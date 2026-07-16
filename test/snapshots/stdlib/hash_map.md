# META
source_lines=263
stages=DESUGAR,MARK
# SOURCE
{- hash_map.mdk — a mutable hash table (Module 6).

   See STDLIB.md (Module 6) for the plan.

   `HashMap k v` is a **mutable** hash table — separate chaining (each bucket a
   `List (k, v)`) in an `Array` held by a `Ref` so it can be swapped on resize,
   plus a `Ref Int` count. This is the *performance* counterpart to the
   persistent ordered `Map` (map.mdk): O(1) average lookup/insert, but updates
   mutate in place (untracked — no effect in the signature) rather than
   returning a fresh map. Reach for `Map` when you want persistence/ordering;
   reach for `HashMap` when you want raw speed and a single owner.

   Keys hash via the `Hashable` typeclass method `hash`. It must agree with the
   key's `Eq`, which holds for every structural `Eq` impl (all the built-ins) —
   a *custom* `Eq` that isn't structural would break it, so don't key a
   HashMap on such a type. A custom key type gets a structural impl from
   `deriving (Hashable)` (#422); hand-write `impl Hashable T` only when the
   derived fold is not what you want. A hash may be NEGATIVE (the fold wraps) —
   `slotOf` masks the sign off before indexing, so that is safe (#416).
   Iteration order is unspecified (hash order).

   The mutating ops sequence mutation statements in block bodies. A conditional
   mutation whose body is a multi-statement block (`deleteAt`) uses an **else-less
   `if`** (Phases 118 & 122 — both the block branch and the missing `else`
   survive `medaka fmt`), dropping the noisy `| otherwise = ()`. The rest stay as
   **guards**: `maybeResize` (the fmt'd else-less form would be one over-long
   line, since its single-application body can't soft-break) and the recursion
   base-cases (`reinsertAll`, `collectBuckets`), where `| i >= n` reads best. -}

-- hash_map/hash_set share identical resize/rehash bodies over DISTINCT ADTs; consolidation needs a shared-core refactor (out of scope).
-- lint-disable-file rule-duplicate-body

import core.{Eq, Debug, Option, Mappable, Hashable}

{- `HashMap buckets count`: `buckets.value` is the bucket array (each slot a
   chain), `count.value` is the live entry count. Both are mutated in place. -}
public export data HashMap k v = HashMap (Ref (Array (List (k, v)))) (Ref Int)

initialCapacity : Int
initialCapacity = 8

{- Bucket index of a key at a given capacity (cap > 0). The `Hashable` contract
   requires only eq-agreement, NOT a non-negative hash, so a contract-compliant
   user impl may hand us any `Int` — and `%` on a negative dividend is negative,
   which would index the bucket array out of bounds (issue #416: an OOB
   `arrayGetUnsafe`). Clearing the sign bit maps every `Int`, `intMinBound`
   included, into `[0, intMaxBound]` before the `%`. -}
slotOf : Hashable k => k -> Int -> Int
slotOf key cap = bitAnd (hash key) intMaxBound % cap

-- ── Construction ────────────────────────────────────────────────────────

{- | A fresh, empty hash table. Takes `Unit` (not a nullary value) so each call
   allocates its own table rather than sharing one mutable cell. -}
export new : Unit -> HashMap k v
new _ = HashMap (Ref (arrayMake initialCapacity [])) (Ref 0)

-- ── Query (pure reads) ──────────────────────────────────────────────────

{- | Number of entries. O(1).

   > size (fromList [(1, 10), (2, 20), (1, 30)])
   2 -}
export size : HashMap k v -> Int
size (HashMap _ count) = count.value

{- | `True` when there are no entries.

   > isEmpty (new () : HashMap Int Int)
   True -}
export isEmpty : HashMap k v -> Bool
isEmpty m = size m == 0

bucketLookup : Eq k => k -> List (k, v) -> Option v
bucketLookup _ [] = None
bucketLookup key ((k, v)::rest)
  | key == k = Some v
  | otherwise = bucketLookup key rest

{- | The value at a key, or `None`.

   > get 2 (fromList [(1, 10), (2, 20)])
   Some 20
   > get 9 (fromList [(1, 10), (2, 20)])
   None -}
export get : (Eq k, Hashable k) => k -> HashMap k v -> Option v
get key (HashMap buckets _) =
  let arr = buckets.value
  bucketLookup key (arrayGetUnsafe (slotOf key (arrayLength arr)) arr)

{- | `True` when the key is present.

   > has 2 (fromList [(1, 10), (2, 20)])
   True -}
export has : (Eq k, Hashable k) => k -> HashMap k v -> Bool
has key m = isSome (get key m)

{- | Value at a key, or a fallback.

   > findWithDefault 0 9 (fromList [(1, 10)])
   0 -}
export findWithDefault : (Eq k, Hashable k) => v -> k -> HashMap k v -> v
findWithDefault d key m = fromOption d (get key m)

-- ── Bucket helpers (for insert/delete) ──────────────────────────────────

bucketHas : Eq k => k -> List (k, v) -> Bool
bucketHas _ [] = False
bucketHas key ((k, _)::rest)
  | key == k = True
  | otherwise = bucketHas key rest

bucketReplace : Eq k => k -> v -> List (k, v) -> List (k, v)
bucketReplace _ _ [] = []
bucketReplace key val ((k, v)::rest)
  | key == k = (key, val)::rest
  | otherwise = (k, v) :: bucketReplace key val rest

bucketRemove : Eq k => k -> List (k, v) -> List (k, v)
bucketRemove _ [] = []
bucketRemove key ((k, v)::rest)
  | key == k = rest
  | otherwise = (k, v) :: bucketRemove key rest

-- ── Insertion (mutating) ────────────────────────────────────────────────

{- | Insert (or overwrite) the value at a key, in place. Resizes (doubling)
   when the load factor passes 0.75. -}
export set : (Eq k, Hashable k) => k -> v -> HashMap k v -> Unit
set key val (HashMap buckets count) =
  let arr = buckets.value
  let idx = slotOf key (arrayLength arr)
  insertAt key val arr idx buckets count

insertAt : (Eq k, Hashable k) => k -> v -> Array (List (k, v)) -> Int -> Ref (Array (List (k, v))) -> Ref Int -> Unit
insertAt key val arr idx buckets count
  | bucketHas key (arrayGetUnsafe idx arr) =
    arraySetUnsafe idx (bucketReplace key val (arrayGetUnsafe idx arr)) arr
  | otherwise =
    arraySetUnsafe idx ((key, val) :: arrayGetUnsafe idx arr) arr
    setRef count (count.value + 1)
    maybeResize buckets count

maybeResize : (Eq k, Hashable k) => Ref (Array (List (k, v))) -> Ref Int -> Unit
maybeResize buckets count
  | count.value * 4 > arrayLength buckets.value * 3 = resize buckets count
  | otherwise = ()

resize : (Eq k, Hashable k) => Ref (Array (List (k, v))) -> Ref Int -> Unit
resize buckets count =
  let oldArr = buckets.value
  let newArr = arrayMake (arrayLength oldArr * 2) []
  setRef buckets newArr
  setRef count 0
  reinsertAll oldArr 0 (arrayLength oldArr) buckets count

reinsertAll : (Eq k, Hashable k) => Array (List (k, v)) -> Int -> Int -> Ref (Array (List (k, v))) -> Ref Int -> Unit
reinsertAll oldArr i n buckets count
  | i >= n = ()
  | otherwise =
    reinsertBucket (arrayGetUnsafe i oldArr) buckets count
    reinsertAll oldArr (i + 1) n buckets count

reinsertBucket : (Eq k, Hashable k) => List (k, v) -> Ref (Array (List (k, v))) -> Ref Int -> Unit
reinsertBucket [] _ _ = ()
reinsertBucket ((k, v)::rest) buckets count =
  putRaw k v buckets count
  reinsertBucket rest buckets count

-- Insert into a freshly-resized table (key known absent, so just prepend).
putRaw : Hashable k => k -> v -> Ref (Array (List (k, v))) -> Ref Int -> Unit
putRaw key val buckets count =
  let arr = buckets.value
  let idx = slotOf key (arrayLength arr)
  arraySetUnsafe idx ((key, val) :: arrayGetUnsafe idx arr) arr
  setRef count (count.value + 1)

{- | Build a table from an association list (later pairs win on duplicates).

   > size (fromList [(1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (6, 6), (7, 7), (8, 8)])
   8 -}
export fromList : (Eq k, Hashable k) => List (k, v) -> HashMap k v
fromList pairs =
  let m = new ()
  insertAll pairs m
  m

insertAll : (Eq k, Hashable k) => List (k, v) -> HashMap k v -> Unit
insertAll [] _ = ()
insertAll ((k, v)::rest) m =
  set k v m
  insertAll rest m

-- ── Deletion (mutating) ─────────────────────────────────────────────────

{- | Remove a key, in place. A no-op when absent. -}
export delete : (Eq k, Hashable k) => k -> HashMap k v -> Unit
delete key (HashMap buckets count) =
  let arr = buckets.value
  let idx = slotOf key (arrayLength arr)
  deleteAt key arr idx count

deleteAt : (Eq k, Hashable k) => k -> Array (List (k, v)) -> Int -> Ref Int -> Unit
deleteAt key arr idx count =
  if bucketHas key (arrayGetUnsafe idx arr) then
    arraySetUnsafe idx (bucketRemove key (arrayGetUnsafe idx arr)) arr
    setRef count (count.value - 1)

-- ── Iteration (pure; order unspecified) ─────────────────────────────────

collectBuckets : Array (List (k, v)) -> Int -> Int -> List (k, v) -> List (k, v)
collectBuckets arr i n acc
  | i >= n = acc
  | otherwise = collectBuckets arr (i + 1) n (arrayGetUnsafe i arr ++ acc)

{- | All key/value pairs, in unspecified (hash) order.

   Named `entries`, not `toList`: `toList` is a `Foldable` method (returning
   *elements*), and `HashMap` isn't `Foldable` — within this file the local
   `toList` would be shadowed by the method and mistyped (`List v` vs the
   pairs `List (k, v)`). `toList` below is a thin exported alias, never used
   internally. -}
export entries : HashMap k v -> List (k, v)
entries (HashMap buckets _) =
  collectBuckets buckets.value 0 (arrayLength buckets.value) []

{- | Conventional alias for `entries` (all key/value pairs). -}
export toList : HashMap k v -> List (k, v)
toList m = entries m

{- | All keys, in unspecified order.

   > keys (fromList [(5, 50)])
   [5] -}
export keys : HashMap k v -> List k
keys m = map fst (entries m)

{- | All values, in unspecified order.

   > values (fromList [(5, 50)])
   [50] -}
export values : HashMap k v -> List v
values m = map snd (entries m)

-- ── Instances ───────────────────────────────────────────────────────────

allEntriesIn : (Eq k, Eq v, Hashable k) => List (k, v) -> HashMap k v -> Bool
allEntriesIn [] _ = True
allEntriesIn ((k, v)::rest) m
  | get k m == Some v = allEntriesIn rest m
  | otherwise = False

{- | Order-independent equality: same entries, regardless of internal layout.

   > eq (fromList [(1, 10), (2, 20)]) (fromList [(2, 20), (1, 10)])
   True -}
export impl Eq (HashMap k v) requires Eq k, Eq v, Hashable k where
  eq a b = if size a != size b then False else allEntriesIn (entries a) b

{- | Rendered as `fromList [(k, v), …]` in hash order (so the exact text is
   layout-dependent — don't rely on it for equality; use `eq`). -}
export impl Debug (HashMap k v) requires Debug k, Debug v where
  debug m = "fromList \{debug (entries m)}"
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Debug" false) (mem "Option" false) (mem "Mappable" false) (mem "Hashable" false))))
(DData Public "HashMap" ("k" "v") ((variant "HashMap" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DTypeSig false "initialCapacity" (TyCon "Int"))
(DFunDef false "initialCapacity" () (ELit (LInt 8)))
(DTypeSig false "slotOf" (TyConstrained ((cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "slotOf" ((PVar "key") (PVar "cap")) (EBinOp "%" (EApp (EApp (EVar "bitAnd") (EApp (EVar "hash") (EVar "key"))) (EVar "intMaxBound")) (EVar "cap")))
(DTypeSig true "new" (TyFun (TyCon "Unit") (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v"))))
(DFunDef false "new" (PWild) (EApp (EApp (EVar "HashMap") (EApp (EVar "Ref") (EApp (EApp (EVar "arrayMake") (EVar "initialCapacity")) (EListLit)))) (EApp (EVar "Ref") (ELit (LInt 0)))))
(DTypeSig true "size" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Int")))
(DFunDef false "size" ((PCon "HashMap" PWild (PVar "count"))) (EFieldAccess (EVar "count") "value"))
(DTypeSig true "isEmpty" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))
(DFunDef false "isEmpty" ((PVar "m")) (EBinOp "==" (EApp (EVar "size") (EVar "m")) (ELit (LInt 0))))
(DTypeSig false "bucketLookup" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "bucketLookup" (PWild (PList)) (EVar "None"))
(DFunDef false "bucketLookup" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "bucketLookup") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "get" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "get" ((PVar "key") (PCon "HashMap" (PVar "buckets") PWild)) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoExpr (EApp (EApp (EVar "bucketLookup") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EApp (EApp (EVar "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "arr"))))))
(DTypeSig true "has" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))))
(DFunDef false "has" ((PVar "key") (PVar "m")) (EApp (EVar "isSome") (EApp (EApp (EVar "get") (EVar "key")) (EVar "m"))))
(DTypeSig true "findWithDefault" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "v") (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyVar "v"))))))
(DFunDef false "findWithDefault" ((PVar "d") (PVar "key") (PVar "m")) (EApp (EApp (EVar "fromOption") (EVar "d")) (EApp (EApp (EVar "get") (EVar "key")) (EVar "m"))))
(DTypeSig false "bucketHas" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "Bool")))))
(DFunDef false "bucketHas" (PWild (PList)) (EVar "False"))
(DFunDef false "bucketHas" ((PVar "key") (PCons (PTuple (PVar "k") PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "bucketHas") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bucketReplace" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))))))
(DFunDef false "bucketReplace" (PWild PWild (PList)) (EListLit))
(DFunDef false "bucketReplace" ((PVar "key") (PVar "val") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EBinOp "::" (ETuple (EVar "key") (EVar "val")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EApp (EVar "bucketReplace") (EVar "key")) (EVar "val")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bucketRemove" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))))
(DFunDef false "bucketRemove" (PWild (PList)) (EListLit))
(DFunDef false "bucketRemove" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EVar "rest") (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "bucketRemove") (EVar "key")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "set" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Unit"))))))
(DFunDef false "set" ((PVar "key") (PVar "val") (PCon "HashMap" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "idx") (EApp (EApp (EVar "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "insertAt") (EVar "key")) (EVar "val")) (EVar "arr")) (EVar "idx")) (EVar "buckets")) (EVar "count")))))
(DTypeSig false "insertAt" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))))
(DFunDef false "insertAt" ((PVar "key") (PVar "val") (PVar "arr") (PVar "idx") (PVar "buckets") (PVar "count")) (EIf (EApp (EApp (EVar "bucketHas") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EApp (EApp (EApp (EVar "bucketReplace") (EVar "key")) (EVar "val")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (ETuple (EVar "key") (EVar "val")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "+" (EFieldAccess (EVar "count") "value") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "maybeResize") (EVar "buckets")) (EVar "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "maybeResize" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "maybeResize" ((PVar "buckets") (PVar "count")) (EIf (EBinOp ">" (EBinOp "*" (EFieldAccess (EVar "count") "value") (ELit (LInt 4))) (EBinOp "*" (EApp (EVar "arrayLength") (EFieldAccess (EVar "buckets") "value")) (ELit (LInt 3)))) (EApp (EApp (EVar "resize") (EVar "buckets")) (EVar "count")) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "resize" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "resize" ((PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "oldArr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "newArr") (EApp (EApp (EVar "arrayMake") (EBinOp "*" (EApp (EVar "arrayLength") (EVar "oldArr")) (ELit (LInt 2)))) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "buckets")) (EVar "newArr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reinsertAll") (EVar "oldArr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "oldArr"))) (EVar "buckets")) (EVar "count")))))
(DTypeSig false "reinsertAll" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))))
(DFunDef false "reinsertAll" ((PVar "oldArr") (PVar "i") (PVar "n") (PVar "buckets") (PVar "count")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "reinsertBucket") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "oldArr"))) (EVar "buckets")) (EVar "count"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reinsertAll") (EVar "oldArr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "buckets")) (EVar "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reinsertBucket" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))
(DFunDef false "reinsertBucket" ((PList) PWild PWild) (ELit LUnit))
(DFunDef false "reinsertBucket" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "buckets") (PVar "count")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "putRaw") (EVar "k")) (EVar "v")) (EVar "buckets")) (EVar "count"))) (DoExpr (EApp (EApp (EApp (EVar "reinsertBucket") (EVar "rest")) (EVar "buckets")) (EVar "count")))))
(DTypeSig false "putRaw" (TyConstrained ((cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "putRaw" ((PVar "key") (PVar "val") (PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "idx") (EApp (EApp (EVar "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (ETuple (EVar "key") (EVar "val")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "+" (EFieldAccess (EVar "count") "value") (ELit (LInt 1)))))))
(DTypeSig true "fromList" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")))))
(DFunDef false "fromList" ((PVar "pairs")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "insertAll") (EVar "pairs")) (EVar "m"))) (DoExpr (EVar "m"))))
(DTypeSig false "insertAll" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Unit")))))
(DFunDef false "insertAll" ((PList) PWild) (ELit LUnit))
(DFunDef false "insertAll" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "m")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "set") (EVar "k")) (EVar "v")) (EVar "m"))) (DoExpr (EApp (EApp (EVar "insertAll") (EVar "rest")) (EVar "m")))))
(DTypeSig true "delete" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Unit")))))
(DFunDef false "delete" ((PVar "key") (PCon "HashMap" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "idx") (EApp (EApp (EVar "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "deleteAt") (EVar "key")) (EVar "arr")) (EVar "idx")) (EVar "count")))))
(DTypeSig false "deleteAt" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "deleteAt" ((PVar "key") (PVar "arr") (PVar "idx") (PVar "count")) (EIf (EApp (EApp (EVar "bucketHas") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EApp (EApp (EVar "bucketRemove") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "-" (EFieldAccess (EVar "count") "value") (ELit (LInt 1)))))) (ELit LUnit)))
(DTypeSig false "collectBuckets" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))))))
(DFunDef false "collectBuckets" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "collectBuckets") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "++" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "entries" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "entries" ((PCon "HashMap" (PVar "buckets") PWild)) (EApp (EApp (EApp (EApp (EVar "collectBuckets") (EFieldAccess (EVar "buckets") "value")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EFieldAccess (EVar "buckets") "value"))) (EListLit)))
(DTypeSig true "toList" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "toList" ((PVar "m")) (EApp (EVar "entries") (EVar "m")))
(DTypeSig true "keys" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "k"))))
(DFunDef false "keys" ((PVar "m")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "entries") (EVar "m"))))
(DTypeSig true "values" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "v"))))
(DFunDef false "values" ((PVar "m")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EVar "entries") (EVar "m"))))
(DTypeSig false "allEntriesIn" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Eq" (TyVar "v")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))))
(DFunDef false "allEntriesIn" ((PList) PWild) (EVar "True"))
(DFunDef false "allEntriesIn" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "m")) (EIf (EBinOp "==" (EApp (EApp (EVar "get") (EVar "k")) (EVar "m")) (EApp (EVar "Some") (EVar "v"))) (EApp (EApp (EVar "allEntriesIn") (EVar "rest")) (EVar "m")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Eq" ((TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v"))) ((req "Eq" ((TyVar "k"))) (req "Eq" ((TyVar "v"))) (req "Hashable" ((TyVar "k")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "!=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EVar "False") (EApp (EApp (EVar "allEntriesIn") (EApp (EVar "entries") (EVar "a"))) (EVar "b"))))))
(DImpl true "Debug" ((TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v"))) ((req "Debug" ((TyVar "k"))) (req "Debug" ((TyVar "v")))) ((im "debug" ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EVar "display") (EApp (EVar "debug") (EApp (EVar "entries") (EVar "m"))))) (ELit (LString ""))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Debug" false) (mem "Option" false) (mem "Mappable" false) (mem "Hashable" false))))
(DData Public "HashMap" ("k" "v") ((variant "HashMap" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DTypeSig false "initialCapacity" (TyCon "Int"))
(DFunDef false "initialCapacity" () (ELit (LInt 8)))
(DTypeSig false "slotOf" (TyConstrained ((cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "slotOf" ((PVar "key") (PVar "cap")) (EBinOp "%" (EApp (EApp (EVar "bitAnd") (EApp (EMethodRef "hash") (EVar "key"))) (EVar "intMaxBound")) (EVar "cap")))
(DTypeSig true "new" (TyFun (TyCon "Unit") (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v"))))
(DFunDef false "new" (PWild) (EApp (EApp (EVar "HashMap") (EApp (EVar "Ref") (EApp (EApp (EVar "arrayMake") (EVar "initialCapacity")) (EListLit)))) (EApp (EVar "Ref") (ELit (LInt 0)))))
(DTypeSig true "size" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Int")))
(DFunDef false "size" ((PCon "HashMap" PWild (PVar "count"))) (EFieldAccess (EDictApp "count") "value"))
(DTypeSig true "isEmpty#shadow" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))
(DFunDef false "isEmpty#shadow" ((PVar "m")) (EBinOp "==" (EApp (EVar "size") (EVar "m")) (ELit (LInt 0))))
(DTypeSig false "bucketLookup" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "bucketLookup" (PWild (PList)) (EVar "None"))
(DFunDef false "bucketLookup" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EDictApp "bucketLookup") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "get" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "get" ((PVar "key") (PCon "HashMap" (PVar "buckets") PWild)) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoExpr (EApp (EApp (EDictApp "bucketLookup") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EApp (EApp (EDictApp "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "arr"))))))
(DTypeSig true "has" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))))
(DFunDef false "has" ((PVar "key") (PVar "m")) (EApp (EVar "isSome") (EApp (EApp (EDictApp "get") (EVar "key")) (EVar "m"))))
(DTypeSig true "findWithDefault" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "v") (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyVar "v"))))))
(DFunDef false "findWithDefault" ((PVar "d") (PVar "key") (PVar "m")) (EApp (EApp (EVar "fromOption") (EVar "d")) (EApp (EApp (EDictApp "get") (EVar "key")) (EVar "m"))))
(DTypeSig false "bucketHas" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyCon "Bool")))))
(DFunDef false "bucketHas" (PWild (PList)) (EVar "False"))
(DFunDef false "bucketHas" ((PVar "key") (PCons (PTuple (PVar "k") PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EDictApp "bucketHas") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bucketReplace" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))))))
(DFunDef false "bucketReplace" (PWild PWild (PList)) (EListLit))
(DFunDef false "bucketReplace" ((PVar "key") (PVar "val") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EBinOp "::" (ETuple (EVar "key") (EVar "val")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EApp (EDictApp "bucketReplace") (EVar "key")) (EVar "val")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bucketRemove" (TyConstrained ((cstr "Eq" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))))
(DFunDef false "bucketRemove" (PWild (PList)) (EListLit))
(DFunDef false "bucketRemove" ((PVar "key") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "key") (EVar "k")) (EVar "rest") (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EDictApp "bucketRemove") (EVar "key")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "set" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Unit"))))))
(DFunDef false "set" ((PVar "key") (PVar "val") (PCon "HashMap" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "idx") (EApp (EApp (EDictApp "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EDictApp "insertAt") (EVar "key")) (EVar "val")) (EVar "arr")) (EVar "idx")) (EVar "buckets")) (EDictApp "count")))))
(DTypeSig false "insertAt" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))))
(DFunDef false "insertAt" ((PVar "key") (PVar "val") (PVar "arr") (PVar "idx") (PVar "buckets") (PVar "count")) (EIf (EApp (EApp (EDictApp "bucketHas") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EApp (EApp (EApp (EDictApp "bucketReplace") (EVar "key")) (EVar "val")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (ETuple (EVar "key") (EVar "val")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (EBinOp "+" (EFieldAccess (EDictApp "count") "value") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EDictApp "maybeResize") (EVar "buckets")) (EDictApp "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "maybeResize" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "maybeResize" ((PVar "buckets") (PVar "count")) (EIf (EBinOp ">" (EBinOp "*" (EFieldAccess (EDictApp "count") "value") (ELit (LInt 4))) (EBinOp "*" (EApp (EVar "arrayLength") (EFieldAccess (EVar "buckets") "value")) (ELit (LInt 3)))) (EApp (EApp (EDictApp "resize") (EVar "buckets")) (EDictApp "count")) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "resize" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "resize" ((PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "oldArr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "newArr") (EApp (EApp (EVar "arrayMake") (EBinOp "*" (EApp (EVar "arrayLength") (EVar "oldArr")) (ELit (LInt 2)))) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "buckets")) (EVar "newArr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EDictApp "reinsertAll") (EVar "oldArr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "oldArr"))) (EVar "buckets")) (EDictApp "count")))))
(DTypeSig false "reinsertAll" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))))
(DFunDef false "reinsertAll" ((PVar "oldArr") (PVar "i") (PVar "n") (PVar "buckets") (PVar "count")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EDictApp "reinsertBucket") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "oldArr"))) (EVar "buckets")) (EDictApp "count"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EDictApp "reinsertAll") (EVar "oldArr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "buckets")) (EDictApp "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reinsertBucket" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))
(DFunDef false "reinsertBucket" ((PList) PWild PWild) (ELit LUnit))
(DFunDef false "reinsertBucket" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "buckets") (PVar "count")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EDictApp "putRaw") (EVar "k")) (EVar "v")) (EVar "buckets")) (EDictApp "count"))) (DoExpr (EApp (EApp (EApp (EDictApp "reinsertBucket") (EVar "rest")) (EVar "buckets")) (EDictApp "count")))))
(DTypeSig false "putRaw" (TyConstrained ((cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "putRaw" ((PVar "key") (PVar "val") (PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "idx") (EApp (EApp (EDictApp "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (ETuple (EVar "key") (EVar "val")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (EBinOp "+" (EFieldAccess (EDictApp "count") "value") (ELit (LInt 1)))))))
(DTypeSig true "fromList" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")))))
(DFunDef false "fromList" ((PVar "pairs")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EDictApp "insertAll") (EVar "pairs")) (EVar "m"))) (DoExpr (EVar "m"))))
(DTypeSig false "insertAll" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Unit")))))
(DFunDef false "insertAll" ((PList) PWild) (ELit LUnit))
(DFunDef false "insertAll" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "m")) (EBlock (DoExpr (EApp (EApp (EApp (EDictApp "set") (EVar "k")) (EVar "v")) (EVar "m"))) (DoExpr (EApp (EApp (EDictApp "insertAll") (EVar "rest")) (EVar "m")))))
(DTypeSig true "delete" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Unit")))))
(DFunDef false "delete" ((PVar "key") (PCon "HashMap" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "idx") (EApp (EApp (EDictApp "slotOf") (EVar "key")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EDictApp "deleteAt") (EVar "key")) (EVar "arr")) (EVar "idx")) (EDictApp "count")))))
(DTypeSig false "deleteAt" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyVar "k") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "deleteAt" ((PVar "key") (PVar "arr") (PVar "idx") (PVar "count")) (EIf (EApp (EApp (EDictApp "bucketHas") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EApp (EApp (EDictApp "bucketRemove") (EVar "key")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (EBinOp "-" (EFieldAccess (EDictApp "count") "value") (ELit (LInt 1)))))) (ELit LUnit)))
(DTypeSig false "collectBuckets" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))))))))
(DFunDef false "collectBuckets" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "collectBuckets") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "++" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "entries" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "entries" ((PCon "HashMap" (PVar "buckets") PWild)) (EApp (EApp (EApp (EApp (EVar "collectBuckets") (EFieldAccess (EVar "buckets") "value")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EFieldAccess (EVar "buckets") "value"))) (EListLit)))
(DTypeSig true "toList#shadow" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v")))))
(DFunDef false "toList#shadow" ((PVar "m")) (EApp (EVar "entries") (EVar "m")))
(DTypeSig true "keys" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "k"))))
(DFunDef false "keys" ((PVar "m")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "entries") (EVar "m"))))
(DTypeSig true "values" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyApp (TyCon "List") (TyVar "v"))))
(DFunDef false "values" ((PVar "m")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EVar "entries") (EVar "m"))))
(DTypeSig false "allEntriesIn" (TyConstrained ((cstr "Eq" (TyVar "k")) (cstr "Eq" (TyVar "v")) (cstr "Hashable" (TyVar "k"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v")) (TyCon "Bool")))))
(DFunDef false "allEntriesIn" ((PList) PWild) (EVar "True"))
(DFunDef false "allEntriesIn" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "m")) (EIf (EBinOp "==" (EApp (EApp (EDictApp "get") (EVar "k")) (EVar "m")) (EApp (EVar "Some") (EVar "v"))) (EApp (EApp (EDictApp "allEntriesIn") (EVar "rest")) (EVar "m")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Eq" ((TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v"))) ((req "Eq" ((TyVar "k"))) (req "Eq" ((TyVar "v"))) (req "Hashable" ((TyVar "k")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "!=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EVar "False") (EApp (EApp (EDictApp "allEntriesIn") (EApp (EVar "entries") (EVar "a"))) (EVar "b"))))))
(DImpl true "Debug" ((TyApp (TyApp (TyCon "HashMap") (TyVar "k")) (TyVar "v"))) ((req "Debug" ((TyVar "k"))) (req "Debug" ((TyVar "v")))) ((im "debug" ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EApp (EVar "entries") (EVar "m"))))) (ELit (LString ""))))))
