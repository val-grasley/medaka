# META
source_lines=649
stages=DESUGAR,MARK
# SOURCE
{- set.mdk — an immutable, ordered set of unique elements.

   See STDLIB.md (Module 5) for the plan.

   Design notes
   ────────────
   `Set a` is a *weight-balanced binary search tree* — the same Adams / Haskell
   `Data.Set` scheme as `map.mdk`, but storing only an element per node (no
   value). The invariants are identical:

     • search:   elements in the left subtree < node element < the right
     • balance:  neither subtree is more than `delta` (= 3) times the other

   maintained by the smart constructor `balance`. The structure is *persistent*
   (every op returns a fresh set sharing untouched subtrees), and ordering is by
   the element's `Ord`, so most operations carry an `Ord a` constraint while the
   pure walks (`size`, `toList`, the folds) do not.

   This is a standalone tree rather than a wrapper over `Map a Unit`: it keeps
   the module self-contained (no cross-module name clashes on `insert`/`union`/…)
   and avoids the per-node `Unit` payload. The balancing mirrors map.mdk's,
   which the property tests below re-verify. -}

-- set/map are identical weight-balanced-tree bodies over DISTINCT ADTs; consolidation needs a Set = Map _ Unit refactor (out of scope).
-- lint-disable-file rule-duplicate-body

import core.{
  Eq,
  Ord,
  Debug,
  Display,
  Foldable,
  Semigroup,
  Monoid,
  Ordering,
  Option,
  FromEntries,
}

{- The representation. `Tip` is the empty set; `Bin size elem left right` is an
   interior node whose cached `size` is `1 + size left + size right`. -}
public export data Set a = Tip | Bin Int a (Set a) (Set a)

-- ── Internal smart constructors (mirror map.mdk) ────────────────────────

bin : a -> Set a -> Set a -> Set a
bin x l r = Bin (size l + size r + 1) x l r

{- `balance` is `bin` plus a rebalancing check: when one subtree grows past
   `delta` (= 3) times the other, a single or double rotation (`ratio` = 2
   decides which) restores the weight invariant. -}
balance : a -> Set a -> Set a -> Set a
balance x l r
  | size l + size r <= 1 = bin x l r
  | size r > 3 * size l = rotateL x l r
  | size l > 3 * size r = rotateR x l r
  | otherwise = bin x l r

rotateL : a -> Set a -> Set a -> Set a
rotateL x l (r@(Bin _ _ rl rr)) =
  if size rl < 2 * size rr then
    singleL x l r
  else
    doubleL x l r
rotateL x l Tip = panic "Set.rotateL: empty right subtree"

rotateR : a -> Set a -> Set a -> Set a
rotateR x (l@(Bin _ _ ll lr)) r =
  if size lr < 2 * size ll then
    singleR x l r
  else
    doubleR x l r
rotateR x Tip r = panic "Set.rotateR: empty left subtree"

singleL : a -> Set a -> Set a -> Set a
singleL x1 t1 (Bin _ x2 t2 t3) = bin x2 (bin x1 t1 t2) t3
singleL x1 t1 Tip = panic "Set.singleL: empty right subtree"

singleR : a -> Set a -> Set a -> Set a
singleR x1 (Bin _ x2 t1 t2) t3 = bin x2 t1 (bin x1 t2 t3)
singleR x1 Tip t3 = panic "Set.singleR: empty left subtree"

doubleL : a -> Set a -> Set a -> Set a
doubleL x1 t1 (Bin _ x2 (Bin _ x3 t2 t3) t4) =
  bin x3 (bin x1 t1 t2) (bin x2 t3 t4)
doubleL x1 t1 _ = panic "Set.doubleL: malformed right subtree"

doubleR : a -> Set a -> Set a -> Set a
doubleR x1 (Bin _ x2 t1 (Bin _ x3 t2 t3)) t4 =
  bin x3 (bin x2 t1 t2) (bin x1 t3 t4)
doubleR x1 _ t4 = panic "Set.doubleR: malformed left subtree"

-- ── Construction ────────────────────────────────────────────────────────

{- The empty set is `Monoid.empty` (see `impl Monoid (Set a)` below); use `Tip`
   internally. -}

{- | A set with a single element.

   > size (singleton 5)
   1 -}
export singleton : a -> Set a
singleton x = Bin 1 x Tip Tip

{- | Build a set from a list, dropping duplicates.

   The `Set { x, … }` literal is sugar for `fromList` (it lowers to a
   `FromEntries` dispatch pinned at `Set`, see the impl at the bottom):

   > size (Set { 1, 2, 3, 2, 1 })
   3
   > toList (fromList [3, 1, 2, 3, 1])
   [1, 2, 3]

   The empty literal `Set { }` works too (Phase 114); annotate to fix the
   element type the empty braces leave open:

   > size (Set { } : Set Int)
   0 -}
export fromList : Ord a => List a -> Set a
fromList xs = fold (s x => insert x s) Tip xs

-- ── Query ───────────────────────────────────────────────────────────────

{- | Number of elements. O(1) — read off the root's cached size.

   > size (fromList [1, 2, 3, 2])
   3 -}
export size : Set a -> Int
size Tip = 0
size (Bin s _ _ _) = s

{- | `True` when the element is present.

   > has 2 (fromList [1, 2, 3])
   True
   > has 9 (fromList [1, 2, 3])
   False -}
export has : Ord a => a -> Set a -> Bool
has x Tip = False
has x (Bin _ y l r) = match compare x y
  Lt => has x l
  Gt => has x r
  Eq => True

-- ── Insertion / deletion ────────────────────────────────────────────────

{- | Insert an element. A no-op (structurally) when already present.

   > size (insert 2 (fromList [1, 2, 3]))
   3
   > size (insert 9 (fromList [1, 2, 3]))
   4 -}
export insert : Ord a => a -> Set a -> Set a
insert x Tip = singleton x
insert x (Bin s y l r) = match compare x y
  Lt => balance y (insert x l) r
  Gt => balance y l (insert x r)
  Eq => Bin s x l r

{- | Remove an element. A no-op when absent.

   > has 2 (delete 2 (fromList [1, 2, 3]))
   False

   Deleting an absent element leaves the set unchanged:

   > toList (delete 9 (fromList [1, 2, 3]))
   [1, 2, 3]
   > size (delete 9 (fromList [1, 2, 3]))
   3 -}
export delete : Ord a => a -> Set a -> Set a
delete x Tip = Tip
delete x (Bin _ y l r) = match compare x y
  Lt => balance y (delete x l) r
  Gt => balance y l (delete x r)
  Eq => glue l r

{- `glue` joins two subtrees that were siblings under a now-deleted node (every
   element on the left below every element on the right), promoting the max of
   the larger side (or the min of the other) to keep the result balanced. -}
glue : Set a -> Set a -> Set a
glue Tip r = r
glue l Tip = l
glue l r
  | size l > size r = glueMax l r
  | otherwise = glueMin l r

glueMax : Set a -> Set a -> Set a
glueMax l r = match maxView l
  None => r
  Some (x, l') => balance x l' r

glueMin : Set a -> Set a -> Set a
glueMin l r = match minView r
  None => l
  Some (x, r') => balance x l r'

-- ── Min / max ───────────────────────────────────────────────────────────

{- | Split off the smallest element: `Some (elem, rest)`, or `None` when empty.

   > minView (Set { } : Set Int)
   None -}
export minView : Set a -> Option (a, Set a)
minView Tip = None
minView (Bin _ x l r) = match minView l
  None => Some (x, r)
  Some (xm, l') => Some (xm, balance x l' r)

{- | Split off the largest element: `Some (elem, rest)`, or `None`.

   > maxView (Set { } : Set Int)
   None -}
export maxView : Set a -> Option (a, Set a)
maxView Tip = None
maxView (Bin _ x l r) = match maxView r
  None => Some (x, l)
  Some (xm, r') => Some (xm, balance x l r')

{- | Smallest element, or `None`.

   > getMin (fromList [3, 1, 2])
   Some 1 -}
export getMin : Set a -> Option a
getMin s = map ((x, _) => x) (minView s)

{- | Largest element, or `None`.

   > getMax (fromList [3, 1, 2])
   Some 3 -}
export getMax : Set a -> Option a
getMax s = map ((x, _) => x) (maxView s)

{- | Drop the smallest element (a no-op on the empty set).

   > toList (deleteMin (fromList [3, 1, 2]))
   [2, 3] -}
export deleteMin : Set a -> Set a
deleteMin s = match minView s
  None => Tip
  Some (_, s') => s'

{- | Drop the largest element (a no-op on the empty set).

   > toList (deleteMax (fromList [3, 1, 2]))
   [1, 2] -}
export deleteMax : Set a -> Set a
deleteMax s = match maxView s
  None => Tip
  Some (_, s') => s'

-- ── Folds (ascending element order) ─────────────────────────────────────

foldrSet : (a -> b -> <e> b) -> b -> Set a -> <e> b
foldrSet f z Tip = z
foldrSet f z (Bin _ x l r) = foldrSet f (f x (foldrSet f z r)) l

foldlSet : (b -> a -> <e> b) -> b -> Set a -> <e> b
foldlSet f z Tip = z
foldlSet f z (Bin _ x l r) = foldlSet f (f (foldlSet f z l) x) r

-- ── Split / join ────────────────────────────────────────────────────────

{- The join-based kit (Adams 1992; Blelloch, Ferizovic & Sun 2016) — the mirror
   of the one in map.mdk; see that module for the full rationale.  `balance`
   above only repairs a one-element imbalance, which is all an insert or delete
   can create; combining two whole sets needs primitives that cope with
   subtrees of wildly different weights:

     • `link x l r` — rebuild `l < x < r` into one balanced set, any weights.
     • `link2 l r`  — the same without a dividing element, for when that
                      element is being dropped (`difference`).

   With `splitAt`, every operation below divides and conquers over the tree
   *structure* rather than re-inserting every element one at a time. -}

insertMin : a -> Set a -> Set a
insertMin x Tip = singleton x
insertMin x (Bin _ y l r) = balance y (insertMin x l) r

insertMax : a -> Set a -> Set a
insertMax x Tip = singleton x
insertMax x (Bin _ y l r) = balance y l (insertMax x r)

-- Join `l < x < r` for arbitrarily unbalanced `l`/`r`: descend the heavy side
-- until the weights are within `delta`, rebalancing on the way out.
link : a -> Set a -> Set a -> Set a
link x Tip r = insertMin x r
link x l Tip = insertMax x l
link x (l@(Bin sl xl ll rl)) (r@(Bin sr xr lr rr))
  | 3 * sl < sr = balance xr (link x l lr) rr
  | 3 * sr < sl = balance xl ll (link x rl r)
  | otherwise = bin x l r

-- `link` with no dividing element — every element of `l` is below every
-- element of `r`.  Falls back to `glue` once the weights are comparable.
link2 : Set a -> Set a -> Set a
link2 Tip r = r
link2 l Tip = l
link2 (l@(Bin sl xl ll rl)) (r@(Bin sr xr lr rr))
  | 3 * sl < sr = balance xr (link2 l lr) rr
  | 3 * sr < sl = balance xl ll (link2 rl r)
  | otherwise = glue l r

-- Split a set around an element: everything below it, everything above it.
-- The element itself (if present) is dropped -- `splitMember` reports it.
splitAt : Ord a => a -> Set a -> (Set a, Set a)
splitAt x Tip = (Tip, Tip)
splitAt x (Bin _ y l r) = match compare x y
  Lt =>
    let (below, above) = splitAt x l
    (below, link y above r)
  Gt =>
    let (below, above) = splitAt x r
    (link y l below, above)
  Eq => (l, r)

-- `splitAt` that also reports whether the split element was present.
splitMember : Ord a => a -> Set a -> (Set a, Bool, Set a)
splitMember x Tip = (Tip, False, Tip)
splitMember x (Bin _ y l r) = match compare x y
  Lt =>
    let (below, found, above) = splitMember x l
    (below, found, link y above r)
  Gt =>
    let (below, found, above) = splitMember x r
    (link y l below, found, above)
  Eq => (l, True, r)

-- ── Set algebra ─────────────────────────────────────────────────────────

{- | Union — every element in either set.

   > toList (union (fromList [1, 2]) (fromList [2, 3]))
   [1, 2, 3]

   Disjoint operands keep every element of both; a subset operand adds nothing:

   > toList (union (fromList [1, 2]) (fromList [3, 4]))
   [1, 2, 3, 4]
   > toList (union (fromList [1, 2, 3]) (fromList [2]))
   [1, 2, 3] -}
export union : Ord a => Set a -> Set a -> Set a
union Tip b = b
union a Tip = a
union (Bin _ x l r) b =
  let (bl, br) = splitAt x b
  -- `x`'s counterpart in `b` was dropped by `splitAt`, so the left set wins.
  link x (union l bl) (union r br)

{- | Intersection — elements in both sets.

   > toList (intersection (fromList [1, 2, 3]) (fromList [2, 3, 4]))
   [2, 3]

   Disjoint operands intersect to empty; a subset operand is its own intersection:

   > toList (intersection (fromList [1, 2]) (fromList [3, 4]))
   []
   > toList (intersection (fromList [1, 2, 3]) (fromList [2]))
   [2] -}
export intersection : Ord a => Set a -> Set a -> Set a
intersection Tip b = Tip
intersection a Tip = Tip
intersection (Bin _ x l r) b =
  let (bl, found, br) = splitMember x b
  let l2 = intersection l bl
  let r2 = intersection r br
  if found then link x l2 r2 else link2 l2 r2

{- | Difference — elements in the first set but not the second.

   > toList (difference (fromList [1, 2, 3]) (fromList [2]))
   [1, 3]

   Subtracting a disjoint set changes nothing; subtracting a superset empties it:

   > toList (difference (fromList [1, 2]) (fromList [3, 4]))
   [1, 2]
   > toList (difference (fromList [1, 2, 3]) (fromList [1, 2, 3]))
   [] -}
export difference : Ord a => Set a -> Set a -> Set a
difference Tip b = Tip
difference a Tip = a
difference a (Bin _ x l r) =
  let (al, ar) = splitAt x a
  -- `splitAt` already dropped `x` from both halves, so it is simply not rebuilt.
  link2 (difference al l) (difference ar r)

{- | `True` when every element of the first set is in the second.

   > isSubsetOf (fromList [1, 2]) (fromList [1, 2, 3])
   True
   > isSubsetOf (fromList [1, 4]) (fromList [1, 2, 3])
   False -}
export isSubsetOf : Ord a => Set a -> Set a -> Bool
isSubsetOf a b = size a <= size b && subsetGo a b

{- The size test above is an O(1) reject that settles the commonest `False`.
   Past it, `subsetGo` splits `b` around `a`'s root and recurses -- so a missing
   element aborts the whole walk through `&&` instead of being folded over the
   rest of `a`.  (The old `foldrSet (x acc => acc && has x b) True a`
   short-circuited each individual `has`, but the fold still visited every
   element of `a` after the answer was already known.)  Splitting also shrinks
   `b` on the way down, giving O(|a|·log(|b|/|a| + 1)) rather than a fixed
   O(|a|·log|b|). -}
subsetGo : Ord a => Set a -> Set a -> Bool
subsetGo Tip b = True
subsetGo a Tip = False
subsetGo (Bin _ x l r) b =
  let (bl, found, br) = splitMember x b
  found && subsetGo l bl && subsetGo r br

-- ── Typeclass instances ─────────────────────────────────────────────────

{- | `Foldable Set` folds over elements in ascending order — so `toList`,
   `length`, `elem`, `sum`, `maximum`, `any`/`all`, … all work on a set. (Unlike
   `Map`, whose `toList` means pairs, a set's elements *are* its `toList`, so the
   Foldable methods carry the natural meaning and there's no name clash.)

   > toList (fromList [3, 1, 2, 1])
   [1, 2, 3]
   > length (fromList [3, 1, 2, 1])
   3 -}
export impl Foldable Set where
  fold f z s = foldlSet f z s
  foldRight f z s = foldrSet f z s
  toList s = foldrSet (::) [] s
  isEmpty Tip = True
  isEmpty _ = False
  length s = size s

{- | Structural equality: same elements (compared through the canonical
   ascending element list, so tree *shape* doesn't matter).

   > eq (fromList [1, 2, 3]) (fromList [3, 2, 1, 2])
   True -}
export impl Eq (Set a) requires Eq a where
  eq a b = if size a != size b then False else eq (toList a) (toList b)

{- | Lexicographic ordering through the canonical ascending element list, so a
   proper prefix sorts first.  Enables nesting (`Set (Set a)`, `Map (Set a) v`).

   > compare (fromList [1, 2]) (fromList [1, 3])
   Lt -}
export impl Ord (Set a) requires Ord a where
  compare a b = compare (toList a) (toList b)

{- | Rendered as `fromList [a, …]`, the re-evaluable form (the `Set { … }`
   literal is the *display* form — see PLAN.md Phase 111). Doctest compares
   against a literal: `Debug String` is out of this module's test context.

   > debug (fromList [1, 2, 3]) == "fromList [1, 2, 3]"
   True -}
export impl Debug (Set a) requires Debug a where
  debug s = "fromList \{debug (toList s)}"

-- Comma-joined elements for `Display (Set a)`; renders via `display` (unquoted).
displaySetItems : Display a => List a -> String
displaySetItems [] = ""
displaySetItems [x] = "\{x}"
displaySetItems (y::rest) = "\{y}, \{displaySetItems rest}"

{- | The *display* form — the Phase-108 literal `Set { x, … }` (empty →
   `Set {}`), as opposed to Debug's re-evaluable `fromList [x, …]`.

   > display (fromList [1, 2, 3]) == "Set { 1, 2, 3 }"
   True
   > display (empty : Set Int) == "Set {}"
   True -}
export impl Display (Set a) requires Display a where
  display s = match toList s
    [] => "Set {}"
    xs => "Set { \{displaySetItems xs} }"

{- | `++` on sets is union; `append` dispatches on its first `Set` argument, so
   the `Ord a` it needs threads in by the ordinary route. -}
export impl Semigroup (Set a) requires Ord a where
  append a b = union a b

{- | Backs the `Set { x, … }` literal: the compiler lowers that to
   `fromEntries [x, …]` pinned at `Set`, dispatching here. -}
export impl FromEntries (Set a) a requires Ord a where
  fromEntries es = fromList es

{- | `Monoid.empty` for `Set` is the empty tree (nullary, dispatched on its
   result type; Phase 103). `Tip` needs no dict, so it grounds cleanly.

   > isEmpty (empty : Set Int)
   True -}
export impl Monoid (Set a) requires Ord a where
  empty = Tip

-- ── Structural invariants (for testing / debugging) ─────────────────────

{- | Check the structural invariants at every node: search-tree order
   (left < node < right), the cached `size`, and the weight-balance bound.
   A correct sequence of operations always leaves a set `wellFormed`.

   > wellFormed (fromList [5, 3, 8, 1, 4, 7, 9, 2, 6])
   True
   > wellFormed (Set { } : Set Int)
   True -}
export wellFormed : Ord a => Set a -> Bool
wellFormed Tip = True
wellFormed (Bin s x l r) =
  let sizeOk = size l + size r + 1 == s
  let orderOk = allElems (e => lt e x) l && allElems (e => gt e x) r
  sizeOk && balancedAt l r && orderOk && wellFormed l && wellFormed r

allElems : (a -> Bool) -> Set a -> Bool
allElems p Tip = True
allElems p (Bin _ x l r) = p x && allElems p l && allElems p r

balancedAt : Set a -> Set a -> Bool
balancedAt l r =
  let sl = size l
  let sr = size r
  if sl + sr <= 1 then True else sl <= 3 * sr && sr <= 3 * sl

ascending : Ord a => List a -> Bool
ascending [] = True
ascending [x] = True
ascending (x::y::rest) = lt x y && ascending (y::rest)

-- ── Properties ──────────────────────────────────────────────────────────

prop "fromList builds a well-formed tree" (xs : List Int) =
  wellFormed (fromList xs)

prop "elements come out strictly ascending (sorted, deduped)" (xs : List Int) =
  ascending (toList (fromList xs))

prop "insert then member" (x : Int) (xs : List Int) =
  has x (insert x (fromList xs))

prop "insert preserves well-formedness" (x : Int) (xs : List Int) =
  wellFormed (insert x (fromList xs))

prop "delete removes the element and preserves well-formedness" (x : Int) (xs : List Int) =
  let s = delete x (fromList xs)
  not (has x s) && wellFormed s

prop "union preserves well-formedness" (xs : List Int) (ys : List Int) =
  wellFormed (union (fromList xs) (fromList ys))

prop "intersection elements are in both sets" (xs : List Int) (ys : List Int) =
  let a = fromList xs
  let b = fromList ys
  foldrSet (e acc => acc && has e a && has e b) True (intersection a b)

prop "intersection preserves well-formedness" (xs : List Int) (ys : List Int) =
  wellFormed (intersection (fromList xs) (fromList ys))

prop "difference elements are in the first but not the second" (xs : List Int) (ys : List Int) =
  let a = fromList xs
  let b = fromList ys
  foldrSet (e acc => acc && has e a && not (has e b)) True (difference a b)

prop "difference preserves well-formedness" (xs : List Int) (ys : List Int) =
  wellFormed (difference (fromList xs) (fromList ys))

prop "union is commutative on the sorted element list" (xs : List Int) (ys : List Int) =
  let a = fromList xs
  let b = fromList ys
  eq (toList (union a b)) (toList (union b a))

prop "size of a union is at most the sum of sizes" (xs : List Int) (ys : List Int) =
  let a = fromList xs
  let b = fromList ys
  size (union a b) <= size a + size b

prop "difference elements stay in the first set" (xs : List Int) (ys : List Int) =
  let a = fromList xs
  let b = fromList ys
  foldrSet (e acc => acc && has e a) True (difference a b)

prop "deleting a member removes it" (x : Int) (xs : List Int) =
  not (has x (delete x (insert x (fromList xs))))

{- The naive fold-insert bodies the join-based set algebra replaced (#423).
   Obviously correct and obviously slow, which makes them the differential
   oracle for the fast versions: the properties below assert the two agree
   element-for-element on random inputs.  A join-based operation that silently
   corrupted the weight-balance invariant would still answer every doctest
   correctly, so `wellFormed` is asserted alongside each one. -}

naiveUnion : Ord a => Set a -> Set a -> Set a
naiveUnion a b = foldrSet (x acc => insert x acc) b a

naiveIntersection : Ord a => Set a -> Set a -> Set a
naiveIntersection a b = foldrSet (naiveIntersectStep b) Tip a

naiveIntersectStep : Ord a => Set a -> a -> Set a -> Set a
naiveIntersectStep b x acc = if has x b then insert x acc else acc

naiveDifference : Ord a => Set a -> Set a -> Set a
naiveDifference a b = foldrSet (x acc => delete x acc) a b

naiveIsSubsetOf : Ord a => Set a -> Set a -> Bool
naiveIsSubsetOf a b = foldrSet (x acc => acc && has x b) True a

prop "union agrees with naive fold-insert and stays well-formed" (xs : List Int) (ys : List Int) =
  let a = fromList xs
  let b = fromList ys
  let got = union a b
  eq (toList got) (toList (naiveUnion a b)) && wellFormed got

prop "union elements stay strictly ascending" (xs : List Int) (ys : List Int) =
  ascending (toList (union (fromList xs) (fromList ys)))

prop "intersection agrees with naive and stays well-formed" (xs : List Int) (ys : List Int) =
  let a = fromList xs
  let b = fromList ys
  let got = intersection a b
  eq (toList got) (toList (naiveIntersection a b)) && wellFormed got

prop "difference agrees with naive and stays well-formed" (xs : List Int) (ys : List Int) =
  let a = fromList xs
  let b = fromList ys
  let got = difference a b
  eq (toList got) (toList (naiveDifference a b)) && wellFormed got

prop "isSubsetOf agrees with the naive fold" (xs : List Int) (ys : List Int) =
  let a = fromList xs
  let b = fromList ys
  eq (isSubsetOf a b) (naiveIsSubsetOf a b)

prop "a subset of a union is recognised" (xs : List Int) (ys : List Int) =
  let a = fromList xs
  isSubsetOf a (union a (fromList ys))

prop "splitAt partitions around the element and both halves stay well-formed" (x : Int) (xs : List Int) =
  let (below, above) = splitAt x (fromList xs)
  wellFormed below
    && wellFormed above
    && allElems (b => lt b x) below
    && allElems (a => gt a x) above

prop "link rebuilds a well-formed set from a split" (x : Int) (xs : List Int) =
  let (below, above) = splitAt x (fromList xs)
  let rebuilt = link x below above
  wellFormed rebuilt && has x rebuilt

prop "link2 rejoins a split without its element" (x : Int) (xs : List Int) =
  let (below, above) = splitAt x (fromList xs)
  let rebuilt = link2 below above
  wellFormed rebuilt && eq (toList rebuilt) (toList (delete x (fromList xs)))
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Foldable" false) (mem "Semigroup" false) (mem "Monoid" false) (mem "Ordering" false) (mem "Option" false) (mem "FromEntries" false))))
(DData Public "Set" ("a") ((variant "Tip" (ConPos)) (variant "Bin" (ConPos (TyCon "Int") (TyVar "a") (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))) ())
(DTypeSig false "bin" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "bin" ((PVar "x") (PVar "l") (PVar "r")) (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1)))) (EVar "x")) (EVar "l")) (EVar "r")))
(DTypeSig false "balance" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "balance" ((PVar "x") (PVar "l") (PVar "r")) (EIf (EBinOp "<=" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1))) (EApp (EApp (EApp (EVar "bin") (EVar "x")) (EVar "l")) (EVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "r")) (EBinOp "*" (ELit (LInt 3)) (EApp (EVar "size") (EVar "l")))) (EApp (EApp (EApp (EVar "rotateL") (EVar "x")) (EVar "l")) (EVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "l")) (EBinOp "*" (ELit (LInt 3)) (EApp (EVar "size") (EVar "r")))) (EApp (EApp (EApp (EVar "rotateR") (EVar "x")) (EVar "l")) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "bin") (EVar "x")) (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "rotateL" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "rotateL" ((PVar "x") (PVar "l") (PAs "r" (PCon "Bin" PWild PWild (PVar "rl") (PVar "rr")))) (EIf (EBinOp "<" (EApp (EVar "size") (EVar "rl")) (EBinOp "*" (ELit (LInt 2)) (EApp (EVar "size") (EVar "rr")))) (EApp (EApp (EApp (EVar "singleL") (EVar "x")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EVar "doubleL") (EVar "x")) (EVar "l")) (EVar "r"))))
(DFunDef false "rotateL" ((PVar "x") (PVar "l") (PCon "Tip")) (EApp (EVar "panic") (ELit (LString "Set.rotateL: empty right subtree"))))
(DTypeSig false "rotateR" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "rotateR" ((PVar "x") (PAs "l" (PCon "Bin" PWild PWild (PVar "ll") (PVar "lr"))) (PVar "r")) (EIf (EBinOp "<" (EApp (EVar "size") (EVar "lr")) (EBinOp "*" (ELit (LInt 2)) (EApp (EVar "size") (EVar "ll")))) (EApp (EApp (EApp (EVar "singleR") (EVar "x")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EVar "doubleR") (EVar "x")) (EVar "l")) (EVar "r"))))
(DFunDef false "rotateR" ((PVar "x") (PCon "Tip") (PVar "r")) (EApp (EVar "panic") (ELit (LString "Set.rotateR: empty left subtree"))))
(DTypeSig false "singleL" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "singleL" ((PVar "x1") (PVar "t1") (PCon "Bin" PWild (PVar "x2") (PVar "t2") (PVar "t3"))) (EApp (EApp (EApp (EVar "bin") (EVar "x2")) (EApp (EApp (EApp (EVar "bin") (EVar "x1")) (EVar "t1")) (EVar "t2"))) (EVar "t3")))
(DFunDef false "singleL" ((PVar "x1") (PVar "t1") (PCon "Tip")) (EApp (EVar "panic") (ELit (LString "Set.singleL: empty right subtree"))))
(DTypeSig false "singleR" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "singleR" ((PVar "x1") (PCon "Bin" PWild (PVar "x2") (PVar "t1") (PVar "t2")) (PVar "t3")) (EApp (EApp (EApp (EVar "bin") (EVar "x2")) (EVar "t1")) (EApp (EApp (EApp (EVar "bin") (EVar "x1")) (EVar "t2")) (EVar "t3"))))
(DFunDef false "singleR" ((PVar "x1") (PCon "Tip") (PVar "t3")) (EApp (EVar "panic") (ELit (LString "Set.singleR: empty left subtree"))))
(DTypeSig false "doubleL" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "doubleL" ((PVar "x1") (PVar "t1") (PCon "Bin" PWild (PVar "x2") (PCon "Bin" PWild (PVar "x3") (PVar "t2") (PVar "t3")) (PVar "t4"))) (EApp (EApp (EApp (EVar "bin") (EVar "x3")) (EApp (EApp (EApp (EVar "bin") (EVar "x1")) (EVar "t1")) (EVar "t2"))) (EApp (EApp (EApp (EVar "bin") (EVar "x2")) (EVar "t3")) (EVar "t4"))))
(DFunDef false "doubleL" ((PVar "x1") (PVar "t1") PWild) (EApp (EVar "panic") (ELit (LString "Set.doubleL: malformed right subtree"))))
(DTypeSig false "doubleR" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "doubleR" ((PVar "x1") (PCon "Bin" PWild (PVar "x2") (PVar "t1") (PCon "Bin" PWild (PVar "x3") (PVar "t2") (PVar "t3"))) (PVar "t4")) (EApp (EApp (EApp (EVar "bin") (EVar "x3")) (EApp (EApp (EApp (EVar "bin") (EVar "x2")) (EVar "t1")) (EVar "t2"))) (EApp (EApp (EApp (EVar "bin") (EVar "x1")) (EVar "t3")) (EVar "t4"))))
(DFunDef false "doubleR" ((PVar "x1") PWild (PVar "t4")) (EApp (EVar "panic") (ELit (LString "Set.doubleR: malformed left subtree"))))
(DTypeSig true "singleton" (TyFun (TyVar "a") (TyApp (TyCon "Set") (TyVar "a"))))
(DFunDef false "singleton" ((PVar "x")) (EApp (EApp (EApp (EApp (EVar "Bin") (ELit (LInt 1))) (EVar "x")) (EVar "Tip")) (EVar "Tip")))
(DTypeSig true "fromList" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))
(DFunDef false "fromList" ((PVar "xs")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "s") (PVar "x")) (EApp (EApp (EVar "insert") (EVar "x")) (EVar "s")))) (EVar "Tip")) (EVar "xs")))
(DTypeSig true "size" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Int")))
(DFunDef false "size" ((PCon "Tip")) (ELit (LInt 0)))
(DFunDef false "size" ((PCon "Bin" (PVar "s") PWild PWild PWild)) (EVar "s"))
(DTypeSig true "has" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "has" ((PVar "x") (PCon "Tip")) (EVar "False"))
(DFunDef false "has" ((PVar "x") (PCon "Bin" PWild (PVar "y") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EApp (EApp (EVar "has") (EVar "x")) (EVar "l"))) (arm (PCon "Gt") () (EApp (EApp (EVar "has") (EVar "x")) (EVar "r"))) (arm (PCon "Eq") () (EVar "True"))))
(DTypeSig true "insert" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "insert" ((PVar "x") (PCon "Tip")) (EApp (EVar "singleton") (EVar "x")))
(DFunDef false "insert" ((PVar "x") (PCon "Bin" (PVar "s") (PVar "y") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EApp (EApp (EApp (EVar "balance") (EVar "y")) (EApp (EApp (EVar "insert") (EVar "x")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EVar "balance") (EVar "y")) (EVar "l")) (EApp (EApp (EVar "insert") (EVar "x")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "x")) (EVar "l")) (EVar "r")))))
(DTypeSig true "delete" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "delete" ((PVar "x") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "delete" ((PVar "x") (PCon "Bin" PWild (PVar "y") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EApp (EApp (EApp (EVar "balance") (EVar "y")) (EApp (EApp (EVar "delete") (EVar "x")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EVar "balance") (EVar "y")) (EVar "l")) (EApp (EApp (EVar "delete") (EVar "x")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EVar "glue") (EVar "l")) (EVar "r")))))
(DTypeSig false "glue" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))
(DFunDef false "glue" ((PCon "Tip") (PVar "r")) (EVar "r"))
(DFunDef false "glue" ((PVar "l") (PCon "Tip")) (EVar "l"))
(DFunDef false "glue" ((PVar "l") (PVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (EApp (EApp (EVar "glueMax") (EVar "l")) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EVar "glueMin") (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "glueMax" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))
(DFunDef false "glueMax" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "maxView") (EVar "l")) (arm (PCon "None") () (EVar "r")) (arm (PCon "Some" (PTuple (PVar "x") (PVar "l'"))) () (EApp (EApp (EApp (EVar "balance") (EVar "x")) (EVar "l'")) (EVar "r")))))
(DTypeSig false "glueMin" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))
(DFunDef false "glueMin" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "minView") (EVar "r")) (arm (PCon "None") () (EVar "l")) (arm (PCon "Some" (PTuple (PVar "x") (PVar "r'"))) () (EApp (EApp (EApp (EVar "balance") (EVar "x")) (EVar "l")) (EVar "r'")))))
(DTypeSig true "minView" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Option") (TyTuple (TyVar "a") (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "minView" ((PCon "Tip")) (EVar "None"))
(DFunDef false "minView" ((PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r"))) (EMatch (EApp (EVar "minView") (EVar "l")) (arm (PCon "None") () (EApp (EVar "Some") (ETuple (EVar "x") (EVar "r")))) (arm (PCon "Some" (PTuple (PVar "xm") (PVar "l'"))) () (EApp (EVar "Some") (ETuple (EVar "xm") (EApp (EApp (EApp (EVar "balance") (EVar "x")) (EVar "l'")) (EVar "r")))))))
(DTypeSig true "maxView" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Option") (TyTuple (TyVar "a") (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "maxView" ((PCon "Tip")) (EVar "None"))
(DFunDef false "maxView" ((PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r"))) (EMatch (EApp (EVar "maxView") (EVar "r")) (arm (PCon "None") () (EApp (EVar "Some") (ETuple (EVar "x") (EVar "l")))) (arm (PCon "Some" (PTuple (PVar "xm") (PVar "r'"))) () (EApp (EVar "Some") (ETuple (EVar "xm") (EApp (EApp (EApp (EVar "balance") (EVar "x")) (EVar "l")) (EVar "r'")))))))
(DTypeSig true "getMin" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "getMin" ((PVar "s")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "x") PWild)) (EVar "x"))) (EApp (EVar "minView") (EVar "s"))))
(DTypeSig true "getMax" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "getMax" ((PVar "s")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "x") PWild)) (EVar "x"))) (EApp (EVar "maxView") (EVar "s"))))
(DTypeSig true "deleteMin" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))
(DFunDef false "deleteMin" ((PVar "s")) (EMatch (EApp (EVar "minView") (EVar "s")) (arm (PCon "None") () (EVar "Tip")) (arm (PCon "Some" (PTuple PWild (PVar "s'"))) () (EVar "s'"))))
(DTypeSig true "deleteMax" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))
(DFunDef false "deleteMax" ((PVar "s")) (EMatch (EApp (EVar "maxView") (EVar "s")) (arm (PCon "None") () (EVar "Tip")) (arm (PCon "Some" (PTuple PWild (PVar "s'"))) () (EVar "s'"))))
(DTypeSig false "foldrSet" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldrSet" ((PVar "f") (PVar "z") (PCon "Tip")) (EVar "z"))
(DFunDef false "foldrSet" ((PVar "f") (PVar "z") (PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "foldrSet") (EVar "f")) (EApp (EApp (EVar "f") (EVar "x")) (EApp (EApp (EApp (EVar "foldrSet") (EVar "f")) (EVar "z")) (EVar "r")))) (EVar "l")))
(DTypeSig false "foldlSet" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldlSet" ((PVar "f") (PVar "z") (PCon "Tip")) (EVar "z"))
(DFunDef false "foldlSet" ((PVar "f") (PVar "z") (PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "foldlSet") (EVar "f")) (EApp (EApp (EVar "f") (EApp (EApp (EApp (EVar "foldlSet") (EVar "f")) (EVar "z")) (EVar "l"))) (EVar "x"))) (EVar "r")))
(DTypeSig false "insertMin" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))
(DFunDef false "insertMin" ((PVar "x") (PCon "Tip")) (EApp (EVar "singleton") (EVar "x")))
(DFunDef false "insertMin" ((PVar "x") (PCon "Bin" PWild (PVar "y") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "balance") (EVar "y")) (EApp (EApp (EVar "insertMin") (EVar "x")) (EVar "l"))) (EVar "r")))
(DTypeSig false "insertMax" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))
(DFunDef false "insertMax" ((PVar "x") (PCon "Tip")) (EApp (EVar "singleton") (EVar "x")))
(DFunDef false "insertMax" ((PVar "x") (PCon "Bin" PWild (PVar "y") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "balance") (EVar "y")) (EVar "l")) (EApp (EApp (EVar "insertMax") (EVar "x")) (EVar "r"))))
(DTypeSig false "link" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "link" ((PVar "x") (PCon "Tip") (PVar "r")) (EApp (EApp (EVar "insertMin") (EVar "x")) (EVar "r")))
(DFunDef false "link" ((PVar "x") (PVar "l") (PCon "Tip")) (EApp (EApp (EVar "insertMax") (EVar "x")) (EVar "l")))
(DFunDef false "link" ((PVar "x") (PAs "l" (PCon "Bin" (PVar "sl") (PVar "xl") (PVar "ll") (PVar "rl"))) (PAs "r" (PCon "Bin" (PVar "sr") (PVar "xr") (PVar "lr") (PVar "rr")))) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sl")) (EVar "sr")) (EApp (EApp (EApp (EVar "balance") (EVar "xr")) (EApp (EApp (EApp (EVar "link") (EVar "x")) (EVar "l")) (EVar "lr"))) (EVar "rr")) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sr")) (EVar "sl")) (EApp (EApp (EApp (EVar "balance") (EVar "xl")) (EVar "ll")) (EApp (EApp (EApp (EVar "link") (EVar "x")) (EVar "rl")) (EVar "r"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "bin") (EVar "x")) (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "link2" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))
(DFunDef false "link2" ((PCon "Tip") (PVar "r")) (EVar "r"))
(DFunDef false "link2" ((PVar "l") (PCon "Tip")) (EVar "l"))
(DFunDef false "link2" ((PAs "l" (PCon "Bin" (PVar "sl") (PVar "xl") (PVar "ll") (PVar "rl"))) (PAs "r" (PCon "Bin" (PVar "sr") (PVar "xr") (PVar "lr") (PVar "rr")))) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sl")) (EVar "sr")) (EApp (EApp (EApp (EVar "balance") (EVar "xr")) (EApp (EApp (EVar "link2") (EVar "l")) (EVar "lr"))) (EVar "rr")) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sr")) (EVar "sl")) (EApp (EApp (EApp (EVar "balance") (EVar "xl")) (EVar "ll")) (EApp (EApp (EVar "link2") (EVar "rl")) (EVar "r"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "glue") (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "splitAt" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyTuple (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))))
(DFunDef false "splitAt" ((PVar "x") (PCon "Tip")) (ETuple (EVar "Tip") (EVar "Tip")))
(DFunDef false "splitAt" ((PVar "x") (PCon "Bin" PWild (PVar "y") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EVar "splitAt") (EVar "x")) (EVar "l"))) (DoExpr (ETuple (EVar "below") (EApp (EApp (EApp (EVar "link") (EVar "y")) (EVar "above")) (EVar "r")))))) (arm (PCon "Gt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EVar "splitAt") (EVar "x")) (EVar "r"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "link") (EVar "y")) (EVar "l")) (EVar "below")) (EVar "above"))))) (arm (PCon "Eq") () (ETuple (EVar "l") (EVar "r")))))
(DTypeSig false "splitMember" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyTuple (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool") (TyApp (TyCon "Set") (TyVar "a")))))))
(DFunDef false "splitMember" ((PVar "x") (PCon "Tip")) (ETuple (EVar "Tip") (EVar "False") (EVar "Tip")))
(DFunDef false "splitMember" ((PVar "x") (PCon "Bin" PWild (PVar "y") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "found") (PVar "above")) (EApp (EApp (EVar "splitMember") (EVar "x")) (EVar "l"))) (DoExpr (ETuple (EVar "below") (EVar "found") (EApp (EApp (EApp (EVar "link") (EVar "y")) (EVar "above")) (EVar "r")))))) (arm (PCon "Gt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "found") (PVar "above")) (EApp (EApp (EVar "splitMember") (EVar "x")) (EVar "r"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "link") (EVar "y")) (EVar "l")) (EVar "below")) (EVar "found") (EVar "above"))))) (arm (PCon "Eq") () (ETuple (EVar "l") (EVar "True") (EVar "r")))))
(DTypeSig true "union" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "union" ((PCon "Tip") (PVar "b")) (EVar "b"))
(DFunDef false "union" ((PVar "a") (PCon "Tip")) (EVar "a"))
(DFunDef false "union" ((PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "bl") (PVar "br")) (EApp (EApp (EVar "splitAt") (EVar "x")) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EVar "link") (EVar "x")) (EApp (EApp (EVar "union") (EVar "l")) (EVar "bl"))) (EApp (EApp (EVar "union") (EVar "r")) (EVar "br"))))))
(DTypeSig true "intersection" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "intersection" ((PCon "Tip") (PVar "b")) (EVar "Tip"))
(DFunDef false "intersection" ((PVar "a") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "intersection" ((PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "bl") (PVar "found") (PVar "br")) (EApp (EApp (EVar "splitMember") (EVar "x")) (EVar "b"))) (DoLet false false (PVar "l2") (EApp (EApp (EVar "intersection") (EVar "l")) (EVar "bl"))) (DoLet false false (PVar "r2") (EApp (EApp (EVar "intersection") (EVar "r")) (EVar "br"))) (DoExpr (EIf (EVar "found") (EApp (EApp (EApp (EVar "link") (EVar "x")) (EVar "l2")) (EVar "r2")) (EApp (EApp (EVar "link2") (EVar "l2")) (EVar "r2"))))))
(DTypeSig true "difference" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "difference" ((PCon "Tip") (PVar "b")) (EVar "Tip"))
(DFunDef false "difference" ((PVar "a") (PCon "Tip")) (EVar "a"))
(DFunDef false "difference" ((PVar "a") (PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "al") (PVar "ar")) (EApp (EApp (EVar "splitAt") (EVar "x")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "link2") (EApp (EApp (EVar "difference") (EVar "al")) (EVar "l"))) (EApp (EApp (EVar "difference") (EVar "ar")) (EVar "r"))))))
(DTypeSig true "isSubsetOf" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "isSubsetOf" ((PVar "a") (PVar "b")) (EBinOp "&&" (EBinOp "<=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EApp (EApp (EVar "subsetGo") (EVar "a")) (EVar "b"))))
(DTypeSig false "subsetGo" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "subsetGo" ((PCon "Tip") (PVar "b")) (EVar "True"))
(DFunDef false "subsetGo" ((PVar "a") (PCon "Tip")) (EVar "False"))
(DFunDef false "subsetGo" ((PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "bl") (PVar "found") (PVar "br")) (EApp (EApp (EVar "splitMember") (EVar "x")) (EVar "b"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "found") (EApp (EApp (EVar "subsetGo") (EVar "l")) (EVar "bl"))) (EApp (EApp (EVar "subsetGo") (EVar "r")) (EVar "br"))))))
(DImpl true "Foldable" ((TyCon "Set")) () ((im "fold" ((PVar "f") (PVar "z") (PVar "s")) (EApp (EApp (EApp (EVar "foldlSet") (EVar "f")) (EVar "z")) (EVar "s"))) (im "foldRight" ((PVar "f") (PVar "z") (PVar "s")) (EApp (EApp (EApp (EVar "foldrSet") (EVar "f")) (EVar "z")) (EVar "s"))) (im "toList" ((PVar "s")) (EApp (EApp (EApp (EVar "foldrSet") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "::" (EVar "_a") (EVar "_b")))) (EListLit)) (EVar "s"))) (im "isEmpty" ((PCon "Tip")) (EVar "True")) (im "isEmpty" (PWild) (EVar "False")) (im "length" ((PVar "s")) (EApp (EVar "size") (EVar "s")))))
(DImpl true "Eq" ((TyApp (TyCon "Set") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "!=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EVar "False") (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EVar "a"))) (EApp (EVar "toList") (EVar "b")))))))
(DImpl true "Ord" ((TyApp (TyCon "Set") (TyVar "a"))) ((req "Ord" ((TyVar "a")))) ((im "compare" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "compare") (EApp (EVar "toList") (EVar "a"))) (EApp (EVar "toList") (EVar "b"))))))
(DImpl true "Debug" ((TyApp (TyCon "Set") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EVar "display") (EApp (EVar "debug") (EApp (EVar "toList") (EVar "s"))))) (ELit (LString ""))))))
(DTypeSig false "displaySetItems" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "String"))))
(DFunDef false "displaySetItems" ((PList)) (ELit (LString "")))
(DFunDef false "displaySetItems" ((PList (PVar "x"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString ""))))
(DFunDef false "displaySetItems" ((PCons (PVar "y") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "y"))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "displaySetItems") (EVar "rest")))) (ELit (LString ""))))
(DImpl true "Display" ((TyApp (TyCon "Set") (TyVar "a"))) ((req "Display" ((TyVar "a")))) ((im "display" ((PVar "s")) (EMatch (EApp (EVar "toList") (EVar "s")) (arm (PList) () (ELit (LString "Set {}"))) (arm (PVar "xs") () (EBinOp "++" (EBinOp "++" (ELit (LString "Set { ")) (EApp (EVar "display") (EApp (EVar "displaySetItems") (EVar "xs")))) (ELit (LString " }"))))))))
(DImpl true "Semigroup" ((TyApp (TyCon "Set") (TyVar "a"))) ((req "Ord" ((TyVar "a")))) ((im "append" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "union") (EVar "a")) (EVar "b")))))
(DImpl true "FromEntries" ((TyApp (TyCon "Set") (TyVar "a")) (TyVar "a")) ((req "Ord" ((TyVar "a")))) ((im "fromEntries" ((PVar "es")) (EApp (EVar "fromList") (EVar "es")))))
(DImpl true "Monoid" ((TyApp (TyCon "Set") (TyVar "a"))) ((req "Ord" ((TyVar "a")))) ((im "empty" () (EVar "Tip"))))
(DTypeSig true "wellFormed" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "wellFormed" ((PCon "Tip")) (EVar "True"))
(DFunDef false "wellFormed" ((PCon "Bin" (PVar "s") (PVar "x") (PVar "l") (PVar "r"))) (EBlock (DoLet false false (PVar "sizeOk") (EBinOp "==" (EBinOp "+" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1))) (EVar "s"))) (DoLet false false (PVar "orderOk") (EBinOp "&&" (EApp (EApp (EVar "allElems") (ELam ((PVar "e")) (EApp (EApp (EVar "lt") (EVar "e")) (EVar "x")))) (EVar "l")) (EApp (EApp (EVar "allElems") (ELam ((PVar "e")) (EApp (EApp (EVar "gt") (EVar "e")) (EVar "x")))) (EVar "r")))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "sizeOk") (EApp (EApp (EVar "balancedAt") (EVar "l")) (EVar "r"))) (EVar "orderOk")) (EApp (EVar "wellFormed") (EVar "l"))) (EApp (EVar "wellFormed") (EVar "r"))))))
(DTypeSig false "allElems" (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "allElems" ((PVar "p") (PCon "Tip")) (EVar "True"))
(DFunDef false "allElems" ((PVar "p") (PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r"))) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "p") (EVar "x")) (EApp (EApp (EVar "allElems") (EVar "p")) (EVar "l"))) (EApp (EApp (EVar "allElems") (EVar "p")) (EVar "r"))))
(DTypeSig false "balancedAt" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "balancedAt" ((PVar "l") (PVar "r")) (EBlock (DoLet false false (PVar "sl") (EApp (EVar "size") (EVar "l"))) (DoLet false false (PVar "sr") (EApp (EVar "size") (EVar "r"))) (DoExpr (EIf (EBinOp "<=" (EBinOp "+" (EVar "sl") (EVar "sr")) (ELit (LInt 1))) (EVar "True") (EBinOp "&&" (EBinOp "<=" (EVar "sl") (EBinOp "*" (ELit (LInt 3)) (EVar "sr"))) (EBinOp "<=" (EVar "sr") (EBinOp "*" (ELit (LInt 3)) (EVar "sl"))))))))
(DTypeSig false "ascending" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "ascending" ((PList)) (EVar "True"))
(DFunDef false "ascending" ((PList (PVar "x"))) (EVar "True"))
(DFunDef false "ascending" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EBinOp "&&" (EApp (EApp (EVar "lt") (EVar "x")) (EVar "y")) (EApp (EVar "ascending") (EBinOp "::" (EVar "y") (EVar "rest")))))
(DProp false "fromList builds a well-formed tree" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EVar "wellFormed") (EApp (EVar "fromList") (EVar "xs"))))
(DProp false "elements come out strictly ascending (sorted, deduped)" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EVar "ascending") (EApp (EVar "toList") (EApp (EVar "fromList") (EVar "xs")))))
(DProp false "insert then member" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "has") (EVar "x")) (EApp (EApp (EVar "insert") (EVar "x")) (EApp (EVar "fromList") (EVar "xs")))))
(DProp false "insert preserves well-formedness" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EVar "wellFormed") (EApp (EApp (EVar "insert") (EVar "x")) (EApp (EVar "fromList") (EVar "xs")))))
(DProp false "delete removes the element and preserves well-formedness" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EVar "delete") (EVar "x")) (EApp (EVar "fromList") (EVar "xs")))) (DoExpr (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "x")) (EVar "s"))) (EApp (EVar "wellFormed") (EVar "s"))))))
(DProp false "union preserves well-formedness" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EVar "wellFormed") (EApp (EApp (EVar "union") (EApp (EVar "fromList") (EVar "xs"))) (EApp (EVar "fromList") (EVar "ys")))))
(DProp false "intersection elements are in both sets" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "ys"))) (DoExpr (EApp (EApp (EApp (EVar "foldrSet") (ELam ((PVar "e") (PVar "acc")) (EBinOp "&&" (EBinOp "&&" (EVar "acc") (EApp (EApp (EVar "has") (EVar "e")) (EVar "a"))) (EApp (EApp (EVar "has") (EVar "e")) (EVar "b"))))) (EVar "True")) (EApp (EApp (EVar "intersection") (EVar "a")) (EVar "b"))))))
(DProp false "intersection preserves well-formedness" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EVar "wellFormed") (EApp (EApp (EVar "intersection") (EApp (EVar "fromList") (EVar "xs"))) (EApp (EVar "fromList") (EVar "ys")))))
(DProp false "difference elements are in the first but not the second" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "ys"))) (DoExpr (EApp (EApp (EApp (EVar "foldrSet") (ELam ((PVar "e") (PVar "acc")) (EBinOp "&&" (EBinOp "&&" (EVar "acc") (EApp (EApp (EVar "has") (EVar "e")) (EVar "a"))) (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "e")) (EVar "b")))))) (EVar "True")) (EApp (EApp (EVar "difference") (EVar "a")) (EVar "b"))))))
(DProp false "difference preserves well-formedness" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EVar "wellFormed") (EApp (EApp (EVar "difference") (EApp (EVar "fromList") (EVar "xs"))) (EApp (EVar "fromList") (EVar "ys")))))
(DProp false "union is commutative on the sorted element list" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "ys"))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EApp (EApp (EVar "union") (EVar "a")) (EVar "b")))) (EApp (EVar "toList") (EApp (EApp (EVar "union") (EVar "b")) (EVar "a")))))))
(DProp false "size of a union is at most the sum of sizes" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "ys"))) (DoExpr (EBinOp "<=" (EApp (EVar "size") (EApp (EApp (EVar "union") (EVar "a")) (EVar "b"))) (EBinOp "+" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b")))))))
(DProp false "difference elements stay in the first set" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "ys"))) (DoExpr (EApp (EApp (EApp (EVar "foldrSet") (ELam ((PVar "e") (PVar "acc")) (EBinOp "&&" (EVar "acc") (EApp (EApp (EVar "has") (EVar "e")) (EVar "a"))))) (EVar "True")) (EApp (EApp (EVar "difference") (EVar "a")) (EVar "b"))))))
(DProp false "deleting a member removes it" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "x")) (EApp (EApp (EVar "delete") (EVar "x")) (EApp (EApp (EVar "insert") (EVar "x")) (EApp (EVar "fromList") (EVar "xs")))))))
(DTypeSig false "naiveUnion" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "naiveUnion" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrSet") (ELam ((PVar "x") (PVar "acc")) (EApp (EApp (EVar "insert") (EVar "x")) (EVar "acc")))) (EVar "b")) (EVar "a")))
(DTypeSig false "naiveIntersection" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "naiveIntersection" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrSet") (EApp (EVar "naiveIntersectStep") (EVar "b"))) (EVar "Tip")) (EVar "a")))
(DTypeSig false "naiveIntersectStep" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))))
(DFunDef false "naiveIntersectStep" ((PVar "b") (PVar "x") (PVar "acc")) (EIf (EApp (EApp (EVar "has") (EVar "x")) (EVar "b")) (EApp (EApp (EVar "insert") (EVar "x")) (EVar "acc")) (EVar "acc")))
(DTypeSig false "naiveDifference" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "naiveDifference" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrSet") (ELam ((PVar "x") (PVar "acc")) (EApp (EApp (EVar "delete") (EVar "x")) (EVar "acc")))) (EVar "a")) (EVar "b")))
(DTypeSig false "naiveIsSubsetOf" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "naiveIsSubsetOf" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrSet") (ELam ((PVar "x") (PVar "acc")) (EBinOp "&&" (EVar "acc") (EApp (EApp (EVar "has") (EVar "x")) (EVar "b"))))) (EVar "True")) (EVar "a")))
(DProp false "union agrees with naive fold-insert and stays well-formed" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EVar "union") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EVar "got"))) (EApp (EVar "toList") (EApp (EApp (EVar "naiveUnion") (EVar "a")) (EVar "b")))) (EApp (EVar "wellFormed") (EVar "got"))))))
(DProp false "union elements stay strictly ascending" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EVar "ascending") (EApp (EVar "toList") (EApp (EApp (EVar "union") (EApp (EVar "fromList") (EVar "xs"))) (EApp (EVar "fromList") (EVar "ys"))))))
(DProp false "intersection agrees with naive and stays well-formed" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EVar "intersection") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EVar "got"))) (EApp (EVar "toList") (EApp (EApp (EVar "naiveIntersection") (EVar "a")) (EVar "b")))) (EApp (EVar "wellFormed") (EVar "got"))))))
(DProp false "difference agrees with naive and stays well-formed" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EVar "difference") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EVar "got"))) (EApp (EVar "toList") (EApp (EApp (EVar "naiveDifference") (EVar "a")) (EVar "b")))) (EApp (EVar "wellFormed") (EVar "got"))))))
(DProp false "isSubsetOf agrees with the naive fold" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EVar "fromList") (EVar "ys"))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EApp (EVar "isSubsetOf") (EVar "a")) (EVar "b"))) (EApp (EApp (EVar "naiveIsSubsetOf") (EVar "a")) (EVar "b"))))))
(DProp false "a subset of a union is recognised" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "isSubsetOf") (EVar "a")) (EApp (EApp (EVar "union") (EVar "a")) (EApp (EVar "fromList") (EVar "ys")))))))
(DProp false "splitAt partitions around the element and both halves stay well-formed" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EVar "splitAt") (EVar "x")) (EApp (EVar "fromList") (EVar "xs")))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "wellFormed") (EVar "below")) (EApp (EVar "wellFormed") (EVar "above"))) (EApp (EApp (EVar "allElems") (ELam ((PVar "b")) (EApp (EApp (EVar "lt") (EVar "b")) (EVar "x")))) (EVar "below"))) (EApp (EApp (EVar "allElems") (ELam ((PVar "a")) (EApp (EApp (EVar "gt") (EVar "a")) (EVar "x")))) (EVar "above"))))))
(DProp false "link rebuilds a well-formed set from a split" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EVar "splitAt") (EVar "x")) (EApp (EVar "fromList") (EVar "xs")))) (DoLet false false (PVar "rebuilt") (EApp (EApp (EApp (EVar "link") (EVar "x")) (EVar "below")) (EVar "above"))) (DoExpr (EBinOp "&&" (EApp (EVar "wellFormed") (EVar "rebuilt")) (EApp (EApp (EVar "has") (EVar "x")) (EVar "rebuilt"))))))
(DProp false "link2 rejoins a split without its element" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EVar "splitAt") (EVar "x")) (EApp (EVar "fromList") (EVar "xs")))) (DoLet false false (PVar "rebuilt") (EApp (EApp (EVar "link2") (EVar "below")) (EVar "above"))) (DoExpr (EBinOp "&&" (EApp (EVar "wellFormed") (EVar "rebuilt")) (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EVar "rebuilt"))) (EApp (EVar "toList") (EApp (EApp (EVar "delete") (EVar "x")) (EApp (EVar "fromList") (EVar "xs")))))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Foldable" false) (mem "Semigroup" false) (mem "Monoid" false) (mem "Ordering" false) (mem "Option" false) (mem "FromEntries" false))))
(DData Public "Set" ("a") ((variant "Tip" (ConPos)) (variant "Bin" (ConPos (TyCon "Int") (TyVar "a") (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))) ())
(DTypeSig false "bin" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "bin" ((PVar "x") (PVar "l") (PVar "r")) (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1)))) (EVar "x")) (EVar "l")) (EVar "r")))
(DTypeSig false "balance" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "balance" ((PVar "x") (PVar "l") (PVar "r")) (EIf (EBinOp "<=" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1))) (EApp (EApp (EApp (EVar "bin") (EVar "x")) (EVar "l")) (EVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "r")) (EBinOp "*" (ELit (LInt 3)) (EApp (EVar "size") (EVar "l")))) (EApp (EApp (EApp (EVar "rotateL") (EVar "x")) (EVar "l")) (EVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "l")) (EBinOp "*" (ELit (LInt 3)) (EApp (EVar "size") (EVar "r")))) (EApp (EApp (EApp (EVar "rotateR") (EVar "x")) (EVar "l")) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "bin") (EVar "x")) (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "rotateL" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "rotateL" ((PVar "x") (PVar "l") (PAs "r" (PCon "Bin" PWild PWild (PVar "rl") (PVar "rr")))) (EIf (EBinOp "<" (EApp (EVar "size") (EVar "rl")) (EBinOp "*" (ELit (LInt 2)) (EApp (EVar "size") (EVar "rr")))) (EApp (EApp (EApp (EVar "singleL") (EVar "x")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EVar "doubleL") (EVar "x")) (EVar "l")) (EVar "r"))))
(DFunDef false "rotateL" ((PVar "x") (PVar "l") (PCon "Tip")) (EApp (EVar "panic") (ELit (LString "Set.rotateL: empty right subtree"))))
(DTypeSig false "rotateR" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "rotateR" ((PVar "x") (PAs "l" (PCon "Bin" PWild PWild (PVar "ll") (PVar "lr"))) (PVar "r")) (EIf (EBinOp "<" (EApp (EVar "size") (EVar "lr")) (EBinOp "*" (ELit (LInt 2)) (EApp (EVar "size") (EVar "ll")))) (EApp (EApp (EApp (EVar "singleR") (EVar "x")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EVar "doubleR") (EVar "x")) (EVar "l")) (EVar "r"))))
(DFunDef false "rotateR" ((PVar "x") (PCon "Tip") (PVar "r")) (EApp (EVar "panic") (ELit (LString "Set.rotateR: empty left subtree"))))
(DTypeSig false "singleL" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "singleL" ((PVar "x1") (PVar "t1") (PCon "Bin" PWild (PVar "x2") (PVar "t2") (PVar "t3"))) (EApp (EApp (EApp (EVar "bin") (EVar "x2")) (EApp (EApp (EApp (EVar "bin") (EVar "x1")) (EVar "t1")) (EVar "t2"))) (EVar "t3")))
(DFunDef false "singleL" ((PVar "x1") (PVar "t1") (PCon "Tip")) (EApp (EVar "panic") (ELit (LString "Set.singleL: empty right subtree"))))
(DTypeSig false "singleR" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "singleR" ((PVar "x1") (PCon "Bin" PWild (PVar "x2") (PVar "t1") (PVar "t2")) (PVar "t3")) (EApp (EApp (EApp (EVar "bin") (EVar "x2")) (EVar "t1")) (EApp (EApp (EApp (EVar "bin") (EVar "x1")) (EVar "t2")) (EVar "t3"))))
(DFunDef false "singleR" ((PVar "x1") (PCon "Tip") (PVar "t3")) (EApp (EVar "panic") (ELit (LString "Set.singleR: empty left subtree"))))
(DTypeSig false "doubleL" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "doubleL" ((PVar "x1") (PVar "t1") (PCon "Bin" PWild (PVar "x2") (PCon "Bin" PWild (PVar "x3") (PVar "t2") (PVar "t3")) (PVar "t4"))) (EApp (EApp (EApp (EVar "bin") (EVar "x3")) (EApp (EApp (EApp (EVar "bin") (EVar "x1")) (EVar "t1")) (EVar "t2"))) (EApp (EApp (EApp (EVar "bin") (EVar "x2")) (EVar "t3")) (EVar "t4"))))
(DFunDef false "doubleL" ((PVar "x1") (PVar "t1") PWild) (EApp (EVar "panic") (ELit (LString "Set.doubleL: malformed right subtree"))))
(DTypeSig false "doubleR" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "doubleR" ((PVar "x1") (PCon "Bin" PWild (PVar "x2") (PVar "t1") (PCon "Bin" PWild (PVar "x3") (PVar "t2") (PVar "t3"))) (PVar "t4")) (EApp (EApp (EApp (EVar "bin") (EVar "x3")) (EApp (EApp (EApp (EVar "bin") (EVar "x2")) (EVar "t1")) (EVar "t2"))) (EApp (EApp (EApp (EVar "bin") (EVar "x1")) (EVar "t3")) (EVar "t4"))))
(DFunDef false "doubleR" ((PVar "x1") PWild (PVar "t4")) (EApp (EVar "panic") (ELit (LString "Set.doubleR: malformed left subtree"))))
(DTypeSig true "singleton" (TyFun (TyVar "a") (TyApp (TyCon "Set") (TyVar "a"))))
(DFunDef false "singleton" ((PVar "x")) (EApp (EApp (EApp (EApp (EVar "Bin") (ELit (LInt 1))) (EVar "x")) (EVar "Tip")) (EVar "Tip")))
(DTypeSig true "fromList" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))
(DFunDef false "fromList" ((PVar "xs")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "s") (PVar "x")) (EApp (EApp (EDictApp "insert") (EVar "x")) (EVar "s")))) (EVar "Tip")) (EVar "xs")))
(DTypeSig true "size" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Int")))
(DFunDef false "size" ((PCon "Tip")) (ELit (LInt 0)))
(DFunDef false "size" ((PCon "Bin" (PVar "s") PWild PWild PWild)) (EVar "s"))
(DTypeSig true "has" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "has" ((PVar "x") (PCon "Tip")) (EVar "False"))
(DFunDef false "has" ((PVar "x") (PCon "Bin" PWild (PVar "y") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EApp (EApp (EDictApp "has") (EVar "x")) (EVar "l"))) (arm (PCon "Gt") () (EApp (EApp (EDictApp "has") (EVar "x")) (EVar "r"))) (arm (PCon "Eq") () (EVar "True"))))
(DTypeSig true "insert" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "insert" ((PVar "x") (PCon "Tip")) (EApp (EVar "singleton") (EVar "x")))
(DFunDef false "insert" ((PVar "x") (PCon "Bin" (PVar "s") (PVar "y") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EApp (EApp (EApp (EVar "balance") (EVar "y")) (EApp (EApp (EDictApp "insert") (EVar "x")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EVar "balance") (EVar "y")) (EVar "l")) (EApp (EApp (EDictApp "insert") (EVar "x")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "x")) (EVar "l")) (EVar "r")))))
(DTypeSig true "delete" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "delete" ((PVar "x") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "delete" ((PVar "x") (PCon "Bin" PWild (PVar "y") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EApp (EApp (EApp (EVar "balance") (EVar "y")) (EApp (EApp (EDictApp "delete") (EVar "x")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EVar "balance") (EVar "y")) (EVar "l")) (EApp (EApp (EDictApp "delete") (EVar "x")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EVar "glue") (EVar "l")) (EVar "r")))))
(DTypeSig false "glue" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))
(DFunDef false "glue" ((PCon "Tip") (PVar "r")) (EVar "r"))
(DFunDef false "glue" ((PVar "l") (PCon "Tip")) (EVar "l"))
(DFunDef false "glue" ((PVar "l") (PVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (EApp (EApp (EVar "glueMax") (EVar "l")) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EVar "glueMin") (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "glueMax" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))
(DFunDef false "glueMax" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "maxView") (EVar "l")) (arm (PCon "None") () (EVar "r")) (arm (PCon "Some" (PTuple (PVar "x") (PVar "l'"))) () (EApp (EApp (EApp (EVar "balance") (EVar "x")) (EVar "l'")) (EVar "r")))))
(DTypeSig false "glueMin" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))
(DFunDef false "glueMin" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "minView") (EVar "r")) (arm (PCon "None") () (EVar "l")) (arm (PCon "Some" (PTuple (PVar "x") (PVar "r'"))) () (EApp (EApp (EApp (EVar "balance") (EVar "x")) (EVar "l")) (EVar "r'")))))
(DTypeSig true "minView" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Option") (TyTuple (TyVar "a") (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "minView" ((PCon "Tip")) (EVar "None"))
(DFunDef false "minView" ((PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r"))) (EMatch (EApp (EVar "minView") (EVar "l")) (arm (PCon "None") () (EApp (EVar "Some") (ETuple (EVar "x") (EVar "r")))) (arm (PCon "Some" (PTuple (PVar "xm") (PVar "l'"))) () (EApp (EVar "Some") (ETuple (EVar "xm") (EApp (EApp (EApp (EVar "balance") (EVar "x")) (EVar "l'")) (EVar "r")))))))
(DTypeSig true "maxView" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Option") (TyTuple (TyVar "a") (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "maxView" ((PCon "Tip")) (EVar "None"))
(DFunDef false "maxView" ((PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r"))) (EMatch (EApp (EVar "maxView") (EVar "r")) (arm (PCon "None") () (EApp (EVar "Some") (ETuple (EVar "x") (EVar "l")))) (arm (PCon "Some" (PTuple (PVar "xm") (PVar "r'"))) () (EApp (EVar "Some") (ETuple (EVar "xm") (EApp (EApp (EApp (EVar "balance") (EVar "x")) (EVar "l")) (EVar "r'")))))))
(DTypeSig true "getMin" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "getMin" ((PVar "s")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "x") PWild)) (EVar "x"))) (EApp (EVar "minView") (EVar "s"))))
(DTypeSig true "getMax" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "getMax" ((PVar "s")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "x") PWild)) (EVar "x"))) (EApp (EVar "maxView") (EVar "s"))))
(DTypeSig true "deleteMin" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))
(DFunDef false "deleteMin" ((PVar "s")) (EMatch (EApp (EVar "minView") (EVar "s")) (arm (PCon "None") () (EVar "Tip")) (arm (PCon "Some" (PTuple PWild (PVar "s'"))) () (EVar "s'"))))
(DTypeSig true "deleteMax" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))
(DFunDef false "deleteMax" ((PVar "s")) (EMatch (EApp (EVar "maxView") (EVar "s")) (arm (PCon "None") () (EVar "Tip")) (arm (PCon "Some" (PTuple PWild (PVar "s'"))) () (EVar "s'"))))
(DTypeSig false "foldrSet" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldrSet" ((PVar "f") (PVar "z") (PCon "Tip")) (EVar "z"))
(DFunDef false "foldrSet" ((PVar "f") (PVar "z") (PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "foldrSet") (EVar "f")) (EApp (EApp (EVar "f") (EVar "x")) (EApp (EApp (EApp (EVar "foldrSet") (EVar "f")) (EVar "z")) (EVar "r")))) (EVar "l")))
(DTypeSig false "foldlSet" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldlSet" ((PVar "f") (PVar "z") (PCon "Tip")) (EVar "z"))
(DFunDef false "foldlSet" ((PVar "f") (PVar "z") (PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "foldlSet") (EVar "f")) (EApp (EApp (EVar "f") (EApp (EApp (EApp (EVar "foldlSet") (EVar "f")) (EVar "z")) (EVar "l"))) (EVar "x"))) (EVar "r")))
(DTypeSig false "insertMin" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))
(DFunDef false "insertMin" ((PVar "x") (PCon "Tip")) (EApp (EVar "singleton") (EVar "x")))
(DFunDef false "insertMin" ((PVar "x") (PCon "Bin" PWild (PVar "y") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "balance") (EVar "y")) (EApp (EApp (EVar "insertMin") (EVar "x")) (EVar "l"))) (EVar "r")))
(DTypeSig false "insertMax" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))
(DFunDef false "insertMax" ((PVar "x") (PCon "Tip")) (EApp (EVar "singleton") (EVar "x")))
(DFunDef false "insertMax" ((PVar "x") (PCon "Bin" PWild (PVar "y") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "balance") (EVar "y")) (EVar "l")) (EApp (EApp (EVar "insertMax") (EVar "x")) (EVar "r"))))
(DTypeSig false "link" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "link" ((PVar "x") (PCon "Tip") (PVar "r")) (EApp (EApp (EVar "insertMin") (EVar "x")) (EVar "r")))
(DFunDef false "link" ((PVar "x") (PVar "l") (PCon "Tip")) (EApp (EApp (EVar "insertMax") (EVar "x")) (EVar "l")))
(DFunDef false "link" ((PVar "x") (PAs "l" (PCon "Bin" (PVar "sl") (PVar "xl") (PVar "ll") (PVar "rl"))) (PAs "r" (PCon "Bin" (PVar "sr") (PVar "xr") (PVar "lr") (PVar "rr")))) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sl")) (EVar "sr")) (EApp (EApp (EApp (EVar "balance") (EVar "xr")) (EApp (EApp (EApp (EVar "link") (EVar "x")) (EVar "l")) (EVar "lr"))) (EVar "rr")) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sr")) (EVar "sl")) (EApp (EApp (EApp (EVar "balance") (EVar "xl")) (EVar "ll")) (EApp (EApp (EApp (EVar "link") (EVar "x")) (EVar "rl")) (EVar "r"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "bin") (EVar "x")) (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "link2" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))
(DFunDef false "link2" ((PCon "Tip") (PVar "r")) (EVar "r"))
(DFunDef false "link2" ((PVar "l") (PCon "Tip")) (EVar "l"))
(DFunDef false "link2" ((PAs "l" (PCon "Bin" (PVar "sl") (PVar "xl") (PVar "ll") (PVar "rl"))) (PAs "r" (PCon "Bin" (PVar "sr") (PVar "xr") (PVar "lr") (PVar "rr")))) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sl")) (EVar "sr")) (EApp (EApp (EApp (EVar "balance") (EVar "xr")) (EApp (EApp (EVar "link2") (EVar "l")) (EVar "lr"))) (EVar "rr")) (EIf (EBinOp "<" (EBinOp "*" (ELit (LInt 3)) (EVar "sr")) (EVar "sl")) (EApp (EApp (EApp (EVar "balance") (EVar "xl")) (EVar "ll")) (EApp (EApp (EVar "link2") (EVar "rl")) (EVar "r"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "glue") (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "splitAt" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyTuple (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))))
(DFunDef false "splitAt" ((PVar "x") (PCon "Tip")) (ETuple (EVar "Tip") (EVar "Tip")))
(DFunDef false "splitAt" ((PVar "x") (PCon "Bin" PWild (PVar "y") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EDictApp "splitAt") (EVar "x")) (EVar "l"))) (DoExpr (ETuple (EVar "below") (EApp (EApp (EApp (EVar "link") (EVar "y")) (EVar "above")) (EVar "r")))))) (arm (PCon "Gt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EDictApp "splitAt") (EVar "x")) (EVar "r"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "link") (EVar "y")) (EVar "l")) (EVar "below")) (EVar "above"))))) (arm (PCon "Eq") () (ETuple (EVar "l") (EVar "r")))))
(DTypeSig false "splitMember" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyTuple (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool") (TyApp (TyCon "Set") (TyVar "a")))))))
(DFunDef false "splitMember" ((PVar "x") (PCon "Tip")) (ETuple (EVar "Tip") (EVar "False") (EVar "Tip")))
(DFunDef false "splitMember" ((PVar "x") (PCon "Bin" PWild (PVar "y") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (arm (PCon "Lt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "found") (PVar "above")) (EApp (EApp (EDictApp "splitMember") (EVar "x")) (EVar "l"))) (DoExpr (ETuple (EVar "below") (EVar "found") (EApp (EApp (EApp (EVar "link") (EVar "y")) (EVar "above")) (EVar "r")))))) (arm (PCon "Gt") () (EBlock (DoLet false false (PTuple (PVar "below") (PVar "found") (PVar "above")) (EApp (EApp (EDictApp "splitMember") (EVar "x")) (EVar "r"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "link") (EVar "y")) (EVar "l")) (EVar "below")) (EVar "found") (EVar "above"))))) (arm (PCon "Eq") () (ETuple (EVar "l") (EVar "True") (EVar "r")))))
(DTypeSig true "union" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "union" ((PCon "Tip") (PVar "b")) (EVar "b"))
(DFunDef false "union" ((PVar "a") (PCon "Tip")) (EVar "a"))
(DFunDef false "union" ((PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "bl") (PVar "br")) (EApp (EApp (EDictApp "splitAt") (EVar "x")) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EVar "link") (EVar "x")) (EApp (EApp (EDictApp "union") (EVar "l")) (EVar "bl"))) (EApp (EApp (EDictApp "union") (EVar "r")) (EVar "br"))))))
(DTypeSig true "intersection" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "intersection" ((PCon "Tip") (PVar "b")) (EVar "Tip"))
(DFunDef false "intersection" ((PVar "a") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "intersection" ((PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "bl") (PVar "found") (PVar "br")) (EApp (EApp (EDictApp "splitMember") (EVar "x")) (EVar "b"))) (DoLet false false (PVar "l2") (EApp (EApp (EDictApp "intersection") (EVar "l")) (EVar "bl"))) (DoLet false false (PVar "r2") (EApp (EApp (EDictApp "intersection") (EVar "r")) (EVar "br"))) (DoExpr (EIf (EVar "found") (EApp (EApp (EApp (EVar "link") (EVar "x")) (EVar "l2")) (EVar "r2")) (EApp (EApp (EVar "link2") (EVar "l2")) (EVar "r2"))))))
(DTypeSig true "difference" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "difference" ((PCon "Tip") (PVar "b")) (EVar "Tip"))
(DFunDef false "difference" ((PVar "a") (PCon "Tip")) (EVar "a"))
(DFunDef false "difference" ((PVar "a") (PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r"))) (EBlock (DoLet false false (PTuple (PVar "al") (PVar "ar")) (EApp (EApp (EDictApp "splitAt") (EVar "x")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "link2") (EApp (EApp (EDictApp "difference") (EVar "al")) (EVar "l"))) (EApp (EApp (EDictApp "difference") (EVar "ar")) (EVar "r"))))))
(DTypeSig true "isSubsetOf" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "isSubsetOf" ((PVar "a") (PVar "b")) (EBinOp "&&" (EBinOp "<=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EApp (EApp (EDictApp "subsetGo") (EVar "a")) (EVar "b"))))
(DTypeSig false "subsetGo" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "subsetGo" ((PCon "Tip") (PVar "b")) (EVar "True"))
(DFunDef false "subsetGo" ((PVar "a") (PCon "Tip")) (EVar "False"))
(DFunDef false "subsetGo" ((PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r")) (PVar "b")) (EBlock (DoLet false false (PTuple (PVar "bl") (PVar "found") (PVar "br")) (EApp (EApp (EDictApp "splitMember") (EVar "x")) (EVar "b"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "found") (EApp (EApp (EDictApp "subsetGo") (EVar "l")) (EVar "bl"))) (EApp (EApp (EDictApp "subsetGo") (EVar "r")) (EVar "br"))))))
(DImpl true "Foldable" ((TyCon "Set")) () ((im "fold" ((PVar "f") (PVar "z") (PVar "s")) (EApp (EApp (EApp (EVar "foldlSet") (EVar "f")) (EVar "z")) (EVar "s"))) (im "foldRight" ((PVar "f") (PVar "z") (PVar "s")) (EApp (EApp (EApp (EVar "foldrSet") (EVar "f")) (EVar "z")) (EVar "s"))) (im "toList" ((PVar "s")) (EApp (EApp (EApp (EVar "foldrSet") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "::" (EVar "_a") (EVar "_b")))) (EListLit)) (EVar "s"))) (im "isEmpty" ((PCon "Tip")) (EVar "True")) (im "isEmpty" (PWild) (EVar "False")) (im "length" ((PVar "s")) (EApp (EVar "size") (EVar "s")))))
(DImpl true "Eq" ((TyApp (TyCon "Set") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "!=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EVar "False") (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EVar "a"))) (EApp (EMethodRef "toList") (EVar "b")))))))
(DImpl true "Ord" ((TyApp (TyCon "Set") (TyVar "a"))) ((req "Ord" ((TyVar "a")))) ((im "compare" ((PVar "a") (PVar "b")) (EApp (EApp (EMethodRef "compare") (EApp (EMethodRef "toList") (EVar "a"))) (EApp (EMethodRef "toList") (EVar "b"))))))
(DImpl true "Debug" ((TyApp (TyCon "Set") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EApp (EMethodRef "toList") (EVar "s"))))) (ELit (LString ""))))))
(DTypeSig false "displaySetItems" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "String"))))
(DFunDef false "displaySetItems" ((PList)) (ELit (LString "")))
(DFunDef false "displaySetItems" ((PList (PVar "x"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString ""))))
(DFunDef false "displaySetItems" ((PCons (PVar "y") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "y"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EDictApp "displaySetItems") (EVar "rest")))) (ELit (LString ""))))
(DImpl true "Display" ((TyApp (TyCon "Set") (TyVar "a"))) ((req "Display" ((TyVar "a")))) ((im "display" ((PVar "s")) (EMatch (EApp (EMethodRef "toList") (EVar "s")) (arm (PList) () (ELit (LString "Set {}"))) (arm (PVar "xs") () (EBinOp "++" (EBinOp "++" (ELit (LString "Set { ")) (EApp (EMethodRef "display") (EApp (EDictApp "displaySetItems") (EVar "xs")))) (ELit (LString " }"))))))))
(DImpl true "Semigroup" ((TyApp (TyCon "Set") (TyVar "a"))) ((req "Ord" ((TyVar "a")))) ((im "append" ((PVar "a") (PVar "b")) (EApp (EApp (EDictApp "union") (EVar "a")) (EVar "b")))))
(DImpl true "FromEntries" ((TyApp (TyCon "Set") (TyVar "a")) (TyVar "a")) ((req "Ord" ((TyVar "a")))) ((im "fromEntries" ((PVar "es")) (EApp (EDictApp "fromList") (EVar "es")))))
(DImpl true "Monoid" ((TyApp (TyCon "Set") (TyVar "a"))) ((req "Ord" ((TyVar "a")))) ((im "empty" () (EVar "Tip"))))
(DTypeSig true "wellFormed" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "wellFormed" ((PCon "Tip")) (EVar "True"))
(DFunDef false "wellFormed" ((PCon "Bin" (PVar "s") (PVar "x") (PVar "l") (PVar "r"))) (EBlock (DoLet false false (PVar "sizeOk") (EBinOp "==" (EBinOp "+" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1))) (EVar "s"))) (DoLet false false (PVar "orderOk") (EBinOp "&&" (EApp (EApp (EVar "allElems") (ELam ((PVar "e")) (EApp (EApp (EMethodRef "lt") (EVar "e")) (EVar "x")))) (EVar "l")) (EApp (EApp (EVar "allElems") (ELam ((PVar "e")) (EApp (EApp (EMethodRef "gt") (EVar "e")) (EVar "x")))) (EVar "r")))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "sizeOk") (EApp (EApp (EVar "balancedAt") (EVar "l")) (EVar "r"))) (EVar "orderOk")) (EApp (EDictApp "wellFormed") (EVar "l"))) (EApp (EDictApp "wellFormed") (EVar "r"))))))
(DTypeSig false "allElems" (TyFun (TyFun (TyVar "a") (TyCon "Bool")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "allElems" ((PVar "p") (PCon "Tip")) (EVar "True"))
(DFunDef false "allElems" ((PVar "p") (PCon "Bin" PWild (PVar "x") (PVar "l") (PVar "r"))) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "p") (EVar "x")) (EApp (EApp (EVar "allElems") (EVar "p")) (EVar "l"))) (EApp (EApp (EVar "allElems") (EVar "p")) (EVar "r"))))
(DTypeSig false "balancedAt" (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "balancedAt" ((PVar "l") (PVar "r")) (EBlock (DoLet false false (PVar "sl") (EApp (EVar "size") (EVar "l"))) (DoLet false false (PVar "sr") (EApp (EVar "size") (EVar "r"))) (DoExpr (EIf (EBinOp "<=" (EBinOp "+" (EVar "sl") (EVar "sr")) (ELit (LInt 1))) (EVar "True") (EBinOp "&&" (EBinOp "<=" (EVar "sl") (EBinOp "*" (ELit (LInt 3)) (EVar "sr"))) (EBinOp "<=" (EVar "sr") (EBinOp "*" (ELit (LInt 3)) (EVar "sl"))))))))
(DTypeSig false "ascending" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "ascending" ((PList)) (EVar "True"))
(DFunDef false "ascending" ((PList (PVar "x"))) (EVar "True"))
(DFunDef false "ascending" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EBinOp "&&" (EApp (EApp (EMethodRef "lt") (EVar "x")) (EVar "y")) (EApp (EDictApp "ascending") (EBinOp "::" (EVar "y") (EVar "rest")))))
(DProp false "fromList builds a well-formed tree" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EDictApp "wellFormed") (EApp (EDictApp "fromList") (EVar "xs"))))
(DProp false "elements come out strictly ascending (sorted, deduped)" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EDictApp "ascending") (EApp (EMethodRef "toList") (EApp (EDictApp "fromList") (EVar "xs")))))
(DProp false "insert then member" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EDictApp "has") (EVar "x")) (EApp (EApp (EDictApp "insert") (EVar "x")) (EApp (EDictApp "fromList") (EVar "xs")))))
(DProp false "insert preserves well-formedness" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EDictApp "wellFormed") (EApp (EApp (EDictApp "insert") (EVar "x")) (EApp (EDictApp "fromList") (EVar "xs")))))
(DProp false "delete removes the element and preserves well-formedness" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EDictApp "delete") (EVar "x")) (EApp (EDictApp "fromList") (EVar "xs")))) (DoExpr (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EDictApp "has") (EVar "x")) (EVar "s"))) (EApp (EDictApp "wellFormed") (EVar "s"))))))
(DProp false "union preserves well-formedness" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EDictApp "wellFormed") (EApp (EApp (EDictApp "union") (EApp (EDictApp "fromList") (EVar "xs"))) (EApp (EDictApp "fromList") (EVar "ys")))))
(DProp false "intersection elements are in both sets" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EVar "ys"))) (DoExpr (EApp (EApp (EApp (EVar "foldrSet") (ELam ((PVar "e") (PVar "acc")) (EBinOp "&&" (EBinOp "&&" (EVar "acc") (EApp (EApp (EDictApp "has") (EVar "e")) (EVar "a"))) (EApp (EApp (EDictApp "has") (EVar "e")) (EVar "b"))))) (EVar "True")) (EApp (EApp (EDictApp "intersection") (EVar "a")) (EVar "b"))))))
(DProp false "intersection preserves well-formedness" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EDictApp "wellFormed") (EApp (EApp (EDictApp "intersection") (EApp (EDictApp "fromList") (EVar "xs"))) (EApp (EDictApp "fromList") (EVar "ys")))))
(DProp false "difference elements are in the first but not the second" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EVar "ys"))) (DoExpr (EApp (EApp (EApp (EVar "foldrSet") (ELam ((PVar "e") (PVar "acc")) (EBinOp "&&" (EBinOp "&&" (EVar "acc") (EApp (EApp (EDictApp "has") (EVar "e")) (EVar "a"))) (EApp (EVar "not") (EApp (EApp (EDictApp "has") (EVar "e")) (EVar "b")))))) (EVar "True")) (EApp (EApp (EDictApp "difference") (EVar "a")) (EVar "b"))))))
(DProp false "difference preserves well-formedness" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EDictApp "wellFormed") (EApp (EApp (EDictApp "difference") (EApp (EDictApp "fromList") (EVar "xs"))) (EApp (EDictApp "fromList") (EVar "ys")))))
(DProp false "union is commutative on the sorted element list" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EVar "ys"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EApp (EApp (EDictApp "union") (EVar "a")) (EVar "b")))) (EApp (EMethodRef "toList") (EApp (EApp (EDictApp "union") (EVar "b")) (EVar "a")))))))
(DProp false "size of a union is at most the sum of sizes" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EVar "ys"))) (DoExpr (EBinOp "<=" (EApp (EVar "size") (EApp (EApp (EDictApp "union") (EVar "a")) (EVar "b"))) (EBinOp "+" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b")))))))
(DProp false "difference elements stay in the first set" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EVar "ys"))) (DoExpr (EApp (EApp (EApp (EVar "foldrSet") (ELam ((PVar "e") (PVar "acc")) (EBinOp "&&" (EVar "acc") (EApp (EApp (EDictApp "has") (EVar "e")) (EVar "a"))))) (EVar "True")) (EApp (EApp (EDictApp "difference") (EVar "a")) (EVar "b"))))))
(DProp false "deleting a member removes it" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EVar "not") (EApp (EApp (EDictApp "has") (EVar "x")) (EApp (EApp (EDictApp "delete") (EVar "x")) (EApp (EApp (EDictApp "insert") (EVar "x")) (EApp (EDictApp "fromList") (EVar "xs")))))))
(DTypeSig false "naiveUnion" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "naiveUnion" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrSet") (ELam ((PVar "x") (PVar "acc")) (EApp (EApp (EDictApp "insert") (EVar "x")) (EVar "acc")))) (EVar "b")) (EVar "a")))
(DTypeSig false "naiveIntersection" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "naiveIntersection" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrSet") (EApp (EDictApp "naiveIntersectStep") (EVar "b"))) (EVar "Tip")) (EVar "a")))
(DTypeSig false "naiveIntersectStep" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a")))))))
(DFunDef false "naiveIntersectStep" ((PVar "b") (PVar "x") (PVar "acc")) (EIf (EApp (EApp (EDictApp "has") (EVar "x")) (EVar "b")) (EApp (EApp (EDictApp "insert") (EVar "x")) (EVar "acc")) (EVar "acc")))
(DTypeSig false "naiveDifference" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyApp (TyCon "Set") (TyVar "a"))))))
(DFunDef false "naiveDifference" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrSet") (ELam ((PVar "x") (PVar "acc")) (EApp (EApp (EDictApp "delete") (EVar "x")) (EVar "acc")))) (EVar "a")) (EVar "b")))
(DTypeSig false "naiveIsSubsetOf" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyFun (TyApp (TyCon "Set") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "naiveIsSubsetOf" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrSet") (ELam ((PVar "x") (PVar "acc")) (EBinOp "&&" (EVar "acc") (EApp (EApp (EDictApp "has") (EVar "x")) (EVar "b"))))) (EVar "True")) (EVar "a")))
(DProp false "union agrees with naive fold-insert and stays well-formed" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EDictApp "union") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EVar "got"))) (EApp (EMethodRef "toList") (EApp (EApp (EDictApp "naiveUnion") (EVar "a")) (EVar "b")))) (EApp (EDictApp "wellFormed") (EVar "got"))))))
(DProp false "union elements stay strictly ascending" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EDictApp "ascending") (EApp (EMethodRef "toList") (EApp (EApp (EDictApp "union") (EApp (EDictApp "fromList") (EVar "xs"))) (EApp (EDictApp "fromList") (EVar "ys"))))))
(DProp false "intersection agrees with naive and stays well-formed" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EDictApp "intersection") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EVar "got"))) (EApp (EMethodRef "toList") (EApp (EApp (EDictApp "naiveIntersection") (EVar "a")) (EVar "b")))) (EApp (EDictApp "wellFormed") (EVar "got"))))))
(DProp false "difference agrees with naive and stays well-formed" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EVar "ys"))) (DoLet false false (PVar "got") (EApp (EApp (EDictApp "difference") (EVar "a")) (EVar "b"))) (DoExpr (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EVar "got"))) (EApp (EMethodRef "toList") (EApp (EApp (EDictApp "naiveDifference") (EVar "a")) (EVar "b")))) (EApp (EDictApp "wellFormed") (EVar "got"))))))
(DProp false "isSubsetOf agrees with the naive fold" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoLet false false (PVar "b") (EApp (EDictApp "fromList") (EVar "ys"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EApp (EDictApp "isSubsetOf") (EVar "a")) (EVar "b"))) (EApp (EApp (EDictApp "naiveIsSubsetOf") (EVar "a")) (EVar "b"))))))
(DProp false "a subset of a union is recognised" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "ys" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PVar "a") (EApp (EDictApp "fromList") (EVar "xs"))) (DoExpr (EApp (EApp (EDictApp "isSubsetOf") (EVar "a")) (EApp (EApp (EDictApp "union") (EVar "a")) (EApp (EDictApp "fromList") (EVar "ys")))))))
(DProp false "splitAt partitions around the element and both halves stay well-formed" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EDictApp "splitAt") (EVar "x")) (EApp (EDictApp "fromList") (EVar "xs")))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EDictApp "wellFormed") (EVar "below")) (EApp (EDictApp "wellFormed") (EVar "above"))) (EApp (EApp (EVar "allElems") (ELam ((PVar "b")) (EApp (EApp (EMethodRef "lt") (EVar "b")) (EVar "x")))) (EVar "below"))) (EApp (EApp (EVar "allElems") (ELam ((PVar "a")) (EApp (EApp (EMethodRef "gt") (EVar "a")) (EVar "x")))) (EVar "above"))))))
(DProp false "link rebuilds a well-formed set from a split" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EDictApp "splitAt") (EVar "x")) (EApp (EDictApp "fromList") (EVar "xs")))) (DoLet false false (PVar "rebuilt") (EApp (EApp (EApp (EVar "link") (EVar "x")) (EVar "below")) (EVar "above"))) (DoExpr (EBinOp "&&" (EApp (EDictApp "wellFormed") (EVar "rebuilt")) (EApp (EApp (EDictApp "has") (EVar "x")) (EVar "rebuilt"))))))
(DProp false "link2 rejoins a split without its element" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBlock (DoLet false false (PTuple (PVar "below") (PVar "above")) (EApp (EApp (EDictApp "splitAt") (EVar "x")) (EApp (EDictApp "fromList") (EVar "xs")))) (DoLet false false (PVar "rebuilt") (EApp (EApp (EVar "link2") (EVar "below")) (EVar "above"))) (DoExpr (EBinOp "&&" (EApp (EDictApp "wellFormed") (EVar "rebuilt")) (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EVar "rebuilt"))) (EApp (EMethodRef "toList") (EApp (EApp (EDictApp "delete") (EVar "x")) (EApp (EDictApp "fromList") (EVar "xs")))))))))
