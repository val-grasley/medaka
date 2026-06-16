# Design: Num-polymorphic numeric literals (PLAN.md #11)

> Read-only scoping pass, 2026-06-16 (worktree base `2a54937`, BASE_OK). Decisions
> in §6 are the open forks; §0 records the locked choices once the user rules.

## 0. Locked decisions (user, 2026-06-16)
1. **Int literals only** (fork 1.i). `1`/`0` → `Num a`; float literals (`1.0`) stay
   monomorphic `Float`. No `Fractional` class.
2. **Default-to-Int** (fork 2). A top-level/ambiguous `Num`-only var defaults to `Int`
   (a monomorphism rule for `Num`); no exported `Num a => a` constants, no constant
   dict-passing.
3. **Defer the `fromInt` revert to Stage 5** (fork 3). Ship #11 (Stages 0-4) first;
   revert `sum`/`product` `fromInt 0/1`→`0/1` only as a separate gated follow-up.
4. **`PLit (LInt)` patterns stay `Int`** (fork 4). Only `ELit` goes polymorphic.

## 1. Empirical problem statement

All transcripts from `./_build/default/bin/main.exe` (OCaml oracle).

**(a) Cannot make a literal a `Float` by context:**
```
x : Float
x = 0
main = println x
-- /tmp/p_float_lit.mdk:2:4: Type mismatch: Float vs Int
```

**(b) Mixed literal arithmetic rejected:**
```
main = println (1.0 + 2)
-- :1:22: Type mismatch: Int vs Float
```

**(c) Bidirectional sig doesn't reach the literal — the crispest case:**
```
g : Float -> Float
g x = x + 1          -- `1` forced to Int even though x : Float
-- :2:10: Type mismatch: Int vs Float
```

**(d) Bare defaulting already "works" — but only because literals are concretely `Int`:**
```
main = println (1 + 2)      ==> 3        (type Int, monomorphic)
```

**(e) `sum`/`product` are polymorphic TODAY via the `fromInt` workaround** (not via #11):
```
sum [1.0, 2.0, 3.0]    ==> 6.0
product [2, 3, 4]      ==> 24
```
Source `core.mdk:745`: `sum xs = fold (+) (fromInt 0) xs` (commit fa0bbe9, "closes G9").

**Numeric class hierarchy (confirmed `core.mdk:467-495`):** there is **only `Num`**
(`add/sub/mul/div/negate/abs/signum/fromInt`, `requires Eq`). No `Fractional`, `Real`,
`Integral`, or separate `Float` class. `div` is overloaded inside `Num`. **Consequence:**
float literals have no class to be polymorphic over — float-literal polymorphism is a
genuine fork (§6.1).

## 2. Mechanism

### 2.1 The `litType` change (the easy 5%)
- OCaml `lib/typecheck.ml:1775-1777` `type_lit` (used by `ELit` :1985 and `PLit` :1791).
- Selfhost `selfhost/types/typecheck.mdk:2050-2052` `litType` (used by `inferPat (PLit)`
  :1987 and `infer (ELit)` :2121).

Change `LInt _ -> Int` to: fresh tyvar `a` + a `Num a` obligation. The operator path
**already does exactly this** for `+ - * /` (oracle `binop_type:2833-2834`
`record_iface_usage "Num" "add"`; selfhost `recordNumObligation:2701-2706`). So the literal
change reuses the operator machinery wholesale.

### 2.2 The hard 95%: where defaulting fires, and the eval problem

**Fact A — no defaulting step exists, by design.** Both checkers defer any obligation whose
head type is non-concrete (`lib/typecheck.ml:4085-4093` `is_concrete`; selfhost
`allConcreteHeads`). A `Num a` with `a` unbound is **silently dropped**. Today benign because
`litType` grounds the var to `Int`. Under #11 the var stays unbound through generalization:
either it generalizes (`n = 1` → `Num a => a`, surfacing in every type dump) or it leaks an
**ambiguous unconstrained `Num a`** to eval. A real **defaulting pass** must be added: at a
let-group's generalization boundary, find tyvars constrained *only* by `Num` (no other class,
no concrete link) and **unify them with `Int`**. New machinery in *both* checkers.

**Fact B — eval is value-tagged; literals are not elaborated.** `lib/eval.ml:788`
`ELit (LInt n) -> VInt n` unconditionally. `eval_arith` (:1255-1278) dispatches on the runtime
tag and **errors on mixed tags**. So even if `x : Float; x = 0` typechecks, eval yields
`VInt 0` and `0.0 + x` crashes. **The literal's runtime rep must follow its inferred type** →
**elaboration**: rewrite a `Float`-typed `LInt n` into `LFloat (float n)` in the typed pipeline
(the `dict_pass`/marker stage already rewrites post-typecheck), mirrored in the native emitter.

### 2.3 HM levels / value restriction / monomorphism
- **Levels:** the fresh literal var is at `current_level`; defaulting must run **at
  generalization boundaries** (oracle `generalize:937`, selfhost `generalizeGroup:3251`).
- **Value restriction:** `ELit` is non-expansive, so `n = 1` *would* generalize to
  `Num a => a`. Defaulting at the group close intercepts this → policy decision (§6.2).
- **No existing monomorphism rule.** Defaulting must define one for the `Num`-only case, or
  accept exported `Num a => a` (which needs dict-passing for plain numeric constants — large
  ripple).

### 2.4 Two-compiler parity (the headline risk)
The defaulting decision must be **byte-identical** between the two checkers in every case:
which vars are "Num-only", iteration order over the constraint set, per-group vs module-end,
interaction with deferred obligations. Gated by `diff_selfhost_typecheck_golden*.sh` and the
self-compile fixpoint. Any asymmetry → fixpoint divergence.

## 3. Touchpoint map

**OCaml `lib/typecheck.ml`:** `type_lit` 1775-1781 (split ELit vs PLit); `ELit` arm 1985;
`binop_type` 2808-2834 (compose, avoid double obligations); `is_concrete`/constraint-checking
4083-4125 + generalize sites 937 / 2212-2219 / 2494-2501 (**add defaulting pass here**);
value-restriction 1020-1053.

**Selfhost `selfhost/types/typecheck.mdk`:** `litType` 2050-2056 + `infer (ELit)` 2121 +
`inferPat (PLit)` 1987; `recordNumObligation`/`numIfaceRegistered` 2679-2715 (reuse);
`generalize` 1554-1556 / `generalizeGroup` 3251 (defaulting insertion); `scopeArities`
7206-7229 (**the `fromInt 0` workaround's reconciliation — reverting changes inferred
arities here**).

**Ripples beyond typecheck:** `lib/eval.ml:788` + typed elaboration/`dict_pass` stage
(literal re-tag — **mandatory**, Fact B); native emitter `selfhost/backend/llvm_emit.mdk`
(re-tag mirror — `i64` vs `double` constant); `stdlib/core.mdk:745,750` (optional revert).

**The two PLAN sub-gaps (~332-336):** (a) RNone arg-tag for a `fromInt`/section in an
*unconstrained* fn — **in-scope and unavoidable** (#11 creates unconstrained `Num a` vars;
the defaulting pass §2.2 IS the fix). (b) poly-`a` auto-print mistypes the print routine —
**in-scope**: if defaulting grounds to `Int` before eval, `println` sees `VInt` and prints
fine; a *consequence* of the defaulting policy, not separable.

## 4. Blast radius
- **Type-dump goldens move.** `test/diff_fixtures/*.golden` (109) + `native_cli_goldens/check/*`
  (27) print inferred schemes. `test/diff_fixtures/lit.golden:129,135` shows
  `product : a Int -> Int` / `sum : a Int -> Int` today. **Estimate 30-60 goldens move**,
  dominated by the shared prelude type dump.
- **`scopeArities` (typecheck.mdk:7214) flips.** Reverting `fromInt 0`→`0` makes `sum`'s
  `Num a` var survive generalization → inferred arity == sig arity, *removing* the divergence
  the workaround dodges — **but only if dict-passing now threads the `Num` dict to call
  sites**; get it wrong and `sum` SIGSEGVs at `-O2`. Highest-risk interaction.
- **Fixpoint risk (selfhost half):** defaulting-order asymmetry breaks `selfcompile_fixpoint`;
  native re-tag must match interp or `diff_selfhost_llvm`/`_build` (output-compared) fails.
- **Eval gates:** `test_eval`/`test_run`/doctests mixing int/float literals could shift.

## 5. Staged plan (OCaml-first-then-mirror, each independently gated)
Rationale: the frozen OCaml oracle is the differential reference; land defaulting there first
so every selfhost stage diffs against a known-correct oracle (lockstep has no oracle until
both are done — exactly the parity risk to de-risk early).

- **Stage 0 (spike, no commit):** OCaml only — `litType (LInt)`→fresh `Num a` var + minimal
  default-to-Int at the top-level generalize boundary. Verify (a)-(c) pass, (d) still `3`.
- **Stage 1 (OCaml typecheck + defaulting):** full pass at all generalize sites; MR policy
  (§6.2). Gate: `test_typecheck`, re-capture type-dump goldens, `@thorough`.
- **Stage 2 (OCaml eval elaboration):** literal re-tag `LInt`→`LFloat` in the typed pipeline.
  Gate: `test_eval`/`test_run`, float-mix programs run.
- **Stage 3 (selfhost typecheck + defaulting):** mirror Stages 1-2, byte-matching oracle
  defaulting order. Gate: `diff_selfhost_typecheck_golden*`, `diff_selfhost_check`.
- **Stage 4 (native emitter re-tag):** mirror in `llvm_emit.mdk`. Gate: `diff_selfhost_llvm`/
  `_build`, then `selfcompile_fixpoint`.
- **Stage 5 (optional workaround revert):** `fromInt 0/1`→`0/1` in `core.mdk`; re-verify
  `scopeArities` + `-O2` `sum`/`product`. Gate: full bench + fixpoint. **Land last, separately
  — riskiest, NOT required for the feature.**

## 6. Design forks (need a human decision)
1. **Integer literals only, or also float?** Only `Num` exists. (i) **Int-only** — `1.0` stays
   monomorphic `Float`, `1` becomes `Num a`; simplest, covers (a)-(c). (ii) float literals over
   `Num` — unsound-ish (`1.0 :: Int` would typecheck). (iii) new `Fractional`/`Floating` class —
   separate larger feature. **Recommend (i).** *Gates the whole scope.*
2. **Monomorphism rule at module boundaries?** Top-level `n = 1` → `Int` (default) or
   `Num a => a` (polymorphic constant, dict-passed)? Exporting `Num a => a` makes **every
   numeric constant dict-passed** (large eval/emit ripple + perf cost). **Recommend
   default-to-Int (MR-for-Num).**
3. **Revert the `fromInt 0/1` workaround?** The *motivation* but **separable**. **Recommend:
   ship #11 (Stages 0-4) first, revert in Stage 5 as a gated follow-up** once the
   arity/`scopeArities`/`-O2` interaction is proven; keep `fromInt` as the proven fallback.
4. **`PLit (LInt)` patterns:** keep monomorphic `Int`? A pattern `0` matching a `Float`
   scrutinee is exotic. **Recommend patterns stay `Int` (only `ELit` goes polymorphic)** to
   bound scope.

## 7. STOP-worthy risks
- **Float-literal polymorphism (fork 1.iii)** → new `Fractional` class through both checkers +
  stdlib impls = a *second* feature. STOP and split.
- **Exporting `Num a => a` constants (fork 2, no MR)** → every literal becomes a dict-passed
  value; touches `dict_pass`, eval driver, native emit. STOP and reassess.
- **`sum`/`product` `-O2` SIGSEGV** (typecheck.mdk:7214 warning): reverting the workaround may
  re-introduce inferred-vs-sig arity divergence under dict-passing — a native-only crash the
  interp won't show. Stage 5 gated on a clean `-O2` `sum`/`product` bench; keep `fromInt` as
  fallback.
- **Defaulting-order parity** between the two checkers is the silent fixpoint-breaker. Budget
  real time for Stage 3 diffing.

## Critical files
- `lib/typecheck.ml` (litType 1775, ELit 1985, binop_type 2808, is_concrete 4083, generalize 937)
- `selfhost/types/typecheck.mdk` (litType 2050, recordNumObligation 2701, generalizeGroup 3251, scopeArities 7206)
- `lib/eval.ml` (ELit 788, eval_arith 1255 — mixed-tag crash / re-tag site)
- `selfhost/backend/llvm_emit.mdk` (native literal constant — re-tag mirror)
- `stdlib/core.mdk` (Num interface 467, sum/product fromInt workaround 745/750)
