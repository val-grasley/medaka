# META
source_lines=8
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
sign n
  | n < 0 = "neg"
  | n > 0 = "pos"
  | True = "zero"

firstPos xs
  | x <- head xs, x > 0 = x
  | True = 0
# PARSE
(DFunDef false "sign" ((PVar "n")) (EGuards (garm ((GBool (EBinOp "<" (EVar "n") (ELit (LInt 0))))) (ELit (LString "neg"))) (garm ((GBool (EBinOp ">" (EVar "n") (ELit (LInt 0))))) (ELit (LString "pos"))) (garm ((GBool (EVar "True"))) (ELit (LString "zero")))))
(DFunDef false "firstPos" ((PVar "xs")) (EGuards (garm ((GBind (PVar "x") (EApp (EVar "head") (EVar "xs"))) (GBool (EBinOp ">" (EVar "x") (ELit (LInt 0))))) (EVar "x")) (garm ((GBool (EVar "True"))) (ELit (LInt 0)))))
# PRINTER
sign n
  | n < 0 = "neg"
  | n > 0 = "pos"
  | True = "zero"
firstPos xs
  | x <- head xs, x > 0 = x
  | True = 0
# DESUGAR
(DFunDef false "sign" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (ELit (LString "neg")) (EIf (EBinOp ">" (EVar "n") (ELit (LInt 0))) (ELit (LString "pos")) (EIf (EVar "True") (ELit (LString "zero")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "firstPos" ((PVar "xs")) (EMatch (EApp (EVar "head") (EVar "xs")) (arm (PVar "x") () (EIf (EBinOp ">" (EVar "x") (ELit (LInt 0))) (EVar "x") (EIf (EVar "True") (ELit (LInt 0)) (EApp (EVar "__fallthrough__") (ELit LUnit))))) (arm PWild () (EIf (EVar "True") (ELit (LInt 0)) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
# MARK
(DFunDef false "sign" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (ELit (LString "neg")) (EIf (EBinOp ">" (EVar "n") (ELit (LInt 0))) (ELit (LString "pos")) (EIf (EVar "True") (ELit (LString "zero")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "firstPos" ((PVar "xs")) (EMatch (EApp (EVar "head") (EVar "xs")) (arm (PVar "x") () (EIf (EBinOp ">" (EVar "x") (ELit (LInt 0))) (EVar "x") (EIf (EVar "True") (ELit (LInt 0)) (EApp (EVar "__fallthrough__") (ELit LUnit))))) (arm PWild () (EIf (EVar "True") (ELit (LInt 0)) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
