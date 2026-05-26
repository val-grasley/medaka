# Medaka Standard Library Plan

This document lists what belongs in the first four stdlib modules. It is a
checklist, not a spec: implementation order within a module is yours to choose.
No code snippets — just the names, grouped so nothing slips through.

Work interactively via the REPL (`:load stdlib/core.mdk`, `:reload` after edits).
Expect to discover language gaps as you go; record them in PLAN.md §5.

---

## Module 1 — `core`

The foundation every other module depends on. Implement this first.

### Interfaces

- `Eq a` — equality comparison
  - `eq : a -> a -> Bool`
  - `neq : a -> a -> Bool` (default: `not (eq x y)`)
    — *move to standalone once constraint syntax lands; as a method it allows
    inconsistent implementations where `neq` disagrees with `eq`*

- `Ord a` requires `Eq a` — total ordering
  - `compare : a -> a -> Ordering`
  - `lt : a -> a -> Bool` (default from `compare`)
    — *keep as method; direct comparison can be faster than `compare` + pattern match*
  - `gt : a -> a -> Bool` (default from `compare`) — *same, keep as method*
  - `lte : a -> a -> Bool` (default from `compare`) — *same, keep as method*
  - `gte : a -> a -> Bool` (default from `compare`) — *same, keep as method*
  - `min : a -> a -> a` (default from `compare`) — *keep as method; override for NaN semantics etc.*
  - `max : a -> a -> a` (default from `compare`) — *same, keep as method*
  - `clamp : a -> a -> a -> a` (default from `min`/`max`)
    — *move to standalone once constraint syntax lands; purely derivable, no reason to override*

- `Show a` — human-readable string representation
  - `show : a -> String`

- `Num a` of `Eq a` — numeric arithmetic (already seeded as a builtin)
  - `add : a -> a -> a`
  - `sub : a -> a -> a`
  - `mul : a -> a -> a`
  - `div : a -> a -> a`
  - `negate : a -> a`
  - `abs : a -> a`
  - `signum : a -> a`
  - `fromInt : Int -> a`

- `Bounded a` — types with a minimum and maximum value
  - `minBound : a`
  - `maxBound : a`

- `Mappable f` — structure-preserving map (Functor)
  - `map : (a -> b) -> f a -> f b`

- `Foldable t` — collapsible into a summary value
  - `fold : (b -> a -> b) -> b -> t a -> b`
  - `foldRight : (a -> b -> b) -> b -> t a -> b`
  - `toList : t a -> List a`
  - `isEmpty : t a -> Bool` (default via `toList`; override for O(1) structures)
  - `length : t a -> Int` (default via `fold`; override for O(1) structures)

  The following are **standalone functions** (not interface methods) because they
  require additional constraints (`Eq a`, `Num a`) that cannot be expressed in
  interface member types until Medaka gains constraint syntax in signatures:
  - `any : Foldable t => (a -> Bool) -> t a -> Bool`
  - `all : Foldable t => (a -> Bool) -> t a -> Bool`
  - `find : Foldable t => (a -> Bool) -> t a -> Option a`
  - `count : Foldable t => (a -> Bool) -> t a -> Int`
  - `sum : (Foldable t, Num a) => t a -> a`
  - `product : (Foldable t, Num a) => t a -> a`
  - `elem : (Foldable t, Eq a) => a -> t a -> Bool`

- `Applicative f` of `Mappable f`
  - `pure : a -> f a`
  - `ap : f (a -> b) -> f a -> f b`

- `Monad m` requires `Applicative m`
  - `andThen : m a -> (a -> m b) -> m b` (flatMap / bind)
  - `flatMap : (a -> m b) -> m a -> m b` (default: `flip andThen`)
  - `join : m (m a) -> m a` (default: `andThen identity`)
  - `when : Bool -> m Unit -> m Unit` (default)
  - `unless : Bool -> m Unit -> m Unit` (default)

  `flatMap`, `join`, `when`, `unless` are purely definitional aliases with no
  reason to override — *move all four to standalone functions once constraint
  syntax lands*

### Data types

- `Ordering` — `Lt | Eq | Gt`

- `Option a` — already a builtin; add instances and helpers:
  - `isSome : Option a -> Bool`
  - `isNone : Option a -> Bool`
  - `fromOption : a -> Option a -> a`
  - `mapOption : (a -> b) -> Option a -> Option b`
  - `withDefault : a -> Option a -> a`
  - `toResult : e -> Option a -> Result e a`
  - Instances: `Eq (Option a)`, `Ord (Option a)`, `Show (Option a)`,
    `Mappable Option`, `Foldable Option`, `Applicative Option`, `Monad Option`

- `Result e a` — already a builtin; add instances and helpers:
  - `isOk : Result e a -> Bool`
  - `isErr : Result e a -> Bool`
  - `fromResult : a -> Result e a -> a`
  - `mapResult : (a -> b) -> Result e a -> Result e b`
  - `mapErr : (e -> f) -> Result e a -> Result f a`
  - `andThenResult : Result e a -> (a -> Result e b) -> Result e b`
  - `toOption : Result e a -> Option a`
  - `fromOption : e -> Option a -> Result e a`
  - Instances: `Eq (Result e a)`, `Show (Result e a)`,
    `Mappable (Result e)`, `Monad (Result e)`

### Utility functions

- `identity : a -> a`
- `const : a -> b -> a`
- `flip : (a -> b -> c) -> b -> a -> c`
- `compose : (b -> c) -> (a -> b) -> a -> c`
- `pipe : (a -> b) -> (b -> c) -> a -> c`
- `apply : (a -> b) -> a -> b`
- `not : Bool -> Bool`
- `and : Bool -> Bool -> Bool`
- `or : Bool -> Bool -> Bool`
- `xor : Bool -> Bool -> Bool`
- `panic : String -> a` (wrapper around the extern)

---

## Module 2 — `list`

Depends on `core`. Implement all List operations here; the `extern` primitives
`map`, `filter`, `fold` can be re-exported or superseded.

### Construction

- `empty : List a`
- `singleton : a -> List a`
- `range : Int -> Int -> List Int`
- `rangeStep : Int -> Int -> Int -> List Int`
- `replicate : Int -> a -> List a`
- `iterate : Int -> (a -> a) -> a -> List a`
- `unfold : (b -> Option (a, b)) -> b -> List a`

### Observation

- `isEmpty : List a -> Bool`
- `length : List a -> Int`
- `head : List a -> Option a`
- `tail : List a -> Option (List a)`
- `last : List a -> Option a`
- `init : List a -> Option (List a)`
- `get : Int -> List a -> Option a`

### Transformation

- `map : (a -> b) -> List a -> List b`
- `filter : (a -> Bool) -> List a -> List a`
- `filterMap : (a -> Option b) -> List a -> List b`
- `reverse : List a -> List a`
- `concat : List (List a) -> List a`
- `concatMap : (a -> List b) -> List a -> List b`
- `flatten : List (List a) -> List a`
- `intersperse : a -> List a -> List a`
- `intercalate : List a -> List (List a) -> List a`
- `transpose : List (List a) -> List (List a)`
- `subsequences : List a -> List (List a)`
- `permutations : List a -> List (List a)`

### Folds and scans

- `fold : (b -> a -> b) -> b -> List a -> b`
- `foldRight : (a -> b -> b) -> b -> List a -> b`
- `foldMap : Monoid m => (a -> m) -> List a -> m` — *blocked: `Monoid` is not defined anywhere in this plan; add a `Monoid` interface to `core` or drop this function*
- `scanLeft : (b -> a -> b) -> b -> List a -> List b`
- `scanRight : (a -> b -> b) -> b -> List a -> List b`
- `sum : List Int -> Int`
- `sumFloat : List Float -> Float`
- `product : List Int -> Int`
- `maximum : Ord a => List a -> Option a`
- `minimum : Ord a => List a -> Option a`

### Search

- `elem : Eq a => a -> List a -> Bool`
- `notElem : Eq a => a -> List a -> Bool`
- `find : (a -> Bool) -> List a -> Option a`
- `findIndex : (a -> Bool) -> List a -> Option Int`
- `findIndices : (a -> Bool) -> List a -> List Int`
- `elemIndex : Eq a => a -> List a -> Option Int`
- `any : (a -> Bool) -> List a -> Bool`
- `all : (a -> Bool) -> List a -> Bool`
- `count : (a -> Bool) -> List a -> Int`

### Sublists

- `take : Int -> List a -> List a`
- `drop : Int -> List a -> List a`
- `takeWhile : (a -> Bool) -> List a -> List a`
- `dropWhile : (a -> Bool) -> List a -> List a`
- `span : (a -> Bool) -> List a -> (List a, List a)`
- `break : (a -> Bool) -> List a -> (List a, List a)`
- `splitAt : Int -> List a -> (List a, List a)`
- `slice : Int -> Int -> List a -> List a`
- `chunks : Int -> List a -> List (List a)`

### Zipping and combining

- `zip : List a -> List b -> List (a, b)`
- `zip3 : List a -> List b -> List c -> List (a, b, c)`
- `zipWith : (a -> b -> c) -> List a -> List b -> List c`
- `unzip : List (a, b) -> (List a, List b)`

### Sorting

- `sort : Ord a => List a -> List a`
- `sortBy : (a -> a -> Ordering) -> List a -> List a`
- `sortOn : Ord b => (a -> b) -> List a -> List a`
- `nub : Eq a => List a -> List a`
- `nubBy : (a -> a -> Bool) -> List a -> List a`

### Grouping

- `group : Eq a => List a -> List (List a)`
- `groupBy : (a -> a -> Bool) -> List a -> List (List a)`
- `partition : (a -> Bool) -> List a -> (List a, List a)`
- `tally : Eq a => List a -> List (a, Int)`

### Instances

- `impl Eq (List a)` where `Eq a`
- `impl Ord (List a)` where `Ord a`
- `impl Show (List a)` where `Show a`
- `impl Mappable List`
- `impl Foldable List`
- `impl Applicative List`
- `impl Monad List`

---

## Module 3 — `string`

Depends on `core`. Also provides `Char` utilities.

### Char operations

- `isDigit : Char -> Bool`
- `isAlpha : Char -> Bool`
- `isAlphaNum : Char -> Bool`
- `isSpace : Char -> Bool`
- `isUpper : Char -> Bool`
- `isLower : Char -> Bool`
- `isPunct : Char -> Bool`
- `toUpper : Char -> Char`
- `toLower : Char -> Char`
- `digitToInt : Char -> Option Int`
- `intToDigit : Int -> Option Char`
- `charCode : Char -> Int`
- `charFromCode : Int -> Option Char`

### Conversion

- `fromChar : Char -> String`
- `toChars : String -> List Char`
- `fromChars : List Char -> String`
- `toString : Show a => a -> String`
- `toInt : String -> Option Int`
- `toFloat : String -> Option Float`
- `fromInt : Int -> String`
- `fromFloat : Float -> String`

### Inspection

- `length : String -> Int`
- `isEmpty : String -> Bool`
- `startsWith : String -> String -> Bool`
- `endsWith : String -> String -> Bool`
- `contains : String -> String -> Bool`
- `indexOf : String -> String -> Option Int`
- `lastIndexOf : String -> String -> Option Int`
- `count : String -> String -> Int`

### Transformation

- `append : String -> String -> String`
- `prepend : String -> String -> String`
- `concat : List String -> String`
- `join : String -> List String -> String`
- `repeat : Int -> String -> String`
- `reverse : String -> String`
- `trim : String -> String`
- `trimLeft : String -> String`
- `trimRight : String -> String`
- `toUpper : String -> String`
- `toLower : String -> String`
- `capitalize : String -> String`
- `replace : String -> String -> String -> String`
- `replaceAll : String -> String -> String -> String`

### Slicing and splitting

- `slice : Int -> Int -> String -> String`
- `take : Int -> String -> String`
- `drop : Int -> String -> String`
- `split : String -> String -> List String`
- `splitAt : Int -> String -> (String, String)`
- `lines : String -> List String`
- `words : String -> List String`
- `unlines : List String -> String`
- `unwords : List String -> String`

### Padding

- `padLeft : Int -> Char -> String -> String`
- `padRight : Int -> Char -> String -> String`
- `center : Int -> Char -> String -> String`

### Instances

- `impl Eq String` (already in Ord built-in; formalize here)
- `impl Ord String`
- `impl Show String`
- `impl Eq Char`
- `impl Ord Char`
- `impl Show Char`

---

## Module 4 — `array`

Depends on `core`. Arrays are fixed-size and support O(1) random access.
Mutations use `Ref` or `let mut` internally; the external API can be pure or
effectful, depending on what the language exposes cleanly.

### Construction

- `make : Int -> a -> Array a`
- `makeWith : Int -> (Int -> a) -> Array a`
- `fromList : List a -> Array a`
- `singleton : a -> Array a`
- `empty : Array a`
- `range : Int -> Int -> Array Int`
- `replicate : Int -> a -> Array a`
- `copy : Array a -> Array a`

### Observation

- `length : Array a -> Int`
- `isEmpty : Array a -> Bool`
- `get : Int -> Array a -> Option a`
- `getUnsafe : Int -> Array a -> a`
- `first : Array a -> Option a`
- `last : Array a -> Option a`
- `toList : Array a -> List a`

### Transformation (pure — return new arrays)

- `map : (a -> b) -> Array a -> Array b`
- `filter : (a -> Bool) -> Array a -> Array a`
- `filterMap : (a -> Option b) -> Array a -> Array b`
- `reverse : Array a -> Array a`
- `slice : Int -> Int -> Array a -> Array a`
- `take : Int -> Array a -> Array a`
- `drop : Int -> Array a -> Array a`
- `append : Array a -> Array a -> Array a`
- `concat : Array (Array a) -> Array a`
- `zip : Array a -> Array b -> Array (a, b)`
- `zipWith : (a -> b -> c) -> Array a -> Array b -> Array c`
- `unzip : Array (a, b) -> (Array a, Array b)`

### Mutation (effectful — modify in place)

- `set : Int -> a -> Array a -> <Mut> Unit`
- `swap : Int -> Int -> Array a -> <Mut> Unit`
- `fill : a -> Array a -> <Mut> Unit`
- `sortInPlace : Ord a => Array a -> <Mut> Unit`
- `sortInPlaceBy : (a -> a -> Ordering) -> Array a -> <Mut> Unit`

### Folds and search

- `fold : (b -> a -> b) -> b -> Array a -> b`
- `foldRight : (a -> b -> b) -> b -> Array a -> b`
- `any : (a -> Bool) -> Array a -> Bool`
- `all : (a -> Bool) -> Array a -> Bool`
- `find : (a -> Bool) -> Array a -> Option a`
- `findIndex : (a -> Bool) -> Array a -> Option Int`
- `elem : Eq a => a -> Array a -> Bool`
- `sum : Array Int -> Int`
- `product : Array Int -> Int`
- `maximum : Ord a => Array a -> Option a`
- `minimum : Ord a => Array a -> Option a`

### Sorting (pure)

- `sort : Ord a => Array a -> Array a`
- `sortBy : (a -> a -> Ordering) -> Array a -> Array a`
- `sortOn : Ord b => (a -> b) -> Array a -> Array a`

### Instances

- `impl Eq (Array a)` where `Eq a`
- `impl Show (Array a)` where `Show a`
- `impl Mappable Array`
- `impl Foldable Array`
