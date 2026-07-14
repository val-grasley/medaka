# META
source_lines=166
stages=DESUGAR,MARK
# SOURCE
-- Composed self-hosted front-end LOGIC — wires the stage ports into one
-- `runCheck`, the way bin/main.ml's `check` runs the OCaml pipeline:
--
--   parse → desugar → resolve → exhaust → typecheck
--
-- Run via the thin driver: medaka run compiler/entries/check_main.mdk <rt> <core> <src>
--
-- Output (location-free, so it diffs against the location-stripped oracles):
--   • if resolve reports errors, print them (sorted by the harness) and stop —
--     downstream stages can't run with unbound names;
--   • otherwise print guard-exhaustiveness warnings (exhaust, on the RAW AST)
--     followed by the inferred top-level schemes (typecheck, over core + prog).
--
-- A clean prelude-using program therefore prints exactly its === TYPES ===
-- schemes; a resolve fixture prints its resolve diagnostics; an exhaust fixture
-- prints its guard warning(s) ahead of the schemes.  runtime.mdk seeds the
-- extern signatures; core.mdk is the prelude prepended for resolve + typecheck.

-- LOGIC-ONLY module (Phase C Slice 0): the `main` + `withFiles`/`withCore`/
-- `withTarget` driver moved to compiler/entries/check_main.mdk so two private `main`s
-- (this driver's + the native CLI dispatcher's) don't collide under
-- private_mangle.  This module now exposes only `runCheck` + its helpers, so it
-- composes cleanly into compiler/medaka_cli.mdk and the batch/modules harnesses.

import frontend.ast.{Decl}
import frontend.parser.{parse}
import frontend.desugar.{desugar}
import support.util.{joinNl}
import frontend.resolve.{
  resolveToLines,
  resolveModulesToLines,
  resolveModulesToHumane,
  resolveModulesToLinesG,
  resolveModulesToHumaneG,
  singleFileImportErrors,
  ppResError,
}
import frontend.exhaust.{exhaustToLinesWith}
import types.typecheck.{
  checkToLinesWithRuntime,
  setCoherenceUserDecls,
  checkErrorsWithRuntime,
  checkModulesEntryReport,
  checkModulesEntryHasErrors,
}

-- exported so the batch typecheck harness's synthetic entry can pull this
-- module into a single union closure (does not change its inferred schemes),
-- and so compiler/entries/check_main.mdk + compiler/medaka_cli.mdk can drive it.
export runCheck : String -> String -> String -> String
runCheck rsrc csrc tsrc =
  let raw = parse tsrc
  let desugared = desugar raw
  let runtimeP = parse rsrc
  let coreP = parse csrc
  let importErrs = singleFileImportErrors desugared
  let importDiags = joinNl (map ppResError importErrs)
  routeImportCheck importDiags runtimeP coreP raw desugared
-- R3: check for imports of unknown modules before resolve so we emit
-- UnknownModule (right category) rather than falling through to a
-- spurious typecheck "Unbound variable".  In single-file mode there is
-- no loader, so any non-core import is by definition unknown.

routeImportCheck : String -> List Decl -> List Decl -> List Decl -> List Decl -> String
routeImportCheck "" runtimeP coreP raw desugared =
  let resDiags = resolveToLines runtimeP coreP desugared
  reportFor resDiags runtimeP coreP raw desugared
routeImportCheck diags _ _ _ _ = diags

reportFor : String -> List Decl -> List Decl -> List Decl -> List Decl -> String
reportFor "" runtimeP coreP raw desugared =
  cleanReport runtimeP coreP raw desugared
reportFor resDiags _ _ _ _ = resDiags

cleanReport : List Decl -> List Decl -> List Decl -> List Decl -> String
-- Intentional cross-file duplicate of the same helper in check_batch.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
cleanReport runtimeP coreP raw desugared =
  let exWarns = exhaustToLinesWith (raw ++ runtimeP ++ coreP) raw
  let _ = setCoherenceUserDecls desugared
  let schemes = checkToLinesWithRuntime (desugar runtimeP) (desugar coreP) desugared
  joinNonEmpty exWarns schemes
-- TYPECHECK-AUDIT S3: stage the USER decls (NO prelude) for the coherence check
-- so a user impl overriding a prelude impl is not flagged as overlapping.

joinNonEmpty : String -> String -> String
joinNonEmpty "" b = b
joinNonEmpty a "" = a
joinNonEmpty a b = "\{a}\n\{b}"

-- G1 (SOUNDNESS): does the same front-end pipeline runCheck drives report ANY
-- error?  This is the exit-code predicate for the native CLI: runCheck returns a
-- REPORT string whose success path is a NON-empty signature dump, so "report
-- non-empty" is NOT "had an error".  checkHasErrors instead mirrors runCheck's
-- exact short-circuit ROUTING (single-file imports → resolve → typecheck) and
-- tests each error CATEGORY for content, reusing the same error
-- sources, while ignoring exhaustiveness WARNINGS (not errors) and the success
-- scheme dump.  Keeping this separate from runCheck leaves its stdout byte-
-- identical (the diff_native_cli gate stays green); only the exit code is gated.
export checkHasErrors : String -> String -> String -> Bool
checkHasErrors rsrc csrc tsrc =
  let raw = parse tsrc
  let desugared = desugar raw
  let runtimeP = parse rsrc
  let coreP = parse csrc
  let importErrs = singleFileImportErrors desugared
  match importErrs
    _::_ => True
    [] =>
      let resDiags = resolveToLines runtimeP coreP desugared
      match resDiags
        "" =>
          let _ = setCoherenceUserDecls desugared
          checkErrorsWithRuntime (desugar runtimeP) (desugar coreP) desugared
        _ => True

-- ── multi-module `check` (DRIVER-COLLAPSE Phase 4, OPTION A) ───────────────
-- The unified `medaka check` path for IMPORT-BEARING files.  The CLI loads the
-- entry + its transitive imports (loadProgram, entry LAST in dependency-first
-- order) and DESUGARS each, then calls these.  This RESOLVES imports (vs the
-- single-file path's `UnknownModule`), mirroring how `build`/`run` route through
-- loadProgram → the multi-module typecheck.  Output mirrors runCheck's shape over
-- the entry module: multi-module resolve diagnostics short-circuit first, else the
-- entry module's schemes/type-errors/match-warnings via checkModulesEntryReport.
-- `rtD`/`coreD` are the DESUGARED runtime/core decls; `mods` are the DESUGARED
-- loaded modules (entry last).  Kept separate from runCheck so the no-import path
-- stays byte-identical (the CLI routes 1-module loads through runCheck).
export runCheckModules : Bool -> List String -> List Decl -> List Decl -> List (String, List Decl) -> String
runCheckModules allowInternal trustedMods rtD coreD mods =
  let resDiags = resolveModulesToHumaneG allowInternal trustedMods rtD coreD mods
  match resDiags
    "" =>
      let exWarns = entryExhaust rtD coreD mods
      let report = checkModulesEntryReport rtD coreD mods
      joinNonEmpty exWarns report
    _ => resDiags

-- exit-code predicate analog of checkHasErrors for the multi-module path: a
-- resolve error OR any type error in the entry module.
export checkModulesHasErrors : Bool -> List String -> List Decl -> List Decl -> List (String, List Decl) -> Bool
checkModulesHasErrors allowInternal trustedMods rtD coreD mods =
  let resDiags = resolveModulesToLinesG allowInternal trustedMods rtD coreD mods
  match resDiags
    "" => checkModulesEntryHasErrors rtD coreD mods
    _ => True

-- guard-exhaustiveness warnings on the ENTRY module (last) — the multi-module
-- analog of runCheck's `exhaustToLines raw`.  exhaustToLines runs on the desugared
-- decls here (the loaded mods are already desugared); guard-coverage lowering does
-- not erase the `match` shape exhaust inspects, so this surfaces the same warnings.
-- Oracle superset = runtime + core + EVERY loaded module's decls (so a
-- multi-clause function in the entry module over an IMPORTED ADT is not
-- false-flagged); only the entry module (last) is CHECKED.  `rtD`/`coreD`/`mods`
-- are the DESUGARED decls, which still carry the DData the oracle reads.
entryExhaust : List Decl -> List Decl -> List (String, List Decl) -> String
entryExhaust rtD coreD mods =
  let oracleDecls = rtD ++ coreD ++ flatMap declsOfMod mods
  entryExhaustGo oracleDecls mods

declsOfMod : (String, List Decl) -> List Decl
declsOfMod (_, prog) = prog

entryExhaustGo : List Decl -> List (String, List Decl) -> String
entryExhaustGo _ [] = ""
entryExhaustGo oracleDecls [(_, prog)] = exhaustToLinesWith oracleDecls prog
entryExhaustGo oracleDecls (_::rest) = entryExhaustGo oracleDecls rest
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "resolveToLines" false) (mem "resolveModulesToLines" false) (mem "resolveModulesToHumane" false) (mem "resolveModulesToLinesG" false) (mem "resolveModulesToHumaneG" false) (mem "singleFileImportErrors" false) (mem "ppResError" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "exhaustToLinesWith" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "checkToLinesWithRuntime" false) (mem "setCoherenceUserDecls" false) (mem "checkErrorsWithRuntime" false) (mem "checkModulesEntryReport" false) (mem "checkModulesEntryHasErrors" false))))
(DTypeSig true "runCheck" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "runCheck" ((PVar "rsrc") (PVar "csrc") (PVar "tsrc")) (EBlock (DoLet false false (PVar "raw") (EApp (EVar "parse") (EVar "tsrc"))) (DoLet false false (PVar "desugared") (EApp (EVar "desugar") (EVar "raw"))) (DoLet false false (PVar "runtimeP") (EApp (EVar "parse") (EVar "rsrc"))) (DoLet false false (PVar "coreP") (EApp (EVar "parse") (EVar "csrc"))) (DoLet false false (PVar "importErrs") (EApp (EVar "singleFileImportErrors") (EVar "desugared"))) (DoLet false false (PVar "importDiags") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "ppResError")) (EVar "importErrs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "routeImportCheck") (EVar "importDiags")) (EVar "runtimeP")) (EVar "coreP")) (EVar "raw")) (EVar "desugared")))))
(DTypeSig false "routeImportCheck" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))))
(DFunDef false "routeImportCheck" ((PLit (LString "")) (PVar "runtimeP") (PVar "coreP") (PVar "raw") (PVar "desugared")) (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EVar "resolveToLines") (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reportFor") (EVar "resDiags")) (EVar "runtimeP")) (EVar "coreP")) (EVar "raw")) (EVar "desugared")))))
(DFunDef false "routeImportCheck" ((PVar "diags") PWild PWild PWild PWild) (EVar "diags"))
(DTypeSig false "reportFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))))
(DFunDef false "reportFor" ((PLit (LString "")) (PVar "runtimeP") (PVar "coreP") (PVar "raw") (PVar "desugared")) (EApp (EApp (EApp (EApp (EVar "cleanReport") (EVar "runtimeP")) (EVar "coreP")) (EVar "raw")) (EVar "desugared")))
(DFunDef false "reportFor" ((PVar "resDiags") PWild PWild PWild PWild) (EVar "resDiags"))
(DTypeSig false "cleanReport" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))))
(DFunDef false "cleanReport" ((PVar "runtimeP") (PVar "coreP") (PVar "raw") (PVar "desugared")) (EBlock (DoLet false false (PVar "exWarns") (EApp (EApp (EVar "exhaustToLinesWith") (EBinOp "++" (EBinOp "++" (EVar "raw") (EVar "runtimeP")) (EVar "coreP"))) (EVar "raw"))) (DoLet false false PWild (EApp (EVar "setCoherenceUserDecls") (EVar "desugared"))) (DoLet false false (PVar "schemes") (EApp (EApp (EApp (EVar "checkToLinesWithRuntime") (EApp (EVar "desugar") (EVar "runtimeP"))) (EApp (EVar "desugar") (EVar "coreP"))) (EVar "desugared"))) (DoExpr (EApp (EApp (EVar "joinNonEmpty") (EVar "exWarns")) (EVar "schemes")))))
(DTypeSig false "joinNonEmpty" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinNonEmpty" ((PLit (LString "")) (PVar "b")) (EVar "b"))
(DFunDef false "joinNonEmpty" ((PVar "a") (PLit (LString ""))) (EVar "a"))
(DFunDef false "joinNonEmpty" ((PVar "a") (PVar "b")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "b"))) (ELit (LString ""))))
(DTypeSig true "checkHasErrors" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "checkHasErrors" ((PVar "rsrc") (PVar "csrc") (PVar "tsrc")) (EBlock (DoLet false false (PVar "raw") (EApp (EVar "parse") (EVar "tsrc"))) (DoLet false false (PVar "desugared") (EApp (EVar "desugar") (EVar "raw"))) (DoLet false false (PVar "runtimeP") (EApp (EVar "parse") (EVar "rsrc"))) (DoLet false false (PVar "coreP") (EApp (EVar "parse") (EVar "csrc"))) (DoLet false false (PVar "importErrs") (EApp (EVar "singleFileImportErrors") (EVar "desugared"))) (DoExpr (EMatch (EVar "importErrs") (arm (PCons PWild PWild) () (EVar "True")) (arm (PList) () (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EVar "resolveToLines") (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EBlock (DoLet false false PWild (EApp (EVar "setCoherenceUserDecls") (EVar "desugared"))) (DoExpr (EApp (EApp (EApp (EVar "checkErrorsWithRuntime") (EApp (EVar "desugar") (EVar "runtimeP"))) (EApp (EVar "desugar") (EVar "coreP"))) (EVar "desugared"))))) (arm PWild () (EVar "True"))))))))))
(DTypeSig true "runCheckModules" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))))
(DFunDef false "runCheckModules" ((PVar "allowInternal") (PVar "trustedMods") (PVar "rtD") (PVar "coreD") (PVar "mods")) (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "rtD")) (EVar "coreD")) (EVar "mods"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EBlock (DoLet false false (PVar "exWarns") (EApp (EApp (EApp (EVar "entryExhaust") (EVar "rtD")) (EVar "coreD")) (EVar "mods"))) (DoLet false false (PVar "report") (EApp (EApp (EApp (EVar "checkModulesEntryReport") (EVar "rtD")) (EVar "coreD")) (EVar "mods"))) (DoExpr (EApp (EApp (EVar "joinNonEmpty") (EVar "exWarns")) (EVar "report"))))) (arm PWild () (EVar "resDiags"))))))
(DTypeSig true "checkModulesHasErrors" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool")))))))
(DFunDef false "checkModulesHasErrors" ((PVar "allowInternal") (PVar "trustedMods") (PVar "rtD") (PVar "coreD") (PVar "mods")) (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToLinesG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "rtD")) (EVar "coreD")) (EVar "mods"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EApp (EApp (EApp (EVar "checkModulesEntryHasErrors") (EVar "rtD")) (EVar "coreD")) (EVar "mods"))) (arm PWild () (EVar "True"))))))
(DTypeSig false "entryExhaust" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))
(DFunDef false "entryExhaust" ((PVar "rtD") (PVar "coreD") (PVar "mods")) (EBlock (DoLet false false (PVar "oracleDecls") (EBinOp "++" (EBinOp "++" (EVar "rtD") (EVar "coreD")) (EApp (EApp (EVar "flatMap") (EVar "declsOfMod")) (EVar "mods")))) (DoExpr (EApp (EApp (EVar "entryExhaustGo") (EVar "oracleDecls")) (EVar "mods")))))
(DTypeSig false "declsOfMod" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "declsOfMod" ((PTuple PWild (PVar "prog"))) (EVar "prog"))
(DTypeSig false "entryExhaustGo" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))
(DFunDef false "entryExhaustGo" (PWild (PList)) (ELit (LString "")))
(DFunDef false "entryExhaustGo" ((PVar "oracleDecls") (PList (PTuple PWild (PVar "prog")))) (EApp (EApp (EVar "exhaustToLinesWith") (EVar "oracleDecls")) (EVar "prog")))
(DFunDef false "entryExhaustGo" ((PVar "oracleDecls") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "entryExhaustGo") (EVar "oracleDecls")) (EVar "rest")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "resolveToLines" false) (mem "resolveModulesToLines" false) (mem "resolveModulesToHumane" false) (mem "resolveModulesToLinesG" false) (mem "resolveModulesToHumaneG" false) (mem "singleFileImportErrors" false) (mem "ppResError" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "exhaustToLinesWith" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "checkToLinesWithRuntime" false) (mem "setCoherenceUserDecls" false) (mem "checkErrorsWithRuntime" false) (mem "checkModulesEntryReport" false) (mem "checkModulesEntryHasErrors" false))))
(DTypeSig true "runCheck" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "runCheck" ((PVar "rsrc") (PVar "csrc") (PVar "tsrc")) (EBlock (DoLet false false (PVar "raw") (EApp (EVar "parse") (EVar "tsrc"))) (DoLet false false (PVar "desugared") (EApp (EVar "desugar") (EVar "raw"))) (DoLet false false (PVar "runtimeP") (EApp (EVar "parse") (EVar "rsrc"))) (DoLet false false (PVar "coreP") (EApp (EVar "parse") (EVar "csrc"))) (DoLet false false (PVar "importErrs") (EApp (EVar "singleFileImportErrors") (EVar "desugared"))) (DoLet false false (PVar "importDiags") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "ppResError")) (EVar "importErrs")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "routeImportCheck") (EVar "importDiags")) (EVar "runtimeP")) (EVar "coreP")) (EVar "raw")) (EVar "desugared")))))
(DTypeSig false "routeImportCheck" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))))
(DFunDef false "routeImportCheck" ((PLit (LString "")) (PVar "runtimeP") (PVar "coreP") (PVar "raw") (PVar "desugared")) (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EVar "resolveToLines") (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reportFor") (EVar "resDiags")) (EVar "runtimeP")) (EVar "coreP")) (EVar "raw")) (EVar "desugared")))))
(DFunDef false "routeImportCheck" ((PVar "diags") PWild PWild PWild PWild) (EVar "diags"))
(DTypeSig false "reportFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))))
(DFunDef false "reportFor" ((PLit (LString "")) (PVar "runtimeP") (PVar "coreP") (PVar "raw") (PVar "desugared")) (EApp (EApp (EApp (EApp (EVar "cleanReport") (EVar "runtimeP")) (EVar "coreP")) (EVar "raw")) (EVar "desugared")))
(DFunDef false "reportFor" ((PVar "resDiags") PWild PWild PWild PWild) (EVar "resDiags"))
(DTypeSig false "cleanReport" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))))
(DFunDef false "cleanReport" ((PVar "runtimeP") (PVar "coreP") (PVar "raw") (PVar "desugared")) (EBlock (DoLet false false (PVar "exWarns") (EApp (EApp (EVar "exhaustToLinesWith") (EBinOp "++" (EBinOp "++" (EVar "raw") (EVar "runtimeP")) (EVar "coreP"))) (EVar "raw"))) (DoLet false false PWild (EApp (EVar "setCoherenceUserDecls") (EVar "desugared"))) (DoLet false false (PVar "schemes") (EApp (EApp (EApp (EVar "checkToLinesWithRuntime") (EApp (EVar "desugar") (EVar "runtimeP"))) (EApp (EVar "desugar") (EVar "coreP"))) (EVar "desugared"))) (DoExpr (EApp (EApp (EVar "joinNonEmpty") (EVar "exWarns")) (EVar "schemes")))))
(DTypeSig false "joinNonEmpty" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinNonEmpty" ((PLit (LString "")) (PVar "b")) (EVar "b"))
(DFunDef false "joinNonEmpty" ((PVar "a") (PLit (LString ""))) (EVar "a"))
(DFunDef false "joinNonEmpty" ((PVar "a") (PVar "b")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString ""))))
(DTypeSig true "checkHasErrors" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "checkHasErrors" ((PVar "rsrc") (PVar "csrc") (PVar "tsrc")) (EBlock (DoLet false false (PVar "raw") (EApp (EVar "parse") (EVar "tsrc"))) (DoLet false false (PVar "desugared") (EApp (EVar "desugar") (EVar "raw"))) (DoLet false false (PVar "runtimeP") (EApp (EVar "parse") (EVar "rsrc"))) (DoLet false false (PVar "coreP") (EApp (EVar "parse") (EVar "csrc"))) (DoLet false false (PVar "importErrs") (EApp (EVar "singleFileImportErrors") (EVar "desugared"))) (DoExpr (EMatch (EVar "importErrs") (arm (PCons PWild PWild) () (EVar "True")) (arm (PList) () (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EVar "resolveToLines") (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EBlock (DoLet false false PWild (EApp (EVar "setCoherenceUserDecls") (EVar "desugared"))) (DoExpr (EApp (EApp (EApp (EVar "checkErrorsWithRuntime") (EApp (EVar "desugar") (EVar "runtimeP"))) (EApp (EVar "desugar") (EVar "coreP"))) (EVar "desugared"))))) (arm PWild () (EVar "True"))))))))))
(DTypeSig true "runCheckModules" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))))
(DFunDef false "runCheckModules" ((PVar "allowInternal") (PVar "trustedMods") (PVar "rtD") (PVar "coreD") (PVar "mods")) (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "rtD")) (EVar "coreD")) (EVar "mods"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EBlock (DoLet false false (PVar "exWarns") (EApp (EApp (EApp (EVar "entryExhaust") (EVar "rtD")) (EVar "coreD")) (EVar "mods"))) (DoLet false false (PVar "report") (EApp (EApp (EApp (EVar "checkModulesEntryReport") (EVar "rtD")) (EVar "coreD")) (EVar "mods"))) (DoExpr (EApp (EApp (EVar "joinNonEmpty") (EVar "exWarns")) (EVar "report"))))) (arm PWild () (EVar "resDiags"))))))
(DTypeSig true "checkModulesHasErrors" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Bool")))))))
(DFunDef false "checkModulesHasErrors" ((PVar "allowInternal") (PVar "trustedMods") (PVar "rtD") (PVar "coreD") (PVar "mods")) (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToLinesG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "rtD")) (EVar "coreD")) (EVar "mods"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EApp (EApp (EApp (EVar "checkModulesEntryHasErrors") (EVar "rtD")) (EVar "coreD")) (EVar "mods"))) (arm PWild () (EVar "True"))))))
(DTypeSig false "entryExhaust" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))
(DFunDef false "entryExhaust" ((PVar "rtD") (PVar "coreD") (PVar "mods")) (EBlock (DoLet false false (PVar "oracleDecls") (EBinOp "++" (EBinOp "++" (EVar "rtD") (EVar "coreD")) (EApp (EApp (EDictApp "flatMap") (EVar "declsOfMod")) (EVar "mods")))) (DoExpr (EApp (EApp (EVar "entryExhaustGo") (EVar "oracleDecls")) (EVar "mods")))))
(DTypeSig false "declsOfMod" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "declsOfMod" ((PTuple PWild (PVar "prog"))) (EVar "prog"))
(DTypeSig false "entryExhaustGo" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))
(DFunDef false "entryExhaustGo" (PWild (PList)) (ELit (LString "")))
(DFunDef false "entryExhaustGo" ((PVar "oracleDecls") (PList (PTuple PWild (PVar "prog")))) (EApp (EApp (EVar "exhaustToLinesWith") (EVar "oracleDecls")) (EVar "prog")))
(DFunDef false "entryExhaustGo" ((PVar "oracleDecls") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "entryExhaustGo") (EVar "oracleDecls")) (EVar "rest")))
