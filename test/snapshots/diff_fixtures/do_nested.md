# META
source_lines=3
stages=TOKENS,DESUGAR,MARK
# SOURCE
main = do
  let x = 1
  println x
# TOKENS
IDENT "main"
EQUAL
DO
INDENT
LET
IDENT "x"
EQUAL
INT 1
NEWLINE
IDENT "println"
IDENT "x"
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "main" () (ELet false (PVar "x") (ELit (LInt 1)) (EApp (EVar "println") (EVar "x"))))
# MARK
(DFunDef false "main" () (ELet false (PVar "x") (ELit (LInt 1)) (EApp (EDictApp "println") (EVar "x"))))
