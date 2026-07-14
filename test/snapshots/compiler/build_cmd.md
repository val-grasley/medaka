# META
source_lines=454
stages=DESUGAR,MARK
# SOURCE
-- compiler/driver/build_cmd.mdk — `medaka build` ported to self-hosted Medaka
-- (Stage 4 Phase B.11).  The self-host analog of lib/build_cmd.ml: compile a
-- user .mdk program to a native binary via the Medaka-hosted LLVM emitter
-- (compiler/entries/llvm_emit_modules_main.mdk) + clang + the C runtime + Boehm GC.
--
-- EMIT STEP = SHELL-OUT (option b), mirroring lib/build_cmd.ml verbatim.  The
-- emitter is a heavy Medaka program carrying global Ref state (arg-stamp tables,
-- gap log) and writes IR to stdout via putStr.  Driving it in-process would mean
-- importing the entire emitter module graph into this driver AND risking Ref
-- bleed across the build's own elaboration — exactly the fragility the OCaml
-- driver cites for shelling out.  Running a FRESH `medaka run <emitter> …`
-- subprocess gives a clean stdout pipe and pristine Ref state per build, which is
-- what every working harness (test/diff_compiler_llvm_modules.sh, build_cmd.sh)
-- already relies on.  runCommand (#18, native-emittable) is the new capability
-- that makes this expressible in Medaka.
--
-- PATHS.  Selfhost has no Sys.executable_name / getcwd extern, so the driver
-- reads the medaka exe and repo root from the environment (MEDAKA, MEDAKA_ROOT)
-- — supplied by the gate script — falling back to "medaka" / "." .  Backend
-- assets (runtime.mdk, core.mdk, the emitter, medaka_rt.c, the compiler + stdlib
-- dirs) resolve repo-relative exactly as build_cmd.ml does.
--
-- GAP POLICY.  Hard-error (mirrors the MVP): a non-zero emitter exit (an
-- unemittable construct → `panic: … gap …`) or empty IR aborts the build with
-- the emitter's own diagnostic surfaced.

import support.util.{reverseL, stringTrim}
import driver.loader.{entrySearchRoots}
import support.path.{dirOf, chopExt, joinPath}

-- A build either succeeds (writing the binary) or fails with a message.
public export data BuildResult = BuildOk String | BuildErr String

-- Backend target: TNative = the LLVM/clang native binary (default); TWasm =
-- WasmGC via the wasm_emit entry + wasm-tools assemble/validate.
public export data BuildTarget = TNative | TWasm

-- Append an informational suffix (e.g. a "kept IR" note) to a BuildResult's
-- message, whichever arm it is — so a --keep-ir note is visible whether the
-- rest of the build (clang / wasm-tools) went on to succeed or fail.
appendNote : String -> BuildResult -> BuildResult
appendNote note (BuildOk m) = BuildOk (m ++ note)
appendNote note (BuildErr m) = BuildErr (m ++ note)

-- ---- small string helpers (externs only — keeps this module self-contained) ----

-- Strip leading/trailing ASCII whitespace: stringTrim (from support/util.mdk).

isWS : String -> Bool
isWS c = c == " " || c == "\n" || c == "\t" || c == "\r"

-- Split a whitespace-separated flag string into a list of non-empty tokens.
splitWS : String -> List String
splitWS s = splitWSGo (stringTrim s) 0 0 []

splitWSGo : String -> Int -> Int -> List String -> List String
splitWSGo s i start acc =
  let n = stringLength s
  if i >= n then if i > start then reverseL (stringSlice start i s :: acc) else reverseL acc
  else
    if isWS (stringSlice i (i + 1) s) then
      let acc2 = if i > start then stringSlice start i s :: acc else acc
      splitWSGo s (i + 1) (i + 1) acc2
    else splitWSGo s (i + 1) start acc

-- dirname / basename / chop-extension / join now live in support/path.mdk.

-- ---- environment / asset resolution ----

export envOr : String -> String -> <IO> String
-- Intentional cross-file duplicate of the same helper in lsp_harness_main.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
envOr name dflt = match getEnv name
  Some v => if v == "" then dflt else v
  None => dflt

-- ---- exe-relative install-layout defaults (D1, DISTRIBUTION-DESIGN.md §4) ----
-- A relocated `medaka` binary can't assume it's running inside this repo, so
-- when MEDAKA_ROOT/MEDAKA_EMITTER are unset we derive them from the running
-- executable's OWN location rather than defaulting to "." (cwd) / "" (broken
-- `medaka run <emitter>` fallback).  The layout `make medaka` already produces —
-- `./medaka`, `./medaka_emitter`, and `stdlib/` all siblings at the repo root —
-- IS this default layout, so the in-repo dev build keeps working with no env
-- vars set: exeDir is the repo root, exactly what MEDAKA_ROOT needs to be.  An
-- explicit env var always wins (envOr only falls back to these when unset).
export exeDir : <IO> String
exeDir = dirOf (executablePath ())

export defaultMedakaRoot : <IO> String
defaultMedakaRoot = exeDir

export defaultMedakaEmitter : <IO> String
defaultMedakaEmitter = joinPath exeDir "medaka_emitter"

-- ---- the trailing-Unit auto-print trim ----
-- The interpreter auto-prints main's Unit as a trailing "()\n"; the emitter's
-- IR is captured via subprocess stdout, so strip a trailing "()\n" if present
-- (mirrors strip_trailing_unit in build_cmd.ml).
stripTrailingUnit : String -> String
stripTrailingUnit s =
  let n = stringLength s
  if n >= 3 && stringSlice (n - 3) n s == "()\n" then
    stringSlice 0 (n - 3) s
  else
    s

-- ---- per-invocation scratch directory ----
-- SCRATCH-PATH INVARIANT.  Every temp file this driver stages — the emitted
-- .ll / .wat, and the bare-`-lgc` probe source + probe binary — lives inside ONE
-- directory created by `mktemp -d`, unique to this `medaka build` process, and
-- removed before the driver returns.
--
-- This is the only scheme that is actually collision-proof.  Two earlier ones
-- were not:
--   * keying the IR path on the OUTPUT BASENAME (`/tmp/medaka_build_<base>.ll`)
--     is only *basename*-safe.  /tmp is GLOBAL: two concurrent builds of
--     DIFFERENT inputs that both write `-o <somedir>/out` — different worktrees,
--     different sessions, different repos — collided on one
--     /tmp/medaka_build_out.ll and linked each other's IR.  The failure was not
--     a crash but a stable-looking WRONG binary.
--   * the gc probe paths (/tmp/medaka_build_gcprobe.{c,out}) were FIXED — not
--     uniquified at all.
-- Even keying on the ABSOLUTE output path would not suffice: a rebuild racing
-- itself writes the same output path.  mktemp -d allocates the directory
-- atomically, so uniqueness depends on nothing but the process.  The 6-X
-- template is accepted by both GNU and BSD mktemp (dual-platform).
makeTempDir : Unit -> <IO> Result String String
makeTempDir _ = match runCommand "mktemp" ["-d", "/tmp/medaka_build_XXXXXX"]
  Err e => Err e
  Ok (0, out, _) =>
    let dir = stringTrim out
    if dir == "" then Err "mktemp -d printed no path" else Ok dir
  Ok (_, _, mtErr) =>
    let msg = stringTrim mtErr
    Err (if msg == "" then "mktemp -d failed" else msg)

-- Best-effort unlink of every entry the build staged in the scratch dir.  The
-- driver only ever writes flat files there, so removeFile suffices.
removeEntries : String -> List String -> <IO> Unit
removeEntries _ [] = ()
removeEntries dir (n::rest) =
  let _ = removeFile (joinPath dir n)
  removeEntries dir rest

-- Tear the scratch dir down so a build leaks nothing into /tmp.  Every Result is
-- discarded on purpose: a cleanup failure must never fail an otherwise-good build.
cleanupTempDir : String -> <IO> Unit
cleanupTempDir dir = match listDir dir
  Err _ => ()
  Ok entries =>
    let _ = removeEntries dir entries
    let _ = removeDir dir
    ()

-- ---- Boehm GC flag detection (pkg-config → brew → bare -lgc) ----
-- Returns Some (cflags, libs) or None.  tmpDir is the caller's per-invocation
-- scratch dir (the bare-lgc probe is staged inside it).
detectGC : String -> String -> <IO> Option (List String, List String)
detectGC cc tmpDir = match runCommand "pkg-config" ["--exists", "bdw-gc"]
  Ok (0, _, _) =>
    let cflags = gcQuery "pkg-config" ["--cflags", "bdw-gc"]
    let libs = gcQuery "pkg-config" ["--libs", "bdw-gc"]
    Some (splitWS cflags, splitWS libs)
  _ => detectGCBrew cc tmpDir

gcQuery : String -> List String -> <IO> String
gcQuery prog args = match runCommand prog args
  Ok (_, out, _) => stringTrim out
  Err _ => ""

detectGCBrew : String -> String -> <IO> Option (List String, List String)
detectGCBrew cc tmpDir = match runCommand "brew" ["--prefix", "bdw-gc"]
  Ok (0, out, _) =>
    let prefix = stringTrim out
    if prefix != "" && fileExists (joinPath prefix "include/gc.h") then
      Some (
        ["-I" ++ joinPath prefix "include"],
        ["-L" ++ joinPath prefix "lib", "-lgc"],
      )
    else
      detectGCBare cc tmpDir
  _ => detectGCBare cc tmpDir

-- Bare -lgc probe: compile a trivial gc.h program from a temp source.  Both the
-- probe source and its output binary go in the per-invocation scratch dir — they
-- used to be fixed /tmp paths, which two concurrent builds raced on.
detectGCBare : String -> String -> <IO> Option (List String, List String)
detectGCBare cc tmpDir =
  let probe = joinPath tmpDir "gcprobe.c"
  let probeOut = joinPath tmpDir "gcprobe.out"
  let _ = writeFile probe "#include <gc.h>\nint main(void){return 0;}\n"
  match runCommand cc [probe, "-lgc", "-o", probeOut]
    Ok (0, _, _) => Some ([], ["-lgc"])
    _ => None

-- ---- keep-IR (--keep-ir / MEDAKA_KEEP_IR) ----
-- Normally the emitted IR lives ONLY inside the per-process scratch dir
-- (makeTempDir) and is gone the instant the build returns — which is exactly
-- the problem for the project's #1 bug class ("check green / build silently
-- wrong"): the IR that actually produced the binary is the evidence, and by
-- default we destroy it.  `--keep-ir` (or the env var, for a build shelled out
-- by something else, e.g. a test harness) copies that IR to a PREDICTABLE
-- path next to the output binary — outPath ++ ".ll" (native) / ".wat" (wasm)
-- — and reports the path in the build's own result message.  Purely additive:
-- with neither the flag nor the env var set, effectiveKeepIr is False and
-- nothing about the scratch-dir lifecycle changes.
--
-- WHY "next to the output binary" is safe under concurrency, even though two
-- DIFFERENT builds sharing one `-o` is the exact shape that broke IR-path
-- uniqueness before (see makeTempDir's doc comment): here the compile itself
-- never reads this path — the kept file is a copy of IR that a build already
-- finished reading out of ITS OWN private tmpDir, written purely for the
-- human afterward.  So a foreign build can never be compiled from another
-- build's IR (the actual historical failure mode — a stable-looking WRONG
-- binary).  What remains is the ordinary last-write-wins race on `outPath`
-- itself when two builds target the same output path concurrently — a
-- pre-existing, accepted property of sharing an output path (the binary at
-- outPath already has it) — the kept-IR file just shares that same, already-
-- understood race, not a new one.
effectiveKeepIr : Bool -> <IO> Bool
effectiveKeepIr cliFlag = cliFlag || envOr "MEDAKA_KEEP_IR" "" != ""

-- Best-effort: a kept-IR write failure must never fail an otherwise-good
-- build, so its Result is folded into an informational note either way.
keepIrNote : String -> String -> <IO> String
keepIrNote path contents = match writeFile path contents
  Ok _ => "\nkept IR: " ++ path
  Err e => "\nwarning: could not keep IR at \{path}: " ++ e

-- ---- the build pipeline ----
-- root  = repo root (assets live under it)
-- medaka = path to the medaka exe (for the emit shell-out)
-- cc    = C compiler
-- target = TNative (LLVM/clang) | TWasm (WasmGC + wasm-tools)
-- inputAbs = absolute path of the user .mdk entry
-- outPath  = output binary path
-- keepIrCli = True iff `--keep-ir` was passed on the command line (OR'd with
--             MEDAKA_KEEP_IR inside effectiveKeepIr)
export runBuild : String -> String -> String -> BuildTarget -> String -> String -> Bool -> <IO> BuildResult
runBuild root medaka cc TNative inputAbs outPath keepIrCli =
  runBuildNative root medaka cc inputAbs outPath keepIrCli
runBuild root medaka cc TWasm inputAbs outPath keepIrCli =
  runBuildWasm root medaka inputAbs outPath keepIrCli

-- ---- native (LLVM/clang) target — the original path ----
-- Wrapper: allocate the per-invocation scratch dir (see makeTempDir), run the
-- build inside it, then tear it down whatever the outcome.  `res` is bound (and
-- so fully forced — Medaka is strict) BEFORE cleanupTempDir runs, so the .ll is
-- still on disk while clang reads it.
runBuildNative : String -> String -> String -> String -> String -> Bool -> <IO> BuildResult
runBuildNative root medaka cc inputAbs outPath keepIrCli = match makeTempDir ()
  Err e =>
    BuildErr "error: could not create a scratch directory for the build: \{e}"
  Ok tmpDir =>
    let res = runBuildNativeIn root medaka cc inputAbs outPath tmpDir keepIrCli
    let _ = cleanupTempDir tmpDir
    res

runBuildNativeIn : String -> String -> String -> String -> String -> String -> Bool -> <IO> BuildResult
runBuildNativeIn root medaka cc inputAbs outPath tmpDir keepIrCli =
  let emitter = joinPath root "compiler/entries/llvm_emit_modules_main.mdk"
  let runtimeP = joinPath root "stdlib/runtime.mdk"
  let preludeP = joinPath root "stdlib/core.mdk"
  let rtC = joinPath root "runtime/medaka_rt.c"
  let compilerDir = joinPath root "compiler"
  let stdlibDir = joinPath root "stdlib"
  -- P0-13: entrySearchRoots gives BOTH the entry's own dir (resolves a bare
  -- sibling import next to the entry, e.g. `src/main.mdk` importing
  -- `src/helper.mdk`'s `helper`) and the project root found by walking up from
  -- there (resolves a dotted cross-package import rooted at the project dir) —
  -- see the loader.mdk doc comment. A single `findProjectRoot` root here used to
  -- swallow the sibling-import case whenever a `medaka.toml` sat above the
  -- entry's own directory.
  let inputRoots = entrySearchRoots (dirOf inputAbs)
  -- Stage the IR inside THIS invocation's private scratch dir (makeTempDir).  It
  -- used to be /tmp/medaka_build_<output basename>.ll, which is only
  -- basename-unique in a GLOBAL directory — concurrent builds writing the same
  -- output basename (very common: `-o <tmpdir>/out`) overwrote each other's IR.
  let llPath = joinPath tmpDir "program.ll"
  let emitArgsBase = [runtimeP, preludeP, inputAbs] ++ inputRoots ++ [compilerDir, stdlibDir]
  let emitter2 = envOr "MEDAKA_EMITTER" defaultMedakaEmitter
  let useNative = emitter2 != ""
  let emitProg = if useNative then emitter2 else medaka
  let emitArgs = if useNative then
    emitArgsBase
  else
    "run" :: emitter::emitArgsBase
  match runCommand emitProg emitArgs
    Err e =>
      BuildErr "error: could not run emitter (\{emitProg}): \{e}"
    Ok (code, irRaw, emitErr) => if code != 0 then BuildErr "error: emitter failed compiling \{inputAbs}\n\{emitErr}"
    else
      let ir = stripTrailingUnit irRaw
      if stringLength ir == 0 then BuildErr "error: emitter produced empty IR for \{inputAbs}\n\{emitErr}"
      else match writeFile llPath ir
        Err e => BuildErr ("error: could not write IR: " ++ e)
        Ok _ =>
          -- --keep-ir / MEDAKA_KEEP_IR: copy the IR to a predictable path next
          -- to the output binary AFTER clangLink returns (success or failure —
          -- a clang failure is exactly the case where seeing the IR matters
          -- most), not before.  This is deliberate, not incidental: two
          -- concurrent builds of DIFFERENT programs sharing one `-o` each run
          -- an independent last-write-wins race on outPath (pre-existing,
          -- inherent to sharing an output path) AND, if we copied the .ll
          -- first, a SEPARATE independent race on outPath++".ll" — the two
          -- races can pick different "winners", pairing build A's binary with
          -- build B's kept IR (silently misleading — measured empirically:
          -- ~1/3 of trials crossed when the .ll copy ran before clangLink).
          -- Writing the copy immediately after clangLink returns collapses the
          -- two races to nearly the same instant in each process's timeline,
          -- so whichever build's clang finishes last is also the one most
          -- likely to finish its .ll copy last. This narrows, but for a
          -- same-`-o` race cannot fully eliminate, the crossing window — see
          -- the concurrency note on effectiveKeepIr for why builds to
          -- DISTINCT `-o` paths (the normal, sane usage) have NO such race at
          -- all.
          let res = clangLink cc rtC llPath outPath inputAbs tmpDir
          let note = if effectiveKeepIr keepIrCli then keepIrNote (outPath ++ ".ll") ir else ""
          appendNote note res

-- ---- wasm (WasmGC + wasm-tools) target ----
-- Structurally identical to runBuildNative: run the emitter (here the WasmGC
-- modules entry) via a fresh subprocess, capture its WAT on stdout, then assemble
-- with `wasm-tools parse` (the clang analogue) and `wasm-tools validate` (GC
-- validation, on by default) instead of clang.
--
-- EMITTER BINARY.  Like the LLVM path, the emitter must be a COMPILED binary, not
-- `medaka run <entry>`: the entry's `main = match args ()` needs the `args` runtime
-- extern, which exists in the native runtime but NOT in the native interpreter's
-- run mode — so `medaka run <emitter>` fails at resolve (`unbound identifier:
-- args`) for the LLVM entry too.  The LLVM path sidesteps this via the compiled
-- MEDAKA_EMITTER binary, which defaults to `<exeDir>/medaka_emitter` (a self-
-- locating default — `make medaka` always builds it alongside `medaka`, so the
-- LLVM path needs no env var in the common case).  The wasm peer has NO such
-- self-locating default (there is no fixed post-build location for the wasm
-- emitter binary), so MEDAKA_WASM_EMITTER MUST be set — build one with
-- `test/wasm/build_wasm_oracle.sh` (produces test/bin/wasm_emit_modules_main).
--
-- ⚠️ T-22 (2026-07-14): this used to fall back to `medaka run <entry>` when unset,
-- on the theory that the failure would be "surfaced clearly" — it was not. `medaka`
-- here is whatever `envOr "MEDAKA" "medaka"` resolves to (a bare PATH-relative name
-- by default, NOT this process's own exeDir), so the fallback typically shells a
-- `medaka` that plain isn't found on PATH — `runCommand` reports that as a bare
-- "No such file or directory", which names neither the missing env var nor the
-- fix. Three separate agents lost time to this. No in-repo caller ever relied on
-- the fallback actually working (every gate that drives --target wasm sets
-- MEDAKA_WASM_EMITTER itself), so it is now an explicit, actionable error instead
-- of a silent, broken code path — the same treatment probeWasmTools already gets
-- below for missing wasm-tools.
-- Args mirror the LLVM root set: the COMPILED binary takes positional
-- <runtime> <core> <entry> <inputDir> <compiler> <stdlib> (the wasm entry takes
-- any number of roots after the entry).
runBuildWasm : String -> String -> String -> String -> Bool -> <IO> BuildResult
runBuildWasm root medaka inputAbs outPath keepIrCli = match makeTempDir ()
  Err e =>
    BuildErr "error: could not create a scratch directory for the build: \{e}"
  Ok tmpDir =>
    let res = runBuildWasmIn root medaka inputAbs outPath tmpDir keepIrCli
    let _ = cleanupTempDir tmpDir
    res

runBuildWasmIn : String -> String -> String -> String -> String -> Bool -> <IO> BuildResult
runBuildWasmIn root medaka inputAbs outPath tmpDir keepIrCli =
  let runtimeP = joinPath root "stdlib/runtime.mdk"
  let preludeP = joinPath root "stdlib/core.mdk"
  let compilerDir = joinPath root "compiler"
  let stdlibDir = joinPath root "stdlib"
  -- P0-13: see the comment on runBuildNative's inputRoots — same fix.
  let inputRoots = entrySearchRoots (dirOf inputAbs)
  -- Same scratch-path invariant as the native path: the WAT is staged in THIS
  -- invocation's private mktemp dir, not at a globally-shared
  -- /tmp/medaka_build_<output basename>.wat that a concurrent build can clobber.
  let watPath = joinPath tmpDir "program.wat"
  let emitArgsBase = [runtimeP, preludeP, inputAbs] ++ inputRoots ++ [compilerDir, stdlibDir]
  let wasmEmitter = envOr "MEDAKA_WASM_EMITTER" ""
  -- Surface a missing/unset/mistyped MEDAKA_WASM_EMITTER as an actionable error
  -- here; without this, runCommand fails with a bare "No such file or directory"
  -- that names neither the variable nor the fix.
  if wasmEmitter == "" then
    BuildErr "error: --target wasm needs a compiled wasm emitter — set MEDAKA_WASM_EMITTER to its path\n  build one with: sh test/wasm/build_wasm_oracle.sh (produces test/bin/wasm_emit_modules_main)"
  else if !fileExists wasmEmitter then
    BuildErr "error: MEDAKA_WASM_EMITTER points to a missing binary: \{wasmEmitter}\n  build it with: sh test/wasm/build_wasm_oracle.sh (produces test/bin/wasm_emit_modules_main)"
  else match probeWasmTools ()
    None => BuildErr "error: wasm-tools not found on PATH — install wasm-tools (cargo install wasm-tools or brew install wasm-tools) for --target wasm"
    Some _ => match runCommand wasmEmitter emitArgsBase
      Err e => BuildErr "error: could not run wasm emitter (\{wasmEmitter}): \{e}"
      Ok (code, watRaw, emitErr) => if code != 0 then BuildErr "error: wasm emitter failed compiling \{inputAbs}\n\{emitErr}"
      else
        let wat = stripTrailingUnit watRaw
        if stringLength wat == 0 then BuildErr "error: wasm emitter produced empty WAT for \{inputAbs}\n\{emitErr}"
        else match writeFile watPath wat
          Err e => BuildErr ("error: could not write WAT: " ++ e)
          Ok _ =>
            -- Same --keep-ir handling as the native path (.wat instead of
            -- .ll), including the AFTER-assemble ordering — see the comment
            -- on the native path's runBuildNativeIn for why.
            let res = wasmAssemble watPath outPath inputAbs
            let note = if effectiveKeepIr keepIrCli then keepIrNote (outPath ++ ".wat") wat else ""
            appendNote note res

-- Probe `wasm-tools` up front (the wasm analogue of the implicit clang
-- requirement).  `wasm-tools --version` exits 0 iff the tool is reachable.
probeWasmTools : Unit -> <IO> Option Unit
probeWasmTools _ = match runCommand "wasm-tools" ["--version"]
  Ok (0, _, _) => Some ()
  _ => None

-- STEP 2 (wasm): assemble the WAT to a .wasm with `wasm-tools parse`, then GC-
-- validate it with `wasm-tools validate`.  Surfaces each tool's own stderr on
-- failure.  `--features=all` matches the gate scripts' validate (GC + tail-call).
wasmAssemble : String -> String -> String -> <IO> BuildResult
wasmAssemble watPath outPath inputAbs = match runCommand "wasm-tools" ["parse", watPath, "-o", outPath]
  Err e => BuildErr ("error: could not run wasm-tools parse: " ++ e)
  Ok (0, _, _) => match runCommand "wasm-tools" ["validate", "--features=all", outPath]
    Err e => BuildErr ("error: could not run wasm-tools validate: " ++ e)
    Ok (0, _, _) => BuildOk "built \{inputAbs} -> \{outPath}"
    Ok (_, _, valErr) =>
      BuildErr "error: wasm-tools validate rejected \{outPath}\n\{valErr}"
  Ok (_, _, parseErr) => BuildErr "error: wasm-tools parse failed assembling \{inputAbs}\n\{parseErr}"
-- EMIT STEP.  Two paths, selected by the MEDAKA_EMITTER env var:
--   * set   → invoke that NATIVE EMITTER BINARY directly (OCaml-free path — the
--             clang(seed) binary from test/bootstrap_from_seed.sh).  Args are the
--             emitter's positional inputs WITHOUT the "run <emitter>" prefix.
--   * unset → fall back to a fresh `medaka run <emitter> …` subprocess (the
--             original OCaml-interpreter path; nothing regresses).
-- Both receive identical <runtime> <prelude> <input> <inputDir> <compiler> <stdlib>
-- args and produce identical IR (the native emitter is the clang-compiled seed,
-- byte-fixpoint with the interpreter — selfcompile_build_fixpoint.sh C3a/C3b).

-- STEP 1: emit LLVM IR via a FRESH subprocess (Ref-state isolation).
-- Roots: inputDir (user modules shadow stdlib), compiler, stdlib — mirrors
-- the loader's root-ordered search and build_cmd.ml's emit_argv.

-- STEP 2: clang the IR + C runtime + Boehm GC into a native binary.
clangLink : String -> String -> String -> String -> String -> String -> <IO> BuildResult
clangLink cc rtC llPath outPath inputAbs tmpDir = match detectGC cc tmpDir
  None => BuildErr "error: libgc (bdw-gc) not found — install bdw-gc (brew install bdw-gc) or set GC_PREFIX/pkg-config"
  Some (gcCflags, gcLibs) =>
    -- Optimization level is overridable via MEDAKA_CLANG_OPT (default -O2). The
    -- oracle build (test/build_oracles.sh) sets a lower level: those are throwaway
    -- test binaries where clang -O2 (~half the per-build wall time) buys little
    -- runtime on the small gate fixtures they process.
    let optFlagRaw = envOr "MEDAKA_CLANG_OPT" "-O2"
    let optFlag = if optFlagRaw == "" then "-O2" else optFlagRaw
    -- The runtime (runtime/medaka_rt.c) runs the compiled program on a 256 MB
    -- worker thread via GC_pthread_create, so it self-provisions its stack: no
    -- Mach-O-only `-Wl,-stack_size` link flag is needed on either platform.
    -- `-pthread` (thread runtime) and `-lm` (math externs) go on every link.
    let clangArgs = [optFlag, "-pthread"] ++ gcCflags ++ [llPath, rtC] ++ gcLibs ++ ["-lm", "-o", outPath]
    match runCommand cc clangArgs
      Err e => BuildErr "error: could not run clang (\{cc}): \{e}"
      Ok (0, _, _) => BuildOk "built \{inputAbs} -> \{outPath}"
      Ok (_, _, ccErr) =>
        BuildErr "error: clang failed linking \{inputAbs}\n\{ccErr}"
# DESUGAR
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "entrySearchRoots" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "chopExt" false) (mem "joinPath" false))))
(DData Public "BuildResult" () ((variant "BuildOk" (ConPos (TyCon "String"))) (variant "BuildErr" (ConPos (TyCon "String")))) ())
(DData Public "BuildTarget" () ((variant "TNative" (ConPos)) (variant "TWasm" (ConPos))) ())
(DTypeSig false "appendNote" (TyFun (TyCon "String") (TyFun (TyCon "BuildResult") (TyCon "BuildResult"))))
(DFunDef false "appendNote" ((PVar "note") (PCon "BuildOk" (PVar "m"))) (EApp (EVar "BuildOk") (EBinOp "++" (EVar "m") (EVar "note"))))
(DFunDef false "appendNote" ((PVar "note") (PCon "BuildErr" (PVar "m"))) (EApp (EVar "BuildErr") (EBinOp "++" (EVar "m") (EVar "note"))))
(DTypeSig false "isWS" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isWS" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LString " "))) (EBinOp "==" (EVar "c") (ELit (LString "\n")))) (EBinOp "==" (EVar "c") (ELit (LString "\t")))) (EBinOp "==" (EVar "c") (ELit (LString "\r")))))
(DTypeSig false "splitWS" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitWS" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "splitWSGo") (EApp (EVar "stringTrim") (EVar "s"))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)))
(DTypeSig false "splitWSGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitWSGo" ((PVar "s") (PVar "i") (PVar "start") (PVar "acc")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EIf (EBinOp ">" (EVar "i") (EVar "start")) (EApp (EVar "reverseL") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "i")) (EVar "s")) (EVar "acc"))) (EApp (EVar "reverseL") (EVar "acc"))) (EIf (EApp (EVar "isWS") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s"))) (EBlock (DoLet false false (PVar "acc2") (EIf (EBinOp ">" (EVar "i") (EVar "start")) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "i")) (EVar "s")) (EVar "acc")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "splitWSGo") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc2")))) (EApp (EApp (EApp (EApp (EVar "splitWSGo") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "start")) (EVar "acc")))))))
(DTypeSig true "envOr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "envOr" ((PVar "name") (PVar "dflt")) (EMatch (EApp (EVar "getEnv") (EVar "name")) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (EVar "dflt") (EVar "v"))) (arm (PCon "None") () (EVar "dflt"))))
(DTypeSig true "exeDir" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "exeDir" () (EApp (EVar "dirOf") (EApp (EVar "executablePath") (ELit LUnit))))
(DTypeSig true "defaultMedakaRoot" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "defaultMedakaRoot" () (EVar "exeDir"))
(DTypeSig true "defaultMedakaEmitter" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "defaultMedakaEmitter" () (EApp (EApp (EVar "joinPath") (EVar "exeDir")) (ELit (LString "medaka_emitter"))))
(DTypeSig false "stripTrailingUnit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripTrailingUnit" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 3)))) (EVar "n")) (EVar "s")) (ELit (LString "()\n")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 3)))) (EVar "s")) (EVar "s")))))
(DTypeSig false "makeTempDir" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "makeTempDir" (PWild) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mktemp"))) (EListLit (ELit (LString "-d")) (ELit (LString "/tmp/medaka_build_XXXXXX")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "dir") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (EApp (EVar "Err") (ELit (LString "mktemp -d printed no path"))) (EApp (EVar "Ok") (EVar "dir")))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "mtErr"))) () (EBlock (DoLet false false (PVar "msg") (EApp (EVar "stringTrim") (EVar "mtErr"))) (DoExpr (EApp (EVar "Err") (EIf (EBinOp "==" (EVar "msg") (ELit (LString ""))) (ELit (LString "mktemp -d failed")) (EVar "msg"))))))))
(DTypeSig false "removeEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "removeEntries" (PWild (PList)) (ELit LUnit))
(DFunDef false "removeEntries" ((PVar "dir") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "removeFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EVar "n")))) (DoExpr (EApp (EApp (EVar "removeEntries") (EVar "dir")) (EVar "rest")))))
(DTypeSig false "cleanupTempDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "cleanupTempDir" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" (PVar "entries")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "removeEntries") (EVar "dir")) (EVar "entries"))) (DoLet false false PWild (EApp (EVar "removeDir") (EVar "dir"))) (DoExpr (ELit LUnit))))))
(DTypeSig false "detectGC" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "detectGC" ((PVar "cc") (PVar "tmpDir")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "pkg-config"))) (EListLit (ELit (LString "--exists")) (ELit (LString "bdw-gc")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EBlock (DoLet false false (PVar "cflags") (EApp (EApp (EVar "gcQuery") (ELit (LString "pkg-config"))) (EListLit (ELit (LString "--cflags")) (ELit (LString "bdw-gc"))))) (DoLet false false (PVar "libs") (EApp (EApp (EVar "gcQuery") (ELit (LString "pkg-config"))) (EListLit (ELit (LString "--libs")) (ELit (LString "bdw-gc"))))) (DoExpr (EApp (EVar "Some") (ETuple (EApp (EVar "splitWS") (EVar "cflags")) (EApp (EVar "splitWS") (EVar "libs"))))))) (arm PWild () (EApp (EApp (EVar "detectGCBrew") (EVar "cc")) (EVar "tmpDir")))))
(DTypeSig false "gcQuery" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "gcQuery" ((PVar "prog") (PVar "args")) (EMatch (EApp (EApp (EVar "runCommand") (EVar "prog")) (EVar "args")) (arm (PCon "Ok" (PTuple PWild (PVar "out") PWild)) () (EApp (EVar "stringTrim") (EVar "out"))) (arm (PCon "Err" PWild) () (ELit (LString "")))))
(DTypeSig false "detectGCBrew" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "detectGCBrew" ((PVar "cc") (PVar "tmpDir")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "brew"))) (EListLit (ELit (LString "--prefix")) (ELit (LString "bdw-gc")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "prefix") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "!=" (EVar "prefix") (ELit (LString ""))) (EApp (EVar "fileExists") (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "include/gc.h"))))) (EApp (EVar "Some") (ETuple (EListLit (EBinOp "++" (ELit (LString "-I")) (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "include"))))) (EListLit (EBinOp "++" (ELit (LString "-L")) (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "lib")))) (ELit (LString "-lgc"))))) (EApp (EApp (EVar "detectGCBare") (EVar "cc")) (EVar "tmpDir")))))) (arm PWild () (EApp (EApp (EVar "detectGCBare") (EVar "cc")) (EVar "tmpDir")))))
(DTypeSig false "detectGCBare" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "detectGCBare" ((PVar "cc") (PVar "tmpDir")) (EBlock (DoLet false false (PVar "probe") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "gcprobe.c")))) (DoLet false false (PVar "probeOut") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "gcprobe.out")))) (DoLet false false PWild (EApp (EApp (EVar "writeFile") (EVar "probe")) (ELit (LString "#include <gc.h>\nint main(void){return 0;}\n")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "cc")) (EListLit (EVar "probe") (ELit (LString "-lgc")) (ELit (LString "-o")) (EVar "probeOut"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "Some") (ETuple (EListLit) (EListLit (ELit (LString "-lgc")))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "effectiveKeepIr" (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "effectiveKeepIr" ((PVar "cliFlag")) (EBinOp "||" (EVar "cliFlag") (EBinOp "!=" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_KEEP_IR"))) (ELit (LString ""))) (ELit (LString "")))))
(DTypeSig false "keepIrNote" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "keepIrNote" ((PVar "path") (PVar "contents")) (EMatch (EApp (EApp (EVar "writeFile") (EVar "path")) (EVar "contents")) (arm (PCon "Ok" PWild) () (EBinOp "++" (ELit (LString "\nkept IR: ")) (EVar "path"))) (arm (PCon "Err" (PVar "e")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\nwarning: could not keep IR at ")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ": "))) (EVar "e")))))
(DTypeSig true "runBuild" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "BuildTarget") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult"))))))))))
(DFunDef false "runBuild" ((PVar "root") (PVar "medaka") (PVar "cc") (PCon "TNative") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNative") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "inputAbs")) (EVar "outPath")) (EVar "keepIrCli")))
(DFunDef false "runBuild" ((PVar "root") (PVar "medaka") (PVar "cc") (PCon "TWasm") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EApp (EApp (EApp (EApp (EApp (EVar "runBuildWasm") (EVar "root")) (EVar "medaka")) (EVar "inputAbs")) (EVar "outPath")) (EVar "keepIrCli")))
(DTypeSig false "runBuildNative" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult")))))))))
(DFunDef false "runBuildNative" ((PVar "root") (PVar "medaka") (PVar "cc") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not create a scratch directory for the build: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNativeIn") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "inputAbs")) (EVar "outPath")) (EVar "tmpDir")) (EVar "keepIrCli"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "res"))))))
(DTypeSig false "runBuildNativeIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult"))))))))))
(DFunDef false "runBuildNativeIn" ((PVar "root") (PVar "medaka") (PVar "cc") (PVar "inputAbs") (PVar "outPath") (PVar "tmpDir") (PVar "keepIrCli")) (EBlock (DoLet false false (PVar "emitter") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler/entries/llvm_emit_modules_main.mdk")))) (DoLet false false (PVar "runtimeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/runtime.mdk")))) (DoLet false false (PVar "preludeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/core.mdk")))) (DoLet false false (PVar "rtC") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "runtime/medaka_rt.c")))) (DoLet false false (PVar "compilerDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler")))) (DoLet false false (PVar "stdlibDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib")))) (DoLet false false (PVar "inputRoots") (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "inputAbs")))) (DoLet false false (PVar "llPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "program.ll")))) (DoLet false false (PVar "emitArgsBase") (EBinOp "++" (EBinOp "++" (EListLit (EVar "runtimeP") (EVar "preludeP") (EVar "inputAbs")) (EVar "inputRoots")) (EListLit (EVar "compilerDir") (EVar "stdlibDir")))) (DoLet false false (PVar "emitter2") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_EMITTER"))) (EVar "defaultMedakaEmitter"))) (DoLet false false (PVar "useNative") (EBinOp "!=" (EVar "emitter2") (ELit (LString "")))) (DoLet false false (PVar "emitProg") (EIf (EVar "useNative") (EVar "emitter2") (EVar "medaka"))) (DoLet false false (PVar "emitArgs") (EIf (EVar "useNative") (EVar "emitArgsBase") (EBinOp "::" (ELit (LString "run")) (EBinOp "::" (EVar "emitter") (EVar "emitArgsBase"))))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "emitProg")) (EVar "emitArgs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run emitter (")) (EApp (EVar "display") (EVar "emitProg"))) (ELit (LString "): "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "irRaw") (PVar "emitErr"))) () (EIf (EBinOp "!=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: emitter failed compiling ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "emitErr"))) (ELit (LString "")))) (EBlock (DoLet false false (PVar "ir") (EApp (EVar "stripTrailingUnit") (EVar "irRaw"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "ir")) (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: emitter produced empty IR for ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "emitErr"))) (ELit (LString "")))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "llPath")) (EVar "ir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not write IR: ")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clangLink") (EVar "cc")) (EVar "rtC")) (EVar "llPath")) (EVar "outPath")) (EVar "inputAbs")) (EVar "tmpDir"))) (DoLet false false (PVar "note") (EIf (EApp (EVar "effectiveKeepIr") (EVar "keepIrCli")) (EApp (EApp (EVar "keepIrNote") (EBinOp "++" (EVar "outPath") (ELit (LString ".ll")))) (EVar "ir")) (ELit (LString "")))) (DoExpr (EApp (EApp (EVar "appendNote") (EVar "note")) (EVar "res")))))))))))))))
(DTypeSig false "runBuildWasm" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult"))))))))
(DFunDef false "runBuildWasm" ((PVar "root") (PVar "medaka") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not create a scratch directory for the build: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildWasmIn") (EVar "root")) (EVar "medaka")) (EVar "inputAbs")) (EVar "outPath")) (EVar "tmpDir")) (EVar "keepIrCli"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "res"))))))
(DTypeSig false "runBuildWasmIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult")))))))))
(DFunDef false "runBuildWasmIn" ((PVar "root") (PVar "medaka") (PVar "inputAbs") (PVar "outPath") (PVar "tmpDir") (PVar "keepIrCli")) (EBlock (DoLet false false (PVar "runtimeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/runtime.mdk")))) (DoLet false false (PVar "preludeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/core.mdk")))) (DoLet false false (PVar "compilerDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler")))) (DoLet false false (PVar "stdlibDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib")))) (DoLet false false (PVar "inputRoots") (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "inputAbs")))) (DoLet false false (PVar "watPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "program.wat")))) (DoLet false false (PVar "emitArgsBase") (EBinOp "++" (EBinOp "++" (EListLit (EVar "runtimeP") (EVar "preludeP") (EVar "inputAbs")) (EVar "inputRoots")) (EListLit (EVar "compilerDir") (EVar "stdlibDir")))) (DoLet false false (PVar "wasmEmitter") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_WASM_EMITTER"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "wasmEmitter") (ELit (LString ""))) (EApp (EVar "BuildErr") (ELit (LString "error: --target wasm needs a compiled wasm emitter — set MEDAKA_WASM_EMITTER to its path\n  build one with: sh test/wasm/build_wasm_oracle.sh (produces test/bin/wasm_emit_modules_main)"))) (EIf (EUnOp "!" (EApp (EVar "fileExists") (EVar "wasmEmitter"))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: MEDAKA_WASM_EMITTER points to a missing binary: ")) (EApp (EVar "display") (EVar "wasmEmitter"))) (ELit (LString "\n  build it with: sh test/wasm/build_wasm_oracle.sh (produces test/bin/wasm_emit_modules_main)")))) (EMatch (EApp (EVar "probeWasmTools") (ELit LUnit)) (arm (PCon "None") () (EApp (EVar "BuildErr") (ELit (LString "error: wasm-tools not found on PATH — install wasm-tools (cargo install wasm-tools or brew install wasm-tools) for --target wasm")))) (arm (PCon "Some" PWild) () (EMatch (EApp (EApp (EVar "runCommand") (EVar "wasmEmitter")) (EVar "emitArgsBase")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run wasm emitter (")) (EApp (EVar "display") (EVar "wasmEmitter"))) (ELit (LString "): "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "watRaw") (PVar "emitErr"))) () (EIf (EBinOp "!=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm emitter failed compiling ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "emitErr"))) (ELit (LString "")))) (EBlock (DoLet false false (PVar "wat") (EApp (EVar "stripTrailingUnit") (EVar "watRaw"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "wat")) (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm emitter produced empty WAT for ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "emitErr"))) (ELit (LString "")))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "watPath")) (EVar "wat")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not write WAT: ")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EVar "wasmAssemble") (EVar "watPath")) (EVar "outPath")) (EVar "inputAbs"))) (DoLet false false (PVar "note") (EIf (EApp (EVar "effectiveKeepIr") (EVar "keepIrCli")) (EApp (EApp (EVar "keepIrNote") (EBinOp "++" (EVar "outPath") (ELit (LString ".wat")))) (EVar "wat")) (ELit (LString "")))) (DoExpr (EApp (EApp (EVar "appendNote") (EVar "note")) (EVar "res")))))))))))))))))))
(DTypeSig false "probeWasmTools" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Unit")))))
(DFunDef false "probeWasmTools" (PWild) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "wasm-tools"))) (EListLit (ELit (LString "--version")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "Some") (ELit LUnit))) (arm PWild () (EVar "None"))))
(DTypeSig false "wasmAssemble" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "BuildResult"))))))
(DFunDef false "wasmAssemble" ((PVar "watPath") (PVar "outPath") (PVar "inputAbs")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "wasm-tools"))) (EListLit (ELit (LString "parse")) (EVar "watPath") (ELit (LString "-o")) (EVar "outPath"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not run wasm-tools parse: ")) (EVar "e")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "wasm-tools"))) (EListLit (ELit (LString "validate")) (ELit (LString "--features=all")) (EVar "outPath"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not run wasm-tools validate: ")) (EVar "e")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "BuildOk") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "built ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString " -> "))) (EApp (EVar "display") (EVar "outPath"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "valErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm-tools validate rejected ")) (EApp (EVar "display") (EVar "outPath"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "valErr"))) (ELit (LString ""))))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "parseErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm-tools parse failed assembling ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "parseErr"))) (ELit (LString "")))))))
(DTypeSig false "clangLink" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "BuildResult")))))))))
(DFunDef false "clangLink" ((PVar "cc") (PVar "rtC") (PVar "llPath") (PVar "outPath") (PVar "inputAbs") (PVar "tmpDir")) (EMatch (EApp (EApp (EVar "detectGC") (EVar "cc")) (EVar "tmpDir")) (arm (PCon "None") () (EApp (EVar "BuildErr") (ELit (LString "error: libgc (bdw-gc) not found — install bdw-gc (brew install bdw-gc) or set GC_PREFIX/pkg-config")))) (arm (PCon "Some" (PTuple (PVar "gcCflags") (PVar "gcLibs"))) () (EBlock (DoLet false false (PVar "optFlagRaw") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_CLANG_OPT"))) (ELit (LString "-O2")))) (DoLet false false (PVar "optFlag") (EIf (EBinOp "==" (EVar "optFlagRaw") (ELit (LString ""))) (ELit (LString "-O2")) (EVar "optFlagRaw"))) (DoLet false false (PVar "clangArgs") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EVar "optFlag") (ELit (LString "-pthread"))) (EVar "gcCflags")) (EListLit (EVar "llPath") (EVar "rtC"))) (EVar "gcLibs")) (EListLit (ELit (LString "-lm")) (ELit (LString "-o")) (EVar "outPath")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "cc")) (EVar "clangArgs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run clang (")) (EApp (EVar "display") (EVar "cc"))) (ELit (LString "): "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "BuildOk") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "built ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString " -> "))) (EApp (EVar "display") (EVar "outPath"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "ccErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: clang failed linking ")) (EApp (EVar "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "ccErr"))) (ELit (LString "")))))))))))
# MARK
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "entrySearchRoots" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false) (mem "chopExt" false) (mem "joinPath" false))))
(DData Public "BuildResult" () ((variant "BuildOk" (ConPos (TyCon "String"))) (variant "BuildErr" (ConPos (TyCon "String")))) ())
(DData Public "BuildTarget" () ((variant "TNative" (ConPos)) (variant "TWasm" (ConPos))) ())
(DTypeSig false "appendNote" (TyFun (TyCon "String") (TyFun (TyCon "BuildResult") (TyCon "BuildResult"))))
(DFunDef false "appendNote" ((PVar "note") (PCon "BuildOk" (PVar "m"))) (EApp (EVar "BuildOk") (EBinOp "++" (EVar "m") (EVar "note"))))
(DFunDef false "appendNote" ((PVar "note") (PCon "BuildErr" (PVar "m"))) (EApp (EVar "BuildErr") (EBinOp "++" (EVar "m") (EVar "note"))))
(DTypeSig false "isWS" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isWS" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LString " "))) (EBinOp "==" (EVar "c") (ELit (LString "\n")))) (EBinOp "==" (EVar "c") (ELit (LString "\t")))) (EBinOp "==" (EVar "c") (ELit (LString "\r")))))
(DTypeSig false "splitWS" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitWS" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "splitWSGo") (EApp (EVar "stringTrim") (EVar "s"))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit)))
(DTypeSig false "splitWSGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitWSGo" ((PVar "s") (PVar "i") (PVar "start") (PVar "acc")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EIf (EBinOp ">" (EVar "i") (EVar "start")) (EApp (EVar "reverseL") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "i")) (EVar "s")) (EVar "acc"))) (EApp (EVar "reverseL") (EVar "acc"))) (EIf (EApp (EVar "isWS") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s"))) (EBlock (DoLet false false (PVar "acc2") (EIf (EBinOp ">" (EVar "i") (EVar "start")) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "i")) (EVar "s")) (EVar "acc")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "splitWSGo") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc2")))) (EApp (EApp (EApp (EApp (EVar "splitWSGo") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "start")) (EVar "acc")))))))
(DTypeSig true "envOr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "envOr" ((PVar "name") (PVar "dflt")) (EMatch (EApp (EVar "getEnv") (EVar "name")) (arm (PCon "Some" (PVar "v")) () (EIf (EBinOp "==" (EVar "v") (ELit (LString ""))) (EVar "dflt") (EVar "v"))) (arm (PCon "None") () (EVar "dflt"))))
(DTypeSig true "exeDir" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "exeDir" () (EApp (EVar "dirOf") (EApp (EVar "executablePath") (ELit LUnit))))
(DTypeSig true "defaultMedakaRoot" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "defaultMedakaRoot" () (EVar "exeDir"))
(DTypeSig true "defaultMedakaEmitter" (TyEffect ("IO") None (TyCon "String")))
(DFunDef false "defaultMedakaEmitter" () (EApp (EApp (EVar "joinPath") (EVar "exeDir")) (ELit (LString "medaka_emitter"))))
(DTypeSig false "stripTrailingUnit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripTrailingUnit" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 3)))) (EVar "n")) (EVar "s")) (ELit (LString "()\n")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 3)))) (EVar "s")) (EVar "s")))))
(DTypeSig false "makeTempDir" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "makeTempDir" (PWild) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "mktemp"))) (EListLit (ELit (LString "-d")) (ELit (LString "/tmp/medaka_build_XXXXXX")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "dir") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (EApp (EVar "Err") (ELit (LString "mktemp -d printed no path"))) (EApp (EVar "Ok") (EVar "dir")))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "mtErr"))) () (EBlock (DoLet false false (PVar "msg") (EApp (EVar "stringTrim") (EVar "mtErr"))) (DoExpr (EApp (EVar "Err") (EIf (EBinOp "==" (EVar "msg") (ELit (LString ""))) (ELit (LString "mktemp -d failed")) (EVar "msg"))))))))
(DTypeSig false "removeEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "removeEntries" (PWild (PList)) (ELit LUnit))
(DFunDef false "removeEntries" ((PVar "dir") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "removeFile") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EVar "n")))) (DoExpr (EApp (EApp (EVar "removeEntries") (EVar "dir")) (EVar "rest")))))
(DTypeSig false "cleanupTempDir" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "cleanupTempDir" ((PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" (PVar "entries")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "removeEntries") (EVar "dir")) (EVar "entries"))) (DoLet false false PWild (EApp (EVar "removeDir") (EVar "dir"))) (DoExpr (ELit LUnit))))))
(DTypeSig false "detectGC" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "detectGC" ((PVar "cc") (PVar "tmpDir")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "pkg-config"))) (EListLit (ELit (LString "--exists")) (ELit (LString "bdw-gc")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EBlock (DoLet false false (PVar "cflags") (EApp (EApp (EVar "gcQuery") (ELit (LString "pkg-config"))) (EListLit (ELit (LString "--cflags")) (ELit (LString "bdw-gc"))))) (DoLet false false (PVar "libs") (EApp (EApp (EVar "gcQuery") (ELit (LString "pkg-config"))) (EListLit (ELit (LString "--libs")) (ELit (LString "bdw-gc"))))) (DoExpr (EApp (EVar "Some") (ETuple (EApp (EVar "splitWS") (EVar "cflags")) (EApp (EVar "splitWS") (EVar "libs"))))))) (arm PWild () (EApp (EApp (EVar "detectGCBrew") (EVar "cc")) (EVar "tmpDir")))))
(DTypeSig false "gcQuery" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "gcQuery" ((PVar "prog") (PVar "args")) (EMatch (EApp (EApp (EVar "runCommand") (EVar "prog")) (EVar "args")) (arm (PCon "Ok" (PTuple PWild (PVar "out") PWild)) () (EApp (EVar "stringTrim") (EVar "out"))) (arm (PCon "Err" PWild) () (ELit (LString "")))))
(DTypeSig false "detectGCBrew" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "detectGCBrew" ((PVar "cc") (PVar "tmpDir")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "brew"))) (EListLit (ELit (LString "--prefix")) (ELit (LString "bdw-gc")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) (PVar "out") PWild)) () (EBlock (DoLet false false (PVar "prefix") (EApp (EVar "stringTrim") (EVar "out"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "!=" (EVar "prefix") (ELit (LString ""))) (EApp (EVar "fileExists") (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "include/gc.h"))))) (EApp (EVar "Some") (ETuple (EListLit (EBinOp "++" (ELit (LString "-I")) (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "include"))))) (EListLit (EBinOp "++" (ELit (LString "-L")) (EApp (EApp (EVar "joinPath") (EVar "prefix")) (ELit (LString "lib")))) (ELit (LString "-lgc"))))) (EApp (EApp (EVar "detectGCBare") (EVar "cc")) (EVar "tmpDir")))))) (arm PWild () (EApp (EApp (EVar "detectGCBare") (EVar "cc")) (EVar "tmpDir")))))
(DTypeSig false "detectGCBare" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "detectGCBare" ((PVar "cc") (PVar "tmpDir")) (EBlock (DoLet false false (PVar "probe") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "gcprobe.c")))) (DoLet false false (PVar "probeOut") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "gcprobe.out")))) (DoLet false false PWild (EApp (EApp (EVar "writeFile") (EVar "probe")) (ELit (LString "#include <gc.h>\nint main(void){return 0;}\n")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "cc")) (EListLit (EVar "probe") (ELit (LString "-lgc")) (ELit (LString "-o")) (EVar "probeOut"))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "Some") (ETuple (EListLit) (EListLit (ELit (LString "-lgc")))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "effectiveKeepIr" (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "effectiveKeepIr" ((PVar "cliFlag")) (EBinOp "||" (EVar "cliFlag") (EBinOp "!=" (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_KEEP_IR"))) (ELit (LString ""))) (ELit (LString "")))))
(DTypeSig false "keepIrNote" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "keepIrNote" ((PVar "path") (PVar "contents")) (EMatch (EApp (EApp (EVar "writeFile") (EVar "path")) (EVar "contents")) (arm (PCon "Ok" PWild) () (EBinOp "++" (ELit (LString "\nkept IR: ")) (EVar "path"))) (arm (PCon "Err" (PVar "e")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\nwarning: could not keep IR at ")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ": "))) (EVar "e")))))
(DTypeSig true "runBuild" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "BuildTarget") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult"))))))))))
(DFunDef false "runBuild" ((PVar "root") (PVar "medaka") (PVar "cc") (PCon "TNative") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNative") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "inputAbs")) (EVar "outPath")) (EVar "keepIrCli")))
(DFunDef false "runBuild" ((PVar "root") (PVar "medaka") (PVar "cc") (PCon "TWasm") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EApp (EApp (EApp (EApp (EApp (EVar "runBuildWasm") (EVar "root")) (EVar "medaka")) (EVar "inputAbs")) (EVar "outPath")) (EVar "keepIrCli")))
(DTypeSig false "runBuildNative" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult")))))))))
(DFunDef false "runBuildNative" ((PVar "root") (PVar "medaka") (PVar "cc") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not create a scratch directory for the build: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildNativeIn") (EVar "root")) (EVar "medaka")) (EVar "cc")) (EVar "inputAbs")) (EVar "outPath")) (EVar "tmpDir")) (EVar "keepIrCli"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "res"))))))
(DTypeSig false "runBuildNativeIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult"))))))))))
(DFunDef false "runBuildNativeIn" ((PVar "root") (PVar "medaka") (PVar "cc") (PVar "inputAbs") (PVar "outPath") (PVar "tmpDir") (PVar "keepIrCli")) (EBlock (DoLet false false (PVar "emitter") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler/entries/llvm_emit_modules_main.mdk")))) (DoLet false false (PVar "runtimeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/runtime.mdk")))) (DoLet false false (PVar "preludeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/core.mdk")))) (DoLet false false (PVar "rtC") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "runtime/medaka_rt.c")))) (DoLet false false (PVar "compilerDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler")))) (DoLet false false (PVar "stdlibDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib")))) (DoLet false false (PVar "inputRoots") (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "inputAbs")))) (DoLet false false (PVar "llPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "program.ll")))) (DoLet false false (PVar "emitArgsBase") (EBinOp "++" (EBinOp "++" (EListLit (EVar "runtimeP") (EVar "preludeP") (EVar "inputAbs")) (EVar "inputRoots")) (EListLit (EVar "compilerDir") (EVar "stdlibDir")))) (DoLet false false (PVar "emitter2") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_EMITTER"))) (EVar "defaultMedakaEmitter"))) (DoLet false false (PVar "useNative") (EBinOp "!=" (EVar "emitter2") (ELit (LString "")))) (DoLet false false (PVar "emitProg") (EIf (EVar "useNative") (EVar "emitter2") (EVar "medaka"))) (DoLet false false (PVar "emitArgs") (EIf (EVar "useNative") (EVar "emitArgsBase") (EBinOp "::" (ELit (LString "run")) (EBinOp "::" (EVar "emitter") (EVar "emitArgsBase"))))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "emitProg")) (EVar "emitArgs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run emitter (")) (EApp (EMethodRef "display") (EVar "emitProg"))) (ELit (LString "): "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "irRaw") (PVar "emitErr"))) () (EIf (EBinOp "!=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: emitter failed compiling ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "emitErr"))) (ELit (LString "")))) (EBlock (DoLet false false (PVar "ir") (EApp (EVar "stripTrailingUnit") (EVar "irRaw"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "ir")) (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: emitter produced empty IR for ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "emitErr"))) (ELit (LString "")))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "llPath")) (EVar "ir")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not write IR: ")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "clangLink") (EVar "cc")) (EVar "rtC")) (EVar "llPath")) (EVar "outPath")) (EVar "inputAbs")) (EVar "tmpDir"))) (DoLet false false (PVar "note") (EIf (EApp (EVar "effectiveKeepIr") (EVar "keepIrCli")) (EApp (EApp (EVar "keepIrNote") (EBinOp "++" (EVar "outPath") (ELit (LString ".ll")))) (EVar "ir")) (ELit (LString "")))) (DoExpr (EApp (EApp (EVar "appendNote") (EVar "note")) (EVar "res")))))))))))))))
(DTypeSig false "runBuildWasm" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult"))))))))
(DFunDef false "runBuildWasm" ((PVar "root") (PVar "medaka") (PVar "inputAbs") (PVar "outPath") (PVar "keepIrCli")) (EMatch (EApp (EVar "makeTempDir") (ELit LUnit)) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not create a scratch directory for the build: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "tmpDir")) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "runBuildWasmIn") (EVar "root")) (EVar "medaka")) (EVar "inputAbs")) (EVar "outPath")) (EVar "tmpDir")) (EVar "keepIrCli"))) (DoLet false false PWild (EApp (EVar "cleanupTempDir") (EVar "tmpDir"))) (DoExpr (EVar "res"))))))
(DTypeSig false "runBuildWasmIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "BuildResult")))))))))
(DFunDef false "runBuildWasmIn" ((PVar "root") (PVar "medaka") (PVar "inputAbs") (PVar "outPath") (PVar "tmpDir") (PVar "keepIrCli")) (EBlock (DoLet false false (PVar "runtimeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/runtime.mdk")))) (DoLet false false (PVar "preludeP") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib/core.mdk")))) (DoLet false false (PVar "compilerDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "compiler")))) (DoLet false false (PVar "stdlibDir") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "stdlib")))) (DoLet false false (PVar "inputRoots") (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "inputAbs")))) (DoLet false false (PVar "watPath") (EApp (EApp (EVar "joinPath") (EVar "tmpDir")) (ELit (LString "program.wat")))) (DoLet false false (PVar "emitArgsBase") (EBinOp "++" (EBinOp "++" (EListLit (EVar "runtimeP") (EVar "preludeP") (EVar "inputAbs")) (EVar "inputRoots")) (EListLit (EVar "compilerDir") (EVar "stdlibDir")))) (DoLet false false (PVar "wasmEmitter") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_WASM_EMITTER"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "==" (EVar "wasmEmitter") (ELit (LString ""))) (EApp (EVar "BuildErr") (ELit (LString "error: --target wasm needs a compiled wasm emitter — set MEDAKA_WASM_EMITTER to its path\n  build one with: sh test/wasm/build_wasm_oracle.sh (produces test/bin/wasm_emit_modules_main)"))) (EIf (EUnOp "!" (EApp (EVar "fileExists") (EVar "wasmEmitter"))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (ELit (LString "error: MEDAKA_WASM_EMITTER points to a missing binary: ")) (EApp (EMethodRef "display") (EVar "wasmEmitter"))) (ELit (LString "\n  build it with: sh test/wasm/build_wasm_oracle.sh (produces test/bin/wasm_emit_modules_main)")))) (EMatch (EApp (EVar "probeWasmTools") (ELit LUnit)) (arm (PCon "None") () (EApp (EVar "BuildErr") (ELit (LString "error: wasm-tools not found on PATH — install wasm-tools (cargo install wasm-tools or brew install wasm-tools) for --target wasm")))) (arm (PCon "Some" PWild) () (EMatch (EApp (EApp (EVar "runCommand") (EVar "wasmEmitter")) (EVar "emitArgsBase")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run wasm emitter (")) (EApp (EMethodRef "display") (EVar "wasmEmitter"))) (ELit (LString "): "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "watRaw") (PVar "emitErr"))) () (EIf (EBinOp "!=" (EVar "code") (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm emitter failed compiling ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "emitErr"))) (ELit (LString "")))) (EBlock (DoLet false false (PVar "wat") (EApp (EVar "stripTrailingUnit") (EVar "watRaw"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "wat")) (ELit (LInt 0))) (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm emitter produced empty WAT for ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "emitErr"))) (ELit (LString "")))) (EMatch (EApp (EApp (EVar "writeFile") (EVar "watPath")) (EVar "wat")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not write WAT: ")) (EVar "e")))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "res") (EApp (EApp (EApp (EVar "wasmAssemble") (EVar "watPath")) (EVar "outPath")) (EVar "inputAbs"))) (DoLet false false (PVar "note") (EIf (EApp (EVar "effectiveKeepIr") (EVar "keepIrCli")) (EApp (EApp (EVar "keepIrNote") (EBinOp "++" (EVar "outPath") (ELit (LString ".wat")))) (EVar "wat")) (ELit (LString "")))) (DoExpr (EApp (EApp (EVar "appendNote") (EVar "note")) (EVar "res")))))))))))))))))))
(DTypeSig false "probeWasmTools" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "Unit")))))
(DFunDef false "probeWasmTools" (PWild) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "wasm-tools"))) (EListLit (ELit (LString "--version")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "Some") (ELit LUnit))) (arm PWild () (EVar "None"))))
(DTypeSig false "wasmAssemble" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "BuildResult"))))))
(DFunDef false "wasmAssemble" ((PVar "watPath") (PVar "outPath") (PVar "inputAbs")) (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "wasm-tools"))) (EListLit (ELit (LString "parse")) (EVar "watPath") (ELit (LString "-o")) (EVar "outPath"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not run wasm-tools parse: ")) (EVar "e")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EMatch (EApp (EApp (EVar "runCommand") (ELit (LString "wasm-tools"))) (EListLit (ELit (LString "validate")) (ELit (LString "--features=all")) (EVar "outPath"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (ELit (LString "error: could not run wasm-tools validate: ")) (EVar "e")))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "BuildOk") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "built ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString " -> "))) (EApp (EMethodRef "display") (EVar "outPath"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "valErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm-tools validate rejected ")) (EApp (EMethodRef "display") (EVar "outPath"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "valErr"))) (ELit (LString ""))))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "parseErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: wasm-tools parse failed assembling ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "parseErr"))) (ELit (LString "")))))))
(DTypeSig false "clangLink" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "BuildResult")))))))))
(DFunDef false "clangLink" ((PVar "cc") (PVar "rtC") (PVar "llPath") (PVar "outPath") (PVar "inputAbs") (PVar "tmpDir")) (EMatch (EApp (EApp (EVar "detectGC") (EVar "cc")) (EVar "tmpDir")) (arm (PCon "None") () (EApp (EVar "BuildErr") (ELit (LString "error: libgc (bdw-gc) not found — install bdw-gc (brew install bdw-gc) or set GC_PREFIX/pkg-config")))) (arm (PCon "Some" (PTuple (PVar "gcCflags") (PVar "gcLibs"))) () (EBlock (DoLet false false (PVar "optFlagRaw") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_CLANG_OPT"))) (ELit (LString "-O2")))) (DoLet false false (PVar "optFlag") (EIf (EBinOp "==" (EVar "optFlagRaw") (ELit (LString ""))) (ELit (LString "-O2")) (EVar "optFlagRaw"))) (DoLet false false (PVar "clangArgs") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (EVar "optFlag") (ELit (LString "-pthread"))) (EVar "gcCflags")) (EListLit (EVar "llPath") (EVar "rtC"))) (EVar "gcLibs")) (EListLit (ELit (LString "-lm")) (ELit (LString "-o")) (EVar "outPath")))) (DoExpr (EMatch (EApp (EApp (EVar "runCommand") (EVar "cc")) (EVar "clangArgs")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: could not run clang (")) (EApp (EMethodRef "display") (EVar "cc"))) (ELit (LString "): "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple (PLit (LInt 0)) PWild PWild)) () (EApp (EVar "BuildOk") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "built ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString " -> "))) (EApp (EMethodRef "display") (EVar "outPath"))) (ELit (LString ""))))) (arm (PCon "Ok" (PTuple PWild PWild (PVar "ccErr"))) () (EApp (EVar "BuildErr") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "error: clang failed linking ")) (EApp (EMethodRef "display") (EVar "inputAbs"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "ccErr"))) (ELit (LString "")))))))))))
