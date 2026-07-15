# META
source_lines=17
stages=TOKENS,DESUGAR,MARK
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
# TOKENS
NEWLINE
EFFECT
UPPER "KV"
NEWLINE
EFFECT
UPPER "Log"
NEWLINE
EXTERN
IDENT "kvGet"
COLON
UPPER "String"
ARROW
LT
UPPER "KV"
GT
UPPER "String"
NEWLINE
IDENT "get"
COLON
UPPER "String"
ARROW
LT
UPPER "KV"
GT
UPPER "String"
NEWLINE
IDENT "get"
IDENT "k"
EQUAL
IDENT "kvGet"
IDENT "k"
NEWLINE
IDENT "handler"
COLON
UPPER "String"
ARROW
LT
UPPER "KV"
COMMA
UPPER "Log"
GT
UPPER "String"
NEWLINE
IDENT "handler"
IDENT "k"
EQUAL
IDENT "get"
IDENT "k"
NEWLINE
IDENT "main"
COLON
LT
UPPER "IO"
GT
UPPER "Unit"
NEWLINE
IDENT "main"
EQUAL
IDENT "println"
STRING "effect labels ok"
NEWLINE
NEWLINE
EOF
# DESUGAR
(DEffect false "KV" None)
(DEffect false "Log" None)
(DExtern false "kvGet" (TyFun (TyCon "String") (TyEffect ("KV") None (TyCon "String"))))
(DTypeSig false "get" (TyFun (TyCon "String") (TyEffect ("KV") None (TyCon "String"))))
(DFunDef false "get" ((PVar "k")) (EApp (EVar "kvGet") (EVar "k")))
(DTypeSig false "handler" (TyFun (TyCon "String") (TyEffect ("KV" "Log") None (TyCon "String"))))
(DFunDef false "handler" ((PVar "k")) (EApp (EVar "get") (EVar "k")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EVar "println") (ELit (LString "effect labels ok"))))
# MARK
(DEffect false "KV" None)
(DEffect false "Log" None)
(DExtern false "kvGet" (TyFun (TyCon "String") (TyEffect ("KV") None (TyCon "String"))))
(DTypeSig false "get" (TyFun (TyCon "String") (TyEffect ("KV") None (TyCon "String"))))
(DFunDef false "get" ((PVar "k")) (EApp (EVar "kvGet") (EVar "k")))
(DTypeSig false "handler" (TyFun (TyCon "String") (TyEffect ("KV" "Log") None (TyCon "String"))))
(DFunDef false "handler" ((PVar "k")) (EApp (EVar "get") (EVar "k")))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EDictApp "println") (ELit (LString "effect labels ok"))))
