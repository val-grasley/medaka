# META
source_lines=22
stages=CORE_IR
# SOURCE
-- a multi-method interface, dispatch on a recursive ADT, and an Eq-like
-- method that dispatches on its first argument among several impls
interface Sized a where
  size : a -> Int
  isEmpty : a -> Bool
  isEmpty x = size x == 0
data Nat = Z | S Nat
data Tree = Leaf | Branch Tree Tree
impl Sized Nat where
  size Z = 0
  size (S n) = 1 + size n
impl Sized Tree where
  size Leaf = 0
  size (Branch l r) = 1 + size l + size r
interface Combine a where
  combine : a -> a -> a
impl Combine Nat where
  combine Z m = m
  combine (S n) m = S (combine n m)
three = S (S (S Z))
t = Branch (Branch Leaf Leaf) Leaf
main = (size three, isEmpty Z, isEmpty three, size t, isEmpty Leaf, size (combine three (S Z)))
# CORE_IR
(CProgram ((CBind "three" (CClause () (CApp (CVar "S" AGlobal) (CApp (CVar "S" AGlobal) (CApp (CVar "S" AGlobal) (CVar "Z" AGlobal)))))) (CBind "t" (CClause () (CApp (CApp (CVar "Branch" AGlobal) (CApp (CApp (CVar "Branch" AGlobal) (CVar "Leaf" AGlobal)) (CVar "Leaf" AGlobal))) (CVar "Leaf" AGlobal)))) (CBind "main" (CClause () (CTuple (CApp (CVar "size" AGlobal) (CVar "three" AGlobal)) (CApp (CVar "isEmpty" AGlobal) (CVar "Z" AGlobal)) (CApp (CVar "isEmpty" AGlobal) (CVar "three" AGlobal)) (CApp (CVar "size" AGlobal) (CVar "t" AGlobal)) (CApp (CVar "isEmpty" AGlobal) (CVar "Leaf" AGlobal)) (CApp (CVar "size" AGlobal) (CApp (CApp (CVar "combine" AGlobal) (CVar "three" AGlobal)) (CApp (CVar "S" AGlobal) (CVar "Z" AGlobal)))))))) ((ca "Z" 0) (ca "S" 1) (ca "Leaf" 0) (ca "Branch" 2)) ((ct "Z" "Nat") (ct "S" "Nat") (ct "Leaf" "Tree") (ct "Branch" "Tree")) ((CImplEntry "isEmpty" 1 (CImplDefault ((PVar "x")) (CBinPrim "==" (CApp (CVar "size" AGlobal) (CVar "x" (ALocal 0 0))) (CLit (LInt 0))))) (CImplEntry "size" 0 (CImplTagged "Nat" "Sized|Nat|" "Sized" (0) ((PCon "Z")) (CLit (LInt 0)))) (CImplEntry "size" 0 (CImplTagged "Nat" "Sized|Nat|" "Sized" (0) ((PCon "S" (PVar "n"))) (CBinPrim "+" (CLit (LInt 1)) (CApp (CVar "size" AGlobal) (CVar "n" (ALocal 0 0)))))) (CImplEntry "isEmpty" 0 (CImplTagged "Nat" "Sized|Nat|" "Sized" (0) ((PVar "x")) (CBinPrim "==" (CApp (CVar "size" AGlobal) (CVar "x" (ALocal 0 0))) (CLit (LInt 0))))) (CImplEntry "size" 0 (CImplTagged "Tree" "Sized|Tree|" "Sized" (0) ((PCon "Leaf")) (CLit (LInt 0)))) (CImplEntry "size" 0 (CImplTagged "Tree" "Sized|Tree|" "Sized" (0) ((PCon "Branch" (PVar "l") (PVar "r"))) (CBinPrim "+" (CBinPrim "+" (CLit (LInt 1)) (CApp (CVar "size" AGlobal) (CVar "l" (ALocal 0 0)))) (CApp (CVar "size" AGlobal) (CVar "r" (ALocal 0 1)))))) (CImplEntry "isEmpty" 0 (CImplTagged "Tree" "Sized|Tree|" "Sized" (0) ((PVar "x")) (CBinPrim "==" (CApp (CVar "size" AGlobal) (CVar "x" (ALocal 0 0))) (CLit (LInt 0))))) (CImplEntry "combine" 0 (CImplTagged "Nat" "Combine|Nat|" "Combine" (0 1) ((PCon "Z") (PVar "m")) (CVar "m" (ALocal 0 0)))) (CImplEntry "combine" 0 (CImplTagged "Nat" "Combine|Nat|" "Combine" (0 1) ((PCon "S" (PVar "n")) (PVar "m")) (CApp (CVar "S" AGlobal) (CApp (CApp (CVar "combine" AGlobal) (CVar "n" (ALocal 1 0))) (CVar "m" (ALocal 0 0))))))))
