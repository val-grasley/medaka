# META
source_lines=22
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
expectEqual expected actual =
  if eq expected actual then
    Pass
  else
    Fail "mismatch"

goTests t =
  match runExpectation t
    Pass =>
      println "ok"
      done 1
    Fail msg =>
      println msg
      done 0

prop "reverse is involutive" (xs : List Int) = eq (reverse (reverse xs)) xs

prop "span recovers" (xs : List Int) (n : Int) =
  let (a, b) = span p xs
  eq (a ++ b) xs

test "two plus two" = expectEqual 4 (2 + 2)
# PARSE
(DFunDef false "expectEqual" ((PVar "expected") (PVar "actual")) (EIf (EApp (EApp (EVar "eq") (EVar "expected")) (EVar "actual")) (EVar "Pass") (EApp (EVar "Fail") (ELit (LString "mismatch")))))
(DFunDef false "goTests" ((PVar "t")) (EMatch (EApp (EVar "runExpectation") (EVar "t")) (arm (PCon "Pass") () (EBlock (DoExpr (EApp (EVar "println") (ELit (LString "ok")))) (DoExpr (EApp (EVar "done") (ELit (LInt 1)))))) (arm (PCon "Fail" (PVar "msg")) () (EBlock (DoExpr (EApp (EVar "println") (EVar "msg"))) (DoExpr (EApp (EVar "done") (ELit (LInt 0))))))))
(DProp false "reverse is involutive" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "eq") (EApp (EVar "reverse") (EApp (EVar "reverse") (EVar "xs")))) (EVar "xs")))
(DProp false "span recovers" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EApp (EVar "span") (EVar "p")) (EVar "xs"))) (DoExpr (EApp (EApp (EVar "eq") (EBinOp "++" (EVar "a") (EVar "b"))) (EVar "xs")))))
(DTest false "two plus two" (EApp (EApp (EVar "expectEqual") (ELit (LInt 4))) (EBinOp "+" (ELit (LInt 2)) (ELit (LInt 2)))))
# PRINTER
expectEqual expected actual =
  if eq expected actual then
    Pass
  else
    Fail "mismatch"
goTests t = match runExpectation t
  Pass =>
    println "ok"
    done 1
  Fail msg =>
    println msg
    done 0
prop "reverse is involutive" (xs : List Int) = eq (reverse (reverse xs)) xs
prop "span recovers" (xs : List Int) (n : Int) =
  let (a, b) = span p xs
  eq (a ++ b) xs
test "two plus two" = expectEqual 4 (2 + 2)
# DESUGAR
(DFunDef false "expectEqual" ((PVar "expected") (PVar "actual")) (EIf (EApp (EApp (EVar "eq") (EVar "expected")) (EVar "actual")) (EVar "Pass") (EApp (EVar "Fail") (ELit (LString "mismatch")))))
(DFunDef false "goTests" ((PVar "t")) (EMatch (EApp (EVar "runExpectation") (EVar "t")) (arm (PCon "Pass") () (EBlock (DoExpr (EApp (EVar "println") (ELit (LString "ok")))) (DoExpr (EApp (EVar "done") (ELit (LInt 1)))))) (arm (PCon "Fail" (PVar "msg")) () (EBlock (DoExpr (EApp (EVar "println") (EVar "msg"))) (DoExpr (EApp (EVar "done") (ELit (LInt 0))))))))
(DProp false "reverse is involutive" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EVar "eq") (EApp (EVar "reverse") (EApp (EVar "reverse") (EVar "xs")))) (EVar "xs")))
(DProp false "span recovers" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EApp (EVar "span") (EVar "p")) (EVar "xs"))) (DoExpr (EApp (EApp (EVar "eq") (EBinOp "++" (EVar "a") (EVar "b"))) (EVar "xs")))))
(DTest false "two plus two" (EApp (EApp (EVar "expectEqual") (ELit (LInt 4))) (EBinOp "+" (ELit (LInt 2)) (ELit (LInt 2)))))
# MARK
(DFunDef false "expectEqual" ((PVar "expected") (PVar "actual")) (EIf (EApp (EApp (EMethodRef "eq") (EVar "expected")) (EVar "actual")) (EVar "Pass") (EApp (EVar "Fail") (ELit (LString "mismatch")))))
(DFunDef false "goTests" ((PVar "t")) (EMatch (EApp (EVar "runExpectation") (EVar "t")) (arm (PCon "Pass") () (EBlock (DoExpr (EApp (EDictApp "println") (ELit (LString "ok")))) (DoExpr (EApp (EVar "done") (ELit (LInt 1)))))) (arm (PCon "Fail" (PVar "msg")) () (EBlock (DoExpr (EApp (EDictApp "println") (EVar "msg"))) (DoExpr (EApp (EVar "done") (ELit (LInt 0))))))))
(DProp false "reverse is involutive" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int")))) (EApp (EApp (EMethodRef "eq") (EApp (EVar "reverse") (EApp (EVar "reverse") (EVar "xs")))) (EVar "xs")))
(DProp false "span recovers" ((pp "xs" (TyApp (TyCon "List") (TyCon "Int"))) (pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EApp (EVar "span") (EVar "p")) (EVar "xs"))) (DoExpr (EApp (EApp (EMethodRef "eq") (EBinOp "++" (EVar "a") (EVar "b"))) (EVar "xs")))))
(DTest false "two plus two" (EApp (EApp (EVar "expectEqual") (ELit (LInt 4))) (EBinOp "+" (ELit (LInt 2)) (ELit (LInt 2)))))
