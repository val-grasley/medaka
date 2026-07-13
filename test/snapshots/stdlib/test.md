# META
source_lines=129
stages=DESUGAR,MARK
# SOURCE
-- test.mdk — unit testing library.
-- Import what you need: `import test.{expectEqual, expectTrue, …}`
-- Run with: `medaka test your_file.mdk`
-- See STDLIB.md for the division-of-labour between doctests / props / tests.

{- | The result of a single test expectation. -}
public export data Expectation = Pass | Fail String deriving (Debug)

-- ── Primitive assertions ─────────────────────────────────────────────────

{- | Always passes.

   > pass
   Pass -}
export pass : Expectation
pass = Pass

{- | Fails with the given message.

   > fail "not ready"
   Fail "not ready" -}
export fail : String -> Expectation
fail msg = Fail msg

{- | Passes when the `Bool` is `True`.

   > expectTrue True
   Pass
   > expectTrue False
   Fail "expected True but got False" -}
export expectTrue : Bool -> Expectation
expectTrue True = Pass
expectTrue False = Fail "expected True but got False"

{- | Passes when the `Bool` is `False`.

   > expectFalse False
   Pass
   > expectFalse True
   Fail "expected False but got True" -}
export expectFalse : Bool -> Expectation
expectFalse False = Pass
expectFalse True = Fail "expected False but got True"

{- | Passes when the two values are equal.

   > expectEqual 42 42
   Pass
   > expectEqual 1 2
   Fail "expected 1 but got 2" -}
export expectEqual : (Eq a, Debug a) => a -> a -> Expectation
expectEqual expected actual =
  if eq expected actual then
    Pass
  else
    Fail "expected \{debug expected} but got \{debug actual}"

{- | Passes when the two values are not equal.

   > expectNotEqual 1 2
   Pass
   > expectNotEqual 1 1
   Fail "expected values to differ but both were 1" -}
export expectNotEqual : (Eq a, Debug a) => a -> a -> Expectation
expectNotEqual expected actual =
  if neq expected actual then
    Pass
  else
    Fail ("expected values to differ but both were " ++ debug actual)

{- | Passes when `actual < expected`.

   > expectLessThan 10 3
   Pass
   > expectLessThan 10 15
   Fail "expected 15 < 10" -}
export expectLessThan : (Ord a, Debug a) => a -> a -> Expectation
expectLessThan expected actual =
  if lt actual expected then
    Pass
  else
    Fail "expected \{debug actual} < \{debug expected}"

{- | Passes when `actual > expected`.

   > expectGreaterThan 0 5
   Pass
   > expectGreaterThan 10 3
   Fail "expected 3 > 10" -}
export expectGreaterThan : (Ord a, Debug a) => a -> a -> Expectation
expectGreaterThan expected actual =
  if gt actual expected then
    Pass
  else
    Fail "expected \{debug actual} > \{debug expected}"

-- Helper for expectAll: accumulate the first Fail, or stay Pass.
expectAllStep : Expectation -> Expectation -> Expectation
expectAllStep (Fail msg) _ = Fail msg
expectAllStep Pass e = e

{- | Combine a list of expectations: passes only when all of them pass.
   The first `Fail` is returned immediately.

   > expectAll [Pass, Pass, Pass]
   Pass
   > expectAll [Pass, Fail "oops", Pass]
   Fail "oops" -}
export expectAll : List Expectation -> Expectation
expectAll es = fold expectAllStep Pass es

-- ── Test runner ──────────────────────────────────────────────────────────

goTests : List (String, Unit -> Expectation) -> Int -> Int -> <IO> Bool
goTests [] passed failed =
  println "\n\{intToString passed} passed, \{intToString failed} failed"
  eq failed 0
goTests ((name, thunk)::rest) passed failed = match thunk ()
  Pass =>
    println ("  ok   " ++ name)
    goTests rest (passed + 1) failed
  Fail msg =>
    println "  FAIL \{name}: \{msg}"
    goTests rest passed (failed + 1)

{- | Run a list of `(name, thunk)` test pairs.  Prints each result and a
   final summary; returns `True` when all tests pass. -}
export runTests : List (String, Unit -> Expectation) -> <IO> Bool
runTests tests = goTests tests 0 0
# DESUGAR
(DData Public "Expectation" () ((variant "Pass" (ConPos)) (variant "Fail" (ConPos (TyCon "String")))) ())
(DImpl true "Debug" ((TyCon "Expectation")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Pass") () (ELit (LString "Pass"))) (arm (PCon "Fail" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Fail ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DTypeSig true "pass" (TyCon "Expectation"))
(DFunDef false "pass" () (EVar "Pass"))
(DTypeSig true "fail" (TyFun (TyCon "String") (TyCon "Expectation")))
(DFunDef false "fail" ((PVar "msg")) (EApp (EVar "Fail") (EVar "msg")))
(DTypeSig true "expectTrue" (TyFun (TyCon "Bool") (TyCon "Expectation")))
(DFunDef false "expectTrue" ((PCon "True")) (EVar "Pass"))
(DFunDef false "expectTrue" ((PCon "False")) (EApp (EVar "Fail") (ELit (LString "expected True but got False"))))
(DTypeSig true "expectFalse" (TyFun (TyCon "Bool") (TyCon "Expectation")))
(DFunDef false "expectFalse" ((PCon "False")) (EVar "Pass"))
(DFunDef false "expectFalse" ((PCon "True")) (EApp (EVar "Fail") (ELit (LString "expected False but got True"))))
(DTypeSig true "expectEqual" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectEqual" ((PVar "expected") (PVar "actual")) (EIf (EApp (EApp (EVar "eq") (EVar "expected")) (EVar "actual")) (EVar "Pass") (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "expected")))) (ELit (LString " but got "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "actual")))) (ELit (LString ""))))))
(DTypeSig true "expectNotEqual" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectNotEqual" ((PVar "expected") (PVar "actual")) (EIf (EApp (EApp (EVar "neq") (EVar "expected")) (EVar "actual")) (EVar "Pass") (EApp (EVar "Fail") (EBinOp "++" (ELit (LString "expected values to differ but both were ")) (EApp (EVar "debug") (EVar "actual"))))))
(DTypeSig true "expectLessThan" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectLessThan" ((PVar "expected") (PVar "actual")) (EIf (EApp (EApp (EVar "lt") (EVar "actual")) (EVar "expected")) (EVar "Pass") (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "actual")))) (ELit (LString " < "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "expected")))) (ELit (LString ""))))))
(DTypeSig true "expectGreaterThan" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectGreaterThan" ((PVar "expected") (PVar "actual")) (EIf (EApp (EApp (EVar "gt") (EVar "actual")) (EVar "expected")) (EVar "Pass") (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "actual")))) (ELit (LString " > "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "expected")))) (ELit (LString ""))))))
(DTypeSig false "expectAllStep" (TyFun (TyCon "Expectation") (TyFun (TyCon "Expectation") (TyCon "Expectation"))))
(DFunDef false "expectAllStep" ((PCon "Fail" (PVar "msg")) PWild) (EApp (EVar "Fail") (EVar "msg")))
(DFunDef false "expectAllStep" ((PCon "Pass") (PVar "e")) (EVar "e"))
(DTypeSig true "expectAll" (TyFun (TyApp (TyCon "List") (TyCon "Expectation")) (TyCon "Expectation")))
(DFunDef false "expectAll" ((PVar "es")) (EApp (EApp (EApp (EVar "fold") (EVar "expectAllStep")) (EVar "Pass")) (EVar "es")))
(DTypeSig false "goTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Expectation")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "goTests" ((PList) (PVar "passed") (PVar "failed")) (EBlock (DoExpr (EApp (EVar "println") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "passed")))) (ELit (LString " passed, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "failed")))) (ELit (LString " failed"))))) (DoExpr (EApp (EApp (EVar "eq") (EVar "failed")) (ELit (LInt 0))))))
(DFunDef false "goTests" ((PCons (PTuple (PVar "name") (PVar "thunk")) (PVar "rest")) (PVar "passed") (PVar "failed")) (EMatch (EApp (EVar "thunk") (ELit LUnit)) (arm (PCon "Pass") () (EBlock (DoExpr (EApp (EVar "println") (EBinOp "++" (ELit (LString "  ok   ")) (EVar "name")))) (DoExpr (EApp (EApp (EApp (EVar "goTests") (EVar "rest")) (EBinOp "+" (EVar "passed") (ELit (LInt 1)))) (EVar "failed"))))) (arm (PCon "Fail" (PVar "msg")) () (EBlock (DoExpr (EApp (EVar "println") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EVar "goTests") (EVar "rest")) (EVar "passed")) (EBinOp "+" (EVar "failed") (ELit (LInt 1)))))))))
(DTypeSig true "runTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Expectation")))) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "runTests" ((PVar "tests")) (EApp (EApp (EApp (EVar "goTests") (EVar "tests")) (ELit (LInt 0))) (ELit (LInt 0))))
# MARK
(DData Public "Expectation" () ((variant "Pass" (ConPos)) (variant "Fail" (ConPos (TyCon "String")))) ())
(DImpl true "Debug" ((TyCon "Expectation")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Pass") () (ELit (LString "Pass"))) (arm (PCon "Fail" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Fail ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DTypeSig true "pass" (TyCon "Expectation"))
(DFunDef false "pass" () (EVar "Pass"))
(DTypeSig true "fail" (TyFun (TyCon "String") (TyCon "Expectation")))
(DFunDef false "fail" ((PVar "msg")) (EApp (EVar "Fail") (EVar "msg")))
(DTypeSig true "expectTrue" (TyFun (TyCon "Bool") (TyCon "Expectation")))
(DFunDef false "expectTrue" ((PCon "True")) (EVar "Pass"))
(DFunDef false "expectTrue" ((PCon "False")) (EApp (EVar "Fail") (ELit (LString "expected True but got False"))))
(DTypeSig true "expectFalse" (TyFun (TyCon "Bool") (TyCon "Expectation")))
(DFunDef false "expectFalse" ((PCon "False")) (EVar "Pass"))
(DFunDef false "expectFalse" ((PCon "True")) (EApp (EVar "Fail") (ELit (LString "expected False but got True"))))
(DTypeSig true "expectEqual" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectEqual" ((PVar "expected") (PVar "actual")) (EIf (EApp (EApp (EMethodRef "eq") (EVar "expected")) (EVar "actual")) (EVar "Pass") (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "expected")))) (ELit (LString " but got "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "actual")))) (ELit (LString ""))))))
(DTypeSig true "expectNotEqual" (TyConstrained ((cstr "Eq" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectNotEqual" ((PVar "expected") (PVar "actual")) (EIf (EApp (EApp (EDictApp "neq") (EVar "expected")) (EVar "actual")) (EVar "Pass") (EApp (EVar "Fail") (EBinOp "++" (ELit (LString "expected values to differ but both were ")) (EApp (EMethodRef "debug") (EVar "actual"))))))
(DTypeSig true "expectLessThan" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectLessThan" ((PVar "expected") (PVar "actual")) (EIf (EApp (EApp (EMethodRef "lt") (EVar "actual")) (EVar "expected")) (EVar "Pass") (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "actual")))) (ELit (LString " < "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "expected")))) (ELit (LString ""))))))
(DTypeSig true "expectGreaterThan" (TyConstrained ((cstr "Ord" (TyVar "a")) (cstr "Debug" (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyVar "a") (TyCon "Expectation")))))
(DFunDef false "expectGreaterThan" ((PVar "expected") (PVar "actual")) (EIf (EApp (EApp (EMethodRef "gt") (EVar "actual")) (EVar "expected")) (EVar "Pass") (EApp (EVar "Fail") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "actual")))) (ELit (LString " > "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "expected")))) (ELit (LString ""))))))
(DTypeSig false "expectAllStep" (TyFun (TyCon "Expectation") (TyFun (TyCon "Expectation") (TyCon "Expectation"))))
(DFunDef false "expectAllStep" ((PCon "Fail" (PVar "msg")) PWild) (EApp (EVar "Fail") (EVar "msg")))
(DFunDef false "expectAllStep" ((PCon "Pass") (PVar "e")) (EVar "e"))
(DTypeSig true "expectAll" (TyFun (TyApp (TyCon "List") (TyCon "Expectation")) (TyCon "Expectation")))
(DFunDef false "expectAll" ((PVar "es")) (EApp (EApp (EApp (EMethodRef "fold") (EVar "expectAllStep")) (EVar "Pass")) (EVar "es")))
(DTypeSig false "goTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Expectation")))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Bool"))))))
(DFunDef false "goTests" ((PList) (PVar "passed") (PVar "failed")) (EBlock (DoExpr (EApp (EDictApp "println") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "passed")))) (ELit (LString " passed, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "failed")))) (ELit (LString " failed"))))) (DoExpr (EApp (EApp (EMethodRef "eq") (EVar "failed")) (ELit (LInt 0))))))
(DFunDef false "goTests" ((PCons (PTuple (PVar "name") (PVar "thunk")) (PVar "rest")) (PVar "passed") (PVar "failed")) (EMatch (EApp (EVar "thunk") (ELit LUnit)) (arm (PCon "Pass") () (EBlock (DoExpr (EApp (EDictApp "println") (EBinOp "++" (ELit (LString "  ok   ")) (EVar "name")))) (DoExpr (EApp (EApp (EApp (EVar "goTests") (EVar "rest")) (EBinOp "+" (EVar "passed") (ELit (LInt 1)))) (EVar "failed"))))) (arm (PCon "Fail" (PVar "msg")) () (EBlock (DoExpr (EApp (EDictApp "println") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  FAIL ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))) (DoExpr (EApp (EApp (EApp (EVar "goTests") (EVar "rest")) (EVar "passed")) (EBinOp "+" (EVar "failed") (ELit (LInt 1)))))))))
(DTypeSig true "runTests" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Expectation")))) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "runTests" ((PVar "tests")) (EApp (EApp (EApp (EVar "goTests") (EVar "tests")) (ELit (LInt 0))) (ELit (LInt 0))))
