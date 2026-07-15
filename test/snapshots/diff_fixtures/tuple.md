# META
source_lines=12
stages=TOKENS,DESUGAR,MARK
# SOURCE
swap (a, b) = (b, a)

addPair (a, b) = a + b

main : <IO> Unit
main =
  let t = (3, 7)
  println (fst t)
  println (snd t)
  println (addPair t)
  let u = swap t
  println (fst u)
# TOKENS
IDENT "swap"
LPAREN
IDENT "a"
COMMA
IDENT "b"
RPAREN
EQUAL
LPAREN
IDENT "b"
COMMA
IDENT "a"
RPAREN
NEWLINE
IDENT "addPair"
LPAREN
IDENT "a"
COMMA
IDENT "b"
RPAREN
EQUAL
IDENT "a"
PLUS
IDENT "b"
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
IDENT "t"
EQUAL
LPAREN
INT 3
COMMA
INT 7
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "fst"
IDENT "t"
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "snd"
IDENT "t"
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "addPair"
IDENT "t"
RPAREN
NEWLINE
LET
IDENT "u"
EQUAL
IDENT "swap"
IDENT "t"
NEWLINE
IDENT "println"
LPAREN
IDENT "fst"
IDENT "u"
RPAREN
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "swap" ((PTuple (PVar "a") (PVar "b"))) (ETuple (EVar "b") (EVar "a")))
(DFunDef false "addPair" ((PTuple (PVar "a") (PVar "b"))) (EBinOp "+" (EVar "a") (EVar "b")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "t") (ETuple (ELit (LInt 3)) (ELit (LInt 7)))) (DoExpr (EApp (EVar "println") (EApp (EVar "fst") (EVar "t")))) (DoExpr (EApp (EVar "println") (EApp (EVar "snd") (EVar "t")))) (DoExpr (EApp (EVar "println") (EApp (EVar "addPair") (EVar "t")))) (DoLet false false (PVar "u") (EApp (EVar "swap") (EVar "t"))) (DoExpr (EApp (EVar "println") (EApp (EVar "fst") (EVar "u"))))))
# MARK
(DFunDef false "swap" ((PTuple (PVar "a") (PVar "b"))) (ETuple (EVar "b") (EVar "a")))
(DFunDef false "addPair" ((PTuple (PVar "a") (PVar "b"))) (EBinOp "+" (EVar "a") (EVar "b")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "t") (ETuple (ELit (LInt 3)) (ELit (LInt 7)))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "fst") (EVar "t")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "snd") (EVar "t")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "addPair") (EVar "t")))) (DoLet false false (PVar "u") (EApp (EVar "swap") (EVar "t"))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "fst") (EVar "u"))))))
