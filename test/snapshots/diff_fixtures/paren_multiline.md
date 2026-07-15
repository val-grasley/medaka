# META
source_lines=5
stages=TOKENS,DESUGAR,MARK
# SOURCE
r = (1
  + 2
  * 3)

main = println r
# TOKENS
IDENT "r"
EQUAL
LPAREN
INT 1
PLUS
INT 2
STAR
INT 3
RPAREN
NEWLINE
IDENT "main"
EQUAL
IDENT "println"
IDENT "r"
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "r" () (EBinOp "+" (ELit (LInt 1)) (EBinOp "*" (ELit (LInt 2)) (ELit (LInt 3)))))
(DFunDef false "main" () (EApp (EVar "println") (EVar "r")))
# MARK
(DFunDef false "r" () (EBinOp "+" (ELit (LInt 1)) (EBinOp "*" (ELit (LInt 2)) (ELit (LInt 3)))))
(DFunDef false "main" () (EApp (EDictApp "println") (EVar "r")))
