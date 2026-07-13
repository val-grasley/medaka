# META
source_lines=28
stages=PARSE,DESUGAR,MARK
# SOURCE
export interface Eq a where
  eq : a -> a -> Bool

export interface Ord a requires Eq a where
  compare : a -> a -> Ordering
  lte x y = compare x y

export impl Eq Int where
  eq a b = a == b

impl Eq (Option a) requires Eq a where
  eq None None = True
  eq (Some a) (Some b) = eq a b
  eq _ _ = False

impl Debug a where
  debug _ = "?"

clamp lo hi = min hi >> max lo

combine = f << g

deleteAt x count =
  if has x then
    remove x
    setRef count (count.value - 1)

divides a b = mod a b == 0
# PARSE
(DInterface true false "Eq" ("a") () ((imethod "eq" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) None)))
(DInterface true false "Ord" ("a") ((super "Eq" ("a"))) ((imethod "compare" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Ordering"))) None) (imethod "lte" (TyVar "_") (mdef ((PVar "x") (PVar "y")) (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y"))))))
(DImpl true "Eq" ((TyCon "Int")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl false "Eq" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "None") (PCon "None")) (EVar "True")) (im "eq" ((PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) (EApp (EApp (EVar "eq") (EVar "a")) (EVar "b"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl false "Debug" ((TyVar "a")) () ((im "debug" (PWild) (ELit (LString "?")))))
(DFunDef false "clamp" ((PVar "lo") (PVar "hi")) (EBinOp ">>" (EApp (EVar "min") (EVar "hi")) (EApp (EVar "max") (EVar "lo"))))
(DFunDef false "combine" () (EBinOp "<<" (EVar "f") (EVar "g")))
(DFunDef false "deleteAt" ((PVar "x") (PVar "count")) (EIf (EApp (EVar "has") (EVar "x")) (EBlock (DoExpr (EApp (EVar "remove") (EVar "x"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "-" (EFieldAccess (EVar "count") "value") (ELit (LInt 1)))))) (ELit LUnit)))
(DFunDef false "divides" ((PVar "a") (PVar "b")) (EBinOp "==" (EApp (EApp (EVar "mod") (EVar "a")) (EVar "b")) (ELit (LInt 0))))
# DESUGAR
(DInterface true false "Eq" ("a") () ((imethod "eq" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) None)))
(DInterface true false "Ord" ("a") ((super "Eq" ("a"))) ((imethod "compare" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Ordering"))) None) (imethod "lte" (TyVar "_") (mdef ((PVar "x") (PVar "y")) (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y"))))))
(DImpl true "Eq" ((TyCon "Int")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl false "Eq" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "None") (PCon "None")) (EVar "True")) (im "eq" ((PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) (EApp (EApp (EVar "eq") (EVar "a")) (EVar "b"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl false "Debug" ((TyVar "a")) () ((im "debug" (PWild) (ELit (LString "?")))))
(DFunDef false "clamp" ((PVar "lo") (PVar "hi")) (EBinOp ">>" (EApp (EVar "min") (EVar "hi")) (EApp (EVar "max") (EVar "lo"))))
(DFunDef false "combine" () (EBinOp "<<" (EVar "f") (EVar "g")))
(DFunDef false "deleteAt" ((PVar "x") (PVar "count")) (EIf (EApp (EVar "has") (EVar "x")) (EBlock (DoExpr (EApp (EVar "remove") (EVar "x"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "-" (EFieldAccess (EVar "count") "value") (ELit (LInt 1)))))) (ELit LUnit)))
(DFunDef false "divides" ((PVar "a") (PVar "b")) (EBinOp "==" (EApp (EApp (EVar "mod") (EVar "a")) (EVar "b")) (ELit (LInt 0))))
# MARK
(DInterface true false "Eq" ("a") () ((imethod "eq" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool"))) None)))
(DInterface true false "Ord" ("a") ((super "Eq" ("a"))) ((imethod "compare" (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Ordering"))) None) (imethod "lte" (TyVar "_") (mdef ((PVar "x") (PVar "y")) (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y"))))))
(DImpl true "Eq" ((TyCon "Int")) () ((im "eq" ((PVar "a") (PVar "b")) (EBinOp "==" (EVar "a") (EVar "b")))))
(DImpl false "Eq" ((TyApp (TyCon "Option") (TyVar "a"))) ((req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "None") (PCon "None")) (EVar "True")) (im "eq" ((PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) (EApp (EApp (EMethodRef "eq") (EVar "a")) (EVar "b"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl false "Debug" ((TyVar "a")) () ((im "debug" (PWild) (ELit (LString "?")))))
(DFunDef false "clamp" ((PVar "lo") (PVar "hi")) (EBinOp ">>" (EApp (EMethodRef "min") (EVar "hi")) (EApp (EMethodRef "max") (EVar "lo"))))
(DFunDef false "combine" () (EBinOp "<<" (EVar "f") (EVar "g")))
(DFunDef false "deleteAt" ((PVar "x") (PVar "count")) (EIf (EApp (EVar "has") (EVar "x")) (EBlock (DoExpr (EApp (EVar "remove") (EVar "x"))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (EBinOp "-" (EFieldAccess (EDictApp "count") "value") (ELit (LInt 1)))))) (ELit LUnit)))
(DFunDef false "divides" ((PVar "a") (PVar "b")) (EBinOp "==" (EApp (EApp (EVar "mod") (EVar "a")) (EVar "b")) (ELit (LInt 0))))
