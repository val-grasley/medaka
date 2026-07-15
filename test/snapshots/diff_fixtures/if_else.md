# META
source_lines=15
stages=TOKENS,DESUGAR,MARK
# SOURCE
classify n =
  if n < 0 then "negative"
  else if n > 0 then "positive"
  else "zero"

abs n =
  if n < 0 then 0 - n
  else n

main : <IO> Unit
main =
  println (classify (-5))
  println (classify 0)
  println (classify 3)
  println (abs (-7))
# TOKENS
IDENT "classify"
IDENT "n"
EQUAL
INDENT
IF
IDENT "n"
LT
INT 0
THEN
STRING "negative"
ELSE
IF
IDENT "n"
GT
INT 0
THEN
STRING "positive"
ELSE
STRING "zero"
NEWLINE
DEDENT
NEWLINE
IDENT "abs"
IDENT "n"
EQUAL
INDENT
IF
IDENT "n"
LT
INT 0
THEN
INT 0
MINUS
IDENT "n"
ELSE
IDENT "n"
NEWLINE
DEDENT
NEWLINE
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
LPAREN
IDENT "classify"
LPAREN
MINUS
INT 5
RPAREN
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "classify"
INT 0
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "classify"
INT 3
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "abs"
LPAREN
MINUS
INT 7
RPAREN
RPAREN
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "classify" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (ELit (LString "negative")) (EIf (EBinOp ">" (EVar "n") (ELit (LInt 0))) (ELit (LString "positive")) (ELit (LString "zero")))))
(DFunDef false "abs" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "classify") (EUnOp "-" (ELit (LInt 5)))))) (DoExpr (EApp (EVar "println") (EApp (EVar "classify") (ELit (LInt 0))))) (DoExpr (EApp (EVar "println") (EApp (EVar "classify") (ELit (LInt 3))))) (DoExpr (EApp (EVar "println") (EApp (EVar "abs") (EUnOp "-" (ELit (LInt 7))))))))
# MARK
(DFunDef false "classify" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (ELit (LString "negative")) (EIf (EBinOp ">" (EVar "n") (ELit (LInt 0))) (ELit (LString "positive")) (ELit (LString "zero")))))
(DFunDef false "abs#shadow" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "classify") (EUnOp "-" (ELit (LInt 5)))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "classify") (ELit (LInt 0))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "classify") (ELit (LInt 3))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "abs#shadow") (EUnOp "-" (ELit (LInt 7))))))))
