# META
source_lines=20
stages=TOKENS,DESUGAR,MARK
# SOURCE
data Shape = Circle Int | Rect Int Int deriving (Display)

area s =
  match s
    Circle r => r * r
    Rect w h => w * h

perimeter s =
  match s
    Circle r => 2 * r
    Rect w h => 2 * (w + h)

main : <IO> Unit
main =
  let c = Circle 5
  let r = Rect 3 4
  println c
  println (area c)
  println (area r)
  println (perimeter r)
# TOKENS
DATA
UPPER "Shape"
EQUAL
UPPER "Circle"
UPPER "Int"
PIPE
UPPER "Rect"
UPPER "Int"
UPPER "Int"
DERIVING
LPAREN
UPPER "Display"
RPAREN
NEWLINE
IDENT "area"
IDENT "s"
EQUAL
INDENT
MATCH
IDENT "s"
INDENT
UPPER "Circle"
IDENT "r"
FAT_ARROW
IDENT "r"
STAR
IDENT "r"
NEWLINE
UPPER "Rect"
IDENT "w"
IDENT "h"
FAT_ARROW
IDENT "w"
STAR
IDENT "h"
NEWLINE
DEDENT
NEWLINE
DEDENT
NEWLINE
IDENT "perimeter"
IDENT "s"
EQUAL
INDENT
MATCH
IDENT "s"
INDENT
UPPER "Circle"
IDENT "r"
FAT_ARROW
INT 2
STAR
IDENT "r"
NEWLINE
UPPER "Rect"
IDENT "w"
IDENT "h"
FAT_ARROW
INT 2
STAR
LPAREN
IDENT "w"
PLUS
IDENT "h"
RPAREN
NEWLINE
DEDENT
NEWLINE
DEDENT
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
LET
IDENT "c"
EQUAL
UPPER "Circle"
INT 5
NEWLINE
LET
IDENT "r"
EQUAL
UPPER "Rect"
INT 3
INT 4
NEWLINE
IDENT "println"
IDENT "c"
NEWLINE
IDENT "println"
LPAREN
IDENT "area"
IDENT "c"
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "area"
IDENT "r"
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "perimeter"
IDENT "r"
RPAREN
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DData Private "Shape" () ((variant "Circle" (ConPos (TyCon "Int"))) (variant "Rect" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Display" ((TyCon "Shape")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Circle" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Circle ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a0"))))) (arm (PCon "Rect" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Rect ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "display") (EVar "__a1")))))))))
(DFunDef false "area" ((PVar "s")) (EMatch (EVar "s") (arm (PCon "Circle" (PVar "r")) () (EBinOp "*" (EVar "r") (EVar "r"))) (arm (PCon "Rect" (PVar "w") (PVar "h")) () (EBinOp "*" (EVar "w") (EVar "h")))))
(DFunDef false "perimeter" ((PVar "s")) (EMatch (EVar "s") (arm (PCon "Circle" (PVar "r")) () (EBinOp "*" (ELit (LInt 2)) (EVar "r"))) (arm (PCon "Rect" (PVar "w") (PVar "h")) () (EBinOp "*" (ELit (LInt 2)) (EBinOp "+" (EVar "w") (EVar "h"))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Circle") (ELit (LInt 5)))) (DoLet false false (PVar "r") (EApp (EApp (EVar "Rect") (ELit (LInt 3))) (ELit (LInt 4)))) (DoExpr (EApp (EVar "println") (EVar "c"))) (DoExpr (EApp (EVar "println") (EApp (EVar "area") (EVar "c")))) (DoExpr (EApp (EVar "println") (EApp (EVar "area") (EVar "r")))) (DoExpr (EApp (EVar "println") (EApp (EVar "perimeter") (EVar "r"))))))
# MARK
(DData Private "Shape" () ((variant "Circle" (ConPos (TyCon "Int"))) (variant "Rect" (ConPos (TyCon "Int") (TyCon "Int")))) ())
(DImpl true "Display" ((TyCon "Shape")) () ((im "display" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Circle" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Circle ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0"))))) (arm (PCon "Rect" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Rect ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "display") (EVar "__a1")))))))))
(DFunDef false "area" ((PVar "s")) (EMatch (EVar "s") (arm (PCon "Circle" (PVar "r")) () (EBinOp "*" (EVar "r") (EVar "r"))) (arm (PCon "Rect" (PVar "w") (PVar "h")) () (EBinOp "*" (EVar "w") (EVar "h")))))
(DFunDef false "perimeter" ((PVar "s")) (EMatch (EVar "s") (arm (PCon "Circle" (PVar "r")) () (EBinOp "*" (ELit (LInt 2)) (EVar "r"))) (arm (PCon "Rect" (PVar "w") (PVar "h")) () (EBinOp "*" (ELit (LInt 2)) (EBinOp "+" (EVar "w") (EVar "h"))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Circle") (ELit (LInt 5)))) (DoLet false false (PVar "r") (EApp (EApp (EVar "Rect") (ELit (LInt 3))) (ELit (LInt 4)))) (DoExpr (EApp (EDictApp "println") (EVar "c"))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "area") (EVar "c")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "area") (EVar "r")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "perimeter") (EVar "r"))))))
