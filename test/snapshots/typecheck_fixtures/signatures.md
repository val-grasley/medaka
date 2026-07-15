# META
source_lines=22
stages=TYPES
# SOURCE
-- explicit type signatures constrain inference (and polymorphic recursion)
f : Int -> Int
f x = x
g : a -> a
g y = y
h : (a -> b) -> a -> b
h fn z = fn z
konst : a -> b -> a
konst x y = x
poly : a -> (a, a)
poly x = (x, x)
data Opt a = Non | Som a
safeHead : List a -> Opt a
safeHead xs = match xs
  (z :: _) => Som z
  [] => Non
mapO : (a -> b) -> Opt a -> Opt b
mapO fn o = match o
  Som x => Som (fn x)
  Non => Non
ann = (5 : Int)
strAnn = ("hi" : String)
# TYPES
f : Int -> Int
g : a -> a
h : (a -> b) -> a -> b
konst : a -> b -> a
poly : a -> (a, a)
safeHead : List a -> Opt a
mapO : (a -> b) -> Opt a -> Opt b
ann : Int
strAnn : String
