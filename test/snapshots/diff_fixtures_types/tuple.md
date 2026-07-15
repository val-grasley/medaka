# META
source_lines=12
stages=TYPES_USER
# SOURCE
swap (a, b) = (b, a)

addPair (a, b) = a + b

main : <IO> Unit
main =
  let t = (3, 7)
  println (fst t)
  println (snd t)
  println (addPair t)
  let u = swap t
  println (fst u)
# TYPES_USER
swap : (a, b) -> (b, a)
addPair : Num a => (a, a) -> a
main : Unit
