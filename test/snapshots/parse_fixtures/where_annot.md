# META
source_lines=10
stages=PARSE,DESUGAR,MARK
# SOURCE
-- where binding with a type annotation (`go : ty = body`)
f n = n + go
  where
    go: Int = 5

-- un-annotated + multi-clause where still coalesce (no regression)
g x = h x
  where
    h 0 = 1
    h k = k * 2
# PARSE
(DFunDef false "f" ((PVar "n")) (ELetGroup ((lgb "go" (clause () (EAnnot (ELit (LInt 5)) (TyCon "Int"))))) (EBinOp "+" (EVar "n") (EVar "go"))))
(DFunDef false "g" ((PVar "x")) (ELetGroup ((lgb "h" (clause ((PLit (LInt 0))) (ELit (LInt 1))) (clause ((PVar "k")) (EBinOp "*" (EVar "k") (ELit (LInt 2)))))) (EApp (EVar "h") (EVar "x"))))
# DESUGAR
(DFunDef false "f" ((PVar "n")) (ELetGroup ((lgb "go" (clause () (EAnnot (ELit (LInt 5)) (TyCon "Int"))))) (EBinOp "+" (EVar "n") (EVar "go"))))
(DFunDef false "g" ((PVar "x")) (ELetGroup ((lgb "h" (clause ((PLit (LInt 0))) (ELit (LInt 1))) (clause ((PVar "k")) (EBinOp "*" (EVar "k") (ELit (LInt 2)))))) (EApp (EVar "h") (EVar "x"))))
# MARK
(DFunDef false "f" ((PVar "n")) (ELetGroup ((lgb "go" (clause () (EAnnot (ELit (LInt 5)) (TyCon "Int"))))) (EBinOp "+" (EVar "n") (EVar "go"))))
(DFunDef false "g" ((PVar "x")) (ELetGroup ((lgb "h" (clause ((PLit (LInt 0))) (ELit (LInt 1))) (clause ((PVar "k")) (EBinOp "*" (EVar "k") (ELit (LInt 2)))))) (EApp (EVar "h") (EVar "x"))))
