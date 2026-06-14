# ARGSTAMP-UNIFY-PLAN.md — retire the `argStampEnabled` eval-vs-emit dispatch fork

Status: APPROVED 2026-06-14 (user — **full unification**). Sequel to
`selfhost/DRIVER-COLLAPSE-PLAN.md` (unified single-file vs multi-module drivers;
left this finer eval-vs-emit split). Implements `TYPECHECK-AUDIT.md §6`'s "third
semantic axis." Selfhost-only; OCaml `lib/` stays the frozen byte-diff oracle.
Land BEFORE `lib/` removal (the oracle verifies every phase).

## Why
`argStampEnabled` is ONE flag toggling TWO dispatch-elaboration modes on the unified
driver. **Emit** (`True`): full static **dict-threading** (impl methods get leading
`$dict_` params, arg/binop sites get routes, promotion runs) — the compiler REQUIRES
it (no runtime values at codegen). **Eval** (`False`): a REDUCED dict layer + runtime
**arg-tag** dispatch (`filterByTag` in `eval.mdk`). Every fork point is a place the
two modes elaborate the SAME program differently — the documented root of #55, the
driver-collapse binop regression, and #21. Each was a reconciliation PATCH
(`evalDictLayerActive`; the now-removed `suppressBinopStamp`), not a fix of the seam.
Direction is forced: emit can't drop dict-threading, so **eval adopts it** (flip
`argStampEnabled := True` for the eval driver) and arg-tag retires to its irreducible
residual.

## Key findings (scoping, 2026-06-14)
- The fork is **entirely elaboration-time** (`typecheck.mdk`); the interpreter reads
  NO flag — it consumes whatever tree the typechecker produces. So unification = flip
  the flag on for the eval driver, NOT rewrite `eval.mdk`.
- **Return-position dispatch is already unified** (#55 widened `funConstraintsRef`
  reseed + the return-pos/method/rec dict layers to `argStampEnabled || evalDictLayerActive`).
  The ENTIRE remaining delta is **arg-position dispatch** + the #21 binop-reqs gate.
- **#21's gate becomes unconditional for free** once `resolveArgStamps` runs on eval
  (impl methods then have the `$dict_` slot the binop reqs apply to) — this work
  subsumes/cleans up the #21 fix.
- **arg-tag cannot (and should not) fully retire**: primitive `Eq Int`/`Ord Int`
  stay structural (`valueEq`/`valueCompare`) — the SAME irreducible residual the
  native backend leaves (`AUDIT §route-taxonomy 1a`). "eval == emit" holds for the
  dict-threadable user-ADT universe; primitives stay structural in BOTH. Not a fork.
- **Fixpoint is HELPED**: the compiler already self-compiles under `argStampEnabled=True`
  (emit), so flipping eval converges it TOWARD the existing self-compile mode.

## Fork inventory (all in `selfhost/types/typecheck.mdk`; line refs as of 5ee7eef)
ALREADY CONVERGED (do not touch): F7 (`checkModuleFullImpl` reseed, `:5837/5879`),
F12 (`realizeRecDictApps`/`resolveDictApps`/`resolveMethodDicts`, `:6564/6565/6577`) —
gated `argStampEnabled || evalDictLayerActive` since #55. The REMAINING delta:
- **F1/F2/F8** (`argDispatchOf :1883`, `elaborateDict :2879`, `elaborateModules :6213`) — arg-dispatch index seeding; eval `argNames=[]` → arg-position uses stay bare `EVar`→`filterByTag`.
- **F10** (`moduleDictNames :6444`) — emit set = `preludeReturnPosDictNames ++ preludeArgPosDictNames ++ constrainedSigNames`; eval OMITS `preludeArgPosDictNames`. The structural asymmetry.
- **F11/F6** (`resolveArgStamps :6550`, `inferPlainImpl :4806`) — adds leading `$dict_` params to impl methods + stamps arg-site routes; skipped on eval. The core step.
- **F4** (`resolveBinopSite :3569`, the #21 fix) — element-dict `reqs` gated on `argStampEnabled`; becomes unconditional once F11 runs on eval.
- **F3** (`stampRLocalOrFallback :3480`) — eval `RNone` reset (C5 standalone-shadow); verify still resolves (orthogonal to arg-tag-vs-dict).
- **F9** (`:6260`) — `evalDictLayerActive := not argStampEnabled` (the two flags are one axis); retire at the end.

## Arg-tag dependency map (`selfhost/eval/eval.mdk`) — what unification must handle
`filterByTag`/`keepCand`/`keepOrAll` (`:650-663`) via `applyOpt (VMulti vs) arg`
(`:631`) is the arg-tag engine; fires at every F1/F11 site eval skips. Load-bearing for:
1. **Primitives** — `valueEq`/`valueCompare` via `evalArith` (`:1239`); `==`/`<` on
   primitives never reach a `VMulti`. **Eval legitimately keeps this structural** (so
   does native). `binopPrimitiveHead` (`:3502`) already keeps primitive operands `RNone`.
2. **ADT arg-position dispatch** (`toList`/`isEmpty`/`map` on a user receiver) — the
   878 D3a sites; these MIGRATE to threaded dicts under unification.
3. **Return-position/no-arg** (`pure`/`empty`/`fromInt`, the `neq`-hang) — already
   dict-threaded (F12). Unification must add arg-position dicts WITHOUT regressing the
   return-position-only discipline that keeps the `neq`-hang closed.

## Unification design
Flip `argStampEnabled := True` on the eval driver → ONE elaboration mode. Eval's
`evalMethodAt`/`applyDicts` consume the now-uniformly-threaded dicts; `evalDictLayerActive`
retires (dead). Turn on F1/F2/F8/F11/F6 + F10's `preludeArgPosDictNames` for eval; F4
becomes unconditional. **Keep `filterByTag` ONLY for the primitive/`RNone` residual**
(assert no groundable ADT arg-position site reaches it on eval — parity with emit).
Safety core: emit already self-compiles under `True`, so eval converges toward the
existing self-compile mode (fixpoint strengthened, not threatened).

## Phasing (sequential; each byte-diff-gated vs OCaml oracle + `selfcompile_fixpoint` C3a/C3b YES)
Eval-dict goldens WILL shift (arg-position dicts thread on eval → different elaborated
trees, identical OUTPUT). The OUTPUT diff is the correctness gate; IR/tree goldens
re-baseline per phase. **Structured so phases 1+2+4 alone already close #55/#21/binop
observably — a clean partial landing if Phase 3 balloons.**
- **Phase 0 — parity probe (small).** Temp probe running every eval-dict fixture under both flag settings, diffing OUTPUT; establish current pass set. Gate: probe + `diff_selfhost_eval_dict(+_batch)` (#55 canary).
- **Phase 1 — F10 dict-set on eval (medium).** Add `preludeArgPosDictNames` to eval's `moduleDictNames`. RISK: `neq`-hang. Canary: `medaka test stdlib/core.mdk`. Gates: `diff_selfhost_test`, eval_dict(+batch), bootstrap_eval, fixpoint.
- **Phase 2 — F1/F2/F8 index on eval (medium).** `argDispatchOf` returns the index; `argNames` populated; arg-position uses become `EMethodAt`. Gates: eval_dict(+batch), _eval_typed, _eval_modules, fixpoint.
- **Phase 3 — F11/F6 stamps on eval (medium-large; RISKIEST).** Impl methods get leading `$dict_` params on eval; arg-sites get routes. Changes eval VALUE shapes (Phase 96/103/121/125/134 ordering-hazard class). Verify `evalMethodAt`/`applyDicts`/`applyClosure` arities with `dev/module_debug.exe` + prelude-shadowing fixtures. Gates: eval_run(+batch), _eval_typed_modules, bootstrap_eval, fixpoint.
- **Phase 4 — F4 unconditional + retire `evalDictLayerActive` (medium).** Drop the `:3569` gate (forward reqs always); delete `evalDictLayerActive`, simplify `|| evalDictLayerActive` guards to plain `argStampEnabled`. Gates: full matrix + native_cli + fixpoint.
- **Phase 5 — scope surviving `filterByTag` (small).** Assert/probe arg-tag fires ONLY for primitive `Eq`/`Ord` + `RNone` residual; no groundable ADT arg-position site reaches it on eval. Gate: parity probe + fixpoint.

Riskiest = Phase 3 (eval value-shape change). Phase 1 (`neq`-hang) second. FULLY sequential (shared mutable `typecheck.mdk`/`eval.mdk` + fixpoint canary).

## Risk register
- **`neq`-hang (P1)** — arg-position prelude fns in eval dict set → prop-shrinker oscillation. Canary: `medaka test stdlib/core.mdk` every phase; keep return-position discipline where genuinely return-position.
- **Primitive dispatch (P3/4)** — a primitive operand stamped `RKey "Int"` would route to a method-less `VDict` → crash. Mitigation: `binopPrimitiveHead` keeps primitives `RNone`; assert no primitive head gets a non-`RNone` arg-stamp.
- **Monomorphic-literal pinning (#55)** — preserved by the return-position layer (F12, on). Canary: `diff_selfhost_eval_dict_batch`.
- **Eval-driver ordering (P3)** — leading dict params shift install/thunk-force order. Mitigation: `module_debug` + prelude-shadowing fixtures; lazy-toplevel-nullary canonical.
- **Fixpoint** — emit already runs `True`; eval converges toward self-compile mode. C3a/C3b YES mandatory each phase.
- **Surviving-unify-var-id route keying** — caught by eval_dict + _llvm_modules OUTPUT diffs.

## Effort
~6–7 days, fully sequential, peer-to-slightly-larger than the driver collapse (this
changes one path's elaboration SEMANTICS, not just callers, so more goldens
re-baseline + Phase 3 perturbs runtime value shapes). Phase 3 is the long pole.
