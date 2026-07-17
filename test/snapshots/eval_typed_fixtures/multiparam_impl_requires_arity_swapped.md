# META
source_lines=41
stages=EVAL
# SOURCE
-- #609 regression, §6 C3 half of multiparam_impl_requires_arity.mdk: the SAME
-- program with the two `Ix` impls declared in the opposite order.  Both must print
-- 2050.
--
-- This sibling PASSED pre-fix (the Char impl being declared first meant first-match
-- happened to agree with the goal), while its twin died with
-- `E-NONEXHAUSTIVE-MATCH`.  Identical semantics, opposite outcomes, decided purely
-- by declaration order — so the PAIR is the gate; neither file alone can see it.
data Box a = Box a

interface Foo a where
  foo : a -> Int
impl Foo Int where
  foo x = 7
impl Foo Bool where
  foo x = 8

interface Baz a where
  baz : a -> Int
impl Baz Int where
  baz x = 300
impl Baz Bool where
  baz x = 400

interface Bar a where
  bar : a -> Int
impl Bar Int where
  bar x = 50
impl Bar Bool where
  bar x = 60

interface Ix c i where
  ix : c -> i -> Int

impl Ix (Box a) Char requires Bar a where
  ix (Box x) i = bar x + 2000

impl Ix (Box a) Bool requires Foo a, Baz a where
  ix (Box x) i = foo x + baz x

main = println (ix (Box 1) 'z')
# EVAL
2050
