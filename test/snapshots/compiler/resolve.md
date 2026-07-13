# META
source_lines=2203
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted resolve stage — Stage 2 port of `lib/resolve.ml` (single-file
-- path: `resolve_program`).  Runs after desugar.  Collects every binding name
-- into a name environment (seeded with primitives + runtime externs + the
-- prelude) and walks the decls reporting references that aren't in scope:
-- unbound variables, unknown constructors / types / effects / interfaces,
-- methods not in their interface, duplicate definitions, and extern-with-body.
--
-- Pure-functional: each check returns a `List ResError` rather than mutating a
-- ref; locations are dropped (the self-host AST has none), so the dump is the
-- sorted error structure — matching `dev/diagdump.exe --resolve`
-- (test/diff_compiler_resolve.sh).  The multi-module path (imports validated
-- against real exports, privacy, aliases) is the reference's resolve_module and
-- is NOT needed here: single-file mode stubs imports into scope.

import frontend.ast.{
  Loc(..),
  Lit(..),
  Ty(..),
  Constraint(..),
  Addr(..),
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
  useMemberLocal,
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
  Decl(..),
}
import support.ordmap.{OrdMap, omEmpty, omInsert, omHasKey, omDelete}
import support.util.{
  contains,
  editDistance,
  minI,
  maxI,
  listLen,
  escStr,
  joinNl,
  joinWith,
  lookupAssoc,
  reverseL,
  initList,
  joinDot,
  filterList,
}

-- ── Errors (mirror lib/resolve.ml's `error`) ──────────────────────────────
-- Stage B (WS-4 / F6): every ctor carries a trailing `Option Loc` — the source
-- span of the offending node (mirror of lib/resolve.ml pairing each error with
-- `!current_loc`).  Expression-position errors carry the enclosing `ELoc` span
-- threaded through the walk; decl/build-phase errors with no node in scope carry
-- `None` (rendered as the oracle's dummy {0,0} range / `<unknown location>`).
public export data ResError =
  -- trailing `Option String` = nearest in-scope name suggestion (edit-distance
  -- "did you mean"), None when no candidate is close enough (ERROR-QUALITY §4.1)
  | UnboundVariable String (Option Loc) (Option String)
  -- an unbound name that IS exported by a module the file already `import`s
  -- (bare or selective-but-missing-this-name): name, exporting module id.
  -- Takes priority over the generic edit-distance UnboundVariable suggestion
  -- (audit finding #5) — the fix is "select this name from the import", not a
  -- typo correction, and a fuzzy edit-distance match against an unrelated name
  -- is actively misleading here.
  | UnboundVariableExported String String (Option Loc)
  -- trailing `Option String` = suggested constructor name: today ONLY a
  -- curated Haskell-alias exact match (`Just`→`Some`, …; see
  -- `haskellCtorAliases`), None otherwise — there is no general edit-distance
  -- fallback for constructor patterns.
  | UnknownConstructor String (Option Loc) (Option String)
  -- trailing `Option String` = nearest in-scope TYPE name suggestion (same
  -- did-you-mean policy as UnboundVariable, candidates drawn from env.types)
  | UnknownType String (Option Loc) (Option String)
  | UnknownEffect String (Option Loc)
  | UnknownField String (Option Loc)
  | FieldNotInRecord String String (Option Loc)
  | DuplicateDefinition String String (Option Loc)
  | UnknownInterface String (Option Loc)
  | MethodNotInInterface String String (Option Loc)
  | ExternWithBody String (Option Loc)
  -- multi-module path (resolve_module): import validation against real exports
  | PrivateNameAccess String String (Option Loc)
  -- name, owning module
  | NoExportedConstructors String String (Option Loc)
  -- type, owning module (exported abstractly)
  | AbstractFieldAccess String String (Option Loc)
  -- type name, field name: a record-pattern field on a type whose fields are not
  -- in scope because the type was exported abstractly (`export` without `public`)
  | UnknownModule String (Option Loc)
  -- `import` of a module not among known exports
  -- misplaced surface constructs that survive desugar
  | NonRecursiveValueLet String (Option Loc)
  -- `let x = … x …` (no `rec`) referencing itself
  | DuplicateBinding String (Option Loc)
  -- Phase 148: non-contiguous clauses of a top-level binding
  -- a nullary top-level VALUE binding (`x = e`, no params) defined >=2× — a
  -- genuine duplicate (a value binding admits exactly one clause), unlike a
  -- multi-clause function whose clauses each carry >=1 discriminating pattern
  | DuplicateValueBinding String (Option Loc)
  -- a variable bound more than once among binders introduced TOGETHER: a
  -- non-linear pattern (`(x, x)`, `Pair x x`) or a repeated parameter (`f x x`,
  -- `x x => …`).  The binder is non-linear → all but one occurrence is silently
  -- dropped (miscompiles).  First String = the noun phrase for the group
  -- ("pattern" / "parameter list"); second = the offending name.
  | DuplicateBinder String String (Option Loc)
  | AsPatternMisplaced (Option Loc)  -- `x@..` outside a binding LHS
  -- name USED unqualified, exported by ≥2 non-`core` modules (use-time
  -- ambiguity; MAP-SET-AMBIGUITY-DESIGN.md)
  | AmbiguousOccurrence String (List String) (Option Loc)
  -- an internal-only array-kernel extern (arrayGetUnsafe, …) referenced from a
  -- module that is neither in the standard library nor compiled with
  -- `--allow-internal` (see internalExterns / Env.internalGuard)
  | InternalExternAccess String (Option Loc)
  -- beta mutability model (P0-5): a bare reassignment `x = e` of an existing
  -- binding. Bindings are immutable; `=` (without `let`) is not a declaration.
  -- Carries the reassigned name + span. Mutation lives on `Ref`/`:=`.
  | ReassignImmutable String (Option Loc)

-- The did-you-mean pair (misspelled name, suggested name) for a resolve error,
-- or None.  Only an UnboundVariable that carries a suggestion qualifies today.
-- Consumed by diagnostics.mdk (Stage 2) to build the structured `help`/`fix`
-- JSON fields — the fix span is the misspelled name's own loc-start + its length.
export resErrorDidYouMean : ResError -> Option (String, String)
resErrorDidYouMean (UnboundVariable n _ (Some sug)) = Some (n, sug)
resErrorDidYouMean (UnknownConstructor n _ (Some sug)) = Some (n, sug)
resErrorDidYouMean (UnknownType n _ (Some sug)) = Some (n, sug)
resErrorDidYouMean _ = None

-- The source span carried by a ResError (Stage B): consumed by diagnostics.mdk
-- to position the Diag (was uniformly `None` pre-Stage-B).
export resErrorLoc : ResError -> Option Loc
resErrorLoc (UnboundVariable _ l _) = l
resErrorLoc (UnboundVariableExported _ _ l) = l
resErrorLoc (UnknownConstructor _ l _) = l
resErrorLoc (UnknownType _ l _) = l
resErrorLoc (UnknownEffect _ l) = l
resErrorLoc (UnknownField _ l) = l
resErrorLoc (FieldNotInRecord _ _ l) = l
resErrorLoc (DuplicateDefinition _ _ l) = l
resErrorLoc (UnknownInterface _ l) = l
resErrorLoc (MethodNotInInterface _ _ l) = l
resErrorLoc (ExternWithBody _ l) = l
resErrorLoc (PrivateNameAccess _ _ l) = l
resErrorLoc (NoExportedConstructors _ _ l) = l
resErrorLoc (AbstractFieldAccess _ _ l) = l
resErrorLoc (UnknownModule _ l) = l
resErrorLoc (NonRecursiveValueLet _ l) = l
resErrorLoc (DuplicateBinding _ l) = l
resErrorLoc (DuplicateValueBinding _ l) = l
resErrorLoc (DuplicateBinder _ _ l) = l
resErrorLoc (AsPatternMisplaced l) = l
resErrorLoc (AmbiguousOccurrence _ _ l) = l
resErrorLoc (InternalExternAccess _ l) = l
resErrorLoc (ReassignImmutable _ l) = l

-- ── The name environment ──────────────────────────────────────────────────
-- Name-category sets, as plain lists (the self-host is prelude-only, so no
-- hash_map; membership is a linear `contains`).
-- `fieldOwners` is (field, owner) pairs; `ifaceMethods` is (iface, methods).
public export data Env = Env {
    values : List String,
    types : List String,
    ctors : List String,
    fields : List String,
    fieldOwners : List (String, String),
    interfaces : List String,
    ifaceMethods : List (String, List String),
    effects : List String,
    imported : List String,
    importedModuleValues : List (String, List String),  -- (modId, expValues) pairs for every non-`core` module this file `import`s
    ambiguous : List (String, List String),  -- (multi-module path only; single-file `buildEnv` leaves this `[]`) — lets
    internalGuard : List String,  -- `checkVar` recognize an unbound name that's an export of an ALREADY
  }  -- imported module (needs a selective import, not a typo fix; audit #5).
-- use-time ambiguity (MAP-SET-AMBIGUITY-DESIGN.md): name → the ≥2 distinct
-- non-`core` module ids that export it unqualified

-- internal-only externs (arrayGetUnsafe, …) that this module is NOT permitted
-- to reference (empty when the module is trusted: a stdlib module, or any
-- module under `--allow-internal`).  checkVar flags a reference to one of these.

-- ── internal-only externs ──────────────────────────────────────────────────
-- Array-kernel primitives declared in stdlib/runtime.mdk that bypass bounds
-- checks / mutate in place.  They are globally in scope (runtime.mdk is the
-- implicit prelude), so a module that is neither part of the standard library
-- nor compiled with `--allow-internal` must not reference them.  Mirrors the
-- hardcoded-set pattern of builtInEffects.  `__fallthrough__` is deliberately
-- EXCLUDED: it is compiler-generated by desugar for guard fallthrough and so
-- legitimately appears in user programs post-desugar.
export internalExterns : List String
internalExterns = ["arrayGetUnsafe", "arraySetUnsafe", "arrayBlit", "arrayFill", "bytesToFloat64"]

-- The internal-extern guard list for a module given whether internal access is
-- permitted (a trusted module / `--allow-internal`): empty ⇒ no restriction.
export internalGuardFor : Bool -> List String
internalGuardFor True = []
internalGuardFor False = internalExterns

-- the owners registered for a field name in the field-owner multimap
ownersOf : String -> List (String, String) -> List String
ownersOf _ [] = []
ownersOf field ((f, owner)::rest)
  | f == field = owner :: ownersOf field rest
  | otherwise = ownersOf field rest

-- ── pat_bindings ──────────────────────────────────────────────────────────
patBindings : Pat -> List String
patBindings (PVar x) = [x]
patBindings PWild = []
patBindings (PLit _) = []
patBindings (PCon _ ps) = flatMap patBindings ps
patBindings (PCons a b) = patBindings a ++ patBindings b
patBindings (PTuple ps) = flatMap patBindings ps
patBindings (PList ps) = flatMap patBindings ps
patBindings (PAs x p) = x :: patBindings p
patBindings (PRng _ _ _) = []
patBindings (PRec _ fields _) = flatMap recFieldBindings fields

recFieldBindings : RecPatField -> List String
recFieldBindings (RecPatField fname None) = [fname]
recFieldBindings (RecPatField _ (Some p)) = patBindings p

patsBindings : List Pat -> List String
patsBindings ps = flatMap patBindings ps

-- Non-linearity check for a group of binders introduced TOGETHER — a single
-- match/let/do pattern (`(x, x)`, `Pair x x`) or a parameter list (`f x x`,
-- `x x => …`).  The language binds each variable exactly once; a repeat is not
-- shadowing (these binders share one scope) but a silent drop — `(x, x)` binds
-- only the FIRST component → runtime garbage.  `findDups` yields each repeated
-- name once (keyed on the 2nd occurrence).  Patterns carry no own Loc, so the
-- error is positioned at the enclosing clause/expr span `loc`.  `kind` is the
-- group's noun phrase ("pattern" / "parameter list").
patGroupDupErrors : Option Loc -> String -> List Pat -> List ResError
patGroupDupErrors loc kind ps =
  map (n => DuplicateBinder kind n loc) (findDups [] (patsBindings ps))

-- ── check_type ────────────────────────────────────────────────────────────
-- `cur` (Stage B) is the enclosing `ELoc` span threaded from the expr walk (or
-- `None` at decl level), mirroring lib/resolve.ml's `!current_loc`.
checkType : Option Loc -> Env -> Ty -> List ResError
checkType cur env (TyCon n loc) =
  if contains n env.types || contains n env.imported || isTupleCtorTyName n then
    []
  else
    [UnknownType n (orElseLocL loc cur) (suggestType env n)]
checkType _ _ (TyVar _) = []
-- (helper below `checkType`) — accept the bare tuple type constructors
-- `(,)`…`(,,,,)` (which the parser lowers to `TyCon "__tupleN__"`, arities 2–5)
-- as known type names WITHOUT adding them to `env.types`/`primitiveTypes`: those
-- feed the emitter's per-head default-method enumeration, and a spurious
-- `__tupleN__` head there makes it try to emit a `Bimappable` default at a tuple
-- with no `bimap` impl.  Kept in sync with the parser's `tupleCtorTyName` and
-- typecheck's `tupleHeadTagTc`.
checkType cur env (TyApp a b) = checkType cur env a ++ checkType cur env b
checkType cur env (TyFun a b) = checkType cur env a ++ checkType cur env b
checkType cur env (TyTuple ts) = flatMap (checkType cur env) ts
checkType cur env (TyEffect labels _ t) = flatMap (checkEffect cur env) (map fst labels)
  ++ checkType cur env t
checkType cur env (TyConstrained cs t) = flatMap (checkConstraint cur env) cs
  ++ checkType cur env t

builtInEffects : List String
builtInEffects = [
  "IO",
  "Mut",
  "Panic",
  "Rand",
  "Stdout",
  "Stderr",
  "Stdin",
  "Clock",
  "Env",
  "Exec",
  "Net",
  "FileRead",
  "FileWrite",
]

checkEffect : Option Loc -> Env -> String -> List ResError
checkEffect cur env e =
  if contains e builtInEffects || contains e env.effects then
    []
  else
    [UnknownEffect e cur]

checkConstraint : Option Loc -> Env -> Constraint -> List ResError
checkConstraint cur env (Constraint iface args) = (if contains iface env.interfaces then [] else [UnknownInterface iface cur])
  ++ flatMap (checkType cur env) args

-- ── check_pat ─────────────────────────────────────────────────────────────
checkPat : Option Loc -> Env -> Pat -> List ResError
checkPat cur env (PCon c ps) = (if contains c env.ctors || contains c env.imported then [] else [UnknownConstructor c cur (suggestCtor c)])
  ++ flatMap (checkPat cur env) ps
checkPat cur env (PCons a b) = checkPat cur env a ++ checkPat cur env b
checkPat cur env (PTuple ps) = flatMap (checkPat cur env) ps
checkPat cur env (PList ps) = flatMap (checkPat cur env) ps
checkPat cur env (PAs _ p) = checkPat cur env p
checkPat cur env (PRec name fields _) = checkRecPat cur env name fields
checkPat _ _ _ = []

checkRecPat : Option Loc -> Env -> String -> List RecPatField -> List ResError
checkRecPat cur env name fields = recPatHead cur env name
  ++ flatMap (checkRecField cur env name) fields

recPatHead : Option Loc -> Env -> String -> List ResError
recPatHead cur env name =
  if contains name env.types || contains name env.ctors then
    []
  else
    [UnknownType name cur (suggestType env name)]

checkRecField : Option Loc -> Env -> String -> RecPatField -> List ResError
checkRecField cur env owner (RecPatField fname popt) = fieldCheck cur env owner fname
  ++ recFieldSub cur env popt

fieldCheck : Option Loc -> Env -> String -> String -> List ResError
fieldCheck cur env owner fname =
  let owners = ownersOf fname env.fieldOwners
  fieldVerdict cur env owner fname owners

-- No record in scope declares `fname`.  If the pattern head `owner` IS a known
-- type (it resolved past recPatHead) yet owns NO fields at all, its fields were
-- never registered — the only way a local record/named-field-variant reaches here
-- with zero owners is that it was exported abstractly (`export` without `public`),
-- whereas a local definition always registers its fields.  Distinguish that case
-- from a genuinely-unknown field with a clearer message.
fieldVerdict : Option Loc -> Env -> String -> String -> List String -> List ResError
fieldVerdict cur env owner fname [] =
  if contains owner env.types && not (ownsAnyField owner env.fieldOwners) then
    [AbstractFieldAccess owner fname cur]
  else
    [UnknownField fname cur]
fieldVerdict cur env owner fname owners =
  if contains owner owners then
    []
  else
    [FieldNotInRecord fname owner cur]

-- does `owner` own ANY field in the field-owner multimap?
ownsAnyField : String -> List (String, String) -> Bool
ownsAnyField _ [] = False
ownsAnyField owner ((_, o)::rest)
  | o == owner = True
  | otherwise = ownsAnyField owner rest

recFieldSub : Option Loc -> Env -> Option Pat -> List ResError
recFieldSub _ _ None = []
recFieldSub cur env (Some p) = checkPat cur env p

-- ── check_expr (scope = locally-bound names) ──────────────────────────────
-- `cur` (Stage B): the innermost enclosing `ELoc` span, threaded so every error
-- emitted while walking the expr carries that span (mirror lib/resolve.ml's
-- `!current_loc`, set by its `ELoc` arm).  `None` until the first ELoc.
checkExpr : Option Loc -> Env -> List String -> Expr -> List ResError
checkExpr _ _ _ (ELit _) = []
checkExpr _ _ _ (ENumLit _ _ _) = []  -- PLAN.md #11: a literal, nothing to bind
checkExpr _ _ _ (EMethodRef _) = []
checkExpr _ _ _ (EDictApp _) = []
-- EVarAt/EMethodAt/EDictAt are elaborated nodes introduced by annotateProgram /
-- typecheck AFTER resolve; checkExpr's input is the desugared pre-resolve AST, so
-- these arms are unreachable.
checkExpr _ _ _ (EVarAt _ _) =
  panic "unreachable: EVarAt is introduced by annotateProgram after resolve"
checkExpr _ _ _ (EMethodAt _ _ _ _) =
  panic
    "unreachable: EMethodAt is introduced by typecheck elaboration after resolve"
checkExpr _ _ _ (EDictAt _ _) =
  panic
    "unreachable: EDictAt is introduced by typecheck elaboration after resolve"
checkExpr cur env scope (EVar n) = checkVar cur env scope n
checkExpr cur env scope (EApp f x) = checkExpr cur env scope f
  ++ checkExpr cur env scope x
checkExpr cur env scope (ELam pats body) = flatMap (checkPat cur env) pats
  ++ patGroupDupErrors cur "parameter list" pats
  ++ checkExpr cur env (patsBindings pats ++ scope) body
checkExpr cur env scope (ELet _ isRec pat e1 e2) =
  checkLet cur env scope isRec pat e1 e2
checkExpr cur env scope (ELetGroup binds body) =
  checkLetGroup cur env scope binds body
checkExpr cur env scope (EMatch e0 arms) = checkExpr cur env scope e0
  ++ flatMap (checkArm cur env scope) arms
checkExpr cur env scope (EIf c t el) = checkExpr cur env scope c
  ++ checkExpr cur env scope t
  ++ checkExpr cur env scope el
checkExpr cur env scope (EBinOp _ a b _) = checkExpr cur env scope a
  ++ checkExpr cur env scope b
checkExpr cur env scope (EUnOp _ a _) = checkExpr cur env scope a
checkExpr cur env scope (EInfix op a b) = checkVar cur env scope op
  ++ checkExpr cur env scope a
  ++ checkExpr cur env scope b
checkExpr cur env scope (EFieldAccess e0 _ _) = checkExpr cur env scope e0
-- EMapLit/ESetLit are lowered to `fromEntries …` by desugar's
-- lowerContainerLiterals BEFORE resolve runs, so these arms are unreachable.
checkExpr _ _ _ (EMapLit _ _) =
  panic
    "unreachable: EMapLit is lowered to fromEntries by desugar before resolve"
checkExpr _ _ _ (ESetLit _ _) =
  panic
    "unreachable: ESetLit is lowered to fromEntries by desugar before resolve"
checkExpr cur env scope (ETuple es) = flatMap (checkExpr cur env scope) es
checkExpr cur env scope (EListLit es) = flatMap (checkExpr cur env scope) es
checkExpr cur env scope (EArrayLit es) = flatMap (checkExpr cur env scope) es
checkExpr cur env scope (ERangeList lo hi _) = checkExpr cur env scope lo
  ++ checkExpr cur env scope hi
checkExpr cur env scope (ERangeArray lo hi _) = checkExpr cur env scope lo
  ++ checkExpr cur env scope hi
checkExpr cur env scope (ESlice e0 lo hi _ _) = checkExpr cur env scope e0
  ++ checkExpr cur env scope lo
  ++ checkExpr cur env scope hi
checkExpr cur env scope (EIndex e0 i _) = checkExpr cur env scope e0
  ++ checkExpr cur env scope i
checkExpr cur env scope (EAnnot e0 t) = checkExpr cur env scope e0
  ++ checkType cur env t
-- EHeadAnnot is the synthetic `:~` head-pin desugar emits for Map/Set literals
-- (`fromEntries [...] :~ Map _k _v`).  The container type (Map/Set/…) is a real
-- type, so validate it like EAnnot via checkType — except the multi-module env
-- already carries imported types so an `import map`-bearing program resolves
-- `Map`, while a bare `Map { … }` with no import resolves to UnknownType, both
-- matching the OCaml oracle (lib/resolve.ml EHeadAnnot arm, Phase 108).
checkExpr cur env scope (EHeadAnnot e0 t) = checkExpr cur env scope e0
  ++ checkType cur env t
checkExpr cur env scope (EBlock stmts) = checkStmts cur env scope stmts
checkExpr cur env scope (EDo stmts) = checkStmts cur env scope stmts
checkExpr cur env scope (EStringInterp parts) =
  flatMap (checkInterp cur env scope) parts
checkExpr cur env scope (EGuards arms) =
  flatMap (checkGuardArm cur env scope) arms
checkExpr cur env scope (ERecordCreate name fs) =
  checkRecordCreate cur env scope name fs
checkExpr cur env scope (ERecordUpdate e0 fs _) =
  checkRecordUpdate cur env scope e0 fs
checkExpr cur env scope (EVariantUpdate con e0 fs) = checkExpr cur env scope e0
  ++ checkRecordCreate cur env scope con fs
checkExpr cur env scope (EAsPat _ e0) =
  AsPatternMisplaced cur :: checkExpr cur env scope e0
checkExpr cur env scope (ESection s) = checkSection cur env scope s
-- ELoc captures its span into `cur` (Stage B), then recurses — so any error in
-- the wrapped subtree is attributed to this span (mirror lib/resolve.ml's ELoc
-- arm setting `current_loc`).
checkExpr _ env scope (ELoc l e) = checkExpr (Some l) env scope e
checkExpr cur env scope (EDoOrigin _ e) = checkExpr cur env scope e

-- an `@Name` impl hint is not a value reference (resolve must not flag it)
checkVar : Option Loc -> Env -> List String -> String -> List ResError
checkVar cur env scope n
  | isHint n = []
  -- internal-only extern referenced (and not locally shadowed) from an
  -- untrusted module ⇒ compile error (see internalExterns / Env.internalGuard).
  | not (contains n scope) && contains n env.internalGuard =
    [InternalExternAccess n cur]
  | not (lookupValue env scope n) = unboundVarErrors cur env scope n
  -- use-time ambiguity: resolves, not shadowed by a local, exported by ≥2
  -- non-core modules (same-module top-levels already excluded from the set).
  | not (contains n scope) && isAmbiguous env n =
    [AmbiguousOccurrence n (ambigMods env n) cur]
  | otherwise = []

-- The errors for a name that failed `lookupValue`: if it's exported by an
-- already-imported module (audit #5 — the user needs a selective import, not
-- a typo fix), report that specifically; otherwise fall back to the generic
-- edit-distance/Haskell-alias UnboundVariable suggestion.
unboundVarErrors : Option Loc -> Env -> List String -> String -> List ResError
unboundVarErrors cur env scope n = match modulesExportingName env n
  m::_ => [UnboundVariableExported n m cur]
  [] => [UnboundVariable n cur (suggestName env scope n)]

-- module ids (of modules this file already imports) that export `n` as a
-- value — deliberately NOT scope/local-shadow aware, since `unboundVarErrors`
-- only reaches this after `lookupValue` already failed (so `n` cannot be a
-- shadowed local).
modulesExportingName : Env -> String -> List String
modulesExportingName env n = flatMap (matchesExport n) env.importedModuleValues

matchesExport : String -> (String, List String) -> List String
matchesExport n (mid, vals) = if contains n vals then [mid] else []

isAmbiguous : Env -> String -> Bool
isAmbiguous env n = match lookupAssoc n env.ambiguous
  Some _ => True
  None => False

ambigMods : Env -> String -> List String
ambigMods env n = match lookupAssoc n env.ambiguous
  Some mods => mods
  None => []

isHint : String -> Bool
isHint n = startsWithAt (stringToChars n)

startsWithAt : Array Char -> Bool
-- Intentional cross-file duplicate of the same helper in annotate.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
startsWithAt cs = arrayLength cs > 0 && arrayGetUnsafe 0 cs == '@'

lookupValue : Env -> List String -> String -> Bool
lookupValue env scope n = contains n scope
  || contains n env.values
  || contains n env.ctors
  || contains n env.imported

-- "did you mean" for an unbound name: the nearest in-scope value name by
-- Levenshtein distance (ERROR-QUALITY §4.1).  Suggest only when the distance is
-- small absolutely (≤ 2) AND small relative to the name length (≤ max(1, len/3)).
-- Names shorter than 3 chars never suggest: a 1-2 char name sits within edit
-- distance 1 of many unrelated short names (`x` → `e`), which is pure noise.
-- Ties break lexicographically.  Local (`scope`) names are tried first so a
-- mistyped local outranks an equidistant prelude name (a local typo most likely
-- meant a local).
-- ── Curated Haskell→Medaka alias tables (ERROR-QUALITY F-dimension) ───────
-- LLMs are trained heavily on Haskell and reflexively reach for Haskell names
-- that Medaka deliberately renamed.  When an unbound/unknown name EXACTLY
-- matches one of these, the `suggest*` functions below surface the Medaka
-- equivalent with priority over the generic edit-distance did-you-mean: an
-- exact foreign-name match is higher-confidence than a fuzzy same-language
-- one (and often wins where edit distance wouldn't even fire — `fmap`→`map`
-- is edit-distance 2 on a 4-char word).  One table per namespace, kept
-- together here rather than scattered by call site.
haskellTypeAliases : List (String, String)
haskellTypeAliases = [
  ("Functor", "Mappable"),
  ("Monad", "Thenable"),
  ("Maybe", "Option"),
  ("Either", "Result"),
]

haskellValueAliases : List (String, String)
haskellValueAliases = [
  ("fmap", "map"),
  ("return", "pure"),
  ("show", "debug"),
  ("mappend", "append"),
  ("mempty", "empty"),
  ("foldr", "foldRight"),
  ("foldl", "fold"),
  ("error", "panic"),
  ("undefined", "panic"),
]

haskellCtorAliases : List (String, String)
haskellCtorAliases =
  [("Just", "Some"), ("Nothing", "None"), ("Left", "Err"), ("Right", "Ok")]

-- Was `sug` produced by looking `bad` up in one of the three alias tables
-- above (as opposed to falling out of generic edit-distance search)?  Used by
-- `ppResError` to decide whether to append the "(… is Haskell …)" note.
isHaskellAliasPair : String -> String -> Bool
isHaskellAliasPair bad sug = optStrEq (lookupAssoc bad haskellTypeAliases) sug
  || optStrEq (lookupAssoc bad haskellValueAliases) sug
  || optStrEq (lookupAssoc bad haskellCtorAliases) sug

optStrEq : Option String -> String -> Bool
optStrEq (Some x) sug = x == sug
optStrEq None _ = False

-- The CLI-text parenthetical appended after a did-you-mean hint when it came
-- from a curated Haskell alias, e.g. "('fmap' is Haskell; Medaka uses
-- 'map')".  Empty string (no-op append) when the hint is a plain
-- edit-distance suggestion.
haskellNote : String -> String -> String
haskellNote bad sug =
  if isHaskellAliasPair bad sug then
    " ('\{bad}' is Haskell; Medaka uses '\{sug}')"
  else
    ""

-- "did you mean" for an unbound name: an exact curated Haskell-alias match
-- takes priority; otherwise the nearest in-scope value name by Levenshtein
-- distance (ERROR-QUALITY §4.1).  Suggest only when the distance is small
-- absolutely (≤ 2) AND small relative to the name length (≤ max(1, len/3)).
-- Names shorter than 3 chars never suggest: a 1-2 char name sits within edit
-- distance 1 of many unrelated short names (`x` → `e`), which is pure noise.
-- Ties break lexicographically.  Local (`scope`) names are tried first so a
-- mistyped local outranks an equidistant prelude name (a local typo most likely
-- meant a local).
suggestName : Env -> List String -> String -> Option String
suggestName env scope n = match lookupAssoc n (haskellValueAliases ++ haskellCtorAliases)
  Some sug => Some sug
  None => suggestNameFuzzy env scope n

suggestNameFuzzy : Env -> List String -> String -> Option String
suggestNameFuzzy env scope n
  | stringLength n < 3 = None
  | otherwise =
    let lim = minI 2 (maxI 1 (stringLength n / 3))
    match bestOf n lim scope
      Some best => Some best
      None => bestOf n lim (env.values ++ env.ctors ++ env.imported)

-- "did you mean" for an unknown TYPE name: an exact curated Haskell-alias
-- match takes priority; otherwise same policy as `suggestName` (nearest by
-- edit distance, ≤ min(2, len/3), names shorter than 3 chars never suggest),
-- candidates drawn from the in-scope type names (builtins + user
-- `data`/`type`/`record` + imported) rather than value names.
suggestType : Env -> String -> Option String
suggestType env n = match lookupAssoc n haskellTypeAliases
  Some sug => Some sug
  None => suggestTypeFuzzy env n

suggestTypeFuzzy : Env -> String -> Option String
suggestTypeFuzzy env n
  | stringLength n < 3 = None
  | otherwise =
    let lim = minI 2 (maxI 1 (stringLength n / 3))
    bestOf n lim (env.types ++ env.imported)

-- "did you mean" for an unknown CONSTRUCTOR (pattern position): today ONLY an
-- exact curated Haskell-alias match (e.g. `Just`→`Some`) — there is no
-- general edit-distance fallback for constructors yet.
suggestCtor : String -> Option String
suggestCtor n = lookupAssoc n haskellCtorAliases

bestOf : String -> Int -> List String -> Option String
bestOf n lim cands = map ((best, _) => best) (bestCandidate n lim cands None)

bestCandidate : String -> Int -> List String -> Option (String, Int) -> Option (String, Int)
bestCandidate _ _ [] acc = acc
bestCandidate n lim (c::cs) acc
  | c == n = bestCandidate n lim cs acc
  | editDistance n c > lim = bestCandidate n lim cs acc
  | otherwise = bestCandidate n lim cs (keepBetter c (editDistance n c) acc)

keepBetter : String -> Int -> Option (String, Int) -> Option (String, Int)
keepBetter c d None = Some (c, d)
keepBetter c d (Some (bc, bd))
  | d < bd = Some (c, d)
  | d == bd && c < bc = Some (c, d)
  | otherwise = Some (bc, bd)

checkLet : Option Loc -> Env -> List String -> Bool -> Pat -> Expr -> Expr -> List ResError
checkLet cur env scope True (PVar f) e1 e2 = checkExpr cur env (f::scope) e1
  ++ checkExpr cur env (f::scope) e2
-- non-recursive (or rec with non-var pat): the bound names are NOT in scope on
-- the RHS.  An UnboundVariable for one of them ⇒ the user likely forgot `rec`,
-- so re-target it as NonRecursiveValueLet (mirrors lib/resolve.ml's rewrite).
checkLet cur env scope _ pat e1 e2 =
  let bound = patBindings pat
  checkPat cur env pat
    ++ patGroupDupErrors cur "pattern" [pat]
    ++ map (rewriteNonRec bound) (checkExpr cur env scope e1)
    ++ checkExpr cur env (bound ++ scope) e2

rewriteNonRec : List String -> ResError -> ResError
rewriteNonRec bound (UnboundVariable n l s) =
  if contains n bound then
    NonRecursiveValueLet n l
  else
    UnboundVariable n l s
rewriteNonRec _ e = e

-- where-group: all group names are in scope for every clause body + the result
checkLetGroup : Option Loc -> Env -> List String -> List LetBind -> Expr -> List ResError
checkLetGroup cur env scope binds body =
  let scope2 = map letBindName binds ++ scope
  flatMap (checkLetBind cur env scope2) binds ++ checkExpr cur env scope2 body

letBindName : LetBind -> String
letBindName (LetBind n _) = n

checkLetBind : Option Loc -> Env -> List String -> LetBind -> List ResError
checkLetBind cur env scope (LetBind n clauses) = letBindDupErrors cur n clauses
  ++ flatMap (checkFunClause cur env scope) clauses

-- A let/where binding whose clause run includes a NULLARY clause (`y = e`, no
-- params) yet has >1 clause is a duplicate value binding — the exact analog of
-- the top-level `int = 4` / `int = 5` case (coalesceClauses merged `y = 1` /
-- `y = 2` into one multi-clause LetBind).  A value binding admits exactly one
-- clause; the extras silently last-win → runtime garbage.  Multi-clause
-- FUNCTIONS (every clause carries >=1 pattern → no nullary clause) are exempt.
-- Flags every clause after the first; loc = that clause's body span.
letBindDupErrors : Option Loc -> String -> List FunClause -> List ResError
letBindDupErrors cur n clauses =
  if hasNullaryClause clauses then
    dupClauseTail cur n False clauses
  else
    []

hasNullaryClause : List FunClause -> Bool
hasNullaryClause [] = False
hasNullaryClause ((FunClause ps _)::rest) = isEmptyL ps || hasNullaryClause rest

dupClauseTail : Option Loc -> String -> Bool -> List FunClause -> List ResError
dupClauseTail _ _ _ [] = []
dupClauseTail cur n seen ((FunClause _ body)::rest) = whenL seen [DuplicateValueBinding n (orElseLocL (firstExprLoc body) cur)]
  ++ dupClauseTail cur n True rest

-- Parameter patterns are checked BEFORE the body's expr walk ever sees an
-- ELoc, so a bare `cur` (often None here — e.g. a top-level where-group)
-- would leave a pattern-position error (unknown record field in a
-- destructuring param) permanently unlocated. Fall back to the clause
-- body's own first ELoc span, same approximation `dupClauseTail`/`declLoc`
-- already use for pattern-adjacent errors.
checkFunClause : Option Loc -> Env -> List String -> FunClause -> List ResError
checkFunClause cur env scope (FunClause pats body) =
  let patLoc = orElseLocL (firstExprLoc body) cur
  flatMap (checkPat patLoc env) pats
    ++ patGroupDupErrors patLoc "parameter list" pats
    ++ checkExpr cur env (patsBindings pats ++ scope) body

checkArm : Option Loc -> Env -> List String -> Arm -> List ResError
checkArm cur env scope (Arm pat gs body) =
  let scope0 = patBindings pat ++ scope
  let (gErrs, scope2) = checkArmGuards cur env scope0 gs
  checkPat cur env pat
    ++ patGroupDupErrors cur "pattern" [pat]
    ++ gErrs
    ++ checkExpr cur env scope2 body

-- Resolve an arm's guard qualifiers left-to-right, threading each pattern-bind's
-- binders into the LATER qualifiers AND the arm body (mirror of lib/resolve.ml's
-- EMatch fold).  Returns the accumulated errors and the body's scope.  A `GBind`
-- also resolves its bind expression in the pre-bind scope and checks its pattern.
checkArmGuards : Option Loc -> Env -> List String -> List Guard -> (List ResError, List String)
checkArmGuards _ _ scope [] = ([], scope)
checkArmGuards cur env scope ((GBool e)::rest) =
  let (rErrs, scope2) = checkArmGuards cur env scope rest
  (checkExpr cur env scope e ++ rErrs, scope2)
checkArmGuards cur env scope ((GBind p e)::rest) =
  let here = checkExpr cur env scope e ++ checkPat cur env p ++ patGroupDupErrors cur "pattern" [p]
  let (rErrs, scope2) = checkArmGuards cur env (patBindings p ++ scope) rest
  (here ++ rErrs, scope2)

checkGuardArm : Option Loc -> Env -> List String -> GuardArm -> List ResError
checkGuardArm cur env scope (GuardArm gs body) = flatMap (checkGuard cur env scope) gs
  ++ checkExpr cur env scope body

checkGuard : Option Loc -> Env -> List String -> Guard -> List ResError
checkGuard cur env scope (GBool e) = checkExpr cur env scope e
checkGuard cur env scope (GBind _ e) = checkExpr cur env scope e

checkStmts : Option Loc -> Env -> List String -> List DoStmt -> List ResError
checkStmts _ _ _ [] = []
checkStmts cur env scope (s::rest) =
  let (errs, scope2) = checkStmt cur env scope s
  errs ++ checkStmts cur env scope2 rest

checkStmt : Option Loc -> Env -> List String -> DoStmt -> (List ResError, List String)
checkStmt cur env scope (DoExpr e) = (checkExpr cur env scope e, scope)
checkStmt cur env scope (DoBind p e) = (
  checkPat cur env p ++ patGroupDupErrors cur "pattern" [p] ++ checkExpr cur env scope e,
  patBindings p ++ scope,
)
checkStmt cur env scope (DoLet _ False p e) = (
  checkPat cur env p ++ patGroupDupErrors cur "pattern" [p] ++ checkExpr cur env scope e,
  patBindings p ++ scope,
)
checkStmt cur env scope (DoLet _ True p e) = (
  checkPat cur env p ++ patGroupDupErrors cur "pattern" [p] ++ checkExpr cur env (patBindings p ++ scope) e,
  patBindings p ++ scope,
)
-- beta: a bare reassignment `x = e` (no `let`) of an existing binding is an
-- error — bindings are immutable. Still check the RHS so its errors surface too.
checkStmt cur env scope (DoAssign x e) = (
  ReassignImmutable x (orElseLocL (firstExprLoc e) cur) :: checkExpr cur env scope e,
  scope,
)
checkStmt cur env scope (DoFieldAssign _ _ e) =
  (checkExpr cur env scope e, scope)

checkInterp : Option Loc -> Env -> List String -> InterpPart -> List ResError
checkInterp _ _ _ (InterpStr _) = []
checkInterp cur env scope (InterpExpr e) = checkExpr cur env scope e

checkFieldAssign : Option Loc -> Env -> List String -> FieldAssign -> List ResError
checkFieldAssign cur env scope (FieldAssign _ e) = checkExpr cur env scope e

-- record create `C { f = v, … }`: head must be a record type / named ctor; if so,
-- each field must belong to it; then check the value exprs
checkRecordCreate : Option Loc -> Env -> List String -> String -> List FieldAssign -> List ResError
checkRecordCreate cur env scope name fs = recCreateHead cur env name fs
  ++ flatMap (checkFieldAssign cur env scope) fs

recCreateHead : Option Loc -> Env -> String -> List FieldAssign -> List ResError
recCreateHead cur env name fs
  | contains name env.types || contains name env.imported || contains name env.ctors = flatMap (recCreateField cur env name) fs
  | otherwise = [UnknownType name cur (suggestType env name)]

recCreateField : Option Loc -> Env -> String -> FieldAssign -> List ResError
recCreateField cur env owner (FieldAssign fname _) =
  fieldVerdict cur env owner fname (ownersOf fname env.fieldOwners)

-- record update `{ e | f = v, … }`: the receiver's type isn't pinned, so only
-- flag a field unknown to *every* record (no FieldNotInRecord here)
checkRecordUpdate : Option Loc -> Env -> List String -> Expr -> List FieldAssign -> List ResError
checkRecordUpdate cur env scope e0 fs = checkExpr cur env scope e0
  ++ flatMap (recUpdateField cur env scope) fs

recUpdateField : Option Loc -> Env -> List String -> FieldAssign -> List ResError
recUpdateField cur env scope (FieldAssign fname v) = checkExpr cur env scope v
  ++ fieldKnownErr cur env fname

fieldKnownErr : Option Loc -> Env -> String -> List ResError
fieldKnownErr cur env fname =
  recUpdateVerdict cur fname (ownersOf fname env.fieldOwners)

recUpdateVerdict : Option Loc -> String -> List String -> List ResError
recUpdateVerdict cur fname [] = [UnknownField fname cur]
recUpdateVerdict _ _ _ = []

checkSection : Option Loc -> Env -> List String -> Section -> List ResError
checkSection _ _ _ (SecBare _) = []
checkSection cur env scope (SecRight _ e) = checkExpr cur env scope e
checkSection cur env scope (SecLeft e _) = checkExpr cur env scope e

-- ── check_decl ────────────────────────────────────────────────────────────
-- Decl-level entry: `cur` starts at `None` (no enclosing expr span yet, mirror
-- lib/resolve.ml resetting `current_loc := None` per decl); the body's `ELoc`
-- wrappers re-set it as the expr walk descends.
checkDecl : Env -> Decl -> List ResError
checkDecl env (DFunDef _ _ pats body) = flatMap (checkPat (firstExprLoc body) env) pats
  ++ patGroupDupErrors (firstExprLoc body) "parameter list" pats
  ++ checkExpr None env (patsBindings pats) body
checkDecl env (DLetGroup _ binds) =
  -- top-level where-group: all group names are in scope for every clause body
  -- (mutual recursion), mirroring lib/resolve.ml's DLetGroup arm.
  flatMap (checkLetBind None env (map letBindName binds)) binds
checkDecl env (DTypeSig _ _ t) = checkType None env t
checkDecl env (DExtern _ _ t) = checkType None env t
checkDecl env (DData _ _ _ vs _) = flatMap (checkVariant env) vs
checkDecl env (DProp _ _ params body) = checkProp env params body
checkDecl env (DTest _ _ body) = checkExpr None env [] body
checkDecl env (DBench _ _ body) = checkExpr None env [] body
checkDecl env (DInterface { supers, methods, ... }) =
  checkInterfaceDecl env supers methods
checkDecl env (DImpl { iface, tys, reqs, methods, ... }) =
  checkImplDecl env iface tys reqs methods
checkDecl env (DTypeAlias _ _ _ rhs) = checkType None env rhs
checkDecl env (DNewtype _ _ _ _ fty _) = checkType None env fty
checkDecl env (DAttrib _ inner) = checkDecl env inner
checkDecl _ _ = []

checkVariant : Env -> Variant -> List ResError
checkVariant env (Variant _ (ConPos tys)) = flatMap (checkType None env) tys
checkVariant env (Variant _ (ConNamed fs _)) = flatMap (checkFieldType env) fs

checkFieldType : Env -> Field -> List ResError
checkFieldType env (Field _ t) = checkType None env t

checkProp : Env -> List PropParam -> Expr -> List ResError
checkProp env params body = flatMap (checkPropParamTy env) params
  ++ checkExpr None env (map propParamName params) body

checkPropParamTy : Env -> PropParam -> List ResError
checkPropParamTy env (PropParam _ t) = checkType None env t

propParamName : PropParam -> String
propParamName (PropParam x _) = x

checkInterfaceDecl : Env -> List Super -> List IfaceMethod -> List ResError
checkInterfaceDecl env supers methods = flatMap (checkSuper env) supers
  ++ flatMap (checkIfaceMethod env) methods

checkSuper : Env -> Super -> List ResError
checkSuper env (Super iface _) =
  if contains iface env.interfaces then
    []
  else
    [UnknownInterface iface None]

checkIfaceMethod : Env -> IfaceMethod -> List ResError
checkIfaceMethod env (IfaceMethod _ t None) = checkType None env t
checkIfaceMethod env (IfaceMethod _ t (Some (MethodDefault pats body))) = checkType None env t
  ++ flatMap (checkPat (firstExprLoc body) env) pats
  ++ checkExpr None env (patsBindings pats) body

checkImplDecl : Env -> String -> List Ty -> List Require -> List ImplMethod -> List ResError
checkImplDecl env iface tyargs reqs methods = flatMap (checkType None env) tyargs
  ++ flatMap (checkRequire env) reqs
  ++ flatMap (checkImplMethod env) methods
  ++ checkImplIface env iface methods

checkRequire : Env -> Require -> List ResError
checkRequire env (Require iface tys) = (if contains iface env.interfaces then [] else [UnknownInterface iface None])
  ++ flatMap (checkType None env) tys

checkImplMethod : Env -> ImplMethod -> List ResError
checkImplMethod env (ImplMethod _ pats body) = flatMap (checkPat (firstExprLoc body) env) pats
  ++ checkExpr None env (patsBindings pats) body

checkImplIface : Env -> String -> List ImplMethod -> List ResError
checkImplIface env iface methods
  | not (contains iface env.interfaces) = [UnknownInterface iface None]
  | otherwise = flatMap (checkMethodMember iface (ifaceMethodsOf iface env.ifaceMethods)) methods

ifaceMethodsOf : String -> List (String, List String) -> List String
ifaceMethodsOf _ [] = []
ifaceMethodsOf iface ((i, ms)::rest)
  | i == iface = ms
  | otherwise = ifaceMethodsOf iface rest

checkMethodMember : String -> List String -> ImplMethod -> List ResError
checkMethodMember iface known (ImplMethod mname _ _) =
  if contains mname known then
    []
  else
    [MethodNotInInterface mname iface None]

-- ── Primitives (hardcoded, mirror lib/resolve.ml) ────────────────────────
isTupleCtorTyName : String -> Bool
isTupleCtorTyName n =
  contains n ["__tuple2__", "__tuple3__", "__tuple4__", "__tuple5__"]

primitiveTypes : List String
primitiveTypes =
  ["Int", "Float", "String", "Char", "Bool", "Unit", "List", "Ref", "Array"]

primitiveConstructors : List String
primitiveConstructors = ["True", "False"]

-- ── Name extractors (over runtime / prelude / user decls) ─────────────────
externNames : List Decl -> List String
externNames [] = []
externNames ((DExtern _ n _)::rest) = n :: externNames rest
externNames (_::rest) = externNames rest

dataRecordNames : List Decl -> List String
dataRecordNames [] = []
dataRecordNames ((DData _ n _ _ _)::rest) = n :: dataRecordNames rest
dataRecordNames ((DTypeAlias _ n _ _)::rest) = n :: dataRecordNames rest
dataRecordNames ((DNewtype _ n _ _ _ _)::rest) = n :: dataRecordNames rest
dataRecordNames ((DAttrib _ d)::rest) = dataRecordNames (d::rest)
dataRecordNames (_::rest) = dataRecordNames rest

-- user/platform effect labels declared with `effect Foo` (Phase 146 gap 2)
effectNames : List Decl -> List String
effectNames [] = []
effectNames ((DEffect _ n _ _)::rest) = n :: effectNames rest
effectNames ((DAttrib _ d)::rest) = effectNames (d::rest)
effectNames (_::rest) = effectNames rest

ctorNames : List Decl -> List String
ctorNames [] = []
ctorNames ((DData _ _ _ vs _)::rest) = map variantName vs ++ ctorNames rest
ctorNames ((DNewtype _ _ _ con _ _)::rest) = con :: ctorNames rest
ctorNames ((DAttrib _ d)::rest) = ctorNames (d::rest)
ctorNames (_::rest) = ctorNames rest

variantName : Variant -> String
variantName (Variant n _) = n

ifaceMethodNm : IfaceMethod -> String
ifaceMethodNm (IfaceMethod n _ _) = n

implMethodNm : ImplMethod -> String
implMethodNm (ImplMethod n _ _) = n

interfaceList : List Decl -> List (String, List String)
interfaceList [] = []
interfaceList ((DInterface { name = n, methods, ... })::rest) =
  (n, map ifaceMethodNm methods) :: interfaceList rest
interfaceList (_::rest) = interfaceList rest

-- prelude value names (DFunDef/DTypeSig + DImpl & DInterface method names)
preludeValueNames : List Decl -> List String
preludeValueNames [] = []
preludeValueNames ((DFunDef _ n _ _)::rest) = n :: preludeValueNames rest
preludeValueNames ((DTypeSig _ n _)::rest) = n :: preludeValueNames rest
preludeValueNames ((DImpl { methods, ... })::rest) = map implMethodNm methods
  ++ preludeValueNames rest
preludeValueNames ((DInterface { methods, ... })::rest) = map ifaceMethodNm methods
  ++ preludeValueNames rest
preludeValueNames ((DAttrib _ d)::rest) = preludeValueNames (d::rest)
preludeValueNames (_::rest) = preludeValueNames rest

-- user value names (DFunDef/DTypeSig/DExtern + DInterface methods; NOT DImpl)
userValueNames : List Decl -> List String
userValueNames [] = []
userValueNames ((DFunDef _ n _ _)::rest) = n :: userValueNames rest
userValueNames ((DTypeSig _ n _)::rest) = n :: userValueNames rest
userValueNames ((DExtern _ n _)::rest) = n :: userValueNames rest
userValueNames ((DLetGroup _ bs)::rest) = map letBindName bs
  ++ userValueNames rest
userValueNames ((DInterface { methods, ... })::rest) = map ifaceMethodNm methods
  ++ userValueNames rest
userValueNames ((DAttrib _ d)::rest) = userValueNames (d::rest)
userValueNames (_::rest) = userValueNames rest

fieldOwnersOf : List Decl -> List (String, String)
fieldOwnersOf [] = []
fieldOwnersOf ((DData _ _ _ vs _)::rest) = flatMap variantFieldOwners vs
  ++ fieldOwnersOf rest
fieldOwnersOf (_::rest) = fieldOwnersOf rest

recordFieldOwner : String -> Field -> (String, String)
recordFieldOwner owner (Field fname _) = (fname, owner)

variantFieldOwners : Variant -> List (String, String)
variantFieldOwners (Variant cname (ConNamed fs _)) =
  map (recordFieldOwner cname) fs
variantFieldOwners (Variant _ (ConPos _)) = []

-- single-file import stub: names brought into scope (core import = no-op)
importedNames : List Decl -> List String
importedNames [] = []
importedNames ((DUse _ path _)::rest) = useImportNames path
  ++ importedNames rest
importedNames (_::rest) = importedNames rest

useImportNames : UsePath -> List String
useImportNames path = if useModId path == "core" then [] else useStubNames path

useStubNames : UsePath -> List String
useStubNames (UseName ns) = [lastOf ns]
useStubNames (UseGroup _ ms) = map useMemberLocal ms
useStubNames (UseWild _) = []
-- A module alias binds `A.name` per EXPORT, which this single-file stub path cannot
-- enumerate (it has no ModuleExports).  Binding bare `A` here would be a lie — `A`
-- alone is never a value.  A non-core import in a single file is already reported by
-- `singleFileImportErrors`, so contributing nothing is right.
useStubNames (UseAlias _ _) = []

useModId : UsePath -> String
useModId (UseName ns) =
  if listLen ns > 1 then
    joinDot (initList ns)
  else
    firstOr "" ns
useModId (UseGroup ns _) = joinDot ns
useModId (UseWild ns) = joinDot ns
useModId (UseAlias ns _) = joinDot ns

lastOf : List String -> String
lastOf [] = ""
lastOf [x] = x
lastOf (_::rest) = lastOf rest

firstOr : String -> List String -> String
firstOr d [] = d
firstOr _ (x::_) = x

programIsCore : List Decl -> Bool
programIsCore prog = hasOrdering prog && hasFoldable prog

hasOrdering : List Decl -> Bool
hasOrdering [] = False
hasOrdering ((DData _ "Ordering" _ _ _)::_) = True
hasOrdering (_::rest) = hasOrdering rest

hasFoldable : List Decl -> Bool
hasFoldable [] = False
hasFoldable ((DInterface { name = "Foldable", ... })::_) = True
hasFoldable (_::rest) = hasFoldable rest

-- ── build_env ─────────────────────────────────────────────────────────────
buildEnv : List Decl -> List Decl -> List Decl -> List String -> Env
buildEnv runtimeDecls preludeDecls prog internalGuard =
  let seed = not (programIsCore prog)
  let pTypes = whenL seed (dataRecordNames preludeDecls)
  let pCtors = whenL seed (ctorNames preludeDecls)
  let pIfaces = whenL seed (interfaceList preludeDecls)
  let pValues = whenL seed (preludeValueNames preludeDecls)
  let pFieldOwners = whenL seed (fieldOwnersOf preludeDecls)
  let uIfaces = interfaceList prog
  let imported = importedNames prog
  Env {
    values = externNames runtimeDecls ++ pValues ++ userValueNames prog ++ imported,
    types = primitiveTypes ++ pTypes ++ dataRecordNames prog ++ imported,
    ctors = primitiveConstructors ++ pCtors ++ ctorNames prog,
    fields = map fst pFieldOwners ++ map fst (fieldOwnersOf prog),
    fieldOwners = pFieldOwners ++ fieldOwnersOf prog,
    interfaces = map fst pIfaces ++ map fst uIfaces,
    ifaceMethods = pIfaces ++ uIfaces,
    effects = effectNames prog,
    imported = imported,
    importedModuleValues = [],
    ambiguous = [],
    internalGuard = internalGuard,
  }

whenL : Bool -> List a -> List a
whenL True xs = xs
whenL False _ = []

-- ── build-time errors: ExternWithBody + DuplicateDefinition ──────────────
buildErrors : List Decl -> List Decl -> List ResError
buildErrors preludeDecls prog = externWithBodyErrors (externNames prog) prog
  ++ duplicateErrors preludeDecls prog
  ++ contiguityErrors prog
  ++ dupValueBindingErrors prog

-- A nullary top-level VALUE binding (`x = e`, zero params) admits EXACTLY ONE
-- clause: there is no argument to discriminate on, so a second same-named
-- definition silently last-wins at eval → runtime garbage (`intToString: not an
-- Int`).  Flag the 2nd (and later) occurrence.  A multi-clause FUNCTION
-- (`f Red = 1` / `f Green = 2`) is NOT flagged: every clause carries >=1
-- pattern, so `isNullary` is False and the run stays clean.  Runs on the same
-- post-desugar decl list as contiguityErrors; DTypeSig is transparent (a
-- signature between `int : Int` and `int = 4` does not break the run), any other
-- decl (or a differently-named DFunDef) starts a fresh run.
dupValueBindingErrors : List Decl -> List ResError
dupValueBindingErrors prog = dupValGo None False prog

-- run = Some name of the current contiguous same-name DFunDef run; sawNullary =
-- a nullary clause has already appeared in that run.
dupValGo : Option String -> Bool -> List Decl -> List ResError
dupValGo _ _ [] = []
dupValGo run sawNullary (d::rest)
  | isTransparentDecl d = dupValGo run sawNullary rest
  | otherwise = match dupValClause d
    Some (n, isNull, loc) =>
      let continuing = run == Some n
      let dup = continuing && (sawNullary || isNull)
      let errs = whenL dup [DuplicateValueBinding n loc]
      let sawNullary2 = continuing && sawNullary || isNull
      errs ++ dupValGo (Some n) sawNullary2 rest
    None => dupValGo None False rest

-- (name, isNullary, loc) for a single-clause top-level value/function def;
-- None for any decl that is not a DFunDef (starts a fresh run).
dupValClause : Decl -> Option (String, Bool, Option Loc)
dupValClause (DAttrib _ d) = dupValClause d
dupValClause (DFunDef _ n ps body) = Some (n, isEmptyL ps, firstExprLoc body)
dupValClause _ = None

isEmptyL : List a -> Bool
isEmptyL [] = True
isEmptyL _ = False

-- Phase 148: the clauses of a top-level value binding must be contiguous.  Two
-- same-named DFunDef/DLetGroup clause-runs separated by an intervening clause-body
-- decl are silently coalesced into one multi-clause function; flag the gap.
-- Mirrors lib/resolve.ml's check_contiguous_bindings.  Walk decls tracking opened
-- (names in their current contiguous run of clause bodies) and closed (a run that
-- ended); reaching a closed name re-opens it AND is the error.  A clause-body decl
-- closes every open name it does not itself bind.  Type signatures (DTypeSig) are
-- TRANSPARENT — they neither open nor close a run, so the "all sigs, then all
-- defs" grouping of a mutually-recursive pair is accepted.
declBindNames : Decl -> List String
declBindNames (DAttrib _ d) = declBindNames d
declBindNames (DFunDef _ n _ _) = [n]
declBindNames (DLetGroup _ bs) = map letBindName bs
declBindNames _ = []

-- a transparent decl (DTypeSig) is skipped entirely by the contiguity walk
isTransparentDecl : Decl -> Bool
isTransparentDecl (DAttrib _ d) = isTransparentDecl d
isTransparentDecl (DTypeSig _ _ _) = True
isTransparentDecl _ = False

contiguityErrors : List Decl -> List ResError
contiguityErrors prog = contigGo omEmpty [] prog

-- closed = names whose run ended; opened = names in their current run.
--
-- `closed` is an OrdMap-backed SET, not a list: it accumulates every top-level
-- name in the file and is only ever probed for membership (order is irrelevant —
-- error order comes from `ns`).  As a list it made this walk O(N²) in both time
-- and allocation, since every decl rebuilt the whole accumulator (`unionStr`'s
-- `acc ++ [x]`, then `removeAll`'s full copy).  That was ~100% of the resolve
-- stage's cost on a large file.  `opened` stays a list — by construction it never
-- holds more than a single decl's binders (opened2 ⊆ ns), so it is O(1)-sized.
contigGo : OrdMap Unit -> List String -> List Decl -> List ResError
contigGo _ _ [] = []
contigGo closed opened (d::rest)
  | isTransparentDecl d = contigGo closed opened rest
  | otherwise =
    let ns = declBindNames d
    -- close every open name not bound by this decl
    let stillOpen = filterKeepOpen ns opened
    let nowClosed = closeMissing opened stillOpen closed
    -- process this decl's bound names against the closed set
    let errs = newlyDuplicated (declLoc d) nowClosed ns
    -- re-open the names this decl binds (whether fresh or re-opened)
    let opened2 = unionStr stillOpen ns
    -- a re-opened (previously closed) name leaves the closed set; harmless to keep,
    -- but removing it avoids a second spurious flag on a third occurrence
    let closed2 = deleteAllStr ns nowClosed
    errs ++ contigGo closed2 opened2 rest

-- names from `opened` that are still bound by the current decl (stay open)
filterKeepOpen : List String -> List String -> List String
filterKeepOpen _ [] = []
filterKeepOpen ns (o::os)
  | contains o ns = o :: filterKeepOpen ns os
  | otherwise = filterKeepOpen ns os

-- add every `opened` name NOT in `stillOpen` to the closed set
closeMissing : List String -> List String -> OrdMap Unit -> OrdMap Unit
closeMissing [] _ closed = closed
closeMissing (o::os) stillOpen closed
  | contains o stillOpen = closeMissing os stillOpen closed
  | otherwise = closeMissing os stillOpen (omInsert o () closed)

-- drop every name in `ns` from the closed set
deleteAllStr : List String -> OrdMap Unit -> OrdMap Unit
deleteAllStr [] closed = closed
deleteAllStr (n::ns) closed = deleteAllStr ns (omDelete n closed)

-- a bound name that is in the closed set is a non-contiguous re-appearance.
-- Stage B: carry the offending decl's source span (first ELoc in its body, mirror
-- lib/resolve.ml's `decl_loc`).
newlyDuplicated : Option Loc -> OrdMap Unit -> List String -> List ResError
newlyDuplicated _ _ [] = []
newlyDuplicated loc closed (n::ns)
  | omHasKey n closed = DuplicateBinding n loc :: newlyDuplicated loc closed ns
  | otherwise = newlyDuplicated loc closed ns

-- decl_loc: the first ELoc span found in a pre-order walk of a decl's body
-- (mirror lib/resolve.ml's `decl_loc`, which uses Desugar.map_expr to grab the
-- first ELoc).  DFunDef only; other decls have no body span → None.
declLoc : Decl -> Option Loc
declLoc (DAttrib _ d) = declLoc d
declLoc (DFunDef _ _ _ body) = firstExprLoc body
declLoc _ = None

-- First ELoc span in a pre-order traversal of an expr (None if the subtree has
-- no ELoc wrapper).  Pre-order so it matches map_expr's outermost-first order.
firstExprLoc : Expr -> Option Loc
firstExprLoc (ELoc l _) = Some l
firstExprLoc (EApp f x) = orElseLocL (firstExprLoc f) (firstExprLoc x)
firstExprLoc (ELam _ body) = firstExprLoc body
firstExprLoc (ELet _ _ _ e1 e2) = orElseLocL (firstExprLoc e1) (firstExprLoc e2)
firstExprLoc (ELetGroup _ body) = firstExprLoc body
firstExprLoc (EMatch e0 _) = firstExprLoc e0
firstExprLoc (EIf c t el) =
  orElseLocL (firstExprLoc c) (orElseLocL (firstExprLoc t) (firstExprLoc el))
firstExprLoc (EBinOp _ a b _) = orElseLocL (firstExprLoc a) (firstExprLoc b)
firstExprLoc (EUnOp _ a _) = firstExprLoc a
firstExprLoc (EInfix _ a b) = orElseLocL (firstExprLoc a) (firstExprLoc b)
firstExprLoc (EFieldAccess e0 _ _) = firstExprLoc e0
firstExprLoc (ETuple es) = firstLocList es
firstExprLoc (EListLit es) = firstLocList es
firstExprLoc (EArrayLit es) = firstLocList es
firstExprLoc (EAnnot e0 _) = firstExprLoc e0
firstExprLoc (EHeadAnnot e0 _) = firstExprLoc e0
firstExprLoc (ERangeList lo hi _) =
  orElseLocL (firstExprLoc lo) (firstExprLoc hi)
firstExprLoc (ERangeArray lo hi _) =
  orElseLocL (firstExprLoc lo) (firstExprLoc hi)
firstExprLoc (EIndex e0 i _) = orElseLocL (firstExprLoc e0) (firstExprLoc i)
firstExprLoc (ESlice e0 lo hi _ _) =
  orElseLocL (firstExprLoc e0) (orElseLocL (firstExprLoc lo) (firstExprLoc hi))
firstExprLoc (EDoOrigin _ e) = firstExprLoc e
firstExprLoc _ = None

firstLocList : List Expr -> Option Loc
firstLocList [] = None
firstLocList (e::rest) = orElseLocL (firstExprLoc e) (firstLocList rest)

orElseLocL : Option Loc -> Option Loc -> Option Loc
orElseLocL (Some l) _ = Some l
orElseLocL None r = r

unionStr : List String -> List String -> List String
unionStr acc [] = acc
unionStr acc (x::xs)
  | contains x acc = unionStr acc xs
  | otherwise = unionStr (acc ++ [x]) xs

externWithBodyErrors : List String -> List Decl -> List ResError
externWithBodyErrors _ [] = []
externWithBodyErrors externs ((DFunDef _ n _ _)::rest) = (if contains n externs then [ExternWithBody n None] else [])
  ++ externWithBodyErrors externs rest
externWithBodyErrors externs (_::rest) = externWithBodyErrors externs rest

duplicateErrors : List Decl -> List Decl -> List ResError
duplicateErrors preludeDecls prog =
  let seed = not (programIsCore prog)
  let typeSeed = primitiveTypes ++ whenL seed (dataRecordNames preludeDecls)
  let ctorSeed = primitiveConstructors ++ whenL seed (ctorNames preludeDecls)
  let ifaceSeed = whenL seed (map fst (interfaceList preludeDecls))
  map (dupErr "type") (findDups typeSeed (dataRecordNames prog))
    ++ map (dupErr "constructor") (findDups ctorSeed (ctorNames prog))
    ++ map (dupErr "interface") (findDups ifaceSeed (map fst (interfaceList prog)))

dupErr : String -> String -> ResError
dupErr kind n = DuplicateDefinition kind n None

-- names that are already present when declared (order-sensitive, like add_unique)
findDups : List String -> List String -> List String
findDups _ [] = []
findDups seen (n::rest)
  | contains n seen = n :: findDups seen rest
  | otherwise = findDups (n::seen) rest

-- ── Serialization (matches dev/diagdump.ml's sexp_error) ─────────────────
-- The loc field (Stage B) is dropped here — the sexp form mirrors the OCaml
-- diagdump's location-stripped serialization.
export resErrorSexp : ResError -> String
-- NOTE: the suggestion field is deliberately NOT serialized — the sexp feeds the
-- resolve_modules gate and must stay stable (the suggestion is cosmetic).
resErrorSexp (UnboundVariable n _ _) = "(UnboundVariable " ++ escStr n ++ ")"
resErrorSexp (UnboundVariableExported n m _) =
  "(UnboundVariableExported \{escStr n} \{escStr m})"
resErrorSexp (UnknownConstructor n _ _) = "(UnknownConstructor "
  ++ escStr n
  ++ ")"
-- NOTE: the suggestion field is deliberately NOT serialized here either (mirrors
-- UnboundVariable above) — keeps the resolve_modules gate's sexp stable.
resErrorSexp (UnknownType n _ _) = "(UnknownType " ++ escStr n ++ ")"
resErrorSexp (UnknownEffect n _) = "(UnknownEffect " ++ escStr n ++ ")"
resErrorSexp (UnknownField n _) = "(UnknownField " ++ escStr n ++ ")"
resErrorSexp (FieldNotInRecord f r _) =
  "(FieldNotInRecord \{escStr f} \{escStr r})"
resErrorSexp (DuplicateDefinition k n _) =
  "(DuplicateDefinition \{escStr k} \{escStr n})"
resErrorSexp (InternalExternAccess n _) = "(InternalExternAccess "
  ++ escStr n
  ++ ")"
resErrorSexp (UnknownInterface n _) = "(UnknownInterface " ++ escStr n ++ ")"
resErrorSexp (MethodNotInInterface m i _) =
  "(MethodNotInInterface \{escStr m} \{escStr i})"
resErrorSexp (ExternWithBody n _) = "(ExternWithBody " ++ escStr n ++ ")"
resErrorSexp (PrivateNameAccess n m _) =
  "(PrivateNameAccess \{escStr n} \{escStr m})"
resErrorSexp (NoExportedConstructors n m _) =
  "(NoExportedConstructors \{escStr n} \{escStr m})"
resErrorSexp (AbstractFieldAccess t f _) =
  "(AbstractFieldAccess \{escStr t} \{escStr f})"
resErrorSexp (UnknownModule n _) = "(UnknownModule " ++ escStr n ++ ")"
resErrorSexp (NonRecursiveValueLet n _) = "(NonRecursiveValueLet "
  ++ escStr n
  ++ ")"
resErrorSexp (DuplicateBinding n _) = "(DuplicateBinding " ++ escStr n ++ ")"
resErrorSexp (DuplicateValueBinding n _) = "(DuplicateValueBinding "
  ++ escStr n
  ++ ")"
resErrorSexp (DuplicateBinder k n _) =
  "(DuplicateBinder \{escStr k} \{escStr n})"
resErrorSexp (AsPatternMisplaced _) = "AsPatternMisplaced"
resErrorSexp (AmbiguousOccurrence n mods _) = "(AmbiguousOccurrence "
  ++ joinWith " " (escStr n :: map escStr mods)
  ++ ")"
resErrorSexp (ReassignImmutable n _) = "(ReassignImmutable " ++ escStr n ++ ")"

-- String key for an `Option Loc`, used only to distinguish dedup candidates
-- (NOT a serialization contract like resErrorSexp): `None` collapses to a
-- fixed marker (matching UnknownType's un-threaded decl-level errors, which all
-- carry `None`), a real `Loc` renders its span so two errors at DIFFERENT real
-- locations are never conflated.
locKey : Option Loc -> String
locKey None = "-"
locKey (Some (Loc f sl sc el ec)) = "\{f}:\{intToString sl}:\{intToString sc}:\{intToString el}:\{intToString ec}"

-- Collapse consecutive-or-not errors that render identically (same
-- resErrorCode + ppResError message + location).  This mainly hits a typo'd
-- type name reused in more than one position of the same signature (`f :
-- Strng -> Strng`): each occurrence is a genuine separate AST node, but with
-- no real location threaded here (decl-level checks pass `cur = None`,
-- loc-threading is a separate task) the reports are otherwise
-- indistinguishable noise — whereas two errors with the SAME message but
-- DIFFERENT real locations (e.g. the same unbound name used twice in one
-- line) are kept, since the location makes them distinguishable and each is
-- independently actionable. Order-preserving, first occurrence wins.
-- NOTE: keyed on `ppResError`/`resErrorCode` (exhaustive over every ResError
-- constructor), NOT `resErrorSexp`. (`resErrorSexp` is now itself total —
-- including an `InternalExternAccess` arm — but the human `ppResError` key is
-- kept here since it carries the actionable message text.)
dedupResErrors : List ResError -> List ResError
dedupResErrors es = dedupResErrorsGo es []

dedupResErrorsGo : List ResError -> List String -> List ResError
dedupResErrorsGo [] _ = []
dedupResErrorsGo (e::es) seen =
  let key = "\{resErrorCode e}|\{ppResError e}|\{locKey (resErrorLoc e)}"
  if contains key seen then
    dedupResErrorsGo es seen
  else
    e :: dedupResErrorsGo es (key::seen)

-- ── resolve_program ───────────────────────────────────────────────────────
-- runtimeDecls = runtime.mdk externs; preludeDecls = core.mdk; prog = target.
export resolveProgram : List Decl -> List Decl -> List Decl -> List ResError
resolveProgram runtimeDecls preludeDecls prog =
  let env = buildEnv runtimeDecls preludeDecls prog []
  dedupResErrors (buildErrors preludeDecls prog ++ flatMap (checkDecl env) prog)

-- Like resolveProgram but flags references to internal-only externs listed in
-- `internalGuard` (empty ⇒ unrestricted).  The single-file `medaka check` error
-- path passes `internalGuardFor allowInternal`.
export resolveProgramG2 : List String -> List Decl -> List Decl -> List Decl -> List ResError
resolveProgramG2 internalGuard runtimeDecls preludeDecls prog =
  let env = buildEnv runtimeDecls preludeDecls prog internalGuard
  dedupResErrors (buildErrors preludeDecls prog ++ flatMap (checkDecl env) prog)

-- Human-readable message for a ResError (mirrors lib/resolve.ml's pp_error).
-- Used by diagnostics.mdk to produce "error: <msg>" lines.  Loc-independent.
export ppResError : ResError -> String
ppResError (UnboundVariable n _ s) = match s
  Some sug => "Unbound variable: \{n}. Did you mean '\{sug}'"
    ++ haskellNote n sug
  None => "Unbound variable: \{n}"
ppResError (UnboundVariableExported n m _) =
  "Unbound variable: \{n}. (Did you forget to 'import \{m}.{\{n}}'?)"
ppResError (UnknownConstructor n _ s) = match s
  Some sug => "Unknown constructor: \{n}. Did you mean '\{sug}'"
    ++ haskellNote n sug
  None => "Unknown constructor: " ++ n
ppResError (UnknownType n _ s) = match s
  Some sug => "Unknown type: \{n}. Did you mean '\{sug}'" ++ haskellNote n sug
  None => "Unknown type: " ++ n
ppResError (UnknownEffect n _) = "Unknown effect: " ++ n
ppResError (UnknownField n _) = "Unknown field: " ++ n
ppResError (FieldNotInRecord f r _) =
  "Unknown field: \{f}. Record '\{r}' has no field '\{f}'"
ppResError (DuplicateDefinition k n _) = "Duplicate \{k}: \{n}"
ppResError (UnknownInterface n _) = "Unknown interface: " ++ n
ppResError (MethodNotInInterface m i _) =
  "Method '\{m}' is not part of interface '\{i}'"
ppResError (ExternWithBody n _) = "Extern '"
  ++ n
  ++ "' must not have a definition body"
ppResError (PrivateNameAccess n m _) =
  "Module '\{m}' has no exported name '\{n}'"
ppResError (NoExportedConstructors n m _) = "'\{n}' exports no constructors from module '\{m}' (exported abstractly). Remove `(..)` or export with `public export`"
ppResError (AbstractFieldAccess t f _) = "'\{t}' is exported abstractly. Field '\{f}' is not accessible; declare it `public export` to expose its fields"
ppResError (UnknownModule n _) = "Unknown module: " ++ n
ppResError (AsPatternMisplaced _) = "`@` as-patterns are only allowed in a binding position (a lambda parameter, a do-block bind, or a match pattern)"
ppResError (NonRecursiveValueLet n _) = "'\{n}' is not in scope in its own binding. Non-function `let` is not recursive; write `let rec \{n} = ...` (RHS must be a lambda)"
ppResError (DuplicateBinding n _) = "Clauses of '\{n}' must be contiguous. An earlier same-named binding is separated by another declaration; group all clauses (and the signature) together"
ppResError (DuplicateValueBinding n _) = "Duplicate binding '\{n}': it is already defined in this scope. A value binding has exactly one definition — rename this one or remove it"
ppResError (DuplicateBinder k n _) = "Duplicate binder: '\{n}' is bound more than once in this \{k}. Each binder must be distinct — rename one occurrence"
ppResError (AmbiguousOccurrence n mods _) = "Ambiguous occurrence: '\{n}' is exported by \{ambigModPhrase mods}. Qualify, or select with `import <mod>.{\{n}}`"
ppResError (InternalExternAccess n _) = "'"
  ++ n
  ++ "' is an internal-only primitive. Cannot be used outside the standard library (pass --allow-internal to override)"
ppResError (ReassignImmutable n _) = "Cannot reassign '\{n}' — bindings are immutable. To bind a new value, shadow it with `let \{n} = ...`. For mutable state, use a `Ref`: `let \{n} = Ref 0`, then write `\{n} := \{n}.value + 1` (read the cell with `\{n}.value`)"

-- Stable diagnostic code (DIAGNOSTIC-CODES-DESIGN §2) for a resolve error — one
-- `R-*` code per ResError constructor.  Authored here (a single chokepoint), so
-- the two ResError→Diag conversion sites need no per-call-site change.  Codes are
-- append-only; never renumber.
export resErrorCode : ResError -> String
resErrorCode (UnboundVariable _ _ _) = "R-UNBOUND"
resErrorCode (UnboundVariableExported _ _ _) = "R-UNBOUND"
resErrorCode (UnknownConstructor _ _ _) = "R-UNKNOWN-CTOR"
resErrorCode (UnknownType _ _ _) = "R-UNKNOWN-TYPE"
resErrorCode (UnknownEffect _ _) = "R-UNKNOWN-EFFECT"
resErrorCode (UnknownField _ _) = "R-UNKNOWN-FIELD"
resErrorCode (FieldNotInRecord _ _ _) = "R-FIELD-NOT-IN-RECORD"
resErrorCode (DuplicateDefinition _ _ _) = "R-DUPLICATE-DEF"
resErrorCode (UnknownInterface _ _) = "R-UNKNOWN-INTERFACE"
resErrorCode (MethodNotInInterface _ _ _) = "R-METHOD-NOT-IN-INTERFACE"
resErrorCode (ExternWithBody _ _) = "R-EXTERN-WITH-BODY"
resErrorCode (PrivateNameAccess _ _ _) = "R-PRIVATE-NAME"
resErrorCode (NoExportedConstructors _ _ _) = "R-NO-EXPORTED-CTORS"
resErrorCode (AbstractFieldAccess _ _ _) = "R-ABSTRACT-FIELD"
resErrorCode (UnknownModule _ _) = "R-UNKNOWN-MODULE"
resErrorCode (NonRecursiveValueLet _ _) = "R-NONREC-VALUE-LET"
resErrorCode (DuplicateBinding _ _) = "R-DUPLICATE-BINDING"
resErrorCode (DuplicateValueBinding _ _) = "R-DUP-BINDING"
resErrorCode (DuplicateBinder _ _ _) = "R-DUP-BINDER"
resErrorCode (AsPatternMisplaced _) = "R-AS-PATTERN-MISPLACED"
resErrorCode (AmbiguousOccurrence _ _ _) = "R-AMBIGUOUS-OCCURRENCE"
resErrorCode (InternalExternAccess _ _) = "R-INTERNAL-EXTERN"
resErrorCode (ReassignImmutable _ _) = "R-IMMUTABLE-ASSIGN"

-- Mirror lib/resolve.ml's mod_phrase: two modules → "both `a` and `b`";
-- otherwise a comma-separated list of backtick-quoted module names.
ambigModPhrase : List String -> String
ambigModPhrase (a::b::[]) = "both `\{a}` and `\{b}`"
ambigModPhrase mods = joinWith ", " (map (m => "`" ++ m ++ "`") mods)

-- one human-readable error message per line (the harness sorts)
export resolveToLines : List Decl -> List Decl -> List Decl -> String
resolveToLines runtimeDecls preludeDecls prog =
  joinNl (map ppResError (resolveProgram runtimeDecls preludeDecls prog))

-- ── Single-file import validation ─────────────────────────────────────────
-- In single-file mode the loader is absent, so resolve_program stubs unknown
-- imports into scope (mirroring lib/resolve.ml's behaviour when known_modules=[]).
-- This function catches DUse declarations that reference a non-core module and
-- emits UnknownModule — used by check.mdk BEFORE running resolveToLines so the
-- pipeline halts with the correct error category rather than falling through to
-- a spurious typecheck "Unbound variable".
export singleFileImportErrors : List Decl -> List ResError
singleFileImportErrors [] = []
singleFileImportErrors ((DUse _ path _)::rest) =
  let mid = useModId path
  if mid == "core" || mid == "" then
    singleFileImportErrors rest
  else
    UnknownModule mid None :: singleFileImportErrors rest
singleFileImportErrors (_::rest) = singleFileImportErrors rest

-- ══════════════════════════════════════════════════════════════════════════
-- Multi-module path — port of lib/resolve.ml's `resolve_module`.
--
-- Resolves one module against the EXPORTS of previously-resolved modules
-- (dependency-first), so imports are validated against what a module actually
-- makes public — the privacy / abstract-ctor / unknown-module checks the
-- single-file path stubs out (PrivateNameAccess / NoExportedConstructors /
-- UnknownModule).  `buildExports` then computes this module's own public
-- interface, threaded into the next module's `known` set by the driver.
-- ══════════════════════════════════════════════════════════════════════════

-- The public interface of a resolved module (mirror lib/resolve.ml's
-- module_exports; exp_fields is dropped — consumers only read field OWNERS).
public export data ModuleExports = ModuleExports {
    modId : String,
    expValues : List String,
    expTypes : List String,
    expCtors : List String,
    expTypeCtors : List (String, List String),
    expFieldOwners : List (String, String),
    expInterfaces : List String,
    expIfaceMethods : List (String, List String),
    expEffects : List String,  -- exported effect labels (Phase 146)
  }
-- public type → its exported ctors
-- (field, owner type/ctor)

-- iface → method names

-- ── small generic helpers ──────────────────────────────────────────────────
isNonEmpty : List a -> Bool
isNonEmpty [] = False
isNonEmpty _ = True

-- keep the elements of `names` that are members of `domain`
filterContains : List String -> List String -> List String
filterContains _ [] = []
filterContains domain (n::rest)
  | contains n domain = n :: filterContains domain rest
  | otherwise = filterContains domain rest

findExports : String -> List ModuleExports -> Option ModuleExports
findExports _ [] = None
findExports mid (e::rest)
  | e.modId == mid = Some e
  | otherwise = findExports mid rest

-- exported under any value/type/ctor/interface category (lib's imported_names is_pub)
isPubExp : ModuleExports -> String -> Bool
isPubExp exp n = contains n exp.expValues
  || contains n exp.expTypes
  || contains n exp.expCtors
  || contains n exp.expInterfaces

typeCtorsOf : String -> ModuleExports -> Option (List String)
typeCtorsOf name exp = lookupAssoc name exp.expTypeCtors

-- ── usePaths / pubUsePaths ─────────────────────────────────────────────────
usePathsOf : List Decl -> List UsePath
usePathsOf [] = []
usePathsOf ((DUse _ path _)::rest) = path :: usePathsOf rest
usePathsOf (_::rest) = usePathsOf rest

-- Like usePathsOf but keeps each import's own source Loc alongside its path —
-- used only by the collectImports chain, which attaches the loc to any
-- privacy/abstract-ctor error it raises (F3 Chunk B: real range instead of the
-- dummy {0,0}/`<unknown location>`).
usePathLocsOf : List Decl -> List (UsePath, Loc)
usePathLocsOf [] = []
usePathLocsOf ((DUse _ path loc)::rest) = (path, loc) :: usePathLocsOf rest
usePathLocsOf (_::rest) = usePathLocsOf rest

pubUsePaths : List Decl -> List UsePath
pubUsePaths [] = []
pubUsePaths ((DUse True path _)::rest) = path :: pubUsePaths rest
pubUsePaths (_::rest) = pubUsePaths rest

-- ── imported_names + expand_member ─────────────────────────────────────────
-- Names a use-path brings into scope, plus the privacy / abstract-ctor errors.
importedNamesMM : UsePath -> ModuleExports -> (List String, List ResError)
importedNamesMM (UseName ns) exp =
  if listLen ns > 1 then
    let nm = lastOf ns
    ([nm], pubErr exp nm)
  else ([], [])
importedNamesMM (UseGroup _ members) exp =
  let expanded = flatMap (expandMemberNames exp) members
  let names = map localOfExpanded expanded
  let expandErrs = flatMap (expandMemberErrs exp) members
  (names, expandErrs ++ flatMap (pubErrExpanded exp) expanded)
importedNamesMM (UseWild _) exp =
  (exp.expValues ++ exp.expTypes ++ exp.expCtors, [])
-- `import m as A` binds m's exported VALUES as `A.name`, and nothing unqualified.
-- Values only: a qualified reference parses as a field access, whose field must be
-- lowercase, so `A.SomeType` / `A.SomeCtor` cannot be spelled at all (it is a parse
-- error, not a silent miss).  Types and ctors are imported with `import m.{T(..)}`.
importedNamesMM (UseAlias _ a) exp = (map (qualifiedLocal a) exp.expValues, [])

pubErr : ModuleExports -> String -> List ResError
pubErr exp n =
  if isPubExp exp n then
    []
  else
    [PrivateNameAccess n exp.modId None]

-- Like pubErr but carries the offending member's own source Loc (from a
-- UseGroup member) so the diagnostic squiggles just that name, not the whole
-- import statement (RESOLVER-DIAG-LOCATION-DESIGN.md F3 follow-up).
pubErrLoc : ModuleExports -> (String, Loc) -> List ResError
pubErrLoc exp (n, loc) =
  if isPubExp exp n then
    []
  else
    [PrivateNameAccess n exp.modId (Some loc)]

-- expand_member: `T(..)` → the type plus its exported ctors; a plain member is
-- itself.  `T(..)` on an abstractly-exported type is a NoExportedConstructors.
-- Each expanded name carries the source member's own Loc (ctors expanded from
-- `T(..)` inherit T's member loc).
--
-- Each entry is (ORIGIN, LOCAL, loc).  They differ only under a member alias
-- (`import m.{a as b}` → origin `a`, local `b`): the privacy check must ask about the
-- ORIGIN (that is the name m exports), while scope binds the LOCAL.  Conflating the
-- two would make `import m.{privateThing as x}` silently legal.  Ctors expanded from
-- `T(..) as U` keep their OWN names — one alias cannot rename N constructors.
expandMemberNames : ModuleExports -> UseMember -> List (String, String, Loc)
expandMemberNames _ (m@(UseMember name False loc _)) =
  [(name, useMemberLocal m, loc)]
expandMemberNames exp (m@(UseMember name True loc _)) = match typeCtorsOf name exp
  Some ctors => (name, useMemberLocal m, loc) :: map (c => (c, c, loc)) ctors
  None => [(name, useMemberLocal m, loc)]

localOfExpanded : (String, String, Loc) -> String
localOfExpanded (_, local, _) = local

-- privacy is checked against the ORIGIN name, with the member's own Loc.
pubErrExpanded : ModuleExports -> (String, String, Loc) -> List ResError
pubErrExpanded exp (origin, _, loc) = pubErrLoc exp (origin, loc)

expandMemberErrs : ModuleExports -> UseMember -> List ResError
expandMemberErrs _ (UseMember _ False _ _) = []
expandMemberErrs exp (UseMember name True loc _) = match typeCtorsOf name exp
  Some _ => []
  None =>
    if contains name exp.expTypes then
      [NoExportedConstructors name exp.modId (Some loc)]
    else
      []

-- ── import contributions to the env ────────────────────────────────────────
public export data ImportAdds =
  | ImportAdds {
      iaImported : List String,
      iaValues : List String,
      iaTypes : List String,
      iaCtors : List String,
      iaIfaces : List String,
      iaFieldOwners : List (String, String),
      iaErrors : List ResError,
    }

emptyAdds : ImportAdds
emptyAdds = ImportAdds {
  iaImported = [],
  iaValues = [],
  iaTypes = [],
  iaCtors = [],
  iaIfaces = [],
  iaFieldOwners = [],
  iaErrors = [],
}

mergeAdds : ImportAdds -> ImportAdds -> ImportAdds
mergeAdds a b = ImportAdds {
  iaImported = a.iaImported ++ b.iaImported,
  iaValues = a.iaValues ++ b.iaValues,
  iaTypes = a.iaTypes ++ b.iaTypes,
  iaCtors = a.iaCtors ++ b.iaCtors,
  iaIfaces = a.iaIfaces ++ b.iaIfaces,
  iaFieldOwners = a.iaFieldOwners ++ b.iaFieldOwners,
  iaErrors = a.iaErrors ++ b.iaErrors,
}

collectImports : List ModuleExports -> List Decl -> ImportAdds
collectImports known prog = foldImports known (usePathLocsOf prog)

-- ── use-time ambiguity (MAP-SET-AMBIGUITY-DESIGN.md) ───────────────────────
-- The VALUE names a single non-core import contributes, attributed to its
-- DIRECTLY-imported module id (not the original definer → re-export safe).
importValueNames : List ModuleExports -> UsePath -> List String
importValueNames known path =
  if useModId path == "core" then []
  else match findExports (useModId path) known
    None => []
    Some exp =>
      let (names, _) = importedNamesMM path exp
      filterContains exp.expValues names

-- Register one (name, mid) into a name→[mid] assoc, deduping mids.
addProvenance : List (String, List String) -> String -> String -> List (String, List String)
addProvenance [] n mid = [(n, [mid])]
addProvenance ((k, mids)::rest) n mid
  | k == n =
    if contains mid mids then
      (k, mids)::rest
    else
      (k, mids ++ [mid])::rest
  | otherwise = (k, mids) :: addProvenance rest n mid

-- Fold the value names of one import (all tagged with the same mid) into prov.
addImportProvenance : List (String, List String) -> String -> List String -> List (String, List String)
addImportProvenance prov _ [] = prov
addImportProvenance prov mid (n::rest) =
  addImportProvenance (addProvenance prov n mid) mid rest

-- Provenance over every non-core import in the program, in decl order
-- (mirrors lib/resolve.ml's left-to-right List.iter so mod-id order matches).
valueProvenance : List ModuleExports -> List UsePath -> List (String, List String)
valueProvenance known paths = foldProvenance known [] paths

foldProvenance : List ModuleExports -> List (String, List String) -> List UsePath -> List (String, List String)
foldProvenance _ prov [] = prov
foldProvenance known prov (p::rest) =
  let mid = useModId p
  let prov2 = if mid == "core" then
    prov
  else
    addImportProvenance prov mid (importValueNames known p)
  foldProvenance known prov2 rest

-- Keep only names with ≥2 distinct provenances AND no same-module top-level
-- value shadow (a real local def wins).
ambiguousSet : List ModuleExports -> List Decl -> List (String, List String)
ambiguousSet known prog =
  let prov = valueProvenance known (usePathsOf prog)
  let sameMod = userValueNames prog
  keepAmbiguous sameMod prov

keepAmbiguous : List String -> List (String, List String) -> List (String, List String)
keepAmbiguous _ [] = []
keepAmbiguous sameMod ((n, mids)::rest)
  | listLen mids >= 2 && not (contains n sameMod) =
    (n, mids) :: keepAmbiguous sameMod rest
  | otherwise = keepAmbiguous sameMod rest

foldImports : List ModuleExports -> List (UsePath, Loc) -> ImportAdds
foldImports _ [] = emptyAdds
foldImports known ((p, loc)::rest) =
  mergeAdds (oneImport known p loc) (foldImports known rest)

oneImport : List ModuleExports -> UsePath -> Loc -> ImportAdds
oneImport known path loc =
  let mid = useModId path
  if mid == "core" then emptyAdds
  else match findExports mid known
    None => stubOrUnknown known path mid loc
    Some exp => realImport exp path loc

-- module not in `known`: in multi-module mode (known non-empty) this is an
-- UnknownModule; the first module (known empty) keeps the single-file stub.
stubOrUnknown : List ModuleExports -> UsePath -> String -> Loc -> ImportAdds
stubOrUnknown known path mid loc =
  if isNonEmpty known then ImportAdds {
    iaImported = [],
    iaValues = [],
    iaTypes = [],
    iaCtors = [],
    iaIfaces = [],
    iaFieldOwners = [],
    iaErrors = [UnknownModule mid (Some loc)],
  }
  else
    let names = useStubNames path
    ImportAdds {
      iaImported = names,
      iaValues = names,
      iaTypes = names,
      iaCtors = [],
      iaIfaces = [],
      iaFieldOwners = [],
      iaErrors = [],
    }

realImport : ModuleExports -> UsePath -> Loc -> ImportAdds
realImport exp path loc =
  let (names, errs) = importedNamesMM path exp
  ImportAdds {
    iaImported = names,
    iaValues = filterContains exp.expValues names,
    iaTypes = filterContains exp.expTypes names,
    iaCtors = filterContains exp.expCtors names,
    iaIfaces = filterContains exp.expInterfaces names,
    iaFieldOwners = ownedFieldOwners exp exp.expFieldOwners,
    iaErrors = map (withResErrorLoc loc) errs,
  }

-- Attach a real Loc to a ResError that was constructed with `None` (some
-- privacy/abstract-ctor errors — e.g. from the bare `UseName` case in
-- importedNamesMM — carry no loc of their own, only the ModuleExports, not
-- the importing DUse's span). Errors from a UseGroup member (pubErrLoc /
-- expandMemberErrs) already carry that member's own `Some` loc — PRESERVE it
-- rather than clobbering with the whole-statement loc, so the diagnostic
-- squiggles just the offending name.
withResErrorLoc : Loc -> ResError -> ResError
withResErrorLoc loc (PrivateNameAccess n m None) =
  PrivateNameAccess n m (Some loc)
withResErrorLoc _ (PrivateNameAccess n m (Some l)) =
  PrivateNameAccess n m (Some l)
withResErrorLoc loc (NoExportedConstructors n m None) =
  NoExportedConstructors n m (Some loc)
withResErrorLoc _ (NoExportedConstructors n m (Some l)) =
  NoExportedConstructors n m (Some l)
withResErrorLoc _ e = e

-- field-ownership pairs whose owner is an exported type/ctor (copied into scope
-- so field access / record patterns over imported records resolve)
ownedFieldOwners : ModuleExports -> List (String, String) -> List (String, String)
ownedFieldOwners _ [] = []
ownedFieldOwners exp ((f, o)::rest)
  | contains o exp.expTypes || contains o exp.expCtors =
    (f, o) :: ownedFieldOwners exp rest
  | otherwise = ownedFieldOwners exp rest

-- iface-method memberships for imported interfaces (so an `impl` of an imported
-- interface validates against its real method set — Phase 130).  Only for
-- interfaces actually in scope (baseIfaces = prelude + user + imported-by-name).
importedIfaceMethods : List ModuleExports -> List Decl -> List String -> List (String, List String)
importedIfaceMethods known prog baseIfaces =
  flatMap (oneImportIfaceMethods known baseIfaces) (usePathsOf prog)

oneImportIfaceMethods : List ModuleExports -> List String -> UsePath -> List (String, List String)
oneImportIfaceMethods known baseIfaces path =
  let mid = useModId path
  if mid == "core" then []
  else match findExports mid known
    None => []
    Some exp => filterIfaceMethods baseIfaces exp.expIfaceMethods

filterIfaceMethods : List String -> List (String, List String) -> List (String, List String)
filterIfaceMethods _ [] = []
filterIfaceMethods baseIfaces ((iface, ms)::rest)
  | contains iface baseIfaces =
    (iface, ms) :: filterIfaceMethods baseIfaces rest
  | otherwise = filterIfaceMethods baseIfaces rest

-- Install exported effect labels from all imported modules (Phase 146).
importedEffects : List ModuleExports -> List Decl -> List String
importedEffects known prog = flatMap (oneImportEffects known) (usePathsOf prog)

oneImportEffects : List ModuleExports -> UsePath -> List String
oneImportEffects known path =
  let mid = useModId path
  if mid == "core" then []
  else match findExports mid known
    None => []
    Some exp => exp.expEffects

-- ── buildEnv (multi-module): like buildEnv but validating imports ──────────
buildEnvMM : List Decl -> List Decl -> List ModuleExports -> List Decl -> List String -> (Env, List ResError)
buildEnvMM runtimeDecls preludeDecls known prog internalGuard =
  let seed = not (programIsCore prog)
  let pTypes = whenL seed (dataRecordNames preludeDecls)
  let pCtors = whenL seed (ctorNames preludeDecls)
  let pIfaces = whenL seed (interfaceList preludeDecls)
  let pValues = whenL seed (preludeValueNames preludeDecls)
  let pFieldOwners = whenL seed (fieldOwnersOf preludeDecls)
  let uIfaces = interfaceList prog
  let adds = collectImports known prog
  let baseIfaces = map fst pIfaces ++ map fst uIfaces ++ adds.iaIfaces
  let impIfaceMethods = importedIfaceMethods known prog baseIfaces
  let impEffects = importedEffects known prog
  let impModValues = importedModuleValueSets known prog
  let env = Env {
    values = externNames runtimeDecls ++ pValues ++ userValueNames prog ++ adds.iaValues,
    types = primitiveTypes ++ pTypes ++ dataRecordNames prog ++ adds.iaTypes,
    ctors = primitiveConstructors ++ pCtors ++ ctorNames prog ++ adds.iaCtors,
    fields = map fst pFieldOwners ++ map fst (fieldOwnersOf prog) ++ map fst adds.iaFieldOwners,
    fieldOwners = pFieldOwners ++ fieldOwnersOf prog ++ adds.iaFieldOwners,
    interfaces = baseIfaces,
    ifaceMethods = pIfaces ++ uIfaces ++ impIfaceMethods,
    effects = effectNames prog ++ impEffects,
    imported = adds.iaImported,
    importedModuleValues = impModValues,
    ambiguous = ambiguousSet known prog,
    internalGuard = internalGuard,
  }
  (env, adds.iaErrors)

-- (modId, expValues) pairs for every non-`core` import in the program,
-- regardless of import form (bare `UseName`, selective `UseGroup`, wildcard) —
-- used only to answer "is this unbound name exported by a module I already
-- import?" (audit #5), not to bind any names into scope.
importedModuleValueSets : List ModuleExports -> List Decl -> List (String, List String)
importedModuleValueSets known prog =
  flatMap (oneImportedModuleValues known) (usePathsOf prog)

oneImportedModuleValues : List ModuleExports -> UsePath -> List (String, List String)
oneImportedModuleValues known path =
  let mid = useModId path
  if mid == "core" then []
  else match findExports mid known
    None => []
    Some exp => [(mid, exp.expValues)]

-- ── build_exports ──────────────────────────────────────────────────────────
buildExports : List ModuleExports -> String -> List Decl -> Env -> ModuleExports
buildExports known modId prog env = ModuleExports {
  modId = modId,
  expValues = expValuesDirect prog ++ publicIfaceMethodVals prog env ++ reExpValues known prog,
  expTypes = expTypesDirect prog ++ reExpTypes known prog,
  expCtors = expCtorsDirect prog ++ reExpCtors known prog,
  expTypeCtors = expTypeCtorsDirect prog,
  expFieldOwners = expFieldOwnersDirect prog ++ reExpFieldOwners known prog,
  expInterfaces = expInterfacesDirect prog ++ reExpInterfaces known prog,
  expIfaceMethods = expIfaceMethodsDirect prog ++ reExpIfaceMethods known prog,
  expEffects = expEffectsDirect prog ++ reExpEffects known prog,
}

-- pub DTypeSig/DExtern/DFunDef
expValuesDirect : List Decl -> List String
expValuesDirect [] = []
expValuesDirect ((DTypeSig True n _)::rest) = n :: expValuesDirect rest
expValuesDirect ((DExtern True n _)::rest) = n :: expValuesDirect rest
expValuesDirect ((DFunDef True n _ _)::rest) = n :: expValuesDirect rest
expValuesDirect (_::rest) = expValuesDirect rest

-- methods of PUBLIC interfaces that are bound as values (lib's final iter loop)
publicIfaceMethodVals : List Decl -> Env -> List String
publicIfaceMethodVals prog env =
  flatMap (keepBoundMethods env) (pubIfaceMethodSets prog)

keepBoundMethods : Env -> List String -> List String
keepBoundMethods env ms = filterContains env.values ms

pubIfaceMethodSets : List Decl -> List (List String)
pubIfaceMethodSets [] = []
pubIfaceMethodSets ((DInterface { pub = True, methods, ... })::rest) =
  map ifaceMethodNm methods :: pubIfaceMethodSets rest
pubIfaceMethodSets (_::rest) = pubIfaceMethodSets rest

-- pub newtype + VisPublic/VisAbstract data & record (the type name only)
expTypesDirect : List Decl -> List String
expTypesDirect [] = []
expTypesDirect ((DNewtype True n _ _ _ _)::rest) = n :: expTypesDirect rest
expTypesDirect ((DData VisPublic n _ _ _)::rest) = n :: expTypesDirect rest
expTypesDirect ((DData VisAbstract n _ _ _)::rest) = n :: expTypesDirect rest
expTypesDirect ((DTypeAlias True n _ _)::rest) = n :: expTypesDirect rest
expTypesDirect (_::rest) = expTypesDirect rest

-- pub newtype ctor + VisPublic data ctors (VisAbstract exports NO ctors)
expCtorsDirect : List Decl -> List String
expCtorsDirect [] = []
expCtorsDirect ((DNewtype True _ _ con _ _)::rest) = con :: expCtorsDirect rest
expCtorsDirect ((DData VisPublic _ _ vs _)::rest) = map variantName vs
  ++ expCtorsDirect rest
expCtorsDirect (_::rest) = expCtorsDirect rest

expTypeCtorsDirect : List Decl -> List (String, List String)
expTypeCtorsDirect [] = []
expTypeCtorsDirect ((DNewtype True n _ con _ _)::rest) =
  (n, [con]) :: expTypeCtorsDirect rest
expTypeCtorsDirect ((DData VisPublic n _ vs _)::rest) =
  (n, map variantName vs) :: expTypeCtorsDirect rest
expTypeCtorsDirect (_::rest) = expTypeCtorsDirect rest

-- field owners for PUBLIC data (named-field variants) + record
expFieldOwnersDirect : List Decl -> List (String, String)
expFieldOwnersDirect [] = []
expFieldOwnersDirect ((DData VisPublic _ _ vs _)::rest) = flatMap variantFieldOwners vs
  ++ expFieldOwnersDirect rest
expFieldOwnersDirect (_::rest) = expFieldOwnersDirect rest

expInterfacesDirect : List Decl -> List String
expInterfacesDirect [] = []
expInterfacesDirect ((DInterface { pub = True, name = n, ... })::rest) =
  n :: expInterfacesDirect rest
expInterfacesDirect (_::rest) = expInterfacesDirect rest

expIfaceMethodsDirect : List Decl -> List (String, List String)
expIfaceMethodsDirect [] = []
expIfaceMethodsDirect ((DInterface { pub = True, name = n, methods, ... })::rest) = (n, map ifaceMethodNm methods) :: expIfaceMethodsDirect rest
expIfaceMethodsDirect (_::rest) = expIfaceMethodsDirect rest

expEffectsDirect : List Decl -> List String
expEffectsDirect [] = []
expEffectsDirect ((DEffect True n _ _)::rest) = n :: expEffectsDirect rest
expEffectsDirect (_::rest) = expEffectsDirect rest

reExpEffects : List ModuleExports -> List Decl -> List String
reExpEffects known prog =
  flatMap (overPubUse known reExpEffectsFrom) (pubUsePaths prog)

reExpEffectsFrom : UsePath -> ModuleExports -> List String
reExpEffectsFrom (UseWild _) src = src.expEffects
reExpEffectsFrom _ _ = []

-- ── pub-import re-export (export import …) — mirror lib's reexport_name ──────
-- The names a pub use-path re-exports from its source module (errors suppressed
-- here — they were already reported when the module imported them).
-- (ORIGIN, LOCAL) per re-exported name.  The origin is what the SOURCE module exports
-- (so it is what the `filterContains src.expX` guards below must test); the local is
-- the name THIS module re-exports it under.  They differ only for a member alias
-- (`export import m.{a as b}` re-exports m's `a` as `b`).
--
-- A whole-module alias is absent on purpose: `export import m as A` is rejected in the
-- parser.  Re-exporting `A.f` would export a name no importer could write without
-- knowing our private alias.
reexportBindings : UsePath -> ModuleExports -> List (String, String)
reexportBindings (UseName ns) _ =
  if listLen ns > 1 then
    let n = lastOf ns
    [(n, n)]
  else []
reexportBindings (UseGroup _ members) src =
  map dropLocOfExpanded (flatMap (expandMemberNames src) members)
reexportBindings (UseWild _) src =
  map
    selfBinding
    (src.expValues ++ src.expTypes ++ src.expCtors ++ src.expInterfaces)
reexportBindings (UseAlias _ _) _ = []

dropLocOfExpanded : (String, String, Loc) -> (String, String)
dropLocOfExpanded (origin, local, _) = (origin, local)

selfBinding : String -> (String, String)
selfBinding n = (n, n)

-- the LOCAL names whose ORIGIN is one of `origins` (the source module's export list of
-- the relevant kind).  This is the aliased form of the old `filterContains`.
localsExportedFrom : List String -> List (String, String) -> List String
localsExportedFrom origins bindings =
  map snd (filterList (b => contains (fst b) origins) bindings)

reExpValues : List ModuleExports -> List Decl -> List String
reExpValues known prog =
  flatMap (overPubUse known reExpValuesFrom) (pubUsePaths prog)

reExpValuesFrom : UsePath -> ModuleExports -> List String
reExpValuesFrom path src =
  let bindings = reexportBindings path src
  localsExportedFrom src.expValues bindings
    ++ flatMap (ifaceValsOf src) (map fst bindings)

ifaceValsOf : ModuleExports -> String -> List String
ifaceValsOf src n =
  if contains n src.expInterfaces then
    filterContains src.expValues (ifaceMethodsOf n src.expIfaceMethods)
  else
    []

reExpTypes : List ModuleExports -> List Decl -> List String
reExpTypes known prog =
  flatMap (overPubUse known reExpTypesFrom) (pubUsePaths prog)

reExpTypesFrom : UsePath -> ModuleExports -> List String
reExpTypesFrom path src =
  localsExportedFrom src.expTypes (reexportBindings path src)

reExpCtors : List ModuleExports -> List Decl -> List String
reExpCtors known prog =
  flatMap (overPubUse known reExpCtorsFrom) (pubUsePaths prog)

reExpCtorsFrom : UsePath -> ModuleExports -> List String
reExpCtorsFrom path src =
  localsExportedFrom src.expCtors (reexportBindings path src)

reExpInterfaces : List ModuleExports -> List Decl -> List String
reExpInterfaces known prog =
  flatMap (overPubUse known reExpInterfacesFrom) (pubUsePaths prog)

-- Interfaces / types / ctors / field owners key off the ORIGIN name: only a VALUE
-- member can carry an alias (parser-enforced), so for these kinds origin == local and
-- the origin list is exactly the old behaviour.  Keying an interface by an alias would
-- be unsound anyway — impl coherence is resolved on the real interface name globally.
reexportOrigins : UsePath -> ModuleExports -> List String
reexportOrigins path src = map fst (reexportBindings path src)

reExpInterfacesFrom : UsePath -> ModuleExports -> List String
reExpInterfacesFrom path src =
  filterContains src.expInterfaces (reexportOrigins path src)

reExpIfaceMethods : List ModuleExports -> List Decl -> List (String, List String)
reExpIfaceMethods known prog =
  flatMap (overPubUse known reExpIfaceMethodsFrom) (pubUsePaths prog)

reExpIfaceMethodsFrom : UsePath -> ModuleExports -> List (String, List String)
reExpIfaceMethodsFrom path src =
  ifaceMethodPairs
    src
    (filterContains src.expInterfaces (reexportOrigins path src))

ifaceMethodPairs : ModuleExports -> List String -> List (String, List String)
ifaceMethodPairs _ [] = []
ifaceMethodPairs src (i::rest) =
  (i, ifaceMethodsOf i src.expIfaceMethods) :: ifaceMethodPairs src rest

reExpFieldOwners : List ModuleExports -> List Decl -> List (String, String)
reExpFieldOwners known prog =
  flatMap (overPubUse known reExpFieldOwnersFrom) (pubUsePaths prog)

reExpFieldOwnersFrom : UsePath -> ModuleExports -> List (String, String)
reExpFieldOwnersFrom path src =
  ownersForTypes
    (filterContains src.expTypes (reexportOrigins path src))
    src.expFieldOwners

ownersForTypes : List String -> List (String, String) -> List (String, String)
ownersForTypes _ [] = []
ownersForTypes types ((f, o)::rest)
  | contains o types = (f, o) :: ownersForTypes types rest
  | otherwise = ownersForTypes types rest

-- run `f` against a pub use-path's resolved source exports (skip core/unknown)
overPubUse : List ModuleExports -> (UsePath -> ModuleExports -> List b) -> UsePath -> List b
overPubUse known f path =
  let mid = useModId path
  if mid == "core" then []
  else match findExports mid known
    None => []
    Some src => f path src

-- ── resolve_module + multi-module driver ───────────────────────────────────
export resolveModule : List Decl -> List Decl -> List ModuleExports -> String -> List Decl -> (ModuleExports, List ResError)
resolveModule runtimeDecls preludeDecls known modId prog =
  resolveModuleG [] runtimeDecls preludeDecls known modId prog

-- Like resolveModule but with an explicit internal-extern guard list for this
-- module (empty ⇒ trusted: a stdlib module, or `--allow-internal`).
export resolveModuleG : List String -> List Decl -> List Decl -> List ModuleExports -> String -> List Decl -> (ModuleExports, List ResError)
resolveModuleG internalGuard runtimeDecls preludeDecls known modId prog =
  let (env, importErrs) = buildEnvMM runtimeDecls preludeDecls known prog internalGuard
  let errs = dedupResErrors (buildErrors preludeDecls prog ++ importErrs ++ flatMap (checkDecl env) prog)
  let exp = buildExports known modId prog env
  (exp, errs)

-- thread resolveModule over modules in dependency-first order, accumulating
-- exports; collect the union of every module's errors (the harness sorts).
resolveModulesErrors : List Decl -> List Decl -> List ModuleExports -> List (String, List Decl) -> List ResError
resolveModulesErrors rt pre known mods =
  resolveModulesErrorsG True [] rt pre known mods

-- Guarded variant: a module is trusted (no internal-extern restriction) when
-- `allowInternal` is set OR its modId is in `trustedMods` (the stdlib-owned
-- modules, per the loader's owning-root).  Untrusted modules get the
-- internalExterns guard list.
resolveModulesErrorsG : Bool -> List String -> List Decl -> List Decl -> List ModuleExports -> List (String, List Decl) -> List ResError
resolveModulesErrorsG _ _ _ _ _ [] = []
resolveModulesErrorsG allowInternal trustedMods rt pre known ((mid, prog)::rest) =
  let guard = if allowInternal || contains mid trustedMods then
    []
  else
    internalExterns
  let (exp, errs) = resolveModuleG guard rt pre known mid prog
  errs
    ++ resolveModulesErrorsG allowInternal trustedMods rt pre (exp::known) rest

-- one S-expression per diagnostic (the harness sorts); matches
-- `diagdump --resolve-modules` over the same ordered module list.
export resolveModulesToLines : List Decl -> List Decl -> List (String, List Decl) -> String
resolveModulesToLines runtimeDecls preludeDecls mods =
  joinNl (map
    resErrorSexp
    (resolveModulesErrors runtimeDecls preludeDecls [] mods))

-- Guarded variant of resolveModulesToLines (S-expr output) for the `medaka check`
-- exit-code predicate: `allowInternal` / `trustedMods` decide per-module trust.
export resolveModulesToLinesG : Bool -> List String -> List Decl -> List Decl -> List (String, List Decl) -> String
resolveModulesToLinesG allowInternal trustedMods runtimeDecls preludeDecls mods = joinNl (map resErrorSexp (resolveModulesErrorsG allowInternal trustedMods runtimeDecls preludeDecls [] mods))

-- HUMANE multi-module resolve diagnostics for the `medaka check` CLI (vs the
-- S-expression `resolveModulesToLines`, which the differential resolve-modules
-- harness diffs).  Each error is rendered through `ppResError` with a location
-- prefix mirroring the OCaml oracle: `file:line:col: msg` when located, else
-- `<unknown location>: msg` (PrivateNameAccess et al. carry no loc).  Kept
-- separate so `resolveModulesToLines`'s sexp output stays byte-stable for the
-- harness golden.
export resolveModulesToHumane : List Decl -> List Decl -> List (String, List Decl) -> String
resolveModulesToHumane runtimeDecls preludeDecls mods =
  joinNl (map
    ppResErrorLocated
    (resolveModulesErrors runtimeDecls preludeDecls [] mods))

-- Guarded variant of resolveModulesToHumane for the run/build/check CLI:
-- `allowInternal` / `trustedMods` decide per-module internal-extern trust.
export resolveModulesToHumaneG : Bool -> List String -> List Decl -> List Decl -> List (String, List Decl) -> String
resolveModulesToHumaneG allowInternal trustedMods runtimeDecls preludeDecls mods = joinNl (map ppResErrorLocated (resolveModulesErrorsG allowInternal trustedMods runtimeDecls preludeDecls [] mods))

-- Like resolveModulesToHumaneG but with an explicit fallback FILE for a loc
-- whose own `file` is empty (F3 Chunk B: `DUse`'s captured Loc is always ""
-- — the multi-module loader (`loadProgram`) never carries per-module file
-- paths, unlike its `*Files*` siblings — so an import-validation error, e.g.
-- `PrivateNameAccess`/`NoExportedConstructors`/`UnknownModule`, can only be
-- attributed to the CLI's own entry file, not necessarily the module that
-- actually declared the offending `import`).  Correct when the failing import
-- is in the entry module (the common case); a transitive dependency's own bad
-- import still degrades gracefully to the entry file rather than the old
-- `<unknown location>`.
export resolveModulesToHumaneGF : String -> Bool -> List String -> List Decl -> List Decl -> List (String, List Decl) -> String
resolveModulesToHumaneGF fallbackFile allowInternal trustedMods runtimeDecls preludeDecls mods = joinNl (map (ppResErrorLocatedF fallbackFile) (resolveModulesErrorsG allowInternal trustedMods runtimeDecls preludeDecls [] mods))

-- A single located humane line for a resolve error.
export ppResErrorLocated : ResError -> String
ppResErrorLocated e = ppResErrorLocatedF "" e

-- Like ppResErrorLocated but substitutes `fallbackFile` for a located error
-- whose own Loc carries an empty file (see resolveModulesToHumaneGF).
export ppResErrorLocatedF : String -> ResError -> String
ppResErrorLocatedF fallbackFile e = match resErrorLoc e
  None => "<unknown location>: " ++ ppResError e
  Some (Loc f sl sc _ _) =>
    let ff = if f == "" then fallbackFile else f
    "\{ff}:\{intToString sl}:\{intToString sc}: \{ppResError e}"
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Addr" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberLocal" false) (mem "qualifiedLocal" false) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false) (mem "omDelete" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "editDistance" false) (mem "minI" false) (mem "maxI" false) (mem "listLen" false) (mem "escStr" false) (mem "joinNl" false) (mem "joinWith" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "initList" false) (mem "joinDot" false) (mem "filterList" false))))
(DData Public "ResError" () ((variant "UnboundVariable" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")))) (variant "UnboundVariableExported" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownConstructor" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")))) (variant "UnknownType" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")))) (variant "UnknownEffect" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownField" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "FieldNotInRecord" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateDefinition" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownInterface" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "MethodNotInInterface" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "ExternWithBody" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "PrivateNameAccess" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "NoExportedConstructors" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AbstractFieldAccess" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownModule" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "NonRecursiveValueLet" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateBinding" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateValueBinding" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateBinder" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AsPatternMisplaced" (ConPos (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AmbiguousOccurrence" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "InternalExternAccess" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "ReassignImmutable" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DTypeSig true "resErrorDidYouMean" (TyFun (TyCon "ResError") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "resErrorDidYouMean" ((PCon "UnboundVariable" (PVar "n") PWild (PCon "Some" (PVar "sug")))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "sug"))))
(DFunDef false "resErrorDidYouMean" ((PCon "UnknownConstructor" (PVar "n") PWild (PCon "Some" (PVar "sug")))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "sug"))))
(DFunDef false "resErrorDidYouMean" ((PCon "UnknownType" (PVar "n") PWild (PCon "Some" (PVar "sug")))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "sug"))))
(DFunDef false "resErrorDidYouMean" (PWild) (EVar "None"))
(DTypeSig true "resErrorLoc" (TyFun (TyCon "ResError") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "resErrorLoc" ((PCon "UnboundVariable" PWild (PVar "l") PWild)) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnboundVariableExported" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownConstructor" PWild (PVar "l") PWild)) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownType" PWild (PVar "l") PWild)) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownEffect" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownField" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "FieldNotInRecord" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateDefinition" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownInterface" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "MethodNotInInterface" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "ExternWithBody" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "PrivateNameAccess" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "NoExportedConstructors" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AbstractFieldAccess" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownModule" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "NonRecursiveValueLet" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateBinding" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateValueBinding" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateBinder" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AsPatternMisplaced" (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AmbiguousOccurrence" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "InternalExternAccess" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "ReassignImmutable" PWild (PVar "l"))) (EVar "l"))
(DData Public "Env" () ((variant "Env" (ConNamed (field "values" (TyApp (TyCon "List") (TyCon "String"))) (field "types" (TyApp (TyCon "List") (TyCon "String"))) (field "ctors" (TyApp (TyCon "List") (TyCon "String"))) (field "fields" (TyApp (TyCon "List") (TyCon "String"))) (field "fieldOwners" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "interfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "ifaceMethods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "effects" (TyApp (TyCon "List") (TyCon "String"))) (field "imported" (TyApp (TyCon "List") (TyCon "String"))) (field "importedModuleValues" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "ambiguous" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "internalGuard" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig true "internalExterns" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "internalExterns" () (EListLit (ELit (LString "arrayGetUnsafe")) (ELit (LString "arraySetUnsafe")) (ELit (LString "arrayBlit")) (ELit (LString "arrayFill")) (ELit (LString "bytesToFloat64"))))
(DTypeSig true "internalGuardFor" (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "internalGuardFor" ((PCon "True")) (EListLit))
(DFunDef false "internalGuardFor" ((PCon "False")) (EVar "internalExterns"))
(DTypeSig false "ownersOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ownersOf" (PWild (PList)) (EListLit))
(DFunDef false "ownersOf" ((PVar "field") (PCons (PTuple (PVar "f") (PVar "owner")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "f") (EVar "field")) (EBinOp "::" (EVar "owner") (EApp (EApp (EVar "ownersOf") (EVar "field")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ownersOf") (EVar "field")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "patBindings" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patBindings" ((PCon "PVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "patBindings" ((PCon "PWild")) (EListLit))
(DFunDef false "patBindings" ((PCon "PLit" PWild)) (EListLit))
(DFunDef false "patBindings" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "a")) (EApp (EVar "patBindings") (EVar "b"))))
(DFunDef false "patBindings" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PAs" (PVar "x") (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patBindings") (EVar "p"))))
(DFunDef false "patBindings" ((PCon "PRng" PWild PWild PWild)) (EListLit))
(DFunDef false "patBindings" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "flatMap") (EVar "recFieldBindings")) (EVar "fields")))
(DTypeSig false "recFieldBindings" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" (PVar "fname") (PCon "None"))) (EListLit (EVar "fname")))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patBindings") (EVar "p")))
(DTypeSig false "patsBindings" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patsBindings" ((PVar "ps")) (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")))
(DTypeSig false "patGroupDupErrors" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "patGroupDupErrors" ((PVar "loc") (PVar "kind") (PVar "ps")) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EApp (EVar "DuplicateBinder") (EVar "kind")) (EVar "n")) (EVar "loc")))) (EApp (EApp (EVar "findDups") (EListLit)) (EApp (EVar "patsBindings") (EVar "ps")))))
(DTypeSig false "checkType" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyCon" (PVar "n") (PVar "loc"))) (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "env") "types")) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "env") "imported"))) (EApp (EVar "isTupleCtorTyName") (EVar "n"))) (EListLit) (EListLit (EApp (EApp (EApp (EVar "UnknownType") (EVar "n")) (EApp (EApp (EVar "orElseLocL") (EVar "loc")) (EVar "cur"))) (EApp (EApp (EVar "suggestType") (EVar "env")) (EVar "n"))))))
(DFunDef false "checkType" (PWild PWild (PCon "TyVar" PWild)) (EListLit))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "a")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "b"))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "a")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "b"))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env"))) (EVar "ts")))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyEffect" (PVar "labels") PWild (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkEffect") (EVar "cur")) (EVar "env"))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "labels"))) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkConstraint") (EVar "cur")) (EVar "env"))) (EVar "cs")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DTypeSig false "builtInEffects" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "builtInEffects" () (EListLit (ELit (LString "IO")) (ELit (LString "Mut")) (ELit (LString "Panic")) (ELit (LString "Rand")) (ELit (LString "Stdout")) (ELit (LString "Stderr")) (ELit (LString "Stdin")) (ELit (LString "Clock")) (ELit (LString "Env")) (ELit (LString "Exec")) (ELit (LString "Net")) (ELit (LString "FileRead")) (ELit (LString "FileWrite"))))
(DTypeSig false "checkEffect" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkEffect" ((PVar "cur") (PVar "env") (PVar "e")) (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "e")) (EVar "builtInEffects")) (EApp (EApp (EVar "contains") (EVar "e")) (EFieldAccess (EVar "env") "effects"))) (EListLit) (EListLit (EApp (EApp (EVar "UnknownEffect") (EVar "e")) (EVar "cur")))))
(DTypeSig false "checkConstraint" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkConstraint" ((PVar "cur") (PVar "env") (PCon "Constraint" (PVar "iface") (PVar "args"))) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces")) (EListLit) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "cur")))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env"))) (EVar "args"))))
(DTypeSig false "checkPat" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PCon" (PVar "c") (PVar "ps"))) (EBinOp "++" (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "c")) (EFieldAccess (EVar "env") "ctors")) (EApp (EApp (EVar "contains") (EVar "c")) (EFieldAccess (EVar "env") "imported"))) (EListLit) (EListLit (EApp (EApp (EApp (EVar "UnknownConstructor") (EVar "c")) (EVar "cur")) (EApp (EVar "suggestCtor") (EVar "c"))))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "ps"))))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "a")) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "b"))))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "ps")))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "ps")))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PAs" PWild (PVar "p"))) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PRec" (PVar "name") (PVar "fields") PWild)) (EApp (EApp (EApp (EApp (EVar "checkRecPat") (EVar "cur")) (EVar "env")) (EVar "name")) (EVar "fields")))
(DFunDef false "checkPat" (PWild PWild PWild) (EListLit))
(DTypeSig false "checkRecPat" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkRecPat" ((PVar "cur") (PVar "env") (PVar "name") (PVar "fields")) (EBinOp "++" (EApp (EApp (EApp (EVar "recPatHead") (EVar "cur")) (EVar "env")) (EVar "name")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkRecField") (EVar "cur")) (EVar "env")) (EVar "name"))) (EVar "fields"))))
(DTypeSig false "recPatHead" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "recPatHead" ((PVar "cur") (PVar "env") (PVar "name")) (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "env") "types")) (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "env") "ctors"))) (EListLit) (EListLit (EApp (EApp (EApp (EVar "UnknownType") (EVar "name")) (EVar "cur")) (EApp (EApp (EVar "suggestType") (EVar "env")) (EVar "name"))))))
(DTypeSig false "checkRecField" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkRecField" ((PVar "cur") (PVar "env") (PVar "owner") (PCon "RecPatField" (PVar "fname") (PVar "popt"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "fieldCheck") (EVar "cur")) (EVar "env")) (EVar "owner")) (EVar "fname")) (EApp (EApp (EApp (EVar "recFieldSub") (EVar "cur")) (EVar "env")) (EVar "popt"))))
(DTypeSig false "fieldCheck" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "fieldCheck" ((PVar "cur") (PVar "env") (PVar "owner") (PVar "fname")) (EBlock (DoLet false false (PVar "owners") (EApp (EApp (EVar "ownersOf") (EVar "fname")) (EFieldAccess (EVar "env") "fieldOwners"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "fieldVerdict") (EVar "cur")) (EVar "env")) (EVar "owner")) (EVar "fname")) (EVar "owners")))))
(DTypeSig false "fieldVerdict" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "fieldVerdict" ((PVar "cur") (PVar "env") (PVar "owner") (PVar "fname") (PList)) (EIf (EBinOp "&&" (EApp (EApp (EVar "contains") (EVar "owner")) (EFieldAccess (EVar "env") "types")) (EApp (EVar "not") (EApp (EApp (EVar "ownsAnyField") (EVar "owner")) (EFieldAccess (EVar "env") "fieldOwners")))) (EListLit (EApp (EApp (EApp (EVar "AbstractFieldAccess") (EVar "owner")) (EVar "fname")) (EVar "cur"))) (EListLit (EApp (EApp (EVar "UnknownField") (EVar "fname")) (EVar "cur")))))
(DFunDef false "fieldVerdict" ((PVar "cur") (PVar "env") (PVar "owner") (PVar "fname") (PVar "owners")) (EIf (EApp (EApp (EVar "contains") (EVar "owner")) (EVar "owners")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "FieldNotInRecord") (EVar "fname")) (EVar "owner")) (EVar "cur")))))
(DTypeSig false "ownsAnyField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "ownsAnyField" (PWild (PList)) (EVar "False"))
(DFunDef false "ownsAnyField" ((PVar "owner") (PCons (PTuple PWild (PVar "o")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "o") (EVar "owner")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "ownsAnyField") (EVar "owner")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recFieldSub" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "Option") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "recFieldSub" (PWild PWild (PCon "None")) (EListLit))
(DFunDef false "recFieldSub" ((PVar "cur") (PVar "env") (PCon "Some" (PVar "p"))) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")))
(DTypeSig false "checkExpr" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "ELit" PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "ENumLit" PWild PWild PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EMethodRef" PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EDictApp" PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EVarAt" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EVarAt is introduced by annotateProgram after resolve"))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EMethodAt" PWild PWild PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EMethodAt is introduced by typecheck elaboration after resolve"))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EDictAt" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EDictAt is introduced by typecheck elaboration after resolve"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EVar" (PVar "n"))) (EApp (EApp (EApp (EApp (EVar "checkVar") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "n")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "f")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "x"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ELam" (PVar "pats") (PVar "body"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "parameter list"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EBinOp "++" (EApp (EVar "patsBindings") (EVar "pats")) (EVar "scope"))) (EVar "body"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ELet" PWild (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkLet") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "isRec")) (EVar "pat")) (EVar "e1")) (EVar "e2")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EVar "checkLetGroup") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "binds")) (EVar "body")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkArm") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "arms"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "c")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "t"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "el"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "b"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "a")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkVar") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "op")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "b"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EMapLit" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EMapLit is lowered to fromEntries by desugar before resolve"))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "ESetLit" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: ESetLit is lowered to fromEntries by desugar before resolve"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "es")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "es")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "es")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "lo")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "hi"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "lo")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "hi"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "hi"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "i"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "checkStmts") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "stmts")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EDo" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "checkStmts") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "stmts")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkInterp") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "parts")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkGuardArm") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "arms")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERecordCreate" (PVar "name") (PVar "fs"))) (EApp (EApp (EApp (EApp (EApp (EVar "checkRecordCreate") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "name")) (EVar "fs")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "checkRecordUpdate") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EVar "fs")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EVariantUpdate" (PVar "con") (PVar "e0") (PVar "fs"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EApp (EApp (EVar "checkRecordCreate") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "con")) (EVar "fs"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EAsPat" PWild (PVar "e0"))) (EBinOp "::" (EApp (EVar "AsPatternMisplaced") (EVar "cur")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ESection" (PVar "s"))) (EApp (EApp (EApp (EApp (EVar "checkSection") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "s")))
(DFunDef false "checkExpr" (PWild (PVar "env") (PVar "scope") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EApp (EVar "Some") (EVar "l"))) (EVar "env")) (EVar "scope")) (EVar "e")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkVar" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkVar" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "n")) (EIf (EApp (EVar "isHint") (EVar "n")) (EListLit) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "scope"))) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "env") "internalGuard"))) (EListLit (EApp (EApp (EVar "InternalExternAccess") (EVar "n")) (EVar "cur"))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "lookupValue") (EVar "env")) (EVar "scope")) (EVar "n"))) (EApp (EApp (EApp (EApp (EVar "unboundVarErrors") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "n")) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "scope"))) (EApp (EApp (EVar "isAmbiguous") (EVar "env")) (EVar "n"))) (EListLit (EApp (EApp (EApp (EVar "AmbiguousOccurrence") (EVar "n")) (EApp (EApp (EVar "ambigMods") (EVar "env")) (EVar "n"))) (EVar "cur"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "unboundVarErrors" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "unboundVarErrors" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "n")) (EMatch (EApp (EApp (EVar "modulesExportingName") (EVar "env")) (EVar "n")) (arm (PCons (PVar "m") PWild) () (EListLit (EApp (EApp (EApp (EVar "UnboundVariableExported") (EVar "n")) (EVar "m")) (EVar "cur")))) (arm (PList) () (EListLit (EApp (EApp (EApp (EVar "UnboundVariable") (EVar "n")) (EVar "cur")) (EApp (EApp (EApp (EVar "suggestName") (EVar "env")) (EVar "scope")) (EVar "n")))))))
(DTypeSig false "modulesExportingName" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "modulesExportingName" ((PVar "env") (PVar "n")) (EApp (EApp (EVar "flatMap") (EApp (EVar "matchesExport") (EVar "n"))) (EFieldAccess (EVar "env") "importedModuleValues")))
(DTypeSig false "matchesExport" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "matchesExport" ((PVar "n") (PTuple (PVar "mid") (PVar "vals"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "vals")) (EListLit (EVar "mid")) (EListLit)))
(DTypeSig false "isAmbiguous" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isAmbiguous" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ambiguous")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "ambigMods" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ambigMods" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ambiguous")) (arm (PCon "Some" (PVar "mods")) () (EVar "mods")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "isHint" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHint" ((PVar "n")) (EApp (EVar "startsWithAt") (EApp (EVar "stringToChars") (EVar "n"))))
(DTypeSig false "startsWithAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Bool")))
(DFunDef false "startsWithAt" ((PVar "cs")) (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")) (ELit (LChar "@")))))
(DTypeSig false "lookupValue" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "lookupValue" ((PVar "env") (PVar "scope") (PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "n")) (EVar "scope")) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "env") "values"))) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "env") "ctors"))) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "env") "imported"))))
(DTypeSig false "haskellTypeAliases" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellTypeAliases" () (EListLit (ETuple (ELit (LString "Functor")) (ELit (LString "Mappable"))) (ETuple (ELit (LString "Monad")) (ELit (LString "Thenable"))) (ETuple (ELit (LString "Maybe")) (ELit (LString "Option"))) (ETuple (ELit (LString "Either")) (ELit (LString "Result")))))
(DTypeSig false "haskellValueAliases" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellValueAliases" () (EListLit (ETuple (ELit (LString "fmap")) (ELit (LString "map"))) (ETuple (ELit (LString "return")) (ELit (LString "pure"))) (ETuple (ELit (LString "show")) (ELit (LString "debug"))) (ETuple (ELit (LString "mappend")) (ELit (LString "append"))) (ETuple (ELit (LString "mempty")) (ELit (LString "empty"))) (ETuple (ELit (LString "foldr")) (ELit (LString "foldRight"))) (ETuple (ELit (LString "foldl")) (ELit (LString "fold"))) (ETuple (ELit (LString "error")) (ELit (LString "panic"))) (ETuple (ELit (LString "undefined")) (ELit (LString "panic")))))
(DTypeSig false "haskellCtorAliases" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellCtorAliases" () (EListLit (ETuple (ELit (LString "Just")) (ELit (LString "Some"))) (ETuple (ELit (LString "Nothing")) (ELit (LString "None"))) (ETuple (ELit (LString "Left")) (ELit (LString "Err"))) (ETuple (ELit (LString "Right")) (ELit (LString "Ok")))))
(DTypeSig false "isHaskellAliasPair" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isHaskellAliasPair" ((PVar "bad") (PVar "sug")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "optStrEq") (EApp (EApp (EVar "lookupAssoc") (EVar "bad")) (EVar "haskellTypeAliases"))) (EVar "sug")) (EApp (EApp (EVar "optStrEq") (EApp (EApp (EVar "lookupAssoc") (EVar "bad")) (EVar "haskellValueAliases"))) (EVar "sug"))) (EApp (EApp (EVar "optStrEq") (EApp (EApp (EVar "lookupAssoc") (EVar "bad")) (EVar "haskellCtorAliases"))) (EVar "sug"))))
(DTypeSig false "optStrEq" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "optStrEq" ((PCon "Some" (PVar "x")) (PVar "sug")) (EBinOp "==" (EVar "x") (EVar "sug")))
(DFunDef false "optStrEq" ((PCon "None") PWild) (EVar "False"))
(DTypeSig false "haskellNote" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellNote" ((PVar "bad") (PVar "sug")) (EIf (EApp (EApp (EVar "isHaskellAliasPair") (EVar "bad")) (EVar "sug")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " ('")) (EApp (EVar "display") (EVar "bad"))) (ELit (LString "' is Haskell; Medaka uses '"))) (EApp (EVar "display") (EVar "sug"))) (ELit (LString "')"))) (ELit (LString ""))))
(DTypeSig false "suggestName" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "suggestName" ((PVar "env") (PVar "scope") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EBinOp "++" (EVar "haskellValueAliases") (EVar "haskellCtorAliases"))) (arm (PCon "Some" (PVar "sug")) () (EApp (EVar "Some") (EVar "sug"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "suggestNameFuzzy") (EVar "env")) (EVar "scope")) (EVar "n")))))
(DTypeSig false "suggestNameFuzzy" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "suggestNameFuzzy" ((PVar "env") (PVar "scope") (PVar "n")) (EIf (EBinOp "<" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 3))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "lim") (EApp (EApp (EVar "minI") (ELit (LInt 2))) (EApp (EApp (EVar "maxI") (ELit (LInt 1))) (EBinOp "/" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 3)))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "bestOf") (EVar "n")) (EVar "lim")) (EVar "scope")) (arm (PCon "Some" (PVar "best")) () (EApp (EVar "Some") (EVar "best"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "bestOf") (EVar "n")) (EVar "lim")) (EBinOp "++" (EBinOp "++" (EFieldAccess (EVar "env") "values") (EFieldAccess (EVar "env") "ctors")) (EFieldAccess (EVar "env") "imported"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "suggestType" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "suggestType" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "haskellTypeAliases")) (arm (PCon "Some" (PVar "sug")) () (EApp (EVar "Some") (EVar "sug"))) (arm (PCon "None") () (EApp (EApp (EVar "suggestTypeFuzzy") (EVar "env")) (EVar "n")))))
(DTypeSig false "suggestTypeFuzzy" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "suggestTypeFuzzy" ((PVar "env") (PVar "n")) (EIf (EBinOp "<" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 3))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "lim") (EApp (EApp (EVar "minI") (ELit (LInt 2))) (EApp (EApp (EVar "maxI") (ELit (LInt 1))) (EBinOp "/" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 3)))))) (DoExpr (EApp (EApp (EApp (EVar "bestOf") (EVar "n")) (EVar "lim")) (EBinOp "++" (EFieldAccess (EVar "env") "types") (EFieldAccess (EVar "env") "imported"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "suggestCtor" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "suggestCtor" ((PVar "n")) (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "haskellCtorAliases")))
(DTypeSig false "bestOf" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "bestOf" ((PVar "n") (PVar "lim") (PVar "cands")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "best") PWild)) (EVar "best"))) (EApp (EApp (EApp (EApp (EVar "bestCandidate") (EVar "n")) (EVar "lim")) (EVar "cands")) (EVar "None"))))
(DTypeSig false "bestCandidate" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "bestCandidate" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "bestCandidate" ((PVar "n") (PVar "lim") (PCons (PVar "c") (PVar "cs")) (PVar "acc")) (EIf (EBinOp "==" (EVar "c") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "bestCandidate") (EVar "n")) (EVar "lim")) (EVar "cs")) (EVar "acc")) (EIf (EBinOp ">" (EApp (EApp (EVar "editDistance") (EVar "n")) (EVar "c")) (EVar "lim")) (EApp (EApp (EApp (EApp (EVar "bestCandidate") (EVar "n")) (EVar "lim")) (EVar "cs")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "bestCandidate") (EVar "n")) (EVar "lim")) (EVar "cs")) (EApp (EApp (EApp (EVar "keepBetter") (EVar "c")) (EApp (EApp (EVar "editDistance") (EVar "n")) (EVar "c"))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "keepBetter" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "keepBetter" ((PVar "c") (PVar "d") (PCon "None")) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))))
(DFunDef false "keepBetter" ((PVar "c") (PVar "d") (PCon "Some" (PTuple (PVar "bc") (PVar "bd")))) (EIf (EBinOp "<" (EVar "d") (EVar "bd")) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "d") (EVar "bd")) (EBinOp "<" (EVar "c") (EVar "bc"))) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))) (EIf (EVar "otherwise") (EApp (EVar "Some") (ETuple (EVar "bc") (EVar "bd"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "checkLet" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError"))))))))))
(DFunDef false "checkLet" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "True") (PCon "PVar" (PVar "f")) (PVar "e1") (PVar "e2")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EBinOp "::" (EVar "f") (EVar "scope"))) (EVar "e1")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EBinOp "::" (EVar "f") (EVar "scope"))) (EVar "e2"))))
(DFunDef false "checkLet" ((PVar "cur") (PVar "env") (PVar "scope") PWild (PVar "pat") (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "bound") (EApp (EVar "patBindings") (EVar "pat"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "pat")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "pat")))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteNonRec") (EVar "bound"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e1")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EBinOp "++" (EVar "bound") (EVar "scope"))) (EVar "e2"))))))
(DTypeSig false "rewriteNonRec" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ResError") (TyCon "ResError"))))
(DFunDef false "rewriteNonRec" ((PVar "bound") (PCon "UnboundVariable" (PVar "n") (PVar "l") (PVar "s"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "bound")) (EApp (EApp (EVar "NonRecursiveValueLet") (EVar "n")) (EVar "l")) (EApp (EApp (EApp (EVar "UnboundVariable") (EVar "n")) (EVar "l")) (EVar "s"))))
(DFunDef false "rewriteNonRec" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "checkLetGroup" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkLetGroup" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "binds") (PVar "body")) (EBlock (DoLet false false (PVar "scope2") (EBinOp "++" (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")) (EVar "scope"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkLetBind") (EVar "cur")) (EVar "env")) (EVar "scope2"))) (EVar "binds")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "checkLetBind" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkLetBind" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EBinOp "++" (EApp (EApp (EApp (EVar "letBindDupErrors") (EVar "cur")) (EVar "n")) (EVar "clauses")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkFunClause") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "clauses"))))
(DTypeSig false "letBindDupErrors" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "letBindDupErrors" ((PVar "cur") (PVar "n") (PVar "clauses")) (EIf (EApp (EVar "hasNullaryClause") (EVar "clauses")) (EApp (EApp (EApp (EApp (EVar "dupClauseTail") (EVar "cur")) (EVar "n")) (EVar "False")) (EVar "clauses")) (EListLit)))
(DTypeSig false "hasNullaryClause" (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Bool")))
(DFunDef false "hasNullaryClause" ((PList)) (EVar "False"))
(DFunDef false "hasNullaryClause" ((PCons (PCon "FunClause" (PVar "ps") PWild) (PVar "rest"))) (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "ps")) (EApp (EVar "hasNullaryClause") (EVar "rest"))))
(DTypeSig false "dupClauseTail" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "dupClauseTail" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "dupClauseTail" ((PVar "cur") (PVar "n") (PVar "seen") (PCons (PCon "FunClause" PWild (PVar "body")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "whenL") (EVar "seen")) (EListLit (EApp (EApp (EVar "DuplicateValueBinding") (EVar "n")) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "cur"))))) (EApp (EApp (EApp (EApp (EVar "dupClauseTail") (EVar "cur")) (EVar "n")) (EVar "True")) (EVar "rest"))))
(DTypeSig false "checkFunClause" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkFunClause" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "patLoc") (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "cur"))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EVar "patLoc")) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "patLoc")) (ELit (LString "parameter list"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EBinOp "++" (EApp (EVar "patsBindings") (EVar "pats")) (EVar "scope"))) (EVar "body"))))))
(DTypeSig false "checkArm" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkArm" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "Arm" (PVar "pat") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "scope0") (EBinOp "++" (EApp (EVar "patBindings") (EVar "pat")) (EVar "scope"))) (DoLet false false (PTuple (PVar "gErrs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkArmGuards") (EVar "cur")) (EVar "env")) (EVar "scope0")) (EVar "gs"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "pat")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "pat")))) (EVar "gErrs")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "checkArmGuards" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "ResError")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "checkArmGuards" (PWild PWild (PVar "scope") (PList)) (ETuple (EListLit) (EVar "scope")))
(DFunDef false "checkArmGuards" ((PVar "cur") (PVar "env") (PVar "scope") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rErrs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkArmGuards") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EVar "rErrs")) (EVar "scope2")))))
(DFunDef false "checkArmGuards" ((PVar "cur") (PVar "env") (PVar "scope") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p"))) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p"))))) (DoLet false false (PTuple (PVar "rErrs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkArmGuards") (EVar "cur")) (EVar "env")) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EVar "scope"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EVar "here") (EVar "rErrs")) (EVar "scope2")))))
(DTypeSig false "checkGuardArm" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkGuardArm" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkGuard") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "gs")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "body"))))
(DTypeSig false "checkGuard" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkGuard" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "GBool" (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DFunDef false "checkGuard" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "GBind" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkStmts" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkStmts" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "checkStmts" ((PVar "cur") (PVar "env") (PVar "scope") (PCons (PVar "s") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "errs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkStmt") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "s"))) (DoExpr (EBinOp "++" (EVar "errs") (EApp (EApp (EApp (EApp (EVar "checkStmts") (EVar "cur")) (EVar "env")) (EVar "scope2")) (EVar "rest"))))))
(DTypeSig false "checkStmt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "DoStmt") (TyTuple (TyApp (TyCon "List") (TyCon "ResError")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoExpr" (PVar "e"))) (ETuple (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EVar "scope")))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoBind" (PVar "p") (PVar "e"))) (ETuple (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EVar "scope"))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoLet" PWild (PCon "False") (PVar "p") (PVar "e"))) (ETuple (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EVar "scope"))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoLet" PWild (PCon "True") (PVar "p") (PVar "e"))) (ETuple (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EVar "scope"))) (EVar "e"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EVar "scope"))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoAssign" (PVar "x") (PVar "e"))) (ETuple (EBinOp "::" (EApp (EApp (EVar "ReassignImmutable") (EVar "x")) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "e"))) (EVar "cur"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e"))) (EVar "scope")))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoFieldAssign" PWild PWild (PVar "e"))) (ETuple (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EVar "scope")))
(DTypeSig false "checkInterp" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkInterp" (PWild PWild PWild (PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "checkInterp" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "InterpExpr" (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkFieldAssign" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkFieldAssign" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "FieldAssign" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkRecordCreate" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkRecordCreate" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "name") (PVar "fs")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "recCreateHead") (EVar "cur")) (EVar "env")) (EVar "name")) (EVar "fs")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkFieldAssign") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "fs"))))
(DTypeSig false "recCreateHead" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "recCreateHead" ((PVar "cur") (PVar "env") (PVar "name") (PVar "fs")) (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "env") "types")) (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "env") "imported"))) (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "env") "ctors"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "recCreateField") (EVar "cur")) (EVar "env")) (EVar "name"))) (EVar "fs")) (EIf (EVar "otherwise") (EListLit (EApp (EApp (EApp (EVar "UnknownType") (EVar "name")) (EVar "cur")) (EApp (EApp (EVar "suggestType") (EVar "env")) (EVar "name")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recCreateField" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "recCreateField" ((PVar "cur") (PVar "env") (PVar "owner") (PCon "FieldAssign" (PVar "fname") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "fieldVerdict") (EVar "cur")) (EVar "env")) (EVar "owner")) (EVar "fname")) (EApp (EApp (EVar "ownersOf") (EVar "fname")) (EFieldAccess (EVar "env") "fieldOwners"))))
(DTypeSig false "checkRecordUpdate" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkRecordUpdate" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "e0") (PVar "fs")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "recUpdateField") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "fs"))))
(DTypeSig false "recUpdateField" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "recUpdateField" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "FieldAssign" (PVar "fname") (PVar "v"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "v")) (EApp (EApp (EApp (EVar "fieldKnownErr") (EVar "cur")) (EVar "env")) (EVar "fname"))))
(DTypeSig false "fieldKnownErr" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "fieldKnownErr" ((PVar "cur") (PVar "env") (PVar "fname")) (EApp (EApp (EApp (EVar "recUpdateVerdict") (EVar "cur")) (EVar "fname")) (EApp (EApp (EVar "ownersOf") (EVar "fname")) (EFieldAccess (EVar "env") "fieldOwners"))))
(DTypeSig false "recUpdateVerdict" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "recUpdateVerdict" ((PVar "cur") (PVar "fname") (PList)) (EListLit (EApp (EApp (EVar "UnknownField") (EVar "fname")) (EVar "cur"))))
(DFunDef false "recUpdateVerdict" (PWild PWild PWild) (EListLit))
(DTypeSig false "checkSection" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Section") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkSection" (PWild PWild PWild (PCon "SecBare" PWild)) (EListLit))
(DFunDef false "checkSection" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "SecRight" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DFunDef false "checkSection" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "SecLeft" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkDecl" (TyFun (TyCon "Env") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DFunDef" PWild PWild (PVar "pats") (PVar "body"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EApp (EVar "firstExprLoc") (EVar "body"))) (ELit (LString "parameter list"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EVar "patsBindings") (EVar "pats"))) (EVar "body"))))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkLetBind") (EVar "None")) (EVar "env")) (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")))) (EVar "binds")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DTypeSig" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DExtern" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DData" PWild PWild PWild (PVar "vs") PWild)) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkVariant") (EVar "env"))) (EVar "vs")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DProp" PWild PWild (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EVar "checkProp") (EVar "env")) (EVar "params")) (EVar "body")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DTest" PWild PWild (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EListLit)) (EVar "body")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DBench" PWild PWild (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EListLit)) (EVar "body")))
(DFunDef false "checkDecl" ((PVar "env") (PRec "DInterface" ((rf "supers" None) (rf "methods" None)) true)) (EApp (EApp (EApp (EVar "checkInterfaceDecl") (EVar "env")) (EVar "supers")) (EVar "methods")))
(DFunDef false "checkDecl" ((PVar "env") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) true)) (EApp (EApp (EApp (EApp (EApp (EVar "checkImplDecl") (EVar "env")) (EVar "iface")) (EVar "tys")) (EVar "reqs")) (EVar "methods")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DTypeAlias" PWild PWild PWild (PVar "rhs"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "rhs")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DNewtype" PWild PWild PWild PWild (PVar "fty") PWild)) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "fty")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DAttrib" PWild (PVar "inner"))) (EApp (EApp (EVar "checkDecl") (EVar "env")) (EVar "inner")))
(DFunDef false "checkDecl" (PWild PWild) (EListLit))
(DTypeSig false "checkVariant" (TyFun (TyCon "Env") (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkVariant" ((PVar "env") (PCon "Variant" PWild (PCon "ConPos" (PVar "tys")))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env"))) (EVar "tys")))
(DFunDef false "checkVariant" ((PVar "env") (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkFieldType") (EVar "env"))) (EVar "fs")))
(DTypeSig false "checkFieldType" (TyFun (TyCon "Env") (TyFun (TyCon "Field") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkFieldType" ((PVar "env") (PCon "Field" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DTypeSig false "checkProp" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkProp" ((PVar "env") (PVar "params") (PVar "body")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "checkPropParamTy") (EVar "env"))) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EApp (EVar "map") (EVar "propParamName")) (EVar "params"))) (EVar "body"))))
(DTypeSig false "checkPropParamTy" (TyFun (TyCon "Env") (TyFun (TyCon "PropParam") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkPropParamTy" ((PVar "env") (PCon "PropParam" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DTypeSig false "propParamName" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "propParamName" ((PCon "PropParam" (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "checkInterfaceDecl" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "Super")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkInterfaceDecl" ((PVar "env") (PVar "supers") (PVar "methods")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "checkSuper") (EVar "env"))) (EVar "supers")) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkIfaceMethod") (EVar "env"))) (EVar "methods"))))
(DTypeSig false "checkSuper" (TyFun (TyCon "Env") (TyFun (TyCon "Super") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkSuper" ((PVar "env") (PCon "Super" (PVar "iface") PWild)) (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces")) (EListLit) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "None")))))
(DTypeSig false "checkIfaceMethod" (TyFun (TyCon "Env") (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkIfaceMethod" ((PVar "env") (PCon "IfaceMethod" PWild (PVar "t") (PCon "None"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DFunDef false "checkIfaceMethod" ((PVar "env") (PCon "IfaceMethod" PWild (PVar "t") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "env"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EVar "patsBindings") (EVar "pats"))) (EVar "body"))))
(DTypeSig false "checkImplDecl" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkImplDecl" ((PVar "env") (PVar "iface") (PVar "tyargs") (PVar "reqs") (PVar "methods")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env"))) (EVar "tyargs")) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkRequire") (EVar "env"))) (EVar "reqs"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkImplMethod") (EVar "env"))) (EVar "methods"))) (EApp (EApp (EApp (EVar "checkImplIface") (EVar "env")) (EVar "iface")) (EVar "methods"))))
(DTypeSig false "checkRequire" (TyFun (TyCon "Env") (TyFun (TyCon "Require") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkRequire" ((PVar "env") (PCon "Require" (PVar "iface") (PVar "tys"))) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces")) (EListLit) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "None")))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env"))) (EVar "tys"))))
(DTypeSig false "checkImplMethod" (TyFun (TyCon "Env") (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkImplMethod" ((PVar "env") (PCon "ImplMethod" PWild (PVar "pats") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EVar "patsBindings") (EVar "pats"))) (EVar "body"))))
(DTypeSig false "checkImplIface" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkImplIface" ((PVar "env") (PVar "iface") (PVar "methods")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces"))) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "None"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkMethodMember") (EVar "iface")) (EApp (EApp (EVar "ifaceMethodsOf") (EVar "iface")) (EFieldAccess (EVar "env") "ifaceMethods")))) (EVar "methods")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifaceMethodsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceMethodsOf" (PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodsOf" ((PVar "iface") (PCons (PTuple (PVar "i") (PVar "ms")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "i") (EVar "iface")) (EVar "ms") (EIf (EVar "otherwise") (EApp (EApp (EVar "ifaceMethodsOf") (EVar "iface")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "checkMethodMember" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkMethodMember" ((PVar "iface") (PVar "known") (PCon "ImplMethod" (PVar "mname") PWild PWild)) (EIf (EApp (EApp (EVar "contains") (EVar "mname")) (EVar "known")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "MethodNotInInterface") (EVar "mname")) (EVar "iface")) (EVar "None")))))
(DTypeSig false "isTupleCtorTyName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isTupleCtorTyName" ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EListLit (ELit (LString "__tuple2__")) (ELit (LString "__tuple3__")) (ELit (LString "__tuple4__")) (ELit (LString "__tuple5__")))))
(DTypeSig false "primitiveTypes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "primitiveTypes" () (EListLit (ELit (LString "Int")) (ELit (LString "Float")) (ELit (LString "String")) (ELit (LString "Char")) (ELit (LString "Bool")) (ELit (LString "Unit")) (ELit (LString "List")) (ELit (LString "Ref")) (ELit (LString "Array"))))
(DTypeSig false "primitiveConstructors" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "primitiveConstructors" () (EListLit (ELit (LString "True")) (ELit (LString "False"))))
(DTypeSig false "externNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "externNames" ((PList)) (EListLit))
(DFunDef false "externNames" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "externNames") (EVar "rest"))))
(DFunDef false "externNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "externNames") (EVar "rest")))
(DTypeSig false "dataRecordNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dataRecordNames" ((PList)) (EListLit))
(DFunDef false "dataRecordNames" ((PCons (PCon "DData" PWild (PVar "n") PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PCon "DTypeAlias" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PCon "DNewtype" PWild (PVar "n") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "dataRecordNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "dataRecordNames") (EVar "rest")))
(DTypeSig false "effectNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "effectNames" ((PList)) (EListLit))
(DFunDef false "effectNames" ((PCons (PCon "DEffect" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "effectNames") (EVar "rest"))))
(DFunDef false "effectNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "effectNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "effectNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "effectNames") (EVar "rest")))
(DTypeSig false "ctorNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ctorNames" ((PList)) (EListLit))
(DFunDef false "ctorNames" ((PCons (PCon "DData" PWild PWild PWild (PVar "vs") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "variantName")) (EVar "vs")) (EApp (EVar "ctorNames") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons (PCon "DNewtype" PWild PWild PWild (PVar "con") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "con") (EApp (EVar "ctorNames") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "ctorNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "ctorNames") (EVar "rest")))
(DTypeSig false "variantName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "ifaceMethodNm" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodNm" ((PCon "IfaceMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "implMethodNm" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodNm" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "interfaceList" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "interfaceList" ((PList)) (EListLit))
(DFunDef false "interfaceList" ((PCons (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods"))) (EApp (EVar "interfaceList") (EVar "rest"))))
(DFunDef false "interfaceList" ((PCons PWild (PVar "rest"))) (EApp (EVar "interfaceList") (EVar "rest")))
(DTypeSig false "preludeValueNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "preludeValueNames" ((PList)) (EListLit))
(DFunDef false "preludeValueNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PRec "DImpl" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "implMethodNm")) (EVar "methods")) (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "preludeValueNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "preludeValueNames") (EVar "rest")))
(DTypeSig false "userValueNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "userValueNames" ((PList)) (EListLit))
(DFunDef false "userValueNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DLetGroup" PWild (PVar "bs")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "bs")) (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "userValueNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "userValueNames") (EVar "rest")))
(DTypeSig false "fieldOwnersOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "fieldOwnersOf" ((PList)) (EListLit))
(DFunDef false "fieldOwnersOf" ((PCons (PCon "DData" PWild PWild PWild (PVar "vs") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "variantFieldOwners")) (EVar "vs")) (EApp (EVar "fieldOwnersOf") (EVar "rest"))))
(DFunDef false "fieldOwnersOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "fieldOwnersOf") (EVar "rest")))
(DTypeSig false "recordFieldOwner" (TyFun (TyCon "String") (TyFun (TyCon "Field") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "recordFieldOwner" ((PVar "owner") (PCon "Field" (PVar "fname") PWild)) (ETuple (EVar "fname") (EVar "owner")))
(DTypeSig false "variantFieldOwners" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "variantFieldOwners" ((PCon "Variant" (PVar "cname") (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EApp (EVar "map") (EApp (EVar "recordFieldOwner") (EVar "cname"))) (EVar "fs")))
(DFunDef false "variantFieldOwners" ((PCon "Variant" PWild (PCon "ConPos" PWild))) (EListLit))
(DTypeSig false "importedNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "importedNames" ((PList)) (EListLit))
(DFunDef false "importedNames" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EVar "useImportNames") (EVar "path")) (EApp (EVar "importedNames") (EVar "rest"))))
(DFunDef false "importedNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "importedNames") (EVar "rest")))
(DTypeSig false "useImportNames" (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "useImportNames" ((PVar "path")) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EListLit) (EApp (EVar "useStubNames") (EVar "path"))))
(DTypeSig false "useStubNames" (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "useStubNames" ((PCon "UseName" (PVar "ns"))) (EListLit (EApp (EVar "lastOf") (EVar "ns"))))
(DFunDef false "useStubNames" ((PCon "UseGroup" PWild (PVar "ms"))) (EApp (EApp (EVar "map") (EVar "useMemberLocal")) (EVar "ms")))
(DFunDef false "useStubNames" ((PCon "UseWild" PWild)) (EListLit))
(DFunDef false "useStubNames" ((PCon "UseAlias" PWild PWild)) (EListLit))
(DTypeSig false "useModId" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useModId" ((PCon "UseName" (PVar "ns"))) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EVar "joinDot") (EApp (EVar "initList") (EVar "ns"))) (EApp (EApp (EVar "firstOr") (ELit (LString ""))) (EVar "ns"))))
(DFunDef false "useModId" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModId" ((PCon "UseWild" (PVar "ns"))) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModId" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DTypeSig false "lastOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastOf" ((PList)) (ELit (LString "")))
(DFunDef false "lastOf" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastOf") (EVar "rest")))
(DTypeSig false "firstOr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "firstOr" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "firstOr" (PWild (PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "programIsCore" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "programIsCore" ((PVar "prog")) (EBinOp "&&" (EApp (EVar "hasOrdering") (EVar "prog")) (EApp (EVar "hasFoldable") (EVar "prog"))))
(DTypeSig false "hasOrdering" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasOrdering" ((PList)) (EVar "False"))
(DFunDef false "hasOrdering" ((PCons (PCon "DData" PWild (PLit (LString "Ordering")) PWild PWild PWild) PWild)) (EVar "True"))
(DFunDef false "hasOrdering" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasOrdering") (EVar "rest")))
(DTypeSig false "hasFoldable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasFoldable" ((PList)) (EVar "False"))
(DFunDef false "hasFoldable" ((PCons (PRec "DInterface" ((rf "name" (PLit (LString "Foldable")))) true) PWild)) (EVar "True"))
(DFunDef false "hasFoldable" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasFoldable") (EVar "rest")))
(DTypeSig false "buildEnv" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Env"))))))
(DFunDef false "buildEnv" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog") (PVar "internalGuard")) (EBlock (DoLet false false (PVar "seed") (EApp (EVar "not") (EApp (EVar "programIsCore") (EVar "prog")))) (DoLet false false (PVar "pTypes") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "dataRecordNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pCtors") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "ctorNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pIfaces") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "interfaceList") (EVar "preludeDecls")))) (DoLet false false (PVar "pValues") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "preludeValueNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pFieldOwners") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "fieldOwnersOf") (EVar "preludeDecls")))) (DoLet false false (PVar "uIfaces") (EApp (EVar "interfaceList") (EVar "prog"))) (DoLet false false (PVar "imported") (EApp (EVar "importedNames") (EVar "prog"))) (DoExpr (ERecordCreate "Env" ((fa "values" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "externNames") (EVar "runtimeDecls")) (EVar "pValues")) (EApp (EVar "userValueNames") (EVar "prog"))) (EVar "imported"))) (fa "types" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "primitiveTypes") (EVar "pTypes")) (EApp (EVar "dataRecordNames") (EVar "prog"))) (EVar "imported"))) (fa "ctors" (EBinOp "++" (EBinOp "++" (EVar "primitiveConstructors") (EVar "pCtors")) (EApp (EVar "ctorNames") (EVar "prog")))) (fa "fields" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "pFieldOwners")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "fieldOwnersOf") (EVar "prog"))))) (fa "fieldOwners" (EBinOp "++" (EVar "pFieldOwners") (EApp (EVar "fieldOwnersOf") (EVar "prog")))) (fa "interfaces" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "pIfaces")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "uIfaces")))) (fa "ifaceMethods" (EBinOp "++" (EVar "pIfaces") (EVar "uIfaces"))) (fa "effects" (EApp (EVar "effectNames") (EVar "prog"))) (fa "imported" (EVar "imported")) (fa "importedModuleValues" (EListLit)) (fa "ambiguous" (EListLit)) (fa "internalGuard" (EVar "internalGuard")))))))
(DTypeSig false "whenL" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "whenL" ((PCon "True") (PVar "xs")) (EVar "xs"))
(DFunDef false "whenL" ((PCon "False") PWild) (EListLit))
(DTypeSig false "buildErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "buildErrors" ((PVar "preludeDecls") (PVar "prog")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "externWithBodyErrors") (EApp (EVar "externNames") (EVar "prog"))) (EVar "prog")) (EApp (EApp (EVar "duplicateErrors") (EVar "preludeDecls")) (EVar "prog"))) (EApp (EVar "contiguityErrors") (EVar "prog"))) (EApp (EVar "dupValueBindingErrors") (EVar "prog"))))
(DTypeSig false "dupValueBindingErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "dupValueBindingErrors" ((PVar "prog")) (EApp (EApp (EApp (EVar "dupValGo") (EVar "None")) (EVar "False")) (EVar "prog")))
(DTypeSig false "dupValGo" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "dupValGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "dupValGo" ((PVar "run") (PVar "sawNullary") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "isTransparentDecl") (EVar "d")) (EApp (EApp (EApp (EVar "dupValGo") (EVar "run")) (EVar "sawNullary")) (EVar "rest")) (EIf (EVar "otherwise") (EMatch (EApp (EVar "dupValClause") (EVar "d")) (arm (PCon "Some" (PTuple (PVar "n") (PVar "isNull") (PVar "loc"))) () (EBlock (DoLet false false (PVar "continuing") (EBinOp "==" (EVar "run") (EApp (EVar "Some") (EVar "n")))) (DoLet false false (PVar "dup") (EBinOp "&&" (EVar "continuing") (EBinOp "||" (EVar "sawNullary") (EVar "isNull")))) (DoLet false false (PVar "errs") (EApp (EApp (EVar "whenL") (EVar "dup")) (EListLit (EApp (EApp (EVar "DuplicateValueBinding") (EVar "n")) (EVar "loc"))))) (DoLet false false (PVar "sawNullary2") (EBinOp "||" (EBinOp "&&" (EVar "continuing") (EVar "sawNullary")) (EVar "isNull"))) (DoExpr (EBinOp "++" (EVar "errs") (EApp (EApp (EApp (EVar "dupValGo") (EApp (EVar "Some") (EVar "n"))) (EVar "sawNullary2")) (EVar "rest")))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "dupValGo") (EVar "None")) (EVar "False")) (EVar "rest")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupValClause" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "dupValClause" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "dupValClause") (EVar "d")))
(DFunDef false "dupValClause" ((PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body"))) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EVar "isEmptyL") (EVar "ps")) (EApp (EVar "firstExprLoc") (EVar "body")))))
(DFunDef false "dupValClause" (PWild) (EVar "None"))
(DTypeSig false "isEmptyL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isEmptyL" ((PList)) (EVar "True"))
(DFunDef false "isEmptyL" (PWild) (EVar "False"))
(DTypeSig false "declBindNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declBindNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declBindNames") (EVar "d")))
(DFunDef false "declBindNames" ((PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "declBindNames" ((PCon "DLetGroup" PWild (PVar "bs"))) (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "bs")))
(DFunDef false "declBindNames" (PWild) (EListLit))
(DTypeSig false "isTransparentDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isTransparentDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isTransparentDecl") (EVar "d")))
(DFunDef false "isTransparentDecl" ((PCon "DTypeSig" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isTransparentDecl" (PWild) (EVar "False"))
(DTypeSig false "contiguityErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "contiguityErrors" ((PVar "prog")) (EApp (EApp (EApp (EVar "contigGo") (EVar "omEmpty")) (EListLit)) (EVar "prog")))
(DTypeSig false "contigGo" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "contigGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "contigGo" ((PVar "closed") (PVar "opened") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "isTransparentDecl") (EVar "d")) (EApp (EApp (EApp (EVar "contigGo") (EVar "closed")) (EVar "opened")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "ns") (EApp (EVar "declBindNames") (EVar "d"))) (DoLet false false (PVar "stillOpen") (EApp (EApp (EVar "filterKeepOpen") (EVar "ns")) (EVar "opened"))) (DoLet false false (PVar "nowClosed") (EApp (EApp (EApp (EVar "closeMissing") (EVar "opened")) (EVar "stillOpen")) (EVar "closed"))) (DoLet false false (PVar "errs") (EApp (EApp (EApp (EVar "newlyDuplicated") (EApp (EVar "declLoc") (EVar "d"))) (EVar "nowClosed")) (EVar "ns"))) (DoLet false false (PVar "opened2") (EApp (EApp (EVar "unionStr") (EVar "stillOpen")) (EVar "ns"))) (DoLet false false (PVar "closed2") (EApp (EApp (EVar "deleteAllStr") (EVar "ns")) (EVar "nowClosed"))) (DoExpr (EBinOp "++" (EVar "errs") (EApp (EApp (EApp (EVar "contigGo") (EVar "closed2")) (EVar "opened2")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterKeepOpen" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterKeepOpen" (PWild (PList)) (EListLit))
(DFunDef false "filterKeepOpen" ((PVar "ns") (PCons (PVar "o") (PVar "os"))) (EIf (EApp (EApp (EVar "contains") (EVar "o")) (EVar "ns")) (EBinOp "::" (EVar "o") (EApp (EApp (EVar "filterKeepOpen") (EVar "ns")) (EVar "os"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterKeepOpen") (EVar "ns")) (EVar "os")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeMissing" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "closeMissing" ((PList) PWild (PVar "closed")) (EVar "closed"))
(DFunDef false "closeMissing" ((PCons (PVar "o") (PVar "os")) (PVar "stillOpen") (PVar "closed")) (EIf (EApp (EApp (EVar "contains") (EVar "o")) (EVar "stillOpen")) (EApp (EApp (EApp (EVar "closeMissing") (EVar "os")) (EVar "stillOpen")) (EVar "closed")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "closeMissing") (EVar "os")) (EVar "stillOpen")) (EApp (EApp (EApp (EVar "omInsert") (EVar "o")) (ELit LUnit)) (EVar "closed"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "deleteAllStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "deleteAllStr" ((PList) (PVar "closed")) (EVar "closed"))
(DFunDef false "deleteAllStr" ((PCons (PVar "n") (PVar "ns")) (PVar "closed")) (EApp (EApp (EVar "deleteAllStr") (EVar "ns")) (EApp (EApp (EVar "omDelete") (EVar "n")) (EVar "closed"))))
(DTypeSig false "newlyDuplicated" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "newlyDuplicated" (PWild PWild (PList)) (EListLit))
(DFunDef false "newlyDuplicated" ((PVar "loc") (PVar "closed") (PCons (PVar "n") (PVar "ns"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "closed")) (EBinOp "::" (EApp (EApp (EVar "DuplicateBinding") (EVar "n")) (EVar "loc")) (EApp (EApp (EApp (EVar "newlyDuplicated") (EVar "loc")) (EVar "closed")) (EVar "ns"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "newlyDuplicated") (EVar "loc")) (EVar "closed")) (EVar "ns")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declLoc" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "declLoc" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declLoc") (EVar "d")))
(DFunDef false "declLoc" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "firstExprLoc") (EVar "body")))
(DFunDef false "declLoc" (PWild) (EVar "None"))
(DTypeSig false "firstExprLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstExprLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "firstExprLoc" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "f"))) (EApp (EVar "firstExprLoc") (EVar "x"))))
(DFunDef false "firstExprLoc" ((PCon "ELam" PWild (PVar "body"))) (EApp (EVar "firstExprLoc") (EVar "body")))
(DFunDef false "firstExprLoc" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "e1"))) (EApp (EVar "firstExprLoc") (EVar "e2"))))
(DFunDef false "firstExprLoc" ((PCon "ELetGroup" PWild (PVar "body"))) (EApp (EVar "firstExprLoc") (EVar "body")))
(DFunDef false "firstExprLoc" ((PCon "EMatch" (PVar "e0") PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "c"))) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "t"))) (EApp (EVar "firstExprLoc") (EVar "el")))))
(DFunDef false "firstExprLoc" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "a"))) (EApp (EVar "firstExprLoc") (EVar "b"))))
(DFunDef false "firstExprLoc" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EVar "firstExprLoc") (EVar "a")))
(DFunDef false "firstExprLoc" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "a"))) (EApp (EVar "firstExprLoc") (EVar "b"))))
(DFunDef false "firstExprLoc" ((PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "firstLocList") (EVar "es")))
(DFunDef false "firstExprLoc" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "firstLocList") (EVar "es")))
(DFunDef false "firstExprLoc" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "firstLocList") (EVar "es")))
(DFunDef false "firstExprLoc" ((PCon "EAnnot" (PVar "e0") PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "EHeadAnnot" (PVar "e0") PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "lo"))) (EApp (EVar "firstExprLoc") (EVar "hi"))))
(DFunDef false "firstExprLoc" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "lo"))) (EApp (EVar "firstExprLoc") (EVar "hi"))))
(DFunDef false "firstExprLoc" ((PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "e0"))) (EApp (EVar "firstExprLoc") (EVar "i"))))
(DFunDef false "firstExprLoc" ((PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "e0"))) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "lo"))) (EApp (EVar "firstExprLoc") (EVar "hi")))))
(DFunDef false "firstExprLoc" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "firstExprLoc") (EVar "e")))
(DFunDef false "firstExprLoc" (PWild) (EVar "None"))
(DTypeSig false "firstLocList" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstLocList" ((PList)) (EVar "None"))
(DFunDef false "firstLocList" ((PCons (PVar "e") (PVar "rest"))) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "e"))) (EApp (EVar "firstLocList") (EVar "rest"))))
(DTypeSig false "orElseLocL" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "orElseLocL" ((PCon "Some" (PVar "l")) PWild) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "orElseLocL" ((PCon "None") (PVar "r")) (EVar "r"))
(DTypeSig false "unionStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "unionStr" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "unionStr" ((PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "acc")) (EApp (EApp (EVar "unionStr") (EVar "acc")) (EVar "xs")) (EIf (EVar "otherwise") (EApp (EApp (EVar "unionStr") (EBinOp "++" (EVar "acc") (EListLit (EVar "x")))) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "externWithBodyErrors" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "externWithBodyErrors" (PWild (PList)) (EListLit))
(DFunDef false "externWithBodyErrors" ((PVar "externs") (PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "externs")) (EListLit (EApp (EApp (EVar "ExternWithBody") (EVar "n")) (EVar "None"))) (EListLit)) (EApp (EApp (EVar "externWithBodyErrors") (EVar "externs")) (EVar "rest"))))
(DFunDef false "externWithBodyErrors" ((PVar "externs") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "externWithBodyErrors") (EVar "externs")) (EVar "rest")))
(DTypeSig false "duplicateErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "duplicateErrors" ((PVar "preludeDecls") (PVar "prog")) (EBlock (DoLet false false (PVar "seed") (EApp (EVar "not") (EApp (EVar "programIsCore") (EVar "prog")))) (DoLet false false (PVar "typeSeed") (EBinOp "++" (EVar "primitiveTypes") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "dataRecordNames") (EVar "preludeDecls"))))) (DoLet false false (PVar "ctorSeed") (EBinOp "++" (EVar "primitiveConstructors") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "ctorNames") (EVar "preludeDecls"))))) (DoLet false false (PVar "ifaceSeed") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "interfaceList") (EVar "preludeDecls"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "dupErr") (ELit (LString "type")))) (EApp (EApp (EVar "findDups") (EVar "typeSeed")) (EApp (EVar "dataRecordNames") (EVar "prog")))) (EApp (EApp (EVar "map") (EApp (EVar "dupErr") (ELit (LString "constructor")))) (EApp (EApp (EVar "findDups") (EVar "ctorSeed")) (EApp (EVar "ctorNames") (EVar "prog"))))) (EApp (EApp (EVar "map") (EApp (EVar "dupErr") (ELit (LString "interface")))) (EApp (EApp (EVar "findDups") (EVar "ifaceSeed")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "interfaceList") (EVar "prog")))))))))
(DTypeSig false "dupErr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "ResError"))))
(DFunDef false "dupErr" ((PVar "kind") (PVar "n")) (EApp (EApp (EApp (EVar "DuplicateDefinition") (EVar "kind")) (EVar "n")) (EVar "None")))
(DTypeSig false "findDups" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "findDups" (PWild (PList)) (EListLit))
(DFunDef false "findDups" ((PVar "seen") (PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "seen")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "findDups") (EVar "seen")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "findDups") (EBinOp "::" (EVar "n") (EVar "seen"))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "resErrorSexp" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "resErrorSexp" ((PCon "UnboundVariable" (PVar "n") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnboundVariable ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnboundVariableExported" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(UnboundVariableExported ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownConstructor" (PVar "n") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownConstructor ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownType" (PVar "n") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownType ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownEffect" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownEffect ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownField" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownField ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "FieldNotInRecord" (PVar "f") (PVar "r") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(FieldNotInRecord ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "f")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "r")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateDefinition" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateDefinition ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "k")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "InternalExternAccess" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(InternalExternAccess ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownInterface" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownInterface ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "MethodNotInInterface" (PVar "m") (PVar "i") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(MethodNotInInterface ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "i")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "ExternWithBody" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(ExternWithBody ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "PrivateNameAccess" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(PrivateNameAccess ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "NoExportedConstructors" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(NoExportedConstructors ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "AbstractFieldAccess" (PVar "t") (PVar "f") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(AbstractFieldAccess ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "t")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "f")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownModule" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownModule ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "NonRecursiveValueLet" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(NonRecursiveValueLet ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateBinding ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateValueBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateValueBinding ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateBinder" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateBinder ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "k")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "AsPatternMisplaced" PWild)) (ELit (LString "AsPatternMisplaced")))
(DFunDef false "resErrorSexp" ((PCon "AmbiguousOccurrence" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(AmbiguousOccurrence ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EApp (EVar "escStr") (EVar "n")) (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "mods"))))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "ReassignImmutable" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(ReassignImmutable ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DTypeSig false "locKey" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locKey" ((PCon "None")) (ELit (LString "-")))
(DFunDef false "locKey" ((PCon "Some" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "f"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "el")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ec")))) (ELit (LString ""))))
(DTypeSig false "dedupResErrors" (TyFun (TyApp (TyCon "List") (TyCon "ResError")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "dedupResErrors" ((PVar "es")) (EApp (EApp (EVar "dedupResErrorsGo") (EVar "es")) (EListLit)))
(DTypeSig false "dedupResErrorsGo" (TyFun (TyApp (TyCon "List") (TyCon "ResError")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "dedupResErrorsGo" ((PList) PWild) (EListLit))
(DFunDef false "dedupResErrorsGo" ((PCons (PVar "e") (PVar "es")) (PVar "seen")) (EBlock (DoLet false false (PVar "key") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "resErrorCode") (EVar "e")))) (ELit (LString "|"))) (EApp (EVar "display") (EApp (EVar "ppResError") (EVar "e")))) (ELit (LString "|"))) (EApp (EVar "display") (EApp (EVar "locKey") (EApp (EVar "resErrorLoc") (EVar "e"))))) (ELit (LString "")))) (DoExpr (EIf (EApp (EApp (EVar "contains") (EVar "key")) (EVar "seen")) (EApp (EApp (EVar "dedupResErrorsGo") (EVar "es")) (EVar "seen")) (EBinOp "::" (EVar "e") (EApp (EApp (EVar "dedupResErrorsGo") (EVar "es")) (EBinOp "::" (EVar "key") (EVar "seen"))))))))
(DTypeSig true "resolveProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "resolveProgram" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EApp (EVar "buildEnv") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "prog")) (EListLit))) (DoExpr (EApp (EVar "dedupResErrors") (EBinOp "++" (EApp (EApp (EVar "buildErrors") (EVar "preludeDecls")) (EVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkDecl") (EVar "env"))) (EVar "prog")))))))
(DTypeSig true "resolveProgramG2" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "resolveProgramG2" ((PVar "internalGuard") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EApp (EVar "buildEnv") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "prog")) (EVar "internalGuard"))) (DoExpr (EApp (EVar "dedupResErrors") (EBinOp "++" (EApp (EApp (EVar "buildErrors") (EVar "preludeDecls")) (EVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkDecl") (EVar "env"))) (EVar "prog")))))))
(DTypeSig true "ppResError" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "ppResError" ((PCon "UnboundVariable" (PVar "n") PWild (PVar "s"))) (EMatch (EVar "s") (arm (PCon "Some" (PVar "sug")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unbound variable: ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ". Did you mean '"))) (EApp (EVar "display") (EVar "sug"))) (ELit (LString "'"))) (EApp (EApp (EVar "haskellNote") (EVar "n")) (EVar "sug")))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "Unbound variable: ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))))))
(DFunDef false "ppResError" ((PCon "UnboundVariableExported" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unbound variable: ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ". (Did you forget to 'import "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ".{"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "}'?)"))))
(DFunDef false "ppResError" ((PCon "UnknownConstructor" (PVar "n") PWild (PVar "s"))) (EMatch (EVar "s") (arm (PCon "Some" (PVar "sug")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unknown constructor: ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ". Did you mean '"))) (EApp (EVar "display") (EVar "sug"))) (ELit (LString "'"))) (EApp (EApp (EVar "haskellNote") (EVar "n")) (EVar "sug")))) (arm (PCon "None") () (EBinOp "++" (ELit (LString "Unknown constructor: ")) (EVar "n")))))
(DFunDef false "ppResError" ((PCon "UnknownType" (PVar "n") PWild (PVar "s"))) (EMatch (EVar "s") (arm (PCon "Some" (PVar "sug")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unknown type: ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ". Did you mean '"))) (EApp (EVar "display") (EVar "sug"))) (ELit (LString "'"))) (EApp (EApp (EVar "haskellNote") (EVar "n")) (EVar "sug")))) (arm (PCon "None") () (EBinOp "++" (ELit (LString "Unknown type: ")) (EVar "n")))))
(DFunDef false "ppResError" ((PCon "UnknownEffect" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "Unknown effect: ")) (EVar "n")))
(DFunDef false "ppResError" ((PCon "UnknownField" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "Unknown field: ")) (EVar "n")))
(DFunDef false "ppResError" ((PCon "FieldNotInRecord" (PVar "f") (PVar "r") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unknown field: ")) (EApp (EVar "display") (EVar "f"))) (ELit (LString ". Record '"))) (EApp (EVar "display") (EVar "r"))) (ELit (LString "' has no field '"))) (EApp (EVar "display") (EVar "f"))) (ELit (LString "'"))))
(DFunDef false "ppResError" ((PCon "DuplicateDefinition" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Duplicate ")) (EApp (EVar "display") (EVar "k"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))))
(DFunDef false "ppResError" ((PCon "UnknownInterface" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "Unknown interface: ")) (EVar "n")))
(DFunDef false "ppResError" ((PCon "MethodNotInInterface" (PVar "m") (PVar "i") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Method '")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "' is not part of interface '"))) (EApp (EVar "display") (EVar "i"))) (ELit (LString "'"))))
(DFunDef false "ppResError" ((PCon "ExternWithBody" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "Extern '")) (EVar "n")) (ELit (LString "' must not have a definition body"))))
(DFunDef false "ppResError" ((PCon "PrivateNameAccess" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Module '")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "' has no exported name '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "'"))))
(DFunDef false "ppResError" ((PCon "NoExportedConstructors" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' exports no constructors from module '"))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "' (exported abstractly). Remove `(..)` or export with `public export`"))))
(DFunDef false "ppResError" ((PCon "AbstractFieldAccess" (PVar "t") (PVar "f") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "display") (EVar "t"))) (ELit (LString "' is exported abstractly. Field '"))) (EApp (EVar "display") (EVar "f"))) (ELit (LString "' is not accessible; declare it `public export` to expose its fields"))))
(DFunDef false "ppResError" ((PCon "UnknownModule" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "Unknown module: ")) (EVar "n")))
(DFunDef false "ppResError" ((PCon "AsPatternMisplaced" PWild)) (ELit (LString "`@` as-patterns are only allowed in a binding position (a lambda parameter, a do-block bind, or a match pattern)")))
(DFunDef false "ppResError" ((PCon "NonRecursiveValueLet" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' is not in scope in its own binding. Non-function `let` is not recursive; write `let rec "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " = ...` (RHS must be a lambda)"))))
(DFunDef false "ppResError" ((PCon "DuplicateBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "Clauses of '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' must be contiguous. An earlier same-named binding is separated by another declaration; group all clauses (and the signature) together"))))
(DFunDef false "ppResError" ((PCon "DuplicateValueBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "Duplicate binding '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': it is already defined in this scope. A value binding has exactly one definition — rename this one or remove it"))))
(DFunDef false "ppResError" ((PCon "DuplicateBinder" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Duplicate binder: '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' is bound more than once in this "))) (EApp (EVar "display") (EVar "k"))) (ELit (LString ". Each binder must be distinct — rename one occurrence"))))
(DFunDef false "ppResError" ((PCon "AmbiguousOccurrence" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Ambiguous occurrence: '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' is exported by "))) (EApp (EVar "display") (EApp (EVar "ambigModPhrase") (EVar "mods")))) (ELit (LString ". Qualify, or select with `import <mod>.{"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "}`"))))
(DFunDef false "ppResError" ((PCon "InternalExternAccess" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EVar "n")) (ELit (LString "' is an internal-only primitive. Cannot be used outside the standard library (pass --allow-internal to override)"))))
(DFunDef false "ppResError" ((PCon "ReassignImmutable" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Cannot reassign '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' — bindings are immutable. To bind a new value, shadow it with `let "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " = ...`. For mutable state, use a `Ref`: `let "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " = Ref 0`, then write `"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " := "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString ".value + 1` (read the cell with `"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString ".value`)"))))
(DTypeSig true "resErrorCode" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "resErrorCode" ((PCon "UnboundVariable" PWild PWild PWild)) (ELit (LString "R-UNBOUND")))
(DFunDef false "resErrorCode" ((PCon "UnboundVariableExported" PWild PWild PWild)) (ELit (LString "R-UNBOUND")))
(DFunDef false "resErrorCode" ((PCon "UnknownConstructor" PWild PWild PWild)) (ELit (LString "R-UNKNOWN-CTOR")))
(DFunDef false "resErrorCode" ((PCon "UnknownType" PWild PWild PWild)) (ELit (LString "R-UNKNOWN-TYPE")))
(DFunDef false "resErrorCode" ((PCon "UnknownEffect" PWild PWild)) (ELit (LString "R-UNKNOWN-EFFECT")))
(DFunDef false "resErrorCode" ((PCon "UnknownField" PWild PWild)) (ELit (LString "R-UNKNOWN-FIELD")))
(DFunDef false "resErrorCode" ((PCon "FieldNotInRecord" PWild PWild PWild)) (ELit (LString "R-FIELD-NOT-IN-RECORD")))
(DFunDef false "resErrorCode" ((PCon "DuplicateDefinition" PWild PWild PWild)) (ELit (LString "R-DUPLICATE-DEF")))
(DFunDef false "resErrorCode" ((PCon "UnknownInterface" PWild PWild)) (ELit (LString "R-UNKNOWN-INTERFACE")))
(DFunDef false "resErrorCode" ((PCon "MethodNotInInterface" PWild PWild PWild)) (ELit (LString "R-METHOD-NOT-IN-INTERFACE")))
(DFunDef false "resErrorCode" ((PCon "ExternWithBody" PWild PWild)) (ELit (LString "R-EXTERN-WITH-BODY")))
(DFunDef false "resErrorCode" ((PCon "PrivateNameAccess" PWild PWild PWild)) (ELit (LString "R-PRIVATE-NAME")))
(DFunDef false "resErrorCode" ((PCon "NoExportedConstructors" PWild PWild PWild)) (ELit (LString "R-NO-EXPORTED-CTORS")))
(DFunDef false "resErrorCode" ((PCon "AbstractFieldAccess" PWild PWild PWild)) (ELit (LString "R-ABSTRACT-FIELD")))
(DFunDef false "resErrorCode" ((PCon "UnknownModule" PWild PWild)) (ELit (LString "R-UNKNOWN-MODULE")))
(DFunDef false "resErrorCode" ((PCon "NonRecursiveValueLet" PWild PWild)) (ELit (LString "R-NONREC-VALUE-LET")))
(DFunDef false "resErrorCode" ((PCon "DuplicateBinding" PWild PWild)) (ELit (LString "R-DUPLICATE-BINDING")))
(DFunDef false "resErrorCode" ((PCon "DuplicateValueBinding" PWild PWild)) (ELit (LString "R-DUP-BINDING")))
(DFunDef false "resErrorCode" ((PCon "DuplicateBinder" PWild PWild PWild)) (ELit (LString "R-DUP-BINDER")))
(DFunDef false "resErrorCode" ((PCon "AsPatternMisplaced" PWild)) (ELit (LString "R-AS-PATTERN-MISPLACED")))
(DFunDef false "resErrorCode" ((PCon "AmbiguousOccurrence" PWild PWild PWild)) (ELit (LString "R-AMBIGUOUS-OCCURRENCE")))
(DFunDef false "resErrorCode" ((PCon "InternalExternAccess" PWild PWild)) (ELit (LString "R-INTERNAL-EXTERN")))
(DFunDef false "resErrorCode" ((PCon "ReassignImmutable" PWild PWild)) (ELit (LString "R-IMMUTABLE-ASSIGN")))
(DTypeSig false "ambigModPhrase" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "ambigModPhrase" ((PCons (PVar "a") (PCons (PVar "b") (PList)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "both `")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "` and `"))) (EApp (EVar "display") (EVar "b"))) (ELit (LString "`"))))
(DFunDef false "ambigModPhrase" ((PVar "mods")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "m")) (ELit (LString "`"))))) (EVar "mods"))))
(DTypeSig true "resolveToLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))
(DFunDef false "resolveToLines" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "ppResError")) (EApp (EApp (EApp (EVar "resolveProgram") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "prog")))))
(DTypeSig true "singleFileImportErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "singleFileImportErrors" ((PList)) (EListLit))
(DFunDef false "singleFileImportErrors" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EBinOp "==" (EVar "mid") (ELit (LString "")))) (EApp (EVar "singleFileImportErrors") (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "UnknownModule") (EVar "mid")) (EVar "None")) (EApp (EVar "singleFileImportErrors") (EVar "rest")))))))
(DFunDef false "singleFileImportErrors" ((PCons PWild (PVar "rest"))) (EApp (EVar "singleFileImportErrors") (EVar "rest")))
(DData Public "ModuleExports" () ((variant "ModuleExports" (ConNamed (field "modId" (TyCon "String")) (field "expValues" (TyApp (TyCon "List") (TyCon "String"))) (field "expTypes" (TyApp (TyCon "List") (TyCon "String"))) (field "expCtors" (TyApp (TyCon "List") (TyCon "String"))) (field "expTypeCtors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "expFieldOwners" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expInterfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "expIfaceMethods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "expEffects" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "isNonEmpty" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isNonEmpty" ((PList)) (EVar "False"))
(DFunDef false "isNonEmpty" (PWild) (EVar "True"))
(DTypeSig false "filterContains" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterContains" (PWild (PList)) (EListLit))
(DFunDef false "filterContains" ((PVar "domain") (PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "domain")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "filterContains") (EVar "domain")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterContains") (EVar "domain")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyApp (TyCon "Option") (TyCon "ModuleExports")))))
(DFunDef false "findExports" (PWild (PList)) (EVar "None"))
(DFunDef false "findExports" ((PVar "mid") (PCons (PVar "e") (PVar "rest"))) (EIf (EBinOp "==" (EFieldAccess (EVar "e") "modId") (EVar "mid")) (EApp (EVar "Some") (EVar "e")) (EIf (EVar "otherwise") (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isPubExp" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isPubExp" ((PVar "exp") (PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expValues")) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expTypes"))) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expCtors"))) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expInterfaces"))))
(DTypeSig false "typeCtorsOf" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "typeCtorsOf" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "exp") "expTypeCtors")))
(DTypeSig false "usePathsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "UsePath"))))
(DFunDef false "usePathsOf" ((PList)) (EListLit))
(DFunDef false "usePathsOf" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "::" (EVar "path") (EApp (EVar "usePathsOf") (EVar "rest"))))
(DFunDef false "usePathsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "usePathsOf") (EVar "rest")))
(DTypeSig false "usePathLocsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "UsePath") (TyCon "Loc")))))
(DFunDef false "usePathLocsOf" ((PList)) (EListLit))
(DFunDef false "usePathLocsOf" ((PCons (PCon "DUse" PWild (PVar "path") (PVar "loc")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "path") (EVar "loc")) (EApp (EVar "usePathLocsOf") (EVar "rest"))))
(DFunDef false "usePathLocsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "usePathLocsOf") (EVar "rest")))
(DTypeSig false "pubUsePaths" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "UsePath"))))
(DFunDef false "pubUsePaths" ((PList)) (EListLit))
(DFunDef false "pubUsePaths" ((PCons (PCon "DUse" (PCon "True") (PVar "path") PWild) (PVar "rest"))) (EBinOp "::" (EVar "path") (EApp (EVar "pubUsePaths") (EVar "rest"))))
(DFunDef false "pubUsePaths" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubUsePaths") (EVar "rest")))
(DTypeSig false "importedNamesMM" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "importedNamesMM" ((PCon "UseName" (PVar "ns")) (PVar "exp")) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EBlock (DoLet false false (PVar "nm") (EApp (EVar "lastOf") (EVar "ns"))) (DoExpr (ETuple (EListLit (EVar "nm")) (EApp (EApp (EVar "pubErr") (EVar "exp")) (EVar "nm"))))) (ETuple (EListLit) (EListLit))))
(DFunDef false "importedNamesMM" ((PCon "UseGroup" PWild (PVar "members")) (PVar "exp")) (EBlock (DoLet false false (PVar "expanded") (EApp (EApp (EVar "flatMap") (EApp (EVar "expandMemberNames") (EVar "exp"))) (EVar "members"))) (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (EVar "localOfExpanded")) (EVar "expanded"))) (DoLet false false (PVar "expandErrs") (EApp (EApp (EVar "flatMap") (EApp (EVar "expandMemberErrs") (EVar "exp"))) (EVar "members"))) (DoExpr (ETuple (EVar "names") (EBinOp "++" (EVar "expandErrs") (EApp (EApp (EVar "flatMap") (EApp (EVar "pubErrExpanded") (EVar "exp"))) (EVar "expanded")))))))
(DFunDef false "importedNamesMM" ((PCon "UseWild" PWild) (PVar "exp")) (ETuple (EBinOp "++" (EBinOp "++" (EFieldAccess (EVar "exp") "expValues") (EFieldAccess (EVar "exp") "expTypes")) (EFieldAccess (EVar "exp") "expCtors")) (EListLit)))
(DFunDef false "importedNamesMM" ((PCon "UseAlias" PWild (PVar "a")) (PVar "exp")) (ETuple (EApp (EApp (EVar "map") (EApp (EVar "qualifiedLocal") (EVar "a"))) (EFieldAccess (EVar "exp") "expValues")) (EListLit)))
(DTypeSig false "pubErr" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "pubErr" ((PVar "exp") (PVar "n")) (EIf (EApp (EApp (EVar "isPubExp") (EVar "exp")) (EVar "n")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EFieldAccess (EVar "exp") "modId")) (EVar "None")))))
(DTypeSig false "pubErrLoc" (TyFun (TyCon "ModuleExports") (TyFun (TyTuple (TyCon "String") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "pubErrLoc" ((PVar "exp") (PTuple (PVar "n") (PVar "loc"))) (EIf (EApp (EApp (EVar "isPubExp") (EVar "exp")) (EVar "n")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EFieldAccess (EVar "exp") "modId")) (EApp (EVar "Some") (EVar "loc"))))))
(DTypeSig false "expandMemberNames" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc"))))))
(DFunDef false "expandMemberNames" (PWild (PAs "m" (PCon "UseMember" (PVar "name") (PCon "False") (PVar "loc") PWild))) (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))))
(DFunDef false "expandMemberNames" ((PVar "exp") (PAs "m" (PCon "UseMember" (PVar "name") (PCon "True") (PVar "loc") PWild))) (EMatch (EApp (EApp (EVar "typeCtorsOf") (EVar "name")) (EVar "exp")) (arm (PCon "Some" (PVar "ctors")) () (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc")) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (ETuple (EVar "c") (EVar "c") (EVar "loc")))) (EVar "ctors")))) (arm (PCon "None") () (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))))))
(DTypeSig false "localOfExpanded" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "localOfExpanded" ((PTuple PWild (PVar "local") PWild)) (EVar "local"))
(DTypeSig false "pubErrExpanded" (TyFun (TyCon "ModuleExports") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "pubErrExpanded" ((PVar "exp") (PTuple (PVar "origin") PWild (PVar "loc"))) (EApp (EApp (EVar "pubErrLoc") (EVar "exp")) (ETuple (EVar "origin") (EVar "loc"))))
(DTypeSig false "expandMemberErrs" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "expandMemberErrs" (PWild (PCon "UseMember" PWild (PCon "False") PWild PWild)) (EListLit))
(DFunDef false "expandMemberErrs" ((PVar "exp") (PCon "UseMember" (PVar "name") (PCon "True") (PVar "loc") PWild)) (EMatch (EApp (EApp (EVar "typeCtorsOf") (EVar "name")) (EVar "exp")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "exp") "expTypes")) (EListLit (EApp (EApp (EApp (EVar "NoExportedConstructors") (EVar "name")) (EFieldAccess (EVar "exp") "modId")) (EApp (EVar "Some") (EVar "loc")))) (EListLit)))))
(DData Public "ImportAdds" () ((variant "ImportAdds" (ConNamed (field "iaImported" (TyApp (TyCon "List") (TyCon "String"))) (field "iaValues" (TyApp (TyCon "List") (TyCon "String"))) (field "iaTypes" (TyApp (TyCon "List") (TyCon "String"))) (field "iaCtors" (TyApp (TyCon "List") (TyCon "String"))) (field "iaIfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "iaFieldOwners" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "iaErrors" (TyApp (TyCon "List") (TyCon "ResError")))))) ())
(DTypeSig false "emptyAdds" (TyCon "ImportAdds"))
(DFunDef false "emptyAdds" () (ERecordCreate "ImportAdds" ((fa "iaImported" (EListLit)) (fa "iaValues" (EListLit)) (fa "iaTypes" (EListLit)) (fa "iaCtors" (EListLit)) (fa "iaIfaces" (EListLit)) (fa "iaFieldOwners" (EListLit)) (fa "iaErrors" (EListLit)))))
(DTypeSig false "mergeAdds" (TyFun (TyCon "ImportAdds") (TyFun (TyCon "ImportAdds") (TyCon "ImportAdds"))))
(DFunDef false "mergeAdds" ((PVar "a") (PVar "b")) (ERecordCreate "ImportAdds" ((fa "iaImported" (EBinOp "++" (EFieldAccess (EVar "a") "iaImported") (EFieldAccess (EVar "b") "iaImported"))) (fa "iaValues" (EBinOp "++" (EFieldAccess (EVar "a") "iaValues") (EFieldAccess (EVar "b") "iaValues"))) (fa "iaTypes" (EBinOp "++" (EFieldAccess (EVar "a") "iaTypes") (EFieldAccess (EVar "b") "iaTypes"))) (fa "iaCtors" (EBinOp "++" (EFieldAccess (EVar "a") "iaCtors") (EFieldAccess (EVar "b") "iaCtors"))) (fa "iaIfaces" (EBinOp "++" (EFieldAccess (EVar "a") "iaIfaces") (EFieldAccess (EVar "b") "iaIfaces"))) (fa "iaFieldOwners" (EBinOp "++" (EFieldAccess (EVar "a") "iaFieldOwners") (EFieldAccess (EVar "b") "iaFieldOwners"))) (fa "iaErrors" (EBinOp "++" (EFieldAccess (EVar "a") "iaErrors") (EFieldAccess (EVar "b") "iaErrors"))))))
(DTypeSig false "collectImports" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ImportAdds"))))
(DFunDef false "collectImports" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "foldImports") (EVar "known")) (EApp (EVar "usePathLocsOf") (EVar "prog"))))
(DTypeSig false "importValueNames" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importValueNames" ((PVar "known") (PVar "path")) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EApp (EVar "useModId") (EVar "path"))) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EBlock (DoLet false false (PTuple (PVar "names") PWild) (EApp (EApp (EVar "importedNamesMM") (EVar "path")) (EVar "exp"))) (DoExpr (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expValues")) (EVar "names"))))))))
(DTypeSig false "addProvenance" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "addProvenance" ((PList) (PVar "n") (PVar "mid")) (EListLit (ETuple (EVar "n") (EListLit (EVar "mid")))))
(DFunDef false "addProvenance" ((PCons (PTuple (PVar "k") (PVar "mids")) (PVar "rest")) (PVar "n") (PVar "mid")) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EIf (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "mids")) (EBinOp "::" (ETuple (EVar "k") (EVar "mids")) (EVar "rest")) (EBinOp "::" (ETuple (EVar "k") (EBinOp "++" (EVar "mids") (EListLit (EVar "mid")))) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "mids")) (EApp (EApp (EApp (EVar "addProvenance") (EVar "rest")) (EVar "n")) (EVar "mid"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "addImportProvenance" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "addImportProvenance" ((PVar "prov") PWild (PList)) (EVar "prov"))
(DFunDef false "addImportProvenance" ((PVar "prov") (PVar "mid") (PCons (PVar "n") (PVar "rest"))) (EApp (EApp (EApp (EVar "addImportProvenance") (EApp (EApp (EApp (EVar "addProvenance") (EVar "prov")) (EVar "n")) (EVar "mid"))) (EVar "mid")) (EVar "rest")))
(DTypeSig false "valueProvenance" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "valueProvenance" ((PVar "known") (PVar "paths")) (EApp (EApp (EApp (EVar "foldProvenance") (EVar "known")) (EListLit)) (EVar "paths")))
(DTypeSig false "foldProvenance" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "foldProvenance" (PWild (PVar "prov") (PList)) (EVar "prov"))
(DFunDef false "foldProvenance" ((PVar "known") (PVar "prov") (PCons (PVar "p") (PVar "rest"))) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "p"))) (DoLet false false (PVar "prov2") (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EVar "prov") (EApp (EApp (EApp (EVar "addImportProvenance") (EVar "prov")) (EVar "mid")) (EApp (EApp (EVar "importValueNames") (EVar "known")) (EVar "p"))))) (DoExpr (EApp (EApp (EApp (EVar "foldProvenance") (EVar "known")) (EVar "prov2")) (EVar "rest")))))
(DTypeSig false "ambiguousSet" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ambiguousSet" ((PVar "known") (PVar "prog")) (EBlock (DoLet false false (PVar "prov") (EApp (EApp (EVar "valueProvenance") (EVar "known")) (EApp (EVar "usePathsOf") (EVar "prog")))) (DoLet false false (PVar "sameMod") (EApp (EVar "userValueNames") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "keepAmbiguous") (EVar "sameMod")) (EVar "prov")))))
(DTypeSig false "keepAmbiguous" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "keepAmbiguous" (PWild (PList)) (EListLit))
(DFunDef false "keepAmbiguous" ((PVar "sameMod") (PCons (PTuple (PVar "n") (PVar "mids")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "mids")) (ELit (LInt 2))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "sameMod")))) (EBinOp "::" (ETuple (EVar "n") (EVar "mids")) (EApp (EApp (EVar "keepAmbiguous") (EVar "sameMod")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "keepAmbiguous") (EVar "sameMod")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "foldImports" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "UsePath") (TyCon "Loc"))) (TyCon "ImportAdds"))))
(DFunDef false "foldImports" (PWild (PList)) (EVar "emptyAdds"))
(DFunDef false "foldImports" ((PVar "known") (PCons (PTuple (PVar "p") (PVar "loc")) (PVar "rest"))) (EApp (EApp (EVar "mergeAdds") (EApp (EApp (EApp (EVar "oneImport") (EVar "known")) (EVar "p")) (EVar "loc"))) (EApp (EApp (EVar "foldImports") (EVar "known")) (EVar "rest"))))
(DTypeSig false "oneImport" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyCon "ImportAdds")))))
(DFunDef false "oneImport" ((PVar "known") (PVar "path") (PVar "loc")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EVar "emptyAdds") (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "stubOrUnknown") (EVar "known")) (EVar "path")) (EVar "mid")) (EVar "loc"))) (arm (PCon "Some" (PVar "exp")) () (EApp (EApp (EApp (EVar "realImport") (EVar "exp")) (EVar "path")) (EVar "loc"))))))))
(DTypeSig false "stubOrUnknown" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "ImportAdds"))))))
(DFunDef false "stubOrUnknown" ((PVar "known") (PVar "path") (PVar "mid") (PVar "loc")) (EIf (EApp (EVar "isNonEmpty") (EVar "known")) (ERecordCreate "ImportAdds" ((fa "iaImported" (EListLit)) (fa "iaValues" (EListLit)) (fa "iaTypes" (EListLit)) (fa "iaCtors" (EListLit)) (fa "iaIfaces" (EListLit)) (fa "iaFieldOwners" (EListLit)) (fa "iaErrors" (EListLit (EApp (EApp (EVar "UnknownModule") (EVar "mid")) (EApp (EVar "Some") (EVar "loc"))))))) (EBlock (DoLet false false (PVar "names") (EApp (EVar "useStubNames") (EVar "path"))) (DoExpr (ERecordCreate "ImportAdds" ((fa "iaImported" (EVar "names")) (fa "iaValues" (EVar "names")) (fa "iaTypes" (EVar "names")) (fa "iaCtors" (EListLit)) (fa "iaIfaces" (EListLit)) (fa "iaFieldOwners" (EListLit)) (fa "iaErrors" (EListLit))))))))
(DTypeSig false "realImport" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyCon "ImportAdds")))))
(DFunDef false "realImport" ((PVar "exp") (PVar "path") (PVar "loc")) (EBlock (DoLet false false (PTuple (PVar "names") (PVar "errs")) (EApp (EApp (EVar "importedNamesMM") (EVar "path")) (EVar "exp"))) (DoExpr (ERecordCreate "ImportAdds" ((fa "iaImported" (EVar "names")) (fa "iaValues" (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expValues")) (EVar "names"))) (fa "iaTypes" (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expTypes")) (EVar "names"))) (fa "iaCtors" (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expCtors")) (EVar "names"))) (fa "iaIfaces" (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expInterfaces")) (EVar "names"))) (fa "iaFieldOwners" (EApp (EApp (EVar "ownedFieldOwners") (EVar "exp")) (EFieldAccess (EVar "exp") "expFieldOwners"))) (fa "iaErrors" (EApp (EApp (EVar "map") (EApp (EVar "withResErrorLoc") (EVar "loc"))) (EVar "errs"))))))))
(DTypeSig false "withResErrorLoc" (TyFun (TyCon "Loc") (TyFun (TyCon "ResError") (TyCon "ResError"))))
(DFunDef false "withResErrorLoc" ((PVar "loc") (PCon "PrivateNameAccess" (PVar "n") (PVar "m") (PCon "None"))) (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "loc"))))
(DFunDef false "withResErrorLoc" (PWild (PCon "PrivateNameAccess" (PVar "n") (PVar "m") (PCon "Some" (PVar "l")))) (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "l"))))
(DFunDef false "withResErrorLoc" ((PVar "loc") (PCon "NoExportedConstructors" (PVar "n") (PVar "m") (PCon "None"))) (EApp (EApp (EApp (EVar "NoExportedConstructors") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "loc"))))
(DFunDef false "withResErrorLoc" (PWild (PCon "NoExportedConstructors" (PVar "n") (PVar "m") (PCon "Some" (PVar "l")))) (EApp (EApp (EApp (EVar "NoExportedConstructors") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "l"))))
(DFunDef false "withResErrorLoc" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "ownedFieldOwners" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "ownedFieldOwners" (PWild (PList)) (EListLit))
(DFunDef false "ownedFieldOwners" ((PVar "exp") (PCons (PTuple (PVar "f") (PVar "o")) (PVar "rest"))) (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "o")) (EFieldAccess (EVar "exp") "expTypes")) (EApp (EApp (EVar "contains") (EVar "o")) (EFieldAccess (EVar "exp") "expCtors"))) (EBinOp "::" (ETuple (EVar "f") (EVar "o")) (EApp (EApp (EVar "ownedFieldOwners") (EVar "exp")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ownedFieldOwners") (EVar "exp")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "importedIfaceMethods" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "importedIfaceMethods" ((PVar "known") (PVar "prog") (PVar "baseIfaces")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "oneImportIfaceMethods") (EVar "known")) (EVar "baseIfaces"))) (EApp (EVar "usePathsOf") (EVar "prog"))))
(DTypeSig false "oneImportIfaceMethods" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "oneImportIfaceMethods" ((PVar "known") (PVar "baseIfaces") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EApp (EApp (EVar "filterIfaceMethods") (EVar "baseIfaces")) (EFieldAccess (EVar "exp") "expIfaceMethods"))))))))
(DTypeSig false "filterIfaceMethods" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "filterIfaceMethods" (PWild (PList)) (EListLit))
(DFunDef false "filterIfaceMethods" ((PVar "baseIfaces") (PCons (PTuple (PVar "iface") (PVar "ms")) (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EVar "baseIfaces")) (EBinOp "::" (ETuple (EVar "iface") (EVar "ms")) (EApp (EApp (EVar "filterIfaceMethods") (EVar "baseIfaces")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterIfaceMethods") (EVar "baseIfaces")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "importedEffects" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importedEffects" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EVar "oneImportEffects") (EVar "known"))) (EApp (EVar "usePathsOf") (EVar "prog"))))
(DTypeSig false "oneImportEffects" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "oneImportEffects" ((PVar "known") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EFieldAccess (EVar "exp") "expEffects")))))))
(DTypeSig false "buildEnvMM" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyCon "Env") (TyApp (TyCon "List") (TyCon "ResError")))))))))
(DFunDef false "buildEnvMM" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "known") (PVar "prog") (PVar "internalGuard")) (EBlock (DoLet false false (PVar "seed") (EApp (EVar "not") (EApp (EVar "programIsCore") (EVar "prog")))) (DoLet false false (PVar "pTypes") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "dataRecordNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pCtors") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "ctorNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pIfaces") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "interfaceList") (EVar "preludeDecls")))) (DoLet false false (PVar "pValues") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "preludeValueNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pFieldOwners") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "fieldOwnersOf") (EVar "preludeDecls")))) (DoLet false false (PVar "uIfaces") (EApp (EVar "interfaceList") (EVar "prog"))) (DoLet false false (PVar "adds") (EApp (EApp (EVar "collectImports") (EVar "known")) (EVar "prog"))) (DoLet false false (PVar "baseIfaces") (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "pIfaces")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "uIfaces"))) (EFieldAccess (EVar "adds") "iaIfaces"))) (DoLet false false (PVar "impIfaceMethods") (EApp (EApp (EApp (EVar "importedIfaceMethods") (EVar "known")) (EVar "prog")) (EVar "baseIfaces"))) (DoLet false false (PVar "impEffects") (EApp (EApp (EVar "importedEffects") (EVar "known")) (EVar "prog"))) (DoLet false false (PVar "impModValues") (EApp (EApp (EVar "importedModuleValueSets") (EVar "known")) (EVar "prog"))) (DoLet false false (PVar "env") (ERecordCreate "Env" ((fa "values" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "externNames") (EVar "runtimeDecls")) (EVar "pValues")) (EApp (EVar "userValueNames") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaValues"))) (fa "types" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "primitiveTypes") (EVar "pTypes")) (EApp (EVar "dataRecordNames") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaTypes"))) (fa "ctors" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "primitiveConstructors") (EVar "pCtors")) (EApp (EVar "ctorNames") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaCtors"))) (fa "fields" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "pFieldOwners")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "fieldOwnersOf") (EVar "prog")))) (EApp (EApp (EVar "map") (EVar "fst")) (EFieldAccess (EVar "adds") "iaFieldOwners")))) (fa "fieldOwners" (EBinOp "++" (EBinOp "++" (EVar "pFieldOwners") (EApp (EVar "fieldOwnersOf") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaFieldOwners"))) (fa "interfaces" (EVar "baseIfaces")) (fa "ifaceMethods" (EBinOp "++" (EBinOp "++" (EVar "pIfaces") (EVar "uIfaces")) (EVar "impIfaceMethods"))) (fa "effects" (EBinOp "++" (EApp (EVar "effectNames") (EVar "prog")) (EVar "impEffects"))) (fa "imported" (EFieldAccess (EVar "adds") "iaImported")) (fa "importedModuleValues" (EVar "impModValues")) (fa "ambiguous" (EApp (EApp (EVar "ambiguousSet") (EVar "known")) (EVar "prog"))) (fa "internalGuard" (EVar "internalGuard"))))) (DoExpr (ETuple (EVar "env") (EFieldAccess (EVar "adds") "iaErrors")))))
(DTypeSig false "importedModuleValueSets" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "importedModuleValueSets" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EVar "oneImportedModuleValues") (EVar "known"))) (EApp (EVar "usePathsOf") (EVar "prog"))))
(DTypeSig false "oneImportedModuleValues" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "oneImportedModuleValues" ((PVar "known") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EListLit (ETuple (EVar "mid") (EFieldAccess (EVar "exp") "expValues")))))))))
(DTypeSig false "buildExports" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Env") (TyCon "ModuleExports"))))))
(DFunDef false "buildExports" ((PVar "known") (PVar "modId") (PVar "prog") (PVar "env")) (ERecordCreate "ModuleExports" ((fa "modId" (EVar "modId")) (fa "expValues" (EBinOp "++" (EBinOp "++" (EApp (EVar "expValuesDirect") (EVar "prog")) (EApp (EApp (EVar "publicIfaceMethodVals") (EVar "prog")) (EVar "env"))) (EApp (EApp (EVar "reExpValues") (EVar "known")) (EVar "prog")))) (fa "expTypes" (EBinOp "++" (EApp (EVar "expTypesDirect") (EVar "prog")) (EApp (EApp (EVar "reExpTypes") (EVar "known")) (EVar "prog")))) (fa "expCtors" (EBinOp "++" (EApp (EVar "expCtorsDirect") (EVar "prog")) (EApp (EApp (EVar "reExpCtors") (EVar "known")) (EVar "prog")))) (fa "expTypeCtors" (EApp (EVar "expTypeCtorsDirect") (EVar "prog"))) (fa "expFieldOwners" (EBinOp "++" (EApp (EVar "expFieldOwnersDirect") (EVar "prog")) (EApp (EApp (EVar "reExpFieldOwners") (EVar "known")) (EVar "prog")))) (fa "expInterfaces" (EBinOp "++" (EApp (EVar "expInterfacesDirect") (EVar "prog")) (EApp (EApp (EVar "reExpInterfaces") (EVar "known")) (EVar "prog")))) (fa "expIfaceMethods" (EBinOp "++" (EApp (EVar "expIfaceMethodsDirect") (EVar "prog")) (EApp (EApp (EVar "reExpIfaceMethods") (EVar "known")) (EVar "prog")))) (fa "expEffects" (EBinOp "++" (EApp (EVar "expEffectsDirect") (EVar "prog")) (EApp (EApp (EVar "reExpEffects") (EVar "known")) (EVar "prog")))))))
(DTypeSig false "expValuesDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expValuesDirect" ((PList)) (EListLit))
(DFunDef false "expValuesDirect" ((PCons (PCon "DTypeSig" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expValuesDirect") (EVar "rest"))))
(DFunDef false "expValuesDirect" ((PCons (PCon "DExtern" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expValuesDirect") (EVar "rest"))))
(DFunDef false "expValuesDirect" ((PCons (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expValuesDirect") (EVar "rest"))))
(DFunDef false "expValuesDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expValuesDirect") (EVar "rest")))
(DTypeSig false "publicIfaceMethodVals" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Env") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "publicIfaceMethodVals" ((PVar "prog") (PVar "env")) (EApp (EApp (EVar "flatMap") (EApp (EVar "keepBoundMethods") (EVar "env"))) (EApp (EVar "pubIfaceMethodSets") (EVar "prog"))))
(DTypeSig false "keepBoundMethods" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "keepBoundMethods" ((PVar "env") (PVar "ms")) (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "env") "values")) (EVar "ms")))
(DTypeSig false "pubIfaceMethodSets" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "pubIfaceMethodSets" ((PList)) (EListLit))
(DFunDef false "pubIfaceMethodSets" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "pubIfaceMethodSets") (EVar "rest"))))
(DFunDef false "pubIfaceMethodSets" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubIfaceMethodSets") (EVar "rest")))
(DTypeSig false "expTypesDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expTypesDirect" ((PList)) (EListLit))
(DFunDef false "expTypesDirect" ((PCons (PCon "DNewtype" (PCon "True") (PVar "n") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons (PCon "DData" (PCon "VisPublic") (PVar "n") PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons (PCon "DData" (PCon "VisAbstract") (PVar "n") PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons (PCon "DTypeAlias" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expTypesDirect") (EVar "rest")))
(DTypeSig false "expCtorsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expCtorsDirect" ((PList)) (EListLit))
(DFunDef false "expCtorsDirect" ((PCons (PCon "DNewtype" (PCon "True") PWild PWild (PVar "con") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "con") (EApp (EVar "expCtorsDirect") (EVar "rest"))))
(DFunDef false "expCtorsDirect" ((PCons (PCon "DData" (PCon "VisPublic") PWild PWild (PVar "vs") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "variantName")) (EVar "vs")) (EApp (EVar "expCtorsDirect") (EVar "rest"))))
(DFunDef false "expCtorsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expCtorsDirect") (EVar "rest")))
(DTypeSig false "expTypeCtorsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "expTypeCtorsDirect" ((PList)) (EListLit))
(DFunDef false "expTypeCtorsDirect" ((PCons (PCon "DNewtype" (PCon "True") (PVar "n") PWild (PVar "con") PWild PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EListLit (EVar "con"))) (EApp (EVar "expTypeCtorsDirect") (EVar "rest"))))
(DFunDef false "expTypeCtorsDirect" ((PCons (PCon "DData" (PCon "VisPublic") (PVar "n") PWild (PVar "vs") PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "variantName")) (EVar "vs"))) (EApp (EVar "expTypeCtorsDirect") (EVar "rest"))))
(DFunDef false "expTypeCtorsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expTypeCtorsDirect") (EVar "rest")))
(DTypeSig false "expFieldOwnersDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "expFieldOwnersDirect" ((PList)) (EListLit))
(DFunDef false "expFieldOwnersDirect" ((PCons (PCon "DData" (PCon "VisPublic") PWild PWild (PVar "vs") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "variantFieldOwners")) (EVar "vs")) (EApp (EVar "expFieldOwnersDirect") (EVar "rest"))))
(DFunDef false "expFieldOwnersDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expFieldOwnersDirect") (EVar "rest")))
(DTypeSig false "expInterfacesDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expInterfacesDirect" ((PList)) (EListLit))
(DFunDef false "expInterfacesDirect" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" (PVar "n"))) true) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expInterfacesDirect") (EVar "rest"))))
(DFunDef false "expInterfacesDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expInterfacesDirect") (EVar "rest")))
(DTypeSig false "expIfaceMethodsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "expIfaceMethodsDirect" ((PList)) (EListLit))
(DFunDef false "expIfaceMethodsDirect" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" (PVar "n")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods"))) (EApp (EVar "expIfaceMethodsDirect") (EVar "rest"))))
(DFunDef false "expIfaceMethodsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expIfaceMethodsDirect") (EVar "rest")))
(DTypeSig false "expEffectsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expEffectsDirect" ((PList)) (EListLit))
(DFunDef false "expEffectsDirect" ((PCons (PCon "DEffect" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expEffectsDirect") (EVar "rest"))))
(DFunDef false "expEffectsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expEffectsDirect") (EVar "rest")))
(DTypeSig false "reExpEffects" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpEffects" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "overPubUse") (EVar "known")) (EVar "reExpEffectsFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpEffectsFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpEffectsFrom" ((PCon "UseWild" PWild) (PVar "src")) (EFieldAccess (EVar "src") "expEffects"))
(DFunDef false "reExpEffectsFrom" (PWild PWild) (EListLit))
(DTypeSig false "reexportBindings" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportBindings" ((PCon "UseName" (PVar "ns")) PWild) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "lastOf") (EVar "ns"))) (DoExpr (EListLit (ETuple (EVar "n") (EVar "n"))))) (EListLit)))
(DFunDef false "reexportBindings" ((PCon "UseGroup" PWild (PVar "members")) (PVar "src")) (EApp (EApp (EVar "map") (EVar "dropLocOfExpanded")) (EApp (EApp (EVar "flatMap") (EApp (EVar "expandMemberNames") (EVar "src"))) (EVar "members"))))
(DFunDef false "reexportBindings" ((PCon "UseWild" PWild) (PVar "src")) (EApp (EApp (EVar "map") (EVar "selfBinding")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EFieldAccess (EVar "src") "expValues") (EFieldAccess (EVar "src") "expTypes")) (EFieldAccess (EVar "src") "expCtors")) (EFieldAccess (EVar "src") "expInterfaces"))))
(DFunDef false "reexportBindings" ((PCon "UseAlias" PWild PWild) PWild) (EListLit))
(DTypeSig false "dropLocOfExpanded" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc")) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "dropLocOfExpanded" ((PTuple (PVar "origin") (PVar "local") PWild)) (ETuple (EVar "origin") (EVar "local")))
(DTypeSig false "selfBinding" (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "selfBinding" ((PVar "n")) (ETuple (EVar "n") (EVar "n")))
(DTypeSig false "localsExportedFrom" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "localsExportedFrom" ((PVar "origins") (PVar "bindings")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "contains") (EApp (EVar "fst") (EVar "b"))) (EVar "origins")))) (EVar "bindings"))))
(DTypeSig false "reExpValues" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpValues" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "overPubUse") (EVar "known")) (EVar "reExpValuesFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpValuesFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpValuesFrom" ((PVar "path") (PVar "src")) (EBlock (DoLet false false (PVar "bindings") (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expValues")) (EVar "bindings")) (EApp (EApp (EVar "flatMap") (EApp (EVar "ifaceValsOf") (EVar "src"))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "bindings")))))))
(DTypeSig false "ifaceValsOf" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceValsOf" ((PVar "src") (PVar "n")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "src") "expInterfaces")) (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expValues")) (EApp (EApp (EVar "ifaceMethodsOf") (EVar "n")) (EFieldAccess (EVar "src") "expIfaceMethods"))) (EListLit)))
(DTypeSig false "reExpTypes" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpTypes" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "overPubUse") (EVar "known")) (EVar "reExpTypesFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpTypesFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpTypesFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expTypes")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpCtors" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpCtors" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "overPubUse") (EVar "known")) (EVar "reExpCtorsFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpCtorsFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpCtorsFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expCtors")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpInterfaces" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpInterfaces" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "overPubUse") (EVar "known")) (EVar "reExpInterfacesFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reexportOrigins" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reexportOrigins" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpInterfacesFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpInterfacesFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expInterfaces")) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpIfaceMethods" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reExpIfaceMethods" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "overPubUse") (EVar "known")) (EVar "reExpIfaceMethodsFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpIfaceMethodsFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reExpIfaceMethodsFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "ifaceMethodPairs") (EVar "src")) (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expInterfaces")) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src")))))
(DTypeSig false "ifaceMethodPairs" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ifaceMethodPairs" (PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodPairs" ((PVar "src") (PCons (PVar "i") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "i") (EApp (EApp (EVar "ifaceMethodsOf") (EVar "i")) (EFieldAccess (EVar "src") "expIfaceMethods"))) (EApp (EApp (EVar "ifaceMethodPairs") (EVar "src")) (EVar "rest"))))
(DTypeSig false "reExpFieldOwners" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reExpFieldOwners" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "overPubUse") (EVar "known")) (EVar "reExpFieldOwnersFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpFieldOwnersFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reExpFieldOwnersFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "ownersForTypes") (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expTypes")) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src")))) (EFieldAccess (EVar "src") "expFieldOwners")))
(DTypeSig false "ownersForTypes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "ownersForTypes" (PWild (PList)) (EListLit))
(DFunDef false "ownersForTypes" ((PVar "types") (PCons (PTuple (PVar "f") (PVar "o")) (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "o")) (EVar "types")) (EBinOp "::" (ETuple (EVar "f") (EVar "o")) (EApp (EApp (EVar "ownersForTypes") (EVar "types")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ownersForTypes") (EVar "types")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "overPubUse" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyVar "b")))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyVar "b"))))))
(DFunDef false "overPubUse" ((PVar "known") (PVar "f") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "f") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "resolveModule" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "ResError")))))))))
(DFunDef false "resolveModule" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "known") (PVar "modId") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModuleG") (EListLit)) (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "known")) (EVar "modId")) (EVar "prog")))
(DTypeSig true "resolveModuleG" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "ResError"))))))))))
(DFunDef false "resolveModuleG" ((PVar "internalGuard") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "known") (PVar "modId") (PVar "prog")) (EBlock (DoLet false false (PTuple (PVar "env") (PVar "importErrs")) (EApp (EApp (EApp (EApp (EApp (EVar "buildEnvMM") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "known")) (EVar "prog")) (EVar "internalGuard"))) (DoLet false false (PVar "errs") (EApp (EVar "dedupResErrors") (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "buildErrors") (EVar "preludeDecls")) (EVar "prog")) (EVar "importErrs")) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkDecl") (EVar "env"))) (EVar "prog"))))) (DoLet false false (PVar "exp") (EApp (EApp (EApp (EApp (EVar "buildExports") (EVar "known")) (EVar "modId")) (EVar "prog")) (EVar "env"))) (DoExpr (ETuple (EVar "exp") (EVar "errs")))))
(DTypeSig false "resolveModulesErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "resolveModulesErrors" ((PVar "rt") (PVar "pre") (PVar "known") (PVar "mods")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsG") (EVar "True")) (EListLit)) (EVar "rt")) (EVar "pre")) (EVar "known")) (EVar "mods")))
(DTypeSig false "resolveModulesErrorsG" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ResError")))))))))
(DFunDef false "resolveModulesErrorsG" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "resolveModulesErrorsG" ((PVar "allowInternal") (PVar "trustedMods") (PVar "rt") (PVar "pre") (PVar "known") (PCons (PTuple (PVar "mid") (PVar "prog")) (PVar "rest"))) (EBlock (DoLet false false (PVar "guard") (EIf (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trustedMods"))) (EListLit) (EVar "internalExterns"))) (DoLet false false (PTuple (PVar "exp") (PVar "errs")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModuleG") (EVar "guard")) (EVar "rt")) (EVar "pre")) (EVar "known")) (EVar "mid")) (EVar "prog"))) (DoExpr (EBinOp "++" (EVar "errs") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "rt")) (EVar "pre")) (EBinOp "::" (EVar "exp") (EVar "known"))) (EVar "rest"))))))
(DTypeSig true "resolveModulesToLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))
(DFunDef false "resolveModulesToLines" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "resErrorSexp")) (EApp (EApp (EApp (EApp (EVar "resolveModulesErrors") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EListLit)) (EVar "mods")))))
(DTypeSig true "resolveModulesToLinesG" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))))
(DFunDef false "resolveModulesToLinesG" ((PVar "allowInternal") (PVar "trustedMods") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "resErrorSexp")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "runtimeDecls")) (EVar "preludeDecls")) (EListLit)) (EVar "mods")))))
(DTypeSig true "resolveModulesToHumane" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))
(DFunDef false "resolveModulesToHumane" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "ppResErrorLocated")) (EApp (EApp (EApp (EApp (EVar "resolveModulesErrors") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EListLit)) (EVar "mods")))))
(DTypeSig true "resolveModulesToHumaneG" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))))
(DFunDef false "resolveModulesToHumaneG" ((PVar "allowInternal") (PVar "trustedMods") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "ppResErrorLocated")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "runtimeDecls")) (EVar "preludeDecls")) (EListLit)) (EVar "mods")))))
(DTypeSig true "resolveModulesToHumaneGF" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))))))
(DFunDef false "resolveModulesToHumaneGF" ((PVar "fallbackFile") (PVar "allowInternal") (PVar "trustedMods") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EVar "ppResErrorLocatedF") (EVar "fallbackFile"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "runtimeDecls")) (EVar "preludeDecls")) (EListLit)) (EVar "mods")))))
(DTypeSig true "ppResErrorLocated" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "ppResErrorLocated" ((PVar "e")) (EApp (EApp (EVar "ppResErrorLocatedF") (ELit (LString ""))) (EVar "e")))
(DTypeSig true "ppResErrorLocatedF" (TyFun (TyCon "String") (TyFun (TyCon "ResError") (TyCon "String"))))
(DFunDef false "ppResErrorLocatedF" ((PVar "fallbackFile") (PVar "e")) (EMatch (EApp (EVar "resErrorLoc") (EVar "e")) (arm (PCon "None") () (EBinOp "++" (ELit (LString "<unknown location>: ")) (EApp (EVar "ppResError") (EVar "e")))) (arm (PCon "Some" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") PWild PWild)) () (EBlock (DoLet false false (PVar "ff") (EIf (EBinOp "==" (EVar "f") (ELit (LString ""))) (EVar "fallbackFile") (EVar "f"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ff"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "ppResError") (EVar "e")))) (ELit (LString ""))))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Addr" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberLocal" false) (mem "qualifiedLocal" false) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false) (mem "omDelete" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "editDistance" false) (mem "minI" false) (mem "maxI" false) (mem "listLen" false) (mem "escStr" false) (mem "joinNl" false) (mem "joinWith" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "initList" false) (mem "joinDot" false) (mem "filterList" false))))
(DData Public "ResError" () ((variant "UnboundVariable" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")))) (variant "UnboundVariableExported" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownConstructor" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")))) (variant "UnknownType" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")))) (variant "UnknownEffect" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownField" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "FieldNotInRecord" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateDefinition" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownInterface" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "MethodNotInInterface" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "ExternWithBody" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "PrivateNameAccess" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "NoExportedConstructors" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AbstractFieldAccess" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownModule" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "NonRecursiveValueLet" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateBinding" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateValueBinding" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateBinder" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AsPatternMisplaced" (ConPos (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AmbiguousOccurrence" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "InternalExternAccess" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "ReassignImmutable" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DTypeSig true "resErrorDidYouMean" (TyFun (TyCon "ResError") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "resErrorDidYouMean" ((PCon "UnboundVariable" (PVar "n") PWild (PCon "Some" (PVar "sug")))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "sug"))))
(DFunDef false "resErrorDidYouMean" ((PCon "UnknownConstructor" (PVar "n") PWild (PCon "Some" (PVar "sug")))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "sug"))))
(DFunDef false "resErrorDidYouMean" ((PCon "UnknownType" (PVar "n") PWild (PCon "Some" (PVar "sug")))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "sug"))))
(DFunDef false "resErrorDidYouMean" (PWild) (EVar "None"))
(DTypeSig true "resErrorLoc" (TyFun (TyCon "ResError") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "resErrorLoc" ((PCon "UnboundVariable" PWild (PVar "l") PWild)) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnboundVariableExported" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownConstructor" PWild (PVar "l") PWild)) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownType" PWild (PVar "l") PWild)) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownEffect" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownField" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "FieldNotInRecord" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateDefinition" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownInterface" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "MethodNotInInterface" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "ExternWithBody" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "PrivateNameAccess" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "NoExportedConstructors" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AbstractFieldAccess" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownModule" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "NonRecursiveValueLet" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateBinding" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateValueBinding" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateBinder" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AsPatternMisplaced" (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AmbiguousOccurrence" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "InternalExternAccess" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "ReassignImmutable" PWild (PVar "l"))) (EVar "l"))
(DData Public "Env" () ((variant "Env" (ConNamed (field "values" (TyApp (TyCon "List") (TyCon "String"))) (field "types" (TyApp (TyCon "List") (TyCon "String"))) (field "ctors" (TyApp (TyCon "List") (TyCon "String"))) (field "fields" (TyApp (TyCon "List") (TyCon "String"))) (field "fieldOwners" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "interfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "ifaceMethods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "effects" (TyApp (TyCon "List") (TyCon "String"))) (field "imported" (TyApp (TyCon "List") (TyCon "String"))) (field "importedModuleValues" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "ambiguous" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "internalGuard" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig true "internalExterns" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "internalExterns" () (EListLit (ELit (LString "arrayGetUnsafe")) (ELit (LString "arraySetUnsafe")) (ELit (LString "arrayBlit")) (ELit (LString "arrayFill")) (ELit (LString "bytesToFloat64"))))
(DTypeSig true "internalGuardFor" (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "internalGuardFor" ((PCon "True")) (EListLit))
(DFunDef false "internalGuardFor" ((PCon "False")) (EVar "internalExterns"))
(DTypeSig false "ownersOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ownersOf" (PWild (PList)) (EListLit))
(DFunDef false "ownersOf" ((PVar "field") (PCons (PTuple (PVar "f") (PVar "owner")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "f") (EVar "field")) (EBinOp "::" (EVar "owner") (EApp (EApp (EVar "ownersOf") (EVar "field")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ownersOf") (EVar "field")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "patBindings" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patBindings" ((PCon "PVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "patBindings" ((PCon "PWild")) (EListLit))
(DFunDef false "patBindings" ((PCon "PLit" PWild)) (EListLit))
(DFunDef false "patBindings" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "a")) (EApp (EVar "patBindings") (EVar "b"))))
(DFunDef false "patBindings" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PAs" (PVar "x") (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patBindings") (EVar "p"))))
(DFunDef false "patBindings" ((PCon "PRng" PWild PWild PWild)) (EListLit))
(DFunDef false "patBindings" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "recFieldBindings")) (EVar "fields")))
(DTypeSig false "recFieldBindings" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" (PVar "fname") (PCon "None"))) (EListLit (EVar "fname")))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patBindings") (EVar "p")))
(DTypeSig false "patsBindings" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patsBindings" ((PVar "ps")) (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")))
(DTypeSig false "patGroupDupErrors" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "patGroupDupErrors" ((PVar "loc") (PVar "kind") (PVar "ps")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EApp (EVar "DuplicateBinder") (EVar "kind")) (EVar "n")) (EVar "loc")))) (EApp (EApp (EVar "findDups") (EListLit)) (EApp (EVar "patsBindings") (EVar "ps")))))
(DTypeSig false "checkType" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyCon" (PVar "n") (PVar "loc"))) (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "env") "types")) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "env") "imported"))) (EApp (EVar "isTupleCtorTyName") (EVar "n"))) (EListLit) (EListLit (EApp (EApp (EApp (EVar "UnknownType") (EVar "n")) (EApp (EApp (EVar "orElseLocL") (EVar "loc")) (EVar "cur"))) (EApp (EApp (EVar "suggestType") (EVar "env")) (EVar "n"))))))
(DFunDef false "checkType" (PWild PWild (PCon "TyVar" PWild)) (EListLit))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "a")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "b"))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "a")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "b"))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env"))) (EVar "ts")))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyEffect" (PVar "labels") PWild (PVar "t"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkEffect") (EVar "cur")) (EVar "env"))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "labels"))) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkConstraint") (EVar "cur")) (EVar "env"))) (EVar "cs")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DTypeSig false "builtInEffects" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "builtInEffects" () (EListLit (ELit (LString "IO")) (ELit (LString "Mut")) (ELit (LString "Panic")) (ELit (LString "Rand")) (ELit (LString "Stdout")) (ELit (LString "Stderr")) (ELit (LString "Stdin")) (ELit (LString "Clock")) (ELit (LString "Env")) (ELit (LString "Exec")) (ELit (LString "Net")) (ELit (LString "FileRead")) (ELit (LString "FileWrite"))))
(DTypeSig false "checkEffect" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkEffect" ((PVar "cur") (PVar "env") (PVar "e")) (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "e")) (EVar "builtInEffects")) (EApp (EApp (EVar "contains") (EVar "e")) (EFieldAccess (EVar "env") "effects"))) (EListLit) (EListLit (EApp (EApp (EVar "UnknownEffect") (EVar "e")) (EVar "cur")))))
(DTypeSig false "checkConstraint" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkConstraint" ((PVar "cur") (PVar "env") (PCon "Constraint" (PVar "iface") (PVar "args"))) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces")) (EListLit) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "cur")))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env"))) (EVar "args"))))
(DTypeSig false "checkPat" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PCon" (PVar "c") (PVar "ps"))) (EBinOp "++" (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "c")) (EFieldAccess (EVar "env") "ctors")) (EApp (EApp (EVar "contains") (EVar "c")) (EFieldAccess (EVar "env") "imported"))) (EListLit) (EListLit (EApp (EApp (EApp (EVar "UnknownConstructor") (EVar "c")) (EVar "cur")) (EApp (EVar "suggestCtor") (EVar "c"))))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "ps"))))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "a")) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "b"))))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "ps")))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PList" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "ps")))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PAs" PWild (PVar "p"))) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PRec" (PVar "name") (PVar "fields") PWild)) (EApp (EApp (EApp (EApp (EVar "checkRecPat") (EVar "cur")) (EVar "env")) (EVar "name")) (EVar "fields")))
(DFunDef false "checkPat" (PWild PWild PWild) (EListLit))
(DTypeSig false "checkRecPat" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkRecPat" ((PVar "cur") (PVar "env") (PVar "name") (PVar "fields")) (EBinOp "++" (EApp (EApp (EApp (EVar "recPatHead") (EVar "cur")) (EVar "env")) (EVar "name")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkRecField") (EVar "cur")) (EVar "env")) (EVar "name"))) (EVar "fields"))))
(DTypeSig false "recPatHead" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "recPatHead" ((PVar "cur") (PVar "env") (PVar "name")) (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "env") "types")) (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "env") "ctors"))) (EListLit) (EListLit (EApp (EApp (EApp (EVar "UnknownType") (EVar "name")) (EVar "cur")) (EApp (EApp (EVar "suggestType") (EVar "env")) (EVar "name"))))))
(DTypeSig false "checkRecField" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkRecField" ((PVar "cur") (PVar "env") (PVar "owner") (PCon "RecPatField" (PVar "fname") (PVar "popt"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "fieldCheck") (EVar "cur")) (EVar "env")) (EVar "owner")) (EVar "fname")) (EApp (EApp (EApp (EVar "recFieldSub") (EVar "cur")) (EVar "env")) (EVar "popt"))))
(DTypeSig false "fieldCheck" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "fieldCheck" ((PVar "cur") (PVar "env") (PVar "owner") (PVar "fname")) (EBlock (DoLet false false (PVar "owners") (EApp (EApp (EVar "ownersOf") (EVar "fname")) (EFieldAccess (EVar "env") "fieldOwners"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "fieldVerdict") (EVar "cur")) (EVar "env")) (EVar "owner")) (EVar "fname")) (EVar "owners")))))
(DTypeSig false "fieldVerdict" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "fieldVerdict" ((PVar "cur") (PVar "env") (PVar "owner") (PVar "fname") (PList)) (EIf (EBinOp "&&" (EApp (EApp (EVar "contains") (EVar "owner")) (EFieldAccess (EVar "env") "types")) (EApp (EVar "not") (EApp (EApp (EVar "ownsAnyField") (EVar "owner")) (EFieldAccess (EVar "env") "fieldOwners")))) (EListLit (EApp (EApp (EApp (EVar "AbstractFieldAccess") (EVar "owner")) (EVar "fname")) (EVar "cur"))) (EListLit (EApp (EApp (EVar "UnknownField") (EVar "fname")) (EVar "cur")))))
(DFunDef false "fieldVerdict" ((PVar "cur") (PVar "env") (PVar "owner") (PVar "fname") (PVar "owners")) (EIf (EApp (EApp (EVar "contains") (EVar "owner")) (EVar "owners")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "FieldNotInRecord") (EVar "fname")) (EVar "owner")) (EVar "cur")))))
(DTypeSig false "ownsAnyField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "ownsAnyField" (PWild (PList)) (EVar "False"))
(DFunDef false "ownsAnyField" ((PVar "owner") (PCons (PTuple PWild (PVar "o")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "o") (EVar "owner")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "ownsAnyField") (EVar "owner")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recFieldSub" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "Option") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "recFieldSub" (PWild PWild (PCon "None")) (EListLit))
(DFunDef false "recFieldSub" ((PVar "cur") (PVar "env") (PCon "Some" (PVar "p"))) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")))
(DTypeSig false "checkExpr" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "ELit" PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "ENumLit" PWild PWild PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EMethodRef" PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EDictApp" PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EVarAt" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EVarAt is introduced by annotateProgram after resolve"))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EMethodAt" PWild PWild PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EMethodAt is introduced by typecheck elaboration after resolve"))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EDictAt" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EDictAt is introduced by typecheck elaboration after resolve"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EVar" (PVar "n"))) (EApp (EApp (EApp (EApp (EVar "checkVar") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "n")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "f")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "x"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ELam" (PVar "pats") (PVar "body"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "parameter list"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EBinOp "++" (EApp (EVar "patsBindings") (EVar "pats")) (EVar "scope"))) (EVar "body"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ELet" PWild (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkLet") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "isRec")) (EVar "pat")) (EVar "e1")) (EVar "e2")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EVar "checkLetGroup") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "binds")) (EVar "body")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkArm") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "arms"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "c")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "t"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "el"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "b"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "a")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkVar") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "op")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "b"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EMapLit" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EMapLit is lowered to fromEntries by desugar before resolve"))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "ESetLit" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: ESetLit is lowered to fromEntries by desugar before resolve"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ETuple" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "es")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "es")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "es")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "lo")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "hi"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "lo")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "hi"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "hi"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "i"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "checkStmts") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "stmts")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EDo" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "checkStmts") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "stmts")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkInterp") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "parts")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EGuards" (PVar "arms"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkGuardArm") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "arms")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERecordCreate" (PVar "name") (PVar "fs"))) (EApp (EApp (EApp (EApp (EApp (EVar "checkRecordCreate") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "name")) (EVar "fs")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "checkRecordUpdate") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EVar "fs")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EVariantUpdate" (PVar "con") (PVar "e0") (PVar "fs"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EApp (EApp (EVar "checkRecordCreate") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "con")) (EVar "fs"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EAsPat" PWild (PVar "e0"))) (EBinOp "::" (EApp (EVar "AsPatternMisplaced") (EVar "cur")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ESection" (PVar "s"))) (EApp (EApp (EApp (EApp (EVar "checkSection") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "s")))
(DFunDef false "checkExpr" (PWild (PVar "env") (PVar "scope") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EApp (EVar "Some") (EVar "l"))) (EVar "env")) (EVar "scope")) (EVar "e")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkVar" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkVar" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "n")) (EIf (EApp (EVar "isHint") (EVar "n")) (EListLit) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "scope"))) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "env") "internalGuard"))) (EListLit (EApp (EApp (EVar "InternalExternAccess") (EVar "n")) (EVar "cur"))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "lookupValue") (EVar "env")) (EVar "scope")) (EVar "n"))) (EApp (EApp (EApp (EApp (EVar "unboundVarErrors") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "n")) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "scope"))) (EApp (EApp (EVar "isAmbiguous") (EVar "env")) (EVar "n"))) (EListLit (EApp (EApp (EApp (EVar "AmbiguousOccurrence") (EVar "n")) (EApp (EApp (EVar "ambigMods") (EVar "env")) (EVar "n"))) (EVar "cur"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "unboundVarErrors" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "unboundVarErrors" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "n")) (EMatch (EApp (EApp (EVar "modulesExportingName") (EVar "env")) (EVar "n")) (arm (PCons (PVar "m") PWild) () (EListLit (EApp (EApp (EApp (EVar "UnboundVariableExported") (EVar "n")) (EVar "m")) (EVar "cur")))) (arm (PList) () (EListLit (EApp (EApp (EApp (EVar "UnboundVariable") (EVar "n")) (EVar "cur")) (EApp (EApp (EApp (EVar "suggestName") (EVar "env")) (EVar "scope")) (EVar "n")))))))
(DTypeSig false "modulesExportingName" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "modulesExportingName" ((PVar "env") (PVar "n")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "matchesExport") (EVar "n"))) (EFieldAccess (EVar "env") "importedModuleValues")))
(DTypeSig false "matchesExport" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "matchesExport" ((PVar "n") (PTuple (PVar "mid") (PVar "vals"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "vals")) (EListLit (EVar "mid")) (EListLit)))
(DTypeSig false "isAmbiguous" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isAmbiguous" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ambiguous")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "ambigMods" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ambigMods" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ambiguous")) (arm (PCon "Some" (PVar "mods")) () (EVar "mods")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "isHint" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHint" ((PVar "n")) (EApp (EVar "startsWithAt") (EApp (EVar "stringToChars") (EVar "n"))))
(DTypeSig false "startsWithAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Bool")))
(DFunDef false "startsWithAt" ((PVar "cs")) (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")) (ELit (LChar "@")))))
(DTypeSig false "lookupValue" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "lookupValue" ((PVar "env") (PVar "scope") (PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "n")) (EVar "scope")) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "env") "values"))) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "env") "ctors"))) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "env") "imported"))))
(DTypeSig false "haskellTypeAliases" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellTypeAliases" () (EListLit (ETuple (ELit (LString "Functor")) (ELit (LString "Mappable"))) (ETuple (ELit (LString "Monad")) (ELit (LString "Thenable"))) (ETuple (ELit (LString "Maybe")) (ELit (LString "Option"))) (ETuple (ELit (LString "Either")) (ELit (LString "Result")))))
(DTypeSig false "haskellValueAliases" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellValueAliases" () (EListLit (ETuple (ELit (LString "fmap")) (ELit (LString "map"))) (ETuple (ELit (LString "return")) (ELit (LString "pure"))) (ETuple (ELit (LString "show")) (ELit (LString "debug"))) (ETuple (ELit (LString "mappend")) (ELit (LString "append"))) (ETuple (ELit (LString "mempty")) (ELit (LString "empty"))) (ETuple (ELit (LString "foldr")) (ELit (LString "foldRight"))) (ETuple (ELit (LString "foldl")) (ELit (LString "fold"))) (ETuple (ELit (LString "error")) (ELit (LString "panic"))) (ETuple (ELit (LString "undefined")) (ELit (LString "panic")))))
(DTypeSig false "haskellCtorAliases" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellCtorAliases" () (EListLit (ETuple (ELit (LString "Just")) (ELit (LString "Some"))) (ETuple (ELit (LString "Nothing")) (ELit (LString "None"))) (ETuple (ELit (LString "Left")) (ELit (LString "Err"))) (ETuple (ELit (LString "Right")) (ELit (LString "Ok")))))
(DTypeSig false "isHaskellAliasPair" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isHaskellAliasPair" ((PVar "bad") (PVar "sug")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "optStrEq") (EApp (EApp (EVar "lookupAssoc") (EVar "bad")) (EVar "haskellTypeAliases"))) (EVar "sug")) (EApp (EApp (EVar "optStrEq") (EApp (EApp (EVar "lookupAssoc") (EVar "bad")) (EVar "haskellValueAliases"))) (EVar "sug"))) (EApp (EApp (EVar "optStrEq") (EApp (EApp (EVar "lookupAssoc") (EVar "bad")) (EVar "haskellCtorAliases"))) (EVar "sug"))))
(DTypeSig false "optStrEq" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "optStrEq" ((PCon "Some" (PVar "x")) (PVar "sug")) (EBinOp "==" (EVar "x") (EVar "sug")))
(DFunDef false "optStrEq" ((PCon "None") PWild) (EVar "False"))
(DTypeSig false "haskellNote" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellNote" ((PVar "bad") (PVar "sug")) (EIf (EApp (EApp (EVar "isHaskellAliasPair") (EVar "bad")) (EVar "sug")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " ('")) (EApp (EMethodRef "display") (EVar "bad"))) (ELit (LString "' is Haskell; Medaka uses '"))) (EApp (EMethodRef "display") (EVar "sug"))) (ELit (LString "')"))) (ELit (LString ""))))
(DTypeSig false "suggestName" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "suggestName" ((PVar "env") (PVar "scope") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EBinOp "++" (EVar "haskellValueAliases") (EVar "haskellCtorAliases"))) (arm (PCon "Some" (PVar "sug")) () (EApp (EVar "Some") (EVar "sug"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "suggestNameFuzzy") (EVar "env")) (EVar "scope")) (EVar "n")))))
(DTypeSig false "suggestNameFuzzy" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "suggestNameFuzzy" ((PVar "env") (PVar "scope") (PVar "n")) (EIf (EBinOp "<" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 3))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "lim") (EApp (EApp (EVar "minI") (ELit (LInt 2))) (EApp (EApp (EVar "maxI") (ELit (LInt 1))) (EBinOp "/" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 3)))))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "bestOf") (EVar "n")) (EVar "lim")) (EVar "scope")) (arm (PCon "Some" (PVar "best")) () (EApp (EVar "Some") (EVar "best"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "bestOf") (EVar "n")) (EVar "lim")) (EBinOp "++" (EBinOp "++" (EFieldAccess (EVar "env") "values") (EFieldAccess (EVar "env") "ctors")) (EFieldAccess (EVar "env") "imported"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "suggestType" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "suggestType" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "haskellTypeAliases")) (arm (PCon "Some" (PVar "sug")) () (EApp (EVar "Some") (EVar "sug"))) (arm (PCon "None") () (EApp (EApp (EVar "suggestTypeFuzzy") (EVar "env")) (EVar "n")))))
(DTypeSig false "suggestTypeFuzzy" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "suggestTypeFuzzy" ((PVar "env") (PVar "n")) (EIf (EBinOp "<" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 3))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "lim") (EApp (EApp (EVar "minI") (ELit (LInt 2))) (EApp (EApp (EVar "maxI") (ELit (LInt 1))) (EBinOp "/" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 3)))))) (DoExpr (EApp (EApp (EApp (EVar "bestOf") (EVar "n")) (EVar "lim")) (EBinOp "++" (EFieldAccess (EVar "env") "types") (EFieldAccess (EVar "env") "imported"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "suggestCtor" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "suggestCtor" ((PVar "n")) (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "haskellCtorAliases")))
(DTypeSig false "bestOf" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "bestOf" ((PVar "n") (PVar "lim") (PVar "cands")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "best") PWild)) (EVar "best"))) (EApp (EApp (EApp (EApp (EVar "bestCandidate") (EVar "n")) (EVar "lim")) (EVar "cands")) (EVar "None"))))
(DTypeSig false "bestCandidate" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "bestCandidate" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "bestCandidate" ((PVar "n") (PVar "lim") (PCons (PVar "c") (PVar "cs")) (PVar "acc")) (EIf (EBinOp "==" (EVar "c") (EVar "n")) (EApp (EApp (EApp (EApp (EVar "bestCandidate") (EVar "n")) (EVar "lim")) (EVar "cs")) (EVar "acc")) (EIf (EBinOp ">" (EApp (EApp (EVar "editDistance") (EVar "n")) (EVar "c")) (EVar "lim")) (EApp (EApp (EApp (EApp (EVar "bestCandidate") (EVar "n")) (EVar "lim")) (EVar "cs")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "bestCandidate") (EVar "n")) (EVar "lim")) (EVar "cs")) (EApp (EApp (EApp (EVar "keepBetter") (EVar "c")) (EApp (EApp (EVar "editDistance") (EVar "n")) (EVar "c"))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "keepBetter" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "keepBetter" ((PVar "c") (PVar "d") (PCon "None")) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))))
(DFunDef false "keepBetter" ((PVar "c") (PVar "d") (PCon "Some" (PTuple (PVar "bc") (PVar "bd")))) (EIf (EBinOp "<" (EVar "d") (EVar "bd")) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "d") (EVar "bd")) (EBinOp "<" (EVar "c") (EVar "bc"))) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))) (EIf (EVar "otherwise") (EApp (EVar "Some") (ETuple (EVar "bc") (EVar "bd"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "checkLet" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError"))))))))))
(DFunDef false "checkLet" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "True") (PCon "PVar" (PVar "f")) (PVar "e1") (PVar "e2")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EBinOp "::" (EVar "f") (EVar "scope"))) (EVar "e1")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EBinOp "::" (EVar "f") (EVar "scope"))) (EVar "e2"))))
(DFunDef false "checkLet" ((PVar "cur") (PVar "env") (PVar "scope") PWild (PVar "pat") (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "bound") (EApp (EVar "patBindings") (EVar "pat"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "pat")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "pat")))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteNonRec") (EVar "bound"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e1")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EBinOp "++" (EVar "bound") (EVar "scope"))) (EVar "e2"))))))
(DTypeSig false "rewriteNonRec" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ResError") (TyCon "ResError"))))
(DFunDef false "rewriteNonRec" ((PVar "bound") (PCon "UnboundVariable" (PVar "n") (PVar "l") (PVar "s"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "bound")) (EApp (EApp (EVar "NonRecursiveValueLet") (EVar "n")) (EVar "l")) (EApp (EApp (EApp (EVar "UnboundVariable") (EVar "n")) (EVar "l")) (EVar "s"))))
(DFunDef false "rewriteNonRec" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "checkLetGroup" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkLetGroup" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "binds") (PVar "body")) (EBlock (DoLet false false (PVar "scope2") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")) (EVar "scope"))) (DoExpr (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkLetBind") (EVar "cur")) (EVar "env")) (EVar "scope2"))) (EVar "binds")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "checkLetBind" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkLetBind" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EBinOp "++" (EApp (EApp (EApp (EVar "letBindDupErrors") (EVar "cur")) (EVar "n")) (EVar "clauses")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkFunClause") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "clauses"))))
(DTypeSig false "letBindDupErrors" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "letBindDupErrors" ((PVar "cur") (PVar "n") (PVar "clauses")) (EIf (EApp (EVar "hasNullaryClause") (EVar "clauses")) (EApp (EApp (EApp (EApp (EVar "dupClauseTail") (EVar "cur")) (EVar "n")) (EVar "False")) (EVar "clauses")) (EListLit)))
(DTypeSig false "hasNullaryClause" (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Bool")))
(DFunDef false "hasNullaryClause" ((PList)) (EVar "False"))
(DFunDef false "hasNullaryClause" ((PCons (PCon "FunClause" (PVar "ps") PWild) (PVar "rest"))) (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "ps")) (EApp (EVar "hasNullaryClause") (EVar "rest"))))
(DTypeSig false "dupClauseTail" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "dupClauseTail" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "dupClauseTail" ((PVar "cur") (PVar "n") (PVar "seen") (PCons (PCon "FunClause" PWild (PVar "body")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "whenL") (EVar "seen")) (EListLit (EApp (EApp (EVar "DuplicateValueBinding") (EVar "n")) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "cur"))))) (EApp (EApp (EApp (EApp (EVar "dupClauseTail") (EVar "cur")) (EVar "n")) (EVar "True")) (EVar "rest"))))
(DTypeSig false "checkFunClause" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkFunClause" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "patLoc") (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "cur"))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EVar "patLoc")) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "patLoc")) (ELit (LString "parameter list"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EBinOp "++" (EApp (EVar "patsBindings") (EVar "pats")) (EVar "scope"))) (EVar "body"))))))
(DTypeSig false "checkArm" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkArm" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "Arm" (PVar "pat") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "scope0") (EBinOp "++" (EApp (EVar "patBindings") (EVar "pat")) (EVar "scope"))) (DoLet false false (PTuple (PVar "gErrs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkArmGuards") (EVar "cur")) (EVar "env")) (EVar "scope0")) (EVar "gs"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "pat")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "pat")))) (EVar "gErrs")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "checkArmGuards" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "ResError")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "checkArmGuards" (PWild PWild (PVar "scope") (PList)) (ETuple (EListLit) (EVar "scope")))
(DFunDef false "checkArmGuards" ((PVar "cur") (PVar "env") (PVar "scope") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rErrs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkArmGuards") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EVar "rErrs")) (EVar "scope2")))))
(DFunDef false "checkArmGuards" ((PVar "cur") (PVar "env") (PVar "scope") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p"))) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p"))))) (DoLet false false (PTuple (PVar "rErrs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkArmGuards") (EVar "cur")) (EVar "env")) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EVar "scope"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EVar "here") (EVar "rErrs")) (EVar "scope2")))))
(DTypeSig false "checkGuardArm" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkGuardArm" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkGuard") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "gs")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "body"))))
(DTypeSig false "checkGuard" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkGuard" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "GBool" (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DFunDef false "checkGuard" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "GBind" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkStmts" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkStmts" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "checkStmts" ((PVar "cur") (PVar "env") (PVar "scope") (PCons (PVar "s") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "errs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkStmt") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "s"))) (DoExpr (EBinOp "++" (EVar "errs") (EApp (EApp (EApp (EApp (EVar "checkStmts") (EVar "cur")) (EVar "env")) (EVar "scope2")) (EVar "rest"))))))
(DTypeSig false "checkStmt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "DoStmt") (TyTuple (TyApp (TyCon "List") (TyCon "ResError")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoExpr" (PVar "e"))) (ETuple (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EVar "scope")))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoBind" (PVar "p") (PVar "e"))) (ETuple (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EVar "scope"))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoLet" PWild (PCon "False") (PVar "p") (PVar "e"))) (ETuple (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EVar "scope"))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoLet" PWild (PCon "True") (PVar "p") (PVar "e"))) (ETuple (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EVar "scope"))) (EVar "e"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "p")) (EVar "scope"))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoAssign" (PVar "x") (PVar "e"))) (ETuple (EBinOp "::" (EApp (EApp (EVar "ReassignImmutable") (EVar "x")) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "e"))) (EVar "cur"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e"))) (EVar "scope")))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoFieldAssign" PWild PWild (PVar "e"))) (ETuple (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EVar "scope")))
(DTypeSig false "checkInterp" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkInterp" (PWild PWild PWild (PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "checkInterp" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "InterpExpr" (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkFieldAssign" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkFieldAssign" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "FieldAssign" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkRecordCreate" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkRecordCreate" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "name") (PVar "fs")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "recCreateHead") (EVar "cur")) (EVar "env")) (EVar "name")) (EVar "fs")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkFieldAssign") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "fs"))))
(DTypeSig false "recCreateHead" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "recCreateHead" ((PVar "cur") (PVar "env") (PVar "name") (PVar "fs")) (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "env") "types")) (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "env") "imported"))) (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "env") "ctors"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "recCreateField") (EVar "cur")) (EVar "env")) (EVar "name"))) (EVar "fs")) (EIf (EVar "otherwise") (EListLit (EApp (EApp (EApp (EVar "UnknownType") (EVar "name")) (EVar "cur")) (EApp (EApp (EVar "suggestType") (EVar "env")) (EVar "name")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recCreateField" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "recCreateField" ((PVar "cur") (PVar "env") (PVar "owner") (PCon "FieldAssign" (PVar "fname") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "fieldVerdict") (EVar "cur")) (EVar "env")) (EVar "owner")) (EVar "fname")) (EApp (EApp (EVar "ownersOf") (EVar "fname")) (EFieldAccess (EVar "env") "fieldOwners"))))
(DTypeSig false "checkRecordUpdate" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkRecordUpdate" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "e0") (PVar "fs")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "recUpdateField") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "fs"))))
(DTypeSig false "recUpdateField" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "recUpdateField" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "FieldAssign" (PVar "fname") (PVar "v"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "v")) (EApp (EApp (EApp (EVar "fieldKnownErr") (EVar "cur")) (EVar "env")) (EVar "fname"))))
(DTypeSig false "fieldKnownErr" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "fieldKnownErr" ((PVar "cur") (PVar "env") (PVar "fname")) (EApp (EApp (EApp (EVar "recUpdateVerdict") (EVar "cur")) (EVar "fname")) (EApp (EApp (EVar "ownersOf") (EVar "fname")) (EFieldAccess (EVar "env") "fieldOwners"))))
(DTypeSig false "recUpdateVerdict" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "recUpdateVerdict" ((PVar "cur") (PVar "fname") (PList)) (EListLit (EApp (EApp (EVar "UnknownField") (EVar "fname")) (EVar "cur"))))
(DFunDef false "recUpdateVerdict" (PWild PWild PWild) (EListLit))
(DTypeSig false "checkSection" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Section") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkSection" (PWild PWild PWild (PCon "SecBare" PWild)) (EListLit))
(DFunDef false "checkSection" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "SecRight" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DFunDef false "checkSection" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "SecLeft" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkDecl" (TyFun (TyCon "Env") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DFunDef" PWild PWild (PVar "pats") (PVar "body"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EApp (EVar "firstExprLoc") (EVar "body"))) (ELit (LString "parameter list"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EVar "patsBindings") (EVar "pats"))) (EVar "body"))))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkLetBind") (EVar "None")) (EVar "env")) (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")))) (EVar "binds")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DTypeSig" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DExtern" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DData" PWild PWild PWild (PVar "vs") PWild)) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkVariant") (EVar "env"))) (EVar "vs")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DProp" PWild PWild (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EVar "checkProp") (EVar "env")) (EVar "params")) (EVar "body")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DTest" PWild PWild (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EListLit)) (EVar "body")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DBench" PWild PWild (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EListLit)) (EVar "body")))
(DFunDef false "checkDecl" ((PVar "env") (PRec "DInterface" ((rf "supers" None) (rf "methods" None)) true)) (EApp (EApp (EApp (EVar "checkInterfaceDecl") (EVar "env")) (EVar "supers")) (EVar "methods")))
(DFunDef false "checkDecl" ((PVar "env") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) true)) (EApp (EApp (EApp (EApp (EApp (EVar "checkImplDecl") (EVar "env")) (EVar "iface")) (EVar "tys")) (EVar "reqs")) (EVar "methods")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DTypeAlias" PWild PWild PWild (PVar "rhs"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "rhs")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DNewtype" PWild PWild PWild PWild (PVar "fty") PWild)) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "fty")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DAttrib" PWild (PVar "inner"))) (EApp (EApp (EVar "checkDecl") (EVar "env")) (EVar "inner")))
(DFunDef false "checkDecl" (PWild PWild) (EListLit))
(DTypeSig false "checkVariant" (TyFun (TyCon "Env") (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkVariant" ((PVar "env") (PCon "Variant" PWild (PCon "ConPos" (PVar "tys")))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env"))) (EVar "tys")))
(DFunDef false "checkVariant" ((PVar "env") (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkFieldType") (EVar "env"))) (EVar "fs")))
(DTypeSig false "checkFieldType" (TyFun (TyCon "Env") (TyFun (TyCon "Field") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkFieldType" ((PVar "env") (PCon "Field" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DTypeSig false "checkProp" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkProp" ((PVar "env") (PVar "params") (PVar "body")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkPropParamTy") (EVar "env"))) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EApp (EMethodRef "map") (EVar "propParamName")) (EVar "params"))) (EVar "body"))))
(DTypeSig false "checkPropParamTy" (TyFun (TyCon "Env") (TyFun (TyCon "PropParam") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkPropParamTy" ((PVar "env") (PCon "PropParam" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DTypeSig false "propParamName" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "propParamName" ((PCon "PropParam" (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "checkInterfaceDecl" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "Super")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkInterfaceDecl" ((PVar "env") (PVar "supers") (PVar "methods")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkSuper") (EVar "env"))) (EVar "supers")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkIfaceMethod") (EVar "env"))) (EVar "methods"))))
(DTypeSig false "checkSuper" (TyFun (TyCon "Env") (TyFun (TyCon "Super") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkSuper" ((PVar "env") (PCon "Super" (PVar "iface") PWild)) (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces")) (EListLit) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "None")))))
(DTypeSig false "checkIfaceMethod" (TyFun (TyCon "Env") (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkIfaceMethod" ((PVar "env") (PCon "IfaceMethod" PWild (PVar "t") (PCon "None"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DFunDef false "checkIfaceMethod" ((PVar "env") (PCon "IfaceMethod" PWild (PVar "t") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "env"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EVar "patsBindings") (EVar "pats"))) (EVar "body"))))
(DTypeSig false "checkImplDecl" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkImplDecl" ((PVar "env") (PVar "iface") (PVar "tyargs") (PVar "reqs") (PVar "methods")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env"))) (EVar "tyargs")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkRequire") (EVar "env"))) (EVar "reqs"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkImplMethod") (EVar "env"))) (EVar "methods"))) (EApp (EApp (EApp (EVar "checkImplIface") (EVar "env")) (EVar "iface")) (EVar "methods"))))
(DTypeSig false "checkRequire" (TyFun (TyCon "Env") (TyFun (TyCon "Require") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkRequire" ((PVar "env") (PCon "Require" (PVar "iface") (PVar "tys"))) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces")) (EListLit) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "None")))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env"))) (EVar "tys"))))
(DTypeSig false "checkImplMethod" (TyFun (TyCon "Env") (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkImplMethod" ((PVar "env") (PCon "ImplMethod" PWild (PVar "pats") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EVar "patsBindings") (EVar "pats"))) (EVar "body"))))
(DTypeSig false "checkImplIface" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkImplIface" ((PVar "env") (PVar "iface") (PVar "methods")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces"))) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "None"))) (EIf (EVar "otherwise") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkMethodMember") (EVar "iface")) (EApp (EApp (EVar "ifaceMethodsOf") (EVar "iface")) (EFieldAccess (EVar "env") "ifaceMethods")))) (EVar "methods")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifaceMethodsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceMethodsOf" (PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodsOf" ((PVar "iface") (PCons (PTuple (PVar "i") (PVar "ms")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "i") (EVar "iface")) (EVar "ms") (EIf (EVar "otherwise") (EApp (EApp (EVar "ifaceMethodsOf") (EVar "iface")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "checkMethodMember" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkMethodMember" ((PVar "iface") (PVar "known") (PCon "ImplMethod" (PVar "mname") PWild PWild)) (EIf (EApp (EApp (EVar "contains") (EVar "mname")) (EVar "known")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "MethodNotInInterface") (EVar "mname")) (EVar "iface")) (EVar "None")))))
(DTypeSig false "isTupleCtorTyName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isTupleCtorTyName" ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EListLit (ELit (LString "__tuple2__")) (ELit (LString "__tuple3__")) (ELit (LString "__tuple4__")) (ELit (LString "__tuple5__")))))
(DTypeSig false "primitiveTypes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "primitiveTypes" () (EListLit (ELit (LString "Int")) (ELit (LString "Float")) (ELit (LString "String")) (ELit (LString "Char")) (ELit (LString "Bool")) (ELit (LString "Unit")) (ELit (LString "List")) (ELit (LString "Ref")) (ELit (LString "Array"))))
(DTypeSig false "primitiveConstructors" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "primitiveConstructors" () (EListLit (ELit (LString "True")) (ELit (LString "False"))))
(DTypeSig false "externNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "externNames" ((PList)) (EListLit))
(DFunDef false "externNames" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "externNames") (EVar "rest"))))
(DFunDef false "externNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "externNames") (EVar "rest")))
(DTypeSig false "dataRecordNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dataRecordNames" ((PList)) (EListLit))
(DFunDef false "dataRecordNames" ((PCons (PCon "DData" PWild (PVar "n") PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PCon "DTypeAlias" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PCon "DNewtype" PWild (PVar "n") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "dataRecordNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "dataRecordNames") (EVar "rest")))
(DTypeSig false "effectNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "effectNames" ((PList)) (EListLit))
(DFunDef false "effectNames" ((PCons (PCon "DEffect" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "effectNames") (EVar "rest"))))
(DFunDef false "effectNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "effectNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "effectNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "effectNames") (EVar "rest")))
(DTypeSig false "ctorNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ctorNames" ((PList)) (EListLit))
(DFunDef false "ctorNames" ((PCons (PCon "DData" PWild PWild PWild (PVar "vs") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "variantName")) (EVar "vs")) (EApp (EVar "ctorNames") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons (PCon "DNewtype" PWild PWild PWild (PVar "con") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "con") (EApp (EVar "ctorNames") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "ctorNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "ctorNames") (EVar "rest")))
(DTypeSig false "variantName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "ifaceMethodNm" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodNm" ((PCon "IfaceMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "implMethodNm" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodNm" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "interfaceList" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "interfaceList" ((PList)) (EListLit))
(DFunDef false "interfaceList" ((PCons (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods"))) (EApp (EVar "interfaceList") (EVar "rest"))))
(DFunDef false "interfaceList" ((PCons PWild (PVar "rest"))) (EApp (EVar "interfaceList") (EVar "rest")))
(DTypeSig false "preludeValueNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "preludeValueNames" ((PList)) (EListLit))
(DFunDef false "preludeValueNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PRec "DImpl" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "implMethodNm")) (EVar "methods")) (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "preludeValueNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "preludeValueNames") (EVar "rest")))
(DTypeSig false "userValueNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "userValueNames" ((PList)) (EListLit))
(DFunDef false "userValueNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DLetGroup" PWild (PVar "bs")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "bs")) (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "userValueNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "userValueNames") (EVar "rest")))
(DTypeSig false "fieldOwnersOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "fieldOwnersOf" ((PList)) (EListLit))
(DFunDef false "fieldOwnersOf" ((PCons (PCon "DData" PWild PWild PWild (PVar "vs") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "variantFieldOwners")) (EVar "vs")) (EApp (EVar "fieldOwnersOf") (EVar "rest"))))
(DFunDef false "fieldOwnersOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "fieldOwnersOf") (EVar "rest")))
(DTypeSig false "recordFieldOwner" (TyFun (TyCon "String") (TyFun (TyCon "Field") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "recordFieldOwner" ((PVar "owner") (PCon "Field" (PVar "fname") PWild)) (ETuple (EVar "fname") (EVar "owner")))
(DTypeSig false "variantFieldOwners" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "variantFieldOwners" ((PCon "Variant" (PVar "cname") (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EApp (EMethodRef "map") (EApp (EVar "recordFieldOwner") (EVar "cname"))) (EVar "fs")))
(DFunDef false "variantFieldOwners" ((PCon "Variant" PWild (PCon "ConPos" PWild))) (EListLit))
(DTypeSig false "importedNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "importedNames" ((PList)) (EListLit))
(DFunDef false "importedNames" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EVar "useImportNames") (EVar "path")) (EApp (EVar "importedNames") (EVar "rest"))))
(DFunDef false "importedNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "importedNames") (EVar "rest")))
(DTypeSig false "useImportNames" (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "useImportNames" ((PVar "path")) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EListLit) (EApp (EVar "useStubNames") (EVar "path"))))
(DTypeSig false "useStubNames" (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "useStubNames" ((PCon "UseName" (PVar "ns"))) (EListLit (EApp (EVar "lastOf") (EVar "ns"))))
(DFunDef false "useStubNames" ((PCon "UseGroup" PWild (PVar "ms"))) (EApp (EApp (EMethodRef "map") (EVar "useMemberLocal")) (EVar "ms")))
(DFunDef false "useStubNames" ((PCon "UseWild" PWild)) (EListLit))
(DFunDef false "useStubNames" ((PCon "UseAlias" PWild PWild)) (EListLit))
(DTypeSig false "useModId" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useModId" ((PCon "UseName" (PVar "ns"))) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EVar "joinDot") (EApp (EVar "initList") (EVar "ns"))) (EApp (EApp (EVar "firstOr") (ELit (LString ""))) (EVar "ns"))))
(DFunDef false "useModId" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModId" ((PCon "UseWild" (PVar "ns"))) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModId" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DTypeSig false "lastOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastOf" ((PList)) (ELit (LString "")))
(DFunDef false "lastOf" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastOf") (EVar "rest")))
(DTypeSig false "firstOr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "firstOr" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "firstOr" (PWild (PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "programIsCore" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "programIsCore" ((PVar "prog")) (EBinOp "&&" (EApp (EVar "hasOrdering") (EVar "prog")) (EApp (EVar "hasFoldable") (EVar "prog"))))
(DTypeSig false "hasOrdering" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasOrdering" ((PList)) (EVar "False"))
(DFunDef false "hasOrdering" ((PCons (PCon "DData" PWild (PLit (LString "Ordering")) PWild PWild PWild) PWild)) (EVar "True"))
(DFunDef false "hasOrdering" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasOrdering") (EVar "rest")))
(DTypeSig false "hasFoldable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasFoldable" ((PList)) (EVar "False"))
(DFunDef false "hasFoldable" ((PCons (PRec "DInterface" ((rf "name" (PLit (LString "Foldable")))) true) PWild)) (EVar "True"))
(DFunDef false "hasFoldable" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasFoldable") (EVar "rest")))
(DTypeSig false "buildEnv" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Env"))))))
(DFunDef false "buildEnv" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog") (PVar "internalGuard")) (EBlock (DoLet false false (PVar "seed") (EApp (EVar "not") (EApp (EVar "programIsCore") (EVar "prog")))) (DoLet false false (PVar "pTypes") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "dataRecordNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pCtors") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "ctorNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pIfaces") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "interfaceList") (EVar "preludeDecls")))) (DoLet false false (PVar "pValues") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "preludeValueNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pFieldOwners") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "fieldOwnersOf") (EVar "preludeDecls")))) (DoLet false false (PVar "uIfaces") (EApp (EVar "interfaceList") (EVar "prog"))) (DoLet false false (PVar "imported") (EApp (EVar "importedNames") (EVar "prog"))) (DoExpr (ERecordCreate "Env" ((fa "values" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "externNames") (EVar "runtimeDecls")) (EVar "pValues")) (EApp (EVar "userValueNames") (EVar "prog"))) (EVar "imported"))) (fa "types" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "primitiveTypes") (EVar "pTypes")) (EApp (EVar "dataRecordNames") (EVar "prog"))) (EVar "imported"))) (fa "ctors" (EBinOp "++" (EBinOp "++" (EVar "primitiveConstructors") (EVar "pCtors")) (EApp (EVar "ctorNames") (EVar "prog")))) (fa "fields" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "pFieldOwners")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "fieldOwnersOf") (EVar "prog"))))) (fa "fieldOwners" (EBinOp "++" (EVar "pFieldOwners") (EApp (EVar "fieldOwnersOf") (EVar "prog")))) (fa "interfaces" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "pIfaces")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "uIfaces")))) (fa "ifaceMethods" (EBinOp "++" (EVar "pIfaces") (EVar "uIfaces"))) (fa "effects" (EApp (EVar "effectNames") (EVar "prog"))) (fa "imported" (EVar "imported")) (fa "importedModuleValues" (EListLit)) (fa "ambiguous" (EListLit)) (fa "internalGuard" (EVar "internalGuard")))))))
(DTypeSig false "whenL" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "whenL" ((PCon "True") (PVar "xs")) (EVar "xs"))
(DFunDef false "whenL" ((PCon "False") PWild) (EListLit))
(DTypeSig false "buildErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "buildErrors" ((PVar "preludeDecls") (PVar "prog")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "externWithBodyErrors") (EApp (EVar "externNames") (EVar "prog"))) (EVar "prog")) (EApp (EApp (EVar "duplicateErrors") (EVar "preludeDecls")) (EVar "prog"))) (EApp (EVar "contiguityErrors") (EVar "prog"))) (EApp (EVar "dupValueBindingErrors") (EVar "prog"))))
(DTypeSig false "dupValueBindingErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "dupValueBindingErrors" ((PVar "prog")) (EApp (EApp (EApp (EVar "dupValGo") (EVar "None")) (EVar "False")) (EVar "prog")))
(DTypeSig false "dupValGo" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "dupValGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "dupValGo" ((PVar "run") (PVar "sawNullary") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "isTransparentDecl") (EVar "d")) (EApp (EApp (EApp (EVar "dupValGo") (EVar "run")) (EVar "sawNullary")) (EVar "rest")) (EIf (EVar "otherwise") (EMatch (EApp (EVar "dupValClause") (EVar "d")) (arm (PCon "Some" (PTuple (PVar "n") (PVar "isNull") (PVar "loc"))) () (EBlock (DoLet false false (PVar "continuing") (EBinOp "==" (EVar "run") (EApp (EVar "Some") (EVar "n")))) (DoLet false false (PVar "dup") (EBinOp "&&" (EVar "continuing") (EBinOp "||" (EVar "sawNullary") (EVar "isNull")))) (DoLet false false (PVar "errs") (EApp (EApp (EVar "whenL") (EVar "dup")) (EListLit (EApp (EApp (EVar "DuplicateValueBinding") (EVar "n")) (EVar "loc"))))) (DoLet false false (PVar "sawNullary2") (EBinOp "||" (EBinOp "&&" (EVar "continuing") (EVar "sawNullary")) (EVar "isNull"))) (DoExpr (EBinOp "++" (EVar "errs") (EApp (EApp (EApp (EVar "dupValGo") (EApp (EVar "Some") (EVar "n"))) (EVar "sawNullary2")) (EVar "rest")))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "dupValGo") (EVar "None")) (EVar "False")) (EVar "rest")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupValClause" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "dupValClause" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "dupValClause") (EVar "d")))
(DFunDef false "dupValClause" ((PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body"))) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EVar "isEmptyL") (EVar "ps")) (EApp (EVar "firstExprLoc") (EVar "body")))))
(DFunDef false "dupValClause" (PWild) (EVar "None"))
(DTypeSig false "isEmptyL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isEmptyL" ((PList)) (EVar "True"))
(DFunDef false "isEmptyL" (PWild) (EVar "False"))
(DTypeSig false "declBindNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declBindNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declBindNames") (EVar "d")))
(DFunDef false "declBindNames" ((PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "declBindNames" ((PCon "DLetGroup" PWild (PVar "bs"))) (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "bs")))
(DFunDef false "declBindNames" (PWild) (EListLit))
(DTypeSig false "isTransparentDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isTransparentDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isTransparentDecl") (EVar "d")))
(DFunDef false "isTransparentDecl" ((PCon "DTypeSig" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isTransparentDecl" (PWild) (EVar "False"))
(DTypeSig false "contiguityErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "contiguityErrors" ((PVar "prog")) (EApp (EApp (EApp (EVar "contigGo") (EVar "omEmpty")) (EListLit)) (EVar "prog")))
(DTypeSig false "contigGo" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "contigGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "contigGo" ((PVar "closed") (PVar "opened") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "isTransparentDecl") (EVar "d")) (EApp (EApp (EApp (EVar "contigGo") (EVar "closed")) (EVar "opened")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "ns") (EApp (EVar "declBindNames") (EVar "d"))) (DoLet false false (PVar "stillOpen") (EApp (EApp (EVar "filterKeepOpen") (EVar "ns")) (EVar "opened"))) (DoLet false false (PVar "nowClosed") (EApp (EApp (EApp (EVar "closeMissing") (EVar "opened")) (EVar "stillOpen")) (EVar "closed"))) (DoLet false false (PVar "errs") (EApp (EApp (EApp (EVar "newlyDuplicated") (EApp (EVar "declLoc") (EVar "d"))) (EVar "nowClosed")) (EVar "ns"))) (DoLet false false (PVar "opened2") (EApp (EApp (EVar "unionStr") (EVar "stillOpen")) (EVar "ns"))) (DoLet false false (PVar "closed2") (EApp (EApp (EVar "deleteAllStr") (EVar "ns")) (EVar "nowClosed"))) (DoExpr (EBinOp "++" (EVar "errs") (EApp (EApp (EApp (EVar "contigGo") (EVar "closed2")) (EVar "opened2")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterKeepOpen" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterKeepOpen" (PWild (PList)) (EListLit))
(DFunDef false "filterKeepOpen" ((PVar "ns") (PCons (PVar "o") (PVar "os"))) (EIf (EApp (EApp (EVar "contains") (EVar "o")) (EVar "ns")) (EBinOp "::" (EVar "o") (EApp (EApp (EVar "filterKeepOpen") (EVar "ns")) (EVar "os"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterKeepOpen") (EVar "ns")) (EVar "os")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeMissing" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "closeMissing" ((PList) PWild (PVar "closed")) (EVar "closed"))
(DFunDef false "closeMissing" ((PCons (PVar "o") (PVar "os")) (PVar "stillOpen") (PVar "closed")) (EIf (EApp (EApp (EVar "contains") (EVar "o")) (EVar "stillOpen")) (EApp (EApp (EApp (EVar "closeMissing") (EVar "os")) (EVar "stillOpen")) (EVar "closed")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "closeMissing") (EVar "os")) (EVar "stillOpen")) (EApp (EApp (EApp (EVar "omInsert") (EVar "o")) (ELit LUnit)) (EVar "closed"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "deleteAllStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "deleteAllStr" ((PList) (PVar "closed")) (EVar "closed"))
(DFunDef false "deleteAllStr" ((PCons (PVar "n") (PVar "ns")) (PVar "closed")) (EApp (EApp (EVar "deleteAllStr") (EVar "ns")) (EApp (EApp (EVar "omDelete") (EVar "n")) (EVar "closed"))))
(DTypeSig false "newlyDuplicated" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "newlyDuplicated" (PWild PWild (PList)) (EListLit))
(DFunDef false "newlyDuplicated" ((PVar "loc") (PVar "closed") (PCons (PVar "n") (PVar "ns"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "closed")) (EBinOp "::" (EApp (EApp (EVar "DuplicateBinding") (EVar "n")) (EVar "loc")) (EApp (EApp (EApp (EVar "newlyDuplicated") (EVar "loc")) (EVar "closed")) (EVar "ns"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "newlyDuplicated") (EVar "loc")) (EVar "closed")) (EVar "ns")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declLoc" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "declLoc" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declLoc") (EVar "d")))
(DFunDef false "declLoc" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "firstExprLoc") (EVar "body")))
(DFunDef false "declLoc" (PWild) (EVar "None"))
(DTypeSig false "firstExprLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstExprLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "firstExprLoc" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "f"))) (EApp (EVar "firstExprLoc") (EVar "x"))))
(DFunDef false "firstExprLoc" ((PCon "ELam" PWild (PVar "body"))) (EApp (EVar "firstExprLoc") (EVar "body")))
(DFunDef false "firstExprLoc" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "e1"))) (EApp (EVar "firstExprLoc") (EVar "e2"))))
(DFunDef false "firstExprLoc" ((PCon "ELetGroup" PWild (PVar "body"))) (EApp (EVar "firstExprLoc") (EVar "body")))
(DFunDef false "firstExprLoc" ((PCon "EMatch" (PVar "e0") PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "c"))) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "t"))) (EApp (EVar "firstExprLoc") (EVar "el")))))
(DFunDef false "firstExprLoc" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "a"))) (EApp (EVar "firstExprLoc") (EVar "b"))))
(DFunDef false "firstExprLoc" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EVar "firstExprLoc") (EVar "a")))
(DFunDef false "firstExprLoc" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "a"))) (EApp (EVar "firstExprLoc") (EVar "b"))))
(DFunDef false "firstExprLoc" ((PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "firstLocList") (EVar "es")))
(DFunDef false "firstExprLoc" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "firstLocList") (EVar "es")))
(DFunDef false "firstExprLoc" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "firstLocList") (EVar "es")))
(DFunDef false "firstExprLoc" ((PCon "EAnnot" (PVar "e0") PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "EHeadAnnot" (PVar "e0") PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "lo"))) (EApp (EVar "firstExprLoc") (EVar "hi"))))
(DFunDef false "firstExprLoc" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "lo"))) (EApp (EVar "firstExprLoc") (EVar "hi"))))
(DFunDef false "firstExprLoc" ((PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "e0"))) (EApp (EVar "firstExprLoc") (EVar "i"))))
(DFunDef false "firstExprLoc" ((PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "e0"))) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "lo"))) (EApp (EVar "firstExprLoc") (EVar "hi")))))
(DFunDef false "firstExprLoc" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "firstExprLoc") (EVar "e")))
(DFunDef false "firstExprLoc" (PWild) (EVar "None"))
(DTypeSig false "firstLocList" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstLocList" ((PList)) (EVar "None"))
(DFunDef false "firstLocList" ((PCons (PVar "e") (PVar "rest"))) (EApp (EApp (EVar "orElseLocL") (EApp (EVar "firstExprLoc") (EVar "e"))) (EApp (EVar "firstLocList") (EVar "rest"))))
(DTypeSig false "orElseLocL" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "orElseLocL" ((PCon "Some" (PVar "l")) PWild) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "orElseLocL" ((PCon "None") (PVar "r")) (EVar "r"))
(DTypeSig false "unionStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "unionStr" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "unionStr" ((PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "acc")) (EApp (EApp (EVar "unionStr") (EVar "acc")) (EVar "xs")) (EIf (EVar "otherwise") (EApp (EApp (EVar "unionStr") (EBinOp "++" (EVar "acc") (EListLit (EVar "x")))) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "externWithBodyErrors" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "externWithBodyErrors" (PWild (PList)) (EListLit))
(DFunDef false "externWithBodyErrors" ((PVar "externs") (PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "externs")) (EListLit (EApp (EApp (EVar "ExternWithBody") (EVar "n")) (EVar "None"))) (EListLit)) (EApp (EApp (EVar "externWithBodyErrors") (EVar "externs")) (EVar "rest"))))
(DFunDef false "externWithBodyErrors" ((PVar "externs") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "externWithBodyErrors") (EVar "externs")) (EVar "rest")))
(DTypeSig false "duplicateErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "duplicateErrors" ((PVar "preludeDecls") (PVar "prog")) (EBlock (DoLet false false (PVar "seed") (EApp (EVar "not") (EApp (EVar "programIsCore") (EVar "prog")))) (DoLet false false (PVar "typeSeed") (EBinOp "++" (EVar "primitiveTypes") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "dataRecordNames") (EVar "preludeDecls"))))) (DoLet false false (PVar "ctorSeed") (EBinOp "++" (EVar "primitiveConstructors") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "ctorNames") (EVar "preludeDecls"))))) (DoLet false false (PVar "ifaceSeed") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "interfaceList") (EVar "preludeDecls"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "dupErr") (ELit (LString "type")))) (EApp (EApp (EVar "findDups") (EVar "typeSeed")) (EApp (EVar "dataRecordNames") (EVar "prog")))) (EApp (EApp (EMethodRef "map") (EApp (EVar "dupErr") (ELit (LString "constructor")))) (EApp (EApp (EVar "findDups") (EVar "ctorSeed")) (EApp (EVar "ctorNames") (EVar "prog"))))) (EApp (EApp (EMethodRef "map") (EApp (EVar "dupErr") (ELit (LString "interface")))) (EApp (EApp (EVar "findDups") (EVar "ifaceSeed")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "interfaceList") (EVar "prog")))))))))
(DTypeSig false "dupErr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "ResError"))))
(DFunDef false "dupErr" ((PVar "kind") (PVar "n")) (EApp (EApp (EApp (EVar "DuplicateDefinition") (EVar "kind")) (EVar "n")) (EVar "None")))
(DTypeSig false "findDups" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "findDups" (PWild (PList)) (EListLit))
(DFunDef false "findDups" ((PVar "seen") (PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "seen")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "findDups") (EVar "seen")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "findDups") (EBinOp "::" (EVar "n") (EVar "seen"))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "resErrorSexp" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "resErrorSexp" ((PCon "UnboundVariable" (PVar "n") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnboundVariable ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnboundVariableExported" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(UnboundVariableExported ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownConstructor" (PVar "n") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownConstructor ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownType" (PVar "n") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownType ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownEffect" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownEffect ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownField" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownField ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "FieldNotInRecord" (PVar "f") (PVar "r") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(FieldNotInRecord ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "f")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "r")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateDefinition" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateDefinition ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "k")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "InternalExternAccess" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(InternalExternAccess ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownInterface" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownInterface ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "MethodNotInInterface" (PVar "m") (PVar "i") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(MethodNotInInterface ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "i")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "ExternWithBody" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(ExternWithBody ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "PrivateNameAccess" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(PrivateNameAccess ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "NoExportedConstructors" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(NoExportedConstructors ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "AbstractFieldAccess" (PVar "t") (PVar "f") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(AbstractFieldAccess ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "t")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "f")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownModule" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownModule ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "NonRecursiveValueLet" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(NonRecursiveValueLet ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateBinding ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateValueBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateValueBinding ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateBinder" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateBinder ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "k")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "AsPatternMisplaced" PWild)) (ELit (LString "AsPatternMisplaced")))
(DFunDef false "resErrorSexp" ((PCon "AmbiguousOccurrence" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(AmbiguousOccurrence ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EApp (EVar "escStr") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "mods"))))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "ReassignImmutable" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(ReassignImmutable ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DTypeSig false "locKey" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locKey" ((PCon "None")) (ELit (LString "-")))
(DFunDef false "locKey" ((PCon "Some" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "el")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ec")))) (ELit (LString ""))))
(DTypeSig false "dedupResErrors" (TyFun (TyApp (TyCon "List") (TyCon "ResError")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "dedupResErrors" ((PVar "es")) (EApp (EApp (EVar "dedupResErrorsGo") (EVar "es")) (EListLit)))
(DTypeSig false "dedupResErrorsGo" (TyFun (TyApp (TyCon "List") (TyCon "ResError")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "dedupResErrorsGo" ((PList) PWild) (EListLit))
(DFunDef false "dedupResErrorsGo" ((PCons (PVar "e") (PVar "es")) (PVar "seen")) (EBlock (DoLet false false (PVar "key") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "resErrorCode") (EVar "e")))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EApp (EVar "ppResError") (EVar "e")))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EApp (EVar "locKey") (EApp (EVar "resErrorLoc") (EVar "e"))))) (ELit (LString "")))) (DoExpr (EIf (EApp (EApp (EVar "contains") (EVar "key")) (EVar "seen")) (EApp (EApp (EVar "dedupResErrorsGo") (EVar "es")) (EVar "seen")) (EBinOp "::" (EVar "e") (EApp (EApp (EVar "dedupResErrorsGo") (EVar "es")) (EBinOp "::" (EVar "key") (EVar "seen"))))))))
(DTypeSig true "resolveProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "resolveProgram" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EApp (EVar "buildEnv") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "prog")) (EListLit))) (DoExpr (EApp (EVar "dedupResErrors") (EBinOp "++" (EApp (EApp (EVar "buildErrors") (EVar "preludeDecls")) (EVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkDecl") (EVar "env"))) (EVar "prog")))))))
(DTypeSig true "resolveProgramG2" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "resolveProgramG2" ((PVar "internalGuard") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EApp (EVar "buildEnv") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "prog")) (EVar "internalGuard"))) (DoExpr (EApp (EVar "dedupResErrors") (EBinOp "++" (EApp (EApp (EVar "buildErrors") (EVar "preludeDecls")) (EVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkDecl") (EVar "env"))) (EVar "prog")))))))
(DTypeSig true "ppResError" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "ppResError" ((PCon "UnboundVariable" (PVar "n") PWild (PVar "s"))) (EMatch (EVar "s") (arm (PCon "Some" (PVar "sug")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unbound variable: ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ". Did you mean '"))) (EApp (EMethodRef "display") (EVar "sug"))) (ELit (LString "'"))) (EApp (EApp (EVar "haskellNote") (EVar "n")) (EVar "sug")))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "Unbound variable: ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))))))
(DFunDef false "ppResError" ((PCon "UnboundVariableExported" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unbound variable: ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ". (Did you forget to 'import "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ".{"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "}'?)"))))
(DFunDef false "ppResError" ((PCon "UnknownConstructor" (PVar "n") PWild (PVar "s"))) (EMatch (EVar "s") (arm (PCon "Some" (PVar "sug")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unknown constructor: ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ". Did you mean '"))) (EApp (EMethodRef "display") (EVar "sug"))) (ELit (LString "'"))) (EApp (EApp (EVar "haskellNote") (EVar "n")) (EVar "sug")))) (arm (PCon "None") () (EBinOp "++" (ELit (LString "Unknown constructor: ")) (EVar "n")))))
(DFunDef false "ppResError" ((PCon "UnknownType" (PVar "n") PWild (PVar "s"))) (EMatch (EVar "s") (arm (PCon "Some" (PVar "sug")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unknown type: ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ". Did you mean '"))) (EApp (EMethodRef "display") (EVar "sug"))) (ELit (LString "'"))) (EApp (EApp (EVar "haskellNote") (EVar "n")) (EVar "sug")))) (arm (PCon "None") () (EBinOp "++" (ELit (LString "Unknown type: ")) (EVar "n")))))
(DFunDef false "ppResError" ((PCon "UnknownEffect" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "Unknown effect: ")) (EVar "n")))
(DFunDef false "ppResError" ((PCon "UnknownField" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "Unknown field: ")) (EVar "n")))
(DFunDef false "ppResError" ((PCon "FieldNotInRecord" (PVar "f") (PVar "r") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unknown field: ")) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString ". Record '"))) (EApp (EMethodRef "display") (EVar "r"))) (ELit (LString "' has no field '"))) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString "'"))))
(DFunDef false "ppResError" ((PCon "DuplicateDefinition" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Duplicate ")) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))))
(DFunDef false "ppResError" ((PCon "UnknownInterface" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "Unknown interface: ")) (EVar "n")))
(DFunDef false "ppResError" ((PCon "MethodNotInInterface" (PVar "m") (PVar "i") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Method '")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "' is not part of interface '"))) (EApp (EMethodRef "display") (EVar "i"))) (ELit (LString "'"))))
(DFunDef false "ppResError" ((PCon "ExternWithBody" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "Extern '")) (EVar "n")) (ELit (LString "' must not have a definition body"))))
(DFunDef false "ppResError" ((PCon "PrivateNameAccess" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Module '")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "' has no exported name '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "'"))))
(DFunDef false "ppResError" ((PCon "NoExportedConstructors" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' exports no constructors from module '"))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "' (exported abstractly). Remove `(..)` or export with `public export`"))))
(DFunDef false "ppResError" ((PCon "AbstractFieldAccess" (PVar "t") (PVar "f") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EMethodRef "display") (EVar "t"))) (ELit (LString "' is exported abstractly. Field '"))) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString "' is not accessible; declare it `public export` to expose its fields"))))
(DFunDef false "ppResError" ((PCon "UnknownModule" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "Unknown module: ")) (EVar "n")))
(DFunDef false "ppResError" ((PCon "AsPatternMisplaced" PWild)) (ELit (LString "`@` as-patterns are only allowed in a binding position (a lambda parameter, a do-block bind, or a match pattern)")))
(DFunDef false "ppResError" ((PCon "NonRecursiveValueLet" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' is not in scope in its own binding. Non-function `let` is not recursive; write `let rec "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " = ...` (RHS must be a lambda)"))))
(DFunDef false "ppResError" ((PCon "DuplicateBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "Clauses of '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' must be contiguous. An earlier same-named binding is separated by another declaration; group all clauses (and the signature) together"))))
(DFunDef false "ppResError" ((PCon "DuplicateValueBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "Duplicate binding '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': it is already defined in this scope. A value binding has exactly one definition — rename this one or remove it"))))
(DFunDef false "ppResError" ((PCon "DuplicateBinder" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Duplicate binder: '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' is bound more than once in this "))) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString ". Each binder must be distinct — rename one occurrence"))))
(DFunDef false "ppResError" ((PCon "AmbiguousOccurrence" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Ambiguous occurrence: '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' is exported by "))) (EApp (EMethodRef "display") (EApp (EVar "ambigModPhrase") (EVar "mods")))) (ELit (LString ". Qualify, or select with `import <mod>.{"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "}`"))))
(DFunDef false "ppResError" ((PCon "InternalExternAccess" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EVar "n")) (ELit (LString "' is an internal-only primitive. Cannot be used outside the standard library (pass --allow-internal to override)"))))
(DFunDef false "ppResError" ((PCon "ReassignImmutable" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Cannot reassign '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' — bindings are immutable. To bind a new value, shadow it with `let "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " = ...`. For mutable state, use a `Ref`: `let "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " = Ref 0`, then write `"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " := "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ".value + 1` (read the cell with `"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ".value`)"))))
(DTypeSig true "resErrorCode" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "resErrorCode" ((PCon "UnboundVariable" PWild PWild PWild)) (ELit (LString "R-UNBOUND")))
(DFunDef false "resErrorCode" ((PCon "UnboundVariableExported" PWild PWild PWild)) (ELit (LString "R-UNBOUND")))
(DFunDef false "resErrorCode" ((PCon "UnknownConstructor" PWild PWild PWild)) (ELit (LString "R-UNKNOWN-CTOR")))
(DFunDef false "resErrorCode" ((PCon "UnknownType" PWild PWild PWild)) (ELit (LString "R-UNKNOWN-TYPE")))
(DFunDef false "resErrorCode" ((PCon "UnknownEffect" PWild PWild)) (ELit (LString "R-UNKNOWN-EFFECT")))
(DFunDef false "resErrorCode" ((PCon "UnknownField" PWild PWild)) (ELit (LString "R-UNKNOWN-FIELD")))
(DFunDef false "resErrorCode" ((PCon "FieldNotInRecord" PWild PWild PWild)) (ELit (LString "R-FIELD-NOT-IN-RECORD")))
(DFunDef false "resErrorCode" ((PCon "DuplicateDefinition" PWild PWild PWild)) (ELit (LString "R-DUPLICATE-DEF")))
(DFunDef false "resErrorCode" ((PCon "UnknownInterface" PWild PWild)) (ELit (LString "R-UNKNOWN-INTERFACE")))
(DFunDef false "resErrorCode" ((PCon "MethodNotInInterface" PWild PWild PWild)) (ELit (LString "R-METHOD-NOT-IN-INTERFACE")))
(DFunDef false "resErrorCode" ((PCon "ExternWithBody" PWild PWild)) (ELit (LString "R-EXTERN-WITH-BODY")))
(DFunDef false "resErrorCode" ((PCon "PrivateNameAccess" PWild PWild PWild)) (ELit (LString "R-PRIVATE-NAME")))
(DFunDef false "resErrorCode" ((PCon "NoExportedConstructors" PWild PWild PWild)) (ELit (LString "R-NO-EXPORTED-CTORS")))
(DFunDef false "resErrorCode" ((PCon "AbstractFieldAccess" PWild PWild PWild)) (ELit (LString "R-ABSTRACT-FIELD")))
(DFunDef false "resErrorCode" ((PCon "UnknownModule" PWild PWild)) (ELit (LString "R-UNKNOWN-MODULE")))
(DFunDef false "resErrorCode" ((PCon "NonRecursiveValueLet" PWild PWild)) (ELit (LString "R-NONREC-VALUE-LET")))
(DFunDef false "resErrorCode" ((PCon "DuplicateBinding" PWild PWild)) (ELit (LString "R-DUPLICATE-BINDING")))
(DFunDef false "resErrorCode" ((PCon "DuplicateValueBinding" PWild PWild)) (ELit (LString "R-DUP-BINDING")))
(DFunDef false "resErrorCode" ((PCon "DuplicateBinder" PWild PWild PWild)) (ELit (LString "R-DUP-BINDER")))
(DFunDef false "resErrorCode" ((PCon "AsPatternMisplaced" PWild)) (ELit (LString "R-AS-PATTERN-MISPLACED")))
(DFunDef false "resErrorCode" ((PCon "AmbiguousOccurrence" PWild PWild PWild)) (ELit (LString "R-AMBIGUOUS-OCCURRENCE")))
(DFunDef false "resErrorCode" ((PCon "InternalExternAccess" PWild PWild)) (ELit (LString "R-INTERNAL-EXTERN")))
(DFunDef false "resErrorCode" ((PCon "ReassignImmutable" PWild PWild)) (ELit (LString "R-IMMUTABLE-ASSIGN")))
(DTypeSig false "ambigModPhrase" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "ambigModPhrase" ((PCons (PVar "a") (PCons (PVar "b") (PList)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "both `")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "` and `"))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "`"))))
(DFunDef false "ambigModPhrase" ((PVar "mods")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "m")) (ELit (LString "`"))))) (EVar "mods"))))
(DTypeSig true "resolveToLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))
(DFunDef false "resolveToLines" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "ppResError")) (EApp (EApp (EApp (EVar "resolveProgram") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "prog")))))
(DTypeSig true "singleFileImportErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "singleFileImportErrors" ((PList)) (EListLit))
(DFunDef false "singleFileImportErrors" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EBinOp "==" (EVar "mid") (ELit (LString "")))) (EApp (EVar "singleFileImportErrors") (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "UnknownModule") (EVar "mid")) (EVar "None")) (EApp (EVar "singleFileImportErrors") (EVar "rest")))))))
(DFunDef false "singleFileImportErrors" ((PCons PWild (PVar "rest"))) (EApp (EVar "singleFileImportErrors") (EVar "rest")))
(DData Public "ModuleExports" () ((variant "ModuleExports" (ConNamed (field "modId" (TyCon "String")) (field "expValues" (TyApp (TyCon "List") (TyCon "String"))) (field "expTypes" (TyApp (TyCon "List") (TyCon "String"))) (field "expCtors" (TyApp (TyCon "List") (TyCon "String"))) (field "expTypeCtors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "expFieldOwners" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expInterfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "expIfaceMethods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "expEffects" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "isNonEmpty" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isNonEmpty" ((PList)) (EVar "False"))
(DFunDef false "isNonEmpty" (PWild) (EVar "True"))
(DTypeSig false "filterContains" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterContains" (PWild (PList)) (EListLit))
(DFunDef false "filterContains" ((PVar "domain") (PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "domain")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "filterContains") (EVar "domain")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterContains") (EVar "domain")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyApp (TyCon "Option") (TyCon "ModuleExports")))))
(DFunDef false "findExports" (PWild (PList)) (EVar "None"))
(DFunDef false "findExports" ((PVar "mid") (PCons (PVar "e") (PVar "rest"))) (EIf (EBinOp "==" (EFieldAccess (EVar "e") "modId") (EVar "mid")) (EApp (EVar "Some") (EVar "e")) (EIf (EVar "otherwise") (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isPubExp" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isPubExp" ((PVar "exp") (PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expValues")) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expTypes"))) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expCtors"))) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expInterfaces"))))
(DTypeSig false "typeCtorsOf" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "typeCtorsOf" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "exp") "expTypeCtors")))
(DTypeSig false "usePathsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "UsePath"))))
(DFunDef false "usePathsOf" ((PList)) (EListLit))
(DFunDef false "usePathsOf" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "::" (EVar "path") (EApp (EVar "usePathsOf") (EVar "rest"))))
(DFunDef false "usePathsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "usePathsOf") (EVar "rest")))
(DTypeSig false "usePathLocsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "UsePath") (TyCon "Loc")))))
(DFunDef false "usePathLocsOf" ((PList)) (EListLit))
(DFunDef false "usePathLocsOf" ((PCons (PCon "DUse" PWild (PVar "path") (PVar "loc")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "path") (EVar "loc")) (EApp (EVar "usePathLocsOf") (EVar "rest"))))
(DFunDef false "usePathLocsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "usePathLocsOf") (EVar "rest")))
(DTypeSig false "pubUsePaths" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "UsePath"))))
(DFunDef false "pubUsePaths" ((PList)) (EListLit))
(DFunDef false "pubUsePaths" ((PCons (PCon "DUse" (PCon "True") (PVar "path") PWild) (PVar "rest"))) (EBinOp "::" (EVar "path") (EApp (EVar "pubUsePaths") (EVar "rest"))))
(DFunDef false "pubUsePaths" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubUsePaths") (EVar "rest")))
(DTypeSig false "importedNamesMM" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "importedNamesMM" ((PCon "UseName" (PVar "ns")) (PVar "exp")) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EBlock (DoLet false false (PVar "nm") (EApp (EVar "lastOf") (EVar "ns"))) (DoExpr (ETuple (EListLit (EVar "nm")) (EApp (EApp (EVar "pubErr") (EVar "exp")) (EVar "nm"))))) (ETuple (EListLit) (EListLit))))
(DFunDef false "importedNamesMM" ((PCon "UseGroup" PWild (PVar "members")) (PVar "exp")) (EBlock (DoLet false false (PVar "expanded") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "expandMemberNames") (EVar "exp"))) (EVar "members"))) (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (EVar "localOfExpanded")) (EVar "expanded"))) (DoLet false false (PVar "expandErrs") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "expandMemberErrs") (EVar "exp"))) (EVar "members"))) (DoExpr (ETuple (EVar "names") (EBinOp "++" (EVar "expandErrs") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "pubErrExpanded") (EVar "exp"))) (EVar "expanded")))))))
(DFunDef false "importedNamesMM" ((PCon "UseWild" PWild) (PVar "exp")) (ETuple (EBinOp "++" (EBinOp "++" (EFieldAccess (EVar "exp") "expValues") (EFieldAccess (EVar "exp") "expTypes")) (EFieldAccess (EVar "exp") "expCtors")) (EListLit)))
(DFunDef false "importedNamesMM" ((PCon "UseAlias" PWild (PVar "a")) (PVar "exp")) (ETuple (EApp (EApp (EMethodRef "map") (EApp (EVar "qualifiedLocal") (EVar "a"))) (EFieldAccess (EVar "exp") "expValues")) (EListLit)))
(DTypeSig false "pubErr" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "pubErr" ((PVar "exp") (PVar "n")) (EIf (EApp (EApp (EVar "isPubExp") (EVar "exp")) (EVar "n")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EFieldAccess (EVar "exp") "modId")) (EVar "None")))))
(DTypeSig false "pubErrLoc" (TyFun (TyCon "ModuleExports") (TyFun (TyTuple (TyCon "String") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "pubErrLoc" ((PVar "exp") (PTuple (PVar "n") (PVar "loc"))) (EIf (EApp (EApp (EVar "isPubExp") (EVar "exp")) (EVar "n")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EFieldAccess (EVar "exp") "modId")) (EApp (EVar "Some") (EVar "loc"))))))
(DTypeSig false "expandMemberNames" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc"))))))
(DFunDef false "expandMemberNames" (PWild (PAs "m" (PCon "UseMember" (PVar "name") (PCon "False") (PVar "loc") PWild))) (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))))
(DFunDef false "expandMemberNames" ((PVar "exp") (PAs "m" (PCon "UseMember" (PVar "name") (PCon "True") (PVar "loc") PWild))) (EMatch (EApp (EApp (EVar "typeCtorsOf") (EVar "name")) (EVar "exp")) (arm (PCon "Some" (PVar "ctors")) () (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (ETuple (EVar "c") (EVar "c") (EVar "loc")))) (EVar "ctors")))) (arm (PCon "None") () (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))))))
(DTypeSig false "localOfExpanded" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "localOfExpanded" ((PTuple PWild (PVar "local") PWild)) (EVar "local"))
(DTypeSig false "pubErrExpanded" (TyFun (TyCon "ModuleExports") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "pubErrExpanded" ((PVar "exp") (PTuple (PVar "origin") PWild (PVar "loc"))) (EApp (EApp (EVar "pubErrLoc") (EVar "exp")) (ETuple (EVar "origin") (EVar "loc"))))
(DTypeSig false "expandMemberErrs" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "expandMemberErrs" (PWild (PCon "UseMember" PWild (PCon "False") PWild PWild)) (EListLit))
(DFunDef false "expandMemberErrs" ((PVar "exp") (PCon "UseMember" (PVar "name") (PCon "True") (PVar "loc") PWild)) (EMatch (EApp (EApp (EVar "typeCtorsOf") (EVar "name")) (EVar "exp")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "exp") "expTypes")) (EListLit (EApp (EApp (EApp (EVar "NoExportedConstructors") (EVar "name")) (EFieldAccess (EVar "exp") "modId")) (EApp (EVar "Some") (EVar "loc")))) (EListLit)))))
(DData Public "ImportAdds" () ((variant "ImportAdds" (ConNamed (field "iaImported" (TyApp (TyCon "List") (TyCon "String"))) (field "iaValues" (TyApp (TyCon "List") (TyCon "String"))) (field "iaTypes" (TyApp (TyCon "List") (TyCon "String"))) (field "iaCtors" (TyApp (TyCon "List") (TyCon "String"))) (field "iaIfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "iaFieldOwners" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "iaErrors" (TyApp (TyCon "List") (TyCon "ResError")))))) ())
(DTypeSig false "emptyAdds" (TyCon "ImportAdds"))
(DFunDef false "emptyAdds" () (ERecordCreate "ImportAdds" ((fa "iaImported" (EListLit)) (fa "iaValues" (EListLit)) (fa "iaTypes" (EListLit)) (fa "iaCtors" (EListLit)) (fa "iaIfaces" (EListLit)) (fa "iaFieldOwners" (EListLit)) (fa "iaErrors" (EListLit)))))
(DTypeSig false "mergeAdds" (TyFun (TyCon "ImportAdds") (TyFun (TyCon "ImportAdds") (TyCon "ImportAdds"))))
(DFunDef false "mergeAdds" ((PVar "a") (PVar "b")) (ERecordCreate "ImportAdds" ((fa "iaImported" (EBinOp "++" (EFieldAccess (EVar "a") "iaImported") (EFieldAccess (EVar "b") "iaImported"))) (fa "iaValues" (EBinOp "++" (EFieldAccess (EVar "a") "iaValues") (EFieldAccess (EVar "b") "iaValues"))) (fa "iaTypes" (EBinOp "++" (EFieldAccess (EVar "a") "iaTypes") (EFieldAccess (EVar "b") "iaTypes"))) (fa "iaCtors" (EBinOp "++" (EFieldAccess (EVar "a") "iaCtors") (EFieldAccess (EVar "b") "iaCtors"))) (fa "iaIfaces" (EBinOp "++" (EFieldAccess (EVar "a") "iaIfaces") (EFieldAccess (EVar "b") "iaIfaces"))) (fa "iaFieldOwners" (EBinOp "++" (EFieldAccess (EVar "a") "iaFieldOwners") (EFieldAccess (EVar "b") "iaFieldOwners"))) (fa "iaErrors" (EBinOp "++" (EFieldAccess (EVar "a") "iaErrors") (EFieldAccess (EVar "b") "iaErrors"))))))
(DTypeSig false "collectImports" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ImportAdds"))))
(DFunDef false "collectImports" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "foldImports") (EVar "known")) (EApp (EVar "usePathLocsOf") (EVar "prog"))))
(DTypeSig false "importValueNames" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importValueNames" ((PVar "known") (PVar "path")) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EApp (EVar "useModId") (EVar "path"))) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EBlock (DoLet false false (PTuple (PVar "names") PWild) (EApp (EApp (EVar "importedNamesMM") (EVar "path")) (EVar "exp"))) (DoExpr (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expValues")) (EVar "names"))))))))
(DTypeSig false "addProvenance" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "addProvenance" ((PList) (PVar "n") (PVar "mid")) (EListLit (ETuple (EVar "n") (EListLit (EVar "mid")))))
(DFunDef false "addProvenance" ((PCons (PTuple (PVar "k") (PVar "mids")) (PVar "rest")) (PVar "n") (PVar "mid")) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EIf (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "mids")) (EBinOp "::" (ETuple (EVar "k") (EVar "mids")) (EVar "rest")) (EBinOp "::" (ETuple (EVar "k") (EBinOp "++" (EVar "mids") (EListLit (EVar "mid")))) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "mids")) (EApp (EApp (EApp (EVar "addProvenance") (EVar "rest")) (EVar "n")) (EVar "mid"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "addImportProvenance" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "addImportProvenance" ((PVar "prov") PWild (PList)) (EVar "prov"))
(DFunDef false "addImportProvenance" ((PVar "prov") (PVar "mid") (PCons (PVar "n") (PVar "rest"))) (EApp (EApp (EApp (EVar "addImportProvenance") (EApp (EApp (EApp (EVar "addProvenance") (EVar "prov")) (EVar "n")) (EVar "mid"))) (EVar "mid")) (EVar "rest")))
(DTypeSig false "valueProvenance" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "valueProvenance" ((PVar "known") (PVar "paths")) (EApp (EApp (EApp (EVar "foldProvenance") (EVar "known")) (EListLit)) (EVar "paths")))
(DTypeSig false "foldProvenance" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "foldProvenance" (PWild (PVar "prov") (PList)) (EVar "prov"))
(DFunDef false "foldProvenance" ((PVar "known") (PVar "prov") (PCons (PVar "p") (PVar "rest"))) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "p"))) (DoLet false false (PVar "prov2") (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EVar "prov") (EApp (EApp (EApp (EVar "addImportProvenance") (EVar "prov")) (EVar "mid")) (EApp (EApp (EVar "importValueNames") (EVar "known")) (EVar "p"))))) (DoExpr (EApp (EApp (EApp (EVar "foldProvenance") (EVar "known")) (EVar "prov2")) (EVar "rest")))))
(DTypeSig false "ambiguousSet" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ambiguousSet" ((PVar "known") (PVar "prog")) (EBlock (DoLet false false (PVar "prov") (EApp (EApp (EVar "valueProvenance") (EVar "known")) (EApp (EVar "usePathsOf") (EVar "prog")))) (DoLet false false (PVar "sameMod") (EApp (EVar "userValueNames") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "keepAmbiguous") (EVar "sameMod")) (EVar "prov")))))
(DTypeSig false "keepAmbiguous" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "keepAmbiguous" (PWild (PList)) (EListLit))
(DFunDef false "keepAmbiguous" ((PVar "sameMod") (PCons (PTuple (PVar "n") (PVar "mids")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "mids")) (ELit (LInt 2))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "sameMod")))) (EBinOp "::" (ETuple (EVar "n") (EVar "mids")) (EApp (EApp (EVar "keepAmbiguous") (EVar "sameMod")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "keepAmbiguous") (EVar "sameMod")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "foldImports" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "UsePath") (TyCon "Loc"))) (TyCon "ImportAdds"))))
(DFunDef false "foldImports" (PWild (PList)) (EVar "emptyAdds"))
(DFunDef false "foldImports" ((PVar "known") (PCons (PTuple (PVar "p") (PVar "loc")) (PVar "rest"))) (EApp (EApp (EVar "mergeAdds") (EApp (EApp (EApp (EVar "oneImport") (EVar "known")) (EVar "p")) (EVar "loc"))) (EApp (EApp (EVar "foldImports") (EVar "known")) (EVar "rest"))))
(DTypeSig false "oneImport" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyCon "ImportAdds")))))
(DFunDef false "oneImport" ((PVar "known") (PVar "path") (PVar "loc")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EVar "emptyAdds") (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "stubOrUnknown") (EVar "known")) (EVar "path")) (EVar "mid")) (EVar "loc"))) (arm (PCon "Some" (PVar "exp")) () (EApp (EApp (EApp (EVar "realImport") (EVar "exp")) (EVar "path")) (EVar "loc"))))))))
(DTypeSig false "stubOrUnknown" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "ImportAdds"))))))
(DFunDef false "stubOrUnknown" ((PVar "known") (PVar "path") (PVar "mid") (PVar "loc")) (EIf (EApp (EVar "isNonEmpty") (EVar "known")) (ERecordCreate "ImportAdds" ((fa "iaImported" (EListLit)) (fa "iaValues" (EListLit)) (fa "iaTypes" (EListLit)) (fa "iaCtors" (EListLit)) (fa "iaIfaces" (EListLit)) (fa "iaFieldOwners" (EListLit)) (fa "iaErrors" (EListLit (EApp (EApp (EVar "UnknownModule") (EVar "mid")) (EApp (EVar "Some") (EVar "loc"))))))) (EBlock (DoLet false false (PVar "names") (EApp (EVar "useStubNames") (EVar "path"))) (DoExpr (ERecordCreate "ImportAdds" ((fa "iaImported" (EVar "names")) (fa "iaValues" (EVar "names")) (fa "iaTypes" (EVar "names")) (fa "iaCtors" (EListLit)) (fa "iaIfaces" (EListLit)) (fa "iaFieldOwners" (EListLit)) (fa "iaErrors" (EListLit))))))))
(DTypeSig false "realImport" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyCon "ImportAdds")))))
(DFunDef false "realImport" ((PVar "exp") (PVar "path") (PVar "loc")) (EBlock (DoLet false false (PTuple (PVar "names") (PVar "errs")) (EApp (EApp (EVar "importedNamesMM") (EVar "path")) (EVar "exp"))) (DoExpr (ERecordCreate "ImportAdds" ((fa "iaImported" (EVar "names")) (fa "iaValues" (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expValues")) (EVar "names"))) (fa "iaTypes" (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expTypes")) (EVar "names"))) (fa "iaCtors" (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expCtors")) (EVar "names"))) (fa "iaIfaces" (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expInterfaces")) (EVar "names"))) (fa "iaFieldOwners" (EApp (EApp (EVar "ownedFieldOwners") (EVar "exp")) (EFieldAccess (EVar "exp") "expFieldOwners"))) (fa "iaErrors" (EApp (EApp (EMethodRef "map") (EApp (EVar "withResErrorLoc") (EVar "loc"))) (EVar "errs"))))))))
(DTypeSig false "withResErrorLoc" (TyFun (TyCon "Loc") (TyFun (TyCon "ResError") (TyCon "ResError"))))
(DFunDef false "withResErrorLoc" ((PVar "loc") (PCon "PrivateNameAccess" (PVar "n") (PVar "m") (PCon "None"))) (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "loc"))))
(DFunDef false "withResErrorLoc" (PWild (PCon "PrivateNameAccess" (PVar "n") (PVar "m") (PCon "Some" (PVar "l")))) (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "l"))))
(DFunDef false "withResErrorLoc" ((PVar "loc") (PCon "NoExportedConstructors" (PVar "n") (PVar "m") (PCon "None"))) (EApp (EApp (EApp (EVar "NoExportedConstructors") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "loc"))))
(DFunDef false "withResErrorLoc" (PWild (PCon "NoExportedConstructors" (PVar "n") (PVar "m") (PCon "Some" (PVar "l")))) (EApp (EApp (EApp (EVar "NoExportedConstructors") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "l"))))
(DFunDef false "withResErrorLoc" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "ownedFieldOwners" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "ownedFieldOwners" (PWild (PList)) (EListLit))
(DFunDef false "ownedFieldOwners" ((PVar "exp") (PCons (PTuple (PVar "f") (PVar "o")) (PVar "rest"))) (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "o")) (EFieldAccess (EVar "exp") "expTypes")) (EApp (EApp (EVar "contains") (EVar "o")) (EFieldAccess (EVar "exp") "expCtors"))) (EBinOp "::" (ETuple (EVar "f") (EVar "o")) (EApp (EApp (EVar "ownedFieldOwners") (EVar "exp")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ownedFieldOwners") (EVar "exp")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "importedIfaceMethods" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "importedIfaceMethods" ((PVar "known") (PVar "prog") (PVar "baseIfaces")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "oneImportIfaceMethods") (EVar "known")) (EVar "baseIfaces"))) (EApp (EVar "usePathsOf") (EVar "prog"))))
(DTypeSig false "oneImportIfaceMethods" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "oneImportIfaceMethods" ((PVar "known") (PVar "baseIfaces") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EApp (EApp (EVar "filterIfaceMethods") (EVar "baseIfaces")) (EFieldAccess (EVar "exp") "expIfaceMethods"))))))))
(DTypeSig false "filterIfaceMethods" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "filterIfaceMethods" (PWild (PList)) (EListLit))
(DFunDef false "filterIfaceMethods" ((PVar "baseIfaces") (PCons (PTuple (PVar "iface") (PVar "ms")) (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EVar "baseIfaces")) (EBinOp "::" (ETuple (EVar "iface") (EVar "ms")) (EApp (EApp (EVar "filterIfaceMethods") (EVar "baseIfaces")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterIfaceMethods") (EVar "baseIfaces")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "importedEffects" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importedEffects" ((PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "oneImportEffects") (EVar "known"))) (EApp (EVar "usePathsOf") (EVar "prog"))))
(DTypeSig false "oneImportEffects" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "oneImportEffects" ((PVar "known") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EFieldAccess (EVar "exp") "expEffects")))))))
(DTypeSig false "buildEnvMM" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyCon "Env") (TyApp (TyCon "List") (TyCon "ResError")))))))))
(DFunDef false "buildEnvMM" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "known") (PVar "prog") (PVar "internalGuard")) (EBlock (DoLet false false (PVar "seed") (EApp (EVar "not") (EApp (EVar "programIsCore") (EVar "prog")))) (DoLet false false (PVar "pTypes") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "dataRecordNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pCtors") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "ctorNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pIfaces") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "interfaceList") (EVar "preludeDecls")))) (DoLet false false (PVar "pValues") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "preludeValueNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pFieldOwners") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "fieldOwnersOf") (EVar "preludeDecls")))) (DoLet false false (PVar "uIfaces") (EApp (EVar "interfaceList") (EVar "prog"))) (DoLet false false (PVar "adds") (EApp (EApp (EVar "collectImports") (EVar "known")) (EVar "prog"))) (DoLet false false (PVar "baseIfaces") (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "pIfaces")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "uIfaces"))) (EFieldAccess (EVar "adds") "iaIfaces"))) (DoLet false false (PVar "impIfaceMethods") (EApp (EApp (EApp (EVar "importedIfaceMethods") (EVar "known")) (EVar "prog")) (EVar "baseIfaces"))) (DoLet false false (PVar "impEffects") (EApp (EApp (EVar "importedEffects") (EVar "known")) (EVar "prog"))) (DoLet false false (PVar "impModValues") (EApp (EApp (EVar "importedModuleValueSets") (EVar "known")) (EVar "prog"))) (DoLet false false (PVar "env") (ERecordCreate "Env" ((fa "values" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "externNames") (EVar "runtimeDecls")) (EVar "pValues")) (EApp (EVar "userValueNames") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaValues"))) (fa "types" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "primitiveTypes") (EVar "pTypes")) (EApp (EVar "dataRecordNames") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaTypes"))) (fa "ctors" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "primitiveConstructors") (EVar "pCtors")) (EApp (EVar "ctorNames") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaCtors"))) (fa "fields" (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "pFieldOwners")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "fieldOwnersOf") (EVar "prog")))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EFieldAccess (EVar "adds") "iaFieldOwners")))) (fa "fieldOwners" (EBinOp "++" (EBinOp "++" (EVar "pFieldOwners") (EApp (EVar "fieldOwnersOf") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaFieldOwners"))) (fa "interfaces" (EVar "baseIfaces")) (fa "ifaceMethods" (EBinOp "++" (EBinOp "++" (EVar "pIfaces") (EVar "uIfaces")) (EVar "impIfaceMethods"))) (fa "effects" (EBinOp "++" (EApp (EVar "effectNames") (EVar "prog")) (EVar "impEffects"))) (fa "imported" (EFieldAccess (EVar "adds") "iaImported")) (fa "importedModuleValues" (EVar "impModValues")) (fa "ambiguous" (EApp (EApp (EVar "ambiguousSet") (EVar "known")) (EVar "prog"))) (fa "internalGuard" (EVar "internalGuard"))))) (DoExpr (ETuple (EVar "env") (EFieldAccess (EVar "adds") "iaErrors")))))
(DTypeSig false "importedModuleValueSets" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "importedModuleValueSets" ((PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "oneImportedModuleValues") (EVar "known"))) (EApp (EVar "usePathsOf") (EVar "prog"))))
(DTypeSig false "oneImportedModuleValues" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "oneImportedModuleValues" ((PVar "known") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EListLit (ETuple (EVar "mid") (EFieldAccess (EVar "exp") "expValues")))))))))
(DTypeSig false "buildExports" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Env") (TyCon "ModuleExports"))))))
(DFunDef false "buildExports" ((PVar "known") (PVar "modId") (PVar "prog") (PVar "env")) (ERecordCreate "ModuleExports" ((fa "modId" (EVar "modId")) (fa "expValues" (EBinOp "++" (EBinOp "++" (EApp (EVar "expValuesDirect") (EVar "prog")) (EApp (EApp (EVar "publicIfaceMethodVals") (EVar "prog")) (EVar "env"))) (EApp (EApp (EVar "reExpValues") (EVar "known")) (EVar "prog")))) (fa "expTypes" (EBinOp "++" (EApp (EVar "expTypesDirect") (EVar "prog")) (EApp (EApp (EVar "reExpTypes") (EVar "known")) (EVar "prog")))) (fa "expCtors" (EBinOp "++" (EApp (EVar "expCtorsDirect") (EVar "prog")) (EApp (EApp (EVar "reExpCtors") (EVar "known")) (EVar "prog")))) (fa "expTypeCtors" (EApp (EVar "expTypeCtorsDirect") (EVar "prog"))) (fa "expFieldOwners" (EBinOp "++" (EApp (EVar "expFieldOwnersDirect") (EVar "prog")) (EApp (EApp (EVar "reExpFieldOwners") (EVar "known")) (EVar "prog")))) (fa "expInterfaces" (EBinOp "++" (EApp (EVar "expInterfacesDirect") (EVar "prog")) (EApp (EApp (EVar "reExpInterfaces") (EVar "known")) (EVar "prog")))) (fa "expIfaceMethods" (EBinOp "++" (EApp (EVar "expIfaceMethodsDirect") (EVar "prog")) (EApp (EApp (EVar "reExpIfaceMethods") (EVar "known")) (EVar "prog")))) (fa "expEffects" (EBinOp "++" (EApp (EVar "expEffectsDirect") (EVar "prog")) (EApp (EApp (EVar "reExpEffects") (EVar "known")) (EVar "prog")))))))
(DTypeSig false "expValuesDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expValuesDirect" ((PList)) (EListLit))
(DFunDef false "expValuesDirect" ((PCons (PCon "DTypeSig" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expValuesDirect") (EVar "rest"))))
(DFunDef false "expValuesDirect" ((PCons (PCon "DExtern" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expValuesDirect") (EVar "rest"))))
(DFunDef false "expValuesDirect" ((PCons (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expValuesDirect") (EVar "rest"))))
(DFunDef false "expValuesDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expValuesDirect") (EVar "rest")))
(DTypeSig false "publicIfaceMethodVals" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Env") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "publicIfaceMethodVals" ((PVar "prog") (PVar "env")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "keepBoundMethods") (EVar "env"))) (EApp (EVar "pubIfaceMethodSets") (EVar "prog"))))
(DTypeSig false "keepBoundMethods" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "keepBoundMethods" ((PVar "env") (PVar "ms")) (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "env") "values")) (EVar "ms")))
(DTypeSig false "pubIfaceMethodSets" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "pubIfaceMethodSets" ((PList)) (EListLit))
(DFunDef false "pubIfaceMethodSets" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "pubIfaceMethodSets") (EVar "rest"))))
(DFunDef false "pubIfaceMethodSets" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubIfaceMethodSets") (EVar "rest")))
(DTypeSig false "expTypesDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expTypesDirect" ((PList)) (EListLit))
(DFunDef false "expTypesDirect" ((PCons (PCon "DNewtype" (PCon "True") (PVar "n") PWild PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons (PCon "DData" (PCon "VisPublic") (PVar "n") PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons (PCon "DData" (PCon "VisAbstract") (PVar "n") PWild PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons (PCon "DTypeAlias" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expTypesDirect") (EVar "rest")))
(DTypeSig false "expCtorsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expCtorsDirect" ((PList)) (EListLit))
(DFunDef false "expCtorsDirect" ((PCons (PCon "DNewtype" (PCon "True") PWild PWild (PVar "con") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "con") (EApp (EVar "expCtorsDirect") (EVar "rest"))))
(DFunDef false "expCtorsDirect" ((PCons (PCon "DData" (PCon "VisPublic") PWild PWild (PVar "vs") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "variantName")) (EVar "vs")) (EApp (EVar "expCtorsDirect") (EVar "rest"))))
(DFunDef false "expCtorsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expCtorsDirect") (EVar "rest")))
(DTypeSig false "expTypeCtorsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "expTypeCtorsDirect" ((PList)) (EListLit))
(DFunDef false "expTypeCtorsDirect" ((PCons (PCon "DNewtype" (PCon "True") (PVar "n") PWild (PVar "con") PWild PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EListLit (EVar "con"))) (EApp (EVar "expTypeCtorsDirect") (EVar "rest"))))
(DFunDef false "expTypeCtorsDirect" ((PCons (PCon "DData" (PCon "VisPublic") (PVar "n") PWild (PVar "vs") PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "variantName")) (EVar "vs"))) (EApp (EVar "expTypeCtorsDirect") (EVar "rest"))))
(DFunDef false "expTypeCtorsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expTypeCtorsDirect") (EVar "rest")))
(DTypeSig false "expFieldOwnersDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "expFieldOwnersDirect" ((PList)) (EListLit))
(DFunDef false "expFieldOwnersDirect" ((PCons (PCon "DData" (PCon "VisPublic") PWild PWild (PVar "vs") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "variantFieldOwners")) (EVar "vs")) (EApp (EVar "expFieldOwnersDirect") (EVar "rest"))))
(DFunDef false "expFieldOwnersDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expFieldOwnersDirect") (EVar "rest")))
(DTypeSig false "expInterfacesDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expInterfacesDirect" ((PList)) (EListLit))
(DFunDef false "expInterfacesDirect" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" (PVar "n"))) true) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expInterfacesDirect") (EVar "rest"))))
(DFunDef false "expInterfacesDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expInterfacesDirect") (EVar "rest")))
(DTypeSig false "expIfaceMethodsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "expIfaceMethodsDirect" ((PList)) (EListLit))
(DFunDef false "expIfaceMethodsDirect" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" (PVar "n")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods"))) (EApp (EVar "expIfaceMethodsDirect") (EVar "rest"))))
(DFunDef false "expIfaceMethodsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expIfaceMethodsDirect") (EVar "rest")))
(DTypeSig false "expEffectsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expEffectsDirect" ((PList)) (EListLit))
(DFunDef false "expEffectsDirect" ((PCons (PCon "DEffect" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expEffectsDirect") (EVar "rest"))))
(DFunDef false "expEffectsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expEffectsDirect") (EVar "rest")))
(DTypeSig false "reExpEffects" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpEffects" ((PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "overPubUse") (EVar "known")) (EVar "reExpEffectsFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpEffectsFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpEffectsFrom" ((PCon "UseWild" PWild) (PVar "src")) (EFieldAccess (EVar "src") "expEffects"))
(DFunDef false "reExpEffectsFrom" (PWild PWild) (EListLit))
(DTypeSig false "reexportBindings" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportBindings" ((PCon "UseName" (PVar "ns")) PWild) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "lastOf") (EVar "ns"))) (DoExpr (EListLit (ETuple (EVar "n") (EVar "n"))))) (EListLit)))
(DFunDef false "reexportBindings" ((PCon "UseGroup" PWild (PVar "members")) (PVar "src")) (EApp (EApp (EMethodRef "map") (EVar "dropLocOfExpanded")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "expandMemberNames") (EVar "src"))) (EVar "members"))))
(DFunDef false "reexportBindings" ((PCon "UseWild" PWild) (PVar "src")) (EApp (EApp (EMethodRef "map") (EVar "selfBinding")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EFieldAccess (EVar "src") "expValues") (EFieldAccess (EVar "src") "expTypes")) (EFieldAccess (EVar "src") "expCtors")) (EFieldAccess (EVar "src") "expInterfaces"))))
(DFunDef false "reexportBindings" ((PCon "UseAlias" PWild PWild) PWild) (EListLit))
(DTypeSig false "dropLocOfExpanded" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc")) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "dropLocOfExpanded" ((PTuple (PVar "origin") (PVar "local") PWild)) (ETuple (EVar "origin") (EVar "local")))
(DTypeSig false "selfBinding" (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "selfBinding" ((PVar "n")) (ETuple (EVar "n") (EVar "n")))
(DTypeSig false "localsExportedFrom" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "localsExportedFrom" ((PVar "origins") (PVar "bindings")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "contains") (EApp (EVar "fst") (EVar "b"))) (EVar "origins")))) (EVar "bindings"))))
(DTypeSig false "reExpValues" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpValues" ((PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "overPubUse") (EVar "known")) (EVar "reExpValuesFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpValuesFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpValuesFrom" ((PVar "path") (PVar "src")) (EBlock (DoLet false false (PVar "bindings") (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expValues")) (EVar "bindings")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "ifaceValsOf") (EVar "src"))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "bindings")))))))
(DTypeSig false "ifaceValsOf" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceValsOf" ((PVar "src") (PVar "n")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "src") "expInterfaces")) (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expValues")) (EApp (EApp (EVar "ifaceMethodsOf") (EVar "n")) (EFieldAccess (EVar "src") "expIfaceMethods"))) (EListLit)))
(DTypeSig false "reExpTypes" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpTypes" ((PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "overPubUse") (EVar "known")) (EVar "reExpTypesFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpTypesFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpTypesFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expTypes")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpCtors" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpCtors" ((PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "overPubUse") (EVar "known")) (EVar "reExpCtorsFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpCtorsFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpCtorsFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expCtors")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpInterfaces" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpInterfaces" ((PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "overPubUse") (EVar "known")) (EVar "reExpInterfacesFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reexportOrigins" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reexportOrigins" ((PVar "path") (PVar "src")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpInterfacesFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpInterfacesFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expInterfaces")) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpIfaceMethods" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reExpIfaceMethods" ((PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "overPubUse") (EVar "known")) (EVar "reExpIfaceMethodsFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpIfaceMethodsFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reExpIfaceMethodsFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "ifaceMethodPairs") (EVar "src")) (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expInterfaces")) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src")))))
(DTypeSig false "ifaceMethodPairs" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ifaceMethodPairs" (PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodPairs" ((PVar "src") (PCons (PVar "i") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "i") (EApp (EApp (EVar "ifaceMethodsOf") (EVar "i")) (EFieldAccess (EVar "src") "expIfaceMethods"))) (EApp (EApp (EVar "ifaceMethodPairs") (EVar "src")) (EVar "rest"))))
(DTypeSig false "reExpFieldOwners" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reExpFieldOwners" ((PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "overPubUse") (EVar "known")) (EVar "reExpFieldOwnersFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpFieldOwnersFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reExpFieldOwnersFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "ownersForTypes") (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expTypes")) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src")))) (EFieldAccess (EVar "src") "expFieldOwners")))
(DTypeSig false "ownersForTypes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "ownersForTypes" (PWild (PList)) (EListLit))
(DFunDef false "ownersForTypes" ((PVar "types") (PCons (PTuple (PVar "f") (PVar "o")) (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "o")) (EVar "types")) (EBinOp "::" (ETuple (EVar "f") (EVar "o")) (EApp (EApp (EVar "ownersForTypes") (EVar "types")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ownersForTypes") (EVar "types")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "overPubUse" (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyVar "b")))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyVar "b"))))))
(DFunDef false "overPubUse" ((PVar "known") (PVar "f") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "f") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "resolveModule" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "ResError")))))))))
(DFunDef false "resolveModule" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "known") (PVar "modId") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModuleG") (EListLit)) (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "known")) (EVar "modId")) (EVar "prog")))
(DTypeSig true "resolveModuleG" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "ResError"))))))))))
(DFunDef false "resolveModuleG" ((PVar "internalGuard") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "known") (PVar "modId") (PVar "prog")) (EBlock (DoLet false false (PTuple (PVar "env") (PVar "importErrs")) (EApp (EApp (EApp (EApp (EApp (EVar "buildEnvMM") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "known")) (EVar "prog")) (EVar "internalGuard"))) (DoLet false false (PVar "errs") (EApp (EVar "dedupResErrors") (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "buildErrors") (EVar "preludeDecls")) (EVar "prog")) (EVar "importErrs")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkDecl") (EVar "env"))) (EVar "prog"))))) (DoLet false false (PVar "exp") (EApp (EApp (EApp (EApp (EVar "buildExports") (EVar "known")) (EVar "modId")) (EVar "prog")) (EVar "env"))) (DoExpr (ETuple (EVar "exp") (EVar "errs")))))
(DTypeSig false "resolveModulesErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "resolveModulesErrors" ((PVar "rt") (PVar "pre") (PVar "known") (PVar "mods")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsG") (EVar "True")) (EListLit)) (EVar "rt")) (EVar "pre")) (EVar "known")) (EVar "mods")))
(DTypeSig false "resolveModulesErrorsG" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ResError")))))))))
(DFunDef false "resolveModulesErrorsG" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "resolveModulesErrorsG" ((PVar "allowInternal") (PVar "trustedMods") (PVar "rt") (PVar "pre") (PVar "known") (PCons (PTuple (PVar "mid") (PVar "prog")) (PVar "rest"))) (EBlock (DoLet false false (PVar "guard") (EIf (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trustedMods"))) (EListLit) (EVar "internalExterns"))) (DoLet false false (PTuple (PVar "exp") (PVar "errs")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModuleG") (EDictApp "guard")) (EVar "rt")) (EVar "pre")) (EVar "known")) (EVar "mid")) (EVar "prog"))) (DoExpr (EBinOp "++" (EVar "errs") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "rt")) (EVar "pre")) (EBinOp "::" (EVar "exp") (EVar "known"))) (EVar "rest"))))))
(DTypeSig true "resolveModulesToLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))
(DFunDef false "resolveModulesToLines" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "resErrorSexp")) (EApp (EApp (EApp (EApp (EVar "resolveModulesErrors") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EListLit)) (EVar "mods")))))
(DTypeSig true "resolveModulesToLinesG" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))))
(DFunDef false "resolveModulesToLinesG" ((PVar "allowInternal") (PVar "trustedMods") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "resErrorSexp")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "runtimeDecls")) (EVar "preludeDecls")) (EListLit)) (EVar "mods")))))
(DTypeSig true "resolveModulesToHumane" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))
(DFunDef false "resolveModulesToHumane" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "ppResErrorLocated")) (EApp (EApp (EApp (EApp (EVar "resolveModulesErrors") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EListLit)) (EVar "mods")))))
(DTypeSig true "resolveModulesToHumaneG" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))))
(DFunDef false "resolveModulesToHumaneG" ((PVar "allowInternal") (PVar "trustedMods") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "ppResErrorLocated")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "runtimeDecls")) (EVar "preludeDecls")) (EListLit)) (EVar "mods")))))
(DTypeSig true "resolveModulesToHumaneGF" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))))))
(DFunDef false "resolveModulesToHumaneGF" ((PVar "fallbackFile") (PVar "allowInternal") (PVar "trustedMods") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EVar "ppResErrorLocatedF") (EVar "fallbackFile"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "runtimeDecls")) (EVar "preludeDecls")) (EListLit)) (EVar "mods")))))
(DTypeSig true "ppResErrorLocated" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "ppResErrorLocated" ((PVar "e")) (EApp (EApp (EVar "ppResErrorLocatedF") (ELit (LString ""))) (EVar "e")))
(DTypeSig true "ppResErrorLocatedF" (TyFun (TyCon "String") (TyFun (TyCon "ResError") (TyCon "String"))))
(DFunDef false "ppResErrorLocatedF" ((PVar "fallbackFile") (PVar "e")) (EMatch (EApp (EVar "resErrorLoc") (EVar "e")) (arm (PCon "None") () (EBinOp "++" (ELit (LString "<unknown location>: ")) (EApp (EVar "ppResError") (EVar "e")))) (arm (PCon "Some" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") PWild PWild)) () (EBlock (DoLet false false (PVar "ff") (EIf (EBinOp "==" (EVar "f") (ELit (LString ""))) (EVar "fallbackFile") (EVar "f"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ff"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "ppResError") (EVar "e")))) (ELit (LString ""))))))))
