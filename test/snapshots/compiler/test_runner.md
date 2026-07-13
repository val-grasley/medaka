# META
source_lines=51
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted `test "…" = <expr>` runner (Phase 127 restored 2026-07-11).
--
-- A `test "name" = body` declaration is symmetric with `prop`: the host
-- (test_cmd.mdk) discovers every `DTest` decl, evaluates its body to an
-- `Expectation` VALUE (never catching panics — a genuinely-crashing body is
-- unrecoverable and aborts the run, per the `no-catchable-panics` invariant),
-- and reports pass/fail using the SAME reporting shape as doctests (ok/FAIL +
-- loc + per-file summary + exit code, P0-6).
--
-- This module owns discovery (`collectTests`/`hasTests`) and the single-body
-- evaluator (`runOneTest`); test_cmd owns the incremental print loop + summary
-- (it can't live here — test_cmd imports this module, not the reverse).  Like
-- prop_runner, results are printed AS each test is evaluated, so a body that
-- aborts the run does not mask the tests that already passed.

import frontend.ast.{Decl, DTest, Expr(..), Loc(..)}
import eval.eval.{Value(..), EvalEnv(..), eval, extendEnv, force, ppValue}
import tools.doctest.{ExResult(..)}

-- True iff the program declares at least one `test "…"`.
export hasTests : List Decl -> Bool
hasTests [] = False
hasTests ((DTest _ _ _)::_) = True
hasTests (_::rest) = hasTests rest

-- Line number of a body expr (peel the transparent ELoc wrapper).
exprLine : Expr -> Int
exprLine (ELoc (Loc _ l _ _ _) _) = l
exprLine (EApp f _) = exprLine f
exprLine (EAnnot e _) = exprLine e
exprLine (EHeadAnnot e _) = exprLine e
exprLine _ = 0

-- Each `test "…" = body` as (name, line, body), in source order.
export collectTests : List Decl -> List (String, Int, Expr)
collectTests [] = []
collectTests ((DTest _ name body)::rest) =
  (name, exprLine body, body) :: collectTests rest
collectTests (_::rest) = collectTests rest

-- Evaluate one test body to an Expectation value and classify it.  A body that
-- does not reduce to Pass/Fail is an `Errored` (e.g. a partial closure); a body
-- that genuinely panics is unrecoverable and aborts the whole run.
export runOneTest : List (String, Value e) -> Expr -> <Mut | e> ExResult
runOneTest evalEnv body =
  let env = extendEnv (EvalEnv [[]]) evalEnv
  match force (eval env body)
    VCon "Pass" [] => Pass
    VCon "Fail" [VString msg] => Fail msg ""
    VCon "Fail" [v] => Fail (ppValue v) ""
    other => Errored ("test body did not evaluate to an Expectation: " ++ ppValue other)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DTest" false) (mem "Expr" true) (mem "Loc" true))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "EvalEnv" true) (mem "eval" false) (mem "extendEnv" false) (mem "force" false) (mem "ppValue" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "ExResult" true))))
(DTypeSig true "hasTests" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasTests" ((PList)) (EVar "False"))
(DFunDef false "hasTests" ((PCons (PCon "DTest" PWild PWild PWild) PWild)) (EVar "True"))
(DFunDef false "hasTests" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasTests") (EVar "rest")))
(DTypeSig false "exprLine" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "exprLine" ((PCon "ELoc" (PCon "Loc" PWild (PVar "l") PWild PWild PWild) PWild)) (EVar "l"))
(DFunDef false "exprLine" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "exprLine") (EVar "f")))
(DFunDef false "exprLine" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "exprLine") (EVar "e")))
(DFunDef false "exprLine" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "exprLine") (EVar "e")))
(DFunDef false "exprLine" (PWild) (ELit (LInt 0)))
(DTypeSig true "collectTests" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "collectTests" ((PList)) (EListLit))
(DFunDef false "collectTests" ((PCons (PCon "DTest" PWild (PVar "name") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "exprLine") (EVar "body")) (EVar "body")) (EApp (EVar "collectTests") (EVar "rest"))))
(DFunDef false "collectTests" ((PCons PWild (PVar "rest"))) (EApp (EVar "collectTests") (EVar "rest")))
(DTypeSig true "runOneTest" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Expr") (TyEffect ("Mut") (Some "e") (TyCon "ExResult")))))
(DFunDef false "runOneTest" ((PVar "evalEnv") (PVar "body")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "extendEnv") (EApp (EVar "EvalEnv") (EListLit (EListLit)))) (EVar "evalEnv"))) (DoExpr (EMatch (EApp (EVar "force") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body"))) (arm (PCon "VCon" (PLit (LString "Pass")) (PList)) () (EVar "Pass")) (arm (PCon "VCon" (PLit (LString "Fail")) (PList (PCon "VString" (PVar "msg")))) () (EApp (EApp (EVar "Fail") (EVar "msg")) (ELit (LString "")))) (arm (PCon "VCon" (PLit (LString "Fail")) (PList (PVar "v"))) () (EApp (EApp (EVar "Fail") (EApp (EVar "ppValue") (EVar "v"))) (ELit (LString "")))) (arm (PVar "other") () (EApp (EVar "Errored") (EBinOp "++" (ELit (LString "test body did not evaluate to an Expectation: ")) (EApp (EVar "ppValue") (EVar "other")))))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DTest" false) (mem "Expr" true) (mem "Loc" true))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "EvalEnv" true) (mem "eval" false) (mem "extendEnv" false) (mem "force" false) (mem "ppValue" false))))
(DUse false (UseGroup ("tools" "doctest") ((mem "ExResult" true))))
(DTypeSig true "hasTests" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasTests" ((PList)) (EVar "False"))
(DFunDef false "hasTests" ((PCons (PCon "DTest" PWild PWild PWild) PWild)) (EVar "True"))
(DFunDef false "hasTests" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasTests") (EVar "rest")))
(DTypeSig false "exprLine" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "exprLine" ((PCon "ELoc" (PCon "Loc" PWild (PVar "l") PWild PWild PWild) PWild)) (EVar "l"))
(DFunDef false "exprLine" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "exprLine") (EVar "f")))
(DFunDef false "exprLine" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "exprLine") (EVar "e")))
(DFunDef false "exprLine" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "exprLine") (EVar "e")))
(DFunDef false "exprLine" (PWild) (ELit (LInt 0)))
(DTypeSig true "collectTests" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "collectTests" ((PList)) (EListLit))
(DFunDef false "collectTests" ((PCons (PCon "DTest" PWild (PVar "name") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "exprLine") (EVar "body")) (EVar "body")) (EApp (EVar "collectTests") (EVar "rest"))))
(DFunDef false "collectTests" ((PCons PWild (PVar "rest"))) (EApp (EVar "collectTests") (EVar "rest")))
(DTypeSig true "runOneTest" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "Expr") (TyEffect ("Mut") (Some "e") (TyCon "ExResult")))))
(DFunDef false "runOneTest" ((PVar "evalEnv") (PVar "body")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EVar "extendEnv") (EApp (EVar "EvalEnv") (EListLit (EListLit)))) (EVar "evalEnv"))) (DoExpr (EMatch (EApp (EVar "force") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body"))) (arm (PCon "VCon" (PLit (LString "Pass")) (PList)) () (EVar "Pass")) (arm (PCon "VCon" (PLit (LString "Fail")) (PList (PCon "VString" (PVar "msg")))) () (EApp (EApp (EVar "Fail") (EVar "msg")) (ELit (LString "")))) (arm (PCon "VCon" (PLit (LString "Fail")) (PList (PVar "v"))) () (EApp (EApp (EVar "Fail") (EApp (EVar "ppValue") (EVar "v"))) (ELit (LString "")))) (arm (PVar "other") () (EApp (EVar "Errored") (EBinOp "++" (ELit (LString "test body did not evaluate to an Expectation: ")) (EApp (EVar "ppValue") (EVar "other")))))))))
