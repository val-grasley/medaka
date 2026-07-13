# META
source_lines=15
stages=DESUGAR,MARK
# SOURCE
factorial n =
  match n
    0 => 1
    n => n * factorial (n - 1)

fib n =
  match n
    0 => 0
    1 => 1
    n => fib (n - 1) + fib (n - 2)

main : <IO> Unit
main =
  println (factorial 10)
  println (fib 10)
# DESUGAR
(DFunDef false "factorial" ((PVar "n")) (EMatch (EVar "n") (arm (PLit (LInt 0)) () (ELit (LInt 1))) (arm (PVar "n") () (EBinOp "*" (EVar "n") (EApp (EVar "factorial") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))))
(DFunDef false "fib" ((PVar "n")) (EMatch (EVar "n") (arm (PLit (LInt 0)) () (ELit (LInt 0))) (arm (PLit (LInt 1)) () (ELit (LInt 1))) (arm (PVar "n") () (EBinOp "+" (EApp (EVar "fib") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "fib") (EBinOp "-" (EVar "n") (ELit (LInt 2))))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "factorial") (ELit (LInt 10))))) (DoExpr (EApp (EVar "println") (EApp (EVar "fib") (ELit (LInt 10)))))))
# MARK
(DFunDef false "factorial" ((PVar "n")) (EMatch (EVar "n") (arm (PLit (LInt 0)) () (ELit (LInt 1))) (arm (PVar "n") () (EBinOp "*" (EVar "n") (EApp (EVar "factorial") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))))
(DFunDef false "fib" ((PVar "n")) (EMatch (EVar "n") (arm (PLit (LInt 0)) () (ELit (LInt 0))) (arm (PLit (LInt 1)) () (ELit (LInt 1))) (arm (PVar "n") () (EBinOp "+" (EApp (EVar "fib") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EApp (EVar "fib") (EBinOp "-" (EVar "n") (ELit (LInt 2))))))))
(DTypeSig false "main" (TyEffect ("IO") None (TyCon "Unit")))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "factorial") (ELit (LInt 10))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "fib") (ELit (LInt 10)))))))
