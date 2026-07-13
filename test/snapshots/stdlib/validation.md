# META
source_lines=135
stages=DESUGAR,MARK
# SOURCE
{- validation.mdk — an accumulating-error applicative.

   `Validation e a` is shaped exactly like `Result e a` (`Failure`/`Success`
   instead of `Err`/`Ok`) but its `Applicative` has different semantics:
   `Result`'s `ap` short-circuits on the first `Err`, while `Validation`'s
   `ap` COMBINES both sides' errors via `Semigroup e` when both are
   `Failure`. This is the standard shape used to validate several
   independent fields of a record and report every problem at once, rather
   than just the first one.

   Deliberately NO `impl Thenable Validation`. A monadic `andThen` must
   short-circuit — the second computation only runs (and so its error only
   exists) once the first succeeds — which is exactly the opposite of the
   accumulating `Applicative` above. Offering both on the same type would
   be incoherent (two "correct" answers for combining two failures depend
   on which interface a caller happens to reach for). Haskell's
   `validation` package, PureScript, and Scala/cats' `Validated` all make
   this same call: accumulate via `Applicative`, and if you need
   short-circuiting sequencing, convert to `Result` (`validationToResult`) first. -}

import core.{
  Result,
  Ok,
  Err,
  Mappable,
  Applicative,
  Semigroup,
  Eq,
  Debug,
  Display,
  Foldable,
  Traversable,
}

{- | Validation's own `Failure`/`Success` — same shape as `Result`'s
   `Err`/`Ok`, distinguished by name so its different `Applicative` reads
   as intentional rather than a `Result` look-alike bug.

   > validationToResult (Success 1)
   Ok 1
   > validationToResult (Failure "bad")
   Err "bad" -}
public export data Validation e a = Failure e | Success a

export impl Mappable (Validation e) where
  map f (Success a) = Success (f a)
  map _ (Failure e) = Failure e

{- | The accumulating `Applicative`. `pure` lifts into `Success`; `ap`
   combines two `Failure`s with `Semigroup e`'s `++` instead of keeping only
   the first, so validating several fields collects every error.

   > validationToResult (ap (Failure ["bad name"] : Validation (List String) (Int -> Int)) (Failure ["bad age"] : Validation (List String) Int))
   Err ["bad name", "bad age"]
   > validationToResult (ap (Failure ["bad name"] : Validation (List String) (Int -> Int)) (Success 5 : Validation (List String) Int))
   Err ["bad name"]
   > validationToResult (ap (pure (n => n + 1) : Validation (List String) (Int -> Int)) (Success 5 : Validation (List String) Int))
   Ok 6 -}
export impl Applicative (Validation e) requires Semigroup e where
  pure a = Success a
  ap (Failure e1) (Failure e2) = Failure (e1 ++ e2)
  ap (Failure e) _ = Failure e
  ap (Success f) v = map f v

export impl Foldable (Validation e) where
  fold _ acc (Failure _) = acc
  fold f acc (Success x) = f acc x
  foldRight _ acc (Failure _) = acc
  foldRight f acc (Success x) = f x acc
  toList (Failure _) = []
  toList (Success x) = [x]

-- Multi-clause + return-position `pure` loops in eval for Thenable impls;
-- see the note above core.mdk's Traversable impls — do not split.
-- lint-disable-next-line rule-match-on-param
export impl Traversable (Validation e) where
  traverse f v = match v
    Failure e => pure (Failure e)
    Success x => map Success (f x)

export impl Eq (Validation e a) requires Eq e, Eq a where
  eq (Failure x) (Failure y) = eq x y
  eq (Success x) (Success y) = eq x y
  eq _ _ = False

export impl Debug (Validation e a) requires Debug e, Debug a where
  debug (Failure e) = "Failure " ++ debug e
  debug (Success a) = "Success " ++ debug a

{- | Human-facing rendering (backs `println` and `\{}` interpolation), mirroring
   core's `Display (Result e a)`.

   > display (Success 7)
   "Success 7"
   > display (Failure "bad")
   "Failure bad" -}
export impl Display (Validation e a) requires Display e, Display a where
  display (Failure e) = "Failure " ++ display e
  display (Success a) = "Success " ++ display a

{- | Drop down to the short-circuiting `Result` (e.g. to `andThen`-sequence
   once you no longer need to accumulate).

   > validationToResult (Success 1)
   Ok 1 -}
export validationToResult : Validation e a -> Result e a
validationToResult (Success a) = Ok a
validationToResult (Failure e) = Err e

{- | Lift a `Result` into `Validation` (e.g. to combine it with others via
   the accumulating `Applicative`).

   > resultToValidation (Ok 1 : Result String Int)
   Success 1
   > resultToValidation (Err "bad" : Result String Int)
   Failure "bad" -}
export resultToValidation : Result e a -> Validation e a
resultToValidation (Ok a) = Success a
resultToValidation (Err e) = Failure e

-- ─── Property tests ─────────────────────────────────────────────────────

prop "validationToResult/resultToValidation round-trip on Success" (n : Int) =
  validationToResult (resultToValidation (Ok n : Result Int Int)) ==
    (Ok n : Result Int Int)

prop "validationToResult/resultToValidation round-trip on Failure" (n : Int) =
  validationToResult (resultToValidation (Err n : Result Int Int)) ==
    (Err n : Result Int Int)

prop "map identity is identity on Success" (n : Int) =
  map identity (Success n : Validation Int Int) == Success n

prop "map identity is identity on Failure" (n : Int) =
  map identity (Failure n : Validation Int Int) == Failure n
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Result" false) (mem "Ok" false) (mem "Err" false) (mem "Mappable" false) (mem "Applicative" false) (mem "Semigroup" false) (mem "Eq" false) (mem "Debug" false) (mem "Display" false) (mem "Foldable" false) (mem "Traversable" false))))
(DData Public "Validation" ("e" "a") ((variant "Failure" (ConPos (TyVar "e"))) (variant "Success" (ConPos (TyVar "a")))) ())
(DImpl true "Mappable" ((TyApp (TyCon "Validation") (TyVar "e"))) () ((im "map" ((PVar "f") (PCon "Success" (PVar "a"))) (EApp (EVar "Success") (EApp (EVar "f") (EVar "a")))) (im "map" (PWild (PCon "Failure" (PVar "e"))) (EApp (EVar "Failure") (EVar "e")))))
(DImpl true "Applicative" ((TyApp (TyCon "Validation") (TyVar "e"))) ((req "Semigroup" ((TyVar "e")))) ((im "pure" ((PVar "a")) (EApp (EVar "Success") (EVar "a"))) (im "ap" ((PCon "Failure" (PVar "e1")) (PCon "Failure" (PVar "e2"))) (EApp (EVar "Failure") (EBinOp "++" (EVar "e1") (EVar "e2")))) (im "ap" ((PCon "Failure" (PVar "e")) PWild) (EApp (EVar "Failure") (EVar "e"))) (im "ap" ((PCon "Success" (PVar "f")) (PVar "v")) (EApp (EApp (EVar "map") (EVar "f")) (EVar "v")))))
(DImpl true "Foldable" ((TyApp (TyCon "Validation") (TyVar "e"))) () ((im "fold" (PWild (PVar "acc") (PCon "Failure" PWild)) (EVar "acc")) (im "fold" ((PVar "f") (PVar "acc") (PCon "Success" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "x"))) (im "foldRight" (PWild (PVar "acc") (PCon "Failure" PWild)) (EVar "acc")) (im "foldRight" ((PVar "f") (PVar "acc") (PCon "Success" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "x")) (EVar "acc"))) (im "toList" ((PCon "Failure" PWild)) (EListLit)) (im "toList" ((PCon "Success" (PVar "x"))) (EListLit (EVar "x")))))
(DImpl true "Traversable" ((TyApp (TyCon "Validation") (TyVar "e"))) () ((im "traverse" ((PVar "f") (PVar "v")) (EMatch (EVar "v") (arm (PCon "Failure" (PVar "e")) () (EApp (EVar "pure") (EApp (EVar "Failure") (EVar "e")))) (arm (PCon "Success" (PVar "x")) () (EApp (EApp (EVar "map") (EVar "Success")) (EApp (EVar "f") (EVar "x"))))))))
(DImpl true "Eq" ((TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))) ((req "Eq" ((TyVar "e"))) (req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "Failure" (PVar "x")) (PCon "Failure" (PVar "y"))) (EApp (EApp (EVar "eq") (EVar "x")) (EVar "y"))) (im "eq" ((PCon "Success" (PVar "x")) (PCon "Success" (PVar "y"))) (EApp (EApp (EVar "eq") (EVar "x")) (EVar "y"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl true "Debug" ((TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))) ((req "Debug" ((TyVar "e"))) (req "Debug" ((TyVar "a")))) ((im "debug" ((PCon "Failure" (PVar "e"))) (EBinOp "++" (ELit (LString "Failure ")) (EApp (EVar "debug") (EVar "e")))) (im "debug" ((PCon "Success" (PVar "a"))) (EBinOp "++" (ELit (LString "Success ")) (EApp (EVar "debug") (EVar "a"))))))
(DImpl true "Display" ((TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))) ((req "Display" ((TyVar "e"))) (req "Display" ((TyVar "a")))) ((im "display" ((PCon "Failure" (PVar "e"))) (EBinOp "++" (ELit (LString "Failure ")) (EApp (EVar "display") (EVar "e")))) (im "display" ((PCon "Success" (PVar "a"))) (EBinOp "++" (ELit (LString "Success ")) (EApp (EVar "display") (EVar "a"))))))
(DTypeSig true "validationToResult" (TyFun (TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))))
(DFunDef false "validationToResult" ((PCon "Success" (PVar "a"))) (EApp (EVar "Ok") (EVar "a")))
(DFunDef false "validationToResult" ((PCon "Failure" (PVar "e"))) (EApp (EVar "Err") (EVar "e")))
(DTypeSig true "resultToValidation" (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))))
(DFunDef false "resultToValidation" ((PCon "Ok" (PVar "a"))) (EApp (EVar "Success") (EVar "a")))
(DFunDef false "resultToValidation" ((PCon "Err" (PVar "e"))) (EApp (EVar "Failure") (EVar "e")))
(DProp false "validationToResult/resultToValidation round-trip on Success" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "validationToResult") (EApp (EVar "resultToValidation") (EAnnot (EApp (EVar "Ok") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int"))))) (EAnnot (EApp (EVar "Ok") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int")))))
(DProp false "validationToResult/resultToValidation round-trip on Failure" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "validationToResult") (EApp (EVar "resultToValidation") (EAnnot (EApp (EVar "Err") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int"))))) (EAnnot (EApp (EVar "Err") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int")))))
(DProp false "map identity is identity on Success" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "map") (EVar "identity")) (EAnnot (EApp (EVar "Success") (EVar "n")) (TyApp (TyApp (TyCon "Validation") (TyCon "Int")) (TyCon "Int")))) (EApp (EVar "Success") (EVar "n"))))
(DProp false "map identity is identity on Failure" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EVar "map") (EVar "identity")) (EAnnot (EApp (EVar "Failure") (EVar "n")) (TyApp (TyApp (TyCon "Validation") (TyCon "Int")) (TyCon "Int")))) (EApp (EVar "Failure") (EVar "n"))))
# MARK
(DUse false (UseGroup ("core") ((mem "Result" false) (mem "Ok" false) (mem "Err" false) (mem "Mappable" false) (mem "Applicative" false) (mem "Semigroup" false) (mem "Eq" false) (mem "Debug" false) (mem "Display" false) (mem "Foldable" false) (mem "Traversable" false))))
(DData Public "Validation" ("e" "a") ((variant "Failure" (ConPos (TyVar "e"))) (variant "Success" (ConPos (TyVar "a")))) ())
(DImpl true "Mappable" ((TyApp (TyCon "Validation") (TyVar "e"))) () ((im "map" ((PVar "f") (PCon "Success" (PVar "a"))) (EApp (EVar "Success") (EApp (EVar "f") (EVar "a")))) (im "map" (PWild (PCon "Failure" (PVar "e"))) (EApp (EVar "Failure") (EVar "e")))))
(DImpl true "Applicative" ((TyApp (TyCon "Validation") (TyVar "e"))) ((req "Semigroup" ((TyVar "e")))) ((im "pure" ((PVar "a")) (EApp (EVar "Success") (EVar "a"))) (im "ap" ((PCon "Failure" (PVar "e1")) (PCon "Failure" (PVar "e2"))) (EApp (EVar "Failure") (EBinOp "++" (EVar "e1") (EVar "e2")))) (im "ap" ((PCon "Failure" (PVar "e")) PWild) (EApp (EVar "Failure") (EVar "e"))) (im "ap" ((PCon "Success" (PVar "f")) (PVar "v")) (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "v")))))
(DImpl true "Foldable" ((TyApp (TyCon "Validation") (TyVar "e"))) () ((im "fold" (PWild (PVar "acc") (PCon "Failure" PWild)) (EVar "acc")) (im "fold" ((PVar "f") (PVar "acc") (PCon "Success" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "x"))) (im "foldRight" (PWild (PVar "acc") (PCon "Failure" PWild)) (EVar "acc")) (im "foldRight" ((PVar "f") (PVar "acc") (PCon "Success" (PVar "x"))) (EApp (EApp (EVar "f") (EVar "x")) (EVar "acc"))) (im "toList" ((PCon "Failure" PWild)) (EListLit)) (im "toList" ((PCon "Success" (PVar "x"))) (EListLit (EVar "x")))))
(DImpl true "Traversable" ((TyApp (TyCon "Validation") (TyVar "e"))) () ((im "traverse" ((PVar "f") (PVar "v")) (EMatch (EVar "v") (arm (PCon "Failure" (PVar "e")) () (EApp (EMethodRef "pure") (EApp (EVar "Failure") (EVar "e")))) (arm (PCon "Success" (PVar "x")) () (EApp (EApp (EMethodRef "map") (EVar "Success")) (EApp (EVar "f") (EVar "x"))))))))
(DImpl true "Eq" ((TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))) ((req "Eq" ((TyVar "e"))) (req "Eq" ((TyVar "a")))) ((im "eq" ((PCon "Failure" (PVar "x")) (PCon "Failure" (PVar "y"))) (EApp (EApp (EMethodRef "eq") (EVar "x")) (EVar "y"))) (im "eq" ((PCon "Success" (PVar "x")) (PCon "Success" (PVar "y"))) (EApp (EApp (EMethodRef "eq") (EVar "x")) (EVar "y"))) (im "eq" (PWild PWild) (EVar "False"))))
(DImpl true "Debug" ((TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))) ((req "Debug" ((TyVar "e"))) (req "Debug" ((TyVar "a")))) ((im "debug" ((PCon "Failure" (PVar "e"))) (EBinOp "++" (ELit (LString "Failure ")) (EApp (EMethodRef "debug") (EVar "e")))) (im "debug" ((PCon "Success" (PVar "a"))) (EBinOp "++" (ELit (LString "Success ")) (EApp (EMethodRef "debug") (EVar "a"))))))
(DImpl true "Display" ((TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))) ((req "Display" ((TyVar "e"))) (req "Display" ((TyVar "a")))) ((im "display" ((PCon "Failure" (PVar "e"))) (EBinOp "++" (ELit (LString "Failure ")) (EApp (EMethodRef "display") (EVar "e")))) (im "display" ((PCon "Success" (PVar "a"))) (EBinOp "++" (ELit (LString "Success ")) (EApp (EMethodRef "display") (EVar "a"))))))
(DTypeSig true "validationToResult" (TyFun (TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a"))))
(DFunDef false "validationToResult" ((PCon "Success" (PVar "a"))) (EApp (EVar "Ok") (EVar "a")))
(DFunDef false "validationToResult" ((PCon "Failure" (PVar "e"))) (EApp (EVar "Err") (EVar "e")))
(DTypeSig true "resultToValidation" (TyFun (TyApp (TyApp (TyCon "Result") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyCon "Validation") (TyVar "e")) (TyVar "a"))))
(DFunDef false "resultToValidation" ((PCon "Ok" (PVar "a"))) (EApp (EVar "Success") (EVar "a")))
(DFunDef false "resultToValidation" ((PCon "Err" (PVar "e"))) (EApp (EVar "Failure") (EVar "e")))
(DProp false "validationToResult/resultToValidation round-trip on Success" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "validationToResult") (EApp (EVar "resultToValidation") (EAnnot (EApp (EVar "Ok") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int"))))) (EAnnot (EApp (EVar "Ok") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int")))))
(DProp false "validationToResult/resultToValidation round-trip on Failure" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "validationToResult") (EApp (EVar "resultToValidation") (EAnnot (EApp (EVar "Err") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int"))))) (EAnnot (EApp (EVar "Err") (EVar "n")) (TyApp (TyApp (TyCon "Result") (TyCon "Int")) (TyCon "Int")))))
(DProp false "map identity is identity on Success" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EMethodRef "map") (EVar "identity")) (EAnnot (EApp (EVar "Success") (EVar "n")) (TyApp (TyApp (TyCon "Validation") (TyCon "Int")) (TyCon "Int")))) (EApp (EVar "Success") (EVar "n"))))
(DProp false "map identity is identity on Failure" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EApp (EMethodRef "map") (EVar "identity")) (EAnnot (EApp (EVar "Failure") (EVar "n")) (TyApp (TyApp (TyCon "Validation") (TyCon "Int")) (TyCon "Int")))) (EApp (EVar "Failure") (EVar "n"))))
