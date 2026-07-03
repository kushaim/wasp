module Wasp.Cli.Command.Start.ServerRuntimeInputChange
  ( classifyServerRuntimeInputChange,
  )
where

import qualified StrongPath as SP
import qualified System.FilePath as FP
import Wasp.Cli.Command.Compile (CompileResult (..))
import Wasp.Cli.Command.Watch (ProjectFileChange (..), WatchCompileResult (..))
import Wasp.Generator.Common (GeneratedAppDir)
import Wasp.Generator.FileDraft.Writeable (FileOrDirPathRelativeTo)
import qualified Wasp.Generator.ServerGenerator.Common as ServerGenerator.Common
import Wasp.Generator.ServerGenerator.Start (ServerRuntimeInputChange (..))
import Wasp.Generator.WriteFileDrafts (GeneratedAppPathChange (..))
import Wasp.Project.Common (srcDirInWaspProjectDir)
import Wasp.Util.Glob (compileGlobPatterns, dirAndDescendantsGlobs, matchesAnyGlob, recursiveFileGlobsWithExtensions)

classifyServerRuntimeInputChange :: WatchCompileResult -> ServerRuntimeInputChange
classifyServerRuntimeInputChange watchCompileResult
  | any (serverRuntimeInputGlobs `matchesAnyGlob`) changedPaths = ServerRuntimeInputMightHaveChanged
  | otherwise = NoServerRuntimeInputChange
  where
    changedPaths = changedProjectPaths ++ changedGeneratedAppPaths

    changedProjectPaths = _projectFileChangePath <$> _watchProjectFileChanges watchCompileResult
    changedGeneratedAppPaths =
      generatedAppPathChangeToFilePath <$> _compileGeneratedAppPathChanges (_watchCompileResult watchCompileResult)

    -- SDK changes ('sdk/wasp/...') are deliberately not covered by these globs,
    -- even though the server bundle includes the SDK. We assume every
    -- server-relevant SDK regeneration comes with a change to the generated
    -- server src or the user's src.
    serverRuntimeInputGlobs =
      compileGlobPatterns $
        concat
          [ recursiveFileGlobsWithExtensions projectSrcDir serverRuntimeInputFileExtensions,
            [generatedServerEnvFile],
            dirAndDescendantsGlobs generatedServerSrcDir
          ]

    projectSrcDir = FP.dropTrailingPathSeparator $ SP.fromRelDir srcDirInWaspProjectDir
    generatedServerSrcDir = FP.dropTrailingPathSeparator $ SP.fromRelDir ServerGenerator.Common.serverSrcDirInGeneratedAppDir
    generatedServerEnvFile = SP.fromRelDir ServerGenerator.Common.serverRootDirInGeneratedAppDir FP.</> ".env"
    serverRuntimeInputFileExtensions = [".ts", ".mts", ".js", ".mjs", ".json"]

generatedAppPathChangeToFilePath :: GeneratedAppPathChange -> FilePath
generatedAppPathChangeToFilePath (GeneratedAppPathWritten path) = fileOrDirPathToFilePath path
generatedAppPathChangeToFilePath (GeneratedAppPathDeleted path) = fileOrDirPathToFilePath path

fileOrDirPathToFilePath :: FileOrDirPathRelativeTo GeneratedAppDir -> FilePath
fileOrDirPathToFilePath (Left file) = SP.fromRelFile file
fileOrDirPathToFilePath (Right dir) = FP.dropTrailingPathSeparator $ SP.fromRelDir dir
