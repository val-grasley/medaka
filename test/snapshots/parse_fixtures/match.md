# META
source_lines=14
stages=PARSE,DESUGAR,MARK
# SOURCE
fromMaybe d m =
  match m
    None => d
    Some x => x

len xs =
  match xs
    [] => 0
    y :: ys => 1 + len ys

classify n =
  match n
    0 => "zero"
    _ => "other"
# PARSE
(DFunDef false "fromMaybe" ((PVar "d") (PVar "m")) (EMatch (EVar "m") (arm (PCon "None") () (EVar "d")) (arm (PCon "Some" (PVar "x")) () (EVar "x"))))
(DFunDef false "len" ((PVar "xs")) (EMatch (EVar "xs") (arm (PList) () (ELit (LInt 0))) (arm (PCons (PVar "y") (PVar "ys")) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "len") (EVar "ys"))))))
(DFunDef false "classify" ((PVar "n")) (EMatch (EVar "n") (arm (PLit (LInt 0)) () (ELit (LString "zero"))) (arm PWild () (ELit (LString "other")))))
# DESUGAR
(DFunDef false "fromMaybe" ((PVar "d") (PVar "m")) (EMatch (EVar "m") (arm (PCon "None") () (EVar "d")) (arm (PCon "Some" (PVar "x")) () (EVar "x"))))
(DFunDef false "len" ((PVar "xs")) (EMatch (EVar "xs") (arm (PList) () (ELit (LInt 0))) (arm (PCons (PVar "y") (PVar "ys")) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "len") (EVar "ys"))))))
(DFunDef false "classify" ((PVar "n")) (EMatch (EVar "n") (arm (PLit (LInt 0)) () (ELit (LString "zero"))) (arm PWild () (ELit (LString "other")))))
# MARK
(DFunDef false "fromMaybe" ((PVar "d") (PVar "m")) (EMatch (EVar "m") (arm (PCon "None") () (EVar "d")) (arm (PCon "Some" (PVar "x")) () (EVar "x"))))
(DFunDef false "len" ((PVar "xs")) (EMatch (EVar "xs") (arm (PList) () (ELit (LInt 0))) (arm (PCons (PVar "y") (PVar "ys")) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "len") (EVar "ys"))))))
(DFunDef false "classify" ((PVar "n")) (EMatch (EVar "n") (arm (PLit (LInt 0)) () (ELit (LString "zero"))) (arm PWild () (ELit (LString "other")))))
