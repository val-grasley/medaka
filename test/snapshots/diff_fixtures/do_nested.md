# META
source_lines=3
stages=DESUGAR,MARK
# SOURCE
main = do
  let x = 1
  println x
# DESUGAR
(DFunDef false "main" () (ELet false (PVar "x") (ELit (LInt 1)) (EApp (EVar "println") (EVar "x"))))
# MARK
(DFunDef false "main" () (ELet false (PVar "x") (ELit (LInt 1)) (EApp (EDictApp "println") (EVar "x"))))
