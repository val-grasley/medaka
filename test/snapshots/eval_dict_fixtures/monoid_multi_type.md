# META
source_lines=7
stages=EVAL
# SOURCE
-- The same constrained function called at TWO concrete types — each call site
-- supplies a different Monoid dictionary (String vs List), so the in-body `empty`
-- resolves per-call to the right impl.
doubleEmpty : Monoid a => a -> a
doubleEmpty x = append (append x empty) empty

main = putStrLn (doubleEmpty "ab" ++ " / " ++ debug (doubleEmpty (append [1, 2] [3])))
# EVAL
ab / [1, 2, 3]
