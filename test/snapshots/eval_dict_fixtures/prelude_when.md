# META
source_lines=10
stages=EVAL
# SOURCE
-- A PRELUDE `=>`-constrained function driven at a constraint variable's type.
-- `when : Thenable m => Bool -> m Unit -> m Unit` returns `pure ()` in its False
-- branch — a return-position method at the constraint var `m`, whose result type
-- `m Unit` is HIGHER-KINDED (the dict var sits in the TApp head, not at top
-- level).  The unit argument doesn't discriminate Option from List, so arg-tag
-- dispatch picks the first `pure` impl (List) for both — wrong for Option.  With
-- the prelude's own constrained fns now dict-passed, each call site supplies the
-- right Applicative dict and the in-body `pure` routes to it.  Two concrete types
-- (Option, List) confirm per-call dispatch; the True branch returns the argument.
main = putStrLn (debug (when False (Some ())) ++ " / " ++ debug (when False [()]) ++ " / " ++ debug (when True (Some ())))
# EVAL
Some () / [()] / Some ()
