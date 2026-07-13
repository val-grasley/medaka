# TRMC-DESIGN.md — tail-recursion-modulo-cons for the native LLVM backend

**Status:** IMPLEMENTED — Phase 1 `#56` (2026-06-11), Phase 3 (dispatch-graph TMC parity
with the wasm backend) `38459006`, 2026-07-13. Exemplary "AS BUILT" self-tracking
throughout (see the doc's own Phase 1/2/3 status lines). One item explicitly SCOPED &
DEFERRED (Phase 2(b)). Dead bare-path citations (`compiler/llvm_emit.mdk`) corrected to
`compiler/backend/llvm_emit.mdk`, 2026-07-13 doc pass.

Design for native TRMC (destination-passing) in `compiler/backend/llvm_emit.mdk`, the last
big architectural change in the canonicalization workstream (PLAN #56). Phase 1
scope approved 2026-06-11. Companion to `STAGE2-DESIGN.md` / `RUNTIME-DESIGN.md`.

## Problem (confirmed on current main)

A builder `f (x::xs) = g x :: f xs` lowers so the recursive call is the LAST arg
of a `::` (Cons) application that is the clause result — and it is evaluated
*before* the cons is built, so every frame stays live to the base case:

```
%t17 = call i64 @mdk_upto(...)        ; ordinary CALL (not musttail)
%t18 = call ptr @mdk_alloc(24)        ; cons cell allocated AFTER the call returns
store <ConsHeader>, ptr %cell ; store <head> ; store %t17 -> tail
ret ...
```

Native list builders **SIGSEGV at ~70–80k cons cells** (interpreter handles 2M+).
Measured: `upto 1 N |> lenAcc` — ok ≤70k, SIGSEGV(139) ≥80k.

Out of scope (already fine): `++`/`append` is a C extern (`mdk_list_append`,
`runtime/medaka_rt.c:258`) — an O(n) iterative loop, no native stack growth.
Existing `musttail` (`emitFnBody`, ~`llvm_emit.mdk:4727`) covers only DIRECT
tail recursion (`lenAcc`-style), not cons-tail builders. No TRMC exists today.

## Mechanism: destination-passing (TMC proper)

Chosen over accumulator+reverse — order/effect-preserving, single pass, reuses the
existing alloc site. **In-place loop with a mutable destination register** (no new
define variant / prototype / trampoline → the ABI stays uniform-i64, and
dispatch/eta/musttail machinery is undisturbed). The eligible clause body becomes:

```
entry:  %hole = alloca i64            ; final contents = the returned list head
        br label %loop
loop:   ; phis: the recursion params + %destslot (ptr to the i64 to fill)
        <param match/guard>
        ; base/Nil leaf:  store <nil-immediate> into *%destslot ; br exit
        ; cons leaf:
        %cell = call ptr @mdk_alloc(24)
        store <ConsHeader>, ptr %cell
        store <head>, ptr %cell+8
        store (ptrtoint %cell), ptr %destslot      ; link into parent's tail (or %hole)
        %newdest = getelementptr %cell, +16        ; this cell's tail slot
        <recompute rec args>                       ; br loop with phi(newargs, %newdest)
exit:   %r = load i64, ptr %hole ; ret i64 %r
```

O(1) stack, identical list value + order + effect sequence.

## Phase 1 scope (APPROVED → IMPLEMENTED 2026-06-11, #56)

**Cons-only (`::`), top-level NON-DICT self-recursive defines, syntactic
clause-result `head :: self-call`.** Fixes every user-written list builder
(`upto`, `replicate`, `take`, hand-rolled `myMap`).

Qualifies when, for a clause: result is `CBinPrim "::" head tail` (the `op=="::"`
arm, `llvm_emit.mdk:~1616`) AND `tail` is a saturated self-recursive `CApp`-spine
to the function AND `head` contains no self-call. Multi-clause: eligible if ≥1
clause matches; base/non-matching clauses store-into-current-dest + branch-to-exit;
all clauses share one `loop` block keyed on param phis.

Falls back to current (stack-growing) codegen for: recursion not in cons-tail
position; recursion under a non-`::` constructor (phase 2); mutual recursion
(out of scope); a guarded eligible clause that can fail into another clause.

## Emitter touchpoints (`compiler/backend/llvm_emit.mdk`)

1. **New analysis** `trmcEligible name clauses : Bool` + per-clause classifier
   `consTailClause` — structural detection of `CBinPrim "::" head (CApp→self)`.
   Place near `clausePairs`/`clauseArity` (~4643).
2. **One branch point** in `emitFn` (~4482) / `emitMultiClauseFn` (~4630) /
   `emitFnClause` (~4662): if `trmcEligible`, route to new `emitTrmcFn`.
3. **New `emitTrmcFn`** reuses the decision-tree machinery (`emitClauseTree`/
   `emitClauseChain` ~3150) but redirects the LEAF (`emitLeaf` ~4159): eligible
   leaf = cons-into-dest + loop-back; base leaf = store-into-dest + br exit.
4. **Reuse `emitCtorAlloc` (~4002) + `storeFields` (~4015) verbatim** for header+head
   stores; only new emit = `store (ptrtoint cell) into *dest` + `getelementptr +16`.
   Constants in scope: `cellTag e "Cons"` (header), Nil immediate (`562949953421315`).
5. **The self-call is NOT emitted as a call** — bypass `emitApp`/`emitFnBody`; emit
   only the arg recomputation feeding the loop phis (this is what removes the
   stack-growing `call`).

## Risk resolutions

- **GC safety:** `mdk_alloc`→`GC_malloc` returns ZEROED memory (`medaka_rt.c:66-71`),
  so the alloc→store window reads as `0` (even word = null, never followed by Boehm).
  No garbage-tail window. Store order: alloc → header → head → link-into-dest → advance.
- **Closures/eta/dispatch:** Phase 1 restricts to top-level NON-DICT defines (skip
  leading `$dict` params via `isDictParamName` ~4576), so `etaSaturateMethodBody`
  (~4523) / lifted-lambda paths (`emitGroupBindDefine` ~1977) are never touched. ABI
  unchanged (uniform i64). → dispatch/eta/closures undisturbed.
- **Fixpoint (C3a/C3b):** deterministic structural transform → interp- and
  native-emit produce identical IR → holds by construction. The emitter's own
  `:: <ident>` sites may become eligible (its emitted IR changes, still deterministic
  + correct). Output-based differential gates stay green (identical list value).
  **Mandatory post-gate: `selfcompile_fixpoint.sh` + `diff_compiler_llvm.sh`.**

## Gate

New deep-list stack-safety fixture (`test/diff_native_stack.sh` or extend
`diff_compiler_llvm.sh`): `upto 1 2_000_000 |> length` — **SIGSEGV before,
print `2000000` after**, stdout == interpreter oracle.

## Phase 2 (deferred, if warranted)

(a) Dispatch/dict-passed methods (`map`/`filterMap` via instances — interacts with
eta-saturation, medium risk); (b) `match`/`if`-arm tail descent (`filterMap`'s
in-arm cons); (c) general single-constructor last-field TMC (not just `::`). Each
independently gateable. Until Phase 2, stdlib `map (+1) [1..1M]` still overflows;
hand-rolled builders are stack-safe.

## Phase 1 — AS BUILT (2026-06-11, `compiler/backend/llvm_emit.mdk`)

Implemented exactly to the destination-passing mechanism above, with an
ALLOCA-based mutable destination + param slots (not block phis) — simpler, robust
at every clang `-O` level (`mem2reg` promotes them under `-O2`), and it sidesteps
all phi-wiring across decision-tree leaves.

**Eligible-detection** (`trmcEligible` + `isConsTail`/`trmcBodyOk`, structural,
deterministic): a clause qualifies when, descending through `CIf`/`CLet`/
`CLetGroup` tail wrappers, every leaf is EITHER self-free OR an eligible cons-tail
`CBinPrim "::" head tail` with `head` self-free and `tail` a SATURATED self
`CApp`-spine (arity-exact). ANY self-call outside a cons-tail leaf disqualifies the
whole function → current codegen. `match`/`CDecision` are NOT descended (a self-call
inside a match arm is treated as a leaf with a self-ref ⇒ disqualified — that's the
Phase-2 in-arm-cons case). Gated to NON-DICT defines via `leadingDictPats == 0`
(`isDictParamName`), so dict-passed `map`/`filterMap` + lifted lambdas are untouched.

**Two shapes handled** (both observed in real builders, which the original design
under-specified — function-clause guards desugar to nested `CIf`, NOT a decision
tree):
- *Single-clause guarded* (`upto`/`replicate`: `f x | g = [] | otherwise = x :: f …`)
  → body is nested `CIf`; `emitTrmcBody` descends the `CIf`/let wrappers and routes
  each value leaf to the cons/base emit directly.
- *Multi-clause* (`myMap f [] = [] ; myMap f (x::xs) = f x :: myMap f xs`) → reuses
  `emitClauseTree`'s decision-tree clause chain VERBATIM; the per-clause leaf
  (`emitLeaf`) is TRMC-aware via a module-level `trmcCtxRef` (mirrors
  `fallthroughLabelRef`), so the clause body is descended in tail position instead
  of computing a value. `emitDecision` saves+clears `trmcCtxRef` across an
  expression-position `match`, so a nested match's arms still compute values.

**Emit shape** (`@mdk_upto` example):
```
entry:  %hole = alloca i64 ; %dest = alloca ptr ; store ptr %hole, ptr %dest
        %tp0 = alloca i64 ; store %arg0,%tp0 ; %tp1 = alloca i64 ; store %arg1,%tp1
        br label %trmcloop
trmcloop: <reload %tpK> ; <CIf guard chain / decision tree>
  base leaf:  %d=load ptr,%dest ; store <nil-imm 562949953421315>, %d ; br trmcexit
  cons leaf:  %cell=call ptr @mdk_alloc(24) ; store <ConsHdr>,%cell
              store <head>, %cell+8 ; %d=load %dest ; store ptrtoint(%cell), %d
              %nd=gep %cell,+16 ; store ptr %nd, %dest
              <recompute args → %tpK> ; br trmcloop      ; NO `call @mdk_upto`
trmcexit: %r=load i64,%hole ; ret %r
```
The cell's own tail word stays ZEROED (GC_malloc) until the next iteration fills it
(GC-safe per §"Risk"). Recursion args are computed into temps THEN stored, so an
in-place slot store can't clobber a not-yet-read param.

**Deviations / notes:**
- The multi-clause path re-allocates the synthetic tuple scrutinee (`emitClauseTree`,
  arity≥2) once per iteration — one extra GC cell/element. Bounded, O(1)-stack, value-
  correct; left as-is (an `emitClauseTree` TRMC-specialisation is a possible later
  cleanup). The decision-tree's own `decend`/result slot becomes a dead block (no
  predecessor) — LLVM tolerates it.
- The self-call is fully BYPASSED: verified no `call …@mdk_<self>` in an eligible
  define's body (only the head's indirect closure call `call i64 %reg(...)` for
  `myMap`'s `f x`, and the external caller's own call site, remain).

**Gates (all green):** `diff_compiler_llvm` 172, `_modules` 9, `_typed` 37,
`diff_compiler_build` 15, `diff_native_cli` 54; `selfcompile_fixpoint` C3a **YES** /
C3b **YES** (the emitter's own `:: <ident>` builders became TRMC-eligible — its
emitted IR changed but reproduces byte-for-byte, fixpoint holds by determinism). New
`test/diff_native_stack.sh` (2 fixtures under `test/stack_fixtures/`): `upto 1 2_000_000`
single-clause + `myMap … (upto 1 2_000_000)` multi-clause both print `2000000`, exit 0,
== oracle. **Before/after:** at the default clang stack the single-clause builder
SIGSEGV(139)→`2000000`.

**Out of scope confirmed (expected fallbacks):** a `myMap`-as-`match` (single clause,
body is `CDecision`) is NOT transformed — the self-call sits in a match arm (Phase 2b).
A *very* deep (>~1M) linked list can still SIGSEGV under the DEFAULT stack from Boehm
GC's RECURSIVE mark (a separate pre-existing native-runtime limit, unrelated to TRMC) —
the production build (`build_cmd.mdk`: `-O2 -Wl,-stack_size,0x20000000`) gives the mark
room; the stack gate links with those flags.

## Phase 2 — DESIGN (full general TMC; scope locked 2026-06-11)

Scoping pass against the Phase-1 AS-BUILT machinery. **Key reframe:** stdlib
`map`/`filterMap` impls carry **NO dict params** (Phase-1's `leadingDictPats==0` gate
was a red herring) — the real reason they aren't TRMC'd is that **TRMC has zero reach
into the impl-emit path** (`emitImpls`→`emitGroup`→`emitGroupBody`, ~`llvm_emit.mdk:2916-3149`),
and the recursive call is a `CMethod method (RKey tag)` (post-`restampIface`), NOT a
`CVar self`. The feared eta-saturation interaction is **orthogonal** for List
`map`/`filterMap` (full-arity, `gatherGroup` no-op, `etaSaturateMethodBody` is `emitFn`-only).

**SAFETY-CRITICAL:** `freeVars (CMethod …)` returns only dict names — the method NAME is
invisible. So Phase-1's `not (refersTo self)` disqualification net is BLIND to dispatched
self-calls. B-dispatch MUST add a `CMethod`-aware self walk (`mentionsSelfMethod method tag`)
to disqualify a body that self-recurses via `CMethod` in a non-tail position, else miscompile.

### Three sub-parts + staging (each independently gated; decline → current codegen, no regression)

1. **Axis A — general single-constructor LAST field** (lowest risk, FIRST). Generalize
   `isConsTail`/`emitTrmcCons` from `CBinPrim "::"` to any saturated `CVar ctor` app
   (`isCtor`, `ctorArity≥1`) whose LAST field is the saturated self-call, other fields
   self-free. Thread `Emit` into the detection helpers (for `isCtor`/`ctorArity`). Emit:
   alloc `8*(arity+1)`, header `cellTag e ctor`, `storeFields` non-last fields, link cell
   into the **last-field slot (offset `8*arity`)**, advance dest there. `::` stays the
   special case. Already routes through `emitFn`→`trmcTryFn` (non-dict top-level). Clean.
2. **B-dispatch — `map`/`filterMap` via instances** (headline, medium). (B1) wire TRMC into
   `emitGroup` (split `emitTrmcFn` into `emitTrmcHeader` + reusable `emitTrmcLoopBody`; the
   impl path supplies `@mdk_impl_<tag>_<method>` + the impl param-env). (B2) `CMethod`-self
   detection (`isSelfMethodSatApp method tag arity`) + the safety-critical `mentionsSelfMethod`
   disqualification. Self-predicate becomes `SelfByVar name | SelfByMethod method tag` threaded
   through the same structural walk. Builds on A's `emitTrmcCtor`.
3. **B-match-descent — `filterMap`'s in-arm cons** (medium, after B-dispatch). Add a
   `CDecision` tail arm to `trmcBodyOk`/`emitTrmcBody`: descend each arm in tail position
   (scrut self-free), classifying {cons-tail | **plain-tail self-call** | base}. New leaf kind
   `emitTrmcTailCall` (recompute args + `br loop`, no cell) for the bare-self arm. The tail
   CDecision keeps `trmcCtxRef` LIVE (vs `emitDecision`'s save/clear for expression-position).

### Scope LOCKED (user, 2026-06-11): a / a / yes — (b) deferred as CLEAN future extensions
- **F1 = (a):** detect only when the self-call is the constructor's LAST field. (b) [any field
  position] is purely additive later — parameterize the dest-offset by field index (the emit
  mechanism is identical; (a) is the `idx=arity-1` case). **Keep the offset COMPUTED, not
  hardcoded, so (b) is a localized patch.** No real target needs (b) today.
- **F2 = (a):** B-dispatch covers non-dict/non-eta impls (map/filterMap/ap over List — every
  real target). (b) [dict-carrying/eta-reshaped constrained impls] is additive later — relax the
  predicate + thread the loop-invariant leading dict/eta params through the loop by identity.
  **Keep the param-threading GENERIC (don't assume zero leading params), so (b) is a relax.**
  No real constrained cons-tail impl exists today.
- **F3 = yes:** the plain-tail self-call leaf (iterate on a shorter list, build no cell) is
  required for `filter`/`filterMap` and is in scope.

### Gate
Extend `test/diff_native_stack.sh` (fixtures under `test/stack_fixtures/`), each SIGSEGV-before /
correct-after, == `eval_probe` oracle, exit 0, linked with `-O2 -Wl,-stack_size,0x20000000`:
`map (+1) [1..2_000_000] |> sum` (B-dispatch; needs the TYPED emit path `llvm_emit_typed_main.mdk`
+ runtime + core, since `map` is a stdlib method); `filter`/`filterMap` over 2M (B-match);
a deep user-ADT `data Chain = Link Int Chain | End; build 2_000_000 |> depth` (Axis A, prelude-free
path); a multi-field non-`::` ctor builder (Axis A). Plus full `diff_compiler_*` + `diff_native_cli`
+ `selfcompile_fixpoint` C3a/C3b YES (the emitter's own `map`/`filterMap` become loops — deterministic,
reproduces byte-for-byte, the Phase-1 precedent).

### Backend portability — what the eventual WasmGC backend inherits

TRMC splits into a backend-agnostic ANALYSIS and a backend-specific EMIT:

- **Reusable (Core-IR-level, no LLVM dependency):** the eligibility analysis —
  `trmcEligible`/`isConsTail`/`isCtorTail`, the `CMethod`-self detection, the
  match-arm descent. Pure structural analysis over `CExpr`/`CApp`/`CBinPrim`/`CMethod`
  (which clause is tail-modulo-constructor, which field is the self-call, what
  disqualifies). **This is where most of the intellectual work + route-fragile risk
  lives** (the `CMethod`-blindness gotcha, disqualification soundness) — so the
  expensive part is portable. *Currently physically in `llvm_emit.mdk`; the logic is
  not LLVM-coupled — lift it into a shared/Core-IR module when WasmGC arrives (a
  mechanical move; not worth factoring now with no second consumer).*
- **Backend-specific (rebuild for WasmGC):** the destination-passing EMIT
  (`emitTrmcCtor`/`emitTrmcFn`) — `alloca` dest pointer, `@mdk_alloc`, `getelementptr`
  into the field slot, `store` child address, `br loop`. Raw-pointer + mutable-memory
  codegen. **The TECHNIQUE transfers directly:** WasmGC has no raw pointers but has
  `struct.new`/`struct.set` — destination-passing becomes "hold the parent cell ref,
  `struct.set` the child into the parent's recursive field, loop with parent := child."
  Same algorithm, ~the size of `emitTrmcCtor`, not a reinvention.
- **Constraint TRMC imposes on the WasmGC type defs:** destination-passing writes the
  child AFTER creating the parent, so the constructor fields used as TRMC destinations
  (the cons tail, an ADT's recursive field) MUST be declared **`mut`** in the WasmGC
  struct types (you'd otherwise make functional-list fields immutable). Slight optimizer
  cost; standard for TMC on any GC'd backend. Bake it into the cons/ADT struct types
  from the start.

## Phase 2 Axis A — AS BUILT (2026-06-11, `compiler/backend/llvm_emit.mdk`, #56)

General single-constructor LAST-field TMC. Generalizes the Phase-1 cons-only
machinery; `::`/Cons is now the special case `ctor=Cons, arity 2, selfIdx 1`.

**Detection** (`isConsTail` → `isCtorTail e self arity ex`, now `<Mut>`, threads
`Emit` for `isCtor`/`ctorArity`):
- `CBinPrim "::" head tail` — unchanged `::` arm: head self-free, tail a saturated
  self `CApp`-spine. (`::` never flattens to a `CVar` head.)
- otherwise `flattenApp ex []` → `(CVar ctor _, fields)` qualifies iff `isCtor e ctor`,
  `length fields == ctorArity e ctor`, `ctorArity ≥ 1`, and `ctorTailFieldsOk`: the
  LAST field is a saturated self-call (`isSelfSatApp`), every LEADING field self-free.

`trmcEligible`/`trmcClausesOk`/`trmcAnyCons`/`trmcBodyOk`/`trmcBodyHasCons` all became
`<Mut>` + thread `Emit` (mechanical). New pure helpers: `ctorTailFieldsOk`,
`allSelfFreeF`, `splitLastF` (split into leading + last). Field accessors generalized:
`consTailHead` → `ctorTailLeadFields` (the non-last fields, stored into the cell — `[head]`
for `::`); `consTailArgs` now reads the LAST field's self-call args (both forms);
`ctorTailName` (`"Cons"` for `::`); `ctorTailSelfIdx` (the self-call's field index =
`arity-1`).

**Emit** (`emitTrmcCons` → `emitTrmcCtor e env ctor leadFields args selfIdx …`):
`arity = len leadFields + 1`; emit leading-field values (`emitArgs`, left-to-right);
`mdk_alloc(8*(arity+1))`; header `cellTag e ctor`; `storeFields` the leading fields at
their positional offsets (0-based, +8…); link cell-word into `*dest`; advance dest via
`getelementptr +8*(selfIdx+1)`; recompute self-args into temps then param slots; `br loop`.
The self-call slot stays ZEROED (GC_malloc) until the next iteration fills it (GC-safe per
§"Risk", unchanged). The Cons path is byte-identical to Phase 1: `emitArgs [head]` ≡ the
old `emitExpr head`, `cellTag "Cons"`, alloc 24, advance +16.

**F1(b) SEAM (kept open):** the dest-offset is `8*(selfIdx+1)` COMPUTED from `selfIdx`
(passed as `ctorTailSelfIdx ex`, always `arity-1` under (a)), NOT hardcoded "last". So
Phase-2 F1(b) [self-call in any field] is a DETECTION-ONLY patch: broaden `isCtorTail`/
`ctorTailFieldsOk` to find which field is the self-call and set `selfIdx` to it; `emitTrmcCtor`
is unchanged — it already stores the leading-by-index fields and links at `8*(selfIdx+1)`.
(Note: F1(b) must also store the OTHER non-self fields including those AFTER the self slot;
the current emit stores `leadFields` 0-based contiguous, fine for (a) where the self-call is
last. (b) will store all non-self fields at their true positional offsets — an additive
refinement of `storeFields`, not a rewrite.)

**Gates (all green):** `diff_compiler_llvm` 172, `_modules` 9, `_typed` 37,
`diff_compiler_build` 15, `diff_native_cli` 54; `selfcompile_fixpoint` C3a **YES** / C3b
**YES** (the emitter's own ctor builders that became eligible reproduce byte-for-byte —
deterministic transform). `test/diff_native_stack.sh` now 4 fixtures: existing
`upto_deep_single` + `mymap_deep_multi` (Cons, still pass), new `chain_deep_adt`
(`data Chain = Link Int Chain | End; build 2_000_000 |> depth` → 2000000) + `node_deep_multifield`
(2-leading-field `Node Int Int T3` → 2000001000000), all `== eval_probe`, exit 0,
`-O2 -Wl,-stack_size,0x20000000`. **Before/after** (chain_deep_adt, default stack): pre-Axis-A
`@mdk_build` carries `call i64 @mdk_build` → SIGSEGV(139); post-Axis-A the self-call is
`br label %trmcloop` (NO `call @mdk_build`) → prints 2000000, exit 0. Small: `build 5 |> depth`
= 5; Cons `upto 1 5 |> len` = 5.

**Out of scope (confirmed fallbacks, no regression):** self-call NOT in the last field (F1(b),
deferred — falls to current codegen); dispatch/dict-passed impl methods (B-dispatch);
match-arm tail descent (B-match). Axis A is strictly top-level non-dict `emitFn`→`trmcTryFn`
defines.

## Phase 2 B-dispatch — AS BUILT (2026-06-11, `compiler/backend/llvm_emit.mdk`, #56)

The HEADLINE win: TRMC now reaches the DISPATCHED impl-emit path, so the stdlib
`map` instance method (Functor List) builds a 2,000,000-element list in O(1) stack.
F2(a) scope: NON-dict, NON-eta impls (List `map`/`ap`-shape — `filterMap`'s cons is
in a match arm, B-match-descent territory, see below).

**Diagnosis (traced impl IR).** `map`/`filterMap` impls carry NO dict params and reach
a SEPARATE emit path from Axis A: `emitImpls`→`emitGroups`→`emitGroup`→`emitGroupBody`
(Axis A is `emitFn`→`trmcTryFn`, never visited here). The lowered `map` impl is
`@mdk_impl_List_map(i64 %arg0, i64 %arg1)`, arity 2, two clauses (`map _ [] = []` /
`map f (x::xs) = f x :: map f xs`); the recursive call is **`CMethod "map" (RKey "List" [])`**
(post-`restampIface`), NOT `CVar self` — it lowers (`emitMethod`'s `RKey` arm →
`emitImplCallSat`) to a direct `call @mdk_impl_List_map`, the stack-growing site.

**B2 — `CMethod`-self detection (`SelfRef`).** The self-predicate is generalised from
a bare `self : String` to `data SelfRef = SelfByVar String | SelfByMethod String String`
(method, tag), threaded through the SAME structural walk (`isCtorTail`/`isSelfSatApp`/
`trmcBodyOk`/`trmcBodyHasCons`/`ctorTailFieldsOk`/`allSelfFreeF`). `isSelfHead` matches
`CVar f` (SelfByVar) or `CMethod m (RKey t _)` with `m==method && t==tag` (SelfByMethod).
`TrmcOn` now carries the `SelfRef` so the cons/ctor leaf recognises the self-call.

**B2 — the SAFETY-CRITICAL disqualification.** `freeVars (CMethod …)` returns ONLY the
dict names — the method NAME is invisible — so Phase-1/Axis-A's freeVars-based
`refersTo`/`selfFree` net is BLIND to a dispatched self-call. A body that self-recurses
via `CMethod` in a NON-tail position would be wrongly accepted as "self-free" →
TRMC-transformed → the non-tail self recursion DROPPED → silent MISCOMPILE. Fix:
`selfFree` is SelfRef-directed — `SelfByVar` uses `freeVars` (unchanged); `SelfByMethod`
uses a dedicated full-tree walk **`mentionsSelfMethod method tag`** that descends every
CExpr constructor (incl. `CDecision`/`CMatch` arms, guards, `CBlock` stmts, record/index/
slice subtrees) looking for a `CMethod method (RKey tag)` occurrence. Verified
empirically: (1) `filterMap`'s cons sits inside a `CDecision` arm → its leaf is the whole
`CDecision`, which `mentionsSelfMethod` reports as containing the self-call → `trmcBodyOk`
False → `filterMap` stays ORDINARY (NOT TRMC'd, 2 recursive calls remain, output correct);
(2) an adversarial `mapb f (x::xs) = f x :: append (mapb f xs) []` (self-call NON-tail under
`append`) → `isCtorTail` False (head is `append`, not the self-method), then `selfFree`
False (the `CDecision`-free `mentionsSelfMethod` finds the buried `mapb`) → disqualified,
recursive call KEPT. Both confirm the net is not blind.

**B1 — wiring (`emitGroup`→TRMC).** `emitTrmcFn` is split into `emitTrmcHeader defineName
arity` (emits `define @<name>(…) {` + `entry:`) + reusable **`emitTrmcLoopBody self arity
slotTys clauses single …`** (entry-block setup → loop → reload → `TrmcOn` dispatch → exit
ret; does NOT emit the closing `}`). The top-level path (`emitTrmcFn`) and the new impl path
(`trmcImplTry`, called from `emitGroup` before `emitGroupBody`) BOTH call it. The impl path
supplies the `@mdk_impl_<tag>_<method>` define name, the receiver-typed `aK` scrutinee env
(`patPosTys tag positions` — matching `emitGroupBody`'s `implParamEnvByPos`), and
`SelfByMethod method tag`. The cons-leaf emit (`emitTrmcCtor`, shared from Axis A) is
unchanged. `setCurImplSelfFns` is set BEFORE the TRMC/ordinary choice so the cons-head
callback `f x` (`map`'s `f x :: …`) still types as the container.

**Emit shape** (`@mdk_impl_List_map`, post-B-dispatch): `entry` sets up `%hole`/`%dest`/
two param slots, `br %trmcloop`; the loop reloads `f`/`xs`, runs the decision-tree clause
chain (`emitClauseTree`, TRMC-aware leaf via `trmcCtxRef`); the Cons leaf does the indirect
`call %f(…)` (head `f x`, KEPT), allocs the Cons cell, stores head, links into `*dest`,
advances `%dest` to +16, recomputes `f`/`xs` into the slots, `br %trmcloop` — **NO `call
@mdk_impl_List_map`**; the Nil leaf stores the nil immediate into `*dest`, `br %trmcexit`.

**F2(b) param-threading seam (confirmed GENERIC).** The loop param-threading
(`trmcEmitParamSlots`/`trmcReloadParams`/`trmcStoreParamSlots`) is keyed purely on `arity`
and a positional `slotTys` list — it makes NO assumption of zero leading params. F2(b)
(dict/eta-carrying constrained impls) is therefore a DETECTION-ONLY relax: broaden the F2(a)
`trmcNonDict` gate to admit leading dict/eta params and thread them as loop-invariants by
identity; the loop machinery is unchanged. No real constrained cons-tail impl exists today.

**`filterMap` awaits B-match.** `filterMap`'s cons lives inside a `match` arm (`CDecision`),
which `trmcBodyOk` does NOT descend (a tail cons in a match arm is the B-match-descent stage).
So B-dispatch does NOT fully transform `filterMap` — EXPECTED, and the B2 walk correctly keeps
it ineligible rather than miscompiling it. `map` (whose cons IS the syntactic clause result)
is fully TRMC'd.

**Gates (all green):** `diff_compiler_llvm` 172, `_modules` 9, `_typed` 37,
`diff_compiler_build` 15, `diff_native_cli` 54; `selfcompile_fixpoint` C3a **YES** / C3b
**YES** (deterministic structural transform → reproduces byte-for-byte). `diff_native_stack.sh`
extended to drive the TYPED emitter (`llvm_emit_typed_main` + runtime + core, oracle
`eval_probe --prelude`) for stdlib-method fixtures under `test/stack_fixtures_typed/`; new
`map_deep` fixture (`map (x => x+1) [1..=2_000_000] |> length` → 2000000). **Before/after**
(`map_deep`, DEFAULT stack): pre-B-dispatch `@mdk_impl_List_map` carries `call
@mdk_impl_List_map` → SIGSEGV(139); post-B-dispatch the self-call is `br label %trmcloop`
(NO recursive call) → prints 2000000, exit 0, `== eval_probe --prelude`. Small: `map (+1)
[1,2,3]` → `2,3,4`.

## Phase 2 B-match-descent — AS BUILT (2026-06-11, `compiler/backend/llvm_emit.mdk`, #56)

The LAST Phase-2 sub-part: TRMC now descends a TAIL-position `match` (`CDecision`),
so `filterMap`'s in-arm cons (`Some y => y :: filterMap f xs`) AND its plain-tail
drop (`None => filterMap f xs`, the **F3** leaf) both become O(1)-stack loop edges.
This completes the **a/a/yes scope: Phase 2 is COMPLETE** — `map`/`filter`/`filterMap`
+ general single-ctor builders are all stack-safe.

**The target.** `filterMap f (x::xs) = match f x { Some y => y :: filterMap f xs ;
None => filterMap f xs }`. The `(x::xs)` clause body (reached via `emitClauseTree`'s
decision-tree leaf, which calls `emitTrmcBody` under `TrmcOn`) is itself a
**`CDecision`** whose arms are a cons-tail self (`Some`), a **plain-tail self-call**
(`None`), and the `[]` base clause. Pre-B-match the `CDecision` was un-descended (its
self-calls were non-tail leaves) → `filterMap` stayed ordinary (2 recursive `call
@mdk_impl_List_filterMap`, SIGSEGV at default stack — correct, NOT miscompiled).

**Detection** (`trmcBodyOk`/`trmcBodyHasCons`): a tail-position `CDecision scrut arms
_` is descended — the **scrutinee must be self-free** (`selfFree self scrut`, evaluated
eagerly outside the loop's destination position) and **every arm body** is recursively
`trmcBodyOk` in tail position (`trmcArmsOk`); arm **guards must be self-free**
(`trmcGuardsSelfFree`). The leaf classifier (`trmcBodyOk`'s base case) gained a THIRD
class between ctor-tail and self-free base: a **plain-tail self-call**
(`isSelfSatApp self arity ex` — a bare saturated self-call). `trmcBodyHasCons` descends
arms via `trmcArmsHaveCons` but the plain-tail leaf is NOT a "cons" (builds no cell), so a
function whose only self-calls are plain-tail (pure tail recursion) is left to the
existing `musttail` path — at least one true cons/ctor-tail must exist to warrant the
loop. Any self-call in a NON-tail position inside an arm is caught by the SelfRef-directed
`selfFree` (B-dispatch's `mentionsSelfMethod` for dispatched impls — its safety-critical
disqualification is REUSED unchanged, not regressed). **`CMatch` (non-treeable arms) is NOT
a detection case** — it has no `emitExpr` arm, so it disqualifies (ordinary codegen, no
regression).

**F3 plain-tail leaf** (`emitTrmcTailCall`, routed from `emitTrmcLeaf` between the
ctor-tail and base cases): the `None => filterMap f xs` arm — a bare saturated self-call
in tail position. It is the cons leaf MINUS the alloc + head + dest-link/advance:
recompute the recursion args into temps, store them into the loop's param slots,
`br loop`. The destination is left UNCHANGED, so the next iteration fills the SAME
destination slot — exactly the "drop this element, iterate on a shorter list" semantics
`filter`/`filterMap` need. NO `call`.

**Emit / the live-vs-save-clear boundary.** New `CDecision` arm in `emitTrmcBody` (the
tail-descent walker): emit the scrutinee, then walk the SAME decision-tree machinery as
`emitDecision` (`emitTree`) but keep `trmcCtxRef` **LIVE** across the tree — so each arm
body is descended as a TRMC tail leaf via `emitLeaf`'s `TrmcOn` branch (→ `emitTrmcBody`
→ cons-into-dest+loop / plain-tail-call+loop / base+exit), NOT computed into a value
slot. This is the inverse of `emitDecision`'s save+clear of `trmcCtxRef`, which STAYS for
an EXPRESSION-position match — a nested value-producing match inside an arm re-enters
`emitDecision` and saves+clears it for its own value arms. So the boundary is: a
**tail-position** `CDecision` (the clause-result match) keeps the ctx live;
**expression-position** matches (anywhere else, via `emitExpr → emitDecision`) save+clear.
`fallthroughLabelRef` is still saved+cleared (a non-exhaustive tail match's `CTFail` is a
genuine abort). The decision's own result slot + `endL` block become a DEAD block (no
`TrmcOn` leaf stores/branches there — every leaf branches to `loopL`/`exitL`); LLVM
tolerates the no-predecessor block (Phase-1 precedent).

**Emit shape** (`@mdk_impl_List_filterMap`, post-B-match — verified IR): 0 `call
@mdk_impl_List_filterMap` inside the define. The cons arm (`Some y`): `call @mdk_alloc(24)`,
store header + head, link into `*dest`, advance dest +16, recompute `f`/`xs` into slots,
`br %trmcloop`. The plain-tail arm (`None`): NO alloc, NO dest store — just `store` the two
recomputed args into the param slots, `br %trmcloop`. The base (`[]`): nil-immediate into
`*dest`, `br %trmcexit`.

**Deferred seams unchanged:** F1(b) [self-call not in the last ctor field] + F2(b)
[dict/eta-carrying constrained impls] remain clean future extensions (the dest-offset is
COMPUTED from `selfIdx`; the loop param-threading is GENERIC in `arity`/`slotTys`).

**Gates (all green):** `diff_compiler_llvm` 172, `_modules` 9, `_typed` 37,
`diff_compiler_build` 15, `diff_native_cli` 54; `selfcompile_fixpoint` C3a **YES** / C3b
**YES** (the emitter's own `filterMap`/`filter`-over-`CExpr` sites became loops with
match-arm descent — deterministic, reproduces byte-for-byte). `diff_native_stack.sh` now 7
fixtures: new `filtermap_deep` (`filterMap (x => Some (x+1)) [1..=2_000_000] |> length` →
2000000, all kept) + `filter_deep` (`filterMap keepEven … ` → 1000000, the F3 DROP path
exercised on ~half the elements). **Before/after** (`filtermap_deep`, DEFAULT stack):
pre-B-match `@mdk_impl_List_filterMap` carries 2 `call @mdk_impl_List_filterMap` →
SIGSEGV(139); post-B-match both arms are `br label %trmcloop` (NO recursive call) → prints
2000000, exit 0, `== eval_probe --prelude`. Small correctness (native == oracle):
`filterMap keepEven [1..6]` → `[2,4,6]`; `filter (x => x > 0) [-1,2,-3,4]` → `[2,4]`. No
regression: `map (+1)` still fully TRMC'd (0 recursive calls); a non-tail self in a match
arm (`sumList xs = match xs { … (y::ys) => y + sumList ys }`) stays ineligible (no cons
leaf) → ordinary codegen, native == oracle == 10.

**Phase 2 a/a/yes COMPLETE.** map / filter / filterMap + general-ctor builders all
stack-safe; the deferred F1(b)/F2(b) seams remain (no real target needs them today).

## Phase 2 (b) — SCOPED & DEFERRED (2026-06-11)

A read-only scoping pass assessed what it would take to land the deferred (b) items.
**Both DEFERRED** — neither has any real target; building them would be speculative
emit exercised only by synthetic fixtures (fails "bounded work + clear payoff"). Kept
as documented seams; revisit only if a real target appears.

**F1(b) — self-call in ANY constructor field (not just last).** No real target: no
stdlib/compiler builder puts its self-call anywhere but last (synthetic only). Effort
SMALL–MEDIUM, risk LOW.
- *Detection:* broaden `ctorTailFieldsOk` → find the UNIQUE self-call field (others
  self-free), return its index via `ctorTailSelfIdx`. ~10 lines.
- *Emit — NOT detection-only (the in-code seam note is over-optimistic):* `storeFields … 0`
  writes the non-self fields contiguously at `8*(i+1)`; for a non-last `selfIdx` the
  field AFTER the self slot must be stored at its TRUE offset, skipping the self slot —
  needs an index-aware `storeFieldsAt` (or before/after split) + threading the full field
  list + `selfIdx` into `emitTrmcCtor`. ~15–25 lines.
- *GC invariant SAFE:* only the self slot must stay zeroed (alloc→link null window);
  other slots may be written. Store order: alloc → header → non-self fields at true
  offsets → link cell into `*dest` → advance dest to the self slot.
- **Design fork (needs a human call when built):** a ctor with TWO self-calls in
  different fields (`data Tree = Br Tree Int Tree`) is genuinely MULTI-recursive — only
  one tail position exists, so it is NOT TMC-able. Detection must require EXACTLY ONE
  self-field and disqualify ≥2 (the second self-call is caught by the `selfFree` net).

**F2(b) — dict-carrying / eta-reshaped constrained cons-tail impls.** No real target —
exhaustively verified ABSENT: only `Eq`/`Ord`/`Debug`/`Display`/`Hashable` instances
carry `requires`, and none BUILDS a list (their `::` is pattern-deconstruction; their
recursion is direct-tail Bool/Ordering). The headline builders (`map`/`ap`/`filterMap`/
`Applicative List`) carry no `requires` on the IMPL (it sits on the interface) → no dict
params → already covered by F2(a)/B-dispatch. `ap` recurses under `++` (C extern), not
cons-tail. Constrained list-builder typeclasses don't exist in this stdlib design.
Effort MEDIUM–LARGE, risk MEDIUM (speculative, no oracle target).
- *Detection:* relax `trmcNonDict` (rejects `leadingDictPats > 0`) to admit leading
  dict/eta params + thread them as loop-invariants (`trmcEmitParamSlots`/`trmcReloadParams`
  are already arity/slotTys-generic). The `SelfByMethod` + `mentionsSelfMethod` safety net
  is dict-agnostic → carries over.
- *NOT a pure "relax" (the seam note understates this):* `etaSaturateMethodBody` runs only
  on the `emitFn` top-level path, NOT the impl path. To TRMC an eta-reshaped constrained
  impl you'd first route eta-saturation into the impl path THEN thread the synthesized
  `$eta` params — coupling two currently-separate concerns.

**Verdict:** both seams are real + parameterized as documented; neither meets the bar
today (no target). If ever built, gate each with a synthetic SIGSEGV-before /
correct-after fixture (F1(b): `data T = N T Int`/field-0 + a self-in-middle ctor,
prelude-free path; F2(b): a synthetic `instance Builder T requires C a` through the typed
path) + full `diff_compiler_*` + `selfcompile_fixpoint` C3a/C3b.

## Phase 3 — dispatch-graph (b′) TMC for LLVM — **SHIPPED 2026-07-13 (TMC-parity arc)**

> The 2026-06-22 deferral below is retained as history.  Both of its blocking
> obstacles dissolved:
>
> - **musttail prototype-match — MOOT.** The deferral (and the preserved WIP
>   patch) assumed group members stay separate defines, forcing a uniform-arity
>   `musttail` inner ring.  But the Stage-3 detection's **v4 validation proves no
>   bind or impl outside the group references a non-root member** — so the whole
>   group INLINES into the root's ONE define: member bodies are `gdisp_<m>:`
>   basic blocks, every sanctioned tail edge is `store args into shared slots +
>   br` (no call of any kind), and the destination is a LOCAL `alloca` seeded to
>   `&hole` — the Phase-1 protocol verbatim (no module globals, no first-cell
>   flag, no reset wrapper; re-entrancy safe per activation).  Members emit no
>   standalone define.  Emit: `emitGDispGroup`/`emitGDispBody`/`emitGDispLeaf`
>   (+ leaf hooks in `emitLeaf`/`emitGuardedArm`, save/clear in `emitDecision` —
>   the same discipline as `trmcCtxRef`).
> - **detection non-termination — SOLVED upstream.** The WASM Stage-3 detector
>   (pass-0 precomputed head tables, worklist growth, hard 256-cap BFS) replaced
>   the algorithm that hung; it was lifted into the shared
>   `backend/trmc_analysis.mdk` (`detectDispatchGroups`, hook-parameterized) and
>   now runs in BOTH emitters.  Measured on the compiler's own graphs: detection
>   is ~0.6% of emit time (perf profile); whole-emit delta vs the pre-arc seed
>   emitter ≈ +4–8% on `check_main`.
>
> **Parity is the invariant now:** every eligibility decision (Stage-1/impl
> `trmcEligible`, the dispatch-graph detection, the v5 stage-1-claims predicate)
> lives in `backend/trmc_analysis.mdk`; the wasm-only uniform-ctor gate was
> retired (mixed leaf-ctor sets now emit on both backends); both emitters write
> `; tmc:` / `;; tmc:` census markers, and `test/diff_compiler_tmc_parity.sh`
> FAILS on any per-function TMC-set difference across backends
> (`test/tmc_census.sh` is the underlying census; corpus = stack fixtures + wasm
> TMC fixtures + the `check_main` module graph — 109 TMC'd fns incl. 11 dispatch
> groups, byte-identical sets).  Fixtures: `test/stack_fixtures/
> {dispatch_group_deep,mixed_ctor_deep,guard_arm_trmc}.mdk` +
> `test/wasm/fixtures/w_trmc_mixed_ctor.mdk`.
>
> **Bug found by the port (fixed 2026-07-13):** `emitGuardedArm` had no `TrmcOn`
> branch — a guarded arm in a TRMC tail-position match value-emitted its body
> into the dead `trmcdecend`/`unreachable` block: runtime UB, a SILENT
> MISCOMPILE (native printed `[]`/0 where the interpreter and WasmGC were
> correct).  Fixed by descending the guarded body via `emitTrmcBody` (and the
> group analogue); fixture `guard_arm_trmc.mdk`.

### The 2026-06-22 deferral (historical)

## Phase 3 (historical) — (b′) dispatch-into-single-target for LLVM — SCOPED & DEFERRED (2026-06-22)

The WasmGC backend gained a novel **dispatch-into-single-target (b′)** TMC
(`compiler/WASMGC-TRMC-DESIGN.md`): a tail-connected GROUP rooted at one cons-target
(e.g. the lexer's `scan`) where cons-free routers (`scanAt`) tail-call into the group
and leaves do `tok :: scan …`. A read-only-then-reverted port pass (2026-06-22)
attempted to mirror it into the LLVM backend to keep the two in sync. **Verdict:
DEFERRED — there is a fundamental ISA obstacle and native does not need it.**

**Primary obstacle — `musttail` prototype-match (no LLVM analogue of `return_call`).**
A (b′) group's members have **heterogeneous arities** (the lexer's router `scanAt` is
arity-6, the cons-root `scan` it spine-conses to is arity-5; in the compiler's own
source `variantStartsAt`/`variantStartsGo` are 7/6). WASM's `return_call` threads any
args across any callee prototype — the cross-function tail edge is free. The existing
LLVM TRMC stays *within one define* (`br %loop`, self-recursive, one prototype); a (b′)
group's only stack-safe cross-function edge is **`musttail`**, which **requires caller
and callee param counts to match exactly** (`cannot guarantee tail call due to
mismatched parameter counts`, confirmed empirically). So the WASM technique does NOT
port verbatim. The workaround that resolves it — a **uniform-arity dual-define** (public
`@mdk_<m>` at real arity + an inner `@mdk_<m>__disp` at `U = max-member-arity`, the hot
cycle musttailing a uniform inner ring with zero-padded args) — is correct in principle
but **materially larger than "mirror `emitTrmcCtor`"**, which was the STOP condition.

**Secondary — detection non-termination on the real graph.** The lifted
`detectDispatchGroups` (parameterized over `canonName`/`fnArity` closures) did not
terminate on the ~2000-bind `medaka_cli` graph (3 GB+, killed at 2 min) where the
structurally-identical WASM original terminates — a suspected O(binds²)-with-deep-walks
pathology amplified by per-call closures, not root-caused (the bootstrap's tolerant
seed-fallback masked which emitter was active, blocking an A/B test). Fixpoint not
reached.

**Why DEFER (user, 2026-06-22).** Native has a deep C stack
(`-Wl,-stack_size,0x20000000`), so (b′) overflow is rare on native — this was a
*consistency* port, not a live-bug fix. The (b′) shape that mattered (browser/V8 stack)
is already fixed on WasmGC. The cost (uniform-arity dual-define + root-causing the
non-termination, on the canonical backend, with fixpoint risk) far exceeds the benefit.
**The backends stay in sync on self-recursive + dispatched-method TMC (Phase 1/2); they
differ on (b′) by ISA necessity, not oversight.**

**If ever resumed** (a real native (b′) overflow appears): the reverted WIP was preserved
at `compiler/bprime-llvm-wip.patch` (819 lines, against base `243dbb9`). Forward options,
ranked: (1) homogeneous-arity-only subset (sound, passes fixpoint, but the real lexer
group is heterogeneous so it wouldn't transform — synthetic value only); (2) the full
uniform-arity dual-define + fix the detection non-termination.
*(Resolved 2026-07-13 by the single-define inlining above — neither option was needed;
the WIP patch was deleted as superseded.)*
