# META
source_lines=25
stages=DESUGAR,MARK
# SOURCE
{- option.mdk — the `Option` eliminator.

   `Option a` (`Some`/`None`) itself lives in `core.mdk` (the implicit
   prelude), alongside `isSome`/`isNone`/`fromOption`/`toResult`/`fromResult`.
   This module adds the one thing core doesn't: the fold-both-cases
   eliminator, named `option` (Haskell calls it `maybe`, but Medaka names a
   thing for what it eliminates, not for category theory — it matches the
   `Option` type). -}

{- | Eliminate an `Option` by supplying a default for `None` and a function
   for `Some`.

   > option 0 (x => x + 1) (Some 41)
   42
   > option 0 (x => x + 1) None
   0 -}
export option : b -> (a -> <e> b) -> Option a -> <e> b
option dflt f (Some x) = f x
option dflt _ None = dflt

prop "option dflt f (Some x) == f x" (x : Int) (d : Int) =
  option d (n => n * 2) (Some x) == x * 2

prop "option dflt f None == dflt" (d : Int) =
  option d (n => n * 2) (None : Option Int) == d
# DESUGAR
(DTypeSig true "option" (TyFun (TyVar "b") (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "option" ((PVar "dflt") (PVar "f") (PCon "Some" (PVar "x"))) (EApp (EVar "f") (EVar "x")))
(DFunDef false "option" ((PVar "dflt") PWild (PCon "None")) (EVar "dflt"))
(DProp false "option dflt f (Some x) == f x" ((pp "x" (TyCon "Int")) (pp "d" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EApp (EVar "option") (EVar "d")) (ELam ((PVar "n")) (EBinOp "*" (EVar "n") (ELit (LInt 2))))) (EApp (EVar "Some") (EVar "x"))) (EBinOp "*" (EVar "x") (ELit (LInt 2)))))
(DProp false "option dflt f None == dflt" ((pp "d" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EApp (EVar "option") (EVar "d")) (ELam ((PVar "n")) (EBinOp "*" (EVar "n") (ELit (LInt 2))))) (EAnnot (EVar "None") (TyApp (TyCon "Option") (TyCon "Int")))) (EVar "d")))
# MARK
(DTypeSig true "option" (TyFun (TyVar "b") (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e") (TyVar "b"))) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyEffect () (Some "e") (TyVar "b"))))))
(DFunDef false "option" ((PVar "dflt") (PVar "f") (PCon "Some" (PVar "x"))) (EApp (EVar "f") (EVar "x")))
(DFunDef false "option" ((PVar "dflt") PWild (PCon "None")) (EVar "dflt"))
(DProp false "option dflt f (Some x) == f x" ((pp "x" (TyCon "Int")) (pp "d" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EApp (EVar "option") (EVar "d")) (ELam ((PVar "n")) (EBinOp "*" (EVar "n") (ELit (LInt 2))))) (EApp (EVar "Some") (EVar "x"))) (EBinOp "*" (EVar "x") (ELit (LInt 2)))))
(DProp false "option dflt f None == dflt" ((pp "d" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EApp (EVar "option") (EVar "d")) (ELam ((PVar "n")) (EBinOp "*" (EVar "n") (ELit (LInt 2))))) (EAnnot (EVar "None") (TyApp (TyCon "Option") (TyCon "Int")))) (EVar "d")))
