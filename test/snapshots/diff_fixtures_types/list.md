# META
source_lines=11
stages=TYPES_USER
# SOURCE
sum xs = fold (acc x => acc + x) 0 xs

myLength xs = fold (acc _ => acc + 1) 0 xs

main : <IO> Unit
main =
  let xs = [1, 2, 3, 4, 5]
  println (sum xs)
  println (myLength xs)
  println (sum ([] : List Int))
  println ([1, 2] ++ [3, 4])
# TYPES_USER
sum : (Foldable a, Num b) => a b -> b
myLength : Foldable a => a b -> Int
main : Unit
