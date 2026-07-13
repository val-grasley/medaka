# META
source_lines=15
stages=DESUGAR,MARK
# SOURCE
safeDiv n d =
  match d
    0 => None
    _ => Some (n / d)

showResult r =
  match r
    None => "error"
    Some x => "ok: \{x}"

main : <IO> Unit
main =
  println (showResult (safeDiv 10 2))
  println (showResult (safeDiv 10 0))
  println (showResult (safeDiv 7 3))
# DESUGAR
(DFunDef false "safeDiv" ((PVar "n") (PVar "d")) (EMatch (EVar "d") (arm (PLit (LInt 0)) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EBinOp "/" (EVar "n") (EVar "d"))))))
(DFunDef false "showResult" ((PVar "r")) (EMatch (EVar "r") (arm (PCon "None") () (ELit (LString "error"))) (arm (PCon "Some" (PVar "x")) () (EBinOp "++" (EBinOp "++" (ELit (LString "ok: ")) (EApp (EVar "display") (EVar "x"))) (ELit (LString ""))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "showResult") (EApp (EApp (EVar "safeDiv") (ELit (LInt 10))) (ELit (LInt 2)))))) (DoExpr (EApp (EVar "println") (EApp (EVar "showResult") (EApp (EApp (EVar "safeDiv") (ELit (LInt 10))) (ELit (LInt 0)))))) (DoExpr (EApp (EVar "println") (EApp (EVar "showResult") (EApp (EApp (EVar "safeDiv") (ELit (LInt 7))) (ELit (LInt 3))))))))
# MARK
(DFunDef false "safeDiv" ((PVar "n") (PVar "d")) (EMatch (EVar "d") (arm (PLit (LInt 0)) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EBinOp "/" (EVar "n") (EVar "d"))))))
(DFunDef false "showResult" ((PVar "r")) (EMatch (EVar "r") (arm (PCon "None") () (ELit (LString "error"))) (arm (PCon "Some" (PVar "x")) () (EBinOp "++" (EBinOp "++" (ELit (LString "ok: ")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString ""))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "showResult") (EApp (EApp (EVar "safeDiv") (ELit (LInt 10))) (ELit (LInt 2)))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "showResult") (EApp (EApp (EVar "safeDiv") (ELit (LInt 10))) (ELit (LInt 0)))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "showResult") (EApp (EApp (EVar "safeDiv") (ELit (LInt 7))) (ELit (LInt 3))))))))
