# META
source_lines=10
stages=DESUGAR,MARK
# SOURCE
double x = x * 2
isEven x = x % 2 == 0

sumList xs = fold (acc x => acc + x) 0 xs

main : <IO> Unit
main =
  println (map double [1, 2, 3, 4, 5])
  println (filter isEven [1, 2, 3, 4, 5, 6])
  println (sumList (map double [1, 2, 3]))
# DESUGAR
(DFunDef false "double" ((PVar "x")) (EBinOp "*" (EVar "x") (ELit (LInt 2))))
(DFunDef false "isEven" ((PVar "x")) (EBinOp "==" (EBinOp "%" (EVar "x") (ELit (LInt 2))) (ELit (LInt 0))))
(DFunDef false "sumList" ((PVar "xs")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "+" (EVar "acc") (EVar "x")))) (ELit (LInt 0))) (EVar "xs")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EApp (EVar "map") (EVar "double")) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)))))) (DoExpr (EApp (EVar "println") (EApp (EApp (EVar "filter") (EVar "isEven")) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)) (ELit (LInt 6)))))) (DoExpr (EApp (EVar "println") (EApp (EVar "sumList") (EApp (EApp (EVar "map") (EVar "double")) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))))))))
# MARK
(DFunDef false "double" ((PVar "x")) (EBinOp "*" (EVar "x") (ELit (LInt 2))))
(DFunDef false "isEven" ((PVar "x")) (EBinOp "==" (EBinOp "%" (EVar "x") (ELit (LInt 2))) (ELit (LInt 0))))
(DFunDef false "sumList" ((PVar "xs")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "+" (EVar "acc") (EVar "x")))) (ELit (LInt 0))) (EVar "xs")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EApp (EMethodRef "map") (EVar "double")) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)))))) (DoExpr (EApp (EDictApp "println") (EApp (EApp (EMethodRef "filter") (EVar "isEven")) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)) (ELit (LInt 6)))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "sumList") (EApp (EApp (EMethodRef "map") (EVar "double")) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))))))))
