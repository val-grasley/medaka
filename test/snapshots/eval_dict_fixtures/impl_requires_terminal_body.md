# META
source_lines=44
stages=EVAL
# SOURCE
-- #413: a call site forwards an impl's `requires` dicts UNCONDITIONALLY, but
-- dict_pass only gives an impl method matching leading params when its body actually
-- READS one (usesImplDict).  A terminal body (`s _ = 2`) declares none — so eval must
-- not apply the route's dicts to it, or the dict lands in the first value param and
-- the real argument is then applied to the RESULT ("applied non-function: 2").
-- Pins BOTH sides of that gate: an impl that ignores its requires dict, and one that
-- consumes it (including recursively), so a fix cannot "pass" by dropping dicts that
-- ARE needed.  Every value below is hand-derived, and matches `medaka build`.
interface S a where
  s : a -> Int

interface P a requires S a where
  p : a -> Int

impl S Int where
  s _ = 1

-- terminal: IGNORES its `requires S a` dict ⇒ dict_pass gives it NO dict param
impl S (List a) requires S a where
  s _ = 2

-- consuming: READS its `requires S a` dict ⇒ dict_pass gives it one
impl S (Option a) requires S a where
  s (Some x) = 10 + s x
  s None = 0

impl P (List a) requires S a where
  p x = s x

impl P (Option a) requires S a where
  p x = s x

main : <IO> Unit
main =
  -- p [1,2] → impl P (List a) → `p x = s x` → s [1,2] → impl S (List a) → 2
  println (p [1, 2])
  -- p (Some 3) → impl P (Option a), a:=Int → s (Some 3) → impl S (Option a)
  --   → 10 + s 3 → 10 + (impl S Int → 1) = 11
  println (p (Some 3))
  -- s (Some (Some 4)) → impl S (Option a), a:=Option Int → 10 + s (Some 4)
  --   → 10 + (10 + s 4) → 10 + (10 + 1) = 21   [recursive dict threading]
  println (s (Some (Some 4)))
  -- s [1,2] direct (no enclosing impl body) → impl S (List a) → 2
  println (s [1, 2])
# EVAL
2
11
21
2
