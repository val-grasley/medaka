# META
source_lines=44
stages=TYPES_USER
# SOURCE
-- Capability-effects v2 Stage 2a: PARAMETERIZED effect surface syntax.
-- This fixture is the CLI-level guard that the unit-test bypass (raw
-- Parser.program in test_typecheck.ml) failed to provide: it must parse +
-- typecheck through the REAL indentation-aware `check` pipeline on both the
-- OCaml oracle and the native self-host, exercising every Stage-2a form:
--   * `effect Net Prefix`     — domain-carrying effect decl (Prefix refinement)
--   * `effect Stdout`         — plain (domainless) effect decl
--   * `<Net "a.com/foo">`      — effect-row atom with a Prefix-pattern argument
--   * `data Async e a = … <e> …` — an effect-row PARAMETER on a data decl:
--       `e` is kind-inferred KRow from its use in the Suspend field's effect
--       tail, so `runAsync : Async e a -> <e> a` performs exactly the stored row
effect Net Prefix
effect Stdout

extern netGet : String -> <Net "a.com/foo"> String

fetch : String -> <Net "a.com/foo"> String
fetch path = netGet path

data Async e a = Done a | Suspend (Unit -> <e> Async e a)

runAsync : Async e a -> <e> a
runAsync m = match m
  Done a => a
  Suspend t => runAsync (t ())

liftIO : (Unit -> <e> a) -> Async e a
liftIO act = Suspend (u => Done (act u))

-- regression guard (native-only bug, fixed): a KRow param `e` that appears
-- ONLY as a type-app argument (no `<e>` tail anywhere in the signature) must
-- still resolve to the shared row effvar.  `instantiateSigTracked`'s Pass-A
-- pre-unify etbl seeded from `effTailNames` ALONE collapsed `e` to the pure
-- closed row, so `yld` inferred `Async <> Unit` and an effectful continuation
-- threaded after it spuriously "leaked" <IO>.  Fix: seed `rowArgNames` too.
yld : Async e Unit
yld = Suspend (_ => Done ())

seqIO : Async e a -> (a -> Async e b) -> Async e b
seqIO (Done a) k = k a
seqIO (Suspend t) k = Suspend (u => seqIO (t u) k)

main : <IO> Unit
main = runAsync (seqIO yld (_ => liftIO (u => println "effect param ok")))
# TYPES_USER
netGet : String -> <Net "a.com/foo"> String
fetch : String -> <Net "a.com/foo"> String
runAsync : Async a b -> b
liftIO : (Unit -> a) -> Async b a
yld : Async a Unit
seqIO : Async a b -> (b -> Async a c) -> Async a c
main : Unit
