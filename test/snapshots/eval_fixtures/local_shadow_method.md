# META
source_lines=22
stages=CORE_IR
# SOURCE
-- A LOCAL binder whose name collides with a prelude interface method (`debug`)
-- must resolve to the local binding, NOT dispatch as the method.  The marker /
-- typecheck prepass is scope-blind by default; the scope-aware rp/an/dn guard in
-- rewriteArgScoped keeps a shadowed reference a plain EVar so inference resolves
-- the local.  Mirrors lib/typecheck.ml's `env.locals` skip of the method table.
-- Regression for the native `run`-vs-`build` divergence (run mis-dispatched
-- `debug` to `Debug Int` → `intToString: not an Int`).

debug x = x + 1

fromLet y =
  let debug = 99
  debug

fromLambda = (debug => debug + 1) 41

fromMatch y = match y
  debug => debug + 100

fromParam debug = debug * 2

main = (fromLet 0, fromLambda, fromMatch 5, fromParam 21)
# CORE_IR
(CProgram ((CBind "debug" (CClause ((PVar "x")) (CBinPrim "+" (CVar "x" (ALocal 0 0)) (CLit (LInt 1))))) (CBind "fromLet" (CClause ((PVar "y")) (CBlock (CSLet false (PVar "debug") (CLit (LInt 99))) (CSExpr (CVar "debug" (ALocal 0 0)))))) (CBind "fromLambda" (CClause () (CApp (CLam ((PVar "debug")) (CBinPrim "+" (CVar "debug" (ALocal 0 0)) (CLit (LInt 1)))) (CLit (LInt 41))))) (CBind "fromMatch" (CClause ((PVar "y")) (CDecision (CVar "y" (ALocal 0 0)) ((arm (PVar "debug") () (CBinPrim "+" (CVar "debug" (ALocal 0 0)) (CLit (LInt 100))))) (CTLeaf 0)))) (CBind "fromParam" (CClause ((PVar "debug")) (CBinPrim "*" (CVar "debug" (ALocal 0 0)) (CLit (LInt 2))))) (CBind "main" (CClause () (CTuple (CApp (CVar "fromLet" AGlobal) (CLit (LInt 0))) (CVar "fromLambda" AGlobal) (CApp (CVar "fromMatch" AGlobal) (CLit (LInt 5))) (CApp (CVar "fromParam" AGlobal) (CLit (LInt 21))))))) () () ())
