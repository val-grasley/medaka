# ARGSTAMP-UNIFY-PLAN.md — retire the `emitArgStampPasses` eval-vs-emit dispatch fork

**Status:** IMPLEMENTED — `d01a411a`, 2026-06-14. All phases (0–5) done; eval-vs-emit
dispatch fork retired (`evalDictLayerActive` has zero live code readers — verified via
`grep -n evalDictLayerActive compiler/types/typecheck.mdk compiler/eval/eval.mdk`, all
hits are `--` comments). One residual explicitly deferred (Gap 3 / generic prelude
free-fn over a typeclass receiver), tracked in `../docs/design/GAP3-SLICE7-DESIGN.md`. NOTE: AGENTS.md's
doc-index table currently (mis)describes this plan as "IN PROGRESS" / "is being
retired" — that is stale; this doc's own record is correct.

**Status:** IMPLEMENTED / COMPLETE — the flag itself is now GONE. #157 (2026-07-15,
PR #231) retired `emitArgStampPasses` entirely: elaboration is single-mode across emit,
eval, and the golden drivers, so the "vestigiality noted for follow-up" residual below
is fully closed. The Phase-0 temp parity probe (`compiler/entries/argstamp_parity_probe.mdk`
+ `test/argstamp_parity_probe.sh`) has been DELETED per this plan's own "delete at
unification end" instruction — it compared two now-identical modes. This doc is retained as
history only; the sections below describe the retired flag and are no longer live.

Status: **COMPLETE 2026-06-14.** All phases (0/1/2+3/4/5) DONE. Eval and emit now run
ONE elaboration mode (full static dict-threading); arg-tag (`filterByTag`) survives only
for the irreducible primitive `Eq Int`/`Ord Int` + genuinely-`RNone` residual — parity
with the native backend. `evalDictLayerActive` retired (zero readers). Approved
2026-06-14 (user — **full unification**). Sequel to
`compiler/DRIVER-COLLAPSE-PLAN.md` (unified single-file vs multi-module drivers;
left this finer eval-vs-emit split). Implements `TYPECHECK-AUDIT.md §6`'s "third
semantic axis." Selfhost-only; OCaml `lib/` stays the frozen byte-diff oracle.
Land BEFORE `lib/` removal (the oracle verifies every phase).

## Why
`emitArgStampPasses` is ONE flag toggling TWO dispatch-elaboration modes on the unified
driver. **Emit** (`True`): full static **dict-threading** (impl methods get leading
`$dict_` params, arg/binop sites get routes, promotion runs) — the compiler REQUIRES
it (no runtime values at codegen). **Eval** (`False`): a REDUCED dict layer + runtime
**arg-tag** dispatch (`filterByTag` in `eval.mdk`). Every fork point is a place the
two modes elaborate the SAME program differently — the documented root of #55, the
driver-collapse binop regression, and #21. Each was a reconciliation PATCH
(`evalDictLayerActive`; the now-removed `suppressBinopStamp`), not a fix of the seam.
Direction is forced: emit can't drop dict-threading, so **eval adopts it** (flip
`emitArgStampPasses := True` for the eval driver) and arg-tag retires to its irreducible
residual.

## Key findings (scoping, 2026-06-14)
- The fork is **entirely elaboration-time** (`typecheck.mdk`); the interpreter reads
  NO flag — it consumes whatever tree the typechecker produces. So unification = flip
  the flag on for the eval driver, NOT rewrite `eval.mdk`.
- **Return-position dispatch is already unified** (#55 widened `funConstraintsRef`
  reseed + the return-pos/method/rec dict layers to `emitArgStampPasses || evalDictLayerActive`).
  The ENTIRE remaining delta is **arg-position dispatch** + the #21 binop-reqs gate.
- **#21's gate becomes unconditional for free** once `resolveArgStamps` runs on eval
  (impl methods then have the `$dict_` slot the binop reqs apply to) — this work
  subsumes/cleans up the #21 fix.
- **arg-tag cannot (and should not) fully retire**: primitive `Eq Int`/`Ord Int`
  stay structural (`valueEq`/`valueCompare`) — the SAME irreducible residual the
  native backend leaves (`AUDIT §route-taxonomy 1a`). "eval == emit" holds for the
  dict-threadable user-ADT universe; primitives stay structural in BOTH. Not a fork.
  - **Deferred residual filed here — "Gap 3" (the generic prelude free-fn slice-7
    build failure).** A generic *prelude* free fn over a typeclass with a
    generic/primitive receiver (`sequence : (Traversable t, Thenable m) => …` as a
    free fn) fails `medaka build`: the caller's arg-position `debug` stays `RNone` →
    arg-tag-dispatches over primitive impl groups (no cell tag). The real fix is the
    cross-cutting **A+B** in [`../GAP3-SLICE7-DESIGN.md`](../docs/design/GAP3-SLICE7-DESIGN.md)
    (typecheck arg-stamp grounding so the site never reaches arg-tag, + a
    generic-receiver dict-threading ABI). DEFERRED (2026-06-26): zero current callers
    (per-impl specialization covers `sequence`); schedule with the A+B staging
    (`../docs/design/GAP3-SLICE7-DESIGN.md` §7) when a real generic prelude free-fn forces it. This is
    the concrete instance of "the site never reaches arg-tag" for a non-primitive
    generic receiver — adjacent to, but distinct from, the primitive `Eq Int` residual above.
- **Fixpoint is HELPED**: the compiler already self-compiles under `emitArgStampPasses=True`
  (emit), so flipping eval converges it TOWARD the existing self-compile mode.

## Fork inventory (all in `compiler/types/typecheck.mdk`; line refs as of 5ee7eef)
ALREADY CONVERGED (do not touch): F7 (`checkModuleFullImpl` reseed, `:5837/5879`),
F12 (`realizeRecDictApps`/`resolveDictApps`/`resolveMethodDicts`, `:6564/6565/6577`) —
gated `emitArgStampPasses || evalDictLayerActive` since #55. The REMAINING delta:
- **F1/F2/F8** (`argDispatchOf :1883`, `elaborateDict :2879`, `elaborateModules :6213`) — arg-dispatch index seeding; eval `argNames=[]` → arg-position uses stay bare `EVar`→`filterByTag`.
- **F10** (`moduleDictNames :6444`) — emit set = `preludeReturnPosDictNames ++ preludeArgPosDictNames ++ constrainedSigNames`; eval OMITS `preludeArgPosDictNames`. The structural asymmetry.
- **F11/F6** (`resolveArgStamps :6550`, `inferPlainImpl :4806`) — adds leading `$dict_` params to impl methods + stamps arg-site routes; skipped on eval. The core step.
- **F4** (`resolveBinopSite :3569`, the #21 fix) — element-dict `reqs` gated on `emitArgStampPasses`; becomes unconditional once F11 runs on eval.
- **F3** (`stampRLocalOrFallback :3480`) — eval `RNone` reset (C5 standalone-shadow); verify still resolves (orthogonal to arg-tag-vs-dict).
- **F9** (`:6260`) — `evalDictLayerActive := not emitArgStampPasses` (the two flags are one axis); retire at the end.

## Arg-tag dependency map (`compiler/eval/eval.mdk`) — what unification must handle
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
Flip `emitArgStampPasses := True` on the eval driver → ONE elaboration mode. Eval's
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
- **Phase 0 — parity probe (small).** Temp probe running every eval-dict fixture under both flag settings, diffing OUTPUT; establish current pass set. Gate: probe + `diff_compiler_eval_dict(+_batch)` (#55 canary).
- **Phase 1 — F10 dict-set on eval (medium).** Add `preludeArgPosDictNames` to eval's `moduleDictNames`. RISK: `neq`-hang. Canary: `medaka test stdlib/core.mdk`. Gates: `diff_compiler_test`, eval_dict(+batch), bootstrap_eval, fixpoint.
- **Phase 0 — ✅ DONE (5863541).** Parity probe + baseline: 22/25 eval-dict fixtures OUTPUT-identical under both flag modes; 3 differ (all Phase 2+3). Fork inventory F1–F12 + arg-tag map confirmed on main.
- **Phase 1 — ✅ DONE (4b6a9a3).** F10: eval `moduleDictNames` now includes `preludeArgPosDictNames`. Output-invariant; `neq`-hang did NOT fire (canary green, no narrowing). Parity unchanged 22/3.
- **Phase 2+3 — MERGED (Phase 2 cannot stand alone; the riskiest phase).** Phase 2 (index seeding F1/F2/F8) was attempted in isolation and STOPPED: it is NOT output-invariant. The plan's `EMethodAt`-with-`RNone` ≡ bare-`EVar`-arg-tag equivalence holds for *standalone* arg-position calls but FAILS for element-dispatch arg-position methods (`eq`/`compare`/`append`) occurring inside `requires`/`=>` constrained bodies: marking them `EMethodAt-RNone` regresses output (the `filterByTag`/`keepOrAll` fallback that served the bare `EVar` does not reproduce through `lookupMethod`+`methodAtNarrow RNone`; parity went 22/3 → 15/10, 8 break / 1 fix). Those sites need the actual route (`resolveArgStamps`), so index seeding and route stamping are inseparable. **Do them together:** seed `argDispatchIdxRef`/`argNames` on eval (F1/F2/F8) AND run `resolveArgStamps` (F11/F6) on eval, AND adapt the interpreter (`evalMethodAt`/`applyDicts`/`applyClosure`) so its arities consume the now-threaded leading `$dict_` params. This changes eval VALUE shapes (Phase 96/103/121/125/134 install/thunk-order hazard class) — verify with `dev/module_debug.exe` + prelude-shadowing fixtures + the 3 Phase-3 parity fixtures (`instance_requires_option`, `nested_instance_dicts`, `monoid_mutual_recursive`) flipping to PASS. Gates: parity probe → 25/0, eval_run(+batch), eval_dict(+batch), _eval_typed_modules, bootstrap_eval, fixpoint.

  **ATTEMPTED 2026-06-14 — STOPPED, BLOCKED on real #21.** The ungating (F1/F2/F8/F11/F6 + F4 fold-in) flips all 3 divergent fixtures to PASS (parity → 25/0) and needs NO interpreter change (`evalMethodAt`/`applyDicts` already consume threaded `$dict_` params — the fork is purely elaboration-time as predicted). BUT it regresses `diff_compiler_test` 9/0 → 6/3 and `diff_compiler_eval_dict` (vs OCaml golden) 22/3 → 19/6: `debug` of a nested container (`List (List a)`, `List (a,b)`) panics `'++' requires Semigroup` because a 2-level dict `RKey "List" [RKey "Int"]` does NOT compose through the interpreter's `applyDicts` + the `Debug (List a) requires Debug a` → `debugListItems` → inner-`debug` impl-body forwarding. **This is the genuine #21 nested-element-dict flattening — which the 2026-06-14 #21 fix (5ee7eef) CONTAINED (by gating eval to the arg-tag fallback), not solved.** Unification removes that containment and re-exposes it. **PREREQUISITE:** the 2-level nested element-dict composition (arg-position / constrained-impl-body path) must be genuinely fixed BEFORE Phase 2+3 can land. **METHODOLOGY CORRECTION:** the parity probe is BLIND to regressions affecting ON and OFF equally (after ungating, both modes were equally wrong vs golden, probe read 25/0 while the real gate regressed) — **`diff_compiler_eval_dict` (vs OCaml golden) is the load-bearing gate for this phase, NOT the parity probe.** No regression shipped (agent reverted to baseline; main at 49b995c = phases 0/1 only).

  **LANDED 2026-06-14 (commit 20a5c45).** The ungating (F1/F2/F8/F6/F4/F11, exactly as planned) + THREE root-caused interpreter/elaboration fixes — all confirmed empirically, all latent on baseline (arg-tag hid them), all now also benefit the pre-existing emit breakage:
  1. **Genuine #21 (2-level nested element-dict).** The bug was NOT "applyDicts can't compose a nested route" — `dictOfRoute (RKey "List" [RKey "Int"])` builds the nested `VDict` fine. It was (a) `methodAtNarrow` for an arg-position `RDict` site DISCARDED the forwarding dict's nested `reqs` (returned `[]`, unlike `RDictFwd`), so the narrowed List-impl `debug` (now carrying a leading `$dict_` param post-`resolveArgStamps`) got the VALUE applied into its dict slot → `<impl@List:<closure>>` reached `++`; AND (b) the dict can be OVER-provisioned (the structural route + requires-only impl table attributes an `Int` req to a List dict even when THIS List impl has no `requires` — two interfaces sharing the head tag), so blindly forwarding ALL reqs over-applies (`Semigroup (List a)`'s no-dict `append`). FIX (`eval.mdk`): `methodAtNarrow (RDict d)` forwards the dict's `reqs` (like `RDictFwd`), and `evalMethodAt` TRUNCATES them to the matched impl's `reqCount` (`impl-pats − declared-method-arity`, new `methodReqCountRef` built per eval driver) — mirroring emit's `emitDispatchChain` which loads only `reqCount` of the matched impl, tolerating an over-provisioned dict.
  2. **Multi-param-interface return-vs-arg misclassification (`set.mdk`/`Set {…}`).** `fromEntries : List e -> c` (`FromEntries c e`) was classed arg-position because its `List e` arg mentions the PHANTOM element param `e` → mis-routed to a `List` arg-tag site (no `List` impl) instead of return-position dispatch on `c`. Was ALSO breaking baseline `medaka build` for any Set/Map literal. FIX (`typecheck.mdk` `dispatchTyparams` + `eval.mdk` `receiverParam`): classify by the RECEIVER (FIRST) typaram only; single-param interfaces unaffected.
  3. **Mutual-recursion dict forwarding (`monoid_mutual_recursive`).** `evenCat`/`oddCat`'s constraint vars unify to one id; the GLOBAL uncleared `activeDictVars` maps it to whichever sibling registered LAST, so an arg-stamp inside `evenCat` forwarded the out-of-scope `$dict_oddCat_0`. Was ALSO breaking baseline `medaka build`. FIX (`typecheck.mdk`): `pendingArgStamps` carries `currentFn`; `resolveArgStamp` resolves via `activeDictVarOfEncl`, preferring the ENCLOSING fn's OWN dict slot for a constraint var that is encl's.

  Gates (all green): `diff_compiler_test` **9/0**, `diff_compiler_eval_dict` **22/3** (== baseline; the residual 3 = `method_constraint_foldmap_{list,string}` + `method_constraint_user_iface`, a PRE-EXISTING method-level-constraint `foldMap`/`Monoid m` gap, NOT this work — failing identically on baseline), `_batch` 7/18 (== baseline #55 residual). Emit byte-identical: `diff_compiler_llvm` 180/0, `_modules` 13/0, `_typed` 37/0, `diff_compiler_build` 21/0, `diff_native_cli` 54/0. `eval_run`(+batch) 25/0, `eval_modules` 4/0, `eval_typed_modules` 2/0, `bootstrap_eval` 20/0. Canary `core.mdk` 9/0 (no `neq`-hang). parity probe 25/0. `selfcompile_fixpoint` **C3a YES / C3b YES**. NOTE: `medaka build` (emit) of `monoid_mutual_recursive`/`Set {…}` literals still fails (separate pre-existing EMIT-PATH dict-mangling gaps — `$dict_<module>__<fn>_<slot>` not threaded); the INTERPRETER (`medaka run`, eval_dict gate) is now correct for both. Phase 2+3 done; F4 already unconditional (folded in); Phases 4 (retire `evalDictLayerActive` dead flag) + 5 (scope `filterByTag`) remain.
- **Phase 4 — F4 unconditional + retire `evalDictLayerActive` (medium).** Drop the `:3569` gate (forward reqs always); delete `evalDictLayerActive`, simplify `|| evalDictLayerActive` guards to plain `emitArgStampPasses`. Gates: full matrix + native_cli + fixpoint.
- **Phase 4 — ✅ DONE 2026-06-14.** `evalDictLayerActive` was written EXACTLY ONCE
  (`set_ref evalDictLayerActive (not emitArgStampPasses.value)`) and read only in guards of
  the form `emitArgStampPasses.value || evalDictLayerActive.value` — an **always-True
  tautology** (`p || not p`) post-Phase-2+3, since the eval path now threads dicts fully.
  Confirmed-first: each guard's body is byte-identical whether True-by-`emitArgStampPasses`
  (emit) or True-by-`evalDictLayerActive` (eval), so retiring the flag and making each
  guard **unconditional** is behavior-preserving on every gate. Simplifications (all in
  `compiler/types/typecheck.mdk`): F7 `checkModuleFullImpl` reseed (the two
  `set_ref funConstraintsRef` / `set_ref crossModuleFunConstraintsRef` guards, now plain
  `let _ = …`); F12 `realizeRecDictApps` + `resolveDictApps` + `resolveMethodDicts`
  (three guards → plain calls); `dictPassModulesIfEnabled` collapsed from a
  guarded-clause (`| emitArgStampPasses || evalDictLayerActive = …` + `| otherwise =
  (core2, modules2)`) to one unconditional `= …` body (the `otherwise` arm was dead). F4
  (`resolveBinopSite` element-dict reqs) was already folded unconditional during Phase
  2+3 (commit 20a5c45) — no `:3569` gate remained to drop. Flag DEFINITION + comment +
  the single `set_ref` setter DELETED. `grep -rn evalDictLayerActive compiler/` → **0
  live code readers** (only explanatory comments + these plan-doc history lines remain).
  Gates all green (see Verification below). `make medaka` + `selfcompile_fixpoint`
  **C3a YES / C3b YES**.
- **Phase 5 — scope surviving `filterByTag` (small).** Assert/probe arg-tag fires ONLY for primitive `Eq`/`Ord` + `RNone` residual; no groundable ADT arg-position site reaches it on eval. Gate: parity probe + fixpoint.
- **Phase 5 — ✅ DONE 2026-06-14 (analysis + retained probe).** Arg-tag dispatch
  (`filterByTag`/`keepCand`/`keepOrAll`, `compiler/eval/eval.mdk:710-724`) fires **only**
  from the single site `applyOpt (VMulti vs) arg` (`:692`) — i.e. when a method occurrence
  reaches eval as a bare un-routed `VMulti` dispatcher applied to an argument. Post-Phase
  2+3, every **groundable ADT arg-position** site is stamped with a route (`EMethodAt`
  carrying `RKey`/`RDict`) at elaboration and dispatches through
  `evalMethodAt`/`applyDicts`/threaded `$dict_` params — it NEVER reaches
  `applyOpt (VMulti …)`. So `filterByTag` is confined to the **irreducible residual**, the
  SAME residual the native backend leaves structural (AUDIT §route-taxonomy 1a):
  1. **Primitive `Eq Int`/`Ord Int`** (`==`/`<`/`<=`…) via `valueEq`/`valueCompare`/
     `evalArith` — these are structural and never construct a `VMulti` at all;
     `binopPrimitiveHead` keeps primitive operands `RNone`, so no primitive head ever gets
     a non-`RNone` arg-stamp (P3/P4 risk-register mitigation holds).
  2. **Genuinely-`RNone` sites** — a method occurrence with no groundable receiver tag
     (standalone-shadow no-impl receiver; the `keepOrAll original [] = original`
     keep-the-original-set fallback path).
  No groundable ADT arg-position site reaches `filterByTag` on eval = **parity with emit**.
  Evidence: `diff_compiler_eval_dict` 22/3 == OCaml golden (the eval path produces the
  same OUTPUT as the dict-threading emit path); the 3 residual fails are the pre-existing
  method-level-constraint `foldMap`/`Monoid m` gap, NOT arg-tag. **Probe DECISION: KEPT**
  `test/argstamp_parity_probe.sh` + `compiler/entries/argstamp_parity_probe.mdk` as a
  permanent regression gate (re-asserts eval==emit OUTPUT-convergence across the
  eval-dict corpus under both flag settings). **NOT load-bearing alone** — it is blind to
  regressions that hit ON and OFF equally (documented Phase 2+3 methodology correction);
  `diff_compiler_eval_dict` (vs OCaml golden) remains THE load-bearing gate. Stale-binary
  footgun: the probe binary `test/bin/argstamp_parity_probe` does NOT auto-rebuild —
  rebuild via `./medaka build compiler/entries/argstamp_parity_probe.mdk -o
  test/bin/argstamp_parity_probe` before trusting it.

### Unification COMPLETE — summary
The `emitArgStampPasses` eval-vs-emit dispatch fork is closed. ONE elaboration mode threads
dicts on both paths; `evalDictLayerActive` (the #55-era reconciliation patch) is retired
with zero readers; arg-tag (`filterByTag`) is scoped to its irreducible primitive +
`RNone` residual, parity with the native backend. **Vestigiality noted for follow-up (do
NOT act on here):** `emitArgStampPasses` itself still legitimately distinguishes
emit-specific concerns (arg-position stamping, `discoverPromotedModules` snapshot,
per-module impl-body inference via `implInferEnabled`, `argMeasureEnabled`). Whether
those emit-only passes can be unified or whether `emitArgStampPasses` can retire entirely is
a SEPARATE, larger question — several `emitArgStampPasses.value` / `implInferEnabled.value`
guards remain that are NOT tautologies (they genuinely gate emit-only work). Left intact.

Riskiest = Phase 3 (eval value-shape change). Phase 1 (`neq`-hang) second. FULLY sequential (shared mutable `typecheck.mdk`/`eval.mdk` + fixpoint canary).

## Risk register
- **`neq`-hang (P1)** — arg-position prelude fns in eval dict set → prop-shrinker oscillation. Canary: `medaka test stdlib/core.mdk` every phase; keep return-position discipline where genuinely return-position.
- **Primitive dispatch (P3/4)** — a primitive operand stamped `RKey "Int"` would route to a method-less `VDict` → crash. Mitigation: `binopPrimitiveHead` keeps primitives `RNone`; assert no primitive head gets a non-`RNone` arg-stamp.
- **Monomorphic-literal pinning (#55)** — preserved by the return-position layer (F12, on). Canary: `diff_compiler_eval_dict_batch`.
- **Eval-driver ordering (P3)** — leading dict params shift install/thunk-force order. Mitigation: `module_debug` + prelude-shadowing fixtures; lazy-toplevel-nullary canonical.
- **Fixpoint** — emit already runs `True`; eval converges toward self-compile mode. C3a/C3b YES mandatory each phase.
- **Surviving-unify-var-id route keying** — caught by eval_dict + _llvm_modules OUTPUT diffs.

## Effort
~6–7 days, fully sequential, peer-to-slightly-larger than the driver collapse (this
changes one path's elaboration SEMANTICS, not just callers, so more goldens
re-baseline + Phase 3 perturbs runtime value shapes). Phase 3 is the long pole.
