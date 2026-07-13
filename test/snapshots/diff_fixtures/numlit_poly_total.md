# META
source_lines=11
stages=DESUGAR,MARK
# SOURCE
-- PLAN.md #11 soundness (e7031e6 mirror): a polymorphic-`Num` accumulator literal.
-- `total : Num a => List a -> a` folds `(+)` from the literal `0`, which stays a
-- `Num a` survivor and routes through total's Num dict via `fromInt` — `total
-- [1.0,2.0]` ⇒ 3.0 (Float), `total [1,2]` ⇒ 3 (Int).  Same shape as core.mdk's
-- `sum xs = fold (+) (fromInt 0) xs`, but with the literal `0` carrying the route.
total xs = fold (+) 0 xs

main : <IO> Unit
main =
  println (total [1.0, 2.0])
  println (total [1, 2])
# DESUGAR
(DFunDef false "total" ((PVar "xs")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "+" (EVar "_a") (EVar "_b")))) (ELit (LInt 0))) (EVar "xs")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "total") (EListLit (ELit (LFloat 1.0)) (ELit (LFloat 2.0)))))) (DoExpr (EApp (EVar "println") (EApp (EVar "total") (EListLit (ELit (LInt 1)) (ELit (LInt 2))))))))
# MARK
(DFunDef false "total" ((PVar "xs")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "+" (EVar "_a") (EVar "_b")))) (ELit (LInt 0))) (EVar "xs")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "total") (EListLit (ELit (LFloat 1.0)) (ELit (LFloat 2.0)))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "total") (EListLit (ELit (LInt 1)) (ELit (LInt 2))))))))
