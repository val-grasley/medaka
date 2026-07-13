# META
source_lines=11
stages=DESUGAR,MARK
# SOURCE
sum xs = fold (acc x => acc + x) 0 xs

myLength xs = fold (acc _ => acc + 1) 0 xs

main : <IO> Unit
main =
  let xs = [1, 2, 3, 4, 5]
  println (sum xs)
  println (myLength xs)
  println (sum ([] : List Int))
  println ([1, 2] ++ [3, 4])
# DESUGAR
(DFunDef false "sum" ((PVar "xs")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "+" (EVar "acc") (EVar "x")))) (ELit (LInt 0))) (EVar "xs")))
(DFunDef false "myLength" ((PVar "xs")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") PWild) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))) (ELit (LInt 0))) (EVar "xs")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "xs") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)))) (DoExpr (EApp (EVar "println") (EApp (EVar "sum") (EVar "xs")))) (DoExpr (EApp (EVar "println") (EApp (EVar "myLength") (EVar "xs")))) (DoExpr (EApp (EVar "println") (EApp (EVar "sum") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))))) (DoExpr (EApp (EVar "println") (EBinOp "++" (EListLit (ELit (LInt 1)) (ELit (LInt 2))) (EListLit (ELit (LInt 3)) (ELit (LInt 4))))))))
# MARK
(DFunDef false "sum" ((PVar "xs")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "+" (EVar "acc") (EVar "x")))) (ELit (LInt 0))) (EVar "xs")))
(DFunDef false "myLength" ((PVar "xs")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") PWild) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))) (ELit (LInt 0))) (EVar "xs")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "xs") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "sum") (EVar "xs")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "myLength") (EVar "xs")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "sum") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))))) (DoExpr (EApp (EDictApp "println") (EBinOp "++" (EListLit (ELit (LInt 1)) (ELit (LInt 2))) (EListLit (ELit (LInt 3)) (ELit (LInt 4))))))))
