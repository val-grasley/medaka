# META
source_lines=2
stages=TOKENS,DESUGAR,MARK
# SOURCE
main : <IO> Unit
main = println (sum [1.0, 2.0, 3.0])
# TOKENS
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
IDENT "sum"
LBRACKET
FLOAT 1.0
COMMA
FLOAT 2.0
COMMA
FLOAT 3.0
RBRACKET
RPAREN
NEWLINE
NEWLINE
EOF
# DESUGAR
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EVar "println") (EApp (EVar "sum") (EListLit (ELit (LFloat 1.0)) (ELit (LFloat 2.0)) (ELit (LFloat 3.0))))))
# MARK
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EDictApp "println") (EApp (EDictApp "sum") (EListLit (ELit (LFloat 1.0)) (ELit (LFloat 2.0)) (ELit (LFloat 3.0))))))
