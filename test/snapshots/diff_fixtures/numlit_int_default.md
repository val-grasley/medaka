# META
source_lines=2
stages=TOKENS,DESUGAR,MARK
# SOURCE
main : <IO> Unit
main = println (1 + 2)
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
INT 1
PLUS
INT 2
RPAREN
NEWLINE
NEWLINE
EOF
# DESUGAR
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EVar "println") (EBinOp "+" (ELit (LInt 1)) (ELit (LInt 2)))))
# MARK
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EDictApp "println") (EBinOp "+" (ELit (LInt 1)) (ELit (LInt 2)))))
