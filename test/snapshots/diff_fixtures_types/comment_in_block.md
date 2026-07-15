# META
source_lines=5
stages=TYPES_USER
# SOURCE
f x =
  -- comment inside = block
  x + 1

main = println (f 3)
# TYPES_USER
f : Num a => a -> a
main : Unit
