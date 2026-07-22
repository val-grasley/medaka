# META
source_lines=11
stages=TOKENS,DESUGAR,MARK
# SOURCE
interface Sz a where
  sz : a -> Int

impl Sz Int where
  sz x = g x
    where
      g n = n + 1

g x = x

main = println (g "hi")
# TOKENS
INTERFACE
UPPER "Sz"
IDENT "a"
WHERE
INDENT
IDENT "sz"
COLON
IDENT "a"
ARROW
UPPER "Int"
NEWLINE
DEDENT
NEWLINE
IMPL
UPPER "Sz"
UPPER "Int"
WHERE
INDENT
IDENT "sz"
IDENT "x"
EQUAL
IDENT "g"
IDENT "x"
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
(DInterface false false "Sz" ("a") () ((imethod "sz" (TyFun (TyVar "a") (TyCon "Int")) None)))
(DImpl false "Sz" ((TyCon "Int")) () ((im "sz" ((PVar "x")) (ELetGroup ((lgb "g" (clause ((PVar "n")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "g") (EVar "x"))))))
(DFunDef false "g" ((PVar "x")) (EVar "x"))
(DFunDef false "main" () (EApp (EVar "println") (EApp (EVar "g") (ELit (LString "hi")))))
# MARK
(DInterface false false "Sz" ("a") () ((imethod "sz" (TyFun (TyVar "a") (TyCon "Int")) None)))
(DImpl false "Sz" ((TyCon "Int")) () ((im "sz" ((PVar "x")) (ELetGroup ((lgb "g" (clause ((PVar "n")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "g") (EVar "x"))))))
(DFunDef false "g" ((PVar "x")) (EVar "x"))
(DFunDef false "main" () (EApp (EDictApp "println") (EApp (EVar "g") (ELit (LString "hi")))))
