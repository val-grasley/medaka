# META
source_lines=8
stages=DESUGAR,MARK
# SOURCE
data Color = Red | Green | Blue

colorName : Color -> String
colorName c = match c
  Red => "red"
  Green => "green"

main = println (colorName Red)
# DESUGAR
(DData Private "Color" () ((variant "Red" (ConPos)) (variant "Green" (ConPos)) (variant "Blue" (ConPos))) ())
(DTypeSig false "colorName" (TyFun (TyCon "Color") (TyCon "String")))
(DFunDef false "colorName" ((PVar "c")) (EMatch (EVar "c") (arm (PCon "Red") () (ELit (LString "red"))) (arm (PCon "Green") () (ELit (LString "green")))))
(DFunDef false "main" () (EApp (EVar "println") (EApp (EVar "colorName") (EVar "Red"))))
# MARK
(DData Private "Color" () ((variant "Red" (ConPos)) (variant "Green" (ConPos)) (variant "Blue" (ConPos))) ())
(DTypeSig false "colorName" (TyFun (TyCon "Color") (TyCon "String")))
(DFunDef false "colorName" ((PVar "c")) (EMatch (EVar "c") (arm (PCon "Red") () (ELit (LString "red"))) (arm (PCon "Green") () (ELit (LString "green")))))
(DFunDef false "main" () (EApp (EDictApp "println") (EApp (EVar "colorName") (EVar "Red"))))
