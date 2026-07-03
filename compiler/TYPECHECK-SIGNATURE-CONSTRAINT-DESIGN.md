# Signature Constraint Soundness — Design + Blast-Radius Census

**Status:** DESIGN + CENSUS (no fix shipped). 2026-07-03.
**File under study:** `compiler/types/typecheck.mdk` (~10.7k lines).
**Base:** ancestor of `32a51317` (BASE_OK).

## The bug (re-confirmed)

A user function whose explicit signature **omits a typeclass constraint its body
requires** is accepted, and the omission **severs the constraint for downstream
callers**, causing wrong-dictionary dispatch (a silent wrong answer).

Decisive repro:

```
interface Greet a where
  greet : a -> String
impl Greet Int where
  greet n = "int"
sayHi : a -> String          -- MISSING `Greet a =>`
sayHi x = greet x
useIt : b -> String          -- MISSING `Greet b =>`
useIt y = sayHi y
main = println (useIt "hello")
```

`medaka check` accepts; `medaka run` prints `int` — dispatching `greet` on a
**String** via the **Int** impl. Expected: rejected at check.

### Empirically established boundary (probed on the binary)

| Case | `sayHi` sig | `useIt` sig | Result |
|------|-------------|-------------|--------|
| A | signed, no ctor | — (`sayHi "hello"` direct) | **caught** `No impl of Greet for String` |
| B | signed, no ctor | — (`sayHi 5` direct) | runs `int` (Int impl exists — correct) |
| C/D | signed, no ctor | unsigned | **BUG** → `int` |
| E | unsigned | signed, no ctor | **BUG** → `int` |
| F | unsigned | unsigned | **caught** (error) |

**Reading:** either written signature severs. When both are unsigned (F) the
inferred-constraint promotion path propagates `Greet` through the whole chain and
the concrete `useIt "hello"` at `String` is caught. The single-hop direct call
(A) is caught because the callee's tyvar is *grounded concrete* at that use. The
bug is specifically a **signed** binding whose body induces an interface
constraint on a quantified var that is **absent from the declared context**, and
whose declared (empty) context then governs downstream dict-passing.

---

## 1. Root-cause trace

### 1.1 The Scheme carries no constraint context

Medaka's `Scheme` is `Forall (List Int) (List Int) Mono` — quantified value-var
ids, quantified effect-var ids, and a mono. **There is no constraint context in
the scheme.** Constraints live out-of-band in module-level refs
(`funConstraintsRef`, `funConstraintIfacesRef`, `schemeObligationsRef`,
`activeDictVars`). This is the structural reason the leniency exists: for a signed
binding, the declared sig's constraints are written into those refs while the
body's inferred constraints are collected separately and **never reconciled**.

### 1.2 The seam: `processSCC` (lines 8925–8967)

Per letrec/SCC group:

```
8933  let (regs, sigTvMaps) = preunifySigsEx sigs placeholders   -- DECLARED ctor regs (from the SIG)
8934  let _ = inferMembers env2 sigs grouped placeholders          -- infer bodies
8935  let _ = checkSigsTooGeneral sigTvMaps                         -- (unrelated: tyvar-collapse check)
8936  let _ = registerConstraintRegs regs                          -- adopt DECLARED ctors → funConstraintsRef
...
8947  let addedObls = takeFirst (… - oblN0) pendingImplObligations.value   -- INFERRED obligations
...
8960  let schemes = sccSchemes …                                   -- (m, genRestricted isVal v) — no context
8961  let _ = registerSchemeObligations addedObls schemes          -- records inferred (iface, var-id) — ALWAYS-ON
8962  let _ = registerInferredConstraints sigs schemes             -- promotes UNSIGNED members' inferred ctors
```

**Declared side.** `preunifySigsEx` (8986–8996) builds a signed member's
constraint list *only from the signature text*:

```
8994  let regs = [(m, constraintVarIfaceMonos (sigConstraints ty) (snd inst))]
```

`sigConstraints` (9007–9009) reads only `TyConstrained cs _`; for `sayHi : a ->
String` it is `[]`. `registerConstraintRegs`→`registerMember` (9033–9060) writes
that (empty) list into `funConstraintsRef`/`funConstraintIfacesRef` — the tables
that drive downstream **dict-passing arity**. Empty ⇒ no dict param ⇒ **the
constraint is severed for every caller**.

**Inferred side, but never compared.** The body's inferred obligations *are*
collected (`addedObls` at 8947) and `registerSchemeObligations` (9322–9330)
records the `(iface, quantified-var-id)` pairs the body actually required (via
`schemeObligationsOf`/`schemeObligationOne`, 9335–9353). Its own comment
(9315–9321) admits the asymmetry: *"A signed member's declared `=>` constraints
come from its sig instead … an unsatisfiable one SHOULD error."* But **nothing
computes `inferred ⊆ declared` for a signed member.** `registerInferredConstraints`
→ `maybeInferConstraint` (9309–9313) even *explicitly skips signed members*
(`omHasKey m sigNameSetRef.value = ()`), so the inferred `Greet` is deliberately
not promoted into `sayHi`'s dict tables.

### 1.3 Why single-hop is caught but the chain is not

The `schemeObligationsRef` entry recorded at 8961 is consumed only when the
binding is used as a plain `EVar`: `instantiateVarTracked` (4176–4193) instantiates
the recorded obligations *tracked* and pushes each onto `pendingCallObligations`;
after inference `checkCallObligations` (7783) → `checkOneCallObligation` (8018–8028)
→ `noImplFoundMsg` (8211–8212) rejects a **concrete** dispatch head with no impl.

- **A** (`sayHi "hello"`): the obligation instantiates to `Greet String`, a
  concrete head with no impl → caught.
- **B** (`sayHi 5`): `Greet Int` — impl exists → correctly silent.
- **C/D/E** (`useIt y = sayHi y`): at the `sayHi y` site the obligation
  instantiates to `Greet b` where `b` is still a **polymorphic tyvar** (useIt's
  own quantified var). A polymorphic head *defers* (never rejects). It is supposed
  to re-attach as a scheme obligation of `useIt`, but because `useIt` is **signed
  with an empty context**, its declared regs win and the obligation chain is
  dropped — so when `useIt "hello"` finally grounds `b` to `String`, no obligation
  fires. The definition-site check that would have rejected `useIt` (and `sayHi`)
  for omitting the constraint does not exist.

### 1.4 There is a precedent to mirror: `checkEffectEscape`

Effects already do exactly the reconciliation constraints lack.
`checkEffectEscape` (9164–9172), called from `inferMembers` (9099), compares a
signed member's body-inferred concrete effects against the signature's declared
effect row and rejects extras:

```
9165 checkEffectEscape sigs m effs = match lookupAssoc m sigs
9167   Some ty => match atomsEscape effs (declaredEffects ty)
9169     extras => pushTypeError (effectEscapeMsg m (declaredEffects ty) extras)
```

`checkSigsTooGeneral` (9216–9241, called 8935) is a second, weaker precedent — it
already reconciles the declared sig against post-inference facts (tyvar-collapse),
but ignores constraints. The missing check is the constraint analogue of
`checkEffectEscape`.

---

## 2. The fix formulation

**Check:** for a binding with an explicit signature, the set of interface
constraints **inferred from its body** on the binding's own quantified vars must
be a **subset of the declared constraint context, closed under the interface
`requires` (superclass) graph**. Any inferred constraint not covered ⇒
`type_error`.

**Where it slots in:** `processSCC`, immediately after
`registerSchemeObligations addedObls schemes` (line 8961) and before
`registerInferredConstraints` (8962). At that point every input is already in
hand:

- **Declared context** — `regs` (8933): `[(m, [(iface, mono)])]`, each mono
  normalizing to the quantified-var id. (Prototype `declaredPairsOf`.)
- **Inferred obligations** — two sources that must BOTH be consulted (see §2.1):
  - `schemeObligationsOf (schemeIds sch) addedObls` — the `pendingImplObligations`
    (unmarked / flat-check) path.
  - `inferredConstraintIds m (schemeIds sch)` paired with `ifaceForInferredId m id`
    — the `methodSiteFns`/`dictAppFns` (marked run/build/loader) path; this is the
    *same* source `registerInferredConstraints` uses for unsigned members
    (3360–3363).
- **Superclass closure** — `ifaceSupersOf superDeclsRef.value` (6460–6468) driven
  by the same fixpoint shape as `expandSupersPairs` (3563–3572)/`superSlotOf`
  (3588–3594), but **ungated** (the existing `expandSupersPairs` is gated to *user*
  interfaces at `superSlotsOf` 3578–3584 via `userIfaceNamesRef`; the check must
  include prelude supers like `Applicative requires Mappable`).

**Composition.** Purely additive — it only *reads* refs already populated at 8961
and pushes into the accumulating `typeErrors`. It does not change dict-passing,
generalization, or any existing propagation.

### 2.1 CRITICAL subtlety #1 — obligations land in different refs by path

Whether the body's method occurrence lands in `pendingImplObligations` or in
`pendingSites`/`methodSiteFns` depends on whether the **marker** ran:

- **Unmarked** (flat `checkProgramSeeded` / the `medaka check` single-file path):
  a method `EVar` goes through `recordImplObligation` (4207–4212) →
  `pendingImplObligations` → visible to `schemeObligationsOf`.
- **Marked** (loader / run / build; and *return-position* methods like `pure`
  even on the check path): the occurrence is rewritten to `EMethodAt`/`EMethodRef`
  and goes through `recordSiteHinted` (3329–3334) → `pendingSites` +
  `methodSiteFns` — **not** `pendingImplObligations`.

A complete fix MUST union both sources (prototype used `obsA ++ obsB`). A fix
reading only `schemeObligationsOf` would miss every return-position-method
constraint (e.g. a signed member using `pure`/`ap` without declaring the class).

### 2.2 CRITICAL subtlety #2 — superclass closure is mandatory

Closing the declared context over `requires` is **not optional polish** — without
it the check produces **10 false positives in the prelude alone** (see §3). E.g.
`map2 : Applicative f => … ; map2 f fa fb = ap (map f fa) fb` uses `map`
(Mappable) but declares only `Applicative`; since `Applicative f requires Mappable
f` (core.mdk:589) the signature is sound. Likewise `when`/`unless`/`forEach`/…
declare `Thenable`/`Alternative`, which transitively require `Applicative`
(core.mdk:638, 748). The declared set must be `requires`-closed before the subset
test.

### 2.3 CRITICAL subtlety #3 — `superDeclsRef` is not always populated

`superDeclsRef` (1540) holds the in-scope interface decls for super-expansion. It
is set on the `elaborateDict` (5150) and `elabModuleStamp` (10706) paths but
**not** on the flat `checkProgramSeeded` path — so the closure comes back empty
there (verified: `superDecls=0`). The fix must add
`setRef superDeclsRef prog` at the top of `checkProgramSeeded` (7747, after
`resetState`). This is a one-line prerequisite; harmless (the ref is read-only
during inference).

### 2.4 Diagnostic wording + location

Point at the **definition** (GHC-style), mirroring `effectEscapeMsg`. Suggested:
`Could not deduce 'Greet a' from the signature of 'sayHi' — its body requires it;
add 'Greet a =>' to the declared type`. The def-site is strictly better than the
call site: it localizes to the one binding whose signature is wrong, rather than
to every (possibly cross-module) use.

---

## 3. BLAST-RADIUS CENSUS — **0 newly-failing sites**

**Method: PROTOTYPED the full check** (superclass-closed, both obligation
sources), rebuilt `./medaka`, then ran `./medaka check` over every source module
**as the entry** (so each module's own signed members are inferred and censused),
plus the flat prelude path. Prototype then reverted (`git checkout`).

Validation that the census tool actually fires:
- Flat prelude path with the naive (no-superclass) check → **10 hits**; adding the
  `requires` closure → **0**. Confirms both the tool and that all 10 are sound.
- Repro `sayHi`/`useIt` → fires exactly on the offending bindings.
- A module-as-entry bad fixture (`export sayHi : a -> String; sayHi x = greet x`)
  → fires. Confirms the loader/`checkModuleFullImpl`→`processSCC` path exercises it.

**Result over the whole tree:**

```
CHECKED = 116 modules (compiler + stdlib + sqlite)
CENSUS_TOTAL = 0 newly-failing sites
MODULES_WITH_UNBOUND (import-load failures) = 0  → full coverage
```

Per-corpus:
- **Prelude (`stdlib/core.mdk`):** 0 genuine. 10 candidate functions
  (`map2`, `map3`, `when`, `unless`, `guard`, `foldThen`, `repeatThen`,
  `filterThen`, `forEach`, `runEach`) declare a constraint that *transitively
  requires* the inferred one — all sound under the superclass closure.
- **`stdlib/*` (list, string, array, map, set, io, json, …):** 0.
- **`compiler/*` (all 46 modules incl. `typecheck.mdk` itself):** 0.
- **`sqlite/*`:** 0.

**Interpretation.** With a *correct* (superclass-aware, both-source) check, the
existing corpus already satisfies constraint soundness — every constrained
function declares its constraints (relying on `requires` closure for the monadic
prelude helpers). The leniency is not being exploited anywhere in-tree. **This
makes the fix a small, safe landing, not a large arc.**

> Coverage caveat (honest): `medaka check <module-as-entry>` censuses that module's
> **own** signed members; a module's *imported* dependencies are seeded as schemes,
> not re-inferred. Because the sweep ran **every** module as an entry, every signed
> member in the tree was censused exactly once. A separate probe entry
> (`check_modules_main`) was tried first but is a **scheme-dump that does not render
> the diagnostics accumulator** — it silently swallows the census (and any
> `type_error`); do not use it to census. Use the real `medaka check` CLI.

---

## 4. Design forks (need a human decision)

1. **Reject vs warn.** *Recommend REJECT* (`pushTypeError`), matching
   `checkEffectEscape`. Census is 0, so rejection breaks nothing in-tree. A
   `--warn`-only phase-in is available but unnecessary given the 0 census.

2. **Def-site vs call-site diagnostic.** *Recommend DEF-SITE* (GHC-style). The
   data at 8961 is naturally def-keyed; call-site would need threading and would
   fire N times per missing constraint.

3. **Auto-suggest the missing constraint.** *Recommend YES, cheap.* We already
   have `(iface, var-id)` and can recover the var *name* from the sig tyvar map
   (`sigTvMaps`/`snd inst`); emit `help: add '\{iface} \{varName} =>'`. Low effort,
   high UX. Can ship in a follow-up if it complicates the first landing.

4. **Constraints only, or effects too?** Effects are **already** handled
   (`checkEffectEscape`). *Recommend SCOPE = constraints only* — this design is the
   missing constraint analogue; nothing else needed.

5. **Interaction with impl `requires`.** The closure must use the *full* interface
   `requires` graph (prelude + user), i.e. an **ungated** `ifaceSupersOf` walk, not
   the user-only `expandSupersPairs`. *Recommend a dedicated ungated closure helper*
   (the prototype's `censusSuperClose`) rather than relaxing the existing gated one,
   whose gating is load-bearing for dict arity (see the clamp-regression note at
   1543–1548). Impl-level `requires` (e.g. `impl Eq (List a) requires Eq a`) is
   orthogonal — it constrains instance *availability*, not a function's declared
   context, and needs no change here.

6. **Multi-param / structured constraints.** The prototype (like
   `schemeObligationOne`, 9344–9353) handles the single-param `C a` shape (the one
   the bug exercises) and skips multi-param/non-var-headed dispatch. *Recommend
   ship single-param first* (covers the bug and the whole prelude); multi-param
   constraint checking is a separable enhancement.

---

## 5. Seed / fixpoint note

`typecheck.mdk` is in the self-compile graph but is **not** the emitter, so **no
seed re-mint** is required. However:
- The **self-compile fixpoint** (`test/selfcompile_fixpoint.sh`) must pass, and
- **the compiler's own source must satisfy the new check** — which the census
  confirms it already does (0 compiler hits).

Because emitted IR is unaffected (this is a typecheck-time reject), the change is
fixpoint-safe: the gates that would move are the check/typecheck golden gates
(`diff_compiler_check*`, error-quality fixtures) — expect only additive new
rejections, none in-tree.

---

## Appendix — key line citations (`compiler/types/typecheck.mdk`)

| What | Lines |
|------|-------|
| `Scheme = Forall ids evars mono` (no context) | 716 |
| `processSCC` (the seam) | 8925–8967 |
| `preunifySigsEx` builds regs from sig only | 8986–8996 (esp. 8994) |
| `sigConstraints` | 9007–9009 |
| `registerConstraintRegs` → `registerMember` (declared → funConstraintsRef) | 9033–9060 |
| `maybeInferConstraint` SKIPS signed members | 9309–9313 |
| `registerSchemeObligations` (always-on inferred record) + comment | 9315–9330 |
| `schemeObligationsOf` / `schemeObligationOne` | 9335–9353 |
| `inferredConstraintIds` (marked-path inferred ctors) | 3360–3384 |
| `instantiateVarTracked` (single-hop consumption) | 4176–4193 |
| `recordImplObligation` (unmarked → pendingImplObligations) | 4207–4212 |
| `recordSiteHinted` (marked → pendingSites + methodSiteFns) | 3329–3334 |
| `checkCallObligations`/`checkOneCallObligation`/`noImplFoundMsg` | 7783, 8018–8028, 8211–8212 |
| `checkEffectEscape` (the precedent to mirror) | 9164–9172 (called 9099) |
| `checkSigsTooGeneral` (weaker precedent) | 9216–9241 (called 8935) |
| `ifaceSupersOf` | 6460–6468 |
| `expandSupersPairs`/`superSlotOf` (gated closure to copy, ungated) | 3563–3594 |
| `superDeclsRef` (+ set sites; NOT in flat check) | 1540; 5150, 10706 |
| interface `requires` (Applicative/Thenable/Alternative/Traversable) | core.mdk 589, 638, 748, 913 |
