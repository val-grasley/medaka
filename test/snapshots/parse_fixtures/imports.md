# META
source_lines=19
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
import core.{Eq, Ord, Option}
import list.{reverse}
export import string.{join, Foo(..)}
import utils.helper
import utils.*
import utils as U

extern putStr : String -> <IO> Unit
extern Ref : a -> Ref a

export
neq : Eq a => a -> a -> Bool
neq x y = not (eq x y)

export
clampMin : Ord a => a -> a -> a
clampMin lo x
  | x < lo = lo
  | True = x
# PARSE
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Option" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse true (UseGroup ("string") ((mem "join" false) (mem "Foo" true))))
(DUse false (UseName ("utils" "helper")))
(DUse false (UseWild ("utils")))
(DUse false (UseAlias ("utils") "U"))
(DExtern false "putStr" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DExtern false "Ref" (TyFun (TyVar "a") (TyApp (TyCon "Ref") (TyVar "a"))))
(DTypeSig true "neq" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool")))))
(DFunDef false "neq" ((PVar "x") (PVar "y")) (EApp (EVar "not") (EApp (EApp (EVar "eq") (EVar "x")) (EVar "y"))))
(DTypeSig true "clampMin" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))))
(DFunDef false "clampMin" ((PVar "lo") (PVar "x")) (EGuards (garm ((GBool (EBinOp "<" (EVar "x") (EVar "lo")))) (EVar "lo")) (garm ((GBool (EVar "True"))) (EVar "x"))))
# PRINTER
import core.{Eq, Ord, Option}
import list.{reverse}
export import string.{join, Foo(..)}
import utils.helper
import utils.*
import utils as U
extern putStr : String -> <IO> Unit
extern Ref : a -> Ref a
export neq : Eq a => a -> a -> Bool
neq x y = not (eq x y)
export clampMin : Ord a => a -> a -> a
clampMin lo x
  | x < lo = lo
  | True = x
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Option" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse true (UseGroup ("string") ((mem "join" false) (mem "Foo" true))))
(DUse false (UseName ("utils" "helper")))
(DUse false (UseWild ("utils")))
(DUse false (UseAlias ("utils") "U"))
(DExtern false "putStr" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DExtern false "Ref" (TyFun (TyVar "a") (TyApp (TyCon "Ref") (TyVar "a"))))
(DTypeSig true "neq" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool")))))
(DFunDef false "neq" ((PVar "x") (PVar "y")) (EApp (EVar "not") (EApp (EApp (EVar "eq") (EVar "x")) (EVar "y"))))
(DTypeSig true "clampMin" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))))
(DFunDef false "clampMin" ((PVar "lo") (PVar "x")) (EIf (EBinOp "<" (EVar "x") (EVar "lo")) (EVar "lo") (EIf (EVar "True") (EVar "x") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("core") ((mem "Eq" false) (mem "Ord" false) (mem "Option" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse true (UseGroup ("string") ((mem "join" false) (mem "Foo" true))))
(DUse false (UseName ("utils" "helper")))
(DUse false (UseWild ("utils")))
(DUse false (UseAlias ("utils") "U"))
(DExtern false "putStr" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DExtern false "Ref" (TyFun (TyVar "a") (TyApp (TyCon "Ref") (TyVar "a"))))
(DTypeSig true "neq" (TyConstrained ((cstr "Eq" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Bool")))))
(DFunDef false "neq" ((PVar "x") (PVar "y")) (EApp (EVar "not") (EApp (EApp (EMethodRef "eq") (EVar "x")) (EVar "y"))))
(DTypeSig true "clampMin" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))))
(DFunDef false "clampMin" ((PVar "lo") (PVar "x")) (EIf (EBinOp "<" (EVar "x") (EVar "lo")) (EVar "lo") (EIf (EVar "True") (EVar "x") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
