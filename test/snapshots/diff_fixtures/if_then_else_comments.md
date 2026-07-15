# META
source_lines=4
stages=TOKENS,DESUGAR,MARK
# SOURCE
main =
  if True -- condition
  then println "yes" -- then branch
  else println "no" -- else branch
# TOKENS
IDENT "main"
EQUAL
INDENT
IF
UPPER "True"
THEN
IDENT "println"
STRING "yes"
ELSE
IDENT "println"
STRING "no"
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "main" () (EIf (EVar "True") (EApp (EVar "println") (ELit (LString "yes"))) (EApp (EVar "println") (ELit (LString "no")))))
# MARK
(DFunDef false "main" () (EIf (EVar "True") (EApp (EDictApp "println") (ELit (LString "yes"))) (EApp (EDictApp "println") (ELit (LString "no")))))
