# META
source_lines=15
stages=TYPES_USER
# SOURCE
pair a b = (a, b)

applyBoth f g x = (f x, g x)

double x = x * 2
inc x = x + 1

main : <IO> Unit
main =
  let t = pair 1 "one"
  println (fst t)
  println (snd t)
  let r = applyBoth double inc 5
  println (fst r)
  println (snd r)
# TYPES_USER
pair : a -> b -> (a, b)
applyBoth : (a -> b) -> (a -> c) -> a -> (b, c)
double : Num a => a -> a
inc : Num a => a -> a
main : Unit
