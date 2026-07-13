# META
source_lines=17
stages=DESUGAR,MARK
# SOURCE
-- Phase 146 gap 2: user-declared effect labels.  `effect KV`/`effect Log`
-- register labels usable in rows; a <KV> body subsumes under a <KV, Log> bound.
-- The effectful functions typecheck (exercising propagation + subsumption) but
-- are not reached from `main`, so EVAL stays clean.
effect KV
effect Log

extern kvGet : String -> <KV> String

get : String -> <KV> String
get k = kvGet k

handler : String -> <KV, Log> String
handler k = get k

main : <IO> Unit
main = println "effect labels ok"
# DESUGAR
(DEffect false "KV" None false)
(DEffect false "Log" None false)
(DExtern false "kvGet" (TyFun (TyCon "String") (TyEffect ("KV") None (TyCon "String"))))
(DTypeSig false "get" (TyFun (TyCon "String") (TyEffect ("KV") None (TyCon "String"))))
(DFunDef false "get" ((PVar "k")) (EApp (EVar "kvGet") (EVar "k")))
(DTypeSig false "handler" (TyFun (TyCon "String") (TyEffect ("KV" "Log") None (TyCon "String"))))
(DFunDef false "handler" ((PVar "k")) (EApp (EVar "get") (EVar "k")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EVar "println") (ELit (LString "effect labels ok"))))
# MARK
(DEffect false "KV" None false)
(DEffect false "Log" None false)
(DExtern false "kvGet" (TyFun (TyCon "String") (TyEffect ("KV") None (TyCon "String"))))
(DTypeSig false "get" (TyFun (TyCon "String") (TyEffect ("KV") None (TyCon "String"))))
(DFunDef false "get" ((PVar "k")) (EApp (EVar "kvGet") (EVar "k")))
(DTypeSig false "handler" (TyFun (TyCon "String") (TyEffect ("KV" "Log") None (TyCon "String"))))
(DFunDef false "handler" ((PVar "k")) (EApp (EVar "get") (EVar "k")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EDictApp "println") (ELit (LString "effect labels ok"))))
