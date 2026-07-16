# META
source_lines=1590
stages=DESUGAR,MARK
# SOURCE
{- core.mdk — the foundation every other Medaka module rests on.

   This file is automatically prepended to every program by the compiler
   (see lib/prelude.ml), so everything declared here is in scope without
   an `import`.  See STDLIB.md for the full plan and Module 1 checklist.

   Layout:
     1. Foundational data types (Ordering, Option, Result)
     2. Interface hierarchy in dependency order:
          Eq → Ord, Semigroup → Monoid, Debug, Num, Bounded,
          Mappable → Applicative → Thenable, Foldable
        Each interface is followed by its impls for built-in types.
     3. Standalone helpers (Bool, Option, Result, Foldable, utility)
     4. Arbitrary (property-testing generator interface)

   Style notes:
     * Strict evaluation: prefer tail-recursive helpers in `where` clauses
       over right-leaning recursion when traversing potentially-large data.
     * `default` on an impl is only required when more than one impl is
       visible for the same head; we mark the `Result e` instances `default`
       so a user can later add an `Err`-mapping variant. -}

-- ─── 1. Data types ──────────────────────────────────────────────────────

-- | Three-way comparison result, produced by `Ord.compare`.
public export data Ordering = Lt | Eq | Gt

{- | A value that may be absent.  Medaka's name for Haskell's `Maybe`.

   > isSome (Some 1)
   True
   > isSome None
   False -}
public export data Option a = Some a | None

{- | A computation that either succeeded with `Ok a` or failed with `Err e`.
   Errors are data; pattern-match to handle them.  See language-design.md.

   > isOk (Ok 1)
   True
   > isOk (Err "boom")
   False -}
public export data Result e a = Ok a | Err e

-- ─── 2. Interfaces and built-in impls ───────────────────────────────────

{- | Structural equality.  Reflexive, symmetric, transitive.
   `==` on primitives is a builtin and does *not* dispatch through this
   interface; the impls below exist so generic `Eq a => ...` code works. -}
export interface Eq a where
  eq : a -> a -> Bool

-- | Negation of `eq`.  Standalone so impls cannot make it disagree with `eq`.
export neq : Eq a => a -> a -> Bool
neq x y = not (eq x y)

export impl Eq Int where
  eq a b = a == b

export impl Eq Float where
  eq a b = a == b

export impl Eq Bool where
  eq a b = a == b

export impl Eq String where
  eq a b = a == b

export impl Eq Char where
  eq a b = a == b

export impl Eq Unit where
  eq _ _ = True

export impl Eq (List a) requires Eq a where
  eq [] [] = True
  eq (x::xs) (y::ys) = eq x y && eq xs ys
  eq _ _ = False

export impl Eq (Option a) requires Eq a where
  eq None None = True
  eq (Some x) (Some y) = eq x y
  eq _ _ = False

export impl Eq (Result e a) requires Eq e, Eq a where
  eq (Ok x) (Ok y) = eq x y
  eq (Err x) (Err y) = eq x y
  eq _ _ = False

-- Structural equality for tuples (arities 2–5): equal iff every field is.
export impl Eq (a, b) requires Eq a, Eq b where
  eq (a1, b1) (a2, b2) = eq a1 a2 && eq b1 b2

export impl Eq (a, b, c) requires Eq a, Eq b, Eq c where
  eq (a1, b1, c1) (a2, b2, c2) = eq a1 a2 && eq b1 b2 && eq c1 c2

export impl Eq (a, b, c, d) requires Eq a, Eq b, Eq c, Eq d where
  eq (a1, b1, c1, d1) (a2, b2, c2, d2) = eq a1 a2
    && eq b1 b2
    && eq c1 c2
    && eq d1 d2

export impl Eq (a, b, c, d, e) requires Eq a, Eq b, Eq c, Eq d, Eq e where
  eq (a1, b1, c1, d1, e1) (a2, b2, c2, d2, e2) = eq a1 a2
    && eq b1 b2
    && eq c1 c2
    && eq d1 d2
    && eq e1 e2

{- | Associative combine.  Backs the `++` operator and is the parent of
   `Monoid`.  Implementations *must* satisfy
       append a (append b c) == append (append a b) c. -}
export interface Semigroup a where
  append : a -> a -> a

export impl Semigroup (List a) where
  append xs ys = xs ++ ys

export impl Semigroup String where
  append s1 s2 = s1 ++ s2

{- | A `Semigroup` with an identity element.  Laws:
       append empty x == x       (left identity)
       append x empty == x       (right identity) -}
export interface Monoid a requires Semigroup a where
  empty : a

export impl Monoid (List a) where
  empty = []

export impl Monoid String where
  empty = ""

{- | Total ordering.  `compare` is the primitive method; the comparison
   helpers all have defaults expressed through it, but impls may override
   any of them for performance or to encode special semantics (e.g. NaN). -}
export interface Ord a requires Eq a where
  compare : a -> a -> Ordering
  lt : a -> a -> Bool
  gt : a -> a -> Bool
  lte : a -> a -> Bool
  gte : a -> a -> Bool
  min : a -> a -> a
  max : a -> a -> a
  lt x y = match compare x y
    Lt => True
    _ => False
  gt x y = match compare x y
    Gt => True
    _ => False
  lte x y = match compare x y
    Gt => False
    _ => True
  gte x y = match compare x y
    Lt => False
    _ => True
  min x y = match compare x y
    Gt => y
    _ => x
  max x y = match compare x y
    Lt => y
    _ => x

{- | `clamp lo hi x` constrains `x` into the inclusive interval `[lo, hi]`.
   Precondition: `lo <= hi`; otherwise the result is `lo`.

   > clamp 0 10 5
   5
   > clamp 0 10 (-3)
   0
   > clamp 0 10 99
   10 -}
export clamp : Ord a => a -> a -> a -> a
clamp lo hi = min hi >> max lo

{- | `isEven n` is `True` when `n` is divisible by 2 (negatives included).

   > isEven 4
   True
   > isEven 7
   False -}
export isEven : Int -> Bool
isEven n = n % 2 == 0

{- | `isOdd n` is `True` when `n` is not divisible by 2.

   > isOdd 3
   True
   > isOdd 8
   False -}
export isOdd : Int -> Bool
isOdd n = n % 2 != 0

export impl Ord Int where
  compare a b = if a < b then Lt else if a > b then Gt else Eq

-- | `True` when `x`'s IEEE-754 sign bit is set.  Deliberately NOT `x < 0.0`:
-- this also holds for −0.0 (which compares EQUAL to +0.0) and for −NaN (which
-- compares False against everything), and those two are exactly the cases no
-- arithmetic predicate can see.  Reads the sign out of the big-endian IEEE
-- encoding, so it costs an 8-byte Array; `compare` reaches it only for zeros
-- and NaNs, never on the ordered hot path.
floatSignBit : Float -> Bool
floatSignBit x = arrayGetUnsafe 0 (floatToBytes64 x) >= 128

-- | totalOrder tie-break for two Floats that are EQUAL under IEEE `==`.  The
-- only such pair that totalOrder separates is −0.0 < +0.0; every other equal
-- pair shares a sign and stays `Eq`.
compareBySign : Float -> Float -> Ordering
compareBySign a b = match (floatSignBit a, floatSignBit b)
  (True, False) => Lt
  (False, True) => Gt
  _ => Eq

-- | totalOrder for a pair where `< > ==` were ALL False — i.e. at least one
-- operand is a NaN.  −NaN sits below every non-NaN, +NaN above every non-NaN;
-- two NaNs of the same sign are `Eq`.  `x != x` is the NaN test (IEEE's only
-- self-inequality); it is inlined rather than calling `isNaN`, which lives in
-- `math.mdk` — the prelude cannot import it, and this is not a big enough
-- reason to promote it into the prelude's public surface.
compareNaN : Float -> Float -> Ordering
compareNaN a b
  | a != a && b != b = compareBySign a b
  | a != a = if floatSignBit a then Lt else Gt
  | otherwise = if floatSignBit b then Gt else Lt

{- | `Ord Float` is IEEE-754 **totalOrder** (issue #360):

     −NaN < −inf < … < −0.0 < +0.0 < … < +inf < +NaN

   so `compare`, `min`/`max` and therefore `sort` are deterministic on NaN data
   and never crash.  The previous `if a < b … else Eq` shape returned `Eq` for
   `compare nan x` at EVERY `x`, which is not a total order at all: it broke
   transitivity (`nan Eq 1.0` and `nan Eq 3.0`, yet `1.0 != 3.0`), so a sorted
   result was only an accident of the algorithm.

   Deliberate divergence: `compare x y == Eq` no longer coincides with `x == y`
   at NaN and −0.0.  `Ord`'s total order and `Eq`'s IEEE equality genuinely
   disagree at those two points — the trade Rust's `f64::total_cmp` and Java's
   `Double.compare` make too.

   ⚠️  The four relational overrides below are LOAD-BEARING, do not delete them.
   `< <= > >=` at Float are primitive IEEE predicates on every path, and all
   four are False at a NaN operand (EMITTER-SEMANTICS N5, issue #305).  Ord's
   interface DEFAULTS derive them from `compare`, so without these overrides the
   Float dict would hand them totalOrder and silently make `nan < 1.0` True —
   re-opening the S0 that #305 closed.  `min`/`max` keep their compare-derived
   defaults on purpose: they are not IEEE predicates, and #360 asks for them to
   be total. -}
-- (guards are not accepted in an impl method body — hence the `if` chain)
export impl Ord Float where
  compare a b =
    if a < b then
      Lt
    else if a > b then
      Gt
    else if a == b then
      compareBySign a b
    else
      compareNaN a b
  lt a b = a < b
  gt a b = a > b
  lte a b = a <= b
  gte a b = a >= b

export impl Ord String where
  compare a b = if a < b then Lt else if a > b then Gt else Eq

export impl Ord Char where
  compare a b = if a < b then Lt else if a > b then Gt else Eq

-- | Lexicographic chaining: take the first non-`Eq` result, else the second.
-- Private helper backing the tuple `Ord` impls below.
thenCmp : Ordering -> Ordering -> Ordering
thenCmp Eq o = o
thenCmp o _ = o

-- Lexicographic ordering for tuples (arities 2–5): compare field by field,
-- left to right, stopping at the first that differs.
export impl Ord (a, b) requires Ord a, Ord b where
  compare (a1, b1) (a2, b2) = thenCmp (compare a1 a2) (compare b1 b2)

export impl Ord (a, b, c) requires Ord a, Ord b, Ord c where
  compare (a1, b1, c1) (a2, b2, c2) =
    thenCmp (compare a1 a2) (thenCmp (compare b1 b2) (compare c1 c2))

export impl Ord (a, b, c, d) requires Ord a, Ord b, Ord c, Ord d where
  compare (a1, b1, c1, d1) (a2, b2, c2, d2) =
    thenCmp
      (compare a1 a2)
      (thenCmp (compare b1 b2) (thenCmp (compare c1 c2) (compare d1 d2)))

export impl Ord (a, b, c, d, e) requires Ord a, Ord b, Ord c, Ord d, Ord e where
  compare (a1, b1, c1, d1, e1) (a2, b2, c2, d2, e2) =
    thenCmp
      (compare a1 a2)
      (thenCmp
        (compare b1 b2)
        (thenCmp (compare c1 c2) (thenCmp (compare d1 d2) (compare e1 e2))))

{- | Lexicographic ordering: compare element-wise, and a proper prefix sorts
   before any list that extends it (`[1] < [1, 2]`, `[] < [0]`). -}
export impl Ord (List a) requires Ord a where
  compare [] [] = Eq
  compare [] _ = Lt
  compare _ [] = Gt
  compare (x::xs) (y::ys) = thenCmp (compare x y) (compare xs ys)

-- | `None` sorts before every `Some`; two `Some`s compare by their contents.
export impl Ord (Option a) requires Ord a where
  compare None None = Eq
  compare None (Some _) = Lt
  compare (Some _) None = Gt
  compare (Some x) (Some y) = compare x y

-- | `Err` sorts before `Ok`; like constructors compare by their payloads.
export impl Ord (Result e a) requires Ord e, Ord a where
  compare (Err x) (Err y) = compare x y
  compare (Err _) (Ok _) = Lt
  compare (Ok _) (Err _) = Gt
  compare (Ok x) (Ok y) = compare x y

{- | Human-readable string rendering.  Backs `medaka test` doctests, which
   compare a result's `debug` against the expected text (GHCi/doctest parity).
   `Debug Int`/`Float`/`Bool`/`Unit`/`List`/`Option`/`Result` and the tuple
   impls live here; `Debug String`/`Debug Char` live in `string.mdk`.
   Numeric/Bool `debug` matches the interpreter's `pp_value` (so it agrees with
   `println`); `String`/`Char` render *quoted* (round-trippable, so `debug`
   intentionally differs from `println` — cf. Haskell `debug` vs `putStr`). -}
export interface Debug a where
  debug : a -> String

export impl Debug Int where
  debug n = intToString n

export impl Debug Float where
  debug x = floatToString x

export impl Debug Bool where
  debug True = "True"
  debug False = "False"

export impl Debug Unit where
  debug _ = "()"

export impl Debug Ordering where
  debug Lt = "Lt"
  debug Eq = "Eq"
  debug Gt = "Gt"

-- Eq/Ord for Ordering are HAND-WRITTEN (not `deriving`): the `Eq` data
-- CONSTRUCTOR collides with the `Eq` class name, so `deriving (Eq)` is
-- ambiguous.  Without these, `o == Lt` check-accepts and `run`s but `build`
-- FAILS (no Ord/Eq Ordering binary).  Rank Lt < Eq < Gt.
export impl Eq Ordering where
  eq Lt Lt = True
  eq Eq Eq = True
  eq Gt Gt = True
  eq _ _ = False

export impl Ord Ordering where
  compare Lt Lt = Eq
  compare Lt _ = Lt
  compare _ Lt = Gt
  compare Eq Eq = Eq
  compare Eq _ = Lt
  compare _ Eq = Gt
  compare Gt Gt = Eq

-- `Debug String`/`Debug Char` render a *quoted, escaped literal* (`debug "hi"` is
-- `"hi"`, `debug 'a'` is `'a'`) via the `debugStringLit`/`debugCharLit` externs —
-- round-trippable, matching Haskell, and distinct from `println`'s raw output.
-- They live here in the prelude (not `string.mdk`) so that `debug`-ing a String
-- or Char — the most common doctest result type — resolves without importing
-- `string`, alongside the other primitive `Debug` impls (Phase 92).
export impl Debug String where
  debug s = debugStringLit s

export impl Debug Char where
  debug c = debugCharLit c

-- Comma-joined element rendering for `Debug (List a)`: a top-level recursive
-- constrained helper.  Its self-call forwards the `Debug a` dictionary and the
-- impl body forwards its own `requires Debug a` dict into it (Phase 74 follow-up
-- fix to dictionary passing for recursive constrained functions).
debugListItems : Debug a => List a -> String
debugListItems [] = ""
debugListItems [x] = debug x
debugListItems (y::rest) = "\{debug y}, \{debugListItems rest}"

export impl Debug (List a) requires Debug a where
  debug xs = "[\{debugListItems xs}]"

-- Comma-joined element rendering for `Debug (Array a)`, mirroring
-- `debugListItems` but recursing by index (arrays aren't cons-lists) so it
-- allocates no intermediate list.
debugArrayItems : Debug a => Array a -> Int -> Int -> String
debugArrayItems arr i n
  | i >= n = ""
  | i == n - 1 = debug (arrayGetUnsafe i arr)
  | otherwise =
    "\{debug (arrayGetUnsafe i arr)}, \{debugArrayItems arr (i + 1) n}"

{- | Bracketed, comma-separated rendering matching the interpreter's printer
   (`[|1, 2, 3|]`), so `debug` agrees with `println` on arrays.  Lives in
   `core.mdk` (not `array.mdk`) so array literals render without an explicit
   `import array`.

   > debug [|1, 2, 3|] == "[|1, 2, 3|]"
   True -}
export impl Debug (Array a) requires Debug a where
  debug arr = "[|\{debugArrayItems arr 0 (arrayLength arr)}|]"

-- Lives in `core.mdk` (not `array.mdk`) alongside `Debug`/`Index` so
-- `deriving (Eq)` over a field of array type builds without an `import array`.
export impl Eq (Array a) requires Eq a where
  eq a b =
    if arrayLength a != arrayLength b then
      False
    else
      eqGo a b 0 (arrayLength a)

eqGo : Eq a => Array a -> Array a -> Int -> Int -> Bool
eqGo a b i n =
  if i >= n then
    True
  else if eq (arrayGetUnsafe i a) (arrayGetUnsafe i b) then
    eqGo a b (i + 1) n
  else
    False

export impl Debug (Option a) requires Debug a where
  debug None = "None"
  debug (Some x) = "Some " ++ debug x

export impl Debug (Result e a) requires Debug e, Debug a where
  debug (Ok x) = "Ok " ++ debug x
  debug (Err e) = "Err " ++ debug e

-- Tuple rendering (arities 2–5): `(a, b)`, matching the interpreter's
-- value printer.
export impl Debug (a, b) requires Debug a, Debug b where
  debug (a, b) = "(\{debug a}, \{debug b})"

export impl Debug (a, b, c) requires Debug a, Debug b, Debug c where
  debug (a, b, c) = "(\{debug a}, \{debug b}, \{debug c})"

export impl Debug (a, b, c, d) requires Debug a, Debug b, Debug c, Debug d where
  debug (a, b, c, d) = "(\{debug a}, \{debug b}, \{debug c}, \{debug d})"

export impl Debug (a, b, c, d, e) requires Debug a, Debug b, Debug c, Debug d, Debug e where
  debug (a, b, c, d, e) =
    "(\{debug a}, \{debug b}, \{debug c}, \{debug d}, \{debug e})"

{- | Display rendering for string interpolation.  A `"\{e}"` hole desugars to
   `display e`, so this is what `\{...}` calls.  Unlike `Debug`, `Display` does
   *not* quote `String`/`Char` (interpolating a string splices its characters,
   it doesn't debug a quoted literal) — this is the Debug-vs-Display split.  For
   every other type `display` matches `debug`'s output, recursing with `display`
   so nested strings stay unquoted too.  Lives in `core.mdk` (not `string.mdk`
   like `Debug String`) because interpolation is core syntax: a bare `"\{name}"`
   can't depend on an imported module.  `deriving (Display)` mirrors
   `deriving (Debug)`. -}
export interface Display a where
  display : a -> String

export impl Display Int where
  display n = intToString n

export impl Display Float where
  display x = floatToString x

export impl Display Bool where
  display True = "True"
  display False = "False"

export impl Display Unit where
  display _ = "()"

export impl Display Ordering where
  display Lt = "Lt"
  display Eq = "Eq"
  display Gt = "Gt"

export impl Display String where
  display s = s

export impl Display Char where
  display c = charToStr c

-- Comma-joined element rendering for `Display (List a)`, mirroring
-- `debugListItems`: a top-level recursive constrained helper that forwards its
-- `Display a` dictionary on the self-call.
displayListItems : Display a => List a -> String
displayListItems [] = ""
displayListItems [x] = display x
displayListItems (y::rest) = "\{y}, \{displayListItems rest}"

export impl Display (List a) requires Display a where
  display xs = "[\{displayListItems xs}]"

-- Display counterpart of `debugArrayItems`: recurses via `display` (unquoted).
displayArrayItems : Display a => Array a -> Int -> Int -> String
displayArrayItems arr i n
  | i >= n = ""
  | i == n - 1 = display (arrayGetUnsafe i arr)
  | otherwise =
    "\{display (arrayGetUnsafe i arr)}, \{displayArrayItems arr (i + 1) n}"

{- | Renders `[|1, 2, 3|]`, matching `debug` but with unquoted elements (the
   Display convention).  In `core.mdk` alongside `Debug (Array a)` so array
   literals interpolate without an explicit `import array`.

   > display [|1, 2, 3|] == "[|1, 2, 3|]"
   True -}
export impl Display (Array a) requires Display a where
  display arr = "[|\{displayArrayItems arr 0 (arrayLength arr)}|]"

export impl Display (Option a) requires Display a where
  display None = "None"
  display (Some x) = "Some " ++ display x

export impl Display (Result e a) requires Display e, Display a where
  display (Ok x) = "Ok " ++ display x
  display (Err e) = "Err " ++ display e

export impl Display (a, b) requires Display a, Display b where
  display (a, b) = "(\{a}, \{b})"

export impl Display (a, b, c) requires Display a, Display b, Display c where
  display (a, b, c) = "(\{a}, \{b}, \{c})"

export impl Display (a, b, c, d) requires Display a, Display b, Display c, Display d where
  display (a, b, c, d) = "(\{a}, \{b}, \{c}, \{d})"

export impl Display (a, b, c, d, e) requires Display a, Display b, Display c, Display d, Display e where
  display (a, b, c, d, e) = "(\{a}, \{b}, \{c}, \{d}, \{e})"

{- Derived `deriving (Debug, Display)` field rendering (`desugar.mdk`'s
   `showFieldPart`) must parenthesize a nested constructor-application field
   so the structure stays re-parseable — `Branch (Branch (Leaf 1) (Leaf 2))
   (Leaf 3)`, not the ambiguous `Branch Branch Leaf 1 Leaf 2 Leaf 3`.  Whether
   a field needs parens is a runtime property of ITS rendering (the field's
   own type may dispatch to any impl, derived or hand-written), not a static
   property of the derived type — so the decision is made by inspecting the
   rendered string itself, after the nested `debug`/`display` call returns,
   rather than threading a `showsPrec`-style precedence argument through the
   whole `Debug`/`Display` interface (that would ripple into every hand-written
   impl in the tree for a single desugar-local concern).

   A rendering is atomic (no parens needed) iff it is a single token:
     - empty,
     - a quoted `String`/`Char` literal (`debugStringLit`/`debugCharLit`
       always emit one whole self-delimited quoted token, so a leading quote
       is sufficient — no need to scan inside it), or
     - has no SPACE at bracket-depth 0 (so `[1, 2, 3]`, `(1, 2)`, and
       `[|1, 2, 3|]` — self-delimited by their own brackets — are already
       unambiguous and need no extra parens; a record-syntax rendering like
       `Circle { radius = 1.0 }` is NOT bracket-led — it starts with the
       bare constructor name — so it correctly falls through to needing
       parens when nested, same as a positional constructor application).
   A bare negative-number literal (`-1`) is treated as needing parens too:
   although `f -1` happens to parse as `f (-1)` in Medaka's own grammar (a
   deliberate tight-minus rule), a reader can't be expected to know that, and
   `Leaf (-1)` is unambiguous on sight — matching the classic `showsPrec`
   convention of parenthesizing negative numeric literals in argument
   position. -}
derivedShowWrap : String -> String
-- Called only from generated `deriving` code (desugar.mdk's `showFieldPart`),
-- never from source text in this tree, so the dead-code rule can't see the
-- (real) call site.
-- lint-disable-next-line rule-dead-code
derivedShowWrap s
  | derivedArgNeedsParens s = "(\{s})"
  | otherwise = s

derivedArgNeedsParens : String -> Bool
-- lint-disable-next-line rule-dead-code
derivedArgNeedsParens s
  | stringLength s == 0 = False
  | derivedIsQuoteChar (arrayGetUnsafe 0 (stringToChars s)) = False
  | arrayGetUnsafe 0 (stringToChars s) == '-' = True
  | otherwise = derivedHasTopLevelSpace (stringToChars s) 0 (stringLength s) 0

derivedIsQuoteChar : Char -> Bool
-- lint-disable-next-line rule-dead-code
derivedIsQuoteChar c = c == '"' || c == '\''

derivedHasTopLevelSpace : Array Char -> Int -> Int -> Int -> Bool
-- lint-disable-next-line rule-dead-code
derivedHasTopLevelSpace chars i n depth
  | i >= n = False
  | arrayGetUnsafe i chars == ' ' && depth == 0 = True
  | otherwise = derivedHasTopLevelSpace chars (i + 1) n (derivedNextDepth (arrayGetUnsafe i chars) depth)

derivedNextDepth : Char -> Int -> Int
-- lint-disable-next-line rule-dead-code
derivedNextDepth c depth
  | c == '(' || c == '[' || c == '{' = depth + 1
  | c == ')' || c == ']' || c == '}' = depth - 1
  | otherwise = depth

{- | Hash code for use in hash tables.  Equal values (per `Eq`) must produce
   the same hash — the contractual invariant.  Hash values need not be unique.
   Primitive impls delegate to per-type externs (`hashInt`/`hashString`/… —
   specified deterministic hashers, byte-identical across the tree-walker and the
   native backend); the compound impls below (`Option`/`Result`/`List`/tuples)
   hand-write a djb2-style fold: seed with constructor ordinal, then
   `acc = acc * 33 + hash field` left-to-right over fields.  ⛔ `deriving
   (Hashable)` is NOT implemented — `deriveForData` (desugar.mdk) supports only
   Eq/Debug/Display/Generic/Ord; writing `deriving (Hashable)` on a `data`/
   `record` type silently generates nothing (issue #421 tracks the silent
   part; #422 tracks implementing the deriver). Write a manual `impl
   Hashable T` in the meantime. -}
export interface Hashable a where
  hash : a -> Int

export impl Hashable Int where
  hash n = hashInt n

export impl Hashable Float where
  hash x = hashFloat x

export impl Hashable String where
  hash s = hashString s

export impl Hashable Char where
  hash c = hashChar c

export impl Hashable Bool where
  hash b = hashBool b

export impl Hashable Unit where
  hash _ = 0

-- Lt=0, Eq=1, Gt=2 — matches constructor declaration order.
export impl Hashable Ordering where
  hash Lt = 0
  hash Eq = 1
  hash Gt = 2

-- None=1 (ordinal 1, no fields); Some x seeds at 0 then folds: 0*33+hash x.
export impl Hashable (Option a) requires Hashable a where
  hash None = 1
  hash (Some x) = hash x

-- Ok seeds at 0, Err at 1.
export impl Hashable (Result e a) requires Hashable e, Hashable a where
  hash (Ok x) = hash x
  hash (Err e) = 33 + hash e

-- Left-fold: acc starts at 0, each element: acc = acc*33 + hash x.
hashListItems : Hashable a => Int -> List a -> Int
hashListItems acc [] = acc
hashListItems acc (x::xs) = hashListItems (acc * 33 + hash x) xs

export impl Hashable (List a) requires Hashable a where
  hash xs = hashListItems 0 xs

export impl Hashable (a, b) requires Hashable a, Hashable b where
  hash (a, b) = hash a * 33 + hash b

export impl Hashable (a, b, c) requires Hashable a, Hashable b, Hashable c where
  hash (a, b, c) = (hash a * 33 + hash b) * 33 + hash c

export impl Hashable (a, b, c, d) requires Hashable a, Hashable b, Hashable c, Hashable d where
  hash (a, b, c, d) = ((hash a * 33 + hash b) * 33 + hash c) * 33 + hash d

export impl Hashable (a, b, c, d, e) requires Hashable a, Hashable b, Hashable c, Hashable d, Hashable e where
  hash (a, b, c, d, e) =
    (((hash a * 33 + hash b) * 33 + hash c) * 33 + hash d) * 33 + hash e

{- | Human-facing output (Phase 111).  `println`/`print` render via `Display`
   (unquoted, user-facing) rather than dumping internal `VCon` structure, so a
   `Map` prints `Map { 1 => 10 }`, not its weight-balanced tree.  For
   round-trippable Debug-rendering output (strings/chars quoted, constructor
   names visible), import `io.mdk` and use `inspect` (`inspect x = putStrLn
   (debug x)`).  These are ordinary Medaka functions over the string-only
   `putStr`/`putStrLn` externs, which moves the `Display` constraint into
   Medaka where dict-passing works (an extern can't receive a dictionary). -}
export println : Display a => a -> <IO> Unit
println x = putStrLn (display x)

export print : Display a => a -> <IO> Unit
print x = putStr (display x)

{- | Numeric arithmetic.  Backs `+`, `-`, `*`, `/` for user-defined numeric
   types; the operators are hard-wired for `Int` and `Float` and only
   dispatch through `add`/`sub`/... for other types.

   `div` is truncating for `Int` and true division for `Float`, matching
   the host operator. -}
export interface Num a requires Eq a where
  add : a -> a -> a
  sub : a -> a -> a
  mul : a -> a -> a
  div : a -> a -> a
  negate : a -> a
  abs : a -> a
  signum : a -> a
  fromInt : Int -> a

export impl Num Int where
  add a b = a + b
  sub a b = a - b
  mul a b = a * b
  div a b = a / b
  negate a = 0 - a
  abs a = if a < 0 then 0 - a else a
  signum a = if a > 0 then 1 else if a < 0 then 0 - 1 else 0
  fromInt x = x

export impl Num Float where
  add a b = a + b
  sub a b = a - b
  mul a b = a * b
  div a b = a / b
  negate a = 0.0 - a
  abs a = if a < 0.0 then 0.0 - a else a
  signum a = if a > 0.0 then 1.0 else if a < 0.0 then 0.0 - 1.0 else 0.0
  fromInt x = intToFloat x

{- | Types with a smallest and largest representable value.
   Impls for `Int`, `Char` etc. land once the corresponding extern
   constants are added; the interface itself is here so generic
   bounded-type code can be written today. -}
export interface Bounded a where
  minBound : a
  maxBound : a

{- | `Int` bounds are the platform's 63-bit native-integer limits.
   > (minBound : Int) < (maxBound : Int)
   True -}
export impl Bounded Int where
  minBound = intMinBound
  maxBound = intMaxBound

{- | `Char` ranges over the Unicode scalar values, U+0000 to U+10FFFF.
   > charCode (minBound : Char)
   0
   > charCode (maxBound : Char)
   1114111 -}
export impl Bounded Char where
  minBound = charMinBound
  maxBound = charMaxBound

{- | Structure-preserving map (a.k.a. Functor).  Laws:
       map identity      == identity
       map (g `compose` f) == map g `compose` map f -}
export interface Mappable f where
  map : (a -> <e> b) -> f a -> <e> f b

export impl Mappable List where
  map _ [] = []
  map f (x::xs) = f x :: map f xs

export impl Mappable Option where
  map f (Some a) = Some (f a)
  map _ None = None

{- `default` so a user-defined alternative (e.g. one that maps over the
   `Err` side) can coexist without forcing every call site to qualify. -}
export impl Mappable (Result e) where
  map f (Ok a) = Ok (f a)
  map _ e = e

{- | Replace every element of a wrapped value with a constant, keeping the
   structure — Haskell's `$>`.  `replaceWith fa b == map (const b) fa`.

   > replaceWith (Some 5) 9
   Some 9 -}
export replaceWith : Mappable f => f a -> b -> f b
replaceWith fa b = map (_ => b) fa

{- | `Mappable` plus the ability to lift a plain value and apply a wrapped
   function to a wrapped argument.  Laws (identity, homomorphism,
   interchange, composition) follow Haskell's `Applicative`. -}
export interface Applicative f requires Mappable f where
  pure : a -> f a
  ap : f (a -> b) -> f a -> f b

export impl Applicative List where
  pure a = [a]
  ap [] _ = []
  ap (f::fs) xs = map f xs ++ ap fs xs
{- List of functions × list of arguments → cross product of applications.
       Equivalent to `concatMap (f => map f xs) fs` but spelled out so we
       don't depend on `concatMap` at this point in the file. -}

export impl Applicative Option where
  pure a = Some a
  ap None _ = None
  ap _ None = None
  ap (Some f) (Some a) = Some (f a)

{- `default` (like `Mappable (Result e)`) so an error-accumulating
   alternative — a `Validation`-style applicative — can coexist. -}
export impl Applicative (Result e) where
  pure a = Ok a
  ap (Ok f) (Ok a) = Ok (f a)
  ap (Err e) _ = Err e
  ap _ (Err e) = Err e

{- | Lift a binary function over two applicative values — Haskell's `liftA2`.

   > map2 (a b => a + b) (Some 3) (Some 4)
   Some 7
   > map2 (a b => a + b) (None : Option Int) (Some 4)
   None
   > map2 (a b => a + b) [1, 2] [10, 20]
   [11, 21, 12, 22] -}
export map2 : Applicative f => (a -> b -> c) -> f a -> f b -> f c
map2 f fa fb = ap (map f fa) fb

{- | Lift a ternary function over three applicative values — Haskell's `liftA3`.

   > map3 (a b c => a + b + c) (Some 1) (Some 2) (Some 3)
   Some 6
   > map3 (a b c => a + b + c) [1] [10, 20] [100]
   [111, 121] -}
export map3 : Applicative f => (a -> b -> c -> d) -> f a -> f b -> f c -> f d
map3 f fa fb fc = ap (ap (map f fa) fb) fc

{- | Sequencing of computations, threading the result.  Equivalent to
   Haskell's `>>=` with arguments swapped to match the readable
   "value first, then action" reading order.  Drives `do`-notation. -}
export interface Thenable m requires Applicative m where
  andThen : m a -> (a -> <e> m b) -> <e> m b

-- | `andThen` with arguments flipped — the Haskell/Scala `flatMap`.
export flatMap : Thenable m => (a -> <e> m b) -> m a -> <e> m b
flatMap f ma = andThen ma f

-- | Collapse one layer of nesting.  Haskell calls this `join`.
export flat : Thenable m => m (m a) -> m a
flat x = andThen x identity

-- | Run an action only when the condition holds.
export when : Thenable m => Bool -> m Unit -> m Unit
when b m = if b then m else pure ()

-- | Run an action only when the condition is false.  Dual of `when`.
export unless : Thenable m => Bool -> m Unit -> m Unit
unless b m = if b then pure () else m

{- | Monadic left fold: thread an accumulator through an effectful step, in
   order, over a list.  Haskell's `foldM`.

   > foldThen (acc x => Some (acc + x)) 0 [1, 2, 3]
   Some 6 -}
export foldThen : Thenable m => (b -> a -> <e> m b) -> b -> List a -> <e> m b
foldThen _ z [] = pure z
foldThen f z (x::xs) = andThen (f z x) (z2 => foldThen f z2 xs)

{- | Run an action `n` times and collect the results in order.  `n <= 0`
   yields `pure []`.  Haskell's `replicateM`.

   > repeatThen 3 (Some 7)
   Some [7, 7, 7] -}
export repeatThen : Thenable m => Int -> m a -> m (List a)
repeatThen n action
  | n <= 0 = pure []
  | otherwise = andThen action (x => map (x :: _) (repeatThen (n - 1) action))

{- | Keep the elements for which an effectful predicate returns `True`, in
   order.  Haskell's `filterM`.

   > filterThen (x => Some (x > 1)) [1, 2, 3]
   Some [2, 3] -}
export filterThen : Thenable m => (a -> <e> m Bool) -> List a -> <e> m (List a)
filterThen _ [] = pure []
filterThen f (x::xs) = andThen
  (f x)
  (keep => andThen (filterThen f xs) (rest => pure (if keep then x::rest else rest)))

{- | Run an effectful action for each element, in order, discarding the
   per-element results.  Haskell's `traverse_`/`for_` specialised to `List`.

   > forEach [1, 2, 3] (x => Some ())
   Some () -}
export forEach : Thenable m => List a -> (a -> <e> m Unit) -> <e> m Unit
forEach [] _ = pure ()
forEach (x::xs) f = andThen (f x) (_ => forEach xs f)

{- | Run each action in a list, in order, discarding the results.  Haskell's
   `sequence_` specialised to `List`.

   > runEach [Some 1, Some 2]
   Some () -}
export runEach : Thenable m => List (m a) -> m Unit
runEach [] = pure ()
runEach (x::xs) = andThen x (_ => runEach xs)

export impl Thenable List where
  andThen [] _ = []
  andThen xs f = concatRev (revAcc xs []) []
    where
      -- Tail-recursive reverse (core has no `reverse`; that lives in `list.mdk`).
      revAcc [] acc = acc
      revAcc (x::rest) acc = revAcc rest (x :: acc)
      -- `concatRev` folds `f x ++ acc` over the REVERSED input, rebuilding
      -- `f a ++ f b ++ f c` by `++` associativity.  Its recursive call is the
      -- whole body (tail ⇒ no stack growth — depth was previously the outer-list
      -- length under the non-tail `f x ++ andThen xs f`); the `++` is iterative.
      concatRev [] acc = acc
      concatRev (x::rest) acc = concatRev rest (f x ++ acc)

export impl Thenable Option where
  andThen None _ = None
  andThen (Some a) f = f a

{- `default` (like the rest of the `Result e` family) so a short-circuiting
   alternative can coexist with the standard error-propagating sequence. -}
export impl Thenable (Result e) where
  andThen (Err e) _ = Err e
  andThen (Ok a) f = f a

{- | Nondeterministic choice.  `noMatch` is the always-failing alternative
   (identity for `orElse`); `orElse a b` tries `a` and, if it
   "fails"/is-empty, falls back to `b` (left-biased).

   Laws:
       orElse noMatch x == x          (left identity)
       orElse x noMatch == x          (right identity)
       orElse (orElse x y) z == orElse x (orElse y z)  (associativity)

   > length (orElse [1, 2] [3])
   3
   > isEmpty (orElse ([] : List Int) [1])
   False
   > isSome (orElse (Some 1) (Some 2))
   True
   > isSome (orElse None (Some 2))
   True
   > isSome (orElse None (None : Option Int))
   False -}
export interface Alternative f requires Applicative f where
  noMatch : f a
  orElse : f a -> f a -> f a

export impl Alternative List where
  noMatch = []
  orElse xs ys = xs ++ ys

export impl Alternative Option where
  noMatch = None
  orElse (Some x) _ = Some x
  orElse None b = b

{- | `guard True` succeeds with `pure ()`; `guard False` is the failing
   `noMatch`.  Used to prune an `Alternative` computation on a condition.

   > (guard True : Option Unit)
   Some ()
   > (guard False : Option Unit)
   None -}
export guard : Alternative f => Bool -> f Unit
guard True = pure ()
guard False = noMatch

{- | Map over BOTH type parameters of a two-parameter type constructor —
   Haskell's `Bifunctor`, renamed to fit `Mappable`/`Thenable`.  `mapFirst`
   touches the left/`Err` side, `mapSecond` the right/`Ok` side; both have
   defaults in terms of `bimap`.

   > bimap (n => n + 1) (n => n * 2) (Ok 5 : Result Int Int)
   Ok 10
   > bimap (n => n + 1) (n => n * 2) (Err 5 : Result Int Int)
   Err 6 -}
export interface Bimappable p where
  bimap : (a -> <e> c) -> (b -> <e> d) -> p a b -> <e> p c d
  mapFirst : (a -> <e> c) -> p a b -> <e> p c b
  mapFirst f = bimap f identity
  mapSecond : (b -> <e> d) -> p a b -> <e> p a d
  mapSecond g = bimap identity g

{- `mapFirst` on `Result` generalizes the standalone `mapErr`. -}
export impl Bimappable Result where
  bimap f _ (Err e) = Err (f e)
  bimap _ g (Ok a) = Ok (g a)

{- The bare 2-tuple constructor `(,)` as a `Bimappable`: `bimap` maps the two
   fields independently.  `mapFirst`/`mapSecond` come from the interface
   defaults, so they touch the left/right field respectively.

   > bimap (x => x + 1) (y => y * 2) (3, 4)
   (4, 8)
   > mapFirst (x => x + 1) (3, 4)
   (4, 4)
   > mapSecond (y => y * 2) (3, 4)
   (3, 8) -}
export impl Bimappable (,) where
  bimap f g (x, y) = (f x, g y)

{- | Collapse a container down to a summary value.

   `fold` is a strict left fold; `foldRight` is the natural recursive form
   and is the one you want for operations that need to preserve element
   order (or that would otherwise allocate a reversed accumulator).

   `length`, `isEmpty`, and `foldMap` come with defaults so impls only
   need to define `fold`, `foldRight`, and `toList`; override the others
   when the data structure admits a faster implementation (e.g. O(1)
   `length` for arrays).

   > isEmpty (None : Option Int)
   True
   > length (Some 5)
   1 -}
export interface Foldable t where
  fold : (b -> a -> <e> b) -> b -> t a -> <e> b
  foldRight : (a -> b -> <e> b) -> b -> t a -> <e> b
  foldMap : Monoid m => (a -> <e> m) -> t a -> <e> m
  toList : t a -> List a
  isEmpty : t a -> Bool
  length : t a -> Int
  foldMap f = fold (acc x => acc ++ f x) empty
  length t = fold (acc _ => acc + 1) 0 t
  isEmpty t = match toList t
    [] => True
    _ => False

{- | Containers that can drop elements (and transform-while-dropping).
   Modeled on Haskell's `witherable` Filterable: `filterMap` is the
   primitive, `filter` falls out as a derived default.  Kept separate
   from `Mappable` because not every functor can shrink — a fixed-shape
   container has no sensible `filterMap`. -}
export interface Filterable f requires Mappable f where
  filterMap : (a -> <e> Option b) -> f a -> <e> f b
  filter : (a -> <e> Bool) -> f a -> <e> f a
  filter p = filterMap (x => if p x then Some x else None)

{- | Build a container `c` from a list of entries of type `e`.  Backs the
   container-literal sugar: the compiler lowers `Map { k => v, … }` to
   `fromEntries [(k, v), …]` and `Set { x, … }` to `fromEntries [x, …]`,
   pinning the result type to the named container so this dispatches to that
   container's impl.  `c` is the dispatch (result) type; `e` is its entry type
   — for a map `(k, v)`, for a set the element.  Impls live with each container
   (e.g. `impl FromEntries (Map k v) (k, v)` in map.mdk). -}
export interface FromEntries c e where
  fromEntries : List e -> c

{- | Read access to a container `c` keyed by `k`, yielding a `v`.  `index c k`
   looks up the value at key/index `k`; impls raise the coded `indexError`
   abort (E-INDEX-OOB) on an out-of-range index or missing key. -}
export interface Index c k v where
  index : c -> k -> v

{- | Write access to a container `c` keyed by `k`.  `setIndex c k v` writes
   `v` at key/index `k`, returning the (possibly mutated in place) container.
   Requires `Index c k v` (a container you can write into, you can also read
   from). -}
export interface IndexMut c k v requires Index c k v where
  setIndex : c -> k -> v -> c

{- | `index arr i` reads `arr`'s element at `i` (`arr[i]` sugar dispatches
   here).  O(1).  Raises the coded `indexError` (E-INDEX-OOB) when `i` is
   out of range -- use `get` for a safe `Option`-returning read instead. -}
export impl Index (Array a) Int a where
  index arr i =
    if i < 0 || i >= arrayLength arr then
      indexError "index \{intToString i} out of bounds"
    else
      arrayGetUnsafe i arr

{- | `setIndex arr i v` writes `v` at `arr`'s index `i`, in place, and
   returns `arr`.  O(1).  Raises the coded `indexError` (E-INDEX-OOB) when
   `i` is out of range. -}
export impl IndexMut (Array a) Int a where
  setIndex arr i v =
    if i < 0 || i >= arrayLength arr then indexError "index \{intToString i} out of bounds"
    else
      let _ = arraySetUnsafe i v arr
      arr

{- | `index xs i` is `xs`'s element at position `i`.  O(n) — a singly-linked
   list has no random access, so this walks `i` cons cells; prefer `Array`/
   `MutArray` for index-heavy workloads.  Raises the coded `indexError`
   (E-INDEX-OOB) when `i` is out of range.  No `IndexMut` impl: `List` is
   immutable / has no in-place element write. -}
export impl Index (List a) Int a where
  index [] _ = indexError "index out of bounds"
  index (h::t) i = if i <= 0 then h else index t (i - 1)

{- | `index s i` is the codepoint `Char` of `s` at position `i` (`s[i]` sugar
   dispatches here; codepoints, not grapheme clusters -- matches `toChars`).
   Raises the coded `indexError` (E-INDEX-OOB) when `i` is out of range.  No
   `IndexMut` impl: `String` is immutable. -}
export impl Index String Int Char where
  index s i =
    let cs = stringToChars s
    if i < 0 || i >= arrayLength cs then
      indexError "index \{intToString i} out of bounds"
    else
      arrayGetUnsafe i cs

export impl Foldable List where
  fold _ acc [] = acc
  fold f acc (x::xs) = fold f (f acc x) xs
  foldRight _ acc [] = acc
  foldRight f acc (x::xs) = f x (foldRight f acc xs)
  toList = identity
  isEmpty [] = True
  isEmpty _ = False
  length = fold (acc _ => acc + 1) 0
{- Tail-recursive via the strict left fold; `1 + length xs` would
       accumulate stack frames proportional to list length. -}

{- `Option` and `Result e` each foldable as a 0-or-1-element container.
   `default` on the Result impl mirrors `Mappable (Result e)`: a user-defined
   alternative (e.g. folding over the `Err` side) can coexist without
   forcing every call site to qualify. -}
export impl Foldable Option where
  fold _ acc None = acc
  fold f acc (Some x) = f acc x
  foldRight _ acc None = acc
  foldRight f acc (Some x) = f x acc
  toList None = []
  toList (Some x) = [x]

export impl Foldable (Result e) where
  fold _ acc (Err _) = acc
  fold f acc (Ok x) = f acc x
  foldRight _ acc (Err _) = acc
  foldRight f acc (Ok x) = f x acc
  toList (Err _) = []
  toList (Ok x) = [x]

{- | Containers that can be traversed left-to-right, running an effectful
   function over each element and collecting the results inside the effect.
   `Traversable` is `Mappable` + `Foldable` plus the ability to *commute* the
   container with an applicative/monadic effect: `traverse` walks the structure,
   `sequence` flips a container-of-effects into an effect-of-container.

   For `Option`/`Result` the effect short-circuits on the first `None`/`Err`;
   for any other `Thenable m` it threads `m` through the whole structure.

   > traverse (x => if x > 0 then Some x else None) [1, 2, 3]
   Some [1, 2, 3]
   > traverse (x => if x > 0 then Some x else None) [1, -2, 3]
   None
   > traverse (x => if x > 0 then Some (x + 1) else None) (Some 5)
   Some Some 6
   > traverse (x => if x > 0 then Ok x else Err x) [1, 2, 3]
   Ok [1, 2, 3]
   > traverse (x => if x > 0 then Ok x else Err x) [1, -2, 3]
   Err -2
   > sequence [Some 1, Some 2, Some 3]
   Some [1, 2, 3]
   > sequence [Some 1, None, Some 3]
   None
   > sequence [Ok 1, Ok 2, Ok 3]
   Ok [1, 2, 3]
   > sequence [Ok 1, Err 99, Ok 3]
   Err 99 -}
export interface Traversable t requires Mappable t, Foldable t where
  traverse : Thenable m => (a -> <e> m b) -> t a -> <e> m (t b)
  sequence : Thenable m => t (m a) -> <e> m (t a)
  sequence ta = traverse identity ta
-- `sequence` is an interface DEFAULT: the desugar fill pass (fillImplDefaults)
-- synthesizes a concrete-receiver per-impl copy of this body into every impl,
-- so each List/Option/Result instance dispatches `traverse` on its concrete
-- receiver and codegens correctly.  Written eta-expanded (`sequence ta = …`,
-- not point-free `sequence = traverse identity`): the point-free form loses the
-- `m` dictionary and mis-dispatches the inner `pure` to the `t` instance.

{- Each `traverse` impl is a SINGLE clause with an inner `match`, not separate
   per-constructor clauses: the multi-clause form of a generic `Thenable m =>`
   method whose body has a return-position `pure` loops in eval (dict-passing ×
   multi-clause desugar).  Do not split them back out. -}
-- lint-disable-next-line rule-match-on-param
export impl Traversable List where
  traverse f xs = match xs
    [] => pure []
    x::rest => andThen (f x) (y => map (y :: _) (traverse f rest))

-- lint-disable-next-line rule-match-on-param
export impl Traversable Option where
  traverse f opt = match opt
    None => pure None
    Some x => map Some (f x)

{- `default` mirrors the `Foldable`/`Mappable (Result e)` impls so a
   user-defined alternative can coexist without qualifying call sites. -}
-- lint-disable-next-line rule-match-on-param
export impl Traversable (Result e) where
  traverse f res = match res
    Err e => pure (Err e)
    Ok x => map Ok (f x)

-- ─── 3. Standalone helpers ──────────────────────────────────────────────

{- Foldable helpers — generic over any Foldable container.

   These do *not* short-circuit because `fold` itself doesn't; that's the
   price of staying generic.  Container-specific versions in `list.mdk`,
   `array.mdk`, etc. can short-circuit where it matters. -}

{- | True when at least one element satisfies the predicate.

   > any (x => x > 2) [1, 2, 3]
   True
   > any (x => x > 10) [1, 2, 3]
   False -}
export any : Foldable t => (a -> <e> Bool) -> t a -> <e> Bool
any f = fold (acc x => acc || f x) False

{- | True when every element satisfies the predicate.  Vacuously true on
   the empty container.

   > all (x => x > 0) [1, 2, 3]
   True
   > all (x => x > 0) []
   True -}
export all : Foldable t => (a -> <e> Bool) -> t a -> <e> Bool
all f = fold (acc x => acc && f x) True

{- | First element satisfying the predicate, or `None` if none do.
   Latches the first hit via an as-pattern so subsequent elements don't
   overwrite the answer. -}
export find : Foldable t => (a -> <e> Bool) -> t a -> <e> Option a
find f = fold g None
  where
    g (acc@(Some _)) _ = acc
    g None x
      | f x = Some x
      | otherwise = None

-- | Number of elements satisfying the predicate.
export count : Foldable t => (a -> <e> Bool) -> t a -> <e> Int
count f = fold g 0
  where
    g acc x
      | f x = acc + 1
      | otherwise = acc

{- | Sum of a numeric foldable.  Identity is `0`; in practice this only
   works for `Int` today because `(+)` is a builtin that doesn't yet
   dispatch through `Num.add` for user-defined numeric types. -}
export sum : (Foldable t, Num a) => t a -> a
sum xs = fold (+) (fromInt 0) xs

-- | Product of a numeric foldable.  Identity is `1`.  Same caveat as `sum`.
export product : (Foldable t, Num a) => t a -> a
product xs = fold (*) (fromInt 1) xs

-- | True when the value appears in the container (by `Eq`).
export elem : (Foldable t, Eq a) => a -> t a -> Bool
elem a = fold (acc x => acc || x == a) False

-- | True when the value does *not* appear in the container.  `not . elem`.
export notElem : (Foldable t, Eq a) => a -> t a -> Bool
notElem a xs = not (elem a xs)

{- | Largest element by `Ord`, or `None` when the container is empty.  Generic
   over any `Foldable` — `List`, `Array`, `Option`, … all reuse this one body.

   > maximum [3, 1, 2]
   Some 3
   > maximum ([] : List Int)
   None -}
export maximum : (Foldable t, Ord a) => t a -> Option a
maximum = fold step None
  where
    step None x = Some x
    step (Some m) x = Some (max m x)

{- | Smallest element by `Ord`, or `None` when empty.  Generic, like `maximum`.

   > minimum [3, 1, 2]
   Some 1 -}
export minimum : (Foldable t, Ord a) => t a -> Option a
minimum = fold step None
  where
    step None x = Some x
    step (Some m) x = Some (min m x)

{- | `Filterable List`.  Lives in `core` (rather than `list.mdk`) so the
   `filter` name is in scope for the rest of the stdlib; `list.mdk`
   re-exports it for discoverability.

   > filter (x => x > 2) [1, 2, 3, 4]
   [3, 4] -}
export impl Filterable List where
  filterMap _ [] = []
  filterMap f (x::xs) = match f x
    Some y => y :: filterMap f xs
    None => filterMap f xs

-- ─── Bool helpers ───────────────────────────────────────────────────────

-- | Alias for `True`, idiomatic in guard chains.
export otherwise : Bool
otherwise = True

-- | Logical negation.
export not : Bool -> Bool
not True = False
not False = True

{- | Strict logical AND.  The lazy short-circuiting form is the `&&`
   operator, which is hard-wired in the evaluator. -}
export and : Bool -> Bool -> Bool
and True True = True
and _ _ = False

-- | Strict logical OR.  See `and` for the lazy form.
export or : Bool -> Bool -> Bool
or False False = False
or _ _ = True

-- | Exclusive OR.
export xor : Bool -> Bool -> Bool
xor a b = a != b

-- ─── Option helpers ─────────────────────────────────────────────────────

-- | True if the value is present.
export isSome : Option a -> Bool
isSome (Some _) = True
isSome None = False

-- | True if the value is absent.
export isNone : Option a -> Bool
isNone None = True
isNone (Some _) = False

{- | Unwrap with a default for `None`.

   > fromOption 0 (Some 42)
   42
   > fromOption 0 None
   0 -}
export fromOption : a -> Option a -> a
fromOption _ (Some a) = a
fromOption d None = d

-- | Turn an `Option` into a `Result`, supplying the error for `None`.
export toResult : e -> Option a -> Result e a
toResult _ (Some a) = Ok a
toResult e None = Err e

{- | Forget the error: `Ok x → Some x`, `Err _ → None`.
   Named to match the "from-Result" intuition; this is the inverse of
   `toResult` modulo the discarded error value. -}
export fromResult : Result e a -> Option a
fromResult (Ok a) = Some a
fromResult (Err _) = None

-- ─── Result helpers ─────────────────────────────────────────────────────

-- | True if the result is `Ok`.
export isOk : Result e a -> Bool
isOk (Ok _) = True
isOk (Err _) = False

-- | True if the result is `Err`.
export isErr : Result e a -> Bool
isErr (Err _) = True
isErr (Ok _) = False

{- | Unwrap with a default for `Err`.  Named distinctly from
   `fromOption` so the two don't collide when both are in scope. -}
export fromResultOr : a -> Result e a -> a
fromResultOr _ (Ok a) = a
fromResultOr d (Err _) = d

{- | Apply a function to the `Err` side, leaving `Ok` alone.  The `Ok`
   analogue is just `map` from `Mappable (Result e)`. -}
export mapErr : (e -> f) -> Result e a -> Result f a
mapErr f (Err e) = Err (f e)
mapErr _ (Ok a) = Ok a

-- ─── Utility functions ──────────────────────────────────────────────────

-- | Return the argument unchanged.
export identity : a -> a
identity x = x

{- | First component of a pair.
   > fst (1, 2)
   1 -}
export fst : (a, b) -> a
fst (a, _) = a

{- | Second component of a pair.
   > snd ("a", True)
   True -}
export snd : (a, b) -> b
snd (_, b) = b

{- | Return the first argument; useful as a building block for ignoring
   a callback's input (`map (const 0) xs == replicate (length xs) 0`). -}
export const : a -> b -> a
const x _ = x

-- | Swap the first two arguments of a binary function.
export flip : (a -> b -> <e> c) -> b -> a -> <e> c
flip f b a = f a b

{- | Apply a binary function `f` to two arguments after running each through a
   projection `g` — the classic `on`.  `sortBy (on compare fst)` compares
   pairs by their first component.

   > on compare fst (1, 9) (2, 8)
   Lt -}
export on : (b -> b -> <e> c) -> (a -> b) -> a -> a -> <e> c
on f g x y = f (g x) (g y)

{- | Turn a function on a pair into a function of two arguments.  The inverse
   of `uncurry`.  (Medaka tuples aren't auto-curried, so this is not free.)

   > curry fst 1 2
   1 -}
export curry : ((a, b) -> <e> c) -> a -> b -> <e> c
curry f a b = f (a, b)

{- | Turn a two-argument function into a function on a pair.  The inverse of
   `curry`.

   > uncurry (a b => a + b) (3, 4)
   7 -}
export uncurry : (a -> b -> <e> c) -> (a, b) -> <e> c
uncurry f (a, b) = f a b

{- | Run a wrapped computation for its structure/effect and discard the result,
   replacing it with `Unit`.  Haskell calls this `void`.

   > discard (Some 5)
   Some () -}
export discard : Mappable f => f a -> f Unit
discard fa = map (_ => ()) fa

{- | Right-to-left function composition: `(compose g f) x == g (f x)`.
   Spelled `<<` as an operator. -}
export compose : (b -> <e> c) -> (a -> <e> b) -> a -> <e> c
compose g f a = g (f a)

{- | Left-to-right function composition: `(pipe f g) x == g (f x)`.
   Spelled `>>` as an operator. -}
export pipe : (a -> <e> b) -> (b -> <e> c) -> a -> <e> c
pipe f g a = g (f a)

{- | Function application as a function.  Mainly useful for higher-order
   code that wants to defer "actually call this" decisions. -}
export apply : (a -> <e> b) -> a -> <e> b
apply f a = f a

-- ─── 4. Arbitrary (property-test generators) ────────────────────────────

{- | Sources of random values for property-based testing (`prop` decls).
   `arbitrary` produces a value in the `<Rand>` effect; `shrink` returns
   progressively smaller candidates used to reduce a failing example. -}
export interface Arbitrary a where
  arbitrary : Unit -> <Rand> a
  shrink : a -> List a
  shrink _ = []

export impl Arbitrary Int where
  arbitrary () = randomInt (-1000) 1000
  shrink 0 = []
  shrink n = [0, n / 2]

export impl Arbitrary Bool where
  arbitrary () = randomBool ()

export impl Arbitrary Float where
  arbitrary () = randomFloat ()

export impl Arbitrary Char where
  arbitrary () = randomChar ()

-- | Generate a random string of 0–10 printable ASCII chars.
export arbitraryString : Unit -> <Rand> String
arbitraryString () = go (randomInt 0 10) ""
  where
    go 0 acc = acc
    go n acc = go (n - 1) (acc ++ charToStr (randomChar ()))

export impl Arbitrary String where
  arbitrary () = arbitraryString ()

-- | Generate a list of up to `maxLen` elements using `gen`.
export arbitraryList : (Unit -> <Rand> a) -> Int -> <Rand> List a
arbitraryList gen maxLen = go (randomInt 0 maxLen) []
  where
    go 0 acc = acc
    go n acc = go (n - 1) (gen () :: acc)

-- ─── 4b. Generic (structural representation / `deriving (Generic)`) ──────

{- | A uniform, flat structural view of any value.  `deriving (Generic)`
   synthesises `to_rep`, turning a value into this tagged tree; a library
   author writes one function over `Rep` and gets their typeclass for any
   deriving type (serialisation, hashing, pretty-printing, …).

   `RCon` carries a constructor's name and its positional fields' reps;
   `RRecord` carries a record type's name and its named fields.  The
   remaining constructors are primitive leaves. -}
public export data Rep =
  | RCon String (List Rep)
  | RRecord String (List RField)
  | RInt Int
  | RFloat Float
  | RString String
  | RBool Bool
  | RChar Char
  | RUnit

-- | A named field inside an `RRecord`.
public export data RField = RField { fld_name : String, fld_rep : Rep }

{- | Types with a structural representation.  `to_rep` is synthesised by
   `deriving (Generic)`.  `from_rep` is return-type polymorphic, which the
   runtime cannot dispatch on arguments alone, so it is a stub for now —
   the signature is fixed so a later phase can fill in real bodies. -}
export interface Generic a where
  to_rep : a -> Rep
  from_rep : Rep -> a
  from_rep _ = panic "from_rep: not implemented (Phase 1 is to_rep only)"

export impl Generic Int where
  to_rep n = RInt n

export impl Generic Float where
  to_rep x = RFloat x

export impl Generic String where
  to_rep s = RString s

export impl Generic Bool where
  to_rep b = RBool b

export impl Generic Char where
  to_rep c = RChar c

export impl Generic Unit where
  to_rep _ = RUnit

-- ─── 5. Properties (executed by `medaka test`) ──────────────────────────

prop "neq is the negation of eq" (x : Int) (y : Int) = neq x y == not (eq x y)

prop "compare agrees with lt/gt/eq" (x : Int) (y : Int) = match compare x y
  Lt => lt x y && not (gt x y) && neq x y
  Gt => gt x y && not (lt x y) && neq x y
  Eq => eq x y && not (lt x y) && not (gt x y)

prop "clamp keeps values inside the interval" (x : Int) =
  let c = clamp 0 100 x
  c >= 0 && c <= 100

prop "filter . filter p == filter p" (xs : List Int) =
  eq (filter (x => x > 0) (filter (x => x > 0) xs)) (filter (x => x > 0) xs)

prop "length matches a counting fold" (xs : List Int) =
  length xs == fold (acc _ => acc + 1) 0 xs

prop "any/all duality" (xs : List Int) =
  any (x => x > 0) xs == not (all (x => x <= 0) xs)

prop "fromOption d (Some x) == x" (x : Int) (d : Int) =
  fromOption d (Some x) == x

prop "toResult/fromResult round-trip on Some" (x : Int) =
  eq (fromResult (toResult "missing" (Some x))) (Some x)

prop "Ord (List a) is reflexive" (xs : List Int) = match compare xs xs
  Eq => True
  _ => False

prop "discard replaces the payload with Unit" (x : Int) =
  eq (discard (Some x)) (Some ())

prop "on agrees with its hand expansion" (a : Int) (b : Int) =
  on (x y => x + y) (n => n * 2) a b == a * 2 + b * 2

prop "map2 on Some matches direct application" (a : Int) (b : Int) =
  eq (map2 (x y => x + y) (Some a) (Some b)) (Some (a + b))

prop "map3 on Some matches direct application" (a : Int) (b : Int) (c : Int) =
  eq (map3 (x y z => x + y + z) (Some a) (Some b) (Some c)) (Some (a + b + c))

prop "mapFirst on Result generalizes mapErr" (n : Int) = eq
  (mapFirst (x => x + 1) (Err n : Result Int Int))
  (mapErr (x => x + 1) (Err n))

prop "foldThen with Some agrees with a pure fold" (xs : List Int) = eq
  (foldThen (acc x => Some (acc + x)) 0 xs)
  (Some (fold (acc x => acc + x) 0 xs))
# DESUGAR
(DData Public "Ordering" () ((variant "Lt" (ConPos)) (variant "Eq" (ConPos)) (variant "Gt" (ConPos))) ())
(DData Public "Option" ("a") ((variant "Some" (ConPos (TyVar "a"))) (variant "None" (ConPos))) ())
(DData Public "Result" ("e" "a") ((variant "Ok" (ConPos (TyVar "a"))) (variant "Err" (ConPos (TyVar "e")))) ())
(DInterface true false "Eq" ("a") () ((imethod "eq" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) None)))
(DTypeSig true "neq" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool")))))
(DFunDef false "neq" ((PVar "x") (PVar "y")) (EApp (EVar "not") (EApp (EApp (EVar "eq") (EVar "x")) (EVar "y"))))
(DImpl true "Eq" ((TyCon "Int")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl true "Eq" ((TyCon "Float")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl true "Eq" ((TyCon "Bool")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl true "Eq" ((TyCon "String")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl true "Eq" ((TyCon "Char")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl true "Eq" ((TyCon "Unit")) () ((im "eq" (PWild PWild) (EVar "True"))))
(DImpl true "Eq" ((TyApp (TyCon "List") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PList) (PList)) (EVar "True")) (im "eq" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "x")) (EVar "y")) (EApp (EApp (EVar "eq") (EVar "xs")) (EVar "ys")))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl true "Eq" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "None") (PCon "None")) (EVar "True")) (im "eq" ((PCon "Some" (PVar "x")) (PCon "Some" (PVar "y"))) (EApp (EApp (EVar "eq") (EVar "x")) (EVar "y"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl true "Eq" ((TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) ((req "Eq" ((TyVar "e"))) (req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "Ok" (PVar "x")) (PCon "Ok" (PVar "y"))) (EApp (EApp (EVar "eq") (EVar "x")) (EVar "y"))) (im "eq" ((PCon "Err" (PVar "x")) (PCon "Err" (PVar "y"))) (EApp (EApp (EVar "eq") (EVar "x")) (EVar "y"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl true "Eq" ((TyTuple (TyVar "a") (TyVar "b"))) ((req "Eq" ((TyVar "a"))) (req "Eq" ((TyVar "b")))) ((im "eq" ((PTuple (PVar "a1") (PVar "b1")) (PTuple (PVar "a2") (PVar "b2"))) (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "eq") (EVar "b1")) (EVar "b2"))))))
(DImpl true "Eq" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c"))) ((req "Eq" ((TyVar "a"))) (req "Eq" ((TyVar "b"))) (req "Eq" ((TyVar "c")))) ((im "eq" ((PTuple (PVar "a1") (PVar "b1") (PVar "c1")) (PTuple (PVar "a2") (PVar "b2") (PVar "c2"))) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "eq") (EVar "b1")) (EVar "b2"))) (EApp (EApp (EVar "eq") (EVar "c1")) (EVar "c2"))))))
(DImpl true "Eq" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d"))) ((req "Eq" ((TyVar "a"))) (req "Eq" ((TyVar "b"))) (req "Eq" ((TyVar "c"))) (req "Eq" ((TyVar "d")))) ((im "eq" ((PTuple (PVar "a1") (PVar "b1") (PVar "c1") (PVar "d1")) (PTuple (PVar "a2") (PVar "b2") (PVar "c2") (PVar "d2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "eq") (EVar "b1")) (EVar "b2"))) (EApp (EApp (EVar "eq") (EVar "c1")) (EVar "c2"))) (EApp (EApp (EVar "eq") (EVar "d1")) (EVar "d2"))))))
(DImpl true "Eq" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d") (TyVar "e"))) ((req "Eq" ((TyVar "a"))) (req "Eq" ((TyVar "b"))) (req "Eq" ((TyVar "c"))) (req "Eq" ((TyVar "d"))) (req "Eq" ((TyVar "e")))) ((im "eq" ((PTuple (PVar "a1") (PVar "b1") (PVar "c1") (PVar "d1") (PVar "e1")) (PTuple (PVar "a2") (PVar "b2") (PVar "c2") (PVar "d2") (PVar "e2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "eq") (EVar "b1")) (EVar "b2"))) (EApp (EApp (EVar "eq") (EVar "c1")) (EVar "c2"))) (EApp (EApp (EVar "eq") (EVar "d1")) (EVar "d2"))) (EApp (EApp (EVar "eq") (EVar "e1")) (EVar "e2"))))))
(DInterface true false "Semigroup" ("a") () ((imethod "append" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))) None)))
(DImpl true "Semigroup" ((TyApp (TyCon "List") (TyVar "a"))) () ((im "append" ((PVar "xs") (PVar "ys")) (EBinOp "++" (EVar "xs") (EVar "ys")))))
(DImpl true "Semigroup" ((TyCon "String")) () ((im "append" ((PVar "s1") (PVar "s2")) (EBinOp "++" (EVar "s1") (EVar "s2")))))
(DInterface true false "Monoid" ("a") ((super "Semigroup" ("a"))) ((imethod "empty" (TyVar "a") None)))
(DImpl true "Monoid" ((TyApp (TyCon "List") (TyVar "a"))) () ((im "empty" () (EListLit))))
(DImpl true "Monoid" ((TyCon "String")) () ((im "empty" () (ELit (LString "")))))
(DInterface true false "Ord" ("a") ((super "Eq" ("a"))) ((imethod "compare" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Ordering"))) None) (imethod "lt" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) (mdef ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False"))))) (imethod "gt" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) (mdef ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False"))))) (imethod "lte" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) (mdef ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True"))))) (imethod "gte" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) (mdef ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True"))))) (imethod "min" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))) (mdef ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x"))))) (imethod "max" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))) (mdef ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x")))))))
(DTypeSig true "clamp" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))))))
(DFunDef false "clamp" ((PVar "lo") (PVar "hi")) (EBinOp ">>" (EApp (EVar "min") (EVar "hi")) (EApp (EVar "max") (EVar "lo"))))
(DTypeSig true "isEven" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isEven" ((PVar "n")) (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 0))))
(DTypeSig true "isOdd" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isOdd" ((PVar "n")) (EBinOp "!=" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 0))))
(DImpl true "Ord" ((TyCon "Int")) () ((im "compare" ((PVar "a") (PVar "b")) (EIf (EBinOp "<" (EVar "a") (EVar "b")) (EVar "Lt") (EIf (EBinOp ">" (EVar "a") (EVar "b")) (EVar "Gt") (EVar "Eq")))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DTypeSig false "floatSignBit" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "floatSignBit" ((PVar "x")) (EBinOp ">=" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "floatToBytes64") (EVar "x"))) (ELit (LInt 128))))
(DTypeSig false "compareBySign" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Ordering"))))
(DFunDef false "compareBySign" ((PVar "a") (PVar "b")) (EMatch (ETuple (EApp (EVar "floatSignBit") (EVar "a")) (EApp (EVar "floatSignBit") (EVar "b"))) (arm (PTuple (PCon "True") (PCon "False")) () (EVar "Lt")) (arm (PTuple (PCon "False") (PCon "True")) () (EVar "Gt")) (arm PWild () (EVar "Eq"))))
(DTypeSig false "compareNaN" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Ordering"))))
(DFunDef false "compareNaN" ((PVar "a") (PVar "b")) (EIf (EBinOp "&&" (EBinOp "!=" (EVar "a") (EVar "a")) (EBinOp "!=" (EVar "b") (EVar "b"))) (EApp (EApp (EVar "compareBySign") (EVar "a")) (EVar "b")) (EIf (EBinOp "!=" (EVar "a") (EVar "a")) (EIf (EApp (EVar "floatSignBit") (EVar "a")) (EVar "Lt") (EVar "Gt")) (EIf (EVar "otherwise") (EIf (EApp (EVar "floatSignBit") (EVar "b")) (EVar "Gt") (EVar "Lt")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DImpl true "Ord" ((TyCon "Float")) () ((im "compare" ((PVar "a") (PVar "b")) (EIf (EBinOp "<" (EVar "a") (EVar "b")) (EVar "Lt") (EIf (EBinOp ">" (EVar "a") (EVar "b")) (EVar "Gt") (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EApp (EVar "compareBySign") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "compareNaN") (EVar "a")) (EVar "b")))))) (im "lt" ((PVar "a") (PVar "b")) (EBinOp "<" (EVar "a") (EVar "b"))) (im "gt" ((PVar "a") (PVar "b")) (EBinOp ">" (EVar "a") (EVar "b"))) (im "lte" ((PVar "a") (PVar "b")) (EBinOp "<=" (EVar "a") (EVar "b"))) (im "gte" ((PVar "a") (PVar "b")) (EBinOp ">=" (EVar "a") (EVar "b"))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyCon "String")) () ((im "compare" ((PVar "a") (PVar "b")) (EIf (EBinOp "<" (EVar "a") (EVar "b")) (EVar "Lt") (EIf (EBinOp ">" (EVar "a") (EVar "b")) (EVar "Gt") (EVar "Eq")))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyCon "Char")) () ((im "compare" ((PVar "a") (PVar "b")) (EIf (EBinOp "<" (EVar "a") (EVar "b")) (EVar "Lt") (EIf (EBinOp ">" (EVar "a") (EVar "b")) (EVar "Gt") (EVar "Eq")))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DTypeSig false "thenCmp" (TyFun (TyCon "Ordering") (TyFun (TyCon "Ordering") (TyCon "Ordering"))))
(DFunDef false "thenCmp" ((PCon "Eq") (PVar "o")) (EVar "o"))
(DFunDef false "thenCmp" ((PVar "o") PWild) (EVar "o"))
(DImpl true "Ord" ((TyTuple (TyVar "a") (TyVar "b"))) ((req "Ord" ((TyVar "a"))) (req "Ord" ((TyVar "b")))) ((im "compare" ((PTuple (PVar "a1") (PVar "b1")) (PTuple (PVar "a2") (PVar "b2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EVar "compare") (EVar "a1")) (EVar "a2"))) (EApp (EApp (EVar "compare") (EVar "b1")) (EVar "b2")))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c"))) ((req "Ord" ((TyVar "a"))) (req "Ord" ((TyVar "b"))) (req "Ord" ((TyVar "c")))) ((im "compare" ((PTuple (PVar "a1") (PVar "b1") (PVar "c1")) (PTuple (PVar "a2") (PVar "b2") (PVar "c2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EVar "compare") (EVar "a1")) (EVar "a2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EVar "compare") (EVar "b1")) (EVar "b2"))) (EApp (EApp (EVar "compare") (EVar "c1")) (EVar "c2"))))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d"))) ((req "Ord" ((TyVar "a"))) (req "Ord" ((TyVar "b"))) (req "Ord" ((TyVar "c"))) (req "Ord" ((TyVar "d")))) ((im "compare" ((PTuple (PVar "a1") (PVar "b1") (PVar "c1") (PVar "d1")) (PTuple (PVar "a2") (PVar "b2") (PVar "c2") (PVar "d2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EVar "compare") (EVar "a1")) (EVar "a2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EVar "compare") (EVar "b1")) (EVar "b2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EVar "compare") (EVar "c1")) (EVar "c2"))) (EApp (EApp (EVar "compare") (EVar "d1")) (EVar "d2")))))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d") (TyVar "e"))) ((req "Ord" ((TyVar "a"))) (req "Ord" ((TyVar "b"))) (req "Ord" ((TyVar "c"))) (req "Ord" ((TyVar "d"))) (req "Ord" ((TyVar "e")))) ((im "compare" ((PTuple (PVar "a1") (PVar "b1") (PVar "c1") (PVar "d1") (PVar "e1")) (PTuple (PVar "a2") (PVar "b2") (PVar "c2") (PVar "d2") (PVar "e2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EVar "compare") (EVar "a1")) (EVar "a2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EVar "compare") (EVar "b1")) (EVar "b2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EVar "compare") (EVar "c1")) (EVar "c2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EVar "compare") (EVar "d1")) (EVar "d2"))) (EApp (EApp (EVar "compare") (EVar "e1")) (EVar "e2"))))))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyApp (TyCon "List") (TyVar "a"))) ((req "Ord" ((TyVar "a")))) ((im "compare" ((PList) (PList)) (EVar "Eq")) (im "compare" ((PList) PWild) (EVar "Lt")) (im "compare" (PWild (PList)) (EVar "Gt")) (im "compare" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y"))) (EApp (EApp (EVar "compare") (EVar "xs")) (EVar "ys")))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Ord" ((TyVar "a")))) ((im "compare" ((PCon "None") (PCon "None")) (EVar "Eq")) (im "compare" ((PCon "None") (PCon "Some" PWild)) (EVar "Lt")) (im "compare" ((PCon "Some" PWild) (PCon "None")) (EVar "Gt")) (im "compare" ((PCon "Some" (PVar "x")) (PCon "Some" (PVar "y"))) (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y"))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) ((req "Ord" ((TyVar "e"))) (req "Ord" ((TyVar "a")))) ((im "compare" ((PCon "Err" (PVar "x")) (PCon "Err" (PVar "y"))) (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y"))) (im "compare" ((PCon "Err" PWild) (PCon "Ok" PWild)) (EVar "Lt")) (im "compare" ((PCon "Ok" PWild) (PCon "Err" PWild)) (EVar "Gt")) (im "compare" ((PCon "Ok" (PVar "x")) (PCon "Ok" (PVar "y"))) (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y"))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DInterface true false "Debug" ("a") () ((imethod "debug" (TyFun (TyVar "a") (TyCon "String")) None)))
(DImpl true "Debug" ((TyCon "Int")) () ((im "debug" ((PVar "n")) (EApp (EVar "intToString") (EVar "n")))))
(DImpl true "Debug" ((TyCon "Float")) () ((im "debug" ((PVar "x")) (EApp (EVar "floatToString") (EVar "x")))))
(DImpl true "Debug" ((TyCon "Bool")) () ((im "debug" ((PCon "True")) (ELit (LString "True"))) (im "debug" ((PCon "False")) (ELit (LString "False")))))
(DImpl true "Debug" ((TyCon "Unit")) () ((im "debug" (PWild) (ELit (LString "()")))))
(DImpl true "Debug" ((TyCon "Ordering")) () ((im "debug" ((PCon "Lt")) (ELit (LString "Lt"))) (im "debug" ((PCon "Eq")) (ELit (LString "Eq"))) (im "debug" ((PCon "Gt")) (ELit (LString "Gt")))))
(DImpl true "Eq" ((TyCon "Ordering")) () ((im "eq" ((PCon "Lt") (PCon "Lt")) (EVar "True")) (im "eq" ((PCon "Eq") (PCon "Eq")) (EVar "True")) (im "eq" ((PCon "Gt") (PCon "Gt")) (EVar "True")) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl true "Ord" ((TyCon "Ordering")) () ((im "compare" ((PCon "Lt") (PCon "Lt")) (EVar "Eq")) (im "compare" ((PCon "Lt") PWild) (EVar "Lt")) (im "compare" (PWild (PCon "Lt")) (EVar "Gt")) (im "compare" ((PCon "Eq") (PCon "Eq")) (EVar "Eq")) (im "compare" ((PCon "Eq") PWild) (EVar "Lt")) (im "compare" (PWild (PCon "Eq")) (EVar "Gt")) (im "compare" ((PCon "Gt") (PCon "Gt")) (EVar "Eq")) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Debug" ((TyCon "String")) () ((im "debug" ((PVar "s")) (EApp (EVar "debugStringLit") (EVar "s")))))
(DImpl true "Debug" ((TyCon "Char")) () ((im "debug" ((PVar "c")) (EApp (EVar "debugCharLit") (EVar "c")))))
(DTypeSig false "debugListItems" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "String"))))
(DFunDef false "debugListItems" ((PList)) (ELit (LString "")))
(DFunDef false "debugListItems" ((PList (PVar "x"))) (EApp (EVar "debug") (EVar "x")))
(DFunDef false "debugListItems" ((PCons (PVar "y") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "y")))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "debugListItems") (EVar "rest")))) (ELit (LString ""))))
(DImpl true "Debug" ((TyApp (TyCon "List") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "xs")) (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EVar "display") (EApp (EVar "debugListItems") (EVar "xs")))) (ELit (LString "]"))))))
(DTypeSig false "debugArrayItems" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))))
(DFunDef false "debugArrayItems" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EIf (EBinOp "==" (EVar "i") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "debug") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "debug") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "debugArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DImpl true "Debug" ((TyApp (TyCon "Array") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "arr")) (EBinOp "++" (EBinOp "++" (ELit (LString "[|")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "debugArrayItems") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))) (ELit (LString "|]"))))))
(DImpl true "Eq" ((TyApp (TyCon "Array") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "!=" (EApp (EVar "arrayLength") (EVar "a")) (EApp (EVar "arrayLength") (EVar "b"))) (EVar "False") (EApp (EApp (EApp (EApp (EVar "eqGo") (EVar "a")) (EVar "b")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "a")))))))
(DTypeSig false "eqGo" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "eqGo" ((PVar "a") (PVar "b") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "True") (EIf (EApp (EApp (EVar "eq") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "b"))) (EApp (EApp (EApp (EApp (EVar "eqGo") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "False"))))
(DImpl true "Debug" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PCon "None")) (ELit (LString "None"))) (im "debug" ((PCon "Some" (PVar "x"))) (EBinOp "++" (ELit (LString "Some ")) (EApp (EVar "debug") (EVar "x"))))))
(DImpl true "Debug" ((TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) ((req "Debug" ((TyVar "e"))) (req "Debug" ((TyVar "a")))) ((im "debug" ((PCon "Ok" (PVar "x"))) (EBinOp "++" (ELit (LString "Ok ")) (EApp (EVar "debug") (EVar "x")))) (im "debug" ((PCon "Err" (PVar "e"))) (EBinOp "++" (ELit (LString "Err ")) (EApp (EVar "debug") (EVar "e"))))))
(DImpl true "Debug" ((TyTuple (TyVar "a") (TyVar "b"))) ((req "Debug" ((TyVar "a"))) (req "Debug" ((TyVar "b")))) ((im "debug" ((PTuple (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "a")))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "b")))) (ELit (LString ")"))))))
(DImpl true "Debug" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c"))) ((req "Debug" ((TyVar "a"))) (req "Debug" ((TyVar "b"))) (req "Debug" ((TyVar "c")))) ((im "debug" ((PTuple (PVar "a") (PVar "b") (PVar "c"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "a")))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "b")))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "c")))) (ELit (LString ")"))))))
(DImpl true "Debug" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d"))) ((req "Debug" ((TyVar "a"))) (req "Debug" ((TyVar "b"))) (req "Debug" ((TyVar "c"))) (req "Debug" ((TyVar "d")))) ((im "debug" ((PTuple (PVar "a") (PVar "b") (PVar "c") (PVar "d"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "a")))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "b")))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "c")))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "d")))) (ELit (LString ")"))))))
(DImpl true "Debug" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d") (TyVar "e"))) ((req "Debug" ((TyVar "a"))) (req "Debug" ((TyVar "b"))) (req "Debug" ((TyVar "c"))) (req "Debug" ((TyVar "d"))) (req "Debug" ((TyVar "e")))) ((im "debug" ((PTuple (PVar "a") (PVar "b") (PVar "c") (PVar "d") (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "a")))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "b")))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "c")))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "d")))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "e")))) (ELit (LString ")"))))))
(DInterface true false "Display" ("a") () ((imethod "display" (TyFun (TyVar "a") (TyCon "String")) None)))
(DImpl true "Display" ((TyCon "Int")) () ((im "display" ((PVar "n")) (EApp (EVar "intToString") (EVar "n")))))
(DImpl true "Display" ((TyCon "Float")) () ((im "display" ((PVar "x")) (EApp (EVar "floatToString") (EVar "x")))))
(DImpl true "Display" ((TyCon "Bool")) () ((im "display" ((PCon "True")) (ELit (LString "True"))) (im "display" ((PCon "False")) (ELit (LString "False")))))
(DImpl true "Display" ((TyCon "Unit")) () ((im "display" (PWild) (ELit (LString "()")))))
(DImpl true "Display" ((TyCon "Ordering")) () ((im "display" ((PCon "Lt")) (ELit (LString "Lt"))) (im "display" ((PCon "Eq")) (ELit (LString "Eq"))) (im "display" ((PCon "Gt")) (ELit (LString "Gt")))))
(DImpl true "Display" ((TyCon "String")) () ((im "display" ((PVar "s")) (EVar "s"))))
(DImpl true "Display" ((TyCon "Char")) () ((im "display" ((PVar "c")) (EApp (EVar "charToStr") (EVar "c")))))
(DTypeSig false "displayListItems" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "String"))))
(DFunDef false "displayListItems" ((PList)) (ELit (LString "")))
(DFunDef false "displayListItems" ((PList (PVar "x"))) (EApp (EVar "display") (EVar "x")))
(DFunDef false "displayListItems" ((PCons (PVar "y") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "y"))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "displayListItems") (EVar "rest")))) (ELit (LString ""))))
(DImpl true "Display" ((TyApp (TyCon "List") (TyVar "a"))) ((req "Display" ((TyVar "a")))) ((im "display" ((PVar "xs")) (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EVar "display") (EApp (EVar "displayListItems") (EVar "xs")))) (ELit (LString "]"))))))
(DTypeSig false "displayArrayItems" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))))
(DFunDef false "displayArrayItems" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EIf (EBinOp "==" (EVar "i") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "display") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "display") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "displayArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DImpl true "Display" ((TyApp (TyCon "Array") (TyVar "a"))) ((req "Display" ((TyVar "a")))) ((im "display" ((PVar "arr")) (EBinOp "++" (EBinOp "++" (ELit (LString "[|")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "displayArrayItems") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))) (ELit (LString "|]"))))))
(DImpl true "Display" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Display" ((TyVar "a")))) ((im "display" ((PCon "None")) (ELit (LString "None"))) (im "display" ((PCon "Some" (PVar "x"))) (EBinOp "++" (ELit (LString "Some ")) (EApp (EVar "display") (EVar "x"))))))
(DImpl true "Display" ((TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) ((req "Display" ((TyVar "e"))) (req "Display" ((TyVar "a")))) ((im "display" ((PCon "Ok" (PVar "x"))) (EBinOp "++" (ELit (LString "Ok ")) (EApp (EVar "display") (EVar "x")))) (im "display" ((PCon "Err" (PVar "e"))) (EBinOp "++" (ELit (LString "Err ")) (EApp (EVar "display") (EVar "e"))))))
(DImpl true "Display" ((TyTuple (TyVar "a") (TyVar "b"))) ((req "Display" ((TyVar "a"))) (req "Display" ((TyVar "b")))) ((im "display" ((PTuple (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EVar "a"))) (ELit (LString ", "))) (EApp (EVar "display") (EVar "b"))) (ELit (LString ")"))))))
(DImpl true "Display" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c"))) ((req "Display" ((TyVar "a"))) (req "Display" ((TyVar "b"))) (req "Display" ((TyVar "c")))) ((im "display" ((PTuple (PVar "a") (PVar "b") (PVar "c"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EVar "a"))) (ELit (LString ", "))) (EApp (EVar "display") (EVar "b"))) (ELit (LString ", "))) (EApp (EVar "display") (EVar "c"))) (ELit (LString ")"))))))
(DImpl true "Display" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d"))) ((req "Display" ((TyVar "a"))) (req "Display" ((TyVar "b"))) (req "Display" ((TyVar "c"))) (req "Display" ((TyVar "d")))) ((im "display" ((PTuple (PVar "a") (PVar "b") (PVar "c") (PVar "d"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EVar "a"))) (ELit (LString ", "))) (EApp (EVar "display") (EVar "b"))) (ELit (LString ", "))) (EApp (EVar "display") (EVar "c"))) (ELit (LString ", "))) (EApp (EVar "display") (EVar "d"))) (ELit (LString ")"))))))
(DImpl true "Display" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d") (TyVar "e"))) ((req "Display" ((TyVar "a"))) (req "Display" ((TyVar "b"))) (req "Display" ((TyVar "c"))) (req "Display" ((TyVar "d"))) (req "Display" ((TyVar "e")))) ((im "display" ((PTuple (PVar "a") (PVar "b") (PVar "c") (PVar "d") (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EVar "a"))) (ELit (LString ", "))) (EApp (EVar "display") (EVar "b"))) (ELit (LString ", "))) (EApp (EVar "display") (EVar "c"))) (ELit (LString ", "))) (EApp (EVar "display") (EVar "d"))) (ELit (LString ", "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ")"))))))
(DTypeSig false "derivedShowWrap" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "derivedShowWrap" ((PVar "s")) (EIf (EApp (EVar "derivedArgNeedsParens") (EVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EVar "s"))) (ELit (LString ")"))) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "derivedArgNeedsParens" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "derivedArgNeedsParens" ((PVar "s")) (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))) (EVar "False") (EIf (EApp (EVar "derivedIsQuoteChar") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s")))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LChar "-"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "derivedHasTopLevelSpace") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))) (ELit (LInt 0))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "derivedIsQuoteChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "derivedIsQuoteChar" ((PVar "c")) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (EBinOp "==" (EVar "c") (ELit (LChar "'")))))
(DTypeSig false "derivedHasTopLevelSpace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "derivedHasTopLevelSpace" ((PVar "chars") (PVar "i") (PVar "n") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar " "))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "derivedHasTopLevelSpace") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EApp (EVar "derivedNextDepth") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars"))) (EVar "depth"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "derivedNextDepth" (TyFun (TyCon "Char") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "derivedNextDepth" ((PVar "c") (PVar "depth")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "("))) (EBinOp "==" (EVar "c") (ELit (LChar "[")))) (EBinOp "==" (EVar "c") (ELit (LChar "{")))) (EBinOp "+" (EVar "depth") (ELit (LInt 1))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar ")"))) (EBinOp "==" (EVar "c") (ELit (LChar "]")))) (EBinOp "==" (EVar "c") (ELit (LChar "}")))) (EBinOp "-" (EVar "depth") (ELit (LInt 1))) (EIf (EVar "otherwise") (EVar "depth") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DInterface true false "Hashable" ("a") () ((imethod "hash" (TyFun (TyVar "a") (TyCon "Int")) None)))
(DImpl true "Hashable" ((TyCon "Int")) () ((im "hash" ((PVar "n")) (EApp (EVar "hashInt") (EVar "n")))))
(DImpl true "Hashable" ((TyCon "Float")) () ((im "hash" ((PVar "x")) (EApp (EVar "hashFloat") (EVar "x")))))
(DImpl true "Hashable" ((TyCon "String")) () ((im "hash" ((PVar "s")) (EApp (EVar "hashString") (EVar "s")))))
(DImpl true "Hashable" ((TyCon "Char")) () ((im "hash" ((PVar "c")) (EApp (EVar "hashChar") (EVar "c")))))
(DImpl true "Hashable" ((TyCon "Bool")) () ((im "hash" ((PVar "b")) (EApp (EVar "hashBool") (EVar "b")))))
(DImpl true "Hashable" ((TyCon "Unit")) () ((im "hash" (PWild) (ELit (LInt 0)))))
(DImpl true "Hashable" ((TyCon "Ordering")) () ((im "hash" ((PCon "Lt")) (ELit (LInt 0))) (im "hash" ((PCon "Eq")) (ELit (LInt 1))) (im "hash" ((PCon "Gt")) (ELit (LInt 2)))))
(DImpl true "Hashable" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Hashable" ((TyVar "a")))) ((im "hash" ((PCon "None")) (ELit (LInt 1))) (im "hash" ((PCon "Some" (PVar "x"))) (EApp (EVar "hash") (EVar "x")))))
(DImpl true "Hashable" ((TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) ((req "Hashable" ((TyVar "e"))) (req "Hashable" ((TyVar "a")))) ((im "hash" ((PCon "Ok" (PVar "x"))) (EApp (EVar "hash") (EVar "x"))) (im "hash" ((PCon "Err" (PVar "e"))) (EBinOp "+" (ELit (LInt 33)) (EApp (EVar "hash") (EVar "e"))))))
(DTypeSig false "hashListItems" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))))
(DFunDef false "hashListItems" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "hashListItems" ((PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "hashListItems") (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 33))) (EApp (EVar "hash") (EVar "x")))) (EVar "xs")))
(DImpl true "Hashable" ((TyApp (TyCon "List") (TyVar "a"))) ((req "Hashable" ((TyVar "a")))) ((im "hash" ((PVar "xs")) (EApp (EApp (EVar "hashListItems") (ELit (LInt 0))) (EVar "xs")))))
(DImpl true "Hashable" ((TyTuple (TyVar "a") (TyVar "b"))) ((req "Hashable" ((TyVar "a"))) (req "Hashable" ((TyVar "b")))) ((im "hash" ((PTuple (PVar "a") (PVar "b"))) (EBinOp "+" (EBinOp "*" (EApp (EVar "hash") (EVar "a")) (ELit (LInt 33))) (EApp (EVar "hash") (EVar "b"))))))
(DImpl true "Hashable" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c"))) ((req "Hashable" ((TyVar "a"))) (req "Hashable" ((TyVar "b"))) (req "Hashable" ((TyVar "c")))) ((im "hash" ((PTuple (PVar "a") (PVar "b") (PVar "c"))) (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EApp (EVar "hash") (EVar "a")) (ELit (LInt 33))) (EApp (EVar "hash") (EVar "b"))) (ELit (LInt 33))) (EApp (EVar "hash") (EVar "c"))))))
(DImpl true "Hashable" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d"))) ((req "Hashable" ((TyVar "a"))) (req "Hashable" ((TyVar "b"))) (req "Hashable" ((TyVar "c"))) (req "Hashable" ((TyVar "d")))) ((im "hash" ((PTuple (PVar "a") (PVar "b") (PVar "c") (PVar "d"))) (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EApp (EVar "hash") (EVar "a")) (ELit (LInt 33))) (EApp (EVar "hash") (EVar "b"))) (ELit (LInt 33))) (EApp (EVar "hash") (EVar "c"))) (ELit (LInt 33))) (EApp (EVar "hash") (EVar "d"))))))
(DImpl true "Hashable" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d") (TyVar "e"))) ((req "Hashable" ((TyVar "a"))) (req "Hashable" ((TyVar "b"))) (req "Hashable" ((TyVar "c"))) (req "Hashable" ((TyVar "d"))) (req "Hashable" ((TyVar "e")))) ((im "hash" ((PTuple (PVar "a") (PVar "b") (PVar "c") (PVar "d") (PVar "e"))) (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EApp (EVar "hash") (EVar "a")) (ELit (LInt 33))) (EApp (EVar "hash") (EVar "b"))) (ELit (LInt 33))) (EApp (EVar "hash") (EVar "c"))) (ELit (LInt 33))) (EApp (EVar "hash") (EVar "d"))) (ELit (LInt 33))) (EApp (EVar "hash") (EVar "e"))))))
(DTypeSig true "println" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "println" ((PVar "x")) (EApp (EVar "putStrLn") (EApp (EVar "display") (EVar "x"))))
(DTypeSig true "print" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "print" ((PVar "x")) (EApp (EVar "putStr") (EApp (EVar "display") (EVar "x"))))
(DInterface true false "Num" ("a") ((super "Eq" ("a"))) ((imethod "add" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))) None) (imethod "sub" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))) None) (imethod "mul" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))) None) (imethod "div" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))) None) (imethod "negate" (TyFun (TyVar "a") (TyVar "a")) None) (imethod "abs" (TyFun (TyVar "a") (TyVar "a")) None) (imethod "signum" (TyFun (TyVar "a") (TyVar "a")) None) (imethod "fromInt" (TyFun (TyCon "Int") (TyVar "a")) None)))
(DImpl true "Num" ((TyCon "Int")) () ((im "add" ((PVar "a") (PVar "b")) (EBinOp "+" (EVar "a") (EVar "b"))) (im "sub" ((PVar "a") (PVar "b")) (EBinOp "-" (EVar "a") (EVar "b"))) (im "mul" ((PVar "a") (PVar "b")) (EBinOp "*" (EVar "a") (EVar "b"))) (im "div" ((PVar "a") (PVar "b")) (EBinOp "/" (EVar "a") (EVar "b"))) (im "negate" ((PVar "a")) (EBinOp "-" (ELit (LInt 0)) (EVar "a"))) (im "abs" ((PVar "a")) (EIf (EBinOp "<" (EVar "a") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "a")) (EVar "a"))) (im "signum" ((PVar "a")) (EIf (EBinOp ">" (EVar "a") (ELit (LInt 0))) (ELit (LInt 1)) (EIf (EBinOp "<" (EVar "a") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (ELit (LInt 0))))) (im "fromInt" ((PVar "x")) (EVar "x"))))
(DImpl true "Num" ((TyCon "Float")) () ((im "add" ((PVar "a") (PVar "b")) (EBinOp "+" (EVar "a") (EVar "b"))) (im "sub" ((PVar "a") (PVar "b")) (EBinOp "-" (EVar "a") (EVar "b"))) (im "mul" ((PVar "a") (PVar "b")) (EBinOp "*" (EVar "a") (EVar "b"))) (im "div" ((PVar "a") (PVar "b")) (EBinOp "/" (EVar "a") (EVar "b"))) (im "negate" ((PVar "a")) (EBinOp "-" (ELit (LFloat 0.0)) (EVar "a"))) (im "abs" ((PVar "a")) (EIf (EBinOp "<" (EVar "a") (ELit (LFloat 0.0))) (EBinOp "-" (ELit (LFloat 0.0)) (EVar "a")) (EVar "a"))) (im "signum" ((PVar "a")) (EIf (EBinOp ">" (EVar "a") (ELit (LFloat 0.0))) (ELit (LFloat 1.0)) (EIf (EBinOp "<" (EVar "a") (ELit (LFloat 0.0))) (EBinOp "-" (ELit (LFloat 0.0)) (ELit (LFloat 1.0))) (ELit (LFloat 0.0))))) (im "fromInt" ((PVar "x")) (EApp (EVar "intToFloat") (EVar "x")))))
(DInterface true false "Bounded" ("a") () ((imethod "minBound" (TyVar "a") None) (imethod "maxBound" (TyVar "a") None)))
(DImpl true "Bounded" ((TyCon "Int")) () ((im "minBound" () (EVar "intMinBound")) (im "maxBound" () (EVar "intMaxBound"))))
(DImpl true "Bounded" ((TyCon "Char")) () ((im "minBound" () (EVar "charMinBound")) (im "maxBound" () (EVar "charMaxBound"))))
(DInterface true false "Mappable" ("f") () ((imethod "map" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyVar "f") (TyVar "b"))))) None)))
(DImpl true "Mappable" ((TyCon "List")) () ((im "map" (PWild (PList)) (EListLit)) (im "map" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "map") (EVar "f")) (EVar "xs"))))))
(DImpl true "Mappable" ((TyCon "Option")) () ((im "map" ((PVar "f") (PCon "Some" (PVar "a"))) (EApp (EVar "Some") (EApp (EVar "f") (EVar "a")))) (im "map" (PWild (PCon "None")) (EVar "None"))))
(DImpl true "Mappable" ((TyApp (TyCon "Result") (TyVar "e"))) () ((im "map" ((PVar "f") (PCon "Ok" (PVar "a"))) (EApp (EVar "Ok") (EApp (EVar "f") (EVar "a")))) (im "map" (PWild (PVar "e")) (EVar "e"))))
(DTypeSig true "replaceWith" (TyConstrained ((cstr "Mappable" (TyVar "f"))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyFun (TyVar "b") (TyApp (TyVar "f") (TyVar "b"))))))
(DFunDef false "replaceWith" ((PVar "fa") (PVar "b")) (EApp (EApp (EVar "map") (ELam (PWild) (EVar "b"))) (EVar "fa")))
(DInterface true false "Applicative" ("f") ((super "Mappable" ("f"))) ((imethod "pure" (TyFun (TyVar "a") (TyApp (TyVar "f") (TyVar "a"))) None) (imethod "ap" (TyFun (TyApp (TyVar "f") (TyFun (TyVar "a") (TyVar "b"))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyApp (TyVar "f") (TyVar "b")))) None)))
(DImpl true "Applicative" ((TyCon "List")) () ((im "pure" ((PVar "a")) (EListLit (EVar "a"))) (im "ap" ((PList) PWild) (EListLit)) (im "ap" ((PCons (PVar "f") (PVar "fs")) (PVar "xs")) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "f")) (EVar "xs")) (EApp (EApp (EVar "ap") (EVar "fs")) (EVar "xs"))))))
(DImpl true "Applicative" ((TyCon "Option")) () ((im "pure" ((PVar "a")) (EApp (EVar "Some") (EVar "a"))) (im "ap" ((PCon "None") PWild) (EVar "None")) (im "ap" (PWild (PCon "None")) (EVar "None")) (im "ap" ((PCon "Some" (PVar "f")) (PCon "Some" (PVar "a"))) (EApp (EVar "Some") (EApp (EVar "f") (EVar "a"))))))
(DImpl true "Applicative" ((TyApp (TyCon "Result") (TyVar "e"))) () ((im "pure" ((PVar "a")) (EApp (EVar "Ok") (EVar "a"))) (im "ap" ((PCon "Ok" (PVar "f")) (PCon "Ok" (PVar "a"))) (EApp (EVar "Ok") (EApp (EVar "f") (EVar "a")))) (im "ap" ((PCon "Err" (PVar "e")) PWild) (EApp (EVar "Err") (EVar "e"))) (im "ap" (PWild (PCon "Err" (PVar "e"))) (EApp (EVar "Err") (EVar "e")))))
(DTypeSig true "map2" (TyConstrained ((cstr "Applicative" (TyVar "f"))) (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyVar "c"))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyFun (TyApp (TyVar "f") (TyVar "b")) (TyApp (TyVar "f") (TyVar "c")))))))
(DFunDef false "map2" ((PVar "f") (PVar "fa") (PVar "fb")) (EApp (EApp (EVar "ap") (EApp (EApp (EVar "map") (EVar "f")) (EVar "fa"))) (EVar "fb")))
(DTypeSig true "map3" (TyConstrained ((cstr "Applicative" (TyVar "f"))) (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyFun (TyVar "c") (TyVar "d")))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyFun (TyApp (TyVar "f") (TyVar "b")) (TyFun (TyApp (TyVar "f") (TyVar "c")) (TyApp (TyVar "f") (TyVar "d"))))))))
(DFunDef false "map3" ((PVar "f") (PVar "fa") (PVar "fb") (PVar "fc")) (EApp (EApp (EVar "ap") (EApp (EApp (EVar "ap") (EApp (EApp (EVar "map") (EVar "f")) (EVar "fa"))) (EVar "fb"))) (EVar "fc")))
(DInterface true false "Thenable" ("m") ((super "Applicative" ("m"))) ((imethod "andThen" (TyFun (TyApp (TyVar "m") (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyVar "m") (TyVar "b")))) (TyEffect () (Some "e") (TyApp (TyVar "m") (TyVar "b"))))) None)))
(DTypeSig true "flatMap" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyVar "m") (TyVar "b")))) (TyFun (TyApp (TyVar "m") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyVar "m") (TyVar "b")))))))
(DFunDef false "flatMap" ((PVar "f") (PVar "ma")) (EApp (EApp (EVar "andThen") (EVar "ma")) (EVar "f")))
(DTypeSig true "flat" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyApp (TyVar "m") (TyApp (TyVar "m") (TyVar "a"))) (TyApp (TyVar "m") (TyVar "a")))))
(DFunDef false "flat" ((PVar "x")) (EApp (EApp (EVar "andThen") (EVar "x")) (EVar "identity")))
(DTypeSig true "when" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyVar "m") (TyCon "Unit")) (TyApp (TyVar "m") (TyCon "Unit"))))))
(DFunDef false "when" ((PVar "b") (PVar "m")) (EIf (EVar "b") (EVar "m") (EApp (EVar "pure") (ELit LUnit))))
(DTypeSig true "unless" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyVar "m") (TyCon "Unit")) (TyApp (TyVar "m") (TyCon "Unit"))))))
(DFunDef false "unless" ((PVar "b") (PVar "m")) (EIf (EVar "b") (EApp (EVar "pure") (ELit LUnit)) (EVar "m")))
(DTypeSig true "foldThen" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyVar "m") (TyVar "b"))))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyVar "m") (TyVar "b"))))))))
(DFunDef false "foldThen" (PWild (PVar "z") (PList)) (EApp (EVar "pure") (EVar "z")))
(DFunDef false "foldThen" ((PVar "f") (PVar "z") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "f") (EVar "z")) (EVar "x"))) (ELam ((PVar "z2")) (EApp (EApp (EApp (EVar "foldThen") (EVar "f")) (EVar "z2")) (EVar "xs")))))
(DTypeSig true "repeatThen" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyVar "m") (TyVar "a")) (TyApp (TyVar "m") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "repeatThen" ((PVar "n") (PVar "action")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EVar "pure") (EListLit)) (EIf (EVar "otherwise") (EApp (EApp (EVar "andThen") (EVar "action")) (ELam ((PVar "x")) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "x") (EVar "_s")))) (EApp (EApp (EVar "repeatThen") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "action"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "filterThen" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyVar "m") (TyCon "Bool")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyVar "m") (TyApp (TyCon "List") (TyVar "a"))))))))
(DFunDef false "filterThen" (PWild (PList)) (EApp (EVar "pure") (EListLit)))
(DFunDef false "filterThen" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "andThen") (EApp (EVar "f") (EVar "x"))) (ELam ((PVar "keep")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "filterThen") (EVar "f")) (EVar "xs"))) (ELam ((PVar "rest")) (EApp (EVar "pure") (EIf (EVar "keep") (EBinOp "::" (EVar "x") (EVar "rest")) (EVar "rest"))))))))
(DTypeSig true "forEach" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyVar "m") (TyCon "Unit")))) (TyEffect () (Some "e") (TyApp (TyVar "m") (TyCon "Unit")))))))
(DFunDef false "forEach" ((PList) PWild) (EApp (EVar "pure") (ELit LUnit)))
(DFunDef false "forEach" ((PCons (PVar "x") (PVar "xs")) (PVar "f")) (EApp (EApp (EVar "andThen") (EApp (EVar "f") (EVar "x"))) (ELam (PWild) (EApp (EApp (EVar "forEach") (EVar "xs")) (EVar "f")))))
(DTypeSig true "runEach" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyApp (TyCon "List") (TyApp (TyVar "m") (TyVar "a"))) (TyApp (TyVar "m") (TyCon "Unit")))))
(DFunDef false "runEach" ((PList)) (EApp (EVar "pure") (ELit LUnit)))
(DFunDef false "runEach" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "andThen") (EVar "x")) (ELam (PWild) (EApp (EVar "runEach") (EVar "xs")))))
(DImpl true "Thenable" ((TyCon "List")) () ((im "andThen" ((PList) PWild) (EListLit)) (im "andThen" ((PVar "xs") (PVar "f")) (ELetGroup ((lgb "revAcc" (clause ((PList) (PVar "acc")) (EVar "acc")) (clause ((PCons (PVar "x") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "revAcc") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "acc"))))) (lgb "concatRev" (clause ((PList) (PVar "acc")) (EVar "acc")) (clause ((PCons (PVar "x") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "concatRev") (EVar "rest")) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EVar "acc")))))) (EApp (EApp (EVar "concatRev") (EApp (EApp (EVar "revAcc") (EVar "xs")) (EListLit))) (EListLit))))))
(DImpl true "Thenable" ((TyCon "Option")) () ((im "andThen" ((PCon "None") PWild) (EVar "None")) (im "andThen" ((PCon "Some" (PVar "a")) (PVar "f")) (EApp (EVar "f") (EVar "a")))))
(DImpl true "Thenable" ((TyApp (TyCon "Result") (TyVar "e"))) () ((im "andThen" ((PCon "Err" (PVar "e")) PWild) (EApp (EVar "Err") (EVar "e"))) (im "andThen" ((PCon "Ok" (PVar "a")) (PVar "f")) (EApp (EVar "f") (EVar "a")))))
(DInterface true false "Alternative" ("f") ((super "Applicative" ("f"))) ((imethod "noMatch" (TyApp (TyVar "f") (TyVar "a")) None) (imethod "orElse" (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyApp (TyVar "f") (TyVar "a")))) None)))
(DImpl true "Alternative" ((TyCon "List")) () ((im "noMatch" () (EListLit)) (im "orElse" ((PVar "xs") (PVar "ys")) (EBinOp "++" (EVar "xs") (EVar "ys")))))
(DImpl true "Alternative" ((TyCon "Option")) () ((im "noMatch" () (EVar "None")) (im "orElse" ((PCon "Some" (PVar "x")) PWild) (EApp (EVar "Some") (EVar "x"))) (im "orElse" ((PCon "None") (PVar "b")) (EVar "b"))))
(DTypeSig true "guard" (TyConstrained ((cstr "Alternative" (TyVar "f"))) (TyFun (TyCon "Bool") (TyApp (TyVar "f") (TyCon "Unit")))))
(DFunDef false "guard" ((PCon "True")) (EApp (EVar "pure") (ELit LUnit)))
(DFunDef false "guard" ((PCon "False")) (EVar "noMatch"))
(DInterface true false "Bimappable" ("p") () ((imethod "bimap" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "c"))) (TyFun (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "d"))) (TyFun (TyApp (TyApp (TyVar "p") (TyVar "a")) (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyApp (TyVar "p") (TyVar "c")) (TyVar "d")))))) None) (imethod "mapFirst" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "c"))) (TyFun (TyApp (TyApp (TyVar "p") (TyVar "a")) (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyApp (TyVar "p") (TyVar "c")) (TyVar "b"))))) (mdef ((PVar "f")) (EApp (EApp (EVar "bimap") (EVar "f")) (EVar "identity")))) (imethod "mapSecond" (TyFun (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "d"))) (TyFun (TyApp (TyApp (TyVar "p") (TyVar "a")) (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyApp (TyVar "p") (TyVar "a")) (TyVar "d"))))) (mdef ((PVar "g")) (EApp (EApp (EVar "bimap") (EVar "identity")) (EVar "g"))))))
(DImpl true "Bimappable" ((TyCon "Result")) () ((im "bimap" ((PVar "f") PWild (PCon "Err" (PVar "e"))) (EApp (EVar "Err") (EApp (EVar "f") (EVar "e")))) (im "bimap" (PWild (PVar "g") (PCon "Ok" (PVar "a"))) (EApp (EVar "Ok") (EApp (EVar "g") (EVar "a")))) (im "mapFirst" ((PVar "f")) (EApp (EApp (EVar "bimap") (EVar "f")) (EVar "identity"))) (im "mapSecond" ((PVar "g")) (EApp (EApp (EVar "bimap") (EVar "identity")) (EVar "g")))))
(DImpl true "Bimappable" ((TyCon "__tuple2__")) () ((im "bimap" ((PVar "f") (PVar "g") (PTuple (PVar "x") (PVar "y"))) (ETuple (EApp (EVar "f") (EVar "x")) (EApp (EVar "g") (EVar "y")))) (im "mapFirst" ((PVar "f")) (EApp (EApp (EVar "bimap") (EVar "f")) (EVar "identity"))) (im "mapSecond" ((PVar "g")) (EApp (EApp (EVar "bimap") (EVar "identity")) (EVar "g")))))
(DInterface true false "Foldable" ("t") () ((imethod "fold" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))) None) (imethod "foldRight" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))) None) (imethod "foldMap" (TyConstrained ((cstr "Monoid" (TyVar "m"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "m"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyVar "m"))))) (mdef ((PVar "f")) (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "++" (EVar "acc") (EApp (EVar "f") (EVar "x"))))) (EVar "empty")))) (imethod "toList" (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))) None) (imethod "isEmpty" (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyCon "Bool")) (mdef ((PVar "t")) (EMatch (EApp (EVar "toList") (EVar "t")) (arm (PList) () (EVar "True")) (arm PWild () (EVar "False"))))) (imethod "length" (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyCon "Int")) (mdef ((PVar "t")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") PWild) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))) (ELit (LInt 0))) (EVar "t"))))))
(DInterface true false "Filterable" ("f") ((super "Mappable" ("f"))) ((imethod "filterMap" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "b")))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyVar "f") (TyVar "b"))))) None) (imethod "filter" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyVar "f") (TyVar "a"))))) (mdef ((PVar "p")) (EApp (EVar "filterMap") (ELam ((PVar "x")) (EIf (EApp (EVar "p") (EVar "x")) (EApp (EVar "Some") (EVar "x")) (EVar "None"))))))))
(DInterface true false "FromEntries" ("c" "e") () ((imethod "fromEntries" (TyFun (TyApp (TyCon "List") (TyVar "e")) (TyVar "c")) None)))
(DInterface true false "Index" ("c" "k" "v") () ((imethod "index" (TyFun (TyVar "c") (TyFun (TyVar "k") (TyVar "v"))) None)))
(DInterface true false "IndexMut" ("c" "k" "v") ((super "Index" ("c" "k" "v"))) ((imethod "setIndex" (TyFun (TyVar "c") (TyFun (TyVar "k") (TyFun (TyVar "v") (TyVar "c")))) None)))
(DImpl true "Index" ((TyApp (TyCon "Array") (TyVar "a")) (TyCon "Int") (TyVar "a")) () ((im "index" ((PVar "arr") (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EApp (EVar "indexError") (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " out of bounds")))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))))
(DImpl true "IndexMut" ((TyApp (TyCon "Array") (TyVar "a")) (TyCon "Int") (TyVar "a")) () ((im "setIndex" ((PVar "arr") (PVar "i") (PVar "v")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EApp (EVar "indexError") (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " out of bounds")))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "v")) (EVar "arr"))) (DoExpr (EVar "arr")))))))
(DImpl true "Index" ((TyApp (TyCon "List") (TyVar "a")) (TyCon "Int") (TyVar "a")) () ((im "index" ((PList) PWild) (EApp (EVar "indexError") (ELit (LString "index out of bounds")))) (im "index" ((PCons (PVar "h") (PVar "t")) (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "h") (EApp (EApp (EVar "index") (EVar "t")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))))
(DImpl true "Index" ((TyCon "String") (TyCon "Int") (TyCon "Char")) () ((im "index" ((PVar "s") (PVar "i")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs")))) (EApp (EVar "indexError") (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " out of bounds")))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))))))
(DImpl true "Foldable" ((TyCon "List")) () ((im "fold" (PWild (PVar "acc") (PList)) (EVar "acc")) (im "fold" ((PVar "f") (PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EApp (EVar "fold") (EVar "f")) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "x"))) (EVar "xs"))) (im "foldRight" (PWild (PVar "acc") (PList)) (EVar "acc")) (im "foldRight" ((PVar "f") (PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "f") (EVar "x")) (EApp (EApp (EApp (EVar "foldRight") (EVar "f")) (EVar "acc")) (EVar "xs")))) (im "toList" () (EVar "identity")) (im "isEmpty" ((PList)) (EVar "True")) (im "isEmpty" (PWild) (EVar "False")) (im "length" () (EApp (EApp (EVar "fold") (ELam ((PVar "acc") PWild) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))) (ELit (LInt 0)))) (im "foldMap" ((PVar "f")) (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "++" (EVar "acc") (EApp (EVar "f") (EVar "x"))))) (EVar "empty")))))
(DImpl true "Foldable" ((TyCon "Option")) () ((im "fold" (PWild (PVar "acc") (PCon "None")) (EVar "acc")) (im "fold" ((PVar "f") (PVar "acc") (PCon "Some" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "x"))) (im "foldRight" (PWild (PVar "acc") (PCon "None")) (EVar "acc")) (im "foldRight" ((PVar "f") (PVar "acc") (PCon "Some" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "x")) (EVar "acc"))) (im "toList" ((PCon "None")) (EListLit)) (im "toList" ((PCon "Some" (PVar "x"))) (EListLit (EVar "x"))) (im "foldMap" ((PVar "f")) (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "++" (EVar "acc") (EApp (EVar "f") (EVar "x"))))) (EVar "empty"))) (im "isEmpty" ((PVar "t")) (EMatch (EApp (EVar "toList") (EVar "t")) (arm (PList) () (EVar "True")) (arm PWild () (EVar "False")))) (im "length" ((PVar "t")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") PWild) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))) (ELit (LInt 0))) (EVar "t")))))
(DImpl true "Foldable" ((TyApp (TyCon "Result") (TyVar "e"))) () ((im "fold" (PWild (PVar "acc") (PCon "Err" PWild)) (EVar "acc")) (im "fold" ((PVar "f") (PVar "acc") (PCon "Ok" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "x"))) (im "foldRight" (PWild (PVar "acc") (PCon "Err" PWild)) (EVar "acc")) (im "foldRight" ((PVar "f") (PVar "acc") (PCon "Ok" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "x")) (EVar "acc"))) (im "toList" ((PCon "Err" PWild)) (EListLit)) (im "toList" ((PCon "Ok" (PVar "x"))) (EListLit (EVar "x"))) (im "foldMap" ((PVar "f")) (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "++" (EVar "acc") (EApp (EVar "f") (EVar "x"))))) (EVar "empty"))) (im "isEmpty" ((PVar "t")) (EMatch (EApp (EVar "toList") (EVar "t")) (arm (PList) () (EVar "True")) (arm PWild () (EVar "False")))) (im "length" ((PVar "t")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") PWild) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))) (ELit (LInt 0))) (EVar "t")))))
(DInterface true false "Traversable" ("t") ((super "Mappable" ("t")) (super "Foldable" ("t"))) ((imethod "traverse" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyVar "m") (TyVar "b")))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyVar "m") (TyApp (TyVar "t") (TyVar "b"))))))) None) (imethod "sequence" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyApp (TyVar "t") (TyApp (TyVar "m") (TyVar "a"))) (TyEffect () (Some "e") (TyApp (TyVar "m") (TyApp (TyVar "t") (TyVar "a")))))) (mdef ((PVar "ta")) (EApp (EApp (EVar "traverse") (EVar "identity")) (EVar "ta"))))))
(DImpl true "Traversable" ((TyCon "List")) () ((im "traverse" ((PVar "f") (PVar "xs")) (EMatch (EVar "xs") (arm (PList) () (EApp (EVar "pure") (EListLit))) (arm (PCons (PVar "x") (PVar "rest")) () (EApp (EApp (EVar "andThen") (EApp (EVar "f") (EVar "x"))) (ELam ((PVar "y")) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "y") (EVar "_s")))) (EApp (EApp (EVar "traverse") (EVar "f")) (EVar "rest")))))))) (im "sequence" ((PVar "ta")) (EApp (EApp (EVar "traverse") (EVar "identity")) (EVar "ta")))))
(DImpl true "Traversable" ((TyCon "Option")) () ((im "traverse" ((PVar "f") (PVar "opt")) (EMatch (EVar "opt") (arm (PCon "None") () (EApp (EVar "pure") (EVar "None"))) (arm (PCon "Some" (PVar "x")) () (EApp (EApp (EVar "map") (EVar "Some")) (EApp (EVar "f") (EVar "x")))))) (im "sequence" ((PVar "ta")) (EApp (EApp (EVar "traverse") (EVar "identity")) (EVar "ta")))))
(DImpl true "Traversable" ((TyApp (TyCon "Result") (TyVar "e"))) () ((im "traverse" ((PVar "f") (PVar "res")) (EMatch (EVar "res") (arm (PCon "Err" (PVar "e")) () (EApp (EVar "pure") (EApp (EVar "Err") (EVar "e")))) (arm (PCon "Ok" (PVar "x")) () (EApp (EApp (EVar "map") (EVar "Ok")) (EApp (EVar "f") (EVar "x")))))) (im "sequence" ((PVar "ta")) (EApp (EApp (EVar "traverse") (EVar "identity")) (EVar "ta")))))
(DTypeSig true "any" (TyConstrained ((cstr "Foldable" (TyVar "t"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyCon "Bool"))))))
(DFunDef false "any" ((PVar "f")) (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "||" (EVar "acc") (EApp (EVar "f") (EVar "x"))))) (EVar "False")))
(DTypeSig true "all" (TyConstrained ((cstr "Foldable" (TyVar "t"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyCon "Bool"))))))
(DFunDef false "all" ((PVar "f")) (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "&&" (EVar "acc") (EApp (EVar "f") (EVar "x"))))) (EVar "True")))
(DTypeSig true "find" (TyConstrained ((cstr "Foldable" (TyVar "t"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a")))))))
(DFunDef false "find" ((PVar "f")) (ELetGroup ((lgb "g" (clause ((PAs "acc" (PCon "Some" PWild)) PWild) (EVar "acc")) (clause ((PCon "None") (PVar "x")) (EIf (EApp (EVar "f") (EVar "x")) (EApp (EVar "Some") (EVar "x")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EApp (EVar "fold") (EVar "g")) (EVar "None"))))
(DTypeSig true "count" (TyConstrained ((cstr "Foldable" (TyVar "t"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyCon "Int"))))))
(DFunDef false "count" ((PVar "f")) (ELetGroup ((lgb "g" (clause ((PVar "acc") (PVar "x")) (EIf (EApp (EVar "f") (EVar "x")) (EBinOp "+" (EVar "acc") (ELit (LInt 1))) (EIf (EVar "otherwise") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EApp (EVar "fold") (EVar "g")) (ELit (LInt 0)))))
(DTypeSig true "sum" (TyConstrained ((cstr "Foldable" (TyVar "t")) (cstr "Num" (TyVar "a"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyVar "a"))))
(DFunDef false "sum" ((PVar "xs")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "+" (EVar "_a") (EVar "_b")))) (EApp (EVar "fromInt") (ELit (LInt 0)))) (EVar "xs")))
(DTypeSig true "product" (TyConstrained ((cstr "Foldable" (TyVar "t")) (cstr "Num" (TyVar "a"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyVar "a"))))
(DFunDef false "product" ((PVar "xs")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "*" (EVar "_a") (EVar "_b")))) (EApp (EVar "fromInt") (ELit (LInt 1)))) (EVar "xs")))
(DTypeSig true "elem" (TyConstrained ((cstr "Foldable" (TyVar "t")) (cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "elem" ((PVar "a")) (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "||" (EVar "acc") (EBinOp "==" (EVar "x") (EVar "a"))))) (EVar "False")))
(DTypeSig true "notElem" (TyConstrained ((cstr "Foldable" (TyVar "t")) (cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "notElem" ((PVar "a") (PVar "xs")) (EApp (EVar "not") (EApp (EApp (EVar "elem") (EVar "a")) (EVar "xs"))))
(DTypeSig true "maximum" (TyConstrained ((cstr "Foldable" (TyVar "t")) (cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "maximum" () (ELetGroup ((lgb "step" (clause ((PCon "None") (PVar "x")) (EApp (EVar "Some") (EVar "x"))) (clause ((PCon "Some" (PVar "m")) (PVar "x")) (EApp (EVar "Some") (EApp (EApp (EVar "max") (EVar "m")) (EVar "x")))))) (EApp (EApp (EVar "fold") (EVar "step")) (EVar "None"))))
(DTypeSig true "minimum" (TyConstrained ((cstr "Foldable" (TyVar "t")) (cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "minimum" () (ELetGroup ((lgb "step" (clause ((PCon "None") (PVar "x")) (EApp (EVar "Some") (EVar "x"))) (clause ((PCon "Some" (PVar "m")) (PVar "x")) (EApp (EVar "Some") (EApp (EApp (EVar "min") (EVar "m")) (EVar "x")))))) (EApp (EApp (EVar "fold") (EVar "step")) (EVar "None"))))
(DImpl true "Filterable" ((TyCon "List")) () ((im "filterMap" (PWild (PList)) (EListLit)) (im "filterMap" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EMatch (EApp (EVar "f") (EVar "x")) (arm (PCon "Some" (PVar "y")) () (EBinOp "::" (EVar "y") (EApp (EApp (EVar "filterMap") (EVar "f")) (EVar "xs")))) (arm (PCon "None") () (EApp (EApp (EVar "filterMap") (EVar "f")) (EVar "xs"))))) (im "filter" ((PVar "p")) (EApp (EVar "filterMap") (ELam ((PVar "x")) (EIf (EApp (EVar "p") (EVar "x")) (EApp (EVar "Some") (EVar "x")) (EVar "None")))))))
(DTypeSig true "otherwise" (TyCon "Bool"))
(DFunDef false "otherwise" () (EVar "True"))
(DTypeSig true "not" (TyFun (TyCon "Bool") (TyCon "Bool")))
(DFunDef false "not" ((PCon "True")) (EVar "False"))
(DFunDef false "not" ((PCon "False")) (EVar "True"))
(DTypeSig true "and" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "and" ((PCon "True") (PCon "True")) (EVar "True"))
(DFunDef false "and" (PWild PWild) (EVar "False"))
(DTypeSig true "or" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "or" ((PCon "False") (PCon "False")) (EVar "False"))
(DFunDef false "or" (PWild PWild) (EVar "True"))
(DTypeSig true "xor" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "xor" ((PVar "a") (PVar "b")) (EBinOp "!=" (EVar "a") (EVar "b")))
(DTypeSig true "isSome" (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isSome" ((PCon "Some" PWild)) (EVar "True"))
(DFunDef false "isSome" ((PCon "None")) (EVar "False"))
(DTypeSig true "isNone" (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isNone" ((PCon "None")) (EVar "True"))
(DFunDef false "isNone" ((PCon "Some" PWild)) (EVar "False"))
(DTypeSig true "fromOption" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyVar "a"))))
(DFunDef false "fromOption" (PWild (PCon "Some" (PVar "a"))) (EVar "a"))
(DFunDef false "fromOption" ((PVar "d") (PCon "None")) (EVar "d"))
(DTypeSig true "toResult" (TyFun (TyVar "e") (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")))))
(DFunDef false "toResult" (PWild (PCon "Some" (PVar "a"))) (EApp (EVar "Ok") (EVar "a")))
(DFunDef false "toResult" ((PVar "e") (PCon "None")) (EApp (EVar "Err") (EVar "e")))
(DTypeSig true "fromResult" (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "fromResult" ((PCon "Ok" (PVar "a"))) (EApp (EVar "Some") (EVar "a")))
(DFunDef false "fromResult" ((PCon "Err" PWild)) (EVar "None"))
(DTypeSig true "isOk" (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isOk" ((PCon "Ok" PWild)) (EVar "True"))
(DFunDef false "isOk" ((PCon "Err" PWild)) (EVar "False"))
(DTypeSig true "isErr" (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isErr" ((PCon "Err" PWild)) (EVar "True"))
(DFunDef false "isErr" ((PCon "Ok" PWild)) (EVar "False"))
(DTypeSig true "fromResultOr" (TyFun (TyVar "a") (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyVar "a"))))
(DFunDef false "fromResultOr" (PWild (PCon "Ok" (PVar "a"))) (EVar "a"))
(DFunDef false "fromResultOr" ((PVar "d") (PCon "Err" PWild)) (EVar "d"))
(DTypeSig true "mapErr" (TyFun (TyFun (TyVar "e") (TyVar "f")) (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Result") (TyVar "f")) (TyVar "a")))))
(DFunDef false "mapErr" ((PVar "f") (PCon "Err" (PVar "e"))) (EApp (EVar "Err") (EApp (EVar "f") (EVar "e"))))
(DFunDef false "mapErr" (PWild (PCon "Ok" (PVar "a"))) (EApp (EVar "Ok") (EVar "a")))
(DTypeSig true "identity" (TyFun (TyVar "a") (TyVar "a")))
(DFunDef false "identity" ((PVar "x")) (EVar "x"))
(DTypeSig true "fst" (TyFun (TyTuple (TyVar "a") (TyVar "b")) (TyVar "a")))
(DFunDef false "fst" ((PTuple (PVar "a") PWild)) (EVar "a"))
(DTypeSig true "snd" (TyFun (TyTuple (TyVar "a") (TyVar "b")) (TyVar "b")))
(DFunDef false "snd" ((PTuple PWild (PVar "b"))) (EVar "b"))
(DTypeSig true "const" (TyFun (TyVar "a") (TyFun (TyVar "b") (TyVar "a"))))
(DFunDef false "const" ((PVar "x") PWild) (EVar "x"))
(DTypeSig true "flip" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c")))) (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "c"))))))
(DFunDef false "flip" ((PVar "f") (PVar "b") (PVar "a")) (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")))
(DTypeSig true "on" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c")))) (TyFun (TyFun (TyVar "a") (TyVar "b")) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "c")))))))
(DFunDef false "on" ((PVar "f") (PVar "g") (PVar "x") (PVar "y")) (EApp (EApp (EVar "f") (EApp (EVar "g") (EVar "x"))) (EApp (EVar "g") (EVar "y"))))
(DTypeSig true "curry" (TyFun (TyFun (TyTuple (TyVar "a") (TyVar "b")) (TyEffect () (Some "e") (TyVar "c"))) (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c"))))))
(DFunDef false "curry" ((PVar "f") (PVar "a") (PVar "b")) (EApp (EVar "f") (ETuple (EVar "a") (EVar "b"))))
(DTypeSig true "uncurry" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c")))) (TyFun (TyTuple (TyVar "a") (TyVar "b")) (TyEffect () (Some "e") (TyVar "c")))))
(DFunDef false "uncurry" ((PVar "f") (PTuple (PVar "a") (PVar "b"))) (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")))
(DTypeSig true "discard" (TyConstrained ((cstr "Mappable" (TyVar "f"))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyApp (TyVar "f") (TyCon "Unit")))))
(DFunDef false "discard" ((PVar "fa")) (EApp (EApp (EVar "map") (ELam (PWild) (ELit LUnit))) (EVar "fa")))
(DTypeSig true "compose" (TyFun (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "c"))))))
(DFunDef false "compose" ((PVar "g") (PVar "f") (PVar "a")) (EApp (EVar "g") (EApp (EVar "f") (EVar "a"))))
(DTypeSig true "pipe" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c"))) (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "c"))))))
(DFunDef false "pipe" ((PVar "f") (PVar "g") (PVar "a")) (EApp (EVar "g") (EApp (EVar "f") (EVar "a"))))
(DTypeSig true "apply" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))))
(DFunDef false "apply" ((PVar "f") (PVar "a")) (EApp (EVar "f") (EVar "a")))
(DInterface true false "Arbitrary" ("a") () ((imethod "arbitrary" (TyFun (TyCon "Unit") (TyEffect ("Rand") None (TyVar "a"))) None) (imethod "shrink" (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a"))) (mdef (PWild) (EListLit)))))
(DImpl true "Arbitrary" ((TyCon "Int")) () ((im "arbitrary" ((PLit LUnit)) (EApp (EApp (EVar "randomInt") (EUnOp "-" (ELit (LInt 1000)))) (ELit (LInt 1000)))) (im "shrink" ((PLit (LInt 0))) (EListLit)) (im "shrink" ((PVar "n")) (EListLit (ELit (LInt 0)) (EBinOp "/" (EVar "n") (ELit (LInt 2)))))))
(DImpl true "Arbitrary" ((TyCon "Bool")) () ((im "arbitrary" ((PLit LUnit)) (EApp (EVar "randomBool") (ELit LUnit))) (im "shrink" (PWild) (EListLit))))
(DImpl true "Arbitrary" ((TyCon "Float")) () ((im "arbitrary" ((PLit LUnit)) (EApp (EVar "randomFloat") (ELit LUnit))) (im "shrink" (PWild) (EListLit))))
(DImpl true "Arbitrary" ((TyCon "Char")) () ((im "arbitrary" ((PLit LUnit)) (EApp (EVar "randomChar") (ELit LUnit))) (im "shrink" (PWild) (EListLit))))
(DTypeSig true "arbitraryString" (TyFun (TyCon "Unit") (TyEffect ("Rand") None (TyCon "String"))))
(DFunDef false "arbitraryString" ((PLit LUnit)) (ELetGroup ((lgb "go" (clause ((PLit (LInt 0)) (PVar "acc")) (EVar "acc")) (clause ((PVar "n") (PVar "acc")) (EApp (EApp (EVar "go") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EVar "randomChar") (ELit LUnit)))))))) (EApp (EApp (EVar "go") (EApp (EApp (EVar "randomInt") (ELit (LInt 0))) (ELit (LInt 10)))) (ELit (LString "")))))
(DImpl true "Arbitrary" ((TyCon "String")) () ((im "arbitrary" ((PLit LUnit)) (EApp (EVar "arbitraryString") (ELit LUnit))) (im "shrink" (PWild) (EListLit))))
(DTypeSig true "arbitraryList" (TyFun (TyFun (TyCon "Unit") (TyEffect ("Rand") None (TyVar "a"))) (TyFun (TyCon "Int") (TyEffect ("Rand") None (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "arbitraryList" ((PVar "gen") (PVar "maxLen")) (ELetGroup ((lgb "go" (clause ((PLit (LInt 0)) (PVar "acc")) (EVar "acc")) (clause ((PVar "n") (PVar "acc")) (EApp (EApp (EVar "go") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "gen") (ELit LUnit)) (EVar "acc")))))) (EApp (EApp (EVar "go") (EApp (EApp (EVar "randomInt") (ELit (LInt 0))) (EVar "maxLen"))) (EListLit))))
(DData Public "Rep" () ((variant "RCon" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Rep")))) (variant "RRecord" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "RField")))) (variant "RInt" (ConPos (TyCon "Int"))) (variant "RFloat" (ConPos (TyCon "Float"))) (variant "RString" (ConPos (TyCon "String"))) (variant "RBool" (ConPos (TyCon "Bool"))) (variant "RChar" (ConPos (TyCon "Char"))) (variant "RUnit" (ConPos))) ())
(DData Public "RField" () ((variant "RField" (ConNamed (field "fld_name" (TyCon "String")) (field "fld_rep" (TyCon "Rep"))))) ())
(DInterface true false "Generic" ("a") () ((imethod "to_rep" (TyFun (TyVar "a") (TyCon "Rep")) None) (imethod "from_rep" (TyFun (TyCon "Rep") (TyVar "a")) (mdef (PWild) (EApp (EVar "panic") (ELit (LString "from_rep: not implemented (Phase 1 is to_rep only)")))))))
(DImpl true "Generic" ((TyCon "Int")) () ((im "to_rep" ((PVar "n")) (EApp (EVar "RInt") (EVar "n"))) (im "from_rep" (PWild) (EApp (EVar "panic") (ELit (LString "from_rep: not implemented (Phase 1 is to_rep only)"))))))
(DImpl true "Generic" ((TyCon "Float")) () ((im "to_rep" ((PVar "x")) (EApp (EVar "RFloat") (EVar "x"))) (im "from_rep" (PWild) (EApp (EVar "panic") (ELit (LString "from_rep: not implemented (Phase 1 is to_rep only)"))))))
(DImpl true "Generic" ((TyCon "String")) () ((im "to_rep" ((PVar "s")) (EApp (EVar "RString") (EVar "s"))) (im "from_rep" (PWild) (EApp (EVar "panic") (ELit (LString "from_rep: not implemented (Phase 1 is to_rep only)"))))))
(DImpl true "Generic" ((TyCon "Bool")) () ((im "to_rep" ((PVar "b")) (EApp (EVar "RBool") (EVar "b"))) (im "from_rep" (PWild) (EApp (EVar "panic") (ELit (LString "from_rep: not implemented (Phase 1 is to_rep only)"))))))
(DImpl true "Generic" ((TyCon "Char")) () ((im "to_rep" ((PVar "c")) (EApp (EVar "RChar") (EVar "c"))) (im "from_rep" (PWild) (EApp (EVar "panic") (ELit (LString "from_rep: not implemented (Phase 1 is to_rep only)"))))))
(DImpl true "Generic" ((TyCon "Unit")) () ((im "to_rep" (PWild) (EVar "RUnit")) (im "from_rep" (PWild) (EApp (EVar "panic") (ELit (LString "from_rep: not implemented (Phase 1 is to_rep only)"))))))
(DProp false "neq is the negation of eq" ((pp "x" (TyCon "Int")) (pp "y" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "neq") (EVar "x")) (EVar "y")) (EApp (EVar "not") (EApp (EApp (EVar "eq") (EVar "x")) (EVar "y")))))
(DProp false "compare agrees with lt/gt/eq" ((pp "x" (TyCon "Int")) (pp "y" (TyCon "Int"))) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "lt") (EVar "x")) (EVar "y")) (EApp (EVar "not") (EApp (EApp (EVar "gt") (EVar "x")) (EVar "y")))) (EApp (EApp (EVar "neq") (EVar "x")) (EVar "y")))) (arm (PCon "Gt") () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "gt") (EVar "x")) (EVar "y")) (EApp (EVar "not") (EApp (EApp (EVar "lt") (EVar "x")) (EVar "y")))) (EApp (EApp (EVar "neq") (EVar "x")) (EVar "y")))) (arm (PCon "Eq") () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "x")) (EVar "y")) (EApp (EVar "not") (EApp (EApp (EVar "lt") (EVar "x")) (EVar "y")))) (EApp (EVar "not") (EApp (EApp (EVar "gt") (EVar "x")) (EVar "y")))))))
(DProp false "clamp keeps values inside the interval" ((pp "x" (TyCon "Int"))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "clamp") (ELit (LInt 0))) (ELit (LInt 100))) (EVar "x"))) (DoExpr (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 0))) (EBinOp "<=" (EVar "c") (ELit (LInt 100)))))))
(DProp false "filter . filter p == filter p" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "filter") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 0))))) (EApp (EApp (EVar "filter") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 0))))) (EVar "xs")))) (EApp (EApp (EVar "filter") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 0))))) (EVar "xs"))))
(DProp false "length matches a counting fold" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EVar "length") (EVar "xs")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") PWild) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))) (ELit (LInt 0))) (EVar "xs"))))
(DProp false "any/all duality" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EApp (EVar "any") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 0))))) (EVar "xs")) (EApp (EVar "not") (EApp (EApp (EVar "all") (ELam ((PVar "x")) (EBinOp "<=" (EVar "x") (ELit (LInt 0))))) (EVar "xs")))))
(DProp false "fromOption d (Some x) == x" ((pp "x" (TyCon "Int")) (pp "d" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "fromOption") (EVar "d")) (EApp (EVar "Some") (EVar "x"))) (EVar "x")))
(DProp false "toResult/fromResult round-trip on Some" ((pp "x" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EVar "fromResult") (EApp (EApp (EVar "toResult") (ELit (LString "missing"))) (EApp (EVar "Some") (EVar "x"))))) (EApp (EVar "Some") (EVar "x"))))
(DProp false "Ord (List a) is reflexive" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EMatch (EApp (EApp (EVar "compare") (EVar "xs")) (EVar "xs")) (arm (PCon "Eq") () (EVar "True")) (arm PWild () (EVar "False"))))
(DProp false "discard replaces the payload with Unit" ((pp "x" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EVar "discard") (EApp (EVar "Some") (EVar "x")))) (EApp (EVar "Some") (ELit LUnit))))
(DProp false "on agrees with its hand expansion" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EApp (EApp (EVar "on") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (ELam ((PVar "n")) (EBinOp "*" (EVar "n") (ELit (LInt 2))))) (EVar "a")) (EVar "b")) (EBinOp "+" (EBinOp "*" (EVar "a") (ELit (LInt 2))) (EBinOp "*" (EVar "b") (ELit (LInt 2))))))
(DProp false "map2 on Some matches direct application" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EApp (EVar "map2") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EApp (EVar "Some") (EVar "a"))) (EApp (EVar "Some") (EVar "b")))) (EApp (EVar "Some") (EBinOp "+" (EVar "a") (EVar "b")))))
(DProp false "map3 on Some matches direct application" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int")) (pp "c" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EApp (EApp (EVar "map3") (ELam ((PVar "x") (PVar "y") (PVar "z")) (EBinOp "+" (EBinOp "+" (EVar "x") (EVar "y")) (EVar "z")))) (EApp (EVar "Some") (EVar "a"))) (EApp (EVar "Some") (EVar "b"))) (EApp (EVar "Some") (EVar "c")))) (EApp (EVar "Some") (EBinOp "+" (EBinOp "+" (EVar "a") (EVar "b")) (EVar "c")))))
(DProp false "mapFirst on Result generalizes mapErr" ((pp "n" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "mapFirst") (ELam ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))) (EAnnot (EApp (EVar "Err") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int"))))) (EApp (EApp (EVar "mapErr") (ELam ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))) (EApp (EVar "Err") (EVar "n")))))
(DProp false "foldThen with Some agrees with a pure fold" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "eq") (EApp (EApp (EApp (EVar "foldThen") (ELam ((PVar "acc") (PVar "x")) (EApp (EVar "Some") (EBinOp "+" (EVar "acc") (EVar "x"))))) (ELit (LInt 0))) (EVar "xs"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "+" (EVar "acc") (EVar "x")))) (ELit (LInt 0))) (EVar "xs")))))
# MARK
(DData Public "Ordering" () ((variant "Lt" (ConPos)) (variant "Eq" (ConPos)) (variant "Gt" (ConPos))) ())
(DData Public "Option" ("a") ((variant "Some" (ConPos (TyVar "a"))) (variant "None" (ConPos))) ())
(DData Public "Result" ("e" "a") ((variant "Ok" (ConPos (TyVar "a"))) (variant "Err" (ConPos (TyVar "e")))) ())
(DInterface true false "Eq" ("a") () ((imethod "eq" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) None)))
(DTypeSig true "neq" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool")))))
(DFunDef false "neq" ((PVar "x") (PVar "y")) (EApp (EVar "not") (EApp (EApp (EMethodRef "eq") (EVar "x")) (EVar "y"))))
(DImpl true "Eq" ((TyCon "Int")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl true "Eq" ((TyCon "Float")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl true "Eq" ((TyCon "Bool")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl true "Eq" ((TyCon "String")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl true "Eq" ((TyCon "Char")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl true "Eq" ((TyCon "Unit")) () ((im "eq" (PWild PWild) (EVar "True"))))
(DImpl true "Eq" ((TyApp (TyCon "List") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PList) (PList)) (EVar "True")) (im "eq" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "x")) (EVar "y")) (EApp (EApp (EMethodRef "eq") (EVar "xs")) (EVar "ys")))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl true "Eq" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "None") (PCon "None")) (EVar "True")) (im "eq" ((PCon "Some" (PVar "x")) (PCon "Some" (PVar "y"))) (EApp (EApp (EMethodRef "eq") (EVar "x")) (EVar "y"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl true "Eq" ((TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) ((req "Eq" ((TyVar "e"))) (req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "Ok" (PVar "x")) (PCon "Ok" (PVar "y"))) (EApp (EApp (EMethodRef "eq") (EVar "x")) (EVar "y"))) (im "eq" ((PCon "Err" (PVar "x")) (PCon "Err" (PVar "y"))) (EApp (EApp (EMethodRef "eq") (EVar "x")) (EVar "y"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl true "Eq" ((TyTuple (TyVar "a") (TyVar "b"))) ((req "Eq" ((TyVar "a"))) (req "Eq" ((TyVar "b")))) ((im "eq" ((PTuple (PVar "a1") (PVar "b1")) (PTuple (PVar "a2") (PVar "b2"))) (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "a1")) (EVar "a2")) (EApp (EApp (EMethodRef "eq") (EVar "b1")) (EVar "b2"))))))
(DImpl true "Eq" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c"))) ((req "Eq" ((TyVar "a"))) (req "Eq" ((TyVar "b"))) (req "Eq" ((TyVar "c")))) ((im "eq" ((PTuple (PVar "a1") (PVar "b1") (PVar "c1")) (PTuple (PVar "a2") (PVar "b2") (PVar "c2"))) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "a1")) (EVar "a2")) (EApp (EApp (EMethodRef "eq") (EVar "b1")) (EVar "b2"))) (EApp (EApp (EMethodRef "eq") (EVar "c1")) (EVar "c2"))))))
(DImpl true "Eq" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d"))) ((req "Eq" ((TyVar "a"))) (req "Eq" ((TyVar "b"))) (req "Eq" ((TyVar "c"))) (req "Eq" ((TyVar "d")))) ((im "eq" ((PTuple (PVar "a1") (PVar "b1") (PVar "c1") (PVar "d1")) (PTuple (PVar "a2") (PVar "b2") (PVar "c2") (PVar "d2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "a1")) (EVar "a2")) (EApp (EApp (EMethodRef "eq") (EVar "b1")) (EVar "b2"))) (EApp (EApp (EMethodRef "eq") (EVar "c1")) (EVar "c2"))) (EApp (EApp (EMethodRef "eq") (EVar "d1")) (EVar "d2"))))))
(DImpl true "Eq" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d") (TyVar "e"))) ((req "Eq" ((TyVar "a"))) (req "Eq" ((TyVar "b"))) (req "Eq" ((TyVar "c"))) (req "Eq" ((TyVar "d"))) (req "Eq" ((TyVar "e")))) ((im "eq" ((PTuple (PVar "a1") (PVar "b1") (PVar "c1") (PVar "d1") (PVar "e1")) (PTuple (PVar "a2") (PVar "b2") (PVar "c2") (PVar "d2") (PVar "e2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "a1")) (EVar "a2")) (EApp (EApp (EMethodRef "eq") (EVar "b1")) (EVar "b2"))) (EApp (EApp (EMethodRef "eq") (EVar "c1")) (EVar "c2"))) (EApp (EApp (EMethodRef "eq") (EVar "d1")) (EVar "d2"))) (EApp (EApp (EMethodRef "eq") (EVar "e1")) (EVar "e2"))))))
(DInterface true false "Semigroup" ("a") () ((imethod "append" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))) None)))
(DImpl true "Semigroup" ((TyApp (TyCon "List") (TyVar "a"))) () ((im "append" ((PVar "xs") (PVar "ys")) (EBinOp "++" (EVar "xs") (EVar "ys")))))
(DImpl true "Semigroup" ((TyCon "String")) () ((im "append" ((PVar "s1") (PVar "s2")) (EBinOp "++" (EVar "s1") (EVar "s2")))))
(DInterface true false "Monoid" ("a") ((super "Semigroup" ("a"))) ((imethod "empty" (TyVar "a") None)))
(DImpl true "Monoid" ((TyApp (TyCon "List") (TyVar "a"))) () ((im "empty" () (EListLit))))
(DImpl true "Monoid" ((TyCon "String")) () ((im "empty" () (ELit (LString "")))))
(DInterface true false "Ord" ("a") ((super "Eq" ("a"))) ((imethod "compare" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Ordering"))) None) (imethod "lt" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) (mdef ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False"))))) (imethod "gt" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) (mdef ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False"))))) (imethod "lte" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) (mdef ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True"))))) (imethod "gte" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) (mdef ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True"))))) (imethod "min" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))) (mdef ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x"))))) (imethod "max" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))) (mdef ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x")))))))
(DTypeSig true "clamp" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))))))
(DFunDef false "clamp" ((PVar "lo") (PVar "hi")) (EBinOp ">>" (EApp (EMethodRef "min") (EVar "hi")) (EApp (EMethodRef "max") (EVar "lo"))))
(DTypeSig true "isEven" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isEven" ((PVar "n")) (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 0))))
(DTypeSig true "isOdd" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isOdd" ((PVar "n")) (EBinOp "!=" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 0))))
(DImpl true "Ord" ((TyCon "Int")) () ((im "compare" ((PVar "a") (PVar "b")) (EIf (EBinOp "<" (EVar "a") (EVar "b")) (EVar "Lt") (EIf (EBinOp ">" (EVar "a") (EVar "b")) (EVar "Gt") (EVar "Eq")))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DTypeSig false "floatSignBit" (TyFun (TyCon "Float") (TyCon "Bool")))
(DFunDef false "floatSignBit" ((PVar "x")) (EBinOp ">=" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "floatToBytes64") (EVar "x"))) (ELit (LInt 128))))
(DTypeSig false "compareBySign" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Ordering"))))
(DFunDef false "compareBySign" ((PVar "a") (PVar "b")) (EMatch (ETuple (EApp (EVar "floatSignBit") (EVar "a")) (EApp (EVar "floatSignBit") (EVar "b"))) (arm (PTuple (PCon "True") (PCon "False")) () (EVar "Lt")) (arm (PTuple (PCon "False") (PCon "True")) () (EVar "Gt")) (arm PWild () (EVar "Eq"))))
(DTypeSig false "compareNaN" (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyCon "Ordering"))))
(DFunDef false "compareNaN" ((PVar "a") (PVar "b")) (EIf (EBinOp "&&" (EBinOp "!=" (EVar "a") (EVar "a")) (EBinOp "!=" (EVar "b") (EVar "b"))) (EApp (EApp (EVar "compareBySign") (EVar "a")) (EVar "b")) (EIf (EBinOp "!=" (EVar "a") (EVar "a")) (EIf (EApp (EVar "floatSignBit") (EVar "a")) (EVar "Lt") (EVar "Gt")) (EIf (EVar "otherwise") (EIf (EApp (EVar "floatSignBit") (EVar "b")) (EVar "Gt") (EVar "Lt")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DImpl true "Ord" ((TyCon "Float")) () ((im "compare" ((PVar "a") (PVar "b")) (EIf (EBinOp "<" (EVar "a") (EVar "b")) (EVar "Lt") (EIf (EBinOp ">" (EVar "a") (EVar "b")) (EVar "Gt") (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EApp (EVar "compareBySign") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "compareNaN") (EVar "a")) (EVar "b")))))) (im "lt" ((PVar "a") (PVar "b")) (EBinOp "<" (EVar "a") (EVar "b"))) (im "gt" ((PVar "a") (PVar "b")) (EBinOp ">" (EVar "a") (EVar "b"))) (im "lte" ((PVar "a") (PVar "b")) (EBinOp "<=" (EVar "a") (EVar "b"))) (im "gte" ((PVar "a") (PVar "b")) (EBinOp ">=" (EVar "a") (EVar "b"))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyCon "String")) () ((im "compare" ((PVar "a") (PVar "b")) (EIf (EBinOp "<" (EVar "a") (EVar "b")) (EVar "Lt") (EIf (EBinOp ">" (EVar "a") (EVar "b")) (EVar "Gt") (EVar "Eq")))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyCon "Char")) () ((im "compare" ((PVar "a") (PVar "b")) (EIf (EBinOp "<" (EVar "a") (EVar "b")) (EVar "Lt") (EIf (EBinOp ">" (EVar "a") (EVar "b")) (EVar "Gt") (EVar "Eq")))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DTypeSig false "thenCmp" (TyFun (TyCon "Ordering") (TyFun (TyCon "Ordering") (TyCon "Ordering"))))
(DFunDef false "thenCmp" ((PCon "Eq") (PVar "o")) (EVar "o"))
(DFunDef false "thenCmp" ((PVar "o") PWild) (EVar "o"))
(DImpl true "Ord" ((TyTuple (TyVar "a") (TyVar "b"))) ((req "Ord" ((TyVar "a"))) (req "Ord" ((TyVar "b")))) ((im "compare" ((PTuple (PVar "a1") (PVar "b1")) (PTuple (PVar "a2") (PVar "b2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EMethodRef "compare") (EVar "a1")) (EVar "a2"))) (EApp (EApp (EMethodRef "compare") (EVar "b1")) (EVar "b2")))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c"))) ((req "Ord" ((TyVar "a"))) (req "Ord" ((TyVar "b"))) (req "Ord" ((TyVar "c")))) ((im "compare" ((PTuple (PVar "a1") (PVar "b1") (PVar "c1")) (PTuple (PVar "a2") (PVar "b2") (PVar "c2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EMethodRef "compare") (EVar "a1")) (EVar "a2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EMethodRef "compare") (EVar "b1")) (EVar "b2"))) (EApp (EApp (EMethodRef "compare") (EVar "c1")) (EVar "c2"))))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d"))) ((req "Ord" ((TyVar "a"))) (req "Ord" ((TyVar "b"))) (req "Ord" ((TyVar "c"))) (req "Ord" ((TyVar "d")))) ((im "compare" ((PTuple (PVar "a1") (PVar "b1") (PVar "c1") (PVar "d1")) (PTuple (PVar "a2") (PVar "b2") (PVar "c2") (PVar "d2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EMethodRef "compare") (EVar "a1")) (EVar "a2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EMethodRef "compare") (EVar "b1")) (EVar "b2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EMethodRef "compare") (EVar "c1")) (EVar "c2"))) (EApp (EApp (EMethodRef "compare") (EVar "d1")) (EVar "d2")))))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d") (TyVar "e"))) ((req "Ord" ((TyVar "a"))) (req "Ord" ((TyVar "b"))) (req "Ord" ((TyVar "c"))) (req "Ord" ((TyVar "d"))) (req "Ord" ((TyVar "e")))) ((im "compare" ((PTuple (PVar "a1") (PVar "b1") (PVar "c1") (PVar "d1") (PVar "e1")) (PTuple (PVar "a2") (PVar "b2") (PVar "c2") (PVar "d2") (PVar "e2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EMethodRef "compare") (EVar "a1")) (EVar "a2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EMethodRef "compare") (EVar "b1")) (EVar "b2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EMethodRef "compare") (EVar "c1")) (EVar "c2"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EMethodRef "compare") (EVar "d1")) (EVar "d2"))) (EApp (EApp (EMethodRef "compare") (EVar "e1")) (EVar "e2"))))))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyApp (TyCon "List") (TyVar "a"))) ((req "Ord" ((TyVar "a")))) ((im "compare" ((PList) (PList)) (EVar "Eq")) (im "compare" ((PList) PWild) (EVar "Lt")) (im "compare" (PWild (PList)) (EVar "Gt")) (im "compare" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EApp (EApp (EVar "thenCmp") (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y"))) (EApp (EApp (EMethodRef "compare") (EVar "xs")) (EVar "ys")))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Ord" ((TyVar "a")))) ((im "compare" ((PCon "None") (PCon "None")) (EVar "Eq")) (im "compare" ((PCon "None") (PCon "Some" PWild)) (EVar "Lt")) (im "compare" ((PCon "Some" PWild) (PCon "None")) (EVar "Gt")) (im "compare" ((PCon "Some" (PVar "x")) (PCon "Some" (PVar "y"))) (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y"))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Ord" ((TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) ((req "Ord" ((TyVar "e"))) (req "Ord" ((TyVar "a")))) ((im "compare" ((PCon "Err" (PVar "x")) (PCon "Err" (PVar "y"))) (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y"))) (im "compare" ((PCon "Err" PWild) (PCon "Ok" PWild)) (EVar "Lt")) (im "compare" ((PCon "Ok" PWild) (PCon "Err" PWild)) (EVar "Gt")) (im "compare" ((PCon "Ok" (PVar "x")) (PCon "Ok" (PVar "y"))) (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y"))) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DInterface true false "Debug" ("a") () ((imethod "debug" (TyFun (TyVar "a") (TyCon "String")) None)))
(DImpl true "Debug" ((TyCon "Int")) () ((im "debug" ((PVar "n")) (EApp (EVar "intToString") (EVar "n")))))
(DImpl true "Debug" ((TyCon "Float")) () ((im "debug" ((PVar "x")) (EApp (EVar "floatToString") (EVar "x")))))
(DImpl true "Debug" ((TyCon "Bool")) () ((im "debug" ((PCon "True")) (ELit (LString "True"))) (im "debug" ((PCon "False")) (ELit (LString "False")))))
(DImpl true "Debug" ((TyCon "Unit")) () ((im "debug" (PWild) (ELit (LString "()")))))
(DImpl true "Debug" ((TyCon "Ordering")) () ((im "debug" ((PCon "Lt")) (ELit (LString "Lt"))) (im "debug" ((PCon "Eq")) (ELit (LString "Eq"))) (im "debug" ((PCon "Gt")) (ELit (LString "Gt")))))
(DImpl true "Eq" ((TyCon "Ordering")) () ((im "eq" ((PCon "Lt") (PCon "Lt")) (EVar "True")) (im "eq" ((PCon "Eq") (PCon "Eq")) (EVar "True")) (im "eq" ((PCon "Gt") (PCon "Gt")) (EVar "True")) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl true "Ord" ((TyCon "Ordering")) () ((im "compare" ((PCon "Lt") (PCon "Lt")) (EVar "Eq")) (im "compare" ((PCon "Lt") PWild) (EVar "Lt")) (im "compare" (PWild (PCon "Lt")) (EVar "Gt")) (im "compare" ((PCon "Eq") (PCon "Eq")) (EVar "Eq")) (im "compare" ((PCon "Eq") PWild) (EVar "Lt")) (im "compare" (PWild (PCon "Eq")) (EVar "Gt")) (im "compare" ((PCon "Gt") (PCon "Gt")) (EVar "Eq")) (im "lt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "gt" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "True")) (arm PWild () (EVar "False")))) (im "lte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "gte" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "False")) (arm PWild () (EVar "True")))) (im "min" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EVar "y")) (arm PWild () (EVar "x")))) (im "max" ((PVar "x") (PVar "y")) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EVar "y")) (arm PWild () (EVar "x"))))))
(DImpl true "Debug" ((TyCon "String")) () ((im "debug" ((PVar "s")) (EApp (EVar "debugStringLit") (EVar "s")))))
(DImpl true "Debug" ((TyCon "Char")) () ((im "debug" ((PVar "c")) (EApp (EVar "debugCharLit") (EVar "c")))))
(DTypeSig false "debugListItems" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "String"))))
(DFunDef false "debugListItems" ((PList)) (ELit (LString "")))
(DFunDef false "debugListItems" ((PList (PVar "x"))) (EApp (EMethodRef "debug") (EVar "x")))
(DFunDef false "debugListItems" ((PCons (PVar "y") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "y")))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EDictApp "debugListItems") (EVar "rest")))) (ELit (LString ""))))
(DImpl true "Debug" ((TyApp (TyCon "List") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "xs")) (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EMethodRef "display") (EApp (EDictApp "debugListItems") (EVar "xs")))) (ELit (LString "]"))))))
(DTypeSig false "debugArrayItems" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))))
(DFunDef false "debugArrayItems" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EIf (EBinOp "==" (EVar "i") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EMethodRef "debug") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EDictApp "debugArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DImpl true "Debug" ((TyApp (TyCon "Array") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "arr")) (EBinOp "++" (EBinOp "++" (ELit (LString "[|")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EDictApp "debugArrayItems") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))) (ELit (LString "|]"))))))
(DImpl true "Eq" ((TyApp (TyCon "Array") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "!=" (EApp (EVar "arrayLength") (EVar "a")) (EApp (EVar "arrayLength") (EVar "b"))) (EVar "False") (EApp (EApp (EApp (EApp (EDictApp "eqGo") (EVar "a")) (EVar "b")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "a")))))))
(DTypeSig false "eqGo" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "eqGo" ((PVar "a") (PVar "b") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "True") (EIf (EApp (EApp (EMethodRef "eq") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "b"))) (EApp (EApp (EApp (EApp (EDictApp "eqGo") (EVar "a")) (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "False"))))
(DImpl true "Debug" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PCon "None")) (ELit (LString "None"))) (im "debug" ((PCon "Some" (PVar "x"))) (EBinOp "++" (ELit (LString "Some ")) (EApp (EMethodRef "debug") (EVar "x"))))))
(DImpl true "Debug" ((TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) ((req "Debug" ((TyVar "e"))) (req "Debug" ((TyVar "a")))) ((im "debug" ((PCon "Ok" (PVar "x"))) (EBinOp "++" (ELit (LString "Ok ")) (EApp (EMethodRef "debug") (EVar "x")))) (im "debug" ((PCon "Err" (PVar "e"))) (EBinOp "++" (ELit (LString "Err ")) (EApp (EMethodRef "debug") (EVar "e"))))))
(DImpl true "Debug" ((TyTuple (TyVar "a") (TyVar "b"))) ((req "Debug" ((TyVar "a"))) (req "Debug" ((TyVar "b")))) ((im "debug" ((PTuple (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "a")))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "b")))) (ELit (LString ")"))))))
(DImpl true "Debug" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c"))) ((req "Debug" ((TyVar "a"))) (req "Debug" ((TyVar "b"))) (req "Debug" ((TyVar "c")))) ((im "debug" ((PTuple (PVar "a") (PVar "b") (PVar "c"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "a")))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "b")))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "c")))) (ELit (LString ")"))))))
(DImpl true "Debug" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d"))) ((req "Debug" ((TyVar "a"))) (req "Debug" ((TyVar "b"))) (req "Debug" ((TyVar "c"))) (req "Debug" ((TyVar "d")))) ((im "debug" ((PTuple (PVar "a") (PVar "b") (PVar "c") (PVar "d"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "a")))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "b")))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "c")))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "d")))) (ELit (LString ")"))))))
(DImpl true "Debug" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d") (TyVar "e"))) ((req "Debug" ((TyVar "a"))) (req "Debug" ((TyVar "b"))) (req "Debug" ((TyVar "c"))) (req "Debug" ((TyVar "d"))) (req "Debug" ((TyVar "e")))) ((im "debug" ((PTuple (PVar "a") (PVar "b") (PVar "c") (PVar "d") (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "a")))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "b")))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "c")))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "d")))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "e")))) (ELit (LString ")"))))))
(DInterface true false "Display" ("a") () ((imethod "display" (TyFun (TyVar "a") (TyCon "String")) None)))
(DImpl true "Display" ((TyCon "Int")) () ((im "display" ((PVar "n")) (EApp (EVar "intToString") (EVar "n")))))
(DImpl true "Display" ((TyCon "Float")) () ((im "display" ((PVar "x")) (EApp (EVar "floatToString") (EVar "x")))))
(DImpl true "Display" ((TyCon "Bool")) () ((im "display" ((PCon "True")) (ELit (LString "True"))) (im "display" ((PCon "False")) (ELit (LString "False")))))
(DImpl true "Display" ((TyCon "Unit")) () ((im "display" (PWild) (ELit (LString "()")))))
(DImpl true "Display" ((TyCon "Ordering")) () ((im "display" ((PCon "Lt")) (ELit (LString "Lt"))) (im "display" ((PCon "Eq")) (ELit (LString "Eq"))) (im "display" ((PCon "Gt")) (ELit (LString "Gt")))))
(DImpl true "Display" ((TyCon "String")) () ((im "display" ((PVar "s")) (EVar "s"))))
(DImpl true "Display" ((TyCon "Char")) () ((im "display" ((PVar "c")) (EApp (EVar "charToStr") (EVar "c")))))
(DTypeSig false "displayListItems" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "String"))))
(DFunDef false "displayListItems" ((PList)) (ELit (LString "")))
(DFunDef false "displayListItems" ((PList (PVar "x"))) (EApp (EMethodRef "display") (EVar "x")))
(DFunDef false "displayListItems" ((PCons (PVar "y") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "y"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EDictApp "displayListItems") (EVar "rest")))) (ELit (LString ""))))
(DImpl true "Display" ((TyApp (TyCon "List") (TyVar "a"))) ((req "Display" ((TyVar "a")))) ((im "display" ((PVar "xs")) (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EMethodRef "display") (EApp (EDictApp "displayListItems") (EVar "xs")))) (ELit (LString "]"))))))
(DTypeSig false "displayArrayItems" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))))
(DFunDef false "displayArrayItems" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit (LString "")) (EIf (EBinOp "==" (EVar "i") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EMethodRef "display") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EMethodRef "display") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EDictApp "displayArrayItems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DImpl true "Display" ((TyApp (TyCon "Array") (TyVar "a"))) ((req "Display" ((TyVar "a")))) ((im "display" ((PVar "arr")) (EBinOp "++" (EBinOp "++" (ELit (LString "[|")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EDictApp "displayArrayItems") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))) (ELit (LString "|]"))))))
(DImpl true "Display" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Display" ((TyVar "a")))) ((im "display" ((PCon "None")) (ELit (LString "None"))) (im "display" ((PCon "Some" (PVar "x"))) (EBinOp "++" (ELit (LString "Some ")) (EApp (EMethodRef "display") (EVar "x"))))))
(DImpl true "Display" ((TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) ((req "Display" ((TyVar "e"))) (req "Display" ((TyVar "a")))) ((im "display" ((PCon "Ok" (PVar "x"))) (EBinOp "++" (ELit (LString "Ok ")) (EApp (EMethodRef "display") (EVar "x")))) (im "display" ((PCon "Err" (PVar "e"))) (EBinOp "++" (ELit (LString "Err ")) (EApp (EMethodRef "display") (EVar "e"))))))
(DImpl true "Display" ((TyTuple (TyVar "a") (TyVar "b"))) ((req "Display" ((TyVar "a"))) (req "Display" ((TyVar "b")))) ((im "display" ((PTuple (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString ")"))))))
(DImpl true "Display" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c"))) ((req "Display" ((TyVar "a"))) (req "Display" ((TyVar "b"))) (req "Display" ((TyVar "c")))) ((im "display" ((PTuple (PVar "a") (PVar "b") (PVar "c"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EVar "c"))) (ELit (LString ")"))))))
(DImpl true "Display" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d"))) ((req "Display" ((TyVar "a"))) (req "Display" ((TyVar "b"))) (req "Display" ((TyVar "c"))) (req "Display" ((TyVar "d")))) ((im "display" ((PTuple (PVar "a") (PVar "b") (PVar "c") (PVar "d"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EVar "c"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EVar "d"))) (ELit (LString ")"))))))
(DImpl true "Display" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d") (TyVar "e"))) ((req "Display" ((TyVar "a"))) (req "Display" ((TyVar "b"))) (req "Display" ((TyVar "c"))) (req "Display" ((TyVar "d"))) (req "Display" ((TyVar "e")))) ((im "display" ((PTuple (PVar "a") (PVar "b") (PVar "c") (PVar "d") (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EVar "c"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EVar "d"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ")"))))))
(DTypeSig false "derivedShowWrap" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "derivedShowWrap" ((PVar "s")) (EIf (EApp (EVar "derivedArgNeedsParens") (EVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString ")"))) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "derivedArgNeedsParens" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "derivedArgNeedsParens" ((PVar "s")) (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))) (EVar "False") (EIf (EApp (EVar "derivedIsQuoteChar") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s")))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LChar "-"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "derivedHasTopLevelSpace") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))) (ELit (LInt 0))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "derivedIsQuoteChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "derivedIsQuoteChar" ((PVar "c")) (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (EBinOp "==" (EVar "c") (ELit (LChar "'")))))
(DTypeSig false "derivedHasTopLevelSpace" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "derivedHasTopLevelSpace" ((PVar "chars") (PVar "i") (PVar "n") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar " "))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "derivedHasTopLevelSpace") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EApp (EVar "derivedNextDepth") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars"))) (EVar "depth"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "derivedNextDepth" (TyFun (TyCon "Char") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "derivedNextDepth" ((PVar "c") (PVar "depth")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "("))) (EBinOp "==" (EVar "c") (ELit (LChar "[")))) (EBinOp "==" (EVar "c") (ELit (LChar "{")))) (EBinOp "+" (EVar "depth") (ELit (LInt 1))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar ")"))) (EBinOp "==" (EVar "c") (ELit (LChar "]")))) (EBinOp "==" (EVar "c") (ELit (LChar "}")))) (EBinOp "-" (EVar "depth") (ELit (LInt 1))) (EIf (EVar "otherwise") (EVar "depth") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DInterface true false "Hashable" ("a") () ((imethod "hash" (TyFun (TyVar "a") (TyCon "Int")) None)))
(DImpl true "Hashable" ((TyCon "Int")) () ((im "hash" ((PVar "n")) (EApp (EVar "hashInt") (EVar "n")))))
(DImpl true "Hashable" ((TyCon "Float")) () ((im "hash" ((PVar "x")) (EApp (EVar "hashFloat") (EVar "x")))))
(DImpl true "Hashable" ((TyCon "String")) () ((im "hash" ((PVar "s")) (EApp (EVar "hashString") (EVar "s")))))
(DImpl true "Hashable" ((TyCon "Char")) () ((im "hash" ((PVar "c")) (EApp (EVar "hashChar") (EVar "c")))))
(DImpl true "Hashable" ((TyCon "Bool")) () ((im "hash" ((PVar "b")) (EApp (EVar "hashBool") (EVar "b")))))
(DImpl true "Hashable" ((TyCon "Unit")) () ((im "hash" (PWild) (ELit (LInt 0)))))
(DImpl true "Hashable" ((TyCon "Ordering")) () ((im "hash" ((PCon "Lt")) (ELit (LInt 0))) (im "hash" ((PCon "Eq")) (ELit (LInt 1))) (im "hash" ((PCon "Gt")) (ELit (LInt 2)))))
(DImpl true "Hashable" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Hashable" ((TyVar "a")))) ((im "hash" ((PCon "None")) (ELit (LInt 1))) (im "hash" ((PCon "Some" (PVar "x"))) (EApp (EMethodRef "hash") (EVar "x")))))
(DImpl true "Hashable" ((TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) ((req "Hashable" ((TyVar "e"))) (req "Hashable" ((TyVar "a")))) ((im "hash" ((PCon "Ok" (PVar "x"))) (EApp (EMethodRef "hash") (EVar "x"))) (im "hash" ((PCon "Err" (PVar "e"))) (EBinOp "+" (ELit (LInt 33)) (EApp (EMethodRef "hash") (EVar "e"))))))
(DTypeSig false "hashListItems" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))))
(DFunDef false "hashListItems" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "hashListItems" ((PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EDictApp "hashListItems") (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 33))) (EApp (EMethodRef "hash") (EVar "x")))) (EVar "xs")))
(DImpl true "Hashable" ((TyApp (TyCon "List") (TyVar "a"))) ((req "Hashable" ((TyVar "a")))) ((im "hash" ((PVar "xs")) (EApp (EApp (EDictApp "hashListItems") (ELit (LInt 0))) (EVar "xs")))))
(DImpl true "Hashable" ((TyTuple (TyVar "a") (TyVar "b"))) ((req "Hashable" ((TyVar "a"))) (req "Hashable" ((TyVar "b")))) ((im "hash" ((PTuple (PVar "a") (PVar "b"))) (EBinOp "+" (EBinOp "*" (EApp (EMethodRef "hash") (EVar "a")) (ELit (LInt 33))) (EApp (EMethodRef "hash") (EVar "b"))))))
(DImpl true "Hashable" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c"))) ((req "Hashable" ((TyVar "a"))) (req "Hashable" ((TyVar "b"))) (req "Hashable" ((TyVar "c")))) ((im "hash" ((PTuple (PVar "a") (PVar "b") (PVar "c"))) (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EApp (EMethodRef "hash") (EVar "a")) (ELit (LInt 33))) (EApp (EMethodRef "hash") (EVar "b"))) (ELit (LInt 33))) (EApp (EMethodRef "hash") (EVar "c"))))))
(DImpl true "Hashable" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d"))) ((req "Hashable" ((TyVar "a"))) (req "Hashable" ((TyVar "b"))) (req "Hashable" ((TyVar "c"))) (req "Hashable" ((TyVar "d")))) ((im "hash" ((PTuple (PVar "a") (PVar "b") (PVar "c") (PVar "d"))) (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EApp (EMethodRef "hash") (EVar "a")) (ELit (LInt 33))) (EApp (EMethodRef "hash") (EVar "b"))) (ELit (LInt 33))) (EApp (EMethodRef "hash") (EVar "c"))) (ELit (LInt 33))) (EApp (EMethodRef "hash") (EVar "d"))))))
(DImpl true "Hashable" ((TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d") (TyVar "e"))) ((req "Hashable" ((TyVar "a"))) (req "Hashable" ((TyVar "b"))) (req "Hashable" ((TyVar "c"))) (req "Hashable" ((TyVar "d"))) (req "Hashable" ((TyVar "e")))) ((im "hash" ((PTuple (PVar "a") (PVar "b") (PVar "c") (PVar "d") (PVar "e"))) (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EBinOp "+" (EBinOp "*" (EApp (EMethodRef "hash") (EVar "a")) (ELit (LInt 33))) (EApp (EMethodRef "hash") (EVar "b"))) (ELit (LInt 33))) (EApp (EMethodRef "hash") (EVar "c"))) (ELit (LInt 33))) (EApp (EMethodRef "hash") (EVar "d"))) (ELit (LInt 33))) (EApp (EMethodRef "hash") (EVar "e"))))))
(DTypeSig true "println" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "println" ((PVar "x")) (EApp (EVar "putStrLn") (EApp (EMethodRef "display") (EVar "x"))))
(DTypeSig true "print" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "print" ((PVar "x")) (EApp (EVar "putStr") (EApp (EMethodRef "display") (EVar "x"))))
(DInterface true false "Num" ("a") ((super "Eq" ("a"))) ((imethod "add" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))) None) (imethod "sub" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))) None) (imethod "mul" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))) None) (imethod "div" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a"))) None) (imethod "negate" (TyFun (TyVar "a") (TyVar "a")) None) (imethod "abs" (TyFun (TyVar "a") (TyVar "a")) None) (imethod "signum" (TyFun (TyVar "a") (TyVar "a")) None) (imethod "fromInt" (TyFun (TyCon "Int") (TyVar "a")) None)))
(DImpl true "Num" ((TyCon "Int")) () ((im "add" ((PVar "a") (PVar "b")) (EBinOp "+" (EVar "a") (EVar "b"))) (im "sub" ((PVar "a") (PVar "b")) (EBinOp "-" (EVar "a") (EVar "b"))) (im "mul" ((PVar "a") (PVar "b")) (EBinOp "*" (EVar "a") (EVar "b"))) (im "div" ((PVar "a") (PVar "b")) (EBinOp "/" (EVar "a") (EVar "b"))) (im "negate" ((PVar "a")) (EBinOp "-" (ELit (LInt 0)) (EVar "a"))) (im "abs" ((PVar "a")) (EIf (EBinOp "<" (EVar "a") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "a")) (EVar "a"))) (im "signum" ((PVar "a")) (EIf (EBinOp ">" (EVar "a") (ELit (LInt 0))) (ELit (LInt 1)) (EIf (EBinOp "<" (EVar "a") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (ELit (LInt 0))))) (im "fromInt" ((PVar "x")) (EVar "x"))))
(DImpl true "Num" ((TyCon "Float")) () ((im "add" ((PVar "a") (PVar "b")) (EBinOp "+" (EVar "a") (EVar "b"))) (im "sub" ((PVar "a") (PVar "b")) (EBinOp "-" (EVar "a") (EVar "b"))) (im "mul" ((PVar "a") (PVar "b")) (EBinOp "*" (EVar "a") (EVar "b"))) (im "div" ((PVar "a") (PVar "b")) (EBinOp "/" (EVar "a") (EVar "b"))) (im "negate" ((PVar "a")) (EBinOp "-" (ELit (LFloat 0.0)) (EVar "a"))) (im "abs" ((PVar "a")) (EIf (EBinOp "<" (EVar "a") (ELit (LFloat 0.0))) (EBinOp "-" (ELit (LFloat 0.0)) (EVar "a")) (EVar "a"))) (im "signum" ((PVar "a")) (EIf (EBinOp ">" (EVar "a") (ELit (LFloat 0.0))) (ELit (LFloat 1.0)) (EIf (EBinOp "<" (EVar "a") (ELit (LFloat 0.0))) (EBinOp "-" (ELit (LFloat 0.0)) (ELit (LFloat 1.0))) (ELit (LFloat 0.0))))) (im "fromInt" ((PVar "x")) (EApp (EVar "intToFloat") (EVar "x")))))
(DInterface true false "Bounded" ("a") () ((imethod "minBound" (TyVar "a") None) (imethod "maxBound" (TyVar "a") None)))
(DImpl true "Bounded" ((TyCon "Int")) () ((im "minBound" () (EVar "intMinBound")) (im "maxBound" () (EVar "intMaxBound"))))
(DImpl true "Bounded" ((TyCon "Char")) () ((im "minBound" () (EVar "charMinBound")) (im "maxBound" () (EVar "charMaxBound"))))
(DInterface true false "Mappable" ("f") () ((imethod "map" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyVar "f") (TyVar "b"))))) None)))
(DImpl true "Mappable" ((TyCon "List")) () ((im "map" (PWild (PList)) (EListLit)) (im "map" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "xs"))))))
(DImpl true "Mappable" ((TyCon "Option")) () ((im "map" ((PVar "f") (PCon "Some" (PVar "a"))) (EApp (EVar "Some") (EApp (EVar "f") (EVar "a")))) (im "map" (PWild (PCon "None")) (EVar "None"))))
(DImpl true "Mappable" ((TyApp (TyCon "Result") (TyVar "e"))) () ((im "map" ((PVar "f") (PCon "Ok" (PVar "a"))) (EApp (EVar "Ok") (EApp (EVar "f") (EVar "a")))) (im "map" (PWild (PVar "e")) (EVar "e"))))
(DTypeSig true "replaceWith" (TyConstrained ((cstr "Mappable" (TyVar "f"))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyFun (TyVar "b") (TyApp (TyVar "f") (TyVar "b"))))))
(DFunDef false "replaceWith" ((PVar "fa") (PVar "b")) (EApp (EApp (EMethodRef "map") (ELam (PWild) (EVar "b"))) (EVar "fa")))
(DInterface true false "Applicative" ("f") ((super "Mappable" ("f"))) ((imethod "pure" (TyFun (TyVar "a") (TyApp (TyVar "f") (TyVar "a"))) None) (imethod "ap" (TyFun (TyApp (TyVar "f") (TyFun (TyVar "a") (TyVar "b"))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyApp (TyVar "f") (TyVar "b")))) None)))
(DImpl true "Applicative" ((TyCon "List")) () ((im "pure" ((PVar "a")) (EListLit (EVar "a"))) (im "ap" ((PList) PWild) (EListLit)) (im "ap" ((PCons (PVar "f") (PVar "fs")) (PVar "xs")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "xs")) (EApp (EApp (EMethodRef "ap") (EVar "fs")) (EVar "xs"))))))
(DImpl true "Applicative" ((TyCon "Option")) () ((im "pure" ((PVar "a")) (EApp (EVar "Some") (EVar "a"))) (im "ap" ((PCon "None") PWild) (EVar "None")) (im "ap" (PWild (PCon "None")) (EVar "None")) (im "ap" ((PCon "Some" (PVar "f")) (PCon "Some" (PVar "a"))) (EApp (EVar "Some") (EApp (EVar "f") (EVar "a"))))))
(DImpl true "Applicative" ((TyApp (TyCon "Result") (TyVar "e"))) () ((im "pure" ((PVar "a")) (EApp (EVar "Ok") (EVar "a"))) (im "ap" ((PCon "Ok" (PVar "f")) (PCon "Ok" (PVar "a"))) (EApp (EVar "Ok") (EApp (EVar "f") (EVar "a")))) (im "ap" ((PCon "Err" (PVar "e")) PWild) (EApp (EVar "Err") (EVar "e"))) (im "ap" (PWild (PCon "Err" (PVar "e"))) (EApp (EVar "Err") (EVar "e")))))
(DTypeSig true "map2" (TyConstrained ((cstr "Applicative" (TyVar "f"))) (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyVar "c"))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyFun (TyApp (TyVar "f") (TyVar "b")) (TyApp (TyVar "f") (TyVar "c")))))))
(DFunDef false "map2" ((PVar "f") (PVar "fa") (PVar "fb")) (EApp (EApp (EMethodRef "ap") (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "fa"))) (EVar "fb")))
(DTypeSig true "map3" (TyConstrained ((cstr "Applicative" (TyVar "f"))) (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyFun (TyVar "c") (TyVar "d")))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyFun (TyApp (TyVar "f") (TyVar "b")) (TyFun (TyApp (TyVar "f") (TyVar "c")) (TyApp (TyVar "f") (TyVar "d"))))))))
(DFunDef false "map3" ((PVar "f") (PVar "fa") (PVar "fb") (PVar "fc")) (EApp (EApp (EMethodRef "ap") (EApp (EApp (EMethodRef "ap") (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "fa"))) (EVar "fb"))) (EVar "fc")))
(DInterface true false "Thenable" ("m") ((super "Applicative" ("m"))) ((imethod "andThen" (TyFun (TyApp (TyVar "m") (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyVar "m") (TyVar "b")))) (TyEffect () (Some "e") (TyApp (TyVar "m") (TyVar "b"))))) None)))
(DTypeSig true "flatMap" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyVar "m") (TyVar "b")))) (TyFun (TyApp (TyVar "m") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyVar "m") (TyVar "b")))))))
(DFunDef false "flatMap" ((PVar "f") (PVar "ma")) (EApp (EApp (EMethodRef "andThen") (EVar "ma")) (EVar "f")))
(DTypeSig true "flat" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyApp (TyVar "m") (TyApp (TyVar "m") (TyVar "a"))) (TyApp (TyVar "m") (TyVar "a")))))
(DFunDef false "flat" ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EVar "x")) (EVar "identity")))
(DTypeSig true "when" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyVar "m") (TyCon "Unit")) (TyApp (TyVar "m") (TyCon "Unit"))))))
(DFunDef false "when" ((PVar "b") (PVar "m")) (EIf (EVar "b") (EVar "m") (EApp (EMethodRef "pure") (ELit LUnit))))
(DTypeSig true "unless" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyVar "m") (TyCon "Unit")) (TyApp (TyVar "m") (TyCon "Unit"))))))
(DFunDef false "unless" ((PVar "b") (PVar "m")) (EIf (EVar "b") (EApp (EMethodRef "pure") (ELit LUnit)) (EVar "m")))
(DTypeSig true "foldThen" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyVar "m") (TyVar "b"))))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyVar "m") (TyVar "b"))))))))
(DFunDef false "foldThen" (PWild (PVar "z") (PList)) (EApp (EMethodRef "pure") (EVar "z")))
(DFunDef false "foldThen" ((PVar "f") (PVar "z") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "f") (EVar "z")) (EVar "x"))) (ELam ((PVar "z2")) (EApp (EApp (EApp (EDictApp "foldThen") (EVar "f")) (EVar "z2")) (EVar "xs")))))
(DTypeSig true "repeatThen" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyVar "m") (TyVar "a")) (TyApp (TyVar "m") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "repeatThen" ((PVar "n") (PVar "action")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EMethodRef "pure") (EListLit)) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "andThen") (EVar "action")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "x") (EVar "_s")))) (EApp (EApp (EDictApp "repeatThen") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "action"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "filterThen" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyVar "m") (TyCon "Bool")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyVar "m") (TyApp (TyCon "List") (TyVar "a"))))))))
(DFunDef false "filterThen" (PWild (PList)) (EApp (EMethodRef "pure") (EListLit)))
(DFunDef false "filterThen" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "f") (EVar "x"))) (ELam ((PVar "keep")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EDictApp "filterThen") (EVar "f")) (EVar "xs"))) (ELam ((PVar "rest")) (EApp (EMethodRef "pure") (EIf (EVar "keep") (EBinOp "::" (EVar "x") (EVar "rest")) (EVar "rest"))))))))
(DTypeSig true "forEach" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyVar "m") (TyCon "Unit")))) (TyEffect () (Some "e") (TyApp (TyVar "m") (TyCon "Unit")))))))
(DFunDef false "forEach" ((PList) PWild) (EApp (EMethodRef "pure") (ELit LUnit)))
(DFunDef false "forEach" ((PCons (PVar "x") (PVar "xs")) (PVar "f")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "f") (EVar "x"))) (ELam (PWild) (EApp (EApp (EDictApp "forEach") (EVar "xs")) (EVar "f")))))
(DTypeSig true "runEach" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyApp (TyCon "List") (TyApp (TyVar "m") (TyVar "a"))) (TyApp (TyVar "m") (TyCon "Unit")))))
(DFunDef false "runEach" ((PList)) (EApp (EMethodRef "pure") (ELit LUnit)))
(DFunDef false "runEach" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EMethodRef "andThen") (EVar "x")) (ELam (PWild) (EApp (EDictApp "runEach") (EVar "xs")))))
(DImpl true "Thenable" ((TyCon "List")) () ((im "andThen" ((PList) PWild) (EListLit)) (im "andThen" ((PVar "xs") (PVar "f")) (ELetGroup ((lgb "revAcc" (clause ((PList) (PVar "acc")) (EVar "acc")) (clause ((PCons (PVar "x") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "revAcc") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "acc"))))) (lgb "concatRev" (clause ((PList) (PVar "acc")) (EVar "acc")) (clause ((PCons (PVar "x") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "concatRev") (EVar "rest")) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EVar "acc")))))) (EApp (EApp (EVar "concatRev") (EApp (EApp (EVar "revAcc") (EVar "xs")) (EListLit))) (EListLit))))))
(DImpl true "Thenable" ((TyCon "Option")) () ((im "andThen" ((PCon "None") PWild) (EVar "None")) (im "andThen" ((PCon "Some" (PVar "a")) (PVar "f")) (EApp (EVar "f") (EVar "a")))))
(DImpl true "Thenable" ((TyApp (TyCon "Result") (TyVar "e"))) () ((im "andThen" ((PCon "Err" (PVar "e")) PWild) (EApp (EVar "Err") (EVar "e"))) (im "andThen" ((PCon "Ok" (PVar "a")) (PVar "f")) (EApp (EVar "f") (EVar "a")))))
(DInterface true false "Alternative" ("f") ((super "Applicative" ("f"))) ((imethod "noMatch" (TyApp (TyVar "f") (TyVar "a")) None) (imethod "orElse" (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyApp (TyVar "f") (TyVar "a")))) None)))
(DImpl true "Alternative" ((TyCon "List")) () ((im "noMatch" () (EListLit)) (im "orElse" ((PVar "xs") (PVar "ys")) (EBinOp "++" (EVar "xs") (EVar "ys")))))
(DImpl true "Alternative" ((TyCon "Option")) () ((im "noMatch" () (EVar "None")) (im "orElse" ((PCon "Some" (PVar "x")) PWild) (EApp (EVar "Some") (EVar "x"))) (im "orElse" ((PCon "None") (PVar "b")) (EVar "b"))))
(DTypeSig true "guard" (TyConstrained ((cstr "Alternative" (TyVar "f"))) (TyFun (TyCon "Bool") (TyApp (TyVar "f") (TyCon "Unit")))))
(DFunDef false "guard" ((PCon "True")) (EApp (EMethodRef "pure") (ELit LUnit)))
(DFunDef false "guard" ((PCon "False")) (EMethodRef "noMatch"))
(DInterface true false "Bimappable" ("p") () ((imethod "bimap" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "c"))) (TyFun (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "d"))) (TyFun (TyApp (TyApp (TyVar "p") (TyVar "a")) (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyApp (TyVar "p") (TyVar "c")) (TyVar "d")))))) None) (imethod "mapFirst" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "c"))) (TyFun (TyApp (TyApp (TyVar "p") (TyVar "a")) (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyApp (TyVar "p") (TyVar "c")) (TyVar "b"))))) (mdef ((PVar "f")) (EApp (EApp (EMethodRef "bimap") (EVar "f")) (EVar "identity")))) (imethod "mapSecond" (TyFun (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "d"))) (TyFun (TyApp (TyApp (TyVar "p") (TyVar "a")) (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyApp (TyVar "p") (TyVar "a")) (TyVar "d"))))) (mdef ((PVar "g")) (EApp (EApp (EMethodRef "bimap") (EVar "identity")) (EVar "g"))))))
(DImpl true "Bimappable" ((TyCon "Result")) () ((im "bimap" ((PVar "f") PWild (PCon "Err" (PVar "e"))) (EApp (EVar "Err") (EApp (EVar "f") (EVar "e")))) (im "bimap" (PWild (PVar "g") (PCon "Ok" (PVar "a"))) (EApp (EVar "Ok") (EApp (EVar "g") (EVar "a")))) (im "mapFirst" ((PVar "f")) (EApp (EApp (EMethodRef "bimap") (EVar "f")) (EVar "identity"))) (im "mapSecond" ((PVar "g")) (EApp (EApp (EMethodRef "bimap") (EVar "identity")) (EVar "g")))))
(DImpl true "Bimappable" ((TyCon "__tuple2__")) () ((im "bimap" ((PVar "f") (PVar "g") (PTuple (PVar "x") (PVar "y"))) (ETuple (EApp (EVar "f") (EVar "x")) (EApp (EVar "g") (EVar "y")))) (im "mapFirst" ((PVar "f")) (EApp (EApp (EMethodRef "bimap") (EVar "f")) (EVar "identity"))) (im "mapSecond" ((PVar "g")) (EApp (EApp (EMethodRef "bimap") (EVar "identity")) (EVar "g")))))
(DInterface true false "Foldable" ("t") () ((imethod "fold" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))) None) (imethod "foldRight" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))) None) (imethod "foldMap" (TyConstrained ((cstr "Monoid" (TyVar "m"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "m"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyVar "m"))))) (mdef ((PVar "f")) (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "++" (EVar "acc") (EApp (EVar "f") (EVar "x"))))) (EMethodRef "empty")))) (imethod "toList" (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))) None) (imethod "isEmpty" (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyCon "Bool")) (mdef ((PVar "t")) (EMatch (EApp (EMethodRef "toList") (EVar "t")) (arm (PList) () (EVar "True")) (arm PWild () (EVar "False"))))) (imethod "length" (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyCon "Int")) (mdef ((PVar "t")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") PWild) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))) (ELit (LInt 0))) (EVar "t"))))))
(DInterface true false "Filterable" ("f") ((super "Mappable" ("f"))) ((imethod "filterMap" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "b")))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyVar "f") (TyVar "b"))))) None) (imethod "filter" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyVar "f") (TyVar "a"))))) (mdef ((PVar "p")) (EApp (EMethodRef "filterMap") (ELam ((PVar "x")) (EIf (EApp (EVar "p") (EVar "x")) (EApp (EVar "Some") (EVar "x")) (EVar "None"))))))))
(DInterface true false "FromEntries" ("c" "e") () ((imethod "fromEntries" (TyFun (TyApp (TyCon "List") (TyVar "e")) (TyVar "c")) None)))
(DInterface true false "Index" ("c" "k" "v") () ((imethod "index" (TyFun (TyVar "c") (TyFun (TyVar "k") (TyVar "v"))) None)))
(DInterface true false "IndexMut" ("c" "k" "v") ((super "Index" ("c" "k" "v"))) ((imethod "setIndex" (TyFun (TyVar "c") (TyFun (TyVar "k") (TyFun (TyVar "v") (TyVar "c")))) None)))
(DImpl true "Index" ((TyApp (TyCon "Array") (TyVar "a")) (TyCon "Int") (TyVar "a")) () ((im "index" ((PVar "arr") (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EApp (EVar "indexError") (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " out of bounds")))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))))
(DImpl true "IndexMut" ((TyApp (TyCon "Array") (TyVar "a")) (TyCon "Int") (TyVar "a")) () ((im "setIndex" ((PVar "arr") (PVar "i") (PVar "v")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EApp (EVar "indexError") (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " out of bounds")))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "v")) (EVar "arr"))) (DoExpr (EVar "arr")))))))
(DImpl true "Index" ((TyApp (TyCon "List") (TyVar "a")) (TyCon "Int") (TyVar "a")) () ((im "index" ((PList) PWild) (EApp (EVar "indexError") (ELit (LString "index out of bounds")))) (im "index" ((PCons (PVar "h") (PVar "t")) (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "h") (EApp (EApp (EMethodRef "index") (EVar "t")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))))
(DImpl true "Index" ((TyCon "String") (TyCon "Int") (TyCon "Char")) () ((im "index" ((PVar "s") (PVar "i")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs")))) (EApp (EVar "indexError") (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " out of bounds")))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))))))
(DImpl true "Foldable" ((TyCon "List")) () ((im "fold" (PWild (PVar "acc") (PList)) (EVar "acc")) (im "fold" ((PVar "f") (PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EApp (EMethodRef "fold") (EVar "f")) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "x"))) (EVar "xs"))) (im "foldRight" (PWild (PVar "acc") (PList)) (EVar "acc")) (im "foldRight" ((PVar "f") (PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "f") (EVar "x")) (EApp (EApp (EApp (EMethodRef "foldRight") (EVar "f")) (EVar "acc")) (EVar "xs")))) (im "toList" () (EVar "identity")) (im "isEmpty" ((PList)) (EVar "True")) (im "isEmpty" (PWild) (EVar "False")) (im "length" () (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") PWild) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))) (ELit (LInt 0)))) (im "foldMap" ((PVar "f")) (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "++" (EVar "acc") (EApp (EVar "f") (EVar "x"))))) (EMethodRef "empty")))))
(DImpl true "Foldable" ((TyCon "Option")) () ((im "fold" (PWild (PVar "acc") (PCon "None")) (EVar "acc")) (im "fold" ((PVar "f") (PVar "acc") (PCon "Some" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "x"))) (im "foldRight" (PWild (PVar "acc") (PCon "None")) (EVar "acc")) (im "foldRight" ((PVar "f") (PVar "acc") (PCon "Some" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "x")) (EVar "acc"))) (im "toList" ((PCon "None")) (EListLit)) (im "toList" ((PCon "Some" (PVar "x"))) (EListLit (EVar "x"))) (im "foldMap" ((PVar "f")) (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "++" (EVar "acc") (EApp (EVar "f") (EVar "x"))))) (EMethodRef "empty"))) (im "isEmpty" ((PVar "t")) (EMatch (EApp (EMethodRef "toList") (EVar "t")) (arm (PList) () (EVar "True")) (arm PWild () (EVar "False")))) (im "length" ((PVar "t")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") PWild) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))) (ELit (LInt 0))) (EVar "t")))))
(DImpl true "Foldable" ((TyApp (TyCon "Result") (TyVar "e"))) () ((im "fold" (PWild (PVar "acc") (PCon "Err" PWild)) (EVar "acc")) (im "fold" ((PVar "f") (PVar "acc") (PCon "Ok" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "x"))) (im "foldRight" (PWild (PVar "acc") (PCon "Err" PWild)) (EVar "acc")) (im "foldRight" ((PVar "f") (PVar "acc") (PCon "Ok" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "x")) (EVar "acc"))) (im "toList" ((PCon "Err" PWild)) (EListLit)) (im "toList" ((PCon "Ok" (PVar "x"))) (EListLit (EVar "x"))) (im "foldMap" ((PVar "f")) (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "++" (EVar "acc") (EApp (EVar "f") (EVar "x"))))) (EMethodRef "empty"))) (im "isEmpty" ((PVar "t")) (EMatch (EApp (EMethodRef "toList") (EVar "t")) (arm (PList) () (EVar "True")) (arm PWild () (EVar "False")))) (im "length" ((PVar "t")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") PWild) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))) (ELit (LInt 0))) (EVar "t")))))
(DInterface true false "Traversable" ("t") ((super "Mappable" ("t")) (super "Foldable" ("t"))) ((imethod "traverse" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyVar "m") (TyVar "b")))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyVar "m") (TyApp (TyVar "t") (TyVar "b"))))))) None) (imethod "sequence" (TyConstrained ((cstr "Thenable" (TyVar "m"))) (TyFun (TyApp (TyVar "t") (TyApp (TyVar "m") (TyVar "a"))) (TyEffect () (Some "e") (TyApp (TyVar "m") (TyApp (TyVar "t") (TyVar "a")))))) (mdef ((PVar "ta")) (EApp (EApp (EMethodRef "traverse") (EVar "identity")) (EVar "ta"))))))
(DImpl true "Traversable" ((TyCon "List")) () ((im "traverse" ((PVar "f") (PVar "xs")) (EMatch (EVar "xs") (arm (PList) () (EApp (EMethodRef "pure") (EListLit))) (arm (PCons (PVar "x") (PVar "rest")) () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "f") (EVar "x"))) (ELam ((PVar "y")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "y") (EVar "_s")))) (EApp (EApp (EMethodRef "traverse") (EVar "f")) (EVar "rest")))))))) (im "sequence" ((PVar "ta")) (EApp (EApp (EMethodRef "traverse") (EVar "identity")) (EVar "ta")))))
(DImpl true "Traversable" ((TyCon "Option")) () ((im "traverse" ((PVar "f") (PVar "opt")) (EMatch (EVar "opt") (arm (PCon "None") () (EApp (EMethodRef "pure") (EVar "None"))) (arm (PCon "Some" (PVar "x")) () (EApp (EApp (EMethodRef "map") (EVar "Some")) (EApp (EVar "f") (EVar "x")))))) (im "sequence" ((PVar "ta")) (EApp (EApp (EMethodRef "traverse") (EVar "identity")) (EVar "ta")))))
(DImpl true "Traversable" ((TyApp (TyCon "Result") (TyVar "e"))) () ((im "traverse" ((PVar "f") (PVar "res")) (EMatch (EVar "res") (arm (PCon "Err" (PVar "e")) () (EApp (EMethodRef "pure") (EApp (EVar "Err") (EVar "e")))) (arm (PCon "Ok" (PVar "x")) () (EApp (EApp (EMethodRef "map") (EVar "Ok")) (EApp (EVar "f") (EVar "x")))))) (im "sequence" ((PVar "ta")) (EApp (EApp (EMethodRef "traverse") (EVar "identity")) (EVar "ta")))))
(DTypeSig true "any" (TyConstrained ((cstr "Foldable" (TyVar "t"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyCon "Bool"))))))
(DFunDef false "any" ((PVar "f")) (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "||" (EVar "acc") (EApp (EVar "f") (EVar "x"))))) (EVar "False")))
(DTypeSig true "all" (TyConstrained ((cstr "Foldable" (TyVar "t"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyCon "Bool"))))))
(DFunDef false "all" ((PVar "f")) (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "&&" (EVar "acc") (EApp (EVar "f") (EVar "x"))))) (EVar "True")))
(DTypeSig true "find" (TyConstrained ((cstr "Foldable" (TyVar "t"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a")))))))
(DFunDef false "find" ((PVar "f")) (ELetGroup ((lgb "g" (clause ((PAs "acc" (PCon "Some" PWild)) PWild) (EVar "acc")) (clause ((PCon "None") (PVar "x")) (EIf (EApp (EVar "f") (EVar "x")) (EApp (EVar "Some") (EVar "x")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EApp (EMethodRef "fold") (EVar "g")) (EVar "None"))))
(DTypeSig true "count" (TyConstrained ((cstr "Foldable" (TyVar "t"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyEffect () (Some "e") (TyCon "Int"))))))
(DFunDef false "count" ((PVar "f")) (ELetGroup ((lgb "g" (clause ((PVar "acc") (PVar "x")) (EIf (EApp (EVar "f") (EVar "x")) (EBinOp "+" (EVar "acc") (ELit (LInt 1))) (EIf (EVar "otherwise") (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EApp (EMethodRef "fold") (EVar "g")) (ELit (LInt 0)))))
(DTypeSig true "sum" (TyConstrained ((cstr "Foldable" (TyVar "t")) (cstr "Num" (TyVar "a"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyVar "a"))))
(DFunDef false "sum" ((PVar "xs")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "+" (EVar "_a") (EVar "_b")))) (EApp (EMethodRef "fromInt") (ELit (LInt 0)))) (EVar "xs")))
(DTypeSig true "product" (TyConstrained ((cstr "Foldable" (TyVar "t")) (cstr "Num" (TyVar "a"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyVar "a"))))
(DFunDef false "product" ((PVar "xs")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "*" (EVar "_a") (EVar "_b")))) (EApp (EMethodRef "fromInt") (ELit (LInt 1)))) (EVar "xs")))
(DTypeSig true "elem" (TyConstrained ((cstr "Foldable" (TyVar "t")) (cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "elem" ((PVar "a")) (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "||" (EVar "acc") (EBinOp "==" (EVar "x") (EVar "a"))))) (EVar "False")))
(DTypeSig true "notElem" (TyConstrained ((cstr "Foldable" (TyVar "t")) (cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "notElem" ((PVar "a") (PVar "xs")) (EApp (EVar "not") (EApp (EApp (EDictApp "elem") (EVar "a")) (EVar "xs"))))
(DTypeSig true "maximum" (TyConstrained ((cstr "Foldable" (TyVar "t")) (cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "maximum" () (ELetGroup ((lgb "step" (clause ((PCon "None") (PVar "x")) (EApp (EVar "Some") (EVar "x"))) (clause ((PCon "Some" (PVar "m")) (PVar "x")) (EApp (EVar "Some") (EApp (EApp (EMethodRef "max") (EVar "m")) (EVar "x")))))) (EApp (EApp (EMethodRef "fold") (EVar "step")) (EVar "None"))))
(DTypeSig true "minimum" (TyConstrained ((cstr "Foldable" (TyVar "t")) (cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyVar "t") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "minimum" () (ELetGroup ((lgb "step" (clause ((PCon "None") (PVar "x")) (EApp (EVar "Some") (EVar "x"))) (clause ((PCon "Some" (PVar "m")) (PVar "x")) (EApp (EVar "Some") (EApp (EApp (EMethodRef "min") (EVar "m")) (EVar "x")))))) (EApp (EApp (EMethodRef "fold") (EVar "step")) (EVar "None"))))
(DImpl true "Filterable" ((TyCon "List")) () ((im "filterMap" (PWild (PList)) (EListLit)) (im "filterMap" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EMatch (EApp (EVar "f") (EVar "x")) (arm (PCon "Some" (PVar "y")) () (EBinOp "::" (EVar "y") (EApp (EApp (EMethodRef "filterMap") (EVar "f")) (EVar "xs")))) (arm (PCon "None") () (EApp (EApp (EMethodRef "filterMap") (EVar "f")) (EVar "xs"))))) (im "filter" ((PVar "p")) (EApp (EMethodRef "filterMap") (ELam ((PVar "x")) (EIf (EApp (EVar "p") (EVar "x")) (EApp (EVar "Some") (EVar "x")) (EVar "None")))))))
(DTypeSig true "otherwise" (TyCon "Bool"))
(DFunDef false "otherwise" () (EVar "True"))
(DTypeSig true "not" (TyFun (TyCon "Bool") (TyCon "Bool")))
(DFunDef false "not" ((PCon "True")) (EVar "False"))
(DFunDef false "not" ((PCon "False")) (EVar "True"))
(DTypeSig true "and" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "and" ((PCon "True") (PCon "True")) (EVar "True"))
(DFunDef false "and" (PWild PWild) (EVar "False"))
(DTypeSig true "or" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "or" ((PCon "False") (PCon "False")) (EVar "False"))
(DFunDef false "or" (PWild PWild) (EVar "True"))
(DTypeSig true "xor" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "xor" ((PVar "a") (PVar "b")) (EBinOp "!=" (EVar "a") (EVar "b")))
(DTypeSig true "isSome" (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isSome" ((PCon "Some" PWild)) (EVar "True"))
(DFunDef false "isSome" ((PCon "None")) (EVar "False"))
(DTypeSig true "isNone" (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isNone" ((PCon "None")) (EVar "True"))
(DFunDef false "isNone" ((PCon "Some" PWild)) (EVar "False"))
(DTypeSig true "fromOption" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyVar "a"))))
(DFunDef false "fromOption" (PWild (PCon "Some" (PVar "a"))) (EVar "a"))
(DFunDef false "fromOption" ((PVar "d") (PCon "None")) (EVar "d"))
(DTypeSig true "toResult" (TyFun (TyVar "e") (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")))))
(DFunDef false "toResult" (PWild (PCon "Some" (PVar "a"))) (EApp (EVar "Ok") (EVar "a")))
(DFunDef false "toResult" ((PVar "e") (PCon "None")) (EApp (EVar "Err") (EVar "e")))
(DTypeSig true "fromResult" (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "fromResult" ((PCon "Ok" (PVar "a"))) (EApp (EVar "Some") (EVar "a")))
(DFunDef false "fromResult" ((PCon "Err" PWild)) (EVar "None"))
(DTypeSig true "isOk" (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isOk" ((PCon "Ok" PWild)) (EVar "True"))
(DFunDef false "isOk" ((PCon "Err" PWild)) (EVar "False"))
(DTypeSig true "isErr" (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isErr" ((PCon "Err" PWild)) (EVar "True"))
(DFunDef false "isErr" ((PCon "Ok" PWild)) (EVar "False"))
(DTypeSig true "fromResultOr" (TyFun (TyVar "a") (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyVar "a"))))
(DFunDef false "fromResultOr" (PWild (PCon "Ok" (PVar "a"))) (EVar "a"))
(DFunDef false "fromResultOr" ((PVar "d") (PCon "Err" PWild)) (EVar "d"))
(DTypeSig true "mapErr" (TyFun (TyFun (TyVar "e") (TyVar "f")) (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Result") (TyVar "f")) (TyVar "a")))))
(DFunDef false "mapErr" ((PVar "f") (PCon "Err" (PVar "e"))) (EApp (EVar "Err") (EApp (EVar "f") (EVar "e"))))
(DFunDef false "mapErr" (PWild (PCon "Ok" (PVar "a"))) (EApp (EVar "Ok") (EVar "a")))
(DTypeSig true "identity" (TyFun (TyVar "a") (TyVar "a")))
(DFunDef false "identity" ((PVar "x")) (EVar "x"))
(DTypeSig true "fst" (TyFun (TyTuple (TyVar "a") (TyVar "b")) (TyVar "a")))
(DFunDef false "fst" ((PTuple (PVar "a") PWild)) (EVar "a"))
(DTypeSig true "snd" (TyFun (TyTuple (TyVar "a") (TyVar "b")) (TyVar "b")))
(DFunDef false "snd" ((PTuple PWild (PVar "b"))) (EVar "b"))
(DTypeSig true "const" (TyFun (TyVar "a") (TyFun (TyVar "b") (TyVar "a"))))
(DFunDef false "const" ((PVar "x") PWild) (EVar "x"))
(DTypeSig true "flip" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c")))) (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "c"))))))
(DFunDef false "flip" ((PVar "f") (PVar "b") (PVar "a")) (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")))
(DTypeSig true "on" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c")))) (TyFun (TyFun (TyVar "a") (TyVar "b")) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "c")))))))
(DFunDef false "on" ((PVar "f") (PVar "g") (PVar "x") (PVar "y")) (EApp (EApp (EVar "f") (EApp (EVar "g") (EVar "x"))) (EApp (EVar "g") (EVar "y"))))
(DTypeSig true "curry" (TyFun (TyFun (TyTuple (TyVar "a") (TyVar "b")) (TyEffect () (Some "e") (TyVar "c"))) (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c"))))))
(DFunDef false "curry" ((PVar "f") (PVar "a") (PVar "b")) (EApp (EVar "f") (ETuple (EVar "a") (EVar "b"))))
(DTypeSig true "uncurry" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c")))) (TyFun (TyTuple (TyVar "a") (TyVar "b")) (TyEffect () (Some "e") (TyVar "c")))))
(DFunDef false "uncurry" ((PVar "f") (PTuple (PVar "a") (PVar "b"))) (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")))
(DTypeSig true "discard" (TyConstrained ((cstr "Mappable" (TyVar "f"))) (TyFun (TyApp (TyVar "f") (TyVar "a")) (TyApp (TyVar "f") (TyCon "Unit")))))
(DFunDef false "discard" ((PVar "fa")) (EApp (EApp (EMethodRef "map") (ELam (PWild) (ELit LUnit))) (EVar "fa")))
(DTypeSig true "compose" (TyFun (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "c"))))))
(DFunDef false "compose" ((PVar "g") (PVar "f") (PVar "a")) (EApp (EVar "g") (EApp (EVar "f") (EVar "a"))))
(DTypeSig true "pipe" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c"))) (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "c"))))))
(DFunDef false "pipe" ((PVar "f") (PVar "g") (PVar "a")) (EApp (EVar "g") (EApp (EVar "f") (EVar "a"))))
(DTypeSig true "apply" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))))
(DFunDef false "apply" ((PVar "f") (PVar "a")) (EApp (EVar "f") (EVar "a")))
(DInterface true false "Arbitrary" ("a") () ((imethod "arbitrary" (TyFun (TyCon "Unit") (TyEffect ("Rand") None (TyVar "a"))) None) (imethod "shrink" (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a"))) (mdef (PWild) (EListLit)))))
(DImpl true "Arbitrary" ((TyCon "Int")) () ((im "arbitrary" ((PLit LUnit)) (EApp (EApp (EVar "randomInt") (EUnOp "-" (ELit (LInt 1000)))) (ELit (LInt 1000)))) (im "shrink" ((PLit (LInt 0))) (EListLit)) (im "shrink" ((PVar "n")) (EListLit (ELit (LInt 0)) (EBinOp "/" (EVar "n") (ELit (LInt 2)))))))
(DImpl true "Arbitrary" ((TyCon "Bool")) () ((im "arbitrary" ((PLit LUnit)) (EApp (EVar "randomBool") (ELit LUnit))) (im "shrink" (PWild) (EListLit))))
(DImpl true "Arbitrary" ((TyCon "Float")) () ((im "arbitrary" ((PLit LUnit)) (EApp (EVar "randomFloat") (ELit LUnit))) (im "shrink" (PWild) (EListLit))))
(DImpl true "Arbitrary" ((TyCon "Char")) () ((im "arbitrary" ((PLit LUnit)) (EApp (EVar "randomChar") (ELit LUnit))) (im "shrink" (PWild) (EListLit))))
(DTypeSig true "arbitraryString" (TyFun (TyCon "Unit") (TyEffect ("Rand") None (TyCon "String"))))
(DFunDef false "arbitraryString" ((PLit LUnit)) (ELetGroup ((lgb "go" (clause ((PLit (LInt 0)) (PVar "acc")) (EVar "acc")) (clause ((PVar "n") (PVar "acc")) (EApp (EApp (EVar "go") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EVar "randomChar") (ELit LUnit)))))))) (EApp (EApp (EVar "go") (EApp (EApp (EVar "randomInt") (ELit (LInt 0))) (ELit (LInt 10)))) (ELit (LString "")))))
(DImpl true "Arbitrary" ((TyCon "String")) () ((im "arbitrary" ((PLit LUnit)) (EApp (EVar "arbitraryString") (ELit LUnit))) (im "shrink" (PWild) (EListLit))))
(DTypeSig true "arbitraryList" (TyFun (TyFun (TyCon "Unit") (TyEffect ("Rand") None (TyVar "a"))) (TyFun (TyCon "Int") (TyEffect ("Rand") None (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "arbitraryList" ((PVar "gen") (PVar "maxLen")) (ELetGroup ((lgb "go" (clause ((PLit (LInt 0)) (PVar "acc")) (EVar "acc")) (clause ((PVar "n") (PVar "acc")) (EApp (EApp (EVar "go") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "gen") (ELit LUnit)) (EVar "acc")))))) (EApp (EApp (EVar "go") (EApp (EApp (EVar "randomInt") (ELit (LInt 0))) (EVar "maxLen"))) (EListLit))))
(DData Public "Rep" () ((variant "RCon" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Rep")))) (variant "RRecord" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "RField")))) (variant "RInt" (ConPos (TyCon "Int"))) (variant "RFloat" (ConPos (TyCon "Float"))) (variant "RString" (ConPos (TyCon "String"))) (variant "RBool" (ConPos (TyCon "Bool"))) (variant "RChar" (ConPos (TyCon "Char"))) (variant "RUnit" (ConPos))) ())
(DData Public "RField" () ((variant "RField" (ConNamed (field "fld_name" (TyCon "String")) (field "fld_rep" (TyCon "Rep"))))) ())
(DInterface true false "Generic" ("a") () ((imethod "to_rep" (TyFun (TyVar "a") (TyCon "Rep")) None) (imethod "from_rep" (TyFun (TyCon "Rep") (TyVar "a")) (mdef (PWild) (EApp (EVar "panic") (ELit (LString "from_rep: not implemented (Phase 1 is to_rep only)")))))))
(DImpl true "Generic" ((TyCon "Int")) () ((im "to_rep" ((PVar "n")) (EApp (EVar "RInt") (EVar "n"))) (im "from_rep" (PWild) (EApp (EVar "panic") (ELit (LString "from_rep: not implemented (Phase 1 is to_rep only)"))))))
(DImpl true "Generic" ((TyCon "Float")) () ((im "to_rep" ((PVar "x")) (EApp (EVar "RFloat") (EVar "x"))) (im "from_rep" (PWild) (EApp (EVar "panic") (ELit (LString "from_rep: not implemented (Phase 1 is to_rep only)"))))))
(DImpl true "Generic" ((TyCon "String")) () ((im "to_rep" ((PVar "s")) (EApp (EVar "RString") (EVar "s"))) (im "from_rep" (PWild) (EApp (EVar "panic") (ELit (LString "from_rep: not implemented (Phase 1 is to_rep only)"))))))
(DImpl true "Generic" ((TyCon "Bool")) () ((im "to_rep" ((PVar "b")) (EApp (EVar "RBool") (EVar "b"))) (im "from_rep" (PWild) (EApp (EVar "panic") (ELit (LString "from_rep: not implemented (Phase 1 is to_rep only)"))))))
(DImpl true "Generic" ((TyCon "Char")) () ((im "to_rep" ((PVar "c")) (EApp (EVar "RChar") (EVar "c"))) (im "from_rep" (PWild) (EApp (EVar "panic") (ELit (LString "from_rep: not implemented (Phase 1 is to_rep only)"))))))
(DImpl true "Generic" ((TyCon "Unit")) () ((im "to_rep" (PWild) (EVar "RUnit")) (im "from_rep" (PWild) (EApp (EVar "panic") (ELit (LString "from_rep: not implemented (Phase 1 is to_rep only)"))))))
(DProp false "neq is the negation of eq" ((pp "x" (TyCon "Int")) (pp "y" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EDictApp "neq") (EVar "x")) (EVar "y")) (EApp (EVar "not") (EApp (EApp (EMethodRef "eq") (EVar "x")) (EVar "y")))))
(DProp false "compare agrees with lt/gt/eq" ((pp "x" (TyCon "Int")) (pp "y" (TyCon "Int"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "lt") (EVar "x")) (EVar "y")) (EApp (EVar "not") (EApp (EApp (EMethodRef "gt") (EVar "x")) (EVar "y")))) (EApp (EApp (EDictApp "neq") (EVar "x")) (EVar "y")))) (arm (PCon "Gt") () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "gt") (EVar "x")) (EVar "y")) (EApp (EVar "not") (EApp (EApp (EMethodRef "lt") (EVar "x")) (EVar "y")))) (EApp (EApp (EDictApp "neq") (EVar "x")) (EVar "y")))) (arm (PCon "Eq") () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "x")) (EVar "y")) (EApp (EVar "not") (EApp (EApp (EMethodRef "lt") (EVar "x")) (EVar "y")))) (EApp (EVar "not") (EApp (EApp (EMethodRef "gt") (EVar "x")) (EVar "y")))))))
(DProp false "clamp keeps values inside the interval" ((pp "x" (TyCon "Int"))) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EDictApp "clamp") (ELit (LInt 0))) (ELit (LInt 100))) (EVar "x"))) (DoExpr (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 0))) (EBinOp "<=" (EVar "c") (ELit (LInt 100)))))))
(DProp false "filter . filter p == filter p" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 0))))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 0))))) (EVar "xs")))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 0))))) (EVar "xs"))))
(DProp false "length matches a counting fold" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EMethodRef "length") (EVar "xs")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") PWild) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))) (ELit (LInt 0))) (EVar "xs"))))
(DProp false "any/all duality" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EApp (EDictApp "any") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 0))))) (EVar "xs")) (EApp (EVar "not") (EApp (EApp (EDictApp "all") (ELam ((PVar "x")) (EBinOp "<=" (EVar "x") (ELit (LInt 0))))) (EVar "xs")))))
(DProp false "fromOption d (Some x) == x" ((pp "x" (TyCon "Int")) (pp "d" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "fromOption") (EVar "d")) (EApp (EVar "Some") (EVar "x"))) (EVar "x")))
(DProp false "toResult/fromResult round-trip on Some" ((pp "x" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EVar "fromResult") (EApp (EApp (EVar "toResult") (ELit (LString "missing"))) (EApp (EVar "Some") (EVar "x"))))) (EApp (EVar "Some") (EVar "x"))))
(DProp false "Ord (List a) is reflexive" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "xs")) (EVar "xs")) (arm (PCon "Eq") () (EVar "True")) (arm PWild () (EVar "False"))))
(DProp false "discard replaces the payload with Unit" ((pp "x" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EDictApp "discard") (EApp (EVar "Some") (EVar "x")))) (EApp (EVar "Some") (ELit LUnit))))
(DProp false "on agrees with its hand expansion" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EApp (EApp (EVar "on") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (ELam ((PVar "n")) (EBinOp "*" (EVar "n") (ELit (LInt 2))))) (EVar "a")) (EVar "b")) (EBinOp "+" (EBinOp "*" (EVar "a") (ELit (LInt 2))) (EBinOp "*" (EVar "b") (ELit (LInt 2))))))
(DProp false "map2 on Some matches direct application" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EApp (EDictApp "map2") (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))) (EApp (EVar "Some") (EVar "a"))) (EApp (EVar "Some") (EVar "b")))) (EApp (EVar "Some") (EBinOp "+" (EVar "a") (EVar "b")))))
(DProp false "map3 on Some matches direct application" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int")) (pp "c" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EApp (EApp (EDictApp "map3") (ELam ((PVar "x") (PVar "y") (PVar "z")) (EBinOp "+" (EBinOp "+" (EVar "x") (EVar "y")) (EVar "z")))) (EApp (EVar "Some") (EVar "a"))) (EApp (EVar "Some") (EVar "b"))) (EApp (EVar "Some") (EVar "c")))) (EApp (EVar "Some") (EBinOp "+" (EBinOp "+" (EVar "a") (EVar "b")) (EVar "c")))))
(DProp false "mapFirst on Result generalizes mapErr" ((pp "n" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EMethodRef "mapFirst") (ELam ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))) (EAnnot (EApp (EVar "Err") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int"))))) (EApp (EApp (EVar "mapErr") (ELam ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))) (EApp (EVar "Err") (EVar "n")))))
(DProp false "foldThen with Some agrees with a pure fold" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EApp (EDictApp "foldThen") (ELam ((PVar "acc") (PVar "x")) (EApp (EVar "Some") (EBinOp "+" (EVar "acc") (EVar "x"))))) (ELit (LInt 0))) (EVar "xs"))) (EApp (EVar "Some") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "+" (EVar "acc") (EVar "x")))) (ELit (LInt 0))) (EVar "xs")))))
