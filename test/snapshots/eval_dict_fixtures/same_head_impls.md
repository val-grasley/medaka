# META
source_lines=30
stages=EVAL
# SOURCE
-- TYPECHECK-AUDIT C7: two NON-overlapping impls that share a head tycon (Pair).
-- `Pair Int Bool` and `Pair Bool Int` do not overlap (S3 coherence accepts both),
-- but both have head tycon `Pair`.  A return-position method `def` dispatched at
-- each concrete type must pick the RIGHT impl.  Head-tag-only routing (the C7 bug)
-- sends both to `Pair` → first-impl-wins → one type gets the wrong value.  The
-- canonical-impl-key route + key-match narrowing picks each correctly == oracle.
data Pair a b = Pr a b

interface Def a where
  def : a

impl Def (Pair Int Bool) where
  def = Pr 1 True

impl Def (Pair Bool Int) where
  def = Pr False 2

ib : Pair Int Bool
ib = def

bi : Pair Bool Int
bi = def

main = putStrLn (showIB ib ++ " / " ++ showBI bi)

showIB : Pair Int Bool -> String
showIB (Pr a b) = intToString a ++ "," ++ debug b

showBI : Pair Bool Int -> String
showBI (Pr a b) = debug a ++ "," ++ intToString b
# EVAL
1,True / False,2
