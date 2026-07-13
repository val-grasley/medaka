# META
source_lines=136
stages=DESUGAR,MARK
# SOURCE
-- nonempty — a guaranteed-non-empty list.
--
-- `NonEmpty a` is a head element plus a (possibly empty) tail list, so it can
-- never be empty by construction.  This lets `head`, `maximum`, and `minimum`
-- be TOTAL — they return an `a`, not an `Option a` like the partial Foldable
-- helpers on a plain `List`.
--
-- Import by bare name: `import nonempty` (this module is not auto-prelude), then
-- call `nonempty.head`, `nonempty.maximum`, etc.

import core.{
  Eq,
  Ord,
  Debug,
  Display,
  Mappable,
  Foldable,
  Traversable,
  Semigroup,
  Applicative,
  Thenable,
  Option,
  Some,
  None,
}

-- A head element plus a (possibly empty) tail.  Never empty.
public export data NonEmpty a = NECons a (List a)

-- ---------------------------------------------------------------------------
-- Construction & conversion
-- ---------------------------------------------------------------------------

{- | A `NonEmpty` holding exactly one element.

   > toList (singleton 9)
   [9]
   > head (singleton 9)
   9 -}
export singleton : a -> NonEmpty a
singleton x = NECons x []

{- | Build a `NonEmpty` from a plain list, or `None` if the list is empty.
   Inverse of `toList` for non-empty inputs.

   > fromList [1, 2, 3] == Some (NECons 1 [2, 3])
   True
   > fromList ([] : List Int)
   None -}
export fromList : List a -> Option (NonEmpty a)
fromList [] = None
fromList (x::rest) = Some (NECons x rest)

-- ---------------------------------------------------------------------------
-- Total accessors — the point of the module: these return `a`, never `Option`.
-- ---------------------------------------------------------------------------

{- | The first element.  Total (a `NonEmpty` always has one).

   > head (NECons 7 [8, 9])
   7 -}
export head : NonEmpty a -> a
head (NECons x _) = x

{- | The largest element.  Total.

   > maximum (NECons 3 [1, 4, 1, 5])
   5 -}
export maximum : Ord a => NonEmpty a -> a
maximum (NECons x xs) = fold (acc y => max y acc) x xs

{- | The smallest element.  Total.

   > minimum (NECons 3 [1, 4, 1, 5])
   1 -}
export minimum : Ord a => NonEmpty a -> a
minimum (NECons x xs) = fold (acc y => min y acc) x xs

-- ---------------------------------------------------------------------------
-- Instances
-- ---------------------------------------------------------------------------

{- | Map over every element, preserving non-emptiness.

   > toList (map (n => n * 2) (NECons 1 [2, 3]))
   [2, 4, 6] -}
export impl Mappable NonEmpty where
  map f (NECons x xs) = NECons (f x) (map f xs)

{- | Fold over every element (head first).  `toList` recovers the plain list.

   > fold (acc y => acc + y) 0 (NECons 1 [2, 3])
   6
   > toList (NECons 1 [2, 3])
   [1, 2, 3] -}
export impl Foldable NonEmpty where
  fold f z (NECons x xs) = fold f (f z x) xs
  foldRight f z (NECons x xs) = foldRight f (foldRight f z xs) [x]
  toList (NECons x xs) = x::xs
  isEmpty _ = False
  length (NECons _ xs) = 1 + length xs

export impl Traversable NonEmpty where
  traverse f (NECons x xs) = andThen (f x) (y => map (NECons y) (traverse f xs))

{- | Append concatenates: the head of the left operand, then everything else.

   > toList (append (NECons 1 [2]) (NECons 3 [4]))
   [1, 2, 3, 4] -}
export impl Semigroup (NonEmpty a) where
  append (NECons x xs) other = NECons x (xs ++ toList other)

export impl Eq (NonEmpty a) requires Eq a where
  eq (NECons x xs) (NECons y ys) = eq x y && eq xs ys

export impl Debug (NonEmpty a) requires Debug a where
  debug ne = "NonEmpty \{debug (toList ne)}"

{- | Human-facing rendering (backs `println` and `\{}` interpolation).

   > display (NECons 1 [2, 3])
   "NonEmpty [1, 2, 3]" -}
export impl Display (NonEmpty a) requires Display a where
  display ne = "NonEmpty \{toList ne}"

-- ---------------------------------------------------------------------------
-- Properties
-- ---------------------------------------------------------------------------

prop "singleton has one element" (x : Int) = eq (toList (singleton x)) [x]

prop "head is the first element" (x : Int) (xs : List Int) =
  head (NECons x xs) == x

prop "fromList . toList round-trips" (x : Int) (xs : List Int) =
  eq (fromList (toList (NECons x xs))) (Some (NECons x xs))
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Mappable" false) (mem "Foldable" false) (mem "Traversable" false) (mem "Semigroup" false) (mem "Applicative" false) (mem "Thenable" false) (mem "Option" false) (mem "Some" false) (mem "None" false))))
(DData Public "NonEmpty" ("a") ((variant "NECons" (ConPos (TyVar "a") (TyApp (TyCon "List") (TyVar "a"))))) ())
(DTypeSig true "singleton" (TyFun (TyVar "a") (TyApp (TyCon "NonEmpty") (TyVar "a"))))
(DFunDef false "singleton" ((PVar "x")) (EApp (EApp (EVar "NECons") (EVar "x")) (EListLit)))
(DTypeSig true "fromList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyApp (TyCon "NonEmpty") (TyVar "a")))))
(DFunDef false "fromList" ((PList)) (EVar "None"))
(DFunDef false "fromList" ((PCons (PVar "x") (PVar "rest"))) (EApp (EVar "Some") (EApp (EApp (EVar "NECons") (EVar "x")) (EVar "rest"))))
(DTypeSig true "head" (TyFun (TyApp (TyCon "NonEmpty") (TyVar "a")) (TyVar "a")))
(DFunDef false "head" ((PCon "NECons" (PVar "x") PWild)) (EVar "x"))
(DTypeSig true "maximum" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "NonEmpty") (TyVar "a")) (TyVar "a"))))
(DFunDef false "maximum" ((PCon "NECons" (PVar "x") (PVar "xs"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "y")) (EApp (EApp (EVar "max") (EVar "y")) (EVar "acc")))) (EVar "x")) (EVar "xs")))
(DTypeSig true "minimum" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "NonEmpty") (TyVar "a")) (TyVar "a"))))
(DFunDef false "minimum" ((PCon "NECons" (PVar "x") (PVar "xs"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "y")) (EApp (EApp (EVar "min") (EVar "y")) (EVar "acc")))) (EVar "x")) (EVar "xs")))
(DImpl true "Mappable" ((TyCon "NonEmpty")) () ((im "map" ((PVar "f") (PCon "NECons" (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "NECons") (EApp (EVar "f") (EVar "x"))) (EApp (EApp (EVar "map") (EVar "f")) (EVar "xs"))))))
(DImpl true "Foldable" ((TyCon "NonEmpty")) () ((im "fold" ((PVar "f") (PVar "z") (PCon "NECons" (PVar "x") (PVar "xs"))) (EApp (EApp (EApp (EVar "fold") (EVar "f")) (EApp (EApp (EVar "f") (EVar "z")) (EVar "x"))) (EVar "xs"))) (im "foldRight" ((PVar "f") (PVar "z") (PCon "NECons" (PVar "x") (PVar "xs"))) (EApp (EApp (EApp (EVar "foldRight") (EVar "f")) (EApp (EApp (EApp (EVar "foldRight") (EVar "f")) (EVar "z")) (EVar "xs"))) (EListLit (EVar "x")))) (im "toList" ((PCon "NECons" (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EVar "xs"))) (im "isEmpty" (PWild) (EVar "False")) (im "length" ((PCon "NECons" PWild (PVar "xs"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "length") (EVar "xs"))))))
(DImpl true "Traversable" ((TyCon "NonEmpty")) () ((im "traverse" ((PVar "f") (PCon "NECons" (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "andThen") (EApp (EVar "f") (EVar "x"))) (ELam ((PVar "y")) (EApp (EApp (EVar "map") (EApp (EVar "NECons") (EVar "y"))) (EApp (EApp (EVar "traverse") (EVar "f")) (EVar "xs"))))))))
(DImpl true "Semigroup" ((TyApp (TyCon "NonEmpty") (TyVar "a"))) () ((im "append" ((PCon "NECons" (PVar "x") (PVar "xs")) (PVar "other")) (EApp (EApp (EVar "NECons") (EVar "x")) (EBinOp "++" (EVar "xs") (EApp (EVar "toList") (EVar "other")))))))
(DImpl true "Eq" ((TyApp (TyCon "NonEmpty") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "NECons" (PVar "x") (PVar "xs")) (PCon "NECons" (PVar "y") (PVar "ys"))) (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "x")) (EVar "y")) (EApp (EApp (EVar "eq") (EVar "xs")) (EVar "ys"))))))
(DImpl true "Debug" ((TyApp (TyCon "NonEmpty") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "ne")) (EBinOp "++" (EBinOp "++" (ELit (LString "NonEmpty ")) (EApp (EVar "display") (EApp (EVar "debug") (EApp (EVar "toList") (EVar "ne"))))) (ELit (LString ""))))))
(DImpl true "Display" ((TyApp (TyCon "NonEmpty") (TyVar "a"))) ((req "Display" ((TyVar "a")))) ((im "display" ((PVar "ne")) (EBinOp "++" (EBinOp "++" (ELit (LString "NonEmpty ")) (EApp (EVar "display") (EApp (EVar "toList") (EVar "ne")))) (ELit (LString ""))))))
(DProp false "singleton has one element" ((pp "x" (TyCon "Int"))) (EApp (EApp (EVar "eq") (EApp (EVar "toList") (EApp (EVar "singleton") (EVar "x")))) (EListLit (EVar "x"))))
(DProp false "head is the first element" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EVar "head") (EApp (EApp (EVar "NECons") (EVar "x")) (EVar "xs"))) (EVar "x")))
(DProp false "fromList . toList round-trips" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "eq") (EApp (EVar "fromList") (EApp (EVar "toList") (EApp (EApp (EVar "NECons") (EVar "x")) (EVar "xs"))))) (EApp (EVar "Some") (EApp (EApp (EVar "NECons") (EVar "x")) (EVar "xs")))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Debug" false) (mem "Display" false) (mem "Mappable" false) (mem "Foldable" false) (mem "Traversable" false) (mem "Semigroup" false) (mem "Applicative" false) (mem "Thenable" false) (mem "Option" false) (mem "Some" false) (mem "None" false))))
(DData Public "NonEmpty" ("a") ((variant "NECons" (ConPos (TyVar "a") (TyApp (TyCon "List") (TyVar "a"))))) ())
(DTypeSig true "singleton" (TyFun (TyVar "a") (TyApp (TyCon "NonEmpty") (TyVar "a"))))
(DFunDef false "singleton" ((PVar "x")) (EApp (EApp (EVar "NECons") (EVar "x")) (EListLit)))
(DTypeSig true "fromList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyApp (TyCon "NonEmpty") (TyVar "a")))))
(DFunDef false "fromList" ((PList)) (EVar "None"))
(DFunDef false "fromList" ((PCons (PVar "x") (PVar "rest"))) (EApp (EVar "Some") (EApp (EApp (EVar "NECons") (EVar "x")) (EVar "rest"))))
(DTypeSig true "head" (TyFun (TyApp (TyCon "NonEmpty") (TyVar "a")) (TyVar "a")))
(DFunDef false "head" ((PCon "NECons" (PVar "x") PWild)) (EVar "x"))
(DTypeSig true "maximum" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "NonEmpty") (TyVar "a")) (TyVar "a"))))
(DFunDef false "maximum" ((PCon "NECons" (PVar "x") (PVar "xs"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "y")) (EApp (EApp (EMethodRef "max") (EVar "y")) (EVar "acc")))) (EVar "x")) (EVar "xs")))
(DTypeSig true "minimum" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "NonEmpty") (TyVar "a")) (TyVar "a"))))
(DFunDef false "minimum" ((PCon "NECons" (PVar "x") (PVar "xs"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "y")) (EApp (EApp (EMethodRef "min") (EVar "y")) (EVar "acc")))) (EVar "x")) (EVar "xs")))
(DImpl true "Mappable" ((TyCon "NonEmpty")) () ((im "map" ((PVar "f") (PCon "NECons" (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "NECons") (EApp (EVar "f") (EVar "x"))) (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "xs"))))))
(DImpl true "Foldable" ((TyCon "NonEmpty")) () ((im "fold" ((PVar "f") (PVar "z") (PCon "NECons" (PVar "x") (PVar "xs"))) (EApp (EApp (EApp (EMethodRef "fold") (EVar "f")) (EApp (EApp (EVar "f") (EVar "z")) (EVar "x"))) (EVar "xs"))) (im "foldRight" ((PVar "f") (PVar "z") (PCon "NECons" (PVar "x") (PVar "xs"))) (EApp (EApp (EApp (EMethodRef "foldRight") (EVar "f")) (EApp (EApp (EApp (EMethodRef "foldRight") (EVar "f")) (EVar "z")) (EVar "xs"))) (EListLit (EVar "x")))) (im "toList" ((PCon "NECons" (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EVar "xs"))) (im "isEmpty" (PWild) (EVar "False")) (im "length" ((PCon "NECons" PWild (PVar "xs"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EMethodRef "length") (EVar "xs"))))))
(DImpl true "Traversable" ((TyCon "NonEmpty")) () ((im "traverse" ((PVar "f") (PCon "NECons" (PVar "x") (PVar "xs"))) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "f") (EVar "x"))) (ELam ((PVar "y")) (EApp (EApp (EMethodRef "map") (EApp (EVar "NECons") (EVar "y"))) (EApp (EApp (EMethodRef "traverse") (EVar "f")) (EVar "xs"))))))))
(DImpl true "Semigroup" ((TyApp (TyCon "NonEmpty") (TyVar "a"))) () ((im "append" ((PCon "NECons" (PVar "x") (PVar "xs")) (PVar "other")) (EApp (EApp (EVar "NECons") (EVar "x")) (EBinOp "++" (EVar "xs") (EApp (EMethodRef "toList") (EVar "other")))))))
(DImpl true "Eq" ((TyApp (TyCon "NonEmpty") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "NECons" (PVar "x") (PVar "xs")) (PCon "NECons" (PVar "y") (PVar "ys"))) (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "x")) (EVar "y")) (EApp (EApp (EMethodRef "eq") (EVar "xs")) (EVar "ys"))))))
(DImpl true "Debug" ((TyApp (TyCon "NonEmpty") (TyVar "a"))) ((req "Debug" ((TyVar "a")))) ((im "debug" ((PVar "ne")) (EBinOp "++" (EBinOp "++" (ELit (LString "NonEmpty ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EApp (EMethodRef "toList") (EVar "ne"))))) (ELit (LString ""))))))
(DImpl true "Display" ((TyApp (TyCon "NonEmpty") (TyVar "a"))) ((req "Display" ((TyVar "a")))) ((im "display" ((PVar "ne")) (EBinOp "++" (EBinOp "++" (ELit (LString "NonEmpty ")) (EApp (EMethodRef "display") (EApp (EMethodRef "toList") (EVar "ne")))) (ELit (LString ""))))))
(DProp false "singleton has one element" ((pp "x" (TyCon "Int"))) (EApp (EApp (EMethodRef "eq") (EApp (EMethodRef "toList") (EApp (EVar "singleton") (EVar "x")))) (EListLit (EVar "x"))))
(DProp false "head is the first element" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EBinOp "==" (EApp (EVar "head") (EApp (EApp (EVar "NECons") (EVar "x")) (EVar "xs"))) (EVar "x")))
(DProp false "fromList . toList round-trips" ((pp "x" (TyCon "Int")) (pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EMethodRef "eq") (EApp (EVar "fromList") (EApp (EMethodRef "toList") (EApp (EApp (EVar "NECons") (EVar "x")) (EVar "xs"))))) (EApp (EVar "Some") (EApp (EApp (EVar "NECons") (EVar "x")) (EVar "xs")))))
