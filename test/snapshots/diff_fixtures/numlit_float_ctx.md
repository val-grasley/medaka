# META
source_lines=5
stages=TOKENS,DESUGAR,MARK
# SOURCE
x : Float
x = 0

main : <IO> Unit
main = println x
# TOKENS
IDENT "x"
COLON
UPPER "Float"
NEWLINE
IDENT "x"
EQUAL
INT 0
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
IDENT "x"
NEWLINE
NEWLINE
EOF
# DESUGAR
(DTypeSig false "x" (TyCon "Float"))
(DFunDef false "x" () (ELit (LInt 0)))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EVar "println") (EVar "x")))
# MARK
(DTypeSig false "x" (TyCon "Float"))
(DFunDef false "x" () (ELit (LInt 0)))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EDictApp "println") (EVar "x")))
