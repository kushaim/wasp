module Job.Process.LongRunningTest where

import Control.Concurrent (Chan, newChan, readChan, threadDelay)
import Control.Exception (finally)
import Control.Monad (when)
import Data.Maybe (isJust)
import qualified Data.Text as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import System.Directory (doesFileExist, getTemporaryDirectory, removeFile)
import System.Exit (ExitCode (..))
import System.IO (hClose, openTempFile)
import System.Info (os)
import qualified System.Process as P
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)
import qualified Wasp.Job as J
import qualified Wasp.Job.Process.LongRunning as LongRunning
import Wasp.Util (secondsToMicroSeconds)

spec_LongRunningProcess :: Spec
spec_LongRunningProcess =
  if os == "mingw32"
    then return ()
    else describe "LongRunningProcess" $ do
      it "kills process-group descendants after the root process exits" $ do
        pidFilePath <- makeTempPath "wasp-long-running-child.pid"
        chan <- newChan
        longRunningProcess <- LongRunning.start (P.proc "sh" ["-c", childProcessScript pidFilePath]) J.Server chan
        let cleanup = LongRunning.stop longRunningProcess >> removeFileIfExists pidFilePath
        ( do
            waitUntil "child pid file" $ doesFileExist pidFilePath
            childPid <- readFile pidFilePath
            waitUntil "root process exit" $ isJust <$> LongRunning.getExitCode longRunningProcess
            isProcessAlive childPid `shouldReturn` True

            startedAt <- getCurrentTime
            LongRunning.stop longRunningProcess
            stoppedAt <- getCurrentTime

            realToFrac (stoppedAt `diffUTCTime` startedAt) `shouldSatisfy` (< maxAcceptableStopSeconds)
            waitUntil "child process exit" $ not <$> isProcessAlive childPid
          )
          `finally` cleanup

      it "interrupts the process so it can exit gracefully before being killed" $ do
        startedFilePath <- makeTempPath "wasp-long-running-started"
        gracefulExitFilePath <- makeTempPath "wasp-long-running-graceful-exit"
        chan <- newChan
        let script =
              "trap 'echo done > "
                <> shellQuote gracefulExitFilePath
                <> "; exit 0' INT; "
                <> "echo started > "
                <> shellQuote startedFilePath
                <> "; "
                <> "while true; do sleep 0.05; done"
        longRunningProcess <- LongRunning.start (P.proc "sh" ["-c", script]) J.Server chan
        let cleanup =
              LongRunning.stop longRunningProcess
                >> mapM_ removeFileIfExists [startedFilePath, gracefulExitFilePath]
        ( do
            waitUntil "process start" $ doesFileExist startedFilePath
            LongRunning.stop longRunningProcess
            waitUntil "graceful exit marker" $ doesFileExist gracefulExitFilePath
          )
          `finally` cleanup

      it "kills a process that ignores INT" $ do
        startedFilePath <- makeTempPath "wasp-long-running-stubborn"
        chan <- newChan
        let script =
              "trap '' INT TERM; "
                <> "echo started > "
                <> shellQuote startedFilePath
                <> "; "
                <> "while true; do sleep 0.1; done"
        longRunningProcess <- LongRunning.start (P.proc "sh" ["-c", script]) J.Server chan
        let cleanup = LongRunning.stop longRunningProcess >> removeFileIfExists startedFilePath
        ( do
            waitUntil "process start" $ doesFileExist startedFilePath
            startedAt <- getCurrentTime
            LongRunning.stop longRunningProcess
            stoppedAt <- getCurrentTime
            realToFrac (stoppedAt `diffUTCTime` startedAt) `shouldSatisfy` (< maxAcceptableStopSeconds)
            waitUntil "root process exit" $ isJust <$> LongRunning.getExitCode longRunningProcess
          )
          `finally` cleanup

      it "forwards all output when chunks split multibyte characters" $ do
        chan <- newChan
        let euroSignCount = 40000 :: Int
        -- The euro sign is 3 bytes in UTF-8 (octal 342 202 254), so fixed-size
        -- read chunks can't align with character boundaries.
        let script =
              "awk 'BEGIN { for (i = 0; i < "
                <> show euroSignCount
                <> "; i++) printf \"\\342\\202\\254\" }'"
        longRunningProcess <- LongRunning.start (P.proc "sh" ["-c", script]) J.Server chan
        maybeExitCode <- timeout (secondsToMicroSeconds 20) $ LongRunning.wait longRunningProcess
        case maybeExitCode of
          Nothing -> do
            LongRunning.stop longRunningProcess
            expectationFailure "Timed out waiting for process exit; output forwarding likely stalled"
          Just exitCode -> do
            exitCode `shouldBe` ExitSuccess
            output <- collectQueuedOutput chan
            T.length output `shouldBe` euroSignCount
            T.all (== '€') output `shouldBe` True

-- Covers the graceful stop timeout, the KILL escalation, and polling slack.
maxAcceptableStopSeconds :: Double
maxAcceptableStopSeconds = 2

childProcessScript :: FilePath -> String
childProcessScript pidFilePath =
  "trap '' INT; "
    <> "(trap '' INT; while true; do sleep 1; done) & "
    <> "echo $! > "
    <> shellQuote pidFilePath
    <> "; "
    <> "sleep 0.2; "
    <> "exit 0"

collectQueuedOutput :: Chan J.JobMessage -> IO T.Text
collectQueuedOutput chan = go []
  where
    go collected = do
      maybeMessage <- timeout (secondsToMicroSeconds 0.2) $ readChan chan
      case maybeMessage of
        Nothing -> return $ T.concat $ reverse collected
        Just J.JobMessage {J._data = J.JobOutput output _} -> go (output : collected)
        Just _ -> go collected

makeTempPath :: String -> IO FilePath
makeTempPath nameTemplate = do
  tempDir <- getTemporaryDirectory
  (filePath, fileHandle) <- openTempFile tempDir nameTemplate
  hClose fileHandle
  removeFile filePath
  return filePath

shellQuote :: String -> String
shellQuote value = "'" <> concatMap quoteChar value <> "'"
  where
    quoteChar '\'' = "'\\''"
    quoteChar char = [char]

waitUntil :: String -> IO Bool -> IO ()
waitUntil label condition = go (50 :: Int)
  where
    go remainingAttempts
      | remainingAttempts <= 0 = expectationFailure $ "Timed out waiting for " <> label
      | otherwise = do
          result <- condition
          if result
            then return ()
            else do
              threadDelay 100000
              go $ remainingAttempts - 1

isProcessAlive :: String -> IO Bool
isProcessAlive pid = do
  (exitCode, _, _) <- P.readCreateProcessWithExitCode (P.proc "kill" ["-0", trim pid]) ""
  return $ exitCode == ExitSuccess

trim :: String -> String
trim = unwords . words

removeFileIfExists :: FilePath -> IO ()
removeFileIfExists filePath = do
  exists <- doesFileExist filePath
  when exists $ removeFile filePath
