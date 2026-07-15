# META
source_lines=11
stages=EVAL
# SOURCE
data Color = Red | Green | Blue deriving (Eq, Ord)

data T = A Int | B Int | C Int deriving (Eq, Ord)

main : <IO> Unit
main =
  println (Red < Blue)
  println (Blue < Red)
  println (compare Red Blue)
  println (compare (A 5) (B 1))
  println (compare (A 2) (A 1))
# EVAL
True
False
Lt
Lt
Gt
