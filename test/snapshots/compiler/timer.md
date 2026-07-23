# META
source_lines=116
stages=DESUGAR,MARK
# SOURCE
-- Per-stage wall-clock timing helpers for the self-hosted pipeline.
-- Guarded by the MEDAKA_PERF environment variable: when unset, emitPhase and
-- emitTotal are no-ops, so drivers that import this module produce byte-identical
-- stdout to their un-instrumented counterparts.
--
-- Typical usage in a perf driver:
--   let on  = perfEnabled ()
--   let t0  = now ()
--   let res = ...stage work...
--   let t1  = now ()
--   let _   = emitPhase on "stage" (t1 - t0) "N decls"
--   ...
--   let _   = emitTotal on (tEnd - tStart)
--
-- All timing output goes to stderr so stdout is not disturbed.

-- True when MEDAKA_PERF is set to any value in the environment.
export perfEnabled : Unit -> <IO> Bool
perfEnabled () = match getEnv "MEDAKA_PERF"
  Some _ => True
  None => False

-- True when MEDAKA_PERF_WASM is set to any value in the environment.
--
-- SEPARATE from perfEnabled, and it gates WORK rather than OUTPUT — that is the
-- whole point. Every other stage is gated only on printing (`emitPhaseA on ...`),
-- because every other stage is cheap enough to always run. `wasm-emit` is not: it
-- is ~10x llvm_emit and, sampled at the `xref` shape's resolve-driven N=16000, it
-- cost the `gates (types)` shard ~277 s per run and made it the CI critical path
-- at 12 min against engines' 3.7 min.
--
-- ⚠️ A CALLER MUST BRANCH ON THIS, NOT PASS IT TO emitPhaseA. Medaka is strict, so
-- `emitPhaseA (perfWasmEnabled ()) "wasm-emit" ... (wasmText cprog)` still RUNS the
-- emission and saves nothing — it only hides the line. See profile_main.mdk.
--
-- ⚠️ EMPTY IS OFF — a DELIBERATE divergence from perfEnabled's "set to any value",
-- and it is not a style quibble. `getEnv` is C `getenv`: a var set to the EMPTY string
-- is SET, so `MEDAKA_PERF_WASM=` reads `Some ""` and the "any value" rule turns it ON.
-- MEASURED, on the obvious shell spelling of the off-switch:
--   MEDAKA_PERF_WASM="" ... profile_main   =>  wasm-emit RAN
-- Under "any value" this stage is on whenever a caller writes the natural
-- `MEDAKA_PERF_WASM="$flag"` with an unset flag — i.e. the off-switch silently fails
-- OPEN, the ~277 s saving evaporates, and the only symptom is a slow shard. An
-- off-switch whose failure mode is "still on, silently" is not an off-switch.
export perfWasmEnabled : Unit -> <IO> Bool
perfWasmEnabled () = match getEnv "MEDAKA_PERF_WASM"
  Some "" => False
  Some _ => True
  None => False

-- Current wall-clock time in seconds (gettimeofday).
export now : Unit -> <IO> Float
now () = wallTimeSec ()

-- Emit one timed phase to stderr.  Label, elapsed time (seconds), and an ops
-- string (free-form: "N decls", "runtime+core", etc).  No-op when on = False.
-- Format: [perf] <label>\t<elapsed>s\t<ops>
export emitPhase : Bool -> String -> Float -> String -> <IO> Unit
emitPhase False _ _ _ = ()
emitPhase True label elapsed ops =
  ePutStrLn "[perf] \{label}\t\{floatToString elapsed}s\t\{ops}"

-- Emit the total pipeline time to stderr.  No-op when on = False.
export emitTotal : Bool -> Float -> <IO> Unit
emitTotal False _ = ()
emitTotal True elapsed =
  ePutStrLn ("[perf] total\t" ++ floatToString elapsed ++ "s")

-- Count total declarations across a list of (moduleId, decls) pairs.
-- Used by drivers as a cheap proxy for "work units" without modifying stages.
export totalDecls : List (String, List a) -> Int
totalDecls [] = 0
totalDecls ((_, ds)::rest) = countList ds + totalDecls rest

countList : List a -> Int
countList [] = 0
countList (_::xs) = 1 + countList xs

-- GC-backed allocation snapshot: total bytes allocated since process start.
-- Use paired snapshots to measure per-stage byte allocations.
-- Backed by Gc.allocated_bytes (monotonically increasing float).
export allocSnap : Unit -> <IO> Float
allocSnap () = allocBytes ()

-- Extended phase emit that includes an allocation-delta column (bytes → MB).
-- Format: [perf] <label>\t<elapsed>s\t<allocMB>MB\t<ops>
export emitPhaseA : Bool -> String -> Float -> Float -> String -> <IO> Unit
emitPhaseA False _ _ _ _ = ()
emitPhaseA True label elapsed allocDelta ops =
  ePutStrLn
    "[perf] \{label}\t\{floatToString elapsed}s\t\{floatToString (allocDelta / 1048576.0)}MB\t\{ops}"

-- Extended total emit with allocation (four-field format to match emitPhaseA).
export emitTotalA : Bool -> Float -> Float -> <IO> Unit
emitTotalA False _ _ = ()
emitTotalA True elapsed allocTotal =
  ePutStrLn
    "[perf] total\t\{floatToString elapsed}s\t\{floatToString (allocTotal / 1048576.0)}MB\t"

-- Extended phase emit that ALSO appends the deterministic per-stage OP-COUNT delta
-- (issue #884) as a trailing TAB-delimited 5th column. Format:
--   [perf] <label>\t<elapsed>s\t<allocMB>MB\t<ops>\t<opDelta>
--
-- ⚠️ The op-delta MUST be its own tab-delimited field. The existing `<ops>` field is
-- FREE-FORM and contains spaces ("N decls", "runtime+core"), so the perf gate's
-- op-arm parses this with `awk -F'\t'` and reads field 5. A whitespace split would
-- land inside `<ops>` and read garbage — see diff_compiler_perf_scaling.sh:stage_ops.
--
-- No existing consumer breaks: the gate's TIME/ALLOC arms and profile_compiler.sh
-- read whitespace-split fields 2/3/4, none of which move when a 5th tab-field is
-- appended. `opDelta` is a snapshot-subtract of opcount.opSnap across the stage.
export emitPhaseAO : Bool -> String -> Float -> Float -> String -> Int -> <IO> Unit
emitPhaseAO False _ _ _ _ _ = ()
emitPhaseAO True label elapsed allocDelta ops opDelta =
  ePutStrLn
    "[perf] \{label}\t\{floatToString elapsed}s\t\{floatToString (allocDelta / 1048576.0)}MB\t\{ops}\t\{intToString opDelta}"
# DESUGAR
(DTypeSig true "perfEnabled" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "perfEnabled" ((PLit LUnit)) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_PERF"))) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "perfWasmEnabled" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "perfWasmEnabled" ((PLit LUnit)) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_PERF_WASM"))) (arm (PCon "Some" (PLit (LString ""))) () (EVar "False")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "now" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Float"))))
(DFunDef false "now" ((PLit LUnit)) (EApp (EVar "wallTimeSec") (ELit LUnit)))
(DTypeSig true "emitPhase" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "emitPhase" ((PCon "False") PWild PWild PWild) (ELit LUnit))
(DFunDef false "emitPhase" ((PCon "True") (PVar "label") (PVar "elapsed") (PVar "ops")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "\t"))) (EApp (EVar "display") (EApp (EVar "floatToString") (EVar "elapsed")))) (ELit (LString "s\t"))) (EApp (EVar "display") (EVar "ops"))) (ELit (LString "")))))
(DTypeSig true "emitTotal" (TyFun (TyCon "Bool") (TyFun (TyCon "Float") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitTotal" ((PCon "False") PWild) (ELit LUnit))
(DFunDef false "emitTotal" ((PCon "True") (PVar "elapsed")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] total\t")) (EApp (EVar "floatToString") (EVar "elapsed"))) (ELit (LString "s")))))
(DTypeSig true "totalDecls" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyVar "a")))) (TyCon "Int")))
(DFunDef false "totalDecls" ((PList)) (ELit (LInt 0)))
(DFunDef false "totalDecls" ((PCons (PTuple PWild (PVar "ds")) (PVar "rest"))) (EBinOp "+" (EApp (EVar "countList") (EVar "ds")) (EApp (EVar "totalDecls") (EVar "rest"))))
(DTypeSig false "countList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))
(DFunDef false "countList" ((PList)) (ELit (LInt 0)))
(DFunDef false "countList" ((PCons PWild (PVar "xs"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "countList") (EVar "xs"))))
(DTypeSig true "allocSnap" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Float"))))
(DFunDef false "allocSnap" ((PLit LUnit)) (EApp (EVar "allocBytes") (ELit LUnit)))
(DTypeSig true "emitPhaseA" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "emitPhaseA" ((PCon "False") PWild PWild PWild PWild) (ELit LUnit))
(DFunDef false "emitPhaseA" ((PCon "True") (PVar "label") (PVar "elapsed") (PVar "allocDelta") (PVar "ops")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "\t"))) (EApp (EVar "display") (EApp (EVar "floatToString") (EVar "elapsed")))) (ELit (LString "s\t"))) (EApp (EVar "display") (EApp (EVar "floatToString") (EBinOp "/" (EVar "allocDelta") (ELit (LFloat 1048576.0)))))) (ELit (LString "MB\t"))) (EApp (EVar "display") (EVar "ops"))) (ELit (LString "")))))
(DTypeSig true "emitTotalA" (TyFun (TyCon "Bool") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitTotalA" ((PCon "False") PWild PWild) (ELit LUnit))
(DFunDef false "emitTotalA" ((PCon "True") (PVar "elapsed") (PVar "allocTotal")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] total\t")) (EApp (EVar "display") (EApp (EVar "floatToString") (EVar "elapsed")))) (ELit (LString "s\t"))) (EApp (EVar "display") (EApp (EVar "floatToString") (EBinOp "/" (EVar "allocTotal") (ELit (LFloat 1048576.0)))))) (ELit (LString "MB\t")))))
(DTypeSig true "emitPhaseAO" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "emitPhaseAO" ((PCon "False") PWild PWild PWild PWild PWild) (ELit LUnit))
(DFunDef false "emitPhaseAO" ((PCon "True") (PVar "label") (PVar "elapsed") (PVar "allocDelta") (PVar "ops") (PVar "opDelta")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "\t"))) (EApp (EVar "display") (EApp (EVar "floatToString") (EVar "elapsed")))) (ELit (LString "s\t"))) (EApp (EVar "display") (EApp (EVar "floatToString") (EBinOp "/" (EVar "allocDelta") (ELit (LFloat 1048576.0)))))) (ELit (LString "MB\t"))) (EApp (EVar "display") (EVar "ops"))) (ELit (LString "\t"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "opDelta")))) (ELit (LString "")))))
# MARK
(DTypeSig true "perfEnabled" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "perfEnabled" ((PLit LUnit)) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_PERF"))) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "perfWasmEnabled" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "perfWasmEnabled" ((PLit LUnit)) (EMatch (EApp (EVar "getEnv") (ELit (LString "MEDAKA_PERF_WASM"))) (arm (PCon "Some" (PLit (LString ""))) () (EVar "False")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "now" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Float"))))
(DFunDef false "now" ((PLit LUnit)) (EApp (EVar "wallTimeSec") (ELit LUnit)))
(DTypeSig true "emitPhase" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "emitPhase" ((PCon "False") PWild PWild PWild) (ELit LUnit))
(DFunDef false "emitPhase" ((PCon "True") (PVar "label") (PVar "elapsed") (PVar "ops")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EApp (EVar "floatToString") (EVar "elapsed")))) (ELit (LString "s\t"))) (EApp (EMethodRef "display") (EVar "ops"))) (ELit (LString "")))))
(DTypeSig true "emitTotal" (TyFun (TyCon "Bool") (TyFun (TyCon "Float") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitTotal" ((PCon "False") PWild) (ELit LUnit))
(DFunDef false "emitTotal" ((PCon "True") (PVar "elapsed")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] total\t")) (EApp (EVar "floatToString") (EVar "elapsed"))) (ELit (LString "s")))))
(DTypeSig true "totalDecls" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyVar "a")))) (TyCon "Int")))
(DFunDef false "totalDecls" ((PList)) (ELit (LInt 0)))
(DFunDef false "totalDecls" ((PCons (PTuple PWild (PVar "ds")) (PVar "rest"))) (EBinOp "+" (EApp (EVar "countList") (EVar "ds")) (EApp (EVar "totalDecls") (EVar "rest"))))
(DTypeSig false "countList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))
(DFunDef false "countList" ((PList)) (ELit (LInt 0)))
(DFunDef false "countList" ((PCons PWild (PVar "xs"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "countList") (EVar "xs"))))
(DTypeSig true "allocSnap" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "Float"))))
(DFunDef false "allocSnap" ((PLit LUnit)) (EApp (EVar "allocBytes") (ELit LUnit)))
(DTypeSig true "emitPhaseA" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "emitPhaseA" ((PCon "False") PWild PWild PWild PWild) (ELit LUnit))
(DFunDef false "emitPhaseA" ((PCon "True") (PVar "label") (PVar "elapsed") (PVar "allocDelta") (PVar "ops")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EApp (EVar "floatToString") (EVar "elapsed")))) (ELit (LString "s\t"))) (EApp (EMethodRef "display") (EApp (EVar "floatToString") (EBinOp "/" (EVar "allocDelta") (ELit (LFloat 1048576.0)))))) (ELit (LString "MB\t"))) (EApp (EMethodRef "display") (EVar "ops"))) (ELit (LString "")))))
(DTypeSig true "emitTotalA" (TyFun (TyCon "Bool") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitTotalA" ((PCon "False") PWild PWild) (ELit LUnit))
(DFunDef false "emitTotalA" ((PCon "True") (PVar "elapsed") (PVar "allocTotal")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] total\t")) (EApp (EMethodRef "display") (EApp (EVar "floatToString") (EVar "elapsed")))) (ELit (LString "s\t"))) (EApp (EMethodRef "display") (EApp (EVar "floatToString") (EBinOp "/" (EVar "allocTotal") (ELit (LFloat 1048576.0)))))) (ELit (LString "MB\t")))))
(DTypeSig true "emitPhaseAO" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Float") (TyFun (TyCon "Float") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "emitPhaseAO" ((PCon "False") PWild PWild PWild PWild PWild) (ELit LUnit))
(DFunDef false "emitPhaseAO" ((PCon "True") (PVar "label") (PVar "elapsed") (PVar "allocDelta") (PVar "ops") (PVar "opDelta")) (EApp (EVar "ePutStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[perf] ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EApp (EVar "floatToString") (EVar "elapsed")))) (ELit (LString "s\t"))) (EApp (EMethodRef "display") (EApp (EVar "floatToString") (EBinOp "/" (EVar "allocDelta") (ELit (LFloat 1048576.0)))))) (ELit (LString "MB\t"))) (EApp (EMethodRef "display") (EVar "ops"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "opDelta")))) (ELit (LString "")))))
