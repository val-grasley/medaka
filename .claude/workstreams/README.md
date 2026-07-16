# Workstreams

> **The backlog is the GitHub issue tracker. These files are the domain knowledge.**
>
> Work items used to live in markdown lists here. They now live in **GitHub Issues**, because an
> issue **self-drains** — closing it removes it from the backlog — while a markdown list has to be
> *remembered*, and this repo has proved repeatedly that it will not be. When the backlog was rebuilt
> on 2026-07-14, **six of its entries were already fixed** and nobody had noticed.
>
> What stays here is what does *not* belong in an issue: the traps, the collision map, and the
> reasons a whole bug **class** keeps recurring.

---

## Find your work

```sh
gh issue list --label "S0: silent wrongness"          # always start here
gh issue list --label "ws:soundness" --state open     # one workstream
gh issue list --label "needs-repro"                   # claims nobody has reproduced
gh issue list --milestone "0.1.0 public preview"      # the release floor
```

| Label | Meaning | The test |
|---|---|---|
| **`S0: silent wrongness`** | A wrong answer, or destroyed source, **with no error.** | *Would a user ship a bug and never know?* |
| **`S1: loud breakage`** | A crash, a panic, or a rejection where the promise says it works. | *Does it stop someone — with a message?* |
| **`S2: misleading`** | A wrong location, harmful advice, or a check that silently stops checking. | *Does it send the reader somewhere wrong?* |
| **`S3: friction & debt`** | Perf, duplication, ergonomics, code health. | *Does it "just" cost time?* |
| **`verified`** | The repro was run against the binary at a stated SHA and **still fails**. | |
| **`needs-repro`** | An inherited claim. **Nobody has reproduced it.** | |
| **`release-blocker`** | 0.1.0 floor. A 🚢 `S3` outranks a plain `S3`. | |

**S0 beats everything, and soundness beats release** (decided 2026-07-14). The preview ships on a
compiler you can trust, or it does not ship.

---

## 🔬 `verified` vs `needs-repro` — the rule that makes this durable

**Reproduce before you fix. A `needs-repro` issue is a lead, not a fact.**

The backlog was rebuilt on 2026-07-14 by running every inherited claim against the binary at
`e34e2b46`. The results are the argument for the rule:

- **4 of the 11 SQLite-dogfood bugs were already fixed** — including *both* "silent build miscompile"
  P0s that `PLAN.md` was still advertising as open.
- **A "fabricated `1:0` source location"** (the top DIAGNOSTICS item) **would not reproduce on any
  error shape.**
- **A duplicate-definition SEGFAULT** (a top HANDOFF item) now emits a clean *"'foo' is already
  defined at line 1"*.
- **`newtype`, described as "entirely unusable — best value-to-risk item on the board"**, works.
- **An overlapping-tuple-impl "most-specific-resolution bug"** dispatches correctly.
- Meanwhile the **worst bug in the tree** (`fmt` destroying source, #51) was filed in **three docs as
  three unrelated items**, none of which named the shared root cause — a lexer with no exponent form.

Closing an issue as *already fixed* is a **good outcome**. Say so in the PR and delete the ledger rows
that cite it.

**When you close an issue, delete the doc rows that pointed at it.** The tracker is the backlog; a doc
that duplicates it will drift from it.

---

## The workstreams

| Workstream | Owns | Touches |
|---|---|---|
| [COMPILER-SOUNDNESS.md](COMPILER-SOUNDNESS.md) | miscompiles + `check`/`run`/`build` disagreement | `compiler/types/`, `compiler/backend/`, `compiler/eval/` |
| [LANGUAGE.md](LANGUAGE.md) | surface syntax + semantics, lexer → typecheck | `compiler/frontend/`, `compiler/types/` |
| [TOOLING.md](TOOLING.md) | `fmt` / `lint` / `test` / `doc` / CLI ergonomics | `compiler/tools/`, `compiler/driver/` |
| [WASM.md](WASM.md) | the WasmGC backend + its gates | `compiler/backend/wasm_emit.mdk`, `test/wasm/` |
| [EMITTER.md](EMITTER.md) | the native LLVM backend: `EMITTER-SEMANTICS` conformance + consolidation arc | `compiler/backend/llvm_emit.mdk`, `runtime/medaka_rt.c` |
| [DIAGNOSTICS.md](DIAGNOSTICS.md) | error-message quality + source locations | `compiler/driver/diagnostics.mdk`, `compiler/frontend/` |
| [TESTING.md](TESTING.md) | gates, goldens, oracles, CI | `test/`, `.github/` |
| [RELEASE.md](RELEASE.md) 🚢 | the 0.1.0 public preview | `docs/`, packaging, `playground/` |
| [PERF.md](PERF.md) | quadratics + constant factors | `compiler/frontend/resolve.mdk`, `compiler/tools/check.mdk` |
| [TYPECHECK.md](TYPECHECK.md) | the typechecker consolidation arc: entailment engine, driver unification, state discipline | `compiler/types/typecheck.mdk` |
| [STDLIB.md](STDLIB.md) | missing stdlib/support functions | `stdlib/`, `compiler/support/util.mdk` |
| [HARNESS.md](HARNESS.md) | the **agent harness** — not the repo | — |

**[HARNESS.md](HARNESS.md) is not a backlog — it is a hazard briefing.** Read it before you spawn an
agent, whatever workstream you are on.

---

## Collision map — read before running two of these at once

The unit of collision is a **file**, not a topic.

- **Safe in parallel:** TESTING (`test/`) × RELEASE (`docs/`, packaging, `playground/`) × HARNESS.
  Disjoint trees, no compiler source between them.
- **SOUNDNESS × LANGUAGE × DIAGNOSTICS × TYPECHECK all live in `compiler/frontend/` + `compiler/types/`.** Run
  **one at a time** unless the items are provably in different files. `typecheck.mdk` is the hottest
  file in the repo, and it is a **13k-line file with two textually duplicated typecheck bodies**
  (#80). TYPECHECK (the consolidation arc) rewrites that file's structure — while one of its PRs is
  in flight, treat the whole file as locked for every other workstream.
- **WASM × SOUNDNESS.** A miscompile fix usually needs *both* emitters — that is exactly how #59
  happened (an LLVM fix that never reached wasm; the workaround was reverted on the strength of a
  green script, and only the wasm tandem gate caught it). **If your soundness item touches
  `llvm_emit.mdk`, you own the wasm arm too.**
- **PERF × SOUNDNESS.** `resolve.mdk` (PERF) and `typecheck.mdk`/`llvm_emit.mdk` (SOUNDNESS) usually
  merge cleanly — but see rule 1.
- **EMITTER × SOUNDNESS × WASM all reach `llvm_emit.mdk` (and a semantics fix there owns the wasm
  arm too).** EMITTER is the consolidation arc for that file — while one of its PRs is in flight,
  treat `compiler/backend/llvm_emit.mdk` as locked for the other workstreams, exactly as TYPECHECK
  locks `typecheck.mdk`. Emitter changes also perturb the SEED — batch re-mint units.
- **STDLIB × everything.** `stdlib/core.mdk` is the **prelude**. Touching it moves every snapshot
  golden, the LSP completion list, and the doctest line numbers, and it perturbs the fixpoint. Land
  core changes **at a checkpoint, alone**.

### ⚠️ Three rules that are not negotiable

1. **A clean auto-merge is NOT agreement.** Two green branches have merged cleanly into a *crashing*
   tree: one had added a caller into machinery the other was re-signing, on different lines, so there
   was no conflict marker. If two workstreams touched the same subsystem, **grep the merged tree for
   every caller of any signature that changed** and run `typecheck_compiler_source.sh` — it is the
   *only* thing that catches a stale caller, because `make medaka` does not gate on type errors.

2. **STAGE COMMITS BY PATH. NEVER `git add -A`.** The harness misroutes agents into the orchestrator's
   worktree ([HARNESS.md](HARNESS.md)). A `git add -A` there has already swept an agent's unreviewed
   typechecker change into a commit whose message claimed it touched only test ledgers.

3. **Keep at most ONE compiler-source PR in flight.** The merge queue removes the O(N²) *CI* cost, not
   the O(N²) *golden* cost — goldens are re-cut from source, never text-merged, so two compiler
   branches always fight over the same golden files.
</content>
