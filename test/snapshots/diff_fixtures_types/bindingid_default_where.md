# META
source_lines=12
stages=TYPES_USER
# SOURCE
interface Bx a where
  bx : a -> Int
  bx x = g 0
    where
      g n = n + 1

impl Bx Int where
  bx x = x

g x = x

main = println (g "hi")
# TYPES_USER
g : a -> a
main : Unit
