# Build Scheduling and Performance

## Findings

- Every filesystem event triggers full compilation before server relevance is known. Successful compiles also rebuild SDK unconditionally; even runtime-env changes do excessive work.

- Successful compile hook blocks watcher through server bundle and replacement. New events queue while obsolete revision can still become running server.

- Debounce stores duplicate events in list and lacks revision identity, coalescing, cancellation, or latest-wins behavior. Burst edits therefore create avoidable work and stale transitions.

- Low-level Node jobs previously ran `node --version` and `npm --version` before every Node command. Local cleanup removed these hot-path checks, eliminating four version subprocesses from each successful server replacement.

- Current pipeline fixes Nodemon coordination race but does not achieve component-granular invalidation. Client-only, restart-only, bundle-only, and full-generation changes still share too much work.

## Target pipeline

```text
filesystem snapshot
  -> RevisionId
  -> input/effect analysis
  -> latest-wins scheduler
  -> required build phases only
  -> bundle immutable revision
  -> process supervisor replacement
```

Only newest successful revision may start. Pending work for superseded revisions should coalesce or cancel where safe.

## Actions

- Introduce revision IDs across watch, compile, bundle, and process replacement.
- Implement latest-wins scheduler with event-set aggregation and obsolete-work cancellation.
- Split build into incremental phase DAG; skip SDK, npm, Prisma, and bundle when unaffected.
- Cache immutable phase results by declared inputs and effects.
- Complete `ValidatedNodeEnvironment` capability and pass it from command boundary into IO/library APIs.
- Measure edit-to-ready latency separately for client-only, restart-only, rebundle, and full-regeneration changes.
