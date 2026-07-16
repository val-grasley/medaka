# META
source_lines=571
stages=DESUGAR,MARK
# SOURCE
-- Core IR evaluator — STAGE2-DESIGN §2.1's "trivial Core-IR tree-walker" that
-- closes the net-new-IR oracle gap by EQUIVALENCE: it evaluates the lowered Core
-- IR and its stdout/pp_value is diffed against the AST tree-walker (eval.mdk /
-- dev/eval_probe) over the whole fixture corpus.  Core IR is correct iff
-- evaluating it matches evaluating the AST.
--
-- It deliberately REUSES eval.mdk's runtime — the host `Value`, environment,
-- `apply`/dispatch/fall-through machinery, pattern matcher, arithmetic, externs
-- and `pp_value` — exactly the "reuse the host Value/GC/externs" the design
-- prescribes (Axis 2/§2.2).  A Core IR closure is a `VClosureF` (the host-fn
-- closure added to eval.mdk), so multi-clause functions and guard fall-through
-- run through the SAME `VMulti` + `VFallthrough` path the AST interpreter uses.
--
-- SLICE 1: the engine core — literals, lexically-addressed variables (resolved
-- by name for now; the slot-indexing consume-half is 2.0's parked rework),
-- application, lambdas, let / letrec / let-groups, match (with guards), if,
-- primitive binops (arith / compare / `::` / `++`), unary ops, tuples, lists,
-- ADT constructors + pattern matching, single- and multi-clause recursion.
-- SLICE 3: records (create / field access / update), refs (`Ref`/`setRef`/
-- `.value` externs + deref), arrays, ranges (list + array), index, slice, and
-- bare sequential blocks (`let mut` / `<-` rebinding) — the value-level helpers
-- are reused verbatim from eval.mdk, these arms only thread `ceval`.
-- SLICE 5: typeclass dispatch — impls/interface-defaults are lowered (Ty-free)
-- and installed into the driver's env as arg-tag-dispatched `VMulti`s (the same
-- values eval.mdk installs); `CMethod`/`CDict` arms consume the elaborated routes
-- on the typed lowering path.

import frontend.ast.{Lit(..), Pat(..), Addr(..), Route(..), Decl}
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
import ir.core_ir_lower.{lowerGroups, lowerImplsWith}
import support.util.{isEmptyL, dedup}
import eval.eval.{
  Value(..),
  EvalEnv(..),
  lookupEnv,
  extendEnv,
  pushFrame,
  findCell,
  applyValue,
  matchPat,
  force,
  startsWithAt,
  evalArith,
  evalUnop,
  consVal,
  appendVal,
  makeCtor,
  boolSeeds,
  externBindings,
  ctorToTypeRef,
  installConsts,
  cellResult,
  lookupBinding,
  isNullary,
  ppValue,
  outputRef,
  evalIndex,
  evalSlice,
  evalRange,
  rangeListMk,
  rangeArrayMk,
  evalRecordUpdate,
  evalValueField,
  evalField,
  narrowMethod,
  routeTag,
  applyDicts,
  applyMethodDicts,
  coalesceImpls,
  buildCtorToType,
  collectCtors,
  buildIfaceDispatch,
  implMethodNames,
  methodCellsOf,
  importFrameOf,
  pubReexports,
  evalVariantUpdate,
  buildCtorFieldOrders,
  ctorFieldOrdersRef,
  methodAtNarrow,
  applyValues,
}

-- ── the evaluator ─────────────────────────────────────────────────────────
export ceval : EvalEnv (Value e) -> CExpr -> <e> Value e
ceval _ (CLit l) = litValue l
ceval env (CVar x _) = if startsWithAt x then VUnit else lookupEnv env x
ceval env (CApp f x) = applyValue (ceval env f) (ceval env x)
ceval env (CLam pats body) = VClosureF env pats (e => ceval e body)
ceval env (CLet True (PVar f) e1 e2) = cevalRecLet env f e1 e2
ceval env (CLet _ pat e1 e2) = cevalLet env pat e1 e2
ceval env (CLetGroup binds body) = cevalLetGroup env binds body
ceval env (CMatch scrut arms) = cevalMatch env (ceval env scrut) arms
ceval env (CDecision scrut arms tree) =
  cevalDecision env (ceval env scrut) arms tree
ceval env (CIf c t e) = cevalIf env (ceval env c) t e
ceval env (CBinPrim op l r _) = cevalBinPrim op (ceval env l) (ceval env r)
ceval env (CUnOp op e) = evalUnop op (ceval env e)
ceval env (CTuple es) = VTuple (map (ceval env) es)
ceval env (CList es) = VList (map (ceval env) es)
ceval env (CBlock stmts) = cevalBlock env stmts
-- ── slice 3: records / refs / arrays / ranges / index / slice ──────────────
-- The value-level work (build / deref / index / range) is REUSED verbatim from
-- eval.mdk — these arms only thread `ceval` over the sub-expressions and hand the
-- resulting Values to eval.mdk's helpers, so the IR path and the AST path share
-- one runtime (the Axis-2 discipline).  Refs are plain externs (`Ref`/`setRef`)
-- reached through `CApp`/`CVar`; `.value` deref is `CFieldAccess _ "value"`.
ceval env (CArray es) = VArray (arrayFromList (map (ceval env) es))
ceval env (CRecord name fields) = VRecord name (map (cevalField env) fields)
ceval env (CRecordUpdate _ base fields) =
  evalRecordUpdate (ceval env base) (map (cevalField env) fields)
ceval env (CVariantUpdate con base fields) =
  evalVariantUpdate con (ceval env base) (map (cevalField env) fields)
ceval env (CFieldAccess e "value" _) = evalValueField (ceval env e)
ceval env (CFieldAccess e field _) = evalField (ceval env e) field
ceval env (CIndex a i) = evalIndex (ceval env a) (ceval env i)
ceval env (CSlice a lo hi incl) =
  evalSlice (ceval env a) (ceval env lo) (ceval env hi) incl
ceval env (CStringIndex a i) = evalIndex (ceval env a) (ceval env i)
ceval env (CStringSlice a lo hi incl) =
  evalSlice (ceval env a) (ceval env lo) (ceval env hi) incl
ceval env (CListIndex a i) = evalIndex (ceval env a) (ceval env i)
ceval env (CListSlice a lo hi incl) =
  evalSlice (ceval env a) (ceval env lo) (ceval env hi) incl
ceval env (CRangeList lo hi incl) =
  evalRange (ceval env lo) (ceval env hi) incl rangeListMk
ceval env (CRangeArray lo hi incl) =
  evalRange (ceval env lo) (ceval env hi) incl rangeArrayMk
-- ── slice 5: typeclass dispatch read out of the elaborated routes ──────────
-- These fire only on the TYPED lowering path (marker + typecheck.elaborate fills
-- the routes); the untyped driver leaves method occurrences as plain `CVar`s that
-- resolve to the installed `VMulti` and dispatch by arg-tag in `applyValue`.  The
-- arms mirror eval.mdk's `EMethodAt`/`EDictAt` exactly (Routes already read out
-- into the immutable `CMethod`/`CDict` at lowering time).
-- #413 LOCKSTEP: "mirror exactly" was aspirational — this arm had drifted, missing
-- both eval.mdk's `awaitsArgs` guard and its `fwdReqs` truncation, and (with
-- eval.mdk) applied the call site's impl dicts even to an impl method that declares
-- none.  It now calls eval.mdk's `applyMethodDicts`, the SINGLE shared
-- implementation, so the two interpreters cannot silently diverge again.
ceval env (CMethod name route implRoutes methRoutes) =
  let (narrowed, fwdReqs) = methodAtNarrow env (lookupEnv env name) route
  applyMethodDicts env name route narrowed fwdReqs implRoutes methRoutes
ceval env (CDict name routes) = applyDicts env (lookupEnv env name) routes
ceval _ _ = panic "core_ir ceval: unsupported node"

cevalField : EvalEnv (Value e) -> CField -> <e> (String, Value e)
cevalField env (CField k e) = (k, ceval env e)

litValue : Lit -> Value e
litValue (LInt n) = VInt n
litValue (LFloat f) = VFloat f
litValue (LString s) = VString s
litValue (LChar c) = VChar c
litValue (LBool b) = VBool b
litValue LUnit = VUnit

cevalBinPrim : String -> Value e -> Value e -> Value e
cevalBinPrim "::" l r = consVal l r
cevalBinPrim "++" l r = appendVal l r
cevalBinPrim op l r = evalArith op l r

cevalIf : EvalEnv (Value e) -> Value e -> CExpr -> CExpr -> <e> Value e
cevalIf env (VBool True) t _ = ceval env t
cevalIf env (VCon "True" []) t _ = ceval env t
cevalIf env (VBool False) _ e = ceval env e
cevalIf env (VCon "False" []) _ e = ceval env e
cevalIf _ _ _ _ = panic "if condition is not a Bool"

cevalMatch : EvalEnv (Value e) -> Value e -> List CArm -> <e> Value e
cevalMatch _ _ [] = panic "no matching clause in match"
cevalMatch env sv ((CArm pat guards body)::rest) = match matchPat pat sv
  None => cevalMatch env sv rest
  Some binds => match cevalGuards (extendEnv env binds) guards
    Some env2 => ceval env2 body
    None => cevalMatch env sv rest

cevalGuards : EvalEnv (Value e) -> List CGuard -> <e> Option (EvalEnv (Value e))
cevalGuards env [] = Some env
cevalGuards env ((CGBool g)::qs) = match ceval env g
  VBool True => cevalGuards env qs
  VCon "True" [] => cevalGuards env qs
  _ => None
cevalGuards env ((CGBind p e)::qs) = match matchPat p (ceval env e)
  Some b => cevalGuards (extendEnv env b) qs
  None => None

-- ── decision-tree match evaluation (§2.1) ──────────────────────────────────
-- Walk the compiled CTree against the scrutinee value, testing each field's
-- head once and routing to the selected arm — the same result cevalMatch's
-- ordered arms compute, with the per-clause re-tests collapsed into one tree.
-- `root` is the whole scrutinee (kept for the leaf re-match that recovers
-- bindings + runs guards); `occs` is the live column values (the matrix
-- columns), starting as just [root] and expanding into a constructor's fields
-- as the tree descends — kept in lockstep with the lowering's specialization.
cevalDecision : EvalEnv (Value e) -> Value e -> List CArm -> CTree -> <e> Value e
cevalDecision env root arms tree = cevalTree env root arms [root] tree

cevalTree : EvalEnv (Value e) -> Value e -> List CArm -> List (Value e) -> CTree -> <e> Value e
cevalTree _ _ _ _ CTFail = panic "no matching clause in match"
cevalTree env root arms _ (CTLeaf i) = cevalArm env root arms i
cevalTree env root arms occs (CTGuard i fail) =
  cevalGuardedArm env root arms occs i fail
cevalTree env root arms occs (CTDrop sub) =
  cevalTree env root arms (cOccsTail occs) sub
cevalTree env root arms occs (CTSwitch branches dft) =
  cevalSwitch env root arms occs branches dft

cOccsTail : List (Value e) -> List (Value e)
cOccsTail [] = []
cOccsTail (_::xs) = xs

-- a terminal leaf: re-match the selected arm's ORIGINAL pattern against the
-- whole scrutinee (guaranteed to match — the tree path implies it) to recover
-- its variable bindings, then evaluate its body.
cevalArm : EvalEnv (Value e) -> Value e -> List CArm -> Int -> <e> Value e
cevalArm env root arms i = match nthArm arms i
  Some (CArm pat _ body) => cevalArmBody env root pat body
  None => panic "core_ir decision tree: arm index out of range"

cevalArmBody : EvalEnv (Value e) -> Value e -> Pat -> CExpr -> <e> Value e
cevalArmBody env root pat body = match matchPat pat root
  Some binds => ceval (extendEnv env binds) body
  None => panic "core_ir decision tree: leaf pattern did not match scrutinee"

-- a guarded leaf: re-match for bindings, run the guards; on success eval the
-- body, on failure resume the ordered semantics via the `fail` subtree (at the
-- current column context, so its switches read the same live sub-values).
cevalGuardedArm : EvalEnv (Value e) -> Value e -> List CArm -> List (Value e) -> Int -> CTree -> <e> Value e
cevalGuardedArm env root arms occs i fail = match nthArm arms i
  Some (CArm pat guards body) =>
    cevalGuardedBody env root arms occs pat guards body fail
  None => panic "core_ir decision tree: guarded arm index out of range"

-- `None` from matchPat is a fall-through, not a panic: PRng/PRec arms
-- canonicalize to PWild in the matrix (so the tree may route to them), but
-- matchPat tests the ORIGINAL pattern, which can legitimately fail (e.g. a
-- value out of range, or a record missing a required field).  The fall-through
-- resumes the ordered semantics via the `fail` subtree, exactly as cevalMatch's
-- sequential arm-by-arm search would.  For non-PRng/PRec arms the tree
-- guarantees the pattern matches, so None is unreachable there.
cevalGuardedBody : EvalEnv (Value e) -> Value e -> List CArm -> List (Value e) -> Pat -> List CGuard -> CExpr -> CTree -> <e> Value e
cevalGuardedBody env root arms occs pat guards body fail = match matchPat pat root
  None => cevalTree env root arms occs fail
  Some binds => match cevalGuards (extendEnv env binds) guards
    Some env2 => ceval env2 body
    None => cevalTree env root arms occs fail

-- a switch: the head occurrence (column 0) is `occs`'s head; try each branch's
-- head against it (constructors/literals are disjoint, so the first match is
-- THE match), descending into the matched head's fields ++ the remaining
-- columns; if none match, the default branch drops the head column.
cevalSwitch : EvalEnv (Value e) -> Value e -> List CArm -> List (Value e) -> List CTBranch -> CTree -> <e> Value e
cevalSwitch env root arms [] branches dft = cevalTree env root arms [] dft
cevalSwitch env root arms (v::rest) branches dft =
  cevalSwitchOn env root arms v rest branches dft

cevalSwitchOn : EvalEnv (Value e) -> Value e -> List CArm -> Value e -> List (Value e) -> List CTBranch -> CTree -> <e> Value e
cevalSwitchOn env root arms _ rest [] dft = cevalTree env root arms rest dft
cevalSwitchOn env root arms v rest ((CTBranch head sub)::more) dft = match headExtract head v
  Some subs => cevalTree env root arms (subs ++ rest) sub
  None => cevalSwitchOn env root arms v rest more dft

-- test a head against a value, returning its decomposed sub-values when it
-- matches.  Reuses matchPat (with fresh binders) for BOTH the test and the
-- field extraction, so list/tuple/bool/unit value shapes need no special code.
headExtract : CHead -> Value e -> Option (List (Value e))
headExtract (HCon c a) v = extractWith (PCon c (cBinders a)) v
headExtract (HTuple n) v = extractWith (PTuple (cBinders n)) v
headExtract HCons v = extractWith (PCons (PVar "$d0") (PVar "$d1")) v
headExtract HNil v = extractWith (PList []) v
headExtract HUnit v = extractWith (PLit LUnit) v
headExtract (HLit l) v = extractWith (PLit l) v

extractWith : Pat -> Value e -> Option (List (Value e))
extractWith p v = map (map snd) (matchPat p v)

-- `a` fresh binder patterns ($d0, $d1, …); matchPats binds them left-to-right,
-- so `map snd` recovers the constructor's fields in order.  The names are
-- discarded, so collisions are harmless.
cBinders : Int -> List Pat
cBinders n = cBindersGo 0 n

cBindersGo : Int -> Int -> List Pat
cBindersGo i n
  | i >= n = []
  | otherwise = PVar ("$d" ++ intToString i) :: cBindersGo (i + 1) n

nthArm : List CArm -> Int -> Option CArm
nthArm (a::_) 0 = Some a
nthArm (_::rest) n = nthArm rest (n - 1)
nthArm [] _ = None

cevalRecLet : EvalEnv (Value e) -> String -> CExpr -> CExpr -> <e> Value e
cevalRecLet env f e1 e2 =
  let cell = Ref VUnit
  let recEnv = pushFrame env [(f, cell)]
  let v = ceval recEnv e1
  let _ = setRef cell v
  ceval recEnv e2

cevalLet : EvalEnv (Value e) -> Pat -> CExpr -> CExpr -> <e> Value e
cevalLet env pat e1 e2 = match matchPat pat (ceval env e1)
  None => panic "let pattern match failure"
  Some binds => ceval (extendEnv env binds) e2

-- ── bare sequential blocks (function-body `let` sequences, imperative IO) ───
-- Mirrors eval.mdk's evalBlock: a block ending in a `let` yields VUnit; ending
-- in an expr yields that expr.  (Mutable-cell `let mut` / Ref rebinding via
-- DoAssign is carried for slice 3; slice-1 fixtures use only let + expr.)
cevalBlock : EvalEnv (Value e) -> List CStmt -> <e> Value e
cevalBlock _ [] = VUnit
cevalBlock env [CSExpr e] = ceval env e
cevalBlock env [CSLet _ pat e] = cBlockLetLast env pat e
cevalBlock env ((CSExpr e)::rest) =
  let _ = ceval env e
  cevalBlock env rest
cevalBlock env ((CSLet _ pat e)::rest) = cBlockLet env pat e rest
cevalBlock env [CSAssign _ e] =
  let _ = ceval env e
  VUnit
cevalBlock env ((CSAssign x e)::rest) =
  cevalBlock (extendEnv env [(x, ceval env e)]) rest

cBlockLetLast : EvalEnv (Value e) -> Pat -> CExpr -> <e> Value e
cBlockLetLast env pat e = match matchPat pat (ceval env e)
  None => panic "let pattern match failure in block"
  Some _ => VUnit

cBlockLet : EvalEnv (Value e) -> Pat -> CExpr -> List CStmt -> <e> Value e
cBlockLet env pat e rest = match matchPat pat (ceval env e)
  None => panic "let pattern match failure in block"
  Some binds => cevalBlock (extendEnv env binds) rest

-- ── let-groups (where / mutually-recursive coalesced bindings) ─────────────
cevalLetGroup : EvalEnv (Value e) -> List CBind -> CExpr -> <e> Value e
cevalLetGroup env binds body =
  let cells = map cBindCell binds
  let env2 = pushFrame env cells
  let _ = cInstallGroup env2 cells binds
  ceval env2 body

cBindCell : CBind -> (String, Ref (Value e))
cBindCell (CBind name _) = (name, Ref VUnit)

cInstallGroup : EvalEnv (Value e) -> List (String, Ref (Value e)) -> List CBind -> <e> Unit
cInstallGroup _ _ [] = ()
cInstallGroup env cells ((CBind name clauses)::rest) =
  let _ = setRef (findCell cells name) (cGroupValue env clauses)
  cInstallGroup env cells rest

-- let-group binding value: a nullary single clause is eager (recursive let);
-- multi-clause coalesces into a VMulti dispatched by arg pattern + fall-through.
cGroupValue : EvalEnv (Value e) -> List CClause -> <e> Value e
cGroupValue env [CClause pats body]
  | isNullary pats = ceval env body
  | otherwise = cClauseClosure env (CClause pats body)
cGroupValue env clauses = VMulti (map (cClauseClosure env) clauses)

cClauseClosure : EvalEnv (Value e) -> CClause -> Value e
cClauseClosure env (CClause pats body) = VClosureF env pats (e => ceval e body)

-- ── program driver ─────────────────────────────────────────────────────────
-- Mirror of eval.mdk's evalProgram, but installs Core IR groups.  A nullary
-- top-level binding becomes a deferred VThunk (forced on first lookup) so
-- point-free defs can reference values installed later, in any order.
export cevalProgram : CProgram -> <e> List (String, Value e)
cevalProgram (CProgram groups ctorArs ctorToType implEntries) =
  let _ = setRef ctorToTypeRef ctorToType
  let ctors = map ctorBinding ctorArs
  let allNames = map fst boolSeeds ++ map fst (externBindings ()) ++ map fst ctors ++ map cBindName groups ++ cImplMethodNames implEntries
  let cells = map (n => (n, Ref VUnit)) allNames
  let env = EvalEnv [cells]
  let _ = installConsts cells boolSeeds
  let _ = installConsts cells (externBindings ())
  let _ = installConsts cells ctors
  let _ = installConsts cells (coalesceImpls (map (cImplEntryValue env) implEntries))
  let _ = cInstallTopGroups env cells groups
  map cellResult cells
-- impls (lazy closures) install BEFORE groups so a nullary group's eager body
-- can already see the dispatch tables — mirrors eval.mdk's evalProgram order.

ctorBinding : (String, Int) -> (String, Value e)
ctorBinding (name, arity) = (name, makeCtor name arity)

-- ── typeclass impl installation (slice 5) ──────────────────────────────────
-- Turn each lowered CImplEntry into the same (name, (score, Value)) eval.mdk's
-- declImplEntries produces, then `coalesceImpls` (reused) sorts by specificity
-- and folds same-named candidates into one VMulti — the arg-tag-dispatched value
-- the AST walker installs.  The only difference from eval.mdk is the closure
-- body runs `ceval` over a `CExpr` instead of `eval` over an `Expr`.
cImplMethodNames : List CImplEntry -> List String
cImplMethodNames entries = dedup (map cImplEntryName entries)

cImplEntryName : CImplEntry -> String
cImplEntryName (CImplEntry n _ _) = n

cImplEntryValue : EvalEnv (Value e) -> CImplEntry -> (String, (Int, Value e))
cImplEntryValue env (CImplEntry name score body) =
  (name, (score, cImplBodyValue env body))

cImplBodyValue : EvalEnv (Value e) -> CImplBody -> Value e
cImplBodyValue env (CImplTagged tag key iface positions pats body) =
  VTypedImpl tag key positions 0 (cImplMethodValue env positions pats body)
cImplBodyValue env (CImplDefault pats body) = cImplMethodValue env [] pats body

-- A point-free (no-param) impl/default body: defer a return-position method as a
-- VThunk; otherwise eta-expand so the discriminating arg still reaches the body
-- (mirrors eval.mdk's implMethodValue / Phase 121).
cImplMethodValue : EvalEnv (Value e) -> List Int -> List Pat -> CExpr -> Value e
cImplMethodValue env positions [] body
  | isEmptyL positions = VThunk (_ => ceval env body)
  | otherwise = VClosureF env [PVar "$eta"] (e => ceval e (CApp body (CVar "$eta" AGlobal)))
cImplMethodValue env _ pats body = VClosureF env pats (e => ceval e body)

cBindName : CBind -> String
cBindName (CBind n _) = n

cInstallTopGroups : EvalEnv (Value e) -> List (String, Ref (Value e)) -> List CBind -> <e> Unit
cInstallTopGroups _ _ [] = ()
cInstallTopGroups env cells ((CBind n clauses)::rest) =
  let _ = setRef (findCell cells n) (cTopGroupValue env clauses)
  cInstallTopGroups env cells rest

cTopGroupValue : EvalEnv (Value e) -> List CClause -> Value e
cTopGroupValue env [CClause pats body]
  | isNullary pats = VThunk (_ => ceval env body)
  | otherwise = VClosureF env pats (e => ceval e body)
cTopGroupValue env clauses = VMulti (map (cClauseClosure env) clauses)

-- ── entry point (pure-value path, diffed via pp_value of `main`) ───────────
export cevalMain : CProgram -> String
cevalMain prog = match lookupBinding "main" (cevalProgram prog)
  Some v => ppValue (force v)
  None => panic "core_ir eval: no `main` binding"

-- Run the Core IR program for its OUTPUT (forcing `main`, whose IO side-effects
-- append to eval.mdk's outputRef) and return the captured stdout — the Core-IR
-- analog of eval.mdk's evalOutput, for the typed / run corpora that diff stdout
-- (=== EVAL === goldens) rather than pp_value of `main`.
export cevalOutput : CProgram -> String
cevalOutput prog =
  let _ = setRef outputRef ""
  let binds = cevalProgram prog
  let _ = cRunMainForEffect binds
  outputRef.value

cRunMainForEffect : List (String, Value e) -> <e> Value e
cRunMainForEffect binds = match lookupBinding "main" binds
  Some v => force v
  None => VUnit

-- ── multi-module evaluation (per-module Core-IR frames over a shared global) ──
-- The Core-IR analog of eval.mdk's evalModules — the loader-driven path that runs
-- the compiler's own module graph through the Core IR.  Structure mirrors the AST
-- evalModules EXACTLY: the prelude (core) installs GLOBALLY (all its names
-- global); each loaded module's top-level groups are LOCAL, so same-named
-- functions across modules stay isolated (Phase 110); ctors and impl methods
-- coalesce GLOBALLY into one coherent VMulti per interface method.  Modules arrive
-- dependency-first (loader order); a module's `import`s resolve to the exporting
-- module's cells.  VThunk laziness defers every nullary binding to its first
-- lookup, so the reference's explicit deferred-thunk ordering is unnecessary here.
--
-- The only Core-IR-specific work vs evalModules is the LOWERING: each module's
-- groups lower to `CBind`s (installed via cInstallTopGroups's ceval-closures) and
-- its impls lower to `CImplEntry`s against the JOINT dispatch table built from
-- ALL decls (an impl in one module for a prelude interface needs the prelude's
-- dispatch positions).  The value-agnostic import-frame machinery (importFrameOf /
-- pubReexports — they thread only cells + DUse paths, never Values) is reused
-- verbatim from eval.mdk.  UNTYPED path, like cevalProgram / evalModules.
-- parameterized over the value type (v := Value e), like eval.mdk's ModInfo —
-- see the kind-inference note on `Value`
data CModInfo v =
  | CModInfo String (List Decl) (List CBind) (List CImplEntry) (List (String, Ref v)) (EvalEnv v)

export cevalModules : List Decl -> List (String, List Decl) -> <e> List (String, Value e)
cevalModules preludeDecls modules =
  let moduleDecls = flatMap snd modules
  let allDecls = preludeDecls ++ moduleDecls
  let _ = setRef ctorToTypeRef (buildCtorToType allDecls)
  let _ = setRef ctorFieldOrdersRef (buildCtorFieldOrders allDecls)
  let disp = buildIfaceDispatch allDecls
  let ctors = collectCtors allDecls
  let preludeGroups = lowerGroups preludeDecls
  let preludeImpls = lowerImplsWith disp preludeDecls
  let globalNames = map fst boolSeeds ++ map fst (externBindings ()) ++ map fst ctors ++ implMethodNames allDecls ++ map cBindName preludeGroups
  let globalCells = map (n => (n, Ref VUnit)) globalNames
  let globalEnv = EvalEnv [globalCells]
  let mods = cBuildModInfos disp globalCells [] modules
  let implEntries = map (cImplEntryValue globalEnv) preludeImpls ++ flatMap cModImplValues mods
  let _ = installConsts globalCells boolSeeds
  let _ = installConsts globalCells (externBindings ())
  let _ = installConsts globalCells ctors
  let _ = installConsts globalCells (coalesceImpls implEntries)
  let _ = cInstallTopGroups globalEnv globalCells preludeGroups
  let _ = cInstallModGroups mods
  cRootLocals mods

-- pass 1: lower + allocate each module's local cells and build its env (imports
-- resolved against already-processed modules, since loader order is
-- dependency-first).  Mirror of eval.mdk's buildModInfos, lowering groups/impls.
cBuildModInfos : List ((String, String), List Int) -> List (String, Ref (Value e)) -> List (String, List (String, Ref (Value e))) -> List (String, List Decl) -> List (CModInfo (Value e))
cBuildModInfos _ _ _ [] = []
cBuildModInfos disp globalCells exportsMap ((mid, decls)::rest) =
  let cbinds = lowerGroups decls
  let cimpls = lowerImplsWith disp decls
  -- P0-9 (Core-IR port of the eval.mdk fix): each module's OWN constructors ALSO
  -- live in its LOCAL frame — they stay in the shared global too (see
  -- cevalModules) for by-name / `Type(..)` cross-module ctor imports.  The local
  -- copy SHADOWS the global, which is keyed by BARE ctor name across every
  -- module's decls; two modules defining a same-named ctor at different arities
  -- (`map`'s arity-5 `Bin` vs `set`'s arity-4 `Bin`) collide in that one global
  -- cell, so a module would otherwise construct via the OTHER module's arity —
  -- saturating early and applying the surplus arg (E-NOT-A-FUNCTION).
  let modCtors = collectCtors decls
  let localCells = map (n => (n, Ref VUnit)) (map cBindName cbinds ++ map fst modCtors)
  let imports = importFrameOf exportsMap decls
  let menv = EvalEnv [localCells, imports, globalCells]
  -- IMPORT ALIASING (Core-IR port of the eval.mdk fix — these two module drivers are
  -- parallel and their frame semantics MUST move in lockstep): a module also exports the
  -- interface/impl METHODS it declares, bound to the SAME global (coalesced-dispatcher)
  -- cell.  Methods are global-by-name and so appear in no module's localCells; without
  -- this, an ALIASED method import binds to nothing, while an un-aliased one silently
  -- works by falling through to the global frame under its unchanged name.
  let exports = localCells ++ methodCellsOf globalCells decls ++ pubReexports globalCells exportsMap decls
  CModInfo mid decls cbinds cimpls localCells menv :: cBuildModInfos disp globalCells ((mid, exports)::exportsMap) rest

-- a module's impl methods / interface defaults close over ITS env but coalesce
-- into the shared global VMulti (mirror of eval.mdk's modImplEntries)
cModImplValues : CModInfo (Value e) -> <e> List (String, (Int, Value e))
cModImplValues (CModInfo _ _ _ cimpls _ menv) =
  map (cImplEntryValue menv) cimpls

-- pass 2: install each module's groups into its own cells (its env)
cInstallModGroups : List (CModInfo (Value e)) -> <e> Unit
cInstallModGroups [] = ()
cInstallModGroups ((CModInfo _ decls cbinds _ cells menv)::rest) =
  let _ = cInstallTopGroups menv cells cbinds
  -- P0-9: install this module's own ctor values into its local cells (allocated
  -- in cBuildModInfos), so map/set construct their own arity-correct `Bin`/`Tip`.
  let _ = installConsts cells (collectCtors decls)
  cInstallModGroups rest

-- the root module is last in dependency order; its locals hold `main`
cRootLocals : List (CModInfo (Value e)) -> <e> List (String, Value e)
cRootLocals [] = []
cRootLocals [CModInfo _ _ _ _ cells _] = map cellResult cells
cRootLocals (_::rest) = cRootLocals rest

-- Run a multi-module Core-IR program for its OUTPUT (the loader-driven analog of
-- cevalOutput): evaluate every module in dependency order, force the root module's
-- `main` for its IO side-effects, return the captured stdout.
export cevalModulesOutput : List Decl -> List (String, List Decl) -> String
cevalModulesOutput preludeDecls modules =
  let _ = setRef outputRef ""
  let binds = cevalModules preludeDecls modules
  let _ = cRunMainForEffect binds
  outputRef.value
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true) (mem "Addr" true) (mem "Route" true) (mem "Decl" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CProgram" true) (mem "CTree" true) (mem "CTBranch" true) (mem "CHead" true))))
(DUse false (UseGroup ("ir" "core_ir_lower") ((mem "lowerGroups" false) (mem "lowerImplsWith" false))))
(DUse false (UseGroup ("support" "util") ((mem "isEmptyL" false) (mem "dedup" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "EvalEnv" true) (mem "lookupEnv" false) (mem "extendEnv" false) (mem "pushFrame" false) (mem "findCell" false) (mem "applyValue" false) (mem "matchPat" false) (mem "force" false) (mem "startsWithAt" false) (mem "evalArith" false) (mem "evalUnop" false) (mem "consVal" false) (mem "appendVal" false) (mem "makeCtor" false) (mem "boolSeeds" false) (mem "externBindings" false) (mem "ctorToTypeRef" false) (mem "installConsts" false) (mem "cellResult" false) (mem "lookupBinding" false) (mem "isNullary" false) (mem "ppValue" false) (mem "outputRef" false) (mem "evalIndex" false) (mem "evalSlice" false) (mem "evalRange" false) (mem "rangeListMk" false) (mem "rangeArrayMk" false) (mem "evalRecordUpdate" false) (mem "evalValueField" false) (mem "evalField" false) (mem "narrowMethod" false) (mem "routeTag" false) (mem "applyDicts" false) (mem "applyMethodDicts" false) (mem "coalesceImpls" false) (mem "buildCtorToType" false) (mem "collectCtors" false) (mem "buildIfaceDispatch" false) (mem "implMethodNames" false) (mem "methodCellsOf" false) (mem "importFrameOf" false) (mem "pubReexports" false) (mem "evalVariantUpdate" false) (mem "buildCtorFieldOrders" false) (mem "ctorFieldOrdersRef" false) (mem "methodAtNarrow" false) (mem "applyValues" false))))
(DTypeSig true "ceval" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "CExpr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "ceval" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "litValue") (EVar "l")))
(DFunDef false "ceval" ((PVar "env") (PCon "CVar" (PVar "x") PWild)) (EIf (EApp (EVar "startsWithAt") (EVar "x")) (EVar "VUnit") (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "x"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "applyValue") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "f"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "x"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "VClosureF") (EVar "env")) (EVar "pats")) (ELam ((PVar "e")) (EApp (EApp (EVar "ceval") (EVar "e")) (EVar "body")))))
(DFunDef false "ceval" ((PVar "env") (PCon "CLet" (PCon "True") (PCon "PVar" (PVar "f")) (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "cevalRecLet") (EVar "env")) (EVar "f")) (EVar "e1")) (EVar "e2")))
(DFunDef false "ceval" ((PVar "env") (PCon "CLet" PWild (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "cevalLet") (EVar "env")) (EVar "pat")) (EVar "e1")) (EVar "e2")))
(DFunDef false "ceval" ((PVar "env") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EVar "cevalLetGroup") (EVar "env")) (EVar "binds")) (EVar "body")))
(DFunDef false "ceval" ((PVar "env") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EVar "cevalMatch") (EVar "env")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "ceval" ((PVar "env") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EApp (EVar "cevalDecision") (EVar "env")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "scrut"))) (EVar "arms")) (EVar "tree")))
(DFunDef false "ceval" ((PVar "env") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "cevalIf") (EVar "env")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "c"))) (EVar "t")) (EVar "e")))
(DFunDef false "ceval" ((PVar "env") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") PWild)) (EApp (EApp (EApp (EVar "cevalBinPrim") (EVar "op")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "l"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "r"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CUnOp" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "evalUnop") (EVar "op")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CTuple" (PVar "es"))) (EApp (EVar "VTuple") (EApp (EApp (EVar "map") (EApp (EVar "ceval") (EVar "env"))) (EVar "es"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CList" (PVar "es"))) (EApp (EVar "VList") (EApp (EApp (EVar "map") (EApp (EVar "ceval") (EVar "env"))) (EVar "es"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "cevalBlock") (EVar "env")) (EVar "stmts")))
(DFunDef false "ceval" ((PVar "env") (PCon "CArray" (PVar "es"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EApp (EVar "ceval") (EVar "env"))) (EVar "es")))))
(DFunDef false "ceval" ((PVar "env") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "VRecord") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "cevalField") (EVar "env"))) (EVar "fields"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields"))) (EApp (EApp (EVar "evalRecordUpdate") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "cevalField") (EVar "env"))) (EVar "fields"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "evalVariantUpdate") (EVar "con")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "cevalField") (EVar "env"))) (EVar "fields"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CFieldAccess" (PVar "e") (PLit (LString "value")) PWild)) (EApp (EVar "evalValueField") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CFieldAccess" (PVar "e") (PVar "field") PWild)) (EApp (EApp (EVar "evalField") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))) (EVar "field")))
(DFunDef false "ceval" ((PVar "env") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "evalIndex") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "i"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "evalSlice") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "ceval" ((PVar "env") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "evalIndex") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "i"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "evalSlice") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "ceval" ((PVar "env") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "evalIndex") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "i"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "evalSlice") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "ceval" ((PVar "env") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "evalRange") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "hi"))) (EVar "incl")) (EVar "rangeListMk")))
(DFunDef false "ceval" ((PVar "env") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "evalRange") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "hi"))) (EVar "incl")) (EVar "rangeArrayMk")))
(DFunDef false "ceval" ((PVar "env") (PCon "CMethod" (PVar "name") (PVar "route") (PVar "implRoutes") (PVar "methRoutes"))) (EBlock (DoLet false false (PTuple (PVar "narrowed") (PVar "fwdReqs")) (EApp (EApp (EApp (EVar "methodAtNarrow") (EVar "env")) (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "name"))) (EVar "route"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyMethodDicts") (EVar "env")) (EVar "name")) (EVar "route")) (EVar "narrowed")) (EVar "fwdReqs")) (EVar "implRoutes")) (EVar "methRoutes")))))
(DFunDef false "ceval" ((PVar "env") (PCon "CDict" (PVar "name") (PVar "routes"))) (EApp (EApp (EApp (EVar "applyDicts") (EVar "env")) (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "name"))) (EVar "routes")))
(DFunDef false "ceval" (PWild PWild) (EApp (EVar "panic") (ELit (LString "core_ir ceval: unsupported node"))))
(DTypeSig false "cevalField" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "CField") (TyEffect () (Some "e") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cevalField" ((PVar "env") (PCon "CField" (PVar "k") (PVar "e"))) (ETuple (EVar "k") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))))
(DTypeSig false "litValue" (TyFun (TyCon "Lit") (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "litValue" ((PCon "LInt" (PVar "n"))) (EApp (EVar "VInt") (EVar "n")))
(DFunDef false "litValue" ((PCon "LFloat" (PVar "f"))) (EApp (EVar "VFloat") (EVar "f")))
(DFunDef false "litValue" ((PCon "LString" (PVar "s"))) (EApp (EVar "VString") (EVar "s")))
(DFunDef false "litValue" ((PCon "LChar" (PVar "c"))) (EApp (EVar "VChar") (EVar "c")))
(DFunDef false "litValue" ((PCon "LBool" (PVar "b"))) (EApp (EVar "VBool") (EVar "b")))
(DFunDef false "litValue" ((PCon "LUnit")) (EVar "VUnit"))
(DTypeSig false "cevalBinPrim" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "cevalBinPrim" ((PLit (LString "::")) (PVar "l") (PVar "r")) (EApp (EApp (EVar "consVal") (EVar "l")) (EVar "r")))
(DFunDef false "cevalBinPrim" ((PLit (LString "++")) (PVar "l") (PVar "r")) (EApp (EApp (EVar "appendVal") (EVar "l")) (EVar "r")))
(DFunDef false "cevalBinPrim" ((PVar "op") (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "evalArith") (EVar "op")) (EVar "l")) (EVar "r")))
(DTypeSig false "cevalIf" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalIf" ((PVar "env") (PCon "VBool" (PCon "True")) (PVar "t") PWild) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "t")))
(DFunDef false "cevalIf" ((PVar "env") (PCon "VCon" (PLit (LString "True")) (PList)) (PVar "t") PWild) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "t")))
(DFunDef false "cevalIf" ((PVar "env") (PCon "VBool" (PCon "False")) PWild (PVar "e")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e")))
(DFunDef false "cevalIf" ((PVar "env") (PCon "VCon" (PLit (LString "False")) (PList)) PWild (PVar "e")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e")))
(DFunDef false "cevalIf" (PWild PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "if condition is not a Bool"))))
(DTypeSig false "cevalMatch" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cevalMatch" (PWild PWild (PList)) (EApp (EVar "panic") (ELit (LString "no matching clause in match"))))
(DFunDef false "cevalMatch" ((PVar "env") (PVar "sv") (PCons (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EVar "sv")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "cevalMatch") (EVar "env")) (EVar "sv")) (EVar "rest"))) (arm (PCon "Some" (PVar "binds")) () (EMatch (EApp (EApp (EVar "cevalGuards") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "guards")) (arm (PCon "Some" (PVar "env2")) () (EApp (EApp (EVar "ceval") (EVar "env2")) (EVar "body"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "cevalMatch") (EVar "env")) (EVar "sv")) (EVar "rest")))))))
(DTypeSig false "cevalGuards" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalGuards" ((PVar "env") (PList)) (EApp (EVar "Some") (EVar "env")))
(DFunDef false "cevalGuards" ((PVar "env") (PCons (PCon "CGBool" (PVar "g")) (PVar "qs"))) (EMatch (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "g")) (arm (PCon "VBool" (PCon "True")) () (EApp (EApp (EVar "cevalGuards") (EVar "env")) (EVar "qs"))) (arm (PCon "VCon" (PLit (LString "True")) (PList)) () (EApp (EApp (EVar "cevalGuards") (EVar "env")) (EVar "qs"))) (arm PWild () (EVar "None"))))
(DFunDef false "cevalGuards" ((PVar "env") (PCons (PCon "CGBind" (PVar "p") (PVar "e")) (PVar "qs"))) (EMatch (EApp (EApp (EVar "matchPat") (EVar "p")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "cevalGuards") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "b"))) (EVar "qs"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "cevalDecision" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "CTree") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalDecision" ((PVar "env") (PVar "root") (PVar "arms") (PVar "tree")) (EApp (EApp (EApp (EApp (EApp (EVar "cevalTree") (EVar "env")) (EVar "root")) (EVar "arms")) (EListLit (EVar "root"))) (EVar "tree")))
(DTypeSig false "cevalTree" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "CTree") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "cevalTree" (PWild PWild PWild PWild (PCon "CTFail")) (EApp (EVar "panic") (ELit (LString "no matching clause in match"))))
(DFunDef false "cevalTree" ((PVar "env") (PVar "root") (PVar "arms") PWild (PCon "CTLeaf" (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "cevalArm") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "i")))
(DFunDef false "cevalTree" ((PVar "env") (PVar "root") (PVar "arms") (PVar "occs") (PCon "CTGuard" (PVar "i") (PVar "fail"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cevalGuardedArm") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "occs")) (EVar "i")) (EVar "fail")))
(DFunDef false "cevalTree" ((PVar "env") (PVar "root") (PVar "arms") (PVar "occs") (PCon "CTDrop" (PVar "sub"))) (EApp (EApp (EApp (EApp (EApp (EVar "cevalTree") (EVar "env")) (EVar "root")) (EVar "arms")) (EApp (EVar "cOccsTail") (EVar "occs"))) (EVar "sub")))
(DFunDef false "cevalTree" ((PVar "env") (PVar "root") (PVar "arms") (PVar "occs") (PCon "CTSwitch" (PVar "branches") (PVar "dft"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cevalSwitch") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "occs")) (EVar "branches")) (EVar "dft")))
(DTypeSig false "cOccsTail" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "cOccsTail" ((PList)) (EListLit))
(DFunDef false "cOccsTail" ((PCons PWild (PVar "xs"))) (EVar "xs"))
(DTypeSig false "cevalArm" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalArm" ((PVar "env") (PVar "root") (PVar "arms") (PVar "i")) (EMatch (EApp (EApp (EVar "nthArm") (EVar "arms")) (EVar "i")) (arm (PCon "Some" (PCon "CArm" (PVar "pat") PWild (PVar "body"))) () (EApp (EApp (EApp (EApp (EVar "cevalArmBody") (EVar "env")) (EVar "root")) (EVar "pat")) (EVar "body"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "core_ir decision tree: arm index out of range"))))))
(DTypeSig false "cevalArmBody" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Pat") (TyFun (TyCon "CExpr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalArmBody" ((PVar "env") (PVar "root") (PVar "pat") (PVar "body")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EVar "root")) (arm (PCon "Some" (PVar "binds")) () (EApp (EApp (EVar "ceval") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "body"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "core_ir decision tree: leaf pattern did not match scrutinee"))))))
(DTypeSig false "cevalGuardedArm" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "CTree") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "cevalGuardedArm" ((PVar "env") (PVar "root") (PVar "arms") (PVar "occs") (PVar "i") (PVar "fail")) (EMatch (EApp (EApp (EVar "nthArm") (EVar "arms")) (EVar "i")) (arm (PCon "Some" (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cevalGuardedBody") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "occs")) (EVar "pat")) (EVar "guards")) (EVar "body")) (EVar "fail"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "core_ir decision tree: guarded arm index out of range"))))))
(DTypeSig false "cevalGuardedBody" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyCon "CExpr") (TyFun (TyCon "CTree") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))))))
(DFunDef false "cevalGuardedBody" ((PVar "env") (PVar "root") (PVar "arms") (PVar "occs") (PVar "pat") (PVar "guards") (PVar "body") (PVar "fail")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EVar "root")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "cevalTree") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "occs")) (EVar "fail"))) (arm (PCon "Some" (PVar "binds")) () (EMatch (EApp (EApp (EVar "cevalGuards") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "guards")) (arm (PCon "Some" (PVar "env2")) () (EApp (EApp (EVar "ceval") (EVar "env2")) (EVar "body"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "cevalTree") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "occs")) (EVar "fail")))))))
(DTypeSig false "cevalSwitch" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "CTBranch")) (TyFun (TyCon "CTree") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "cevalSwitch" ((PVar "env") (PVar "root") (PVar "arms") (PList) (PVar "branches") (PVar "dft")) (EApp (EApp (EApp (EApp (EApp (EVar "cevalTree") (EVar "env")) (EVar "root")) (EVar "arms")) (EListLit)) (EVar "dft")))
(DFunDef false "cevalSwitch" ((PVar "env") (PVar "root") (PVar "arms") (PCons (PVar "v") (PVar "rest")) (PVar "branches") (PVar "dft")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cevalSwitchOn") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "v")) (EVar "rest")) (EVar "branches")) (EVar "dft")))
(DTypeSig false "cevalSwitchOn" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "CTBranch")) (TyFun (TyCon "CTree") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))))))
(DFunDef false "cevalSwitchOn" ((PVar "env") (PVar "root") (PVar "arms") PWild (PVar "rest") (PList) (PVar "dft")) (EApp (EApp (EApp (EApp (EApp (EVar "cevalTree") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "rest")) (EVar "dft")))
(DFunDef false "cevalSwitchOn" ((PVar "env") (PVar "root") (PVar "arms") (PVar "v") (PVar "rest") (PCons (PCon "CTBranch" (PVar "head") (PVar "sub")) (PVar "more")) (PVar "dft")) (EMatch (EApp (EApp (EVar "headExtract") (EVar "head")) (EVar "v")) (arm (PCon "Some" (PVar "subs")) () (EApp (EApp (EApp (EApp (EApp (EVar "cevalTree") (EVar "env")) (EVar "root")) (EVar "arms")) (EBinOp "++" (EVar "subs") (EVar "rest"))) (EVar "sub"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cevalSwitchOn") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "v")) (EVar "rest")) (EVar "more")) (EVar "dft")))))
(DTypeSig false "headExtract" (TyFun (TyCon "CHead") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "headExtract" ((PCon "HCon" (PVar "c") (PVar "a")) (PVar "v")) (EApp (EApp (EVar "extractWith") (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EVar "cBinders") (EVar "a")))) (EVar "v")))
(DFunDef false "headExtract" ((PCon "HTuple" (PVar "n")) (PVar "v")) (EApp (EApp (EVar "extractWith") (EApp (EVar "PTuple") (EApp (EVar "cBinders") (EVar "n")))) (EVar "v")))
(DFunDef false "headExtract" ((PCon "HCons") (PVar "v")) (EApp (EApp (EVar "extractWith") (EApp (EApp (EVar "PCons") (EApp (EVar "PVar") (ELit (LString "$d0")))) (EApp (EVar "PVar") (ELit (LString "$d1"))))) (EVar "v")))
(DFunDef false "headExtract" ((PCon "HNil") (PVar "v")) (EApp (EApp (EVar "extractWith") (EApp (EVar "PList") (EListLit))) (EVar "v")))
(DFunDef false "headExtract" ((PCon "HUnit") (PVar "v")) (EApp (EApp (EVar "extractWith") (EApp (EVar "PLit") (EVar "LUnit"))) (EVar "v")))
(DFunDef false "headExtract" ((PCon "HLit" (PVar "l")) (PVar "v")) (EApp (EApp (EVar "extractWith") (EApp (EVar "PLit") (EVar "l"))) (EVar "v")))
(DTypeSig false "extractWith" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "extractWith" ((PVar "p") (PVar "v")) (EApp (EApp (EVar "map") (EApp (EVar "map") (EVar "snd"))) (EApp (EApp (EVar "matchPat") (EVar "p")) (EVar "v"))))
(DTypeSig false "cBinders" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "cBinders" ((PVar "n")) (EApp (EApp (EVar "cBindersGo") (ELit (LInt 0))) (EVar "n")))
(DTypeSig false "cBindersGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "cBindersGo" ((PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "PVar") (EBinOp "++" (ELit (LString "$d")) (EApp (EVar "intToString") (EVar "i")))) (EApp (EApp (EVar "cBindersGo") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "nthArm" (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "CArm")))))
(DFunDef false "nthArm" ((PCons (PVar "a") PWild) (PLit (LInt 0))) (EApp (EVar "Some") (EVar "a")))
(DFunDef false "nthArm" ((PCons PWild (PVar "rest")) (PVar "n")) (EApp (EApp (EVar "nthArm") (EVar "rest")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))))
(DFunDef false "nthArm" ((PList) PWild) (EVar "None"))
(DTypeSig false "cevalRecLet" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalRecLet" ((PVar "env") (PVar "f") (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EVar "VUnit"))) (DoLet false false (PVar "recEnv") (EApp (EApp (EVar "pushFrame") (EVar "env")) (EListLit (ETuple (EVar "f") (EVar "cell"))))) (DoLet false false (PVar "v") (EApp (EApp (EVar "ceval") (EVar "recEnv")) (EVar "e1"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cell")) (EVar "v"))) (DoExpr (EApp (EApp (EVar "ceval") (EVar "recEnv")) (EVar "e2")))))
(DTypeSig false "cevalLet" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Pat") (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalLet" ((PVar "env") (PVar "pat") (PVar "e1") (PVar "e2")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e1"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "let pattern match failure")))) (arm (PCon "Some" (PVar "binds")) () (EApp (EApp (EVar "ceval") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "e2")))))
(DTypeSig false "cevalBlock" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "cevalBlock" (PWild (PList)) (EVar "VUnit"))
(DFunDef false "cevalBlock" ((PVar "env") (PList (PCon "CSExpr" (PVar "e")))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e")))
(DFunDef false "cevalBlock" ((PVar "env") (PList (PCon "CSLet" PWild (PVar "pat") (PVar "e")))) (EApp (EApp (EApp (EVar "cBlockLetLast") (EVar "env")) (EVar "pat")) (EVar "e")))
(DFunDef false "cevalBlock" ((PVar "env") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))) (DoExpr (EApp (EApp (EVar "cevalBlock") (EVar "env")) (EVar "rest")))))
(DFunDef false "cevalBlock" ((PVar "env") (PCons (PCon "CSLet" PWild (PVar "pat") (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "cBlockLet") (EVar "env")) (EVar "pat")) (EVar "e")) (EVar "rest")))
(DFunDef false "cevalBlock" ((PVar "env") (PList (PCon "CSAssign" PWild (PVar "e")))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "cevalBlock" ((PVar "env") (PCons (PCon "CSAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EApp (EApp (EVar "cevalBlock") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EListLit (ETuple (EVar "x") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e")))))) (EVar "rest")))
(DTypeSig false "cBlockLetLast" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Pat") (TyFun (TyCon "CExpr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cBlockLetLast" ((PVar "env") (PVar "pat") (PVar "e")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "let pattern match failure in block")))) (arm (PCon "Some" PWild) () (EVar "VUnit"))))
(DTypeSig false "cBlockLet" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Pat") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cBlockLet" ((PVar "env") (PVar "pat") (PVar "e") (PVar "rest")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "let pattern match failure in block")))) (arm (PCon "Some" (PVar "binds")) () (EApp (EApp (EVar "cevalBlock") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "rest")))))
(DTypeSig false "cevalLetGroup" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "CExpr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cevalLetGroup" ((PVar "env") (PVar "binds") (PVar "body")) (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EVar "map") (EVar "cBindCell")) (EVar "binds"))) (DoLet false false (PVar "env2") (EApp (EApp (EVar "pushFrame") (EVar "env")) (EVar "cells"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "cInstallGroup") (EVar "env2")) (EVar "cells")) (EVar "binds"))) (DoExpr (EApp (EApp (EVar "ceval") (EVar "env2")) (EVar "body")))))
(DTypeSig false "cBindCell" (TyFun (TyCon "CBind") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "cBindCell" ((PCon "CBind" (PVar "name") PWild)) (ETuple (EVar "name") (EApp (EVar "Ref") (EVar "VUnit"))))
(DTypeSig false "cInstallGroup" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyEffect () (Some "e") (TyCon "Unit"))))))
(DFunDef false "cInstallGroup" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "cInstallGroup" ((PVar "env") (PVar "cells") (PCons (PCon "CBind" (PVar "name") (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EApp (EApp (EVar "findCell") (EVar "cells")) (EVar "name"))) (EApp (EApp (EVar "cGroupValue") (EVar "env")) (EVar "clauses")))) (DoExpr (EApp (EApp (EApp (EVar "cInstallGroup") (EVar "env")) (EVar "cells")) (EVar "rest")))))
(DTypeSig false "cGroupValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "cGroupValue" ((PVar "env") (PList (PCon "CClause" (PVar "pats") (PVar "body")))) (EIf (EApp (EVar "isNullary") (EVar "pats")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "body")) (EIf (EVar "otherwise") (EApp (EApp (EVar "cClauseClosure") (EVar "env")) (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "body"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "cGroupValue" ((PVar "env") (PVar "clauses")) (EApp (EVar "VMulti") (EApp (EApp (EVar "map") (EApp (EVar "cClauseClosure") (EVar "env"))) (EVar "clauses"))))
(DTypeSig false "cClauseClosure" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "CClause") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "cClauseClosure" ((PVar "env") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "VClosureF") (EVar "env")) (EVar "pats")) (ELam ((PVar "e")) (EApp (EApp (EVar "ceval") (EVar "e")) (EVar "body")))))
(DTypeSig true "cevalProgram" (TyFun (TyCon "CProgram") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cevalProgram" ((PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorToType") (PVar "implEntries"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "ctorToTypeRef")) (EVar "ctorToType"))) (DoLet false false (PVar "ctors") (EApp (EApp (EVar "map") (EVar "ctorBinding")) (EVar "ctorArs"))) (DoLet false false (PVar "allNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "boolSeeds")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "externBindings") (ELit LUnit)))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "ctors"))) (EApp (EApp (EVar "map") (EVar "cBindName")) (EVar "groups"))) (EApp (EVar "cImplMethodNames") (EVar "implEntries")))) (DoLet false false (PVar "cells") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "Ref") (EVar "VUnit"))))) (EVar "allNames"))) (DoLet false false (PVar "env") (EApp (EVar "EvalEnv") (EListLit (EVar "cells")))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "cells")) (EVar "boolSeeds"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "cells")) (EApp (EVar "externBindings") (ELit LUnit)))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "cells")) (EVar "ctors"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "cells")) (EApp (EVar "coalesceImpls") (EApp (EApp (EVar "map") (EApp (EVar "cImplEntryValue") (EVar "env"))) (EVar "implEntries"))))) (DoLet false false PWild (EApp (EApp (EApp (EVar "cInstallTopGroups") (EVar "env")) (EVar "cells")) (EVar "groups"))) (DoExpr (EApp (EApp (EVar "map") (EVar "cellResult")) (EVar "cells")))))
(DTypeSig false "ctorBinding" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "ctorBinding" ((PTuple (PVar "name") (PVar "arity"))) (ETuple (EVar "name") (EApp (EApp (EVar "makeCtor") (EVar "name")) (EVar "arity"))))
(DTypeSig false "cImplMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "cImplMethodNames" ((PVar "entries")) (EApp (EVar "dedup") (EApp (EApp (EVar "map") (EVar "cImplEntryName")) (EVar "entries"))))
(DTypeSig false "cImplEntryName" (TyFun (TyCon "CImplEntry") (TyCon "String")))
(DFunDef false "cImplEntryName" ((PCon "CImplEntry" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "cImplEntryValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "CImplEntry") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cImplEntryValue" ((PVar "env") (PCon "CImplEntry" (PVar "name") (PVar "score") (PVar "body"))) (ETuple (EVar "name") (ETuple (EVar "score") (EApp (EApp (EVar "cImplBodyValue") (EVar "env")) (EVar "body")))))
(DTypeSig false "cImplBodyValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "CImplBody") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "cImplBodyValue" ((PVar "env") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "positions") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EVar "VTypedImpl") (EVar "tag")) (EVar "key")) (EVar "positions")) (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "cImplMethodValue") (EVar "env")) (EVar "positions")) (EVar "pats")) (EVar "body"))))
(DFunDef false "cImplBodyValue" ((PVar "env") (PCon "CImplDefault" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "cImplMethodValue") (EVar "env")) (EListLit)) (EVar "pats")) (EVar "body")))
(DTypeSig false "cImplMethodValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "CExpr") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cImplMethodValue" ((PVar "env") (PVar "positions") (PList) (PVar "body")) (EIf (EApp (EVar "isEmptyL") (EVar "positions")) (EApp (EVar "VThunk") (ELam (PWild) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "body")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "VClosureF") (EVar "env")) (EListLit (EApp (EVar "PVar") (ELit (LString "$eta"))))) (ELam ((PVar "e")) (EApp (EApp (EVar "ceval") (EVar "e")) (EApp (EApp (EVar "CApp") (EVar "body")) (EApp (EApp (EVar "CVar") (ELit (LString "$eta"))) (EVar "AGlobal")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "cImplMethodValue" ((PVar "env") PWild (PVar "pats") (PVar "body")) (EApp (EApp (EApp (EVar "VClosureF") (EVar "env")) (EVar "pats")) (ELam ((PVar "e")) (EApp (EApp (EVar "ceval") (EVar "e")) (EVar "body")))))
(DTypeSig false "cBindName" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "cBindName" ((PCon "CBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "cInstallTopGroups" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyEffect () (Some "e") (TyCon "Unit"))))))
(DFunDef false "cInstallTopGroups" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "cInstallTopGroups" ((PVar "env") (PVar "cells") (PCons (PCon "CBind" (PVar "n") (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EApp (EApp (EVar "findCell") (EVar "cells")) (EVar "n"))) (EApp (EApp (EVar "cTopGroupValue") (EVar "env")) (EVar "clauses")))) (DoExpr (EApp (EApp (EApp (EVar "cInstallTopGroups") (EVar "env")) (EVar "cells")) (EVar "rest")))))
(DTypeSig false "cTopGroupValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "cTopGroupValue" ((PVar "env") (PList (PCon "CClause" (PVar "pats") (PVar "body")))) (EIf (EApp (EVar "isNullary") (EVar "pats")) (EApp (EVar "VThunk") (ELam (PWild) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "body")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "VClosureF") (EVar "env")) (EVar "pats")) (ELam ((PVar "e")) (EApp (EApp (EVar "ceval") (EVar "e")) (EVar "body")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "cTopGroupValue" ((PVar "env") (PVar "clauses")) (EApp (EVar "VMulti") (EApp (EApp (EVar "map") (EApp (EVar "cClauseClosure") (EVar "env"))) (EVar "clauses"))))
(DTypeSig true "cevalMain" (TyFun (TyCon "CProgram") (TyCon "String")))
(DFunDef false "cevalMain" ((PVar "prog")) (EMatch (EApp (EApp (EVar "lookupBinding") (ELit (LString "main"))) (EApp (EVar "cevalProgram") (EVar "prog"))) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "ppValue") (EApp (EVar "force") (EVar "v")))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "core_ir eval: no `main` binding"))))))
(DTypeSig true "cevalOutput" (TyFun (TyCon "CProgram") (TyCon "String")))
(DFunDef false "cevalOutput" ((PVar "prog")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false (PVar "binds") (EApp (EVar "cevalProgram") (EVar "prog"))) (DoLet false false PWild (EApp (EVar "cRunMainForEffect") (EVar "binds"))) (DoExpr (EFieldAccess (EVar "outputRef") "value"))))
(DTypeSig false "cRunMainForEffect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "cRunMainForEffect" ((PVar "binds")) (EMatch (EApp (EApp (EVar "lookupBinding") (ELit (LString "main"))) (EVar "binds")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "force") (EVar "v"))) (arm (PCon "None") () (EVar "VUnit"))))
(DData Private "CModInfo" ("v") ((variant "CModInfo" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyVar "v")))) (TyApp (TyCon "EvalEnv") (TyVar "v"))))) ())
(DTypeSig true "cevalModules" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalModules" ((PVar "preludeDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "moduleDecls") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modules"))) (DoLet false false (PVar "allDecls") (EBinOp "++" (EVar "preludeDecls") (EVar "moduleDecls"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "ctorToTypeRef")) (EApp (EVar "buildCtorToType") (EVar "allDecls")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "ctorFieldOrdersRef")) (EApp (EVar "buildCtorFieldOrders") (EVar "allDecls")))) (DoLet false false (PVar "disp") (EApp (EVar "buildIfaceDispatch") (EVar "allDecls"))) (DoLet false false (PVar "ctors") (EApp (EVar "collectCtors") (EVar "allDecls"))) (DoLet false false (PVar "preludeGroups") (EApp (EVar "lowerGroups") (EVar "preludeDecls"))) (DoLet false false (PVar "preludeImpls") (EApp (EApp (EVar "lowerImplsWith") (EVar "disp")) (EVar "preludeDecls"))) (DoLet false false (PVar "globalNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "boolSeeds")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "externBindings") (ELit LUnit)))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "ctors"))) (EApp (EVar "implMethodNames") (EVar "allDecls"))) (EApp (EApp (EVar "map") (EVar "cBindName")) (EVar "preludeGroups")))) (DoLet false false (PVar "globalCells") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "Ref") (EVar "VUnit"))))) (EVar "globalNames"))) (DoLet false false (PVar "globalEnv") (EApp (EVar "EvalEnv") (EListLit (EVar "globalCells")))) (DoLet false false (PVar "mods") (EApp (EApp (EApp (EApp (EVar "cBuildModInfos") (EVar "disp")) (EVar "globalCells")) (EListLit)) (EVar "modules"))) (DoLet false false (PVar "implEntries") (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "cImplEntryValue") (EVar "globalEnv"))) (EVar "preludeImpls")) (EApp (EApp (EVar "flatMap") (EVar "cModImplValues")) (EVar "mods")))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "boolSeeds"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EApp (EVar "externBindings") (ELit LUnit)))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "ctors"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EApp (EVar "coalesceImpls") (EVar "implEntries")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "cInstallTopGroups") (EVar "globalEnv")) (EVar "globalCells")) (EVar "preludeGroups"))) (DoLet false false PWild (EApp (EVar "cInstallModGroups") (EVar "mods"))) (DoExpr (EApp (EVar "cRootLocals") (EVar "mods")))))
(DTypeSig false "cBuildModInfos" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyApp (TyCon "CModInfo") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "cBuildModInfos" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "cBuildModInfos" ((PVar "disp") (PVar "globalCells") (PVar "exportsMap") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EBlock (DoLet false false (PVar "cbinds") (EApp (EVar "lowerGroups") (EVar "decls"))) (DoLet false false (PVar "cimpls") (EApp (EApp (EVar "lowerImplsWith") (EVar "disp")) (EVar "decls"))) (DoLet false false (PVar "modCtors") (EApp (EVar "collectCtors") (EVar "decls"))) (DoLet false false (PVar "localCells") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "Ref") (EVar "VUnit"))))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "cBindName")) (EVar "cbinds")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "modCtors"))))) (DoLet false false (PVar "imports") (EApp (EApp (EVar "importFrameOf") (EVar "exportsMap")) (EVar "decls"))) (DoLet false false (PVar "menv") (EApp (EVar "EvalEnv") (EListLit (EVar "localCells") (EVar "imports") (EVar "globalCells")))) (DoLet false false (PVar "exports") (EBinOp "++" (EBinOp "++" (EVar "localCells") (EApp (EApp (EVar "methodCellsOf") (EVar "globalCells")) (EVar "decls"))) (EApp (EApp (EApp (EVar "pubReexports") (EVar "globalCells")) (EVar "exportsMap")) (EVar "decls")))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CModInfo") (EVar "mid")) (EVar "decls")) (EVar "cbinds")) (EVar "cimpls")) (EVar "localCells")) (EVar "menv")) (EApp (EApp (EApp (EApp (EVar "cBuildModInfos") (EVar "disp")) (EVar "globalCells")) (EBinOp "::" (ETuple (EVar "mid") (EVar "exports")) (EVar "exportsMap"))) (EVar "rest"))))))
(DTypeSig false "cModImplValues" (TyFun (TyApp (TyCon "CModInfo") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cModImplValues" ((PCon "CModInfo" PWild PWild PWild (PVar "cimpls") PWild (PVar "menv"))) (EApp (EApp (EVar "map") (EApp (EVar "cImplEntryValue") (EVar "menv"))) (EVar "cimpls")))
(DTypeSig false "cInstallModGroups" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "CModInfo") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyCon "Unit"))))
(DFunDef false "cInstallModGroups" ((PList)) (ELit LUnit))
(DFunDef false "cInstallModGroups" ((PCons (PCon "CModInfo" PWild (PVar "decls") (PVar "cbinds") PWild (PVar "cells") (PVar "menv")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "cInstallTopGroups") (EVar "menv")) (EVar "cells")) (EVar "cbinds"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "cells")) (EApp (EVar "collectCtors") (EVar "decls")))) (DoExpr (EApp (EVar "cInstallModGroups") (EVar "rest")))))
(DTypeSig false "cRootLocals" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "CModInfo") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cRootLocals" ((PList)) (EListLit))
(DFunDef false "cRootLocals" ((PList (PCon "CModInfo" PWild PWild PWild PWild (PVar "cells") PWild))) (EApp (EApp (EVar "map") (EVar "cellResult")) (EVar "cells")))
(DFunDef false "cRootLocals" ((PCons PWild (PVar "rest"))) (EApp (EVar "cRootLocals") (EVar "rest")))
(DTypeSig true "cevalModulesOutput" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))
(DFunDef false "cevalModulesOutput" ((PVar "preludeDecls") (PVar "modules")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false (PVar "binds") (EApp (EApp (EVar "cevalModules") (EVar "preludeDecls")) (EVar "modules"))) (DoLet false false PWild (EApp (EVar "cRunMainForEffect") (EVar "binds"))) (DoExpr (EFieldAccess (EVar "outputRef") "value"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true) (mem "Addr" true) (mem "Route" true) (mem "Decl" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CProgram" true) (mem "CTree" true) (mem "CTBranch" true) (mem "CHead" true))))
(DUse false (UseGroup ("ir" "core_ir_lower") ((mem "lowerGroups" false) (mem "lowerImplsWith" false))))
(DUse false (UseGroup ("support" "util") ((mem "isEmptyL" false) (mem "dedup" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "EvalEnv" true) (mem "lookupEnv" false) (mem "extendEnv" false) (mem "pushFrame" false) (mem "findCell" false) (mem "applyValue" false) (mem "matchPat" false) (mem "force" false) (mem "startsWithAt" false) (mem "evalArith" false) (mem "evalUnop" false) (mem "consVal" false) (mem "appendVal" false) (mem "makeCtor" false) (mem "boolSeeds" false) (mem "externBindings" false) (mem "ctorToTypeRef" false) (mem "installConsts" false) (mem "cellResult" false) (mem "lookupBinding" false) (mem "isNullary" false) (mem "ppValue" false) (mem "outputRef" false) (mem "evalIndex" false) (mem "evalSlice" false) (mem "evalRange" false) (mem "rangeListMk" false) (mem "rangeArrayMk" false) (mem "evalRecordUpdate" false) (mem "evalValueField" false) (mem "evalField" false) (mem "narrowMethod" false) (mem "routeTag" false) (mem "applyDicts" false) (mem "applyMethodDicts" false) (mem "coalesceImpls" false) (mem "buildCtorToType" false) (mem "collectCtors" false) (mem "buildIfaceDispatch" false) (mem "implMethodNames" false) (mem "methodCellsOf" false) (mem "importFrameOf" false) (mem "pubReexports" false) (mem "evalVariantUpdate" false) (mem "buildCtorFieldOrders" false) (mem "ctorFieldOrdersRef" false) (mem "methodAtNarrow" false) (mem "applyValues" false))))
(DTypeSig true "ceval" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "CExpr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "ceval" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "litValue") (EVar "l")))
(DFunDef false "ceval" ((PVar "env") (PCon "CVar" (PVar "x") PWild)) (EIf (EApp (EVar "startsWithAt") (EVar "x")) (EVar "VUnit") (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "x"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "applyValue") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "f"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "x"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "VClosureF") (EVar "env")) (EVar "pats")) (ELam ((PVar "e")) (EApp (EApp (EVar "ceval") (EVar "e")) (EVar "body")))))
(DFunDef false "ceval" ((PVar "env") (PCon "CLet" (PCon "True") (PCon "PVar" (PVar "f")) (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "cevalRecLet") (EVar "env")) (EVar "f")) (EVar "e1")) (EVar "e2")))
(DFunDef false "ceval" ((PVar "env") (PCon "CLet" PWild (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "cevalLet") (EVar "env")) (EVar "pat")) (EVar "e1")) (EVar "e2")))
(DFunDef false "ceval" ((PVar "env") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EVar "cevalLetGroup") (EVar "env")) (EVar "binds")) (EVar "body")))
(DFunDef false "ceval" ((PVar "env") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EVar "cevalMatch") (EVar "env")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "ceval" ((PVar "env") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EApp (EVar "cevalDecision") (EVar "env")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "scrut"))) (EVar "arms")) (EVar "tree")))
(DFunDef false "ceval" ((PVar "env") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "cevalIf") (EVar "env")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "c"))) (EVar "t")) (EVar "e")))
(DFunDef false "ceval" ((PVar "env") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") PWild)) (EApp (EApp (EApp (EVar "cevalBinPrim") (EVar "op")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "l"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "r"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CUnOp" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "evalUnop") (EVar "op")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CTuple" (PVar "es"))) (EApp (EVar "VTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "ceval") (EVar "env"))) (EVar "es"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CList" (PVar "es"))) (EApp (EVar "VList") (EApp (EApp (EMethodRef "map") (EApp (EVar "ceval") (EVar "env"))) (EVar "es"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "cevalBlock") (EVar "env")) (EVar "stmts")))
(DFunDef false "ceval" ((PVar "env") (PCon "CArray" (PVar "es"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EApp (EVar "ceval") (EVar "env"))) (EVar "es")))))
(DFunDef false "ceval" ((PVar "env") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "VRecord") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "cevalField") (EVar "env"))) (EVar "fields"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields"))) (EApp (EApp (EVar "evalRecordUpdate") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "cevalField") (EVar "env"))) (EVar "fields"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "evalVariantUpdate") (EVar "con")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "cevalField") (EVar "env"))) (EVar "fields"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CFieldAccess" (PVar "e") (PLit (LString "value")) PWild)) (EApp (EVar "evalValueField") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CFieldAccess" (PVar "e") (PVar "field") PWild)) (EApp (EApp (EVar "evalField") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))) (EVar "field")))
(DFunDef false "ceval" ((PVar "env") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "evalIndex") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "i"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "evalSlice") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "ceval" ((PVar "env") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "evalIndex") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "i"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "evalSlice") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "ceval" ((PVar "env") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "evalIndex") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "i"))))
(DFunDef false "ceval" ((PVar "env") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "evalSlice") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "ceval" ((PVar "env") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "evalRange") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "hi"))) (EVar "incl")) (EVar "rangeListMk")))
(DFunDef false "ceval" ((PVar "env") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "evalRange") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "hi"))) (EVar "incl")) (EVar "rangeArrayMk")))
(DFunDef false "ceval" ((PVar "env") (PCon "CMethod" (PVar "name") (PVar "route") (PVar "implRoutes") (PVar "methRoutes"))) (EBlock (DoLet false false (PTuple (PVar "narrowed") (PVar "fwdReqs")) (EApp (EApp (EApp (EVar "methodAtNarrow") (EVar "env")) (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "name"))) (EVar "route"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyMethodDicts") (EVar "env")) (EVar "name")) (EVar "route")) (EVar "narrowed")) (EVar "fwdReqs")) (EVar "implRoutes")) (EVar "methRoutes")))))
(DFunDef false "ceval" ((PVar "env") (PCon "CDict" (PVar "name") (PVar "routes"))) (EApp (EApp (EApp (EVar "applyDicts") (EVar "env")) (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "name"))) (EVar "routes")))
(DFunDef false "ceval" (PWild PWild) (EApp (EVar "panic") (ELit (LString "core_ir ceval: unsupported node"))))
(DTypeSig false "cevalField" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "CField") (TyEffect () (Some "e") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cevalField" ((PVar "env") (PCon "CField" (PVar "k") (PVar "e"))) (ETuple (EVar "k") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))))
(DTypeSig false "litValue" (TyFun (TyCon "Lit") (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "litValue" ((PCon "LInt" (PVar "n"))) (EApp (EVar "VInt") (EVar "n")))
(DFunDef false "litValue" ((PCon "LFloat" (PVar "f"))) (EApp (EVar "VFloat") (EVar "f")))
(DFunDef false "litValue" ((PCon "LString" (PVar "s"))) (EApp (EVar "VString") (EVar "s")))
(DFunDef false "litValue" ((PCon "LChar" (PVar "c"))) (EApp (EVar "VChar") (EVar "c")))
(DFunDef false "litValue" ((PCon "LBool" (PVar "b"))) (EApp (EVar "VBool") (EVar "b")))
(DFunDef false "litValue" ((PCon "LUnit")) (EVar "VUnit"))
(DTypeSig false "cevalBinPrim" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "cevalBinPrim" ((PLit (LString "::")) (PVar "l") (PVar "r")) (EApp (EApp (EVar "consVal") (EVar "l")) (EVar "r")))
(DFunDef false "cevalBinPrim" ((PLit (LString "++")) (PVar "l") (PVar "r")) (EApp (EApp (EVar "appendVal") (EVar "l")) (EVar "r")))
(DFunDef false "cevalBinPrim" ((PVar "op") (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "evalArith") (EVar "op")) (EVar "l")) (EVar "r")))
(DTypeSig false "cevalIf" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalIf" ((PVar "env") (PCon "VBool" (PCon "True")) (PVar "t") PWild) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "t")))
(DFunDef false "cevalIf" ((PVar "env") (PCon "VCon" (PLit (LString "True")) (PList)) (PVar "t") PWild) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "t")))
(DFunDef false "cevalIf" ((PVar "env") (PCon "VBool" (PCon "False")) PWild (PVar "e")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e")))
(DFunDef false "cevalIf" ((PVar "env") (PCon "VCon" (PLit (LString "False")) (PList)) PWild (PVar "e")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e")))
(DFunDef false "cevalIf" (PWild PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "if condition is not a Bool"))))
(DTypeSig false "cevalMatch" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cevalMatch" (PWild PWild (PList)) (EApp (EVar "panic") (ELit (LString "no matching clause in match"))))
(DFunDef false "cevalMatch" ((PVar "env") (PVar "sv") (PCons (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EVar "sv")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "cevalMatch") (EVar "env")) (EVar "sv")) (EVar "rest"))) (arm (PCon "Some" (PVar "binds")) () (EMatch (EApp (EApp (EVar "cevalGuards") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "guards")) (arm (PCon "Some" (PVar "env2")) () (EApp (EApp (EVar "ceval") (EVar "env2")) (EVar "body"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "cevalMatch") (EVar "env")) (EVar "sv")) (EVar "rest")))))))
(DTypeSig false "cevalGuards" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalGuards" ((PVar "env") (PList)) (EApp (EVar "Some") (EVar "env")))
(DFunDef false "cevalGuards" ((PVar "env") (PCons (PCon "CGBool" (PVar "g")) (PVar "qs"))) (EMatch (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "g")) (arm (PCon "VBool" (PCon "True")) () (EApp (EApp (EVar "cevalGuards") (EVar "env")) (EVar "qs"))) (arm (PCon "VCon" (PLit (LString "True")) (PList)) () (EApp (EApp (EVar "cevalGuards") (EVar "env")) (EVar "qs"))) (arm PWild () (EVar "None"))))
(DFunDef false "cevalGuards" ((PVar "env") (PCons (PCon "CGBind" (PVar "p") (PVar "e")) (PVar "qs"))) (EMatch (EApp (EApp (EVar "matchPat") (EVar "p")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "cevalGuards") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "b"))) (EVar "qs"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "cevalDecision" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "CTree") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalDecision" ((PVar "env") (PVar "root") (PVar "arms") (PVar "tree")) (EApp (EApp (EApp (EApp (EApp (EVar "cevalTree") (EVar "env")) (EVar "root")) (EVar "arms")) (EListLit (EVar "root"))) (EVar "tree")))
(DTypeSig false "cevalTree" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "CTree") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "cevalTree" (PWild PWild PWild PWild (PCon "CTFail")) (EApp (EVar "panic") (ELit (LString "no matching clause in match"))))
(DFunDef false "cevalTree" ((PVar "env") (PVar "root") (PVar "arms") PWild (PCon "CTLeaf" (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "cevalArm") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "i")))
(DFunDef false "cevalTree" ((PVar "env") (PVar "root") (PVar "arms") (PVar "occs") (PCon "CTGuard" (PVar "i") (PVar "fail"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cevalGuardedArm") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "occs")) (EVar "i")) (EVar "fail")))
(DFunDef false "cevalTree" ((PVar "env") (PVar "root") (PVar "arms") (PVar "occs") (PCon "CTDrop" (PVar "sub"))) (EApp (EApp (EApp (EApp (EApp (EVar "cevalTree") (EVar "env")) (EVar "root")) (EVar "arms")) (EApp (EVar "cOccsTail") (EVar "occs"))) (EMethodRef "sub")))
(DFunDef false "cevalTree" ((PVar "env") (PVar "root") (PVar "arms") (PVar "occs") (PCon "CTSwitch" (PVar "branches") (PVar "dft"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cevalSwitch") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "occs")) (EVar "branches")) (EVar "dft")))
(DTypeSig false "cOccsTail" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "cOccsTail" ((PList)) (EListLit))
(DFunDef false "cOccsTail" ((PCons PWild (PVar "xs"))) (EVar "xs"))
(DTypeSig false "cevalArm" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalArm" ((PVar "env") (PVar "root") (PVar "arms") (PVar "i")) (EMatch (EApp (EApp (EVar "nthArm") (EVar "arms")) (EVar "i")) (arm (PCon "Some" (PCon "CArm" (PVar "pat") PWild (PVar "body"))) () (EApp (EApp (EApp (EApp (EVar "cevalArmBody") (EVar "env")) (EVar "root")) (EVar "pat")) (EVar "body"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "core_ir decision tree: arm index out of range"))))))
(DTypeSig false "cevalArmBody" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Pat") (TyFun (TyCon "CExpr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalArmBody" ((PVar "env") (PVar "root") (PVar "pat") (PVar "body")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EVar "root")) (arm (PCon "Some" (PVar "binds")) () (EApp (EApp (EVar "ceval") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "body"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "core_ir decision tree: leaf pattern did not match scrutinee"))))))
(DTypeSig false "cevalGuardedArm" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "CTree") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "cevalGuardedArm" ((PVar "env") (PVar "root") (PVar "arms") (PVar "occs") (PVar "i") (PVar "fail")) (EMatch (EApp (EApp (EVar "nthArm") (EVar "arms")) (EVar "i")) (arm (PCon "Some" (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cevalGuardedBody") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "occs")) (EVar "pat")) (EVar "guards")) (EVar "body")) (EVar "fail"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "core_ir decision tree: guarded arm index out of range"))))))
(DTypeSig false "cevalGuardedBody" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyCon "CExpr") (TyFun (TyCon "CTree") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))))))
(DFunDef false "cevalGuardedBody" ((PVar "env") (PVar "root") (PVar "arms") (PVar "occs") (PVar "pat") (PVar "guards") (PVar "body") (PVar "fail")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EVar "root")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "cevalTree") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "occs")) (EVar "fail"))) (arm (PCon "Some" (PVar "binds")) () (EMatch (EApp (EApp (EVar "cevalGuards") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "guards")) (arm (PCon "Some" (PVar "env2")) () (EApp (EApp (EVar "ceval") (EVar "env2")) (EVar "body"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "cevalTree") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "occs")) (EVar "fail")))))))
(DTypeSig false "cevalSwitch" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "CTBranch")) (TyFun (TyCon "CTree") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "cevalSwitch" ((PVar "env") (PVar "root") (PVar "arms") (PList) (PVar "branches") (PVar "dft")) (EApp (EApp (EApp (EApp (EApp (EVar "cevalTree") (EVar "env")) (EVar "root")) (EVar "arms")) (EListLit)) (EVar "dft")))
(DFunDef false "cevalSwitch" ((PVar "env") (PVar "root") (PVar "arms") (PCons (PVar "v") (PVar "rest")) (PVar "branches") (PVar "dft")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cevalSwitchOn") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "v")) (EVar "rest")) (EVar "branches")) (EVar "dft")))
(DTypeSig false "cevalSwitchOn" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "CTBranch")) (TyFun (TyCon "CTree") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))))))
(DFunDef false "cevalSwitchOn" ((PVar "env") (PVar "root") (PVar "arms") PWild (PVar "rest") (PList) (PVar "dft")) (EApp (EApp (EApp (EApp (EApp (EVar "cevalTree") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "rest")) (EVar "dft")))
(DFunDef false "cevalSwitchOn" ((PVar "env") (PVar "root") (PVar "arms") (PVar "v") (PVar "rest") (PCons (PCon "CTBranch" (PVar "head") (PVar "sub")) (PVar "more")) (PVar "dft")) (EMatch (EApp (EApp (EVar "headExtract") (EVar "head")) (EVar "v")) (arm (PCon "Some" (PVar "subs")) () (EApp (EApp (EApp (EApp (EApp (EVar "cevalTree") (EVar "env")) (EVar "root")) (EVar "arms")) (EBinOp "++" (EVar "subs") (EVar "rest"))) (EMethodRef "sub"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "cevalSwitchOn") (EVar "env")) (EVar "root")) (EVar "arms")) (EVar "v")) (EVar "rest")) (EVar "more")) (EVar "dft")))))
(DTypeSig false "headExtract" (TyFun (TyCon "CHead") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "headExtract" ((PCon "HCon" (PVar "c") (PVar "a")) (PVar "v")) (EApp (EApp (EVar "extractWith") (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EVar "cBinders") (EVar "a")))) (EVar "v")))
(DFunDef false "headExtract" ((PCon "HTuple" (PVar "n")) (PVar "v")) (EApp (EApp (EVar "extractWith") (EApp (EVar "PTuple") (EApp (EVar "cBinders") (EVar "n")))) (EVar "v")))
(DFunDef false "headExtract" ((PCon "HCons") (PVar "v")) (EApp (EApp (EVar "extractWith") (EApp (EApp (EVar "PCons") (EApp (EVar "PVar") (ELit (LString "$d0")))) (EApp (EVar "PVar") (ELit (LString "$d1"))))) (EVar "v")))
(DFunDef false "headExtract" ((PCon "HNil") (PVar "v")) (EApp (EApp (EVar "extractWith") (EApp (EVar "PList") (EListLit))) (EVar "v")))
(DFunDef false "headExtract" ((PCon "HUnit") (PVar "v")) (EApp (EApp (EVar "extractWith") (EApp (EVar "PLit") (EVar "LUnit"))) (EVar "v")))
(DFunDef false "headExtract" ((PCon "HLit" (PVar "l")) (PVar "v")) (EApp (EApp (EVar "extractWith") (EApp (EVar "PLit") (EVar "l"))) (EVar "v")))
(DTypeSig false "extractWith" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "extractWith" ((PVar "p") (PVar "v")) (EApp (EApp (EMethodRef "map") (EApp (EMethodRef "map") (EVar "snd"))) (EApp (EApp (EVar "matchPat") (EVar "p")) (EVar "v"))))
(DTypeSig false "cBinders" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "cBinders" ((PVar "n")) (EApp (EApp (EVar "cBindersGo") (ELit (LInt 0))) (EVar "n")))
(DTypeSig false "cBindersGo" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "cBindersGo" ((PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "PVar") (EBinOp "++" (ELit (LString "$d")) (EApp (EVar "intToString") (EVar "i")))) (EApp (EApp (EVar "cBindersGo") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "nthArm" (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "CArm")))))
(DFunDef false "nthArm" ((PCons (PVar "a") PWild) (PLit (LInt 0))) (EApp (EVar "Some") (EVar "a")))
(DFunDef false "nthArm" ((PCons PWild (PVar "rest")) (PVar "n")) (EApp (EApp (EVar "nthArm") (EVar "rest")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))))
(DFunDef false "nthArm" ((PList) PWild) (EVar "None"))
(DTypeSig false "cevalRecLet" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalRecLet" ((PVar "env") (PVar "f") (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EVar "VUnit"))) (DoLet false false (PVar "recEnv") (EApp (EApp (EVar "pushFrame") (EVar "env")) (EListLit (ETuple (EVar "f") (EVar "cell"))))) (DoLet false false (PVar "v") (EApp (EApp (EVar "ceval") (EVar "recEnv")) (EVar "e1"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cell")) (EVar "v"))) (DoExpr (EApp (EApp (EVar "ceval") (EVar "recEnv")) (EVar "e2")))))
(DTypeSig false "cevalLet" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Pat") (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalLet" ((PVar "env") (PVar "pat") (PVar "e1") (PVar "e2")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e1"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "let pattern match failure")))) (arm (PCon "Some" (PVar "binds")) () (EApp (EApp (EVar "ceval") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "e2")))))
(DTypeSig false "cevalBlock" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "cevalBlock" (PWild (PList)) (EVar "VUnit"))
(DFunDef false "cevalBlock" ((PVar "env") (PList (PCon "CSExpr" (PVar "e")))) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e")))
(DFunDef false "cevalBlock" ((PVar "env") (PList (PCon "CSLet" PWild (PVar "pat") (PVar "e")))) (EApp (EApp (EApp (EVar "cBlockLetLast") (EVar "env")) (EVar "pat")) (EVar "e")))
(DFunDef false "cevalBlock" ((PVar "env") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))) (DoExpr (EApp (EApp (EVar "cevalBlock") (EVar "env")) (EVar "rest")))))
(DFunDef false "cevalBlock" ((PVar "env") (PCons (PCon "CSLet" PWild (PVar "pat") (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "cBlockLet") (EVar "env")) (EVar "pat")) (EVar "e")) (EVar "rest")))
(DFunDef false "cevalBlock" ((PVar "env") (PList (PCon "CSAssign" PWild (PVar "e")))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "cevalBlock" ((PVar "env") (PCons (PCon "CSAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EApp (EApp (EVar "cevalBlock") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EListLit (ETuple (EVar "x") (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e")))))) (EVar "rest")))
(DTypeSig false "cBlockLetLast" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Pat") (TyFun (TyCon "CExpr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cBlockLetLast" ((PVar "env") (PVar "pat") (PVar "e")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "let pattern match failure in block")))) (arm (PCon "Some" PWild) () (EVar "VUnit"))))
(DTypeSig false "cBlockLet" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Pat") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cBlockLet" ((PVar "env") (PVar "pat") (PVar "e") (PVar "rest")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "e"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "let pattern match failure in block")))) (arm (PCon "Some" (PVar "binds")) () (EApp (EApp (EVar "cevalBlock") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "rest")))))
(DTypeSig false "cevalLetGroup" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "CExpr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cevalLetGroup" ((PVar "env") (PVar "binds") (PVar "body")) (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EMethodRef "map") (EVar "cBindCell")) (EVar "binds"))) (DoLet false false (PVar "env2") (EApp (EApp (EVar "pushFrame") (EVar "env")) (EVar "cells"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "cInstallGroup") (EVar "env2")) (EVar "cells")) (EVar "binds"))) (DoExpr (EApp (EApp (EVar "ceval") (EVar "env2")) (EVar "body")))))
(DTypeSig false "cBindCell" (TyFun (TyCon "CBind") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "cBindCell" ((PCon "CBind" (PVar "name") PWild)) (ETuple (EVar "name") (EApp (EVar "Ref") (EVar "VUnit"))))
(DTypeSig false "cInstallGroup" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyEffect () (Some "e") (TyCon "Unit"))))))
(DFunDef false "cInstallGroup" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "cInstallGroup" ((PVar "env") (PVar "cells") (PCons (PCon "CBind" (PVar "name") (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EApp (EApp (EVar "findCell") (EVar "cells")) (EVar "name"))) (EApp (EApp (EVar "cGroupValue") (EVar "env")) (EVar "clauses")))) (DoExpr (EApp (EApp (EApp (EVar "cInstallGroup") (EVar "env")) (EVar "cells")) (EVar "rest")))))
(DTypeSig false "cGroupValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "cGroupValue" ((PVar "env") (PList (PCon "CClause" (PVar "pats") (PVar "body")))) (EIf (EApp (EVar "isNullary") (EVar "pats")) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "body")) (EIf (EVar "otherwise") (EApp (EApp (EVar "cClauseClosure") (EVar "env")) (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "body"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "cGroupValue" ((PVar "env") (PVar "clauses")) (EApp (EVar "VMulti") (EApp (EApp (EMethodRef "map") (EApp (EVar "cClauseClosure") (EVar "env"))) (EVar "clauses"))))
(DTypeSig false "cClauseClosure" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "CClause") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "cClauseClosure" ((PVar "env") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "VClosureF") (EVar "env")) (EVar "pats")) (ELam ((PVar "e")) (EApp (EApp (EVar "ceval") (EVar "e")) (EVar "body")))))
(DTypeSig true "cevalProgram" (TyFun (TyCon "CProgram") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cevalProgram" ((PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorToType") (PVar "implEntries"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "ctorToTypeRef")) (EVar "ctorToType"))) (DoLet false false (PVar "ctors") (EApp (EApp (EMethodRef "map") (EVar "ctorBinding")) (EVar "ctorArs"))) (DoLet false false (PVar "allNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "boolSeeds")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "externBindings") (ELit LUnit)))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "ctors"))) (EApp (EApp (EMethodRef "map") (EVar "cBindName")) (EVar "groups"))) (EApp (EVar "cImplMethodNames") (EVar "implEntries")))) (DoLet false false (PVar "cells") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "Ref") (EVar "VUnit"))))) (EVar "allNames"))) (DoLet false false (PVar "env") (EApp (EVar "EvalEnv") (EListLit (EVar "cells")))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "cells")) (EVar "boolSeeds"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "cells")) (EApp (EVar "externBindings") (ELit LUnit)))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "cells")) (EVar "ctors"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "cells")) (EApp (EVar "coalesceImpls") (EApp (EApp (EMethodRef "map") (EApp (EVar "cImplEntryValue") (EVar "env"))) (EVar "implEntries"))))) (DoLet false false PWild (EApp (EApp (EApp (EVar "cInstallTopGroups") (EVar "env")) (EVar "cells")) (EVar "groups"))) (DoExpr (EApp (EApp (EMethodRef "map") (EVar "cellResult")) (EVar "cells")))))
(DTypeSig false "ctorBinding" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "ctorBinding" ((PTuple (PVar "name") (PVar "arity"))) (ETuple (EVar "name") (EApp (EApp (EVar "makeCtor") (EVar "name")) (EVar "arity"))))
(DTypeSig false "cImplMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "cImplMethodNames" ((PVar "entries")) (EApp (EVar "dedup") (EApp (EApp (EMethodRef "map") (EVar "cImplEntryName")) (EVar "entries"))))
(DTypeSig false "cImplEntryName" (TyFun (TyCon "CImplEntry") (TyCon "String")))
(DFunDef false "cImplEntryName" ((PCon "CImplEntry" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "cImplEntryValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "CImplEntry") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cImplEntryValue" ((PVar "env") (PCon "CImplEntry" (PVar "name") (PVar "score") (PVar "body"))) (ETuple (EVar "name") (ETuple (EVar "score") (EApp (EApp (EVar "cImplBodyValue") (EVar "env")) (EVar "body")))))
(DTypeSig false "cImplBodyValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "CImplBody") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "cImplBodyValue" ((PVar "env") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "positions") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EVar "VTypedImpl") (EVar "tag")) (EVar "key")) (EVar "positions")) (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "cImplMethodValue") (EVar "env")) (EVar "positions")) (EVar "pats")) (EVar "body"))))
(DFunDef false "cImplBodyValue" ((PVar "env") (PCon "CImplDefault" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "cImplMethodValue") (EVar "env")) (EListLit)) (EVar "pats")) (EVar "body")))
(DTypeSig false "cImplMethodValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "CExpr") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cImplMethodValue" ((PVar "env") (PVar "positions") (PList) (PVar "body")) (EIf (EApp (EVar "isEmptyL") (EVar "positions")) (EApp (EVar "VThunk") (ELam (PWild) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "body")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "VClosureF") (EVar "env")) (EListLit (EApp (EVar "PVar") (ELit (LString "$eta"))))) (ELam ((PVar "e")) (EApp (EApp (EVar "ceval") (EVar "e")) (EApp (EApp (EVar "CApp") (EVar "body")) (EApp (EApp (EVar "CVar") (ELit (LString "$eta"))) (EVar "AGlobal")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "cImplMethodValue" ((PVar "env") PWild (PVar "pats") (PVar "body")) (EApp (EApp (EApp (EVar "VClosureF") (EVar "env")) (EVar "pats")) (ELam ((PVar "e")) (EApp (EApp (EVar "ceval") (EVar "e")) (EVar "body")))))
(DTypeSig false "cBindName" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "cBindName" ((PCon "CBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "cInstallTopGroups" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyEffect () (Some "e") (TyCon "Unit"))))))
(DFunDef false "cInstallTopGroups" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "cInstallTopGroups" ((PVar "env") (PVar "cells") (PCons (PCon "CBind" (PVar "n") (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EApp (EApp (EVar "findCell") (EVar "cells")) (EVar "n"))) (EApp (EApp (EVar "cTopGroupValue") (EVar "env")) (EVar "clauses")))) (DoExpr (EApp (EApp (EApp (EVar "cInstallTopGroups") (EVar "env")) (EVar "cells")) (EVar "rest")))))
(DTypeSig false "cTopGroupValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "cTopGroupValue" ((PVar "env") (PList (PCon "CClause" (PVar "pats") (PVar "body")))) (EIf (EApp (EVar "isNullary") (EVar "pats")) (EApp (EVar "VThunk") (ELam (PWild) (EApp (EApp (EVar "ceval") (EVar "env")) (EVar "body")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "VClosureF") (EVar "env")) (EVar "pats")) (ELam ((PVar "e")) (EApp (EApp (EVar "ceval") (EVar "e")) (EVar "body")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "cTopGroupValue" ((PVar "env") (PVar "clauses")) (EApp (EVar "VMulti") (EApp (EApp (EMethodRef "map") (EApp (EVar "cClauseClosure") (EVar "env"))) (EVar "clauses"))))
(DTypeSig true "cevalMain" (TyFun (TyCon "CProgram") (TyCon "String")))
(DFunDef false "cevalMain" ((PVar "prog")) (EMatch (EApp (EApp (EVar "lookupBinding") (ELit (LString "main"))) (EApp (EVar "cevalProgram") (EVar "prog"))) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "ppValue") (EApp (EVar "force") (EVar "v")))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "core_ir eval: no `main` binding"))))))
(DTypeSig true "cevalOutput" (TyFun (TyCon "CProgram") (TyCon "String")))
(DFunDef false "cevalOutput" ((PVar "prog")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false (PVar "binds") (EApp (EVar "cevalProgram") (EVar "prog"))) (DoLet false false PWild (EApp (EVar "cRunMainForEffect") (EVar "binds"))) (DoExpr (EFieldAccess (EVar "outputRef") "value"))))
(DTypeSig false "cRunMainForEffect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "cRunMainForEffect" ((PVar "binds")) (EMatch (EApp (EApp (EVar "lookupBinding") (ELit (LString "main"))) (EVar "binds")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "force") (EVar "v"))) (arm (PCon "None") () (EVar "VUnit"))))
(DData Private "CModInfo" ("v") ((variant "CModInfo" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyVar "v")))) (TyApp (TyCon "EvalEnv") (TyVar "v"))))) ())
(DTypeSig true "cevalModules" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cevalModules" ((PVar "preludeDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "moduleDecls") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modules"))) (DoLet false false (PVar "allDecls") (EBinOp "++" (EVar "preludeDecls") (EVar "moduleDecls"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "ctorToTypeRef")) (EApp (EVar "buildCtorToType") (EVar "allDecls")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "ctorFieldOrdersRef")) (EApp (EVar "buildCtorFieldOrders") (EVar "allDecls")))) (DoLet false false (PVar "disp") (EApp (EVar "buildIfaceDispatch") (EVar "allDecls"))) (DoLet false false (PVar "ctors") (EApp (EVar "collectCtors") (EVar "allDecls"))) (DoLet false false (PVar "preludeGroups") (EApp (EVar "lowerGroups") (EVar "preludeDecls"))) (DoLet false false (PVar "preludeImpls") (EApp (EApp (EVar "lowerImplsWith") (EVar "disp")) (EVar "preludeDecls"))) (DoLet false false (PVar "globalNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "boolSeeds")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "externBindings") (ELit LUnit)))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "ctors"))) (EApp (EVar "implMethodNames") (EVar "allDecls"))) (EApp (EApp (EMethodRef "map") (EVar "cBindName")) (EVar "preludeGroups")))) (DoLet false false (PVar "globalCells") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "Ref") (EVar "VUnit"))))) (EVar "globalNames"))) (DoLet false false (PVar "globalEnv") (EApp (EVar "EvalEnv") (EListLit (EVar "globalCells")))) (DoLet false false (PVar "mods") (EApp (EApp (EApp (EApp (EVar "cBuildModInfos") (EVar "disp")) (EVar "globalCells")) (EListLit)) (EVar "modules"))) (DoLet false false (PVar "implEntries") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "cImplEntryValue") (EVar "globalEnv"))) (EVar "preludeImpls")) (EApp (EApp (EDictApp "flatMap") (EVar "cModImplValues")) (EVar "mods")))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "boolSeeds"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EApp (EVar "externBindings") (ELit LUnit)))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "ctors"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EApp (EVar "coalesceImpls") (EVar "implEntries")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "cInstallTopGroups") (EVar "globalEnv")) (EVar "globalCells")) (EVar "preludeGroups"))) (DoLet false false PWild (EApp (EVar "cInstallModGroups") (EVar "mods"))) (DoExpr (EApp (EVar "cRootLocals") (EVar "mods")))))
(DTypeSig false "cBuildModInfos" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyApp (TyCon "CModInfo") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "cBuildModInfos" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "cBuildModInfos" ((PVar "disp") (PVar "globalCells") (PVar "exportsMap") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EBlock (DoLet false false (PVar "cbinds") (EApp (EVar "lowerGroups") (EVar "decls"))) (DoLet false false (PVar "cimpls") (EApp (EApp (EVar "lowerImplsWith") (EVar "disp")) (EVar "decls"))) (DoLet false false (PVar "modCtors") (EApp (EVar "collectCtors") (EVar "decls"))) (DoLet false false (PVar "localCells") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "Ref") (EVar "VUnit"))))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "cBindName")) (EVar "cbinds")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "modCtors"))))) (DoLet false false (PVar "imports") (EApp (EApp (EVar "importFrameOf") (EVar "exportsMap")) (EVar "decls"))) (DoLet false false (PVar "menv") (EApp (EVar "EvalEnv") (EListLit (EVar "localCells") (EVar "imports") (EVar "globalCells")))) (DoLet false false (PVar "exports") (EBinOp "++" (EBinOp "++" (EVar "localCells") (EApp (EApp (EVar "methodCellsOf") (EVar "globalCells")) (EVar "decls"))) (EApp (EApp (EApp (EVar "pubReexports") (EVar "globalCells")) (EVar "exportsMap")) (EVar "decls")))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CModInfo") (EVar "mid")) (EVar "decls")) (EVar "cbinds")) (EVar "cimpls")) (EVar "localCells")) (EVar "menv")) (EApp (EApp (EApp (EApp (EVar "cBuildModInfos") (EVar "disp")) (EVar "globalCells")) (EBinOp "::" (ETuple (EVar "mid") (EVar "exports")) (EVar "exportsMap"))) (EVar "rest"))))))
(DTypeSig false "cModImplValues" (TyFun (TyApp (TyCon "CModInfo") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "cModImplValues" ((PCon "CModInfo" PWild PWild PWild (PVar "cimpls") PWild (PVar "menv"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "cImplEntryValue") (EVar "menv"))) (EVar "cimpls")))
(DTypeSig false "cInstallModGroups" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "CModInfo") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyCon "Unit"))))
(DFunDef false "cInstallModGroups" ((PList)) (ELit LUnit))
(DFunDef false "cInstallModGroups" ((PCons (PCon "CModInfo" PWild (PVar "decls") (PVar "cbinds") PWild (PVar "cells") (PVar "menv")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "cInstallTopGroups") (EVar "menv")) (EVar "cells")) (EVar "cbinds"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "cells")) (EApp (EVar "collectCtors") (EVar "decls")))) (DoExpr (EApp (EVar "cInstallModGroups") (EVar "rest")))))
(DTypeSig false "cRootLocals" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "CModInfo") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "cRootLocals" ((PList)) (EListLit))
(DFunDef false "cRootLocals" ((PList (PCon "CModInfo" PWild PWild PWild PWild (PVar "cells") PWild))) (EApp (EApp (EMethodRef "map") (EVar "cellResult")) (EVar "cells")))
(DFunDef false "cRootLocals" ((PCons PWild (PVar "rest"))) (EApp (EVar "cRootLocals") (EVar "rest")))
(DTypeSig true "cevalModulesOutput" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))
(DFunDef false "cevalModulesOutput" ((PVar "preludeDecls") (PVar "modules")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false (PVar "binds") (EApp (EApp (EVar "cevalModules") (EVar "preludeDecls")) (EVar "modules"))) (DoLet false false PWild (EApp (EVar "cRunMainForEffect") (EVar "binds"))) (DoExpr (EFieldAccess (EVar "outputRef") "value"))))
