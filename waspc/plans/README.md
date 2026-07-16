# Native Server Lifecycle Review

Review scope: `miho/native-server-process-watch`, PR #4407. Goal: remove Nodemon while keeping one correct owner for compilation, bundling, server replacement, and process-tree cleanup.

Documents:

- [Process lifecycle](./01-process-lifecycle.md)
- [Invalidation and watching](./02-invalidation-and-watch.md)
- [Build scheduling and performance](./03-build-scheduling-and-performance.md)
- [Integration, upgrades, and merge gate](./04-integration-and-merge-gate.md)
- [Machine-readable tasks](./tasks.json)

Finding sections capture review baseline. `tasks.json` is live execution status and scope.

Task priority:

```text
P0 = correctness or merge risk
P1 = required robustness work
P2 = follow-up architecture, performance, or hygiene
```

Task status:

```text
pending | completed
```
