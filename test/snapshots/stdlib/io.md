# META
source_lines=71
stages=DESUGAR,MARK
# SOURCE
{- io.mdk — files, standard streams, environment, and process I/O.

   See STDLIB.md (Module 7) for the plan.

   The irreducible host primitives are `extern`s in stdlib/runtime.mdk, so they
   are **global** (no import needed): `readFile`/`writeFile`/`appendFile`,
   `readLine`/`readLineOpt`/`readAll`, `args`, `getEnv`, `fileExists`, `listDir`,
   `exit`, `putStr`/`putStrLn` (and the prelude's `print`/`println`), and the
   stderr pair `ePutStr`/`ePutStrLn`. This module adds the ergonomic layer on
   top — `Display`-based stderr output, line-oriented file reading, and an
   `Option`-smoothing environment helper.

   Conventions: file ops return `Result String _` with the host error message in
   `Err`; `getEnv` returns `Option`. There is no IO monad — an action runs when
   it is evaluated, so you can `match readFile path` directly. -}

import core.{Debug, Display, Option, Result, fromOption}

-- ── Standard error (Display, mirroring the prelude's print/println) ──────

{- | Write a value to stderr (no trailing newline), rendered via `Display` —
   the stderr analog of the prelude's `print`. -}
export eprint : Display a => a -> <IO> Unit
eprint x = ePutStr (display x)

{- | Write a value to stderr followed by a newline — the stderr analog of
   `println`. Use for diagnostics and errors so they don't pollute stdout. -}
export eprintln : Display a => a -> <IO> Unit
eprintln x = ePutStrLn (display x)

-- ── Debug output ─────────────────────────────────────────────────────────

{- | Print a value via `Debug` followed by a newline — the `Debug`-rendering
   analog of `println`.  Unlike `println` (which uses `Display` and is
   user-facing), `inspect` produces round-trippable output: strings and chars
   are quoted, ADTs print with constructor names and field values.  Handy for
   tracing intermediate values without a custom `Display` impl. -}
export inspect : Debug a => a -> <IO> Unit
inspect x = putStrLn (debug x)

-- ── Files ────────────────────────────────────────────────────────────────

{- Line splitting is done here over the global `string*` kernel externs (in
   runtime.mdk) rather than `import string.{lines}`.  string.mdk is importable
   as of Phase 117, but `string.lines` deliberately *keeps* the final empty line
   a trailing newline produces, whereas readLines drops it — so this stays a
   local helper.  Splits on `\n`, dropping a trailing `\r` (so CRLF files work)
   and the final empty line a trailing newline would otherwise produce. -}
export stripCR : String -> String
stripCR s =
  let n = stringLength s
  if n > 0 && stringSlice (n - 1) n s == "\r" then
    stringSlice 0 (n - 1) s
  else
    s

splitLines : String -> List String
splitLines s = match stringIndexOf "\n" s
  None => if s == "" then [] else [stripCR s]
  Some i => stripCR (stringSlice 0 i s) :: splitLines (stringSlice (i + 1) (stringLength s) s)

{- | Read a file and split it into lines, or `Err` with the host message on a
   read failure. The trailing newline does not produce a final empty line. -}
export readLines : String -> <IO> Result String (List String)
readLines path = map splitLines (readFile path)

-- ── Environment ──────────────────────────────────────────────────────────

{- | An environment variable's value, or `fallback` when it is unset. -}
export getEnvOr : String -> String -> <IO> String
getEnvOr name fallback = fromOption fallback (getEnv name)
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Debug" false) (mem "Display" false) (mem "Option" false) (mem "Result" false) (mem "fromOption" false))))
(DTypeSig true "eprint" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "eprint" ((PVar "x")) (EApp (EVar "ePutStr") (EApp (EVar "display") (EVar "x"))))
(DTypeSig true "eprintln" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "eprintln" ((PVar "x")) (EApp (EVar "ePutStrLn") (EApp (EVar "display") (EVar "x"))))
(DTypeSig true "inspect" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "inspect" ((PVar "x")) (EApp (EVar "putStrLn") (EApp (EVar "debug") (EVar "x"))))
(DTypeSig true "stripCR" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripCR" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "\r")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s")) (EVar "s")))))
(DTypeSig false "splitLines" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitLines" ((PVar "s")) (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "\n"))) (EVar "s")) (arm (PCon "None") () (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EListLit) (EListLit (EApp (EVar "stripCR") (EVar "s"))))) (arm (PCon "Some" (PVar "i")) () (EBinOp "::" (EApp (EVar "stripCR") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "s"))) (EApp (EVar "splitLines") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))))
(DTypeSig true "readLines" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "readLines" ((PVar "path")) (EApp (EApp (EVar "map") (EVar "splitLines")) (EApp (EVar "readFile") (EVar "path"))))
(DTypeSig true "getEnvOr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "getEnvOr" ((PVar "name") (PVar "fallback")) (EApp (EApp (EVar "fromOption") (EVar "fallback")) (EApp (EVar "getEnv") (EVar "name"))))
# MARK
(DUse false (UseGroup ("core") ((mem "Debug" false) (mem "Display" false) (mem "Option" false) (mem "Result" false) (mem "fromOption" false))))
(DTypeSig true "eprint" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "eprint" ((PVar "x")) (EApp (EVar "ePutStr") (EApp (EMethodRef "display") (EVar "x"))))
(DTypeSig true "eprintln" (TyConstrained ((cstr "Display" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "eprintln" ((PVar "x")) (EApp (EVar "ePutStrLn") (EApp (EMethodRef "display") (EVar "x"))))
(DTypeSig true "inspect" (TyConstrained ((cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "inspect" ((PVar "x")) (EApp (EVar "putStrLn") (EApp (EMethodRef "debug") (EVar "x"))))
(DTypeSig true "stripCR" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripCR" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString "\r")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "s")) (EVar "s")))))
(DTypeSig false "splitLines" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitLines" ((PVar "s")) (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "\n"))) (EVar "s")) (arm (PCon "None") () (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EListLit) (EListLit (EApp (EVar "stripCR") (EVar "s"))))) (arm (PCon "Some" (PVar "i")) () (EBinOp "::" (EApp (EVar "stripCR") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "s"))) (EApp (EVar "splitLines") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))))))
(DTypeSig true "readLines" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "readLines" ((PVar "path")) (EApp (EApp (EMethodRef "map") (EVar "splitLines")) (EApp (EVar "readFile") (EVar "path"))))
(DTypeSig true "getEnvOr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "getEnvOr" ((PVar "name") (PVar "fallback")) (EApp (EApp (EVar "fromOption") (EVar "fallback")) (EApp (EVar "getEnv") (EVar "name"))))
