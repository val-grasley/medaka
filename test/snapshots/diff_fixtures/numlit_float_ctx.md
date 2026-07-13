# META
source_lines=5
stages=DESUGAR,MARK
# SOURCE
x : Float
x = 0

main : <IO> Unit
main = println x
# DESUGAR
(DTypeSig false "x" (TyCon "Float"))
(DFunDef false "x" () (ELit (LInt 0)))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EVar "println") (EVar "x")))
# MARK
(DTypeSig false "x" (TyCon "Float"))
(DFunDef false "x" () (ELit (LInt 0)))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EDictApp "println") (EVar "x")))
