module Wasp.Job.Process.LongRunning
  ( LongRunningProcess,
    getExitCode,
    start,
    stop,
    wait,
  )
where

import Control.Concurrent (Chan, threadDelay, writeChan)
import Control.Concurrent.Async (Async, async, cancel, waitCatch)
import Control.Exception (SomeException, try)
import Control.Monad (void, when)
import qualified Data.ByteString as BS
import Data.Maybe (isNothing)
import Data.Text.Encoding (decodeUtf8)
import System.Exit (ExitCode)
import System.IO (Handle, hClose)
import qualified System.Info
import qualified System.Process as P
import qualified Wasp.Job as J

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
        waitForOutput stdoutAsync
        waitForOutput stderrAsync
        closeHandles
        return exitCode
  let stopProcessAndOutput = do
        stopProcessTree processHandle maybeProcessGroupPid
        closeHandles
        cancel stdoutAsync
        cancel stderrAsync
  return $
    LongRunningProcess
      { wait = waitForProcessAndOutput,
        stop = stopProcessAndOutput,
        getExitCode = P.getProcessExitCode processHandle
      }

configureLongRunningProcess :: P.CreateProcess -> P.CreateProcess
configureLongRunningProcess process =
  process
    { P.create_group = System.Info.os /= "mingw32",
      P.use_process_jobs = System.Info.os == "mingw32",
      -- Long-running processes don't read stdin, so we can isolate and stop
      -- the whole process tree.
      -- We still pipe and drain stdout/stderr: System.Process documents NoStream as
      -- unsafe for output when the child writes to the closed file descriptor.
      P.std_in = P.NoStream,
      P.std_out = P.CreatePipe,
      P.std_err = P.CreatePipe
    }

waitForOutput :: Async a -> IO ()
waitForOutput outputAsync = void $ waitCatch outputAsync

forwardOutput :: Chan J.JobMessage -> J.JobType -> Maybe Handle -> J.JobOutputType -> IO ()
forwardOutput _ _ Nothing _ = return ()
forwardOutput chan jobType (Just handle) outputType = forwardChunks
  where
    forwardChunks = do
      output <- BS.hGetSome handle 4096
      if BS.null output
        then return ()
        else do
          writeChan chan $
            J.JobMessage
              { J._data = J.JobOutput (decodeUtf8 output) outputType,
                J._jobType = jobType
              }
          forwardChunks

closeHandleIfOpen :: Maybe Handle -> IO ()
closeHandleIfOpen Nothing = return ()
closeHandleIfOpen (Just handle) = void (try $ hClose handle :: IO (Either SomeException ()))

stopProcessTree :: P.ProcessHandle -> Maybe String -> IO ()
stopProcessTree processHandle maybeProcessGroupPid = do
  -- First ask the tree to stop, then escalate if it doesn't release resources
  -- in time e.g. a dev server port.
  interruptProcessTree processHandle maybeProcessGroupPid
  void $ waitForExit processHandle gracefulStopTimeoutMicroseconds
  -- The root process can exit before its descendants, so root exit isn't enough
  -- proof that the server port was released.
  terminateProcessTree processHandle maybeProcessGroupPid
  void $ waitForExit processHandle hardStopTimeoutMicroseconds

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
interruptProcessTree processHandle maybeProcessGroupPid =
  if System.Info.os == "mingw32"
    then terminateRootProcessIfRunning processHandle
    else case maybeProcessGroupPid of
      Nothing -> void (try (P.interruptProcessGroupOf processHandle) :: IO (Either SomeException ()))
      Just processGroupPid -> signalProcessGroup "INT" processGroupPid

terminateProcessTree :: P.ProcessHandle -> Maybe String -> IO ()
terminateProcessTree processHandle maybeProcessGroupPid =
  if System.Info.os == "mingw32"
    then terminateRootProcessIfRunning processHandle
    else do
      maybe (return ()) (signalProcessGroup "KILL") maybeProcessGroupPid
      terminateRootProcessIfRunning processHandle

terminateRootProcessIfRunning :: P.ProcessHandle -> IO ()
terminateRootProcessIfRunning processHandle = do
  isRunning <- isProcessRunning processHandle
  when isRunning $ P.terminateProcess processHandle

signalProcessGroup :: String -> String -> IO ()
signalProcessGroup signal pid = do
  -- System.Process exposes group interrupts but not arbitrary group signals.
  signalResult <- try $ P.readCreateProcessWithExitCode (P.proc "kill" ["-" <> signal, "-" <> pid]) ""
  case signalResult :: Either SomeException (ExitCode, String, String) of
    Left _ -> return ()
    Right _ -> return ()

isProcessRunning :: P.ProcessHandle -> IO Bool
isProcessRunning processHandle = do
  maybeExitCode <- P.getProcessExitCode processHandle
  return $ isNothing maybeExitCode

gracefulStopTimeoutMicroseconds :: Int
gracefulStopTimeoutMicroseconds = secondsInMicroseconds `div` 4

hardStopTimeoutMicroseconds :: Int
hardStopTimeoutMicroseconds = 5 * secondsInMicroseconds

pollIntervalMicroseconds :: Int
pollIntervalMicroseconds = secondsInMicroseconds `div` 10

secondsInMicroseconds :: Int
secondsInMicroseconds = 1000000
