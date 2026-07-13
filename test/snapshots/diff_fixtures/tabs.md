# META
source_lines=4
stages=DESUGAR,MARK
# SOURCE
main =
	if True
	then println "yes"
	else println "no"
# DESUGAR
(DFunDef false "main" () (EIf (EVar "True") (EApp (EVar "println") (ELit (LString "yes"))) (EApp (EVar "println") (ELit (LString "no")))))
# MARK
(DFunDef false "main" () (EIf (EVar "True") (EApp (EDictApp "println") (ELit (LString "yes"))) (EApp (EDictApp "println") (ELit (LString "no")))))
