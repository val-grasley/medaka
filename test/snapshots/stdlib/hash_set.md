# META
source_lines=203
stages=DESUGAR,MARK
# SOURCE
{- hash_set.mdk — a mutable hash set (Module 6).

   See STDLIB.md (Module 6) for the plan.

   `HashSet a` is a **mutable** hash set — separate chaining (each bucket a
   `List a`) in a `Ref`-held array plus a `Ref Int` count, mirroring
   `hash_map.mdk`. The *performance* counterpart to the persistent ordered `Set`
   (set.mdk): O(1) average membership/insert, updates mutate in place.

   Standalone rather than a wrapper over `HashMap a Unit` — same reasoning as
   set.mdk over `Map a Unit` (self-contained, no qualified-import gymnastics, no
   `Unit` payload). Elements hash via the `Hashable` typeclass method `hash`
   (structural by default via `deriving (Hashable)`), which
   must agree with the element's `Eq`. Iteration order is unspecified.

   `Foldable HashSet` makes `toList`/`elem`/`length`/`any`/… work (a set's
   elements *are* its `toList`, unlike a map's pairs). -}

-- hash_set/hash_map share identical resize/rehash bodies over DISTINCT ADTs; consolidation needs a shared-core refactor (out of scope).
-- lint-disable-file rule-duplicate-body

import core.{Eq, Debug, Foldable, Hashable}

{- `HashSet buckets count`: chains in `buckets.value`, live count in
   `count.value`; both mutated in place. -}
public export data HashSet a = HashSet (Ref (Array (List a))) (Ref Int)

initialCapacity : Int
initialCapacity = 8

slotOf : Hashable a => a -> Int -> Int
slotOf x cap = hash x % cap

-- ── Construction ────────────────────────────────────────────────────────

{- | A fresh, empty hash set. Takes `Unit` so each call allocates its own. -}
export new : Unit -> HashSet a
new _ = HashSet (Ref (arrayMake initialCapacity [])) (Ref 0)

-- ── Query (pure reads) ──────────────────────────────────────────────────

{- | Number of elements. O(1).

   > size (fromList [1, 2, 3, 2, 1])
   3 -}
export size : HashSet a -> Int
size (HashSet _ count) = count.value

bucketHas : Eq a => a -> List a -> Bool
bucketHas _ [] = False
bucketHas x (y::rest)
  | x == y = True
  | otherwise = bucketHas x rest

{- | `True` when the element is present.

   > has 2 (fromList [1, 2, 3])
   True
   > has 9 (fromList [1, 2, 3])
   False -}
export has : (Eq a, Hashable a) => a -> HashSet a -> Bool
has x (HashSet buckets _) =
  let arr = buckets.value
  bucketHas x (arrayGetUnsafe (slotOf x (arrayLength arr)) arr)

-- ── Insertion / deletion (mutating) ─────────────────────────────────────

bucketRemove : Eq a => a -> List a -> List a
bucketRemove _ [] = []
bucketRemove x (y::rest)
  | x == y = rest
  | otherwise = y :: bucketRemove x rest

{- | Add an element, in place. A no-op when already present. Resizes (doubling)
   past load factor 0.75. -}
export insert : (Eq a, Hashable a) => a -> HashSet a -> Unit
insert x (HashSet buckets count) =
  let arr = buckets.value
  let idx = slotOf x (arrayLength arr)
  insertAt x arr idx buckets count

insertAt : (Eq a, Hashable a) => a -> Array (List a) -> Int -> Ref (Array (List a)) -> Ref Int -> Unit
insertAt x arr idx buckets count
  | bucketHas x (arrayGetUnsafe idx arr) = ()
  | otherwise =
    arraySetUnsafe idx (x :: arrayGetUnsafe idx arr) arr
    setRef count (count.value + 1)
    maybeResize buckets count

maybeResize : Hashable a => Ref (Array (List a)) -> Ref Int -> Unit
maybeResize buckets count
  | count.value * 4 > arrayLength buckets.value * 3 = resize buckets count
  | otherwise = ()

resize : Hashable a => Ref (Array (List a)) -> Ref Int -> Unit
resize buckets count =
  let oldArr = buckets.value
  let newArr = arrayMake (arrayLength oldArr * 2) []
  setRef buckets newArr
  setRef count 0
  reinsertAll oldArr 0 (arrayLength oldArr) buckets count

reinsertAll : Hashable a => Array (List a) -> Int -> Int -> Ref (Array (List a)) -> Ref Int -> Unit
reinsertAll oldArr i n buckets count
  | i >= n = ()
  | otherwise =
    reinsertBucket (arrayGetUnsafe i oldArr) buckets count
    reinsertAll oldArr (i + 1) n buckets count

reinsertBucket : Hashable a => List a -> Ref (Array (List a)) -> Ref Int -> Unit
reinsertBucket [] _ _ = ()
reinsertBucket (x::rest) buckets count =
  putRaw x buckets count
  reinsertBucket rest buckets count

putRaw : Hashable a => a -> Ref (Array (List a)) -> Ref Int -> Unit
putRaw x buckets count =
  let arr = buckets.value
  let idx = slotOf x (arrayLength arr)
  arraySetUnsafe idx (x :: arrayGetUnsafe idx arr) arr
  setRef count (count.value + 1)

{- | Build a set from a list, dropping duplicates.

   > size (fromList [1, 2, 3, 4, 5, 6, 7, 8, 8, 1])
   8 -}
export fromList : (Eq a, Hashable a) => List a -> HashSet a
fromList xs =
  let s = new ()
  insertAll xs s
  s

insertAll : (Eq a, Hashable a) => List a -> HashSet a -> Unit
insertAll [] _ = ()
insertAll (x::rest) s =
  insert x s
  insertAll rest s

{- | Remove an element, in place. A no-op when absent. -}
export delete : (Eq a, Hashable a) => a -> HashSet a -> Unit
delete x (HashSet buckets count) =
  let arr = buckets.value
  let idx = slotOf x (arrayLength arr)
  deleteAt x arr idx count

deleteAt : (Eq a, Hashable a) => a -> Array (List a) -> Int -> Ref Int -> Unit
deleteAt x arr idx count =
  if bucketHas x (arrayGetUnsafe idx arr) then
    arraySetUnsafe idx (bucketRemove x (arrayGetUnsafe idx arr)) arr
    setRef count (count.value - 1)

-- ── Iteration / folds ───────────────────────────────────────────────────

collectElems : Array (List a) -> Int -> Int -> List a -> List a
collectElems arr i n acc
  | i >= n = acc
  | otherwise = collectElems arr (i + 1) n (arrayGetUnsafe i arr ++ acc)

elemList : HashSet a -> List a
elemList (HashSet buckets _) =
  collectElems buckets.value 0 (arrayLength buckets.value) []

foldrElems : (a -> b -> <e> b) -> b -> List a -> <e> b
foldrElems _ z [] = z
foldrElems f z (x::rest) = f x (foldrElems f z rest)

foldlElems : (b -> a -> <e> b) -> b -> List a -> <e> b
foldlElems _ z [] = z
foldlElems f z (x::rest) = foldlElems f (f z x) rest

-- ── Instances ───────────────────────────────────────────────────────────

{- | Folds over elements (unspecified order), so `toList`/`length`/`elem`/`any`/
   `sum`/… all work on a HashSet.

   > toList (fromList [1, 1, 2]) != []
   True
   > length (fromList [3, 1, 2, 1])
   3 -}
export impl Foldable HashSet where
  fold f z s = foldlElems f z (elemList s)
  foldRight f z s = foldrElems f z (elemList s)
  toList s = elemList s
  isEmpty s = size s == 0
  length s = size s

allIn : (Eq a, Hashable a) => List a -> HashSet a -> Bool
allIn [] _ = True
allIn (x::rest) s
  | has x s = allIn rest s
  | otherwise = False

{- | Order-independent equality: same elements regardless of layout.

   > eq (fromList [1, 2, 3]) (fromList [3, 2, 1, 2])
   True -}
export impl Eq (HashSet a) requires Eq a, Hashable a where
  eq a b = if size a != size b then False else allIn (elemList a) b

{- | Rendered `fromList [a, …]` in hash order (layout-dependent; use `eq` for
   equality). -}
export impl Debug (HashSet a) requires Debug a where
  debug s = "fromList \{debug (elemList s)}"
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Debug" false) (mem "Foldable" false) (mem "Hashable" false))))
(DData Public "HashSet" ("a") ((variant "HashSet" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DTypeSig false "initialCapacity" (TyCon "Int"))
(DFunDef false "initialCapacity" () (ELit (LInt 8)))
(DTypeSig false "slotOf" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "slotOf" ((PVar "x") (PVar "cap")) (EBinOp "%" (EApp (EVar "hash") (EVar "x")) (EVar "cap")))
(DTypeSig true "new" (TyFun (TyCon "Unit") (TyApp (TyCon "HashSet") (TyVar "a"))))
(DFunDef false "new" (PWild) (EApp (EApp (EVar "HashSet") (EApp (EVar "Ref") (EApp (EApp (EVar "arrayMake") (EVar "initialCapacity")) (EListLit)))) (EApp (EVar "Ref") (ELit (LInt 0)))))
(DTypeSig true "size" (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Int")))
(DFunDef false "size" ((PCon "HashSet" PWild (PVar "count"))) (EFieldAccess (EVar "count") "value"))
(DTypeSig false "bucketHas" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "bucketHas" (PWild (PList)) (EVar "False"))
(DFunDef false "bucketHas" ((PVar "x") (PCons (PVar "y") (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "bucketHas") (EVar "x")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "has" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "has" ((PVar "x") (PCon "HashSet" (PVar "buckets") PWild)) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoExpr (EApp (EApp (EVar "bucketHas") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EApp (EApp (EVar "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "arr"))))))
(DTypeSig false "bucketRemove" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "bucketRemove" (PWild (PList)) (EListLit))
(DFunDef false "bucketRemove" ((PVar "x") (PCons (PVar "y") (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "rest") (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "bucketRemove") (EVar "x")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "insert" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "insert" ((PVar "x") (PCon "HashSet" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "idx") (EApp (EApp (EVar "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "insertAt") (EVar "x")) (EVar "arr")) (EVar "idx")) (EVar "buckets")) (EVar "count")))))
(DTypeSig false "insertAt" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))))
(DFunDef false "insertAt" ((PVar "x") (PVar "arr") (PVar "idx") (PVar "buckets") (PVar "count")) (EIf (EApp (EApp (EVar "bucketHas") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "+" (EFieldAccess (EVar "count") "value") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "maybeResize") (EVar "buckets")) (EVar "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "maybeResize" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "maybeResize" ((PVar "buckets") (PVar "count")) (EIf (EBinOp ">" (EBinOp "*" (EFieldAccess (EVar "count") "value") (ELit (LInt 4))) (EBinOp "*" (EApp (EVar "arrayLength") (EFieldAccess (EVar "buckets") "value")) (ELit (LInt 3)))) (EApp (EApp (EVar "resize") (EVar "buckets")) (EVar "count")) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "resize" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "resize" ((PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "oldArr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "newArr") (EApp (EApp (EVar "arrayMake") (EBinOp "*" (EApp (EVar "arrayLength") (EVar "oldArr")) (ELit (LInt 2)))) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "buckets")) (EVar "newArr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reinsertAll") (EVar "oldArr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "oldArr"))) (EVar "buckets")) (EVar "count")))))
(DTypeSig false "reinsertAll" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))))
(DFunDef false "reinsertAll" ((PVar "oldArr") (PVar "i") (PVar "n") (PVar "buckets") (PVar "count")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "reinsertBucket") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "oldArr"))) (EVar "buckets")) (EVar "count"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reinsertAll") (EVar "oldArr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "buckets")) (EVar "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reinsertBucket" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))
(DFunDef false "reinsertBucket" ((PList) PWild PWild) (ELit LUnit))
(DFunDef false "reinsertBucket" ((PCons (PVar "x") (PVar "rest")) (PVar "buckets") (PVar "count")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "putRaw") (EVar "x")) (EVar "buckets")) (EVar "count"))) (DoExpr (EApp (EApp (EApp (EVar "reinsertBucket") (EVar "rest")) (EVar "buckets")) (EVar "count")))))
(DTypeSig false "putRaw" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))
(DFunDef false "putRaw" ((PVar "x") (PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "idx") (EApp (EApp (EVar "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "+" (EFieldAccess (EVar "count") "value") (ELit (LInt 1)))))))
(DTypeSig true "fromList" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "HashSet") (TyVar "a")))))
(DFunDef false "fromList" ((PVar "xs")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "insertAll") (EVar "xs")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "insertAll" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "insertAll" ((PList) PWild) (ELit LUnit))
(DFunDef false "insertAll" ((PCons (PVar "x") (PVar "rest")) (PVar "s")) (EBlock (DoExpr (EApp (EApp (EVar "insert") (EVar "x")) (EVar "s"))) (DoExpr (EApp (EApp (EVar "insertAll") (EVar "rest")) (EVar "s")))))
(DTypeSig true "delete" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "delete" ((PVar "x") (PCon "HashSet" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "idx") (EApp (EApp (EVar "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "deleteAt") (EVar "x")) (EVar "arr")) (EVar "idx")) (EVar "count")))))
(DTypeSig false "deleteAt" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "deleteAt" ((PVar "x") (PVar "arr") (PVar "idx") (PVar "count")) (EIf (EApp (EApp (EVar "bucketHas") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EApp (EApp (EVar "bucketRemove") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "-" (EFieldAccess (EVar "count") "value") (ELit (LInt 1)))))) (ELit LUnit)))
(DTypeSig false "collectElems" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "collectElems" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "collectElems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "++" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "elemList" (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "elemList" ((PCon "HashSet" (PVar "buckets") PWild)) (EApp (EApp (EApp (EApp (EVar "collectElems") (EFieldAccess (EVar "buckets") "value")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EFieldAccess (EVar "buckets") "value"))) (EListLit)))
(DTypeSig false "foldrElems" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldrElems" (PWild (PVar "z") (PList)) (EVar "z"))
(DFunDef false "foldrElems" ((PVar "f") (PVar "z") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "f") (EVar "x")) (EApp (EApp (EApp (EVar "foldrElems") (EVar "f")) (EVar "z")) (EVar "rest"))))
(DTypeSig false "foldlElems" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldlElems" (PWild (PVar "z") (PList)) (EVar "z"))
(DFunDef false "foldlElems" ((PVar "f") (PVar "z") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EApp (EVar "foldlElems") (EVar "f")) (EApp (EApp (EVar "f") (EVar "z")) (EVar "x"))) (EVar "rest")))
(DImpl true "Foldable" ((TyCon "HashSet")) () ((im "fold" ((PVar "f") (PVar "z") (PVar "s")) (EApp (EApp (EApp (EVar "foldlElems") (EVar "f")) (EVar "z")) (EApp (EVar "elemList") (EVar "s")))) (im "foldRight" ((PVar "f") (PVar "z") (PVar "s")) (EApp (EApp (EApp (EVar "foldrElems") (EVar "f")) (EVar "z")) (EApp (EVar "elemList") (EVar "s")))) (im "toList" ((PVar "s")) (EApp (EVar "elemList") (EVar "s"))) (im "isEmpty" ((PVar "s")) (EBinOp "==" (EApp (EVar "size") (EVar "s")) (ELit (LInt 0)))) (im "length" ((PVar "s")) (EApp (EVar "size") (EVar "s")))))
(DTypeSig false "allIn" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "allIn" ((PList) PWild) (EVar "True"))
(DFunDef false "allIn" ((PCons (PVar "x") (PVar "rest")) (PVar "s")) (EIf (EApp (EApp (EVar "has") (EVar "x")) (EVar "s")) (EApp (EApp (EVar "allIn") (EVar "rest")) (EVar "s")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Eq" ((TyApp (TyCon "HashSet") (TyVar "a"))) ((req "Eq" ((TyVar "a"))) (req "Hashable" ((TyVar "a")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "!=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EVar "False") (EApp (EApp (EVar "allIn") (EApp (EVar "elemList") (EVar "a"))) (EVar "b"))))))
(DImpl true "Debug" ((TyApp (TyCon "HashSet") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EVar "display") (EApp (EVar "debug") (EApp (EVar "elemList") (EVar "s"))))) (ELit (LString ""))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Debug" false) (mem "Foldable" false) (mem "Hashable" false))))
(DData Public "HashSet" ("a") ((variant "HashSet" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DTypeSig false "initialCapacity" (TyCon "Int"))
(DFunDef false "initialCapacity" () (ELit (LInt 8)))
(DTypeSig false "slotOf" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "slotOf" ((PVar "x") (PVar "cap")) (EBinOp "%" (EApp (EMethodRef "hash") (EVar "x")) (EVar "cap")))
(DTypeSig true "new" (TyFun (TyCon "Unit") (TyApp (TyCon "HashSet") (TyVar "a"))))
(DFunDef false "new" (PWild) (EApp (EApp (EVar "HashSet") (EApp (EVar "Ref") (EApp (EApp (EVar "arrayMake") (EVar "initialCapacity")) (EListLit)))) (EApp (EVar "Ref") (ELit (LInt 0)))))
(DTypeSig true "size" (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Int")))
(DFunDef false "size" ((PCon "HashSet" PWild (PVar "count"))) (EFieldAccess (EDictApp "count") "value"))
(DTypeSig false "bucketHas" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "bucketHas" (PWild (PList)) (EVar "False"))
(DFunDef false "bucketHas" ((PVar "x") (PCons (PVar "y") (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EDictApp "bucketHas") (EVar "x")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "has" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "has" ((PVar "x") (PCon "HashSet" (PVar "buckets") PWild)) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoExpr (EApp (EApp (EDictApp "bucketHas") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EApp (EApp (EDictApp "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (EVar "arr"))))))
(DTypeSig false "bucketRemove" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "bucketRemove" (PWild (PList)) (EListLit))
(DFunDef false "bucketRemove" ((PVar "x") (PCons (PVar "y") (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "rest") (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EDictApp "bucketRemove") (EVar "x")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "insert" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "insert" ((PVar "x") (PCon "HashSet" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "idx") (EApp (EApp (EDictApp "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EDictApp "insertAt") (EVar "x")) (EVar "arr")) (EVar "idx")) (EVar "buckets")) (EDictApp "count")))))
(DTypeSig false "insertAt" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))))
(DFunDef false "insertAt" ((PVar "x") (PVar "arr") (PVar "idx") (PVar "buckets") (PVar "count")) (EIf (EApp (EApp (EDictApp "bucketHas") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (EBinOp "+" (EFieldAccess (EDictApp "count") "value") (ELit (LInt 1))))) (DoExpr (EApp (EApp (EDictApp "maybeResize") (EVar "buckets")) (EDictApp "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "maybeResize" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "maybeResize" ((PVar "buckets") (PVar "count")) (EIf (EBinOp ">" (EBinOp "*" (EFieldAccess (EDictApp "count") "value") (ELit (LInt 4))) (EBinOp "*" (EApp (EVar "arrayLength") (EFieldAccess (EVar "buckets") "value")) (ELit (LInt 3)))) (EApp (EApp (EDictApp "resize") (EVar "buckets")) (EDictApp "count")) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "resize" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))
(DFunDef false "resize" ((PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "oldArr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "newArr") (EApp (EApp (EVar "arrayMake") (EBinOp "*" (EApp (EVar "arrayLength") (EVar "oldArr")) (ELit (LInt 2)))) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "buckets")) (EVar "newArr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EDictApp "reinsertAll") (EVar "oldArr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "oldArr"))) (EVar "buckets")) (EDictApp "count")))))
(DTypeSig false "reinsertAll" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))))
(DFunDef false "reinsertAll" ((PVar "oldArr") (PVar "i") (PVar "n") (PVar "buckets") (PVar "count")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EDictApp "reinsertBucket") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "oldArr"))) (EVar "buckets")) (EDictApp "count"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EDictApp "reinsertAll") (EVar "oldArr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EVar "buckets")) (EDictApp "count")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reinsertBucket" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))
(DFunDef false "reinsertBucket" ((PList) PWild PWild) (ELit LUnit))
(DFunDef false "reinsertBucket" ((PCons (PVar "x") (PVar "rest")) (PVar "buckets") (PVar "count")) (EBlock (DoExpr (EApp (EApp (EApp (EDictApp "putRaw") (EVar "x")) (EVar "buckets")) (EDictApp "count"))) (DoExpr (EApp (EApp (EApp (EDictApp "reinsertBucket") (EVar "rest")) (EVar "buckets")) (EDictApp "count")))))
(DTypeSig false "putRaw" (TyConstrained ((cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit"))))))
(DFunDef false "putRaw" ((PVar "x") (PVar "buckets") (PVar "count")) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "idx") (EApp (EApp (EDictApp "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (EBinOp "+" (EFieldAccess (EDictApp "count") "value") (ELit (LInt 1)))))))
(DTypeSig true "fromList" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "HashSet") (TyVar "a")))))
(DFunDef false "fromList" ((PVar "xs")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EDictApp "insertAll") (EVar "xs")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "insertAll" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "insertAll" ((PList) PWild) (ELit LUnit))
(DFunDef false "insertAll" ((PCons (PVar "x") (PVar "rest")) (PVar "s")) (EBlock (DoExpr (EApp (EApp (EDictApp "insert") (EVar "x")) (EVar "s"))) (DoExpr (EApp (EApp (EDictApp "insertAll") (EVar "rest")) (EVar "s")))))
(DTypeSig true "delete" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "delete" ((PVar "x") (PCon "HashSet" (PVar "buckets") (PVar "count"))) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "buckets") "value")) (DoLet false false (PVar "idx") (EApp (EApp (EDictApp "slotOf") (EVar "x")) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EApp (EApp (EApp (EApp (EDictApp "deleteAt") (EVar "x")) (EVar "arr")) (EVar "idx")) (EDictApp "count")))))
(DTypeSig false "deleteAt" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "deleteAt" ((PVar "x") (PVar "arr") (PVar "idx") (PVar "count")) (EIf (EApp (EApp (EDictApp "bucketHas") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "idx")) (EApp (EApp (EDictApp "bucketRemove") (EVar "x")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "idx")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (EBinOp "-" (EFieldAccess (EDictApp "count") "value") (ELit (LInt 1)))))) (ELit LUnit)))
(DTypeSig false "collectElems" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "List") (TyVar "a"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "collectElems" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "collectElems") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "++" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "elemList" (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "elemList" ((PCon "HashSet" (PVar "buckets") PWild)) (EApp (EApp (EApp (EApp (EVar "collectElems") (EFieldAccess (EVar "buckets") "value")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EFieldAccess (EVar "buckets") "value"))) (EListLit)))
(DTypeSig false "foldrElems" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldrElems" (PWild (PVar "z") (PList)) (EVar "z"))
(DFunDef false "foldrElems" ((PVar "f") (PVar "z") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "f") (EVar "x")) (EApp (EApp (EApp (EVar "foldrElems") (EVar "f")) (EVar "z")) (EVar "rest"))))
(DTypeSig false "foldlElems" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "foldlElems" (PWild (PVar "z") (PList)) (EVar "z"))
(DFunDef false "foldlElems" ((PVar "f") (PVar "z") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EApp (EVar "foldlElems") (EVar "f")) (EApp (EApp (EVar "f") (EVar "z")) (EVar "x"))) (EVar "rest")))
(DImpl true "Foldable" ((TyCon "HashSet")) () ((im "fold" ((PVar "f") (PVar "z") (PVar "s")) (EApp (EApp (EApp (EVar "foldlElems") (EVar "f")) (EVar "z")) (EApp (EVar "elemList") (EVar "s")))) (im "foldRight" ((PVar "f") (PVar "z") (PVar "s")) (EApp (EApp (EApp (EVar "foldrElems") (EVar "f")) (EVar "z")) (EApp (EVar "elemList") (EVar "s")))) (im "toList" ((PVar "s")) (EApp (EVar "elemList") (EVar "s"))) (im "isEmpty" ((PVar "s")) (EBinOp "==" (EApp (EVar "size") (EVar "s")) (ELit (LInt 0)))) (im "length" ((PVar "s")) (EApp (EVar "size") (EVar "s")))))
(DTypeSig false "allIn" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Hashable" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "HashSet") (TyVar "a")) (TyCon "Bool")))))
(DFunDef false "allIn" ((PList) PWild) (EVar "True"))
(DFunDef false "allIn" ((PCons (PVar "x") (PVar "rest")) (PVar "s")) (EIf (EApp (EApp (EDictApp "has") (EVar "x")) (EVar "s")) (EApp (EApp (EDictApp "allIn") (EVar "rest")) (EVar "s")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Eq" ((TyApp (TyCon "HashSet") (TyVar "a"))) ((req "Eq" ((TyVar "a"))) (req "Hashable" ((TyVar "a")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "!=" (EApp (EVar "size") (EVar "a")) (EApp (EVar "size") (EVar "b"))) (EVar "False") (EApp (EApp (EDictApp "allIn") (EApp (EVar "elemList") (EVar "a"))) (EVar "b"))))))
(DImpl true "Debug" ((TyApp (TyCon "HashSet") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EApp (EVar "elemList") (EVar "s"))))) (ELit (LString ""))))))
