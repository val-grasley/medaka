# META
source_lines=15
stages=TYPES
# SOURCE
-- effect annotations on arrows (rendered only when non-empty; pure inference
-- stays bare; <eff> on a non-arrow is dropped)
emit : Int -> <IO> Unit
emit x = ()
gen : a -> <IO, Rand> a
gen x = x
pureVal : <IO> Int
pureVal = 5
higher : (a -> <IO> b) -> a -> <IO> b
higher fn x = fn x
runTwice : (Unit -> <IO> a) -> <IO> Unit
runTwice fn = ()
mixed : Int -> Int -> <Rand> Bool
mixed a b = a == b
purePoly x = x
# TYPES
emit : Int -> <IO> Unit
gen : a -> <IO, Rand> a
pureVal : Int
higher : (a -> <IO> b) -> a -> <IO> b
runTwice : (Unit -> <IO> a) -> <IO> Unit
mixed : Int -> Int -> <Rand> Bool
purePoly : a -> a
