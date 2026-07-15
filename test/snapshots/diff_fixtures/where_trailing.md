# META
source_lines=4
stages=TOKENS,DESUGAR,MARK
# SOURCE
f x = go x where
  go n = n + 1

main = println (f 5)
# TOKENS
IDENT "f"
IDENT "x"
EQUAL
IDENT "go"
IDENT "x"
WHERE
INDENT
IDENT "go"
IDENT "n"
EQUAL
IDENT "n"
PLUS
INT 1
NEWLINE
DEDENT
NEWLINE
IDENT "main"
EQUAL
IDENT "println"
LPAREN
IDENT "f"
INT 5
RPAREN
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "f" ((PVar "x")) (ELetGroup ((lgb "go" (clause ((PVar "n")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "go") (EVar "x"))))
(DFunDef false "main" () (EApp (EVar "println") (EApp (EVar "f") (ELit (LInt 5)))))
# MARK
(DFunDef false "f" ((PVar "x")) (ELetGroup ((lgb "go" (clause ((PVar "n")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "go") (EVar "x"))))
(DFunDef false "main" () (EApp (EDictApp "println") (EApp (EVar "f") (ELit (LInt 5)))))
