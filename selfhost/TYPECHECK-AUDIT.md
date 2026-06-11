# Selfhost Typechecker Audit — 2026-06-09

Audit of `selfhost/typecheck.mdk` (HM core + dict-passing layer), `selfhost/marker.mdk`,
and the typecheck↔eval seam (`selfhost/eval.mdk`, drivers, `selfhost/annotate.mdk`),
with the OCaml reference (`lib/`) as oracle, plus an architecture-level review of the
dispatch design ahead of Stage 3 (native backend canonical, gated OCaml retirement).

**Method.** Static line-by-line diff against the oracle by four parallel review passes,
then empirical verification of the high-severity claims on the built binary
(OCaml oracle = `main.exe run/check`; selfhost = `main.exe run selfhost/<driver>.mdk …`;
native = `llvm_emit_modules_main` → clang → run). Repro files under `/tmp/verify/`,
`/tmp/audit-{hm,eval}/`.

**Legend.**
- Status: `[KNOWN]` already documented (where) / `[NEW]` undocumented / `[UNCERTAIN]`.
- Verification: **CONFIRMED** (repro run, divergence observed) / **LATENT** (code path
  exists, repro does not fire today — trigger condition stated) / **STATIC** (code
  reading only, unrun).

---

## Executive summary

1. **Four confirmed divergences** between selfhost and oracle, two of them soundness-class:
   the value restriction is entirely missing (T1 — polymorphic mutable refs typecheck),
   and elaborated dicts are applied without the awaits-args gate (S1 — valid programs
   panic). Method-level constraints on explicitly-implemented interface methods misbind
   a dict into a value parameter (S2), and inline recursive `let … in` panics in the
   selfhost typechecker (T2).
2. **Coherence checking does not exist in selfhost** (S3): no overlapping-impl,
   duplicate-impl, or orphan checks — every dispatch mechanism downstream (first-match
   narrowing, arg-tag if-chains, the native `unreachable` arm) assumes a guarantee only
   the OCaml typechecker enforces. Must be a gate item for OCaml retirement.
3. **Two latent Phase-134-class hazards** are present in code but masked today: bare-name
   joint dict arity/name keying on the multi-module emit path (L1 — fires when E4 lands)
   and `RKey tag []` empty nested-req routes at `=>`-call sites (L2 — masked by arg-tag
   on the interpreter).
4. The architecture itself is **sound enough to become canonical**, conditional on:
   porting coherence, collapsing the dual eval/typecheck drivers, de-risking the two
   identity-keying fragilities (surviving unify var-id, bare names), and adding a
   differential fuzzer + error-path parity to the retirement bar. No redesign needed.
5. The recurring root pattern across findings: **semantics keyed by incidental identity**
   (unify-survivor ids, bare names, install order, first-match table order) where the
   oracle keys by resolved identity (module-scoped names, canonical impl keys,
   source order). Each port that dropped the resolution step became a finding.

Priority order for fixes: S1 → S2 → T1 → T2 → S3 → L1+L2 (before E4) → C-series → D-series.

---

## Soundness / confirmed-correctness findings

### S1. `EMethodAt` applies dicts without the awaits-args gate — valid programs panic — [NEW] ✅ CLOSED (2026-06-09, `69b3400`)

**FIXED:** ported the awaits-args gate into `selfhost/eval.mdk` `EMethodAt` (758-771,
reusing the existing `awaitsArgs` helper) — route dicts (method + impl + forwarded
reqs) apply only when the narrowed value awaits args, mirroring `lib/eval.ml:869-873`.
Repro `test/eval_dict_fixtures/instance_terminal_default.mdk` now yields `[]` ==
oracle (was `panic: applied non-function: []`). All eval-family + bootstrap + native
gates green; no S1↔S2 interaction. Original finding below.

- **Where:** `selfhost/eval.mdk:758-762`; oracle gate `lib/eval.ml:869-873`.
- **What:** the oracle folds method-/impl-dicts into the narrowed value only when it
  still awaits arguments (closure/extern/thunk). Selfhost applies unconditionally; a
  *terminal* impl body (gets no leading dict param, by `usesImplDict` design,
  `selfhost/typecheck.mdk:2606-2656`) receives a dict argument anyway.
  `selfhost/README.md:1138-1139`'s claim that narrowing "always awaits its dict arg"
  is disproven.
- **Repro** (`/tmp/audit-eval/p103_terminal_def.mdk`): `Default` interface, `def : a`,
  `impl Default (List a) requires Default a where def = []`, `main` prints
  `(def : List Int)`. Oracle: `[]`. Selfhost `eval_dict_main`:
  `panic: applied non-function: []`, exit 1.
- **Fix:** port the gate — apply `methodRef`/`implRef` dicts only when the narrowed
  value awaits args; drop them otherwise.

### S2. Method-level dict params dropped from explicit impl clauses (k-offset missing) — [NEW] ✅ CLOSED (2026-06-09)

**Fix applied:** `dictPassDecl`'s DImpl arm no longer early-returns on `reqs = []`; it
always runs `implDictPassMethods`. `prependImplDictIfUser` now prepends `dictParams n k`
(k = `methodDictArityOf n`, method-level constraint count) and offsets the impl-`requires`
dict params to slots `k..k+nReq-1` via the new `dictParamsFrom n k nReq` helper —
`dictParams n k ++ implPats ++ pats`, mirroring `dict_pass.ml:118` (`dict_pats n k @
impl_pats @ pats`) and skipping only when `k == 0 && implPats == []`. The route side
(`registerReqSlots`) starts its impl-dict slot at `methodDictArityOf mname` instead of 0,
matching `typecheck.ml:3690`'s `method_off + slot`. `implDictNames`/`usesImplDict` probe
the offset slots. Repro (`build : Num e => e -> t` / `impl Builder Box`) now prints `6` ==
oracle on the `eval_dict_main` path; fixture `test/eval_dict_fixtures/method_constraint_impl_offset.mdk`.
The 2-method method-level-constraint variant (D6 family) also works (prints `22` == oracle),
so D6 is subsumed for the method-level case. All dict/check/bootstrap/native/fixpoint gates
green; no S1↔eval interaction (eval untouched). Original finding below.

### S2 (original). Method-level dict params dropped from explicit impl clauses (k-offset missing) — [NEW] CONFIRMED

- **Where:** `selfhost/typecheck.mdk:2595-2614` (`dictPassDecl` DImpl arm →
  `implDictPassMethods`, impl-dict slots start at 0, no method-level dicts prepended);
  oracle `lib/dict_pass.ml:99-119` (`dict_pats n k @ impl_pats @ pats`) +
  `lib/typecheck.ml:3682-3690` (`method_off + slot` naming).
- **What:** a method with its own constraint (`build : Num e => e -> t`) implemented by
  an explicit impl: eval applies method dicts unconditionally first
  (`eval.mdk:758-762`), but the impl clause never gained the corresponding params —
  the dict binds the first value parameter.
- **Repro** (`/tmp/verify/dp2.mdk`): `interface Builder t where build : Num e => e -> t`;
  `impl Builder Box where build n = MkBox (n + n)`. Oracle: `6`. Selfhost
  `eval_dict_main`: `eval.mdk:1100:52: panic: unknown op '+'` — `n` is bound to the
  dict, `+` sees a non-numeric operand.
- **Fix:** in `implDictPassMethods`, prepend `dictPats n k` (k = method-level constraint
  count) before impl-requires pats and offset impl-dict names by k — direct mirror of
  `dict_pass.ml:103`. Fixing this likely also subsumes D6 (multi-method `requires`
  naming ambiguity).

### OH1. Oracle gap — combined method-level constraint + impl-`requires` + terminal body — [NEW] CONFIRMED (oracle-side, surfaced during S2)

- **What:** an interface method with BOTH its own method-level constraint AND an impl
  whose body forwards an impl-`requires` dict to a *terminal* (non-awaiting) base value
  panics on the **OCaml oracle itself**: `panic: unbound identifier: $dict_base_0`. So
  this shape has no correct reference behavior to mirror — it's a `lib/` dict-passing
  hole (the `method_off + slot` naming and the terminal-forward path don't compose).
- **Status:** out of S2 scope (S2 fixed the method-level offset; the selfhost side is
  now AHEAD of the oracle here — it would need a correct oracle to diff against).
  Register as an oracle-side dict-passing fix; relevant to retirement parity (the
  hybrid oracle must not enshrine this hole). Repro: extend the S2 fixture with an
  impl-`requires`'d terminal `base`. Low priority (niche shape, no corpus hit).


### S3. No coherence checking — overlapping/duplicate impls silently accepted — [NEW] ✅ CLOSED (2026-06-09)

- **Where:** oracle only: `lib/typecheck.ml:149-150, 3288-3293 (impls_overlap),
  3352-3370 (rejection), 3871-3885 (pick_dispatch_impl most-specific-wins)` (Phase 68).
  Selfhost: zero hits for any of it; `findImplEntry` (`typecheck.mdk:2453-2457`) takes
  the FIRST table match, comment admits the assumption ("at most one parametric impl
  per head tycon in well-formed programs"); `resolve.mdk`'s `DuplicateDefinition`
  covers value names only.
- **Why it matters:** interpreter arg-tag is ordered first-impl-wins; the native
  emitter's exhausted arg-tag arm is `unreachable` *"because the typechecker proved a
  real impl"* (`llvm_emit.mdk:2059+`). Both are sound only under a coherence guarantee
  that, post-OCaml-retirement, nothing enforces. Duplicate impls → silent
  install-order-dependent dispatch; specific-vs-parametric pairs → table order wins.
- **Fix:** port `impls_overlap` + duplicate-impl rejection into selfhost impl-table
  construction now (cheap); defer most-specific-wins until a corpus file needs it.
  Add to the Stage 3 retirement bar explicitly, with overlap/orphan rejection cases in
  the ported test suite.
- **Done (2026-06-09):** ported `check_coherence` into `selfhost/typecheck.mdk` as
  `checkCoherence` (+ `cohOverlap`/`cohSubsumes`/`cohStrictlyMoreSpecific`/`cohPpPair`
  helpers, search `coherence check (TYPECHECK-AUDIT S3)`). Each USER impl's head args
  are realized to monos under one shared fresh-var map (distinct ids per impl); the
  overlap test is the oracle's wildcard-unification `impls_overlap` byte-for-byte
  (parametric-vs-specific overlap via `a:=Int`; `a a` vs `Int Bool` correctly fails
  via resolve-before-bind). Flags, mirroring the oracle exactly: two overlapping
  `default` impls → `Multiple default impls of …`; two overlapping anonymous
  non-default impls that are NOT a strict specialization (and neither `@Name`) →
  `Overlapping impls of …`. A *named* impl or a strict specialization
  (most-specific-wins) is accepted. Impls are scanned in REVERSE declaration order
  and only the FIRST conflict is emitted, mirroring the oracle's prepend-built
  `env.impls` + raise-on-first — so the rendered head order is byte-identical. The
  check runs over USER decls only (prelude impls excluded via `setCoherenceUserDecls`,
  staged by the single-file drivers `check.mdk`/`check_batch.mdk`/`typecheck_main.mdk`;
  `checkToLines`'s prelude-free path checks its whole arg) so a user impl OVERRIDING a
  prelude impl (e.g. single-file `impl Eq Int`) is NOT flagged. **Deferred:**
  most-specific-wins dispatch (`pick_dispatch_impl` — accepted but not yet picked
  per-site; no corpus file needs it). **NOT ported — orphan-impl rejection**
  (`check_orphans`): it is a separate multi-module-only check requiring
  imported-user-module name tracking (`known_modules`), unrelated to the
  first-impl-wins / `unreachable` arg-tag soundness this finding is about, and bigger
  than "a check at impl-table construction" — left for a follow-up. Verified: 3 reject
  fixtures (`test/typecheck_error_fixtures/{dup_impl,overlapping_impls,multiple_default_impls}.mdk`)
  + 11 ad-hoc repros agree with the oracle byte-for-byte (accept AND reject decisions,
  incl. parametric/partial-overlap head rendering); no corpus program newly rejected.
  All gates green: `diff_selfhost_typecheck_errors` 24/0, `bootstrap_typecheck` 10/0,
  `bootstrap_eval` 20/0, `diff_selfhost_check(+_batch)` 34/0, `diff_selfhost_check_modules(+_batch)`
  13/0, `diff_selfhost_eval_run` 20/0, `diff_selfhost_eval_dict` 19/0, `diff_selfhost_core_ir`
  20/0, `diff_selfhost_llvm_modules` 6/0, `selfcompile_fixpoint` C3a+C3b YES.

### T1. Value restriction entirely missing — polymorphic mutable refs — [NEW] ✅ CLOSED (2026-06-09)

- **Where:** all five generalize sites generalize unconditionally:
  `selfhost/typecheck.mdk:1606` (inferLetBody), `:1390-1395` (blockLet), `:1844-1847`
  (generalizeGroup), `:3465` (sccSchemes). No `is_nonexpansive` / `lower_to_current`
  analogue exists in the file. Oracle: `lib/typecheck.ml:545-571`, applied at
  `:1688, :1716-1717, :1968, :2756`.
- **Repro** (`/tmp/audit-hm/vr_probe.mdk`): `r = Ref []` → selfhost prints
  `r : Ref (List a)`, zero errors; pushing `1 ::` then `"two" ::` accepted. Oracle
  rejects (`Type mismatch: Int vs String`). Classic polymorphic-ref hole.
- **Fix:** port `is_nonexpansive` (literals/vars/lambdas value; annot/loc transparent;
  tuple/list elementwise; ALL applications expansive incl. ctors), `gen_restricted`,
  and `lower_to_current`; thread into all five sites. Also port the Phase 89
  relaxation (signed arrow-typed point-free bindings) or top-level goldens regress.
- **Adjacent oracle hole = T1b — ✅ CLOSED (2026-06-09, both sides):**
  `lib/typecheck.ml:1968` keyed `gen_restricted` on `is_nonexpansive` only,
  ignoring the `mut` flag, and `DoAssign` (`:1976-1979`) re-instantiates per
  assignment — `/tmp/audit-hm/mutgen.mdk` (`let mut x = []` … `"s" :: x` after
  `x = [1]`) checked clean AND ran, printing a heterogeneous list on BOTH the
  oracle and (post-T1) selfhost. **Fix = gen-restrict-on-mut alone** (the
  `DoAssign` re-instantiation never fires once the binding is monomorphic, so no
  `DoAssign` change was needed — confirmed empirically). Oracle:
  `lib/typecheck.ml:1968` now computes `is_value = (not mut) && is_nonexpansive e`
  and feeds it to `gen_restricted` (value-restricted path lowers + monotypes).
  Selfhost: `blockLet` (`selfhost/typecheck.mdk:1451-1456`) now takes the `mut`
  flag (threaded from `inferStmt`'s `DoLet` arm, `:1436`) and passes
  `(not isMut) && isNonexpansive e` to `genRestricted`. `let mut x = []` is now
  monomorphic on both → `x = [1]` pins it `List Int` → `"s" :: x` rejects
  identically (`Type mismatch: Int vs String`). Valid mut (`let mut c = 0`;
  `c = c + 1`) still typechecks. Differential fixture:
  `test/typecheck_error_fixtures/mut_generalization.mdk` (prelude-free; passes
  both drivers of `diff_selfhost_typecheck_errors.sh`). All OCaml unit suites +
  selfhost/bootstrap/native/fixpoint gates green; no golden re-bless needed.
- **Fix landed (2026-06-09):** ported `isNonexpansive` / `lowerToCurrent` /
  `genRestricted` into `selfhost/typecheck.mdk` (after `generalize`) and threaded
  the value flag into all generalize sites: `inferLetBody` (now passes the RHS
  expr through `inferLet`), `blockLet` (`DoLet`/block-statement path), the
  where-clause `generalizeGroup` (gated on `clausesAreValue`), and the top-level
  `sccSchemes` (gated on `plainVal || sigIsFun`, with `isLetrecGroup` = multi-
  member SCC and the Phase 89 point-free relaxation via `memberSigIsFun`).  Mirrors
  the oracle exactly, ignoring the `mut` flag (the `mut`-gen hole is T1b).  Repro
  (`r = Ref []`; `1 :: r.value`; `"two" :: r.value`) now rejects `Type mismatch`
  == oracle; `let mut x = []` still generalizes == oracle.  Differential fixture:
  `test/typecheck_error_fixtures/value_restriction.mdk` (passes both drivers of
  `diff_selfhost_typecheck_errors.sh`).  All selfhost/bootstrap/native/fixpoint
  gates green.
### T2. Inline `let … in` drops `mut`/`is_fun` flags — recursive inline let panics — [NEW] ✅ CLOSED (2026-06-09)

- **Where:** `selfhost/typecheck.mdk:1204` (`infer env (ELet _ _ pat e1 e2)` — both
  flags wildcarded); oracle `lib/typecheck.ml:1664-1696` (is_fun → placeholder
  pre-bind for self-recursion + generalize; mut → `MutLetRequiresBlock`).
- **Repro** (`/tmp/verify/hm2b.mdk`):
  `v = let go n = if n == 0 then 0 else go (n - 1) in go 3` — oracle: OK. Selfhost:
  `typecheck.mdk:1578:39: panic: unbound variable: go`. The *block* form
  (`let go n = …` on its own indented line) is fine — `blockRecLet` pre-binds; only
  the inline/do-lowered `ELet` arm lacks it. Parser emits `ELet` for `let … in`
  (`parser.mdk:954-989`) and do-lowering preserves `isFun` (`desugar.mdk:227`), so the
  arm is reachable from ordinary surface code.
- **Fix:** split the arm like the oracle: `(is_fun, PVar x)` → placeholder + unify +
  generalize; `mut` → error (or record mut-vars once T1 lands — the two interact).
- **Done (2026-06-09):** split `inferLet` into three arms (`selfhost/typecheck.mdk`):
  `isMut` → record `mutLetRequiresBlockMsg` (byte-identical to the oracle's
  `MutLetRequiresBlock` message) then type the binding (accumulating path, no
  spurious unbound-var panic); `(isFun, PVar x)` → `inferRecLet` (placeholder
  pre-bind + unify + `generalize` — a function is a value, generalizes through the
  T1 value restriction); else → `inferLetSimple` (the prior behaviour, routing
  `PVar` through `genRestricted (isNonexpansive e1)`). Fixtures:
  `test/diff_fixtures/let_in_rec.{mdk,golden}` (accept) and
  `test/typecheck_error_fixtures/mut_let_inline.mdk` (mut-reject).

---

## Latent hazards (present in code, masked today — fix before the masking condition changes)

### L1. Bare-name joint dict arity/name keying on the multi-module emit path (Phase-134 shape) — [NEW] LATENT

- **Where:** `selfhost/typecheck.mdk:3853-3872` (`moduleDictNames` = one global
  bare-name union over all modules; `seedDictAritiesFromSigs` bare-name keyed),
  `:2595-2614` (`dictPassDecl` bare-name match), `:1339-1343` (`constraintMonosOf`
  silently drops absent ids). Oracle fix it never ported: `lib/eval.ml:2100-2163`
  (per-module arity scope = own decls + transitive importers).
- **Empirical:** two-module repro (`/tmp/verify/dp1/` — constrained `shout : Num x =>`
  in module `a`, unconstrained `shout : Int -> Int` in entry) emitted, compiled, and
  ran CORRECTLY (prints 21) — pre-E4, arg-stamping is a no-op on the multi-module path
  (documented in `llvm_emit_modules_main.mdk` E4-READINESS note), so the joint keying
  is not yet consumed. It fires the day E4 (arg-position dict-passing on
  `elaborateModules`) lands; failure mode is the worst in the project: spurious dict
  params → under-applied call → un-run partial closure, clean exit, no output.
- **Fix:** module-qualify dict-pass keys (`mid.name`) or scope
  `moduleDictNames`/arities per module (own + transitive importers), mirroring the
  OCaml fix — *as part of* the E4 work, with a loader-driven regression fixture
  (same-named constrained/unconstrained pair across modules) in the multi-module gate.

### L2. `routeOfMono` emits `RKey tag []` — nested element-dict reqs dropped at `=>`-call sites — ✅ CLOSED (one-level, 2026-06-10)

- **Where:** `selfhost/typecheck.mdk` `routeOfMono` (concrete arm returned
  `RKey tag []`, no recursion into impl requires); oracle `lib/typecheck.ml:3909-3913`
  builds `RKey (key, impl_requires_routes_rec …)`. The return-position
  `implDictRoutesFor`/`implReqRoutes` chain already recursed (Phase 83/84 mirror);
  the **build/module path** (`elabModuleStamp`) was the real victim: it passed an
  EMPTY implTable into `resolveSites` and the dict-app/arg-stamp chains, so even the
  recursive builder had nothing to recurse over → element dict `[]` → `$dict_eq_0`
  unbound at emit → SIGSEGV.
- **Fix (2026-06-10, Cause B / H-b2):** threaded the cumulative `implTable` through
  the whole return- AND arg-position route chain — `routeOfMono`'s concrete arm now
  returns `RKey tag (implRequiresRoutesRec implTable tag m)`; `routesOfMonos`,
  `resolveDictApps`, `resolveMethodDicts`, `argImplReqRoutes`, `argReqRoute` all carry
  the table; both call sites supply it (`elaborateDict` already had it; `elabModuleStamp`
  binds `stampImplTable = buildImplTable implDecls` and feeds it to `resolveSites` +
  `resolveDictApps`). ADDITIONALLY: `collectDictSites` now scans the `EMethodAt`
  impl-/method-route lists so `usesImplDict` sees a nested `RDict $dict_<m>_<slot>`
  in an arg-position element site and `implDictPassMethods` prepends the matching
  param. ADDITIVE — goldens byte-identical (resolveArgStamp never runs OFF, so the
  route lists stay `[]`); self-compile fixpoint C3a/C3b holds byte-for-byte.
- **Verified:** `data Box a = Box (List a); impl Eq (Box a) requires Eq a where
  eq (Box xs) (Box ys) = eq xs ys` builds native == oracle (`True`, no SIGSEGV).
  `import set.{Set}` programs build + run native == oracle. Fixtures:
  `test/construct_fixtures/nested_requires_dict.mdk`,
  `test/eval_dict_fixtures/nested_requires_box.mdk`.
- **RESIDUAL (still open):** (1) **two-level+ nesting** (`Box (List (List Int))`):
  the EMITTER's `dictWordOfRoute (RKey key _) = hashName key` materializes only the
  head tag — the flat i64 dict witness word cannot carry a nested dict, so deeper
  reqs SIGSEGV. Needs a richer runtime dict rep (the MEMORY "flat impl-key dict can't
  carry nested dicts" note). (2) `map`/Map build still hits a SEPARATE arg-tag gap
  (`no impl of method 'toList' for type 'Map'`), not Cause B. (3) Selfhost still lacks
  the oracle's `RHeadKey` fallback (non-ground headed monos → `RNone` → arg-tag).

---

## Correctness divergences (oracle accepts/behaves X, selfhost differs) — STATIC unless noted

### C1. Phase 73 bidirectional signature-driven parameter typing absent — ✅ CLOSED (2026-06-10)
`processSCC` runs `preunifySigsEx` (sig → placeholder) but infers clause params
bottom-up, unifying the sig after (`typecheck.mdk:3323-3361`); oracle peels sig arrows
into clause-pattern types BEFORE body inference (`typecheck.ml:2604-2644`). Programs
relying on checking-mode propagation typecheck on the oracle, fail or infer differently
on selfhost; error positions diverge. **Fix:** port arrow-peel + zip-unify into
`inferMembers`.

- **Done (2026-06-10):** ported the oracle's arrow-peel + zip-unify into the
  per-clause inference path. `inferMembers` (`typecheck.mdk`) now computes a peel
  source per member via `memberPeelSource` — `Some placeholder` when the member has
  a signature, `None` otherwise. (The placeholder already holds the sig
  instantiation, unified in by `preunifySigsEx`; its shared tyvars accumulate
  unifications across clauses exactly as the oracle's `sig_t` does — so peeling the
  placeholder is byte-faithful and needs no re-instantiation.) The source threads
  through `inferMemberClauses` → `inferClauseEff`, which calls new `peelOntoParams`
  AFTER `inferPats` (fresh param TVars) but BEFORE `infer …body`: for a signed
  clause with params it `peelArrows (length pats) src` (peel up to one arrow per
  param, normalizing at each level; stops early on a partial sig) and `zipUnify`s
  the equal-length prefix onto the param types. Unsigned member, value binding
  (no params), and out-of-arrows cases are all no-ops. Purely additive — the
  existing per-clause `unify v arrow` imposes the same equalities, so the solution
  is unchanged; the peel only makes the param types concrete *earlier* so
  type-directed body expressions (receiver-directed field access, `String`-indexed
  `ESlice`) resolve from the signature alone. SCC grouping / generalization /
  mutual-recursion paths untouched (contained checking-mode addition to the clause
  inference, not an SCC-path rewrite). **Unlocks the C2 + C9 sig-typed-param
  residuals:** `g : String -> Char; g s = s.[0]` was `Type mismatch: String vs
  Array a` (fresh receiver TVar defaulted to Array) → now `String -> Char` == oracle;
  two records sharing a field with sig-typed params (`getA : A -> Int; getA a =
  a.shared` + `getB : B -> String; getB b = b.shared`) was `Ambiguous field access`
  (fresh receiver TVar, both owners survive) → now resolves each receiver-directed
  == oracle. Single-owner sig param (`unwrap : Box -> Int; unwrap b = b.val`)
  worked on both before/after. Fixture: accept `test/diff_fixtures/sig_param_typing.mdk`
  (+ golden; flows through check + eval_run gates). Gates: bootstrap_typecheck 11/0,
  bootstrap_eval 20/0, diff_selfhost_check 36/0 + _batch 35/0, check_modules 14/0 +
  _batch 13/0, typecheck 11/0 + _golden 21/0, typecheck_errors 28/0, eval_run 22/0 +
  _batch 21/0, eval_dict 20/0, core_ir 20/0, llvm_modules 6/0, selfcompile_fixpoint
  C3a+C3b YES (the compiler's own inference unchanged — the critical canary holds).

### C2. Phase 72 receiver-directed field resolution absent — first-match field lookup — ✅ CLOSED (2026-06-09)
`lookupRecordByField` returned the first record declaring the field
(`typecheck.mdk:1726-1732`); panicked on unknown field. Oracle: `field_owners` multimap +
receiver-directed pick + `AmbiguousField`. Two records sharing a field name → selfhost
typed against whichever was declared first. **Fix:** port the multimap; receiver head
known → pick that owner; else error.

- **Done (2026-06-09):** rewrote `inferFieldAccess` / `inferRecordUpdateField` in
  `selfhost/typecheck.mdk` to mirror lib/typecheck.ml's `EFieldAccess` (Phase 72). New
  helpers: `fieldOwnerNames` — the field_owners multimap, derived live from `recordsRef`
  (every registry KEY whose `RecordInfo` declares the field, `sortUniqS`-deduped, matching
  the oracle's `field_candidates` + `List.sort_uniq compare`; key = record type name for a
  `record`, ctor name for a named-field variant, exactly like the oracle's `add_field_owner`);
  `resolveFieldRecord` — receiver-directed pick returning `Option (String, RecordInfo)`:
  (a) receiver head tycon is a known record → that record; (b) undetermined `TVar` receiver
  → 0 owners = `UnknownField "<unknown>"`, 1 = that owner, >1 = `AmbiguousField`; (c) concrete
  non-record → first owner so the later `unify` surfaces the usual `Type mismatch`.
  `inferFieldOfRecord` names the resolved record on an unknown field (mirrors `resolve_in`).
  Both error messages are byte-for-byte with the oracle (`unknownFieldMsg`/`ambiguousFieldMsg`),
  pushed into `typeErrors` instead of `panic`. The `value` Ref-projection special case is
  preserved (no record in selfhost/stdlib declares a `value` field, so the guard coincides
  with the oracle's structural `(Ref a).value → a`). Repros vs oracle: two records sharing
  `x` (`Int` vs `String`) — `(b : B).x → String` (was `Int` first-match), `(a : A).x → Int`,
  record literal `(A {…}).x` resolves; `(b : B).x` used as `Int` → `Type mismatch: Int vs
  String` (== oracle); undetermined receiver `r.x` → `AmbiguousField '.x' declared by A, B …`
  (== oracle, both tc_main + check); `(r : A).z` → `Field z does not belong to record A`
  (== oracle, names the record). Single-owner unannotated access (`distSq p = p.x`) still
  resolves — sole candidate path, no Phase 73 needed. **Dependency noted:** the unpinned-param
  shape `getA : A -> Int; getA a = a.x` resolves on the oracle via Phase 73 (signature-driven
  param typing) but is AMBIGUOUS on selfhost — gated by **C1** (Phase 73 absent), not C2. The
  C2 accept fixtures therefore pin the receiver by annotation/literal; once C1 lands the
  sig-typed-param case will resolve too. Fixtures: accept `test/diff_fixtures/record_shared_field.mdk`
  (+ golden; flows through check/eval_run/core_ir/llvm gates), reject
  `test/typecheck_error_fixtures/ambiguous_field.mdk`. Gates: bootstrap_typecheck 10/0,
  bootstrap_eval 20/0, diff_selfhost_check 35/0 + _batch 35/0, check_modules 13/0 + _batch 13/0,
  resolve 14/0 + _batch 14/0 + _modules 10/0, typecheck_errors 28/0, eval_run 21/0 + _batch 21/0,
  core_ir 20/0 + core_ir_run 21/0, llvm 170/0 + llvm_typed 33/0 + llvm_modules 6/0,
  selfcompile_fixpoint C3a+C3b YES.

### C3. `AnnotationTooGeneral` check missing — ✅ CLOSED (2026-06-09)
`inferAnnot` (`typecheck.mdk:1631-1636`) unifies the annotation's fresh vars with the
inferred type — `(intId : a -> a)` silently grounds `a := Int` and accepts where the
oracle rejects (`typecheck.ml:1821-1842`). An annotation can over-claim polymorphism.
**Fix:** after unify, require the annotation's tyvar-table entries to remain distinct
unbound vars; emit the error into `typeErrors`. Keep `EHeadAnnot` exempt (oracle does).

- **Done (2026-06-09):** added `astTypeFreshTbl` (returns the Mono + the name→fresh-tyvar
  map, mirroring `sigToSchemeTvs`) and reworked `inferAnnot` (`typecheck.mdk`) to call it,
  then `checkAnnotTooGeneral ty (map snd tvs)` after the unify. The distinctness check
  reuses the existing `sigTvarIds`/`hasDupI` helpers: `sigTvarIds` keeps only entries that
  normalize to a `TVar` (grounded ones drop out), so the condition
  `lengthL ids < lengthL resolved || hasDupI ids` flags BOTH grounding (`a := T`) AND
  collapse (two annotation vars → same var), matching the oracle's `all_distinct_tvars`.
  On failure it pushes `annotTooGeneralMsg ty` (byte-for-byte with the oracle's message)
  into `typeErrors`. `EHeadAnnot` is exempt by construction — only `EAnnot` routes through
  `inferAnnot` (selfhost has no `infer` arm for `EHeadAnnot`; it'd hit the slice-1 panic),
  so head-pins are untouched. Repro `data T = MkT; g x = match x { MkT => MkT }; h = (g : a -> a)`:
  before = selfhost printed schemes (accepted); after = `TYPE ERROR: Type annotation 'a -> a'
  is more polymorphic …` == oracle, both `tc_main` and `check` drivers. Valid `id x = x; (id : a -> a)`
  and concrete `(k : T -> T)` stay accepted on both. Fixture: `test/typecheck_error_fixtures/annot_too_general.mdk`.
  Gates: bootstrap_typecheck 10/0, bootstrap_eval 20/0, diff_selfhost_check 34/0 + _batch 34/0,
  typecheck_errors 26/0, eval_run 20/0, core_ir 20/0, llvm_modules 6/0, selfcompile_fixpoint C3a+C3b YES.

### C4. Unreferenced zero-param bindings' effects never run — ✅ RESOLVED BY DECISION (2026-06-10): lazy IS canonical
Selfhost `evalOutput` forces only `main` (`eval.mdk:1563-1569, 1597-1600`); nullary
bindings are lazy `VThunk`s (the documented Phase-125 replacement, `eval.mdk:1607-1611`).
Oracle forces ALL deferred nullary thunks in source order (`eval.ml:2075-2076, 2318`).
`sideEffect = println "side"` before `main` prints on the oracle, not on selfhost.
**DECISION (user, 2026-06-10): LAZY is canonical** — top-level bindings are definitions
(values), not statements; effects flow only through `main`; an unreferenced effectful
binding does nothing. Grounded in the functional model + the capability-effects thesis (an
effect firing because a binding merely exists = spooky-action-at-a-distance, the opposite of
explicit effects). Selfhost (Phase-125) is already correct; the oracle's eager forcing is the
legacy/script behavior — NOT reverted. Loose end (low priority): document the divergence in
driver headers / diff harnesses, or make the dying oracle lazy for gate-cleanliness. See
memory `lazy-toplevel-nullary-canonical`.

### C5. Phase-112 standalone-vs-method machinery unported: no `lookup_method`, no `RLocal`, install-order shadowing — ✅ CLOSED 2026-06-10 (`5db8a83`)
**Closed by porting `lib/`'s `RLocal` end-to-end into selfhost** (selfhost-only; `lib/` already had it).
Repro `box.mdk`/`main.mdk` (standalone `toList`/`isEmpty` over a no-Foldable `Box`, used alongside
genuine Foldable `toList`/`isEmpty`) now prints `[1,2]/F/F/[7]` across interpreter, selfhost-typed-eval,
AND native, matching the oracle. Pieces: (i) `RLocal` in `ast.mdk` `Route`; (v) sexp ser/parse arms;
(iii) typecheck `standaloneValuesRef` + `methodDispatchIdxRef` + re-bind shadow names to the graph-wide
method scheme + `resolveRLocalSites` (runs last: no-impl receiver → `RLocal`, genuine → `RNone`/as-is);
(iv) eval `lookupMethod` walks past a non-method shadow (discriminates VTypedImpl=method vs
VClosure=standalone) + `EMethodAt RLocal → lookupEnv`; (vi) emitter `RLocal → direct call to mdk_<name>`.
Install-order "distinguishable sets" was contained (selfhost frame model already separates import-frame
standalone from global-frame impl VMulti — surfaced as a route-stamp ordering + a lookupMethod shape
discriminator). **Fixpoint did NOT re-baseline — C3a/C3b byte-identical** (compiler's own source has no
standalone-shadowing-method site). New gate `test/diff_selfhost_eval_typed_modules.sh` + fixture; all
gates green. (Scoping had recommended defer; reprioritized to close per user — a retirement-gate parity
gap reachable by `map`/`set` `toList` shapes.)


### C5 (original detail).
Three related gaps: (a) `EMethodAt` resolves via plain `lookupEnv` — first frame wins;
oracle's `lookup_method` (`eval.ml:223-234`) walks past non-method shadows to the
VMulti; (b) selfhost `Route` has no `RLocal` (`ast.mdk:38`); (c) `evalProgram` installs
impls then groups into shared first-cells — a name that is both standalone and impl
method always resolves standalone (`eval.mdk:1252-1267`), regardless of source order.
The `annotate.mdk:28-31` header claim that a by-name scan "already reaches a global
method's VMulti past any local frame" is incorrect when an import/local frame binds the
name. Note: the obvious single-module repro is rejected by the oracle too (verified —
`No impl of HasSize for Int`), so the user-visible shape needs an imported standalone
or prelude redefinition; exact blast radius [UNCERTAIN]. **Fix:** port `lookup_method`
+ an `RLocal` analogue; merge standalone+impls into one VMulti candidate set per name.

### C6. `stripBody` re-forces nullary impl thunks without memoising — ✅ CLOSED (2026-06-09)
`eval.mdk:603-618, 1161-1165` — a point-free return-position impl body re-evaluates per
occurrence (effects/cost duplicated); oracle evaluates once (`eval.ml:1899-1903`).
Combined with S1, wrapper-kept thunk + non-empty dicts can panic. **Fix:** memoise
(write back through the cell) or evaluate eagerly like the oracle.

**Done:** `implMethodValue` (`eval.mdk`) now builds the nullary return-position thunk
via `memoThunk env body` — a `VThunk` that captures a private `Ref (Option Value)`
created ONCE (outside the lambda). First force evals `body` and stores `Some v`;
later forces read it back without re-evaluating. The thunk lives nested in a
`VTypedImpl.inner` inside a `VMulti` list (no Ref cell of its own), so the existing
`forceCell`/`forceMemo` cell-memoisation never reached it and `stripBody`'s direct
`f ()` re-ran the body every `EMethodAt` occurrence. memoThunk makes the thunk
idempotent regardless of forcer (`stripBody`/`forceCell`/`force`), so the body's
effects/work run once — identical VALUE to before, matching the oracle's eager-once
semantics. Repro (`test/eval_dict_fixtures/return_pos_memoised.mdk`): a return-position
`theUnit : a` impl whose body prints `[eval]`, referenced twice at the same concrete
type — before: selfhost printed `[eval] [eval] XX`, oracle `[eval] XX`; after: both
`[eval] XX`. All eval/dict/typed/modules/check/core_ir + native llvm_modules +
selfcompile_fixpoint gates green; no value change in any existing program.

### C7. Selfhost `RKey` carries head tycon, not canonical impl key — ✅ CLOSED (2026-06-10)
`ast.mdk:160`, `eval.mdk:680-682` (`hasTag` matches head-tag only) vs oracle
`select_impl_by_key` (`eval.ml:600`). Two impls sharing a head tycon both survive
narrowing → falls to first-impl-wins. Compounds S3 (no overlap rejection upstream).
**Fix:** carry the canonical impl key (typecheck knows it at stamp time); match
`VTypedImpl.key`.

**Done.** Mirror of `lib/ast.ml`'s `impl_key` (`iface|<prec-2 args>|name`) added on
both sides: `eval.mdk` `implKeyOf`/`ppTyAtomK` (impl install now stamps the canonical
key into `VTypedImpl`'s key field instead of the bare iface name); `typecheck.mdk`
`implKeyTc` + a `KeyEntry` registry (`buildKeyTable`/`keyForSite`, `resolveSite`).
Narrowing (`eval.mdk` `hasTag`/`matchesTag`) now matches the route string against
EITHER the head tycon (field 1) OR the canonical key (field 2) — disjoint string
spaces (a bare tycon never contains `|`), so no cross-match. To keep the native
Core-IR/LLVM backend (which keys symbols by head tycon) byte-identical, `keyForSite`
UPGRADES a ground route to the full key ONLY when ≥2 impls of the method share a head
tycon (the genuine collision); every single-impl-per-head site keeps the head tag.
Repro `test/eval_dict_fixtures/same_head_impls.mdk` (`Def (Pair Int Bool)` /
`(Pair Bool Int)`): oracle = selfhost-dict-eval = `1,True / False,2` (each type picks
its own impl). Self-compile fixpoint (C3a/C3b) holds; all eval/check/core-ir/llvm
gates green. **Residual:** the native Core-IR/LLVM backend does not yet disambiguate
same-head impls (its `CImplTagged`/`implFnName`/`implFor` plumbing is head-tag-keyed);
the collision case only resolves on the tree-walking dict-eval path. Closing the
native side would touch the emitter's tag scheme broadly (out of C7 scope).

### C8. Module export surface incomplete on the typed path — ✅ CLOSED (2026-06-09)
(a) `publicValNames` omits interface methods (`typecheck.mdk:3704-3710` — DFunDef/
DTypeSig/DExtern only): a non-core module's interface methods don't export their
schemes. (b) `checkModuleFullImpl` lacks the `inferDefaultBodiesIfEnabled` call
`checkProgramSeeded` has (`:2841` vs `:3675-3695`) — module-path default bodies skip
inference checking. Both violate the mirror-both-entry-points discipline the OCaml side
documents. **Fix:** extend `publicValNames` to DInterface method sigs; add the hook to
the module path.

**Done (2026-06-09):** (a) `publicValNames` (`typecheck.mdk`) now peels `DAttrib` and
exports the method names of every `DInterface { pub = True, … }` via a new
`ifaceMethodNames` helper — mirrors `lib/typecheck.ml`'s `pub_iface_schemes`
(`is_pub = true` interfaces append their method schemes). Before: a wildcard-importing
module panicked `unbound variable: <method>` on the selfhost typed module path; after:
exports the scheme and typechecks == oracle. Fixture
`test/check_module_fixtures/iface_method_export/` (driven by a new fixtures section in
`test/diff_selfhost_check_modules.sh`) regresses without the fix. (b) Added
`inferDefaultBodiesIfEnabled` to `checkModuleFullImpl` right after
`inferModuleImplBodiesIfEnabled`, gated identically (`implInferEnabled`) — the module
path now mirrors `checkProgramSeeded`'s default-body hook. On the LLVM emit path
(`elaborateModules` sets `implInferEnabled := argStampEnabled`, ON) the module path now
reaches the same default-body inference as the single-file emit path.
**C8b residual — ✅ CLOSED (2026-06-10, c203aff):** `inferDefaultBodies`/
`inferDefaultMethod` only inferred **constraint-carrying** default bodies (methods in
`methodConstraintsRef`, e.g. `foldMap`'s `Monoid m`) — for the dict-slot registration.
A *plain* unconstrained default body (`greet x = 5`) was skipped on BOTH selfhost entry
points, and on the plain-check driver the hook was gated OFF entirely. The OCaml oracle
type-checks ALL default bodies unconditionally during interface registration
(`lib/typecheck.ml:3079-3110+`). **Fix (2026-06-10):** (i) `inferDefaultBodiesIfEnabled`
now always calls `inferDefaultBodies` unconditionally (gate removed); (ii) `inferDefaultMethod`
gains a new `None` arm that instantiates the scheme, infers the body, and unifies — same as
the `Some ids` arm minus `registerMethodDictSlots`. Both arms share `inferDefaultMethodBody`
which includes a double-error guard (snapshot `typeErrors` length before body inference;
skip the outer `unify` if new errors were already pushed — prevents duplicate errors from
the accumulating system that the oracle's raise-on-first avoids). Both selfhost entry points
covered (`checkProgramSeeded` + `checkModuleFullImpl`, both call `inferDefaultBodiesIfEnabled`).
Repro `test/typecheck_error_fixtures/default_body_type_error.mdk`; oracle == selfhost.
No `lib/` changes needed. Compiler's own default bodies (Ord.lt/gt/min/max,
Foldable.length/isEmpty, Filterable.filter) type-check correctly — self-compile fixpoint
C3a+C3b YES. No corpus program newly rejected. Gates: diff_selfhost_typecheck_errors 36/0,
diff_selfhost_check 39/0, diff_selfhost_check_modules 15/0, bootstrap_typecheck 12/0,
dune build @thorough 100/100, selfcompile_fixpoint C3a+C3b YES.

### C9. `inferIndex` is List-only; container default diverges — ✅ CLOSED (2026-06-09)
`typecheck.mdk` `inferIndex` unified every `xs.[i]` receiver with `List elem`; oracle
branches String→Char / Array / List and defaults *Array* for undetermined receivers
(`typecheck.ml:2198-2210`). **Done:** ported the oracle's normalize-and-branch into
`inferIndex` + helpers `inferIndexElem`/`indexElemAs` (`typecheck.mdk`): `normalize`
the receiver, then `String → Char`, `List a → a`, everything else (Array, undetermined
`TVar`, clean mismatch) → `Array a -> a`. Verified each branch == oracle via
`dev/tc_probe.exe`: undetermined `f xs = xs.[0]` now `Array a -> a` (was `List a -> a`);
`"…".[i] : Char`; `[…].[i]` / cons-forced `List` index → element. Fixture
`test/typecheck_fixtures/index_default.mdk`. No goldens shifted (corpus had no
undetermined-receiver index site). **Residual (NOT C9, pre-existing):** with an
annotated param (`g : String -> Char; g s = s.[0]`) the selfhost checks the body with
`s` still a fresh `TVar` → Array default → conflicts with the annotation; the oracle
binds the annotated param type *before* body inference and accepts. That is the Phase 73
signature-driven-param-typing gap (upstream of `inferIndex`), symmetric (whatever the
default container, the other annotated container fails) — out of C9 scope.

### OBS4. Record construction missing-field check absent — ✅ CLOSED (2026-06-10)

Surfaced during D1 (PLAN.md OBS4). `inferRecordCreateWith` called `unifyFieldAssigns`
(which validates that SUPPLIED fields exist in the declared set) but never checked that
ALL declared fields are present. So `Pt { x = 1 }` omitting a required field typechecked
clean on selfhost; the oracle rejects with `Missing field y in construction of record MkPt`
(`lib/typecheck.ml:2042-2044 / 2073-2075`, `MissingField` variant).

**Fix:** added `checkMissingFields` (`selfhost/typecheck.mdk:1547-1559`) — iterates the
declared field list from `instantiateRecord` and pushes `missingFieldMsg fname rname`
(`"Missing field <f> in construction of record <r>"`) for each absent name, mirroring the
oracle's per-declared-field loop. Called from `inferRecordCreateWith` BEFORE
`unifyFieldAssigns`. `fieldAssignContains` helper walks the supplied `FieldAssign` list.
Message byte-identical to oracle (`lib/typecheck.ml:718`). Applies to both plain record
construction and named-field variant construction (both route through `inferRecordCreateWith`).

**Verification:** `Pt { x = 1 }` (omits `y`) → `TYPE ERROR: Missing field y in
construction of record MkPt` on both oracle and selfhost. `Pt { x = 1, y = 2 }` →
accepted on both. Fixture `test/typecheck_error_fixtures/missing_field.mdk` (plain record
form; passes both `tc_main` and `check.mdk` drivers in `diff_selfhost_typecheck_errors.sh`).
All bootstrap/check/eval/core_ir/llvm_modules/selfcompile_fixpoint gates green.

---

## Diagnostic-quality / contained divergences

- **D1. Error discipline split-brain** — unify/effect errors accumulate into
  `typeErrors` (finer-grained than the oracle's fail-fast `Type_error`), but unknown
  ctor/record/field and unbound-variable errors are uncatchable interpreter panics
  (`typecheck.mdk:1578, 1143, 1108/1123/1421/1428`). Resolve pre-screens variables but
  NOT record/field/ctor shapes. [KNOWN-partial — resolve-first assumption documented.]
  **Fix:** convert the record/field/ctor panics into `typeErrors` entries. ✅ CLOSED
  (2026-06-10): converted the six user-facing panic sites to accumulated `typeErrors`
  entries + a fresh-var placeholder (oracle accumulate-and-continue analog), with
  byte-identical messages to `lib/typecheck.ml`:
  - `inferVar` (unbound variable → `Unbound variable: <x>`, `UnboundVar`)
  - `inferPatCon` (unknown constructor in a pattern → `Unknown constructor: <n>`,
    `UnknownCtor`); error path still infers the sub-patterns so their bindings reach
    the arm body (else spurious downstream unbound-var errors the oracle never reaches)
  - `inferPatRec` (unknown record in a pattern → `Unknown record type: <n>`,
    `UnknownRecord`); new `bindRecPatFieldsFresh` binds the field pattern vars against
    fresh types on the error path (same anti-cascade reason)
  - `inferRecPatField` (unknown field in a record pattern → `Field <f> does not belong
    to record <r>`, `UnknownField`); threaded the record name through
    `inferPatRecWith`/`inferRecPatFields`; error path binds the field's vars via
    `inferRecPatFieldWith` with a fresh type
  - `inferRecordCreate` (unknown record in construction → `Unknown record type: <n>`)
  - `unifyFieldAssign` (unknown field in construction → `Field <f> does not belong to
    record <r>`); threaded the record name through `inferRecordCreateWith` and the two
    record-update callers (`inferRecordUpdatePicked` via `resolveFieldRecord`'s resolved
    name, `inferRecordUpdateWith`/`inferVariantUpdate` via the constructor name).
  **Left as panics (deliberate):** `inferMethodAt` "unbound method" + `inferDictAt`
  "unbound constrained fn" (`EMethodAt`/`EDictAt` are produced by the marker pass on
  ALREADY-resolved names — a miss is an internal invariant, not a user error the oracle
  recovers from); `inferRecordUpdate` "empty record update" + `inferVariantUpdate`'s
  non-named-field shapes (desugar invariants). **Path note:** these shapes are observable
  ONLY on the no-resolve differential path (`dev/tc_probe.exe` oracle vs
  `selfhost/typecheck_main.mdk`) — the full front-end (`selfhost/check.mdk`) catches them
  in resolve first and stops before typecheck (by design). New gate +
  fixtures: `test/diff_selfhost_typecheck_panic_errors.sh` reading
  `test/typecheck_panic_fixtures/` (6 fixtures, driver-A/no-resolve only, all == oracle,
  no panic). No regression across bootstrap/check/eval/core_ir/llvm_modules/fixpoint.
- **D2. `LetRecNonFunction` guard absent** from `processSCC` (`typecheck.mdk:3161-3315`
  vs oracle `typecheck.ml:2591-2597`) — recursive value bindings infer or loop instead
  of the dedicated error. [NEW] ✅ CLOSED (2026-06-10): added `checkLetRecDecls` +
  `checkLetBind` in `typecheck.mdk`; called from `checkProgramSeeded` before body
  inference. Guard fires on `DLetGroup` members whose all clauses have zero params and
  non-lambda RHS. Fixture: `test/typecheck_error_fixtures/letrec_non_function.mdk`.
- **D3. No operator/interface obligations** — `"a" - "b"` typechecks (`arithOp` merely
  unifies operand types; no Num entailment). [KNOWN — header-documented scope cut.]
  Listed because it changes the accepted set; long-term port obligation recording.
- **D4. `RHeadKey` route missing from selfhost** (`ast.mdk` Route lacks it; oracle
  `lib/ast.ml:74`, Phase 115 #4) — non-ground headed dict applications degrade to
  arg-tag/RNone. Programs the oracle elaborates regress when it retires. [NEW]
- **D5. marker.mdk `shadowRename` lacks the local-rebind capture guard + let-group
  coverage** (`marker.mdk:74-111` vs `method_marker.ml:306-352`): a file redefining a
  prelude standalone while also using that name as a local binder gets the reference
  renamed past the binder; no `nondroppable_shadow` diagnostic. [KNOWN — deferred in
  marker.mdk:70-73; corpus-fragile, no diagnostic when tripped.]
- **D6. Multi-method `requires`-impl dict naming ambiguous** — per-method names
  disambiguate only for single-method interfaces (`typecheck.mdk:3003-3031`, comment
  admits). [KNOWN — D3b-1 scope note.] Subsumed by the S2 fix (method_off + slot).
- **D7. `activeDictVars` keyed by tyvar id only, interface-blind** —
  `(Eq a, Hash a) =>` (two constraints, one tyvar) can forward the wrong slot's dict;
  benign while dicts are consumed head-tag-only, mis-threads once L2 lands structured
  reqs. [NEW; UNCERTAIN impact today — corpus has only single-constraint sites.]
  **Fix:** key by `(iface, id)`.
- **D8. annotate.mdk DoLet arm ignores `rec`** — RHS annotated one frame shallow vs
  `blockRecLet`'s push (`annotate.mdk:199-200` vs `eval.mdk:930-936`). Dormant
  (no driver runs annotate); loud when activated. [NEW]
- **D9. `@Impl` hints unsupported in selfhost eval** — `EVar "@Name"` → VUnit, then
  applied (`eval.mdk:746`); no `VNamedImpl`. [UNCERTAIN — possibly deliberate scope.]
  **Fix:** port, or reject the syntax with a diagnostic.
- **D10. Top-level `DLetGroup` never installed** by `evalProgram` (`eval.mdk:1119-1122`)
  → unbound-identifier panic. [KNOWN — README TODO-blocked list.]
- **D11. Prelude dict-pass coverage hole in drivers** — only `eval_dict_main`
  (single-file) dict-passes the prelude; `eval_typed_main`/`eval_typed_modules_main`
  never do, and **no multi-module dict driver exists** — `when`/`unless` → `pure`
  through the loader is an unexercised corner of the seam. [NEW] **Fix:** add the
  multi-module dict driver (it's also the E4 prerequisite) and fold dict-passing into
  the typed default.

---

## Architecture assessment (Stage 3 readiness)

Condensed verdicts; the dispatch design needs consolidation, not redesign.

1. **Route taxonomy (RKey/RDict/arg-tag): sound-with-caveats.** Post-D3b the emit path
   is `RKey`/`RDict` for 1012/1013 arg-position sites; residuals = `max`/`min` over
   primitive `Ord` (already PLAN'd) + the `empty`/`foldMap` default. Native composite
   cell tags (`typeId*2^32 + ordinal`) make distinct ADTs collision-free, BUT:
   (a) primitives share the immediate rep — arg-tag on a primitive is correctly a hard
   gap natively; (b) a user ctor reusing a reserved name (`Some`/`Cons`/`Ok`/`Lt`…)
   aliases the reserved tag block (`llvm_emit.mdk:3154-3158`) — make that a compile
   error; (c) D4/C7 above are the taxonomy's two real holes.
2. **Surviving-unify-var-id route keying: fragile.** Working, with a documented
   near-miss (a generalization fix that changed unify's representative choice silently
   broke routing — see memory/PLAN Phase 136 notes). The constraint is tribal
   knowledge in two codebases; any unifier refactor (Stage 3 housekeeping!) is the
   tripwire. **Smallest:** assert at route registration that the id is its own
   representative + a thorough-suite test exercising var-var unify both orders.
   **Principled:** evidence variables allocated at constraint introduction
   (GHC-style), keyed by provenance not representative — schedule with the driver
   collapse, not before.
3. **Joint dict-pass with bare-name keying: fragile** (= L1). Module-qualified keys
   capture ~all the risk at ~10% of the cost of per-module dict-pass with explicit
   cross-module signatures.
4. **Flat dicts / no nested instance dicts: sound-with-caveats** (= L2). Native side
   fails loud (`ensureNoReqs` panic); interpreter return-position fails at runtime.
   Convert to a typecheck-time error now; port the OCaml structured-dict design
   (already built there) before retirement, or document as a language limit in
   SYNTAX.md and gate retirement on the diagnostic.
5. **Coherence: unsound-risk on retirement** (= S3). Gate item.
6. **Dual drivers (single-file vs modules, in eval AND typecheck): fragile — the
   recurring defect.** Five phases (96/103/121/125/134) were loader-only bugs; the
   selfhost gate split (`argStampEnabled` emit path vs golden path) adds a third
   semantic axis. **Recommendation:** collapse single-file to the 1-module case of the
   modules path in both compilers during the Stage 3 housekeeping refactor, while the
   byte-diff safety net exists; delete the flat path once `test_run`/doctests pass
   through the unified one.
7. **Effects × dispatch: sound.** Effect rows are erased before codegen and have no
   dispatch interaction; remaining effects work (manifest emission, the closed-closed
   point-free aliasing subsumption hole) is manifest-soundness, not dispatch.
8. **Trust chain: sound-with-caveats — strongest today, weakest post-retirement.**
   Byte-diff bootstrap fixtures + self-compile fixpoint + panic-by-default gaps are
   real defenses; the CTGuard incident proves the silent-blank failure mode is real.
   Post-retirement the oracle becomes a natively-compiled tree-walker validating
   itself (trusting-trust loop). **Add to the retirement bar:** (a) every reachable
   gap a hard error in `medaka build` (incl. refutable `Pat <- e` guards);
   (b) per-SYNTAX.md-construct native==interpreter fixture matrix; (c) differential
   fuzzer with shrinking; (d) keep the last OCaml binary as a frozen third oracle;
   (e) error-path parity (selfhost panics vs oracle accumulated diagnostics — D1)
   before the test-suite port, or it ports green-path-only.

---

## Verification ledger

| Finding | Run | Result |
|---|---|---|
| T1 value restriction | selfhost `typecheck_main` on `Ref []` probes | CONFIRMED — accepts, `Ref (List a)` scheme |
| T1-adjacent oracle mut hole | oracle `run` on `let mut x = []` probe | CONFIRMED — heterogeneous list printed |
| T2 inline rec-let | oracle `check` OK; selfhost `typecheck_main` | CONFIRMED — `panic: unbound variable: go` |
| S1 awaits-args gate | oracle `[]`; selfhost `eval_dict_main` | CONFIRMED — `applied non-function: []` |
| S2 method-dict offset | oracle `6`; selfhost `eval_dict_main` | CONFIRMED — `panic: unknown op '+'` |
| L1 bare-name emit keying | 2-module native emit+clang+run | NOT FIRED — prints 21 (pre-E4 no-op confirms latency) |
| L2 nested reqs at `=>`-site | selfhost `eval_dict_main`, arg-position shape | NOT FIRED — prints 3 (arg-tag masks); return-position shape = S1's repro family |
| C5 install-order shadow | oracle rejects the single-module shape | repro shape invalid; finding stays static |
| S3, C1-C4, C6-C9, D1-D11 | static + grep | unrun — repro sketches in finding text |

Pipeline-order, dict application order (method → impl → fwd reqs), `RDictFwd` gating,
RecDictApp realization, Tarjan SCC + Phase-136 merge, row unification + EffectLeak,
`SignatureTooGeneral`, occurs/level machinery, annotate's frame model (except D8), and
per-module frame isolation were all checked and found faithful to the oracle.
