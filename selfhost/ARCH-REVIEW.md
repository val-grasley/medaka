# Medaka Architecture Review

Living record of the architectural-review workstream. Each pass is read-only and
critical; findings here feed deliberate refactors (not auto-applied). Pass 1 is
breadth (high-level architecture); later passes drill into individual modules/stages.

---

## PASS 1 — High-level architecture (breadth) — 2026-06-14

Read-only critical evaluation of the whole self-hosted compiler (~37k lines Medaka +
~17k OCaml). Methodology: orientation docs → module/import graph → strategic
spot-reads of the giants; no line-by-line audit (deferred to later passes). The four
orchestrator priors were framed as hypotheses to confirm/refute, not conclusions.

### Executive judgment
The architecture is **healthy and well-factored** for a self-hosting compiler of this
size. The pipeline is a clean linear sequence of single-responsibility modules with a
real, equivalence-validated Core IR seam, and the OCaml→native canonical flip is
genuinely complete — the codebase is in good shape for a rigorous refactor. The
**single biggest structural issue is `selfhost/types/typecheck.mdk`**: 6,916 lines
carrying ~48 module-level `Ref`s (~13 solely dispatch/dict route-stamping). Complexity,
mutable state, and coupling all concentrate there; it is the one module that genuinely
warrants decomposition. Most everything else (entry proliferation, multiple map types,
the OCaml duality) is essential or cosmetic, not architectural rot.

### Prioritized findings

**1. `typecheck.mdk` is a 7k-line god-module with concentrated mutable state — High impact / High effort.**
6,916 lines; **48 top-level `Ref`s** (vs 4 in eval, 18 in emitter). Only 4 are core HM
state (`tyvarCounter`, `currentLevel`, `effvarCounter`, `curEffect`); **~13 are
dispatch/dict-passing machinery** (`pendingSites`, `pendingDictApps`, `funConstraintsRef`,
`crossModuleFunConstraintsRef`, `methodConstraintsRef`, `pendingRecDictApps`,
`pendingRLocalSites`, `activeDictVars`, `methodIfaceParamsRef`, …) + ~5 dict-layer
housekeeping/probes. The `resetState` discipline is fragile — source comments track
which Refs are/aren't cleared per-module; `typeErrorsSticky` exists purely to paper
over `resetState` wiping the error accumulator mid-run (the G1 soundness fix, and the
same class as the 2026-06-14 imported-module error-accumulation bug). This module is
the blast-radius center (collapsed driver, dispatch gaps #21/#55, the argStamp fork all
live here).

**2. The `pending*` deferred-mutation Refs are ESSENTIAL, not accidental — informational (refutes prior b).**
Collect-sites-then-patch-routes-after-unification is **forced by HM**: a method site's
route depends on which tyvar-id *survives* unification, knowable only post-inference; a
one-pass stamp reads a stale unlinked var. The OCaml `lib/typecheck.ml` has the same
coupling. So the Refs' *existence* is essential; only their **organization** (13
scattered module globals vs one threaded `DispatchState` record) is the smell. Refactor
= bundle, don't eliminate.

**3. Two execution engines (AST tree-walker + LLVM) only partly share the Core IR seam — Medium / Medium.**
Core IR (`ir/core_ir.mdk`) is a clean, documented, equivalence-validated interface
(DESUGARED / PRIMITIVE / LEXICALLY-ADDRESSED / DICTS-EXPLICIT / EFFECTS-ERASED),
consumed by lower/eval/sexp×2/`llvm_emit`. **But the canonical runtime paths bypass
it**: `medaka_cli` wires `run`/`test`/`repl`/`doctest` straight to the AST tree-walker
(`eval.evalModulesOutput`); only native `build` goes AST→Core IR→LLVM. So Core IR is
the *backend* seam, not a universal seam — the tree-walker is a second back-end
consuming the elaborated AST directly. `core_ir_eval.mdk` (505 lines) is a Core-IR
tree-walker used ONLY as a differential oracle, not on any product path. Dispatch logic
is **NOT** duplicated across engines (refutes a sub-prior): routes computed once in
typecheck; eval and core_ir_eval share `methodAtNarrow`/`applyDicts`/`narrowMethod`;
only `llvm_emit` re-emits the route as LLVM text (necessarily). WasmGC portability is
**aspirational** — the seam is real/serializable, but there is exactly one native
backend; the second-backend claim is unexercised design intent.

**4. `entries/` proliferation (67 files) is JUSTIFIED differential-test scaffolding — Low / Low (refutes prior c).**
67 entries ≈ 77 gate scripts, ~1:1; each a thin driver exposing one pipeline stage's
output for byte-diffing. The real CLI is **one** file (`driver/medaka_cli.mdk`, 419
lines, 8 subcommands). Only **6 entries are unreferenced** by any gate
(`dispatch_argclass_main`, `dispatch_inventory_main`, `llvm_emit_gaps_main`,
`loader_main`, `loc_probe_main`, `perf_main`) — dead probes safe to prune. `_main` vs
`_batch` (single-file vs corpus) is a real harness distinction. Trim the 6 strays at
most.

**5. Multiple map/set implementations — Medium / Medium (contained duplication).**
`SMap` (weight-balanced tree, inline in `typecheck.mdk:1536`), `EMap` (inline in
`llvm_emit.mdk:654`), plus stdlib `map`/`set`/`hash_map`/`hash_set`, plus pervasive
`lookupAssoc` assoc-lists in `support/util.mdk`. The two inline tree-maps are
near-identical, privately re-declared because the two hottest compiler modules each
needed an ordered map and didn't import stdlib `map.mdk` into the bootstrap. Genuine
concept-duplication, though contained. These were the O(N²)→O(N·log N) self-compile
perf fixes (PERF-RESULTS) — a shared `support/ordmap.mdk` would unify them **without
regressing** the perf the inline copies were tuned for.

**6. OCaml `lib/` removal is cleanly supported — Low risk / informational (refutes the entanglement prior).**
Gate re-rooting is **real and done**: 84/87 gates are OCaml-free (native `test/bin/*`
oracles, built via the OCaml-free `make medaka` from the gz IR seed). Only **4 optional
scripts** touch `_build/default` (`bench.sh`, `capture_goldens.sh`,
`profile_selfhost.sh`, `refresh_seed.sh`) — all capture/profiling, guarded/skippable.
Native stdlib loads from disk via `MEDAKA_ROOT`. **No hard blocker to `rm -rf lib bin
dev gen`** beyond losing the optional capture harnesses + `dev/*.ml` oracle probes (17
files, no longer wired to regular gates).

### What's GOOD (preserve in the refactor)
- **Folder taxonomy is coherent** — `frontend/types/ir/backend/eval/tools/driver/support/entries`
  mirrors the pipeline; imports respect layering (backend←ir←frontend; no upward leaks).
- **Core IR seam is a model interface** — documented contract, equivalence-validated,
  serializable, round-trip-gated.
- **Dispatch decision is computed once, consumed many** — right abstraction; engines
  share narrowing helpers.
- **Differential-testing methodology is the load-bearing strength** — preserve the
  entries↔gates structure.

### Verdict on the 4 pressure-test hypotheses
- **(a) Typechecker Refs = real smell, wide blast radius — MIXED.** Blast radius real
  (48 Refs, fragile reset, `typeErrorsSticky` soundness patch), but deferred-route Refs
  are essential to HM. Smell is **organization** (scatter), not existence → consolidate.
- **(b) Dict-passing/dispatch = accidental complexity — REFUTED.** HM-forced
  deferred-mutation; routes computed once and shared; no cross-engine decision
  duplication. Essential, reasonably abstracted. The `argStampEnabled` *fork* is the lone
  incidental piece — already slated for retirement (`ARGSTAMP-UNIFY-PLAN.md`).
- **(c) `entries/` count = bloat — REFUTED.** 1:1 differential-gate scaffolding; one
  real CLI; 6 dead probes.
- **(d) Core IR seam leakier than docs claim — MIXED → mostly refuted.** Seam itself is
  clean/validated; the "leak" is scope: canonical `run`/`test`/`repl` bypass Core IR
  (AST tree-walker), so it's backend-only, not the universal IR the WasmGC framing
  implies.

Docs were **less drifted** than expected (gate re-rooting, Core IR contract,
dispatch-once all accurate). Lone framing overstatement: the WasmGC second-backend
portability (intent, not built).

### Recommended next passes (ranked)
1. **`typecheck.mdk` deep-dive (highest value).** Map the ~13 dispatch Refs into a
   candidate `DispatchState`/`InferenceState` bundle; audit the `resetState`
   clear/no-clear matrix for correctness hazards; scope splitting the file along
   HM-core / dispatch-routing / module-driver seams.
2. **Execution-engine unification.** Decide whether to retire the AST tree-walker in
   favor of running everything through Core IR (`core_ir_eval` already exists as the
   oracle); what `run`/`test`/`repl` would need; whether two AST-level consumers
   (tree-walker + lowerer) are worth keeping post-`lib/` removal.
3. **`argStampEnabled` fork retirement** (already planned) — verify the plan eliminates
   the two-path inference behavior rather than hiding it; directly de-risks finding #1.
4. **Shared ordered-map consolidation** — unify `SMap`/`EMap`/stdlib `map` behind one
   `support` module without regressing the perf the inline copies were tuned for.
