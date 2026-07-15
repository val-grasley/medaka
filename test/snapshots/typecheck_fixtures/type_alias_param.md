# META
source_lines=12
stages=TYPES
# SOURCE
-- Parameterized type aliases expand transparently (stage 3): `Pair a` → `(a, a)`,
-- transitively through alias-of-alias (`IntPair = Pair Int` → `(Int, Int)`).
type Pair a = (a, a)
type IntPair = Pair Int
mk : a -> Pair a
mk x = (x, x)
firstOf : Pair a -> a
firstOf p = match p
  (x, _) => x
fixed : IntPair -> Int
fixed p = match p
  (a, _) => a
# TYPES
mk : a -> (a, a)
firstOf : (a, a) -> a
fixed : (Int, Int) -> Int
