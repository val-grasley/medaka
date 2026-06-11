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
