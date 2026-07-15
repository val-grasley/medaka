# META
source_lines=10
stages=TOKENS,DESUGAR,MARK
# SOURCE
double : Int -> Int
double x = x * 2

greet : String -> String
greet name = "Hello, " ++ name ++ "!"

main : <IO> Unit
main =
  println (double 21)
  println (greet "world")
# TOKENS
IDENT "double"
COLON
UPPER "Int"
ARROW
UPPER "Int"
NEWLINE
IDENT "double"
IDENT "x"
EQUAL
IDENT "x"
STAR
INT 2
NEWLINE
IDENT "greet"
COLON
UPPER "String"
ARROW
UPPER "String"
NEWLINE
IDENT "greet"
IDENT "name"
EQUAL
STRING "Hello, "
PLUSPLUS
IDENT "name"
PLUSPLUS
STRING "!"
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
IDENT "double"
INT 21
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "greet"
STRING "world"
RPAREN
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DTypeSig false "double" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "double" ((PVar "x")) (EBinOp "*" (EVar "x") (ELit (LInt 2))))
(DTypeSig false "greet" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "greet" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "Hello, ")) (EVar "name")) (ELit (LString "!"))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "double") (ELit (LInt 21))))) (DoExpr (EApp (EVar "println") (EApp (EVar "greet") (ELit (LString "world")))))))
# MARK
(DTypeSig false "double" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "double" ((PVar "x")) (EBinOp "*" (EVar "x") (ELit (LInt 2))))
(DTypeSig false "greet" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "greet" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "Hello, ")) (EVar "name")) (ELit (LString "!"))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "double") (ELit (LInt 21))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "greet") (ELit (LString "world")))))))
