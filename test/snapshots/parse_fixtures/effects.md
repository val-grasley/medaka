# META
source_lines=7
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
main : <IO> Unit
greet : String -> <IO> Unit
readAll : <IO> String
runState : <e> a
combine : <IO, Rand> Unit
withTail : <IO | e> a
pureFn : Int -> Int
# PARSE
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DTypeSig false "greet" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DTypeSig false "readAll" (TyEffect ("IO") None (TyCon "String")))
(DTypeSig false "runState" (TyEffect () (Some "e") (TyVar "a")))
(DTypeSig false "combine" (TyEffect ("IO" "Rand") None (TyCon "Unit")))
(DTypeSig false "withTail" (TyEffect ("IO") (Some "e") (TyVar "a")))
(DTypeSig false "pureFn" (TyFun (TyCon "Int") (TyCon "Int")))
# PRINTER
main : <IO> Unit
greet : String -> <IO> Unit
readAll : <IO> String
runState : <e> a
combine : <IO, Rand> Unit
withTail : <IO | e> a
pureFn : Int -> Int
# DESUGAR
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DTypeSig false "greet" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DTypeSig false "readAll" (TyEffect ("IO") None (TyCon "String")))
(DTypeSig false "runState" (TyEffect () (Some "e") (TyVar "a")))
(DTypeSig false "combine" (TyEffect ("IO" "Rand") None (TyCon "Unit")))
(DTypeSig false "withTail" (TyEffect ("IO") (Some "e") (TyVar "a")))
(DTypeSig false "pureFn" (TyFun (TyCon "Int") (TyCon "Int")))
# MARK
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DTypeSig false "greet" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DTypeSig false "readAll" (TyEffect ("IO") None (TyCon "String")))
(DTypeSig false "runState" (TyEffect () (Some "e") (TyVar "a")))
(DTypeSig false "combine" (TyEffect ("IO" "Rand") None (TyCon "Unit")))
(DTypeSig false "withTail" (TyEffect ("IO") (Some "e") (TyVar "a")))
(DTypeSig false "pureFn" (TyFun (TyCon "Int") (TyCon "Int")))
