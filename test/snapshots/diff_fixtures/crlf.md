# META
source_lines=4
stages=DESUGAR,MARK
# SOURCE
x = 1
y = 2

main = println (x + y)
# DESUGAR
(DFunDef false "x" () (ELit (LInt 1)))
(DFunDef false "y" () (ELit (LInt 2)))
(DFunDef false "main" () (EApp (EVar "println") (EBinOp "+" (EVar "x") (EVar "y"))))
# MARK
(DFunDef false "x" () (ELit (LInt 1)))
(DFunDef false "y" () (ELit (LInt 2)))
(DFunDef false "main" () (EApp (EDictApp "println") (EBinOp "+" (EVar "x") (EVar "y"))))
