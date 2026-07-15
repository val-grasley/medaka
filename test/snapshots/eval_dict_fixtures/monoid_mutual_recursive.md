# META
source_lines=16
stages=EVAL
# SOURCE
-- A MUTUALLY-RECURSIVE constrained pair.  `evenCat` and `oddCat` live in one
-- letrec group (their constraint variables unify into a single surviving id), and
-- each calls the OTHER at that shared variable's type.  Each must forward its OWN
-- dict parameter — `evenCat`'s body routes `oddCat xs` to `$dict_evenCat_0` and
-- `oddCat`'s body routes `evenCat xs` to `$dict_oddCat_0`, since that is the dict
-- in scope — rather than the sibling's (which the shared id would otherwise pick).
-- Both also use the return-position `empty` in their base case.
evenCat : Monoid a => List a -> a
evenCat [] = empty
evenCat (x :: xs) = append x (oddCat xs)

oddCat : Monoid a => List a -> a
oddCat [] = empty
oddCat (x :: xs) = append x (evenCat xs)

main = putStrLn (evenCat ["a", "b", "c"] ++ "|" ++ oddCat ["x", "y"])
# EVAL
abc|xy
