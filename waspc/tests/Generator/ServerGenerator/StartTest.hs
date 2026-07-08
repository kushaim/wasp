module Generator.ServerGenerator.StartTest where

import Control.Concurrent (newChan, threadDelay)
import Control.Concurrent.Async (cancel, withAsync)
import Control.Exception (SomeException, finally, try)
import Control.Monad (void, when)
import Job.Process.LongRunningTest (isProcessAlive, makeTempPath, trim, waitUntil)
import qualified StrongPath as SP
import System.Directory (createDirectoryIfMissing, doesFileExist, removeDirectoryRecursive, removeFile)
import System.Exit (ExitCode)
import System.FilePath ((</>))
import System.IO (readFile')
import System.Info (os)
import qualified System.Process as P
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldNotBe, shouldReturn)
import qualified Wasp.Generator.ServerGenerator.Common as ServerGenerator.Common
import Wasp.Generator.ServerGenerator.Start
  ( ServerProcessController,
    ServerRuntimeInputChange (..),
    newServerProcessController,
    notifyFailedCompile,
    notifySuccessfulCompile,
    startServer,
  )
import Wasp.Util (secondsToMicroSeconds)

spec_ServerProcessController :: Spec
spec_ServerProcessController =
  if os == "mingw32"
    then return ()
    else describe "server process controller" $ do
      it "starts, restarts, and stops the server across compile outcomes" $
        withGeneratedAppDirFixture $ \fixture -> do
          chan <- newChan
          controller <- newServerProcessController
          generatedAppDir <- SP.parseAbsDir $ _generatedAppDirPath fixture
          withAsync (startServer generatedAppDir controller chan) $ \controllerJob -> do
            waitForServerStart fixture
            initialPid <- readServerPid fixture
            readBundleCount fixture `shouldReturn` 1

            -- Client-only change: no bundle, no restart.
            notifySuccessfulCompileOrFail controller NoServerRuntimeInputChange
            readBundleCount fixture `shouldReturn` 1
            readServerPid fixture `shouldReturn` initialPid
            isProcessAlive initialPid `shouldReturn` True

            -- Server change: bundle + restart.
            clearServerPid fixture
            notifySuccessfulCompileOrFail controller ServerRuntimeInputMightHaveChanged
            waitForServerStart fixture
            restartedPid <- readServerPid fixture
            restartedPid `shouldNotBe` initialPid
            isProcessAlive initialPid `shouldReturn` False
            readBundleCount fixture `shouldReturn` 2

            -- Stale exit notification from the stopped process must not
            -- trigger a restart of its replacement. The delay gives the old
            -- process's exit watcher time to enqueue its notification.
            threadDelay $ secondsToMicroSeconds 0.5
            notifySuccessfulCompileOrFail controller NoServerRuntimeInputChange
            readBundleCount fixture `shouldReturn` 2
            readServerPid fixture `shouldReturn` restartedPid
            isProcessAlive restartedPid `shouldReturn` True

            -- Failed compile stops the server.
            notifyFailedCompileOrFail controller
            waitUntil "server stop after failed compile" $ not <$> isProcessAlive restartedPid

            -- Next successful compile brings the server back even without
            -- server-related changes.
            clearServerPid fixture
            notifySuccessfulCompileOrFail controller NoServerRuntimeInputChange
            waitForServerStart fixture
            recoveredPid <- readServerPid fixture
            readBundleCount fixture `shouldReturn` 3

            -- Cancelling the controller job stops the server.
            cancel controllerJob
            waitUntil "server stop after controller cancel" $ not <$> isProcessAlive recoveredPid

      it "detects a crashed server via exit-code polling and restarts it" $
        withGeneratedAppDirFixture $ \fixture -> do
          -- The crashing server leaves behind a child holding the output pipe
          -- open, which delays the regular process exit notification, so the
          -- controller can only notice the crash by polling the exit code.
          writeServerStartScript fixture crashingServerScript
          chan <- newChan
          controller <- newServerProcessController
          generatedAppDir <- SP.parseAbsDir $ _generatedAppDirPath fixture
          withAsync (startServer generatedAppDir controller chan) $ \_ -> do
            waitUntil "crashed server pid file" $ doesFileExist $ serverPidFilePath fixture
            crashedPid <- readServerPid fixture
            waitUntil "server crash" $ not <$> isProcessAlive crashedPid
            waitUntil "leftover process pid file" $ doesFileExist $ leftoverPidFilePath fixture
            leftoverPid <- trim <$> readFile' (leftoverPidFilePath fixture)
            isProcessAlive leftoverPid `shouldReturn` True

            writeServerStartScript fixture loopingServerScript
            clearServerPid fixture
            notifySuccessfulCompileOrFail controller NoServerRuntimeInputChange
            waitForServerStart fixture
            newPid <- readServerPid fixture
            newPid `shouldNotBe` crashedPid
            waitUntil "leftover process cleanup" $ not <$> isProcessAlive leftoverPid

      it "kills the crashed server's leftover processes when the crash is reported while idle" $
        withGeneratedAppDirFixture $ \fixture -> do
          -- The detached child does not hold the output pipes, so the exit
          -- notification arrives promptly while the controller sits idle.
          writeServerStartScript fixture crashingServerWithDetachedChildScript
          chan <- newChan
          controller <- newServerProcessController
          generatedAppDir <- SP.parseAbsDir $ _generatedAppDirPath fixture
          withAsync (startServer generatedAppDir controller chan) $ \_ -> do
            waitUntil "crashed server pid file" $ doesFileExist $ serverPidFilePath fixture
            waitUntil "leftover process pid file" $ doesFileExist $ leftoverPidFilePath fixture
            leftoverPid <- trim <$> readFile' (leftoverPidFilePath fixture)
            waitUntil "leftover process cleanup" $ not <$> isProcessAlive leftoverPid

newtype GeneratedAppDirFixture = GeneratedAppDirFixture
  { _generatedAppDirPath :: FilePath
  }

withGeneratedAppDirFixture :: (GeneratedAppDirFixture -> IO ()) -> IO ()
withGeneratedAppDirFixture test = do
  generatedAppDirPath <- makeTempPath "wasp-server-controller-test"
  let fixture = GeneratedAppDirFixture generatedAppDirPath
  createDirectoryIfMissing True $ serverDirPath fixture
  writeFile (serverDirPath fixture </> "package.json") packageJson
  writeFile (serverDirPath fixture </> "bundle.sh") "echo bundled >> bundles.log\n"
  writeServerStartScript fixture loopingServerScript
  test fixture `finally` cleanUpFixture fixture
  where
    packageJson =
      unlines
        [ "{",
          "  \"name\": \"wasp-server-controller-test\",",
          "  \"version\": \"1.0.0\",",
          "  \"scripts\": {",
          "    \"bundle\": \"sh bundle.sh\",",
          "    \"start\": \"sh start.sh\"",
          "  }",
          "}"
        ]

cleanUpFixture :: GeneratedAppDirFixture -> IO ()
cleanUpFixture fixture = do
  mapM_ killPidFromFile [serverPidFilePath fixture, leftoverPidFilePath fixture]
  void (try (removeDirectoryRecursive $ _generatedAppDirPath fixture) :: IO (Either SomeException ()))
  where
    killPidFromFile pidFilePath = do
      exists <- doesFileExist pidFilePath
      when exists $ do
        pid <- trim <$> readFile' pidFilePath
        void (try (P.readCreateProcessWithExitCode (P.proc "kill" ["-KILL", pid]) "") :: IO (Either SomeException (ExitCode, String, String)))

loopingServerScript :: String
loopingServerScript =
  unlines
    [ "trap 'exit 0' INT TERM",
      "echo $$ > server.pid",
      "while true; do sleep 0.1; done"
    ]

crashingServerScript :: String
crashingServerScript =
  unlines
    [ "echo $$ > server.pid",
      "sleep 300 &",
      "echo $! > leftover.pid",
      "exit 1"
    ]

crashingServerWithDetachedChildScript :: String
crashingServerWithDetachedChildScript =
  unlines
    [ "echo $$ > server.pid",
      "sleep 300 >/dev/null 2>&1 &",
      "echo $! > leftover.pid",
      "exit 1"
    ]

writeServerStartScript :: GeneratedAppDirFixture -> String -> IO ()
writeServerStartScript fixture = writeFile (serverDirPath fixture </> "start.sh")

serverDirPath :: GeneratedAppDirFixture -> FilePath
serverDirPath fixture =
  _generatedAppDirPath fixture </> SP.fromRelDir ServerGenerator.Common.serverRootDirInGeneratedAppDir

serverPidFilePath :: GeneratedAppDirFixture -> FilePath
serverPidFilePath fixture = serverDirPath fixture </> "server.pid"

leftoverPidFilePath :: GeneratedAppDirFixture -> FilePath
leftoverPidFilePath fixture = serverDirPath fixture </> "leftover.pid"

bundlesLogFilePath :: GeneratedAppDirFixture -> FilePath
bundlesLogFilePath fixture = serverDirPath fixture </> "bundles.log"

waitForServerStart :: GeneratedAppDirFixture -> IO ()
waitForServerStart fixture =
  waitUntilWithin "server start" 30 $ do
    pidFileExists <- doesFileExist $ serverPidFilePath fixture
    if pidFileExists
      then readServerPid fixture >>= isProcessAlive
      else return False

readServerPid :: GeneratedAppDirFixture -> IO String
readServerPid fixture = trim <$> readFile' (serverPidFilePath fixture)

clearServerPid :: GeneratedAppDirFixture -> IO ()
clearServerPid fixture = do
  exists <- doesFileExist $ serverPidFilePath fixture
  when exists $ removeFile $ serverPidFilePath fixture

readBundleCount :: GeneratedAppDirFixture -> IO Int
readBundleCount fixture = do
  exists <- doesFileExist $ bundlesLogFilePath fixture
  if exists
    then length . lines <$> readFile' (bundlesLogFilePath fixture)
    else return 0

notifySuccessfulCompileOrFail :: ServerProcessController -> ServerRuntimeInputChange -> IO ()
notifySuccessfulCompileOrFail controller serverRuntimeInputChange =
  failUnlessHandledInTime $ notifySuccessfulCompile controller serverRuntimeInputChange

notifyFailedCompileOrFail :: ServerProcessController -> IO ()
notifyFailedCompileOrFail = failUnlessHandledInTime . notifyFailedCompile

failUnlessHandledInTime :: IO () -> IO ()
failUnlessHandledInTime notify =
  timeout (secondsToMicroSeconds 60) notify
    >>= maybe (expectationFailure "Controller did not handle the notification in time") return

waitUntilWithin :: String -> Double -> IO Bool -> IO ()
waitUntilWithin label seconds condition = go attempts
  where
    attempts = ceiling $ seconds / 0.25 :: Int
    go remainingAttempts
      | remainingAttempts <= 0 = expectationFailure $ "Timed out waiting for " <> label
      | otherwise = do
          result <- condition
          if result
            then return ()
            else do
              threadDelay (secondsToMicroSeconds 0.25)
              go $ remainingAttempts - 1
