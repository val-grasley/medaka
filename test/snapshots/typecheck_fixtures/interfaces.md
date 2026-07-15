# META
source_lines=19
stages=TYPES
# SOURCE
-- interface method schemes (the interface param is just a free tyvar); impls
-- typecheck-validate but add no output bindings
interface Eq2 a where
  eq2 : a -> a -> Bool
  neq2 : a -> a -> Bool
interface Mappable2 f where
  map2 : (a -> b) -> f a -> f b
interface Container c where
  empty2 : c a
  insert2 : a -> c a -> c a
  toL : c a -> List a
data Color = R | G | B
impl Eq2 Color where
  eq2 x y = True
  neq2 x y = False
useEq a b = eq2 a b
mapTwice f = map2 (map2 f)
build x y = insert2 x (insert2 y empty2)
collect c = toL c
# TYPES
eq2 : a -> a -> Bool
neq2 : a -> a -> Bool
map2 : (a -> b) -> c a -> c b
empty2 : a b
insert2 : a -> b a -> b a
toL : a b -> List b
useEq : Eq2 a => a -> a -> Bool
mapTwice : (Mappable2 c, Mappable2 d) => (a -> b) -> c (d a) -> c (d b)
build : Container b => a -> a -> b a
collect : Container a => a b -> List b
