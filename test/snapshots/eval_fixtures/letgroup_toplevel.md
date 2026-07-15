# META
source_lines=10
stages=CORE_IR
# SOURCE
-- Top-level DLetGroup (`let rec …`) coverage, each mutual-recursion pair
-- expressed as two separate top-level `let rec` bindings.
-- Uses both unconstrained mutual recursion and constrained (== and -) mutual recursion.
let rec ping n = if n then "ping" else pong n
let rec pong n = if n then pong n else "pong"

let rec isEven n = if n == 0 then True else isOdd (n - 1)
let rec isOdd n = if n == 0 then False else isEven (n - 1)

main = (ping False, isEven 4, isOdd 3)
# CORE_IR
(CProgram ((CBind "ping" (CClause ((PVar "n")) (CIf (CVar "n" (ALocal 0 0)) (CLit (LString "ping")) (CApp (CVar "pong" AGlobal) (CVar "n" (ALocal 0 0)))))) (CBind "pong" (CClause ((PVar "n")) (CIf (CVar "n" (ALocal 0 0)) (CApp (CVar "pong" (ALocal 1 0)) (CVar "n" (ALocal 0 0))) (CLit (LString "pong"))))) (CBind "isEven" (CClause ((PVar "n")) (CIf (CBinPrim "==" (CVar "n" (ALocal 0 0)) (CLit (LInt 0))) (CVar "True" AGlobal) (CApp (CVar "isOdd" AGlobal) (CBinPrim "-" (CVar "n" (ALocal 0 0)) (CLit (LInt 1))))))) (CBind "isOdd" (CClause ((PVar "n")) (CIf (CBinPrim "==" (CVar "n" (ALocal 0 0)) (CLit (LInt 0))) (CVar "False" AGlobal) (CApp (CVar "isEven" AGlobal) (CBinPrim "-" (CVar "n" (ALocal 0 0)) (CLit (LInt 1))))))) (CBind "main" (CClause () (CTuple (CApp (CVar "ping" AGlobal) (CVar "False" AGlobal)) (CApp (CVar "isEven" AGlobal) (CLit (LInt 4))) (CApp (CVar "isOdd" AGlobal) (CLit (LInt 3))))))) () () ())
