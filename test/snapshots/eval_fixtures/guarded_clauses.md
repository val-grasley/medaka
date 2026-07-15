# META
source_lines=25
stages=CORE_IR
# SOURCE
-- multi-clause functions whose guards fall through to the next clause
-- (desugars to __fallthrough__) — incl. pattern-bind guards and recursion
data Opt = N | J Int
sign n
  | n > 0 = 1
  | n < 0 = 0 - 1
sign _ = 0
firstPos (x :: rest)
  | x > 0 = x
  | otherwise = firstPos rest
firstPos [] = 0 - 1
unwrapOr o d | J v <- o = v
unwrapOr _ d = d
collatzLen n = go n 0
  where
    go 1 acc = acc
    go m acc
      | m % 2 == 0 = go (m / 2) (acc + 1)
      | otherwise = go (3 * m + 1) (acc + 1)
main =
  ( sign 5, sign (0 - 3), sign 0
  , firstPos [0 - 2, 0 - 1, 3, 4], firstPos [0 - 5]
  , unwrapOr (J 7) 0, unwrapOr N 99
  , collatzLen 6, collatzLen 27
  )
# CORE_IR
(CProgram ((CBind "sign" (CClause ((PVar "n")) (CIf (CBinPrim ">" (CVar "n" (ALocal 0 0)) (CLit (LInt 0))) (CLit (LInt 1)) (CIf (CBinPrim "<" (CVar "n" (ALocal 0 0)) (CLit (LInt 0))) (CBinPrim "-" (CLit (LInt 0)) (CLit (LInt 1))) (CApp (CVar "__fallthrough__" AGlobal) (CLit LUnit))))) (CClause (PWild) (CLit (LInt 0)))) (CBind "firstPos" (CClause ((PCons (PVar "x") (PVar "rest"))) (CIf (CBinPrim ">" (CVar "x" (ALocal 0 0)) (CLit (LInt 0))) (CVar "x" (ALocal 0 0)) (CIf (CVar "otherwise" AGlobal) (CApp (CVar "firstPos" AGlobal) (CVar "rest" (ALocal 0 1))) (CApp (CVar "__fallthrough__" AGlobal) (CLit LUnit))))) (CClause ((PList)) (CBinPrim "-" (CLit (LInt 0)) (CLit (LInt 1))))) (CBind "unwrapOr" (CClause ((PVar "o") (PVar "d")) (CDecision (CVar "o" (ALocal 1 0)) ((arm (PCon "J" (PVar "v")) () (CVar "v" (ALocal 0 0))) (arm PWild () (CApp (CVar "__fallthrough__" AGlobal) (CLit LUnit)))) (CTSwitch ((CTBranch (HCon "J" 1) (CTLeaf 0))) (CTLeaf 1)))) (CClause (PWild (PVar "d")) (CVar "d" (ALocal 0 0)))) (CBind "collatzLen" (CClause ((PVar "n")) (CLetGroup ((CBind "go" (CClause ((PLit (LInt 1)) (PVar "acc")) (CVar "acc" (ALocal 0 0))) (CClause ((PVar "m") (PVar "acc")) (CIf (CBinPrim "==" (CBinPrim "%" (CVar "m" (ALocal 1 0)) (CLit (LInt 2))) (CLit (LInt 0))) (CApp (CApp (CVar "go" (ALocal 2 0)) (CBinPrim "/" (CVar "m" (ALocal 1 0)) (CLit (LInt 2)))) (CBinPrim "+" (CVar "acc" (ALocal 0 0)) (CLit (LInt 1)))) (CIf (CVar "otherwise" AGlobal) (CApp (CApp (CVar "go" (ALocal 2 0)) (CBinPrim "+" (CBinPrim "*" (CLit (LInt 3)) (CVar "m" (ALocal 1 0))) (CLit (LInt 1)))) (CBinPrim "+" (CVar "acc" (ALocal 0 0)) (CLit (LInt 1)))) (CApp (CVar "__fallthrough__" AGlobal) (CLit LUnit))))))) (CApp (CApp (CVar "go" (ALocal 0 0)) (CVar "n" (ALocal 1 0))) (CLit (LInt 0)))))) (CBind "main" (CClause () (CTuple (CApp (CVar "sign" AGlobal) (CLit (LInt 5))) (CApp (CVar "sign" AGlobal) (CBinPrim "-" (CLit (LInt 0)) (CLit (LInt 3)))) (CApp (CVar "sign" AGlobal) (CLit (LInt 0))) (CApp (CVar "firstPos" AGlobal) (CList (CBinPrim "-" (CLit (LInt 0)) (CLit (LInt 2))) (CBinPrim "-" (CLit (LInt 0)) (CLit (LInt 1))) (CLit (LInt 3)) (CLit (LInt 4)))) (CApp (CVar "firstPos" AGlobal) (CList (CBinPrim "-" (CLit (LInt 0)) (CLit (LInt 5))))) (CApp (CApp (CVar "unwrapOr" AGlobal) (CApp (CVar "J" AGlobal) (CLit (LInt 7)))) (CLit (LInt 0))) (CApp (CApp (CVar "unwrapOr" AGlobal) (CVar "N" AGlobal)) (CLit (LInt 99))) (CApp (CVar "collatzLen" AGlobal) (CLit (LInt 6))) (CApp (CVar "collatzLen" AGlobal) (CLit (LInt 27))))))) ((ca "N" 0) (ca "J" 1)) ((ct "N" "Opt") (ct "J" "Opt")) ())
