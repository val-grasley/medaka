# META
source_lines=231
stages=DESUGAR,MARK
# SOURCE
-- Structural S-expression dump of the Core IR (STAGE2-DESIGN §2.1).  Mirrors
-- sexp.mdk's style (AST dump) so the format is familiar; cprogramToSexp is the
-- canonical entry point and the frozen IR's serialization contract.
--
-- Losslessness: every field is serialized, including the lexical Addr on CVar
-- and the dispatch Routes on CMethod/CDict, so a parsed-back CProgram carries
-- the same structural information as the in-memory lowered program.
--
-- Sub-serializers are all exported so a future round-trip parser can import
-- them for cross-checking (parse-back → re-dump → assert identical output).

import frontend.ast.{Lit(..), Pat(..), Addr(..), Route(..)}
import ir.core_ir.{
  CExpr(..),
  CArm(..),
  CGuard(..),
  CStmt(..),
  CField(..),
  CBind(..),
  CClause(..),
  CImplEntry(..),
  CImplBody(..),
  CProgram(..),
  CTree(..),
  CTBranch(..),
  CHead(..),
}
import ir.sexp.{boolStr, node, slist, litSexp, patSexp}
import support.util.{escStr, joinNl}

-- ── Addr and Route ─────────────────────────────────────────────────────────────

export addrSexp : Addr -> String
addrSexp (ALocal frame slot) =
  node "ALocal" [intToString frame, intToString slot]
addrSexp AGlobal = "AGlobal"

-- FAITHFUL-ROUTE mode (#686).  DEFAULT False → the golden/round-trip projection
-- below, byte-identical to every committed core_ir_sexp/snapshot golden.  Set True
-- ONLY by a debug probe entry (core_ir_typed_modules_dump_main.mdk) via
-- setFaithfulRoutes so `routeSexp` emits `RKey`/`RLocal`'s nested `List Route` —
-- the element/impl dicts — which the golden projection deliberately drops.  Without
-- this a null element route (`RKey "List" [RNone]`) and a resolved one
-- (`RKey "List" [RKey "Int" []]`) serialize IDENTICALLY, so the typed-IR dump the
-- docs bill as the highest-value dict-route probe is blind to exactly the class of
-- bug it is reached for (a null element dict → build SIGSEGV, #410/#669).
faithfulRoutesRef : Ref Bool
faithfulRoutesRef = Ref False

-- Enable/disable the faithful nested-route projection.  Debug-only: NEVER call this
-- on a golden-producing path (snapshot.mdk / round-trip) — it moves the corpus.
export setFaithfulRoutes : Bool -> Unit
setFaithfulRoutes b = setRef faithfulRoutesRef b

export routeSexp : Route -> String
routeSexp RNone = "RNone"
routeSexp (RKey k ds) =
  if faithfulRoutesRef.value then
    node "RKey" [escStr k, slist (map routeSexp ds)]
  else
    node "RKey" [escStr k]
routeSexp (RDict d) = node "RDict" [escStr d]
routeSexp (RDictFwd d) = node "RDictFwd" [escStr d]
-- S-1: the dict list is DROPPED in the DEFAULT projection, exactly as RKey's nested
-- requires-routes are — the S-expr form is a debug/golden projection, not a faithful
-- round-trip of the route.  Keeping it lossy holds every core_ir_sexp golden
-- byte-identical across the S-1 route widening.  The faithful arm (above/below) is
-- gated behind faithfulRoutesRef so ONLY the debug probe pays the widening.
routeSexp (RLocal "" ds) =
  if faithfulRoutesRef.value then
    node "RLocal" [escStr "", slist (map routeSexp ds)]
  else
    "RLocal"
routeSexp (RLocal s ds) =
  if faithfulRoutesRef.value then
    node "RLocal" [escStr s, slist (map routeSexp ds)]
  else
    node "RLocal" [escStr s]
routeSexp (RScalar s) = node "RScalar" [escStr s]

-- ── CExpr ─────────────────────────────────────────────────────────────────────

export cexprSexp : CExpr -> String
cexprSexp (CLit l) = node "CLit" [litSexp l]
cexprSexp (CVar x addr) = node "CVar" [escStr x, addrSexp addr]
cexprSexp (CApp f x) = node "CApp" [cexprSexp f, cexprSexp x]
cexprSexp (CLam pats body) =
  node "CLam" [slist (map patSexp pats), cexprSexp body]
cexprSexp (CLet isRec pat e1 e2) =
  node "CLet" [boolStr isRec, patSexp pat, cexprSexp e1, cexprSexp e2]
cexprSexp (CLetGroup binds body) =
  node "CLetGroup" [slist (map cbindSexp binds), cexprSexp body]
cexprSexp (CMatch scrut arms) =
  node "CMatch" (cexprSexp scrut :: map carmSexp arms)
cexprSexp (CDecision scrut arms tree) =
  node "CDecision" [cexprSexp scrut, slist (map carmSexp arms), ctreeSexp tree]
cexprSexp (CIf c t e) = node "CIf" [cexprSexp c, cexprSexp t, cexprSexp e]
cexprSexp (CBinPrim op l r tag) =
  if tag == "" then
    node "CBinPrim" [escStr op, cexprSexp l, cexprSexp r]
  else
    node "CBinPrim" [escStr op, cexprSexp l, cexprSexp r, escStr tag]
cexprSexp (CUnOp op e) = node "CUnOp" [escStr op, cexprSexp e]
cexprSexp (CTuple es) = node "CTuple" (map cexprSexp es)
cexprSexp (CList es) = node "CList" (map cexprSexp es)
cexprSexp (CRecord name fields) =
  node "CRecord" (escStr name :: map cfieldSexp fields)
cexprSexp (CFieldAccess e f n) =
  node "CFieldAccess" [cexprSexp e, escStr f, escStr n]
cexprSexp (CRecordUpdate name base fields) =
  node "CRecordUpdate" (escStr name :: cexprSexp base :: map cfieldSexp fields)
cexprSexp (CVariantUpdate con base fields) =
  node "CVariantUpdate" (escStr con :: cexprSexp base :: map cfieldSexp fields)
cexprSexp (CArray es) = node "CArray" (map cexprSexp es)
cexprSexp (CRangeList lo hi incl) =
  node "CRangeList" [cexprSexp lo, cexprSexp hi, boolStr incl]
cexprSexp (CRangeArray lo hi incl) =
  node "CRangeArray" [cexprSexp lo, cexprSexp hi, boolStr incl]
cexprSexp (CIndex a i) = node "CIndex" [cexprSexp a, cexprSexp i]
cexprSexp (CSlice a lo hi incl) =
  node "CSlice" [cexprSexp a, cexprSexp lo, cexprSexp hi, boolStr incl]
cexprSexp (CStringIndex a i) = node "CStringIndex" [cexprSexp a, cexprSexp i]
cexprSexp (CStringSlice a lo hi incl) =
  node "CStringSlice" [cexprSexp a, cexprSexp lo, cexprSexp hi, boolStr incl]
cexprSexp (CListIndex a i) = node "CListIndex" [cexprSexp a, cexprSexp i]
cexprSexp (CListSlice a lo hi incl) =
  node "CListSlice" [cexprSexp a, cexprSexp lo, cexprSexp hi, boolStr incl]
cexprSexp (CBlock stmts) = node "CBlock" (map cstmtSexp stmts)
cexprSexp (CMethod name route implRoutes methRoutes) = node
  "CMethod"
  [
    escStr name,
    routeSexp route,
    slist (map routeSexp implRoutes),
    slist (map routeSexp methRoutes),
  ]
cexprSexp (CDict name routes) =
  node "CDict" [escStr name, slist (map routeSexp routes)]

-- ── CField ────────────────────────────────────────────────────────────────────

export cfieldSexp : CField -> String
cfieldSexp (CField name e) = node "cf" [escStr name, cexprSexp e]

-- ── CArm, CGuard ─────────────────────────────────────────────────────────────

export carmSexp : CArm -> String
carmSexp (CArm pat guards body) =
  node "arm" [patSexp pat, slist (map cguardSexp guards), cexprSexp body]

export cguardSexp : CGuard -> String
cguardSexp (CGBool e) = node "CGBool" [cexprSexp e]
cguardSexp (CGBind pat e) = node "CGBind" [patSexp pat, cexprSexp e]

-- ── Decision tree ─────────────────────────────────────────────────────────────

export ctreeSexp : CTree -> String
ctreeSexp CTFail = "CTFail"
ctreeSexp (CTLeaf i) = node "CTLeaf" [intToString i]
ctreeSexp (CTGuard i fail) = node "CTGuard" [intToString i, ctreeSexp fail]
ctreeSexp (CTSwitch branches dflt) =
  node "CTSwitch" [slist (map ctbranchSexp branches), ctreeSexp dflt]
ctreeSexp (CTDrop tree) = node "CTDrop" [ctreeSexp tree]

export ctbranchSexp : CTBranch -> String
ctbranchSexp (CTBranch head tree) =
  node "CTBranch" [cheadSexp head, ctreeSexp tree]

export cheadSexp : CHead -> String
cheadSexp (HCon name arity) = node "HCon" [escStr name, intToString arity]
cheadSexp (HTuple arity) = node "HTuple" [intToString arity]
cheadSexp HCons = "HCons"
cheadSexp HNil = "HNil"
cheadSexp HUnit = "HUnit"
cheadSexp (HLit l) = node "HLit" [litSexp l]

-- ── CStmt ─────────────────────────────────────────────────────────────────────

export cstmtSexp : CStmt -> String
cstmtSexp (CSExpr e) = node "CSExpr" [cexprSexp e]
cstmtSexp (CSLet isRec pat e) =
  node "CSLet" [boolStr isRec, patSexp pat, cexprSexp e]
cstmtSexp (CSAssign x e) = node "CSAssign" [escStr x, cexprSexp e]

-- ── CBind, CClause ────────────────────────────────────────────────────────────

export cbindSexp : CBind -> String
cbindSexp (CBind name clauses) =
  node "CBind" (escStr name :: map cclauseSexp clauses)

export cclauseSexp : CClause -> String
cclauseSexp (CClause pats body) =
  node "CClause" [slist (map patSexp pats), cexprSexp body]

-- ── CImplEntry, CImplBody ─────────────────────────────────────────────────────

export cimplBodySexp : CImplBody -> String
cimplBodySexp (CImplTagged tag key iface positions pats body) = node
  "CImplTagged"
  [
    escStr tag,
    escStr key,
    escStr iface,
    slist (map intToString positions),
    slist (map patSexp pats),
    cexprSexp body,
  ]
cimplBodySexp (CImplDefault pats body) =
  node "CImplDefault" [slist (map patSexp pats), cexprSexp body]

export cimplEntrySexp : CImplEntry -> String
cimplEntrySexp (CImplEntry name score body) =
  node "CImplEntry" [escStr name, intToString score, cimplBodySexp body]

-- ── CProgram ─────────────────────────────────────────────────────────────────

ctorArityPairSexp : (String, Int) -> String
ctorArityPairSexp (name, arity) = node "ca" [escStr name, intToString arity]

ctorTypePairSexp : (String, String) -> String
ctorTypePairSexp (ctor, ty) = node "ct" [escStr ctor, escStr ty]

export cprogramToSexp : CProgram -> String
cprogramToSexp (CProgram binds ctorArities ctorToType impls) = node
  "CProgram"
  [
    slist (map cbindSexp binds),
    slist (map ctorArityPairSexp ctorArities),
    slist (map ctorTypePairSexp ctorToType),
    slist (map cimplEntrySexp impls),
  ]
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true) (mem "Addr" true) (mem "Route" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CProgram" true) (mem "CTree" true) (mem "CTBranch" true) (mem "CHead" true))))
(DUse false (UseGroup ("ir" "sexp") ((mem "boolStr" false) (mem "node" false) (mem "slist" false) (mem "litSexp" false) (mem "patSexp" false))))
(DUse false (UseGroup ("support" "util") ((mem "escStr" false) (mem "joinNl" false))))
(DTypeSig true "addrSexp" (TyFun (TyCon "Addr") (TyCon "String")))
(DFunDef false "addrSexp" ((PCon "ALocal" (PVar "frame") (PVar "slot"))) (EApp (EApp (EVar "node") (ELit (LString "ALocal"))) (EListLit (EApp (EVar "intToString") (EVar "frame")) (EApp (EVar "intToString") (EVar "slot")))))
(DFunDef false "addrSexp" ((PCon "AGlobal")) (ELit (LString "AGlobal")))
(DTypeSig false "faithfulRoutesRef" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "faithfulRoutesRef" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig true "setFaithfulRoutes" (TyFun (TyCon "Bool") (TyCon "Unit")))
(DFunDef false "setFaithfulRoutes" ((PVar "b")) (EApp (EApp (EVar "setRef") (EVar "faithfulRoutesRef")) (EVar "b")))
(DTypeSig true "routeSexp" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "routeSexp" ((PCon "RNone")) (ELit (LString "RNone")))
(DFunDef false "routeSexp" ((PCon "RKey" (PVar "k") (PVar "ds"))) (EIf (EFieldAccess (EVar "faithfulRoutesRef") "value") (EApp (EApp (EVar "node") (ELit (LString "RKey"))) (EListLit (EApp (EVar "escStr") (EVar "k")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "routeSexp")) (EVar "ds"))))) (EApp (EApp (EVar "node") (ELit (LString "RKey"))) (EListLit (EApp (EVar "escStr") (EVar "k"))))))
(DFunDef false "routeSexp" ((PCon "RDict" (PVar "d"))) (EApp (EApp (EVar "node") (ELit (LString "RDict"))) (EListLit (EApp (EVar "escStr") (EVar "d")))))
(DFunDef false "routeSexp" ((PCon "RDictFwd" (PVar "d"))) (EApp (EApp (EVar "node") (ELit (LString "RDictFwd"))) (EListLit (EApp (EVar "escStr") (EVar "d")))))
(DFunDef false "routeSexp" ((PCon "RLocal" (PLit (LString "")) (PVar "ds"))) (EIf (EFieldAccess (EVar "faithfulRoutesRef") "value") (EApp (EApp (EVar "node") (ELit (LString "RLocal"))) (EListLit (EApp (EVar "escStr") (ELit (LString ""))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "routeSexp")) (EVar "ds"))))) (ELit (LString "RLocal"))))
(DFunDef false "routeSexp" ((PCon "RLocal" (PVar "s") (PVar "ds"))) (EIf (EFieldAccess (EVar "faithfulRoutesRef") "value") (EApp (EApp (EVar "node") (ELit (LString "RLocal"))) (EListLit (EApp (EVar "escStr") (EVar "s")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "routeSexp")) (EVar "ds"))))) (EApp (EApp (EVar "node") (ELit (LString "RLocal"))) (EListLit (EApp (EVar "escStr") (EVar "s"))))))
(DFunDef false "routeSexp" ((PCon "RScalar" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "RScalar"))) (EListLit (EApp (EVar "escStr") (EVar "s")))))
(DTypeSig true "cexprSexp" (TyFun (TyCon "CExpr") (TyCon "String")))
(DFunDef false "cexprSexp" ((PCon "CLit" (PVar "l"))) (EApp (EApp (EVar "node") (ELit (LString "CLit"))) (EListLit (EApp (EVar "litSexp") (EVar "l")))))
(DFunDef false "cexprSexp" ((PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "node") (ELit (LString "CVar"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EVar "addrSexp") (EVar "addr")))))
(DFunDef false "cexprSexp" ((PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "node") (ELit (LString "CApp"))) (EListLit (EApp (EVar "cexprSexp") (EVar "f")) (EApp (EVar "cexprSexp") (EVar "x")))))
(DFunDef false "cexprSexp" ((PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CLam"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EVar "cexprSexp") (EVar "body")))))
(DFunDef false "cexprSexp" ((PCon "CLet" (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EVar "node") (ELit (LString "CLet"))) (EListLit (EApp (EVar "boolStr") (EVar "isRec")) (EApp (EVar "patSexp") (EVar "pat")) (EApp (EVar "cexprSexp") (EVar "e1")) (EApp (EVar "cexprSexp") (EVar "e2")))))
(DFunDef false "cexprSexp" ((PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CLetGroup"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "cbindSexp")) (EVar "binds"))) (EApp (EVar "cexprSexp") (EVar "body")))))
(DFunDef false "cexprSexp" ((PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "node") (ELit (LString "CMatch"))) (EBinOp "::" (EApp (EVar "cexprSexp") (EVar "scrut")) (EApp (EApp (EVar "map") (EVar "carmSexp")) (EVar "arms")))))
(DFunDef false "cexprSexp" ((PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EVar "node") (ELit (LString "CDecision"))) (EListLit (EApp (EVar "cexprSexp") (EVar "scrut")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "carmSexp")) (EVar "arms"))) (EApp (EVar "ctreeSexp") (EVar "tree")))))
(DFunDef false "cexprSexp" ((PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CIf"))) (EListLit (EApp (EVar "cexprSexp") (EVar "c")) (EApp (EVar "cexprSexp") (EVar "t")) (EApp (EVar "cexprSexp") (EVar "e")))))
(DFunDef false "cexprSexp" ((PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag"))) (EIf (EBinOp "==" (EVar "tag") (ELit (LString ""))) (EApp (EApp (EVar "node") (ELit (LString "CBinPrim"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EVar "cexprSexp") (EVar "l")) (EApp (EVar "cexprSexp") (EVar "r")))) (EApp (EApp (EVar "node") (ELit (LString "CBinPrim"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EVar "cexprSexp") (EVar "l")) (EApp (EVar "cexprSexp") (EVar "r")) (EApp (EVar "escStr") (EVar "tag"))))))
(DFunDef false "cexprSexp" ((PCon "CUnOp" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CUnOp"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EVar "cexprSexp") (EVar "e")))))
(DFunDef false "cexprSexp" ((PCon "CTuple" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "CTuple"))) (EApp (EApp (EVar "map") (EVar "cexprSexp")) (EVar "es"))))
(DFunDef false "cexprSexp" ((PCon "CList" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "CList"))) (EApp (EApp (EVar "map") (EVar "cexprSexp")) (EVar "es"))))
(DFunDef false "cexprSexp" ((PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "node") (ELit (LString "CRecord"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "name")) (EApp (EApp (EVar "map") (EVar "cfieldSexp")) (EVar "fields")))))
(DFunDef false "cexprSexp" ((PCon "CFieldAccess" (PVar "e") (PVar "f") (PVar "n"))) (EApp (EApp (EVar "node") (ELit (LString "CFieldAccess"))) (EListLit (EApp (EVar "cexprSexp") (EVar "e")) (EApp (EVar "escStr") (EVar "f")) (EApp (EVar "escStr") (EVar "n")))))
(DFunDef false "cexprSexp" ((PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EVar "node") (ELit (LString "CRecordUpdate"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "name")) (EBinOp "::" (EApp (EVar "cexprSexp") (EVar "base")) (EApp (EApp (EVar "map") (EVar "cfieldSexp")) (EVar "fields"))))))
(DFunDef false "cexprSexp" ((PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EVar "node") (ELit (LString "CVariantUpdate"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "con")) (EBinOp "::" (EApp (EVar "cexprSexp") (EVar "base")) (EApp (EApp (EVar "map") (EVar "cfieldSexp")) (EVar "fields"))))))
(DFunDef false "cexprSexp" ((PCon "CArray" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "CArray"))) (EApp (EApp (EVar "map") (EVar "cexprSexp")) (EVar "es"))))
(DFunDef false "cexprSexp" ((PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CRangeList"))) (EListLit (EApp (EVar "cexprSexp") (EVar "lo")) (EApp (EVar "cexprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CRangeArray"))) (EListLit (EApp (EVar "cexprSexp") (EVar "lo")) (EApp (EVar "cexprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CIndex"))) (EListLit (EApp (EVar "cexprSexp") (EVar "a")) (EApp (EVar "cexprSexp") (EVar "i")))))
(DFunDef false "cexprSexp" ((PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CSlice"))) (EListLit (EApp (EVar "cexprSexp") (EVar "a")) (EApp (EVar "cexprSexp") (EVar "lo")) (EApp (EVar "cexprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CStringIndex"))) (EListLit (EApp (EVar "cexprSexp") (EVar "a")) (EApp (EVar "cexprSexp") (EVar "i")))))
(DFunDef false "cexprSexp" ((PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CStringSlice"))) (EListLit (EApp (EVar "cexprSexp") (EVar "a")) (EApp (EVar "cexprSexp") (EVar "lo")) (EApp (EVar "cexprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CListIndex"))) (EListLit (EApp (EVar "cexprSexp") (EVar "a")) (EApp (EVar "cexprSexp") (EVar "i")))))
(DFunDef false "cexprSexp" ((PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CListSlice"))) (EListLit (EApp (EVar "cexprSexp") (EVar "a")) (EApp (EVar "cexprSexp") (EVar "lo")) (EApp (EVar "cexprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "node") (ELit (LString "CBlock"))) (EApp (EApp (EVar "map") (EVar "cstmtSexp")) (EVar "stmts"))))
(DFunDef false "cexprSexp" ((PCon "CMethod" (PVar "name") (PVar "route") (PVar "implRoutes") (PVar "methRoutes"))) (EApp (EApp (EVar "node") (ELit (LString "CMethod"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "routeSexp") (EVar "route")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "routeSexp")) (EVar "implRoutes"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "routeSexp")) (EVar "methRoutes"))))))
(DFunDef false "cexprSexp" ((PCon "CDict" (PVar "name") (PVar "routes"))) (EApp (EApp (EVar "node") (ELit (LString "CDict"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "routeSexp")) (EVar "routes"))))))
(DTypeSig true "cfieldSexp" (TyFun (TyCon "CField") (TyCon "String")))
(DFunDef false "cfieldSexp" ((PCon "CField" (PVar "name") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "cf"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "cexprSexp") (EVar "e")))))
(DTypeSig true "carmSexp" (TyFun (TyCon "CArm") (TyCon "String")))
(DFunDef false "carmSexp" ((PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "arm"))) (EListLit (EApp (EVar "patSexp") (EVar "pat")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "cguardSexp")) (EVar "guards"))) (EApp (EVar "cexprSexp") (EVar "body")))))
(DTypeSig true "cguardSexp" (TyFun (TyCon "CGuard") (TyCon "String")))
(DFunDef false "cguardSexp" ((PCon "CGBool" (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CGBool"))) (EListLit (EApp (EVar "cexprSexp") (EVar "e")))))
(DFunDef false "cguardSexp" ((PCon "CGBind" (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CGBind"))) (EListLit (EApp (EVar "patSexp") (EVar "pat")) (EApp (EVar "cexprSexp") (EVar "e")))))
(DTypeSig true "ctreeSexp" (TyFun (TyCon "CTree") (TyCon "String")))
(DFunDef false "ctreeSexp" ((PCon "CTFail")) (ELit (LString "CTFail")))
(DFunDef false "ctreeSexp" ((PCon "CTLeaf" (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CTLeaf"))) (EListLit (EApp (EVar "intToString") (EVar "i")))))
(DFunDef false "ctreeSexp" ((PCon "CTGuard" (PVar "i") (PVar "fail"))) (EApp (EApp (EVar "node") (ELit (LString "CTGuard"))) (EListLit (EApp (EVar "intToString") (EVar "i")) (EApp (EVar "ctreeSexp") (EVar "fail")))))
(DFunDef false "ctreeSexp" ((PCon "CTSwitch" (PVar "branches") (PVar "dflt"))) (EApp (EApp (EVar "node") (ELit (LString "CTSwitch"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "ctbranchSexp")) (EVar "branches"))) (EApp (EVar "ctreeSexp") (EVar "dflt")))))
(DFunDef false "ctreeSexp" ((PCon "CTDrop" (PVar "tree"))) (EApp (EApp (EVar "node") (ELit (LString "CTDrop"))) (EListLit (EApp (EVar "ctreeSexp") (EVar "tree")))))
(DTypeSig true "ctbranchSexp" (TyFun (TyCon "CTBranch") (TyCon "String")))
(DFunDef false "ctbranchSexp" ((PCon "CTBranch" (PVar "head") (PVar "tree"))) (EApp (EApp (EVar "node") (ELit (LString "CTBranch"))) (EListLit (EApp (EVar "cheadSexp") (EVar "head")) (EApp (EVar "ctreeSexp") (EVar "tree")))))
(DTypeSig true "cheadSexp" (TyFun (TyCon "CHead") (TyCon "String")))
(DFunDef false "cheadSexp" ((PCon "HCon" (PVar "name") (PVar "arity"))) (EApp (EApp (EVar "node") (ELit (LString "HCon"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "intToString") (EVar "arity")))))
(DFunDef false "cheadSexp" ((PCon "HTuple" (PVar "arity"))) (EApp (EApp (EVar "node") (ELit (LString "HTuple"))) (EListLit (EApp (EVar "intToString") (EVar "arity")))))
(DFunDef false "cheadSexp" ((PCon "HCons")) (ELit (LString "HCons")))
(DFunDef false "cheadSexp" ((PCon "HNil")) (ELit (LString "HNil")))
(DFunDef false "cheadSexp" ((PCon "HUnit")) (ELit (LString "HUnit")))
(DFunDef false "cheadSexp" ((PCon "HLit" (PVar "l"))) (EApp (EApp (EVar "node") (ELit (LString "HLit"))) (EListLit (EApp (EVar "litSexp") (EVar "l")))))
(DTypeSig true "cstmtSexp" (TyFun (TyCon "CStmt") (TyCon "String")))
(DFunDef false "cstmtSexp" ((PCon "CSExpr" (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CSExpr"))) (EListLit (EApp (EVar "cexprSexp") (EVar "e")))))
(DFunDef false "cstmtSexp" ((PCon "CSLet" (PVar "isRec") (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CSLet"))) (EListLit (EApp (EVar "boolStr") (EVar "isRec")) (EApp (EVar "patSexp") (EVar "pat")) (EApp (EVar "cexprSexp") (EVar "e")))))
(DFunDef false "cstmtSexp" ((PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CSAssign"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EVar "cexprSexp") (EVar "e")))))
(DTypeSig true "cbindSexp" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "cbindSexp" ((PCon "CBind" (PVar "name") (PVar "clauses"))) (EApp (EApp (EVar "node") (ELit (LString "CBind"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "name")) (EApp (EApp (EVar "map") (EVar "cclauseSexp")) (EVar "clauses")))))
(DTypeSig true "cclauseSexp" (TyFun (TyCon "CClause") (TyCon "String")))
(DFunDef false "cclauseSexp" ((PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CClause"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EVar "cexprSexp") (EVar "body")))))
(DTypeSig true "cimplBodySexp" (TyFun (TyCon "CImplBody") (TyCon "String")))
(DFunDef false "cimplBodySexp" ((PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "positions") (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CImplTagged"))) (EListLit (EApp (EVar "escStr") (EVar "tag")) (EApp (EVar "escStr") (EVar "key")) (EApp (EVar "escStr") (EVar "iface")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "intToString")) (EVar "positions"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EVar "cexprSexp") (EVar "body")))))
(DFunDef false "cimplBodySexp" ((PCon "CImplDefault" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CImplDefault"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EVar "cexprSexp") (EVar "body")))))
(DTypeSig true "cimplEntrySexp" (TyFun (TyCon "CImplEntry") (TyCon "String")))
(DFunDef false "cimplEntrySexp" ((PCon "CImplEntry" (PVar "name") (PVar "score") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CImplEntry"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "intToString") (EVar "score")) (EApp (EVar "cimplBodySexp") (EVar "body")))))
(DTypeSig false "ctorArityPairSexp" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "String")))
(DFunDef false "ctorArityPairSexp" ((PTuple (PVar "name") (PVar "arity"))) (EApp (EApp (EVar "node") (ELit (LString "ca"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "intToString") (EVar "arity")))))
(DTypeSig false "ctorTypePairSexp" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "ctorTypePairSexp" ((PTuple (PVar "ctor") (PVar "ty"))) (EApp (EApp (EVar "node") (ELit (LString "ct"))) (EListLit (EApp (EVar "escStr") (EVar "ctor")) (EApp (EVar "escStr") (EVar "ty")))))
(DTypeSig true "cprogramToSexp" (TyFun (TyCon "CProgram") (TyCon "String")))
(DFunDef false "cprogramToSexp" ((PCon "CProgram" (PVar "binds") (PVar "ctorArities") (PVar "ctorToType") (PVar "impls"))) (EApp (EApp (EVar "node") (ELit (LString "CProgram"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "cbindSexp")) (EVar "binds"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "ctorArityPairSexp")) (EVar "ctorArities"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "ctorTypePairSexp")) (EVar "ctorToType"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "cimplEntrySexp")) (EVar "impls"))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true) (mem "Addr" true) (mem "Route" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CProgram" true) (mem "CTree" true) (mem "CTBranch" true) (mem "CHead" true))))
(DUse false (UseGroup ("ir" "sexp") ((mem "boolStr" false) (mem "node" false) (mem "slist" false) (mem "litSexp" false) (mem "patSexp" false))))
(DUse false (UseGroup ("support" "util") ((mem "escStr" false) (mem "joinNl" false))))
(DTypeSig true "addrSexp" (TyFun (TyCon "Addr") (TyCon "String")))
(DFunDef false "addrSexp" ((PCon "ALocal" (PVar "frame") (PVar "slot"))) (EApp (EApp (EVar "node") (ELit (LString "ALocal"))) (EListLit (EApp (EVar "intToString") (EVar "frame")) (EApp (EVar "intToString") (EVar "slot")))))
(DFunDef false "addrSexp" ((PCon "AGlobal")) (ELit (LString "AGlobal")))
(DTypeSig false "faithfulRoutesRef" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "faithfulRoutesRef" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig true "setFaithfulRoutes" (TyFun (TyCon "Bool") (TyCon "Unit")))
(DFunDef false "setFaithfulRoutes" ((PVar "b")) (EApp (EApp (EVar "setRef") (EVar "faithfulRoutesRef")) (EVar "b")))
(DTypeSig true "routeSexp" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "routeSexp" ((PCon "RNone")) (ELit (LString "RNone")))
(DFunDef false "routeSexp" ((PCon "RKey" (PVar "k") (PVar "ds"))) (EIf (EFieldAccess (EVar "faithfulRoutesRef") "value") (EApp (EApp (EVar "node") (ELit (LString "RKey"))) (EListLit (EApp (EVar "escStr") (EVar "k")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "routeSexp")) (EVar "ds"))))) (EApp (EApp (EVar "node") (ELit (LString "RKey"))) (EListLit (EApp (EVar "escStr") (EVar "k"))))))
(DFunDef false "routeSexp" ((PCon "RDict" (PVar "d"))) (EApp (EApp (EVar "node") (ELit (LString "RDict"))) (EListLit (EApp (EVar "escStr") (EVar "d")))))
(DFunDef false "routeSexp" ((PCon "RDictFwd" (PVar "d"))) (EApp (EApp (EVar "node") (ELit (LString "RDictFwd"))) (EListLit (EApp (EVar "escStr") (EVar "d")))))
(DFunDef false "routeSexp" ((PCon "RLocal" (PLit (LString "")) (PVar "ds"))) (EIf (EFieldAccess (EVar "faithfulRoutesRef") "value") (EApp (EApp (EVar "node") (ELit (LString "RLocal"))) (EListLit (EApp (EVar "escStr") (ELit (LString ""))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "routeSexp")) (EVar "ds"))))) (ELit (LString "RLocal"))))
(DFunDef false "routeSexp" ((PCon "RLocal" (PVar "s") (PVar "ds"))) (EIf (EFieldAccess (EVar "faithfulRoutesRef") "value") (EApp (EApp (EVar "node") (ELit (LString "RLocal"))) (EListLit (EApp (EVar "escStr") (EVar "s")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "routeSexp")) (EVar "ds"))))) (EApp (EApp (EVar "node") (ELit (LString "RLocal"))) (EListLit (EApp (EVar "escStr") (EVar "s"))))))
(DFunDef false "routeSexp" ((PCon "RScalar" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "RScalar"))) (EListLit (EApp (EVar "escStr") (EVar "s")))))
(DTypeSig true "cexprSexp" (TyFun (TyCon "CExpr") (TyCon "String")))
(DFunDef false "cexprSexp" ((PCon "CLit" (PVar "l"))) (EApp (EApp (EVar "node") (ELit (LString "CLit"))) (EListLit (EApp (EVar "litSexp") (EVar "l")))))
(DFunDef false "cexprSexp" ((PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "node") (ELit (LString "CVar"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EVar "addrSexp") (EVar "addr")))))
(DFunDef false "cexprSexp" ((PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "node") (ELit (LString "CApp"))) (EListLit (EApp (EVar "cexprSexp") (EVar "f")) (EApp (EVar "cexprSexp") (EVar "x")))))
(DFunDef false "cexprSexp" ((PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CLam"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EVar "cexprSexp") (EVar "body")))))
(DFunDef false "cexprSexp" ((PCon "CLet" (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EVar "node") (ELit (LString "CLet"))) (EListLit (EApp (EVar "boolStr") (EVar "isRec")) (EApp (EVar "patSexp") (EVar "pat")) (EApp (EVar "cexprSexp") (EVar "e1")) (EApp (EVar "cexprSexp") (EVar "e2")))))
(DFunDef false "cexprSexp" ((PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CLetGroup"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "cbindSexp")) (EVar "binds"))) (EApp (EVar "cexprSexp") (EVar "body")))))
(DFunDef false "cexprSexp" ((PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "node") (ELit (LString "CMatch"))) (EBinOp "::" (EApp (EVar "cexprSexp") (EVar "scrut")) (EApp (EApp (EMethodRef "map") (EVar "carmSexp")) (EVar "arms")))))
(DFunDef false "cexprSexp" ((PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EVar "node") (ELit (LString "CDecision"))) (EListLit (EApp (EVar "cexprSexp") (EVar "scrut")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "carmSexp")) (EVar "arms"))) (EApp (EVar "ctreeSexp") (EVar "tree")))))
(DFunDef false "cexprSexp" ((PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CIf"))) (EListLit (EApp (EVar "cexprSexp") (EVar "c")) (EApp (EVar "cexprSexp") (EVar "t")) (EApp (EVar "cexprSexp") (EVar "e")))))
(DFunDef false "cexprSexp" ((PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag"))) (EIf (EBinOp "==" (EVar "tag") (ELit (LString ""))) (EApp (EApp (EVar "node") (ELit (LString "CBinPrim"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EVar "cexprSexp") (EVar "l")) (EApp (EVar "cexprSexp") (EVar "r")))) (EApp (EApp (EVar "node") (ELit (LString "CBinPrim"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EVar "cexprSexp") (EVar "l")) (EApp (EVar "cexprSexp") (EVar "r")) (EApp (EVar "escStr") (EVar "tag"))))))
(DFunDef false "cexprSexp" ((PCon "CUnOp" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CUnOp"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EVar "cexprSexp") (EVar "e")))))
(DFunDef false "cexprSexp" ((PCon "CTuple" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "CTuple"))) (EApp (EApp (EMethodRef "map") (EVar "cexprSexp")) (EVar "es"))))
(DFunDef false "cexprSexp" ((PCon "CList" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "CList"))) (EApp (EApp (EMethodRef "map") (EVar "cexprSexp")) (EVar "es"))))
(DFunDef false "cexprSexp" ((PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "node") (ELit (LString "CRecord"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "cfieldSexp")) (EVar "fields")))))
(DFunDef false "cexprSexp" ((PCon "CFieldAccess" (PVar "e") (PVar "f") (PVar "n"))) (EApp (EApp (EVar "node") (ELit (LString "CFieldAccess"))) (EListLit (EApp (EVar "cexprSexp") (EVar "e")) (EApp (EVar "escStr") (EVar "f")) (EApp (EVar "escStr") (EVar "n")))))
(DFunDef false "cexprSexp" ((PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EVar "node") (ELit (LString "CRecordUpdate"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "name")) (EBinOp "::" (EApp (EVar "cexprSexp") (EVar "base")) (EApp (EApp (EMethodRef "map") (EVar "cfieldSexp")) (EVar "fields"))))))
(DFunDef false "cexprSexp" ((PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EVar "node") (ELit (LString "CVariantUpdate"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "con")) (EBinOp "::" (EApp (EVar "cexprSexp") (EVar "base")) (EApp (EApp (EMethodRef "map") (EVar "cfieldSexp")) (EVar "fields"))))))
(DFunDef false "cexprSexp" ((PCon "CArray" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "CArray"))) (EApp (EApp (EMethodRef "map") (EVar "cexprSexp")) (EVar "es"))))
(DFunDef false "cexprSexp" ((PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CRangeList"))) (EListLit (EApp (EVar "cexprSexp") (EVar "lo")) (EApp (EVar "cexprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CRangeArray"))) (EListLit (EApp (EVar "cexprSexp") (EVar "lo")) (EApp (EVar "cexprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CIndex"))) (EListLit (EApp (EVar "cexprSexp") (EVar "a")) (EApp (EVar "cexprSexp") (EVar "i")))))
(DFunDef false "cexprSexp" ((PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CSlice"))) (EListLit (EApp (EVar "cexprSexp") (EVar "a")) (EApp (EVar "cexprSexp") (EVar "lo")) (EApp (EVar "cexprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CStringIndex"))) (EListLit (EApp (EVar "cexprSexp") (EVar "a")) (EApp (EVar "cexprSexp") (EVar "i")))))
(DFunDef false "cexprSexp" ((PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CStringSlice"))) (EListLit (EApp (EVar "cexprSexp") (EVar "a")) (EApp (EVar "cexprSexp") (EVar "lo")) (EApp (EVar "cexprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CListIndex"))) (EListLit (EApp (EVar "cexprSexp") (EVar "a")) (EApp (EVar "cexprSexp") (EVar "i")))))
(DFunDef false "cexprSexp" ((PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CListSlice"))) (EListLit (EApp (EVar "cexprSexp") (EVar "a")) (EApp (EVar "cexprSexp") (EVar "lo")) (EApp (EVar "cexprSexp") (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "node") (ELit (LString "CBlock"))) (EApp (EApp (EMethodRef "map") (EVar "cstmtSexp")) (EVar "stmts"))))
(DFunDef false "cexprSexp" ((PCon "CMethod" (PVar "name") (PVar "route") (PVar "implRoutes") (PVar "methRoutes"))) (EApp (EApp (EVar "node") (ELit (LString "CMethod"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "routeSexp") (EVar "route")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "routeSexp")) (EVar "implRoutes"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "routeSexp")) (EVar "methRoutes"))))))
(DFunDef false "cexprSexp" ((PCon "CDict" (PVar "name") (PVar "routes"))) (EApp (EApp (EVar "node") (ELit (LString "CDict"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "routeSexp")) (EVar "routes"))))))
(DTypeSig true "cfieldSexp" (TyFun (TyCon "CField") (TyCon "String")))
(DFunDef false "cfieldSexp" ((PCon "CField" (PVar "name") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "cf"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "cexprSexp") (EVar "e")))))
(DTypeSig true "carmSexp" (TyFun (TyCon "CArm") (TyCon "String")))
(DFunDef false "carmSexp" ((PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "arm"))) (EListLit (EApp (EVar "patSexp") (EVar "pat")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "cguardSexp")) (EVar "guards"))) (EApp (EVar "cexprSexp") (EVar "body")))))
(DTypeSig true "cguardSexp" (TyFun (TyCon "CGuard") (TyCon "String")))
(DFunDef false "cguardSexp" ((PCon "CGBool" (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CGBool"))) (EListLit (EApp (EVar "cexprSexp") (EVar "e")))))
(DFunDef false "cguardSexp" ((PCon "CGBind" (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CGBind"))) (EListLit (EApp (EVar "patSexp") (EVar "pat")) (EApp (EVar "cexprSexp") (EVar "e")))))
(DTypeSig true "ctreeSexp" (TyFun (TyCon "CTree") (TyCon "String")))
(DFunDef false "ctreeSexp" ((PCon "CTFail")) (ELit (LString "CTFail")))
(DFunDef false "ctreeSexp" ((PCon "CTLeaf" (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CTLeaf"))) (EListLit (EApp (EVar "intToString") (EVar "i")))))
(DFunDef false "ctreeSexp" ((PCon "CTGuard" (PVar "i") (PVar "fail"))) (EApp (EApp (EVar "node") (ELit (LString "CTGuard"))) (EListLit (EApp (EVar "intToString") (EVar "i")) (EApp (EVar "ctreeSexp") (EVar "fail")))))
(DFunDef false "ctreeSexp" ((PCon "CTSwitch" (PVar "branches") (PVar "dflt"))) (EApp (EApp (EVar "node") (ELit (LString "CTSwitch"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "ctbranchSexp")) (EVar "branches"))) (EApp (EVar "ctreeSexp") (EVar "dflt")))))
(DFunDef false "ctreeSexp" ((PCon "CTDrop" (PVar "tree"))) (EApp (EApp (EVar "node") (ELit (LString "CTDrop"))) (EListLit (EApp (EVar "ctreeSexp") (EVar "tree")))))
(DTypeSig true "ctbranchSexp" (TyFun (TyCon "CTBranch") (TyCon "String")))
(DFunDef false "ctbranchSexp" ((PCon "CTBranch" (PVar "head") (PVar "tree"))) (EApp (EApp (EVar "node") (ELit (LString "CTBranch"))) (EListLit (EApp (EVar "cheadSexp") (EVar "head")) (EApp (EVar "ctreeSexp") (EVar "tree")))))
(DTypeSig true "cheadSexp" (TyFun (TyCon "CHead") (TyCon "String")))
(DFunDef false "cheadSexp" ((PCon "HCon" (PVar "name") (PVar "arity"))) (EApp (EApp (EVar "node") (ELit (LString "HCon"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "intToString") (EVar "arity")))))
(DFunDef false "cheadSexp" ((PCon "HTuple" (PVar "arity"))) (EApp (EApp (EVar "node") (ELit (LString "HTuple"))) (EListLit (EApp (EVar "intToString") (EVar "arity")))))
(DFunDef false "cheadSexp" ((PCon "HCons")) (ELit (LString "HCons")))
(DFunDef false "cheadSexp" ((PCon "HNil")) (ELit (LString "HNil")))
(DFunDef false "cheadSexp" ((PCon "HUnit")) (ELit (LString "HUnit")))
(DFunDef false "cheadSexp" ((PCon "HLit" (PVar "l"))) (EApp (EApp (EVar "node") (ELit (LString "HLit"))) (EListLit (EApp (EVar "litSexp") (EVar "l")))))
(DTypeSig true "cstmtSexp" (TyFun (TyCon "CStmt") (TyCon "String")))
(DFunDef false "cstmtSexp" ((PCon "CSExpr" (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CSExpr"))) (EListLit (EApp (EVar "cexprSexp") (EVar "e")))))
(DFunDef false "cstmtSexp" ((PCon "CSLet" (PVar "isRec") (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CSLet"))) (EListLit (EApp (EVar "boolStr") (EVar "isRec")) (EApp (EVar "patSexp") (EVar "pat")) (EApp (EVar "cexprSexp") (EVar "e")))))
(DFunDef false "cstmtSexp" ((PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CSAssign"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EVar "cexprSexp") (EVar "e")))))
(DTypeSig true "cbindSexp" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "cbindSexp" ((PCon "CBind" (PVar "name") (PVar "clauses"))) (EApp (EApp (EVar "node") (ELit (LString "CBind"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "cclauseSexp")) (EVar "clauses")))))
(DTypeSig true "cclauseSexp" (TyFun (TyCon "CClause") (TyCon "String")))
(DFunDef false "cclauseSexp" ((PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CClause"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EVar "cexprSexp") (EVar "body")))))
(DTypeSig true "cimplBodySexp" (TyFun (TyCon "CImplBody") (TyCon "String")))
(DFunDef false "cimplBodySexp" ((PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "positions") (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CImplTagged"))) (EListLit (EApp (EVar "escStr") (EVar "tag")) (EApp (EVar "escStr") (EVar "key")) (EApp (EVar "escStr") (EVar "iface")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EVar "positions"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EVar "cexprSexp") (EVar "body")))))
(DFunDef false "cimplBodySexp" ((PCon "CImplDefault" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CImplDefault"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EVar "cexprSexp") (EVar "body")))))
(DTypeSig true "cimplEntrySexp" (TyFun (TyCon "CImplEntry") (TyCon "String")))
(DFunDef false "cimplEntrySexp" ((PCon "CImplEntry" (PVar "name") (PVar "score") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CImplEntry"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "intToString") (EVar "score")) (EApp (EVar "cimplBodySexp") (EVar "body")))))
(DTypeSig false "ctorArityPairSexp" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "String")))
(DFunDef false "ctorArityPairSexp" ((PTuple (PVar "name") (PVar "arity"))) (EApp (EApp (EVar "node") (ELit (LString "ca"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "intToString") (EVar "arity")))))
(DTypeSig false "ctorTypePairSexp" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "ctorTypePairSexp" ((PTuple (PVar "ctor") (PVar "ty"))) (EApp (EApp (EVar "node") (ELit (LString "ct"))) (EListLit (EApp (EVar "escStr") (EVar "ctor")) (EApp (EVar "escStr") (EVar "ty")))))
(DTypeSig true "cprogramToSexp" (TyFun (TyCon "CProgram") (TyCon "String")))
(DFunDef false "cprogramToSexp" ((PCon "CProgram" (PVar "binds") (PVar "ctorArities") (PVar "ctorToType") (PVar "impls"))) (EApp (EApp (EVar "node") (ELit (LString "CProgram"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "cbindSexp")) (EVar "binds"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "ctorArityPairSexp")) (EVar "ctorArities"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "ctorTypePairSexp")) (EVar "ctorToType"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "cimplEntrySexp")) (EVar "impls"))))))
