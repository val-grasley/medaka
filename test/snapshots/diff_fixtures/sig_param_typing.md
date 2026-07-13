# META
source_lines=20
stages=DESUGAR,MARK
# SOURCE
data Inv = { shared : Int }

data Wat = { shared : String }

invShared : Inv -> Int
invShared a = a.shared

watShared : Wat -> String
watShared b = b.shared

charAt : String -> Char
charAt s = s.[0]

main : <IO> Unit
main =
  let i = Inv { shared = 7 }
  let w = Wat { shared = "hi" }
  println (invShared i)
  println (watShared w)
  println (charAt "abc")
# DESUGAR
(DData Private "Inv" () ((variant "Inv" (ConNamed (field "shared" (TyCon "Int"))))) ())
(DData Private "Wat" () ((variant "Wat" (ConNamed (field "shared" (TyCon "String"))))) ())
(DTypeSig false "invShared" (TyFun (TyCon "Inv") (TyCon "Int")))
(DFunDef false "invShared" ((PVar "a")) (EFieldAccess (EVar "a") "shared"))
(DTypeSig false "watShared" (TyFun (TyCon "Wat") (TyCon "String")))
(DFunDef false "watShared" ((PVar "b")) (EFieldAccess (EVar "b") "shared"))
(DTypeSig false "charAt" (TyFun (TyCon "String") (TyCon "Char")))
(DFunDef false "charAt" ((PVar "s")) (EApp (EApp (EVar "index") (EVar "s")) (ELit (LInt 0))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "i") (ERecordCreate "Inv" ((fa "shared" (ELit (LInt 7)))))) (DoLet false false (PVar "w") (ERecordCreate "Wat" ((fa "shared" (ELit (LString "hi")))))) (DoExpr (EApp (EVar "println") (EApp (EVar "invShared") (EVar "i")))) (DoExpr (EApp (EVar "println") (EApp (EVar "watShared") (EVar "w")))) (DoExpr (EApp (EVar "println") (EApp (EVar "charAt") (ELit (LString "abc")))))))
# MARK
(DData Private "Inv" () ((variant "Inv" (ConNamed (field "shared" (TyCon "Int"))))) ())
(DData Private "Wat" () ((variant "Wat" (ConNamed (field "shared" (TyCon "String"))))) ())
(DTypeSig false "invShared" (TyFun (TyCon "Inv") (TyCon "Int")))
(DFunDef false "invShared" ((PVar "a")) (EFieldAccess (EVar "a") "shared"))
(DTypeSig false "watShared" (TyFun (TyCon "Wat") (TyCon "String")))
(DFunDef false "watShared" ((PVar "b")) (EFieldAccess (EVar "b") "shared"))
(DTypeSig false "charAt" (TyFun (TyCon "String") (TyCon "Char")))
(DFunDef false "charAt" ((PVar "s")) (EApp (EApp (EMethodRef "index") (EVar "s")) (ELit (LInt 0))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "i") (ERecordCreate "Inv" ((fa "shared" (ELit (LInt 7)))))) (DoLet false false (PVar "w") (ERecordCreate "Wat" ((fa "shared" (ELit (LString "hi")))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "invShared") (EVar "i")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "watShared") (EVar "w")))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "charAt") (ELit (LString "abc")))))))
