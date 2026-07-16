module Wasp.Job.Process
  ( runProcessAndStreamOutput,
    runProcessAsJob,
  )
where

import Control.Concurrent.Async (Concurrently (..))
import Data.Conduit (runConduit, (.|))
import qualified Data.Conduit.List as CL
import qualified Data.Conduit.Process as CP
import qualified Data.Conduit.Text as CT
import qualified System.Process as P
import UnliftIO.Exception (bracket, finally)
import qualified Wasp.Job as J

-- TODO:
--   Switch from Data.Conduit.Process to Data.Conduit.Process.Typed.
--   It is a new module meant to replace Data.Conduit.Process which is about to become deprecated.

-- | Runs a top-level job and emits 'JobExit' when it finishes.
-- Internal child processes should use 'runProcessAndStreamOutput' instead.
runProcessAsJob :: P.CreateProcess -> J.JobType -> J.Job
runProcessAsJob process jobType = J.makeJob jobType $ runProcessAndStreamOutput process jobType

-- | Runs a child process and streams its output without emitting 'JobExit'.
-- Use 'runProcessAsJob' for top-level jobs that should signal completion to job readers.
runProcessAndStreamOutput :: P.CreateProcess -> J.JobType -> J.JobOutputStreamer
runProcessAndStreamOutput process jobType chan =
  bracket
    (CP.streamingProcess process)
    cleanUpStreamingProcess
    runStreamingProcessAndStreamOutput
  where
    cleanUpStreamingProcess (_, _, _, streamingProcessHandle) =
      terminateStreamingProcess streamingProcessHandle
        `finally` CP.closeStreamingProcessHandle streamingProcessHandle

    runStreamingProcessAndStreamOutput (CP.Inherited, stdoutStream, stderrStream, processHandle) = do
      let forwardStdoutToChan =
            runConduit $
              stdoutStream .| CT.decodeUtf8Lenient .| CL.mapM_ (\text -> J.writeJobOutput jobType J.Stdout text chan)

      let forwardStderrToChan =
            runConduit $
              stderrStream .| CT.decodeUtf8Lenient .| CL.mapM_ (\text -> J.writeJobOutput jobType J.Stderr text chan)

      runConcurrently $
        Concurrently forwardStdoutToChan
          *> Concurrently forwardStderrToChan
          *> Concurrently (CP.waitForStreamingProcess processHandle)

    -- This generic runner does not create a process group, so it owns only the
    -- root process. Group cleanup belongs to LongRunning, which creates one.
    terminateStreamingProcess :: CP.StreamingProcessHandle -> IO ()
    terminateStreamingProcess streamingProcessHandle = do
      let processHandle = CP.streamingProcessHandleRaw streamingProcessHandle
      CP.getStreamingProcessExitCode streamingProcessHandle >>= \case
        Just _ -> return ()
        Nothing -> P.terminateProcess processHandle
