# META
source_lines=18
stages=TYPES
# SOURCE
-- ADT constructors + pattern matching + recursion
data Opt a = Non | Som a
data Pair a b = MkPair a b
data Tree a = Leaf a | Node (Tree a) (Tree a)
wrap x = Som x
fromOpt d o = match o
  Som x => x
  Non => d
mapOpt f o = match o
  Som x => Som (f x)
  Non => Non
swap (MkPair a b) = MkPair b a
applyPair p = match p
  MkPair f x => f x
single x = Leaf x
mirror t = match t
  Leaf x => Leaf x
  Node l r => Node (mirror r) (mirror l)
# TYPES
wrap : a -> Opt a
fromOpt : a -> Opt a -> a
mapOpt : (a -> b) -> Opt a -> Opt b
swap : Pair a b -> Pair b a
applyPair : Pair (a -> b) a -> b
single : a -> Tree a
mirror : Tree a -> Tree a
