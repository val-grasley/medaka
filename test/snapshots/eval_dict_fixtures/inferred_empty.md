# META
source_lines=12
stages=EVAL
# SOURCE
-- INFERRED (unsignatured) constraint: `doubleEmpty` has NO `: Monoid a =>`
-- signature, but its body uses the return-position method `empty` at its
-- parameter's tyvar — so after inference that tyvar is constrained.  Plain
-- arg-tag dispatch cannot resolve `empty` (no discriminating argument), so the
-- function must be PROMOTED: marked EDictAt, given a leading dict parameter, and
-- the in-body `empty` routed to it (RDict).  The reference's two-pass Elaborate
-- discovers the constraint after the first typecheck and re-marks; the
-- self-hosted elaborateDict does the same (discoverPromoted).  Called at a
-- concrete type (String) so the caller supplies the String Monoid dict.
doubleEmpty x = append (append x empty) empty

main = putStrLn (doubleEmpty "ab")
# EVAL
ab
