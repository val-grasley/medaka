# META
source_lines=7
stages=TOKENS,DESUGAR,MARK
# SOURCE
main : <IO> Unit
main =
  let x = 10
  let y = 20
  let sum = x + y
  println sum
  println (x * y)
# TOKENS
IDENT "main"
COLON
LT
UPPER "IO"
GT
UPPER "Unit"
NEWLINE
IDENT "main"
EQUAL
INDENT
LET
IDENT "x"
EQUAL
INT 10
NEWLINE
LET
IDENT "y"
EQUAL
INT 20
NEWLINE
LET
IDENT "sum"
EQUAL
IDENT "x"
PLUS
IDENT "y"
NEWLINE
IDENT "println"
IDENT "sum"
NEWLINE
IDENT "println"
LPAREN
IDENT "x"
STAR
IDENT "y"
RPAREN
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "x") (ELit (LInt 10))) (DoLet false false (PVar "y") (ELit (LInt 20))) (DoLet false false (PVar "sum") (EBinOp "+" (EVar "x") (EVar "y"))) (DoExpr (EApp (EVar "println") (EVar "sum"))) (DoExpr (EApp (EVar "println") (EBinOp "*" (EVar "x") (EVar "y"))))))
# MARK
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "x") (ELit (LInt 10))) (DoLet false false (PVar "y") (ELit (LInt 20))) (DoLet false false (PVar "sum") (EBinOp "+" (EVar "x") (EVar "y"))) (DoExpr (EApp (EDictApp "println") (EDictApp "sum"))) (DoExpr (EApp (EDictApp "println") (EBinOp "*" (EVar "x") (EVar "y"))))))
