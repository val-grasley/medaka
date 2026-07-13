# META
source_lines=601
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

{- | Split a list of pairs into a pair of lists — the inverse of `zip`.

   > unzip [(1, 2), (3, 4)]
   ([1, 3], [2, 4])
   > unzip []
   ([], []) -}
export unzip : List (a, b) -> (List a, List b)
unzip [] = ([], [])
unzip ((x, y)::xys) = let (xs, ys) = unzip xys in (x::xs, y::ys)

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
(DTypeSig true "unzip" (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b"))) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "unzip" ((PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "unzip" ((PCons (PTuple (PVar "x") (PVar "y")) (PVar "xys"))) (ELet false (PTuple (PVar "xs") (PVar "ys")) (EApp (EVar "unzip") (EVar "xys")) (ETuple (EBinOp "::" (EVar "x") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))))
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
(DTypeSig true "unzip" (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "a") (TyVar "b"))) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "unzip" ((PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "unzip" ((PCons (PTuple (PVar "x") (PVar "y")) (PVar "xys"))) (ELet false (PTuple (PVar "xs") (PVar "ys")) (EApp (EVar "unzip") (EVar "xys")) (ETuple (EBinOp "::" (EVar "x") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))))
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
