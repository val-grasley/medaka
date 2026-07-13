# META
source_lines=14
stages=DESUGAR,MARK
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
