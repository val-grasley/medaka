# META
source_lines=21
stages=CORE_IR
# SOURCE
-- record patterns through the decision tree (PRec arms with fall-through)
data Vec = { dx : Int, dy : Int }

magnitude v = v.dx * v.dx + v.dy * v.dy

-- multi-arm record match: specific field-value arms fall through in the tree
axis v = match v
  Vec { dx = 0, dy } => dy
  Vec { dx, dy = 0 } => dx
  Vec { dx, dy } => dx + dy

main =
  let up = Vec { dx = 0, dy = 5 }
  let right = Vec { dx = 3, dy = 0 }
  let diag = Vec { dx = 2, dy = 4 }
  ( magnitude up
  , magnitude right
  , axis up
  , axis right
  , axis diag
  )
# CORE_IR
(CProgram ((CBind "magnitude" (CClause ((PVar "v")) (CBinPrim "+" (CBinPrim "*" (CFieldAccess (CVar "v" (ALocal 0 0)) "dx" "") (CFieldAccess (CVar "v" (ALocal 0 0)) "dx" "")) (CBinPrim "*" (CFieldAccess (CVar "v" (ALocal 0 0)) "dy" "") (CFieldAccess (CVar "v" (ALocal 0 0)) "dy" ""))))) (CBind "axis" (CClause ((PVar "v")) (CDecision (CVar "v" (ALocal 0 0)) ((arm (PRec "Vec" ((rf "dx" (PLit (LInt 0))) (rf "dy" None)) false) () (CVar "dy" (ALocal 0 0))) (arm (PRec "Vec" ((rf "dx" None) (rf "dy" (PLit (LInt 0)))) false) () (CVar "dx" (ALocal 0 0))) (arm (PRec "Vec" ((rf "dx" None) (rf "dy" None)) false) () (CBinPrim "+" (CVar "dx" (ALocal 0 0)) (CVar "dy" (ALocal 0 1))))) (CTGuard 0 (CTGuard 1 (CTGuard 2 CTFail)))))) (CBind "main" (CClause () (CBlock (CSLet false (PVar "up") (CRecord "Vec" (cf "dx" (CLit (LInt 0))) (cf "dy" (CLit (LInt 5))))) (CSLet false (PVar "right") (CRecord "Vec" (cf "dx" (CLit (LInt 3))) (cf "dy" (CLit (LInt 0))))) (CSLet false (PVar "diag") (CRecord "Vec" (cf "dx" (CLit (LInt 2))) (cf "dy" (CLit (LInt 4))))) (CSExpr (CTuple (CApp (CVar "magnitude" AGlobal) (CVar "up" (ALocal 2 0))) (CApp (CVar "magnitude" AGlobal) (CVar "right" (ALocal 1 0))) (CApp (CVar "axis" AGlobal) (CVar "up" (ALocal 2 0))) (CApp (CVar "axis" AGlobal) (CVar "right" (ALocal 1 0))) (CApp (CVar "axis" AGlobal) (CVar "diag" (ALocal 0 0))))))))) ((ca "Vec" 2)) ((ct "Vec" "Vec")) ())
