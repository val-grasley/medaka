# META
source_lines=8
stages=EVAL
# SOURCE
-- A `Monoid a =>` function whose body uses the return-position method `empty` at
-- the constraint variable's type.  `empty` has no discriminating argument, so
-- arg-tag dispatch cannot resolve it — the Monoid dictionary the caller supplies
-- must be threaded in (dict-passing).  Called here at a concrete type (String).
doubleEmpty : Monoid a => a -> a
doubleEmpty x = append (append x empty) empty

main = putStrLn (doubleEmpty "ab")
# EVAL
ab
