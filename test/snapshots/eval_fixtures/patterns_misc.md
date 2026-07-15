# META
source_lines=17
stages=CORE_IR
# SOURCE
-- as-patterns (in match), literal-pattern dispatch, char values, unary minus, currying
ack 0 n = n + 1
ack m 0 = ack (m - 1) 1
ack m n = ack (m - 1) (ack m (n - 1))
dedup (x :: y :: rest) = if x == y then dedup (y :: rest) else x :: dedup (y :: rest)
dedup other = other
firstTwo xs = match xs
  whole@(x :: y :: _) => (x, y, whole)
  other => (0, 0, other)
const3 a b c = a
neg = (0 - 5)
vowel 'a' = True
vowel 'e' = True
vowel c = False
main =
  let part = const3 1 2
  (ack 2 3, dedup [1, 1, 2, 3, 3, 3], firstTwo [7, 8, 9], part 99, neg, vowel 'e', vowel 'z')
# CORE_IR
(CProgram ((CBind "ack" (CClause ((PLit (LInt 0)) (PVar "n")) (CBinPrim "+" (CVar "n" (ALocal 0 0)) (CLit (LInt 1)))) (CClause ((PVar "m") (PLit (LInt 0))) (CApp (CApp (CVar "ack" AGlobal) (CBinPrim "-" (CVar "m" (ALocal 1 0)) (CLit (LInt 1)))) (CLit (LInt 1)))) (CClause ((PVar "m") (PVar "n")) (CApp (CApp (CVar "ack" AGlobal) (CBinPrim "-" (CVar "m" (ALocal 1 0)) (CLit (LInt 1)))) (CApp (CApp (CVar "ack" AGlobal) (CVar "m" (ALocal 1 0))) (CBinPrim "-" (CVar "n" (ALocal 0 0)) (CLit (LInt 1))))))) (CBind "dedup" (CClause ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (CIf (CBinPrim "==" (CVar "x" (ALocal 0 0)) (CVar "y" (ALocal 0 1))) (CApp (CVar "dedup" AGlobal) (CBinPrim "::" (CVar "y" (ALocal 0 1)) (CVar "rest" (ALocal 0 2)))) (CBinPrim "::" (CVar "x" (ALocal 0 0)) (CApp (CVar "dedup" AGlobal) (CBinPrim "::" (CVar "y" (ALocal 0 1)) (CVar "rest" (ALocal 0 2))))))) (CClause ((PVar "other")) (CVar "other" (ALocal 0 0)))) (CBind "firstTwo" (CClause ((PVar "xs")) (CDecision (CVar "xs" (ALocal 0 0)) ((arm (PAs "whole" (PCons (PVar "x") (PCons (PVar "y") PWild))) () (CTuple (CVar "x" (ALocal 0 1)) (CVar "y" (ALocal 0 2)) (CVar "whole" (ALocal 0 0)))) (arm (PVar "other") () (CTuple (CLit (LInt 0)) (CLit (LInt 0)) (CVar "other" (ALocal 0 0))))) (CTSwitch ((CTBranch HCons (CTDrop (CTSwitch ((CTBranch HCons (CTLeaf 0))) (CTLeaf 1))))) (CTLeaf 1))))) (CBind "const3" (CClause ((PVar "a") (PVar "b") (PVar "c")) (CVar "a" (ALocal 2 0)))) (CBind "neg" (CClause () (CBinPrim "-" (CLit (LInt 0)) (CLit (LInt 5))))) (CBind "vowel" (CClause ((PLit (LChar "a"))) (CVar "True" AGlobal)) (CClause ((PLit (LChar "e"))) (CVar "True" AGlobal)) (CClause ((PVar "c")) (CVar "False" AGlobal))) (CBind "main" (CClause () (CBlock (CSLet false (PVar "part") (CApp (CApp (CVar "const3" AGlobal) (CLit (LInt 1))) (CLit (LInt 2)))) (CSExpr (CTuple (CApp (CApp (CVar "ack" AGlobal) (CLit (LInt 2))) (CLit (LInt 3))) (CApp (CVar "dedup" AGlobal) (CList (CLit (LInt 1)) (CLit (LInt 1)) (CLit (LInt 2)) (CLit (LInt 3)) (CLit (LInt 3)) (CLit (LInt 3)))) (CApp (CVar "firstTwo" AGlobal) (CList (CLit (LInt 7)) (CLit (LInt 8)) (CLit (LInt 9)))) (CApp (CVar "part" (ALocal 0 0)) (CLit (LInt 99))) (CVar "neg" AGlobal) (CApp (CVar "vowel" AGlobal) (CLit (LChar "e"))) (CApp (CVar "vowel" AGlobal) (CLit (LChar "z"))))))))) () () ())
