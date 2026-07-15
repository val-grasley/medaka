# META
source_lines=9
stages=EVAL
# SOURCE
-- Two constraints on one type variable → two leading dict parameters.  `==` is
-- arg-dispatched (Eq), `empty` is dict-dispatched (Monoid); the Monoid dict must
-- be threaded even though the Eq one is only used by an arg-position method.
pick : (Eq a, Monoid a) => a -> a -> a
pick x y = if x == y then empty else append x y

main =
  putStrLn (pick "a" "a")
  putStrLn (pick "a" "b")
# EVAL

ab
