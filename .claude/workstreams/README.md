# Workstreams

Each file here is a **self-contained backlog for one orchestrator**. They are deliberately
separate so several orchestrators can run in parallel without colliding — a workstream names
the files it touches, so you can see the overlap before you spawn anything.

| Workstream | Owns | Touches |
|---|---|---|
| [TESTING.md](TESTING.md) | the test suite, gates, CI, golden/oracle machinery | `test/`, `.github/workflows/` |
| [COMPILER-SOUNDNESS.md](COMPILER-SOUNDNESS.md) | miscompiles + check/run/build disagreement | `compiler/types/`, `compiler/backend/`, `compiler/eval/` |
| [PERF.md](PERF.md) | quadratics + constant factors in the compiler | `compiler/frontend/resolve.mdk`, `compiler/tools/check.mdk` |
| [STDLIB.md](STDLIB.md) | missing stdlib/support functions the compiler keeps hand-rolling | `stdlib/`, `compiler/support/util.mdk` |
| [DIAGNOSTICS.md](DIAGNOSTICS.md) | error-message quality + wrong/fabricated source locations | `compiler/driver/diagnostics.mdk`, `compiler/frontend/` |
| [HARNESS.md](HARNESS.md) | the agent harness itself (not the repo) | — |

## Collision map — read before running two of these at once

- **TESTING × everything.** Testing only touches `test/` and `.github/`, so it is the safest to
  run alongside anything. The exception is when a compiler fix needs a golden re-cut; that
  belongs to the *compiler* workstream's PR, not to Testing's.
- **COMPILER-SOUNDNESS × PERF.** Both touch `compiler/`. `resolve.mdk` (PERF) and
  `typecheck.mdk`/`llvm_emit.mdk` (SOUNDNESS) are different files, so they *usually* merge —
  but see the warning below. Sequence them if either grows.
- **STDLIB × everything.** `stdlib/core.mdk` is the **prelude**: touching it moves every
  snapshot golden and perturbs the fixpoint. Land stdlib changes at a checkpoint, alone.

## ⚠️ Two rules that are not negotiable

1. **A clean auto-merge is NOT agreement.** Two green branches have merged cleanly into a
   *crashing* tree — git flagged 2 conflicts and silently auto-merged a third break it could
   not see (one branch had added a caller into machinery the other was re-signing; different
   lines, so no conflict marker). If two workstreams touched the same subsystem, **grep the
   merged tree for every caller of any signature that changed**, and run
   `typecheck_compiler_source.sh` — it is the *only* thing that catches a stale caller, because
   `make medaka` does not gate on type errors.

2. **STAGE COMMITS BY PATH. NEVER `git add -A`.** The harness misroutes agents into the
   orchestrator's worktree (see [HARNESS.md](HARNESS.md)). A `git add -A` there has already
   swept an agent's unreviewed typechecker change into a commit that claims to touch only test
   ledgers.
</content>
