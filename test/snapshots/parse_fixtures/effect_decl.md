# META
source_lines=5
stages=PARSE,DESUGAR,MARK
# SOURCE
effect KV
export effect Fetch

get : String -> <KV> String
get k = k
# PARSE
(DEffect false "KV" None false)
(DEffect true "Fetch" None false)
(DTypeSig false "get" (TyFun (TyCon "String") (TyEffect ("KV") None (TyCon "String"))))
(DFunDef false "get" ((PVar "k")) (EVar "k"))
# DESUGAR
(DEffect false "KV" None false)
(DEffect true "Fetch" None false)
(DTypeSig false "get" (TyFun (TyCon "String") (TyEffect ("KV") None (TyCon "String"))))
(DFunDef false "get" ((PVar "k")) (EVar "k"))
# MARK
(DEffect false "KV" None false)
(DEffect true "Fetch" None false)
(DTypeSig false "get" (TyFun (TyCon "String") (TyEffect ("KV") None (TyCon "String"))))
(DFunDef false "get" ((PVar "k")) (EVar "k"))
