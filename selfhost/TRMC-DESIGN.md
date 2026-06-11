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

## Phase 1 scope (APPROVED)

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
