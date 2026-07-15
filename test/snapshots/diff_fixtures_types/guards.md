# META
source_lines=18
stages=TYPES_USER
# SOURCE
sign n
  | n < 0 = "neg"
  | n > 0 = "pos"
  | True = "zero"

clamp lo hi n
  | n < lo = lo
  | n > hi = hi
  | True = n

main : <IO> Unit
main =
  println (sign (-3))
  println (sign 0)
  println (sign 5)
  println (clamp 0 10 (-5))
  println (clamp 0 10 15)
  println (clamp 0 10 7)
# TYPES_USER
clamp : Ord a => a -> a -> a -> a
sign : (Num a, Ord a) => a -> String
main : Unit
