# META
source_lines=13
stages=CORE_IR
# SOURCE
-- record create / field access / update / pattern match
data Point = { x : Int, y : Int }
data Box = { label : String, pt : Point }
distSq p = p.x * p.x + p.y * p.y
moveRight p = { p | x = p.x + 1 }
swap p = match p
  Point { x, y } => Point { x = y, y = x }
labelOf b = b.label
main =
  let p = Point { x = 3, y = 4 }
  let q = moveRight p
  let b = Box { label = "origin", pt = Point { x = 0, y = 0 } }
  (p, distSq p, q, distSq q, swap p, labelOf b, b.pt.y)
# CORE_IR
(CProgram ((CBind "distSq" (CClause ((PVar "p")) (CBinPrim "+" (CBinPrim "*" (CFieldAccess (CVar "p" (ALocal 0 0)) "x" "") (CFieldAccess (CVar "p" (ALocal 0 0)) "x" "")) (CBinPrim "*" (CFieldAccess (CVar "p" (ALocal 0 0)) "y" "") (CFieldAccess (CVar "p" (ALocal 0 0)) "y" ""))))) (CBind "moveRight" (CClause ((PVar "p")) (CRecordUpdate "" (CVar "p" (ALocal 0 0)) (cf "x" (CBinPrim "+" (CFieldAccess (CVar "p" (ALocal 0 0)) "x" "") (CLit (LInt 1))))))) (CBind "swap" (CClause ((PVar "p")) (CDecision (CVar "p" (ALocal 0 0)) ((arm (PRec "Point" ((rf "x" None) (rf "y" None)) false) () (CRecord "Point" (cf "x" (CVar "y" (ALocal 0 1))) (cf "y" (CVar "x" (ALocal 0 0)))))) (CTGuard 0 CTFail)))) (CBind "labelOf" (CClause ((PVar "b")) (CFieldAccess (CVar "b" (ALocal 0 0)) "label" ""))) (CBind "main" (CClause () (CBlock (CSLet false (PVar "p") (CRecord "Point" (cf "x" (CLit (LInt 3))) (cf "y" (CLit (LInt 4))))) (CSLet false (PVar "q") (CApp (CVar "moveRight" AGlobal) (CVar "p" (ALocal 0 0)))) (CSLet false (PVar "b") (CRecord "Box" (cf "label" (CLit (LString "origin"))) (cf "pt" (CRecord "Point" (cf "x" (CLit (LInt 0))) (cf "y" (CLit (LInt 0))))))) (CSExpr (CTuple (CVar "p" (ALocal 2 0)) (CApp (CVar "distSq" AGlobal) (CVar "p" (ALocal 2 0))) (CVar "q" (ALocal 1 0)) (CApp (CVar "distSq" AGlobal) (CVar "q" (ALocal 1 0))) (CApp (CVar "swap" AGlobal) (CVar "p" (ALocal 2 0))) (CApp (CVar "labelOf" AGlobal) (CVar "b" (ALocal 0 0))) (CFieldAccess (CFieldAccess (CVar "b" (ALocal 0 0)) "pt" "") "y" ""))))))) ((ca "Point" 2) (ca "Box" 2)) ((ct "Point" "Point") (ct "Box" "Box")) ())
