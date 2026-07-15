# META
source_lines=8
stages=TOKENS,DESUGAR,MARK
# SOURCE
data Color = Red | Green | Blue

colorName : Color -> String
colorName c = match c
  Red => "red"
  Green => "green"

main = println (colorName Red)
# TOKENS
DATA
UPPER "Color"
EQUAL
UPPER "Red"
PIPE
UPPER "Green"
PIPE
UPPER "Blue"
NEWLINE
IDENT "colorName"
COLON
UPPER "Color"
ARROW
UPPER "String"
NEWLINE
IDENT "colorName"
IDENT "c"
EQUAL
MATCH
IDENT "c"
INDENT
UPPER "Red"
FAT_ARROW
STRING "red"
NEWLINE
UPPER "Green"
FAT_ARROW
STRING "green"
NEWLINE
DEDENT
NEWLINE
IDENT "main"
EQUAL
IDENT "println"
LPAREN
IDENT "colorName"
UPPER "Red"
RPAREN
NEWLINE
NEWLINE
EOF
# DESUGAR
(DData Private "Color" () ((variant "Red" (ConPos)) (variant "Green" (ConPos)) (variant "Blue" (ConPos))) ())
(DTypeSig false "colorName" (TyFun (TyCon "Color") (TyCon "String")))
(DFunDef false "colorName" ((PVar "c")) (EMatch (EVar "c") (arm (PCon "Red") () (ELit (LString "red"))) (arm (PCon "Green") () (ELit (LString "green")))))
(DFunDef false "main" () (EApp (EVar "println") (EApp (EVar "colorName") (EVar "Red"))))
# MARK
(DData Private "Color" () ((variant "Red" (ConPos)) (variant "Green" (ConPos)) (variant "Blue" (ConPos))) ())
(DTypeSig false "colorName" (TyFun (TyCon "Color") (TyCon "String")))
(DFunDef false "colorName" ((PVar "c")) (EMatch (EVar "c") (arm (PCon "Red") () (ELit (LString "red"))) (arm (PCon "Green") () (ELit (LString "green")))))
(DFunDef false "main" () (EApp (EDictApp "println") (EApp (EVar "colorName") (EVar "Red"))))
