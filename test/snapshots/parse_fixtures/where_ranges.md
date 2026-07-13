# META
source_lines=19
stages=PARSE,DESUGAR,MARK
# SOURCE
range : Int -> Int -> List Int
range lo hi = [lo..hi]

upto n = [0..=n]

arr = [|1, 2, 3|]

empties = [||]

reverse xs = go xs []
  where
    go [] acc = acc
    go (y::ys) acc = go ys (y :: acc)

permute xs = flatMap (h, rest => map (p => h :: p) rest) (selections xs)

drop n (xs@(_::rest))
  | n <= 0 = xs
  | otherwise = drop (n - 1) rest
# PARSE
(DTypeSig false "range" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "range" ((PVar "lo") (PVar "hi")) (ERangeList (EVar "lo") (EVar "hi") false))
(DFunDef false "upto" ((PVar "n")) (ERangeList (ELit (LInt 0)) (EVar "n") true))
(DFunDef false "arr" () (EArrayLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))
(DFunDef false "empties" () (EArrayLit))
(DFunDef false "reverse" ((PVar "xs")) (ELetGroup ((lgb "go" (clause ((PList) (PVar "acc")) (EVar "acc")) (clause ((PCons (PVar "y") (PVar "ys")) (PVar "acc")) (EApp (EApp (EVar "go") (EVar "ys")) (EBinOp "::" (EVar "y") (EVar "acc")))))) (EApp (EApp (EVar "go") (EVar "xs")) (EListLit))))
(DFunDef false "permute" ((PVar "xs")) (EApp (EApp (EVar "flatMap") (ETuple (EVar "h") (ELam ((PVar "rest")) (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EBinOp "::" (EVar "h") (EVar "p")))) (EVar "rest"))))) (EApp (EVar "selections") (EVar "xs"))))
(DFunDef false "drop" ((PVar "n") (PAs "xs" (PCons PWild (PVar "rest")))) (EGuards (garm ((GBool (EBinOp "<=" (EVar "n") (ELit (LInt 0))))) (EVar "xs")) (garm ((GBool (EVar "otherwise"))) (EApp (EApp (EVar "drop") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest")))))
# DESUGAR
(DTypeSig false "range" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "range" ((PVar "lo") (PVar "hi")) (ERangeList (EVar "lo") (EVar "hi") false))
(DFunDef false "upto" ((PVar "n")) (ERangeList (ELit (LInt 0)) (EVar "n") true))
(DFunDef false "arr" () (EArrayLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))
(DFunDef false "empties" () (EArrayLit))
(DFunDef false "reverse" ((PVar "xs")) (ELetGroup ((lgb "go" (clause ((PList) (PVar "acc")) (EVar "acc")) (clause ((PCons (PVar "y") (PVar "ys")) (PVar "acc")) (EApp (EApp (EVar "go") (EVar "ys")) (EBinOp "::" (EVar "y") (EVar "acc")))))) (EApp (EApp (EVar "go") (EVar "xs")) (EListLit))))
(DFunDef false "permute" ((PVar "xs")) (EApp (EApp (EVar "flatMap") (ETuple (EVar "h") (ELam ((PVar "rest")) (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EBinOp "::" (EVar "h") (EVar "p")))) (EVar "rest"))))) (EApp (EVar "selections") (EVar "xs"))))
(DFunDef false "drop" ((PVar "n") (PAs "xs" (PCons PWild (PVar "rest")))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EVar "xs") (EIf (EVar "otherwise") (EApp (EApp (EVar "drop") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DTypeSig false "range" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "range" ((PVar "lo") (PVar "hi")) (ERangeList (EVar "lo") (EVar "hi") false))
(DFunDef false "upto" ((PVar "n")) (ERangeList (ELit (LInt 0)) (EVar "n") true))
(DFunDef false "arr" () (EArrayLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3))))
(DFunDef false "empties" () (EArrayLit))
(DFunDef false "reverse" ((PVar "xs")) (ELetGroup ((lgb "go" (clause ((PList) (PVar "acc")) (EVar "acc")) (clause ((PCons (PVar "y") (PVar "ys")) (PVar "acc")) (EApp (EApp (EVar "go") (EVar "ys")) (EBinOp "::" (EVar "y") (EVar "acc")))))) (EApp (EApp (EVar "go") (EVar "xs")) (EListLit))))
(DFunDef false "permute" ((PVar "xs")) (EApp (EApp (EDictApp "flatMap") (ETuple (EVar "h") (ELam ((PVar "rest")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EBinOp "::" (EVar "h") (EVar "p")))) (EVar "rest"))))) (EApp (EVar "selections") (EVar "xs"))))
(DFunDef false "drop" ((PVar "n") (PAs "xs" (PCons PWild (PVar "rest")))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EVar "xs") (EIf (EVar "otherwise") (EApp (EApp (EVar "drop") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
