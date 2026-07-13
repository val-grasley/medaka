# META
source_lines=1688
stages=DESUGAR,MARK
# SOURCE
-- compiler/medaka_cli.mdk — the native `medaka` CLI dispatcher (Phase C
-- Slice 0+1).  Compiled natively (`medaka build compiler/medaka_cli.mdk -o
-- ./medaka`) this is a Medaka CLI replacing bin/main.ml's check/fmt/new
-- subcommands with no OCaml at runtime.
--
--   ./medaka check <file.mdk>     type-check (parse→…→typecheck), via check.runCheck
--   ./medaka fmt [--stdout|--check|--write] <file.mdk>   format (default: in place)
--   ./medaka new <name>           scaffold a new project
--   ./medaka help | --help | -h   usage
--
-- Stdlib paths (runtime.mdk / core.mdk) resolve from MEDAKA_ROOT, mirroring
-- compiler/build_cmd.mdk's envOr — compiler has no getcwd/executable_name
-- extern.  The implemented subcommands are exactly the dispatch arms below
-- (check/fmt/new/build/run/test/repl/lsp/doc/check-policy/manifest); any other
-- subcommand falls through to the catch-all, which prints "not yet in native
-- CLI" and exits 1.

import tools.check.{runCheck, checkHasErrors, runCheckModules}
import tools.snapshot.{runSnapshotWorker, runSnapshotSupervisor, parseStages}
import tools.fmt.{formatSource}
import tools.new_cmd.{newProject}
import driver.build_cmd.{
  BuildResult,
  BuildOk,
  BuildErr,
  BuildTarget,
  TNative,
  TWasm,
  runBuild,
  envOr,
  defaultMedakaRoot,
}
import support.util.{
  reverseL,
  joinNl,
  splitNl,
  startsWith,
  endsWith,
  anyList,
  contains,
  sortUniqS,
  schemeLineName,
}
import support.ordmap.{OrdMap, omEmpty, omHasKey, omFromNames}
import support.path.{baseOf, chopExt}
import frontend.ast.{Decl(..), Expr(..), Loc(..), Pat, LetBind(..)}
import frontend.parser.{
  parse,
  parseLocated,
  parseWithPositions,
  parseResult,
  ParseError,
  parseErrorLine,
  parseErrorCol,
  parseErrorMessage,
  Positions,
}
import frontend.desugar.{desugar}
import frontend.resolve.{
  resolveModulesToHumane,
  resolveModulesToHumaneG,
  resolveModulesToHumaneGF,
}
import driver.loader.{
  loadProgram,
  loadProgramFilesLocated,
  findProjectRoot,
  entrySearchRoots,
  stdlibTrustedMods,
  unknownModuleIdOf,
  findImportLoc,
  availableModulesHint,
  availableModulesText,
}
import driver.diagnostics.{
  analyzeProject,
  analyzeLocated,
  analyzeLocatedG,
  ppDiagCli,
  ppDiagCliSrc,
  Diag(..),
  Severity(..),
  SevError,
  cjPosition,
  cjRange,
  cjRangeOfLoc,
  cjDiagnostic,
  cjFileEntry,
  cjAllToJson,
  readDiagSrc,
  parseErrCode,
  parseErrHelpFix,
  codeKind,
  optField,
  cjFixJson,
  mkDiag,
}
import json.{Json, JInt, JString, JArray, JObject, jObject, jArray, stringify}
import types.typecheck.{
  elaborateModules,
  resetTypeErrorsSticky,
  hadTypeErrors,
  mainTypeIsAsync,
  mainTypeIsUnit,
}
import eval.eval.{
  evalModulesOutputRun,
  evalModulesOutputAsync,
  currentEvalFile,
  runJsonMode,
  progArgsRef,
}
import tools.test_cmd.{runTest}
import tools.repl.{initSession, replLoop}
import tools.lsp.{runServer}
import tools.doc.{runDoc}
import tools.lint.{
  allRules,
  lintProgram,
  applySuppressions,
  applySuppressionsMulti,
  findingToDiag,
  Finding,
  applyFixes,
  runCrossFileRules,
}
import tools.check_policy.{
  runCheckPolicy,
  runAcceptedPlugin,
  PolicyArgs(..),
  parsePolicyArgs,
  PolicyOutcome(..),
  runManifest,
  parseManifestArgs,
  ManifestArgs(..),
}

-- FLAG for user confirmation: exact version string/format not yet confirmed —
-- using "0.1.0-preview" (the 0.1.0 public-preview target named in AGENTS.md)
-- pending sign-off. No existing version constant was found elsewhere in
-- compiler/ (lsp.mdk hardcodes a literal "0.1.0" for its own protocol reply;
-- new_cmd.mdk hardcodes a literal "0.1.0" into scaffolded medaka.toml — neither
-- is a shared constant this could reuse).
medakaVersion : String
medakaVersion = "0.1.0-preview"

printVersion : Unit -> <IO> Unit
printVersion _ = putStrLn ("medaka " ++ medakaVersion)

main : <IO, Mut, Panic> Unit
main = match args ()
  [] => usage ()
  "help"::_ => usage ()
  "--help"::_ => usage ()
  "-h"::_ => usage ()
  "--version"::_ => printVersion ()
  "-v"::_ => printVersion ()
  "version"::_ => printVersion ()
  "check"::rest => runCheckCmd rest
  "fmt"::rest => runFmtCmd rest
  "new"::rest => runNewCmd rest
  "build"::rest => runBuildCmd rest
  "run"::rest => runRunCmd rest
  "test"::rest => runTestCmd rest
  "snapshot"::rest => runSnapshotCmd rest
  "doc"::rest => runDocCmd rest
  "lint"::rest => runLintCmd rest
  "check-policy"::rest => runCheckPolicyCmd rest
  "manifest"::rest => runManifestCmd rest
  "repl"::rest => runReplCmd rest
  "lsp"::rest => runLspCmd rest
  sub::_ => notYet sub

-- ── usage (mirrors bin/main.ml print_usage) ───────────────────────────────
-- Takes Unit so the interpreter's top-level-value evaluation doesn't fire its
-- IO eagerly (native build only runs main); native CLI prints it on demand.
usage : Unit -> <IO> Unit
usage _ = putStrLn (stringConcat
  [
    "medaka. A functional language compiler\n",
    "\n",
    "Usage:\n",
    "  medaka                    Show this message\n",
    "  medaka run [--release] <file.mdk>   Type-check and run a program\n",
    "  medaka build <file.mdk> [-o <out>]  Compile to a native binary (LLVM + clang)\n",
    "  medaka check [--json] <file.mdk>    Type-check without running\n",
    "  medaka test [file.mdk]    Run doctests + prop tests\n",
    "  medaka bench [file.mdk]   Run bench declarations\n",
    "  medaka doc [file.mdk]     Generate Markdown documentation\n",
    "  medaka lint [paths...]    Lint files/dirs (style rules; --fix, --disable/--only/--deny=<rules,...>)\n",
    "  medaka snapshot [--check|--new] [paths...]  Per-stage snapshot tests (--out <dir>, --stages <a,b,..>)\n",
    "  medaka fmt [paths...]     Format .mdk files in place (or --check)\n",
    "  medaka new <name>         Scaffold a new project directory\n",
    "  medaka lsp                Run the language server over stdio\n",
    "  medaka help               Show this message\n",
    "  medaka --version          Show the compiler version\n",
  ])

-- ── deferred subcommands ──────────────────────────────────────────────────
notYet : String -> <IO, Panic> Unit
notYet sub =
  let _ = ePutStrLn ("medaka: subcommand '" ++ sub ++ "' not yet in native CLI")
  exit 1

-- ── check ─────────────────────────────────────────────────────────────────
-- PARSE-ERROR-LOCATION Stage 1: render a located `ParseError` through the SAME
-- caret-aware `ppDiagCliSrc` + `Diag` machinery the typecheck/resolve text paths
-- use, so EVERY CLI-text parse error gets `file:L:C:` + a source snippet + caret
-- + the stable `P-*`/`L-*` code (and, for the clean single-token hints, a `help`).
-- `parseErrorLine` is 1-based, `parseErrorCol` 0-based — the exact convention
-- `ppDiagCliSrc`/`parseErrHelpFix` expect (matching the `--json` inline build).
ppParseError : String -> String -> ParseError -> String
ppParseError src file e =
  let ploc = Loc file (parseErrorLine e) (parseErrorCol e) (parseErrorLine e) (parseErrorCol e + 1)
  let (h, fx) = parseErrHelpFix (parseErrorMessage e) ploc
  ppDiagCliSrc
    src
    file
    (Diag
      SevError
      (parseErrCode (parseErrorMessage e))
      (parseErrorMessage e)
      (Some ploc)
      h
      fx)

-- Reads <MEDAKA_ROOT>/stdlib/{runtime,core}.mdk + the target, runs
-- check.runCheck, prints schemes/diagnostics.  Mirrors check_main.mdk; exit 0
-- (runCheck reports diagnostics in-band, like the interpreted driver).
--
-- DRIVER-COLLAPSE Phase 4 (OPTION A): `check` now RESOLVES imports.  We load the
-- entry + its transitive imports via loadProgram (same roots/priority as run/build)
-- and route by module count: a 1-module load (no non-core imports) goes through the
-- single-file runCheck (full prelude+user scheme dump, byte-identical to the old
-- behaviour — keeps the no-import goldens green); a multi-module load goes through
-- runCheckModules (multi-module resolve + per-module-frame typecheck), so a valid
-- cross-module reference reports import-aware diagnostics instead of `UnknownModule`.
runCheckCmd : List String -> <IO, Mut, Panic> Unit
runCheckCmd argv =
  let jsonMode = hasFlag "--json" argv
  let allowInternal = hasFlag "--allow-internal" argv
  let typesMode = hasFlag "--types" argv
  let argv2 = dropFlags argv
  match argv2
    [target] =>
      let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
      let rtPath = root ++ "/stdlib/runtime.mdk"
      let corePath = root ++ "/stdlib/core.mdk"
      let stdlibDir = root ++ "/stdlib"
      let roots = entrySearchRoots (dirOf2 target) ++ [stdlibDir]
      match readFile rtPath
        Err msg =>
          let _ = ePutStrLn msg
          exit 1
        Ok rsrc => match readFile corePath
          Err msg =>
            let _ = ePutStrLn msg
            exit 1
          Ok csrc => if jsonMode then runCheckJsonCmd allowInternal rsrc csrc target roots stdlibDir
          else match readFile target
            Err msg =>
              let _ = ePutStrLn msg
              exit 1
            Ok tsrc => match parseResult tsrc
              Err e =>
                let _ = ePutStrLn (ppParseError tsrc target e)
                exit 1
              -- Load with parseLocated (real ELoc spans), mirroring `run`
              -- (line ~678): plain loadProgram uses placeholder-loc `parse`,
              -- which collapses every span to 1:0, so an import-bearing
              -- file's Unbound-variable diagnostic pointed at the import
              -- line instead of the actual use site.
              Ok _ => match map (map dropModPath) (loadProgramFilesLocated (_ => None) target roots)
                Err lmsg =>
                  let _ = ePutStrLn (moduleLoadErrText tsrc target stdlibDir lmsg)
                  exit 1
                Ok mods =>
                  let trusted = stdlibTrustedMods target roots stdlibDir mods
                  checkRoute typesMode allowInternal trusted roots rsrc csrc tsrc target mods
    _ =>
      let _ = ePutStrLn "usage: medaka check [--json] [--types] [--allow-internal] <file.mdk>"
      exit 1
-- G1: print the report (byte-identical stdout for no-import files:
-- diff_native_cli gate), then gate the EXIT CODE on the error predicate
-- so CI `$?` matches OCaml `check` (exit 1 on any error).

-- A load error (missing/cyclic import) is reported verbatim, like
-- build/run; exit 1.  No-fixture single-file files never error here.

-- F3 Chunk B (R-MODULE-LOAD): the loader's `Err "unknown module: X"` carries no
-- location (see loader.mdk's entry-scan doc comment).  `tsrc` is already known
-- to parse (the caller's `parseResult` succeeded), so re-parse it with
-- `parseLocated` (real ELoc/DUse spans) and look up the failing modId's own
-- `import` statement; render through the shared carat formatter when found,
-- else fall back to the bare message (unchanged behaviour).
-- F: an `unknown module` message additionally carries an "available modules:
-- ..." suffix (enumerated from `roots` via loader's `availableModulesHint`) so
-- the CLI-text path — which does not render structured `help` — still surfaces
-- an actionable fix.  Other loader errors (cycle / unreadable file) are
-- unaffected: `unknownModuleIdOf` gates the hint to the one message shape it
-- applies to.
moduleLoadErrText : String -> String -> String -> String -> <IO, Mut> String
moduleLoadErrText tsrc target stdlibDir lmsg = match unknownModuleIdOf lmsg
  None => lmsg
  Some mid =>
    let msg = lmsg ++ availableModulesHint stdlibDir
    match findImportLoc mid (parseLocated tsrc)
      None => msg
      Some loc => ppDiagCliSrc tsrc target (Diag SevError "R-MODULE-LOAD" msg (Some loc) None None)

-- Render every ERROR diagnostic across a loaded multi-module project as located
-- human text (`file:L:C: msg` + caret), reusing the SAME `analyzeProject` the
-- `--json` path uses (line ~549).  This is what lets `check`/`run`/`build`
-- surface an IMPORTED-module type error WITH its location — not just the entry
-- module, and not the loc-free `TYPE ERROR: …`/boolean-deflection they used to
-- collapse to.  `None` when the project has no error diagnostics (clean).
-- Dependency-first file order (helper before entry), same as the loader/JSON.
locatedProjectErrors : String -> List String -> String -> String -> <IO, Mut> Option String
locatedProjectErrors target roots rsrc csrc =
  let cacheRef = Ref []
  let parseCacheRef = Ref []
  let results = analyzeProject cacheRef parseCacheRef (_ => None) target roots rsrc csrc
  let triples = map readDiagSrc results
  let rendered = flatMap renderTripleErrors triples
  match rendered
    [] => None
    _ => Some (joinNl rendered)

renderTripleErrors : (String, String, List Diag) -> List String
renderTripleErrors (path, src, diags) =
  map (ppDiagCliSrc src path) (filter isDiagError diags)

-- For the run/build multi-module gates, whose SOUNDNESS predicate stays the
-- looser `hadTypeErrors` (checkModulesHasErrors over-rejects valid code — see
-- typecheckGateRoute's note): once that gate has already fired, render the located
-- per-module diagnostics for the human message, falling back to the generic
-- deflection only if analyzeProject surfaces none (never leaves the user with
-- exit 1 and no text).
locatedOrGeneric : String -> List String -> String -> String -> <IO, Mut> String
locatedOrGeneric target roots rsrc csrc = match locatedProjectErrors target roots rsrc csrc
  Some t => t
  None => "error: type error in "
    ++ target
    ++ ". Run `medaka check` for details"

-- Route by module count: a single loaded module (no non-core imports) ⇒ the
-- single-file runCheck (byte-identical full dump); >1 module ⇒ the multi-module
-- import-resolving report.  `mods` is dependency-first, entry last.
-- `target` is passed for positioned error output (Stage-A: file:line:col: message).
--
-- 0.1.0 preview UX (audit #6): bare `medaka check` on a clean single-file
-- program used to dump the ~120-line prelude `=== TYPES ===` scheme corpus
-- ahead of the user's own bindings — noisy and beginner-unfriendly. `typesMode`
-- (the `--types` flag) opts back into that full dump, byte-identical to the
-- historical behaviour (preserves the diff_native_cli goldens, which now pass
-- `--types`). Bare `check` instead keeps only the lines naming one of the
-- user's OWN top-level bindings (`userSchemeLines`) — filtering happens HERE,
-- CLI-only, so the probe-driven goldens (check_main.mdk et al., which call
-- `runCheck`/`runCheckModules` directly) keep dumping unconditionally.
checkRoute : Bool -> Bool -> List String -> List String -> String -> String -> String -> String -> List (String, List Decl) -> <IO, Mut, Panic> Unit
checkRoute typesMode allowInternal trusted _ rsrc csrc tsrc target [(mid, decls)] =
  -- BUGFIX (internal-extern noise on stdlib/compiler self-checks): the caller
  -- already computed `trusted` (stdlibTrustedMods, owning-root based) for
  -- EVERY module count, but this single-module arm used to discard it and
  -- gate purely on the CLI `--allow-internal` flag — so `medaka check` on a
  -- bare stdlib file (e.g. `stdlib/array.mdk`, no non-core imports ⇒ this
  -- arm) flagged its OWN legitimate internal-extern calls as errors unless
  -- the flag was passed every time, even with MEDAKA_ROOT correctly set.
  -- Honour `trusted` here too, matching the multi-module arm below.
  let diags = analyzeLocatedG (allowInternal || contains mid trusted) rsrc csrc tsrc
  let errs = filter isDiagError diags
  match errs
    [] =>
      -- Clean (no errors): the scheme dump goes to STDOUT loc-free, but any
      -- non-exhaustive-match WARNING is re-rendered LOCATED (file:L:C: + caret)
      -- to STDERR, byte-consistent with how errors render (line ~277).  runCheck
      -- bundles the warning loc-free into stdout, so we strip its "Warning: …"
      -- lines and re-emit them from `diags` (which carries the real Loc the
      -- --json path already reports).  See ERROR-QUALITY.md (Located dimension).
      let warns = filter isDiagWarn diags
      let dump = stripWarningLines (runCheck rsrc csrc tsrc)
      let report = if typesMode then dump else userSchemeLines decls dump
      let _ = putStr report
      -- 0.1.0 beginner-footgun warning (main-shape, see below): reuse the same
      -- elaborateModules the multi-module route calls just for mainSchemeRef —
      -- runCheck's own single-file path never populates it.
      let mainWarns = mainShapeWarnings (desugar (parse rsrc)) (desugar (parse csrc)) [(mid, desugar decls)] decls
      let _ = emitLocatedWarnings tsrc target (warns ++ mainWarns)
      ()
    _ =>
      let _ = ePutStrLn (joinNl (map (ppDiagCliSrc tsrc target) errs))
      exit 1
checkRoute typesMode allowInternal trusted roots rsrc csrc tsrc target mods =
  let rtD = desugar (parse rsrc)
  let coreD = desugar (parse csrc)
  let modsD = map desugarPair mods
  -- RESOLVE-phase errors (e.g. importing a name a module does not export —
  -- PrivateNameAccess) go to STDERR + exit 1, mirroring the single-file arm's
  -- channel discipline (errors→stderr).  Previously these were `putStr` to STDOUT
  -- unprefixed, so they were invisible to any errors-on-stderr consumer (the
  -- error-quality corpus captured them as empty).  The clean/type-error report
  -- still goes to STDOUT (the check_cli_modules gate expects TYPE ERROR there).
  let resDiags = resolveModulesToHumaneGF target allowInternal trusted rtD coreD modsD
  match resDiags
    "" =>
      -- BUGFIX (imported-module diagnostics): when there ARE type errors, render
      -- the accumulated per-module diagnostics LOCATED (`file:L:C: msg` + caret),
      -- across ALL modules — reusing the exact analyzeProject surface `--json`
      -- mirrors — instead of runCheckModules's loc-free `TYPE ERROR: …` (which
      -- also dropped every imported-module error's location).  Clean ⇒ the schemes
      -- dump + main-shape warnings, unchanged.
      match locatedProjectErrors target roots rsrc csrc
        Some errText =>
          let _ = putStr errText
          exit 1
        None =>
          let _ = putStr (runCheckModules allowInternal trusted rtD coreD modsD)
          -- 0.1.0 main-shape warning (see below): runCheckModules/
          -- checkModulesHasErrors never call elaborateModules, so mainSchemeRef
          -- is never populated on this route either — mainShapeWarnings runs
          -- it itself (only when the cheap syntactic arity check finds nothing).
          let mainWarns = match lastModPair mods
            Some (emid, edecls) => mainShapeWarnings rtD coreD modsD edecls
            None => []
          emitLocatedWarnings tsrc target mainWarns
    _ =>
      let _ = ePutStrLn resDiags
      exit 1

-- ── main-shape beginner-footgun warning (0.1.0 audit #3) ────────────────────
-- `medaka run` evaluates top-level bindings and checks `main` EXISTS but never
-- APPLIES it: a `main` that isn't a zero-arg Unit-typed value silently no-ops
-- (exit 0, no output, no diagnostic).  Two distinct beginner shapes surface the
-- same way:
--   (1) `main` is a FUNCTION (`main () = …` / `main x = …`) — visible on the
--       raw (pre-desugar) Decl as a non-empty param list; no type info needed.
--   (2) `main` is a zero-arg value whose inferred type is neither Unit nor
--       `Async _` (e.g. `main = 5`) — reuses mainTypeIsUnit/mainTypeIsAsync,
--       the same hooks `runProgramOutput`/the emitter already use to decide how
--       to force `main`; only meaningful once elaborateModules has stamped
--       typecheck.mdk's mainSchemeRef.
-- Both render as a LOCATED warning (file:L:C: + caret) via the same
-- ppDiagCliSrc/emitLocatedWarnings surface non-exhaustive-match warnings use.

-- Find a top-level `main` DFunDef among a module's raw decls (skipping @attr
-- wrappers).  Returns its param list + body so callers can inspect arity and
-- locate the body's first ELoc span.
findMainFunDef : List Decl -> Option (List Pat, Expr)
findMainFunDef [] = None
findMainFunDef ((DAttrib _ d)::rest) = findMainFunDef (d::rest)
findMainFunDef ((DFunDef _ "main" ps body)::_) = Some (ps, body)
findMainFunDef (_::rest) = findMainFunDef rest

-- Best-effort location: the first ELoc span walking the outermost EApp spine
-- (mirrors frontend/desugar.mdk's private `exprLoc`, duplicated here so this
-- stays self-contained in medaka_cli.mdk per the F5 ownership split).
mainBodyLoc : Expr -> Option Loc
mainBodyLoc (ELoc l _) = Some l
mainBodyLoc (EApp f _) = mainBodyLoc f
mainBodyLoc _ = None

mainArityMsg : String
mainArityMsg = "'main' must be a value of type Unit. Write 'main = …', not 'main () = …' or 'main x = …' ('medaka run' never applies main; it forces a zero-arg main for its effects)"

mainNonUnitMsg : String
mainNonUnitMsg = "'main' must be a value of type Unit (e.g. an IO action). 'medaka run' only forces main for its side effects and prints nothing for a plain value; wrap the intended effect, e.g. 'main = println \"hi\"'"

-- The ARITY shape (`main () = …` / `main x = …`) needs no type info, so it's
-- safe to call before (or without) elaborateModules — and takes precedence
-- over the non-Unit-value check below (no double warning).
mainArityWarning : List Decl -> Option Diag
mainArityWarning decls = match findMainFunDef decls
  Some (_::_, body) =>
    Some (mkDiag SevWarning "W-MAIN-SHAPE" mainArityMsg (mainBodyLoc body))
  _ => None

-- The non-Unit/non-Async VALUE shape (`main = 5`).  Only meaningful once
-- elaborateModules has run (mainSchemeRef populated) — callers must ensure
-- that happened first.
mainNonUnitWarning : List Decl -> <Mut> Option Diag
mainNonUnitWarning decls = match findMainFunDef decls
  Some ([], body) =>
    if mainTypeIsUnit () || mainTypeIsAsync () then
      None
    else
      Some (mkDiag SevWarning "W-MAIN-SHAPE" mainNonUnitMsg (mainBodyLoc body))
  _ => None

-- Shared driver: the arity check is free (no typecheck needed); only when it
-- finds nothing do we pay for an extra elaborateModules call (routes that
-- don't already run it for their own purposes — both `check` arms) so
-- mainSchemeRef is populated for the non-Unit-value check.  `modsDFull` is the
-- FULL desugared module list (elaborateModules needs the whole graph, not just
-- the entry) — the caller already has it computed for its own typecheck pass.
mainShapeWarnings : List Decl -> List Decl -> List (String, List Decl) -> List Decl -> <Mut> List Diag
mainShapeWarnings rtD coreD modsDFull entryDecls = match mainArityWarning entryDecls
  Some d => [d]
  None =>
    let _ = elaborateModules rtD coreD modsDFull
    match mainNonUnitWarning entryDecls
      Some d => [d]
      None => []

-- Last (String, List Decl) pair — the entry module (loader's `mods` is
-- dependency-first, entry last).
lastModPair : List (String, List Decl) -> Option (String, List Decl)
lastModPair [] = None
lastModPair [p] = Some p
lastModPair (_::rest) = lastModPair rest

-- Drop check's non-positional flags (--release is silently ignored; --json is
-- handled by the caller via hasFlag before dropFlags strips it).
dropFlags : List String -> List String
dropFlags [] = []
dropFlags ("--json"::rest) = dropFlags rest
dropFlags ("--release"::rest) = dropFlags rest
dropFlags ("--allow-internal"::rest) = dropFlags rest
dropFlags ("--types"::rest) = dropFlags rest
dropFlags (x::rest) = x :: dropFlags rest

-- True if the flag appears anywhere in argv.
hasFlag : String -> List String -> Bool
hasFlag _ [] = False
hasFlag flag (x::rest)
  | x == flag = True
  | otherwise = hasFlag flag rest

-- ── check --json ───────────────────────────────────────────────────────────
-- Mirrors OCaml's `check --json` (bin/main.ml line ~863):
--   analyze_project → all_diagnostics_to_json → print_endline → exit
-- Key ordering matches OCaml/Yojson alphabetical insertion:
--   file entry:   file, diagnostics
--   diagnostic:   message, range, severity, source
--   range:        end, start
--   position:     character, line

-- Run check --json: mirrors OCaml's check --json (analyze_project → JSON).
-- Routes by module count (mirrors checkRoute) because the compiler analyzeProject
-- multi-module path has a known limitation for single-file type errors:
--   single module (no non-core imports) → analyzeLocated (single-file path)
--   multi-module → analyzeProject (loader path)
-- Parse errors are detected FIRST (before loadProgram panics) via parseResult.
-- Output: {"files":[{"file":<path>,"diagnostics":[...]}]}
-- Exits 1 if any error diagnostic; 0 otherwise.
runCheckJsonCmd : Bool -> String -> String -> String -> List String -> String -> <IO, Mut, Panic> Unit
runCheckJsonCmd allowInternal rsrc csrc target roots stdlibDir =
  let src = readFileSafe target
  match parseResult src
    Err e =>
      -- Parse error: emit a single located diagnostic, matching LSP format.
      let ln = parseErrorLine e - 1
      let col = parseErrorCol e
      let r = cjRange ln col ln (col + 1)
      let pcode = parseErrCode (parseErrorMessage e)
      -- Stage 2 fix (agent-quality nicety): the two clean single-token parse
      -- hints (`::`→`:`, `/=`→`!=`) get a machine-applicable `fix` + `help`
      -- here too (this JSON diag is built inline, not via `cjDiagnostic`).
      -- `parseErrHelpFix` needs a `Loc` with the SAME 1-based line + 0-based
      -- col convention as `parseErrLoc` (`parseErrorLine e`, not `ln`).
      let ploc = Loc target (parseErrorLine e) col (parseErrorLine e) (col + 1)
      let (phelp, pfix) = parseErrHelpFix (parseErrorMessage e) ploc
      let diagJson = jObject ([("code", JString pcode)] ++ optField "fix" (map cjFixJson pfix) ++ optField "help" (map JString phelp) ++ [("kind", JString (codeKind pcode)), ("message", JString (parseErrorMessage e)), ("range", r), ("severity", JInt 1), ("source", JString "medaka")])
      let filesJson = jObject [("file", JString target), ("diagnostics", JArray (arrayFromList [diagJson]))]
      let _ = println (stringify (jObject [("files", JArray (arrayFromList [filesJson]))]))
      exit 1
    Ok _ =>
      match loadProgram target roots
        Err lmsg =>
          -- Load error (missing import etc.): report as single diagnostic.
          -- F3 Chunk B: entry-scan the (already-known-to-parse) source for the
          -- failing DUse's own span — see moduleLoadErrText's doc comment.
          -- F: an `unknown module` error additionally gets an "available
          -- modules: ..." suffix on the message AND a structured `help` (JSON
          -- consumers get both; `unknownModuleIdOf` gates this to the one
          -- message shape it applies to — other loader errors are untouched).
          let mloc = match unknownModuleIdOf lmsg
            None => None
            Some mid => findImportLoc mid (parseLocated src)
          let mhelp = match unknownModuleIdOf lmsg
            None => None
            Some _ => match availableModulesText stdlibDir
              "" => None
              txt => Some txt
          let jmsg = lmsg ++ (match unknownModuleIdOf lmsg
            None => ""
            Some _ => availableModulesHint stdlibDir)
          let triples = [(target, src, [Diag SevError "R-MODULE-LOAD" jmsg mloc mhelp None])]
          let _ = println (cjAllToJson triples)
          exit 1
        Ok mods => match mods
          [(mid, _)] =>
            -- Single module: analyzeLocated (single-file path, correct for type errors).
            -- Same fix as checkRoute: honour the owning-root trust signal too
            -- (stdlibTrustedMods), not just `--allow-internal`, so a bare
            -- stdlib/compiler file checked via `--json` isn't noise-flagged.
            let trusted = stdlibTrustedMods target roots stdlibDir mods
            let diags = analyzeLocatedG (allowInternal || contains mid trusted) rsrc csrc src
            let _ = println (cjAllToJson [(target, src, diags)])
            let hasErr = any isDiagError diags
            if hasErr then exit 1 else ()
          _ =>
            -- Multi-module: analyzeProject.
            let cacheRef = Ref []
            let parseCacheRef = Ref []
            let results = analyzeProject cacheRef parseCacheRef (_ => None) target roots rsrc csrc
            let triples = map readDiagSrc results
            let _ = println (cjAllToJson triples)
            let hasErr = any cjHasErr results
            if hasErr then exit 1 else ()

readFileSafe : String -> <IO> String
readFileSafe path = match readFile path
  Ok src => src
  Err _ => ""

cjHasErr : (String, List Diag) -> Bool
cjHasErr (_, diags) = any isDiagError diags

isDiagError : Diag -> Bool
isDiagError (Diag SevError _ _ _ _ _) = True
isDiagError _ = False

isDiagWarn : Diag -> Bool
isDiagWarn d = not (isDiagError d)

-- Drop the loc-free "Warning: …" lines runCheck bundles into its scheme dump, so
-- the located re-render (emitLocatedWarnings) is the single warning surface —
-- otherwise the CLI would print each warning twice (loc-free + located).  Scheme
-- lines are "name : type", never "Warning: …", so this only removes warnings.
stripWarningLines : String -> String
stripWarningLines s =
  joinNl (filter (l => not (startsWith "Warning: " l)) (splitNl s))

-- 0.1.0 preview UX (audit #6): filter `runCheck`'s "name : scheme" dump down to
-- just the lines naming one of THIS file's own top-level bindings, dropping the
-- prelude's ~120 always-present schemes (eq/append/map/println/…). Each kept
-- line's name is matched by exact "\{name} : " prefix (scheme lines are never
-- "Warning: …" — those are already stripped by `stripWarningLines` upstream).
--
-- PERF: O(lines × log names).  This used to be O(lines × names) — an `anyList`
-- over EVERY top-level name per dump line, each probe allocating a fresh
-- "\{n} : " prefix string.  On a 2k-function file that is ~8.5M prefix builds +
-- compares, and it was the single largest cost of `medaka check` on a large
-- file.  A line's candidate name is uniquely determined (`schemeLineName`: the
-- text before its first " : ", since identifiers hold no space), so one set
-- lookup decides the line.
userSchemeLines : List Decl -> String -> String
userSchemeLines decls report =
  let names = omFromNames (topLevelNames decls) omEmpty
  joinNl (filter (namesUserBinding names) (splitNl report))

namesUserBinding : OrdMap Unit -> String -> Bool
namesUserBinding names l = match schemeLineName l
  Some n => omHasKey n names
  None => False

-- Every name a top-level Decl of this file introduces into value scope,
-- regardless of `pub` (single-file `check` has no module boundary to gate on).
topLevelNames : List Decl -> List String
topLevelNames [] = []
topLevelNames ((DAttrib _ d)::rest) = topLevelNames [d] ++ topLevelNames rest
topLevelNames ((DFunDef _ n _ _)::rest) = n :: topLevelNames rest
topLevelNames ((DTypeSig _ n _)::rest) = n :: topLevelNames rest
topLevelNames ((DExtern _ n _)::rest) = n :: topLevelNames rest
topLevelNames ((DLetGroup _ binds)::rest) = map letBindName binds
  ++ topLevelNames rest
topLevelNames (_::rest) = topLevelNames rest

letBindName : LetBind -> String
letBindName (LetBind n _) = n

-- Re-render warning Diags LOCATED (file:L:C: + caret) to STDERR, exactly like
-- errors (ppDiagCliSrc).  Warnings do not change the exit code (stays 0).
emitLocatedWarnings : String -> String -> List Diag -> <IO> Unit
emitLocatedWarnings _ _ [] = ()
emitLocatedWarnings src file ws =
  ePutStrLn (joinNl (map (ppDiagCliSrc src file) ws))

-- Mirrors lib/fmt.ml's single-file dispatch: default --write (in place),
-- --stdout prints, --check reports.  A single literal-file target keeps the
-- ORIGINAL single-file path byte-for-byte (goldens depend on this).  A
-- directory target (or multiple targets) recursively expands via the SAME
-- `expandLintTarget`/`collectMdkFiles` walk `medaka lint` uses (dir/file
-- discriminated by `listDir`; skips dotfiles/dot-dirs; no test/-exclusion,
-- matching lint's own behavior) and formats every `.mdk` found, aggregating
-- exit codes the way `medaka lint`'s multi-file path does (any error → exit 1).
data FmtMode = FmtWrite | FmtStdout | FmtCheck

runFmtCmd : List String -> <IO, Mut, Panic> Unit
runFmtCmd argv = match parseFmtArgs argv FmtWrite []
  Err msg =>
    let _ = ePutStrLn msg
    exit 2
  Ok (_, []) =>
    let _ = ePutStrLn "Usage: medaka fmt [--check | --stdout | --write] <path>..."
    exit 2
  -- `listDir` Err = literal file (EXACT original single-file behavior); Ok =
  -- a directory, recursively expanded.
  Ok (mode, [target]) => match listDir target
    Err _ => fmtOne mode target
    Ok _ => fmtManyTargets mode [target]
  Ok (mode, targets) => fmtManyTargets mode targets

-- Multiple targets and/or a directory target: expand to concrete .mdk files
-- and format each, aggregating. `--stdout` only makes sense for one file.
fmtManyTargets : FmtMode -> List String -> <IO, Mut, Panic> Unit
fmtManyTargets FmtStdout _ =
  let _ = ePutStrLn "medaka fmt: --stdout requires exactly one file"
  exit 2
fmtManyTargets mode targets =
  let files = flatMap expandLintTarget targets
  match files
    [] =>
      let _ = ePutStrLn "medaka fmt: no .mdk files found"
      exit 2
    _ => if fmtFilesGo mode files False then exit 1 else ()

-- Fold over an expanded file list, formatting each and aggregating whether any
-- error occurred (read failure, parse error, or --check finding unformatted
-- output) — mirrors `lintFilesGo`'s aggregation.
fmtFilesGo : FmtMode -> List String -> Bool -> <IO, Mut, Panic> Bool
fmtFilesGo _ [] acc = acc
fmtFilesGo mode (f::rest) acc =
  let hadErr = fmtOneReport mode f
  fmtFilesGo mode rest (acc || hadErr)

-- Like `fmtOne` but reports to stdout/stderr and RETURNS whether an error
-- occurred instead of exiting immediately, so `fmtFilesGo` can aggregate
-- across many files (the single-file path still calls `fmtOne` directly and
-- exits per its own original codes, unchanged).
fmtOneReport : FmtMode -> String -> <IO, Mut, Panic> Bool
fmtOneReport mode file = match readFile file
  Err msg =>
    let _ = ePutStrLn "\{file}: \{msg}"
    True
  Ok src => match parseResult src
    Err e =>
      let _ = ePutStrLn (ppParseError src file e)
      True
    Ok _ =>
      let formatted = formatSource src
      match mode
        FmtStdout =>
          let _ = putStr formatted
          False
        FmtCheck => if formatted == src then False
        else
          let _ = ePutStrLn (file ++ ": not formatted")
          True
        FmtWrite => if formatted == src then False
        else match writeFile file formatted
          Err msg =>
            let _ = ePutStrLn "\{file}: \{msg}"
            True
          Ok _ => False

parseFmtArgs : List String -> FmtMode -> List String -> Result String (FmtMode, List String)
parseFmtArgs [] mode acc = Ok (mode, reverseL acc)
parseFmtArgs ("--check"::rest) _ acc = parseFmtArgs rest FmtCheck acc
parseFmtArgs ("--stdout"::rest) _ acc = parseFmtArgs rest FmtStdout acc
parseFmtArgs ("--write"::rest) _ acc = parseFmtArgs rest FmtWrite acc
parseFmtArgs ("-w"::rest) _ acc = parseFmtArgs rest FmtWrite acc
parseFmtArgs (x::rest) mode acc =
  if stringLength x > 0 && stringSlice 0 1 x == "-" then
    Err ("medaka fmt: unknown flag: " ++ x)
  else
    parseFmtArgs rest mode (x::acc)

fmtOne : FmtMode -> String -> <IO, Mut, Panic> Unit
fmtOne mode file = match readFile file
  Err msg =>
    let _ = ePutStrLn "\{file}: \{msg}"
    exit 2
  -- PARSE-ERROR-LOCATION Stage 1: surface a located parse error before
  -- formatSource's panicking `parse` fires a bare `parse error`.
  Ok src => match parseResult src
    Err e =>
      let _ = ePutStrLn (ppParseError src file e)
      exit 1
    Ok _ =>
      let formatted = formatSource src
      match mode
        FmtStdout => putStr formatted
        FmtCheck => if formatted == src then ()
        else
          let _ = ePutStrLn (file ++ ": not formatted")
          exit 1
        FmtWrite => if formatted == src then ()
        else match writeFile file formatted
          Err msg =>
            let _ = ePutStrLn "\{file}: \{msg}"
            exit 2
          Ok _ => ()

-- ── new ───────────────────────────────────────────────────────────────────
runNewCmd : List String -> <IO, Panic> Unit
runNewCmd [name] =
  let code = newProject name
  if code == 0 then () else exit code
runNewCmd _ =
  let _ = ePutStrLn "Usage: medaka new <name>"
  exit 2

-- ── build ─────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `build` arm (Build_cmd.run) + build_main.mdk: parse
-- `<entry.mdk> [-o <out>]`, then drive build_cmd.runBuild (emit IR via a fresh
-- emitter subprocess → clang + C runtime + Boehm GC → native binary).  Paths
-- come from the environment (MEDAKA_ROOT/MEDAKA/CC) since compiler has no
-- getcwd/executable_name extern.  MEDAKA defaults to "./medaka" so a build with
-- no MEDAKA set re-invokes THIS native binary as the emitter host (no OCaml).
runBuildCmd : List String -> <IO, Mut, Panic> Unit
runBuildCmd argv = match parseBuildArgs argv
  Err msg =>
    let _ = ePutStrLn msg
    exit 1
  Ok (input, outOpt, target) => if not (fileExists input) then
    let _ = ePutStrLn ("error: no such file: " ++ input)
    exit 1
  else
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let medaka = envOr "MEDAKA" "medaka"
    let cc = envOr "CC" "clang"
    let inputAbs = input
    let allowInternal = hasFlag "--allow-internal" argv
    let outPath = match outOpt
      Some o => o
      None => defaultOutPath target input
    match typecheckGate allowInternal root inputAbs
      TGErr msg =>
        let _ = ePutStrLn msg
        exit 1
      TGOk => match runBuild root medaka cc target inputAbs outPath
        BuildOk msg => println msg
        BuildErr msg =>
          let _ = ePutStrLn msg
          exit 1

-- Default output path per target: native drops the extension (a bare exe name);
-- wasm appends `.wasm` to the entry's base.
defaultOutPath : BuildTarget -> String -> String
defaultOutPath TNative input = chopExt (baseOf input)
defaultOutPath TWasm input = chopExt (baseOf input) ++ ".wasm"
-- G1 (SOUNDNESS): typecheck the whole module graph BEFORE shelling out to
-- the emitter.  runBuild emits/clangs whatever the emitter produces — for
-- an ill-typed program that is garbage (the G1 bug), so we abort here on any
-- type error.  Mirrors the OCaml driver's STEP-0 check gate.

-- G1 typecheck gate result: clean / a diagnostic (resolve or type error, or a
-- pre-typecheck read/load failure) whose message we surface verbatim.
data TypecheckGate = TGOk | TGErr String

-- Load the entry + transitive imports and run the SAME front-end `medaka check`
-- runs, reporting whether any error fired AND rendering it exactly as `check`
-- does.  This must be the CHECK path, not the EMIT path (elaborateModules):
-- elaborateModules sets implInferEnabled and deliberately SKIPS checkImplObligations
-- (a check-only diagnostic the emit driver doesn't want), so an ill-typed program
-- like `"x" + 1` slips past hadTypeErrors and reaches the emitter, which fails
-- with a confusing downstream `emitter failed …`.  We instead mirror checkRoute:
-- surface the exact diagnostic `check` prints and abort BEFORE the emitter/clang.
-- Read/load failures become TGErr (surfaced as-is) so the caller mirrors
-- runBuild/loadProgram's own diagnostics.
typecheckGate : Bool -> String -> String -> <IO, Mut, Panic> TypecheckGate
typecheckGate allowInternal root input =
  let rtPath = root ++ "/stdlib/runtime.mdk"
  let corePath = root ++ "/stdlib/core.mdk"
  let stdlibDir = root ++ "/stdlib"
  let roots = entrySearchRoots (dirOf2 input) ++ [stdlibDir]
  match readFile rtPath
    Err msg => TGErr msg
    Ok rsrc => match readFile corePath
      Err msg => TGErr msg
      Ok csrc => match readFile input
        Err msg => TGErr msg
        -- PARSE-ERROR-LOCATION Stage 1: a located parse diagnostic before
        -- loadProgram's panicking `parse` fires a bare `parse error`.
        Ok tsrc => match parseResult tsrc
          Err e => TGErr (ppParseError tsrc input e)
          Ok _ => match loadProgram input roots
            Err msg => TGErr msg
            Ok mods =>
              let trusted = stdlibTrustedMods input roots stdlibDir mods
              typecheckGateRoute allowInternal trusted roots rsrc csrc tsrc input mods

-- Route by module count.  A single loaded module (no non-core imports) runs the
-- ACCURATE located check `medaka check` uses for single files — analyzeLocatedG
-- (which runs checkImplObligations, the very pass the emit path skips and the one
-- that catches `"x" + 1`'s `No impl of Num for String`) — and renders BYTE-IDENTICAL
-- carat diagnostics via ppDiagCliSrc.  This is the case the G1 bug fixture exercises.
--
-- The MULTI-MODULE case keeps the emit-path predicate (resolve diagnostics +
-- elaborate + hadTypeErrors) it always used.  We deliberately do NOT gate a
-- multi-module build on the multi-module obligation check (checkModulesHasErrors):
-- it OVER-REJECTS valid code — e.g. it flags the compiler's own source with a
-- spurious `No impl of Alternative for Parser`, which would break every oracle
-- build of a compiler entry even though those programs typecheck-for-emit, build,
-- and self-host cleanly.  So multi-module keeps its prior (looser but sound)
-- behaviour; the located single-file path is what this fix tightens.
typecheckGateRoute : Bool -> List String -> List String -> String -> String -> String -> String -> List (String, List Decl) -> <IO, Mut, Panic> TypecheckGate
typecheckGateRoute allowInternal trusted _ rsrc csrc tsrc target [(mid, _)] =
  -- Same fix as checkRoute's single-module arm: honour the caller-computed
  -- `trusted` (owning-root) signal here too, not just `--allow-internal`.
  let diags = analyzeLocatedG (allowInternal || contains mid trusted) rsrc csrc tsrc
  let errs = filter isDiagError diags
  match errs
    [] => TGOk
    _ => TGErr (joinNl (map (ppDiagCliSrc tsrc target) errs))
typecheckGateRoute allowInternal trusted roots rsrc csrc tsrc target mods =
  let rtD = desugar (parse rsrc)
  let coreD = desugar (parse csrc)
  let modsD = map desugarPair mods
  let resDiags = resolveModulesToHumaneGF target allowInternal trusted rtD coreD modsD
  match resDiags
    "" =>
      let _ = resetTypeErrorsSticky ()
      let _ = elaborateModules rtD coreD modsD
      match hadTypeErrors ()
        -- Gate stays the looser (sound, non-over-rejecting) hadTypeErrors, but the
        -- MESSAGE is now the located per-module diagnostics (matching `--json`/
        -- `check`), so a build failure points at the offending file:L:C — including
        -- an IMPORTED module — instead of the opaque entry-only deflection.
        True => TGErr (locatedOrGeneric target roots rsrc csrc)
        False => TGOk
    _ => TGErr resDiags

-- Parse `[-o <out>] [--target <native|wasm>]`; first remaining positional is the
-- input.  Default target is TNative (the LLVM/clang path) — purely additive, the
-- no-`--target` behaviour is unchanged.
parseBuildArgs : List String -> Result String (String, Option String, BuildTarget)
parseBuildArgs argv = parseBuildGo argv [] None TNative

parseBuildGo : List String -> List String -> Option String -> BuildTarget -> Result String (String, Option String, BuildTarget)
parseBuildGo [] acc out target = finishBuildArgs (reverseL acc) out target
parseBuildGo ("-o"::v::rest) acc out target =
  parseBuildGo rest acc (Some v) target
parseBuildGo ["-o"] _ _ _ = Err "error: -o requires an argument"
parseBuildGo ("--target"::v::rest) acc out _ = match parseTarget v
  Err msg => Err msg
  Ok t => parseBuildGo rest acc out t
parseBuildGo ["--target"] _ _ _ =
  Err "error: --target requires an argument (native|wasm)"
parseBuildGo ("--allow-internal"::rest) acc out target =
  parseBuildGo rest acc out target
parseBuildGo (x::rest) acc out target = parseBuildGo rest (x::acc) out target

parseTarget : String -> Result String BuildTarget
parseTarget "native" = Ok TNative
parseTarget "wasm" = Ok TWasm
parseTarget other =
  Err ("error: unknown --target '" ++ other ++ "' (expected native|wasm)")

finishBuildArgs : List String -> Option String -> BuildTarget -> Result String (String, Option String, BuildTarget)
finishBuildArgs [] _ _ =
  Err "usage: medaka build [--target native|wasm] <file.mdk> [-o <out>]"
finishBuildArgs [input] out target = Ok (input, out, target)
finishBuildArgs _ _ _ = Err "error: medaka build takes exactly one input file"

-- ── run ───────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `run` arm + eval_typed_modules_main.mdk: load the entry
-- + its transitive imports (dependency-first), desugar each, elaborateModules
-- (marker + typecheck route-stamping over the module graph), then evalModules
-- forces `main` for IO and returns the captured stdout.  `main` must be a
-- zero-arg value (`main = …`); top-level nullary bindings are LAZY (Phase-125),
-- so only effects reached from main run.  Roots: the entry's dir (user modules
-- shadow stdlib) then MEDAKA_ROOT/stdlib — same priority as the OCaml loader.
-- `--release`/`--json` are accepted-but-ignored (dropFlags), matching `check`.
--
-- ARGS NOTE.  `medaka run FILE a b c` passes a/b/c as the program's args.  The
-- native runtime's `args` extern returns the WHOLE process argv[1..] (set once in
-- @main's prologue), so a program run this way observes the CLI's own argv —
-- unlike the OCaml driver, which slices argv[3..].  This only matters for
-- programs that read `args ()`; the common `main = …` case is unaffected.  The
-- first positional after dropFlags is the entry; any further positionals are
-- the program's intended args (passthrough; observed via the native extern).
--
-- Shared eval tail: once the gate has ruled the program CLEAN and the whole
-- module graph has been elaborated (route-stamping via the per-module
-- typecheck, mainSchemeRef populated), force `main`.  Only reached AFTER the
-- check-strength gate below (single-file: analyzeLocatedG; multi-module:
-- resolve + hadTypeErrors), so a genuinely ill-typed program never reaches
-- evalModulesOutput (G1 soundness invariant).
finishRunEval : String -> Bool -> (List Decl, List (String, List Decl)) -> List (String, List Decl) -> <IO, Mut, Panic> Unit
finishRunEval target jsonMode elaborated mods =
  -- 0.1.0 main-shape warning: elaborateModules already ran over the WHOLE graph,
  -- so mainSchemeRef is already populated — no extra typecheck pass needed.
  let mainWarns = match lastModPair mods
    Some (_, edecls) => match mainArityWarning edecls
      Some d => [d]
      None => match mainNonUnitWarning edecls
        Some d => [d]
        None => []
    None => []
  let _ = emitLocatedWarnings (readFileSafe target) target mainWarns
  let _ = setRef currentEvalFile target
  let _ = setRef runJsonMode jsonMode
  putStr (runProgramOutput (fst elaborated) (snd elaborated))

runRunCmd : List String -> <IO, Mut, Panic> Unit
runRunCmd argv =
  let jsonMode = hasFlag "--json" argv
  match dropFlags argv
    [] =>
      let _ = ePutStrLn "usage: medaka run [--release] [--json] <file.mdk>"
      exit 1
    target::progArgs =>
      let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
      let rtPath = root ++ "/stdlib/runtime.mdk"
      let corePath = root ++ "/stdlib/core.mdk"
      let stdlibDir = root ++ "/stdlib"
      let roots = entrySearchRoots (dirOf2 target) ++ [stdlibDir]
      let allowInternal = hasFlag "--allow-internal" argv
      -- publish the args AFTER the target for the run-path `args` extern
      -- (eval.mdk's pArgs reads this Ref): `medaka run prog.mdk a b` ⇒ ["a","b"],
      -- matching what the same program's compiled binary sees.
      let _ = setRef progArgsRef progArgs
      match readFile rtPath
        Err msg =>
          let _ = ePutStrLn msg
          exit 1
        Ok rsrc => match readFile corePath
          Err msg =>
            let _ = ePutStrLn msg
            exit 1
          -- Parse the user modules with parseLocated (real ELoc spans) so a
          -- runtime error (E-*) can report a correct file:L:C.  Plain loadProgram
          -- uses placeholder-loc `parse`, which collapses every span to 1:0.
          -- Structurally identical decls → eval output byte-identical.
          -- PARSE-ERROR-LOCATION Stage 1: surface a located parse error on the
          -- entry file BEFORE loadProgramFilesLocated's panicking `parse` fires a
          -- bare `parse error`.  Error-path only; valid input is unaffected.
          Ok csrc => match parseResult (readFileSafe target)
            Err e =>
              let _ = ePutStrLn (ppParseError (readFileSafe target) target e)
              exit 1
            Ok _ => match map (map dropModPath) (loadProgramFilesLocated (_ => None) target roots)
              Err msg =>
                let _ = ePutStrLn msg
                exit 1
              Ok mods =>
                let rtD = desugar (parse rsrc)
                let coreD = desugar (parse csrc)
                let modsD = map desugarPair mods
                let trusted = stdlibTrustedMods target roots stdlibDir mods
                -- Route by module count, mirroring `checkRoute` EXACTLY, so that
                -- `run` accepts/rejects the SAME set of programs `medaka check`
                -- does (beta P0-1 / P1-8).  The old gate was resolve-errors +
                -- elaborate + hadTypeErrors for ALL programs — a WEAKER predicate
                -- than check's: it missed constraint/no-impl/coherence errors
                -- (so run silently executed ill-typed programs) AND spuriously
                -- fired on some check-clean programs (standalone-fn-shadows-iface).
                match modsD
                  [_] =>
                    -- Single-file: gate on the SAME located analysis `check`
                    -- uses (analyzeLocatedG → checkImplObligations et al.) and
                    -- render byte-identical caret diagnostics via ppDiagCliSrc,
                    -- instead of the opaque "type error in <file>" message (P1-8).
                    let tsrc = readFileSafe target
                    let diags = analyzeLocatedG allowInternal rsrc csrc tsrc
                    let errs = filter isDiagError diags
                    match errs
                      [] =>
                        let _ = resetTypeErrorsSticky ()
                        let elaborated = elaborateModules rtD coreD modsD
                        finishRunEval target jsonMode elaborated mods
                      _ =>
                        let _ = ePutStrLn (joinNl (map (ppDiagCliSrc tsrc target) errs))
                        exit 1
                  _ =>
                    -- Multi-module: keep the resolve + elaborate + hadTypeErrors
                    -- predicate (matches `build`'s multi-module gate).  This is
                    -- looser than check's checkModulesHasErrors but SOUND, and
                    -- deliberately so: checkModulesHasErrors OVER-REJECTS valid
                    -- multi-module code (e.g. the compiler's own source with a
                    -- spurious `No impl of Alternative for Parser`), which run is
                    -- routinely used on.  See typecheckGateRoute's note.
                    let resDiags = resolveModulesToHumaneGF target allowInternal trusted rtD coreD modsD
                    match resDiags
                      "" =>
                        let _ = resetTypeErrorsSticky ()
                        let elaborated = elaborateModules rtD coreD modsD
                        match hadTypeErrors ()
                          True =>
                            -- Located per-module diagnostics (matching `--json`/
                            -- `check`/`build`) so `run`'s rejection points at the
                            -- offending file:L:C, imported modules included, rather
                            -- than the opaque entry-only deflection.  Gate stays the
                            -- sound hadTypeErrors (see the note above).
                            let _ = ePutStrLn (locatedOrGeneric target roots rsrc csrc)
                            exit 1
                          False => finishRunEval target jsonMode elaborated mods
                      _ =>
                        let _ = ePutStrLn resDiags
                        exit 1
-- G1 (SOUNDNESS): typecheck the WHOLE module graph and abort before
-- eval on ANY type error.  elaborateModules route-stamps via the
-- per-module typecheck (checkModuleFullImpl), which pushes into the
-- sticky error accumulator; resetTypeErrorsSticky clears it first so
-- hadTypeErrors reflects THIS run only.  A type error makes
-- evalModulesOutput miscompile (the G1 bug), so we never reach it.
-- Resolve-phase errors (e.g. PrivateNameAccess) ride a SEPARATE channel
-- hadTypeErrors does not cover, so resolveModulesToHumane is consulted
-- FIRST (mirroring `check`/`build`) and run aborts with the same humane
-- diagnostic before elaborate/eval.

desugarPair : (String, List Decl) -> (String, List Decl)
desugarPair (mid, p) = (mid, desugar p)

-- Drop the file-path component of a located-loader triple back to the
-- (modId, decls) pair shape loadProgram returns.
dropModPath : (String, String, List Decl) -> (String, List Decl)
dropModPath (mid, _, prog) = (mid, prog)

-- ASYNC-DESIGN Stage 2 (D5): route a `main : Async _` through the program's
-- `runAsync` (perform its stored row) instead of forcing it to an inert Async
-- value; a plain `main` keeps the ordinary force-for-effect path.  mainTypeIsAsync
-- reads the scheme elaborateModules just stashed, so this must run post-elaborate.
-- B2 (RUN-EFFECTS): the plain path is evalModulesOutputRun — evalModulesOutput
-- plus the real-I/O externs (File/Env/Stdin/Stderr/Clock), hence the `IO` row.
runProgramOutput : List Decl -> List (String, List Decl) -> <IO, Mut> String
runProgramOutput preludeDecls modules = match mainTypeIsAsync ()
  True => evalModulesOutputAsync preludeDecls modules
  False => evalModulesOutputRun preludeDecls modules

-- ── test ──────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `test` arm + test_main.mdk: read <MEDAKA_ROOT>/stdlib/
-- {runtime,core}.mdk, then drive test_cmd.runTest (doctests + prop tests).
-- runTest reads the three sources itself and prints the report in-band (it
-- handles its own read errors, so no exit on a bad target — matches the
-- interpreted driver, which also just ePutStrLn's a read error).  Roots mirror
-- run: the entry's dir (user modules shadow stdlib) then MEDAKA_ROOT/stdlib.
-- runTest now returns a Bool (True = every doctest+prop passed, or vacuously
-- no tests / read error); `exit 1` when False so CI can trust the exit code
-- instead of scraping the printed report (P0-6).
runTestCmd : List String -> <IO, Mut, Panic> Unit
runTestCmd argv = match dropFlags argv
  [] =>
    let _ = ePutStrLn "usage: medaka test [file.mdk]"
    exit 1
  target::_ =>
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let rtPath = root ++ "/stdlib/runtime.mdk"
    let corePath = root ++ "/stdlib/core.mdk"
    let stdlibDir = root ++ "/stdlib"
    let roots = entrySearchRoots (dirOf2 target) ++ [stdlibDir]
    let ok = runTest rtPath corePath target roots
    if ok then () else exit 1

-- ── doc ───────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `doc` arm + lib/doc.ml: read the target file, parse
-- (capturing decl positions + comments), typecheck a desugared copy through the
-- single-file path for inferred schemes, extract PUBLIC-decl doc entries, and
-- print Markdown to stdout.  Single-file only (OCaml `doc` is single-file too).
-- Prelude sources (runtime.mdk/core.mdk) come from MEDAKA_ROOT for scheme
-- inference, exactly as check/run/test do.
runDocCmd : List String -> <IO, Mut, Panic> Unit
runDocCmd argv = match dropFlags argv
  [] =>
    let _ = ePutStrLn "usage: medaka doc [file.mdk]"
    exit 1
  target::_ =>
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let rtPath = root ++ "/stdlib/runtime.mdk"
    let corePath = root ++ "/stdlib/core.mdk"
    match readFile rtPath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok rsrc => match readFile corePath
        Err msg =>
          let _ = ePutStrLn msg
          exit 1
        Ok csrc => match readFile target
          Err msg =>
            let _ = ePutStrLn msg
            exit 1
          Ok tsrc => putStr (runDoc rsrc csrc tsrc target)

-- ── check-policy ───────────────────────────────────────────────────────────
-- WS-1a of EFFECTS-CONFORMANCE-ROADMAP.md.  Mirrors bin/main.ml's `check-policy`
-- arm: parse `--allow L1,L2,… / --fn name / <file>`, type-check the plugin, read
-- the named fn's inferred effect row, and accept (+ run on a sample request) or
-- reject (+ print the call chain) per the policy.  Prelude sources come from
-- MEDAKA_ROOT, as check/run/doc do.  runCheckPolicy returns (report, accepted?);
-- we print the report and exit 0 (accept) / 1 (reject) — the OCaml arm exits the
-- same way.  Defaults (allow "Cache,Log", fn "transform") match the oracle.
runCheckPolicyCmd : List String -> <IO, Mut, Panic> Unit
runCheckPolicyCmd argv = match parsePolicyArgs argv
  PolicyArgs None _ _ =>
    let _ = ePutStrLn "usage: medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]"
    exit 1
  PolicyArgs (Some target) allow fn =>
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let rtPath = root ++ "/stdlib/runtime.mdk"
    let corePath = root ++ "/stdlib/core.mdk"
    match readFile rtPath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok rsrc => match readFile corePath
        Err msg =>
          let _ = ePutStrLn msg
          exit 1
        Ok csrc => match readFile target
          Err msg =>
            let _ = ePutStrLn msg
            exit 1
          Ok tsrc =>
            -- Print the accept/reject HEADER first (OCaml prints `✅ accepted`
            -- to stdout before running the plugin); on accept, then run the plugin
            -- (a panic on an unstubbed extern surfaces post-header, like OCaml).
            match runCheckPolicy rsrc csrc tsrc allow fn
              PolicyReject report =>
                let _ = putStr report
                exit 1
              PolicyAccept header pluginFn coreD rtD userD =>
                let _ = putStr header
                putStr (runAcceptedPlugin pluginFn coreD rtD userD)

-- ── manifest ─────────────────────────────────────────────────────────────────
-- WS-1c of EFFECTS-CONFORMANCE-ROADMAP.md.  Emit a module's verified capability
-- manifest as a TOML artifact.  Given a source file and an optional --fn name
-- (default "main"), typechecks the file, reads the named fn's inferred effect
-- row, filters to security labels (dropping Mut/Panic), and prints:
--
--   [package.capabilities]
--   Net = "idp.example.com/api"
--   Stdout = true
--
-- Security/internal rule: isSecurity l = not (l == "Mut" || l == "Panic").
-- Labels sorted ascending (stable output).  Prefix-param → string TOML value;
-- ⊤/Unit param → boolean `true`.
--
-- WS-1c (deferred): Wasm custom section embedding (see
-- compiler/tools/check_policy.mdk comment + EFFECTS-SEMANTICS.md §7).
runManifestCmd : List String -> <IO, Mut, Panic> Unit
runManifestCmd argv = match parseManifestArgs argv
  ManifestArgs None _ =>
    let _ = ePutStrLn "usage: medaka manifest <file.mdk> [--fn name]"
    exit 1
  ManifestArgs (Some target) fn =>
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let rtPath = root ++ "/stdlib/runtime.mdk"
    let corePath = root ++ "/stdlib/core.mdk"
    match readFile rtPath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok rsrc => match readFile corePath
        Err msg =>
          let _ = ePutStrLn msg
          exit 1
        Ok csrc => match readFile target
          Err msg =>
            let _ = ePutStrLn msg
            exit 1
          Ok tsrc => putStr (runManifest rsrc csrc tsrc fn)

-- ── lint ──────────────────────────────────────────────────────────────────
-- Parse target file(s) and run lint rules over the raw pre-desugar AST.
-- Flags:
--   --fix                rewrite fixable findings in-place
--   --disable=r1,r2,...  suppress findings from the named rules
--   --only=r1,...        keep only findings from the named rules
--   --deny=r1,...        promote findings from the named rules to SevError
-- Target resolution:
--   ≥1 explicit file args   → lint each in order
--   single directory arg    → lint all top-level .mdk files in that dir (sorted)
--   no file arg             → find medaka.toml project root, lint top-level .mdk files
--     (note: top-level only — subdirectory .mdk files are not walked recursively)
-- Exit 0 unless a SevError finding exists (only via --deny in v1 report mode).
runLintCmd : List String -> <IO, Mut, Panic> Unit
runLintCmd argv =
  let disableNames = parseLintFlagList "--disable=" argv
  let onlyNames = parseLintFlagList "--only=" argv
  let denyNames = parseLintFlagList "--deny=" argv
  let fixMode = hasFlag "--fix" argv
  let fileArgs = lintTargets argv
  let files = resolveLintTargets fileArgs
  let multiFile = match files
    (_::_::_) => True
    _ => False
  let perFileErr = lintFilesGo fixMode multiFile disableNames onlyNames denyNames files False
  -- Cross-file rules only run in the multi-file REPORT path; a single target or
  -- --fix produces nothing (need ≥2 files), keeping single-file output identical.
  let crossErr =
    if multiFile && not fixMode then runCrossFileReport disableNames onlyNames denyNames files
    else False
  if perFileErr || crossErr then exit 1 else ()

-- Parse every target file once, then run the cross-file rule tier over the whole
-- set.  Findings render AFTER the per-file output under a `cross-file:` header.
-- --only/--disable are honored inside `runCrossFileRules`; --deny promotion is
-- applied here (mirrors the per-file path).  Returns whether any finding is an
-- error severity (feeds the exit code).
runCrossFileReport : List String -> List String -> List String -> List String -> <IO, Mut, Panic> Bool
runCrossFileReport disableNames onlyNames denyNames files =
  let triples = parseLintFiles files
  let raw = runCrossFileRules onlyNames disableNames triples
  -- Honor inline `-- lint-disable-*` directives on cross-file findings too:
  -- each finding anchors to its own file, so filter against that file's own
  -- directives (recovered from its source) before the CLI flag filters.
  let suppressed = applySuppressionsMulti (readLintSrcs files) raw
  let findings = applyFindingDeny denyNames suppressed
  match findings
    [] => False
    _ =>
      let _ = putStrLn ""
      let _ = putStrLn "cross-file:"
      let _ = putStrLn (joinNl (map renderCrossFinding findings))
      anyList isFindingError findings

-- Render one cross-file finding.  The file path lives in the finding's loc; pass
-- it as the diagnostic's file (src="" → header-only, no carat, so output stays
-- deterministic across the whole file set).
renderCrossFinding : Finding -> String
renderCrossFinding f = ppDiagCliSrc "" (locFileOf f.loc) (findingToDiag f)

locFileOf : Option Loc -> String
locFileOf (Some (Loc file _ _ _ _)) = file
locFileOf None = ""

-- Read each readable target's source into `(path, src)` for inline-directive
-- recovery in the cross-file report path.  Unreadable files are skipped.
readLintSrcs : List String -> <IO, Mut, Panic> List (String, String)
readLintSrcs [] = []
readLintSrcs (f::rest) = match readFile f
  Err _ => readLintSrcs rest
  Ok src => (f, src) :: readLintSrcs rest

-- Parse each readable target into (path, Positions, decls) for the cross-file
-- tier.  Unreadable files are skipped (already reported by the per-file pass).
parseLintFiles : List String -> <IO, Mut, Panic> List (String, Positions, List Decl)
parseLintFiles [] = []
parseLintFiles (f::rest) = match readFile f
  Err _ => parseLintFiles rest
  Ok src =>
    let (decls, pos) = parseWithPositions src
    (f, pos, decls) :: parseLintFiles rest

-- Resolve file args to a concrete list of .mdk paths.
-- Empty args → project root mode (find medaka.toml, list top-level .mdk files).
-- Each non-empty arg is expanded individually: a path listDir succeeds on is
-- treated as a directory (recursively collected); else it's kept as a literal
-- file path. This applies uniformly whether one or many targets are given, so
-- `medaka lint dirA dirB` expands BOTH dirs (not just the first).
resolveLintTargets : List String -> <IO, Mut, Panic> List String
resolveLintTargets [] =
  let cwd = canonicalizePath "."
  let root = findProjectRoot cwd
  if not (fileExists (root ++ "/medaka.toml")) then
    let _ = ePutStrLn "medaka lint: no medaka.toml found; run from a project directory or pass file/dir paths"
    let _ = exit 1
    []
  else collectMdkFiles root
resolveLintTargets targets = flatMap expandLintTarget targets

-- One target: a listable path is a directory (recursively collect its .mdk
-- files); otherwise a literal file path, kept as-is.
expandLintTarget : String -> <IO, Mut, Panic> List String
expandLintTarget target = match listDir target
  Ok _ => collectMdkFiles target
  Err _ => [target]

-- Join a directory path with an entry name (handles trailing slash).
lintPathJoin : String -> String -> String
lintPathJoin dir name =
  if endsWith "/" dir then
    dir ++ name
  else
    "\{dir}/\{name}"

-- Recursively collect every `.mdk` file under `dir`, sorted (deterministic).
-- Walks SUBDIRECTORIES; skips dot-entries (dotfiles AND dot-directories like
-- `.git`/`.claude`).  A failed top-level `listDir` reports once and yields [].
collectMdkFiles : String -> <IO, Mut, Panic> List String
collectMdkFiles dir = match listDir dir
  Err msg =>
    let _ = ePutStrLn "medaka lint: cannot list directory \{dir}: \{msg}"
    []
  Ok _ => sortUniqS (collectMdkFilesRec dir)

collectMdkFilesRec : String -> <IO, Mut, Panic> List String
collectMdkFilesRec dir = match listDir dir
  Err _ => []
  Ok entries => collectMdkEntries dir (filterNonDot entries)

collectMdkEntries : String -> List String -> <IO, Mut, Panic> List String
collectMdkEntries _ [] = []
collectMdkEntries dir (name::rest) = collectMdkEntry dir name
  ++ collectMdkEntries dir rest

-- One entry: a listable path is a subdirectory (recurse); otherwise a file,
-- kept iff it ends in `.mdk`.  Mirrors the dir/file discriminator used elsewhere
-- (listDir Ok = dir, Err = file).
collectMdkEntry : String -> String -> <IO, Mut, Panic> List String
collectMdkEntry dir name =
  let full = lintPathJoin dir name
  match listDir full
    Ok _ => collectMdkFilesRec full
    Err _ => if endsWith ".mdk" name then [full] else []

-- Drop dot-entries (dotfiles and dot-directories) from a listDir result.
filterNonDot : List String -> List String
filterNonDot [] = []
filterNonDot (n::rest)
  | startsWith "." n = filterNonDot rest
  | otherwise = n :: filterNonDot rest

-- Fold over file list, running lint on each.  acc = whether any SevError seen.
lintFilesGo : Bool -> Bool -> List String -> List String -> List String -> List String -> Bool -> <IO, Mut, Panic> Bool
lintFilesGo _ _ _ _ _ [] acc = acc
lintFilesGo fixMode multiFile disableNames onlyNames denyNames (f::rest) acc =
  let hadErr = if fixMode then
    lintOneFileFix onlyNames disableNames f
  else
    lintOneFileReport multiFile disableNames onlyNames denyNames f
  lintFilesGo
    fixMode
    multiFile
    disableNames
    onlyNames
    denyNames
    rest
    (acc || hadErr)

-- Lint a single file in report mode.
-- multiFile=False: output is byte-for-byte identical to single-file v1 behavior.
-- multiFile=True: prints "path:" header before findings (only when there are findings).
lintOneFileReport : Bool -> List String -> List String -> List String -> String -> <IO, Mut, Panic> Bool
lintOneFileReport multiFile disableNames onlyNames denyNames target = match readFile target
  Err msg =>
    let _ = ePutStrLn msg
    True
  Ok src =>
    let (decls, pos) = parseWithPositions src
    -- suppress findings silenced by inline `-- lint-disable-*` directives before
    -- applying the CLI flag filters (--only/--disable/--deny).
    let allFindings = applySuppressions src (lintProgram allRules target src pos decls)
    let findings = applyFindingFilters disableNames onlyNames denyNames allFindings
    let output = joinNl (map (f => ppDiagCliSrc src target (findingToDiag f)) findings)
    let hasOutput = stringLength output > 0
    let _ = if multiFile && hasOutput then putStrLn (target ++ ":") else ()
    let _ = if hasOutput then putStrLn output else ()
    anyList isFindingError findings

-- Fix a single file in-place.  Returns True only on I/O error (write errors exit 2).
lintOneFileFix : List String -> List String -> String -> <IO, Mut, Panic> Bool
lintOneFileFix onlyNames disableNames target = match readFile target
  Err msg =>
    let _ = ePutStrLn msg
    True
  Ok src =>
    let (decls, pos) = parseWithPositions src
    let (newSrc, n) = applyFixes onlyNames disableNames src decls pos
    if newSrc == src then
      let _ = putStrLn ("fixed 0 finding(s) in " ++ target)
      False
    else match writeFile target newSrc
      Err msg =>
        let _ = ePutStrLn "\{target}: \{msg}"
        let _ = exit 2
        True
      Ok _ =>
        let _ = putStrLn "fixed \{intToString n} finding(s) in \{target}"
        False

-- All non-flag args in order (flags all start with --).
lintTargets : List String -> List String
lintTargets [] = []
lintTargets (x::rest)
  | startsWith "--" x = lintTargets rest
  | otherwise = x :: lintTargets rest

-- ── snapshot ──────────────────────────────────────────────────────────────
-- `medaka snapshot [--check | --new] [--out <dir>] [--isolate] <paths...>`
--
-- Directory targets are expanded by the SAME `expandLintTarget`/`collectMdkFiles`
-- pair `medaka lint` and `medaka fmt` already use — dir-vs-file discrimination,
-- dotfile skipping and recursion all live in one place.
--
-- `--worker` is INTERNAL: the supervisor re-spawns this same binary with it (that is
-- the whole crash-resume mechanism, see tools/snapshot.mdk).  `--isolate` forces one
-- process per fixture and is a DEBUG aid only — the steady-state answer to a known
-- crasher is `isolate=true` in its `# META`.
--
-- R0 has NO `--bless` on purpose: `--new` creates a missing snapshot and refuses to
-- touch an existing one, so no regression can be silently re-blessed.
-- A snapshot target that does not exist is a HARNESS error, not a fixture outcome.
--
-- Without this guard, an unreadable path was RENDERED as a snapshot whose entire
-- body was `# CRASH: cannot read fixture` — and `--check` then compared that section
-- against itself, matched, and reported PASS. Forever. So a typo'd path, or a
-- DELETED fixture, silently became a permanently-passing snapshot that tested
-- nothing.
--
-- That is exactly the silent-green bug class this whole harness was built to
-- REPLACE (see TESTING-DESIGN.md §2.3: a missing oracle used to exit 2 = SKIP, and
-- a fresh clone ran zero tests and printed "0 failed"). Never let "I could not read
-- it" become an expected output. Fail loudly, up front.
assertSnapshotTargetsExist : List String -> <IO, Mut, Panic> Unit
assertSnapshotTargetsExist files =
  let missing = filter (f => not (fileExists f)) files
  if missing == [] then ()
  else
    let _ = ePutStrLn "medaka snapshot: these targets do not exist:"
    let _ = ePutStrLn (joinNl (map (m => "  \{m}") missing))
    exit 1

runSnapshotCmd : List String -> <IO, Mut, Panic> Unit
runSnapshotCmd argv =
  let root = match snapFlagValue "--root" argv
    Some r => r
    None => envOr "MEDAKA_ROOT" defaultMedakaRoot
  let sel = snapshotStages argv
  let files = flatMap expandLintTarget (snapshotTargets argv)
  let _ = assertSnapshotTargetsExist files
  if files == [] then
    let _ = ePutStrLn "usage: medaka snapshot [--check|--new] [--out <dir>] [--stages <a,b,…>] <paths...>"
    exit 1
  else
    if hasFlag "--worker" argv then runSnapshotWorker root sel files
    else
      let check = hasFlag "--check" argv
      if not check && not (hasFlag "--new" argv) then
        let _ = ePutStrLn "medaka snapshot: pass --check (verify) or --new (create missing snapshots)"
        exit 1
      else
        let ok = runSnapshotSupervisor root check (hasFlag "--isolate" argv) (snapFlagValue "--out" argv) sel files
        if ok then () else exit 1

-- `--stages parse,desugar,mark` restricts which sections a fixture renders (see
-- tools/snapshot.mdk).  Absent == every stage.  A typo'd stage name EXITS rather than
-- being dropped: silently rendering fewer sections than asked for would report a clean
-- pass over a stage that never ran.
snapshotStages : List String -> <IO, Panic> List String
snapshotStages argv = match snapFlagValue "--stages" argv
  None => []
  Some spec => match parseStages spec
    Ok names => names
    Err msg =>
      let _ = ePutStrLn "medaka snapshot: \{msg}"
      let _ = exit 1
      []

-- Non-flag args, minus the VALUE of the value-taking flags (--out/--root/--stages).
snapshotTargets : List String -> List String
snapshotTargets [] = []
snapshotTargets ("--out"::_::rest) = snapshotTargets rest
snapshotTargets ("--root"::_::rest) = snapshotTargets rest
snapshotTargets ("--stages"::_::rest) = snapshotTargets rest
snapshotTargets (x::rest)
  | startsWith "--" x = snapshotTargets rest
  | otherwise = x :: snapshotTargets rest

-- `--flag value` (space-separated, unlike lint's `--flag=v1,v2`).
snapFlagValue : String -> List String -> Option String
snapFlagValue _ [] = None
snapFlagValue _ [_] = None
snapFlagValue name (a::v::rest) =
  if a == name then
    Some v
  else
    snapFlagValue name (v::rest)

-- Parse --prefix=v1,v2,... from argv; returns [] if not present.
parseLintFlagList : String -> List String -> List String
parseLintFlagList prefix [] = []
parseLintFlagList prefix (x::rest)
  | startsWith prefix x =
    splitLintNames (stringSlice (stringLength prefix) (stringLength x) x)
  | otherwise = parseLintFlagList prefix rest

-- Split a comma-separated string.  Uses literal ',' to avoid Char-param issues.
splitLintNames : String -> List String
splitLintNames s = splitLintNamesGo (stringToChars s) s 0 0 (stringLength s)

splitLintNamesGo : Array Char -> String -> Int -> Int -> Int -> List String
splitLintNamesGo chars s start i n
  | i >= n = [stringSlice start n s]
  | arrayGetUnsafe i chars == ',' =
    stringSlice start i s :: splitLintNamesGo chars s (i + 1) (i + 1) n
  | otherwise = splitLintNamesGo chars s start (i + 1) n

-- Apply finding-level filters.  Operates on Finding.rule (a String) so no
-- Rule-record field access is needed in medaka_cli.mdk.
applyFindingFilters : List String -> List String -> List String -> List Finding -> List Finding
applyFindingFilters disable only deny findings =
  let after1 = applyFindingOnly only findings
  let after2 = applyFindingDisable disable after1
  applyFindingDeny deny after2

-- --only: keep findings whose rule is in the list (no-op when empty).
applyFindingOnly : List String -> List Finding -> List Finding
applyFindingOnly [] findings = findings
applyFindingOnly names findings = lintFindingOnlyGo names findings

lintFindingOnlyGo : List String -> List Finding -> List Finding
lintFindingOnlyGo _ [] = []
lintFindingOnlyGo names (f::rest)
  | contains f.rule names = f :: lintFindingOnlyGo names rest
  | otherwise = lintFindingOnlyGo names rest

-- --disable: remove findings whose rule is in the list (no-op when empty).
applyFindingDisable : List String -> List Finding -> List Finding
applyFindingDisable [] findings = findings
applyFindingDisable names findings = lintFindingDisableGo names findings

lintFindingDisableGo : List String -> List Finding -> List Finding
lintFindingDisableGo _ [] = []
lintFindingDisableGo names (f::rest)
  | contains f.rule names = lintFindingDisableGo names rest
  | otherwise = f :: lintFindingDisableGo names rest

-- --deny: promote findings to SevError when their rule is in the list.
applyFindingDeny : List String -> List Finding -> List Finding
applyFindingDeny [] findings = findings
applyFindingDeny names findings = lintFindingDenyGo names findings

lintFindingDenyGo : List String -> List Finding -> List Finding
lintFindingDenyGo _ [] = []
lintFindingDenyGo names (f::rest)
  | contains f.rule names = Finding {
    rule = f.rule,
    message = f.message,
    severity = SevError,
    loc = f.loc,
  } :: lintFindingDenyGo names rest
  | otherwise = f :: lintFindingDenyGo names rest

isFindingError : Finding -> Bool
isFindingError f = match f.severity
  SevError => True
  SevWarning => False

-- dirname on a POSIX path (mirrors build_cmd.dirOf, kept local to avoid an extra
-- import of a non-exported helper).
dirOf2 : String -> String
dirOf2 path = dirGo2 path (stringLength path)

dirGo2 : String -> Int -> String
dirGo2 path 0 = "."
dirGo2 path i =
  if stringSlice (i - 1) i path == "/" then
    stringSlice 0 (i - 1) path
  else
    dirGo2 path (i - 1)

-- ── repl ──────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `repl` arm (Repl.run) + repl_main.mdk: read
-- MEDAKA_ROOT/stdlib/{runtime,core}.mdk, init the session, then run the
-- interactive REPL loop.  Any extra args are silently ignored (consistent with
-- the OCaml driver, which also ignores extra args after "repl").
runReplCmd : List String -> <IO, Mut, Panic> Unit
runReplCmd _ =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let rtPath = root ++ "/stdlib/runtime.mdk"
  let corePath = root ++ "/stdlib/core.mdk"
  match readFile rtPath
    Err msg =>
      let _ = ePutStrLn msg
      exit 1
    Ok rsrc => match readFile corePath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok csrc =>
        let runtimeDecls = desugar (parse rsrc)
        let preludeDecls = desugar (parse csrc)
        let _ = initSession runtimeDecls preludeDecls
        replLoop ()

-- ── lsp ───────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `lsp` arm (Lsp_server.run) + lsp_main.mdk: read
-- MEDAKA_ROOT/stdlib/{runtime,core}.mdk, then run the JSON-RPC-over-stdio
-- loop (initialize handshake + publishDiagnostics on didOpen/didChange).
runLspCmd : List String -> <IO, Mut, Panic> Unit
runLspCmd _ =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let rtPath = root ++ "/stdlib/runtime.mdk"
  let corePath = root ++ "/stdlib/core.mdk"
  match readFile rtPath
    Err msg =>
      let _ = ePutStrLn msg
      exit 1
    Ok rsrc => match readFile corePath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok csrc => runServer rsrc csrc
# DESUGAR
(DUse false (UseGroup ("tools" "check") ((mem "runCheck" false) (mem "checkHasErrors" false) (mem "runCheckModules" false))))
(DUse false (UseGroup ("tools" "snapshot") ((mem "runSnapshotWorker" false) (mem "runSnapshotSupervisor" false) (mem "parseStages" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSource" false))))
(DUse false (UseGroup ("tools" "new_cmd") ((mem "newProject" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "BuildResult" false) (mem "BuildOk" false) (mem "BuildErr" false) (mem "BuildTarget" false) (mem "TNative" false) (mem "TWasm" false) (mem "runBuild" false) (mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinNl" false) (mem "splitNl" false) (mem "startsWith" false) (mem "endsWith" false) (mem "anyList" false) (mem "contains" false) (mem "sortUniqS" false) (mem "schemeLineName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("support" "path") ((mem "baseOf" false) (mem "chopExt" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" false) (mem "LetBind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseWithPositions" false) (mem "parseResult" false) (mem "ParseError" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false) (mem "Positions" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "resolveModulesToHumane" false) (mem "resolveModulesToHumaneG" false) (mem "resolveModulesToHumaneGF" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "loadProgram" false) (mem "loadProgramFilesLocated" false) (mem "findProjectRoot" false) (mem "entrySearchRoots" false) (mem "stdlibTrustedMods" false) (mem "unknownModuleIdOf" false) (mem "findImportLoc" false) (mem "availableModulesHint" false) (mem "availableModulesText" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeProject" false) (mem "analyzeLocated" false) (mem "analyzeLocatedG" false) (mem "ppDiagCli" false) (mem "ppDiagCliSrc" false) (mem "Diag" true) (mem "Severity" true) (mem "SevError" false) (mem "cjPosition" false) (mem "cjRange" false) (mem "cjRangeOfLoc" false) (mem "cjDiagnostic" false) (mem "cjFileEntry" false) (mem "cjAllToJson" false) (mem "readDiagSrc" false) (mem "parseErrCode" false) (mem "parseErrHelpFix" false) (mem "codeKind" false) (mem "optField" false) (mem "cjFixJson" false) (mem "mkDiag" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JInt" false) (mem "JString" false) (mem "JArray" false) (mem "JObject" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "elaborateModules" false) (mem "resetTypeErrorsSticky" false) (mem "hadTypeErrors" false) (mem "mainTypeIsAsync" false) (mem "mainTypeIsUnit" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "evalModulesOutputRun" false) (mem "evalModulesOutputAsync" false) (mem "currentEvalFile" false) (mem "runJsonMode" false) (mem "progArgsRef" false))))
(DUse false (UseGroup ("tools" "test_cmd") ((mem "runTest" false))))
(DUse false (UseGroup ("tools" "repl") ((mem "initSession" false) (mem "replLoop" false))))
(DUse false (UseGroup ("tools" "lsp") ((mem "runServer" false))))
(DUse false (UseGroup ("tools" "doc") ((mem "runDoc" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "allRules" false) (mem "lintProgram" false) (mem "applySuppressions" false) (mem "applySuppressionsMulti" false) (mem "findingToDiag" false) (mem "Finding" false) (mem "applyFixes" false) (mem "runCrossFileRules" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "runCheckPolicy" false) (mem "runAcceptedPlugin" false) (mem "PolicyArgs" true) (mem "parsePolicyArgs" false) (mem "PolicyOutcome" true) (mem "runManifest" false) (mem "parseManifestArgs" false) (mem "ManifestArgs" true))))
(DTypeSig false "medakaVersion" (TyCon "String"))
(DFunDef false "medakaVersion" () (ELit (LString "0.1.0-preview")))
(DTypeSig false "printVersion" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printVersion" (PWild) (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "medaka ")) (EVar "medakaVersion"))))
(DTypeSig false "main" (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit")))
(DFunDef false "main" () (EMatch (EApp (EVar "args") (ELit LUnit)) (arm (PList) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "-h")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "-v")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "check")) (PVar "rest")) () (EApp (EVar "runCheckCmd") (EVar "rest"))) (arm (PCons (PLit (LString "fmt")) (PVar "rest")) () (EApp (EVar "runFmtCmd") (EVar "rest"))) (arm (PCons (PLit (LString "new")) (PVar "rest")) () (EApp (EVar "runNewCmd") (EVar "rest"))) (arm (PCons (PLit (LString "build")) (PVar "rest")) () (EApp (EVar "runBuildCmd") (EVar "rest"))) (arm (PCons (PLit (LString "run")) (PVar "rest")) () (EApp (EVar "runRunCmd") (EVar "rest"))) (arm (PCons (PLit (LString "test")) (PVar "rest")) () (EApp (EVar "runTestCmd") (EVar "rest"))) (arm (PCons (PLit (LString "snapshot")) (PVar "rest")) () (EApp (EVar "runSnapshotCmd") (EVar "rest"))) (arm (PCons (PLit (LString "doc")) (PVar "rest")) () (EApp (EVar "runDocCmd") (EVar "rest"))) (arm (PCons (PLit (LString "lint")) (PVar "rest")) () (EApp (EVar "runLintCmd") (EVar "rest"))) (arm (PCons (PLit (LString "check-policy")) (PVar "rest")) () (EApp (EVar "runCheckPolicyCmd") (EVar "rest"))) (arm (PCons (PLit (LString "manifest")) (PVar "rest")) () (EApp (EVar "runManifestCmd") (EVar "rest"))) (arm (PCons (PLit (LString "repl")) (PVar "rest")) () (EApp (EVar "runReplCmd") (EVar "rest"))) (arm (PCons (PLit (LString "lsp")) (PVar "rest")) () (EApp (EVar "runLspCmd") (EVar "rest"))) (arm (PCons (PVar "sub") PWild) () (EApp (EVar "notYet") (EVar "sub")))))
(DTypeSig false "usage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "usage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka. A functional language compiler\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka                    Show this message\n")) (ELit (LString "  medaka run [--release] <file.mdk>   Type-check and run a program\n")) (ELit (LString "  medaka build <file.mdk> [-o <out>]  Compile to a native binary (LLVM + clang)\n")) (ELit (LString "  medaka check [--json] <file.mdk>    Type-check without running\n")) (ELit (LString "  medaka test [file.mdk]    Run doctests + prop tests\n")) (ELit (LString "  medaka bench [file.mdk]   Run bench declarations\n")) (ELit (LString "  medaka doc [file.mdk]     Generate Markdown documentation\n")) (ELit (LString "  medaka lint [paths...]    Lint files/dirs (style rules; --fix, --disable/--only/--deny=<rules,...>)\n")) (ELit (LString "  medaka snapshot [--check|--new] [paths...]  Per-stage snapshot tests (--out <dir>, --stages <a,b,..>)\n")) (ELit (LString "  medaka fmt [paths...]     Format .mdk files in place (or --check)\n")) (ELit (LString "  medaka new <name>         Scaffold a new project directory\n")) (ELit (LString "  medaka lsp                Run the language server over stdio\n")) (ELit (LString "  medaka help               Show this message\n")) (ELit (LString "  medaka --version          Show the compiler version\n"))))))
(DTypeSig false "notYet" (TyFun (TyCon "String") (TyEffect ("IO" "Panic") None (TyCon "Unit"))))
(DFunDef false "notYet" ((PVar "sub")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka: subcommand '")) (EVar "sub")) (ELit (LString "' not yet in native CLI"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "ppParseError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "ppParseError" ((PVar "src") (PVar "file") (PVar "e")) (EBlock (DoLet false false (PVar "ploc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EApp (EVar "parseErrorCol") (EVar "e"))) (EApp (EVar "parseErrorLine") (EVar "e"))) (EBinOp "+" (EApp (EVar "parseErrorCol") (EVar "e")) (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "h") (PVar "fx")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "file")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (EApp (EVar "parseErrorMessage") (EVar "e"))) (EApp (EVar "Some") (EVar "ploc"))) (EVar "h")) (EVar "fx"))))))
(DTypeSig false "runCheckCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runCheckCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false (PVar "typesMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--types"))) (EVar "argv"))) (DoLet false false (PVar "argv2") (EApp (EVar "dropFlags") (EVar "argv"))) (DoExpr (EMatch (EVar "argv2") (arm (PList (PVar "target")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EIf (EVar "jsonMode") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runCheckJsonCmd") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "map") (EApp (EVar "map") (EVar "dropModPath"))) (EApp (EApp (EApp (EVar "loadProgramFilesLocated") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots"))) (arm (PCon "Err" (PVar "lmsg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "target")) (EVar "stdlibDir")) (EVar "lmsg")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "stdlibTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkRoute") (EVar "typesMode")) (EVar "allowInternal")) (EVar "trusted")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EVar "mods")))))))))))))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check [--json] [--types] [--allow-internal] <file.mdk>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DTypeSig false "moduleLoadErrText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Mut") None (TyCon "String")))))))
(DFunDef false "moduleLoadErrText" ((PVar "tsrc") (PVar "target") (PVar "stdlibDir") (PVar "lmsg")) (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "lmsg")) (arm (PCon "Some" (PVar "mid")) () (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EVar "lmsg") (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "tsrc"))) (arm (PCon "None") () (EVar "msg")) (arm (PCon "Some" (PVar "loc")) () (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "msg")) (EApp (EVar "Some") (EVar "loc"))) (EVar "None")) (EVar "None"))))))))))
(DTypeSig false "locatedProjectErrors" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Mut") None (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "locatedProjectErrors" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EBlock (DoLet false false (PVar "cacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "cacheRef")) (EVar "parseCacheRef")) (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc"))) (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (EVar "readDiagSrc")) (EVar "results"))) (DoLet false false (PVar "rendered") (EApp (EApp (EVar "flatMap") (EVar "renderTripleErrors")) (EVar "triples"))) (DoExpr (EMatch (EVar "rendered") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "rendered"))))))))
(DTypeSig false "renderTripleErrors" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderTripleErrors" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "path"))) (EApp (EApp (EVar "filter") (EVar "isDiagError")) (EVar "diags"))))
(DTypeSig false "locatedOrGeneric" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Mut") None (TyCon "String")))))))
(DFunDef false "locatedOrGeneric" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EMatch (EApp (EApp (EApp (EApp (EVar "locatedProjectErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "error: type error in ")) (EVar "target")) (ELit (LString ". Run `medaka check` for details"))))))
(DTypeSig false "checkRoute" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))))))))))
(DFunDef false "checkRoute" ((PVar "typesMode") (PVar "allowInternal") (PVar "trusted") PWild (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PList (PTuple (PVar "mid") (PVar "decls")))) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EVar "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false (PVar "warns") (EApp (EApp (EVar "filter") (EVar "isDiagWarn")) (EVar "diags"))) (DoLet false false (PVar "dump") (EApp (EVar "stripWarningLines") (EApp (EApp (EApp (EVar "runCheck") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")))) (DoLet false false (PVar "report") (EIf (EVar "typesMode") (EVar "dump") (EApp (EApp (EVar "userSchemeLines") (EVar "decls")) (EVar "dump")))) (DoLet false false PWild (EApp (EVar "putStr") (EVar "report"))) (DoLet false false (PVar "mainWarns") (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (EListLit (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "decls"))))) (EVar "decls"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EBinOp "++" (EVar "warns") (EVar "mainWarns")))) (DoExpr (ELit LUnit)))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target"))) (EVar "errs"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DFunDef false "checkRoute" ((PVar "typesMode") (PVar "allowInternal") (PVar "trusted") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "mods")) (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneGF") (EVar "target")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EMatch (EApp (EApp (EApp (EApp (EVar "locatedProjectErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PCon "Some" (PVar "errText")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "errText"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EApp (EVar "runCheckModules") (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD")))) (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple (PVar "emid") (PVar "edecls"))) () (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EVar "rtD")) (EVar "coreD")) (EVar "modsD")) (EVar "edecls"))) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EVar "mainWarns"))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "resDiags"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DTypeSig false "findMainFunDef" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "findMainFunDef" ((PList)) (EVar "None"))
(DFunDef false "findMainFunDef" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "findMainFunDef") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "findMainFunDef" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PVar "ps") (PVar "body")) PWild)) (EApp (EVar "Some") (ETuple (EVar "ps") (EVar "body"))))
(DFunDef false "findMainFunDef" ((PCons PWild (PVar "rest"))) (EApp (EVar "findMainFunDef") (EVar "rest")))
(DTypeSig false "mainBodyLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "mainBodyLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "mainBodyLoc" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "mainBodyLoc") (EVar "f")))
(DFunDef false "mainBodyLoc" (PWild) (EVar "None"))
(DTypeSig false "mainArityMsg" (TyCon "String"))
(DFunDef false "mainArityMsg" () (ELit (LString "'main' must be a value of type Unit. Write 'main = …', not 'main () = …' or 'main x = …' ('medaka run' never applies main; it forces a zero-arg main for its effects)")))
(DTypeSig false "mainNonUnitMsg" (TyCon "String"))
(DFunDef false "mainNonUnitMsg" () (ELit (LString "'main' must be a value of type Unit (e.g. an IO action). 'medaka run' only forces main for its side effects and prints nothing for a plain value; wrap the intended effect, e.g. 'main = println \"hi\"'")))
(DTypeSig false "mainArityWarning" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Diag"))))
(DFunDef false "mainArityWarning" ((PVar "decls")) (EMatch (EApp (EVar "findMainFunDef") (EVar "decls")) (arm (PCon "Some" (PTuple (PCons PWild PWild) (PVar "body"))) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevWarning")) (ELit (LString "W-MAIN-SHAPE"))) (EVar "mainArityMsg")) (EApp (EVar "mainBodyLoc") (EVar "body"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "mainNonUnitWarning" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("Mut") None (TyApp (TyCon "Option") (TyCon "Diag")))))
(DFunDef false "mainNonUnitWarning" ((PVar "decls")) (EMatch (EApp (EVar "findMainFunDef") (EVar "decls")) (arm (PCon "Some" (PTuple (PList) (PVar "body"))) () (EIf (EBinOp "||" (EApp (EVar "mainTypeIsUnit") (ELit LUnit)) (EApp (EVar "mainTypeIsAsync") (ELit LUnit))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevWarning")) (ELit (LString "W-MAIN-SHAPE"))) (EVar "mainNonUnitMsg")) (EApp (EVar "mainBodyLoc") (EVar "body")))))) (arm PWild () (EVar "None"))))
(DTypeSig false "mainShapeWarnings" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("Mut") None (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "mainShapeWarnings" ((PVar "rtD") (PVar "coreD") (PVar "modsDFull") (PVar "entryDecls")) (EMatch (EApp (EVar "mainArityWarning") (EVar "entryDecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsDFull"))) (DoExpr (EMatch (EApp (EVar "mainNonUnitWarning") (EVar "entryDecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit))))))))
(DTypeSig false "lastModPair" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lastModPair" ((PList)) (EVar "None"))
(DFunDef false "lastModPair" ((PList (PVar "p"))) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "lastModPair" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModPair") (EVar "rest")))
(DTypeSig false "dropFlags" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropFlags" ((PList)) (EListLit))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--json")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--release")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--allow-internal")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--types")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "dropFlags") (EVar "rest"))))
(DTypeSig false "hasFlag" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "hasFlag" (PWild (PList)) (EVar "False"))
(DFunDef false "hasFlag" ((PVar "flag") (PCons (PVar "x") (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EVar "flag")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "hasFlag") (EVar "flag")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runCheckJsonCmd" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit")))))))))
(DFunDef false "runCheckJsonCmd" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "roots") (PVar "stdlibDir")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "target"))) (DoExpr (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "ln") (EBinOp "-" (EApp (EVar "parseErrorLine") (EVar "e")) (ELit (LInt 1)))) (DoLet false false (PVar "col") (EApp (EVar "parseErrorCol") (EVar "e"))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EApp (EVar "cjRange") (EVar "ln")) (EVar "col")) (EVar "ln")) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (DoLet false false (PVar "pcode") (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (DoLet false false (PVar "ploc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "target")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EVar "col")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "phelp") (PVar "pfix")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoLet false false (PVar "diagJson") (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JString") (EVar "pcode")))) (EApp (EApp (EVar "optField") (ELit (LString "fix"))) (EApp (EApp (EVar "map") (EVar "cjFixJson")) (EVar "pfix")))) (EApp (EApp (EVar "optField") (ELit (LString "help"))) (EApp (EApp (EVar "map") (EVar "JString")) (EVar "phelp")))) (EListLit (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EApp (EVar "codeKind") (EVar "pcode")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EApp (EVar "parseErrorMessage") (EVar "e")))) (ETuple (ELit (LString "range")) (EVar "r")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka")))))))) (DoLet false false (PVar "filesJson") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "target"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EListLit (EVar "diagJson")))))))) (DoLet false false PWild (EApp (EVar "println") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "files")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EListLit (EVar "filesJson")))))))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "lmsg")) () (EBlock (DoLet false false (PVar "mloc") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "mid")) () (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "src")))))) (DoLet false false (PVar "mhelp") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" PWild) () (EMatch (EApp (EVar "availableModulesText") (EVar "stdlibDir")) (arm (PLit (LString "")) () (EVar "None")) (arm (PVar "txt") () (EApp (EVar "Some") (EVar "txt"))))))) (DoLet false false (PVar "jmsg") (EBinOp "++" (EVar "lmsg") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" PWild) () (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))))) (DoLet false false (PVar "triples") (EListLit (ETuple (EVar "target") (EVar "src") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "jmsg")) (EVar "mloc")) (EVar "mhelp")) (EVar "None")))))) (DoLet false false PWild (EApp (EVar "println") (EApp (EVar "cjAllToJson") (EVar "triples")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "mods")) () (EMatch (EVar "mods") (arm (PList (PTuple (PVar "mid") PWild)) () (EBlock (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "stdlibTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "src"))) (DoLet false false PWild (EApp (EVar "println") (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "target") (EVar "src") (EVar "diags")))))) (DoLet false false (PVar "hasErr") (EApp (EApp (EVar "any") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EIf (EVar "hasErr") (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit))))) (arm PWild () (EBlock (DoLet false false (PVar "cacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "cacheRef")) (EVar "parseCacheRef")) (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc"))) (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (EVar "readDiagSrc")) (EVar "results"))) (DoLet false false PWild (EApp (EVar "println") (EApp (EVar "cjAllToJson") (EVar "triples")))) (DoLet false false (PVar "hasErr") (EApp (EApp (EVar "any") (EVar "cjHasErr")) (EVar "results"))) (DoExpr (EIf (EVar "hasErr") (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))))))))
(DTypeSig false "readFileSafe" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "readFileSafe" ((PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Ok" (PVar "src")) () (EVar "src")) (arm (PCon "Err" PWild) () (ELit (LString "")))))
(DTypeSig false "cjHasErr" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "cjHasErr" ((PTuple PWild (PVar "diags"))) (EApp (EApp (EVar "any") (EVar "isDiagError")) (EVar "diags")))
(DTypeSig false "isDiagError" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isDiagError" ((PCon "Diag" (PCon "SevError") PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isDiagError" (PWild) (EVar "False"))
(DTypeSig false "isDiagWarn" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isDiagWarn" ((PVar "d")) (EApp (EVar "not") (EApp (EVar "isDiagError") (EVar "d"))))
(DTypeSig false "stripWarningLines" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripWarningLines" ((PVar "s")) (EApp (EVar "joinNl") (EApp (EApp (EVar "filter") (ELam ((PVar "l")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "Warning: "))) (EVar "l"))))) (EApp (EVar "splitNl") (EVar "s")))))
(DTypeSig false "userSchemeLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "userSchemeLines" ((PVar "decls") (PVar "report")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "omFromNames") (EApp (EVar "topLevelNames") (EVar "decls"))) (EVar "omEmpty"))) (DoExpr (EApp (EVar "joinNl") (EApp (EApp (EVar "filter") (EApp (EVar "namesUserBinding") (EVar "names"))) (EApp (EVar "splitNl") (EVar "report")))))))
(DTypeSig false "namesUserBinding" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "namesUserBinding" ((PVar "names") (PVar "l")) (EMatch (EApp (EVar "schemeLineName") (EVar "l")) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "topLevelNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topLevelNames" ((PList)) (EListLit))
(DFunDef false "topLevelNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "topLevelNames") (EListLit (EVar "d"))) (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")) (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "topLevelNames") (EVar "rest")))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "emitLocatedWarnings" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitLocatedWarnings" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "emitLocatedWarnings" ((PVar "src") (PVar "file") (PVar "ws")) (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "file"))) (EVar "ws")))))
(DData Private "FmtMode" () ((variant "FmtWrite" (ConPos)) (variant "FmtStdout" (ConPos)) (variant "FmtCheck" (ConPos))) ())
(DTypeSig false "runFmtCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runFmtCmd" ((PVar "argv")) (EMatch (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "argv")) (EVar "FmtWrite")) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple PWild (PList))) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "Usage: medaka fmt [--check | --stdout | --write] <path>...")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PList (PVar "target")))) () (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "fmtOne") (EVar "mode")) (EVar "target"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EListLit (EVar "target")))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PVar "targets"))) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EVar "targets")))))
(DTypeSig false "fmtManyTargets" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit")))))
(DFunDef false "fmtManyTargets" ((PCon "FmtStdout") PWild) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka fmt: --stdout requires exactly one file")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DFunDef false "fmtManyTargets" ((PVar "mode") (PVar "targets")) (EBlock (DoLet false false (PVar "files") (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka fmt: no .mdk files found")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm PWild () (EIf (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "files")) (EVar "False")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))
(DTypeSig false "fmtFilesGo" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO" "Mut" "Panic") None (TyCon "Bool"))))))
(DFunDef false "fmtFilesGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "fmtFilesGo" ((PVar "mode") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "hadErr") (EApp (EApp (EVar "fmtOneReport") (EVar "mode")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr"))))))
(DTypeSig false "fmtOneReport" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyCon "Bool")))))
(DFunDef false "fmtOneReport" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "formatted"))) (DoExpr (EVar "False")))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EVar "False") (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted"))))) (DoExpr (EVar "True"))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EVar "False") (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EVar "False")))))))))))))
(DTypeSig false "parseFmtArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "FmtMode") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "parseFmtArgs" ((PList) (PVar "mode") (PVar "acc")) (EApp (EVar "Ok") (ETuple (EVar "mode") (EApp (EVar "reverseL") (EVar "acc")))))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--check")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtCheck")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--stdout")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtStdout")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--write")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtWrite")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "-w")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtWrite")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PVar "x") (PVar "rest")) (PVar "mode") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "x")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "x")) (ELit (LString "-")))) (EApp (EVar "Err") (EBinOp "++" (ELit (LString "medaka fmt: unknown flag: ")) (EVar "x"))) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "mode")) (EBinOp "::" (EVar "x") (EVar "acc")))))
(DTypeSig false "fmtOne" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit")))))
(DFunDef false "fmtOne" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EApp (EVar "putStr") (EVar "formatted"))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ELit LUnit) (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" PWild) () (ELit LUnit)))))))))))))
(DTypeSig false "runNewCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Panic") None (TyCon "Unit"))))
(DFunDef false "runNewCmd" ((PList (PVar "name"))) (EBlock (DoLet false false (PVar "code") (EApp (EVar "newProject") (EVar "name"))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (ELit LUnit) (EApp (EVar "exit") (EVar "code"))))))
(DFunDef false "runNewCmd" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "Usage: medaka new <name>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DTypeSig false "runBuildCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runBuildCmd" ((PVar "argv")) (EMatch (EApp (EVar "parseBuildArgs") (EVar "argv")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PTuple (PVar "input") (PVar "outOpt") (PVar "target"))) () (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "input"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (ELit (LString "error: no such file: ")) (EVar "input")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "inputAbs") (EVar "input")) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false (PVar "outPath") (EMatch (EVar "outOpt") (arm (PCon "Some" (PVar "o")) () (EVar "o")) (arm (PCon "None") () (EApp (EApp (EVar "defaultOutPath") (EVar "target")) (EVar "input"))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "typecheckGate") (EVar "allowInternal")) (EVar "root")) (EVar "inputAbs")) (arm (PCon "TGErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "TGOk") () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuild") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "target")) (EVar "inputAbs")) (EVar "outPath")) (arm (PCon "BuildOk" (PVar "msg")) () (EApp (EVar "println") (EVar "msg"))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))))))))
(DTypeSig false "defaultOutPath" (TyFun (TyCon "BuildTarget") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "defaultOutPath" ((PCon "TNative") (PVar "input")) (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))))
(DFunDef false "defaultOutPath" ((PCon "TWasm") (PVar "input")) (EBinOp "++" (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))) (ELit (LString ".wasm"))))
(DData Private "TypecheckGate" () ((variant "TGOk" (ConPos)) (variant "TGErr" (ConPos (TyCon "String")))) ())
(DTypeSig false "typecheckGate" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyCon "TypecheckGate"))))))
(DFunDef false "typecheckGate" ((PVar "allowInternal") (PVar "root") (PVar "input")) (EBlock (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "input"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "input")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "TGErr") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "input")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "loadProgram") (EVar "input")) (EVar "roots")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "stdlibTrustedMods") (EVar "input")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckGateRoute") (EVar "allowInternal")) (EVar "trusted")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "input")) (EVar "mods")))))))))))))))))
(DTypeSig false "typecheckGateRoute" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO" "Mut" "Panic") None (TyCon "TypecheckGate")))))))))))
(DFunDef false "typecheckGateRoute" ((PVar "allowInternal") (PVar "trusted") PWild (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PList (PTuple (PVar "mid") PWild))) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EVar "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "TGOk")) (arm PWild () (EApp (EVar "TGErr") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target"))) (EVar "errs")))))))))
(DFunDef false "typecheckGateRoute" ((PVar "allowInternal") (PVar "trusted") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "mods")) (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneGF") (EVar "target")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EApp (EVar "hadTypeErrors") (ELit LUnit)) (arm (PCon "True") () (EApp (EVar "TGErr") (EApp (EApp (EApp (EApp (EVar "locatedOrGeneric") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")))) (arm (PCon "False") () (EVar "TGOk")))))) (arm PWild () (EApp (EVar "TGErr") (EVar "resDiags")))))))
(DTypeSig false "parseBuildArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))
(DFunDef false "parseBuildArgs" ((PVar "argv")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "argv")) (EListLit)) (EVar "None")) (EVar "TNative")))
(DTypeSig false "parseBuildGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget"))))))))
(DFunDef false "parseBuildGo" ((PList) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EVar "finishBuildArgs") (EApp (EVar "reverseL") (EVar "acc"))) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "-o")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EApp (EVar "Some") (EVar "v"))) (EVar "target")))
(DFunDef false "parseBuildGo" ((PList (PLit (LString "-o"))) PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: -o requires an argument"))))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--target")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc") (PVar "out") PWild) (EMatch (EApp (EVar "parseTarget") (EVar "v")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PVar "t")) () (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "t")))))
(DFunDef false "parseBuildGo" ((PList (PLit (LString "--target"))) PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: --target requires an argument (native|wasm)"))))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--allow-internal")) (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PVar "x") (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "acc"))) (EVar "out")) (EVar "target")))
(DTypeSig false "parseTarget" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BuildTarget"))))
(DFunDef false "parseTarget" ((PLit (LString "native"))) (EApp (EVar "Ok") (EVar "TNative")))
(DFunDef false "parseTarget" ((PLit (LString "wasm"))) (EApp (EVar "Ok") (EVar "TWasm")))
(DFunDef false "parseTarget" ((PVar "other")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "error: unknown --target '")) (EVar "other")) (ELit (LString "' (expected native|wasm)")))))
(DTypeSig false "finishBuildArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))))
(DFunDef false "finishBuildArgs" ((PList) PWild PWild) (EApp (EVar "Err") (ELit (LString "usage: medaka build [--target native|wasm] <file.mdk> [-o <out>]"))))
(DFunDef false "finishBuildArgs" ((PList (PVar "input")) (PVar "out") (PVar "target")) (EApp (EVar "Ok") (ETuple (EVar "input") (EVar "out") (EVar "target"))))
(DFunDef false "finishBuildArgs" (PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: medaka build takes exactly one input file"))))
(DTypeSig false "finishRunEval" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit")))))))
(DFunDef false "finishRunEval" ((PVar "target") (PVar "jsonMode") (PVar "elaborated") (PVar "mods")) (EBlock (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple PWild (PVar "edecls"))) () (EMatch (EApp (EVar "mainArityWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EMatch (EApp (EVar "mainNonUnitWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit)))))) (arm (PCon "None") () (EListLit)))) (DoLet false false PWild (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "mainWarns"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "currentEvalFile")) (EVar "target"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "runJsonMode")) (EVar "jsonMode"))) (DoExpr (EApp (EVar "putStr") (EApp (EApp (EVar "runProgramOutput") (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))))))
(DTypeSig false "runRunCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runRunCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoExpr (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka run [--release] [--json] <file.mdk>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") (PVar "progArgs")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "progArgsRef")) (EVar "progArgs"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "parseResult") (EApp (EVar "readFileSafe") (EVar "target"))) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "map") (EApp (EVar "map") (EVar "dropModPath"))) (EApp (EApp (EApp (EVar "loadProgramFilesLocated") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots"))) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "stdlibTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoExpr (EMatch (EVar "modsD") (arm (PList PWild) () (EBlock (DoLet false false (PVar "tsrc") (EApp (EVar "readFileSafe") (EVar "target"))) (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EVar "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EVar "elaborated")) (EVar "mods"))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target"))) (EVar "errs"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))) (arm PWild () (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneGF") (EVar "target")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EApp (EVar "hadTypeErrors") (ELit LUnit)) (arm (PCon "True") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "locatedOrGeneric") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "False") () (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EVar "elaborated")) (EVar "mods"))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "resDiags"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))))))))))))))))))))
(DTypeSig false "desugarPair" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugarPair" ((PTuple (PVar "mid") (PVar "p"))) (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "p"))))
(DTypeSig false "dropModPath" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "dropModPath" ((PTuple (PVar "mid") PWild (PVar "prog"))) (ETuple (EVar "mid") (EVar "prog")))
(DTypeSig false "runProgramOutput" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO" "Mut") None (TyCon "String")))))
(DFunDef false "runProgramOutput" ((PVar "preludeDecls") (PVar "modules")) (EMatch (EApp (EVar "mainTypeIsAsync") (ELit LUnit)) (arm (PCon "True") () (EApp (EApp (EVar "evalModulesOutputAsync") (EVar "preludeDecls")) (EVar "modules"))) (arm (PCon "False") () (EApp (EApp (EVar "evalModulesOutputRun") (EVar "preludeDecls")) (EVar "modules")))))
(DTypeSig false "runTestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runTestCmd" ((PVar "argv")) (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka test [file.mdk]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") PWild) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EVar "runTest") (EVar "rtPath")) (EVar "corePath")) (EVar "target")) (EVar "roots"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "exit") (ELit (LInt 1)))))))))
(DTypeSig false "runDocCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runDocCmd" ((PVar "argv")) (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka doc [file.mdk]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") PWild) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runDoc") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target"))))))))))))))
(DTypeSig false "runCheckPolicyCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runCheckPolicyCmd" ((PVar "argv")) (EMatch (EApp (EVar "parsePolicyArgs") (EVar "argv")) (arm (PCon "PolicyArgs" (PCon "None") PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "PolicyArgs" (PCon "Some" (PVar "target")) (PVar "allow") (PVar "fn")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "runCheckPolicy") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "allow")) (EVar "fn")) (arm (PCon "PolicyReject" (PVar "report")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "report"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "PolicyAccept" (PVar "header") (PVar "pluginFn") (PVar "coreD") (PVar "rtD") (PVar "userD")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "header"))) (DoExpr (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runAcceptedPlugin") (EVar "pluginFn")) (EVar "coreD")) (EVar "rtD")) (EVar "userD"))))))))))))))))))
(DTypeSig false "runManifestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runManifestCmd" ((PVar "argv")) (EMatch (EApp (EVar "parseManifestArgs") (EVar "argv")) (arm (PCon "ManifestArgs" (PCon "None") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka manifest <file.mdk> [--fn name]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "ManifestArgs" (PCon "Some" (PVar "target")) (PVar "fn")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runManifest") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "fn"))))))))))))))
(DTypeSig false "runLintCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runLintCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "disableNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--disable="))) (EVar "argv"))) (DoLet false false (PVar "onlyNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--only="))) (EVar "argv"))) (DoLet false false (PVar "denyNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--deny="))) (EVar "argv"))) (DoLet false false (PVar "fixMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--fix"))) (EVar "argv"))) (DoLet false false (PVar "fileArgs") (EApp (EVar "lintTargets") (EVar "argv"))) (DoLet false false (PVar "files") (EApp (EVar "resolveLintTargets") (EVar "fileArgs"))) (DoLet false false (PVar "multiFile") (EMatch (EVar "files") (arm (PCons PWild (PCons PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False")))) (DoLet false false (PVar "perFileErr") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "files")) (EVar "False"))) (DoLet false false (PVar "crossErr") (EIf (EBinOp "&&" (EVar "multiFile") (EApp (EVar "not") (EVar "fixMode"))) (EApp (EApp (EApp (EApp (EVar "runCrossFileReport") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "files")) (EVar "False"))) (DoExpr (EIf (EBinOp "||" (EVar "perFileErr") (EVar "crossErr")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))
(DTypeSig false "runCrossFileReport" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Bool")))))))
(DFunDef false "runCrossFileReport" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "files")) (EBlock (DoLet false false (PVar "triples") (EApp (EVar "parseLintFiles") (EVar "files"))) (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRules") (EVar "onlyNames")) (EVar "disableNames")) (EVar "triples"))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMulti") (EApp (EVar "readLintSrcs") (EVar "files"))) (EVar "raw"))) (DoLet false false (PVar "findings") (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed"))) (DoExpr (EMatch (EVar "findings") (arm (PList) () (EVar "False")) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "cross-file:")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "renderCrossFinding")) (EVar "findings"))))) (DoExpr (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")))))))))
(DTypeSig false "renderCrossFinding" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "renderCrossFinding" ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (ELit (LString ""))) (EApp (EVar "locFileOf") (EFieldAccess (EVar "f") "loc"))) (EApp (EVar "findingToDiag") (EVar "f"))))
(DTypeSig false "locFileOf" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locFileOf" ((PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild))) (EVar "file"))
(DFunDef false "locFileOf" ((PCon "None")) (ELit (LString "")))
(DTypeSig false "readLintSrcs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "readLintSrcs" ((PList)) (EListLit))
(DFunDef false "readLintSrcs" ((PCons (PVar "f") (PVar "rest"))) (EMatch (EApp (EVar "readFile") (EVar "f")) (arm (PCon "Err" PWild) () (EApp (EVar "readLintSrcs") (EVar "rest"))) (arm (PCon "Ok" (PVar "src")) () (EBinOp "::" (ETuple (EVar "f") (EVar "src")) (EApp (EVar "readLintSrcs") (EVar "rest"))))))
(DTypeSig false "parseLintFiles" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "parseLintFiles" ((PList)) (EListLit))
(DFunDef false "parseLintFiles" ((PCons (PVar "f") (PVar "rest"))) (EMatch (EApp (EVar "readFile") (EVar "f")) (arm (PCon "Err" PWild) () (EApp (EVar "parseLintFiles") (EVar "rest"))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoExpr (EBinOp "::" (ETuple (EVar "f") (EVar "pos") (EVar "decls")) (EApp (EVar "parseLintFiles") (EVar "rest"))))))))
(DTypeSig false "resolveLintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "resolveLintTargets" ((PList)) (EBlock (DoLet false false (PVar "cwd") (EApp (EVar "canonicalizePath") (ELit (LString ".")))) (DoLet false false (PVar "root") (EApp (EVar "findProjectRoot") (EVar "cwd"))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EBinOp "++" (EVar "root") (ELit (LString "/medaka.toml"))))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka lint: no medaka.toml found; run from a project directory or pass file/dir paths")))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EListLit))) (EApp (EVar "collectMdkFiles") (EVar "root"))))))
(DFunDef false "resolveLintTargets" ((PVar "targets")) (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets")))
(DTypeSig false "expandLintTarget" (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "expandLintTarget" ((PVar "target")) (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFiles") (EVar "target"))) (arm (PCon "Err" PWild) () (EListLit (EVar "target")))))
(DTypeSig false "lintPathJoin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "lintPathJoin" ((PVar "dir") (PVar "name")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "dir")) (EBinOp "++" (EVar "dir") (EVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))))
(DTypeSig false "collectMdkFiles" (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFiles" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: cannot list directory ")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EListLit)))) (arm (PCon "Ok" PWild) () (EApp (EVar "sortUniqS") (EApp (EVar "collectMdkFilesRec") (EVar "dir"))))))
(DTypeSig false "collectMdkFilesRec" (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFilesRec" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EApp (EVar "filterNonDot") (EVar "entries"))))))
(DTypeSig false "collectMdkEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntries" (PWild (PList)) (EListLit))
(DFunDef false "collectMdkEntries" ((PVar "dir") (PCons (PVar "name") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "collectMdkEntry") (EVar "dir")) (EVar "name")) (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EVar "rest"))))
(DTypeSig false "collectMdkEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntry" ((PVar "dir") (PVar "name")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "lintPathJoin") (EVar "dir")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFilesRec") (EVar "full"))) (arm (PCon "Err" PWild) () (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "name")) (EListLit (EVar "full")) (EListLit)))))))
(DTypeSig false "filterNonDot" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterNonDot" ((PList)) (EListLit))
(DFunDef false "filterNonDot" ((PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (EApp (EVar "filterNonDot") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "n") (EApp (EVar "filterNonDot") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lintFilesGo" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO" "Mut" "Panic") None (TyCon "Bool"))))))))))
(DFunDef false "lintFilesGo" (PWild PWild PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lintFilesGo" ((PVar "fixMode") (PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "hadErr") (EIf (EVar "fixMode") (EApp (EApp (EApp (EVar "lintOneFileFix") (EVar "onlyNames")) (EVar "disableNames")) (EVar "f")) (EApp (EApp (EApp (EApp (EApp (EVar "lintOneFileReport") (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "f")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr"))))))
(DTypeSig false "lintOneFileReport" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyCon "Bool"))))))))
(DFunDef false "lintOneFileReport" ((PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressions") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EVar "lintProgram") (EVar "allRules")) (EVar "target")) (EVar "src")) (EVar "pos")) (EVar "decls")))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "allFindings"))) (DoLet false false (PVar "output") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (ELam ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "target")) (EApp (EVar "findingToDiag") (EVar "f"))))) (EVar "findings")))) (DoLet false false (PVar "hasOutput") (EBinOp ">" (EApp (EVar "stringLength") (EVar "output")) (ELit (LInt 0)))) (DoLet false false PWild (EIf (EBinOp "&&" (EVar "multiFile") (EVar "hasOutput")) (EApp (EVar "putStrLn") (EBinOp "++" (EVar "target") (ELit (LString ":")))) (ELit LUnit))) (DoLet false false PWild (EIf (EVar "hasOutput") (EApp (EVar "putStrLn") (EVar "output")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")))))))
(DTypeSig false "lintOneFileFix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyCon "Bool"))))))
(DFunDef false "lintOneFileFix" ((PVar "onlyNames") (PVar "disableNames") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PTuple (PVar "newSrc") (PVar "n")) (EApp (EApp (EApp (EApp (EApp (EVar "applyFixes") (EVar "onlyNames")) (EVar "disableNames")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoExpr (EIf (EBinOp "==" (EVar "newSrc") (EVar "src")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "fixed 0 finding(s) in ")) (EVar "target")))) (DoExpr (EVar "False"))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "target")) (EVar "newSrc")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 2)))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "fixed ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " finding(s) in "))) (EApp (EVar "display") (EVar "target"))) (ELit (LString ""))))) (DoExpr (EVar "False")))))))))))
(DTypeSig false "lintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "lintTargets" ((PList)) (EListLit))
(DFunDef false "lintTargets" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "x")) (EApp (EVar "lintTargets") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EVar "lintTargets") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "assertSnapshotTargetsExist" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "assertSnapshotTargetsExist" ((PVar "files")) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EVar "filter") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "f"))))) (EVar "files"))) (DoExpr (EIf (EBinOp "==" (EVar "missing") (EListLit)) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: these targets do not exist:")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (EVar "missing"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))
(DTypeSig false "runSnapshotCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runSnapshotCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "root") (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--root"))) (EVar "argv")) (arm (PCon "Some" (PVar "r")) () (EVar "r")) (arm (PCon "None") () (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))))) (DoLet false false (PVar "sel") (EApp (EVar "snapshotStages") (EVar "argv"))) (DoLet false false (PVar "files") (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EApp (EVar "snapshotTargets") (EVar "argv")))) (DoLet false false PWild (EApp (EVar "assertSnapshotTargetsExist") (EVar "files"))) (DoExpr (EIf (EBinOp "==" (EVar "files") (EListLit)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka snapshot [--check|--new] [--out <dir>] [--stages <a,b,…>] <paths...>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EIf (EApp (EApp (EVar "hasFlag") (ELit (LString "--worker"))) (EVar "argv")) (EApp (EApp (EApp (EVar "runSnapshotWorker") (EVar "root")) (EVar "sel")) (EVar "files")) (EBlock (DoLet false false (PVar "check") (EApp (EApp (EVar "hasFlag") (ELit (LString "--check"))) (EVar "argv"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "check")) (EApp (EVar "not") (EApp (EApp (EVar "hasFlag") (ELit (LString "--new"))) (EVar "argv")))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: pass --check (verify) or --new (create missing snapshots)")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EBlock (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSnapshotSupervisor") (EVar "root")) (EVar "check")) (EApp (EApp (EVar "hasFlag") (ELit (LString "--isolate"))) (EVar "argv"))) (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--out"))) (EVar "argv"))) (EVar "sel")) (EVar "files"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "exit") (ELit (LInt 1))))))))))))))
(DTypeSig false "snapshotStages" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Panic") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "snapshotStages" ((PVar "argv")) (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--stages"))) (EVar "argv")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "spec")) () (EMatch (EApp (EVar "parseStages") (EVar "spec")) (arm (PCon "Ok" (PVar "names")) () (EVar "names")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka snapshot: ")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EListLit))))))))
(DTypeSig false "snapshotTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "snapshotTargets" ((PList)) (EListLit))
(DFunDef false "snapshotTargets" ((PCons (PLit (LString "--out")) (PCons PWild (PVar "rest")))) (EApp (EVar "snapshotTargets") (EVar "rest")))
(DFunDef false "snapshotTargets" ((PCons (PLit (LString "--root")) (PCons PWild (PVar "rest")))) (EApp (EVar "snapshotTargets") (EVar "rest")))
(DFunDef false "snapshotTargets" ((PCons (PLit (LString "--stages")) (PCons PWild (PVar "rest")))) (EApp (EVar "snapshotTargets") (EVar "rest")))
(DFunDef false "snapshotTargets" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "x")) (EApp (EVar "snapshotTargets") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EVar "snapshotTargets") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "snapFlagValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "snapFlagValue" (PWild (PList)) (EVar "None"))
(DFunDef false "snapFlagValue" (PWild (PList PWild)) (EVar "None"))
(DFunDef false "snapFlagValue" ((PVar "name") (PCons (PVar "a") (PCons (PVar "v") (PVar "rest")))) (EIf (EBinOp "==" (EVar "a") (EVar "name")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "snapFlagValue") (EVar "name")) (EBinOp "::" (EVar "v") (EVar "rest")))))
(DTypeSig false "parseLintFlagList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "parseLintFlagList" ((PVar "prefix") (PList)) (EListLit))
(DFunDef false "parseLintFlagList" ((PVar "prefix") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "x")) (EApp (EVar "splitLintNames") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "x"))) (EVar "x"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseLintFlagList") (EVar "prefix")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "splitLintNames" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitLintNames" ((PVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EApp (EVar "stringToChars") (EVar "s"))) (EVar "s")) (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))))
(DTypeSig false "splitLintNamesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitLintNamesGo" ((PVar "chars") (PVar "s") (PVar "start") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "n")) (EVar "s"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar ","))) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "i")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EVar "chars")) (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EVar "chars")) (EVar "s")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "applyFindingFilters" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "applyFindingFilters" ((PVar "disable") (PVar "only") (PVar "deny") (PVar "findings")) (EBlock (DoLet false false (PVar "after1") (EApp (EApp (EVar "applyFindingOnly") (EVar "only")) (EVar "findings"))) (DoLet false false (PVar "after2") (EApp (EApp (EVar "applyFindingDisable") (EVar "disable")) (EVar "after1"))) (DoExpr (EApp (EApp (EVar "applyFindingDeny") (EVar "deny")) (EVar "after2")))))
(DTypeSig false "applyFindingOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingOnly" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingOnly" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingOnlyGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingOnlyGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingOnlyGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyFindingDisable" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingDisable" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingDisable" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingDisableGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingDisableGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingDisableGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyFindingDeny" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingDeny" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingDeny" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingDenyGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingDenyGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingDenyGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EBinOp "::" (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EVar "SevError")) (fa "loc" (EFieldAccess (EVar "f") "loc")))) (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isFindingError" (TyFun (TyCon "Finding") (TyCon "Bool")))
(DFunDef false "isFindingError" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "severity") (arm (PCon "SevError") () (EVar "True")) (arm (PCon "SevWarning") () (EVar "False"))))
(DTypeSig false "dirOf2" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOf2" ((PVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirGo2" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirGo2" ((PVar "path") (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirGo2" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "runReplCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runReplCmd" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "preludeDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false PWild (EApp (EApp (EVar "initSession") (EVar "runtimeDecls")) (EVar "preludeDecls"))) (DoExpr (EApp (EVar "replLoop") (ELit LUnit)))))))))))
(DTypeSig false "runLspCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runLspCmd" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EApp (EApp (EVar "runServer") (EVar "rsrc")) (EVar "csrc")))))))))
# MARK
(DUse false (UseGroup ("tools" "check") ((mem "runCheck" false) (mem "checkHasErrors" false) (mem "runCheckModules" false))))
(DUse false (UseGroup ("tools" "snapshot") ((mem "runSnapshotWorker" false) (mem "runSnapshotSupervisor" false) (mem "parseStages" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSource" false))))
(DUse false (UseGroup ("tools" "new_cmd") ((mem "newProject" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "BuildResult" false) (mem "BuildOk" false) (mem "BuildErr" false) (mem "BuildTarget" false) (mem "TNative" false) (mem "TWasm" false) (mem "runBuild" false) (mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinNl" false) (mem "splitNl" false) (mem "startsWith" false) (mem "endsWith" false) (mem "anyList" false) (mem "contains" false) (mem "sortUniqS" false) (mem "schemeLineName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("support" "path") ((mem "baseOf" false) (mem "chopExt" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" false) (mem "LetBind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseWithPositions" false) (mem "parseResult" false) (mem "ParseError" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false) (mem "Positions" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "resolveModulesToHumane" false) (mem "resolveModulesToHumaneG" false) (mem "resolveModulesToHumaneGF" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "loadProgram" false) (mem "loadProgramFilesLocated" false) (mem "findProjectRoot" false) (mem "entrySearchRoots" false) (mem "stdlibTrustedMods" false) (mem "unknownModuleIdOf" false) (mem "findImportLoc" false) (mem "availableModulesHint" false) (mem "availableModulesText" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeProject" false) (mem "analyzeLocated" false) (mem "analyzeLocatedG" false) (mem "ppDiagCli" false) (mem "ppDiagCliSrc" false) (mem "Diag" true) (mem "Severity" true) (mem "SevError" false) (mem "cjPosition" false) (mem "cjRange" false) (mem "cjRangeOfLoc" false) (mem "cjDiagnostic" false) (mem "cjFileEntry" false) (mem "cjAllToJson" false) (mem "readDiagSrc" false) (mem "parseErrCode" false) (mem "parseErrHelpFix" false) (mem "codeKind" false) (mem "optField" false) (mem "cjFixJson" false) (mem "mkDiag" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JInt" false) (mem "JString" false) (mem "JArray" false) (mem "JObject" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "elaborateModules" false) (mem "resetTypeErrorsSticky" false) (mem "hadTypeErrors" false) (mem "mainTypeIsAsync" false) (mem "mainTypeIsUnit" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "evalModulesOutputRun" false) (mem "evalModulesOutputAsync" false) (mem "currentEvalFile" false) (mem "runJsonMode" false) (mem "progArgsRef" false))))
(DUse false (UseGroup ("tools" "test_cmd") ((mem "runTest" false))))
(DUse false (UseGroup ("tools" "repl") ((mem "initSession" false) (mem "replLoop" false))))
(DUse false (UseGroup ("tools" "lsp") ((mem "runServer" false))))
(DUse false (UseGroup ("tools" "doc") ((mem "runDoc" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "allRules" false) (mem "lintProgram" false) (mem "applySuppressions" false) (mem "applySuppressionsMulti" false) (mem "findingToDiag" false) (mem "Finding" false) (mem "applyFixes" false) (mem "runCrossFileRules" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "runCheckPolicy" false) (mem "runAcceptedPlugin" false) (mem "PolicyArgs" true) (mem "parsePolicyArgs" false) (mem "PolicyOutcome" true) (mem "runManifest" false) (mem "parseManifestArgs" false) (mem "ManifestArgs" true))))
(DTypeSig false "medakaVersion" (TyCon "String"))
(DFunDef false "medakaVersion" () (ELit (LString "0.1.0-preview")))
(DTypeSig false "printVersion" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printVersion" (PWild) (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "medaka ")) (EVar "medakaVersion"))))
(DTypeSig false "main" (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit")))
(DFunDef false "main" () (EMatch (EApp (EVar "args") (ELit LUnit)) (arm (PList) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "-h")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "-v")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "check")) (PVar "rest")) () (EApp (EVar "runCheckCmd") (EVar "rest"))) (arm (PCons (PLit (LString "fmt")) (PVar "rest")) () (EApp (EVar "runFmtCmd") (EVar "rest"))) (arm (PCons (PLit (LString "new")) (PVar "rest")) () (EApp (EVar "runNewCmd") (EVar "rest"))) (arm (PCons (PLit (LString "build")) (PVar "rest")) () (EApp (EVar "runBuildCmd") (EVar "rest"))) (arm (PCons (PLit (LString "run")) (PVar "rest")) () (EApp (EVar "runRunCmd") (EVar "rest"))) (arm (PCons (PLit (LString "test")) (PVar "rest")) () (EApp (EVar "runTestCmd") (EVar "rest"))) (arm (PCons (PLit (LString "snapshot")) (PVar "rest")) () (EApp (EVar "runSnapshotCmd") (EVar "rest"))) (arm (PCons (PLit (LString "doc")) (PVar "rest")) () (EApp (EVar "runDocCmd") (EVar "rest"))) (arm (PCons (PLit (LString "lint")) (PVar "rest")) () (EApp (EVar "runLintCmd") (EVar "rest"))) (arm (PCons (PLit (LString "check-policy")) (PVar "rest")) () (EApp (EVar "runCheckPolicyCmd") (EVar "rest"))) (arm (PCons (PLit (LString "manifest")) (PVar "rest")) () (EApp (EVar "runManifestCmd") (EVar "rest"))) (arm (PCons (PLit (LString "repl")) (PVar "rest")) () (EApp (EVar "runReplCmd") (EVar "rest"))) (arm (PCons (PLit (LString "lsp")) (PVar "rest")) () (EApp (EVar "runLspCmd") (EVar "rest"))) (arm (PCons (PVar "sub") PWild) () (EApp (EVar "notYet") (EMethodRef "sub")))))
(DTypeSig false "usage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "usage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka. A functional language compiler\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka                    Show this message\n")) (ELit (LString "  medaka run [--release] <file.mdk>   Type-check and run a program\n")) (ELit (LString "  medaka build <file.mdk> [-o <out>]  Compile to a native binary (LLVM + clang)\n")) (ELit (LString "  medaka check [--json] <file.mdk>    Type-check without running\n")) (ELit (LString "  medaka test [file.mdk]    Run doctests + prop tests\n")) (ELit (LString "  medaka bench [file.mdk]   Run bench declarations\n")) (ELit (LString "  medaka doc [file.mdk]     Generate Markdown documentation\n")) (ELit (LString "  medaka lint [paths...]    Lint files/dirs (style rules; --fix, --disable/--only/--deny=<rules,...>)\n")) (ELit (LString "  medaka snapshot [--check|--new] [paths...]  Per-stage snapshot tests (--out <dir>, --stages <a,b,..>)\n")) (ELit (LString "  medaka fmt [paths...]     Format .mdk files in place (or --check)\n")) (ELit (LString "  medaka new <name>         Scaffold a new project directory\n")) (ELit (LString "  medaka lsp                Run the language server over stdio\n")) (ELit (LString "  medaka help               Show this message\n")) (ELit (LString "  medaka --version          Show the compiler version\n"))))))
(DTypeSig false "notYet" (TyFun (TyCon "String") (TyEffect ("IO" "Panic") None (TyCon "Unit"))))
(DFunDef false "notYet" ((PVar "sub")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka: subcommand '")) (EMethodRef "sub")) (ELit (LString "' not yet in native CLI"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "ppParseError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "ppParseError" ((PVar "src") (PVar "file") (PVar "e")) (EBlock (DoLet false false (PVar "ploc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EApp (EVar "parseErrorCol") (EVar "e"))) (EApp (EVar "parseErrorLine") (EVar "e"))) (EBinOp "+" (EApp (EVar "parseErrorCol") (EVar "e")) (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "h") (PVar "fx")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "file")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (EApp (EVar "parseErrorMessage") (EVar "e"))) (EApp (EVar "Some") (EVar "ploc"))) (EVar "h")) (EVar "fx"))))))
(DTypeSig false "runCheckCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runCheckCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false (PVar "typesMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--types"))) (EVar "argv"))) (DoLet false false (PVar "argv2") (EApp (EVar "dropFlags") (EVar "argv"))) (DoExpr (EMatch (EVar "argv2") (arm (PList (PVar "target")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EIf (EVar "jsonMode") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runCheckJsonCmd") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EMethodRef "map") (EApp (EMethodRef "map") (EVar "dropModPath"))) (EApp (EApp (EApp (EVar "loadProgramFilesLocated") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots"))) (arm (PCon "Err" (PVar "lmsg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "target")) (EVar "stdlibDir")) (EVar "lmsg")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "stdlibTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkRoute") (EVar "typesMode")) (EVar "allowInternal")) (EVar "trusted")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EVar "mods")))))))))))))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check [--json] [--types] [--allow-internal] <file.mdk>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DTypeSig false "moduleLoadErrText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Mut") None (TyCon "String")))))))
(DFunDef false "moduleLoadErrText" ((PVar "tsrc") (PVar "target") (PVar "stdlibDir") (PVar "lmsg")) (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "lmsg")) (arm (PCon "Some" (PVar "mid")) () (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EVar "lmsg") (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "tsrc"))) (arm (PCon "None") () (EVar "msg")) (arm (PCon "Some" (PVar "loc")) () (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "msg")) (EApp (EVar "Some") (EVar "loc"))) (EVar "None")) (EVar "None"))))))))))
(DTypeSig false "locatedProjectErrors" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Mut") None (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "locatedProjectErrors" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EBlock (DoLet false false (PVar "cacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "cacheRef")) (EVar "parseCacheRef")) (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc"))) (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (EVar "readDiagSrc")) (EVar "results"))) (DoLet false false (PVar "rendered") (EApp (EApp (EDictApp "flatMap") (EVar "renderTripleErrors")) (EVar "triples"))) (DoExpr (EMatch (EVar "rendered") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "rendered"))))))))
(DTypeSig false "renderTripleErrors" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderTripleErrors" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "path"))) (EApp (EApp (EMethodRef "filter") (EVar "isDiagError")) (EVar "diags"))))
(DTypeSig false "locatedOrGeneric" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Mut") None (TyCon "String")))))))
(DFunDef false "locatedOrGeneric" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EMatch (EApp (EApp (EApp (EApp (EVar "locatedProjectErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "error: type error in ")) (EVar "target")) (ELit (LString ". Run `medaka check` for details"))))))
(DTypeSig false "checkRoute" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))))))))))
(DFunDef false "checkRoute" ((PVar "typesMode") (PVar "allowInternal") (PVar "trusted") PWild (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PList (PTuple (PVar "mid") (PVar "decls")))) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EMethodRef "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false (PVar "warns") (EApp (EApp (EMethodRef "filter") (EVar "isDiagWarn")) (EVar "diags"))) (DoLet false false (PVar "dump") (EApp (EVar "stripWarningLines") (EApp (EApp (EApp (EVar "runCheck") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")))) (DoLet false false (PVar "report") (EIf (EVar "typesMode") (EVar "dump") (EApp (EApp (EVar "userSchemeLines") (EVar "decls")) (EVar "dump")))) (DoLet false false PWild (EApp (EVar "putStr") (EVar "report"))) (DoLet false false (PVar "mainWarns") (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (EListLit (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "decls"))))) (EVar "decls"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EBinOp "++" (EVar "warns") (EVar "mainWarns")))) (DoExpr (ELit LUnit)))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target"))) (EVar "errs"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DFunDef false "checkRoute" ((PVar "typesMode") (PVar "allowInternal") (PVar "trusted") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "mods")) (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneGF") (EVar "target")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EMatch (EApp (EApp (EApp (EApp (EVar "locatedProjectErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PCon "Some" (PVar "errText")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "errText"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EApp (EVar "runCheckModules") (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD")))) (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple (PVar "emid") (PVar "edecls"))) () (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EVar "rtD")) (EVar "coreD")) (EVar "modsD")) (EVar "edecls"))) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EVar "mainWarns"))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "resDiags"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DTypeSig false "findMainFunDef" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "findMainFunDef" ((PList)) (EVar "None"))
(DFunDef false "findMainFunDef" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "findMainFunDef") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "findMainFunDef" ((PCons (PCon "DFunDef" PWild (PLit (LString "main")) (PVar "ps") (PVar "body")) PWild)) (EApp (EVar "Some") (ETuple (EVar "ps") (EVar "body"))))
(DFunDef false "findMainFunDef" ((PCons PWild (PVar "rest"))) (EApp (EVar "findMainFunDef") (EVar "rest")))
(DTypeSig false "mainBodyLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "mainBodyLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "mainBodyLoc" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "mainBodyLoc") (EVar "f")))
(DFunDef false "mainBodyLoc" (PWild) (EVar "None"))
(DTypeSig false "mainArityMsg" (TyCon "String"))
(DFunDef false "mainArityMsg" () (ELit (LString "'main' must be a value of type Unit. Write 'main = …', not 'main () = …' or 'main x = …' ('medaka run' never applies main; it forces a zero-arg main for its effects)")))
(DTypeSig false "mainNonUnitMsg" (TyCon "String"))
(DFunDef false "mainNonUnitMsg" () (ELit (LString "'main' must be a value of type Unit (e.g. an IO action). 'medaka run' only forces main for its side effects and prints nothing for a plain value; wrap the intended effect, e.g. 'main = println \"hi\"'")))
(DTypeSig false "mainArityWarning" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Diag"))))
(DFunDef false "mainArityWarning" ((PVar "decls")) (EMatch (EApp (EVar "findMainFunDef") (EVar "decls")) (arm (PCon "Some" (PTuple (PCons PWild PWild) (PVar "body"))) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevWarning")) (ELit (LString "W-MAIN-SHAPE"))) (EVar "mainArityMsg")) (EApp (EVar "mainBodyLoc") (EVar "body"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "mainNonUnitWarning" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("Mut") None (TyApp (TyCon "Option") (TyCon "Diag")))))
(DFunDef false "mainNonUnitWarning" ((PVar "decls")) (EMatch (EApp (EVar "findMainFunDef") (EVar "decls")) (arm (PCon "Some" (PTuple (PList) (PVar "body"))) () (EIf (EBinOp "||" (EApp (EVar "mainTypeIsUnit") (ELit LUnit)) (EApp (EVar "mainTypeIsAsync") (ELit LUnit))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevWarning")) (ELit (LString "W-MAIN-SHAPE"))) (EVar "mainNonUnitMsg")) (EApp (EVar "mainBodyLoc") (EVar "body")))))) (arm PWild () (EVar "None"))))
(DTypeSig false "mainShapeWarnings" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("Mut") None (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "mainShapeWarnings" ((PVar "rtD") (PVar "coreD") (PVar "modsDFull") (PVar "entryDecls")) (EMatch (EApp (EVar "mainArityWarning") (EVar "entryDecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsDFull"))) (DoExpr (EMatch (EApp (EVar "mainNonUnitWarning") (EVar "entryDecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit))))))))
(DTypeSig false "lastModPair" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lastModPair" ((PList)) (EVar "None"))
(DFunDef false "lastModPair" ((PList (PVar "p"))) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "lastModPair" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModPair") (EVar "rest")))
(DTypeSig false "dropFlags" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropFlags" ((PList)) (EListLit))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--json")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--release")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--allow-internal")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PLit (LString "--types")) (PVar "rest"))) (EApp (EVar "dropFlags") (EVar "rest")))
(DFunDef false "dropFlags" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "dropFlags") (EVar "rest"))))
(DTypeSig false "hasFlag" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "hasFlag" (PWild (PList)) (EVar "False"))
(DFunDef false "hasFlag" ((PVar "flag") (PCons (PVar "x") (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EVar "flag")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "hasFlag") (EVar "flag")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runCheckJsonCmd" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit")))))))))
(DFunDef false "runCheckJsonCmd" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "roots") (PVar "stdlibDir")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "target"))) (DoExpr (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false (PVar "ln") (EBinOp "-" (EApp (EVar "parseErrorLine") (EVar "e")) (ELit (LInt 1)))) (DoLet false false (PVar "col") (EApp (EVar "parseErrorCol") (EVar "e"))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EApp (EVar "cjRange") (EVar "ln")) (EVar "col")) (EVar "ln")) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (DoLet false false (PVar "pcode") (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (DoLet false false (PVar "ploc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "target")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EVar "col")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "phelp") (PVar "pfix")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoLet false false (PVar "diagJson") (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JString") (EVar "pcode")))) (EApp (EApp (EVar "optField") (ELit (LString "fix"))) (EApp (EApp (EMethodRef "map") (EVar "cjFixJson")) (EVar "pfix")))) (EApp (EApp (EVar "optField") (ELit (LString "help"))) (EApp (EApp (EMethodRef "map") (EVar "JString")) (EVar "phelp")))) (EListLit (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EApp (EVar "codeKind") (EVar "pcode")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EApp (EVar "parseErrorMessage") (EVar "e")))) (ETuple (ELit (LString "range")) (EVar "r")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka")))))))) (DoLet false false (PVar "filesJson") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "target"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EListLit (EVar "diagJson")))))))) (DoLet false false PWild (EApp (EDictApp "println") (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "files")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EListLit (EVar "filesJson")))))))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "lmsg")) () (EBlock (DoLet false false (PVar "mloc") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "mid")) () (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "src")))))) (DoLet false false (PVar "mhelp") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" PWild) () (EMatch (EApp (EVar "availableModulesText") (EVar "stdlibDir")) (arm (PLit (LString "")) () (EVar "None")) (arm (PVar "txt") () (EApp (EVar "Some") (EVar "txt"))))))) (DoLet false false (PVar "jmsg") (EBinOp "++" (EVar "lmsg") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" PWild) () (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))))) (DoLet false false (PVar "triples") (EListLit (ETuple (EVar "target") (EVar "src") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "jmsg")) (EVar "mloc")) (EVar "mhelp")) (EVar "None")))))) (DoLet false false PWild (EApp (EDictApp "println") (EApp (EVar "cjAllToJson") (EVar "triples")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "mods")) () (EMatch (EVar "mods") (arm (PList (PTuple (PVar "mid") PWild)) () (EBlock (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "stdlibTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "src"))) (DoLet false false PWild (EApp (EDictApp "println") (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "target") (EVar "src") (EVar "diags")))))) (DoLet false false (PVar "hasErr") (EApp (EApp (EDictApp "any") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EIf (EVar "hasErr") (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit))))) (arm PWild () (EBlock (DoLet false false (PVar "cacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "cacheRef")) (EVar "parseCacheRef")) (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc"))) (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (EVar "readDiagSrc")) (EVar "results"))) (DoLet false false PWild (EApp (EDictApp "println") (EApp (EVar "cjAllToJson") (EVar "triples")))) (DoLet false false (PVar "hasErr") (EApp (EApp (EDictApp "any") (EVar "cjHasErr")) (EVar "results"))) (DoExpr (EIf (EVar "hasErr") (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))))))))
(DTypeSig false "readFileSafe" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "readFileSafe" ((PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Ok" (PVar "src")) () (EVar "src")) (arm (PCon "Err" PWild) () (ELit (LString "")))))
(DTypeSig false "cjHasErr" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "cjHasErr" ((PTuple PWild (PVar "diags"))) (EApp (EApp (EDictApp "any") (EVar "isDiagError")) (EVar "diags")))
(DTypeSig false "isDiagError" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isDiagError" ((PCon "Diag" (PCon "SevError") PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isDiagError" (PWild) (EVar "False"))
(DTypeSig false "isDiagWarn" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "isDiagWarn" ((PVar "d")) (EApp (EVar "not") (EApp (EVar "isDiagError") (EVar "d"))))
(DTypeSig false "stripWarningLines" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripWarningLines" ((PVar "s")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "l")) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "Warning: "))) (EVar "l"))))) (EApp (EVar "splitNl") (EVar "s")))))
(DTypeSig false "userSchemeLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "userSchemeLines" ((PVar "decls") (PVar "report")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "omFromNames") (EApp (EVar "topLevelNames") (EVar "decls"))) (EVar "omEmpty"))) (DoExpr (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "filter") (EApp (EVar "namesUserBinding") (EVar "names"))) (EApp (EVar "splitNl") (EVar "report")))))))
(DTypeSig false "namesUserBinding" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "namesUserBinding" ((PVar "names") (PVar "l")) (EMatch (EApp (EVar "schemeLineName") (EVar "l")) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "topLevelNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topLevelNames" ((PList)) (EListLit))
(DFunDef false "topLevelNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "topLevelNames") (EListLit (EVar "d"))) (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")) (EApp (EVar "topLevelNames") (EVar "rest"))))
(DFunDef false "topLevelNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "topLevelNames") (EVar "rest")))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "emitLocatedWarnings" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitLocatedWarnings" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "emitLocatedWarnings" ((PVar "src") (PVar "file") (PVar "ws")) (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "file"))) (EVar "ws")))))
(DData Private "FmtMode" () ((variant "FmtWrite" (ConPos)) (variant "FmtStdout" (ConPos)) (variant "FmtCheck" (ConPos))) ())
(DTypeSig false "runFmtCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runFmtCmd" ((PVar "argv")) (EMatch (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "argv")) (EVar "FmtWrite")) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple PWild (PList))) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "Usage: medaka fmt [--check | --stdout | --write] <path>...")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PList (PVar "target")))) () (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "fmtOne") (EVar "mode")) (EVar "target"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EListLit (EVar "target")))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PVar "targets"))) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EVar "targets")))))
(DTypeSig false "fmtManyTargets" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit")))))
(DFunDef false "fmtManyTargets" ((PCon "FmtStdout") PWild) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka fmt: --stdout requires exactly one file")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DFunDef false "fmtManyTargets" ((PVar "mode") (PVar "targets")) (EBlock (DoLet false false (PVar "files") (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka fmt: no .mdk files found")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm PWild () (EIf (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "files")) (EVar "False")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))
(DTypeSig false "fmtFilesGo" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO" "Mut" "Panic") None (TyCon "Bool"))))))
(DFunDef false "fmtFilesGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "fmtFilesGo" ((PVar "mode") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "hadErr") (EApp (EApp (EVar "fmtOneReport") (EVar "mode")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr"))))))
(DTypeSig false "fmtOneReport" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyCon "Bool")))))
(DFunDef false "fmtOneReport" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "formatted"))) (DoExpr (EVar "False")))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EVar "False") (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted"))))) (DoExpr (EVar "True"))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EVar "False") (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EVar "False")))))))))))))
(DTypeSig false "parseFmtArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "FmtMode") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "parseFmtArgs" ((PList) (PVar "mode") (PVar "acc")) (EApp (EVar "Ok") (ETuple (EVar "mode") (EApp (EVar "reverseL") (EVar "acc")))))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--check")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtCheck")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--stdout")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtStdout")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--write")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtWrite")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "-w")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtWrite")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PVar "x") (PVar "rest")) (PVar "mode") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "x")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "x")) (ELit (LString "-")))) (EApp (EVar "Err") (EBinOp "++" (ELit (LString "medaka fmt: unknown flag: ")) (EVar "x"))) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "mode")) (EBinOp "::" (EVar "x") (EVar "acc")))))
(DTypeSig false "fmtOne" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit")))))
(DFunDef false "fmtOne" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EApp (EVar "putStr") (EVar "formatted"))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ELit LUnit) (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" PWild) () (ELit LUnit)))))))))))))
(DTypeSig false "runNewCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Panic") None (TyCon "Unit"))))
(DFunDef false "runNewCmd" ((PList (PVar "name"))) (EBlock (DoLet false false (PVar "code") (EApp (EVar "newProject") (EVar "name"))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (ELit LUnit) (EApp (EVar "exit") (EVar "code"))))))
(DFunDef false "runNewCmd" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "Usage: medaka new <name>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DTypeSig false "runBuildCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runBuildCmd" ((PVar "argv")) (EMatch (EApp (EVar "parseBuildArgs") (EVar "argv")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PTuple (PVar "input") (PVar "outOpt") (PVar "target"))) () (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "input"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (ELit (LString "error: no such file: ")) (EVar "input")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "inputAbs") (EVar "input")) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false (PVar "outPath") (EMatch (EVar "outOpt") (arm (PCon "Some" (PVar "o")) () (EVar "o")) (arm (PCon "None") () (EApp (EApp (EVar "defaultOutPath") (EVar "target")) (EVar "input"))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "typecheckGate") (EVar "allowInternal")) (EVar "root")) (EVar "inputAbs")) (arm (PCon "TGErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "TGOk") () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuild") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "target")) (EVar "inputAbs")) (EVar "outPath")) (arm (PCon "BuildOk" (PVar "msg")) () (EApp (EDictApp "println") (EVar "msg"))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))))))))
(DTypeSig false "defaultOutPath" (TyFun (TyCon "BuildTarget") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "defaultOutPath" ((PCon "TNative") (PVar "input")) (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))))
(DFunDef false "defaultOutPath" ((PCon "TWasm") (PVar "input")) (EBinOp "++" (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))) (ELit (LString ".wasm"))))
(DData Private "TypecheckGate" () ((variant "TGOk" (ConPos)) (variant "TGErr" (ConPos (TyCon "String")))) ())
(DTypeSig false "typecheckGate" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyCon "TypecheckGate"))))))
(DFunDef false "typecheckGate" ((PVar "allowInternal") (PVar "root") (PVar "input")) (EBlock (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "input"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "input")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "TGErr") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "input")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "loadProgram") (EVar "input")) (EVar "roots")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "stdlibTrustedMods") (EVar "input")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckGateRoute") (EVar "allowInternal")) (EVar "trusted")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "input")) (EVar "mods")))))))))))))))))
(DTypeSig false "typecheckGateRoute" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO" "Mut" "Panic") None (TyCon "TypecheckGate")))))))))))
(DFunDef false "typecheckGateRoute" ((PVar "allowInternal") (PVar "trusted") PWild (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PList (PTuple (PVar "mid") PWild))) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EMethodRef "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "TGOk")) (arm PWild () (EApp (EVar "TGErr") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target"))) (EVar "errs")))))))))
(DFunDef false "typecheckGateRoute" ((PVar "allowInternal") (PVar "trusted") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "mods")) (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneGF") (EVar "target")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EApp (EVar "hadTypeErrors") (ELit LUnit)) (arm (PCon "True") () (EApp (EVar "TGErr") (EApp (EApp (EApp (EApp (EVar "locatedOrGeneric") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")))) (arm (PCon "False") () (EVar "TGOk")))))) (arm PWild () (EApp (EVar "TGErr") (EVar "resDiags")))))))
(DTypeSig false "parseBuildArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))
(DFunDef false "parseBuildArgs" ((PVar "argv")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "argv")) (EListLit)) (EVar "None")) (EVar "TNative")))
(DTypeSig false "parseBuildGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget"))))))))
(DFunDef false "parseBuildGo" ((PList) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EVar "finishBuildArgs") (EApp (EVar "reverseL") (EVar "acc"))) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "-o")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EApp (EVar "Some") (EVar "v"))) (EVar "target")))
(DFunDef false "parseBuildGo" ((PList (PLit (LString "-o"))) PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: -o requires an argument"))))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--target")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc") (PVar "out") PWild) (EMatch (EApp (EVar "parseTarget") (EVar "v")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PVar "t")) () (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "t")))))
(DFunDef false "parseBuildGo" ((PList (PLit (LString "--target"))) PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: --target requires an argument (native|wasm)"))))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--allow-internal")) (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PVar "x") (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "acc"))) (EVar "out")) (EVar "target")))
(DTypeSig false "parseTarget" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BuildTarget"))))
(DFunDef false "parseTarget" ((PLit (LString "native"))) (EApp (EVar "Ok") (EVar "TNative")))
(DFunDef false "parseTarget" ((PLit (LString "wasm"))) (EApp (EVar "Ok") (EVar "TWasm")))
(DFunDef false "parseTarget" ((PVar "other")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "error: unknown --target '")) (EVar "other")) (ELit (LString "' (expected native|wasm)")))))
(DTypeSig false "finishBuildArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))))
(DFunDef false "finishBuildArgs" ((PList) PWild PWild) (EApp (EVar "Err") (ELit (LString "usage: medaka build [--target native|wasm] <file.mdk> [-o <out>]"))))
(DFunDef false "finishBuildArgs" ((PList (PVar "input")) (PVar "out") (PVar "target")) (EApp (EVar "Ok") (ETuple (EVar "input") (EVar "out") (EVar "target"))))
(DFunDef false "finishBuildArgs" (PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: medaka build takes exactly one input file"))))
(DTypeSig false "finishRunEval" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit")))))))
(DFunDef false "finishRunEval" ((PVar "target") (PVar "jsonMode") (PVar "elaborated") (PVar "mods")) (EBlock (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple PWild (PVar "edecls"))) () (EMatch (EApp (EVar "mainArityWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EMatch (EApp (EVar "mainNonUnitWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit)))))) (arm (PCon "None") () (EListLit)))) (DoLet false false PWild (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "mainWarns"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "currentEvalFile")) (EVar "target"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "runJsonMode")) (EVar "jsonMode"))) (DoExpr (EApp (EVar "putStr") (EApp (EApp (EVar "runProgramOutput") (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))))))
(DTypeSig false "runRunCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runRunCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoExpr (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka run [--release] [--json] <file.mdk>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") (PVar "progArgs")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "progArgsRef")) (EVar "progArgs"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "parseResult") (EApp (EVar "readFileSafe") (EVar "target"))) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EMethodRef "map") (EApp (EMethodRef "map") (EVar "dropModPath"))) (EApp (EApp (EApp (EVar "loadProgramFilesLocated") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots"))) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "stdlibTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoExpr (EMatch (EVar "modsD") (arm (PList PWild) () (EBlock (DoLet false false (PVar "tsrc") (EApp (EVar "readFileSafe") (EVar "target"))) (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EMethodRef "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EVar "elaborated")) (EVar "mods"))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target"))) (EVar "errs"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))) (arm PWild () (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneGF") (EVar "target")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EApp (EVar "hadTypeErrors") (ELit LUnit)) (arm (PCon "True") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "locatedOrGeneric") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "False") () (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EVar "elaborated")) (EVar "mods"))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "resDiags"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))))))))))))))))))))
(DTypeSig false "desugarPair" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugarPair" ((PTuple (PVar "mid") (PVar "p"))) (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "p"))))
(DTypeSig false "dropModPath" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "dropModPath" ((PTuple (PVar "mid") PWild (PVar "prog"))) (ETuple (EVar "mid") (EVar "prog")))
(DTypeSig false "runProgramOutput" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO" "Mut") None (TyCon "String")))))
(DFunDef false "runProgramOutput" ((PVar "preludeDecls") (PVar "modules")) (EMatch (EApp (EVar "mainTypeIsAsync") (ELit LUnit)) (arm (PCon "True") () (EApp (EApp (EVar "evalModulesOutputAsync") (EVar "preludeDecls")) (EVar "modules"))) (arm (PCon "False") () (EApp (EApp (EVar "evalModulesOutputRun") (EVar "preludeDecls")) (EVar "modules")))))
(DTypeSig false "runTestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runTestCmd" ((PVar "argv")) (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka test [file.mdk]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") PWild) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EVar "runTest") (EVar "rtPath")) (EVar "corePath")) (EVar "target")) (EVar "roots"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "exit") (ELit (LInt 1)))))))))
(DTypeSig false "runDocCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runDocCmd" ((PVar "argv")) (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka doc [file.mdk]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") PWild) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runDoc") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target"))))))))))))))
(DTypeSig false "runCheckPolicyCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runCheckPolicyCmd" ((PVar "argv")) (EMatch (EApp (EVar "parsePolicyArgs") (EVar "argv")) (arm (PCon "PolicyArgs" (PCon "None") PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "PolicyArgs" (PCon "Some" (PVar "target")) (PVar "allow") (PVar "fn")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "runCheckPolicy") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "allow")) (EVar "fn")) (arm (PCon "PolicyReject" (PVar "report")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "report"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "PolicyAccept" (PVar "header") (PVar "pluginFn") (PVar "coreD") (PVar "rtD") (PVar "userD")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "header"))) (DoExpr (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runAcceptedPlugin") (EVar "pluginFn")) (EVar "coreD")) (EVar "rtD")) (EVar "userD"))))))))))))))))))
(DTypeSig false "runManifestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runManifestCmd" ((PVar "argv")) (EMatch (EApp (EVar "parseManifestArgs") (EVar "argv")) (arm (PCon "ManifestArgs" (PCon "None") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka manifest <file.mdk> [--fn name]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "ManifestArgs" (PCon "Some" (PVar "target")) (PVar "fn")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runManifest") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "fn"))))))))))))))
(DTypeSig false "runLintCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runLintCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "disableNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--disable="))) (EVar "argv"))) (DoLet false false (PVar "onlyNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--only="))) (EVar "argv"))) (DoLet false false (PVar "denyNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--deny="))) (EVar "argv"))) (DoLet false false (PVar "fixMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--fix"))) (EVar "argv"))) (DoLet false false (PVar "fileArgs") (EApp (EVar "lintTargets") (EVar "argv"))) (DoLet false false (PVar "files") (EApp (EVar "resolveLintTargets") (EVar "fileArgs"))) (DoLet false false (PVar "multiFile") (EMatch (EVar "files") (arm (PCons PWild (PCons PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False")))) (DoLet false false (PVar "perFileErr") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "files")) (EVar "False"))) (DoLet false false (PVar "crossErr") (EIf (EBinOp "&&" (EVar "multiFile") (EApp (EVar "not") (EVar "fixMode"))) (EApp (EApp (EApp (EApp (EVar "runCrossFileReport") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "files")) (EVar "False"))) (DoExpr (EIf (EBinOp "||" (EVar "perFileErr") (EVar "crossErr")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))
(DTypeSig false "runCrossFileReport" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Bool")))))))
(DFunDef false "runCrossFileReport" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "files")) (EBlock (DoLet false false (PVar "triples") (EApp (EVar "parseLintFiles") (EVar "files"))) (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRules") (EVar "onlyNames")) (EVar "disableNames")) (EVar "triples"))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMulti") (EApp (EVar "readLintSrcs") (EVar "files"))) (EVar "raw"))) (DoLet false false (PVar "findings") (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed"))) (DoExpr (EMatch (EVar "findings") (arm (PList) () (EVar "False")) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "cross-file:")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "renderCrossFinding")) (EVar "findings"))))) (DoExpr (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")))))))))
(DTypeSig false "renderCrossFinding" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "renderCrossFinding" ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (ELit (LString ""))) (EApp (EVar "locFileOf") (EFieldAccess (EVar "f") "loc"))) (EApp (EVar "findingToDiag") (EVar "f"))))
(DTypeSig false "locFileOf" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locFileOf" ((PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild))) (EVar "file"))
(DFunDef false "locFileOf" ((PCon "None")) (ELit (LString "")))
(DTypeSig false "readLintSrcs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "readLintSrcs" ((PList)) (EListLit))
(DFunDef false "readLintSrcs" ((PCons (PVar "f") (PVar "rest"))) (EMatch (EApp (EVar "readFile") (EVar "f")) (arm (PCon "Err" PWild) () (EApp (EVar "readLintSrcs") (EVar "rest"))) (arm (PCon "Ok" (PVar "src")) () (EBinOp "::" (ETuple (EVar "f") (EVar "src")) (EApp (EVar "readLintSrcs") (EVar "rest"))))))
(DTypeSig false "parseLintFiles" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "parseLintFiles" ((PList)) (EListLit))
(DFunDef false "parseLintFiles" ((PCons (PVar "f") (PVar "rest"))) (EMatch (EApp (EVar "readFile") (EVar "f")) (arm (PCon "Err" PWild) () (EApp (EVar "parseLintFiles") (EVar "rest"))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoExpr (EBinOp "::" (ETuple (EVar "f") (EVar "pos") (EVar "decls")) (EApp (EVar "parseLintFiles") (EVar "rest"))))))))
(DTypeSig false "resolveLintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "resolveLintTargets" ((PList)) (EBlock (DoLet false false (PVar "cwd") (EApp (EVar "canonicalizePath") (ELit (LString ".")))) (DoLet false false (PVar "root") (EApp (EVar "findProjectRoot") (EVar "cwd"))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EBinOp "++" (EVar "root") (ELit (LString "/medaka.toml"))))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka lint: no medaka.toml found; run from a project directory or pass file/dir paths")))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EListLit))) (EApp (EVar "collectMdkFiles") (EVar "root"))))))
(DFunDef false "resolveLintTargets" ((PVar "targets")) (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets")))
(DTypeSig false "expandLintTarget" (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "expandLintTarget" ((PVar "target")) (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFiles") (EVar "target"))) (arm (PCon "Err" PWild) () (EListLit (EVar "target")))))
(DTypeSig false "lintPathJoin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "lintPathJoin" ((PVar "dir") (PVar "name")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "dir")) (EBinOp "++" (EVar "dir") (EVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))))
(DTypeSig false "collectMdkFiles" (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFiles" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: cannot list directory ")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EListLit)))) (arm (PCon "Ok" PWild) () (EApp (EVar "sortUniqS") (EApp (EVar "collectMdkFilesRec") (EVar "dir"))))))
(DTypeSig false "collectMdkFilesRec" (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFilesRec" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EApp (EVar "filterNonDot") (EVar "entries"))))))
(DTypeSig false "collectMdkEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntries" (PWild (PList)) (EListLit))
(DFunDef false "collectMdkEntries" ((PVar "dir") (PCons (PVar "name") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "collectMdkEntry") (EVar "dir")) (EVar "name")) (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EVar "rest"))))
(DTypeSig false "collectMdkEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntry" ((PVar "dir") (PVar "name")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "lintPathJoin") (EVar "dir")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFilesRec") (EVar "full"))) (arm (PCon "Err" PWild) () (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "name")) (EListLit (EVar "full")) (EListLit)))))))
(DTypeSig false "filterNonDot" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterNonDot" ((PList)) (EListLit))
(DFunDef false "filterNonDot" ((PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (EApp (EVar "filterNonDot") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "n") (EApp (EVar "filterNonDot") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lintFilesGo" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO" "Mut" "Panic") None (TyCon "Bool"))))))))))
(DFunDef false "lintFilesGo" (PWild PWild PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lintFilesGo" ((PVar "fixMode") (PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "hadErr") (EIf (EVar "fixMode") (EApp (EApp (EApp (EVar "lintOneFileFix") (EVar "onlyNames")) (EVar "disableNames")) (EVar "f")) (EApp (EApp (EApp (EApp (EApp (EVar "lintOneFileReport") (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "f")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr"))))))
(DTypeSig false "lintOneFileReport" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyCon "Bool"))))))))
(DFunDef false "lintOneFileReport" ((PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressions") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EVar "lintProgram") (EVar "allRules")) (EVar "target")) (EVar "src")) (EVar "pos")) (EVar "decls")))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "allFindings"))) (DoLet false false (PVar "output") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "target")) (EApp (EVar "findingToDiag") (EVar "f"))))) (EVar "findings")))) (DoLet false false (PVar "hasOutput") (EBinOp ">" (EApp (EVar "stringLength") (EVar "output")) (ELit (LInt 0)))) (DoLet false false PWild (EIf (EBinOp "&&" (EVar "multiFile") (EVar "hasOutput")) (EApp (EVar "putStrLn") (EBinOp "++" (EVar "target") (ELit (LString ":")))) (ELit LUnit))) (DoLet false false PWild (EIf (EVar "hasOutput") (EApp (EVar "putStrLn") (EVar "output")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")))))))
(DTypeSig false "lintOneFileFix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO" "Mut" "Panic") None (TyCon "Bool"))))))
(DFunDef false "lintOneFileFix" ((PVar "onlyNames") (PVar "disableNames") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PTuple (PVar "newSrc") (PVar "n")) (EApp (EApp (EApp (EApp (EApp (EVar "applyFixes") (EVar "onlyNames")) (EVar "disableNames")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoExpr (EIf (EBinOp "==" (EVar "newSrc") (EVar "src")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "fixed 0 finding(s) in ")) (EVar "target")))) (DoExpr (EVar "False"))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "target")) (EVar "newSrc")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 2)))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "fixed ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " finding(s) in "))) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ""))))) (DoExpr (EVar "False")))))))))))
(DTypeSig false "lintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "lintTargets" ((PList)) (EListLit))
(DFunDef false "lintTargets" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "x")) (EApp (EVar "lintTargets") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EVar "lintTargets") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "assertSnapshotTargetsExist" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "assertSnapshotTargetsExist" ((PVar "files")) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "f"))))) (EVar "files"))) (DoExpr (EIf (EBinOp "==" (EVar "missing") (EListLit)) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: these targets do not exist:")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (EVar "missing"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))
(DTypeSig false "runSnapshotCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runSnapshotCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "root") (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--root"))) (EVar "argv")) (arm (PCon "Some" (PVar "r")) () (EVar "r")) (arm (PCon "None") () (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))))) (DoLet false false (PVar "sel") (EApp (EVar "snapshotStages") (EVar "argv"))) (DoLet false false (PVar "files") (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EApp (EVar "snapshotTargets") (EVar "argv")))) (DoLet false false PWild (EApp (EVar "assertSnapshotTargetsExist") (EVar "files"))) (DoExpr (EIf (EBinOp "==" (EVar "files") (EListLit)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka snapshot [--check|--new] [--out <dir>] [--stages <a,b,…>] <paths...>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EIf (EApp (EApp (EVar "hasFlag") (ELit (LString "--worker"))) (EVar "argv")) (EApp (EApp (EApp (EVar "runSnapshotWorker") (EVar "root")) (EVar "sel")) (EVar "files")) (EBlock (DoLet false false (PVar "check") (EApp (EApp (EVar "hasFlag") (ELit (LString "--check"))) (EVar "argv"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "check")) (EApp (EVar "not") (EApp (EApp (EVar "hasFlag") (ELit (LString "--new"))) (EVar "argv")))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: pass --check (verify) or --new (create missing snapshots)")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EBlock (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSnapshotSupervisor") (EVar "root")) (EVar "check")) (EApp (EApp (EVar "hasFlag") (ELit (LString "--isolate"))) (EVar "argv"))) (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--out"))) (EVar "argv"))) (EVar "sel")) (EVar "files"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "exit") (ELit (LInt 1))))))))))))))
(DTypeSig false "snapshotStages" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Panic") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "snapshotStages" ((PVar "argv")) (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--stages"))) (EVar "argv")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "spec")) () (EMatch (EApp (EVar "parseStages") (EVar "spec")) (arm (PCon "Ok" (PVar "names")) () (EVar "names")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka snapshot: ")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EListLit))))))))
(DTypeSig false "snapshotTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "snapshotTargets" ((PList)) (EListLit))
(DFunDef false "snapshotTargets" ((PCons (PLit (LString "--out")) (PCons PWild (PVar "rest")))) (EApp (EVar "snapshotTargets") (EVar "rest")))
(DFunDef false "snapshotTargets" ((PCons (PLit (LString "--root")) (PCons PWild (PVar "rest")))) (EApp (EVar "snapshotTargets") (EVar "rest")))
(DFunDef false "snapshotTargets" ((PCons (PLit (LString "--stages")) (PCons PWild (PVar "rest")))) (EApp (EVar "snapshotTargets") (EVar "rest")))
(DFunDef false "snapshotTargets" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "x")) (EApp (EVar "snapshotTargets") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EVar "snapshotTargets") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "snapFlagValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "snapFlagValue" (PWild (PList)) (EVar "None"))
(DFunDef false "snapFlagValue" (PWild (PList PWild)) (EVar "None"))
(DFunDef false "snapFlagValue" ((PVar "name") (PCons (PVar "a") (PCons (PVar "v") (PVar "rest")))) (EIf (EBinOp "==" (EVar "a") (EVar "name")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "snapFlagValue") (EVar "name")) (EBinOp "::" (EVar "v") (EVar "rest")))))
(DTypeSig false "parseLintFlagList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "parseLintFlagList" ((PVar "prefix") (PList)) (EListLit))
(DFunDef false "parseLintFlagList" ((PVar "prefix") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "x")) (EApp (EVar "splitLintNames") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "x"))) (EVar "x"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseLintFlagList") (EVar "prefix")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "splitLintNames" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitLintNames" ((PVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EApp (EVar "stringToChars") (EVar "s"))) (EVar "s")) (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))))
(DTypeSig false "splitLintNamesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitLintNamesGo" ((PVar "chars") (PVar "s") (PVar "start") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "n")) (EVar "s"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar ","))) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "i")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EVar "chars")) (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EVar "chars")) (EVar "s")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "applyFindingFilters" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "applyFindingFilters" ((PVar "disable") (PVar "only") (PVar "deny") (PVar "findings")) (EBlock (DoLet false false (PVar "after1") (EApp (EApp (EVar "applyFindingOnly") (EVar "only")) (EVar "findings"))) (DoLet false false (PVar "after2") (EApp (EApp (EVar "applyFindingDisable") (EVar "disable")) (EVar "after1"))) (DoExpr (EApp (EApp (EVar "applyFindingDeny") (EVar "deny")) (EVar "after2")))))
(DTypeSig false "applyFindingOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingOnly" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingOnly" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingOnlyGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingOnlyGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingOnlyGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyFindingDisable" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingDisable" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingDisable" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingDisableGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingDisableGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingDisableGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyFindingDeny" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingDeny" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingDeny" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingDenyGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingDenyGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingDenyGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EBinOp "::" (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EVar "SevError")) (fa "loc" (EFieldAccess (EVar "f") "loc")))) (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isFindingError" (TyFun (TyCon "Finding") (TyCon "Bool")))
(DFunDef false "isFindingError" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "severity") (arm (PCon "SevError") () (EVar "True")) (arm (PCon "SevWarning") () (EVar "False"))))
(DTypeSig false "dirOf2" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOf2" ((PVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirGo2" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirGo2" ((PVar "path") (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirGo2" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "runReplCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runReplCmd" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "preludeDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false PWild (EApp (EApp (EVar "initSession") (EVar "runtimeDecls")) (EVar "preludeDecls"))) (DoExpr (EApp (EVar "replLoop") (ELit LUnit)))))))))))
(DTypeSig false "runLspCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO" "Mut" "Panic") None (TyCon "Unit"))))
(DFunDef false "runLspCmd" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EApp (EApp (EVar "runServer") (EVar "rsrc")) (EVar "csrc")))))))))
