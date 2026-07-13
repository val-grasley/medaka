# META
source_lines=11
stages=DESUGAR,MARK
# SOURCE
-- T2: inline `let … in` recursive function binding.  The RHS references `go`
-- itself, so the typechecker must pre-bind `go` (placeholder) before inferring
-- the body and generalize after (a function is a value).  Historically the
-- inline `ELet` arm dropped the is_fun flag and panicked `unbound variable: go`.
countdown : Int -> Int
countdown start = let go n = if n == 0 then 0 else go (n - 1) in go start

main : <IO> Unit
main =
  println (countdown 5)
  println (countdown 0)
# DESUGAR
(DTypeSig false "countdown" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "countdown" ((PVar "start")) (ELet false (PVar "go") (ELam ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EVar "go") (EBinOp "-" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "go") (EVar "start"))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "countdown") (ELit (LInt 5))))) (DoExpr (EApp (EVar "println") (EApp (EVar "countdown") (ELit (LInt 0)))))))
# MARK
(DTypeSig false "countdown" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "countdown" ((PVar "start")) (ELet false (PVar "go") (ELam ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EVar "go") (EBinOp "-" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "go") (EVar "start"))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "countdown") (ELit (LInt 5))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "countdown") (ELit (LInt 0)))))))
