# META
source_lines=5
stages=TOKENS,DESUGAR,MARK
# SOURCE
x = 1
-- top-level comment-only line (layout-transparent)
y = 2

main = println (x + y)
# TOKENS
IDENT "x"
EQUAL
INT 1
NEWLINE
IDENT "y"
EQUAL
INT 2
NEWLINE
IDENT "main"
EQUAL
IDENT "println"
LPAREN
IDENT "x"
PLUS
IDENT "y"
RPAREN
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "x" () (ELit (LInt 1)))
(DFunDef false "y" () (ELit (LInt 2)))
(DFunDef false "main" () (EApp (EVar "println") (EBinOp "+" (EVar "x") (EVar "y"))))
# MARK
(DFunDef false "x" () (ELit (LInt 1)))
(DFunDef false "y" () (ELit (LInt 2)))
(DFunDef false "main" () (EApp (EDictApp "println") (EBinOp "+" (EVar "x") (EVar "y"))))
