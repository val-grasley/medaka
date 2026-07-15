# META
source_lines=12
stages=EVAL
# SOURCE
-- A USER `=>`-constrained function FORWARDS its own dict into a PRELUDE
-- constrained function.  `twice` is `Thenable m =>` and calls `when` at its OWN
-- constraint var `m` (not a concrete type), so the call site can't key an RKey —
-- it must forward the dict `twice` itself received (RDict `$dict_twice_0`).  Inside
-- `when`, `pure ()` then routes to `when`'s dict param, which was the forwarded
-- one.  `main` pins the concrete type at the top of the chain (Option, then List),
-- supplying the original dict.  Exercises prelude dict-passing composed with the
-- user slice's forwarding, across two types.
twice : Thenable m => m Unit -> m Unit
twice x = when False x

main = putStrLn (debug (twice (Some ())) ++ " / " ++ debug (twice [()]))
# EVAL
Some () / [()]
