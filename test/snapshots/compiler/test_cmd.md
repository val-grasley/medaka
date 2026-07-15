# META
source_lines=414
stages=DESUGAR,MARK
# SOURCE
-- compiler/test_cmd.mdk — `medaka test` logic (doctests + property tests),
-- factored out of test_main.mdk so BOTH the interpreted driver (test_main.mdk)
-- and the native CLI (medaka_cli.mdk's runTestCmd) share one implementation.
--
-- Exports:
--   runTest runtimeP coreP target roots   read the three sources + drive
--   rootsOrDefault target roots           default roots to [dirOf target]
--   dirOf path                            dirname on a POSIX path
--
-- Mirrors `./_build/default/bin/main.exe test <file.mdk>` byte-for-byte for the
-- doctest phase and (passing) prop phase:
--
--   running doctests in <file>
--     ok   <file>:<line>: <input>
--     FAIL <file>:<line>: <input>
--          expected: <e>
--            actual: <a>
--     ERROR <file>:<line>: <input>
--           <msg>
--   <blank>
--   <file>: P/T passed[ (F failed, E errors)]
--   Testing "<prop>" ... OK (100 tests)        -- prop phase, only if props exist
--   <blank>
--   N passed, M failed
--
-- The doctest/prop phases route EVERY file through the multi-module path
-- (DRIVER-COLLAPSE Phase 1+3): a no-import file uses the degenerate 1-module case
-- (elaborateOne/elaborateModules over [("__user__", decls)] + evalOne/
-- evalModulesRootEnv); an import-bearing file loads its real sibling graph
-- (loadProgram + elaborateModules + evalModules), so cross-module instances/values
-- resolve.  Neither path calls the flat elaborateDict/evalProgram anymore.

import frontend.ast.{Decl, DData, DInterface, Expr}
import frontend.parser.{parse, parseLocated}
import frontend.desugar.{desugar}
import driver.loader.{loadProgram}
import types.typecheck.{elaborateOne, elaborateModules}
import frontend.lexer.{collectComments}
import eval.eval.{
  Value,
  evalOneWith,
  evalModulesWith,
  evalModulesRootEnvWith,
  testCapableExterns,
  funNamesOf,
  dropShadowedExp,
}
import tools.doctest.{
  Example,
  ExResult(..),
  RunResult,
  extractExamples,
  buildSynthResults,
  buildSynthDecls,
  buildDetails,
  hasUseDecls,
  runDetails,
  runPassed,
  runFailed,
  runErrors,
  exampleInput,
  exampleLine,
  synthName,
}
import tools.prop_runner.{runAllProps, hasProps}
import tools.test_runner.{collectTests, runOneTest, hasTests}
import support.util.{listLen}
import support.path.{dirOf}

export rootsOrDefault : String -> List String -> List String
rootsOrDefault target [] = [dirOf target]
rootsOrDefault _ roots = roots

-- Returns True iff every doctest AND every prop passed (a read error, or a
-- file with zero tests, also returns True — vacuous/IO-error pass mirrors the
-- pre-existing printed behaviour; callers gate `exit 1` on this Bool rather
-- than on the printed report, since the report is prose, not a signal).
export runTest : String -> String -> String -> List String -> <IO> Bool
runTest runtimeP coreP target roots = match readFile runtimeP
  Err e =>
    let _ = ePutStrLn e
    True
  Ok rsrc => match readFile coreP
    Err e =>
      let _ = ePutStrLn e
      True
    Ok csrc => match readFile target
      Err e =>
        let _ = ePutStrLn e
        True
      Ok tsrc => driveAll (desugar (parse rsrc)) (desugar (parse csrc)) target tsrc roots

driveAll : List Decl -> List Decl -> String -> String -> List String -> <IO> Bool
driveAll runtimeDecls coreDecls target tsrc roots =
  let userDecls = desugar (parse tsrc)
  let doctestsOk = runDoctests runtimeDecls coreDecls target tsrc userDecls roots
  let propsOk = runProps runtimeDecls coreDecls target userDecls roots
  let testsOk = runTestDecls runtimeDecls coreDecls target tsrc userDecls roots
  doctestsOk && propsOk && testsOk

-- ── doctest phase ────────────────────────────────────────────────────────────

runDoctests : List Decl -> List Decl -> String -> String -> List Decl -> List String -> <IO> Bool
runDoctests runtimeDecls coreDecls target tsrc userDecls roots =
  let _ = putStrLn ("running doctests in " ++ target)
  let examples = extractExamples (collectComments tsrc)
  match examples
    [] =>
      let _ = putStrLn "  (no doctests found)"
      True
    _ =>
      let synthResults = buildSynthResults examples
      let synthDecls = buildSynthDecls synthResults
      let result = runChosen runtimeDecls coreDecls target userDecls roots examples synthDecls synthResults
      reportDoctests target result

runChosen : List Decl -> List Decl -> String -> List Decl -> List String -> List Example -> List Decl -> List (Result String (List Decl)) -> <IO> RunResult
runChosen runtimeDecls coreDecls target userDecls roots examples synthDecls synthResults
  | hasUseDecls userDecls = runMulti runtimeDecls coreDecls target userDecls roots examples synthDecls synthResults
  | otherwise =
    runSingle runtimeDecls coreDecls userDecls examples synthDecls synthResults

-- Single-file path: drop shadowed prelude, append synth, dict-elaborate, run.
-- When the file under test IS the prelude (`medaka test stdlib/core.mdk`), it
-- already declares everything the prelude provides, so prepending the prelude
-- would duplicate every top-level decl (two `Bounded Char` impls, etc.) and
-- corrupt return-position dispatch.  Mirror lib/doctest.ml's `program_is_core`
-- guard: skip the prelude prepend for core.
-- Single-file (no-import) path, DRIVER-COLLAPSE Phase 1+3: route the degenerate
-- no-import file through the SAME multi-module path as an import-bearing one — the
-- 1-module wrappers (elaborateOne → evalOne).  elaborateModules owns the dict-set
-- (its `moduleDictNames` return-position subset == coreDictNames's non-core case:
-- preludeReturnPosDictNames ++ the file's constrained sigs, arg-position helpers
-- excluded so the `neq`-hang stays closed).  livePrelude is the shadow-dropped core,
-- passed SEPARATE (elaborateOne folds it in); for `medaka test stdlib/core.mdk`
-- (programIsCore) livePrelude is [] so the prelude is not double-prepended.  evalOne's
-- rootLocals carry the synthesized __dt_i__ bindings (same as runMulti).
runSingle : List Decl -> List Decl -> List Decl -> List Example -> List Decl -> List (Result String (List Decl)) -> RunResult
runSingle runtimeDecls coreDecls userDecls examples synthDecls synthResults =
  let allUser = userDecls ++ synthDecls
  let userNames = funNamesOf allUser
  let livePrelude = if programIsCore userDecls then
    []
  else
    dropShadowedExp userNames coreDecls
  let elaborated = elaborateOne runtimeDecls livePrelude ("__user__", allUser)
  let env = evalOneWith (testCapableExterns ()) [] ("__main__", elaborated)
  buildDetails (Ok env) synthResults examples

-- DRIVER-COLLAPSE Phase 1+3 note on the dict-set: the old `coreDictNames`
-- externally-built dict-set (preludeReturnPosDictNames ++ constrainedSigNames, with
-- arg-position helpers excluded to keep the `neq`-hang closed) is gone — the
-- migrated runSingle/runPropsSingle route through elaborateModules, which OWNS the
-- equivalent return-position dict-set via its own `moduleDictNames`.  The
-- `medaka test stdlib/core.mdk` canary guards the neq-hang.

-- Mirror of lib/typecheck.ml's program_is_core (also compiler/resolve.mdk's
-- programIsCore): the prelude is the unique program declaring BOTH the
-- `Ordering` data type and the `Foldable` interface.
programIsCore : List Decl -> Bool
programIsCore prog = pcHasOrdering prog && pcHasFoldable prog

pcHasOrdering : List Decl -> Bool
pcHasOrdering [] = False
pcHasOrdering ((DData _ "Ordering" _ _ _)::_) = True
pcHasOrdering (_::rest) = pcHasOrdering rest

pcHasFoldable : List Decl -> Bool
pcHasFoldable [] = False
pcHasFoldable ((DInterface { name = "Foldable", ... })::_) = True
pcHasFoldable (_::rest) = pcHasFoldable rest

-- Multi-module path: load the module graph, inject synth into the root module,
-- elaborate across modules, eval (root env carries the __dt_i__ bindings).
runMulti : List Decl -> List Decl -> String -> List Decl -> List String -> List Example -> List Decl -> List (Result String (List Decl)) -> <IO> RunResult
runMulti runtimeDecls coreDecls target _userDecls roots examples synthDecls synthResults = match loadProgram target roots
  Err e => buildDetails (Err e) synthResults examples
  Ok mods =>
    let injected = injectIntoRoot target synthDecls (map desugarPair mods)
    let elaborated = elaborateModules runtimeDecls coreDecls injected
    let env = evalModulesWith (testCapableExterns ()) (fst elaborated) (snd elaborated)
    buildDetails (Ok env) synthResults examples

desugarPair : (String, List Decl) -> (String, List Decl)
desugarPair (mid, p) = (mid, desugar p)

-- Append synth decls to the ROOT (last) module in the loaded list.  The
-- loader returns modules in dependency-first order, so the entry (target)
-- is always last.  Using the last module avoids having to recompute the
-- module id from the target path + roots (which is how the loader keyed it),
-- making the injection robust to both relative and absolute target paths and
-- to nested module ids like "lib.probe" vs bare ids like "probe".
injectIntoRoot : String -> List Decl -> List (String, List Decl) -> List (String, List Decl)
injectIntoRoot _ synthDecls mods = injectIntoLast synthDecls mods

injectIntoLast : List Decl -> List (String, List Decl) -> List (String, List Decl)
injectIntoLast _ [] = []
injectIntoLast synthDecls [(mid, decls)] = [(mid, decls ++ synthDecls)]
injectIntoLast synthDecls (x::rest) = x :: injectIntoLast synthDecls rest

-- ── doctest reporting (mirrors lib/test_cmd.ml) ──────────────────────────────

reportDoctests : String -> RunResult -> <IO> Bool
reportDoctests target result =
  let _ = printDetails target (runDetails result)
  let total = runPassed result + runFailed result + runErrors result
  let _ = putStr "\n\{target}: \{intToString (runPassed result)}/\{intToString total} passed"
  let _ = putStr (failSuffix result)
  let _ = putStr "\n"
  runFailed result == 0 && runErrors result == 0

failSuffix : RunResult -> String
failSuffix result
  | runFailed result > 0 || runErrors result > 0 = " (\{intToString (runFailed result)} failed, \{intToString (runErrors result)} errors)"
  | otherwise = ""

printDetails : String -> List (Example, ExResult) -> <IO> Unit
printDetails _ [] = ()
printDetails target ((ex, res)::rest) =
  let _ = printOne target ex res
  printDetails target rest

printOne : String -> Example -> ExResult -> <IO> Unit
printOne target ex res =
  let loc = "\{target}:\{intToString (exampleLine ex)}"
  match res
    Pass => putStrLn "  ok   \{loc}: \{exampleInput ex}"
    Fail expected actual =>
      let _ = putStrLn "  FAIL \{loc}: \{exampleInput ex}"
      let _ = putStrLn ("       expected: " ++ expected)
      putStrLn ("         actual: " ++ actual)
    Errored msg =>
      let _ = putStrLn "  ERROR \{loc}: \{exampleInput ex}"
      putStrLn ("        " ++ msg)

-- ── prop phase ───────────────────────────────────────────────────────────────
-- Only runs (and prints) if the file declares props — mirrors the OCaml short
-- circuit (`Prop_runner.run_all` returns true with no output when none).

runProps : List Decl -> List Decl -> String -> List Decl -> List String -> <IO> Bool
runProps runtimeDecls coreDecls target userDecls roots
  | not (hasProps userDecls) = True
  | hasUseDecls userDecls =
    runPropsMulti runtimeDecls coreDecls target userDecls roots
  | otherwise = runPropsSingle runtimeDecls coreDecls userDecls

-- Single-file (no-import) prop path, DRIVER-COLLAPSE Phase 1+3: same multi-module
-- path as runPropsMulti, with the degenerate 1-module list [("__user__", userDecls)].
-- livePrelude passed SEPARATE (programIsCore ⇒ []); elaborateModules owns the
-- dict-set.
-- evalModulesRootEnv exposes prelude globals (eq/compare) the prop bodies need, and
-- the prop bodies themselves are pulled from the ELABORATED root module (dict-passed
-- call sites) — keyed by the "__user__" id — so the file's own `=>`-constrained fns
-- (set's `fromList`/`wellFormed`) get their leading dict argument, mirroring
-- runPropsMulti's elaboratedRootProps (which inferPropBodies typed in-module).
runPropsSingle : List Decl -> List Decl -> List Decl -> <IO> Bool
runPropsSingle runtimeDecls coreDecls userDecls =
  let userNames = funNamesOf userDecls
  let livePrelude = if programIsCore userDecls then
    []
  else
    dropShadowedExp userNames coreDecls
  let elaborated = elaborateModules runtimeDecls livePrelude [("__user__", userDecls)]
  let env = evalModulesRootEnvWith (testCapableExterns ()) (fst elaborated) (snd elaborated)
  let rootProps = match lookupModuleDecls "__user__" (snd elaborated)
    Some decls => decls
    None => userDecls
  runAllProps env rootProps

runPropsMulti : List Decl -> List Decl -> String -> List Decl -> List String -> <IO> Bool
runPropsMulti runtimeDecls coreDecls target userDecls roots = match loadProgram target roots
  Err e =>
    let _ = ePutStrLn e
    False
  Ok mods =>
    let elaborated = elaborateModules runtimeDecls coreDecls (map desugarPair mods)
    let env = evalModulesRootEnvWith (testCapableExterns ()) (fst elaborated) (snd elaborated)
    let rootProps = elaboratedRootProps target (snd elaborated) userDecls
    runAllProps env rootProps
-- DRIVER-COLLAPSE Phase 2: the eval-dict layer now promotes the file's own
-- `=>`-constrained fns (set's `wellFormed`/`fromList`, etc.), so the bindings in
-- [env] take a leading dict ARGUMENT.  A prop body calls those fns, so its call
-- sites must carry the matching dict argument — i.e. the bodies must be the
-- ELABORATED (marked + dict-passed) ones, NOT raw `userDecls`.  Pull the props
-- from the elaborated root module (mirrors how runMulti's doctest synth bodies
-- are elaborated in-tree); raw bodies would under-apply the now-dict-passed call
-- and `force` a partial closure → not VBool → every prop "fails" (set's
-- `fromList []` reported ill-formed).

-- The prop decls to evaluate: the elaborated root module's props (dict-passed call
-- sites) when the loader kept a module whose id matches the target's basename;
-- otherwise fall back to the raw userDecls (preserves the pre-Phase-2 behaviour for
-- any path where the root module isn't separately present).
-- The root module is the LAST in the list (dependency-first order — entry is last).
elaboratedRootProps : String -> List (String, List Decl) -> List Decl -> List Decl
elaboratedRootProps _ modules userDecls = match lastModule modules
  Some decls => decls
  None => userDecls

lastModule : List (String, List Decl) -> Option (List Decl)
lastModule [] = None
lastModule [(_, decls)] = Some decls
lastModule (_::rest) = lastModule rest

lookupModuleDecls : String -> List (String, List Decl) -> Option (List Decl)
lookupModuleDecls _ [] = None
lookupModuleDecls rootId ((mid, decls)::rest)
  | mid == rootId = Some decls
  | otherwise = lookupModuleDecls rootId rest

-- ── test phase (Phase 127 restored 2026-07-11) ───────────────────────────────
-- Symmetric with the prop phase: only runs (and prints) if the file declares
-- `test "…"` decls.  Each body is evaluated to an `Expectation` VALUE (panics are
-- NOT caught — a genuinely-crashing body aborts the run), and the pass/fail is
-- reported with the SAME shape as the doctest phase (RunResult/ExResult + loc +
-- summary + exit code), per P0-6.  Discovery routes through the same multi-module
-- vs single-file split as the prop phase, and — like runPropsMulti — pulls the
-- DTest bodies from the ELABORATED root module so their `expectEqual`/… call sites
-- carry the dict argument (`import test`'s constrained assertions).

runTestDecls : List Decl -> List Decl -> String -> String -> List Decl -> List String -> <IO> Bool
runTestDecls runtimeDecls coreDecls target tsrc userDecls roots
  | not (hasTests userDecls) = True
  | hasUseDecls userDecls =
    runTestDeclsMulti runtimeDecls coreDecls target tsrc userDecls roots
  | otherwise = runTestDeclsSingle runtimeDecls coreDecls target tsrc userDecls

-- Line map keyed by test name, from a POSITION-populating reparse of the source
-- (the bare `parse` used elsewhere leaves placeholder line-1 locs).
testLineTests : String -> List (String, Int, Expr)
testLineTests tsrc = collectTests (desugar (parseLocated tsrc))

runTestDeclsSingle : List Decl -> List Decl -> String -> String -> List Decl -> <IO> Bool
runTestDeclsSingle runtimeDecls coreDecls target tsrc userDecls =
  let userNames = funNamesOf userDecls
  let livePrelude = if programIsCore userDecls then
    []
  else
    dropShadowedExp userNames coreDecls
  let elaborated = elaborateModules runtimeDecls livePrelude [("__user__", userDecls)]
  let env = evalModulesRootEnvWith (testCapableExterns ()) (fst elaborated) (snd elaborated)
  let rootTests = match lookupModuleDecls "__user__" (snd elaborated)
    Some decls => decls
    None => userDecls
  reportTests
    target
    env
    (attachRawLines (testLineTests tsrc) (collectTests rootTests))

runTestDeclsMulti : List Decl -> List Decl -> String -> String -> List Decl -> List String -> <IO> Bool
runTestDeclsMulti runtimeDecls coreDecls target tsrc userDecls roots = match loadProgram target roots
  Err e =>
    let _ = ePutStrLn e
    False
  Ok mods =>
    let elaborated = elaborateModules runtimeDecls coreDecls (map desugarPair mods)
    let env = evalModulesRootEnvWith (testCapableExterns ()) (fst elaborated) (snd elaborated)
    let rootTests = elaboratedRootProps target (snd elaborated) userDecls
    reportTests
      target
      env
      (attachRawLines (testLineTests tsrc) (collectTests rootTests))

-- The elaborated (dict-passed) body loses its leading ELoc (the marker rewrites
-- the leftmost method EVar into a dict node), so take each test's line from the
-- RAW parsed decls (matched by unique test name) and keep the elaborated body.
attachRawLines : List (String, Int, Expr) -> List (String, Int, Expr) -> List (String, Int, Expr)
attachRawLines _ [] = []
attachRawLines raw ((name, _, body)::rest) =
  (name, lookupRawLine name raw, body) :: attachRawLines raw rest

lookupRawLine : String -> List (String, Int, Expr) -> Int
lookupRawLine _ [] = 0
lookupRawLine name ((n, l, _)::rest)
  | n == name = l
  | otherwise = lookupRawLine name rest

-- Reuses the doctest reporting SHAPE (`ok`/`FAIL <f>:<line>: <name>`, then the
-- `<f>: P/T passed[ (F failed, E errors)]` summary + exit code, P0-6).  Like the
-- prop phase, each result is printed AS its body is evaluated (not batched), so a
-- body that aborts the run still leaves the tests that already passed on screen.
-- Returns True iff every test passed.
reportTests : String -> List (String, Value e) -> List (String, Int, Expr) -> <IO> Bool
reportTests target env tests =
  let _ = putStrLn ("running tests in " ++ target)
  let (passed, failed, errors) = runTestLoop target env tests 0 0 0
  let total = passed + failed + errors
  let _ = putStr "\n\{target}: \{intToString passed}/\{intToString total} passed"
  let _ = putStr (testFailSuffix failed errors)
  let _ = putStr "\n"
  failed == 0 && errors == 0

runTestLoop : String -> List (String, Value e) -> List (String, Int, Expr) -> Int -> Int -> Int -> <IO> (Int, Int, Int)
runTestLoop _ _ [] passed failed errors = (passed, failed, errors)
runTestLoop target env ((name, line, body)::rest) passed failed errors =
  let loc = "\{target}:\{intToString line}"
  match runOneTest env body
    Pass =>
      let _ = putStrLn "  ok   \{loc}: \{name}"
      runTestLoop target env rest (passed + 1) failed errors
    Fail msg _ =>
      let _ = putStrLn "  FAIL \{loc}: \{name}"
      let _ = putStrLn ("       " ++ msg)
      runTestLoop target env rest passed (failed + 1) errors
    Errored msg =>
      let _ = putStrLn "  FAIL \{loc}: \{name}"
      let _ = putStrLn ("       " ++ msg)
      runTestLoop target env rest passed failed (errors + 1)

testFailSuffix : Int -> Int -> String
testFailSuffix failed errors
  | failed > 0 || errors > 0 =
    " (\{intToString failed} failed, \{intToString errors} errors)"
  | otherwise = ""
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DData" false) (mem "DInterface" false) (mem "Expr" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "loadProgram" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "elaborateOne" false) (mem "elaborateModules" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "collectComments" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" false) (mem "evalOneWith" false) (mem "evalModulesWith" false) (mem "evalModulesRootEnvWith" false) (mem "testCapableExterns" false) (mem "funNamesOf" false) (mem "dropShadowedExp" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" true) (mem "RunResult" false) (mem "extractExamples" false) (mem "buildSynthResults" false) (mem "buildSynthDecls" false) (mem "buildDetails" false) (mem "hasUseDecls" false) (mem "runDetails" false) (mem "runPassed" false) (mem "runFailed" false) (mem "runErrors" false) (mem "exampleInput" false) (mem "exampleLine" false) (mem "synthName" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "runAllProps" false) (mem "hasProps" false))))
(DUse false (UseGroup ("tools" "test_runner") ((mem "collectTests" false) (mem "runOneTest" false) (mem "hasTests" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DTypeSig true "rootsOrDefault" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "rootsOrDefault" ((PVar "target") (PList)) (EListLit (EApp (EVar "dirOf") (EVar "target"))))
(DFunDef false "rootsOrDefault" (PWild (PVar "roots")) (EVar "roots"))
(DTypeSig true "runTest" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runTest" ((PVar "runtimeP") (PVar "coreP") (PVar "target") (PVar "roots")) (EMatch (EApp (EVar "readFile") (EVar "runtimeP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "coreP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "tsrc")) () (EApp (EApp (EApp (EApp (EApp (EVar "driveAll") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (EVar "target")) (EVar "tsrc")) (EVar "roots")))))))))
(DTypeSig false "driveAll" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "driveAll" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "roots")) (EBlock (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoLet false false (PVar "doctestsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runDoctests") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots"))) (DoLet false false (PVar "propsOk") (EApp (EApp (EApp (EApp (EApp (EVar "runProps") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "userDecls")) (EVar "roots"))) (DoLet false false (PVar "testsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDecls") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "doctestsOk") (EVar "propsOk")) (EVar "testsOk")))))
(DTypeSig false "runDoctests" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runDoctests" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "running doctests in ")) (EVar "target")))) (DoLet false false (PVar "examples") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (DoExpr (EMatch (EVar "examples") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "  (no doctests found)")))) (DoExpr (EVar "True")))) (arm PWild () (EBlock (DoLet false false (PVar "synthResults") (EApp (EVar "buildSynthResults") (EVar "examples"))) (DoLet false false (PVar "synthDecls") (EApp (EVar "buildSynthDecls") (EVar "synthResults"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosen") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults"))) (DoExpr (EApp (EApp (EVar "reportDoctests") (EVar "target")) (EVar "result")))))))))
(DTypeSig false "runChosen" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult")))))))))))
(DFunDef false "runChosen" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "userDecls")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "RunResult"))))))))
(DFunDef false "runSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "userDecls") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EBlock (DoLet false false (PVar "allUser") (EBinOp "++" (EVar "userDecls") (EVar "synthDecls"))) (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "allUser"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateOne") (EVar "runtimeDecls")) (EVar "livePrelude")) (ETuple (ELit (LString "__user__")) (EVar "allUser")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalOneWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EListLit)) (ETuple (ELit (LString "__main__")) (EVar "elaborated")))) (DoExpr (EApp (EApp (EApp (EVar "buildDetails") (EApp (EVar "Ok") (EVar "env"))) (EVar "synthResults")) (EVar "examples")))))
(DTypeSig false "programIsCore" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "programIsCore" ((PVar "prog")) (EBinOp "&&" (EApp (EVar "pcHasOrdering") (EVar "prog")) (EApp (EVar "pcHasFoldable") (EVar "prog"))))
(DTypeSig false "pcHasOrdering" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "pcHasOrdering" ((PList)) (EVar "False"))
(DFunDef false "pcHasOrdering" ((PCons (PCon "DData" PWild (PLit (LString "Ordering")) PWild PWild PWild) PWild)) (EVar "True"))
(DFunDef false "pcHasOrdering" ((PCons PWild (PVar "rest"))) (EApp (EVar "pcHasOrdering") (EVar "rest")))
(DTypeSig false "pcHasFoldable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "pcHasFoldable" ((PList)) (EVar "False"))
(DFunDef false "pcHasFoldable" ((PCons (PRec "DInterface" ((rf "name" (PLit (LString "Foldable")))) true) PWild)) (EVar "True"))
(DFunDef false "pcHasFoldable" ((PCons PWild (PVar "rest"))) (EApp (EVar "pcHasFoldable") (EVar "rest")))
(DTypeSig false "runMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult")))))))))))
(DFunDef false "runMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "_userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "buildDetails") (EApp (EVar "Err") (EVar "e"))) (EVar "synthResults")) (EVar "examples"))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "injected") (EApp (EApp (EApp (EVar "injectIntoRoot") (EVar "target")) (EVar "synthDecls")) (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "injected"))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoExpr (EApp (EApp (EApp (EVar "buildDetails") (EApp (EVar "Ok") (EVar "env"))) (EVar "synthResults")) (EVar "examples")))))))
(DTypeSig false "desugarPair" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugarPair" ((PTuple (PVar "mid") (PVar "p"))) (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "p"))))
(DTypeSig false "injectIntoRoot" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "injectIntoRoot" (PWild (PVar "synthDecls") (PVar "mods")) (EApp (EApp (EVar "injectIntoLast") (EVar "synthDecls")) (EVar "mods")))
(DTypeSig false "injectIntoLast" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "injectIntoLast" (PWild (PList)) (EListLit))
(DFunDef false "injectIntoLast" ((PVar "synthDecls") (PList (PTuple (PVar "mid") (PVar "decls")))) (EListLit (ETuple (EVar "mid") (EBinOp "++" (EVar "decls") (EVar "synthDecls")))))
(DFunDef false "injectIntoLast" ((PVar "synthDecls") (PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "injectIntoLast") (EVar "synthDecls")) (EVar "rest"))))
(DTypeSig false "reportDoctests" (TyFun (TyCon "String") (TyFun (TyCon "RunResult") (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "reportDoctests" ((PVar "target") (PVar "result")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "printDetails") (EVar "target")) (EApp (EVar "runDetails") (EVar "result")))) (DoLet false false (PVar "total") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EVar "result")) (EApp (EVar "runFailed") (EVar "result"))) (EApp (EVar "runErrors") (EVar "result")))) (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "runPassed") (EVar "result"))))) (ELit (LString "/"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " passed"))))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "failSuffix") (EVar "result")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EVar "runFailed") (EVar "result")) (ELit (LInt 0))) (EBinOp "==" (EApp (EVar "runErrors") (EVar "result")) (ELit (LInt 0)))))))
(DTypeSig false "failSuffix" (TyFun (TyCon "RunResult") (TyCon "String")))
(DFunDef false "failSuffix" ((PVar "result")) (EIf (EBinOp "||" (EBinOp ">" (EApp (EVar "runFailed") (EVar "result")) (ELit (LInt 0))) (EBinOp ">" (EApp (EVar "runErrors") (EVar "result")) (ELit (LInt 0)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "runFailed") (EVar "result"))))) (ELit (LString " failed, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "runErrors") (EVar "result"))))) (ELit (LString " errors)"))) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "printDetails" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Example") (TyCon "ExResult"))) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "printDetails" (PWild (PList)) (ELit LUnit))
(DFunDef false "printDetails" ((PVar "target") (PCons (PTuple (PVar "ex") (PVar "res")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "printOne") (EVar "target")) (EVar "ex")) (EVar "res"))) (DoExpr (EApp (EApp (EVar "printDetails") (EVar "target")) (EVar "rest")))))
(DTypeSig false "printOne" (TyFun (TyCon "String") (TyFun (TyCon "Example") (TyFun (TyCon "ExResult") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "printOne" ((PVar "target") (PVar "ex") (PVar "res")) (EBlock (DoLet false false (PVar "loc") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "exampleLine") (EVar "ex"))))) (ELit (LString "")))) (DoExpr (EMatch (EVar "res") (arm (PCon "Pass") () (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ok   ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "exampleInput") (EVar "ex")))) (ELit (LString ""))))) (arm (PCon "Fail" (PVar "expected") (PVar "actual")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "exampleInput") (EVar "ex")))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "       expected: ")) (EVar "expected")))) (DoExpr (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "         actual: ")) (EVar "actual")))))) (arm (PCon "Errored" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ERROR ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "exampleInput") (EVar "ex")))) (ELit (LString ""))))) (DoExpr (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "        ")) (EVar "msg"))))))))))
(DTypeSig false "runProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "runProps" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "userDecls") (PVar "roots")) (EIf (EApp (EVar "not") (EApp (EVar "hasProps") (EVar "userDecls"))) (EVar "True") (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EVar "runPropsMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "userDecls")) (EVar "roots")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "runPropsSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "userDecls")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "runPropsSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "runPropsSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "userDecls")) (EBlock (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (ELit (LString "__user__")) (EVar "userDecls"))))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootProps") (EMatch (EApp (EApp (EVar "lookupModuleDecls") (ELit (LString "__user__"))) (EApp (EVar "snd") (EVar "elaborated"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls")))) (DoExpr (EApp (EApp (EVar "runAllProps") (EVar "env")) (EVar "rootProps")))))
(DTypeSig false "runPropsMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "runPropsMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "userDecls") (PVar "roots")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootProps") (EApp (EApp (EApp (EVar "elaboratedRootProps") (EVar "target")) (EApp (EVar "snd") (EVar "elaborated"))) (EVar "userDecls"))) (DoExpr (EApp (EApp (EVar "runAllProps") (EVar "env")) (EVar "rootProps")))))))
(DTypeSig false "elaboratedRootProps" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "elaboratedRootProps" (PWild (PVar "modules") (PVar "userDecls")) (EMatch (EApp (EVar "lastModule") (EVar "modules")) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls"))))
(DTypeSig false "lastModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "lastModule" ((PList)) (EVar "None"))
(DFunDef false "lastModule" ((PList (PTuple PWild (PVar "decls")))) (EApp (EVar "Some") (EVar "decls")))
(DFunDef false "lastModule" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModule") (EVar "rest")))
(DTypeSig false "lookupModuleDecls" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lookupModuleDecls" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupModuleDecls" ((PVar "rootId") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "mid") (EVar "rootId")) (EApp (EVar "Some") (EVar "decls")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupModuleDecls") (EVar "rootId")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runTestDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runTestDecls" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots")) (EIf (EApp (EVar "not") (EApp (EVar "hasTests") (EVar "userDecls"))) (EVar "True") (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDeclsMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "runTestDeclsSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "testLineTests" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "testLineTests" ((PVar "tsrc")) (EApp (EVar "collectTests") (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EVar "tsrc")))))
(DTypeSig false "runTestDeclsSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "runTestDeclsSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls")) (EBlock (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (ELit (LString "__user__")) (EVar "userDecls"))))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootTests") (EMatch (EApp (EApp (EVar "lookupModuleDecls") (ELit (LString "__user__"))) (EApp (EVar "snd") (EVar "elaborated"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls")))) (DoExpr (EApp (EApp (EApp (EVar "reportTests") (EVar "target")) (EVar "env")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EVar "rootTests")))))))
(DTypeSig false "runTestDeclsMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runTestDeclsMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EApp (EApp (EVar "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootTests") (EApp (EApp (EApp (EVar "elaboratedRootProps") (EVar "target")) (EApp (EVar "snd") (EVar "elaborated"))) (EVar "userDecls"))) (DoExpr (EApp (EApp (EApp (EVar "reportTests") (EVar "target")) (EVar "env")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EVar "rootTests")))))))))
(DTypeSig false "attachRawLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))))
(DFunDef false "attachRawLines" (PWild (PList)) (EListLit))
(DFunDef false "attachRawLines" ((PVar "raw") (PCons (PTuple (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EVar "lookupRawLine") (EVar "name")) (EVar "raw")) (EVar "body")) (EApp (EApp (EVar "attachRawLines") (EVar "raw")) (EVar "rest"))))
(DTypeSig false "lookupRawLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyCon "Int"))))
(DFunDef false "lookupRawLine" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "lookupRawLine" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "l") PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EVar "l") (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupRawLine") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reportTests" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "reportTests" ((PVar "target") (PVar "env") (PVar "tests")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "running tests in ")) (EVar "target")))) (DoLet false false (PTuple (PVar "passed") (PVar "failed") (PVar "errors")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "tests")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (DoLet false false (PVar "total") (EBinOp "+" (EBinOp "+" (EVar "passed") (EVar "failed")) (EVar "errors"))) (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "passed")))) (ELit (LString "/"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " passed"))))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EApp (EVar "testFailSuffix") (EVar "failed")) (EVar "errors")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EVar "failed") (ELit (LInt 0))) (EBinOp "==" (EVar "errors") (ELit (LInt 0)))))))
(DTypeSig false "runTestLoop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))))))))))
(DFunDef false "runTestLoop" (PWild PWild (PList) (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EVar "passed") (EVar "failed") (EVar "errors")))
(DFunDef false "runTestLoop" ((PVar "target") (PVar "env") (PCons (PTuple (PVar "name") (PVar "line") (PVar "body")) (PVar "rest")) (PVar "passed") (PVar "failed") (PVar "errors")) (EBlock (DoLet false false (PVar "loc") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "runOneTest") (EVar "env")) (EVar "body")) (arm (PCon "Pass") () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ok   ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "rest")) (EBinOp "+" (EVar "passed") (ELit (LInt 1)))) (EVar "failed")) (EVar "errors"))))) (arm (PCon "Fail" (PVar "msg") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "       ")) (EVar "msg")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "rest")) (EVar "passed")) (EBinOp "+" (EVar "failed") (ELit (LInt 1)))) (EVar "errors"))))) (arm (PCon "Errored" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EVar "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "       ")) (EVar "msg")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "rest")) (EVar "passed")) (EVar "failed")) (EBinOp "+" (EVar "errors") (ELit (LInt 1)))))))))))
(DTypeSig false "testFailSuffix" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "testFailSuffix" ((PVar "failed") (PVar "errors")) (EIf (EBinOp "||" (EBinOp ">" (EVar "failed") (ELit (LInt 0))) (EBinOp ">" (EVar "errors") (ELit (LInt 0)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "failed")))) (ELit (LString " failed, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "errors")))) (ELit (LString " errors)"))) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DData" false) (mem "DInterface" false) (mem "Expr" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "loadProgram" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "elaborateOne" false) (mem "elaborateModules" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "collectComments" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" false) (mem "evalOneWith" false) (mem "evalModulesWith" false) (mem "evalModulesRootEnvWith" false) (mem "testCapableExterns" false) (mem "funNamesOf" false) (mem "dropShadowedExp" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "Example" false) (mem "ExResult" true) (mem "RunResult" false) (mem "extractExamples" false) (mem "buildSynthResults" false) (mem "buildSynthDecls" false) (mem "buildDetails" false) (mem "hasUseDecls" false) (mem "runDetails" false) (mem "runPassed" false) (mem "runFailed" false) (mem "runErrors" false) (mem "exampleInput" false) (mem "exampleLine" false) (mem "synthName" false))))
(DUse false (UseGroup ("tools" "prop_runner") ((mem "runAllProps" false) (mem "hasProps" false))))
(DUse false (UseGroup ("tools" "test_runner") ((mem "collectTests" false) (mem "runOneTest" false) (mem "hasTests" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DTypeSig true "rootsOrDefault" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "rootsOrDefault" ((PVar "target") (PList)) (EListLit (EApp (EVar "dirOf") (EVar "target"))))
(DFunDef false "rootsOrDefault" (PWild (PVar "roots")) (EVar "roots"))
(DTypeSig true "runTest" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runTest" ((PVar "runtimeP") (PVar "coreP") (PVar "target") (PVar "roots")) (EMatch (EApp (EVar "readFile") (EVar "runtimeP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EVar "coreP")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "readFile") (EVar "target")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "True")))) (arm (PCon "Ok" (PVar "tsrc")) () (EApp (EApp (EApp (EApp (EApp (EVar "driveAll") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "rsrc")))) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "csrc")))) (EVar "target")) (EVar "tsrc")) (EVar "roots")))))))))
(DTypeSig false "driveAll" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "driveAll" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "roots")) (EBlock (DoLet false false (PVar "userDecls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "tsrc")))) (DoLet false false (PVar "doctestsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runDoctests") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots"))) (DoLet false false (PVar "propsOk") (EApp (EApp (EApp (EApp (EApp (EVar "runProps") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "userDecls")) (EVar "roots"))) (DoLet false false (PVar "testsOk") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDecls") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EVar "doctestsOk") (EVar "propsOk")) (EVar "testsOk")))))
(DTypeSig false "runDoctests" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runDoctests" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "running doctests in ")) (EVar "target")))) (DoLet false false (PVar "examples") (EApp (EVar "extractExamples") (EApp (EVar "collectComments") (EVar "tsrc")))) (DoExpr (EMatch (EVar "examples") (arm (PList) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "  (no doctests found)")))) (DoExpr (EVar "True")))) (arm PWild () (EBlock (DoLet false false (PVar "synthResults") (EApp (EVar "buildSynthResults") (EVar "examples"))) (DoLet false false (PVar "synthDecls") (EApp (EVar "buildSynthDecls") (EVar "synthResults"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runChosen") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults"))) (DoExpr (EApp (EApp (EVar "reportDoctests") (EVar "target")) (EVar "result")))))))))
(DTypeSig false "runChosen" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult")))))))))))
(DFunDef false "runChosen" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "userDecls")) (EVar "roots")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "userDecls")) (EVar "examples")) (EVar "synthDecls")) (EVar "synthResults")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "RunResult"))))))))
(DFunDef false "runSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "userDecls") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EBlock (DoLet false false (PVar "allUser") (EBinOp "++" (EVar "userDecls") (EVar "synthDecls"))) (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "allUser"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateOne") (EVar "runtimeDecls")) (EVar "livePrelude")) (ETuple (ELit (LString "__user__")) (EVar "allUser")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalOneWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EListLit)) (ETuple (ELit (LString "__main__")) (EVar "elaborated")))) (DoExpr (EApp (EApp (EApp (EVar "buildDetails") (EApp (EVar "Ok") (EVar "env"))) (EVar "synthResults")) (EVar "examples")))))
(DTypeSig false "programIsCore" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "programIsCore" ((PVar "prog")) (EBinOp "&&" (EApp (EVar "pcHasOrdering") (EVar "prog")) (EApp (EVar "pcHasFoldable") (EVar "prog"))))
(DTypeSig false "pcHasOrdering" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "pcHasOrdering" ((PList)) (EVar "False"))
(DFunDef false "pcHasOrdering" ((PCons (PCon "DData" PWild (PLit (LString "Ordering")) PWild PWild PWild) PWild)) (EVar "True"))
(DFunDef false "pcHasOrdering" ((PCons PWild (PVar "rest"))) (EApp (EVar "pcHasOrdering") (EVar "rest")))
(DTypeSig false "pcHasFoldable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "pcHasFoldable" ((PList)) (EVar "False"))
(DFunDef false "pcHasFoldable" ((PCons (PRec "DInterface" ((rf "name" (PLit (LString "Foldable")))) true) PWild)) (EVar "True"))
(DFunDef false "pcHasFoldable" ((PCons PWild (PVar "rest"))) (EApp (EVar "pcHasFoldable") (EVar "rest")))
(DTypeSig false "runMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Example")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "RunResult")))))))))))
(DFunDef false "runMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "_userDecls") (PVar "roots") (PVar "examples") (PVar "synthDecls") (PVar "synthResults")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "buildDetails") (EApp (EVar "Err") (EVar "e"))) (EVar "synthResults")) (EVar "examples"))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "injected") (EApp (EApp (EApp (EVar "injectIntoRoot") (EVar "target")) (EVar "synthDecls")) (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "injected"))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoExpr (EApp (EApp (EApp (EVar "buildDetails") (EApp (EVar "Ok") (EVar "env"))) (EVar "synthResults")) (EVar "examples")))))))
(DTypeSig false "desugarPair" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "desugarPair" ((PTuple (PVar "mid") (PVar "p"))) (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "p"))))
(DTypeSig false "injectIntoRoot" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "injectIntoRoot" (PWild (PVar "synthDecls") (PVar "mods")) (EApp (EApp (EVar "injectIntoLast") (EVar "synthDecls")) (EVar "mods")))
(DTypeSig false "injectIntoLast" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "injectIntoLast" (PWild (PList)) (EListLit))
(DFunDef false "injectIntoLast" ((PVar "synthDecls") (PList (PTuple (PVar "mid") (PVar "decls")))) (EListLit (ETuple (EVar "mid") (EBinOp "++" (EVar "decls") (EVar "synthDecls")))))
(DFunDef false "injectIntoLast" ((PVar "synthDecls") (PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "injectIntoLast") (EVar "synthDecls")) (EVar "rest"))))
(DTypeSig false "reportDoctests" (TyFun (TyCon "String") (TyFun (TyCon "RunResult") (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "reportDoctests" ((PVar "target") (PVar "result")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "printDetails") (EVar "target")) (EApp (EVar "runDetails") (EVar "result")))) (DoLet false false (PVar "total") (EBinOp "+" (EBinOp "+" (EApp (EVar "runPassed") (EVar "result")) (EApp (EVar "runFailed") (EVar "result"))) (EApp (EVar "runErrors") (EVar "result")))) (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "runPassed") (EVar "result"))))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " passed"))))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "failSuffix") (EVar "result")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EVar "runFailed") (EVar "result")) (ELit (LInt 0))) (EBinOp "==" (EApp (EVar "runErrors") (EVar "result")) (ELit (LInt 0)))))))
(DTypeSig false "failSuffix" (TyFun (TyCon "RunResult") (TyCon "String")))
(DFunDef false "failSuffix" ((PVar "result")) (EIf (EBinOp "||" (EBinOp ">" (EApp (EVar "runFailed") (EVar "result")) (ELit (LInt 0))) (EBinOp ">" (EApp (EVar "runErrors") (EVar "result")) (ELit (LInt 0)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "runFailed") (EVar "result"))))) (ELit (LString " failed, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "runErrors") (EVar "result"))))) (ELit (LString " errors)"))) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "printDetails" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Example") (TyCon "ExResult"))) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "printDetails" (PWild (PList)) (ELit LUnit))
(DFunDef false "printDetails" ((PVar "target") (PCons (PTuple (PVar "ex") (PVar "res")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "printOne") (EVar "target")) (EVar "ex")) (EVar "res"))) (DoExpr (EApp (EApp (EVar "printDetails") (EVar "target")) (EVar "rest")))))
(DTypeSig false "printOne" (TyFun (TyCon "String") (TyFun (TyCon "Example") (TyFun (TyCon "ExResult") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "printOne" ((PVar "target") (PVar "ex") (PVar "res")) (EBlock (DoLet false false (PVar "loc") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "exampleLine") (EVar "ex"))))) (ELit (LString "")))) (DoExpr (EMatch (EVar "res") (arm (PCon "Pass") () (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ok   ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "exampleInput") (EVar "ex")))) (ELit (LString ""))))) (arm (PCon "Fail" (PVar "expected") (PVar "actual")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "exampleInput") (EVar "ex")))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "       expected: ")) (EVar "expected")))) (DoExpr (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "         actual: ")) (EVar "actual")))))) (arm (PCon "Errored" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ERROR ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "exampleInput") (EVar "ex")))) (ELit (LString ""))))) (DoExpr (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "        ")) (EVar "msg"))))))))))
(DTypeSig false "runProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "runProps" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "userDecls") (PVar "roots")) (EIf (EApp (EVar "not") (EApp (EVar "hasProps") (EVar "userDecls"))) (EVar "True") (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EVar "runPropsMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "userDecls")) (EVar "roots")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "runPropsSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "userDecls")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "runPropsSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "runPropsSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "userDecls")) (EBlock (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (ELit (LString "__user__")) (EVar "userDecls"))))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootProps") (EMatch (EApp (EApp (EVar "lookupModuleDecls") (ELit (LString "__user__"))) (EApp (EVar "snd") (EVar "elaborated"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls")))) (DoExpr (EApp (EApp (EVar "runAllProps") (EVar "env")) (EVar "rootProps")))))
(DTypeSig false "runPropsMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "runPropsMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "userDecls") (PVar "roots")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootProps") (EApp (EApp (EApp (EVar "elaboratedRootProps") (EVar "target")) (EApp (EVar "snd") (EVar "elaborated"))) (EVar "userDecls"))) (DoExpr (EApp (EApp (EVar "runAllProps") (EVar "env")) (EVar "rootProps")))))))
(DTypeSig false "elaboratedRootProps" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "elaboratedRootProps" (PWild (PVar "modules") (PVar "userDecls")) (EMatch (EApp (EVar "lastModule") (EVar "modules")) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls"))))
(DTypeSig false "lastModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "lastModule" ((PList)) (EVar "None"))
(DFunDef false "lastModule" ((PList (PTuple PWild (PVar "decls")))) (EApp (EVar "Some") (EVar "decls")))
(DFunDef false "lastModule" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastModule") (EVar "rest")))
(DTypeSig false "lookupModuleDecls" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lookupModuleDecls" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupModuleDecls" ((PVar "rootId") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "mid") (EVar "rootId")) (EApp (EVar "Some") (EVar "decls")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupModuleDecls") (EVar "rootId")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "runTestDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runTestDecls" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots")) (EIf (EApp (EVar "not") (EApp (EVar "hasTests") (EVar "userDecls"))) (EVar "True") (EIf (EApp (EVar "hasUseDecls") (EVar "userDecls")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestDeclsMulti") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EVar "roots")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "runTestDeclsSingle") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "target")) (EVar "tsrc")) (EVar "userDecls")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "testLineTests" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "testLineTests" ((PVar "tsrc")) (EApp (EVar "collectTests") (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EVar "tsrc")))))
(DTypeSig false "runTestDeclsSingle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Bool"))))))))
(DFunDef false "runTestDeclsSingle" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls")) (EBlock (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (DoLet false false (PVar "livePrelude") (EIf (EApp (EVar "programIsCore") (EVar "userDecls")) (EListLit) (EApp (EApp (EVar "dropShadowedExp") (EVar "userNames")) (EVar "coreDecls")))) (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "livePrelude")) (EListLit (ETuple (ELit (LString "__user__")) (EVar "userDecls"))))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootTests") (EMatch (EApp (EApp (EVar "lookupModuleDecls") (ELit (LString "__user__"))) (EApp (EVar "snd") (EVar "elaborated"))) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EVar "userDecls")))) (DoExpr (EApp (EApp (EApp (EVar "reportTests") (EVar "target")) (EVar "env")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EVar "rootTests")))))))
(DTypeSig false "runTestDeclsMulti" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runTestDeclsMulti" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "target") (PVar "tsrc") (PVar "userDecls") (PVar "roots")) (EMatch (EApp (EApp (EVar "loadProgram") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "e"))) (DoExpr (EVar "False")))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "elaborated") (EApp (EApp (EApp (EVar "elaborateModules") (EVar "runtimeDecls")) (EVar "coreDecls")) (EApp (EApp (EMethodRef "map") (EVar "desugarPair")) (EVar "mods")))) (DoLet false false (PVar "env") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "testCapableExterns") (ELit LUnit))) (EApp (EVar "fst") (EVar "elaborated"))) (EApp (EVar "snd") (EVar "elaborated")))) (DoLet false false (PVar "rootTests") (EApp (EApp (EApp (EVar "elaboratedRootProps") (EVar "target")) (EApp (EVar "snd") (EVar "elaborated"))) (EVar "userDecls"))) (DoExpr (EApp (EApp (EApp (EVar "reportTests") (EVar "target")) (EVar "env")) (EApp (EApp (EVar "attachRawLines") (EApp (EVar "testLineTests") (EVar "tsrc"))) (EApp (EVar "collectTests") (EVar "rootTests")))))))))
(DTypeSig false "attachRawLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))))))
(DFunDef false "attachRawLines" (PWild (PList)) (EListLit))
(DFunDef false "attachRawLines" ((PVar "raw") (PCons (PTuple (PVar "name") PWild (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EVar "lookupRawLine") (EVar "name")) (EVar "raw")) (EVar "body")) (EApp (EApp (EVar "attachRawLines") (EVar "raw")) (EVar "rest"))))
(DTypeSig false "lookupRawLine" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyCon "Int"))))
(DFunDef false "lookupRawLine" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "lookupRawLine" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "l") PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EVar "l") (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupRawLine") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reportTests" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "reportTests" ((PVar "target") (PVar "env") (PVar "tests")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "running tests in ")) (EVar "target")))) (DoLet false false (PTuple (PVar "passed") (PVar "failed") (PVar "errors")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "tests")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (DoLet false false (PVar "total") (EBinOp "+" (EBinOp "+" (EVar "passed") (EVar "failed")) (EVar "errors"))) (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "passed")))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " passed"))))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EApp (EVar "testFailSuffix") (EVar "failed")) (EVar "errors")))) (DoLet false false PWild (EApp (EVar "putStr") (ELit (LString "\n")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EVar "failed") (ELit (LInt 0))) (EBinOp "==" (EVar "errors") (ELit (LInt 0)))))))
(DTypeSig false "runTestLoop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))))))))))
(DFunDef false "runTestLoop" (PWild PWild (PList) (PVar "passed") (PVar "failed") (PVar "errors")) (ETuple (EVar "passed") (EVar "failed") (EVar "errors")))
(DFunDef false "runTestLoop" ((PVar "target") (PVar "env") (PCons (PTuple (PVar "name") (PVar "line") (PVar "body")) (PVar "rest")) (PVar "passed") (PVar "failed") (PVar "errors")) (EBlock (DoLet false false (PVar "loc") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "target"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "runOneTest") (EVar "env")) (EVar "body")) (arm (PCon "Pass") () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ok   ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "rest")) (EBinOp "+" (EVar "passed") (ELit (LInt 1)))) (EVar "failed")) (EVar "errors"))))) (arm (PCon "Fail" (PVar "msg") PWild) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "       ")) (EVar "msg")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "rest")) (EVar "passed")) (EBinOp "+" (EVar "failed") (ELit (LInt 1)))) (EVar "errors"))))) (arm (PCon "Errored" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EMethodRef "display") (EVar "loc"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (ELit (LString "       ")) (EVar "msg")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runTestLoop") (EVar "target")) (EVar "env")) (EVar "rest")) (EVar "passed")) (EVar "failed")) (EBinOp "+" (EVar "errors") (ELit (LInt 1)))))))))))
(DTypeSig false "testFailSuffix" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "testFailSuffix" ((PVar "failed") (PVar "errors")) (EIf (EBinOp "||" (EBinOp ">" (EVar "failed") (ELit (LInt 0))) (EBinOp ">" (EVar "errors") (ELit (LInt 0)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "failed")))) (ELit (LString " failed, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "errors")))) (ELit (LString " errors)"))) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
