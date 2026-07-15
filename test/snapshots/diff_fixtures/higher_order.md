# META
source_lines=10
stages=TOKENS,DESUGAR,MARK
# SOURCE
double x = x * 2
isEven x = x % 2 == 0

sumList xs = fold (acc x => acc + x) 0 xs

main : <IO> Unit
main =
  println (map double [1, 2, 3, 4, 5])
  println (filter isEven [1, 2, 3, 4, 5, 6])
  println (sumList (map double [1, 2, 3]))
# TOKENS
IDENT "double"
IDENT "x"
EQUAL
IDENT "x"
STAR
INT 2
NEWLINE
IDENT "isEven"
IDENT "x"
EQUAL
IDENT "x"
MOD
INT 2
EQ_EQ
INT 0
NEWLINE
IDENT "sumList"
IDENT "xs"
EQUAL
IDENT "fold"
LPAREN
IDENT "acc"
IDENT "x"
FAT_ARROW
IDENT "acc"
PLUS
IDENT "x"
RPAREN
INT 0
IDENT "xs"
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
IDENT "map"
IDENT "double"
LBRACKET
INT 1
COMMA
INT 2
COMMA
INT 3
COMMA
INT 4
COMMA
INT 5
RBRACKET
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "filter"
IDENT "isEven"
LBRACKET
INT 1
COMMA
INT 2
COMMA
INT 3
COMMA
INT 4
COMMA
INT 5
COMMA
INT 6
RBRACKET
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "sumList"
LPAREN
IDENT "map"
IDENT "double"
LBRACKET
INT 1
COMMA
INT 2
COMMA
INT 3
RBRACKET
RPAREN
RPAREN
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "double" ((PVar "x")) (EBinOp "*" (EVar "x") (ELit (LInt 2))))
(DFunDef false "isEven" ((PVar "x")) (EBinOp "==" (EBinOp "%" (EVar "x") (ELit (LInt 2))) (ELit (LInt 0))))
(DFunDef false "sumList" ((PVar "xs")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "+" (EVar "acc") (EVar "x")))) (ELit (LInt 0))) (EVar "xs")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EApp (EVar "map") (EVar "double")) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)))))) (DoExpr (EApp (EVar "println") (EApp (EApp (EVar "filter") (EVar "isEven")) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)) (ELit (LInt 6)))))) (DoExpr (EApp (EVar "println") (EApp (EVar "sumList") (EApp (EApp (EVar "map") (EVar "double")) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))))))))
# MARK
(DFunDef false "double" ((PVar "x")) (EBinOp "*" (EVar "x") (ELit (LInt 2))))
(DFunDef false "isEven" ((PVar "x")) (EBinOp "==" (EBinOp "%" (EVar "x") (ELit (LInt 2))) (ELit (LInt 0))))
(DFunDef false "sumList" ((PVar "xs")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "+" (EVar "acc") (EVar "x")))) (ELit (LInt 0))) (EVar "xs")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EApp (EMethodRef "map") (EVar "double")) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)))))) (DoExpr (EApp (EDictApp "println") (EApp (EApp (EMethodRef "filter") (EVar "isEven")) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)) (ELit (LInt 6)))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "sumList") (EApp (EApp (EMethodRef "map") (EVar "double")) (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))))))))
