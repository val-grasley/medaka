# META
source_lines=3
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
getX p = p.x
deep p = p.a.b.c
combine p q = p.x + q.y
# PARSE
(DFunDef false "getX" ((PVar "p")) (EFieldAccess (EVar "p") "x"))
(DFunDef false "deep" ((PVar "p")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "p") "a") "b") "c"))
(DFunDef false "combine" ((PVar "p") (PVar "q")) (EBinOp "+" (EFieldAccess (EVar "p") "x") (EFieldAccess (EVar "q") "y")))
# PRINTER
getX p = p.x
deep p = p.a.b.c
combine p q = p.x + q.y
# DESUGAR
(DFunDef false "getX" ((PVar "p")) (EFieldAccess (EVar "p") "x"))
(DFunDef false "deep" ((PVar "p")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "p") "a") "b") "c"))
(DFunDef false "combine" ((PVar "p") (PVar "q")) (EBinOp "+" (EFieldAccess (EVar "p") "x") (EFieldAccess (EVar "q") "y")))
# MARK
(DFunDef false "getX" ((PVar "p")) (EFieldAccess (EVar "p") "x"))
(DFunDef false "deep" ((PVar "p")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "p") "a") "b") "c"))
(DFunDef false "combine" ((PVar "p") (PVar "q")) (EBinOp "+" (EFieldAccess (EVar "p") "x") (EFieldAccess (EVar "q") "y")))
