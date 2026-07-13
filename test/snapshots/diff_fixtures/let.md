# META
source_lines=7
stages=DESUGAR,MARK
# SOURCE
main : <IO> Unit
main =
  let x = 10
  let y = 20
  let sum = x + y
  println sum
  println (x * y)
# DESUGAR
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "x") (ELit (LInt 10))) (DoLet false false (PVar "y") (ELit (LInt 20))) (DoLet false false (PVar "sum") (EBinOp "+" (EVar "x") (EVar "y"))) (DoExpr (EApp (EVar "println") (EVar "sum"))) (DoExpr (EApp (EVar "println") (EBinOp "*" (EVar "x") (EVar "y"))))))
# MARK
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "x") (ELit (LInt 10))) (DoLet false false (PVar "y") (ELit (LInt 20))) (DoLet false false (PVar "sum") (EBinOp "+" (EVar "x") (EVar "y"))) (DoExpr (EApp (EDictApp "println") (EDictApp "sum"))) (DoExpr (EApp (EDictApp "println") (EBinOp "*" (EVar "x") (EVar "y"))))))
