# META
source_lines=338
stages=DESUGAR,MARK
# SOURCE
-- Structural S-expression dump of the self-host AST, mirroring dev/astdump.ml
-- byte-for-byte so the self-hosted parser can be diffed against the OCaml
-- reference.  Tags are the lib/ast.ml constructor names.  Coverage grows with
-- the AST/parser; new variants get a matching clause here.

import frontend.ast.{
  DeriveRef(..),
  deriveRefName,
  Lit(..),
  Ty(..),
  Constraint(..),
  Pat(..),
  RecPatField(..),
  Guard(..),
  Arm(..),
  DoStmt(..),
  InterpPart(..),
  GuardArm(..),
  FieldAssign(..),
  Section(..),
  FunClause(..),
  LetBind(..),
  Expr(..),
  UseMember(..),
  UsePath(..),
  PropParam(..),
  MethodDefault(..),
  IfaceMethod(..),
  Super(..),
  Require(..),
  ImplMethod(..),
  DataVis(..),
  Field(..),
  ConPayload(..),
  Variant(..),
  Decl(..),
  Attr(..),
}
import support.util.{escStr, joinNl, joinWith}

export boolStr : Bool -> String
boolStr True = "true"
boolStr False = "false"

-- O(total) join via `stringConcat` (see util.joinWith) — was a right-recursive
-- `y ++ " " ++ joinSp rest`, quadratic in the serialized output size.
joinSp : List String -> String
joinSp xs = joinWith " " xs

export node : String -> List String -> String
node tag parts = "(" ++ joinSp (tag::parts) ++ ")"

export slist : List String -> String
slist xs = "(" ++ joinSp xs ++ ")"

export litSexp : Lit -> String
litSexp (LInt n) = node "LInt" [intToString n]
litSexp (LFloat f) = node "LFloat" [floatToString f]
litSexp (LString s) = node "LString" [escStr s]
litSexp (LChar s) = node "LChar" [escStr s]
litSexp (LBool b) = node "LBool" [boolStr b]
litSexp LUnit = "LUnit"

export patSexp : Pat -> String
patSexp (PVar x) = node "PVar" [escStr x]
patSexp PWild = "PWild"
patSexp (PLit l) = node "PLit" [litSexp l]
patSexp (PCon c ps) = node "PCon" (escStr c :: map patSexp ps)
patSexp (PCons a b) = node "PCons" [patSexp a, patSexp b]
patSexp (PTuple ps) = node "PTuple" (map patSexp ps)
patSexp (PList ps) = node "PList" (map patSexp ps)
patSexp (PAs x q) = node "PAs" [escStr x, patSexp q]
patSexp (PRng lo hi incl) = node "PRng" [litSexp lo, litSexp hi, boolStr incl]
patSexp (PRec name fields rest) =
  node "PRec" [escStr name, slist (map recPatFieldSexp fields), boolStr rest]

recPatFieldSexp : RecPatField -> String
recPatFieldSexp (RecPatField f (Some p)) = node "rf" [escStr f, patSexp p]
recPatFieldSexp (RecPatField f None) = node "rf" [escStr f, "None"]

tySexp : Ty -> String
tySexp (TyCon c _) = node "TyCon" [escStr c]
tySexp (TyVar v) = node "TyVar" [escStr v]
tySexp (TyApp a b) = node "TyApp" [tySexp a, tySexp b]
tySexp (TyFun a b) = node "TyFun" [tySexp a, tySexp b]
tySexp (TyTuple ts) = node "TyTuple" (map tySexp ts)
tySexp (TyEffect labels tail t) =
  node "TyEffect" [slist (map effAtomSexp labels), optStrSexp tail, tySexp t]
tySexp (TyConstrained cs t) =
  node "TyConstrained" [slist (map constraintSexp cs), tySexp t]

constraintSexp : Constraint -> String
constraintSexp (Constraint iface args) =
  node "cstr" (escStr iface :: map tySexp args)

export optStrSexp : Option String -> String
optStrSexp (Some s) = node "Some" [escStr s]
optStrSexp None = "None"

-- a row atom: a bare label, or `(atom Net "pat")` when parameterized.
effAtomSexp : (String, Option String) -> String
effAtomSexp (l, None) = escStr l
effAtomSexp (l, Some "_") = node "hole" [escStr l]  -- v2 Stage 2b inferred hole
effAtomSexp (l, Some s) = node "atom" [escStr l, escStr s]

guardSexp : Guard -> String
guardSexp (GBool e) = node "GBool" [exprSexp e]
guardSexp (GBind p e) = node "GBind" [patSexp p, exprSexp e]

armSexp : Arm -> String
armSexp (Arm p gs body) =
  node "arm" [patSexp p, slist (map guardSexp gs), exprSexp body]

export exprSexp : Expr -> String
-- ELoc is TRANSPARENT in the structural dump (mirror of dev/astdump.ml:69
-- `ELoc(_,e) -> sexp_expr e`): the parse/sexp gates stay byte-identical to the
-- OCaml oracle, which strips locs before dumping.
exprSexp (ELoc _ e) = exprSexp e
exprSexp (EDoOrigin _ e) = exprSexp e
exprSexp (ELit l) = node "ELit" [litSexp l]
-- PLAN.md #11: render an `ENumLit` exactly as `(ELit (LInt n))` so the compiler
-- sexp/astdump stays byte-identical to the OCaml side (whose astdump does the
-- same) and the parse-fixture / OCaml↔compiler sexp diff gates keep passing.
exprSexp (ENumLit n _ _) = node "ELit" [node "LInt" [intToString n]]
exprSexp (EVar x) = node "EVar" [escStr x]
-- EVarAt/EMethodAt are elaborated nodes introduced by annotate/typecheck
-- (post-resolve); programToSexp only ever serializes pre-annotate (desugared)
-- ASTs, so these arms are unreachable.
exprSexp (EVarAt _ _) =
  panic
    "unreachable: programToSexp serializes pre-annotate ASTs; EVarAt is introduced by annotateProgram"
exprSexp (EMethodAt _ _ _ _) =
  panic
    "unreachable: programToSexp serializes pre-annotate ASTs; EMethodAt is introduced by typecheck elaboration"
exprSexp (EDictAt _ _) =
  panic
    "unreachable: programToSexp serializes pre-annotate ASTs; EDictAt is introduced by typecheck elaboration"
exprSexp (EApp f x) = node "EApp" [exprSexp f, exprSexp x]
exprSexp (ELam ps b) = node "ELam" [slist (map patSexp ps), exprSexp b]
exprSexp (ELet m _isf p e1 e2) =
  node "ELet" [boolStr m, patSexp p, exprSexp e1, exprSexp e2]
exprSexp (EMatch s arms) = node "EMatch" (exprSexp s :: map armSexp arms)
exprSexp (EIf c t el) = node "EIf" [exprSexp c, exprSexp t, exprSexp el]
exprSexp (EBinOp op a b _) = node "EBinOp" [escStr op, exprSexp a, exprSexp b]
exprSexp (EUnOp op a _) = node "EUnOp" [escStr op, exprSexp a]
exprSexp (EInfix op a b) = node "EInfix" [escStr op, exprSexp a, exprSexp b]
exprSexp (EFieldAccess e f _) = node "EFieldAccess" [exprSexp e, escStr f]
exprSexp (ETuple es) = node "ETuple" (map exprSexp es)
exprSexp (EListLit es) = node "EListLit" (map exprSexp es)
exprSexp (EArrayLit es) = node "EArrayLit" (map exprSexp es)
exprSexp (ERangeList lo hi incl) =
  node "ERangeList" [exprSexp lo, exprSexp hi, boolStr incl]
exprSexp (ERangeArray lo hi incl) =
  node "ERangeArray" [exprSexp lo, exprSexp hi, boolStr incl]
exprSexp (ESlice e lo hi incl _) =
  node "ESlice" [exprSexp e, exprSexp lo, exprSexp hi, boolStr incl]
exprSexp (ELetGroup binds body) =
  node "ELetGroup" [slist (map letBindSexp binds), exprSexp body]
exprSexp (ESection s) = node "ESection" [sectionSexp s]
exprSexp (EIndex a i _) = node "EIndex" [exprSexp a, exprSexp i]
exprSexp (EAnnot e t) = node "EAnnot" [exprSexp e, tySexp t]
exprSexp (EHeadAnnot e t) = node "EHeadAnnot" [exprSexp e, tySexp t]
exprSexp (EBlock stmts) = node "EBlock" (map doStmtSexp stmts)
exprSexp (EDo stmts) = node "EDo" (map doStmtSexp stmts)
exprSexp (EStringInterp parts) = node "EStringInterp" (map interpPartSexp parts)
exprSexp (EGuards arms) = node "EGuards" (map guardArmSexp arms)
exprSexp (ERecordCreate n fs) =
  node "ERecordCreate" [escStr n, slist (map fieldAssignSexp fs)]
exprSexp (ERecordUpdate e fs _) =
  node "ERecordUpdate" [exprSexp e, slist (map fieldAssignSexp fs)]
exprSexp (EVariantUpdate c e fs) =
  node "EVariantUpdate" [escStr c, exprSexp e, slist (map fieldAssignSexp fs)]
exprSexp (EMapLit n kvs) = node "EMapLit" [escStr n, slist (map kvSexp kvs)]
exprSexp (ESetLit n es) = node "ESetLit" [escStr n, slist (map exprSexp es)]
exprSexp (EAsPat x e) = node "EAsPat" [escStr x, exprSexp e]
exprSexp (EMethodRef name) = node "EMethodRef" [escStr name]
exprSexp (EDictApp name) = node "EDictApp" [escStr name]

sectionSexp : Section -> String
sectionSexp (SecBare op) = node "SecBare" [escStr op]
sectionSexp (SecRight op e) = node "SecRight" [escStr op, exprSexp e]
sectionSexp (SecLeft e op) = node "SecLeft" [exprSexp e, escStr op]

interpPartSexp : InterpPart -> String
interpPartSexp (InterpStr s) = node "InterpStr" [escStr s]
interpPartSexp (InterpExpr e) = node "InterpExpr" [exprSexp e]

guardArmSexp : GuardArm -> String
guardArmSexp (GuardArm gs body) =
  node "garm" [slist (map guardSexp gs), exprSexp body]

fieldAssignSexp : FieldAssign -> String
fieldAssignSexp (FieldAssign n e) = node "fa" [escStr n, exprSexp e]

kvSexp : (Expr, Expr) -> String
kvSexp (k, v) = node "kv" [exprSexp k, exprSexp v]

letBindSexp : LetBind -> String
letBindSexp (LetBind name clauses) =
  node "lgb" (escStr name :: map funClauseSexp clauses)

funClauseSexp : FunClause -> String
funClauseSexp (FunClause pats body) =
  node "clause" [slist (map patSexp pats), exprSexp body]

doStmtSexp : DoStmt -> String
doStmtSexp (DoExpr e) = node "DoExpr" [exprSexp e]
doStmtSexp (DoBind p e) = node "DoBind" [patSexp p, exprSexp e]
doStmtSexp (DoLet m r p e) =
  node "DoLet" [boolStr m, boolStr r, patSexp p, exprSexp e]
doStmtSexp (DoAssign x e) = node "DoAssign" [escStr x, exprSexp e]
doStmtSexp (DoFieldAssign x fs e) =
  node "DoFieldAssign" [escStr x, slist (map escStr fs), exprSexp e]

visSexp : DataVis -> String
visSexp VisPrivate = "Private"
visSexp VisAbstract = "Abstract"
visSexp VisPublic = "Public"

fieldSexp : Field -> String
fieldSexp (Field n t) = node "field" [escStr n, tySexp t]

payloadSexp : ConPayload -> String
payloadSexp (ConPos tys) = node "ConPos" (map tySexp tys)
payloadSexp (ConNamed fs _) = node "ConNamed" (map fieldSexp fs)

variantSexp : Variant -> String
variantSexp (Variant n pl) = node "variant" [escStr n, payloadSexp pl]

declSexp : Decl -> String
declSexp (DTypeSig p n t) = node "DTypeSig" [boolStr p, escStr n, tySexp t]
declSexp (DExtern p n t) = node "DExtern" [boolStr p, escStr n, tySexp t]
declSexp (DFunDef p n ps b) =
  node "DFunDef" [boolStr p, escStr n, slist (map patSexp ps), exprSexp b]
declSexp (DData vis n ps vs ds) = node
  "DData"
  [
    visSexp vis,
    escStr n,
    slist (map escStr ps),
    slist (map variantSexp vs),
    slist (map (d => escStr (deriveRefName d)) ds),
  ]
declSexp (DUse pub path _) = node "DUse" [boolStr pub, usePathSexp path]
declSexp (DEffect pub n dom) =
  node "DEffect" [boolStr pub, escStr n, optStrSexp dom]
declSexp (DProp pub name params body) = node
  "DProp"
  [boolStr pub, escStr name, slist (map propParamSexp params), exprSexp body]
declSexp (DTest pub name body) =
  node "DTest" [boolStr pub, escStr name, exprSexp body]
declSexp (DBench pub name body) =
  node "DBench" [boolStr pub, escStr name, exprSexp body]
declSexp (DTypeAlias p n ps t) =
  node "DTypeAlias" [boolStr p, escStr n, slist (map escStr ps), tySexp t]
declSexp (DNewtype p n ps con fty ds) = node
  "DNewtype"
  [
    boolStr p,
    escStr n,
    slist (map escStr ps),
    escStr con,
    tySexp fty,
    slist (map (d => escStr (deriveRefName d)) ds),
  ]
declSexp (DLetGroup p binds) =
  node "DLetGroup" [boolStr p, slist (map letBindSexp binds)]
declSexp (DAttrib attrs d) =
  node "DAttrib" [slist (map attrSexp attrs), declSexp d]

declSexp (DInterface { pub, def, name, typarams, supers, methods }) = node
  "DInterface"
  [
    boolStr pub,
    boolStr def,
    escStr name,
    slist (map escStr typarams),
    slist (map superSexp supers),
    slist (map ifaceMethodSexp methods),
  ]
declSexp (DImpl { pub, iface, tys, reqs, methods }) = node
  "DImpl"
  [
    boolStr pub,
    escStr iface,
    slist (map tySexp tys),
    slist (map requireSexp reqs),
    slist (map implMethodSexp methods),
  ]

attrSexp : Attr -> String
attrSexp (AttrDeprecated s) = node "AttrDeprecated" [escStr s]
attrSexp AttrInline = "AttrInline"
attrSexp AttrMustUse = "AttrMustUse"

propParamSexp : PropParam -> String
propParamSexp (PropParam n t) = node "pp" [escStr n, tySexp t]

methodDefaultSexp : Option MethodDefault -> String
methodDefaultSexp None = "None"
methodDefaultSexp (Some (MethodDefault pats body)) =
  node "mdef" [slist (map patSexp pats), exprSexp body]

ifaceMethodSexp : IfaceMethod -> String
ifaceMethodSexp (IfaceMethod name ty def) =
  node "imethod" [escStr name, tySexp ty, methodDefaultSexp def]

superSexp : Super -> String
superSexp (Super iface params) =
  node "super" [escStr iface, slist (map escStr params)]

requireSexp : Require -> String
requireSexp (Require iface tys) =
  node "req" [escStr iface, slist (map tySexp tys)]

implMethodSexp : ImplMethod -> String
implMethodSexp (ImplMethod name pats body) =
  node "im" [escStr name, slist (map patSexp pats), exprSexp body]

-- loc-free by design (mirrors tySexp/declSexp) — keeps .mark/.desugar goldens
-- byte-identical since imports erase before codegen.
useMemberSexp : UseMember -> String
-- An un-aliased member keeps its historical 2-field shape, so every existing golden is
-- byte-identical; only `a as b` adds the third field.
useMemberSexp (UseMember n withAll _ alias) = match alias
  Some a => node "mem" [escStr n, boolStr withAll, escStr a]
  None => node "mem" [escStr n, boolStr withAll]

usePathSexp : UsePath -> String
usePathSexp (UseName ids) = node "UseName" [slist (map escStr ids)]
usePathSexp (UseGroup ids ms) =
  node "UseGroup" [slist (map escStr ids), slist (map useMemberSexp ms)]
usePathSexp (UseWild ids) = node "UseWild" [slist (map escStr ids)]
usePathSexp (UseAlias ids a) =
  node "UseAlias" [slist (map escStr ids), escStr a]

export programToSexp : List Decl -> String
programToSexp prog = joinNl (map declSexp prog)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "DeriveRef" true) (mem "deriveRefName" false) (mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true) (mem "Attr" true))))
(DUse false (UseGroup ("support" "util") ((mem "escStr" false) (mem "joinNl" false) (mem "joinWith" false))))
(DTypeSig true "boolStr" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "boolStr" ((PCon "True")) (ELit (LString "true")))
(DFunDef false "boolStr" ((PCon "False")) (ELit (LString "false")))
(DTypeSig false "joinSp" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSp" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "xs")))
(DTypeSig true "node" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "node" ((PVar "tag") (PVar "parts")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "joinSp") (EBinOp "::" (EVar "tag") (EVar "parts")))) (ELit (LString ")"))))
(DTypeSig true "slist" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "slist" ((PVar "xs")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "joinSp") (EVar "xs"))) (ELit (LString ")"))))
(DTypeSig true "litSexp" (TyFun (TyCon "Lit") (TyCon "String")))
(DFunDef false "litSexp" ((PCon "LInt" (PVar "n"))) (EApp (EApp (EVar "node") (ELit (LString "LInt"))) (EListLit (EApp (EVar "intToString") (EVar "n")))))
(DFunDef false "litSexp" ((PCon "LFloat" (PVar "f"))) (EApp (EApp (EVar "node") (ELit (LString "LFloat"))) (EListLit (EApp (EVar "floatToString") (EVar "f")))))
(DFunDef false "litSexp" ((PCon "LString" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "LString"))) (EListLit (EApp (EVar "escStr") (EVar "s")))))
(DFunDef false "litSexp" ((PCon "LChar" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "LChar"))) (EListLit (EApp (EVar "escStr") (EVar "s")))))
(DFunDef false "litSexp" ((PCon "LBool" (PVar "b"))) (EApp (EApp (EVar "node") (ELit (LString "LBool"))) (EListLit (EApp (EVar "boolStr") (EVar "b")))))
(DFunDef false "litSexp" ((PCon "LUnit")) (ELit (LString "LUnit")))
(DTypeSig true "patSexp" (TyFun (TyCon "Pat") (TyCon "String")))
(DFunDef false "patSexp" ((PCon "PVar" (PVar "x"))) (EApp (EApp (EVar "node") (ELit (LString "PVar"))) (EListLit (EApp (EVar "escStr") (EVar "x")))))
(DFunDef false "patSexp" ((PCon "PWild")) (ELit (LString "PWild")))
(DFunDef false "patSexp" ((PCon "PLit" (PVar "l"))) (EApp (EApp (EVar "node") (ELit (LString "PLit"))) (EListLit (EApp (EVar "litSexp") (EVar "l")))))
(DFunDef false "patSexp" ((PCon "PCon" (PVar "c") (PVar "ps"))) (EApp (EApp (EVar "node") (ELit (LString "PCon"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "c")) (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "ps")))))
(DFunDef false "patSexp" ((PCon "PCons" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "node") (ELit (LString "PCons"))) (EListLit (EApp (EVar "patSexp") (EVar "a")) (EApp (EVar "patSexp") (EVar "b")))))
(DFunDef false "patSexp" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "node") (ELit (LString "PTuple"))) (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "ps"))))
(DFunDef false "patSexp" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "node") (ELit (LString "PList"))) (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "ps"))))
(DFunDef false "patSexp" ((PCon "PAs" (PVar "x") (PVar "q"))) (EApp (EApp (EVar "node") (ELit (LString "PAs"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EVar "patSexp") (EVar "q")))))
(DFunDef false "patSexp" ((PCon "PRng" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "PRng"))) (EListLit (EApp (EVar "litSexp") (EVar "lo")) (EApp (EVar "litSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "patSexp" ((PCon "PRec" (PVar "name") (PVar "fields") (PVar "rest"))) (EApp (EApp (EVar "node") (ELit (LString "PRec"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "recPatFieldSexp")) (EVar "fields"))) (EApp (EVar "boolStr") (EVar "rest")))))
(DTypeSig false "recPatFieldSexp" (TyFun (TyCon "RecPatField") (TyCon "String")))
(DFunDef false "recPatFieldSexp" ((PCon "RecPatField" (PVar "f") (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "node") (ELit (LString "rf"))) (EListLit (EApp (EVar "escStr") (EVar "f")) (EApp (EVar "patSexp") (EVar "p")))))
(DFunDef false "recPatFieldSexp" ((PCon "RecPatField" (PVar "f") (PCon "None"))) (EApp (EApp (EVar "node") (ELit (LString "rf"))) (EListLit (EApp (EVar "escStr") (EVar "f")) (ELit (LString "None")))))
(DTypeSig false "tySexp" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "tySexp" ((PCon "TyCon" (PVar "c") PWild)) (EApp (EApp (EVar "node") (ELit (LString "TyCon"))) (EListLit (EApp (EVar "escStr") (EVar "c")))))
(DFunDef false "tySexp" ((PCon "TyVar" (PVar "v"))) (EApp (EApp (EVar "node") (ELit (LString "TyVar"))) (EListLit (EApp (EVar "escStr") (EVar "v")))))
(DFunDef false "tySexp" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "node") (ELit (LString "TyApp"))) (EListLit (EApp (EVar "tySexp") (EVar "a")) (EApp (EVar "tySexp") (EVar "b")))))
(DFunDef false "tySexp" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "node") (ELit (LString "TyFun"))) (EListLit (EApp (EVar "tySexp") (EVar "a")) (EApp (EVar "tySexp") (EVar "b")))))
(DFunDef false "tySexp" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "node") (ELit (LString "TyTuple"))) (EApp (EApp (EVar "map") (EVar "tySexp")) (EVar "ts"))))
(DFunDef false "tySexp" ((PCon "TyEffect" (PVar "labels") (PVar "tail") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "TyEffect"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "effAtomSexp")) (EVar "labels"))) (EApp (EVar "optStrSexp") (EVar "tail")) (EApp (EVar "tySexp") (EVar "t")))))
(DFunDef false "tySexp" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "TyConstrained"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "constraintSexp")) (EVar "cs"))) (EApp (EVar "tySexp") (EVar "t")))))
(DTypeSig false "constraintSexp" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "constraintSexp" ((PCon "Constraint" (PVar "iface") (PVar "args"))) (EApp (EApp (EVar "node") (ELit (LString "cstr"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "iface")) (EApp (EApp (EVar "map") (EVar "tySexp")) (EVar "args")))))
(DTypeSig true "optStrSexp" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))
(DFunDef false "optStrSexp" ((PCon "Some" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "Some"))) (EListLit (EApp (EVar "escStr") (EVar "s")))))
(DFunDef false "optStrSexp" ((PCon "None")) (ELit (LString "None")))
(DTypeSig false "effAtomSexp" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "effAtomSexp" ((PTuple (PVar "l") (PCon "None"))) (EApp (EVar "escStr") (EVar "l")))
(DFunDef false "effAtomSexp" ((PTuple (PVar "l") (PCon "Some" (PLit (LString "_"))))) (EApp (EApp (EVar "node") (ELit (LString "hole"))) (EListLit (EApp (EVar "escStr") (EVar "l")))))
(DFunDef false "effAtomSexp" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EApp (EApp (EVar "node") (ELit (LString "atom"))) (EListLit (EApp (EVar "escStr") (EVar "l")) (EApp (EVar "escStr") (EVar "s")))))
(DTypeSig false "guardSexp" (TyFun (TyCon "Guard") (TyCon "String")))
(DFunDef false "guardSexp" ((PCon "GBool" (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "GBool"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")))))
(DFunDef false "guardSexp" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "GBind"))) (EListLit (EApp (EVar "patSexp") (EVar "p")) (EApp (EVar "exprSexp") (EVar "e")))))
(DTypeSig false "armSexp" (TyFun (TyCon "Arm") (TyCon "String")))
(DFunDef false "armSexp" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "arm"))) (EListLit (EApp (EVar "patSexp") (EVar "p")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "guardSexp")) (EVar "gs"))) (EApp (EVar "exprSexp") (EVar "body")))))
(DTypeSig true "exprSexp" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "exprSexp" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "exprSexp") (EVar "e")))
(DFunDef false "exprSexp" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "exprSexp") (EVar "e")))
(DFunDef false "exprSexp" ((PCon "ELit" (PVar "l"))) (EApp (EApp (EVar "node") (ELit (LString "ELit"))) (EListLit (EApp (EVar "litSexp") (EVar "l")))))
(DFunDef false "exprSexp" ((PCon "ENumLit" (PVar "n") PWild PWild)) (EApp (EApp (EVar "node") (ELit (LString "ELit"))) (EListLit (EApp (EApp (EVar "node") (ELit (LString "LInt"))) (EListLit (EApp (EVar "intToString") (EVar "n")))))))
(DFunDef false "exprSexp" ((PCon "EVar" (PVar "x"))) (EApp (EApp (EVar "node") (ELit (LString "EVar"))) (EListLit (EApp (EVar "escStr") (EVar "x")))))
(DFunDef false "exprSexp" ((PCon "EVarAt" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: programToSexp serializes pre-annotate ASTs; EVarAt is introduced by annotateProgram"))))
(DFunDef false "exprSexp" ((PCon "EMethodAt" PWild PWild PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: programToSexp serializes pre-annotate ASTs; EMethodAt is introduced by typecheck elaboration"))))
(DFunDef false "exprSexp" ((PCon "EDictAt" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: programToSexp serializes pre-annotate ASTs; EDictAt is introduced by typecheck elaboration"))))
(DFunDef false "exprSexp" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "node") (ELit (LString "EApp"))) (EListLit (EApp (EVar "exprSexp") (EVar "f")) (EApp (EVar "exprSexp") (EVar "x")))))
(DFunDef false "exprSexp" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "node") (ELit (LString "ELam"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "ps"))) (EApp (EVar "exprSexp") (EVar "b")))))
(DFunDef false "exprSexp" ((PCon "ELet" (PVar "m") (PVar "_isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EVar "node") (ELit (LString "ELet"))) (EListLit (EApp (EVar "boolStr") (EVar "m")) (EApp (EVar "patSexp") (EVar "p")) (EApp (EVar "exprSexp") (EVar "e1")) (EApp (EVar "exprSexp") (EVar "e2")))))
(DFunDef false "exprSexp" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "node") (ELit (LString "EMatch"))) (EBinOp "::" (EApp (EVar "exprSexp") (EVar "s")) (EApp (EApp (EVar "map") (EVar "armSexp")) (EVar "arms")))))
(DFunDef false "exprSexp" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EVar "node") (ELit (LString "EIf"))) (EListLit (EApp (EVar "exprSexp") (EVar "c")) (EApp (EVar "exprSexp") (EVar "t")) (EApp (EVar "exprSexp") (EVar "el")))))
(DFunDef false "exprSexp" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EApp (EApp (EVar "node") (ELit (LString "EBinOp"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EVar "exprSexp") (EVar "a")) (EApp (EVar "exprSexp") (EVar "b")))))
(DFunDef false "exprSexp" ((PCon "EUnOp" (PVar "op") (PVar "a") PWild)) (EApp (EApp (EVar "node") (ELit (LString "EUnOp"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EVar "exprSexp") (EVar "a")))))
(DFunDef false "exprSexp" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EVar "node") (ELit (LString "EInfix"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EVar "exprSexp") (EVar "a")) (EApp (EVar "exprSexp") (EVar "b")))))
(DFunDef false "exprSexp" ((PCon "EFieldAccess" (PVar "e") (PVar "f") PWild)) (EApp (EApp (EVar "node") (ELit (LString "EFieldAccess"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")) (EApp (EVar "escStr") (EVar "f")))))
(DFunDef false "exprSexp" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "ETuple"))) (EApp (EApp (EVar "map") (EVar "exprSexp")) (EVar "es"))))
(DFunDef false "exprSexp" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "EListLit"))) (EApp (EApp (EVar "map") (EVar "exprSexp")) (EVar "es"))))
(DFunDef false "exprSexp" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "EArrayLit"))) (EApp (EApp (EVar "map") (EVar "exprSexp")) (EVar "es"))))
(DFunDef false "exprSexp" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "ERangeList"))) (EListLit (EApp (EVar "exprSexp") (EVar "lo")) (EApp (EVar "exprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "exprSexp" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "ERangeArray"))) (EListLit (EApp (EVar "exprSexp") (EVar "lo")) (EApp (EVar "exprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "exprSexp" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "incl") PWild)) (EApp (EApp (EVar "node") (ELit (LString "ESlice"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")) (EApp (EVar "exprSexp") (EVar "lo")) (EApp (EVar "exprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "exprSexp" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "ELetGroup"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "letBindSexp")) (EVar "binds"))) (EApp (EVar "exprSexp") (EVar "body")))))
(DFunDef false "exprSexp" ((PCon "ESection" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "ESection"))) (EListLit (EApp (EVar "sectionSexp") (EVar "s")))))
(DFunDef false "exprSexp" ((PCon "EIndex" (PVar "a") (PVar "i") PWild)) (EApp (EApp (EVar "node") (ELit (LString "EIndex"))) (EListLit (EApp (EVar "exprSexp") (EVar "a")) (EApp (EVar "exprSexp") (EVar "i")))))
(DFunDef false "exprSexp" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "EAnnot"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")) (EApp (EVar "tySexp") (EVar "t")))))
(DFunDef false "exprSexp" ((PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "EHeadAnnot"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")) (EApp (EVar "tySexp") (EVar "t")))))
(DFunDef false "exprSexp" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "node") (ELit (LString "EBlock"))) (EApp (EApp (EVar "map") (EVar "doStmtSexp")) (EVar "stmts"))))
(DFunDef false "exprSexp" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "node") (ELit (LString "EDo"))) (EApp (EApp (EVar "map") (EVar "doStmtSexp")) (EVar "stmts"))))
(DFunDef false "exprSexp" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "node") (ELit (LString "EStringInterp"))) (EApp (EApp (EVar "map") (EVar "interpPartSexp")) (EVar "parts"))))
(DFunDef false "exprSexp" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "node") (ELit (LString "EGuards"))) (EApp (EApp (EVar "map") (EVar "guardArmSexp")) (EVar "arms"))))
(DFunDef false "exprSexp" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "node") (ELit (LString "ERecordCreate"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "fieldAssignSexp")) (EVar "fs"))))))
(DFunDef false "exprSexp" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EApp (EApp (EVar "node") (ELit (LString "ERecordUpdate"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "fieldAssignSexp")) (EVar "fs"))))))
(DFunDef false "exprSexp" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EVar "node") (ELit (LString "EVariantUpdate"))) (EListLit (EApp (EVar "escStr") (EVar "c")) (EApp (EVar "exprSexp") (EVar "e")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "fieldAssignSexp")) (EVar "fs"))))))
(DFunDef false "exprSexp" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "node") (ELit (LString "EMapLit"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "kvSexp")) (EVar "kvs"))))))
(DFunDef false "exprSexp" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "ESetLit"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "exprSexp")) (EVar "es"))))))
(DFunDef false "exprSexp" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "EAsPat"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EVar "exprSexp") (EVar "e")))))
(DFunDef false "exprSexp" ((PCon "EMethodRef" (PVar "name"))) (EApp (EApp (EVar "node") (ELit (LString "EMethodRef"))) (EListLit (EApp (EVar "escStr") (EVar "name")))))
(DFunDef false "exprSexp" ((PCon "EDictApp" (PVar "name"))) (EApp (EApp (EVar "node") (ELit (LString "EDictApp"))) (EListLit (EApp (EVar "escStr") (EVar "name")))))
(DTypeSig false "sectionSexp" (TyFun (TyCon "Section") (TyCon "String")))
(DFunDef false "sectionSexp" ((PCon "SecBare" (PVar "op"))) (EApp (EApp (EVar "node") (ELit (LString "SecBare"))) (EListLit (EApp (EVar "escStr") (EVar "op")))))
(DFunDef false "sectionSexp" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "SecRight"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EVar "exprSexp") (EVar "e")))))
(DFunDef false "sectionSexp" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "node") (ELit (LString "SecLeft"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")) (EApp (EVar "escStr") (EVar "op")))))
(DTypeSig false "interpPartSexp" (TyFun (TyCon "InterpPart") (TyCon "String")))
(DFunDef false "interpPartSexp" ((PCon "InterpStr" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "InterpStr"))) (EListLit (EApp (EVar "escStr") (EVar "s")))))
(DFunDef false "interpPartSexp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "InterpExpr"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")))))
(DTypeSig false "guardArmSexp" (TyFun (TyCon "GuardArm") (TyCon "String")))
(DFunDef false "guardArmSexp" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "garm"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "guardSexp")) (EVar "gs"))) (EApp (EVar "exprSexp") (EVar "body")))))
(DTypeSig false "fieldAssignSexp" (TyFun (TyCon "FieldAssign") (TyCon "String")))
(DFunDef false "fieldAssignSexp" ((PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "fa"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "exprSexp") (EVar "e")))))
(DTypeSig false "kvSexp" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyCon "String")))
(DFunDef false "kvSexp" ((PTuple (PVar "k") (PVar "v"))) (EApp (EApp (EVar "node") (ELit (LString "kv"))) (EListLit (EApp (EVar "exprSexp") (EVar "k")) (EApp (EVar "exprSexp") (EVar "v")))))
(DTypeSig false "letBindSexp" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindSexp" ((PCon "LetBind" (PVar "name") (PVar "clauses"))) (EApp (EApp (EVar "node") (ELit (LString "lgb"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "name")) (EApp (EApp (EVar "map") (EVar "funClauseSexp")) (EVar "clauses")))))
(DTypeSig false "funClauseSexp" (TyFun (TyCon "FunClause") (TyCon "String")))
(DFunDef false "funClauseSexp" ((PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "clause"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EVar "exprSexp") (EVar "body")))))
(DTypeSig false "doStmtSexp" (TyFun (TyCon "DoStmt") (TyCon "String")))
(DFunDef false "doStmtSexp" ((PCon "DoExpr" (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "DoExpr"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")))))
(DFunDef false "doStmtSexp" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "DoBind"))) (EListLit (EApp (EVar "patSexp") (EVar "p")) (EApp (EVar "exprSexp") (EVar "e")))))
(DFunDef false "doStmtSexp" ((PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "DoLet"))) (EListLit (EApp (EVar "boolStr") (EVar "m")) (EApp (EVar "boolStr") (EVar "r")) (EApp (EVar "patSexp") (EVar "p")) (EApp (EVar "exprSexp") (EVar "e")))))
(DFunDef false "doStmtSexp" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "DoAssign"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EVar "exprSexp") (EVar "e")))))
(DFunDef false "doStmtSexp" ((PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "DoFieldAssign"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "fs"))) (EApp (EVar "exprSexp") (EVar "e")))))
(DTypeSig false "visSexp" (TyFun (TyCon "DataVis") (TyCon "String")))
(DFunDef false "visSexp" ((PCon "VisPrivate")) (ELit (LString "Private")))
(DFunDef false "visSexp" ((PCon "VisAbstract")) (ELit (LString "Abstract")))
(DFunDef false "visSexp" ((PCon "VisPublic")) (ELit (LString "Public")))
(DTypeSig false "fieldSexp" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldSexp" ((PCon "Field" (PVar "n") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "field"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "tySexp") (EVar "t")))))
(DTypeSig false "payloadSexp" (TyFun (TyCon "ConPayload") (TyCon "String")))
(DFunDef false "payloadSexp" ((PCon "ConPos" (PVar "tys"))) (EApp (EApp (EVar "node") (ELit (LString "ConPos"))) (EApp (EApp (EVar "map") (EVar "tySexp")) (EVar "tys"))))
(DFunDef false "payloadSexp" ((PCon "ConNamed" (PVar "fs") PWild)) (EApp (EApp (EVar "node") (ELit (LString "ConNamed"))) (EApp (EApp (EVar "map") (EVar "fieldSexp")) (EVar "fs"))))
(DTypeSig false "variantSexp" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantSexp" ((PCon "Variant" (PVar "n") (PVar "pl"))) (EApp (EApp (EVar "node") (ELit (LString "variant"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "payloadSexp") (EVar "pl")))))
(DTypeSig false "declSexp" (TyFun (TyCon "Decl") (TyCon "String")))
(DFunDef false "declSexp" ((PCon "DTypeSig" (PVar "p") (PVar "n") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "DTypeSig"))) (EListLit (EApp (EVar "boolStr") (EVar "p")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "tySexp") (EVar "t")))))
(DFunDef false "declSexp" ((PCon "DExtern" (PVar "p") (PVar "n") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "DExtern"))) (EListLit (EApp (EVar "boolStr") (EVar "p")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "tySexp") (EVar "t")))))
(DFunDef false "declSexp" ((PCon "DFunDef" (PVar "p") (PVar "n") (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "node") (ELit (LString "DFunDef"))) (EListLit (EApp (EVar "boolStr") (EVar "p")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "ps"))) (EApp (EVar "exprSexp") (EVar "b")))))
(DFunDef false "declSexp" ((PCon "DData" (PVar "vis") (PVar "n") (PVar "ps") (PVar "vs") (PVar "ds"))) (EApp (EApp (EVar "node") (ELit (LString "DData"))) (EListLit (EApp (EVar "visSexp") (EVar "vis")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "ps"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "variantSexp")) (EVar "vs"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EApp (EVar "escStr") (EApp (EVar "deriveRefName") (EVar "d"))))) (EVar "ds"))))))
(DFunDef false "declSexp" ((PCon "DUse" (PVar "pub") (PVar "path") PWild)) (EApp (EApp (EVar "node") (ELit (LString "DUse"))) (EListLit (EApp (EVar "boolStr") (EVar "pub")) (EApp (EVar "usePathSexp") (EVar "path")))))
(DFunDef false "declSexp" ((PCon "DEffect" (PVar "pub") (PVar "n") (PVar "dom"))) (EApp (EApp (EVar "node") (ELit (LString "DEffect"))) (EListLit (EApp (EVar "boolStr") (EVar "pub")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "optStrSexp") (EVar "dom")))))
(DFunDef false "declSexp" ((PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "DProp"))) (EListLit (EApp (EVar "boolStr") (EVar "pub")) (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "propParamSexp")) (EVar "params"))) (EApp (EVar "exprSexp") (EVar "body")))))
(DFunDef false "declSexp" ((PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "DTest"))) (EListLit (EApp (EVar "boolStr") (EVar "pub")) (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "exprSexp") (EVar "body")))))
(DFunDef false "declSexp" ((PCon "DBench" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "DBench"))) (EListLit (EApp (EVar "boolStr") (EVar "pub")) (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "exprSexp") (EVar "body")))))
(DFunDef false "declSexp" ((PCon "DTypeAlias" (PVar "p") (PVar "n") (PVar "ps") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "DTypeAlias"))) (EListLit (EApp (EVar "boolStr") (EVar "p")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "ps"))) (EApp (EVar "tySexp") (EVar "t")))))
(DFunDef false "declSexp" ((PCon "DNewtype" (PVar "p") (PVar "n") (PVar "ps") (PVar "con") (PVar "fty") (PVar "ds"))) (EApp (EApp (EVar "node") (ELit (LString "DNewtype"))) (EListLit (EApp (EVar "boolStr") (EVar "p")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "ps"))) (EApp (EVar "escStr") (EVar "con")) (EApp (EVar "tySexp") (EVar "fty")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EApp (EVar "escStr") (EApp (EVar "deriveRefName") (EVar "d"))))) (EVar "ds"))))))
(DFunDef false "declSexp" ((PCon "DLetGroup" (PVar "p") (PVar "binds"))) (EApp (EApp (EVar "node") (ELit (LString "DLetGroup"))) (EListLit (EApp (EVar "boolStr") (EVar "p")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "letBindSexp")) (EVar "binds"))))))
(DFunDef false "declSexp" ((PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "node") (ELit (LString "DAttrib"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "attrSexp")) (EVar "attrs"))) (EApp (EVar "declSexp") (EVar "d")))))
(DFunDef false "declSexp" ((PRec "DInterface" ((rf "pub" None) (rf "def" None) (rf "name" None) (rf "typarams" None) (rf "supers" None) (rf "methods" None)) false)) (EApp (EApp (EVar "node") (ELit (LString "DInterface"))) (EListLit (EApp (EVar "boolStr") (EVar "pub")) (EApp (EVar "boolStr") (EVar "def")) (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "typarams"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "superSexp")) (EVar "supers"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "ifaceMethodSexp")) (EVar "methods"))))))
(DFunDef false "declSexp" ((PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EApp (EApp (EVar "node") (ELit (LString "DImpl"))) (EListLit (EApp (EVar "boolStr") (EVar "pub")) (EApp (EVar "escStr") (EVar "iface")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "tySexp")) (EVar "tys"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "requireSexp")) (EVar "reqs"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "implMethodSexp")) (EVar "methods"))))))
(DTypeSig false "attrSexp" (TyFun (TyCon "Attr") (TyCon "String")))
(DFunDef false "attrSexp" ((PCon "AttrDeprecated" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "AttrDeprecated"))) (EListLit (EApp (EVar "escStr") (EVar "s")))))
(DFunDef false "attrSexp" ((PCon "AttrInline")) (ELit (LString "AttrInline")))
(DFunDef false "attrSexp" ((PCon "AttrMustUse")) (ELit (LString "AttrMustUse")))
(DTypeSig false "propParamSexp" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "propParamSexp" ((PCon "PropParam" (PVar "n") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "pp"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "tySexp") (EVar "t")))))
(DTypeSig false "methodDefaultSexp" (TyFun (TyApp (TyCon "Option") (TyCon "MethodDefault")) (TyCon "String")))
(DFunDef false "methodDefaultSexp" ((PCon "None")) (ELit (LString "None")))
(DFunDef false "methodDefaultSexp" ((PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body")))) (EApp (EApp (EVar "node") (ELit (LString "mdef"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EVar "exprSexp") (EVar "body")))))
(DTypeSig false "ifaceMethodSexp" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodSexp" ((PCon "IfaceMethod" (PVar "name") (PVar "ty") (PVar "def"))) (EApp (EApp (EVar "node") (ELit (LString "imethod"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "tySexp") (EVar "ty")) (EApp (EVar "methodDefaultSexp") (EVar "def")))))
(DTypeSig false "superSexp" (TyFun (TyCon "Super") (TyCon "String")))
(DFunDef false "superSexp" ((PCon "Super" (PVar "iface") (PVar "params"))) (EApp (EApp (EVar "node") (ELit (LString "super"))) (EListLit (EApp (EVar "escStr") (EVar "iface")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "params"))))))
(DTypeSig false "requireSexp" (TyFun (TyCon "Require") (TyCon "String")))
(DFunDef false "requireSexp" ((PCon "Require" (PVar "iface") (PVar "tys"))) (EApp (EApp (EVar "node") (ELit (LString "req"))) (EListLit (EApp (EVar "escStr") (EVar "iface")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "tySexp")) (EVar "tys"))))))
(DTypeSig false "implMethodSexp" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodSexp" ((PCon "ImplMethod" (PVar "name") (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "im"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EVar "exprSexp") (EVar "body")))))
(DTypeSig false "useMemberSexp" (TyFun (TyCon "UseMember") (TyCon "String")))
(DFunDef false "useMemberSexp" ((PCon "UseMember" (PVar "n") (PVar "withAll") PWild (PVar "alias"))) (EMatch (EVar "alias") (arm (PCon "Some" (PVar "a")) () (EApp (EApp (EVar "node") (ELit (LString "mem"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "boolStr") (EVar "withAll")) (EApp (EVar "escStr") (EVar "a"))))) (arm (PCon "None") () (EApp (EApp (EVar "node") (ELit (LString "mem"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "boolStr") (EVar "withAll")))))))
(DTypeSig false "usePathSexp" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "usePathSexp" ((PCon "UseName" (PVar "ids"))) (EApp (EApp (EVar "node") (ELit (LString "UseName"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "ids"))))))
(DFunDef false "usePathSexp" ((PCon "UseGroup" (PVar "ids") (PVar "ms"))) (EApp (EApp (EVar "node") (ELit (LString "UseGroup"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "ids"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "useMemberSexp")) (EVar "ms"))))))
(DFunDef false "usePathSexp" ((PCon "UseWild" (PVar "ids"))) (EApp (EApp (EVar "node") (ELit (LString "UseWild"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "ids"))))))
(DFunDef false "usePathSexp" ((PCon "UseAlias" (PVar "ids") (PVar "a"))) (EApp (EApp (EVar "node") (ELit (LString "UseAlias"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "ids"))) (EApp (EVar "escStr") (EVar "a")))))
(DTypeSig true "programToSexp" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "programToSexp" ((PVar "prog")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "declSexp")) (EVar "prog"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "DeriveRef" true) (mem "deriveRefName" false) (mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true) (mem "Attr" true))))
(DUse false (UseGroup ("support" "util") ((mem "escStr" false) (mem "joinNl" false) (mem "joinWith" false))))
(DTypeSig true "boolStr" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "boolStr" ((PCon "True")) (ELit (LString "true")))
(DFunDef false "boolStr" ((PCon "False")) (ELit (LString "false")))
(DTypeSig false "joinSp" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSp" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "xs")))
(DTypeSig true "node" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "node" ((PVar "tag") (PVar "parts")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "joinSp") (EBinOp "::" (EVar "tag") (EVar "parts")))) (ELit (LString ")"))))
(DTypeSig true "slist" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "slist" ((PVar "xs")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "joinSp") (EVar "xs"))) (ELit (LString ")"))))
(DTypeSig true "litSexp" (TyFun (TyCon "Lit") (TyCon "String")))
(DFunDef false "litSexp" ((PCon "LInt" (PVar "n"))) (EApp (EApp (EVar "node") (ELit (LString "LInt"))) (EListLit (EApp (EVar "intToString") (EVar "n")))))
(DFunDef false "litSexp" ((PCon "LFloat" (PVar "f"))) (EApp (EApp (EVar "node") (ELit (LString "LFloat"))) (EListLit (EApp (EVar "floatToString") (EVar "f")))))
(DFunDef false "litSexp" ((PCon "LString" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "LString"))) (EListLit (EApp (EVar "escStr") (EVar "s")))))
(DFunDef false "litSexp" ((PCon "LChar" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "LChar"))) (EListLit (EApp (EVar "escStr") (EVar "s")))))
(DFunDef false "litSexp" ((PCon "LBool" (PVar "b"))) (EApp (EApp (EVar "node") (ELit (LString "LBool"))) (EListLit (EApp (EVar "boolStr") (EVar "b")))))
(DFunDef false "litSexp" ((PCon "LUnit")) (ELit (LString "LUnit")))
(DTypeSig true "patSexp" (TyFun (TyCon "Pat") (TyCon "String")))
(DFunDef false "patSexp" ((PCon "PVar" (PVar "x"))) (EApp (EApp (EVar "node") (ELit (LString "PVar"))) (EListLit (EApp (EVar "escStr") (EVar "x")))))
(DFunDef false "patSexp" ((PCon "PWild")) (ELit (LString "PWild")))
(DFunDef false "patSexp" ((PCon "PLit" (PVar "l"))) (EApp (EApp (EVar "node") (ELit (LString "PLit"))) (EListLit (EApp (EVar "litSexp") (EVar "l")))))
(DFunDef false "patSexp" ((PCon "PCon" (PVar "c") (PVar "ps"))) (EApp (EApp (EVar "node") (ELit (LString "PCon"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "c")) (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "ps")))))
(DFunDef false "patSexp" ((PCon "PCons" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "node") (ELit (LString "PCons"))) (EListLit (EApp (EVar "patSexp") (EVar "a")) (EApp (EVar "patSexp") (EVar "b")))))
(DFunDef false "patSexp" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "node") (ELit (LString "PTuple"))) (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "ps"))))
(DFunDef false "patSexp" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "node") (ELit (LString "PList"))) (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "ps"))))
(DFunDef false "patSexp" ((PCon "PAs" (PVar "x") (PVar "q"))) (EApp (EApp (EVar "node") (ELit (LString "PAs"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EVar "patSexp") (EVar "q")))))
(DFunDef false "patSexp" ((PCon "PRng" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "PRng"))) (EListLit (EApp (EVar "litSexp") (EVar "lo")) (EApp (EVar "litSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "patSexp" ((PCon "PRec" (PVar "name") (PVar "fields") (PVar "rest"))) (EApp (EApp (EVar "node") (ELit (LString "PRec"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "recPatFieldSexp")) (EVar "fields"))) (EApp (EVar "boolStr") (EVar "rest")))))
(DTypeSig false "recPatFieldSexp" (TyFun (TyCon "RecPatField") (TyCon "String")))
(DFunDef false "recPatFieldSexp" ((PCon "RecPatField" (PVar "f") (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "node") (ELit (LString "rf"))) (EListLit (EApp (EVar "escStr") (EVar "f")) (EApp (EVar "patSexp") (EVar "p")))))
(DFunDef false "recPatFieldSexp" ((PCon "RecPatField" (PVar "f") (PCon "None"))) (EApp (EApp (EVar "node") (ELit (LString "rf"))) (EListLit (EApp (EVar "escStr") (EVar "f")) (ELit (LString "None")))))
(DTypeSig false "tySexp" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "tySexp" ((PCon "TyCon" (PVar "c") PWild)) (EApp (EApp (EVar "node") (ELit (LString "TyCon"))) (EListLit (EApp (EVar "escStr") (EVar "c")))))
(DFunDef false "tySexp" ((PCon "TyVar" (PVar "v"))) (EApp (EApp (EVar "node") (ELit (LString "TyVar"))) (EListLit (EApp (EVar "escStr") (EVar "v")))))
(DFunDef false "tySexp" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "node") (ELit (LString "TyApp"))) (EListLit (EApp (EVar "tySexp") (EVar "a")) (EApp (EVar "tySexp") (EVar "b")))))
(DFunDef false "tySexp" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "node") (ELit (LString "TyFun"))) (EListLit (EApp (EVar "tySexp") (EVar "a")) (EApp (EVar "tySexp") (EVar "b")))))
(DFunDef false "tySexp" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "node") (ELit (LString "TyTuple"))) (EApp (EApp (EMethodRef "map") (EVar "tySexp")) (EVar "ts"))))
(DFunDef false "tySexp" ((PCon "TyEffect" (PVar "labels") (PVar "tail") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "TyEffect"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "effAtomSexp")) (EVar "labels"))) (EApp (EVar "optStrSexp") (EVar "tail")) (EApp (EVar "tySexp") (EVar "t")))))
(DFunDef false "tySexp" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "TyConstrained"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "constraintSexp")) (EVar "cs"))) (EApp (EVar "tySexp") (EVar "t")))))
(DTypeSig false "constraintSexp" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "constraintSexp" ((PCon "Constraint" (PVar "iface") (PVar "args"))) (EApp (EApp (EVar "node") (ELit (LString "cstr"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "iface")) (EApp (EApp (EMethodRef "map") (EVar "tySexp")) (EVar "args")))))
(DTypeSig true "optStrSexp" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))
(DFunDef false "optStrSexp" ((PCon "Some" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "Some"))) (EListLit (EApp (EVar "escStr") (EVar "s")))))
(DFunDef false "optStrSexp" ((PCon "None")) (ELit (LString "None")))
(DTypeSig false "effAtomSexp" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "effAtomSexp" ((PTuple (PVar "l") (PCon "None"))) (EApp (EVar "escStr") (EVar "l")))
(DFunDef false "effAtomSexp" ((PTuple (PVar "l") (PCon "Some" (PLit (LString "_"))))) (EApp (EApp (EVar "node") (ELit (LString "hole"))) (EListLit (EApp (EVar "escStr") (EVar "l")))))
(DFunDef false "effAtomSexp" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EApp (EApp (EVar "node") (ELit (LString "atom"))) (EListLit (EApp (EVar "escStr") (EVar "l")) (EApp (EVar "escStr") (EVar "s")))))
(DTypeSig false "guardSexp" (TyFun (TyCon "Guard") (TyCon "String")))
(DFunDef false "guardSexp" ((PCon "GBool" (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "GBool"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")))))
(DFunDef false "guardSexp" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "GBind"))) (EListLit (EApp (EVar "patSexp") (EVar "p")) (EApp (EVar "exprSexp") (EVar "e")))))
(DTypeSig false "armSexp" (TyFun (TyCon "Arm") (TyCon "String")))
(DFunDef false "armSexp" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "arm"))) (EListLit (EApp (EVar "patSexp") (EVar "p")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "guardSexp")) (EVar "gs"))) (EApp (EVar "exprSexp") (EVar "body")))))
(DTypeSig true "exprSexp" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "exprSexp" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "exprSexp") (EVar "e")))
(DFunDef false "exprSexp" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "exprSexp") (EVar "e")))
(DFunDef false "exprSexp" ((PCon "ELit" (PVar "l"))) (EApp (EApp (EVar "node") (ELit (LString "ELit"))) (EListLit (EApp (EVar "litSexp") (EVar "l")))))
(DFunDef false "exprSexp" ((PCon "ENumLit" (PVar "n") PWild PWild)) (EApp (EApp (EVar "node") (ELit (LString "ELit"))) (EListLit (EApp (EApp (EVar "node") (ELit (LString "LInt"))) (EListLit (EApp (EVar "intToString") (EVar "n")))))))
(DFunDef false "exprSexp" ((PCon "EVar" (PVar "x"))) (EApp (EApp (EVar "node") (ELit (LString "EVar"))) (EListLit (EApp (EVar "escStr") (EVar "x")))))
(DFunDef false "exprSexp" ((PCon "EVarAt" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: programToSexp serializes pre-annotate ASTs; EVarAt is introduced by annotateProgram"))))
(DFunDef false "exprSexp" ((PCon "EMethodAt" PWild PWild PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: programToSexp serializes pre-annotate ASTs; EMethodAt is introduced by typecheck elaboration"))))
(DFunDef false "exprSexp" ((PCon "EDictAt" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: programToSexp serializes pre-annotate ASTs; EDictAt is introduced by typecheck elaboration"))))
(DFunDef false "exprSexp" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "node") (ELit (LString "EApp"))) (EListLit (EApp (EVar "exprSexp") (EVar "f")) (EApp (EVar "exprSexp") (EVar "x")))))
(DFunDef false "exprSexp" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "node") (ELit (LString "ELam"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "ps"))) (EApp (EVar "exprSexp") (EVar "b")))))
(DFunDef false "exprSexp" ((PCon "ELet" (PVar "m") (PVar "_isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EVar "node") (ELit (LString "ELet"))) (EListLit (EApp (EVar "boolStr") (EVar "m")) (EApp (EVar "patSexp") (EVar "p")) (EApp (EVar "exprSexp") (EVar "e1")) (EApp (EVar "exprSexp") (EVar "e2")))))
(DFunDef false "exprSexp" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "node") (ELit (LString "EMatch"))) (EBinOp "::" (EApp (EVar "exprSexp") (EVar "s")) (EApp (EApp (EMethodRef "map") (EVar "armSexp")) (EVar "arms")))))
(DFunDef false "exprSexp" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EVar "node") (ELit (LString "EIf"))) (EListLit (EApp (EVar "exprSexp") (EVar "c")) (EApp (EVar "exprSexp") (EVar "t")) (EApp (EVar "exprSexp") (EVar "el")))))
(DFunDef false "exprSexp" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EApp (EApp (EVar "node") (ELit (LString "EBinOp"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EVar "exprSexp") (EVar "a")) (EApp (EVar "exprSexp") (EVar "b")))))
(DFunDef false "exprSexp" ((PCon "EUnOp" (PVar "op") (PVar "a") PWild)) (EApp (EApp (EVar "node") (ELit (LString "EUnOp"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EVar "exprSexp") (EVar "a")))))
(DFunDef false "exprSexp" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EVar "node") (ELit (LString "EInfix"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EVar "exprSexp") (EVar "a")) (EApp (EVar "exprSexp") (EVar "b")))))
(DFunDef false "exprSexp" ((PCon "EFieldAccess" (PVar "e") (PVar "f") PWild)) (EApp (EApp (EVar "node") (ELit (LString "EFieldAccess"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")) (EApp (EVar "escStr") (EVar "f")))))
(DFunDef false "exprSexp" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "ETuple"))) (EApp (EApp (EMethodRef "map") (EVar "exprSexp")) (EVar "es"))))
(DFunDef false "exprSexp" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "EListLit"))) (EApp (EApp (EMethodRef "map") (EVar "exprSexp")) (EVar "es"))))
(DFunDef false "exprSexp" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "EArrayLit"))) (EApp (EApp (EMethodRef "map") (EVar "exprSexp")) (EVar "es"))))
(DFunDef false "exprSexp" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "ERangeList"))) (EListLit (EApp (EVar "exprSexp") (EVar "lo")) (EApp (EVar "exprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "exprSexp" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "ERangeArray"))) (EListLit (EApp (EVar "exprSexp") (EVar "lo")) (EApp (EVar "exprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "exprSexp" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "incl") PWild)) (EApp (EApp (EVar "node") (ELit (LString "ESlice"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")) (EApp (EVar "exprSexp") (EVar "lo")) (EApp (EVar "exprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "exprSexp" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "ELetGroup"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "letBindSexp")) (EVar "binds"))) (EApp (EVar "exprSexp") (EVar "body")))))
(DFunDef false "exprSexp" ((PCon "ESection" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "ESection"))) (EListLit (EApp (EVar "sectionSexp") (EVar "s")))))
(DFunDef false "exprSexp" ((PCon "EIndex" (PVar "a") (PVar "i") PWild)) (EApp (EApp (EVar "node") (ELit (LString "EIndex"))) (EListLit (EApp (EVar "exprSexp") (EVar "a")) (EApp (EVar "exprSexp") (EVar "i")))))
(DFunDef false "exprSexp" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "EAnnot"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")) (EApp (EVar "tySexp") (EVar "t")))))
(DFunDef false "exprSexp" ((PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "EHeadAnnot"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")) (EApp (EVar "tySexp") (EVar "t")))))
(DFunDef false "exprSexp" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "node") (ELit (LString "EBlock"))) (EApp (EApp (EMethodRef "map") (EVar "doStmtSexp")) (EVar "stmts"))))
(DFunDef false "exprSexp" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "node") (ELit (LString "EDo"))) (EApp (EApp (EMethodRef "map") (EVar "doStmtSexp")) (EVar "stmts"))))
(DFunDef false "exprSexp" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "node") (ELit (LString "EStringInterp"))) (EApp (EApp (EMethodRef "map") (EVar "interpPartSexp")) (EVar "parts"))))
(DFunDef false "exprSexp" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "node") (ELit (LString "EGuards"))) (EApp (EApp (EMethodRef "map") (EVar "guardArmSexp")) (EVar "arms"))))
(DFunDef false "exprSexp" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "node") (ELit (LString "ERecordCreate"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "fieldAssignSexp")) (EVar "fs"))))))
(DFunDef false "exprSexp" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EApp (EApp (EVar "node") (ELit (LString "ERecordUpdate"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "fieldAssignSexp")) (EVar "fs"))))))
(DFunDef false "exprSexp" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EVar "node") (ELit (LString "EVariantUpdate"))) (EListLit (EApp (EVar "escStr") (EVar "c")) (EApp (EVar "exprSexp") (EVar "e")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "fieldAssignSexp")) (EVar "fs"))))))
(DFunDef false "exprSexp" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "node") (ELit (LString "EMapLit"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "kvSexp")) (EVar "kvs"))))))
(DFunDef false "exprSexp" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "ESetLit"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "exprSexp")) (EVar "es"))))))
(DFunDef false "exprSexp" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "EAsPat"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EVar "exprSexp") (EVar "e")))))
(DFunDef false "exprSexp" ((PCon "EMethodRef" (PVar "name"))) (EApp (EApp (EVar "node") (ELit (LString "EMethodRef"))) (EListLit (EApp (EVar "escStr") (EVar "name")))))
(DFunDef false "exprSexp" ((PCon "EDictApp" (PVar "name"))) (EApp (EApp (EVar "node") (ELit (LString "EDictApp"))) (EListLit (EApp (EVar "escStr") (EVar "name")))))
(DTypeSig false "sectionSexp" (TyFun (TyCon "Section") (TyCon "String")))
(DFunDef false "sectionSexp" ((PCon "SecBare" (PVar "op"))) (EApp (EApp (EVar "node") (ELit (LString "SecBare"))) (EListLit (EApp (EVar "escStr") (EVar "op")))))
(DFunDef false "sectionSexp" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "SecRight"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EVar "exprSexp") (EVar "e")))))
(DFunDef false "sectionSexp" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "node") (ELit (LString "SecLeft"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")) (EApp (EVar "escStr") (EVar "op")))))
(DTypeSig false "interpPartSexp" (TyFun (TyCon "InterpPart") (TyCon "String")))
(DFunDef false "interpPartSexp" ((PCon "InterpStr" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "InterpStr"))) (EListLit (EApp (EVar "escStr") (EVar "s")))))
(DFunDef false "interpPartSexp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "InterpExpr"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")))))
(DTypeSig false "guardArmSexp" (TyFun (TyCon "GuardArm") (TyCon "String")))
(DFunDef false "guardArmSexp" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "garm"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "guardSexp")) (EVar "gs"))) (EApp (EVar "exprSexp") (EVar "body")))))
(DTypeSig false "fieldAssignSexp" (TyFun (TyCon "FieldAssign") (TyCon "String")))
(DFunDef false "fieldAssignSexp" ((PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "fa"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "exprSexp") (EVar "e")))))
(DTypeSig false "kvSexp" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyCon "String")))
(DFunDef false "kvSexp" ((PTuple (PVar "k") (PVar "v"))) (EApp (EApp (EVar "node") (ELit (LString "kv"))) (EListLit (EApp (EVar "exprSexp") (EVar "k")) (EApp (EVar "exprSexp") (EVar "v")))))
(DTypeSig false "letBindSexp" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindSexp" ((PCon "LetBind" (PVar "name") (PVar "clauses"))) (EApp (EApp (EVar "node") (ELit (LString "lgb"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "funClauseSexp")) (EVar "clauses")))))
(DTypeSig false "funClauseSexp" (TyFun (TyCon "FunClause") (TyCon "String")))
(DFunDef false "funClauseSexp" ((PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "clause"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EVar "exprSexp") (EVar "body")))))
(DTypeSig false "doStmtSexp" (TyFun (TyCon "DoStmt") (TyCon "String")))
(DFunDef false "doStmtSexp" ((PCon "DoExpr" (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "DoExpr"))) (EListLit (EApp (EVar "exprSexp") (EVar "e")))))
(DFunDef false "doStmtSexp" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "DoBind"))) (EListLit (EApp (EVar "patSexp") (EVar "p")) (EApp (EVar "exprSexp") (EVar "e")))))
(DFunDef false "doStmtSexp" ((PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "DoLet"))) (EListLit (EApp (EVar "boolStr") (EVar "m")) (EApp (EVar "boolStr") (EVar "r")) (EApp (EVar "patSexp") (EVar "p")) (EApp (EVar "exprSexp") (EVar "e")))))
(DFunDef false "doStmtSexp" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "DoAssign"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EVar "exprSexp") (EVar "e")))))
(DFunDef false "doStmtSexp" ((PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "DoFieldAssign"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "fs"))) (EApp (EVar "exprSexp") (EVar "e")))))
(DTypeSig false "visSexp" (TyFun (TyCon "DataVis") (TyCon "String")))
(DFunDef false "visSexp" ((PCon "VisPrivate")) (ELit (LString "Private")))
(DFunDef false "visSexp" ((PCon "VisAbstract")) (ELit (LString "Abstract")))
(DFunDef false "visSexp" ((PCon "VisPublic")) (ELit (LString "Public")))
(DTypeSig false "fieldSexp" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldSexp" ((PCon "Field" (PVar "n") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "field"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "tySexp") (EVar "t")))))
(DTypeSig false "payloadSexp" (TyFun (TyCon "ConPayload") (TyCon "String")))
(DFunDef false "payloadSexp" ((PCon "ConPos" (PVar "tys"))) (EApp (EApp (EVar "node") (ELit (LString "ConPos"))) (EApp (EApp (EMethodRef "map") (EVar "tySexp")) (EVar "tys"))))
(DFunDef false "payloadSexp" ((PCon "ConNamed" (PVar "fs") PWild)) (EApp (EApp (EVar "node") (ELit (LString "ConNamed"))) (EApp (EApp (EMethodRef "map") (EVar "fieldSexp")) (EVar "fs"))))
(DTypeSig false "variantSexp" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantSexp" ((PCon "Variant" (PVar "n") (PVar "pl"))) (EApp (EApp (EVar "node") (ELit (LString "variant"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "payloadSexp") (EVar "pl")))))
(DTypeSig false "declSexp" (TyFun (TyCon "Decl") (TyCon "String")))
(DFunDef false "declSexp" ((PCon "DTypeSig" (PVar "p") (PVar "n") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "DTypeSig"))) (EListLit (EApp (EVar "boolStr") (EVar "p")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "tySexp") (EVar "t")))))
(DFunDef false "declSexp" ((PCon "DExtern" (PVar "p") (PVar "n") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "DExtern"))) (EListLit (EApp (EVar "boolStr") (EVar "p")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "tySexp") (EVar "t")))))
(DFunDef false "declSexp" ((PCon "DFunDef" (PVar "p") (PVar "n") (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "node") (ELit (LString "DFunDef"))) (EListLit (EApp (EVar "boolStr") (EVar "p")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "ps"))) (EApp (EVar "exprSexp") (EVar "b")))))
(DFunDef false "declSexp" ((PCon "DData" (PVar "vis") (PVar "n") (PVar "ps") (PVar "vs") (PVar "ds"))) (EApp (EApp (EVar "node") (ELit (LString "DData"))) (EListLit (EApp (EVar "visSexp") (EVar "vis")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "ps"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "variantSexp")) (EVar "vs"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EApp (EVar "escStr") (EApp (EVar "deriveRefName") (EVar "d"))))) (EVar "ds"))))))
(DFunDef false "declSexp" ((PCon "DUse" (PVar "pub") (PVar "path") PWild)) (EApp (EApp (EVar "node") (ELit (LString "DUse"))) (EListLit (EApp (EVar "boolStr") (EVar "pub")) (EApp (EVar "usePathSexp") (EVar "path")))))
(DFunDef false "declSexp" ((PCon "DEffect" (PVar "pub") (PVar "n") (PVar "dom"))) (EApp (EApp (EVar "node") (ELit (LString "DEffect"))) (EListLit (EApp (EVar "boolStr") (EVar "pub")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "optStrSexp") (EVar "dom")))))
(DFunDef false "declSexp" ((PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "DProp"))) (EListLit (EApp (EVar "boolStr") (EVar "pub")) (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "propParamSexp")) (EVar "params"))) (EApp (EVar "exprSexp") (EVar "body")))))
(DFunDef false "declSexp" ((PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "DTest"))) (EListLit (EApp (EVar "boolStr") (EVar "pub")) (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "exprSexp") (EVar "body")))))
(DFunDef false "declSexp" ((PCon "DBench" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "DBench"))) (EListLit (EApp (EVar "boolStr") (EVar "pub")) (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "exprSexp") (EVar "body")))))
(DFunDef false "declSexp" ((PCon "DTypeAlias" (PVar "p") (PVar "n") (PVar "ps") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "DTypeAlias"))) (EListLit (EApp (EVar "boolStr") (EVar "p")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "ps"))) (EApp (EVar "tySexp") (EVar "t")))))
(DFunDef false "declSexp" ((PCon "DNewtype" (PVar "p") (PVar "n") (PVar "ps") (PVar "con") (PVar "fty") (PVar "ds"))) (EApp (EApp (EVar "node") (ELit (LString "DNewtype"))) (EListLit (EApp (EVar "boolStr") (EVar "p")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "ps"))) (EApp (EVar "escStr") (EVar "con")) (EApp (EVar "tySexp") (EVar "fty")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EApp (EVar "escStr") (EApp (EVar "deriveRefName") (EVar "d"))))) (EVar "ds"))))))
(DFunDef false "declSexp" ((PCon "DLetGroup" (PVar "p") (PVar "binds"))) (EApp (EApp (EVar "node") (ELit (LString "DLetGroup"))) (EListLit (EApp (EVar "boolStr") (EVar "p")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "letBindSexp")) (EVar "binds"))))))
(DFunDef false "declSexp" ((PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "node") (ELit (LString "DAttrib"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "attrSexp")) (EVar "attrs"))) (EApp (EVar "declSexp") (EVar "d")))))
(DFunDef false "declSexp" ((PRec "DInterface" ((rf "pub" None) (rf "def" None) (rf "name" None) (rf "typarams" None) (rf "supers" None) (rf "methods" None)) false)) (EApp (EApp (EVar "node") (ELit (LString "DInterface"))) (EListLit (EApp (EVar "boolStr") (EVar "pub")) (EApp (EVar "boolStr") (EVar "def")) (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "typarams"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "superSexp")) (EVar "supers"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodSexp")) (EVar "methods"))))))
(DFunDef false "declSexp" ((PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EApp (EApp (EVar "node") (ELit (LString "DImpl"))) (EListLit (EApp (EVar "boolStr") (EVar "pub")) (EApp (EVar "escStr") (EVar "iface")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "tySexp")) (EVar "tys"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "requireSexp")) (EVar "reqs"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "implMethodSexp")) (EVar "methods"))))))
(DTypeSig false "attrSexp" (TyFun (TyCon "Attr") (TyCon "String")))
(DFunDef false "attrSexp" ((PCon "AttrDeprecated" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "AttrDeprecated"))) (EListLit (EApp (EVar "escStr") (EVar "s")))))
(DFunDef false "attrSexp" ((PCon "AttrInline")) (ELit (LString "AttrInline")))
(DFunDef false "attrSexp" ((PCon "AttrMustUse")) (ELit (LString "AttrMustUse")))
(DTypeSig false "propParamSexp" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "propParamSexp" ((PCon "PropParam" (PVar "n") (PVar "t"))) (EApp (EApp (EVar "node") (ELit (LString "pp"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "tySexp") (EVar "t")))))
(DTypeSig false "methodDefaultSexp" (TyFun (TyApp (TyCon "Option") (TyCon "MethodDefault")) (TyCon "String")))
(DFunDef false "methodDefaultSexp" ((PCon "None")) (ELit (LString "None")))
(DFunDef false "methodDefaultSexp" ((PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body")))) (EApp (EApp (EVar "node") (ELit (LString "mdef"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EVar "exprSexp") (EVar "body")))))
(DTypeSig false "ifaceMethodSexp" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodSexp" ((PCon "IfaceMethod" (PVar "name") (PVar "ty") (PVar "def"))) (EApp (EApp (EVar "node") (ELit (LString "imethod"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "tySexp") (EVar "ty")) (EApp (EVar "methodDefaultSexp") (EVar "def")))))
(DTypeSig false "superSexp" (TyFun (TyCon "Super") (TyCon "String")))
(DFunDef false "superSexp" ((PCon "Super" (PVar "iface") (PVar "params"))) (EApp (EApp (EVar "node") (ELit (LString "super"))) (EListLit (EApp (EVar "escStr") (EVar "iface")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "params"))))))
(DTypeSig false "requireSexp" (TyFun (TyCon "Require") (TyCon "String")))
(DFunDef false "requireSexp" ((PCon "Require" (PVar "iface") (PVar "tys"))) (EApp (EApp (EVar "node") (ELit (LString "req"))) (EListLit (EApp (EVar "escStr") (EVar "iface")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "tySexp")) (EVar "tys"))))))
(DTypeSig false "implMethodSexp" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodSexp" ((PCon "ImplMethod" (PVar "name") (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "im"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EVar "exprSexp") (EVar "body")))))
(DTypeSig false "useMemberSexp" (TyFun (TyCon "UseMember") (TyCon "String")))
(DFunDef false "useMemberSexp" ((PCon "UseMember" (PVar "n") (PVar "withAll") PWild (PVar "alias"))) (EMatch (EVar "alias") (arm (PCon "Some" (PVar "a")) () (EApp (EApp (EVar "node") (ELit (LString "mem"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "boolStr") (EVar "withAll")) (EApp (EVar "escStr") (EVar "a"))))) (arm (PCon "None") () (EApp (EApp (EVar "node") (ELit (LString "mem"))) (EListLit (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "boolStr") (EVar "withAll")))))))
(DTypeSig false "usePathSexp" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "usePathSexp" ((PCon "UseName" (PVar "ids"))) (EApp (EApp (EVar "node") (ELit (LString "UseName"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "ids"))))))
(DFunDef false "usePathSexp" ((PCon "UseGroup" (PVar "ids") (PVar "ms"))) (EApp (EApp (EVar "node") (ELit (LString "UseGroup"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "ids"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "useMemberSexp")) (EVar "ms"))))))
(DFunDef false "usePathSexp" ((PCon "UseWild" (PVar "ids"))) (EApp (EApp (EVar "node") (ELit (LString "UseWild"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "ids"))))))
(DFunDef false "usePathSexp" ((PCon "UseAlias" (PVar "ids") (PVar "a"))) (EApp (EApp (EVar "node") (ELit (LString "UseAlias"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "ids"))) (EApp (EVar "escStr") (EVar "a")))))
(DTypeSig true "programToSexp" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "programToSexp" ((PVar "prog")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "declSexp")) (EVar "prog"))))
