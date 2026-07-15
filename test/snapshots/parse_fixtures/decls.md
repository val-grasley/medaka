# META
source_lines=6
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
identity x = x
add x y = x + y
const x y = x
apply f x = f x

answer = 42
# PARSE
(DFunDef false "identity" ((PVar "x")) (EVar "x"))
(DFunDef false "add" ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))
(DFunDef false "const" ((PVar "x") (PVar "y")) (EVar "x"))
(DFunDef false "apply" ((PVar "f") (PVar "x")) (EApp (EVar "f") (EVar "x")))
(DFunDef false "answer" () (ELit (LInt 42)))
# PRINTER
identity x = x
add x y = x + y
const x y = x
apply f x = f x
answer = 42
# DESUGAR
(DFunDef false "identity" ((PVar "x")) (EVar "x"))
(DFunDef false "add" ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))
(DFunDef false "const" ((PVar "x") (PVar "y")) (EVar "x"))
(DFunDef false "apply" ((PVar "f") (PVar "x")) (EApp (EVar "f") (EVar "x")))
(DFunDef false "answer" () (ELit (LInt 42)))
# MARK
(DFunDef false "identity" ((PVar "x")) (EVar "x"))
(DFunDef false "add#shadow" ((PVar "x") (PVar "y")) (EBinOp "+" (EVar "x") (EVar "y")))
(DFunDef false "const" ((PVar "x") (PVar "y")) (EVar "x"))
(DFunDef false "apply" ((PVar "f") (PVar "x")) (EApp (EVar "f") (EVar "x")))
(DFunDef false "answer" () (ELit (LInt 42)))
