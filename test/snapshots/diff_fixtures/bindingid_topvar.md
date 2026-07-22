# META
source_lines=5
stages=TOKENS,DESUGAR,MARK
# SOURCE
g x = x + 1

h = g 2

main = println h
# TOKENS
IDENT "g"
IDENT "x"
EQUAL
IDENT "x"
PLUS
INT 1
NEWLINE
IDENT "h"
EQUAL
IDENT "g"
INT 2
NEWLINE
IDENT "main"
EQUAL
IDENT "println"
IDENT "h"
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "g" ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))
(DFunDef false "h" () (EApp (EVar "g") (ELit (LInt 2))))
(DFunDef false "main" () (EApp (EVar "println") (EVar "h")))
# MARK
(DFunDef false "g" ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))
(DFunDef false "h" () (EApp (EVar "g") (ELit (LInt 2))))
(DFunDef false "main" () (EApp (EDictApp "println") (EVar "h")))
