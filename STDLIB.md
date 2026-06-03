# Medaka Standard Library Plan

This document lists what belongs in the first four stdlib modules. It is a
checklist, not a spec: implementation order within a module is yours to choose.
No code snippets — just the names, grouped so nothing slips through.

Work interactively via the REPL (`:load stdlib/core.mdk`, `:reload` after edits).
Expect to discover language gaps as you go; record them in PLAN.md's open
roadmap.

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

## Module 0 — `runtime` (extern catalog) ✅ implemented

These are the OCaml-backed primitives declared as `extern` in
`stdlib/runtime.mdk`. They are visible to every Medaka program without an
import. The list is authoritative — adding a new primitive means editing this
file and the matching impl in `lib/eval.ml`.

- `putStr : String -> <IO> Unit` — write a string to stdout, no trailing newline
- `putStrLn : String -> <IO> Unit` — write a string to stdout followed by `\n`
- `inspect : a -> <IO> Unit` — dump a value's raw internal structure (debug
  escape hatch; bypasses `Display`)
- (`print`/`println : Display a => a -> <IO> Unit` are Medaka prelude functions
  over `putStr`/`putStrLn`, not externs — they render via `Display`, Phase 111)
- `Ref : a -> Ref a` — wrap a value in a mutable cell (read it back via `r.value`)
- `set_ref : Ref a -> a -> <Mut> Unit` — overwrite the contents of a `Ref`
- `hash : a -> Int` — structural, non-negative hash (Module 6 hash containers)
- `pi : Float` — math constant π
- `e : Float` — math constant e
- `readLine : Unit -> <IO> String` — read one line from stdin
- `readFile : String -> <IO> (Result String String)` — read file, `Ok contents` or `Err message`
- `writeFile : String -> String -> <IO> (Result String Unit)` — write file, `Ok ()` or `Err message`
- `exit : Int -> <Panic> Unit` — terminate the process with the given exit code
- `panic : String -> a` — abort with a runtime panic carrying the message

io Module 7 host primitives (see Module 7 for the ergonomic layer):

- `args : Unit -> <IO> (List String)` — program args after the script name
- `getEnv : String -> <IO> (Option String)` — environment variable, or `None`
- `fileExists : String -> <IO> Bool`
- `appendFile : String -> String -> <IO> (Result String Unit)` — `Ok ()` / `Err message`
- `listDir : String -> <IO> (Result String (List String))` — directory entry names
- `ePutStr` / `ePutStrLn : String -> <IO> Unit` — raw stderr output
- `readLineOpt : Unit -> <IO> (Option String)` — one stdin line, `None` at EOF
- `readAll : Unit -> <IO> String` — all of stdin

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

### Data types

- ✅ `Ordering` — `Lt | Eq | Gt` — three-way comparison result

- ✅ `Option a` — `Some a | None` — value that may be absent
  Helpers:
  - ✅ `isSome : Option a -> Bool` — true if `Some _`
  - ✅ `isNone : Option a -> Bool` — true if `None`
  - ✅ `fromOption : a -> Option a -> a` — extract value or fall back to default (also known as `withDefault` in some langs)
  - ✅ `toResult : e -> Option a -> Result e a` — `Some x → Ok x`, `None → Err e`
  - ✅ `fromResult : Result e a -> Option a` — `Ok x → Some x`, `Err _ → None` *(was named `toOption` in earlier draft)*
  - ✅ Instances: `Eq (Option a)`, `Ord (Option a)`, `Show (Option a)`, `Mappable Option`, `Foldable Option`, `Applicative Option`, `Thenable Option`

- ✅ `Result e a` — `Ok a | Err e` — success-or-error value
  Helpers:
  - ✅ `isOk : Result e a -> Bool` — true if `Ok _`
  - ✅ `isErr : Result e a -> Bool` — true if `Err _`
  - ✅ `fromResultOr : a -> Result e a -> a` — extract `Ok` value or fall back to default (renamed from the earlier draft's `fromResult` to avoid collision with `Option`'s)
  - ✅ `mapErr : (e -> f) -> Result e a -> Result f a` — apply to the `Err` side, pass `Ok` through
  - ✅ Instances: `Eq (Result e a)`, `Ord (Result e a)`, `Show (Result e a)`, `Mappable (Result e)`, `Thenable (Result e)`

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
- ✅ `impl Show` for every built-in type and for `Option`, `Result`, `List`, tuples (and `Array`, in `array.mdk`)
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

- ⏳ `zip : List a -> List b -> List (a, b)` — pair up elements; result length is the shorter input
- ⏳ `zip3 : List a -> List b -> List c -> List (a, b, c)` — triple-up version of `zip`
- ⏳ `zipWith : (a -> b -> c) -> List a -> List b -> List c` — generalised `zip`; result length is the shorter input
- ⏳ `unzip : List (a, b) -> (List a, List b)` — split a list of pairs into two parallel lists

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
- ✅ `impl Show (List a)` where `Show a` — bracketed comma-separated form *(in `core.mdk`)*
- ✅ `impl Mappable List` — *(in `core.mdk`)*
- ✅ `impl Foldable List` — *(in `core.mdk`)*
- ✅ `impl Filterable List` — *(in `core.mdk`)*
- ✅ `impl Applicative List` — *(in `core.mdk`)*
- ✅ `impl Thenable List` — *(in `core.mdk`)*
- ⏳ `impl Semigroup (List a)` — concatenation (currently driven by the `++` dispatch path)
- ✅ `impl Monoid (List a)` — *(in `core.mdk`)*

---

## Module 3 — `string` ✅ implemented (kernel Phase 75; `string.mdk` complete)

Depends on `core`. Also provides `Char` utilities. File `stdlib/string.mdk`
currently contains only an `import` line (the `Show String`/`Show Char` impls).

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
- 🟡 `toUpper`/`toLower` for a single `Char` — call the kernel externs `charToUpper`/`charToLower` directly; the `String`-level `toUpper`/`toLower` (full Unicode) own those names in this module
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

- 🟡 `length`/`isEmpty` — intentionally not defined (would clash with the `Foldable` methods); use the global `stringLength`, or `s == ""`
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
- ✅ `impl Show String` — quoted, escaped (in `string.mdk`, via `showStringLit`)
- ✅ `impl Semigroup String` — in `core.mdk` (alongside `Monoid String`)
- ✅ `impl Eq Char` — *(in `core.mdk`)*
- ✅ `impl Ord Char` — codepoint order *(in `core.mdk`)*
- ✅ `impl Show Char` — quoted (in `string.mdk`, via `showCharLit`)

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
4. **Typeclass impls**: `Mappable`, `Foldable`, `Filterable`, `Semigroup`,
   `Monoid`, `Eq`.  Deliberately *not* `Applicative` / `Thenable` — the natural
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

### Mutation (effectful — modify in place)

- ✅ `set : Int -> a -> Array a -> <Mut> Unit` — bounds-checked write (panics on OOB)
- ✅ `swap : Int -> Int -> Array a -> <Mut> Unit`
- ✅ `fill : a -> Array a -> <Mut> Unit`
- ✅ `sortInPlace : Ord a => Array a -> <Mut> Unit`
- ✅ `sortInPlaceBy : (a -> a -> Ordering) -> Array a -> <Mut> Unit`

### Folds and search

- 🟡 `fold`, `foldRight`, `any`, `all` — via `impl Foldable Array` + core helpers
- ✅ `find : (a -> Bool) -> Array a -> Option a` — first match, or `None` (array-specific short-circuiting version)
- ✅ `findIndex : (a -> Bool) -> Array a -> Option Int` — index of the first match
- 🟡 `elem`, `sum`, `product`, `maximum`, `minimum` — **no longer array-specific**: the generic `Foldable` versions in `core` dispatch over `impl Foldable Array` (same tight loop), so the array copies were removed as redundant

### Sorting (pure)

- ✅ `sort : Ord a => Array a -> Array a` — fresh sorted copy (kernel-level `arraySortBy compare`)
- ✅ `sortBy : (a -> a -> Ordering) -> Array a -> Array a`
- ✅ `sortOn : Ord b => (a -> b) -> Array a -> Array a`

### Instances

- ✅ `impl Eq (Array a)` where `Eq a` — element-wise
- ✅ `impl Show (Array a)` where `Show a` — bracketed `[|1, 2, 3|]` form (now unblocked: `Show Int`/`Float`/… landed in core)
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
- **Instances:** ✅ `Mappable (Map k)` (over values), `Eq`/`Show` (via the
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
- **Instances:** `Foldable Set`, `Eq`/`Show` (via the ascending element list),
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
**mutable** hash containers. Updates mutate in place (`<Mut>` in the signature)
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
  allocates its own table), `fromList : Eq k => List (k, v) -> <Mut> HashMap k v`.
- **Query (pure):** `size` (O(1)), `isEmpty`, `get`, `member`, `findWithDefault`.
- **Mutation (`<Mut>`):** `insert` (overwrites), `delete`.
- **Iteration (pure, unspecified order):** `entries` (the pairs), `toList`
  (alias of `entries`), `keys`, `values`.
- **Instances:** `Eq` (order-independent — same entries), `Show` (`fromList […]`
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
- **Mutation (`<Mut>`):** `insert`, `delete`.
- **Instances:** `Foldable`, `Eq` (order-independent), `Show`.
- 7 doctests.

### `mut_array` ⏳ unstarted

A growable mutable array (vector) over the fixed-size `Array`. Not yet built.

### Compiler notes

- New `hash : a -> Int` extern (runtime.mdk + eval.ml) — structural,
  non-negative (`Hashtbl.hash`).
- Removed `"HashMap"`/`"HashSet"` from `resolve.ml`'s `primitive_types` (reserved
  placeholders), mirroring the `Map`/`Set` removals.
- Surfaced two language gaps (PLAN.md): **Phase 118** (`if`/`else` branches can't
  be multi-statement blocks — use guards) and **Phase 119** (false-positive
  non-exhaustiveness for 3+-arg list-matching functions — use a `where go`
  single-list-arg helper). Both have clean workarounds used in these modules.

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
- ✅ Mutation (`<Mut>`): `push` (amortized O(1), doubling), `pop` (returns
  `Option`), `set` (panics OOB), `swap`, `clear` (keeps capacity), `mapInPlace`
- ✅ Instances: `Foldable MutArray` (index-based folds, never allocates a list),
  `Eq` (element-wise over the live range), `Show` (`fromList [..]`)
- 11 doctests. **Skipped:** `Mappable` (use `mapInPlace`, or `toList`→`map`);
  growth/shrink heuristics beyond doubling.

**Cross-module dispatch limitation (pre-existing, language-level).** Direct
`Foldable` method calls on an imported instance work across the loader
(`length v`, `toList v`, `push`/`pop`/…), but a **generic `Foldable`-derived
function that threads a dictionary internally** — `sum`, `product`, `maximum`,
`minimum` — panics `no matching impl for dispatch` when its argument's instance
comes from an *imported* module. This is **not** specific to `mut_array`:
`sum (array.fromList [1,2,3])` fails identically on `main`, as do `map`/`set`/
`hash_*`. The single-file doctest path threads the dict correctly (so the
`sum`/`length` doctests pass). Root cause is the cross-module dict-passing gap
tracked in the dict-passing internals notes; filed for a future phase.
