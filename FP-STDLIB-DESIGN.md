# FP Standard Library — Typeclasses, Combinators & Error Handling

Status: **design proposal** (2026-07-01). Read-only planning doc. Companion to
`P1-STDLIB-DESIGN.md`, which scoped the *batteries* (math / fs / net / codecs /
time). That doc deliberately under-covered the **functional-programming surface**:
the typeclass hierarchy, FP combinators, monadic/applicative helpers, principled
error handling (accumulating `Validation`), and monoid machinery. This doc
surveys what Haskell / F# / OCaml programmers (and, as hierarchy references,
PureScript and Scala cats) reach for that **Medaka lacks**, and tiers the
additions P1 / P2 / P3.

Every recommendation was written against the *actual* current surface — I read
`stdlib/core.mdk` and `stdlib/list.mdk` end to end (§1). Names follow Medaka's
existing renames (`Mappable`, `Thenable`, `Option`, `Result`), with the
Haskell/F#/OCaml equivalent in parentheses.

---

## 0. Medaka type-system facts this doc relies on (verified in-tree)

These shape what is *expressible*, so I checked each before recommending anything:

- **HKT works.** `Mappable f`, `Applicative f`, `Thenable m`, `Foldable t`,
  `Traversable t` are all higher-kinded (`core.mdk:561`, `581`, `610`, `701`,
  `793`). So type-constructor classes (Bifunctor, Comonad, Contravariant,
  Profunctor) are **expressible** in principle.
- **Superclass constraints via `requires`** work, including multiple:
  `Ord a requires Eq a`, `Monoid a requires Semigroup a`,
  `Traversable t requires Mappable t, Foldable t`, and multi-constraint impls
  (`impl Eq (Result e a) requires Eq e, Eq a`).
- **Multi-parameter type classes work.** `interface FromEntries c e`
  (`core.mdk:731`) is a live 2-parameter class. So a class over two type
  parameters is not a blocker (relevant for `Bifunctor`, which is single-param
  over a 2-ary constructor — even easier).
- **`do`-notation desugars to `andThen`/`pure` over `Thenable`, for ANY user
  monad.** Verified: `stdlib/byteparser.mdk` defines
  `impl Thenable ByteParser` (line 84) and uses `do` blocks freely
  (`some p = do …`, line 187). So all `do`-based monadic helpers (`foldM`,
  `replicateM`, `traverse_`, `guard`, …) will work over user `Thenable`s, not
  just built-ins. This is the single most important enabler in this doc.
- **`Foldable` already exposes `foldMap`** (`core.mdk:704`) with a default
  `foldMap f = fold (acc x => acc ++ f x) empty`. So the *monoid-driven fold*
  pattern is half-built — it only lacks the monoid **newtype wrappers** (`Sum`,
  `Any`, …) to specialize it (`getSum (foldMap Sum xs)`).
- **Value restriction is relaxed + type aliases expand** (recent work, per
  MEMORY). `isNonexpansive` now generalizes constructor applications and records
  of values, so `data Sum = Sum Int` / `data Identity a = Identity a` wrappers
  and a *polymorphic* `noMatch`-style nullary constant generalize correctly.
  This is what makes the monoid-newtype and `Identity`/`Const` designs cheap.
- **Effects vs monads are distinct.** A bare block is a *capability effect*
  (`<IO>` etc.); `do` is *value-level monadic sequencing*. `Async` is already a
  value-level monad with **no** `<Async>` effect (MEMORY, `stdlib/async.mdk`).
  So `Reader`/`Writer`/`State` below are **value-level monads**, not effects —
  they sit alongside `Async`, not alongside `<IO>`.
- **No catchable panics; `Result` is the sole error channel** (MEMORY:
  "no recover/try/catch"). This is *the* argument for accumulating `Validation`
  (§5): with no exceptions, the only way to report *several* errors at once is a
  data type that accumulates them.

Cost legend (per item, mirroring `P1-STDLIB-DESIGN.md`):
- **[pure]** — writeable in `stdlib/*.mdk` over what exists today. No externs, no
  re-mint (new modules are import-by-bare-name unless pulled into `core`).
- **[pure+core]** — pure, but recommended for `core.mdk` (auto-prelude) →
  perturbs the compiler build → **needs a seed re-mint + `selfcompile_fixpoint`**.
- **[needs-feature]** — needs a language capability Medaka lacks today; named
  inline.
- **[interacts-with-effects]** — touches the effect-row story.

---

## 0.5 Locked naming decisions (2026-07-01) — anti-gatekeep pass

Reviewed the P1 set against Medaka's approachability goal (the `Mappable`/
`Thenable` renaming philosophy: *name a thing for what you do with it, not for
category theory*). The doc below tiered by value but imported Haskell's
**vocabulary** wholesale; these decisions replace the jargon names. **Names below
are canonical — supersede any conflicting sketch later in this doc.**

**House convention:** effect-sequencing helpers take a **`-Then` suffix** (echoes
`Thenable`/`andThen`; a convention Medaka owns — no other language uses it).

| Doc / Haskell name | Locked Medaka name | Rationale |
|---|---|---|
| `liftA2` / `liftA3` | **`map2` / `map3`** | Elm-style; "map over N containers"; ties to `Mappable` |
| `foldM` | **`foldThen`** | `-Then` convention |
| `replicateM` | **`repeatThen`** | `-Then` convention |
| `filterM` | **`filterThen`** | `-Then` convention |
| `zipWithM` (P2) | **`zipWithThen`** | `-Then` convention |
| `for_` | **`forEach`** | run action per element, discard results |
| `traverse_` | *(dropped)* | `forEach` is its flip |
| `sequence_` | **`runEach`** | run a list of ready actions, discard results |
| `void` | **`discard`** | says what it does |
| `$>` / `<$` | **`replaceWith : f a -> b -> f b`** | no symbolic operators |
| `<&>` | *(dropped)* | `xs \|> map f` already covers flipped map |
| `Bifunctor` (class) | **`Bimappable`** (class) | methods `bimap` / `mapFirst` / `mapSecond` |
| `maybe` (eliminator) | **`option`** | matches the `Option` type |
| `either` (eliminator) | **`result`** | matches the `Result` type |
| `lefts` / `rights` | **`oks` / `errs`** | matches `Ok` / `Err` |
| `catOptions` | **`somes`** | collects the `Some`s |
| `guard` | **`guard`** (kept) | common enough word |
| `on` | **`on`** (kept) | load-bearing; documented |
| `curry` / `uncurry` | **`curry` / `uncurry`** (kept) | earn place (tuples aren't auto-curried) |

**Scope change:** monoid newtypes (`Sum`/`Product`/`Any`/`All`/`Min`/`Max`/
`First`/`Last`) **demoted P1 → P2** — redundant with the existing plain Foldable
helpers `sum`/`product`/`any`/`all`; the newtype-`foldMap` dance is *less*
approachable than `sum xs`, so it doesn't earn a P1 bite.

**Delivery plan (bites):**
- **Modules (no re-mint, first parallel wave):** `validation.mdk`, `nonempty.mdk`,
  eliminators (`option.mdk` + `result.mdk` + list-shaped `somes`/`oks`/`errs`/
  `partitionResults` into `list.mdk`).
- **Core (one batched re-mint at checkpoint):** the combinators / `map2`-`map3` /
  `-Then` family / `forEach`+`runEach` / `discard` / `replaceWith` (bite A), then
  `Bimappable` + impls (bite B).

## AS-BUILT (2026-07-02)

Everything in the delivery plan above SHIPPED, with all §0.5-locked names used
as designed. See `STDLIB.md` Modules 1/2/20–23 for the verified per-function
listing.

- **Modules (no re-mint):** `stdlib/validation.mdk` (`Validation e a`, accumulating
  `Applicative requires Semigroup e`, deliberately no `Thenable`), `stdlib/nonempty.mdk`
  (`NonEmpty a`, total `head`/`maximum`/`minimum`), `stdlib/option.mdk` (`option`
  eliminator), `stdlib/result.mdk` (`result` eliminator); `stdlib/list.mdk` gained
  `somes`/`oks`/`errs`/`partitionResults`.
- **Core (bite A + B, one re-mint):** `on`, `curry`, `uncurry`, `discard`, `map2`/`map3`,
  `foldThen`/`repeatThen`/`filterThen`, `forEach`/`runEach`, `guard`; new
  `Bimappable p` interface (`bimap`/`mapFirst`/`mapSecond`) with `impl Bimappable Result`
  and `impl Bimappable (,)`.
- **Two compiler changes enabled this, both landed as part of the same arc:**
  1. **Emitter PAP-in-container fix** (`0f4f4c1`) — a partially-applied multi-arg
     closure stored in a container and later saturated (exactly `map2`/`map3`'s
     `ap (map f fa) fb` shape) SIGSEGV'd on `build`. Fixed via arity-carrying
     closure cells + a runtime `mdk_apply` for arity-aware opaque application.
     See `compiler/EMITTER-GAPS.md`.
  2. **Tuples as a real type constructor** (Stage 1 `a642a43`, Stage 2 `c00ee2b`) —
     `(,)`/`(,,)`/`(,,,)`/`(,,,,)` surface syntax names the bare (unsaturated)
     tuple constructor in type position, which is what makes `impl Bimappable (,)`
     possible at all (a saturated `(a, b)` head is kind-inconsistent with a
     higher-kinded class param). See `compiler/TUPLE-TYPE-CONSTRUCTOR-DESIGN.md`.
     Seed re-minted (`9671acd`) — the prior seed couldn't parse `(,)`.

**Deferred to P2** (per the tiering above — unchanged by this session):
monoid newtypes (`Sum`/`Product`/`Any`/`All`/`Min`/`Max`/`First`/`Last`),
`Reader`/`Writer`/`State`, `zipWithThen`/`Kleisli`/`asum`, `Enum`, lazy `Seq`.

**Known residual (open, discovered during this arc, NOT tuple-specific):** a
typeclass impl defined in a non-prelude sibling module fails to emit its
`define` at **build** time (the call is emitted; the impl's LLVM define is
missing) — reproduces with plain `Result`/`Box` impls too, not just tuples.
Prelude impls (e.g. `impl Bimappable Result`, `impl Bimappable (,)` in
`core.mdk`) build and dispatch correctly; only a sibling-module impl trips it.
Eval-only fixtures capture the shape: `test/eval_typed_modules_fixtures/bimappable_tuple_sibling/`,
`test/eval_typed_modules_fixtures/bimappable_constrained_sibling/`,
`test/eval_typed_modules_fixtures/impl_requires_nonfunctor_sibling/`. See
`compiler/EMITTER-GAPS.md` for the pointer into `llvm_emit.mdk`.

---

## 1. Current FP surface census (what already exists — do not re-propose)

Read from `stdlib/core.mdk` (1174 lines) and `stdlib/list.mdk` (545 lines).

### Typeclasses already in `core` (auto-prelude)

| Medaka | Haskell/std equivalent | Methods (verified) |
|---|---|---|
| `Eq a` | Eq | `eq`; standalone `neq` |
| `Ord a requires Eq a` | Ord | `compare`, `lt/gt/lte/gte/min/max` (defaults via `compare`) |
| `Semigroup a` | Semigroup | `append` (backs `++`) |
| `Monoid a requires Semigroup a` | Monoid | `empty` |
| `Num a requires Eq a` | Num | `add sub mul div negate abs signum fromInt` |
| `Bounded a` | Bounded | `minBound maxBound` |
| `Debug a` | Show | `debug` (quoted/round-trippable) |
| `Display a` | (no direct HS analogue) | `display` (unquoted; backs `\{…}` interp) |
| `Hashable a` | Hashable | `hash` |
| `Mappable f` | **Functor** | `map` (effect-polymorphic `<e>`) |
| `Applicative f requires Mappable f` | Applicative | `pure`, `ap` |
| `Thenable m requires Applicative m` | **Monad** | `andThen` (`>>=` flipped); standalone `flatMap`, `flat` (join), `when`, `unless` |
| `Alternative f requires Applicative f` | Alternative | `noMatch` (empty), `orElse` (`<|>`) |
| `Foldable t` | Foldable | `fold` (foldl'), `foldRight` (foldr), **`foldMap`**, `toList`, `isEmpty`, `length` |
| `Filterable f requires Mappable f` | witherable Filterable | `filterMap`, `filter` |
| `Traversable t requires Mappable t, Foldable t` | Traversable | `traverse`, `sequence` |
| `FromEntries c e` | (container-literal sugar) | `fromEntries` — **multi-param class** |
| `Arbitrary a` | QuickCheck Arbitrary | `arbitrary`, `shrink` |
| `Generic a` | GHC.Generics | `to_rep`, `from_rep` (stub) |

### Data types + combinators already present

- **`Option a`** (= Maybe): `Some`/`None`; `isSome`, `isNone`, `fromOption`
  (= fromMaybe), `toResult`, `fromResult`. `Mappable`/`Applicative`/`Thenable`/
  `Alternative`/`Foldable`/`Traversable` instances all in core.
- **`Result e a`** (= Either): `Ok`/`Err`; `isOk`, `isErr`, `fromResultOr`
  (= fromRight-with-default), `mapErr` (= first/mapLeft). Instances as above; the
  `Result e` instances are marked `default` **specifically so an error-mapping
  or error-accumulating alternative can coexist** (`core.mdk:572,599,647` — the
  author already anticipated `Validation`).
- **Function combinators (core):** `identity`, `const`, `flip`, `compose` (`<<`),
  `pipe` (`>>`), `apply`, `fst`, `snd`. Operators `|>`/`>>`/`<<` per SYNTAX.md.
  Operator sections work (`(== x)`, `(+)`, `(2 * _)`).
- **Foldable helpers (generic, core):** `any`, `all`, `find`, `count`, `sum`,
  `product`, `elem`, `notElem`, `maximum`, `minimum`.
- **Bool:** `not`, `and`, `or`, `xor`, `otherwise`.
- **`list.mdk`:** rich — `map`/`filter`/`fold`/`foldRight`/`traverse`/`sequence`
  (via classes), `reverse`, `scanLeft`/`scanRight`, `zip`/`zip3`/`zipWith`/
  `unzip`, `take`/`drop`/`takeWhile`/`dropWhile`/`span`/`break`/`splitAt`/
  `slice`/`chunks`, `sort`/`sortBy`/`sortOn`, `nub`/`nubBy`, `group`/`groupBy`,
  `partition`, `tally`, `findIndex`/`findIndices`/`elemIndex`, `head`/`tail`/
  `last`/`init`/`get`, `intersperse`/`intercalate`, `transpose`, `subsequences`/
  `permutations`, `range`/`rangeStep`/`replicate`/`iterate`/`unfold`.

### What's conspicuously ABSENT (the gap this doc fills)

Confirmed by grep — none of these exist anywhere in `stdlib/`:
`bimap`, `curry`, `uncurry`, `on`, `void`, `<&>`/`$>`, `liftA2`/`liftA3`,
`foldM`, `replicateM`, `filterM`, `traverse_`/`for_`/`sequence_`, `guard`,
`>=>`/`<=<`, `mapMaybe`/`catMaybes` (as Option-list ops), `partitionEithers`/
`lefts`/`rights`, `either`, `maybe`, `getOrElse`/`unwrapOr`, `orElse` on Option
beyond the class method, `Validation`, `NonEmpty`, `Identity`, `Const`, `These`,
the monoid newtypes (`Sum`/`Product`/`Min`/`Max`/`All`/`Any`/`First`/`Last`/
`Endo`/`Dual`), `Reader`/`Writer`/`State`, lazy `Seq`/`Stream`, `Bifunctor`,
`Contravariant`, `Profunctor`, `Comonad`, `Enum`, `Semigroupoid`/`Category`.

---

## 2. Language comparison — the FP vocabulary

What Haskell / F# / OCaml programmers reach for, with PureScript + Scala cats as
hierarchy references. **Table-stakes** = present in ≥3 of the five and reached
for daily; **advanced** = present but specialist.

### 2.1 Function & functor combinators (table-stakes)

| Concept | Haskell | F# | OCaml | Have it? |
|---|---|---|---|---|
| id / const / flip | `Data.Function` | built-in / `id` | `Fun.id`,`Fun.const`,`Fun.flip` | ✅ `identity`/`const`/`flip` |
| compose / pipe | `.` / `&` | `>>` `<<` `\|>` | `Fun.compose`(4.something)/`\|>` | ✅ `<<`/`>>`/`\|>` |
| `on` | `Data.Function.on` | — | — | ❌ |
| curry / uncurry | `Data.Tuple`/Prelude | — (tuples native) | — | ❌ |
| fix | `Data.Function.fix` | — | — | ❌ (rec is native; low value) |
| void | `Data.Functor.void`/`Control.Monad.void` | `ignore` | `ignore` | ❌ |
| `$>` `<$` `<&>` | `Data.Functor` | — | — | ❌ |

Every mainstream FP lib ships `on`, `void`, and functor operators. `curry`/
`uncurry` are Haskell/PureScript/cats table-stakes (F#/OCaml lean on native
tuples so need them less — but Medaka tuples are not auto-uncurried, so they earn
their place).

### 2.2 Applicative / monadic helpers (table-stakes)

| Concept | Haskell (`Control.Monad`/`Applicative`) | F# | OCaml | Have it? |
|---|---|---|---|---|
| `liftA2`/`liftA3` | ✅ | (CE `let!`+`and!`) | (`let+`/`and+` ppx) | ❌ (only `ap`) |
| `guard` | ✅ `Control.Monad.guard` | — | — | ❌ |
| `when`/`unless` | ✅ | — | — | ✅ (core) |
| `void` | ✅ | `ignore` | `ignore` | ❌ |
| `join` | ✅ | — | `Option.join` etc. | ✅ `flat` |
| `foldM` | ✅ | `List.fold` (no monad) | — | ❌ |
| `filterM` | ✅ | — | — | ❌ |
| `replicateM`/`_` | ✅ | — | — | ❌ |
| `traverse_`/`for_`/`sequence_` | ✅ `Data.Foldable` | `Seq.iter` | `List.iter` | ❌ (only value-returning `traverse`) |
| `zipWithM` | ✅ | — | — | ❌ (P2) |
| `mapAndUnzipM` | ✅ | — | — | ❌ (P3, niche) |
| Kleisli `>=>`/`<=<` | ✅ | — | — | ❌ (P2) |
| `mplus`/`msum`/`asum` | ✅ | — | — | partial (`orElse` exists; no `asum`) |

Everything in this block is **[pure]** over the existing `Thenable`/`Applicative`/
`Foldable`/`Alternative` classes and works over user monads because `do` does
(§0). This is the highest value-per-line category for a young FP language.

### 2.3 Option / Result rich combinators (table-stakes — F#/OCaml set the bar)

F# `Option`/`Result` and OCaml `Option`/`Result` modules are the gold standard
of "small but complete". Medaka has the constructors + a handful of helpers but
is missing the everyday ones:

| Concept | Haskell | F# | OCaml | Have it? |
|---|---|---|---|---|
| `maybe`/`option elim` | `Data.Maybe.maybe` | `Option.fold`/`defaultValue` | `Option.fold`/`value` | ❌ (`fromOption` only) |
| `either` elim | `Data.Either.either` | `Result` match | `Result.fold` | ❌ |
| getOrElse / unwrapOr | `fromMaybe` | `Option.defaultValue` | `Option.value ~default` | ✅ `fromOption`/`fromResultOr` |
| `orElse` (Option-biased) | `Data.Maybe`/`<\|>` | `Option.orElse` | — | ✅ (Alternative method) |
| `mapError`/`mapLeft` | `Data.Bifunctor.first` | `Result.mapError` | `Result.map_error` | ✅ `mapErr` |
| `mapMaybe`/`filterMap` | `Data.Maybe.mapMaybe` | `List.choose` | `List.filter_map` | ✅ `filterMap` (class) |
| `catMaybes` | `Data.Maybe.catMaybes` | `List.choose id` | — | ❌ |
| `partitionEithers`/`lefts`/`rights` | `Data.Either` | `List.partition`+ | `List.partition_map` | ❌ |
| `toList`/`maybeToList` | `Data.Maybe` | `Option.toList` | `Option.to_list` | ✅ (Foldable `toList`) |
| `listToMaybe`/`tryHead` | `Data.Maybe` | `List.tryHead` | — | ✅ `list.head` |

### 2.4 The typeclass hierarchy — what's missing (PureScript/cats reference)

PureScript's `prelude` and Scala **cats** are the canonical "complete lawful
hierarchy". Mapping Medaka against them:

| Class | PureScript / cats | Medaka status | Verdict |
|---|---|---|---|
| Functor / Apply / Applicative / Bind / Monad | ✅ / ✅ | ✅ `Mappable`/`Applicative`/`Thenable` | complete |
| Semigroup / Monoid | ✅ / ✅ | ✅ | complete |
| Foldable / Traversable | ✅ / ✅ | ✅ | complete |
| Alternative / Plus | ✅ / `Alternative`+`MonoidK` | ✅ `Alternative` | complete |
| **Bifunctor** | ✅ / `Bifunctor` | ❌ | **P1** (bimap for Result/tuple) |
| **Contravariant** | ✅ / `Contravariant` | ❌ | P2 |
| **Profunctor** | ✅ / `Profunctor` | ❌ | P3 |
| **Comonad** | (`purescript-free`) / `Comonad` | ❌ | P3 (few use cases) |
| **Semigroupoid / Category** | ✅ / `Category` | ❌ | P3 (functions only; `<<`/`>>` cover it) |
| **Enum / BoundedEnum** | ✅ `Enum` | ❌ | P2 (succ/pred/range; `Bounded` exists) |
| `Eq1`/`Ord1`/`Show1` | (via `Data.Eq`) / `Eq1` etc. | ❌ | P3 (needs quantified constraints — see §4) |
| Foldable1 / Semigroup over NonEmpty | ✅ / `Reducible`,`NonEmptyList` | ❌ | P2 (with `NonEmpty`) |
| **MonadError / ApplicativeError** | — / ✅ | partial (`Result` is it) | P2 as a class |

### 2.5 Error handling — `Validation` (the headline gap)

Every serious FP ecosystem ships an **accumulating-error applicative** distinct
from the fail-fast Either/Result:

- **Haskell:** `validation` package — `Data.Validation.Validation e a`
  (`Failure e | Success a`); `Applicative` accumulates via `Semigroup e`;
  **deliberately no `Monad` instance** (a lawful Monad must short-circuit).
- **PureScript:** `purescript-validation` — `Data.Validation.Semigroup.V err a`,
  same shape, same "no Monad" caveat.
- **Scala cats:** `cats.data.Validated[E, A]` (`Invalid`/`Valid`) — the canonical
  example; `ValidatedNel` = `Validated[NonEmptyList[E], A]` for form validation.
- **F#:** FSharpPlus `Validation<'e,'a>`; the pattern is folklore in F# form/DTO
  validation.

The shape: identical to `Result`, but `ap (Err e1) (Err e2) = Err (e1 <> e2)`
(accumulate) instead of `ap (Err e1) _ = Err e1` (short-circuit). It is
**Applicative-but-not-Monad by design**: a monadic bind *can't* accumulate — the
second error only exists if the first computation succeeded — so a `Monad`
instance would disagree with the `Applicative` and break coherence. All four
reference libs make exactly this choice (confirmed via their docs, §7).

### 2.6 Data types (mixed)

| Type | Haskell | F# | OCaml | cats/PS | Verdict |
|---|---|---|---|---|---|
| `NonEmpty` list | `Data.List.NonEmpty` | — | — | `NonEmptyList` | **P1** (total `head`/`max`) |
| `Identity` | `Data.Functor.Identity` | — | — | `cats.Id` | P2 (monad-transformer base; low value pre-transformers) |
| `Const` | `Data.Functor.Const` | — | — | `Const` | P3 (lens plumbing) |
| **`Validation`** | `validation` | FSharpPlus | — | `Validated` | **P1** |
| `These` / `Ior` | `these` | — | — | `Ior` | P3 |
| monoid newtypes | `Data.Monoid`/`Semigroup` | — | — | `cats.kernel` | **P1** (`Sum`/`Product`/`Any`/`All`/`Min`/`Max`/`First`/`Last`) |
| `Endo`/`Dual` | `Data.Monoid` | — | — | ✅ | P2/P3 |
| lazy `Seq`/`Stream` | lazy lists | `Seq` | `Seq` (`Stdlib.Seq`) | `Stream`/`fs2` | P2 (Medaka is strict → needs thunks, §4) |
| `Reader`/`Writer`/`State` | `mtl`/`transformers` | — | — | cats `Kleisli`/`Writer`/`State` | P2 (value-level monads) |

---

## 3. P1 / P2 / P3 tiering (proposed additions)

Each row: what, HS/F#/OCaml name, one-line Medaka API sketch (Medaka naming),
cost tag, and **core-worthy** (auto-prelude) vs **module** (import-by-name).

### P1 — highest value, mostly one-liners

| Item | = | Medaka sketch | Cost | Where |
|---|---|---|---|---|
| **Applicative/monadic helpers** | liftA2/guard/void/foldM/replicateM/filterM/traverse_/for_/sequence_ | `liftA2 : Applicative f => (a -> b -> c) -> f a -> f b -> f c`; `guard : Alternative f => Bool -> f Unit`; `void : Mappable f => f a -> f Unit`; `foldM : Thenable m => (b -> a -> m b) -> b -> List a -> m b`; `replicateM : Thenable m => Int -> m a -> m (List a)`; `traverse_ : (Thenable m, Foldable t) => (a -> m Unit) -> t a -> m Unit` | [pure] | **core** (ubiquitous; `guard`/`void`/`liftA2` belong next to `when`/`unless`) |
| **Function combinators** | on / curry / uncurry / void | `on : (b -> b -> c) -> (a -> b) -> a -> a -> c`; `curry : ((a,b) -> c) -> a -> b -> c`; `uncurry : (a -> b -> c) -> (a,b) -> c` | [pure] | **core** (next to `flip`/`compose`) |
| **Functor operators** | `<&>` `$>` `<$` | `mapFlip`/`(<&>) : f a -> (a -> b) -> f b`; `constMap`/`($>) : f a -> b -> f b` | [pure] | **core** (operators need to be in scope everywhere) |
| **Option/Result eliminators** | maybe / either / catMaybes / partitionEithers / lefts / rights | `option : b -> (a -> b) -> Option a -> b`; `either : (e -> c) -> (a -> c) -> Result e a -> c`; `catOptions : List (Option a) -> List a`; `partitionResults : List (Result e a) -> (List e, List a)` | [pure] | **module** `option`/`result` (or extend `list`) — not every program needs them |
| **`Bifunctor`** | Data.Bifunctor | `interface Bifunctor p where bimap : (a -> c) -> (b -> d) -> p a b -> p c d` + `first`/`second`; impls for `Result`/tuple | [pure] | **core** (small; `first`=`mapErr` generalized; `bimap` on `Result` is daily) |
| **monoid newtypes + `foldMap` payoff** | Sum/Product/Any/All/Min/Max/First/Last | `data Sum a = Sum a` with `impl Semigroup/Monoid`; `getSum`; then `getSum (foldMap Sum xs)` works via the existing `foldMap` | [pure] | **module** `monoid` (wrappers are niche enough not to pollute the prelude) |
| **`Validation`** | validation / Validated | `data Validation e a = Failure e \| Success a`; `Applicative` accumulates via `Semigroup e`; **no `Thenable`**; `validate`/`toResult`/`fromResult` bridges | [pure] | **module** `validation` |
| **`NonEmpty`** | Data.List.NonEmpty | `data NonEmpty a = NECons a (List a)`; total `neHead`/`neMax`/`neMin`; `Foldable`/`Mappable`/`Traversable`/`Semigroup` | [pure] | **module** `nonempty` |

### P2 — next wave

| Item | = | Cost | Notes |
|---|---|---|---|
| `zipWithM` / Kleisli `>=>`/`<=<` / `asum`/`msum` | Control.Monad | [pure] | Round out the monad kit once P1 lands |
| `Reader`/`Writer`/`State` (value-level monads) | mtl/cats | [pure] | Each a `data` + `Thenable` instance; `do` works over them. **Not effects.** Writer needs `Monoid`. |
| `Enum` class | Enum | [pure+core] | `succ`/`pred`/`enumFromTo`; ranges already exist for Int as sugar |
| `Identity` | Data.Functor.Identity | [pure] | Base case for a future transformer story; low value until then |
| `These`/`Ior` | these/Ior | [pure] | `data These a b = This a \| That b \| Both a b` |
| `Endo`/`Dual` monoids | Data.Monoid | [pure] | With the P1 monoid module |
| `MonadError`/`ApplicativeError` as a class | cats | [needs-feature?] | Only worth it if a second error monad appears; `Result` covers most |
| Foldable1 over `NonEmpty` | Reducible | [pure] | Total `fold1`/`max1` |
| lazy `Seq`/`Stream` | OCaml Seq | [needs-feature] | Medaka is strict → thunk encoding (§4). Real but deferrable. |

### P3 — later / on-demand

`Contravariant`, `Profunctor`, `Comonad`, `Category`/`Semigroupoid`,
`Const`, `Eq1`/`Ord1`/`Show1`, `mapAndUnzipM`, `Divisible`. All expressible
(HKT + multi-param classes) but specialist; add on demand.

---

## 4. Expressibility & cost notes (grounded in what I read)

- **Almost everything above is `[pure]`.** The helpers in §2.2/§2.3 are literal
  one-to-five-line functions over the existing classes. Because `do` desugars
  over any `Thenable` (verified on `ByteParser`), `foldM`/`replicateM`/`filterM`/
  `traverse_` work over user monads with no compiler change.
- **`Bifunctor` / `Validation` / `NonEmpty` / monoid newtypes are all
  expressible today.** HKT + `requires` + multi-param classes cover them, and
  relaxed value restriction (§0) makes the `data`-wrapper/polymorphic-constant
  patterns generalize. `Validation`'s no-Monad-instance is a *feature* — just
  don't write `impl Thenable Validation` (and the `Applicative (Result e)` impl
  is already `default`, leaving room for a sibling).
- **`foldMap` monoid payoff is nearly free.** `foldMap` exists; the monoid module
  just adds `data Sum a = Sum a` + instances. Watch one subtlety: `sum`/`product`
  in core note that `(+)`/`(*)` don't yet dispatch through `Num.add` for
  user types — the monoid-newtype route (`getSum . foldMap Sum`) is the *clean*
  generalization that sidesteps that, so it's worth having for that reason too.
- **`core`-worthy items force a seed re-mint.** Anything added to `core.mdk`
  (the applicative/monadic helpers, function combinators, functor operators,
  `Bifunctor`) perturbs the compiler build → **re-mint + `selfcompile_fixpoint`**
  (batch them into one checkpoint, per the "defer seed re-mints" practice). The
  separate modules (`validation`, `nonempty`, `monoid`, `option`/`result`
  eliminators) are import-by-name and need **no re-mint** — cheapest, and good
  first bites.
- **Effect-polymorphism caveat.** Existing methods thread `<e>` (e.g.
  `map : (a -> <e> b) -> f a -> <e> f b`). New helpers should mirror that
  signature style so an effectful callback (`traverse_` running `<IO>` actions)
  type-checks. This is `[interacts-with-effects]` only in that the *signatures*
  must carry `<e>`; no new effect infra.
- **`Reader`/`Writer`/`State` are value-level monads, not effects** — they are
  `data` + `Thenable`, exactly like `Async`. Clean, `[pure]`, but P2 because
  without monad transformers they don't compose with each other or with `<IO>`,
  which limits their payoff.
- **lazy `Seq`/`Stream` is the one genuine `[needs-feature]` here.** Medaka is
  strict; a lazy sequence needs a thunk encoding (`data Seq a = SNil | SCons a
  (Unit -> Seq a)`) or a memoizing `Ref`-thunk. Expressible (async.mdk already
  does thunk-based deferral with `Suspend`), but it's a real module with its own
  laziness discipline, not a one-liner. Defer to P2.
- **Multi-param classes with functional dependencies / `Eq1`-style quantified
  constraints** are the only things that might exceed the type system.
  `FromEntries c e` shows plain multi-param works, but `Eq1`
  (`forall a. Eq a => Eq (f a)`) wants a *quantified* constraint — verify before
  committing (P3, so low urgency).

---

## 5. Highest-value P1 picks — validated against the comparison

The maintainer's priors, adjudicated:

1. **Applicative/monadic helpers (`foldM`/`replicateM`/`traverse_`/`guard`/
   `void`/`liftA2`) — YES, top pick.** Table-stakes in Haskell; pure one-liners;
   work over user monads *today* because `do` does. Highest value-per-line in the
   whole doc. `traverse_`/`for_`/`sequence_` especially: right now the only way to
   run an effectful action per element and discard results is to build a list and
   throw it away.
2. **`Validation` — YES, the headline.** With no exceptions, accumulating
   `Validation` is the *only* way to report multiple errors at once. The core
   author already left the `Result e` Applicative `default` to make room for it.
   High value, pure, self-contained module.
3. **`Bifunctor`/`bimap` — YES, but modest.** `bimap`/`first`/`second` on
   `Result` and tuples is daily FP. Cheap. `first` generalizes the existing
   `mapErr`. Core-worthy but small.
4. **Function combinators (`on`/`curry`/`uncurry`/`void`/`<&>`) — YES.**
   `on` (`sortBy (compare `on` fst)`) and `void` are reached-for constantly;
   `curry`/`uncurry` matter *because* Medaka tuples aren't auto-curried. Trivial.
5. **Rich Option/Result combinators (`maybe`/`either`/`catOptions`/
   `partitionResults`) — YES, but as a module, not core.** F#/OCaml prove these
   are table-stakes; but they're not needed by *every* program, so keep them out
   of the auto-prelude.
6. **Monoid newtype wrappers + `foldMap` — YES, worth it, as a module.**
   `foldMap` already exists and is inert without them; `getSum (foldMap Sum xs)`
   is the canonical demo. Low urgency but cheap and it "completes" an existing
   feature.

**What's noise for a young language (defer):** `Contravariant`, `Profunctor`,
`Comonad`, `Category`, `Const`, `Eq1`/`Ord1`/`Show1`, `Endo`/`Dual`, `These`.
All expressible, none reached-for daily. `fix` too — native recursion covers it.
`Identity` is only useful as a transformer base, which Medaka doesn't have yet.

---

## 6. Design forks (need a human decision)

1. **Auto-prelude (`core`) vs separate module for the new classes/helpers?**
   Adding to `core` grows *every* program's binary and forces a re-mint each time.
   - *Recommendation:* **core** for the tiny, universal, operator-ish items
     (`on`/`curry`/`uncurry`/`void`/`liftA2`/`guard`/`<&>`/`$>` and `Bifunctor`)
     — they're the same weight class as `when`/`flip`, which are already in core,
     and operators must be in scope everywhere. **Separate modules** for
     `validation`, `nonempty`, `monoid` (newtypes), and the Option/Result
     eliminator bundle — self-contained, not universal, and re-mint-free. Batch
     the core additions into **one** re-mint checkpoint.

2. **`Validation`: new type vs a `Result`-with-Semigroup Applicative variant?**
   - *Recommendation:* **new type** `data Validation e a = Failure e | Success a`.
     A type's Applicative instance is fixed; you cannot have `Result` both
     short-circuit (its current `default` impl, relied on by `traverse`/`do`) and
     accumulate. A distinct type makes the "no Monad instance" law-boundary
     explicit and lets `traverse`-with-`Validation` accumulate while `Result`
     stays fail-fast. Provide `toResult`/`fromResult` bridges. This matches
     Haskell/PureScript/cats exactly.

3. **`NonEmpty` now (P1) or later?**
   - *Recommendation:* **P1, as a module.** It's the clean fix for the partial
     `head`/`maximum`/`minimum` (which return `Option` today); `NonEmpty` makes
     them total. Pure, small, and it pairs naturally with `Validation`
     (`ValidatedNel`-style accumulation into a `NonEmpty` of errors). Low risk.

4. **Lazy `Seq`/`Stream` in P1 or defer?**
   - *Recommendation:* **defer to P2.** It's the only genuine `[needs-feature]`
     (thunk encoding) in the FP set, and strict `List` + the existing generic
     `Foldable` cover most needs. Design it deliberately alongside a
     memoization/`Ref`-thunk decision, not as a P1 rush.

5. **`Reader`/`Writer`/`State` now or P2?**
   - *Recommendation:* **P2.** Each is a pure `data` + `Thenable` and `do` works
     over them — but without monad transformers they don't stack or interleave
     with `<IO>`, so their real-world payoff is limited until a transformer story
     exists. Ship the monadic *helpers* (P1) first; they benefit every existing
     monad including `Async`. Revisit Reader/Writer/State when (if) transformers
     are on the roadmap.

6. **Do the Option/Result eliminators live in `option`/`result` modules or extend
   `list`?** `catOptions`/`partitionResults` are list-shaped; `maybe`/`either`
   are not.
   - *Recommendation:* put `maybe`/`either`/`getOrElse`-family in small
     `option.mdk`/`result.mdk` modules (mirroring F#/OCaml's `Option`/`Result`
     modules — discoverable by name), and the list-shaped `catOptions`/
     `partitionResults`/`lefts`/`rights` in `list.mdk` (they belong with `zip`/
     `partition`). Avoids a circular "list imports option imports list".

---

## 7. Sources

FP-surface references cross-checked against official docs (2026-07):

- Haskell `Control.Monad` —
  https://hackage.haskell.org/package/base/docs/Control-Monad.html ;
  `Control.Applicative` —
  https://hackage.haskell.org/package/base/docs/Control-Applicative.html
  (also `Data.Function`, `Data.Functor`, `Data.Maybe`, `Data.Either`,
  `Data.Bifunctor`, `Data.Foldable`, `Data.Semigroup`/`Data.Monoid` newtypes,
  `Data.List.NonEmpty`, `Data.Functor.Identity`/`Const` in `base`)
- Haskell `validation` (`Data.Validation` — accumulating applicative, no Monad) —
  https://hackage.haskell.org/package/validation-1.1.3/docs/Data-Validation.html
  (repo https://github.com/system-f/validation)
- F# `Option` module —
  https://fsharp.github.io/fsharp-core-docs/reference/fsharp-core-optionmodule.html
  ; `Result` —
  https://fsharp.github.io/fsharp-core-docs/reference/fsharp-core-resultmodule.html
  (Validation is community — FSharpPlus / FsToolkit.ErrorHandling, not core)
- OCaml stdlib — https://ocaml.org/api/Option.html ,
  https://ocaml.org/api/Result.html , https://ocaml.org/manual/5.3/api/Stdlib.Seq.html
  (`Fun`, `List.filter_map`/`List.partition_map`)
- PureScript `Data.Validation.Semigroup` —
  https://pursuit.purescript.org/packages/purescript-validation/5.0.0/docs/Data.Validation.Semigroup
  (prelude hierarchy at
  https://pursuit.purescript.org/packages/purescript-prelude)
- Scala cats — https://typelevel.org/cats/typeclasses.html and
  `cats.data.Validated` https://typelevel.org/cats/api/cats/data/Validated.html
  (`Ior`, `NonEmptyList`, `Kleisli`/`Writer`/`State`)

*(A background research pass cross-checked category presence and exact names
against the docs above.)*
