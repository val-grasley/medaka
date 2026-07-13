# META
source_lines=7
stages=DESUGAR,MARK
# SOURCE
main =
  if True
  then
    if False
    then println "a"
    else println "b"
  else println "c"
# DESUGAR
(DFunDef false "main" () (EIf (EVar "True") (EIf (EVar "False") (EApp (EVar "println") (ELit (LString "a"))) (EApp (EVar "println") (ELit (LString "b")))) (EApp (EVar "println") (ELit (LString "c")))))
# MARK
(DFunDef false "main" () (EIf (EVar "True") (EIf (EVar "False") (EApp (EDictApp "println") (ELit (LString "a"))) (EApp (EDictApp "println") (ELit (LString "b")))) (EApp (EDictApp "println") (ELit (LString "c")))))
