# META
source_lines=4
stages=TOKENS,DESUGAR,MARK
# SOURCE
r = [1, 2]
  :: [[3, 4]]

main = println r
# TOKENS
IDENT "r"
EQUAL
LBRACKET
INT 1
COMMA
INT 2
RBRACKET
CONS
LBRACKET
LBRACKET
INT 3
COMMA
INT 4
RBRACKET
RBRACKET
NEWLINE
IDENT "main"
EQUAL
IDENT "println"
IDENT "r"
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "r" () (EBinOp "::" (EListLit (ELit (LInt 1)) (ELit (LInt 2))) (EListLit (EListLit (ELit (LInt 3)) (ELit (LInt 4))))))
(DFunDef false "main" () (EApp (EVar "println") (EVar "r")))
# MARK
(DFunDef false "r" () (EBinOp "::" (EListLit (ELit (LInt 1)) (ELit (LInt 2))) (EListLit (EListLit (ELit (LInt 3)) (ELit (LInt 4))))))
(DFunDef false "main" () (EApp (EDictApp "println") (EVar "r")))
