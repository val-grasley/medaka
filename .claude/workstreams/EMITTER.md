# Workstream: EMITTER (native LLVM backend)

**Owns:** the native backend's conformance to `docs/spec/EMITTER-SEMANTICS.md` and the
consolidation arc for `compiler/backend/llvm_emit.mdk` — numeric-semantics defects, the
type-recovery unification, emission-state discipline, and the backend's scaling liabilities.
**Touches:** `compiler/backend/llvm_emit.mdk` (almost exclusively), `runtime/medaka_rt.c`,
`compiler/backend/{emit_support,private_mangle,trmc_analysis}.mdk`, `compiler/ir/core_ir*.mdk`.

```sh
gh issue list --label "ws:emitter" --state open   # the backlog. #362 is the tracking issue + DAG.
```

**Boundary with the neighbors:** a *miscompile* is `ws:soundness` (this workstream co-labels);
`wasm_emit.mdk` is `ws:wasm` — but **every soundness fix that touches `llvm_emit.mdk` owns the
wasm arm too** (#59; a one-backend fix is a half fix). Frontend quadratics are `ws:perf`; the
backend's are co-labeled here because their fix constraints are emitter-specific (below).

---

## Why this workstream exists

The emitter is the 2026-06 "de-risking spike" that **became the canonical backend** without an
architecture pass: 10,013 lines, ~34 module-level Refs, a slice-by-slice accretion header, and
five accreted float-type-recovery heuristics compensating for one missing upstream fact. The
2026-07-16 founding audit (three parallel static passes + binary probes at `40e14b85`) found the
shape familiar from `typecheck.mdk`'s consolidation arc: correct-in-the-large, held together by
manual mirror discipline, quadratic in the small, and with its formal contract implicit. The
contract is now explicit — `docs/spec/EMITTER-SEMANTICS.md` — and this workstream is convergence
to it, in gate-verified steps (DAG in #362).

## The duplicate-family map (grep anchors, not line numbers)

| Family | Members |
|---|---|
| Type recovery ×2 | `typeOf`/`callRetTy`/`paramUseTy`/`inferSigs` (pure twin) ∥ every `emitExpr` arm's inline `(String, LTy)` recovery (#353 — the file admits the twinning at the `typeOf` header) |
| Float-ness heuristics ×5 | `staticIsFloat` · two-pass `inferSigs` (mutates `sigs`!) · `bodyFloatRet`/`closureRetTyRef` · the `RScalar` stamp (the done-right model) · `mainKind` auto-print (#353) |
| Cell allocators ×6 | `emitCtorAlloc` ∥ `emitClosureAlloc` ∥ `emitClosureAllocPatch` ∥ dict cell ∥ atomic Float box ∥ TRMC cons cell (#356 — `$tuple`/`$ref` were already unified; the rest were not) |
| Call emission ×16 | `emitApp`/`emitExternApplied`/`emitIndirect`/`emitImplCall*`/`emitOverApp`/`emitApplyAny`/`emitApplyRuntime`/`emitPap*`/`emitDictApp*`/`emitCtorApp`/`emitMethodDispatch*`/`emitTrmcTailCall` |
| Extern dispatch ladders ×5 | `emitFileExtern`/`emitNumExtern`/`emitNetExtern`/`emitUnicodeExtern`/io+str siblings — the five biggest fns in the file (#358) |
| CExpr walkers ×2 | `freeVars` (trmc_analysis) ∥ `eagerVars` (emit_support) — deliberate siblings, one arm apart |

## ⚠️ THE TRAPS — read before your first PR here

### 1. Fixpoint FIRST, and output gates are not enough
`selfcompile_fixpoint` C3a/C3b before anything else: the reverted isKnownFn HashMap attempt
passed **every** output gate byte-identical and failed ONLY the fixpoint (the emitter couldn't
emit its own new code). Then `typecheck_compiler_source.sh` (the build does not gate on type
errors) and the gates your diff touches.

### 2. The hash-container ban is RETIRED (retested 2026-07-16) — but fixpoint FIRST survives it
The 2026-06-11 "HashMap in llvm_emit breaks the fixpoint" failure (PERF-RESULTS "Attempted &
reverted") **no longer reproduces**: the same shape — a module-level
`Ref (Option (HashMap String Unit))` index, aliased `hash_map` imports, live in `isKnownFn` —
passed `selfcompile_fixpoint` C3a/C3b byte-for-byte on 2026-07-16 (post-#364 main). The
intervening emitter fixes closed the gap without anyone noticing — which is D4's whole point.
Two disciplines survive the retest: (a) a NEW container shape still proves itself against the
fixpoint FIRST — the June failure was invisible to every output gate; the first emitter-source
PR that ships a hash container should also pin the shape as a fixture so the capability cannot
silently regress; (b) weigh the import — `hash_map` is a new-type import (drags its whole impl
surface; every future `hash_map` stdlib change then perturbs the emitter fixpoint/seed).
`OrdMap` (which PERF-RESULTS calls by its 2026-06-11 ancestor name "EMap") stays the default for
constant tables at O(log n); reach for a hash container where O(1) on a hot, large, mutable set
genuinely pays for the import.

### 3. `sigs` is MUTATED mid-emission — memoizing it serves stale Float types
The two-pass Float propagation rewrites the sig table (`f x = x + 1.0` re-infers on pass 2).
A once-built index broke `fn_float_chain` (1/172). `fnNames`/`distinctTypeNames`/ctor tables are
constant and memoize fine; `sigs` is not. The real fix is #353 (carry the fact on the node).

### 4. Two rebuilds to measure anything; a binary's speed comes from the emitter that compiled it
Load the **`benchmark-emitter` skill** before timing a codegen change — one rebuild crosses the
arms and measures the opposite of reality (a real 2.2× win once read as a 2.5× slowdown). Seed
re-mints: `test/refresh_seed.sh` is not idempotent after a codegen change — run it twice; batch
re-mint units (`feedback_defer_seed_remint`).

### 5. Emitter perf defects are mostly PURE SCANS — the alloc gate is physically blind to them
`findByTag`, `lookupAssoc`, `paramUseTy` allocate nothing. Grade per-stage TIME with a pinned
heap (`GC_INITIAL_HEAP_SIZE`), min-of-K — and note `perf_scaling` currently has **no lower/emit
stage at all** (#359 adds it; land it before claiming a perf fix is regression-guarded).

### 6. You own the wasm arm, and parity is not coverage
Any semantics fix here lands in `wasm_emit.mdk` in the same arc (#59). And two backends equally
wrong pass every parity gate (the TMC dict-veto) — pin *coverage* (EXPECT-style, falsified once)
when the fix changes what a backend accepts.

### 7. Emission-state Refs: the miscompile shape is write-then-read-across-paths
The refutable-guard miscompile came from a jump target in a module Ref that another emission path
nulled. Its fix (`labelFallthrough`, node-carried) covers the sentinel half only —
`fallthroughLabelRef` still carries the CTFail target with save+NULL discipline in three emitters
(#354). Do not add new write-then-read Refs; carry the decision on the node (wasm threads the
label as an argument — the reference design). Install-once tables (`returnsSelfTableRef` family)
have no per-program reset (#357) — do not add siblings to that lifecycle.

### 8. Probes: `main` must be a zero-arg Unit value, and `do` is monadic
`main () = …` is a silent no-op; `medaka run` rejects non-Unit value-mains with a diagnostic
while `build` auto-prints them (intentional asymmetry — see #361 for where it gets pinned).
Multi-statement probes use the layout block (`main =` + indented `println`s), not `do`.

### 9. The debunkings are findings too — do not re-file them
> ### 🔁 CLOSING AN ISSUE IS NOT DONE UNTIL THE ROWS BELOW ASSERTING IT ARE DRAINED — **in the SAME commit**
>
> **This ledger went stale exactly once — #305 stayed listed as "the live NaN defect" for hours
> after #484 closed it (2026-07-16).** Each `#N` cited below is an encoded claim that N is still
> the open, live version of that finding — with no derivation and no expiry (#488). When you close
> an issue referenced anywhere in this list (or in `docs/spec/EMITTER-SEMANTICS.md`), run:
> `grep -rn '#<N>' .claude/workstreams/EMITTER.md .claude/workstreams/WASM.md
> docs/spec/EMITTER-SEMANTICS.md` and drain **every** hit in the closing commit — including the
> SIBLING workstream's ledger (#488: #484 drained neither ledger's stale `#305` row on
> merge — `WASM.md`'s copy was only fixed later, separately, in #487; this file's copy sat stale
> until #488 itself). The drain is the ledger OWNER's job; nobody else will do it for you.
>
> A parse-the-refs-and-check-`gh issue view --state` gate is tempting but the same trap #438
> documents for `WASM-SEMANTICS`'s law table applies here too — this prose isn't a structured
> state column, so a naive gate can't tell "closed, correctly reported as fixed" from "closed,
> still asserted open" without a format that doesn't exist yet. Until then: grep + a human/reviewer.

Verified DISPROVED at `40e14b85` (a correction needs the same proof as a filing):
- **IR-text building is NOT quadratic** — prepend into a `Ref (List String)`, one reverse+join.
- **`nan <= nan` over top-level Float bindings is CORRECT natively** (both `False`) — the
  `RScalar` stamp covers the shape the static read predicted would fall to `mdk_value_cmp_raw`.
  The generic/HOF path NaN defect (#305) is now FIXED (#484, 2026-07-16) — IEEE relational ops
  hold on the type-lost path too. The N6 decision (#360: pin the Float `compare`/min/max/sort
  story at NaN) is ALSO decided and implemented — `impl Ord Float` in `stdlib/core.mdk:227-251`
  is IEEE-754 totalOrder, citing #360 in its own header comment — even though the #360 issue
  itself is still open on the tracker (#438 sweep, 2026-07-16: verified the doc is right and the
  tracker is what's stale here; flagging for the tracker owner rather than closing it myself).
- **Bare-Float value-main auto-print works** (`6.0`, not garbage) — SHARED-FLOAT's C4 row is
  stale (#361).
- **User ctors shadowing `Ok`/`Some`/`Cons`… cannot alias the reserved tags** — the resolver
  rejects them (`Duplicate constructor`); the emitter comment claiming otherwise is stale (#361).
- **`dce.mdk` and `core_ir_lower` collectors are clean**; `private_mangle`'s rename map is
  already OrdMap (its one straggler is `pubFnNames`, in #352).
- **`1e+300` prints and re-lexes** — #51 is CLOSED; the round-trip law currently holds where
  probed.
- **Hash containers DO self-compile in llvm_emit now** (retested 2026-07-16, fixpoint C3a/C3b
  YES on the exact June shape) — trap 2 above; the old ban is history, not a rule.

### 10. One compiler-source PR in flight; stage commits by path
Goldens are re-cut from source, never text-merged; and never `git add -A`
(`.claude/workstreams/HARNESS.md`). A change to `llvm_emit.mdk` moves the compiler's own
snapshot goldens — bless them by name in the same commit.

---

## Sequencing

The DAG lives in **#362** (tracking). Shape: Phase 0 semantics defects (#345 ✅ FIXED — Num-poly
Float `%` is fmod on every engine; #346 ✅ FIXED; #360→#305,
#361 — #360's decision is implemented too, see §9 above) → Phase 1 enforcement (#359 ✅ FIXED
2026-07-16 — emit-stage perf arm now shipped, see `docs/spec/WASM-SEMANTICS.md`'s Perf posture
row; #347/#348 identity hardening still open) → Phase 2
mechanical perf under the OrdMap constraint (#349 → #350 → #352; #351 gated) → Phase 3 the
architecture arc (#353 umbrella; #354–#358 staged). Enforcement lands before optimization on
purpose: a perf fix without #359 is un-regressable.

## Reading list

- `docs/spec/EMITTER-SEMANTICS.md` — the contract; §9 maps every law to status + issue.
- `docs/spec/DICT-SEMANTICS.md` §7 — the single-evaluator law this backend refines.
- `compiler/RUNTIME-DESIGN.md` §8 — the ratified value representation (V-laws' source).
- `compiler/EMITTER-GAPS.md` — the E-series closure history + open capability residuals.
- `compiler/SHARED-FLOAT-RESIDUAL-DESIGN.md` — the float-typing case study (why N8 exists).
- `compiler/PERF-RESULTS.md` — the fixpoint-safe-container evidence and the reverted attempts.
- `benchmark-emitter` + `perf-hunt` skills — measurement discipline; two-rebuild rule.
