# META
source_lines=11
stages=TYPES_USER
# SOURCE
interface Sz a where
  sz : a -> Int

impl Sz Int where
  sz x = g x
    where
      g n = n + 1

g x = x

main = println (g "hi")
# TYPES_USER
g : a -> a
main : Unit
