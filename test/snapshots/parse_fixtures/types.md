# META
source_lines=6
stages=PARSE,DESUGAR,MARK
# SOURCE
inc : Int -> Int
add : Int -> Int -> Int
ids : List a
pair : (Int, String)
mapper : (a -> b) -> List a -> List b
const : a -> b -> a
# PARSE
(DTypeSig false "inc" (TyFun (TyCon "Int") (TyCon "Int")))
(DTypeSig false "add" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DTypeSig false "ids" (TyApp (TyCon "List") (TyVar "a")))
(DTypeSig false "pair" (TyTuple (TyCon "Int") (TyCon "String")))
(DTypeSig false "mapper" (TyFun (TyFun (TyVar "a") (TyVar "b")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DTypeSig false "const" (TyFun (TyVar "a") (TyFun (TyVar "b") (TyVar "a"))))
# DESUGAR
(DTypeSig false "inc" (TyFun (TyCon "Int") (TyCon "Int")))
(DTypeSig false "add" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DTypeSig false "ids" (TyApp (TyCon "List") (TyVar "a")))
(DTypeSig false "pair" (TyTuple (TyCon "Int") (TyCon "String")))
(DTypeSig false "mapper" (TyFun (TyFun (TyVar "a") (TyVar "b")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DTypeSig false "const" (TyFun (TyVar "a") (TyFun (TyVar "b") (TyVar "a"))))
# MARK
(DTypeSig false "inc" (TyFun (TyCon "Int") (TyCon "Int")))
(DTypeSig false "add" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DTypeSig false "ids" (TyApp (TyCon "List") (TyVar "a")))
(DTypeSig false "pair" (TyTuple (TyCon "Int") (TyCon "String")))
(DTypeSig false "mapper" (TyFun (TyFun (TyVar "a") (TyVar "b")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DTypeSig false "const" (TyFun (TyVar "a") (TyFun (TyVar "b") (TyVar "a"))))
