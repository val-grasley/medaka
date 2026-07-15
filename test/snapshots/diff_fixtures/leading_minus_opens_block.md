# META
source_lines=5
stages=TOKENS,DESUGAR,MARK
# SOURCE
x = 5
y =
  - x

main = println y
# TOKENS
IDENT "x"
EQUAL
INT 5
NEWLINE
IDENT "y"
EQUAL
INDENT
MINUS
IDENT "x"
NEWLINE
DEDENT
NEWLINE
IDENT "main"
EQUAL
IDENT "println"
IDENT "y"
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "x" () (ELit (LInt 5)))
(DFunDef false "y" () (EUnOp "-" (EVar "x")))
(DFunDef false "main" () (EApp (EVar "println") (EVar "y")))
# MARK
(DFunDef false "x" () (ELit (LInt 5)))
(DFunDef false "y" () (EUnOp "-" (EVar "x")))
(DFunDef false "main" () (EApp (EDictApp "println") (EVar "y")))
