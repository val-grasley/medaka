# META
source_lines=4
stages=TOKENS,DESUGAR,MARK
# SOURCE
wrap x y = x
  :: y

main = println (wrap 1 [2, 3])
# TOKENS
IDENT "wrap"
IDENT "x"
IDENT "y"
EQUAL
IDENT "x"
CONS
IDENT "y"
NEWLINE
IDENT "main"
EQUAL
IDENT "println"
LPAREN
IDENT "wrap"
INT 1
LBRACKET
INT 2
COMMA
INT 3
RBRACKET
RPAREN
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "wrap" ((PVar "x") (PVar "y")) (EBinOp "::" (EVar "x") (EVar "y")))
(DFunDef false "main" () (EApp (EVar "println") (EApp (EApp (EVar "wrap") (ELit (LInt 1))) (EListLit (ELit (LInt 2)) (ELit (LInt 3))))))
# MARK
(DFunDef false "wrap" ((PVar "x") (PVar "y")) (EBinOp "::" (EVar "x") (EVar "y")))
(DFunDef false "main" () (EApp (EDictApp "println") (EApp (EApp (EVar "wrap") (ELit (LInt 1))) (EListLit (ELit (LInt 2)) (ELit (LInt 3))))))
