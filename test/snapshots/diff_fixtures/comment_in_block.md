# META
source_lines=5
stages=DESUGAR,MARK
# SOURCE
f x =
  -- comment inside = block
  x + 1

main = println (f 3)
# DESUGAR
(DFunDef false "f" ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))
(DFunDef false "main" () (EApp (EVar "println") (EApp (EVar "f") (ELit (LInt 3)))))
# MARK
(DFunDef false "f" ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))
(DFunDef false "main" () (EApp (EDictApp "println") (EApp (EVar "f") (ELit (LInt 3)))))
