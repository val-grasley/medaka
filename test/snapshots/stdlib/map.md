# META
source_lines=554
stages=DESUGAR,MARK
# SOURCE
{- map.mdk — an immutable, ordered key→value map.

   See STDLIB.md (Module 5) for the plan.

   Design notes
   ────────────
   `Map k v` is a *weight-balanced binary search tree* (the Adams / Haskell
   `Data.Map` scheme): every interior node caches the size of its subtree, and
   the two invariants

     • search:   keys in the left subtree < node key < keys in the right
     • balance:  neither subtree is more than `delta` times the size of the
                 other (`delta = 3`)

   are maintained by a single smart constructor, `balance`, that rotates when an
   insert or delete tips a node out of balance.  Caching the size makes `size`
   O(1) and the balancing decision a couple of integer comparisons; it also pays
   for `split`-style operations later.

   The whole structure is *persistent* — every operation returns a fresh map and
   shares all the untouched subtrees with the original, so an old version stays
   valid and cheap to keep around.  That is exactly what a compiler's symbol
   tables and scopes want.

   Ordering is by the key's `Ord` instance.  Most operations therefore carry an
   `Ord k` constraint; the few that only walk an existing tree (`size`, `map`,
   `keys`, the folds) do not, because the tree is already in order. -}

-- map/set are identical weight-balanced-tree bodies over DISTINCT ADTs; consolidation needs a Set = Map _ Unit refactor (out of scope).
-- lint-disable-file rule-duplicate-body

import core.{
  Eq,
  Ord,
  Debug,
  Display,
  Mappable,
  Semigroup,
  Monoid,
  Ordering,
  Option,
  FromEntries,
  Index,
}

{- The representation.  `Tip` is the empty tree; `Bin size key value left right`
   is an interior node whose cached `size` is `1 + size left + size right`.
   Public so callers can pattern-match if they really need to, but the smart
   constructors below are the only sanctioned way to *build* one. -}
public export data Map k v = Tip | Bin Int k v (Map k v) (Map k v)

-- ── Internal smart constructors ─────────────────────────────────────────

{- `bin` assembles a node and computes its cached size from the children.
   Use it whenever the children are already balanced relative to each other
   (after a rotation, or when only values changed). -}
bin : k -> v -> Map k v -> Map k v -> Map k v
bin k v l r = Bin (size l + size r + 1) k v l r

{- `balance` is `bin` plus a rebalancing check.  When one subtree grows past
   `delta` (= 3) times the other, a single or double rotation restores the
   weight invariant.  `ratio` (= 2) decides single vs. double: a double
   rotation is needed when the heavy subtree's *inner* grandchild is the bulk. -}
balance : k -> v -> Map k v -> Map k v -> Map k v
balance k v l r
  | size l + size r <= 1 = bin k v l r
  | size r > 3 * size l = rotateL k v l r
  | size l > 3 * size r = rotateR k v l r
  | otherwise = bin k v l r

-- Right subtree too heavy: single left rotation, or double if its left
-- grandchild outweighs its right.
rotateL : k -> v -> Map k v -> Map k v -> Map k v
rotateL k v l (r@(Bin _ _ _ rl rr)) =
  if size rl < 2 * size rr then
    singleL k v l r
  else
    doubleL k v l r
rotateL k v l Tip = panic "Map.rotateL: empty right subtree"

-- Left subtree too heavy: mirror of rotateL.
rotateR : k -> v -> Map k v -> Map k v -> Map k v
rotateR k v (l@(Bin _ _ _ ll lr)) r =
  if size lr < 2 * size ll then
    singleR k v l r
  else
    doubleR k v l r
rotateR k v Tip r = panic "Map.rotateR: empty left subtree"

singleL : k -> v -> Map k v -> Map k v -> Map k v
singleL k1 v1 t1 (Bin _ k2 v2 t2 t3) = bin k2 v2 (bin k1 v1 t1 t2) t3
singleL k1 v1 t1 Tip = panic "Map.singleL: empty right subtree"

singleR : k -> v -> Map k v -> Map k v -> Map k v
singleR k1 v1 (Bin _ k2 v2 t1 t2) t3 = bin k2 v2 t1 (bin k1 v1 t2 t3)
singleR k1 v1 Tip t3 = panic "Map.singleR: empty left subtree"

doubleL : k -> v -> Map k v -> Map k v -> Map k v
doubleL k1 v1 t1 (Bin _ k2 v2 (Bin _ k3 v3 t2 t3) t4) =
  bin k3 v3 (bin k1 v1 t1 t2) (bin k2 v2 t3 t4)
doubleL k1 v1 t1 _ = panic "Map.doubleL: malformed right subtree"

doubleR : k -> v -> Map k v -> Map k v -> Map k v
doubleR k1 v1 (Bin _ k2 v2 t1 (Bin _ k3 v3 t2 t3)) t4 =
  bin k3 v3 (bin k2 v2 t1 t2) (bin k1 v1 t3 t4)
doubleR k1 v1 _ t4 = panic "Map.doubleR: malformed left subtree"

-- ── Construction ────────────────────────────────────────────────────────

-- The empty map is `Monoid.empty` (see `impl Monoid (Map k v)` below); use
-- the `Tip` constructor directly inside this module.

{- | A map with a single entry.

   > size (singleton 1 "a")
   1 -}
export singleton : k -> v -> Map k v
singleton k v = Bin 1 k v Tip Tip

{- | Build a map from an association list.  Later pairs win on duplicate keys.

   The `Map { k => v, … }` literal is sugar for `fromList` (it lowers to a
   `FromEntries` dispatch pinned at `Map`, see the impl at the bottom of this
   file):

   > size (Map { 1 => 10, 2 => 20, 3 => 30 })
   3
   > findWithDefault 0 2 (Map { 1 => 10, 2 => 20 })
   20

   The empty literal `Map { }` works too (Phase 114); annotate to fix the
   element types the empty braces leave open:

   > size (Map { } : Map Int Int)
   0

   > keys (fromList [(3, 0), (1, 0), (2, 0)])
   [1, 2, 3]
   > findWithDefault 0 1 (fromList [(1, 10), (1, 20)])
   20 -}
export fromList : Ord k => List (k, v) -> Map k v
fromList xs = fold (m (k, v) => set k v m) Tip xs

-- ── Query ───────────────────────────────────────────────────────────────

{- | Number of entries.  O(1) — read straight off the root's cached size.

   > size (fromList [(1, 10), (2, 20), (1, 30)])
   2 -}
export size : Map k v -> Int
size Tip = 0
size (Bin s _ _ _ _) = s

{- | `True` when the map has no entries.

   > isEmpty (empty : Map Int Int)
   True -}
export isEmpty : Map k v -> Bool
isEmpty Tip = True
isEmpty _ = False

{- | Look up the value at a key.

   > get 2 (fromList [(1, 10), (2, 20)])
   Some 20
   > get 9 (fromList [(1, 10), (2, 20)])
   None -}
export get : Ord k => k -> Map k v -> Option v
get k Tip = None
get k (Bin _ k2 v l r) = match compare k k2
  Lt => get k l
  Gt => get k r
  Eq => Some v

{- | `index m k` looks up `m`'s value at key `k` (`m[k]` sugar dispatches
   here).  Raises the coded `indexError` (E-INDEX-OOB) when the key is
   absent -- use `get` for a safe `Option`-returning read instead.  Note the
   flipped argument order vs. `get k m`: the `Index` interface always takes
   the container first (`index m k`). -}
export impl Index (Map k v) k v requires Ord k where
  index m k = match get k m
    Some v => v
    None => indexError "key not found"

{- | `True` when the key is present.

   > has 2 (fromList [(1, 10), (2, 20)])
   True
   > has 9 (fromList [(1, 10), (2, 20)])
   False -}
export has : Ord k => k -> Map k v -> Bool
has k Tip = False
has k (Bin _ k2 _ l r) = match compare k k2
  Lt => has k l
  Gt => has k r
  Eq => True

{- | Value at a key, or a fallback when the key is absent.

   > findWithDefault 0 2 (fromList [(1, 10), (2, 20)])
   20
   > findWithDefault 0 9 (fromList [(1, 10), (2, 20)])
   0 -}
export findWithDefault : Ord k => v -> k -> Map k v -> v
findWithDefault d k m = match get k m
  None => d
  Some v => v

-- ── Insertion ───────────────────────────────────────────────────────────

{- | Insert a key/value pair, replacing any existing value at the key.

   > findWithDefault 0 2 (set 2 99 (fromList [(1, 10), (2, 20)]))
   99 -}
export set : Ord k => k -> v -> Map k v -> Map k v
set k v Tip = singleton k v
set k v (Bin s k2 v2 l r) = match compare k k2
  Lt => balance k2 v2 (set k v l) r
  Gt => balance k2 v2 l (set k v r)
  Eq => Bin s k v l r

{- | Insert with a combining function.  On a collision the new value is
   `f newValue oldValue`; on a fresh key the value is stored as-is.

   > findWithDefault 0 1 (insertWith (n o => n + o) 1 5 (fromList [(1, 10)]))
   15 -}
export insertWith : Ord k => (v -> v -> v) -> k -> v -> Map k v -> Map k v
insertWith f k v Tip = singleton k v
insertWith f k v (Bin s k2 v2 l r) = match compare k k2
  Lt => balance k2 v2 (insertWith f k v l) r
  Gt => balance k2 v2 l (insertWith f k v r)
  Eq => Bin s k2 (f v v2) l r

{- | Apply a function to the value at a key, if present.  A no-op when the key
   is absent.  The tree shape is unchanged, so no rebalancing is needed.

   > findWithDefault 0 1 (adjust (n => n * 10) 1 (fromList [(1, 5), (2, 6)]))
   50 -}
export adjust : Ord k => (v -> v) -> k -> Map k v -> Map k v
adjust f k Tip = Tip
adjust f k (Bin s k2 v2 l r) = match compare k k2
  Lt => Bin s k2 v2 (adjust f k l) r
  Gt => Bin s k2 v2 l (adjust f k r)
  Eq => Bin s k2 (f v2) l r

-- ── Deletion ────────────────────────────────────────────────────────────

{- | Remove a key.  A no-op when the key is absent.

   > has 2 (delete 2 (fromList [(1, 10), (2, 20)]))
   False
   > size (delete 9 (fromList [(1, 10), (2, 20)]))
   2 -}
export delete : Ord k => k -> Map k v -> Map k v
delete k Tip = Tip
delete k (Bin _ k2 v2 l r) = match compare k k2
  Lt => balance k2 v2 (delete k l) r
  Gt => balance k2 v2 l (delete k r)
  Eq => glue l r

{- `glue` joins two subtrees that were siblings under a now-deleted node, so
   every key on the left is below every key on the right.  It promotes the max
   of the larger side (or the min of the other) to be the new root, keeping the
   result balanced. -}
glue : Map k v -> Map k v -> Map k v
glue Tip r = r
glue l Tip = l
glue l r
  | size l > size r = glueMax l r
  | otherwise = glueMin l r

glueMax : Map k v -> Map k v -> Map k v
glueMax l r = match maxView l
  None => r
  Some (k, v, l') => balance k v l' r

glueMin : Map k v -> Map k v -> Map k v
glueMin l r = match minView r
  None => l
  Some (k, v, r') => balance k v l r'

-- ── Min / max ───────────────────────────────────────────────────────────

{- | Split off the smallest entry: `Some (key, value, rest)`, or `None` when
   empty.  `rest` stays balanced. -}
export minView : Map k v -> Option (k, v, Map k v)
minView Tip = None
minView (Bin _ k v l r) = match minView l
  None => Some (k, v, r)
  Some (km, vm, l') => Some (km, vm, balance k v l' r)

{- | Split off the largest entry: `Some (key, value, rest)`, or `None`. -}
export maxView : Map k v -> Option (k, v, Map k v)
maxView Tip = None
maxView (Bin _ k v l r) = match maxView r
  None => Some (k, v, l)
  Some (km, vm, r') => Some (km, vm, balance k v l r')

{- | Smallest key/value, or `None`.

   > getMin (fromList [(3, 0), (1, 0), (2, 0)])
   Some (1, 0) -}
export getMin : Map k v -> Option (k, v)
getMin m = map ((k, v, _) => (k, v)) (minView m)

{- | Largest key/value, or `None`.

   > getMax (fromList [(3, 0), (1, 0), (2, 0)])
   Some (3, 0) -}
export getMax : Map k v -> Option (k, v)
getMax m = map ((k, v, _) => (k, v)) (maxView m)

{- | Drop the smallest entry (a no-op on the empty map).

   > keys (deleteMin (fromList [(3, 0), (1, 0), (2, 0)]))
   [2, 3] -}
export deleteMin : Map k v -> Map k v
deleteMin m = match minView m
  None => Tip
  Some (_, _, m') => m'

{- | Drop the largest entry (a no-op on the empty map).

   > keys (deleteMax (fromList [(3, 0), (1, 0), (2, 0)]))
   [1, 2] -}
export deleteMax : Map k v -> Map k v
deleteMax m = match maxView m
  None => Tip
  Some (_, _, m') => m'

-- ── Folds and traversal (in ascending key order) ────────────────────────

{- | Right fold over key/value pairs in ascending key order. -}
export foldrWithKey : (k -> v -> b -> <e> b) -> b -> Map k v -> <e> b
foldrWithKey f z Tip = z
foldrWithKey f z (Bin _ k v l r) = foldrWithKey f (f k v (foldrWithKey f z r)) l

{- | Left fold over key/value pairs in ascending key order. -}
export foldlWithKey : (b -> k -> v -> <e> b) -> b -> Map k v -> <e> b
foldlWithKey f z Tip = z
foldlWithKey f z (Bin _ k v l r) = foldlWithKey f (f (foldlWithKey f z l) k v) r

{- | All key/value pairs, ascending by key.

   > toList (fromList [(2, 20), (1, 10), (3, 30)])
   [(1, 10), (2, 20), (3, 30)] -}
export toList : Map k v -> List (k, v)
toList m = foldrWithKey (k v acc => (k, v)::acc) [] m

{- | All keys, ascending.

   > keys (fromList [(2, 0), (3, 0), (1, 0)])
   [1, 2, 3] -}
export keys : Map k v -> List k
keys m = foldrWithKey (k _ acc => k::acc) [] m

{- | All values, ordered by their keys.

   > elems (fromList [(2, 20), (1, 10), (3, 30)])
   [10, 20, 30] -}
export elems : Map k v -> List v
elems m = foldrWithKey (k v acc => v::acc) [] m

{- | Map a function over the values, keeping keys and structure.  The key is
   passed alongside the value.

   > elems (mapWithKey (k v => k + v) (fromList [(1, 10), (2, 20)]))
   [11, 22] -}
export mapWithKey : (k -> v -> <e> w) -> Map k v -> <e> Map k w
mapWithKey f Tip = Tip
mapWithKey f (Bin s k v l r) = Bin s k (f k v) (mapWithKey f l) (mapWithKey f r)

{- | Keep only the entries whose key/value satisfy the predicate.

   > keys (filterWithKey (k v => v > 15) (fromList [(1, 10), (2, 20), (3, 30)]))
   [2, 3] -}
export filterWithKey : Ord k => (k -> v -> <e> Bool) -> Map k v -> <e> Map k v
filterWithKey p m = foldrWithKey (filterStep p) Tip m

filterStep : Ord k => (k -> v -> <e> Bool) -> k -> v -> Map k v -> <e> Map k v
filterStep p k v acc = if p k v then set k v acc else acc

-- ── Combining ───────────────────────────────────────────────────────────

{- | Left-biased union: on a shared key the value from the first map wins.

   > findWithDefault 0 1 (union (fromList [(1, 1)]) (fromList [(1, 2), (2, 2)]))
   1
   > size (union (fromList [(1, 1)]) (fromList [(1, 2), (2, 2)]))
   2 -}
export union : Ord k => Map k v -> Map k v -> Map k v
union a b = foldrWithKey (k v acc => set k v acc) b a

{- | Union with a combining function for shared keys: `f leftValue rightValue`.

   > findWithDefault 0 1 (unionWith (x y => x + y) (fromList [(1, 1)]) (fromList [(1, 2)]))
   3 -}
export unionWith : Ord k => (v -> v -> v) -> Map k v -> Map k v -> Map k v
unionWith f a b = foldrWithKey (k v acc => insertWith f k v acc) b a

{- | Keys present in the first map but not the second (values from the first).

   > keys (difference (fromList [(1, 0), (2, 0), (3, 0)]) (fromList [(2, 0)]))
   [1, 3] -}
export difference : Ord k => Map k v -> Map k w -> Map k v
difference a b = foldrWithKey (k _ acc => delete k acc) a b

{- | Keys present in both maps, combined with `f leftValue rightValue`.

   > toList (intersectionWith (x y => x + y) (fromList [(1, 10), (2, 20)]) (fromList [(2, 2), (3, 3)]))
   [(2, 22)] -}
export intersectionWith : Ord k => (v -> w -> x) -> Map k v -> Map k w -> Map k x
intersectionWith f a b = foldrWithKey (intersectStep f b) Tip a

intersectStep : Ord k => (v -> w -> x) -> Map k w -> k -> v -> Map k x -> Map k x
intersectStep f b k v acc = match get k b
  None => acc
  Some w => set k (f v w) acc

-- ── Typeclass instances ─────────────────────────────────────────────────

{- | Map over the values, keys and structure preserved.

   > elems (map (n => n * 10) (fromList [(1, 1), (2, 2)]))
   [10, 20] -}
export impl Mappable (Map k) where
  map f Tip = Tip
  map f (Bin s k v l r) = Bin s k (f v) (map f l) (map f r)

{- | Structural equality: same keys mapped to equal values.  Compared through
   the canonical ascending association list, so tree *shape* doesn't matter.

   > eq (fromList [(1, 10), (2, 20)]) (fromList [(2, 20), (1, 10)])
   True -}
export impl Eq (Map k v) requires Eq k, Eq v where
  eq a b = if size a != size b then False else eq (toList a) (toList b)

{- | Lexicographic ordering through the canonical ascending association list,
   so two maps order by their `(key, value)` pairs and a proper prefix sorts
   first.  Enables nesting (`Map (Set k) v`) and sorting `List (Map …)`.

   > compare (fromList [(1, 10)]) (fromList [(1, 20)])
   Lt -}
export impl Ord (Map k v) requires Ord k, Ord v where
  compare a b = compare (toList a) (toList b)

{- | Rendered as `fromList [(k, v), …]`, mirroring the constructor that would
   rebuild it.  (Doctest compares against a literal: `Debug String` lives in
   string.mdk, out of this module's isolated test context.)

   > debug (fromList [(1, 10), (2, 20)]) == "fromList [(1, 10), (2, 20)]"
   True -}
export impl Debug (Map k v) requires Debug k, Debug v where
  debug m = "fromList \{debug (toList m)}"

-- Comma-joined `k => v` entries for `Display (Map k v)`; keys/values render via
-- `display` (unquoted), the Display convention.  `toList` gives ascending pairs.
displayMapEntries : (Display k, Display v) => List (k, v) -> String
displayMapEntries [] = ""
displayMapEntries [(k, v)] = "\{k} => \{v}"
displayMapEntries ((k, v)::rest) = "\{k} => \{v}, \{displayMapEntries rest}"

{- | The *display* form — the Phase-108 literal `Map { k => v, … }` (empty →
   `Map {}`), as opposed to Debug's re-evaluable `fromList [(k, v), …]`.

   > display (fromList [(1, 10), (2, 20)]) == "Map { 1 => 10, 2 => 20 }"
   True
   > display (empty : Map Int Int) == "Map {}"
   True -}
export impl Display (Map k v) requires Display k, Display v where
  display m = match toList m
    [] => "Map {}"
    es => "Map { \{displayMapEntries es} }"

{- | `++` on maps is left-biased union (the left map wins on shared keys).

   `append` dispatches on its first `Map` argument, so the `Ord k` it needs to
   merge threads in by the ordinary route. -}
export impl Semigroup (Map k v) requires Ord k where
  append a b = union a b

{- | Backs the `Map { k => v, … }` literal: the compiler lowers that to
   `fromEntries [(k, v), …]` pinned at `Map`, dispatching here.  The `Ord k`
   the build needs threads in by the ordinary return-position route. -}
export impl FromEntries (Map k v) (k, v) requires Ord k where
  fromEntries es = fromList es

{- | `Monoid.empty` for `Map` is the empty tree.  `empty` is nullary and so
   dispatches on its *result* type (Phase 103); the impl's `requires Ord k`
   carries no dict here because `Tip` needs none, so a return-position `empty :
   Map k v` grounds cleanly.

   > isEmpty (empty : Map Int Int)
   True -}
export impl Monoid (Map k v) requires Ord k where
  empty = Tip

-- ── Structural invariants (for testing / debugging) ─────────────────────

{- | Check the three structural invariants at every node: the search-tree
   order (left keys < node key < right keys), the cached `size` matching the
   actual subtree size, and the weight-balance bound (neither sibling more than
   `delta` times the other).  A correct sequence of operations always leaves a
   map `wellFormed`; it is exported as a debugging aid and as the backbone of
   this module's property tests.  Re-walks subtrees for the order check, so it
   is O(n log n) — not for hot paths. -}
export wellFormed : Ord k => Map k v -> Bool
wellFormed Tip = True
wellFormed (Bin s k v l r) =
  let sizeOk = size l + size r + 1 == s
  let orderOk = allKeys (lk => lt lk k) l && allKeys (gk => gt gk k) r
  sizeOk && balancedAt l r && orderOk && wellFormed l && wellFormed r

-- Every key in the subtree satisfies the predicate.
allKeys : (k -> Bool) -> Map k v -> Bool
allKeys p Tip = True
allKeys p (Bin _ k _ l r) = p k && allKeys p l && allKeys p r

-- The weight-balance bound between two siblings: tiny pairs are exempt,
-- otherwise neither may exceed `delta` (= 3) times the other.
balancedAt : Map k v -> Map k v -> Bool
balancedAt l r =
  let sl = size l
  let sr = size r
  if sl + sr <= 1 then True else sl <= 3 * sr && sr <= 3 * sl

-- Strictly-ascending check used by the key-ordering property.
ascending : Ord a => List a -> Bool
ascending [] = True
ascending [x] = True
ascending (x::y::rest) = lt x y && ascending (y::rest)

-- ── Properties ──────────────────────────────────────────────────────────

prop "fromList builds a well-formed tree" (xs : List (Int, Int)) =
  wellFormed (fromList xs)

prop "keys come out strictly ascending" (xs : List (Int, Int)) =
  ascending (keys (fromList xs))

prop "insert then lookup returns the inserted value" (k : Int) (v : Int) (xs : List (Int, Int)) = eq (get k (set k v (fromList xs))) (Some v)

prop "insert preserves well-formedness" (k : Int) (v : Int) (xs : List (Int, Int)) = wellFormed (set k v (fromList xs))

prop "delete removes the key and preserves well-formedness" (k : Int) (xs : List (Int, Int)) =
  let m = delete k (fromList xs)
  not (has k m) && wellFormed m

prop "union preserves well-formedness" (xs : List (Int, Int)) (ys : List (Int, Int)) = wellFormed (union (fromList xs) (fromList ys))

prop "union is left-biased on shared keys" (k : Int) (xs : List (Int, Int)) =
  let l = set k 1 (fromList xs)
  let r = set k 2 (fromList xs)
  eq (get k (union l r)) (Some 1)
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Mappable" false) (mem "Semigroup" false) (mem "Monoid" false) (mem "Ordering" false) (mem "Option" false) (mem "FromEntries" false) (mem "Index" false))))
(DData Public "Map" ("k" "v") ((variant "Tip" (ConPos)) (variant "Bin" (ConPos (TyCon "Int") (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))) ())
(DTypeSig false "bin" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "bin" ((PVar "k") (PVar "v") (PVar "l") (PVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")))
(DTypeSig false "balance" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "balance" ((PVar "k") (PVar "v") (PVar "l") (PVar "r")) (EIf (EBinOp "<=" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "r")) (EBinOp "*" (ELit (LInt 3)) (EApp (EVar "size") (EVar "l")))) (EApp (EApp (EApp (EApp (EVar "rotateL") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "l")) (EBinOp "*" (ELit (LInt 3)) (EApp (EVar "size") (EVar "r")))) (EApp (EApp (EApp (EApp (EVar "rotateR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "rotateL" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "rotateL" ((PVar "k") (PVar "v") (PVar "l") (PAs "r" (PCon "Bin" PWild PWild PWild (PVar "rl") (PVar "rr")))) (EIf (EBinOp "<" (EApp (EVar "size") (EVar "rl")) (EBinOp "*" (ELit (LInt 2)) (EApp (EVar "size") (EVar "rr")))) (EApp (EApp (EApp (EApp (EVar "singleL") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EApp (EVar "doubleL") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r"))))
(DFunDef false "rotateL" ((PVar "k") (PVar "v") (PVar "l") (PCon "Tip")) (EApp (EVar "panic") (ELit (LString "Map.rotateL: empty right subtree"))))
(DTypeSig false "rotateR" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "rotateR" ((PVar "k") (PVar "v") (PAs "l" (PCon "Bin" PWild PWild PWild (PVar "ll") (PVar "lr"))) (PVar "r")) (EIf (EBinOp "<" (EApp (EVar "size") (EVar "lr")) (EBinOp "*" (ELit (LInt 2)) (EApp (EVar "size") (EVar "ll")))) (EApp (EApp (EApp (EApp (EVar "singleR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EApp (EVar "doubleR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r"))))
(DFunDef false "rotateR" ((PVar "k") (PVar "v") (PCon "Tip") (PVar "r")) (EApp (EVar "panic") (ELit (LString "Map.rotateR: empty left subtree"))))
(DTypeSig false "singleL" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "singleL" ((PVar "k1") (PVar "v1") (PVar "t1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "t2") (PVar "t3"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t1")) (EVar "t2"))) (EVar "t3")))
(DFunDef false "singleL" ((PVar "k1") (PVar "v1") (PVar "t1") (PCon "Tip")) (EApp (EVar "panic") (ELit (LString "Map.singleL: empty right subtree"))))
(DTypeSig false "singleR" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "singleR" ((PVar "k1") (PVar "v1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "t1") (PVar "t2")) (PVar "t3")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EVar "t1")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t2")) (EVar "t3"))))
(DFunDef false "singleR" ((PVar "k1") (PVar "v1") (PCon "Tip") (PVar "t3")) (EApp (EVar "panic") (ELit (LString "Map.singleR: empty left subtree"))))
(DTypeSig false "doubleL" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "doubleL" ((PVar "k1") (PVar "v1") (PVar "t1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PCon "Bin" PWild (PVar "k3") (PVar "v3") (PVar "t2") (PVar "t3")) (PVar "t4"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k3")) (EVar "v3")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t1")) (EVar "t2"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EVar "t3")) (EVar "t4"))))
(DFunDef false "doubleL" ((PVar "k1") (PVar "v1") (PVar "t1") PWild) (EApp (EVar "panic") (ELit (LString "Map.doubleL: malformed right subtree"))))
(DTypeSig false "doubleR" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "doubleR" ((PVar "k1") (PVar "v1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "t1") (PCon "Bin" PWild (PVar "k3") (PVar "v3") (PVar "t2") (PVar "t3"))) (PVar "t4")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k3")) (EVar "v3")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EVar "t1")) (EVar "t2"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t3")) (EVar "t4"))))
(DFunDef false "doubleR" ((PVar "k1") (PVar "v1") PWild (PVar "t4")) (EApp (EVar "panic") (ELit (LString "Map.doubleR: malformed left subtree"))))
(DTypeSig true "singleton" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "singleton" ((PVar "k") (PVar "v")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (ELit (LInt 1))) (EVar "k")) (EVar "v")) (EVar "Tip")) (EVar "Tip")))
(DTypeSig true "fromList" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "fromList" ((PVar "xs")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PTuple (PVar "k") (PVar "v"))) (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "Tip")) (EVar "xs")))
(DTypeSig true "size" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Int")))
(DFunDef false "size" ((PCon "Tip")) (ELit (LInt 0)))
(DFunDef false "size" ((PCon "Bin" (PVar "s") PWild PWild PWild PWild)) (EVar "s"))
(DTypeSig true "isEmpty" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))
(DFunDef false "isEmpty" ((PCon "Tip")) (EVar "True"))
(DFunDef false "isEmpty" (PWild) (EVar "False"))
(DTypeSig true "get" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "get" ((PVar "k") (PCon "Tip")) (EVar "None"))
(DFunDef false "get" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EVar "get") (EVar "k")) (EVar "l"))) (arm (PCon "Gt") () (EApp (EApp (EVar "get") (EVar "k")) (EVar "r"))) (arm (PCon "Eq") () (EApp (EVar "Some") (EVar "v")))))
(DImpl true "Index" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyVar "k") (TyVar "v")) ((req "Ord" ((TyVar "k")))) ((im "index" ((PVar "m") (PVar "k")) (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "m")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "indexError") (ELit (LString "key not found"))))))))
(DTypeSig true "has" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))))
(DFunDef false "has" ((PVar "k") (PCon "Tip")) (EVar "False"))
(DFunDef false "has" ((PVar "k") (PCon "Bin" PWild (PVar "k2") PWild (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EVar "has") (EVar "k")) (EVar "l"))) (arm (PCon "Gt") () (EApp (EApp (EVar "has") (EVar "k")) (EVar "r"))) (arm (PCon "Eq") () (EVar "True"))))
(DTypeSig true "findWithDefault" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "v") (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyVar "v"))))))
(DFunDef false "findWithDefault" ((PVar "d") (PVar "k") (PVar "m")) (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "m")) (arm (PCon "None") () (EVar "d")) (arm (PCon "Some" (PVar "v")) () (EVar "v"))))
(DTypeSig true "set" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "set" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "set" ((PVar "k") (PVar "v") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")))))
(DTypeSig true "insertWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))))
(DFunDef false "insertWith" ((PVar "f") (PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertWith" ((PVar "f") (PVar "k") (PVar "v") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EApp (EVar "insertWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "insertWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "v2"))) (EVar "l")) (EVar "r")))))
(DTypeSig true "adjust" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyVar "v")) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "adjust" ((PVar "f") (PVar "k") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "adjust" ((PVar "f") (PVar "k") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EVar "adjust") (EVar "f")) (EVar "k")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EVar "adjust") (EVar "f")) (EVar "k")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EApp (EVar "f") (EVar "v2"))) (EVar "l")) (EVar "r")))))
(DTypeSig true "delete" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "delete" ((PVar "k") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "delete" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EVar "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EApp (EApp (EVar "delete") (EVar "k")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EVar "delete") (EVar "k")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EVar "glue") (EVar "l")) (EVar "r")))))
(DTypeSig false "glue" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glue" ((PCon "Tip") (PVar "r")) (EVar "r"))
(DFunDef false "glue" ((PVar "l") (PCon "Tip")) (EVar "l"))
(DFunDef false "glue" ((PVar "l") (PVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (EApp (EApp (EVar "glueMax") (EVar "l")) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EVar "glueMin") (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "glueMax" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glueMax" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "maxView") (EVar "l")) (arm (PCon "None") () (EVar "r")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v") (PVar "l'"))) () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l'")) (EVar "r")))))
(DTypeSig false "glueMin" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glueMin" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "minView") (EVar "r")) (arm (PCon "None") () (EVar "l")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v") (PVar "r'"))) () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r'")))))
(DTypeSig true "minView" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "minView" ((PCon "Tip")) (EVar "None"))
(DFunDef false "minView" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EMatch (EApp (EVar "minView") (EVar "l")) (arm (PCon "None") () (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v") (EVar "r")))) (arm (PCon "Some" (PTuple (PVar "km") (PVar "vm") (PVar "l'"))) () (EApp (EVar "Some") (ETuple (EVar "km") (EVar "vm") (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l'")) (EVar "r")))))))
(DTypeSig true "maxView" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "maxView" ((PCon "Tip")) (EVar "None"))
(DFunDef false "maxView" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EMatch (EApp (EVar "maxView") (EVar "r")) (arm (PCon "None") () (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v") (EVar "l")))) (arm (PCon "Some" (PTuple (PVar "km") (PVar "vm") (PVar "r'"))) () (EApp (EVar "Some") (ETuple (EVar "km") (EVar "vm") (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r'")))))))
(DTypeSig true "getMin" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "getMin" ((PVar "m")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "k") (PVar "v") PWild)) (ETuple (EVar "k") (EVar "v")))) (EApp (EVar "minView") (EVar "m"))))
(DTypeSig true "getMax" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "getMax" ((PVar "m")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "k") (PVar "v") PWild)) (ETuple (EVar "k") (EVar "v")))) (EApp (EVar "maxView") (EVar "m"))))
(DTypeSig true "deleteMin" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))
(DFunDef false "deleteMin" ((PVar "m")) (EMatch (EApp (EVar "minView") (EVar "m")) (arm (PCon "None") () (EVar "Tip")) (arm (PCon "Some" (PTuple PWild PWild (PVar "m'"))) () (EVar "m'"))))
(DTypeSig true "deleteMax" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))
(DFunDef false "deleteMax" ((PVar "m")) (EMatch (EApp (EVar "maxView") (EVar "m")) (arm (PCon "None") () (EVar "Tip")) (arm (PCon "Some" (PTuple PWild PWild (PVar "m'"))) () (EVar "m'"))))
(DTypeSig true "foldrWithKey" (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b"))))) (TyFun (TyVar "b") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldrWithKey" ((PVar "f") (PVar "z") (PCon "Tip")) (EVar "z"))
(DFunDef false "foldrWithKey" ((PVar "f") (PVar "z") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "foldrWithKey") (EVar "f")) (EApp (EApp (EApp (EVar "f") (EVar "k")) (EVar "v")) (EApp (EApp (EApp (EVar "foldrWithKey") (EVar "f")) (EVar "z")) (EVar "r")))) (EVar "l")))
(DTypeSig true "foldlWithKey" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "k") (TyFun (TyVar "v") (TyEffect () (Some "e") (TyVar "b"))))) (TyFun (TyVar "b") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldlWithKey" ((PVar "f") (PVar "z") (PCon "Tip")) (EVar "z"))
(DFunDef false "foldlWithKey" ((PVar "f") (PVar "z") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "foldlWithKey") (EVar "f")) (EApp (EApp (EApp (EVar "f") (EApp (EApp (EApp (EVar "foldlWithKey") (EVar "f")) (EVar "z")) (EVar "l"))) (EVar "k")) (EVar "v"))) (EVar "r")))
(DTypeSig true "toList" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "toList" ((PVar "m")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") (PVar "v") (PVar "acc")) (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EVar "acc")))) (EListLit)) (EVar "m")))
(DTypeSig true "keys" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "k"))))
(DFunDef false "keys" ((PVar "m")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") PWild (PVar "acc")) (EBinOp "::" (EVar "k") (EVar "acc")))) (EListLit)) (EVar "m")))
(DTypeSig true "elems" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "v"))))
(DFunDef false "elems" ((PVar "m")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") (PVar "v") (PVar "acc")) (EBinOp "::" (EVar "v") (EVar "acc")))) (EListLit)) (EVar "m")))
(DTypeSig true "mapWithKey" (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyEffect () (Some "e") (TyVar "w")))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w"))))))
(DFunDef false "mapWithKey" ((PVar "f") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "mapWithKey" ((PVar "f") (PCon "Bin" (PVar "s") (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EApp (EApp (EVar "f") (EVar "k")) (EVar "v"))) (EApp (EApp (EVar "mapWithKey") (EVar "f")) (EVar "l"))) (EApp (EApp (EVar "mapWithKey") (EVar "f")) (EVar "r"))))
(DTypeSig true "filterWithKey" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyEffect () (Some "e") (TyCon "Bool")))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "filterWithKey" ((PVar "p") (PVar "m")) (EApp (EApp (EApp (EVar "foldrWithKey") (EApp (EVar "filterStep") (EVar "p"))) (EVar "Tip")) (EVar "m")))
(DTypeSig false "filterStep" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyEffect () (Some "e") (TyCon "Bool")))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))))
(DFunDef false "filterStep" ((PVar "p") (PVar "k") (PVar "v") (PVar "acc")) (EIf (EApp (EApp (EVar "p") (EVar "k")) (EVar "v")) (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EVar "acc")) (EVar "acc")))
(DTypeSig true "union" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "union" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") (PVar "v") (PVar "acc")) (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EVar "acc")))) (EVar "b")) (EVar "a")))
(DTypeSig true "unionWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "unionWith" ((PVar "f") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") (PVar "v") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "insertWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "acc")))) (EVar "b")) (EVar "a")))
(DTypeSig true "difference" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "difference" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") PWild (PVar "acc")) (EApp (EApp (EVar "delete") (EVar "k")) (EVar "acc")))) (EVar "a")) (EVar "b")))
(DTypeSig true "intersectionWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "w") (TyVar "x"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "x")))))))
(DFunDef false "intersectionWith" ((PVar "f") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (EApp (EApp (EVar "intersectStep") (EVar "f")) (EVar "b"))) (EVar "Tip")) (EVar "a")))
(DTypeSig false "intersectStep" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "w") (TyVar "x"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "x")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "x")))))))))
(DFunDef false "intersectStep" ((PVar "f") (PVar "b") (PVar "k") (PVar "v") (PVar "acc")) (EMatch (EApp (EApp (EVar "get") (EVar "k")) (EVar "b")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "w")) () (EApp (EApp (EApp (EVar "set") (EVar "k")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "w"))) (EVar "acc")))))
(DImpl true "Mappable" ((TyApp (TyCon "Map") (TyVar "k"))) () ((im "map" ((PVar "f") (PCon "Tip")) (EVar "Tip")) (im "map" ((PVar "f") (PCon "Bin" (PVar "s") (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EApp (EVar "f") (EVar "v"))) (EApp (EApp (EVar "map") (EVar "f")) (EVar "l"))) (EApp (EApp (EVar "map") (EVar "f")) (EVar "r"))))))
(DImpl true "Eq" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Eq" ((TyVar "k"))) (req "Eq" ((TyVar "v")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "!=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EVar "False") (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EVar "a"))) (EApp (EVar "toList") (EVar "b")))))))
(DImpl true "Ord" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Ord" ((TyVar "k"))) (req "Ord" ((TyVar "v")))) ((im "compare" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "compare") (EApp (EVar "toList") (EVar "a"))) (EApp (EVar "toList") (EVar "b"))))))
(DImpl true "Debug" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Debug" ((TyVar "k"))) (req "Debug" ((TyVar "v")))) ((im "debug" ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EVar "display") (EApp (EVar "debug") (EApp (EVar "toList") (EVar "m"))))) (ELit (LString ""))))))
(DTypeSig false "displayMapEntries" (TyConstrained ((cstr "Display" (TyVar "k")) (cstr "Display" (TyVar "v"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "String"))))
(DFunDef false "displayMapEntries" ((PList)) (ELit (LString "")))
(DFunDef false "displayMapEntries" ((PList (PTuple (PVar "k") (PVar "v")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "k"))) (ELit (LString " => "))) (EApp (EVar "display") (EVar "v"))) (ELit (LString ""))))
(DFunDef false "displayMapEntries" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "k"))) (ELit (LString " => "))) (EApp (EVar "display") (EVar "v"))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "displayMapEntries") (EVar "rest")))) (ELit (LString ""))))
(DImpl true "Display" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Display" ((TyVar "k"))) (req "Display" ((TyVar "v")))) ((im "display" ((PVar "m")) (EMatch (EApp (EVar "toList") (EVar "m")) (arm (PList) () (ELit (LString "Map {}"))) (arm (PVar "es") () (EBinOp "++" (EBinOp "++" (ELit (LString "Map { ")) (EApp (EVar "display") (EApp (EVar "displayMapEntries") (EVar "es")))) (ELit (LString " }"))))))))
(DImpl true "Semigroup" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Ord" ((TyVar "k")))) ((im "append" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "union") (EVar "a")) (EVar "b")))))
(DImpl true "FromEntries" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyTuple (TyVar "k") (TyVar "v"))) ((req "Ord" ((TyVar "k")))) ((im "fromEntries" ((PVar "es")) (EApp (EVar "fromList") (EVar "es")))))
(DImpl true "Monoid" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Ord" ((TyVar "k")))) ((im "empty" () (EVar "Tip"))))
(DTypeSig true "wellFormed" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool"))))
(DFunDef false "wellFormed" ((PCon "Tip")) (EVar "True"))
(DFunDef false "wellFormed" ((PCon "Bin" (PVar "s") (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EBlock (DoLet false false (PVar "sizeOk") (EBinOp "==" (EBinOp "+" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1))) (EVar "s"))) (DoLet false false (PVar "orderOk") (EBinOp "&&" (EApp (EApp (EVar "allKeys") (ELam ((PVar "lk")) (EApp (EApp (EVar "lt") (EVar "lk")) (EVar "k")))) (EVar "l")) (EApp (EApp (EVar "allKeys") (ELam ((PVar "gk")) (EApp (EApp (EVar "gt") (EVar "gk")) (EVar "k")))) (EVar "r")))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "sizeOk") (EApp (EApp (EVar "balancedAt") (EVar "l")) (EVar "r"))) (EVar "orderOk")) (EApp (EVar "wellFormed") (EVar "l"))) (EApp (EVar "wellFormed") (EVar "r"))))))
(DTypeSig false "allKeys" (TyFun (TyFun (TyVar "k") (TyCon "Bool")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool"))))
(DFunDef false "allKeys" ((PVar "p") (PCon "Tip")) (EVar "True"))
(DFunDef false "allKeys" ((PVar "p") (PCon "Bin" PWild (PVar "k") PWild (PVar "l") (PVar "r"))) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "p") (EVar "k")) (EApp (EApp (EVar "allKeys") (EVar "p")) (EVar "l"))) (EApp (EApp (EVar "allKeys") (EVar "p")) (EVar "r"))))
(DTypeSig false "balancedAt" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool"))))
(DFunDef false "balancedAt" ((PVar "l") (PVar "r")) (EBlock (DoLet false false (PVar "sl") (EApp (EVar "size") (EVar "l"))) (DoLet false false (PVar "sr") (EApp (EVar "size") (EVar "r"))) (DoExpr (EIf (EBinOp "<=" (EBinOp "+" (EVar "sl") (EVar "sr")) (ELit (LInt 1))) (EVar "True") (EBinOp "&&" (EBinOp "<=" (EVar "sl") (EBinOp "*" (ELit (LInt 3)) (EVar "sr"))) (EBinOp "<=" (EVar "sr") (EBinOp "*" (ELit (LInt 3)) (EVar "sl"))))))))
(DTypeSig false "ascending" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "ascending" ((PList)) (EVar "True"))
(DFunDef false "ascending" ((PList (PVar "x"))) (EVar "True"))
(DFunDef false "ascending" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EBinOp "&&" (EApp (EApp (EVar "lt") (EVar "x")) (EVar "y")) (EApp (EVar "ascending") (EBinOp "::" (EVar "y") (EVar "rest")))))
(DProp false "fromList builds a well-formed tree" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EVar "wellFormed") (EApp (EVar "fromList") (EVar "xs"))))
(DProp false "keys come out strictly ascending" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EVar "ascending") (EApp (EVar "keys") (EApp (EVar "fromList") (EVar "xs")))))
(DProp false "insert then lookup returns the inserted value" ((pp "k" (TyCon "Int")) (pp "v" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EApp (EVar "eq") (EApp (EApp (EVar "get") (EVar "k")) (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EApp (EVar "fromList") (EVar "xs"))))) (EApp (EVar "Some") (EVar "v"))))
(DProp false "insert preserves well-formedness" ((pp "k" (TyCon "Int")) (pp "v" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EVar "wellFormed") (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EApp (EVar "fromList") (EVar "xs")))))
(DProp false "delete removes the key and preserves well-formedness" ((pp "k" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EApp (EVar "delete") (EVar "k")) (EApp (EVar "fromList") (EVar "xs")))) (DoExpr (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "k")) (EVar "m"))) (EApp (EVar "wellFormed") (EVar "m"))))))
(DProp false "union preserves well-formedness" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EVar "wellFormed") (EApp (EApp (EVar "union") (EApp (EVar "fromList") (EVar "xs"))) (EApp (EVar "fromList") (EVar "ys")))))
(DProp false "union is left-biased on shared keys" ((pp "k" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "l") (EApp (EApp (EApp (EVar "set") (EVar "k")) (ELit (LInt 1))) (EApp (EVar "fromList") (EVar "xs")))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "set") (EVar "k")) (ELit (LInt 2))) (EApp (EVar "fromList") (EVar "xs")))) (DoExpr (EApp (EApp (EVar "eq") (EApp (EApp (EVar "get") (EVar "k")) (EApp (EApp (EVar "union") (EVar "l")) (EVar "r")))) (EApp (EVar "Some") (ELit (LInt 1)))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Mappable" false) (mem "Semigroup" false) (mem "Monoid" false) (mem "Ordering" false) (mem "Option" false) (mem "FromEntries" false) (mem "Index" false))))
(DData Public "Map" ("k" "v") ((variant "Tip" (ConPos)) (variant "Bin" (ConPos (TyCon "Int") (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))) ())
(DTypeSig false "bin" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "bin" ((PVar "k") (PVar "v") (PVar "l") (PVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EBinOp "+" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1)))) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")))
(DTypeSig false "balance" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "balance" ((PVar "k") (PVar "v") (PVar "l") (PVar "r")) (EIf (EBinOp "<=" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "r")) (EBinOp "*" (ELit (LInt 3)) (EApp (EVar "size") (EVar "l")))) (EApp (EApp (EApp (EApp (EVar "rotateL") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "l")) (EBinOp "*" (ELit (LInt 3)) (EApp (EVar "size") (EVar "r")))) (EApp (EApp (EApp (EApp (EVar "rotateR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "rotateL" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "rotateL" ((PVar "k") (PVar "v") (PVar "l") (PAs "r" (PCon "Bin" PWild PWild PWild (PVar "rl") (PVar "rr")))) (EIf (EBinOp "<" (EApp (EVar "size") (EVar "rl")) (EBinOp "*" (ELit (LInt 2)) (EApp (EVar "size") (EVar "rr")))) (EApp (EApp (EApp (EApp (EVar "singleL") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EApp (EVar "doubleL") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r"))))
(DFunDef false "rotateL" ((PVar "k") (PVar "v") (PVar "l") (PCon "Tip")) (EApp (EVar "panic") (ELit (LString "Map.rotateL: empty right subtree"))))
(DTypeSig false "rotateR" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "rotateR" ((PVar "k") (PVar "v") (PAs "l" (PCon "Bin" PWild PWild PWild (PVar "ll") (PVar "lr"))) (PVar "r")) (EIf (EBinOp "<" (EApp (EVar "size") (EVar "lr")) (EBinOp "*" (ELit (LInt 2)) (EApp (EVar "size") (EVar "ll")))) (EApp (EApp (EApp (EApp (EVar "singleR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")) (EApp (EApp (EApp (EApp (EVar "doubleR") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r"))))
(DFunDef false "rotateR" ((PVar "k") (PVar "v") (PCon "Tip") (PVar "r")) (EApp (EVar "panic") (ELit (LString "Map.rotateR: empty left subtree"))))
(DTypeSig false "singleL" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "singleL" ((PVar "k1") (PVar "v1") (PVar "t1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "t2") (PVar "t3"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t1")) (EVar "t2"))) (EVar "t3")))
(DFunDef false "singleL" ((PVar "k1") (PVar "v1") (PVar "t1") (PCon "Tip")) (EApp (EVar "panic") (ELit (LString "Map.singleL: empty right subtree"))))
(DTypeSig false "singleR" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "singleR" ((PVar "k1") (PVar "v1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "t1") (PVar "t2")) (PVar "t3")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EVar "t1")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t2")) (EVar "t3"))))
(DFunDef false "singleR" ((PVar "k1") (PVar "v1") (PCon "Tip") (PVar "t3")) (EApp (EVar "panic") (ELit (LString "Map.singleR: empty left subtree"))))
(DTypeSig false "doubleL" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "doubleL" ((PVar "k1") (PVar "v1") (PVar "t1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PCon "Bin" PWild (PVar "k3") (PVar "v3") (PVar "t2") (PVar "t3")) (PVar "t4"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k3")) (EVar "v3")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t1")) (EVar "t2"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EVar "t3")) (EVar "t4"))))
(DFunDef false "doubleL" ((PVar "k1") (PVar "v1") (PVar "t1") PWild) (EApp (EVar "panic") (ELit (LString "Map.doubleL: malformed right subtree"))))
(DTypeSig false "doubleR" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "doubleR" ((PVar "k1") (PVar "v1") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "t1") (PCon "Bin" PWild (PVar "k3") (PVar "v3") (PVar "t2") (PVar "t3"))) (PVar "t4")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k3")) (EVar "v3")) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k2")) (EVar "v2")) (EVar "t1")) (EVar "t2"))) (EApp (EApp (EApp (EApp (EVar "bin") (EVar "k1")) (EVar "v1")) (EVar "t3")) (EVar "t4"))))
(DFunDef false "doubleR" ((PVar "k1") (PVar "v1") PWild (PVar "t4")) (EApp (EVar "panic") (ELit (LString "Map.doubleR: malformed left subtree"))))
(DTypeSig true "singleton" (TyFun (TyVar "k") (TyFun (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "singleton" ((PVar "k") (PVar "v")) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (ELit (LInt 1))) (EVar "k")) (EVar "v")) (EVar "Tip")) (EVar "Tip")))
(DTypeSig true "fromList" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "fromList" ((PVar "xs")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PTuple (PVar "k") (PVar "v"))) (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EVar "m")))) (EVar "Tip")) (EVar "xs")))
(DTypeSig true "size" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Int")))
(DFunDef false "size" ((PCon "Tip")) (ELit (LInt 0)))
(DFunDef false "size" ((PCon "Bin" (PVar "s") PWild PWild PWild PWild)) (EVar "s"))
(DTypeSig true "isEmpty#shadow" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))
(DFunDef false "isEmpty#shadow" ((PCon "Tip")) (EVar "True"))
(DFunDef false "isEmpty#shadow" (PWild) (EVar "False"))
(DTypeSig true "get" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "get" ((PVar "k") (PCon "Tip")) (EVar "None"))
(DFunDef false "get" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "l"))) (arm (PCon "Gt") () (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "r"))) (arm (PCon "Eq") () (EApp (EVar "Some") (EVar "v")))))
(DImpl true "Index" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyVar "k") (TyVar "v")) ((req "Ord" ((TyVar "k")))) ((im "index" ((PVar "m") (PVar "k")) (EMatch (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "m")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "indexError") (ELit (LString "key not found"))))))))
(DTypeSig true "has" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))))
(DFunDef false "has" ((PVar "k") (PCon "Tip")) (EVar "False"))
(DFunDef false "has" ((PVar "k") (PCon "Bin" PWild (PVar "k2") PWild (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EDictApp "has") (EVar "k")) (EVar "l"))) (arm (PCon "Gt") () (EApp (EApp (EDictApp "has") (EVar "k")) (EVar "r"))) (arm (PCon "Eq") () (EVar "True"))))
(DTypeSig true "findWithDefault" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "v") (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyVar "v"))))))
(DFunDef false "findWithDefault" ((PVar "d") (PVar "k") (PVar "m")) (EMatch (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "m")) (arm (PCon "None") () (EVar "d")) (arm (PCon "Some" (PVar "v")) () (EVar "v"))))
(DTypeSig true "set" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "set" ((PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "set" ((PVar "k") (PVar "v") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r")))))
(DTypeSig true "insertWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))))
(DFunDef false "insertWith" ((PVar "f") (PVar "k") (PVar "v") (PCon "Tip")) (EApp (EApp (EVar "singleton") (EVar "k")) (EVar "v")))
(DFunDef false "insertWith" ((PVar "f") (PVar "k") (PVar "v") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EApp (EDictApp "insertWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EApp (EDictApp "insertWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "v2"))) (EVar "l")) (EVar "r")))))
(DTypeSig true "adjust" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyVar "v")) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "adjust" ((PVar "f") (PVar "k") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "adjust" ((PVar "f") (PVar "k") (PCon "Bin" (PVar "s") (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EVar "v2")) (EApp (EApp (EApp (EDictApp "adjust") (EVar "f")) (EVar "k")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EApp (EDictApp "adjust") (EVar "f")) (EVar "k")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k2")) (EApp (EVar "f") (EVar "v2"))) (EVar "l")) (EVar "r")))))
(DTypeSig true "delete" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "delete" ((PVar "k") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "delete" ((PVar "k") (PCon "Bin" PWild (PVar "k2") (PVar "v2") (PVar "l") (PVar "r"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "k")) (EVar "k2")) (arm (PCon "Lt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EApp (EApp (EDictApp "delete") (EVar "k")) (EVar "l"))) (EVar "r"))) (arm (PCon "Gt") () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k2")) (EVar "v2")) (EVar "l")) (EApp (EApp (EDictApp "delete") (EVar "k")) (EVar "r")))) (arm (PCon "Eq") () (EApp (EApp (EVar "glue") (EVar "l")) (EVar "r")))))
(DTypeSig false "glue" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glue" ((PCon "Tip") (PVar "r")) (EVar "r"))
(DFunDef false "glue" ((PVar "l") (PCon "Tip")) (EVar "l"))
(DFunDef false "glue" ((PVar "l") (PVar "r")) (EIf (EBinOp ">" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (EApp (EApp (EVar "glueMax") (EVar "l")) (EVar "r")) (EIf (EVar "otherwise") (EApp (EApp (EVar "glueMin") (EVar "l")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "glueMax" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glueMax" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "maxView") (EVar "l")) (arm (PCon "None") () (EVar "r")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v") (PVar "l'"))) () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l'")) (EVar "r")))))
(DTypeSig false "glueMin" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))
(DFunDef false "glueMin" ((PVar "l") (PVar "r")) (EMatch (EApp (EVar "minView") (EVar "r")) (arm (PCon "None") () (EVar "l")) (arm (PCon "Some" (PTuple (PVar "k") (PVar "v") (PVar "r'"))) () (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r'")))))
(DTypeSig true "minView" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "minView" ((PCon "Tip")) (EVar "None"))
(DFunDef false "minView" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EMatch (EApp (EVar "minView") (EVar "l")) (arm (PCon "None") () (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v") (EVar "r")))) (arm (PCon "Some" (PTuple (PVar "km") (PVar "vm") (PVar "l'"))) () (EApp (EVar "Some") (ETuple (EVar "km") (EVar "vm") (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l'")) (EVar "r")))))))
(DTypeSig true "maxView" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "maxView" ((PCon "Tip")) (EVar "None"))
(DFunDef false "maxView" ((PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EMatch (EApp (EVar "maxView") (EVar "r")) (arm (PCon "None") () (EApp (EVar "Some") (ETuple (EVar "k") (EVar "v") (EVar "l")))) (arm (PCon "Some" (PTuple (PVar "km") (PVar "vm") (PVar "r'"))) () (EApp (EVar "Some") (ETuple (EVar "km") (EVar "vm") (EApp (EApp (EApp (EApp (EVar "balance") (EVar "k")) (EVar "v")) (EVar "l")) (EVar "r'")))))))
(DTypeSig true "getMin" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "getMin" ((PVar "m")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "k") (PVar "v") PWild)) (ETuple (EVar "k") (EVar "v")))) (EApp (EVar "minView") (EVar "m"))))
(DTypeSig true "getMax" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "getMax" ((PVar "m")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "k") (PVar "v") PWild)) (ETuple (EVar "k") (EVar "v")))) (EApp (EVar "maxView") (EVar "m"))))
(DTypeSig true "deleteMin" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))
(DFunDef false "deleteMin" ((PVar "m")) (EMatch (EApp (EVar "minView") (EVar "m")) (arm (PCon "None") () (EVar "Tip")) (arm (PCon "Some" (PTuple PWild PWild (PVar "m'"))) () (EVar "m'"))))
(DTypeSig true "deleteMax" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))
(DFunDef false "deleteMax" ((PVar "m")) (EMatch (EApp (EVar "maxView") (EVar "m")) (arm (PCon "None") () (EVar "Tip")) (arm (PCon "Some" (PTuple PWild PWild (PVar "m'"))) () (EVar "m'"))))
(DTypeSig true "foldrWithKey" (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b"))))) (TyFun (TyVar "b") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldrWithKey" ((PVar "f") (PVar "z") (PCon "Tip")) (EVar "z"))
(DFunDef false "foldrWithKey" ((PVar "f") (PVar "z") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "foldrWithKey") (EVar "f")) (EApp (EApp (EApp (EVar "f") (EVar "k")) (EVar "v")) (EApp (EApp (EApp (EVar "foldrWithKey") (EVar "f")) (EVar "z")) (EVar "r")))) (EVar "l")))
(DTypeSig true "foldlWithKey" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "k") (TyFun (TyVar "v") (TyEffect () (Some "e") (TyVar "b"))))) (TyFun (TyVar "b") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldlWithKey" ((PVar "f") (PVar "z") (PCon "Tip")) (EVar "z"))
(DFunDef false "foldlWithKey" ((PVar "f") (PVar "z") (PCon "Bin" PWild (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "foldlWithKey") (EVar "f")) (EApp (EApp (EApp (EVar "f") (EApp (EApp (EApp (EVar "foldlWithKey") (EVar "f")) (EVar "z")) (EVar "l"))) (EVar "k")) (EVar "v"))) (EVar "r")))
(DTypeSig true "toList#shadow" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "toList#shadow" ((PVar "m")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") (PVar "v") (PVar "acc")) (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EVar "acc")))) (EListLit)) (EVar "m")))
(DTypeSig true "keys" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "k"))))
(DFunDef false "keys" ((PVar "m")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") PWild (PVar "acc")) (EBinOp "::" (EVar "k") (EVar "acc")))) (EListLit)) (EVar "m")))
(DTypeSig true "elems" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "v"))))
(DFunDef false "elems" ((PVar "m")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") (PVar "v") (PVar "acc")) (EBinOp "::" (EVar "v") (EVar "acc")))) (EListLit)) (EVar "m")))
(DTypeSig true "mapWithKey" (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyEffect () (Some "e") (TyVar "w")))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w"))))))
(DFunDef false "mapWithKey" ((PVar "f") (PCon "Tip")) (EVar "Tip"))
(DFunDef false "mapWithKey" ((PVar "f") (PCon "Bin" (PVar "s") (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EApp (EApp (EVar "f") (EVar "k")) (EVar "v"))) (EApp (EApp (EVar "mapWithKey") (EVar "f")) (EVar "l"))) (EApp (EApp (EVar "mapWithKey") (EVar "f")) (EVar "r"))))
(DTypeSig true "filterWithKey" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyEffect () (Some "e") (TyCon "Bool")))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "filterWithKey" ((PVar "p") (PVar "m")) (EApp (EApp (EApp (EVar "foldrWithKey") (EApp (EDictApp "filterStep") (EVar "p"))) (EVar "Tip")) (EVar "m")))
(DTypeSig false "filterStep" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "k") (TyFun (TyVar "v") (TyEffect () (Some "e") (TyCon "Bool")))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))))
(DFunDef false "filterStep" ((PVar "p") (PVar "k") (PVar "v") (PVar "acc")) (EIf (EApp (EApp (EVar "p") (EVar "k")) (EVar "v")) (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EVar "acc")) (EVar "acc")))
(DTypeSig true "union" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "union" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") (PVar "v") (PVar "acc")) (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EVar "acc")))) (EVar "b")) (EVar "a")))
(DTypeSig true "unionWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "v") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "unionWith" ((PVar "f") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") (PVar "v") (PVar "acc")) (EApp (EApp (EApp (EApp (EDictApp "insertWith") (EVar "f")) (EVar "k")) (EVar "v")) (EVar "acc")))) (EVar "b")) (EVar "a")))
(DTypeSig true "difference" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))
(DFunDef false "difference" ((PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (ELam ((PVar "k") PWild (PVar "acc")) (EApp (EApp (EDictApp "delete") (EVar "k")) (EVar "acc")))) (EVar "a")) (EVar "b")))
(DTypeSig true "intersectionWith" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "w") (TyVar "x"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "x")))))))
(DFunDef false "intersectionWith" ((PVar "f") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "foldrWithKey") (EApp (EApp (EDictApp "intersectStep") (EVar "f")) (EVar "b"))) (EVar "Tip")) (EVar "a")))
(DTypeSig false "intersectStep" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyFun (TyVar "v") (TyFun (TyVar "w") (TyVar "x"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "w")) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "x")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "x")))))))))
(DFunDef false "intersectStep" ((PVar "f") (PVar "b") (PVar "k") (PVar "v") (PVar "acc")) (EMatch (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "b")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "w")) () (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EApp (EApp (EVar "f") (EVar "v")) (EVar "w"))) (EVar "acc")))))
(DImpl true "Mappable" ((TyApp (TyCon "Map") (TyVar "k"))) () ((im "map" ((PVar "f") (PCon "Tip")) (EVar "Tip")) (im "map" ((PVar "f") (PCon "Bin" (PVar "s") (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "Bin") (EVar "s")) (EVar "k")) (EApp (EVar "f") (EVar "v"))) (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "l"))) (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "r"))))))
(DImpl true "Eq" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Eq" ((TyVar "k"))) (req "Eq" ((TyVar "v")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "!=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EVar "False") (EApp (EApp (EMethodRef "eq") (EApp (EVar "toList#shadow") (EVar "a"))) (EApp (EVar "toList#shadow") (EVar "b")))))))
(DImpl true "Ord" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Ord" ((TyVar "k"))) (req "Ord" ((TyVar "v")))) ((im "compare" ((PVar "a") (PVar "b")) (EApp (EApp (EMethodRef "compare") (EApp (EVar "toList#shadow") (EVar "a"))) (EApp (EVar "toList#shadow") (EVar "b"))))))
(DImpl true "Debug" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Debug" ((TyVar "k"))) (req "Debug" ((TyVar "v")))) ((im "debug" ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EApp (EVar "toList#shadow") (EVar "m"))))) (ELit (LString ""))))))
(DTypeSig false "displayMapEntries" (TyConstrained ((cstr "Display" (TyVar "k")) (cstr "Display" (TyVar "v"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "String"))))
(DFunDef false "displayMapEntries" ((PList)) (ELit (LString "")))
(DFunDef false "displayMapEntries" ((PList (PTuple (PVar "k") (PVar "v")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString ""))))
(DFunDef false "displayMapEntries" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EDictApp "displayMapEntries") (EVar "rest")))) (ELit (LString ""))))
(DImpl true "Display" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Display" ((TyVar "k"))) (req "Display" ((TyVar "v")))) ((im "display" ((PVar "m")) (EMatch (EApp (EVar "toList#shadow") (EVar "m")) (arm (PList) () (ELit (LString "Map {}"))) (arm (PVar "es") () (EBinOp "++" (EBinOp "++" (ELit (LString "Map { ")) (EApp (EMethodRef "display") (EApp (EDictApp "displayMapEntries") (EVar "es")))) (ELit (LString " }"))))))))
(DImpl true "Semigroup" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Ord" ((TyVar "k")))) ((im "append" ((PVar "a") (PVar "b")) (EApp (EApp (EDictApp "union") (EVar "a")) (EVar "b")))))
(DImpl true "FromEntries" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyTuple (TyVar "k") (TyVar "v"))) ((req "Ord" ((TyVar "k")))) ((im "fromEntries" ((PVar "es")) (EApp (EDictApp "fromList") (EVar "es")))))
(DImpl true "Monoid" ((TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))) ((req "Ord" ((TyVar "k")))) ((im "empty" () (EVar "Tip"))))
(DTypeSig true "wellFormed" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool"))))
(DFunDef false "wellFormed" ((PCon "Tip")) (EVar "True"))
(DFunDef false "wellFormed" ((PCon "Bin" (PVar "s") (PVar "k") (PVar "v") (PVar "l") (PVar "r"))) (EBlock (DoLet false false (PVar "sizeOk") (EBinOp "==" (EBinOp "+" (EBinOp "+" (EApp (EVar "size") (EVar "l")) (EApp (EVar "size") (EVar "r"))) (ELit (LInt 1))) (EVar "s"))) (DoLet false false (PVar "orderOk") (EBinOp "&&" (EApp (EApp (EVar "allKeys") (ELam ((PVar "lk")) (EApp (EApp (EMethodRef "lt") (EVar "lk")) (EVar "k")))) (EVar "l")) (EApp (EApp (EVar "allKeys") (ELam ((PVar "gk")) (EApp (EApp (EMethodRef "gt") (EVar "gk")) (EVar "k")))) (EVar "r")))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "sizeOk") (EApp (EApp (EVar "balancedAt") (EVar "l")) (EVar "r"))) (EVar "orderOk")) (EApp (EDictApp "wellFormed") (EVar "l"))) (EApp (EDictApp "wellFormed") (EVar "r"))))))
(DTypeSig false "allKeys" (TyFun (TyFun (TyVar "k") (TyCon "Bool")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool"))))
(DFunDef false "allKeys" ((PVar "p") (PCon "Tip")) (EVar "True"))
(DFunDef false "allKeys" ((PVar "p") (PCon "Bin" PWild (PVar "k") PWild (PVar "l") (PVar "r"))) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "p") (EVar "k")) (EApp (EApp (EVar "allKeys") (EVar "p")) (EVar "l"))) (EApp (EApp (EVar "allKeys") (EVar "p")) (EVar "r"))))
(DTypeSig false "balancedAt" (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "Bool"))))
(DFunDef false "balancedAt" ((PVar "l") (PVar "r")) (EBlock (DoLet false false (PVar "sl") (EApp (EVar "size") (EVar "l"))) (DoLet false false (PVar "sr") (EApp (EVar "size") (EVar "r"))) (DoExpr (EIf (EBinOp "<=" (EBinOp "+" (EVar "sl") (EVar "sr")) (ELit (LInt 1))) (EVar "True") (EBinOp "&&" (EBinOp "<=" (EVar "sl") (EBinOp "*" (ELit (LInt 3)) (EVar "sr"))) (EBinOp "<=" (EVar "sr") (EBinOp "*" (ELit (LInt 3)) (EVar "sl"))))))))
(DTypeSig false "ascending" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "ascending" ((PList)) (EVar "True"))
(DFunDef false "ascending" ((PList (PVar "x"))) (EVar "True"))
(DFunDef false "ascending" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EBinOp "&&" (EApp (EApp (EMethodRef "lt") (EVar "x")) (EVar "y")) (EApp (EDictApp "ascending") (EBinOp "::" (EVar "y") (EVar "rest")))))
(DProp false "fromList builds a well-formed tree" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EDictApp "wellFormed") (EApp (EDictApp "fromList") (EVar "xs"))))
(DProp false "keys come out strictly ascending" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EDictApp "ascending") (EApp (EVar "keys") (EApp (EDictApp "fromList") (EVar "xs")))))
(DProp false "insert then lookup returns the inserted value" ((pp "k" (TyCon "Int")) (pp "v" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EApp (EMethodRef "eq") (EApp (EApp (EDictApp "get") (EVar "k")) (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EApp (EDictApp "fromList") (EVar "xs"))))) (EApp (EVar "Some") (EVar "v"))))
(DProp false "insert preserves well-formedness" ((pp "k" (TyCon "Int")) (pp "v" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EDictApp "wellFormed") (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EApp (EDictApp "fromList") (EVar "xs")))))
(DProp false "delete removes the key and preserves well-formedness" ((pp "k" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "m") (EApp (EApp (EDictApp "delete") (EVar "k")) (EApp (EDictApp "fromList") (EVar "xs")))) (DoExpr (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EDictApp "has") (EVar "k")) (EVar "m"))) (EApp (EDictApp "wellFormed") (EVar "m"))))))
(DProp false "union preserves well-formedness" ((pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))) (pp "ys" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EApp (EDictApp "wellFormed") (EApp (EApp (EDictApp "union") (EApp (EDictApp "fromList") (EVar "xs"))) (EApp (EDictApp "fromList") (EVar "ys")))))
(DProp false "union is left-biased on shared keys" ((pp "k" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))) (EBlock (DoLet false false (PVar "l") (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (ELit (LInt 1))) (EApp (EDictApp "fromList") (EVar "xs")))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (ELit (LInt 2))) (EApp (EDictApp "fromList") (EVar "xs")))) (DoExpr (EApp (EApp (EMethodRef "eq") (EApp (EApp (EDictApp "get") (EVar "k")) (EApp (EApp (EDictApp "union") (EVar "l")) (EVar "r")))) (EApp (EVar "Some") (ELit (LInt 1)))))))
