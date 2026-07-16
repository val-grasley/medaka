# Medaka Standard Library Plan

> Historical bug-fix citations below (`lib/prelude.ml`, `lib/resolve.ml`,
> `lib/typecheck.ml`, `eval.ml`, `bin/main.ml`) reference the OCaml reference
> compiler, removed 2026-06-26 (`06356a80` — see AGENTS.md / `LIB-REMOVAL-DESIGN.md`).
> Those paths no longer exist; the fixes they describe are already reflected in
> the native `compiler/` sources.

This document lists what belongs in the first four stdlib modules. It is a
checklist, not a spec: implementation order within a module is yours to choose.
No code snippets — just the names, grouped so nothing slips through.

Work interactively via the REPL (`:load stdlib/core.mdk`, `:reload` after edits).
Expect to discover language gaps as you go; record them in PLAN.md's open
roadmap.

> **Forward direction — capability stratification (decided 2026-06-06).** For the
> multi-target future (general-purpose LLVM-native + WASM-edge; see
> [`compiler/RUNTIME-DESIGN.md`](../../compiler/RUNTIME-DESIGN.md) §6a and
> [`CAPABILITY-EFFECTS.md`](../design/CAPABILITY-EFFECTS.md)), the stdlib will be
> **stratified** into a **pure core** (data structures, algorithms — capability-free,
> byte-identical on every target) vs. **capability modules** (file IO, net, KV, time,
> RNG — effect-labeled, present only where the target grants the capability).
> Capability-bearing functions get effect labels and live in capability modules,
> never the pure core. New stdlib work should respect this split now — retrofitting
> it later is expensive. Phase 146 wires the effect labels.

**Status legend**

- ✅ implemented in the indicated file
- ⏳ planned, not yet started
- 🟡 partially implemented / superseded (see note)
- ⛔ intentionally not provided (see note)

**Notes on the current state (as of 2026-06-01).**

- Modules 1–4 are implemented, including `Bounded Int`/`Bounded Char` (Phase 93,
  via native bound externs). The only deliberate gap: `String.fromInt`/`fromFloat`
  (would collide with `Num.fromInt`; use the global `intToString`/`floatToString`).
- `maximum`/`minimum`/`notElem` were made **generic over `Foldable`** in `core`
  (not List/Array-specific), per the preference for interface-driven generality.

- The compiler prepends `stdlib/core.mdk` to every user program (`lib/prelude.ml`),
  so every name marked ✅ in `core` is in scope without an `import`.
- Constraint syntax has landed (Phase 20 ✅). Items previously blocked on
  "move to standalone once constraint syntax lands" can now be standalone
  functions. They are listed that way below.
- `Monad` has been renamed `Thenable` and now drives `do`-notation dispatch.
- A `Semigroup` interface was added (Phase 22 ✅) and now backs `++`.
- The runtime extern catalog lives in `stdlib/runtime.mdk` (see §0 below); the
  evaluator's primitive table mirrors it.

---

## Remaining work (roadmap)

Modules 1–10 are implemented (✅). What's left is incremental — additions to
existing modules, not new modules. PLAN.md's "Standard library" workstream points
here. In rough priority order:

- **`<>` Semigroup operator** — not lexed at all; `a <> b` fails at the lexer. The
  `Semigroup` interface and `++` dispatch work; only the `<>` operator token is missing.
- **`impl Semigroup (List a)`** — ✅ present in `core.mdk`; cosmetic gap that it doesn't
  also live in `list.mdk`. Not a functional gap.
- **JSON follow-ups** (Module 9, deferred from v1): indented pretty-printer;
  `ToJson`/`FromJson` codec interfaces for user types (a strong `deriving`
  exercise).
- **Effect-label refinement** — see §"Label refinement roadmap" below. Shared with
  the capability-effects wedge (PLAN.md): `wallTimeSec`→`<Time>`, the `<IO>` split
  (`<Stdout>`/`<Stderr>`/`<Stdin>`/`<Fs>`/`<Args>`/`<Env>`), `panic`/`exit` split,
  cross-module label export, then manifest emission.
- **Deferred / minor:** single-codepoint `s.[i]` string indexing (rejected at
  typecheck since bracket slicing landed); conditional auto-import of the `test`
  vocabulary (Module 10 v2, blocked on `marked_prelude` coalescing).

---

## Module 0 — `runtime` (extern catalog) ✅ implemented

These are the primitives declared as `extern` in `stdlib/runtime.mdk`. They are
visible to every Medaka program without an import. The list below reflects
the **current** labels (fine-grained after the `<IO>` split — verified 2026-06-22).

- `putStr : String -> <Stdout> Unit` — write a string to stdout, no trailing newline
- `putStrLn : String -> <Stdout> Unit` — write a string to stdout followed by `\n`
- (`print`/`println : Display a => a -> <IO> Unit` are Medaka prelude functions
  over `putStr`/`putStrLn`, not externs — they render via `Display`, Phase 111)
- `Ref : a -> Ref a` — wrap a value in a mutable cell (read it back via `r.value`)
- `set_ref : Ref a -> a -> Unit` — overwrite the contents of a `Ref` (mutation is untracked, no effect row)
- `hashInt`, `hashFloat`, `hashString`, `hashChar`, `hashBool : _ -> Int` — type-specific
  hash externs; the `Hashable` interface in `core.mdk` calls these (replaced the old
  generic `hash : a -> Int` extern)
- `pi : Float` — math constant π
- `e : Float` — math constant e
- `readLine : Unit -> <Stdin> String` — read one line from stdin
- `readFile : String -> <FileRead> (Result String String)` — read file, `Ok contents` or `Err message`
- `writeFile : String -> String -> <FileWrite> (Result String Unit)` — write file, `Ok ()` or `Err message`
- `exit : Int -> Unit` — terminate the process with the given exit code
- `panic : String -> a` — abort with a runtime panic carrying the message

io Module 7 host primitives (see Module 7 for the ergonomic layer):

- `args : Unit -> <Env> (List String)` — program args after the script name
- `getEnv : String -> <Env> (Option String)` — environment variable, or `None`
- `fileExists : String -> <FileRead> Bool`
- `appendFile : String -> String -> <FileWrite> (Result String Unit)` — `Ok ()` / `Err message`
- `listDir : String -> <FileRead> (Result String (List String))` — directory entry names
- `ePutStr` / `ePutStrLn : String -> <Stderr> Unit` — raw stderr output
- `readLineOpt : Unit -> <Stdin> (Option String)` — one stdin line, `None` at EOF
- `readAll : Unit -> <Stdin> String` — all of stdin

`pure` and `map` are *not* externs — they are interface methods (see `core`).

---

## Module 1 — `core` ✅ implemented

The foundation every other module depends on. Implemented in `stdlib/core.mdk`
and prepended to every program by the compiler.

### Interfaces

- ✅ `Eq a` — equality comparison
  - `eq : a -> a -> Bool` — true when the two values are structurally equal
  - `neq : Eq a => a -> a -> Bool` (standalone, default `not (eq x y)`) — negation of `eq`; standalone so impls cannot make it disagree with `eq`

- ✅ `Ord a` requires `Eq a` — total ordering
  - `compare : a -> a -> Ordering` — return `Lt`, `Eq`, or `Gt`
  - `lt : a -> a -> Bool` (default from `compare`) — strict less-than; method (not standalone) so impls can override for speed or NaN semantics
  - `gt : a -> a -> Bool` (default from `compare`) — strict greater-than
  - `lte : a -> a -> Bool` (default from `compare`) — less-than-or-equal
  - `gte : a -> a -> Bool` (default from `compare`) — greater-than-or-equal
  - `min : a -> a -> a` (default from `compare`) — pick the smaller of two values
  - `max : a -> a -> a` (default from `compare`) — pick the larger of two values
  - ✅ `clamp : Ord a => a -> a -> a -> a` (standalone) — `clamp lo hi x` constrains `x` to `[lo, hi]`

- ✅ `Debug a` — human-readable string representation
  - `debug : a -> String` — render a value as a `String` for display

- ✅ `Semigroup a` — associative combine (used by the `++` operator)
  - `append : a -> a -> a` — combine two values; must be associative

- ✅ `Monoid a` requires `Semigroup a` — semigroup with identity element
  - `empty : a` — identity such that `append empty x == x == append x empty`

- ✅ `Num a` requires `Eq a` — numeric arithmetic (backs `+`/`-`/`*`/`/`)
  - `add : a -> a -> a` — addition
  - `sub : a -> a -> a` — subtraction
  - `mul : a -> a -> a` — multiplication
  - `div : a -> a -> a` — division (semantics impl-defined: truncating for `Int`, true for `Float`)
  - `negate : a -> a` — additive inverse
  - `abs : a -> a` — absolute value
  - `signum : a -> a` — sign as `-1`, `0`, or `1`
  - `fromInt : Int -> a` — convert an `Int` literal to this numeric type

- ✅ `Bounded a` — types with a minimum and maximum value
  - `minBound : a` — smallest representable value
  - `maxBound : a` — largest representable value

- ✅ `Mappable f` — structure-preserving map (Functor)
  - `map : (a -> b) -> f a -> f b` — apply a function inside the structure

- ✅ `Applicative f` requires `Mappable f`
  - `pure : a -> f a` — lift a value into the minimal context
  - `ap : f (a -> b) -> f a -> f b` — apply an effectful function to an effectful argument

- ✅ `Thenable m` requires `Applicative m` — drives `do`-notation
  - `andThen : m a -> (a -> m b) -> m b` — sequence two computations, threading the result; equivalent to Haskell's `>>=` with arguments flipped. `do`-block `<-` desugars to this (Phase 19 wiring TODO).

  Standalone helpers (constraint syntax has landed, so these no longer need to
  be methods):
  - ✅ `flatMap : Thenable m => (a -> m b) -> m a -> m b` — `andThen` with arguments flipped
  - ✅ `flat : Thenable m => m (m a) -> m a` — collapse a nested wrapped value (was `join`)
  - ✅ `when : Thenable m => Bool -> m Unit -> m Unit` — run the action only when the condition is true
  - ✅ `unless : Thenable m => Bool -> m Unit -> m Unit` — run the action only when the condition is false

- ✅ `Foldable t` — collapsible into a summary value
  - `fold : (b -> a -> b) -> b -> t a -> b` — left fold
  - `foldRight : (a -> b -> b) -> b -> t a -> b` — right fold
  - `foldMap : Monoid m => (a -> m) -> t a -> m` (default via `fold` + `append`/`empty`) — map each element to a monoid and combine
  - `toList : t a -> List a` — flatten to a plain list (linearises order)
  - `isEmpty : t a -> Bool` (default via `toList`; override for O(1) structures) — true when there are no elements
  - `length : t a -> Int` (default via `fold`; override for O(1) structures) — element count

  Standalone helpers (all use constraint syntax now that Phase 20 has landed):
  - ✅ `any : Foldable t => (a -> Bool) -> t a -> Bool` — true when the predicate holds for at least one element
  - ✅ `all : Foldable t => (a -> Bool) -> t a -> Bool` — true when the predicate holds for every element
  - ✅ `find : Foldable t => (a -> Bool) -> t a -> Option a` — first element satisfying the predicate, or `None`
  - ✅ `count : Foldable t => (a -> Bool) -> t a -> Int` — number of elements satisfying the predicate
  - ✅ `sum : (Foldable t, Num a) => t a -> a` — additive fold; identity is `fromInt 0`
  - ✅ `product : (Foldable t, Num a) => t a -> a` — multiplicative fold; identity is `fromInt 1`
  - ✅ `elem : (Foldable t, Eq a) => a -> t a -> Bool` — true when the element is present (compared via `Eq`)
  - ✅ `notElem : (Foldable t, Eq a) => a -> t a -> Bool` — `not (elem x xs)`
  - ✅ `maximum : (Foldable t, Ord a) => t a -> Option a` — largest element, or `None` when empty
  - ✅ `minimum : (Foldable t, Ord a) => t a -> Option a` — smallest element, or `None` when empty

- ✅ `Filterable f` requires `Mappable f` — containers that can drop elements
  - `filterMap : (a -> Option b) -> f a -> f b` — the primitive; apply a partial function, keep `Some` results
  - `filter : (a -> Bool) -> f a -> f a` (default via `filterMap`) — keep elements satisfying the predicate

- ✅ `Bimappable p` (P1, 2026-07-02; Haskell `Bifunctor`, renamed to fit `Mappable`/`Thenable`) — a two-slot container mappable independently on each side
  - `bimap : (a -> c) -> (b -> d) -> p a b -> p c d` — map both sides at once
  - `mapFirst : (a -> c) -> p a b -> p c b` (default via `bimap identity`) — touch only the left/`Err` side
  - `mapSecond : (b -> d) -> p a b -> p a d` (default via `bimap identity`) — touch only the right/`Ok` side
  - ✅ Instances: `impl Bimappable (Result e)`, `impl Bimappable (,)` (the bare 2-tuple constructor — enabled by the tuple-as-type-constructor change, see `compiler/TUPLE-TYPE-CONSTRUCTOR-DESIGN.md`)

### Data types

- ✅ `Ordering` — `Lt | Eq | Gt` — three-way comparison result

- ✅ `Option a` — `Some a | None` — value that may be absent
  Helpers:
  - ✅ `isSome : Option a -> Bool` — true if `Some _`
  - ✅ `isNone : Option a -> Bool` — true if `None`
  - ✅ `fromOption : a -> Option a -> a` — extract value or fall back to default (also known as `withDefault` in some langs)
  - ✅ `toResult : e -> Option a -> Result e a` — `Some x → Ok x`, `None → Err e`
  - ✅ `fromResult : Result e a -> Option a` — `Ok x → Some x`, `Err _ → None` *(was named `toOption` in earlier draft)*
  - ✅ Instances: `Eq (Option a)`, `Ord (Option a)`, `Debug (Option a)`, `Mappable Option`, `Foldable Option`, `Applicative Option`, `Thenable Option`

- ✅ `Result e a` — `Ok a | Err e` — success-or-error value
  Helpers:
  - ✅ `isOk : Result e a -> Bool` — true if `Ok _`
  - ✅ `isErr : Result e a -> Bool` — true if `Err _`
  - ✅ `fromResultOr : a -> Result e a -> a` — extract `Ok` value or fall back to default (renamed from the earlier draft's `fromResult` to avoid collision with `Option`'s)
  - ✅ `mapErr : (e -> f) -> Result e a -> Result f a` — apply to the `Err` side, pass `Ok` through
  - ✅ Instances: `Eq (Result e a)`, `Ord (Result e a)`, `Debug (Result e a)`, `Mappable (Result e)`, `Thenable (Result e)`

### Utility functions

- ✅ `identity : a -> a` — return the argument unchanged
- ✅ `const : a -> b -> a` — return the first argument, ignoring the second
- ✅ `flip : (a -> b -> c) -> b -> a -> c` — swap the first two arguments of a binary function
- ✅ `compose : (b -> c) -> (a -> b) -> a -> c` — right-to-left function composition (`g . f`)
- ✅ `pipe : (a -> b) -> (b -> c) -> a -> c` — left-to-right function composition
- ✅ `apply : (a -> b) -> a -> b` — function application as a function
- ✅ `fst : (a, b) -> a` — first component of a pair
- ✅ `snd : (a, b) -> b` — second component of a pair
- ✅ `not : Bool -> Bool` — logical negation
- ✅ `and : Bool -> Bool -> Bool` — logical AND (strict; both args evaluated)
- ✅ `or : Bool -> Bool -> Bool` — logical OR (strict)
- ✅ `xor : Bool -> Bool -> Bool` — logical XOR
- ✅ `otherwise : Bool` — alias for `True`, idiomatic in guard chains
- ⏳ `panic : String -> a` — already an extern in `runtime.mdk`; no stdlib re-export needed

**FP combinators (P1, 2026-07-02 — see `FP-STDLIB-DESIGN.md` §0.5 for the naming rationale):**

- ✅ `on : (b -> b -> c) -> (a -> b) -> a -> a -> c` — `on cmp f x y == cmp (f x) (f y)`
- ✅ `curry : ((a, b) -> c) -> a -> b -> c` — turn a tuple-taking function into a 2-arg function
- ✅ `uncurry : (a -> b -> c) -> (a, b) -> c` — turn a 2-arg function into a tuple-taking function
- ✅ `discard : Mappable f => f a -> f Unit` — run for structure/effect, discard the result (Haskell `void`)
- ✅ `replaceWith : Mappable f => f a -> b -> f b` — replace every element with a constant (Haskell `$>`)
- ✅ `map2 : Applicative f => (a -> b -> c) -> f a -> f b -> f c` — lift a 2-arg function over two containers (Elm-style; Haskell `liftA2`)
- ✅ `map3 : Applicative f => (a -> b -> c -> d) -> f a -> f b -> f c -> f d` — lift a 3-arg function over three containers (Haskell `liftA3`)
- ✅ `foldThen : Thenable m => (b -> a -> m b) -> b -> List a -> m b` — effectful left fold (Haskell `foldM`); `-Then` house convention
- ✅ `repeatThen : Thenable m => Int -> m a -> m (List a)` — run an effectful action N times, collecting results (Haskell `replicateM`)
- ✅ `filterThen : Thenable m => (a -> m Bool) -> List a -> m (List a)` — effectful filter (Haskell `filterM`)
- ✅ `forEach : Thenable m => List a -> (a -> m Unit) -> m Unit` — run an action per element, discard results (Haskell `for_`)
- ✅ `runEach : Thenable m => List (m a) -> m Unit` — run a list of ready actions, discard results (Haskell `sequence_`)
- ✅ `guard : Alternative f => Bool -> f Unit` — fail the computation when the condition is false

(`filter` is no longer a List-specific standalone here — it is a `Filterable`
method; see the interface above and `impl Filterable List` below.)

### Impls already provided

- ✅ `impl Eq (List a) requires Eq a`
- ✅ `impl Monoid (List a)`
- ✅ `impl Monoid String`
- ✅ `impl Mappable List`, `impl Mappable Option`, `impl Mappable (Result e)` (default)
- ✅ `impl Applicative List`, `impl Applicative Option`, `impl Applicative (Result e)`
- ✅ `impl Thenable List`, `impl Thenable Option`, `impl Thenable (Result e)`
- ✅ `impl Foldable List`
- ✅ `impl Filterable List`

### Impls still missing (track here as `core` grows)

- ✅ `impl Semigroup (List a)`, `impl Semigroup String` (explicit impls in `core.mdk`)
- ✅ `impl Eq` for `Int`, `Float`, `Bool`, `Char`, `String`, `Unit`, `Option a`, `Result e a`, tuples
- ✅ `impl Ord` for `Int`, `Float`, `Char`, `String`, `Option a`, `Result e a`, tuples, `List a`
- ✅ `impl Debug` for every built-in type and for `Option`, `Result`, `List`, tuples (and `Array`, in `array.mdk`)
- ✅ `impl Num Int`, `impl Num Float`
- ✅ `impl Bounded Int`, `impl Bounded Char` (Phase 93) — backed by native bound externs (`intMinBound`/`intMaxBound` = the 63-bit OCaml `int` limits; `charMinBound`/`charMaxBound` = U+0000 / U+10FFFF). The bounds dispatch by result type via Phase 96's nullary return-position fix.
- ✅ `impl Foldable Option`, `impl Foldable (Result e)`, `impl Foldable Array`
- ✅ `impl Mappable Array`

---

## Module 2 — `list` ✅ implemented

Depends on `core`. Functions already covered by a typeclass instance do not need
implementations here — use the dispatch path instead:

- `impl Foldable List` / `impl Mappable List`: fold, foldRight, map, any, all,
  find, count, elem, sum, product, isEmpty, length
- `impl Filterable List`: filter, filterMap
- `impl Monoid List`: empty
- `impl Thenable List`: concat / flatten (via `flat`), concatMap (via `flatMap`)

### Construction

- ✅ `singleton : a -> List a` — one-element list
- ✅ `range : Int -> Int -> List Int` — `range lo hi` produces `[lo, lo+1, …, hi-1]` (exclusive upper bound)
- ✅ `rangeStep : Int -> Int -> Int -> List Int` — `rangeStep lo hi step`; sign of `step` must match `hi - lo` or result is empty
- ✅ `replicate : Int -> a -> List a` — list containing the value repeated N times
- ✅ `iterate : Int -> (a -> a) -> a -> List a` — `[seed, f seed, f (f seed), …]` of length N
- ✅ `unfold : (b -> Option (a, b)) -> b -> List a` — generate a list from a seed; stops when the generator returns `None`

### Observation

- ✅ `head : List a -> Option a` — first element, or `None` if empty
- ✅ `tail : List a -> Option (List a)` — all elements after the first, or `None` if empty
- ✅ `last : List a -> Option a` — final element, or `None` if empty
- ✅ `init : List a -> Option (List a)` — all elements except the last, or `None` if empty
- ✅ `get : Int -> List a -> Option a` — element at index (0-based), or `None` if out of range

### Transformation

- ✅ `reverse : List a -> List a` — list in opposite order
- ✅ `intersperse : a -> List a -> List a` — insert separator between every pair of elements
- ✅ `intercalate : List a -> List (List a) -> List a` — `flat` (flatten) after `intersperse`
- ✅ `transpose : List (List a) -> List (List a)` — turn rows into columns
- ✅ `subsequences : List a -> List (List a)` — every subset of the list (2^N of them)
- ✅ `permutations : List a -> List (List a)` — every ordering of the list (N! of them)

### Folds and scans

- ✅ `scanLeft : (b -> a -> b) -> b -> List a -> List b` — like `fold` but keeps every intermediate accumulator
- ✅ `scanRight : (a -> b -> b) -> b -> List a -> List b` — right-associated `scanLeft`
- ✅ `maximum` / `minimum` — **generic in `core`** now (`(Foldable t, Ord a) => t a -> Option a`); they work on `List` directly, so no List-specific copy is needed here

### Search

- ✅ `notElem` — also **generic in `core`** (`(Foldable t, Eq a) => a -> t a -> Bool`)
- ✅ `findIndex : (a -> Bool) -> List a -> Option Int` — index of the first match, or `None`
- ✅ `findIndices : (a -> Bool) -> List a -> List Int` — all indices that match
- ✅ `elemIndex : Eq a => a -> List a -> Option Int` — index of the first occurrence of the value

### Sublists

- ✅ `take : Int -> List a -> List a` — first N elements (fewer if the list is shorter)
- ✅ `drop : Int -> List a -> List a` — everything after the first N elements
- ✅ `takeWhile : (a -> Bool) -> List a -> List a` — prefix where the predicate holds
- ✅ `dropWhile : (a -> Bool) -> List a -> List a` — drop the leading run where the predicate holds
- ✅ `span : (a -> Bool) -> List a -> (List a, List a)` — `(takeWhile p xs, dropWhile p xs)`
- ✅ `break : (a -> Bool) -> List a -> (List a, List a)` — `span (not . p) xs`
- ✅ `splitAt : Int -> List a -> (List a, List a)` — `(take n xs, drop n xs)`
- ✅ `slice : Int -> Int -> List a -> List a` — `slice lo hi xs` is `drop lo (take hi xs)`
- ✅ `chunks : Int -> List a -> List (List a)` — split into consecutive groups of N (last group may be shorter)

### Zipping and combining

- ✅ `zip : List a -> List b -> List (a, b)` — pair up elements; result length is the shorter input (`list.mdk:494`)
- ✅ `zip3 : List a -> List b -> List c -> List (a, b, c)` — triple-up version of `zip` (`list.mdk:507`)
- ✅ `zipWith : (a -> b -> <e> c) -> List a -> List b -> <e> List c` — generalised `zip`; result length is the shorter input (`list.mdk:521`)
- ✅ `unzip : List (a, b) -> (List a, List b)` — split a list of pairs into two parallel lists (`list.mdk:533`)

### Effectful traversal

- ✅ `traverse : Thenable m => (a -> <e> m b) -> List a -> <e> m (List b)` — map an effectful function over a list, collecting results inside the effect; short-circuits on the first `Err`/`None` (`list.mdk`)
- ✅ `sequence : Thenable m => List (m a) -> m (List a)` — flip a list of effects into an effect of a list (`sequence == traverse identity`) (`list.mdk`)

### Option/Result-list combinators (P1, 2026-07-02)

- ✅ `somes : List (Option a) -> List a` — keep only the `Some` payloads, dropping `None`s (Haskell `catOptions`)
- ✅ `oks : List (Result e a) -> List a` — keep only the `Ok` payloads, dropping `Err`s (Haskell `rights`)
- ✅ `errs : List (Result e a) -> List e` — keep only the `Err` payloads, dropping `Ok`s (Haskell `lefts`)
- ✅ `partitionResults : List (Result e a) -> (List e, List a)` — split into `(errs, oks)` in one pass

### Sorting

- ✅ `sort : Ord a => List a -> List a` — ascending sort (stable merge sort)
- ✅ `sortBy : (a -> a -> Ordering) -> List a -> List a` — custom comparator
- ✅ `sortOn : Ord b => (a -> b) -> List a -> List a` — sort by a derived key, computing the key **once per element** (decorate–sort–undecorate). (Historically used the recompute-per-comparison form to dodge a `sortBy` generalisation bug; that bug was fixed in Phase 90, so both `List.sortOn` and `array.sortOn` now decorate.)
- ✅ `nub : Eq a => List a -> List a` — remove duplicates, keeping the first occurrence; O(N²) baseline
- ✅ `nubBy : (a -> a -> Bool) -> List a -> List a` — `nub` with a custom equality test

### Grouping

- ✅ `group : Eq a => List a -> List (List a)` — group runs of equal adjacent elements
- ✅ `groupBy : (a -> a -> Bool) -> List a -> List (List a)` — `group` with a custom equivalence
- ✅ `partition : (a -> Bool) -> List a -> (List a, List a)` — `(filter p xs, filter (not . p) xs)` in one pass
- ✅ `tally : Eq a => List a -> List (a, Int)` — element → count, in first-seen (insertion-stable) order

### Instances

- ✅ `impl Eq (List a)` where `Eq a` — *(in `core.mdk`)*
- ✅ `impl Ord (List a)` where `Ord a` — lexicographic ordering *(in `core.mdk`, beside `Eq`)*
- ✅ `impl Debug (List a)` where `Debug a` — bracketed comma-separated form *(in `core.mdk`)*
- ✅ `impl Mappable List` — *(in `core.mdk`)*
- ✅ `impl Foldable List` — *(in `core.mdk`)*
- ✅ `impl Filterable List` — *(in `core.mdk`)*
- ✅ `impl Applicative List` — *(in `core.mdk`)*
- ✅ `impl Thenable List` — *(in `core.mdk`)*
- ✅ `impl Semigroup (List a)` — concatenation via `++`; lives in `core.mdk` (not `list.mdk` — cosmetic only, works)
- ✅ `impl Monoid (List a)` — *(in `core.mdk`)*

---

## Module 3 — `string` ✅ implemented and reviewed (kernel Phase 75; API frozen 2026-06-03)

Depends on `core`. Also provides `Char` utilities. File `stdlib/string.mdk`
currently contains only an `import` line (the `Debug String`/`Debug Char` impls).

**Design — locked 2026-05-31.** Mirrors the array layering (Module 4): a tiny
host-backed kernel in `stdlib/runtime.mdk`, with the bulk of this module
written in Medaka on top.

- **Representation.** `String` is an immutable sequence of **Unicode scalar
  values (codepoints)**, UTF-8 backed. `Char` is one codepoint (`VChar` already
  holds a UTF-8 string, not an OCaml `char`). `length`, indexing, `slice`,
  `take`/`drop` are all **codepoint**-based — never byte, never grapheme.
  - *Done (Phase 75):* the `s.[lo..hi]` bracket slice is now **codepoint**-based
    (was byte-based `String.sub`). Single-codepoint `s.[i]` indexing is not yet
    supported (`EIndex` rejects strings at typecheck) — deferred.
- **Kernel shape.** Minimal bridge to `Array Char` (the analog of
  `arrayFromList`/`arrayMakeWith`) plus a few codepoint-aware perf externs that
  avoid an `Array Char` round-trip on hot paths.
- **Unicode.** Classification and case folding are **host-backed now** — they
  need the Unicode character database, which OCaml's stdlib lacks. Implement via
  [`uucp`](https://erratique.ch/software/uucp) (add to `lib/dune`). The contract
  (full Unicode) is part of the runtime and every self-hosting host must re-provide
  it, exactly like `floatToString`. ASCII-only ops (`isDigit`, `digitToInt`,
  hex) stay in Medaka — `'0'..'9'`/`'a'..'f'` is exact and needs no tables.

### Runtime kernel (extern, in `stdlib/runtime.mdk`)

The irreducible trusted surface. Everything in the sections below that is *not*
listed here is written in Medaka over this kernel + the `Array` stdlib.

Bridge to `Array Char`:

- ✅ `stringToChars : String -> Array Char` — decode to codepoints
- ✅ `stringFromChars : Array Char -> String` — encode

Char ↔ codepoint (UTF-8 decode/encode can't be expressed in Medaka):

- ✅ `charCode : Char -> Int` — scalar value
- ✅ `charFromCode : Int -> Option Char` — `None` on surrogate / `> 0x10FFFF`

Codepoint-aware perf externs (avoid an `Array Char` round-trip):

- ✅ `stringLength : String -> Int` — single-pass codepoint count
- ✅ `stringSlice : Int -> Int -> String -> String` — half-open `[lo, hi)`, clamps
- ✅ `stringConcat : List String -> String` — buffered; backs `concat`/`join`
- ✅ `stringIndexOf : String -> String -> Option Int` — host byte search → first codepoint index; backs `indexOf`/`contains`/`split`/`replace*`
- ✅ `stringCompare : String -> String -> Ordering` — UTF-8 byte order == codepoint order

Number parsing/formatting (correct float work is infeasible in Medaka):

- ✅ `stringToFloat : String -> Option Float`
- ✅ `floatToString : Float -> String` — already an extern
- ✅ `intToString : Int -> String` — already an extern

Unicode classification & case folding (host Unicode tables via `uucp`):

- ✅ `charIsAlpha : Char -> Bool`
- ✅ `charIsSpace : Char -> Bool`
- ✅ `charIsUpper : Char -> Bool`
- ✅ `charIsLower : Char -> Bool`
- ✅ `charIsPunct : Char -> Bool`
- ✅ `charToUpper : Char -> Char` — identity for non-letters **and** where the
  Unicode mapping would expand 1→N (e.g. `'ß'` is unchanged; it can't become
  `SS` in a single `Char`)
- ✅ `charToLower : Char -> Char` — same identity-on-expansion caveat
- ✅ `stringToUpper : String -> String` — full-fidelity uppercasing, expands
  1→N (`"Straße" → "STRASSE"`). Why a separate extern: `charToUpper` can't
  express expansion, so `String.toUpper` is **not** `map charToUpper`.
- ✅ `stringToLower : String -> String` — full-fidelity lowercasing

Already present and reused: `charToStr` (= `fromChar`), `showStringLit`,
`showCharLit`, `randomChar`.

### Char operations

*All Medaka, over the kernel above.*



- ✅ `isDigit : Char -> Bool` — `'0'..'9'` (ASCII, via `charCode`)
- ✅ `isAlpha : Char -> Bool` — wraps `charIsAlpha`
- ✅ `isAlphaNum : Char -> Bool` — `isAlpha c || isDigit c`
- ✅ `isSpace : Char -> Bool` — wraps `charIsSpace`
- ✅ `isUpper : Char -> Bool` — wraps `charIsUpper`
- ✅ `isLower : Char -> Bool` — wraps `charIsLower`
- ✅ `isPunct : Char -> Bool` — wraps `charIsPunct`
- ⛔ `toUpper`/`toLower` for a single `Char` — **intentionally not provided**: the `String`-level `toUpper`/`toLower` (full Unicode) own those unqualified names. For Char, call the kernel externs `charToUpper`/`charToLower` directly (they return `Char`, so they're identity on 1→N expansions like `'ß'`)
- ✅ `digitToInt : Char -> Option Int` — `'0'..'9' → Some 0..9`, `'a'..'f' → Some 10..15`, else `None` (ASCII, via `charCode`)
- ✅ `intToDigit : Int -> Option Char` — inverse of `digitToInt` for `0..15` (via `charFromCode`)
- ✅ `charCode : Char -> Int` — **kernel extern**
- ✅ `charFromCode : Int -> Option Char` — **kernel extern**

### Conversion

*All Medaka, over the kernel above, except where noted.*

- ✅ `fromChar : Char -> String` — one-character string (= existing `charToStr`)
- ✅ `toChars : String -> Array Char` — codepoints (returns the native `Array Char`; call `Array.toList` for a list)
- ✅ `fromChars : List Char -> String` — inverse of `toChars` (`stringFromChars ∘ arrayFromList`)
- ✅ `toInt : String -> Option Int` — parse a decimal integer, leading sign allowed; `None` on any failure
- ✅ `toFloat : String -> Option Float` — wraps `stringToFloat`; `None` on any failure
- ⛔ `fromInt : Int -> String` — **intentionally not provided**: would collide with `Num.fromInt`; use the global `intToString` (already an extern)
- ⛔ `fromFloat : Float -> String` — **intentionally not provided** for symmetry with `fromInt`; use the global `floatToString`

### Inspection

- ⛔ `length`/`isEmpty` — **intentionally not provided**: would clash with the `Foldable` methods of the same name. Use the global `stringLength`, or `s == ""`. A `Sized`/`HasLength` interface is the right lever if this is ever revisited, but is out of scope for now
- ✅ `startsWith : String -> String -> Bool` — `startsWith prefix s` — true when `s` begins with `prefix`
- ✅ `endsWith : String -> String -> Bool` — `endsWith suffix s` — true when `s` ends with `suffix`
- ✅ `contains : String -> String -> Bool` — `contains needle haystack`
- ✅ `indexOf : String -> String -> Option Int` — first index of `needle` in `haystack`, or `None`
- ✅ `lastIndexOf : String -> String -> Option Int` — last index of `needle` in `haystack`
- ✅ `countOccurrences : String -> String -> Int` — number of non-overlapping occurrences (renamed from `count` in Phase 117 to avoid shadowing the prelude `count`)

### Transformation

- ✅ `prepend : String -> String -> String` — prepend a prefix; `flip` of `Semigroup.append`
- ✅ `concat : List String -> String` — concatenate all strings in order
- ✅ `join : String -> List String -> String` — `join sep parts` — concatenate with `sep` between each pair
- ✅ `repeat : Int -> String -> String` — repeat the string N times
- ✅ `reverse : String -> String` — codepoint-reversed string
- ✅ `trim : String -> String` — strip whitespace from both ends
- ✅ `trimLeft : String -> String` — strip leading whitespace
- ✅ `trimRight : String -> String` — strip trailing whitespace
- ✅ `toUpper : String -> String` — wraps `stringToUpper` (full Unicode, expands 1→N; *not* `map charToUpper`)
- ✅ `toLower : String -> String` — wraps `stringToLower`
- ✅ `capitalize : String -> String` — uppercase first char, leave the rest alone
- ✅ `replace : String -> String -> String -> String` — `replace old new s` — replace the first occurrence
- ✅ `replaceAll : String -> String -> String -> String` — replace every non-overlapping occurrence

### Slicing and splitting

- ✅ `slice : Int -> Int -> String -> String` — `slice lo hi s` — substring `[lo, hi)`
- ✅ `take : Int -> String -> String` — first N codepoints (fewer if shorter)
- ✅ `drop : Int -> String -> String` — drop the first N codepoints
- ✅ `split : String -> String -> List String` — `split sep s` — split on `sep`, dropping the separator
- ✅ `splitAt : Int -> String -> (String, String)` — `(take n s, drop n s)`
- ✅ `lines : String -> List String` — split on `\n` (also accept `\r\n`)
- ✅ `words : String -> List String` — split on runs of whitespace, drop empties
- ✅ `unlines : List String -> String` — join with `\n` and append a trailing newline
- ✅ `unwords : List String -> String` — join with single spaces

### Padding

- ✅ `padLeft : Int -> Char -> String -> String` — left-pad with the given char up to total length N
- ✅ `padRight : Int -> Char -> String -> String` — right-pad
- ✅ `center : Int -> Char -> String -> String` — center the string, splitting padding evenly (extra goes on the right)

### Instances

- ✅ `impl Eq String` — *(in `core.mdk`)*
- ✅ `impl Ord String` — lexicographic codepoint order *(in `core.mdk`)*
- ✅ `impl Debug String` — quoted, escaped (in `string.mdk`, via `showStringLit`)
- ✅ `impl Semigroup String` — in `core.mdk` (alongside `Monoid String`)
- ✅ `impl Eq Char` — *(in `core.mdk`)*
- ✅ `impl Ord Char` — codepoint order *(in `core.mdk`)*
- ✅ `impl Debug Char` — quoted (in `string.mdk`, via `showCharLit`)

---

## Module 4 — `array` ✅ implemented

Depends on `core`. Arrays are fixed-size and support O(1) random access.
The runtime already exposes `VArray`, the `[|...|]` literal, range
literals (`[|lo..hi|]`/`[|lo..=hi|]`), and panicking bracket indexing
(`arr[i]`).

**Design layering** (see `stdlib/array.mdk` for the full rationale):

1. **Kernel** of OCaml-backed primitives in `stdlib/runtime.mdk`
   (`arrayLength`, `arrayMake`, `arrayMakeWith`, `arrayGetUnsafe`,
   `arraySetUnsafe`, `arrayCopy`, `arrayBlit`, `arrayFill`,
   `arrayFromList`).  **Note (2026-06-07, `→MEDAKA` migration):** `sortBy`/
   `sortInPlaceBy`/`sort` no longer call the `arraySortBy`/`arraySortInPlaceBy`
   externs — they route through a pure-Medaka top-down mergesort (`mergeSortBy`)
   in `array.mdk`, so the FFI-callback coupling is gone for the LLVM backend. The
   `arraySortBy`/`arraySortInPlaceBy` externs are now **dead in the stdlib** (still
   declared in `runtime.mdk`/`eval.ml` for the interpreter). A pure `makeWith` also
   exists, but `array.mdk` internals (incl. `mergeSortBy`) still call the
   `arrayMakeWith` extern — see PLAN.md "Native backend" for the remaining cutover.
2. **Pure stdlib** (Medaka) built on the kernel via `arrayMakeWith`
   and tail-recursive helpers.
3. **Effectful stdlib** (Medaka) that mutates in place (untracked — no effect row).
4. **Typeclass impls**: `Mappable`, `Foldable`, `Filterable`, `Semigroup`,
   `Monoid`, `Eq`.  Deliberately *not* `Applicative` / `Thenable` — the natural
   definitions encode cartesian-style allocation that's a performance
   trap on bulk data.  `Debug` is blocked on a resolver gap (see below).

**Resolver gap (closed).**  Previously, interface methods whose only
body in core was a default on the interface itself (`max`, `min`,
`debug`) were not seeded into `prelude_values` and resolved as unbound
in user files.  Fixed in `lib/resolve.ml` by extending
`prelude_values` to include `DInterface` method names — so this
module can now use `max`/`min` directly.  `impl Debug (Array a)`
remains deferred, but the blocker is now narrower: `debug` resolves;
what's missing is the actual `impl Debug Int`/`Debug Float`/etc. in
core that the recursive call would dispatch through.

**Multi-file loader (closed).**  `typecheck_module` previously
re-prepended the prelude per module, and `te_impls` leaked the
prelude's default impls into downstream modules, surfacing as a
spurious `Multiple default impls of Mappable for Result a` when any
non-leaf module defined an impl.  Fixed in `lib/typecheck.ml` by
filtering `impl_seeded` entries out of `te_impls`.

**Constraint + effect signatures (closed).**  Found and fixed during
this work: `declared_effects` in `lib/typecheck.ml` didn't unwrap
`TyConstrained`, so any signature combining a constraint with an
effect — like `sortInPlace : Ord a => Array a -> <Mut> Unit` — was
typechecked as if it had no declared effect, then errored on the
`<Mut>` produced by the body.  Added the missing match case.

### Construction

- ✅ `make : Int -> a -> Array a` — array of length N filled with the value
- ✅ `makeWith : Int -> (Int -> a) -> Array a` — generate element at each index via the function
- ✅ `fromList : List a -> Array a` — copy list contents into a new array
- ✅ `singleton : a -> Array a` — one-element array
- ✅ `empty : Array a` — the empty array
- ✅ `range : Int -> Int -> Array Int` — `[lo, hi)` as an array
- ✅ `replicate : Int -> a -> Array a` — alias for `make`; included for symmetry with `List`
- ✅ `copy : Array a -> Array a` — fresh array with the same contents (useful before mutation)

### Observation

- 🟡 `length` — provided by `impl Foldable Array`, not re-exported as standalone (would collide with the polymorphic `Foldable.length`)
- 🟡 `isEmpty` — same; via `Foldable Array`
- ✅ `get : Int -> Array a -> Option a` — bounds-checked indexing
- *Not implemented as a separate name:* `getUnsafe` — use `arrayGetUnsafe` (the kernel primitive) directly, or the panicking `arr[i]` operator
- ✅ `first : Array a -> Option a` — element at index 0, or `None`
- ✅ `last : Array a -> Option a` — final element, or `None`
- 🟡 `toList` — via `Foldable Array`

### Transformation (pure — return new arrays)

- 🟡 `map` — via `impl Mappable Array`
- 🟡 `filter`, `filterMap` — via `impl Filterable Array` (no longer a standalone `filterA`; `filter`/`filterMap` are `Filterable` methods now)
- ✅ `reverse : Array a -> Array a` — fresh array in opposite order
- ✅ `slice : Int -> Int -> Array a -> Array a` — `[lo, hi)`; clamps to bounds, does not panic (use `arr[lo..hi]` for the panicking variant)
- ✅ `take : Int -> Array a -> Array a` — first N elements
- ✅ `drop : Int -> Array a -> Array a` — everything after the first N
- 🟡 `append` — via `impl Semigroup (Array a)` (also the `++` operator); no separate standalone
- ✅ `concat : Array (Array a) -> Array a` — flatten one level
- ✅ `zip : Array a -> Array b -> Array (a, b)` — pair up by index; result length is the shorter input
- ✅ `zipWith : (a -> b -> c) -> Array a -> Array b -> Array c` — generalised `zip`
- ✅ `unzip : Array (a, b) -> (Array a, Array b)` — split into two parallel arrays

### Mutation (untracked — modifies in place, no effect row)

- ✅ `set : Int -> a -> Array a -> Unit` — bounds-checked write (panics on OOB)
- ✅ `swap : Int -> Int -> Array a -> Unit`
- ✅ `fill : a -> Array a -> Unit`
- ✅ `sortInPlace : Ord a => Array a -> Unit`
- ✅ `sortInPlaceBy : (a -> a -> <e> Ordering) -> Array a -> <e> Unit`

### Folds and search

- 🟡 `fold`, `foldRight`, `any`, `all` — via `impl Foldable Array` + core helpers
- ✅ `find : (a -> Bool) -> Array a -> Option a` — first match, or `None` (array-specific short-circuiting version)
- ✅ `findIndex : (a -> Bool) -> Array a -> Option Int` — index of the first match
- 🟡 `elem`, `sum`, `product`, `maximum`, `minimum` — **no longer array-specific**: the generic `Foldable` versions in `core` dispatch over `impl Foldable Array` (same tight loop), so the array copies were removed as redundant

### Sorting (pure)

- ✅ `sort : Ord a => Array a -> Array a` — fresh sorted copy (pure-Medaka `mergeSortBy`; see note above re: `arraySortBy` migration)
- ✅ `sortBy : (a -> a -> Ordering) -> Array a -> Array a`
- ✅ `sortOn : Ord b => (a -> b) -> Array a -> Array a`

### Instances

- ✅ `impl Eq (Array a)` where `Eq a` — element-wise
- ✅ `impl Debug (Array a)` where `Debug a` — bracketed `[|1, 2, 3|]` form (now unblocked: `Debug Int`/`Float`/… landed in core)
- ✅ `impl Mappable Array`
- ✅ `impl Foldable Array`
- ✅ `impl Filterable Array`
- ✅ `impl Semigroup (Array a)` — array concatenation
- ✅ `impl Monoid (Array a)` — identity is `[||]`
- **Skipped:** `Applicative Array`, `Thenable Array` — semantically definable but encourage O(N·M) allocation; arrays should drop into `List` for monadic non-determinism and convert back at the boundary

---

## Module 5 — `map` / `set` (ordered)

Persistent **ordered** containers, keyed by `Ord`. Both implemented:
`map` (`stdlib/map.mdk`) and `set` (`stdlib/set.mdk`) — Module 5 complete.

**Representation.** `Map k v` is a **weight-balanced binary search tree** (the
Adams / Haskell `Data.Map` scheme): `data Map k v = Tip | Bin Int k v (Map k v)
(Map k v)`, where the cached `Int` is the subtree size. A single smart
constructor `balance` (`delta = 3`, `ratio = 2`) keeps neither subtree more than
3× its sibling, so every operation is O(log n) and `size` is O(1). The structure
is persistent — operations return a fresh map sharing all untouched subtrees.
Verified: 1000 ascending inserts (the BST worst case) give depth 15 (≈ the
1.44·log₂n bound), and a `wellFormed` invariant checker (BST order + size caches
+ balance bound) holds across 700 randomized insert/delete/union property cases.

**Name claim (compiler).** `Map` was a reserved primitive type name in
`lib/resolve.ml` (a placeholder backing the stubbed `Map { k => v }` literal
sugar). It is now removed from `primitive_types` so `data Map k v` in
`stdlib/map.mdk` is the canonical definition — mirroring how `Option`/`Result`/
`Ordering` live in `core.mdk`.

**Literal sugar (Phase 108 ✅).** `Map { 1 => 10, 2 => 20 }` now builds a real
map. It lowers (in `desugar`) to `fromEntries [(1,10),(2,20)]` pinned at the
`Map` type, where `fromEntries` is a core interface `FromEntries c e` dispatched
on the result type; `impl FromEntries (Map k v) (k, v) requires Ord k` lives in
`map.mdk`. The name is **authoritative** (`Banana { … }` → `Unknown type`), and
the literal requires the container's module imported (for the impl). `Set { … }`
will work once `set.mdk` adds the matching impl. See PLAN.md Phase 108.

### `map` ✅ implemented (`stdlib/map.mdk`)

- **Construction:** `empty` (= `Tip`; standalone, *not* a `Monoid` method — see
  below), `singleton`, `fromList` (last write wins on duplicate keys)
- **Query:** `size` (O(1)), `isEmpty`, `lookup`, `member`, `findWithDefault`
- **Insertion:** `insert`, `insertWith` (`f new old`), `adjust`
- **Deletion:** `delete`, `deleteMin`, `deleteMax`
- **Min/max:** `minView`, `maxView`, `lookupMin`, `lookupMax`
- **Folds / traversal (ascending key order):** `foldrWithKey`, `foldlWithKey`,
  `toList` (assoc pairs), `keys`, `elems`, `mapWithKey`, `filterWithKey`
- **Combining:** `union` (left-biased), `unionWith`, `difference`,
  `intersectionWith`
- **Invariant checker:** `wellFormed` (exported; backs the property tests)
- **Instances:** ✅ `Mappable (Map k)` (over values), `Eq`/`Debug` (via the
  canonical ascending assoc list), `Semigroup (Map k v) requires Ord k`
  (`++` = left-biased `union`)
- **⛔ `Monoid (Map k v)` — intentionally not provided.** `Monoid.empty` is
  nullary, so it dispatches on its *result* type; a return-position dispatch
  can't supply the `Ord k` the instance requires (the Phase 83/84 flat-dict
  limitation — confirmed: even `array`'s `empty` mis-resolves through it). Use
  the standalone `empty` (= `Tip`) as the identity. `Semigroup.append` is fine
  because it dispatches on its first `Map` argument.
- **Naming notes:** `toList` returns assoc pairs (the Map-conventional meaning);
  `Foldable (Map k)` is **not** implemented to avoid hijacking `toList` to mean
  "values" — use `elems`/`keys`/`size` instead. No `filter` (would clash with
  `Filterable.filter`); use `filterWithKey`.

### `set` ✅ implemented (`stdlib/set.mdk`)

A **standalone** weight-balanced element tree (`data Set a = Tip | Bin Int a (Set
a) (Set a)`) — chosen over a `Map a Unit` wrapper to keep the module
self-contained (a wrapper would need qualified imports to dodge map's
identically-named `insert`/`union`/… exports) and drop the per-node `Unit`. The
balancing mirrors map.mdk's; the property tests re-verify it (depth 15 for 1000
ascending inserts).

- **Construction:** `empty` (= `Monoid.empty`/`Tip`), `singleton`, `fromList`
  (drops duplicates)
- **Query:** `size` (O(1)), `member`; `isEmpty`/`length`/`elem`/`toList`/`sum`/
  `maximum`/`any`/`all` via `Foldable Set` (folds over elements, ascending)
- **Insertion / deletion:** `insert`, `delete`, `deleteMin`, `deleteMax`
- **Min/max:** `minView`, `maxView`, `lookupMin`, `lookupMax`
- **Set algebra:** `union`, `intersection`, `difference`, `isSubsetOf`
- **Invariant checker:** `wellFormed` (backs the property tests)
- **Instances:** `Foldable Set`, `Eq`/`Debug` (via the ascending element list),
  `Semigroup` (`++` = `union`), `Monoid` (empty = `Tip`)
- **Literal:** `Set { 1, 2, 3 }` works (Phase 108) via `impl FromEntries (Set a)
  a requires Ord a`.
- **Naming:** unlike `Map` (whose standalone `toList` is shadowed by
  `Foldable.toList`), Set *implements* `Foldable`, so `toList`/`elem`/etc. are the
  Foldable methods and resolve cleanly from user files. No `map`/`filter`
  standalones (would clash with `Mappable`/`Filterable` method names, and `Set`
  is not a lawful `Mappable`); a future element-`map` needs a non-clashing name.

---

## Module 6 — `hash_map` / `hash_set` (mutable, performance)

The performance counterpart to the persistent ordered Module 5: O(1)-average
**mutable** hash containers. Updates mutate in place (untracked — no effect row)
rather than returning a fresh structure. Reach for `Map`/`Set` when you want
persistence/ordering; reach for these for raw speed with a single owner.

**Representation.** Separate chaining: each bucket is a `List` of entries, in an
`Array` held by a `Ref` (so it can be swapped on resize), plus a `Ref Int` count.
Doubles capacity past load factor 0.75. Hashing is the global `hash` extern
(structural, non-negative), which **must agree with the key/element's `Eq`** — it
holds for all structural `Eq` impls (the built-ins); a custom non-structural `Eq`
would break it. Iteration order is unspecified.

### `hash_map` ✅ implemented (`stdlib/hash_map.mdk`)

- **Construction:** `new : Unit -> HashMap k v` (a *function*, so each call
  allocates its own table), `fromList : Eq k => List (k, v) -> HashMap k v`.
- **Query (pure):** `size` (O(1)), `isEmpty`, `get`, `member`, `findWithDefault`.
- **Mutation (untracked, no effect row):** `insert` (overwrites), `delete`.
- **Iteration (pure, unspecified order):** `entries` (the pairs), `toList`
  (alias of `entries`), `keys`, `values`.
- **Instances:** `Eq` (order-independent — same entries), `Debug` (`fromList […]`
  in hash order). *Not* `Foldable` (its `toList` means pairs, which would clash
  with `Foldable.toList`'s element meaning — hence the internal `entries` name).
- 8 doctests.

### `hash_set` ✅ implemented (`stdlib/hash_set.mdk`)

Standalone mutable element tree (mirrors `hash_map` minus values; not a wrapper
over `HashMap a Unit`, same reasoning as `set` over `Map a Unit`).

- **Construction:** `new`, `fromList`.
- **Query (pure):** `size`, `member`; `toList`/`length`/`elem`/`any`/`sum`/… via
  `Foldable HashSet` (a set's elements *are* its `toList`, so no clash — unlike
  `hash_map`).
- **Mutation (untracked, no effect row):** `insert`, `delete`.
- **Instances:** `Foldable`, `Eq` (order-independent), `Debug`.
- 7 doctests.

### `mut_array` ✅ implemented — see Module 8 below

A growable mutable array (vector) over the fixed-size `Array` — `stdlib/mut_array.mdk`. See **Module 8** for the full API. (This `⏳ unstarted` note was stale; corrected 2026-06-18.)

### Compiler notes

- `hash : a -> Int` is the `Hashable` typeclass method; the five primitive impls
  call SPECIFIED per-type hasher externs (`hashInt`/`hashString`/`hashChar`/
  `hashBool`/`hashFloat`, runtime.mdk + eval.ml + runtime/medaka_rt.c) — byte-
  identical oracle/native, non-negative `[0, 2^30)`. Replaced the old structural
  `__hashRaw` (`Hashtbl.hash`), which the type-erased native runtime can't run.
- Removed `"HashMap"`/`"HashSet"` from `resolve.ml`'s `primitive_types` (reserved
  placeholders), mirroring the `Map`/`Set` removals.
- Surfaced two language gaps (both now fixed): **Phase 118** (`if`/`else` branches
  can't be multi-statement blocks — ✅ DONE 2026-06-03) and **Phase 119** (false-positive
  non-exhaustiveness for 3+-arg list-matching functions — ✅ DONE 2026-06-03). The
  workarounds in these modules remain valid code but are no longer required by the language.

---

## Module 7 — `io` ✅ implemented

Files, standard streams, environment, and process I/O. The irreducible host
primitives are `extern`s in `runtime.mdk` (so they are **global**, no import) —
see the Module 0 catalog. `stdlib/io.mdk` adds the ergonomic layer on top.

**Externs (global, in `runtime.mdk`):** `args`, `getEnv`, `fileExists`,
`appendFile`, `listDir`, `ePutStr`/`ePutStrLn`, `readLineOpt`, `readAll` — plus
the pre-existing `readFile`/`writeFile`/`readLine`/`exit`/`putStr`/`putStrLn`.
Convention: file ops return `Result String _` (host message in `Err`); `getEnv`
returns `Option`. No IO monad — an action runs when evaluated, so you can
`match readFile path` directly. The `args` extern is the program's own args
(`medaka run FILE a b c` → `["a", "b", "c"]`), wired in `bin/main.ml`.

**`io.mdk` (Medaka ergonomics):**

- `eprint` / `eprintln : Display a => a -> <IO> Unit` — stderr analogs of the
  prelude's `print`/`println` (render via `Display`).
- `readLines : String -> <IO> (Result String (List String))` — read a file split
  into lines (drops a trailing `\r` and the final empty line).
- `getEnvOr : String -> String -> <IO> String` — env var or a fallback.

**Note:** `readLines` splits lines via the global `string*` kernel externs rather
than `import string.{lines}`. `stdlib/string.mdk` is importable as of Phase 117,
but `string.lines` keeps the final empty line a trailing newline produces while
`readLines` drops it, so the local splitter stays. **Not yet provided:**
stdin-line iteration helpers, `withFile`-style bracketing, `removeFile`/`rename`
— add when needed.
- 23 doctests + 8 props.

---

## Module 8 — `mut_array` ✅ implemented

A **growable mutable array** (dynamic array / vector) — `stdlib/mut_array.mdk`.
The counterpart to the fixed-size `Array` (Module 4): `MutArray a` is backed by
an `Array a` with spare capacity, so `push` is **amortized O(1)** (the backing
doubles when full, the same resize trick as the Module 6 hash tables).

**Representation.** `data MutArray a = MutArray (Ref (Array a)) (Ref Int)` —
`backing.value` is the capacity-sized store, `len.value` the live count
(`0 <= len <= capacity`). Slots `[len, capacity)` are scratch (never read). The
type is declared in the module and registered via the normal `DData` pipeline,
so it is **not** in `resolve.ml`'s `primitive_types` (mirrors `Map`/`Set`).

**No dummy fill needed.** `new ()` starts at capacity 0 and allocates on the
first `push`, using the pushed element as the grow-fill — so constructing an
empty vector needs no default value of `a`.

- ✅ Construction: `new : Unit -> MutArray a`, `fromList`, `fromArray` (copies)
- ✅ Observation (pure): `capacity`, `get` (bounds-checked `Option`), `first`,
  `last`; `length`/`isEmpty`/`toList` via `Foldable`
- ✅ Conversion: `toArray` (snapshot of the live range into a fresh `Array`)
- ✅ Mutation (untracked, no effect row): `push` (amortized O(1), doubling), `pop` (returns
  `Option`), `set` (panics OOB), `swap`, `clear` (keeps capacity), `mapInPlace`
- ✅ Instances: `Foldable MutArray` (index-based folds, never allocates a list),
  `Eq` (element-wise over the live range), `Debug` (`fromList [..]`)
- 11 doctests. **Skipped:** `Mappable` (use `mapInPlace`, or `toList`→`map`);
  growth/shrink heuristics beyond doubling.

**Cross-module dispatch — RESOLVED (verified 2026-06-03).** This note formerly
claimed a "pre-existing, language-level" limitation: that a **generic
`Foldable`-derived function threading a dictionary internally** — `sum`,
`product`, `maximum`, `minimum` — panicked `no matching impl for dispatch` when
its argument's instance came from an *imported* module (while direct method
calls like `length v`/`toList v` worked). **That is no longer true** —
empirically `sum`/`maximum`/`minimum`/`product` over imported `array`,
`mut_array`, `set`, and `hash_set` instances all dispatch correctly on `main`.
The cross-module dict-passing gap was closed by the eval-driver ordering work in
**Phases 125–126** (`eval_modules`/`eval_modules_root_env` thread the full
local∪imports∪global env, so the generic helper's internal dict resolves against
the imported impl). Kept here as a corrected record because the stale claim
would otherwise mislead self-hosting design (cross-module generic dispatch is
exactly what a multi-file compiler does constantly).

---

## Module 9 — `json` ✅ implemented

A from-scratch JSON value type, parser, and serializer — `stdlib/json.mdk`.
Written primarily to **exercise the stdlib**: a recursive ADT, `Array`-backed
storage, `Char`/`String` kernel handling, `Result` error threading, and the
`Eq`/`Debug`/`Display` interfaces. Built **on** the stdlib it exercises —
`list.reverse`, `string.join`/`fromChars`/`isDigit`/`toInt`, plus the global
`array*`/`string*`/`char*` externs (the first stdlib module to import real
siblings). Only genuinely JSON-specific logic (`isWs`, hex/`\u`, escaping, the
parser) is local.

**Value model.** `data Json = JNull | JBool Bool | JInt Int | JFloat Float
| JString String | JArray (Array Json) | JObject (Array (String, Json))`.
- Numbers **split** `JInt`/`JFloat` so `3` round-trips as `3` (not `3.0`); the
  parser classifies int-vs-float by the presence of `.`/`e`.
- Arrays and objects are **`Array`-backed**, not `List` — JSON payloads are often
  large, and a contiguous `Array` gives O(1) indexing and compact storage where a
  cons-list costs O(n) access + per-cell overhead. Objects are an `Array` of
  `(key, value)` pairs (assoc-style, no `Map` dependency), so insertion order is
  preserved and round-trips exactly; key lookup is linear.

**API.**
- ✅ `parse : String -> Result String Json` — recursive descent over an
  `Array Char` with an explicit position, threaded through a `bindP` combinator.
  Builds each level transiently into a `List` then `arrayFromList`s it, so `parse`
  stays **pure** while the stored value is contiguous. Handles
  strings + escapes (`\" \\ \/ \n \t \r \b \f \uXXXX`), int/float numbers with
  exponents, nested arrays/objects, and reports a message on malformed input.
- ✅ `stringify : Json -> String` — compact serialization. Escapes control chars,
  and normalizes `floatToString`'s trailing-dot form (`1000.` → `1000.0`) so
  output is always valid JSON.
- ✅ `jArray`/`jObject` — build from a `List` (stored as `Array`).
- ✅ Accessors: `lookup` (object key), `index` (array element, O(1)), `asString`/
  `asInt`/`asFloat`/`asBool`/`asArray`.
- ✅ Instances: `Eq Json` (hand-rolled element-wise, **positional** object
  equality), `Debug Json` / `Display Json` (both render compact JSON text).
- 12 doctests; nested round-trip identity, escapes, `\u` decoding, floats, and
  error cases validated via a `run` probe.

**Not handled (v1):** strict leading-zero / number-grammar rejection (the
number scan is lenient on input — output is always valid); `Infinity`/`NaN`
floats (not representable in JSON). `\uXXXX` surrogate pairs (astral
codepoints) ARE handled: a valid high/low pair decodes to its astral scalar
value, and a lone (unpaired) surrogate is a parse error, not silent corruption.
**Possible follow-ups:** a pretty-printer (indented output); `ToJson`/`FromJson`
encode/decode interfaces for user types (a strong interface/`deriving` tire-kick).

## Module 10 — `test` ✅ implemented (Phase 127)

`stdlib/test.mdk` — the unit testing library.  Medaka has three complementary
kinds of tests; each covers different ground:

| Kind | Syntax | Best for |
|------|--------|----------|
| **Doctests** | `-- > expr` / `-- result` in comments | Observable pure outputs; inline documentation |
| **Props** | `prop "name" (x : T) = bool_expr` | Universal laws; algebraic invariants; generative testing |
| **Tests** | `test "name" = expectation_expr` | Error / negative paths; non-`Debug`-able results; multi-step or effectful checks; maintainer-only assertions |

To use: `import test.{runTests, expectEqual, expectTrue, …}` in your file,
write `test "…" = …` declarations, then `medaka test your_file.mdk`.

**Exports:** `Expectation` (ADT: `Pass | Fail String`), `pass`, `fail`,
`expectEqual`, `expectNotEqual`, `expectTrue`, `expectFalse`,
`expectLessThan`, `expectGreaterThan`, `expectAll`, `runTests`.

**`runExpectation`** (extern, not re-exported) catches OCaml-level
`Eval_error`/`Impl_no_match` so one crashing test body never silences
the tests that follow — the crash becomes `Fail "message"`.

- 16 doctests (one per assertion function).
- **v2 follow-up (deferred):** conditional auto-import — inject the test
  vocabulary only into files that contain a `test` decl (frictionless, no
  explicit import needed).  Blocked on the `marked_prelude`-coalescing risk
  that is the codebase's most repeated bug source; build it on a tested v1.

---

## Module 11 — `byteparser` ✅ implemented

`stdlib/byteparser.mdk` — a generic **binary parser-combinator** library.  A
`ByteParser a` wraps `(Array Int -> Int -> BResult a)` with explicit position
threading; `Mappable`/`Applicative`/`Thenable` instances let `do`-notation
sequence parsers, and a left-biased, full-backtracking `Alternative`
(`orElse`).  Not auto-prelude — `import byteparser` by bare name.

**Exports:** types `ByteParser`/`BResult` (`BOk`/`BErr`) + `onOk`/`runBP`;
primitives `satisfy`, `anyByte`, `byte`, `eof`, `peek`, `failWith`; combinators
`many`, `some`, `many1`, `sepBy`, `sepBy1`, `optional`, `between`, `choice`,
`chainl1`, `takeBytes`, `takeSlice`; big-endian binary readers `beUint`,
`beSint`, `beFloat64` + **little-endian mirrors `leUint`, `leSint`, `leFloat64`**
(P1, 2026-07-01); entry point `runByteParser`.  33 doctests.  (The `be`/`le`
prefix = big-/little-endian and is semantic; the old `b`-prefixed combinator
names were dropped on promotion.)

---

## Module 12 — `bytebuilder` ✅ implemented

`stdlib/bytebuilder.mdk` — the symmetric **byte-output builder**, inverse of
`byteparser`.  A `Builder` backed by a growable `MutArray Int` accumulates bytes
in amortised-O(1) `push`; `buildArray` freezes the emission-order range into a
fixed `Array Int` (no reverse pass).  Each `emit*` writes in the byte order its
matching `byteparser` decoder expects, so `encode → decode` round-trips exactly.
Not auto-prelude — `import bytebuilder`.

**Exports:** type `Builder`; `newBuilder`; `emitU8`, `emitU16BE`, `emitU24BE`,
`emitU32BE`, `emitBytes`, `emitBeSint` + **little-endian mirrors `emitU16LE`,
`emitU24LE`, `emitU32LE`, `emitLeUint`, `emitLeSint`** (P1, 2026-07-01);
`buildArray`.  60 round-trip doctests + 4 props.

---

## P1 stdlib (2026-07-01) — see [`P1-STDLIB-DESIGN.md`](./P1-STDLIB-DESIGN.md)

The P1 stdlib expansion (batteries the P0 core omits — math, filesystem,
networking, codecs, time, richer bytes) is designed in
[`P1-STDLIB-DESIGN.md`](./P1-STDLIB-DESIGN.md) with a P1/P2/P3 tiering, a
5-language comparison, and per-item implementation-cost tags. Modules land here
as they ship.

## Module 13 — `path` ✅ implemented (P1, 2026-07-01)

`stdlib/path.mdk` — pure POSIX (`/`-separated) path manipulation, **no
filesystem access, no effects**. Public sibling of the compiler-private
`compiler/support/path.mdk`. Not auto-prelude — `import path`.

**Exports:** `dirname`, `basename`, `extname` (dot-inclusive; a leading-dot-only
name like `.bashrc` has no extension — Go `path.Ext`/Python `splitext`
convention), `stem`, `hasExtension`, `withExtension`, `joinPath`, `joinAll`,
`segments`, `isAbsolute`, `stripPrefix`, `normalize` (Go `path.Clean` lexical
cleanup: collapse `//`, drop `.`, resolve `..`, drop `..` above an absolute
root). 29 doctests + 3 props.

## Module 14 — `hex` ✅ implemented (P1, 2026-07-01)

`stdlib/hex.mdk` — RFC-style base16 encode/decode over `Array Int` bytes. Pure,
no externs. Not auto-prelude — `import hex`.

**Exports:** `encode`/`encodeUpper` (lower/upper hex), `encodeString` (UTF-8 →
hex), `decode` (strict: odd length or non-hex digit → `Err`; accepts both
cases), `decodeString`. 11 doctests + 2 round-trip props.

## Module 15 — `base64` ✅ implemented (P1, 2026-07-01)

`stdlib/base64.mdk` — RFC 4648 base64 encode/decode over `Array Int` bytes,
standard + URL-safe alphabets. Pure, no externs. Not auto-prelude —
`import base64`.

**Exports:** `encode`/`encodeUrlSafe` (both `=`-padded), `encodeString`, `decode`
(strict, Python `b64decode`-style: bad length/char/padding → `Err`, no
whitespace skipping), `decodeUrlSafe`, `decodeString`. 18 doctests + 3 round-trip
props.

## Module 16 — `math` ✅ implemented (P1, 2026-07-01) — native/LLVM only

`stdlib/math.mdk` — floating-point math over **22 libm `extern` primitives**
(native/LLVM backend only; on WasmGC these trap like `floatRem` — a real math
story for wasm needs a host-import seam or polyfill, deferred). Not auto-prelude
— `import math`.

**Externs (in `runtime.mdk`):** roots `sqrt`/`cbrt`; transcendentals
`exp`/`log`/`log2`/`log10`/`sin`/`cos`/`tan`/`asin`/`acos`/`atan`/`sinh`/`cosh`/`tanh`;
rounding `floor`/`ceil`/`round`/`trunc`; two-arg `pow`/`atan2`/`hypot`. Each is a
`math.h` shim (`runtime/medaka_rt.c`), threaded through `eval.mdk` prims +
`llvm_preamble.mdk` declares + `llvm_emit.mdk` (`isMathUnary`/`isMathBinary` →
`isNumExtern`, generic unbox/call/rebox emit arms).

**Pure wrappers:** `toRadians`/`toDegrees`, `isNaN`/`isInfinite`, `logBase`,
integer `gcdInt`/`lcmInt`/`powInt`. (Deliberately NOT re-adding `abs`/`signum`/
`clamp` — `core.mdk` already provides them via `Num`/`Ord`.) 36 doctests + 6
props.

## Module 17 — `fs` ✅ implemented (P1, 2026-07-01) — build-path only

`stdlib/fs.mdk` — a filesystem convenience layer over the host file externs.
`import fs`. **Build-path (native/LLVM) only, BY DESIGN** — the tree-walking
interpreter (`medaka run`) is a deliberately pure, FFI-free, deterministic oracle
(it also *fakes* the clock/random externs with canned values, which is what keeps
the `diff_compiler_eval_*` gates deterministic). File externs are simply unbound
under `medaka run`; a file-touching program uses `medaka build`+run. This is not a
TODO — making `run` do real file IO would require widening the interpreter's
effect boundary (a decided non-goal, 2026-07-01).

**New externs (in `runtime.mdk`):** `removeFile` (unlink), `rename`, `removeDir`
(rmdir, empty only) — all `<FileWrite "_"> Result String Unit`; `statFile :
String -> <FileRead "_"> Result String (Int, Bool, Bool, Float)` (size, isDir,
isFile, mtime — a tuple like `runCommand`). Threaded through `eval.mdk`? No —
file externs are emitter-only; `medaka_rt.c` C shims + `llvm_preamble.mdk`
declares + `llvm_emit.mdk` `isFileExtern`/`emitFileExtern` arms.

**Module API:** `FileStat { size, isDir, isFile, mtime }` record + `stat`;
`copyFile` (read+write bytes), `mkdirAll` (`mkdir -p` via `path.dirname`
recursion, EEXIST-tolerant), `walkDir` (recursive, full paths, depth-first),
`isDir`/`isFile`/`fileSize`. Gated by 6 `test/llvm_fixtures/s13_*` build fixtures
(effectful → no doctests).

## Module 18 — `time` ✅ implemented (P1, 2026-07-01)

`stdlib/time.mdk` — durations + a UTC civil calendar. `import time`. Unlike `fs`,
these run on BOTH `medaka run` and `build` (`<Clock>` externs are interpreted).

**New externs (in `runtime.mdk`):** `monotonicSec : Unit -> <Clock> Float`
(`clock_gettime(CLOCK_MONOTONIC)`, interval timing) + `sleepMs : Int -> <Clock>
Unit` (`nanosleep`). Mirror `wallTimeSec`'s `<Clock>` wiring (eval `prim1M` →
`medaka_rt.c` → `emitPerfExtern`). `<Clock>` is atomic (no capability hole).

**Module API:** `Duration` (ms-backed) with `millis`/`seconds`/`minutes`/`hours`/
`days`, `toMillis`/`toSeconds`, `addDuration`/`subDuration`; `DateTime` record;
`fromEpochSeconds`/`toEpochSeconds` (Hinnant days-from-civil — leap-year &
pre-epoch correct, negatives via floorDiv) + `formatIso` (ISO 8601 `…Z`);
effectful `now`/`nowDateTime`/`monotonic`/`elapsedSince`/`sleep`/`sleepSeconds`.
UTC-only; **timezones = P2**. 15 doctests (cross-checked vs `date -u`) + a
round-trip prop.

## Module 19 — `net` ✅ implemented (P1, 2026-07-01) — native, build-path only

`stdlib/net.mdk` — blocking TCP networking (client + server) + DNS. `import net`.
Design: `NET-DESIGN.md`. **Native/build-path only, BY DESIGN** (like `fs`): net
externs are unbound under `medaka run` (pure oracle), and `build --target wasm`
of a net program is REJECTED (raw BSD sockets have no WasmGC equivalent — a clean
`isNetExternW` guard, not a miscompile).

**Externs (10, in `runtime.mdk`, all `<Net "_"> Result String _`, raw tagged-Int
fds):** `netResolve` (getaddrinfo), `netTcpConnect`, `netTcpListen`,
`netListenPort`, `netTcpAccept`, `netSend` (may write < len), `netRecv` (empty =
EOF), `netShutdown`, `netClose`, `netSetTimeout`. `mdk_net_*` BSD-socket C shims
(SIGPIPE-guarded); separate `isNetExtern`/`emitNetExtern` in `llvm_emit.mdk`.
`Net` is host-refining (`("Net", PPrefix None)` already seeded → `connect "h" p`
α-recovers `<Net "h">` for `manifest`/`check-policy`, zero compiler change).

**Module API:** opaque `Connection`/`Listener`; `connect`/`resolve`;
`listen`/`listenPort`/`accept`; `send`/`sendAll` (short-write loop)/`recv`/
`recvAll`; `sendString`/`recvString`/`sendLine`/`recvLine`; `shutdown`/`close`/
`closeListener`/`setTimeout`; **leak-safe brackets** `withConnection`/
`withListener`/`serveLoop` (always close on Ok and Err paths). Gated by
`test/diff_net.sh` (build-run loopback + API-roundtrip fixtures + a wasm-reject
leg), since net can't be doctested (unbound under the interpreter).

---

## FP stdlib (2026-07-02) — see [`FP-STDLIB-DESIGN.md`](./FP-STDLIB-DESIGN.md)

The FP stdlib pass (anti-gatekeep naming — friendly names over Haskell jargon,
see §0.5 of the design doc) added four new import-by-bare-name modules plus
combinators folded into `core`/`list` (documented above, in Modules 1/2). Two
compiler changes enabled it: an emitter fix for wrapped-then-saturated partial
applications (arity-carrying closures + runtime `mdk_apply`, EMITTER-GAPS.md),
and tuples becoming a real type constructor (`compiler/TUPLE-TYPE-CONSTRUCTOR-DESIGN.md`),
which is what makes `impl Bimappable (,)` possible.

## Module 20 — `validation` ✅ implemented (P1, 2026-07-02)

`stdlib/validation.mdk` — an accumulating-error applicative. `import validation`.

- ✅ `Validation e a = Failure e | Success a` — shaped like `Result e a`
  (`Failure`/`Success` instead of `Err`/`Ok`), but its `Applicative` COMBINES
  both sides' errors via `Semigroup e` when both are `Failure`, instead of
  short-circuiting on the first one — the standard shape for validating
  several independent fields and reporting every problem at once.
- ✅ `impl Mappable (Validation e)`, `impl Applicative (Validation e) requires Semigroup e`,
  `impl Foldable (Validation e)`, `impl Traversable (Validation e)`,
  `impl Eq (Validation e a) requires Eq e, Eq a`, `impl Debug (Validation e a) requires Debug e, Debug a`,
  `impl Display (Validation e a) requires Display e, Display a`
- **Deliberately NO `impl Thenable Validation`** — a monadic `andThen` must
  short-circuit, which is incoherent with accumulating errors on the same type.
  Convert to `Result` first if short-circuiting sequencing is needed.
- ✅ `validationToResult : Validation e a -> Result e a` — drop to the
  short-circuiting `Result`
- ✅ `resultToValidation : Result e a -> Validation e a` — lift a `Result` into
  the accumulating `Validation`

## Module 21 — `nonempty` ✅ implemented (P1, 2026-07-02)

`stdlib/nonempty.mdk` — a guaranteed-non-empty list. `import nonempty`.

- ✅ `NonEmpty a = NECons a (List a)` — a head element plus a (possibly empty)
  tail; never empty by construction
- ✅ `singleton : a -> NonEmpty a` — a `NonEmpty` holding exactly one element
- ✅ `fromList : List a -> Option (NonEmpty a)` — `None` on an empty list
- ✅ `head : NonEmpty a -> a` — **total** (no `Option`, unlike `List.head`)
- ✅ `maximum : Ord a => NonEmpty a -> a` — **total**
- ✅ `minimum : Ord a => NonEmpty a -> a` — **total**
- ✅ `impl Mappable NonEmpty`, `impl Foldable NonEmpty` (`toList` recovers the
  plain list), `impl Traversable NonEmpty`, `impl Semigroup (NonEmpty a)`,
  `impl Eq (NonEmpty a) requires Eq a`, `impl Debug (NonEmpty a) requires Debug a`,
  `impl Display (NonEmpty a) requires Display a` (all `default impl`)

## Module 22 — `option` ✅ implemented (P1, 2026-07-02)

`stdlib/option.mdk` — the `Option` eliminator. `import option`.
`Option`/`isSome`/`isNone`/`fromOption`/`toResult`/`fromResult` already live in
`core` (auto-prelude); this module adds the one thing core doesn't:

- ✅ `option : b -> (a -> <e> b) -> Option a -> <e> b` — fold both cases:
  a default for `None`, a function for `Some` (Haskell calls this `maybe`;
  Medaka names it for the type it eliminates)

## Module 23 — `result` ✅ implemented (P1, 2026-07-02)

`stdlib/result.mdk` — the `Result` eliminator. `import result`.
`Result`/`isOk`/`isErr`/`fromResultOr`/`mapErr` already live in `core`
(auto-prelude); this module adds the one thing core doesn't:

- ✅ `result : (e -> <eff> c) -> (a -> <eff> c) -> Result e a -> <eff> c` — fold
  both cases: a handler for `Err`, a handler for `Ok` (Haskell calls this
  `either`; Medaka names it for the type it eliminates)

## Module 24 — `bits64` ✅ implemented (2026-07-15, issue #223)

`stdlib/bits64.mdk` — 64-bit-**unsigned** arithmetic emulated over the 63-bit
`Int` fixnum (which wraps and cannot hold a `uint64`). A `U64` is a 4-tuple of
16-bit limbs `(Int, Int, Int, Int)`, least-significant first — so tuple
instances already live in `core` and the import is near-free (no new `data`
type / instance surface). Mirrors the limb algorithms the compiler hand-rolled
in `compiler/eval/eval.mdk` for SplitMix64 / FNV-1a (issue #98). Pure, no
externs (uses the `bitAnd`/`bitOr`/`bitXor`/`shiftLeft`/`shiftRight` prelude
primitives). Not auto-prelude — `import bits64`.

**Exports:** `U64` (type alias), `zero`/`one`/`ofInt` (construction; it is
`ofInt` and not `fromInt` because the latter is the `Num` interface method and a
top-level binding of that name poisons module inference),
`isZero`/`cmp64` (predicates; `cmp64` → `Ordering`), `add64`/`sub64`/`mulLow64`
(arithmetic mod 2^64, wrapping), `and64`/`or64`/`xor64` (bitwise),
`shl64`/`shr64` (logical shifts by `n ∈ [0,63]`), `mod64` (exact modulo for any
nonzero divisor up to 2^64−1, via schoolbook bit-by-bit long division). 29
doctests (incl. wraparound + long-division cases).

---

## Capability stratification audit (Phase 146, 2026-06-06)

*Companion to [`CAPABILITY-EFFECTS.md`](../design/CAPABILITY-EFFECTS.md) §3a and
[`CAPABILITY-PLATFORM.md`](../design/CAPABILITY-PLATFORM.md). Output of the Phase 146
item 3 "design-only" audit.*

The stdlib is partitioned into three tiers based on whether a function
requires a **host capability** (something the platform must explicitly grant).
This determines which functions are available on a capability-gated target
(edge Wasm, pure sandbox, plugin module) and what the capability manifest
must list.

> **Update, 2026-07-14:** at the time of this audit (Phase 146) tier M was
> distinguished from tier P by an internal `<Mut>` effect label — never granted,
> never in the manifest, purity-tracking only. That label (and the whole
> internal/security label-class split) was **removed from the language**
> outright: mutation is now untracked and carries no effect row at all, so tier
> M is no longer visible to the type system — a tier-M function's signature is
> indistinguishable from a tier-P one. The P/M split below is kept as a
> **documentation convention** (does this function allocate fresh data or
> mutate in place?), not something the compiler enforces or the manifest can
> see.

### Tiers

| Tier | Effect label | What it means | Available on |
|------|-------------|---------------|-------------|
| **P — Pure** | (none) | Referentially transparent; no host interaction; byte-identical on every target | Every target |
| **M — Local mutation** | (none — untracked) | Heap-local in-place mutation; no host interaction, no observable side effect outside the process | Every target (Wasm supports local heap mutation) |
| **H — Host capability** | `<IO>`, `<Rand>`, `<Time>`, user-defined | Requires the host to provide and grant the capability; gated by the capability manifest | Only where the manifest grants it |

Tiers P and M together are the **capability-free core**: a module that stays
within P+M can be loaded on any target without any manifest grant.  The
distinction between P and M is an *observability* property (is mutation
visible to a caller?), not a *security* property — mutation is not a host
capability and cannot be withheld (and, since 2026-07-14, does not even carry
an effect label).

### Module stratification

| Module | File | Tier | Notes |
|--------|------|------|-------|
| 0 runtime (extern catalog) | `runtime.mdk` | mixed — see §Extern audit | |
| 1 core | `core.mdk` | P + H carve-outs | Mostly P; `print`/`println` → `<IO>`; `Arbitrary`/`arbitraryString`/`arbitraryList` → `<Rand>` |
| 2 list | `list.mdk` | P | Fully pure |
| 3 string | `string.mdk` | P | Fully pure (Unicode DB is bundled, not a syscall) |
| 4 array | `array.mdk` | P + M | In-place ops (`sort!`, `fill`, `blit`) mutate in place, untracked; allocation and reads are P |
| 5 map | `map.mdk` | P | Persistent weight-balanced tree; no mutation |
| 5 set | `set.mdk` | P | Persistent weight-balanced tree; no mutation |
| 6 hash_map | `hash_map.mdk` | M | `insert`/`delete`/`fromList` mutate in place, untracked; all queries pure |
| 6 hash_set | `hash_set.mdk` | M | Same as hash_map |
| 7 io | `io.mdk` | H (`<IO>`) | Entirely host-capability; not available without the `<IO>` grant |
| 8 mut_array | `mut_array.mdk` | M | `push`/`pop`/`set`/`swap`/`clear`/`mapInPlace` mutate in place, untracked; capacity/length queries pure |
| 9 json | `json.mdk` | P | `parse`/`stringify` are fully pure; transiently allocates arrays but the mutation never escapes |
| 10 test | `test.mdk` | P + H | `Expectation` ADT + assertion helpers are P; `runTests` → `<IO>` (prints results to stdout) |

**P+M kernel:** modules 1–9 (excluding io) cover the full capability-free
surface. A plugin restricted to pure computation plus mutable local data
structures needs no manifest entries at all.

### Extern audit

#### Tier P — pure, no effect label

| Group | Externs |
|-------|---------|
| Constants | `pi`, `e`, `intMinBound`, `intMaxBound`, `charMinBound`, `charMaxBound` |
| Allocation (pure) | `Ref` (wraps a value; mutation is `set_ref`), `arrayMake`, `arrayMakeWith`, `arrayCopy`, `arrayFromList` |
| Array read | `arrayLength`, `arrayGetUnsafe` |
| Array pure wrappers | `arraySortBy` — allocates + locally mutates + returns a fresh array; the mutation never escapes |
| Numeric / char conversions | `charToStr`, `intToFloat`, `floatToInt`, `intToString`, `floatToString`, `charCode`, `charFromCode` |
| Debug rendering | `debugStringLit`, `debugCharLit` |
| String kernel | `stringToChars`, `stringFromChars`, `stringLength`, `stringSlice`, `stringConcat`, `stringIndexOf`, `stringCompare`, `stringToFloat` |
| Unicode classification | `charIsAlpha`, `charIsSpace`, `charIsUpper`, `charIsLower`, `charIsPunct` |
| Unicode case folding | `charToUpper`, `charToLower`, `stringToUpper`, `stringToLower` |
| Hash | `hash` — structural, deterministic; must agree with the type's `Eq` |
| Internal | `__fallthrough__` — signals pattern fall-through; not a user capability |

#### Tier M — local mutation (untracked, no effect label)

| Extern | Notes |
|--------|-------|
| `set_ref` | Overwrites a `Ref`; heap-local |
| `arraySetUnsafe` | In-place write; bounds unchecked (stdlib-internal use) |
| `arrayBlit` | Copy range between arrays in-place |
| `arrayFill` | Fill array range in-place |
| `arraySortInPlaceBy` | In-place sort |

#### Tier H — host capabilities

| Extern | Current label | Fine-grained label (proposed) | Notes |
|--------|--------------|-------------------------------|-------|
| `putStr`, `putStrLn` | `<Stdout>` ✅ | `<Stdout>` | Standard output (split done) |
| `ePutStr`, `ePutStrLn` | `<Stderr>` ✅ | `<Stderr>` | Standard error (split done) |
| `readLine`, `readLineOpt`, `readAll` | `<Stdin>` ✅ | `<Stdin>` | Standard input (split done) |
| `readFile`, `fileExists`, `listDir` | `<FileRead>` ✅ | `<FileRead>` | Filesystem read (split done) |
| `writeFile`, `appendFile` | `<FileWrite>` ✅ | `<FileWrite>` | Filesystem write (split done) |
| `args`, `getEnv` | `<Env>` ✅ | `<Env>` | Process args + env vars (split done) |
| `exit` | (none) | **`<Exit>`** (still proposed, not implemented) | Process termination — a genuine withholdable capability; distinct from `panic` (see Design resolution below). Was `<Panic>` until 2026-07-14; when the internal-label class was deleted outright, `exit` lost its label entirely rather than gaining the proposed gated `<Exit>` — the split below never landed |
| `randomInt`, `randomBool`, `randomFloat`, `randomChar`, `setSeed` | `<Rand>` | `<Rand>` | (already fine-grained) |
| `wallTimeSec` | `<Clock>` ✅ (was `<IO>`) | `<Clock>` | Wall-clock read; builtin label is `Clock` (not `Time` as originally planned) |
| `allocBytes` | `<IO>` | `<Perf>` or keep `<IO>` | GC profiling escape hatch; very low priority |

#### Tooling-only (not for user code or edge modules)

| Extern | Label | Notes |
|--------|-------|-------|
| `assert_snapshot` | `<IO>` | Used only by the snapshot test harness |

### Design resolution — `panic` vs `exit` (2026-06-06)

> **Status update, 2026-07-14:** `panic` and `exit` were both labelled
> `<Panic>` at the time this section was written — an internal label (purity
> tracking, never in the manifest). That whole internal-label class was
> removed from the language, and with it `<Panic>` — `exit` simply lost its
> label (it is now `Int -> Unit`, no row), rather than gaining the gated
> `<Exit>` label recommendation below. The distinction argued for here (`exit`
> *should* be a withholdable host capability; `panic` should not) is still a
> live, unimplemented design point — it just needs a **new** label declaration
> (`exit`'s current lack of any row is a regression relative to this section's
> goal, not a fix for it).

`panic` and `exit` were both labelled `<Panic>`, but they are different kinds
of thing, and conflating them is the source of the confusion:

| | `panic : String -> a` | `exit : Int -> <…> Unit` |
|---|---|---|
| Kind | **trap / abort** (partiality) | **process termination** (process control) |
| Catchable in-runtime | yes — `runExpectation` catches `Eval_error`/`Impl_no_match` | no — terminates the process |
| Can the host withhold it? | **no** — the host can only choose what happens *on* abort, not make abort not-happen | **yes** — a plugin that can kill the host process is a real sandbox-escape concern |
| Belongs in the manifest? | no | yes |

The test that defines tier H is "something the platform must explicitly
grant." `exit` passes it; `panic` does not.

**Resolution:**

1. **`panic` stays untagged** (`String -> a`). Partiality is not a host
   capability — it is a property of nearly every partial function (non-exhaustive
   matches, bounds checks, exhaustiveness sentinels, dispatch-failure paths).
   Threading `<Panic>` through all of them would make it the most common label
   in the codebase and **dilute the signal of the labels that actually gate**
   (`<Fs>`, `<Stdout>`, `<Rand>`), while breaking the clean "tier P is
   effect-free" story (`list`/`string`/`map`/`set` are full of partial ops).
   This is the standard call (Haskell `error :: String -> a`, ML `failwith`).
   Treat `panic` as always-subsumed and exclude it from capability gating —
   consistent with WASI trap semantics (always available, untrappable from the
   host).

2. **`exit` gets its own gated label** — rename `<Panic>` → `<Exit>` (process
   control). This is genuinely withholdable: a logging plugin granted
   `{Stdout}` must **not** be able to `exit` the host, which only works if
   `exit` carries a distinct, gated label.

3. **A "cannot abort" / totality guarantee**, if ever required (e.g. a pure
   sandbox that must not abort the host), is a *separate optional totality
   analysis* — not an effect-row capability. Bolting partiality onto the
   capability row makes both worse; that payoff is rare and can wait.

### Target profiles

| Profile | Tiers available | Practical capability grants |
|---------|----------------|----------------------------|
| Pure sandbox | P only | none — all computation, no I/O or mutation |
| General compute | P + M | none — data structures + algorithms freely |
| Edge / plugin | P + M + selected H | per-deployment manifest: e.g. `{Stdout, Fetch}` for a logging transform; `{Stdout, KV}` for a cache-layer plugin |
| General-purpose native | P + M + all H | all built-in labels; user programs use IO/Rand/Exit freely |

### Label refinement roadmap

The infrastructure for fine-grained labels is in place (Phase 146 gap 2:
`effect Foo` declarations, user-definable labels, all labels are erased
before codegen).  The remaining steps, in priority order:

1. **`wallTimeSec` label** — ✅ already using `<Clock>` in `runtime.mdk` (the builtin
   label is `Clock`, not `Time`; `<Time>` was a placeholder name that was never
   added). Do the final label audit before manifest emission.
2. **`<IO>` split** — ✅ largely DONE (verified 2026-06-22): externs now use `<Stdout>`,
   `<Stderr>`, `<Stdin>`, `<FileRead>`, `<FileWrite>`, `<Env>` in `runtime.mdk`. The
   io.mdk wrappers and `appendFile` may still use `<IO>`; do a final audit before
   manifest emission.
3. **`panic`/`exit` split** — `panic` stays untagged (excluded from gating);
   `exit` should get a real gated `<Exit>` capability label. See "Design
   resolution" above. **Still open** as of 2026-07-14: `exit` currently carries
   *no* label at all (its old `<Panic>` label was deleted along with the whole
   internal-label class, rather than replaced by `<Exit>`), so this item is not
   done — it needs a genuinely new label declaration, not a rename. Apply
   before manifest emission.
4. **Cross-module effect label export** — ✅ DONE (Phase 146 gap 3, 2026-06-07): `export effect Fetch` declared in a
   platform SDK module is now visible across the loader boundary via `exp_effects` in `module_exports`.
5. **Manifest emission** — the final Phase 146 remaining item (CAPABILITY-EFFECTS.md
   §5a): once labels are refined and cross-module export works, the compiler
   emits a `[package.capabilities]` table from a verified entry point's effect
   row.
