# META
source_lines=6
stages=PARSE,DESUGAR,MARK
# SOURCE
a = 1e12
b = 1.5e10
c = 9e+15
d = 1e-05
e = 2E3
f = 1_000e1_0
# PARSE
(DFunDef false "a" () (ELit (LFloat 1e+12)))
(DFunDef false "b" () (ELit (LFloat 15000000000.0)))
(DFunDef false "c" () (ELit (LFloat 9e+15)))
(DFunDef false "d" () (ELit (LFloat 1e-05)))
(DFunDef false "e" () (ELit (LFloat 2000.0)))
(DFunDef false "f" () (ELit (LFloat 1e+13)))
# DESUGAR
(DFunDef false "a" () (ELit (LFloat 1e+12)))
(DFunDef false "b" () (ELit (LFloat 15000000000.0)))
(DFunDef false "c" () (ELit (LFloat 9e+15)))
(DFunDef false "d" () (ELit (LFloat 1e-05)))
(DFunDef false "e" () (ELit (LFloat 2000.0)))
(DFunDef false "f" () (ELit (LFloat 1e+13)))
# MARK
(DFunDef false "a" () (ELit (LFloat 1e+12)))
(DFunDef false "b" () (ELit (LFloat 15000000000.0)))
(DFunDef false "c" () (ELit (LFloat 9e+15)))
(DFunDef false "d" () (ELit (LFloat 1e-05)))
(DFunDef false "e" () (ELit (LFloat 2000.0)))
(DFunDef false "f" () (ELit (LFloat 1e+13)))
