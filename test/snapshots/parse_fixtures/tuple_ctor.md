# META
source_lines=19
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
-- The bare tuple type constructors `(,)`/`(,,)`/… name the unsaturated n-tuple
-- head in TYPE position: as an impl head (`impl C (,)`) and applied to arguments
-- (`(,) a b` is the same type as `(a, b)`).  Arities 2–5 are accepted.

interface Swap p where
  swap : p a b -> p b a

impl Swap (,) where
  swap (x, y) = (y, x)

fst2 : (,) a b -> a
fst2 (x, _) = x

mid3 : (,,) a b c -> b
mid3 (_, y, _) = y

main =
  println (fst2 (swap (1, 2)))
  println (mid3 (3, 4, 5))
# PARSE
(DInterface false false "Swap" ("p") () ((imethod "swap" (TyFun (TyApp (TyApp (TyVar "p") (TyVar "a")) (TyVar "b")) (TyApp (TyApp (TyVar "p") (TyVar "b")) (TyVar "a"))) None)))
(DImpl false "Swap" ((TyCon "__tuple2__")) () ((im "swap" ((PTuple (PVar "x") (PVar "y"))) (ETuple (EVar "y") (EVar "x")))))
(DTypeSig false "fst2" (TyFun (TyApp (TyApp (TyCon "__tuple2__") (TyVar "a")) (TyVar "b")) (TyVar "a")))
(DFunDef false "fst2" ((PTuple (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "mid3" (TyFun (TyApp (TyApp (TyApp (TyCon "__tuple3__") (TyVar "a")) (TyVar "b")) (TyVar "c")) (TyVar "b")))
(DFunDef false "mid3" ((PTuple PWild (PVar "y") PWild)) (EVar "y"))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "fst2") (EApp (EVar "swap") (ETuple (ELit (LInt 1)) (ELit (LInt 2))))))) (DoExpr (EApp (EVar "println") (EApp (EVar "mid3") (ETuple (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5))))))))
# PRINTER
interface Swap p where
  swap : p a b -> p b a
impl Swap (,) where
  swap (x, y) = (y, x)
fst2 : (,) a b -> a
fst2 (x, _) = x
mid3 : (,,) a b c -> b
mid3 (_, y, _) = y
main =
  println (fst2 (swap (1, 2)))
  println (mid3 (3, 4, 5))
# DESUGAR
(DInterface false false "Swap" ("p") () ((imethod "swap" (TyFun (TyApp (TyApp (TyVar "p") (TyVar "a")) (TyVar "b")) (TyApp (TyApp (TyVar "p") (TyVar "b")) (TyVar "a"))) None)))
(DImpl false "Swap" ((TyCon "__tuple2__")) () ((im "swap" ((PTuple (PVar "x") (PVar "y"))) (ETuple (EVar "y") (EVar "x")))))
(DTypeSig false "fst2" (TyFun (TyApp (TyApp (TyCon "__tuple2__") (TyVar "a")) (TyVar "b")) (TyVar "a")))
(DFunDef false "fst2" ((PTuple (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "mid3" (TyFun (TyApp (TyApp (TyApp (TyCon "__tuple3__") (TyVar "a")) (TyVar "b")) (TyVar "c")) (TyVar "b")))
(DFunDef false "mid3" ((PTuple PWild (PVar "y") PWild)) (EVar "y"))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EVar "println") (EApp (EVar "fst2") (EApp (EVar "swap") (ETuple (ELit (LInt 1)) (ELit (LInt 2))))))) (DoExpr (EApp (EVar "println") (EApp (EVar "mid3") (ETuple (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5))))))))
# MARK
(DInterface false false "Swap" ("p") () ((imethod "swap" (TyFun (TyApp (TyApp (TyVar "p") (TyVar "a")) (TyVar "b")) (TyApp (TyApp (TyVar "p") (TyVar "b")) (TyVar "a"))) None)))
(DImpl false "Swap" ((TyCon "__tuple2__")) () ((im "swap" ((PTuple (PVar "x") (PVar "y"))) (ETuple (EVar "y") (EVar "x")))))
(DTypeSig false "fst2" (TyFun (TyApp (TyApp (TyCon "__tuple2__") (TyVar "a")) (TyVar "b")) (TyVar "a")))
(DFunDef false "fst2" ((PTuple (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "mid3" (TyFun (TyApp (TyApp (TyApp (TyCon "__tuple3__") (TyVar "a")) (TyVar "b")) (TyVar "c")) (TyVar "b")))
(DFunDef false "mid3" ((PTuple PWild (PVar "y") PWild)) (EVar "y"))
(DFunDef false "main" () (EBlock (DoExpr (EApp (EDictApp "println") (EApp (EVar "fst2") (EApp (EMethodRef "swap") (ETuple (ELit (LInt 1)) (ELit (LInt 2))))))) (DoExpr (EApp (EDictApp "println") (EApp (EVar "mid3") (ETuple (ELit (LInt 3)) (ELit (LInt 4)) (ELit (LInt 5))))))))
