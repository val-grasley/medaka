# META
source_lines=5
stages=DESUGAR,MARK
# SOURCE
r = (1
  + 2
  * 3)

main = println r
# DESUGAR
(DFunDef false "r" () (EBinOp "+" (ELit (LInt 1)) (EBinOp "*" (ELit (LInt 2)) (ELit (LInt 3)))))
(DFunDef false "main" () (EApp (EVar "println") (EVar "r")))
# MARK
(DFunDef false "r" () (EBinOp "+" (ELit (LInt 1)) (EBinOp "*" (ELit (LInt 2)) (ELit (LInt 3)))))
(DFunDef false "main" () (EApp (EDictApp "println") (EVar "r")))
