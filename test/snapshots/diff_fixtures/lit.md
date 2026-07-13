# META
source_lines=8
stages=DESUGAR,MARK
# SOURCE
main : <IO> Unit
main =
  println 42
  println (2 + 3)
  println (10 - 4)
  println (3 * 7)
  println True
  println False
# DESUGAR
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (ELit (LInt 42)))) (DoExpr (EApp (EVar "println") (EBinOp "+" (ELit (LInt 2)) (ELit (LInt 3))))) (DoExpr (EApp (EVar "println") (EBinOp "-" (ELit (LInt 10)) (ELit (LInt 4))))) (DoExpr (EApp (EVar "println") (EBinOp "*" (ELit (LInt 3)) (ELit (LInt 7))))) (DoExpr (EApp (EVar "println") (EVar "True"))) (DoExpr (EApp (EVar "println") (EVar "False")))))
# MARK
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (ELit (LInt 42)))) (DoExpr (EApp (EDictApp "println") (EBinOp "+" (ELit (LInt 2)) (ELit (LInt 3))))) (DoExpr (EApp (EDictApp "println") (EBinOp "-" (ELit (LInt 10)) (ELit (LInt 4))))) (DoExpr (EApp (EDictApp "println") (EBinOp "*" (ELit (LInt 3)) (ELit (LInt 7))))) (DoExpr (EApp (EDictApp "println") (EVar "True"))) (DoExpr (EApp (EDictApp "println") (EVar "False")))))
