# META
source_lines=28
stages=EVAL
# SOURCE
-- #609 regression (S0, silent wrongness): impl selection for a MULTI-PARAM
-- interface must match the FULL head vector, not just head argument 0.
--
-- `ix 1 'x'` is the goal `Ix Int Char`, which matches EXACTLY ONE impl.  Before
-- the fix every selection path (keyEntryOf's matchable pattern, matchingEntries,
-- entryCovers → tySubsumes) compared arg-0 patterns only, so `Ix Int Bool` and
-- `Ix Int Char` were "⊑-equal" — no unique min⊑ — and pickMostSpecificEntry fell
-- to FIRST MATCH.  Result: `check` exit 0 and the program printed 100, the
-- `Ix Int Bool` impl.  DICT-SEMANTICS §3: `match(IE, C τ̄)` and `⊑` range over the
-- head VECTOR `τ̄`; §6 C3 forbids selection from depending on declaration order.
--
-- The asymmetry that made it SILENT rather than an error: the concrete-obligation
-- CHECKER (implMatchesU) always walked the full vector, so `ix 1 "nope"` correctly
-- errored `No impl of Ix for Int String`.  The checker saw the vector; the router
-- did not.  Both engines agreed and were uniformly wrong, so no differential gate
-- could see it — only a golden pinning the VALUE can.
--
-- See multiparam_impl_selection_swapped.mdk for the §6 C3 order-independence half.
interface Ix a i where
  ix : a -> i -> Int

impl Ix Int Bool where
  ix a i = 100

impl Ix Int Char where
  ix a i = 200

main = println (ix 1 'x')
# EVAL
200
