# META
source_lines=10
stages=PARSE,DESUGAR,MARK
# SOURCE
-- block-form `let` with a type annotation (plain and function-typed)
annotated =
  let p: Int = 5
  let q: Int -> Int = addOne
  q p

-- un-annotated block-let still parses (no regression)
plain =
  let s = 5
  s
# PARSE
(DFunDef false "annotated" () (EBlock (DoLet false false (PVar "p") (EAnnot (ELit (LInt 5)) (TyCon "Int"))) (DoLet false false (PVar "q") (EAnnot (EVar "addOne") (TyFun (TyCon "Int") (TyCon "Int")))) (DoExpr (EApp (EVar "q") (EVar "p")))))
(DFunDef false "plain" () (EBlock (DoLet false false (PVar "s") (ELit (LInt 5))) (DoExpr (EVar "s"))))
# DESUGAR
(DFunDef false "annotated" () (EBlock (DoLet false false (PVar "p") (EAnnot (ELit (LInt 5)) (TyCon "Int"))) (DoLet false false (PVar "q") (EAnnot (EVar "addOne") (TyFun (TyCon "Int") (TyCon "Int")))) (DoExpr (EApp (EVar "q") (EVar "p")))))
(DFunDef false "plain" () (EBlock (DoLet false false (PVar "s") (ELit (LInt 5))) (DoExpr (EVar "s"))))
# MARK
(DFunDef false "annotated" () (EBlock (DoLet false false (PVar "p") (EAnnot (ELit (LInt 5)) (TyCon "Int"))) (DoLet false false (PVar "q") (EAnnot (EVar "addOne") (TyFun (TyCon "Int") (TyCon "Int")))) (DoExpr (EApp (EVar "q") (EVar "p")))))
(DFunDef false "plain" () (EBlock (DoLet false false (PVar "s") (ELit (LInt 5))) (DoExpr (EVar "s"))))
