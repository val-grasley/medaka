# META
source_lines=232
stages=DESUGAR,MARK
# SOURCE
{- mut_array.mdk — a growable mutable array (dynamic array / vector).

   `Array a` (Module 4) is **fixed-size**: O(1) random access, but no `push`/
   `pop`.  `MutArray a` is the growable counterpart — a vector backed by an
   `Array a` with spare capacity, so `push` is amortized O(1) (the backing
   doubles when full, like the hash tables in Module 6).  Reach for `Array` when
   the length is known up front; reach for `MutArray` when you accumulate.

   Representation: `MutArray backing len` where `backing.value` is the backing
   array (its `arrayLength` is the *capacity*) and `len.value` is the number of
   live elements (`0 <= len <= capacity`).  Both are `Ref`s, mutated in place
   (`<Mut>`).  Slots `[len, capacity)` are scratch — never read; they hold
   whatever value last filled them (the most recent `push`'s element on a grow).

   Iteration / instances only ever touch the live range `[0, len)`, so the
   scratch tail is invisible.  `empty`/`new` start at capacity 0 and allocate on
   first `push`, using the pushed element as the fill — so no dummy/default
   value is needed to construct one. -}

import core.{Eq, Debug, Foldable, Option, Index, IndexMut}

{- `MutArray backing len`: `backing.value` is the capacity-sized store,
   `len.value` the live count; both mutated in place. -}
public export data MutArray a = MutArray (Ref (Array a)) (Ref Int)

-- Live element count (internal; the public name is `Foldable.length`).
count : MutArray a -> Int
count (MutArray _ len) = len.value

-- ── Construction ────────────────────────────────────────────────────────

{- | A fresh, empty vector (capacity 0; grows on first `push`).  Takes `Unit`,
   not a nullary value, so each call allocates its own cells. -}
export new : Unit -> MutArray a
new _ = MutArray (Ref [||]) (Ref 0)

{- | Build a vector from a list, preserving order.  Capacity equals the length
   (the next `push` triggers a grow).

   > length (fromList [1, 2, 3])
   3 -}
export fromList : List a -> MutArray a
fromList xs =
  let arr = arrayFromList xs
  MutArray (Ref arr) (Ref (arrayLength arr))

{- | Wrap a *copy* of an array as a vector (so later mutation does not disturb
   the caller's array). -}
export fromArray : Array a -> MutArray a
fromArray arr =
  let c = arrayCopy arr
  MutArray (Ref c) (Ref (arrayLength c))

-- ── Observation (pure reads) ────────────────────────────────────────────

{- | Capacity of the backing store (`>= length`).  Grows by doubling.

   > capacity (fromList [1, 2, 3])
   3 -}
export capacity : MutArray a -> Int
capacity (MutArray backing _) = arrayLength backing.value

{- | Element at an index, or `None` when out of the live range `[0, length)`.

   > get 1 (fromList [10, 20, 30])
   Some 20
   > get 5 (fromList [10, 20, 30])
   None -}
export get : Int -> MutArray a -> Option a
get i (MutArray backing len)
  | i >= 0 && i < len.value = Some (arrayGetUnsafe i backing.value)
  | otherwise = None

{- | `index ma i` reads `ma`'s element at `i` (`ma[i]` sugar dispatches here),
   over the live range `[0, length)`.  O(1).  Raises the coded `indexError`
   (E-INDEX-OOB) when `i` is out of range -- use `get` for a safe
   `Option`-returning read instead. -}
export impl Index (MutArray a) Int a where
  index (MutArray backing len) i =
    if i >= 0 && i < len.value then
      arrayGetUnsafe i backing.value
    else
      indexError "index \{intToString i} out of bounds"

{- | First element, or `None` when empty.

   > first (fromList [10, 20, 30])
   Some 10 -}
export first : MutArray a -> Option a
first ma = get 0 ma

{- | Last element, or `None` when empty.

   > last (fromList [10, 20, 30])
   Some 30 -}
export last : MutArray a -> Option a
last ma = get (count ma - 1) ma

-- ── Conversion ──────────────────────────────────────────────────────────

elemsGo : Array a -> Int -> List a -> List a
elemsGo arr i acc
  | i < 0 = acc
  | otherwise = elemsGo arr (i - 1) (arrayGetUnsafe i arr :: acc)

-- The live elements as a list, in order (used by `Foldable.toList`).
elems : MutArray a -> List a
elems (MutArray backing len) = elemsGo backing.value (len.value - 1) []

{- | Snapshot the live range into a fresh fixed-size `Array a`.  (Shown here via
   the `arrayLength` kernel primitive — `Array`'s own `Foldable`/`Debug` live in
   `array.mdk`, which this module does not import.)

   > arrayLength (toArray (fromList [1, 2, 3]))
   3 -}
export toArray : MutArray a -> Array a
toArray (MutArray backing len) =
  let arr = backing.value
  arrayMakeWith len.value (i => arrayGetUnsafe i arr)

-- ── Mutation (effectful — modify in place) ──────────────────────────────

{- | Append an element, growing (doubling) the backing store when it is full.
   Amortized O(1). -}
export push : a -> MutArray a -> Unit
push x (MutArray backing len)
  | len.value < arrayLength backing.value =
    arraySetUnsafe len.value x backing.value
    setRef len (len.value + 1)
  | otherwise =
    let oldArr = backing.value
    let oldLen = len.value
    let newCap = if oldLen == 0 then 1 else oldLen * 2
    let newArr = arrayMake newCap x
    arrayBlit oldArr 0 newArr 0 oldLen
    setRef backing newArr
    setRef len (oldLen + 1)

{- | Remove and return the last element, or `None` when empty.  Keeps capacity
   (no shrink). -}
export pop : MutArray a -> Option a
pop (MutArray backing len)
  | len.value == 0 = None
  | otherwise =
    let i = len.value - 1
    let x = arrayGetUnsafe i backing.value
    setRef len i
    Some x

{- | Overwrite the element at an index.  Panics when out of the live range
   `[0, length)` (use `push` to extend). -}
export set : Int -> a -> MutArray a -> Unit
set i x (MutArray backing len)
  | i >= 0 && i < len.value = arraySetUnsafe i x backing.value
  | otherwise = panic "MutArray.set: index out of bounds"

{- | `setIndex ma i v` writes `v` at `ma`'s index `i`, in place, over the live
   range `[0, length)`, and returns `ma`.  O(1).  Raises the coded
   `indexError` (E-INDEX-OOB) when `i` is out of range. -}
export impl IndexMut (MutArray a) Int a where
  setIndex (MutArray backing len) i v =
    if i >= 0 && i < len.value then
      let _ = arraySetUnsafe i v backing.value
      MutArray backing len
    else indexError "index \{intToString i} out of bounds"

{- | Exchange the elements at two indices.  Caller ensures both are in range. -}
export swap : Int -> Int -> MutArray a -> Unit
swap i j (MutArray backing _) =
  let arr = backing.value
  let xi = arrayGetUnsafe i arr
  let xj = arrayGetUnsafe j arr
  arraySetUnsafe i xj arr
  arraySetUnsafe j xi arr

{- | Drop all elements (length 0), retaining the allocated capacity. -}
export clear : MutArray a -> Unit
clear (MutArray _ len) = setRef len 0

mapInPlaceGo : (a -> a) -> Array a -> Int -> Int -> Unit
mapInPlaceGo f arr i n
  | i >= n = ()
  | otherwise =
    arraySetUnsafe i (f (arrayGetUnsafe i arr)) arr
    mapInPlaceGo f arr (i + 1) n

{- | Apply `f` to every live element in place. -}
export mapInPlace : (a -> a) -> MutArray a -> Unit
mapInPlace f (MutArray backing len) = mapInPlaceGo f backing.value 0 len.value

-- ── Folds (index-based; never allocate a list) ──────────────────────────

foldGo : (b -> a -> <e> b) -> b -> Array a -> Int -> Int -> <e> b
foldGo f z arr i n
  | i >= n = z
  | otherwise = foldGo f (f z (arrayGetUnsafe i arr)) arr (i + 1) n

foldRightGo : (a -> b -> <e> b) -> b -> Array a -> Int -> <e> b
foldRightGo f z arr i
  | i < 0 = z
  | otherwise = foldRightGo f (f (arrayGetUnsafe i arr) z) arr (i - 1)

-- ── Instances ───────────────────────────────────────────────────────────

{- | Folds over the live range (in order), so `toList`/`length`/`sum`/`elem`/
   `any`/… all work on a `MutArray`.

   > sum (fromList [1, 2, 3, 4])
   10
   > length (fromList [9, 8, 7])
   3 -}
export impl Foldable MutArray where
  fold f z (MutArray backing len) = foldGo f z backing.value 0 len.value
  foldRight f z (MutArray backing len) =
    foldRightGo f z backing.value (len.value - 1)
  toList ma = elems ma
  isEmpty (MutArray _ len) = len.value == 0
  length (MutArray _ len) = len.value

{- | Element-wise equality over the live ranges (capacity is irrelevant).

   > eq (fromList [1, 2, 3]) (fromList [1, 2, 3])
   True -}
export impl Eq (MutArray a) requires Eq a where
  eq a b = if count a != count b then False else eq (elems a) (elems b)

{- | Rendered as `fromList [a, …]` over the live range.

   > debug (fromList [1, 2, 3]) == "fromList [1, 2, 3]"
   True -}
export impl Debug (MutArray a) requires Debug a where
  debug ma = "fromList \{debug (elems ma)}"
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Debug" false) (mem "Foldable" false) (mem "Option" false) (mem "Index" false) (mem "IndexMut" false))))
(DData Public "MutArray" ("a") ((variant "MutArray" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyVar "a"))) (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DTypeSig false "count" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Int")))
(DFunDef false "count" ((PCon "MutArray" PWild (PVar "len"))) (EFieldAccess (EVar "len") "value"))
(DTypeSig true "new" (TyFun (TyCon "Unit") (TyApp (TyCon "MutArray") (TyVar "a"))))
(DFunDef false "new" (PWild) (EApp (EApp (EVar "MutArray") (EApp (EVar "Ref") (EArrayLit))) (EApp (EVar "Ref") (ELit (LInt 0)))))
(DTypeSig true "fromList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "MutArray") (TyVar "a"))))
(DFunDef false "fromList" ((PVar "xs")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "arrayFromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "MutArray") (EApp (EVar "Ref") (EVar "arr"))) (EApp (EVar "Ref") (EApp (EVar "arrayLength") (EVar "arr")))))))
(DTypeSig true "fromArray" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "MutArray") (TyVar "a"))))
(DFunDef false "fromArray" ((PVar "arr")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "arrayCopy") (EVar "arr"))) (DoExpr (EApp (EApp (EVar "MutArray") (EApp (EVar "Ref") (EVar "c"))) (EApp (EVar "Ref") (EApp (EVar "arrayLength") (EVar "c")))))))
(DTypeSig true "capacity" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Int")))
(DFunDef false "capacity" ((PCon "MutArray" (PVar "backing") PWild)) (EApp (EVar "arrayLength") (EFieldAccess (EVar "backing") "value")))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "get" ((PVar "i") (PCon "MutArray" (PVar "backing") (PVar "len"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EFieldAccess (EVar "len") "value"))) (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "backing") "value"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Index" ((TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Int") (TyVar "a")) () ((im "index" ((PCon "MutArray" (PVar "backing") (PVar "len")) (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EFieldAccess (EVar "len") "value"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "backing") "value")) (EApp (EVar "indexError") (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " out of bounds"))))))))
(DTypeSig true "first" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "first" ((PVar "ma")) (EApp (EApp (EVar "get") (ELit (LInt 0))) (EVar "ma")))
(DTypeSig true "last" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "last" ((PVar "ma")) (EApp (EApp (EVar "get") (EBinOp "-" (EApp (EVar "count") (EVar "ma")) (ELit (LInt 1)))) (EVar "ma")))
(DTypeSig false "elemsGo" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "elemsGo" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "elemsGo") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "elems" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "elems" ((PCon "MutArray" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EVar "elemsGo") (EFieldAccess (EVar "backing") "value")) (EBinOp "-" (EFieldAccess (EVar "len") "value") (ELit (LInt 1)))) (EListLit)))
(DTypeSig true "toArray" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "toArray" ((PCon "MutArray" (PVar "backing") (PVar "len"))) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "backing") "value")) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EFieldAccess (EVar "len") "value")) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))))
(DTypeSig true "push" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "push" ((PVar "x") (PCon "MutArray" (PVar "backing") (PVar "len"))) (EIf (EBinOp "<" (EFieldAccess (EVar "len") "value") (EApp (EVar "arrayLength") (EFieldAccess (EVar "backing") "value"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EFieldAccess (EVar "len") "value")) (EVar "x")) (EFieldAccess (EVar "backing") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "len")) (EBinOp "+" (EFieldAccess (EVar "len") "value") (ELit (LInt 1)))))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "oldArr") (EFieldAccess (EVar "backing") "value")) (DoLet false false (PVar "oldLen") (EFieldAccess (EVar "len") "value")) (DoLet false false (PVar "newCap") (EIf (EBinOp "==" (EVar "oldLen") (ELit (LInt 0))) (ELit (LInt 1)) (EBinOp "*" (EVar "oldLen") (ELit (LInt 2))))) (DoLet false false (PVar "newArr") (EApp (EApp (EVar "arrayMake") (EVar "newCap")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "oldArr")) (ELit (LInt 0))) (EVar "newArr")) (ELit (LInt 0))) (EVar "oldLen"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "backing")) (EVar "newArr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "len")) (EBinOp "+" (EVar "oldLen") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "pop" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "pop" ((PCon "MutArray" (PVar "backing") (PVar "len"))) (EIf (EBinOp "==" (EFieldAccess (EVar "len") "value") (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "i") (EBinOp "-" (EFieldAccess (EVar "len") "value") (ELit (LInt 1)))) (DoLet false false (PVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "backing") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "len")) (EVar "i"))) (DoExpr (EApp (EVar "Some") (EVar "x")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "set" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "set" ((PVar "i") (PVar "x") (PCon "MutArray" (PVar "backing") (PVar "len"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EFieldAccess (EVar "len") "value"))) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "x")) (EFieldAccess (EVar "backing") "value")) (EIf (EVar "otherwise") (EApp (EVar "panic") (ELit (LString "MutArray.set: index out of bounds"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "IndexMut" ((TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Int") (TyVar "a")) () ((im "setIndex" ((PCon "MutArray" (PVar "backing") (PVar "len")) (PVar "i") (PVar "v")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EFieldAccess (EVar "len") "value"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "v")) (EFieldAccess (EVar "backing") "value"))) (DoExpr (EApp (EApp (EVar "MutArray") (EVar "backing")) (EVar "len")))) (EApp (EVar "indexError") (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " out of bounds"))))))))
(DTypeSig true "swap" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "swap" ((PVar "i") (PVar "j") (PCon "MutArray" (PVar "backing") PWild)) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "backing") "value")) (DoLet false false (PVar "xi") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (DoLet false false (PVar "xj") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "xj")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EVar "xi")) (EVar "arr")))))
(DTypeSig true "clear" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Unit")))
(DFunDef false "clear" ((PCon "MutArray" PWild (PVar "len"))) (EApp (EApp (EVar "setRef") (EVar "len")) (ELit (LInt 0))))
(DTypeSig false "mapInPlaceGo" (TyFun (TyFun (TyVar "a") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "mapInPlaceGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mapInPlaceGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "mapInPlace" (TyFun (TyFun (TyVar "a") (TyVar "a")) (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "mapInPlace" ((PVar "f") (PCon "MutArray" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EApp (EVar "mapInPlaceGo") (EVar "f")) (EFieldAccess (EVar "backing") "value")) (ELit (LInt 0))) (EFieldAccess (EVar "len") "value")))
(DTypeSig false "foldGo" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "b"))))))))
(DFunDef false "foldGo" ((PVar "f") (PVar "z") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "z") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EApp (EApp (EVar "f") (EVar "z")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "foldRightGo" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "b")))))))
(DFunDef false "foldRightGo" ((PVar "f") (PVar "z") (PVar "arr") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "z") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "foldRightGo") (EVar "f")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EVar "z"))) (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Foldable" ((TyCon "MutArray")) () ((im "fold" ((PVar "f") (PVar "z") (PCon "MutArray" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EVar "z")) (EFieldAccess (EVar "backing") "value")) (ELit (LInt 0))) (EFieldAccess (EVar "len") "value"))) (im "foldRight" ((PVar "f") (PVar "z") (PCon "MutArray" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EApp (EVar "foldRightGo") (EVar "f")) (EVar "z")) (EFieldAccess (EVar "backing") "value")) (EBinOp "-" (EFieldAccess (EVar "len") "value") (ELit (LInt 1))))) (im "toList" ((PVar "ma")) (EApp (EVar "elems") (EVar "ma"))) (im "isEmpty" ((PCon "MutArray" PWild (PVar "len"))) (EBinOp "==" (EFieldAccess (EVar "len") "value") (ELit (LInt 0)))) (im "length" ((PCon "MutArray" PWild (PVar "len"))) (EFieldAccess (EVar "len") "value"))))
(DImpl true "Eq" ((TyApp (TyCon "MutArray") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "!=" (EApp (EVar "count") (EVar "a")) (EApp (EVar "count") (EVar "b"))) (EVar "False") (EApp (EApp (EVar "eq") (EApp (EVar "elems") (EVar "a"))) (EApp (EVar "elems") (EVar "b")))))))
(DImpl true "Debug" ((TyApp (TyCon "MutArray") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "ma")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EVar "display") (EApp (EVar "debug") (EApp (EVar "elems") (EVar "ma"))))) (ELit (LString ""))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Debug" false) (mem "Foldable" false) (mem "Option" false) (mem "Index" false) (mem "IndexMut" false))))
(DData Public "MutArray" ("a") ((variant "MutArray" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyVar "a"))) (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DTypeSig false "count" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Int")))
(DFunDef false "count" ((PCon "MutArray" PWild (PVar "len"))) (EFieldAccess (EVar "len") "value"))
(DTypeSig true "new" (TyFun (TyCon "Unit") (TyApp (TyCon "MutArray") (TyVar "a"))))
(DFunDef false "new" (PWild) (EApp (EApp (EVar "MutArray") (EApp (EVar "Ref") (EArrayLit))) (EApp (EVar "Ref") (ELit (LInt 0)))))
(DTypeSig true "fromList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "MutArray") (TyVar "a"))))
(DFunDef false "fromList" ((PVar "xs")) (EBlock (DoLet false false (PVar "arr") (EApp (EVar "arrayFromList") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "MutArray") (EApp (EVar "Ref") (EVar "arr"))) (EApp (EVar "Ref") (EApp (EVar "arrayLength") (EVar "arr")))))))
(DTypeSig true "fromArray" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "MutArray") (TyVar "a"))))
(DFunDef false "fromArray" ((PVar "arr")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "arrayCopy") (EVar "arr"))) (DoExpr (EApp (EApp (EVar "MutArray") (EApp (EVar "Ref") (EVar "c"))) (EApp (EVar "Ref") (EApp (EVar "arrayLength") (EVar "c")))))))
(DTypeSig true "capacity" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Int")))
(DFunDef false "capacity" ((PCon "MutArray" (PVar "backing") PWild)) (EApp (EVar "arrayLength") (EFieldAccess (EVar "backing") "value")))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "get" ((PVar "i") (PCon "MutArray" (PVar "backing") (PVar "len"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EFieldAccess (EVar "len") "value"))) (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "backing") "value"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Index" ((TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Int") (TyVar "a")) () ((im "index" ((PCon "MutArray" (PVar "backing") (PVar "len")) (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EFieldAccess (EVar "len") "value"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "backing") "value")) (EApp (EVar "indexError") (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " out of bounds"))))))))
(DTypeSig true "first" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "first" ((PVar "ma")) (EApp (EApp (EVar "get") (ELit (LInt 0))) (EVar "ma")))
(DTypeSig true "last" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "last" ((PVar "ma")) (EApp (EApp (EVar "get") (EBinOp "-" (EApp (EVar "count") (EVar "ma")) (ELit (LInt 1)))) (EVar "ma")))
(DTypeSig false "elemsGo" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "elemsGo" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "elemsGo") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "elems" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "elems" ((PCon "MutArray" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EVar "elemsGo") (EFieldAccess (EVar "backing") "value")) (EBinOp "-" (EFieldAccess (EVar "len") "value") (ELit (LInt 1)))) (EListLit)))
(DTypeSig true "toArray" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyApp (TyCon "Array") (TyVar "a"))))
(DFunDef false "toArray" ((PCon "MutArray" (PVar "backing") (PVar "len"))) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "backing") "value")) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EFieldAccess (EVar "len") "value")) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))))))
(DTypeSig true "push" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "push" ((PVar "x") (PCon "MutArray" (PVar "backing") (PVar "len"))) (EIf (EBinOp "<" (EFieldAccess (EVar "len") "value") (EApp (EVar "arrayLength") (EFieldAccess (EVar "backing") "value"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EFieldAccess (EVar "len") "value")) (EVar "x")) (EFieldAccess (EVar "backing") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "len")) (EBinOp "+" (EFieldAccess (EVar "len") "value") (ELit (LInt 1)))))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "oldArr") (EFieldAccess (EVar "backing") "value")) (DoLet false false (PVar "oldLen") (EFieldAccess (EVar "len") "value")) (DoLet false false (PVar "newCap") (EIf (EBinOp "==" (EVar "oldLen") (ELit (LInt 0))) (ELit (LInt 1)) (EBinOp "*" (EVar "oldLen") (ELit (LInt 2))))) (DoLet false false (PVar "newArr") (EApp (EApp (EVar "arrayMake") (EVar "newCap")) (EVar "x"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "arrayBlit") (EVar "oldArr")) (ELit (LInt 0))) (EVar "newArr")) (ELit (LInt 0))) (EVar "oldLen"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "backing")) (EVar "newArr"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "len")) (EBinOp "+" (EVar "oldLen") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "pop" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "a"))))
(DFunDef false "pop" ((PCon "MutArray" (PVar "backing") (PVar "len"))) (EIf (EBinOp "==" (EFieldAccess (EVar "len") "value") (ELit (LInt 0))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "i") (EBinOp "-" (EFieldAccess (EVar "len") "value") (ELit (LInt 1)))) (DoLet false false (PVar "x") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "backing") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "len")) (EVar "i"))) (DoExpr (EApp (EVar "Some") (EVar "x")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "set" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "set" ((PVar "i") (PVar "x") (PCon "MutArray" (PVar "backing") (PVar "len"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EFieldAccess (EVar "len") "value"))) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "x")) (EFieldAccess (EVar "backing") "value")) (EIf (EVar "otherwise") (EApp (EVar "panic") (ELit (LString "MutArray.set: index out of bounds"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "IndexMut" ((TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Int") (TyVar "a")) () ((im "setIndex" ((PCon "MutArray" (PVar "backing") (PVar "len")) (PVar "i") (PVar "v")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EFieldAccess (EVar "len") "value"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "v")) (EFieldAccess (EVar "backing") "value"))) (DoExpr (EApp (EApp (EVar "MutArray") (EVar "backing")) (EVar "len")))) (EApp (EVar "indexError") (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " out of bounds"))))))))
(DTypeSig true "swap" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Unit")))))
(DFunDef false "swap" ((PVar "i") (PVar "j") (PCon "MutArray" (PVar "backing") PWild)) (EBlock (DoLet false false (PVar "arr") (EFieldAccess (EVar "backing") "value")) (DoLet false false (PVar "xi") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (DoLet false false (PVar "xj") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "xj")) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EVar "xi")) (EVar "arr")))))
(DTypeSig true "clear" (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Unit")))
(DFunDef false "clear" ((PCon "MutArray" PWild (PVar "len"))) (EApp (EApp (EVar "setRef") (EVar "len")) (ELit (LInt 0))))
(DTypeSig false "mapInPlaceGo" (TyFun (TyFun (TyVar "a") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "mapInPlaceGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EVar "arr"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "mapInPlaceGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "mapInPlace" (TyFun (TyFun (TyVar "a") (TyVar "a")) (TyFun (TyApp (TyCon "MutArray") (TyVar "a")) (TyCon "Unit"))))
(DFunDef false "mapInPlace" ((PVar "f") (PCon "MutArray" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EApp (EVar "mapInPlaceGo") (EVar "f")) (EFieldAccess (EVar "backing") "value")) (ELit (LInt 0))) (EFieldAccess (EVar "len") "value")))
(DTypeSig false "foldGo" (TyFun (TyFun (TyVar "b") (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "b"))))))))
(DFunDef false "foldGo" ((PVar "f") (PVar "z") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "z") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EApp (EApp (EVar "f") (EVar "z")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")))) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "foldRightGo" (TyFun (TyFun (TyVar "a") (TyFun (TyVar "b") (TyEffect () (Some "e") (TyVar "b")))) (TyFun (TyVar "b") (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyVar "b")))))))
(DFunDef false "foldRightGo" ((PVar "f") (PVar "z") (PVar "arr") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "z") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "foldRightGo") (EVar "f")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (EVar "z"))) (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DImpl true "Foldable" ((TyCon "MutArray")) () ((im "fold" ((PVar "f") (PVar "z") (PCon "MutArray" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EApp (EApp (EVar "foldGo") (EVar "f")) (EVar "z")) (EFieldAccess (EVar "backing") "value")) (ELit (LInt 0))) (EFieldAccess (EVar "len") "value"))) (im "foldRight" ((PVar "f") (PVar "z") (PCon "MutArray" (PVar "backing") (PVar "len"))) (EApp (EApp (EApp (EApp (EVar "foldRightGo") (EVar "f")) (EVar "z")) (EFieldAccess (EVar "backing") "value")) (EBinOp "-" (EFieldAccess (EVar "len") "value") (ELit (LInt 1))))) (im "toList" ((PVar "ma")) (EApp (EVar "elems") (EVar "ma"))) (im "isEmpty" ((PCon "MutArray" PWild (PVar "len"))) (EBinOp "==" (EFieldAccess (EVar "len") "value") (ELit (LInt 0)))) (im "length" ((PCon "MutArray" PWild (PVar "len"))) (EFieldAccess (EVar "len") "value"))))
(DImpl true "Eq" ((TyApp (TyCon "MutArray") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PVar "a") (PVar "b")) (EIf (EBinOp "!=" (EApp (EVar "count") (EVar "a")) (EApp (EVar "count") (EVar "b"))) (EVar "False") (EApp (EApp (EMethodRef "eq") (EApp (EVar "elems") (EVar "a"))) (EApp (EVar "elems") (EVar "b")))))))
(DImpl true "Debug" ((TyApp (TyCon "MutArray") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "ma")) (EBinOp "++" (EBinOp "++" (ELit (LString "fromList ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EApp (EVar "elems") (EVar "ma"))))) (ELit (LString ""))))))
