# META
source_lines=16
stages=CORE_IR
# SOURCE
-- Inferred-constraint recursion: a recursive function WITHOUT an explicit type
-- signature whose recursion uses a constrained operation (== needs Eq, -/+ need
-- Num) must forward the INFERRED constraint's dict into the self/mutual recursive
-- call.  Before the fix, the recursive callee was under-applied (its EDictAt route
-- stayed empty while dict_pass still prepended the dict param) → dispatch failed.
--   countDown      : self-recursion, inferred Eq + Num
--   isEven / isOdd : mutual recursion, inferred Eq + Num (shared SCC)
--   sumTo          : self-recursion threading an accumulating Num result
countDown n = if n == 0 then 0 else countDown (n - 1)

isEven n = if n == 0 then True else isOdd (n - 1)
isOdd n = if n == 0 then False else isEven (n - 1)

sumTo n = if n == 0 then 0 else n + sumTo (n - 1)

main = (countDown 5, isEven 4, isOdd 4, sumTo 5)
# CORE_IR
(CProgram ((CBind "countDown" (CClause ((PVar "n")) (CIf (CBinPrim "==" (CVar "n" (ALocal 0 0)) (CLit (LInt 0))) (CLit (LInt 0)) (CApp (CVar "countDown" AGlobal) (CBinPrim "-" (CVar "n" (ALocal 0 0)) (CLit (LInt 1))))))) (CBind "isEven" (CClause ((PVar "n")) (CIf (CBinPrim "==" (CVar "n" (ALocal 0 0)) (CLit (LInt 0))) (CVar "True" AGlobal) (CApp (CVar "isOdd" AGlobal) (CBinPrim "-" (CVar "n" (ALocal 0 0)) (CLit (LInt 1))))))) (CBind "isOdd" (CClause ((PVar "n")) (CIf (CBinPrim "==" (CVar "n" (ALocal 0 0)) (CLit (LInt 0))) (CVar "False" AGlobal) (CApp (CVar "isEven" AGlobal) (CBinPrim "-" (CVar "n" (ALocal 0 0)) (CLit (LInt 1))))))) (CBind "sumTo" (CClause ((PVar "n")) (CIf (CBinPrim "==" (CVar "n" (ALocal 0 0)) (CLit (LInt 0))) (CLit (LInt 0)) (CBinPrim "+" (CVar "n" (ALocal 0 0)) (CApp (CVar "sumTo" AGlobal) (CBinPrim "-" (CVar "n" (ALocal 0 0)) (CLit (LInt 1)))))))) (CBind "main" (CClause () (CTuple (CApp (CVar "countDown" AGlobal) (CLit (LInt 5))) (CApp (CVar "isEven" AGlobal) (CLit (LInt 4))) (CApp (CVar "isOdd" AGlobal) (CLit (LInt 4))) (CApp (CVar "sumTo" AGlobal) (CLit (LInt 5))))))) () () ())
