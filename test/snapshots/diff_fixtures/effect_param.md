# META
source_lines=44
stages=TOKENS,DESUGAR,MARK
# SOURCE
-- Capability-effects v2 Stage 2a: PARAMETERIZED effect surface syntax.
-- This fixture is the CLI-level guard that the unit-test bypass (raw
-- Parser.program in test_typecheck.ml) failed to provide: it must parse +
-- typecheck through the REAL indentation-aware `check` pipeline on both the
-- OCaml oracle and the native self-host, exercising every Stage-2a form:
--   * `effect Net Prefix`     — domain-carrying effect decl (Prefix refinement)
--   * `effect Stdout`         — plain (domainless) effect decl
--   * `<Net "a.com/foo">`      — effect-row atom with a Prefix-pattern argument
--   * `data Async e a = … <e> …` — an effect-row PARAMETER on a data decl:
--       `e` is kind-inferred KRow from its use in the Suspend field's effect
--       tail, so `runAsync : Async e a -> <e> a` performs exactly the stored row
effect Net Prefix
effect Stdout

extern netGet : String -> <Net "a.com/foo"> String

fetch : String -> <Net "a.com/foo"> String
fetch path = netGet path

data Async e a = Done a | Suspend (Unit -> <e> Async e a)

runAsync : Async e a -> <e> a
runAsync m = match m
  Done a => a
  Suspend t => runAsync (t ())

liftIO : (Unit -> <e> a) -> Async e a
liftIO act = Suspend (u => Done (act u))

-- regression guard (native-only bug, fixed): a KRow param `e` that appears
-- ONLY as a type-app argument (no `<e>` tail anywhere in the signature) must
-- still resolve to the shared row effvar.  `instantiateSigTracked`'s Pass-A
-- pre-unify etbl seeded from `effTailNames` ALONE collapsed `e` to the pure
-- closed row, so `yld` inferred `Async <> Unit` and an effectful continuation
-- threaded after it spuriously "leaked" <IO>.  Fix: seed `rowArgNames` too.
yld : Async e Unit
yld = Suspend (_ => Done ())

seqIO : Async e a -> (a -> Async e b) -> Async e b
seqIO (Done a) k = k a
seqIO (Suspend t) k = Suspend (u => seqIO (t u) k)

main : <IO> Unit
main = runAsync (seqIO yld (_ => liftIO (u => println "effect param ok")))
# TOKENS
NEWLINE
EFFECT
UPPER "Net"
UPPER "Prefix"
NEWLINE
EFFECT
UPPER "Stdout"
NEWLINE
EXTERN
IDENT "netGet"
COLON
UPPER "String"
ARROW
LT
UPPER "Net"
STRING "a.com/foo"
GT
UPPER "String"
NEWLINE
IDENT "fetch"
COLON
UPPER "String"
ARROW
LT
UPPER "Net"
STRING "a.com/foo"
GT
UPPER "String"
NEWLINE
IDENT "fetch"
IDENT "path"
EQUAL
IDENT "netGet"
IDENT "path"
NEWLINE
DATA
UPPER "Async"
IDENT "e"
IDENT "a"
EQUAL
UPPER "Done"
IDENT "a"
PIPE
UPPER "Suspend"
LPAREN
UPPER "Unit"
ARROW
LT
IDENT "e"
GT
UPPER "Async"
IDENT "e"
IDENT "a"
RPAREN
NEWLINE
IDENT "runAsync"
COLON
UPPER "Async"
IDENT "e"
IDENT "a"
ARROW
LT
IDENT "e"
GT
IDENT "a"
NEWLINE
IDENT "runAsync"
IDENT "m"
EQUAL
MATCH
IDENT "m"
INDENT
UPPER "Done"
IDENT "a"
FAT_ARROW
IDENT "a"
NEWLINE
UPPER "Suspend"
IDENT "t"
FAT_ARROW
IDENT "runAsync"
LPAREN
IDENT "t"
LPAREN
RPAREN
RPAREN
NEWLINE
DEDENT
NEWLINE
IDENT "liftIO"
COLON
LPAREN
UPPER "Unit"
ARROW
LT
IDENT "e"
GT
IDENT "a"
RPAREN
ARROW
UPPER "Async"
IDENT "e"
IDENT "a"
NEWLINE
IDENT "liftIO"
IDENT "act"
EQUAL
UPPER "Suspend"
LPAREN
IDENT "u"
FAT_ARROW
UPPER "Done"
LPAREN
IDENT "act"
IDENT "u"
RPAREN
RPAREN
NEWLINE
IDENT "yld"
COLON
UPPER "Async"
IDENT "e"
UPPER "Unit"
NEWLINE
IDENT "yld"
EQUAL
UPPER "Suspend"
LPAREN
UNDERSCORE
FAT_ARROW
UPPER "Done"
LPAREN
RPAREN
RPAREN
NEWLINE
IDENT "seqIO"
COLON
UPPER "Async"
IDENT "e"
IDENT "a"
ARROW
LPAREN
IDENT "a"
ARROW
UPPER "Async"
IDENT "e"
IDENT "b"
RPAREN
ARROW
UPPER "Async"
IDENT "e"
IDENT "b"
NEWLINE
IDENT "seqIO"
LPAREN
UPPER "Done"
IDENT "a"
RPAREN
IDENT "k"
EQUAL
IDENT "k"
IDENT "a"
NEWLINE
IDENT "seqIO"
LPAREN
UPPER "Suspend"
IDENT "t"
RPAREN
IDENT "k"
EQUAL
UPPER "Suspend"
LPAREN
IDENT "u"
FAT_ARROW
IDENT "seqIO"
LPAREN
IDENT "t"
IDENT "u"
RPAREN
IDENT "k"
RPAREN
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
IDENT "runAsync"
LPAREN
IDENT "seqIO"
IDENT "yld"
LPAREN
UNDERSCORE
FAT_ARROW
IDENT "liftIO"
LPAREN
IDENT "u"
FAT_ARROW
IDENT "println"
STRING "effect param ok"
RPAREN
RPAREN
RPAREN
NEWLINE
NEWLINE
EOF
# DESUGAR
(DEffect false "Net" (Some "Prefix"))
(DEffect false "Stdout" None)
(DExtern false "netGet" (TyFun (TyCon "String") (TyEffect ((atom "Net" "a.com/foo")) None (TyCon "String"))))
(DTypeSig false "fetch" (TyFun (TyCon "String") (TyEffect ((atom "Net" "a.com/foo")) None (TyCon "String"))))
(DFunDef false "fetch" ((PVar "path")) (EApp (EVar "netGet") (EVar "path")))
(DData Private "Async" ("e" "a") ((variant "Done" (ConPos (TyVar "a"))) (variant "Suspend" (ConPos (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))))) ())
(DTypeSig false "runAsync" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyEffect () (Some "e") (TyVar "a"))))
(DFunDef false "runAsync" ((PVar "m")) (EMatch (EVar "m") (arm (PCon "Done" (PVar "a")) () (EVar "a")) (arm (PCon "Suspend" (PVar "t")) () (EApp (EVar "runAsync") (EApp (EVar "t") (ELit LUnit))))))
(DTypeSig false "liftIO" (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "liftIO" ((PVar "act")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "act") (EVar "u"))))))
(DTypeSig false "yld" (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))
(DFunDef false "yld" () (EApp (EVar "Suspend") (ELam (PWild) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig false "seqIO" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "b"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "b")))))
(DFunDef false "seqIO" ((PCon "Done" (PVar "a")) (PVar "k")) (EApp (EVar "k") (EVar "a")))
(DFunDef false "seqIO" ((PCon "Suspend" (PVar "t")) (PVar "k")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "seqIO") (EApp (EVar "t") (EVar "u"))) (EVar "k")))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EVar "runAsync") (EApp (EApp (EVar "seqIO") (EVar "yld")) (ELam (PWild) (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EVar "println") (ELit (LString "effect param ok")))))))))
# MARK
(DEffect false "Net" (Some "Prefix"))
(DEffect false "Stdout" None)
(DExtern false "netGet" (TyFun (TyCon "String") (TyEffect ((atom "Net" "a.com/foo")) None (TyCon "String"))))
(DTypeSig false "fetch" (TyFun (TyCon "String") (TyEffect ((atom "Net" "a.com/foo")) None (TyCon "String"))))
(DFunDef false "fetch" ((PVar "path")) (EApp (EVar "netGet") (EVar "path")))
(DData Private "Async" ("e" "a") ((variant "Done" (ConPos (TyVar "a"))) (variant "Suspend" (ConPos (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))))) ())
(DTypeSig false "runAsync" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyEffect () (Some "e") (TyVar "a"))))
(DFunDef false "runAsync" ((PVar "m")) (EMatch (EVar "m") (arm (PCon "Done" (PVar "a")) () (EVar "a")) (arm (PCon "Suspend" (PVar "t")) () (EApp (EVar "runAsync") (EApp (EVar "t") (ELit LUnit))))))
(DTypeSig false "liftIO" (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "liftIO" ((PVar "act")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "act") (EVar "u"))))))
(DTypeSig false "yld" (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))
(DFunDef false "yld" () (EApp (EVar "Suspend") (ELam (PWild) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig false "seqIO" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "b"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "b")))))
(DFunDef false "seqIO" ((PCon "Done" (PVar "a")) (PVar "k")) (EApp (EVar "k") (EVar "a")))
(DFunDef false "seqIO" ((PCon "Suspend" (PVar "t")) (PVar "k")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "seqIO") (EApp (EVar "t") (EVar "u"))) (EVar "k")))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EApp (EVar "runAsync") (EApp (EApp (EVar "seqIO") (EVar "yld")) (ELam (PWild) (EApp (EVar "liftIO") (ELam ((PVar "u")) (EApp (EDictApp "println") (ELit (LString "effect param ok")))))))))
