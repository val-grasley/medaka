# META
source_lines=11
stages=DESUGAR,MARK
# SOURCE
-- PLAN.md #11 soundness (e7031e6 mirror): a polymorphic-`Num` integer literal in a
-- generic function body must route through `fromInt` at runtime, not stamp a static
-- VInt.  `inc : Num a => a -> a`; the `1` stays a `Num a` survivor (not defaulted),
-- so it dispatches through inc's Num dict — `inc 2.5` ⇒ 3.5 (Float), `inc 5` ⇒ 6
-- (Int).  Pre-fix this crashed `unknown op '+' for 2.5, 1`.
inc x = x + 1

main : <IO> Unit
main =
  println (inc 2.5)
  println (inc 5)
# DESUGAR
(DFunDef false "inc" ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "inc") (ELit (LFloat 2.5))))) (DoExpr (EApp (EVar "println") (EApp (EVar "inc") (ELit (LInt 5)))))))
# MARK
(DFunDef false "inc" ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 1))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "inc") (ELit (LFloat 2.5))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "inc") (ELit (LInt 5)))))))
