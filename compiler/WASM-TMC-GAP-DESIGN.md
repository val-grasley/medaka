# WASM-TMC-GAP-DESIGN.md — TMC does not fire on constrained (dict-passed) builders

**Status:** FIXED (Stages 0–2 + 4 landed 2026-07-14; Stage 3 — the (b′) group dict
relax — deliberately deferred, the dict veto stays on `dispNonDict` for groups).
⚠️ One claim in §2.1 below proved WRONG during implementation: the self-call of a
constrained define is a **`CDict self routes` spine, not a `CVar self` spine**, so
`isSelfSatApp` did NOT "already match it" — the analysis had to learn the CDict head
(`isSelfHead`/`isSelfSatApp` saturation = |args| + |routes| == lowered arity, routes
identity-forwarded), `selfFree` needed a `mentionsSelfDict` structural walk (freeVars
is as blind to a CDict fn name as to a CMethod name), and both leaf emitters now skip
the loop-invariant leading dict slots when storing recomputed args.  The rest of the
diagnosis held.  Originally: diagnosed 2026-07-14. The TMC-parity arc
(`compiler/TRMC-DESIGN.md` Phase 3, `compiler/WASMGC-TRMC-DESIGN.md` §12) is
*correct about parity*: both backends TMC the same functions, on the probe path
**and** on the shipping path. What neither backend does is TMC a function that
carries a leading `$dict` parameter — and every unannotated polymorphic list
builder in user code is exactly that. `test/wasm/fixtures/w_deep_append.mdk` and
`test/wasm/fixtures/w_trmc_deep_cons.mdk` stack-overflow under `medaka build
--target wasm`; native survives the *same* un-transformed code only because
`runtime/medaka_rt.c` gives it a 256 MB worker stack. Companion to
`compiler/TRMC-DESIGN.md` (§Phase 2(b), the deferral this document falsifies) and
`compiler/WASMGC-TRMC-DESIGN.md`.

---

## 0. Verdict up front

The reported symptom is real and reproduces. **The hypothesis on record about its
cause — that `#18a` made `++` a `Semigroup` method, so the shipping path stops
reaching the iterative `$mdk_append` intrinsic and instead dispatches to a
recursive stdlib `append` — is REFUTED.** Three independent facts kill it:

1. **`w_trmc_deep_cons.mdk` contains no `++` at all.** It is `upto` + `lenAcc`. A
   theory about `++` cannot explain a fixture that never appends. The two fixtures
   fail for **one** shared reason, and `++` is not it.
2. **`++` on a `List` never routes to a `Semigroup` method.** `binopBuiltinHead`
   (`compiler/types/typecheck.mdk:7652`) reads
   `binopBuiltinHead "append" tag = binopPrimitiveHead tag || tag == "List"` —
   `List` is explicitly excluded from the `recordBinopSite`/`resolveBinopSites`
   dispatch seam, so the site is never stamped and `rewriteBinopExpr` leaves it a
   literal `EBinOp "++"`. Verified in the shipping WAT: the program's `__init`
   (the block that forces `main`) calls `$w_deep_append__upto` twice, then
   **`$mdk_append` once** — the iterative intrinsic, reached exactly as designed.
3. **Even if it did route, there is no recursive `append` to route to.** Stdlib's
   `impl Semigroup (List a)` is `append xs ys = xs ++ ys` (`stdlib/core.mdk:116`),
   which lowers to `(func $mdk_impl_List_append … call $mdk_append return)` — a
   one-line forwarder to the same intrinsic. In the shipping WAT for
   `w_deep_append` it has **zero callers**.

**The real cause.** On the shipping (typecheck-bearing) path, `upto` is generalized
to a constrained scheme (`>` ⇒ `Ord`, `+`/`1` ⇒ `Num`), so `dictPass` prepends a
leading `$dict_…` parameter. **Both** TMC eligibility gates —
`dispNonDict` (`compiler/backend/trmc_analysis.mdk:565`) on the WasmGC side and
`trmcNonDict` (`compiler/backend/llvm_emit.mdk:6645`) on the LLVM side — reject any
clause whose first pattern is a `$dict_…` `PVar`. So TMC declines, on **both**
backends, and the builder recurses one frame per cons cell.

This is **not a parity hole. Parity holds.** It is a *coverage* hole that both
backends share identically — which is precisely why a parity gate could never see
it (§3).

---

## 1. Reproduction (all output below is real, observed on this worktree)

Setup: `make medaka`; `sh test/wasm/build_wasm_oracle.sh`;
`export MEDAKA_EMITTER=$PWD/medaka_emitter MEDAKA_WASM_EMITTER=$PWD/test/bin/wasm_emit_modules_main`.

| fixture | native (`medaka build`) | wasm (`medaka build --target wasm`) |
|---|---|---|
| `test/wasm/fixtures/w_trmc_deep_cons.mdk` | `2000000`, exit 0 | `Maximum call stack size exceeded` |
| `test/wasm/fixtures/w_deep_append.mdk` | `100000`, exit 0 | `Maximum call stack size exceeded` |

### 1.1 What `upto` lowers to, per path (`--keep-ir`)

| emit path | emitted `upto` | census marker |
|---|---|---|
| `test/bin/llvm_emit_main` (probe — parse→desugar→annotate→lower→emit, **no typecheck, no prelude**) | *(TMC loop)* | `; tmc: upto trmc` |
| `test/bin/wasm_emit_main` (probe) | `(func $upto (param ×2) …)` | `;; tmc: upto trmc` |
| `medaka build` → `medaka_emitter` (**shipping**) | `define i64 @mdk_w_trmc_deep_cons__upto(i64 %arg0, i64 %arg1, i64 %arg2)` + a real recursive `call` | *(absent)* |
| `medaka build --target wasm` → `test/bin/wasm_emit_modules_main` (**shipping**) | `(func $w_trmc_deep_cons__upto (param ×3) …)`, `(local $$dict_w_trmc_deep_cons__upto_0 …)` | *(absent)* |

**Arity 3 for a 2-argument source function.** `%arg0` is the dict; the shipping
native call site passes `@mdk_dc_3` into all of `upto`, `lenAcc`, `println`. The
complete shipping marker set, on **both** backends, for **both** fixtures is:

```
; tmc: impl_List_map trmc          ;; tmc: impl_List_map trmc
; tmc: impl_List_filterMap trmc    ;; tmc: impl_List_filterMap trmc
```

Byte-identical across backends — the parity gate's green light is *honest*. It is
also completely uninformative: the function the fixture exists to transform is
absent from both sets.

### 1.2 The minimal pair — the dict is the whole discriminator

Same program, same shipping emitters; the only change is a **monomorphic type
signature** on the two top-level functions (`upto : Int -> Int -> List Int`,
`lenAcc : Int -> List Int -> Int`), which removes the constraint and therefore the
dict param:

```
;; tmc: sigged__upto trmc            <- marker appears
(func $sigged__upto (param ×2) …)    <- arity back to 2
```

and the resulting `.wasm`, run under `node test/wasm/run.js`:

- signature-annotated `w_trmc_deep_cons` → **`2000000`**
- signature-annotated `w_deep_append`    → **`100000`**

Both fixtures pass on the shipping wasm path the moment the dict disappears. That
is the diagnosis, end to end: **not `++`, not `$mdk_append`, not the wasm emit — the
dict param.**

---

## 2. Root cause: the F2(b) deferral audited the wrong population

`compiler/TRMC-DESIGN.md` §"Phase 2 (b) — SCOPED & DEFERRED" defers F2(b)
(dict-carrying TMC) with this justification:

> **F2(b) — dict-carrying / eta-reshaped constrained cons-tail impls.** No real
> target — exhaustively verified ABSENT: only `Eq`/`Ord`/`Debug`/`Display`/`Hashable`
> instances carry `requires`, and none BUILDS a list.

That audit is accurate — **about impls.** But `trmcNonDict` does not gate only the
impl path. It gates **both**:

- `trmcImplTry` (`compiler/backend/llvm_emit.mdk:4533`) — the impl path the audit looked at, and
- `trmcTryFn`   (`compiler/backend/llvm_emit.mdk:6627`) — the **top-level** path, which the audit did not look at.

The WasmGC peer is the same shape: `dispNonDict` gates `wasmTrmcTry`
(`compiler/backend/wasm_emit.mdk:5542`), `wTrmcImplTry` (`:5571`), and the
dispatch-graph root/growth (`compiler/backend/trmc_analysis.mdk:605` / `:806`).

The population that actually carries dicts on the top-level path is not
"constrained stdlib impls" — that set really is empty. It is **every generalized
polymorphic function in user code**, and any list builder that touches `+`, `>`,
`==` on its element type is generalized unless the author writes a monomorphic
signature. `upto lo hi = if lo > hi then [] else lo :: upto (lo + 1) hi` — the
canonical builder, the one in the fixtures, the one in every tutorial — is exactly
that. **F2(b)'s "no real target" was true of the ~30 stdlib impls and false of the
open set of user programs.**

The gate's own rationale (`TRMC-DESIGN.md` Phase 1 AS BUILT) confirms it was
conservatism, never soundness:

> Gated to NON-DICT defines via `leadingDictPats == 0` (`isDictParamName`), so
> dict-passed `map`/`filterMap` + lifted lambdas are untouched.

### 2.1 The relax is genuinely small — the dict is loop-invariant

Medaka has no polymorphic recursion, so a direct self-call forwards its own dict
unchanged. Confirmed in the shipping IR:

```
%t1768 = call i64 @mdk_w_trmc_deep_cons__upto(i64 %arg0, i64 %t1767, i64 %arg2)
                                              ^^^^^ the dict, re-passed by identity
```

The self-call spine is a **saturated 3-arg `CApp`** at the lowered arity — so
`trmcEligible`/`isSelfSatApp` (which are arity-generic, keyed on
`clauseArity`/`clauseArityOf`) already match it. Nothing in the *analysis* needs to
change; only the gate that vetoes it.

---

## 3. Is the parity gate blind by construction? — Yes, in three distinct ways

`test/diff_compiler_tmc_parity.sh` wraps `test/tmc_census.sh`. Its corpus has two arms:

**Arm A — the fixtures (`test/stack_fixtures/*.mdk`, `test/wasm/fixtures/w_trmc_*.mdk`).**
Emitted through `test/bin/llvm_emit_main` and `test/bin/wasm_emit_main` — **both
prelude-free, typecheck-free probes.** No typecheck ⇒ no `dictPass` ⇒ no dict param
⇒ TMC fires. **This arm is blind by construction.** `w_trmc_deep_cons` appears in
the census as `upto trmc` on both backends while the *same fixture*, built by
`medaka build --target wasm`, does not TMC `upto` at all. The census is asserting a
fact about a compiler nobody runs — the exact failure the TESTING orchestrator was
right to go after.

**Arm B — `compiler/entries/check_main.mdk`.** Emitted through `medaka_emitter`
(= `llvm_emit_modules_main`) and `test/bin/wasm_emit_modules_main`, with
`stdlib/runtime.mdk` + `stdlib/core.mdk`. This arm **is** the real prelude-bearing
path — the hypothesis's claim that "the census corpus has NO PRELUDE IN IT" is
**wrong**. But it never sees a constrained builder either: the compiler's own
sources are signature-annotated (a property `test/typecheck_compiler_source.sh`
enforces), and a WAT scan of `check_main` finds that every dict-carrying
self-recursive function in it is an `Eq`/`Ord`/`Debug`/`Display`/`Hashable` walker —
**not one of them builds a cons spine.** That is the F2(b) audit's finding,
independently reconfirmed. So arm B is *representative of the compiler* and
*unrepresentative of user code*, which is where the bug lives.

**The structural blindness (the one that matters).** Both backends run the *same
predicate*, from the *same shared module*, and therefore **decline identically**.

> **A parity gate cannot detect a bug in which both backends are equally wrong.**
> Two sets that are both missing `upto` are still equal.

The census (12/12 `same`, `check_main` 152 == 152) is a *correct* result. There is
simply **no gate anywhere in the tree that asserts "TMC actually fires on function
X on the path users take."** Parity was gated; coverage never was.

**Collateral: `test/diff_native_stack.sh` has the same hole.** Its prelude-free
fixtures (`test/stack_fixtures/`) run through `test/bin/llvm_emit_main` (no
typecheck). Its typed fixtures (`test/stack_fixtures_typed/`) *do* run the real
prelude via `test/bin/llvm_emit_typed_main` — and there `lenAcc` genuinely comes out
`define i64 @mdk_lenAcc(i64 %arg0, i64 %arg1, i64 %arg2)`, dict and all — but all
three typed fixtures happen to contain only dict-carrying *consumers* (handled by
`musttail`), never a dict-carrying *builder*. So the native stack gate has never
tested a constrained builder either.

---

## 4. Native is affected too — the 256 MB stack is hiding it

`compiler/driver/build_cmd.mdk`'s `clangLink` passes no stack flag; the program runs
on a **256 MB GC-aware worker pthread** spawned by `runtime/medaka_rt.c`. That is
what carries the *un-transformed* builder:

| N in `upto 1 N \|> lenAcc` (no signature) | native `medaka build` |
|---|---|
| 2,000,000 | `2000000` |
| 4,000,000 | `4000000` |
| 8,000,000 | `runtime error [E-STACK-OVERFLOW]: stack overflow (recursion too deep)`, exit 134 |

The native IR for these programs carries **three real recursive `call
@mdk_w_deep_append__upto` sites and no `; tmc:` marker.** Native is not correct
here; it is *lucky*, by a factor of ~100× in stack budget. **Fixing this is an LLVM
fix as much as a wasm one** — which is a point in favour of fixing it in the shared
analysis rather than in either emitter.

---

## 5. Fix design

### Stage 0 — make the gate red BEFORE touching the emitter (mandatory first step)

Nothing here is safe to "fix" against a gate that cannot fail. Land the gate first,
watch it go red, then fix.

1. **Add a SHIPPING arm to `test/tmc_census.sh`.** Today the fixture corpus goes
   only through the prelude-free probes. Emit every fixture a **second** time
   through the pair `medaka build` actually shells out to —
   `medaka_emitter <runtime> <core> <fixture> <roots…>` and
   `test/bin/wasm_emit_modules_main <runtime> <core> <fixture> <roots…>` — writing
   `<name>.ship.{llvm,wasm}.tmc`. Keep the probe arm (it is a cheap
   detection-drift signal), but the shipping arm is the one that speaks for users.
2. **Add COVERAGE pins, not just parity.** A per-fixture header pragma
   (`-- EXPECT-TMC: upto`) that the census reads; the gate FAILS if a pinned
   function is missing from **either** backend's shipping set. This is the piece
   whose absence let the arc ship: parity between two sets that both dropped `upto`
   is vacuous — the same "two empty sets are trivially identical" trap
   `test/diff_compiler_tmc_parity.sh` already guards against at the *corpus* level
   (its `n -eq 0` check) but not at the *function* level.
   Pin at minimum: `upto` on `w_trmc_deep_cons` / `w_deep_append` /
   `upto_deep_single`, and `myMap` on `mymap_deep_multi`.
3. **Expected state after Stage 0:** `diff_compiler_tmc_parity` **RED** (coverage),
   still `same` on parity. `test/diff_compiler_engines.sh` already red on the two
   wasm fixtures — leave it red, do not touch `test/engine_divergence.txt` yet.

### Stage 1 — the fix: admit leading dict params on the SELF-recursive path (F2(b), shape (a))

Detection-only relax. **One shared predicate, both backends.**

- `compiler/backend/trmc_analysis.mdk` — replace the boolean `dispNonDict` with a
  count (`leadingDictCount : List CClause -> Int`) plus a predicate that **admits**
  dict-carrying clauses provided the leading-dict count is **uniform across all
  clauses** of the bind (a non-uniform count would mean the slots are not
  positionally consistent; reject).
- `compiler/backend/wasm_emit.mdk` — `wasmTrmcTry` (`:5542`) and `wTrmcImplTry`
  (`:5571`) swap `dispNonDict` for the new predicate. **The emit needs no change:**
  `emitWasmTrmcCore` is keyed purely on `arity`, uses `synthParams arity`, and types
  every param `(ref eq)`. The dict is just another slot.
- `compiler/backend/llvm_emit.mdk` — `trmcTryFn` (`:6627`) and `trmcImplTry`
  (`:4533`) likewise. **Verify (do not assume)** that `emitTrmcLoopBody`'s
  `slotTys` stays aligned: `ptys` comes from `sigLookup` ← `inferSigs`, which infers
  over the **lowered** `CBind`s (post-`dictPass`), so it should already produce one
  `LTy` per lowered param *including* the dict. If it does not, pad `ptys` with
  `leadingDictCount` leading `LTInt` — `trmcReloadParams` is positional and
  `trmcTail`-driven, so a one-off misalignment would silently type the wrong
  scrutinee.
- **Soundness rests on two facts, both verified above, both worth an assertion in
  the fix:** (a) the self-call is saturated at the *lowered* arity, so
  `isSelfSatApp` already matches it; (b) the dict is forwarded by identity (no
  polymorphic recursion in Medaka). Even if (b) were violated, the generic
  arg-recompute path (`wTrmcEmitArgsToTemps` / `trmcEmitParamSlots`) evaluates the
  self-call's dict argument like any other arg and stores it back into the slot — so
  the transform is correct for a *changing* dict too. This is the F2(b) design's own
  claim ("thread them as loop-invariants by identity"), and it holds.
- **What must keep declining, and does so for free:** an **eta-reshaped** binding.
  `etaSaturateFnClause` (`compiler/backend/wasm_emit.mdk:2607`) /
  `etaSaturateMethodBody` (`compiler/backend/llvm_emit.mdk`) synthesize `$eta`
  params, after which the body's self-call is **no longer saturated** to the new
  arity — so `isSelfSatApp` fails and `trmcEligible` returns `False` on its own. Add
  a fixture that pins this (a point-free constrained builder), do **not** add a
  second gate for it.

### Stage 2 — delete the duplicate predicate (this is how the class recurs)

`dispNonDict` lives in `compiler/backend/trmc_analysis.mdk` — the module whose entire
purpose is "one analysis ⇒ parity by construction" — and `trmcNonDict` is a
**second, independent copy of the same rule** in `compiler/backend/llvm_emit.mdk`.
They happen to agree today. A shared-analysis module with a per-backend copy of one
of its predicates is a parity gate waiting to fail silently. Delete `trmcNonDict`;
point `trmcTryFn`/`trmcImplTry` at the shared predicate. (Byte-identical LLVM output
expected — pure predicate unification. `test/selfcompile_fixpoint.sh` C3a/C3b is the
decisive gate, and `trmc_analysis.mdk` is IN-GRAPH, so a seed re-mint may be needed;
see `compiler/WASMGC-TRMC-DESIGN.md` §11 Stage 0, the precedent.)

### Stage 3 — dispatch-graph (b′) groups: DEFER, deliberately

`dispTryRoot` (`compiler/backend/trmc_analysis.mdk:605`) and `dispGrow` (`:806`) also
veto dict-carrying binds. Relaxing *those* is materially harder: a (b′) group has
**heterogeneous member arities**, and the LLVM (b′) emit inlines the whole group into
one define over a **shared slot set** (`TRMC-DESIGN.md` §Phase 3), so a per-member
dict would have to be threaded through slots it does not own. The wasm side
(`return_call` + per-group globals) would take it more easily — which is exactly the
kind of asymmetry that re-splits the TMC sets and *would* trip the parity gate.

**Recommendation: leave the dict veto on the group path**, and let Stage-1's
self-recursive relax carry the whole user-facing class (shape (a) — every builder in
the fixtures, and the one shape a user hand-writes). Record the residual here. If a
real (b′) dict-carrying group ever appears, it must be built on **both** backends in
the same commit, or the parity gate will (correctly) reject it.

### Stage 4 — correct the lies the fixtures and the ledger are telling

- **`test/wasm/fixtures/w_deep_append.mdk`'s header is wrong.** It says it tests "the
  OLD recursive `$mdk_append` (self-call under `struct.new $C_Cons`)" vs "the
  ITERATIVE destination-passing rewrite". `$mdk_append` is iterative and works; the
  fixture actually exercises `upto`. Rewrite the header to say what it tests.
- **`test/engine_divergence.txt`** rows for `wasm/w_deep_append` and
  `wasm/w_trmc_deep_cons` both attribute the failure to `$mdk_append` / "TRMC does
  not take effect" without naming the cause. Replace with the dict-param diagnosis
  and a pointer here; remove the rows when Stage 1 lands.
- **`compiler/TRMC-DESIGN.md` §"Phase 2 (b) — SCOPED & DEFERRED"** must record that
  F2(b)'s "no real target" was an *impl-scoped* audit, that `trmcNonDict` also gates
  the **top-level** path, and that the real target class is every unannotated
  polymorphic user builder.

### Sequencing

`Stage 0 (red gate)` → `Stage 1 (relax + emit verify)` → `Stage 2 (predicate
unification, fixpoint + possible reseed)` → `Stage 4 (docs/ledger)`. Stage 3 is a
documented non-goal. Stages 1 and 2 both touch `compiler/backend/trmc_analysis.mdk`,
which is in the self-host graph — `test/selfcompile_fixpoint.sh` and
`test/typecheck_compiler_source.sh` are mandatory on both.

### Gates that must be green at the end

`test/diff_compiler_tmc_parity.sh` (parity **and** the new coverage pins, on the
shipping arm), `test/diff_compiler_engines.sh` (the two wasm fixtures print
`2000000` / `100000`), `test/diff_native_stack.sh`, `test/wasm/diff_wasm.sh`,
`test/selfcompile_fixpoint.sh` C3a/C3b, `test/typecheck_compiler_source.sh`.

---

## 6. What this does NOT explain

The other newly-exposed wasm bugs (`num_int_max`/`num_int_min` trapping
`unreachable`; the `illegal cast` family; `clos_partial_app` failing GC validation)
have **nothing to do with TMC** — none of the affected fixtures is a builder, and
none of the affected functions carries a TMC marker on either backend. Not chased
here.

**One free pointer, offered without having chased it.** `clos_partial_app`'s reported
symptom is `type mismatch: expected (ref eq) but nothing on stack`. That exact string
is what `compiler/backend/wasm_emit.mdk`'s own eta-saturation comments say the
*under-application* failure mode looks like ("the lifted fn returns an under-applied
`fold step empty` PAP → wasm validate fails … expected `(ref eq)` but nothing on
stack"). `etaSaturateFnClause` runs on the real-prelude path and not on the
prelude-free probe. That is a lead for whoever owns that bug, not a claim.
