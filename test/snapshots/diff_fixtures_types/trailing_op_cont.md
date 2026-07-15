# META
source_lines=49
stages=TYPES_USER
# SOURCE
addN : Int -> Int -> Int
addN x y = x + y

arith : Int -> Int -> Int
arith a b = a +
  b *
  2

sub : Int -> Int -> Int
sub a b = a -
  b

divmod : Int -> Int -> Int
divmod a b = a /
  b %
  3

cmp : Int -> Int -> Bool
cmp a b = a ==
  b

cmp2 : Int -> Int -> Bool
cmp2 a b = a <
  b

logic : Bool -> Bool -> Bool
logic p q = p &&
  q ||
  False

listcat : List Int -> List Int -> List Int
listcat xs ys = xs ++
  ys

cons : Int -> List Int -> List Int
cons h t = h ::
  t

pipeline : Int -> Int
pipeline x = x |>
  addN 1

composeR : Int -> Int
composeR x = (addN 1 >> addN 2) x

composeL : Int -> Int
composeL x = (addN 1 << addN 2) x

main = println (arith 3 4)
# TYPES_USER
sub : a -> a -> a
addN : Int -> Int -> Int
arith : Int -> Int -> Int
sub : Int -> Int -> Int
divmod : Int -> Int -> Int
cmp : Int -> Int -> Bool
cmp2 : Int -> Int -> Bool
logic : Bool -> Bool -> Bool
listcat : List Int -> List Int -> List Int
cons : Int -> List Int -> List Int
pipeline : Int -> Int
composeR : Int -> Int
composeL : Int -> Int
main : Unit
