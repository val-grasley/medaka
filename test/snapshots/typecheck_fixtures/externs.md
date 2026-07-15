# META
source_lines=15
stages=TYPES
# SOURCE
-- extern declarations become top-level schemes; pure externs used freely,
-- effectful externs used through a signature that declares the effect
-- (inferred effect PROPAGATION from an unsigned call site needs open rows —
-- a later slice — so it's avoided here)
extern strLen : String -> Int
extern toChars : String -> List Char
extern wrapL : a -> List a
extern emit : String -> <IO> Unit
extern rng : Unit -> <Rand> Int
useLen s = strLen s
charsOf s = toChars s
boxIt x = wrapL x
combine a b = strLen a + strLen b
shout : String -> <IO> Unit
shout s = emit s
# TYPES
strLen : String -> Int
toChars : String -> List Char
wrapL : a -> List a
emit : String -> <IO> Unit
rng : Unit -> <Rand> Int
useLen : String -> Int
charsOf : String -> List Char
boxIt : a -> List a
combine : String -> String -> Int
shout : String -> <IO> Unit
