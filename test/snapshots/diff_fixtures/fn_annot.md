# META
source_lines=10
stages=DESUGAR,MARK
# SOURCE
double : Int -> Int
double x = x * 2

greet : String -> String
greet name = "Hello, " ++ name ++ "!"

main : <IO> Unit
main =
  println (double 21)
  println (greet "world")
# DESUGAR
(DTypeSig false "double" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "double" ((PVar "x")) (EBinOp "*" (EVar "x") (ELit (LInt 2))))
(DTypeSig false "greet" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "greet" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "Hello, ")) (EVar "name")) (ELit (LString "!"))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "double") (ELit (LInt 21))))) (DoExpr (EApp (EVar "println") (EApp (EVar "greet") (ELit (LString "world")))))))
# MARK
(DTypeSig false "double" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "double" ((PVar "x")) (EBinOp "*" (EVar "x") (ELit (LInt 2))))
(DTypeSig false "greet" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "greet" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "Hello, ")) (EVar "name")) (ELit (LString "!"))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "double") (ELit (LInt 21))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "greet") (ELit (LString "world")))))))
