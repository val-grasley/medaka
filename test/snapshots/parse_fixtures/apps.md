# META
source_lines=4
stages=PARSE,DESUGAR,MARK
# SOURCE
a = f x y
b = twice g z
c = f (g x) (h y)
compose f g x = f (g x)
# PARSE
(DFunDef false "a" () (EApp (EApp (EVar "f") (EVar "x")) (EVar "y")))
(DFunDef false "b" () (EApp (EApp (EVar "twice") (EVar "g")) (EVar "z")))
(DFunDef false "c" () (EApp (EApp (EVar "f") (EApp (EVar "g") (EVar "x"))) (EApp (EVar "h") (EVar "y"))))
(DFunDef false "compose" ((PVar "f") (PVar "g") (PVar "x")) (EApp (EVar "f") (EApp (EVar "g") (EVar "x"))))
# DESUGAR
(DFunDef false "a" () (EApp (EApp (EVar "f") (EVar "x")) (EVar "y")))
(DFunDef false "b" () (EApp (EApp (EVar "twice") (EVar "g")) (EVar "z")))
(DFunDef false "c" () (EApp (EApp (EVar "f") (EApp (EVar "g") (EVar "x"))) (EApp (EVar "h") (EVar "y"))))
(DFunDef false "compose" ((PVar "f") (PVar "g") (PVar "x")) (EApp (EVar "f") (EApp (EVar "g") (EVar "x"))))
# MARK
(DFunDef false "a" () (EApp (EApp (EVar "f") (EVar "x")) (EVar "y")))
(DFunDef false "b" () (EApp (EApp (EVar "twice") (EVar "g")) (EVar "z")))
(DFunDef false "c" () (EApp (EApp (EVar "f") (EApp (EVar "g") (EVar "x"))) (EApp (EVar "h") (EVar "y"))))
(DFunDef false "compose" ((PVar "f") (PVar "g") (PVar "x")) (EApp (EVar "f") (EApp (EVar "g") (EVar "x"))))
