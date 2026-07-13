# META
source_lines=12
stages=DESUGAR,MARK
# SOURCE
swap (a, b) = (b, a)

addPair (a, b) = a + b

main : <IO> Unit
main =
  let t = (3, 7)
  println (fst t)
  println (snd t)
  println (addPair t)
  let u = swap t
  println (fst u)
# DESUGAR
(DFunDef false "swap" ((PTuple (PVar "a") (PVar "b"))) (ETuple (EVar "b") (EVar "a")))
(DFunDef false "addPair" ((PTuple (PVar "a") (PVar "b"))) (EBinOp "+" (EVar "a") (EVar "b")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "t") (ETuple (ELit (LInt 3)) (ELit (LInt 7)))) (DoExpr (EApp (EVar "println") (EApp (EVar "fst") (EVar "t")))) (DoExpr (EApp (EVar "println") (EApp (EVar "snd") (EVar "t")))) (DoExpr (EApp (EVar "println") (EApp (EVar "addPair") (EVar "t")))) (DoLet false false (PVar "u") (EApp (EVar "swap") (EVar "t"))) (DoExpr (EApp (EVar "println") (EApp (EVar "fst") (EVar "u"))))))
# MARK
(DFunDef false "swap" ((PTuple (PVar "a") (PVar "b"))) (ETuple (EVar "b") (EVar "a")))
(DFunDef false "addPair" ((PTuple (PVar "a") (PVar "b"))) (EBinOp "+" (EVar "a") (EVar "b")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "t") (ETuple (ELit (LInt 3)) (ELit (LInt 7)))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "fst") (EVar "t")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "snd") (EVar "t")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "addPair") (EVar "t")))) (DoLet false false (PVar "u") (EApp (EVar "swap") (EVar "t"))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "fst") (EVar "u"))))))
