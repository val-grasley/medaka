# META
source_lines=77
stages=EVAL
# SOURCE
-- #412: an impl's `requires` context whose subject is STRUCTURED (`requires S (List a)`,
-- not the bare-tyvar `requires S a` that #413's impl_requires_terminal_body pins) must be
-- discharged by the SAME entailment as a top-level goal, at the CONSTRUCTION SITE's goal
-- instantiation — DICT-SEMANTICS §2 "uniformity of nested resolution" ("sub-evidence is
-- never pre-baked at the instance declaration against the general head") and §3's
-- assum-before-inst precedence.
--
-- Before the fix the impl body statically committed to the GENERAL `impl S (List a)`
-- (emitting `call @mdk_impl_S__List_a___s` outright) and threw away the most-specific
-- dict the construction site had correctly built and passed: `assum` was unreachable for
-- a structured given, because the given registry was keyed by TYVAR ID and the goal
-- lookup recursed to the SPINE HEAD (`S (List a)` → `TCon "List"` → no tyvar → None →
-- fall through to `inst`). So every cell below silently printed the general instance's
-- value under `build` (2/2/200/21, exit 0) and `run` crashed outright.
--
-- Every value is hand-derived, and `run` and `build` must AGREE on all of them
-- (DICT-SEMANTICS §7, the single-evaluator law) — this file is committed to BOTH
-- test/eval_dict_fixtures/ and test/build_diff_fixtures/ byte-for-byte for exactly that
-- reason. The §6.1.3 rigid-commit control (`requires S a` must still print 2 under
-- overlap) lives in test/build_diff_fixtures/impl_requires_structured_rigid_control.mdk;
-- it cannot be pinned here because `run` crashes on that shape (a separate, pre-existing
-- bug — see that fixture's header).
interface S a where
  s : a -> Int

interface T a where
  t : a -> Int

interface U a where
  u : a -> Int

impl S Int where
  s n = 100 + n

-- the GENERAL instance: what a declaration-head pre-bake wrongly commits to
impl S (List a) requires S a where
  s _ = 200

-- the MORE SPECIFIC instances that must win at a ground construction goal
impl S (List Int) where
  s _ = 300

impl S (List String) where
  s _ = 400

-- structured `requires`: the context subject is `List a`, the impl head's own subject
impl T (List a) requires S (List a) where
  t x = s x

-- a body that PATTERN-MATCHES its argument: proves the value arg still arrives intact
-- alongside the forwarded dict (the calling convention is not disturbed)
impl S (List Bool) where
  s xs = match xs
    [] => 30
    _ => 31

impl U (List a) requires S (List a) where
  u x = s x

-- GROUND control: a non-parametric impl head needs no context, and its `s x` goal is
-- ground at the DECLARATION — this arm resolved most-specifically before the fix and
-- must be undisturbed by it.
impl T (List Bool) where
  t x = s x

main : <IO> Unit
main =
  -- t [1,2] → impl T (List a) at a:=Int → its `requires S (List Int)` is discharged at
  --   the CONSTRUCTION goal, where min⊑ picks `impl S (List Int)` over `impl S (List a)`
  --   → the body's `s x` reads that forwarded dict → 300
  println (t [1, 2])
  -- SAME impl body, different construction goal → per-site dict, not type-pinned → 400
  println (t ["a"])
  -- the matching body receives its list (not a dict) in the value param → 31
  println (u [True, False])
  -- ground control: impl T (List Bool) → `s x` at the ground goal S (List Bool) → 31
  println (t [True])
# EVAL
300
400
31
31
