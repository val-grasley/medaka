# META
source_lines=26
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
-- Declaration/expression forms the self-hosted parser was hardened to accept:
-- type aliases, newtypes (with/without deriving), top-level mutually-recursive
-- let-groups (each as its own `let rec`), declaration attributes, and
-- Map/Set literals.

type Name = String
type Wrapper a = Option a

newtype UserId = UserId Int
newtype Age = Age Int deriving (Eq, Ord)

let rec isEven = n => if n == 0 then True else isOdd (n - 1)
let rec isOdd = n => if n == 0 then False else isEven (n - 1)

@inline
double x = x + x

@deprecated "use double"
twice x = x + x

@must_use
important x = x

scores = Map { "a" => 1, "b" => 2 }
emptyish = Set { 1, 2, 3 }
nested = Map { "k" => Set { 1, 2 } }
# PARSE
(DTypeAlias false "Name" () (TyCon "String"))
(DTypeAlias false "Wrapper" ("a") (TyApp (TyCon "Option") (TyVar "a")))
(DNewtype false "UserId" () "UserId" (TyCon "Int") ())
(DNewtype false "Age" () "Age" (TyCon "Int") ("Eq" "Ord"))
(DLetGroup false ((lgb "isEven" (clause () (ELam ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "True") (EApp (EVar "isOdd") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))))))
(DLetGroup false ((lgb "isOdd" (clause () (ELam ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "False") (EApp (EVar "isEven") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))))))
(DAttrib (AttrInline) (DFunDef false "double" ((PVar "x")) (EBinOp "+" (EVar "x") (EVar "x"))))
(DAttrib ((AttrDeprecated "use double")) (DFunDef false "twice" ((PVar "x")) (EBinOp "+" (EVar "x") (EVar "x"))))
(DAttrib (AttrMustUse) (DFunDef false "important" ((PVar "x")) (EVar "x")))
(DFunDef false "scores" () (EMapLit "Map" ((kv (ELit (LString "a")) (ELit (LInt 1))) (kv (ELit (LString "b")) (ELit (LInt 2))))))
(DFunDef false "emptyish" () (ESetLit "Set" ((ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))))
(DFunDef false "nested" () (EMapLit "Map" ((kv (ELit (LString "k")) (ESetLit "Set" ((ELit (LInt 1)) (ELit (LInt 2))))))))
# PRINTER
type Name = String
type Wrapper a = Option a
newtype UserId = UserId Int
newtype Age = Age Int deriving (Eq, Ord)
let rec isEven = n => if n == 0 then True else isOdd (n - 1)
let rec isOdd = n => if n == 0 then False else isEven (n - 1)
@inline
double x = x + x
@deprecated "use double"
twice x = x + x
@must_use
important x = x
scores = Map { "a" => 1, "b" => 2 }
emptyish = Set { 1, 2, 3 }
nested = Map { "k" => Set { 1, 2 } }
# DESUGAR
(DTypeAlias false "Name" () (TyCon "String"))
(DTypeAlias false "Wrapper" ("a") (TyApp (TyCon "Option") (TyVar "a")))
(DNewtype false "UserId" () "UserId" (TyCon "Int") ())
(DNewtype false "Age" () "Age" (TyCon "Int") ())
(DImpl true "Eq" ((TyCon "Age")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Age" (PVar "__a0")) (PCon "Age" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Ord" ((TyCon "Age")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Age" (PVar "__a0")) (PCon "Age" (PVar "__b0"))) () (EApp (EApp (EVar "compare") (EVar "__a0")) (EVar "__b0")))))))
(DLetGroup false ((lgb "isEven" (clause () (ELam ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "True") (EApp (EVar "isOdd") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))))))
(DLetGroup false ((lgb "isOdd" (clause () (ELam ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "False") (EApp (EVar "isEven") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))))))
(DAttrib (AttrInline) (DFunDef false "double" ((PVar "x")) (EBinOp "+" (EVar "x") (EVar "x"))))
(DAttrib ((AttrDeprecated "use double")) (DFunDef false "twice" ((PVar "x")) (EBinOp "+" (EVar "x") (EVar "x"))))
(DAttrib (AttrMustUse) (DFunDef false "important" ((PVar "x")) (EVar "x")))
(DFunDef false "scores" () (EHeadAnnot (EApp (EVar "fromEntries") (EListLit (ETuple (ELit (LString "a")) (ELit (LInt 1))) (ETuple (ELit (LString "b")) (ELit (LInt 2))))) (TyApp (TyApp (TyCon "Map") (TyVar "_k")) (TyVar "_v"))))
(DFunDef false "emptyish" () (EHeadAnnot (EApp (EVar "fromEntries") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (TyApp (TyCon "Set") (TyVar "_a"))))
(DFunDef false "nested" () (EHeadAnnot (EApp (EVar "fromEntries") (EListLit (ETuple (ELit (LString "k")) (EHeadAnnot (EApp (EVar "fromEntries") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (TyApp (TyCon "Set") (TyVar "_a")))))) (TyApp (TyApp (TyCon "Map") (TyVar "_k")) (TyVar "_v"))))
# MARK
(DTypeAlias false "Name" () (TyCon "String"))
(DTypeAlias false "Wrapper" ("a") (TyApp (TyCon "Option") (TyVar "a")))
(DNewtype false "UserId" () "UserId" (TyCon "Int") ())
(DNewtype false "Age" () "Age" (TyCon "Int") ())
(DImpl true "Eq" ((TyCon "Age")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Age" (PVar "__a0")) (PCon "Age" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Ord" ((TyCon "Age")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Age" (PVar "__a0")) (PCon "Age" (PVar "__b0"))) () (EApp (EApp (EMethodRef "compare") (EVar "__a0")) (EVar "__b0")))))))
(DLetGroup false ((lgb "isEven" (clause () (ELam ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "True") (EApp (EVar "isOdd") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))))))
(DLetGroup false ((lgb "isOdd" (clause () (ELam ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "False") (EApp (EVar "isEven") (EBinOp "-" (EVar "n") (ELit (LInt 1))))))))))
(DAttrib (AttrInline) (DFunDef false "double" ((PVar "x")) (EBinOp "+" (EVar "x") (EVar "x"))))
(DAttrib ((AttrDeprecated "use double")) (DFunDef false "twice" ((PVar "x")) (EBinOp "+" (EVar "x") (EVar "x"))))
(DAttrib (AttrMustUse) (DFunDef false "important" ((PVar "x")) (EVar "x")))
(DFunDef false "scores" () (EHeadAnnot (EApp (EMethodRef "fromEntries") (EListLit (ETuple (ELit (LString "a")) (ELit (LInt 1))) (ETuple (ELit (LString "b")) (ELit (LInt 2))))) (TyApp (TyApp (TyCon "Map") (TyVar "_k")) (TyVar "_v"))))
(DFunDef false "emptyish" () (EHeadAnnot (EApp (EMethodRef "fromEntries") (EListLit (ELit (LInt 1)) (ELit (LInt 2)) (ELit (LInt 3)))) (TyApp (TyCon "Set") (TyVar "_a"))))
(DFunDef false "nested" () (EHeadAnnot (EApp (EMethodRef "fromEntries") (EListLit (ETuple (ELit (LString "k")) (EHeadAnnot (EApp (EMethodRef "fromEntries") (EListLit (ELit (LInt 1)) (ELit (LInt 2)))) (TyApp (TyCon "Set") (TyVar "_a")))))) (TyApp (TyApp (TyCon "Map") (TyVar "_k")) (TyVar "_v"))))
