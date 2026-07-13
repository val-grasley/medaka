# META
source_lines=2
stages=DESUGAR,MARK
# SOURCE
main : <IO> Unit
main = println (1 + 2)
# DESUGAR
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EVar "println") (EBinOp "+" (ELit (LInt 1)) (ELit (LInt 2)))))
# MARK
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EDictApp "println") (EBinOp "+" (ELit (LInt 1)) (ELit (LInt 2)))))
