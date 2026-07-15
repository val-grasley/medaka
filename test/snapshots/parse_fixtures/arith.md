# META
source_lines=6
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
a = 1 + 2 + 3
b = 1 + 2 * 3
c = 10 - 4 - 1
d = 2 * 3 + 4 * 5
e = g 1 - h 2
f = 100 / 5 / 2
# PARSE
(DFunDef false "a" () (EBinOp "+" (EBinOp "+" (ELit (LInt 1)) (ELit (LInt 2))) (ELit (LInt 3))))
(DFunDef false "b" () (EBinOp "+" (ELit (LInt 1)) (EBinOp "*" (ELit (LInt 2)) (ELit (LInt 3)))))
(DFunDef false "c" () (EBinOp "-" (EBinOp "-" (ELit (LInt 10)) (ELit (LInt 4))) (ELit (LInt 1))))
(DFunDef false "d" () (EBinOp "+" (EBinOp "*" (ELit (LInt 2)) (ELit (LInt 3))) (EBinOp "*" (ELit (LInt 4)) (ELit (LInt 5)))))
(DFunDef false "e" () (EBinOp "-" (EApp (EVar "g") (ELit (LInt 1))) (EApp (EVar "h") (ELit (LInt 2)))))
(DFunDef false "f" () (EBinOp "/" (EBinOp "/" (ELit (LInt 100)) (ELit (LInt 5))) (ELit (LInt 2))))
# PRINTER
a = 1 + 2 + 3
b = 1 + 2 * 3
c = 10 - 4 - 1
d = 2 * 3 + 4 * 5
e = g 1 - h 2
f = 100 / 5 / 2
# DESUGAR
(DFunDef false "a" () (EBinOp "+" (EBinOp "+" (ELit (LInt 1)) (ELit (LInt 2))) (ELit (LInt 3))))
(DFunDef false "b" () (EBinOp "+" (ELit (LInt 1)) (EBinOp "*" (ELit (LInt 2)) (ELit (LInt 3)))))
(DFunDef false "c" () (EBinOp "-" (EBinOp "-" (ELit (LInt 10)) (ELit (LInt 4))) (ELit (LInt 1))))
(DFunDef false "d" () (EBinOp "+" (EBinOp "*" (ELit (LInt 2)) (ELit (LInt 3))) (EBinOp "*" (ELit (LInt 4)) (ELit (LInt 5)))))
(DFunDef false "e" () (EBinOp "-" (EApp (EVar "g") (ELit (LInt 1))) (EApp (EVar "h") (ELit (LInt 2)))))
(DFunDef false "f" () (EBinOp "/" (EBinOp "/" (ELit (LInt 100)) (ELit (LInt 5))) (ELit (LInt 2))))
# MARK
(DFunDef false "a" () (EBinOp "+" (EBinOp "+" (ELit (LInt 1)) (ELit (LInt 2))) (ELit (LInt 3))))
(DFunDef false "b" () (EBinOp "+" (ELit (LInt 1)) (EBinOp "*" (ELit (LInt 2)) (ELit (LInt 3)))))
(DFunDef false "c" () (EBinOp "-" (EBinOp "-" (ELit (LInt 10)) (ELit (LInt 4))) (ELit (LInt 1))))
(DFunDef false "d" () (EBinOp "+" (EBinOp "*" (ELit (LInt 2)) (ELit (LInt 3))) (EBinOp "*" (ELit (LInt 4)) (ELit (LInt 5)))))
(DFunDef false "e" () (EBinOp "-" (EApp (EVar "g") (ELit (LInt 1))) (EApp (EVar "h") (ELit (LInt 2)))))
(DFunDef false "f" () (EBinOp "/" (EBinOp "/" (ELit (LInt 100)) (ELit (LInt 5))) (ELit (LInt 2))))
