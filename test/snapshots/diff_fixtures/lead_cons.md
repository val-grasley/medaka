# META
source_lines=4
stages=DESUGAR,MARK
# SOURCE
r = [1, 2]
  :: [[3, 4]]

main = println r
# DESUGAR
(DFunDef false "r" () (EBinOp "::" (EListLit (ELit (LInt 1)) (ELit (LInt 2))) (EListLit (EListLit (ELit (LInt 3)) (ELit (LInt 4))))))
(DFunDef false "main" () (EApp (EVar "println") (EVar "r")))
# MARK
(DFunDef false "r" () (EBinOp "::" (EListLit (ELit (LInt 1)) (ELit (LInt 2))) (EListLit (EListLit (ELit (LInt 3)) (ELit (LInt 4))))))
(DFunDef false "main" () (EApp (EDictApp "println") (EVar "r")))
