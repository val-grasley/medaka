# META
source_lines=5
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
greet name = "hello, \{name}"
report n = "got \{n} items"
math a b = "sum = \{a + b}"
multi x y = "x=\{x} y=\{y}!"
nested f x = "result: \{f x}"
# PARSE
(DFunDef false "greet" ((PVar "name")) (EStringInterp (InterpStr "hello, ") (InterpExpr (EVar "name")) (InterpStr "")))
(DFunDef false "report" ((PVar "n")) (EStringInterp (InterpStr "got ") (InterpExpr (EVar "n")) (InterpStr " items")))
(DFunDef false "math" ((PVar "a") (PVar "b")) (EStringInterp (InterpStr "sum = ") (InterpExpr (EBinOp "+" (EVar "a") (EVar "b"))) (InterpStr "")))
(DFunDef false "multi" ((PVar "x") (PVar "y")) (EStringInterp (InterpStr "x=") (InterpExpr (EVar "x")) (InterpStr " y=") (InterpExpr (EVar "y")) (InterpStr "!")))
(DFunDef false "nested" ((PVar "f") (PVar "x")) (EStringInterp (InterpStr "result: ") (InterpExpr (EApp (EVar "f") (EVar "x"))) (InterpStr "")))
# PRINTER
greet name = "hello, \{name}"
report n = "got \{n} items"
math a b = "sum = \{a + b}"
multi x y = "x=\{x} y=\{y}!"
nested f x = "result: \{f x}"
# DESUGAR
(DFunDef false "greet" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "hello, ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "report" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "got ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString " items"))))
(DFunDef false "math" ((PVar "a") (PVar "b")) (EBinOp "++" (EBinOp "++" (ELit (LString "sum = ")) (EApp (EVar "display") (EBinOp "+" (EVar "a") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "multi" ((PVar "x") (PVar "y")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "x=")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " y="))) (EApp (EVar "display") (EVar "y"))) (ELit (LString "!"))))
(DFunDef false "nested" ((PVar "f") (PVar "x")) (EBinOp "++" (EBinOp "++" (ELit (LString "result: ")) (EApp (EVar "display") (EApp (EVar "f") (EVar "x")))) (ELit (LString ""))))
# MARK
(DFunDef false "greet" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "hello, ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "report" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "got ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " items"))))
(DFunDef false "math" ((PVar "a") (PVar "b")) (EBinOp "++" (EBinOp "++" (ELit (LString "sum = ")) (EApp (EMethodRef "display") (EBinOp "+" (EVar "a") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "multi" ((PVar "x") (PVar "y")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "x=")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " y="))) (EApp (EMethodRef "display") (EVar "y"))) (ELit (LString "!"))))
(DFunDef false "nested" ((PVar "f") (PVar "x")) (EBinOp "++" (EBinOp "++" (ELit (LString "result: ")) (EApp (EMethodRef "display") (EApp (EVar "f") (EVar "x")))) (ELit (LString ""))))
