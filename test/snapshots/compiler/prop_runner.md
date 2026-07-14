# META
source_lines=368
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted property-test runner — port of lib/prop_runner.ml.
--
-- For each `prop "name" (x : T) (y : U) … = body` declaration: generate random
-- inputs for each parameter (structurally, from the type), evaluate the body in
-- an environment extended with those bindings, and check it returns True for
-- max_tests draws.  On the first failing draw, greedily shrink the
-- counterexample and report it.
--
-- The RNG lives in eval.mdk's externs (`randomInt`/…), a self-contained LCG
-- (NOT the reference's SplitMix64 nor OCaml's `Random`); a PASSING prop's output
-- (`OK (100 tests)`) is RNG-independent, so it matches `medaka test`.  A FAILING
-- prop's shrunk counterexample is RNG-dependent and diverges across all three
-- runners — see the report in test/diff_compiler_test.sh.

import frontend.ast.{
  Decl,
  Expr,
  DProp,
  DData,
  DNewtype,
  PropParam,
  Ty(..),
  Variant(..),
  Field(..),
  ConPayload(..),
}
import eval.eval.{
  Value(..),
  EvalEnv(..),
  eval,
  extendEnv,
  force,
  ppValue,
  rngStateRef,
}
import support.util.{listLen, lookupAssoc, reverseL, isEmptyL, filterList, zipL}

-- ── RNG wrappers (call the eval externs through tiny Medaka shims) ───────────
-- The externs are bound by name in the eval frame, but prop_runner runs OUTSIDE
-- the evaluated program — so we re-implement the same LCG draws here over the
-- shared `rngStateRef`, keeping generation in this module rather than threading
-- an eval env through every generator.

rngNextLocal : Unit -> Int
-- Intentional cross-file duplicate of the same helper in eval.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
rngNextLocal _ =
  let s = (rngStateRef.value * 1103515245 + 12345) % 2147483648
  let _ = setRef rngStateRef s
  s

randIntRange : Int -> Int -> Int
randIntRange lo hi =
  let range = hi - lo + 1
  if range <= 0 then lo else lo + rngNextLocal () % range

randBoolL : Unit -> Bool
randBoolL _ = rngNextLocal () % 2 == 1

-- ── tydef registry (built from the program's data/record decls) ─────────────

public export data TyDef = TDData (List String) (List Variant)

buildTyDefs : List Decl -> List (String, TyDef)
buildTyDefs [] = []
buildTyDefs (d::rest) = match d
  DData _ name params variants _ =>
    (name, TDData params variants) :: buildTyDefs rest
  DNewtype _ name params con fty _ =>
    (name, TDData params [Variant con (ConPos [fty])]) :: buildTyDefs rest
  _ => buildTyDefs rest

-- ── type substitution + spine peeling (mirror lib/prop_runner.ml) ────────────

substTy : List (String, Ty) -> Ty -> Ty
substTy subst (TyVar v) = match lookupAssoc v subst
  Some t => t
  None => TyVar v
substTy subst (TyApp a b) = TyApp (substTy subst a) (substTy subst b)
substTy subst (TyTuple ts) = TyTuple (map (substTy subst) ts)
substTy subst (TyFun a b) = TyFun (substTy subst a) (substTy subst b)
substTy _ t = t

-- Peel a TyApp spine: `Pair a b` → Some ("Pair", [a, b]); `Int` → Some ("Int", []).
tySpine : Ty -> Option (String, List Ty)
tySpine t = tySpineGo [] t

tySpineGo : List Ty -> Ty -> Option (String, List Ty)
tySpineGo acc (TyApp f a) = tySpineGo (a::acc) f
tySpineGo acc (TyCon n _) = Some (n, acc)
tySpineGo _ _ = None

-- ── value generation ─────────────────────────────────────────────────────────

genForType : List (String, TyDef) -> List (String, Ty) -> Ty -> <e> Value e
genForType tydefs subst (TyVar v) = match lookupAssoc v subst
  Some t => genForType tydefs subst t
  None => panic ("prop_runner: cannot generate values for unbound type variable '" ++ v ++ "'")
genForType tydefs subst (TyCon "Int" _) = VInt (randIntRange (-1000) 1000)
genForType tydefs subst (TyCon "Bool" _) = VBool (randBoolL ())
genForType tydefs subst (TyCon "Float" _) = genFloat ()
genForType tydefs subst (TyCon "Char" _) = VChar (genCharStr ())
genForType tydefs subst (TyCon "String" _) = VString (genString ())
genForType tydefs subst (TyCon "Unit" _) = VUnit
genForType tydefs subst (TyApp (TyCon "List" _) t) =
  VList (genList tydefs subst t (randIntRange 0 7))
genForType tydefs subst (TyApp (TyCon "Array" _) t) =
  VArray (arrayFromList (genList tydefs subst t (randIntRange 0 7)))
genForType tydefs subst (TyApp (TyCon "Option" _) t) =
  if randBoolL () then
    VCon "None" []
  else
    VCon "Some" [genForType tydefs subst t]
genForType tydefs subst (TyApp (TyApp (TyCon "Result" _) e) a) =
  if randBoolL () then
    VCon "Ok" [genForType tydefs subst a]
  else
    VCon "Err" [genForType tydefs subst e]
genForType tydefs subst (TyTuple ts) = VTuple (genTuple tydefs subst ts)
genForType tydefs subst ty = genUserOrFail tydefs subst ty

genTuple : List (String, TyDef) -> List (String, Ty) -> List Ty -> <e> List (Value e)
genTuple _ _ [] = []
genTuple tydefs subst (t::rest) =
  genForType tydefs subst t :: genTuple tydefs subst rest

genList : List (String, TyDef) -> List (String, Ty) -> Ty -> Int -> <e> List (Value e)
genList _ _ _ 0 = []
genList tydefs subst t n =
  genForType tydefs subst t :: genList tydefs subst t (n - 1)

genFloat : Unit -> <e> Value e
genFloat _ =
  let r = rngNextLocal () % 2000001
  VFloat (intToFloat r * (1.0 / 1000000.0) - 1.0)

genCharStr : Unit -> String
genCharStr _ = charToStr (charFromCodeU (32 + rngNextLocal () % 95))

charFromCodeU : Int -> Char
-- Intentional cross-file duplicate of the same helper in eval.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
charFromCodeU n = match charFromCode n
  Some c => c
  None => ' '

-- random String of printable ASCII, length 0..10
genString : Unit -> String
genString _ = stringConcat (genStringGo (randIntRange 0 10))

genStringGo : Int -> List String
genStringGo 0 = []
genStringGo n = genCharStr () :: genStringGo (n - 1)

genUserOrFail : List (String, TyDef) -> List (String, Ty) -> Ty -> <e> Value e
genUserOrFail tydefs subst ty = match tySpine ty
  Some (name, args) => match lookupAssoc name tydefs
    Some tydef => genUser tydefs subst name tydef args
    None => panic ("prop_runner: no Arbitrary instance for type '" ++ name ++ "'. Add 'deriving (Arbitrary)' or an explicit impl.")
  None => panic "prop_runner: cannot generate values for type"

genUser : List (String, TyDef) -> List (String, Ty) -> String -> TyDef -> List Ty -> <e> Value e
genUser tydefs subst name tydef args =
  let args2 = map (substTy subst) args
  match tydef
    TDData params variants =>
      let subst2 = if listLen params == listLen args2 then
        zipL params args2
      else
        []
      let v = nthList variants (randIntRange 0 (listLen variants - 1))
      genVariant tydefs subst2 v

genVariant : List (String, TyDef) -> List (String, Ty) -> Variant -> <e> Value e
genVariant tydefs subst (Variant cname payload) = match payload
  ConPos tys => VCon cname (map (genForType tydefs subst) tys)
  ConNamed fields _ => VCon cname (map (genFieldTy tydefs subst) fields)

genFieldTy : List (String, TyDef) -> List (String, Ty) -> Field -> <e> Value e
genFieldTy tydefs subst (Field _ fty) = genForType tydefs subst fty

nthList : List a -> Int -> a
nthList (x::_) 0 = x
nthList (_::xs) n = nthList xs (n - 1)
nthList [] _ = panic "nthList: index out of range"

-- ── shrinking (native; mirror lib/prop_runner.ml shrink_native) ──────────────

shrinkValue : Ty -> Value e -> List (Value e)
shrinkValue ty v = match (ty, v)
  (TyCon "Int" _, VInt n) => shrinkInt n
  (TyCon "Bool" _, VBool True) => [VBool False]
  (TyCon "Bool" _, VBool False) => []
  (TyCon "Float" _, VFloat x) =>
    if x == 0.0 then
      []
    else
      [VFloat 0.0, VFloat (x / 2.0)]
  (TyCon "String" _, VString s) =>
    if s == "" then
      []
    else
      [VString (stringSlice 0 (stringLength s / 2) s)]
  (TyApp (TyCon "List" _) _, VList []) => []
  (TyApp (TyCon "List" _) _, VList (_::rest)) => [VList rest]
  (TyApp (TyCon "Option" _) _, VCon "None" []) => []
  (TyApp (TyCon "Option" _) _, VCon "Some" _) => [VCon "None" []]
  _ => []

shrinkInt : Int -> List (Value e)
shrinkInt n =
  let cands = [0, n / 2, n + (if n > 0 then -1 else 1)]
  map VInt (filterList (!= n) cands)

-- ── prop evaluation ──────────────────────────────────────────────────────────
-- evalEnv is the program's binding environment (List (String, Value)); each
-- prop body is evaluated in a frame extending it with the generated inputs.

checkProp : List (String, Value e) -> Expr -> List (String, Value e) -> <e> Bool
checkProp evalEnv body inputs =
  let env = extendEnv (EvalEnv [[]]) (inputs ++ evalEnv)
  match force (eval env body)
    VBool b => b
    _ => False

-- ── one prop run ─────────────────────────────────────────────────────────────

-- parameterized over the value type (v := Value e) — see the kind-inference
-- note on eval.mdk's `Value`
public export data PropOutcome v =
  | PropPassed
  | PropFailed Int (List (String, v))

runProp : List (String, TyDef) -> List (String, Value e) -> Decl -> Int -> <IO> Bool
runProp tydefs evalEnv (DProp _ name params body) maxTests =
  let _ = putStr ("Testing " ++ escStrLocal name ++ " ... ")
  match findFailure tydefs evalEnv params body maxTests 1
    PropPassed =>
      let _ = putStrLn ("OK (" ++ intToString maxTests ++ " tests)")
      True
    PropFailed run shrunk =>
      let _ = putStrLn "FAILED after \{intToString run}\{if run == 1 then " test" else " tests"}"
      let _ = putStrLn "  Counterexample:"
      let _ = printCounterexample shrunk
      False
runProp tydefs evalEnv _ maxTests = True

findFailure : List (String, TyDef) -> List (String, Value e) -> List PropParam -> Expr -> Int -> Int -> <e> PropOutcome (Value e)
findFailure tydefs evalEnv params body maxTests run
  | run > maxTests = PropPassed
  | otherwise =
    let inputs = genInputs tydefs params
    findFailureStep
      tydefs
      evalEnv
      params
      body
      maxTests
      run
      inputs
      (checkProp evalEnv body inputs)

findFailureStep : List (String, TyDef) -> List (String, Value e) -> List PropParam -> Expr -> Int -> Int -> List (String, Value e) -> Bool -> <e> PropOutcome (Value e)
findFailureStep tydefs evalEnv params body maxTests run _ True =
  findFailure tydefs evalEnv params body maxTests (run + 1)
findFailureStep _ evalEnv params body _ run inputs False =
  PropFailed run (shrinkLoop evalEnv params body inputs)

genInputs : List (String, TyDef) -> List PropParam -> <e> List (String, Value e)
genInputs _ [] = []
genInputs tydefs ((PropParam x ty)::rest) =
  (x, genForType tydefs [] ty) :: genInputs tydefs rest

printCounterexample : List (String, Value e) -> <IO> Unit
printCounterexample [] = ()
printCounterexample ((x, v)::rest) =
  let _ = putStrLn "    \{x} = \{ppValue v}"
  printCounterexample rest

escStrLocal : String -> String
escStrLocal s = "\"" ++ s ++ "\""

-- ── greedy shrink (mirror lib/prop_runner.ml shrink_loop) ────────────────────

shrinkLoop : List (String, Value e) -> List PropParam -> Expr -> List (String, Value e) -> <e> List (String, Value e)
shrinkLoop evalEnv params body candidate = match tryShrinkOne evalEnv params body candidate 0
  Some better => shrinkLoop evalEnv params body better
  None => candidate

-- Try each param in order; return the first candidate where some smaller value
-- still fails the prop.
tryShrinkOne : List (String, Value e) -> List PropParam -> Expr -> List (String, Value e) -> Int -> <e> Option (List (String, Value e))
tryShrinkOne evalEnv params body candidate i
  | i >= listLen params = None
  | otherwise =
    let (PropParam x ty) = nthList params i
    let currentV = assocVal x candidate
    let smaller = shrinkValue ty currentV
    match findSmaller evalEnv params body candidate x smaller
      Some better => Some better
      None => tryShrinkOne evalEnv params body candidate (i + 1)

findSmaller : List (String, Value e) -> List PropParam -> Expr -> List (String, Value e) -> String -> List (Value e) -> <e> Option (List (String, Value e))
findSmaller _ _ _ _ _ [] = None
findSmaller evalEnv params body candidate x (sv::rest) =
  let candidate2 = replaceVal x sv candidate
  if checkProp evalEnv body candidate2 then
    findSmaller evalEnv params body candidate x rest
  else
    Some candidate2

assocVal : String -> List (String, Value e) -> Value e
assocVal x kvs = match lookupAssoc x kvs
  Some v => v
  None => panic ("prop shrink: missing binding " ++ x)

replaceVal : String -> Value e -> List (String, Value e) -> List (String, Value e)
replaceVal _ _ [] = []
replaceVal x sv ((k, v)::rest)
  | k == x = (k, sv) :: replaceVal x sv rest
  | otherwise = (k, v) :: replaceVal x sv rest

-- ── run all props in a program ───────────────────────────────────────────────

isProp : Decl -> Bool
isProp (DProp _ _ _ _) = True
isProp _ = False

filterProps : List Decl -> List Decl
filterProps decls = filterDecls isProp decls

filterDecls : (Decl -> Bool) -> List Decl -> List Decl
filterDecls _ [] = []
filterDecls p (d::rest)
  | p d = d :: filterDecls p rest
  | otherwise = filterDecls p rest

-- Run every prop; print the trailing summary; return True iff all passed.
-- Output exactly mirrors lib/prop_runner.ml's run_all (no leading line; one
-- `Testing … OK/FAILED` per prop; a blank line then `N passed, M failed`).
export runAllProps : List (String, Value e) -> List Decl -> <IO> Bool
runAllProps evalEnv program =
  let props = filterProps program
  if isEmptyL props then True
  else
    let tydefs = buildTyDefs program
    let results = runEach tydefs evalEnv props
    let nPass = countTrue results
    let nFail = listLen results - nPass
    let _ = putStrLn "\n\{intToString nPass} passed, \{intToString nFail} failed"
    nFail == 0

runEach : List (String, TyDef) -> List (String, Value e) -> List Decl -> <IO> List Bool
runEach _ _ [] = []
runEach tydefs evalEnv (p::rest) =
  runProp tydefs evalEnv p 100 :: runEach tydefs evalEnv rest

countTrue : List Bool -> Int
countTrue [] = 0
countTrue (True::rest) = 1 + countTrue rest
countTrue (False::rest) = countTrue rest

export hasProps : List Decl -> Bool
hasProps decls = anyDecl isProp decls

anyDecl : (Decl -> Bool) -> List Decl -> Bool
anyDecl _ [] = False
anyDecl p (d::rest) = p d || anyDecl p rest
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Expr" false) (mem "DProp" false) (mem "DData" false) (mem "DNewtype" false) (mem "PropParam" false) (mem "Ty" true) (mem "Variant" true) (mem "Field" true) (mem "ConPayload" true))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "EvalEnv" true) (mem "eval" false) (mem "extendEnv" false) (mem "force" false) (mem "ppValue" false) (mem "rngStateRef" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "filterList" false) (mem "zipL" false))))
(DTypeSig false "rngNextLocal" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "rngNextLocal" (PWild) (EBlock (DoLet false false (PVar "s") (EBinOp "%" (EBinOp "+" (EBinOp "*" (EFieldAccess (EVar "rngStateRef") "value") (ELit (LInt 1103515245))) (ELit (LInt 12345))) (ELit (LInt 2147483648)))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "rngStateRef")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "randIntRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "randIntRange" ((PVar "lo") (PVar "hi")) (EBlock (DoLet false false (PVar "range") (EBinOp "+" (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<=" (EVar "range") (ELit (LInt 0))) (EVar "lo") (EBinOp "+" (EVar "lo") (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (EVar "range")))))))
(DTypeSig false "randBoolL" (TyFun (TyCon "Unit") (TyCon "Bool")))
(DFunDef false "randBoolL" (PWild) (EBinOp "==" (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 2))) (ELit (LInt 1))))
(DData Public "TyDef" () ((variant "TDData" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant"))))) ())
(DTypeSig false "buildTyDefs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef")))))
(DFunDef false "buildTyDefs" ((PList)) (EListLit))
(DFunDef false "buildTyDefs" ((PCons (PVar "d") (PVar "rest"))) (EMatch (EVar "d") (arm (PCon "DData" PWild (PVar "name") (PVar "params") (PVar "variants") PWild) () (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EVar "TDData") (EVar "params")) (EVar "variants"))) (EApp (EVar "buildTyDefs") (EVar "rest")))) (arm (PCon "DNewtype" PWild (PVar "name") (PVar "params") (PVar "con") (PVar "fty") PWild) () (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EVar "TDData") (EVar "params")) (EListLit (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty"))))))) (EApp (EVar "buildTyDefs") (EVar "rest")))) (arm PWild () (EApp (EVar "buildTyDefs") (EVar "rest")))))
(DTypeSig false "substTy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyVar" (PVar "v"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "subst")) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EApp (EVar "TyVar") (EVar "v")))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyApp") (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "b"))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "TyTuple") (EApp (EApp (EVar "map") (EApp (EVar "substTy") (EVar "subst"))) (EVar "ts"))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "b"))))
(DFunDef false "substTy" (PWild (PVar "t")) (EVar "t"))
(DTypeSig false "tySpine" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty"))))))
(DFunDef false "tySpine" ((PVar "t")) (EApp (EApp (EVar "tySpineGo") (EListLit)) (EVar "t")))
(DTypeSig false "tySpineGo" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty")))))))
(DFunDef false "tySpineGo" ((PVar "acc") (PCon "TyApp" (PVar "f") (PVar "a"))) (EApp (EApp (EVar "tySpineGo") (EBinOp "::" (EVar "a") (EVar "acc"))) (EVar "f")))
(DFunDef false "tySpineGo" ((PVar "acc") (PCon "TyCon" (PVar "n") PWild)) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "acc"))))
(DFunDef false "tySpineGo" (PWild PWild) (EVar "None"))
(DTypeSig false "genForType" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyVar" (PVar "v"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "subst")) (arm (PCon "Some" (PVar "t")) () (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "t"))) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "prop_runner: cannot generate values for unbound type variable '")) (EVar "v")) (ELit (LString "'")))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyCon" (PLit (LString "Int")) PWild)) (EApp (EVar "VInt") (EApp (EApp (EVar "randIntRange") (EUnOp "-" (ELit (LInt 1000)))) (ELit (LInt 1000)))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyCon" (PLit (LString "Bool")) PWild)) (EApp (EVar "VBool") (EApp (EVar "randBoolL") (ELit LUnit))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyCon" (PLit (LString "Float")) PWild)) (EApp (EVar "genFloat") (ELit LUnit)))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyCon" (PLit (LString "Char")) PWild)) (EApp (EVar "VChar") (EApp (EVar "genCharStr") (ELit LUnit))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyCon" (PLit (LString "String")) PWild)) (EApp (EVar "VString") (EApp (EVar "genString") (ELit LUnit))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyCon" (PLit (LString "Unit")) PWild)) (EVar "VUnit"))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyApp" (PCon "TyCon" (PLit (LString "List")) PWild) (PVar "t"))) (EApp (EVar "VList") (EApp (EApp (EApp (EApp (EVar "genList") (EVar "tydefs")) (EVar "subst")) (EVar "t")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (ELit (LInt 7))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyApp" (PCon "TyCon" (PLit (LString "Array")) PWild) (PVar "t"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EVar "genList") (EVar "tydefs")) (EVar "subst")) (EVar "t")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (ELit (LInt 7)))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyApp" (PCon "TyCon" (PLit (LString "Option")) PWild) (PVar "t"))) (EIf (EApp (EVar "randBoolL") (ELit LUnit)) (EApp (EApp (EVar "VCon") (ELit (LString "None"))) (EListLit)) (EApp (EApp (EVar "VCon") (ELit (LString "Some"))) (EListLit (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "t"))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyApp" (PCon "TyApp" (PCon "TyCon" (PLit (LString "Result")) PWild) (PVar "e")) (PVar "a"))) (EIf (EApp (EVar "randBoolL") (ELit LUnit)) (EApp (EApp (EVar "VCon") (ELit (LString "Ok"))) (EListLit (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "a")))) (EApp (EApp (EVar "VCon") (ELit (LString "Err"))) (EListLit (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "e"))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "VTuple") (EApp (EApp (EApp (EVar "genTuple") (EVar "tydefs")) (EVar "subst")) (EVar "ts"))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "ty")) (EApp (EApp (EApp (EVar "genUserOrFail") (EVar "tydefs")) (EVar "subst")) (EVar "ty")))
(DTypeSig false "genTuple" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "genTuple" (PWild PWild (PList)) (EListLit))
(DFunDef false "genTuple" ((PVar "tydefs") (PVar "subst") (PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "t")) (EApp (EApp (EApp (EVar "genTuple") (EVar "tydefs")) (EVar "subst")) (EVar "rest"))))
(DTypeSig false "genList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "genList" (PWild PWild PWild (PLit (LInt 0))) (EListLit))
(DFunDef false "genList" ((PVar "tydefs") (PVar "subst") (PVar "t") (PVar "n")) (EBinOp "::" (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "genList") (EVar "tydefs")) (EVar "subst")) (EVar "t")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "genFloat" (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "genFloat" (PWild) (EBlock (DoLet false false (PVar "r") (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 2000001)))) (DoExpr (EApp (EVar "VFloat") (EBinOp "-" (EBinOp "*" (EApp (EVar "intToFloat") (EVar "r")) (EBinOp "/" (ELit (LFloat 1.0)) (ELit (LFloat 1000000.0)))) (ELit (LFloat 1.0)))))))
(DTypeSig false "genCharStr" (TyFun (TyCon "Unit") (TyCon "String")))
(DFunDef false "genCharStr" (PWild) (EApp (EVar "charToStr") (EApp (EVar "charFromCodeU") (EBinOp "+" (ELit (LInt 32)) (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 95)))))))
(DTypeSig false "charFromCodeU" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "charFromCodeU" ((PVar "n")) (EMatch (EApp (EVar "charFromCode") (EVar "n")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (ELit (LChar " ")))))
(DTypeSig false "genString" (TyFun (TyCon "Unit") (TyCon "String")))
(DFunDef false "genString" (PWild) (EApp (EVar "stringConcat") (EApp (EVar "genStringGo") (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (ELit (LInt 10))))))
(DTypeSig false "genStringGo" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "genStringGo" ((PLit (LInt 0))) (EListLit))
(DFunDef false "genStringGo" ((PVar "n")) (EBinOp "::" (EApp (EVar "genCharStr") (ELit LUnit)) (EApp (EVar "genStringGo") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "genUserOrFail" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "genUserOrFail" ((PVar "tydefs") (PVar "subst") (PVar "ty")) (EMatch (EApp (EVar "tySpine") (EVar "ty")) (arm (PCon "Some" (PTuple (PVar "name") (PVar "args"))) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "tydefs")) (arm (PCon "Some" (PVar "tydef")) () (EApp (EApp (EApp (EApp (EApp (EVar "genUser") (EVar "tydefs")) (EVar "subst")) (EVar "name")) (EVar "tydef")) (EVar "args"))) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "prop_runner: no Arbitrary instance for type '")) (EVar "name")) (ELit (LString "'. Add 'deriving (Arbitrary)' or an explicit impl."))))))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "prop_runner: cannot generate values for type"))))))
(DTypeSig false "genUser" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "String") (TyFun (TyCon "TyDef") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "genUser" ((PVar "tydefs") (PVar "subst") (PVar "name") (PVar "tydef") (PVar "args")) (EBlock (DoLet false false (PVar "args2") (EApp (EApp (EVar "map") (EApp (EVar "substTy") (EVar "subst"))) (EVar "args"))) (DoExpr (EMatch (EVar "tydef") (arm (PCon "TDData" (PVar "params") (PVar "variants")) () (EBlock (DoLet false false (PVar "subst2") (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (EApp (EVar "listLen") (EVar "args2"))) (EApp (EApp (EVar "zipL") (EVar "params")) (EVar "args2")) (EListLit))) (DoLet false false (PVar "v") (EApp (EApp (EVar "nthList") (EVar "variants")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "listLen") (EVar "variants")) (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EApp (EVar "genVariant") (EVar "tydefs")) (EVar "subst2")) (EVar "v")))))))))
(DTypeSig false "genVariant" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Variant") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "genVariant" ((PVar "tydefs") (PVar "subst") (PCon "Variant" (PVar "cname") (PVar "payload"))) (EMatch (EVar "payload") (arm (PCon "ConPos" (PVar "tys")) () (EApp (EApp (EVar "VCon") (EVar "cname")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst"))) (EVar "tys")))) (arm (PCon "ConNamed" (PVar "fields") PWild) () (EApp (EApp (EVar "VCon") (EVar "cname")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "genFieldTy") (EVar "tydefs")) (EVar "subst"))) (EVar "fields"))))))
(DTypeSig false "genFieldTy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Field") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "genFieldTy" ((PVar "tydefs") (PVar "subst") (PCon "Field" PWild (PVar "fty"))) (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "fty")))
(DTypeSig false "nthList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyCon "Int") (TyVar "a"))))
(DFunDef false "nthList" ((PCons (PVar "x") PWild) (PLit (LInt 0))) (EVar "x"))
(DFunDef false "nthList" ((PCons PWild (PVar "xs")) (PVar "n")) (EApp (EApp (EVar "nthList") (EVar "xs")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))))
(DFunDef false "nthList" ((PList) PWild) (EApp (EVar "panic") (ELit (LString "nthList: index out of range"))))
(DTypeSig false "shrinkValue" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "shrinkValue" ((PVar "ty") (PVar "v")) (EMatch (ETuple (EVar "ty") (EVar "v")) (arm (PTuple (PCon "TyCon" (PLit (LString "Int")) PWild) (PCon "VInt" (PVar "n"))) () (EApp (EVar "shrinkInt") (EVar "n"))) (arm (PTuple (PCon "TyCon" (PLit (LString "Bool")) PWild) (PCon "VBool" (PCon "True"))) () (EListLit (EApp (EVar "VBool") (EVar "False")))) (arm (PTuple (PCon "TyCon" (PLit (LString "Bool")) PWild) (PCon "VBool" (PCon "False"))) () (EListLit)) (arm (PTuple (PCon "TyCon" (PLit (LString "Float")) PWild) (PCon "VFloat" (PVar "x"))) () (EIf (EBinOp "==" (EVar "x") (ELit (LFloat 0.0))) (EListLit) (EListLit (EApp (EVar "VFloat") (ELit (LFloat 0.0))) (EApp (EVar "VFloat") (EBinOp "/" (EVar "x") (ELit (LFloat 2.0))))))) (arm (PTuple (PCon "TyCon" (PLit (LString "String")) PWild) (PCon "VString" (PVar "s"))) () (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EListLit) (EListLit (EApp (EVar "VString") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "/" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2)))) (EVar "s")))))) (arm (PTuple (PCon "TyApp" (PCon "TyCon" (PLit (LString "List")) PWild) PWild) (PCon "VList" (PList))) () (EListLit)) (arm (PTuple (PCon "TyApp" (PCon "TyCon" (PLit (LString "List")) PWild) PWild) (PCon "VList" (PCons PWild (PVar "rest")))) () (EListLit (EApp (EVar "VList") (EVar "rest")))) (arm (PTuple (PCon "TyApp" (PCon "TyCon" (PLit (LString "Option")) PWild) PWild) (PCon "VCon" (PLit (LString "None")) (PList))) () (EListLit)) (arm (PTuple (PCon "TyApp" (PCon "TyCon" (PLit (LString "Option")) PWild) PWild) (PCon "VCon" (PLit (LString "Some")) PWild)) () (EListLit (EApp (EApp (EVar "VCon") (ELit (LString "None"))) (EListLit)))) (arm PWild () (EListLit))))
(DTypeSig false "shrinkInt" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "shrinkInt" ((PVar "n")) (EBlock (DoLet false false (PVar "cands") (EListLit (ELit (LInt 0)) (EBinOp "/" (EVar "n") (ELit (LInt 2))) (EBinOp "+" (EVar "n") (EIf (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1))) (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EVar "map") (EVar "VInt")) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "!=" (EVar "_s") (EVar "n")))) (EVar "cands"))))))
(DTypeSig false "checkProp" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyCon "Bool"))))))
(DFunDef false "checkProp" ((PVar "evalEnv") (PVar "body") (PVar "inputs")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "extendEnv") (EApp (EVar "EvalEnv") (EListLit (EListLit)))) (EBinOp "++" (EVar "inputs") (EVar "evalEnv")))) (DoExpr (EMatch (EApp (EVar "force") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body"))) (arm (PCon "VBool" (PVar "b")) () (EVar "b")) (arm PWild () (EVar "False"))))))
(DData Public "PropOutcome" ("v") ((variant "PropPassed" (ConPos)) (variant "PropFailed" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "v")))))) ())
(DTypeSig false "runProp" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runProp" ((PVar "tydefs") (PVar "evalEnv") (PCon "DProp" PWild (PVar "name") (PVar "params") (PVar "body")) (PVar "maxTests")) (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (ELit (LString "Testing ")) (EApp (EVar "escStrLocal") (EVar "name"))) (ELit (LString " ... "))))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "tydefs")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (ELit (LInt 1))) (arm (PCon "PropPassed") () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "OK (")) (EApp (EVar "intToString") (EVar "maxTests"))) (ELit (LString " tests)"))))) (DoExpr (EVar "True")))) (arm (PCon "PropFailed" (PVar "run") (PVar "shrunk")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAILED after ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "run")))) (ELit (LString ""))) (EApp (EVar "display") (EIf (EBinOp "==" (EVar "run") (ELit (LInt 1))) (ELit (LString " test")) (ELit (LString " tests"))))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "  Counterexample:")))) (DoLet false false PWild (EApp (EVar "printCounterexample") (EVar "shrunk"))) (DoExpr (EVar "False"))))))))
(DFunDef false "runProp" ((PVar "tydefs") (PVar "evalEnv") PWild (PVar "maxTests")) (EVar "True"))
(DTypeSig false "findFailure" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e")))))))))))
(DFunDef false "findFailure" ((PVar "tydefs") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "maxTests") (PVar "run")) (EIf (EBinOp ">" (EVar "run") (EVar "maxTests")) (EVar "PropPassed") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "inputs") (EApp (EApp (EVar "genInputs") (EVar "tydefs")) (EVar "params"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailureStep") (EVar "tydefs")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (EVar "run")) (EVar "inputs")) (EApp (EApp (EApp (EVar "checkProp") (EVar "evalEnv")) (EVar "body")) (EVar "inputs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findFailureStep" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Bool") (TyEffect () (Some "e") (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e")))))))))))))
(DFunDef false "findFailureStep" ((PVar "tydefs") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "maxTests") (PVar "run") PWild (PCon "True")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "tydefs")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (EBinOp "+" (EVar "run") (ELit (LInt 1)))))
(DFunDef false "findFailureStep" (PWild (PVar "evalEnv") (PVar "params") (PVar "body") PWild (PVar "run") (PVar "inputs") (PCon "False")) (EApp (EApp (EVar "PropFailed") (EVar "run")) (EApp (EApp (EApp (EApp (EVar "shrinkLoop") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "inputs"))))
(DTypeSig false "genInputs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "genInputs" (PWild (PList)) (EListLit))
(DFunDef false "genInputs" ((PVar "tydefs") (PCons (PCon "PropParam" (PVar "x") (PVar "ty")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "x") (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EListLit)) (EVar "ty"))) (EApp (EApp (EVar "genInputs") (EVar "tydefs")) (EVar "rest"))))
(DTypeSig false "printCounterexample" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printCounterexample" ((PList)) (ELit LUnit))
(DFunDef false "printCounterexample" ((PCons (PTuple (PVar "x") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "ppValue") (EVar "v")))) (ELit (LString ""))))) (DoExpr (EApp (EVar "printCounterexample") (EVar "rest")))))
(DTypeSig false "escStrLocal" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escStrLocal" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\""))))
(DTypeSig false "shrinkLoop" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "shrinkLoop" ((PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "tryShrinkOne") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (ELit (LInt 0))) (arm (PCon "Some" (PVar "better")) () (EApp (EApp (EApp (EApp (EVar "shrinkLoop") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "better"))) (arm (PCon "None") () (EVar "candidate"))))
(DTypeSig false "tryShrinkOne" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))))))
(DFunDef false "tryShrinkOne" ((PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "listLen") (EVar "params"))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PCon "PropParam" (PVar "x") (PVar "ty")) (EApp (EApp (EVar "nthList") (EVar "params")) (EVar "i"))) (DoLet false false (PVar "currentV") (EApp (EApp (EVar "assocVal") (EVar "x")) (EVar "candidate"))) (DoLet false false (PVar "smaller") (EApp (EApp (EVar "shrinkValue") (EVar "ty")) (EVar "currentV"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findSmaller") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EVar "x")) (EVar "smaller")) (arm (PCon "Some" (PVar "better")) () (EApp (EVar "Some") (EVar "better"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "tryShrinkOne") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findSmaller" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))))))
(DFunDef false "findSmaller" (PWild PWild PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "findSmaller" ((PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate") (PVar "x") (PCons (PVar "sv") (PVar "rest"))) (EBlock (DoLet false false (PVar "candidate2") (EApp (EApp (EApp (EVar "replaceVal") (EVar "x")) (EVar "sv")) (EVar "candidate"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "checkProp") (EVar "evalEnv")) (EVar "body")) (EVar "candidate2")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findSmaller") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EVar "x")) (EVar "rest")) (EApp (EVar "Some") (EVar "candidate2"))))))
(DTypeSig false "assocVal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "assocVal" ((PVar "x") (PVar "kvs")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "x")) (EVar "kvs")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "prop shrink: missing binding ")) (EVar "x"))))))
(DTypeSig false "replaceVal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "replaceVal" (PWild PWild (PList)) (EListLit))
(DFunDef false "replaceVal" ((PVar "x") (PVar "sv") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "x")) (EBinOp "::" (ETuple (EVar "k") (EVar "sv")) (EApp (EApp (EApp (EVar "replaceVal") (EVar "x")) (EVar "sv")) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EApp (EVar "replaceVal") (EVar "x")) (EVar "sv")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isProp" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isProp" ((PCon "DProp" PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isProp" (PWild) (EVar "False"))
(DTypeSig false "filterProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "filterProps" ((PVar "decls")) (EApp (EApp (EVar "filterDecls") (EVar "isProp")) (EVar "decls")))
(DTypeSig false "filterDecls" (TyFun (TyFun (TyCon "Decl") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "filterDecls" (PWild (PList)) (EListLit))
(DFunDef false "filterDecls" ((PVar "p") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "p") (EVar "d")) (EBinOp "::" (EVar "d") (EApp (EApp (EVar "filterDecls") (EVar "p")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterDecls") (EVar "p")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "runAllProps" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "runAllProps" ((PVar "evalEnv") (PVar "program")) (EBlock (DoLet false false (PVar "props") (EApp (EVar "filterProps") (EVar "program"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "props")) (EVar "True") (EBlock (DoLet false false (PVar "tydefs") (EApp (EVar "buildTyDefs") (EVar "program"))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EVar "runEach") (EVar "tydefs")) (EVar "evalEnv")) (EVar "props"))) (DoLet false false (PVar "nPass") (EApp (EVar "countTrue") (EVar "results"))) (DoLet false false (PVar "nFail") (EBinOp "-" (EApp (EVar "listLen") (EVar "results")) (EVar "nPass"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "nPass")))) (ELit (LString " passed, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "nFail")))) (ELit (LString " failed"))))) (DoExpr (EBinOp "==" (EVar "nFail") (ELit (LInt 0)))))))))
(DTypeSig false "runEach" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Bool")))))))
(DFunDef false "runEach" (PWild PWild (PList)) (EListLit))
(DFunDef false "runEach" ((PVar "tydefs") (PVar "evalEnv") (PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "runProp") (EVar "tydefs")) (EVar "evalEnv")) (EVar "p")) (ELit (LInt 100))) (EApp (EApp (EApp (EVar "runEach") (EVar "tydefs")) (EVar "evalEnv")) (EVar "rest"))))
(DTypeSig false "countTrue" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyCon "Int")))
(DFunDef false "countTrue" ((PList)) (ELit (LInt 0)))
(DFunDef false "countTrue" ((PCons (PCon "True") (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "countTrue") (EVar "rest"))))
(DFunDef false "countTrue" ((PCons (PCon "False") (PVar "rest"))) (EApp (EVar "countTrue") (EVar "rest")))
(DTypeSig true "hasProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasProps" ((PVar "decls")) (EApp (EApp (EVar "anyDecl") (EVar "isProp")) (EVar "decls")))
(DTypeSig false "anyDecl" (TyFun (TyFun (TyCon "Decl") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "anyDecl" (PWild (PList)) (EVar "False"))
(DFunDef false "anyDecl" ((PVar "p") (PCons (PVar "d") (PVar "rest"))) (EBinOp "||" (EApp (EVar "p") (EVar "d")) (EApp (EApp (EVar "anyDecl") (EVar "p")) (EVar "rest"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Expr" false) (mem "DProp" false) (mem "DData" false) (mem "DNewtype" false) (mem "PropParam" false) (mem "Ty" true) (mem "Variant" true) (mem "Field" true) (mem "ConPayload" true))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "EvalEnv" true) (mem "eval" false) (mem "extendEnv" false) (mem "force" false) (mem "ppValue" false) (mem "rngStateRef" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "filterList" false) (mem "zipL" false))))
(DTypeSig false "rngNextLocal" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "rngNextLocal" (PWild) (EBlock (DoLet false false (PVar "s") (EBinOp "%" (EBinOp "+" (EBinOp "*" (EFieldAccess (EVar "rngStateRef") "value") (ELit (LInt 1103515245))) (ELit (LInt 12345))) (ELit (LInt 2147483648)))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "rngStateRef")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "randIntRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "randIntRange" ((PVar "lo") (PVar "hi")) (EBlock (DoLet false false (PVar "range") (EBinOp "+" (EBinOp "-" (EVar "hi") (EVar "lo")) (ELit (LInt 1)))) (DoExpr (EIf (EBinOp "<=" (EVar "range") (ELit (LInt 0))) (EVar "lo") (EBinOp "+" (EVar "lo") (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (EVar "range")))))))
(DTypeSig false "randBoolL" (TyFun (TyCon "Unit") (TyCon "Bool")))
(DFunDef false "randBoolL" (PWild) (EBinOp "==" (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 2))) (ELit (LInt 1))))
(DData Public "TyDef" () ((variant "TDData" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant"))))) ())
(DTypeSig false "buildTyDefs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef")))))
(DFunDef false "buildTyDefs" ((PList)) (EListLit))
(DFunDef false "buildTyDefs" ((PCons (PVar "d") (PVar "rest"))) (EMatch (EVar "d") (arm (PCon "DData" PWild (PVar "name") (PVar "params") (PVar "variants") PWild) () (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EVar "TDData") (EVar "params")) (EVar "variants"))) (EApp (EVar "buildTyDefs") (EVar "rest")))) (arm (PCon "DNewtype" PWild (PVar "name") (PVar "params") (PVar "con") (PVar "fty") PWild) () (EBinOp "::" (ETuple (EVar "name") (EApp (EApp (EVar "TDData") (EVar "params")) (EListLit (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty"))))))) (EApp (EVar "buildTyDefs") (EVar "rest")))) (arm PWild () (EApp (EVar "buildTyDefs") (EVar "rest")))))
(DTypeSig false "substTy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyVar" (PVar "v"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "subst")) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EApp (EVar "TyVar") (EVar "v")))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyApp") (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "b"))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "TyTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "substTy") (EVar "subst"))) (EVar "ts"))))
(DFunDef false "substTy" ((PVar "subst") (PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyFun") (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "a"))) (EApp (EApp (EVar "substTy") (EVar "subst")) (EVar "b"))))
(DFunDef false "substTy" (PWild (PVar "t")) (EVar "t"))
(DTypeSig false "tySpine" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty"))))))
(DFunDef false "tySpine" ((PVar "t")) (EApp (EApp (EVar "tySpineGo") (EListLit)) (EVar "t")))
(DTypeSig false "tySpineGo" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty")))))))
(DFunDef false "tySpineGo" ((PVar "acc") (PCon "TyApp" (PVar "f") (PVar "a"))) (EApp (EApp (EVar "tySpineGo") (EBinOp "::" (EVar "a") (EVar "acc"))) (EVar "f")))
(DFunDef false "tySpineGo" ((PVar "acc") (PCon "TyCon" (PVar "n") PWild)) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "acc"))))
(DFunDef false "tySpineGo" (PWild PWild) (EVar "None"))
(DTypeSig false "genForType" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyVar" (PVar "v"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "subst")) (arm (PCon "Some" (PVar "t")) () (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "t"))) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "prop_runner: cannot generate values for unbound type variable '")) (EVar "v")) (ELit (LString "'")))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyCon" (PLit (LString "Int")) PWild)) (EApp (EVar "VInt") (EApp (EApp (EVar "randIntRange") (EUnOp "-" (ELit (LInt 1000)))) (ELit (LInt 1000)))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyCon" (PLit (LString "Bool")) PWild)) (EApp (EVar "VBool") (EApp (EVar "randBoolL") (ELit LUnit))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyCon" (PLit (LString "Float")) PWild)) (EApp (EVar "genFloat") (ELit LUnit)))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyCon" (PLit (LString "Char")) PWild)) (EApp (EVar "VChar") (EApp (EVar "genCharStr") (ELit LUnit))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyCon" (PLit (LString "String")) PWild)) (EApp (EVar "VString") (EApp (EVar "genString") (ELit LUnit))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyCon" (PLit (LString "Unit")) PWild)) (EVar "VUnit"))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyApp" (PCon "TyCon" (PLit (LString "List")) PWild) (PVar "t"))) (EApp (EVar "VList") (EApp (EApp (EApp (EApp (EVar "genList") (EVar "tydefs")) (EVar "subst")) (EVar "t")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (ELit (LInt 7))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyApp" (PCon "TyCon" (PLit (LString "Array")) PWild) (PVar "t"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EVar "genList") (EVar "tydefs")) (EVar "subst")) (EVar "t")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (ELit (LInt 7)))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyApp" (PCon "TyCon" (PLit (LString "Option")) PWild) (PVar "t"))) (EIf (EApp (EVar "randBoolL") (ELit LUnit)) (EApp (EApp (EVar "VCon") (ELit (LString "None"))) (EListLit)) (EApp (EApp (EVar "VCon") (ELit (LString "Some"))) (EListLit (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "t"))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyApp" (PCon "TyApp" (PCon "TyCon" (PLit (LString "Result")) PWild) (PVar "e")) (PVar "a"))) (EIf (EApp (EVar "randBoolL") (ELit LUnit)) (EApp (EApp (EVar "VCon") (ELit (LString "Ok"))) (EListLit (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "a")))) (EApp (EApp (EVar "VCon") (ELit (LString "Err"))) (EListLit (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "e"))))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PCon "TyTuple" (PVar "ts"))) (EApp (EVar "VTuple") (EApp (EApp (EApp (EVar "genTuple") (EVar "tydefs")) (EVar "subst")) (EVar "ts"))))
(DFunDef false "genForType" ((PVar "tydefs") (PVar "subst") (PVar "ty")) (EApp (EApp (EApp (EVar "genUserOrFail") (EVar "tydefs")) (EVar "subst")) (EVar "ty")))
(DTypeSig false "genTuple" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "genTuple" (PWild PWild (PList)) (EListLit))
(DFunDef false "genTuple" ((PVar "tydefs") (PVar "subst") (PCons (PVar "t") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "t")) (EApp (EApp (EApp (EVar "genTuple") (EVar "tydefs")) (EVar "subst")) (EVar "rest"))))
(DTypeSig false "genList" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "genList" (PWild PWild PWild (PLit (LInt 0))) (EListLit))
(DFunDef false "genList" ((PVar "tydefs") (PVar "subst") (PVar "t") (PVar "n")) (EBinOp "::" (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "genList") (EVar "tydefs")) (EVar "subst")) (EVar "t")) (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "genFloat" (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "genFloat" (PWild) (EBlock (DoLet false false (PVar "r") (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 2000001)))) (DoExpr (EApp (EVar "VFloat") (EBinOp "-" (EBinOp "*" (EApp (EVar "intToFloat") (EVar "r")) (EBinOp "/" (ELit (LFloat 1.0)) (ELit (LFloat 1000000.0)))) (ELit (LFloat 1.0)))))))
(DTypeSig false "genCharStr" (TyFun (TyCon "Unit") (TyCon "String")))
(DFunDef false "genCharStr" (PWild) (EApp (EVar "charToStr") (EApp (EVar "charFromCodeU") (EBinOp "+" (ELit (LInt 32)) (EBinOp "%" (EApp (EVar "rngNextLocal") (ELit LUnit)) (ELit (LInt 95)))))))
(DTypeSig false "charFromCodeU" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "charFromCodeU" ((PVar "n")) (EMatch (EApp (EVar "charFromCode") (EVar "n")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (ELit (LChar " ")))))
(DTypeSig false "genString" (TyFun (TyCon "Unit") (TyCon "String")))
(DFunDef false "genString" (PWild) (EApp (EVar "stringConcat") (EApp (EVar "genStringGo") (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (ELit (LInt 10))))))
(DTypeSig false "genStringGo" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "genStringGo" ((PLit (LInt 0))) (EListLit))
(DFunDef false "genStringGo" ((PVar "n")) (EBinOp "::" (EApp (EVar "genCharStr") (ELit LUnit)) (EApp (EVar "genStringGo") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "genUserOrFail" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Ty") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "genUserOrFail" ((PVar "tydefs") (PVar "subst") (PVar "ty")) (EMatch (EApp (EVar "tySpine") (EVar "ty")) (arm (PCon "Some" (PTuple (PVar "name") (PVar "args"))) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "tydefs")) (arm (PCon "Some" (PVar "tydef")) () (EApp (EApp (EApp (EApp (EApp (EVar "genUser") (EVar "tydefs")) (EVar "subst")) (EVar "name")) (EVar "tydef")) (EVar "args"))) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "prop_runner: no Arbitrary instance for type '")) (EVar "name")) (ELit (LString "'. Add 'deriving (Arbitrary)' or an explicit impl."))))))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "prop_runner: cannot generate values for type"))))))
(DTypeSig false "genUser" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "String") (TyFun (TyCon "TyDef") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "genUser" ((PVar "tydefs") (PVar "subst") (PVar "name") (PVar "tydef") (PVar "args")) (EBlock (DoLet false false (PVar "args2") (EApp (EApp (EMethodRef "map") (EApp (EVar "substTy") (EVar "subst"))) (EVar "args"))) (DoExpr (EMatch (EVar "tydef") (arm (PCon "TDData" (PVar "params") (PVar "variants")) () (EBlock (DoLet false false (PVar "subst2") (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "params")) (EApp (EVar "listLen") (EVar "args2"))) (EApp (EApp (EVar "zipL") (EVar "params")) (EVar "args2")) (EListLit))) (DoLet false false (PVar "v") (EApp (EApp (EVar "nthList") (EVar "variants")) (EApp (EApp (EVar "randIntRange") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "listLen") (EVar "variants")) (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EApp (EVar "genVariant") (EVar "tydefs")) (EVar "subst2")) (EVar "v")))))))))
(DTypeSig false "genVariant" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Variant") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "genVariant" ((PVar "tydefs") (PVar "subst") (PCon "Variant" (PVar "cname") (PVar "payload"))) (EMatch (EVar "payload") (arm (PCon "ConPos" (PVar "tys")) () (EApp (EApp (EVar "VCon") (EVar "cname")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst"))) (EVar "tys")))) (arm (PCon "ConNamed" (PVar "fields") PWild) () (EApp (EApp (EVar "VCon") (EVar "cname")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "genFieldTy") (EVar "tydefs")) (EVar "subst"))) (EVar "fields"))))))
(DTypeSig false "genFieldTy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "Field") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "genFieldTy" ((PVar "tydefs") (PVar "subst") (PCon "Field" PWild (PVar "fty"))) (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EVar "subst")) (EVar "fty")))
(DTypeSig false "nthList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyCon "Int") (TyVar "a"))))
(DFunDef false "nthList" ((PCons (PVar "x") PWild) (PLit (LInt 0))) (EVar "x"))
(DFunDef false "nthList" ((PCons PWild (PVar "xs")) (PVar "n")) (EApp (EApp (EVar "nthList") (EVar "xs")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))))
(DFunDef false "nthList" ((PList) PWild) (EApp (EVar "panic") (ELit (LString "nthList: index out of range"))))
(DTypeSig false "shrinkValue" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "shrinkValue" ((PVar "ty") (PVar "v")) (EMatch (ETuple (EVar "ty") (EVar "v")) (arm (PTuple (PCon "TyCon" (PLit (LString "Int")) PWild) (PCon "VInt" (PVar "n"))) () (EApp (EVar "shrinkInt") (EVar "n"))) (arm (PTuple (PCon "TyCon" (PLit (LString "Bool")) PWild) (PCon "VBool" (PCon "True"))) () (EListLit (EApp (EVar "VBool") (EVar "False")))) (arm (PTuple (PCon "TyCon" (PLit (LString "Bool")) PWild) (PCon "VBool" (PCon "False"))) () (EListLit)) (arm (PTuple (PCon "TyCon" (PLit (LString "Float")) PWild) (PCon "VFloat" (PVar "x"))) () (EIf (EBinOp "==" (EVar "x") (ELit (LFloat 0.0))) (EListLit) (EListLit (EApp (EVar "VFloat") (ELit (LFloat 0.0))) (EApp (EVar "VFloat") (EBinOp "/" (EVar "x") (ELit (LFloat 2.0))))))) (arm (PTuple (PCon "TyCon" (PLit (LString "String")) PWild) (PCon "VString" (PVar "s"))) () (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EListLit) (EListLit (EApp (EVar "VString") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "/" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2)))) (EVar "s")))))) (arm (PTuple (PCon "TyApp" (PCon "TyCon" (PLit (LString "List")) PWild) PWild) (PCon "VList" (PList))) () (EListLit)) (arm (PTuple (PCon "TyApp" (PCon "TyCon" (PLit (LString "List")) PWild) PWild) (PCon "VList" (PCons PWild (PVar "rest")))) () (EListLit (EApp (EVar "VList") (EVar "rest")))) (arm (PTuple (PCon "TyApp" (PCon "TyCon" (PLit (LString "Option")) PWild) PWild) (PCon "VCon" (PLit (LString "None")) (PList))) () (EListLit)) (arm (PTuple (PCon "TyApp" (PCon "TyCon" (PLit (LString "Option")) PWild) PWild) (PCon "VCon" (PLit (LString "Some")) PWild)) () (EListLit (EApp (EApp (EVar "VCon") (ELit (LString "None"))) (EListLit)))) (arm PWild () (EListLit))))
(DTypeSig false "shrinkInt" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "shrinkInt" ((PVar "n")) (EBlock (DoLet false false (PVar "cands") (EListLit (ELit (LInt 0)) (EBinOp "/" (EVar "n") (ELit (LInt 2))) (EBinOp "+" (EVar "n") (EIf (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1))) (ELit (LInt 1)))))) (DoExpr (EApp (EApp (EMethodRef "map") (EVar "VInt")) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "!=" (EVar "_s") (EVar "n")))) (EVar "cands"))))))
(DTypeSig false "checkProp" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyCon "Bool"))))))
(DFunDef false "checkProp" ((PVar "evalEnv") (PVar "body") (PVar "inputs")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "extendEnv") (EApp (EVar "EvalEnv") (EListLit (EListLit)))) (EBinOp "++" (EVar "inputs") (EVar "evalEnv")))) (DoExpr (EMatch (EApp (EVar "force") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body"))) (arm (PCon "VBool" (PVar "b")) () (EVar "b")) (arm PWild () (EVar "False"))))))
(DData Public "PropOutcome" ("v") ((variant "PropPassed" (ConPos)) (variant "PropFailed" (ConPos (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "v")))))) ())
(DTypeSig false "runProp" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyEffect ("IO") None (TyCon "Bool")))))))
(DFunDef false "runProp" ((PVar "tydefs") (PVar "evalEnv") (PCon "DProp" PWild (PVar "name") (PVar "params") (PVar "body")) (PVar "maxTests")) (EBlock (DoLet false false PWild (EApp (EVar "putStr") (EBinOp "++" (EBinOp "++" (ELit (LString "Testing ")) (EApp (EVar "escStrLocal") (EVar "name"))) (ELit (LString " ... "))))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "tydefs")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (ELit (LInt 1))) (arm (PCon "PropPassed") () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (ELit (LString "OK (")) (EApp (EVar "intToString") (EVar "maxTests"))) (ELit (LString " tests)"))))) (DoExpr (EVar "True")))) (arm (PCon "PropFailed" (PVar "run") (PVar "shrunk")) () (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAILED after ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "run")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EIf (EBinOp "==" (EVar "run") (ELit (LInt 1))) (ELit (LString " test")) (ELit (LString " tests"))))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EVar "putStrLn") (ELit (LString "  Counterexample:")))) (DoLet false false PWild (EApp (EVar "printCounterexample") (EVar "shrunk"))) (DoExpr (EVar "False"))))))))
(DFunDef false "runProp" ((PVar "tydefs") (PVar "evalEnv") PWild (PVar "maxTests")) (EVar "True"))
(DTypeSig false "findFailure" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e")))))))))))
(DFunDef false "findFailure" ((PVar "tydefs") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "maxTests") (PVar "run")) (EIf (EBinOp ">" (EVar "run") (EVar "maxTests")) (EVar "PropPassed") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "inputs") (EApp (EApp (EVar "genInputs") (EVar "tydefs")) (EVar "params"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailureStep") (EVar "tydefs")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (EVar "run")) (EVar "inputs")) (EApp (EApp (EApp (EVar "checkProp") (EVar "evalEnv")) (EVar "body")) (EVar "inputs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findFailureStep" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Bool") (TyEffect () (Some "e") (TyApp (TyCon "PropOutcome") (TyApp (TyCon "Value") (TyVar "e")))))))))))))
(DFunDef false "findFailureStep" ((PVar "tydefs") (PVar "evalEnv") (PVar "params") (PVar "body") (PVar "maxTests") (PVar "run") PWild (PCon "True")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findFailure") (EVar "tydefs")) (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "maxTests")) (EBinOp "+" (EVar "run") (ELit (LInt 1)))))
(DFunDef false "findFailureStep" (PWild (PVar "evalEnv") (PVar "params") (PVar "body") PWild (PVar "run") (PVar "inputs") (PCon "False")) (EApp (EApp (EVar "PropFailed") (EVar "run")) (EApp (EApp (EApp (EApp (EVar "shrinkLoop") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "inputs"))))
(DTypeSig false "genInputs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "genInputs" (PWild (PList)) (EListLit))
(DFunDef false "genInputs" ((PVar "tydefs") (PCons (PCon "PropParam" (PVar "x") (PVar "ty")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "x") (EApp (EApp (EApp (EVar "genForType") (EVar "tydefs")) (EListLit)) (EVar "ty"))) (EApp (EApp (EVar "genInputs") (EVar "tydefs")) (EVar "rest"))))
(DTypeSig false "printCounterexample" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printCounterexample" ((PList)) (ELit LUnit))
(DFunDef false "printCounterexample" ((PCons (PTuple (PVar "x") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "ppValue") (EVar "v")))) (ELit (LString ""))))) (DoExpr (EApp (EVar "printCounterexample") (EVar "rest")))))
(DTypeSig false "escStrLocal" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escStrLocal" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\""))))
(DTypeSig false "shrinkLoop" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "shrinkLoop" ((PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "tryShrinkOne") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (ELit (LInt 0))) (arm (PCon "Some" (PVar "better")) () (EApp (EApp (EApp (EApp (EVar "shrinkLoop") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "better"))) (arm (PCon "None") () (EVar "candidate"))))
(DTypeSig false "tryShrinkOne" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))))))
(DFunDef false "tryShrinkOne" ((PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "listLen") (EVar "params"))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PCon "PropParam" (PVar "x") (PVar "ty")) (EApp (EApp (EVar "nthList") (EVar "params")) (EVar "i"))) (DoLet false false (PVar "currentV") (EApp (EApp (EVar "assocVal") (EVar "x")) (EVar "candidate"))) (DoLet false false (PVar "smaller") (EApp (EApp (EVar "shrinkValue") (EVar "ty")) (EVar "currentV"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findSmaller") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EVar "x")) (EVar "smaller")) (arm (PCon "Some" (PVar "better")) () (EApp (EVar "Some") (EVar "better"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "tryShrinkOne") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findSmaller" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))))))
(DFunDef false "findSmaller" (PWild PWild PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "findSmaller" ((PVar "evalEnv") (PVar "params") (PVar "body") (PVar "candidate") (PVar "x") (PCons (PVar "sv") (PVar "rest"))) (EBlock (DoLet false false (PVar "candidate2") (EApp (EApp (EApp (EVar "replaceVal") (EVar "x")) (EVar "sv")) (EVar "candidate"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "checkProp") (EVar "evalEnv")) (EVar "body")) (EVar "candidate2")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findSmaller") (EVar "evalEnv")) (EVar "params")) (EVar "body")) (EVar "candidate")) (EVar "x")) (EVar "rest")) (EApp (EVar "Some") (EVar "candidate2"))))))
(DTypeSig false "assocVal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "assocVal" ((PVar "x") (PVar "kvs")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "x")) (EVar "kvs")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "prop shrink: missing binding ")) (EVar "x"))))))
(DTypeSig false "replaceVal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "replaceVal" (PWild PWild (PList)) (EListLit))
(DFunDef false "replaceVal" ((PVar "x") (PVar "sv") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "x")) (EBinOp "::" (ETuple (EVar "k") (EVar "sv")) (EApp (EApp (EApp (EVar "replaceVal") (EVar "x")) (EVar "sv")) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EApp (EVar "replaceVal") (EVar "x")) (EVar "sv")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isProp" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isProp" ((PCon "DProp" PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isProp" (PWild) (EVar "False"))
(DTypeSig false "filterProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "filterProps" ((PVar "decls")) (EApp (EApp (EVar "filterDecls") (EVar "isProp")) (EVar "decls")))
(DTypeSig false "filterDecls" (TyFun (TyFun (TyCon "Decl") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "filterDecls" (PWild (PList)) (EListLit))
(DFunDef false "filterDecls" ((PVar "p") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "p") (EVar "d")) (EBinOp "::" (EVar "d") (EApp (EApp (EVar "filterDecls") (EVar "p")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterDecls") (EVar "p")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "runAllProps" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Bool")))))
(DFunDef false "runAllProps" ((PVar "evalEnv") (PVar "program")) (EBlock (DoLet false false (PVar "props") (EApp (EVar "filterProps") (EVar "program"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "props")) (EVar "True") (EBlock (DoLet false false (PVar "tydefs") (EApp (EVar "buildTyDefs") (EVar "program"))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EVar "runEach") (EVar "tydefs")) (EVar "evalEnv")) (EVar "props"))) (DoLet false false (PVar "nPass") (EApp (EVar "countTrue") (EVar "results"))) (DoLet false false (PVar "nFail") (EBinOp "-" (EApp (EVar "listLen") (EVar "results")) (EVar "nPass"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "nPass")))) (ELit (LString " passed, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "nFail")))) (ELit (LString " failed"))))) (DoExpr (EBinOp "==" (EVar "nFail") (ELit (LInt 0)))))))))
(DTypeSig false "runEach" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyDef"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Bool")))))))
(DFunDef false "runEach" (PWild PWild (PList)) (EListLit))
(DFunDef false "runEach" ((PVar "tydefs") (PVar "evalEnv") (PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "runProp") (EVar "tydefs")) (EVar "evalEnv")) (EVar "p")) (ELit (LInt 100))) (EApp (EApp (EApp (EVar "runEach") (EVar "tydefs")) (EVar "evalEnv")) (EVar "rest"))))
(DTypeSig false "countTrue" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyCon "Int")))
(DFunDef false "countTrue" ((PList)) (ELit (LInt 0)))
(DFunDef false "countTrue" ((PCons (PCon "True") (PVar "rest"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "countTrue") (EVar "rest"))))
(DFunDef false "countTrue" ((PCons (PCon "False") (PVar "rest"))) (EApp (EVar "countTrue") (EVar "rest")))
(DTypeSig true "hasProps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasProps" ((PVar "decls")) (EApp (EApp (EVar "anyDecl") (EVar "isProp")) (EVar "decls")))
(DTypeSig false "anyDecl" (TyFun (TyFun (TyCon "Decl") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "anyDecl" (PWild (PList)) (EVar "False"))
(DFunDef false "anyDecl" ((PVar "p") (PCons (PVar "d") (PVar "rest"))) (EBinOp "||" (EApp (EVar "p") (EVar "d")) (EApp (EApp (EVar "anyDecl") (EVar "p")) (EVar "rest"))))
