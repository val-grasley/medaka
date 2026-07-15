# META
source_lines=12
stages=CORE_IR
# SOURCE
-- ADTs with payloads, nested pattern matching, recursion over a tree
data Tree = Leaf Int | Node Tree Tree
sumT (Leaf n) = n
sumT (Node l r) = sumT l + sumT r
depth (Leaf _) = 1
depth (Node l r) = 1 + maxI (depth l) (depth r)
maxI a b = if a > b then a else b
data Opt = Non | Som Int
unwrap Non d = d
unwrap (Som x) _ = x
t = Node (Node (Leaf 1) (Leaf 2)) (Leaf 3)
main = (sumT t, depth t, unwrap (Som 7) 0, unwrap Non 99, Node (Leaf 1) (Leaf 2))
# CORE_IR
(CProgram ((CBind "sumT" (CClause ((PCon "Leaf" (PVar "n"))) (CVar "n" (ALocal 0 0))) (CClause ((PCon "Node" (PVar "l") (PVar "r"))) (CBinPrim "+" (CApp (CVar "sumT" AGlobal) (CVar "l" (ALocal 0 0))) (CApp (CVar "sumT" AGlobal) (CVar "r" (ALocal 0 1)))))) (CBind "depth" (CClause ((PCon "Leaf" PWild)) (CLit (LInt 1))) (CClause ((PCon "Node" (PVar "l") (PVar "r"))) (CBinPrim "+" (CLit (LInt 1)) (CApp (CApp (CVar "maxI" AGlobal) (CApp (CVar "depth" AGlobal) (CVar "l" (ALocal 0 0)))) (CApp (CVar "depth" AGlobal) (CVar "r" (ALocal 0 1))))))) (CBind "maxI" (CClause ((PVar "a") (PVar "b")) (CIf (CBinPrim ">" (CVar "a" (ALocal 1 0)) (CVar "b" (ALocal 0 0))) (CVar "a" (ALocal 1 0)) (CVar "b" (ALocal 0 0))))) (CBind "unwrap" (CClause ((PCon "Non") (PVar "d")) (CVar "d" (ALocal 0 0))) (CClause ((PCon "Som" (PVar "x")) PWild) (CVar "x" (ALocal 1 0)))) (CBind "t" (CClause () (CApp (CApp (CVar "Node" AGlobal) (CApp (CApp (CVar "Node" AGlobal) (CApp (CVar "Leaf" AGlobal) (CLit (LInt 1)))) (CApp (CVar "Leaf" AGlobal) (CLit (LInt 2))))) (CApp (CVar "Leaf" AGlobal) (CLit (LInt 3)))))) (CBind "main" (CClause () (CTuple (CApp (CVar "sumT" AGlobal) (CVar "t" AGlobal)) (CApp (CVar "depth" AGlobal) (CVar "t" AGlobal)) (CApp (CApp (CVar "unwrap" AGlobal) (CApp (CVar "Som" AGlobal) (CLit (LInt 7)))) (CLit (LInt 0))) (CApp (CApp (CVar "unwrap" AGlobal) (CVar "Non" AGlobal)) (CLit (LInt 99))) (CApp (CApp (CVar "Node" AGlobal) (CApp (CVar "Leaf" AGlobal) (CLit (LInt 1)))) (CApp (CVar "Leaf" AGlobal) (CLit (LInt 2)))))))) ((ca "Leaf" 1) (ca "Node" 2) (ca "Non" 0) (ca "Som" 1)) ((ct "Leaf" "Tree") (ct "Node" "Tree") (ct "Non" "Opt") (ct "Som" "Opt")) ())
