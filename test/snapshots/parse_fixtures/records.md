# META
source_lines=11
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
mk x y = Point { x = x, y = y }

shift p = { p | x = p.x + 1, y = p.y - 1 }

neg n = -n

twice n = -n + -n

annotated = (xs : List Int)

wildLam = acc _ => acc
# PARSE
(DFunDef false "mk" ((PVar "x") (PVar "y")) (ERecordCreate "Point" ((fa "x" (EVar "x")) (fa "y" (EVar "y")))))
(DFunDef false "shift" ((PVar "p")) (ERecordUpdate (EVar "p") ((fa "x" (EBinOp "+" (EFieldAccess (EVar "p") "x") (ELit (LInt 1)))) (fa "y" (EBinOp "-" (EFieldAccess (EVar "p") "y") (ELit (LInt 1)))))))
(DFunDef false "neg" ((PVar "n")) (EUnOp "-" (EVar "n")))
(DFunDef false "twice" ((PVar "n")) (EBinOp "+" (EUnOp "-" (EVar "n")) (EUnOp "-" (EVar "n"))))
(DFunDef false "annotated" () (EAnnot (EVar "xs") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "wildLam" () (ELam ((PVar "acc") PWild) (EVar "acc")))
# PRINTER
mk x y = Point { x = x, y = y }
shift p = { p | x = p.x + 1, y = p.y - 1 }
neg n = -n
twice n = -n + -n
annotated = xs : List Int
wildLam = acc _ => acc
# DESUGAR
(DFunDef false "mk" ((PVar "x") (PVar "y")) (ERecordCreate "Point" ((fa "x" (EVar "x")) (fa "y" (EVar "y")))))
(DFunDef false "shift" ((PVar "p")) (ERecordUpdate (EVar "p") ((fa "x" (EBinOp "+" (EFieldAccess (EVar "p") "x") (ELit (LInt 1)))) (fa "y" (EBinOp "-" (EFieldAccess (EVar "p") "y") (ELit (LInt 1)))))))
(DFunDef false "neg" ((PVar "n")) (EUnOp "-" (EVar "n")))
(DFunDef false "twice" ((PVar "n")) (EBinOp "+" (EUnOp "-" (EVar "n")) (EUnOp "-" (EVar "n"))))
(DFunDef false "annotated" () (EAnnot (EVar "xs") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "wildLam" () (ELam ((PVar "acc") PWild) (EVar "acc")))
# MARK
(DFunDef false "mk" ((PVar "x") (PVar "y")) (ERecordCreate "Point" ((fa "x" (EVar "x")) (fa "y" (EVar "y")))))
(DFunDef false "shift" ((PVar "p")) (ERecordUpdate (EVar "p") ((fa "x" (EBinOp "+" (EFieldAccess (EVar "p") "x") (ELit (LInt 1)))) (fa "y" (EBinOp "-" (EFieldAccess (EVar "p") "y") (ELit (LInt 1)))))))
(DFunDef false "neg" ((PVar "n")) (EUnOp "-" (EVar "n")))
(DFunDef false "twice" ((PVar "n")) (EBinOp "+" (EUnOp "-" (EVar "n")) (EUnOp "-" (EVar "n"))))
(DFunDef false "annotated" () (EAnnot (EVar "xs") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "wildLam" () (ELam ((PVar "acc") PWild) (EVar "acc")))
