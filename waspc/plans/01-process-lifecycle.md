# Process Lifecycle

## Findings

- Root exit is coupled to stdout/stderr EOF in `LongRunning.wait`. A descendant retaining an inherited pipe can prevent exit notification forever.

- Stop observes the `npm run start` wrapper, not full Node process tree or port ownership. Wrapper exit can race replacement and leave old server bound to port.

- CI confirms cleanup failures: six Linux ARM lifecycle tests fail, while starter and four example jobs leave port 3001 occupied after `wasp start` termination.

- Windows uses `use_process_jobs = True`, so `ProcessHandle` completion represents whole job rather than root process. Root crash with surviving child becomes invisible to both waiting and polling.

- Windows lifecycle tests are skipped. Green Windows CI therefore proves compilation, not process supervision behavior.

- SIGINT and SIGTERM both become `UserInterrupt`; cleanup always sends SIGINT. Original signal and exit semantics are lost, while startup and SIGHUP remain outside complete handling.

- Generic process streaming applies strict UTF-8 decoding to arbitrary chunks and does not explicitly close every pipe handle. Valid split multibyte output can throw; repeated bundles risk descriptor leakage.

- POSIX process groups do not contain truly detached children, and current detached-child test does not create a new session or group. `NoStream` also changes stdin behavior for custom interactive servers.

- Controller requests use blocking `MVar`s without closed/not-started states, and exit-watcher `Async`s are discarded. Controller failure can hang callers or silently disable crash reporting.

- `Job` and `JobOutputStreamer` are identical aliases. Type system cannot enforce their different completion and `JobExit` contracts.

## Target model

```hs
data ManagedProcessState
  = Running
  | RootExited ExitCode
  | DrainingOutput
  | TreeQuiescent
  | Stopped

data ShutdownReason
  = Interrupt
  | Terminate
  | Hangup
  | Replace RevisionId
  | ParentExit
```

Root exit, bounded output drain, and tree quiescence must be independently observable. Replacement may start only after owned tree is quiescent and server port can be rebound.

## Current implementation

- POSIX uses a dedicated process group, independent root waiter, bounded output drain, idempotent stop worker, and fail-closed replacement. Linux ignores zombie-only groups after two `/proc` scans so container PID 1 cannot create false shutdown timeouts.

- Isolated long-running server and web-app jobs close stdin. They are intentionally noninteractive because a background process group cannot safely read the foreground terminal.

- Windows still couples root completion to Job Object completion; independent root monitoring and lifecycle tests are deferred.

## Actions

- Build cross-platform supervisor with separate root and tree lifetimes.
- Launch Node directly or explicitly model npm wrapper and Node child as different processes.
- Wait for tree termination and port release before publishing `Stopped`.
- Implement POSIX process-group liveness and Windows job-object ownership with independent root monitoring.
- Preserve SIGINT/SIGTERM CLI exit identity. Propagate shutdown reason through child cleanup only with future scoped lifecycle API.
- Bracket process creation, close handles, stream UTF-8 incrementally, and flush decoder at EOF.
- Replace controller with scoped lifecycle API and explicit states, preferably STM-backed.
- Decide and test detached-child and stdin support contracts.
- Replace `Job` aliases with distinct types or separate completion primitives.
