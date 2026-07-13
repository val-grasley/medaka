# META
source_lines=10
stages=PARSE,DESUGAR,MARK
# SOURCE
double a = let s = a + 1 in s * 2
swap p = let x = p.a in let y = p.b in (y, x)

-- indented clause body that is a let-in expression (G8 case 1)
stepDown x =
  let go n = if n == 0 then 0 else go (n - 1) in go x

-- function-let with params followed by `in` (G8 case 1 variant)
counted x =
  let loop n acc = if n == 0 then acc else loop (n - 1) (acc + 1) in loop x 0
# PARSE
(DFunDef false "double" ((PVar "a")) (ELet false (PVar "s") (EBinOp "+" (EVar "a") (ELit (LInt 1))) (EBinOp "*" (EVar "s") (ELit (LInt 2)))))
(DFunDef false "swap" ((PVar "p")) (ELet false (PVar "x") (EFieldAccess (EVar "p") "a") (ELet false (PVar "y") (EFieldAccess (EVar "p") "b") (ETuple (EVar "y") (EVar "x")))))
(DFunDef false "stepDown" ((PVar "x")) (ELet false (PVar "go") (ELam ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EVar "go") (EBinOp "-" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "go") (EVar "x"))))
(DFunDef false "counted" ((PVar "x")) (ELet false (PVar "loop") (ELam ((PVar "n")) (ELam ((PVar "acc")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "acc") (EApp (EApp (EVar "loop") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))))) (EApp (EApp (EVar "loop") (EVar "x")) (ELit (LInt 0)))))
# DESUGAR
(DFunDef false "double" ((PVar "a")) (ELet false (PVar "s") (EBinOp "+" (EVar "a") (ELit (LInt 1))) (EBinOp "*" (EVar "s") (ELit (LInt 2)))))
(DFunDef false "swap" ((PVar "p")) (ELet false (PVar "x") (EFieldAccess (EVar "p") "a") (ELet false (PVar "y") (EFieldAccess (EVar "p") "b") (ETuple (EVar "y") (EVar "x")))))
(DFunDef false "stepDown" ((PVar "x")) (ELet false (PVar "go") (ELam ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EVar "go") (EBinOp "-" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "go") (EVar "x"))))
(DFunDef false "counted" ((PVar "x")) (ELet false (PVar "loop") (ELam ((PVar "n")) (ELam ((PVar "acc")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "acc") (EApp (EApp (EVar "loop") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))))) (EApp (EApp (EVar "loop") (EVar "x")) (ELit (LInt 0)))))
# MARK
(DFunDef false "double" ((PVar "a")) (ELet false (PVar "s") (EBinOp "+" (EVar "a") (ELit (LInt 1))) (EBinOp "*" (EVar "s") (ELit (LInt 2)))))
(DFunDef false "swap" ((PVar "p")) (ELet false (PVar "x") (EFieldAccess (EVar "p") "a") (ELet false (PVar "y") (EFieldAccess (EVar "p") "b") (ETuple (EVar "y") (EVar "x")))))
(DFunDef false "stepDown" ((PVar "x")) (ELet false (PVar "go") (ELam ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EVar "go") (EBinOp "-" (EVar "n") (ELit (LInt 1)))))) (EApp (EVar "go") (EVar "x"))))
(DFunDef false "counted" ((PVar "x")) (ELet false (PVar "loop") (ELam ((PVar "n")) (ELam ((PVar "acc")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "acc") (EApp (EApp (EVar "loop") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1))))))) (EApp (EApp (EVar "loop") (EVar "x")) (ELit (LInt 0)))))
