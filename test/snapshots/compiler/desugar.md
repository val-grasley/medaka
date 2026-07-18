# META
source_lines=1014
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted desugar stage — Stage 1 port of `lib/desugar.ml`.  Lowers surface
-- sugar (guards, sections, string interpolation, list comprehensions, do-blocks,
-- `?`, record puns, `deriving`, interface defaults) into the core AST.  Runs
-- after the parser, before resolve — purely syntactic, no type info.  Validated
-- byte-for-byte against `dev/astdump.exe --desugar` (test/diff_compiler_desugar.sh).
--
-- The reference `desugar_program` runs eight passes in a fixed order; this file
-- ports them incrementally.  `mapExpr`/`mapDecl` are the shared bottom-up
-- traversal engine (mirror of `map_expr`/`map_decl`): a rewrite `f` is applied
-- post-order (children first, then the node).

import frontend.ast.{
  Lit(..),
  Ty(..),
  Constraint(..),
  Pat(..),
  RecPatField(..),
  Guard(..),
  Arm(..),
  DoStmt(..),
  Loc(..),
  InterpPart(..),
  GuardArm(..),
  FieldAssign(..),
  Section(..),
  FunClause(..),
  LetBind(..),
  Expr(..),
  UseMember(..),
  UsePath(..),
  qualifiedLocal,
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
  Attr,
  Decl(..),
  DeriveRef(..),
  deriveRefName,
  Route(..),
}
import support.util.{
  listLen,
  joinWith,
  contains,
  allList,
  fallthroughName,
  filterList,
  anyList,
}

-- ── Bottom-up traversal engine (mirror of map_expr / map_decl) ────────────
-- `mapExpr f e` rewrites every subexpression of `e` with `f`, post-order: the
-- children are rewritten first, then `f` is applied to the rebuilt node.
export mapExpr : (Expr -> Expr) -> Expr -> Expr
mapExpr f e = f (mapKids f e)

mapKids : (Expr -> Expr) -> Expr -> Expr
-- ELoc is transparent: recurse into the wrapped expr, preserve the loc (mirror
-- of lib/desugar.ml's `map_expr` ELoc arm).  Without this the wildcard below
-- would stop the rewrite at the wrapper and never reach the atom inside.
mapKids f (ELoc l e) = ELoc l (mapExpr f e)
mapKids f (EDoOrigin l e) = EDoOrigin l (mapExpr f e)
mapKids f (EApp a b) = EApp (mapExpr f a) (mapExpr f b)
mapKids f (ELam ps b) = ELam ps (mapExpr f b)
mapKids f (ELet m r p e1 e2) = ELet m r p (mapExpr f e1) (mapExpr f e2)
mapKids f (ELetGroup bs e2) = ELetGroup (map (mapLetBind f) bs) (mapExpr f e2)
mapKids f (EMatch e0 arms) = EMatch (mapExpr f e0) (map (mapArm f) arms)
mapKids f (EIf c t el) = EIf (mapExpr f c) (mapExpr f t) (mapExpr f el)
mapKids f (EBinOp op a b r) = EBinOp op (mapExpr f a) (mapExpr f b) r
mapKids f (EUnOp op a r) = EUnOp op (mapExpr f a) r
mapKids f (EInfix op a b) = EInfix op (mapExpr f a) (mapExpr f b)
mapKids f (EFieldAccess e0 n r) = EFieldAccess (mapExpr f e0) n r
mapKids f (ERecordCreate n fs) = ERecordCreate n (map (mapFieldAssign f) fs)
mapKids f (ERecordUpdate e0 fs r) =
  ERecordUpdate (mapExpr f e0) (map (mapFieldAssign f) fs) r
mapKids f (EVariantUpdate c e0 fs) =
  EVariantUpdate c (mapExpr f e0) (map (mapFieldAssign f) fs)
mapKids f (EArrayLit es) = EArrayLit (map (mapExpr f) es)
mapKids f (EListLit es) = EListLit (map (mapExpr f) es)
mapKids f (ETuple es) = ETuple (map (mapExpr f) es)
mapKids f (EIndex e0 i r) = EIndex (mapExpr f e0) (mapExpr f i) r
mapKids f (ERangeList lo hi incl) =
  ERangeList (mapExpr f lo) (mapExpr f hi) incl
mapKids f (ERangeArray lo hi incl) =
  ERangeArray (mapExpr f lo) (mapExpr f hi) incl
mapKids f (ESlice e0 lo hi incl r) =
  ESlice (mapExpr f e0) (mapExpr f lo) (mapExpr f hi) incl r
mapKids f (EBlock stmts) = EBlock (map (mapDoStmt f) stmts)
mapKids f (EDo stmts) = EDo (map (mapDoStmt f) stmts)
mapKids f (EAnnot e0 t) = EAnnot (mapExpr f e0) t
mapKids f (EStringInterp parts) = EStringInterp (map (mapInterp f) parts)
mapKids f (EGuards arms) = EGuards (map (mapGuardArm f) arms)
mapKids f (ESection (SecRight op e0)) = ESection (SecRight op (mapExpr f e0))
mapKids f (ESection (SecLeft e0 op)) = ESection (SecLeft (mapExpr f e0) op)
mapKids f (EMapLit n kvs) = EMapLit n (map (mapKv f) kvs)
mapKids f (ESetLit n es) = ESetLit n (map (mapExpr f) es)
mapKids f (EHeadAnnot e0 t) = EHeadAnnot (mapExpr f e0) t
mapKids _ e = e

mapKv : (Expr -> Expr) -> (Expr, Expr) -> (Expr, Expr)
mapKv f (k, v) = (mapExpr f k, mapExpr f v)

mapArm : (Expr -> Expr) -> Arm -> Arm
mapArm f (Arm p gs b) = Arm p (map (mapGuard f) gs) (mapExpr f b)

mapGuard : (Expr -> Expr) -> Guard -> Guard
mapGuard f (GBool g) = GBool (mapExpr f g)
mapGuard f (GBind p g) = GBind p (mapExpr f g)

mapGuardArm : (Expr -> Expr) -> GuardArm -> GuardArm
mapGuardArm f (GuardArm gs b) = GuardArm (map (mapGuard f) gs) (mapExpr f b)

mapLetBind : (Expr -> Expr) -> LetBind -> LetBind
mapLetBind f (LetBind n clauses) = LetBind n (map (mapFunClause f) clauses)

mapFunClause : (Expr -> Expr) -> FunClause -> FunClause
mapFunClause f (FunClause ps b) = FunClause ps (mapExpr f b)

mapFieldAssign : (Expr -> Expr) -> FieldAssign -> FieldAssign
mapFieldAssign f (FieldAssign n v) = FieldAssign n (mapExpr f v)

mapDoStmt : (Expr -> Expr) -> DoStmt -> DoStmt
mapDoStmt f (DoExpr e) = DoExpr (mapExpr f e)
mapDoStmt f (DoBind p e) = DoBind p (mapExpr f e)
mapDoStmt f (DoLet m r p e) = DoLet m r p (mapExpr f e)
mapDoStmt f (DoAssign x e) = DoAssign x (mapExpr f e)
mapDoStmt f (DoFieldAssign x fs e) = DoFieldAssign x fs (mapExpr f e)

mapInterp : (Expr -> Expr) -> InterpPart -> InterpPart
mapInterp _ (InterpStr s) = InterpStr s
mapInterp f (InterpExpr e) = InterpExpr (mapExpr f e)

export mapDecl : (Expr -> Expr) -> Decl -> Decl
mapDecl f (DFunDef pub n ps e) = DFunDef pub n ps (mapExpr f e)
mapDecl f (d@(DInterface { methods, ... })) =
  DInterface { d | methods = map (mapIfaceMethod f) methods }
mapDecl f (d@(DImpl { methods, ... })) =
  DImpl { d | methods = map (mapImplMethod f) methods }
mapDecl f (DProp pub name params body) = DProp pub name params (mapExpr f body)
mapDecl f (DTest pub name body) = DTest pub name (mapExpr f body)
mapDecl f (DBench pub name body) = DBench pub name (mapExpr f body)
mapDecl f (DAttrib attrs d) = DAttrib attrs (mapDecl f d)
mapDecl _ d = d

mapIfaceMethod : (Expr -> Expr) -> IfaceMethod -> IfaceMethod
mapIfaceMethod _ (IfaceMethod n ty None) = IfaceMethod n ty None
mapIfaceMethod f (IfaceMethod n ty (Some (MethodDefault ps e))) =
  IfaceMethod n ty (Some (MethodDefault ps (mapExpr f e)))

mapImplMethod : (Expr -> Expr) -> ImplMethod -> ImplMethod
mapImplMethod f (ImplMethod n ps e) = ImplMethod n ps (mapExpr f e)

-- exported: the method_marker stage reuses this bottom-up traversal engine
export mapProg : (Expr -> Expr) -> List Decl -> List Decl
mapProg f prog = map (mapDecl f) prog

-- ── AST smart constructors (shared by the sugar + derive passes) ──────────
-- Tiny builders for the AST shapes that recur across this file's passes, so a
-- pass body reads as its intent rather than nested constructor boilerplate.

-- binary application of a named function: `f a b`
callBin : String -> Expr -> Expr -> Expr
callBin fn a b = EApp (EApp (EVar fn) a) b

-- binary operator, not yet resolved: `a <op> b`
binOp : String -> Expr -> Expr -> Expr
binOp op a b = EBinOp op a b (Ref RNone)

-- an integer literal in EXPRESSION position.  `ENumLit`, never `ELit (LInt)` —
-- that is the shape the parser emits and the only one dictPass rewrites away.
intLit : Int -> Expr
intLit n = ENumLit n (Ref None) (Ref RNone) ""

-- a derived impl head with the fixed pub / non-default / no-name shape;
-- applyDeriveParams rewrites tys + reqs afterwards for the type's params.
derivedImpl : String -> String -> List ImplMethod -> Decl
derivedImpl iface tyName methods = DImpl {
  pub = True,
  iface = iface,
  tys = [TyCon tyName None],
  reqs = [],
  methods = methods,
}

-- two-parameter impl method: `m a b = body`
binMethod : String -> String -> String -> Expr -> ImplMethod
binMethod m a b body = ImplMethod m [PVar a, PVar b] body

-- ── Pass: desugar_sugar (guards / function / sections / interpolation) ────
-- Mirror of lib/desugar.ml's rewrite_sugar, applied bottom-up by mapProg.
rewriteSugar : Expr -> Expr
rewriteSugar (EGuards arms) = guardsToCore arms
rewriteSugar (ESection s) = sectionToCore s
rewriteSugar (EStringInterp parts) = interpToCore parts
-- `x := e` (reference write) → `setRef x e` (the existing `<Mut>` extern).
-- Pure surface sugar: no dedicated typecheck/eval arm — the application flows
-- through `setRef`'s signature (`Ref a -> a -> <Mut> Unit`), so a non-`Ref` LHS
-- is a type error at the call site.
rewriteSugar (EBinOp ":=" lhs rhs _) = callBin "setRef" lhs rhs
-- `a[i]` / `a.[i]` (read position) → `index a i` (Index interface dispatch).
rewriteSugar (EIndex a i _) = callBin "index" a i
rewriteSugar e = e

-- ── Pass: rewrite_assign_index (`a[i] := v` → `setIndex a i v`) ───────────
-- Runs BEFORE rewriteSugar.  Because mapExpr is post-order, the EIndex LHS of a
-- `:=` would be rewritten to `index a i` before the parent `:=` node is ever
-- visited, so a single combined arm on rewriteSugar could never fire.  This
-- first pass discriminates the `:=` LHS while the EIndex node is still intact;
-- a non-EIndex LHS is left as a plain `:=` for rewriteSugar to lower to setRef.
rewriteAssignIndex : Expr -> Expr
rewriteAssignIndex (EBinOp ":=" lhs v r) =
  assignIndexLhs (stripLocE lhs) lhs v r
rewriteAssignIndex e = e

assignIndexLhs : Expr -> Expr -> Expr -> Ref Route -> Expr
assignIndexLhs (EIndex a i _) _ v _ = EApp (callBin "setIndex" a i) v
assignIndexLhs _ lhs v r = EBinOp ":=" lhs v r

-- Peel transparent ELoc wrappers so the LHS shape is visible (mirror of the
-- parser's local `stripLoc`).
stripLocE : Expr -> Expr
stripLocE (ELoc _ e) = stripLocE e
stripLocE e = e

-- guard arms → nested if/match, terminated by `__fallthrough__ ()` (fold_right)
guardsToCore : List GuardArm -> Expr
guardsToCore [] = fallthrough
guardsToCore ((GuardArm quals body)::rest) =
  armChain quals body (guardsToCore rest)

fallthrough : Expr
fallthrough = EApp (EVar fallthroughName) (ELit LUnit)

armChain : List Guard -> Expr -> Expr -> Expr
armChain [] body _ = body
armChain ((GBool e)::qs) body els = EIf e (armChain qs body els) els
armChain ((GBind p e)::qs) body els =
  EMatch e [Arm p [] (armChain qs body els), Arm PWild [] els]

-- operator sections → lambdas
sectionToCore : Section -> Expr
sectionToCore (SecBare op) =
  ELam [PVar "_a", PVar "_b"] (binOp op (EVar "_a") (EVar "_b"))
sectionToCore (SecRight op e) = ELam [PVar "_s"] (binOp op (EVar "_s") e)
sectionToCore (SecLeft e op) = ELam [PVar "_s"] (binOp op e (EVar "_s"))

-- `"a\{e}b"` → `"a" ++ display e ++ "b"` (left-associated `++`)
interpToCore : List InterpPart -> Expr
interpToCore parts = concatStrings (map interpPartToExpr parts)

interpPartToExpr : InterpPart -> Expr
interpPartToExpr (InterpStr s) = ELit (LString s)
interpPartToExpr (InterpExpr e) = EApp (EVar "display") e

concatStrings : List Expr -> Expr
concatStrings [] = ELit (LString "")
concatStrings [x] = x
concatStrings (first::rest) = concatLeft first rest

concatLeft : Expr -> List Expr -> Expr
concatLeft acc [] = acc
concatLeft acc (e::rest) = concatLeft (binOp "++" acc e) rest

-- ── Pass: lower_do_blocks (do-notation → andThen/pure chains) ─────────────
-- Mirror of lib/desugar.ml's rewrite_do/lower_do.  Only EDo is lowered; bare
-- EBlock survives (the reference leaves it for eval).  The do_tag the reference
-- EDo carries is ignored by lowering, so the self-host EDo (no tag) suffices.
-- check_do_wellformed (which rejects DoAssign/DoFieldAssign/empty in a do-block)
-- is validation-only and skipped — those never appear in a well-formed EDo.
rewriteDo : Expr -> Expr
rewriteDo (EDo stmts) = wrapDoOrigin stmts (lowerDo stmts)
rewriteDo e = e

-- Phase 150: wrap the lowered chain in a transparent EDoOrigin carrying the
-- do-block's loc (the first statement's position) so a monad-constraint failure
-- surfaces as a tailored "do requires a monad" error instead of a baffling deep
-- `Type mismatch`.  A single trailing `do { e }` lowers to bare `e` (no monad
-- obligation) — leave it unwrapped so non-do expressions aren't mis-blamed.
wrapDoOrigin : List DoStmt -> Expr -> Expr
wrapDoOrigin [DoExpr _] lowered = lowered
wrapDoOrigin stmts lowered = match firstDoStmtLoc stmts
  Some l => EDoOrigin l lowered
  None => lowered

firstDoStmtLoc : List DoStmt -> Option Loc
firstDoStmtLoc [] = None
firstDoStmtLoc (s::rest) = match doStmtLoc s
  Some l => Some l
  None => firstDoStmtLoc rest

doStmtLoc : DoStmt -> Option Loc
doStmtLoc (DoExpr e) = exprLoc e
doStmtLoc (DoBind _ e) = exprLoc e
doStmtLoc (DoLet _ _ _ e) = exprLoc e
doStmtLoc (DoAssign _ e) = exprLoc e
doStmtLoc (DoFieldAssign _ _ e) = exprLoc e

exprLoc : Expr -> Option Loc
exprLoc (ELoc l _) = Some l
exprLoc (EApp f _) = exprLoc f
exprLoc _ = None

lowerDo : List DoStmt -> Expr
lowerDo [DoExpr e] = e
lowerDo [DoBind pat e] =
  callBin "andThen" e (doCont pat (EApp (EVar "pure") (ELit LUnit)))
lowerDo ((DoExpr e)::rest) = callBin "andThen" e (ELam [PWild] (lowerDo rest))
lowerDo ((DoBind pat e)::rest) = callBin "andThen" e (doCont pat (lowerDo rest))
lowerDo ((DoLet _ isFun pat e)::rest) = ELet False isFun pat e (lowerDo rest)
lowerDo _ = fallthrough

-- bind continuation: a bare lambda for an irrefutable pattern, else a 1-arg
-- lambda + 2-arm match whose wildcard arm fails (do_bind_fail = fallthrough)
doCont : Pat -> Expr -> Expr
doCont pat body
  | isRefutable pat = ELam [PVar "__do_x"] (EMatch (EVar "__do_x") [Arm pat [] body, Arm PWild [] fallthrough])
  | otherwise = ELam [pat] body

isRefutable : Pat -> Bool
isRefutable (PVar _) = False
isRefutable PWild = False
isRefutable (PLit _) = True
isRefutable (PCon _ _) = True
isRefutable (PCons _ _) = True
isRefutable (PList _) = True
isRefutable (PRng _ _ _) = True
isRefutable (PRec _ _ _) = True
isRefutable (PTuple ps) = anyRefutable ps
isRefutable (PAs _ p) = isRefutable p

anyRefutable : List Pat -> Bool
anyRefutable [] = False
anyRefutable (p::ps) = isRefutable p || anyRefutable ps

-- ── Pass: expand_decl (`deriving` → generated impls) ──────────────────────
-- Mirror of lib/desugar.ml's expand_decl + the Eq/Debug/Display/Ord/Generic
-- derivers, PLUS `Hashable` (#422), which has no counterpart in the reference —
-- it generates the djb2 fold core.mdk's `Hashable` doc specifies.  A
-- `data`/`newtype` with derives becomes the decl (derives cleared)
-- followed by one generated impl per derived interface; a `newtype` derives via
-- a synthetic single-variant data deriver.  Generated bodies are core (no sugar),
-- so they pass through the later passes unchanged.  Generated names are
-- positional (`__a%d`/`__b%d`) — deterministic, matching the reference.
-- (Record derives, Arbitrary, and newtype Num/Generic remain deferred.  The old
-- note here claimed they were "not exercised by the corpus"; that was FALSE —
-- test/ported/test_eval_ported.mdk derives `Num` AND `Generic` on newtypes and
-- only passes because the bindings that use them (`distRN`, `genNewtypeName`)
-- are dead: no test forces them, and a top-level nullary is lazy.  `checkDerives`
-- below now reports those sites instead of dropping them silently — #421.)
expandDecl : Decl -> List Decl
expandDecl (DData vis name params variants derives) =
  DData vis name params variants [] ::
    deriveImpls (deriveForData name params variants) derives
expandDecl (DNewtype vis name params con fty derives) =
  DNewtype vis name params con fty [] ::
    deriveImpls (deriveForNewtype name params con fty) derives
expandDecl (DAttrib attrs d) = attribHead attrs (expandDecl d)
expandDecl d = [d]

-- DAttrib wraps a single decl; expanding the inner decl may yield generated
-- impls — keep the attribute on the head, leave the impls bare (lib/desugar.ml).
attribHead : List Attr -> List Decl -> List Decl
attribHead _ [] = []
attribHead attrs (first::rest) = DAttrib attrs first :: rest

deriveImpls : (String -> Option Decl) -> List DeriveRef -> List Decl
deriveImpls _ [] = []
deriveImpls f (d::ds) = match f (deriveRefName d)
  Some gen => gen :: deriveImpls f ds
  None => deriveImpls f ds

-- Every `data` deriver, keyed by the name that selects it in `deriving (…)`.
-- This list is THE single source of truth: `deriveForData` looks a name up here,
-- and the "supported: …" copy in the unknown-derive diagnostic (#421) is
-- `map fst` of this same list — so a deriver added later (#422's `Hashable`)
-- both starts working AND starts being advertised by the message, with no
-- hand-typed list to rot.
-- The generator is a THUNK on purpose: Medaka is strict, so an eager
-- `List (String, Decl)` would run every deriver on every lookup.
dataDerivers : String -> List String -> List Variant -> List (String, Unit -> Decl)
dataDerivers name params variants = [
  ("Eq", _ => applyDeriveParams name params (deriveEqData name variants)),
  ("Ord", _ => applyDeriveParams name params (deriveOrdData name variants)),
  (
    "Debug",
    _ => applyDeriveParams name params (deriveShowData "Debug" "debug" name variants),
  ),
  (
    "Display",
    _ => applyDeriveParams name params (deriveShowData "Display" "display" name variants),
  ),
  (
    "Generic",
    _ => applyDeriveParams name params (deriveGenericData name variants),
  ),
  (
    "Hashable",
    _ => applyDeriveParams name params (deriveHashData name variants),
  ),
]

-- Force the deriver `iface` selects, or None when no deriver claims the name.
lookupDeriver : String -> List (String, Unit -> Decl) -> Option Decl
lookupDeriver _ [] = None
lookupDeriver n ((k, f)::rest)
  | n == k = Some (f ())
  | otherwise = lookupDeriver n rest

deriveForData : String -> List String -> List Variant -> String -> Option Decl
deriveForData name params variants iface =
  lookupDeriver iface (dataDerivers name params variants)

-- A newtype is structurally a single-constructor, single-field data type, so the
-- data derivers produce the right tagged rendering via a synthetic variant.
-- The newtype deriver table — the newtype counterpart of `dataDerivers`, and
-- likewise the single source of both the lookup and the diagnostic's copy.
-- It is deliberately SHORTER than `dataDerivers`: `Generic` (and `Num`) go
-- through specialized newtype derivers in lib/desugar.ml that this port has not
-- taken, so a newtype genuinely cannot derive them here.  Keeping the two tables
-- separate is what stops the diagnostic from advertising `Generic` on a newtype
-- that cannot have it.
newtypeDerivers : String -> List String -> String -> Ty -> List (String, Unit -> Decl)
newtypeDerivers name params con fty =
  let synthetic = [Variant con (ConPos [fty])]
  [
    ("Eq", _ => applyDeriveParams name params (deriveEqData name synthetic)),
    ("Ord", _ => applyDeriveParams name params (deriveOrdData name synthetic)),
    (
      "Debug",
      _ => applyDeriveParams name params (deriveShowData "Debug" "debug" name synthetic),
    ),
    (
      "Display",
      _ => applyDeriveParams name params (deriveShowData "Display" "display" name synthetic),
    ),
    -- Hashable needs no specialized newtype deriver: the synthetic variant is
    -- ordinal 0 with one field, so the fold collapses to `0 * 33 + hash x` —
    -- exactly "hash the wrapped value", which is what a newtype key should do.
    (
      "Hashable",
      _ => applyDeriveParams name params (deriveHashData name synthetic),
    ),
  ]

deriveForNewtype : String -> List String -> String -> Ty -> String -> Option Decl
deriveForNewtype name params con fty iface =
  lookupDeriver iface (newtypeDerivers name params con fty)

-- ── Pass: unknown `deriving (…)` names (standalone, pre-desugar) ─────────────
-- `expandDecl` DROPS any derive name it has no deriver for, so `deriving (Banana)`
-- generated nothing and said nothing (#421): the failure surfaced later and
-- elsewhere as "No impl of Banana for X" at the first use site — or never, when the
-- impl was only needed on a rare path.  This standalone pass reports each such
-- name.  It must run on the RAW pre-desugar AST because that is the only tree that
-- still HAS the derives (`expandDecl` clears the field), exactly like
-- `checkGuardExhaustiveness`'s standalone pass over the surface `EGuards` shape.
-- Pure: it returns messages + locs and the driver pushes them, so errors keep
-- accumulating rather than raising here.
export checkDerives : List Decl -> List (String, Option Loc)
checkDerives decls = flatMap declDeriveErrors decls

-- The `match derives` guard is load-bearing, not style: Medaka is strict, so
-- passing `map fst (dataDerivers …)` to a decl with NO derives would still build
-- the deriver table for every `data` in the program.
declDeriveErrors : Decl -> List (String, Option Loc)
declDeriveErrors (DData _ name params variants derives) = match derives
  [] => []
  _ => flatMap (unknownDerive name (map fst (dataDerivers name params variants))) derives
declDeriveErrors (DNewtype _ name params con fty derives) = match derives
  [] => []
  _ => flatMap (unknownDerive name (map fst (newtypeDerivers name params con fty))) derives
declDeriveErrors (DAttrib _ d) = declDeriveErrors d
declDeriveErrors _ = []

unknownDerive : String -> List String -> DeriveRef -> List (String, Option Loc)
unknownDerive tyName supported (DeriveRef n loc)
  | contains n supported = []
  | otherwise = [(cannotDeriveMsg tyName supported n, loc)]

-- Reports what was OBSERVED (no deriver claims this name), not a conclusion
-- ("unknown interface") — `Num` IS a real interface, it just has no deriver here.
cannotDeriveMsg : String -> List String -> String -> String
cannotDeriveMsg tyName supported n =
  "cannot derive '\{n}' for '\{tyName}'; supported: \{joinWith ", " supported}"

-- rewrite a generated impl's head/constraints for the type's params:
-- `data Box a deriving Eq` → `impl Eq (Box a) requires Eq a`
applyDeriveParams : String -> List String -> Decl -> Decl
applyDeriveParams name params (d@(DImpl { iface, ... })) = DImpl { d | tys = [appliedHead name params], reqs = paramRequires iface params }
applyDeriveParams _ _ d = d

appliedHead : String -> List String -> Ty
appliedHead name params = appliedHeadGo (TyCon name None) params

appliedHeadGo : Ty -> List String -> Ty
appliedHeadGo acc [] = acc
appliedHeadGo acc (p::ps) = appliedHeadGo (TyApp acc (TyVar p)) ps

paramRequires : String -> List String -> List Require
paramRequires iface params = map (paramReq iface) params

paramReq : String -> String -> Require
paramReq iface p = Require iface [TyVar p]

conArity : Variant -> Int
conArity (Variant _ (ConPos tys)) = listLen tys
conArity (Variant _ (ConNamed fs _)) = listLen fs

-- positional binder names: genVars "__a" 2 = ["__a0", "__a1"]
genVars : String -> Int -> List String
genVars prefix n = genVarsGo prefix 0 n

genVarsGo : String -> Int -> Int -> List String
genVarsGo prefix i n
  | i >= n = []
  | otherwise = prefix ++ intToString i :: genVarsGo prefix (i + 1) n

-- Bind a variant's fields to the positional binder vars the derived body uses.
-- A positional (ConPos) variant yields `PCon C [PVar v0, …]`. A named-field
-- (ConNamed / record-shaped) variant yields a record pattern
-- `PRec C { f0 = v0, … }`: eval represents a named-field constructor value as
-- VRecord, which a positional `PCon` cannot match (only `PRec` can), whereas the
-- emitter accepts both — so PRec makes the derived match work in BOTH pipelines.
conBindPat : Variant -> List String -> Pat
conBindPat (Variant cname (ConPos _)) vars = PCon cname (map PVar vars)
conBindPat (Variant cname (ConNamed fs _)) vars =
  PRec cname (recPatFields fs vars) False

recPatFields : List Field -> List String -> List RecPatField
recPatFields [] _ = []
recPatFields _ [] = []
recPatFields ((Field n _)::fs) (v::vs) =
  RecPatField n (Some (PVar v)) :: recPatFields fs vs

-- Debug and Display share the rendering ("Con " ++ <call> a0 ++ " " ++ …);
-- only the interface + method-call name differ.
deriveShowData : String -> String -> String -> List Variant -> Decl
deriveShowData iface callName name variants = derivedImpl
  iface
  name
  [
    ImplMethod callName [PVar "__x"] (EMatch (EVar "__x") (map (showArm callName) variants))
  ]

showArm : String -> Variant -> Arm
showArm callName (v@(Variant cname payload)) =
  let vars = genVars "__a" (conArity v)
  Arm (conBindPat v vars) [] (showBody callName cname payload vars)

-- A positional variant renders `Con a0 a1 …`; a named-field (ConNamed /
-- record-shaped) variant renders `Con { f0 = a0, f1 = a1, … }`, matching the
-- surface record literal syntax.
showBody : String -> String -> ConPayload -> List String -> Expr
showBody _ cname _ [] = ELit (LString cname)
showBody callName cname (ConNamed fs _) (v::vs) =
  concatStrings
    (ELit (LString (cname ++ " {")) :: showNamedParts callName 0 fs (v::vs) ++ [ELit (LString " }")])
showBody callName cname _ (v::vs) =
  concatStrings
    (ELit (LString (cname ++ " ")) :: showFieldParts callName 0 (v::vs))

showFieldParts : String -> Int -> List String -> List Expr
showFieldParts _ _ [] = []
showFieldParts callName i (v::vs) = showFieldPart callName i v
  ++ showFieldParts callName (i + 1) vs

-- Nested field args are wrapped through the prelude's `derivedShowWrap`
-- (`core.mdk`) so a nested constructor application stays parenthesized —
-- `Branch (Branch (Leaf 1) (Leaf 2)) (Leaf 3)`, not
-- `Branch Branch Leaf 1 Leaf 2 Leaf 3`. See `core.mdk` for the full rationale
-- (shared unchanged by both `Debug` and `Display`, since they run through
-- this exact same generator and neither documents a different contract here).
showFieldPart : String -> Int -> String -> List Expr
showFieldPart callName 0 v = [wrappedFieldCall callName v]
showFieldPart callName _ v = [ELit (LString " "), wrappedFieldCall callName v]

wrappedFieldCall : String -> String -> Expr
wrappedFieldCall callName v =
  EApp (EVar "derivedShowWrap") (EApp (EVar callName) (EVar v))

-- ` f0 = <call> a0, f1 = <call> a1, …` inside the record braces.
showNamedParts : String -> Int -> List Field -> List String -> List Expr
showNamedParts _ _ [] _ = []
showNamedParts _ _ _ [] = []
showNamedParts callName i ((Field fn _)::fs) (v::vs) = showNamedPart callName i fn v
  ++ showNamedParts callName (i + 1) fs vs

showNamedPart : String -> Int -> String -> String -> List Expr
showNamedPart callName 0 fn v =
  [ELit (LString " \{fn} = "), EApp (EVar callName) (EVar v)]
showNamedPart callName _ fn v =
  [ELit (LString ", \{fn} = "), EApp (EVar callName) (EVar v)]

-- Eq: same-constructor arms compare fields pairwise; a cross-constructor
-- wildcard arm (only with ≥2 variants) returns False.
deriveEqData : String -> List Variant -> Decl
deriveEqData name variants = derivedImpl
  "Eq"
  name
  [
    binMethod "eq" "__x" "__y" (EMatch (ETuple [EVar "__x", EVar "__y"]) (eqArms variants))
  ]

eqArms : List Variant -> List Arm
eqArms variants
  | listLen variants > 1 = map eqSameConArm variants
    ++ [Arm (PTuple [PWild, PWild]) [] (EVar "False")]
  | otherwise = map eqSameConArm variants

eqSameConArm : Variant -> Arm
eqSameConArm (v@(Variant _ _)) =
  let n = conArity v
  Arm
    (PTuple [conBindPat v (genVars "__a" n), conBindPat v (genVars "__b" n)])
    []
    (eqBody n (genVars "__a" n) (genVars "__b" n))

eqBody : Int -> List String -> List String -> Expr
eqBody 0 _ _ = EVar "True"
eqBody _ avars bvars = andAll (zipEqCalls avars bvars)

zipEqCalls : List String -> List String -> List Expr
zipEqCalls [] _ = []
zipEqCalls _ [] = []
zipEqCalls (a::arest) (b::brest) =
  callBin "eq" (EVar a) (EVar b) :: zipEqCalls arest brest

andAll : List Expr -> Expr
andAll [] = EVar "True"
andAll (first::rest) = andLeft first rest

andLeft : Expr -> List Expr -> Expr
andLeft acc [] = acc
andLeft acc (e::rest) = andLeft (binOp "&&" acc e) rest

-- Ord: one arm per (i, vi)×(j, vj) constructor pair.  Different constructors
-- compare by declaration order (Lt/Gt); same constructor compares fields
-- lexicographically.  Mirror of lib/desugar.ml's derive_ord_data.
deriveOrdData : String -> List Variant -> Decl
deriveOrdData name variants = derivedImpl
  "Ord"
  name
  [
    binMethod "compare" "__x" "__y" (EMatch (ETuple [EVar "__x", EVar "__y"]) (ordArms variants))
  ]

ordArms : List Variant -> List Arm
ordArms variants =
  let indexed = indexFrom 0 variants
  flatMap (ordRow indexed) indexed

indexFrom : Int -> List a -> List (Int, a)
indexFrom _ [] = []
indexFrom i (x::xs) = (i, x) :: indexFrom (i + 1) xs

ordRow : List (Int, Variant) -> (Int, Variant) -> List Arm
ordRow indexed (i, vi) = map (ordCell i vi) indexed

ordCell : Int -> Variant -> (Int, Variant) -> Arm
ordCell i vi (j, vj) =
  let avars = genVars "__a" (conArity vi)
  let bvars = genVars "__b" (conArity vj)
  Arm
    (PTuple [conBindPat vi avars, conBindPat vj bvars])
    []
    (ordBody i j avars bvars)

ordBody : Int -> Int -> List String -> List String -> Expr
ordBody i j avars bvars
  | i < j = EVar "Lt"
  | i > j = EVar "Gt"
  | otherwise = lexCompareExprs (zipExprPairs avars bvars)

zipExprPairs : List String -> List String -> List (Expr, Expr)
zipExprPairs [] _ = []
zipExprPairs _ [] = []
zipExprPairs (a::arest) (b::brest) =
  (EVar a, EVar b) :: zipExprPairs arest brest

-- Lexicographic chain: `compare a b` per pair, short-circuiting on the first
-- non-Eq result.  Mirror of lib/desugar.ml's lex_compare_exprs.
lexCompareExprs : List (Expr, Expr) -> Expr
lexCompareExprs [] = EVar "Eq"
lexCompareExprs [(ea, eb)] = callBin "compare" ea eb
lexCompareExprs ((ea, eb)::rest) = EMatch
  (callBin "compare" ea eb)
  [
    Arm (PCon "Eq" []) [] (lexCompareExprs rest),
    Arm (PVar "__c") [] (EVar "__c"),
  ]

-- Hashable: the djb2-style fold core.mdk's `Hashable` doc specifies — seed the
-- accumulator with the constructor's ordinal, then `acc = acc * 33 + hash field`
-- left-to-right.  One arm per constructor, so the ordinal seed is what keeps
-- `A 1` and `B 1` apart.  This is the SAME fold the hand-written compound impls
-- next to that doc use (`hash (a, b) = hash a * 33 + hash b`, `hashListItems`),
-- which is why a derived and a hand-written impl of the same shape agree.
--
-- Deliberately does NOT mask the result non-negative.  `Int` wraps, so the fold
-- goes negative routinely — that is safe and intended: the `Hashable` contract
-- requires only that equal values hash equal, never non-negativity, and both
-- consumers mask at the point of use (`slotOf` in hash_map/hash_set, #416).
-- Masking here would buy nothing, cost a bit of hash space, and make derived
-- impls silently disagree with the unmasked compound impls in core.mdk.
deriveHashData : String -> List Variant -> Decl
deriveHashData name variants = derivedImpl
  "Hashable"
  name
  [
    ImplMethod "hash" [PVar "__x"] (EMatch (EVar "__x") (map hashArm (indexFrom 0 variants)))
  ]

hashArm : (Int, Variant) -> Arm
hashArm (i, v) =
  let vars = genVars "__a" (conArity v)
  Arm (conBindPat v vars) [] (hashFold (intLit i) vars)

-- `acc * 33 + hash field` per field, left-to-right.  A field-less constructor
-- hashes to its bare ordinal (matching core.mdk's `hash None = 1`).
hashFold : Expr -> List String -> Expr
hashFold acc [] = acc
hashFold acc (v::vs) =
  hashFold
    (binOp "+" (binOp "*" acc (intLit 33)) (EApp (EVar "hash") (EVar v)))
    vs

-- Generic: one arm per constructor → RCon name [to_rep a0, …]
deriveGenericData : String -> List Variant -> Decl
deriveGenericData name variants = derivedImpl
  "Generic"
  name
  [
    ImplMethod "to_rep" [PVar "__x"] (EMatch (EVar "__x") (map genericArm variants))
  ]

genericArm : Variant -> Arm
genericArm (v@(Variant cname payload)) =
  let vars = genVars "__a" (conArity v)
  Arm (conBindPat v vars) [] (genericRep cname payload vars)

-- Positional variant → `RCon name [to_rep a0, …]`; named-field (record-shaped)
-- variant → `RRecord name [RField { fld_name = "f", fld_rep = to_rep a0 }, …]`,
-- so `to_rep` reflects the field labels a record carries.
genericRep : String -> ConPayload -> List String -> Expr
genericRep cname (ConNamed fs _) vars =
  callBin "RRecord" (ELit (LString cname)) (EListLit (genericRFields fs vars))
genericRep cname _ vars =
  callBin "RCon" (ELit (LString cname)) (EListLit (map toRep vars))

genericRFields : List Field -> List String -> List Expr
genericRFields [] _ = []
genericRFields _ [] = []
genericRFields ((Field fn _)::fs) (v::vs) =
  ERecordCreate
      "RField"
      [
        FieldAssign "fld_name" (ELit (LString fn)),
        FieldAssign "fld_rep" (toRep v),
      ] ::
    genericRFields fs vs

toRep : String -> Expr
toRep x = EApp (EVar "to_rep") (EVar x)

-- ── Pass: merge_iface_defaults (coalesce split interface-method entries) ──
-- The parser splits an interface method with both a signature line (`f : T`,
-- default None) and a default-clause line (`f p = body`, type TyVar "_", Some)
-- into two entries; merge them by name into one (first-seen position, the real
-- type, the present default).  Mirror of lib/desugar.ml's merge_iface_methods.
mergeIfaceDefaults : List Decl -> List Decl
mergeIfaceDefaults prog = map mergeIfaceDecl prog

mergeIfaceDecl : Decl -> Decl
mergeIfaceDecl (d@(DInterface { methods, ... })) =
  DInterface { d | methods = mergeIfaceMethods methods }
mergeIfaceDecl d = d

mergeIfaceMethods : List IfaceMethod -> List IfaceMethod
mergeIfaceMethods methods = foldlMethods [] methods

foldlMethods : List IfaceMethod -> List IfaceMethod -> List IfaceMethod
foldlMethods acc [] = acc
foldlMethods acc (m::rest) = foldlMethods (insertMethod acc m) rest

insertMethod : List IfaceMethod -> IfaceMethod -> List IfaceMethod
insertMethod acc m
  | containsMethod (methodName m) acc = mergeInto acc m
  | otherwise = acc ++ [m]

mergeInto : List IfaceMethod -> IfaceMethod -> List IfaceMethod
mergeInto [] m = [m]
mergeInto (x::xs) m
  | methodName x == methodName m = mergeTwo x m :: xs
  | otherwise = x :: mergeInto xs m

mergeTwo : IfaceMethod -> IfaceMethod -> IfaceMethod
mergeTwo (IfaceMethod n prevTy prevDef) (IfaceMethod _ mTy mDef) =
  IfaceMethod n (mergedType prevTy mTy) (mergedDefault prevDef mDef)

mergedType : Ty -> Ty -> Ty
mergedType (TyVar "_") mTy = mTy
mergedType prevTy _ = prevTy

mergedDefault : Option MethodDefault -> Option MethodDefault -> Option MethodDefault
mergedDefault (Some d) _ = Some d
mergedDefault None mDef = mDef

containsMethod : String -> List IfaceMethod -> Bool
containsMethod _ [] = False
containsMethod name (x::xs) = methodName x == name || containsMethod name xs

methodName : IfaceMethod -> String
methodName (IfaceMethod n _ _) = n

-- ── Pass: fill_impl_defaults (specialize interface defaults per impl) ──
-- For each DImpl, synthesize a concrete-receiver ImplMethod for every interface
-- default method the impl does not explicitly define.  The synthesized clause is
-- byte-identical to the hand-written per-impl form (receiver concreteness comes
-- from the impl's type, not the body text); the tagged copy is strictly more
-- specific than the untagged `lowerDefault` fallback, so `coalesceImpls` picks
-- it.  Universal across all interfaces; same-module only (sees just DInterface
-- defaults co-located in this decl list — a user impl of a prelude interface in
-- another module keeps using the fallback, as intended).  Runs after
-- mergeIfaceDefaults (so each IfaceMethod carries its merged default) and before
-- the later sugar passes (so the copied body lowers exactly like the original).
-- See TRAVERSABLE-DEFAULT-METHOD-DESIGN.md Fork 1.
fillImplDefaults : List Decl -> List Decl
fillImplDefaults prog = map (fillImplDecl prog) prog

fillImplDecl : List Decl -> Decl -> Decl
fillImplDecl prog (d@DImpl { iface, methods, ... })
  -- UNIVERSAL: every interface's missing defaults are specialized per impl, with no
  -- exclusions.  Ord and Foldable were formerly held back because their specialized
  -- defaults tripped two emitter dict-threading gaps, both now CLOSED (see
  -- TRAVERSABLE-DEFAULT-METHOD-DESIGN.md §9):
  --   * Ord — registerImplRequires keys EVERY method of an impl under the same impl
  --     tyvar id, so specializing lt/gt/min/max alongside compare made the global
  --     route lookup return the LAST-registered `$dict_<m>_<slot>` for ALL bodies
  --     (compare's element dispatch wrongly forwarded `$dict_max_0` → "unbound dict
  --     witness").  Fixed by encl-aware requires routing (typecheck.mdk
  --     activeDictVarForEncl / argImplDictRoutesForEncl).
  --   * Foldable — `foldMap f = fold (acc x => acc ++ f x) empty` is ETA-SHORT (binds
  --     only `f` + its `Monoid m` dict, returns a partial awaiting the container); the
  --     tagged copy wasn't eta-expanded so a saturated call dropped the container and
  --     returned an unapplied PAP → SIGSEGV.  Fixed by counting leading dict params in
  --     gatherGroup's eta-expansion target (llvm_emit.mdk).
  | otherwise = DImpl { d | methods = methods ++ synthDefaultMethods methods (ifaceDefaults iface prog) }
fillImplDecl _ d = d

-- The named interface's default methods (those carrying a MethodDefault body).
ifaceDefaults : String -> List Decl -> List IfaceMethod
ifaceDefaults _ [] = []
ifaceDefaults target (d::rest) = ifaceDefaultsStep target d rest

ifaceDefaultsStep : String -> Decl -> List Decl -> List IfaceMethod
ifaceDefaultsStep target (DInterface { name, methods, ... }) rest
  | name == target = filterList ifaceMethodHasDefault methods
  | otherwise = ifaceDefaults target rest
ifaceDefaultsStep target _ rest = ifaceDefaults target rest

ifaceMethodHasDefault : IfaceMethod -> Bool
ifaceMethodHasDefault (IfaceMethod _ _ (Some _)) = True
ifaceMethodHasDefault (IfaceMethod _ _ None) = False

-- Synthesize an ImplMethod from each default whose name is not already explicit.
synthDefaultMethods : List ImplMethod -> List IfaceMethod -> List ImplMethod
synthDefaultMethods _ [] = []
synthDefaultMethods explicit (m::rest)
  | implDefines (methodName m) explicit = synthDefaultMethods explicit rest
  | otherwise = synthFromDefault m :: synthDefaultMethods explicit rest

implDefines : String -> List ImplMethod -> Bool
implDefines name explicit = anyList (implMethodNamed name) explicit

implMethodNamed : String -> ImplMethod -> Bool
implMethodNamed name (ImplMethod n _ _) = n == name

synthFromDefault : IfaceMethod -> ImplMethod
synthFromDefault (IfaceMethod n _ (Some (MethodDefault ps body))) =
  ImplMethod n ps body
synthFromDefault (IfaceMethod n _ None) = ImplMethod n [] (EVar n)

concatMapDecl : (Decl -> List Decl) -> List Decl -> List Decl
concatMapDecl f prog = concatLists (map f prog)

concatLists : List (List a) -> List a
concatLists [] = []
concatLists (xs::rest) = xs ++ concatLists rest

-- ── Pass: desugar_record_puns ────────────────────────────────────────────
-- `Name { a, b }` (all bare vars, no `=`) parses as ESetLit; when Name is a
-- record type this is pun sugar for `Name { a = a, b = b }` → ERecordCreate.
-- Runs before container-literal lowering so genuine Map/Set literals remain.
-- Mirror of lib/desugar.ml's desugar_record_puns.
desugarRecordPuns : List Decl -> List Decl
desugarRecordPuns prog =
  mapProg (rewriteRecordPun (collectRecordNames prog)) prog

-- Names that can head a record-literal brace = every ConNamed constructor of a
-- `data` decl (records are the `data X = { … }` short form, whose synthesized
-- ctor is the type name; explicit named-payload ctors `data T = MkT { … }`
-- qualify too).
collectRecordNames : List Decl -> List String
collectRecordNames [] = []
collectRecordNames ((DData _ _ _ variants _)::rest) = conNamedCtorNames variants
  ++ collectRecordNames rest
collectRecordNames (_::rest) = collectRecordNames rest

conNamedCtorNames : List Variant -> List String
conNamedCtorNames [] = []
conNamedCtorNames ((Variant n (ConNamed _ _))::rest) =
  n :: conNamedCtorNames rest
conNamedCtorNames ((Variant _ (ConPos _))::rest) = conNamedCtorNames rest

rewriteRecordPun : List String -> Expr -> Expr
rewriteRecordPun recordNames (ESetLit name items)
  | contains name recordNames && listLen items > 0 && allList isVarExpr items =
    ERecordCreate name (map punField items)
rewriteRecordPun _ e = e

isVarExpr : Expr -> Bool
isVarExpr (ELoc _ e) = isVarExpr e
isVarExpr (EDoOrigin _ e) = isVarExpr e
isVarExpr (EVar _) = True
isVarExpr _ = False

punField : Expr -> FieldAssign
punField (ELoc _ e) = punField e
punField (EDoOrigin _ e) = punField e
punField (EVar n) = FieldAssign n (EVar n)
punField _ = FieldAssign "" (EVar "")

-- ── Pass: lower_container_literals ────────────────────────────────────────
--   Map { k1 => v1, … }  ⇒  (fromEntries [(k1, v1), …] :~ Name _k _v)
--   Set { e1, … }        ⇒  (fromEntries [e1, …]       :~ Name _a)
-- The `:~` head-pin (EHeadAnnot) fixes the result type so `fromEntries`
-- dispatches by the literal's named type.  Mirror of lib/desugar.ml's
-- lower_container_literals (runs after record puns).
lowerContainerLiterals : List Decl -> List Decl
lowerContainerLiterals prog = mapProg rewriteContainerLit prog

rewriteContainerLit : Expr -> Expr
rewriteContainerLit (EMapLit name kvs) = EHeadAnnot
  (EApp (EVar "fromEntries") (EListLit (map kvToTuple kvs)))
  (pinType name [TyVar "_k", TyVar "_v"])
rewriteContainerLit (ESetLit name items) = EHeadAnnot
  (EApp (EVar "fromEntries") (EListLit items))
  (pinType name [TyVar "_a"])
rewriteContainerLit e = e

kvToTuple : (Expr, Expr) -> Expr
kvToTuple (k, v) = ETuple [k, v]

pinType : String -> List Ty -> Ty
pinType name args = pinTypeGo (TyCon name None) args

pinTypeGo : Ty -> List Ty -> Ty
pinTypeGo acc [] = acc
pinTypeGo acc (t::ts) = pinTypeGo (TyApp acc t) ts

-- ── Import aliasing: a qualified reference `A.name` → the flat name `A.name` ──
-- `import m as A` makes every value m exports available as `A.name`.  The grammar has
-- no notion of a qualified name — `A.name` parses as an ordinary FIELD ACCESS on a
-- variable `A` — so lower it here, before resolve, to a plain `EVar "A.name"`.
-- Resolve/typecheck/eval then bind it exactly like any other imported name (the import
-- machinery enters m's exports under precisely these dotted local names), and
-- `backend/private_mangle.mdk` maps it back to m's real symbol.  A dot cannot occur in
-- a surface identifier, so the flat name is collision-free by construction.
--
-- The rewrite is scoped to the aliases THIS file declares, and the parser forces a
-- module alias to be Uppercase — so an ordinary `rec.field` access on a lowercase
-- local can never be captured here.
moduleAliases : List Decl -> List String
moduleAliases [] = []
moduleAliases ((DUse _ (UseAlias _ a) _)::rest) = a :: moduleAliases rest
moduleAliases ((DAttrib _ d)::rest) = moduleAliases [d] ++ moduleAliases rest
moduleAliases (_::rest) = moduleAliases rest

-- No alias in this file ⇒ the identity, so an alias-free program is untouched.
qualifyAliasRefs : List Decl -> List Decl
qualifyAliasRefs prog = match moduleAliases prog
  [] => prog
  aliases => mapProg (rewriteAliasQual aliases) prog

-- The head must be matched THROUGH `ELoc` — the parser wraps every atom in the
-- transparent location wrapper, so the alias reference is `EFieldAccess (ELoc _ (EVar
-- "A")) "f"`, never a bare `EVar`.
rewriteAliasQual : List String -> Expr -> Expr
rewriteAliasQual aliases (e@(EFieldAccess head f _)) = match stripLocE head
  EVar a => if contains a aliases then EVar (qualifiedLocal a f) else e
  _ => e
rewriteAliasQual _ e = e

-- ── The pass pipeline ─────────────────────────────────────────────────────
-- Ported in the reference order (later passes run last): merge_iface_defaults →
-- expand_decl → desugar_record_puns → lower_container_literals →
-- desugar_list_comps → desugar_questions → lower_do_blocks → desugar_sugar.
export desugar : List Decl -> List Decl
desugar prog = qualifyAliasRefs prog
  |> mergeIfaceDefaults
  |> fillImplDefaults
  |> concatMapDecl expandDecl
  |> desugarRecordPuns
  |> lowerContainerLiterals
  |> mapProg rewriteDo
  |> mapProg rewriteAssignIndex
  |> mapProg rewriteSugar
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "Loc" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "qualifiedLocal" false) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Attr" false) (mem "Decl" true) (mem "DeriveRef" true) (mem "deriveRefName" false) (mem "Route" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "joinWith" false) (mem "contains" false) (mem "allList" false) (mem "fallthroughName" false) (mem "filterList" false) (mem "anyList" false))))
(DTypeSig true "mapExpr" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "mapExpr" ((PVar "f") (PVar "e")) (EApp (EVar "f") (EApp (EApp (EVar "mapKids") (EVar "f")) (EVar "e"))))
(DTypeSig false "mapKids" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "a"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "b"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "b"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ELet" (PVar "m") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e1"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e2"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ELetGroup" (PVar "bs") (PVar "e2"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EApp (EVar "mapLetBind") (EVar "f"))) (EVar "bs"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e2"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EVar "mapArm") (EVar "f"))) (EVar "arms"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "c"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "t"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "el"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "a"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "b"))) (EVar "r")))
(DFunDef false "mapKids" ((PVar "f") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "a"))) (EVar "r")))
(DFunDef false "mapKids" ((PVar "f") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "a"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "b"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EVar "n")) (EVar "r")))
(DFunDef false "mapKids" ((PVar "f") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "mapFieldAssign") (EVar "f"))) (EVar "fs"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EVar "mapFieldAssign") (EVar "f"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "mapKids" ((PVar "f") (PCon "EVariantUpdate" (PVar "c") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EVar "mapFieldAssign") (EVar "f"))) (EVar "fs"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EApp (EVar "mapExpr") (EVar "f"))) (EVar "es"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EApp (EVar "mapExpr") (EVar "f"))) (EVar "es"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EApp (EVar "mapExpr") (EVar "f"))) (EVar "es"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EIndex" (PVar "e0") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "i"))) (EVar "r")))
(DFunDef false "mapKids" ((PVar "f") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "lo"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapKids" ((PVar "f") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "lo"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapKids" ((PVar "f") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "incl") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "lo"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "hi"))) (EVar "incl")) (EVar "r")))
(DFunDef false "mapKids" ((PVar "f") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "map") (EApp (EVar "mapDoStmt") (EVar "f"))) (EVar "stmts"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EVar "map") (EApp (EVar "mapDoStmt") (EVar "f"))) (EVar "stmts"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EVar "t")))
(DFunDef false "mapKids" ((PVar "f") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EApp (EVar "mapInterp") (EVar "f"))) (EVar "parts"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EApp (EVar "mapGuardArm") (EVar "f"))) (EVar "arms"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e0")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0")))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ESection" (PCon "SecLeft" (PVar "e0") (PVar "op")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EVar "op"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "mapKv") (EVar "f"))) (EVar "kvs"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "mapExpr") (EVar "f"))) (EVar "es"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EVar "t")))
(DFunDef false "mapKids" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "mapKv" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "mapKv" ((PVar "f") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "k")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "v"))))
(DTypeSig false "mapArm" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "mapArm" ((PVar "f") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "b"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EVar "map") (EApp (EVar "mapGuard") (EVar "f"))) (EVar "gs"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "b"))))
(DTypeSig false "mapGuard" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Guard") (TyCon "Guard"))))
(DFunDef false "mapGuard" ((PVar "f") (PCon "GBool" (PVar "g"))) (EApp (EVar "GBool") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "g"))))
(DFunDef false "mapGuard" ((PVar "f") (PCon "GBind" (PVar "p") (PVar "g"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "g"))))
(DTypeSig false "mapGuardArm" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "mapGuardArm" ((PVar "f") (PCon "GuardArm" (PVar "gs") (PVar "b"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EVar "map") (EApp (EVar "mapGuard") (EVar "f"))) (EVar "gs"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "b"))))
(DTypeSig false "mapLetBind" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "mapLetBind" ((PVar "f") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "mapFunClause") (EVar "f"))) (EVar "clauses"))))
(DTypeSig false "mapFunClause" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "mapFunClause" ((PVar "f") (PCon "FunClause" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "b"))))
(DTypeSig false "mapFieldAssign" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "mapFieldAssign" ((PVar "f") (PCon "FieldAssign" (PVar "n") (PVar "v"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "v"))))
(DTypeSig false "mapDoStmt" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "mapDoStmt" ((PVar "f") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DFunDef false "mapDoStmt" ((PVar "f") (PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DFunDef false "mapDoStmt" ((PVar "f") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DFunDef false "mapDoStmt" ((PVar "f") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DFunDef false "mapDoStmt" ((PVar "f") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DTypeSig false "mapInterp" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "mapInterp" (PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "mapInterp" ((PVar "f") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DTypeSig true "mapDecl" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "mapDecl" ((PVar "f") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DFunDef false "mapDecl" ((PVar "f") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EVar "mapIfaceMethod") (EVar "f"))) (EVar "methods"))))))
(DFunDef false "mapDecl" ((PVar "f") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EVar "mapImplMethod") (EVar "f"))) (EVar "methods"))))))
(DFunDef false "mapDecl" ((PVar "f") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "body"))))
(DFunDef false "mapDecl" ((PVar "f") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "body"))))
(DFunDef false "mapDecl" ((PVar "f") (PCon "DBench" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DBench") (EVar "pub")) (EVar "name")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "body"))))
(DFunDef false "mapDecl" ((PVar "f") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "mapDecl") (EVar "f")) (EVar "d"))))
(DFunDef false "mapDecl" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "mapIfaceMethod" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))
(DFunDef false "mapIfaceMethod" (PWild (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None"))) (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EVar "None")))
(DFunDef false "mapIfaceMethod" ((PVar "f") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "e"))))) (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "ps")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))))
(DTypeSig false "mapImplMethod" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))
(DFunDef false "mapImplMethod" ((PVar "f") (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DTypeSig true "mapProg" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "mapProg" ((PVar "f") (PVar "prog")) (EApp (EApp (EVar "map") (EApp (EVar "mapDecl") (EVar "f"))) (EVar "prog")))
(DTypeSig false "callBin" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "callBin" ((PVar "fn") (PVar "a") (PVar "b")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b")))
(DTypeSig false "binOp" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "binOp" ((PVar "op") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "a")) (EVar "b")) (EApp (EVar "Ref") (EVar "RNone"))))
(DTypeSig false "intLit" (TyFun (TyCon "Int") (TyCon "Expr")))
(DFunDef false "intLit" ((PVar "n")) (EApp (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EApp (EVar "Ref") (EVar "None"))) (EApp (EVar "Ref") (EVar "RNone"))) (ELit (LString ""))))
(DTypeSig false "derivedImpl" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "Decl")))))
(DFunDef false "derivedImpl" ((PVar "iface") (PVar "tyName") (PVar "methods")) (ERecordCreate "DImpl" ((fa "pub" (EVar "True")) (fa "iface" (EVar "iface")) (fa "tys" (EListLit (EApp (EApp (EVar "TyCon") (EVar "tyName")) (EVar "None")))) (fa "reqs" (EListLit)) (fa "methods" (EVar "methods")))))
(DTypeSig false "binMethod" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "ImplMethod"))))))
(DFunDef false "binMethod" ((PVar "m") (PVar "a") (PVar "b") (PVar "body")) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "m")) (EListLit (EApp (EVar "PVar") (EVar "a")) (EApp (EVar "PVar") (EVar "b")))) (EVar "body")))
(DTypeSig false "rewriteSugar" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteSugar" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "guardsToCore") (EVar "arms")))
(DFunDef false "rewriteSugar" ((PCon "ESection" (PVar "s"))) (EApp (EVar "sectionToCore") (EVar "s")))
(DFunDef false "rewriteSugar" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "interpToCore") (EVar "parts")))
(DFunDef false "rewriteSugar" ((PCon "EBinOp" (PLit (LString ":=")) (PVar "lhs") (PVar "rhs") PWild)) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "setRef"))) (EVar "lhs")) (EVar "rhs")))
(DFunDef false "rewriteSugar" ((PCon "EIndex" (PVar "a") (PVar "i") PWild)) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "index"))) (EVar "a")) (EVar "i")))
(DFunDef false "rewriteSugar" ((PVar "e")) (EVar "e"))
(DTypeSig false "rewriteAssignIndex" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteAssignIndex" ((PCon "EBinOp" (PLit (LString ":=")) (PVar "lhs") (PVar "v") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "assignIndexLhs") (EApp (EVar "stripLocE") (EVar "lhs"))) (EVar "lhs")) (EVar "v")) (EVar "r")))
(DFunDef false "rewriteAssignIndex" ((PVar "e")) (EVar "e"))
(DTypeSig false "assignIndexLhs" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Expr"))))))
(DFunDef false "assignIndexLhs" ((PCon "EIndex" (PVar "a") (PVar "i") PWild) PWild (PVar "v") PWild) (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EVar "callBin") (ELit (LString "setIndex"))) (EVar "a")) (EVar "i"))) (EVar "v")))
(DFunDef false "assignIndexLhs" (PWild (PVar "lhs") (PVar "v") (PVar "r")) (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString ":="))) (EVar "lhs")) (EVar "v")) (EVar "r")))
(DTypeSig false "stripLocE" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripLocE" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stripLocE") (EVar "e")))
(DFunDef false "stripLocE" ((PVar "e")) (EVar "e"))
(DTypeSig false "guardsToCore" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyCon "Expr")))
(DFunDef false "guardsToCore" ((PList)) (EVar "fallthrough"))
(DFunDef false "guardsToCore" ((PCons (PCon "GuardArm" (PVar "quals") (PVar "body")) (PVar "rest"))) (EApp (EApp (EApp (EVar "armChain") (EVar "quals")) (EVar "body")) (EApp (EVar "guardsToCore") (EVar "rest"))))
(DTypeSig false "fallthrough" (TyCon "Expr"))
(DFunDef false "fallthrough" () (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fallthroughName"))) (EApp (EVar "ELit") (EVar "LUnit"))))
(DTypeSig false "armChain" (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "armChain" ((PList) (PVar "body") PWild) (EVar "body"))
(DFunDef false "armChain" ((PCons (PCon "GBool" (PVar "e")) (PVar "qs")) (PVar "body") (PVar "els")) (EApp (EApp (EApp (EVar "EIf") (EVar "e")) (EApp (EApp (EApp (EVar "armChain") (EVar "qs")) (EVar "body")) (EVar "els"))) (EVar "els")))
(DFunDef false "armChain" ((PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "qs")) (PVar "body") (PVar "els")) (EApp (EApp (EVar "EMatch") (EVar "e")) (EListLit (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EListLit)) (EApp (EApp (EApp (EVar "armChain") (EVar "qs")) (EVar "body")) (EVar "els"))) (EApp (EApp (EApp (EVar "Arm") (EVar "PWild")) (EListLit)) (EVar "els")))))
(DTypeSig false "sectionToCore" (TyFun (TyCon "Section") (TyCon "Expr")))
(DFunDef false "sectionToCore" ((PCon "SecBare" (PVar "op"))) (EApp (EApp (EVar "ELam") (EListLit (EApp (EVar "PVar") (ELit (LString "_a"))) (EApp (EVar "PVar") (ELit (LString "_b"))))) (EApp (EApp (EApp (EVar "binOp") (EVar "op")) (EApp (EVar "EVar") (ELit (LString "_a")))) (EApp (EVar "EVar") (ELit (LString "_b"))))))
(DFunDef false "sectionToCore" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "ELam") (EListLit (EApp (EVar "PVar") (ELit (LString "_s"))))) (EApp (EApp (EApp (EVar "binOp") (EVar "op")) (EApp (EVar "EVar") (ELit (LString "_s")))) (EVar "e"))))
(DFunDef false "sectionToCore" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "ELam") (EListLit (EApp (EVar "PVar") (ELit (LString "_s"))))) (EApp (EApp (EApp (EVar "binOp") (EVar "op")) (EVar "e")) (EApp (EVar "EVar") (ELit (LString "_s"))))))
(DTypeSig false "interpToCore" (TyFun (TyApp (TyCon "List") (TyCon "InterpPart")) (TyCon "Expr")))
(DFunDef false "interpToCore" ((PVar "parts")) (EApp (EVar "concatStrings") (EApp (EApp (EVar "map") (EVar "interpPartToExpr")) (EVar "parts"))))
(DTypeSig false "interpPartToExpr" (TyFun (TyCon "InterpPart") (TyCon "Expr")))
(DFunDef false "interpPartToExpr" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "s"))))
(DFunDef false "interpPartToExpr" ((PCon "InterpExpr" (PVar "e"))) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "display")))) (EVar "e")))
(DTypeSig false "concatStrings" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr")))
(DFunDef false "concatStrings" ((PList)) (EApp (EVar "ELit") (EApp (EVar "LString") (ELit (LString "")))))
(DFunDef false "concatStrings" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "concatStrings" ((PCons (PVar "first") (PVar "rest"))) (EApp (EApp (EVar "concatLeft") (EVar "first")) (EVar "rest")))
(DTypeSig false "concatLeft" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "concatLeft" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "concatLeft" ((PVar "acc") (PCons (PVar "e") (PVar "rest"))) (EApp (EApp (EVar "concatLeft") (EApp (EApp (EApp (EVar "binOp") (ELit (LString "++"))) (EVar "acc")) (EVar "e"))) (EVar "rest")))
(DTypeSig false "rewriteDo" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteDo" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "wrapDoOrigin") (EVar "stmts")) (EApp (EVar "lowerDo") (EVar "stmts"))))
(DFunDef false "rewriteDo" ((PVar "e")) (EVar "e"))
(DTypeSig false "wrapDoOrigin" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "wrapDoOrigin" ((PList (PCon "DoExpr" PWild)) (PVar "lowered")) (EVar "lowered"))
(DFunDef false "wrapDoOrigin" ((PVar "stmts") (PVar "lowered")) (EMatch (EApp (EVar "firstDoStmtLoc") (EVar "stmts")) (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EVar "lowered"))) (arm (PCon "None") () (EVar "lowered"))))
(DTypeSig false "firstDoStmtLoc" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstDoStmtLoc" ((PList)) (EVar "None"))
(DFunDef false "firstDoStmtLoc" ((PCons (PVar "s") (PVar "rest"))) (EMatch (EApp (EVar "doStmtLoc") (EVar "s")) (arm (PCon "Some" (PVar "l")) () (EApp (EVar "Some") (EVar "l"))) (arm (PCon "None") () (EApp (EVar "firstDoStmtLoc") (EVar "rest")))))
(DTypeSig false "doStmtLoc" (TyFun (TyCon "DoStmt") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "doStmtLoc" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "exprLoc") (EVar "e")))
(DFunDef false "doStmtLoc" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "exprLoc") (EVar "e")))
(DFunDef false "doStmtLoc" ((PCon "DoLet" PWild PWild PWild (PVar "e"))) (EApp (EVar "exprLoc") (EVar "e")))
(DFunDef false "doStmtLoc" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "exprLoc") (EVar "e")))
(DFunDef false "doStmtLoc" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "exprLoc") (EVar "e")))
(DTypeSig false "exprLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "exprLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "exprLoc" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "exprLoc") (EVar "f")))
(DFunDef false "exprLoc" (PWild) (EVar "None"))
(DTypeSig false "lowerDo" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Expr")))
(DFunDef false "lowerDo" ((PList (PCon "DoExpr" (PVar "e")))) (EVar "e"))
(DFunDef false "lowerDo" ((PList (PCon "DoBind" (PVar "pat") (PVar "e")))) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "andThen"))) (EVar "e")) (EApp (EApp (EVar "doCont") (EVar "pat")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "pure")))) (EApp (EVar "ELit") (EVar "LUnit"))))))
(DFunDef false "lowerDo" ((PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "andThen"))) (EVar "e")) (EApp (EApp (EVar "ELam") (EListLit (EVar "PWild"))) (EApp (EVar "lowerDo") (EVar "rest")))))
(DFunDef false "lowerDo" ((PCons (PCon "DoBind" (PVar "pat") (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "andThen"))) (EVar "e")) (EApp (EApp (EVar "doCont") (EVar "pat")) (EApp (EVar "lowerDo") (EVar "rest")))))
(DFunDef false "lowerDo" ((PCons (PCon "DoLet" PWild (PVar "isFun") (PVar "pat") (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "False")) (EVar "isFun")) (EVar "pat")) (EVar "e")) (EApp (EVar "lowerDo") (EVar "rest"))))
(DFunDef false "lowerDo" (PWild) (EVar "fallthrough"))
(DTypeSig false "doCont" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "doCont" ((PVar "pat") (PVar "body")) (EIf (EApp (EVar "isRefutable") (EVar "pat")) (EApp (EApp (EVar "ELam") (EListLit (EApp (EVar "PVar") (ELit (LString "__do_x"))))) (EApp (EApp (EVar "EMatch") (EApp (EVar "EVar") (ELit (LString "__do_x")))) (EListLit (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EListLit)) (EVar "body")) (EApp (EApp (EApp (EVar "Arm") (EVar "PWild")) (EListLit)) (EVar "fallthrough"))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ELam") (EListLit (EVar "pat"))) (EVar "body")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isRefutable" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isRefutable" ((PCon "PVar" PWild)) (EVar "False"))
(DFunDef false "isRefutable" ((PCon "PWild")) (EVar "False"))
(DFunDef false "isRefutable" ((PCon "PLit" PWild)) (EVar "True"))
(DFunDef false "isRefutable" ((PCon "PCon" PWild PWild)) (EVar "True"))
(DFunDef false "isRefutable" ((PCon "PCons" PWild PWild)) (EVar "True"))
(DFunDef false "isRefutable" ((PCon "PList" PWild)) (EVar "True"))
(DFunDef false "isRefutable" ((PCon "PRng" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isRefutable" ((PCon "PRec" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isRefutable" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "anyRefutable") (EVar "ps")))
(DFunDef false "isRefutable" ((PCon "PAs" PWild (PVar "p"))) (EApp (EVar "isRefutable") (EVar "p")))
(DTypeSig false "anyRefutable" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool")))
(DFunDef false "anyRefutable" ((PList)) (EVar "False"))
(DFunDef false "anyRefutable" ((PCons (PVar "p") (PVar "ps"))) (EBinOp "||" (EApp (EVar "isRefutable") (EVar "p")) (EApp (EVar "anyRefutable") (EVar "ps"))))
(DTypeSig false "expandDecl" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "expandDecl" ((PCon "DData" (PVar "vis") (PVar "name") (PVar "params") (PVar "variants") (PVar "derives"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "DData") (EVar "vis")) (EVar "name")) (EVar "params")) (EVar "variants")) (EListLit)) (EApp (EApp (EVar "deriveImpls") (EApp (EApp (EApp (EVar "deriveForData") (EVar "name")) (EVar "params")) (EVar "variants"))) (EVar "derives"))))
(DFunDef false "expandDecl" ((PCon "DNewtype" (PVar "vis") (PVar "name") (PVar "params") (PVar "con") (PVar "fty") (PVar "derives"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DNewtype") (EVar "vis")) (EVar "name")) (EVar "params")) (EVar "con")) (EVar "fty")) (EListLit)) (EApp (EApp (EVar "deriveImpls") (EApp (EApp (EApp (EApp (EVar "deriveForNewtype") (EVar "name")) (EVar "params")) (EVar "con")) (EVar "fty"))) (EVar "derives"))))
(DFunDef false "expandDecl" ((PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "attribHead") (EVar "attrs")) (EApp (EVar "expandDecl") (EVar "d"))))
(DFunDef false "expandDecl" ((PVar "d")) (EListLit (EVar "d")))
(DTypeSig false "attribHead" (TyFun (TyApp (TyCon "List") (TyCon "Attr")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "attribHead" (PWild (PList)) (EListLit))
(DFunDef false "attribHead" ((PVar "attrs") (PCons (PVar "first") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EVar "first")) (EVar "rest")))
(DTypeSig false "deriveImpls" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Decl"))) (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "deriveImpls" (PWild (PList)) (EListLit))
(DFunDef false "deriveImpls" ((PVar "f") (PCons (PVar "d") (PVar "ds"))) (EMatch (EApp (EVar "f") (EApp (EVar "deriveRefName") (EVar "d"))) (arm (PCon "Some" (PVar "gen")) () (EBinOp "::" (EVar "gen") (EApp (EApp (EVar "deriveImpls") (EVar "f")) (EVar "ds")))) (arm (PCon "None") () (EApp (EApp (EVar "deriveImpls") (EVar "f")) (EVar "ds")))))
(DTypeSig false "dataDerivers" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Decl"))))))))
(DFunDef false "dataDerivers" ((PVar "name") (PVar "params") (PVar "variants")) (EListLit (ETuple (ELit (LString "Eq")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EVar "deriveEqData") (EVar "name")) (EVar "variants"))))) (ETuple (ELit (LString "Ord")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EVar "deriveOrdData") (EVar "name")) (EVar "variants"))))) (ETuple (ELit (LString "Debug")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "deriveShowData") (ELit (LString "Debug"))) (ELit (LString "debug"))) (EVar "name")) (EVar "variants"))))) (ETuple (ELit (LString "Display")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "deriveShowData") (ELit (LString "Display"))) (ELit (LString "display"))) (EVar "name")) (EVar "variants"))))) (ETuple (ELit (LString "Generic")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EVar "deriveGenericData") (EVar "name")) (EVar "variants"))))) (ETuple (ELit (LString "Hashable")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EVar "deriveHashData") (EVar "name")) (EVar "variants")))))))
(DTypeSig false "lookupDeriver" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyCon "Decl")))))
(DFunDef false "lookupDeriver" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupDeriver" ((PVar "n") (PCons (PTuple (PVar "k") (PVar "f")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "k")) (EApp (EVar "Some") (EApp (EVar "f") (ELit LUnit))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupDeriver") (EVar "n")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "deriveForData" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Decl")))))))
(DFunDef false "deriveForData" ((PVar "name") (PVar "params") (PVar "variants") (PVar "iface")) (EApp (EApp (EVar "lookupDeriver") (EVar "iface")) (EApp (EApp (EApp (EVar "dataDerivers") (EVar "name")) (EVar "params")) (EVar "variants"))))
(DTypeSig false "newtypeDerivers" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Decl")))))))))
(DFunDef false "newtypeDerivers" ((PVar "name") (PVar "params") (PVar "con") (PVar "fty")) (EBlock (DoLet false false (PVar "synthetic") (EListLit (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty")))))) (DoExpr (EListLit (ETuple (ELit (LString "Eq")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EVar "deriveEqData") (EVar "name")) (EVar "synthetic"))))) (ETuple (ELit (LString "Ord")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EVar "deriveOrdData") (EVar "name")) (EVar "synthetic"))))) (ETuple (ELit (LString "Debug")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "deriveShowData") (ELit (LString "Debug"))) (ELit (LString "debug"))) (EVar "name")) (EVar "synthetic"))))) (ETuple (ELit (LString "Display")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "deriveShowData") (ELit (LString "Display"))) (ELit (LString "display"))) (EVar "name")) (EVar "synthetic"))))) (ETuple (ELit (LString "Hashable")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EVar "deriveHashData") (EVar "name")) (EVar "synthetic")))))))))
(DTypeSig false "deriveForNewtype" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Decl"))))))))
(DFunDef false "deriveForNewtype" ((PVar "name") (PVar "params") (PVar "con") (PVar "fty") (PVar "iface")) (EApp (EApp (EVar "lookupDeriver") (EVar "iface")) (EApp (EApp (EApp (EApp (EVar "newtypeDerivers") (EVar "name")) (EVar "params")) (EVar "con")) (EVar "fty"))))
(DTypeSig true "checkDerives" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "checkDerives" ((PVar "decls")) (EApp (EApp (EVar "flatMap") (EVar "declDeriveErrors")) (EVar "decls")))
(DTypeSig false "declDeriveErrors" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "declDeriveErrors" ((PCon "DData" PWild (PVar "name") (PVar "params") (PVar "variants") (PVar "derives"))) (EMatch (EVar "derives") (arm (PList) () (EListLit)) (arm PWild () (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "unknownDerive") (EVar "name")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EApp (EVar "dataDerivers") (EVar "name")) (EVar "params")) (EVar "variants"))))) (EVar "derives")))))
(DFunDef false "declDeriveErrors" ((PCon "DNewtype" PWild (PVar "name") (PVar "params") (PVar "con") (PVar "fty") (PVar "derives"))) (EMatch (EVar "derives") (arm (PList) () (EListLit)) (arm PWild () (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "unknownDerive") (EVar "name")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EApp (EApp (EVar "newtypeDerivers") (EVar "name")) (EVar "params")) (EVar "con")) (EVar "fty"))))) (EVar "derives")))))
(DFunDef false "declDeriveErrors" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declDeriveErrors") (EVar "d")))
(DFunDef false "declDeriveErrors" (PWild) (EListLit))
(DTypeSig false "unknownDerive" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "DeriveRef") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))))
(DFunDef false "unknownDerive" ((PVar "tyName") (PVar "supported") (PCon "DeriveRef" (PVar "n") (PVar "loc"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "supported")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EApp (EApp (EApp (EVar "cannotDeriveMsg") (EVar "tyName")) (EVar "supported")) (EVar "n")) (EVar "loc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cannotDeriveMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "cannotDeriveMsg" ((PVar "tyName") (PVar "supported") (PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot derive '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' for '"))) (EApp (EVar "display") (EVar "tyName"))) (ELit (LString "'; supported: "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "supported")))) (ELit (LString ""))))
(DTypeSig false "applyDeriveParams" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl")))))
(DFunDef false "applyDeriveParams" ((PVar "name") (PVar "params") (PAs "d" (PRec "DImpl" ((rf "iface" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "tys" (EListLit (EApp (EApp (EVar "appliedHead") (EVar "name")) (EVar "params")))) (fa "reqs" (EApp (EApp (EVar "paramRequires") (EVar "iface")) (EVar "params"))))))
(DFunDef false "applyDeriveParams" (PWild PWild (PVar "d")) (EVar "d"))
(DTypeSig false "appliedHead" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))
(DFunDef false "appliedHead" ((PVar "name") (PVar "params")) (EApp (EApp (EVar "appliedHeadGo") (EApp (EApp (EVar "TyCon") (EVar "name")) (EVar "None"))) (EVar "params")))
(DTypeSig false "appliedHeadGo" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))
(DFunDef false "appliedHeadGo" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "appliedHeadGo" ((PVar "acc") (PCons (PVar "p") (PVar "ps"))) (EApp (EApp (EVar "appliedHeadGo") (EApp (EApp (EVar "TyApp") (EVar "acc")) (EApp (EVar "TyVar") (EVar "p")))) (EVar "ps")))
(DTypeSig false "paramRequires" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Require")))))
(DFunDef false "paramRequires" ((PVar "iface") (PVar "params")) (EApp (EApp (EVar "map") (EApp (EVar "paramReq") (EVar "iface"))) (EVar "params")))
(DTypeSig false "paramReq" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Require"))))
(DFunDef false "paramReq" ((PVar "iface") (PVar "p")) (EApp (EApp (EVar "Require") (EVar "iface")) (EListLit (EApp (EVar "TyVar") (EVar "p")))))
(DTypeSig false "conArity" (TyFun (TyCon "Variant") (TyCon "Int")))
(DFunDef false "conArity" ((PCon "Variant" PWild (PCon "ConPos" (PVar "tys")))) (EApp (EVar "listLen") (EVar "tys")))
(DFunDef false "conArity" ((PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EVar "listLen") (EVar "fs")))
(DTypeSig false "genVars" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "genVars" ((PVar "prefix") (PVar "n")) (EApp (EApp (EApp (EVar "genVarsGo") (EVar "prefix")) (ELit (LInt 0))) (EVar "n")))
(DTypeSig false "genVarsGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "genVarsGo" ((PVar "prefix") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EVar "prefix") (EApp (EVar "intToString") (EVar "i"))) (EApp (EApp (EApp (EVar "genVarsGo") (EVar "prefix")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "conBindPat" (TyFun (TyCon "Variant") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Pat"))))
(DFunDef false "conBindPat" ((PCon "Variant" (PVar "cname") (PCon "ConPos" PWild)) (PVar "vars")) (EApp (EApp (EVar "PCon") (EVar "cname")) (EApp (EApp (EVar "map") (EVar "PVar")) (EVar "vars"))))
(DFunDef false "conBindPat" ((PCon "Variant" (PVar "cname") (PCon "ConNamed" (PVar "fs") PWild)) (PVar "vars")) (EApp (EApp (EApp (EVar "PRec") (EVar "cname")) (EApp (EApp (EVar "recPatFields") (EVar "fs")) (EVar "vars"))) (EVar "False")))
(DTypeSig false "recPatFields" (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "RecPatField")))))
(DFunDef false "recPatFields" ((PList) PWild) (EListLit))
(DFunDef false "recPatFields" (PWild (PList)) (EListLit))
(DFunDef false "recPatFields" ((PCons (PCon "Field" (PVar "n") PWild) (PVar "fs")) (PCons (PVar "v") (PVar "vs"))) (EBinOp "::" (EApp (EApp (EVar "RecPatField") (EVar "n")) (EApp (EVar "Some") (EApp (EVar "PVar") (EVar "v")))) (EApp (EApp (EVar "recPatFields") (EVar "fs")) (EVar "vs"))))
(DTypeSig false "deriveShowData" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Decl"))))))
(DFunDef false "deriveShowData" ((PVar "iface") (PVar "callName") (PVar "name") (PVar "variants")) (EApp (EApp (EApp (EVar "derivedImpl") (EVar "iface")) (EVar "name")) (EListLit (EApp (EApp (EApp (EVar "ImplMethod") (EVar "callName")) (EListLit (EApp (EVar "PVar") (ELit (LString "__x"))))) (EApp (EApp (EVar "EMatch") (EApp (EVar "EVar") (ELit (LString "__x")))) (EApp (EApp (EVar "map") (EApp (EVar "showArm") (EVar "callName"))) (EVar "variants")))))))
(DTypeSig false "showArm" (TyFun (TyCon "String") (TyFun (TyCon "Variant") (TyCon "Arm"))))
(DFunDef false "showArm" ((PVar "callName") (PAs "v" (PCon "Variant" (PVar "cname") (PVar "payload")))) (EBlock (DoLet false false (PVar "vars") (EApp (EApp (EVar "genVars") (ELit (LString "__a"))) (EApp (EVar "conArity") (EVar "v")))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EApp (EApp (EVar "conBindPat") (EVar "v")) (EVar "vars"))) (EListLit)) (EApp (EApp (EApp (EApp (EVar "showBody") (EVar "callName")) (EVar "cname")) (EVar "payload")) (EVar "vars"))))))
(DTypeSig false "showBody" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ConPayload") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr"))))))
(DFunDef false "showBody" (PWild (PVar "cname") PWild (PList)) (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "cname"))))
(DFunDef false "showBody" ((PVar "callName") (PVar "cname") (PCon "ConNamed" (PVar "fs") PWild) (PCons (PVar "v") (PVar "vs"))) (EApp (EVar "concatStrings") (EBinOp "::" (EApp (EVar "ELit") (EApp (EVar "LString") (EBinOp "++" (EVar "cname") (ELit (LString " {"))))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "showNamedParts") (EVar "callName")) (ELit (LInt 0))) (EVar "fs")) (EBinOp "::" (EVar "v") (EVar "vs"))) (EListLit (EApp (EVar "ELit") (EApp (EVar "LString") (ELit (LString " }")))))))))
(DFunDef false "showBody" ((PVar "callName") (PVar "cname") PWild (PCons (PVar "v") (PVar "vs"))) (EApp (EVar "concatStrings") (EBinOp "::" (EApp (EVar "ELit") (EApp (EVar "LString") (EBinOp "++" (EVar "cname") (ELit (LString " "))))) (EApp (EApp (EApp (EVar "showFieldParts") (EVar "callName")) (ELit (LInt 0))) (EBinOp "::" (EVar "v") (EVar "vs"))))))
(DTypeSig false "showFieldParts" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "showFieldParts" (PWild PWild (PList)) (EListLit))
(DFunDef false "showFieldParts" ((PVar "callName") (PVar "i") (PCons (PVar "v") (PVar "vs"))) (EBinOp "++" (EApp (EApp (EApp (EVar "showFieldPart") (EVar "callName")) (EVar "i")) (EVar "v")) (EApp (EApp (EApp (EVar "showFieldParts") (EVar "callName")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "vs"))))
(DTypeSig false "showFieldPart" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "showFieldPart" ((PVar "callName") (PLit (LInt 0)) (PVar "v")) (EListLit (EApp (EApp (EVar "wrappedFieldCall") (EVar "callName")) (EVar "v"))))
(DFunDef false "showFieldPart" ((PVar "callName") PWild (PVar "v")) (EListLit (EApp (EVar "ELit") (EApp (EVar "LString") (ELit (LString " ")))) (EApp (EApp (EVar "wrappedFieldCall") (EVar "callName")) (EVar "v"))))
(DTypeSig false "wrappedFieldCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Expr"))))
(DFunDef false "wrappedFieldCall" ((PVar "callName") (PVar "v")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "derivedShowWrap")))) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "callName"))) (EApp (EVar "EVar") (EVar "v")))))
(DTypeSig false "showNamedParts" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "showNamedParts" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "showNamedParts" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "showNamedParts" ((PVar "callName") (PVar "i") (PCons (PCon "Field" (PVar "fn") PWild) (PVar "fs")) (PCons (PVar "v") (PVar "vs"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "showNamedPart") (EVar "callName")) (EVar "i")) (EVar "fn")) (EVar "v")) (EApp (EApp (EApp (EApp (EVar "showNamedParts") (EVar "callName")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "fs")) (EVar "vs"))))
(DTypeSig false "showNamedPart" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "showNamedPart" ((PVar "callName") (PLit (LInt 0)) (PVar "fn") (PVar "v")) (EListLit (EApp (EVar "ELit") (EApp (EVar "LString") (EBinOp "++" (EBinOp "++" (ELit (LString " ")) (EApp (EVar "display") (EVar "fn"))) (ELit (LString " = "))))) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "callName"))) (EApp (EVar "EVar") (EVar "v")))))
(DFunDef false "showNamedPart" ((PVar "callName") PWild (PVar "fn") (PVar "v")) (EListLit (EApp (EVar "ELit") (EApp (EVar "LString") (EBinOp "++" (EBinOp "++" (ELit (LString ", ")) (EApp (EVar "display") (EVar "fn"))) (ELit (LString " = "))))) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "callName"))) (EApp (EVar "EVar") (EVar "v")))))
(DTypeSig false "deriveEqData" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Decl"))))
(DFunDef false "deriveEqData" ((PVar "name") (PVar "variants")) (EApp (EApp (EApp (EVar "derivedImpl") (ELit (LString "Eq"))) (EVar "name")) (EListLit (EApp (EApp (EApp (EApp (EVar "binMethod") (ELit (LString "eq"))) (ELit (LString "__x"))) (ELit (LString "__y"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "ETuple") (EListLit (EApp (EVar "EVar") (ELit (LString "__x"))) (EApp (EVar "EVar") (ELit (LString "__y")))))) (EApp (EVar "eqArms") (EVar "variants")))))))
(DTypeSig false "eqArms" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Arm"))))
(DFunDef false "eqArms" ((PVar "variants")) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "variants")) (ELit (LInt 1))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "eqSameConArm")) (EVar "variants")) (EListLit (EApp (EApp (EApp (EVar "Arm") (EApp (EVar "PTuple") (EListLit (EVar "PWild") (EVar "PWild")))) (EListLit)) (EApp (EVar "EVar") (ELit (LString "False")))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "map") (EVar "eqSameConArm")) (EVar "variants")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "eqSameConArm" (TyFun (TyCon "Variant") (TyCon "Arm")))
(DFunDef false "eqSameConArm" ((PAs "v" (PCon "Variant" PWild PWild))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "conArity") (EVar "v"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EApp (EVar "PTuple") (EListLit (EApp (EApp (EVar "conBindPat") (EVar "v")) (EApp (EApp (EVar "genVars") (ELit (LString "__a"))) (EVar "n"))) (EApp (EApp (EVar "conBindPat") (EVar "v")) (EApp (EApp (EVar "genVars") (ELit (LString "__b"))) (EVar "n")))))) (EListLit)) (EApp (EApp (EApp (EVar "eqBody") (EVar "n")) (EApp (EApp (EVar "genVars") (ELit (LString "__a"))) (EVar "n"))) (EApp (EApp (EVar "genVars") (ELit (LString "__b"))) (EVar "n")))))))
(DTypeSig false "eqBody" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr")))))
(DFunDef false "eqBody" ((PLit (LInt 0)) PWild PWild) (EApp (EVar "EVar") (ELit (LString "True"))))
(DFunDef false "eqBody" (PWild (PVar "avars") (PVar "bvars")) (EApp (EVar "andAll") (EApp (EApp (EVar "zipEqCalls") (EVar "avars")) (EVar "bvars"))))
(DTypeSig false "zipEqCalls" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "zipEqCalls" ((PList) PWild) (EListLit))
(DFunDef false "zipEqCalls" (PWild (PList)) (EListLit))
(DFunDef false "zipEqCalls" ((PCons (PVar "a") (PVar "arest")) (PCons (PVar "b") (PVar "brest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "callBin") (ELit (LString "eq"))) (EApp (EVar "EVar") (EVar "a"))) (EApp (EVar "EVar") (EVar "b"))) (EApp (EApp (EVar "zipEqCalls") (EVar "arest")) (EVar "brest"))))
(DTypeSig false "andAll" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr")))
(DFunDef false "andAll" ((PList)) (EApp (EVar "EVar") (ELit (LString "True"))))
(DFunDef false "andAll" ((PCons (PVar "first") (PVar "rest"))) (EApp (EApp (EVar "andLeft") (EVar "first")) (EVar "rest")))
(DTypeSig false "andLeft" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "andLeft" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "andLeft" ((PVar "acc") (PCons (PVar "e") (PVar "rest"))) (EApp (EApp (EVar "andLeft") (EApp (EApp (EApp (EVar "binOp") (ELit (LString "&&"))) (EVar "acc")) (EVar "e"))) (EVar "rest")))
(DTypeSig false "deriveOrdData" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Decl"))))
(DFunDef false "deriveOrdData" ((PVar "name") (PVar "variants")) (EApp (EApp (EApp (EVar "derivedImpl") (ELit (LString "Ord"))) (EVar "name")) (EListLit (EApp (EApp (EApp (EApp (EVar "binMethod") (ELit (LString "compare"))) (ELit (LString "__x"))) (ELit (LString "__y"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "ETuple") (EListLit (EApp (EVar "EVar") (ELit (LString "__x"))) (EApp (EVar "EVar") (ELit (LString "__y")))))) (EApp (EVar "ordArms") (EVar "variants")))))))
(DTypeSig false "ordArms" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Arm"))))
(DFunDef false "ordArms" ((PVar "variants")) (EBlock (DoLet false false (PVar "indexed") (EApp (EApp (EVar "indexFrom") (ELit (LInt 0))) (EVar "variants"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EVar "ordRow") (EVar "indexed"))) (EVar "indexed")))))
(DTypeSig false "indexFrom" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyVar "a"))))))
(DFunDef false "indexFrom" (PWild (PList)) (EListLit))
(DFunDef false "indexFrom" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (ETuple (EVar "i") (EVar "x")) (EApp (EApp (EVar "indexFrom") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "xs"))))
(DTypeSig false "ordRow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Variant"))) (TyFun (TyTuple (TyCon "Int") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Arm")))))
(DFunDef false "ordRow" ((PVar "indexed") (PTuple (PVar "i") (PVar "vi"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "ordCell") (EVar "i")) (EVar "vi"))) (EVar "indexed")))
(DTypeSig false "ordCell" (TyFun (TyCon "Int") (TyFun (TyCon "Variant") (TyFun (TyTuple (TyCon "Int") (TyCon "Variant")) (TyCon "Arm")))))
(DFunDef false "ordCell" ((PVar "i") (PVar "vi") (PTuple (PVar "j") (PVar "vj"))) (EBlock (DoLet false false (PVar "avars") (EApp (EApp (EVar "genVars") (ELit (LString "__a"))) (EApp (EVar "conArity") (EVar "vi")))) (DoLet false false (PVar "bvars") (EApp (EApp (EVar "genVars") (ELit (LString "__b"))) (EApp (EVar "conArity") (EVar "vj")))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EApp (EVar "PTuple") (EListLit (EApp (EApp (EVar "conBindPat") (EVar "vi")) (EVar "avars")) (EApp (EApp (EVar "conBindPat") (EVar "vj")) (EVar "bvars"))))) (EListLit)) (EApp (EApp (EApp (EApp (EVar "ordBody") (EVar "i")) (EVar "j")) (EVar "avars")) (EVar "bvars"))))))
(DTypeSig false "ordBody" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr"))))))
(DFunDef false "ordBody" ((PVar "i") (PVar "j") (PVar "avars") (PVar "bvars")) (EIf (EBinOp "<" (EVar "i") (EVar "j")) (EApp (EVar "EVar") (ELit (LString "Lt"))) (EIf (EBinOp ">" (EVar "i") (EVar "j")) (EApp (EVar "EVar") (ELit (LString "Gt"))) (EIf (EVar "otherwise") (EApp (EVar "lexCompareExprs") (EApp (EApp (EVar "zipExprPairs") (EVar "avars")) (EVar "bvars"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "zipExprPairs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "zipExprPairs" ((PList) PWild) (EListLit))
(DFunDef false "zipExprPairs" (PWild (PList)) (EListLit))
(DFunDef false "zipExprPairs" ((PCons (PVar "a") (PVar "arest")) (PCons (PVar "b") (PVar "brest"))) (EBinOp "::" (ETuple (EApp (EVar "EVar") (EVar "a")) (EApp (EVar "EVar") (EVar "b"))) (EApp (EApp (EVar "zipExprPairs") (EVar "arest")) (EVar "brest"))))
(DTypeSig false "lexCompareExprs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))) (TyCon "Expr")))
(DFunDef false "lexCompareExprs" ((PList)) (EApp (EVar "EVar") (ELit (LString "Eq"))))
(DFunDef false "lexCompareExprs" ((PList (PTuple (PVar "ea") (PVar "eb")))) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "compare"))) (EVar "ea")) (EVar "eb")))
(DFunDef false "lexCompareExprs" ((PCons (PTuple (PVar "ea") (PVar "eb")) (PVar "rest"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EApp (EVar "callBin") (ELit (LString "compare"))) (EVar "ea")) (EVar "eb"))) (EListLit (EApp (EApp (EApp (EVar "Arm") (EApp (EApp (EVar "PCon") (ELit (LString "Eq"))) (EListLit))) (EListLit)) (EApp (EVar "lexCompareExprs") (EVar "rest"))) (EApp (EApp (EApp (EVar "Arm") (EApp (EVar "PVar") (ELit (LString "__c")))) (EListLit)) (EApp (EVar "EVar") (ELit (LString "__c")))))))
(DTypeSig false "deriveHashData" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Decl"))))
(DFunDef false "deriveHashData" ((PVar "name") (PVar "variants")) (EApp (EApp (EApp (EVar "derivedImpl") (ELit (LString "Hashable"))) (EVar "name")) (EListLit (EApp (EApp (EApp (EVar "ImplMethod") (ELit (LString "hash"))) (EListLit (EApp (EVar "PVar") (ELit (LString "__x"))))) (EApp (EApp (EVar "EMatch") (EApp (EVar "EVar") (ELit (LString "__x")))) (EApp (EApp (EVar "map") (EVar "hashArm")) (EApp (EApp (EVar "indexFrom") (ELit (LInt 0))) (EVar "variants"))))))))
(DTypeSig false "hashArm" (TyFun (TyTuple (TyCon "Int") (TyCon "Variant")) (TyCon "Arm")))
(DFunDef false "hashArm" ((PTuple (PVar "i") (PVar "v"))) (EBlock (DoLet false false (PVar "vars") (EApp (EApp (EVar "genVars") (ELit (LString "__a"))) (EApp (EVar "conArity") (EVar "v")))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EApp (EApp (EVar "conBindPat") (EVar "v")) (EVar "vars"))) (EListLit)) (EApp (EApp (EVar "hashFold") (EApp (EVar "intLit") (EVar "i"))) (EVar "vars"))))))
(DTypeSig false "hashFold" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr"))))
(DFunDef false "hashFold" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "hashFold" ((PVar "acc") (PCons (PVar "v") (PVar "vs"))) (EApp (EApp (EVar "hashFold") (EApp (EApp (EApp (EVar "binOp") (ELit (LString "+"))) (EApp (EApp (EApp (EVar "binOp") (ELit (LString "*"))) (EVar "acc")) (EApp (EVar "intLit") (ELit (LInt 33))))) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "hash")))) (EApp (EVar "EVar") (EVar "v"))))) (EVar "vs")))
(DTypeSig false "deriveGenericData" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Decl"))))
(DFunDef false "deriveGenericData" ((PVar "name") (PVar "variants")) (EApp (EApp (EApp (EVar "derivedImpl") (ELit (LString "Generic"))) (EVar "name")) (EListLit (EApp (EApp (EApp (EVar "ImplMethod") (ELit (LString "to_rep"))) (EListLit (EApp (EVar "PVar") (ELit (LString "__x"))))) (EApp (EApp (EVar "EMatch") (EApp (EVar "EVar") (ELit (LString "__x")))) (EApp (EApp (EVar "map") (EVar "genericArm")) (EVar "variants")))))))
(DTypeSig false "genericArm" (TyFun (TyCon "Variant") (TyCon "Arm")))
(DFunDef false "genericArm" ((PAs "v" (PCon "Variant" (PVar "cname") (PVar "payload")))) (EBlock (DoLet false false (PVar "vars") (EApp (EApp (EVar "genVars") (ELit (LString "__a"))) (EApp (EVar "conArity") (EVar "v")))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EApp (EApp (EVar "conBindPat") (EVar "v")) (EVar "vars"))) (EListLit)) (EApp (EApp (EApp (EVar "genericRep") (EVar "cname")) (EVar "payload")) (EVar "vars"))))))
(DTypeSig false "genericRep" (TyFun (TyCon "String") (TyFun (TyCon "ConPayload") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr")))))
(DFunDef false "genericRep" ((PVar "cname") (PCon "ConNamed" (PVar "fs") PWild) (PVar "vars")) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "RRecord"))) (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "cname")))) (EApp (EVar "EListLit") (EApp (EApp (EVar "genericRFields") (EVar "fs")) (EVar "vars")))))
(DFunDef false "genericRep" ((PVar "cname") PWild (PVar "vars")) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "RCon"))) (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "cname")))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EVar "toRep")) (EVar "vars")))))
(DTypeSig false "genericRFields" (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "genericRFields" ((PList) PWild) (EListLit))
(DFunDef false "genericRFields" (PWild (PList)) (EListLit))
(DFunDef false "genericRFields" ((PCons (PCon "Field" (PVar "fn") PWild) (PVar "fs")) (PCons (PVar "v") (PVar "vs"))) (EBinOp "::" (EApp (EApp (EVar "ERecordCreate") (ELit (LString "RField"))) (EListLit (EApp (EApp (EVar "FieldAssign") (ELit (LString "fld_name"))) (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "fn")))) (EApp (EApp (EVar "FieldAssign") (ELit (LString "fld_rep"))) (EApp (EVar "toRep") (EVar "v"))))) (EApp (EApp (EVar "genericRFields") (EVar "fs")) (EVar "vs"))))
(DTypeSig false "toRep" (TyFun (TyCon "String") (TyCon "Expr")))
(DFunDef false "toRep" ((PVar "x")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "to_rep")))) (EApp (EVar "EVar") (EVar "x"))))
(DTypeSig false "mergeIfaceDefaults" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "mergeIfaceDefaults" ((PVar "prog")) (EApp (EApp (EVar "map") (EVar "mergeIfaceDecl")) (EVar "prog")))
(DTypeSig false "mergeIfaceDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "mergeIfaceDecl" ((PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EVar "mergeIfaceMethods") (EVar "methods"))))))
(DFunDef false "mergeIfaceDecl" ((PVar "d")) (EVar "d"))
(DTypeSig false "mergeIfaceMethods" (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "mergeIfaceMethods" ((PVar "methods")) (EApp (EApp (EVar "foldlMethods") (EListLit)) (EVar "methods")))
(DTypeSig false "foldlMethods" (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "foldlMethods" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "foldlMethods" ((PVar "acc") (PCons (PVar "m") (PVar "rest"))) (EApp (EApp (EVar "foldlMethods") (EApp (EApp (EVar "insertMethod") (EVar "acc")) (EVar "m"))) (EVar "rest")))
(DTypeSig false "insertMethod" (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "insertMethod" ((PVar "acc") (PVar "m")) (EIf (EApp (EApp (EVar "containsMethod") (EApp (EVar "methodName") (EVar "m"))) (EVar "acc")) (EApp (EApp (EVar "mergeInto") (EVar "acc")) (EVar "m")) (EIf (EVar "otherwise") (EBinOp "++" (EVar "acc") (EListLit (EVar "m"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "mergeInto" (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "mergeInto" ((PList) (PVar "m")) (EListLit (EVar "m")))
(DFunDef false "mergeInto" ((PCons (PVar "x") (PVar "xs")) (PVar "m")) (EIf (EBinOp "==" (EApp (EVar "methodName") (EVar "x")) (EApp (EVar "methodName") (EVar "m"))) (EBinOp "::" (EApp (EApp (EVar "mergeTwo") (EVar "x")) (EVar "m")) (EVar "xs")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "mergeInto") (EVar "xs")) (EVar "m"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "mergeTwo" (TyFun (TyCon "IfaceMethod") (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))
(DFunDef false "mergeTwo" ((PCon "IfaceMethod" (PVar "n") (PVar "prevTy") (PVar "prevDef")) (PCon "IfaceMethod" PWild (PVar "mTy") (PVar "mDef"))) (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EApp (EApp (EVar "mergedType") (EVar "prevTy")) (EVar "mTy"))) (EApp (EApp (EVar "mergedDefault") (EVar "prevDef")) (EVar "mDef"))))
(DTypeSig false "mergedType" (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "mergedType" ((PCon "TyVar" (PLit (LString "_"))) (PVar "mTy")) (EVar "mTy"))
(DFunDef false "mergedType" ((PVar "prevTy") PWild) (EVar "prevTy"))
(DTypeSig false "mergedDefault" (TyFun (TyApp (TyCon "Option") (TyCon "MethodDefault")) (TyFun (TyApp (TyCon "Option") (TyCon "MethodDefault")) (TyApp (TyCon "Option") (TyCon "MethodDefault")))))
(DFunDef false "mergedDefault" ((PCon "Some" (PVar "d")) PWild) (EApp (EVar "Some") (EVar "d")))
(DFunDef false "mergedDefault" ((PCon "None") (PVar "mDef")) (EVar "mDef"))
(DTypeSig false "containsMethod" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Bool"))))
(DFunDef false "containsMethod" (PWild (PList)) (EVar "False"))
(DFunDef false "containsMethod" ((PVar "name") (PCons (PVar "x") (PVar "xs"))) (EBinOp "||" (EBinOp "==" (EApp (EVar "methodName") (EVar "x")) (EVar "name")) (EApp (EApp (EVar "containsMethod") (EVar "name")) (EVar "xs"))))
(DTypeSig false "methodName" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "methodName" ((PCon "IfaceMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "fillImplDefaults" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "fillImplDefaults" ((PVar "prog")) (EApp (EApp (EVar "map") (EApp (EVar "fillImplDecl") (EVar "prog"))) (EVar "prog")))
(DTypeSig false "fillImplDecl" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "fillImplDecl" ((PVar "prog") (PAs "d" (PRec "DImpl" ((rf "iface" None) (rf "methods" None)) true))) (EIf (EVar "otherwise") (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EBinOp "++" (EVar "methods") (EApp (EApp (EVar "synthDefaultMethods") (EVar "methods")) (EApp (EApp (EVar "ifaceDefaults") (EVar "iface")) (EVar "prog"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "fillImplDecl" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "ifaceDefaults" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "ifaceDefaults" (PWild (PList)) (EListLit))
(DFunDef false "ifaceDefaults" ((PVar "target") (PCons (PVar "d") (PVar "rest"))) (EApp (EApp (EApp (EVar "ifaceDefaultsStep") (EVar "target")) (EVar "d")) (EVar "rest")))
(DTypeSig false "ifaceDefaultsStep" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "IfaceMethod"))))))
(DFunDef false "ifaceDefaultsStep" ((PVar "target") (PRec "DInterface" ((rf "name" None) (rf "methods" None)) true) (PVar "rest")) (EIf (EBinOp "==" (EVar "name") (EVar "target")) (EApp (EApp (EVar "filterList") (EVar "ifaceMethodHasDefault")) (EVar "methods")) (EIf (EVar "otherwise") (EApp (EApp (EVar "ifaceDefaults") (EVar "target")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "ifaceDefaultsStep" ((PVar "target") PWild (PVar "rest")) (EApp (EApp (EVar "ifaceDefaults") (EVar "target")) (EVar "rest")))
(DTypeSig false "ifaceMethodHasDefault" (TyFun (TyCon "IfaceMethod") (TyCon "Bool")))
(DFunDef false "ifaceMethodHasDefault" ((PCon "IfaceMethod" PWild PWild (PCon "Some" PWild))) (EVar "True"))
(DFunDef false "ifaceMethodHasDefault" ((PCon "IfaceMethod" PWild PWild (PCon "None"))) (EVar "False"))
(DTypeSig false "synthDefaultMethods" (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "ImplMethod")))))
(DFunDef false "synthDefaultMethods" (PWild (PList)) (EListLit))
(DFunDef false "synthDefaultMethods" ((PVar "explicit") (PCons (PVar "m") (PVar "rest"))) (EIf (EApp (EApp (EVar "implDefines") (EApp (EVar "methodName") (EVar "m"))) (EVar "explicit")) (EApp (EApp (EVar "synthDefaultMethods") (EVar "explicit")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "synthFromDefault") (EVar "m")) (EApp (EApp (EVar "synthDefaultMethods") (EVar "explicit")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implDefines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "Bool"))))
(DFunDef false "implDefines" ((PVar "name") (PVar "explicit")) (EApp (EApp (EVar "anyList") (EApp (EVar "implMethodNamed") (EVar "name"))) (EVar "explicit")))
(DTypeSig false "implMethodNamed" (TyFun (TyCon "String") (TyFun (TyCon "ImplMethod") (TyCon "Bool"))))
(DFunDef false "implMethodNamed" ((PVar "name") (PCon "ImplMethod" (PVar "n") PWild PWild)) (EBinOp "==" (EVar "n") (EVar "name")))
(DTypeSig false "synthFromDefault" (TyFun (TyCon "IfaceMethod") (TyCon "ImplMethod")))
(DFunDef false "synthFromDefault" ((PCon "IfaceMethod" (PVar "n") PWild (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "body"))))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EVar "body")))
(DFunDef false "synthFromDefault" ((PCon "IfaceMethod" (PVar "n") PWild (PCon "None"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EListLit)) (EApp (EVar "EVar") (EVar "n"))))
(DTypeSig false "concatMapDecl" (TyFun (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Decl"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "concatMapDecl" ((PVar "f") (PVar "prog")) (EApp (EVar "concatLists") (EApp (EApp (EVar "map") (EVar "f")) (EVar "prog"))))
(DTypeSig false "concatLists" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "concatLists" ((PList)) (EListLit))
(DFunDef false "concatLists" ((PCons (PVar "xs") (PVar "rest"))) (EBinOp "++" (EVar "xs") (EApp (EVar "concatLists") (EVar "rest"))))
(DTypeSig false "desugarRecordPuns" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "desugarRecordPuns" ((PVar "prog")) (EApp (EApp (EVar "mapProg") (EApp (EVar "rewriteRecordPun") (EApp (EVar "collectRecordNames") (EVar "prog")))) (EVar "prog")))
(DTypeSig false "collectRecordNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectRecordNames" ((PList)) (EListLit))
(DFunDef false "collectRecordNames" ((PCons (PCon "DData" PWild PWild PWild (PVar "variants") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EVar "conNamedCtorNames") (EVar "variants")) (EApp (EVar "collectRecordNames") (EVar "rest"))))
(DFunDef false "collectRecordNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "collectRecordNames") (EVar "rest")))
(DTypeSig false "conNamedCtorNames" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "conNamedCtorNames" ((PList)) (EListLit))
(DFunDef false "conNamedCtorNames" ((PCons (PCon "Variant" (PVar "n") (PCon "ConNamed" PWild PWild)) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "conNamedCtorNames") (EVar "rest"))))
(DFunDef false "conNamedCtorNames" ((PCons (PCon "Variant" PWild (PCon "ConPos" PWild)) (PVar "rest"))) (EApp (EVar "conNamedCtorNames") (EVar "rest")))
(DTypeSig false "rewriteRecordPun" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteRecordPun" ((PVar "recordNames") (PCon "ESetLit" (PVar "name") (PVar "items"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "contains") (EVar "name")) (EVar "recordNames")) (EBinOp ">" (EApp (EVar "listLen") (EVar "items")) (ELit (LInt 0)))) (EApp (EApp (EVar "allList") (EVar "isVarExpr")) (EVar "items"))) (EApp (EApp (EVar "ERecordCreate") (EVar "name")) (EApp (EApp (EVar "map") (EVar "punField")) (EVar "items"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "rewriteRecordPun" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "isVarExpr" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isVarExpr" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isVarExpr") (EVar "e")))
(DFunDef false "isVarExpr" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "isVarExpr") (EVar "e")))
(DFunDef false "isVarExpr" ((PCon "EVar" PWild)) (EVar "True"))
(DFunDef false "isVarExpr" (PWild) (EVar "False"))
(DTypeSig false "punField" (TyFun (TyCon "Expr") (TyCon "FieldAssign")))
(DFunDef false "punField" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "punField") (EVar "e")))
(DFunDef false "punField" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "punField") (EVar "e")))
(DFunDef false "punField" ((PCon "EVar" (PVar "n"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "EVar") (EVar "n"))))
(DFunDef false "punField" (PWild) (EApp (EApp (EVar "FieldAssign") (ELit (LString ""))) (EApp (EVar "EVar") (ELit (LString "")))))
(DTypeSig false "lowerContainerLiterals" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "lowerContainerLiterals" ((PVar "prog")) (EApp (EApp (EVar "mapProg") (EVar "rewriteContainerLit")) (EVar "prog")))
(DTypeSig false "rewriteContainerLit" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteContainerLit" ((PCon "EMapLit" (PVar "name") (PVar "kvs"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "fromEntries")))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EVar "kvToTuple")) (EVar "kvs"))))) (EApp (EApp (EVar "pinType") (EVar "name")) (EListLit (EApp (EVar "TyVar") (ELit (LString "_k"))) (EApp (EVar "TyVar") (ELit (LString "_v")))))))
(DFunDef false "rewriteContainerLit" ((PCon "ESetLit" (PVar "name") (PVar "items"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "fromEntries")))) (EApp (EVar "EListLit") (EVar "items")))) (EApp (EApp (EVar "pinType") (EVar "name")) (EListLit (EApp (EVar "TyVar") (ELit (LString "_a")))))))
(DFunDef false "rewriteContainerLit" ((PVar "e")) (EVar "e"))
(DTypeSig false "kvToTuple" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyCon "Expr")))
(DFunDef false "kvToTuple" ((PTuple (PVar "k") (PVar "v"))) (EApp (EVar "ETuple") (EListLit (EVar "k") (EVar "v"))))
(DTypeSig false "pinType" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty"))))
(DFunDef false "pinType" ((PVar "name") (PVar "args")) (EApp (EApp (EVar "pinTypeGo") (EApp (EApp (EVar "TyCon") (EVar "name")) (EVar "None"))) (EVar "args")))
(DTypeSig false "pinTypeGo" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty"))))
(DFunDef false "pinTypeGo" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "pinTypeGo" ((PVar "acc") (PCons (PVar "t") (PVar "ts"))) (EApp (EApp (EVar "pinTypeGo") (EApp (EApp (EVar "TyApp") (EVar "acc")) (EVar "t"))) (EVar "ts")))
(DTypeSig false "moduleAliases" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleAliases" ((PList)) (EListLit))
(DFunDef false "moduleAliases" ((PCons (PCon "DUse" PWild (PCon "UseAlias" PWild (PVar "a")) PWild) (PVar "rest"))) (EBinOp "::" (EVar "a") (EApp (EVar "moduleAliases") (EVar "rest"))))
(DFunDef false "moduleAliases" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "moduleAliases") (EListLit (EVar "d"))) (EApp (EVar "moduleAliases") (EVar "rest"))))
(DFunDef false "moduleAliases" ((PCons PWild (PVar "rest"))) (EApp (EVar "moduleAliases") (EVar "rest")))
(DTypeSig false "qualifyAliasRefs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "qualifyAliasRefs" ((PVar "prog")) (EMatch (EApp (EVar "moduleAliases") (EVar "prog")) (arm (PList) () (EVar "prog")) (arm (PVar "aliases") () (EApp (EApp (EVar "mapProg") (EApp (EVar "rewriteAliasQual") (EVar "aliases"))) (EVar "prog")))))
(DTypeSig false "rewriteAliasQual" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteAliasQual" ((PVar "aliases") (PAs "e" (PCon "EFieldAccess" (PVar "head") (PVar "f") PWild))) (EMatch (EApp (EVar "stripLocE") (EVar "head")) (arm (PCon "EVar" (PVar "a")) () (EIf (EApp (EApp (EVar "contains") (EVar "a")) (EVar "aliases")) (EApp (EVar "EVar") (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "f"))) (EVar "e"))) (arm PWild () (EVar "e"))))
(DFunDef false "rewriteAliasQual" (PWild (PVar "e")) (EVar "e"))
(DTypeSig true "desugar" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "desugar" ((PVar "prog")) (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EApp (EVar "qualifyAliasRefs") (EVar "prog")) (EVar "mergeIfaceDefaults")) (EVar "fillImplDefaults")) (EApp (EVar "concatMapDecl") (EVar "expandDecl"))) (EVar "desugarRecordPuns")) (EVar "lowerContainerLiterals")) (EApp (EVar "mapProg") (EVar "rewriteDo"))) (EApp (EVar "mapProg") (EVar "rewriteAssignIndex"))) (EApp (EVar "mapProg") (EVar "rewriteSugar"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "Loc" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "qualifiedLocal" false) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Attr" false) (mem "Decl" true) (mem "DeriveRef" true) (mem "deriveRefName" false) (mem "Route" true))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "joinWith" false) (mem "contains" false) (mem "allList" false) (mem "fallthroughName" false) (mem "filterList" false) (mem "anyList" false))))
(DTypeSig true "mapExpr" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "mapExpr" ((PVar "f") (PVar "e")) (EApp (EVar "f") (EApp (EApp (EVar "mapKids") (EVar "f")) (EVar "e"))))
(DTypeSig false "mapKids" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "a"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "b"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "b"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ELet" (PVar "m") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e1"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e2"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ELetGroup" (PVar "bs") (PVar "e2"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapLetBind") (EVar "f"))) (EVar "bs"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e2"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapArm") (EVar "f"))) (EVar "arms"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "c"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "t"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "el"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "a"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "b"))) (EVar "r")))
(DFunDef false "mapKids" ((PVar "f") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "a"))) (EVar "r")))
(DFunDef false "mapKids" ((PVar "f") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "a"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "b"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EVar "n")) (EVar "r")))
(DFunDef false "mapKids" ((PVar "f") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapFieldAssign") (EVar "f"))) (EVar "fs"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapFieldAssign") (EVar "f"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "mapKids" ((PVar "f") (PCon "EVariantUpdate" (PVar "c") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapFieldAssign") (EVar "f"))) (EVar "fs"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapExpr") (EVar "f"))) (EVar "es"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapExpr") (EVar "f"))) (EVar "es"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapExpr") (EVar "f"))) (EVar "es"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EIndex" (PVar "e0") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "i"))) (EVar "r")))
(DFunDef false "mapKids" ((PVar "f") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "lo"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapKids" ((PVar "f") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "lo"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapKids" ((PVar "f") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "incl") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "lo"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "hi"))) (EVar "incl")) (EVar "r")))
(DFunDef false "mapKids" ((PVar "f") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapDoStmt") (EVar "f"))) (EVar "stmts"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapDoStmt") (EVar "f"))) (EVar "stmts"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EVar "t")))
(DFunDef false "mapKids" ((PVar "f") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapInterp") (EVar "f"))) (EVar "parts"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapGuardArm") (EVar "f"))) (EVar "arms"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e0")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0")))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ESection" (PCon "SecLeft" (PVar "e0") (PVar "op")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EVar "op"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapKv") (EVar "f"))) (EVar "kvs"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapExpr") (EVar "f"))) (EVar "es"))))
(DFunDef false "mapKids" ((PVar "f") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e0"))) (EVar "t")))
(DFunDef false "mapKids" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "mapKv" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "mapKv" ((PVar "f") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "k")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "v"))))
(DTypeSig false "mapArm" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "mapArm" ((PVar "f") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "b"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapGuard") (EVar "f"))) (EVar "gs"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "b"))))
(DTypeSig false "mapGuard" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Guard") (TyCon "Guard"))))
(DFunDef false "mapGuard" ((PVar "f") (PCon "GBool" (PVar "g"))) (EApp (EVar "GBool") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "g"))))
(DFunDef false "mapGuard" ((PVar "f") (PCon "GBind" (PVar "p") (PVar "g"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "g"))))
(DTypeSig false "mapGuardArm" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "mapGuardArm" ((PVar "f") (PCon "GuardArm" (PVar "gs") (PVar "b"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapGuard") (EVar "f"))) (EVar "gs"))) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "b"))))
(DTypeSig false "mapLetBind" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "mapLetBind" ((PVar "f") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapFunClause") (EVar "f"))) (EVar "clauses"))))
(DTypeSig false "mapFunClause" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "mapFunClause" ((PVar "f") (PCon "FunClause" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "b"))))
(DTypeSig false "mapFieldAssign" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "mapFieldAssign" ((PVar "f") (PCon "FieldAssign" (PVar "n") (PVar "v"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "v"))))
(DTypeSig false "mapDoStmt" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "mapDoStmt" ((PVar "f") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DFunDef false "mapDoStmt" ((PVar "f") (PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DFunDef false "mapDoStmt" ((PVar "f") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DFunDef false "mapDoStmt" ((PVar "f") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DFunDef false "mapDoStmt" ((PVar "f") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DTypeSig false "mapInterp" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "mapInterp" (PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "mapInterp" ((PVar "f") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DTypeSig true "mapDecl" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "mapDecl" ((PVar "f") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DFunDef false "mapDecl" ((PVar "f") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EVar "mapIfaceMethod") (EVar "f"))) (EVar "methods"))))))
(DFunDef false "mapDecl" ((PVar "f") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EVar "mapImplMethod") (EVar "f"))) (EVar "methods"))))))
(DFunDef false "mapDecl" ((PVar "f") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "body"))))
(DFunDef false "mapDecl" ((PVar "f") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "body"))))
(DFunDef false "mapDecl" ((PVar "f") (PCon "DBench" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DBench") (EVar "pub")) (EVar "name")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "body"))))
(DFunDef false "mapDecl" ((PVar "f") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "mapDecl") (EVar "f")) (EVar "d"))))
(DFunDef false "mapDecl" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "mapIfaceMethod" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))
(DFunDef false "mapIfaceMethod" (PWild (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None"))) (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EVar "None")))
(DFunDef false "mapIfaceMethod" ((PVar "f") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "e"))))) (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "ps")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))))
(DTypeSig false "mapImplMethod" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))
(DFunDef false "mapImplMethod" ((PVar "f") (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EApp (EApp (EVar "mapExpr") (EVar "f")) (EVar "e"))))
(DTypeSig true "mapProg" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "mapProg" ((PVar "f") (PVar "prog")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapDecl") (EVar "f"))) (EVar "prog")))
(DTypeSig false "callBin" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "callBin" ((PVar "fn") (PVar "a") (PVar "b")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b")))
(DTypeSig false "binOp" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "binOp" ((PVar "op") (PVar "a") (PVar "b")) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "a")) (EVar "b")) (EApp (EVar "Ref") (EVar "RNone"))))
(DTypeSig false "intLit" (TyFun (TyCon "Int") (TyCon "Expr")))
(DFunDef false "intLit" ((PVar "n")) (EApp (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EApp (EVar "Ref") (EVar "None"))) (EApp (EVar "Ref") (EVar "RNone"))) (ELit (LString ""))))
(DTypeSig false "derivedImpl" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "Decl")))))
(DFunDef false "derivedImpl" ((PVar "iface") (PVar "tyName") (PVar "methods")) (ERecordCreate "DImpl" ((fa "pub" (EVar "True")) (fa "iface" (EVar "iface")) (fa "tys" (EListLit (EApp (EApp (EVar "TyCon") (EVar "tyName")) (EVar "None")))) (fa "reqs" (EListLit)) (fa "methods" (EVar "methods")))))
(DTypeSig false "binMethod" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "ImplMethod"))))))
(DFunDef false "binMethod" ((PVar "m") (PVar "a") (PVar "b") (PVar "body")) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "m")) (EListLit (EApp (EVar "PVar") (EVar "a")) (EApp (EVar "PVar") (EVar "b")))) (EVar "body")))
(DTypeSig false "rewriteSugar" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteSugar" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "guardsToCore") (EVar "arms")))
(DFunDef false "rewriteSugar" ((PCon "ESection" (PVar "s"))) (EApp (EVar "sectionToCore") (EVar "s")))
(DFunDef false "rewriteSugar" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "interpToCore") (EVar "parts")))
(DFunDef false "rewriteSugar" ((PCon "EBinOp" (PLit (LString ":=")) (PVar "lhs") (PVar "rhs") PWild)) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "setRef"))) (EVar "lhs")) (EVar "rhs")))
(DFunDef false "rewriteSugar" ((PCon "EIndex" (PVar "a") (PVar "i") PWild)) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "index"))) (EVar "a")) (EVar "i")))
(DFunDef false "rewriteSugar" ((PVar "e")) (EVar "e"))
(DTypeSig false "rewriteAssignIndex" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteAssignIndex" ((PCon "EBinOp" (PLit (LString ":=")) (PVar "lhs") (PVar "v") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "assignIndexLhs") (EApp (EVar "stripLocE") (EVar "lhs"))) (EVar "lhs")) (EVar "v")) (EVar "r")))
(DFunDef false "rewriteAssignIndex" ((PVar "e")) (EVar "e"))
(DTypeSig false "assignIndexLhs" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "Expr"))))))
(DFunDef false "assignIndexLhs" ((PCon "EIndex" (PVar "a") (PVar "i") PWild) PWild (PVar "v") PWild) (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EVar "callBin") (ELit (LString "setIndex"))) (EVar "a")) (EVar "i"))) (EVar "v")))
(DFunDef false "assignIndexLhs" (PWild (PVar "lhs") (PVar "v") (PVar "r")) (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString ":="))) (EVar "lhs")) (EVar "v")) (EVar "r")))
(DTypeSig false "stripLocE" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripLocE" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stripLocE") (EVar "e")))
(DFunDef false "stripLocE" ((PVar "e")) (EVar "e"))
(DTypeSig false "guardsToCore" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyCon "Expr")))
(DFunDef false "guardsToCore" ((PList)) (EVar "fallthrough"))
(DFunDef false "guardsToCore" ((PCons (PCon "GuardArm" (PVar "quals") (PVar "body")) (PVar "rest"))) (EApp (EApp (EApp (EVar "armChain") (EVar "quals")) (EVar "body")) (EApp (EVar "guardsToCore") (EVar "rest"))))
(DTypeSig false "fallthrough" (TyCon "Expr"))
(DFunDef false "fallthrough" () (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fallthroughName"))) (EApp (EVar "ELit") (EVar "LUnit"))))
(DTypeSig false "armChain" (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "armChain" ((PList) (PVar "body") PWild) (EVar "body"))
(DFunDef false "armChain" ((PCons (PCon "GBool" (PVar "e")) (PVar "qs")) (PVar "body") (PVar "els")) (EApp (EApp (EApp (EVar "EIf") (EVar "e")) (EApp (EApp (EApp (EVar "armChain") (EVar "qs")) (EVar "body")) (EVar "els"))) (EVar "els")))
(DFunDef false "armChain" ((PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "qs")) (PVar "body") (PVar "els")) (EApp (EApp (EVar "EMatch") (EVar "e")) (EListLit (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EListLit)) (EApp (EApp (EApp (EVar "armChain") (EVar "qs")) (EVar "body")) (EVar "els"))) (EApp (EApp (EApp (EVar "Arm") (EVar "PWild")) (EListLit)) (EVar "els")))))
(DTypeSig false "sectionToCore" (TyFun (TyCon "Section") (TyCon "Expr")))
(DFunDef false "sectionToCore" ((PCon "SecBare" (PVar "op"))) (EApp (EApp (EVar "ELam") (EListLit (EApp (EVar "PVar") (ELit (LString "_a"))) (EApp (EVar "PVar") (ELit (LString "_b"))))) (EApp (EApp (EApp (EVar "binOp") (EVar "op")) (EApp (EVar "EVar") (ELit (LString "_a")))) (EApp (EVar "EVar") (ELit (LString "_b"))))))
(DFunDef false "sectionToCore" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "ELam") (EListLit (EApp (EVar "PVar") (ELit (LString "_s"))))) (EApp (EApp (EApp (EVar "binOp") (EVar "op")) (EApp (EVar "EVar") (ELit (LString "_s")))) (EVar "e"))))
(DFunDef false "sectionToCore" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "ELam") (EListLit (EApp (EVar "PVar") (ELit (LString "_s"))))) (EApp (EApp (EApp (EVar "binOp") (EVar "op")) (EVar "e")) (EApp (EVar "EVar") (ELit (LString "_s"))))))
(DTypeSig false "interpToCore" (TyFun (TyApp (TyCon "List") (TyCon "InterpPart")) (TyCon "Expr")))
(DFunDef false "interpToCore" ((PVar "parts")) (EApp (EVar "concatStrings") (EApp (EApp (EMethodRef "map") (EVar "interpPartToExpr")) (EVar "parts"))))
(DTypeSig false "interpPartToExpr" (TyFun (TyCon "InterpPart") (TyCon "Expr")))
(DFunDef false "interpPartToExpr" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "s"))))
(DFunDef false "interpPartToExpr" ((PCon "InterpExpr" (PVar "e"))) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "display")))) (EVar "e")))
(DTypeSig false "concatStrings" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr")))
(DFunDef false "concatStrings" ((PList)) (EApp (EVar "ELit") (EApp (EVar "LString") (ELit (LString "")))))
(DFunDef false "concatStrings" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "concatStrings" ((PCons (PVar "first") (PVar "rest"))) (EApp (EApp (EVar "concatLeft") (EVar "first")) (EVar "rest")))
(DTypeSig false "concatLeft" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "concatLeft" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "concatLeft" ((PVar "acc") (PCons (PVar "e") (PVar "rest"))) (EApp (EApp (EVar "concatLeft") (EApp (EApp (EApp (EVar "binOp") (ELit (LString "++"))) (EVar "acc")) (EVar "e"))) (EVar "rest")))
(DTypeSig false "rewriteDo" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteDo" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "wrapDoOrigin") (EVar "stmts")) (EApp (EVar "lowerDo") (EVar "stmts"))))
(DFunDef false "rewriteDo" ((PVar "e")) (EVar "e"))
(DTypeSig false "wrapDoOrigin" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "wrapDoOrigin" ((PList (PCon "DoExpr" PWild)) (PVar "lowered")) (EVar "lowered"))
(DFunDef false "wrapDoOrigin" ((PVar "stmts") (PVar "lowered")) (EMatch (EApp (EVar "firstDoStmtLoc") (EVar "stmts")) (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EVar "lowered"))) (arm (PCon "None") () (EVar "lowered"))))
(DTypeSig false "firstDoStmtLoc" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstDoStmtLoc" ((PList)) (EVar "None"))
(DFunDef false "firstDoStmtLoc" ((PCons (PVar "s") (PVar "rest"))) (EMatch (EApp (EVar "doStmtLoc") (EVar "s")) (arm (PCon "Some" (PVar "l")) () (EApp (EVar "Some") (EVar "l"))) (arm (PCon "None") () (EApp (EVar "firstDoStmtLoc") (EVar "rest")))))
(DTypeSig false "doStmtLoc" (TyFun (TyCon "DoStmt") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "doStmtLoc" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "exprLoc") (EVar "e")))
(DFunDef false "doStmtLoc" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "exprLoc") (EVar "e")))
(DFunDef false "doStmtLoc" ((PCon "DoLet" PWild PWild PWild (PVar "e"))) (EApp (EVar "exprLoc") (EVar "e")))
(DFunDef false "doStmtLoc" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "exprLoc") (EVar "e")))
(DFunDef false "doStmtLoc" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "exprLoc") (EVar "e")))
(DTypeSig false "exprLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "exprLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "exprLoc" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "exprLoc") (EVar "f")))
(DFunDef false "exprLoc" (PWild) (EVar "None"))
(DTypeSig false "lowerDo" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Expr")))
(DFunDef false "lowerDo" ((PList (PCon "DoExpr" (PVar "e")))) (EVar "e"))
(DFunDef false "lowerDo" ((PList (PCon "DoBind" (PVar "pat") (PVar "e")))) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "andThen"))) (EVar "e")) (EApp (EApp (EVar "doCont") (EVar "pat")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "pure")))) (EApp (EVar "ELit") (EVar "LUnit"))))))
(DFunDef false "lowerDo" ((PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "andThen"))) (EVar "e")) (EApp (EApp (EVar "ELam") (EListLit (EVar "PWild"))) (EApp (EVar "lowerDo") (EVar "rest")))))
(DFunDef false "lowerDo" ((PCons (PCon "DoBind" (PVar "pat") (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "andThen"))) (EVar "e")) (EApp (EApp (EVar "doCont") (EVar "pat")) (EApp (EVar "lowerDo") (EVar "rest")))))
(DFunDef false "lowerDo" ((PCons (PCon "DoLet" PWild (PVar "isFun") (PVar "pat") (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "False")) (EVar "isFun")) (EVar "pat")) (EVar "e")) (EApp (EVar "lowerDo") (EVar "rest"))))
(DFunDef false "lowerDo" (PWild) (EVar "fallthrough"))
(DTypeSig false "doCont" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "doCont" ((PVar "pat") (PVar "body")) (EIf (EApp (EVar "isRefutable") (EVar "pat")) (EApp (EApp (EVar "ELam") (EListLit (EApp (EVar "PVar") (ELit (LString "__do_x"))))) (EApp (EApp (EVar "EMatch") (EApp (EVar "EVar") (ELit (LString "__do_x")))) (EListLit (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EListLit)) (EVar "body")) (EApp (EApp (EApp (EVar "Arm") (EVar "PWild")) (EListLit)) (EVar "fallthrough"))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ELam") (EListLit (EVar "pat"))) (EVar "body")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isRefutable" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isRefutable" ((PCon "PVar" PWild)) (EVar "False"))
(DFunDef false "isRefutable" ((PCon "PWild")) (EVar "False"))
(DFunDef false "isRefutable" ((PCon "PLit" PWild)) (EVar "True"))
(DFunDef false "isRefutable" ((PCon "PCon" PWild PWild)) (EVar "True"))
(DFunDef false "isRefutable" ((PCon "PCons" PWild PWild)) (EVar "True"))
(DFunDef false "isRefutable" ((PCon "PList" PWild)) (EVar "True"))
(DFunDef false "isRefutable" ((PCon "PRng" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isRefutable" ((PCon "PRec" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isRefutable" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "anyRefutable") (EVar "ps")))
(DFunDef false "isRefutable" ((PCon "PAs" PWild (PVar "p"))) (EApp (EVar "isRefutable") (EVar "p")))
(DTypeSig false "anyRefutable" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool")))
(DFunDef false "anyRefutable" ((PList)) (EVar "False"))
(DFunDef false "anyRefutable" ((PCons (PVar "p") (PVar "ps"))) (EBinOp "||" (EApp (EVar "isRefutable") (EVar "p")) (EApp (EVar "anyRefutable") (EVar "ps"))))
(DTypeSig false "expandDecl" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "expandDecl" ((PCon "DData" (PVar "vis") (PVar "name") (PVar "params") (PVar "variants") (PVar "derives"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "DData") (EVar "vis")) (EVar "name")) (EVar "params")) (EVar "variants")) (EListLit)) (EApp (EApp (EVar "deriveImpls") (EApp (EApp (EApp (EVar "deriveForData") (EVar "name")) (EVar "params")) (EVar "variants"))) (EVar "derives"))))
(DFunDef false "expandDecl" ((PCon "DNewtype" (PVar "vis") (PVar "name") (PVar "params") (PVar "con") (PVar "fty") (PVar "derives"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DNewtype") (EVar "vis")) (EVar "name")) (EVar "params")) (EVar "con")) (EVar "fty")) (EListLit)) (EApp (EApp (EVar "deriveImpls") (EApp (EApp (EApp (EApp (EVar "deriveForNewtype") (EVar "name")) (EVar "params")) (EVar "con")) (EVar "fty"))) (EVar "derives"))))
(DFunDef false "expandDecl" ((PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "attribHead") (EVar "attrs")) (EApp (EVar "expandDecl") (EVar "d"))))
(DFunDef false "expandDecl" ((PVar "d")) (EListLit (EVar "d")))
(DTypeSig false "attribHead" (TyFun (TyApp (TyCon "List") (TyCon "Attr")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "attribHead" (PWild (PList)) (EListLit))
(DFunDef false "attribHead" ((PVar "attrs") (PCons (PVar "first") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EVar "first")) (EVar "rest")))
(DTypeSig false "deriveImpls" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Decl"))) (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "deriveImpls" (PWild (PList)) (EListLit))
(DFunDef false "deriveImpls" ((PVar "f") (PCons (PVar "d") (PVar "ds"))) (EMatch (EApp (EVar "f") (EApp (EVar "deriveRefName") (EVar "d"))) (arm (PCon "Some" (PVar "gen")) () (EBinOp "::" (EVar "gen") (EApp (EApp (EVar "deriveImpls") (EVar "f")) (EVar "ds")))) (arm (PCon "None") () (EApp (EApp (EVar "deriveImpls") (EVar "f")) (EVar "ds")))))
(DTypeSig false "dataDerivers" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Decl"))))))))
(DFunDef false "dataDerivers" ((PVar "name") (PVar "params") (PVar "variants")) (EListLit (ETuple (ELit (LString "Eq")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EVar "deriveEqData") (EVar "name")) (EVar "variants"))))) (ETuple (ELit (LString "Ord")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EVar "deriveOrdData") (EVar "name")) (EVar "variants"))))) (ETuple (ELit (LString "Debug")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "deriveShowData") (ELit (LString "Debug"))) (ELit (LString "debug"))) (EVar "name")) (EVar "variants"))))) (ETuple (ELit (LString "Display")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "deriveShowData") (ELit (LString "Display"))) (ELit (LString "display"))) (EVar "name")) (EVar "variants"))))) (ETuple (ELit (LString "Generic")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EVar "deriveGenericData") (EVar "name")) (EVar "variants"))))) (ETuple (ELit (LString "Hashable")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EVar "deriveHashData") (EVar "name")) (EVar "variants")))))))
(DTypeSig false "lookupDeriver" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Decl")))) (TyApp (TyCon "Option") (TyCon "Decl")))))
(DFunDef false "lookupDeriver" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupDeriver" ((PVar "n") (PCons (PTuple (PVar "k") (PVar "f")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "k")) (EApp (EVar "Some") (EApp (EVar "f") (ELit LUnit))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupDeriver") (EVar "n")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "deriveForData" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Decl")))))))
(DFunDef false "deriveForData" ((PVar "name") (PVar "params") (PVar "variants") (PVar "iface")) (EApp (EApp (EVar "lookupDeriver") (EVar "iface")) (EApp (EApp (EApp (EVar "dataDerivers") (EVar "name")) (EVar "params")) (EVar "variants"))))
(DTypeSig false "newtypeDerivers" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyFun (TyCon "Unit") (TyCon "Decl")))))))))
(DFunDef false "newtypeDerivers" ((PVar "name") (PVar "params") (PVar "con") (PVar "fty")) (EBlock (DoLet false false (PVar "synthetic") (EListLit (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty")))))) (DoExpr (EListLit (ETuple (ELit (LString "Eq")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EVar "deriveEqData") (EVar "name")) (EVar "synthetic"))))) (ETuple (ELit (LString "Ord")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EVar "deriveOrdData") (EVar "name")) (EVar "synthetic"))))) (ETuple (ELit (LString "Debug")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "deriveShowData") (ELit (LString "Debug"))) (ELit (LString "debug"))) (EVar "name")) (EVar "synthetic"))))) (ETuple (ELit (LString "Display")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "deriveShowData") (ELit (LString "Display"))) (ELit (LString "display"))) (EVar "name")) (EVar "synthetic"))))) (ETuple (ELit (LString "Hashable")) (ELam (PWild) (EApp (EApp (EApp (EVar "applyDeriveParams") (EVar "name")) (EVar "params")) (EApp (EApp (EVar "deriveHashData") (EVar "name")) (EVar "synthetic")))))))))
(DTypeSig false "deriveForNewtype" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Decl"))))))))
(DFunDef false "deriveForNewtype" ((PVar "name") (PVar "params") (PVar "con") (PVar "fty") (PVar "iface")) (EApp (EApp (EVar "lookupDeriver") (EVar "iface")) (EApp (EApp (EApp (EApp (EVar "newtypeDerivers") (EVar "name")) (EVar "params")) (EVar "con")) (EVar "fty"))))
(DTypeSig true "checkDerives" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "checkDerives" ((PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EVar "declDeriveErrors")) (EVar "decls")))
(DTypeSig false "declDeriveErrors" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "declDeriveErrors" ((PCon "DData" PWild (PVar "name") (PVar "params") (PVar "variants") (PVar "derives"))) (EMatch (EVar "derives") (arm (PList) () (EListLit)) (arm PWild () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "unknownDerive") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EApp (EVar "dataDerivers") (EVar "name")) (EVar "params")) (EVar "variants"))))) (EVar "derives")))))
(DFunDef false "declDeriveErrors" ((PCon "DNewtype" PWild (PVar "name") (PVar "params") (PVar "con") (PVar "fty") (PVar "derives"))) (EMatch (EVar "derives") (arm (PList) () (EListLit)) (arm PWild () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "unknownDerive") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EApp (EApp (EVar "newtypeDerivers") (EVar "name")) (EVar "params")) (EVar "con")) (EVar "fty"))))) (EVar "derives")))))
(DFunDef false "declDeriveErrors" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declDeriveErrors") (EVar "d")))
(DFunDef false "declDeriveErrors" (PWild) (EListLit))
(DTypeSig false "unknownDerive" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "DeriveRef") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))))
(DFunDef false "unknownDerive" ((PVar "tyName") (PVar "supported") (PCon "DeriveRef" (PVar "n") (PVar "loc"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "supported")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EApp (EApp (EApp (EVar "cannotDeriveMsg") (EVar "tyName")) (EVar "supported")) (EVar "n")) (EVar "loc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "cannotDeriveMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "cannotDeriveMsg" ((PVar "tyName") (PVar "supported") (PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot derive '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' for '"))) (EApp (EMethodRef "display") (EVar "tyName"))) (ELit (LString "'; supported: "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "supported")))) (ELit (LString ""))))
(DTypeSig false "applyDeriveParams" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl")))))
(DFunDef false "applyDeriveParams" ((PVar "name") (PVar "params") (PAs "d" (PRec "DImpl" ((rf "iface" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "tys" (EListLit (EApp (EApp (EVar "appliedHead") (EVar "name")) (EVar "params")))) (fa "reqs" (EApp (EApp (EVar "paramRequires") (EVar "iface")) (EVar "params"))))))
(DFunDef false "applyDeriveParams" (PWild PWild (PVar "d")) (EVar "d"))
(DTypeSig false "appliedHead" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))
(DFunDef false "appliedHead" ((PVar "name") (PVar "params")) (EApp (EApp (EVar "appliedHeadGo") (EApp (EApp (EVar "TyCon") (EVar "name")) (EVar "None"))) (EVar "params")))
(DTypeSig false "appliedHeadGo" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))
(DFunDef false "appliedHeadGo" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "appliedHeadGo" ((PVar "acc") (PCons (PVar "p") (PVar "ps"))) (EApp (EApp (EVar "appliedHeadGo") (EApp (EApp (EVar "TyApp") (EVar "acc")) (EApp (EVar "TyVar") (EVar "p")))) (EVar "ps")))
(DTypeSig false "paramRequires" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Require")))))
(DFunDef false "paramRequires" ((PVar "iface") (PVar "params")) (EApp (EApp (EMethodRef "map") (EApp (EVar "paramReq") (EVar "iface"))) (EVar "params")))
(DTypeSig false "paramReq" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Require"))))
(DFunDef false "paramReq" ((PVar "iface") (PVar "p")) (EApp (EApp (EVar "Require") (EVar "iface")) (EListLit (EApp (EVar "TyVar") (EVar "p")))))
(DTypeSig false "conArity" (TyFun (TyCon "Variant") (TyCon "Int")))
(DFunDef false "conArity" ((PCon "Variant" PWild (PCon "ConPos" (PVar "tys")))) (EApp (EVar "listLen") (EVar "tys")))
(DFunDef false "conArity" ((PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EVar "listLen") (EVar "fs")))
(DTypeSig false "genVars" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "genVars" ((PVar "prefix") (PVar "n")) (EApp (EApp (EApp (EVar "genVarsGo") (EVar "prefix")) (ELit (LInt 0))) (EVar "n")))
(DTypeSig false "genVarsGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "genVarsGo" ((PVar "prefix") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EVar "prefix") (EApp (EVar "intToString") (EVar "i"))) (EApp (EApp (EApp (EVar "genVarsGo") (EVar "prefix")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "conBindPat" (TyFun (TyCon "Variant") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Pat"))))
(DFunDef false "conBindPat" ((PCon "Variant" (PVar "cname") (PCon "ConPos" PWild)) (PVar "vars")) (EApp (EApp (EVar "PCon") (EVar "cname")) (EApp (EApp (EMethodRef "map") (EVar "PVar")) (EVar "vars"))))
(DFunDef false "conBindPat" ((PCon "Variant" (PVar "cname") (PCon "ConNamed" (PVar "fs") PWild)) (PVar "vars")) (EApp (EApp (EApp (EVar "PRec") (EVar "cname")) (EApp (EApp (EVar "recPatFields") (EVar "fs")) (EVar "vars"))) (EVar "False")))
(DTypeSig false "recPatFields" (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "RecPatField")))))
(DFunDef false "recPatFields" ((PList) PWild) (EListLit))
(DFunDef false "recPatFields" (PWild (PList)) (EListLit))
(DFunDef false "recPatFields" ((PCons (PCon "Field" (PVar "n") PWild) (PVar "fs")) (PCons (PVar "v") (PVar "vs"))) (EBinOp "::" (EApp (EApp (EVar "RecPatField") (EVar "n")) (EApp (EVar "Some") (EApp (EVar "PVar") (EVar "v")))) (EApp (EApp (EVar "recPatFields") (EVar "fs")) (EVar "vs"))))
(DTypeSig false "deriveShowData" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Decl"))))))
(DFunDef false "deriveShowData" ((PVar "iface") (PVar "callName") (PVar "name") (PVar "variants")) (EApp (EApp (EApp (EVar "derivedImpl") (EVar "iface")) (EVar "name")) (EListLit (EApp (EApp (EApp (EVar "ImplMethod") (EVar "callName")) (EListLit (EApp (EVar "PVar") (ELit (LString "__x"))))) (EApp (EApp (EVar "EMatch") (EApp (EVar "EVar") (ELit (LString "__x")))) (EApp (EApp (EMethodRef "map") (EApp (EVar "showArm") (EVar "callName"))) (EVar "variants")))))))
(DTypeSig false "showArm" (TyFun (TyCon "String") (TyFun (TyCon "Variant") (TyCon "Arm"))))
(DFunDef false "showArm" ((PVar "callName") (PAs "v" (PCon "Variant" (PVar "cname") (PVar "payload")))) (EBlock (DoLet false false (PVar "vars") (EApp (EApp (EVar "genVars") (ELit (LString "__a"))) (EApp (EVar "conArity") (EVar "v")))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EApp (EApp (EVar "conBindPat") (EVar "v")) (EVar "vars"))) (EListLit)) (EApp (EApp (EApp (EApp (EVar "showBody") (EVar "callName")) (EVar "cname")) (EVar "payload")) (EVar "vars"))))))
(DTypeSig false "showBody" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ConPayload") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr"))))))
(DFunDef false "showBody" (PWild (PVar "cname") PWild (PList)) (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "cname"))))
(DFunDef false "showBody" ((PVar "callName") (PVar "cname") (PCon "ConNamed" (PVar "fs") PWild) (PCons (PVar "v") (PVar "vs"))) (EApp (EVar "concatStrings") (EBinOp "::" (EApp (EVar "ELit") (EApp (EVar "LString") (EBinOp "++" (EVar "cname") (ELit (LString " {"))))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "showNamedParts") (EVar "callName")) (ELit (LInt 0))) (EVar "fs")) (EBinOp "::" (EVar "v") (EVar "vs"))) (EListLit (EApp (EVar "ELit") (EApp (EVar "LString") (ELit (LString " }")))))))))
(DFunDef false "showBody" ((PVar "callName") (PVar "cname") PWild (PCons (PVar "v") (PVar "vs"))) (EApp (EVar "concatStrings") (EBinOp "::" (EApp (EVar "ELit") (EApp (EVar "LString") (EBinOp "++" (EVar "cname") (ELit (LString " "))))) (EApp (EApp (EApp (EVar "showFieldParts") (EVar "callName")) (ELit (LInt 0))) (EBinOp "::" (EVar "v") (EVar "vs"))))))
(DTypeSig false "showFieldParts" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "showFieldParts" (PWild PWild (PList)) (EListLit))
(DFunDef false "showFieldParts" ((PVar "callName") (PVar "i") (PCons (PVar "v") (PVar "vs"))) (EBinOp "++" (EApp (EApp (EApp (EVar "showFieldPart") (EVar "callName")) (EVar "i")) (EVar "v")) (EApp (EApp (EApp (EVar "showFieldParts") (EVar "callName")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "vs"))))
(DTypeSig false "showFieldPart" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "showFieldPart" ((PVar "callName") (PLit (LInt 0)) (PVar "v")) (EListLit (EApp (EApp (EVar "wrappedFieldCall") (EVar "callName")) (EVar "v"))))
(DFunDef false "showFieldPart" ((PVar "callName") PWild (PVar "v")) (EListLit (EApp (EVar "ELit") (EApp (EVar "LString") (ELit (LString " ")))) (EApp (EApp (EVar "wrappedFieldCall") (EVar "callName")) (EVar "v"))))
(DTypeSig false "wrappedFieldCall" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Expr"))))
(DFunDef false "wrappedFieldCall" ((PVar "callName") (PVar "v")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "derivedShowWrap")))) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "callName"))) (EApp (EVar "EVar") (EVar "v")))))
(DTypeSig false "showNamedParts" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "showNamedParts" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "showNamedParts" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "showNamedParts" ((PVar "callName") (PVar "i") (PCons (PCon "Field" (PVar "fn") PWild) (PVar "fs")) (PCons (PVar "v") (PVar "vs"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "showNamedPart") (EVar "callName")) (EVar "i")) (EVar "fn")) (EVar "v")) (EApp (EApp (EApp (EApp (EVar "showNamedParts") (EVar "callName")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "fs")) (EVar "vs"))))
(DTypeSig false "showNamedPart" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Expr")))))))
(DFunDef false "showNamedPart" ((PVar "callName") (PLit (LInt 0)) (PVar "fn") (PVar "v")) (EListLit (EApp (EVar "ELit") (EApp (EVar "LString") (EBinOp "++" (EBinOp "++" (ELit (LString " ")) (EApp (EMethodRef "display") (EVar "fn"))) (ELit (LString " = "))))) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "callName"))) (EApp (EVar "EVar") (EVar "v")))))
(DFunDef false "showNamedPart" ((PVar "callName") PWild (PVar "fn") (PVar "v")) (EListLit (EApp (EVar "ELit") (EApp (EVar "LString") (EBinOp "++" (EBinOp "++" (ELit (LString ", ")) (EApp (EMethodRef "display") (EVar "fn"))) (ELit (LString " = "))))) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "callName"))) (EApp (EVar "EVar") (EVar "v")))))
(DTypeSig false "deriveEqData" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Decl"))))
(DFunDef false "deriveEqData" ((PVar "name") (PVar "variants")) (EApp (EApp (EApp (EVar "derivedImpl") (ELit (LString "Eq"))) (EVar "name")) (EListLit (EApp (EApp (EApp (EApp (EVar "binMethod") (ELit (LString "eq"))) (ELit (LString "__x"))) (ELit (LString "__y"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "ETuple") (EListLit (EApp (EVar "EVar") (ELit (LString "__x"))) (EApp (EVar "EVar") (ELit (LString "__y")))))) (EApp (EVar "eqArms") (EVar "variants")))))))
(DTypeSig false "eqArms" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Arm"))))
(DFunDef false "eqArms" ((PVar "variants")) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "variants")) (ELit (LInt 1))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "eqSameConArm")) (EVar "variants")) (EListLit (EApp (EApp (EApp (EVar "Arm") (EApp (EVar "PTuple") (EListLit (EVar "PWild") (EVar "PWild")))) (EListLit)) (EApp (EVar "EVar") (ELit (LString "False")))))) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "map") (EVar "eqSameConArm")) (EVar "variants")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "eqSameConArm" (TyFun (TyCon "Variant") (TyCon "Arm")))
(DFunDef false "eqSameConArm" ((PAs "v" (PCon "Variant" PWild PWild))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "conArity") (EVar "v"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EApp (EVar "PTuple") (EListLit (EApp (EApp (EVar "conBindPat") (EVar "v")) (EApp (EApp (EVar "genVars") (ELit (LString "__a"))) (EVar "n"))) (EApp (EApp (EVar "conBindPat") (EVar "v")) (EApp (EApp (EVar "genVars") (ELit (LString "__b"))) (EVar "n")))))) (EListLit)) (EApp (EApp (EApp (EVar "eqBody") (EVar "n")) (EApp (EApp (EVar "genVars") (ELit (LString "__a"))) (EVar "n"))) (EApp (EApp (EVar "genVars") (ELit (LString "__b"))) (EVar "n")))))))
(DTypeSig false "eqBody" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr")))))
(DFunDef false "eqBody" ((PLit (LInt 0)) PWild PWild) (EApp (EVar "EVar") (ELit (LString "True"))))
(DFunDef false "eqBody" (PWild (PVar "avars") (PVar "bvars")) (EApp (EVar "andAll") (EApp (EApp (EVar "zipEqCalls") (EVar "avars")) (EVar "bvars"))))
(DTypeSig false "zipEqCalls" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "zipEqCalls" ((PList) PWild) (EListLit))
(DFunDef false "zipEqCalls" (PWild (PList)) (EListLit))
(DFunDef false "zipEqCalls" ((PCons (PVar "a") (PVar "arest")) (PCons (PVar "b") (PVar "brest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "callBin") (ELit (LString "eq"))) (EApp (EVar "EVar") (EVar "a"))) (EApp (EVar "EVar") (EVar "b"))) (EApp (EApp (EVar "zipEqCalls") (EVar "arest")) (EVar "brest"))))
(DTypeSig false "andAll" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr")))
(DFunDef false "andAll" ((PList)) (EApp (EVar "EVar") (ELit (LString "True"))))
(DFunDef false "andAll" ((PCons (PVar "first") (PVar "rest"))) (EApp (EApp (EVar "andLeft") (EVar "first")) (EVar "rest")))
(DTypeSig false "andLeft" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "andLeft" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "andLeft" ((PVar "acc") (PCons (PVar "e") (PVar "rest"))) (EApp (EApp (EVar "andLeft") (EApp (EApp (EApp (EVar "binOp") (ELit (LString "&&"))) (EVar "acc")) (EVar "e"))) (EVar "rest")))
(DTypeSig false "deriveOrdData" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Decl"))))
(DFunDef false "deriveOrdData" ((PVar "name") (PVar "variants")) (EApp (EApp (EApp (EVar "derivedImpl") (ELit (LString "Ord"))) (EVar "name")) (EListLit (EApp (EApp (EApp (EApp (EVar "binMethod") (ELit (LString "compare"))) (ELit (LString "__x"))) (ELit (LString "__y"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "ETuple") (EListLit (EApp (EVar "EVar") (ELit (LString "__x"))) (EApp (EVar "EVar") (ELit (LString "__y")))))) (EApp (EVar "ordArms") (EVar "variants")))))))
(DTypeSig false "ordArms" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Arm"))))
(DFunDef false "ordArms" ((PVar "variants")) (EBlock (DoLet false false (PVar "indexed") (EApp (EApp (EVar "indexFrom") (ELit (LInt 0))) (EVar "variants"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EVar "ordRow") (EVar "indexed"))) (EVar "indexed")))))
(DTypeSig false "indexFrom" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyVar "a"))))))
(DFunDef false "indexFrom" (PWild (PList)) (EListLit))
(DFunDef false "indexFrom" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (ETuple (EVar "i") (EVar "x")) (EApp (EApp (EVar "indexFrom") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "xs"))))
(DTypeSig false "ordRow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Variant"))) (TyFun (TyTuple (TyCon "Int") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Arm")))))
(DFunDef false "ordRow" ((PVar "indexed") (PTuple (PVar "i") (PVar "vi"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ordCell") (EVar "i")) (EVar "vi"))) (EVar "indexed")))
(DTypeSig false "ordCell" (TyFun (TyCon "Int") (TyFun (TyCon "Variant") (TyFun (TyTuple (TyCon "Int") (TyCon "Variant")) (TyCon "Arm")))))
(DFunDef false "ordCell" ((PVar "i") (PVar "vi") (PTuple (PVar "j") (PVar "vj"))) (EBlock (DoLet false false (PVar "avars") (EApp (EApp (EVar "genVars") (ELit (LString "__a"))) (EApp (EVar "conArity") (EVar "vi")))) (DoLet false false (PVar "bvars") (EApp (EApp (EVar "genVars") (ELit (LString "__b"))) (EApp (EVar "conArity") (EVar "vj")))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EApp (EVar "PTuple") (EListLit (EApp (EApp (EVar "conBindPat") (EVar "vi")) (EVar "avars")) (EApp (EApp (EVar "conBindPat") (EVar "vj")) (EVar "bvars"))))) (EListLit)) (EApp (EApp (EApp (EApp (EVar "ordBody") (EVar "i")) (EVar "j")) (EVar "avars")) (EVar "bvars"))))))
(DTypeSig false "ordBody" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr"))))))
(DFunDef false "ordBody" ((PVar "i") (PVar "j") (PVar "avars") (PVar "bvars")) (EIf (EBinOp "<" (EVar "i") (EVar "j")) (EApp (EVar "EVar") (ELit (LString "Lt"))) (EIf (EBinOp ">" (EVar "i") (EVar "j")) (EApp (EVar "EVar") (ELit (LString "Gt"))) (EIf (EVar "otherwise") (EApp (EVar "lexCompareExprs") (EApp (EApp (EVar "zipExprPairs") (EVar "avars")) (EVar "bvars"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "zipExprPairs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "zipExprPairs" ((PList) PWild) (EListLit))
(DFunDef false "zipExprPairs" (PWild (PList)) (EListLit))
(DFunDef false "zipExprPairs" ((PCons (PVar "a") (PVar "arest")) (PCons (PVar "b") (PVar "brest"))) (EBinOp "::" (ETuple (EApp (EVar "EVar") (EVar "a")) (EApp (EVar "EVar") (EVar "b"))) (EApp (EApp (EVar "zipExprPairs") (EVar "arest")) (EVar "brest"))))
(DTypeSig false "lexCompareExprs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))) (TyCon "Expr")))
(DFunDef false "lexCompareExprs" ((PList)) (EApp (EVar "EVar") (ELit (LString "Eq"))))
(DFunDef false "lexCompareExprs" ((PList (PTuple (PVar "ea") (PVar "eb")))) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "compare"))) (EVar "ea")) (EVar "eb")))
(DFunDef false "lexCompareExprs" ((PCons (PTuple (PVar "ea") (PVar "eb")) (PVar "rest"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EApp (EVar "callBin") (ELit (LString "compare"))) (EVar "ea")) (EVar "eb"))) (EListLit (EApp (EApp (EApp (EVar "Arm") (EApp (EApp (EVar "PCon") (ELit (LString "Eq"))) (EListLit))) (EListLit)) (EApp (EVar "lexCompareExprs") (EVar "rest"))) (EApp (EApp (EApp (EVar "Arm") (EApp (EVar "PVar") (ELit (LString "__c")))) (EListLit)) (EApp (EVar "EVar") (ELit (LString "__c")))))))
(DTypeSig false "deriveHashData" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Decl"))))
(DFunDef false "deriveHashData" ((PVar "name") (PVar "variants")) (EApp (EApp (EApp (EVar "derivedImpl") (ELit (LString "Hashable"))) (EVar "name")) (EListLit (EApp (EApp (EApp (EVar "ImplMethod") (ELit (LString "hash"))) (EListLit (EApp (EVar "PVar") (ELit (LString "__x"))))) (EApp (EApp (EVar "EMatch") (EApp (EVar "EVar") (ELit (LString "__x")))) (EApp (EApp (EMethodRef "map") (EVar "hashArm")) (EApp (EApp (EVar "indexFrom") (ELit (LInt 0))) (EVar "variants"))))))))
(DTypeSig false "hashArm" (TyFun (TyTuple (TyCon "Int") (TyCon "Variant")) (TyCon "Arm")))
(DFunDef false "hashArm" ((PTuple (PVar "i") (PVar "v"))) (EBlock (DoLet false false (PVar "vars") (EApp (EApp (EVar "genVars") (ELit (LString "__a"))) (EApp (EVar "conArity") (EVar "v")))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EApp (EApp (EVar "conBindPat") (EVar "v")) (EVar "vars"))) (EListLit)) (EApp (EApp (EVar "hashFold") (EApp (EVar "intLit") (EVar "i"))) (EVar "vars"))))))
(DTypeSig false "hashFold" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr"))))
(DFunDef false "hashFold" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "hashFold" ((PVar "acc") (PCons (PVar "v") (PVar "vs"))) (EApp (EApp (EVar "hashFold") (EApp (EApp (EApp (EVar "binOp") (ELit (LString "+"))) (EApp (EApp (EApp (EVar "binOp") (ELit (LString "*"))) (EVar "acc")) (EApp (EVar "intLit") (ELit (LInt 33))))) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "hash")))) (EApp (EVar "EVar") (EVar "v"))))) (EVar "vs")))
(DTypeSig false "deriveGenericData" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Decl"))))
(DFunDef false "deriveGenericData" ((PVar "name") (PVar "variants")) (EApp (EApp (EApp (EVar "derivedImpl") (ELit (LString "Generic"))) (EVar "name")) (EListLit (EApp (EApp (EApp (EVar "ImplMethod") (ELit (LString "to_rep"))) (EListLit (EApp (EVar "PVar") (ELit (LString "__x"))))) (EApp (EApp (EVar "EMatch") (EApp (EVar "EVar") (ELit (LString "__x")))) (EApp (EApp (EMethodRef "map") (EVar "genericArm")) (EVar "variants")))))))
(DTypeSig false "genericArm" (TyFun (TyCon "Variant") (TyCon "Arm")))
(DFunDef false "genericArm" ((PAs "v" (PCon "Variant" (PVar "cname") (PVar "payload")))) (EBlock (DoLet false false (PVar "vars") (EApp (EApp (EVar "genVars") (ELit (LString "__a"))) (EApp (EVar "conArity") (EVar "v")))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EApp (EApp (EVar "conBindPat") (EVar "v")) (EVar "vars"))) (EListLit)) (EApp (EApp (EApp (EVar "genericRep") (EVar "cname")) (EVar "payload")) (EVar "vars"))))))
(DTypeSig false "genericRep" (TyFun (TyCon "String") (TyFun (TyCon "ConPayload") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr")))))
(DFunDef false "genericRep" ((PVar "cname") (PCon "ConNamed" (PVar "fs") PWild) (PVar "vars")) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "RRecord"))) (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "cname")))) (EApp (EVar "EListLit") (EApp (EApp (EVar "genericRFields") (EVar "fs")) (EVar "vars")))))
(DFunDef false "genericRep" ((PVar "cname") PWild (PVar "vars")) (EApp (EApp (EApp (EVar "callBin") (ELit (LString "RCon"))) (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "cname")))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EVar "toRep")) (EVar "vars")))))
(DTypeSig false "genericRFields" (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "genericRFields" ((PList) PWild) (EListLit))
(DFunDef false "genericRFields" (PWild (PList)) (EListLit))
(DFunDef false "genericRFields" ((PCons (PCon "Field" (PVar "fn") PWild) (PVar "fs")) (PCons (PVar "v") (PVar "vs"))) (EBinOp "::" (EApp (EApp (EVar "ERecordCreate") (ELit (LString "RField"))) (EListLit (EApp (EApp (EVar "FieldAssign") (ELit (LString "fld_name"))) (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "fn")))) (EApp (EApp (EVar "FieldAssign") (ELit (LString "fld_rep"))) (EApp (EVar "toRep") (EVar "v"))))) (EApp (EApp (EVar "genericRFields") (EVar "fs")) (EVar "vs"))))
(DTypeSig false "toRep" (TyFun (TyCon "String") (TyCon "Expr")))
(DFunDef false "toRep" ((PVar "x")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "to_rep")))) (EApp (EVar "EVar") (EVar "x"))))
(DTypeSig false "mergeIfaceDefaults" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "mergeIfaceDefaults" ((PVar "prog")) (EApp (EApp (EMethodRef "map") (EVar "mergeIfaceDecl")) (EVar "prog")))
(DTypeSig false "mergeIfaceDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "mergeIfaceDecl" ((PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EVar "mergeIfaceMethods") (EVar "methods"))))))
(DFunDef false "mergeIfaceDecl" ((PVar "d")) (EVar "d"))
(DTypeSig false "mergeIfaceMethods" (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "mergeIfaceMethods" ((PVar "methods")) (EApp (EApp (EVar "foldlMethods") (EListLit)) (EVar "methods")))
(DTypeSig false "foldlMethods" (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "foldlMethods" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "foldlMethods" ((PVar "acc") (PCons (PVar "m") (PVar "rest"))) (EApp (EApp (EVar "foldlMethods") (EApp (EApp (EVar "insertMethod") (EVar "acc")) (EVar "m"))) (EVar "rest")))
(DTypeSig false "insertMethod" (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "insertMethod" ((PVar "acc") (PVar "m")) (EIf (EApp (EApp (EVar "containsMethod") (EApp (EVar "methodName") (EVar "m"))) (EVar "acc")) (EApp (EApp (EVar "mergeInto") (EVar "acc")) (EVar "m")) (EIf (EVar "otherwise") (EBinOp "++" (EVar "acc") (EListLit (EVar "m"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "mergeInto" (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "mergeInto" ((PList) (PVar "m")) (EListLit (EVar "m")))
(DFunDef false "mergeInto" ((PCons (PVar "x") (PVar "xs")) (PVar "m")) (EIf (EBinOp "==" (EApp (EVar "methodName") (EVar "x")) (EApp (EVar "methodName") (EVar "m"))) (EBinOp "::" (EApp (EApp (EVar "mergeTwo") (EVar "x")) (EVar "m")) (EVar "xs")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "mergeInto") (EVar "xs")) (EVar "m"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "mergeTwo" (TyFun (TyCon "IfaceMethod") (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))
(DFunDef false "mergeTwo" ((PCon "IfaceMethod" (PVar "n") (PVar "prevTy") (PVar "prevDef")) (PCon "IfaceMethod" PWild (PVar "mTy") (PVar "mDef"))) (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EApp (EApp (EVar "mergedType") (EVar "prevTy")) (EVar "mTy"))) (EApp (EApp (EVar "mergedDefault") (EVar "prevDef")) (EVar "mDef"))))
(DTypeSig false "mergedType" (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "mergedType" ((PCon "TyVar" (PLit (LString "_"))) (PVar "mTy")) (EVar "mTy"))
(DFunDef false "mergedType" ((PVar "prevTy") PWild) (EVar "prevTy"))
(DTypeSig false "mergedDefault" (TyFun (TyApp (TyCon "Option") (TyCon "MethodDefault")) (TyFun (TyApp (TyCon "Option") (TyCon "MethodDefault")) (TyApp (TyCon "Option") (TyCon "MethodDefault")))))
(DFunDef false "mergedDefault" ((PCon "Some" (PVar "d")) PWild) (EApp (EVar "Some") (EVar "d")))
(DFunDef false "mergedDefault" ((PCon "None") (PVar "mDef")) (EVar "mDef"))
(DTypeSig false "containsMethod" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Bool"))))
(DFunDef false "containsMethod" (PWild (PList)) (EVar "False"))
(DFunDef false "containsMethod" ((PVar "name") (PCons (PVar "x") (PVar "xs"))) (EBinOp "||" (EBinOp "==" (EApp (EVar "methodName") (EVar "x")) (EVar "name")) (EApp (EApp (EVar "containsMethod") (EVar "name")) (EVar "xs"))))
(DTypeSig false "methodName" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "methodName" ((PCon "IfaceMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "fillImplDefaults" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "fillImplDefaults" ((PVar "prog")) (EApp (EApp (EMethodRef "map") (EApp (EVar "fillImplDecl") (EVar "prog"))) (EVar "prog")))
(DTypeSig false "fillImplDecl" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "fillImplDecl" ((PVar "prog") (PAs "d" (PRec "DImpl" ((rf "iface" None) (rf "methods" None)) true))) (EIf (EVar "otherwise") (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EBinOp "++" (EVar "methods") (EApp (EApp (EVar "synthDefaultMethods") (EVar "methods")) (EApp (EApp (EVar "ifaceDefaults") (EVar "iface")) (EVar "prog"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "fillImplDecl" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "ifaceDefaults" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "ifaceDefaults" (PWild (PList)) (EListLit))
(DFunDef false "ifaceDefaults" ((PVar "target") (PCons (PVar "d") (PVar "rest"))) (EApp (EApp (EApp (EVar "ifaceDefaultsStep") (EVar "target")) (EVar "d")) (EVar "rest")))
(DTypeSig false "ifaceDefaultsStep" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "IfaceMethod"))))))
(DFunDef false "ifaceDefaultsStep" ((PVar "target") (PRec "DInterface" ((rf "name" None) (rf "methods" None)) true) (PVar "rest")) (EIf (EBinOp "==" (EVar "name") (EVar "target")) (EApp (EApp (EVar "filterList") (EVar "ifaceMethodHasDefault")) (EVar "methods")) (EIf (EVar "otherwise") (EApp (EApp (EVar "ifaceDefaults") (EVar "target")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "ifaceDefaultsStep" ((PVar "target") PWild (PVar "rest")) (EApp (EApp (EVar "ifaceDefaults") (EVar "target")) (EVar "rest")))
(DTypeSig false "ifaceMethodHasDefault" (TyFun (TyCon "IfaceMethod") (TyCon "Bool")))
(DFunDef false "ifaceMethodHasDefault" ((PCon "IfaceMethod" PWild PWild (PCon "Some" PWild))) (EVar "True"))
(DFunDef false "ifaceMethodHasDefault" ((PCon "IfaceMethod" PWild PWild (PCon "None"))) (EVar "False"))
(DTypeSig false "synthDefaultMethods" (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "ImplMethod")))))
(DFunDef false "synthDefaultMethods" (PWild (PList)) (EListLit))
(DFunDef false "synthDefaultMethods" ((PVar "explicit") (PCons (PVar "m") (PVar "rest"))) (EIf (EApp (EApp (EVar "implDefines") (EApp (EVar "methodName") (EVar "m"))) (EVar "explicit")) (EApp (EApp (EVar "synthDefaultMethods") (EVar "explicit")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "synthFromDefault") (EVar "m")) (EApp (EApp (EVar "synthDefaultMethods") (EVar "explicit")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implDefines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "Bool"))))
(DFunDef false "implDefines" ((PVar "name") (PVar "explicit")) (EApp (EApp (EVar "anyList") (EApp (EVar "implMethodNamed") (EVar "name"))) (EVar "explicit")))
(DTypeSig false "implMethodNamed" (TyFun (TyCon "String") (TyFun (TyCon "ImplMethod") (TyCon "Bool"))))
(DFunDef false "implMethodNamed" ((PVar "name") (PCon "ImplMethod" (PVar "n") PWild PWild)) (EBinOp "==" (EVar "n") (EVar "name")))
(DTypeSig false "synthFromDefault" (TyFun (TyCon "IfaceMethod") (TyCon "ImplMethod")))
(DFunDef false "synthFromDefault" ((PCon "IfaceMethod" (PVar "n") PWild (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "body"))))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EVar "body")))
(DFunDef false "synthFromDefault" ((PCon "IfaceMethod" (PVar "n") PWild (PCon "None"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EListLit)) (EApp (EVar "EVar") (EVar "n"))))
(DTypeSig false "concatMapDecl" (TyFun (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Decl"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "concatMapDecl" ((PVar "f") (PVar "prog")) (EApp (EVar "concatLists") (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "prog"))))
(DTypeSig false "concatLists" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "concatLists" ((PList)) (EListLit))
(DFunDef false "concatLists" ((PCons (PVar "xs") (PVar "rest"))) (EBinOp "++" (EVar "xs") (EApp (EVar "concatLists") (EVar "rest"))))
(DTypeSig false "desugarRecordPuns" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "desugarRecordPuns" ((PVar "prog")) (EApp (EApp (EVar "mapProg") (EApp (EVar "rewriteRecordPun") (EApp (EVar "collectRecordNames") (EVar "prog")))) (EVar "prog")))
(DTypeSig false "collectRecordNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectRecordNames" ((PList)) (EListLit))
(DFunDef false "collectRecordNames" ((PCons (PCon "DData" PWild PWild PWild (PVar "variants") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EVar "conNamedCtorNames") (EVar "variants")) (EApp (EVar "collectRecordNames") (EVar "rest"))))
(DFunDef false "collectRecordNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "collectRecordNames") (EVar "rest")))
(DTypeSig false "conNamedCtorNames" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "conNamedCtorNames" ((PList)) (EListLit))
(DFunDef false "conNamedCtorNames" ((PCons (PCon "Variant" (PVar "n") (PCon "ConNamed" PWild PWild)) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "conNamedCtorNames") (EVar "rest"))))
(DFunDef false "conNamedCtorNames" ((PCons (PCon "Variant" PWild (PCon "ConPos" PWild)) (PVar "rest"))) (EApp (EVar "conNamedCtorNames") (EVar "rest")))
(DTypeSig false "rewriteRecordPun" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteRecordPun" ((PVar "recordNames") (PCon "ESetLit" (PVar "name") (PVar "items"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "contains") (EVar "name")) (EVar "recordNames")) (EBinOp ">" (EApp (EVar "listLen") (EVar "items")) (ELit (LInt 0)))) (EApp (EApp (EVar "allList") (EVar "isVarExpr")) (EVar "items"))) (EApp (EApp (EVar "ERecordCreate") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "punField")) (EVar "items"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "rewriteRecordPun" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "isVarExpr" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isVarExpr" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isVarExpr") (EVar "e")))
(DFunDef false "isVarExpr" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "isVarExpr") (EVar "e")))
(DFunDef false "isVarExpr" ((PCon "EVar" PWild)) (EVar "True"))
(DFunDef false "isVarExpr" (PWild) (EVar "False"))
(DTypeSig false "punField" (TyFun (TyCon "Expr") (TyCon "FieldAssign")))
(DFunDef false "punField" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "punField") (EVar "e")))
(DFunDef false "punField" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "punField") (EVar "e")))
(DFunDef false "punField" ((PCon "EVar" (PVar "n"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "EVar") (EVar "n"))))
(DFunDef false "punField" (PWild) (EApp (EApp (EVar "FieldAssign") (ELit (LString ""))) (EApp (EVar "EVar") (ELit (LString "")))))
(DTypeSig false "lowerContainerLiterals" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "lowerContainerLiterals" ((PVar "prog")) (EApp (EApp (EVar "mapProg") (EVar "rewriteContainerLit")) (EVar "prog")))
(DTypeSig false "rewriteContainerLit" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteContainerLit" ((PCon "EMapLit" (PVar "name") (PVar "kvs"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "fromEntries")))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EVar "kvToTuple")) (EVar "kvs"))))) (EApp (EApp (EVar "pinType") (EVar "name")) (EListLit (EApp (EVar "TyVar") (ELit (LString "_k"))) (EApp (EVar "TyVar") (ELit (LString "_v")))))))
(DFunDef false "rewriteContainerLit" ((PCon "ESetLit" (PVar "name") (PVar "items"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "fromEntries")))) (EApp (EVar "EListLit") (EVar "items")))) (EApp (EApp (EVar "pinType") (EVar "name")) (EListLit (EApp (EVar "TyVar") (ELit (LString "_a")))))))
(DFunDef false "rewriteContainerLit" ((PVar "e")) (EVar "e"))
(DTypeSig false "kvToTuple" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyCon "Expr")))
(DFunDef false "kvToTuple" ((PTuple (PVar "k") (PVar "v"))) (EApp (EVar "ETuple") (EListLit (EVar "k") (EVar "v"))))
(DTypeSig false "pinType" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty"))))
(DFunDef false "pinType" ((PVar "name") (PVar "args")) (EApp (EApp (EVar "pinTypeGo") (EApp (EApp (EVar "TyCon") (EVar "name")) (EVar "None"))) (EVar "args")))
(DTypeSig false "pinTypeGo" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty"))))
(DFunDef false "pinTypeGo" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "pinTypeGo" ((PVar "acc") (PCons (PVar "t") (PVar "ts"))) (EApp (EApp (EVar "pinTypeGo") (EApp (EApp (EVar "TyApp") (EVar "acc")) (EVar "t"))) (EVar "ts")))
(DTypeSig false "moduleAliases" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleAliases" ((PList)) (EListLit))
(DFunDef false "moduleAliases" ((PCons (PCon "DUse" PWild (PCon "UseAlias" PWild (PVar "a")) PWild) (PVar "rest"))) (EBinOp "::" (EVar "a") (EApp (EVar "moduleAliases") (EVar "rest"))))
(DFunDef false "moduleAliases" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "moduleAliases") (EListLit (EVar "d"))) (EApp (EVar "moduleAliases") (EVar "rest"))))
(DFunDef false "moduleAliases" ((PCons PWild (PVar "rest"))) (EApp (EVar "moduleAliases") (EVar "rest")))
(DTypeSig false "qualifyAliasRefs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "qualifyAliasRefs" ((PVar "prog")) (EMatch (EApp (EVar "moduleAliases") (EVar "prog")) (arm (PList) () (EVar "prog")) (arm (PVar "aliases") () (EApp (EApp (EVar "mapProg") (EApp (EVar "rewriteAliasQual") (EVar "aliases"))) (EVar "prog")))))
(DTypeSig false "rewriteAliasQual" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteAliasQual" ((PVar "aliases") (PAs "e" (PCon "EFieldAccess" (PVar "head") (PVar "f") PWild))) (EMatch (EApp (EVar "stripLocE") (EVar "head")) (arm (PCon "EVar" (PVar "a")) () (EIf (EApp (EApp (EVar "contains") (EVar "a")) (EVar "aliases")) (EApp (EVar "EVar") (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "f"))) (EVar "e"))) (arm PWild () (EVar "e"))))
(DFunDef false "rewriteAliasQual" (PWild (PVar "e")) (EVar "e"))
(DTypeSig true "desugar" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "desugar" ((PVar "prog")) (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EApp (EVar "qualifyAliasRefs") (EVar "prog")) (EVar "mergeIfaceDefaults")) (EVar "fillImplDefaults")) (EApp (EVar "concatMapDecl") (EVar "expandDecl"))) (EVar "desugarRecordPuns")) (EVar "lowerContainerLiterals")) (EApp (EVar "mapProg") (EVar "rewriteDo"))) (EApp (EVar "mapProg") (EVar "rewriteAssignIndex"))) (EApp (EVar "mapProg") (EVar "rewriteSugar"))))
