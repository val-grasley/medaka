# Tuple as a real type constructor — design doc

**Status: SHIPPED (2026-07-02).** Stage 1 (`a642a43`, zero observable change —
tuples internally became `__tupleN__`-headed `TApp` spines, type-layer-contained,
NO seed re-mint needed for this stage alone) then Stage 2 (`c00ee2b`, Parts A+B —
`(,)`/`(,,)`/`(,,,)`/`(,,,,)` surface syntax for arities 2–5 names the bare
unsaturated tuple constructor in type position; `export impl Bimappable (,)`
lands in `core.mdk`). Verified `check`/`run`/`build` single-file AND across a
module boundary (constrained fn dispatching on a tuple from a sibling module).
Representation matches the design below exactly (Fork A.1 taken — the
kind-correct unsaturated `(,)` surface, not the saturated `impl Bimappable (a, b)`
shape §6/§8 explicitly recommends against). Seed re-minted `9671acd` (the prior
seed couldn't parse the new `(,)` syntax used by `core.mdk`'s own prelude).
**Suspected residual — VERIFIED CLOSED (2026-07-02):** a cross-module
sibling-impl-emit gap flagged mid-workstream (a typeclass impl in a non-prelude
sibling module allegedly not emitting its `define` at build) does **not**
reproduce on current main — checked across 6 repro shapes including the three
exact fixtures below (all build correctly and match their eval goldens). Almost
certainly closed by the Bug-1 arity-carrying-closure emitter fix (`0f4f4c1`,
runtime `mdk_apply`), which reworked opaque dispatch/application emission and
landed on the same branch base. Now **build-guarded**: the fixtures were promoted
to `test/build_diff_fixtures/{bimappable_constrained_sibling,bimappable_tuple_sibling,traverse_parametric_sibling}/`
and wired into `diff_compiler_build` (49/0).

---

**Original design pass below (historical — decisions taken are noted inline above).**

**Status:** decision-ready design pass. No code changed.
**Decision already made (not relitigated):** make the n-tuple a real type
constructor so a higher-kinded type-class param (kind `*→*→*`) can bind to it.
This closes a general language hole — **HKT-over-tuple** — not just `bimap`.

**Author's one-line verdict:** the internal-representation change is
**type-layer-contained** (nothing outside `compiler/types/typecheck.mdk`
pattern-matches the type-level tuple), *but* the representation change **alone
does not make `impl Bimappable (a, b)` compile** — that exact surface is
kind-inconsistent with the rest of the language, and a small **second** change
(an impl-authoring surface for the bare tuple constructor) is required for the
stated payoff. The two changes stage cleanly and independently.

---

## 0. What was empirically verified (on the built `./medaka`)

All probes run against a fresh `make medaka` build.

- **The call-site failure reproduces exactly** as the task describes. With
  `impl Bimappable (a, b)` in scope, `bimap (n=>n+1) (s=>s) (3, "x")` yields
  `Type mismatch: a b c vs (a, String)` at the tuple argument. Root cause:
  `unifyN` has a `TApp~TApp` arm and a `TTuple~TTuple` arm but **no
  `TApp~TTuple` arm** (`typecheck.mdk:2261-2272`), so the interface method's
  spine `p a b` (a `TApp(TApp p a) b`) cannot meet the tuple mono `TTuple[…]`.

- **The kind story is the crux, and it is confirmed by an ADT analogue.**
  `impl Mappable (Box a)` (a *saturated*, kind-`*` head) fails identically to
  `impl Bimappable (a, b)`; the kind-correct `impl Mappable Box` (unsaturated,
  kind-`*→*` head) compiles and runs. So writing a *saturated* tuple `(a, b)`
  as the head of a higher-kinded class is the same kind error the language
  already rejects for ADTs — see §8/§7.

- **`Tuple2` / `(,)` are not surface types today.** `f : Tuple2 a b -> a`
  gives `Unknown type: Tuple2`. There is no way to name the bare tuple
  constructor in surface syntax. This is the missing piece for the impl surface.

- **All five kind-`*` tuple impls dispatch through the `__tupleN__` tag and
  must keep working:** `Eq/Ord/Debug/Display/Hashable (a, b)` at
  `stdlib/core.mdk:91/214/338/406/471`. Baseline `(1,"x") == (1,"x")` → `True`
  today; this is the primary no-regression witness.

---

## 1. Representation decision

### 1.1 Recommendation — DELETE `Mono.TTuple`; pure `TApp` spine

Delete the `TTuple (List Mono)` constructor of `Mono`
(`typecheck.mdk:85`) entirely. Represent an n-tuple internally as a **saturated
`TApp` spine over a synthetic nullary `TCon`**, one distinct constructor per
arity:

```
(a, b)      ==>  TApp (TApp (TCon "__tuple2__") a) b
(a, b, c)   ==>  TApp (TApp (TApp (TCon "__tuple3__") a) b) c
```

Do **not** keep `TTuple` as a "normalized-away alias." A dual representation
would force a canonicalizer at every match site and re-introduce exactly the
special-casing this change exists to delete. The maintainer's instinct to
*collapse* (delete special cases, not add a normalizer) is correct and is what
makes the blast radius small.

### 1.2 The synthetic `TCon` name **is** the existing dispatch tag

Name the constructor with the *exact* string the dispatch machinery already
uses: `tupleCtorName n = "__tuple\{n}__"` (`exhaust.mdk:60-61`), which is
byte-identical to `tupleHeadTagTc` (`typecheck.mdk:7836`) and eval's
`tupleHeadTag` (`eval.mdk:359`). Consequence — **zero tag-parity risk**:

- `headTyconMono`'s generic `TCon n => Some n` arm (`typecheck.mdk:7828`) now
  returns `"__tuple2__"` for a tuple spine *with no tuple special-case at all*.
  The dedicated `TTuple ts => Some (tupleHeadTagTc …)` arm (7829) is **deleted**
  and its job is done by the generic arm, producing the identical string.
- Every downstream dispatch consumer (`matchCol0Type`, RKey routing, eval) keeps
  seeing `"__tupleN__"` unchanged.

The one cost: `"__tuple2__"` is ugly if it leaks into an error message, so
`ppGo` must special-case it back to `(a, b)` — see §1.4. (A cleaner human name
like `"Tuple2"` is possible but then `headTyconMono` needs an explicit
`Tuple<n> → __tupleN__` translation to preserve dispatch parity; the tag-named
form avoids that. This is a minor fork — §7 Fork D.)

### 1.3 Arity/kind story

- One nullary `TCon` per arity: `__tuple2__ : *→*→*`, `__tuple3__ :
  *→*→*→*`, etc. This typechecker enforces kinds only *structurally* (by
  application depth in `TApp` spines) — there is no separate kind table — so
  "kind" is implicit and no kind declaration is needed.
- **Tuple0 / Tuple1:** surface has no 1-tuple; `()` (unit) is currently
  `TyTuple []` → would become `TCon "__tuple0__"`. Verify unit still prints
  `()` and unifies (it is heavily used). This is a real edge — §7 Fork B.

### 1.4 Concrete before/after for the load-bearing functions

Add one smart constructor and route both tuple-*construction* sites through it:

```
tupleMono : List Mono -> Mono                      -- NEW
tupleMono ts = foldl TApp (TCon (tupleCtorName (listLen ts))) ts
```

**`fromAstTypeE` (surface → Mono), `typecheck.mdk:2828`**
```
- fromAstTypeE etbl tvs (TyTuple ts) = TTuple (map (fromAstTypeE etbl tvs) ts)
+ fromAstTypeE etbl tvs (TyTuple ts) = tupleMono (map (fromAstTypeE etbl tvs) ts)
```

**`ppGo` (Mono → string), `typecheck.mdk:2529`** — the `TTuple` arm is deleted;
the `TApp` arm (`ppApp`) must recognise a tuple-tagged spine head and render
`(e1, e2, …)` instead of `head e1 e2`. Concretely, `ppApp` (2527) gains a
guard: if the fully-collected spine head is a `TCon` whose name is a tuple tag,
render the collected args comma-joined in parens; otherwise the existing
application rendering. (Collecting the spine + head is already the shape `ppApp`
walks.)

**`matchTyMono` (surface `Ty` head-pattern vs Mono), `typecheck.mdk:7036-7037`**
— this is a **surface↔Mono bridge**, so it does *not* auto-collapse. The mono
is now a spine, so the `TTuple ms` branch must become a spine match:
```
- matchTyMono (TyTuple ts) m = match normalize m
-   TTuple ms => if listLen ts == listLen ms then matchTyMonoList ts ms else None
-   _ => None
+ matchTyMono (TyTuple ts) m =                 -- match the Tuple<n> spine
+   -- collect spine head+args of `m`; require head == tupleCtorName (len ts)
+   -- and same arity, then matchTyMonoList ts args
```

**`walkDispatch` (surface `Ty` vs Mono), `typecheck.mdk:8377-8378`** — same
bridge issue, same fix: the `TyTuple ts` arm must collect the mono spine's
args rather than expect a `TTuple ms` node. **This one is a silent-failure
trap:** if left unchanged it falls through to `_ => []`, quietly losing
dispatch-var recovery for tuples (no error, wrong dispatch). Must be updated.

**Two `TTuple` *construction* sites** route through `tupleMono`:
`inferPatTuple` (`typecheck.mdk:3090`) and the `ETuple` case of `infer`
(`typecheck.mdk:3144`).

**Pure-`Mono` walks — the collapse (delete the `TTuple` arm, no replacement).**
Each of these already has a `TApp a b` arm that recurses into both children, so
a tuple spine flows through it unchanged:
`freeEffvars` (1278), `occursAdjust` (2230), `lowerToCurrent` (2410),
`freeGenVars` (2437), `substMono` (2468), `substMonoP` (2494),
`monoUnboundIds` (4978), `monoUnboundVarLevels` (5124), `findTvarN` (7431),
`monoTyvarIds` (8664), `monoSpineHeadIsCon` (10110 — the `TCon _ => True` arm
already covers the head).

**`unifyN` (2268-2270):** delete the `TTuple~TTuple` arm; the generic
`TApp~TApp` arm (2261) now unifies tuple~tuple *and* the new tuple~`p a b`
case. Note the arity-mismatch error path changes: `(a,b)` vs `(a,b,c)` used to
hit the guarded `typeMismatch (TTuple …) (TTuple …)`; now it bottoms out as a
`TCon "__tuple2__"` vs `TApp …` mismatch. Because `ppGo` renders both spines as
tuples (§1.4), the *message* stays readable, but a targeted probe should
confirm the wording is acceptable.

**Coherence `cohGoR`/`cohSubR`/`cohEqR` (6275/6314/6329):** each has both a
`TApp` and a `TTuple` arm. Deleting the `TTuple` arm routes tuples through the
`TApp` arm. **Verify `cohSubR` specifically** — its `TApp` arm recurses on the
head only (`cohSub subst f1 f2`, drops the arg for variance reasons) whereas the
`TTuple` arm recurses element-wise. For concrete tuple heads this is expected to
be equivalent, but it is the one place the collapse changes *what gets checked*,
so it needs an explicit coherence probe (two overlapping tuple impls).

---

## 2. THE CRITICAL UNKNOWN — value-layer / emit / exhaust blast radius

**Verdict: the change is type-layer-contained. No file outside
`compiler/types/typecheck.mdk` pattern-matches the type-level tuple
(`Mono.TTuple`), and surface `Ty.TyTuple` is unchanged.** Everything below the
type layer keys off `VTuple` / `PTuple` / `CTuple` / `HTuple` / tuple *arity* —
none of which move. Per-file findings (grep + read of every candidate):

| File | Tuple references | Touches the **type** rep? | Impact |
|------|------------------|---------------------------|--------|
| `frontend/exhaust.mdk` | `PTuple` (204/333/390/405), `ETuple` (461), `tupleCtorName` (60) | No — pattern/value only | **None.** `tupleCtorName` string is *reused* as the TCon name (§1.2), not changed. |
| `eval/eval.mdk` | `VTuple` (value), `PTuple` (pattern), `tupleHeadTag` (359); `TyTuple` at 307/339/367/391 are over **surface `Ty`** | No `Mono.TTuple` | **None.** eval has no `Mono` at all; surface `Ty` unchanged. Tag `__tupleN__` unchanged. |
| `backend/llvm_emit.mdk` | `PTuple`/`CTuple`/`HTuple`/`$tuple`, `emitTuple` | No | **None** — see §4 (matters for merge sequencing). |
| `backend/wasm_emit.mdk` | `CTuple`/`PTuple`/`HTuple`, per-arity `Tup<n>`/`$Tuple<n>` synth | No | **None.** |
| `ir/core_ir*.mdk`, `ir/dce.mdk` | `CTuple`/`HTuple`; `TyTuple` at `core_ir_lower.mdk:870/976` is over **surface `Ty`** | No `Mono` | **None.** |
| `types/annotate.mdk` | `PTuple`/`ETuple` | No | **None.** |
| `frontend/{resolve,marker,desugar,ast}.mdk` | `TyTuple` (surface def + `resolve.mdk:207` walk), `PTuple`/`ETuple` | Surface only | **None** — surface `Ty.TyTuple` is explicitly kept. |
| `tools/{printer,fmt,lsp}.mdk` | none / value-only | No | **None.** |
| `tools/check_policy.mdk` | imports `Mono(..)`; `monoEffects` (304-310) matches `TFun`/`TApp`, **catch-all `_ => []`** | Indirectly | **Compiles fine, but a silent semantic change:** today a `TTuple` hits `_ => []` (element effects ignored); as a `TApp` spine it recurses the `TApp` arm and *collects* element effects. Arguably a fix, but it is a deliberate decision — §7 Fork C. |

**This is the single most important finding of the pass:** the change lives
entirely inside the typechecker's `Mono` algebra. The only cross-file
touchpoint is `check_policy.mdk`'s effect-policy walk (behavioral, not a build
break), plus the *reuse* (not modification) of `exhaust.tupleCtorName` as the
TCon name.

---

## 3. Dispatch / tag continuity

Confirmed the `__tupleN__` path survives byte-for-byte:

- Three producers emit the identical string and must stay in agreement:
  `tupleHeadTagTc` (`typecheck.mdk:7836`), eval `tupleHeadTag`
  (`eval.mdk:359`), exhaust `tupleCtorName` (`exhaust.mdk:61`). Naming the new
  `TCon` `"__tuple\{n}__"` (§1.2) makes `headTyconMono`'s generic `TCon n =>
  Some n` arm reproduce it with no bespoke code — **the strongest reason to use
  the tag as the TCon name.**
- RKey routing in `llvm_emit.mdk` (~3413, `emitMethod`) keys off the stamped
  route tag string; typecheck stamps it via `headTyconMono`. Same string in →
  same route out. No emitter change needed.
- The five kind-`*` tuple impls (`core.mdk:91/214/338/406/471`) dispatch by this
  tag today and are the primary regression witnesses (§6).
- **Byte-parity requirement:** typecheck's tag string and eval's tag string
  must remain equal. Using `tupleCtorName`/`tupleHeadTag`/`tupleHeadTagTc`
  (already equal) preserves it; keep them equal if any is touched.

---

## 4. Interaction with the in-flight emitter (PAP-in-container) work

**This change is expected to touch `llvm_emit.mdk` NOT AT ALL** (§2: the
emitter reads only `CTuple`/`PTuple`/`HTuple`, never `Mono`). Therefore it does
**not** conflict with the concurrent PAP-in-container emit fix in
`llvm_emit.mdk`. The two can land in either order; they share no file. The only
shared *artifact* is the checked-in seed (both changes alter self-compiled IR
and each owes a re-mint) — coordinate the **seed re-mint** as the last step of
whichever lands second, or batch a single re-mint after both (§5).

---

## 5. Staged implementation plan (ascending risk)

All type-representation work is in **one file** (`typecheck.mdk`), so Stages 1
and 1b are inherently **sequential** (same file). Stage 2 additionally touches
`resolve.mdk` (+ possibly `parser.mdk`).

**Stage 1 — introduce the spine, collapse the pure-`Mono` walks.**
Add `tupleMono`; delete `Mono.TTuple`; update `fromAstTypeE`, `ppGo`, the two
constructors (`inferPatTuple`, `infer/ETuple`), the two surface↔Mono bridges
(`matchTyMono`, `walkDispatch`); delete every pure-`Mono` `TTuple` arm; delete
`unifyN`'s and the coherence functions' `TTuple` arms.
*Gate:* `selfcompile_fixpoint.sh` + `diff_compiler_check.sh` +
`diff_compiler_eval*.sh` + desugar/mark goldens (should be untouched — tuples
are surface `Ty`, unchanged) + **targeted probes:** all five core tuple impls
(`(1,"x")==(1,"x")` → `True`, tuple `Display`, tuple `Ord`, tuple `Hashable`
into a `HashSet`), tuple exhaustiveness fixtures, nested-tuple patterns, unit
`()` prints/unifies, and the `cohSubR` two-overlapping-impl coherence probe.
*Risk:* **medium** — touches `unify`/`ppGo`/coherence/dispatch — but
blast-radius-contained to typecheck. No new behavior yet; this stage is a pure
representation refactor whose success criterion is **zero observable change**.

**Stage 1b (optional, same file) — verify HKT-over-tuple at call sites/sigs.**
No new code beyond Stage 1: with the spine in place, `p a b` unifies with a
tuple argument, so a *signature-level* use (`f : Bimappable p => p a b -> …`
applied to a tuple, or an explicit `bimap` call) now typechecks even before any
impl exists. *Gate:* a probe that a polymorphic `bimap`-typed function accepts a
tuple argument without `Type mismatch`. *Risk:* low (assertion, not code).

**Stage 2 — impl-authoring surface for the bare tuple constructor.**
Pick a surface for the unsaturated constructor (§7 Fork A) — recommended `(,)`
/ `(,,)` (Haskell-style) or a named `Tuple2`/`TupleN` — and register it as a
known type constructor: `resolve.mdk`'s type-name resolution (and
`fromAstTypeApp`/the etbl) must accept it and elaborate it to `TCon
"__tupleN__"`; `parser.mdk` needs a token for `(,)` if that surface is chosen
(a named form needs no parser change). Then `impl Bimappable (,)` elaborates its
head to `TCon "__tuple2__"`, binds `p ↦ __tuple2__`, and `p a b` saturates to a
tuple — **all downstream machinery from Stage 1 applies unchanged.**
*Gate:* `impl Bimappable (,)` typechecks + `run` + `build` end-to-end; add a
golden fixture; confirm no existing kind-`*` tuple impl regresses. *Risk:*
**higher** — new surface syntax + resolver + possibly parser; distinct file set
from Stage 1 so it can be reviewed independently.

**Seed re-mint:** the compiler self-compiles, so *any* `typecheck.mdk` source
change alters the self-compiled emitter IR → the checked-in
`compiler/seed/emitter.ll.gz` is owed a re-mint for cold-bootstrap
reproducibility. **Batch a single re-mint after the final stage lands** (and
coordinate with the concurrent emitter work — §4). Verify with
`selfcompile_fixpoint.sh` after re-mint.

---

## 6. Regression surface + gates

- **Tuple-sensitive suites:** `diff_compiler_check.sh` (scheme/pp output),
  `diff_compiler_eval*.sh` (`eval_modules` + single-file), tuple pattern and
  **exhaustiveness** fixtures (`exhaust.mdk`'s `tupleCtorName` path), any golden
  that prints a tuple *type* (ppGo). Desugar/mark/lextok/sexp goldens should be
  **unchanged** (tuples are surface `Ty`/value nodes, which don't move) — if any
  moves, that's a red flag the change leaked below the type layer.
- **Behavioral witnesses (the five core impls):** `Eq/Ord/Debug/Display/
  Hashable` on `(a,b)` — baseline `(1,"x")==(1,"x")` → `True` must hold; add a
  tuple-`Display`, tuple-`Ord`-sort, and tuple-into-`HashSet` probe.
- **Proof of no regression:** Stage 1 is a representation refactor whose
  contract is *identical observable behavior* — the fixpoint holding plus the
  differential suites plus the five-impl witnesses green **is** the proof.
- **Proof of payoff (Stage 2):** a new fixture — an `impl Bimappable <tuple
  ctor>` that `run`s and `build`s and produces the mapped tuple (§8).

---

## 7. DESIGN FORKS (need a human decision)

- **Fork A — the impl-authoring surface (the load-bearing decision).**
  `impl Bimappable (a, b)` as literally written is **kind-inconsistent** (§8):
  it is the saturated `(a,b)` (kind `*`) used where a kind-`*→*→*` head is
  required, exactly the shape the language already rejects for
  `impl Mappable (Box a)`. Options:
  1. **Bare-constructor surface (recommended, principled, consistent).** Add
     `(,)` / `(,,)` (or named `Tuple2`/`TupleN`) as a surface type constructor;
     write `impl Bimappable (,)`. This is the exact analogue of `impl Mappable
     Box` and needs *no* kind inference — the Stage-1 representation makes it
     Just Work. Cost: a little surface syntax + resolver registration.
  2. **Kind-directed decomposition of a saturated tuple head.** Special-case
     `impl Bimappable (a, b)`: when the interface param is higher-kinded and the
     head is a saturated tuple, bind `p ↦ TCon "__tupleN__"` and treat the
     surface element vars as saturating placeholders. More ergonomic surface,
     but adds kind logic to impl-head elaboration and is *inconsistent* with how
     ADTs are handled (you cannot write `impl Mappable (Box a)`).
  The author recommends **A.1**. If the maintainer insists on the `(a, b)`
  spelling, A.2 is a scoped Stage-2 follow-up, not part of the representation
  change.

- **Fork B — Tuple0/`()` (unit).** Unit is `TyTuple []` today → becomes
  `TCon "__tuple0__"`. Decide whether to route unit through the tuple spine at
  all or keep a dedicated unit representation. Must verify unit still prints
  `()` and unifies everywhere (it is pervasive). No 1-tuple exists, so Tuple1 is
  a non-issue.

- **Fork C — `check_policy.monoEffects` (§2).** Element effects of a tuple are
  currently dropped (catch-all `_ => []`); after the change they'd be collected
  via the `TApp` arm. Accept the (arguably more-correct) new behavior, or add an
  explicit tuple-ignoring arm to preserve today's policy exactly.

- **Fork D — TCon name string.** `"__tuple2__"` (== dispatch tag, zero-parity
  code, ugly in raw dumps) vs `"Tuple2"` (clean, but needs an explicit
  `headTyconMono` translation to keep the dispatch tag). Author recommends the
  tag-named form for zero-parity-risk.

- **Fork E — n>2 scope.** Whether Stage 2 lands HKT support for `Tuple3+`
  immediately (the representation already generalizes; only the surface-ctor
  registration and a `Bimappable`-style class instance differ) or defers beyond
  the 2-tuple.

---

## 8. Payoff check

**Does the change enable `impl Bimappable (a, b)` end-to-end?**

- **The general hole it closes — yes.** The Stage-1 representation makes the
  interface method spine `p a b` unify with a tuple at **call sites and in
  signatures** (§1b), which is the actual language hole (HKT-over-tuple) and
  fixes the reproduced `Type mismatch: a b c vs (a, String)`.
- **The exact surface `impl Bimappable (a, b)` — no, and it shouldn't.**
  Empirically (§0) that saturated head is the same kind error the language
  already rejects for `impl Mappable (Box a)`; the kind-correct form is the
  *unsaturated* constructor, which surface cannot yet name. So the honest answer
  is: the representation change is **necessary but not sufficient** for
  authoring the impl; it must be paired with **Fork A** (a bare-tuple-constructor
  surface, recommended `impl Bimappable (,)`).
- **Proof test (Stage 2 fixture):**
  ```
  impl Bimappable (,) where          -- or the chosen surface
    bimap f g (x, y) = (f x, g y)
  main = println (bimap (n => n + 1) (s => s ++ "!") (3, "x"))   -- (4, "x!")
  ```
  must `check`, `run` → `(4, x!)`, and `build` → same. Gate this via a new
  golden plus the `run==build` comparison.

**Bottom line for the maintainer:** ship Stage 1 (contained, zero-behavior-
change representation refactor — the real generality win), then decide Fork A
to unlock impl authoring. Neither stage touches `llvm_emit.mdk`, so both are
merge-safe against the concurrent PAP-in-container fix.
