# META
source_lines=24
stages=DESUGAR,MARK
# SOURCE
{- result.mdk — the `Result` eliminator.

   `Result e a` (`Ok`/`Err`) itself lives in `core.mdk` (the implicit
   prelude), alongside `isOk`/`isErr`/`fromResultOr`/`mapErr`.  This module
   adds the one thing core doesn't: the fold-both-cases eliminator, named
   `result` (Haskell calls it `either`, but Medaka names a thing for what it
   eliminates, not for category theory — it matches the `Result` type). -}

{- | Eliminate a `Result` by supplying a handler for `Err` and a handler for
   `Ok`.

   > result (e => 0) (x => x + 1) (Ok 41)
   42
   > result (e => e) (x => x + 1) (Err 7)
   7 -}
export result : (e -> <eff> c) -> (a -> <eff> c) -> Result e a -> <eff> c
result onErr onOk (Ok x) = onOk x
result onErr onOk (Err e) = onErr e

prop "result onErr onOk (Ok x) == onOk x" (x : Int) =
  result (e => 0) (n => n * 2) (Ok x) == x * 2

prop "result onErr onOk (Err e) == onErr e" (e : Int) =
  result (n => n * 2) (n => 0) (Err e : Result Int Int) == e * 2
# DESUGAR
(DTypeSig true "result" (TyFun (TyFun (TyVar "e") (TyEffect () (Some "eff") (TyVar "c"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "eff") (TyVar "c"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyEffect () (Some "eff") (TyVar "c"))))))
(DFunDef false "result" ((PVar "onErr") (PVar "onOk") (PCon "Ok" (PVar "x"))) (EApp (EVar "onOk") (EVar "x")))
(DFunDef false "result" ((PVar "onErr") (PVar "onOk") (PCon "Err" (PVar "e"))) (EApp (EVar "onErr") (EVar "e")))
(DProp false "result onErr onOk (Ok x) == onOk x" ((pp "x" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EApp (EVar "result") (ELam ((PVar "e")) (ELit (LInt 0)))) (ELam ((PVar "n")) (EBinOp "*" (EVar "n") (ELit (LInt 2))))) (EApp (EVar "Ok") (EVar "x"))) (EBinOp "*" (EVar "x") (ELit (LInt 2)))))
(DProp false "result onErr onOk (Err e) == onErr e" ((pp "e" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EApp (EVar "result") (ELam ((PVar "n")) (EBinOp "*" (EVar "n") (ELit (LInt 2))))) (ELam ((PVar "n")) (ELit (LInt 0)))) (EAnnot (EApp (EVar "Err") (EVar "e")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int")))) (EBinOp "*" (EVar "e") (ELit (LInt 2)))))
# MARK
(DTypeSig true "result" (TyFun (TyFun (TyVar "e") (TyEffect () (Some "eff") (TyVar "c"))) (TyFun (TyFun (TyVar "a") (TyEffect () (Some "eff") (TyVar "c"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyEffect () (Some "eff") (TyVar "c"))))))
(DFunDef false "result" ((PVar "onErr") (PVar "onOk") (PCon "Ok" (PVar "x"))) (EApp (EVar "onOk") (EVar "x")))
(DFunDef false "result" ((PVar "onErr") (PVar "onOk") (PCon "Err" (PVar "e"))) (EApp (EVar "onErr") (EVar "e")))
(DProp false "result onErr onOk (Ok x) == onOk x" ((pp "x" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EApp (EVar "result") (ELam ((PVar "e")) (ELit (LInt 0)))) (ELam ((PVar "n")) (EBinOp "*" (EVar "n") (ELit (LInt 2))))) (EApp (EVar "Ok") (EVar "x"))) (EBinOp "*" (EVar "x") (ELit (LInt 2)))))
(DProp false "result onErr onOk (Err e) == onErr e" ((pp "e" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EApp (EVar "result") (ELam ((PVar "n")) (EBinOp "*" (EVar "n") (ELit (LInt 2))))) (ELam ((PVar "n")) (ELit (LInt 0)))) (EAnnot (EApp (EVar "Err") (EVar "e")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int")))) (EBinOp "*" (EVar "e") (ELit (LInt 2)))))
