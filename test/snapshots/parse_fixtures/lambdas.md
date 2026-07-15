# META
source_lines=4
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
inc = x => x + 1
add = x y => x + y
compose f g = x => f (g x)
applyTwice f = x => f (f x)
# PARSE
(DFunDef false "inc" () (ELam ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1)))))
(DFunDef false "add" () (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y"))))
(DFunDef false "compose" ((PVar "f") (PVar "g")) (ELam ((PVar "x")) (EApp (EVar "f") (EApp (EVar "g") (EVar "x")))))
(DFunDef false "applyTwice" ((PVar "f")) (ELam ((PVar "x")) (EApp (EVar "f") (EApp (EVar "f") (EVar "x")))))
# PRINTER
inc = x => x + 1
add = x y => x + y
compose f g = x => f (g x)
applyTwice f = x => f (f x)
# DESUGAR
(DFunDef false "inc" () (ELam ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1)))))
(DFunDef false "add" () (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y"))))
(DFunDef false "compose" ((PVar "f") (PVar "g")) (ELam ((PVar "x")) (EApp (EVar "f") (EApp (EVar "g") (EVar "x")))))
(DFunDef false "applyTwice" ((PVar "f")) (ELam ((PVar "x")) (EApp (EVar "f") (EApp (EVar "f") (EVar "x")))))
# MARK
(DFunDef false "inc" () (ELam ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1)))))
(DFunDef false "add#shadow" () (ELam ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y"))))
(DFunDef false "compose" ((PVar "f") (PVar "g")) (ELam ((PVar "x")) (EApp (EVar "f") (EApp (EVar "g") (EVar "x")))))
(DFunDef false "applyTwice" ((PVar "f")) (ELam ((PVar "x")) (EApp (EVar "f") (EApp (EVar "f") (EVar "x")))))
