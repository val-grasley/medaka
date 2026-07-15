# META
source_lines=17
stages=EVAL
# SOURCE
-- F0 regression: a typeclass method with a typaram that appears ONLY in return
-- position (`v` in `Get c v where get1 : c -> v`), while dispatch is on the
-- argument-position receiver `c`.  Before the fix, the still-unbound return-only
-- `v` was registered as an INDEPENDENT impl-selection (call) obligation; once
-- groundMultiParamObligations later grounded it to `Int`, checkCallObligations
-- rejected it (`No impl of Get for Int`) — the return param leaked into the
-- impl-lookup key.  Now dispatch/ambiguity keys off the receiver typaram only
-- (dispatchTyparams), so `v` is impl-determined AFTER receiver dispatch.
interface Get c v where
  get1 : c -> v

data Box a = Box a

impl Get (Box a) a where
  get1 (Box x) = x

main = println (get1 (Box 42))
# EVAL
42
