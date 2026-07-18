# META
source_lines=26
stages=CORE_IR
# SOURCE
-- codepoint string indexing, int + char range patterns.
-- Slice sugar `.[lo..hi]` moved OUT with #670 (now a prelude `Slice.slice` method the
-- prelude-free eval probe cannot dispatch); slice coverage: core.mdk doctests +
-- diff_compiler_slice_oob + diff_wasm_modules.
sub x y = x - y
classify n = match n
  0..9 => "low"
  10..99 => "mid"
  _ => "high"
kind c = match c
  'a'..'z' => "lower"
  'A'..'Z' => "upper"
  '0'..'9' => "digit"
  _ => "sym"
main =
  ( arrayGetUnsafe 0 (stringToChars "hello")
  , arrayGetUnsafe 1 (stringToChars "héllo")
  , classify 3
  , classify 42
  , classify 500
  , kind 'q'
  , kind 'K'
  , kind '7'
  , kind '!'
  , sub 100 (sub 20 5)
  )
# CORE_IR
(CProgram ((CBind "sub" (CClause ((PVar "x") (PVar "y")) (CBinPrim "-" (CVar "x" (ALocal 1 0)) (CVar "y" (ALocal 0 0))))) (CBind "classify" (CClause ((PVar "n")) (CDecision (CVar "n" (ALocal 0 0)) ((arm (PRng (LInt 0) (LInt 9) false) () (CLit (LString "low"))) (arm (PRng (LInt 10) (LInt 99) false) () (CLit (LString "mid"))) (arm PWild () (CLit (LString "high")))) (CTGuard 0 (CTGuard 1 (CTLeaf 2)))))) (CBind "kind" (CClause ((PVar "c")) (CDecision (CVar "c" (ALocal 0 0)) ((arm (PRng (LChar "a") (LChar "z") false) () (CLit (LString "lower"))) (arm (PRng (LChar "A") (LChar "Z") false) () (CLit (LString "upper"))) (arm (PRng (LChar "0") (LChar "9") false) () (CLit (LString "digit"))) (arm PWild () (CLit (LString "sym")))) (CTGuard 0 (CTGuard 1 (CTGuard 2 (CTLeaf 3))))))) (CBind "main" (CClause () (CTuple (CApp (CApp (CVar "arrayGetUnsafe" AGlobal) (CLit (LInt 0))) (CApp (CVar "stringToChars" AGlobal) (CLit (LString "hello")))) (CApp (CApp (CVar "arrayGetUnsafe" AGlobal) (CLit (LInt 1))) (CApp (CVar "stringToChars" AGlobal) (CLit (LString "héllo")))) (CApp (CVar "classify" AGlobal) (CLit (LInt 3))) (CApp (CVar "classify" AGlobal) (CLit (LInt 42))) (CApp (CVar "classify" AGlobal) (CLit (LInt 500))) (CApp (CVar "kind" AGlobal) (CLit (LChar "q"))) (CApp (CVar "kind" AGlobal) (CLit (LChar "K"))) (CApp (CVar "kind" AGlobal) (CLit (LChar "7"))) (CApp (CVar "kind" AGlobal) (CLit (LChar "!"))) (CApp (CApp (CVar "sub" AGlobal) (CLit (LInt 100))) (CApp (CApp (CVar "sub" AGlobal) (CLit (LInt 20))) (CLit (LInt 5)))))))) () () ())
