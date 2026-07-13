# META
source_lines=32
stages=PARSE,DESUGAR,MARK
# SOURCE
-- Constructs the self-hosted parser was hardened to accept (matching the OCaml
-- parser): expression-level let forms, if-let, impl hints, as-pattern lambda
-- params, the two `where` placements, and nested record update.

annotatedLet x = let y = x + 1 : Int in y * 2
recLet n = go n
  where
    go = k => go k

ifLet opt = match opt
  Some x => x
  _ => 0

asParam = (xs@rest) => rest
consAsParam = (ps@(x::_)) => x

whereEol x = g x
  where
    g y = y * 2

whereOwnLine x = g x
  where
    g y = y + 1

guardWhere x
  | x > limit = "big"
  | otherwise = "small"
  where
    limit = 100

nestedUpdate p = { p | address = { p.address | city = "Boston" } }
deepUpdate p = { p | a = { p.a | b = { p.a.b | c = 9 } } }
# PARSE
(DFunDef false "annotatedLet" ((PVar "x")) (ELet false (PVar "y") (EAnnot (EBinOp "+" (EVar "x") (ELit (LInt 1))) (TyCon "Int")) (EBinOp "*" (EVar "y") (ELit (LInt 2)))))
(DFunDef false "recLet" ((PVar "n")) (ELetGroup ((lgb "go" (clause () (ELam ((PVar "k")) (EApp (EVar "go") (EVar "k")))))) (EApp (EVar "go") (EVar "n"))))
(DFunDef false "ifLet" ((PVar "opt")) (EMatch (EVar "opt") (arm (PCon "Some" (PVar "x")) () (EVar "x")) (arm PWild () (ELit (LInt 0)))))
(DFunDef false "asParam" () (ELam ((PAs "xs" (PVar "rest"))) (EVar "rest")))
(DFunDef false "consAsParam" () (ELam ((PAs "ps" (PCons (PVar "x") PWild))) (EVar "x")))
(DFunDef false "whereEol" ((PVar "x")) (ELetGroup ((lgb "g" (clause ((PVar "y")) (EBinOp "*" (EVar "y") (ELit (LInt 2)))))) (EApp (EVar "g") (EVar "x"))))
(DFunDef false "whereOwnLine" ((PVar "x")) (ELetGroup ((lgb "g" (clause ((PVar "y")) (EBinOp "+" (EVar "y") (ELit (LInt 1)))))) (EApp (EVar "g") (EVar "x"))))
(DFunDef false "guardWhere" ((PVar "x")) (ELetGroup ((lgb "limit" (clause () (ELit (LInt 100))))) (EGuards (garm ((GBool (EBinOp ">" (EVar "x") (EVar "limit")))) (ELit (LString "big"))) (garm ((GBool (EVar "otherwise"))) (ELit (LString "small"))))))
(DFunDef false "nestedUpdate" ((PVar "p")) (ERecordUpdate (EVar "p") ((fa "address" (ERecordUpdate (EFieldAccess (EVar "p") "address") ((fa "city" (ELit (LString "Boston")))))))))
(DFunDef false "deepUpdate" ((PVar "p")) (ERecordUpdate (EVar "p") ((fa "a" (ERecordUpdate (EFieldAccess (EVar "p") "a") ((fa "b" (ERecordUpdate (EFieldAccess (EFieldAccess (EVar "p") "a") "b") ((fa "c" (ELit (LInt 9))))))))))))
# DESUGAR
(DFunDef false "annotatedLet" ((PVar "x")) (ELet false (PVar "y") (EAnnot (EBinOp "+" (EVar "x") (ELit (LInt 1))) (TyCon "Int")) (EBinOp "*" (EVar "y") (ELit (LInt 2)))))
(DFunDef false "recLet" ((PVar "n")) (ELetGroup ((lgb "go" (clause () (ELam ((PVar "k")) (EApp (EVar "go") (EVar "k")))))) (EApp (EVar "go") (EVar "n"))))
(DFunDef false "ifLet" ((PVar "opt")) (EMatch (EVar "opt") (arm (PCon "Some" (PVar "x")) () (EVar "x")) (arm PWild () (ELit (LInt 0)))))
(DFunDef false "asParam" () (ELam ((PAs "xs" (PVar "rest"))) (EVar "rest")))
(DFunDef false "consAsParam" () (ELam ((PAs "ps" (PCons (PVar "x") PWild))) (EVar "x")))
(DFunDef false "whereEol" ((PVar "x")) (ELetGroup ((lgb "g" (clause ((PVar "y")) (EBinOp "*" (EVar "y") (ELit (LInt 2)))))) (EApp (EVar "g") (EVar "x"))))
(DFunDef false "whereOwnLine" ((PVar "x")) (ELetGroup ((lgb "g" (clause ((PVar "y")) (EBinOp "+" (EVar "y") (ELit (LInt 1)))))) (EApp (EVar "g") (EVar "x"))))
(DFunDef false "guardWhere" ((PVar "x")) (ELetGroup ((lgb "limit" (clause () (ELit (LInt 100))))) (EIf (EBinOp ">" (EVar "x") (EVar "limit")) (ELit (LString "big")) (EIf (EVar "otherwise") (ELit (LString "small")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "nestedUpdate" ((PVar "p")) (ERecordUpdate (EVar "p") ((fa "address" (ERecordUpdate (EFieldAccess (EVar "p") "address") ((fa "city" (ELit (LString "Boston")))))))))
(DFunDef false "deepUpdate" ((PVar "p")) (ERecordUpdate (EVar "p") ((fa "a" (ERecordUpdate (EFieldAccess (EVar "p") "a") ((fa "b" (ERecordUpdate (EFieldAccess (EFieldAccess (EVar "p") "a") "b") ((fa "c" (ELit (LInt 9))))))))))))
# MARK
(DFunDef false "annotatedLet" ((PVar "x")) (ELet false (PVar "y") (EAnnot (EBinOp "+" (EVar "x") (ELit (LInt 1))) (TyCon "Int")) (EBinOp "*" (EVar "y") (ELit (LInt 2)))))
(DFunDef false "recLet" ((PVar "n")) (ELetGroup ((lgb "go" (clause () (ELam ((PVar "k")) (EApp (EVar "go") (EVar "k")))))) (EApp (EVar "go") (EVar "n"))))
(DFunDef false "ifLet" ((PVar "opt")) (EMatch (EVar "opt") (arm (PCon "Some" (PVar "x")) () (EVar "x")) (arm PWild () (ELit (LInt 0)))))
(DFunDef false "asParam" () (ELam ((PAs "xs" (PVar "rest"))) (EVar "rest")))
(DFunDef false "consAsParam" () (ELam ((PAs "ps" (PCons (PVar "x") PWild))) (EVar "x")))
(DFunDef false "whereEol" ((PVar "x")) (ELetGroup ((lgb "g" (clause ((PVar "y")) (EBinOp "*" (EVar "y") (ELit (LInt 2)))))) (EApp (EVar "g") (EVar "x"))))
(DFunDef false "whereOwnLine" ((PVar "x")) (ELetGroup ((lgb "g" (clause ((PVar "y")) (EBinOp "+" (EVar "y") (ELit (LInt 1)))))) (EApp (EVar "g") (EVar "x"))))
(DFunDef false "guardWhere" ((PVar "x")) (ELetGroup ((lgb "limit" (clause () (ELit (LInt 100))))) (EIf (EBinOp ">" (EVar "x") (EVar "limit")) (ELit (LString "big")) (EIf (EVar "otherwise") (ELit (LString "small")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "nestedUpdate" ((PVar "p")) (ERecordUpdate (EVar "p") ((fa "address" (ERecordUpdate (EFieldAccess (EVar "p") "address") ((fa "city" (ELit (LString "Boston")))))))))
(DFunDef false "deepUpdate" ((PVar "p")) (ERecordUpdate (EVar "p") ((fa "a" (ERecordUpdate (EFieldAccess (EVar "p") "a") ((fa "b" (ERecordUpdate (EFieldAccess (EFieldAccess (EVar "p") "a") "b") ((fa "c" (ELit (LInt 9))))))))))))
