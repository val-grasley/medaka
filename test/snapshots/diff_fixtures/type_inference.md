# META
source_lines=15
stages=TOKENS,DESUGAR,MARK
# SOURCE
pair a b = (a, b)

applyBoth f g x = (f x, g x)

double x = x * 2
inc x = x + 1

main : <IO> Unit
main =
  let t = pair 1 "one"
  println (fst t)
  println (snd t)
  let r = applyBoth double inc 5
  println (fst r)
  println (snd r)
# TOKENS
IDENT "pair"
IDENT "a"
IDENT "b"
EQUAL
LPAREN
IDENT "a"
COMMA
IDENT "b"
RPAREN
NEWLINE
IDENT "applyBoth"
IDENT "f"
IDENT "g"
IDENT "x"
EQUAL
LPAREN
IDENT "f"
IDENT "x"
COMMA
IDENT "g"
IDENT "x"
RPAREN
NEWLINE
IDENT "double"
IDENT "x"
EQUAL
IDENT "x"
STAR
INT 2
NEWLINE
IDENT "inc"
IDENT "x"
EQUAL
IDENT "x"
PLUS
INT 1
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
IDENT "pair"
INT 1
STRING "one"
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
LET
IDENT "r"
EQUAL
IDENT "applyBoth"
IDENT "double"
IDENT "inc"
INT 5
NEWLINE
IDENT "println"
LPAREN
IDENT "fst"
IDENT "r"
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "snd"
IDENT "r"
RPAREN
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "pair" ((PVar "a") (PVar "b")) (ETuple (EVar "a") (EVar "b")))
(DFunDef false "applyBoth" ((PVar "f") (PVar "g") (PVar "x")) (ETuple (EApp (EVar "f") (EVar "x")) (EApp (EVar "g") (EVar "x"))))
(DFunDef false "double" ((PVar "x")) (EBinOp "*" (EVar "x") (ELit (LInt 2))))
(DFunDef false "inc" ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "pair") (ELit (LInt 1))) (ELit (LString "one")))) (DoExpr (EApp (EVar "println") (EApp (EVar "fst") (EVar "t")))) (DoExpr (EApp (EVar "println") (EApp (EVar "snd") (EVar "t")))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "applyBoth") (EVar "double")) (EVar "inc")) (ELit (LInt 5)))) (DoExpr (EApp (EVar "println") (EApp (EVar "fst") (EVar "r")))) (DoExpr (EApp (EVar "println") (EApp (EVar "snd") (EVar "r"))))))
# MARK
(DFunDef false "pair" ((PVar "a") (PVar "b")) (ETuple (EVar "a") (EVar "b")))
(DFunDef false "applyBoth" ((PVar "f") (PVar "g") (PVar "x")) (ETuple (EApp (EVar "f") (EVar "x")) (EApp (EVar "g") (EVar "x"))))
(DFunDef false "double" ((PVar "x")) (EBinOp "*" (EVar "x") (ELit (LInt 2))))
(DFunDef false "inc" ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "t") (EApp (EApp (EVar "pair") (ELit (LInt 1))) (ELit (LString "one")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "fst") (EVar "t")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "snd") (EVar "t")))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "applyBoth") (EVar "double")) (EVar "inc")) (ELit (LInt 5)))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "fst") (EVar "r")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "snd") (EVar "r"))))))
