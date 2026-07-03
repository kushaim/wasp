module Wasp.Job.Process.LongRunning
  ( LongRunningProcess,
    getExitCode,
    start,
    stop,
    wait,
  )
where

import Control.Concurrent (Chan, threadDelay)
import Control.Concurrent.Async (Async, async, cancel, waitCatch)
import Control.Exception (SomeException, try)
import Control.Monad (unless, void, when)
import qualified Data.ByteString as BS
import Data.Maybe (isNothing)
import qualified Data.Text as T
import Data.Text.Encoding (Decoding (Some), streamDecodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import System.Exit (ExitCode)
import System.IO (Handle, hClose)
import qualified System.Process as P
import qualified Wasp.Job as J
import Wasp.Util (isWindows, secondsToMicroSeconds)

-- Long-running processes are Wasp-owned children started now and stopped later.
-- They forward output to the job channel, but don't emit JobExit.
data LongRunningProcess = LongRunningProcess
  { wait :: IO ExitCode,
    stop :: IO (),
    getExitCode :: IO (Maybe ExitCode)
  }

start :: P.CreateProcess -> J.JobType -> Chan J.JobMessage -> IO LongRunningProcess
start process jobType chan = do
  (maybeStdin, maybeStdout, maybeStderr, processHandle) <- P.createProcess $ configureLongRunningProcess process
  maybeProcessGroupPid <- fmap show <$> P.getPid processHandle
  stdoutAsync <- async $ forwardOutput chan jobType maybeStdout J.Stdout
  stderrAsync <- async $ forwardOutput chan jobType maybeStderr J.Stderr
  let closeHandles = mapM_ closeHandleIfOpen [maybeStdin, maybeStdout, maybeStderr]
  let waitForProcessAndOutput = do
        exitCode <- P.waitForProcess processHandle
        -- Wait for any buffered output after the root process exits.
        waitForOutputForwarding stdoutAsync
        waitForOutputForwarding stderrAsync
        closeHandles
        return exitCode
  let stopProcessAndOutput = do
        rootProcessExited <- stopProcessTree processHandle maybeProcessGroupPid
        -- hClose blocks while a forwarder is still reading from the handle,
        -- so the forwarders must be cancelled first.
        cancel stdoutAsync
        cancel stderrAsync
        closeHandles
        unless rootProcessExited $
          J.writeJobOutput jobType J.Stderr "Process did not stop after a kill signal; it may still be running.\n" chan
  return $
    LongRunningProcess
      { wait = waitForProcessAndOutput,
        stop = stopProcessAndOutput,
        getExitCode = P.getProcessExitCode processHandle
      }

configureLongRunningProcess :: P.CreateProcess -> P.CreateProcess
configureLongRunningProcess process =
  process
    { P.create_group = not isWindows,
      P.use_process_jobs = isWindows,
      -- Long-running processes don't read stdin, so we can isolate and stop
      -- the whole process tree.
      -- We still pipe and drain stdout/stderr: System.Process documents NoStream as
      -- unsafe for output when the child writes to the closed file descriptor.
      P.std_in = P.NoStream,
      P.std_out = P.CreatePipe,
      P.std_err = P.CreatePipe
    }

waitForOutputForwarding :: Async a -> IO ()
waitForOutputForwarding = void . waitCatch

forwardOutput :: Chan J.JobMessage -> J.JobType -> Maybe Handle -> J.JobOutputType -> IO ()
forwardOutput _ _ Nothing _ = return ()
forwardOutput chan jobType (Just handle) outputType =
  -- Chunks can split a multi-byte UTF-8 sequence, so decoding must carry
  -- partial sequences over into the next chunk.
  forwardChunks $ streamDecodeUtf8With lenientDecode
  where
    forwardChunks decodeChunk = do
      chunk <- BS.hGetSome handle chunkSizeInBytes
      unless (BS.null chunk) $ do
        let Some output _ decodeNextChunk = decodeChunk chunk
        unless (T.null output) $
          J.writeJobOutput jobType outputType output chan
        forwardChunks decodeNextChunk

    chunkSizeInBytes = 4096

closeHandleIfOpen :: Maybe Handle -> IO ()
closeHandleIfOpen Nothing = return ()
closeHandleIfOpen (Just handle) = void (try $ hClose handle :: IO (Either SomeException ()))

-- | Returns whether the root process is known to have exited.
stopProcessTree :: P.ProcessHandle -> Maybe String -> IO Bool
stopProcessTree processHandle maybeProcessGroupPid = do
  -- First ask the tree to stop, then escalate if it doesn't release resources
  -- in time e.g. a dev server port.
  interruptProcessTree processHandle maybeProcessGroupPid
  void $ waitForExit processHandle gracefulStopTimeoutMicroseconds
  -- The root process can exit before its descendants, so root exit isn't enough
  -- proof that the server port was released.
  terminateProcessTree processHandle maybeProcessGroupPid
  waitForExit processHandle hardStopTimeoutMicroseconds

waitForExit :: P.ProcessHandle -> Int -> IO Bool
waitForExit processHandle timeoutMicroseconds = waitForExitOrTimeout timeoutMicroseconds
  where
    waitForExitOrTimeout remainingMicroseconds
      | remainingMicroseconds <= 0 = return False
      | otherwise = do
          stillRunning <- isProcessRunning processHandle
          if stillRunning
            then do
              threadDelay pollIntervalMicroseconds
              waitForExitOrTimeout $ remainingMicroseconds - pollIntervalMicroseconds
            else return True

interruptProcessTree :: P.ProcessHandle -> Maybe String -> IO ()
interruptProcessTree processHandle maybeProcessGroupPid
  | isWindows =
      -- There is no graceful phase on Windows: sending CTRL_BREAK requires
      -- create_group, which we don't set there. Thanks to use_process_jobs,
      -- terminating the root process takes the whole tree down with it.
      terminateRootProcessIfRunning processHandle
  | otherwise = case maybeProcessGroupPid of
      Nothing -> void (try (P.interruptProcessGroupOf processHandle) :: IO (Either SomeException ()))
      Just processGroupPid -> signalProcessGroup "INT" processGroupPid

terminateProcessTree :: P.ProcessHandle -> Maybe String -> IO ()
terminateProcessTree processHandle maybeProcessGroupPid
  | isWindows = terminateRootProcessIfRunning processHandle
  | otherwise = do
      maybe (return ()) (signalProcessGroup "KILL") maybeProcessGroupPid
      terminateRootProcessIfRunning processHandle

terminateRootProcessIfRunning :: P.ProcessHandle -> IO ()
terminateRootProcessIfRunning processHandle = do
  isRunning <- isProcessRunning processHandle
  when isRunning $ P.terminateProcess processHandle

signalProcessGroup :: String -> String -> IO ()
signalProcessGroup signal pid =
  -- System.Process exposes group interrupts but not arbitrary group signals.
  void (try $ P.readCreateProcessWithExitCode (P.proc "kill" ["-" <> signal, "-" <> pid]) "" :: IO (Either SomeException (ExitCode, String, String)))

isProcessRunning :: P.ProcessHandle -> IO Bool
isProcessRunning processHandle = do
  maybeExitCode <- P.getProcessExitCode processHandle
  return $ isNothing maybeExitCode

gracefulStopTimeoutMicroseconds :: Int
gracefulStopTimeoutMicroseconds = secondsToMicroSeconds 0.25

hardStopTimeoutMicroseconds :: Int
hardStopTimeoutMicroseconds = secondsToMicroSeconds 5

pollIntervalMicroseconds :: Int
pollIntervalMicroseconds = secondsToMicroSeconds 0.1
