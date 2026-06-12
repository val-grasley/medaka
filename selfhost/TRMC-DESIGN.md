# TRMC-DESIGN.md — tail-recursion-modulo-cons for the native LLVM backend

Design for native TRMC (destination-passing) in `selfhost/llvm_emit.mdk`, the last
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

## Emitter touchpoints (`selfhost/llvm_emit.mdk`)

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
  **Mandatory post-gate: `selfcompile_fixpoint.sh` + `diff_selfhost_llvm.sh`.**

## Gate

New deep-list stack-safety fixture (`test/diff_native_stack.sh` or extend
`diff_selfhost_llvm.sh`): `upto 1 2_000_000 |> length` — **SIGSEGV before,
print `2000000` after**, stdout == interpreter oracle.

## Phase 2 (deferred, if warranted)

(a) Dispatch/dict-passed methods (`map`/`filterMap` via instances — interacts with
eta-saturation, medium risk); (b) `match`/`if`-arm tail descent (`filterMap`'s
in-arm cons); (c) general single-constructor last-field TMC (not just `::`). Each
independently gateable. Until Phase 2, stdlib `map (+1) [1..1M]` still overflows;
hand-rolled builders are stack-safe.

## Phase 1 — AS BUILT (2026-06-11, `selfhost/llvm_emit.mdk`)

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

**Gates (all green):** `diff_selfhost_llvm` 172, `_modules` 9, `_typed` 37,
`diff_selfhost_build` 15, `diff_native_cli` 54; `selfcompile_fixpoint` C3a **YES** /
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
path); a multi-field non-`::` ctor builder (Axis A). Plus full `diff_selfhost_*` + `diff_native_cli`
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

## Phase 2 Axis A — AS BUILT (2026-06-11, `selfhost/llvm_emit.mdk`, #56)

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

**Gates (all green):** `diff_selfhost_llvm` 172, `_modules` 9, `_typed` 37,
`diff_selfhost_build` 15, `diff_native_cli` 54; `selfcompile_fixpoint` C3a **YES** / C3b
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
