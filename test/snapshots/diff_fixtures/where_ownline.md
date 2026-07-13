# META
source_lines=5
stages=DESUGAR,MARK
# SOURCE
f x = go x
  where
    go n = n + 1

main = println (f 5)
# DESUGAR
(DFunDef false "f" ((PVar "x")) (ELetGroup ((lgb "go" (clause ((PVar "n")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "go") (EVar "x"))))
(DFunDef false "main" () (EApp (EVar "println") (EApp (EVar "f") (ELit (LInt 5)))))
# MARK
(DFunDef false "f" ((PVar "x")) (ELetGroup ((lgb "go" (clause ((PVar "n")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "go") (EVar "x"))))
(DFunDef false "main" () (EApp (EDictApp "println") (EApp (EVar "f") (ELit (LInt 5)))))
