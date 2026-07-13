# META
source_lines=13
stages=DESUGAR,MARK
# SOURCE
data Point = { x : Int, y : Int } deriving (Eq, Ord, Debug)

main =
  let p1 = Point { x = 1, y = 2 }
  let p2 = Point { x = 1, y = 2 }
  let p3 = Point { x = 1, y = 9 }
  let p4 = Point { x = 2, y = 0 }
  println (p1 == p2)
  println (p1 == p3)
  println (compare p3 p4)
  println (compare p1 p2)
  println (compare p4 p3)
  println (debug p1)
# DESUGAR
(DData Private "Point" () ((variant "Point" (ConNamed (field "x" (TyCon "Int")) (field "y" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "Point")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Point" ((rf "x" (PVar "__a0")) (rf "y" (PVar "__a1"))) false) (PRec "Point" ((rf "x" (PVar "__b0")) (rf "y" (PVar "__b1"))) false)) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Ord" ((TyCon "Point")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Point" ((rf "x" (PVar "__a0")) (rf "y" (PVar "__a1"))) false) (PRec "Point" ((rf "x" (PVar "__b0")) (rf "y" (PVar "__b1"))) false)) () (EMatch (EApp (EApp (EVar "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EApp (EApp (EVar "compare") (EVar "__a1")) (EVar "__b1"))) (arm (PVar "__c") () (EVar "__c"))))))))
(DImpl true "Debug" ((TyCon "Point")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Point" ((rf "x" (PVar "__a0")) (rf "y" (PVar "__a1"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Point {")) (ELit (LString " x = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", y = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString " }"))))))))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "p1") (ERecordCreate "Point" ((fa "x" (ELit (LInt 1))) (fa "y" (ELit (LInt 2)))))) (DoLet false false (PVar "p2") (ERecordCreate "Point" ((fa "x" (ELit (LInt 1))) (fa "y" (ELit (LInt 2)))))) (DoLet false false (PVar "p3") (ERecordCreate "Point" ((fa "x" (ELit (LInt 1))) (fa "y" (ELit (LInt 9)))))) (DoLet false false (PVar "p4") (ERecordCreate "Point" ((fa "x" (ELit (LInt 2))) (fa "y" (ELit (LInt 0)))))) (DoExpr (EApp (EVar "println") (EBinOp "==" (EVar "p1") (EVar "p2")))) (DoExpr (EApp (EVar "println") (EBinOp "==" (EVar "p1") (EVar "p3")))) (DoExpr (EApp (EVar "println") (EApp (EApp (EVar "compare") (EVar "p3")) (EVar "p4")))) (DoExpr (EApp (EVar "println") (EApp (EApp (EVar "compare") (EVar "p1")) (EVar "p2")))) (DoExpr (EApp (EVar "println") (EApp (EApp (EVar "compare") (EVar "p4")) (EVar "p3")))) (DoExpr (EApp (EVar "println") (EApp (EVar "debug") (EVar "p1"))))))
# MARK
(DData Private "Point" () ((variant "Point" (ConNamed (field "x" (TyCon "Int")) (field "y" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "Point")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Point" ((rf "x" (PVar "__a0")) (rf "y" (PVar "__a1"))) false) (PRec "Point" ((rf "x" (PVar "__b0")) (rf "y" (PVar "__b1"))) false)) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Ord" ((TyCon "Point")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Point" ((rf "x" (PVar "__a0")) (rf "y" (PVar "__a1"))) false) (PRec "Point" ((rf "x" (PVar "__b0")) (rf "y" (PVar "__b1"))) false)) () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EApp (EApp (EMethodRef "compare") (EVar "__a1")) (EVar "__b1"))) (arm (PVar "__c") () (EVar "__c"))))))))
(DImpl true "Debug" ((TyCon "Point")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Point" ((rf "x" (PVar "__a0")) (rf "y" (PVar "__a1"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Point {")) (ELit (LString " x = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", y = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString " }"))))))))
(DFunDef false "main" () (EBlock (DoLet false false (PVar "p1") (ERecordCreate "Point" ((fa "x" (ELit (LInt 1))) (fa "y" (ELit (LInt 2)))))) (DoLet false false (PVar "p2") (ERecordCreate "Point" ((fa "x" (ELit (LInt 1))) (fa "y" (ELit (LInt 2)))))) (DoLet false false (PVar "p3") (ERecordCreate "Point" ((fa "x" (ELit (LInt 1))) (fa "y" (ELit (LInt 9)))))) (DoLet false false (PVar "p4") (ERecordCreate "Point" ((fa "x" (ELit (LInt 2))) (fa "y" (ELit (LInt 0)))))) (DoExpr (EApp (EDictApp "println") (EBinOp "==" (EVar "p1") (EVar "p2")))) (DoExpr (EApp (EDictApp "println") (EBinOp "==" (EVar "p1") (EVar "p3")))) (DoExpr (EApp (EDictApp "println") (EApp (EApp (EMethodRef "compare") (EVar "p3")) (EVar "p4")))) (DoExpr (EApp (EDictApp "println") (EApp (EApp (EMethodRef "compare") (EVar "p1")) (EVar "p2")))) (DoExpr (EApp (EDictApp "println") (EApp (EApp (EMethodRef "compare") (EVar "p4")) (EVar "p3")))) (DoExpr (EApp (EDictApp "println") (EApp (EMethodRef "debug") (EVar "p1"))))))
