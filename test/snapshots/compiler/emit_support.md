# META
source_lines=200
stages=DESUGAR,MARK
# SOURCE
-- BACKEND-NEUTRAL EMIT SUPPORT — helpers shared verbatim by BOTH the LLVM
-- (`llvm_emit.mdk`) and WasmGC (`wasm_emit.mdk`) emitters.  Home for logic that is
-- genuinely backend-agnostic so the two emitters do not carry byte-identical
-- copies (previously flagged by `medaka lint`'s `rule-duplicate-body`).
--
-- What lives here is the CANONICAL definition; the semantics match the LLVM
-- emitter's historical behaviour exactly (so the primary self-compile fixpoint is
-- unperturbed), and the WasmGC emitter now shares it.

import ir.core_ir.{
  CExpr(..),
  CField(..),
  CBind(..),
  CClause(..),
  CStmt(..),
  CArm(..),
  CGuard(..),
}
import backend.trmc_analysis.{patVars, bindNames}
import support.util.{contains, lookupAssoc, startsWith, fallthroughName}

-- ── eager free-var / strictness analysis ─────────────────────────────────────
-- free CVar names evaluated EAGERLY in `body`: like freeVars, but a `CLam` body is
-- NOT descended (its references are deferred to call time).  Bound names (`b`)
-- accumulate so a let/match-bound local is not mistaken for a global.  Used by the
-- value-binding init-order topo sort in both emitters.
export eagerVars : List String -> CExpr -> List String
eagerVars _ (CLam _ _) = []
eagerVars b (CVar x _) = if contains x b then [] else [x]
eagerVars _ (CLit _) = []
eagerVars b (CApp f a) = eagerVars b f ++ eagerVars b a
eagerVars b (CLet recF pat e1 e2) =
  let b2 = patVars pat ++ b
  let fe1 = if recF then eagerVars b2 e1 else eagerVars b e1
  fe1 ++ eagerVars b2 e2
eagerVars b (CLetGroup binds body) =
  let b2 = bindNames binds ++ b
  eagerVarsBinds b2 binds ++ eagerVars b2 body
eagerVars b (CBlock stmts) = eagerVarsStmts b stmts
eagerVars b (CIf c t f) = eagerVars b c ++ eagerVars b t ++ eagerVars b f
eagerVars b (CBinPrim _ l r _) = eagerVars b l ++ eagerVars b r
eagerVars b (CUnOp _ x) = eagerVars b x
eagerVars b (CMatch scrut arms) = eagerVars b scrut ++ eagerVarsArms b arms
eagerVars b (CDecision scrut arms _) = eagerVars b scrut ++ eagerVarsArms b arms
eagerVars b (CTuple es) = eagerVarsList b es
eagerVars b (CList es) = eagerVarsList b es
eagerVars b (CRangeList lo hi _) = eagerVars b lo ++ eagerVars b hi
eagerVars b (CRecord _ fields) = eagerVarsFields b fields
eagerVars b (CFieldAccess ex _ _) = eagerVars b ex
eagerVars b (CRecordUpdate base updates) = eagerVars b base
  ++ eagerVarsFields b updates
eagerVars b (CVariantUpdate _ base updates) = eagerVars b base
  ++ eagerVarsFields b updates
eagerVars b (CArray es) = eagerVarsList b es
eagerVars b (CRangeArray lo hi _) = eagerVars b lo ++ eagerVars b hi
eagerVars b (CIndex a i) = eagerVars b a ++ eagerVars b i
eagerVars b (CStringIndex a i) = eagerVars b a ++ eagerVars b i
eagerVars b (CStringSlice a lo hi _) = eagerVars b a
eagerVars b (CListIndex a i) = eagerVars b a ++ eagerVars b i
eagerVars b (CListSlice a lo hi _) = eagerVars b a
  ++ eagerVars b lo
  ++ eagerVars b hi
eagerVars b (CSlice a lo hi _) = eagerVars b a
  ++ eagerVars b lo
  ++ eagerVars b hi
eagerVars _ _ = []

eagerVarsList : List String -> List CExpr -> List String
eagerVarsList _ [] = []
eagerVarsList b (e::rest) = eagerVars b e ++ eagerVarsList b rest

eagerVarsArms : List String -> List CArm -> List String
eagerVarsArms _ [] = []
eagerVarsArms b ((CArm pat _ body)::rest) = eagerVars (patVars pat ++ b) body
  ++ eagerVarsArms b rest

eagerVarsFields : List String -> List CField -> List String
eagerVarsFields _ [] = []
eagerVarsFields b ((CField _ ex)::rest) = eagerVars b ex
  ++ eagerVarsFields b rest

eagerVarsStmts : List String -> List CStmt -> List String
eagerVarsStmts _ [] = []
eagerVarsStmts b ((CSExpr ex)::rest) = eagerVars b ex ++ eagerVarsStmts b rest
eagerVarsStmts b ((CSLet _ pat ex)::rest) = eagerVars b ex
  ++ eagerVarsStmts (patVars pat ++ b) rest
eagerVarsStmts b ((CSAssign _ ex)::rest) = eagerVars b ex
  ++ eagerVarsStmts b rest
eagerVarsStmts b (_::rest) = eagerVarsStmts b rest

eagerVarsBinds : List String -> List CBind -> List String
eagerVarsBinds _ [] = []
eagerVarsBinds b ((CBind _ [CClause [] rhs])::rest) = eagerVars b rhs
  ++ eagerVarsBinds b rest
eagerVarsBinds b (_::rest) = eagerVarsBinds b rest

-- ── interface-method dispatch metadata (installed once per compile) ──────────
-- method → (interface, declared-full-arity), from the program's `DInterface`
-- decls.  Populated by each backend's `installMethodIface` before emitProgram; an
-- empty table (prelude-free probe entries) makes every lookup a no-op.  Shared so
-- the two emitters read the same install point.
export methodIfaceTableRef : Ref (List (String, (String, Int)))
methodIfaceTableRef = Ref []

-- the interface a method name belongs to ("" = not an interface method).
export methodIfaceOf : String -> <Mut> String
methodIfaceOf method = match lookupAssoc method methodIfaceTableRef.value
  Some (iface, _) => iface
  None => ""

-- the declared full arity of an interface method (0 = not found).
export methodArityOf : String -> <Mut> Int
methodArityOf method = match lookupAssoc method methodIfaceTableRef.value
  Some (_, arity) => arity
  None => 0

-- ── clause fall-through labelling (shared by BOTH backends) ──────────────────
-- `desugar.mdk` lowers a clause's guard chain to a nested `CIf`/`CDecision`
-- terminated by the sentinel call `__fallthrough__ ()` — "no guard arm matched,
-- try the NEXT clause of this function" (the interpreter's `VFallthrough` →
-- `fallthroughToNone` → `None`).  A backend must therefore lower that sentinel to
-- a jump to the enclosing clause chain's next-clause block.
--
-- ⚠️ A mutable "current next-clause label" Ref does NOT work.  The WasmGC emitter
-- can't use one (it builds instruction lists lazily and forces them at final
-- assembly, long after any setRef/restore), and the LLVM emitter's attempt at one
-- was a SILENT MISCOMPILE: `emitDecision` saves+NULLS the label so a body-level
-- `match`'s own non-exhaustive CTFail is a genuine abort rather than a jump to the
-- next clause — but a REFUTABLE pattern-guard (`f a | Yes x <- a = x`) desugars to
-- exactly such a body-level `CDecision`, whose wildcard arm IS the `__fallthrough__`.
-- Nulling the label turned that arm's "try the next clause" into `@mdk_oob`, so a
-- built binary aborted with `E-INDEX-OOB` on a program `medaka run` evaluated
-- correctly (2026-07-13; fixtures `test/llvm_fixtures/guard_refut_clause*.mdk`).
--
-- So the target is encoded IN THE NODE instead: rewrite every `__fallthrough__`
-- occurrence in a clause body to `__ft__<label>` BEFORE emitting it, and each
-- backend lowers the sentinel to a branch as a PURE function of the var name.
-- Timing-independent, and immune to any save/restore discipline elsewhere.
--
-- The walk descends only what a guard chain can produce (CApp / CIf / CLet /
-- CLetGroup / CBlock / CDecision arms+guards) and deliberately does NOT enter a
-- `CLam`: a closure owns its own clause scope, so a `__fallthrough__` under a
-- lambda is not this clause's — it stays BARE and each backend lowers a bare
-- sentinel to its non-exhaustive abort.
export ftPrefix : String
ftPrefix = "__ft__"

-- `Some lbl` when `x` is a labelled fall-through sentinel (`__ft__<lbl>`); `None`
-- for anything else — including a BARE `__fallthrough__`, which means "no enclosing
-- clause to fall through to" → the backend's non-exhaustive abort.
export ftLabelOf : String -> Option String
ftLabelOf x =
  if startsWith ftPrefix x then
    Some (stringSlice (stringLength ftPrefix) (stringLength x) x)
  else
    None

export labelFallthrough : CExpr -> String -> CExpr
labelFallthrough (e@(CVar x r)) label =
  if x == fallthroughName then
    CVar (ftPrefix ++ label) r
  else
    e
labelFallthrough (CApp f a) label =
  CApp (labelFallthrough f label) (labelFallthrough a label)
labelFallthrough (CIf c t f) label =
  CIf
    (labelFallthrough c label)
    (labelFallthrough t label)
    (labelFallthrough f label)
labelFallthrough (CLet rf p e1 e2) label =
  CLet rf p (labelFallthrough e1 label) (labelFallthrough e2 label)
labelFallthrough (CLetGroup binds b) label =
  CLetGroup binds (labelFallthrough b label)
labelFallthrough (CBlock stmts) label =
  CBlock (map (s => labelFallthroughStmt s label) stmts)
labelFallthrough (CDecision scrut arms tree) label = CDecision
  (labelFallthrough scrut label)
  (map (a => labelFallthroughArm a label) arms)
  tree
labelFallthrough e _ = e

labelFallthroughStmt : CStmt -> String -> CStmt
labelFallthroughStmt (CSExpr e) label = CSExpr (labelFallthrough e label)
labelFallthroughStmt (CSLet rf p e) label =
  CSLet rf p (labelFallthrough e label)
-- CSAssign (`:=`/setRef in a do-block, the Ref-mutability model): the assigned
-- expression is in tail-fallthrough position exactly like CSLet's RHS.
labelFallthroughStmt (CSAssign x e) label =
  CSAssign x (labelFallthrough e label)

labelFallthroughArm : CArm -> String -> CArm
labelFallthroughArm (CArm p gs b) label = CArm
  p
  (map (g => labelFallthroughGuard g label) gs)
  (labelFallthrough b label)

labelFallthroughGuard : CGuard -> String -> CGuard
labelFallthroughGuard (CGBool e) label = CGBool (labelFallthrough e label)
labelFallthroughGuard (CGBind p e) label = CGBind p (labelFallthrough e label)
# DESUGAR
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CStmt" true) (mem "CArm" true) (mem "CGuard" true))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "patVars" false) (mem "bindNames" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "lookupAssoc" false) (mem "startsWith" false) (mem "fallthroughName" false))))
(DTypeSig true "eagerVars" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVars" (PWild (PCon "CLam" PWild PWild)) (EListLit))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CVar" (PVar "x") PWild)) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "b")) (EListLit) (EListLit (EVar "x"))))
(DFunDef false "eagerVars" (PWild (PCon "CLit" PWild)) (EListLit))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CApp" (PVar "f") (PVar "a"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "f")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CLet" (PVar "recF") (PVar "pat") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "b2") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (DoLet false false (PVar "fe1") (EIf (EVar "recF") (EApp (EApp (EVar "eagerVars") (EVar "b2")) (EVar "e1")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "e1")))) (DoExpr (EBinOp "++" (EVar "fe1") (EApp (EApp (EVar "eagerVars") (EVar "b2")) (EVar "e2"))))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "b2") (EBinOp "++" (EApp (EVar "bindNames") (EVar "binds")) (EVar "b"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "eagerVarsBinds") (EVar "b2")) (EVar "binds")) (EApp (EApp (EVar "eagerVars") (EVar "b2")) (EVar "body"))))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "eagerVarsStmts") (EVar "b")) (EVar "stmts")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "c")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "t"))) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "f"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild)) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "l")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "r"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "x")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "scrut")) (EApp (EApp (EVar "eagerVarsArms") (EVar "b")) (EVar "arms"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "scrut")) (EApp (EApp (EVar "eagerVarsArms") (EVar "b")) (EVar "arms"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CTuple" (PVar "es"))) (EApp (EApp (EVar "eagerVarsList") (EVar "b")) (EVar "es")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CList" (PVar "es"))) (EApp (EApp (EVar "eagerVarsList") (EVar "b")) (EVar "es")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EVar "eagerVarsFields") (EVar "b")) (EVar "fields")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CFieldAccess" (PVar "ex") PWild PWild)) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "ex")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CRecordUpdate" (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "base")) (EApp (EApp (EVar "eagerVarsFields") (EVar "b")) (EVar "updates"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "base")) (EApp (EApp (EVar "eagerVarsFields") (EVar "b")) (EVar "updates"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CArray" (PVar "es"))) (EApp (EApp (EVar "eagerVarsList") (EVar "b")) (EVar "es")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "i"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "i"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "i"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" (PWild PWild) (EListLit))
(DTypeSig false "eagerVarsList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVarsList" (PWild (PList)) (EListLit))
(DFunDef false "eagerVarsList" ((PVar "b") (PCons (PVar "e") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "e")) (EApp (EApp (EVar "eagerVarsList") (EVar "b")) (EVar "rest"))))
(DTypeSig false "eagerVarsArms" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVarsArms" (PWild (PList)) (EListLit))
(DFunDef false "eagerVarsArms" ((PVar "b") (PCons (PCon "CArm" (PVar "pat") PWild (PVar "body")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (EVar "body")) (EApp (EApp (EVar "eagerVarsArms") (EVar "b")) (EVar "rest"))))
(DTypeSig false "eagerVarsFields" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVarsFields" (PWild (PList)) (EListLit))
(DFunDef false "eagerVarsFields" ((PVar "b") (PCons (PCon "CField" PWild (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "eagerVarsFields") (EVar "b")) (EVar "rest"))))
(DTypeSig false "eagerVarsStmts" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVarsStmts" (PWild (PList)) (EListLit))
(DFunDef false "eagerVarsStmts" ((PVar "b") (PCons (PCon "CSExpr" (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "eagerVarsStmts") (EVar "b")) (EVar "rest"))))
(DFunDef false "eagerVarsStmts" ((PVar "b") (PCons (PCon "CSLet" PWild (PVar "pat") (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "eagerVarsStmts") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (EVar "rest"))))
(DFunDef false "eagerVarsStmts" ((PVar "b") (PCons (PCon "CSAssign" PWild (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "eagerVarsStmts") (EVar "b")) (EVar "rest"))))
(DFunDef false "eagerVarsStmts" ((PVar "b") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "eagerVarsStmts") (EVar "b")) (EVar "rest")))
(DTypeSig false "eagerVarsBinds" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVarsBinds" (PWild (PList)) (EListLit))
(DFunDef false "eagerVarsBinds" ((PVar "b") (PCons (PCon "CBind" PWild (PList (PCon "CClause" (PList) (PVar "rhs")))) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "rhs")) (EApp (EApp (EVar "eagerVarsBinds") (EVar "b")) (EVar "rest"))))
(DFunDef false "eagerVarsBinds" ((PVar "b") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "eagerVarsBinds") (EVar "b")) (EVar "rest")))
(DTypeSig true "methodIfaceTableRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "methodIfaceTableRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "methodIfaceOf" (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "String"))))
(DFunDef false "methodIfaceOf" ((PVar "method")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "method")) (EFieldAccess (EVar "methodIfaceTableRef") "value")) (arm (PCon "Some" (PTuple (PVar "iface") PWild)) () (EVar "iface")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig true "methodArityOf" (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))))
(DFunDef false "methodArityOf" ((PVar "method")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "method")) (EFieldAccess (EVar "methodIfaceTableRef") "value")) (arm (PCon "Some" (PTuple PWild (PVar "arity"))) () (EVar "arity")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig true "ftPrefix" (TyCon "String"))
(DFunDef false "ftPrefix" () (ELit (LString "__ft__")))
(DTypeSig true "ftLabelOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "ftLabelOf" ((PVar "x")) (EIf (EApp (EApp (EVar "startsWith") (EVar "ftPrefix")) (EVar "x")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "ftPrefix"))) (EApp (EVar "stringLength") (EVar "x"))) (EVar "x"))) (EVar "None")))
(DTypeSig true "labelFallthrough" (TyFun (TyCon "CExpr") (TyFun (TyCon "String") (TyCon "CExpr"))))
(DFunDef false "labelFallthrough" ((PAs "e" (PCon "CVar" (PVar "x") (PVar "r"))) (PVar "label")) (EIf (EBinOp "==" (EVar "x") (EVar "fallthroughName")) (EApp (EApp (EVar "CVar") (EBinOp "++" (EVar "ftPrefix") (EVar "label"))) (EVar "r")) (EVar "e")))
(DFunDef false "labelFallthrough" ((PCon "CApp" (PVar "f") (PVar "a")) (PVar "label")) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "labelFallthrough") (EVar "f")) (EVar "label"))) (EApp (EApp (EVar "labelFallthrough") (EVar "a")) (EVar "label"))))
(DFunDef false "labelFallthrough" ((PCon "CIf" (PVar "c") (PVar "t") (PVar "f")) (PVar "label")) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "labelFallthrough") (EVar "c")) (EVar "label"))) (EApp (EApp (EVar "labelFallthrough") (EVar "t")) (EVar "label"))) (EApp (EApp (EVar "labelFallthrough") (EVar "f")) (EVar "label"))))
(DFunDef false "labelFallthrough" ((PCon "CLet" (PVar "rf") (PVar "p") (PVar "e1") (PVar "e2")) (PVar "label")) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "rf")) (EVar "p")) (EApp (EApp (EVar "labelFallthrough") (EVar "e1")) (EVar "label"))) (EApp (EApp (EVar "labelFallthrough") (EVar "e2")) (EVar "label"))))
(DFunDef false "labelFallthrough" ((PCon "CLetGroup" (PVar "binds") (PVar "b")) (PVar "label")) (EApp (EApp (EVar "CLetGroup") (EVar "binds")) (EApp (EApp (EVar "labelFallthrough") (EVar "b")) (EVar "label"))))
(DFunDef false "labelFallthrough" ((PCon "CBlock" (PVar "stmts")) (PVar "label")) (EApp (EVar "CBlock") (EApp (EApp (EVar "map") (ELam ((PVar "s")) (EApp (EApp (EVar "labelFallthroughStmt") (EVar "s")) (EVar "label")))) (EVar "stmts"))))
(DFunDef false "labelFallthrough" ((PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree")) (PVar "label")) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "labelFallthrough") (EVar "scrut")) (EVar "label"))) (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EApp (EApp (EVar "labelFallthroughArm") (EVar "a")) (EVar "label")))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "labelFallthrough" ((PVar "e") PWild) (EVar "e"))
(DTypeSig false "labelFallthroughStmt" (TyFun (TyCon "CStmt") (TyFun (TyCon "String") (TyCon "CStmt"))))
(DFunDef false "labelFallthroughStmt" ((PCon "CSExpr" (PVar "e")) (PVar "label")) (EApp (EVar "CSExpr") (EApp (EApp (EVar "labelFallthrough") (EVar "e")) (EVar "label"))))
(DFunDef false "labelFallthroughStmt" ((PCon "CSLet" (PVar "rf") (PVar "p") (PVar "e")) (PVar "label")) (EApp (EApp (EApp (EVar "CSLet") (EVar "rf")) (EVar "p")) (EApp (EApp (EVar "labelFallthrough") (EVar "e")) (EVar "label"))))
(DFunDef false "labelFallthroughStmt" ((PCon "CSAssign" (PVar "x") (PVar "e")) (PVar "label")) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "labelFallthrough") (EVar "e")) (EVar "label"))))
(DTypeSig false "labelFallthroughArm" (TyFun (TyCon "CArm") (TyFun (TyCon "String") (TyCon "CArm"))))
(DFunDef false "labelFallthroughArm" ((PCon "CArm" (PVar "p") (PVar "gs") (PVar "b")) (PVar "label")) (EApp (EApp (EApp (EVar "CArm") (EVar "p")) (EApp (EApp (EVar "map") (ELam ((PVar "g")) (EApp (EApp (EVar "labelFallthroughGuard") (EVar "g")) (EVar "label")))) (EVar "gs"))) (EApp (EApp (EVar "labelFallthrough") (EVar "b")) (EVar "label"))))
(DTypeSig false "labelFallthroughGuard" (TyFun (TyCon "CGuard") (TyFun (TyCon "String") (TyCon "CGuard"))))
(DFunDef false "labelFallthroughGuard" ((PCon "CGBool" (PVar "e")) (PVar "label")) (EApp (EVar "CGBool") (EApp (EApp (EVar "labelFallthrough") (EVar "e")) (EVar "label"))))
(DFunDef false "labelFallthroughGuard" ((PCon "CGBind" (PVar "p") (PVar "e")) (PVar "label")) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EApp (EVar "labelFallthrough") (EVar "e")) (EVar "label"))))
# MARK
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CStmt" true) (mem "CArm" true) (mem "CGuard" true))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "patVars" false) (mem "bindNames" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "lookupAssoc" false) (mem "startsWith" false) (mem "fallthroughName" false))))
(DTypeSig true "eagerVars" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVars" (PWild (PCon "CLam" PWild PWild)) (EListLit))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CVar" (PVar "x") PWild)) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "b")) (EListLit) (EListLit (EVar "x"))))
(DFunDef false "eagerVars" (PWild (PCon "CLit" PWild)) (EListLit))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CApp" (PVar "f") (PVar "a"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "f")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CLet" (PVar "recF") (PVar "pat") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "b2") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (DoLet false false (PVar "fe1") (EIf (EVar "recF") (EApp (EApp (EVar "eagerVars") (EVar "b2")) (EVar "e1")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "e1")))) (DoExpr (EBinOp "++" (EVar "fe1") (EApp (EApp (EVar "eagerVars") (EVar "b2")) (EVar "e2"))))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "b2") (EBinOp "++" (EApp (EVar "bindNames") (EVar "binds")) (EVar "b"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "eagerVarsBinds") (EVar "b2")) (EVar "binds")) (EApp (EApp (EVar "eagerVars") (EVar "b2")) (EVar "body"))))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "eagerVarsStmts") (EVar "b")) (EVar "stmts")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "c")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "t"))) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "f"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild)) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "l")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "r"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "x")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "scrut")) (EApp (EApp (EVar "eagerVarsArms") (EVar "b")) (EVar "arms"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "scrut")) (EApp (EApp (EVar "eagerVarsArms") (EVar "b")) (EVar "arms"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CTuple" (PVar "es"))) (EApp (EApp (EVar "eagerVarsList") (EVar "b")) (EVar "es")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CList" (PVar "es"))) (EApp (EApp (EVar "eagerVarsList") (EVar "b")) (EVar "es")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EVar "eagerVarsFields") (EVar "b")) (EVar "fields")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CFieldAccess" (PVar "ex") PWild PWild)) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "ex")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CRecordUpdate" (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "base")) (EApp (EApp (EVar "eagerVarsFields") (EVar "b")) (EVar "updates"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "base")) (EApp (EApp (EVar "eagerVarsFields") (EVar "b")) (EVar "updates"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CArray" (PVar "es"))) (EApp (EApp (EVar "eagerVarsList") (EVar "b")) (EVar "es")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "i"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "i"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "i"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" (PWild PWild) (EListLit))
(DTypeSig false "eagerVarsList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVarsList" (PWild (PList)) (EListLit))
(DFunDef false "eagerVarsList" ((PVar "b") (PCons (PVar "e") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "e")) (EApp (EApp (EVar "eagerVarsList") (EVar "b")) (EVar "rest"))))
(DTypeSig false "eagerVarsArms" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVarsArms" (PWild (PList)) (EListLit))
(DFunDef false "eagerVarsArms" ((PVar "b") (PCons (PCon "CArm" (PVar "pat") PWild (PVar "body")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (EVar "body")) (EApp (EApp (EVar "eagerVarsArms") (EVar "b")) (EVar "rest"))))
(DTypeSig false "eagerVarsFields" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVarsFields" (PWild (PList)) (EListLit))
(DFunDef false "eagerVarsFields" ((PVar "b") (PCons (PCon "CField" PWild (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "eagerVarsFields") (EVar "b")) (EVar "rest"))))
(DTypeSig false "eagerVarsStmts" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVarsStmts" (PWild (PList)) (EListLit))
(DFunDef false "eagerVarsStmts" ((PVar "b") (PCons (PCon "CSExpr" (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "eagerVarsStmts") (EVar "b")) (EVar "rest"))))
(DFunDef false "eagerVarsStmts" ((PVar "b") (PCons (PCon "CSLet" PWild (PVar "pat") (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "eagerVarsStmts") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (EVar "rest"))))
(DFunDef false "eagerVarsStmts" ((PVar "b") (PCons (PCon "CSAssign" PWild (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "eagerVarsStmts") (EVar "b")) (EVar "rest"))))
(DFunDef false "eagerVarsStmts" ((PVar "b") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "eagerVarsStmts") (EVar "b")) (EVar "rest")))
(DTypeSig false "eagerVarsBinds" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVarsBinds" (PWild (PList)) (EListLit))
(DFunDef false "eagerVarsBinds" ((PVar "b") (PCons (PCon "CBind" PWild (PList (PCon "CClause" (PList) (PVar "rhs")))) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "rhs")) (EApp (EApp (EVar "eagerVarsBinds") (EVar "b")) (EVar "rest"))))
(DFunDef false "eagerVarsBinds" ((PVar "b") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "eagerVarsBinds") (EVar "b")) (EVar "rest")))
(DTypeSig true "methodIfaceTableRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "methodIfaceTableRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "methodIfaceOf" (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "String"))))
(DFunDef false "methodIfaceOf" ((PVar "method")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "method")) (EFieldAccess (EVar "methodIfaceTableRef") "value")) (arm (PCon "Some" (PTuple (PVar "iface") PWild)) () (EVar "iface")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig true "methodArityOf" (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))))
(DFunDef false "methodArityOf" ((PVar "method")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "method")) (EFieldAccess (EVar "methodIfaceTableRef") "value")) (arm (PCon "Some" (PTuple PWild (PVar "arity"))) () (EVar "arity")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig true "ftPrefix" (TyCon "String"))
(DFunDef false "ftPrefix" () (ELit (LString "__ft__")))
(DTypeSig true "ftLabelOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "ftLabelOf" ((PVar "x")) (EIf (EApp (EApp (EVar "startsWith") (EVar "ftPrefix")) (EVar "x")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "ftPrefix"))) (EApp (EVar "stringLength") (EVar "x"))) (EVar "x"))) (EVar "None")))
(DTypeSig true "labelFallthrough" (TyFun (TyCon "CExpr") (TyFun (TyCon "String") (TyCon "CExpr"))))
(DFunDef false "labelFallthrough" ((PAs "e" (PCon "CVar" (PVar "x") (PVar "r"))) (PVar "label")) (EIf (EBinOp "==" (EVar "x") (EVar "fallthroughName")) (EApp (EApp (EVar "CVar") (EBinOp "++" (EVar "ftPrefix") (EVar "label"))) (EVar "r")) (EVar "e")))
(DFunDef false "labelFallthrough" ((PCon "CApp" (PVar "f") (PVar "a")) (PVar "label")) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "labelFallthrough") (EVar "f")) (EVar "label"))) (EApp (EApp (EVar "labelFallthrough") (EVar "a")) (EVar "label"))))
(DFunDef false "labelFallthrough" ((PCon "CIf" (PVar "c") (PVar "t") (PVar "f")) (PVar "label")) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "labelFallthrough") (EVar "c")) (EVar "label"))) (EApp (EApp (EVar "labelFallthrough") (EVar "t")) (EVar "label"))) (EApp (EApp (EVar "labelFallthrough") (EVar "f")) (EVar "label"))))
(DFunDef false "labelFallthrough" ((PCon "CLet" (PVar "rf") (PVar "p") (PVar "e1") (PVar "e2")) (PVar "label")) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "rf")) (EVar "p")) (EApp (EApp (EVar "labelFallthrough") (EVar "e1")) (EVar "label"))) (EApp (EApp (EVar "labelFallthrough") (EVar "e2")) (EVar "label"))))
(DFunDef false "labelFallthrough" ((PCon "CLetGroup" (PVar "binds") (PVar "b")) (PVar "label")) (EApp (EApp (EVar "CLetGroup") (EVar "binds")) (EApp (EApp (EVar "labelFallthrough") (EVar "b")) (EVar "label"))))
(DFunDef false "labelFallthrough" ((PCon "CBlock" (PVar "stmts")) (PVar "label")) (EApp (EVar "CBlock") (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (EApp (EApp (EVar "labelFallthroughStmt") (EVar "s")) (EVar "label")))) (EVar "stmts"))))
(DFunDef false "labelFallthrough" ((PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree")) (PVar "label")) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "labelFallthrough") (EVar "scrut")) (EVar "label"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EApp (EApp (EVar "labelFallthroughArm") (EVar "a")) (EVar "label")))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "labelFallthrough" ((PVar "e") PWild) (EVar "e"))
(DTypeSig false "labelFallthroughStmt" (TyFun (TyCon "CStmt") (TyFun (TyCon "String") (TyCon "CStmt"))))
(DFunDef false "labelFallthroughStmt" ((PCon "CSExpr" (PVar "e")) (PVar "label")) (EApp (EVar "CSExpr") (EApp (EApp (EVar "labelFallthrough") (EVar "e")) (EVar "label"))))
(DFunDef false "labelFallthroughStmt" ((PCon "CSLet" (PVar "rf") (PVar "p") (PVar "e")) (PVar "label")) (EApp (EApp (EApp (EVar "CSLet") (EVar "rf")) (EVar "p")) (EApp (EApp (EVar "labelFallthrough") (EVar "e")) (EVar "label"))))
(DFunDef false "labelFallthroughStmt" ((PCon "CSAssign" (PVar "x") (PVar "e")) (PVar "label")) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "labelFallthrough") (EVar "e")) (EVar "label"))))
(DTypeSig false "labelFallthroughArm" (TyFun (TyCon "CArm") (TyFun (TyCon "String") (TyCon "CArm"))))
(DFunDef false "labelFallthroughArm" ((PCon "CArm" (PVar "p") (PVar "gs") (PVar "b")) (PVar "label")) (EApp (EApp (EApp (EVar "CArm") (EVar "p")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "g")) (EApp (EApp (EVar "labelFallthroughGuard") (EVar "g")) (EVar "label")))) (EVar "gs"))) (EApp (EApp (EVar "labelFallthrough") (EVar "b")) (EVar "label"))))
(DTypeSig false "labelFallthroughGuard" (TyFun (TyCon "CGuard") (TyFun (TyCon "String") (TyCon "CGuard"))))
(DFunDef false "labelFallthroughGuard" ((PCon "CGBool" (PVar "e")) (PVar "label")) (EApp (EVar "CGBool") (EApp (EApp (EVar "labelFallthrough") (EVar "e")) (EVar "label"))))
(DFunDef false "labelFallthroughGuard" ((PCon "CGBind" (PVar "p") (PVar "e")) (PVar "label")) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EApp (EVar "labelFallthrough") (EVar "e")) (EVar "label"))))
