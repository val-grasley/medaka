# META
source_lines=8
stages=TOKENS,DESUGAR,MARK
# SOURCE
main : <IO> Unit
main =
  println 42
  println (2 + 3)
  println (10 - 4)
  println (3 * 7)
  println True
  println False
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
IDENT "println"
INT 42
NEWLINE
IDENT "println"
LPAREN
INT 2
PLUS
INT 3
RPAREN
NEWLINE
IDENT "println"
LPAREN
INT 10
MINUS
INT 4
RPAREN
NEWLINE
IDENT "println"
LPAREN
INT 3
STAR
INT 7
RPAREN
NEWLINE
IDENT "println"
UPPER "True"
NEWLINE
IDENT "println"
UPPER "False"
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (ELit (LInt 42)))) (DoExpr (EApp (EVar "println") (EBinOp "+" (ELit (LInt 2)) (ELit (LInt 3))))) (DoExpr (EApp (EVar "println") (EBinOp "-" (ELit (LInt 10)) (ELit (LInt 4))))) (DoExpr (EApp (EVar "println") (EBinOp "*" (ELit (LInt 3)) (ELit (LInt 7))))) (DoExpr (EApp (EVar "println") (EVar "True"))) (DoExpr (EApp (EVar "println") (EVar "False")))))
# MARK
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (ELit (LInt 42)))) (DoExpr (EApp (EDictApp "println") (EBinOp "+" (ELit (LInt 2)) (ELit (LInt 3))))) (DoExpr (EApp (EDictApp "println") (EBinOp "-" (ELit (LInt 10)) (ELit (LInt 4))))) (DoExpr (EApp (EDictApp "println") (EBinOp "*" (ELit (LInt 3)) (ELit (LInt 7))))) (DoExpr (EApp (EDictApp "println") (EVar "True"))) (DoExpr (EApp (EDictApp "println") (EVar "False")))))
