# META
source_lines=5
stages=TOKENS,DESUGAR,MARK
# SOURCE
g : Float -> Float
g x = x + 1

main : <IO> Unit
main = println (g 2.0)
# TOKENS
IDENT "g"
COLON
UPPER "Float"
ARROW
UPPER "Float"
NEWLINE
IDENT "g"
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
IDENT "println"
LPAREN
IDENT "g"
FLOAT 2.0
RPAREN
NEWLINE
NEWLINE
EOF
# DESUGAR
(DTypeSig false "g" (TyFun (TyCon "Float") (TyCon "Float")))
(DFunDef false "g" ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EVar "println") (EApp (EVar "g") (ELit (LFloat 2.0)))))
# MARK
(DTypeSig false "g" (TyFun (TyCon "Float") (TyCon "Float")))
(DFunDef false "g" ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EDictApp "println") (EApp (EVar "g") (ELit (LFloat 2.0)))))
