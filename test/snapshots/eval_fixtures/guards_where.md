# META
source_lines=12
stages=CORE_IR
# SOURCE
-- function guards + where-clause local bindings
classify n
  | n < 0 = "neg"
  | n == 0 = "zero"
  | otherwise = "pos"
hypotSq a b = sq a + sq b
  where
    sq x = x * x
fib n
  | n < 2 = n
  | otherwise = fib (n - 1) + fib (n - 2)
main = (classify (0 - 5), classify 0, classify 9, hypotSq 3 4, fib 10)
# CORE_IR
(CProgram ((CBind "classify" (CClause ((PVar "n")) (CIf (CBinPrim "<" (CVar "n" (ALocal 0 0)) (CLit (LInt 0))) (CLit (LString "neg")) (CIf (CBinPrim "==" (CVar "n" (ALocal 0 0)) (CLit (LInt 0))) (CLit (LString "zero")) (CIf (CVar "otherwise" AGlobal) (CLit (LString "pos")) (CApp (CVar "__fallthrough__" AGlobal) (CLit LUnit))))))) (CBind "hypotSq" (CClause ((PVar "a") (PVar "b")) (CLetGroup ((CBind "sq" (CClause ((PVar "x")) (CBinPrim "*" (CVar "x" (ALocal 0 0)) (CVar "x" (ALocal 0 0)))))) (CBinPrim "+" (CApp (CVar "sq" (ALocal 0 0)) (CVar "a" (ALocal 2 0))) (CApp (CVar "sq" (ALocal 0 0)) (CVar "b" (ALocal 1 0))))))) (CBind "fib" (CClause ((PVar "n")) (CIf (CBinPrim "<" (CVar "n" (ALocal 0 0)) (CLit (LInt 2))) (CVar "n" (ALocal 0 0)) (CIf (CVar "otherwise" AGlobal) (CBinPrim "+" (CApp (CVar "fib" AGlobal) (CBinPrim "-" (CVar "n" (ALocal 0 0)) (CLit (LInt 1)))) (CApp (CVar "fib" AGlobal) (CBinPrim "-" (CVar "n" (ALocal 0 0)) (CLit (LInt 2))))) (CApp (CVar "__fallthrough__" AGlobal) (CLit LUnit)))))) (CBind "main" (CClause () (CTuple (CApp (CVar "classify" AGlobal) (CBinPrim "-" (CLit (LInt 0)) (CLit (LInt 5)))) (CApp (CVar "classify" AGlobal) (CLit (LInt 0))) (CApp (CVar "classify" AGlobal) (CLit (LInt 9))) (CApp (CApp (CVar "hypotSq" AGlobal) (CLit (LInt 3))) (CLit (LInt 4))) (CApp (CVar "fib" AGlobal) (CLit (LInt 10))))))) () () ())
