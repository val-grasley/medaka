# META
source_lines=14
stages=TOKENS,DESUGAR,MARK
# SOURCE
data Cat = { name : String }

data Box = { name : Int }

catName c = (c : Cat).name

boxName b = (b : Box).name

main : <IO> Unit
main =
  let c = Cat { name = "Tom" }
  let b = Box { name = 7 }
  println (catName c)
  println (boxName b)
# TOKENS
DATA
UPPER "Cat"
EQUAL
LBRACE
IDENT "name"
COLON
UPPER "String"
RBRACE
NEWLINE
DATA
UPPER "Box"
EQUAL
LBRACE
IDENT "name"
COLON
UPPER "Int"
RBRACE
NEWLINE
IDENT "catName"
IDENT "c"
EQUAL
LPAREN
IDENT "c"
COLON
UPPER "Cat"
RPAREN
DOT
IDENT "name"
NEWLINE
IDENT "boxName"
IDENT "b"
EQUAL
LPAREN
IDENT "b"
COLON
UPPER "Box"
RPAREN
DOT
IDENT "name"
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
UPPER "Cat"
LBRACE
IDENT "name"
EQUAL
STRING "Tom"
RBRACE
NEWLINE
LET
IDENT "b"
EQUAL
UPPER "Box"
LBRACE
IDENT "name"
EQUAL
INT 7
RBRACE
NEWLINE
IDENT "println"
LPAREN
IDENT "catName"
IDENT "c"
RPAREN
NEWLINE
IDENT "println"
LPAREN
IDENT "boxName"
IDENT "b"
RPAREN
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DData Private "Cat" () ((variant "Cat" (ConNamed (field "name" (TyCon "String"))))) ())
(DData Private "Box" () ((variant "Box" (ConNamed (field "name" (TyCon "Int"))))) ())
(DFunDef false "catName" ((PVar "c")) (EFieldAccess (EAnnot (EVar "c") (TyCon "Cat")) "name"))
(DFunDef false "boxName" ((PVar "b")) (EFieldAccess (EAnnot (EVar "b") (TyCon "Box")) "name"))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "c") (ERecordCreate "Cat" ((fa "name" (ELit (LString "Tom")))))) (DoLet false false (PVar "b") (ERecordCreate "Box" ((fa "name" (ELit (LInt 7)))))) (DoExpr (EApp (EVar "println") (EApp (EVar "catName") (EVar "c")))) (DoExpr (EApp (EVar "println") (EApp (EVar "boxName") (EVar "b"))))))
# MARK
(DData Private "Cat" () ((variant "Cat" (ConNamed (field "name" (TyCon "String"))))) ())
(DData Private "Box" () ((variant "Box" (ConNamed (field "name" (TyCon "Int"))))) ())
(DFunDef false "catName" ((PVar "c")) (EFieldAccess (EAnnot (EVar "c") (TyCon "Cat")) "name"))
(DFunDef false "boxName" ((PVar "b")) (EFieldAccess (EAnnot (EVar "b") (TyCon "Box")) "name"))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "c") (ERecordCreate "Cat" ((fa "name" (ELit (LString "Tom")))))) (DoLet false false (PVar "b") (ERecordCreate "Box" ((fa "name" (ELit (LInt 7)))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "catName") (EVar "c")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "boxName") (EVar "b"))))))
