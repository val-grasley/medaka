# META
source_lines=473
stages=DESUGAR,MARK
# SOURCE
-- TRMC eligibility analysis (TRMC-DESIGN.md §"Phase 1 scope" + §"Backend portability").
-- The BACKEND-AGNOSTIC structural analysis that decides whether a function is
-- tail-recursion-modulo-cons eligible.  Lifted out of `llvm_emit.mdk` (WASMGC-TRMC-DESIGN.md
-- §5/§7-Stage-0) so BOTH the LLVM backend (`llvm_emit.mdk`) and the WasmGC backend
-- (`wasm_emit.mdk`, Stage 1+) share one analysis.  The ctor lookups (`isCtor`/`ctorArity`)
-- are PARAMETERIZED as `(ic : String -> <Mut> Bool)` / `(ar : String -> <Mut> Int)` so this
-- module carries no backend-specific emit state.  The EMIT (destination-passing loop) stays
-- backend-specific and lives in each emitter.

import frontend.ast.{Pat(..), Route(..), Addr(..)}
import ir.core_ir.{
  CExpr(..),
  CField(..),
  CBind(..),
  CClause(..),
  CStmt(..),
  CArm(..),
  CGuard(..),
}
import support.util.{contains, listLen}

-- How the eligible function refers to ITSELF in a tail self-call.  A top-level
-- define recurses by NAME (`CVar self`); a dispatched instance method (Phase 2
-- B-dispatch — stdlib `map`/`filterMap`) recurses via a `CMethod method (RKey tag)`
-- node post-restampIface, where the method NAME is invisible to `freeVars` — so the
-- self-walk MUST be SelfRef-aware, not freeVars-based, or a non-tail `CMethod`
-- self-recursion is silently accepted and MISCOMPILED (TRMC-DESIGN §"SAFETY-CRITICAL").
public export data SelfRef = SelfByVar String | SelfByMethod String String

-- ── pure structural helpers (CExpr free-variable + application analysis) ─────
-- Backend-agnostic; relocated here so the analysis is self-contained (the emitters
-- re-import them).

export flattenApp : CExpr -> List CExpr -> (CExpr, List CExpr)
flattenApp (CApp f a) acc = flattenApp f (a::acc)
flattenApp hd acc = (hd, acc)

-- ── small list helpers (slice 3) ────────────────────────────────────────────
export lengthS : List a -> Int
lengthS [] = 0
lengthS (_::xs) = 1 + lengthS xs

export freeVars : List String -> CExpr -> List String
freeVars _ (CLit _) = []
freeVars b (CVar x _) = if contains x b then [] else [x]
freeVars b (CApp f a) = freeVars b f ++ freeVars b a
freeVars b (CLam ps body) = freeVars (patVarNames ps ++ b) body
freeVars b (CLet recF pat e1 e2) =
  let b2 = patVars pat ++ b
  let fe1 = if recF then freeVars b2 e1 else freeVars b e1
  fe1 ++ freeVars b2 e2
freeVars b (CLetGroup binds body) =
  let b2 = bindNames binds ++ b
  freeVarsBinds b2 binds ++ freeVars b2 body
freeVars b (CBlock stmts) = freeVarsStmts b stmts
freeVars b (CIf c t f) = freeVars b c ++ freeVars b t ++ freeVars b f
freeVars b (CBinPrim _ l r _) = freeVars b l ++ freeVars b r
freeVars b (CUnOp _ x) = freeVars b x
freeVars b (CMatch scrut arms) = freeVars b scrut ++ freeVarsArms b arms
freeVars b (CDecision scrut arms _) = freeVars b scrut ++ freeVarsArms b arms
freeVars b (CTuple es) = freeVarsList b es
freeVars b (CList es) = freeVarsList b es
freeVars b (CRangeList lo hi _) = freeVars b lo ++ freeVars b hi
freeVars b (CRecord _ fields) = freeVarsFields b fields
freeVars b (CFieldAccess ex _ _) = freeVars b ex
freeVars b (CRecordUpdate base updates) = freeVars b base
  ++ freeVarsFields b updates
freeVars b (CVariantUpdate _ base updates) = freeVars b base
  ++ freeVarsFields b updates
freeVars b (CArray es) = freeVarsList b es
freeVars b (CRangeArray lo hi _) = freeVars b lo ++ freeVars b hi
freeVars b (CIndex a i) = freeVars b a ++ freeVars b i
freeVars b (CSlice a lo hi _) = freeVars b a ++ freeVars b lo ++ freeVars b hi
freeVars b (CStringIndex a i) = freeVars b a ++ freeVars b i
freeVars b (CStringSlice a lo hi _) = freeVars b a
  ++ freeVars b lo
  ++ freeVars b hi
freeVars b (CListIndex a i) = freeVars b a ++ freeVars b i
freeVars b (CListSlice a lo hi _) = freeVars b a
  ++ freeVars b lo
  ++ freeVars b hi
freeVars b (CMethod _ route implRoutes methRoutes) =
  routeDictNames b (route :: implRoutes ++ methRoutes)
freeVars b (CDict _ routes) = routeDictNames b routes
freeVars _ _ = []

-- collect the captured dict-param names (RDict/RDictFwd) from a list of Routes.
-- RKey and RNone carry no captured variable name; only RDict/RDictFwd name a dict
-- parameter that the enclosing closure must capture from its env.
export routeDictNames : List String -> List Route -> List String
routeDictNames _ [] = []
routeDictNames b ((RDict d)::rest) = (if contains d b then [] else [d])
  ++ routeDictNames b rest
routeDictNames b ((RDictFwd d)::rest) = (if contains d b then [] else [d])
  ++ routeDictNames b rest
routeDictNames b (_::rest) = routeDictNames b rest

export freeVarsFields : List String -> List CField -> List String
freeVarsFields _ [] = []
freeVarsFields b ((CField _ ex)::rest) = freeVars b ex ++ freeVarsFields b rest

export freeVarsList : List String -> List CExpr -> List String
freeVarsList _ [] = []
freeVarsList b (e::rest) = freeVars b e ++ freeVarsList b rest

export freeVarsArms : List String -> List CArm -> List String
freeVarsArms _ [] = []
freeVarsArms b ((CArm pat _ body)::rest) = freeVars (patVars pat ++ b) body
  ++ freeVarsArms b rest

export freeVarsStmts : List String -> List CStmt -> List String
freeVarsStmts _ [] = []
freeVarsStmts b ((CSExpr ex)::rest) = freeVars b ex ++ freeVarsStmts b rest
freeVarsStmts b ((CSLet _ pat ex)::rest) = freeVars b ex
  ++ freeVarsStmts (patVars pat ++ b) rest
freeVarsStmts b ((CSAssign _ ex)::rest) = freeVars b ex ++ freeVarsStmts b rest
freeVarsStmts b (_::rest) = freeVarsStmts b rest

export freeVarsBinds : List String -> List CBind -> List String
freeVarsBinds _ [] = []
freeVarsBinds b ((CBind _ [CClause [] rhs])::rest) = freeVars b rhs
  ++ freeVarsBinds b rest
freeVarsBinds b (_::rest) = freeVarsBinds b rest

export bindNames : List CBind -> List String
bindNames [] = []
bindNames (b::rest) = bindName b :: bindNames rest

export bindName : CBind -> String
bindName (CBind name _) = name

-- the variables a pattern binds.
export patVars : Pat -> List String
patVars (PVar x) = [x]
patVars (PCon _ args) = patVarsList args
patVars (PCons h t) = patVars h ++ patVars t
patVars (PTuple ps) = patVarsList ps
patVars (PList ps) = patVarsList ps
patVars (PAs x p) = x :: patVars p
patVars _ = []

export patVarsList : List Pat -> List String
patVarsList [] = []
patVarsList (p::rest) = patVars p ++ patVarsList rest

export patVarNames : List Pat -> List String
patVarNames ps = patVarsList ps

-- ── TRMC eligibility analysis (TRMC-DESIGN.md §"Phase 1 scope") ──────────────
-- A function `self` of `arity` is TRMC-eligible when every clause body descends
-- (through CIf / CLet / CLetGroup tail wrappers) to leaves that are EITHER a
-- base/other leaf with NO self-call, OR an eligible cons-tail leaf
-- `CBinPrim "::" head (self-call)` where the tail is a SATURATED self CApp-spine
-- and `head` contains no self-call.  At least one cons-tail leaf must exist (else
-- there is nothing to transform).  Any self-call OUTSIDE a cons-tail leaf
-- DISQUALIFIES the whole function (we cannot prove the loop preserves it) → fall
-- back to the current stack-growing codegen.  Structural + deterministic, so
-- interp- and native-emit produce identical IR (fixpoint holds by construction).
-- `ic`/`ar` are the (backend-neutral) ctor lookups (`isCtor`/`ctorArity`).
export trmcEligible : (String -> <Mut> Bool) -> (String -> <Mut> Int) -> SelfRef -> Int -> List (List Pat, CExpr) -> <Mut> Bool
trmcEligible ic ar self arity clauses = trmcClausesOk ic ar self arity clauses
  && trmcAnyCons ic ar self arity clauses

-- every clause body is TRMC-safe (no misplaced self-call).
export trmcClausesOk : (String -> <Mut> Bool) -> (String -> <Mut> Int) -> SelfRef -> Int -> List (List Pat, CExpr) -> <Mut> Bool
trmcClausesOk _ _ _ _ [] = True
trmcClausesOk ic ar self arity ((_, body)::rest) = trmcBodyOk ic ar self arity body
  && trmcClausesOk ic ar self arity rest

-- at least one clause has an eligible cons/ctor-tail leaf.
export trmcAnyCons : (String -> <Mut> Bool) -> (String -> <Mut> Int) -> SelfRef -> Int -> List (List Pat, CExpr) -> <Mut> Bool
trmcAnyCons _ _ _ _ [] = False
trmcAnyCons ic ar self arity ((_, body)::rest) = trmcBodyHasCons ic ar self arity body
  || trmcAnyCons ic ar self arity rest

-- a tail expr is TRMC-safe: descend through CIf/CLet/CLetGroup wrappers; at a
-- leaf, either it is an eligible ctor-tail (`Ctor f… (self-call)`, the LAST field
-- is the self-call and every other field self-free) or it contains no self-call
-- at all.  A self-call anywhere else fails.  "Self-free" is SelfRef-directed:
-- `selfFree` (freeVars for SelfByVar; the CMethod-aware `mentionsSelfMethod` walk
-- for SelfByMethod — `freeVars` is BLIND to the method name, so a dispatched self
-- recursion outside an eligible tail leaf MUST be caught here, TRMC-DESIGN
-- §"SAFETY-CRITICAL", or it is silently accepted and MISCOMPILED).
export trmcBodyOk : (String -> <Mut> Bool) -> (String -> <Mut> Int) -> SelfRef -> Int -> CExpr -> <Mut> Bool
trmcBodyOk ic ar self arity (CIf c t f) = selfFree self c
  && trmcBodyOk ic ar self arity t
  && trmcBodyOk ic ar self arity f
trmcBodyOk ic ar self arity (CLet _ _ rhs b) = selfFree self rhs
  && trmcBodyOk ic ar self arity b
trmcBodyOk ic ar self arity (CLetGroup binds b) = not (selfRefersToBinds self binds)
  && trmcBodyOk ic ar self arity b
-- B-match-descent (TRMC-DESIGN §"Phase 2 sub-part 3"): a tail-position decision
-- tree (CDecision — `lowerMatch` lowers a constructor/list/tuple/literal match to
-- this; a non-treeable CMatch has NO emit arm and is left to disqualify) is
-- descended — the SCRUTINEE must be self-free (it is evaluated eagerly, not in the
-- loop's destination-passing position), and every arm body must itself be TRMC-safe
-- in tail position.  An arm body may be a cons/ctor-tail leaf, a self-free base, OR
-- the new F3 plain-tail self-call leaf (`None => self …` — iterate on a shorter
-- list, build no cell).  Any self-call in a NON-tail position inside an arm is
-- caught by `trmcBodyOk`'s leaf check (`selfFree` is SelfRef-directed, so a
-- dispatched self-recursion is not blind).
trmcBodyOk ic ar self arity (CDecision scrut arms _) = selfFree self scrut
  && trmcArmsOk ic ar self arity arms
trmcBodyOk ic ar self arity ex =
  if isCtorTail ic ar self arity ex then
    True
  else if isSelfSatApp self arity ex then
    True
  else
    selfFree self ex

-- every match-arm body is TRMC-safe in tail position (guards must be self-free —
-- a self-call inside a guard would run outside the loop's tail position).
export trmcArmsOk : (String -> <Mut> Bool) -> (String -> <Mut> Int) -> SelfRef -> Int -> List CArm -> <Mut> Bool
trmcArmsOk _ _ _ _ [] = True
trmcArmsOk ic ar self arity ((CArm _ guards body)::rest) = trmcGuardsSelfFree self guards
  && trmcBodyOk ic ar self arity body
  && trmcArmsOk ic ar self arity rest

-- every guard expr is self-free (guards run before the arm body, not in tail
-- position — a self-call there can't be a tail leaf).
export trmcGuardsSelfFree : SelfRef -> List CGuard -> Bool
trmcGuardsSelfFree _ [] = True
trmcGuardsSelfFree self ((CGBool c)::rest) = selfFree self c
  && trmcGuardsSelfFree self rest
trmcGuardsSelfFree self ((CGBind _ c)::rest) = selfFree self c
  && trmcGuardsSelfFree self rest

-- does a tail expr (under the same wrappers) reach an eligible ctor-tail leaf?
-- (The plain-tail self-call leaf is NOT a "cons" — it builds no cell — so it does
-- not satisfy trmcAnyCons; a function whose ONLY self-calls are plain-tail (pure
-- tail recursion) is left to the musttail path, not TRMC.  At least one cons/ctor
-- tail must exist to warrant the destination-passing loop.)
export trmcBodyHasCons : (String -> <Mut> Bool) -> (String -> <Mut> Int) -> SelfRef -> Int -> CExpr -> <Mut> Bool
trmcBodyHasCons ic ar self arity (CIf _ t f) = trmcBodyHasCons ic ar self arity t
  || trmcBodyHasCons ic ar self arity f
trmcBodyHasCons ic ar self arity (CLet _ _ _ b) =
  trmcBodyHasCons ic ar self arity b
trmcBodyHasCons ic ar self arity (CLetGroup _ b) =
  trmcBodyHasCons ic ar self arity b
trmcBodyHasCons ic ar self arity (CDecision _ arms _) =
  trmcArmsHaveCons ic ar self arity arms
trmcBodyHasCons ic ar self arity ex = isCtorTail ic ar self arity ex

export trmcArmsHaveCons : (String -> <Mut> Bool) -> (String -> <Mut> Int) -> SelfRef -> Int -> List CArm -> <Mut> Bool
trmcArmsHaveCons _ _ _ _ [] = False
trmcArmsHaveCons ic ar self arity ((CArm _ _ body)::rest) = trmcBodyHasCons ic ar self arity body
  || trmcArmsHaveCons ic ar self arity rest

-- the eligible ctor-tail shape (Phase 2 Axis A — general single-constructor
-- LAST-field TMC).  Two cases, both: the LAST field is a SATURATED self-recursive
-- spine (head==self, exactly `arity` args), every OTHER field self-free.
--   • `CBinPrim "::" head tail` — the `::`/Cons special case (never flattens to a
--     `CVar` head): field0=head (self-free), last field=tail (the self-call).
--   • a saturated ctor app `Ctor f0 f1 … (self …)`: flattenApp head is `CVar ctor`
--     with `isCtor`, exactly `ctorArity` fields, `ctorArity ≥ 1`, the LAST field a
--     saturated self-call, every other field self-free.
-- `self` is a SelfRef: SelfByVar (top-level define) → the self-call spine head is
-- `CVar self`; SelfByMethod (Phase 2 B-dispatch) → `CMethod method (RKey tag) …`.
export isCtorTail : (String -> <Mut> Bool) -> (String -> <Mut> Int) -> SelfRef -> Int -> CExpr -> <Mut> Bool
isCtorTail _ _ self arity (CBinPrim "::" head tail _) = selfFree self head
  && isSelfSatApp self arity tail
isCtorTail ic ar self arity ex = match flattenApp ex []
  (CVar ctor _, fields) =>
    if ic ctor && lengthS fields == ar ctor && ar ctor >= 1 then
      ctorTailFieldsOk self arity fields
    else
      False
  _ => False

-- the field list of a saturated ctor app is TRMC-eligible: the LAST field is the
-- saturated self-call (`isSelfSatApp`), every OTHER (leading) field is self-free.
export ctorTailFieldsOk : SelfRef -> Int -> List CExpr -> Bool
ctorTailFieldsOk self arity fields = match splitLastF fields
  Some (lead, last) => allSelfFreeF self lead && isSelfSatApp self arity last
  None => False

export allSelfFreeF : SelfRef -> List CExpr -> Bool
allSelfFreeF _ [] = True
allSelfFreeF self (x::rest) = selfFree self x && allSelfFreeF self rest

-- split a non-empty list into (leading elements, last element).
export splitLastF : List a -> Option (List a, a)
splitLastF [] = None
splitLastF [x] = Some ([], x)
splitLastF (x::rest) = map ((lead, last) => (x::lead, last)) (splitLastF rest)

-- `ex` is a SATURATED self-call to exactly `arity` value args.  SelfByVar: a
-- `CVar self`-headed spine.  SelfByMethod: a `CMethod method (RKey tag) …`-headed
-- spine (the dispatched recursive call post-restampIface — the only shape that
-- lowers to a direct `@mdk_impl_<tag>_<method>` recursion).
export isSelfSatApp : SelfRef -> Int -> CExpr -> Bool
isSelfSatApp self arity ex = match flattenApp ex []
  (hd, args) => isSelfHead self hd && listLen args == arity

-- is `hd` the head of a self-call for this SelfRef?
export isSelfHead : SelfRef -> CExpr -> Bool
isSelfHead (SelfByVar self) (CVar f _) = f == self
isSelfHead (SelfByMethod method tag) (CMethod m route _ _) = m == method
  && routeIsKey tag route
isSelfHead _ _ = False

-- a route is `RKey tag …` for this tag (the concrete-impl dispatch a dispatched
-- self-recursion carries after restampIface).
export routeIsKey : String -> Route -> Bool
routeIsKey tag (RKey t _) = t == tag
routeIsKey _ _ = False

-- `ex` contains NO free reference to `self`.  SelfByVar: freeVars (a CVar name).
-- SelfByMethod: the CMethod-aware walk (freeVars CANNOT see a method name —
-- TRMC-DESIGN §"SAFETY-CRITICAL").
export selfFree : SelfRef -> CExpr -> Bool
selfFree (SelfByVar self) ex = not (contains self (freeVars [] ex))
selfFree (SelfByMethod method tag) ex = not (mentionsSelfMethod method tag ex)

-- does `ex` mention the self-method `method`@`tag` (a `CMethod method (RKey tag)`
-- occurrence) ANYWHERE in its tree?  This is the safety-critical disqualification:
-- `freeVars (CMethod …)` returns only the dict NAMES, so a dispatched self-call in
-- a NON-tail position is invisible to the freeVars-based `selfFree` and would be
-- wrongly accepted as "self-free" → the body TRMC-transformed → the non-tail self
-- recursion DROPPED → silent miscompile.  This full structural walk closes that.
export mentionsSelfMethod : String -> String -> CExpr -> Bool
mentionsSelfMethod method tag (CMethod m route _ _) = m == method
  && routeIsKey tag route
mentionsSelfMethod method tag (CApp f a) = mentionsSelfMethod method tag f
  || mentionsSelfMethod method tag a
mentionsSelfMethod method tag (CLam _ b) = mentionsSelfMethod method tag b
mentionsSelfMethod method tag (CLet _ _ rhs b) = mentionsSelfMethod method tag rhs
  || mentionsSelfMethod method tag b
mentionsSelfMethod method tag (CLetGroup binds b) = mentionsSelfMethodBinds method tag binds
  || mentionsSelfMethod method tag b
mentionsSelfMethod method tag (CBlock stmts) =
  mentionsSelfMethodStmts method tag stmts
mentionsSelfMethod method tag (CIf c t f) = mentionsSelfMethod method tag c
  || mentionsSelfMethod method tag t
  || mentionsSelfMethod method tag f
mentionsSelfMethod method tag (CBinPrim _ l r _) = mentionsSelfMethod method tag l
  || mentionsSelfMethod method tag r
mentionsSelfMethod method tag (CUnOp _ x) = mentionsSelfMethod method tag x
mentionsSelfMethod method tag (CMatch s arms) = mentionsSelfMethod method tag s
  || mentionsSelfMethodArms method tag arms
mentionsSelfMethod method tag (CDecision s arms _) = mentionsSelfMethod method tag s
  || mentionsSelfMethodArms method tag arms
mentionsSelfMethod method tag (CTuple xs) = mentionsSelfMethodList method tag xs
mentionsSelfMethod method tag (CList xs) = mentionsSelfMethodList method tag xs
mentionsSelfMethod method tag (CArray xs) = mentionsSelfMethodList method tag xs
mentionsSelfMethod method tag (CRangeList lo hi _) = mentionsSelfMethod method tag lo
  || mentionsSelfMethod method tag hi
mentionsSelfMethod method tag (CRangeArray lo hi _) = mentionsSelfMethod method tag lo
  || mentionsSelfMethod method tag hi
mentionsSelfMethod method tag (CRecord _ fields) =
  mentionsSelfMethodFields method tag fields
mentionsSelfMethod method tag (CFieldAccess ex _ _) =
  mentionsSelfMethod method tag ex
mentionsSelfMethod method tag (CRecordUpdate base ups) = mentionsSelfMethod method tag base
  || mentionsSelfMethodFields method tag ups
mentionsSelfMethod method tag (CVariantUpdate _ base ups) = mentionsSelfMethod method tag base
  || mentionsSelfMethodFields method tag ups
mentionsSelfMethod method tag (CIndex a i) = mentionsSelfMethod method tag a
  || mentionsSelfMethod method tag i
mentionsSelfMethod method tag (CSlice a lo hi _) = mentionsSelfMethod method tag a
  || mentionsSelfMethod method tag lo
  || mentionsSelfMethod method tag hi
mentionsSelfMethod method tag (CStringIndex a i) = mentionsSelfMethod method tag a
  || mentionsSelfMethod method tag i
mentionsSelfMethod method tag (CStringSlice a lo hi _) = mentionsSelfMethod method tag a
  || mentionsSelfMethod method tag lo
  || mentionsSelfMethod method tag hi
mentionsSelfMethod method tag (CListIndex a i) = mentionsSelfMethod method tag a
  || mentionsSelfMethod method tag i
mentionsSelfMethod method tag (CListSlice a lo hi _) = mentionsSelfMethod method tag a
  || mentionsSelfMethod method tag lo
  || mentionsSelfMethod method tag hi
mentionsSelfMethod _ _ _ = False

export mentionsSelfMethodList : String -> String -> List CExpr -> Bool
mentionsSelfMethodList _ _ [] = False
mentionsSelfMethodList method tag (x::rest) = mentionsSelfMethod method tag x
  || mentionsSelfMethodList method tag rest

export mentionsSelfMethodArms : String -> String -> List CArm -> Bool
mentionsSelfMethodArms _ _ [] = False
mentionsSelfMethodArms method tag ((CArm _ guards body)::rest) = mentionsSelfMethodGuards method tag guards
  || mentionsSelfMethod method tag body
  || mentionsSelfMethodArms method tag rest

export mentionsSelfMethodGuards : String -> String -> List CGuard -> Bool
mentionsSelfMethodGuards _ _ [] = False
mentionsSelfMethodGuards method tag ((CGBool c)::rest) = mentionsSelfMethod method tag c
  || mentionsSelfMethodGuards method tag rest
mentionsSelfMethodGuards method tag ((CGBind _ c)::rest) = mentionsSelfMethod method tag c
  || mentionsSelfMethodGuards method tag rest

export mentionsSelfMethodFields : String -> String -> List CField -> Bool
mentionsSelfMethodFields _ _ [] = False
mentionsSelfMethodFields method tag ((CField _ v)::rest) = mentionsSelfMethod method tag v
  || mentionsSelfMethodFields method tag rest

export mentionsSelfMethodStmts : String -> String -> List CStmt -> Bool
mentionsSelfMethodStmts _ _ [] = False
mentionsSelfMethodStmts method tag (s::rest) = mentionsSelfMethodStmt method tag s
  || mentionsSelfMethodStmts method tag rest

export mentionsSelfMethodStmt : String -> String -> CStmt -> Bool
mentionsSelfMethodStmt method tag (CSExpr ex) = mentionsSelfMethod method tag ex
mentionsSelfMethodStmt method tag (CSLet _ _ ex) =
  mentionsSelfMethod method tag ex
mentionsSelfMethodStmt method tag (CSAssign _ ex) =
  mentionsSelfMethod method tag ex

export mentionsSelfMethodBinds : String -> String -> List CBind -> Bool
mentionsSelfMethodBinds _ _ [] = False
mentionsSelfMethodBinds method tag ((CBind _ clauses)::rest) = mentionsSelfMethodClauses method tag clauses
  || mentionsSelfMethodBinds method tag rest

export mentionsSelfMethodClauses : String -> String -> List CClause -> Bool
mentionsSelfMethodClauses _ _ [] = False
mentionsSelfMethodClauses method tag ((CClause _ body)::rest) = mentionsSelfMethod method tag body
  || mentionsSelfMethodClauses method tag rest

-- does any nullary let-group binding's RHS reference `self`?  (Only the nullary
-- shape is descendable here; a parametric where-helper that called `self` would
-- be a misplaced self-call, so treat a non-nullary binding conservatively too.)
export selfRefersToBinds : SelfRef -> List CBind -> Bool
selfRefersToBinds _ [] = False
selfRefersToBinds self ((CBind _ [CClause [] rhs])::rest) = not (selfFree self rhs)
  || selfRefersToBinds self rest
selfRefersToBinds self ((CBind _ clauses)::rest) = selfRefersToBindClauses self clauses
  || selfRefersToBinds self rest
selfRefersToBinds self (_::rest) = selfRefersToBinds self rest

export selfRefersToBindClauses : SelfRef -> List CClause -> Bool
selfRefersToBindClauses _ [] = False
selfRefersToBindClauses self ((CClause _ body)::rest) = not (selfFree self body)
  || selfRefersToBindClauses self rest

-- the recursion args of an eligible ctor-tail's self-call (the LAST field's
-- saturated self CApp-spine args).  Works for both the `::` form and a general
-- ctor app: the last field is always the self-call.
export consTailArgs : CExpr -> List CExpr
consTailArgs (CBinPrim "::" _ tail _) = match flattenApp tail []
  (_, args) => args
consTailArgs ex = match flattenApp ex []
  (_, fields) => match splitLastF fields
    Some (_, last) => match flattenApp last []
      (_, args) => args
    None => []

-- the ctor NAME of an eligible ctor-tail leaf (`Cons` for the `::` form).
export ctorTailName : CExpr -> String
ctorTailName (CBinPrim "::" _ _ _) = "Cons"
ctorTailName ex = match flattenApp ex []
  (CVar ctor _, _) => ctor
  _ => ""

-- the LEADING (non-last) field exprs of an eligible ctor-tail leaf — the fields
-- that get stored into the cell (the last field is the destination link, not
-- stored).  For `::` this is `[head]`.
export ctorTailLeadFields : CExpr -> List CExpr
ctorTailLeadFields (CBinPrim "::" head _ _) = [head]
ctorTailLeadFields ex = match flattenApp ex []
  (_, fields) => match splitLastF fields
    Some (lead, _) => lead
    None => []

-- the self-call's field INDEX within the ctor cell (0-based field index, i.e.
-- offset `8*(idx+1)`).  Axis A: always the LAST field ⇒ `arity-1`.  Kept COMPUTED
-- (not hardcoded "last") so Phase-2 F1(b) [self-call in any field] is a localized
-- detection patch — the emit already offsets by this index (TRMC-DESIGN F1(b) seam).
export ctorTailSelfIdx : CExpr -> Int
ctorTailSelfIdx (CBinPrim "::" _ _ _) = 1
ctorTailSelfIdx ex = match flattenApp ex []
  (_, fields) => lengthS fields - 1
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" true) (mem "Route" true) (mem "Addr" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CStmt" true) (mem "CArm" true) (mem "CGuard" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false))))
(DData Public "SelfRef" () ((variant "SelfByVar" (ConPos (TyCon "String"))) (variant "SelfByMethod" (ConPos (TyCon "String") (TyCon "String")))) ())
(DTypeSig true "flattenApp" (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyTuple (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CExpr"))))))
(DFunDef false "flattenApp" ((PCon "CApp" (PVar "f") (PVar "a")) (PVar "acc")) (EApp (EApp (EVar "flattenApp") (EVar "f")) (EBinOp "::" (EVar "a") (EVar "acc"))))
(DFunDef false "flattenApp" ((PVar "hd") (PVar "acc")) (ETuple (EVar "hd") (EVar "acc")))
(DTypeSig true "lengthS" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))
(DFunDef false "lengthS" ((PList)) (ELit (LInt 0)))
(DFunDef false "lengthS" ((PCons PWild (PVar "xs"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "lengthS") (EVar "xs"))))
(DTypeSig true "freeVars" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeVars" (PWild (PCon "CLit" PWild)) (EListLit))
(DFunDef false "freeVars" ((PVar "b") (PCon "CVar" (PVar "x") PWild)) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "b")) (EListLit) (EListLit (EVar "x"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CApp" (PVar "f") (PVar "a"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "f")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "a"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CLam" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "freeVars") (EBinOp "++" (EApp (EVar "patVarNames") (EVar "ps")) (EVar "b"))) (EVar "body")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CLet" (PVar "recF") (PVar "pat") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "b2") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (DoLet false false (PVar "fe1") (EIf (EVar "recF") (EApp (EApp (EVar "freeVars") (EVar "b2")) (EVar "e1")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "e1")))) (DoExpr (EBinOp "++" (EVar "fe1") (EApp (EApp (EVar "freeVars") (EVar "b2")) (EVar "e2"))))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "b2") (EBinOp "++" (EApp (EVar "bindNames") (EVar "binds")) (EVar "b"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "freeVarsBinds") (EVar "b2")) (EVar "binds")) (EApp (EApp (EVar "freeVars") (EVar "b2")) (EVar "body"))))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "freeVarsStmts") (EVar "b")) (EVar "stmts")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "c")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "t"))) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "f"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "l")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "r"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "x")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "scrut")) (EApp (EApp (EVar "freeVarsArms") (EVar "b")) (EVar "arms"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "scrut")) (EApp (EApp (EVar "freeVarsArms") (EVar "b")) (EVar "arms"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CTuple" (PVar "es"))) (EApp (EApp (EVar "freeVarsList") (EVar "b")) (EVar "es")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CList" (PVar "es"))) (EApp (EApp (EVar "freeVarsList") (EVar "b")) (EVar "es")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "lo")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EVar "freeVarsFields") (EVar "b")) (EVar "fields")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CFieldAccess" (PVar "ex") PWild PWild)) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "ex")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CRecordUpdate" (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "base")) (EApp (EApp (EVar "freeVarsFields") (EVar "b")) (EVar "updates"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "base")) (EApp (EApp (EVar "freeVarsFields") (EVar "b")) (EVar "updates"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CArray" (PVar "es"))) (EApp (EApp (EVar "freeVarsList") (EVar "b")) (EVar "es")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "lo")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "i"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "i"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "i"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CMethod" PWild (PVar "route") (PVar "implRoutes") (PVar "methRoutes"))) (EApp (EApp (EVar "routeDictNames") (EVar "b")) (EBinOp "::" (EVar "route") (EBinOp "++" (EVar "implRoutes") (EVar "methRoutes")))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CDict" PWild (PVar "routes"))) (EApp (EApp (EVar "routeDictNames") (EVar "b")) (EVar "routes")))
(DFunDef false "freeVars" (PWild PWild) (EListLit))
(DTypeSig true "routeDictNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "routeDictNames" (PWild (PList)) (EListLit))
(DFunDef false "routeDictNames" ((PVar "b") (PCons (PCon "RDict" (PVar "d")) (PVar "rest"))) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "d")) (EVar "b")) (EListLit) (EListLit (EVar "d"))) (EApp (EApp (EVar "routeDictNames") (EVar "b")) (EVar "rest"))))
(DFunDef false "routeDictNames" ((PVar "b") (PCons (PCon "RDictFwd" (PVar "d")) (PVar "rest"))) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "d")) (EVar "b")) (EListLit) (EListLit (EVar "d"))) (EApp (EApp (EVar "routeDictNames") (EVar "b")) (EVar "rest"))))
(DFunDef false "routeDictNames" ((PVar "b") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "routeDictNames") (EVar "b")) (EVar "rest")))
(DTypeSig true "freeVarsFields" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeVarsFields" (PWild (PList)) (EListLit))
(DFunDef false "freeVarsFields" ((PVar "b") (PCons (PCon "CField" PWild (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "freeVarsFields") (EVar "b")) (EVar "rest"))))
(DTypeSig true "freeVarsList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeVarsList" (PWild (PList)) (EListLit))
(DFunDef false "freeVarsList" ((PVar "b") (PCons (PVar "e") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "e")) (EApp (EApp (EVar "freeVarsList") (EVar "b")) (EVar "rest"))))
(DTypeSig true "freeVarsArms" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeVarsArms" (PWild (PList)) (EListLit))
(DFunDef false "freeVarsArms" ((PVar "b") (PCons (PCon "CArm" (PVar "pat") PWild (PVar "body")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (EVar "body")) (EApp (EApp (EVar "freeVarsArms") (EVar "b")) (EVar "rest"))))
(DTypeSig true "freeVarsStmts" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeVarsStmts" (PWild (PList)) (EListLit))
(DFunDef false "freeVarsStmts" ((PVar "b") (PCons (PCon "CSExpr" (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "freeVarsStmts") (EVar "b")) (EVar "rest"))))
(DFunDef false "freeVarsStmts" ((PVar "b") (PCons (PCon "CSLet" PWild (PVar "pat") (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "freeVarsStmts") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (EVar "rest"))))
(DFunDef false "freeVarsStmts" ((PVar "b") (PCons (PCon "CSAssign" PWild (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "freeVarsStmts") (EVar "b")) (EVar "rest"))))
(DFunDef false "freeVarsStmts" ((PVar "b") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "freeVarsStmts") (EVar "b")) (EVar "rest")))
(DTypeSig true "freeVarsBinds" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeVarsBinds" (PWild (PList)) (EListLit))
(DFunDef false "freeVarsBinds" ((PVar "b") (PCons (PCon "CBind" PWild (PList (PCon "CClause" (PList) (PVar "rhs")))) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "rhs")) (EApp (EApp (EVar "freeVarsBinds") (EVar "b")) (EVar "rest"))))
(DFunDef false "freeVarsBinds" ((PVar "b") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "freeVarsBinds") (EVar "b")) (EVar "rest")))
(DTypeSig true "bindNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "bindNames" ((PList)) (EListLit))
(DFunDef false "bindNames" ((PCons (PVar "b") (PVar "rest"))) (EBinOp "::" (EApp (EVar "bindName") (EVar "b")) (EApp (EVar "bindNames") (EVar "rest"))))
(DTypeSig true "bindName" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "bindName" ((PCon "CBind" (PVar "name") PWild)) (EVar "name"))
(DTypeSig true "patVars" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVars" ((PCon "PVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "patVars" ((PCon "PCon" PWild (PVar "args"))) (EApp (EVar "patVarsList") (EVar "args")))
(DFunDef false "patVars" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "++" (EApp (EVar "patVars") (EVar "h")) (EApp (EVar "patVars") (EVar "t"))))
(DFunDef false "patVars" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "patVarsList") (EVar "ps")))
(DFunDef false "patVars" ((PCon "PList" (PVar "ps"))) (EApp (EVar "patVarsList") (EVar "ps")))
(DFunDef false "patVars" ((PCon "PAs" (PVar "x") (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patVars") (EVar "p"))))
(DFunDef false "patVars" (PWild) (EListLit))
(DTypeSig true "patVarsList" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsList" ((PList)) (EListLit))
(DFunDef false "patVarsList" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "++" (EApp (EVar "patVars") (EVar "p")) (EApp (EVar "patVarsList") (EVar "rest"))))
(DTypeSig true "patVarNames" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarNames" ((PVar "ps")) (EApp (EVar "patVarsList") (EVar "ps")))
(DTypeSig true "trmcEligible" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))) (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "trmcEligible" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PVar "clauses")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EApp (EVar "trmcClausesOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "clauses")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcAnyCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "clauses"))))
(DTypeSig true "trmcClausesOk" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))) (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "trmcClausesOk" (PWild PWild PWild PWild (PList)) (EVar "True"))
(DFunDef false "trmcClausesOk" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCons (PTuple PWild (PVar "body")) (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "body")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcClausesOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "rest"))))
(DTypeSig true "trmcAnyCons" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))) (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "trmcAnyCons" (PWild PWild PWild PWild (PList)) (EVar "False"))
(DFunDef false "trmcAnyCons" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCons (PTuple PWild (PVar "body")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyHasCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "body")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcAnyCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "rest"))))
(DTypeSig true "trmcBodyOk" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyCon "CExpr") (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "trmcBodyOk" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "t"))) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "f"))))
(DFunDef false "trmcBodyOk" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CLet" PWild PWild (PVar "rhs") (PVar "b"))) (EBinOp "&&" (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "rhs")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "b"))))
(DFunDef false "trmcBodyOk" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CLetGroup" (PVar "binds") (PVar "b"))) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "selfRefersToBinds") (EVar "self")) (EVar "binds"))) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "b"))))
(DFunDef false "trmcBodyOk" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "&&" (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "scrut")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcArmsOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "arms"))))
(DFunDef false "trmcBodyOk" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PVar "ex")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "isCtorTail") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "ex")) (EVar "True") (EIf (EApp (EApp (EApp (EVar "isSelfSatApp") (EVar "self")) (EVar "arity")) (EVar "ex")) (EVar "True") (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "ex")))))
(DTypeSig true "trmcArmsOk" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "trmcArmsOk" (PWild PWild PWild PWild (PList)) (EVar "True"))
(DFunDef false "trmcArmsOk" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCons (PCon "CArm" PWild (PVar "guards") (PVar "body")) (PVar "rest"))) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "trmcGuardsSelfFree") (EVar "self")) (EVar "guards")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "body"))) (EApp (EApp (EApp (EApp (EApp (EVar "trmcArmsOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "rest"))))
(DTypeSig true "trmcGuardsSelfFree" (TyFun (TyCon "SelfRef") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyCon "Bool"))))
(DFunDef false "trmcGuardsSelfFree" (PWild (PList)) (EVar "True"))
(DFunDef false "trmcGuardsSelfFree" ((PVar "self") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "c")) (EApp (EApp (EVar "trmcGuardsSelfFree") (EVar "self")) (EVar "rest"))))
(DFunDef false "trmcGuardsSelfFree" ((PVar "self") (PCons (PCon "CGBind" PWild (PVar "c")) (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "c")) (EApp (EApp (EVar "trmcGuardsSelfFree") (EVar "self")) (EVar "rest"))))
(DTypeSig true "trmcBodyHasCons" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyCon "CExpr") (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "trmcBodyHasCons" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CIf" PWild (PVar "t") (PVar "f"))) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyHasCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyHasCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "f"))))
(DFunDef false "trmcBodyHasCons" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CLet" PWild PWild PWild (PVar "b"))) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyHasCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "b")))
(DFunDef false "trmcBodyHasCons" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CLetGroup" PWild (PVar "b"))) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyHasCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "b")))
(DFunDef false "trmcBodyHasCons" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CDecision" PWild (PVar "arms") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "trmcArmsHaveCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "arms")))
(DFunDef false "trmcBodyHasCons" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PVar "ex")) (EApp (EApp (EApp (EApp (EApp (EVar "isCtorTail") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "ex")))
(DTypeSig true "trmcArmsHaveCons" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "trmcArmsHaveCons" (PWild PWild PWild PWild (PList)) (EVar "False"))
(DFunDef false "trmcArmsHaveCons" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCons (PCon "CArm" PWild PWild (PVar "body")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyHasCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "body")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcArmsHaveCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "rest"))))
(DTypeSig true "isCtorTail" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyCon "CExpr") (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "isCtorTail" (PWild PWild (PVar "self") (PVar "arity") (PCon "CBinPrim" (PLit (LString "::")) (PVar "head") (PVar "tail") PWild)) (EBinOp "&&" (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "head")) (EApp (EApp (EApp (EVar "isSelfSatApp") (EVar "self")) (EVar "arity")) (EVar "tail"))))
(DFunDef false "isCtorTail" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PVar "ex")) (EMatch (EApp (EApp (EVar "flattenApp") (EVar "ex")) (EListLit)) (arm (PTuple (PCon "CVar" (PVar "ctor") PWild) (PVar "fields")) () (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "ic") (EVar "ctor")) (EBinOp "==" (EApp (EVar "lengthS") (EVar "fields")) (EApp (EVar "ar") (EVar "ctor")))) (EBinOp ">=" (EApp (EVar "ar") (EVar "ctor")) (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "ctorTailFieldsOk") (EVar "self")) (EVar "arity")) (EVar "fields")) (EVar "False"))) (arm PWild () (EVar "False"))))
(DTypeSig true "ctorTailFieldsOk" (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyCon "Bool")))))
(DFunDef false "ctorTailFieldsOk" ((PVar "self") (PVar "arity") (PVar "fields")) (EMatch (EApp (EVar "splitLastF") (EVar "fields")) (arm (PCon "Some" (PTuple (PVar "lead") (PVar "last"))) () (EBinOp "&&" (EApp (EApp (EVar "allSelfFreeF") (EVar "self")) (EVar "lead")) (EApp (EApp (EApp (EVar "isSelfSatApp") (EVar "self")) (EVar "arity")) (EVar "last")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "allSelfFreeF" (TyFun (TyCon "SelfRef") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyCon "Bool"))))
(DFunDef false "allSelfFreeF" (PWild (PList)) (EVar "True"))
(DFunDef false "allSelfFreeF" ((PVar "self") (PCons (PVar "x") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "x")) (EApp (EApp (EVar "allSelfFreeF") (EVar "self")) (EVar "rest"))))
(DTypeSig true "splitLastF" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyVar "a")))))
(DFunDef false "splitLastF" ((PList)) (EVar "None"))
(DFunDef false "splitLastF" ((PList (PVar "x"))) (EApp (EVar "Some") (ETuple (EListLit) (EVar "x"))))
(DFunDef false "splitLastF" ((PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "lead") (PVar "last"))) (ETuple (EBinOp "::" (EVar "x") (EVar "lead")) (EVar "last")))) (EApp (EVar "splitLastF") (EVar "rest"))))
(DTypeSig true "isSelfSatApp" (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyCon "CExpr") (TyCon "Bool")))))
(DFunDef false "isSelfSatApp" ((PVar "self") (PVar "arity") (PVar "ex")) (EMatch (EApp (EApp (EVar "flattenApp") (EVar "ex")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EBinOp "&&" (EApp (EApp (EVar "isSelfHead") (EVar "self")) (EVar "hd")) (EBinOp "==" (EApp (EVar "listLen") (EVar "args")) (EVar "arity"))))))
(DTypeSig true "isSelfHead" (TyFun (TyCon "SelfRef") (TyFun (TyCon "CExpr") (TyCon "Bool"))))
(DFunDef false "isSelfHead" ((PCon "SelfByVar" (PVar "self")) (PCon "CVar" (PVar "f") PWild)) (EBinOp "==" (EVar "f") (EVar "self")))
(DFunDef false "isSelfHead" ((PCon "SelfByMethod" (PVar "method") (PVar "tag")) (PCon "CMethod" (PVar "m") (PVar "route") PWild PWild)) (EBinOp "&&" (EBinOp "==" (EVar "m") (EVar "method")) (EApp (EApp (EVar "routeIsKey") (EVar "tag")) (EVar "route"))))
(DFunDef false "isSelfHead" (PWild PWild) (EVar "False"))
(DTypeSig true "routeIsKey" (TyFun (TyCon "String") (TyFun (TyCon "Route") (TyCon "Bool"))))
(DFunDef false "routeIsKey" ((PVar "tag") (PCon "RKey" (PVar "t") PWild)) (EBinOp "==" (EVar "t") (EVar "tag")))
(DFunDef false "routeIsKey" (PWild PWild) (EVar "False"))
(DTypeSig true "selfFree" (TyFun (TyCon "SelfRef") (TyFun (TyCon "CExpr") (TyCon "Bool"))))
(DFunDef false "selfFree" ((PCon "SelfByVar" (PVar "self")) (PVar "ex")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "self")) (EApp (EApp (EVar "freeVars") (EListLit)) (EVar "ex")))))
(DFunDef false "selfFree" ((PCon "SelfByMethod" (PVar "method") (PVar "tag")) (PVar "ex")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "ex"))))
(DTypeSig true "mentionsSelfMethod" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CMethod" (PVar "m") (PVar "route") PWild PWild)) (EBinOp "&&" (EBinOp "==" (EVar "m") (EVar "method")) (EApp (EApp (EVar "routeIsKey") (EVar "tag")) (EVar "route"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CApp" (PVar "f") (PVar "a"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "f")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "a"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CLam" PWild (PVar "b"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "b")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CLet" PWild PWild (PVar "rhs") (PVar "b"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "rhs")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "b"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CLetGroup" (PVar "binds") (PVar "b"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethodBinds") (EVar "method")) (EVar "tag")) (EVar "binds")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "b"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EVar "mentionsSelfMethodStmts") (EVar "method")) (EVar "tag")) (EVar "stmts")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "c")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "t"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "f"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild)) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "l")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "r"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "x")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CMatch" (PVar "s") (PVar "arms"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "s")) (EApp (EApp (EApp (EVar "mentionsSelfMethodArms") (EVar "method")) (EVar "tag")) (EVar "arms"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CDecision" (PVar "s") (PVar "arms") PWild)) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "s")) (EApp (EApp (EApp (EVar "mentionsSelfMethodArms") (EVar "method")) (EVar "tag")) (EVar "arms"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CTuple" (PVar "xs"))) (EApp (EApp (EApp (EVar "mentionsSelfMethodList") (EVar "method")) (EVar "tag")) (EVar "xs")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CList" (PVar "xs"))) (EApp (EApp (EApp (EVar "mentionsSelfMethodList") (EVar "method")) (EVar "tag")) (EVar "xs")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CArray" (PVar "xs"))) (EApp (EApp (EApp (EVar "mentionsSelfMethodList") (EVar "method")) (EVar "tag")) (EVar "xs")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "lo")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "hi"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "lo")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "hi"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EApp (EVar "mentionsSelfMethodFields") (EVar "method")) (EVar "tag")) (EVar "fields")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CFieldAccess" (PVar "ex") PWild PWild)) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "ex")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CRecordUpdate" (PVar "base") (PVar "ups"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "base")) (EApp (EApp (EApp (EVar "mentionsSelfMethodFields") (EVar "method")) (EVar "tag")) (EVar "ups"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "ups"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "base")) (EApp (EApp (EApp (EVar "mentionsSelfMethodFields") (EVar "method")) (EVar "tag")) (EVar "ups"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CIndex" (PVar "a") (PVar "i"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "a")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "i"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "a")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "lo"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "hi"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "a")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "i"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "a")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "lo"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "hi"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "a")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "i"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "a")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "lo"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "hi"))))
(DFunDef false "mentionsSelfMethod" (PWild PWild PWild) (EVar "False"))
(DTypeSig true "mentionsSelfMethodList" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodList" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "mentionsSelfMethodList" ((PVar "method") (PVar "tag") (PCons (PVar "x") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "x")) (EApp (EApp (EApp (EVar "mentionsSelfMethodList") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DTypeSig true "mentionsSelfMethodArms" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodArms" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "mentionsSelfMethodArms" ((PVar "method") (PVar "tag") (PCons (PCon "CArm" PWild (PVar "guards") (PVar "body")) (PVar "rest"))) (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethodGuards") (EVar "method")) (EVar "tag")) (EVar "guards")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "body"))) (EApp (EApp (EApp (EVar "mentionsSelfMethodArms") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DTypeSig true "mentionsSelfMethodGuards" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodGuards" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "mentionsSelfMethodGuards" ((PVar "method") (PVar "tag") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "c")) (EApp (EApp (EApp (EVar "mentionsSelfMethodGuards") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DFunDef false "mentionsSelfMethodGuards" ((PVar "method") (PVar "tag") (PCons (PCon "CGBind" PWild (PVar "c")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "c")) (EApp (EApp (EApp (EVar "mentionsSelfMethodGuards") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DTypeSig true "mentionsSelfMethodFields" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodFields" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "mentionsSelfMethodFields" ((PVar "method") (PVar "tag") (PCons (PCon "CField" PWild (PVar "v")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "v")) (EApp (EApp (EApp (EVar "mentionsSelfMethodFields") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DTypeSig true "mentionsSelfMethodStmts" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodStmts" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "mentionsSelfMethodStmts" ((PVar "method") (PVar "tag") (PCons (PVar "s") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethodStmt") (EVar "method")) (EVar "tag")) (EVar "s")) (EApp (EApp (EApp (EVar "mentionsSelfMethodStmts") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DTypeSig true "mentionsSelfMethodStmt" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "CStmt") (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodStmt" ((PVar "method") (PVar "tag") (PCon "CSExpr" (PVar "ex"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "ex")))
(DFunDef false "mentionsSelfMethodStmt" ((PVar "method") (PVar "tag") (PCon "CSLet" PWild PWild (PVar "ex"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "ex")))
(DFunDef false "mentionsSelfMethodStmt" ((PVar "method") (PVar "tag") (PCon "CSAssign" PWild (PVar "ex"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "ex")))
(DTypeSig true "mentionsSelfMethodBinds" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodBinds" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "mentionsSelfMethodBinds" ((PVar "method") (PVar "tag") (PCons (PCon "CBind" PWild (PVar "clauses")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethodClauses") (EVar "method")) (EVar "tag")) (EVar "clauses")) (EApp (EApp (EApp (EVar "mentionsSelfMethodBinds") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DTypeSig true "mentionsSelfMethodClauses" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodClauses" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "mentionsSelfMethodClauses" ((PVar "method") (PVar "tag") (PCons (PCon "CClause" PWild (PVar "body")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "body")) (EApp (EApp (EApp (EVar "mentionsSelfMethodClauses") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DTypeSig true "selfRefersToBinds" (TyFun (TyCon "SelfRef") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "Bool"))))
(DFunDef false "selfRefersToBinds" (PWild (PList)) (EVar "False"))
(DFunDef false "selfRefersToBinds" ((PVar "self") (PCons (PCon "CBind" PWild (PList (PCon "CClause" (PList) (PVar "rhs")))) (PVar "rest"))) (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "rhs"))) (EApp (EApp (EVar "selfRefersToBinds") (EVar "self")) (EVar "rest"))))
(DFunDef false "selfRefersToBinds" ((PVar "self") (PCons (PCon "CBind" PWild (PVar "clauses")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "selfRefersToBindClauses") (EVar "self")) (EVar "clauses")) (EApp (EApp (EVar "selfRefersToBinds") (EVar "self")) (EVar "rest"))))
(DFunDef false "selfRefersToBinds" ((PVar "self") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "selfRefersToBinds") (EVar "self")) (EVar "rest")))
(DTypeSig true "selfRefersToBindClauses" (TyFun (TyCon "SelfRef") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "Bool"))))
(DFunDef false "selfRefersToBindClauses" (PWild (PList)) (EVar "False"))
(DFunDef false "selfRefersToBindClauses" ((PVar "self") (PCons (PCon "CClause" PWild (PVar "body")) (PVar "rest"))) (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "body"))) (EApp (EApp (EVar "selfRefersToBindClauses") (EVar "self")) (EVar "rest"))))
(DTypeSig true "consTailArgs" (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CExpr"))))
(DFunDef false "consTailArgs" ((PCon "CBinPrim" (PLit (LString "::")) PWild (PVar "tail") PWild)) (EMatch (EApp (EApp (EVar "flattenApp") (EVar "tail")) (EListLit)) (arm (PTuple PWild (PVar "args")) () (EVar "args"))))
(DFunDef false "consTailArgs" ((PVar "ex")) (EMatch (EApp (EApp (EVar "flattenApp") (EVar "ex")) (EListLit)) (arm (PTuple PWild (PVar "fields")) () (EMatch (EApp (EVar "splitLastF") (EVar "fields")) (arm (PCon "Some" (PTuple PWild (PVar "last"))) () (EMatch (EApp (EApp (EVar "flattenApp") (EVar "last")) (EListLit)) (arm (PTuple PWild (PVar "args")) () (EVar "args")))) (arm (PCon "None") () (EListLit))))))
(DTypeSig true "ctorTailName" (TyFun (TyCon "CExpr") (TyCon "String")))
(DFunDef false "ctorTailName" ((PCon "CBinPrim" (PLit (LString "::")) PWild PWild PWild)) (ELit (LString "Cons")))
(DFunDef false "ctorTailName" ((PVar "ex")) (EMatch (EApp (EApp (EVar "flattenApp") (EVar "ex")) (EListLit)) (arm (PTuple (PCon "CVar" (PVar "ctor") PWild) PWild) () (EVar "ctor")) (arm PWild () (ELit (LString "")))))
(DTypeSig true "ctorTailLeadFields" (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CExpr"))))
(DFunDef false "ctorTailLeadFields" ((PCon "CBinPrim" (PLit (LString "::")) (PVar "head") PWild PWild)) (EListLit (EVar "head")))
(DFunDef false "ctorTailLeadFields" ((PVar "ex")) (EMatch (EApp (EApp (EVar "flattenApp") (EVar "ex")) (EListLit)) (arm (PTuple PWild (PVar "fields")) () (EMatch (EApp (EVar "splitLastF") (EVar "fields")) (arm (PCon "Some" (PTuple (PVar "lead") PWild)) () (EVar "lead")) (arm (PCon "None") () (EListLit))))))
(DTypeSig true "ctorTailSelfIdx" (TyFun (TyCon "CExpr") (TyCon "Int")))
(DFunDef false "ctorTailSelfIdx" ((PCon "CBinPrim" (PLit (LString "::")) PWild PWild PWild)) (ELit (LInt 1)))
(DFunDef false "ctorTailSelfIdx" ((PVar "ex")) (EMatch (EApp (EApp (EVar "flattenApp") (EVar "ex")) (EListLit)) (arm (PTuple PWild (PVar "fields")) () (EBinOp "-" (EApp (EVar "lengthS") (EVar "fields")) (ELit (LInt 1))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" true) (mem "Route" true) (mem "Addr" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CStmt" true) (mem "CArm" true) (mem "CGuard" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false))))
(DData Public "SelfRef" () ((variant "SelfByVar" (ConPos (TyCon "String"))) (variant "SelfByMethod" (ConPos (TyCon "String") (TyCon "String")))) ())
(DTypeSig true "flattenApp" (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyTuple (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CExpr"))))))
(DFunDef false "flattenApp" ((PCon "CApp" (PVar "f") (PVar "a")) (PVar "acc")) (EApp (EApp (EVar "flattenApp") (EVar "f")) (EBinOp "::" (EVar "a") (EVar "acc"))))
(DFunDef false "flattenApp" ((PVar "hd") (PVar "acc")) (ETuple (EVar "hd") (EVar "acc")))
(DTypeSig true "lengthS" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))
(DFunDef false "lengthS" ((PList)) (ELit (LInt 0)))
(DFunDef false "lengthS" ((PCons PWild (PVar "xs"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "lengthS") (EVar "xs"))))
(DTypeSig true "freeVars" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeVars" (PWild (PCon "CLit" PWild)) (EListLit))
(DFunDef false "freeVars" ((PVar "b") (PCon "CVar" (PVar "x") PWild)) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "b")) (EListLit) (EListLit (EVar "x"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CApp" (PVar "f") (PVar "a"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "f")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "a"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CLam" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "freeVars") (EBinOp "++" (EApp (EVar "patVarNames") (EVar "ps")) (EVar "b"))) (EVar "body")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CLet" (PVar "recF") (PVar "pat") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "b2") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (DoLet false false (PVar "fe1") (EIf (EVar "recF") (EApp (EApp (EVar "freeVars") (EVar "b2")) (EVar "e1")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "e1")))) (DoExpr (EBinOp "++" (EVar "fe1") (EApp (EApp (EVar "freeVars") (EVar "b2")) (EVar "e2"))))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "b2") (EBinOp "++" (EApp (EVar "bindNames") (EVar "binds")) (EVar "b"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "freeVarsBinds") (EVar "b2")) (EVar "binds")) (EApp (EApp (EVar "freeVars") (EVar "b2")) (EVar "body"))))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "freeVarsStmts") (EVar "b")) (EVar "stmts")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "c")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "t"))) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "f"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "l")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "r"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "x")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "scrut")) (EApp (EApp (EVar "freeVarsArms") (EVar "b")) (EVar "arms"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "scrut")) (EApp (EApp (EVar "freeVarsArms") (EVar "b")) (EVar "arms"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CTuple" (PVar "es"))) (EApp (EApp (EVar "freeVarsList") (EVar "b")) (EVar "es")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CList" (PVar "es"))) (EApp (EApp (EVar "freeVarsList") (EVar "b")) (EVar "es")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "lo")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EVar "freeVarsFields") (EVar "b")) (EVar "fields")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CFieldAccess" (PVar "ex") PWild PWild)) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "ex")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CRecordUpdate" (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "base")) (EApp (EApp (EVar "freeVarsFields") (EVar "b")) (EVar "updates"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "updates"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "base")) (EApp (EApp (EVar "freeVarsFields") (EVar "b")) (EVar "updates"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CArray" (PVar "es"))) (EApp (EApp (EVar "freeVarsList") (EVar "b")) (EVar "es")))
(DFunDef false "freeVars" ((PVar "b") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "lo")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "i"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "i"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "i"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "a")) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "lo"))) (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "hi"))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CMethod" PWild (PVar "route") (PVar "implRoutes") (PVar "methRoutes"))) (EApp (EApp (EVar "routeDictNames") (EVar "b")) (EBinOp "::" (EVar "route") (EBinOp "++" (EVar "implRoutes") (EVar "methRoutes")))))
(DFunDef false "freeVars" ((PVar "b") (PCon "CDict" PWild (PVar "routes"))) (EApp (EApp (EVar "routeDictNames") (EVar "b")) (EVar "routes")))
(DFunDef false "freeVars" (PWild PWild) (EListLit))
(DTypeSig true "routeDictNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "routeDictNames" (PWild (PList)) (EListLit))
(DFunDef false "routeDictNames" ((PVar "b") (PCons (PCon "RDict" (PVar "d")) (PVar "rest"))) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "d")) (EVar "b")) (EListLit) (EListLit (EVar "d"))) (EApp (EApp (EVar "routeDictNames") (EVar "b")) (EVar "rest"))))
(DFunDef false "routeDictNames" ((PVar "b") (PCons (PCon "RDictFwd" (PVar "d")) (PVar "rest"))) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "d")) (EVar "b")) (EListLit) (EListLit (EVar "d"))) (EApp (EApp (EVar "routeDictNames") (EVar "b")) (EVar "rest"))))
(DFunDef false "routeDictNames" ((PVar "b") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "routeDictNames") (EVar "b")) (EVar "rest")))
(DTypeSig true "freeVarsFields" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeVarsFields" (PWild (PList)) (EListLit))
(DFunDef false "freeVarsFields" ((PVar "b") (PCons (PCon "CField" PWild (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "freeVarsFields") (EVar "b")) (EVar "rest"))))
(DTypeSig true "freeVarsList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeVarsList" (PWild (PList)) (EListLit))
(DFunDef false "freeVarsList" ((PVar "b") (PCons (PVar "e") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "e")) (EApp (EApp (EVar "freeVarsList") (EVar "b")) (EVar "rest"))))
(DTypeSig true "freeVarsArms" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeVarsArms" (PWild (PList)) (EListLit))
(DFunDef false "freeVarsArms" ((PVar "b") (PCons (PCon "CArm" (PVar "pat") PWild (PVar "body")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (EVar "body")) (EApp (EApp (EVar "freeVarsArms") (EVar "b")) (EVar "rest"))))
(DTypeSig true "freeVarsStmts" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeVarsStmts" (PWild (PList)) (EListLit))
(DFunDef false "freeVarsStmts" ((PVar "b") (PCons (PCon "CSExpr" (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "freeVarsStmts") (EVar "b")) (EVar "rest"))))
(DFunDef false "freeVarsStmts" ((PVar "b") (PCons (PCon "CSLet" PWild (PVar "pat") (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "freeVarsStmts") (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "b"))) (EVar "rest"))))
(DFunDef false "freeVarsStmts" ((PVar "b") (PCons (PCon "CSAssign" PWild (PVar "ex")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "ex")) (EApp (EApp (EVar "freeVarsStmts") (EVar "b")) (EVar "rest"))))
(DFunDef false "freeVarsStmts" ((PVar "b") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "freeVarsStmts") (EVar "b")) (EVar "rest")))
(DTypeSig true "freeVarsBinds" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeVarsBinds" (PWild (PList)) (EListLit))
(DFunDef false "freeVarsBinds" ((PVar "b") (PCons (PCon "CBind" PWild (PList (PCon "CClause" (PList) (PVar "rhs")))) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "freeVars") (EVar "b")) (EVar "rhs")) (EApp (EApp (EVar "freeVarsBinds") (EVar "b")) (EVar "rest"))))
(DFunDef false "freeVarsBinds" ((PVar "b") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "freeVarsBinds") (EVar "b")) (EVar "rest")))
(DTypeSig true "bindNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "bindNames" ((PList)) (EListLit))
(DFunDef false "bindNames" ((PCons (PVar "b") (PVar "rest"))) (EBinOp "::" (EApp (EVar "bindName") (EVar "b")) (EApp (EVar "bindNames") (EVar "rest"))))
(DTypeSig true "bindName" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "bindName" ((PCon "CBind" (PVar "name") PWild)) (EVar "name"))
(DTypeSig true "patVars" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVars" ((PCon "PVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "patVars" ((PCon "PCon" PWild (PVar "args"))) (EApp (EVar "patVarsList") (EVar "args")))
(DFunDef false "patVars" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "++" (EApp (EVar "patVars") (EVar "h")) (EApp (EVar "patVars") (EVar "t"))))
(DFunDef false "patVars" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "patVarsList") (EVar "ps")))
(DFunDef false "patVars" ((PCon "PList" (PVar "ps"))) (EApp (EVar "patVarsList") (EVar "ps")))
(DFunDef false "patVars" ((PCon "PAs" (PVar "x") (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patVars") (EVar "p"))))
(DFunDef false "patVars" (PWild) (EListLit))
(DTypeSig true "patVarsList" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsList" ((PList)) (EListLit))
(DFunDef false "patVarsList" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "++" (EApp (EVar "patVars") (EVar "p")) (EApp (EVar "patVarsList") (EVar "rest"))))
(DTypeSig true "patVarNames" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarNames" ((PVar "ps")) (EApp (EVar "patVarsList") (EVar "ps")))
(DTypeSig true "trmcEligible" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))) (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "trmcEligible" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PVar "clauses")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EApp (EVar "trmcClausesOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "clauses")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcAnyCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "clauses"))))
(DTypeSig true "trmcClausesOk" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))) (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "trmcClausesOk" (PWild PWild PWild PWild (PList)) (EVar "True"))
(DFunDef false "trmcClausesOk" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCons (PTuple PWild (PVar "body")) (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "body")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcClausesOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "rest"))))
(DTypeSig true "trmcAnyCons" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))) (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "trmcAnyCons" (PWild PWild PWild PWild (PList)) (EVar "False"))
(DFunDef false "trmcAnyCons" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCons (PTuple PWild (PVar "body")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyHasCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "body")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcAnyCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "rest"))))
(DTypeSig true "trmcBodyOk" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyCon "CExpr") (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "trmcBodyOk" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "t"))) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "f"))))
(DFunDef false "trmcBodyOk" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CLet" PWild PWild (PVar "rhs") (PVar "b"))) (EBinOp "&&" (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "rhs")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "b"))))
(DFunDef false "trmcBodyOk" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CLetGroup" (PVar "binds") (PVar "b"))) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "selfRefersToBinds") (EVar "self")) (EVar "binds"))) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "b"))))
(DFunDef false "trmcBodyOk" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "&&" (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "scrut")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcArmsOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "arms"))))
(DFunDef false "trmcBodyOk" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PVar "ex")) (EIf (EApp (EApp (EApp (EApp (EApp (EVar "isCtorTail") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "ex")) (EVar "True") (EIf (EApp (EApp (EApp (EVar "isSelfSatApp") (EVar "self")) (EVar "arity")) (EVar "ex")) (EVar "True") (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "ex")))))
(DTypeSig true "trmcArmsOk" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "trmcArmsOk" (PWild PWild PWild PWild (PList)) (EVar "True"))
(DFunDef false "trmcArmsOk" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCons (PCon "CArm" PWild (PVar "guards") (PVar "body")) (PVar "rest"))) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "trmcGuardsSelfFree") (EVar "self")) (EVar "guards")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "body"))) (EApp (EApp (EApp (EApp (EApp (EVar "trmcArmsOk") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "rest"))))
(DTypeSig true "trmcGuardsSelfFree" (TyFun (TyCon "SelfRef") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyCon "Bool"))))
(DFunDef false "trmcGuardsSelfFree" (PWild (PList)) (EVar "True"))
(DFunDef false "trmcGuardsSelfFree" ((PVar "self") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "c")) (EApp (EApp (EVar "trmcGuardsSelfFree") (EVar "self")) (EVar "rest"))))
(DFunDef false "trmcGuardsSelfFree" ((PVar "self") (PCons (PCon "CGBind" PWild (PVar "c")) (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "c")) (EApp (EApp (EVar "trmcGuardsSelfFree") (EVar "self")) (EVar "rest"))))
(DTypeSig true "trmcBodyHasCons" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyCon "CExpr") (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "trmcBodyHasCons" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CIf" PWild (PVar "t") (PVar "f"))) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyHasCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyHasCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "f"))))
(DFunDef false "trmcBodyHasCons" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CLet" PWild PWild PWild (PVar "b"))) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyHasCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "b")))
(DFunDef false "trmcBodyHasCons" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CLetGroup" PWild (PVar "b"))) (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyHasCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "b")))
(DFunDef false "trmcBodyHasCons" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCon "CDecision" PWild (PVar "arms") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "trmcArmsHaveCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "arms")))
(DFunDef false "trmcBodyHasCons" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PVar "ex")) (EApp (EApp (EApp (EApp (EApp (EVar "isCtorTail") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "ex")))
(DTypeSig true "trmcArmsHaveCons" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "trmcArmsHaveCons" (PWild PWild PWild PWild (PList)) (EVar "False"))
(DFunDef false "trmcArmsHaveCons" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PCons (PCon "CArm" PWild PWild (PVar "body")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "trmcBodyHasCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "body")) (EApp (EApp (EApp (EApp (EApp (EVar "trmcArmsHaveCons") (EVar "ic")) (EVar "ar")) (EVar "self")) (EVar "arity")) (EVar "rest"))))
(DTypeSig true "isCtorTail" (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyEffect ("Mut") None (TyCon "Int"))) (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyCon "CExpr") (TyEffect ("Mut") None (TyCon "Bool"))))))))
(DFunDef false "isCtorTail" (PWild PWild (PVar "self") (PVar "arity") (PCon "CBinPrim" (PLit (LString "::")) (PVar "head") (PVar "tail") PWild)) (EBinOp "&&" (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "head")) (EApp (EApp (EApp (EVar "isSelfSatApp") (EVar "self")) (EVar "arity")) (EVar "tail"))))
(DFunDef false "isCtorTail" ((PVar "ic") (PVar "ar") (PVar "self") (PVar "arity") (PVar "ex")) (EMatch (EApp (EApp (EVar "flattenApp") (EVar "ex")) (EListLit)) (arm (PTuple (PCon "CVar" (PVar "ctor") PWild) (PVar "fields")) () (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "ic") (EVar "ctor")) (EBinOp "==" (EApp (EVar "lengthS") (EVar "fields")) (EApp (EVar "ar") (EVar "ctor")))) (EBinOp ">=" (EApp (EVar "ar") (EVar "ctor")) (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "ctorTailFieldsOk") (EVar "self")) (EVar "arity")) (EVar "fields")) (EVar "False"))) (arm PWild () (EVar "False"))))
(DTypeSig true "ctorTailFieldsOk" (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyCon "Bool")))))
(DFunDef false "ctorTailFieldsOk" ((PVar "self") (PVar "arity") (PVar "fields")) (EMatch (EApp (EVar "splitLastF") (EVar "fields")) (arm (PCon "Some" (PTuple (PVar "lead") (PVar "last"))) () (EBinOp "&&" (EApp (EApp (EVar "allSelfFreeF") (EVar "self")) (EVar "lead")) (EApp (EApp (EApp (EVar "isSelfSatApp") (EVar "self")) (EVar "arity")) (EVar "last")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "allSelfFreeF" (TyFun (TyCon "SelfRef") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyCon "Bool"))))
(DFunDef false "allSelfFreeF" (PWild (PList)) (EVar "True"))
(DFunDef false "allSelfFreeF" ((PVar "self") (PCons (PVar "x") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "x")) (EApp (EApp (EVar "allSelfFreeF") (EVar "self")) (EVar "rest"))))
(DTypeSig true "splitLastF" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyVar "a")))))
(DFunDef false "splitLastF" ((PList)) (EVar "None"))
(DFunDef false "splitLastF" ((PList (PVar "x"))) (EApp (EVar "Some") (ETuple (EListLit) (EVar "x"))))
(DFunDef false "splitLastF" ((PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "lead") (PVar "last"))) (ETuple (EBinOp "::" (EVar "x") (EVar "lead")) (EVar "last")))) (EApp (EVar "splitLastF") (EVar "rest"))))
(DTypeSig true "isSelfSatApp" (TyFun (TyCon "SelfRef") (TyFun (TyCon "Int") (TyFun (TyCon "CExpr") (TyCon "Bool")))))
(DFunDef false "isSelfSatApp" ((PVar "self") (PVar "arity") (PVar "ex")) (EMatch (EApp (EApp (EVar "flattenApp") (EVar "ex")) (EListLit)) (arm (PTuple (PVar "hd") (PVar "args")) () (EBinOp "&&" (EApp (EApp (EVar "isSelfHead") (EVar "self")) (EVar "hd")) (EBinOp "==" (EApp (EVar "listLen") (EVar "args")) (EVar "arity"))))))
(DTypeSig true "isSelfHead" (TyFun (TyCon "SelfRef") (TyFun (TyCon "CExpr") (TyCon "Bool"))))
(DFunDef false "isSelfHead" ((PCon "SelfByVar" (PVar "self")) (PCon "CVar" (PVar "f") PWild)) (EBinOp "==" (EVar "f") (EVar "self")))
(DFunDef false "isSelfHead" ((PCon "SelfByMethod" (PVar "method") (PVar "tag")) (PCon "CMethod" (PVar "m") (PVar "route") PWild PWild)) (EBinOp "&&" (EBinOp "==" (EVar "m") (EVar "method")) (EApp (EApp (EVar "routeIsKey") (EVar "tag")) (EVar "route"))))
(DFunDef false "isSelfHead" (PWild PWild) (EVar "False"))
(DTypeSig true "routeIsKey" (TyFun (TyCon "String") (TyFun (TyCon "Route") (TyCon "Bool"))))
(DFunDef false "routeIsKey" ((PVar "tag") (PCon "RKey" (PVar "t") PWild)) (EBinOp "==" (EVar "t") (EVar "tag")))
(DFunDef false "routeIsKey" (PWild PWild) (EVar "False"))
(DTypeSig true "selfFree" (TyFun (TyCon "SelfRef") (TyFun (TyCon "CExpr") (TyCon "Bool"))))
(DFunDef false "selfFree" ((PCon "SelfByVar" (PVar "self")) (PVar "ex")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "self")) (EApp (EApp (EVar "freeVars") (EListLit)) (EVar "ex")))))
(DFunDef false "selfFree" ((PCon "SelfByMethod" (PVar "method") (PVar "tag")) (PVar "ex")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "ex"))))
(DTypeSig true "mentionsSelfMethod" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CMethod" (PVar "m") (PVar "route") PWild PWild)) (EBinOp "&&" (EBinOp "==" (EVar "m") (EVar "method")) (EApp (EApp (EVar "routeIsKey") (EVar "tag")) (EVar "route"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CApp" (PVar "f") (PVar "a"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "f")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "a"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CLam" PWild (PVar "b"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "b")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CLet" PWild PWild (PVar "rhs") (PVar "b"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "rhs")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "b"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CLetGroup" (PVar "binds") (PVar "b"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethodBinds") (EVar "method")) (EVar "tag")) (EVar "binds")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "b"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EVar "mentionsSelfMethodStmts") (EVar "method")) (EVar "tag")) (EVar "stmts")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "c")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "t"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "f"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild)) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "l")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "r"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "x")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CMatch" (PVar "s") (PVar "arms"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "s")) (EApp (EApp (EApp (EVar "mentionsSelfMethodArms") (EVar "method")) (EVar "tag")) (EVar "arms"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CDecision" (PVar "s") (PVar "arms") PWild)) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "s")) (EApp (EApp (EApp (EVar "mentionsSelfMethodArms") (EVar "method")) (EVar "tag")) (EVar "arms"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CTuple" (PVar "xs"))) (EApp (EApp (EApp (EVar "mentionsSelfMethodList") (EVar "method")) (EVar "tag")) (EVar "xs")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CList" (PVar "xs"))) (EApp (EApp (EApp (EVar "mentionsSelfMethodList") (EVar "method")) (EVar "tag")) (EVar "xs")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CArray" (PVar "xs"))) (EApp (EApp (EApp (EVar "mentionsSelfMethodList") (EVar "method")) (EVar "tag")) (EVar "xs")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "lo")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "hi"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "lo")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "hi"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EApp (EVar "mentionsSelfMethodFields") (EVar "method")) (EVar "tag")) (EVar "fields")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CFieldAccess" (PVar "ex") PWild PWild)) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "ex")))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CRecordUpdate" (PVar "base") (PVar "ups"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "base")) (EApp (EApp (EApp (EVar "mentionsSelfMethodFields") (EVar "method")) (EVar "tag")) (EVar "ups"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "ups"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "base")) (EApp (EApp (EApp (EVar "mentionsSelfMethodFields") (EVar "method")) (EVar "tag")) (EVar "ups"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CIndex" (PVar "a") (PVar "i"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "a")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "i"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "a")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "lo"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "hi"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "a")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "i"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "a")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "lo"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "hi"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "a")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "i"))))
(DFunDef false "mentionsSelfMethod" ((PVar "method") (PVar "tag") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "a")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "lo"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "hi"))))
(DFunDef false "mentionsSelfMethod" (PWild PWild PWild) (EVar "False"))
(DTypeSig true "mentionsSelfMethodList" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodList" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "mentionsSelfMethodList" ((PVar "method") (PVar "tag") (PCons (PVar "x") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "x")) (EApp (EApp (EApp (EVar "mentionsSelfMethodList") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DTypeSig true "mentionsSelfMethodArms" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodArms" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "mentionsSelfMethodArms" ((PVar "method") (PVar "tag") (PCons (PCon "CArm" PWild (PVar "guards") (PVar "body")) (PVar "rest"))) (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethodGuards") (EVar "method")) (EVar "tag")) (EVar "guards")) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "body"))) (EApp (EApp (EApp (EVar "mentionsSelfMethodArms") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DTypeSig true "mentionsSelfMethodGuards" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodGuards" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "mentionsSelfMethodGuards" ((PVar "method") (PVar "tag") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "c")) (EApp (EApp (EApp (EVar "mentionsSelfMethodGuards") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DFunDef false "mentionsSelfMethodGuards" ((PVar "method") (PVar "tag") (PCons (PCon "CGBind" PWild (PVar "c")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "c")) (EApp (EApp (EApp (EVar "mentionsSelfMethodGuards") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DTypeSig true "mentionsSelfMethodFields" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodFields" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "mentionsSelfMethodFields" ((PVar "method") (PVar "tag") (PCons (PCon "CField" PWild (PVar "v")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "v")) (EApp (EApp (EApp (EVar "mentionsSelfMethodFields") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DTypeSig true "mentionsSelfMethodStmts" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodStmts" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "mentionsSelfMethodStmts" ((PVar "method") (PVar "tag") (PCons (PVar "s") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethodStmt") (EVar "method")) (EVar "tag")) (EVar "s")) (EApp (EApp (EApp (EVar "mentionsSelfMethodStmts") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DTypeSig true "mentionsSelfMethodStmt" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "CStmt") (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodStmt" ((PVar "method") (PVar "tag") (PCon "CSExpr" (PVar "ex"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "ex")))
(DFunDef false "mentionsSelfMethodStmt" ((PVar "method") (PVar "tag") (PCon "CSLet" PWild PWild (PVar "ex"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "ex")))
(DFunDef false "mentionsSelfMethodStmt" ((PVar "method") (PVar "tag") (PCon "CSAssign" PWild (PVar "ex"))) (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "ex")))
(DTypeSig true "mentionsSelfMethodBinds" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodBinds" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "mentionsSelfMethodBinds" ((PVar "method") (PVar "tag") (PCons (PCon "CBind" PWild (PVar "clauses")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethodClauses") (EVar "method")) (EVar "tag")) (EVar "clauses")) (EApp (EApp (EApp (EVar "mentionsSelfMethodBinds") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DTypeSig true "mentionsSelfMethodClauses" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "Bool")))))
(DFunDef false "mentionsSelfMethodClauses" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "mentionsSelfMethodClauses" ((PVar "method") (PVar "tag") (PCons (PCon "CClause" PWild (PVar "body")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "mentionsSelfMethod") (EVar "method")) (EVar "tag")) (EVar "body")) (EApp (EApp (EApp (EVar "mentionsSelfMethodClauses") (EVar "method")) (EVar "tag")) (EVar "rest"))))
(DTypeSig true "selfRefersToBinds" (TyFun (TyCon "SelfRef") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "Bool"))))
(DFunDef false "selfRefersToBinds" (PWild (PList)) (EVar "False"))
(DFunDef false "selfRefersToBinds" ((PVar "self") (PCons (PCon "CBind" PWild (PList (PCon "CClause" (PList) (PVar "rhs")))) (PVar "rest"))) (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "rhs"))) (EApp (EApp (EVar "selfRefersToBinds") (EVar "self")) (EVar "rest"))))
(DFunDef false "selfRefersToBinds" ((PVar "self") (PCons (PCon "CBind" PWild (PVar "clauses")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "selfRefersToBindClauses") (EVar "self")) (EVar "clauses")) (EApp (EApp (EVar "selfRefersToBinds") (EVar "self")) (EVar "rest"))))
(DFunDef false "selfRefersToBinds" ((PVar "self") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "selfRefersToBinds") (EVar "self")) (EVar "rest")))
(DTypeSig true "selfRefersToBindClauses" (TyFun (TyCon "SelfRef") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "Bool"))))
(DFunDef false "selfRefersToBindClauses" (PWild (PList)) (EVar "False"))
(DFunDef false "selfRefersToBindClauses" ((PVar "self") (PCons (PCon "CClause" PWild (PVar "body")) (PVar "rest"))) (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "selfFree") (EVar "self")) (EVar "body"))) (EApp (EApp (EVar "selfRefersToBindClauses") (EVar "self")) (EVar "rest"))))
(DTypeSig true "consTailArgs" (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CExpr"))))
(DFunDef false "consTailArgs" ((PCon "CBinPrim" (PLit (LString "::")) PWild (PVar "tail") PWild)) (EMatch (EApp (EApp (EVar "flattenApp") (EVar "tail")) (EListLit)) (arm (PTuple PWild (PVar "args")) () (EVar "args"))))
(DFunDef false "consTailArgs" ((PVar "ex")) (EMatch (EApp (EApp (EVar "flattenApp") (EVar "ex")) (EListLit)) (arm (PTuple PWild (PVar "fields")) () (EMatch (EApp (EVar "splitLastF") (EVar "fields")) (arm (PCon "Some" (PTuple PWild (PVar "last"))) () (EMatch (EApp (EApp (EVar "flattenApp") (EVar "last")) (EListLit)) (arm (PTuple PWild (PVar "args")) () (EVar "args")))) (arm (PCon "None") () (EListLit))))))
(DTypeSig true "ctorTailName" (TyFun (TyCon "CExpr") (TyCon "String")))
(DFunDef false "ctorTailName" ((PCon "CBinPrim" (PLit (LString "::")) PWild PWild PWild)) (ELit (LString "Cons")))
(DFunDef false "ctorTailName" ((PVar "ex")) (EMatch (EApp (EApp (EVar "flattenApp") (EVar "ex")) (EListLit)) (arm (PTuple (PCon "CVar" (PVar "ctor") PWild) PWild) () (EVar "ctor")) (arm PWild () (ELit (LString "")))))
(DTypeSig true "ctorTailLeadFields" (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CExpr"))))
(DFunDef false "ctorTailLeadFields" ((PCon "CBinPrim" (PLit (LString "::")) (PVar "head") PWild PWild)) (EListLit (EVar "head")))
(DFunDef false "ctorTailLeadFields" ((PVar "ex")) (EMatch (EApp (EApp (EVar "flattenApp") (EVar "ex")) (EListLit)) (arm (PTuple PWild (PVar "fields")) () (EMatch (EApp (EVar "splitLastF") (EVar "fields")) (arm (PCon "Some" (PTuple (PVar "lead") PWild)) () (EVar "lead")) (arm (PCon "None") () (EListLit))))))
(DTypeSig true "ctorTailSelfIdx" (TyFun (TyCon "CExpr") (TyCon "Int")))
(DFunDef false "ctorTailSelfIdx" ((PCon "CBinPrim" (PLit (LString "::")) PWild PWild PWild)) (ELit (LInt 1)))
(DFunDef false "ctorTailSelfIdx" ((PVar "ex")) (EMatch (EApp (EApp (EVar "flattenApp") (EVar "ex")) (EListLit)) (arm (PTuple PWild (PVar "fields")) () (EBinOp "-" (EApp (EVar "lengthS") (EVar "fields")) (ELit (LInt 1))))))
