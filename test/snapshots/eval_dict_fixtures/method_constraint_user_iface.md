# META
source_lines=19
stages=EVAL
# SOURCE
-- Method-level-constraint dict-passing (Phase 69.x-e) on a USER interface: `crush`
-- mirrors `foldMap` — a method-level `Monoid m` over a result distinct from the
-- container `t`, with a default body that uses the return-position `empty` at type
-- `m`.  The `Tree` impl provides only the peer `crushFold`; `crush` runs through the
-- default, so the caller's `Monoid (List Int)` dict (RKey "List") is folded onto the
-- default body and `empty` resolves to `[]`.  Result is the in-order element pairs.
data Tree a = Leaf a | Branch (Tree a) (Tree a)

interface Crushable t where
  crushFold : (b -> a -> <e> b) -> b -> t a -> <e> b
  crush : Monoid m => (a -> <e> m) -> t a -> <e> m
  crush f t = crushFold (acc x => acc ++ f x) empty t

impl Crushable Tree where
  crushFold f acc (Leaf x) = f acc x
  crushFold f acc (Branch l r) = crushFold f (crushFold f acc l) r

dup x = [x, x]
main = println (crush dup (Branch (Leaf 1) (Branch (Leaf 2) (Leaf 3))))
# EVAL
[1, 1, 2, 2, 3, 3]
