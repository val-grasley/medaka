# META
source_lines=953
stages=DESUGAR,MARK
# SOURCE
-- list.mdk — operations on List a
-- See STDLIB.md for the full implementation plan.

import core.{Eq, Ord, Debug, Foldable, Mappable, Ordering, Option, Result}

-- Re-export the Filterable container ops so they're discoverable as
-- `list.filter` / `list.filterMap`.
export import core.{Filterable, filter, filterMap}

-- `maximum`/`minimum`/`elem`/`notElem`/`sum`/`product`/`find`/`any`/`all`/
-- `count`/`fold`/`foldRight` are *not* defined here: they are generic over
-- `Foldable` in core (the prelude), so they already work on `List` directly.
-- `impl Ord (List a)` (lexicographic) likewise lives in core next to
-- `impl Eq (List a)`.

-- Construction

export singleton : a -> List a
singleton a = [a]

{- | The half-open integer interval `[lo, hi)` — `lo` up to but excluding `hi`.
   Empty when `lo >= hi`.

   > range 2 5
   [2, 3, 4]
   > range 5 5
   []
   > range 5 2
   []
   > range 0 1
   [0] -}
export range : Int -> Int -> List Int
range lo hi = [lo..hi]

{- | `rangeStep lo hi step` — arithmetic sequence from `lo`, stepping by `step`,
   stopping before `hi`.  Empty when `step` points away from `hi` (or is `0`).

   > rangeStep 0 10 3
   [0, 3, 6, 9]
   > rangeStep 5 0 (-2)
   [5, 3, 1] -}
export rangeStep : Int -> Int -> Int -> List Int
rangeStep lo hi step
  | step > 0 && lo < hi = lo :: rangeStep (lo + step) hi step
  | step < 0 && lo > hi = lo :: rangeStep (lo + step) hi step
  | otherwise = []

{- | A list of `n` copies of `x` (empty when `n <= 0`).

   > replicate 3 0
   [0, 0, 0] -}
export replicate : Int -> a -> List a
replicate n x
  | n <= 0 = []
  | otherwise = x :: replicate (n - 1) x

{- | `[x, f x, f (f x), …]` of length `n`.  Empty when `n <= 0`.

   > iterate 4 (n => n * 2) 1
   [1, 2, 4, 8]
   > iterate 0 (n => n * 2) 1
   []
   > iterate 1 (n => n * 2) 1
   [1] -}
export iterate : Int -> (a -> <e> a) -> a -> <e> List a
iterate n f x
  | n <= 0 = []
  | otherwise = x :: iterate (n - 1) f (f x)

{- | Build a list from a seed: `gen` returns `Some (element, nextSeed)` to emit
   an element and continue, or `None` to stop.

   > unfold (n => if n > 5 then None else Some (n, n + 1)) 1
   [1, 2, 3, 4, 5]
   > unfold (n => if n > 0 then None else Some (n, n + 1)) 1
   []
   > unfold (n => if n > 0 then None else Some (n, n + 1)) 0
   [0] -}
export unfold : (b -> <e> Option (a, b)) -> b -> <e> List a
unfold gen seed = match gen seed
  None => []
  Some (x, next) => x :: unfold gen next

-- Transformation

{- | The list in reverse order.  Tail-recursive accumulator — safe on long
   lists where right-leaning recursion would overflow the stack.

   > reverse [1, 2, 3]
   [3, 2, 1] -}
export reverse : List a -> List a
reverse xs = go xs []
  where
    go [] acc = acc
    go (y::ys) acc = go ys (y::acc)

{- | Insert `sep` between every pair of adjacent elements.

   > intersperse 0 [1, 2, 3]
   [1, 0, 2, 0, 3] -}
export intersperse : a -> List a -> List a
intersperse _ [] = []
intersperse _ [x] = [x]
intersperse sep (x::xs) = x :: sep :: intersperse sep xs

{- | Concatenate the inner lists with `sep` between them — `intersperse` then
   flatten.

   > intercalate [0] [[1], [2, 3], [4]]
   [1, 0, 2, 3, 0, 4] -}
export intercalate : List a -> List (List a) -> List a
intercalate sep xss = flat (intersperse sep xss)

{- | Turn rows into columns.  Ragged rows are allowed: shorter rows simply
   contribute nothing to the later columns.

   > transpose [[1, 2, 3], [4, 5, 6]]
   [[1, 4], [2, 5], [3, 6]]
   > transpose [[1, 2], [3], [4, 5, 6]]
   [[1, 3, 4], [2, 5], [6]] -}
export transpose : List (List a) -> List (List a)
transpose [] = []
transpose ([]::xss) = transpose xss
transpose ((x::xs)::xss) =
  (x :: filterMap head xss) :: transpose (xs :: filterMap tail xss)

{- | Every subsequence (subset preserving order), `2^n` of them.

   > subsequences [1, 2, 3]
   [[], [1], [2], [1, 2], [3], [1, 3], [2, 3], [1, 2, 3]] -}
export subsequences : List a -> List (List a)
subsequences [] = [[]]
subsequences (x::xs) = flatMap (sub => [sub, x::sub]) (subsequences xs)

{- | Every ordering of the list, `n!` of them (lexicographic by original
   position).

   > permutations [1, 2, 3]
   [[1, 2, 3], [1, 3, 2], [2, 1, 3], [2, 3, 1], [3, 1, 2], [3, 2, 1]] -}
export permutations : List a -> List (List a)
permutations [] = [[]]
permutations xs =
  flatMap ((h, rest) => map (h :: _) (permutations rest)) (selections xs)

-- Each element paired with the list of the others, original order preserved.
selections : List a -> List (a, List a)
selections [] = []
selections (x::xs) = (x, xs) :: map ((y, ys) => (y, x::ys)) (selections xs)

-- Folds and scans

{- | Like `fold`, but keeping every intermediate accumulator (so the result is
   one longer than the input).

   > scanLeft (acc x => acc + x) 0 [1, 2, 3]
   [0, 1, 3, 6] -}
export scanLeft : (b -> a -> <e> b) -> b -> List a -> <e> List b
scanLeft _ z [] = [z]
scanLeft f z (x::xs) = z :: scanLeft f (f z x) xs

{- | Right-associated `scanLeft`: every intermediate of a right fold.

   > scanRight (x acc => x + acc) 0 [1, 2, 3]
   [6, 5, 3, 0] -}
export scanRight : (a -> b -> <e> b) -> b -> List a -> <e> List b
scanRight _ z [] = [z]
scanRight f z (x::xs) = match scanRight f z xs
  q::qs => f x q :: q::qs
  [] => [f x z]

-- Search

{- | Index of the first element satisfying the predicate, or `None`.

   > findIndex (x => x > 2) [1, 2, 3, 4]
   Some 2 -}
export findIndex : (a -> <e> Bool) -> List a -> <e> Option Int
findIndex p xs = go 0 xs
  where
    go _ [] = None
    go i (x::rest)
      | p x = Some i
      | otherwise = go (i + 1) rest

{- | Indices of every element satisfying the predicate.

   > findIndices (x => x > 2) [1, 3, 2, 4]
   [1, 3] -}
export findIndices : (a -> <e> Bool) -> List a -> <e> List Int
findIndices p xs = go 0 xs
  where
    go _ [] = []
    go i (x::rest)
      | p x = i :: go (i + 1) rest
      | otherwise = go (i + 1) rest

{- | Index of the first occurrence of `x` (by `Eq`), or `None`.

   > elemIndex 3 [1, 2, 3, 2]
   Some 2 -}
export elemIndex : Eq a => a -> List a -> Option Int
elemIndex x xs = findIndex (== x) xs

{- | Indices of every occurrence of `x` (by `Eq`).

   > elemIndices 2 [1, 2, 3, 2]
   [1, 3]
   > elemIndices 9 [1, 2, 3]
   [] -}
export elemIndices : Eq a => a -> List a -> List Int
elemIndices x xs = findIndices (== x) xs

{- | Look `key` up in an association list, returning the first match.
   `O(n)` — for a large or long-lived table reach for `map.Map` (`O(log n)`)
   or `hash_map.HashMap` instead.

   > lookup 2 [(1, "a"), (2, "b")]
   Some "b"
   > lookup 9 [(1, "a"), (2, "b")]
   None -}
export lookup : Eq k => k -> List (k, v) -> Option v
lookup _ [] = None
lookup key ((k, v)::rest)
  | key == k = Some v
  | otherwise = lookup key rest

{- | The first non-`None` result of `f` — `find` and `map` in a single pass,
   without rebuilding the list.  Short-circuits on the first hit.

   > findMap (x => if x > 2 then Some (x * 10) else None) [1, 2, 3, 4]
   Some 30
   > findMap (x => if x > 9 then Some x else None) [1, 2, 3]
   None -}
export findMap : (a -> <e> Option b) -> List a -> <e> Option b
findMap _ [] = None
findMap f (x::rest) = match f x
  Some y => Some y
  None => findMap f rest

-- Non-empty folds

{- | Left-fold using the first element as the seed — `None` on an empty list.
   Named `reduce` rather than `foldl1`: it needs no seed, so it reads as
   "reduce the list to one value".

   > reduce (x y => x + y) [1, 2, 3, 4]
   Some 10
   > reduce (x y => if x > y then x else y) [3, 1, 2]
   Some 3
   > reduce (x y => x + y) ([] : List Int)
   None -}
export reduce : (a -> a -> <e> a) -> List a -> <e> Option a
reduce _ [] = None
reduce f (x::xs) = Some (go x xs)
  where
    go acc [] = acc
    go acc (y::rest) = go (f acc y) rest

{- | Largest element by a custom comparator, or `None` when empty.  Ties keep
   the *first* of the equal elements.  `maximum` (core) is the `Ord` case.

   > maximumBy (x y => compare (x % 10) (y % 10)) [23, 47, 15]
   Some 47
   > maximumBy compare ([] : List Int)
   None -}
export maximumBy : (a -> a -> <e> Ordering) -> List a -> <e> Option a
maximumBy cmp xs = reduce pick xs
  where
    pick a b = match cmp b a
      Gt => b
      _ => a

{- | Smallest element by a custom comparator, or `None` when empty.  Ties keep
   the *first* of the equal elements.  `minimum` (core) is the `Ord` case.

   > minimumBy (x y => compare (x % 10) (y % 10)) [23, 47, 15]
   Some 23
   > minimumBy compare ([] : List Int)
   None -}
export minimumBy : (a -> a -> <e> Ordering) -> List a -> <e> Option a
minimumBy cmp xs = reduce pick xs
  where
    pick a b = match cmp b a
      Lt => b
      _ => a

-- Indexed

{- | `map`, but `f` also receives each element's 0-based index.

   > mapWithIndex (i x => i * x) [1, 2, 3]
   [0, 2, 6]
   > mapWithIndex (i x => i + x) [10, 20]
   [10, 21] -}
export mapWithIndex : (Int -> a -> <e> b) -> List a -> <e> List b
mapWithIndex f xs = go 0 xs
  where
    go _ [] = []
    go i (x::rest) = f i x :: go (i + 1) rest

{- | Pair every element with its 0-based index.

   > indexed ["a", "b", "c"]
   [(0, "a"), (1, "b"), (2, "c")] -}
export indexed : List a -> List (Int, a)
indexed xs = mapWithIndex (i x => (i, x)) xs

{- | Left-to-right `map` threading an accumulator: `f` sees the running state
   and each element, and returns the new state plus the mapped element.
   Returns the final state and the mapped list.

   > mapAccumL (s x => (s + x, s)) 0 [1, 2, 3]
   (6, [0, 1, 3]) -}
export mapAccumL : (s -> a -> <e> (s, b)) -> s -> List a -> <e> (s, List b)
mapAccumL _ s [] = (s, [])
mapAccumL f s (x::xs) =
  let (s2, y) = f s x
  let (s3, ys) = mapAccumL f s2 xs
  (s3, y::ys)

{- | Like `mapAccumL`, but threads the accumulator right-to-left.  The output
   list stays in the input's order.

   > mapAccumR (s x => (s + x, s)) 0 [1, 2, 3]
   (6, [5, 3, 0]) -}
export mapAccumR : (s -> a -> <e> (s, b)) -> s -> List a -> <e> (s, List b)
mapAccumR _ s [] = (s, [])
mapAccumR f s (x::xs) =
  let (s2, ys) = mapAccumR f s xs
  let (s3, y) = f s2 x
  (s3, y::ys)

-- Positional edits
--
-- All three clamp rather than panic, matching `slice`/`take`: an index outside
-- the list is a no-op (`insertAt` clamps to the nearer end).

{- | Insert `x` so that it lands at index `i`, shifting the rest right.
   `i <= 0` prepends; `i >= length` appends.

   > insertAt 1 9 [1, 2, 3]
   [1, 9, 2, 3]
   > insertAt 0 9 [1, 2]
   [9, 1, 2]
   > insertAt 7 9 [1, 2]
   [1, 2, 9] -}
export insertAt : Int -> a -> List a -> List a
insertAt _ x [] = [x]
insertAt i x (y::rest)
  | i <= 0 = x :: y::rest
  | otherwise = y :: insertAt (i - 1) x rest

{- | Replace the element at index `i` with `x`.  Out-of-range leaves the list
   unchanged.

   > updateAt 1 9 [1, 2, 3]
   [1, 9, 3]
   > updateAt 7 9 [1, 2]
   [1, 2] -}
export updateAt : Int -> a -> List a -> List a
updateAt _ _ [] = []
updateAt i x (y::rest)
  | i < 0 = y::rest
  | i == 0 = x::rest
  | otherwise = y :: updateAt (i - 1) x rest

{- | Drop the element at index `i`.  Out-of-range leaves the list unchanged.

   > removeAt 1 [1, 2, 3]
   [1, 3]
   > removeAt 7 [1, 2]
   [1, 2] -}
export removeAt : Int -> List a -> List a
removeAt _ [] = []
removeAt i (y::rest)
  | i < 0 = y::rest
  | i == 0 = rest
  | otherwise = y :: removeAt (i - 1) rest

-- Sublists

{- | First `n` elements (fewer if the list is shorter).

   > take 2 [1, 2, 3, 4]
   [1, 2] -}
export take : Int -> List a -> List a
take _ [] = []
take n (x::xs)
  | n <= 0 = []
  | otherwise = x :: take (n - 1) xs

{- | Everything after the first `n` elements.

   > drop 2 [1, 2, 3, 4]
   [3, 4] -}
export drop : Int -> List a -> List a
drop _ [] = []
drop n (xs@(_::rest))
  | n <= 0 = xs
  | otherwise = drop (n - 1) rest

{- | Longest prefix whose elements all satisfy the predicate.

   > takeWhile (x => x < 3) [1, 2, 3, 1]
   [1, 2]
   > takeWhile (x => x < 9) [1, 2, 3]
   [1, 2, 3]
   > takeWhile (x => x < 0) [1, 2, 3]
   []
   > takeWhile (x => x < 3) ([] : List Int)
   [] -}
export takeWhile : (a -> <e> Bool) -> List a -> <e> List a
takeWhile _ [] = []
takeWhile p (x::xs)
  | p x = x :: takeWhile p xs
  | otherwise = []

{- | Drop the longest prefix whose elements satisfy the predicate.

   > dropWhile (x => x < 3) [1, 2, 3, 1]
   [3, 1]
   > dropWhile (x => x < 9) [1, 2, 3]
   []
   > dropWhile (x => x < 0) [1, 2, 3]
   [1, 2, 3]
   > dropWhile (x => x < 3) ([] : List Int)
   [] -}
export dropWhile : (a -> <e> Bool) -> List a -> <e> List a
dropWhile _ [] = []
dropWhile p (xs@(x::rest))
  | p x = dropWhile p rest
  | otherwise = xs

{- | `(takeWhile p xs, dropWhile p xs)`, in a single pass.

   > span (x => x < 3) [1, 2, 3, 1]
   ([1, 2], [3, 1])
   > span (x => x < 9) [1, 2, 3]
   ([1, 2, 3], [])
   > span (x => x < 0) [1, 2, 3]
   ([], [1, 2, 3])
   > span (x => x < 3) ([] : List Int)
   ([], []) -}
export span : (a -> <e> Bool) -> List a -> <e> (List a, List a)
span _ [] = ([], [])
span p (xs@(x::rest))
  | p x = let (a, b) = span p rest in (x::a, b)
  | otherwise = ([], xs)

{- | `span` with the predicate negated: split at the first element that *does*
   satisfy `p`.

   > break (x => x > 2) [1, 2, 3, 1]
   ([1, 2], [3, 1])
   > break (x => x > 9) [1, 2, 3]
   ([1, 2, 3], [])
   > break (x => x > 0) [1, 2, 3]
   ([], [1, 2, 3])
   > break (x => x > 2) ([] : List Int)
   ([], []) -}
export break : (a -> <e> Bool) -> List a -> <e> (List a, List a)
break p xs = span (x => not (p x)) xs

{- | `(take n xs, drop n xs)`, in a single pass.

   > splitAt 2 [1, 2, 3, 4]
   ([1, 2], [3, 4]) -}
export splitAt : Int -> List a -> (List a, List a)
splitAt _ [] = ([], [])
splitAt n (xs@(x::rest))
  | n <= 0 = ([], xs)
  | otherwise = let (a, b) = splitAt (n - 1) rest in (x::a, b)

{- | `slice lo hi xs` — the elements at indices `[lo, hi)`.

   > slice 1 3 [10, 20, 30, 40]
   [20, 30] -}
export slice : Int -> Int -> List a -> List a
slice lo hi xs = drop lo (take hi xs)

{- | Split into consecutive groups of `n` (the last group may be shorter).
   Empty when `n <= 0`.

   > chunks 2 [1, 2, 3, 4, 5]
   [[1, 2], [3, 4], [5]] -}
export chunks : Int -> List a -> List (List a)
chunks _ [] = []
chunks n (xs@(_::_))
  | n <= 0 = []
  | otherwise = take n xs :: chunks n (drop n xs)

{- | Drop the longest *suffix* whose elements all satisfy the predicate — the
   mirror of `dropWhile`.  Trailing-whitespace trimming is the usual reason.

   > dropWhileEnd (x => x == 0) [1, 2, 0, 0]
   [1, 2]
   > dropWhileEnd (x => x == 0) [0, 1, 0]
   [0, 1]
   > dropWhileEnd (x => x == 0) [0, 0]
   [] -}
export dropWhileEnd : (a -> <e> Bool) -> List a -> <e> List a
dropWhileEnd p xs = reverse (dropWhile p (reverse xs))

{- | The longest *suffix* whose elements all satisfy the predicate — the mirror
   of `takeWhile`.

   > takeWhileEnd (x => x > 1) [1, 2, 3]
   [2, 3]
   > takeWhileEnd (x => x > 9) [1, 2, 3]
   []
   > takeWhileEnd (x => x > 0) [1, 2]
   [1, 2] -}
export takeWhileEnd : (a -> <e> Bool) -> List a -> <e> List a
takeWhileEnd p xs = reverse (takeWhile p (reverse xs))

{- | Split on every occurrence of the separator *sublist*, dropping the
   separators.  The list analogue of `string.split` — same needle-first
   argument order, and an empty separator likewise yields `[xs]`.
   (`splitAt` is the unrelated positional one, which takes an `Int`.)

   > split [0] [1, 0, 2, 0, 3]
   [[1], [2], [3]]
   > split [0, 0] [1, 0, 0, 2]
   [[1], [2]]
   > split [9] [1, 2]
   [[1, 2]]
   > split [0] [0, 1]
   [[], [1]] -}
export split : Eq a => List a -> List a -> List (List a)
split [] xs = [xs]
split sep xs = go xs
  where
    sepLen = length sep
    go ys = match findSub 0 ys
      None => [ys]
      Some i => take i ys :: go (drop (i + sepLen) ys)
    findSub i ys
      | startsWith sep ys = Some i
      | otherwise = findSubTail i ys
    findSubTail _ [] = None
    findSubTail i (_::rest) = findSub (i + 1) rest

-- Sublist predicates
--
-- Named to mirror `string.startsWith` / `endsWith` / `contains` (same
-- needle-first argument order) rather than Haskell's `isPrefixOf` family —
-- these ask the same question of a different container, so they get the same
-- name.  For a *single element* rather than a sublist, `elem` (core, over any
-- `Foldable`) is what you want.

{- | True when `prefix` is a leading sublist of `xs`.  Every list starts with
   the empty list.

   > startsWith [1, 2] [1, 2, 3]
   True
   > startsWith [2, 3] [1, 2, 3]
   False
   > startsWith ([] : List Int) [1]
   True -}
export startsWith : Eq a => List a -> List a -> Bool
startsWith [] _ = True
startsWith _ [] = False
startsWith (p::ps) (x::xs) = p == x && startsWith ps xs

{- | True when `suffix` is a trailing sublist of `xs`.

   > endsWith [2, 3] [1, 2, 3]
   True
   > endsWith [1, 2] [1, 2, 3]
   False -}
export endsWith : Eq a => List a -> List a -> Bool
endsWith suffix xs = startsWith (reverse suffix) (reverse xs)

{- | True when `sub` occurs as a contiguous run anywhere in `xs`.  `O(n*m)`
   naive scan — fine for short needles; for text prefer `string.contains`,
   which is host-backed.

   > contains [2, 3] [1, 2, 3, 4]
   True
   > contains [2, 4] [1, 2, 3, 4]
   False
   > contains ([] : List Int) [1]
   True -}
export contains : Eq a => List a -> List a -> Bool
contains sub [] = startsWith sub []
contains sub (xs@(_::rest))
  | startsWith sub xs = True
  | otherwise = contains sub rest

-- Sorting

{- | Stable sort with a custom comparator (bottom-up is unnecessary; a plain
   recursive merge sort is stable and `O(n log n)`).

   > sortBy (x y => compare y x) [3, 1, 2]
   [3, 2, 1] -}
export sortBy : (a -> a -> <e> Ordering) -> List a -> <e> List a
sortBy _ [] = []
sortBy _ [x] = [x]
sortBy cmp xs =
  let (l, r) = splitAt (length xs / 2) xs
  merge cmp (sortBy cmp l) (sortBy cmp r)

-- Merge two sorted runs, taking from the left on ties so the sort stays stable.
merge : (a -> a -> <e> Ordering) -> List a -> List a -> <e> List a
merge _ [] ys = ys
merge _ xs [] = xs
merge cmp (xs@(x::xs')) (ys@(y::ys')) = match cmp x y
  Gt => y :: merge cmp xs ys'
  _ => x :: merge cmp xs' ys

{- | Ascending stable sort by the `Ord` instance.

   > sort [3, 1, 2, 1]
   [1, 1, 2, 3] -}
export sort : Ord a => List a -> List a
sort xs = sortBy compare xs

{- | Sort by a derived key, computing the key once per element via a
   decorate–sort–undecorate pass (the key may be expensive, so this avoids
   recomputing it inside every comparison).

   > sortOn (x => 0 - x) [1, 3, 2]
   [3, 2, 1] -}
export sortOn : Ord b => (a -> <e> b) -> List a -> <e> List a
sortOn key xs =
  let decorated = map (x => (key x, x)) xs
  map snd (sortBy ((k1, _) (k2, _) => compare k1 k2) decorated)

{- | Drop duplicates by a custom equality, keeping the first occurrence.
   `O(n²)` baseline.

   > nubBy (x y => x == y) [1, 2, 1, 3, 2]
   [1, 2, 3] -}
export nubBy : (a -> a -> <e> Bool) -> List a -> <e> List a
nubBy same xs = go xs []
  where
    go [] _ = []
    go (x::rest) seen
      | any (s => same x s) seen = go rest seen
      | otherwise = x :: go rest (x::seen)

{- | Drop duplicates by `Eq`, keeping the first occurrence.

   > nub [1, 2, 1, 3, 2, 1]
   [1, 2, 3] -}
export nub : Eq a => List a -> List a
nub xs = nubBy (==) xs

{- | Remove the *first* element matching a custom equality; unchanged when
   nothing matches.

   > deleteBy (x y => x == y) 2 [1, 2, 3, 2]
   [1, 3, 2] -}
export deleteBy : (a -> a -> <e> Bool) -> a -> List a -> <e> List a
deleteBy _ _ [] = []
deleteBy same x (y::rest)
  | same x y = rest
  | otherwise = y :: deleteBy same x rest

{- | Remove the *first* occurrence of `x` (by `Eq`); unchanged when absent.
   Only the first — `filter (!= x) xs` removes every occurrence.

   > delete 2 [1, 2, 3, 2]
   [1, 3, 2]
   > delete 9 [1, 2]
   [1, 2] -}
export delete : Eq a => a -> List a -> List a
delete x xs = deleteBy (==) x xs

-- Set-like operations (`union` / `intersect` / `difference`) are deliberately
-- absent: an `Eq`-based list version is `O(n*m)`, and `set.Set` already does
-- each in `O(n log m)` with the same semantics.  Reach for `set`, or
-- `hash_set` when the element is `Hashable`.

-- Grouping

{- | Group maximal runs of adjacent elements that satisfy the equivalence.

   > groupBy (x y => x == y) [1, 1, 2, 3, 3, 3]
   [[1, 1], [2], [3, 3, 3]] -}
export groupBy : (a -> a -> <e> Bool) -> List a -> <e> List (List a)
groupBy _ [] = []
groupBy same (x::xs) =
  let (grp, rest) = span (y => same x y) xs
  (x::grp) :: groupBy same rest

{- | Group maximal runs of adjacent equal elements (by `Eq`).

   > group [1, 1, 2, 3, 3]
   [[1, 1], [2], [3, 3]] -}
export group : Eq a => List a -> List (List a)
group xs = groupBy (==) xs

{- | `(filter p xs, filter (not . p) xs)`, in a single pass.

   > partition (x => x > 2) [1, 2, 3, 4]
   ([3, 4], [1, 2]) -}
export partition : (a -> <e> Bool) -> List a -> <e> (List a, List a)
partition _ [] = ([], [])
partition p (x::xs) =
  let (yes, no) = partition p xs
  if p x then (x::yes, no) else (yes, x::no)

{- | Keep the `Some`s, drop the `None`s.

   > somes [Some 1, None, Some 3]
   [1, 3]
   > somes ([] : List (Option Int))
   [] -}
export somes : List (Option a) -> List a
somes [] = []
somes ((Some x)::rest) = x :: somes rest
somes (None::rest) = somes rest

{- | Keep the `Ok` values, drop the `Err`s.

   > oks [Ok 1, Err "boom", Ok 3]
   [1, 3] -}
export oks : List (Result e a) -> List a
oks [] = []
oks ((Ok x)::rest) = x :: oks rest
oks ((Err _)::rest) = oks rest

{- | Keep the `Err` values, drop the `Ok`s.

   > errs [Ok 1, Err "boom", Ok 3]
   ["boom"] -}
export errs : List (Result e a) -> List e
errs [] = []
errs ((Err e)::rest) = e :: errs rest
errs ((Ok _)::rest) = errs rest

{- | Split into `(errs, oks)` in a single pass.

   > partitionResults [Ok 1, Err "boom", Ok 3]
   (["boom"], [1, 3]) -}
export partitionResults : List (Result e a) -> (List e, List a)
partitionResults [] = ([], [])
partitionResults ((Ok x)::rest) =
  let (es, xs) = partitionResults rest
  (es, x::xs)
partitionResults ((Err e)::rest) =
  let (es, xs) = partitionResults rest
  (e::es, xs)

{- | Count occurrences of each distinct element (by `Eq`), in first-seen order.

   > tally [1, 2, 1, 3, 1, 2]
   [(1, 3), (2, 2), (3, 1)] -}
export tally : Eq a => List a -> List (a, Int)
tally xs = go xs []
  where
    go [] acc = acc
    go (x::rest) acc = go rest (bump x acc)
    bump x [] = [(x, 1)]
    bump x ((k, c)::kvs)
      | k == x = (k, c + 1)::kvs
      | otherwise = (k, c) :: bump x kvs

-- Inspection
-- `isEmpty` and `length` come from `impl Foldable List` in core.mdk.

export head : List a -> Option a
head [] = None
head (x::_) = Some x

export tail : List a -> Option (List a)
tail [] = None
tail (_::xs) = Some xs

{- | Split off the first element — `head` and `tail` in one match, which is
   what you want when destructuring a list you cannot pattern-match on
   directly.  `None` exactly when the list is empty.

   > uncons [1, 2, 3]
   Some (1, [2, 3])
   > uncons [1]
   Some (1, [])
   > uncons ([] : List Int)
   None -}
export uncons : List a -> Option (a, List a)
uncons [] = None
uncons (x::xs) = Some (x, xs)

export last : List a -> Option a
last [] = None
last [x] = Some x
last (x::xs) = last xs

export init : List a -> Option (List a)
init [] = None
init (x::[]) = Some []
init (x::xs) = map (x :: _) (init xs)

export get : Int -> List a -> Option a
get _ [] = None
get 0 (x::_) = Some x
get i (_::xs) = get (i - 1) xs

-- Zipping

{- | Pair up elements of two lists positionally.  The result is as long as
   the *shorter* input; trailing elements of the longer one are dropped.

   > zip [1, 2, 3] [10, 20]
   [(1, 10), (2, 20)]
   > zip [] [1, 2]
   [] -}
export zip : List a -> List b -> List (a, b)
zip [] _ = []
zip _ [] = []
zip (x::xs) (y::ys) = (x, y) :: zip xs ys

{- | Like `zip`, but for three lists, producing triples.  Stops at the
   shortest input.

   > zip3 [1, 2] [3, 4] [5, 6]
   [(1, 3, 5), (2, 4, 6)]
   > zip3 [1, 2, 3] [4, 5] [6]
   [(1, 4, 6)] -}
export zip3 : List a -> List b -> List c -> List (a, b, c)
zip3 [] _ _ = []
zip3 _ [] _ = []
zip3 _ _ [] = []
zip3 (x::xs) (y::ys) (z::zs) = (x, y, z) :: zip3 xs ys zs

{- | Combine two lists element-wise with `f`, stopping at the shorter.
   `zip` is the special case `zipWith (x y => (x, y))`.

   > zipWith (x y => x + y) [1, 2, 3] [10, 20, 30]
   [11, 22, 33]
   > zipWith (x y => x * y) [1, 2, 3, 4] [10, 20]
   [10, 40] -}
export zipWith : (a -> b -> <e> c) -> List a -> List b -> <e> List c
zipWith _ [] _ = []
zipWith _ _ [] = []
zipWith f (x::xs) (y::ys) = f x y :: zipWith f xs ys

{- | Like `zip3`, but for four lists, producing 4-tuples.  Stops at the
   shortest input.

   > zip4 [1, 2] [3, 4] [5, 6] [7, 8]
   [(1, 3, 5, 7), (2, 4, 6, 8)]
   > zip4 [1, 2] [3] [5, 6] [7, 8]
   [(1, 3, 5, 7)] -}
export zip4 : List a -> List b -> List c -> List d -> List (a, b, c, d)
zip4 [] _ _ _ = []
zip4 _ [] _ _ = []
zip4 _ _ [] _ = []
zip4 _ _ _ [] = []
zip4 (w::ws) (x::xs) (y::ys) (z::zs) = (w, x, y, z) :: zip4 ws xs ys zs

{- | Like `zipWith`, but for three lists.  `zip3` is the special case
   `zipWith3 (x y z => (x, y, z))`.

   > zipWith3 (x y z => x + y + z) [1, 2] [10, 20] [100, 200]
   [111, 222]
   > zipWith3 (x y z => x + y + z) [1, 2, 3] [10, 20] [100]
   [111] -}
export zipWith3 : (a -> b -> c -> <e> d) -> List a -> List b -> List c -> <e> List d
zipWith3 _ [] _ _ = []
zipWith3 _ _ [] _ = []
zipWith3 _ _ _ [] = []
zipWith3 f (x::xs) (y::ys) (z::zs) = f x y z :: zipWith3 f xs ys zs

{- | Split a list of pairs into a pair of lists — the inverse of `zip`.

   > unzip [(1, 2), (3, 4)]
   ([1, 3], [2, 4])
   > unzip []
   ([], []) -}
export unzip : List (a, b) -> (List a, List b)
unzip [] = ([], [])
unzip ((x, y)::xys) = let (xs, ys) = unzip xys in (x::xs, y::ys)

{- | Split a list of triples into three lists — the inverse of `zip3`.

   > unzip3 [(1, 2, 3), (4, 5, 6)]
   ([1, 4], [2, 5], [3, 6])
   > unzip3 ([] : List (Int, Int, Int))
   ([], [], []) -}
export unzip3 : List (a, b, c) -> (List a, List b, List c)
unzip3 [] = ([], [], [])
unzip3 ((x, y, z)::rest) =
  let (xs, ys, zs) = unzip3 rest in (x::xs, y::ys, z::zs)

-- Effectful traversal lives in `core.mdk` as the `Traversable` interface:
-- `traverse`/`sequence` are now interface methods (List instance in core), so
-- they dispatch over any `Traversable`, not just `List`.

-- ── Properties (executed by `medaka test`) ──────────────────────────────────

-- Ascending check used by the sort properties below.
isSorted : Ord a => List a -> Bool
isSorted [] = True
isSorted [_] = True
isSorted (x::y::rest) = lte x y && isSorted (y::rest)

prop "reverse is an involution" (xs : List Int) = eq (reverse (reverse xs)) xs

prop "take n ++ drop n recovers the list" (n : Int) (xs : List Int) =
  eq (take n xs ++ drop n xs) xs

prop "splitAt agrees with take/drop" (n : Int) (xs : List Int) =
  let (a, b) = splitAt n xs
  eq a (take n xs) && eq b (drop n xs)

prop "span ++ recovers the list" (xs : List Int) =
  let (a, b) = span (x => x < 5) xs
  eq (a ++ b) xs

prop "sort is ascending and length-preserving" (xs : List Int) =
  let ys = sort xs
  isSorted ys && length ys == length xs

prop "partition splits by the predicate" (xs : List Int) =
  let (yes, no) = partition (x => x > 0) xs
  all (x => x > 0) yes && all (x => x <= 0) no

prop "somes length is at most the input length" (xs : List Int) =
  let os = map (n => if n % 2 == 0 then Some n else None) xs
  length (somes os) <= length os

prop "partitionResults sizes sum to the input length" (xs : List Int) =
  let rs = map (n => if n % 2 == 0 then Ok n else Err n : Result Int Int) xs
  let (es, os) = partitionResults rs
  length es + length os == length rs

prop "oks/errs agree with partitionResults" (xs : List Int) =
  let rs = map (n => if n % 2 == 0 then Ok n else Err n : Result Int Int) xs
  let (es, os) = partitionResults rs
  eq es (errs rs) && eq os (oks rs)

prop "nub removes all duplicates" (xs : List Int) = eq (nub (nub xs)) (nub xs)

prop "concat of group recovers the list" (xs : List Int) =
  eq (flat (group xs)) xs

prop "span prefix all satisfies, and concatenates back" (xs : List Int) =
  let (a, b) = span (x => x < 5) xs
  all (x => x < 5) a && eq (a ++ b) xs

prop "takeWhile ++ dropWhile recovers the list" (xs : List Int) =
  eq (takeWhile (x => x < 5) xs ++ dropWhile (x => x < 5) xs) xs

prop "break equals span of the negated predicate" (xs : List Int) =
  let (a1, b1) = break (x => x > 5) xs
  let (a2, b2) = span (x => not (x > 5)) xs
  eq a1 a2 && eq b1 b2

prop "range length is max 0 (hi - lo)" (lo : Int) (hi : Int) =
  length (range lo hi) == max 0 (hi - lo)
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Foldable" false) (mem "Mappable" false) (mem "Ordering" false) (mem "Option" false) (mem "Result" false))))
(DUse true (UseGroup ("core") ((mem "Filterable" false) (mem "filter" false) (mem "filterMap" false))))
(DTypeSig true "singleton" (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "singleton" ((PVar "a")) (EListLit (EVar "a")))
(DTypeSig true "range" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "range" ((PVar "lo") (PVar "hi")) (ERangeList (EVar "lo") (EVar "hi") false))
(DTypeSig true "rangeStep" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "rangeStep" ((PVar "lo") (PVar "hi") (PVar "step")) (EIf (EBinOp "&&" (EBinOp ">" (EVar "step") (ELit (LInt 0))) (EBinOp "<" (EVar "lo") (EVar "hi"))) (EBinOp "::" (EVar "lo") (EApp (EApp (EApp (EVar "rangeStep") (EBinOp "+" (EVar "lo") (EVar "step"))) (EVar "hi")) (EVar "step"))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "step") (ELit (LInt 0))) (EBinOp ">" (EVar "lo") (EVar "hi"))) (EBinOp "::" (EVar "lo") (EApp (EApp (EApp (EVar "rangeStep") (EBinOp "+" (EVar "lo") (EVar "step"))) (EVar "hi")) (EVar "step"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "replicate" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "replicate" ((PVar "n") (PVar "x")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "replicate") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "x"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "iterate" (TyFun (TyCon "Int") (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "a"))) (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "iterate" ((PVar "n") (PVar "f") (PVar "x")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EApp (EVar "iterate") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "f")) (EApp (EVar "f") (EVar "x")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "unfold" (TyFun (TyFun (TyVar "b") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyTuple (TyVar "a") (TyVar "b"))))) (TyFun (TyVar "b") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "unfold" ((PVar "gen") (PVar "seed")) (EMatch (EApp (EVar "gen") (EVar "seed")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "x") (PVar "next"))) () (EBinOp "::" (EVar "x") (EApp (EApp (EVar "unfold") (EVar "gen")) (EVar "next"))))))
(DTypeSig true "reverse" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "reverse" ((PVar "xs")) (ELetGroup ((lgb "go" (clause ((PList) (PVar "acc")) (EVar "acc")) (clause ((PCons (PVar "y") (PVar "ys")) (PVar "acc")) (EApp (EApp (EVar "go") (EVar "ys")) (EBinOp "::" (EVar "y") (EVar "acc")))))) (EApp (EApp (EVar "go") (EVar "xs")) (EListLit))))
(DTypeSig true "intersperse" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "intersperse" (PWild (PList)) (EListLit))
(DFunDef false "intersperse" (PWild (PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "intersperse" ((PVar "sep") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "sep") (EApp (EApp (EVar "intersperse") (EVar "sep")) (EVar "xs")))))
(DTypeSig true "intercalate" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "intercalate" ((PVar "sep") (PVar "xss")) (EApp (EVar "flat") (EApp (EApp (EVar "intersperse") (EVar "sep")) (EVar "xss"))))
(DTypeSig true "transpose" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "transpose" ((PList)) (EListLit))
(DFunDef false "transpose" ((PCons (PList) (PVar "xss"))) (EApp (EVar "transpose") (EVar "xss")))
(DFunDef false "transpose" ((PCons (PCons (PVar "x") (PVar "xs")) (PVar "xss"))) (EBinOp "::" (EBinOp "::" (EVar "x") (EApp (EApp (EVar "filterMap") (EVar "head")) (EVar "xss"))) (EApp (EVar "transpose") (EBinOp "::" (EVar "xs") (EApp (EApp (EVar "filterMap") (EVar "tail")) (EVar "xss"))))))
(DTypeSig true "subsequences" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "subsequences" ((PList)) (EListLit (EListLit)))
(DFunDef false "subsequences" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "sub")) (EListLit (EVar "sub") (EBinOp "::" (EVar "x") (EVar "sub"))))) (EApp (EVar "subsequences") (EVar "xs"))))
(DTypeSig true "permutations" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "permutations" ((PList)) (EListLit (EListLit)))
(DFunDef false "permutations" ((PVar "xs")) (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "h") (PVar "rest"))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "h") (EVar "_s")))) (EApp (EVar "permutations") (EVar "rest"))))) (EApp (EVar "selections") (EVar "xs"))))
(DTypeSig false "selections" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "selections" ((PList)) (EListLit))
(DFunDef false "selections" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (ETuple (EVar "x") (EVar "xs")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "y") (PVar "ys"))) (ETuple (EVar "y") (EBinOp "::" (EVar "x") (EVar "ys"))))) (EApp (EVar "selections") (EVar "xs")))))
(DTypeSig true "scanLeft" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "b")))))))
(DFunDef false "scanLeft" (PWild (PVar "z") (PList)) (EListLit (EVar "z")))
(DFunDef false "scanLeft" ((PVar "f") (PVar "z") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "z") (EApp (EApp (EApp (EVar "scanLeft") (EVar "f")) (EApp (EApp (EVar "f") (EVar "z")) (EVar "x"))) (EVar "xs"))))
(DTypeSig true "scanRight" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "b")))))))
(DFunDef false "scanRight" (PWild (PVar "z") (PList)) (EListLit (EVar "z")))
(DFunDef false "scanRight" ((PVar "f") (PVar "z") (PCons (PVar "x") (PVar "xs"))) (EMatch (EApp (EApp (EApp (EVar "scanRight") (EVar "f")) (EVar "z")) (EVar "xs")) (arm (PCons (PVar "q") (PVar "qs")) () (EBinOp "::" (EApp (EApp (EVar "f") (EVar "x")) (EVar "q")) (EBinOp "::" (EVar "q") (EVar "qs")))) (arm (PList) () (EListLit (EApp (EApp (EVar "f") (EVar "x")) (EVar "z"))))))
(DTypeSig true "findIndex" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "findIndex" ((PVar "p") (PVar "xs")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EVar "None")) (clause ((PVar "i") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EVar "p") (EVar "x")) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EApp (EVar "go") (ELit (LInt 0))) (EVar "xs"))))
(DTypeSig true "findIndices" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "findIndices" ((PVar "p") (PVar "xs")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "i") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EVar "p") (EVar "x")) (EBinOp "::" (EVar "i") (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EApp (EVar "go") (ELit (LInt 0))) (EVar "xs"))))
(DTypeSig true "elemIndex" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "elemIndex" ((PVar "x") (PVar "xs")) (EApp (EApp (EVar "findIndex") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "x")))) (EVar "xs")))
(DTypeSig true "elemIndices" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "elemIndices" ((PVar "x") (PVar "xs")) (EApp (EApp (EVar "findIndices") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "x")))) (EVar "xs")))
(DTypeSig true "lookup" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "lookup" (PWild (PList)) (EVar "None"))
(DFunDef false "lookup" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookup") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "findMap" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "b")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "b"))))))
(DFunDef false "findMap" (PWild (PList)) (EVar "None"))
(DFunDef false "findMap" ((PVar "f") (PCons (PVar "x") (PVar "rest"))) (EMatch (EApp (EVar "f") (EVar "x")) (arm (PCon "Some" (PVar "y")) () (EApp (EVar "Some") (EVar "y"))) (arm (PCon "None") () (EApp (EApp (EVar "findMap") (EVar "f")) (EVar "rest")))))
(DTypeSig true "reduce" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "a")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "reduce" (PWild (PList)) (EVar "None"))
(DFunDef false "reduce" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (ELetGroup ((lgb "go" (clause ((PVar "acc") (PList)) (EVar "acc")) (clause ((PVar "acc") (PCons (PVar "y") (PVar "rest"))) (EApp (EApp (EVar "go") (EApp (EApp (EVar "f") (EVar "acc")) (EVar "y"))) (EVar "rest"))))) (EApp (EVar "Some") (EApp (EApp (EVar "go") (EVar "x")) (EVar "xs")))))
(DTypeSig true "maximumBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "maximumBy" ((PVar "cmp") (PVar "xs")) (ELetGroup ((lgb "pick" (clause ((PVar "a") (PVar "b")) (EMatch (EApp (EApp (EVar "cmp") (EVar "b")) (EVar "a")) (arm (PCon "Gt") () (EVar "b")) (arm PWild () (EVar "a")))))) (EApp (EApp (EVar "reduce") (EVar "pick")) (EVar "xs"))))
(DTypeSig true "minimumBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "minimumBy" ((PVar "cmp") (PVar "xs")) (ELetGroup ((lgb "pick" (clause ((PVar "a") (PVar "b")) (EMatch (EApp (EApp (EVar "cmp") (EVar "b")) (EVar "a")) (arm (PCon "Lt") () (EVar "b")) (arm PWild () (EVar "a")))))) (EApp (EApp (EVar "reduce") (EVar "pick")) (EVar "xs"))))
(DTypeSig true "mapWithIndex" (TyFun (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "b"))))))
(DFunDef false "mapWithIndex" ((PVar "f") (PVar "xs")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "i") (PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "f") (EVar "i")) (EVar "x")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")))))) (EApp (EApp (EVar "go") (ELit (LInt 0))) (EVar "xs"))))
(DTypeSig true "indexed" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyVar "a")))))
(DFunDef false "indexed" ((PVar "xs")) (EApp (EApp (EVar "mapWithIndex") (ELam ((PVar "i") (PVar "x")) (ETuple (EVar "i") (EVar "x")))) (EVar "xs")))
(DTypeSig true "mapAccumL" (TyFun (TyFun (TyVar "s") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyTuple (TyVar "s") (TyVar "b"))))) (TyFun (TyVar "s") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyTuple (TyVar "s") (TyApp (TyCon "List") (TyVar "b"))))))))
(DFunDef false "mapAccumL" (PWild (PVar "s") (PList)) (ETuple (EVar "s") (EListLit)))
(DFunDef false "mapAccumL" ((PVar "f") (PVar "s") (PCons (PVar "x") (PVar "xs"))) (EBlock (DoLet false false (PTuple (PVar "s2") (PVar "y")) (EApp (EApp (EVar "f") (EVar "s")) (EVar "x"))) (DoLet false false (PTuple (PVar "s3") (PVar "ys")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "f")) (EVar "s2")) (EVar "xs"))) (DoExpr (ETuple (EVar "s3") (EBinOp "::" (EVar "y") (EVar "ys"))))))
(DTypeSig true "mapAccumR" (TyFun (TyFun (TyVar "s") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyTuple (TyVar "s") (TyVar "b"))))) (TyFun (TyVar "s") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyTuple (TyVar "s") (TyApp (TyCon "List") (TyVar "b"))))))))
(DFunDef false "mapAccumR" (PWild (PVar "s") (PList)) (ETuple (EVar "s") (EListLit)))
(DFunDef false "mapAccumR" ((PVar "f") (PVar "s") (PCons (PVar "x") (PVar "xs"))) (EBlock (DoLet false false (PTuple (PVar "s2") (PVar "ys")) (EApp (EApp (EApp (EVar "mapAccumR") (EVar "f")) (EVar "s")) (EVar "xs"))) (DoLet false false (PTuple (PVar "s3") (PVar "y")) (EApp (EApp (EVar "f") (EVar "s2")) (EVar "x"))) (DoExpr (ETuple (EVar "s3") (EBinOp "::" (EVar "y") (EVar "ys"))))))
(DTypeSig true "insertAt" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "insertAt" (PWild (PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "insertAt" ((PVar "i") (PVar "x") (PCons (PVar "y") (PVar "rest"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "insertAt") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "x")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "updateAt" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "updateAt" (PWild PWild (PList)) (EListLit))
(DFunDef false "updateAt" ((PVar "i") (PVar "x") (PCons (PVar "y") (PVar "rest"))) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp "::" (EVar "y") (EVar "rest")) (EIf (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EBinOp "::" (EVar "x") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "updateAt") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "x")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "removeAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "removeAt" (PWild (PList)) (EListLit))
(DFunDef false "removeAt" ((PVar "i") (PCons (PVar "y") (PVar "rest"))) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp "::" (EVar "y") (EVar "rest")) (EIf (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EVar "rest") (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "removeAt") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "take" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "take" (PWild (PList)) (EListLit))
(DFunDef false "take" ((PVar "n") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "take") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "xs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "drop" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "drop" (PWild (PList)) (EListLit))
(DFunDef false "drop" ((PVar "n") (PAs "xs" (PCons PWild (PVar "rest")))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EVar "xs") (EIf (EVar "otherwise") (EApp (EApp (EVar "drop") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "takeWhile" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "takeWhile" (PWild (PList)) (EListLit))
(DFunDef false "takeWhile" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EVar "p") (EVar "x")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeWhile") (EVar "p")) (EVar "xs"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "dropWhile" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "dropWhile" (PWild (PList)) (EListLit))
(DFunDef false "dropWhile" ((PVar "p") (PAs "xs" (PCons (PVar "x") (PVar "rest")))) (EIf (EApp (EVar "p") (EVar "x")) (EApp (EApp (EVar "dropWhile") (EVar "p")) (EVar "rest")) (EIf (EVar "otherwise") (EVar "xs") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "span" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "span" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "span" ((PVar "p") (PAs "xs" (PCons (PVar "x") (PVar "rest")))) (EIf (EApp (EVar "p") (EVar "x")) (ELet false (PTuple (PVar "a") (PVar "b")) (EApp (EApp (EVar "span") (EVar "p")) (EVar "rest")) (ETuple (EBinOp "::" (EVar "x") (EVar "a")) (EVar "b"))) (EIf (EVar "otherwise") (ETuple (EListLit) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "break" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "break" ((PVar "p") (PVar "xs")) (EApp (EApp (EVar "span") (ELam ((PVar "x")) (EApp (EVar "not") (EApp (EVar "p") (EVar "x"))))) (EVar "xs")))
(DTypeSig true "splitAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "splitAt" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "splitAt" ((PVar "n") (PAs "xs" (PCons (PVar "x") (PVar "rest")))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ETuple (EListLit) (EVar "xs")) (EIf (EVar "otherwise") (ELet false (PTuple (PVar "a") (PVar "b")) (EApp (EApp (EVar "splitAt") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest")) (ETuple (EBinOp "::" (EVar "x") (EVar "a")) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "slice" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "slice" ((PVar "lo") (PVar "hi") (PVar "xs")) (EApp (EApp (EVar "drop") (EVar "lo")) (EApp (EApp (EVar "take") (EVar "hi")) (EVar "xs"))))
(DTypeSig true "chunks" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "chunks" (PWild (PList)) (EListLit))
(DFunDef false "chunks" ((PVar "n") (PAs "xs" (PCons PWild PWild))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "take") (EVar "n")) (EVar "xs")) (EApp (EApp (EVar "chunks") (EVar "n")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "xs")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "dropWhileEnd" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "dropWhileEnd" ((PVar "p") (PVar "xs")) (EApp (EVar "reverse") (EApp (EApp (EVar "dropWhile") (EVar "p")) (EApp (EVar "reverse") (EVar "xs")))))
(DTypeSig true "takeWhileEnd" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "takeWhileEnd" ((PVar "p") (PVar "xs")) (EApp (EVar "reverse") (EApp (EApp (EVar "takeWhile") (EVar "p")) (EApp (EVar "reverse") (EVar "xs")))))
(DTypeSig true "split" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "split" ((PList) (PVar "xs")) (EListLit (EVar "xs")))
(DFunDef false "split" ((PVar "sep") (PVar "xs")) (ELetGroup ((lgb "sepLen" (clause () (EApp (EVar "length") (EVar "sep")))) (lgb "go" (clause ((PVar "ys")) (EMatch (EApp (EApp (EVar "findSub") (ELit (LInt 0))) (EVar "ys")) (arm (PCon "None") () (EListLit (EVar "ys"))) (arm (PCon "Some" (PVar "i")) () (EBinOp "::" (EApp (EApp (EVar "take") (EVar "i")) (EVar "ys")) (EApp (EVar "go") (EApp (EApp (EVar "drop") (EBinOp "+" (EVar "i") (EVar "sepLen"))) (EVar "ys")))))))) (lgb "findSub" (clause ((PVar "i") (PVar "ys")) (EIf (EApp (EApp (EVar "startsWith") (EVar "sep")) (EVar "ys")) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EVar "findSubTail") (EVar "i")) (EVar "ys")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))) (lgb "findSubTail" (clause (PWild (PList)) (EVar "None")) (clause ((PVar "i") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "findSub") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))) (EApp (EVar "go") (EVar "xs"))))
(DTypeSig true "startsWith" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "startsWith" ((PList) PWild) (EVar "True"))
(DFunDef false "startsWith" (PWild (PList)) (EVar "False"))
(DFunDef false "startsWith" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "x") (PVar "xs"))) (EBinOp "&&" (EBinOp "==" (EVar "p") (EVar "x")) (EApp (EApp (EVar "startsWith") (EVar "ps")) (EVar "xs"))))
(DTypeSig true "endsWith" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "endsWith" ((PVar "suffix") (PVar "xs")) (EApp (EApp (EVar "startsWith") (EApp (EVar "reverse") (EVar "suffix"))) (EApp (EVar "reverse") (EVar "xs"))))
(DTypeSig true "contains" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "contains" ((PVar "sub") (PList)) (EApp (EApp (EVar "startsWith") (EVar "sub")) (EListLit)))
(DFunDef false "contains" ((PVar "sub") (PAs "xs" (PCons PWild (PVar "rest")))) (EIf (EApp (EApp (EVar "startsWith") (EVar "sub")) (EVar "xs")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "contains") (EVar "sub")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "sortBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sortBy" (PWild (PList)) (EListLit))
(DFunDef false "sortBy" (PWild (PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "sortBy" ((PVar "cmp") (PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "l") (PVar "r")) (EApp (EApp (EVar "splitAt") (EBinOp "/" (EApp (EVar "length") (EVar "xs")) (ELit (LInt 2)))) (EVar "xs"))) (DoExpr (EApp (EApp (EApp (EVar "merge") (EVar "cmp")) (EApp (EApp (EVar "sortBy") (EVar "cmp")) (EVar "l"))) (EApp (EApp (EVar "sortBy") (EVar "cmp")) (EVar "r"))))))
(DTypeSig false "merge" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "merge" (PWild (PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "merge" (PWild (PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "merge" ((PVar "cmp") (PAs "xs" (PCons (PVar "x") (PVar "xs'"))) (PAs "ys" (PCons (PVar "y") (PVar "ys'")))) (EMatch (EApp (EApp (EVar "cmp") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "merge") (EVar "cmp")) (EVar "xs")) (EVar "ys'")))) (arm PWild () (EBinOp "::" (EVar "x") (EApp (EApp (EApp (EVar "merge") (EVar "cmp")) (EVar "xs'")) (EVar "ys"))))))
(DTypeSig true "sort" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "sort" ((PVar "xs")) (EApp (EApp (EVar "sortBy") (EVar "compare")) (EVar "xs")))
(DTypeSig true "sortOn" (TyConstrained ((cstr "Ord" (TyVar "b"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "sortOn" ((PVar "key") (PVar "xs")) (EBlock (DoLet false false (PVar "decorated") (EApp (EApp (EVar "map") (ELam ((PVar "x")) (ETuple (EApp (EVar "key") (EVar "x")) (EVar "x")))) (EVar "xs"))) (DoExpr (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "sortBy") (ELam ((PTuple (PVar "k1") PWild) (PTuple (PVar "k2") PWild)) (EApp (EApp (EVar "compare") (EVar "k1")) (EVar "k2")))) (EVar "decorated"))))))
(DTypeSig true "nubBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "nubBy" ((PVar "same") (PVar "xs")) (ELetGroup ((lgb "go" (clause ((PList) PWild) (EListLit)) (clause ((PCons (PVar "x") (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "s")) (EApp (EApp (EVar "same") (EVar "x")) (EVar "s")))) (EVar "seen")) (EApp (EApp (EVar "go") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "go") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EApp (EVar "go") (EVar "xs")) (EListLit))))
(DTypeSig true "nub" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "nub" ((PVar "xs")) (EApp (EApp (EVar "nubBy") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "==" (EVar "_a") (EVar "_b")))) (EVar "xs")))
(DTypeSig true "deleteBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool")))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "deleteBy" (PWild PWild (PList)) (EListLit))
(DFunDef false "deleteBy" ((PVar "same") (PVar "x") (PCons (PVar "y") (PVar "rest"))) (EIf (EApp (EApp (EVar "same") (EVar "x")) (EVar "y")) (EVar "rest") (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "deleteBy") (EVar "same")) (EVar "x")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "delete" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "delete" ((PVar "x") (PVar "xs")) (EApp (EApp (EApp (EVar "deleteBy") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "==" (EVar "_a") (EVar "_b")))) (EVar "x")) (EVar "xs")))
(DTypeSig true "groupBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "groupBy" (PWild (PList)) (EListLit))
(DFunDef false "groupBy" ((PVar "same") (PCons (PVar "x") (PVar "xs"))) (EBlock (DoLet false false (PTuple (PVar "grp") (PVar "rest")) (EApp (EApp (EVar "span") (ELam ((PVar "y")) (EApp (EApp (EVar "same") (EVar "x")) (EVar "y")))) (EVar "xs"))) (DoExpr (EBinOp "::" (EBinOp "::" (EVar "x") (EVar "grp")) (EApp (EApp (EVar "groupBy") (EVar "same")) (EVar "rest"))))))
(DTypeSig true "group" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "group" ((PVar "xs")) (EApp (EApp (EVar "groupBy") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "==" (EVar "_a") (EVar "_b")))) (EVar "xs")))
(DTypeSig true "partition" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "partition" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "partition" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EBlock (DoLet false false (PTuple (PVar "yes") (PVar "no")) (EApp (EApp (EVar "partition") (EVar "p")) (EVar "xs"))) (DoExpr (EIf (EApp (EVar "p") (EVar "x")) (ETuple (EBinOp "::" (EVar "x") (EVar "yes")) (EVar "no")) (ETuple (EVar "yes") (EBinOp "::" (EVar "x") (EVar "no")))))))
(DTypeSig true "somes" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "somes" ((PList)) (EListLit))
(DFunDef false "somes" ((PCons (PCon "Some" (PVar "x")) (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "somes") (EVar "rest"))))
(DFunDef false "somes" ((PCons (PCon "None") (PVar "rest"))) (EApp (EVar "somes") (EVar "rest")))
(DTypeSig true "oks" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "oks" ((PList)) (EListLit))
(DFunDef false "oks" ((PCons (PCon "Ok" (PVar "x")) (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "oks") (EVar "rest"))))
(DFunDef false "oks" ((PCons (PCon "Err" PWild) (PVar "rest"))) (EApp (EVar "oks") (EVar "rest")))
(DTypeSig true "errs" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) (TyApp (TyCon "List") (TyVar "e"))))
(DFunDef false "errs" ((PList)) (EListLit))
(DFunDef false "errs" ((PCons (PCon "Err" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EVar "e") (EApp (EVar "errs") (EVar "rest"))))
(DFunDef false "errs" ((PCons (PCon "Ok" PWild) (PVar "rest"))) (EApp (EVar "errs") (EVar "rest")))
(DTypeSig true "partitionResults" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) (TyTuple (TyApp (TyCon "List") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "partitionResults" ((PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "partitionResults" ((PCons (PCon "Ok" (PVar "x")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "es") (PVar "xs")) (EApp (EVar "partitionResults") (EVar "rest"))) (DoExpr (ETuple (EVar "es") (EBinOp "::" (EVar "x") (EVar "xs"))))))
(DFunDef false "partitionResults" ((PCons (PCon "Err" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "es") (PVar "xs")) (EApp (EVar "partitionResults") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "e") (EVar "es")) (EVar "xs")))))
(DTypeSig true "tally" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyCon "Int"))))))
(DFunDef false "tally" ((PVar "xs")) (ELetGroup ((lgb "go" (clause ((PList) (PVar "acc")) (EVar "acc")) (clause ((PCons (PVar "x") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "go") (EVar "rest")) (EApp (EApp (EVar "bump") (EVar "x")) (EVar "acc"))))) (lgb "bump" (clause ((PVar "x") (PList)) (EListLit (ETuple (EVar "x") (ELit (LInt 1))))) (clause ((PVar "x") (PCons (PTuple (PVar "k") (PVar "c")) (PVar "kvs"))) (EIf (EBinOp "==" (EVar "k") (EVar "x")) (EBinOp "::" (ETuple (EVar "k") (EBinOp "+" (EVar "c") (ELit (LInt 1)))) (EVar "kvs")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "c")) (EApp (EApp (EVar "bump") (EVar "x")) (EVar "kvs"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EApp (EVar "go") (EVar "xs")) (EListLit))))
(DTypeSig true "head" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "head" ((PList)) (EVar "None"))
(DFunDef false "head" ((PCons (PVar "x") PWild)) (EApp (EVar "Some") (EVar "x")))
(DTypeSig true "tail" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "tail" ((PList)) (EVar "None"))
(DFunDef false "tail" ((PCons PWild (PVar "xs"))) (EApp (EVar "Some") (EVar "xs")))
(DTypeSig true "uncons" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyTuple (TyVar "a") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "uncons" ((PList)) (EVar "None"))
(DFunDef false "uncons" ((PCons (PVar "x") (PVar "xs"))) (EApp (EVar "Some") (ETuple (EVar "x") (EVar "xs"))))
(DTypeSig true "last" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "last" ((PList)) (EVar "None"))
(DFunDef false "last" ((PList (PVar "x"))) (EApp (EVar "Some") (EVar "x")))
(DFunDef false "last" ((PCons (PVar "x") (PVar "xs"))) (EApp (EVar "last") (EVar "xs")))
(DTypeSig true "init" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "init" ((PList)) (EVar "None"))
(DFunDef false "init" ((PCons (PVar "x") (PList))) (EApp (EVar "Some") (EListLit)))
(DFunDef false "init" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "x") (EVar "_s")))) (EApp (EVar "init") (EVar "xs"))))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "get" (PWild (PList)) (EVar "None"))
(DFunDef false "get" ((PLit (LInt 0)) (PCons (PVar "x") PWild)) (EApp (EVar "Some") (EVar "x")))
(DFunDef false "get" ((PVar "i") (PCons PWild (PVar "xs"))) (EApp (EApp (EVar "get") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs")))
(DTypeSig true "zip" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "zip" ((PList) PWild) (EListLit))
(DFunDef false "zip" (PWild (PList)) (EListLit))
(DFunDef false "zip" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "::" (ETuple (EVar "x") (EVar "y")) (EApp (EApp (EVar "zip") (EVar "xs")) (EVar "ys"))))
(DTypeSig true "zip3" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyFun (TyApp (TyCon "List") (TyVar "c")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")))))))
(DFunDef false "zip3" ((PList) PWild PWild) (EListLit))
(DFunDef false "zip3" (PWild (PList) PWild) (EListLit))
(DFunDef false "zip3" (PWild PWild (PList)) (EListLit))
(DFunDef false "zip3" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys")) (PCons (PVar "z") (PVar "zs"))) (EBinOp "::" (ETuple (EVar "x") (EVar "y") (EVar "z")) (EApp (EApp (EApp (EVar "zip3") (EVar "xs")) (EVar "ys")) (EVar "zs"))))
(DTypeSig true "zipWith" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "c")))))))
(DFunDef false "zipWith" (PWild (PList) PWild) (EListLit))
(DFunDef false "zipWith" (PWild PWild (PList)) (EListLit))
(DFunDef false "zipWith" ((PVar "f") (PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "::" (EApp (EApp (EVar "f") (EVar "x")) (EVar "y")) (EApp (EApp (EApp (EVar "zipWith") (EVar "f")) (EVar "xs")) (EVar "ys"))))
(DTypeSig true "zip4" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyFun (TyApp (TyCon "List") (TyVar "c")) (TyFun (TyApp (TyCon "List") (TyVar "d")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d"))))))))
(DFunDef false "zip4" ((PList) PWild PWild PWild) (EListLit))
(DFunDef false "zip4" (PWild (PList) PWild PWild) (EListLit))
(DFunDef false "zip4" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "zip4" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "zip4" ((PCons (PVar "w") (PVar "ws")) (PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys")) (PCons (PVar "z") (PVar "zs"))) (EBinOp "::" (ETuple (EVar "w") (EVar "x") (EVar "y") (EVar "z")) (EApp (EApp (EApp (EApp (EVar "zip4") (EVar "ws")) (EVar "xs")) (EVar "ys")) (EVar "zs"))))
(DTypeSig true "zipWith3" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyFun (TyVar "c") (TyEffect () (Some "e") (TyVar "d"))))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyFun (TyApp (TyCon "List") (TyVar "c")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "d"))))))))
(DFunDef false "zipWith3" (PWild (PList) PWild PWild) (EListLit))
(DFunDef false "zipWith3" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "zipWith3" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "zipWith3" ((PVar "f") (PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys")) (PCons (PVar "z") (PVar "zs"))) (EBinOp "::" (EApp (EApp (EApp (EVar "f") (EVar "x")) (EVar "y")) (EVar "z")) (EApp (EApp (EApp (EApp (EVar "zipWith3") (EVar "f")) (EVar "xs")) (EVar "ys")) (EVar "zs"))))
(DTypeSig true "unzip" (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b"))) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "unzip" ((PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "unzip" ((PCons (PTuple (PVar "x") (PVar "y")) (PVar "xys"))) (ELet false (PTuple (PVar "xs") (PVar "ys")) (EApp (EVar "unzip") (EVar "xys")) (ETuple (EBinOp "::" (EVar "x") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))))
(DTypeSig true "unzip3" (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b") (TyVar "c"))) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")) (TyApp (TyCon "List") (TyVar "c")))))
(DFunDef false "unzip3" ((PList)) (ETuple (EListLit) (EListLit) (EListLit)))
(DFunDef false "unzip3" ((PCons (PTuple (PVar "x") (PVar "y") (PVar "z")) (PVar "rest"))) (ELet false (PTuple (PVar "xs") (PVar "ys") (PVar "zs")) (EApp (EVar "unzip3") (EVar "rest")) (ETuple (EBinOp "::" (EVar "x") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")) (EBinOp "::" (EVar "z") (EVar "zs")))))
(DTypeSig false "isSorted" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "isSorted" ((PList)) (EVar "True"))
(DFunDef false "isSorted" ((PList PWild)) (EVar "True"))
(DFunDef false "isSorted" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EBinOp "&&" (EApp (EApp (EVar "lte") (EVar "x")) (EVar "y")) (EApp (EVar "isSorted") (EBinOp "::" (EVar "y") (EVar "rest")))))
(DProp false "reverse is an involution" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "eq") (EApp (EVar "reverse") (EApp (EVar "reverse") (EVar "xs")))) (EVar "xs")))
(DProp false "take n ++ drop n recovers the list" ((pp "n" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "eq") (EBinOp "++" (EApp (EApp (EVar "take") (EVar "n")) (EVar "xs")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "xs")))) (EVar "xs")))
(DProp false "splitAt agrees with take/drop" ((pp "n" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EApp (EVar "splitAt") (EVar "n")) (EVar "xs"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "a")) (EApp (EApp (EVar "take") (EVar "n")) (EVar "xs"))) (EApp (EApp (EVar "eq") (EVar "b")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "xs")))))))
(DProp false "span ++ recovers the list" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EApp (EVar "span") (ELam ((PVar "x")) (EBinOp "<" (EVar "x") (ELit (LInt 5))))) (EVar "xs"))) (DoExpr (EApp (EApp (EVar "eq") (EBinOp "++" (EVar "a") (EVar "b"))) (EVar "xs")))))
(DProp false "sort is ascending and length-preserving" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "ys") (EApp (EVar "sort") (EVar "xs"))) (DoExpr (EBinOp "&&" (EApp (EVar "isSorted") (EVar "ys")) (EBinOp "==" (EApp (EVar "length") (EVar "ys")) (EApp (EVar "length") (EVar "xs")))))))
(DProp false "partition splits by the predicate" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "yes") (PVar "no")) (EApp (EApp (EVar "partition") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 0))))) (EVar "xs"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "all") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 0))))) (EVar "yes")) (EApp (EApp (EVar "all") (ELam ((PVar "x")) (EBinOp "<=" (EVar "x") (ELit (LInt 0))))) (EVar "no"))))))
(DProp false "somes length is at most the input length" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "os") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 0))) (EApp (EVar "Some") (EVar "n")) (EVar "None")))) (EVar "xs"))) (DoExpr (EBinOp "<=" (EApp (EVar "length") (EApp (EVar "somes") (EVar "os"))) (EApp (EVar "length") (EVar "os"))))))
(DProp false "partitionResults sizes sum to the input length" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "rs") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 0))) (EApp (EVar "Ok") (EVar "n")) (EAnnot (EApp (EVar "Err") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int")))))) (EVar "xs"))) (DoLet false false (PTuple (PVar "es") (PVar "os")) (EApp (EVar "partitionResults") (EVar "rs"))) (DoExpr (EBinOp "==" (EBinOp "+" (EApp (EVar "length") (EVar "es")) (EApp (EVar "length") (EVar "os"))) (EApp (EVar "length") (EVar "rs"))))))
(DProp false "oks/errs agree with partitionResults" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "rs") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 0))) (EApp (EVar "Ok") (EVar "n")) (EAnnot (EApp (EVar "Err") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int")))))) (EVar "xs"))) (DoLet false false (PTuple (PVar "es") (PVar "os")) (EApp (EVar "partitionResults") (EVar "rs"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "es")) (EApp (EVar "errs") (EVar "rs"))) (EApp (EApp (EVar "eq") (EVar "os")) (EApp (EVar "oks") (EVar "rs")))))))
(DProp false "nub removes all duplicates" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "eq") (EApp (EVar "nub") (EApp (EVar "nub") (EVar "xs")))) (EApp (EVar "nub") (EVar "xs"))))
(DProp false "concat of group recovers the list" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "eq") (EApp (EVar "flat") (EApp (EVar "group") (EVar "xs")))) (EVar "xs")))
(DProp false "span prefix all satisfies, and concatenates back" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EApp (EVar "span") (ELam ((PVar "x")) (EBinOp "<" (EVar "x") (ELit (LInt 5))))) (EVar "xs"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "all") (ELam ((PVar "x")) (EBinOp "<" (EVar "x") (ELit (LInt 5))))) (EVar "a")) (EApp (EApp (EVar "eq") (EBinOp "++" (EVar "a") (EVar "b"))) (EVar "xs"))))))
(DProp false "takeWhile ++ dropWhile recovers the list" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "eq") (EBinOp "++" (EApp (EApp (EVar "takeWhile") (ELam ((PVar "x")) (EBinOp "<" (EVar "x") (ELit (LInt 5))))) (EVar "xs")) (EApp (EApp (EVar "dropWhile") (ELam ((PVar "x")) (EBinOp "<" (EVar "x") (ELit (LInt 5))))) (EVar "xs")))) (EVar "xs")))
(DProp false "break equals span of the negated predicate" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "a1") (PVar "b1")) (EApp (EApp (EVar "break") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 5))))) (EVar "xs"))) (DoLet false false (PTuple (PVar "a2") (PVar "b2")) (EApp (EApp (EVar "span") (ELam ((PVar "x")) (EApp (EVar "not") (EBinOp ">" (EVar "x") (ELit (LInt 5)))))) (EVar "xs"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "eq") (EVar "b1")) (EVar "b2"))))))
(DProp false "range length is max 0 (hi - lo)" ((pp "lo" (TyCon "Int")) (pp "hi" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "length") (EApp (EApp (EVar "range") (EVar "lo")) (EVar "hi"))) (EApp (EApp (EVar "max") (ELit (LInt 0))) (EBinOp "-" (EVar "hi") (EVar "lo")))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Foldable" false) (mem "Mappable" false) (mem "Ordering" false) (mem "Option" false) (mem "Result" false))))
(DUse true (UseGroup ("core") ((mem "Filterable" false) (mem "filter" false) (mem "filterMap" false))))
(DTypeSig true "singleton" (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "singleton" ((PVar "a")) (EListLit (EVar "a")))
(DTypeSig true "range" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "range" ((PVar "lo") (PVar "hi")) (ERangeList (EVar "lo") (EVar "hi") false))
(DTypeSig true "rangeStep" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "rangeStep" ((PVar "lo") (PVar "hi") (PVar "step")) (EIf (EBinOp "&&" (EBinOp ">" (EVar "step") (ELit (LInt 0))) (EBinOp "<" (EVar "lo") (EVar "hi"))) (EBinOp "::" (EVar "lo") (EApp (EApp (EApp (EVar "rangeStep") (EBinOp "+" (EVar "lo") (EVar "step"))) (EVar "hi")) (EVar "step"))) (EIf (EBinOp "&&" (EBinOp "<" (EVar "step") (ELit (LInt 0))) (EBinOp ">" (EVar "lo") (EVar "hi"))) (EBinOp "::" (EVar "lo") (EApp (EApp (EApp (EVar "rangeStep") (EBinOp "+" (EVar "lo") (EVar "step"))) (EVar "hi")) (EVar "step"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "replicate" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "replicate" ((PVar "n") (PVar "x")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "replicate") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "x"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "iterate" (TyFun (TyCon "Int") (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "a"))) (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "iterate" ((PVar "n") (PVar "f") (PVar "x")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EApp (EVar "iterate") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "f")) (EApp (EVar "f") (EVar "x")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "unfold" (TyFun (TyFun (TyVar "b") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyTuple (TyVar "a") (TyVar "b"))))) (TyFun (TyVar "b") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "unfold" ((PVar "gen") (PVar "seed")) (EMatch (EApp (EVar "gen") (EVar "seed")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "x") (PVar "next"))) () (EBinOp "::" (EVar "x") (EApp (EApp (EVar "unfold") (EVar "gen")) (EVar "next"))))))
(DTypeSig true "reverse" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "reverse" ((PVar "xs")) (ELetGroup ((lgb "go" (clause ((PList) (PVar "acc")) (EVar "acc")) (clause ((PCons (PVar "y") (PVar "ys")) (PVar "acc")) (EApp (EApp (EVar "go") (EVar "ys")) (EBinOp "::" (EVar "y") (EVar "acc")))))) (EApp (EApp (EVar "go") (EVar "xs")) (EListLit))))
(DTypeSig true "intersperse" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "intersperse" (PWild (PList)) (EListLit))
(DFunDef false "intersperse" (PWild (PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "intersperse" ((PVar "sep") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "sep") (EApp (EApp (EVar "intersperse") (EVar "sep")) (EVar "xs")))))
(DTypeSig true "intercalate" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "intercalate" ((PVar "sep") (PVar "xss")) (EApp (EDictApp "flat") (EApp (EApp (EVar "intersperse") (EVar "sep")) (EVar "xss"))))
(DTypeSig true "transpose" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "transpose" ((PList)) (EListLit))
(DFunDef false "transpose" ((PCons (PList) (PVar "xss"))) (EApp (EVar "transpose") (EVar "xss")))
(DFunDef false "transpose" ((PCons (PCons (PVar "x") (PVar "xs")) (PVar "xss"))) (EBinOp "::" (EBinOp "::" (EVar "x") (EApp (EApp (EMethodRef "filterMap") (EVar "head")) (EVar "xss"))) (EApp (EVar "transpose") (EBinOp "::" (EVar "xs") (EApp (EApp (EMethodRef "filterMap") (EVar "tail")) (EVar "xss"))))))
(DTypeSig true "subsequences" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "subsequences" ((PList)) (EListLit (EListLit)))
(DFunDef false "subsequences" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "sub")) (EListLit (EMethodRef "sub") (EBinOp "::" (EVar "x") (EMethodRef "sub"))))) (EApp (EVar "subsequences") (EVar "xs"))))
(DTypeSig true "permutations" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "permutations" ((PList)) (EListLit (EListLit)))
(DFunDef false "permutations" ((PVar "xs")) (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "h") (PVar "rest"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "h") (EVar "_s")))) (EApp (EVar "permutations") (EVar "rest"))))) (EApp (EVar "selections") (EVar "xs"))))
(DTypeSig false "selections" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "selections" ((PList)) (EListLit))
(DFunDef false "selections" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (ETuple (EVar "x") (EVar "xs")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "y") (PVar "ys"))) (ETuple (EVar "y") (EBinOp "::" (EVar "x") (EVar "ys"))))) (EApp (EVar "selections") (EVar "xs")))))
(DTypeSig true "scanLeft" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "b")))))))
(DFunDef false "scanLeft" (PWild (PVar "z") (PList)) (EListLit (EVar "z")))
(DFunDef false "scanLeft" ((PVar "f") (PVar "z") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "z") (EApp (EApp (EApp (EVar "scanLeft") (EVar "f")) (EApp (EApp (EVar "f") (EVar "z")) (EVar "x"))) (EVar "xs"))))
(DTypeSig true "scanRight" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "b")))))))
(DFunDef false "scanRight" (PWild (PVar "z") (PList)) (EListLit (EVar "z")))
(DFunDef false "scanRight" ((PVar "f") (PVar "z") (PCons (PVar "x") (PVar "xs"))) (EMatch (EApp (EApp (EApp (EVar "scanRight") (EVar "f")) (EVar "z")) (EVar "xs")) (arm (PCons (PVar "q") (PVar "qs")) () (EBinOp "::" (EApp (EApp (EVar "f") (EVar "x")) (EVar "q")) (EBinOp "::" (EVar "q") (EVar "qs")))) (arm (PList) () (EListLit (EApp (EApp (EVar "f") (EVar "x")) (EVar "z"))))))
(DTypeSig true "findIndex" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "findIndex" ((PVar "p") (PVar "xs")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EVar "None")) (clause ((PVar "i") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EVar "p") (EVar "x")) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EApp (EVar "go") (ELit (LInt 0))) (EVar "xs"))))
(DTypeSig true "findIndices" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "findIndices" ((PVar "p") (PVar "xs")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "i") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EVar "p") (EVar "x")) (EBinOp "::" (EVar "i") (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EApp (EVar "go") (ELit (LInt 0))) (EVar "xs"))))
(DTypeSig true "elemIndex" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "elemIndex" ((PVar "x") (PVar "xs")) (EApp (EApp (EVar "findIndex") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "x")))) (EVar "xs")))
(DTypeSig true "elemIndices" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "elemIndices" ((PVar "x") (PVar "xs")) (EApp (EApp (EVar "findIndices") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "x")))) (EVar "xs")))
(DTypeSig true "lookup" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "lookup" (PWild (PList)) (EVar "None"))
(DFunDef false "lookup" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EDictApp "lookup") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "findMap" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "b")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "b"))))))
(DFunDef false "findMap" (PWild (PList)) (EVar "None"))
(DFunDef false "findMap" ((PVar "f") (PCons (PVar "x") (PVar "rest"))) (EMatch (EApp (EVar "f") (EVar "x")) (arm (PCon "Some" (PVar "y")) () (EApp (EVar "Some") (EVar "y"))) (arm (PCon "None") () (EApp (EApp (EVar "findMap") (EVar "f")) (EVar "rest")))))
(DTypeSig true "reduce" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "a")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "reduce" (PWild (PList)) (EVar "None"))
(DFunDef false "reduce" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (ELetGroup ((lgb "go" (clause ((PVar "acc") (PList)) (EVar "acc")) (clause ((PVar "acc") (PCons (PVar "y") (PVar "rest"))) (EApp (EApp (EVar "go") (EApp (EApp (EVar "f") (EVar "acc")) (EVar "y"))) (EVar "rest"))))) (EApp (EVar "Some") (EApp (EApp (EVar "go") (EVar "x")) (EVar "xs")))))
(DTypeSig true "maximumBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "maximumBy" ((PVar "cmp") (PVar "xs")) (ELetGroup ((lgb "pick" (clause ((PVar "a") (PVar "b")) (EMatch (EApp (EApp (EVar "cmp") (EVar "b")) (EVar "a")) (arm (PCon "Gt") () (EVar "b")) (arm PWild () (EVar "a")))))) (EApp (EApp (EVar "reduce") (EVar "pick")) (EVar "xs"))))
(DTypeSig true "minimumBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "minimumBy" ((PVar "cmp") (PVar "xs")) (ELetGroup ((lgb "pick" (clause ((PVar "a") (PVar "b")) (EMatch (EApp (EApp (EVar "cmp") (EVar "b")) (EVar "a")) (arm (PCon "Lt") () (EVar "b")) (arm PWild () (EVar "a")))))) (EApp (EApp (EVar "reduce") (EVar "pick")) (EVar "xs"))))
(DTypeSig true "mapWithIndex" (TyFun (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "b"))))))
(DFunDef false "mapWithIndex" ((PVar "f") (PVar "xs")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "i") (PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "f") (EVar "i")) (EVar "x")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")))))) (EApp (EApp (EVar "go") (ELit (LInt 0))) (EVar "xs"))))
(DTypeSig true "indexed" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyVar "a")))))
(DFunDef false "indexed" ((PVar "xs")) (EApp (EApp (EVar "mapWithIndex") (ELam ((PVar "i") (PVar "x")) (ETuple (EVar "i") (EVar "x")))) (EVar "xs")))
(DTypeSig true "mapAccumL" (TyFun (TyFun (TyVar "s") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyTuple (TyVar "s") (TyVar "b"))))) (TyFun (TyVar "s") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyTuple (TyVar "s") (TyApp (TyCon "List") (TyVar "b"))))))))
(DFunDef false "mapAccumL" (PWild (PVar "s") (PList)) (ETuple (EVar "s") (EListLit)))
(DFunDef false "mapAccumL" ((PVar "f") (PVar "s") (PCons (PVar "x") (PVar "xs"))) (EBlock (DoLet false false (PTuple (PVar "s2") (PVar "y")) (EApp (EApp (EVar "f") (EVar "s")) (EVar "x"))) (DoLet false false (PTuple (PVar "s3") (PVar "ys")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "f")) (EVar "s2")) (EVar "xs"))) (DoExpr (ETuple (EVar "s3") (EBinOp "::" (EVar "y") (EVar "ys"))))))
(DTypeSig true "mapAccumR" (TyFun (TyFun (TyVar "s") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyTuple (TyVar "s") (TyVar "b"))))) (TyFun (TyVar "s") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyTuple (TyVar "s") (TyApp (TyCon "List") (TyVar "b"))))))))
(DFunDef false "mapAccumR" (PWild (PVar "s") (PList)) (ETuple (EVar "s") (EListLit)))
(DFunDef false "mapAccumR" ((PVar "f") (PVar "s") (PCons (PVar "x") (PVar "xs"))) (EBlock (DoLet false false (PTuple (PVar "s2") (PVar "ys")) (EApp (EApp (EApp (EVar "mapAccumR") (EVar "f")) (EVar "s")) (EVar "xs"))) (DoLet false false (PTuple (PVar "s3") (PVar "y")) (EApp (EApp (EVar "f") (EVar "s2")) (EVar "x"))) (DoExpr (ETuple (EVar "s3") (EBinOp "::" (EVar "y") (EVar "ys"))))))
(DTypeSig true "insertAt" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "insertAt" (PWild (PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "insertAt" ((PVar "i") (PVar "x") (PCons (PVar "y") (PVar "rest"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "insertAt") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "x")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "updateAt" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "updateAt" (PWild PWild (PList)) (EListLit))
(DFunDef false "updateAt" ((PVar "i") (PVar "x") (PCons (PVar "y") (PVar "rest"))) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp "::" (EVar "y") (EVar "rest")) (EIf (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EBinOp "::" (EVar "x") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "updateAt") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "x")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "removeAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "removeAt" (PWild (PList)) (EListLit))
(DFunDef false "removeAt" ((PVar "i") (PCons (PVar "y") (PVar "rest"))) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp "::" (EVar "y") (EVar "rest")) (EIf (EBinOp "==" (EVar "i") (ELit (LInt 0))) (EVar "rest") (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "removeAt") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "take" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "take" (PWild (PList)) (EListLit))
(DFunDef false "take" ((PVar "n") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "take") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "xs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "drop" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "drop" (PWild (PList)) (EListLit))
(DFunDef false "drop" ((PVar "n") (PAs "xs" (PCons PWild (PVar "rest")))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EVar "xs") (EIf (EVar "otherwise") (EApp (EApp (EVar "drop") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "takeWhile" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "takeWhile" (PWild (PList)) (EListLit))
(DFunDef false "takeWhile" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EVar "p") (EVar "x")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeWhile") (EVar "p")) (EVar "xs"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "dropWhile" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "dropWhile" (PWild (PList)) (EListLit))
(DFunDef false "dropWhile" ((PVar "p") (PAs "xs" (PCons (PVar "x") (PVar "rest")))) (EIf (EApp (EVar "p") (EVar "x")) (EApp (EApp (EVar "dropWhile") (EVar "p")) (EVar "rest")) (EIf (EVar "otherwise") (EVar "xs") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "span" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "span" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "span" ((PVar "p") (PAs "xs" (PCons (PVar "x") (PVar "rest")))) (EIf (EApp (EVar "p") (EVar "x")) (ELet false (PTuple (PVar "a") (PVar "b")) (EApp (EApp (EVar "span") (EVar "p")) (EVar "rest")) (ETuple (EBinOp "::" (EVar "x") (EVar "a")) (EVar "b"))) (EIf (EVar "otherwise") (ETuple (EListLit) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "break" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "break" ((PVar "p") (PVar "xs")) (EApp (EApp (EVar "span") (ELam ((PVar "x")) (EApp (EVar "not") (EApp (EVar "p") (EVar "x"))))) (EVar "xs")))
(DTypeSig true "splitAt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "splitAt" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "splitAt" ((PVar "n") (PAs "xs" (PCons (PVar "x") (PVar "rest")))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ETuple (EListLit) (EVar "xs")) (EIf (EVar "otherwise") (ELet false (PTuple (PVar "a") (PVar "b")) (EApp (EApp (EVar "splitAt") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest")) (ETuple (EBinOp "::" (EVar "x") (EVar "a")) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "slice" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "slice" ((PVar "lo") (PVar "hi") (PVar "xs")) (EApp (EApp (EVar "drop") (EVar "lo")) (EApp (EApp (EVar "take") (EVar "hi")) (EVar "xs"))))
(DTypeSig true "chunks" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "chunks" (PWild (PList)) (EListLit))
(DFunDef false "chunks" ((PVar "n") (PAs "xs" (PCons PWild PWild))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "take") (EVar "n")) (EVar "xs")) (EApp (EApp (EVar "chunks") (EVar "n")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "xs")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "dropWhileEnd" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "dropWhileEnd" ((PVar "p") (PVar "xs")) (EApp (EVar "reverse") (EApp (EApp (EVar "dropWhile") (EVar "p")) (EApp (EVar "reverse") (EVar "xs")))))
(DTypeSig true "takeWhileEnd" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "takeWhileEnd" ((PVar "p") (PVar "xs")) (EApp (EVar "reverse") (EApp (EApp (EVar "takeWhile") (EVar "p")) (EApp (EVar "reverse") (EVar "xs")))))
(DTypeSig true "split" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "split" ((PList) (PVar "xs")) (EListLit (EVar "xs")))
(DFunDef false "split" ((PVar "sep") (PVar "xs")) (ELetGroup ((lgb "sepLen" (clause () (EApp (EMethodRef "length") (EVar "sep")))) (lgb "go" (clause ((PVar "ys")) (EMatch (EApp (EApp (EVar "findSub") (ELit (LInt 0))) (EVar "ys")) (arm (PCon "None") () (EListLit (EVar "ys"))) (arm (PCon "Some" (PVar "i")) () (EBinOp "::" (EApp (EApp (EVar "take") (EVar "i")) (EVar "ys")) (EApp (EVar "go") (EApp (EApp (EVar "drop") (EBinOp "+" (EVar "i") (EVar "sepLen"))) (EVar "ys")))))))) (lgb "findSub" (clause ((PVar "i") (PVar "ys")) (EIf (EApp (EApp (EDictApp "startsWith") (EVar "sep")) (EVar "ys")) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EVar "findSubTail") (EVar "i")) (EVar "ys")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))) (lgb "findSubTail" (clause (PWild (PList)) (EVar "None")) (clause ((PVar "i") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "findSub") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))) (EApp (EVar "go") (EVar "xs"))))
(DTypeSig true "startsWith" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "startsWith" ((PList) PWild) (EVar "True"))
(DFunDef false "startsWith" (PWild (PList)) (EVar "False"))
(DFunDef false "startsWith" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "x") (PVar "xs"))) (EBinOp "&&" (EBinOp "==" (EVar "p") (EVar "x")) (EApp (EApp (EDictApp "startsWith") (EVar "ps")) (EVar "xs"))))
(DTypeSig true "endsWith" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "endsWith" ((PVar "suffix") (PVar "xs")) (EApp (EApp (EDictApp "startsWith") (EApp (EVar "reverse") (EVar "suffix"))) (EApp (EVar "reverse") (EVar "xs"))))
(DTypeSig true "contains" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "contains" ((PVar "sub") (PList)) (EApp (EApp (EDictApp "startsWith") (EMethodRef "sub")) (EListLit)))
(DFunDef false "contains" ((PVar "sub") (PAs "xs" (PCons PWild (PVar "rest")))) (EIf (EApp (EApp (EDictApp "startsWith") (EMethodRef "sub")) (EVar "xs")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EDictApp "contains") (EMethodRef "sub")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "sortBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sortBy" (PWild (PList)) (EListLit))
(DFunDef false "sortBy" (PWild (PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "sortBy" ((PVar "cmp") (PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "l") (PVar "r")) (EApp (EApp (EVar "splitAt") (EBinOp "/" (EApp (EMethodRef "length") (EVar "xs")) (ELit (LInt 2)))) (EVar "xs"))) (DoExpr (EApp (EApp (EApp (EVar "merge") (EVar "cmp")) (EApp (EApp (EVar "sortBy") (EVar "cmp")) (EVar "l"))) (EApp (EApp (EVar "sortBy") (EVar "cmp")) (EVar "r"))))))
(DTypeSig false "merge" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "merge" (PWild (PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "merge" (PWild (PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "merge" ((PVar "cmp") (PAs "xs" (PCons (PVar "x") (PVar "xs'"))) (PAs "ys" (PCons (PVar "y") (PVar "ys'")))) (EMatch (EApp (EApp (EVar "cmp") (EVar "x")) (EVar "y")) (arm (PCon "Gt") () (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "merge") (EVar "cmp")) (EVar "xs")) (EVar "ys'")))) (arm PWild () (EBinOp "::" (EVar "x") (EApp (EApp (EApp (EVar "merge") (EVar "cmp")) (EVar "xs'")) (EVar "ys"))))))
(DTypeSig true "sort" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "sort" ((PVar "xs")) (EApp (EApp (EVar "sortBy") (EMethodRef "compare")) (EVar "xs")))
(DTypeSig true "sortOn" (TyConstrained ((cstr "Ord" (TyVar "b"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "sortOn" ((PVar "key") (PVar "xs")) (EBlock (DoLet false false (PVar "decorated") (EApp (EApp (EMethodRef "map") (ELam ((PVar "x")) (ETuple (EApp (EVar "key") (EVar "x")) (EVar "x")))) (EVar "xs"))) (DoExpr (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EVar "sortBy") (ELam ((PTuple (PVar "k1") PWild) (PTuple (PVar "k2") PWild)) (EApp (EApp (EMethodRef "compare") (EVar "k1")) (EVar "k2")))) (EVar "decorated"))))))
(DTypeSig true "nubBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "nubBy" ((PVar "same") (PVar "xs")) (ELetGroup ((lgb "go" (clause ((PList) PWild) (EListLit)) (clause ((PCons (PVar "x") (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "s")) (EApp (EApp (EVar "same") (EVar "x")) (EVar "s")))) (EVar "seen")) (EApp (EApp (EVar "go") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "go") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EApp (EVar "go") (EVar "xs")) (EListLit))))
(DTypeSig true "nub" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "nub" ((PVar "xs")) (EApp (EApp (EVar "nubBy") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "==" (EVar "_a") (EVar "_b")))) (EVar "xs")))
(DTypeSig true "deleteBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool")))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "deleteBy" (PWild PWild (PList)) (EListLit))
(DFunDef false "deleteBy" ((PVar "same") (PVar "x") (PCons (PVar "y") (PVar "rest"))) (EIf (EApp (EApp (EVar "same") (EVar "x")) (EVar "y")) (EVar "rest") (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "deleteBy") (EVar "same")) (EVar "x")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "delete" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "delete" ((PVar "x") (PVar "xs")) (EApp (EApp (EApp (EVar "deleteBy") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "==" (EVar "_a") (EVar "_b")))) (EVar "x")) (EVar "xs")))
(DTypeSig true "groupBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "groupBy" (PWild (PList)) (EListLit))
(DFunDef false "groupBy" ((PVar "same") (PCons (PVar "x") (PVar "xs"))) (EBlock (DoLet false false (PTuple (PVar "grp") (PVar "rest")) (EApp (EApp (EVar "span") (ELam ((PVar "y")) (EApp (EApp (EVar "same") (EVar "x")) (EVar "y")))) (EVar "xs"))) (DoExpr (EBinOp "::" (EBinOp "::" (EVar "x") (EVar "grp")) (EApp (EApp (EVar "groupBy") (EVar "same")) (EVar "rest"))))))
(DTypeSig true "group" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "group" ((PVar "xs")) (EApp (EApp (EVar "groupBy") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "==" (EVar "_a") (EVar "_b")))) (EVar "xs")))
(DTypeSig true "partition" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "partition" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "partition" ((PVar "p") (PCons (PVar "x") (PVar "xs"))) (EBlock (DoLet false false (PTuple (PVar "yes") (PVar "no")) (EApp (EApp (EVar "partition") (EVar "p")) (EVar "xs"))) (DoExpr (EIf (EApp (EVar "p") (EVar "x")) (ETuple (EBinOp "::" (EVar "x") (EVar "yes")) (EVar "no")) (ETuple (EVar "yes") (EBinOp "::" (EVar "x") (EVar "no")))))))
(DTypeSig true "somes" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "somes" ((PList)) (EListLit))
(DFunDef false "somes" ((PCons (PCon "Some" (PVar "x")) (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "somes") (EVar "rest"))))
(DFunDef false "somes" ((PCons (PCon "None") (PVar "rest"))) (EApp (EVar "somes") (EVar "rest")))
(DTypeSig true "oks" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "oks" ((PList)) (EListLit))
(DFunDef false "oks" ((PCons (PCon "Ok" (PVar "x")) (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "oks") (EVar "rest"))))
(DFunDef false "oks" ((PCons (PCon "Err" PWild) (PVar "rest"))) (EApp (EVar "oks") (EVar "rest")))
(DTypeSig true "errs" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) (TyApp (TyCon "List") (TyVar "e"))))
(DFunDef false "errs" ((PList)) (EListLit))
(DFunDef false "errs" ((PCons (PCon "Err" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EVar "e") (EApp (EVar "errs") (EVar "rest"))))
(DFunDef false "errs" ((PCons (PCon "Ok" PWild) (PVar "rest"))) (EApp (EVar "errs") (EVar "rest")))
(DTypeSig true "partitionResults" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))) (TyTuple (TyApp (TyCon "List") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "partitionResults" ((PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "partitionResults" ((PCons (PCon "Ok" (PVar "x")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "es") (PVar "xs")) (EApp (EVar "partitionResults") (EVar "rest"))) (DoExpr (ETuple (EVar "es") (EBinOp "::" (EVar "x") (EVar "xs"))))))
(DFunDef false "partitionResults" ((PCons (PCon "Err" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "es") (PVar "xs")) (EApp (EVar "partitionResults") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "e") (EVar "es")) (EVar "xs")))))
(DTypeSig true "tally" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyCon "Int"))))))
(DFunDef false "tally" ((PVar "xs")) (ELetGroup ((lgb "go" (clause ((PList) (PVar "acc")) (EVar "acc")) (clause ((PCons (PVar "x") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "go") (EVar "rest")) (EApp (EApp (EVar "bump") (EVar "x")) (EVar "acc"))))) (lgb "bump" (clause ((PVar "x") (PList)) (EListLit (ETuple (EVar "x") (ELit (LInt 1))))) (clause ((PVar "x") (PCons (PTuple (PVar "k") (PVar "c")) (PVar "kvs"))) (EIf (EBinOp "==" (EVar "k") (EVar "x")) (EBinOp "::" (ETuple (EVar "k") (EBinOp "+" (EVar "c") (ELit (LInt 1)))) (EVar "kvs")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "c")) (EApp (EApp (EVar "bump") (EVar "x")) (EVar "kvs"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))) (EApp (EApp (EVar "go") (EVar "xs")) (EListLit))))
(DTypeSig true "head" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "head" ((PList)) (EVar "None"))
(DFunDef false "head" ((PCons (PVar "x") PWild)) (EApp (EVar "Some") (EVar "x")))
(DTypeSig true "tail" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "tail" ((PList)) (EVar "None"))
(DFunDef false "tail" ((PCons PWild (PVar "xs"))) (EApp (EVar "Some") (EVar "xs")))
(DTypeSig true "uncons" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyTuple (TyVar "a") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "uncons" ((PList)) (EVar "None"))
(DFunDef false "uncons" ((PCons (PVar "x") (PVar "xs"))) (EApp (EVar "Some") (ETuple (EVar "x") (EVar "xs"))))
(DTypeSig true "last" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "last" ((PList)) (EVar "None"))
(DFunDef false "last" ((PList (PVar "x"))) (EApp (EVar "Some") (EVar "x")))
(DFunDef false "last" ((PCons (PVar "x") (PVar "xs"))) (EApp (EVar "last") (EVar "xs")))
(DTypeSig true "init" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "init" ((PList)) (EVar "None"))
(DFunDef false "init" ((PCons (PVar "x") (PList))) (EApp (EVar "Some") (EListLit)))
(DFunDef false "init" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "x") (EVar "_s")))) (EApp (EVar "init") (EVar "xs"))))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "get" (PWild (PList)) (EVar "None"))
(DFunDef false "get" ((PLit (LInt 0)) (PCons (PVar "x") PWild)) (EApp (EVar "Some") (EVar "x")))
(DFunDef false "get" ((PVar "i") (PCons PWild (PVar "xs"))) (EApp (EApp (EVar "get") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs")))
(DTypeSig true "zip" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "zip" ((PList) PWild) (EListLit))
(DFunDef false "zip" (PWild (PList)) (EListLit))
(DFunDef false "zip" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "::" (ETuple (EVar "x") (EVar "y")) (EApp (EApp (EVar "zip") (EVar "xs")) (EVar "ys"))))
(DTypeSig true "zip3" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyFun (TyApp (TyCon "List") (TyVar "c")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")))))))
(DFunDef false "zip3" ((PList) PWild PWild) (EListLit))
(DFunDef false "zip3" (PWild (PList) PWild) (EListLit))
(DFunDef false "zip3" (PWild PWild (PList)) (EListLit))
(DFunDef false "zip3" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys")) (PCons (PVar "z") (PVar "zs"))) (EBinOp "::" (ETuple (EVar "x") (EVar "y") (EVar "z")) (EApp (EApp (EApp (EVar "zip3") (EVar "xs")) (EVar "ys")) (EVar "zs"))))
(DTypeSig true "zipWith" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c")))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "c")))))))
(DFunDef false "zipWith" (PWild (PList) PWild) (EListLit))
(DFunDef false "zipWith" (PWild PWild (PList)) (EListLit))
(DFunDef false "zipWith" ((PVar "f") (PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "::" (EApp (EApp (EVar "f") (EVar "x")) (EVar "y")) (EApp (EApp (EApp (EVar "zipWith") (EVar "f")) (EVar "xs")) (EVar "ys"))))
(DTypeSig true "zip4" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyFun (TyApp (TyCon "List") (TyVar "c")) (TyFun (TyApp (TyCon "List") (TyVar "d")) (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b") (TyVar "c") (TyVar "d"))))))))
(DFunDef false "zip4" ((PList) PWild PWild PWild) (EListLit))
(DFunDef false "zip4" (PWild (PList) PWild PWild) (EListLit))
(DFunDef false "zip4" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "zip4" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "zip4" ((PCons (PVar "w") (PVar "ws")) (PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys")) (PCons (PVar "z") (PVar "zs"))) (EBinOp "::" (ETuple (EVar "w") (EVar "x") (EVar "y") (EVar "z")) (EApp (EApp (EApp (EApp (EVar "zip4") (EVar "ws")) (EVar "xs")) (EVar "ys")) (EVar "zs"))))
(DTypeSig true "zipWith3" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyFun (TyVar "c") (TyEffect () (Some "e") (TyVar "d"))))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyFun (TyApp (TyCon "List") (TyVar "c")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "d"))))))))
(DFunDef false "zipWith3" (PWild (PList) PWild PWild) (EListLit))
(DFunDef false "zipWith3" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "zipWith3" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "zipWith3" ((PVar "f") (PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys")) (PCons (PVar "z") (PVar "zs"))) (EBinOp "::" (EApp (EApp (EApp (EVar "f") (EVar "x")) (EVar "y")) (EVar "z")) (EApp (EApp (EApp (EApp (EVar "zipWith3") (EVar "f")) (EVar "xs")) (EVar "ys")) (EVar "zs"))))
(DTypeSig true "unzip" (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b"))) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "unzip" ((PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "unzip" ((PCons (PTuple (PVar "x") (PVar "y")) (PVar "xys"))) (ELet false (PTuple (PVar "xs") (PVar "ys")) (EApp (EVar "unzip") (EVar "xys")) (ETuple (EBinOp "::" (EVar "x") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))))
(DTypeSig true "unzip3" (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b") (TyVar "c"))) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")) (TyApp (TyCon "List") (TyVar "c")))))
(DFunDef false "unzip3" ((PList)) (ETuple (EListLit) (EListLit) (EListLit)))
(DFunDef false "unzip3" ((PCons (PTuple (PVar "x") (PVar "y") (PVar "z")) (PVar "rest"))) (ELet false (PTuple (PVar "xs") (PVar "ys") (PVar "zs")) (EApp (EVar "unzip3") (EVar "rest")) (ETuple (EBinOp "::" (EVar "x") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")) (EBinOp "::" (EVar "z") (EVar "zs")))))
(DTypeSig false "isSorted" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "isSorted" ((PList)) (EVar "True"))
(DFunDef false "isSorted" ((PList PWild)) (EVar "True"))
(DFunDef false "isSorted" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EBinOp "&&" (EApp (EApp (EMethodRef "lte") (EVar "x")) (EVar "y")) (EApp (EDictApp "isSorted") (EBinOp "::" (EVar "y") (EVar "rest")))))
(DProp false "reverse is an involution" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EMethodRef "eq") (EApp (EVar "reverse") (EApp (EVar "reverse") (EVar "xs")))) (EVar "xs")))
(DProp false "take n ++ drop n recovers the list" ((pp "n" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EMethodRef "eq") (EBinOp "++" (EApp (EApp (EVar "take") (EVar "n")) (EVar "xs")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "xs")))) (EVar "xs")))
(DProp false "splitAt agrees with take/drop" ((pp "n" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EApp (EVar "splitAt") (EVar "n")) (EVar "xs"))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "a")) (EApp (EApp (EVar "take") (EVar "n")) (EVar "xs"))) (EApp (EApp (EMethodRef "eq") (EVar "b")) (EApp (EApp (EVar "drop") (EVar "n")) (EVar "xs")))))))
(DProp false "span ++ recovers the list" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EApp (EVar "span") (ELam ((PVar "x")) (EBinOp "<" (EVar "x") (ELit (LInt 5))))) (EVar "xs"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EBinOp "++" (EVar "a") (EVar "b"))) (EVar "xs")))))
(DProp false "sort is ascending and length-preserving" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "ys") (EApp (EDictApp "sort") (EVar "xs"))) (DoExpr (EBinOp "&&" (EApp (EDictApp "isSorted") (EVar "ys")) (EBinOp "==" (EApp (EMethodRef "length") (EVar "ys")) (EApp (EMethodRef "length") (EVar "xs")))))))
(DProp false "partition splits by the predicate" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "yes") (PVar "no")) (EApp (EApp (EVar "partition") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 0))))) (EVar "xs"))) (DoExpr (EBinOp "&&" (EApp (EApp (EDictApp "all") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 0))))) (EVar "yes")) (EApp (EApp (EDictApp "all") (ELam ((PVar "x")) (EBinOp "<=" (EVar "x") (ELit (LInt 0))))) (EVar "no"))))))
(DProp false "somes length is at most the input length" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "os") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 0))) (EApp (EVar "Some") (EVar "n")) (EVar "None")))) (EVar "xs"))) (DoExpr (EBinOp "<=" (EApp (EMethodRef "length") (EApp (EVar "somes") (EVar "os"))) (EApp (EMethodRef "length") (EVar "os"))))))
(DProp false "partitionResults sizes sum to the input length" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "rs") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 0))) (EApp (EVar "Ok") (EVar "n")) (EAnnot (EApp (EVar "Err") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int")))))) (EVar "xs"))) (DoLet false false (PTuple (PVar "es") (PVar "os")) (EApp (EVar "partitionResults") (EVar "rs"))) (DoExpr (EBinOp "==" (EBinOp "+" (EApp (EMethodRef "length") (EVar "es")) (EApp (EMethodRef "length") (EVar "os"))) (EApp (EMethodRef "length") (EVar "rs"))))))
(DProp false "oks/errs agree with partitionResults" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "rs") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 0))) (EApp (EVar "Ok") (EVar "n")) (EAnnot (EApp (EVar "Err") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int")))))) (EVar "xs"))) (DoLet false false (PTuple (PVar "es") (PVar "os")) (EApp (EVar "partitionResults") (EVar "rs"))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "es")) (EApp (EVar "errs") (EVar "rs"))) (EApp (EApp (EMethodRef "eq") (EVar "os")) (EApp (EVar "oks") (EVar "rs")))))))
(DProp false "nub removes all duplicates" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EMethodRef "eq") (EApp (EDictApp "nub") (EApp (EDictApp "nub") (EVar "xs")))) (EApp (EDictApp "nub") (EVar "xs"))))
(DProp false "concat of group recovers the list" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EMethodRef "eq") (EApp (EDictApp "flat") (EApp (EDictApp "group") (EVar "xs")))) (EVar "xs")))
(DProp false "span prefix all satisfies, and concatenates back" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EApp (EVar "span") (ELam ((PVar "x")) (EBinOp "<" (EVar "x") (ELit (LInt 5))))) (EVar "xs"))) (DoExpr (EBinOp "&&" (EApp (EApp (EDictApp "all") (ELam ((PVar "x")) (EBinOp "<" (EVar "x") (ELit (LInt 5))))) (EVar "a")) (EApp (EApp (EMethodRef "eq") (EBinOp "++" (EVar "a") (EVar "b"))) (EVar "xs"))))))
(DProp false "takeWhile ++ dropWhile recovers the list" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EMethodRef "eq") (EBinOp "++" (EApp (EApp (EVar "takeWhile") (ELam ((PVar "x")) (EBinOp "<" (EVar "x") (ELit (LInt 5))))) (EVar "xs")) (EApp (EApp (EVar "dropWhile") (ELam ((PVar "x")) (EBinOp "<" (EVar "x") (ELit (LInt 5))))) (EVar "xs")))) (EVar "xs")))
(DProp false "break equals span of the negated predicate" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "a1") (PVar "b1")) (EApp (EApp (EVar "break") (ELam ((PVar "x")) (EBinOp ">" (EVar "x") (ELit (LInt 5))))) (EVar "xs"))) (DoLet false false (PTuple (PVar "a2") (PVar "b2")) (EApp (EApp (EVar "span") (ELam ((PVar "x")) (EApp (EVar "not") (EBinOp ">" (EVar "x") (ELit (LInt 5)))))) (EVar "xs"))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "a1")) (EVar "a2")) (EApp (EApp (EMethodRef "eq") (EVar "b1")) (EVar "b2"))))))
(DProp false "range length is max 0 (hi - lo)" ((pp "lo" (TyCon "Int")) (pp "hi" (TyCon "Int"))) (EBinOp "==" (EApp (EMethodRef "length") (EApp (EApp (EVar "range") (EVar "lo")) (EVar "hi"))) (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EBinOp "-" (EVar "hi") (EVar "lo")))))
