# META
source_lines=11
stages=TYPES_USER
# SOURCE
interface P a where
  p : a -> Int

impl P Int where
  p x = x

foo x = p x
  where
    p n = n + 1

main = println (p 5 + foo 7)
# TYPES_USER
foo : Num a => a -> a
main : Unit
