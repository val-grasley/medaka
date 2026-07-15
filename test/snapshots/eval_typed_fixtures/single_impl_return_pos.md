# META
source_lines=16
stages=EVAL
# SOURCE
-- A user-defined interface with a SINGLE impl and a return-position method (the
-- type param appears only in the result, so there's no discriminating argument).
-- A single impl binds to a BARE VTypedImpl, never coalesced into a VMulti — the
-- typed path must still strip that wrapper for the nullary body (narrowMethod's
-- VTypedImpl arm), or the dispatch wrapper leaks and `debug`/arithmetic see a
-- non-Int.  Before the fix this panicked "intToString: not an Int".
interface Default a where
  def : a

impl Default Int where
  def = 7

base : Int
base = def

main = println (debug (base + 1))
# EVAL
8
