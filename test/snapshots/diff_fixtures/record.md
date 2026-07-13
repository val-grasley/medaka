# META
source_lines=13
stages=DESUGAR,MARK
# SOURCE
data Point = { x : Int, y : Int }

distSq p = p.x * p.x + p.y * p.y

moveRight p = { p | x = p.x + 1 }

main : <IO> Unit
main =
  let p = Point { x = 3, y = 4 }
  println (distSq p)
  let q = moveRight p
  println q.x
  println (distSq q)
# DESUGAR
(DData Private "Point" () ((variant "Point" (ConNamed (field "x" (TyCon "Int")) (field "y" (TyCon "Int"))))) ())
(DFunDef false "distSq" ((PVar "p")) (EBinOp "+" (EBinOp "*" (EFieldAccess (EVar "p") "x") (EFieldAccess (EVar "p") "x")) (EBinOp "*" (EFieldAccess (EVar "p") "y") (EFieldAccess (EVar "p") "y"))))
(DFunDef false "moveRight" ((PVar "p")) (ERecordUpdate (EVar "p") ((fa "x" (EBinOp "+" (EFieldAccess (EVar "p") "x") (ELit (LInt 1)))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "p") (ERecordCreate "Point" ((fa "x" (ELit (LInt 3))) (fa "y" (ELit (LInt 4)))))) (DoExpr (EApp (EVar "println") (EApp (EVar "distSq") (EVar "p")))) (DoLet false false (PVar "q") (EApp (EVar "moveRight") (EVar "p"))) (DoExpr (EApp (EVar "println") (EFieldAccess (EVar "q") "x"))) (DoExpr (EApp (EVar "println") (EApp (EVar "distSq") (EVar "q"))))))
# MARK
(DData Private "Point" () ((variant "Point" (ConNamed (field "x" (TyCon "Int")) (field "y" (TyCon "Int"))))) ())
(DFunDef false "distSq" ((PVar "p")) (EBinOp "+" (EBinOp "*" (EFieldAccess (EVar "p") "x") (EFieldAccess (EVar "p") "x")) (EBinOp "*" (EFieldAccess (EVar "p") "y") (EFieldAccess (EVar "p") "y"))))
(DFunDef false "moveRight" ((PVar "p")) (ERecordUpdate (EVar "p") ((fa "x" (EBinOp "+" (EFieldAccess (EVar "p") "x") (ELit (LInt 1)))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "p") (ERecordCreate "Point" ((fa "x" (ELit (LInt 3))) (fa "y" (ELit (LInt 4)))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "distSq") (EVar "p")))) (DoLet false false (PVar "q") (EApp (EVar "moveRight") (EVar "p"))) (DoExpr (EApp (EDictApp "println") (EFieldAccess (EVar "q") "x"))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "distSq") (EVar "q"))))))
