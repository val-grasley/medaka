# META
source_lines=34
stages=TYPES
# SOURCE
-- Constructor applications of non-expansive arguments generalize (SML value
-- restriction relaxation, Phase 66 extension).  All cases below must check
-- clean: the bindings generalize and are usable at multiple instantiations.

-- Full constructor application with a lambda arg: MkBox (x => x) generalizes
data Box a = MkBox a
e = MkBox (x => x)
ei : Box (Int -> Int)
ei = e
es : Box (String -> String)
es = e

-- Partial constructor application: MkTwo (x => x) generalizes (closure, not a mutable cell)
data Two a b = MkTwo a b
g = MkTwo (x => x)
gi : Box (Int -> Int) -> Two (Int -> Int) (Box (Int -> Int))
gi = g
gs : Box (String -> String) -> Two (String -> String) (Box (String -> String))
gs = g

-- Nested constructor application: MkBox (MkBox (x => x)) generalizes
v = MkBox (MkBox (x => x))
vi : Box (Box (Int -> Int))
vi = v
vs : Box (Box (String -> String))
vs = v

-- Record creation of non-expansive fields generalizes
data Pair a = { l : a -> a, r : a -> a }
p = Pair { l = (x => x), r = (x => x) }
pi : Pair Int
pi = p
ps : Pair String
ps = p
# TYPES
e : Box (a -> a)
ei : Box (Int -> Int)
es : Box (String -> String)
g : a -> Two (b -> b) a
gi : Box (Int -> Int) -> Two (Int -> Int) (Box (Int -> Int))
gs : Box (String -> String) -> Two (String -> String) (Box (String -> String))
v : Box (Box (a -> a))
vi : Box (Box (Int -> Int))
vs : Box (Box (String -> String))
p : Pair a
pi : Pair Int
ps : Pair String
