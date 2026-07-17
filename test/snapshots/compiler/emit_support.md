# META
source_lines=364
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
import frontend.ast.{Lit(..), Pat}
import backend.trmc_analysis.{patVars, bindNames, bindName}
import support.util.{
  contains,
  lookupAssoc,
  startsWith,
  fallthroughName,
  dedup,
  filterList,
}
import support.ordmap.{
  OrdMap,
  omEmpty,
  omInsert,
  omLookup,
  omHasKey,
  omFromNames,
}
import support.scc.{tarjanSCCs}

-- ── eager free-var / strictness analysis ─────────────────────────────────────
-- names referenced EAGERLY in `body`: like freeVars, but a `CLam` body is NOT
-- descended (its references are deferred to call time).  Bound names (`b`)
-- accumulate so a let/match-bound local is not mistaken for a global.  Yields the
-- callee of an eager call regardless of head form — a `CVar` (unconstrained
-- function or a value global) OR a `CDict name …` (a saturated call to a
-- constrained top-level function: `+`/`<=`/… thread the callee's dicts through a
-- `CDict` head).  A `CMethod` head is interface DISPATCH — deliberately NOT
-- followed (see `eagerReachMap`; resolving it to impl bodies is #553/#561).  Used
-- by the value-init-order topo sort (via `eagerReachMap`) in both emitters.
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
eagerVars b (CRecordUpdate _ base updates) = eagerVars b base
  ++ eagerVarsFields b updates
eagerVars b (CVariantUpdate _ base updates) = eagerVars b base
  ++ eagerVarsFields b updates
eagerVars b (CArray es) = eagerVarsList b es
eagerVars b (CRangeArray lo hi _) = eagerVars b lo ++ eagerVars b hi
eagerVars b (CIndex a i) = eagerVars b a ++ eagerVars b i
eagerVars b (CStringIndex a i) = eagerVars b a ++ eagerVars b i
eagerVars b (CStringSlice a lo hi _) = eagerVars b a
  ++ eagerVars b lo
  ++ eagerVars b hi
eagerVars b (CListIndex a i) = eagerVars b a ++ eagerVars b i
eagerVars b (CListSlice a lo hi _) = eagerVars b a
  ++ eagerVars b lo
  ++ eagerVars b hi
eagerVars b (CSlice a lo hi _) = eagerVars b a
  ++ eagerVars b lo
  ++ eagerVars b hi
-- a `CDict` head is a saturated call to the named top-level function — an eager
-- callee edge (the routes it carries hold no CExpr, so nothing to descend).
eagerVars b (CDict name _) = if contains name b then [] else [name]
eagerVars _ _ = []

eagerVarsList : List String -> List CExpr -> List String
eagerVarsList _ [] = []
eagerVarsList b (e::rest) = eagerVars b e ++ eagerVarsList b rest

eagerVarsArms : List String -> List CArm -> List String
eagerVarsArms _ [] = []
eagerVarsArms b ((CArm pat gs body)::rest) = eagerVarsGuarded (patVars pat ++ b) gs body
  ++ eagerVarsArms b rest

-- an arm's guard chain + body.  A guard is EAGER — it runs when the arm is
-- tested, so a global it reads is a real init-order edge (dropping the whole
-- guard list is what let `cell = match 3 { m if m < lim => … }` be emitted
-- before `lim` and silently take the wrong arm).  A `Pat <- e` guard binds to
-- its RIGHT: its pattern vars scope over the later guards and the body, exactly
-- as the arm's own pattern does, so thread them rather than scanning flat.
eagerVarsGuarded : List String -> List CGuard -> CExpr -> List String
eagerVarsGuarded b [] body = eagerVars b body
eagerVarsGuarded b ((CGBool c)::rest) body = eagerVars b c
  ++ eagerVarsGuarded b rest body
eagerVarsGuarded b ((CGBind pat e)::rest) body = eagerVars b e
  ++ eagerVarsGuarded (patVars pat ++ b) rest body

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

-- ── eager-reachability closure (Stage B of #553) ─────────────────────────────
-- The init-order topo sort needs, for each value global, the OTHER value globals
-- it reads EAGERLY (at init time).  `eagerVars` alone gives only the ones a
-- binding names DIRECTLY: `a = f ()` yields the callee `f`, never the globals
-- `f`'s body reads.  So a value read HIDDEN behind a call is invisible to the
-- sort, which emits `a` before its dependency and captures a still-zero cell —
-- native prints a silent wrong value, wasm traps at instantiate (#553).
--
-- `eagerReachMap` closes that hole by following the eager call graph transitively.
-- A call's callee is named directly in the IR — `CVar` for an unconstrained
-- function, `CDict name …` for a saturated call to a CONSTRAINED top-level
-- function (any use of `+`/`<=`/… routes its dicts through a `CDict` head).  Both
-- are captured by `eagerVars` and followed here.  Only lambda bodies are NOT
-- descended, so a reference reachable ONLY through a closure — the parser
-- combinator ladder's mutual `do`-block refs — is correctly NOT an init-order edge
-- and forges no false cycle.  Interface-method DISPATCH (`CMethod`) is NOT resolved
-- to its impl bodies here: that residual (acceptance repro #4, `mk True`) and the
-- genuine value cycle (repro #5, `x = x + 1`) are the bounded deviation #561 drains.
--
-- Cost: build a callee adjacency (one pass), CONDENSE strongly-connected components
-- with `tarjanSCCs` (mutual recursion ⇒ one node, so the least fixpoint is total
-- WITHOUT a visited-list — which is also what makes it byte-deterministic for C3b),
-- then fold the SCC DAG once, in the reverse-topological order Tarjan emits (callees
-- before callers).  Each reach set is restricted to value-global names, so it is
-- bounded by the value-global count, never the far larger function count.

-- names a binding references EAGERLY across ALL its clauses (params bound so a
-- parameter never masquerades as a global; lambda bodies not descended), INCLUDING
-- the direct callee of every eager call (`CVar`/`CDict` head — see `eagerVars`).
bindEagerCallees : CBind -> List String
bindEagerCallees (CBind _ clauses) = dedup (clauseEagerVars clauses)

clauseEagerVars : List CClause -> List String
clauseEagerVars [] = []
clauseEagerVars ((CClause params body)::rest) = eagerVars (paramBound params) body
  ++ clauseEagerVars rest

paramBound : List Pat -> List String
paramBound [] = []
paramBound (p::rest) = patVars p ++ paramBound rest

-- names of the nullary single-clause bindings — the value globals whose init
-- order the sort decides; reach sets are restricted to these.
valGlobalNames : List CBind -> List String
valGlobalNames [] = []
valGlobalNames ((CBind name [CClause [] _])::rest) = name :: valGlobalNames rest
valGlobalNames (_::rest) = valGlobalNames rest

-- eager call-graph adjacency, restricted to real top-level bind names so an edge
-- to a constructor / not-emitted name never becomes a graph node.  Membership is
-- tested against an OrdMap SET (`nameSet`), never a `List` — a `List` here would be
-- O(V) per edge = O(V*E), the exact quadratic #553 warns against.
eagerCalleesMap : OrdMap Unit -> List CBind -> OrdMap (List String)
eagerCalleesMap _ [] = omEmpty
eagerCalleesMap nameSet (b::rest) = omInsert
  (bindName b)
  (filterList (n => omHasKey n nameSet) (bindEagerCallees b))
  (eagerCalleesMap nameSet rest)

-- reach(name) = the value globals a binding eagerly reaches through calls,
-- transitively.  Least fixpoint over the eager call graph, condensed by
-- `tarjanSCCs` and folded in the order Tarjan emits (callees before callers), so
-- every cross-SCC callee's reach is already computed when a caller SCC is folded.
-- Members of one SCC share the SCC's reach set — the condensation, not a
-- visited-list, is what makes the fixpoint well-defined (and deterministic).
export eagerReachMap : List CBind -> OrdMap (List String)
eagerReachMap binds =
  let allNames = bindNames binds
  let nameSet = omFromNames allNames omEmpty
  let valSet = omFromNames (valGlobalNames binds) omEmpty
  let adj = eagerCalleesMap nameSet binds
  foldReachSCCs valSet adj (tarjanSCCs allNames adj) omEmpty

-- reach(scc) = (its members' direct value-global callees) ∪ (⋃ reach(callee)).
-- Successor SCCs are already folded and their reach is ⊆ valSet by induction, so
-- the union stays ⊆ valSet — bounding every set to the value-global count.
foldReachSCCs : OrdMap Unit -> OrdMap (List String) -> List (List String) -> OrdMap (List String) -> OrdMap (List String)
foldReachSCCs _ _ [] acc = acc
foldReachSCCs valSet adj (scc::rest) acc =
  let direct = dedup (unionLookup scc adj)
  let reached = dedup (filterList (n => omHasKey n valSet) direct ++ unionLookup direct acc)
  foldReachSCCs valSet adj rest (insertReach scc reached acc)

-- concat (default []) of the OrdMap lookups over a list of keys.
unionLookup : List String -> OrdMap (List String) -> List String
unionLookup [] _ = []
unionLookup (n::rest) m = fromOption [] (omLookup n m) ++ unionLookup rest m

insertReach : List String -> List String -> OrdMap (List String) -> OrdMap (List String)
insertReach [] _ acc = acc
insertReach (n::rest) reached acc =
  insertReach rest reached (omInsert n reached acc)

-- the value globals a value binding depends on EAGERLY, transitively through
-- calls — the COMPLETE init-order edge set the topo sort consumes on both
-- backends (replaces the old direct-only `eagerVars [] body`).
export bindEagerReach : OrdMap (List String) -> CBind -> List String
bindEagerReach rm (CBind name [CClause [] _]) = fromOption [] (omLookup name rm)
bindEagerReach _ _ = []

-- ── interface-method dispatch metadata (installed once per compile) ──────────
-- method → (interface, declared-full-arity), from the program's `DInterface`
-- decls.  Populated by each backend's `installMethodIface` before emitProgram; an
-- empty table (prelude-free probe entries) makes every lookup a no-op.  Shared so
-- the two emitters read the same install point.
export methodIfaceTableRef : Ref (List (String, (String, Int)))
methodIfaceTableRef = Ref []

-- the interface a method name belongs to ("" = not an interface method).
export methodIfaceOf : String -> String
methodIfaceOf method = match lookupAssoc method methodIfaceTableRef.value
  Some (iface, _) => iface
  None => ""

-- the declared full arity of an interface method (0 = not found).
export methodArityOf : String -> Int
methodArityOf method = match lookupAssoc method methodIfaceTableRef.value
  Some (_, arity) => arity
  None => 0

-- ── dict-witness parameter names (shared by BOTH backends) ───────────────────
-- `$dict_<fn>_<slot>` — a dict witness param that dict_pass/elaborateModules PREPENDS
-- to a `=>`-constrained fn's source params.  Both backends must recognize one, for the
-- same reason: a synthesized dict param occupies an IR param slot but has NO entry in
-- the DECLARED signature, so any walk that lines declared types up against lowered
-- params must skip it WITHOUT consuming a declared type — otherwise every declared type
-- describes the param one slot to its LEFT.  llvm_emit's inferParamTysSeedD does this;
-- wasm_emit's numPolyPatsAt/floatPatsAt did NOT, which is what made an explicit
-- `Num a =>` signature *disable* the very runtime dispatch it should have guaranteed
-- (2026-07-14; fixture `test/wasm/fixtures/polynum_sq_sig_float.mdk`).
export isDictParamName : String -> Bool
isDictParamName x = stringLength x >= 5 && stringSlice 0 5 x == "$dict"

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

-- ── range patterns (G6, #379) ────────────────────────────────────────────────
-- the Int codepoint of a `PRng` bound literal (Int directly, Char as its codepoint);
-- other literal kinds can't form a range pattern (parser-rejected).  Backend-neutral:
-- both emitters compare a range bound as a plain Int (LLVM against its `n*2+1` tagged
-- word, WasmGC against an untagged i31), and only the COMPARISON differs — so the bound
-- decoding is shared and the emit is not.
export rngBound : Lit -> Int
rngBound (LInt n) = n
rngBound (LChar c) = charCode (arrayGetUnsafe 0 (stringToChars c))
rngBound _ = 0
# DESUGAR
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CStmt" true) (mem "CArm" true) (mem "CGuard" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" false))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "patVars" false) (mem "bindNames" false) (mem "bindName" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "lookupAssoc" false) (mem "startsWith" false) (mem "fallthroughName" false) (mem "dedup" false) (mem "filterList" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
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
(DFunDef false "eagerVars" ((PVar "b") (PCon "CRecordUpdate" PWild (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "base")) (EApp (EApp (EVar "eagerVarsFields") (EVar "b")) (EVar "updates"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "base")) (EApp (EApp (EVar "eagerVarsFields") (EVar "b")) (EVar "updates"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CArray" (PVar "es"))) (EApp (EApp (EVar "eagerVarsList") (EVar "b")) (EVar "es")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "i"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "i"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "i"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CDict" (PVar "name") PWild)) (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EVar "b")) (EListLit) (EListLit (EVar "name"))))
(DFunDef false "eagerVars" (PWild PWild) (EListLit))
(DTypeSig false "eagerVarsList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVarsList" (PWild (PList)) (EListLit))
(DFunDef false "eagerVarsList" ((PVar "b") (PCons (PVar "e") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "e")) (EApp (EApp (EVar "eagerVarsList") (EVar "b")) (EVar "rest"))))
(DTypeSig false "eagerVarsArms" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVarsArms" (PWild (PList)) (EListLit))
(DFunDef false "eagerVarsArms" ((PVar "b") (PCons (PCon "CArm" (PVar "pat") (PVar "gs") (PVar "body")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EVar "eagerVarsGuarded") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (EVar "gs")) (EVar "body")) (EApp (EApp (EVar "eagerVarsArms") (EVar "b")) (EVar "rest"))))
(DTypeSig false "eagerVarsGuarded" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "eagerVarsGuarded" ((PVar "b") (PList) (PVar "body")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "body")))
(DFunDef false "eagerVarsGuarded" ((PVar "b") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest")) (PVar "body")) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "c")) (EApp (EApp (EApp (EVar "eagerVarsGuarded") (EVar "b")) (EVar "rest")) (EVar "body"))))
(DFunDef false "eagerVarsGuarded" ((PVar "b") (PCons (PCon "CGBind" (PVar "pat") (PVar "e")) (PVar "rest")) (PVar "body")) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "e")) (EApp (EApp (EApp (EVar "eagerVarsGuarded") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (EVar "rest")) (EVar "body"))))
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
(DTypeSig false "bindEagerCallees" (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "bindEagerCallees" ((PCon "CBind" PWild (PVar "clauses"))) (EApp (EVar "dedup") (EApp (EVar "clauseEagerVars") (EVar "clauses"))))
(DTypeSig false "clauseEagerVars" (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "clauseEagerVars" ((PList)) (EListLit))
(DFunDef false "clauseEagerVars" ((PCons (PCon "CClause" (PVar "params") (PVar "body")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EApp (EVar "paramBound") (EVar "params"))) (EVar "body")) (EApp (EVar "clauseEagerVars") (EVar "rest"))))
(DTypeSig false "paramBound" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "paramBound" ((PList)) (EListLit))
(DFunDef false "paramBound" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "++" (EApp (EVar "patVars") (EVar "p")) (EApp (EVar "paramBound") (EVar "rest"))))
(DTypeSig false "valGlobalNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valGlobalNames" ((PList)) (EListLit))
(DFunDef false "valGlobalNames" ((PCons (PCon "CBind" (PVar "name") (PList (PCon "CClause" (PList) PWild))) (PVar "rest"))) (EBinOp "::" (EVar "name") (EApp (EVar "valGlobalNames") (EVar "rest"))))
(DFunDef false "valGlobalNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "valGlobalNames") (EVar "rest")))
(DTypeSig false "eagerCalleesMap" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "eagerCalleesMap" (PWild (PList)) (EVar "omEmpty"))
(DFunDef false "eagerCalleesMap" ((PVar "nameSet") (PCons (PVar "b") (PVar "rest"))) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "bindName") (EVar "b"))) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "nameSet")))) (EApp (EVar "bindEagerCallees") (EVar "b")))) (EApp (EApp (EVar "eagerCalleesMap") (EVar "nameSet")) (EVar "rest"))))
(DTypeSig true "eagerReachMap" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerReachMap" ((PVar "binds")) (EBlock (DoLet false false (PVar "allNames") (EApp (EVar "bindNames") (EVar "binds"))) (DoLet false false (PVar "nameSet") (EApp (EApp (EVar "omFromNames") (EVar "allNames")) (EVar "omEmpty"))) (DoLet false false (PVar "valSet") (EApp (EApp (EVar "omFromNames") (EApp (EVar "valGlobalNames") (EVar "binds"))) (EVar "omEmpty"))) (DoLet false false (PVar "adj") (EApp (EApp (EVar "eagerCalleesMap") (EVar "nameSet")) (EVar "binds"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foldReachSCCs") (EVar "valSet")) (EVar "adj")) (EApp (EApp (EVar "tarjanSCCs") (EVar "allNames")) (EVar "adj"))) (EVar "omEmpty")))))
(DTypeSig false "foldReachSCCs" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "foldReachSCCs" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "foldReachSCCs" ((PVar "valSet") (PVar "adj") (PCons (PVar "scc") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "direct") (EApp (EVar "dedup") (EApp (EApp (EVar "unionLookup") (EVar "scc")) (EVar "adj")))) (DoLet false false (PVar "reached") (EApp (EVar "dedup") (EBinOp "++" (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "valSet")))) (EVar "direct")) (EApp (EApp (EVar "unionLookup") (EVar "direct")) (EVar "acc"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foldReachSCCs") (EVar "valSet")) (EVar "adj")) (EVar "rest")) (EApp (EApp (EApp (EVar "insertReach") (EVar "scc")) (EVar "reached")) (EVar "acc"))))))
(DTypeSig false "unionLookup" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "unionLookup" ((PList) PWild) (EListLit))
(DFunDef false "unionLookup" ((PCons (PVar "n") (PVar "rest")) (PVar "m")) (EBinOp "++" (EApp (EApp (EVar "fromOption") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "m"))) (EApp (EApp (EVar "unionLookup") (EVar "rest")) (EVar "m"))))
(DTypeSig false "insertReach" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "insertReach" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "insertReach" ((PCons (PVar "n") (PVar "rest")) (PVar "reached") (PVar "acc")) (EApp (EApp (EApp (EVar "insertReach") (EVar "rest")) (EVar "reached")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "reached")) (EVar "acc"))))
(DTypeSig true "bindEagerReach" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "bindEagerReach" ((PVar "rm") (PCon "CBind" (PVar "name") (PList (PCon "CClause" (PList) PWild)))) (EApp (EApp (EVar "fromOption") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "rm"))))
(DFunDef false "bindEagerReach" (PWild PWild) (EListLit))
(DTypeSig true "methodIfaceTableRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "methodIfaceTableRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "methodIfaceOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "methodIfaceOf" ((PVar "method")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "method")) (EFieldAccess (EVar "methodIfaceTableRef") "value")) (arm (PCon "Some" (PTuple (PVar "iface") PWild)) () (EVar "iface")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig true "methodArityOf" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "methodArityOf" ((PVar "method")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "method")) (EFieldAccess (EVar "methodIfaceTableRef") "value")) (arm (PCon "Some" (PTuple PWild (PVar "arity"))) () (EVar "arity")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig true "isDictParamName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDictParamName" ((PVar "x")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "x")) (ELit (LInt 5))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 5))) (EVar "x")) (ELit (LString "$dict")))))
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
(DTypeSig true "rngBound" (TyFun (TyCon "Lit") (TyCon "Int")))
(DFunDef false "rngBound" ((PCon "LInt" (PVar "n"))) (EVar "n"))
(DFunDef false "rngBound" ((PCon "LChar" (PVar "c"))) (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "c")))))
(DFunDef false "rngBound" (PWild) (ELit (LInt 0)))
# MARK
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CStmt" true) (mem "CArm" true) (mem "CGuard" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" false))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "patVars" false) (mem "bindNames" false) (mem "bindName" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "lookupAssoc" false) (mem "startsWith" false) (mem "fallthroughName" false) (mem "dedup" false) (mem "filterList" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
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
(DFunDef false "eagerVars" ((PVar "b") (PCon "CRecordUpdate" PWild (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "base")) (EApp (EApp (EVar "eagerVarsFields") (EVar "b")) (EVar "updates"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "base")) (EApp (EApp (EVar "eagerVarsFields") (EVar "b")) (EVar "updates"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CArray" (PVar "es"))) (EApp (EApp (EVar "eagerVarsList") (EVar "b")) (EVar "es")))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "i"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "i"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "i"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "eagerVars" ((PVar "b") (PCon "CDict" (PVar "name") PWild)) (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EVar "b")) (EListLit) (EListLit (EVar "name"))))
(DFunDef false "eagerVars" (PWild PWild) (EListLit))
(DTypeSig false "eagerVarsList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVarsList" (PWild (PList)) (EListLit))
(DFunDef false "eagerVarsList" ((PVar "b") (PCons (PVar "e") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "e")) (EApp (EApp (EVar "eagerVarsList") (EVar "b")) (EVar "rest"))))
(DTypeSig false "eagerVarsArms" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerVarsArms" (PWild (PList)) (EListLit))
(DFunDef false "eagerVarsArms" ((PVar "b") (PCons (PCon "CArm" (PVar "pat") (PVar "gs") (PVar "body")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EVar "eagerVarsGuarded") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (EVar "gs")) (EVar "body")) (EApp (EApp (EVar "eagerVarsArms") (EVar "b")) (EVar "rest"))))
(DTypeSig false "eagerVarsGuarded" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "eagerVarsGuarded" ((PVar "b") (PList) (PVar "body")) (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "body")))
(DFunDef false "eagerVarsGuarded" ((PVar "b") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest")) (PVar "body")) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "c")) (EApp (EApp (EApp (EVar "eagerVarsGuarded") (EVar "b")) (EVar "rest")) (EVar "body"))))
(DFunDef false "eagerVarsGuarded" ((PVar "b") (PCons (PCon "CGBind" (PVar "pat") (PVar "e")) (PVar "rest")) (PVar "body")) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EVar "b")) (EVar "e")) (EApp (EApp (EApp (EVar "eagerVarsGuarded") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (EVar "rest")) (EVar "body"))))
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
(DTypeSig false "bindEagerCallees" (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "bindEagerCallees" ((PCon "CBind" PWild (PVar "clauses"))) (EApp (EVar "dedup") (EApp (EVar "clauseEagerVars") (EVar "clauses"))))
(DTypeSig false "clauseEagerVars" (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "clauseEagerVars" ((PList)) (EListLit))
(DFunDef false "clauseEagerVars" ((PCons (PCon "CClause" (PVar "params") (PVar "body")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "eagerVars") (EApp (EVar "paramBound") (EVar "params"))) (EVar "body")) (EApp (EVar "clauseEagerVars") (EVar "rest"))))
(DTypeSig false "paramBound" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "paramBound" ((PList)) (EListLit))
(DFunDef false "paramBound" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "++" (EApp (EVar "patVars") (EVar "p")) (EApp (EVar "paramBound") (EVar "rest"))))
(DTypeSig false "valGlobalNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "valGlobalNames" ((PList)) (EListLit))
(DFunDef false "valGlobalNames" ((PCons (PCon "CBind" (PVar "name") (PList (PCon "CClause" (PList) PWild))) (PVar "rest"))) (EBinOp "::" (EVar "name") (EApp (EVar "valGlobalNames") (EVar "rest"))))
(DFunDef false "valGlobalNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "valGlobalNames") (EVar "rest")))
(DTypeSig false "eagerCalleesMap" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "eagerCalleesMap" (PWild (PList)) (EVar "omEmpty"))
(DFunDef false "eagerCalleesMap" ((PVar "nameSet") (PCons (PVar "b") (PVar "rest"))) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "bindName") (EVar "b"))) (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "nameSet")))) (EApp (EVar "bindEagerCallees") (EVar "b")))) (EApp (EApp (EVar "eagerCalleesMap") (EVar "nameSet")) (EVar "rest"))))
(DTypeSig true "eagerReachMap" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "eagerReachMap" ((PVar "binds")) (EBlock (DoLet false false (PVar "allNames") (EApp (EVar "bindNames") (EVar "binds"))) (DoLet false false (PVar "nameSet") (EApp (EApp (EVar "omFromNames") (EVar "allNames")) (EVar "omEmpty"))) (DoLet false false (PVar "valSet") (EApp (EApp (EVar "omFromNames") (EApp (EVar "valGlobalNames") (EVar "binds"))) (EVar "omEmpty"))) (DoLet false false (PVar "adj") (EApp (EApp (EVar "eagerCalleesMap") (EVar "nameSet")) (EVar "binds"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foldReachSCCs") (EVar "valSet")) (EVar "adj")) (EApp (EApp (EVar "tarjanSCCs") (EVar "allNames")) (EVar "adj"))) (EVar "omEmpty")))))
(DTypeSig false "foldReachSCCs" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "foldReachSCCs" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "foldReachSCCs" ((PVar "valSet") (PVar "adj") (PCons (PVar "scc") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "direct") (EApp (EVar "dedup") (EApp (EApp (EVar "unionLookup") (EVar "scc")) (EVar "adj")))) (DoLet false false (PVar "reached") (EApp (EVar "dedup") (EBinOp "++" (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "valSet")))) (EVar "direct")) (EApp (EApp (EVar "unionLookup") (EVar "direct")) (EVar "acc"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foldReachSCCs") (EVar "valSet")) (EVar "adj")) (EVar "rest")) (EApp (EApp (EApp (EVar "insertReach") (EVar "scc")) (EVar "reached")) (EVar "acc"))))))
(DTypeSig false "unionLookup" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "unionLookup" ((PList) PWild) (EListLit))
(DFunDef false "unionLookup" ((PCons (PVar "n") (PVar "rest")) (PVar "m")) (EBinOp "++" (EApp (EApp (EVar "fromOption") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "m"))) (EApp (EApp (EVar "unionLookup") (EVar "rest")) (EVar "m"))))
(DTypeSig false "insertReach" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "insertReach" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "insertReach" ((PCons (PVar "n") (PVar "rest")) (PVar "reached") (PVar "acc")) (EApp (EApp (EApp (EVar "insertReach") (EVar "rest")) (EVar "reached")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "reached")) (EVar "acc"))))
(DTypeSig true "bindEagerReach" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "bindEagerReach" ((PVar "rm") (PCon "CBind" (PVar "name") (PList (PCon "CClause" (PList) PWild)))) (EApp (EApp (EVar "fromOption") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "rm"))))
(DFunDef false "bindEagerReach" (PWild PWild) (EListLit))
(DTypeSig true "methodIfaceTableRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "methodIfaceTableRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "methodIfaceOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "methodIfaceOf" ((PVar "method")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "method")) (EFieldAccess (EVar "methodIfaceTableRef") "value")) (arm (PCon "Some" (PTuple (PVar "iface") PWild)) () (EVar "iface")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig true "methodArityOf" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "methodArityOf" ((PVar "method")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "method")) (EFieldAccess (EVar "methodIfaceTableRef") "value")) (arm (PCon "Some" (PTuple PWild (PVar "arity"))) () (EVar "arity")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig true "isDictParamName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDictParamName" ((PVar "x")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "x")) (ELit (LInt 5))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 5))) (EVar "x")) (ELit (LString "$dict")))))
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
(DTypeSig true "rngBound" (TyFun (TyCon "Lit") (TyCon "Int")))
(DFunDef false "rngBound" ((PCon "LInt" (PVar "n"))) (EVar "n"))
(DFunDef false "rngBound" ((PCon "LChar" (PVar "c"))) (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "c")))))
(DFunDef false "rngBound" (PWild) (ELit (LInt 0)))
