# META
source_lines=17
stages=CORE_IR
# SOURCE
-- explicit Refs (Ref / setRef / .value) + pure recursive accumulation
countUp n =
  let r = Ref 0
  let _ = bump r n
  r.value
bump r 0 = r.value
bump r k =
  let _ = setRef r (r.value + 1)
  bump r (k - 1)
sumTo n = loop 0 1 n
loop acc i n
  | i > n = acc
  | otherwise = loop (acc + i) (i + 1) n
main =
  let r = Ref 41
  let _ = setRef r (r.value + 1)
  (r.value, r, countUp 5, sumTo 10)
# CORE_IR
(CProgram ((CBind "countUp" (CClause ((PVar "n")) (CBlock (CSLet false (PVar "r") (CApp (CVar "Ref" AGlobal) (CLit (LInt 0)))) (CSLet false PWild (CApp (CApp (CVar "bump" AGlobal) (CVar "r" (ALocal 0 0))) (CVar "n" (ALocal 1 0)))) (CSExpr (CFieldAccess (CVar "r" (ALocal 1 0)) "value" ""))))) (CBind "bump" (CClause ((PVar "r") (PLit (LInt 0))) (CFieldAccess (CVar "r" (ALocal 1 0)) "value" "")) (CClause ((PVar "r") (PVar "k")) (CBlock (CSLet false PWild (CApp (CApp (CVar "setRef" AGlobal) (CVar "r" (ALocal 1 0))) (CBinPrim "+" (CFieldAccess (CVar "r" (ALocal 1 0)) "value" "") (CLit (LInt 1))))) (CSExpr (CApp (CApp (CVar "bump" AGlobal) (CVar "r" (ALocal 2 0))) (CBinPrim "-" (CVar "k" (ALocal 1 0)) (CLit (LInt 1)))))))) (CBind "sumTo" (CClause ((PVar "n")) (CApp (CApp (CApp (CVar "loop" AGlobal) (CLit (LInt 0))) (CLit (LInt 1))) (CVar "n" (ALocal 0 0))))) (CBind "loop" (CClause ((PVar "acc") (PVar "i") (PVar "n")) (CIf (CBinPrim ">" (CVar "i" (ALocal 1 0)) (CVar "n" (ALocal 0 0))) (CVar "acc" (ALocal 2 0)) (CIf (CVar "otherwise" AGlobal) (CApp (CApp (CApp (CVar "loop" AGlobal) (CBinPrim "+" (CVar "acc" (ALocal 2 0)) (CVar "i" (ALocal 1 0)))) (CBinPrim "+" (CVar "i" (ALocal 1 0)) (CLit (LInt 1)))) (CVar "n" (ALocal 0 0))) (CApp (CVar "__fallthrough__" AGlobal) (CLit LUnit)))))) (CBind "main" (CClause () (CBlock (CSLet false (PVar "r") (CApp (CVar "Ref" AGlobal) (CLit (LInt 41)))) (CSLet false PWild (CApp (CApp (CVar "setRef" AGlobal) (CVar "r" (ALocal 0 0))) (CBinPrim "+" (CFieldAccess (CVar "r" (ALocal 0 0)) "value" "") (CLit (LInt 1))))) (CSExpr (CTuple (CFieldAccess (CVar "r" (ALocal 1 0)) "value" "") (CVar "r" (ALocal 1 0)) (CApp (CVar "countUp" AGlobal) (CLit (LInt 5))) (CApp (CVar "sumTo" AGlobal) (CLit (LInt 10))))))))) () () ())
