# META
source_lines=518
stages=DESUGAR,MARK
# SOURCE
{- array.mdk — operations on Array a
   See STDLIB.md (Module 4) for the plan.

   Design notes
   ────────────
   Arrays are fixed-size, O(1) random access, and backed by mutable memory
   under the hood.  Two design tensions shape this module:

     1. Performance vs. functional feel.  The public API is a pure facade
        where it can be (`map`, `filter`, `sort`, etc. return fresh arrays)
        and explicitly mutates in place where that's the whole point
        (`set`, `swap`, `sortInPlace`) — untracked, no effect in the signature.

     2. Opaque builtin vs. typeclass member.  `Array a` cannot be pattern-
        matched like `List a`, so the impls below dispatch through the
        `array*` primitives declared in stdlib/runtime.mdk.  We implement
        `Mappable`, `Foldable`, `Eq`, `Debug`, `Semigroup`, `Monoid` — and
        deliberately skip `Applicative` / `Thenable`, because the natural
        definitions would encode cartesian-style allocation that's a
        performance trap on bulk data.

   The kernel of OCaml-backed primitives lives in stdlib/runtime.mdk and is
   the surface this module sits on top of.  Most operations here are one or
   two lines of Medaka built on `arrayMakeWith` + `arrayGetUnsafe`, which
   compile to a tight loop in the host runtime. -}

import core.{
  Eq,
  Ord,
  Debug,
  Display,
  Foldable,
  Mappable,
  Filterable,
  Semigroup,
  Monoid,
  Ordering,
  Option,
}

-- ── Construction ────────────────────────────────────────────────────────

-- The empty array is `Monoid.empty` (see `impl Monoid (Array a)` below); use
-- the `[||]` literal directly inside this module.

{- | A one-element array.

   > toList (singleton 5)
   [5] -}
export singleton : a -> Array a
singleton x = [|x|]

{- | `make n x` — a fresh array of `n` copies of `x`.

   > toList (make 3 0)
   [0, 0, 0] -}
export make : Int -> a -> Array a
make n x = arrayMake n x

{- | `makeWith n f` — a fresh array whose element `i` is `f i`.

   > toList (makeWith 3 (i => i * 2))
   [0, 2, 4]
   > length (makeWith 0 (i => i))
   0 -}
export makeWith : Int -> (Int -> <e> a) -> <e> Array a
makeWith n f =
  if n <= 0 then
    [||]
  else
    arrayFromList (revList (makeWithRevBuild f 0 n []) [])

makeWithRevBuild : (Int -> <e> a) -> Int -> Int -> List a -> <e> List a
makeWithRevBuild f i n acc
  | i >= n = acc
  | otherwise = makeWithRevBuild f (i + 1) n (f i :: acc)

-- | Alias for `make`, included for symmetry with `List.replicate`.
export replicate : Int -> a -> Array a
replicate n x = arrayMake n x

-- | Build an array from a list, preserving order.
export fromList : List a -> Array a
fromList xs = arrayFromList xs

{- | Half-open `[lo, hi)`.  Empty when `hi <= lo`.

   > toList (range 0 4)
   [0, 1, 2, 3] -}
export range : Int -> Int -> Array Int
range lo hi = arrayMakeWith (if hi > lo then hi - lo else 0) (lo + _)

{- | Fresh copy with the same contents.  Useful before in-place mutation
   when you want to preserve the original. -}
export copy : Array a -> Array a
copy arr = arrayCopy arr

-- ── Observation ─────────────────────────────────────────────────────────

{- `length`, `isEmpty`, `toList` are provided by `impl Foldable Array`
   below; they're not re-exported as standalone names because that would
   collide with the polymorphic Foldable methods of the same name. -}

{- | Bounds-checked indexing.  `arr[i]` (which panics on OOB) is the fast
   path; `get` is the safe one.

   > get 0 (fromList [1, 2, 3])
   Some 1
   > get 5 (fromList [1, 2, 3])
   None -}
export get : Int -> Array a -> Option a
get i arr =
  if i < 0 || i >= arrayLength arr then
    None
  else
    Some (arrayGetUnsafe i arr)

{- | First element, or `None` when empty.

   > first (fromList [1, 2, 3])
   Some 1 -}
export first : Array a -> Option a
first arr = get 0 arr

{- | Last element, or `None` when empty.

   > last (fromList [1, 2, 3])
   Some 3 -}
export last : Array a -> Option a
last arr = get (arrayLength arr - 1) arr

-- Tail-recursive list build, used by the Foldable Array impl's `toList`.
toListGo : Array a -> Int -> List a -> List a
toListGo arr i acc =
  if i < 0 then
    acc
  else
    toListGo arr (i - 1) (arrayGetUnsafe i arr :: acc)

-- ── Pure transformation (return fresh arrays, no mutation) ──────────────

{- `map` is provided by `impl Mappable Array` below; not re-exported as a
   standalone name to avoid colliding with `Mappable.map`. -}

{- | Reverse the array into a fresh one.

   > toList (reverse (fromList [1, 2, 3]))
   [3, 2, 1] -}
export reverse : Array a -> Array a
reverse arr =
  let n = arrayLength arr
  arrayMakeWith n (i => arrayGetUnsafe (n - 1 - i) arr)

{- | `slice lo hi arr` — half-open `[lo, hi)`.  Clamps to the array bounds:
   a request outside `[0, length arr]` is silently truncated, never panics.
   Use `arr[lo..hi]` if you want OOB to panic instead.

   > toList (slice 1 3 (fromList [1, 2, 3, 4, 5]))
   [2, 3] -}
export slice : Int -> Int -> Array a -> Array a
slice lo hi arr =
  let n = arrayLength arr
  let lo' = if lo < 0 then 0 else min lo n
  let hi' = if hi < lo' then lo' else min hi n
  arrayMakeWith (hi' - lo') (i => arrayGetUnsafe (lo' + i) arr)

{- | First `n` elements (fewer if the array is shorter).

   > toList (take 2 (fromList [1, 2, 3, 4]))
   [1, 2] -}
export take : Int -> Array a -> Array a
take n arr = slice 0 n arr

{- | All but the first `n` elements.

   > toList (drop 2 (fromList [1, 2, 3, 4]))
   [3, 4] -}
export drop : Int -> Array a -> Array a
drop n arr = slice n (arrayLength arr) arr

-- `append` comes from `impl Semigroup (Array a)` (also the `++` operator).

-- | Flatten one level.  Two passes: sum lengths, then fill.
export concat : Array (Array a) -> Array a
concat arrs =
  let outer = arrayLength arrs
  let total = concatTotal arrs 0 0 outer
  arrayMakeWith total (i => concatLookup arrs i 0 outer)

concatTotal : Array (Array a) -> Int -> Int -> Int -> Int
concatTotal arrs i acc outer =
  if i >= outer then
    acc
  else
    concatTotal arrs (i + 1) (acc + arrayLength (arrayGetUnsafe i arrs)) outer

{- | Find element `i` by walking the outer array, subtracting inner
   lengths.  O(outer) per lookup → O(outer * total) overall.  Fine for
   typical use; a future optimisation could precompute a prefix-sum index. -}
concatLookup : Array (Array a) -> Int -> Int -> Int -> a
concatLookup arrs target k outer =
  let inner = arrayGetUnsafe k arrs
  let len = arrayLength inner
  if target < len then
    arrayGetUnsafe target inner
  else
    concatLookup arrs (target - len) (k + 1) outer

-- | Pair up two arrays element-wise, truncating to the shorter length.
export zip : Array a -> Array b -> Array (a, b)
zip a b =
  let n = min (arrayLength a) (arrayLength b)
  arrayMakeWith n (i => (arrayGetUnsafe i a, arrayGetUnsafe i b))

{- | Combine two arrays element-wise with `f`, truncating to the shorter.

   > toList (zipWith (x y => x + y) (fromList [1, 2]) (fromList [10, 20]))
   [11, 22] -}
export zipWith : (a -> b -> <e> c) -> Array a -> Array b -> <e> Array c
zipWith f a b =
  let n = min (arrayLength a) (arrayLength b)
  arrayMakeWith n (i => f (arrayGetUnsafe i a) (arrayGetUnsafe i b))

{- | Split an array of pairs into two parallel arrays — the inverse of `zip`.

   > let (xs, ys) = unzip (fromList [(1, 2), (3, 4)]) in (toList xs, toList ys)
   ([1, 3], [2, 4]) -}
export unzip : Array (a, b) -> (Array a, Array b)
unzip arr =
  let n = arrayLength arr
  (
    arrayMakeWith n (i => fst (arrayGetUnsafe i arr)),
    arrayMakeWith n (i => snd (arrayGetUnsafe i arr)),
  )

{- | `Filterable Array`.  Only `filterMap` is defined; `filter` comes from
   the interface default.  `filterMap` filters via a list intermediate
   (tail-recursive, builds reversed then `arrayFromList` after a final
   reverse): one O(N) traversal + one O(M) list build + one O(M) array
   copy, no mutation so the signature stays pure. -}
export impl Filterable Array where
  filterMap f arr =
    let n = arrayLength arr
    arrayFromList (revList (filterMapGo f arr 0 n []) [])

filterMapGo : (a -> <e> Option b) -> Array a -> Int -> Int -> List b -> <e> List b
filterMapGo f arr i n acc =
  if i >= n then
    acc
  else
    filterMapStep f arr i n acc (f (arrayGetUnsafe i arr))

filterMapStep : (a -> <e> Option b) -> Array a -> Int -> Int -> List b -> Option b -> <e> List b
filterMapStep f arr i n acc (Some y) = filterMapGo f arr (i + 1) n (y::acc)
filterMapStep f arr i n acc None = filterMapGo f arr (i + 1) n acc

-- Local tail-recursive list reverse (avoids depending on stdlib/list.mdk).
revList : List a -> List a -> List a
revList [] acc = acc
revList (x::xs) acc = revList xs (x::acc)

-- ── In-place mutation (untracked — no effect) ───────────────────────────

-- | Bounds-checked write.  Panics on OOB.
export set : Int -> a -> Array a -> Unit
set i x arr =
  if i < 0 || i >= arrayLength arr then
    panic "Array.set: index out of bounds"
  else
    arraySetUnsafe i x arr

-- | Exchange the elements at indices `i` and `j` in place.
export swap : Int -> Int -> Array a -> Unit
swap i j arr =
  let xi = arrayGetUnsafe i arr
  let xj = arrayGetUnsafe j arr
  arraySetUnsafe i xj arr
  arraySetUnsafe j xi arr

-- | Overwrite every element with `x` in place.
export fill : a -> Array a -> Unit
fill x arr = arrayFill x arr

-- | Bounds-checked bulk copy: copies `len` elements from `src` at offset
--   `srcOff` into `dst` at offset `dstOff`.  Panics when any argument is
--   negative or the copy would exceed either array's bounds.
export blit : Array a -> Int -> Array a -> Int -> Int -> Unit
blit src srcOff dst dstOff len =
  if len < 0 then
    panic "Array.blit: negative length"
  else if srcOff < 0 then
    panic "Array.blit: negative srcOff"
  else if dstOff < 0 then
    panic "Array.blit: negative dstOff"
  else if srcOff + len > arrayLength src then
    panic "Array.blit: source out of bounds"
  else if dstOff + len > arrayLength dst then
    panic "Array.blit: destination out of bounds"
  else
    arrayBlit src srcOff dst dstOff len

-- | Sort in place using the supplied comparison.
export sortInPlaceBy : (a -> a -> <e> Ordering) -> Array a -> <e> Unit
sortInPlaceBy cmp arr =
  let sorted = sortBy cmp arr
  arrayBlit sorted 0 arr 0 (arrayLength arr)

-- | Sort in place by the `Ord` instance.
export sortInPlace : Ord a => Array a -> Unit
sortInPlace arr = sortInPlaceBy compare arr

-- ── Pure sort (returns fresh sorted array) ──────────────────────────────

{- | Sort into a fresh array using the supplied comparison (stable mergesort).

   > toList (sortBy compare (fromList [3, 1, 4, 1, 5]))
   [1, 1, 3, 4, 5]
   > toList (sortBy (x y => compare y x) (fromList [3, 1, 2]))
   [3, 2, 1] -}
export sortBy : (a -> a -> <e> Ordering) -> Array a -> <e> Array a
sortBy cmp arr =
  let n = arrayLength arr
  if n <= 1 then arrayCopy arr
  else
    let mid = n / 2
    let left = arrayMakeWith mid (i => arrayGetUnsafe i arr)
    let right = arrayMakeWith (n - mid) (i => arrayGetUnsafe (mid + i) arr)
    merge cmp (sortBy cmp left) (sortBy cmp right)

{- | Sort into a fresh array by the `Ord` instance.

   > toList (sort (fromList [3, 1, 4, 1, 5]))
   [1, 1, 3, 4, 5] -}
export sort : Ord a => Array a -> Array a
sort arr = sortBy compare arr

{- | Sort into a fresh array by a key projection, computing the key once per
   element (decorate–sort–undecorate) so an expensive `key` isn't recomputed in
   every comparison — matching `List.sortOn`.

   > toList (sortOn (x => 0 - x) (fromList [1, 3, 2]))
   [3, 2, 1] -}
export sortOn : Ord b => (a -> <e> b) -> Array a -> <e> Array a
sortOn key arr =
  let decorated = arrayMakeWith (arrayLength arr) (i => (key (arrayGetUnsafe i arr), arrayGetUnsafe i arr))
  let sorted = sortBy ((k1, _) (k2, _) => compare k1 k2) decorated
  arrayMakeWith (arrayLength sorted) (i => snd (arrayGetUnsafe i sorted))

-- ── Merge helpers (→MEDAKA: Medaka implementation for LLVM backend) ────

-- Merge two sorted arrays into a fresh sorted array (stable: equal → left first).
-- No mutation — collects into a list then calls `arrayFromList`.
merge : (a -> a -> <e> Ordering) -> Array a -> Array a -> <e> Array a
merge cmp left right =
  arrayFromList (mergeGo
    cmp
    left
    right
    0
    0
    (arrayLength left)
    (arrayLength right)
    [])

-- Accumulates in reverse; flips at the base case via `revList`.
mergeGo : (a -> a -> <e> Ordering) -> Array a -> Array a -> Int -> Int -> Int -> Int -> List a -> <e> List a
mergeGo cmp left right il ir nl nr acc
  | il >= nl && ir >= nr = revList acc []
  | il >= nl =
    mergeGo cmp left right il (ir + 1) nl nr (arrayGetUnsafe ir right :: acc)
  | ir >= nr =
    mergeGo cmp left right (il + 1) ir nl nr (arrayGetUnsafe il left :: acc)
  | otherwise = mergeStep cmp left right il ir nl nr acc

-- Dispatches on comparator result; separated out to avoid match-inside-else.
mergeStep : (a -> a -> <e> Ordering) -> Array a -> Array a -> Int -> Int -> Int -> Int -> List a -> <e> List a
mergeStep cmp left right il ir nl nr acc = match cmp (arrayGetUnsafe il left) (arrayGetUnsafe ir right)
  Gt =>
    mergeGo cmp left right il (ir + 1) nl nr (arrayGetUnsafe ir right :: acc)
  _ => mergeGo cmp left right (il + 1) ir nl nr (arrayGetUnsafe il left :: acc)

-- ── Folds and search ────────────────────────────────────────────────────

{- `fold`, `foldRight`, `any`, `all` are reachable via the Foldable
   machinery in core once `impl Foldable Array` is loaded.  We define the
   tail-recursive helpers here because the impl bodies and the search
   functions below both call them, but we don't re-export them as
   standalone names. -}

foldGo : (b -> a -> <e> b) -> Array a -> Int -> Int -> b -> <e> b
foldGo f arr i n acc =
  if i >= n then
    acc
  else
    foldGo f arr (i + 1) n (f acc (arrayGetUnsafe i arr))

foldRightGo : (a -> b -> <e> b) -> Array a -> Int -> b -> <e> b
foldRightGo f arr i acc =
  if i < 0 then
    acc
  else
    foldRightGo f arr (i - 1) (f (arrayGetUnsafe i arr) acc)

-- | First element satisfying the predicate, or `None`.
export find : (a -> <e> Bool) -> Array a -> <e> Option a
find pred arr = findGo pred arr 0 (arrayLength arr)

findGo : (a -> <e> Bool) -> Array a -> Int -> Int -> <e> Option a
findGo pred arr i n =
  if i >= n then
    None
  else if pred (arrayGetUnsafe i arr) then
    Some (arrayGetUnsafe i arr)
  else
    findGo pred arr (i + 1) n

{- | Index of the first element satisfying the predicate, or `None`.

   > findIndex (x => x > 2) (fromList [1, 2, 3])
   Some 2 -}
export findIndex : (a -> <e> Bool) -> Array a -> <e> Option Int
findIndex pred arr = findIndexGo pred arr 0 (arrayLength arr)

findIndexGo : (a -> <e> Bool) -> Array a -> Int -> Int -> <e> Option Int
findIndexGo pred arr i n =
  if i >= n then
    None
  else if pred (arrayGetUnsafe i arr) then
    Some i
  else
    findIndexGo pred arr (i + 1) n

{- `elem`, `sum`, and `product` are *not* defined here either: the generic
   `Foldable` versions in core (`elem : (Foldable t, Eq a) => …`,
   `sum`/`product : (Foldable t, Num a) => …`) dispatch over `impl Foldable
   Array` and fold through the same tight loop, so the array-specialised
   copies were pure redundancy.  Doctests pinning the dispatch:

   > elem 2 (fromList [1, 2, 3])
   True
   > sum (fromList [1, 2, 3, 4])
   10
   > product (fromList [1, 2, 3, 4])
   24 -}

{- `maximum`/`minimum` are *not* defined here: the generic `(Foldable t,
   Ord a) => t a -> Option a` versions in core dispatch over `impl Foldable
   Array`, so they already work on arrays.  Doctests pinning that:

   > maximum (fromList [3, 1, 2])
   Some 3
   > minimum (fromList [3, 1, 2])
   Some 1 -}

-- ── Typeclass impls ─────────────────────────────────────────────────────

export impl Mappable Array where
  map f arr = arrayMakeWith (arrayLength arr) (i => f (arrayGetUnsafe i arr))

export impl Foldable Array where
  fold f z arr = foldGo f arr 0 (arrayLength arr) z
  foldRight f z arr = foldRightGo f arr (arrayLength arr - 1) z
  toList arr = toListGo arr (arrayLength arr - 1) []
  isEmpty arr = arrayLength arr == 0
  length arr = arrayLength arr

export impl Semigroup (Array a) where
  append a b = arrayMakeWith
    (arrayLength a + arrayLength b)
    (i => if i < arrayLength a then arrayGetUnsafe i a else arrayGetUnsafe (i - arrayLength a) b)

{- | `Monoid.empty` for `Array` is the empty array.  `empty` is nullary, so it
   dispatches on its annotated *result* type (Phase 103):

   > length (empty : Array Int)
   0 -}
export impl Monoid (Array a) where
  empty = [||]

-- `impl Eq (Array a)` lives in `stdlib/core.mdk` (the prelude), alongside
-- `Debug`/`Index`, so `deriving (Eq)` over an array field builds without an
-- `import array`.

-- ── Properties (executed by `medaka test`) ──────────────────────────────

-- Ascending-order check for props below.
isSortedArr : Ord a => Array a -> Bool
isSortedArr arr = isSortedArrGo arr 0 (arrayLength arr)

isSortedArrGo : Ord a => Array a -> Int -> Int -> Bool
isSortedArrGo arr i n
  | i >= n - 1 = True
  | lte (arrayGetUnsafe i arr) (arrayGetUnsafe (i + 1) arr) =
    isSortedArrGo arr (i + 1) n
  | otherwise = False

prop "sortBy ascending and length-preserving" (xs : List Int) =
  let arr = fromList xs
  let sorted = sortBy compare arr
  isSortedArr sorted && length sorted == length arr

prop "sortBy idempotent" (xs : List Int) =
  let arr = fromList xs
  let sorted = sortBy compare arr
  eq sorted (sortBy compare sorted)

prop "sortBy stable: equal keys preserve original order" (xs : List Int) =
  let arr = fromList (map (x => (0, x)) xs)
  let sorted = sortBy ((k1, _) (k2, _) => compare k1 k2) arr
  eq (toList (map snd sorted)) xs

prop "makeWith length" (n : Int) =
  let n' = if n < 0 then 0 - n else n
  length (makeWith n' (i => i)) == n'

prop "makeWith element at index 0" (n : Int) =
  let n' = if n <= 0 then 1 else n
  arrayGetUnsafe 0 (makeWith n' (i => i * 3 + 7)) == 7
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Foldable" false) (mem "Mappable" false) (mem "Filterable" false) (mem "Semigroup" false) (mem "Monoid" false) (mem "Ordering" false) (mem "Option" false))))
(DTypeSig true "singleton" (TyFun (TyVar "a") (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "singleton" ((PVar "x")) (EArrayLit (EVar "x")))
(DTypeSig true "make" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "make" ((PVar "n") (PVar "x")) (EApp (EApp (EVar "arrayMake") (EVar "n")) (EVar "x")))
(DTypeSig true "makeWith" (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "a"))) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a"))))))
(DFunDef false "makeWith" ((PVar "n") (PVar "f")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EArrayLit) (EApp (EVar "arrayFromList") (EApp (EApp (EVar "revList") (EApp (EApp (EApp (EApp (EVar "makeWithRevBuild") (EVar "f")) (ELit (LInt 0))) (EVar "n")) (EListLit))) (EListLit)))))
(DTypeSig false "makeWithRevBuild" (TyFun (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))))
(DFunDef false "makeWithRevBuild" ((PVar "f") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "makeWithRevBuild") (EVar "f")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EApp (EVar "f") (EVar "i")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "replicate" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "replicate" ((PVar "n") (PVar "x")) (EApp (EApp (EVar "arrayMake") (EVar "n")) (EVar "x")))
(DTypeSig true "fromList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "fromList" ((PVar "xs")) (EApp (EVar "arrayFromList") (EVar "xs")))
(DTypeSig true "range" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "range" ((PVar "lo") (PVar "hi")) (EApp (EApp (EVar "arrayMakeWith") (EIf (EBinOp ">" (EVar "hi") (EVar "lo")) (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 0)))) (ELam ((PVar "_s")) (EBinOp "+" (EVar "lo") (EVar "_s")))))
(DTypeSig true "copy" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "copy" ((PVar "arr")) (EApp (EVar "arrayCopy") (EVar "arr")))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "get" ((PVar "i") (PVar "arr")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))
(DTypeSig true "first" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "first" ((PVar "arr")) (EApp (EApp (EVar "get") (ELit (LInt 0))) (EVar "arr")))
(DTypeSig true "last" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "last" ((PVar "arr")) (EApp (EApp (EVar "get") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "arr")))
(DTypeSig false "toListGo" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "toListGo" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EApp (EApp (EApp (EVar "toListGo") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc")))))
(DTypeSig true "reverse" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "reverse" ((PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EBinOp "-" (EVar "n") (ELit (LInt 1))) (EVar "i"))) (EVar "arr")))))))
(DTypeSig true "slice" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))))
(DFunDef false "slice" ((PVar "lo") (PVar "hi") (PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoLet false false (PVar "lo'") (EIf (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EApp (EVar "min") (EVar "lo")) (EVar "n")))) (DoLet false false (PVar "hi'") (EIf (EBinOp "<" (EVar "hi") (EVar "lo'")) (EVar "lo'") (EApp (EApp (EVar "min") (EVar "hi")) (EVar "n")))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "hi'") (EVar "lo'"))) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "lo'") (EVar "i"))) (EVar "arr")))))))
(DTypeSig true "take" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "take" ((PVar "n") (PVar "arr")) (EApp (EApp (EApp (EVar "slice") (ELit (LInt 0))) (EVar "n")) (EVar "arr")))
(DTypeSig true "drop" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "drop" ((PVar "n") (PVar "arr")) (EApp (EApp (EApp (EVar "slice") (EVar "n")) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "arr")))
(DTypeSig true "concat" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyVar "a"))) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "concat" ((PVar "arrs")) (EBlock (DoLet false false (PVar "outer") (EApp (EVar "arrayLength") (EVar "arrs"))) (DoLet false false (PVar "total") (EApp (EApp (EApp (EApp (EVar "concatTotal") (EVar "arrs")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "outer"))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "total")) (ELam ((PVar "i")) (EApp (EApp (EApp (EApp (EVar "concatLookup") (EVar "arrs")) (EVar "i")) (ELit (LInt 0))) (EVar "outer")))))))
(DTypeSig false "concatTotal" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "concatTotal" ((PVar "arrs") (PVar "i") (PVar "acc") (PVar "outer")) (EIf (EBinOp ">=" (EVar "i") (EVar "outer")) (EVar "acc") (EApp (EApp (EApp (EApp (EVar "concatTotal") (EVar "arrs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (EApp (EVar "arrayLength") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arrs"))))) (EVar "outer"))))
(DTypeSig false "concatLookup" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a"))))))
(DFunDef false "concatLookup" ((PVar "arrs") (PVar "target") (PVar "k") (PVar "outer")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arrs"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "inner"))) (DoExpr (EIf (EBinOp "<" (EVar "target") (EVar "len")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "target")) (EVar "inner")) (EApp (EApp (EApp (EApp (EVar "concatLookup") (EVar "arrs")) (EBinOp "-" (EVar "target") (EVar "len"))) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "outer"))))))
(DTypeSig true "zip" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "b")) (TyApp (TyCon "Array") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "zip" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "min") (EApp (EVar "arrayLength") (EVar "a"))) (EApp (EVar "arrayLength") (EVar "b")))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (ETuple (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "b"))))))))
(DTypeSig true "zipWith" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "c")))))))
(DFunDef false "zipWith" ((PVar "f") (PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "min") (EApp (EVar "arrayLength") (EVar "a"))) (EApp (EVar "arrayLength") (EVar "b")))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "b"))))))))
(DTypeSig true "unzip" (TyFun (TyApp (TyCon "Array") (TyTuple (TyVar "a") (TyVar "b"))) (TyTuple (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "b")))))
(DFunDef false "unzip" ((PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (ETuple (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))) (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EVar "snd") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))))))
(DImpl true "Filterable" ((TyCon "Array")) () ((im "filterMap" ((PVar "f") (PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EVar "arrayFromList") (EApp (EApp (EVar "revList") (EApp (EApp (EApp (EApp (EApp (EVar "filterMapGo") (EVar "f")) (EVar "arr")) (ELit (LInt 0))) (EVar "n")) (EListLit))) (EListLit))))))))
(DTypeSig false "filterMapGo" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "b")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "b")))))))))
(DFunDef false "filterMapGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "filterMapStep") (EVar "f")) (EVar "arr")) (EVar "i")) (EVar "n")) (EVar "acc")) (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))))
(DTypeSig false "filterMapStep" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "b")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyFun (TyApp (TyCon "Option") (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "b"))))))))))
(DFunDef false "filterMapStep" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n") (PVar "acc") (PCon "Some" (PVar "y"))) (EApp (EApp (EApp (EApp (EApp (EVar "filterMapGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "y") (EVar "acc"))))
(DFunDef false "filterMapStep" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n") (PVar "acc") (PCon "None")) (EApp (EApp (EApp (EApp (EApp (EVar "filterMapGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "acc")))
(DTypeSig false "revList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "revList" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "revList" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "revList") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig true "set" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "set" ((PVar "i") (PVar "x") (PVar "arr")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EApp (EVar "panic") (ELit (LString "Array.set: index out of bounds"))) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "x")) (EVar "arr"))))
(DTypeSig true "swap" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "swap" ((PVar "i") (PVar "j") (PVar "arr")) (EBlock (DoLet false false (PVar "xi") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (DoLet false false (PVar "xj") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "xj")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EVar "xi")) (EVar "arr")))))
(DTypeSig true "fill" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "fill" ((PVar "x") (PVar "arr")) (EApp (EApp (EVar "arrayFill") (EVar "x")) (EVar "arr")))
(DTypeSig true "blit" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "blit" ((PVar "src") (PVar "srcOff") (PVar "dst") (PVar "dstOff") (PVar "len")) (EIf (EBinOp "<" (EVar "len") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "Array.blit: negative length"))) (EIf (EBinOp "<" (EVar "srcOff") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "Array.blit: negative srcOff"))) (EIf (EBinOp "<" (EVar "dstOff") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "Array.blit: negative dstOff"))) (EIf (EBinOp ">" (EBinOp "+" (EVar "srcOff") (EVar "len")) (EApp (EVar "arrayLength") (EVar "src"))) (EApp (EVar "panic") (ELit (LString "Array.blit: source out of bounds"))) (EIf (EBinOp ">" (EBinOp "+" (EVar "dstOff") (EVar "len")) (EApp (EVar "arrayLength") (EVar "dst"))) (EApp (EVar "panic") (ELit (LString "Array.blit: destination out of bounds"))) (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "src")) (EVar "srcOff")) (EVar "dst")) (EVar "dstOff")) (EVar "len"))))))))
(DTypeSig true "sortInPlaceBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "sortInPlaceBy" ((PVar "cmp") (PVar "arr")) (EBlock (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (EVar "cmp")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "sorted")) (ELit (LInt 0))) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))))
(DTypeSig true "sortInPlace" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "sortInPlace" ((PVar "arr")) (EApp (EApp (EVar "sortInPlaceBy") (EVar "compare")) (EVar "arr")))
(DTypeSig true "sortBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a"))))))
(DFunDef false "sortBy" ((PVar "cmp") (PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 1))) (EApp (EVar "arrayCopy") (EVar "arr")) (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (DoLet false false (PVar "left") (EApp (EApp (EVar "arrayMakeWith") (EVar "mid")) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))) (DoLet false false (PVar "right") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "n") (EVar "mid"))) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "mid") (EVar "i"))) (EVar "arr"))))) (DoExpr (EApp (EApp (EApp (EVar "merge") (EVar "cmp")) (EApp (EApp (EVar "sortBy") (EVar "cmp")) (EVar "left"))) (EApp (EApp (EVar "sortBy") (EVar "cmp")) (EVar "right")))))))))
(DTypeSig true "sort" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "sort" ((PVar "arr")) (EApp (EApp (EVar "sortBy") (EVar "compare")) (EVar "arr")))
(DTypeSig true "sortOn" (TyConstrained ((cstr "Ord" (TyVar "b"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a")))))))
(DFunDef false "sortOn" ((PVar "key") (PVar "arr")) (EBlock (DoLet false false (PVar "decorated") (EApp (EApp (EVar "arrayMakeWith") (EApp (EVar "arrayLength") (EVar "arr"))) (ELam ((PVar "i")) (ETuple (EApp (EVar "key") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))) (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (ELam ((PTuple (PVar "k1") PWild) (PTuple (PVar "k2") PWild)) (EApp (EApp (EVar "compare") (EVar "k1")) (EVar "k2")))) (EVar "decorated"))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EApp (EVar "arrayLength") (EVar "sorted"))) (ELam ((PVar "i")) (EApp (EVar "snd") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "sorted"))))))))
(DTypeSig false "merge" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a")))))))
(DFunDef false "merge" ((PVar "cmp") (PVar "left") (PVar "right")) (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeGo") (EVar "cmp")) (EVar "left")) (EVar "right")) (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "left"))) (EApp (EVar "arrayLength") (EVar "right"))) (EListLit))))
(DTypeSig false "mergeGo" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))))))))
(DFunDef false "mergeGo" ((PVar "cmp") (PVar "left") (PVar "right") (PVar "il") (PVar "ir") (PVar "nl") (PVar "nr") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "il") (EVar "nl")) (EBinOp ">=" (EVar "ir") (EVar "nr"))) (EApp (EApp (EVar "revList") (EVar "acc")) (EListLit)) (EIf (EBinOp ">=" (EVar "il") (EVar "nl")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeGo") (EVar "cmp")) (EVar "left")) (EVar "right")) (EVar "il")) (EBinOp "+" (EVar "ir") (ELit (LInt 1)))) (EVar "nl")) (EVar "nr")) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "ir")) (EVar "right")) (EVar "acc"))) (EIf (EBinOp ">=" (EVar "ir") (EVar "nr")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeGo") (EVar "cmp")) (EVar "left")) (EVar "right")) (EBinOp "+" (EVar "il") (ELit (LInt 1)))) (EVar "ir")) (EVar "nl")) (EVar "nr")) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "il")) (EVar "left")) (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeStep") (EVar "cmp")) (EVar "left")) (EVar "right")) (EVar "il")) (EVar "ir")) (EVar "nl")) (EVar "nr")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "mergeStep" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))))))))
(DFunDef false "mergeStep" ((PVar "cmp") (PVar "left") (PVar "right") (PVar "il") (PVar "ir") (PVar "nl") (PVar "nr") (PVar "acc")) (EMatch (EApp (EApp (EVar "cmp") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "il")) (EVar "left"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "ir")) (EVar "right"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeGo") (EVar "cmp")) (EVar "left")) (EVar "right")) (EVar "il")) (EBinOp "+" (EVar "ir") (ELit (LInt 1)))) (EVar "nl")) (EVar "nr")) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "ir")) (EVar "right")) (EVar "acc")))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeGo") (EVar "cmp")) (EVar "left")) (EVar "right")) (EBinOp "+" (EVar "il") (ELit (LInt 1)))) (EVar "ir")) (EVar "nl")) (EVar "nr")) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "il")) (EVar "left")) (EVar "acc"))))))
(DTypeSig false "foldGo" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b"))))))))
(DFunDef false "foldGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EApp (EVar "f") (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))))
(DTypeSig false "foldRightGo" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))))))
(DFunDef false "foldRightGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EApp (EApp (EApp (EApp (EVar "foldRightGo") (EVar "f")) (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EVar "acc")))))
(DTypeSig true "find" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "find" ((PVar "pred") (PVar "arr")) (EApp (EApp (EApp (EApp (EVar "findGo") (EVar "pred")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "findGo" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a"))))))))
(DFunDef false "findGo" ((PVar "pred") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EApp (EVar "pred") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EVar "findGo") (EVar "pred")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig true "findIndex" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "findIndex" ((PVar "pred") (PVar "arr")) (EApp (EApp (EApp (EApp (EVar "findIndexGo") (EVar "pred")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "findIndexGo" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "findIndexGo" ((PVar "pred") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EApp (EVar "pred") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EApp (EApp (EVar "findIndexGo") (EVar "pred")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DImpl true "Mappable" ((TyCon "Array")) () ((im "map" ((PVar "f") (PVar "arr")) (EApp (EApp (EVar "arrayMakeWith") (EApp (EVar "arrayLength") (EVar "arr"))) (ELam ((PVar "i")) (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))))))
(DImpl true "Foldable" ((TyCon "Array")) () ((im "fold" ((PVar "f") (PVar "z") (PVar "arr")) (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "z"))) (im "foldRight" ((PVar "f") (PVar "z") (PVar "arr")) (EApp (EApp (EApp (EApp (EVar "foldRightGo") (EVar "f")) (EVar "arr")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "z"))) (im "toList" ((PVar "arr")) (EApp (EApp (EApp (EVar "toListGo") (EVar "arr")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EListLit))) (im "isEmpty" ((PVar "arr")) (EBinOp "==" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 0)))) (im "length" ((PVar "arr")) (EApp (EVar "arrayLength") (EVar "arr")))))
(DImpl true "Semigroup" ((TyApp (TyCon "Array") (TyVar "a"))) () ((im "append" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "arrayMakeWith") (EBinOp "+" (EApp (EVar "arrayLength") (EVar "a")) (EApp (EVar "arrayLength") (EVar "b")))) (ELam ((PVar "i")) (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "a"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (EApp (EVar "arrayLength") (EVar "a")))) (EVar "b"))))))))
(DImpl true "Monoid" ((TyApp (TyCon "Array") (TyVar "a"))) () ((im "empty" () (EArrayLit))))
(DTypeSig false "isSortedArr" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "isSortedArr" ((PVar "arr")) (EApp (EApp (EApp (EVar "isSortedArrGo") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "isSortedArrGo" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "isSortedArrGo" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "True") (EIf (EApp (EApp (EVar "lte") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EVar "isSortedArrGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DProp false "sortBy ascending and length-preserving" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (EVar "compare")) (EVar "arr"))) (DoExpr (EBinOp "&&" (EApp (EVar "isSortedArr") (EVar "sorted")) (EBinOp "==" (EApp (EVar "length") (EVar "sorted")) (EApp (EVar "length") (EVar "arr")))))))
(DProp false "sortBy idempotent" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (EVar "compare")) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "eq") (EVar "sorted")) (EApp (EApp (EVar "sortBy") (EVar "compare")) (EVar "sorted"))))))
(DProp false "sortBy stable: equal keys preserve original order" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EApp (EApp (EVar "map") (ELam ((PVar "x")) (ETuple (ELit (LInt 0)) (EVar "x")))) (EVar "xs")))) (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (ELam ((PTuple (PVar "k1") PWild) (PTuple (PVar "k2") PWild)) (EApp (EApp (EVar "compare") (EVar "k1")) (EVar "k2")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "sorted")))) (EVar "xs")))))
(DProp false "makeWith length" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "n'") (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n"))) (DoExpr (EBinOp "==" (EApp (EVar "length") (EApp (EApp (EVar "makeWith") (EVar "n'")) (ELam ((PVar "i")) (EVar "i")))) (EVar "n'")))))
(DProp false "makeWith element at index 0" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "n'") (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LInt 1)) (EVar "n"))) (DoExpr (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EApp (EVar "makeWith") (EVar "n'")) (ELam ((PVar "i")) (EBinOp "+" (EBinOp "*" (EVar "i") (ELit (LInt 3))) (ELit (LInt 7)))))) (ELit (LInt 7))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Foldable" false) (mem "Mappable" false) (mem "Filterable" false) (mem "Semigroup" false) (mem "Monoid" false) (mem "Ordering" false) (mem "Option" false))))
(DTypeSig true "singleton" (TyFun (TyVar "a") (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "singleton" ((PVar "x")) (EArrayLit (EVar "x")))
(DTypeSig true "make" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "make" ((PVar "n") (PVar "x")) (EApp (EApp (EVar "arrayMake") (EVar "n")) (EVar "x")))
(DTypeSig true "makeWith" (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "a"))) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a"))))))
(DFunDef false "makeWith" ((PVar "n") (PVar "f")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EArrayLit) (EApp (EVar "arrayFromList") (EApp (EApp (EVar "revList") (EApp (EApp (EApp (EApp (EVar "makeWithRevBuild") (EVar "f")) (ELit (LInt 0))) (EVar "n")) (EListLit))) (EListLit)))))
(DTypeSig false "makeWithRevBuild" (TyFun (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))))
(DFunDef false "makeWithRevBuild" ((PVar "f") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "makeWithRevBuild") (EVar "f")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EApp (EVar "f") (EVar "i")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "replicate" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "replicate" ((PVar "n") (PVar "x")) (EApp (EApp (EVar "arrayMake") (EVar "n")) (EVar "x")))
(DTypeSig true "fromList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "fromList" ((PVar "xs")) (EApp (EVar "arrayFromList") (EVar "xs")))
(DTypeSig true "range" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Array") (TyCon "Int")))))
(DFunDef false "range" ((PVar "lo") (PVar "hi")) (EApp (EApp (EVar "arrayMakeWith") (EIf (EBinOp ">" (EVar "hi") (EVar "lo")) (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 0)))) (ELam ((PVar "_s")) (EBinOp "+" (EVar "lo") (EVar "_s")))))
(DTypeSig true "copy" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "copy" ((PVar "arr")) (EApp (EVar "arrayCopy") (EVar "arr")))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "get" ((PVar "i") (PVar "arr")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))
(DTypeSig true "first" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "first" ((PVar "arr")) (EApp (EApp (EVar "get") (ELit (LInt 0))) (EVar "arr")))
(DTypeSig true "last" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "last" ((PVar "arr")) (EApp (EApp (EVar "get") (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "arr")))
(DTypeSig false "toListGo" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "toListGo" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EApp (EApp (EApp (EVar "toListGo") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc")))))
(DTypeSig true "reverse" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "reverse" ((PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EBinOp "-" (EVar "n") (ELit (LInt 1))) (EVar "i"))) (EVar "arr")))))))
(DTypeSig true "slice" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))))
(DFunDef false "slice" ((PVar "lo") (PVar "hi") (PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoLet false false (PVar "lo'") (EIf (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EApp (EMethodRef "min") (EVar "lo")) (EVar "n")))) (DoLet false false (PVar "hi'") (EIf (EBinOp "<" (EVar "hi") (EVar "lo'")) (EVar "lo'") (EApp (EApp (EMethodRef "min") (EVar "hi")) (EVar "n")))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "hi'") (EVar "lo'"))) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "lo'") (EVar "i"))) (EVar "arr")))))))
(DTypeSig true "take" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "take" ((PVar "n") (PVar "arr")) (EApp (EApp (EApp (EVar "slice") (ELit (LInt 0))) (EVar "n")) (EVar "arr")))
(DTypeSig true "drop" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "drop" ((PVar "n") (PVar "arr")) (EApp (EApp (EApp (EVar "slice") (EVar "n")) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "arr")))
(DTypeSig true "concat" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyVar "a"))) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "concat" ((PVar "arrs")) (EBlock (DoLet false false (PVar "outer") (EApp (EVar "arrayLength") (EVar "arrs"))) (DoLet false false (PVar "total") (EApp (EApp (EApp (EApp (EVar "concatTotal") (EVar "arrs")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "outer"))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "total")) (ELam ((PVar "i")) (EApp (EApp (EApp (EApp (EVar "concatLookup") (EVar "arrs")) (EVar "i")) (ELit (LInt 0))) (EVar "outer")))))))
(DTypeSig false "concatTotal" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "concatTotal" ((PVar "arrs") (PVar "i") (PVar "acc") (PVar "outer")) (EIf (EBinOp ">=" (EVar "i") (EVar "outer")) (EVar "acc") (EApp (EApp (EApp (EApp (EVar "concatTotal") (EVar "arrs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (EApp (EVar "arrayLength") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arrs"))))) (EVar "outer"))))
(DTypeSig false "concatLookup" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyVar "a"))))))
(DFunDef false "concatLookup" ((PVar "arrs") (PVar "target") (PVar "k") (PVar "outer")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arrs"))) (DoLet false false (PVar "len") (EApp (EVar "arrayLength") (EVar "inner"))) (DoExpr (EIf (EBinOp "<" (EVar "target") (EVar "len")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "target")) (EVar "inner")) (EApp (EApp (EApp (EApp (EVar "concatLookup") (EVar "arrs")) (EBinOp "-" (EVar "target") (EVar "len"))) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "outer"))))))
(DTypeSig true "zip" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "b")) (TyApp (TyCon "Array") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "zip" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EMethodRef "min") (EApp (EVar "arrayLength") (EVar "a"))) (EApp (EVar "arrayLength") (EVar "b")))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (ETuple (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "b"))))))))
(DTypeSig true "zipWith" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "c")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "c")))))))
(DFunDef false "zipWith" ((PVar "f") (PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EMethodRef "min") (EApp (EVar "arrayLength") (EVar "a"))) (EApp (EVar "arrayLength") (EVar "b")))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "b"))))))))
(DTypeSig true "unzip" (TyFun (TyApp (TyCon "Array") (TyTuple (TyVar "a") (TyVar "b"))) (TyTuple (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "b")))))
(DFunDef false "unzip" ((PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (ETuple (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))) (EApp (EApp (EVar "arrayMakeWith") (EVar "n")) (ELam ((PVar "i")) (EApp (EVar "snd") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))))))
(DImpl true "Filterable" ((TyCon "Array")) () ((im "filterMap" ((PVar "f") (PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EApp (EVar "arrayFromList") (EApp (EApp (EVar "revList") (EApp (EApp (EApp (EApp (EApp (EVar "filterMapGo") (EVar "f")) (EVar "arr")) (ELit (LInt 0))) (EVar "n")) (EListLit))) (EListLit))))))))
(DTypeSig false "filterMapGo" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "b")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "b")))))))))
(DFunDef false "filterMapGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "filterMapStep") (EVar "f")) (EVar "arr")) (EVar "i")) (EVar "n")) (EVar "acc")) (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))))
(DTypeSig false "filterMapStep" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "b")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "b")) (TyFun (TyApp (TyCon "Option") (TyVar "b")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "b"))))))))))
(DFunDef false "filterMapStep" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n") (PVar "acc") (PCon "Some" (PVar "y"))) (EApp (EApp (EApp (EApp (EApp (EVar "filterMapGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "y") (EVar "acc"))))
(DFunDef false "filterMapStep" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n") (PVar "acc") (PCon "None")) (EApp (EApp (EApp (EApp (EApp (EVar "filterMapGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "acc")))
(DTypeSig false "revList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "revList" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "revList" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "revList") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig true "set" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "set" ((PVar "i") (PVar "x") (PVar "arr")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr")))) (EApp (EVar "panic") (ELit (LString "Array.set: index out of bounds"))) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "x")) (EVar "arr"))))
(DTypeSig true "swap" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "swap" ((PVar "i") (PVar "j") (PVar "arr")) (EBlock (DoLet false false (PVar "xi") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (DoLet false false (PVar "xj") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "xj")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EVar "xi")) (EVar "arr")))))
(DTypeSig true "fill" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "fill" ((PVar "x") (PVar "arr")) (EApp (EApp (EVar "arrayFill") (EVar "x")) (EVar "arr")))
(DTypeSig true "blit" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "blit" ((PVar "src") (PVar "srcOff") (PVar "dst") (PVar "dstOff") (PVar "len")) (EIf (EBinOp "<" (EVar "len") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "Array.blit: negative length"))) (EIf (EBinOp "<" (EVar "srcOff") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "Array.blit: negative srcOff"))) (EIf (EBinOp "<" (EVar "dstOff") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "Array.blit: negative dstOff"))) (EIf (EBinOp ">" (EBinOp "+" (EVar "srcOff") (EVar "len")) (EApp (EVar "arrayLength") (EVar "src"))) (EApp (EVar "panic") (ELit (LString "Array.blit: source out of bounds"))) (EIf (EBinOp ">" (EBinOp "+" (EVar "dstOff") (EVar "len")) (EApp (EVar "arrayLength") (EVar "dst"))) (EApp (EVar "panic") (ELit (LString "Array.blit: destination out of bounds"))) (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "src")) (EVar "srcOff")) (EVar "dst")) (EVar "dstOff")) (EVar "len"))))))))
(DTypeSig true "sortInPlaceBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "sortInPlaceBy" ((PVar "cmp") (PVar "arr")) (EBlock (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (EVar "cmp")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "sorted")) (ELit (LInt 0))) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))))
(DTypeSig true "sortInPlace" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "sortInPlace" ((PVar "arr")) (EApp (EApp (EVar "sortInPlaceBy") (EMethodRef "compare")) (EVar "arr")))
(DTypeSig true "sortBy" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a"))))))
(DFunDef false "sortBy" ((PVar "cmp") (PVar "arr")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "arr"))) (DoExpr (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 1))) (EApp (EVar "arrayCopy") (EVar "arr")) (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (DoLet false false (PVar "left") (EApp (EApp (EVar "arrayMakeWith") (EVar "mid")) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))) (DoLet false false (PVar "right") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "n") (EVar "mid"))) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "mid") (EVar "i"))) (EVar "arr"))))) (DoExpr (EApp (EApp (EApp (EVar "merge") (EVar "cmp")) (EApp (EApp (EVar "sortBy") (EVar "cmp")) (EVar "left"))) (EApp (EApp (EVar "sortBy") (EVar "cmp")) (EVar "right")))))))))
(DTypeSig true "sort" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a")))))
(DFunDef false "sort" ((PVar "arr")) (EApp (EApp (EVar "sortBy") (EMethodRef "compare")) (EVar "arr")))
(DTypeSig true "sortOn" (TyConstrained ((cstr "Ord" (TyVar "b"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a")))))))
(DFunDef false "sortOn" ((PVar "key") (PVar "arr")) (EBlock (DoLet false false (PVar "decorated") (EApp (EApp (EVar "arrayMakeWith") (EApp (EVar "arrayLength") (EVar "arr"))) (ELam ((PVar "i")) (ETuple (EApp (EVar "key") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))) (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (ELam ((PTuple (PVar "k1") PWild) (PTuple (PVar "k2") PWild)) (EApp (EApp (EMethodRef "compare") (EVar "k1")) (EVar "k2")))) (EVar "decorated"))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EApp (EVar "arrayLength") (EVar "sorted"))) (ELam ((PVar "i")) (EApp (EVar "snd") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "sorted"))))))))
(DTypeSig false "merge" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Array") (TyVar "a")))))))
(DFunDef false "merge" ((PVar "cmp") (PVar "left") (PVar "right")) (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeGo") (EVar "cmp")) (EVar "left")) (EVar "right")) (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "left"))) (EApp (EVar "arrayLength") (EVar "right"))) (EListLit))))
(DTypeSig false "mergeGo" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))))))))
(DFunDef false "mergeGo" ((PVar "cmp") (PVar "left") (PVar "right") (PVar "il") (PVar "ir") (PVar "nl") (PVar "nr") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "il") (EVar "nl")) (EBinOp ">=" (EVar "ir") (EVar "nr"))) (EApp (EApp (EVar "revList") (EVar "acc")) (EListLit)) (EIf (EBinOp ">=" (EVar "il") (EVar "nl")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeGo") (EVar "cmp")) (EVar "left")) (EVar "right")) (EVar "il")) (EBinOp "+" (EVar "ir") (ELit (LInt 1)))) (EVar "nl")) (EVar "nr")) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "ir")) (EVar "right")) (EVar "acc"))) (EIf (EBinOp ">=" (EVar "ir") (EVar "nr")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeGo") (EVar "cmp")) (EVar "left")) (EVar "right")) (EBinOp "+" (EVar "il") (ELit (LInt 1)))) (EVar "ir")) (EVar "nl")) (EVar "nr")) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "il")) (EVar "left")) (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeStep") (EVar "cmp")) (EVar "left")) (EVar "right")) (EVar "il")) (EVar "ir")) (EVar "nl")) (EVar "nr")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "mergeStep" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Ordering")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyVar "a"))))))))))))
(DFunDef false "mergeStep" ((PVar "cmp") (PVar "left") (PVar "right") (PVar "il") (PVar "ir") (PVar "nl") (PVar "nr") (PVar "acc")) (EMatch (EApp (EApp (EVar "cmp") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "il")) (EVar "left"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "ir")) (EVar "right"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeGo") (EVar "cmp")) (EVar "left")) (EVar "right")) (EVar "il")) (EBinOp "+" (EVar "ir") (ELit (LInt 1)))) (EVar "nl")) (EVar "nr")) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "ir")) (EVar "right")) (EVar "acc")))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mergeGo") (EVar "cmp")) (EVar "left")) (EVar "right")) (EBinOp "+" (EVar "il") (ELit (LInt 1)))) (EVar "ir")) (EVar "nl")) (EVar "nr")) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "il")) (EVar "left")) (EVar "acc"))))))
(DTypeSig false "foldGo" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b"))))))))
(DFunDef false "foldGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EApp (EVar "f") (EVar "acc")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))))
(DTypeSig false "foldRightGo" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))))))
(DFunDef false "foldRightGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EApp (EApp (EApp (EApp (EVar "foldRightGo") (EVar "f")) (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EVar "acc")))))
(DTypeSig true "find" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a"))))))
(DFunDef false "find" ((PVar "pred") (PVar "arr")) (EApp (EApp (EApp (EApp (EVar "findGo") (EVar "pred")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "findGo" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyVar "a"))))))))
(DFunDef false "findGo" ((PVar "pred") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EApp (EVar "pred") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EApp (EApp (EVar "findGo") (EVar "pred")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig true "findIndex" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "findIndex" ((PVar "pred") (PVar "arr")) (EApp (EApp (EApp (EApp (EVar "findIndexGo") (EVar "pred")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "findIndexGo" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyCon "Bool"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "findIndexGo" ((PVar "pred") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EApp (EVar "pred") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EApp (EApp (EVar "findIndexGo") (EVar "pred")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DImpl true "Mappable" ((TyCon "Array")) () ((im "map" ((PVar "f") (PVar "arr")) (EApp (EApp (EVar "arrayMakeWith") (EApp (EVar "arrayLength") (EVar "arr"))) (ELam ((PVar "i")) (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))))))))
(DImpl true "Foldable" ((TyCon "Array")) () ((im "fold" ((PVar "f") (PVar "z") (PVar "arr")) (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "z"))) (im "foldRight" ((PVar "f") (PVar "z") (PVar "arr")) (EApp (EApp (EApp (EApp (EVar "foldRightGo") (EVar "f")) (EVar "arr")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "z"))) (im "toList" ((PVar "arr")) (EApp (EApp (EApp (EVar "toListGo") (EVar "arr")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EListLit))) (im "isEmpty" ((PVar "arr")) (EBinOp "==" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 0)))) (im "length" ((PVar "arr")) (EApp (EVar "arrayLength") (EVar "arr")))))
(DImpl true "Semigroup" ((TyApp (TyCon "Array") (TyVar "a"))) () ((im "append" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "arrayMakeWith") (EBinOp "+" (EApp (EVar "arrayLength") (EVar "a")) (EApp (EVar "arrayLength") (EVar "b")))) (ELam ((PVar "i")) (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "a"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (EApp (EVar "arrayLength") (EVar "a")))) (EVar "b"))))))))
(DImpl true "Monoid" ((TyApp (TyCon "Array") (TyVar "a"))) () ((im "empty" () (EArrayLit))))
(DTypeSig false "isSortedArr" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "isSortedArr" ((PVar "arr")) (EApp (EApp (EApp (EDictApp "isSortedArrGo") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "isSortedArrGo" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "isSortedArrGo" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "True") (EIf (EApp (EApp (EMethodRef "lte") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "arr"))) (EApp (EApp (EApp (EDictApp "isSortedArrGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DProp false "sortBy ascending and length-preserving" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (EMethodRef "compare")) (EVar "arr"))) (DoExpr (EBinOp "&&" (EApp (EDictApp "isSortedArr") (EVar "sorted")) (EBinOp "==" (EApp (EMethodRef "length") (EVar "sorted")) (EApp (EMethodRef "length") (EVar "arr")))))))
(DProp false "sortBy idempotent" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (EMethodRef "compare")) (EVar "arr"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EVar "sorted")) (EApp (EApp (EVar "sortBy") (EMethodRef "compare")) (EVar "sorted"))))))
(DProp false "sortBy stable: equal keys preserve original order" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "fromList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "x")) (ETuple (ELit (LInt 0)) (EVar "x")))) (EVar "xs")))) (DoLet false false (PVar "sorted") (EApp (EApp (EVar "sortBy") (ELam ((PTuple (PVar "k1") PWild) (PTuple (PVar "k2") PWild)) (EApp (EApp (EMethodRef "compare") (EVar "k1")) (EVar "k2")))) (EVar "arr"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "sorted")))) (EVar "xs")))))
(DProp false "makeWith length" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "n'") (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n"))) (DoExpr (EBinOp "==" (EApp (EMethodRef "length") (EApp (EApp (EVar "makeWith") (EVar "n'")) (ELam ((PVar "i")) (EVar "i")))) (EVar "n'")))))
(DProp false "makeWith element at index 0" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "n'") (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LInt 1)) (EVar "n"))) (DoExpr (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EApp (EVar "makeWith") (EVar "n'")) (ELam ((PVar "i")) (EBinOp "+" (EBinOp "*" (EVar "i") (ELit (LInt 3))) (ELit (LInt 7)))))) (ELit (LInt 7))))))
