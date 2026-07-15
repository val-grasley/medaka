# META
source_lines=18
stages=EVAL
# SOURCE
-- TYPECHECK-AUDIT C7 (arg position): two non-overlapping impls sharing a head
-- tycon (MyPair), dispatched by an ARGUMENT-position method `mydef`.  Head-tag-only
-- arg-stamp routing sent both `MyPair Int Bool` and `MyPair Bool Int` to the first
-- impl; the canonical-impl-key route (resolveArgStamp keyForSite) picks each == oracle.
data MyPair a b = MyPair a b

interface Def a where
  mydef : a -> String

impl Def (MyPair Int Bool) where
  mydef p = "int-bool"

impl Def (MyPair Bool Int) where
  mydef p = "bool-int"

main =
  putStrLn (mydef (MyPair 1 True))
  putStrLn (mydef (MyPair True 2))
# EVAL
int-bool
bool-int
