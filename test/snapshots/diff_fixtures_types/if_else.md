# META
source_lines=15
stages=TYPES_USER
# SOURCE
classify n =
  if n < 0 then "negative"
  else if n > 0 then "positive"
  else "zero"

abs n =
  if n < 0 then 0 - n
  else n

main : <IO> Unit
main =
  println (classify (-5))
  println (classify 0)
  println (classify 3)
  println (abs (-7))
# TYPES_USER
abs : (Num b, Ord b) => a -> a
classify : (Num a, Ord a) => a -> String
abs : (Num a, Ord a) => a -> a
main : Unit
