# META
source_lines=5
stages=DESUGAR,MARK
# SOURCE
x = 5
y =
  - x

main = println y
# DESUGAR
(DFunDef false "x" () (ELit (LInt 5)))
(DFunDef false "y" () (EUnOp "-" (EVar "x")))
(DFunDef false "main" () (EApp (EVar "println") (EVar "y")))
# MARK
(DFunDef false "x" () (ELit (LInt 5)))
(DFunDef false "y" () (EUnOp "-" (EVar "x")))
(DFunDef false "main" () (EApp (EDictApp "println") (EVar "y")))
