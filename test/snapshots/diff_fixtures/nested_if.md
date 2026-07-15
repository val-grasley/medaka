# META
source_lines=7
stages=TOKENS,DESUGAR,MARK
# SOURCE
main =
  if True
  then
    if False
    then println "a"
    else println "b"
  else println "c"
# TOKENS
IDENT "main"
EQUAL
INDENT
IF
UPPER "True"
THEN
INDENT
IF
UPPER "False"
THEN
IDENT "println"
STRING "a"
ELSE
IDENT "println"
STRING "b"
NEWLINE
DEDENT
ELSE
IDENT "println"
STRING "c"
NEWLINE
DEDENT
NEWLINE
NEWLINE
EOF
# DESUGAR
(DFunDef false "main" () (EIf (EVar "True") (EIf (EVar "False") (EApp (EVar "println") (ELit (LString "a"))) (EApp (EVar "println") (ELit (LString "b")))) (EApp (EVar "println") (ELit (LString "c")))))
# MARK
(DFunDef false "main" () (EIf (EVar "True") (EIf (EVar "False") (EApp (EDictApp "println") (ELit (LString "a"))) (EApp (EDictApp "println") (ELit (LString "b")))) (EApp (EDictApp "println") (ELit (LString "c")))))
