# META
source_lines=4
stages=DESUGAR,MARK
# SOURCE
r = 1 +
  2

main = println r
# DESUGAR
(DFunDef false "r" () (EBinOp "+" (ELit (LInt 1)) (ELit (LInt 2))))
(DFunDef false "main" () (EApp (EVar "println") (EVar "r")))
# MARK
(DFunDef false "r" () (EBinOp "+" (ELit (LInt 1)) (ELit (LInt 2))))
(DFunDef false "main" () (EApp (EDictApp "println") (EVar "r")))
