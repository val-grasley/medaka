# META
source_lines=14
stages=TYPES
# SOURCE
-- let-polymorphism, if, lists, tuples, list/cons patterns
idLet = let f = (x => x) in (f, f)
nums = [1, 2, 3]
strs = ["a", "b"]
mixed = ("hi", True, [1])
pick b x y = if b then x else y
nil = []
cons2 x y = [x, y]
firstOr d xs = match xs
  (h :: _) => h
  [] => d
len xs = match xs
  [] => 0
  (_ :: t) => len t
# TYPES
idLet : (a -> a, b -> b)
nums : List Int
strs : List String
mixed : (String, Bool, List Int)
pick : Bool -> a -> a -> a
nil : List a
cons2 : a -> a -> List a
firstOr : a -> List a -> a
len : List a -> Int
