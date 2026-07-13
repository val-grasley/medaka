# Generalizing constructor / record applications of values (value-restriction relaxation)

**Status:** IMPLEMENTED — `386a5433`, after 2026-06-30. `isNonexpansive`
(`compiler/types/typecheck.mdk:2439`) now has an `EApp` arm gated by `isCtorAppHead`
(`:2455`, excluding `Ref` by name) — a byte-for-byte match to this doc's own "LOCKED
SCOPE" §D1/D3. Header below ("design only, no code changed") predates the fix.

Original header (predates the fix): **Status:** design only (no code changed). Verified on a `medaka` built from
a discarded worktree, base `90865a6` (BASE_OK).
**Skill:** harden-typechecker (typechecker-internal generalization logic).

Medaka's let-generalization is gated by a *value / non-expansiveness* predicate
that is **stricter than the standard SML one**: it treats **every application**
as expansive, including a **constructor application of non-expansive arguments**
(`MkBox []`, `Some [...]`). Such a binding therefore fails to generalize and
monomorphizes to its first use. This is the same over-restriction that forced the
`data OrdMap = OEmpty | OMap …` nullary-constructor workaround. The standard,
sound SML fix is to also treat *constructor (and tuple/record) applications of
non-expansive arguments* as non-expansive — **excluding the one constructor that
builds a mutable cell, `Ref`** (exactly as SML special-cases `ref`).

---

## 1. Empirical current behavior (verbatim repro)

Binary: a `./medaka` built from a since-discarded agent worktree (path removed,
2026-07-13 doc pass — never a valid path for anyone else),
driver `medaka check <file>` (prints inferred top-level types on success, exit 0;
positioned diagnostics + exit 1 on failure). Probes in scratchpad.

| Case | Source (RHS) | Result today |
|------|--------------|--------------|
| Bare value | `e = []` used at `List Int` **and** `List String` | **GENERALIZES** — `e : List a`, exit 0 |
| Tuple of values | `p = ([], [])` used at `(List Int,List Int)` and `(List String,List Bool)` | **GENERALIZES** — `p : (List a, List b)`, exit 0 |
| **Ctor app (full)** | `data Box a = MkBox a` ; `e = MkBox []` at `Box (List Int)` then `Box (List String)` | **NOT generalized** — `Type mismatch: String vs Int` at 2nd use |
| **Ctor app (partial)** | `data Two a b = MkTwo a b` ; `g = MkTwo []` at two result types | **NOT generalized** — `Type mismatch: String vs Int` |
| **Ctor of lambda** | `b = MkBox (x => x)` at `Box (Int->Int)` / `Box (String->String)` | **NOT generalized** — `Type mismatch: String vs Int` |
| **Nested ctor** | `v = Some (MkBox [])` at two `Option (Box …)` | **NOT generalized** — `Type mismatch: String vs Int` |
| Record create | `Pair { l = [], r = [] }` | `p : Pair` — `ERecordCreate` falls to `_ => False`, expansive (not generalized) |
| **`Ref` app (soundness)** | `r = Ref []` at `Ref (List Int)` / `Ref (List String)` | **NOT generalized** — `Type mismatch: String vs Int` (correctly rejected) |

So: bare values, list literals, and tuples-of-values already generalize;
**all constructor applications (including `Ref`) and record creations do not.**

### How mutable cells are created — the soundness crux

`grep -nE '^extern [A-Z]' stdlib/runtime.mdk` returns exactly **one** line:

```
stdlib/runtime.mdk:15: extern Ref : a -> Ref a
stdlib/runtime.mdk:16: extern setRef : Ref a -> a -> <Mut> Unit
```

`Ref` is the **only uppercase-initial extern**, i.e. the only *constructor* that
yields a mutable cell. Every other mutable structure is built by a **lowercase
function application**, which stays expansive regardless of this change:

- Arrays: `arrayMake`, `arrayMakeWith`, `arrayFromList`, `arrayCopy` (runtime.mdk:124-136).
- `mut_array`, `hash_map`, `hash_set`: pure-Medaka over `Array` via lowercase functions.

Therefore the only way to *syntactically* produce a polymorphic mutable cell from
a constructor application is `Ref <value>`. If that generalized, it would be
unsound (write at one type, read at another). It is correctly rejected today, and
the proposed extension **must keep excluding `Ref`**.

---

## 2. The current predicate (file:line)

`compiler/types/typecheck.mdk`:

```
2267  isNonexpansive : Expr -> Bool
2268  isNonexpansive (ELoc _ e)        = isNonexpansive e
2269  isNonexpansive (EDoOrigin _ e)   = isNonexpansive e
2270  isNonexpansive (ELit _)          = True
2271  isNonexpansive (EVar _)          = True
2272  isNonexpansive (ELam _ _)        = True
2273  isNonexpansive (EAnnot e _)      = isNonexpansive e
2274  isNonexpansive (EHeadAnnot e _)  = isNonexpansive e
2275  isNonexpansive (ETuple es)       = allList isNonexpansive es
2276  isNonexpansive (EListLit es)     = allList isNonexpansive es
2277  isNonexpansive _                 = False        -- everything else, incl. ALL EApp
```

Generalizable forms today: literal, var, lambda, `ELoc`/`EDoOrigin`/`EAnnot`/
`EHeadAnnot` transparent, tuple-of-values, list-literal-of-values. **`EApp` (and
hence every constructor application) and `ERecordCreate` fall through to
`_ => False`.**

The companion `lowerToCurrent` / `genRestricted` (2284-2320) implement the "if not
a value, monomorphize and **lower free vars to `currentLevel`**" half — important
so a non-generalized binding's vars can't be re-captured by an enclosing `let`.
We do **not** touch these; they already behave correctly for both branches.

**Consultation sites** — `genRestricted (… isNonexpansive …)` is called at every
binding site (all pass through one predicate, so changing `isNonexpansive` covers
all of them):

- `3617` — `ELet`/do-let `PVar`: `genRestricted (not isMut && isNonexpansive e) t`
- `4401` — α-scope-seed `let` path
- `5004` — `processLetrecGroup` top-level non-letrec path (`isVal`)
- `5017` — `clauseIsValue (FunClause [] rhs) = isNonexpansive rhs`
- `9103` / `9107` — SCC scheme builder: `memberClauseIsValue ([], rhs) = isNonexpansive rhs`

Constructors are ordinary **`EVar`** heads (there is no `ECon` AST node;
`grep` confirms `EApp Expr Expr` at ast.mdk:124 and no `ECon`/`ECtor`).
`MkBox []` = `EApp (EVar "MkBox") (EListLit [])`; `MkTwo a b` =
`EApp (EApp (EVar "MkTwo") a) b`. Records are a distinct node
`ERecordCreate String (List FieldAssign)` (ast.mdk:171). The marker rewrites
*interface-method* `EVar`s to `EMethodRef`, but constructors are not methods, so
a ctor head stays `EVar` when `isNonexpansive` runs.

---

## 3. Proposed extension (diff-level)

Add two arms (and a small spine/record helper). All-of-args/all-of-fields must be
non-expansive; the spine head must be an **uppercase-initial `EVar` that is not
`Ref`**.

```
-- new arms in isNonexpansive, before the catch-all `_ => False`:
isNonexpansive (EApp f x)          = isCtorApp (EApp f x) && isNonexpansive x
isNonexpansive (ERecordCreate _ fs) = allList (fa => isNonexpansive (faExpr fa)) fs
```

where

```
-- head of an application spine is a data/record constructor (uppercase),
-- and not the mutable-cell constructor Ref.  Strips ELoc/EDoOrigin like
-- spineHeadIsApp (typecheck.mdk:656).  isUpper from compiler/support/char.mdk:51.
isCtorApp : Expr -> Bool
isCtorApp (ELoc _ e)      = isCtorApp e
isCtorApp (EDoOrigin _ e) = isCtorApp e
isCtorApp (EApp f _)      = isCtorApp f          -- walk left spine
isCtorApp (EVar name)     = name != "Ref" && headIsUpper name
isCtorApp _               = False

headIsUpper s = match (stringToChars s)   -- or charAt s 0; mirror existing idiom
  (c :: _) => isUpper c
  []       => False
```

Notes / decisions baked into the above:

- **Constructor application — fully OR partially applied:** both are
  non-expansive. A partial ctor app is a closure (a value); it builds no mutable
  cell. The recursion `isNonexpansive (EApp f x) = isCtorApp (EApp f x) &&
  isNonexpansive x` checks **each** spine argument is non-expansive (the inner
  `EApp` recursion re-enters `isNonexpansive` on `f` only via the *arg* of the
  next layer; to be safe, make the arg-check recurse over the whole spine — see
  the implementation note). This matches SML: "application of a constructor other
  than `ref` to a non-expansive expression."
- **`Ref` excluded by name** — the single mutable-cell constructor (§1). This is
  the SML `ref` special-case. Because `Ref []` then stays expansive, any *outer*
  ctor wrapping it (`Foo (Ref [])`) is also expansive (its arg is expansive), so
  the exclusion propagates correctly with no extra work.
- **Tuple / list literal of values** — already handled (2275-2276); no change.
- **Record creation (`ERecordCreate`)** — add as non-expansive iff all field
  exprs are. A record is an immutable product (a record name *is* its constructor,
  resolve.mdk); it builds no mutable cell. (Use the project's `FieldAssign`
  accessor for the field expr; grep `FieldAssign` for the exact shape.)
- **`if` / `match` / `let … in …`** — **DEFER** (keep expansive). They are not in
  the minimal SML "syntactic value" core, they add real surface area
  (`EBlock`/`EIf`/`EMatch`/`ELetGroup` arms, each with its own subtleties), and
  none of the motivating cases (the `OrdMap` workaround, `MkBox []`) need them.
  This is fork D1 below.

### Implementation note (head-uppercase vs env lookup)

Two ways to identify a constructor:

1. **Syntactic — uppercase-initial head `EVar`** (above). Needs no env threading;
   `isNonexpansive : Expr -> Bool` keeps its signature, so all six call sites are
   untouched. Sound because Medaka constructors are *always* uppercase-initial and
   functions/methods/values *always* lowercase (SYNTAX.md; confirmed: `MkBox`,
   `Some`, `Ref` upper; `map`, `e` lower). **Recommended** — minimal, local.
2. **Semantic — look the head name up in `TcEnv`'s ctor map** (`TcEnv` =
   `TcEnv (OrdMap Scheme) (OrdMap Scheme) …`, 2nd map is ctors, typecheck.mdk:2830).
   More precise but forces `isNonexpansive` to take an env and rewrites every call
   site. Not worth it; the uppercase rule is already exact for this grammar.

Pick (1). The only name that needs special handling — `Ref` — is excluded
explicitly; there are no other uppercase mutable-cell externs (§1).

---

## 4. Soundness argument + the crux

The value restriction exists to stop a polymorphic generalization from being
shared across a **mutable cell** instantiated at two incompatible types. In
Medaka:

- ADTs and records are **immutable**; a constructor application allocates an
  immutable, fully-applied (or partially-applied closure) value. Generalizing
  `MkBox []` to `∀a. Box (List a)` is sound for the same reason generalizing
  `[]` to `∀a. List a` is: there is no write-back path that could fix the
  element type at one use and read it at another.
- The **only** constructor that yields a mutable cell is `Ref`
  (`extern Ref : a -> Ref a`, runtime.mdk:15 — the lone uppercase extern). It is
  excluded by name, so `Ref e` stays expansive. Empirically `r = Ref []` is
  rejected today and **must remain rejected** — generalizing it would let
  `setRef` store an `Int` through `Ref (List Int)` and read it through
  `Ref (List String)`. The proposed predicate preserves this rejection.
- All other mutable structures (`Array`, `mut_array`, `hash_map`, `hash_set`)
  are produced by **lowercase function applications** (`arrayMake`, …), which the
  predicate never treats as non-expansive — they remain expansive exactly as
  today. Function applications in general stay expansive (the `_ => False`
  catch-all still covers `EApp` with a non-ctor head), so an `IO`/effectful or
  cell-allocating call still does not generalize.

Conclusion: treating constructor/tuple/record applications of non-expansive
arguments as non-expansive, **with `Ref` excluded**, is sound for Medaka's model.
No constructor other than `Ref` builds a mutable cell, so no further exclusions
are required. (If a future extern adds a second mutable-cell constructor, it must
be added to the exclusion set — a one-line follow-up, and the uppercase-extern
grep is the audit.)

---

## 5. OCaml relaxed value restriction (variance analysis) — RULE OUT

**Not needed; defer indefinitely.** OCaml's relaxed VR generalizes type variables
that appear only in *covariant* (output) positions even for expansive
expressions, via per-type-constructor variance annotations. That machinery buys
generalization for cases like `let r = ref [] in r` only in covariant slots and
requires a whole variance lattice over every type constructor. The SML extension
in §3 already covers **every motivating case** here (the `OrdMap` workaround,
`MkBox []`, records, tuples) because those are *syntactic values*, not expansive
expressions. Relaxed VR adds large machinery for cases Medaka does not currently
need and that the §3 change does not address (genuinely expansive RHSs). Defer it;
revisit only if a concrete need for generalizing an *expansive* covariant binding
appears.

---

## 6. Staged implementation plan

**Single bounded stage** (one predicate + one helper, no signature change):

1. Add `isCtorApp` + `headIsUpper` helpers near `isNonexpansive`
   (typecheck.mdk ~2267); import/confirm `isUpper` (support/char.mdk:51) is in
   scope, and the `FieldAssign` field-expr accessor for the record arm.
2. Add the `EApp` and `ERecordCreate` arms (§3). Leave `lowerToCurrent` /
   `genRestricted` untouched.
3. **Regression fixtures** (typecheck gate — `test/diff_compiler_check.sh` /
   `diff_compiler_check_modules.sh`, capture goldens per AGENTS "Writing tests"):
   - POSITIVE (must now pass): `MkBox []` at two types; `MkTwo []` (partial) at
     two types; `Some (MkBox [])` nested; `ERecordCreate` of empty lists at two
     types; `MkBox (x => x)` at two function types.
   - **NEGATIVE (must STILL be rejected — proves the VR still bites):**
     (a) `r = Ref []` used at `Ref (List Int)` and `Ref (List String)` →
     still `Type mismatch` (the soundness guard);
     (b) a **function-application** binding, e.g. `xs = arrayFromList []`
     (or any lowercase-head app / effectful call) used at two element types →
     still rejected (expansive function application).
4. **Gates:** new positives accept + both negatives still reject +
   `bash test/diff_compiler_check.sh` + `_check_modules` +
   `bash test/diff_compiler_eval.sh` + `_check_batch` (stdlib loads end-to-end,
   catches an over-broad rule) + `bash test/selfcompile_fixpoint.sh` (C3a/C3b).
5. **Seed re-mint:** `typecheck.mdk` is in the self-compile graph, so the emitted
   IR changes → **re-mint the seed + re-validate fixpoint at the checkpoint**
   (orchestrator handles this per the defer-seed-remint policy).

**Model:** mechanical, well-localized typechecker change with a crisp soundness
boundary and a clear negative test — **Sonnet-suitable**, with the Opus-authored
fixture set (especially the two negatives) handed over verbatim. The only subtle
spot is the spine recursion in the `EApp` arm (ensure *every* argument down the
spine is checked, not just the outermost) — call that out in the handoff.

---

## 7. Design forks needing a human decision

- **D1 — Scope of the extension.**
  (a) *Minimal SML core (recommended):* constructor application (excl. `Ref`),
  tuple, list-literal, record creation — all of non-expansive components.
  (b) *Full SML "syntactic value" set:* additionally `if`/`match`/`let-in` whose
  subexpressions are non-expansive. More surface area, no motivating case here.
  **Recommend (a).** Confirm whether you want `if`/`match`/`let` included now or
  deferred.
- **D2 — Relaxed VR (variance analysis): in or out?** Recommend **OUT / defer**
  (§5). Confirm.
- **D3 — `Ref` exclusion mechanism.** Exclude by name (`name != "Ref"`) given
  `Ref` is the sole uppercase mutable-cell extern (§1), vs a small named
  exclusion *set* for future-proofing. Recommend by-name now + a code comment +
  the uppercase-extern grep as the audit. Confirm.

---

### Appendix — exact repro commands

```
M=./medaka   # a built medaka binary, e.g. from `make medaka`
# c2 (ctor app, NOT generalized):
printf 'data Box a = MkBox a\ne = MkBox []\nuseInt : Box (List Int)\nuseInt = e\nuseStr : Box (List String)\nuseStr = e\nmain = println "ok"\n' > c2.mdk
"$M" check c2.mdk          # -> Type mismatch: String vs Int   (exit 1)
# c3 (tuple, generalizes):
printf 'p = ([], [])\nuseInt : (List Int, List Int)\nuseInt = p\nuseStr : (List String, List Bool)\nuseStr = p\nmain = println "ok"\n' > c3.mdk
"$M" check c3.mdk          # -> p : (List a, List b)           (exit 0)
# p_ref (soundness, must stay rejected):
printf 'r = Ref []\nuseInt : Ref (List Int)\nuseInt = r\nuseStr : Ref (List String)\nuseStr = r\nmain = println "ok"\n' > pref.mdk
"$M" check pref.mdk        # -> Type mismatch: String vs Int   (exit 1)
```

---

## LOCKED SCOPE (orchestrator decision, 2026-06-30)

Accepting the design's recommendations on all three forks:
- **D1 → minimal SML core.** Extend `isNonexpansive` with `EApp` (uppercase-`EVar`-head ctor application, excluding `Ref`, all spine args non-expansive) and `ERecordCreate` (all fields non-expansive). DEFER `if`/`match`/`let` — can extend later if a real case appears.
- **D2 → relaxed value restriction (variance) OUT.** The SML extension covers every motivating case (all syntactic values); variance machinery is unnecessary.
- **D3 → exclude `Ref` by name**, with the `grep '^extern [A-Z]' stdlib/runtime.mdk` audit (today returns exactly `Ref`) recorded here as the justification. **Robustness ask:** the implementation must carry a prominent comment at the exclusion site stating WHY `Ref` is special and that any future uppercase mutable-cell extern MUST be added to the exclusion — so this can't silently become unsound.

**Execution:** single bounded stage (predicate + uppercase-head helper) — Sonnet, with the fixture set below mandatory. **Gate:** the new positives generalize (`MkBox []`, partial ctor app, nested, record-of-values), AND the negatives STILL reject (`Ref []` must stay monomorphic/rejected; a function-application binding like `arrayFromList []` must stay expansive — proving the value restriction still bites where it must); plus `diff_compiler_check`/`_check_modules`/`_eval`/`_check_modules_batch` + `selfcompile_fixpoint` C3a/C3b. `typecheck.mdk` is in the self-compile graph → orchestrator re-mints the seed at the checkpoint.
