# META
source_lines=9
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
i = 42
s = "hello"
u = ()
pair = (1, 2)
triple = (1, 2, 3)
nums = [1, 2, 3]
empty = []
nested = [f x, g y, 7]
ctor = None
# PARSE
(DFunDef false "i" () (ELit (LInt 42)))
(DFunDef false "s" () (ELit (LString "hello")))
(DFunDef false "u" () (ELit LUnit))
(DFunDef false "pair" () (ETuple (ELit (LInt 1)) (ELit (LInt 2))))
(DFunDef false "triple" () (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))
(DFunDef false "nums" () (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))
(DFunDef false "empty" () (EListLit))
(DFunDef false "nested" () (EListLit (EApp (EVar "f") (EVar "x")) (EApp (EVar "g") (EVar "y")) (ELit (LInt 7))))
(DFunDef false "ctor" () (EVar "None"))
# PRINTER
i = 42
s = "hello"
u = ()
pair = (1, 2)
triple = (1, 2, 3)
nums = [1, 2, 3]
empty = []
nested = [f x, g y, 7]
ctor = None
# DESUGAR
(DFunDef false "i" () (ELit (LInt 42)))
(DFunDef false "s" () (ELit (LString "hello")))
(DFunDef false "u" () (ELit LUnit))
(DFunDef false "pair" () (ETuple (ELit (LInt 1)) (ELit (LInt 2))))
(DFunDef false "triple" () (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))
(DFunDef false "nums" () (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))
(DFunDef false "empty" () (EListLit))
(DFunDef false "nested" () (EListLit (EApp (EVar "f") (EVar "x")) (EApp (EVar "g") (EVar "y")) (ELit (LInt 7))))
(DFunDef false "ctor" () (EVar "None"))
# MARK
(DFunDef false "i" () (ELit (LInt 42)))
(DFunDef false "s" () (ELit (LString "hello")))
(DFunDef false "u" () (ELit LUnit))
(DFunDef false "pair" () (ETuple (ELit (LInt 1)) (ELit (LInt 2))))
(DFunDef false "triple" () (ETuple (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))
(DFunDef false "nums" () (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))
(DFunDef false "empty#shadow" () (EListLit))
(DFunDef false "nested" () (EListLit (EApp (EVar "f") (EVar "x")) (EApp (EVar "g") (EVar "y")) (ELit (LInt 7))))
(DFunDef false "ctor" () (EVar "None"))
