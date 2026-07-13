# META
source_lines=4
stages=DESUGAR,MARK
# SOURCE
r = identity
  5

main = println r
# DESUGAR
(DFunDef false "r" () (EApp (EVar "identity") (ELit (LInt 5))))
(DFunDef false "main" () (EApp (EVar "println") (EVar "r")))
# MARK
(DFunDef false "r" () (EApp (EVar "identity") (ELit (LInt 5))))
(DFunDef false "main" () (EApp (EDictApp "println") (EVar "r")))
