# META
source_lines=11
stages=TOKENS,DESUGAR,MARK
# SOURCE
-- T2: inline `let … in` recursive function binding.  The RHS references `go`
-- itself, so the typechecker must pre-bind `go` (placeholder) before inferring
-- the body and generalize after (a function is a value).  Historically the
-- inline `ELet` arm dropped the is_fun flag and panicked `unbound variable: go`.
countdown : Int -> Int
countdown start = let go n = if n == 0 then 0 else go (n - 1) in go start

main : <IO> Unit
main =
  println (countdown 5)
  println (countdown 0)
# TOKENS
NEWLINE
IDENT "countdown"
COLON
UPPER "Int"
ARROW
UPPER "Int"
NEWLINE
IDENT "countdown"
IDENT "start"
EQUAL
LET
IDENT "go"
IDENT "n"
EQUAL
IF
IDENT "n"
EQ_EQ
INT 0
THEN
INT 0
ELSE
IDENT "go"
LPAREN
IDENT "n"
MINUS
INT 1
RPAREN
IN
IDENT "go"
IDENT "start"
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
IDENT "countdown"
INT 5
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "countdown"
INT 0
RPAREN
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DTypeSig false "countdown" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "countdown" ((PVar "start")) (ELet false (PVar "go") (ELam ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EVar "go") (EBinOp "-" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "go") (EVar "start"))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "countdown") (ELit (LInt 5))))) (DoExpr (EApp (EVar "println") (EApp (EVar "countdown") (ELit (LInt 0)))))))
# MARK
(DTypeSig false "countdown" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "countdown" ((PVar "start")) (ELet false (PVar "go") (ELam ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EVar "go") (EBinOp "-" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "go") (EVar "start"))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "countdown") (ELit (LInt 5))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "countdown") (ELit (LInt 0)))))))
