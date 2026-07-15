# META
source_lines=15
stages=TOKENS,DESUGAR,MARK
# SOURCE
factorial n =
  match n
    0 => 1
    n => n * factorial (n - 1)

fib n =
  match n
    0 => 0
    1 => 1
    n => fib (n - 1) + fib (n - 2)

main : <IO> Unit
main =
  println (factorial 10)
  println (fib 10)
# TOKENS
IDENT "factorial"
IDENT "n"
EQUAL
INDENT
MATCH
IDENT "n"
INDENT
INT 0
FAT_ARROW
INT 1
NEWLINE
IDENT "n"
FAT_ARROW
IDENT "n"
STAR
IDENT "factorial"
LPAREN
IDENT "n"
MINUS
INT 1
RPAREN
NEWLINE
DEDENT
NEWLINE
DEDENT
NEWLINE
IDENT "fib"
IDENT "n"
EQUAL
INDENT
MATCH
IDENT "n"
INDENT
INT 0
FAT_ARROW
INT 0
NEWLINE
INT 1
FAT_ARROW
INT 1
NEWLINE
IDENT "n"
FAT_ARROW
IDENT "fib"
LPAREN
IDENT "n"
MINUS
INT 1
RPAREN
PLUS
IDENT "fib"
LPAREN
IDENT "n"
MINUS
INT 2
RPAREN
NEWLINE
DEDENT
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
IDENT "factorial"
INT 10
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "fib"
INT 10
RPAREN
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "factorial" ((PVar "n")) (EMatch (EVar "n") (arm (PLit (LInt 0)) () (ELit (LInt 1))) (arm (PVar "n") () (EBinOp "*" (EVar "n") (EApp (EVar "factorial") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))))
(DFunDef false "fib" ((PVar "n")) (EMatch (EVar "n") (arm (PLit (LInt 0)) () (ELit (LInt 0))) (arm (PLit (LInt 1)) () (ELit (LInt 1))) (arm (PVar "n") () (EBinOp "+" (EApp (EVar "fib") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "fib") (EBinOp "-" (EVar "n") (ELit (LInt 2))))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "factorial") (ELit (LInt 10))))) (DoExpr (EApp (EVar "println") (EApp (EVar "fib") (ELit (LInt 10)))))))
# MARK
(DFunDef false "factorial" ((PVar "n")) (EMatch (EVar "n") (arm (PLit (LInt 0)) () (ELit (LInt 1))) (arm (PVar "n") () (EBinOp "*" (EVar "n") (EApp (EVar "factorial") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))))
(DFunDef false "fib" ((PVar "n")) (EMatch (EVar "n") (arm (PLit (LInt 0)) () (ELit (LInt 0))) (arm (PLit (LInt 1)) () (ELit (LInt 1))) (arm (PVar "n") () (EBinOp "+" (EApp (EVar "fib") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "fib") (EBinOp "-" (EVar "n") (ELit (LInt 2))))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "factorial") (ELit (LInt 10))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "fib") (ELit (LInt 10)))))))
