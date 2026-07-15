# META
source_lines=5
stages=TOKENS,DESUGAR,MARK
# SOURCE
r = 1 +

  2

main = println r
# TOKENS
IDENT "r"
EQUAL
INT 1
PLUS
INT 2
NEWLINE
IDENT "main"
EQUAL
IDENT "println"
IDENT "r"
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "r" () (EBinOp "+" (ELit (LInt 1)) (ELit (LInt 2))))
(DFunDef false "main" () (EApp (EVar "println") (EVar "r")))
# MARK
(DFunDef false "r" () (EBinOp "+" (ELit (LInt 1)) (ELit (LInt 2))))
(DFunDef false "main" () (EApp (EDictApp "println") (EVar "r")))
