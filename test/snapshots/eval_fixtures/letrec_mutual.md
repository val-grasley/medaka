# META
source_lines=14
stages=CORE_IR
# SOURCE
-- mutual recursion + let-group, multi-clause boolean dispatch
-- NB: isEven/isOdd are O(n) (unary decrement), and the SELF-HOSTED eval runs
-- them under double-interpretation, so collatz arguments are kept to small
-- trajectories (6 peaks at 16, 7 at 52) — a big one like 27 (peaks at 9232)
-- makes the self-hosted run take ~75s while testing nothing extra.
isEven 0 = True
isEven n = isOdd (n - 1)
isOdd 0 = False
isOdd n = isEven (n - 1)
collatz n
  | n == 1 = 0
  | isEven n = 1 + collatz (n / 2)
  | otherwise = 1 + collatz (3 * n + 1)
main = (isEven 10, isOdd 7, collatz 6, collatz 7)
# CORE_IR
(CProgram ((CBind "isEven" (CClause ((PLit (LInt 0))) (CVar "True" AGlobal)) (CClause ((PVar "n")) (CApp (CVar "isOdd" AGlobal) (CBinPrim "-" (CVar "n" (ALocal 0 0)) (CLit (LInt 1)))))) (CBind "isOdd" (CClause ((PLit (LInt 0))) (CVar "False" AGlobal)) (CClause ((PVar "n")) (CApp (CVar "isEven" AGlobal) (CBinPrim "-" (CVar "n" (ALocal 0 0)) (CLit (LInt 1)))))) (CBind "collatz" (CClause ((PVar "n")) (CIf (CBinPrim "==" (CVar "n" (ALocal 0 0)) (CLit (LInt 1))) (CLit (LInt 0)) (CIf (CApp (CVar "isEven" AGlobal) (CVar "n" (ALocal 0 0))) (CBinPrim "+" (CLit (LInt 1)) (CApp (CVar "collatz" AGlobal) (CBinPrim "/" (CVar "n" (ALocal 0 0)) (CLit (LInt 2))))) (CIf (CVar "otherwise" AGlobal) (CBinPrim "+" (CLit (LInt 1)) (CApp (CVar "collatz" AGlobal) (CBinPrim "+" (CBinPrim "*" (CLit (LInt 3)) (CVar "n" (ALocal 0 0))) (CLit (LInt 1))))) (CApp (CVar "__fallthrough__" AGlobal) (CLit LUnit))))))) (CBind "main" (CClause () (CTuple (CApp (CVar "isEven" AGlobal) (CLit (LInt 10))) (CApp (CVar "isOdd" AGlobal) (CLit (LInt 7))) (CApp (CVar "collatz" AGlobal) (CLit (LInt 6))) (CApp (CVar "collatz" AGlobal) (CLit (LInt 7))))))) () () ())
