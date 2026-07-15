# META
source_lines=9
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
gt x y = x > y
both a b = a && b
either a b = a || b
eq3 a b c = a == b && b == c
cons x xs = x :: xs
catAll a b c = a ++ b ++ c
classify n = if n < 0 then "neg" else "nonneg"
wrap x y = x
  :: y
# PARSE
(DFunDef false "gt" ((PVar "x") (PVar "y")) (EBinOp ">" (EVar "x") (EVar "y")))
(DFunDef false "both" ((PVar "a") (PVar "b")) (EBinOp "&&" (EVar "a") (EVar "b")))
(DFunDef false "either" ((PVar "a") (PVar "b")) (EBinOp "||" (EVar "a") (EVar "b")))
(DFunDef false "eq3" ((PVar "a") (PVar "b") (PVar "c")) (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EBinOp "==" (EVar "b") (EVar "c"))))
(DFunDef false "cons" ((PVar "x") (PVar "xs")) (EBinOp "::" (EVar "x") (EVar "xs")))
(DFunDef false "catAll" ((PVar "a") (PVar "b") (PVar "c")) (EBinOp "++" (EBinOp "++" (EVar "a") (EVar "b")) (EVar "c")))
(DFunDef false "classify" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (ELit (LString "neg")) (ELit (LString "nonneg"))))
(DFunDef false "wrap" ((PVar "x") (PVar "y")) (EBinOp "::" (EVar "x") (EVar "y")))
# PRINTER
gt x y = x > y
both a b = a && b
either a b = a || b
eq3 a b c = a == b && b == c
cons x xs = x::xs
catAll a b c = a ++ b ++ c
classify n = if n < 0 then "neg" else "nonneg"
wrap x y = x::y
# DESUGAR
(DFunDef false "gt" ((PVar "x") (PVar "y")) (EBinOp ">" (EVar "x") (EVar "y")))
(DFunDef false "both" ((PVar "a") (PVar "b")) (EBinOp "&&" (EVar "a") (EVar "b")))
(DFunDef false "either" ((PVar "a") (PVar "b")) (EBinOp "||" (EVar "a") (EVar "b")))
(DFunDef false "eq3" ((PVar "a") (PVar "b") (PVar "c")) (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EBinOp "==" (EVar "b") (EVar "c"))))
(DFunDef false "cons" ((PVar "x") (PVar "xs")) (EBinOp "::" (EVar "x") (EVar "xs")))
(DFunDef false "catAll" ((PVar "a") (PVar "b") (PVar "c")) (EBinOp "++" (EBinOp "++" (EVar "a") (EVar "b")) (EVar "c")))
(DFunDef false "classify" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (ELit (LString "neg")) (ELit (LString "nonneg"))))
(DFunDef false "wrap" ((PVar "x") (PVar "y")) (EBinOp "::" (EVar "x") (EVar "y")))
# MARK
(DFunDef false "gt#shadow" ((PVar "x") (PVar "y")) (EBinOp ">" (EVar "x") (EVar "y")))
(DFunDef false "both" ((PVar "a") (PVar "b")) (EBinOp "&&" (EVar "a") (EVar "b")))
(DFunDef false "either" ((PVar "a") (PVar "b")) (EBinOp "||" (EVar "a") (EVar "b")))
(DFunDef false "eq3" ((PVar "a") (PVar "b") (PVar "c")) (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EBinOp "==" (EVar "b") (EVar "c"))))
(DFunDef false "cons" ((PVar "x") (PVar "xs")) (EBinOp "::" (EVar "x") (EVar "xs")))
(DFunDef false "catAll" ((PVar "a") (PVar "b") (PVar "c")) (EBinOp "++" (EBinOp "++" (EVar "a") (EVar "b")) (EVar "c")))
(DFunDef false "classify" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (ELit (LString "neg")) (ELit (LString "nonneg"))))
(DFunDef false "wrap" ((PVar "x") (PVar "y")) (EBinOp "::" (EVar "x") (EVar "y")))
