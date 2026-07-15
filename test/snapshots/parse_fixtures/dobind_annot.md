# META
source_lines=7
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
-- do-bind with a type annotation on the bound var: binds the var AND
-- (via the shadowing annotated let) enforces its declared type
compute =
  do
    x: Int <- fetch
    y <- other
    wrap (x + y)
# PARSE
(DFunDef false "compute" () (EDo (DoBind (PVar "x") (EVar "fetch")) (DoLet false false (PVar "x") (EAnnot (EVar "x") (TyCon "Int"))) (DoBind (PVar "y") (EVar "other")) (DoExpr (EApp (EVar "wrap") (EBinOp "+" (EVar "x") (EVar "y"))))))
# PRINTER
compute = do
  x <- fetch
  let x = x : Int
  y <- other
  wrap (x + y)
# DESUGAR
(DFunDef false "compute" () (EApp (EApp (EVar "andThen") (EVar "fetch")) (ELam ((PVar "x")) (ELet false (PVar "x") (EAnnot (EVar "x") (TyCon "Int")) (EApp (EApp (EVar "andThen") (EVar "other")) (ELam ((PVar "y")) (EApp (EVar "wrap") (EBinOp "+" (EVar "x") (EVar "y")))))))))
# MARK
(DFunDef false "compute" () (EApp (EApp (EMethodRef "andThen") (EVar "fetch")) (ELam ((PVar "x")) (ELet false (PVar "x") (EAnnot (EVar "x") (TyCon "Int")) (EApp (EApp (EMethodRef "andThen") (EVar "other")) (ELam ((PVar "y")) (EApp (EVar "wrap") (EBinOp "+" (EVar "x") (EVar "y")))))))))
