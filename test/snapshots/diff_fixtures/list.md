# META
source_lines=11
stages=TOKENS,DESUGAR,MARK
# SOURCE
sum xs = fold (acc x => acc + x) 0 xs

myLength xs = fold (acc _ => acc + 1) 0 xs

main : <IO> Unit
main =
  let xs = [1, 2, 3, 4, 5]
  println (sum xs)
  println (myLength xs)
  println (sum ([] : List Int))
  println ([1, 2] ++ [3, 4])
# TOKENS
IDENT "sum"
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
IDENT "myLength"
IDENT "xs"
EQUAL
IDENT "fold"
LPAREN
IDENT "acc"
UNDERSCORE
FAT_ARROW
IDENT "acc"
PLUS
INT 1
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
LET
IDENT "xs"
EQUAL
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
NEWLINE
IDENT "println"
LPAREN
IDENT "sum"
IDENT "xs"
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "myLength"
IDENT "xs"
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "sum"
LPAREN
LBRACKET
RBRACKET
COLON
UPPER "List"
UPPER "Int"
RPAREN
RPAREN
NEWLINE
IDENT "println"
LPAREN
LBRACKET
INT 1
COMMA
INT 2
RBRACKET
PLUSPLUS
LBRACKET
INT 3
COMMA
INT 4
RBRACKET
RPAREN
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "sum" ((PVar "xs")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "+" (EVar "acc") (EVar "x")))) (ELit (LInt 0))) (EVar "xs")))
(DFunDef false "myLength" ((PVar "xs")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") PWild) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))) (ELit (LInt 0))) (EVar "xs")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "xs") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)))) (DoExpr (EApp (EVar "println") (EApp (EVar "sum") (EVar "xs")))) (DoExpr (EApp (EVar "println") (EApp (EVar "myLength") (EVar "xs")))) (DoExpr (EApp (EVar "println") (EApp (EVar "sum") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))))) (DoExpr (EApp (EVar "println") (EBinOp "++" (EListLit (ELit (LInt 1)) (ELit (LInt 2))) (EListLit (ELit (LInt 3)) (ELit (LInt 4))))))))
# MARK
(DFunDef false "sum" ((PVar "xs")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "x")) (EBinOp "+" (EVar "acc") (EVar "x")))) (ELit (LInt 0))) (EVar "xs")))
(DFunDef false "myLength" ((PVar "xs")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") PWild) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))) (ELit (LInt 0))) (EVar "xs")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "xs") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5)))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "sum") (EVar "xs")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "myLength") (EVar "xs")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "sum") (EAnnot (EListLit) (TyApp (TyCon "List") (TyCon "Int")))))) (DoExpr (EApp (EDictApp "println") (EBinOp "++" (EListLit (ELit (LInt 1)) (ELit (LInt 2))) (EListLit (ELit (LInt 3)) (ELit (LInt 4))))))))
