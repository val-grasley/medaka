# META
source_lines=9
stages=PARSE,DESUGAR,MARK
# SOURCE
joined = [1] ++ [2] ++ [3]
trailing = [1] ++
  [2] ++
  [3]
consJoined = 1 :: 2 :: rest
consTrailing = 1 ::
  2 ::
  rest
rest = []
# PARSE
(DFunDef false "joined" () (EBinOp "++" (EBinOp "++" (EListLit (ELit (LInt 1))) (EListLit (ELit (LInt 2)))) (EListLit (ELit (LInt 3)))))
(DFunDef false "trailing" () (EBinOp "++" (EBinOp "++" (EListLit (ELit (LInt 1))) (EListLit (ELit (LInt 2)))) (EListLit (ELit (LInt 3)))))
(DFunDef false "consJoined" () (EBinOp "::" (ELit (LInt 1)) (EBinOp "::" (ELit (LInt 2)) (EVar "rest"))))
(DFunDef false "consTrailing" () (EBinOp "::" (ELit (LInt 1)) (EBinOp "::" (ELit (LInt 2)) (EVar "rest"))))
(DFunDef false "rest" () (EListLit))
# DESUGAR
(DFunDef false "joined" () (EBinOp "++" (EBinOp "++" (EListLit (ELit (LInt 1))) (EListLit (ELit (LInt 2)))) (EListLit (ELit (LInt 3)))))
(DFunDef false "trailing" () (EBinOp "++" (EBinOp "++" (EListLit (ELit (LInt 1))) (EListLit (ELit (LInt 2)))) (EListLit (ELit (LInt 3)))))
(DFunDef false "consJoined" () (EBinOp "::" (ELit (LInt 1)) (EBinOp "::" (ELit (LInt 2)) (EVar "rest"))))
(DFunDef false "consTrailing" () (EBinOp "::" (ELit (LInt 1)) (EBinOp "::" (ELit (LInt 2)) (EVar "rest"))))
(DFunDef false "rest" () (EListLit))
# MARK
(DFunDef false "joined" () (EBinOp "++" (EBinOp "++" (EListLit (ELit (LInt 1))) (EListLit (ELit (LInt 2)))) (EListLit (ELit (LInt 3)))))
(DFunDef false "trailing" () (EBinOp "++" (EBinOp "++" (EListLit (ELit (LInt 1))) (EListLit (ELit (LInt 2)))) (EListLit (ELit (LInt 3)))))
(DFunDef false "consJoined" () (EBinOp "::" (ELit (LInt 1)) (EBinOp "::" (ELit (LInt 2)) (EVar "rest"))))
(DFunDef false "consTrailing" () (EBinOp "::" (ELit (LInt 1)) (EBinOp "::" (ELit (LInt 2)) (EVar "rest"))))
(DFunDef false "rest" () (EListLit))
