# META
source_lines=1287
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/refindex.mdk — cross-file reference index (#254 Stage 0).
--
-- The LINEAR SUBSTRATE for `references` / `rename`: one whole-project walk that
-- turns the loader's dependency-ordered `(modId, path, decls)` list into two
-- binder-keyed hash maps —
--
--   defIndex : BinderKey -> (uri, defLoc)                    -- where it is defined
--   refIndex : BinderKey -> Ref (List (uri, useLoc))         -- everywhere it is used
--
-- plus an `occIndex : uri -> Ref (List (useLoc, BinderKey))` so a click at a
-- (uri, line, col) resolves to a `BinderKey` by scanning ONLY the clicked file.
--
-- This module ships NO tool wiring (that is Stage 1 — mcp/lsp).  It only builds
-- the index and exposes the query API the Stage-1 tools will call.
--
-- ── the whole correctness idea: MATCH BINDERS, NOT STRINGS ───────────────────
-- A `BinderKey` is derived from RESOLUTION, never from spelling.  It is a String
-- `"<definingModuleId>\t<namespace>\t<name>"` for a top-level / exported binder,
-- and `"<moduleId>\tlocal\t<name>\t<freshId>"` for a local (let / lambda param /
-- match-pattern binder).  Because the key carries the DEFINING module and a
-- per-binder fresh id, it is correct under:
--   * shadowing            — an inner `g` gets a distinct `local` key, so a use
--                            of the inner `g` never returns the top-level `g`;
--   * `import m as A`; A.f  — resolves through the alias to m's origin key;
--   * `import m.{f as g}`   — local `g` maps to m's origin key for `f`;
--   * re-export chains      — `pub import` threads the true origin key forward;
--   * same name, two modules— the module id prefix keeps them distinct;
--   * val/ty/ctor clash     — the namespace field separates them.
--
-- ── linearity (the HARD requirement) ────────────────────────────────────────
-- Build is O(N tokens × D), where D = the MAX LEXICAL NESTING DEPTH — i.e. linear
-- in project size under bounded nesting.  Every hash membership/lookup/insert is
-- O(1) amortized (NEVER a `List` used as a set/map) and every append is an O(1)
-- `Ref`-list push (NEVER `xs ++ [x]`).  The one NON-hash step is the innermost-
-- first scope-frame walk (`lookupScope`/`assocFind`): resolving a local occurrence
-- costs O(D), the lexical nesting depth of its site — bounded by nesting, NOT by
-- project size, exactly the bound `resolve.mdk`'s own `lookupBindId` lives with.
-- That walk IS `bump`-counted, so a regression that let a frame grow to O(project)
-- (e.g. one flat frame accumulating every binder) shows up in the ratio.  A
-- `defOf`/`usesOf` query is O(1)+O(#uses); `binderAt` is O(size of the clicked
-- file), never O(project).  `riOps` is graded N-vs-2N by
-- test/diff_compiler_references_scaling.sh (the alloc gate is BLIND to a
-- non-allocating scan-quadratic, so op-count is the discriminator).

import frontend.ast.{
  Loc(..),
  Ty(..),
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
  useMemberOrigin,
  useMemberLocal,
  PropParam(..),
  MethodDefault(..),
  IfaceMethod(..),
  ImplMethod(..),
  DataVis(..),
  Field(..),
  ConPayload(..),
  Variant(..),
  Decl(..),
}
import frontend.parser.{
  parseWithPositionsOpt,
  positionsDecls,
  DeclPos,
  declPosNameLoc,
}
import driver.loader.{
  loadProgramFilesLocatedCached,
  moduleIdOfPath,
  importModId,
}
import support.util.{zipL, startsWith, endsWith}
import support.path.{joinPath}
import support.char.{isUpper}
import array.{get as arrayGet}
import hash_map.{
  HashMap,
  new as hmNew,
  get as hmGet,
  set as hmSet,
  keys as hmKeys,
}

-- ── namespaces + key formation ───────────────────────────────────────────────
-- separator: a TAB can appear in neither an identifier, a module id (dotted /
-- slashed path), nor a namespace tag, so `mkKey` is injective.
sep : String
sep = "\t"

nsVal : String
nsVal = "val"

nsTy : String
nsTy = "ty"

nsCtor : String
nsCtor = "ctor"

nsField : String
nsField = "field"

nsMethod : String
nsMethod = "method"

-- a top-level / exported binder key.
mkKey : String -> String -> String -> String
mkKey modId ns name = modId ++ sep ++ ns ++ sep ++ name

-- an EXTERNAL (prelude / out-of-project / unresolved) fallback key.  Still keyed
-- by (ns, name) so uses of the SAME external name group under one key; carries no
-- def site (defOf returns None), which is exactly right for F1 intra-project scope.
extKey : String -> String -> String
extKey ns name = "?ext\{sep}\{ns}\{sep}\{name}"

-- ── the index + the build context ───────────────────────────────────────────
export data RefIndex =
  | RefIndex {
      defs : HashMap String (String, Loc),
      refs : HashMap String (Ref (List (String, Loc))),
      occ : HashMap String (Ref (List (Loc, String))),
      ops : Int,
    }

-- Mutable build state threaded through the whole walk.
--   originOf : "<mid>\t<ns>\t<name>" -> originKey   (EXPORTED names, for imports)
--   modExp   : mid -> List (ns, localName, originKey)  (for wildcard enumeration)
--   opCnt    : total hash/push op count (the perf-gate signal)
--   fresh    : monotonic local-binder id source
data Ctx =
  | Ctx {
      defs : HashMap String (String, Loc),
      refs : HashMap String (Ref (List (String, Loc))),
      occ : HashMap String (Ref (List (Loc, String))),
      originOf : HashMap String String,
      modExp : HashMap String (List (String, String, String)),
      opCnt : Ref Int,
      fresh : Ref Int,
    }

-- Per-module walk bundle: the shared Ctx plus this module's identity and env.
--   useEnv : "<ns>\t<localName>" -> BinderKey  (names in scope: own + imports + prelude)
--   aliasM : aliasLocal -> sourceModuleId        (from `import S as A`)
data W = W Ctx String String (HashMap String String) (HashMap String String)

-- ── op-counting hash/ref primitives (NEVER a List-as-map; every op is O(1)) ──
bump : Ctx -> Unit
bump ctx = ctx.opCnt := ctx.opCnt.value + 1

hmGetC : Ctx -> HashMap String v -> String -> Option v
hmGetC ctx m k =
  let _ = bump ctx
  hmGet k m

hmSetC : Ctx -> HashMap String v -> String -> v -> Unit
hmSetC ctx m k v =
  let _ = bump ctx
  hmSet k v m

nextFresh : Ctx -> Int
nextFresh ctx =
  let _ = ctx.fresh := ctx.fresh.value + 1
  ctx.fresh.value

-- ── small helpers ────────────────────────────────────────────────────────────
withUri : String -> Loc -> Loc
withUri uri (Loc _ a b c d) = Loc uri a b c d

dummyLoc : String -> Loc
dummyLoc uri = Loc uri 0 0 0 0

-- first char uppercase ⇒ a constructor / type name (Medaka lexical convention).
headIsUpper : String -> Bool
headIsUpper s = match arrayGet 0 (stringToChars s)
  Some c => isUpper c
  None => False

-- names bound by a pattern (each becomes a DISTINCT local binder / key).
patBinderNames : Pat -> List String
patBinderNames (PVar x) = [x]
patBinderNames PWild = []
patBinderNames (PLit _) = []
patBinderNames (PCon _ ps) = flatMap patBinderNames ps
patBinderNames (PCons a b) = patBinderNames a ++ patBinderNames b
patBinderNames (PTuple ps) = flatMap patBinderNames ps
patBinderNames (PList ps) = flatMap patBinderNames ps
patBinderNames (PAs x p) = x :: patBinderNames p
patBinderNames (PRng _ _ _) = []
patBinderNames (PRec _ fields _) = flatMap recFieldBinderNames fields

recFieldBinderNames : RecPatField -> List String
recFieldBinderNames (RecPatField name None) = [name]
recFieldBinderNames (RecPatField _ (Some p)) = patBinderNames p

-- innermost-first scope lookup (shadowing: first frame wins).  Every frame hop
-- and every element comparison is `bump`ed, so the frame-stack walk (an O(nesting
-- depth) cost, NOT O(project)) IS counted in `riOps` — a deep sequential-`let`
-- chain that pushed one frame per binder shows up in the scaling ratio.
lookupScope : Ctx -> String -> List (List (String, String)) -> Option String
lookupScope _ _ [] = None
lookupScope ctx n (frame::rest) =
  let _ = bump ctx
  match assocFind ctx n frame
    Some k => Some k
    None => lookupScope ctx n rest

assocFind : Ctx -> String -> List (String, String) -> Option String
assocFind _ _ [] = None
assocFind ctx n ((k, v)::rest) =
  let _ = bump ctx
  if k == n then Some v else assocFind ctx n rest

-- ── record: def site, use site, occurrence ──────────────────────────────────
recordDef : Ctx -> String -> String -> Loc -> Unit
recordDef ctx key uri loc =
  let _ = hmSetC ctx ctx.defs key (uri, loc)
  pushOcc ctx uri loc key

recordRef : Ctx -> String -> String -> Loc -> Unit
recordRef ctx key uri loc =
  let _ = pushRef ctx key uri loc
  pushOcc ctx uri loc key

pushRef : Ctx -> String -> String -> Loc -> Unit
pushRef ctx key uri loc = match hmGetC ctx ctx.refs key
  Some r =>
    let _ = bump ctx
    r := (uri, loc)::r.value
  None => hmSetC ctx ctx.refs key (Ref [(uri, loc)])

pushOcc : Ctx -> String -> Loc -> String -> Unit
pushOcc ctx uri loc key = match hmGetC ctx ctx.occ uri
  Some r =>
    let _ = bump ctx
    r := (loc, key)::r.value
  None => hmSetC ctx ctx.occ uri (Ref [(loc, key)])

-- ── occurrence resolution (the shadow-correct core) ──────────────────────────
-- A lower-case occurrence is a local, a plain value, OR an interface-METHOD call
-- (pre-marker, `map`/`==`/`compare`/a user `interface` method are all plain
-- `EVar`s).  Method DEFS are keyed under `nsMethod` and threaded through
-- imports/re-exports under `nsMethod`, so a method call MUST consult `nsMethod`
-- or its use-key never matches its def-key (Finding 1).  Order — local, then own/
-- imported value, then method — mirrors resolve.mdk's "a standalone shadows the
-- method" (definer-shadow) rule, and keeps the separate `nsMethod` key so F4
-- (group-a-method's-impls) stays expressible.
resolveVal : W -> List (List (String, String)) -> String -> String
resolveVal (W ctx _ _ useEnv _) scope name = match lookupScope ctx name scope
  Some k => k
  None => match hmGetC ctx useEnv (nsVal ++ sep ++ name)
    Some k => k
    None => match hmGetC ctx useEnv (nsMethod ++ sep ++ name)
      Some k => k
      None => extKey nsVal name

resolveCtor : W -> String -> String
resolveCtor (W ctx _ _ useEnv _) name = match hmGetC ctx useEnv (nsCtor ++ sep ++ name)
  Some k => k
  None => extKey nsCtor name

resolveTy : W -> String -> String
resolveTy (W ctx _ _ useEnv _) name = match hmGetC ctx useEnv (nsTy ++ sep ++ name)
  Some k => k
  None => extKey nsTy name

resolveField : W -> String -> String
resolveField (W ctx _ _ useEnv _) name = match hmGetC ctx useEnv (nsField ++ sep ++ name)
  Some k => k
  None => extKey nsField name

-- ── the expression walk (mirrors resolve.mdk stampExpr's frame-stack shape) ──
-- `curLoc` is the location of the nearest enclosing `ELoc` wrapper — the parser
-- wraps every atom (incl. every `EVar`) in one, so a leaf `EVar`/`ECon` sees its
-- own precise span here.
walkExpr : W -> List (List (String, String)) -> Loc -> Expr -> Unit
walkExpr w scope _ (ELoc l e) = walkExpr w scope (locWithUriOf w l) e
walkExpr w scope _ (EDoOrigin l e) = walkExpr w scope (locWithUriOf w l) e
walkExpr w scope curLoc (EVar n)
  | headIsUpper n = recordRef (ctxOf w) (resolveCtor w n) (uriOf w) curLoc
  | otherwise = recordRef (ctxOf w) (resolveVal w scope n) (uriOf w) curLoc
walkExpr w scope curLoc (EApp f x) =
  let _ = walkExpr w scope curLoc f
  walkExpr w scope curLoc x
walkExpr w scope curLoc (ELam pats body) =
  let frame = mkNamedFrame w curLoc (flatMap patBinderNames pats)
  walkExpr w (frame::scope) curLoc body
walkExpr w scope curLoc (ELet _ isRec pat e1 e2) =
  let frame = mkNamedFrame w curLoc (patBinderNames pat)
  let scope1 = if isRec then frame::scope else scope
  let _ = walkExpr w scope1 curLoc e1
  walkExpr w (frame::scope) curLoc e2
walkExpr w scope curLoc (ELetGroup binds body) =
  let frame = mkNamedFrame w curLoc (map letBindName binds)
  let scope1 = frame::scope
  let _ = walkBinds w scope1 curLoc binds
  walkExpr w scope1 curLoc body
walkExpr w scope curLoc (EMatch e0 arms) =
  let _ = walkExpr w scope curLoc e0
  walkArms w scope curLoc arms
walkExpr w scope curLoc (EIf c t el) =
  let _ = walkExpr w scope curLoc c
  let _ = walkExpr w scope curLoc t
  walkExpr w scope curLoc el
walkExpr w scope curLoc (EBinOp _ a b _) =
  let _ = walkExpr w scope curLoc a
  walkExpr w scope curLoc b
walkExpr w scope curLoc (EUnOp _ a _) = walkExpr w scope curLoc a
walkExpr w scope curLoc (EInfix _ a b) =
  let _ = walkExpr w scope curLoc a
  walkExpr w scope curLoc b
walkExpr w scope curLoc (EFieldAccess e0 f _) =
  walkFieldAccess w scope curLoc e0 f
walkExpr w scope curLoc (ETuple es) = walkEach w scope curLoc es
walkExpr w scope curLoc (EListLit es) = walkEach w scope curLoc es
walkExpr w scope curLoc (EArrayLit es) = walkEach w scope curLoc es
walkExpr w scope curLoc (ERangeList lo hi _) =
  let _ = walkExpr w scope curLoc lo
  walkExpr w scope curLoc hi
walkExpr w scope curLoc (ERangeArray lo hi _) =
  let _ = walkExpr w scope curLoc lo
  walkExpr w scope curLoc hi
walkExpr w scope curLoc (ESlice e0 lo hi _ _) =
  let _ = walkExpr w scope curLoc e0
  let _ = walkExpr w scope curLoc lo
  walkExpr w scope curLoc hi
walkExpr w scope curLoc (EIndex e0 i _) =
  let _ = walkExpr w scope curLoc e0
  walkExpr w scope curLoc i
walkExpr w scope curLoc (EAnnot e0 t) =
  let _ = walkTy w curLoc t
  walkExpr w scope curLoc e0
walkExpr w scope curLoc (EHeadAnnot e0 t) =
  let _ = walkTy w curLoc t
  walkExpr w scope curLoc e0
walkExpr w scope curLoc (EBlock stmts) = walkStmts w scope curLoc stmts
walkExpr w scope curLoc (EDo stmts) = walkStmts w scope curLoc stmts
walkExpr w scope curLoc (EStringInterp parts) = walkInterp w scope curLoc parts
walkExpr w scope curLoc (EGuards arms) = walkGuardArms w scope curLoc arms
walkExpr w scope curLoc (ERecordCreate name fs) =
  let _ = recordRef (ctxOf w) (resolveCtor w name) (uriOf w) curLoc
  walkFields w scope curLoc fs
walkExpr w scope curLoc (ERecordUpdate e0 fs _) =
  let _ = walkExpr w scope curLoc e0
  walkFields w scope curLoc fs
walkExpr w scope curLoc (EVariantUpdate con e0 fs) =
  let _ = recordRef (ctxOf w) (resolveCtor w con) (uriOf w) curLoc
  let _ = walkExpr w scope curLoc e0
  walkFields w scope curLoc fs
walkExpr w scope curLoc (EMapLit _ kvs) = walkKvs w scope curLoc kvs
walkExpr w scope curLoc (ESetLit _ es) = walkEach w scope curLoc es
walkExpr w scope curLoc (EAsPat _ e0) = walkExpr w scope curLoc e0
walkExpr w scope curLoc (ESection s) = walkSection w scope curLoc s
walkExpr _ _ _ _ = ()

-- alias-qualified `A.f` vs a genuine record field access `record.field`.
walkFieldAccess : W -> List (List (String, String)) -> Loc -> Expr -> String -> Unit
walkFieldAccess w scope curLoc e0 f = match aliasHeadOf w (peelLoc e0)
  Some srcMod =>
    -- `A.f` where `A` is an import alias for module `srcMod`: resolve to the
    -- origin key of `f` in `srcMod` (values only — a qualified name is lowercase).
    recordRef (ctxOf w) (aliasOriginKey w srcMod f) (uriOf w) curLoc
  None =>
    let _ = recordRef (ctxOf w) (resolveField w f) (uriOf w) curLoc
    walkExpr w scope curLoc e0

aliasHeadOf : W -> Expr -> Option String
aliasHeadOf (W ctx _ _ _ aliasM) (EVar a) = hmGetC ctx aliasM a
aliasHeadOf _ _ = None

aliasOriginKey : W -> String -> String -> String
aliasOriginKey (W ctx _ _ _ _) srcMod f = match hmGetC ctx ctx.originOf (mkKey srcMod nsVal f)
  Some k => k
  None => extKey nsVal f

peelLoc : Expr -> Expr
peelLoc (ELoc _ e) = peelLoc e
peelLoc (EDoOrigin _ e) = peelLoc e
peelLoc e = e

walkEach : W -> List (List (String, String)) -> Loc -> List Expr -> Unit
walkEach _ _ _ [] = ()
walkEach w scope curLoc (e::rest) =
  let _ = walkExpr w scope curLoc e
  walkEach w scope curLoc rest

walkKvs : W -> List (List (String, String)) -> Loc -> List (Expr, Expr) -> Unit
walkKvs _ _ _ [] = ()
walkKvs w scope curLoc ((k, v)::rest) =
  let _ = walkExpr w scope curLoc k
  let _ = walkExpr w scope curLoc v
  walkKvs w scope curLoc rest

walkFields : W -> List (List (String, String)) -> Loc -> List FieldAssign -> Unit
walkFields _ _ _ [] = ()
walkFields w scope curLoc ((FieldAssign _ e)::rest) =
  let _ = walkExpr w scope curLoc e
  walkFields w scope curLoc rest

walkSection : W -> List (List (String, String)) -> Loc -> Section -> Unit
walkSection _ _ _ (SecBare _) = ()
walkSection w scope curLoc (SecRight _ e) = walkExpr w scope curLoc e
walkSection w scope curLoc (SecLeft e _) = walkExpr w scope curLoc e

walkInterp : W -> List (List (String, String)) -> Loc -> List InterpPart -> Unit
walkInterp _ _ _ [] = ()
walkInterp w scope curLoc ((InterpStr _)::rest) = walkInterp w scope curLoc rest
walkInterp w scope curLoc ((InterpExpr e)::rest) =
  let _ = walkExpr w scope curLoc e
  walkInterp w scope curLoc rest

walkStmts : W -> List (List (String, String)) -> Loc -> List DoStmt -> Unit
walkStmts _ _ _ [] = ()
walkStmts w scope curLoc ((DoExpr e)::rest) =
  let _ = walkExpr w scope curLoc e
  walkStmts w scope curLoc rest
walkStmts w scope curLoc ((DoBind p e)::rest) =
  let _ = walkExpr w scope curLoc e
  let frame = mkNamedFrame w curLoc (patBinderNames p)
  walkStmts w (frame::scope) curLoc rest
walkStmts w scope curLoc ((DoLet _ _ p e)::rest) =
  let _ = walkExpr w scope curLoc e
  let frame = mkNamedFrame w curLoc (patBinderNames p)
  walkStmts w (frame::scope) curLoc rest
walkStmts w scope curLoc ((DoAssign _ e)::rest) =
  let _ = walkExpr w scope curLoc e
  walkStmts w scope curLoc rest
walkStmts w scope curLoc ((DoFieldAssign _ _ e)::rest) =
  let _ = walkExpr w scope curLoc e
  walkStmts w scope curLoc rest

walkArms : W -> List (List (String, String)) -> Loc -> List Arm -> Unit
walkArms _ _ _ [] = ()
walkArms w scope curLoc ((Arm pat gs body)::rest) =
  let frame = mkNamedFrame w curLoc (patBinderNames pat)
  let scope1 = frame::scope
  let scope2 = walkGuards w scope1 curLoc gs
  let _ = walkExpr w scope2 curLoc body
  walkArms w scope curLoc rest

walkGuardArms : W -> List (List (String, String)) -> Loc -> List GuardArm -> Unit
walkGuardArms _ _ _ [] = ()
walkGuardArms w scope curLoc ((GuardArm gs body)::rest) =
  let scope2 = walkGuards w scope curLoc gs
  let _ = walkExpr w scope2 curLoc body
  walkGuardArms w scope curLoc rest

-- a guard list threads scope (a `Pat <- e` bind adds binders for later guards).
walkGuards : W -> List (List (String, String)) -> Loc -> List Guard -> List (List (String, String))
walkGuards _ scope _ [] = scope
walkGuards w scope curLoc ((GBool e)::rest) =
  let _ = walkExpr w scope curLoc e
  walkGuards w scope curLoc rest
walkGuards w scope curLoc ((GBind p e)::rest) =
  let _ = walkExpr w scope curLoc e
  let frame = mkNamedFrame w curLoc (patBinderNames p)
  walkGuards w (frame::scope) curLoc rest

walkBinds : W -> List (List (String, String)) -> Loc -> List LetBind -> Unit
walkBinds _ _ _ [] = ()
walkBinds w scope curLoc ((LetBind _ clauses)::rest) =
  let _ = walkClauses w scope curLoc clauses
  walkBinds w scope curLoc rest

walkClauses : W -> List (List (String, String)) -> Loc -> List FunClause -> Unit
walkClauses _ _ _ [] = ()
walkClauses w scope curLoc ((FunClause pats body)::rest) =
  let frame = mkNamedFrame w curLoc (flatMap patBinderNames pats)
  let _ = walkExpr w (frame::scope) curLoc body
  walkClauses w scope curLoc rest

-- ── type walk (TyCon carries its OWN Option Loc — no curLoc threading needed) ─
walkTy : W -> Loc -> Ty -> Unit
walkTy w _ (TyCon name mloc) = match mloc
  Some l => recordRef (ctxOf w) (resolveTy w name) (uriOf w) (locWithUriOf w l)
  None => ()
walkTy _ _ (TyVar _) = ()
walkTy w curLoc (TyApp a b) =
  let _ = walkTy w curLoc a
  walkTy w curLoc b
walkTy w curLoc (TyFun a b) =
  let _ = walkTy w curLoc a
  walkTy w curLoc b
walkTy w curLoc (TyTuple ts) = walkTys w curLoc ts
walkTy w curLoc (TyEffect _ _ t) = walkTy w curLoc t
walkTy w curLoc (TyConstrained _ t) = walkTy w curLoc t

walkTys : W -> Loc -> List Ty -> Unit
walkTys _ _ [] = ()
walkTys w curLoc (t::rest) =
  let _ = walkTy w curLoc t
  walkTys w curLoc rest

-- ── local binder frames (each name → a fresh, shadow-distinct key) ───────────
mkNamedFrame : W -> Loc -> List String -> List (String, String)
mkNamedFrame _ _ [] = []
mkNamedFrame w atLoc (n::rest) =
  mkOneLocal w atLoc n :: mkNamedFrame w atLoc rest

mkOneLocal : W -> Loc -> String -> (String, String)
mkOneLocal (W ctx mid uri _ _) atLoc name =
  let fid = nextFresh ctx
  let key = "\{mid}\{sep}local\{sep}\{name}\{sep}\{intToString fid}"
  let _ = recordDef ctx key uri (withUri uri atLoc)
  (name, key)

-- ── accessors ────────────────────────────────────────────────────────────────
ctxOf : W -> Ctx
ctxOf (W ctx _ _ _ _) = ctx

uriOf : W -> String
uriOf (W _ _ uri _ _) = uri

locWithUriOf : W -> Loc -> Loc
locWithUriOf w l = withUri (uriOf w) l

letBindName : LetBind -> String
letBindName (LetBind n _) = n

ppName : PropParam -> String
ppName (PropParam n _) = n

ifName : IfaceMethod -> String
ifName (IfaceMethod n _ _) = n

-- ── def collection (top-level binders, with real #331 name Locs) ─────────────
-- a def entry: (namespace, name, key, defLoc, isPub).
data DefEntry = DefEntry String String String Loc Bool

collectDefs : Ctx -> HashMap String Unit -> String -> String -> List (Decl, DeclPos) -> List DefEntry
collectDefs _ _ _ _ [] = []
collectDefs ctx expSet mid uri ((d, p)::rest) = defsOfDecl ctx expSet mid uri d (nameLocOf uri p)
  ++ collectDefs ctx expSet mid uri rest

-- A VALUE's export flag lives on its `export foo : T` SIGNATURE, not on the bare
-- `foo = …` definition (idiomatic Medaka), so a def's pub is `declPub OR the name
-- is in the module's sig/def/extern export set` — mirrors resolve's
-- `expValuesDirect` (which lists both `DTypeSig True` and `DFunDef True`).
valuePub : Ctx -> HashMap String Unit -> Bool -> String -> Bool
valuePub _ _ True _ = True
valuePub ctx expSet False n = match hmGetC ctx expSet n
  Some _ => True
  None => False

-- names this module exports as VALUES (via sig, def, extern, or let-group).
collectExportedValues : Ctx -> List Decl -> HashMap String Unit
collectExportedValues ctx decls =
  let s = hmNew ()
  let _ = collectExpValGo ctx s decls
  s

collectExpValGo : Ctx -> HashMap String Unit -> List Decl -> Unit
collectExpValGo _ _ [] = ()
collectExpValGo ctx s ((DTypeSig True n _)::rest) =
  let _ = hmSetC ctx s n ()
  collectExpValGo ctx s rest
collectExpValGo ctx s ((DFunDef True n _ _)::rest) =
  let _ = hmSetC ctx s n ()
  collectExpValGo ctx s rest
collectExpValGo ctx s ((DExtern True n _)::rest) =
  let _ = hmSetC ctx s n ()
  collectExpValGo ctx s rest
collectExpValGo ctx s ((DLetGroup True binds)::rest) =
  let _ = collectLetNames ctx s binds
  collectExpValGo ctx s rest
collectExpValGo ctx s ((DAttrib _ inner)::rest) =
  collectExpValGo ctx s (inner::rest)
collectExpValGo ctx s (_::rest) = collectExpValGo ctx s rest

collectLetNames : Ctx -> HashMap String Unit -> List LetBind -> Unit
collectLetNames _ _ [] = ()
collectLetNames ctx s ((LetBind n _)::rest) =
  let _ = hmSetC ctx s n ()
  collectLetNames ctx s rest

nameLocOf : String -> DeclPos -> Loc
nameLocOf uri p = match declPosNameLoc p
  Some l => withUri uri l
  None => dummyLoc uri

-- Record every def entry for one decl into `defs`/`occ` and return them (for the
-- module's own env + export tables).  Constructor / field / method secondary
-- names use the decl's own name Loc as an approximate def site (Stage 0: the KEY
-- identity is load-bearing; per-child Locs are a documented residual).
defsOfDecl : Ctx -> HashMap String Unit -> String -> String -> Decl -> Loc -> List DefEntry
defsOfDecl ctx expSet mid uri (DFunDef pub n _ _) loc = [
  emitDef ctx uri (DefEntry nsVal n (mkKey mid nsVal n) loc (valuePub ctx expSet pub n))
]
defsOfDecl ctx expSet mid uri (DExtern pub n _) loc = [
  emitDef ctx uri (DefEntry nsVal n (mkKey mid nsVal n) loc (valuePub ctx expSet pub n))
]
defsOfDecl _ _ _ _ (DTypeSig _ _ _) _ = []
defsOfDecl ctx expSet mid uri (DLetGroup pub binds) loc =
  map (letGroupDef ctx expSet mid uri loc pub) binds
defsOfDecl ctx _ mid uri (DData vis n _ variants _) loc =
  let tyDef = emitDef ctx uri (DefEntry nsTy n (mkKey mid nsTy n) loc (dataIsPub vis))
  tyDef :: flatMap (variantDefs ctx mid uri loc (ctorsPub vis)) variants
defsOfDecl ctx _ mid uri (DNewtype pub n _ con _ _) loc =
  let tyDef = emitDef ctx uri (DefEntry nsTy n (mkKey mid nsTy n) loc pub)
  let conDef = emitDef ctx uri (DefEntry nsCtor con (mkKey mid nsCtor con) loc pub)
  [tyDef, conDef]
defsOfDecl ctx _ mid uri (DTypeAlias pub n _ _) loc =
  [emitDef ctx uri (DefEntry nsTy n (mkKey mid nsTy n) loc pub)]
defsOfDecl ctx _ mid uri (DInterface { pub, name, methods, ... }) loc =
  let ifaceDef = emitDef ctx uri (DefEntry nsTy name (mkKey mid nsTy name) loc pub)
  ifaceDef :: map (methodDef ctx mid uri loc pub) methods
defsOfDecl _ _ _ _ (DImpl { ... }) _ = []
defsOfDecl ctx expSet mid uri (DAttrib _ inner) loc =
  defsOfDecl ctx expSet mid uri inner loc
defsOfDecl _ _ _ _ _ _ = []

letGroupDef : Ctx -> HashMap String Unit -> String -> String -> Loc -> Bool -> LetBind -> DefEntry
letGroupDef ctx expSet mid uri loc pub (LetBind n _) =
  emitDef
    ctx
    uri
    (DefEntry nsVal n (mkKey mid nsVal n) loc (valuePub ctx expSet pub n))

variantDefs : Ctx -> String -> String -> Loc -> Bool -> Variant -> List DefEntry
variantDefs ctx mid uri loc pub (Variant cn payload) =
  emitDef ctx uri (DefEntry nsCtor cn (mkKey mid nsCtor cn) loc pub) ::
    fieldDefs ctx mid uri loc pub payload

fieldDefs : Ctx -> String -> String -> Loc -> Bool -> ConPayload -> List DefEntry
fieldDefs _ _ _ _ _ (ConPos _) = []
fieldDefs ctx mid uri loc pub (ConNamed fields _) =
  map (fieldDef ctx mid uri loc pub) fields

fieldDef : Ctx -> String -> String -> Loc -> Bool -> Field -> DefEntry
fieldDef ctx mid uri loc pub (Field fn _) =
  emitDef ctx uri (DefEntry nsField fn (mkKey mid nsField fn) loc pub)

methodDef : Ctx -> String -> String -> Loc -> Bool -> IfaceMethod -> DefEntry
methodDef ctx mid uri loc pub m =
  let n = ifName m
  emitDef ctx uri (DefEntry nsMethod n (mkKey mid nsMethod n) loc pub)

emitDef : Ctx -> String -> DefEntry -> DefEntry
emitDef ctx uri (d@(DefEntry _ _ key loc _)) =
  let _ = recordDef ctx key uri loc
  d

dataIsPub : DataVis -> Bool
dataIsPub VisPrivate = False
dataIsPub _ = True

ctorsPub : DataVis -> Bool
ctorsPub VisPublic = True
ctorsPub _ = False

-- ── body walk over decls (uses the assembled useEnv) ─────────────────────────
walkDecls : W -> List (Decl, DeclPos) -> Unit
walkDecls _ [] = ()
walkDecls w ((d, p)::rest) =
  let _ = walkDeclBody w d (nameLocOf (uriOf w) p)
  walkDecls w rest

walkDeclBody : W -> Decl -> Loc -> Unit
walkDeclBody w (DFunDef _ _ pats body) loc =
  let frame = mkNamedFrame w loc (flatMap patBinderNames pats)
  walkExpr w [frame] loc body
walkDeclBody w (DTypeSig _ _ ty) loc = walkTy w loc ty
walkDeclBody w (DExtern _ _ ty) loc = walkTy w loc ty
walkDeclBody w (DData _ _ _ variants _) loc = walkVariants w loc variants
walkDeclBody w (DNewtype _ _ _ _ fieldTy _) loc = walkTy w loc fieldTy
walkDeclBody w (DTypeAlias _ _ _ rhs) loc = walkTy w loc rhs
walkDeclBody w (DInterface { methods, ... }) loc =
  walkIfaceMethods w loc methods
walkDeclBody w (DImpl { tys, methods, ... }) loc =
  let _ = walkTys w loc tys
  walkImplMethods w loc methods
walkDeclBody w (DProp _ _ params body) loc =
  let frame = mkNamedFrame w loc (map ppName params)
  walkExpr w [frame] loc body
walkDeclBody w (DTest _ _ body) loc = walkExpr w [] loc body
walkDeclBody w (DBench _ _ body) loc = walkExpr w [] loc body
walkDeclBody w (DLetGroup _ binds) loc =
  let frame = mkNamedFrame w loc (map letBindName binds)
  walkBinds w [frame] loc binds
walkDeclBody w (DAttrib _ inner) loc = walkDeclBody w inner loc
walkDeclBody _ _ _ = ()

walkVariants : W -> Loc -> List Variant -> Unit
walkVariants _ _ [] = ()
walkVariants w loc ((Variant _ payload)::rest) =
  let _ = walkPayload w loc payload
  walkVariants w loc rest

walkPayload : W -> Loc -> ConPayload -> Unit
walkPayload w loc (ConPos tys) = walkTys w loc tys
walkPayload w loc (ConNamed fields _) = walkFieldTys w loc fields

walkFieldTys : W -> Loc -> List Field -> Unit
walkFieldTys _ _ [] = ()
walkFieldTys w loc ((Field _ ty)::rest) =
  let _ = walkTy w loc ty
  walkFieldTys w loc rest

walkIfaceMethods : W -> Loc -> List IfaceMethod -> Unit
walkIfaceMethods _ _ [] = ()
walkIfaceMethods w loc ((IfaceMethod _ ty mdef)::rest) =
  let _ = walkTy w loc ty
  let _ = walkMethodDefault w loc mdef
  walkIfaceMethods w loc rest

walkMethodDefault : W -> Loc -> Option MethodDefault -> Unit
walkMethodDefault _ _ None = ()
walkMethodDefault w loc (Some (MethodDefault pats body)) =
  let frame = mkNamedFrame w loc (flatMap patBinderNames pats)
  walkExpr w [frame] loc body

walkImplMethods : W -> Loc -> List ImplMethod -> Unit
walkImplMethods _ _ [] = ()
walkImplMethods w loc ((ImplMethod _ pats body)::rest) =
  let frame = mkNamedFrame w loc (flatMap patBinderNames pats)
  let _ = walkExpr w [frame] loc body
  walkImplMethods w loc rest

-- ── env + export assembly (per module, in dependency order) ──────────────────
-- Own defs (pub or not) go into this module's useEnv; PUBLIC defs also become
-- export origins.  Imports resolve local names to the ORIGIN key of an already-
-- processed dependency; `pub import` re-exports thread the true origin forward.
addOwnToEnv : Ctx -> HashMap String String -> List DefEntry -> Unit
addOwnToEnv _ _ [] = ()
addOwnToEnv ctx useEnv ((DefEntry ns name key _ _)::rest) =
  let _ = hmSetC ctx useEnv (ns ++ sep ++ name) key
  addOwnToEnv ctx useEnv rest

registerExports : Ctx -> String -> List DefEntry -> List Decl -> Unit
registerExports ctx mid ownDefs decls =
  let _ = registerOwnExports ctx mid ownDefs
  registerReExports ctx mid decls

registerOwnExports : Ctx -> String -> List DefEntry -> Unit
registerOwnExports _ _ [] = ()
registerOwnExports ctx mid ((DefEntry ns name key _ pub)::rest) =
  let _ = whenPub ctx mid ns name key pub
  registerOwnExports ctx mid rest

whenPub : Ctx -> String -> String -> String -> String -> Bool -> Unit
whenPub _ _ _ _ _ False = ()
whenPub ctx mid ns name key True = addExport ctx mid ns name key

-- record `<mid> exports <name>@<ns>` with origin key, both in the flat originOf
-- map (O(1) member lookup) and the per-module list (wildcard enumeration).
addExport : Ctx -> String -> String -> String -> String -> Unit
addExport ctx mid ns name originKey =
  let _ = hmSetC ctx ctx.originOf (mkKey mid ns name) originKey
  let cur = match hmGetC ctx ctx.modExp mid
    Some l => l
    None => []
  hmSetC ctx ctx.modExp mid ((ns, name, originKey)::cur)

registerReExports : Ctx -> String -> List Decl -> Unit
registerReExports _ _ [] = ()
registerReExports ctx mid ((DUse True path _)::rest) =
  let _ = reExportPath ctx mid path
  registerReExports ctx mid rest
registerReExports ctx mid ((DAttrib _ inner)::rest) =
  registerReExports ctx mid (inner::rest)
registerReExports ctx mid (_::rest) = registerReExports ctx mid rest

reExportPath : Ctx -> String -> UsePath -> Unit
reExportPath ctx mid (UseName ns) = reExportName ctx mid ns
reExportPath ctx mid (UseGroup srcPath members) =
  reExportMembers ctx mid (joinDotL srcPath) members
reExportPath ctx mid (UseWild srcPath) = reExportWild ctx mid (joinDotL srcPath)
reExportPath _ _ (UseAlias _ _) = ()

reExportName : Ctx -> String -> List String -> Unit
reExportName ctx mid ns = match splitLastL ns
  Some (pre, nm) => reExportOne ctx mid (joinDotL pre) nm nm
  None => ()

reExportMembers : Ctx -> String -> String -> List UseMember -> Unit
reExportMembers _ _ _ [] = ()
reExportMembers ctx mid srcMod (m::rest) =
  let _ = reExportOne ctx mid srcMod (useMemberOrigin m) (useMemberLocal m)
  reExportMembers ctx mid srcMod rest

-- re-export the origin name `o` from `srcMod` under local `l` in `mid`, in every
-- namespace `srcMod` actually exports it under.
reExportOne : Ctx -> String -> String -> String -> String -> Unit
reExportOne ctx mid srcMod o l =
  let _ = reExportNs ctx mid srcMod o l nsVal
  let _ = reExportNs ctx mid srcMod o l nsTy
  let _ = reExportNs ctx mid srcMod o l nsCtor
  reExportNs ctx mid srcMod o l nsMethod

reExportNs : Ctx -> String -> String -> String -> String -> String -> Unit
reExportNs ctx mid srcMod o l ns = match hmGetC ctx ctx.originOf (mkKey srcMod ns o)
  Some originKey => addExport ctx mid ns l originKey
  None => ()

reExportWild : Ctx -> String -> String -> Unit
reExportWild ctx mid srcMod = match hmGetC ctx ctx.modExp srcMod
  Some entries => reExportWildGo ctx mid entries
  None => ()

reExportWildGo : Ctx -> String -> List (String, String, String) -> Unit
reExportWildGo _ _ [] = ()
reExportWildGo ctx mid ((ns, name, originKey)::rest) =
  let _ = addExport ctx mid ns name originKey
  reExportWildGo ctx mid rest

-- ── imports → this module's useEnv (all DUse, pub or not) ────────────────────
processImports : Ctx -> HashMap String String -> HashMap String String -> List Decl -> Unit
processImports _ _ _ [] = ()
processImports ctx useEnv aliasM ((DUse _ path _)::rest) =
  let _ = importPath ctx useEnv aliasM path
  processImports ctx useEnv aliasM rest
processImports ctx useEnv aliasM ((DAttrib _ inner)::rest) =
  processImports ctx useEnv aliasM (inner::rest)
processImports ctx useEnv aliasM (_::rest) =
  processImports ctx useEnv aliasM rest

importPath : Ctx -> HashMap String String -> HashMap String String -> UsePath -> Unit
importPath ctx useEnv _ (UseName ns) = match splitLastL ns
  Some (pre, nm) => importOne ctx useEnv (joinDotL pre) nm nm
  None => ()
importPath ctx useEnv _ (UseGroup srcPath members) =
  importMembers ctx useEnv (joinDotL srcPath) members
importPath ctx useEnv _ (UseWild srcPath) =
  importWild ctx useEnv (joinDotL srcPath)
importPath ctx _ aliasM (UseAlias srcPath alias) =
  hmSetC ctx aliasM alias (joinDotL srcPath)

importMembers : Ctx -> HashMap String String -> String -> List UseMember -> Unit
importMembers _ _ _ [] = ()
importMembers ctx useEnv srcMod (m::rest) =
  let _ = importOne ctx useEnv srcMod (useMemberOrigin m) (useMemberLocal m)
  importMembers ctx useEnv srcMod rest

importOne : Ctx -> HashMap String String -> String -> String -> String -> Unit
importOne ctx useEnv srcMod o l =
  let _ = importNs ctx useEnv srcMod o l nsVal
  let _ = importNs ctx useEnv srcMod o l nsTy
  let _ = importNs ctx useEnv srcMod o l nsCtor
  importNs ctx useEnv srcMod o l nsMethod

importNs : Ctx -> HashMap String String -> String -> String -> String -> String -> Unit
importNs ctx useEnv srcMod o l ns = match hmGetC ctx ctx.originOf (mkKey srcMod ns o)
  Some originKey => hmSetC ctx useEnv (ns ++ sep ++ l) originKey
  None => ()

importWild : Ctx -> HashMap String String -> String -> Unit
importWild ctx useEnv srcMod = match hmGetC ctx ctx.modExp srcMod
  Some entries => importWildGo ctx useEnv entries
  None => ()

importWildGo : Ctx -> HashMap String String -> List (String, String, String) -> Unit
importWildGo _ _ [] = ()
importWildGo ctx useEnv ((ns, name, originKey)::rest) =
  let _ = hmSetC ctx useEnv (ns ++ sep ++ name) originKey
  importWildGo ctx useEnv rest

-- ── prelude seeding (core + runtime): export origins WITHOUT def recording ───
-- F1: intra-project scope.  Prelude names resolve to stable `core`/`runtime`
-- origin keys so uses group, but no def site is recorded (defOf → None), and we
-- never walk prelude bodies.
seedPrelude : Ctx -> String -> String -> Unit
seedPrelude ctx mid src = match parseWithPositionsOpt src
  None => ()
  Some (decls, _) =>
    let expSet = collectExportedValues ctx decls
    seedPreludeGo ctx mid (preludeDefEntries expSet mid decls)

-- prelude def entries WITHOUT recording (no defs/occ), keyed like real exports.
-- `expSet` supplies sig-exported value names (same `export foo : T` idiom).
preludeDefEntries : HashMap String Unit -> String -> List Decl -> List (String, String, String)
preludeDefEntries _ _ [] = []
preludeDefEntries expSet mid (d::rest) = preludeDefsOfDecl expSet mid d
  ++ preludeDefEntries expSet mid rest

preludeDefsOfDecl : HashMap String Unit -> String -> Decl -> List (String, String, String)
preludeDefsOfDecl expSet mid (DFunDef pub n _ _) = valEntry expSet mid pub n
preludeDefsOfDecl expSet mid (DExtern pub n _) = valEntry expSet mid pub n
preludeDefsOfDecl _ mid (DData vis n _ variants _) = consIf
  (dataIsPub vis)
  (nsTy, n, mkKey mid nsTy n)
  (flatMap (preludeVariant mid) variants)
preludeDefsOfDecl _ mid (DNewtype True n _ con _ _) =
  [(nsTy, n, mkKey mid nsTy n), (nsCtor, con, mkKey mid nsCtor con)]
preludeDefsOfDecl _ mid (DTypeAlias True n _ _) = [(nsTy, n, mkKey mid nsTy n)]
preludeDefsOfDecl _ mid (DInterface { pub, name, methods, ... }) = consIf
  pub
  (nsTy, name, mkKey mid nsTy name)
  (map (preludeMethod mid) methods)
preludeDefsOfDecl expSet mid (DAttrib _ inner) =
  preludeDefsOfDecl expSet mid inner
preludeDefsOfDecl _ _ _ = []

valEntry : HashMap String Unit -> String -> Bool -> String -> List (String, String, String)
valEntry expSet mid pub n =
  if pub || memberOfRaw expSet n then
    [(nsVal, n, mkKey mid nsVal n)]
  else
    []

memberOfRaw : HashMap String Unit -> String -> Bool
memberOfRaw s k = match hmGet k s
  Some _ => True
  None => False

preludeVariant : String -> Variant -> List (String, String, String)
preludeVariant mid (Variant cn _) = [(nsCtor, cn, mkKey mid nsCtor cn)]

preludeMethod : String -> IfaceMethod -> (String, String, String)
preludeMethod mid m =
  let n = ifName m
  (nsMethod, n, mkKey mid nsMethod n)

consIf : Bool -> a -> List a -> List a
consIf False _ xs = xs
consIf True x xs = x::xs

seedPreludeGo : Ctx -> String -> List (String, String, String) -> Unit
seedPreludeGo _ _ [] = ()
seedPreludeGo ctx mid ((ns, name, originKey)::rest) =
  let _ = addExport ctx mid ns name originKey
  seedPreludeGo ctx mid rest

-- copy the prelude modules' exports into a module's useEnv (auto-in-scope).
seedUseEnvPrelude : Ctx -> HashMap String String -> Unit
seedUseEnvPrelude ctx useEnv =
  let _ = importWild ctx useEnv "core"
  importWild ctx useEnv "runtime"

-- ── the per-module driver ────────────────────────────────────────────────────
indexModule : Ctx -> String -> String -> String -> Unit
indexModule ctx mid uri src = match parseWithPositionsOpt src
  None => ()
  Some (decls, positions) =>
    let paired = zipL decls (positionsDecls positions)
    let expSet = collectExportedValues ctx decls
    let ownDefs = collectDefs ctx expSet mid uri paired
    let useEnv = hmNew ()
    let aliasM = hmNew ()
    let _ = seedUseEnvPrelude ctx useEnv
    let _ = addOwnToEnv ctx useEnv ownDefs
    let _ = processImports ctx useEnv aliasM decls
    let _ = registerExports ctx mid ownDefs decls
    walkDecls (W ctx mid uri useEnv aliasM) paired

processModules : Ctx -> (String -> Option String) -> List (String, String, List Decl) -> <IO> Unit
processModules _ _ [] = ()
processModules ctx read ((mid, path, _)::rest) =
  let _ = match getSrc read path
    None => ()
    Some src => indexModule ctx mid path src
  processModules ctx read rest

getSrc : (String -> Option String) -> String -> <IO> Option String
getSrc read path = match read path
  Some s => Some s
  None => match readFile path
    Ok s => Some s
    Err _ => None

newCtx : Unit -> Ctx
newCtx _ = Ctx {
  defs = hmNew (),
  refs = hmNew (),
  occ = hmNew (),
  originOf = hmNew (),
  modExp = hmNew (),
  opCnt = Ref 0,
  fresh = Ref 0,
}

emptyIndex : Unit -> RefIndex
emptyIndex _ =
  RefIndex { defs = hmNew (), refs = hmNew (), occ = hmNew (), ops = 0 }

-- ── PUBLIC API (what the Stage-1 tools call) ─────────────────────────────────

-- Build the whole-project reference index rooted at `entry`.  `read` is the
-- editor-buffer override callback (return `None` to fall back to disk), exactly
-- as `analyzeProject`/`projectEntrySchemes` take it.  Best-effort on load error
-- (returns an empty index — Stage 1 decides how to surface a partial project).
export buildRefIndex : (String -> Option String) -> String -> List String -> String -> String -> <IO> RefIndex
buildRefIndex read entry roots runtimeSrc coreSrc =
  let parseCache = Ref []
  match loadProgramFilesLocatedCached parseCache read entry roots
    Err _ => emptyIndex ()
    Ok mods =>
      let ctx = newCtx ()
      let _ = seedPrelude ctx "runtime" runtimeSrc
      let _ = seedPrelude ctx "core" coreSrc
      -- Reset the op counter after (constant-cost) prelude seeding so `riOps`
      -- measures ONLY the project-indexing work — the quantity the scaling gate
      -- grades N-vs-2N.  A large constant prelude term would otherwise drag the
      -- linear ratio below 2.0 and mask the signal.
      let _ = ctx.opCnt := 0
      let _ = processModules ctx read mods
      RefIndex {
          defs = ctx.defs,
          refs = ctx.refs,
          occ = ctx.occ,
          ops = ctx.opCnt.value,
        }

-- Disk-only convenience (no editor-buffer overrides) — the CLI/probe entry.
export buildRefIndexDisk : String -> List String -> String -> String -> <IO> RefIndex
buildRefIndexDisk entry roots runtimeSrc coreSrc =
  buildRefIndex noOverride entry roots runtimeSrc coreSrc

noOverride : String -> Option String
noOverride _ = None

-- ── WHOLE-PROJECT index build (#254 Stage 1.1) ───────────────────────────────
--
-- `buildRefIndex` above is ENTRY-ROOTED: `loadProgramFilesLocatedCached` walks
-- only the clicked file's OWN imports (downward), so a `references` query on a
-- leaf module's definition misses every use in a file that IMPORTS it (a
-- reverse-dependent is never on the entry's own import closure). This section
-- closes that gap: enumerate every `.mdk` file under the PROJECT ROOT
-- (recursive `listDir`, F1-scoped — never descends into stdlib, which is a
-- SEPARATE root never nested under a project root) and feed the SAME
-- `processModules` walk `buildRefIndex` already uses, just over the FULL file
-- set instead of one entry's closure. F2 (best-effort) is inherited for free:
-- `processModules` -> `indexModule` already no-ops a file that fails to parse
-- (`parseWithPositionsOpt … None => ()`) — one broken sibling never aborts the
-- whole build, whole-project or entry-rooted alike.
--
-- LINEARITY: `processModules ctx read mods` is UNCHANGED (still one O(1)
-- hash/push per token, per file) — the only new cost is the recursive
-- directory walk itself, O(#dirs + #files) with an O(1) `Ref`-list push per
-- discovered file, never a `List`-as-set/`++`-in-a-fold. Total build stays
-- O(total project tokens); see test/diff_compiler_references_scaling.sh's
-- `--project` measurement.
--
-- Module id per file: `moduleIdOfPath [projectRoot] path` — the SAME
-- path-to-id function the entry-rooted loader itself uses (now exported from
-- `driver.loader`), so a file discovered by directory walk gets the IDENTICAL
-- BinderKey module prefix a sibling's `import <id>` would resolve to. This
-- does NOT replicate the loader's `[dependencies]` multi-root canonicalization
-- (`rewriteDecls`/`canonicalModId`) — a no-op for the common single-root
-- project (no declared deps), and out of scope for this fast-follow; a
-- declared-dependency project's cross-package aliasing is a documented
-- residual, not attempted here.

-- Recursively enumerate every `.mdk` file under `root`, depth-first, skipping
-- dot-entries (dotfiles/dot-dirs, e.g. `.git`) — mirrors
-- `medaka_cli.mdk`'s `collectMdkFiles`/`collectMdkFilesRec` idiom (that
-- module doesn't export it, hence this scoped copy). `listDir` on an entry
-- doubles as the dir/file discriminator: `Ok` = directory (recurse), `Err` =
-- a file (or unreadable — either way, no further recursion). Best-effort
-- (F2): an unlistable directory just contributes nothing, never aborts the
-- walk. O(#dirs + #files); an O(1) `Ref`-list push per file, never `++`.
enumerateMdkFiles : String -> <IO> List String
enumerateMdkFiles root =
  let acc = Ref []
  let _ = enumerateDir acc root
  reverseList acc.value

enumerateDir : Ref (List String) -> String -> <IO> Unit
enumerateDir acc dir = match listDir dir
  Err _ => ()
  Ok entries => enumerateEntries acc dir (dropDotEntries entries)

enumerateEntries : Ref (List String) -> String -> List String -> <IO> Unit
enumerateEntries _ _ [] = ()
enumerateEntries acc dir (name::rest) =
  let _ = enumerateOne acc dir name
  enumerateEntries acc dir rest

enumerateOne : Ref (List String) -> String -> String -> <IO> Unit
enumerateOne acc dir name =
  let full = joinPath dir name
  match listDir full
    Ok _ => enumerateDir acc full
    Err _ => if endsWith ".mdk" name then acc := full::acc.value else ()

dropDotEntries : List String -> List String
dropDotEntries [] = []
dropDotEntries (n::rest)
  | startsWith "." n = dropDotEntries rest
  | otherwise = n :: dropDotEntries rest

-- Every enumerated file paired with its loader-consistent module id.
midPathsOf : String -> <IO> List (String, String)
midPathsOf root =
  map (path => (moduleIdOfPath [root] path, path)) (enumerateMdkFiles root)

-- ── dependency-first ORDERING (the part `listDir` doesn't give you) ─────────
--
-- `processModules`/`indexModule` (shared with entry-rooted `buildRefIndex`)
-- assume dependency-first order: `registerReExports`/`processImports` look up
-- an imported module's origin in `ctx.originOf`, which is only populated once
-- THAT module has itself been indexed (`registerOwnExports`). The entry-
-- rooted loader's DFS guarantees this by construction (a module is only
-- appended to its result after every import it walked); a plain `listDir`
-- enumeration has NO such guarantee — filesystem order is arbitrary, and
-- indexing a re-exporting module (`reexport.mdk`) before the module it
-- re-exports (`defs.mdk`) SILENTLY drops the re-export (a no-op lookup miss,
-- not an error), which then makes every USE reached only through that
-- re-export land under an `?ext` (unresolved) key instead of joining the real
-- BinderKey — a real regression a first cut of this feature reproduced and
-- caught right here. Fix: a standard multi-root, dependency-first DFS over
-- the WHOLE enumerated set (not just one entry), same shape as the loader's
-- own `visitModF` — visited-set is a `HashMap String Unit` (O(1) membership,
-- never a `List`-as-set), and an import outside the enumerated set (stdlib,
-- an unreadable sibling) is simply not followed further (F2: best-effort,
-- never fatal; a cycle is broken the same way — mark-before-recurse).
--
-- COST: this parses every file ONCE here (to read its own `DUse` imports)
-- and `processModules` parses it AGAIN afterwards — a bounded 2x constant,
-- not a re-walk of OTHER files' work, so the build stays O(total project
-- tokens) (see test/diff_compiler_references_scaling.sh's `--project` run).
-- The ordering pass's own hash-map ops are routed through the SAME `ctx`
-- op-counting wrappers (`hmGetC`/`hmSetC`) as the rest of the build, so this
-- cost is NOT invisible to `riOps` / the scaling gate.
directImportIds : List Decl -> List String
directImportIds [] = []
directImportIds ((DUse _ path _)::rest) =
  let m = importModId path
  if m == "core" then directImportIds rest else m :: directImportIds rest
directImportIds ((DAttrib _ inner)::rest) = directImportIds (inner::rest)
directImportIds (_::rest) = directImportIds rest

registerMidPaths : Ctx -> HashMap String String -> List (String, String) -> Unit
registerMidPaths _ _ [] = ()
registerMidPaths ctx byMid ((mid, path)::rest) =
  let _ = hmSetC ctx byMid mid path
  registerMidPaths ctx byMid rest

midsOf : List (String, String) -> List String
midsOf [] = []
midsOf ((mid, _)::rest) = mid :: midsOf rest

topoVisitAll : Ctx -> (String -> Option String) -> HashMap String String -> HashMap String Unit -> Ref (List (String, String, List Decl)) -> List String -> <IO> Unit
topoVisitAll _ _ _ _ _ [] = ()
topoVisitAll ctx read byMid visited acc (mid::rest) =
  let _ = topoVisit ctx read byMid visited acc mid
  topoVisitAll ctx read byMid visited acc rest

-- Visit one module: mark it visited FIRST (breaks a cycle without looping),
-- then recurse into its OWN direct imports (dependency-first) before
-- appending it — a post-order DFS emit, so a dependency always lands earlier
-- in `acc` than its dependent. `mid`s outside the enumerated set (`byMid`
-- miss) or a file that fails to parse both no-op (F2: best-effort).
topoVisit : Ctx -> (String -> Option String) -> HashMap String String -> HashMap String Unit -> Ref (List (String, String, List Decl)) -> String -> <IO> Unit
topoVisit ctx read byMid visited acc mid = match hmGetC ctx visited mid
  Some _ => ()
  None => match hmGetC ctx byMid mid
    None => ()
    Some path =>
      let _ = hmSetC ctx visited mid ()
      match getSrc read path
        None => ()
        Some src => match parseWithPositionsOpt src
          None => ()
          Some (decls, _) =>
            let _ = topoVisitAll ctx read byMid visited acc (directImportIds decls)
            acc := (mid, path, decls)::acc.value

-- Order the whole-project file set dependency-first (see block comment
-- above). O(N) — each enumerated file is visited (parsed once, hashed twice)
-- exactly once, regardless of how many OTHER files import it.
topoOrderModules : Ctx -> (String -> Option String) -> List (String, String) -> <IO> List (String, String, List Decl)
topoOrderModules ctx read midPaths =
  let byMid = hmNew ()
  let _ = registerMidPaths ctx byMid midPaths
  let visited = hmNew ()
  let acc = Ref []
  let _ = topoVisitAll ctx read byMid visited acc (midsOf midPaths)
  reverseList acc.value

-- Build the reference index over EVERY `.mdk` file under `projectRoot` — true
-- whole-project scope (see the section header above for why this differs
-- from `buildRefIndex`). `read` is the same editor-buffer override callback
-- (unsaved buffers win over disk).
export buildRefIndexProject : (String -> Option String) -> String -> String -> String -> <IO> RefIndex
buildRefIndexProject read projectRoot runtimeSrc coreSrc =
  let ctx = newCtx ()
  let _ = seedPrelude ctx "runtime" runtimeSrc
  let _ = seedPrelude ctx "core" coreSrc
  -- Reset AFTER prelude seeding, same rationale as `buildRefIndex`: `riOps`
  -- must measure only the project-indexing work the scaling gate grades.
  let _ = ctx.opCnt := 0
  let midPaths = midPathsOf projectRoot
  let mods = topoOrderModules ctx read midPaths
  let _ = processModules ctx read mods
  RefIndex {
      defs = ctx.defs,
      refs = ctx.refs,
      occ = ctx.occ,
      ops = ctx.opCnt.value,
    }

-- Disk-only convenience (no editor-buffer overrides) — the CLI/probe entry.
export buildRefIndexProjectDisk : String -> String -> String -> <IO> RefIndex
buildRefIndexProjectDisk projectRoot runtimeSrc coreSrc =
  buildRefIndexProject noOverride projectRoot runtimeSrc coreSrc

-- The definition site of a binder, if it is defined inside the project.  O(1).
export defOf : RefIndex -> String -> Option (String, Loc)
defOf idx key = hmGet key idx.defs

-- Every use site of a binder, in source order.  O(#uses).
export usesOf : RefIndex -> String -> List (String, Loc)
usesOf idx key = match hmGet key idx.refs
  Some r => reverseList r.value
  None => []

-- The binder referenced/defined at (uri, line, col).  O(size of THAT file) — a
-- scan of one file's occurrences, independent of project size.  `line` is
-- 1-based, `col` 0-based (the `Loc` convention).
export binderAt : RefIndex -> String -> Int -> Int -> Option String
binderAt idx uri line col = match hmGet uri idx.occ
  Some r => scanOcc line col r.value
  None => None

scanOcc : Int -> Int -> List (Loc, String) -> Option String
scanOcc _ _ [] = None
scanOcc line col ((loc, key)::rest)
  | locContains loc line col = Some key
  | otherwise = scanOcc line col rest

-- (1-based startLine, 0-based startCol, 1-based endLine, 0-based endCol) contains
-- a (1-based line, 0-based col) point.
locContains : Loc -> Int -> Int -> Bool
locContains (Loc _ sl sc el ec) line col
  | line < sl = False
  | line > el = False
  | line == sl && col < sc = False
  | line == el && col > ec = False
  | otherwise = True

-- Total O(1) build-op count (hash gets/sets + list pushes) — the perf-gate
-- signal.  Linear build ⇒ this ~doubles when the project doubles.
export riOps : RefIndex -> Int
riOps idx = idx.ops

-- All indexed binder keys (defs).  For probes / Stage-1 enumeration.  O(#defs).
export allDefKeys : RefIndex -> List String
allDefKeys idx = hmKeys idx.defs

-- Count of use sites recorded for a key.  O(#uses).
export usesCount : RefIndex -> String -> Int
usesCount idx key = listLength (usesOf idx key)

-- The number of occurrences a `binderAt` on `uri` would scan (that file's own
-- occurrence-list length).  This is the exact work a query does — a per-query
-- re-walk would grow with the whole project; a correct index keeps it O(clicked
-- file).  The scaling gate holds this FLAT as project size grows.
export occCountFor : RefIndex -> String -> Int
occCountFor idx uri = match hmGet uri idx.occ
  Some r => listLength r.value
  None => 0

-- ── tiny local list helpers (no stdlib list import needed) ───────────────────
reverseList : List a -> List a
reverseList xs = reverseGo xs []

reverseGo : List a -> List a -> List a
reverseGo [] acc = acc
reverseGo (x::xs) acc = reverseGo xs (x::acc)

listLength : List a -> Int
listLength xs = lengthGo xs 0

lengthGo : List a -> Int -> Int
lengthGo [] n = n
lengthGo (_::xs) n = lengthGo xs (n + 1)

joinDotL : List String -> String
joinDotL [] = ""
joinDotL [x] = x
joinDotL (x::rest) = "\{x}.\{joinDotL rest}"

splitLastL : List a -> Option (List a, a)
splitLastL [] = None
splitLastL [x] = Some ([], x)
splitLastL (x::rest) = map ((pre, last) => (x::pre, last)) (splitLastL rest)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Ty" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberOrigin" false) (mem "useMemberLocal" false) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositionsOpt" false) (mem "positionsDecls" false) (mem "DeclPos" false) (mem "declPosNameLoc" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "loadProgramFilesLocatedCached" false) (mem "moduleIdOfPath" false) (mem "importModId" false))))
(DUse false (UseGroup ("support" "util") ((mem "zipL" false) (mem "startsWith" false) (mem "endsWith" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false))))
(DUse false (UseGroup ("support" "char") ((mem "isUpper" false))))
(DUse false (UseGroup ("array") ((mem "get" false "arrayGet"))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false "hmNew") (mem "get" false "hmGet") (mem "set" false "hmSet") (mem "keys" false "hmKeys"))))
(DTypeSig false "sep" (TyCon "String"))
(DFunDef false "sep" () (ELit (LString "\t")))
(DTypeSig false "nsVal" (TyCon "String"))
(DFunDef false "nsVal" () (ELit (LString "val")))
(DTypeSig false "nsTy" (TyCon "String"))
(DFunDef false "nsTy" () (ELit (LString "ty")))
(DTypeSig false "nsCtor" (TyCon "String"))
(DFunDef false "nsCtor" () (ELit (LString "ctor")))
(DTypeSig false "nsField" (TyCon "String"))
(DFunDef false "nsField" () (ELit (LString "field")))
(DTypeSig false "nsMethod" (TyCon "String"))
(DFunDef false "nsMethod" () (ELit (LString "method")))
(DTypeSig false "mkKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "mkKey" ((PVar "modId") (PVar "ns") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "modId") (EVar "sep")) (EVar "ns")) (EVar "sep")) (EVar "name")))
(DTypeSig false "extKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "extKey" ((PVar "ns") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "?ext")) (EApp (EVar "display") (EVar "sep"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "ns"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "sep"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DData Abstract "RefIndex" () ((variant "RefIndex" (ConNamed (field "defs" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Loc")))) (field "refs" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc")))))) (field "occ" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "String")))))) (field "ops" (TyCon "Int"))))) ())
(DData Private "Ctx" () ((variant "Ctx" (ConNamed (field "defs" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Loc")))) (field "refs" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc")))))) (field "occ" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "String")))))) (field "originOf" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String"))) (field "modExp" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))))) (field "opCnt" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "fresh" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DData Private "W" () ((variant "W" (ConPos (TyCon "Ctx") (TyCon "String") (TyCon "String") (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String"))))) ())
(DTypeSig false "bump" (TyFun (TyCon "Ctx") (TyCon "Unit")))
(DFunDef false "bump" ((PVar "ctx")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "opCnt")) (EBinOp "+" (EFieldAccess (EFieldAccess (EVar "ctx") "opCnt") "value") (ELit (LInt 1)))))
(DTypeSig false "hmGetC" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyVar "v")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "hmGetC" ((PVar "ctx") (PVar "m") (PVar "k")) (EBlock (DoLet false false PWild (EApp (EVar "bump") (EVar "ctx"))) (DoExpr (EApp (EApp (EVar "hmGet") (EVar "k")) (EVar "m")))))
(DTypeSig false "hmSetC" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyVar "v")) (TyFun (TyCon "String") (TyFun (TyVar "v") (TyCon "Unit"))))))
(DFunDef false "hmSetC" ((PVar "ctx") (PVar "m") (PVar "k") (PVar "v")) (EBlock (DoLet false false PWild (EApp (EVar "bump") (EVar "ctx"))) (DoExpr (EApp (EApp (EApp (EVar "hmSet") (EVar "k")) (EVar "v")) (EVar "m")))))
(DTypeSig false "nextFresh" (TyFun (TyCon "Ctx") (TyCon "Int")))
(DFunDef false "nextFresh" ((PVar "ctx")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "fresh")) (EBinOp "+" (EFieldAccess (EFieldAccess (EVar "ctx") "fresh") "value") (ELit (LInt 1))))) (DoExpr (EFieldAccess (EFieldAccess (EVar "ctx") "fresh") "value"))))
(DTypeSig false "withUri" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "Loc"))))
(DFunDef false "withUri" ((PVar "uri") (PCon "Loc" PWild (PVar "a") (PVar "b") (PVar "c") (PVar "d"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "uri")) (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d")))
(DTypeSig false "dummyLoc" (TyFun (TyCon "String") (TyCon "Loc")))
(DFunDef false "dummyLoc" ((PVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "uri")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "headIsUpper" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "headIsUpper" ((PVar "s")) (EMatch (EApp (EApp (EVar "arrayGet") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s"))) (arm (PCon "Some" (PVar "c")) () (EApp (EVar "isUpper") (EVar "c"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "patBinderNames" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patBinderNames" ((PCon "PVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "patBinderNames" ((PCon "PWild")) (EListLit))
(DFunDef false "patBinderNames" ((PCon "PLit" PWild)) (EListLit))
(DFunDef false "patBinderNames" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBinderNames")) (EVar "ps")))
(DFunDef false "patBinderNames" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patBinderNames") (EVar "a")) (EApp (EVar "patBinderNames") (EVar "b"))))
(DFunDef false "patBinderNames" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBinderNames")) (EVar "ps")))
(DFunDef false "patBinderNames" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBinderNames")) (EVar "ps")))
(DFunDef false "patBinderNames" ((PCon "PAs" (PVar "x") (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patBinderNames") (EVar "p"))))
(DFunDef false "patBinderNames" ((PCon "PRng" PWild PWild PWild)) (EListLit))
(DFunDef false "patBinderNames" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "flatMap") (EVar "recFieldBinderNames")) (EVar "fields")))
(DTypeSig false "recFieldBinderNames" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recFieldBinderNames" ((PCon "RecPatField" (PVar "name") (PCon "None"))) (EListLit (EVar "name")))
(DFunDef false "recFieldBinderNames" ((PCon "RecPatField" PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patBinderNames") (EVar "p")))
(DTypeSig false "lookupScope" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "lookupScope" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "lookupScope" ((PVar "ctx") (PVar "n") (PCons (PVar "frame") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "bump") (EVar "ctx"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "assocFind") (EVar "ctx")) (EVar "n")) (EVar "frame")) (arm (PCon "Some" (PVar "k")) () (EApp (EVar "Some") (EVar "k"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "lookupScope") (EVar "ctx")) (EVar "n")) (EVar "rest")))))))
(DTypeSig false "assocFind" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "assocFind" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "assocFind" ((PVar "ctx") (PVar "n") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "bump") (EVar "ctx"))) (DoExpr (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EApp (EVar "assocFind") (EVar "ctx")) (EVar "n")) (EVar "rest"))))))
(DTypeSig false "recordDef" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "Unit"))))))
(DFunDef false "recordDef" ((PVar "ctx") (PVar "key") (PVar "uri") (PVar "loc")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "defs")) (EVar "key")) (ETuple (EVar "uri") (EVar "loc")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushOcc") (EVar "ctx")) (EVar "uri")) (EVar "loc")) (EVar "key")))))
(DTypeSig false "recordRef" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "Unit"))))))
(DFunDef false "recordRef" ((PVar "ctx") (PVar "key") (PVar "uri") (PVar "loc")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "pushRef") (EVar "ctx")) (EVar "key")) (EVar "uri")) (EVar "loc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushOcc") (EVar "ctx")) (EVar "uri")) (EVar "loc")) (EVar "key")))))
(DTypeSig false "pushRef" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "Unit"))))))
(DFunDef false "pushRef" ((PVar "ctx") (PVar "key") (PVar "uri") (PVar "loc")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "refs")) (EVar "key")) (arm (PCon "Some" (PVar "r")) () (EBlock (DoLet false false PWild (EApp (EVar "bump") (EVar "ctx"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EBinOp "::" (ETuple (EVar "uri") (EVar "loc")) (EFieldAccess (EVar "r") "value")))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "refs")) (EVar "key")) (EApp (EVar "Ref") (EListLit (ETuple (EVar "uri") (EVar "loc"))))))))
(DTypeSig false "pushOcc" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "pushOcc" ((PVar "ctx") (PVar "uri") (PVar "loc") (PVar "key")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "occ")) (EVar "uri")) (arm (PCon "Some" (PVar "r")) () (EBlock (DoLet false false PWild (EApp (EVar "bump") (EVar "ctx"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EBinOp "::" (ETuple (EVar "loc") (EVar "key")) (EFieldAccess (EVar "r") "value")))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "occ")) (EVar "uri")) (EApp (EVar "Ref") (EListLit (ETuple (EVar "loc") (EVar "key"))))))))
(DTypeSig false "resolveVal" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "resolveVal" ((PCon "W" (PVar "ctx") PWild PWild (PVar "useEnv") PWild) (PVar "scope") (PVar "name")) (EMatch (EApp (EApp (EApp (EVar "lookupScope") (EVar "ctx")) (EVar "name")) (EVar "scope")) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "nsVal") (EVar "sep")) (EVar "name"))) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "nsMethod") (EVar "sep")) (EVar "name"))) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EApp (EApp (EVar "extKey") (EVar "nsVal")) (EVar "name")))))))))
(DTypeSig false "resolveCtor" (TyFun (TyCon "W") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "resolveCtor" ((PCon "W" (PVar "ctx") PWild PWild (PVar "useEnv") PWild) (PVar "name")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "nsCtor") (EVar "sep")) (EVar "name"))) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EApp (EApp (EVar "extKey") (EVar "nsCtor")) (EVar "name")))))
(DTypeSig false "resolveTy" (TyFun (TyCon "W") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "resolveTy" ((PCon "W" (PVar "ctx") PWild PWild (PVar "useEnv") PWild) (PVar "name")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "nsTy") (EVar "sep")) (EVar "name"))) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EApp (EApp (EVar "extKey") (EVar "nsTy")) (EVar "name")))))
(DTypeSig false "resolveField" (TyFun (TyCon "W") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "resolveField" ((PCon "W" (PVar "ctx") PWild PWild (PVar "useEnv") PWild) (PVar "name")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "nsField") (EVar "sep")) (EVar "name"))) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EApp (EApp (EVar "extKey") (EVar "nsField")) (EVar "name")))))
(DTypeSig false "walkExpr" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyCon "Expr") (TyCon "Unit"))))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") PWild (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EApp (EApp (EVar "locWithUriOf") (EVar "w")) (EVar "l"))) (EVar "e")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") PWild (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EApp (EApp (EVar "locWithUriOf") (EVar "w")) (EVar "l"))) (EVar "e")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EVar" (PVar "n"))) (EIf (EApp (EVar "headIsUpper") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "recordRef") (EApp (EVar "ctxOf") (EVar "w"))) (EApp (EApp (EVar "resolveCtor") (EVar "w")) (EVar "n"))) (EApp (EVar "uriOf") (EVar "w"))) (EVar "curLoc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "recordRef") (EApp (EVar "ctxOf") (EVar "w"))) (EApp (EApp (EApp (EVar "resolveVal") (EVar "w")) (EVar "scope")) (EVar "n"))) (EApp (EVar "uriOf") (EVar "w"))) (EVar "curLoc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EApp" (PVar "f") (PVar "x"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "x")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ELam" (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EApp (EVar "flatMap") (EVar "patBinderNames")) (EVar "pats")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "curLoc")) (EVar "body")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ELet" PWild (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EVar "patBinderNames") (EVar "pat")))) (DoLet false false (PVar "scope1") (EIf (EVar "isRec") (EBinOp "::" (EVar "frame") (EVar "scope")) (EVar "scope"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope1")) (EVar "curLoc")) (EVar "e1"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "curLoc")) (EVar "e2")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")))) (DoLet false false (PVar "scope1") (EBinOp "::" (EVar "frame") (EVar "scope"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkBinds") (EVar "w")) (EVar "scope1")) (EVar "curLoc")) (EVar "binds"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope1")) (EVar "curLoc")) (EVar "body")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "arms")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "c"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "el")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "b")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "a")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "b")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EFieldAccess" (PVar "e0") (PVar "f") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "walkFieldAccess") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0")) (EVar "f")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ETuple" (PVar "es"))) (EApp (EApp (EApp (EApp (EVar "walkEach") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "es")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EApp (EApp (EVar "walkEach") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "es")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EApp (EApp (EVar "walkEach") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "es")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "hi")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "hi")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "hi")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "i")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "stmts")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EDo" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "stmts")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EApp (EApp (EVar "walkInterp") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "parts")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EGuards" (PVar "arms"))) (EApp (EApp (EApp (EApp (EVar "walkGuardArms") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "arms")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ERecordCreate" (PVar "name") (PVar "fs"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordRef") (EApp (EVar "ctxOf") (EVar "w"))) (EApp (EApp (EVar "resolveCtor") (EVar "w")) (EVar "name"))) (EApp (EVar "uriOf") (EVar "w"))) (EVar "curLoc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "fs")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild)) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "fs")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EVariantUpdate" (PVar "con") (PVar "e0") (PVar "fs"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordRef") (EApp (EVar "ctxOf") (EVar "w"))) (EApp (EApp (EVar "resolveCtor") (EVar "w")) (EVar "con"))) (EApp (EVar "uriOf") (EVar "w"))) (EVar "curLoc"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "fs")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EApp (EApp (EVar "walkKvs") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "kvs")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ESetLit" PWild (PVar "es"))) (EApp (EApp (EApp (EApp (EVar "walkEach") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "es")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EAsPat" PWild (PVar "e0"))) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ESection" (PVar "s"))) (EApp (EApp (EApp (EApp (EVar "walkSection") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "s")))
(DFunDef false "walkExpr" (PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "walkFieldAccess" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyCon "Unit")))))))
(DFunDef false "walkFieldAccess" ((PVar "w") (PVar "scope") (PVar "curLoc") (PVar "e0") (PVar "f")) (EMatch (EApp (EApp (EVar "aliasHeadOf") (EVar "w")) (EApp (EVar "peelLoc") (EVar "e0"))) (arm (PCon "Some" (PVar "srcMod")) () (EApp (EApp (EApp (EApp (EVar "recordRef") (EApp (EVar "ctxOf") (EVar "w"))) (EApp (EApp (EApp (EVar "aliasOriginKey") (EVar "w")) (EVar "srcMod")) (EVar "f"))) (EApp (EVar "uriOf") (EVar "w"))) (EVar "curLoc"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordRef") (EApp (EVar "ctxOf") (EVar "w"))) (EApp (EApp (EVar "resolveField") (EVar "w")) (EVar "f"))) (EApp (EVar "uriOf") (EVar "w"))) (EVar "curLoc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0")))))))
(DTypeSig false "aliasHeadOf" (TyFun (TyCon "W") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "aliasHeadOf" ((PCon "W" (PVar "ctx") PWild PWild PWild (PVar "aliasM")) (PCon "EVar" (PVar "a"))) (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "aliasM")) (EVar "a")))
(DFunDef false "aliasHeadOf" (PWild PWild) (EVar "None"))
(DTypeSig false "aliasOriginKey" (TyFun (TyCon "W") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "aliasOriginKey" ((PCon "W" (PVar "ctx") PWild PWild PWild PWild) (PVar "srcMod") (PVar "f")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "originOf")) (EApp (EApp (EApp (EVar "mkKey") (EVar "srcMod")) (EVar "nsVal")) (EVar "f"))) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EApp (EApp (EVar "extKey") (EVar "nsVal")) (EVar "f")))))
(DTypeSig false "peelLoc" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "peelLoc" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "peelLoc") (EVar "e")))
(DFunDef false "peelLoc" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "peelLoc") (EVar "e")))
(DFunDef false "peelLoc" ((PVar "e")) (EVar "e"))
(DTypeSig false "walkEach" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Unit"))))))
(DFunDef false "walkEach" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkEach" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PVar "e") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkEach") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkKvs" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))) (TyCon "Unit"))))))
(DFunDef false "walkKvs" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkKvs" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "k"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "v"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkKvs") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkFields" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyCon "Unit"))))))
(DFunDef false "walkFields" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkFields" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "FieldAssign" PWild (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkSection" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyCon "Section") (TyCon "Unit"))))))
(DFunDef false "walkSection" (PWild PWild PWild (PCon "SecBare" PWild)) (ELit LUnit))
(DFunDef false "walkSection" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "SecRight" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e")))
(DFunDef false "walkSection" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "SecLeft" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e")))
(DTypeSig false "walkInterp" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "InterpPart")) (TyCon "Unit"))))))
(DFunDef false "walkInterp" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkInterp" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "InterpStr" PWild) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "walkInterp") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))
(DFunDef false "walkInterp" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "InterpExpr" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkInterp") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkStmts" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Unit"))))))
(DFunDef false "walkStmts" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EVar "patBinderNames") (EVar "p")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "curLoc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "DoLet" PWild PWild (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EVar "patBinderNames") (EVar "p")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "curLoc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "DoAssign" PWild (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "DoFieldAssign" PWild PWild (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkArms" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Unit"))))))
(DFunDef false "walkArms" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkArms" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "Arm" (PVar "pat") (PVar "gs") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EVar "patBinderNames") (EVar "pat")))) (DoLet false false (PVar "scope1") (EBinOp "::" (EVar "frame") (EVar "scope"))) (DoLet false false (PVar "scope2") (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EVar "scope1")) (EVar "curLoc")) (EVar "gs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope2")) (EVar "curLoc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkGuardArms" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyCon "Unit"))))))
(DFunDef false "walkGuardArms" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkGuardArms" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "GuardArm" (PVar "gs") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "scope2") (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "gs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope2")) (EVar "curLoc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkGuardArms") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkGuards" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "walkGuards" (PWild (PVar "scope") PWild (PList)) (EVar "scope"))
(DFunDef false "walkGuards" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DFunDef false "walkGuards" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EVar "patBinderNames") (EVar "p")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkBinds" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Unit"))))))
(DFunDef false "walkBinds" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkBinds" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "LetBind" PWild (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "clauses"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkBinds") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkClauses" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Unit"))))))
(DFunDef false "walkClauses" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkClauses" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "FunClause" (PVar "pats") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EApp (EVar "flatMap") (EVar "patBinderNames")) (EVar "pats")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "curLoc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkTy" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyCon "Ty") (TyCon "Unit")))))
(DFunDef false "walkTy" ((PVar "w") PWild (PCon "TyCon" (PVar "name") (PVar "mloc"))) (EMatch (EVar "mloc") (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EApp (EApp (EVar "recordRef") (EApp (EVar "ctxOf") (EVar "w"))) (EApp (EApp (EVar "resolveTy") (EVar "w")) (EVar "name"))) (EApp (EVar "uriOf") (EVar "w"))) (EApp (EApp (EVar "locWithUriOf") (EVar "w")) (EVar "l")))) (arm (PCon "None") () (ELit LUnit))))
(DFunDef false "walkTy" (PWild PWild (PCon "TyVar" PWild)) (ELit LUnit))
(DFunDef false "walkTy" ((PVar "w") (PVar "curLoc") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "b")))))
(DFunDef false "walkTy" ((PVar "w") (PVar "curLoc") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "b")))))
(DFunDef false "walkTy" ((PVar "w") (PVar "curLoc") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EApp (EVar "walkTys") (EVar "w")) (EVar "curLoc")) (EVar "ts")))
(DFunDef false "walkTy" ((PVar "w") (PVar "curLoc") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "t")))
(DFunDef false "walkTy" ((PVar "w") (PVar "curLoc") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "t")))
(DTypeSig false "walkTys" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Unit")))))
(DFunDef false "walkTys" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkTys" ((PVar "w") (PVar "curLoc") (PCons (PVar "t") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EVar "walkTys") (EVar "w")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "mkNamedFrame" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "mkNamedFrame" (PWild PWild (PList)) (EListLit))
(DFunDef false "mkNamedFrame" ((PVar "w") (PVar "atLoc") (PCons (PVar "n") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "mkOneLocal") (EVar "w")) (EVar "atLoc")) (EVar "n")) (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "atLoc")) (EVar "rest"))))
(DTypeSig false "mkOneLocal" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "mkOneLocal" ((PCon "W" (PVar "ctx") (PVar "mid") (PVar "uri") PWild PWild) (PVar "atLoc") (PVar "name")) (EBlock (DoLet false false (PVar "fid") (EApp (EVar "nextFresh") (EVar "ctx"))) (DoLet false false (PVar "key") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "mid"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "sep"))) (ELit (LString "local"))) (EApp (EVar "display") (EVar "sep"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "sep"))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "fid")))) (ELit (LString "")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordDef") (EVar "ctx")) (EVar "key")) (EVar "uri")) (EApp (EApp (EVar "withUri") (EVar "uri")) (EVar "atLoc")))) (DoExpr (ETuple (EVar "name") (EVar "key")))))
(DTypeSig false "ctxOf" (TyFun (TyCon "W") (TyCon "Ctx")))
(DFunDef false "ctxOf" ((PCon "W" (PVar "ctx") PWild PWild PWild PWild)) (EVar "ctx"))
(DTypeSig false "uriOf" (TyFun (TyCon "W") (TyCon "String")))
(DFunDef false "uriOf" ((PCon "W" PWild PWild (PVar "uri") PWild PWild)) (EVar "uri"))
(DTypeSig false "locWithUriOf" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyCon "Loc"))))
(DFunDef false "locWithUriOf" ((PVar "w") (PVar "l")) (EApp (EApp (EVar "withUri") (EApp (EVar "uriOf") (EVar "w"))) (EVar "l")))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "ppName" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "ppName" ((PCon "PropParam" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "ifName" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifName" ((PCon "IfaceMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DData Private "DefEntry" () ((variant "DefEntry" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Loc") (TyCon "Bool")))) ())
(DTypeSig false "collectDefs" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyApp (TyCon "List") (TyCon "DefEntry"))))))))
(DFunDef false "collectDefs" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "collectDefs" ((PVar "ctx") (PVar "expSet") (PVar "mid") (PVar "uri") (PCons (PTuple (PVar "d") (PVar "p")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "defsOfDecl") (EVar "ctx")) (EVar "expSet")) (EVar "mid")) (EVar "uri")) (EVar "d")) (EApp (EApp (EVar "nameLocOf") (EVar "uri")) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EVar "collectDefs") (EVar "ctx")) (EVar "expSet")) (EVar "mid")) (EVar "uri")) (EVar "rest"))))
(DTypeSig false "valuePub" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "valuePub" (PWild PWild (PCon "True") PWild) (EVar "True"))
(DFunDef false "valuePub" ((PVar "ctx") (PVar "expSet") (PCon "False") (PVar "n")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "expSet")) (EVar "n")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "collectExportedValues" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "collectExportedValues" ((PVar "ctx") (PVar "decls")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "hmNew") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "collectExpValGo") (EVar "ctx")) (EVar "s")) (EVar "decls"))) (DoExpr (EVar "s"))))
(DTypeSig false "collectExpValGo" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "collectExpValGo" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "collectExpValGo" ((PVar "ctx") (PVar "s") (PCons (PCon "DTypeSig" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "s")) (EVar "n")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "collectExpValGo") (EVar "ctx")) (EVar "s")) (EVar "rest")))))
(DFunDef false "collectExpValGo" ((PVar "ctx") (PVar "s") (PCons (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "s")) (EVar "n")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "collectExpValGo") (EVar "ctx")) (EVar "s")) (EVar "rest")))))
(DFunDef false "collectExpValGo" ((PVar "ctx") (PVar "s") (PCons (PCon "DExtern" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "s")) (EVar "n")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "collectExpValGo") (EVar "ctx")) (EVar "s")) (EVar "rest")))))
(DFunDef false "collectExpValGo" ((PVar "ctx") (PVar "s") (PCons (PCon "DLetGroup" (PCon "True") (PVar "binds")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "collectLetNames") (EVar "ctx")) (EVar "s")) (EVar "binds"))) (DoExpr (EApp (EApp (EApp (EVar "collectExpValGo") (EVar "ctx")) (EVar "s")) (EVar "rest")))))
(DFunDef false "collectExpValGo" ((PVar "ctx") (PVar "s") (PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EApp (EApp (EVar "collectExpValGo") (EVar "ctx")) (EVar "s")) (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "collectExpValGo" ((PVar "ctx") (PVar "s") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "collectExpValGo") (EVar "ctx")) (EVar "s")) (EVar "rest")))
(DTypeSig false "collectLetNames" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Unit")))))
(DFunDef false "collectLetNames" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "collectLetNames" ((PVar "ctx") (PVar "s") (PCons (PCon "LetBind" (PVar "n") PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "s")) (EVar "n")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "collectLetNames") (EVar "ctx")) (EVar "s")) (EVar "rest")))))
(DTypeSig false "nameLocOf" (TyFun (TyCon "String") (TyFun (TyCon "DeclPos") (TyCon "Loc"))))
(DFunDef false "nameLocOf" ((PVar "uri") (PVar "p")) (EMatch (EApp (EVar "declPosNameLoc") (EVar "p")) (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EVar "withUri") (EVar "uri")) (EVar "l"))) (arm (PCon "None") () (EApp (EVar "dummyLoc") (EVar "uri")))))
(DTypeSig false "defsOfDecl" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyCon "DefEntry")))))))))
(DFunDef false "defsOfDecl" ((PVar "ctx") (PVar "expSet") (PVar "mid") (PVar "uri") (PCon "DFunDef" (PVar "pub") (PVar "n") PWild PWild) (PVar "loc")) (EListLit (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsVal")) (EVar "n")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsVal")) (EVar "n"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EVar "valuePub") (EVar "ctx")) (EVar "expSet")) (EVar "pub")) (EVar "n"))))))
(DFunDef false "defsOfDecl" ((PVar "ctx") (PVar "expSet") (PVar "mid") (PVar "uri") (PCon "DExtern" (PVar "pub") (PVar "n") PWild) (PVar "loc")) (EListLit (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsVal")) (EVar "n")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsVal")) (EVar "n"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EVar "valuePub") (EVar "ctx")) (EVar "expSet")) (EVar "pub")) (EVar "n"))))))
(DFunDef false "defsOfDecl" (PWild PWild PWild PWild (PCon "DTypeSig" PWild PWild PWild) PWild) (EListLit))
(DFunDef false "defsOfDecl" ((PVar "ctx") (PVar "expSet") (PVar "mid") (PVar "uri") (PCon "DLetGroup" (PVar "pub") (PVar "binds")) (PVar "loc")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "letGroupDef") (EVar "ctx")) (EVar "expSet")) (EVar "mid")) (EVar "uri")) (EVar "loc")) (EVar "pub"))) (EVar "binds")))
(DFunDef false "defsOfDecl" ((PVar "ctx") PWild (PVar "mid") (PVar "uri") (PCon "DData" (PVar "vis") (PVar "n") PWild (PVar "variants") PWild) (PVar "loc")) (EBlock (DoLet false false (PVar "tyDef") (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsTy")) (EVar "n")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "n"))) (EVar "loc")) (EApp (EVar "dataIsPub") (EVar "vis"))))) (DoExpr (EBinOp "::" (EVar "tyDef") (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EApp (EVar "variantDefs") (EVar "ctx")) (EVar "mid")) (EVar "uri")) (EVar "loc")) (EApp (EVar "ctorsPub") (EVar "vis")))) (EVar "variants"))))))
(DFunDef false "defsOfDecl" ((PVar "ctx") PWild (PVar "mid") (PVar "uri") (PCon "DNewtype" (PVar "pub") (PVar "n") PWild (PVar "con") PWild PWild) (PVar "loc")) (EBlock (DoLet false false (PVar "tyDef") (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsTy")) (EVar "n")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "n"))) (EVar "loc")) (EVar "pub")))) (DoLet false false (PVar "conDef") (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsCtor")) (EVar "con")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsCtor")) (EVar "con"))) (EVar "loc")) (EVar "pub")))) (DoExpr (EListLit (EVar "tyDef") (EVar "conDef")))))
(DFunDef false "defsOfDecl" ((PVar "ctx") PWild (PVar "mid") (PVar "uri") (PCon "DTypeAlias" (PVar "pub") (PVar "n") PWild PWild) (PVar "loc")) (EListLit (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsTy")) (EVar "n")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "n"))) (EVar "loc")) (EVar "pub")))))
(DFunDef false "defsOfDecl" ((PVar "ctx") PWild (PVar "mid") (PVar "uri") (PRec "DInterface" ((rf "pub" None) (rf "name" None) (rf "methods" None)) true) (PVar "loc")) (EBlock (DoLet false false (PVar "ifaceDef") (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsTy")) (EVar "name")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "name"))) (EVar "loc")) (EVar "pub")))) (DoExpr (EBinOp "::" (EVar "ifaceDef") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EApp (EVar "methodDef") (EVar "ctx")) (EVar "mid")) (EVar "uri")) (EVar "loc")) (EVar "pub"))) (EVar "methods"))))))
(DFunDef false "defsOfDecl" (PWild PWild PWild PWild (PRec "DImpl" () true) PWild) (EListLit))
(DFunDef false "defsOfDecl" ((PVar "ctx") (PVar "expSet") (PVar "mid") (PVar "uri") (PCon "DAttrib" PWild (PVar "inner")) (PVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "defsOfDecl") (EVar "ctx")) (EVar "expSet")) (EVar "mid")) (EVar "uri")) (EVar "inner")) (EVar "loc")))
(DFunDef false "defsOfDecl" (PWild PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "letGroupDef" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "Bool") (TyFun (TyCon "LetBind") (TyCon "DefEntry")))))))))
(DFunDef false "letGroupDef" ((PVar "ctx") (PVar "expSet") (PVar "mid") (PVar "uri") (PVar "loc") (PVar "pub") (PCon "LetBind" (PVar "n") PWild)) (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsVal")) (EVar "n")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsVal")) (EVar "n"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EVar "valuePub") (EVar "ctx")) (EVar "expSet")) (EVar "pub")) (EVar "n")))))
(DTypeSig false "variantDefs" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "Bool") (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyCon "DefEntry")))))))))
(DFunDef false "variantDefs" ((PVar "ctx") (PVar "mid") (PVar "uri") (PVar "loc") (PVar "pub") (PCon "Variant" (PVar "cn") (PVar "payload"))) (EBinOp "::" (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsCtor")) (EVar "cn")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsCtor")) (EVar "cn"))) (EVar "loc")) (EVar "pub"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldDefs") (EVar "ctx")) (EVar "mid")) (EVar "uri")) (EVar "loc")) (EVar "pub")) (EVar "payload"))))
(DTypeSig false "fieldDefs" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "Bool") (TyFun (TyCon "ConPayload") (TyApp (TyCon "List") (TyCon "DefEntry")))))))))
(DFunDef false "fieldDefs" (PWild PWild PWild PWild PWild (PCon "ConPos" PWild)) (EListLit))
(DFunDef false "fieldDefs" ((PVar "ctx") (PVar "mid") (PVar "uri") (PVar "loc") (PVar "pub") (PCon "ConNamed" (PVar "fields") PWild)) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EApp (EVar "fieldDef") (EVar "ctx")) (EVar "mid")) (EVar "uri")) (EVar "loc")) (EVar "pub"))) (EVar "fields")))
(DTypeSig false "fieldDef" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "Bool") (TyFun (TyCon "Field") (TyCon "DefEntry"))))))))
(DFunDef false "fieldDef" ((PVar "ctx") (PVar "mid") (PVar "uri") (PVar "loc") (PVar "pub") (PCon "Field" (PVar "fn") PWild)) (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsField")) (EVar "fn")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsField")) (EVar "fn"))) (EVar "loc")) (EVar "pub"))))
(DTypeSig false "methodDef" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "Bool") (TyFun (TyCon "IfaceMethod") (TyCon "DefEntry"))))))))
(DFunDef false "methodDef" ((PVar "ctx") (PVar "mid") (PVar "uri") (PVar "loc") (PVar "pub") (PVar "m")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "ifName") (EVar "m"))) (DoExpr (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsMethod")) (EVar "n")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsMethod")) (EVar "n"))) (EVar "loc")) (EVar "pub"))))))
(DTypeSig false "emitDef" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "DefEntry") (TyCon "DefEntry")))))
(DFunDef false "emitDef" ((PVar "ctx") (PVar "uri") (PAs "d" (PCon "DefEntry" PWild PWild (PVar "key") (PVar "loc") PWild))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordDef") (EVar "ctx")) (EVar "key")) (EVar "uri")) (EVar "loc"))) (DoExpr (EVar "d"))))
(DTypeSig false "dataIsPub" (TyFun (TyCon "DataVis") (TyCon "Bool")))
(DFunDef false "dataIsPub" ((PCon "VisPrivate")) (EVar "False"))
(DFunDef false "dataIsPub" (PWild) (EVar "True"))
(DTypeSig false "ctorsPub" (TyFun (TyCon "DataVis") (TyCon "Bool")))
(DFunDef false "ctorsPub" ((PCon "VisPublic")) (EVar "True"))
(DFunDef false "ctorsPub" (PWild) (EVar "False"))
(DTypeSig false "walkDecls" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyCon "Unit"))))
(DFunDef false "walkDecls" (PWild (PList)) (ELit LUnit))
(DFunDef false "walkDecls" ((PVar "w") (PCons (PTuple (PVar "d") (PVar "p")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkDeclBody") (EVar "w")) (EVar "d")) (EApp (EApp (EVar "nameLocOf") (EApp (EVar "uriOf") (EVar "w"))) (EVar "p")))) (DoExpr (EApp (EApp (EVar "walkDecls") (EVar "w")) (EVar "rest")))))
(DTypeSig false "walkDeclBody" (TyFun (TyCon "W") (TyFun (TyCon "Decl") (TyFun (TyCon "Loc") (TyCon "Unit")))))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DFunDef" PWild PWild (PVar "pats") (PVar "body")) (PVar "loc")) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "loc")) (EApp (EApp (EVar "flatMap") (EVar "patBinderNames")) (EVar "pats")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EListLit (EVar "frame"))) (EVar "loc")) (EVar "body")))))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DTypeSig" PWild PWild (PVar "ty")) (PVar "loc")) (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "loc")) (EVar "ty")))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DExtern" PWild PWild (PVar "ty")) (PVar "loc")) (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "loc")) (EVar "ty")))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DData" PWild PWild PWild (PVar "variants") PWild) (PVar "loc")) (EApp (EApp (EApp (EVar "walkVariants") (EVar "w")) (EVar "loc")) (EVar "variants")))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DNewtype" PWild PWild PWild PWild (PVar "fieldTy") PWild) (PVar "loc")) (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "loc")) (EVar "fieldTy")))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DTypeAlias" PWild PWild PWild (PVar "rhs")) (PVar "loc")) (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "loc")) (EVar "rhs")))
(DFunDef false "walkDeclBody" ((PVar "w") (PRec "DInterface" ((rf "methods" None)) true) (PVar "loc")) (EApp (EApp (EApp (EVar "walkIfaceMethods") (EVar "w")) (EVar "loc")) (EVar "methods")))
(DFunDef false "walkDeclBody" ((PVar "w") (PRec "DImpl" ((rf "tys" None) (rf "methods" None)) true) (PVar "loc")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTys") (EVar "w")) (EVar "loc")) (EVar "tys"))) (DoExpr (EApp (EApp (EApp (EVar "walkImplMethods") (EVar "w")) (EVar "loc")) (EVar "methods")))))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DProp" PWild PWild (PVar "params") (PVar "body")) (PVar "loc")) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "loc")) (EApp (EApp (EVar "map") (EVar "ppName")) (EVar "params")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EListLit (EVar "frame"))) (EVar "loc")) (EVar "body")))))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DTest" PWild PWild (PVar "body")) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EListLit)) (EVar "loc")) (EVar "body")))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DBench" PWild PWild (PVar "body")) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EListLit)) (EVar "loc")) (EVar "body")))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DLetGroup" PWild (PVar "binds")) (PVar "loc")) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "loc")) (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkBinds") (EVar "w")) (EListLit (EVar "frame"))) (EVar "loc")) (EVar "binds")))))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DAttrib" PWild (PVar "inner")) (PVar "loc")) (EApp (EApp (EApp (EVar "walkDeclBody") (EVar "w")) (EVar "inner")) (EVar "loc")))
(DFunDef false "walkDeclBody" (PWild PWild PWild) (ELit LUnit))
(DTypeSig false "walkVariants" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Unit")))))
(DFunDef false "walkVariants" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkVariants" ((PVar "w") (PVar "loc") (PCons (PCon "Variant" PWild (PVar "payload")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkPayload") (EVar "w")) (EVar "loc")) (EVar "payload"))) (DoExpr (EApp (EApp (EApp (EVar "walkVariants") (EVar "w")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkPayload" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyCon "ConPayload") (TyCon "Unit")))))
(DFunDef false "walkPayload" ((PVar "w") (PVar "loc") (PCon "ConPos" (PVar "tys"))) (EApp (EApp (EApp (EVar "walkTys") (EVar "w")) (EVar "loc")) (EVar "tys")))
(DFunDef false "walkPayload" ((PVar "w") (PVar "loc") (PCon "ConNamed" (PVar "fields") PWild)) (EApp (EApp (EApp (EVar "walkFieldTys") (EVar "w")) (EVar "loc")) (EVar "fields")))
(DTypeSig false "walkFieldTys" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyCon "Unit")))))
(DFunDef false "walkFieldTys" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkFieldTys" ((PVar "w") (PVar "loc") (PCons (PCon "Field" PWild (PVar "ty")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "loc")) (EVar "ty"))) (DoExpr (EApp (EApp (EApp (EVar "walkFieldTys") (EVar "w")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkIfaceMethods" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Unit")))))
(DFunDef false "walkIfaceMethods" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkIfaceMethods" ((PVar "w") (PVar "loc") (PCons (PCon "IfaceMethod" PWild (PVar "ty") (PVar "mdef")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "loc")) (EVar "ty"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "walkMethodDefault") (EVar "w")) (EVar "loc")) (EVar "mdef"))) (DoExpr (EApp (EApp (EApp (EVar "walkIfaceMethods") (EVar "w")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkMethodDefault" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "Option") (TyCon "MethodDefault")) (TyCon "Unit")))))
(DFunDef false "walkMethodDefault" (PWild PWild (PCon "None")) (ELit LUnit))
(DFunDef false "walkMethodDefault" ((PVar "w") (PVar "loc") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body")))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "loc")) (EApp (EApp (EVar "flatMap") (EVar "patBinderNames")) (EVar "pats")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EListLit (EVar "frame"))) (EVar "loc")) (EVar "body")))))
(DTypeSig false "walkImplMethods" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "Unit")))))
(DFunDef false "walkImplMethods" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkImplMethods" ((PVar "w") (PVar "loc") (PCons (PCon "ImplMethod" PWild (PVar "pats") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "loc")) (EApp (EApp (EVar "flatMap") (EVar "patBinderNames")) (EVar "pats")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EListLit (EVar "frame"))) (EVar "loc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EVar "walkImplMethods") (EVar "w")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "addOwnToEnv" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DefEntry")) (TyCon "Unit")))))
(DFunDef false "addOwnToEnv" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "addOwnToEnv" ((PVar "ctx") (PVar "useEnv") (PCons (PCon "DefEntry" (PVar "ns") (PVar "name") (PVar "key") PWild PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "ns") (EVar "sep")) (EVar "name"))) (EVar "key"))) (DoExpr (EApp (EApp (EApp (EVar "addOwnToEnv") (EVar "ctx")) (EVar "useEnv")) (EVar "rest")))))
(DTypeSig false "registerExports" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DefEntry")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))))
(DFunDef false "registerExports" ((PVar "ctx") (PVar "mid") (PVar "ownDefs") (PVar "decls")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "registerOwnExports") (EVar "ctx")) (EVar "mid")) (EVar "ownDefs"))) (DoExpr (EApp (EApp (EApp (EVar "registerReExports") (EVar "ctx")) (EVar "mid")) (EVar "decls")))))
(DTypeSig false "registerOwnExports" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DefEntry")) (TyCon "Unit")))))
(DFunDef false "registerOwnExports" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "registerOwnExports" ((PVar "ctx") (PVar "mid") (PCons (PCon "DefEntry" (PVar "ns") (PVar "name") (PVar "key") PWild (PVar "pub")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "whenPub") (EVar "ctx")) (EVar "mid")) (EVar "ns")) (EVar "name")) (EVar "key")) (EVar "pub"))) (DoExpr (EApp (EApp (EApp (EVar "registerOwnExports") (EVar "ctx")) (EVar "mid")) (EVar "rest")))))
(DTypeSig false "whenPub" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "Unit"))))))))
(DFunDef false "whenPub" (PWild PWild PWild PWild PWild (PCon "False")) (ELit LUnit))
(DFunDef false "whenPub" ((PVar "ctx") (PVar "mid") (PVar "ns") (PVar "name") (PVar "key") (PCon "True")) (EApp (EApp (EApp (EApp (EApp (EVar "addExport") (EVar "ctx")) (EVar "mid")) (EVar "ns")) (EVar "name")) (EVar "key")))
(DTypeSig false "addExport" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))))
(DFunDef false "addExport" ((PVar "ctx") (PVar "mid") (PVar "ns") (PVar "name") (PVar "originKey")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "originOf")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "ns")) (EVar "name"))) (EVar "originKey"))) (DoLet false false (PVar "cur") (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "modExp")) (EVar "mid")) (arm (PCon "Some" (PVar "l")) () (EVar "l")) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "modExp")) (EVar "mid")) (EBinOp "::" (ETuple (EVar "ns") (EVar "name") (EVar "originKey")) (EVar "cur"))))))
(DTypeSig false "registerReExports" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "registerReExports" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "registerReExports" ((PVar "ctx") (PVar "mid") (PCons (PCon "DUse" (PCon "True") (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "reExportPath") (EVar "ctx")) (EVar "mid")) (EVar "path"))) (DoExpr (EApp (EApp (EApp (EVar "registerReExports") (EVar "ctx")) (EVar "mid")) (EVar "rest")))))
(DFunDef false "registerReExports" ((PVar "ctx") (PVar "mid") (PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EApp (EApp (EVar "registerReExports") (EVar "ctx")) (EVar "mid")) (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "registerReExports" ((PVar "ctx") (PVar "mid") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "registerReExports") (EVar "ctx")) (EVar "mid")) (EVar "rest")))
(DTypeSig false "reExportPath" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyCon "Unit")))))
(DFunDef false "reExportPath" ((PVar "ctx") (PVar "mid") (PCon "UseName" (PVar "ns"))) (EApp (EApp (EApp (EVar "reExportName") (EVar "ctx")) (EVar "mid")) (EVar "ns")))
(DFunDef false "reExportPath" ((PVar "ctx") (PVar "mid") (PCon "UseGroup" (PVar "srcPath") (PVar "members"))) (EApp (EApp (EApp (EApp (EVar "reExportMembers") (EVar "ctx")) (EVar "mid")) (EApp (EVar "joinDotL") (EVar "srcPath"))) (EVar "members")))
(DFunDef false "reExportPath" ((PVar "ctx") (PVar "mid") (PCon "UseWild" (PVar "srcPath"))) (EApp (EApp (EApp (EVar "reExportWild") (EVar "ctx")) (EVar "mid")) (EApp (EVar "joinDotL") (EVar "srcPath"))))
(DFunDef false "reExportPath" (PWild PWild (PCon "UseAlias" PWild PWild)) (ELit LUnit))
(DTypeSig false "reExportName" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "reExportName" ((PVar "ctx") (PVar "mid") (PVar "ns")) (EMatch (EApp (EVar "splitLastL") (EVar "ns")) (arm (PCon "Some" (PTuple (PVar "pre") (PVar "nm"))) () (EApp (EApp (EApp (EApp (EApp (EVar "reExportOne") (EVar "ctx")) (EVar "mid")) (EApp (EVar "joinDotL") (EVar "pre"))) (EVar "nm")) (EVar "nm"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "reExportMembers" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "UseMember")) (TyCon "Unit"))))))
(DFunDef false "reExportMembers" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "reExportMembers" ((PVar "ctx") (PVar "mid") (PVar "srcMod") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "reExportOne") (EVar "ctx")) (EVar "mid")) (EVar "srcMod")) (EApp (EVar "useMemberOrigin") (EVar "m"))) (EApp (EVar "useMemberLocal") (EVar "m")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "reExportMembers") (EVar "ctx")) (EVar "mid")) (EVar "srcMod")) (EVar "rest")))))
(DTypeSig false "reExportOne" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))))
(DFunDef false "reExportOne" ((PVar "ctx") (PVar "mid") (PVar "srcMod") (PVar "o") (PVar "l")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reExportNs") (EVar "ctx")) (EVar "mid")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsVal"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reExportNs") (EVar "ctx")) (EVar "mid")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsTy"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reExportNs") (EVar "ctx")) (EVar "mid")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsCtor"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reExportNs") (EVar "ctx")) (EVar "mid")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsMethod")))))
(DTypeSig false "reExportNs" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit"))))))))
(DFunDef false "reExportNs" ((PVar "ctx") (PVar "mid") (PVar "srcMod") (PVar "o") (PVar "l") (PVar "ns")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "originOf")) (EApp (EApp (EApp (EVar "mkKey") (EVar "srcMod")) (EVar "ns")) (EVar "o"))) (arm (PCon "Some" (PVar "originKey")) () (EApp (EApp (EApp (EApp (EApp (EVar "addExport") (EVar "ctx")) (EVar "mid")) (EVar "ns")) (EVar "l")) (EVar "originKey"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "reExportWild" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "reExportWild" ((PVar "ctx") (PVar "mid") (PVar "srcMod")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "modExp")) (EVar "srcMod")) (arm (PCon "Some" (PVar "entries")) () (EApp (EApp (EApp (EVar "reExportWildGo") (EVar "ctx")) (EVar "mid")) (EVar "entries"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "reExportWildGo" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "reExportWildGo" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "reExportWildGo" ((PVar "ctx") (PVar "mid") (PCons (PTuple (PVar "ns") (PVar "name") (PVar "originKey")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "addExport") (EVar "ctx")) (EVar "mid")) (EVar "ns")) (EVar "name")) (EVar "originKey"))) (DoExpr (EApp (EApp (EApp (EVar "reExportWildGo") (EVar "ctx")) (EVar "mid")) (EVar "rest")))))
(DTypeSig false "processImports" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))))
(DFunDef false "processImports" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "processImports" ((PVar "ctx") (PVar "useEnv") (PVar "aliasM") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "importPath") (EVar "ctx")) (EVar "useEnv")) (EVar "aliasM")) (EVar "path"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "processImports") (EVar "ctx")) (EVar "useEnv")) (EVar "aliasM")) (EVar "rest")))))
(DFunDef false "processImports" ((PVar "ctx") (PVar "useEnv") (PVar "aliasM") (PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "processImports") (EVar "ctx")) (EVar "useEnv")) (EVar "aliasM")) (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "processImports" ((PVar "ctx") (PVar "useEnv") (PVar "aliasM") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "processImports") (EVar "ctx")) (EVar "useEnv")) (EVar "aliasM")) (EVar "rest")))
(DTypeSig false "importPath" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyCon "UsePath") (TyCon "Unit"))))))
(DFunDef false "importPath" ((PVar "ctx") (PVar "useEnv") PWild (PCon "UseName" (PVar "ns"))) (EMatch (EApp (EVar "splitLastL") (EVar "ns")) (arm (PCon "Some" (PTuple (PVar "pre") (PVar "nm"))) () (EApp (EApp (EApp (EApp (EApp (EVar "importOne") (EVar "ctx")) (EVar "useEnv")) (EApp (EVar "joinDotL") (EVar "pre"))) (EVar "nm")) (EVar "nm"))) (arm (PCon "None") () (ELit LUnit))))
(DFunDef false "importPath" ((PVar "ctx") (PVar "useEnv") PWild (PCon "UseGroup" (PVar "srcPath") (PVar "members"))) (EApp (EApp (EApp (EApp (EVar "importMembers") (EVar "ctx")) (EVar "useEnv")) (EApp (EVar "joinDotL") (EVar "srcPath"))) (EVar "members")))
(DFunDef false "importPath" ((PVar "ctx") (PVar "useEnv") PWild (PCon "UseWild" (PVar "srcPath"))) (EApp (EApp (EApp (EVar "importWild") (EVar "ctx")) (EVar "useEnv")) (EApp (EVar "joinDotL") (EVar "srcPath"))))
(DFunDef false "importPath" ((PVar "ctx") PWild (PVar "aliasM") (PCon "UseAlias" (PVar "srcPath") (PVar "alias"))) (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "aliasM")) (EVar "alias")) (EApp (EVar "joinDotL") (EVar "srcPath"))))
(DTypeSig false "importMembers" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "UseMember")) (TyCon "Unit"))))))
(DFunDef false "importMembers" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "importMembers" ((PVar "ctx") (PVar "useEnv") (PVar "srcMod") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "importOne") (EVar "ctx")) (EVar "useEnv")) (EVar "srcMod")) (EApp (EVar "useMemberOrigin") (EVar "m"))) (EApp (EVar "useMemberLocal") (EVar "m")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "importMembers") (EVar "ctx")) (EVar "useEnv")) (EVar "srcMod")) (EVar "rest")))))
(DTypeSig false "importOne" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))))
(DFunDef false "importOne" ((PVar "ctx") (PVar "useEnv") (PVar "srcMod") (PVar "o") (PVar "l")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "importNs") (EVar "ctx")) (EVar "useEnv")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsVal"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "importNs") (EVar "ctx")) (EVar "useEnv")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsTy"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "importNs") (EVar "ctx")) (EVar "useEnv")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsCtor"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "importNs") (EVar "ctx")) (EVar "useEnv")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsMethod")))))
(DTypeSig false "importNs" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit"))))))))
(DFunDef false "importNs" ((PVar "ctx") (PVar "useEnv") (PVar "srcMod") (PVar "o") (PVar "l") (PVar "ns")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "originOf")) (EApp (EApp (EApp (EVar "mkKey") (EVar "srcMod")) (EVar "ns")) (EVar "o"))) (arm (PCon "Some" (PVar "originKey")) () (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "ns") (EVar "sep")) (EVar "l"))) (EVar "originKey"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "importWild" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "importWild" ((PVar "ctx") (PVar "useEnv") (PVar "srcMod")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "modExp")) (EVar "srcMod")) (arm (PCon "Some" (PVar "entries")) () (EApp (EApp (EApp (EVar "importWildGo") (EVar "ctx")) (EVar "useEnv")) (EVar "entries"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "importWildGo" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "importWildGo" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "importWildGo" ((PVar "ctx") (PVar "useEnv") (PCons (PTuple (PVar "ns") (PVar "name") (PVar "originKey")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "ns") (EVar "sep")) (EVar "name"))) (EVar "originKey"))) (DoExpr (EApp (EApp (EApp (EVar "importWildGo") (EVar "ctx")) (EVar "useEnv")) (EVar "rest")))))
(DTypeSig false "seedPrelude" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "seedPrelude" ((PVar "ctx") (PVar "mid") (PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PTuple (PVar "decls") PWild)) () (EBlock (DoLet false false (PVar "expSet") (EApp (EApp (EVar "collectExportedValues") (EVar "ctx")) (EVar "decls"))) (DoExpr (EApp (EApp (EApp (EVar "seedPreludeGo") (EVar "ctx")) (EVar "mid")) (EApp (EApp (EApp (EVar "preludeDefEntries") (EVar "expSet")) (EVar "mid")) (EVar "decls"))))))))
(DTypeSig false "preludeDefEntries" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))))
(DFunDef false "preludeDefEntries" (PWild PWild (PList)) (EListLit))
(DFunDef false "preludeDefEntries" ((PVar "expSet") (PVar "mid") (PCons (PVar "d") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EVar "preludeDefsOfDecl") (EVar "expSet")) (EVar "mid")) (EVar "d")) (EApp (EApp (EApp (EVar "preludeDefEntries") (EVar "expSet")) (EVar "mid")) (EVar "rest"))))
(DTypeSig false "preludeDefsOfDecl" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))))
(DFunDef false "preludeDefsOfDecl" ((PVar "expSet") (PVar "mid") (PCon "DFunDef" (PVar "pub") (PVar "n") PWild PWild)) (EApp (EApp (EApp (EApp (EVar "valEntry") (EVar "expSet")) (EVar "mid")) (EVar "pub")) (EVar "n")))
(DFunDef false "preludeDefsOfDecl" ((PVar "expSet") (PVar "mid") (PCon "DExtern" (PVar "pub") (PVar "n") PWild)) (EApp (EApp (EApp (EApp (EVar "valEntry") (EVar "expSet")) (EVar "mid")) (EVar "pub")) (EVar "n")))
(DFunDef false "preludeDefsOfDecl" (PWild (PVar "mid") (PCon "DData" (PVar "vis") (PVar "n") PWild (PVar "variants") PWild)) (EApp (EApp (EApp (EVar "consIf") (EApp (EVar "dataIsPub") (EVar "vis"))) (ETuple (EVar "nsTy") (EVar "n") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "n")))) (EApp (EApp (EVar "flatMap") (EApp (EVar "preludeVariant") (EVar "mid"))) (EVar "variants"))))
(DFunDef false "preludeDefsOfDecl" (PWild (PVar "mid") (PCon "DNewtype" (PCon "True") (PVar "n") PWild (PVar "con") PWild PWild)) (EListLit (ETuple (EVar "nsTy") (EVar "n") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "n"))) (ETuple (EVar "nsCtor") (EVar "con") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsCtor")) (EVar "con")))))
(DFunDef false "preludeDefsOfDecl" (PWild (PVar "mid") (PCon "DTypeAlias" (PCon "True") (PVar "n") PWild PWild)) (EListLit (ETuple (EVar "nsTy") (EVar "n") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "n")))))
(DFunDef false "preludeDefsOfDecl" (PWild (PVar "mid") (PRec "DInterface" ((rf "pub" None) (rf "name" None) (rf "methods" None)) true)) (EApp (EApp (EApp (EVar "consIf") (EVar "pub")) (ETuple (EVar "nsTy") (EVar "name") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "name")))) (EApp (EApp (EVar "map") (EApp (EVar "preludeMethod") (EVar "mid"))) (EVar "methods"))))
(DFunDef false "preludeDefsOfDecl" ((PVar "expSet") (PVar "mid") (PCon "DAttrib" PWild (PVar "inner"))) (EApp (EApp (EApp (EVar "preludeDefsOfDecl") (EVar "expSet")) (EVar "mid")) (EVar "inner")))
(DFunDef false "preludeDefsOfDecl" (PWild PWild PWild) (EListLit))
(DTypeSig false "valEntry" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))))))))
(DFunDef false "valEntry" ((PVar "expSet") (PVar "mid") (PVar "pub") (PVar "n")) (EIf (EBinOp "||" (EVar "pub") (EApp (EApp (EVar "memberOfRaw") (EVar "expSet")) (EVar "n"))) (EListLit (ETuple (EVar "nsVal") (EVar "n") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsVal")) (EVar "n")))) (EListLit)))
(DTypeSig false "memberOfRaw" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "memberOfRaw" ((PVar "s") (PVar "k")) (EMatch (EApp (EApp (EVar "hmGet") (EVar "k")) (EVar "s")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "preludeVariant" (TyFun (TyCon "String") (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))))))
(DFunDef false "preludeVariant" ((PVar "mid") (PCon "Variant" (PVar "cn") PWild)) (EListLit (ETuple (EVar "nsCtor") (EVar "cn") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsCtor")) (EVar "cn")))))
(DTypeSig false "preludeMethod" (TyFun (TyCon "String") (TyFun (TyCon "IfaceMethod") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "preludeMethod" ((PVar "mid") (PVar "m")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "ifName") (EVar "m"))) (DoExpr (ETuple (EVar "nsMethod") (EVar "n") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsMethod")) (EVar "n"))))))
(DTypeSig false "consIf" (TyFun (TyCon "Bool") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "consIf" ((PCon "False") PWild (PVar "xs")) (EVar "xs"))
(DFunDef false "consIf" ((PCon "True") (PVar "x") (PVar "xs")) (EBinOp "::" (EVar "x") (EVar "xs")))
(DTypeSig false "seedPreludeGo" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "seedPreludeGo" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "seedPreludeGo" ((PVar "ctx") (PVar "mid") (PCons (PTuple (PVar "ns") (PVar "name") (PVar "originKey")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "addExport") (EVar "ctx")) (EVar "mid")) (EVar "ns")) (EVar "name")) (EVar "originKey"))) (DoExpr (EApp (EApp (EApp (EVar "seedPreludeGo") (EVar "ctx")) (EVar "mid")) (EVar "rest")))))
(DTypeSig false "seedUseEnvPrelude" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "seedUseEnvPrelude" ((PVar "ctx") (PVar "useEnv")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "importWild") (EVar "ctx")) (EVar "useEnv")) (ELit (LString "core")))) (DoExpr (EApp (EApp (EApp (EVar "importWild") (EVar "ctx")) (EVar "useEnv")) (ELit (LString "runtime"))))))
(DTypeSig false "indexModule" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "indexModule" ((PVar "ctx") (PVar "mid") (PVar "uri") (PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EBlock (DoLet false false (PVar "paired") (EApp (EApp (EVar "zipL") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions")))) (DoLet false false (PVar "expSet") (EApp (EApp (EVar "collectExportedValues") (EVar "ctx")) (EVar "decls"))) (DoLet false false (PVar "ownDefs") (EApp (EApp (EApp (EApp (EApp (EVar "collectDefs") (EVar "ctx")) (EVar "expSet")) (EVar "mid")) (EVar "uri")) (EVar "paired"))) (DoLet false false (PVar "useEnv") (EApp (EVar "hmNew") (ELit LUnit))) (DoLet false false (PVar "aliasM") (EApp (EVar "hmNew") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "seedUseEnvPrelude") (EVar "ctx")) (EVar "useEnv"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "addOwnToEnv") (EVar "ctx")) (EVar "useEnv")) (EVar "ownDefs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "processImports") (EVar "ctx")) (EVar "useEnv")) (EVar "aliasM")) (EVar "decls"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "registerExports") (EVar "ctx")) (EVar "mid")) (EVar "ownDefs")) (EVar "decls"))) (DoExpr (EApp (EApp (EVar "walkDecls") (EApp (EApp (EApp (EApp (EApp (EVar "W") (EVar "ctx")) (EVar "mid")) (EVar "uri")) (EVar "useEnv")) (EVar "aliasM"))) (EVar "paired")))))))
(DTypeSig false "processModules" (TyFun (TyCon "Ctx") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "processModules" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "processModules" ((PVar "ctx") (PVar "read") (PCons (PTuple (PVar "mid") (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EMatch (EApp (EApp (EVar "getSrc") (EVar "read")) (EVar "path")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EVar "indexModule") (EVar "ctx")) (EVar "mid")) (EVar "path")) (EVar "src"))))) (DoExpr (EApp (EApp (EApp (EVar "processModules") (EVar "ctx")) (EVar "read")) (EVar "rest")))))
(DTypeSig false "getSrc" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "getSrc" ((PVar "read") (PVar "path")) (EMatch (EApp (EVar "read") (EVar "path")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Ok" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "Err" PWild) () (EVar "None"))))))
(DTypeSig false "newCtx" (TyFun (TyCon "Unit") (TyCon "Ctx")))
(DFunDef false "newCtx" (PWild) (ERecordCreate "Ctx" ((fa "defs" (EApp (EVar "hmNew") (ELit LUnit))) (fa "refs" (EApp (EVar "hmNew") (ELit LUnit))) (fa "occ" (EApp (EVar "hmNew") (ELit LUnit))) (fa "originOf" (EApp (EVar "hmNew") (ELit LUnit))) (fa "modExp" (EApp (EVar "hmNew") (ELit LUnit))) (fa "opCnt" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "fresh" (EApp (EVar "Ref") (ELit (LInt 0)))))))
(DTypeSig false "emptyIndex" (TyFun (TyCon "Unit") (TyCon "RefIndex")))
(DFunDef false "emptyIndex" (PWild) (ERecordCreate "RefIndex" ((fa "defs" (EApp (EVar "hmNew") (ELit LUnit))) (fa "refs" (EApp (EVar "hmNew") (ELit LUnit))) (fa "occ" (EApp (EVar "hmNew") (ELit LUnit))) (fa "ops" (ELit (LInt 0))))))
(DTypeSig true "buildRefIndex" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "RefIndex"))))))))
(DFunDef false "buildRefIndex" ((PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "parseCache") (EApp (EVar "Ref") (EListLit))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "loadProgramFilesLocatedCached") (EVar "parseCache")) (EVar "read")) (EVar "entry")) (EVar "roots")) (arm (PCon "Err" PWild) () (EApp (EVar "emptyIndex") (ELit LUnit))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "newCtx") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "seedPrelude") (EVar "ctx")) (ELit (LString "runtime"))) (EVar "runtimeSrc"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "seedPrelude") (EVar "ctx")) (ELit (LString "core"))) (EVar "coreSrc"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "opCnt")) (ELit (LInt 0)))) (DoLet false false PWild (EApp (EApp (EApp (EVar "processModules") (EVar "ctx")) (EVar "read")) (EVar "mods"))) (DoExpr (ERecordCreate "RefIndex" ((fa "defs" (EFieldAccess (EVar "ctx") "defs")) (fa "refs" (EFieldAccess (EVar "ctx") "refs")) (fa "occ" (EFieldAccess (EVar "ctx") "occ")) (fa "ops" (EFieldAccess (EFieldAccess (EVar "ctx") "opCnt") "value")))))))))))
(DTypeSig true "buildRefIndexDisk" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "RefIndex")))))))
(DFunDef false "buildRefIndexDisk" ((PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EApp (EApp (EApp (EApp (EApp (EVar "buildRefIndex") (EVar "noOverride")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")))
(DTypeSig false "noOverride" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "noOverride" (PWild) (EVar "None"))
(DTypeSig false "enumerateMdkFiles" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "enumerateMdkFiles" ((PVar "root")) (EBlock (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "enumerateDir") (EVar "acc")) (EVar "root"))) (DoExpr (EApp (EVar "reverseList") (EFieldAccess (EVar "acc") "value")))))
(DTypeSig false "enumerateDir" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "enumerateDir" ((PVar "acc") (PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EApp (EVar "enumerateEntries") (EVar "acc")) (EVar "dir")) (EApp (EVar "dropDotEntries") (EVar "entries"))))))
(DTypeSig false "enumerateEntries" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "enumerateEntries" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "enumerateEntries" ((PVar "acc") (PVar "dir") (PCons (PVar "name") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "enumerateOne") (EVar "acc")) (EVar "dir")) (EVar "name"))) (DoExpr (EApp (EApp (EApp (EVar "enumerateEntries") (EVar "acc")) (EVar "dir")) (EVar "rest")))))
(DTypeSig false "enumerateOne" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "enumerateOne" ((PVar "acc") (PVar "dir") (PVar "name")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "enumerateDir") (EVar "acc")) (EVar "full"))) (arm (PCon "Err" PWild) () (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "name")) (EApp (EApp (EVar "setRef") (EVar "acc")) (EBinOp "::" (EVar "full") (EFieldAccess (EVar "acc") "value"))) (ELit LUnit)))))))
(DTypeSig false "dropDotEntries" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropDotEntries" ((PList)) (EListLit))
(DFunDef false "dropDotEntries" ((PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (EApp (EVar "dropDotEntries") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "n") (EApp (EVar "dropDotEntries") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "midPathsOf" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "midPathsOf" ((PVar "root")) (EApp (EApp (EVar "map") (ELam ((PVar "path")) (ETuple (EApp (EApp (EVar "moduleIdOfPath") (EListLit (EVar "root"))) (EVar "path")) (EVar "path")))) (EApp (EVar "enumerateMdkFiles") (EVar "root"))))
(DTypeSig false "directImportIds" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "directImportIds" ((PList)) (EListLit))
(DFunDef false "directImportIds" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "m") (EApp (EVar "importModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "m") (ELit (LString "core"))) (EApp (EVar "directImportIds") (EVar "rest")) (EBinOp "::" (EVar "m") (EApp (EVar "directImportIds") (EVar "rest")))))))
(DFunDef false "directImportIds" ((PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EVar "directImportIds") (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "directImportIds" ((PCons PWild (PVar "rest"))) (EApp (EVar "directImportIds") (EVar "rest")))
(DTypeSig false "registerMidPaths" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "registerMidPaths" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "registerMidPaths" ((PVar "ctx") (PVar "byMid") (PCons (PTuple (PVar "mid") (PVar "path")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "byMid")) (EVar "mid")) (EVar "path"))) (DoExpr (EApp (EApp (EApp (EVar "registerMidPaths") (EVar "ctx")) (EVar "byMid")) (EVar "rest")))))
(DTypeSig false "midsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "midsOf" ((PList)) (EListLit))
(DFunDef false "midsOf" ((PCons (PTuple (PVar "mid") PWild) (PVar "rest"))) (EBinOp "::" (EVar "mid") (EApp (EVar "midsOf") (EVar "rest"))))
(DTypeSig false "topoVisitAll" (TyFun (TyCon "Ctx") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "topoVisitAll" (PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "topoVisitAll" ((PVar "ctx") (PVar "read") (PVar "byMid") (PVar "visited") (PVar "acc") (PCons (PVar "mid") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "topoVisit") (EVar "ctx")) (EVar "read")) (EVar "byMid")) (EVar "visited")) (EVar "acc")) (EVar "mid"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "topoVisitAll") (EVar "ctx")) (EVar "read")) (EVar "byMid")) (EVar "visited")) (EVar "acc")) (EVar "rest")))))
(DTypeSig false "topoVisit" (TyFun (TyCon "Ctx") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "topoVisit" ((PVar "ctx") (PVar "read") (PVar "byMid") (PVar "visited") (PVar "acc") (PVar "mid")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "visited")) (EVar "mid")) (arm (PCon "Some" PWild) () (ELit LUnit)) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "byMid")) (EVar "mid")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "path")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "visited")) (EVar "mid")) (ELit LUnit))) (DoExpr (EMatch (EApp (EApp (EVar "getSrc") (EVar "read")) (EVar "path")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "src")) () (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PTuple (PVar "decls") PWild)) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "topoVisitAll") (EVar "ctx")) (EVar "read")) (EVar "byMid")) (EVar "visited")) (EVar "acc")) (EApp (EVar "directImportIds") (EVar "decls")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "acc")) (EBinOp "::" (ETuple (EVar "mid") (EVar "path") (EVar "decls")) (EFieldAccess (EVar "acc") "value"))))))))))))))))
(DTypeSig false "topoOrderModules" (TyFun (TyCon "Ctx") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "topoOrderModules" ((PVar "ctx") (PVar "read") (PVar "midPaths")) (EBlock (DoLet false false (PVar "byMid") (EApp (EVar "hmNew") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "registerMidPaths") (EVar "ctx")) (EVar "byMid")) (EVar "midPaths"))) (DoLet false false (PVar "visited") (EApp (EVar "hmNew") (ELit LUnit))) (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "topoVisitAll") (EVar "ctx")) (EVar "read")) (EVar "byMid")) (EVar "visited")) (EVar "acc")) (EApp (EVar "midsOf") (EVar "midPaths")))) (DoExpr (EApp (EVar "reverseList") (EFieldAccess (EVar "acc") "value")))))
(DTypeSig true "buildRefIndexProject" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "RefIndex")))))))
(DFunDef false "buildRefIndexProject" ((PVar "read") (PVar "projectRoot") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "newCtx") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "seedPrelude") (EVar "ctx")) (ELit (LString "runtime"))) (EVar "runtimeSrc"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "seedPrelude") (EVar "ctx")) (ELit (LString "core"))) (EVar "coreSrc"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "opCnt")) (ELit (LInt 0)))) (DoLet false false (PVar "midPaths") (EApp (EVar "midPathsOf") (EVar "projectRoot"))) (DoLet false false (PVar "mods") (EApp (EApp (EApp (EVar "topoOrderModules") (EVar "ctx")) (EVar "read")) (EVar "midPaths"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "processModules") (EVar "ctx")) (EVar "read")) (EVar "mods"))) (DoExpr (ERecordCreate "RefIndex" ((fa "defs" (EFieldAccess (EVar "ctx") "defs")) (fa "refs" (EFieldAccess (EVar "ctx") "refs")) (fa "occ" (EFieldAccess (EVar "ctx") "occ")) (fa "ops" (EFieldAccess (EFieldAccess (EVar "ctx") "opCnt") "value")))))))
(DTypeSig true "buildRefIndexProjectDisk" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "RefIndex"))))))
(DFunDef false "buildRefIndexProjectDisk" ((PVar "projectRoot") (PVar "runtimeSrc") (PVar "coreSrc")) (EApp (EApp (EApp (EApp (EVar "buildRefIndexProject") (EVar "noOverride")) (EVar "projectRoot")) (EVar "runtimeSrc")) (EVar "coreSrc")))
(DTypeSig true "defOf" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Loc"))))))
(DFunDef false "defOf" ((PVar "idx") (PVar "key")) (EApp (EApp (EVar "hmGet") (EVar "key")) (EFieldAccess (EVar "idx") "defs")))
(DTypeSig true "usesOf" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))))))
(DFunDef false "usesOf" ((PVar "idx") (PVar "key")) (EMatch (EApp (EApp (EVar "hmGet") (EVar "key")) (EFieldAccess (EVar "idx") "refs")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "reverseList") (EFieldAccess (EVar "r") "value"))) (arm (PCon "None") () (EListLit))))
(DTypeSig true "binderAt" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "binderAt" ((PVar "idx") (PVar "uri") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EVar "hmGet") (EVar "uri")) (EFieldAccess (EVar "idx") "occ")) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EApp (EVar "scanOcc") (EVar "line")) (EVar "col")) (EFieldAccess (EVar "r") "value"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "scanOcc" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "scanOcc" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "scanOcc" ((PVar "line") (PVar "col") (PCons (PTuple (PVar "loc") (PVar "key")) (PVar "rest"))) (EIf (EApp (EApp (EApp (EVar "locContains") (EVar "loc")) (EVar "line")) (EVar "col")) (EApp (EVar "Some") (EVar "key")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "scanOcc") (EVar "line")) (EVar "col")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "locContains" (TyFun (TyCon "Loc") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "locContains" ((PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (PVar "line") (PVar "col")) (EIf (EBinOp "<" (EVar "line") (EVar "sl")) (EVar "False") (EIf (EBinOp ">" (EVar "line") (EVar "el")) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EVar "line") (EVar "sl")) (EBinOp "<" (EVar "col") (EVar "sc"))) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EVar "line") (EVar "el")) (EBinOp ">" (EVar "col") (EVar "ec"))) (EVar "False") (EIf (EVar "otherwise") (EVar "True") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig true "riOps" (TyFun (TyCon "RefIndex") (TyCon "Int")))
(DFunDef false "riOps" ((PVar "idx")) (EFieldAccess (EVar "idx") "ops"))
(DTypeSig true "allDefKeys" (TyFun (TyCon "RefIndex") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "allDefKeys" ((PVar "idx")) (EApp (EVar "hmKeys") (EFieldAccess (EVar "idx") "defs")))
(DTypeSig true "usesCount" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "usesCount" ((PVar "idx") (PVar "key")) (EApp (EVar "listLength") (EApp (EApp (EVar "usesOf") (EVar "idx")) (EVar "key"))))
(DTypeSig true "occCountFor" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "occCountFor" ((PVar "idx") (PVar "uri")) (EMatch (EApp (EApp (EVar "hmGet") (EVar "uri")) (EFieldAccess (EVar "idx") "occ")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "listLength") (EFieldAccess (EVar "r") "value"))) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "reverseList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "reverseList" ((PVar "xs")) (EApp (EApp (EVar "reverseGo") (EVar "xs")) (EListLit)))
(DTypeSig false "reverseGo" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "reverseGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseGo" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "reverseGo") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig false "listLength" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))
(DFunDef false "listLength" ((PVar "xs")) (EApp (EApp (EVar "lengthGo") (EVar "xs")) (ELit (LInt 0))))
(DTypeSig false "lengthGo" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lengthGo" ((PList) (PVar "n")) (EVar "n"))
(DFunDef false "lengthGo" ((PCons PWild (PVar "xs")) (PVar "n")) (EApp (EApp (EVar "lengthGo") (EVar "xs")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))
(DTypeSig false "joinDotL" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinDotL" ((PList)) (ELit (LString "")))
(DFunDef false "joinDotL" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "joinDotL" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "joinDotL") (EVar "rest")))) (ELit (LString ""))))
(DTypeSig false "splitLastL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyVar "a")))))
(DFunDef false "splitLastL" ((PList)) (EVar "None"))
(DFunDef false "splitLastL" ((PList (PVar "x"))) (EApp (EVar "Some") (ETuple (EListLit) (EVar "x"))))
(DFunDef false "splitLastL" ((PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "pre") (PVar "last"))) (ETuple (EBinOp "::" (EVar "x") (EVar "pre")) (EVar "last")))) (EApp (EVar "splitLastL") (EVar "rest"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Ty" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberOrigin" false) (mem "useMemberLocal" false) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseWithPositionsOpt" false) (mem "positionsDecls" false) (mem "DeclPos" false) (mem "declPosNameLoc" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "loadProgramFilesLocatedCached" false) (mem "moduleIdOfPath" false) (mem "importModId" false))))
(DUse false (UseGroup ("support" "util") ((mem "zipL" false) (mem "startsWith" false) (mem "endsWith" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false))))
(DUse false (UseGroup ("support" "char") ((mem "isUpper" false))))
(DUse false (UseGroup ("array") ((mem "get" false "arrayGet"))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false "hmNew") (mem "get" false "hmGet") (mem "set" false "hmSet") (mem "keys" false "hmKeys"))))
(DTypeSig false "sep" (TyCon "String"))
(DFunDef false "sep" () (ELit (LString "\t")))
(DTypeSig false "nsVal" (TyCon "String"))
(DFunDef false "nsVal" () (ELit (LString "val")))
(DTypeSig false "nsTy" (TyCon "String"))
(DFunDef false "nsTy" () (ELit (LString "ty")))
(DTypeSig false "nsCtor" (TyCon "String"))
(DFunDef false "nsCtor" () (ELit (LString "ctor")))
(DTypeSig false "nsField" (TyCon "String"))
(DFunDef false "nsField" () (ELit (LString "field")))
(DTypeSig false "nsMethod" (TyCon "String"))
(DFunDef false "nsMethod" () (ELit (LString "method")))
(DTypeSig false "mkKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "mkKey" ((PVar "modId") (PVar "ns") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "modId") (EVar "sep")) (EVar "ns")) (EVar "sep")) (EVar "name")))
(DTypeSig false "extKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "extKey" ((PVar "ns") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "?ext")) (EApp (EMethodRef "display") (EVar "sep"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "ns"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "sep"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DData Abstract "RefIndex" () ((variant "RefIndex" (ConNamed (field "defs" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Loc")))) (field "refs" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc")))))) (field "occ" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "String")))))) (field "ops" (TyCon "Int"))))) ())
(DData Private "Ctx" () ((variant "Ctx" (ConNamed (field "defs" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Loc")))) (field "refs" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc")))))) (field "occ" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "String")))))) (field "originOf" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String"))) (field "modExp" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))))) (field "opCnt" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "fresh" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DData Private "W" () ((variant "W" (ConPos (TyCon "Ctx") (TyCon "String") (TyCon "String") (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String"))))) ())
(DTypeSig false "bump" (TyFun (TyCon "Ctx") (TyCon "Unit")))
(DFunDef false "bump" ((PVar "ctx")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "opCnt")) (EBinOp "+" (EFieldAccess (EFieldAccess (EVar "ctx") "opCnt") "value") (ELit (LInt 1)))))
(DTypeSig false "hmGetC" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyVar "v")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyVar "v"))))))
(DFunDef false "hmGetC" ((PVar "ctx") (PVar "m") (PVar "k")) (EBlock (DoLet false false PWild (EApp (EVar "bump") (EVar "ctx"))) (DoExpr (EApp (EApp (EVar "hmGet") (EVar "k")) (EVar "m")))))
(DTypeSig false "hmSetC" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyVar "v")) (TyFun (TyCon "String") (TyFun (TyVar "v") (TyCon "Unit"))))))
(DFunDef false "hmSetC" ((PVar "ctx") (PVar "m") (PVar "k") (PVar "v")) (EBlock (DoLet false false PWild (EApp (EVar "bump") (EVar "ctx"))) (DoExpr (EApp (EApp (EApp (EVar "hmSet") (EVar "k")) (EVar "v")) (EVar "m")))))
(DTypeSig false "nextFresh" (TyFun (TyCon "Ctx") (TyCon "Int")))
(DFunDef false "nextFresh" ((PVar "ctx")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "fresh")) (EBinOp "+" (EFieldAccess (EFieldAccess (EVar "ctx") "fresh") "value") (ELit (LInt 1))))) (DoExpr (EFieldAccess (EFieldAccess (EVar "ctx") "fresh") "value"))))
(DTypeSig false "withUri" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "Loc"))))
(DFunDef false "withUri" ((PVar "uri") (PCon "Loc" PWild (PVar "a") (PVar "b") (PVar "c") (PVar "d"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "uri")) (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d")))
(DTypeSig false "dummyLoc" (TyFun (TyCon "String") (TyCon "Loc")))
(DFunDef false "dummyLoc" ((PVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "uri")) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "headIsUpper" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "headIsUpper" ((PVar "s")) (EMatch (EApp (EApp (EVar "arrayGet") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s"))) (arm (PCon "Some" (PVar "c")) () (EApp (EVar "isUpper") (EVar "c"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "patBinderNames" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patBinderNames" ((PCon "PVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "patBinderNames" ((PCon "PWild")) (EListLit))
(DFunDef false "patBinderNames" ((PCon "PLit" PWild)) (EListLit))
(DFunDef false "patBinderNames" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBinderNames")) (EVar "ps")))
(DFunDef false "patBinderNames" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patBinderNames") (EVar "a")) (EApp (EVar "patBinderNames") (EVar "b"))))
(DFunDef false "patBinderNames" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBinderNames")) (EVar "ps")))
(DFunDef false "patBinderNames" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBinderNames")) (EVar "ps")))
(DFunDef false "patBinderNames" ((PCon "PAs" (PVar "x") (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patBinderNames") (EVar "p"))))
(DFunDef false "patBinderNames" ((PCon "PRng" PWild PWild PWild)) (EListLit))
(DFunDef false "patBinderNames" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "recFieldBinderNames")) (EVar "fields")))
(DTypeSig false "recFieldBinderNames" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recFieldBinderNames" ((PCon "RecPatField" (PVar "name") (PCon "None"))) (EListLit (EVar "name")))
(DFunDef false "recFieldBinderNames" ((PCon "RecPatField" PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patBinderNames") (EVar "p")))
(DTypeSig false "lookupScope" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "lookupScope" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "lookupScope" ((PVar "ctx") (PVar "n") (PCons (PVar "frame") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "bump") (EVar "ctx"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "assocFind") (EVar "ctx")) (EVar "n")) (EVar "frame")) (arm (PCon "Some" (PVar "k")) () (EApp (EVar "Some") (EVar "k"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "lookupScope") (EVar "ctx")) (EVar "n")) (EVar "rest")))))))
(DTypeSig false "assocFind" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "assocFind" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "assocFind" ((PVar "ctx") (PVar "n") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "bump") (EVar "ctx"))) (DoExpr (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EApp (EVar "assocFind") (EVar "ctx")) (EVar "n")) (EVar "rest"))))))
(DTypeSig false "recordDef" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "Unit"))))))
(DFunDef false "recordDef" ((PVar "ctx") (PVar "key") (PVar "uri") (PVar "loc")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "defs")) (EVar "key")) (ETuple (EVar "uri") (EVar "loc")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushOcc") (EVar "ctx")) (EVar "uri")) (EVar "loc")) (EVar "key")))))
(DTypeSig false "recordRef" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "Unit"))))))
(DFunDef false "recordRef" ((PVar "ctx") (PVar "key") (PVar "uri") (PVar "loc")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "pushRef") (EVar "ctx")) (EVar "key")) (EVar "uri")) (EVar "loc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushOcc") (EVar "ctx")) (EVar "uri")) (EVar "loc")) (EVar "key")))))
(DTypeSig false "pushRef" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "Unit"))))))
(DFunDef false "pushRef" ((PVar "ctx") (PVar "key") (PVar "uri") (PVar "loc")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "refs")) (EVar "key")) (arm (PCon "Some" (PVar "r")) () (EBlock (DoLet false false PWild (EApp (EVar "bump") (EVar "ctx"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EBinOp "::" (ETuple (EVar "uri") (EVar "loc")) (EFieldAccess (EVar "r") "value")))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "refs")) (EVar "key")) (EApp (EVar "Ref") (EListLit (ETuple (EVar "uri") (EVar "loc"))))))))
(DTypeSig false "pushOcc" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "pushOcc" ((PVar "ctx") (PVar "uri") (PVar "loc") (PVar "key")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "occ")) (EVar "uri")) (arm (PCon "Some" (PVar "r")) () (EBlock (DoLet false false PWild (EApp (EVar "bump") (EVar "ctx"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "r")) (EBinOp "::" (ETuple (EVar "loc") (EVar "key")) (EFieldAccess (EVar "r") "value")))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "occ")) (EVar "uri")) (EApp (EVar "Ref") (EListLit (ETuple (EVar "loc") (EVar "key"))))))))
(DTypeSig false "resolveVal" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "resolveVal" ((PCon "W" (PVar "ctx") PWild PWild (PVar "useEnv") PWild) (PVar "scope") (PVar "name")) (EMatch (EApp (EApp (EApp (EVar "lookupScope") (EVar "ctx")) (EVar "name")) (EVar "scope")) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "nsVal") (EVar "sep")) (EVar "name"))) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "nsMethod") (EVar "sep")) (EVar "name"))) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EApp (EApp (EVar "extKey") (EVar "nsVal")) (EVar "name")))))))))
(DTypeSig false "resolveCtor" (TyFun (TyCon "W") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "resolveCtor" ((PCon "W" (PVar "ctx") PWild PWild (PVar "useEnv") PWild) (PVar "name")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "nsCtor") (EVar "sep")) (EVar "name"))) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EApp (EApp (EVar "extKey") (EVar "nsCtor")) (EVar "name")))))
(DTypeSig false "resolveTy" (TyFun (TyCon "W") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "resolveTy" ((PCon "W" (PVar "ctx") PWild PWild (PVar "useEnv") PWild) (PVar "name")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "nsTy") (EVar "sep")) (EVar "name"))) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EApp (EApp (EVar "extKey") (EVar "nsTy")) (EVar "name")))))
(DTypeSig false "resolveField" (TyFun (TyCon "W") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "resolveField" ((PCon "W" (PVar "ctx") PWild PWild (PVar "useEnv") PWild) (PVar "name")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "nsField") (EVar "sep")) (EVar "name"))) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EApp (EApp (EVar "extKey") (EVar "nsField")) (EVar "name")))))
(DTypeSig false "walkExpr" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyCon "Expr") (TyCon "Unit"))))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") PWild (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EApp (EApp (EVar "locWithUriOf") (EVar "w")) (EVar "l"))) (EVar "e")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") PWild (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EApp (EApp (EVar "locWithUriOf") (EVar "w")) (EVar "l"))) (EVar "e")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EVar" (PVar "n"))) (EIf (EApp (EVar "headIsUpper") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "recordRef") (EApp (EVar "ctxOf") (EVar "w"))) (EApp (EApp (EVar "resolveCtor") (EVar "w")) (EVar "n"))) (EApp (EVar "uriOf") (EVar "w"))) (EVar "curLoc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "recordRef") (EApp (EVar "ctxOf") (EVar "w"))) (EApp (EApp (EApp (EVar "resolveVal") (EVar "w")) (EVar "scope")) (EVar "n"))) (EApp (EVar "uriOf") (EVar "w"))) (EVar "curLoc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EApp" (PVar "f") (PVar "x"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "x")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ELam" (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EApp (EDictApp "flatMap") (EVar "patBinderNames")) (EVar "pats")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "curLoc")) (EVar "body")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ELet" PWild (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EVar "patBinderNames") (EVar "pat")))) (DoLet false false (PVar "scope1") (EIf (EVar "isRec") (EBinOp "::" (EVar "frame") (EVar "scope")) (EVar "scope"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope1")) (EVar "curLoc")) (EVar "e1"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "curLoc")) (EVar "e2")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")))) (DoLet false false (PVar "scope1") (EBinOp "::" (EVar "frame") (EVar "scope"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkBinds") (EVar "w")) (EVar "scope1")) (EVar "curLoc")) (EVar "binds"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope1")) (EVar "curLoc")) (EVar "body")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "arms")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "c"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "el")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "b")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "a")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "b")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EFieldAccess" (PVar "e0") (PVar "f") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "walkFieldAccess") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0")) (EVar "f")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ETuple" (PVar "es"))) (EApp (EApp (EApp (EApp (EVar "walkEach") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "es")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EApp (EApp (EVar "walkEach") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "es")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EApp (EApp (EVar "walkEach") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "es")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "hi")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "hi")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "hi")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "i")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "stmts")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EDo" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "stmts")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EApp (EApp (EVar "walkInterp") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "parts")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EGuards" (PVar "arms"))) (EApp (EApp (EApp (EApp (EVar "walkGuardArms") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "arms")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ERecordCreate" (PVar "name") (PVar "fs"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordRef") (EApp (EVar "ctxOf") (EVar "w"))) (EApp (EApp (EVar "resolveCtor") (EVar "w")) (EVar "name"))) (EApp (EVar "uriOf") (EVar "w"))) (EVar "curLoc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "fs")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild)) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "fs")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EVariantUpdate" (PVar "con") (PVar "e0") (PVar "fs"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordRef") (EApp (EVar "ctxOf") (EVar "w"))) (EApp (EApp (EVar "resolveCtor") (EVar "w")) (EVar "con"))) (EApp (EVar "uriOf") (EVar "w"))) (EVar "curLoc"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "fs")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EApp (EApp (EVar "walkKvs") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "kvs")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ESetLit" PWild (PVar "es"))) (EApp (EApp (EApp (EApp (EVar "walkEach") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "es")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "EAsPat" PWild (PVar "e0"))) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "ESection" (PVar "s"))) (EApp (EApp (EApp (EApp (EVar "walkSection") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "s")))
(DFunDef false "walkExpr" (PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "walkFieldAccess" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyCon "Unit")))))))
(DFunDef false "walkFieldAccess" ((PVar "w") (PVar "scope") (PVar "curLoc") (PVar "e0") (PVar "f")) (EMatch (EApp (EApp (EVar "aliasHeadOf") (EVar "w")) (EApp (EVar "peelLoc") (EVar "e0"))) (arm (PCon "Some" (PVar "srcMod")) () (EApp (EApp (EApp (EApp (EVar "recordRef") (EApp (EVar "ctxOf") (EVar "w"))) (EApp (EApp (EApp (EVar "aliasOriginKey") (EVar "w")) (EVar "srcMod")) (EVar "f"))) (EApp (EVar "uriOf") (EVar "w"))) (EVar "curLoc"))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordRef") (EApp (EVar "ctxOf") (EVar "w"))) (EApp (EApp (EVar "resolveField") (EVar "w")) (EVar "f"))) (EApp (EVar "uriOf") (EVar "w"))) (EVar "curLoc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e0")))))))
(DTypeSig false "aliasHeadOf" (TyFun (TyCon "W") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "aliasHeadOf" ((PCon "W" (PVar "ctx") PWild PWild PWild (PVar "aliasM")) (PCon "EVar" (PVar "a"))) (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "aliasM")) (EVar "a")))
(DFunDef false "aliasHeadOf" (PWild PWild) (EVar "None"))
(DTypeSig false "aliasOriginKey" (TyFun (TyCon "W") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "aliasOriginKey" ((PCon "W" (PVar "ctx") PWild PWild PWild PWild) (PVar "srcMod") (PVar "f")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "originOf")) (EApp (EApp (EApp (EVar "mkKey") (EVar "srcMod")) (EVar "nsVal")) (EVar "f"))) (arm (PCon "Some" (PVar "k")) () (EVar "k")) (arm (PCon "None") () (EApp (EApp (EVar "extKey") (EVar "nsVal")) (EVar "f")))))
(DTypeSig false "peelLoc" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "peelLoc" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "peelLoc") (EVar "e")))
(DFunDef false "peelLoc" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "peelLoc") (EVar "e")))
(DFunDef false "peelLoc" ((PVar "e")) (EVar "e"))
(DTypeSig false "walkEach" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Unit"))))))
(DFunDef false "walkEach" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkEach" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PVar "e") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkEach") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkKvs" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))) (TyCon "Unit"))))))
(DFunDef false "walkKvs" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkKvs" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "k"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "v"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkKvs") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkFields" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyCon "Unit"))))))
(DFunDef false "walkFields" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkFields" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "FieldAssign" PWild (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkSection" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyCon "Section") (TyCon "Unit"))))))
(DFunDef false "walkSection" (PWild PWild PWild (PCon "SecBare" PWild)) (ELit LUnit))
(DFunDef false "walkSection" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "SecRight" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e")))
(DFunDef false "walkSection" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCon "SecLeft" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e")))
(DTypeSig false "walkInterp" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "InterpPart")) (TyCon "Unit"))))))
(DFunDef false "walkInterp" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkInterp" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "InterpStr" PWild) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "walkInterp") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))
(DFunDef false "walkInterp" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "InterpExpr" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkInterp") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkStmts" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Unit"))))))
(DFunDef false "walkStmts" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EVar "patBinderNames") (EVar "p")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "curLoc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "DoLet" PWild PWild (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EVar "patBinderNames") (EVar "p")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "curLoc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "DoAssign" PWild (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "DoFieldAssign" PWild PWild (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkArms" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Unit"))))))
(DFunDef false "walkArms" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkArms" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "Arm" (PVar "pat") (PVar "gs") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EVar "patBinderNames") (EVar "pat")))) (DoLet false false (PVar "scope1") (EBinOp "::" (EVar "frame") (EVar "scope"))) (DoLet false false (PVar "scope2") (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EVar "scope1")) (EVar "curLoc")) (EVar "gs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope2")) (EVar "curLoc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkGuardArms" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyCon "Unit"))))))
(DFunDef false "walkGuardArms" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkGuardArms" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "GuardArm" (PVar "gs") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "scope2") (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "gs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope2")) (EVar "curLoc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkGuardArms") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkGuards" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "walkGuards" (PWild (PVar "scope") PWild (PList)) (EVar "scope"))
(DFunDef false "walkGuards" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DFunDef false "walkGuards" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "e"))) (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EVar "patBinderNames") (EVar "p")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkBinds" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Unit"))))))
(DFunDef false "walkBinds" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkBinds" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "LetBind" PWild (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "clauses"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkBinds") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkClauses" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Unit"))))))
(DFunDef false "walkClauses" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkClauses" ((PVar "w") (PVar "scope") (PVar "curLoc") (PCons (PCon "FunClause" (PVar "pats") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "curLoc")) (EApp (EApp (EDictApp "flatMap") (EVar "patBinderNames")) (EVar "pats")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "curLoc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "w")) (EVar "scope")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "walkTy" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyCon "Ty") (TyCon "Unit")))))
(DFunDef false "walkTy" ((PVar "w") PWild (PCon "TyCon" (PVar "name") (PVar "mloc"))) (EMatch (EVar "mloc") (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EApp (EApp (EVar "recordRef") (EApp (EVar "ctxOf") (EVar "w"))) (EApp (EApp (EVar "resolveTy") (EVar "w")) (EVar "name"))) (EApp (EVar "uriOf") (EVar "w"))) (EApp (EApp (EVar "locWithUriOf") (EVar "w")) (EVar "l")))) (arm (PCon "None") () (ELit LUnit))))
(DFunDef false "walkTy" (PWild PWild (PCon "TyVar" PWild)) (ELit LUnit))
(DFunDef false "walkTy" ((PVar "w") (PVar "curLoc") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "b")))))
(DFunDef false "walkTy" ((PVar "w") (PVar "curLoc") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "b")))))
(DFunDef false "walkTy" ((PVar "w") (PVar "curLoc") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EApp (EVar "walkTys") (EVar "w")) (EVar "curLoc")) (EVar "ts")))
(DFunDef false "walkTy" ((PVar "w") (PVar "curLoc") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "t")))
(DFunDef false "walkTy" ((PVar "w") (PVar "curLoc") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "t")))
(DTypeSig false "walkTys" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Unit")))))
(DFunDef false "walkTys" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkTys" ((PVar "w") (PVar "curLoc") (PCons (PVar "t") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "curLoc")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EVar "walkTys") (EVar "w")) (EVar "curLoc")) (EVar "rest")))))
(DTypeSig false "mkNamedFrame" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "mkNamedFrame" (PWild PWild (PList)) (EListLit))
(DFunDef false "mkNamedFrame" ((PVar "w") (PVar "atLoc") (PCons (PVar "n") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "mkOneLocal") (EVar "w")) (EVar "atLoc")) (EVar "n")) (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "atLoc")) (EVar "rest"))))
(DTypeSig false "mkOneLocal" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "mkOneLocal" ((PCon "W" (PVar "ctx") (PVar "mid") (PVar "uri") PWild PWild) (PVar "atLoc") (PVar "name")) (EBlock (DoLet false false (PVar "fid") (EApp (EVar "nextFresh") (EVar "ctx"))) (DoLet false false (PVar "key") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "sep"))) (ELit (LString "local"))) (EApp (EMethodRef "display") (EVar "sep"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "sep"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "fid")))) (ELit (LString "")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordDef") (EVar "ctx")) (EVar "key")) (EVar "uri")) (EApp (EApp (EVar "withUri") (EVar "uri")) (EVar "atLoc")))) (DoExpr (ETuple (EVar "name") (EVar "key")))))
(DTypeSig false "ctxOf" (TyFun (TyCon "W") (TyCon "Ctx")))
(DFunDef false "ctxOf" ((PCon "W" (PVar "ctx") PWild PWild PWild PWild)) (EVar "ctx"))
(DTypeSig false "uriOf" (TyFun (TyCon "W") (TyCon "String")))
(DFunDef false "uriOf" ((PCon "W" PWild PWild (PVar "uri") PWild PWild)) (EVar "uri"))
(DTypeSig false "locWithUriOf" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyCon "Loc"))))
(DFunDef false "locWithUriOf" ((PVar "w") (PVar "l")) (EApp (EApp (EVar "withUri") (EApp (EVar "uriOf") (EVar "w"))) (EVar "l")))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "ppName" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "ppName" ((PCon "PropParam" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "ifName" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifName" ((PCon "IfaceMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DData Private "DefEntry" () ((variant "DefEntry" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Loc") (TyCon "Bool")))) ())
(DTypeSig false "collectDefs" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyApp (TyCon "List") (TyCon "DefEntry"))))))))
(DFunDef false "collectDefs" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "collectDefs" ((PVar "ctx") (PVar "expSet") (PVar "mid") (PVar "uri") (PCons (PTuple (PVar "d") (PVar "p")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "defsOfDecl") (EVar "ctx")) (EVar "expSet")) (EVar "mid")) (EVar "uri")) (EVar "d")) (EApp (EApp (EVar "nameLocOf") (EVar "uri")) (EVar "p"))) (EApp (EApp (EApp (EApp (EApp (EVar "collectDefs") (EVar "ctx")) (EVar "expSet")) (EVar "mid")) (EVar "uri")) (EVar "rest"))))
(DTypeSig false "valuePub" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "valuePub" (PWild PWild (PCon "True") PWild) (EVar "True"))
(DFunDef false "valuePub" ((PVar "ctx") (PVar "expSet") (PCon "False") (PVar "n")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "expSet")) (EVar "n")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "collectExportedValues" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "collectExportedValues" ((PVar "ctx") (PVar "decls")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "hmNew") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "collectExpValGo") (EVar "ctx")) (EVar "s")) (EVar "decls"))) (DoExpr (EVar "s"))))
(DTypeSig false "collectExpValGo" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "collectExpValGo" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "collectExpValGo" ((PVar "ctx") (PVar "s") (PCons (PCon "DTypeSig" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "s")) (EVar "n")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "collectExpValGo") (EVar "ctx")) (EVar "s")) (EVar "rest")))))
(DFunDef false "collectExpValGo" ((PVar "ctx") (PVar "s") (PCons (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "s")) (EVar "n")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "collectExpValGo") (EVar "ctx")) (EVar "s")) (EVar "rest")))))
(DFunDef false "collectExpValGo" ((PVar "ctx") (PVar "s") (PCons (PCon "DExtern" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "s")) (EVar "n")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "collectExpValGo") (EVar "ctx")) (EVar "s")) (EVar "rest")))))
(DFunDef false "collectExpValGo" ((PVar "ctx") (PVar "s") (PCons (PCon "DLetGroup" (PCon "True") (PVar "binds")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "collectLetNames") (EVar "ctx")) (EVar "s")) (EVar "binds"))) (DoExpr (EApp (EApp (EApp (EVar "collectExpValGo") (EVar "ctx")) (EVar "s")) (EVar "rest")))))
(DFunDef false "collectExpValGo" ((PVar "ctx") (PVar "s") (PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EApp (EApp (EVar "collectExpValGo") (EVar "ctx")) (EVar "s")) (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "collectExpValGo" ((PVar "ctx") (PVar "s") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "collectExpValGo") (EVar "ctx")) (EVar "s")) (EVar "rest")))
(DTypeSig false "collectLetNames" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Unit")))))
(DFunDef false "collectLetNames" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "collectLetNames" ((PVar "ctx") (PVar "s") (PCons (PCon "LetBind" (PVar "n") PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "s")) (EVar "n")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "collectLetNames") (EVar "ctx")) (EVar "s")) (EVar "rest")))))
(DTypeSig false "nameLocOf" (TyFun (TyCon "String") (TyFun (TyCon "DeclPos") (TyCon "Loc"))))
(DFunDef false "nameLocOf" ((PVar "uri") (PVar "p")) (EMatch (EApp (EVar "declPosNameLoc") (EVar "p")) (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EVar "withUri") (EVar "uri")) (EVar "l"))) (arm (PCon "None") () (EApp (EVar "dummyLoc") (EVar "uri")))))
(DTypeSig false "defsOfDecl" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyCon "DefEntry")))))))))
(DFunDef false "defsOfDecl" ((PVar "ctx") (PVar "expSet") (PVar "mid") (PVar "uri") (PCon "DFunDef" (PVar "pub") (PVar "n") PWild PWild) (PVar "loc")) (EListLit (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsVal")) (EVar "n")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsVal")) (EVar "n"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EVar "valuePub") (EVar "ctx")) (EVar "expSet")) (EVar "pub")) (EVar "n"))))))
(DFunDef false "defsOfDecl" ((PVar "ctx") (PVar "expSet") (PVar "mid") (PVar "uri") (PCon "DExtern" (PVar "pub") (PVar "n") PWild) (PVar "loc")) (EListLit (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsVal")) (EVar "n")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsVal")) (EVar "n"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EVar "valuePub") (EVar "ctx")) (EVar "expSet")) (EVar "pub")) (EVar "n"))))))
(DFunDef false "defsOfDecl" (PWild PWild PWild PWild (PCon "DTypeSig" PWild PWild PWild) PWild) (EListLit))
(DFunDef false "defsOfDecl" ((PVar "ctx") (PVar "expSet") (PVar "mid") (PVar "uri") (PCon "DLetGroup" (PVar "pub") (PVar "binds")) (PVar "loc")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "letGroupDef") (EVar "ctx")) (EVar "expSet")) (EVar "mid")) (EVar "uri")) (EVar "loc")) (EVar "pub"))) (EVar "binds")))
(DFunDef false "defsOfDecl" ((PVar "ctx") PWild (PVar "mid") (PVar "uri") (PCon "DData" (PVar "vis") (PVar "n") PWild (PVar "variants") PWild) (PVar "loc")) (EBlock (DoLet false false (PVar "tyDef") (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsTy")) (EVar "n")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "n"))) (EVar "loc")) (EApp (EVar "dataIsPub") (EVar "vis"))))) (DoExpr (EBinOp "::" (EVar "tyDef") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EApp (EVar "variantDefs") (EVar "ctx")) (EVar "mid")) (EVar "uri")) (EVar "loc")) (EApp (EVar "ctorsPub") (EVar "vis")))) (EVar "variants"))))))
(DFunDef false "defsOfDecl" ((PVar "ctx") PWild (PVar "mid") (PVar "uri") (PCon "DNewtype" (PVar "pub") (PVar "n") PWild (PVar "con") PWild PWild) (PVar "loc")) (EBlock (DoLet false false (PVar "tyDef") (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsTy")) (EVar "n")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "n"))) (EVar "loc")) (EVar "pub")))) (DoLet false false (PVar "conDef") (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsCtor")) (EVar "con")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsCtor")) (EVar "con"))) (EVar "loc")) (EVar "pub")))) (DoExpr (EListLit (EVar "tyDef") (EVar "conDef")))))
(DFunDef false "defsOfDecl" ((PVar "ctx") PWild (PVar "mid") (PVar "uri") (PCon "DTypeAlias" (PVar "pub") (PVar "n") PWild PWild) (PVar "loc")) (EListLit (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsTy")) (EVar "n")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "n"))) (EVar "loc")) (EVar "pub")))))
(DFunDef false "defsOfDecl" ((PVar "ctx") PWild (PVar "mid") (PVar "uri") (PRec "DInterface" ((rf "pub" None) (rf "name" None) (rf "methods" None)) true) (PVar "loc")) (EBlock (DoLet false false (PVar "ifaceDef") (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsTy")) (EVar "name")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "name"))) (EVar "loc")) (EVar "pub")))) (DoExpr (EBinOp "::" (EVar "ifaceDef") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EApp (EVar "methodDef") (EVar "ctx")) (EVar "mid")) (EVar "uri")) (EVar "loc")) (EVar "pub"))) (EVar "methods"))))))
(DFunDef false "defsOfDecl" (PWild PWild PWild PWild (PRec "DImpl" () true) PWild) (EListLit))
(DFunDef false "defsOfDecl" ((PVar "ctx") (PVar "expSet") (PVar "mid") (PVar "uri") (PCon "DAttrib" PWild (PVar "inner")) (PVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "defsOfDecl") (EVar "ctx")) (EVar "expSet")) (EVar "mid")) (EVar "uri")) (EVar "inner")) (EVar "loc")))
(DFunDef false "defsOfDecl" (PWild PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "letGroupDef" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "Bool") (TyFun (TyCon "LetBind") (TyCon "DefEntry")))))))))
(DFunDef false "letGroupDef" ((PVar "ctx") (PVar "expSet") (PVar "mid") (PVar "uri") (PVar "loc") (PVar "pub") (PCon "LetBind" (PVar "n") PWild)) (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsVal")) (EVar "n")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsVal")) (EVar "n"))) (EVar "loc")) (EApp (EApp (EApp (EApp (EVar "valuePub") (EVar "ctx")) (EVar "expSet")) (EVar "pub")) (EVar "n")))))
(DTypeSig false "variantDefs" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "Bool") (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyCon "DefEntry")))))))))
(DFunDef false "variantDefs" ((PVar "ctx") (PVar "mid") (PVar "uri") (PVar "loc") (PVar "pub") (PCon "Variant" (PVar "cn") (PVar "payload"))) (EBinOp "::" (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsCtor")) (EVar "cn")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsCtor")) (EVar "cn"))) (EVar "loc")) (EVar "pub"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldDefs") (EVar "ctx")) (EVar "mid")) (EVar "uri")) (EVar "loc")) (EVar "pub")) (EVar "payload"))))
(DTypeSig false "fieldDefs" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "Bool") (TyFun (TyCon "ConPayload") (TyApp (TyCon "List") (TyCon "DefEntry")))))))))
(DFunDef false "fieldDefs" (PWild PWild PWild PWild PWild (PCon "ConPos" PWild)) (EListLit))
(DFunDef false "fieldDefs" ((PVar "ctx") (PVar "mid") (PVar "uri") (PVar "loc") (PVar "pub") (PCon "ConNamed" (PVar "fields") PWild)) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EApp (EVar "fieldDef") (EVar "ctx")) (EVar "mid")) (EVar "uri")) (EVar "loc")) (EVar "pub"))) (EVar "fields")))
(DTypeSig false "fieldDef" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "Bool") (TyFun (TyCon "Field") (TyCon "DefEntry"))))))))
(DFunDef false "fieldDef" ((PVar "ctx") (PVar "mid") (PVar "uri") (PVar "loc") (PVar "pub") (PCon "Field" (PVar "fn") PWild)) (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsField")) (EVar "fn")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsField")) (EVar "fn"))) (EVar "loc")) (EVar "pub"))))
(DTypeSig false "methodDef" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "Bool") (TyFun (TyCon "IfaceMethod") (TyCon "DefEntry"))))))))
(DFunDef false "methodDef" ((PVar "ctx") (PVar "mid") (PVar "uri") (PVar "loc") (PVar "pub") (PVar "m")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "ifName") (EVar "m"))) (DoExpr (EApp (EApp (EApp (EVar "emitDef") (EVar "ctx")) (EVar "uri")) (EApp (EApp (EApp (EApp (EApp (EVar "DefEntry") (EVar "nsMethod")) (EVar "n")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsMethod")) (EVar "n"))) (EVar "loc")) (EVar "pub"))))))
(DTypeSig false "emitDef" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "DefEntry") (TyCon "DefEntry")))))
(DFunDef false "emitDef" ((PVar "ctx") (PVar "uri") (PAs "d" (PCon "DefEntry" PWild PWild (PVar "key") (PVar "loc") PWild))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordDef") (EVar "ctx")) (EVar "key")) (EVar "uri")) (EVar "loc"))) (DoExpr (EVar "d"))))
(DTypeSig false "dataIsPub" (TyFun (TyCon "DataVis") (TyCon "Bool")))
(DFunDef false "dataIsPub" ((PCon "VisPrivate")) (EVar "False"))
(DFunDef false "dataIsPub" (PWild) (EVar "True"))
(DTypeSig false "ctorsPub" (TyFun (TyCon "DataVis") (TyCon "Bool")))
(DFunDef false "ctorsPub" ((PCon "VisPublic")) (EVar "True"))
(DFunDef false "ctorsPub" (PWild) (EVar "False"))
(DTypeSig false "walkDecls" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyCon "Unit"))))
(DFunDef false "walkDecls" (PWild (PList)) (ELit LUnit))
(DFunDef false "walkDecls" ((PVar "w") (PCons (PTuple (PVar "d") (PVar "p")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkDeclBody") (EVar "w")) (EVar "d")) (EApp (EApp (EVar "nameLocOf") (EApp (EVar "uriOf") (EVar "w"))) (EVar "p")))) (DoExpr (EApp (EApp (EVar "walkDecls") (EVar "w")) (EVar "rest")))))
(DTypeSig false "walkDeclBody" (TyFun (TyCon "W") (TyFun (TyCon "Decl") (TyFun (TyCon "Loc") (TyCon "Unit")))))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DFunDef" PWild PWild (PVar "pats") (PVar "body")) (PVar "loc")) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "loc")) (EApp (EApp (EDictApp "flatMap") (EVar "patBinderNames")) (EVar "pats")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EListLit (EVar "frame"))) (EVar "loc")) (EVar "body")))))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DTypeSig" PWild PWild (PVar "ty")) (PVar "loc")) (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "loc")) (EVar "ty")))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DExtern" PWild PWild (PVar "ty")) (PVar "loc")) (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "loc")) (EVar "ty")))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DData" PWild PWild PWild (PVar "variants") PWild) (PVar "loc")) (EApp (EApp (EApp (EVar "walkVariants") (EVar "w")) (EVar "loc")) (EVar "variants")))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DNewtype" PWild PWild PWild PWild (PVar "fieldTy") PWild) (PVar "loc")) (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "loc")) (EVar "fieldTy")))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DTypeAlias" PWild PWild PWild (PVar "rhs")) (PVar "loc")) (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "loc")) (EVar "rhs")))
(DFunDef false "walkDeclBody" ((PVar "w") (PRec "DInterface" ((rf "methods" None)) true) (PVar "loc")) (EApp (EApp (EApp (EVar "walkIfaceMethods") (EVar "w")) (EVar "loc")) (EVar "methods")))
(DFunDef false "walkDeclBody" ((PVar "w") (PRec "DImpl" ((rf "tys" None) (rf "methods" None)) true) (PVar "loc")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTys") (EVar "w")) (EVar "loc")) (EVar "tys"))) (DoExpr (EApp (EApp (EApp (EVar "walkImplMethods") (EVar "w")) (EVar "loc")) (EVar "methods")))))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DProp" PWild PWild (PVar "params") (PVar "body")) (PVar "loc")) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "loc")) (EApp (EApp (EMethodRef "map") (EVar "ppName")) (EVar "params")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EListLit (EVar "frame"))) (EVar "loc")) (EVar "body")))))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DTest" PWild PWild (PVar "body")) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EListLit)) (EVar "loc")) (EVar "body")))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DBench" PWild PWild (PVar "body")) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EListLit)) (EVar "loc")) (EVar "body")))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DLetGroup" PWild (PVar "binds")) (PVar "loc")) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "loc")) (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkBinds") (EVar "w")) (EListLit (EVar "frame"))) (EVar "loc")) (EVar "binds")))))
(DFunDef false "walkDeclBody" ((PVar "w") (PCon "DAttrib" PWild (PVar "inner")) (PVar "loc")) (EApp (EApp (EApp (EVar "walkDeclBody") (EVar "w")) (EVar "inner")) (EVar "loc")))
(DFunDef false "walkDeclBody" (PWild PWild PWild) (ELit LUnit))
(DTypeSig false "walkVariants" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyCon "Unit")))))
(DFunDef false "walkVariants" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkVariants" ((PVar "w") (PVar "loc") (PCons (PCon "Variant" PWild (PVar "payload")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkPayload") (EVar "w")) (EVar "loc")) (EVar "payload"))) (DoExpr (EApp (EApp (EApp (EVar "walkVariants") (EVar "w")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkPayload" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyCon "ConPayload") (TyCon "Unit")))))
(DFunDef false "walkPayload" ((PVar "w") (PVar "loc") (PCon "ConPos" (PVar "tys"))) (EApp (EApp (EApp (EVar "walkTys") (EVar "w")) (EVar "loc")) (EVar "tys")))
(DFunDef false "walkPayload" ((PVar "w") (PVar "loc") (PCon "ConNamed" (PVar "fields") PWild)) (EApp (EApp (EApp (EVar "walkFieldTys") (EVar "w")) (EVar "loc")) (EVar "fields")))
(DTypeSig false "walkFieldTys" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyCon "Unit")))))
(DFunDef false "walkFieldTys" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkFieldTys" ((PVar "w") (PVar "loc") (PCons (PCon "Field" PWild (PVar "ty")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "loc")) (EVar "ty"))) (DoExpr (EApp (EApp (EApp (EVar "walkFieldTys") (EVar "w")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkIfaceMethods" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyCon "Unit")))))
(DFunDef false "walkIfaceMethods" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkIfaceMethods" ((PVar "w") (PVar "loc") (PCons (PCon "IfaceMethod" PWild (PVar "ty") (PVar "mdef")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkTy") (EVar "w")) (EVar "loc")) (EVar "ty"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "walkMethodDefault") (EVar "w")) (EVar "loc")) (EVar "mdef"))) (DoExpr (EApp (EApp (EApp (EVar "walkIfaceMethods") (EVar "w")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkMethodDefault" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "Option") (TyCon "MethodDefault")) (TyCon "Unit")))))
(DFunDef false "walkMethodDefault" (PWild PWild (PCon "None")) (ELit LUnit))
(DFunDef false "walkMethodDefault" ((PVar "w") (PVar "loc") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body")))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "loc")) (EApp (EApp (EDictApp "flatMap") (EVar "patBinderNames")) (EVar "pats")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EListLit (EVar "frame"))) (EVar "loc")) (EVar "body")))))
(DTypeSig false "walkImplMethods" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "Unit")))))
(DFunDef false "walkImplMethods" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkImplMethods" ((PVar "w") (PVar "loc") (PCons (PCon "ImplMethod" PWild (PVar "pats") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EApp (EVar "mkNamedFrame") (EVar "w")) (EVar "loc")) (EApp (EApp (EDictApp "flatMap") (EVar "patBinderNames")) (EVar "pats")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EListLit (EVar "frame"))) (EVar "loc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EVar "walkImplMethods") (EVar "w")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "addOwnToEnv" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DefEntry")) (TyCon "Unit")))))
(DFunDef false "addOwnToEnv" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "addOwnToEnv" ((PVar "ctx") (PVar "useEnv") (PCons (PCon "DefEntry" (PVar "ns") (PVar "name") (PVar "key") PWild PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "ns") (EVar "sep")) (EVar "name"))) (EVar "key"))) (DoExpr (EApp (EApp (EApp (EVar "addOwnToEnv") (EVar "ctx")) (EVar "useEnv")) (EVar "rest")))))
(DTypeSig false "registerExports" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DefEntry")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))))
(DFunDef false "registerExports" ((PVar "ctx") (PVar "mid") (PVar "ownDefs") (PVar "decls")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "registerOwnExports") (EVar "ctx")) (EVar "mid")) (EVar "ownDefs"))) (DoExpr (EApp (EApp (EApp (EVar "registerReExports") (EVar "ctx")) (EVar "mid")) (EVar "decls")))))
(DTypeSig false "registerOwnExports" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "DefEntry")) (TyCon "Unit")))))
(DFunDef false "registerOwnExports" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "registerOwnExports" ((PVar "ctx") (PVar "mid") (PCons (PCon "DefEntry" (PVar "ns") (PVar "name") (PVar "key") PWild (PVar "pub")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "whenPub") (EVar "ctx")) (EVar "mid")) (EVar "ns")) (EVar "name")) (EVar "key")) (EVar "pub"))) (DoExpr (EApp (EApp (EApp (EVar "registerOwnExports") (EVar "ctx")) (EVar "mid")) (EVar "rest")))))
(DTypeSig false "whenPub" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "Unit"))))))))
(DFunDef false "whenPub" (PWild PWild PWild PWild PWild (PCon "False")) (ELit LUnit))
(DFunDef false "whenPub" ((PVar "ctx") (PVar "mid") (PVar "ns") (PVar "name") (PVar "key") (PCon "True")) (EApp (EApp (EApp (EApp (EApp (EVar "addExport") (EVar "ctx")) (EVar "mid")) (EVar "ns")) (EVar "name")) (EVar "key")))
(DTypeSig false "addExport" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))))
(DFunDef false "addExport" ((PVar "ctx") (PVar "mid") (PVar "ns") (PVar "name") (PVar "originKey")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "originOf")) (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "ns")) (EVar "name"))) (EVar "originKey"))) (DoLet false false (PVar "cur") (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "modExp")) (EVar "mid")) (arm (PCon "Some" (PVar "l")) () (EVar "l")) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "modExp")) (EVar "mid")) (EBinOp "::" (ETuple (EVar "ns") (EVar "name") (EVar "originKey")) (EVar "cur"))))))
(DTypeSig false "registerReExports" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "registerReExports" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "registerReExports" ((PVar "ctx") (PVar "mid") (PCons (PCon "DUse" (PCon "True") (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "reExportPath") (EVar "ctx")) (EVar "mid")) (EVar "path"))) (DoExpr (EApp (EApp (EApp (EVar "registerReExports") (EVar "ctx")) (EVar "mid")) (EVar "rest")))))
(DFunDef false "registerReExports" ((PVar "ctx") (PVar "mid") (PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EApp (EApp (EVar "registerReExports") (EVar "ctx")) (EVar "mid")) (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "registerReExports" ((PVar "ctx") (PVar "mid") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "registerReExports") (EVar "ctx")) (EVar "mid")) (EVar "rest")))
(DTypeSig false "reExportPath" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyCon "Unit")))))
(DFunDef false "reExportPath" ((PVar "ctx") (PVar "mid") (PCon "UseName" (PVar "ns"))) (EApp (EApp (EApp (EVar "reExportName") (EVar "ctx")) (EVar "mid")) (EVar "ns")))
(DFunDef false "reExportPath" ((PVar "ctx") (PVar "mid") (PCon "UseGroup" (PVar "srcPath") (PVar "members"))) (EApp (EApp (EApp (EApp (EVar "reExportMembers") (EVar "ctx")) (EVar "mid")) (EApp (EVar "joinDotL") (EVar "srcPath"))) (EVar "members")))
(DFunDef false "reExportPath" ((PVar "ctx") (PVar "mid") (PCon "UseWild" (PVar "srcPath"))) (EApp (EApp (EApp (EVar "reExportWild") (EVar "ctx")) (EVar "mid")) (EApp (EVar "joinDotL") (EVar "srcPath"))))
(DFunDef false "reExportPath" (PWild PWild (PCon "UseAlias" PWild PWild)) (ELit LUnit))
(DTypeSig false "reExportName" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "reExportName" ((PVar "ctx") (PVar "mid") (PVar "ns")) (EMatch (EApp (EVar "splitLastL") (EVar "ns")) (arm (PCon "Some" (PTuple (PVar "pre") (PVar "nm"))) () (EApp (EApp (EApp (EApp (EApp (EVar "reExportOne") (EVar "ctx")) (EVar "mid")) (EApp (EVar "joinDotL") (EVar "pre"))) (EVar "nm")) (EVar "nm"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "reExportMembers" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "UseMember")) (TyCon "Unit"))))))
(DFunDef false "reExportMembers" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "reExportMembers" ((PVar "ctx") (PVar "mid") (PVar "srcMod") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "reExportOne") (EVar "ctx")) (EVar "mid")) (EVar "srcMod")) (EApp (EVar "useMemberOrigin") (EVar "m"))) (EApp (EVar "useMemberLocal") (EVar "m")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "reExportMembers") (EVar "ctx")) (EVar "mid")) (EVar "srcMod")) (EVar "rest")))))
(DTypeSig false "reExportOne" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))))
(DFunDef false "reExportOne" ((PVar "ctx") (PVar "mid") (PVar "srcMod") (PVar "o") (PVar "l")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reExportNs") (EVar "ctx")) (EVar "mid")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsVal"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reExportNs") (EVar "ctx")) (EVar "mid")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsTy"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reExportNs") (EVar "ctx")) (EVar "mid")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsCtor"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reExportNs") (EVar "ctx")) (EVar "mid")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsMethod")))))
(DTypeSig false "reExportNs" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit"))))))))
(DFunDef false "reExportNs" ((PVar "ctx") (PVar "mid") (PVar "srcMod") (PVar "o") (PVar "l") (PVar "ns")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "originOf")) (EApp (EApp (EApp (EVar "mkKey") (EVar "srcMod")) (EVar "ns")) (EVar "o"))) (arm (PCon "Some" (PVar "originKey")) () (EApp (EApp (EApp (EApp (EApp (EVar "addExport") (EVar "ctx")) (EVar "mid")) (EVar "ns")) (EVar "l")) (EVar "originKey"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "reExportWild" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "reExportWild" ((PVar "ctx") (PVar "mid") (PVar "srcMod")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "modExp")) (EVar "srcMod")) (arm (PCon "Some" (PVar "entries")) () (EApp (EApp (EApp (EVar "reExportWildGo") (EVar "ctx")) (EVar "mid")) (EVar "entries"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "reExportWildGo" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "reExportWildGo" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "reExportWildGo" ((PVar "ctx") (PVar "mid") (PCons (PTuple (PVar "ns") (PVar "name") (PVar "originKey")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "addExport") (EVar "ctx")) (EVar "mid")) (EVar "ns")) (EVar "name")) (EVar "originKey"))) (DoExpr (EApp (EApp (EApp (EVar "reExportWildGo") (EVar "ctx")) (EVar "mid")) (EVar "rest")))))
(DTypeSig false "processImports" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))))
(DFunDef false "processImports" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "processImports" ((PVar "ctx") (PVar "useEnv") (PVar "aliasM") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "importPath") (EVar "ctx")) (EVar "useEnv")) (EVar "aliasM")) (EVar "path"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "processImports") (EVar "ctx")) (EVar "useEnv")) (EVar "aliasM")) (EVar "rest")))))
(DFunDef false "processImports" ((PVar "ctx") (PVar "useEnv") (PVar "aliasM") (PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "processImports") (EVar "ctx")) (EVar "useEnv")) (EVar "aliasM")) (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "processImports" ((PVar "ctx") (PVar "useEnv") (PVar "aliasM") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "processImports") (EVar "ctx")) (EVar "useEnv")) (EVar "aliasM")) (EVar "rest")))
(DTypeSig false "importPath" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyCon "UsePath") (TyCon "Unit"))))))
(DFunDef false "importPath" ((PVar "ctx") (PVar "useEnv") PWild (PCon "UseName" (PVar "ns"))) (EMatch (EApp (EVar "splitLastL") (EVar "ns")) (arm (PCon "Some" (PTuple (PVar "pre") (PVar "nm"))) () (EApp (EApp (EApp (EApp (EApp (EVar "importOne") (EVar "ctx")) (EVar "useEnv")) (EApp (EVar "joinDotL") (EVar "pre"))) (EVar "nm")) (EVar "nm"))) (arm (PCon "None") () (ELit LUnit))))
(DFunDef false "importPath" ((PVar "ctx") (PVar "useEnv") PWild (PCon "UseGroup" (PVar "srcPath") (PVar "members"))) (EApp (EApp (EApp (EApp (EVar "importMembers") (EVar "ctx")) (EVar "useEnv")) (EApp (EVar "joinDotL") (EVar "srcPath"))) (EVar "members")))
(DFunDef false "importPath" ((PVar "ctx") (PVar "useEnv") PWild (PCon "UseWild" (PVar "srcPath"))) (EApp (EApp (EApp (EVar "importWild") (EVar "ctx")) (EVar "useEnv")) (EApp (EVar "joinDotL") (EVar "srcPath"))))
(DFunDef false "importPath" ((PVar "ctx") PWild (PVar "aliasM") (PCon "UseAlias" (PVar "srcPath") (PVar "alias"))) (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "aliasM")) (EVar "alias")) (EApp (EVar "joinDotL") (EVar "srcPath"))))
(DTypeSig false "importMembers" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "UseMember")) (TyCon "Unit"))))))
(DFunDef false "importMembers" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "importMembers" ((PVar "ctx") (PVar "useEnv") (PVar "srcMod") (PCons (PVar "m") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "importOne") (EVar "ctx")) (EVar "useEnv")) (EVar "srcMod")) (EApp (EVar "useMemberOrigin") (EVar "m"))) (EApp (EVar "useMemberLocal") (EVar "m")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "importMembers") (EVar "ctx")) (EVar "useEnv")) (EVar "srcMod")) (EVar "rest")))))
(DTypeSig false "importOne" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))))
(DFunDef false "importOne" ((PVar "ctx") (PVar "useEnv") (PVar "srcMod") (PVar "o") (PVar "l")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "importNs") (EVar "ctx")) (EVar "useEnv")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsVal"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "importNs") (EVar "ctx")) (EVar "useEnv")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsTy"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "importNs") (EVar "ctx")) (EVar "useEnv")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsCtor"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "importNs") (EVar "ctx")) (EVar "useEnv")) (EVar "srcMod")) (EVar "o")) (EVar "l")) (EVar "nsMethod")))))
(DTypeSig false "importNs" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit"))))))))
(DFunDef false "importNs" ((PVar "ctx") (PVar "useEnv") (PVar "srcMod") (PVar "o") (PVar "l") (PVar "ns")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "originOf")) (EApp (EApp (EApp (EVar "mkKey") (EVar "srcMod")) (EVar "ns")) (EVar "o"))) (arm (PCon "Some" (PVar "originKey")) () (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "ns") (EVar "sep")) (EVar "l"))) (EVar "originKey"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "importWild" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "importWild" ((PVar "ctx") (PVar "useEnv") (PVar "srcMod")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EFieldAccess (EVar "ctx") "modExp")) (EVar "srcMod")) (arm (PCon "Some" (PVar "entries")) () (EApp (EApp (EApp (EVar "importWildGo") (EVar "ctx")) (EVar "useEnv")) (EVar "entries"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig false "importWildGo" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "importWildGo" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "importWildGo" ((PVar "ctx") (PVar "useEnv") (PCons (PTuple (PVar "ns") (PVar "name") (PVar "originKey")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "useEnv")) (EBinOp "++" (EBinOp "++" (EVar "ns") (EVar "sep")) (EVar "name"))) (EVar "originKey"))) (DoExpr (EApp (EApp (EApp (EVar "importWildGo") (EVar "ctx")) (EVar "useEnv")) (EVar "rest")))))
(DTypeSig false "seedPrelude" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "seedPrelude" ((PVar "ctx") (PVar "mid") (PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PTuple (PVar "decls") PWild)) () (EBlock (DoLet false false (PVar "expSet") (EApp (EApp (EVar "collectExportedValues") (EVar "ctx")) (EVar "decls"))) (DoExpr (EApp (EApp (EApp (EVar "seedPreludeGo") (EVar "ctx")) (EVar "mid")) (EApp (EApp (EApp (EVar "preludeDefEntries") (EVar "expSet")) (EVar "mid")) (EVar "decls"))))))))
(DTypeSig false "preludeDefEntries" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))))
(DFunDef false "preludeDefEntries" (PWild PWild (PList)) (EListLit))
(DFunDef false "preludeDefEntries" ((PVar "expSet") (PVar "mid") (PCons (PVar "d") (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EVar "preludeDefsOfDecl") (EVar "expSet")) (EVar "mid")) (EVar "d")) (EApp (EApp (EApp (EVar "preludeDefEntries") (EVar "expSet")) (EVar "mid")) (EVar "rest"))))
(DTypeSig false "preludeDefsOfDecl" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))))
(DFunDef false "preludeDefsOfDecl" ((PVar "expSet") (PVar "mid") (PCon "DFunDef" (PVar "pub") (PVar "n") PWild PWild)) (EApp (EApp (EApp (EApp (EVar "valEntry") (EVar "expSet")) (EVar "mid")) (EVar "pub")) (EVar "n")))
(DFunDef false "preludeDefsOfDecl" ((PVar "expSet") (PVar "mid") (PCon "DExtern" (PVar "pub") (PVar "n") PWild)) (EApp (EApp (EApp (EApp (EVar "valEntry") (EVar "expSet")) (EVar "mid")) (EVar "pub")) (EVar "n")))
(DFunDef false "preludeDefsOfDecl" (PWild (PVar "mid") (PCon "DData" (PVar "vis") (PVar "n") PWild (PVar "variants") PWild)) (EApp (EApp (EApp (EVar "consIf") (EApp (EVar "dataIsPub") (EVar "vis"))) (ETuple (EVar "nsTy") (EVar "n") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "n")))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "preludeVariant") (EVar "mid"))) (EVar "variants"))))
(DFunDef false "preludeDefsOfDecl" (PWild (PVar "mid") (PCon "DNewtype" (PCon "True") (PVar "n") PWild (PVar "con") PWild PWild)) (EListLit (ETuple (EVar "nsTy") (EVar "n") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "n"))) (ETuple (EVar "nsCtor") (EVar "con") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsCtor")) (EVar "con")))))
(DFunDef false "preludeDefsOfDecl" (PWild (PVar "mid") (PCon "DTypeAlias" (PCon "True") (PVar "n") PWild PWild)) (EListLit (ETuple (EVar "nsTy") (EVar "n") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "n")))))
(DFunDef false "preludeDefsOfDecl" (PWild (PVar "mid") (PRec "DInterface" ((rf "pub" None) (rf "name" None) (rf "methods" None)) true)) (EApp (EApp (EApp (EVar "consIf") (EVar "pub")) (ETuple (EVar "nsTy") (EVar "name") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsTy")) (EVar "name")))) (EApp (EApp (EMethodRef "map") (EApp (EVar "preludeMethod") (EVar "mid"))) (EVar "methods"))))
(DFunDef false "preludeDefsOfDecl" ((PVar "expSet") (PVar "mid") (PCon "DAttrib" PWild (PVar "inner"))) (EApp (EApp (EApp (EVar "preludeDefsOfDecl") (EVar "expSet")) (EVar "mid")) (EVar "inner")))
(DFunDef false "preludeDefsOfDecl" (PWild PWild PWild) (EListLit))
(DTypeSig false "valEntry" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))))))))
(DFunDef false "valEntry" ((PVar "expSet") (PVar "mid") (PVar "pub") (PVar "n")) (EIf (EBinOp "||" (EVar "pub") (EApp (EApp (EVar "memberOfRaw") (EVar "expSet")) (EVar "n"))) (EListLit (ETuple (EVar "nsVal") (EVar "n") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsVal")) (EVar "n")))) (EListLit)))
(DTypeSig false "memberOfRaw" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "memberOfRaw" ((PVar "s") (PVar "k")) (EMatch (EApp (EApp (EVar "hmGet") (EVar "k")) (EVar "s")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "preludeVariant" (TyFun (TyCon "String") (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))))))
(DFunDef false "preludeVariant" ((PVar "mid") (PCon "Variant" (PVar "cn") PWild)) (EListLit (ETuple (EVar "nsCtor") (EVar "cn") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsCtor")) (EVar "cn")))))
(DTypeSig false "preludeMethod" (TyFun (TyCon "String") (TyFun (TyCon "IfaceMethod") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "preludeMethod" ((PVar "mid") (PVar "m")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "ifName") (EVar "m"))) (DoExpr (ETuple (EVar "nsMethod") (EVar "n") (EApp (EApp (EApp (EVar "mkKey") (EVar "mid")) (EVar "nsMethod")) (EVar "n"))))))
(DTypeSig false "consIf" (TyFun (TyCon "Bool") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "consIf" ((PCon "False") PWild (PVar "xs")) (EVar "xs"))
(DFunDef false "consIf" ((PCon "True") (PVar "x") (PVar "xs")) (EBinOp "::" (EVar "x") (EVar "xs")))
(DTypeSig false "seedPreludeGo" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "seedPreludeGo" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "seedPreludeGo" ((PVar "ctx") (PVar "mid") (PCons (PTuple (PVar "ns") (PVar "name") (PVar "originKey")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "addExport") (EVar "ctx")) (EVar "mid")) (EVar "ns")) (EVar "name")) (EVar "originKey"))) (DoExpr (EApp (EApp (EApp (EVar "seedPreludeGo") (EVar "ctx")) (EVar "mid")) (EVar "rest")))))
(DTypeSig false "seedUseEnvPrelude" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "seedUseEnvPrelude" ((PVar "ctx") (PVar "useEnv")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "importWild") (EVar "ctx")) (EVar "useEnv")) (ELit (LString "core")))) (DoExpr (EApp (EApp (EApp (EVar "importWild") (EVar "ctx")) (EVar "useEnv")) (ELit (LString "runtime"))))))
(DTypeSig false "indexModule" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "indexModule" ((PVar "ctx") (PVar "mid") (PVar "uri") (PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EBlock (DoLet false false (PVar "paired") (EApp (EApp (EVar "zipL") (EVar "decls")) (EApp (EVar "positionsDecls") (EVar "positions")))) (DoLet false false (PVar "expSet") (EApp (EApp (EVar "collectExportedValues") (EVar "ctx")) (EVar "decls"))) (DoLet false false (PVar "ownDefs") (EApp (EApp (EApp (EApp (EApp (EVar "collectDefs") (EVar "ctx")) (EVar "expSet")) (EVar "mid")) (EVar "uri")) (EVar "paired"))) (DoLet false false (PVar "useEnv") (EApp (EVar "hmNew") (ELit LUnit))) (DoLet false false (PVar "aliasM") (EApp (EVar "hmNew") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "seedUseEnvPrelude") (EVar "ctx")) (EVar "useEnv"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "addOwnToEnv") (EVar "ctx")) (EVar "useEnv")) (EVar "ownDefs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "processImports") (EVar "ctx")) (EVar "useEnv")) (EVar "aliasM")) (EVar "decls"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "registerExports") (EVar "ctx")) (EVar "mid")) (EVar "ownDefs")) (EVar "decls"))) (DoExpr (EApp (EApp (EVar "walkDecls") (EApp (EApp (EApp (EApp (EApp (EVar "W") (EVar "ctx")) (EVar "mid")) (EVar "uri")) (EVar "useEnv")) (EVar "aliasM"))) (EVar "paired")))))))
(DTypeSig false "processModules" (TyFun (TyCon "Ctx") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "processModules" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "processModules" ((PVar "ctx") (PVar "read") (PCons (PTuple (PVar "mid") (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EMatch (EApp (EApp (EVar "getSrc") (EVar "read")) (EVar "path")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EApp (EApp (EVar "indexModule") (EVar "ctx")) (EVar "mid")) (EVar "path")) (EVar "src"))))) (DoExpr (EApp (EApp (EApp (EVar "processModules") (EVar "ctx")) (EVar "read")) (EVar "rest")))))
(DTypeSig false "getSrc" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "getSrc" ((PVar "read") (PVar "path")) (EMatch (EApp (EVar "read") (EVar "path")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Ok" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "Err" PWild) () (EVar "None"))))))
(DTypeSig false "newCtx" (TyFun (TyCon "Unit") (TyCon "Ctx")))
(DFunDef false "newCtx" (PWild) (ERecordCreate "Ctx" ((fa "defs" (EApp (EVar "hmNew") (ELit LUnit))) (fa "refs" (EApp (EVar "hmNew") (ELit LUnit))) (fa "occ" (EApp (EVar "hmNew") (ELit LUnit))) (fa "originOf" (EApp (EVar "hmNew") (ELit LUnit))) (fa "modExp" (EApp (EVar "hmNew") (ELit LUnit))) (fa "opCnt" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "fresh" (EApp (EVar "Ref") (ELit (LInt 0)))))))
(DTypeSig false "emptyIndex" (TyFun (TyCon "Unit") (TyCon "RefIndex")))
(DFunDef false "emptyIndex" (PWild) (ERecordCreate "RefIndex" ((fa "defs" (EApp (EVar "hmNew") (ELit LUnit))) (fa "refs" (EApp (EVar "hmNew") (ELit LUnit))) (fa "occ" (EApp (EVar "hmNew") (ELit LUnit))) (fa "ops" (ELit (LInt 0))))))
(DTypeSig true "buildRefIndex" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "RefIndex"))))))))
(DFunDef false "buildRefIndex" ((PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "parseCache") (EApp (EVar "Ref") (EListLit))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "loadProgramFilesLocatedCached") (EVar "parseCache")) (EVar "read")) (EVar "entry")) (EVar "roots")) (arm (PCon "Err" PWild) () (EApp (EVar "emptyIndex") (ELit LUnit))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "newCtx") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "seedPrelude") (EVar "ctx")) (ELit (LString "runtime"))) (EVar "runtimeSrc"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "seedPrelude") (EVar "ctx")) (ELit (LString "core"))) (EVar "coreSrc"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "opCnt")) (ELit (LInt 0)))) (DoLet false false PWild (EApp (EApp (EApp (EVar "processModules") (EVar "ctx")) (EVar "read")) (EVar "mods"))) (DoExpr (ERecordCreate "RefIndex" ((fa "defs" (EFieldAccess (EVar "ctx") "defs")) (fa "refs" (EFieldAccess (EVar "ctx") "refs")) (fa "occ" (EFieldAccess (EVar "ctx") "occ")) (fa "ops" (EFieldAccess (EFieldAccess (EVar "ctx") "opCnt") "value")))))))))))
(DTypeSig true "buildRefIndexDisk" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "RefIndex")))))))
(DFunDef false "buildRefIndexDisk" ((PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EApp (EApp (EApp (EApp (EApp (EVar "buildRefIndex") (EVar "noOverride")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")))
(DTypeSig false "noOverride" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "noOverride" (PWild) (EVar "None"))
(DTypeSig false "enumerateMdkFiles" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "enumerateMdkFiles" ((PVar "root")) (EBlock (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "enumerateDir") (EVar "acc")) (EVar "root"))) (DoExpr (EApp (EVar "reverseList") (EFieldAccess (EVar "acc") "value")))))
(DTypeSig false "enumerateDir" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "enumerateDir" ((PVar "acc") (PVar "dir")) (EMatch (EApp (EVar "listDir") (EVar "dir")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" (PVar "entries")) () (EApp (EApp (EApp (EVar "enumerateEntries") (EVar "acc")) (EVar "dir")) (EApp (EVar "dropDotEntries") (EVar "entries"))))))
(DTypeSig false "enumerateEntries" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "enumerateEntries" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "enumerateEntries" ((PVar "acc") (PVar "dir") (PCons (PVar "name") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "enumerateOne") (EVar "acc")) (EVar "dir")) (EVar "name"))) (DoExpr (EApp (EApp (EApp (EVar "enumerateEntries") (EVar "acc")) (EVar "dir")) (EVar "rest")))))
(DTypeSig false "enumerateOne" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "enumerateOne" ((PVar "acc") (PVar "dir") (PVar "name")) (EBlock (DoLet false false (PVar "full") (EApp (EApp (EVar "joinPath") (EVar "dir")) (EVar "name"))) (DoExpr (EMatch (EApp (EVar "listDir") (EVar "full")) (arm (PCon "Ok" PWild) () (EApp (EApp (EVar "enumerateDir") (EVar "acc")) (EVar "full"))) (arm (PCon "Err" PWild) () (EIf (EApp (EApp (EVar "endsWith") (ELit (LString ".mdk"))) (EVar "name")) (EApp (EApp (EVar "setRef") (EVar "acc")) (EBinOp "::" (EVar "full") (EFieldAccess (EVar "acc") "value"))) (ELit LUnit)))))))
(DTypeSig false "dropDotEntries" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropDotEntries" ((PList)) (EListLit))
(DFunDef false "dropDotEntries" ((PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "."))) (EVar "n")) (EApp (EVar "dropDotEntries") (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "n") (EApp (EVar "dropDotEntries") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "midPathsOf" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "midPathsOf" ((PVar "root")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "path")) (ETuple (EApp (EApp (EVar "moduleIdOfPath") (EListLit (EVar "root"))) (EVar "path")) (EVar "path")))) (EApp (EVar "enumerateMdkFiles") (EVar "root"))))
(DTypeSig false "directImportIds" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "directImportIds" ((PList)) (EListLit))
(DFunDef false "directImportIds" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "m") (EApp (EVar "importModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "m") (ELit (LString "core"))) (EApp (EVar "directImportIds") (EVar "rest")) (EBinOp "::" (EVar "m") (EApp (EVar "directImportIds") (EVar "rest")))))))
(DFunDef false "directImportIds" ((PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EVar "directImportIds") (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "directImportIds" ((PCons PWild (PVar "rest"))) (EApp (EVar "directImportIds") (EVar "rest")))
(DTypeSig false "registerMidPaths" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "registerMidPaths" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "registerMidPaths" ((PVar "ctx") (PVar "byMid") (PCons (PTuple (PVar "mid") (PVar "path")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "byMid")) (EVar "mid")) (EVar "path"))) (DoExpr (EApp (EApp (EApp (EVar "registerMidPaths") (EVar "ctx")) (EVar "byMid")) (EVar "rest")))))
(DTypeSig false "midsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "midsOf" ((PList)) (EListLit))
(DFunDef false "midsOf" ((PCons (PTuple (PVar "mid") PWild) (PVar "rest"))) (EBinOp "::" (EVar "mid") (EApp (EVar "midsOf") (EVar "rest"))))
(DTypeSig false "topoVisitAll" (TyFun (TyCon "Ctx") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "topoVisitAll" (PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "topoVisitAll" ((PVar "ctx") (PVar "read") (PVar "byMid") (PVar "visited") (PVar "acc") (PCons (PVar "mid") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "topoVisit") (EVar "ctx")) (EVar "read")) (EVar "byMid")) (EVar "visited")) (EVar "acc")) (EVar "mid"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "topoVisitAll") (EVar "ctx")) (EVar "read")) (EVar "byMid")) (EVar "visited")) (EVar "acc")) (EVar "rest")))))
(DTypeSig false "topoVisit" (TyFun (TyCon "Ctx") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))))))
(DFunDef false "topoVisit" ((PVar "ctx") (PVar "read") (PVar "byMid") (PVar "visited") (PVar "acc") (PVar "mid")) (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "visited")) (EVar "mid")) (arm (PCon "Some" PWild) () (ELit LUnit)) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "hmGetC") (EVar "ctx")) (EVar "byMid")) (EVar "mid")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "path")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "hmSetC") (EVar "ctx")) (EVar "visited")) (EVar "mid")) (ELit LUnit))) (DoExpr (EMatch (EApp (EApp (EVar "getSrc") (EVar "read")) (EVar "path")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "src")) () (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PTuple (PVar "decls") PWild)) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "topoVisitAll") (EVar "ctx")) (EVar "read")) (EVar "byMid")) (EVar "visited")) (EVar "acc")) (EApp (EVar "directImportIds") (EVar "decls")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "acc")) (EBinOp "::" (ETuple (EVar "mid") (EVar "path") (EVar "decls")) (EFieldAccess (EVar "acc") "value"))))))))))))))))
(DTypeSig false "topoOrderModules" (TyFun (TyCon "Ctx") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "topoOrderModules" ((PVar "ctx") (PVar "read") (PVar "midPaths")) (EBlock (DoLet false false (PVar "byMid") (EApp (EVar "hmNew") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "registerMidPaths") (EVar "ctx")) (EVar "byMid")) (EVar "midPaths"))) (DoLet false false (PVar "visited") (EApp (EVar "hmNew") (ELit LUnit))) (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "topoVisitAll") (EVar "ctx")) (EVar "read")) (EVar "byMid")) (EVar "visited")) (EVar "acc")) (EApp (EVar "midsOf") (EVar "midPaths")))) (DoExpr (EApp (EVar "reverseList") (EFieldAccess (EVar "acc") "value")))))
(DTypeSig true "buildRefIndexProject" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "RefIndex")))))))
(DFunDef false "buildRefIndexProject" ((PVar "read") (PVar "projectRoot") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "newCtx") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "seedPrelude") (EVar "ctx")) (ELit (LString "runtime"))) (EVar "runtimeSrc"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "seedPrelude") (EVar "ctx")) (ELit (LString "core"))) (EVar "coreSrc"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "ctx") "opCnt")) (ELit (LInt 0)))) (DoLet false false (PVar "midPaths") (EApp (EVar "midPathsOf") (EVar "projectRoot"))) (DoLet false false (PVar "mods") (EApp (EApp (EApp (EVar "topoOrderModules") (EVar "ctx")) (EVar "read")) (EVar "midPaths"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "processModules") (EVar "ctx")) (EVar "read")) (EVar "mods"))) (DoExpr (ERecordCreate "RefIndex" ((fa "defs" (EFieldAccess (EVar "ctx") "defs")) (fa "refs" (EFieldAccess (EVar "ctx") "refs")) (fa "occ" (EFieldAccess (EVar "ctx") "occ")) (fa "ops" (EFieldAccess (EFieldAccess (EVar "ctx") "opCnt") "value")))))))
(DTypeSig true "buildRefIndexProjectDisk" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "RefIndex"))))))
(DFunDef false "buildRefIndexProjectDisk" ((PVar "projectRoot") (PVar "runtimeSrc") (PVar "coreSrc")) (EApp (EApp (EApp (EApp (EVar "buildRefIndexProject") (EVar "noOverride")) (EVar "projectRoot")) (EVar "runtimeSrc")) (EVar "coreSrc")))
(DTypeSig true "defOf" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Loc"))))))
(DFunDef false "defOf" ((PVar "idx") (PVar "key")) (EApp (EApp (EVar "hmGet") (EVar "key")) (EFieldAccess (EVar "idx") "defs")))
(DTypeSig true "usesOf" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Loc"))))))
(DFunDef false "usesOf" ((PVar "idx") (PVar "key")) (EMatch (EApp (EApp (EVar "hmGet") (EVar "key")) (EFieldAccess (EVar "idx") "refs")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "reverseList") (EFieldAccess (EVar "r") "value"))) (arm (PCon "None") () (EListLit))))
(DTypeSig true "binderAt" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "binderAt" ((PVar "idx") (PVar "uri") (PVar "line") (PVar "col")) (EMatch (EApp (EApp (EVar "hmGet") (EVar "uri")) (EFieldAccess (EVar "idx") "occ")) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EApp (EVar "scanOcc") (EVar "line")) (EVar "col")) (EFieldAccess (EVar "r") "value"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "scanOcc" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "scanOcc" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "scanOcc" ((PVar "line") (PVar "col") (PCons (PTuple (PVar "loc") (PVar "key")) (PVar "rest"))) (EIf (EApp (EApp (EApp (EVar "locContains") (EVar "loc")) (EVar "line")) (EVar "col")) (EApp (EVar "Some") (EVar "key")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "scanOcc") (EVar "line")) (EVar "col")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "locContains" (TyFun (TyCon "Loc") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "locContains" ((PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (PVar "line") (PVar "col")) (EIf (EBinOp "<" (EVar "line") (EVar "sl")) (EVar "False") (EIf (EBinOp ">" (EVar "line") (EVar "el")) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EVar "line") (EVar "sl")) (EBinOp "<" (EVar "col") (EVar "sc"))) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EVar "line") (EVar "el")) (EBinOp ">" (EVar "col") (EVar "ec"))) (EVar "False") (EIf (EVar "otherwise") (EVar "True") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig true "riOps" (TyFun (TyCon "RefIndex") (TyCon "Int")))
(DFunDef false "riOps" ((PVar "idx")) (EFieldAccess (EVar "idx") "ops"))
(DTypeSig true "allDefKeys" (TyFun (TyCon "RefIndex") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "allDefKeys" ((PVar "idx")) (EApp (EVar "hmKeys") (EFieldAccess (EVar "idx") "defs")))
(DTypeSig true "usesCount" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "usesCount" ((PVar "idx") (PVar "key")) (EApp (EVar "listLength") (EApp (EApp (EVar "usesOf") (EVar "idx")) (EVar "key"))))
(DTypeSig true "occCountFor" (TyFun (TyCon "RefIndex") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "occCountFor" ((PVar "idx") (PVar "uri")) (EMatch (EApp (EApp (EVar "hmGet") (EVar "uri")) (EFieldAccess (EVar "idx") "occ")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "listLength") (EFieldAccess (EVar "r") "value"))) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "reverseList" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "reverseList" ((PVar "xs")) (EApp (EApp (EVar "reverseGo") (EVar "xs")) (EListLit)))
(DTypeSig false "reverseGo" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "reverseGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseGo" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "reverseGo") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig false "listLength" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Int")))
(DFunDef false "listLength" ((PVar "xs")) (EApp (EApp (EVar "lengthGo") (EVar "xs")) (ELit (LInt 0))))
(DTypeSig false "lengthGo" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lengthGo" ((PList) (PVar "n")) (EVar "n"))
(DFunDef false "lengthGo" ((PCons PWild (PVar "xs")) (PVar "n")) (EApp (EApp (EVar "lengthGo") (EVar "xs")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))))
(DTypeSig false "joinDotL" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinDotL" ((PList)) (ELit (LString "")))
(DFunDef false "joinDotL" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "joinDotL" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "joinDotL") (EVar "rest")))) (ELit (LString ""))))
(DTypeSig false "splitLastL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyVar "a")))))
(DFunDef false "splitLastL" ((PList)) (EVar "None"))
(DFunDef false "splitLastL" ((PList (PVar "x"))) (EApp (EVar "Some") (ETuple (EListLit) (EVar "x"))))
(DFunDef false "splitLastL" ((PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "pre") (PVar "last"))) (ETuple (EBinOp "::" (EVar "x") (EVar "pre")) (EVar "last")))) (EApp (EVar "splitLastL") (EVar "rest"))))
