# Integration, Upgrades, and Merge Gate

## Findings (review baseline)

- Removing Nodemon establishes one intended server lifecycle owner and removes SDK-generation coordination race. `CompileResult`, exact draft deltas, watch hooks, serialized controller, process IDs, Node-job extraction, and shared glob utilities are useful enabling refactors.

- Expanded TypeScript Spec includes invalidate old watcher assumption that all relevant files live at root or under `src`. Recent Vite/Rolldown changes also expose platform-sensitive generated bundle output on macOS ARM.

- Four tracked example lockfiles still contain generated-server Nodemon. Waspello and waspleau lockfiles also contain unrelated React Router/plugin churn.

- Nodemon remains in Spec package development dependencies. This usage is separate from generated server lifecycle and is not correctness bug.

- Local macOS ARM suites pass: 663 waspc tests and 41 CLI tests. Current CI still has lifecycle failures on Linux ARM, port leaks in starter/examples, and one macOS generated-bundle snapshot mismatch.

- Windows check passes while lifecycle tests are skipped. Platform merge confidence remains incomplete.

## Current local status

- macOS ARM passes 667 core tests, 45 CLI tests, three repeated core-suite flake runs, and `cabal build all`.

- Seven example locks now contain only intended generated-server Nodemon removals; Spec's independent Nodemon 3 watcher remains. Full generated-app/npm validation awaits fresh dependencies and CI.

- POSIX supervision, port rebind, resource cleanup, signal exit identity, and Linux zombie-aware liveness are implemented. Windows independent root monitoring remains deferred.

## Merge gate

```text
[ ] Linux ARM lifecycle tests green in CI; implementation is ready for rerun
[x] local lifecycle tests prove shutdown and replacement release the server port
[x] process streams/handles resource-safe
[x] generated locks intentional
[ ] generated snapshots intentional across CI platforms
```

## Known residual risks

- Windows independent root monitoring and lifecycle tests are deferred.
- Broader invalidation coverage and watcher-start revision reconciliation retain old-system limitations and are deferred.

## Actions

- [x] Implement fixes for observed POSIX lifecycle failures.
- [x] Add real port-bind/rebind tests after shutdown and replacement.
- [ ] Enable process supervision tests on Windows with native root monitoring; deferred.
- [x] Remove stale generated-server Nodemon lock entries and isolate unrelated dependency churn.
- [ ] Investigate macOS ARM Vite/Rolldown snapshot difference separately; deferred.
- [x] Remove repeated low-level Node/npm checks.
- [ ] Introduce typed Node validation capability; deferred.
- [ ] Re-run full CI matrix.
