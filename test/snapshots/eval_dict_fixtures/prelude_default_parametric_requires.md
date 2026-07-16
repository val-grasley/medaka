# META
source_lines=84
stages=EVAL
# SOURCE
-- #315: a user impl of a PRELUDE interface, in another module, relying on a DEFAULT
-- method.  desugar's fillImplDefaults specialises an interface's defaults into an
-- impl only when both are in the SAME decl list (desugar.mdk:698-700), and desugar
-- is handed one module at a time — so `impl Ord (Box a)` below gets NO specialised
-- `lt`/`gt`/… and dispatch falls to the interface's own generic default body.  That
-- body is shared by every impl, so it declares no impl-dict params and its inner
-- `compare` is stamped RNone.  eval applied the call site's `requires` dicts to it
-- anyway: the dict bound to `lt`'s first VALUE param `x`, the body returned False,
-- and the real argument was then applied to False → "applied non-function: false",
-- while `build` was correct (the emitter lifts a per-tag copy and eta-prepends the
-- dicts — emitDefaultDefine/restampIfaceDicts).  A loud run≠build divergence.
--
-- The trigger is a CONJUNCTION — each ingredient alone is fine, so the controls
-- below are load-bearing:
--   * cross-module + default, but NO `requires`      → `Mono` (worked before)
--   * `requires`, but the method is DIRECTLY defined → `compare` (worked before)
--   * same-module interface + default + `requires`   → `MyBox` (desugar specialises)
-- Every value below is hand-derived from the source and matches `medaka build`.

data Box a = Box a deriving (Debug)

impl Eq (Box a) requires Eq a where
  eq (Box x) (Box y) = eq x y

-- defines ONLY `compare`; lt/gt/lte/gte/min/max are inherited PRELUDE defaults
impl Ord (Box a) requires Ord a where
  compare (Box x) (Box y) = compare x y

-- CONTROL: cross-module + inherited defaults, but no `requires` (nothing to route)
data Mono = Mono Int deriving (Debug)

impl Eq Mono where
  eq (Mono x) (Mono y) = eq x y

impl Ord Mono where
  compare (Mono x) (Mono y) = compare x y

-- CONTROL: a SAME-module interface + default + `requires` — desugar specialises the
-- default into the impl, so this never took the inherited-default path.
interface MyOrd a where
  mycompare : a -> a -> Ordering
  mylt : a -> a -> Bool
  mylt x y = match mycompare x y
    Lt => True
    _ => False

data MyBox a = MyBox a

impl MyOrd Int where
  mycompare x y = compare x y

impl MyOrd (MyBox a) requires MyOrd a where
  mycompare (MyBox x) (MyBox y) = mycompare x y

main : <IO> Unit
main =
  -- lt@Box is an INHERITED prelude default: `match compare x y { Lt => True; _ => False }`.
  -- compare (Box 1) (Box 2) → compare 1 2 → Lt ⇒ True
  println (lt (Box 1) (Box 2))
  -- gt: `match compare x y { Gt => True; _ => False }`; compare → Lt ⇒ False
  println (gt (Box 1) (Box 2))
  -- lte: `match compare x y { Gt => False; _ => True }`; compare 2 2 → Eq ⇒ True
  println (lte (Box 2) (Box 2))
  -- gte: `match compare x y { Lt => False; _ => True }`; compare 1 2 → Lt ⇒ False
  println (gte (Box 1) (Box 2))
  -- the operator form of the same default ⇒ True
  println (Box 1 < Box 2)
  -- min: `match compare x y { Gt => y; _ => x }`; compare 5 3 → Gt ⇒ y = Box 3
  println (debug (min (Box 5) (Box 3)))
  -- max: `match compare x y { Lt => y; _ => x }`; compare 5 3 → Gt ⇒ x = Box 5
  println (debug (max (Box 5) (Box 3)))
  -- RECURSIVE: the inherited default must route the ELEMENT dict too.
  -- compare (Box (Box 1)) (Box (Box 2)) → compare (Box 1) (Box 2) → compare 1 2 → Lt ⇒ True
  println (lt (Box (Box 1)) (Box (Box 2)))
  -- CONTROL: `compare` is DIRECTLY defined by the impl, not inherited ⇒ Lt
  println (compare (Box 1) (Box 2))
  -- CONTROL: no `requires` — compare 1 2 → Lt ⇒ True
  println (lt (Mono 1) (Mono 2))
  -- CONTROL: the prelude's OWN parametric impls, whose defaults desugar DID
  -- specialise (interface + impl are both in core.mdk) ⇒ True, True
  println (lt [1] [2])
  println (lt (Some 1) (Some 2))
  -- CONTROL: same-module interface + `requires` ⇒ mycompare 1 2 → Lt ⇒ True
  println (mylt (MyBox 1) (MyBox 2))
# EVAL
True
False
True
False
True
Box 3
Box 5
True
Lt
True
True
True
True
