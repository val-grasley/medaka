# META
source_lines=9
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
greet name =
  let msg = name
  println msg
  println name

compute a b =
  let s = a + b
  let p = a * b
  s + p
# PARSE
(DFunDef false "greet" ((PVar "name")) (EBlock (DoLet false false (PVar "msg") (EVar "name")) (DoExpr (EApp (EVar "println") (EVar "msg"))) (DoExpr (EApp (EVar "println") (EVar "name")))))
(DFunDef false "compute" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "s") (EBinOp "+" (EVar "a") (EVar "b"))) (DoLet false false (PVar "p") (EBinOp "*" (EVar "a") (EVar "b"))) (DoExpr (EBinOp "+" (EVar "s") (EVar "p")))))
# PRINTER
greet name =
  let msg = name
  println msg
  println name
compute a b =
  let s = a + b
  let p = a * b
  s + p
# DESUGAR
(DFunDef false "greet" ((PVar "name")) (EBlock (DoLet false false (PVar "msg") (EVar "name")) (DoExpr (EApp (EVar "println") (EVar "msg"))) (DoExpr (EApp (EVar "println") (EVar "name")))))
(DFunDef false "compute" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "s") (EBinOp "+" (EVar "a") (EVar "b"))) (DoLet false false (PVar "p") (EBinOp "*" (EVar "a") (EVar "b"))) (DoExpr (EBinOp "+" (EVar "s") (EVar "p")))))
# MARK
(DFunDef false "greet" ((PVar "name")) (EBlock (DoLet false false (PVar "msg") (EVar "name")) (DoExpr (EApp (EDictApp "println") (EVar "msg"))) (DoExpr (EApp (EDictApp "println") (EVar "name")))))
(DFunDef false "compute" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "s") (EBinOp "+" (EVar "a") (EVar "b"))) (DoLet false false (PVar "p") (EBinOp "*" (EVar "a") (EVar "b"))) (DoExpr (EBinOp "+" (EVar "s") (EVar "p")))))
