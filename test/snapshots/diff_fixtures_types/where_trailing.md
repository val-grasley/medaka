# META
source_lines=4
stages=TYPES_USER
# SOURCE
f x = go x where
  go n = n + 1

main = println (f 5)
# TYPES_USER
f : Num a => a -> a
main : Unit
