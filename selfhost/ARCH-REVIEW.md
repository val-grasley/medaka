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

**Note (2026-06-18):** the gap-census and dispatch-inventory entry points (`dispatch_argclass_main`,
`dispatch_inventory_main`, `llvm_emit_gaps_main`) were debugging/gap-hunting probes created
during the Stage-3 gap-closure arc. The dispatch gaps they inventoried are all closed
(#54/#55/#50/#21 — see `selfhost/DISPATCH-GAPS-SCOPE.md`). These entries are
**consumed only by the dead sections they were built to diagnose** — they are safe to
prune and any sections in this review that reference them as investigation entry points
are historical (the gaps they pointed at no longer exist).

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

---

## PASS 2 — `typecheck.mdk` deep-dive (refactor-scoping) — 2026-06-14

Deep read of `selfhost/types/typecheck.mdk` (6,916 lines, **49** module-level `Ref`s —
pass-1's "48" undercounted by one). Read-only; produces a sequenced plan, implements
nothing.

### Ref inventory (49), classified
- **(i) Core HM state — 7:** `tyvarCounter`, `currentLevel`, `effvarCounter`,
  `curEffect`, `occursCheckFailed`, `recordsRef`, `sigNameSetRef`.
- **(ii) Dispatch / dict route-stamping — 22** (pass-1 said ~13; real count is HALF the
  module's mutable state): 8 deferred-site collectors (`pendingSites`,
  `pendingBinopSites`, `pendingRLocalSites`, `pendingImplObligations`, `pendingDictApps`,
  `pendingMethodDicts`, `pendingRecDictApps`, `pendingArgStamps`); 7 route tables
  (`activeDictVars`, `funConstraintsRef`, `methodConstraintsRef`, `methodIfaceParamsRef`,
  `methodDispatchIdxRef`, `standaloneValuesRef`, `argDispatchIdxRef`); 2 scope context
  (`currentFn`, `currentImplBody`); 5 promotion-discovery (`methodSiteFns`, `dictAppFns`,
  `promotedRef`, `dictEligibleRef`, `dictEligibleSetRef`).
- **(iii) Cross-module accumulation — 1:** `crossModuleFunConstraintsRef` (survives reset).
- **(iv) Path-mode flags — 3:** `implInferEnabled`, `argStampEnabled`, `coherenceUserDecls`.
- **(v) Diagnostics — 5:** `typeErrors`, `typeErrorsSticky`, `currentLoc`, `matchWarnings`,
  `matchOracle`.
- **(vi) Probe/vestigial — 4 + Tarjan 6:** probe cluster (`argMeasureEnabled`,
  `argSiteResults`, `appliedCounts`, `pendingArgSites`) consumed ONLY by the dead entry
  `dispatch_argclass_main`; Tarjan SCC `tj*` (self-contained, 5387–5460).

### `resetState` hazard audit (the soundness core)
`resetState` clears 24 Refs; **25 deliberately survive**, each load-bearing, the
discipline encoded in PROSE not types. Ranked by soundness risk:
1. **`typeErrorsSticky` (critical).** Multi-module path resets per module → `typeErrors`
   keeps only the LAST module's errors; sticky is the ONLY thing aborting on an error in
   any non-last module. Any code that pushes an error but reads `typeErrors` (not
   `hadTypeErrors`) silently drops it — the EXACT class of G1 AND the 2026-06-14
   imported-module bug. **Already recurred once.** NOT fixable by consolidation — inherent
   to per-module reset + whole-graph error reporting.
2. **`crossModuleFunConstraintsRef` (high).** Reset-then-reseed dance:
   `discoverPromotedModules` does `resetState()` then manually restores 3 refs
   (sticky + typeErrors + this). Miss a restore → dropped dict arity → under-applied dict →
   silent partial closure (Phase-134 failure mode).
3. **Mandatory re-seed tables (high):** `standaloneValuesRef`/`methodIfaceParamsRef`/
   `methodDispatchIdxRef` wiped then rebuilt per module; a future step inserted between
   reset and rebuild that reads them → `None` → dropped Ord dict → SIGSEGV (gap #44 mode).

**Verdict:** robust only because the comments are exhaustive; no mechanism prevents a
future edit from clearing a survivor or reading a not-yet-reseeded table. "One edit away"
from another dropped-error/dropped-dict miscompile.

### `DispatchState` consolidation — partial win, honest
Bundle dispatch Groups A (8 collectors) + B (7 tables) + C (2 scope) + D (5 discovery)
into a single `Ref DispatchState` record (NOT threading — these are read at
inferVar/inferMethodAt depth across the 25-arm `infer` walk; threading a record through
every arm is a massive change to the most delicate function). **Real win:** `resetState`
becomes one record assignment; the `discoverPromotedModules` reset/reseed dance collapses
to save/restore-record (shrinks hazard #2). **The catch:** must DELIBERATELY EXCLUDE the
diagnostics Refs (v) — `typeErrorsSticky` is sound *because* it lives outside any
reset-bundle; bundling it re-introduces hazard #1. So: shrinks the *dispatch* reset
surface (22→1), does NOT fix the *soundness* foot-gun. Sell as "shrink dispatch reset
surface," not "fix the reset hazard."

### File-split verdict — MOSTLY NEGATIVE (refutes pass-1's main split proposal)
- **HM-core / dispatch split is NET-NEGATIVE.** Dispatch Refs are read INSIDE `infer`
  (inferVar/inferMethodAt/inferBinopE); inference and route-collection are mutually
  recursive through the same 25-arm dispatch. Splitting → either re-export 22 mutable
  globals across a no-`.mli` boundary (coupling becomes invisible — worse) or deep-thread
  the record across files. Scatters an essential tight core. **Don't.**
- **Module-driver split is weak** — the entry points depend on the survival/reseed
  invariants; extracting them spans the invariants across two files.
- **Clean extractions:** Tarjan SCC (5387–5460, 6 Refs, pure `List (String,List String) ->
  List (List String)`) → `support/scc.mdk`. Optionally the pretty-printer (`pp*`/`cohPp*`,
  already local-Ref-threaded) → `types/typrint.mdk` (cosmetic).
- The file is big because the typechecker is irreducibly complex, not because unrelated
  things were dumped together. **Consolidate + unify; do not decompose the core.**

### Two-entry-point coherence — REAL residual divergence risk (the key finding)
The driver collapse unified the eval/build DRIVER, but two typecheck BODIES still exist
textually duplicated: `checkProgramSeeded` (single-file) ∥ `checkModuleFullImpl`
(per-module) — comments literally say "mirrors checkProgramSeeded"; **mirror discipline is
manual.** Plus the resolve-chain runs at two call sites with two orderings. Any new resolve
pass / `pending*` collector / reseed table must be added to BOTH. **The 2026-06-14
imported-module bug was exactly a mirror miss.** Unifying these two bodies into one shared
helper is the real soundness lever — the collapse finished the driver unification but left
the typecheck-body unification half-done.

### Sequenced refactor recommendation (safest → riskiest; each gate-verified byte-identical + fixpoint)
1. **Prune dead probes** — delete dead entries `dispatch_argclass_main` + `loc_probe_main`,
   then remove the now-dead probe Refs (4) + `currentLocString` + the `if
   argMeasureEnabled` branch in `infer`'s EApp arm. ~80 LOC, cleans the hot path. Trivially
   byte-identical (no gate touches probe paths).
2. **Extract Tarjan SCC** → `support/scc.mdk` (6 Refs out, clean interface). Gate: letrec
   ordering identical (drives the perf-tuned `processTopGroups`).
3. **Finish ARGSTAMP-UNIFY** (already planned) — collapses 48 fork sites; do BEFORE the
   DispatchState bundle so the bundle isn't designed around a vanishing flag.
4. **Unify the two typecheck bodies** (highest-value soundness step) — one shared helper
   parameterized by single-vs-module seed diffs + one resolve-chain helper. Kills the
   manual-mirror divergence class (the imported-module bug). Gate: both single-file +
   multi-module goldens byte-identical; add a multi-module regression (the class only
   surfaces multi-module).
5. **Bundle dispatch Refs into `Ref DispatchState`** (Groups A–D; diagnostics EXCLUDED).
   Highest churn; do last. Gate: full suite byte-identical + fixpoint.
6. **(Optional) Extract pretty-printer** — low risk, modest value; defer.

**Do NOT** attempt the HM-core/dispatch file split. The wins are consolidation (5) +
mirror-unification (4), not decomposition. Hazard #1 (`typeErrorsSticky`) is inherent and
unfixable by refactor — the best mitigation is (4): one place to reason about it.

---

## Implementation corrections (from executing the pipeline) — 2026-06-14

**Step 1 (dead-probe prune) — DONE** (main `710f707`): removed 4 dead Refs + ArgSite +
~189 LOC arg-measurement/loc-probe machinery from typecheck.mdk + 6 dead entries (932
LOC); kept the live look-alikes (`recordArgSiteFn`, `pendingArgStamps`). Gates
byte-identical + fixpoint YES.

**Step 2 (Tarjan + printer extractions) — BLOCKED, both deferred/dropped.** Pass-2
under-estimated the coupling:
- **Tarjan SCC is NOT pure over `(String, List String)`** — it takes an `SMap` adjacency
  directly and its state is `SMap`-backed (`tjIndex`/`tjLow`/`tjOn : Ref (SMap …)`).
  `SMap` (inline `typecheck.mdk:1422–1484`, backs `TcEnv`, perf-load-bearing — the Tarjan
  rewrite cut typecheck ~5×) can't be referenced from `support/` (layering). **SCC
  extraction is GATED ON the ordered-map consolidation** (move `SMap`→`support/` first),
  not independent. Cluster for the later move: `tarjanSCCs`/`tarjanAll`/`tjVisit`/
  `strongconnect`/… + 6 `tj*` Refs (`typecheck.mdk:5272–5345`, ~73 LOC).
- **Printer extraction → circular import** (depends on `normalize` (50 uses)/`effrowLabels`/
  `lookupAssocI` which stay in typecheck). Cosmetic; **DROPPED**.

**Resequenced pipeline:** the extractions are cosmetic AND entangled; the ordered-map
consolidation is their prerequisite. Revised priority: (1) dead-probe ✓ → (2)
`argStampEnabled` retirement [real value, no extraction needed] → (3) `DispatchState`
bundle → (ordered-map consolidation + the now-unblocked Tarjan extraction as an optional
later tidy-up). The pretty-printer extraction is dropped.

---

## PASS 3 — `selfhost/backend/llvm_emit.mdk` (native LLVM emitter) — 2026-06-14

Read-only review of the OTHER 7k-line giant (7,212 lines). The key question: is it
more decomposable than the typechecker (pass 2 found that irreducible)?

### Executive judgment
**Healthier and MORE decomposable than `typecheck.mdk` — the headline.** Where `infer`
is irreducibly coupled (mutual recursion sharing live mutable state), the emitter's core
is **structural tree-recursion**: `emitExpr` (923) is a clean 25-arm node dispatch, each
arm a self-contained lowering, with special cases (TRMC, default-methods) isolated into
their own functions rather than woven in. There IS a real ~2,000–3,000-line core-file
reduction available here that the typechecker could not offer. Biggest concrete issue:
the `Emit` 10-field POSITIONAL record (cheap, high-value fix).

### Prioritized findings
1. **`Emit` 10-field positional record (`llvm_emit.mdk:605`) — HIGH value / LOW effort.**
   Ten same-shaped `Ref (List …)` fields disambiguated only by underscore-position across
   ~11 hand-written accessors (`freshId`/`emit`/`bufRef`/`lamsRef`/`fnNames`/`ctorTable`/
   `recFieldTable`/`implEntriesOf`/`ctorTypeTable`/`sigTable`/`globalsRegRef`) + 2
   construction sites (6970, 7173). A buf/fns swap wouldn't typecheck (all same shape).
   **Fix = named-field record** — mechanical, byte-identical, fixpoint-safe. The clearest
   fixable defect in the file.
2. **Mutable-state split (Emit vs ~18 module globals) is PRINCIPLED, not accidental.** The
   module globals (`returnsSelfTableRef`/`methodIfaceTableRef`/…, 181–486) are install-once
   read-only config pushed in by the entries from `core_ir_lower.mdk` BEFORE `emitProgram` —
   a deliberate interface seam. The Emit record is per-emission threaded state. Correct
   split. The one genuinely-redundant bit: memoization refs (`knownFnMapRef`/`ctorMapRef`/
   `sigMapRef`, 680–700) shadow Emit fields for perf — justified, minor.
3. **Emit dispatch core is CLEAN (cleaner than `infer`) — GOOD, preserve.** 25-arm
   structural dispatch, no shared accumulator, no fixpoint; route lowering `emitMethod`
   (2436) is a clean 5-way `match route` mirroring the interpreter's arms. The one
   intricate spot (`emitTree`/`emitLeaf`, the decision-tree match compiler) is essential +
   contained.
4. **TRMC is the BEST-architected subsystem — GOOD.** Entangles the main path via exactly
   one ref (`trmcCtxRef`) + one branch point; the eligibility analysis is pure `CExpr`
   analysis (no LLVM), genuinely WasmGC-portable as the design claims. Only `emitTrmcCtor`
   is backend-specific.
5. **String-building coherent — leave it.** O(1)-prepend buffer; the `stringConcat`
   segment-emit was tried + reverted (no win — see PERF-RESULTS).
6. **Gap-tolerance (46 `gapE`/`gapU`) — LOW.** Deliberate self-compile crutch (record-and-
   skip), not dead code; flag so a reviewer doesn't mistake a `gapE` for a defect.

### Decomposability verdict — MORE decomposable than typecheck; real splits exist
- **Preamble + runtime-decls (`emitPreamble`, ~7002–7094) → `backend/llvm_preamble.mdk`** —
  pure constant output, zero coupling beyond the buffer. Trivial, ~100 lines.
- **TRMC eligibility analysis → shared Core-IR module** — pure `CExpr` analysis; but GATE
  on WasmGC (one consumer today; the design already plans this).
- **Type-lowering (`typeOf`/`tagToLTy`/`LTy`/`FnSig`) → `backend/llvm_lty.mdk`** —
  self-contained; modest shrink.
- NOT separable: `emitExpr`/`emitApp`/`emitMethod`/`emitTree` (the value+decision-tree
  compiler core) — but smaller/more structural than typecheck's `infer`.

### Duplication with the interpreter — CLEAN split
The route re-emission realizes-as-LLVM what the interpreter executes; the *decision* is
shared (computed by typecheck/dict-pass), only the *realization* differs. Irreducible
codegen-vs-interpret boundary; unifying it is a large speculative refactor with no payoff.
The one real shared candidate is the TRMC eligibility analysis (above).

### Recommended next actions (ranked)
1. **`Emit` → named-field record** (footgun-killer; byte-identical, fixpoint-gated).
2. **Lift `emitPreamble` → `backend/llvm_preamble.mdk`** (~100 lines, zero risk).
3. Lift TRMC analysis to shared Core-IR — **gate on WasmGC** (not now).
4. Lift `typeOf`/`LTy` → `backend/llvm_lty.mdk` (modest).
5. **Leave** the dispatch core, decision-tree compiler, string buffer, install tables, and
   the codegen/interpret split — essential or correctly factored.

Net: unlike the typechecker, the emitter's size is PARTLY incidental — a real ~30%
core-file reduction is available at low risk. Do 1 + 2 now; gate 3 on WasmGC.
