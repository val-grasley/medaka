# META
source_lines=2340
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
import tools.snapshot.{
  runSnapshotWorker,
  runSnapshotSupervisor,
  parseStages,
  SnapMode(..),
}
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
  emitRtObj,
  emitPreludeObj,
  envOr,
  defaultMedakaRoot,
  readPreludeFile,
}
import support.util.{
  reverseL,
  joinNl,
  joinWith,
  splitNl,
  startsWith,
  endsWith,
  anyList,
  filterList,
  contains,
  sortUniqS,
  schemeLineName,
  stringTrim,
}
import support.ordmap.{OrdMap, omEmpty, omHasKey, omFromNames}
import support.path.{baseOf, chopExt, joinPath}
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
  resolveModulesToHumaneByPath,
}
import driver.loader.{
  LoadError,
  LoadMsg,
  LoadParseFailed,
  loadProgramE,
  loadProgramFilesLocatedE,
  findProjectRoot,
  entrySearchRoots,
  projectTrustedMods,
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
  checkJsonFile,
  readFileSafe,
  diagIsError,
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
import tools.mcp.{runMcpServer}
import tools.doc.{runDoc}
import tools.lint.{
  allRules,
  lintProgram,
  applySuppressions,
  applySuppressionsMulti,
  applySuppressionsDirs,
  applySuppressionsMultiDirs,
  collectDirectives,
  findingToDiag,
  Finding,
  Directive,
  applyFixes,
  runCrossFileRules,
  runCrossFileRulesFromOccs,
  crossFileCacheSound,
  fileDupOccs,
  parseLintFlagList,
  applyFindingFilters,
  applyFindingDeny,
  isFindingError,
  lintFileDiagTriple,
}
import tools.lint_cache.{
  LintEntry(..),
  contentHashOf,
  ruleSetStamp,
  cacheDirOf,
  loadEntry,
  storeEntries,
}
import tools.codemod.{
  findCodemod,
  codemodMk,
  codemodWarnDecls,
  codemodListing,
  codemodSource,
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

-- ── staleness guard (issue #89) ─────────────────────────────────────────────
-- A ./medaka built in tree Y but run against tree X's NEWER compiler sources
-- silently applies OLD compiler semantics (an old binary misreads `1.5e3` as
-- `Unbound variable: e3`), and the version string ("0.1.0-preview") never moves,
-- so it is useless as a staleness signal.  test/build_native_medaka.sh bakes the
-- compiler-source fingerprint into the binary (-DMEDAKA_SRC_FP, surfaced by the
-- `buildFingerprint` extern); here we recompute the SAME fingerprint over the
-- LIVE <root>/compiler and warn on a mismatch.  MEDAKA_STRICT=1 promotes the
-- warning to a hard error.  Runs on every invocation, so it is gated TIGHTLY:
-- only when a stamp was baked AND <root>/compiler is present (a shipped binary
-- has neither).
--
-- `liveSourceFingerprint` reproduces src_fingerprint() from the build script
-- byte-for-byte: names AND contents of `find compiler -name '*.mdk' | LC_ALL=C
-- sort`, hashed by the same hash_stream chain (sha256sum → shasum → cksum).  The
-- per-file `while read; cat` shell loop the script uses costs ~110ms (118 forks);
-- we stream through ONE perl process (~16ms, verified byte-identical).  perl
-- absent → the guard exits non-zero → None → the check silently skips (never a
-- false warning).
liveSourceFingerprint : String -> <IO> Option String
liveSourceFingerprint root =
  let script = stringConcat [
    "command -v perl >/dev/null 2>&1 || exit 7; cd \"",
    root,
    "\" && find compiler -name '*.mdk' -print | LC_ALL=C sort",
    " | perl -ne 'chomp; print \"$_\\n\"; open F,\"<\",$_ or next; local $/; my $c=<F>; print $c if defined $c; close F' 2>/dev/null",
    " | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; elif command -v shasum >/dev/null 2>&1; then shasum -a 256; else cksum; fi; }",
    " | cut -d' ' -f1",
  ]
  match runCommand "sh" ["-c", script]
    Ok (0, out, _) =>
      let h = stringTrim out
      if h == "" then None else Some h
    _ => None

checkSourceStaleness : Unit -> <IO> Unit
checkSourceStaleness _ =
  let baked = buildFingerprint ()
  if baked == "" then ()
  else
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let compilerDir = joinPath root "compiler"
    if not (fileExists compilerDir) then ()
    else match liveSourceFingerprint root
      None => ()
      Some live => if live == baked then ()
      else
        let msg = "warning: this ./medaka was built from compiler source that differs from " ++ compilerDir ++ " — it may be stale; rebuild with 'make medaka'."
        if envOr "MEDAKA_STRICT" "" != "" then
          let _ = ePutStrLn msg
          exit 1
        else ePutStrLn msg

main : <IO> Unit
main =
  let _ = checkSourceStaleness ()
  runCli ()

runCli : Unit -> <IO> Unit
runCli _ = match args ()
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
  "codemod"::rest => runCodemodCmd rest
  "check-policy"::rest => runCheckPolicyCmd rest
  "manifest"::rest => runManifestCmd rest
  "repl"::rest => runReplCmd rest
  "lsp"::rest => runLspCmd rest
  "mcp"::rest => runMcpCmd rest
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
    "  medaka build <file.mdk> [-o <out>] [--keep-ir]  Compile to a native binary (LLVM + clang)\n",
    "  medaka check [--json] <file.mdk>    Type-check without running\n",
    "  medaka test [file.mdk]    Run doctests + prop tests\n",
    "  medaka bench [file.mdk]   Run bench declarations\n",
    "  medaka doc [file.mdk]     Generate Markdown documentation\n",
    "  medaka lint [paths...]    Lint files/dirs (style rules; --fix, --cache, --disable/--only/--deny=<rules,...>)\n",
    "  medaka codemod <name> [flags] [paths...]  Apply a named source-preserving AST transform (--write/--stdout)\n",
    "  medaka snapshot [--check|--new|--bless] [paths...]  Per-stage snapshot tests (--out <dir>, --stages <a,b,..>)\n",
    "  medaka fmt [paths...]     Format .mdk files in place (or --check)\n",
    "  medaka new <name>         Scaffold a new project directory\n",
    "  medaka repl               Start an interactive REPL (reads stdin until EOF or :quit)\n",
    "  medaka lsp                Run the language server over stdio\n",
    "  medaka mcp                Run the MCP server over stdio (JSON-RPC for agents)\n",
    "  medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]  Check a plugin's inferred effects against an allow-list\n",
    "  medaka manifest <file.mdk> [--fn name]  Emit the verified capability manifest as TOML\n",
    "  medaka help               Show this message\n",
    "  medaka --version          Show the compiler version\n",
  ])

-- ── deferred subcommands ──────────────────────────────────────────────────
notYet : String -> <IO> Unit
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
runCheckCmd : List String -> <IO> Unit
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
      match readPreludeFile rtPath
        Err msg =>
          let _ = ePutStrLn msg
          exit 1
        Ok rsrc => match readPreludeFile corePath
          Err msg =>
            let _ = ePutStrLn msg
            exit 1
          Ok csrc => if jsonMode then runCheckJsonCmd allowInternal rsrc csrc target stdlibDir
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
              Ok _ => match loadProgramFilesLocatedE (_ => None) target roots
                Err lerr =>
                  let _ = ePutStrLn (moduleLoadErrText tsrc target stdlibDir lerr)
                  exit 1
                Ok modsWithPath =>
                  let mods = map dropModPath modsWithPath
                  let pathMap = map modIdToPath modsWithPath
                  let trusted = projectTrustedMods target roots stdlibDir mods
                  checkRoute typesMode allowInternal trusted pathMap roots rsrc csrc tsrc target mods
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
-- A parse/lex error inside an IMPORTED module (#100) renders exactly as though
-- that module had been checked directly: `ppParseError` against the module's OWN
-- source and path, so the file, line/col, caret and `P-*`/`L-*` code all name the
-- module that is actually broken rather than the entry that imported it.
moduleLoadErrText : String -> String -> String -> LoadError -> <IO> String
moduleLoadErrText _ _ _ (LoadParseFailed mpath msrc e) =
  ppParseError msrc mpath e
moduleLoadErrText tsrc target stdlibDir (LoadMsg lmsg) = match unknownModuleIdOf lmsg
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
locatedProjectErrors : String -> List String -> String -> String -> <IO> Option String
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
locatedOrGeneric : String -> List String -> String -> String -> <IO> String
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
checkRoute : Bool -> Bool -> List String -> List (String, String) -> List String -> String -> String -> String -> String -> List (String, List Decl) -> <IO> Unit
checkRoute typesMode allowInternal trusted _ _ rsrc csrc tsrc target [(mid, decls)] =
  -- BUGFIX (internal-extern noise on stdlib/compiler self-checks): the caller
  -- already computed `trusted` (projectTrustedMods, owning-root based) for
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
      let _ = putStrLn report
      -- 0.1.0 beginner-footgun warning (main-shape, see below): reuse the same
      -- elaborateModules the multi-module route calls just for mainSchemeRef —
      -- runCheck's own single-file path never populates it.
      let mainWarns = mainShapeWarnings (desugar (parse rsrc)) (desugar (parse csrc)) [(mid, desugar decls)] decls
      let _ = emitLocatedWarnings tsrc target (warns ++ mainWarns)
      ()
    _ =>
      let _ = ePutStrLn (joinNl (map (ppDiagCliSrc tsrc target) errs))
      exit 1
checkRoute typesMode allowInternal trusted pathMap roots rsrc csrc tsrc target mods =
  let rtD = desugar (parse rsrc)
  let coreD = desugar (parse csrc)
  let modsD = map desugarPair mods
  -- RESOLVE-phase errors (e.g. importing a name a module does not export —
  -- PrivateNameAccess) go to STDERR + exit 1, mirroring the single-file arm's
  -- channel discipline (errors→stderr).  Previously these were `putStr` to STDOUT
  -- unprefixed, so they were invisible to any errors-on-stderr consumer (the
  -- error-quality corpus captured them as empty).  The clean/type-error report
  -- still goes to STDOUT (the check_cli_modules gate expects TYPE ERROR there).
  -- #41: attribute each module's resolve errors to its OWN file (via `pathMap`),
  -- not a single `target` fallback that mislabels every imported-module error as
  -- the entry file.
  let resDiags = resolveModulesToHumaneByPath pathMap allowInternal trusted rtD coreD modsD
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
          let _ = putStrLn (runCheckModules allowInternal trusted rtD coreD modsD)
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
mainNonUnitWarning : List Decl -> Option Diag
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
mainShapeWarnings : List Decl -> List Decl -> List (String, List Decl) -> List Decl -> List Diag
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
-- The ENTRY's parse errors are detected FIRST via parseResult; an IMPORTED
-- module's are reported by the loader itself (#100), attributed to that module.
-- Output: {"files":[{"file":<path>,"diagnostics":[...]}]}
-- Exits 1 if any error diagnostic; 0 otherwise.
-- The whole routing (parse-error / load-error / single / multi module) now lives
-- in `checkJsonFile` (driver.diagnostics), shared with the `medaka mcp`
-- medaka_check tool.  This driver just prints the JSON and gates the exit code —
-- stdout is byte-identical to the old inline body (diff_native_cli golden).
runCheckJsonCmd : Bool -> String -> String -> String -> String -> <IO> Unit
runCheckJsonCmd allowInternal rsrc csrc target stdlibDir =
  let (json, hasErr) = checkJsonFile allowInternal rsrc csrc target stdlibDir
  let _ = println json
  if hasErr then exit 1 else ()

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

runFmtCmd : List String -> <IO> Unit
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
fmtManyTargets : FmtMode -> List String -> <IO> Unit
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
fmtFilesGo : FmtMode -> List String -> Bool -> <IO> Bool
fmtFilesGo _ [] acc = acc
fmtFilesGo mode (f::rest) acc =
  let hadErr = fmtOneReport mode f
  fmtFilesGo mode rest (acc || hadErr)

-- Like `fmtOne` but reports to stdout/stderr and RETURNS whether an error
-- occurred instead of exiting immediately, so `fmtFilesGo` can aggregate
-- across many files (the single-file path still calls `fmtOne` directly and
-- exits per its own original codes, unchanged).
fmtOneReport : FmtMode -> String -> <IO> Bool
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

fmtOne : FmtMode -> String -> <IO> Unit
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

-- ── codemod ────────────────────────────────────────────────────────────────
-- `medaka codemod <name> [codemod-flags] [--write|--stdout] <paths...>`.
--
-- Registry-driven (tools/codemod.mdk): the first arg names a codemod; the rest
-- splits into mode flags (--write/--stdout), the codemod's OWN value-taking flags
-- (any other `--flag value`, handed to the codemod's `mk`), and file/dir targets
-- (expanded by the SAME `expandLintTarget`/`collectMdkFiles` walk fmt/lint use).
--
-- Modes mirror `fmt`: default is a DRY-RUN that prints `would rewrite: <file>`
-- per changed file and exits 1 if any would change (0 otherwise), so idempotence
-- is a plain exit-code check; `--write` rewrites only files that actually change;
-- `--stdout` prints one file's result (original text if unchanged).  A bare
-- `medaka codemod` lists the registry and exits 2.
data CodeMode = CmDry | CmWrite | CmStdout

runCodemodCmd : List String -> <IO> Unit
runCodemodCmd [] = listCodemodsAndExit ()
runCodemodCmd (name::rest) = match findCodemod name
  None =>
    let _ = ePutStrLn "medaka codemod: unknown codemod '\{name}'"
    listCodemodsAndExit ()
  Some cm => match splitCodemodArgv rest CmDry [] []
    Err msg =>
      let _ = ePutStrLn msg
      exit 2
    Ok (mode, cargs, targets) => match codemodMk cm cargs
      Err msg =>
        let _ = ePutStrLn "medaka codemod \{name}: \{msg}"
        exit 2
      Ok xf =>
        let files = flatMap expandLintTarget targets
        match files
          [] =>
            let _ = ePutStrLn "medaka codemod: no .mdk files found"
            exit 2
          _ => match mode
            CmStdout => match files
              [one] => codemodStdout xf (codemodWarnDecls cm cargs) one
              _ =>
                let _ = ePutStrLn "medaka codemod: --stdout requires exactly one file"
                exit 2
            _ =>
              if codemodFilesGo mode xf (codemodWarnDecls cm cargs) files False then
                exit 1
              else
                ()

listCodemodsAndExit : Unit -> <IO> Unit
listCodemodsAndExit _ =
  let _ = putStrLn "Usage: medaka codemod <name> [flags] [--write|--stdout] <paths...>"
  let _ = putStrLn ""
  let _ = putStrLn "Available codemods:"
  let _ = putStrLn codemodListing
  exit 2

-- Split the post-name argv into (mode, codemod-flags, paths).  --write/--stdout
-- are consumed as modes; any other `--flag` is a codemod flag that consumes the
-- NEXT token as its value (the effect-labels convention: --strip <v>, --rename
-- <v>); everything else is a target path.
splitCodemodArgv : List String -> CodeMode -> List String -> List String -> Result String (CodeMode, List String, List String)
splitCodemodArgv [] mode cargs paths = Ok (mode, reverseL cargs, reverseL paths)
splitCodemodArgv ("--write"::rest) _ cargs paths =
  splitCodemodArgv rest CmWrite cargs paths
splitCodemodArgv ("--stdout"::rest) _ cargs paths =
  splitCodemodArgv rest CmStdout cargs paths
splitCodemodArgv (tok::rest) mode cargs paths =
  if startsWith "--" tok then match rest
    v::rest2 => splitCodemodArgv rest2 mode (v :: tok::cargs) paths
    [] => Err "medaka codemod: flag '\{tok}' requires a value"
  else splitCodemodArgv rest mode cargs (tok::paths)

-- --stdout for a single file: parse errors exit 1, otherwise print the rewritten
-- (or, if unchanged, the original) source.  Advisory warnings go to stderr.
codemodStdout : (Decl -> (Decl, Bool)) -> (List Decl -> List String) -> String -> <IO> Unit
codemodStdout xf warnFn file = match readFile file
  Err msg =>
    let _ = ePutStrLn "\{file}: \{msg}"
    exit 2
  Ok src => match codemodSource xf src
    Err e =>
      let _ = ePutStrLn (ppParseError src file e)
      exit 1
    Ok result =>
      let _ = emitCodemodWarns warnFn file src
      match result
        None => putStr src
        Some out => putStr out

-- Dry-run / --write fold over an expanded file list.  Returns whether the
-- process should exit 1: for dry-run that is "any file would change"; for
-- --write it is "any read/parse/write error" (a successful rewrite is exit 0).
codemodFilesGo : CodeMode -> (Decl -> (Decl, Bool)) -> (List Decl -> List String) -> List String -> Bool -> <IO> Bool
codemodFilesGo _ _ _ [] acc = acc
codemodFilesGo mode xf warnFn (f::rest) acc =
  let signal = codemodOneReport mode xf warnFn f
  codemodFilesGo mode xf warnFn rest (acc || signal)

codemodOneReport : CodeMode -> (Decl -> (Decl, Bool)) -> (List Decl -> List String) -> String -> <IO> Bool
codemodOneReport mode xf warnFn file = match readFile file
  Err msg =>
    let _ = ePutStrLn "\{file}: \{msg}"
    True
  Ok src => match codemodSource xf src
    Err e =>
      let _ = ePutStrLn (ppParseError src file e)
      True
    Ok result =>
      let _ = emitCodemodWarns warnFn file src
      match result
        None => False
        Some out => match mode
          CmWrite => match writeFile file out
            Err msg =>
              let _ = ePutStrLn "\{file}: \{msg}"
              True
            Ok _ => False
          _ =>
            let _ = putStrLn "would rewrite: \{file}"
            True

-- Emit a codemod's advisory warnings for one file to stderr.  Safe to reparse:
-- the caller only reaches here after `codemodSource` proved the source parses.
emitCodemodWarns : (List Decl -> List String) -> String -> String -> <IO> Unit
emitCodemodWarns warnFn file src =
  let (decls, _) = parseWithPositions src
  emitWarnLines file (warnFn decls)

emitWarnLines : String -> List String -> <IO> Unit
emitWarnLines _ [] = ()
emitWarnLines file (w::ws) =
  let _ = ePutStrLn "\{file}: warning: \{w}"
  emitWarnLines file ws

-- ── new ───────────────────────────────────────────────────────────────────
-- `medaka new <name>` scaffolds a project directory named after `name` — so
-- `name` must be validated BEFORE any filesystem write happens (#582). A
-- leading-dash arg is never a legal project name: `--help`/`-h` is help (print
-- usage, exit 0, no scaffolding), anything else starting with `-` is an
-- unrecognized option (error + usage to stderr, nonzero exit, no
-- scaffolding). Mirrors `runFmtCmd`'s "-"-prefix flag detection and
-- `buildUsage`'s subcommand-local `--help` handling.
newUsageLine : String
newUsageLine = "Usage: medaka new <name>"

runNewCmd : List String -> <IO> Unit
runNewCmd [arg] =
  if arg == "--help" || arg == "-h" then putStrLn newUsageLine
  else
    if stringLength arg > 0 && stringSlice 0 1 arg == "-" then
      let _ = ePutStrLn ("medaka new: unknown option '" ++ arg ++ "'")
      let _ = ePutStrLn newUsageLine
      exit 2
    else
      let code = newProject arg
      if code == 0 then () else exit code
runNewCmd _ =
  let _ = ePutStrLn newUsageLine
  exit 2

-- ── build ─────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `build` arm (Build_cmd.run) + build_main.mdk: parse
-- `<entry.mdk> [-o <out>]`, then drive build_cmd.runBuild (emit IR via a fresh
-- emitter subprocess → clang + C runtime + Boehm GC → native binary).  Paths
-- come from the environment (MEDAKA_ROOT/MEDAKA/CC) since compiler has no
-- getcwd/executable_name extern.  MEDAKA defaults to "./medaka" so a build with
-- no MEDAKA set re-invokes THIS native binary as the emitter host (no OCaml).
runBuildCmd : List String -> <IO> Unit
runBuildCmd argv =
  if hasFlag "--help" argv || hasFlag "-h" argv then buildUsage ()
  else match snapFlagValue "--emit-rt-obj" argv
    -- `medaka build --emit-rt-obj <path>`: precompile runtime/medaka_rt.c to a
    -- reusable object with EXACTLY the flags a normal link would apply, then exit.
    -- No input .mdk is required (or read) in this mode — it compiles only the C
    -- runtime.  A CI gate points MEDAKA_RT_OBJ at the result to skip the redundant
    -- per-build recompile of the identical runtime.
    Some objPath =>
      let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
      let cc = envOr "CC" "clang"
      match emitRtObj cc root objPath
        BuildOk msg => println msg
        BuildErr msg =>
          let _ = ePutStrLn msg
          exit 1
    None => match snapFlagValue "--emit-prelude-obj" argv
      -- `medaka build --emit-prelude-obj <path>`: precompile stdlib/core.mdk to a
      -- reusable object with EXACTLY the flags a normal link would apply, then exit
      -- (issue #118 — the same trick as --emit-rt-obj, one level up: the prelude is
      -- 88% of a small program's IR).  No input .mdk is required (or read) in this
      -- mode.  A CI gate points MEDAKA_PRELUDE_OBJ at the result to skip
      -- re-optimising the identical prelude on every subsequent build.
      Some objPath =>
        let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
        let cc = envOr "CC" "clang"
        let medaka = envOr "MEDAKA" "./medaka"
        match emitPreludeObj cc root medaka objPath
          BuildOk msg => println msg
          BuildErr msg =>
            let _ = ePutStrLn msg
            exit 1
      None => match parseBuildArgs argv
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
          let keepIrCli = hasFlag "--keep-ir" argv
          let outPath = match outOpt
            Some o => o
            None => defaultOutPath target input
          match typecheckGate allowInternal root inputAbs
            TGErr msg =>
              let _ = ePutStrLn msg
              exit 1
            TGOk => match runBuild root medaka cc target inputAbs outPath keepIrCli
              BuildOk msg => println msg
              BuildErr msg =>
                let _ = ePutStrLn msg
                exit 1

-- `medaka build --help` / `-h`: a subcommand-local usage, since the global
-- `usage()` (only matched when --help/-h is argv[0]) never sees this — dispatch
-- routes "build"::rest to runBuildCmd before the top-level --help arm gets a
-- chance.  Exists specifically so --keep-ir (and the other build-only flags)
-- are discoverable without reading the source.
buildUsage : Unit -> <IO> Unit
buildUsage _ = putStrLn (stringConcat
  [
    "usage: medaka build [--target native|wasm] <file.mdk> [-o <out>] [--keep-ir] [--allow-internal]\n",
    "\n",
    "  -o <out>          output path for the binary (default: <file> with its extension dropped)\n",
    "  --target <t>      backend: native (LLVM + clang, default) or wasm (WasmGC + wasm-tools)\n",
    "  --keep-ir         keep the emitted IR (.ll for native, .wat for wasm) at <out>.ll/.wat\n",
    "                    instead of discarding it with the build's scratch directory; the\n",
    "                    kept path is printed. Env var MEDAKA_KEEP_IR=1 does the same for a\n",
    "                    build invoked by something else (e.g. a test harness)\n",
    "  --allow-internal  permit internal-only externs outside stdlib/\n",
    "  --emit-rt-obj <p> compile only runtime/medaka_rt.c to a reusable object at <p> (with\n",
    "                    the same flags a normal link uses) and exit; point MEDAKA_RT_OBJ at\n",
    "                    it to skip recompiling the runtime on every subsequent build\n",
    "  --emit-prelude-obj <p>\n",
    "                    compile only stdlib/core.mdk to a reusable object at <p> (with the\n",
    "                    same flags a normal link uses) and exit; point MEDAKA_PRELUDE_OBJ at\n",
    "                    it to skip re-optimising the prelude on every subsequent build.\n",
    "                    Opt-in: separate objects cannot inline the prelude into user code\n",
  ])

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
typecheckGate : Bool -> String -> String -> <IO> TypecheckGate
typecheckGate allowInternal root input =
  let rtPath = root ++ "/stdlib/runtime.mdk"
  let corePath = root ++ "/stdlib/core.mdk"
  let stdlibDir = root ++ "/stdlib"
  let roots = entrySearchRoots (dirOf2 input) ++ [stdlibDir]
  match readPreludeFile rtPath
    Err msg => TGErr msg
    Ok rsrc => match readPreludeFile corePath
      Err msg => TGErr msg
      Ok csrc => match readFile input
        Err msg => TGErr msg
        -- PARSE-ERROR-LOCATION Stage 1: a located parse diagnostic for the ENTRY.
        -- An IMPORTED module's parse error is located by the loader itself (#100)
        -- and rendered by moduleLoadErrText.
        Ok tsrc => match parseResult tsrc
          Err e => TGErr (ppParseError tsrc input e)
          Ok _ => match loadProgramE input roots
            Err lerr => TGErr (moduleLoadErrText tsrc input stdlibDir lerr)
            Ok mods =>
              let trusted = projectTrustedMods input roots stdlibDir mods
              typecheckGateRoute allowInternal trusted roots rsrc csrc tsrc input mods

-- Route by module count.  A single loaded module (no non-core imports) runs the
-- ACCURATE located check `medaka check` uses for single files — analyzeLocatedG
-- (which runs checkImplObligations, the very pass the emit path skips and the one
-- that catches `"x" + 1`'s `No impl of Num for String`) — and renders BYTE-IDENTICAL
-- carat diagnostics via ppDiagCliSrc.  This is the case the G1 bug fixture exercises.
--
-- The MULTI-MODULE case gates on `locatedProjectErrors` — LITERALLY the predicate
-- `checkRoute`'s multi-module arm uses (analyzeProject), so `build`/`run` reject
-- exactly the graphs `check` rejects, by construction (bug #40).
--
-- WHY THE OLD PREDICATE WAS UNSOUND (and could not be patched in place).  It was
-- `resolve diagnostics + elaborateModules + hadTypeErrors`.  But `elaborateModules`
-- sets `implInferEnabled := True`, and typecheck.mdk gates `checkImplObligations`
-- (the pass that raises `No impl of Display for Foo`) behind `if not
-- implInferEnabled.value`.  So the emit/eval elaboration STRUCTURALLY CANNOT record
-- a constraint / missing-impl error: `hadTypeErrors` stayed False and multi-module
-- `run` EXECUTED the ill-typed program, dying later on an unrelated runtime panic
-- (`intToString: not an Int`).  A plain unification `Type mismatch` DID set the
-- sticky flag, which is exactly why the hole hid for so long — probing with a type
-- mismatch shows correct behaviour.  Single-file `run`/`build` were never affected:
-- their arm already gates on `analyzeLocatedG`, which runs with implInferEnabled OFF.
--
-- WHY THIS DOES NOT OVER-REJECT.  The historical fear (recorded here as "the
-- multi-module obligation check flags the compiler's own source with a spurious
-- `No impl of Alternative for Parser`") named a predicate that no longer exists, and
-- the false positive it described was fixed by checkModuleFullDiags's `accAll` seed
-- (typecheck.mdk "Bug C": without the imported-standalone-shadow universe, `toList m`
-- routed to method dispatch → spurious `No impl of Foldable for Map`).  The proof that
-- analyzeProject is clean on compiler source is a REQUIRED CI check:
-- test/typecheck_compiler_source.sh runs exactly this driver over
-- compiler/driver/medaka_cli.mdk's whole import closure and fails on ANY
-- error-severity diagnostic.  So gating the oracle builds on it is safe.
--
-- The elaborate + hadTypeErrors gate is KEPT behind it as belt-and-braces (it is the
-- emit path's own view, and it is not a superset of nothing — a diagnostic only the
-- emit elaboration can see still aborts before the emitter).
typecheckGateRoute : Bool -> List String -> List String -> String -> String -> String -> String -> List (String, List Decl) -> <IO> TypecheckGate
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
    "" => match locatedProjectErrors target roots rsrc csrc
      -- CHECK-STRENGTH gate: the located per-module diagnostics, identical to what
      -- `medaka check` prints and to what `--json` reports.
      Some errText => TGErr errText
      None =>
        let _ = resetTypeErrorsSticky ()
        let _ = elaborateModules rtD coreD modsD
        match hadTypeErrors ()
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
-- --keep-ir: read separately via hasFlag in runBuildCmd (same convention as
-- --allow-internal above) — just strip it here so it doesn't fall through to
-- finishBuildArgs and get mistaken for the input file.
parseBuildGo ("--keep-ir"::rest) acc out target =
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
finishRunEval : String -> Bool -> (List Decl, List (String, List Decl)) -> List (String, List Decl) -> <IO> Unit
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

runRunCmd : List String -> <IO> Unit
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
      match readPreludeFile rtPath
        Err msg =>
          let _ = ePutStrLn msg
          exit 1
        Ok rsrc => match readPreludeFile corePath
          Err msg =>
            let _ = ePutStrLn msg
            exit 1
          -- Parse the user modules with parseLocated (real ELoc spans) so a
          -- runtime error (E-*) can report a correct file:L:C.  Plain loadProgram
          -- uses placeholder-loc `parse`, which collapses every span to 1:0.
          -- Structurally identical decls → eval output byte-identical.
          -- PARSE-ERROR-LOCATION Stage 1: surface a located parse error on the
          -- ENTRY file.  An IMPORTED module's parse error is located by the loader
          -- itself (#100) and rendered by moduleLoadErrText, so neither one is a
          -- bare `parse error` panic any more.  Error-path only; valid input is
          -- unaffected.
          Ok csrc => match parseResult (readFileSafe target)
            Err e =>
              let _ = ePutStrLn (ppParseError (readFileSafe target) target e)
              exit 1
            Ok _ => match map (map dropModPath) (loadProgramFilesLocatedE (_ => None) target roots)
              Err lerr =>
                let _ = ePutStrLn (moduleLoadErrText (readFileSafe target) target stdlibDir lerr)
                exit 1
              Ok mods =>
                let rtD = desugar (parse rsrc)
                let coreD = desugar (parse csrc)
                let modsD = map desugarPair mods
                let trusted = projectTrustedMods target roots stdlibDir mods
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
                    -- Multi-module: gate on `locatedProjectErrors` — the SAME
                    -- analyzeProject predicate `checkRoute`'s multi-module arm uses —
                    -- so `run` rejects exactly the graphs `check` rejects (bug #40).
                    --
                    -- The old gate here was resolve + elaborateModules +
                    -- hadTypeErrors, which is BLIND to constraint / missing-impl
                    -- errors: elaborateModules sets implInferEnabled, and typecheck
                    -- skips checkImplObligations under it.  So multi-module `run`
                    -- EXECUTED an ill-typed program (`println "\{Foo 1}"` with no
                    -- Display impl) and died on an unrelated `intToString: not an Int`
                    -- panic, while `check` on the same program printed the real
                    -- located `No impl of Display for Foo`.  See typecheckGateRoute
                    -- for why this is not an over-rejection.
                    let resDiags = resolveModulesToHumaneGF target allowInternal trusted rtD coreD modsD
                    match resDiags
                      "" => match locatedProjectErrors target roots rsrc csrc
                        Some errText =>
                          let _ = ePutStrLn errText
                          exit 1
                        None =>
                          let _ = resetTypeErrorsSticky ()
                          let elaborated = elaborateModules rtD coreD modsD
                          match hadTypeErrors ()
                            True =>
                              -- Belt-and-braces: anything only the emit/eval
                              -- elaboration can see still aborts before eval.
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

-- (modId, path, decls) → (modId, path): the per-module file map threaded into the
-- multi-module resolve renderer so an imported module's diagnostics report ITS
-- own path, not the entry's (#41).
modIdToPath : (String, String, List Decl) -> (String, String)
modIdToPath (mid, path, _) = (mid, path)

-- ASYNC-DESIGN Stage 2 (D5): route a `main : Async _` through the program's
-- `runAsync` (perform its stored row) instead of forcing it to an inert Async
-- value; a plain `main` keeps the ordinary force-for-effect path.  mainTypeIsAsync
-- reads the scheme elaborateModules just stashed, so this must run post-elaborate.
-- B2 (RUN-EFFECTS): the plain path is evalModulesOutputRun — evalModulesOutput
-- plus the real-I/O externs (File/Env/Stdin/Stderr/Clock), hence the `IO` row.
runProgramOutput : List Decl -> List (String, List Decl) -> <IO> String
runProgramOutput preludeDecls modules = match mainTypeIsAsync ()
  True => evalModulesOutputAsync preludeDecls modules
  False => evalModulesOutputRun preludeDecls modules

-- ── test ──────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `test` arm + test_main.mdk: read <MEDAKA_ROOT>/stdlib/
-- {runtime,core}.mdk, then drive test_cmd.runTest (doctests + prop tests).
-- runTest reads the three sources itself and prints the report in-band; since
-- P0-212 a read error (prelude OR target) makes runTest return False (a file
-- that can't even be opened is a FAILURE, not a vacuous pass — only a file
-- that parses clean with zero doctests/props is vacuously True).  Roots mirror
-- run: the entry's dir (user modules shadow stdlib) then MEDAKA_ROOT/stdlib.
--
-- Target resolution (#82 row 2): mirrors `medaka lint`/`medaka fmt` — a single
-- literal-file arg keeps the EXACT original single-file path (byte-for-byte,
-- same `runTest` call), so this is backward-compatible.  A directory arg, a
-- `medaka.toml` project dir, or multiple args are expanded via the SAME
-- `expandLintTarget`/`collectMdkFiles` walk lint/fmt use, and every resolved
-- `.mdk` file is tested in turn, aggregating: exit nonzero iff ANY file's
-- tests failed OR couldn't be read (this is also what makes the #212 exit-0
-- bug go away for the directory/project route, not just the single-file one).
runTestCmd : List String -> <IO> Unit
runTestCmd argv = match dropFlags argv
  [] =>
    let _ = ePutStrLn "usage: medaka test [file.mdk | dir]"
    exit 1
  [target] => match listDir target
    Err _ => runTestOne target
    Ok _ => runTestManyTargets [target]
  targets => runTestManyTargets targets

-- Original single-file path, unchanged: read <MEDAKA_ROOT>/stdlib sources,
-- build search roots, run `runTest`, exit 1 on any failure/read-error.
runTestOne : String -> <IO> Unit
runTestOne target =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let rtPath = root ++ "/stdlib/runtime.mdk"
  let corePath = root ++ "/stdlib/core.mdk"
  let stdlibDir = root ++ "/stdlib"
  let roots = entrySearchRoots (dirOf2 target) ++ [stdlibDir]
  let ok = runTest rtPath corePath target roots
  if ok then () else exit 1

-- Directory/project/multi-target path: expand every target to concrete .mdk
-- files (SAME walk as lint/fmt), then run+aggregate. An empty resolved set
-- (empty dir, or a dir with no .mdk files) is reported and left at exit 0 —
-- "nothing to test" is not a failure, mirroring runTest's own vacuous-pass
-- convention for a single zero-doctest file.
runTestManyTargets : List String -> <IO> Unit
runTestManyTargets targets =
  let files = flatMap expandLintTarget targets
  match files
    [] =>
      let _ = putStrLn "medaka test: no .mdk files found"
      ()
    _ =>
      let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
      let rtPath = root ++ "/stdlib/runtime.mdk"
      let corePath = root ++ "/stdlib/core.mdk"
      let stdlibDir = root ++ "/stdlib"
      if testFilesGo rtPath corePath stdlibDir files False then exit 1 else ()

-- Fold `runTest` over an expanded file list, aggregating whether ANY file
-- failed (tests failed, or the file itself couldn't be read/parsed).
testFilesGo : String -> String -> String -> List String -> Bool -> <IO> Bool
testFilesGo _ _ _ [] acc = acc
testFilesGo rtPath corePath stdlibDir (f::rest) acc =
  let roots = entrySearchRoots (dirOf2 f) ++ [stdlibDir]
  let ok = runTest rtPath corePath f roots
  testFilesGo rtPath corePath stdlibDir rest (acc || not ok)

-- ── doc ───────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `doc` arm + lib/doc.ml: read the target file, parse
-- (capturing decl positions + comments), typecheck a desugared copy through the
-- single-file path for inferred schemes, extract PUBLIC-decl doc entries, and
-- print Markdown to stdout.  Single-file only (OCaml `doc` is single-file too).
-- Prelude sources (runtime.mdk/core.mdk) come from MEDAKA_ROOT for scheme
-- inference, exactly as check/run/test do.
runDocCmd : List String -> <IO> Unit
runDocCmd argv = match dropFlags argv
  [] =>
    let _ = ePutStrLn "usage: medaka doc [file.mdk]"
    exit 1
  target::_ =>
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let rtPath = root ++ "/stdlib/runtime.mdk"
    let corePath = root ++ "/stdlib/core.mdk"
    match readPreludeFile rtPath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok rsrc => match readPreludeFile corePath
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
runCheckPolicyCmd : List String -> <IO> Unit
runCheckPolicyCmd argv = match parsePolicyArgs argv
  PolicyArgs None _ _ =>
    let _ = ePutStrLn "usage: medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]"
    exit 1
  PolicyArgs (Some target) allow fn =>
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let rtPath = root ++ "/stdlib/runtime.mdk"
    let corePath = root ++ "/stdlib/core.mdk"
    match readPreludeFile rtPath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok rsrc => match readPreludeFile corePath
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
-- row, and prints:
--
--   [package.capabilities]
--   Net = "idp.example.com/api"
--   Stdout = true
--
-- Every effect label is a host capability, so the whole verified row is emitted.
-- Labels sorted ascending (stable output).  Prefix-param → string TOML value;
-- ⊤/Unit param → boolean `true`.
--
-- WS-1c (deferred): Wasm custom section embedding (see
-- compiler/tools/check_policy.mdk comment + EFFECTS-SEMANTICS.md §7).
runManifestCmd : List String -> <IO> Unit
runManifestCmd argv = match parseManifestArgs argv
  ManifestArgs None _ =>
    let _ = ePutStrLn "usage: medaka manifest <file.mdk> [--fn name]"
    exit 1
  ManifestArgs (Some target) fn =>
    let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
    let rtPath = root ++ "/stdlib/runtime.mdk"
    let corePath = root ++ "/stdlib/core.mdk"
    match readPreludeFile rtPath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok rsrc => match readPreludeFile corePath
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
--   --json               emit the {"files":[...]} structured-diagnostics
--                        envelope (same schema as `check --json`) instead of
--                        human text; --fix is ignored in this mode (#249,
--                        report-only — autofix is out of scope)
--   --cache              reuse per-file results for files whose CONTENT is
--                        unchanged (#395; opt-in, like ESLint's --cache).  See
--                        `lintCacheCtx` for the exact scope and the two ways it
--                        declines.  Output is byte-identical to a run without it
--                        — test/diff_compiler_lint_cache.sh is the gate.
--   --disable=r1,r2,...  suppress findings from the named rules
--   --only=r1,...        keep only findings from the named rules
--   --deny=r1,...        promote findings from the named rules to SevError
-- Target resolution:
--   ≥1 explicit file args   → lint each in order
--   single directory arg    → lint all top-level .mdk files in that dir (sorted)
--   no file arg             → find medaka.toml project root, lint top-level .mdk files
--     (note: top-level only — subdirectory .mdk files are not walked recursively)
-- Exit 0 unless a SevError finding exists (only via --deny in v1 report mode).
runLintCmd : List String -> <IO> Unit
runLintCmd argv =
  let disableNames = parseLintFlagList "--disable=" argv
  let onlyNames = parseLintFlagList "--only=" argv
  let denyNames = parseLintFlagList "--deny=" argv
  let fixMode = hasFlag "--fix" argv
  let jsonMode = hasFlag "--json" argv
  let fileArgs = lintTargets argv
  let files = resolveLintTargets fileArgs
  if jsonMode then runLintJsonCmd disableNames onlyNames denyNames files
  else
    let multiFile = match files
      (_::_::_) => True
      _ => False
    let cacheCtx = lintCacheCtx (hasFlag "--cache" argv) fixMode
    -- `parsed` carries each readable target's (path, src, Positions, decls) out of
    -- the per-file pass so the cross-file tier reuses them instead of re-reading
    -- and re-parsing every file (#394).  It is EMPTY under --cache, where a hit
    -- has no parse to hand on — that path reaches the cross-file tier through the
    -- entries' cached occurrences instead (see runCrossFileReportCached).
    let (perFileErr, entries, parsed) =
      lintFilesGo fixMode multiFile disableNames onlyNames denyNames cacheCtx files False
    -- Cross-file rules only run in the multi-file REPORT path; a single target or
    -- --fix produces nothing (need ≥2 files), keeping single-file output identical.
    let crossErr =
      if not (multiFile && not fixMode) then False
      else match cacheCtx
        Some _ => runCrossFileReportCached disableNames onlyNames denyNames entries
        None => runCrossFileReport disableNames onlyNames denyNames parsed
    -- Persist AFTER reporting: the cache is an optimisation, so a failure to
    -- write one must never change what a run says or whether it exits 0.
    let _ = match cacheCtx
      Some (cacheDir, stamp) => storeEntries cacheDir stamp entries
      None => ()
    if perFileErr || crossErr then exit 1 else ()

-- Resolve `--cache` to `Some (cacheDir, ruleSetStamp)`, or `None` to run
-- uncached.  TWO reasons this declines, both deliberate (#395):
--
--   * `--fix` (and `--json`, which never reaches here) is out of v1 scope. --fix
--     REWRITES the files whose content is the cache key, and ESLint's
--     --cache+--fix is a known sharp edge; --json is a separate per-file path.
--     Combining --cache with either is a silent no-op, not an error.
--   * `crossFileCacheSound` is False — someone added a second cross-file rule,
--     whose per-file inputs nothing caches.  Under --cache that rule would
--     SILENTLY NOT RUN.  So --cache turns itself off instead, costing a slower
--     lint rather than a wrong one.  (No warning: this is a correct, quiet
--     fallback, and a lint that prints compiler-internal chatter to stdout would
--     break every caller that diffs its output.)
--
-- The cache dir hangs off the project root — the same `medaka.toml` walk-up the
-- rest of the CLI uses, which falls back to the cwd when there is no manifest
-- (the repo root case: `medaka lint compiler stdlib sqlite` runs where no
-- medaka.toml sits, and lands the cache at the repo root, which is what the
-- pre-commit hook wants).  A cache dir that resolves somewhere unexpected costs
-- misses, never wrong answers.
lintCacheCtx : Bool -> Bool -> <IO> Option (String, String)
lintCacheCtx False _ = None
lintCacheCtx True True = None
lintCacheCtx True False
  | not crossFileCacheSound = None
  | otherwise =
    let root = findProjectRoot (canonicalizePath ".")
    let stamp = ruleSetStamp ()
    -- An empty stamp means the binary could not be read, so the rule set cannot
    -- be identified — the one input that makes a hit meaningful is missing.
    -- Decline rather than share a cache across unknown rule sets.
    if stamp == "" then None else Some (cacheDirOf root, stamp)

-- `medaka lint --json`: run the lint pipeline over every resolved target file
-- and emit the SAME `{"files":[{"file":...,"diagnostics":[...]}]}` envelope
-- `medaka check --json` emits (via `cjAllToJson`) — one schema for both
-- surfaces (#249).  Each `Finding` becomes a `Diag` via `findingToDiag`
-- (inside `lintFileDiagTriple`), which stamps the lint RULE NAME into the
-- diagnostic's `code` field.  Cross-file rules do not participate (JSON mode
-- is per-file, mirroring `check --json`'s own per-file shape); `--fix` is
-- ignored here.  Exit 1 iff any diagnostic is a hard error (severity 1) —
-- matches `runCheckJsonCmd`'s convention.
runLintJsonCmd : List String -> List String -> List String -> List String -> <IO> Unit
runLintJsonCmd disableNames onlyNames denyNames files =
  let triples = lintFilesToDiagTriples disableNames onlyNames denyNames files
  let _ = putStr (cjAllToJson triples)
  if anyList cjLintTripleHasErr triples then exit 1 else ()

-- Sequence `lintFileDiagTriple` over every target file, in order.  Mirrors
-- `lintFilesGo`'s explicit recursion — this codebase sequences an `<IO>`
-- list traversal by hand, not via `map` over an effectful function.
lintFilesToDiagTriples : List String -> List String -> List String -> List String -> <IO> List (String, String, List Diag)
lintFilesToDiagTriples _ _ _ [] = []
lintFilesToDiagTriples disable only deny (f::rest) =
  lintFileDiagTriple disable only deny f ::
    lintFilesToDiagTriples disable only deny rest

cjLintTripleHasErr : (String, String, List Diag) -> Bool
cjLintTripleHasErr (_, _, diags) = anyList diagIsError diags

-- Run the cross-file rule tier over the whole set, REUSING the parses the per-file
-- pass already produced (#394 — this used to call `parseLintFiles`, re-reading and
-- re-parsing every target, plus `readLintSrcs` for a third read of the same bytes).
-- Findings render AFTER the per-file output under a `cross-file:` header.
-- --only/--disable are honored inside `runCrossFileRules`; --deny promotion is
-- applied here (mirrors the per-file path).  Returns whether any finding is an
-- error severity (feeds the exit code).
runCrossFileReport : List String -> List String -> List String -> List (String, String, Positions, List Decl) -> <IO> Bool
runCrossFileReport disableNames onlyNames denyNames parsed =
  let triples = map parsedToTriple parsed
  let raw = runCrossFileRules onlyNames disableNames triples
  -- Honor inline `-- lint-disable-*` directives on cross-file findings too:
  -- each finding anchors to its own file, so filter against that file's own
  -- directives (recovered from its source) before the CLI flag filters.
  let suppressed = applySuppressionsMulti (map parsedToSrc parsed) raw
  reportCrossFindings (applyFindingDeny denyNames suppressed)

-- The --cache counterpart of `runCrossFileReport` (#395).  Identical in every
-- observable way; the ONLY difference is its input, because a cache hit has no
-- parse to give the tier:
--   * findings come from `runCrossFileRulesFromOccs` over every file's
--     occurrences — cached ones and freshly-computed ones alike — instead of
--     from `runCrossFileRules` over parses.  Both run the SAME `dupJoin`.
--   * directives are the entries' own (already parsed, cached or fresh) rather
--     than re-lexed from source.
--
-- ⚠️ THE JOIN RUNS EVERY TIME, over ALL files.  Only its per-file INPUTS are
-- cached.  A duplicate-body finding names file A because of file B, so caching
-- these findings would leave A's finding standing after B stopped duplicating
-- it — A is unchanged, so A hits.  Scenario 3 of
-- test/diff_compiler_lint_cache.sh is exactly that edit and exists to catch
-- anyone who tries it.  Callers must have checked `crossFileCacheSound`
-- (`lintCacheCtx` does).
runCrossFileReportCached : List String -> List String -> List String -> List LintEntry -> <IO> Bool
runCrossFileReportCached disableNames onlyNames denyNames entries =
  let raw = runCrossFileRulesFromOccs onlyNames disableNames (flatMap entryOccs entries)
  let suppressed = applySuppressionsMultiDirs (map entryDirTable entries) raw
  reportCrossFindings (applyFindingDeny denyNames suppressed)

entryOccs : LintEntry -> List (String, Int, String, String)
entryOccs e = e.dupOccs

entryDirTable : LintEntry -> (String, List Directive)
entryDirTable e = (e.path, e.directives)

-- Shared tail of both cross-file report paths: render (after the per-file
-- output, under a `cross-file:` header) and report whether anything was an
-- error.  One renderer, so the cached and uncached paths cannot format
-- differently.
reportCrossFindings : List Finding -> <IO> Bool
reportCrossFindings [] = False
reportCrossFindings findings =
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
-- Projections off the threaded (path, src, Positions, decls) quad (#394): the
-- cross-file rule tier wants (path, Positions, decls), and the inline-directive
-- suppression pass wants (path, src).  Both used to be re-derived from disk by
-- `parseLintFiles` / `readLintSrcs`, which this replaces.
parsedToTriple : (String, String, Positions, List Decl) -> (String, Positions, List Decl)
parsedToTriple (path, _, pos, decls) = (path, pos, decls)

parsedToSrc : (String, String, Positions, List Decl) -> (String, String)
parsedToSrc (path, src, _, _) = (path, src)

-- Resolve file args to a concrete list of .mdk paths.
-- Empty args → project root mode (find medaka.toml, list top-level .mdk files).
-- Each non-empty arg is expanded individually: a path listDir succeeds on is
-- treated as a directory (recursively collected); else it's kept as a literal
-- file path. This applies uniformly whether one or many targets are given, so
-- `medaka lint dirA dirB` expands BOTH dirs (not just the first).
resolveLintTargets : List String -> <IO> List String
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
expandLintTarget : String -> <IO> List String
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
collectMdkFiles : String -> <IO> List String
collectMdkFiles dir = match listDir dir
  Err msg =>
    let _ = ePutStrLn "medaka lint: cannot list directory \{dir}: \{msg}"
    []
  Ok _ => sortUniqS (collectMdkFilesRec dir)

collectMdkFilesRec : String -> <IO> List String
collectMdkFilesRec dir = match listDir dir
  Err _ => []
  Ok entries => collectMdkEntries dir (filterNonDot entries)

collectMdkEntries : String -> List String -> <IO> List String
collectMdkEntries _ [] = []
collectMdkEntries dir (name::rest) = collectMdkEntry dir name
  ++ collectMdkEntries dir rest

-- One entry: a listable path is a subdirectory (recurse); otherwise a file,
-- kept iff it ends in `.mdk`.  Mirrors the dir/file discriminator used elsewhere
-- (listDir Ok = dir, Err = file).
collectMdkEntry : String -> String -> <IO> List String
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
-- Returns (anyError, entries, parsedFiles).
--
-- `entries` is every readable target's LintEntry — the per-file lint result
-- (findings + duplicate-body occurrences + inline directives), however obtained.
-- Under --cache these are what gets persisted, and the dirty ones are the files
-- that actually had to be linted this run.
--
-- `parsedFiles` is threaded to the cross-file tier so it need not re-read/re-parse
-- the same targets (#394); it is empty in --fix mode, which runs no cross-file
-- rules, and empty under --cache, where a cache HIT has no parse to hand on and
-- the tier is reached from `entries` instead.  Not accumulating it under --cache
-- is also why a warm run holds no decls in memory.
--
-- The per-file printing order is unchanged: each file's report is emitted
-- (strictly) before the recursion.
lintFilesGo : Bool -> Bool -> List String -> List String -> List String -> Option (String, String) -> List String -> Bool -> <IO> (Bool, List LintEntry, List (String, String, Positions, List Decl))
lintFilesGo _ _ _ _ _ _ [] acc = (acc, [], [])
lintFilesGo fixMode multiFile disableNames onlyNames denyNames cacheCtx (f::rest) acc =
  if fixMode then
    let hadErr = lintOneFileFix onlyNames disableNames f
    lintFilesGo
      fixMode
      multiFile
      disableNames
      onlyNames
      denyNames
      cacheCtx
      rest
      (acc || hadErr)
  else
    let (hadErr, entries, parsed) = lintOneFileReport multiFile disableNames onlyNames denyNames cacheCtx f
    let (restErr, restEntries, restParsed) = lintFilesGo fixMode multiFile disableNames onlyNames denyNames cacheCtx rest (acc || hadErr)
    (restErr, entries ++ restEntries, parsed ++ restParsed)

-- Lint a single file in report mode.
-- multiFile=False: output is byte-for-byte identical to single-file v1 behavior.
-- multiFile=True: prints "path:" header before findings (only when there are findings).
-- Returns (hadError, parsed) where `parsed` is a 0-or-1 element list carrying this
-- file's (path, src, Positions, decls) for the cross-file tier to REUSE — empty
-- when the file could not be read (mirroring the old parseLintFiles/readLintSrcs
-- skip-unreadable behavior).  Handing the parse out rather than letting the
-- cross-file tier redo it is issue #394: the tier used to `parseLintFiles` (a full
-- re-read + re-parse of every target, 11.4% of a whole-tree lint's runtime) AND
-- `readLintSrcs` (a THIRD read of the same bytes) after this pass had already read
-- and parsed each file. Memory-neutral: runCrossFileReport already materialised
-- every triple at once.
lintOneFileReport : Bool -> List String -> List String -> List String -> Option (String, String) -> String -> <IO> (Bool, List LintEntry, List (String, String, Positions, List Decl))
lintOneFileReport multiFile disableNames onlyNames denyNames cacheCtx target = match readFile target
  Err msg =>
    let _ = ePutStrLn msg
    (True, [], [])
  Ok src =>
    let (entry, parsed) = lintEntryOf cacheCtx target src
    -- Suppress findings silenced by inline `-- lint-disable-*` directives before
    -- applying the CLI flag filters (--only/--disable/--deny).  Both the cached
    -- and uncached paths render from THIS one expression over the entry, so a
    -- hit and a miss cannot print different things: the only difference between
    -- them is where `entry` came from.
    let allFindings = applySuppressionsDirs entry.directives entry.findings
    let findings = applyFindingFilters disableNames onlyNames denyNames allFindings
    let output = joinNl (map (f => ppDiagCliSrc src target (findingToDiag f)) findings)
    let hasOutput = stringLength output > 0
    let _ = if multiFile && hasOutput then putStrLn (target ++ ":") else ()
    let _ = if hasOutput then putStrLn output else ()
    (anyList isFindingError findings, [entry], parsed)

-- One file's lint result, from the cache when it can be trusted and from a real
-- parse otherwise.  Also returns the parse for the #394 cross-file reuse — empty
-- on a cache hit (there is no parse) and, deliberately, empty whenever the cache
-- is on at all, since that path does not consume it.
--
-- The `--cache` decision, in full: a HIT requires the shard to decode, and to
-- agree on the format version, the rule-set stamp, the path, AND the content
-- hash.  Anything else is a miss.  `lint_cache.decodeEntry` owns that check;
-- this function only decides when to ask.
lintEntryOf : Option (String, String) -> String -> String -> <IO> (LintEntry, List (String, String, Positions, List Decl))
lintEntryOf None target src =
  let (entry, pos, decls) = lintFileFresh target src "" False
  (entry, [(target, src, pos, decls)])
lintEntryOf (Some (cacheDir, stamp)) target src =
  let hash = contentHashOf src
  match loadEntry cacheDir stamp target hash
    Some hit => (hit, [])
    None =>
      let (entry, _, _) = lintFileFresh target src hash True
      (entry, [])

-- Parse and lint a file for real: the miss path, and the whole of the uncached
-- path.  The returned entry is `dirty` — it is this run's work and its shard (if
-- any) needs writing.
--
-- `wantOccs` exists because Medaka is STRICT: an unconditional `fileDupOccs`
-- here would make every UNCACHED run compute each body's `structuralKey` twice
-- — once for this field and once inside `runCrossFileRules`, which walks the
-- parses itself — and that key is an `exprSexp` of every eligible body, i.e.
-- the single most expensive thing the cross-file tier does.  So the field is
-- filled only on the path that consumes it (--cache, via
-- runCrossFileReportCached); the uncached path leaves it empty and keeps
-- reaching the tier through the parses, exactly as before #395.
lintFileFresh : String -> String -> String -> Bool -> <IO> (LintEntry, Positions, List Decl)
lintFileFresh target src hash wantOccs =
  let (decls, pos) = parseWithPositions src
  (
    LintEntry {
      path = target,
      contentHash = hash,
      findings = lintProgram allRules target src pos decls,
      dupOccs = if wantOccs then fileDupOccs (target, pos, decls) else [],
      directives = collectDirectives src,
      dirty = True,
    },
    pos,
    decls,
  )

-- Fix a single file in-place.  Returns True only on I/O error (write errors exit 2).
lintOneFileFix : List String -> List String -> String -> <IO> Bool
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
-- `medaka snapshot [--check | --new | --bless] [--out <dir>] [--isolate] <paths...>`
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
-- The three modes are mutually exclusive and one is REQUIRED (an unqualified `medaka
-- snapshot <paths>` exits): "what do you want me to do with these files" has no safe
-- default when one of the answers is "rewrite the expectations".
--
--   --check  compare; write nothing.                                    (the gate)
--   --new    create a MISSING snapshot; never touch an existing one.
--   --bless  rewrite an EXISTING snapshot; never create one; and REFUSE outright if any
--            differing section carries diagnostic prose.  The three locks are argued in
--            tools/snapshot.mdk's header block; the SCOPE lock is enforced right here.
--
-- SCOPE (lock 1).  `--bless` requires explicit targets, and `assertBlessIsScoped` below
-- is the enforcement.  Yes, `files == []` already exits on the usage line — but that is
-- an accident of "no targets means nothing to do", and a later refactor that gave the
-- command a default corpus would silently turn `medaka snapshot --bless` into
-- bless-the-world.  OCaml's promote has a scope and deliberately no `make all`; naming
-- what you approve is the ONLY friction that survives with no CI in the loop, so it gets
-- its own guard with its own reason attached, not a side effect of another check.
--
-- Targets are FIXTURES (`.mdk`), never snapshot `.md` files — in either direction, for
-- every mode.  `--out` flattens fixtures from five different roots into one snapshot
-- dir by basename, so the `.md` -> fixture map is not invertible and a `.md` target
-- could not be resolved back to the source it must re-render.
--
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
assertSnapshotTargetsExist : List String -> <IO> Unit
assertSnapshotTargetsExist files =
  let missing = filter (f => not (fileExists f)) files
  if missing == [] then ()
  else
    let _ = ePutStrLn "medaka snapshot: these targets do not exist:"
    let _ = ePutStrLn (joinNl (map (m => "  \{m}") missing))
    exit 1

-- Lock 1, on its own, with its own message.  A `--bless` naming nothing is refused BEFORE
-- target expansion, so the refusal cannot be confused with "your glob matched no files".
assertBlessIsScoped : List String -> List String -> <IO> Unit
assertBlessIsScoped argv targets =
  if not (hasFlag "--bless" argv) || targets != [] then ()
  else
    let _ = ePutStrLn "medaka snapshot: --bless requires explicit targets — there is no whole-suite bless."
    let _ = ePutStrLn "  Name what you are approving, e.g.:"
    let _ = ePutStrLn "    medaka snapshot --bless --out test/snapshots/compiler compiler/frontend/lexer.mdk"
    let _ = ePutStrLn "  (or, family-aware:  sh test/diff_compiler_snapshot_frontend.sh --bless compiler/frontend/lexer.mdk)"
    exit 1

runSnapshotCmd : List String -> <IO> Unit
runSnapshotCmd argv =
  let root = match snapFlagValue "--root" argv
    Some r => r
    None => envOr "MEDAKA_ROOT" defaultMedakaRoot
  let sel = snapshotStages argv
  let targets = snapshotTargets argv
  let _ = assertBlessIsScoped argv targets
  let files = flatMap expandLintTarget targets
  let _ = assertSnapshotTargetsExist files
  if files == [] then
    let _ = ePutStrLn "usage: medaka snapshot [--check|--new|--bless] [--out <dir>] [--stages <a,b,…>] <paths...>"
    exit 1
  else
    if hasFlag "--worker" argv then runSnapshotWorker root sel files
    else match snapshotMode argv
      None =>
        let _ = ePutStrLn "medaka snapshot: pass --check (verify), --new (create missing snapshots) or --bless (rewrite existing ones)"
        exit 1
      Some mode =>
        let ok = runSnapshotSupervisor root mode (hasFlag "--isolate" argv) (snapFlagValue "--out" argv) sel files
        if ok then () else exit 1

-- Exactly one mode, and it is mandatory.  Two modes at once is a hard error rather than
-- a precedence rule: `--check --bless` is a person who does not know which one they
-- meant, and guessing for them is how a verify run turns into a rewrite run.
snapshotMode : List String -> <IO> Option SnapMode
snapshotMode argv =
  let modes = filterList (f => hasFlag f argv) ["--check", "--new", "--bless"]
  match modes
    ["--check"] => Some SnapCheck
    ["--new"] => Some SnapNew
    ["--bless"] => Some SnapBless
    [] => None
    many =>
      let _ = ePutStrLn "medaka snapshot: \{joinWith " " many} are mutually exclusive — pick one."
      let _ = exit 1
      None

-- `--stages parse,desugar,mark` restricts which sections a fixture renders (see
-- tools/snapshot.mdk).  Absent == every stage.  A typo'd stage name EXITS rather than
-- being dropped: silently rendering fewer sections than asked for would report a clean
-- pass over a stage that never ran.
snapshotStages : List String -> <IO> List String
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
-- interactive REPL loop.
--
-- Usage text for `medaka repl --help` / `-h` — mirrors lspUsageLine's shape
-- (#321), adapted to describe the interactive session instead of a stdio
-- protocol server.
replUsageLine : String
replUsageLine = stringConcat
  [
    "medaka repl — Start the interactive REPL\n",
    "\n",
    "Usage:\n",
    "  medaka repl     Start an interactive session that reads expressions\n",
    "                 from stdin, evaluates them, and prints results until\n",
    "                 stdin closes (EOF) or you enter :quit.\n",
  ]

-- #657: argv used to be discarded (`runReplCmd _ = ...`), so `--help`/`-h`/any
-- bogus arg silently fell into the interactive read loop — which blocks on
-- stdin forever if stdin is an open terminal, the same shape as the bug
-- fixed in runLspCmd (#321), runMcpCmd (#299), and runNewCmd (#582). Blocking
-- on stdin with NO args is correct (that's the actual REPL); only an
-- explicit/unknown arg needs handling before the loop starts.
runReplCmd : List String -> <IO> Unit
runReplCmd [] =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let rtPath = root ++ "/stdlib/runtime.mdk"
  let corePath = root ++ "/stdlib/core.mdk"
  match readPreludeFile rtPath
    Err msg =>
      let _ = ePutStrLn msg
      exit 1
    Ok rsrc => match readPreludeFile corePath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok csrc =>
        let runtimeDecls = desugar (parse rsrc)
        let preludeDecls = desugar (parse csrc)
        let _ = initSession runtimeDecls preludeDecls
        replLoop ()
runReplCmd ("--help"::_) =
  let _ = putStrLn replUsageLine
  exit 0
runReplCmd ("-h"::_) =
  let _ = putStrLn replUsageLine
  exit 0
runReplCmd (bad::_) =
  let _ = ePutStrLn ("medaka repl: unknown option '" ++ bad ++ "'")
  let _ = ePutStrLn replUsageLine
  exit 1

-- ── lsp ───────────────────────────────────────────────────────────────────
-- Mirrors bin/main.ml's `lsp` arm (Lsp_server.run) + lsp_main.mdk: read
-- MEDAKA_ROOT/stdlib/{runtime,core}.mdk, then run the JSON-RPC-over-stdio
-- loop (initialize handshake + publishDiagnostics on didOpen/didChange).
--
-- Usage text for `medaka lsp --help` / `-h` — mirrors mcpUsage's one-line
-- description plus the stdio-blocking reminder, adapted for the Language
-- Server Protocol. A plain String (not a function) so it can be printed to
-- either stdout (help) or stderr (error), matching newUsageLine's shape
-- (#582) rather than mcpUsage's stdout-only one (#299).
lspUsageLine : String
lspUsageLine = stringConcat
  [
    "medaka lsp — Run the Language Server Protocol server over stdio\n",
    "\n",
    "Usage:\n",
    "  medaka lsp     Start the server; it reads JSON-RPC requests from stdin\n",
    "                 and writes responses to stdout until stdin closes (EOF).\n",
    "                 This is the normal, correct behavior for an LSP stdio\n",
    "                 server — it is not supposed to be interactive.\n",
  ]

-- #321: argv used to be discarded (`runLspCmd _ = ...`), so `--help`/`-h`/any
-- bogus arg silently fell into the JSON-RPC read loop — which blocks on stdin
-- forever if stdin is an open terminal. Blocking on stdin with NO args is
-- correct (that's the actual protocol); only an explicit/unknown arg needs
-- handling before the server starts. Structurally mirrors runMcpCmd (#299,
-- same file) since lsp — like mcp — takes no positional arguments in normal
-- use; the "unknown option" wording mirrors runNewCmd (#582).
runLspCmd : List String -> <IO> Unit
runLspCmd [] = runLspServerFromEnv ()
runLspCmd ("--help"::_) =
  let _ = putStrLn lspUsageLine
  exit 0
runLspCmd ("-h"::_) =
  let _ = putStrLn lspUsageLine
  exit 0
runLspCmd (bad::_) =
  let _ = ePutStrLn ("medaka lsp: unknown option '" ++ bad ++ "'")
  let _ = ePutStrLn lspUsageLine
  exit 1

runLspServerFromEnv : Unit -> <IO> Unit
runLspServerFromEnv _ =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let rtPath = root ++ "/stdlib/runtime.mdk"
  let corePath = root ++ "/stdlib/core.mdk"
  match readPreludeFile rtPath
    Err msg =>
      let _ = ePutStrLn msg
      exit 1
    Ok rsrc => match readPreludeFile corePath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok csrc => runServer rsrc csrc

-- Short usage blurb for `medaka mcp --help` / `-h` — mirrors the one-line
-- description `usage` (line ~284) gives mcp in the top-level help, plus the
-- reminder that it's a stdio server (so a reader knows why it blocks).
mcpUsage : Unit -> <IO> Unit
mcpUsage _ = putStrLn (stringConcat
  [
    "medaka mcp — Run the MCP server over stdio (JSON-RPC for agents)\n",
    "\n",
    "Usage:\n",
    "  medaka mcp     Start the server; it reads JSON-RPC requests from stdin\n",
    "                 and writes responses to stdout until stdin closes (EOF).\n",
    "                 This is the normal, correct behavior for an MCP stdio\n",
    "                 server — it is not supposed to be interactive.\n",
  ])

-- `medaka mcp`: the MCP (Model Context Protocol) stdio server.  Mirrors
-- runLspCmd exactly — load MEDAKA_ROOT/stdlib/{runtime,core}.mdk and hand the
-- prelude sources to the tools.mcp entry point (they're threaded through so the
-- tools added by later issues can run the compiler pipeline).  Same `<IO>`
-- effect row as runLspCmd (the `Mut`/`Panic` class the issue cited was cut
-- 2026-07-14 — effects are capabilities only).
--
-- #299: argv used to be discarded (`runMcpCmd _ = ...`), so `--help`/`-h`/any
-- bogus arg silently fell into the JSON-RPC read loop — which blocks on stdin
-- forever if stdin is an open terminal. Blocking on stdin with NO args is
-- correct (that's the actual protocol); only an explicit/unknown arg needs
-- handling before the server starts.
runMcpCmd : List String -> <IO> Unit
runMcpCmd [] = runMcpServerFromEnv ()
runMcpCmd ("--help"::_) =
  let _ = mcpUsage ()
  exit 0
runMcpCmd ("-h"::_) =
  let _ = mcpUsage ()
  exit 0
runMcpCmd (bad::_) =
  let _ = ePutStrLn ("medaka mcp: unknown argument '" ++ bad ++ "' (mcp takes no arguments; try 'medaka mcp --help')")
  exit 1

runMcpServerFromEnv : Unit -> <IO> Unit
runMcpServerFromEnv _ =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  let rtPath = root ++ "/stdlib/runtime.mdk"
  let corePath = root ++ "/stdlib/core.mdk"
  let stdlibDir = root ++ "/stdlib"
  match readPreludeFile rtPath
    Err msg =>
      let _ = ePutStrLn msg
      exit 1
    Ok rsrc => match readPreludeFile corePath
      Err msg =>
        let _ = ePutStrLn msg
        exit 1
      Ok csrc => runMcpServer rsrc csrc stdlibDir
# DESUGAR
(DUse false (UseGroup ("tools" "check") ((mem "runCheck" false) (mem "checkHasErrors" false) (mem "runCheckModules" false))))
(DUse false (UseGroup ("tools" "snapshot") ((mem "runSnapshotWorker" false) (mem "runSnapshotSupervisor" false) (mem "parseStages" false) (mem "SnapMode" true))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSource" false))))
(DUse false (UseGroup ("tools" "new_cmd") ((mem "newProject" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "BuildResult" false) (mem "BuildOk" false) (mem "BuildErr" false) (mem "BuildTarget" false) (mem "TNative" false) (mem "TWasm" false) (mem "runBuild" false) (mem "emitRtObj" false) (mem "emitPreludeObj" false) (mem "envOr" false) (mem "defaultMedakaRoot" false) (mem "readPreludeFile" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinNl" false) (mem "joinWith" false) (mem "splitNl" false) (mem "startsWith" false) (mem "endsWith" false) (mem "anyList" false) (mem "filterList" false) (mem "contains" false) (mem "sortUniqS" false) (mem "schemeLineName" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("support" "path") ((mem "baseOf" false) (mem "chopExt" false) (mem "joinPath" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" false) (mem "LetBind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseWithPositions" false) (mem "parseResult" false) (mem "ParseError" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false) (mem "Positions" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "resolveModulesToHumane" false) (mem "resolveModulesToHumaneG" false) (mem "resolveModulesToHumaneGF" false) (mem "resolveModulesToHumaneByPath" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "LoadError" false) (mem "LoadMsg" false) (mem "LoadParseFailed" false) (mem "loadProgramE" false) (mem "loadProgramFilesLocatedE" false) (mem "findProjectRoot" false) (mem "entrySearchRoots" false) (mem "projectTrustedMods" false) (mem "unknownModuleIdOf" false) (mem "findImportLoc" false) (mem "availableModulesHint" false) (mem "availableModulesText" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeProject" false) (mem "analyzeLocated" false) (mem "analyzeLocatedG" false) (mem "ppDiagCli" false) (mem "ppDiagCliSrc" false) (mem "Diag" true) (mem "Severity" true) (mem "SevError" false) (mem "cjPosition" false) (mem "cjRange" false) (mem "cjRangeOfLoc" false) (mem "cjDiagnostic" false) (mem "cjFileEntry" false) (mem "cjAllToJson" false) (mem "readDiagSrc" false) (mem "parseErrCode" false) (mem "parseErrHelpFix" false) (mem "codeKind" false) (mem "optField" false) (mem "cjFixJson" false) (mem "mkDiag" false) (mem "checkJsonFile" false) (mem "readFileSafe" false) (mem "diagIsError" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JInt" false) (mem "JString" false) (mem "JArray" false) (mem "JObject" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "elaborateModules" false) (mem "resetTypeErrorsSticky" false) (mem "hadTypeErrors" false) (mem "mainTypeIsAsync" false) (mem "mainTypeIsUnit" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "evalModulesOutputRun" false) (mem "evalModulesOutputAsync" false) (mem "currentEvalFile" false) (mem "runJsonMode" false) (mem "progArgsRef" false))))
(DUse false (UseGroup ("tools" "test_cmd") ((mem "runTest" false))))
(DUse false (UseGroup ("tools" "repl") ((mem "initSession" false) (mem "replLoop" false))))
(DUse false (UseGroup ("tools" "lsp") ((mem "runServer" false))))
(DUse false (UseGroup ("tools" "mcp") ((mem "runMcpServer" false))))
(DUse false (UseGroup ("tools" "doc") ((mem "runDoc" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "allRules" false) (mem "lintProgram" false) (mem "applySuppressions" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMultiDirs" false) (mem "collectDirectives" false) (mem "findingToDiag" false) (mem "Finding" false) (mem "Directive" false) (mem "applyFixes" false) (mem "runCrossFileRules" false) (mem "runCrossFileRulesFromOccs" false) (mem "crossFileCacheSound" false) (mem "fileDupOccs" false) (mem "parseLintFlagList" false) (mem "applyFindingFilters" false) (mem "applyFindingDeny" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false))))
(DUse false (UseGroup ("tools" "lint_cache") ((mem "LintEntry" true) (mem "contentHashOf" false) (mem "ruleSetStamp" false) (mem "cacheDirOf" false) (mem "loadEntry" false) (mem "storeEntries" false))))
(DUse false (UseGroup ("tools" "codemod") ((mem "findCodemod" false) (mem "codemodMk" false) (mem "codemodWarnDecls" false) (mem "codemodListing" false) (mem "codemodSource" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "runCheckPolicy" false) (mem "runAcceptedPlugin" false) (mem "PolicyArgs" true) (mem "parsePolicyArgs" false) (mem "PolicyOutcome" true) (mem "runManifest" false) (mem "parseManifestArgs" false) (mem "ManifestArgs" true))))
(DTypeSig false "medakaVersion" (TyCon "String"))
(DFunDef false "medakaVersion" () (ELit (LString "0.1.0-preview")))
(DTypeSig false "printVersion" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printVersion" (PWild) (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "medaka ")) (EVar "medakaVersion"))))
(DTypeSig false "liveSourceFingerprint" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "liveSourceFingerprint" ((PVar "root")) (EBlock (DoLet false false (PVar "script") (EApp (EVar "stringConcat") (EListLit (ELit (LString "command -v perl >/dev/null 2>&1 || exit 7; cd \"")) (EVar "root") (ELit (LString "\" && find compiler -name '*.mdk' -print | LC_ALL=C sort")) (ELit (LString " | perl -ne 'chomp; print \"$_\\n\"; open F,\"<\",$_ or next; local $/; my $c=<F>; print $c if defined $c; close F' 2>/dev/null")) (ELit (LString " | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; elif command -v shasum >/dev/null 2>&1; then shasum -a 256; else cksum; fi; }")) (ELit (LString " | cut -d' ' -f1"))))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "sh"))) (EListLit (ELit (LString "-c")) (EVar "script"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "h") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "h") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (EVar "h")))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "checkSourceStaleness" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "checkSourceStaleness" (PWild) (EBlock (DoLet false false (PVar "baked") (EApp (EVar "buildFingerprint") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "baked") (ELit (LString ""))) (ELit LUnit) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "compilerDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "compilerDir"))) (ELit LUnit) (EMatch (EApp (EVar "liveSourceFingerprint") (EVar "root")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "live")) () (EIf (EBinOp "==" (EVar "live") (EVar "baked")) (ELit LUnit) (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EBinOp "++" (ELit (LString "warning: this ./medaka was built from compiler source that differs from ")) (EVar "compilerDir")) (ELit (LString " — it may be stale; rebuild with 'make medaka'.")))) (DoExpr (EIf (EBinOp "!=" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_STRICT"))) (ELit (LString ""))) (ELit (LString ""))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EApp (EVar "ePutStrLn") (EVar "msg")))))))))))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false PWild (EApp (EVar "checkSourceStaleness") (ELit LUnit))) (DoExpr (EApp (EVar "runCli") (ELit LUnit)))))
(DTypeSig false "runCli" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCli" (PWild) (EMatch (EApp (EVar "args") (ELit LUnit)) (arm (PList) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "-h")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "-v")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "check")) (PVar "rest")) () (EApp (EVar "runCheckCmd") (EVar "rest"))) (arm (PCons (PLit (LString "fmt")) (PVar "rest")) () (EApp (EVar "runFmtCmd") (EVar "rest"))) (arm (PCons (PLit (LString "new")) (PVar "rest")) () (EApp (EVar "runNewCmd") (EVar "rest"))) (arm (PCons (PLit (LString "build")) (PVar "rest")) () (EApp (EVar "runBuildCmd") (EVar "rest"))) (arm (PCons (PLit (LString "run")) (PVar "rest")) () (EApp (EVar "runRunCmd") (EVar "rest"))) (arm (PCons (PLit (LString "test")) (PVar "rest")) () (EApp (EVar "runTestCmd") (EVar "rest"))) (arm (PCons (PLit (LString "snapshot")) (PVar "rest")) () (EApp (EVar "runSnapshotCmd") (EVar "rest"))) (arm (PCons (PLit (LString "doc")) (PVar "rest")) () (EApp (EVar "runDocCmd") (EVar "rest"))) (arm (PCons (PLit (LString "lint")) (PVar "rest")) () (EApp (EVar "runLintCmd") (EVar "rest"))) (arm (PCons (PLit (LString "codemod")) (PVar "rest")) () (EApp (EVar "runCodemodCmd") (EVar "rest"))) (arm (PCons (PLit (LString "check-policy")) (PVar "rest")) () (EApp (EVar "runCheckPolicyCmd") (EVar "rest"))) (arm (PCons (PLit (LString "manifest")) (PVar "rest")) () (EApp (EVar "runManifestCmd") (EVar "rest"))) (arm (PCons (PLit (LString "repl")) (PVar "rest")) () (EApp (EVar "runReplCmd") (EVar "rest"))) (arm (PCons (PLit (LString "lsp")) (PVar "rest")) () (EApp (EVar "runLspCmd") (EVar "rest"))) (arm (PCons (PLit (LString "mcp")) (PVar "rest")) () (EApp (EVar "runMcpCmd") (EVar "rest"))) (arm (PCons (PVar "sub") PWild) () (EApp (EVar "notYet") (EVar "sub")))))
(DTypeSig false "usage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "usage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka. A functional language compiler\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka                    Show this message\n")) (ELit (LString "  medaka run [--release] <file.mdk>   Type-check and run a program\n")) (ELit (LString "  medaka build <file.mdk> [-o <out>] [--keep-ir]  Compile to a native binary (LLVM + clang)\n")) (ELit (LString "  medaka check [--json] <file.mdk>    Type-check without running\n")) (ELit (LString "  medaka test [file.mdk]    Run doctests + prop tests\n")) (ELit (LString "  medaka bench [file.mdk]   Run bench declarations\n")) (ELit (LString "  medaka doc [file.mdk]     Generate Markdown documentation\n")) (ELit (LString "  medaka lint [paths...]    Lint files/dirs (style rules; --fix, --cache, --disable/--only/--deny=<rules,...>)\n")) (ELit (LString "  medaka codemod <name> [flags] [paths...]  Apply a named source-preserving AST transform (--write/--stdout)\n")) (ELit (LString "  medaka snapshot [--check|--new|--bless] [paths...]  Per-stage snapshot tests (--out <dir>, --stages <a,b,..>)\n")) (ELit (LString "  medaka fmt [paths...]     Format .mdk files in place (or --check)\n")) (ELit (LString "  medaka new <name>         Scaffold a new project directory\n")) (ELit (LString "  medaka repl               Start an interactive REPL (reads stdin until EOF or :quit)\n")) (ELit (LString "  medaka lsp                Run the language server over stdio\n")) (ELit (LString "  medaka mcp                Run the MCP server over stdio (JSON-RPC for agents)\n")) (ELit (LString "  medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]  Check a plugin's inferred effects against an allow-list\n")) (ELit (LString "  medaka manifest <file.mdk> [--fn name]  Emit the verified capability manifest as TOML\n")) (ELit (LString "  medaka help               Show this message\n")) (ELit (LString "  medaka --version          Show the compiler version\n"))))))
(DTypeSig false "notYet" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "notYet" ((PVar "sub")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka: subcommand '")) (EVar "sub")) (ELit (LString "' not yet in native CLI"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "ppParseError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "ppParseError" ((PVar "src") (PVar "file") (PVar "e")) (EBlock (DoLet false false (PVar "ploc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EApp (EVar "parseErrorCol") (EVar "e"))) (EApp (EVar "parseErrorLine") (EVar "e"))) (EBinOp "+" (EApp (EVar "parseErrorCol") (EVar "e")) (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "h") (PVar "fx")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "file")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (EApp (EVar "parseErrorMessage") (EVar "e"))) (EApp (EVar "Some") (EVar "ploc"))) (EVar "h")) (EVar "fx"))))))
(DTypeSig false "runCheckCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCheckCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false (PVar "typesMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--types"))) (EVar "argv"))) (DoLet false false (PVar "argv2") (EApp (EVar "dropFlags") (EVar "argv"))) (DoExpr (EMatch (EVar "argv2") (arm (PList (PVar "target")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EIf (EVar "jsonMode") (EApp (EApp (EApp (EApp (EApp (EVar "runCheckJsonCmd") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "target")) (EVar "stdlibDir")) (EVar "lerr")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "modsWithPath")) () (EBlock (DoLet false false (PVar "mods") (EApp (EApp (EVar "map") (EVar "dropModPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "pathMap") (EApp (EApp (EVar "map") (EVar "modIdToPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkRoute") (EVar "typesMode")) (EVar "allowInternal")) (EVar "trusted")) (EVar "pathMap")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EVar "mods")))))))))))))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check [--json] [--types] [--allow-internal] <file.mdk>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DTypeSig false "moduleLoadErrText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyCon "String")))))))
(DFunDef false "moduleLoadErrText" (PWild PWild PWild (PCon "LoadParseFailed" (PVar "mpath") (PVar "msrc") (PVar "e"))) (EApp (EApp (EApp (EVar "ppParseError") (EVar "msrc")) (EVar "mpath")) (EVar "e")))
(DFunDef false "moduleLoadErrText" ((PVar "tsrc") (PVar "target") (PVar "stdlibDir") (PCon "LoadMsg" (PVar "lmsg"))) (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "lmsg")) (arm (PCon "Some" (PVar "mid")) () (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EVar "lmsg") (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "tsrc"))) (arm (PCon "None") () (EVar "msg")) (arm (PCon "Some" (PVar "loc")) () (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "msg")) (EApp (EVar "Some") (EVar "loc"))) (EVar "None")) (EVar "None"))))))))))
(DTypeSig false "locatedProjectErrors" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "locatedProjectErrors" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EBlock (DoLet false false (PVar "cacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "cacheRef")) (EVar "parseCacheRef")) (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc"))) (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (EVar "readDiagSrc")) (EVar "results"))) (DoLet false false (PVar "rendered") (EApp (EApp (EVar "flatMap") (EVar "renderTripleErrors")) (EVar "triples"))) (DoExpr (EMatch (EVar "rendered") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "rendered"))))))))
(DTypeSig false "renderTripleErrors" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderTripleErrors" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "path"))) (EApp (EApp (EVar "filter") (EVar "isDiagError")) (EVar "diags"))))
(DTypeSig false "locatedOrGeneric" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))))
(DFunDef false "locatedOrGeneric" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EMatch (EApp (EApp (EApp (EApp (EVar "locatedProjectErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "error: type error in ")) (EVar "target")) (ELit (LString ". Run `medaka check` for details"))))))
(DTypeSig false "checkRoute" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Unit")))))))))))))
(DFunDef false "checkRoute" ((PVar "typesMode") (PVar "allowInternal") (PVar "trusted") PWild PWild (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PList (PTuple (PVar "mid") (PVar "decls")))) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EVar "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false (PVar "warns") (EApp (EApp (EVar "filter") (EVar "isDiagWarn")) (EVar "diags"))) (DoLet false false (PVar "dump") (EApp (EVar "stripWarningLines") (EApp (EApp (EApp (EVar "runCheck") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")))) (DoLet false false (PVar "report") (EIf (EVar "typesMode") (EVar "dump") (EApp (EApp (EVar "userSchemeLines") (EVar "decls")) (EVar "dump")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "report"))) (DoLet false false (PVar "mainWarns") (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (EListLit (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "decls"))))) (EVar "decls"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EBinOp "++" (EVar "warns") (EVar "mainWarns")))) (DoExpr (ELit LUnit)))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target"))) (EVar "errs"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DFunDef false "checkRoute" ((PVar "typesMode") (PVar "allowInternal") (PVar "trusted") (PVar "pathMap") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "mods")) (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneByPath") (EVar "pathMap")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EMatch (EApp (EApp (EApp (EApp (EVar "locatedProjectErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PCon "Some" (PVar "errText")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "errText"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EApp (EApp (EApp (EApp (EVar "runCheckModules") (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD")))) (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple (PVar "emid") (PVar "edecls"))) () (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EVar "rtD")) (EVar "coreD")) (EVar "modsD")) (EVar "edecls"))) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EVar "mainWarns"))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "resDiags"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
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
(DTypeSig false "mainNonUnitWarning" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Diag"))))
(DFunDef false "mainNonUnitWarning" ((PVar "decls")) (EMatch (EApp (EVar "findMainFunDef") (EVar "decls")) (arm (PCon "Some" (PTuple (PList) (PVar "body"))) () (EIf (EBinOp "||" (EApp (EVar "mainTypeIsUnit") (ELit LUnit)) (EApp (EVar "mainTypeIsAsync") (ELit LUnit))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevWarning")) (ELit (LString "W-MAIN-SHAPE"))) (EVar "mainNonUnitMsg")) (EApp (EVar "mainBodyLoc") (EVar "body")))))) (arm PWild () (EVar "None"))))
(DTypeSig false "mainShapeWarnings" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Diag")))))))
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
(DTypeSig false "runCheckJsonCmd" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "runCheckJsonCmd" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "stdlibDir")) (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFile") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir"))) (DoLet false false PWild (EApp (EVar "println") (EVar "json"))) (DoExpr (EIf (EVar "hasErr") (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))
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
(DTypeSig false "runFmtCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runFmtCmd" ((PVar "argv")) (EMatch (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "argv")) (EVar "FmtWrite")) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple PWild (PList))) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "Usage: medaka fmt [--check | --stdout | --write] <path>...")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PList (PVar "target")))) () (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "fmtOne") (EVar "mode")) (EVar "target"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EListLit (EVar "target")))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PVar "targets"))) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EVar "targets")))))
(DTypeSig false "fmtManyTargets" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "fmtManyTargets" ((PCon "FmtStdout") PWild) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka fmt: --stdout requires exactly one file")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DFunDef false "fmtManyTargets" ((PVar "mode") (PVar "targets")) (EBlock (DoLet false false (PVar "files") (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka fmt: no .mdk files found")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm PWild () (EIf (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "files")) (EVar "False")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))
(DTypeSig false "fmtFilesGo" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "fmtFilesGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "fmtFilesGo" ((PVar "mode") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "hadErr") (EApp (EApp (EVar "fmtOneReport") (EVar "mode")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr"))))))
(DTypeSig false "fmtOneReport" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "fmtOneReport" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "formatted"))) (DoExpr (EVar "False")))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EVar "False") (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted"))))) (DoExpr (EVar "True"))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EVar "False") (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EVar "False")))))))))))))
(DTypeSig false "parseFmtArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "FmtMode") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "parseFmtArgs" ((PList) (PVar "mode") (PVar "acc")) (EApp (EVar "Ok") (ETuple (EVar "mode") (EApp (EVar "reverseL") (EVar "acc")))))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--check")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtCheck")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--stdout")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtStdout")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--write")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtWrite")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "-w")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtWrite")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PVar "x") (PVar "rest")) (PVar "mode") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "x")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "x")) (ELit (LString "-")))) (EApp (EVar "Err") (EBinOp "++" (ELit (LString "medaka fmt: unknown flag: ")) (EVar "x"))) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "mode")) (EBinOp "::" (EVar "x") (EVar "acc")))))
(DTypeSig false "fmtOne" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "fmtOne" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EApp (EVar "putStr") (EVar "formatted"))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ELit LUnit) (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" PWild) () (ELit LUnit)))))))))))))
(DData Private "CodeMode" () ((variant "CmDry" (ConPos)) (variant "CmWrite" (ConPos)) (variant "CmStdout" (ConPos))) ())
(DTypeSig false "runCodemodCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCodemodCmd" ((PList)) (EApp (EVar "listCodemodsAndExit") (ELit LUnit)))
(DFunDef false "runCodemodCmd" ((PCons (PVar "name") (PVar "rest"))) (EMatch (EApp (EVar "findCodemod") (EVar "name")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod: unknown codemod '")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "'"))))) (DoExpr (EApp (EVar "listCodemodsAndExit") (ELit LUnit))))) (arm (PCon "Some" (PVar "cm")) () (EMatch (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmDry")) (EListLit)) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PVar "cargs") (PVar "targets"))) () (EMatch (EApp (EApp (EVar "codemodMk") (EVar "cm")) (EVar "cargs")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PVar "xf")) () (EBlock (DoLet false false (PVar "files") (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka codemod: no .mdk files found")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm PWild () (EMatch (EVar "mode") (arm (PCon "CmStdout") () (EMatch (EVar "files") (arm (PList (PVar "one")) () (EApp (EApp (EApp (EVar "codemodStdout") (EVar "xf")) (EApp (EApp (EVar "codemodWarnDecls") (EVar "cm")) (EVar "cargs"))) (EVar "one"))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka codemod: --stdout requires exactly one file")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))))) (arm PWild () (EIf (EApp (EApp (EApp (EApp (EApp (EVar "codemodFilesGo") (EVar "mode")) (EVar "xf")) (EApp (EApp (EVar "codemodWarnDecls") (EVar "cm")) (EVar "cargs"))) (EVar "files")) (EVar "False")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))))))))))
(DTypeSig false "listCodemodsAndExit" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "listCodemodsAndExit" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "Usage: medaka codemod <name> [flags] [--write|--stdout] <paths...>")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "Available codemods:")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "codemodListing"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DTypeSig false "splitCodemodArgv" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CodeMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "CodeMode") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "splitCodemodArgv" ((PList) (PVar "mode") (PVar "cargs") (PVar "paths")) (EApp (EVar "Ok") (ETuple (EVar "mode") (EApp (EVar "reverseL") (EVar "cargs")) (EApp (EVar "reverseL") (EVar "paths")))))
(DFunDef false "splitCodemodArgv" ((PCons (PLit (LString "--write")) (PVar "rest")) PWild (PVar "cargs") (PVar "paths")) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmWrite")) (EVar "cargs")) (EVar "paths")))
(DFunDef false "splitCodemodArgv" ((PCons (PLit (LString "--stdout")) (PVar "rest")) PWild (PVar "cargs") (PVar "paths")) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmStdout")) (EVar "cargs")) (EVar "paths")))
(DFunDef false "splitCodemodArgv" ((PCons (PVar "tok") (PVar "rest")) (PVar "mode") (PVar "cargs") (PVar "paths")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "tok")) (EMatch (EVar "rest") (arm (PCons (PVar "v") (PVar "rest2")) () (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest2")) (EVar "mode")) (EBinOp "::" (EVar "v") (EBinOp "::" (EVar "tok") (EVar "cargs")))) (EVar "paths"))) (arm (PList) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod: flag '")) (EApp (EVar "display") (EVar "tok"))) (ELit (LString "' requires a value")))))) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "mode")) (EVar "cargs")) (EBinOp "::" (EVar "tok") (EVar "paths")))))
(DTypeSig false "codemodStdout" (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "codemodStdout" ((PVar "xf") (PVar "warnFn") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EVar "codemodSource") (EVar "xf")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "result")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "emitCodemodWarns") (EVar "warnFn")) (EVar "file")) (EVar "src"))) (DoExpr (EMatch (EVar "result") (arm (PCon "None") () (EApp (EVar "putStr") (EVar "src"))) (arm (PCon "Some" (PVar "out")) () (EApp (EVar "putStr") (EVar "out")))))))))))
(DTypeSig false "codemodFilesGo" (TyFun (TyCon "CodeMode") (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "codemodFilesGo" (PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "codemodFilesGo" ((PVar "mode") (PVar "xf") (PVar "warnFn") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "signal") (EApp (EApp (EApp (EApp (EVar "codemodOneReport") (EVar "mode")) (EVar "xf")) (EVar "warnFn")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "codemodFilesGo") (EVar "mode")) (EVar "xf")) (EVar "warnFn")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "signal"))))))
(DTypeSig false "codemodOneReport" (TyFun (TyCon "CodeMode") (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "codemodOneReport" ((PVar "mode") (PVar "xf") (PVar "warnFn") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EVar "codemodSource") (EVar "xf")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "result")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "emitCodemodWarns") (EVar "warnFn")) (EVar "file")) (EVar "src"))) (DoExpr (EMatch (EVar "result") (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "out")) () (EMatch (EVar "mode") (arm (PCon "CmWrite") () (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "out")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EVar "False")))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "would rewrite: ")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ""))))) (DoExpr (EVar "True"))))))))))))))
(DTypeSig false "emitCodemodWarns" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitCodemodWarns" ((PVar "warnFn") (PVar "file") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "decls") PWild) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoExpr (EApp (EApp (EVar "emitWarnLines") (EVar "file")) (EApp (EVar "warnFn") (EVar "decls"))))))
(DTypeSig false "emitWarnLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitWarnLines" (PWild (PList)) (ELit LUnit))
(DFunDef false "emitWarnLines" ((PVar "file") (PCons (PVar "w") (PVar "ws"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ": warning: "))) (EApp (EVar "display") (EVar "w"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EVar "emitWarnLines") (EVar "file")) (EVar "ws")))))
(DTypeSig false "newUsageLine" (TyCon "String"))
(DFunDef false "newUsageLine" () (ELit (LString "Usage: medaka new <name>")))
(DTypeSig false "runNewCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runNewCmd" ((PList (PVar "arg"))) (EIf (EBinOp "||" (EBinOp "==" (EVar "arg") (ELit (LString "--help"))) (EBinOp "==" (EVar "arg") (ELit (LString "-h")))) (EApp (EVar "putStrLn") (EVar "newUsageLine")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "arg")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "arg")) (ELit (LString "-")))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka new: unknown option '")) (EVar "arg")) (ELit (LString "'"))))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "newUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))) (EBlock (DoLet false false (PVar "code") (EApp (EVar "newProject") (EVar "arg"))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (ELit LUnit) (EApp (EVar "exit") (EVar "code"))))))))
(DFunDef false "runNewCmd" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "newUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DTypeSig false "runBuildCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildCmd" ((PVar "argv")) (EIf (EBinOp "||" (EApp (EApp (EVar "hasFlag") (ELit (LString "--help"))) (EVar "argv")) (EApp (EApp (EVar "hasFlag") (ELit (LString "-h"))) (EVar "argv"))) (EApp (EVar "buildUsage") (ELit LUnit)) (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--emit-rt-obj"))) (EVar "argv")) (arm (PCon "Some" (PVar "objPath")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "emitRtObj") (EVar "cc")) (EVar "root")) (EVar "objPath")) (arm (PCon "BuildOk" (PVar "msg")) () (EApp (EVar "println") (EVar "msg"))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--emit-prelude-obj"))) (EVar "argv")) (arm (PCon "Some" (PVar "objPath")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "./medaka")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "emitPreludeObj") (EVar "cc")) (EVar "root")) (EVar "medaka")) (EVar "objPath")) (arm (PCon "BuildOk" (PVar "msg")) () (EApp (EVar "println") (EVar "msg"))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))) (arm (PCon "None") () (EMatch (EApp (EVar "parseBuildArgs") (EVar "argv")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PTuple (PVar "input") (PVar "outOpt") (PVar "target"))) () (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "input"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (ELit (LString "error: no such file: ")) (EVar "input")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "inputAbs") (EVar "input")) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false (PVar "keepIrCli") (EApp (EApp (EVar "hasFlag") (ELit (LString "--keep-ir"))) (EVar "argv"))) (DoLet false false (PVar "outPath") (EMatch (EVar "outOpt") (arm (PCon "Some" (PVar "o")) () (EVar "o")) (arm (PCon "None") () (EApp (EApp (EVar "defaultOutPath") (EVar "target")) (EVar "input"))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "typecheckGate") (EVar "allowInternal")) (EVar "root")) (EVar "inputAbs")) (arm (PCon "TGErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "TGOk") () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuild") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "target")) (EVar "inputAbs")) (EVar "outPath")) (EVar "keepIrCli")) (arm (PCon "BuildOk" (PVar "msg")) () (EApp (EVar "println") (EVar "msg"))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))))))))))))
(DTypeSig false "buildUsage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "buildUsage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "usage: medaka build [--target native|wasm] <file.mdk> [-o <out>] [--keep-ir] [--allow-internal]\n")) (ELit (LString "\n")) (ELit (LString "  -o <out>          output path for the binary (default: <file> with its extension dropped)\n")) (ELit (LString "  --target <t>      backend: native (LLVM + clang, default) or wasm (WasmGC + wasm-tools)\n")) (ELit (LString "  --keep-ir         keep the emitted IR (.ll for native, .wat for wasm) at <out>.ll/.wat\n")) (ELit (LString "                    instead of discarding it with the build's scratch directory; the\n")) (ELit (LString "                    kept path is printed. Env var MEDAKA_KEEP_IR=1 does the same for a\n")) (ELit (LString "                    build invoked by something else (e.g. a test harness)\n")) (ELit (LString "  --allow-internal  permit internal-only externs outside stdlib/\n")) (ELit (LString "  --emit-rt-obj <p> compile only runtime/medaka_rt.c to a reusable object at <p> (with\n")) (ELit (LString "                    the same flags a normal link uses) and exit; point MEDAKA_RT_OBJ at\n")) (ELit (LString "                    it to skip recompiling the runtime on every subsequent build\n")) (ELit (LString "  --emit-prelude-obj <p>\n")) (ELit (LString "                    compile only stdlib/core.mdk to a reusable object at <p> (with the\n")) (ELit (LString "                    same flags a normal link uses) and exit; point MEDAKA_PRELUDE_OBJ at\n")) (ELit (LString "                    it to skip re-optimising the prelude on every subsequent build.\n")) (ELit (LString "                    Opt-in: separate objects cannot inline the prelude into user code\n"))))))
(DTypeSig false "defaultOutPath" (TyFun (TyCon "BuildTarget") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "defaultOutPath" ((PCon "TNative") (PVar "input")) (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))))
(DFunDef false "defaultOutPath" ((PCon "TWasm") (PVar "input")) (EBinOp "++" (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))) (ELit (LString ".wasm"))))
(DData Private "TypecheckGate" () ((variant "TGOk" (ConPos)) (variant "TGErr" (ConPos (TyCon "String")))) ())
(DTypeSig false "typecheckGate" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "TypecheckGate"))))))
(DFunDef false "typecheckGate" ((PVar "allowInternal") (PVar "root") (PVar "input")) (EBlock (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "input"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "input")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "TGErr") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "input")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "loadProgramE") (EVar "input")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EApp (EVar "TGErr") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "input")) (EVar "stdlibDir")) (EVar "lerr")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "input")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckGateRoute") (EVar "allowInternal")) (EVar "trusted")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "input")) (EVar "mods")))))))))))))))))
(DTypeSig false "typecheckGateRoute" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "TypecheckGate")))))))))))
(DFunDef false "typecheckGateRoute" ((PVar "allowInternal") (PVar "trusted") PWild (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PList (PTuple (PVar "mid") PWild))) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EVar "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "TGOk")) (arm PWild () (EApp (EVar "TGErr") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target"))) (EVar "errs")))))))))
(DFunDef false "typecheckGateRoute" ((PVar "allowInternal") (PVar "trusted") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "mods")) (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneGF") (EVar "target")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EMatch (EApp (EApp (EApp (EApp (EVar "locatedProjectErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PCon "Some" (PVar "errText")) () (EApp (EVar "TGErr") (EVar "errText"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EApp (EVar "hadTypeErrors") (ELit LUnit)) (arm (PCon "True") () (EApp (EVar "TGErr") (EApp (EApp (EApp (EApp (EVar "locatedOrGeneric") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")))) (arm (PCon "False") () (EVar "TGOk")))))))) (arm PWild () (EApp (EVar "TGErr") (EVar "resDiags")))))))
(DTypeSig false "parseBuildArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))
(DFunDef false "parseBuildArgs" ((PVar "argv")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "argv")) (EListLit)) (EVar "None")) (EVar "TNative")))
(DTypeSig false "parseBuildGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget"))))))))
(DFunDef false "parseBuildGo" ((PList) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EVar "finishBuildArgs") (EApp (EVar "reverseL") (EVar "acc"))) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "-o")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EApp (EVar "Some") (EVar "v"))) (EVar "target")))
(DFunDef false "parseBuildGo" ((PList (PLit (LString "-o"))) PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: -o requires an argument"))))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--target")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc") (PVar "out") PWild) (EMatch (EApp (EVar "parseTarget") (EVar "v")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PVar "t")) () (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "t")))))
(DFunDef false "parseBuildGo" ((PList (PLit (LString "--target"))) PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: --target requires an argument (native|wasm)"))))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--allow-internal")) (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--keep-ir")) (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PVar "x") (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "acc"))) (EVar "out")) (EVar "target")))
(DTypeSig false "parseTarget" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BuildTarget"))))
(DFunDef false "parseTarget" ((PLit (LString "native"))) (EApp (EVar "Ok") (EVar "TNative")))
(DFunDef false "parseTarget" ((PLit (LString "wasm"))) (EApp (EVar "Ok") (EVar "TWasm")))
(DFunDef false "parseTarget" ((PVar "other")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "error: unknown --target '")) (EVar "other")) (ELit (LString "' (expected native|wasm)")))))
(DTypeSig false "finishBuildArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))))
(DFunDef false "finishBuildArgs" ((PList) PWild PWild) (EApp (EVar "Err") (ELit (LString "usage: medaka build [--target native|wasm] <file.mdk> [-o <out>]"))))
(DFunDef false "finishBuildArgs" ((PList (PVar "input")) (PVar "out") (PVar "target")) (EApp (EVar "Ok") (ETuple (EVar "input") (EVar "out") (EVar "target"))))
(DFunDef false "finishBuildArgs" (PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: medaka build takes exactly one input file"))))
(DTypeSig false "finishRunEval" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "finishRunEval" ((PVar "target") (PVar "jsonMode") (PVar "elaborated") (PVar "mods")) (EBlock (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple PWild (PVar "edecls"))) () (EMatch (EApp (EVar "mainArityWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EMatch (EApp (EVar "mainNonUnitWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit)))))) (arm (PCon "None") () (EListLit)))) (DoLet false false PWild (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "mainWarns"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "currentEvalFile")) (EVar "target"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "runJsonMode")) (EVar "jsonMode"))) (DoExpr (EApp (EVar "putStr") (EApp (EApp (EVar "runProgramOutput") (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))))))
(DTypeSig false "runRunCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runRunCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoExpr (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka run [--release] [--json] <file.mdk>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") (PVar "progArgs")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "progArgsRef")) (EVar "progArgs"))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "parseResult") (EApp (EVar "readFileSafe") (EVar "target"))) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "map") (EApp (EVar "map") (EVar "dropModPath"))) (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots"))) (arm (PCon "Err" (PVar "lerr")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "stdlibDir")) (EVar "lerr")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoExpr (EMatch (EVar "modsD") (arm (PList PWild) () (EBlock (DoLet false false (PVar "tsrc") (EApp (EVar "readFileSafe") (EVar "target"))) (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EVar "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EVar "elaborated")) (EVar "mods"))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target"))) (EVar "errs"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))) (arm PWild () (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneGF") (EVar "target")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EMatch (EApp (EApp (EApp (EApp (EVar "locatedProjectErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PCon "Some" (PVar "errText")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "errText"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EApp (EVar "hadTypeErrors") (ELit LUnit)) (arm (PCon "True") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "locatedOrGeneric") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "False") () (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EVar "elaborated")) (EVar "mods"))))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "resDiags"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))))))))))))))))))))
(DTypeSig false "desugarPair" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugarPair" ((PTuple (PVar "mid") (PVar "p"))) (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "p"))))
(DTypeSig false "dropModPath" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "dropModPath" ((PTuple (PVar "mid") PWild (PVar "prog"))) (ETuple (EVar "mid") (EVar "prog")))
(DTypeSig false "modIdToPath" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "modIdToPath" ((PTuple (PVar "mid") (PVar "path") PWild)) (ETuple (EVar "mid") (EVar "path")))
(DTypeSig false "runProgramOutput" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "runProgramOutput" ((PVar "preludeDecls") (PVar "modules")) (EMatch (EApp (EVar "mainTypeIsAsync") (ELit LUnit)) (arm (PCon "True") () (EApp (EApp (EVar "evalModulesOutputAsync") (EVar "preludeDecls")) (EVar "modules"))) (arm (PCon "False") () (EApp (EApp (EVar "evalModulesOutputRun") (EVar "preludeDecls")) (EVar "modules")))))
(DTypeSig false "runTestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runTestCmd" ((PVar "argv")) (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka test [file.mdk | dir]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PList (PVar "target")) () (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Err" PWild) () (EApp (EVar "runTestOne") (EVar "target"))) (arm (PCon "Ok" PWild) () (EApp (EVar "runTestManyTargets") (EListLit (EVar "target")))))) (arm (PVar "targets") () (EApp (EVar "runTestManyTargets") (EVar "targets")))))
(DTypeSig false "runTestOne" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runTestOne" ((PVar "target")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EVar "runTest") (EVar "rtPath")) (EVar "corePath")) (EVar "target")) (EVar "roots"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "exit") (ELit (LInt 1)))))))
(DTypeSig false "runTestManyTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runTestManyTargets" ((PVar "targets")) (EBlock (DoLet false false (PVar "files") (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "medaka test: no .mdk files found")))) (DoExpr (ELit LUnit)))) (arm PWild () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EApp (EVar "testFilesGo") (EVar "rtPath")) (EVar "corePath")) (EVar "stdlibDir")) (EVar "files")) (EVar "False")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))))
(DTypeSig false "testFilesGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "testFilesGo" (PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "testFilesGo" ((PVar "rtPath") (PVar "corePath") (PVar "stdlibDir") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "f"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EVar "runTest") (EVar "rtPath")) (EVar "corePath")) (EVar "f")) (EVar "roots"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "testFilesGo") (EVar "rtPath")) (EVar "corePath")) (EVar "stdlibDir")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EApp (EVar "not") (EVar "ok")))))))
(DTypeSig false "runDocCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runDocCmd" ((PVar "argv")) (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka doc [file.mdk]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") PWild) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runDoc") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target"))))))))))))))
(DTypeSig false "runCheckPolicyCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCheckPolicyCmd" ((PVar "argv")) (EMatch (EApp (EVar "parsePolicyArgs") (EVar "argv")) (arm (PCon "PolicyArgs" (PCon "None") PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "PolicyArgs" (PCon "Some" (PVar "target")) (PVar "allow") (PVar "fn")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "runCheckPolicy") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "allow")) (EVar "fn")) (arm (PCon "PolicyReject" (PVar "report")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "report"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "PolicyAccept" (PVar "header") (PVar "pluginFn") (PVar "coreD") (PVar "rtD") (PVar "userD")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "header"))) (DoExpr (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runAcceptedPlugin") (EVar "pluginFn")) (EVar "coreD")) (EVar "rtD")) (EVar "userD"))))))))))))))))))
(DTypeSig false "runManifestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runManifestCmd" ((PVar "argv")) (EMatch (EApp (EVar "parseManifestArgs") (EVar "argv")) (arm (PCon "ManifestArgs" (PCon "None") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka manifest <file.mdk> [--fn name]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "ManifestArgs" (PCon "Some" (PVar "target")) (PVar "fn")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runManifest") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "fn"))))))))))))))
(DTypeSig false "runLintCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLintCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "disableNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--disable="))) (EVar "argv"))) (DoLet false false (PVar "onlyNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--only="))) (EVar "argv"))) (DoLet false false (PVar "denyNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--deny="))) (EVar "argv"))) (DoLet false false (PVar "fixMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--fix"))) (EVar "argv"))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoLet false false (PVar "fileArgs") (EApp (EVar "lintTargets") (EVar "argv"))) (DoLet false false (PVar "files") (EApp (EVar "resolveLintTargets") (EVar "fileArgs"))) (DoExpr (EIf (EVar "jsonMode") (EApp (EApp (EApp (EApp (EVar "runLintJsonCmd") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "files")) (EBlock (DoLet false false (PVar "multiFile") (EMatch (EVar "files") (arm (PCons PWild (PCons PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False")))) (DoLet false false (PVar "cacheCtx") (EApp (EApp (EVar "lintCacheCtx") (EApp (EApp (EVar "hasFlag") (ELit (LString "--cache"))) (EVar "argv"))) (EVar "fixMode"))) (DoLet false false (PTuple (PVar "perFileErr") (PVar "entries") (PVar "parsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "files")) (EVar "False"))) (DoLet false false (PVar "crossErr") (EIf (EApp (EVar "not") (EBinOp "&&" (EVar "multiFile") (EApp (EVar "not") (EVar "fixMode")))) (EVar "False") (EMatch (EVar "cacheCtx") (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "runCrossFileReportCached") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "entries"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "runCrossFileReport") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "parsed")))))) (DoLet false false PWild (EMatch (EVar "cacheCtx") (arm (PCon "Some" (PTuple (PVar "cacheDir") (PVar "stamp"))) () (EApp (EApp (EApp (EVar "storeEntries") (EVar "cacheDir")) (EVar "stamp")) (EVar "entries"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EIf (EBinOp "||" (EVar "perFileErr") (EVar "crossErr")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit))))))))
(DTypeSig false "lintCacheCtx" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "lintCacheCtx" ((PCon "False") PWild) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "True")) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "False")) (EIf (EApp (EVar "not") (EVar "crossFileCacheSound")) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "root") (EApp (EVar "findProjectRoot") (EApp (EVar "canonicalizePath") (ELit (LString "."))))) (DoLet false false (PVar "stamp") (EApp (EVar "ruleSetStamp") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "stamp") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (ETuple (EApp (EVar "cacheDirOf") (EVar "root")) (EVar "stamp")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runLintJsonCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "runLintJsonCmd" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "files")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagTriples") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "files"))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "cjAllToJson") (EVar "triples")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EVar "cjLintTripleHasErr")) (EVar "triples")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))
(DTypeSig false "lintFilesToDiagTriples" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "lintFilesToDiagTriples" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintFilesToDiagTriples" ((PVar "disable") (PVar "only") (PVar "deny") (PCons (PVar "f") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "lintFileDiagTriple") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "f")) (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagTriples") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "rest"))))
(DTypeSig false "cjLintTripleHasErr" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "cjLintTripleHasErr" ((PTuple PWild PWild (PVar "diags"))) (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags")))
(DTypeSig false "runCrossFileReport" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runCrossFileReport" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "parsed")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (EVar "parsedToTriple")) (EVar "parsed"))) (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRules") (EVar "onlyNames")) (EVar "disableNames")) (EVar "triples"))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMulti") (EApp (EApp (EVar "map") (EVar "parsedToSrc")) (EVar "parsed"))) (EVar "raw"))) (DoExpr (EApp (EVar "reportCrossFindings") (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed"))))))
(DTypeSig false "runCrossFileReportCached" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runCrossFileReportCached" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "entries")) (EBlock (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRulesFromOccs") (EVar "onlyNames")) (EVar "disableNames")) (EApp (EApp (EVar "flatMap") (EVar "entryOccs")) (EVar "entries")))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMultiDirs") (EApp (EApp (EVar "map") (EVar "entryDirTable")) (EVar "entries"))) (EVar "raw"))) (DoExpr (EApp (EVar "reportCrossFindings") (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed"))))))
(DTypeSig false "entryOccs" (TyFun (TyCon "LintEntry") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))))
(DFunDef false "entryOccs" ((PVar "e")) (EFieldAccess (EVar "e") "dupOccs"))
(DTypeSig false "entryDirTable" (TyFun (TyCon "LintEntry") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))))
(DFunDef false "entryDirTable" ((PVar "e")) (ETuple (EFieldAccess (EVar "e") "path") (EFieldAccess (EVar "e") "directives")))
(DTypeSig false "reportCrossFindings" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "reportCrossFindings" ((PList)) (EVar "False"))
(DFunDef false "reportCrossFindings" ((PVar "findings")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "cross-file:")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "renderCrossFinding")) (EVar "findings"))))) (DoExpr (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")))))
(DTypeSig false "renderCrossFinding" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "renderCrossFinding" ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (ELit (LString ""))) (EApp (EVar "locFileOf") (EFieldAccess (EVar "f") "loc"))) (EApp (EVar "findingToDiag") (EVar "f"))))
(DTypeSig false "locFileOf" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locFileOf" ((PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild))) (EVar "file"))
(DFunDef false "locFileOf" ((PCon "None")) (ELit (LString "")))
(DTypeSig false "parsedToTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "parsedToTriple" ((PTuple (PVar "path") PWild (PVar "pos") (PVar "decls"))) (ETuple (EVar "path") (EVar "pos") (EVar "decls")))
(DTypeSig false "parsedToSrc" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "parsedToSrc" ((PTuple (PVar "path") (PVar "src") PWild PWild)) (ETuple (EVar "path") (EVar "src")))
(DTypeSig false "resolveLintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "resolveLintTargets" ((PList)) (EBlock (DoLet false false (PVar "cwd") (EApp (EVar "canonicalizePath") (ELit (LString ".")))) (DoLet false false (PVar "root") (EApp (EVar "findProjectRoot") (EVar "cwd"))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EBinOp "++" (EVar "root") (ELit (LString "/medaka.toml"))))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka lint: no medaka.toml found; run from a project directory or pass file/dir paths")))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EListLit))) (EApp (EVar "collectMdkFiles") (EVar "root"))))))
(DFunDef false "resolveLintTargets" ((PVar "targets")) (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets")))
(DTypeSig false "expandLintTarget" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "expandLintTarget" ((PVar "target")) (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFiles") (EVar "target"))) (arm (PCon "Err" PWild) () (EListLit (EVar "target")))))
(DTypeSig false "lintPathJoin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "lintPathJoin" ((PVar "dir") (PVar "name")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "dir")) (EBinOp "++" (EVar "dir") (EVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))))
(DTypeSig false "collectMdkFiles" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFiles" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: cannot list directory ")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EListLit)))) (arm (PCon "Ok" PWild) () (EApp (EVar "sortUniqS") (EApp (EVar "collectMdkFilesRec") (EVar "dir"))))))
(DTypeSig false "collectMdkFilesRec" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFilesRec" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EApp (EVar "filterNonDot") (EVar "entries"))))))
(DTypeSig false "collectMdkEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntries" (PWild (PList)) (EListLit))
(DFunDef false "collectMdkEntries" ((PVar "dir") (PCons (PVar "name") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "collectMdkEntry") (EVar "dir")) (EVar "name")) (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EVar "rest"))))
(DTypeSig false "collectMdkEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntry" ((PVar "dir") (PVar "name")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "lintPathJoin") (EVar "dir")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFilesRec") (EVar "full"))) (arm (PCon "Err" PWild) () (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "name")) (EListLit (EVar "full")) (EListLit)))))))
(DTypeSig false "filterNonDot" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterNonDot" ((PList)) (EListLit))
(DFunDef false "filterNonDot" ((PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (EApp (EVar "filterNonDot") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "n") (EApp (EVar "filterNonDot") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lintFilesGo" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))))
(DFunDef false "lintFilesGo" (PWild PWild PWild PWild PWild PWild (PList) (PVar "acc")) (ETuple (EVar "acc") (EListLit) (EListLit)))
(DFunDef false "lintFilesGo" ((PVar "fixMode") (PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "cacheCtx") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EIf (EVar "fixMode") (EBlock (DoLet false false (PVar "hadErr") (EApp (EApp (EApp (EVar "lintOneFileFix") (EVar "onlyNames")) (EVar "disableNames")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr"))))) (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "entries") (PVar "parsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintOneFileReport") (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "f"))) (DoLet false false (PTuple (PVar "restErr") (PVar "restEntries") (PVar "restParsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr")))) (DoExpr (ETuple (EVar "restErr") (EBinOp "++" (EVar "entries") (EVar "restEntries")) (EBinOp "++" (EVar "parsed") (EVar "restParsed")))))))
(DTypeSig false "lintOneFileReport" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))
(DFunDef false "lintOneFileReport" ((PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "cacheCtx") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (ETuple (EVar "True") (EListLit) (EListLit))))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "entry") (PVar "parsed")) (EApp (EApp (EApp (EVar "lintEntryOf") (EVar "cacheCtx")) (EVar "target")) (EVar "src"))) (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressionsDirs") (EFieldAccess (EVar "entry") "directives")) (EFieldAccess (EVar "entry") "findings"))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "allFindings"))) (DoLet false false (PVar "output") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (ELam ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "target")) (EApp (EVar "findingToDiag") (EVar "f"))))) (EVar "findings")))) (DoLet false false (PVar "hasOutput") (EBinOp ">" (EApp (EVar "stringLength") (EVar "output")) (ELit (LInt 0)))) (DoLet false false PWild (EIf (EBinOp "&&" (EVar "multiFile") (EVar "hasOutput")) (EApp (EVar "putStrLn") (EBinOp "++" (EVar "target") (ELit (LString ":")))) (ELit LUnit))) (DoLet false false PWild (EIf (EVar "hasOutput") (EApp (EVar "putStrLn") (EVar "output")) (ELit LUnit))) (DoExpr (ETuple (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")) (EListLit (EVar "entry")) (EVar "parsed")))))))
(DTypeSig false "lintEntryOf" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "LintEntry") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "lintEntryOf" ((PCon "None") (PVar "target") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "entry") (PVar "pos") (PVar "decls")) (EApp (EApp (EApp (EApp (EVar "lintFileFresh") (EVar "target")) (EVar "src")) (ELit (LString ""))) (EVar "False"))) (DoExpr (ETuple (EVar "entry") (EListLit (ETuple (EVar "target") (EVar "src") (EVar "pos") (EVar "decls")))))))
(DFunDef false "lintEntryOf" ((PCon "Some" (PTuple (PVar "cacheDir") (PVar "stamp"))) (PVar "target") (PVar "src")) (EBlock (DoLet false false (PVar "hash") (EApp (EVar "contentHashOf") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "loadEntry") (EVar "cacheDir")) (EVar "stamp")) (EVar "target")) (EVar "hash")) (arm (PCon "Some" (PVar "hit")) () (ETuple (EVar "hit") (EListLit))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "entry") PWild PWild) (EApp (EApp (EApp (EApp (EVar "lintFileFresh") (EVar "target")) (EVar "src")) (EVar "hash")) (EVar "True"))) (DoExpr (ETuple (EVar "entry") (EListLit)))))))))
(DTypeSig false "lintFileFresh" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyCon "LintEntry") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "lintFileFresh" ((PVar "target") (PVar "src") (PVar "hash") (PVar "wantOccs")) (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoExpr (ETuple (ERecordCreate "LintEntry" ((fa "path" (EVar "target")) (fa "contentHash" (EVar "hash")) (fa "findings" (EApp (EApp (EApp (EApp (EApp (EVar "lintProgram") (EVar "allRules")) (EVar "target")) (EVar "src")) (EVar "pos")) (EVar "decls"))) (fa "dupOccs" (EIf (EVar "wantOccs") (EApp (EVar "fileDupOccs") (ETuple (EVar "target") (EVar "pos") (EVar "decls"))) (EListLit))) (fa "directives" (EApp (EVar "collectDirectives") (EVar "src"))) (fa "dirty" (EVar "True")))) (EVar "pos") (EVar "decls")))))
(DTypeSig false "lintOneFileFix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "lintOneFileFix" ((PVar "onlyNames") (PVar "disableNames") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PTuple (PVar "newSrc") (PVar "n")) (EApp (EApp (EApp (EApp (EApp (EVar "applyFixes") (EVar "onlyNames")) (EVar "disableNames")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoExpr (EIf (EBinOp "==" (EVar "newSrc") (EVar "src")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "fixed 0 finding(s) in ")) (EVar "target")))) (DoExpr (EVar "False"))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "target")) (EVar "newSrc")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 2)))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "fixed ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " finding(s) in "))) (EApp (EVar "display") (EVar "target"))) (ELit (LString ""))))) (DoExpr (EVar "False")))))))))))
(DTypeSig false "lintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "lintTargets" ((PList)) (EListLit))
(DFunDef false "lintTargets" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "x")) (EApp (EVar "lintTargets") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EVar "lintTargets") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "assertSnapshotTargetsExist" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertSnapshotTargetsExist" ((PVar "files")) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EVar "filter") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "f"))))) (EVar "files"))) (DoExpr (EIf (EBinOp "==" (EVar "missing") (EListLit)) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: these targets do not exist:")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (EVar "missing"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))
(DTypeSig false "assertBlessIsScoped" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "assertBlessIsScoped" ((PVar "argv") (PVar "targets")) (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "hasFlag") (ELit (LString "--bless"))) (EVar "argv"))) (EBinOp "!=" (EVar "targets") (EListLit))) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: --bless requires explicit targets — there is no whole-suite bless.")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "  Name what you are approving, e.g.:")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "    medaka snapshot --bless --out test/snapshots/compiler compiler/frontend/lexer.mdk")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "  (or, family-aware:  sh test/diff_compiler_snapshot_frontend.sh --bless compiler/frontend/lexer.mdk)")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))
(DTypeSig false "runSnapshotCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runSnapshotCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "root") (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--root"))) (EVar "argv")) (arm (PCon "Some" (PVar "r")) () (EVar "r")) (arm (PCon "None") () (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))))) (DoLet false false (PVar "sel") (EApp (EVar "snapshotStages") (EVar "argv"))) (DoLet false false (PVar "targets") (EApp (EVar "snapshotTargets") (EVar "argv"))) (DoLet false false PWild (EApp (EApp (EVar "assertBlessIsScoped") (EVar "argv")) (EVar "targets"))) (DoLet false false (PVar "files") (EApp (EApp (EVar "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoLet false false PWild (EApp (EVar "assertSnapshotTargetsExist") (EVar "files"))) (DoExpr (EIf (EBinOp "==" (EVar "files") (EListLit)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka snapshot [--check|--new|--bless] [--out <dir>] [--stages <a,b,…>] <paths...>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EIf (EApp (EApp (EVar "hasFlag") (ELit (LString "--worker"))) (EVar "argv")) (EApp (EApp (EApp (EVar "runSnapshotWorker") (EVar "root")) (EVar "sel")) (EVar "files")) (EMatch (EApp (EVar "snapshotMode") (EVar "argv")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: pass --check (verify), --new (create missing snapshots) or --bless (rewrite existing ones)")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Some" (PVar "mode")) () (EBlock (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSnapshotSupervisor") (EVar "root")) (EVar "mode")) (EApp (EApp (EVar "hasFlag") (ELit (LString "--isolate"))) (EVar "argv"))) (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--out"))) (EVar "argv"))) (EVar "sel")) (EVar "files"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "exit") (ELit (LInt 1)))))))))))))
(DTypeSig false "snapshotMode" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "SnapMode")))))
(DFunDef false "snapshotMode" ((PVar "argv")) (EBlock (DoLet false false (PVar "modes") (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EApp (EVar "hasFlag") (EVar "f")) (EVar "argv")))) (EListLit (ELit (LString "--check")) (ELit (LString "--new")) (ELit (LString "--bless"))))) (DoExpr (EMatch (EVar "modes") (arm (PList (PLit (LString "--check"))) () (EApp (EVar "Some") (EVar "SnapCheck"))) (arm (PList (PLit (LString "--new"))) () (EApp (EVar "Some") (EVar "SnapNew"))) (arm (PList (PLit (LString "--bless"))) () (EApp (EVar "Some") (EVar "SnapBless"))) (arm (PList) () (EVar "None")) (arm (PVar "many") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka snapshot: ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "many")))) (ELit (LString " are mutually exclusive — pick one."))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EVar "None"))))))))
(DTypeSig false "snapshotStages" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
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
(DTypeSig false "dirOf2" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOf2" ((PVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirGo2" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirGo2" ((PVar "path") (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirGo2" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "replUsageLine" (TyCon "String"))
(DFunDef false "replUsageLine" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka repl — Start the interactive REPL\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka repl     Start an interactive session that reads expressions\n")) (ELit (LString "                 from stdin, evaluates them, and prints results until\n")) (ELit (LString "                 stdin closes (EOF) or you enter :quit.\n")))))
(DTypeSig false "runReplCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runReplCmd" ((PList)) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "preludeDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false PWild (EApp (EApp (EVar "initSession") (EVar "runtimeDecls")) (EVar "preludeDecls"))) (DoExpr (EApp (EVar "replLoop") (ELit LUnit)))))))))))
(DFunDef false "runReplCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runReplCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runReplCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka repl: unknown option '")) (EVar "bad")) (ELit (LString "'"))))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "lspUsageLine" (TyCon "String"))
(DFunDef false "lspUsageLine" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka lsp — Run the Language Server Protocol server over stdio\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka lsp     Start the server; it reads JSON-RPC requests from stdin\n")) (ELit (LString "                 and writes responses to stdout until stdin closes (EOF).\n")) (ELit (LString "                 This is the normal, correct behavior for an LSP stdio\n")) (ELit (LString "                 server — it is not supposed to be interactive.\n")))))
(DTypeSig false "runLspCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLspCmd" ((PList)) (EApp (EVar "runLspServerFromEnv") (ELit LUnit)))
(DFunDef false "runLspCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runLspCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runLspCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lsp: unknown option '")) (EVar "bad")) (ELit (LString "'"))))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "runLspServerFromEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLspServerFromEnv" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EApp (EApp (EVar "runServer") (EVar "rsrc")) (EVar "csrc")))))))))
(DTypeSig false "mcpUsage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "mcpUsage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka mcp — Run the MCP server over stdio (JSON-RPC for agents)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka mcp     Start the server; it reads JSON-RPC requests from stdin\n")) (ELit (LString "                 and writes responses to stdout until stdin closes (EOF).\n")) (ELit (LString "                 This is the normal, correct behavior for an MCP stdio\n")) (ELit (LString "                 server — it is not supposed to be interactive.\n"))))))
(DTypeSig false "runMcpCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runMcpCmd" ((PList)) (EApp (EVar "runMcpServerFromEnv") (ELit LUnit)))
(DFunDef false "runMcpCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "mcpUsage") (ELit LUnit))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runMcpCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "mcpUsage") (ELit LUnit))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runMcpCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka mcp: unknown argument '")) (EVar "bad")) (ELit (LString "' (mcp takes no arguments; try 'medaka mcp --help')"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "runMcpServerFromEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runMcpServerFromEnv" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EApp (EApp (EApp (EVar "runMcpServer") (EVar "rsrc")) (EVar "csrc")) (EVar "stdlibDir")))))))))
# MARK
(DUse false (UseGroup ("tools" "check") ((mem "runCheck" false) (mem "checkHasErrors" false) (mem "runCheckModules" false))))
(DUse false (UseGroup ("tools" "snapshot") ((mem "runSnapshotWorker" false) (mem "runSnapshotSupervisor" false) (mem "parseStages" false) (mem "SnapMode" true))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatSource" false))))
(DUse false (UseGroup ("tools" "new_cmd") ((mem "newProject" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "BuildResult" false) (mem "BuildOk" false) (mem "BuildErr" false) (mem "BuildTarget" false) (mem "TNative" false) (mem "TWasm" false) (mem "runBuild" false) (mem "emitRtObj" false) (mem "emitPreludeObj" false) (mem "envOr" false) (mem "defaultMedakaRoot" false) (mem "readPreludeFile" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinNl" false) (mem "joinWith" false) (mem "splitNl" false) (mem "startsWith" false) (mem "endsWith" false) (mem "anyList" false) (mem "filterList" false) (mem "contains" false) (mem "sortUniqS" false) (mem "schemeLineName" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("support" "path") ((mem "baseOf" false) (mem "chopExt" false) (mem "joinPath" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" false) (mem "LetBind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseWithPositions" false) (mem "parseResult" false) (mem "ParseError" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false) (mem "Positions" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "resolveModulesToHumane" false) (mem "resolveModulesToHumaneG" false) (mem "resolveModulesToHumaneGF" false) (mem "resolveModulesToHumaneByPath" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "LoadError" false) (mem "LoadMsg" false) (mem "LoadParseFailed" false) (mem "loadProgramE" false) (mem "loadProgramFilesLocatedE" false) (mem "findProjectRoot" false) (mem "entrySearchRoots" false) (mem "projectTrustedMods" false) (mem "unknownModuleIdOf" false) (mem "findImportLoc" false) (mem "availableModulesHint" false) (mem "availableModulesText" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "analyzeProject" false) (mem "analyzeLocated" false) (mem "analyzeLocatedG" false) (mem "ppDiagCli" false) (mem "ppDiagCliSrc" false) (mem "Diag" true) (mem "Severity" true) (mem "SevError" false) (mem "cjPosition" false) (mem "cjRange" false) (mem "cjRangeOfLoc" false) (mem "cjDiagnostic" false) (mem "cjFileEntry" false) (mem "cjAllToJson" false) (mem "readDiagSrc" false) (mem "parseErrCode" false) (mem "parseErrHelpFix" false) (mem "codeKind" false) (mem "optField" false) (mem "cjFixJson" false) (mem "mkDiag" false) (mem "checkJsonFile" false) (mem "readFileSafe" false) (mem "diagIsError" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JInt" false) (mem "JString" false) (mem "JArray" false) (mem "JObject" false) (mem "jObject" false) (mem "jArray" false) (mem "stringify" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "elaborateModules" false) (mem "resetTypeErrorsSticky" false) (mem "hadTypeErrors" false) (mem "mainTypeIsAsync" false) (mem "mainTypeIsUnit" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "evalModulesOutputRun" false) (mem "evalModulesOutputAsync" false) (mem "currentEvalFile" false) (mem "runJsonMode" false) (mem "progArgsRef" false))))
(DUse false (UseGroup ("tools" "test_cmd") ((mem "runTest" false))))
(DUse false (UseGroup ("tools" "repl") ((mem "initSession" false) (mem "replLoop" false))))
(DUse false (UseGroup ("tools" "lsp") ((mem "runServer" false))))
(DUse false (UseGroup ("tools" "mcp") ((mem "runMcpServer" false))))
(DUse false (UseGroup ("tools" "doc") ((mem "runDoc" false))))
(DUse false (UseGroup ("tools" "lint") ((mem "allRules" false) (mem "lintProgram" false) (mem "applySuppressions" false) (mem "applySuppressionsMulti" false) (mem "applySuppressionsDirs" false) (mem "applySuppressionsMultiDirs" false) (mem "collectDirectives" false) (mem "findingToDiag" false) (mem "Finding" false) (mem "Directive" false) (mem "applyFixes" false) (mem "runCrossFileRules" false) (mem "runCrossFileRulesFromOccs" false) (mem "crossFileCacheSound" false) (mem "fileDupOccs" false) (mem "parseLintFlagList" false) (mem "applyFindingFilters" false) (mem "applyFindingDeny" false) (mem "isFindingError" false) (mem "lintFileDiagTriple" false))))
(DUse false (UseGroup ("tools" "lint_cache") ((mem "LintEntry" true) (mem "contentHashOf" false) (mem "ruleSetStamp" false) (mem "cacheDirOf" false) (mem "loadEntry" false) (mem "storeEntries" false))))
(DUse false (UseGroup ("tools" "codemod") ((mem "findCodemod" false) (mem "codemodMk" false) (mem "codemodWarnDecls" false) (mem "codemodListing" false) (mem "codemodSource" false))))
(DUse false (UseGroup ("tools" "check_policy") ((mem "runCheckPolicy" false) (mem "runAcceptedPlugin" false) (mem "PolicyArgs" true) (mem "parsePolicyArgs" false) (mem "PolicyOutcome" true) (mem "runManifest" false) (mem "parseManifestArgs" false) (mem "ManifestArgs" true))))
(DTypeSig false "medakaVersion" (TyCon "String"))
(DFunDef false "medakaVersion" () (ELit (LString "0.1.0-preview")))
(DTypeSig false "printVersion" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printVersion" (PWild) (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "medaka ")) (EVar "medakaVersion"))))
(DTypeSig false "liveSourceFingerprint" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "liveSourceFingerprint" ((PVar "root")) (EBlock (DoLet false false (PVar "script") (EApp (EVar "stringConcat") (EListLit (ELit (LString "command -v perl >/dev/null 2>&1 || exit 7; cd \"")) (EVar "root") (ELit (LString "\" && find compiler -name '*.mdk' -print | LC_ALL=C sort")) (ELit (LString " | perl -ne 'chomp; print \"$_\\n\"; open F,\"<\",$_ or next; local $/; my $c=<F>; print $c if defined $c; close F' 2>/dev/null")) (ELit (LString " | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; elif command -v shasum >/dev/null 2>&1; then shasum -a 256; else cksum; fi; }")) (ELit (LString " | cut -d' ' -f1"))))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "sh"))) (EListLit (ELit (LString "-c")) (EVar "script"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "h") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "h") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (EVar "h")))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "checkSourceStaleness" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "checkSourceStaleness" (PWild) (EBlock (DoLet false false (PVar "baked") (EApp (EVar "buildFingerprint") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "baked") (ELit (LString ""))) (ELit LUnit) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "compilerDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler")))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "compilerDir"))) (ELit LUnit) (EMatch (EApp (EVar "liveSourceFingerprint") (EVar "root")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "live")) () (EIf (EBinOp "==" (EVar "live") (EVar "baked")) (ELit LUnit) (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EBinOp "++" (ELit (LString "warning: this ./medaka was built from compiler source that differs from ")) (EVar "compilerDir")) (ELit (LString " — it may be stale; rebuild with 'make medaka'.")))) (DoExpr (EIf (EBinOp "!=" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_STRICT"))) (ELit (LString ""))) (ELit (LString ""))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EApp (EVar "ePutStrLn") (EVar "msg")))))))))))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoLet false false PWild (EApp (EVar "checkSourceStaleness") (ELit LUnit))) (DoExpr (EApp (EVar "runCli") (ELit LUnit)))))
(DTypeSig false "runCli" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCli" (PWild) (EMatch (EApp (EVar "args") (ELit LUnit)) (arm (PList) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--help")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "-h")) PWild) () (EApp (EVar "usage") (ELit LUnit))) (arm (PCons (PLit (LString "--version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "-v")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "version")) PWild) () (EApp (EVar "printVersion") (ELit LUnit))) (arm (PCons (PLit (LString "check")) (PVar "rest")) () (EApp (EVar "runCheckCmd") (EVar "rest"))) (arm (PCons (PLit (LString "fmt")) (PVar "rest")) () (EApp (EVar "runFmtCmd") (EVar "rest"))) (arm (PCons (PLit (LString "new")) (PVar "rest")) () (EApp (EVar "runNewCmd") (EVar "rest"))) (arm (PCons (PLit (LString "build")) (PVar "rest")) () (EApp (EVar "runBuildCmd") (EVar "rest"))) (arm (PCons (PLit (LString "run")) (PVar "rest")) () (EApp (EVar "runRunCmd") (EVar "rest"))) (arm (PCons (PLit (LString "test")) (PVar "rest")) () (EApp (EVar "runTestCmd") (EVar "rest"))) (arm (PCons (PLit (LString "snapshot")) (PVar "rest")) () (EApp (EVar "runSnapshotCmd") (EVar "rest"))) (arm (PCons (PLit (LString "doc")) (PVar "rest")) () (EApp (EVar "runDocCmd") (EVar "rest"))) (arm (PCons (PLit (LString "lint")) (PVar "rest")) () (EApp (EVar "runLintCmd") (EVar "rest"))) (arm (PCons (PLit (LString "codemod")) (PVar "rest")) () (EApp (EVar "runCodemodCmd") (EVar "rest"))) (arm (PCons (PLit (LString "check-policy")) (PVar "rest")) () (EApp (EVar "runCheckPolicyCmd") (EVar "rest"))) (arm (PCons (PLit (LString "manifest")) (PVar "rest")) () (EApp (EVar "runManifestCmd") (EVar "rest"))) (arm (PCons (PLit (LString "repl")) (PVar "rest")) () (EApp (EVar "runReplCmd") (EVar "rest"))) (arm (PCons (PLit (LString "lsp")) (PVar "rest")) () (EApp (EVar "runLspCmd") (EVar "rest"))) (arm (PCons (PLit (LString "mcp")) (PVar "rest")) () (EApp (EVar "runMcpCmd") (EVar "rest"))) (arm (PCons (PVar "sub") PWild) () (EApp (EVar "notYet") (EMethodRef "sub")))))
(DTypeSig false "usage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "usage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka. A functional language compiler\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka                    Show this message\n")) (ELit (LString "  medaka run [--release] <file.mdk>   Type-check and run a program\n")) (ELit (LString "  medaka build <file.mdk> [-o <out>] [--keep-ir]  Compile to a native binary (LLVM + clang)\n")) (ELit (LString "  medaka check [--json] <file.mdk>    Type-check without running\n")) (ELit (LString "  medaka test [file.mdk]    Run doctests + prop tests\n")) (ELit (LString "  medaka bench [file.mdk]   Run bench declarations\n")) (ELit (LString "  medaka doc [file.mdk]     Generate Markdown documentation\n")) (ELit (LString "  medaka lint [paths...]    Lint files/dirs (style rules; --fix, --cache, --disable/--only/--deny=<rules,...>)\n")) (ELit (LString "  medaka codemod <name> [flags] [paths...]  Apply a named source-preserving AST transform (--write/--stdout)\n")) (ELit (LString "  medaka snapshot [--check|--new|--bless] [paths...]  Per-stage snapshot tests (--out <dir>, --stages <a,b,..>)\n")) (ELit (LString "  medaka fmt [paths...]     Format .mdk files in place (or --check)\n")) (ELit (LString "  medaka new <name>         Scaffold a new project directory\n")) (ELit (LString "  medaka repl               Start an interactive REPL (reads stdin until EOF or :quit)\n")) (ELit (LString "  medaka lsp                Run the language server over stdio\n")) (ELit (LString "  medaka mcp                Run the MCP server over stdio (JSON-RPC for agents)\n")) (ELit (LString "  medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]  Check a plugin's inferred effects against an allow-list\n")) (ELit (LString "  medaka manifest <file.mdk> [--fn name]  Emit the verified capability manifest as TOML\n")) (ELit (LString "  medaka help               Show this message\n")) (ELit (LString "  medaka --version          Show the compiler version\n"))))))
(DTypeSig false "notYet" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "notYet" ((PVar "sub")) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka: subcommand '")) (EMethodRef "sub")) (ELit (LString "' not yet in native CLI"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "ppParseError" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "ppParseError" ((PVar "src") (PVar "file") (PVar "e")) (EBlock (DoLet false false (PVar "ploc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EApp (EVar "parseErrorCol") (EVar "e"))) (EApp (EVar "parseErrorLine") (EVar "e"))) (EBinOp "+" (EApp (EVar "parseErrorCol") (EVar "e")) (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "h") (PVar "fx")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoExpr (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "file")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (EApp (EVar "parseErrorMessage") (EVar "e"))) (EApp (EVar "Some") (EVar "ploc"))) (EVar "h")) (EVar "fx"))))))
(DTypeSig false "runCheckCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCheckCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false (PVar "typesMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--types"))) (EVar "argv"))) (DoLet false false (PVar "argv2") (EApp (EVar "dropFlags") (EVar "argv"))) (DoExpr (EMatch (EVar "argv2") (arm (PList (PVar "target")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EIf (EVar "jsonMode") (EApp (EApp (EApp (EApp (EApp (EVar "runCheckJsonCmd") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "target")) (EVar "stdlibDir")) (EVar "lerr")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "modsWithPath")) () (EBlock (DoLet false false (PVar "mods") (EApp (EApp (EMethodRef "map") (EVar "dropModPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "pathMap") (EApp (EApp (EMethodRef "map") (EVar "modIdToPath")) (EVar "modsWithPath"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkRoute") (EVar "typesMode")) (EVar "allowInternal")) (EVar "trusted")) (EVar "pathMap")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target")) (EVar "mods")))))))))))))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check [--json] [--types] [--allow-internal] <file.mdk>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DTypeSig false "moduleLoadErrText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "LoadError") (TyEffect ("IO") None (TyCon "String")))))))
(DFunDef false "moduleLoadErrText" (PWild PWild PWild (PCon "LoadParseFailed" (PVar "mpath") (PVar "msrc") (PVar "e"))) (EApp (EApp (EApp (EVar "ppParseError") (EVar "msrc")) (EVar "mpath")) (EVar "e")))
(DFunDef false "moduleLoadErrText" ((PVar "tsrc") (PVar "target") (PVar "stdlibDir") (PCon "LoadMsg" (PVar "lmsg"))) (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "lmsg")) (arm (PCon "Some" (PVar "mid")) () (EBlock (DoLet false false (PVar "msg") (EBinOp "++" (EVar "lmsg") (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "tsrc"))) (arm (PCon "None") () (EVar "msg")) (arm (PCon "Some" (PVar "loc")) () (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "msg")) (EApp (EVar "Some") (EVar "loc"))) (EVar "None")) (EVar "None"))))))))))
(DTypeSig false "locatedProjectErrors" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "locatedProjectErrors" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EBlock (DoLet false false (PVar "cacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "cacheRef")) (EVar "parseCacheRef")) (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc"))) (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (EVar "readDiagSrc")) (EVar "results"))) (DoLet false false (PVar "rendered") (EApp (EApp (EDictApp "flatMap") (EVar "renderTripleErrors")) (EVar "triples"))) (DoExpr (EMatch (EVar "rendered") (arm (PList) () (EVar "None")) (arm PWild () (EApp (EVar "Some") (EApp (EVar "joinNl") (EVar "rendered"))))))))
(DTypeSig false "renderTripleErrors" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "renderTripleErrors" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "path"))) (EApp (EApp (EMethodRef "filter") (EVar "isDiagError")) (EVar "diags"))))
(DTypeSig false "locatedOrGeneric" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))))
(DFunDef false "locatedOrGeneric" ((PVar "target") (PVar "roots") (PVar "rsrc") (PVar "csrc")) (EMatch (EApp (EApp (EApp (EApp (EVar "locatedProjectErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "error: type error in ")) (EVar "target")) (ELit (LString ". Run `medaka check` for details"))))))
(DTypeSig false "checkRoute" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Unit")))))))))))))
(DFunDef false "checkRoute" ((PVar "typesMode") (PVar "allowInternal") (PVar "trusted") PWild PWild (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PList (PTuple (PVar "mid") (PVar "decls")))) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EMethodRef "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false (PVar "warns") (EApp (EApp (EMethodRef "filter") (EVar "isDiagWarn")) (EVar "diags"))) (DoLet false false (PVar "dump") (EApp (EVar "stripWarningLines") (EApp (EApp (EApp (EVar "runCheck") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")))) (DoLet false false (PVar "report") (EIf (EVar "typesMode") (EVar "dump") (EApp (EApp (EVar "userSchemeLines") (EVar "decls")) (EVar "dump")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "report"))) (DoLet false false (PVar "mainWarns") (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (EListLit (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "decls"))))) (EVar "decls"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EBinOp "++" (EVar "warns") (EVar "mainWarns")))) (DoExpr (ELit LUnit)))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target"))) (EVar "errs"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
(DFunDef false "checkRoute" ((PVar "typesMode") (PVar "allowInternal") (PVar "trusted") (PVar "pathMap") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "mods")) (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneByPath") (EVar "pathMap")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EMatch (EApp (EApp (EApp (EApp (EVar "locatedProjectErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PCon "Some" (PVar "errText")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "errText"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EApp (EApp (EApp (EApp (EVar "runCheckModules") (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD")))) (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple (PVar "emid") (PVar "edecls"))) () (EApp (EApp (EApp (EApp (EVar "mainShapeWarnings") (EVar "rtD")) (EVar "coreD")) (EVar "modsD")) (EVar "edecls"))) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EVar "tsrc")) (EVar "target")) (EVar "mainWarns"))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "resDiags"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))
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
(DTypeSig false "mainNonUnitWarning" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "Diag"))))
(DFunDef false "mainNonUnitWarning" ((PVar "decls")) (EMatch (EApp (EVar "findMainFunDef") (EVar "decls")) (arm (PCon "Some" (PTuple (PList) (PVar "body"))) () (EIf (EBinOp "||" (EApp (EVar "mainTypeIsUnit") (ELit LUnit)) (EApp (EVar "mainTypeIsAsync") (ELit LUnit))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevWarning")) (ELit (LString "W-MAIN-SHAPE"))) (EVar "mainNonUnitMsg")) (EApp (EVar "mainBodyLoc") (EVar "body")))))) (arm PWild () (EVar "None"))))
(DTypeSig false "mainShapeWarnings" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Diag")))))))
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
(DTypeSig false "runCheckJsonCmd" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "runCheckJsonCmd" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "stdlibDir")) (EBlock (DoLet false false (PTuple (PVar "json") (PVar "hasErr")) (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonFile") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "stdlibDir"))) (DoLet false false PWild (EApp (EDictApp "println") (EVar "json"))) (DoExpr (EIf (EVar "hasErr") (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))
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
(DTypeSig false "runFmtCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runFmtCmd" ((PVar "argv")) (EMatch (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "argv")) (EVar "FmtWrite")) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple PWild (PList))) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "Usage: medaka fmt [--check | --stdout | --write] <path>...")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PList (PVar "target")))) () (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Err" PWild) () (EApp (EApp (EVar "fmtOne") (EVar "mode")) (EVar "target"))) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EListLit (EVar "target")))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PVar "targets"))) () (EApp (EApp (EVar "fmtManyTargets") (EVar "mode")) (EVar "targets")))))
(DTypeSig false "fmtManyTargets" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "fmtManyTargets" ((PCon "FmtStdout") PWild) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka fmt: --stdout requires exactly one file")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DFunDef false "fmtManyTargets" ((PVar "mode") (PVar "targets")) (EBlock (DoLet false false (PVar "files") (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka fmt: no .mdk files found")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm PWild () (EIf (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "files")) (EVar "False")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))
(DTypeSig false "fmtFilesGo" (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "fmtFilesGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "fmtFilesGo" ((PVar "mode") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "hadErr") (EApp (EApp (EVar "fmtOneReport") (EVar "mode")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EVar "fmtFilesGo") (EVar "mode")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr"))))))
(DTypeSig false "fmtOneReport" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "fmtOneReport" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "formatted"))) (DoExpr (EVar "False")))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EVar "False") (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted"))))) (DoExpr (EVar "True"))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (EVar "False") (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EVar "False")))))))))))))
(DTypeSig false "parseFmtArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FmtMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "FmtMode") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "parseFmtArgs" ((PList) (PVar "mode") (PVar "acc")) (EApp (EVar "Ok") (ETuple (EVar "mode") (EApp (EVar "reverseL") (EVar "acc")))))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--check")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtCheck")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--stdout")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtStdout")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "--write")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtWrite")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PLit (LString "-w")) (PVar "rest")) PWild (PVar "acc")) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "FmtWrite")) (EVar "acc")))
(DFunDef false "parseFmtArgs" ((PCons (PVar "x") (PVar "rest")) (PVar "mode") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "x")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "x")) (ELit (LString "-")))) (EApp (EVar "Err") (EBinOp "++" (ELit (LString "medaka fmt: unknown flag: ")) (EVar "x"))) (EApp (EApp (EApp (EVar "parseFmtArgs") (EVar "rest")) (EVar "mode")) (EBinOp "::" (EVar "x") (EVar "acc")))))
(DTypeSig false "fmtOne" (TyFun (TyCon "FmtMode") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "fmtOne" ((PVar "mode") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "formatted") (EApp (EVar "formatSource") (EVar "src"))) (DoExpr (EMatch (EVar "mode") (arm (PCon "FmtStdout") () (EApp (EVar "putStr") (EVar "formatted"))) (arm (PCon "FmtCheck") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EVar "file") (ELit (LString ": not formatted"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))) (arm (PCon "FmtWrite") () (EIf (EBinOp "==" (EVar "formatted") (EVar "src")) (ELit LUnit) (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "formatted")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" PWild) () (ELit LUnit)))))))))))))
(DData Private "CodeMode" () ((variant "CmDry" (ConPos)) (variant "CmWrite" (ConPos)) (variant "CmStdout" (ConPos))) ())
(DTypeSig false "runCodemodCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCodemodCmd" ((PList)) (EApp (EVar "listCodemodsAndExit") (ELit LUnit)))
(DFunDef false "runCodemodCmd" ((PCons (PVar "name") (PVar "rest"))) (EMatch (EApp (EVar "findCodemod") (EVar "name")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod: unknown codemod '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "'"))))) (DoExpr (EApp (EVar "listCodemodsAndExit") (ELit LUnit))))) (arm (PCon "Some" (PVar "cm")) () (EMatch (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmDry")) (EListLit)) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PTuple (PVar "mode") (PVar "cargs") (PVar "targets"))) () (EMatch (EApp (EApp (EVar "codemodMk") (EVar "cm")) (EVar "cargs")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PVar "xf")) () (EBlock (DoLet false false (PVar "files") (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka codemod: no .mdk files found")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm PWild () (EMatch (EVar "mode") (arm (PCon "CmStdout") () (EMatch (EVar "files") (arm (PList (PVar "one")) () (EApp (EApp (EApp (EVar "codemodStdout") (EVar "xf")) (EApp (EApp (EVar "codemodWarnDecls") (EVar "cm")) (EVar "cargs"))) (EVar "one"))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka codemod: --stdout requires exactly one file")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))))) (arm PWild () (EIf (EApp (EApp (EApp (EApp (EApp (EVar "codemodFilesGo") (EVar "mode")) (EVar "xf")) (EApp (EApp (EVar "codemodWarnDecls") (EVar "cm")) (EVar "cargs"))) (EVar "files")) (EVar "False")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))))))))))
(DTypeSig false "listCodemodsAndExit" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "listCodemodsAndExit" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "Usage: medaka codemod <name> [flags] [--write|--stdout] <paths...>")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "Available codemods:")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "codemodListing"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DTypeSig false "splitCodemodArgv" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CodeMode") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "CodeMode") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "splitCodemodArgv" ((PList) (PVar "mode") (PVar "cargs") (PVar "paths")) (EApp (EVar "Ok") (ETuple (EVar "mode") (EApp (EVar "reverseL") (EVar "cargs")) (EApp (EVar "reverseL") (EVar "paths")))))
(DFunDef false "splitCodemodArgv" ((PCons (PLit (LString "--write")) (PVar "rest")) PWild (PVar "cargs") (PVar "paths")) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmWrite")) (EVar "cargs")) (EVar "paths")))
(DFunDef false "splitCodemodArgv" ((PCons (PLit (LString "--stdout")) (PVar "rest")) PWild (PVar "cargs") (PVar "paths")) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "CmStdout")) (EVar "cargs")) (EVar "paths")))
(DFunDef false "splitCodemodArgv" ((PCons (PVar "tok") (PVar "rest")) (PVar "mode") (PVar "cargs") (PVar "paths")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "tok")) (EMatch (EVar "rest") (arm (PCons (PVar "v") (PVar "rest2")) () (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest2")) (EVar "mode")) (EBinOp "::" (EVar "v") (EBinOp "::" (EVar "tok") (EVar "cargs")))) (EVar "paths"))) (arm (PList) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka codemod: flag '")) (EApp (EMethodRef "display") (EVar "tok"))) (ELit (LString "' requires a value")))))) (EApp (EApp (EApp (EApp (EVar "splitCodemodArgv") (EVar "rest")) (EVar "mode")) (EVar "cargs")) (EBinOp "::" (EVar "tok") (EVar "paths")))))
(DTypeSig false "codemodStdout" (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "codemodStdout" ((PVar "xf") (PVar "warnFn") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2)))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EVar "codemodSource") (EVar "xf")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "result")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "emitCodemodWarns") (EVar "warnFn")) (EVar "file")) (EVar "src"))) (DoExpr (EMatch (EVar "result") (arm (PCon "None") () (EApp (EVar "putStr") (EVar "src"))) (arm (PCon "Some" (PVar "out")) () (EApp (EVar "putStr") (EVar "out")))))))))))
(DTypeSig false "codemodFilesGo" (TyFun (TyCon "CodeMode") (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "codemodFilesGo" (PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "codemodFilesGo" ((PVar "mode") (PVar "xf") (PVar "warnFn") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "signal") (EApp (EApp (EApp (EApp (EVar "codemodOneReport") (EVar "mode")) (EVar "xf")) (EVar "warnFn")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "codemodFilesGo") (EVar "mode")) (EVar "xf")) (EVar "warnFn")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "signal"))))))
(DTypeSig false "codemodOneReport" (TyFun (TyCon "CodeMode") (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "codemodOneReport" ((PVar "mode") (PVar "xf") (PVar "warnFn") (PVar "file")) (EMatch (EApp (EVar "readFile") (EVar "file")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EApp (EVar "codemodSource") (EVar "xf")) (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EVar "src")) (EVar "file")) (EVar "e")))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "result")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "emitCodemodWarns") (EVar "warnFn")) (EVar "file")) (EVar "src"))) (DoExpr (EMatch (EVar "result") (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "out")) () (EMatch (EVar "mode") (arm (PCon "CmWrite") () (EMatch (EApp (EApp (EVar "writeFile") (EVar "file")) (EVar "out")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EVar "False")))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "would rewrite: ")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ""))))) (DoExpr (EVar "True"))))))))))))))
(DTypeSig false "emitCodemodWarns" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitCodemodWarns" ((PVar "warnFn") (PVar "file") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "decls") PWild) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoExpr (EApp (EApp (EVar "emitWarnLines") (EVar "file")) (EApp (EVar "warnFn") (EVar "decls"))))))
(DTypeSig false "emitWarnLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitWarnLines" (PWild (PList)) (ELit LUnit))
(DFunDef false "emitWarnLines" ((PVar "file") (PCons (PVar "w") (PVar "ws"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ": warning: "))) (EApp (EMethodRef "display") (EVar "w"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EVar "emitWarnLines") (EVar "file")) (EVar "ws")))))
(DTypeSig false "newUsageLine" (TyCon "String"))
(DFunDef false "newUsageLine" () (ELit (LString "Usage: medaka new <name>")))
(DTypeSig false "runNewCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runNewCmd" ((PList (PVar "arg"))) (EIf (EBinOp "||" (EBinOp "==" (EVar "arg") (ELit (LString "--help"))) (EBinOp "==" (EVar "arg") (ELit (LString "-h")))) (EApp (EVar "putStrLn") (EVar "newUsageLine")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "arg")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "arg")) (ELit (LString "-")))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka new: unknown option '")) (EVar "arg")) (ELit (LString "'"))))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "newUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))) (EBlock (DoLet false false (PVar "code") (EApp (EVar "newProject") (EVar "arg"))) (DoExpr (EIf (EBinOp "==" (EVar "code") (ELit (LInt 0))) (ELit LUnit) (EApp (EVar "exit") (EVar "code"))))))))
(DFunDef false "runNewCmd" (PWild) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "newUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 2))))))
(DTypeSig false "runBuildCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runBuildCmd" ((PVar "argv")) (EIf (EBinOp "||" (EApp (EApp (EVar "hasFlag") (ELit (LString "--help"))) (EVar "argv")) (EApp (EApp (EVar "hasFlag") (ELit (LString "-h"))) (EVar "argv"))) (EApp (EVar "buildUsage") (ELit LUnit)) (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--emit-rt-obj"))) (EVar "argv")) (arm (PCon "Some" (PVar "objPath")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "emitRtObj") (EVar "cc")) (EVar "root")) (EVar "objPath")) (arm (PCon "BuildOk" (PVar "msg")) () (EApp (EDictApp "println") (EVar "msg"))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--emit-prelude-obj"))) (EVar "argv")) (arm (PCon "Some" (PVar "objPath")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "./medaka")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "emitPreludeObj") (EVar "cc")) (EVar "root")) (EVar "medaka")) (EVar "objPath")) (arm (PCon "BuildOk" (PVar "msg")) () (EApp (EDictApp "println") (EVar "msg"))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))) (arm (PCon "None") () (EMatch (EApp (EVar "parseBuildArgs") (EVar "argv")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PTuple (PVar "input") (PVar "outOpt") (PVar "target"))) () (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "input"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (ELit (LString "error: no such file: ")) (EVar "input")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "medaka") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA"))) (ELit (LString "medaka")))) (DoLet false false (PVar "cc") (EApp (EApp (EVar "envOr") (ELit (LString "CC"))) (ELit (LString "clang")))) (DoLet false false (PVar "inputAbs") (EVar "input")) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false (PVar "keepIrCli") (EApp (EApp (EVar "hasFlag") (ELit (LString "--keep-ir"))) (EVar "argv"))) (DoLet false false (PVar "outPath") (EMatch (EVar "outOpt") (arm (PCon "Some" (PVar "o")) () (EVar "o")) (arm (PCon "None") () (EApp (EApp (EVar "defaultOutPath") (EVar "target")) (EVar "input"))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "typecheckGate") (EVar "allowInternal")) (EVar "root")) (EVar "inputAbs")) (arm (PCon "TGErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "TGOk") () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuild") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "target")) (EVar "inputAbs")) (EVar "outPath")) (EVar "keepIrCli")) (arm (PCon "BuildOk" (PVar "msg")) () (EApp (EDictApp "println") (EVar "msg"))) (arm (PCon "BuildErr" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))))))))))))
(DTypeSig false "buildUsage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "buildUsage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "usage: medaka build [--target native|wasm] <file.mdk> [-o <out>] [--keep-ir] [--allow-internal]\n")) (ELit (LString "\n")) (ELit (LString "  -o <out>          output path for the binary (default: <file> with its extension dropped)\n")) (ELit (LString "  --target <t>      backend: native (LLVM + clang, default) or wasm (WasmGC + wasm-tools)\n")) (ELit (LString "  --keep-ir         keep the emitted IR (.ll for native, .wat for wasm) at <out>.ll/.wat\n")) (ELit (LString "                    instead of discarding it with the build's scratch directory; the\n")) (ELit (LString "                    kept path is printed. Env var MEDAKA_KEEP_IR=1 does the same for a\n")) (ELit (LString "                    build invoked by something else (e.g. a test harness)\n")) (ELit (LString "  --allow-internal  permit internal-only externs outside stdlib/\n")) (ELit (LString "  --emit-rt-obj <p> compile only runtime/medaka_rt.c to a reusable object at <p> (with\n")) (ELit (LString "                    the same flags a normal link uses) and exit; point MEDAKA_RT_OBJ at\n")) (ELit (LString "                    it to skip recompiling the runtime on every subsequent build\n")) (ELit (LString "  --emit-prelude-obj <p>\n")) (ELit (LString "                    compile only stdlib/core.mdk to a reusable object at <p> (with the\n")) (ELit (LString "                    same flags a normal link uses) and exit; point MEDAKA_PRELUDE_OBJ at\n")) (ELit (LString "                    it to skip re-optimising the prelude on every subsequent build.\n")) (ELit (LString "                    Opt-in: separate objects cannot inline the prelude into user code\n"))))))
(DTypeSig false "defaultOutPath" (TyFun (TyCon "BuildTarget") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "defaultOutPath" ((PCon "TNative") (PVar "input")) (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))))
(DFunDef false "defaultOutPath" ((PCon "TWasm") (PVar "input")) (EBinOp "++" (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "input"))) (ELit (LString ".wasm"))))
(DData Private "TypecheckGate" () ((variant "TGOk" (ConPos)) (variant "TGErr" (ConPos (TyCon "String")))) ())
(DTypeSig false "typecheckGate" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "TypecheckGate"))))))
(DFunDef false "typecheckGate" ((PVar "allowInternal") (PVar "root") (PVar "input")) (EBlock (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "input"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "input")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "TGErr") (EVar "msg"))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EVar "parseResult") (EVar "tsrc")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "TGErr") (EApp (EApp (EApp (EVar "ppParseError") (EVar "tsrc")) (EVar "input")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "loadProgramE") (EVar "input")) (EVar "roots")) (arm (PCon "Err" (PVar "lerr")) () (EApp (EVar "TGErr") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EVar "tsrc")) (EVar "input")) (EVar "stdlibDir")) (EVar "lerr")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "input")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typecheckGateRoute") (EVar "allowInternal")) (EVar "trusted")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "input")) (EVar "mods")))))))))))))))))
(DTypeSig false "typecheckGateRoute" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "TypecheckGate")))))))))))
(DFunDef false "typecheckGateRoute" ((PVar "allowInternal") (PVar "trusted") PWild (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PList (PTuple (PVar "mid") PWild))) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EMethodRef "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EVar "TGOk")) (arm PWild () (EApp (EVar "TGErr") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target"))) (EVar "errs")))))))))
(DFunDef false "typecheckGateRoute" ((PVar "allowInternal") (PVar "trusted") (PVar "roots") (PVar "rsrc") (PVar "csrc") (PVar "tsrc") (PVar "target") (PVar "mods")) (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneGF") (EVar "target")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EMatch (EApp (EApp (EApp (EApp (EVar "locatedProjectErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PCon "Some" (PVar "errText")) () (EApp (EVar "TGErr") (EVar "errText"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EApp (EVar "hadTypeErrors") (ELit LUnit)) (arm (PCon "True") () (EApp (EVar "TGErr") (EApp (EApp (EApp (EApp (EVar "locatedOrGeneric") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")))) (arm (PCon "False") () (EVar "TGOk")))))))) (arm PWild () (EApp (EVar "TGErr") (EVar "resDiags")))))))
(DTypeSig false "parseBuildArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))
(DFunDef false "parseBuildArgs" ((PVar "argv")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "argv")) (EListLit)) (EVar "None")) (EVar "TNative")))
(DTypeSig false "parseBuildGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget"))))))))
(DFunDef false "parseBuildGo" ((PList) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EVar "finishBuildArgs") (EApp (EVar "reverseL") (EVar "acc"))) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "-o")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EApp (EVar "Some") (EVar "v"))) (EVar "target")))
(DFunDef false "parseBuildGo" ((PList (PLit (LString "-o"))) PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: -o requires an argument"))))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--target")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc") (PVar "out") PWild) (EMatch (EApp (EVar "parseTarget") (EVar "v")) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PVar "t")) () (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "t")))))
(DFunDef false "parseBuildGo" ((PList (PLit (LString "--target"))) PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: --target requires an argument (native|wasm)"))))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--allow-internal")) (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PLit (LString "--keep-ir")) (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EVar "acc")) (EVar "out")) (EVar "target")))
(DFunDef false "parseBuildGo" ((PCons (PVar "x") (PVar "rest")) (PVar "acc") (PVar "out") (PVar "target")) (EApp (EApp (EApp (EApp (EVar "parseBuildGo") (EVar "rest")) (EBinOp "::" (EVar "x") (EVar "acc"))) (EVar "out")) (EVar "target")))
(DTypeSig false "parseTarget" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "BuildTarget"))))
(DFunDef false "parseTarget" ((PLit (LString "native"))) (EApp (EVar "Ok") (EVar "TNative")))
(DFunDef false "parseTarget" ((PLit (LString "wasm"))) (EApp (EVar "Ok") (EVar "TWasm")))
(DFunDef false "parseTarget" ((PVar "other")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "error: unknown --target '")) (EVar "other")) (ELit (LString "' (expected native|wasm)")))))
(DTypeSig false "finishBuildArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "BuildTarget") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyCon "BuildTarget")))))))
(DFunDef false "finishBuildArgs" ((PList) PWild PWild) (EApp (EVar "Err") (ELit (LString "usage: medaka build [--target native|wasm] <file.mdk> [-o <out>]"))))
(DFunDef false "finishBuildArgs" ((PList (PVar "input")) (PVar "out") (PVar "target")) (EApp (EVar "Ok") (ETuple (EVar "input") (EVar "out") (EVar "target"))))
(DFunDef false "finishBuildArgs" (PWild PWild PWild) (EApp (EVar "Err") (ELit (LString "error: medaka build takes exactly one input file"))))
(DTypeSig false "finishRunEval" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "finishRunEval" ((PVar "target") (PVar "jsonMode") (PVar "elaborated") (PVar "mods")) (EBlock (DoLet false false (PVar "mainWarns") (EMatch (EApp (EVar "lastModPair") (EVar "mods")) (arm (PCon "Some" (PTuple PWild (PVar "edecls"))) () (EMatch (EApp (EVar "mainArityWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EMatch (EApp (EVar "mainNonUnitWarning") (EVar "edecls")) (arm (PCon "Some" (PVar "d")) () (EListLit (EVar "d"))) (arm (PCon "None") () (EListLit)))))) (arm (PCon "None") () (EListLit)))) (DoLet false false PWild (EApp (EApp (EApp (EVar "emitLocatedWarnings") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "mainWarns"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "currentEvalFile")) (EVar "target"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "runJsonMode")) (EVar "jsonMode"))) (DoExpr (EApp (EVar "putStr") (EApp (EApp (EVar "runProgramOutput") (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))))))
(DTypeSig false "runRunCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runRunCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoExpr (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka run [--release] [--json] <file.mdk>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") (PVar "progArgs")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "allowInternal") (EApp (EApp (EVar "hasFlag") (ELit (LString "--allow-internal"))) (EVar "argv"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "progArgsRef")) (EVar "progArgs"))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "parseResult") (EApp (EVar "readFileSafe") (EVar "target"))) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EVar "ppParseError") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "e")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EMethodRef "map") (EApp (EMethodRef "map") (EVar "dropModPath"))) (EApp (EApp (EApp (EVar "loadProgramFilesLocatedE") (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots"))) (arm (PCon "Err" (PVar "lerr")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "moduleLoadErrText") (EApp (EVar "readFileSafe") (EVar "target"))) (EVar "target")) (EVar "stdlibDir")) (EVar "lerr")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "rtD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "coreD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false (PVar "modsD") (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods"))) (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoExpr (EMatch (EVar "modsD") (arm (PList PWild) () (EBlock (DoLet false false (PVar "tsrc") (EApp (EVar "readFileSafe") (EVar "target"))) (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc"))) (DoLet false false (PVar "errs") (EApp (EApp (EMethodRef "filter") (EVar "isDiagError")) (EVar "diags"))) (DoExpr (EMatch (EVar "errs") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EVar "elaborated")) (EVar "mods"))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppDiagCliSrc") (EVar "tsrc")) (EVar "target"))) (EVar "errs"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))) (arm PWild () (EBlock (DoLet false false (PVar "resDiags") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesToHumaneGF") (EVar "target")) (EVar "allowInternal")) (EVar "trusted")) (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EVar "resDiags") (arm (PLit (LString "")) () (EMatch (EApp (EApp (EApp (EApp (EVar "locatedProjectErrors") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")) (arm (PCon "Some" (PVar "errText")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "errText"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoExpr (EMatch (EApp (EVar "hadTypeErrors") (ELit LUnit)) (arm (PCon "True") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EApp (EApp (EApp (EVar "locatedOrGeneric") (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "False") () (EApp (EApp (EApp (EApp (EVar "finishRunEval") (EVar "target")) (EVar "jsonMode")) (EVar "elaborated")) (EVar "mods"))))))))) (arm PWild () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "resDiags"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))))))))))))))))))))))))
(DTypeSig false "desugarPair" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugarPair" ((PTuple (PVar "mid") (PVar "p"))) (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "p"))))
(DTypeSig false "dropModPath" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "dropModPath" ((PTuple (PVar "mid") PWild (PVar "prog"))) (ETuple (EVar "mid") (EVar "prog")))
(DTypeSig false "modIdToPath" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "modIdToPath" ((PTuple (PVar "mid") (PVar "path") PWild)) (ETuple (EVar "mid") (EVar "path")))
(DTypeSig false "runProgramOutput" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "runProgramOutput" ((PVar "preludeDecls") (PVar "modules")) (EMatch (EApp (EVar "mainTypeIsAsync") (ELit LUnit)) (arm (PCon "True") () (EApp (EApp (EVar "evalModulesOutputAsync") (EVar "preludeDecls")) (EVar "modules"))) (arm (PCon "False") () (EApp (EApp (EVar "evalModulesOutputRun") (EVar "preludeDecls")) (EVar "modules")))))
(DTypeSig false "runTestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runTestCmd" ((PVar "argv")) (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka test [file.mdk | dir]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PList (PVar "target")) () (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Err" PWild) () (EApp (EVar "runTestOne") (EVar "target"))) (arm (PCon "Ok" PWild) () (EApp (EVar "runTestManyTargets") (EListLit (EVar "target")))))) (arm (PVar "targets") () (EApp (EVar "runTestManyTargets") (EVar "targets")))))
(DTypeSig false "runTestOne" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runTestOne" ((PVar "target")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EVar "runTest") (EVar "rtPath")) (EVar "corePath")) (EVar "target")) (EVar "roots"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "exit") (ELit (LInt 1)))))))
(DTypeSig false "runTestManyTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runTestManyTargets" ((PVar "targets")) (EBlock (DoLet false false (PVar "files") (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoExpr (EMatch (EVar "files") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "medaka test: no .mdk files found")))) (DoExpr (ELit LUnit)))) (arm PWild () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EApp (EVar "testFilesGo") (EVar "rtPath")) (EVar "corePath")) (EVar "stdlibDir")) (EVar "files")) (EVar "False")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))))))
(DTypeSig false "testFilesGo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "testFilesGo" (PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "testFilesGo" ((PVar "rtPath") (PVar "corePath") (PVar "stdlibDir") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf2") (EVar "f"))) (EListLit (EVar "stdlibDir")))) (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EVar "runTest") (EVar "rtPath")) (EVar "corePath")) (EVar "f")) (EVar "roots"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "testFilesGo") (EVar "rtPath")) (EVar "corePath")) (EVar "stdlibDir")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EApp (EVar "not") (EVar "ok")))))))
(DTypeSig false "runDocCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runDocCmd" ((PVar "argv")) (EMatch (EApp (EVar "dropFlags") (EVar "argv")) (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka doc [file.mdk]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCons (PVar "target") PWild) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runDoc") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "target"))))))))))))))
(DTypeSig false "runCheckPolicyCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runCheckPolicyCmd" ((PVar "argv")) (EMatch (EApp (EVar "parsePolicyArgs") (EVar "argv")) (arm (PCon "PolicyArgs" (PCon "None") PWild PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka check-policy <file.mdk> [--allow L1,L2,...] [--fn name]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "PolicyArgs" (PCon "Some" (PVar "target")) (PVar "allow") (PVar "fn")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "runCheckPolicy") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "allow")) (EVar "fn")) (arm (PCon "PolicyReject" (PVar "report")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "report"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "PolicyAccept" (PVar "header") (PVar "pluginFn") (PVar "coreD") (PVar "rtD") (PVar "userD")) () (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EVar "header"))) (DoExpr (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runAcceptedPlugin") (EVar "pluginFn")) (EVar "coreD")) (EVar "rtD")) (EVar "userD"))))))))))))))))))
(DTypeSig false "runManifestCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runManifestCmd" ((PVar "argv")) (EMatch (EApp (EVar "parseManifestArgs") (EVar "argv")) (arm (PCon "ManifestArgs" (PCon "None") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka manifest <file.mdk> [--fn name]")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "ManifestArgs" (PCon "Some" (PVar "target")) (PVar "fn")) () (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "tsrc")) () (EApp (EVar "putStr") (EApp (EApp (EApp (EApp (EVar "runManifest") (EVar "rsrc")) (EVar "csrc")) (EVar "tsrc")) (EVar "fn"))))))))))))))
(DTypeSig false "runLintCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLintCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "disableNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--disable="))) (EVar "argv"))) (DoLet false false (PVar "onlyNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--only="))) (EVar "argv"))) (DoLet false false (PVar "denyNames") (EApp (EApp (EVar "parseLintFlagList") (ELit (LString "--deny="))) (EVar "argv"))) (DoLet false false (PVar "fixMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--fix"))) (EVar "argv"))) (DoLet false false (PVar "jsonMode") (EApp (EApp (EVar "hasFlag") (ELit (LString "--json"))) (EVar "argv"))) (DoLet false false (PVar "fileArgs") (EApp (EVar "lintTargets") (EVar "argv"))) (DoLet false false (PVar "files") (EApp (EVar "resolveLintTargets") (EVar "fileArgs"))) (DoExpr (EIf (EVar "jsonMode") (EApp (EApp (EApp (EApp (EVar "runLintJsonCmd") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "files")) (EBlock (DoLet false false (PVar "multiFile") (EMatch (EVar "files") (arm (PCons PWild (PCons PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False")))) (DoLet false false (PVar "cacheCtx") (EApp (EApp (EVar "lintCacheCtx") (EApp (EApp (EVar "hasFlag") (ELit (LString "--cache"))) (EVar "argv"))) (EVar "fixMode"))) (DoLet false false (PTuple (PVar "perFileErr") (PVar "entries") (PVar "parsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "files")) (EVar "False"))) (DoLet false false (PVar "crossErr") (EIf (EApp (EVar "not") (EBinOp "&&" (EVar "multiFile") (EApp (EVar "not") (EVar "fixMode")))) (EVar "False") (EMatch (EVar "cacheCtx") (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "runCrossFileReportCached") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "entries"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "runCrossFileReport") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "parsed")))))) (DoLet false false PWild (EMatch (EVar "cacheCtx") (arm (PCon "Some" (PTuple (PVar "cacheDir") (PVar "stamp"))) () (EApp (EApp (EApp (EVar "storeEntries") (EVar "cacheDir")) (EVar "stamp")) (EVar "entries"))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EIf (EBinOp "||" (EVar "perFileErr") (EVar "crossErr")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit))))))))
(DTypeSig false "lintCacheCtx" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "lintCacheCtx" ((PCon "False") PWild) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "True")) (EVar "None"))
(DFunDef false "lintCacheCtx" ((PCon "True") (PCon "False")) (EIf (EApp (EVar "not") (EVar "crossFileCacheSound")) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "root") (EApp (EVar "findProjectRoot") (EApp (EVar "canonicalizePath") (ELit (LString "."))))) (DoLet false false (PVar "stamp") (EApp (EVar "ruleSetStamp") (ELit LUnit))) (DoExpr (EIf (EBinOp "==" (EVar "stamp") (ELit (LString ""))) (EVar "None") (EApp (EVar "Some") (ETuple (EApp (EVar "cacheDirOf") (EVar "root")) (EVar "stamp")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runLintJsonCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "runLintJsonCmd" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "files")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagTriples") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "files"))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "cjAllToJson") (EVar "triples")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (EVar "cjLintTripleHasErr")) (EVar "triples")) (EApp (EVar "exit") (ELit (LInt 1))) (ELit LUnit)))))
(DTypeSig false "lintFilesToDiagTriples" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "lintFilesToDiagTriples" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "lintFilesToDiagTriples" ((PVar "disable") (PVar "only") (PVar "deny") (PCons (PVar "f") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "lintFileDiagTriple") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "f")) (EApp (EApp (EApp (EApp (EVar "lintFilesToDiagTriples") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "rest"))))
(DTypeSig false "cjLintTripleHasErr" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "cjLintTripleHasErr" ((PTuple PWild PWild (PVar "diags"))) (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags")))
(DTypeSig false "runCrossFileReport" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runCrossFileReport" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "parsed")) (EBlock (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (EVar "parsedToTriple")) (EVar "parsed"))) (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRules") (EVar "onlyNames")) (EVar "disableNames")) (EVar "triples"))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMulti") (EApp (EApp (EMethodRef "map") (EVar "parsedToSrc")) (EVar "parsed"))) (EVar "raw"))) (DoExpr (EApp (EVar "reportCrossFindings") (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed"))))))
(DTypeSig false "runCrossFileReportCached" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "LintEntry")) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runCrossFileReportCached" ((PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "entries")) (EBlock (DoLet false false (PVar "raw") (EApp (EApp (EApp (EVar "runCrossFileRulesFromOccs") (EVar "onlyNames")) (EVar "disableNames")) (EApp (EApp (EDictApp "flatMap") (EVar "entryOccs")) (EVar "entries")))) (DoLet false false (PVar "suppressed") (EApp (EApp (EVar "applySuppressionsMultiDirs") (EApp (EApp (EMethodRef "map") (EVar "entryDirTable")) (EVar "entries"))) (EVar "raw"))) (DoExpr (EApp (EVar "reportCrossFindings") (EApp (EApp (EVar "applyFindingDeny") (EVar "denyNames")) (EVar "suppressed"))))))
(DTypeSig false "entryOccs" (TyFun (TyCon "LintEntry") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))))
(DFunDef false "entryOccs" ((PVar "e")) (EFieldAccess (EVar "e") "dupOccs"))
(DTypeSig false "entryDirTable" (TyFun (TyCon "LintEntry") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))))
(DFunDef false "entryDirTable" ((PVar "e")) (ETuple (EFieldAccess (EVar "e") "path") (EFieldAccess (EVar "e") "directives")))
(DTypeSig false "reportCrossFindings" (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "reportCrossFindings" ((PList)) (EVar "False"))
(DFunDef false "reportCrossFindings" ((PVar "findings")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "cross-file:")))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "renderCrossFinding")) (EVar "findings"))))) (DoExpr (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")))))
(DTypeSig false "renderCrossFinding" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "renderCrossFinding" ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (ELit (LString ""))) (EApp (EVar "locFileOf") (EFieldAccess (EVar "f") "loc"))) (EApp (EVar "findingToDiag") (EVar "f"))))
(DTypeSig false "locFileOf" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locFileOf" ((PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild))) (EVar "file"))
(DFunDef false "locFileOf" ((PCon "None")) (ELit (LString "")))
(DTypeSig false "parsedToTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "parsedToTriple" ((PTuple (PVar "path") PWild (PVar "pos") (PVar "decls"))) (ETuple (EVar "path") (EVar "pos") (EVar "decls")))
(DTypeSig false "parsedToSrc" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "parsedToSrc" ((PTuple (PVar "path") (PVar "src") PWild PWild)) (ETuple (EVar "path") (EVar "src")))
(DTypeSig false "resolveLintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "resolveLintTargets" ((PList)) (EBlock (DoLet false false (PVar "cwd") (EApp (EVar "canonicalizePath") (ELit (LString ".")))) (DoLet false false (PVar "root") (EApp (EVar "findProjectRoot") (EVar "cwd"))) (DoExpr (EIf (EApp (EVar "not") (EApp (EVar "fileExists") (EBinOp "++" (EVar "root") (ELit (LString "/medaka.toml"))))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka lint: no medaka.toml found; run from a project directory or pass file/dir paths")))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EListLit))) (EApp (EVar "collectMdkFiles") (EVar "root"))))))
(DFunDef false "resolveLintTargets" ((PVar "targets")) (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets")))
(DTypeSig false "expandLintTarget" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "expandLintTarget" ((PVar "target")) (EMatch (EApp (EVar "listDir") (EVar "target")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFiles") (EVar "target"))) (arm (PCon "Err" PWild) () (EListLit (EVar "target")))))
(DTypeSig false "lintPathJoin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "lintPathJoin" ((PVar "dir") (PVar "name")) (EIf (EApp (EApp (EVar "endsWith") (ELit (LString "/"))) (EVar "dir")) (EBinOp "++" (EVar "dir") (EVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))))
(DTypeSig false "collectMdkFiles" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFiles" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lint: cannot list directory ")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EListLit)))) (arm (PCon "Ok" PWild) () (EApp (EVar "sortUniqS") (EApp (EVar "collectMdkFilesRec") (EVar "dir"))))))
(DTypeSig false "collectMdkFilesRec" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectMdkFilesRec" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EApp (EVar "filterNonDot") (EVar "entries"))))))
(DTypeSig false "collectMdkEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntries" (PWild (PList)) (EListLit))
(DFunDef false "collectMdkEntries" ((PVar "dir") (PCons (PVar "name") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "collectMdkEntry") (EVar "dir")) (EVar "name")) (EApp (EApp (EVar "collectMdkEntries") (EVar "dir")) (EVar "rest"))))
(DTypeSig false "collectMdkEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "collectMdkEntry" ((PVar "dir") (PVar "name")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "lintPathJoin") (EVar "dir")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Ok" PWild) () (EApp (EVar "collectMdkFilesRec") (EVar "full"))) (arm (PCon "Err" PWild) () (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "name")) (EListLit (EVar "full")) (EListLit)))))))
(DTypeSig false "filterNonDot" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterNonDot" ((PList)) (EListLit))
(DFunDef false "filterNonDot" ((PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (EApp (EVar "filterNonDot") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "n") (EApp (EVar "filterNonDot") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lintFilesGo" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))))
(DFunDef false "lintFilesGo" (PWild PWild PWild PWild PWild PWild (PList) (PVar "acc")) (ETuple (EVar "acc") (EListLit) (EListLit)))
(DFunDef false "lintFilesGo" ((PVar "fixMode") (PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "cacheCtx") (PCons (PVar "f") (PVar "rest")) (PVar "acc")) (EIf (EVar "fixMode") (EBlock (DoLet false false (PVar "hadErr") (EApp (EApp (EApp (EVar "lintOneFileFix") (EVar "onlyNames")) (EVar "disableNames")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr"))))) (EBlock (DoLet false false (PTuple (PVar "hadErr") (PVar "entries") (PVar "parsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintOneFileReport") (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "f"))) (DoLet false false (PTuple (PVar "restErr") (PVar "restEntries") (PVar "restParsed")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "lintFilesGo") (EVar "fixMode")) (EVar "multiFile")) (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "cacheCtx")) (EVar "rest")) (EBinOp "||" (EVar "acc") (EVar "hadErr")))) (DoExpr (ETuple (EVar "restErr") (EBinOp "++" (EVar "entries") (EVar "restEntries")) (EBinOp "++" (EVar "parsed") (EVar "restParsed")))))))
(DTypeSig false "lintOneFileReport" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LintEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))))))
(DFunDef false "lintOneFileReport" ((PVar "multiFile") (PVar "disableNames") (PVar "onlyNames") (PVar "denyNames") (PVar "cacheCtx") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (ETuple (EVar "True") (EListLit) (EListLit))))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "entry") (PVar "parsed")) (EApp (EApp (EApp (EVar "lintEntryOf") (EVar "cacheCtx")) (EVar "target")) (EVar "src"))) (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressionsDirs") (EFieldAccess (EVar "entry") "directives")) (EFieldAccess (EVar "entry") "findings"))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disableNames")) (EVar "onlyNames")) (EVar "denyNames")) (EVar "allFindings"))) (DoLet false false (PVar "output") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (EVar "src")) (EVar "target")) (EApp (EVar "findingToDiag") (EVar "f"))))) (EVar "findings")))) (DoLet false false (PVar "hasOutput") (EBinOp ">" (EApp (EVar "stringLength") (EVar "output")) (ELit (LInt 0)))) (DoLet false false PWild (EIf (EBinOp "&&" (EVar "multiFile") (EVar "hasOutput")) (EApp (EVar "putStrLn") (EBinOp "++" (EVar "target") (ELit (LString ":")))) (ELit LUnit))) (DoLet false false PWild (EIf (EVar "hasOutput") (EApp (EVar "putStrLn") (EVar "output")) (ELit LUnit))) (DoExpr (ETuple (EApp (EApp (EVar "anyList") (EVar "isFindingError")) (EVar "findings")) (EListLit (EVar "entry")) (EVar "parsed")))))))
(DTypeSig false "lintEntryOf" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "LintEntry") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "lintEntryOf" ((PCon "None") (PVar "target") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "entry") (PVar "pos") (PVar "decls")) (EApp (EApp (EApp (EApp (EVar "lintFileFresh") (EVar "target")) (EVar "src")) (ELit (LString ""))) (EVar "False"))) (DoExpr (ETuple (EVar "entry") (EListLit (ETuple (EVar "target") (EVar "src") (EVar "pos") (EVar "decls")))))))
(DFunDef false "lintEntryOf" ((PCon "Some" (PTuple (PVar "cacheDir") (PVar "stamp"))) (PVar "target") (PVar "src")) (EBlock (DoLet false false (PVar "hash") (EApp (EVar "contentHashOf") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "loadEntry") (EVar "cacheDir")) (EVar "stamp")) (EVar "target")) (EMethodRef "hash")) (arm (PCon "Some" (PVar "hit")) () (ETuple (EVar "hit") (EListLit))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "entry") PWild PWild) (EApp (EApp (EApp (EApp (EVar "lintFileFresh") (EVar "target")) (EVar "src")) (EMethodRef "hash")) (EVar "True"))) (DoExpr (ETuple (EVar "entry") (EListLit)))))))))
(DTypeSig false "lintFileFresh" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyTuple (TyCon "LintEntry") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "lintFileFresh" ((PVar "target") (PVar "src") (PVar "hash") (PVar "wantOccs")) (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoExpr (ETuple (ERecordCreate "LintEntry" ((fa "path" (EVar "target")) (fa "contentHash" (EMethodRef "hash")) (fa "findings" (EApp (EApp (EApp (EApp (EApp (EVar "lintProgram") (EVar "allRules")) (EVar "target")) (EVar "src")) (EVar "pos")) (EVar "decls"))) (fa "dupOccs" (EIf (EVar "wantOccs") (EApp (EVar "fileDupOccs") (ETuple (EVar "target") (EVar "pos") (EVar "decls"))) (EListLit))) (fa "directives" (EApp (EVar "collectDirectives") (EVar "src"))) (fa "dirty" (EVar "True")))) (EVar "pos") (EVar "decls")))))
(DTypeSig false "lintOneFileFix" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "lintOneFileFix" ((PVar "onlyNames") (PVar "disableNames") (PVar "target")) (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PTuple (PVar "newSrc") (PVar "n")) (EApp (EApp (EApp (EApp (EApp (EVar "applyFixes") (EVar "onlyNames")) (EVar "disableNames")) (EVar "src")) (EVar "decls")) (EVar "pos"))) (DoExpr (EIf (EBinOp "==" (EVar "newSrc") (EVar "src")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "fixed 0 finding(s) in ")) (EVar "target")))) (DoExpr (EVar "False"))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "target")) (EVar "newSrc")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 2)))) (DoExpr (EVar "True")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "fixed ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " finding(s) in "))) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ""))))) (DoExpr (EVar "False")))))))))))
(DTypeSig false "lintTargets" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "lintTargets" ((PList)) (EListLit))
(DFunDef false "lintTargets" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "x")) (EApp (EVar "lintTargets") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EVar "lintTargets") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "assertSnapshotTargetsExist" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "assertSnapshotTargetsExist" ((PVar "files")) (EBlock (DoLet false false (PVar "missing") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EVar "fileExists") (EVar "f"))))) (EVar "files"))) (DoExpr (EIf (EBinOp "==" (EVar "missing") (EListLit)) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: these targets do not exist:")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (EVar "missing"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))))
(DTypeSig false "assertBlessIsScoped" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "assertBlessIsScoped" ((PVar "argv") (PVar "targets")) (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "hasFlag") (ELit (LString "--bless"))) (EVar "argv"))) (EBinOp "!=" (EVar "targets") (EListLit))) (ELit LUnit) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: --bless requires explicit targets — there is no whole-suite bless.")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "  Name what you are approving, e.g.:")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "    medaka snapshot --bless --out test/snapshots/compiler compiler/frontend/lexer.mdk")))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "  (or, family-aware:  sh test/diff_compiler_snapshot_frontend.sh --bless compiler/frontend/lexer.mdk)")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))))
(DTypeSig false "runSnapshotCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runSnapshotCmd" ((PVar "argv")) (EBlock (DoLet false false (PVar "root") (EMatch (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--root"))) (EVar "argv")) (arm (PCon "Some" (PVar "r")) () (EVar "r")) (arm (PCon "None") () (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))))) (DoLet false false (PVar "sel") (EApp (EVar "snapshotStages") (EVar "argv"))) (DoLet false false (PVar "targets") (EApp (EVar "snapshotTargets") (EVar "argv"))) (DoLet false false PWild (EApp (EApp (EVar "assertBlessIsScoped") (EVar "argv")) (EVar "targets"))) (DoLet false false (PVar "files") (EApp (EApp (EDictApp "flatMap") (EVar "expandLintTarget")) (EVar "targets"))) (DoLet false false PWild (EApp (EVar "assertSnapshotTargetsExist") (EVar "files"))) (DoExpr (EIf (EBinOp "==" (EVar "files") (EListLit)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "usage: medaka snapshot [--check|--new|--bless] [--out <dir>] [--stages <a,b,…>] <paths...>")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))) (EIf (EApp (EApp (EVar "hasFlag") (ELit (LString "--worker"))) (EVar "argv")) (EApp (EApp (EApp (EVar "runSnapshotWorker") (EVar "root")) (EVar "sel")) (EVar "files")) (EMatch (EApp (EVar "snapshotMode") (EVar "argv")) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (ELit (LString "medaka snapshot: pass --check (verify), --new (create missing snapshots) or --bless (rewrite existing ones)")))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Some" (PVar "mode")) () (EBlock (DoLet false false (PVar "ok") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSnapshotSupervisor") (EVar "root")) (EVar "mode")) (EApp (EApp (EVar "hasFlag") (ELit (LString "--isolate"))) (EVar "argv"))) (EApp (EApp (EVar "snapFlagValue") (ELit (LString "--out"))) (EVar "argv"))) (EVar "sel")) (EVar "files"))) (DoExpr (EIf (EVar "ok") (ELit LUnit) (EApp (EVar "exit") (ELit (LInt 1)))))))))))))
(DTypeSig false "snapshotMode" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "SnapMode")))))
(DFunDef false "snapshotMode" ((PVar "argv")) (EBlock (DoLet false false (PVar "modes") (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EApp (EVar "hasFlag") (EVar "f")) (EVar "argv")))) (EListLit (ELit (LString "--check")) (ELit (LString "--new")) (ELit (LString "--bless"))))) (DoExpr (EMatch (EVar "modes") (arm (PList (PLit (LString "--check"))) () (EApp (EVar "Some") (EVar "SnapCheck"))) (arm (PList (PLit (LString "--new"))) () (EApp (EVar "Some") (EVar "SnapNew"))) (arm (PList (PLit (LString "--bless"))) () (EApp (EVar "Some") (EVar "SnapBless"))) (arm (PList) () (EVar "None")) (arm (PVar "many") () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka snapshot: ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "many")))) (ELit (LString " are mutually exclusive — pick one."))))) (DoLet false false PWild (EApp (EVar "exit") (ELit (LInt 1)))) (DoExpr (EVar "None"))))))))
(DTypeSig false "snapshotStages" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
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
(DTypeSig false "dirOf2" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dirOf2" ((PVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EApp (EVar "stringLength") (EVar "path"))))
(DTypeSig false "dirGo2" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "dirGo2" ((PVar "path") (PLit (LInt 0))) (ELit (LString ".")))
(DFunDef false "dirGo2" ((PVar "path") (PVar "i")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "i")) (EVar "path")) (ELit (LString "/"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "path")) (EApp (EApp (EVar "dirGo2") (EVar "path")) (EBinOp "-" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "replUsageLine" (TyCon "String"))
(DFunDef false "replUsageLine" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka repl — Start the interactive REPL\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka repl     Start an interactive session that reads expressions\n")) (ELit (LString "                 from stdin, evaluates them, and prints results until\n")) (ELit (LString "                 stdin closes (EOF) or you enter :quit.\n")))))
(DTypeSig false "runReplCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runReplCmd" ((PList)) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EBlock (DoLet false false (PVar "runtimeDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (DoLet false false (PVar "preludeDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (DoLet false false PWild (EApp (EApp (EVar "initSession") (EVar "runtimeDecls")) (EVar "preludeDecls"))) (DoExpr (EApp (EVar "replLoop") (ELit LUnit)))))))))))
(DFunDef false "runReplCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runReplCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runReplCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka repl: unknown option '")) (EVar "bad")) (ELit (LString "'"))))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "replUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "lspUsageLine" (TyCon "String"))
(DFunDef false "lspUsageLine" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka lsp — Run the Language Server Protocol server over stdio\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka lsp     Start the server; it reads JSON-RPC requests from stdin\n")) (ELit (LString "                 and writes responses to stdout until stdin closes (EOF).\n")) (ELit (LString "                 This is the normal, correct behavior for an LSP stdio\n")) (ELit (LString "                 server — it is not supposed to be interactive.\n")))))
(DTypeSig false "runLspCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLspCmd" ((PList)) (EApp (EVar "runLspServerFromEnv") (ELit LUnit)))
(DFunDef false "runLspCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runLspCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runLspCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka lsp: unknown option '")) (EVar "bad")) (ELit (LString "'"))))) (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "lspUsageLine"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "runLspServerFromEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runLspServerFromEnv" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EApp (EApp (EVar "runServer") (EVar "rsrc")) (EVar "csrc")))))))))
(DTypeSig false "mcpUsage" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "mcpUsage" (PWild) (EApp (EVar "putStrLn") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka mcp — Run the MCP server over stdio (JSON-RPC for agents)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka mcp     Start the server; it reads JSON-RPC requests from stdin\n")) (ELit (LString "                 and writes responses to stdout until stdin closes (EOF).\n")) (ELit (LString "                 This is the normal, correct behavior for an MCP stdio\n")) (ELit (LString "                 server — it is not supposed to be interactive.\n"))))))
(DTypeSig false "runMcpCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runMcpCmd" ((PList)) (EApp (EVar "runMcpServerFromEnv") (ELit LUnit)))
(DFunDef false "runMcpCmd" ((PCons (PLit (LString "--help")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "mcpUsage") (ELit LUnit))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runMcpCmd" ((PCons (PLit (LString "-h")) PWild)) (EBlock (DoLet false false PWild (EApp (EVar "mcpUsage") (ELit LUnit))) (DoExpr (EApp (EVar "exit") (ELit (LInt 0))))))
(DFunDef false "runMcpCmd" ((PCons (PVar "bad") PWild)) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka mcp: unknown argument '")) (EVar "bad")) (ELit (LString "' (mcp takes no arguments; try 'medaka mcp --help')"))))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DTypeSig false "runMcpServerFromEnv" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runMcpServerFromEnv" (PWild) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoLet false false (PVar "rtPath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/runtime.mdk")))) (DoLet false false (PVar "corePath") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib/core.mdk")))) (DoLet false false (PVar "stdlibDir") (EBinOp "++" (EVar "root") (ELit (LString "/stdlib")))) (DoExpr (EMatch (EApp (EVar "readPreludeFile") (EVar "rtPath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readPreludeFile") (EVar "corePath")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PVar "csrc")) () (EApp (EApp (EApp (EVar "runMcpServer") (EVar "rsrc")) (EVar "csrc")) (EVar "stdlibDir")))))))))
