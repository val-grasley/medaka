# META
source_lines=4
stages=DESUGAR,MARK
# SOURCE
wrap x y = x
  :: y

main = println (wrap 1 [2, 3])
# DESUGAR
(DFunDef false "wrap" ((PVar "x") (PVar "y")) (EBinOp "::" (EVar "x") (EVar "y")))
(DFunDef false "main" () (EApp (EVar "println") (EApp (EApp (EVar "wrap") (ELit (LInt 1))) (EListLit (ELit (LInt 2)) (ELit (LInt 3))))))
# MARK
(DFunDef false "wrap" ((PVar "x") (PVar "y")) (EBinOp "::" (EVar "x") (EVar "y")))
(DFunDef false "main" () (EApp (EDictApp "println") (EApp (EApp (EVar "wrap") (ELit (LInt 1))) (EListLit (ELit (LInt 2)) (ELit (LInt 3))))))
