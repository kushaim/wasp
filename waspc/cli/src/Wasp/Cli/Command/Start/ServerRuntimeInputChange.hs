module Wasp.Cli.Command.Start.ServerRuntimeInputChange
  ( classifyServerEffect,
  )
where

import qualified StrongPath as SP
import qualified System.FilePath as FP
import Wasp.Cli.Command.Compile (CompileResult (..))
import Wasp.Cli.Command.Watch (ProjectFileChange (..), WatchCompileResult (..))
import Wasp.Generator.Common (GeneratedAppDir)
import Wasp.Generator.FileDraft.Writeable (FileOrDirPathRelativeTo)
import qualified Wasp.Generator.ServerGenerator.Common as ServerGenerator.Common
import Wasp.Generator.ServerGenerator.Start (ServerEffect (..))
import Wasp.Generator.WriteFileDrafts (GeneratedAppPathChange (..))
import Wasp.Project.Common (srcDirInWaspProjectDir)
import Wasp.Util.Glob (compileGlobPatterns, dirAndDescendantsGlobs, matchesAnyGlob, recursiveFileGlobsWithExtensions)

classifyServerEffect :: WatchCompileResult -> ServerEffect
classifyServerEffect watchCompileResult =
  foldMap projectFileChangeServerEffect (_watchProjectFileChanges watchCompileResult)
    <> foldMap generatedAppPathChangeServerEffect (_compileGeneratedAppPathChanges $ _watchCompileResult watchCompileResult)
  where
    projectFileChangeServerEffect (ProjectFileChange path)
      | projectServerInputGlobs `matchesAnyGlob` path = RebundleAndRestartServer
      | otherwise = NoServerEffect

    generatedAppPathChangeServerEffect (GeneratedAppPathWritten path) = generatedAppPathServerEffect path
    generatedAppPathChangeServerEffect (GeneratedAppPathDeleted path) = generatedAppPathServerEffect path

    generatedAppPathServerEffect :: FileOrDirPathRelativeTo GeneratedAppDir -> ServerEffect
    generatedAppPathServerEffect (Left file)
      | file == generatedServerPackageFile = RebundleAndRestartServer
      | file == generatedServerEnvFile = RestartServer
      | generatedServerSrcGlobs `matchesAnyGlob` SP.fromRelFile file = RebundleAndRestartServer
      | otherwise = NoServerEffect
    generatedAppPathServerEffect (Right dir)
      | generatedServerSrcGlobs `matchesAnyGlob` FP.dropTrailingPathSeparator (SP.fromRelDir dir) = RebundleAndRestartServer
      | otherwise = NoServerEffect

    -- SDK changes ('sdk/wasp/...') are deliberately not covered by these globs,
    -- even though the server bundle includes the SDK. We assume every
    -- server-relevant SDK regeneration comes with a change to the generated
    -- server src or the user's src.
    projectServerInputGlobs =
      compileGlobPatterns $ recursiveFileGlobsWithExtensions projectSrcDir serverRuntimeInputFileExtensions

    generatedServerSrcGlobs = compileGlobPatterns $ dirAndDescendantsGlobs generatedServerSrcDir

    projectSrcDir = FP.dropTrailingPathSeparator $ SP.fromRelDir srcDirInWaspProjectDir
    generatedServerSrcDir = FP.dropTrailingPathSeparator $ SP.fromRelDir ServerGenerator.Common.serverSrcDirInGeneratedAppDir
    generatedServerEnvFile = ServerGenerator.Common.serverRootDirInGeneratedAppDir SP.</> [SP.relfile|.env|]
    generatedServerPackageFile = ServerGenerator.Common.serverRootDirInGeneratedAppDir SP.</> [SP.relfile|package.json|]
    serverRuntimeInputFileExtensions = [".ts", ".mts", ".js", ".mjs", ".json"]
