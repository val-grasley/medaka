# META
source_lines=21
stages=TYPES
# SOURCE
-- operators infer by shape (arithmetic a->a->a, comparison a->a->Bool, etc.)
add x y = x + y
poly a b c = a + b * c - 1
negI x = 0 - x
negP x = -x
eqp x y = x == y
ltp a b = a < b
clampish a lo hi = if a < lo then lo else if a > hi then hi else a
andb a b = a && b
orb a b = a || b
notb x = !x
appx x y = x ++ y
consx x ys = x :: ys
pipeIt x g = x |> g
fwd g h = g >> h
bwd g h = g << h
applyfn f a b = f a b
data L a = Nil | Cons a (L a)
total xs = match xs
  Nil => 0
  Cons h t => h + total t
# TYPES
add : a -> a -> a
poly : Num a => a -> a -> a -> a
negI : Num a => a -> a
negP : a -> a
eqp : a -> a -> Bool
ltp : a -> a -> Bool
clampish : a -> a -> a -> a
andb : Bool -> Bool -> Bool
orb : Bool -> Bool -> Bool
notb : Bool -> Bool
appx : a -> a -> a
consx : a -> List a -> List a
pipeIt : a -> (a -> b) -> b
fwd : (a -> b) -> (b -> c) -> a -> c
bwd : (a -> b) -> (c -> a) -> c -> b
applyfn : (a -> b -> c) -> a -> b -> c
total : Num a => L a -> a
