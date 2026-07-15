# META
source_lines=13
stages=POSITIONS
# SOURCE
data Tree a
  = Leaf
  | Node { left : Tree a, value : a, right : Tree a }

data Cmd
  = Move Int Int
  | Draw (List Int)
  | Stop

insert v t =
  match t
    Leaf => Node { left = Leaf, value = v, right = Leaf }
    Node r => r.value
# POSITIONS
=== DECLS ===
1:3
5:8
10:13
=== VARIANTS ===
2
3
6
7
8
=== LASTLINE ===
13
