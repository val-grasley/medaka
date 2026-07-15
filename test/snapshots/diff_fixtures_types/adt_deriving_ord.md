# META
source_lines=12
stages=TYPES_USER
# SOURCE
data Color = Red | Green | Blue deriving (Eq, Ord)

data T = A Int | B Int | C Int deriving (Eq, Ord)

main : <IO> Unit
main =
  println (compare Red Blue)
  println (compare Blue Red)
  println (compare Green Green)
  println (compare (A 5) (B 1))
  println (compare (A 1) (A 2))
  println (compare (A 2) (A 1))
# TYPES_USER
main : Unit
