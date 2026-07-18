# META
source_lines=12
stages=CORE_IR
# SOURCE
-- array literals, indexing, ranges (list + array), slices
arr = [|10, 20, 30, 40, 50|]
xs = [1..5]
ys = [0..=4]
zs = [|2..6|]
sumList [] = 0
sumList (x :: xs) = x + sumList xs
main =
  let a3 = arrayGetUnsafe 3 arr
  let mid = arr.[1..3]
  let lst = xs.[1..=3]
  (a3, mid, xs, ys, zs, lst, sumList xs, arrayGetUnsafe 0 arr + arrayGetUnsafe 4 arr)
# CORE_IR
(CProgram ((CBind "arr" (CClause () (CArray (CLit (LInt 10)) (CLit (LInt 20)) (CLit (LInt 30)) (CLit (LInt 40)) (CLit (LInt 50))))) (CBind "xs" (CClause () (CRangeList (CLit (LInt 1)) (CLit (LInt 5)) false))) (CBind "ys" (CClause () (CRangeList (CLit (LInt 0)) (CLit (LInt 4)) true))) (CBind "zs" (CClause () (CRangeArray (CLit (LInt 2)) (CLit (LInt 6)) false))) (CBind "sumList" (CClause ((PList)) (CLit (LInt 0))) (CClause ((PCons (PVar "x") (PVar "xs"))) (CBinPrim "+" (CVar "x" (ALocal 0 0)) (CApp (CVar "sumList" AGlobal) (CVar "xs" (ALocal 0 1)))))) (CBind "main" (CClause () (CBlock (CSLet false (PVar "a3") (CApp (CApp (CVar "arrayGetUnsafe" AGlobal) (CLit (LInt 3))) (CVar "arr" AGlobal))) (CSLet false (PVar "mid") (CApp (CApp (CApp (CApp (CVar "sliceRange" AGlobal) (CVar "arr" AGlobal)) (CLit (LInt 1))) (CLit (LInt 3))) (CLit (LBool false)))) (CSLet false (PVar "lst") (CApp (CApp (CApp (CApp (CVar "sliceRange" AGlobal) (CVar "xs" AGlobal)) (CLit (LInt 1))) (CLit (LInt 3))) (CLit (LBool true)))) (CSExpr (CTuple (CVar "a3" (ALocal 2 0)) (CVar "mid" (ALocal 1 0)) (CVar "xs" AGlobal) (CVar "ys" AGlobal) (CVar "zs" AGlobal) (CVar "lst" (ALocal 0 0)) (CApp (CVar "sumList" AGlobal) (CVar "xs" AGlobal)) (CBinPrim "+" (CApp (CApp (CVar "arrayGetUnsafe" AGlobal) (CLit (LInt 0))) (CVar "arr" AGlobal)) (CApp (CApp (CVar "arrayGetUnsafe" AGlobal) (CLit (LInt 4))) (CVar "arr" AGlobal))))))))) () () ())
