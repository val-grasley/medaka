# META
source_lines=128
stages=DESUGAR,MARK
# SOURCE
-- compiler/driver/main_autoprint.mdk — shared composite-`main` auto-print wrap.
--
-- A bare non-Unit VALUE `main` (`main = ("abc", 1.23)`, `main = [1,2,3]`, a
-- `deriving Display` ADT, …) used to CRASH the emitter (`emitPrint` panics on a
-- non-scalar `main`).  This module implements the uniform fix from
-- compiler/COMPOSITE-MAIN-AUTOPRINT-DESIGN.md §10: rewrite the entry decl
--   main = <e>   ⟶   main = println <e>
-- (`println` renders via `display` → raw strings, `(a, b)` tuples, `[1, 2, 3]`
-- lists, derived ctors) so the value flows through the ordinary polymorphic print
-- path every backend already compiles.  The wrapped `main : <IO> Unit` suppresses
-- the emitter's own scalar auto-print (installMainIsUnitHint True), so a value is
-- printed exactly ONCE.
--
-- SCOPE / re-mint safety: the wrap fires ONLY on a bare zero-arg non-Unit/non-Async
-- value main.  Every compiler-graph `main` is Unit/`<IO>`-typed, so
-- `shouldAutoPrintMain` is always False on the compiler's own source → the emitter
-- output on the compiler graph is byte-identical → the self-compile fixpoint is
-- stable and NO seed re-mint is owed (design §6).
--
-- UNDERIVED detection: a bare ADT main with no `Display` instance (`data H = H;
-- main = H`) must surface the clean `No impl of Display for H; add 'deriving
-- Display'` error, NOT a miscompile.  `underivedMainDiags` re-runs the CHECK gate
-- (`checkProgramDiags`, implInferEnabled OFF → checkImplObligations ON) on the
-- WRAPPED, UN-MANGLED program — exactly what source-level `medaka build` of an
-- explicit `main = println H` already does.  (The design's critical caveat: NEVER
-- call checkImplObligations on the MANGLED emit-elaborated program — it can't match
-- mangled `display`/`println` obligations to impl heads and mis-fires on every
-- program.  Routing through checkProgramDiags on un-mangled decls avoids that.)

import frontend.ast.{Decl(..), Expr(..), Pat, Loc}
import types.typecheck.{
  mainTypeIsUnit,
  mainTypeIsAsync,
  checkProgramDiags,
  setCoherenceUserDecls,
  TcDiag,
}

-- The loader hands modules dependency-first, so the ENTRY module is last.
entryPair : List (String, List Decl) -> Option (String, List Decl)
entryPair [] = None
entryPair [p] = Some p
entryPair (_::rest) = entryPair rest

-- Find the top-level `main`'s param list among a module's decls (skipping @attr
-- wrappers), so the caller can require an EMPTY param list (a value main — a
-- function-shaped `main () =`/`main x =` keeps its own W-MAIN-SHAPE handling and
-- is NEVER auto-printed).
findMainParams : List Decl -> Option (List Pat)
findMainParams [] = None
findMainParams ((DAttrib _ d)::rest) = findMainParams (d::rest)
findMainParams ((DFunDef _ "main" ps _)::_) = Some ps
findMainParams (_::rest) = findMainParams rest

-- True iff a top-level `println` binding is in scope (defined by the prelude).
-- The wrap rewrites `main = <e>` → `main = println <e>`, so it MUST NOT fire when
-- `println` is undefined — e.g. the emit gates that pass an EMPTY core prelude
-- (test/diff_compiler_llvm_modules.sh) to exercise the emitter's own scalar
-- auto-print.  A real `medaka build` always passes core.mdk (which defines
-- `println x = putStrLn (display x)`), so the wrap fires there.
definesPrintln : List Decl -> Bool
definesPrintln [] = False
definesPrintln ((DAttrib _ d)::rest) = definesPrintln (d::rest)
definesPrintln ((DFunDef _ "println" _ _)::_) = True
definesPrintln (_::rest) = definesPrintln rest

-- Auto-print fires iff main's inferred type is neither Unit nor `Async _`, the
-- entry `main` is a zero-arg VALUE (empty param list), AND `println` is in scope.
-- Requires the caller to have run an elaborate first (populates mainSchemeRef).
export shouldAutoPrintMain : List Decl -> List (String, List Decl) -> Bool
shouldAutoPrintMain coreDecls modules =
  if mainTypeIsUnit () || mainTypeIsAsync () then False
  else
    if not (definesPrintln (coreDecls ++ flatMap snd modules)) then False
    else match entryPair modules
      None => False
      Some (_, decls) => match findMainParams decls
        Some [] => True
        _ => False

-- True iff the decl is `main`'s explicit type signature (`main : T`), possibly
-- @attr-wrapped.  When the wrap fires the body becomes `main = println <e>`
-- (: `<IO> Unit`), so a stale explicit `main : <non-Unit>` sig would make the
-- re-check report a `<non-Unit> vs Unit` mismatch → empty IR → build failure.
-- The wrap drops it (the signature was only ever consulted to detect the
-- non-Unit-ness that fires the wrap in the first place).
isMainTypeSig : Decl -> Bool
isMainTypeSig (DAttrib _ d) = isMainTypeSig d
isMainTypeSig (DTypeSig _ "main" _) = True
isMainTypeSig _ = False

-- Rewrite the entry module's `main = <e>` decl to `main = println <e>`, and drop
-- any explicit `main : T` signature (now stale — see isMainTypeSig).
export autoPrintWrapModules : List (String, List Decl) -> List (String, List Decl)
autoPrintWrapModules [] = []
autoPrintWrapModules [(mid, decls)] =
  [(mid, map wrapMainDecl (filter (d => not (isMainTypeSig d)) decls))]
autoPrintWrapModules (p::rest) = p :: autoPrintWrapModules rest

wrapMainDecl : Decl -> Decl
wrapMainDecl (DFunDef vis "main" [] body) =
  DFunDef vis "main" [] (wrapPrintln body)
wrapMainDecl (DAttrib a d) = DAttrib a (wrapMainDecl d)
wrapMainDecl d = d

-- `main = <e>` → `main = println <e>`, re-attaching the body's own source span
-- (its outer `ELoc`, from `parseLocated`) around the synthetic application so the
-- auto-print Display obligation reports AT the main body — not at `{0,0}` — on the
-- check/LSP path (underivedMainDiags).  `ELoc` is transparent to every backend, so
-- the emitted IR is unchanged.  An un-located body (plain `parse`) wraps bare.
wrapPrintln : Expr -> Expr
wrapPrintln (ELoc l inner) = ELoc l (EApp (EVar "println") (ELoc l inner))
wrapPrintln body = EApp (EVar "println") body

-- Re-run the CHECK gate on the wrapped program to surface an underived-ADT main
-- as the clean `No impl of Display …` type error.  Gated to a SINGLE loaded
-- module (the common composite-main shape: playground + `medaka build file.mdk`):
-- the flat core++entry check IS the single-file `analyzeLocated` engine.  A
-- multi-module program flattened this way risks the over-rejection the CLI's
-- multi-module gate deliberately avoids, so it is skipped there (best-effort —
-- the compiler graph never wraps, so this never affects the fixpoint).  Returns
-- the type-error `TcDiag`s for the caller to render.
export underivedMainDiags : List Decl -> List Decl -> List (String, List Decl) -> List TcDiag
underivedMainDiags runtimeDecls coreDecls [(_, entryDecls)] =
  let _ = setCoherenceUserDecls entryDecls
  let (tcErrs, _) = checkProgramDiags runtimeDecls coreDecls entryDecls
  tcErrs
underivedMainDiags _ _ _ = []
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Pat" false) (mem "Loc" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "mainTypeIsUnit" false) (mem "mainTypeIsAsync" false) (mem "checkProgramDiags" false) (mem "setCoherenceUserDecls" false) (mem "TcDiag" false))))
(DTypeSig false "entryPair" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "entryPair" ((PList)) (EVar "None"))
(DFunDef false "entryPair" ((PList (PVar "p"))) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "entryPair" ((PCons PWild (PVar "rest"))) (EApp (EVar "entryPair") (EVar "rest")))
(DTypeSig false "findMainParams" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "findMainParams" ((PList)) (EVar "None"))
(DFunDef false "findMainParams" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "findMainParams") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "findMainParams" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PVar "ps") PWild) PWild)) (EApp (EVar "Some") (EVar "ps")))
(DFunDef false "findMainParams" ((PCons PWild (PVar "rest"))) (EApp (EVar "findMainParams") (EVar "rest")))
(DTypeSig false "definesPrintln" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "definesPrintln" ((PList)) (EVar "False"))
(DFunDef false "definesPrintln" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "definesPrintln") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "definesPrintln" ((PCons (PCon "DFunDef" PWild (PLit (LString "println")) PWild PWild) PWild)) (EVar "True"))
(DFunDef false "definesPrintln" ((PCons PWild (PVar "rest"))) (EApp (EVar "definesPrintln") (EVar "rest")))
(DTypeSig true "shouldAutoPrintMain" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool"))))
(DFunDef false "shouldAutoPrintMain" ((PVar "coreDecls") (PVar "modules")) (EIf (EBinOp "||" (EApp (EVar "mainTypeIsUnit") (ELit LUnit)) (EApp (EVar "mainTypeIsAsync") (ELit LUnit))) (EVar "False") (EIf (EApp (EVar "not") (EApp (EVar "definesPrintln") (EBinOp "++" (EVar "coreDecls") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modules"))))) (EVar "False") (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EMatch (EApp (EVar "findMainParams") (EVar "decls")) (arm (PCon "Some" (PList)) () (EVar "True")) (arm PWild () (EVar "False"))))))))
(DTypeSig false "isMainTypeSig" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isMainTypeSig" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isMainTypeSig") (EVar "d")))
(DFunDef false "isMainTypeSig" ((PCon "DTypeSig" PWild (PLit (LString "main")) PWild)) (EVar "True"))
(DFunDef false "isMainTypeSig" (PWild) (EVar "False"))
(DTypeSig true "autoPrintWrapModules" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "autoPrintWrapModules" ((PList)) (EListLit))
(DFunDef false "autoPrintWrapModules" ((PList (PTuple (PVar "mid") (PVar "decls")))) (EListLit (ETuple (EVar "mid") (EApp (EApp (EVar "map") (EVar "wrapMainDecl")) (EApp (EApp (EVar "filter") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EVar "isMainTypeSig") (EVar "d"))))) (EVar "decls"))))))
(DFunDef false "autoPrintWrapModules" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EVar "p") (EApp (EVar "autoPrintWrapModules") (EVar "rest"))))
(DTypeSig false "wrapMainDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "wrapMainDecl" ((PCon "DFunDef" (PVar "vis") (PLit (LString "main")) (PList) (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (ELit (LString "main"))) (EListLit)) (EApp (EVar "wrapPrintln") (EVar "body"))))
(DFunDef false "wrapMainDecl" ((PCon "DAttrib" (PVar "a") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "a")) (EApp (EVar "wrapMainDecl") (EVar "d"))))
(DFunDef false "wrapMainDecl" ((PVar "d")) (EVar "d"))
(DTypeSig false "wrapPrintln" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "wrapPrintln" ((PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "println")))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "inner")))))
(DFunDef false "wrapPrintln" ((PVar "body")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "println")))) (EVar "body")))
(DTypeSig true "underivedMainDiags" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "TcDiag"))))))
(DFunDef false "underivedMainDiags" ((PVar "runtimeDecls") (PVar "coreDecls") (PList (PTuple PWild (PVar "entryDecls")))) (EBlock (DoLet false false PWild (EApp (EVar "setCoherenceUserDecls") (EVar "entryDecls"))) (DoLet false false (PTuple (PVar "tcErrs") PWild) (EApp (EApp (EApp (EVar "checkProgramDiags") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "entryDecls"))) (DoExpr (EVar "tcErrs"))))
(DFunDef false "underivedMainDiags" (PWild PWild PWild) (EListLit))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Pat" false) (mem "Loc" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "mainTypeIsUnit" false) (mem "mainTypeIsAsync" false) (mem "checkProgramDiags" false) (mem "setCoherenceUserDecls" false) (mem "TcDiag" false))))
(DTypeSig false "entryPair" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "entryPair" ((PList)) (EVar "None"))
(DFunDef false "entryPair" ((PList (PVar "p"))) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "entryPair" ((PCons PWild (PVar "rest"))) (EApp (EVar "entryPair") (EVar "rest")))
(DTypeSig false "findMainParams" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "findMainParams" ((PList)) (EVar "None"))
(DFunDef false "findMainParams" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "findMainParams") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "findMainParams" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PVar "ps") PWild) PWild)) (EApp (EVar "Some") (EVar "ps")))
(DFunDef false "findMainParams" ((PCons PWild (PVar "rest"))) (EApp (EVar "findMainParams") (EVar "rest")))
(DTypeSig false "definesPrintln" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "definesPrintln" ((PList)) (EVar "False"))
(DFunDef false "definesPrintln" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "definesPrintln") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "definesPrintln" ((PCons (PCon "DFunDef" PWild (PLit (LString "println")) PWild PWild) PWild)) (EVar "True"))
(DFunDef false "definesPrintln" ((PCons PWild (PVar "rest"))) (EApp (EVar "definesPrintln") (EVar "rest")))
(DTypeSig true "shouldAutoPrintMain" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool"))))
(DFunDef false "shouldAutoPrintMain" ((PVar "coreDecls") (PVar "modules")) (EIf (EBinOp "||" (EApp (EVar "mainTypeIsUnit") (ELit LUnit)) (EApp (EVar "mainTypeIsAsync") (ELit LUnit))) (EVar "False") (EIf (EApp (EVar "not") (EApp (EVar "definesPrintln") (EBinOp "++" (EVar "coreDecls") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modules"))))) (EVar "False") (EMatch (EApp (EVar "entryPair") (EVar "modules")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple PWild (PVar "decls"))) () (EMatch (EApp (EVar "findMainParams") (EVar "decls")) (arm (PCon "Some" (PList)) () (EVar "True")) (arm PWild () (EVar "False"))))))))
(DTypeSig false "isMainTypeSig" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isMainTypeSig" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isMainTypeSig") (EVar "d")))
(DFunDef false "isMainTypeSig" ((PCon "DTypeSig" PWild (PLit (LString "main")) PWild)) (EVar "True"))
(DFunDef false "isMainTypeSig" (PWild) (EVar "False"))
(DTypeSig true "autoPrintWrapModules" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "autoPrintWrapModules" ((PList)) (EListLit))
(DFunDef false "autoPrintWrapModules" ((PList (PTuple (PVar "mid") (PVar "decls")))) (EListLit (ETuple (EVar "mid") (EApp (EApp (EMethodRef "map") (EVar "wrapMainDecl")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EVar "isMainTypeSig") (EVar "d"))))) (EVar "decls"))))))
(DFunDef false "autoPrintWrapModules" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EVar "p") (EApp (EVar "autoPrintWrapModules") (EVar "rest"))))
(DTypeSig false "wrapMainDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "wrapMainDecl" ((PCon "DFunDef" (PVar "vis") (PLit (LString "main")) (PList) (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (ELit (LString "main"))) (EListLit)) (EApp (EVar "wrapPrintln") (EVar "body"))))
(DFunDef false "wrapMainDecl" ((PCon "DAttrib" (PVar "a") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "a")) (EApp (EVar "wrapMainDecl") (EVar "d"))))
(DFunDef false "wrapMainDecl" ((PVar "d")) (EVar "d"))
(DTypeSig false "wrapPrintln" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "wrapPrintln" ((PCon "ELoc" (PVar "l") (PVar "inner"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "println")))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "inner")))))
(DFunDef false "wrapPrintln" ((PVar "body")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "println")))) (EVar "body")))
(DTypeSig true "underivedMainDiags" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "TcDiag"))))))
(DFunDef false "underivedMainDiags" ((PVar "runtimeDecls") (PVar "coreDecls") (PList (PTuple PWild (PVar "entryDecls")))) (EBlock (DoLet false false PWild (EApp (EVar "setCoherenceUserDecls") (EVar "entryDecls"))) (DoLet false false (PTuple (PVar "tcErrs") PWild) (EApp (EApp (EApp (EVar "checkProgramDiags") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "entryDecls"))) (DoExpr (EVar "tcErrs"))))
(DFunDef false "underivedMainDiags" (PWild PWild PWild) (EListLit))
