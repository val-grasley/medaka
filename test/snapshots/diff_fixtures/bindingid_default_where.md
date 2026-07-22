# META
source_lines=12
stages=TOKENS,DESUGAR,MARK
# SOURCE
interface Bx a where
  bx : a -> Int
  bx x = g 0
    where
      g n = n + 1

impl Bx Int where
  bx x = x

g x = x

main = println (g "hi")
# TOKENS
INTERFACE
UPPER "Bx"
IDENT "a"
WHERE
INDENT
IDENT "bx"
COLON
IDENT "a"
ARROW
UPPER "Int"
NEWLINE
IDENT "bx"
IDENT "x"
EQUAL
IDENT "g"
INT 0
INDENT
WHERE
INDENT
IDENT "g"
IDENT "n"
EQUAL
IDENT "n"
PLUS
INT 1
NEWLINE
DEDENT
NEWLINE
DEDENT
NEWLINE
DEDENT
NEWLINE
IMPL
UPPER "Bx"
UPPER "Int"
WHERE
INDENT
IDENT "bx"
IDENT "x"
EQUAL
IDENT "x"
NEWLINE
DEDENT
NEWLINE
IDENT "g"
IDENT "x"
EQUAL
IDENT "x"
NEWLINE
IDENT "main"
EQUAL
IDENT "println"
LPAREN
IDENT "g"
STRING "hi"
RPAREN
NEWLINE
NEWLINE
EOF
# DESUGAR
(DInterface false false "Bx" ("a") () ((imethod "bx" (TyFun (TyVar "a") (TyCon "Int")) (mdef ((PVar "x")) (ELetGroup ((lgb "g" (clause ((PVar "n")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "g") (ELit (LInt 0))))))))
(DImpl false "Bx" ((TyCon "Int")) () ((im "bx" ((PVar "x")) (EVar "x"))))
(DFunDef false "g" ((PVar "x")) (EVar "x"))
(DFunDef false "main" () (EApp (EVar "println") (EApp (EVar "g") (ELit (LString "hi")))))
# MARK
(DInterface false false "Bx" ("a") () ((imethod "bx" (TyFun (TyVar "a") (TyCon "Int")) (mdef ((PVar "x")) (ELetGroup ((lgb "g" (clause ((PVar "n")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "g") (ELit (LInt 0))))))))
(DImpl false "Bx" ((TyCon "Int")) () ((im "bx" ((PVar "x")) (EVar "x"))))
(DFunDef false "g" ((PVar "x")) (EVar "x"))
(DFunDef false "main" () (EApp (EDictApp "println") (EApp (EVar "g") (ELit (LString "hi")))))
