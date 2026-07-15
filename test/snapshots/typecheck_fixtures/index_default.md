# META
source_lines=9
stages=TYPES
diagnostics=TYPES
# SOURCE
-- C9: a.[i] mirrors the oracle's normalize-and-branch on the receiver head.
-- Undetermined receiver defaults to Array (NOT List): f : Array a -> a.
f xs = xs.[0]
-- String literal receiver -> Char.
fc = "hello".[0]
-- Array literal receiver -> element.
fa = [10, 20, 30].[1]
-- List receiver (forced by cons) -> element.
fl x a = let _ = (x :: a) in a.[0]
# TYPES
TYPE ERROR: Unbound variable: index
TYPE ERROR: Unbound variable: index
TYPE ERROR: Unbound variable: index
TYPE ERROR: Unbound variable: index
