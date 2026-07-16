# Invalidation and Watch

## Findings

- Server invalidation derives semantic decisions from path globs. It misses env-validation SDK output, dependency changes, Prisma Client regeneration, JSX-family server inputs, and generated config/runtime effects.

- Valid TypeScript Spec inputs outside project root and `src/**` are not watched. Custom `wasp.tsconfig` includes can compile initially, then never react to edits.

- `CompileResult` records generated draft changes before setup. SDK build, npm install, and Prisma generation mutate runtime inputs after captured delta.

- Initial compile runs before watcher startup. A second registration/timestamp race can classify uncovered events as stale.

- `package-lock.json` is globally ignored, while install record compares declared dependencies only. Lock-only resolution changes can leave stale `node_modules` indefinitely.

- Compile diagnostics are published after blocking lifecycle hooks. Quiet-down reporting can consume previous result and lose newest warning.

## Target model

```hs
data BuildEffects = BuildEffects
  { serverBundleInputsChanged :: Bool
  , runtimeEnvironmentChanged :: Bool
  , dependenciesChanged       :: Bool
  , prismaClientChanged       :: Bool
  , sdkRuntimeChanged          :: Bool
  }

data ServerAction
  = KeepServer
  | RestartServer
  | RebundleAndRestartServer
```

Generator, synchronization, and setup phases produce composable `BuildEffects`; changed paths remain diagnostics only. Compiler also emits `ProjectInputManifest` containing every watched source, config, and imported Spec dependency.

## Actions

- Replace path classifier with compiler-owned semantic `BuildEffects`.
- Include effects from npm, SDK build, Prisma generation, and generated configs.
- Emit `ProjectInputManifest` from actual compiler/TypeScript dependency graph.
- Start watcher before initial compile, snapshot revision, then replay newer events.
- Add lockfile fingerprint to npm install record and suppress self-generated events by revision.
- Publish compile diagnostics before lifecycle work or through ordered event stream.
- Add integration tests for custom TS includes, env schema, dependency version, Prisma, and `.tsx/.jsx/.cts/.cjs` changes.
