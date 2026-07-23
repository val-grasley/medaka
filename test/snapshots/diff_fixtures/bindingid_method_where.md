# META
source_lines=11
stages=TOKENS,DESUGAR,MARK
# SOURCE
interface P a where
  p : a -> Int

impl P Int where
  p x = x

foo x = p x
  where
    p n = n + 1

main = println (p 5 + foo 7)
# TOKENS
INTERFACE
UPPER "P"
IDENT "a"
WHERE
INDENT
IDENT "p"
COLON
IDENT "a"
ARROW
UPPER "Int"
NEWLINE
DEDENT
NEWLINE
IMPL
UPPER "P"
UPPER "Int"
WHERE
INDENT
IDENT "p"
IDENT "x"
EQUAL
IDENT "x"
NEWLINE
DEDENT
NEWLINE
IDENT "foo"
IDENT "x"
EQUAL
IDENT "p"
IDENT "x"
INDENT
WHERE
INDENT
IDENT "p"
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
IDENT "main"
EQUAL
IDENT "println"
LPAREN
IDENT "p"
INT 5
PLUS
IDENT "foo"
INT 7
RPAREN
NEWLINE
NEWLINE
EOF
# DESUGAR
(DInterface false false "P" ("a") () ((imethod "p" (TyFun (TyVar "a") (TyCon "Int")) None)))
(DImpl false "P" ((TyCon "Int")) () ((im "p" ((PVar "x")) (EVar "x"))))
(DFunDef false "foo" ((PVar "x")) (ELetGroup ((lgb "p" (clause ((PVar "n")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "p") (EVar "x"))))
(DFunDef false "main" () (EApp (EVar "println") (EBinOp "+" (EApp (EVar "p") (ELit (LInt 5))) (EApp (EVar "foo") (ELit (LInt 7))))))
# MARK
(DInterface false false "P" ("a") () ((imethod "p" (TyFun (TyVar "a") (TyCon "Int")) None)))
(DImpl false "P" ((TyCon "Int")) () ((im "p" ((PVar "x")) (EVar "x"))))
(DFunDef false "foo" ((PVar "x")) (ELetGroup ((lgb "p" (clause ((PVar "n")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))) (EApp (EMethodRef "p") (EVar "x"))))
(DFunDef false "main" () (EApp (EDictApp "println") (EBinOp "+" (EApp (EMethodRef "p") (ELit (LInt 5))) (EApp (EVar "foo") (ELit (LInt 7))))))
