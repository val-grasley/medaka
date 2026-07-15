# META
source_lines=4
stages=TOKENS,DESUGAR,MARK
# SOURCE
r = identity
  5

main = println r
# TOKENS
IDENT "r"
EQUAL
IDENT "identity"
INT 5
NEWLINE
IDENT "main"
EQUAL
IDENT "println"
IDENT "r"
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "r" () (EApp (EVar "identity") (ELit (LInt 5))))
(DFunDef false "main" () (EApp (EVar "println") (EVar "r")))
# MARK
(DFunDef false "r" () (EApp (EVar "identity") (ELit (LInt 5))))
(DFunDef false "main" () (EApp (EDictApp "println") (EVar "r")))
