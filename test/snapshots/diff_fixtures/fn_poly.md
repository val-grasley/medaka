# META
source_lines=10
stages=TOKENS,DESUGAR,MARK
# SOURCE
identity x = x
konst x _ = x
flip f b a = f a b

main : <IO> Unit
main =
  println (identity 42)
  println (identity "hello")
  println (konst 10 "ignored")
  println (flip konst "ignored" 99)
# TOKENS
IDENT "identity"
IDENT "x"
EQUAL
IDENT "x"
NEWLINE
IDENT "konst"
IDENT "x"
UNDERSCORE
EQUAL
IDENT "x"
NEWLINE
IDENT "flip"
IDENT "f"
IDENT "b"
IDENT "a"
EQUAL
IDENT "f"
IDENT "a"
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
IDENT "println"
LPAREN
IDENT "identity"
INT 42
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "identity"
STRING "hello"
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "konst"
INT 10
STRING "ignored"
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "flip"
IDENT "konst"
STRING "ignored"
INT 99
RPAREN
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "identity" ((PVar "x")) (EVar "x"))
(DFunDef false "konst" ((PVar "x") PWild) (EVar "x"))
(DFunDef false "flip" ((PVar "f") (PVar "b") (PVar "a")) (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "identity") (ELit (LInt 42))))) (DoExpr (EApp (EVar "println") (EApp (EVar "identity") (ELit (LString "hello"))))) (DoExpr (EApp (EVar "println") (EApp (EApp (EVar "konst") (ELit (LInt 10))) (ELit (LString "ignored"))))) (DoExpr (EApp (EVar "println") (EApp (EApp (EApp (EVar "flip") (EVar "konst")) (ELit (LString "ignored"))) (ELit (LInt 99)))))))
# MARK
(DFunDef false "identity" ((PVar "x")) (EVar "x"))
(DFunDef false "konst" ((PVar "x") PWild) (EVar "x"))
(DFunDef false "flip" ((PVar "f") (PVar "b") (PVar "a")) (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "identity") (ELit (LInt 42))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "identity") (ELit (LString "hello"))))) (DoExpr (EApp (EDictApp "println") (EApp (EApp (EVar "konst") (ELit (LInt 10))) (ELit (LString "ignored"))))) (DoExpr (EApp (EDictApp "println") (EApp (EApp (EApp (EVar "flip") (EVar "konst")) (ELit (LString "ignored"))) (ELit (LInt 99)))))))
