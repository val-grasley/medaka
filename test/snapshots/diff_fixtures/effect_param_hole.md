# META
source_lines=24
stages=TOKENS,DESUGAR,MARK
# SOURCE
-- Capability-effects v2 Stage 2b: INFERRED-HOLE surface form + known-prefix
-- abstract analysis α.  Companion to effect_param.mdk (Stage 2a's concrete
-- parameterized rows).  This fixture is the CLI-level guard for:
--   * `<Net _>`            — the inferred-hole atom on an extern's declared row
--   * α(first argument)     — at the call site `netGet "a.com/foo"`, the hole is
--                             filled by α of the FIRST argument: a string literal
--                             ⇒ Known "a.com/foo" ⇒ <Net "a.com/foo">
--   * delimiter-aware subsumption — the wildcard `<Net "a.com/*">` on `fetch`
--                             must ADMIT the α-derived `<Net "a.com/foo">`.
-- The reject side (sibling-host + computed/function-derived URL ⇒ α=Unknown⇒⊤,
-- both rejected) is exercised by the companion gate diff_compiler_effect_hole.sh.
effect Net Prefix

extern netGet : String -> <Net _> String

-- α("a.com/foo") = Known "a.com/foo"; admitted by the wildcard <Net "a.com/*">.
-- `fetch` is a function (unforced closure) so the extern netGet is never
-- actually evaluated — the fixture exercises the front-end (parse + α + subsume),
-- not the runtime, exactly like effect_param.mdk.
fetch : Unit -> <Net "a.com/*"> String
fetch _ = netGet "a.com/foo"

main : <IO> Unit
main = println "effect hole ok"
# TOKENS
NEWLINE
EFFECT
UPPER "Net"
UPPER "Prefix"
NEWLINE
EXTERN
IDENT "netGet"
COLON
UPPER "String"
ARROW
LT
UPPER "Net"
UNDERSCORE
GT
UPPER "String"
NEWLINE
IDENT "fetch"
COLON
UPPER "Unit"
ARROW
LT
UPPER "Net"
STRING "a.com/*"
GT
UPPER "String"
NEWLINE
IDENT "fetch"
UNDERSCORE
EQUAL
IDENT "netGet"
STRING "a.com/foo"
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
STRING "effect hole ok"
NEWLINE
NEWLINE
EOF
# DESUGAR
(DEffect false "Net" (Some "Prefix"))
(DExtern false "netGet" (TyFun (TyCon "String") (TyEffect ((hole "Net")) None (TyCon "String"))))
(DTypeSig false "fetch" (TyFun (TyCon "Unit") (TyEffect ((atom "Net" "a.com/*")) None (TyCon "String"))))
(DFunDef false "fetch" (PWild) (EApp (EVar "netGet") (ELit (LString "a.com/foo"))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EVar "println") (ELit (LString "effect hole ok"))))
# MARK
(DEffect false "Net" (Some "Prefix"))
(DExtern false "netGet" (TyFun (TyCon "String") (TyEffect ((hole "Net")) None (TyCon "String"))))
(DTypeSig false "fetch" (TyFun (TyCon "Unit") (TyEffect ((atom "Net" "a.com/*")) None (TyCon "String"))))
(DFunDef false "fetch" (PWild) (EApp (EVar "netGet") (ELit (LString "a.com/foo"))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EDictApp "println") (ELit (LString "effect hole ok"))))
