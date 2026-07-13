# META
source_lines=18
stages=DESUGAR,MARK
# SOURCE
sign n
  | n < 0 = "neg"
  | n > 0 = "pos"
  | True = "zero"

clamp lo hi n
  | n < lo = lo
  | n > hi = hi
  | True = n

main : <IO> Unit
main =
  println (sign (-3))
  println (sign 0)
  println (sign 5)
  println (clamp 0 10 (-5))
  println (clamp 0 10 15)
  println (clamp 0 10 7)
# DESUGAR
(DFunDef false "sign" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (ELit (LString "neg")) (EIf (EBinOp ">" (EVar "n") (ELit (LInt 0))) (ELit (LString "pos")) (EIf (EVar "True") (ELit (LString "zero")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "clamp" ((PVar "lo") (PVar "hi") (PVar "n")) (EIf (EBinOp "<" (EVar "n") (EVar "lo")) (EVar "lo") (EIf (EBinOp ">" (EVar "n") (EVar "hi")) (EVar "hi") (EIf (EVar "True") (EVar "n") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "sign") (EUnOp "-" (ELit (LInt 3)))))) (DoExpr (EApp (EVar "println") (EApp (EVar "sign") (ELit (LInt 0))))) (DoExpr (EApp (EVar "println") (EApp (EVar "sign") (ELit (LInt 5))))) (DoExpr (EApp (EVar "println") (EApp (EApp (EApp (EVar "clamp") (ELit (LInt 0))) (ELit (LInt 10))) (EUnOp "-" (ELit (LInt 5)))))) (DoExpr (EApp (EVar "println") (EApp (EApp (EApp (EVar "clamp") (ELit (LInt 0))) (ELit (LInt 10))) (ELit (LInt 15))))) (DoExpr (EApp (EVar "println") (EApp (EApp (EApp (EVar "clamp") (ELit (LInt 0))) (ELit (LInt 10))) (ELit (LInt 7)))))))
# MARK
(DFunDef false "sign" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (ELit (LString "neg")) (EIf (EBinOp ">" (EVar "n") (ELit (LInt 0))) (ELit (LString "pos")) (EIf (EVar "True") (ELit (LString "zero")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "clamp" ((PVar "lo") (PVar "hi") (PVar "n")) (EIf (EBinOp "<" (EVar "n") (EVar "lo")) (EVar "lo") (EIf (EBinOp ">" (EVar "n") (EVar "hi")) (EVar "hi") (EIf (EVar "True") (EVar "n") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "sign") (EUnOp "-" (ELit (LInt 3)))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "sign") (ELit (LInt 0))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "sign") (ELit (LInt 5))))) (DoExpr (EApp (EDictApp "println") (EApp (EApp (EApp (EDictApp "clamp") (ELit (LInt 0))) (ELit (LInt 10))) (EUnOp "-" (ELit (LInt 5)))))) (DoExpr (EApp (EDictApp "println") (EApp (EApp (EApp (EDictApp "clamp") (ELit (LInt 0))) (ELit (LInt 10))) (ELit (LInt 15))))) (DoExpr (EApp (EDictApp "println") (EApp (EApp (EApp (EDictApp "clamp") (ELit (LInt 0))) (ELit (LInt 10))) (ELit (LInt 7)))))))
