# META
source_lines=10
stages=DESUGAR,MARK
# SOURCE
identity x = x
konst x _ = x
flip f b a = f a b

main : <IO> Unit
main =
  println (identity 42)
  println (identity "hello")
  println (konst 10 "ignored")
  println (flip konst "ignored" 99)
# DESUGAR
(DFunDef false "identity" ((PVar "x")) (EVar "x"))
(DFunDef false "konst" ((PVar "x") PWild) (EVar "x"))
(DFunDef false "flip" ((PVar "f") (PVar "b") (PVar "a")) (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "identity") (ELit (LInt 42))))) (DoExpr (EApp (EVar "println") (EApp (EVar "identity") (ELit (LString "hello"))))) (DoExpr (EApp (EVar "println") (EApp (EApp (EVar "konst") (ELit (LInt 10))) (ELit (LString "ignored"))))) (DoExpr (EApp (EVar "println") (EApp (EApp (EApp (EVar "flip") (EVar "konst")) (ELit (LString "ignored"))) (ELit (LInt 99)))))))
# MARK
(DFunDef false "identity" ((PVar "x")) (EVar "x"))
(DFunDef false "konst" ((PVar "x") PWild) (EVar "x"))
(DFunDef false "flip" ((PVar "f") (PVar "b") (PVar "a")) (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "identity") (ELit (LInt 42))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "identity") (ELit (LString "hello"))))) (DoExpr (EApp (EDictApp "println") (EApp (EApp (EVar "konst") (ELit (LInt 10))) (ELit (LString "ignored"))))) (DoExpr (EApp (EDictApp "println") (EApp (EApp (EApp (EVar "flip") (EVar "konst")) (ELit (LString "ignored"))) (ELit (LInt 99)))))))
