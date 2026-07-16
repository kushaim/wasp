module Wasp.Job.Node
  ( makeNodeCommandProcessWithExtraEnv,
    runNodeCommandAndStreamOutputWithExtraEnv,
    runNodeCommandAsJob,
    runNodeCommandAsJobWithExtraEnv,
  )
where

import StrongPath (Abs, Dir, Path')
import qualified StrongPath as SP
import System.Environment (getEnvironment)
import qualified System.Process as P
import qualified Wasp.Job as J
import Wasp.Job.Process (runProcessAndStreamOutput)

runNodeCommandAsJob :: Path' Abs (Dir a) -> String -> [String] -> J.JobType -> J.Job
runNodeCommandAsJob = runNodeCommandAsJobWithExtraEnv []

runNodeCommandAsJobWithExtraEnv :: [(String, String)] -> Path' Abs (Dir a) -> String -> [String] -> J.JobType -> J.Job
runNodeCommandAsJobWithExtraEnv extraEnvVars fromDir command args jobType =
  J.makeJob jobType $
    runNodeCommandAndStreamOutputWithExtraEnv extraEnvVars fromDir command args jobType

runNodeCommandAndStreamOutputWithExtraEnv :: [(String, String)] -> Path' Abs (Dir a) -> String -> [String] -> J.JobType -> J.JobOutputStreamer
runNodeCommandAndStreamOutputWithExtraEnv extraEnvVars fromDir command args jobType chan = do
  nodeCommandProcess <- makeNodeCommandProcessWithExtraEnv extraEnvVars fromDir command args
  runProcessAndStreamOutput nodeCommandProcess jobType chan

-- Node and npm are validated once at CLI command boundaries.
-- TODO: Pass that validation as a capability into this IO layer.
-- Rechecking here added four version subprocesses per server restart.
makeNodeCommandProcessWithExtraEnv :: [(String, String)] -> Path' Abs (Dir a) -> String -> [String] -> IO P.CreateProcess
makeNodeCommandProcessWithExtraEnv extraEnvVars fromDir command args = do
  envVars <- getAllEnvVars
  return $ (P.proc command args) {P.env = Just envVars, P.cwd = Just $ SP.fromAbsDir fromDir}
  where
    -- Haskell will use the first value for variable name it finds. Since env
    -- vars in 'extraEnvVars' should override the inherited env vars, we
    -- must prepend them.
    getAllEnvVars = (extraEnvVars ++) <$> getEnvironment
