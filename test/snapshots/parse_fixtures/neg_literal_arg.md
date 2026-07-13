# META
source_lines=16
stages=PARSE,DESUGAR,MARK
# SOURCE
g x = x + 100
f a b c = a + b + c

classify n = match n
  -5 ..= -1 => "lowneg"
  _ => "other"

main =
  let a = g -1
  let b = f 10 -1 5
  let c = 5 -1
  let d = if True then -1 else 0
  let e = [-1, -2]
  let k = Err -2
  let m = classify -3
  println (a + b + c + d + sum e)
# PARSE
(DFunDef false "g" ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 100))))
(DFunDef false "f" ((PVar "a") (PVar "b") (PVar "c")) (EBinOp "+" (EBinOp "+" (EVar "a") (EVar "b")) (EVar "c")))
(DFunDef false "classify" ((PVar "n")) (EMatch (EVar "n") (arm (PRng (LInt -5) (LInt -1) true) () (ELit (LString "lowneg"))) (arm PWild () (ELit (LString "other")))))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "a") (EApp (EVar "g") (ELit (LInt -1)))) (DoLet false false (PVar "b") (EApp (EApp (EApp (EVar "f") (ELit (LInt 10))) (ELit (LInt -1))) (ELit (LInt 5)))) (DoLet false false (PVar "c") (EBinOp "-" (ELit (LInt 5)) (ELit (LInt 1)))) (DoLet false false (PVar "d") (EIf (EVar "True") (EUnOp "-" (ELit (LInt 1))) (ELit (LInt 0)))) (DoLet false false (PVar "e") (EListLit (EUnOp "-" (ELit (LInt 1))) (EUnOp "-" (ELit (LInt 2))))) (DoLet false false (PVar "k") (EApp (EVar "Err") (ELit (LInt -2)))) (DoLet false false (PVar "m") (EApp (EVar "classify") (ELit (LInt -3)))) (DoExpr (EApp (EVar "println") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "+" (EVar "a") (EVar "b")) (EVar "c")) (EVar "d")) (EApp (EVar "sum") (EVar "e")))))))
# DESUGAR
(DFunDef false "g" ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 100))))
(DFunDef false "f" ((PVar "a") (PVar "b") (PVar "c")) (EBinOp "+" (EBinOp "+" (EVar "a") (EVar "b")) (EVar "c")))
(DFunDef false "classify" ((PVar "n")) (EMatch (EVar "n") (arm (PRng (LInt -5) (LInt -1) true) () (ELit (LString "lowneg"))) (arm PWild () (ELit (LString "other")))))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "a") (EApp (EVar "g") (ELit (LInt -1)))) (DoLet false false (PVar "b") (EApp (EApp (EApp (EVar "f") (ELit (LInt 10))) (ELit (LInt -1))) (ELit (LInt 5)))) (DoLet false false (PVar "c") (EBinOp "-" (ELit (LInt 5)) (ELit (LInt 1)))) (DoLet false false (PVar "d") (EIf (EVar "True") (EUnOp "-" (ELit (LInt 1))) (ELit (LInt 0)))) (DoLet false false (PVar "e") (EListLit (EUnOp "-" (ELit (LInt 1))) (EUnOp "-" (ELit (LInt 2))))) (DoLet false false (PVar "k") (EApp (EVar "Err") (ELit (LInt -2)))) (DoLet false false (PVar "m") (EApp (EVar "classify") (ELit (LInt -3)))) (DoExpr (EApp (EVar "println") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "+" (EVar "a") (EVar "b")) (EVar "c")) (EVar "d")) (EApp (EVar "sum") (EVar "e")))))))
# MARK
(DFunDef false "g" ((PVar "x")) (EBinOp "+" (EVar "x") (ELit (LInt 100))))
(DFunDef false "f" ((PVar "a") (PVar "b") (PVar "c")) (EBinOp "+" (EBinOp "+" (EVar "a") (EVar "b")) (EVar "c")))
(DFunDef false "classify" ((PVar "n")) (EMatch (EVar "n") (arm (PRng (LInt -5) (LInt -1) true) () (ELit (LString "lowneg"))) (arm PWild () (ELit (LString "other")))))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "a") (EApp (EVar "g") (ELit (LInt -1)))) (DoLet false false (PVar "b") (EApp (EApp (EApp (EVar "f") (ELit (LInt 10))) (ELit (LInt -1))) (ELit (LInt 5)))) (DoLet false false (PVar "c") (EBinOp "-" (ELit (LInt 5)) (ELit (LInt 1)))) (DoLet false false (PVar "d") (EIf (EVar "True") (EUnOp "-" (ELit (LInt 1))) (ELit (LInt 0)))) (DoLet false false (PVar "e") (EListLit (EUnOp "-" (ELit (LInt 1))) (EUnOp "-" (ELit (LInt 2))))) (DoLet false false (PVar "k") (EApp (EVar "Err") (ELit (LInt -2)))) (DoLet false false (PVar "m") (EApp (EVar "classify") (ELit (LInt -3)))) (DoExpr (EApp (EDictApp "println") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "+" (EVar "a") (EVar "b")) (EVar "c")) (EVar "d")) (EApp (EDictApp "sum") (EVar "e")))))))
