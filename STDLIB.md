# Medaka Standard Library Plan

This document lists what belongs in the first four stdlib modules. It is a
checklist, not a spec: implementation order within a module is yours to choose.
No code snippets — just the names, grouped so nothing slips through.

Work interactively via the REPL (`:load stdlib/core.mdk`, `:reload` after edits).
Expect to discover language gaps as you go; record them in PLAN.md §5.

**Status legend**

- ✅ implemented in the indicated file
- ⏳ planned, not yet started
- 🟡 partially implemented (see note)

**Notes on the current state (as of 2026-05-26).**

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

## Module 0 — `runtime` (extern catalog) ✅ implemented

These are the OCaml-backed primitives declared as `extern` in
`stdlib/runtime.mdk`. They are visible to every Medaka program without an
import. The list is authoritative — adding a new primitive means editing this
file and the matching impl in `lib/eval.ml`.

- `print : a -> <IO> Unit` — write a value to stdout, no trailing newline
- `println : a -> <IO> Unit` — write a value to stdout followed by `\n`
- `Ref : a -> Ref a` — wrap a value in a mutable cell
- `set_ref : Ref a -> a -> <Mut> Unit` — overwrite the contents of a `Ref`
- `pi : Float` — math constant π
- `e : Float` — math constant e
- `readLine : Unit -> <IO> String` — read one line from stdin
- `readFile : String -> <IO> (Result String String)` — read file, `Ok contents` or `Err message`
- `writeFile : String -> String -> <IO> (Result String Unit)` — write file, `Ok ()` or `Err message`
- `exit : Int -> <Panic> Unit` — terminate the process with the given exit code
- `panic : String -> a` — abort with a runtime panic carrying the message

`pure` and `map` are *not* externs — they are interface methods (see `core`).

---

## Module 1 — `core` 🟡 mostly implemented

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

- ✅ `Show a` — human-readable string representation
  - `show : a -> String` — render a value as a `String` for display

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
  - `toList : t a -> List a` — flatten to a plain list (linearises order)
  - `isEmpty : t a -> Bool` (default via `toList`; override for O(1) structures) — true when there are no elements
  - `length : t a -> Int` (default via `fold`; override for O(1) structures) — element count

  Standalone helpers (all use constraint syntax now that Phase 20 has landed):
  - ✅ `any : Foldable t => (a -> Bool) -> t a -> Bool` — true when the predicate holds for at least one element
  - ✅ `all : Foldable t => (a -> Bool) -> t a -> Bool` — true when the predicate holds for every element
  - ⏳ `find : Foldable t => (a -> Bool) -> t a -> Option a` — first element satisfying the predicate, or `None`
  - ⏳ `count : Foldable t => (a -> Bool) -> t a -> Int` — number of elements satisfying the predicate
  - ⏳ `sum : (Foldable t, Num a) => t a -> a` — additive fold; identity is `fromInt 0`
  - ⏳ `product : (Foldable t, Num a) => t a -> a` — multiplicative fold; identity is `fromInt 1`
  - ⏳ `elem : (Foldable t, Eq a) => a -> t a -> Bool` — true when the element is present (compared via `Eq`)

### Data types

- ✅ `Ordering` — `Lt | Eq | Gt` — three-way comparison result

- ✅ `Option a` — `Some a | None` — value that may be absent
  Helpers:
  - ✅ `isSome : Option a -> Bool` — true if `Some _`
  - ✅ `isNone : Option a -> Bool` — true if `None`
  - ✅ `fromOption : a -> Option a -> a` — extract value or fall back to default (also known as `withDefault` in some langs)
  - ✅ `toResult : e -> Option a -> Result e a` — `Some x → Ok x`, `None → Err e`
  - ⏳ `fromResult : Result e a -> Option a` — `Ok x → Some x`, `Err _ → None` *(was named `toOption` in earlier draft)*
  - ⏳ Instances: `Eq (Option a)`, `Ord (Option a)`, `Show (Option a)`, `Mappable Option` ✅, `Foldable Option`, `Applicative Option` ✅, `Thenable Option` ✅

- ✅ `Result e a` — `Ok a | Err e` — success-or-error value
  Helpers:
  - ✅ `isOk : Result e a -> Bool` — true if `Ok _`
  - ✅ `isErr : Result e a -> Bool` — true if `Err _`
  - ⏳ `fromResultOr : a -> Result e a -> a` — extract `Ok` value or fall back to default (rename `fromResult` from the earlier draft to avoid collision with `Option`'s)
  - ⏳ `mapErr : (e -> f) -> Result e a -> Result f a` — apply to the `Err` side, pass `Ok` through
  - ⏳ Instances: `Eq (Result e a)`, `Show (Result e a)`, `Mappable (Result e)` ✅, `Thenable (Result e)` ✅

### Utility functions

- ✅ `identity : a -> a` — return the argument unchanged
- ✅ `const : a -> b -> a` — return the first argument, ignoring the second
- ✅ `flip : (a -> b -> c) -> b -> a -> c` — swap the first two arguments of a binary function
- ✅ `compose : (b -> c) -> (a -> b) -> a -> c` — right-to-left function composition (`g . f`)
- ✅ `pipe : (a -> b) -> (b -> c) -> a -> c` — left-to-right function composition
- ✅ `apply : (a -> b) -> a -> b` — function application as a function
- ✅ `not : Bool -> Bool` — logical negation
- ✅ `and : Bool -> Bool -> Bool` — logical AND (strict; both args evaluated)
- ✅ `or : Bool -> Bool -> Bool` — logical OR (strict)
- ✅ `xor : Bool -> Bool -> Bool` — logical XOR
- ✅ `otherwise : Bool` — alias for `True`, idiomatic in guard chains
- ✅ `filter : (a -> Bool) -> List a -> List a` — keep elements satisfying the predicate *(currently lives in `core.mdk`; could move to `list.mdk` since it's List-specific)*
- ⏳ `panic : String -> a` — already an extern in `runtime.mdk`; no stdlib re-export needed

### Impls already provided

- ✅ `impl Eq (List a) requires Eq a`
- ✅ `impl Monoid (List a)`
- ✅ `impl Monoid String`
- ✅ `impl Mappable List`, `impl Mappable Option`, `impl Mappable (Result e)` (default)
- ✅ `impl Applicative List`, `impl Applicative Option`, `impl Applicative (Result e)`
- ✅ `impl Thenable List`, `impl Thenable Option`, `impl Thenable (Result e)`
- ✅ `impl Foldable List`

### Impls still missing (track here as `core` grows)

- ⏳ `impl Semigroup (List a)`, `impl Semigroup String` (currently `Monoid` impls exist but the `Semigroup` parent's `append` for each comes from the `++` operator dispatch path; formalise explicit impls)
- ⏳ `impl Eq` for `Int`, `Float`, `Bool`, `Char`, `String`, `Unit`, `Option a`, `Result e a`, tuples
- ⏳ `impl Ord` for `Int`, `Float`, `Char`, `String`, `Option a`, `Result e a`, tuples, `List a`
- ⏳ `impl Show` for every built-in type and for `Option`, `Result`, `List`, tuples
- ⏳ `impl Num Int`, `impl Num Float` (today these are seeded by `seed_builtin_interfaces` in the typechecker — should be replaced by Medaka-side impls)
- ⏳ `impl Bounded Int`, `impl Bounded Char`
- ⏳ `impl Foldable Option`, `impl Foldable (Result e)`, `impl Foldable Array`
- ⏳ `impl Mappable Array`

---

## Module 2 — `list` 🟡 partially implemented

Depends on `core`. `filter` currently lives in `core.mdk` but is List-specific
and may move here. Functions already covered by `impl Foldable List` or
`impl Mappable List` (fold, foldRight, map, any, all, find, count, elem, sum,
product) do not need implementations here — use the typeclass dispatch path.

### Construction

- ⏳ `empty : List a` — the empty list (alias for `[]`)
- ✅ `singleton : a -> List a` — one-element list
- ⏳ `range : Int -> Int -> List Int` — `range lo hi` produces `[lo, lo+1, …, hi-1]` (exclusive upper bound)
- ⏳ `rangeStep : Int -> Int -> Int -> List Int` — `rangeStep lo hi step`; sign of `step` must match `hi - lo` or result is empty
- ⏳ `replicate : Int -> a -> List a` — list containing the value repeated N times
- ⏳ `iterate : Int -> (a -> a) -> a -> List a` — `[seed, f seed, f (f seed), …]` of length N
- ⏳ `unfold : (b -> Option (a, b)) -> b -> List a` — generate a list from a seed; stops when the generator returns `None`

### Observation

- ✅ `isEmpty : List a -> Bool` — true for the empty list
- ✅ `head : List a -> Option a` — first element, or `None` if empty
- ✅ `tail : List a -> Option (List a)` — all elements after the first, or `None` if empty
- ✅ `last : List a -> Option a` — final element, or `None` if empty
- ✅ `init : List a -> Option (List a)` — all elements except the last, or `None` if empty
- ✅ `get : Int -> List a -> Option a` — element at index (0-based), or `None` if out of range

### Transformation

- ⏳ `filter : (a -> Bool) -> List a -> List a` — keep elements satisfying the predicate *(currently lives in `core.mdk` — see note above)*
- ⏳ `filterMap : (a -> Option b) -> List a -> List b` — apply a partial function; keep `Some` results, drop `None`
- ⏳ `reverse : List a -> List a` — list in opposite order
- ⏳ `concat : List (List a) -> List a` — flatten one level (alias for `flatten`)
- ⏳ `concatMap : (a -> List b) -> List a -> List b` — `map` then `concat`; equivalent to `andThen` on `List` (`Thenable`)
- ⏳ `flatten : List (List a) -> List a` — flatten one level
- ⏳ `intersperse : a -> List a -> List a` — insert separator between every pair of elements
- ⏳ `intercalate : List a -> List (List a) -> List a` — `concat` after `intersperse`
- ⏳ `transpose : List (List a) -> List (List a)` — turn rows into columns
- ⏳ `subsequences : List a -> List (List a)` — every subset of the list (2^N of them)
- ⏳ `permutations : List a -> List (List a)` — every ordering of the list (N! of them)

### Folds and scans

- ⏳ `scanLeft : (b -> a -> b) -> b -> List a -> List b` — like `fold` but keeps every intermediate accumulator
- ⏳ `scanRight : (a -> b -> b) -> b -> List a -> List b` — right-associated `scanLeft`
- ⏳ `maximum : Ord a => List a -> Option a` — largest element, or `None` if empty
- ⏳ `minimum : Ord a => List a -> Option a` — smallest element, or `None` if empty

### Search

- ⏳ `notElem : Eq a => a -> List a -> Bool` — `not (elem x xs)`
- ⏳ `findIndex : (a -> Bool) -> List a -> Option Int` — index of the first match, or `None`
- ⏳ `findIndices : (a -> Bool) -> List a -> List Int` — all indices that match
- ⏳ `elemIndex : Eq a => a -> List a -> Option Int` — index of the first occurrence of the value

### Sublists

- ⏳ `take : Int -> List a -> List a` — first N elements (fewer if the list is shorter)
- ⏳ `drop : Int -> List a -> List a` — everything after the first N elements
- ⏳ `takeWhile : (a -> Bool) -> List a -> List a` — prefix where the predicate holds
- ⏳ `dropWhile : (a -> Bool) -> List a -> List a` — drop the leading run where the predicate holds
- ⏳ `span : (a -> Bool) -> List a -> (List a, List a)` — `(takeWhile p xs, dropWhile p xs)`
- ⏳ `break : (a -> Bool) -> List a -> (List a, List a)` — `span (not . p) xs`
- ⏳ `splitAt : Int -> List a -> (List a, List a)` — `(take n xs, drop n xs)`
- ⏳ `slice : Int -> Int -> List a -> List a` — `slice lo hi xs` is `drop lo (take hi xs)`
- ⏳ `chunks : Int -> List a -> List (List a)` — split into consecutive groups of N (last group may be shorter)

### Zipping and combining

- ⏳ `zip : List a -> List b -> List (a, b)` — pair up elements; result length is the shorter input
- ⏳ `zip3 : List a -> List b -> List c -> List (a, b, c)` — triple-up version of `zip`
- ⏳ `zipWith : (a -> b -> c) -> List a -> List b -> List c` — generalised `zip`; result length is the shorter input
- ⏳ `unzip : List (a, b) -> (List a, List b)` — split a list of pairs into two parallel lists

### Sorting

- ⏳ `sort : Ord a => List a -> List a` — ascending sort (stable)
- ⏳ `sortBy : (a -> a -> Ordering) -> List a -> List a` — custom comparator
- ⏳ `sortOn : Ord b => (a -> b) -> List a -> List a` — sort by a derived key (compute the key once per element if possible)
- ⏳ `nub : Eq a => List a -> List a` — remove duplicates, keeping the first occurrence; O(N²) baseline
- ⏳ `nubBy : (a -> a -> Bool) -> List a -> List a` — `nub` with a custom equality test

### Grouping

- ⏳ `group : Eq a => List a -> List (List a)` — group runs of equal adjacent elements
- ⏳ `groupBy : (a -> a -> Bool) -> List a -> List (List a)` — `group` with a custom equivalence
- ⏳ `partition : (a -> Bool) -> List a -> (List a, List a)` — `(filter p xs, filter (not . p) xs)` in one pass
- ⏳ `tally : Eq a => List a -> List (a, Int)` — element → count; order of keys unspecified (insertion-stable would be a nice-to-have)

### Instances

- ✅ `impl Eq (List a)` where `Eq a` — *(in `core.mdk`)*
- ⏳ `impl Ord (List a)` where `Ord a` — lexicographic ordering
- ⏳ `impl Show (List a)` where `Show a` — bracketed comma-separated form
- ✅ `impl Mappable List` — *(in `core.mdk`)*
- ✅ `impl Foldable List` — *(in `core.mdk`)*
- ✅ `impl Applicative List` — *(in `core.mdk`)*
- ✅ `impl Thenable List` — *(in `core.mdk`)*
- ⏳ `impl Semigroup (List a)` — concatenation (currently driven by the `++` dispatch path)
- ✅ `impl Monoid (List a)` — *(in `core.mdk`)*

---

## Module 3 — `string` ⏳ not started

Depends on `core`. Also provides `Char` utilities. File `stdlib/string.mdk`
currently contains only an `import` line.

### Char operations

- ⏳ `isDigit : Char -> Bool` — `'0'..'9'`
- ⏳ `isAlpha : Char -> Bool` — Unicode letter
- ⏳ `isAlphaNum : Char -> Bool` — letter or digit
- ⏳ `isSpace : Char -> Bool` — Unicode whitespace
- ⏳ `isUpper : Char -> Bool` — uppercase letter
- ⏳ `isLower : Char -> Bool` — lowercase letter
- ⏳ `isPunct : Char -> Bool` — Unicode punctuation category
- ⏳ `toUpper : Char -> Char` — case fold to upper (identity for non-letters)
- ⏳ `toLower : Char -> Char` — case fold to lower
- ⏳ `digitToInt : Char -> Option Int` — `'0'..'9' → Some 0..9`, `'a'..'f' → Some 10..15`, else `None`
- ⏳ `intToDigit : Int -> Option Char` — inverse of `digitToInt` for `0..15`
- ⏳ `charCode : Char -> Int` — Unicode codepoint
- ⏳ `charFromCode : Int -> Option Char` — codepoint → `Char`, `None` if out of range / surrogate

### Conversion

- ⏳ `fromChar : Char -> String` — one-character string
- ⏳ `toChars : String -> List Char` — codepoint list (note: not grapheme clusters)
- ⏳ `fromChars : List Char -> String` — inverse of `toChars`
- ⏳ `toString : Show a => a -> String` — alias for `show`
- ⏳ `toInt : String -> Option Int` — parse a decimal integer (leading sign allowed); `None` on any failure
- ⏳ `toFloat : String -> Option Float` — parse a decimal float; `None` on any failure
- ⏳ `fromInt : Int -> String` — decimal representation
- ⏳ `fromFloat : Float -> String` — decimal representation (shortest round-tripping form preferred)

### Inspection

- ⏳ `length : String -> Int` — code-unit count (TBD: clarify byte vs codepoint vs grapheme once the runtime rep is locked)
- ⏳ `isEmpty : String -> Bool` — true for `""`
- ⏳ `startsWith : String -> String -> Bool` — `startsWith prefix s` — true when `s` begins with `prefix`
- ⏳ `endsWith : String -> String -> Bool` — `endsWith suffix s` — true when `s` ends with `suffix`
- ⏳ `contains : String -> String -> Bool` — `contains needle haystack`
- ⏳ `indexOf : String -> String -> Option Int` — first index of `needle` in `haystack`, or `None`
- ⏳ `lastIndexOf : String -> String -> Option Int` — last index of `needle` in `haystack`
- ⏳ `count : String -> String -> Int` — number of non-overlapping occurrences

### Transformation

- ⏳ `append : String -> String -> String` — `s1 ++ s2`; available via the `Semigroup` impl
- ⏳ `prepend : String -> String -> String` — `flip append`
- ⏳ `concat : List String -> String` — concatenate all strings in order
- ⏳ `join : String -> List String -> String` — `join sep parts` — concatenate with `sep` between each pair
- ⏳ `repeat : Int -> String -> String` — repeat the string N times
- ⏳ `reverse : String -> String` — codepoint-reversed string
- ⏳ `trim : String -> String` — strip whitespace from both ends
- ⏳ `trimLeft : String -> String` — strip leading whitespace
- ⏳ `trimRight : String -> String` — strip trailing whitespace
- ⏳ `toUpper : String -> String` — case fold each char to upper
- ⏳ `toLower : String -> String` — case fold each char to lower
- ⏳ `capitalize : String -> String` — uppercase first char, leave the rest alone
- ⏳ `replace : String -> String -> String -> String` — `replace old new s` — replace the first occurrence
- ⏳ `replaceAll : String -> String -> String -> String` — replace every non-overlapping occurrence

### Slicing and splitting

- ⏳ `slice : Int -> Int -> String -> String` — `slice lo hi s` — substring `[lo, hi)`
- ⏳ `take : Int -> String -> String` — first N codepoints (fewer if shorter)
- ⏳ `drop : Int -> String -> String` — drop the first N codepoints
- ⏳ `split : String -> String -> List String` — `split sep s` — split on `sep`, dropping the separator
- ⏳ `splitAt : Int -> String -> (String, String)` — `(take n s, drop n s)`
- ⏳ `lines : String -> List String` — split on `\n` (also accept `\r\n`)
- ⏳ `words : String -> List String` — split on runs of whitespace, drop empties
- ⏳ `unlines : List String -> String` — join with `\n` and append a trailing newline
- ⏳ `unwords : List String -> String` — join with single spaces

### Padding

- ⏳ `padLeft : Int -> Char -> String -> String` — left-pad with the given char up to total length N
- ⏳ `padRight : Int -> Char -> String -> String` — right-pad
- ⏳ `center : Int -> Char -> String -> String` — center the string, splitting padding evenly (extra goes on the right)

### Instances

- ⏳ `impl Eq String` — already type-checks structurally; formalise with explicit method
- ⏳ `impl Ord String` — lexicographic codepoint order
- ⏳ `impl Show String` — quoted, with escape handling
- ⏳ `impl Semigroup String` — already in `core.mdk` via `Monoid`
- ⏳ `impl Eq Char`
- ⏳ `impl Ord Char` — codepoint order
- ⏳ `impl Show Char` — quoted

---

## Module 4 — `array` 🟡 partially implemented

Depends on `core`. Arrays are fixed-size and support O(1) random access.
The runtime already exposes `VArray`, the `[|...|]` literal, range
literals (`[|lo..hi|]`/`[|lo..=hi|]`), and panicking bracket indexing
(`arr[i]`).

**Design layering** (see `stdlib/array.mdk` for the full rationale):

1. **Kernel** of OCaml-backed primitives in `stdlib/runtime.mdk`
   (`arrayLength`, `arrayMake`, `arrayMakeWith`, `arrayGetUnsafe`,
   `arraySetUnsafe`, `arrayCopy`, `arrayBlit`, `arrayFill`,
   `arraySortInPlaceBy`, and the pure wrappers `arraySortBy`,
   `arrayFromList`).  The two pure wrappers exist because Medaka has
   no effect-masking: a function using `arrayBlit`/`arraySortInPlaceBy`
   propagates `<Mut>` to all callers, which would force `sort`/`sortBy`
   to surface `<Mut>` in their signatures.  Encapsulating "alloc +
   mutate locally + return fresh" inside an extern keeps the pure API
   honest.
2. **Pure stdlib** (Medaka) built on the kernel via `arrayMakeWith`
   and tail-recursive helpers.
3. **Effectful stdlib** (Medaka) with explicit `<Mut>` in signatures.
4. **Typeclass impls**: `Mappable`, `Foldable`, `Semigroup`, `Monoid`,
   `Eq`.  Deliberately *not* `Applicative` / `Thenable` — the natural
   definitions encode cartesian-style allocation that's a performance
   trap on bulk data.  `Show` is blocked on a resolver gap (see below).

**Resolver gap (closed).**  Previously, interface methods whose only
body in core was a default on the interface itself (`max`, `min`,
`show`) were not seeded into `prelude_values` and resolved as unbound
in user files.  Fixed in `lib/resolve.ml` by extending
`prelude_values` to include `DInterface` method names — so this
module can now use `max`/`min` directly.  `impl Show (Array a)`
remains deferred, but the blocker is now narrower: `show` resolves;
what's missing is the actual `impl Show Int`/`Show Float`/etc. in
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
- ✅ `filterA : (a -> Bool) -> Array a -> Array a` — keep matching elements (two-pass via list intermediate; pure).  Named `filterA` not `filter` because `core.filter` is a List-specific standalone and Medaka doesn't yet allow two top-level functions to share a name across modules.  When `core.filter` moves to `list.mdk` (already noted as planned in core.mdk), this can be renamed to plain `filter`.
- ✅ `filterMap : (a -> Option b) -> Array a -> Array b` — keep `Some` results
- ✅ `reverse : Array a -> Array a` — fresh array in opposite order
- ✅ `slice : Int -> Int -> Array a -> Array a` — `[lo, hi)`; clamps to bounds, does not panic (use `arr[lo..hi]` for the panicking variant)
- ✅ `take : Int -> Array a -> Array a` — first N elements
- ✅ `drop : Int -> Array a -> Array a` — everything after the first N
- ✅ `append : Array a -> Array a -> Array a` — concatenate two arrays
- ✅ `concat : Array (Array a) -> Array a` — flatten one level
- ✅ `zip : Array a -> Array b -> Array (a, b)` — pair up by index; result length is the shorter input
- ✅ `zipWith : (a -> b -> c) -> Array a -> Array b -> Array c` — generalised `zip`
- ⏳ `unzip : Array (a, b) -> (Array a, Array b)` — split into two parallel arrays

### Mutation (effectful — modify in place)

- ✅ `set : Int -> a -> Array a -> <Mut> Unit` — bounds-checked write (panics on OOB)
- ✅ `swap : Int -> Int -> Array a -> <Mut> Unit`
- ✅ `fill : a -> Array a -> <Mut> Unit`
- ✅ `sortInPlace : Ord a => Array a -> <Mut> Unit`
- ✅ `sortInPlaceBy : (a -> a -> Ordering) -> Array a -> <Mut> Unit`

### Folds and search

- 🟡 `fold`, `foldRight`, `any`, `all` — via `impl Foldable Array` + core helpers
- ✅ `find : (a -> Bool) -> Array a -> Option a` — first match, or `None`
- ✅ `findIndex : (a -> Bool) -> Array a -> Option Int` — index of the first match
- ✅ `elem : Eq a => a -> Array a -> Bool` — value is present
- ✅ `sum : Array Int -> Int` — additive fold
- ✅ `product : Array Int -> Int` — multiplicative fold
- ✅ `maximum : Ord a => Array a -> Option a` — largest element, or `None` if empty
- ✅ `minimum : Ord a => Array a -> Option a` — smallest element, or `None` if empty

### Sorting (pure)

- ✅ `sort : Ord a => Array a -> Array a` — fresh sorted copy (kernel-level `arraySortBy compare`)
- ✅ `sortBy : (a -> a -> Ordering) -> Array a -> Array a`
- ✅ `sortOn : Ord b => (a -> b) -> Array a -> Array a`

### Instances

- ✅ `impl Eq (Array a)` where `Eq a` — element-wise
- ⏳ `impl Show (Array a)` where `Show a` — blocked on the prelude-method-resolution gap (see note above)
- ✅ `impl Mappable Array`
- ✅ `impl Foldable Array`
- ✅ `impl Semigroup (Array a)` — array concatenation
- ✅ `impl Monoid (Array a)` — identity is `[||]`
- **Skipped:** `Applicative Array`, `Thenable Array` — semantically definable but encourage O(N·M) allocation; arrays should drop into `List` for monadic non-determinism and convert back at the boundary
