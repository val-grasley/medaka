# META
source_lines=859
stages=DESUGAR,MARK
# SOURCE
-- UNIVERSAL PER-MODULE NAME MANGLING for the flat multi-module EMIT path.
--
-- The gap-tolerant / multi-module emit drivers FLATTEN every module's decls into
-- one program and name each top-level function by its BARE name (`@mdk_<name>`).
-- Two modules that define a same-named top-level function therefore COLLIDE: only
-- one `@mdk_<name>` survives, and references in BOTH modules route to the surviving
-- one → wrong dispatch / SIGSEGV.  This bit (a) the native lexer's `lex_main.emit`
-- vs `lexer.emit` (private/private) and (b) the native CLI's `repl.isIdentChar :
-- String -> Bool` vs `lsp.isIdentChar : Char -> Bool` (private/private, different
-- arity-compatible types) — and equally bites any EXPORTED pair that happens to
-- share a name.
--
-- FIX — universal mangling: EVERY top-level FUNCTION binding (in core + every
-- module) is renamed to a module-qualified unique symbol `<mid>__<name>`, and
-- EVERY reference is rewritten IMPORT-AWARE to its resolved origin module's
-- mangled name.  Collisions are then impossible BY CONSTRUCTION — no two surviving
-- `@mdk_<sym>` symbols can coincide.
--
-- IMPORT-AWARE RESOLUTION is the crux.  For a (non-shadowed) reference to bare
-- name `n` in unit `mid` we must know WHICH module's definition it binds:
--   1. `n` defined locally in `mid`              → `<mid>__<n>`   (local shadows imports)
--   2. else `n` brought in by a `DUse` of module `M` (UseGroup member / UseWild /
--      UseName stub / UseAlias)                  → `<M>__<n>`
--   3. else `n` defined in core (implicit prelude, imported by every unit) → `core__<n>`
--   4. else (extern C symbol, constructor, interface/impl method, unknown free
--      name) → LEFT UNCHANGED.
-- The per-unit import structure comes straight from the unit's `DUse` decls + the
-- per-module set of EXPORTED (pub) function names — both already present at the
-- mangle point (the `(mid, decls)` units).  No resolve.mdk change is needed: a
-- per-unit LOCAL-name → origin-module map is sufficient.
--
-- IMPORT ALIASING does not perturb any of this, because it only changes what the
-- LOCAL name is, never the shape of the map:
--   `import M.{a as b}`  → local `b`      ↦ `<M>__a`   (origin ≠ local)
--   `import M as A`      → local `A.<n>`  ↦ `<M>__<n>`, for every export `n` of M
-- The `A.<n>` local is the flat name `frontend/desugar.mdk` produces for the qualified
-- reference `A.n` (a dot cannot occur in a surface identifier, so it is collision-free).
-- Mapping it here is exactly what ERASES the alias from the emitted code — no dotted
-- name ever reaches the output.  Note the two-sided consequence: the symbol is always
-- rebuilt from the ORIGIN (`mangledName definer origin`), never from the local, which is
-- why a RE-EXPORTED alias is rejected in the parser — a module's export table maps
-- (name → definer) and could not express "the export `b` is really `a`".
--
-- EXCLUDED (never mangled):
--   • the entry `main` — the emitter emits it as `@main`, the program entry point
--     (llvm_emit.mdk `isFnBind (CBind "main" _) = False`); renaming it would lose
--     the entry.  Excluded as both a definition and a reference target.
--   • externs / runtime C symbols (`@mdk_<externName>` → runtime/medaka_rt.c) —
--     they are declared in runtime.mdk (NOT in core/modules), so they never appear
--     as a definition here; a reference to one is excluded by rule 4 (not in any
--     unit's defined-fn set nor import scope).
--   • interface/impl method names, dict names — they have their own naming in the
--     emitter (impl keys), and are not DFunDef/DData binders this pass touches.
--   • RESERVED constructors (Cons/Nil/Some/None/Ok/Err/Lt/Eq/Gt/True/False) — the
--     emitter gives these fixed reserved tags (llvm_emit.mdk `reservedTag`); mangling
--     would lose the tag.  Excluded at the ctor-export step (`isReservedCtor`).
--
-- CONSTRUCTOR MANGLING (the cross-module ctor-name-collision fix).  The flat emit
-- path also folds EVERY module's `DData`/`DNewtype` ctors into ONE global
-- bare-name-keyed ctor table (arity / tag / type-id / ordinal in llvm_emit.mdk).
-- Two ADTs in different modules declaring a same-named ctor with DIFFERENT arity
-- therefore COLLAPSE into one entry — a nullary ctor inheriting a payload ctor's
-- arity is emitted as a boxed cell instead of an immediate → corrupted value →
-- SIGSEGV (the interpreter is immune: it is structural, no arity table).  Fix: the
-- SAME universal per-module mangling, extended to constructors — every NON-reserved
-- ctor is renamed `<owningMid>__<ctor>` at its DEFINITION (DData variant /
-- DNewtype con) AND at every USE site (EVar construct, PCon / PRec match,
-- ERecordCreate, EVariantUpdate), import-aware (a `import M.{T(..)}` maps T's ctors
-- to `<M>__<ctor>`).  Collisions are then impossible by construction; the per-site
-- owning module comes from the importing unit's scope, so construct and match always
-- agree.  The gates diff OUTPUT, so a consistent ctor rename is invisible.
--
-- This runs PER UNIT, BEFORE elaborateModules flattens the boundaries away.  It
-- lives ONLY in the emit drivers (never the oracle/golden drivers), so every
-- golden/oracle dump is unchanged.  The gates diff program OUTPUT, so a consistent
-- rename is invisible to them — but a reference rewritten to the WRONG origin
-- module's symbol changes output and is caught.
--
-- The reference rewrite is SCOPE-AWARE: a reference to top-level `f` is renamed
-- only where `f` is the FREE top-level name, NOT where a local binder (parameter /
-- let / lambda arg / match-pattern var) named `f` shadows it.  Mirrors the
-- binder-threading of typecheck.mdk's `rewriteArgScoped`.

import frontend.ast.{
  Decl(..),
  Expr(..),
  Pat(..),
  Arm(..),
  Guard(..),
  GuardArm(..),
  DoStmt(..),
  Section(..),
  InterpPart(..),
  FieldAssign(..),
  RecPatField(..),
  LetBind(..),
  FunClause(..),
  IfaceMethod(..),
  MethodDefault(..),
  ImplMethod(..),
  PropParam(..),
  UsePath(..),
  UseMember(..),
  useMemberOrigin,
  useMemberLocal,
  qualifiedLocal,
  Variant(..),
}
import support.util.{
  contains,
  reverseL,
  isEmptyL,
  filterList,
  initList,
  joinDot,
  dedup,
}
-- The per-unit rename map is applied to EVERY reference in the unit (one lookup
-- per EVar / def-name / pattern ctor). Backing it with the String-keyed
-- weight-balanced tree (support.ordmap) makes each lookup O(log n) instead of an
-- O(map) linear `lookupAssoc` scan — the map is built once per unit in mangleUnitU.
import support.ordmap.{OrdMap, omLookup, omFromPairs, omEmpty, omSize}

-- ── entry point ───────────────────────────────────────────────────────────────
-- Given the core unit and every (mid, decls) module, module-qualify EVERY
-- top-level function (except `main` / excluded), rewriting all references
-- import-aware to their origin module's mangled name.  Returns the rewritten
-- (coreDecls, modules) in the same shape `runEmit` already threads to
-- elaborateModules.
export mangleUnits : List Decl -> List (String, List Decl) -> (List Decl, List (String, List Decl))
mangleUnits coreDecls modules =
  let allUnits = ("core", coreDecls)::modules
  let exportsPerUnit = buildExportsPerUnit [] allUnits
  let ctorExportsPerUnit = map unitCtorExportEntry allUnits
  let coreOut = mangleUnitU exportsPerUnit ctorExportsPerUnit ("core", coreDecls)
  let modsOut = map (mangleModule exportsPerUnit ctorExportsPerUnit) modules
  (coreOut, modsOut)
-- Per-unit CONSTRUCTOR exports: (mid, [(typeName, [ctorName])]).  Mirrors
-- exportsPerUnit but for data/record/newtype ctors, so an importing unit can map
-- `import M.{T(..)}` / `import M.{Ctor}` to `<M>__<Ctor>` (see ctorImportEntries).

-- exported (pub) top-level function names of a unit, each paired with the module
-- that ACTUALLY defines it.  For a locally-defined pub fn the definer is the unit
-- itself; for a name brought in by `export import` (a `DUse True` re-export) the
-- definer is chased through the re-export chain to the ORIGINAL owning module
-- (mirroring eval.mdk's `pubReexports`), so an importer of a re-exported name
-- mangles its reference to `<originalDefiner>__<name>`, NOT `<reExporter>__<name>`
-- (the re-exporter has no backing DFunDef → the reference would be orphaned/unbound
-- at emit).  Built as a dependency-ordered fold so a re-export can consult the
-- source module's already-computed exports (loader order is dependency-first — the
-- same invariant eval.mdk's buildModInfos relies on).
buildExportsPerUnit : List (String, List (String, String)) -> List (String, List Decl) -> List (String, List (String, String))
buildExportsPerUnit _ [] = []
buildExportsPerUnit acc ((mid, decls)::rest) =
  let entry = unitExportEntry acc (mid, decls)
  entry :: buildExportsPerUnit (entry::acc) rest

unitExportEntry : List (String, List (String, String)) -> (String, List Decl) -> (String, List (String, String))
unitExportEntry acc (mid, decls) =
  let locals = map (n => (n, mid)) (dedup (pubFnNames decls))
  let reexs = flatMap (reexportFnEntries acc) decls
  (mid, dedupPairsByName (locals ++ reexs))

-- names a `DUse True` (re-export) decl brings in, each paired with its ORIGINAL
-- definer (looked up transitively in `acc` — the source module's already-computed
-- export pairs, so a >1-hop re-export chain still resolves to the true owner).
-- Mirrors eval.mdk's `reexport`/`resolveMembers`.
reexportFnEntries : List (String, List (String, String)) -> Decl -> List (String, String)
reexportFnEntries acc (DUse True path _) =
  let srcMid = useModIdU path
  match lookupExports srcMid acc
    None => []
    Some srcExports => reexportMembers path srcExports
reexportFnEntries acc (DAttrib _ d) = reexportFnEntries acc d
reexportFnEntries _ _ = []

reexportMembers : UsePath -> List (String, String) -> List (String, String)
reexportMembers (UseGroup _ members) srcExports =
  flatMap (reexportMember srcExports) members
reexportMembers (UseWild _) srcExports = srcExports
reexportMembers (UseName ns) srcExports =
  if lenGt1 ns then
    reexportOne srcExports (lastOfPM ns)
  else
    []
reexportMembers (UseAlias _ _) _ = []

reexportMember : List (String, String) -> UseMember -> List (String, String)
reexportMember srcExports m = reexportOne srcExports (useMemberOrigin m)

reexportOne : List (String, String) -> String -> List (String, String)
reexportOne srcExports n = match lookupDefiner n srcExports
  Some definer => [(n, definer)]
  None => []

-- keep the FIRST occurrence of each name — locals are prepended, so a locally
-- defined pub fn wins over a re-export of the same name.
dedupPairsByName : List (String, String) -> List (String, String)
dedupPairsByName pairs = dedupPairsGo pairs []

dedupPairsGo : List (String, String) -> List String -> List (String, String)
dedupPairsGo [] _ = []
dedupPairsGo ((n, d)::rest) seen =
  if contains n seen then
    dedupPairsGo rest seen
  else
    (n, d) :: dedupPairsGo rest (n::seen)

lookupDefiner : String -> List (String, String) -> Option String
lookupDefiner _ [] = None
lookupDefiner k ((n, d)::rest) = if k == n then Some d else lookupDefiner k rest

-- ── per-unit CONSTRUCTOR exports ──────────────────────────────────────────────
-- (mid, [(typeName, [ctorName])]) for every data/record/newtype the unit declares.
-- A reserved constructor (Cons/Nil/Some/None/Ok/Err/Lt/Eq/Gt/True/False — the
-- emitter's fixed-tag set) is OMITTED so it is never mangled (mangling would lose
-- its reserved tag).  Visibility is not gated here: the import side only resolves
-- what the importing unit actually brings into scope, and unmangled-because-private
-- is harmless (an unimported ctor is never referenced cross-unit).
unitCtorExportEntry : (String, List Decl) -> (String, List (String, List String))
unitCtorExportEntry (mid, decls) = (mid, flatMap ctorExportEntries decls)

ctorExportEntries : Decl -> List (String, List String)
ctorExportEntries (DData _ tyname _ variants _) =
  [(tyname, filterList nonReservedCtor (map variantCtorName variants))]
ctorExportEntries (DNewtype _ tyname _ con _ _) =
  if nonReservedCtor con then
    [(tyname, [con])]
  else
    []
ctorExportEntries (DAttrib _ d) = ctorExportEntries d
ctorExportEntries _ = []

variantCtorName : Variant -> String
variantCtorName (Variant n _) = n

-- The emitter's fixed-tag constructors (reservedTag + True/False immediates in
-- llvm_emit.mdk).  Mangling any of these would break the reserved-tag match.
nonReservedCtor : String -> Bool
nonReservedCtor n = not (isReservedCtor n)

isReservedCtor : String -> Bool
isReservedCtor n = n == "Cons"
  || n == "Nil"
  || n == "Some"
  || n == "None"
  || n == "Ok"
  || n == "Err"
  || n == "Lt"
  || n == "Eq"
  || n == "Gt"
  || n == "True"
  || n == "False"

-- ── the unit's CONSTRUCTOR rename map ─────────────────────────────────────────
-- local ctors → `<mid>__<ctor>` (local shadows imports), then imported ctors →
-- `<originMid>__<ctor>`, then core's ctors as implicit-prelude entries.  Keyed by
-- bare ctor name; reserved ctors are excluded at the export step so they never
-- enter the map.
buildUnitCtorRenameMap : String -> List (String, List (String, List String)) -> List Decl -> List (String, String)
buildUnitCtorRenameMap mid ctorExportsPerUnit decls =
  let localCtors = dedup (unitLocalCtorNames decls)
  let localEntries = flatMap (localCtorRenameEntry mid) localCtors
  let importEntries = ctorImportEntries mid ctorExportsPerUnit decls
  localEntries ++ importEntries

-- local (this-unit-declared) constructor names, reserved ones excluded.
unitLocalCtorNames : List Decl -> List String
unitLocalCtorNames decls =
  filterList nonReservedCtor (flatMap localCtorNames decls)

localCtorNames : Decl -> List String
localCtorNames (DData _ _ _ variants _) = map variantCtorName variants
localCtorNames (DNewtype _ _ _ con _ _) = [con]
localCtorNames (DAttrib _ d) = localCtorNames d
localCtorNames _ = []

localCtorRenameEntry : String -> String -> List (String, String)
localCtorRenameEntry mid n = [(n, mangledName mid n)]

-- imported ctors: for each `DUse` of a non-core module M, the ctor names it brings
-- in (a `T(..)` member expands to all of M's ctors of type T; a bare `Ctor` member
-- maps that single name if M exports it) → `<M>__<ctor>`.  Plus core's exported
-- ctors as implicit prelude (`Rep`'s RCon/RInt/… — Ordering/Option/Result ctors are
-- reserved and were never entered).  Local-first ordering already shadows these.
ctorImportEntries : String -> List (String, List (String, List String)) -> List Decl -> List (String, String)
ctorImportEntries _ ctorExportsPerUnit decls = flatMap (declCtorImportEntries ctorExportsPerUnit) decls
  ++ coreCtorImportEntries ctorExportsPerUnit

coreCtorImportEntries : List (String, List (String, List String)) -> List (String, String)
coreCtorImportEntries ctorExportsPerUnit = match lookupCtorExports "core" ctorExportsPerUnit
  Some entries => flatMap coreCtorEntry entries
  None => []

coreCtorEntry : (String, List String) -> List (String, String)
coreCtorEntry (_, ctors) = flatMap (n => [(n, mangledName "core" n)]) ctors

declCtorImportEntries : List (String, List (String, List String)) -> Decl -> List (String, String)
declCtorImportEntries ctorExportsPerUnit (DUse _ path _) =
  useCtorPathEntries ctorExportsPerUnit path
declCtorImportEntries ctorExportsPerUnit (DAttrib _ d) =
  declCtorImportEntries ctorExportsPerUnit d
declCtorImportEntries _ _ = []

useCtorPathEntries : List (String, List (String, List String)) -> UsePath -> List (String, String)
useCtorPathEntries ctorExportsPerUnit path =
  let mid = useModIdU path
  if mid == "core" then []
  else match lookupCtorExports mid ctorExportsPerUnit
    None => []
    Some typeEntries => match path
      UseGroup _ members => flatMap (ctorMemberEntry mid typeEntries) members
      UseWild _ => flatMap (typeCtorEntries mid) typeEntries
      UseName _ => []
      UseAlias _ _ => []
-- `import M.{T(..), Ctor, …}`: a `(..)` member is a TYPE whose ctors all come
-- in; a bare member may be either a ctor name or a type — entered if it names
-- a ctor M exports (a type-only member contributes nothing here).

-- `import M.*`: every ctor M exports comes into scope.

-- a UseGroup member → ctor entries.  `UseMember name True` (`name(..)`) expands to
-- all of type `name`'s ctors; `UseMember name False` enters `name` itself iff it is
-- one of M's exported ctors.
ctorMemberEntry : String -> List (String, List String) -> UseMember -> List (String, String)
ctorMemberEntry mid typeEntries (UseMember name wild _ _) =
  if wild then match lookupCtorTypeEntry name typeEntries
    Some ctors => flatMap (originCtorEntry mid) ctors
    None => []
  else if contains name (flatMap snd typeEntries) then originCtorEntry mid name else []

typeCtorEntries : String -> (String, List String) -> List (String, String)
typeCtorEntries mid (_, ctors) = flatMap (originCtorEntry mid) ctors

originCtorEntry : String -> String -> List (String, String)
originCtorEntry mid n = [(n, mangledName mid n)]

lookupCtorTypeEntry : String -> List (String, List String) -> Option (List String)
lookupCtorTypeEntry _ [] = None
lookupCtorTypeEntry k ((t, cs)::rest) =
  if k == t then
    Some cs
  else
    lookupCtorTypeEntry k rest

lookupCtorExports : String -> List (String, List (String, List String)) -> Option (List (String, List String))
lookupCtorExports _ [] = None
lookupCtorExports k ((m, es)::rest) =
  if k == m then
    Some es
  else
    lookupCtorExports k rest

-- a module keeps its mid in the output pair.
mangleModule : List (String, List (String, String)) -> List (String, List (String, List String)) -> (String, List Decl) -> (String, List Decl)
mangleModule exportsPerUnit ctorExportsPerUnit (mid, decls) =
  (mid, mangleUnitU exportsPerUnit ctorExportsPerUnit (mid, decls))

-- ── per-unit universal rename ────────────────────────────────────────────────
-- For one unit: build the combined rename map (own top-level fns → `<mid>__<name>`,
-- PLUS each imported bare name → its origin module's mangled symbol), then rewrite
-- the unit's decls (definition names + all in-scope references).
mangleUnitU : List (String, List (String, String)) -> List (String, List (String, List String)) -> (String, List Decl) -> List Decl
mangleUnitU exportsPerUnit ctorExportsPerUnit (mid, decls) =
  let rmFn = buildUnitRenameMap mid exportsPerUnit decls
  let rmCtor = buildUnitCtorRenameMap mid ctorExportsPerUnit decls
  let rmList = rmFn ++ rmCtor
  -- omFromPairs over the REVERSED list so the FIRST list entry wins on a duplicate
  -- key — byte-identical to the old first-match `lookupAssoc n rmList`.
  let rm = omFromPairs (reverseL rmList) omEmpty
  if isEmptyL rmList then decls else map (renameDecl rm) decls
-- Function and constructor names occupy disjoint namespaces (ctors Capitalized,
-- fns lowercase), so the two bare-name maps merge without key conflict.  A merged
-- single map lets renameScoped's existing EVar arm rewrite a nullary/partial ctor
-- reference, and renameDecl/renamePat add the def-site + pattern ctor rewrites.

-- The unit's rename map.  Order matters: LOCAL definitions are prepended LAST so a
-- local def shadows an imported same-named binding (lookupAssoc is first-match).
buildUnitRenameMap : String -> List (String, List (String, String)) -> List Decl -> List (String, String)
buildUnitRenameMap mid exportsPerUnit decls =
  let localFns = dedup (unitDefNames (mid, decls))
  let localEntries = flatMap (localRenameEntry mid) localFns
  let importEntries = importRenameEntries mid exportsPerUnit decls
  localEntries ++ importEntries
-- local first ⇒ shadows any imported entry with the same key under lookupAssoc.

-- a local top-level fn → its module-qualified symbol, UNLESS excluded (`main`).
localRenameEntry : String -> String -> List (String, String)
localRenameEntry mid n
  | isExcludedName n = []
  | otherwise = [(n, mangledName mid n)]

-- `main` is the program entry (`@main`); never mangle it.
isExcludedName : String -> Bool
isExcludedName n = n == "main"

-- ── import-aware reference targets ───────────────────────────────────────────
-- For each `DUse` of a non-core module `M`, the bare names it brings into this
-- unit map to `M`'s mangled symbols.  Plus the implicit prelude: every core
-- export is in scope as `core__<name>` (a local def shadows it via local-first
-- ordering; an explicit import of the same name from a sibling shadows core via
-- import-entry ordering below).
-- explicit sibling imports first (they shadow the implicit prelude), prelude last.
importRenameEntries : String -> List (String, List (String, String)) -> List Decl -> List (String, String)
importRenameEntries _ exportsPerUnit decls = flatMap (declImportEntries exportsPerUnit) decls
  ++ coreImportEntries exportsPerUnit

-- core's exports as implicit-prelude entries (`name → core__name`), excluding
-- `main` (core has none, but be safe).
coreImportEntries : List (String, List (String, String)) -> List (String, String)
coreImportEntries exportsPerUnit = match lookupExports "core" exportsPerUnit
  Some names => flatMap coreEntry names
  None => []

coreEntry : (String, String) -> List (String, String)
coreEntry (n, definer)
  | isExcludedName n = []
  | otherwise = [(n, mangledName definer n)]

-- a single `DUse path` → the (bareName, originMangled) entries it introduces.
declImportEntries : List (String, List (String, String)) -> Decl -> List (String, String)
declImportEntries exportsPerUnit (DUse _ path _) =
  usePathEntries exportsPerUnit path
declImportEntries exportsPerUnit (DAttrib _ d) =
  declImportEntries exportsPerUnit d
declImportEntries _ _ = []

-- the LOCAL names a UsePath brings in, each mapped to its ORIGIN's real symbol
-- `<originMid>__<name>`.  Only names that are EXPORTED FUNCTIONS of the origin module
-- are entered (a member that is a type/ctor/value isn't a top-level fn symbol, so leave
-- it unchanged).
--   UseGroup `import M.{a, b}`      → only the listed members ∩ M's exports
--   UseGroup `import M.{a as b}`    → local `b` → M's `a` symbol
--   UseWild  `import M.*`           → every exported fn of M
--   UseName  `import M[.sub]`       → the single stub name (last component), if an export
--   UseAlias `import M as A`        → every exported fn of M, under `A.<name>`
--
-- The UseAlias case is what erases a module alias from the emitted code: desugar turned
-- the qualified reference into the flat name `A.name`, and this maps that name onto M's
-- real symbol.  No dotted name ever reaches the LLVM/Wasm output.
usePathEntries : List (String, List (String, String)) -> UsePath -> List (String, String)
usePathEntries exportsPerUnit path =
  let mid = useModIdU path
  if mid == "core" then []
  else match lookupExports mid exportsPerUnit
    None => []
    Some exports => match path
      UseGroup _ members => flatMap (memberEntry exports) members
      UseWild _ => flatMap originEntryPair exports
      UseName ns => originEntry exports (lastOfPM ns)
      UseAlias _ a => flatMap (aliasEntryPair a) exports

-- a UseGroup member → entry if its ORIGIN names an exported fn of the origin module;
-- the entry is keyed by the member's LOCAL name (its alias, if it has one).
memberEntry : List (String, String) -> UseMember -> List (String, String)
memberEntry exports m =
  originEntryAs exports (useMemberOrigin m) (useMemberLocal m)

-- bare name `n` → `<definer>__<n>` iff `n` is an exported fn of the imported module
-- (`exports` is that module's (name, definer) pairs).  For a RE-EXPORTED name the
-- definer is the ORIGINAL owning module, so the reference points at the real symbol
-- rather than the re-exporter's non-existent one.
originEntry : List (String, String) -> String -> List (String, String)
originEntry exports n = originEntryAs exports n n

-- like originEntry, but the entry is keyed by an arbitrary LOCAL name (an alias).
originEntryAs : List (String, String) -> String -> String -> List (String, String)
originEntryAs exports origin local
  | isExcludedName origin = []
  | otherwise = match lookupDefiner origin exports
    Some definer => [(local, mangledName definer origin)]
    None => []

-- a wildcard import iterates the (name, definer) pairs directly.
originEntryPair : (String, String) -> List (String, String)
originEntryPair (n, definer)
  | isExcludedName n = []
  | otherwise = [(n, mangledName definer n)]

-- a module alias iterates the same pairs, keying each under `A.<name>`.
aliasEntryPair : String -> (String, String) -> List (String, String)
aliasEntryPair a (n, definer)
  | isExcludedName n = []
  | otherwise = [(qualifiedLocal a n, mangledName definer n)]

useModIdU : UsePath -> String
useModIdU (UseName ns) =
  if lenGt1 ns then
    joinDot (initList ns)
  else
    firstOrU "" ns
useModIdU (UseGroup ns _) = joinDot ns
useModIdU (UseWild ns) = joinDot ns
useModIdU (UseAlias ns _) = joinDot ns

lenGt1 : List a -> Bool
lenGt1 (_::_::_) = True
lenGt1 _ = False

firstOrU : String -> List String -> String
firstOrU d [] = d
firstOrU _ (x::_) = x

lastOfPM : List String -> String
lastOfPM [] = ""
lastOfPM [x] = x
lastOfPM (_::rest) = lastOfPM rest

lookupExports : String -> List (String, List (String, String)) -> Option (List (String, String))
lookupExports _ [] = None
lookupExports k ((m, ns)::rest) =
  if k == m then
    Some ns
  else
    lookupExports k rest

-- ── exported (pub) function names of a unit ──────────────────────────────────
-- A name is an exported function symbol if EITHER its DFunDef clause carries
-- `pub = True`, OR a `pub` DTypeSig/DExtern of that name precedes it (the `export`
-- keyword precedes the SIGNATURE; the definition clause parses as a private
-- DFunDef — mirroring resolve.mdk's `expValuesDirect`).  We also count pub
-- DLetGroup binders.  Restricted to names that are ALSO defined as functions in
-- this unit (a pub DTypeSig with no body isn't an emittable symbol).
pubFnNames : List Decl -> List String
pubFnNames decls =
  let defined = unitDefNames ("", decls)
  let pubSigs = pubSigNames decls
  let pubDefs = pubDefNames decls
  filterList (n => contains n defined) (pubSigs ++ pubDefs)

-- names whose DFunDef / DLetGroup binder is itself `pub = True`.
pubDefNames : List Decl -> List String
pubDefNames [] = []
pubDefNames ((DFunDef True n _ _)::rest) = n :: pubDefNames rest
pubDefNames ((DLetGroup True binds)::rest) = map letBindName binds
  ++ pubDefNames rest
pubDefNames ((DAttrib _ d)::rest) = pubDefNames [d] ++ pubDefNames rest
pubDefNames (_::rest) = pubDefNames rest

-- ── collision-name detection (RETAINED — kept available, no longer the trigger) ──
-- all top-level FUNCTION names defined in a unit (DFunDef + DLetGroup binders),
-- wrapped through DAttrib.  Only function-shaped decls can collide as @mdk_<name>.
unitDefNames : (String, List Decl) -> List String
unitDefNames (_, decls) = flatMap declDefNames decls

declDefNames : Decl -> List String
declDefNames (DFunDef _ n _ _) = [n]
declDefNames (DLetGroup _ binds) = map letBindName binds
declDefNames (DAttrib _ d) = declDefNames d
declDefNames _ = []

letBindName : LetBind -> String
letBindName (LetBind n _) = n

-- names exported via a `pub` DTypeSig/DExtern in this unit (so their DFunDef
-- clauses, which parse private, still count as exported function symbols).
pubSigNames : List Decl -> List String
pubSigNames [] = []
pubSigNames ((DTypeSig True n _)::rest) = n :: pubSigNames rest
pubSigNames ((DExtern True n _)::rest) = n :: pubSigNames rest
pubSigNames ((DAttrib _ d)::rest) = pubSigNames [d] ++ pubSigNames rest
pubSigNames (_::rest) = pubSigNames rest

-- `<mid>__<name>` with the mid sanitized to a valid identifier (`/`, `.`, `-` →
-- `_`).  The emitted symbol is `@mdk_<thisname>`, so only [A-Za-z0-9_] are safe.
export mangledName : String -> String -> String
mangledName mid name = "\{sanitizeId mid}__\{name}"

sanitizeId : String -> String
sanitizeId s = sanitizeGo s 0 (stringLength s) ""

sanitizeGo : String -> Int -> Int -> String -> String
sanitizeGo s i len acc =
  if i >= len then acc
  else
    let c = stringSlice i (i + 1) s
    let c2 = if safeChar c then c else "_"
    sanitizeGo s (i + 1) len (acc ++ c2)

export safeChar : String -> Bool
safeChar c = c >= "a" && c <= "z"
  || c >= "A" && c <= "Z"
  || c >= "0" && c <= "9"
  || c == "_"

-- hashName: a deterministic djb2 string hash (seed 5381), computed in the EMITTER
-- (the emitted IR carries the decimal constant).  Shared by BOTH backends so the
-- dict-witness tag / route-key dispatch agrees across LLVM and WasmGC — the hash
-- MUST be byte-identical between them.
export hashName : String -> Int
hashName s = hashChars (stringToChars s) 0 5381

hashChars : Array Char -> Int -> Int -> Int
hashChars cs i acc
  | i >= arrayLength cs = acc
  | otherwise = hashChars cs (i + 1) (acc * 33 + charCode (arrayGetUnsafe i cs))

-- ── decl rewrite (rename both the DEFINITION name and all references) ─────────
renameDecl : OrdMap String -> Decl -> Decl
renameDecl rm (DFunDef pub n ps e) =
  DFunDef
    pub
    (renameDefName rm n)
    (renamePatsPM rm ps)
    (renameScoped rm (patVarsListPM ps) e)
-- a top-level signature (`f : …` / `export f : …`) shares the function's name; it
-- MUST be renamed in lockstep with its DFunDef so the typechecker keys f's scheme
-- under the SAME mangled name the call sites + def now use (else dictPass /
-- publicValNames see `clampU` while the def is `<mid>__clampU` → unbound).
renameDecl rm (DTypeSig pub n ty) = DTypeSig pub (renameDefName rm n) ty
renameDecl rm (d@(DInterface { methods, ... })) =
  DInterface { d | methods = map (renameIfaceMethod rm) methods }
renameDecl rm (d@(DImpl { methods, ... })) =
  DImpl { d | methods = map (renameImplMethod rm) methods }
renameDecl rm (DProp pub name params body) =
  DProp pub name params (renameScoped rm (propParamNamesPM params) body)
renameDecl rm (DTest pub name body) = DTest pub name (renameScoped rm [] body)
renameDecl rm (DBench pub name body) = DBench pub name (renameScoped rm [] body)
renameDecl rm (DLetGroup pub binds) =
  DLetGroup pub (map (renameLetBindDef rm) binds)
-- DATA / NEWTYPE definition sites: rename the constructor names (which the
-- emitter's ctor tables key on) in lockstep with the use-site rewrites below.  The
-- DData TYPE name is left as-is (it is only the VALUE in buildCtorToType — ctorsOf-
-- Type groups by it but never emits it as a symbol); a record (the `data X = { … }`
-- short form) is a ConNamed variant renamed like any ctor; a DNewtype's con is its
-- ctor.  Reserved ctors are not in `rm`
-- (excluded at export), so renameDefName leaves them unchanged.
renameDecl rm (DData vis tyname tps variants derives) =
  DData vis tyname tps (map (renameVariant rm) variants) derives
renameDecl rm (DNewtype pub tyname tps con fty derives) =
  DNewtype pub tyname tps (renameDefName rm con) fty derives
renameDecl rm (DAttrib attrs d) = DAttrib attrs (renameDecl rm d)
renameDecl _ d = d

-- rename a data variant's constructor name (payload types are unaffected).
renameVariant : OrdMap String -> Variant -> Variant
renameVariant rm (Variant n payload) = Variant (renameDefName rm n) payload

-- top-level LetBind in a DLetGroup: rename the binder name (if in map) AND its
-- clause bodies.  The group's own names are in scope across all clauses.
renameLetBindDef : OrdMap String -> LetBind -> LetBind
renameLetBindDef rm (LetBind n clauses) =
  LetBind (renameDefName rm n) (map (renameFunClause rm []) clauses)

renameDefName : OrdMap String -> String -> String
renameDefName rm n = match omLookup n rm
  Some n2 => n2
  None => n

renameIfaceMethod : OrdMap String -> IfaceMethod -> IfaceMethod
renameIfaceMethod _ (IfaceMethod n ty None) = IfaceMethod n ty None
renameIfaceMethod rm (IfaceMethod n ty (Some (MethodDefault ps e))) =
  IfaceMethod
    n
    ty
    (Some (MethodDefault
      (renamePatsPM rm ps)
      (renameScoped rm (patVarsListPM ps) e)))

renameImplMethod : OrdMap String -> ImplMethod -> ImplMethod
renameImplMethod rm (ImplMethod n ps e) =
  ImplMethod n (renamePatsPM rm ps) (renameScoped rm (patVarsListPM ps) e)

propParamNamesPM : List PropParam -> List String
propParamNamesPM ps = map propParamNamePM ps

propParamNamePM : PropParam -> String
propParamNamePM (PropParam n _) = n

-- ── the scope-threaded reference rewrite ──────────────────────────────────────
-- `bound` = names shadowed by a local binder at this node.  An EVar is renamed
-- only when it is in the map AND NOT shadowed.  Binders extend `bound`.  Mirrors
-- typecheck.mdk's rewriteArgScoped exactly.
renameScoped : OrdMap String -> List String -> Expr -> Expr
renameScoped rm bound (EVar n)
  | not (contains n bound) = match omLookup n rm
    Some n2 => EVar n2
    None => EVar n
  | otherwise = EVar n
-- binders
renameScoped rm bound (ELam ps body) =
  ELam (renamePatsPM rm ps) (renameScoped rm (patVarsListPM ps ++ bound) body)
renameScoped rm bound (ELet m r p e1 e2) =
  let pv = patVarsPM p
  let b1 = if r then pv ++ bound else bound
  ELet
    m
    r
    (renamePat rm p)
    (renameScoped rm b1 e1)
    (renameScoped rm (pv ++ bound) e2)
renameScoped rm bound (ELetGroup binds e2) =
  let bnd = letBindNamesPM binds ++ bound
  ELetGroup (map (renameLetBind rm bnd) binds) (renameScoped rm bnd e2)
renameScoped rm bound (EMatch e0 arms) =
  EMatch (renameScoped rm bound e0) (map (renameArm rm bound) arms)
renameScoped rm bound (EBlock stmts) = EBlock (renameStmts rm bound stmts)
renameScoped rm bound (EDo stmts) = EDo (renameStmts rm bound stmts)
-- non-binder composites: recurse children with the same bound
renameScoped rm bound (ELoc l e) = ELoc l (renameScoped rm bound e)
renameScoped rm bound (EDoOrigin l e) = EDoOrigin l (renameScoped rm bound e)
renameScoped rm bound (EApp f x) =
  EApp (renameScoped rm bound f) (renameScoped rm bound x)
renameScoped rm bound (EIf c t e) =
  EIf
    (renameScoped rm bound c)
    (renameScoped rm bound t)
    (renameScoped rm bound e)
renameScoped rm bound (EBinOp op l r dr) =
  EBinOp op (renameScoped rm bound l) (renameScoped rm bound r) dr
renameScoped rm bound (EUnOp op x dr) = EUnOp op (renameScoped rm bound x) dr
renameScoped rm bound (EInfix op l r) =
  EInfix op (renameScoped rm bound l) (renameScoped rm bound r)
renameScoped rm bound (EFieldAccess e0 n r) =
  EFieldAccess (renameScoped rm bound e0) n r
renameScoped rm bound (ETuple es) = ETuple (map (renameScoped rm bound) es)
renameScoped rm bound (EListLit es) = EListLit (map (renameScoped rm bound) es)
renameScoped rm bound (EArrayLit es) =
  EArrayLit (map (renameScoped rm bound) es)
renameScoped rm bound (ERangeList lo hi i) =
  ERangeList (renameScoped rm bound lo) (renameScoped rm bound hi) i
renameScoped rm bound (ERangeArray lo hi i) =
  ERangeArray (renameScoped rm bound lo) (renameScoped rm bound hi) i
renameScoped rm bound (ESlice e0 lo hi i r) =
  ESlice
    (renameScoped rm bound e0)
    (renameScoped rm bound lo)
    (renameScoped rm bound hi)
    i
    r
renameScoped rm bound (EIndex e0 i r) =
  EIndex (renameScoped rm bound e0) (renameScoped rm bound i) r
renameScoped rm bound (EAnnot e0 t) = EAnnot (renameScoped rm bound e0) t
renameScoped rm bound (EHeadAnnot e0 t) =
  EHeadAnnot (renameScoped rm bound e0) t
renameScoped rm bound (ERecordCreate n fs) =
  ERecordCreate (renameDefName rm n) (map (renameField rm bound) fs)
renameScoped rm bound (ERecordUpdate e0 fs) =
  ERecordUpdate (renameScoped rm bound e0) (map (renameField rm bound) fs)
renameScoped rm bound (EVariantUpdate c e0 fs) =
  EVariantUpdate
    (renameDefName rm c)
    (renameScoped rm bound e0)
    (map (renameField rm bound) fs)
renameScoped rm bound (EStringInterp parts) =
  EStringInterp (map (renameInterp rm bound) parts)
renameScoped rm bound (EGuards arms) =
  EGuards (map (renameGuardArm rm bound) arms)
renameScoped rm bound (ESection (SecRight op e0)) =
  ESection (SecRight op (renameScoped rm bound e0))
renameScoped rm bound (ESection (SecLeft e0 op)) =
  ESection (SecLeft (renameScoped rm bound e0) op)
renameScoped rm bound (EMapLit n kvs) = EMapLit n (map (renameKv rm bound) kvs)
renameScoped rm bound (ESetLit n es) =
  ESetLit n (map (renameScoped rm bound) es)
renameScoped rm bound (EAsPat x sub) = EAsPat x (renameScoped rm bound sub)
-- leaves (ELit / EMethodRef / EDictApp / EVarAt / EMethodAt / EDictAt / SecBare)
renameScoped _ _ e = e

renameField : OrdMap String -> List String -> FieldAssign -> FieldAssign
renameField rm bound (FieldAssign n e) = FieldAssign n (renameScoped rm bound e)

renameKv : OrdMap String -> List String -> (Expr, Expr) -> (Expr, Expr)
renameKv rm bound (k, v) = (renameScoped rm bound k, renameScoped rm bound v)

renameInterp : OrdMap String -> List String -> InterpPart -> InterpPart
renameInterp _ _ (InterpStr s) = InterpStr s
renameInterp rm bound (InterpExpr e) = InterpExpr (renameScoped rm bound e)

renameLetBind : OrdMap String -> List String -> LetBind -> LetBind
renameLetBind rm bound (LetBind n clauses) =
  LetBind (renameDefName rm n) (map (renameFunClause rm bound) clauses)

renameFunClause : OrdMap String -> List String -> FunClause -> FunClause
renameFunClause rm bound (FunClause ps body) =
  FunClause
    (renamePatsPM rm ps)
    (renameScoped rm (patVarsListPM ps ++ bound) body)

renameArm : OrdMap String -> List String -> Arm -> Arm
renameArm rm bound (Arm p gs body) =
  let b0 = patVarsPM p ++ bound
  let (gs2, bnd) = renameGuards rm b0 gs
  Arm (renamePat rm p) gs2 (renameScoped rm bnd body)

renameGuardArm : OrdMap String -> List String -> GuardArm -> GuardArm
renameGuardArm rm bound (GuardArm gs body) =
  let (gs2, bnd) = renameGuards rm bound gs
  GuardArm gs2 (renameScoped rm bnd body)

renameGuards : OrdMap String -> List String -> List Guard -> (List Guard, List String)
renameGuards _ bound [] = ([], bound)
renameGuards rm bound ((GBool e)::rest) =
  let e2 = renameScoped rm bound e
  let (rest2, bnd) = renameGuards rm bound rest
  (GBool e2 :: rest2, bnd)
renameGuards rm bound ((GBind p e)::rest) =
  let e2 = renameScoped rm bound e
  let (rest2, bnd) = renameGuards rm (patVarsPM p ++ bound) rest
  (GBind (renamePat rm p) e2 :: rest2, bnd)

renameStmts : OrdMap String -> List String -> List DoStmt -> List DoStmt
renameStmts _ _ [] = []
renameStmts rm bound ((DoExpr e)::rest) =
  DoExpr (renameScoped rm bound e) :: renameStmts rm bound rest
renameStmts rm bound ((DoBind p e)::rest) =
  DoBind (renamePat rm p) (renameScoped rm bound e) ::
    renameStmts rm (patVarsPM p ++ bound) rest
renameStmts rm bound ((DoLet m r p e)::rest) =
  let b1 = if r then patVarsPM p ++ bound else bound
  DoLet m r (renamePat rm p) (renameScoped rm b1 e) :: renameStmts rm (patVarsPM p ++ bound) rest
renameStmts rm bound ((DoAssign x e)::rest) =
  DoAssign x (renameScoped rm bound e) :: renameStmts rm bound rest
renameStmts rm bound ((DoFieldAssign x fs e)::rest) =
  DoFieldAssign x fs (renameScoped rm bound e) :: renameStmts rm bound rest

letBindNamesPM : List LetBind -> List String
letBindNamesPM binds = map letBindName binds

-- ── pattern variables (local copy; covers PRec field/pun binders) ─────────────
patVarsPM : Pat -> List String
patVarsPM (PVar x) = [x]
patVarsPM (PCon _ args) = patVarsListPM args
patVarsPM (PCons h t) = patVarsPM h ++ patVarsPM t
patVarsPM (PTuple ps) = patVarsListPM ps
patVarsPM (PList ps) = patVarsListPM ps
patVarsPM (PAs x p) = x :: patVarsPM p
patVarsPM (PRec _ fields _) = flatMap recPatFieldVarsPM fields
patVarsPM _ = []

patVarsListPM : List Pat -> List String
patVarsListPM ps = flatMap patVarsPM ps

-- ── pattern CONSTRUCTOR rewrite ───────────────────────────────────────────────
-- Rewrite the constructor name of every PCon / PRec in a pattern to its mangled
-- form (reserved ctors are not in `rm`, so renameDefName leaves them).  Pattern
-- VARIABLE binders are untouched — they are lowercase value names, never in the
-- ctor/fn map.  Recurses through all sub-patterns so nested ctors are rewritten.
renamePat : OrdMap String -> Pat -> Pat
renamePat rm (PCon n args) = PCon (renameDefName rm n) (map (renamePat rm) args)
renamePat rm (PCons h t) = PCons (renamePat rm h) (renamePat rm t)
renamePat rm (PTuple ps) = PTuple (map (renamePat rm) ps)
renamePat rm (PList ps) = PList (map (renamePat rm) ps)
renamePat rm (PAs x p) = PAs x (renamePat rm p)
renamePat rm (PRec n fields open) =
  PRec (renameDefName rm n) (map (renameRecPatField rm) fields) open
renamePat _ p = p

renameRecPatField : OrdMap String -> RecPatField -> RecPatField
renameRecPatField _ (RecPatField label None) = RecPatField label None
renameRecPatField rm (RecPatField label (Some p)) =
  RecPatField label (Some (renamePat rm p))

renamePatsPM : OrdMap String -> List Pat -> List Pat
renamePatsPM rm ps = map (renamePat rm) ps

recPatFieldVarsPM : RecPatField -> List String
recPatFieldVarsPM (RecPatField label None) = [label]
recPatFieldVarsPM (RecPatField _ (Some p)) = patVarsPM p
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Pat" true) (mem "Arm" true) (mem "Guard" true) (mem "GuardArm" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "FieldAssign" true) (mem "RecPatField" true) (mem "LetBind" true) (mem "FunClause" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "ImplMethod" true) (mem "PropParam" true) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberOrigin" false) (mem "useMemberLocal" false) (mem "qualifiedLocal" false) (mem "Variant" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "filterList" false) (mem "initList" false) (mem "joinDot" false) (mem "dedup" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omLookup" false) (mem "omFromPairs" false) (mem "omEmpty" false) (mem "omSize" false))))
(DTypeSig true "mangleUnits" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "mangleUnits" ((PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "allUnits") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "exportsPerUnit") (EApp (EApp (EVar "buildExportsPerUnit") (EListLit)) (EVar "allUnits"))) (DoLet false false (PVar "ctorExportsPerUnit") (EApp (EApp (EVar "map") (EVar "unitCtorExportEntry")) (EVar "allUnits"))) (DoLet false false (PVar "coreOut") (EApp (EApp (EApp (EVar "mangleUnitU") (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit")) (ETuple (ELit (LString "core")) (EVar "coreDecls")))) (DoLet false false (PVar "modsOut") (EApp (EApp (EVar "map") (EApp (EApp (EVar "mangleModule") (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit"))) (EVar "modules"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut")))))
(DTypeSig false "buildExportsPerUnit" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "buildExportsPerUnit" (PWild (PList)) (EListLit))
(DFunDef false "buildExportsPerUnit" ((PVar "acc") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EBlock (DoLet false false (PVar "entry") (EApp (EApp (EVar "unitExportEntry") (EVar "acc")) (ETuple (EVar "mid") (EVar "decls")))) (DoExpr (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "buildExportsPerUnit") (EBinOp "::" (EVar "entry") (EVar "acc"))) (EVar "rest"))))))
(DTypeSig false "unitExportEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "unitExportEntry" ((PVar "acc") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "locals") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "mid")))) (EApp (EVar "dedup") (EApp (EVar "pubFnNames") (EVar "decls"))))) (DoLet false false (PVar "reexs") (EApp (EApp (EVar "flatMap") (EApp (EVar "reexportFnEntries") (EVar "acc"))) (EVar "decls"))) (DoExpr (ETuple (EVar "mid") (EApp (EVar "dedupPairsByName") (EBinOp "++" (EVar "locals") (EVar "reexs")))))))
(DTypeSig false "reexportFnEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportFnEntries" ((PVar "acc") (PCon "DUse" (PCon "True") (PVar "path") PWild)) (EBlock (DoLet false false (PVar "srcMid") (EApp (EVar "useModIdU") (EVar "path"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupExports") (EVar "srcMid")) (EVar "acc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "srcExports")) () (EApp (EApp (EVar "reexportMembers") (EVar "path")) (EVar "srcExports")))))))
(DFunDef false "reexportFnEntries" ((PVar "acc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "reexportFnEntries") (EVar "acc")) (EVar "d")))
(DFunDef false "reexportFnEntries" (PWild PWild) (EListLit))
(DTypeSig false "reexportMembers" (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportMembers" ((PCon "UseGroup" PWild (PVar "members")) (PVar "srcExports")) (EApp (EApp (EVar "flatMap") (EApp (EVar "reexportMember") (EVar "srcExports"))) (EVar "members")))
(DFunDef false "reexportMembers" ((PCon "UseWild" PWild) (PVar "srcExports")) (EVar "srcExports"))
(DFunDef false "reexportMembers" ((PCon "UseName" (PVar "ns")) (PVar "srcExports")) (EIf (EApp (EVar "lenGt1") (EVar "ns")) (EApp (EApp (EVar "reexportOne") (EVar "srcExports")) (EApp (EVar "lastOfPM") (EVar "ns"))) (EListLit)))
(DFunDef false "reexportMembers" ((PCon "UseAlias" PWild PWild) PWild) (EListLit))
(DTypeSig false "reexportMember" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportMember" ((PVar "srcExports") (PVar "m")) (EApp (EApp (EVar "reexportOne") (EVar "srcExports")) (EApp (EVar "useMemberOrigin") (EVar "m"))))
(DTypeSig false "reexportOne" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportOne" ((PVar "srcExports") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupDefiner") (EVar "n")) (EVar "srcExports")) (arm (PCon "Some" (PVar "definer")) () (EListLit (ETuple (EVar "n") (EVar "definer")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "dedupPairsByName" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "dedupPairsByName" ((PVar "pairs")) (EApp (EApp (EVar "dedupPairsGo") (EVar "pairs")) (EListLit)))
(DTypeSig false "dedupPairsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "dedupPairsGo" ((PList) PWild) (EListLit))
(DFunDef false "dedupPairsGo" ((PCons (PTuple (PVar "n") (PVar "d")) (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "seen")) (EApp (EApp (EVar "dedupPairsGo") (EVar "rest")) (EVar "seen")) (EBinOp "::" (ETuple (EVar "n") (EVar "d")) (EApp (EApp (EVar "dedupPairsGo") (EVar "rest")) (EBinOp "::" (EVar "n") (EVar "seen"))))))
(DTypeSig false "lookupDefiner" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lookupDefiner" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupDefiner" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "d")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "d")) (EApp (EApp (EVar "lookupDefiner") (EVar "k")) (EVar "rest"))))
(DTypeSig false "unitCtorExportEntry" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "unitCtorExportEntry" ((PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EVar "flatMap") (EVar "ctorExportEntries")) (EVar "decls"))))
(DTypeSig false "ctorExportEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorExportEntries" ((PCon "DData" PWild (PVar "tyname") PWild (PVar "variants") PWild)) (EListLit (ETuple (EVar "tyname") (EApp (EApp (EVar "filterList") (EVar "nonReservedCtor")) (EApp (EApp (EVar "map") (EVar "variantCtorName")) (EVar "variants"))))))
(DFunDef false "ctorExportEntries" ((PCon "DNewtype" PWild (PVar "tyname") PWild (PVar "con") PWild PWild)) (EIf (EApp (EVar "nonReservedCtor") (EVar "con")) (EListLit (ETuple (EVar "tyname") (EListLit (EVar "con")))) (EListLit)))
(DFunDef false "ctorExportEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ctorExportEntries") (EVar "d")))
(DFunDef false "ctorExportEntries" (PWild) (EListLit))
(DTypeSig false "variantCtorName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantCtorName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "nonReservedCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nonReservedCtor" ((PVar "n")) (EApp (EVar "not") (EApp (EVar "isReservedCtor") (EVar "n"))))
(DTypeSig false "isReservedCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isReservedCtor" ((PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "Cons"))) (EBinOp "==" (EVar "n") (ELit (LString "Nil")))) (EBinOp "==" (EVar "n") (ELit (LString "Some")))) (EBinOp "==" (EVar "n") (ELit (LString "None")))) (EBinOp "==" (EVar "n") (ELit (LString "Ok")))) (EBinOp "==" (EVar "n") (ELit (LString "Err")))) (EBinOp "==" (EVar "n") (ELit (LString "Lt")))) (EBinOp "==" (EVar "n") (ELit (LString "Eq")))) (EBinOp "==" (EVar "n") (ELit (LString "Gt")))) (EBinOp "==" (EVar "n") (ELit (LString "True")))) (EBinOp "==" (EVar "n") (ELit (LString "False")))))
(DTypeSig false "buildUnitCtorRenameMap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "buildUnitCtorRenameMap" ((PVar "mid") (PVar "ctorExportsPerUnit") (PVar "decls")) (EBlock (DoLet false false (PVar "localCtors") (EApp (EVar "dedup") (EApp (EVar "unitLocalCtorNames") (EVar "decls")))) (DoLet false false (PVar "localEntries") (EApp (EApp (EVar "flatMap") (EApp (EVar "localCtorRenameEntry") (EVar "mid"))) (EVar "localCtors"))) (DoLet false false (PVar "importEntries") (EApp (EApp (EApp (EVar "ctorImportEntries") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls"))) (DoExpr (EBinOp "++" (EVar "localEntries") (EVar "importEntries")))))
(DTypeSig false "unitLocalCtorNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitLocalCtorNames" ((PVar "decls")) (EApp (EApp (EVar "filterList") (EVar "nonReservedCtor")) (EApp (EApp (EVar "flatMap") (EVar "localCtorNames")) (EVar "decls"))))
(DTypeSig false "localCtorNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "localCtorNames" ((PCon "DData" PWild PWild PWild (PVar "variants") PWild)) (EApp (EApp (EVar "map") (EVar "variantCtorName")) (EVar "variants")))
(DFunDef false "localCtorNames" ((PCon "DNewtype" PWild PWild PWild (PVar "con") PWild PWild)) (EListLit (EVar "con")))
(DFunDef false "localCtorNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "localCtorNames") (EVar "d")))
(DFunDef false "localCtorNames" (PWild) (EListLit))
(DTypeSig false "localCtorRenameEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "localCtorRenameEntry" ((PVar "mid") (PVar "n")) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")))))
(DTypeSig false "ctorImportEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "ctorImportEntries" (PWild (PVar "ctorExportsPerUnit") (PVar "decls")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "declCtorImportEntries") (EVar "ctorExportsPerUnit"))) (EVar "decls")) (EApp (EVar "coreCtorImportEntries") (EVar "ctorExportsPerUnit"))))
(DTypeSig false "coreCtorImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreCtorImportEntries" ((PVar "ctorExportsPerUnit")) (EMatch (EApp (EApp (EVar "lookupCtorExports") (ELit (LString "core"))) (EVar "ctorExportsPerUnit")) (arm (PCon "Some" (PVar "entries")) () (EApp (EApp (EVar "flatMap") (EVar "coreCtorEntry")) (EVar "entries"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "coreCtorEntry" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreCtorEntry" ((PTuple PWild (PVar "ctors"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "n")) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (ELit (LString "core"))) (EVar "n")))))) (EVar "ctors")))
(DTypeSig false "declCtorImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "declCtorImportEntries" ((PVar "ctorExportsPerUnit") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EVar "useCtorPathEntries") (EVar "ctorExportsPerUnit")) (EVar "path")))
(DFunDef false "declCtorImportEntries" ((PVar "ctorExportsPerUnit") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declCtorImportEntries") (EVar "ctorExportsPerUnit")) (EVar "d")))
(DFunDef false "declCtorImportEntries" (PWild PWild) (EListLit))
(DTypeSig false "useCtorPathEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "useCtorPathEntries" ((PVar "ctorExportsPerUnit") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModIdU") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "lookupCtorExports") (EVar "mid")) (EVar "ctorExportsPerUnit")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "typeEntries")) () (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "ctorMemberEntry") (EVar "mid")) (EVar "typeEntries"))) (EVar "members"))) (arm (PCon "UseWild" PWild) () (EApp (EApp (EVar "flatMap") (EApp (EVar "typeCtorEntries") (EVar "mid"))) (EVar "typeEntries"))) (arm (PCon "UseName" PWild) () (EListLit)) (arm (PCon "UseAlias" PWild PWild) () (EListLit)))))))))
(DTypeSig false "ctorMemberEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "ctorMemberEntry" ((PVar "mid") (PVar "typeEntries") (PCon "UseMember" (PVar "name") (PVar "wild") PWild PWild)) (EIf (EVar "wild") (EMatch (EApp (EApp (EVar "lookupCtorTypeEntry") (EVar "name")) (EVar "typeEntries")) (arm (PCon "Some" (PVar "ctors")) () (EApp (EApp (EVar "flatMap") (EApp (EVar "originCtorEntry") (EVar "mid"))) (EVar "ctors"))) (arm (PCon "None") () (EListLit))) (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "typeEntries"))) (EApp (EApp (EVar "originCtorEntry") (EVar "mid")) (EVar "name")) (EListLit))))
(DTypeSig false "typeCtorEntries" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "typeCtorEntries" ((PVar "mid") (PTuple PWild (PVar "ctors"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "originCtorEntry") (EVar "mid"))) (EVar "ctors")))
(DTypeSig false "originCtorEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "originCtorEntry" ((PVar "mid") (PVar "n")) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")))))
(DTypeSig false "lookupCtorTypeEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "lookupCtorTypeEntry" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupCtorTypeEntry" ((PVar "k") (PCons (PTuple (PVar "t") (PVar "cs")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "t")) (EApp (EVar "Some") (EVar "cs")) (EApp (EApp (EVar "lookupCtorTypeEntry") (EVar "k")) (EVar "rest"))))
(DTypeSig false "lookupCtorExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "lookupCtorExports" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupCtorExports" ((PVar "k") (PCons (PTuple (PVar "m") (PVar "es")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "m")) (EApp (EVar "Some") (EVar "es")) (EApp (EApp (EVar "lookupCtorExports") (EVar "k")) (EVar "rest"))))
(DTypeSig false "mangleModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "mangleModule" ((PVar "exportsPerUnit") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EApp (EVar "mangleUnitU") (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit")) (ETuple (EVar "mid") (EVar "decls")))))
(DTypeSig false "mangleUnitU" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "mangleUnitU" ((PVar "exportsPerUnit") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "rmFn") (EApp (EApp (EApp (EVar "buildUnitRenameMap") (EVar "mid")) (EVar "exportsPerUnit")) (EVar "decls"))) (DoLet false false (PVar "rmCtor") (EApp (EApp (EApp (EVar "buildUnitCtorRenameMap") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls"))) (DoLet false false (PVar "rmList") (EBinOp "++" (EVar "rmFn") (EVar "rmCtor"))) (DoLet false false (PVar "rm") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "rmList"))) (EVar "omEmpty"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "rmList")) (EVar "decls") (EApp (EApp (EVar "map") (EApp (EVar "renameDecl") (EVar "rm"))) (EVar "decls"))))))
(DTypeSig false "buildUnitRenameMap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "buildUnitRenameMap" ((PVar "mid") (PVar "exportsPerUnit") (PVar "decls")) (EBlock (DoLet false false (PVar "localFns") (EApp (EVar "dedup") (EApp (EVar "unitDefNames") (ETuple (EVar "mid") (EVar "decls"))))) (DoLet false false (PVar "localEntries") (EApp (EApp (EVar "flatMap") (EApp (EVar "localRenameEntry") (EVar "mid"))) (EVar "localFns"))) (DoLet false false (PVar "importEntries") (EApp (EApp (EApp (EVar "importRenameEntries") (EVar "mid")) (EVar "exportsPerUnit")) (EVar "decls"))) (DoExpr (EBinOp "++" (EVar "localEntries") (EVar "importEntries")))))
(DTypeSig false "localRenameEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "localRenameEntry" ((PVar "mid") (PVar "n")) (EIf (EApp (EVar "isExcludedName") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isExcludedName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isExcludedName" ((PVar "n")) (EBinOp "==" (EVar "n") (ELit (LString "main"))))
(DTypeSig false "importRenameEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "importRenameEntries" (PWild (PVar "exportsPerUnit") (PVar "decls")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "declImportEntries") (EVar "exportsPerUnit"))) (EVar "decls")) (EApp (EVar "coreImportEntries") (EVar "exportsPerUnit"))))
(DTypeSig false "coreImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreImportEntries" ((PVar "exportsPerUnit")) (EMatch (EApp (EApp (EVar "lookupExports") (ELit (LString "core"))) (EVar "exportsPerUnit")) (arm (PCon "Some" (PVar "names")) () (EApp (EApp (EVar "flatMap") (EVar "coreEntry")) (EVar "names"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "coreEntry" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreEntry" ((PTuple (PVar "n") (PVar "definer"))) (EIf (EApp (EVar "isExcludedName") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "declImportEntries" ((PVar "exportsPerUnit") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EVar "usePathEntries") (EVar "exportsPerUnit")) (EVar "path")))
(DFunDef false "declImportEntries" ((PVar "exportsPerUnit") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declImportEntries") (EVar "exportsPerUnit")) (EVar "d")))
(DFunDef false "declImportEntries" (PWild PWild) (EListLit))
(DTypeSig false "usePathEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "usePathEntries" ((PVar "exportsPerUnit") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModIdU") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "lookupExports") (EVar "mid")) (EVar "exportsPerUnit")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exports")) () (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EVar "flatMap") (EApp (EVar "memberEntry") (EVar "exports"))) (EVar "members"))) (arm (PCon "UseWild" PWild) () (EApp (EApp (EVar "flatMap") (EVar "originEntryPair")) (EVar "exports"))) (arm (PCon "UseName" (PVar "ns")) () (EApp (EApp (EVar "originEntry") (EVar "exports")) (EApp (EVar "lastOfPM") (EVar "ns")))) (arm (PCon "UseAlias" PWild (PVar "a")) () (EApp (EApp (EVar "flatMap") (EApp (EVar "aliasEntryPair") (EVar "a"))) (EVar "exports"))))))))))
(DTypeSig false "memberEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "memberEntry" ((PVar "exports") (PVar "m")) (EApp (EApp (EApp (EVar "originEntryAs") (EVar "exports")) (EApp (EVar "useMemberOrigin") (EVar "m"))) (EApp (EVar "useMemberLocal") (EVar "m"))))
(DTypeSig false "originEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "originEntry" ((PVar "exports") (PVar "n")) (EApp (EApp (EApp (EVar "originEntryAs") (EVar "exports")) (EVar "n")) (EVar "n")))
(DTypeSig false "originEntryAs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "originEntryAs" ((PVar "exports") (PVar "origin") (PVar "local")) (EIf (EApp (EVar "isExcludedName") (EVar "origin")) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "lookupDefiner") (EVar "origin")) (EVar "exports")) (arm (PCon "Some" (PVar "definer")) () (EListLit (ETuple (EVar "local") (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "origin"))))) (arm (PCon "None") () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "originEntryPair" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "originEntryPair" ((PTuple (PVar "n") (PVar "definer"))) (EIf (EApp (EVar "isExcludedName") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "aliasEntryPair" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "aliasEntryPair" ((PVar "a") (PTuple (PVar "n") (PVar "definer"))) (EIf (EApp (EVar "isExcludedName") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "n")) (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "useModIdU" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useModIdU" ((PCon "UseName" (PVar "ns"))) (EIf (EApp (EVar "lenGt1") (EVar "ns")) (EApp (EVar "joinDot") (EApp (EVar "initList") (EVar "ns"))) (EApp (EApp (EVar "firstOrU") (ELit (LString ""))) (EVar "ns"))))
(DFunDef false "useModIdU" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModIdU" ((PCon "UseWild" (PVar "ns"))) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModIdU" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DTypeSig false "lenGt1" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "lenGt1" ((PCons PWild (PCons PWild PWild))) (EVar "True"))
(DFunDef false "lenGt1" (PWild) (EVar "False"))
(DTypeSig false "firstOrU" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "firstOrU" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "firstOrU" (PWild (PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "lastOfPM" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastOfPM" ((PList)) (ELit (LString "")))
(DFunDef false "lastOfPM" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOfPM" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastOfPM") (EVar "rest")))
(DTypeSig false "lookupExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "lookupExports" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupExports" ((PVar "k") (PCons (PTuple (PVar "m") (PVar "ns")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "m")) (EApp (EVar "Some") (EVar "ns")) (EApp (EApp (EVar "lookupExports") (EVar "k")) (EVar "rest"))))
(DTypeSig false "pubFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pubFnNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "defined") (EApp (EVar "unitDefNames") (ETuple (ELit (LString "")) (EVar "decls")))) (DoLet false false (PVar "pubSigs") (EApp (EVar "pubSigNames") (EVar "decls"))) (DoLet false false (PVar "pubDefs") (EApp (EVar "pubDefNames") (EVar "decls"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "defined")))) (EBinOp "++" (EVar "pubSigs") (EVar "pubDefs"))))))
(DTypeSig false "pubDefNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pubDefNames" ((PList)) (EListLit))
(DFunDef false "pubDefNames" ((PCons (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "pubDefNames") (EVar "rest"))))
(DFunDef false "pubDefNames" ((PCons (PCon "DLetGroup" (PCon "True") (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")) (EApp (EVar "pubDefNames") (EVar "rest"))))
(DFunDef false "pubDefNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "pubDefNames") (EListLit (EVar "d"))) (EApp (EVar "pubDefNames") (EVar "rest"))))
(DFunDef false "pubDefNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubDefNames") (EVar "rest")))
(DTypeSig false "unitDefNames" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitDefNames" ((PTuple PWild (PVar "decls"))) (EApp (EApp (EVar "flatMap") (EVar "declDefNames")) (EVar "decls")))
(DTypeSig false "declDefNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declDefNames" ((PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "declDefNames" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")))
(DFunDef false "declDefNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declDefNames") (EVar "d")))
(DFunDef false "declDefNames" (PWild) (EListLit))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "pubSigNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pubSigNames" ((PList)) (EListLit))
(DFunDef false "pubSigNames" ((PCons (PCon "DTypeSig" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "pubSigNames") (EVar "rest"))))
(DFunDef false "pubSigNames" ((PCons (PCon "DExtern" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "pubSigNames") (EVar "rest"))))
(DFunDef false "pubSigNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "pubSigNames") (EListLit (EVar "d"))) (EApp (EVar "pubSigNames") (EVar "rest"))))
(DFunDef false "pubSigNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubSigNames") (EVar "rest")))
(DTypeSig true "mangledName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "mangledName" ((PVar "mid") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "sanitizeId") (EVar "mid")))) (ELit (LString "__"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DTypeSig false "sanitizeId" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sanitizeId" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "s")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))) (ELit (LString ""))))
(DTypeSig false "sanitizeGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "sanitizeGo" ((PVar "s") (PVar "i") (PVar "len") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "acc") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s"))) (DoLet false false (PVar "c2") (EIf (EApp (EVar "safeChar") (EVar "c")) (EVar "c") (ELit (LString "_")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EBinOp "++" (EVar "acc") (EVar "c2")))))))
(DTypeSig true "safeChar" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "safeChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "a"))) (EBinOp "<=" (EVar "c") (ELit (LString "z")))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "A"))) (EBinOp "<=" (EVar "c") (ELit (LString "Z"))))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "0"))) (EBinOp "<=" (EVar "c") (ELit (LString "9"))))) (EBinOp "==" (EVar "c") (ELit (LString "_")))))
(DTypeSig true "hashName" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "hashName" ((PVar "s")) (EApp (EApp (EApp (EVar "hashChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))) (ELit (LInt 5381))))
(DTypeSig false "hashChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "hashChars" ((PVar "cs") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "hashChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 33))) (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "renameDecl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "patVarsListPM") (EVar "ps"))) (EVar "e"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DTypeSig" (PVar "pub") (PVar "n") (PVar "ty"))) (EApp (EApp (EApp (EVar "DTypeSig") (EVar "pub")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EVar "ty")))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EVar "renameIfaceMethod") (EVar "rm"))) (EVar "methods"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EVar "renameImplMethod") (EVar "rm"))) (EVar "methods"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "propParamNamesPM") (EVar "params"))) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EListLit)) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DBench" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DBench") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EListLit)) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EVar "map") (EApp (EVar "renameLetBindDef") (EVar "rm"))) (EVar "binds"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DData" (PVar "vis") (PVar "tyname") (PVar "tps") (PVar "variants") (PVar "derives"))) (EApp (EApp (EApp (EApp (EApp (EVar "DData") (EVar "vis")) (EVar "tyname")) (EVar "tps")) (EApp (EApp (EVar "map") (EApp (EVar "renameVariant") (EVar "rm"))) (EVar "variants"))) (EVar "derives")))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DNewtype" (PVar "pub") (PVar "tyname") (PVar "tps") (PVar "con") (PVar "fty") (PVar "derives"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DNewtype") (EVar "pub")) (EVar "tyname")) (EVar "tps")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "con"))) (EVar "fty")) (EVar "derives")))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "renameDecl") (EVar "rm")) (EVar "d"))))
(DFunDef false "renameDecl" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "renameVariant" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Variant") (TyCon "Variant"))))
(DFunDef false "renameVariant" ((PVar "rm") (PCon "Variant" (PVar "n") (PVar "payload"))) (EApp (EApp (EVar "Variant") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EVar "payload")))
(DTypeSig false "renameLetBindDef" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "renameLetBindDef" ((PVar "rm") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameFunClause") (EVar "rm")) (EListLit))) (EVar "clauses"))))
(DTypeSig false "renameDefName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "renameDefName" ((PVar "rm") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "rm")) (arm (PCon "Some" (PVar "n2")) () (EVar "n2")) (arm (PCon "None") () (EVar "n"))))
(DTypeSig false "renameIfaceMethod" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))
(DFunDef false "renameIfaceMethod" (PWild (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None"))) (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EVar "None")))
(DFunDef false "renameIfaceMethod" ((PVar "rm") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "e"))))) (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "patVarsListPM") (EVar "ps"))) (EVar "e"))))))
(DTypeSig false "renameImplMethod" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))
(DFunDef false "renameImplMethod" ((PVar "rm") (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "patVarsListPM") (EVar "ps"))) (EVar "e"))))
(DTypeSig false "propParamNamesPM" (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "propParamNamesPM" ((PVar "ps")) (EApp (EApp (EVar "map") (EVar "propParamNamePM")) (EVar "ps")))
(DTypeSig false "propParamNamePM" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "propParamNamePM" ((PCon "PropParam" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "renameScoped" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EVar" (PVar "n"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "bound"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "rm")) (arm (PCon "Some" (PVar "n2")) () (EApp (EVar "EVar") (EVar "n2"))) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))) (EIf (EVar "otherwise") (EApp (EVar "EVar") (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "ELam") (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EBinOp "++" (EApp (EVar "patVarsListPM") (EVar "ps")) (EVar "bound"))) (EVar "body"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELet" (PVar "m") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "pv") (EApp (EVar "patVarsPM") (EVar "p"))) (DoLet false false (PVar "b1") (EIf (EVar "r") (EBinOp "++" (EVar "pv") (EVar "bound")) (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "b1")) (EVar "e1"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EBinOp "++" (EVar "pv") (EVar "bound"))) (EVar "e2"))))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELetGroup" (PVar "binds") (PVar "e2"))) (EBlock (DoLet false false (PVar "bnd") (EBinOp "++" (EApp (EVar "letBindNamesPM") (EVar "binds")) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameLetBind") (EVar "rm")) (EVar "bnd"))) (EVar "binds"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bnd")) (EVar "e2"))))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameArm") (EVar "rm")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "f"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "x"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "c"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "t"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "dr"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "l"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "r"))) (EVar "dr")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EUnOp" (PVar "op") (PVar "x") (PVar "dr"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "x"))) (EVar "dr")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "l"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "r"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "n")) (EVar "r")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")) (EVar "r")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EIndex" (PVar "e0") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "i"))) (EVar "r")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs"))) (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EVariantUpdate" (PVar "c") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "c"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameInterp") (EVar "rm")) (EVar "bound"))) (EVar "parts"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameGuardArm") (EVar "rm")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e0")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0")))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESection" (PCon "SecLeft" (PVar "e0") (PVar "op")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "op"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameKv") (EVar "rm")) (EVar "bound"))) (EVar "kvs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EAsPat" (PVar "x") (PVar "sub"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "sub"))))
(DFunDef false "renameScoped" (PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "renameField" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))))
(DFunDef false "renameField" ((PVar "rm") (PVar "bound") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "renameKv" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "renameKv" ((PVar "rm") (PVar "bound") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "k")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "v"))))
(DTypeSig false "renameInterp" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))))
(DFunDef false "renameInterp" (PWild PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "renameInterp" ((PVar "rm") (PVar "bound") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "renameLetBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "LetBind") (TyCon "LetBind")))))
(DFunDef false "renameLetBind" ((PVar "rm") (PVar "bound") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameFunClause") (EVar "rm")) (EVar "bound"))) (EVar "clauses"))))
(DTypeSig false "renameFunClause" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FunClause") (TyCon "FunClause")))))
(DFunDef false "renameFunClause" ((PVar "rm") (PVar "bound") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EBinOp "++" (EApp (EVar "patVarsListPM") (EVar "ps")) (EVar "bound"))) (EVar "body"))))
(DTypeSig false "renameArm" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Arm") (TyCon "Arm")))))
(DFunDef false "renameArm" ((PVar "rm") (PVar "bound") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "b0") (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "p")) (EVar "bound"))) (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EVar "b0")) (EVar "gs"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EVar "gs2")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "renameGuardArm" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))))
(DFunDef false "renameGuardArm" ((PVar "rm") (PVar "bound") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EVar "bound")) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "gs2")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "renameGuards" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "renameGuards" (PWild (PVar "bound") (PList)) (ETuple (EListLit) (EVar "bound")))
(DFunDef false "renameGuards" ((PVar "rm") (PVar "bound") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EVar "bound")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DFunDef false "renameGuards" ((PVar "rm") (PVar "bound") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "p")) (EVar "bound"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DTypeSig false "renameStmts" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "renameStmts" (PWild PWild (PList)) (EListLit))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "DoExpr") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoBind") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "p")) (EVar "bound"))) (EVar "rest"))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "b1") (EIf (EVar "r") (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "p")) (EVar "bound")) (EVar "bound"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "b1")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "p")) (EVar "bound"))) (EVar "rest"))))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DTypeSig false "letBindNamesPM" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindNamesPM" ((PVar "binds")) (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")))
(DTypeSig false "patVarsPM" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsPM" ((PCon "PVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "patVarsPM" ((PCon "PCon" PWild (PVar "args"))) (EApp (EVar "patVarsListPM") (EVar "args")))
(DFunDef false "patVarsPM" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "h")) (EApp (EVar "patVarsPM") (EVar "t"))))
(DFunDef false "patVarsPM" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "patVarsListPM") (EVar "ps")))
(DFunDef false "patVarsPM" ((PCon "PList" (PVar "ps"))) (EApp (EVar "patVarsListPM") (EVar "ps")))
(DFunDef false "patVarsPM" ((PCon "PAs" (PVar "x") (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patVarsPM") (EVar "p"))))
(DFunDef false "patVarsPM" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "flatMap") (EVar "recPatFieldVarsPM")) (EVar "fields")))
(DFunDef false "patVarsPM" (PWild) (EListLit))
(DTypeSig false "patVarsListPM" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsListPM" ((PVar "ps")) (EApp (EApp (EVar "flatMap") (EVar "patVarsPM")) (EVar "ps")))
(DTypeSig false "renamePat" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PCon" (PVar "n") (PVar "args"))) (EApp (EApp (EVar "PCon") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "args"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCons") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "h"))) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "t"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EVar "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EVar "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PAs" (PVar "x") (PVar "p"))) (EApp (EApp (EVar "PAs") (EVar "x")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PRec" (PVar "n") (PVar "fields") (PVar "open"))) (EApp (EApp (EApp (EVar "PRec") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "map") (EApp (EVar "renameRecPatField") (EVar "rm"))) (EVar "fields"))) (EVar "open")))
(DFunDef false "renamePat" (PWild (PVar "p")) (EVar "p"))
(DTypeSig false "renameRecPatField" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "RecPatField") (TyCon "RecPatField"))))
(DFunDef false "renameRecPatField" (PWild (PCon "RecPatField" (PVar "label") (PCon "None"))) (EApp (EApp (EVar "RecPatField") (EVar "label")) (EVar "None")))
(DFunDef false "renameRecPatField" ((PVar "rm") (PCon "RecPatField" (PVar "label") (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "RecPatField") (EVar "label")) (EApp (EVar "Some") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p")))))
(DTypeSig false "renamePatsPM" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "renamePatsPM" ((PVar "rm") (PVar "ps")) (EApp (EApp (EVar "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps")))
(DTypeSig false "recPatFieldVarsPM" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recPatFieldVarsPM" ((PCon "RecPatField" (PVar "label") (PCon "None"))) (EListLit (EVar "label")))
(DFunDef false "recPatFieldVarsPM" ((PCon "RecPatField" PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patVarsPM") (EVar "p")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Pat" true) (mem "Arm" true) (mem "Guard" true) (mem "GuardArm" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "FieldAssign" true) (mem "RecPatField" true) (mem "LetBind" true) (mem "FunClause" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "ImplMethod" true) (mem "PropParam" true) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberOrigin" false) (mem "useMemberLocal" false) (mem "qualifiedLocal" false) (mem "Variant" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "filterList" false) (mem "initList" false) (mem "joinDot" false) (mem "dedup" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omLookup" false) (mem "omFromPairs" false) (mem "omEmpty" false) (mem "omSize" false))))
(DTypeSig true "mangleUnits" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "mangleUnits" ((PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "allUnits") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "exportsPerUnit") (EApp (EApp (EVar "buildExportsPerUnit") (EListLit)) (EVar "allUnits"))) (DoLet false false (PVar "ctorExportsPerUnit") (EApp (EApp (EMethodRef "map") (EVar "unitCtorExportEntry")) (EVar "allUnits"))) (DoLet false false (PVar "coreOut") (EApp (EApp (EApp (EVar "mangleUnitU") (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit")) (ETuple (ELit (LString "core")) (EVar "coreDecls")))) (DoLet false false (PVar "modsOut") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "mangleModule") (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit"))) (EVar "modules"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut")))))
(DTypeSig false "buildExportsPerUnit" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "buildExportsPerUnit" (PWild (PList)) (EListLit))
(DFunDef false "buildExportsPerUnit" ((PVar "acc") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EBlock (DoLet false false (PVar "entry") (EApp (EApp (EVar "unitExportEntry") (EVar "acc")) (ETuple (EVar "mid") (EVar "decls")))) (DoExpr (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "buildExportsPerUnit") (EBinOp "::" (EVar "entry") (EVar "acc"))) (EVar "rest"))))))
(DTypeSig false "unitExportEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "unitExportEntry" ((PVar "acc") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "locals") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "mid")))) (EApp (EVar "dedup") (EApp (EVar "pubFnNames") (EVar "decls"))))) (DoLet false false (PVar "reexs") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "reexportFnEntries") (EVar "acc"))) (EVar "decls"))) (DoExpr (ETuple (EVar "mid") (EApp (EVar "dedupPairsByName") (EBinOp "++" (EVar "locals") (EVar "reexs")))))))
(DTypeSig false "reexportFnEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportFnEntries" ((PVar "acc") (PCon "DUse" (PCon "True") (PVar "path") PWild)) (EBlock (DoLet false false (PVar "srcMid") (EApp (EVar "useModIdU") (EVar "path"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupExports") (EVar "srcMid")) (EVar "acc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "srcExports")) () (EApp (EApp (EVar "reexportMembers") (EVar "path")) (EVar "srcExports")))))))
(DFunDef false "reexportFnEntries" ((PVar "acc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "reexportFnEntries") (EVar "acc")) (EVar "d")))
(DFunDef false "reexportFnEntries" (PWild PWild) (EListLit))
(DTypeSig false "reexportMembers" (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportMembers" ((PCon "UseGroup" PWild (PVar "members")) (PVar "srcExports")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "reexportMember") (EVar "srcExports"))) (EVar "members")))
(DFunDef false "reexportMembers" ((PCon "UseWild" PWild) (PVar "srcExports")) (EVar "srcExports"))
(DFunDef false "reexportMembers" ((PCon "UseName" (PVar "ns")) (PVar "srcExports")) (EIf (EApp (EVar "lenGt1") (EVar "ns")) (EApp (EApp (EVar "reexportOne") (EVar "srcExports")) (EApp (EVar "lastOfPM") (EVar "ns"))) (EListLit)))
(DFunDef false "reexportMembers" ((PCon "UseAlias" PWild PWild) PWild) (EListLit))
(DTypeSig false "reexportMember" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportMember" ((PVar "srcExports") (PVar "m")) (EApp (EApp (EVar "reexportOne") (EVar "srcExports")) (EApp (EVar "useMemberOrigin") (EVar "m"))))
(DTypeSig false "reexportOne" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportOne" ((PVar "srcExports") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupDefiner") (EVar "n")) (EVar "srcExports")) (arm (PCon "Some" (PVar "definer")) () (EListLit (ETuple (EVar "n") (EVar "definer")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "dedupPairsByName" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "dedupPairsByName" ((PVar "pairs")) (EApp (EApp (EVar "dedupPairsGo") (EVar "pairs")) (EListLit)))
(DTypeSig false "dedupPairsGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "dedupPairsGo" ((PList) PWild) (EListLit))
(DFunDef false "dedupPairsGo" ((PCons (PTuple (PVar "n") (PVar "d")) (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "seen")) (EApp (EApp (EVar "dedupPairsGo") (EVar "rest")) (EVar "seen")) (EBinOp "::" (ETuple (EVar "n") (EVar "d")) (EApp (EApp (EVar "dedupPairsGo") (EVar "rest")) (EBinOp "::" (EVar "n") (EVar "seen"))))))
(DTypeSig false "lookupDefiner" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lookupDefiner" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupDefiner" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "d")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "d")) (EApp (EApp (EVar "lookupDefiner") (EVar "k")) (EVar "rest"))))
(DTypeSig false "unitCtorExportEntry" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "unitCtorExportEntry" ((PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EDictApp "flatMap") (EVar "ctorExportEntries")) (EVar "decls"))))
(DTypeSig false "ctorExportEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorExportEntries" ((PCon "DData" PWild (PVar "tyname") PWild (PVar "variants") PWild)) (EListLit (ETuple (EVar "tyname") (EApp (EApp (EVar "filterList") (EVar "nonReservedCtor")) (EApp (EApp (EMethodRef "map") (EVar "variantCtorName")) (EVar "variants"))))))
(DFunDef false "ctorExportEntries" ((PCon "DNewtype" PWild (PVar "tyname") PWild (PVar "con") PWild PWild)) (EIf (EApp (EVar "nonReservedCtor") (EVar "con")) (EListLit (ETuple (EVar "tyname") (EListLit (EVar "con")))) (EListLit)))
(DFunDef false "ctorExportEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ctorExportEntries") (EVar "d")))
(DFunDef false "ctorExportEntries" (PWild) (EListLit))
(DTypeSig false "variantCtorName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantCtorName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "nonReservedCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nonReservedCtor" ((PVar "n")) (EApp (EVar "not") (EApp (EVar "isReservedCtor") (EVar "n"))))
(DTypeSig false "isReservedCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isReservedCtor" ((PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "Cons"))) (EBinOp "==" (EVar "n") (ELit (LString "Nil")))) (EBinOp "==" (EVar "n") (ELit (LString "Some")))) (EBinOp "==" (EVar "n") (ELit (LString "None")))) (EBinOp "==" (EVar "n") (ELit (LString "Ok")))) (EBinOp "==" (EVar "n") (ELit (LString "Err")))) (EBinOp "==" (EVar "n") (ELit (LString "Lt")))) (EBinOp "==" (EVar "n") (ELit (LString "Eq")))) (EBinOp "==" (EVar "n") (ELit (LString "Gt")))) (EBinOp "==" (EVar "n") (ELit (LString "True")))) (EBinOp "==" (EVar "n") (ELit (LString "False")))))
(DTypeSig false "buildUnitCtorRenameMap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "buildUnitCtorRenameMap" ((PVar "mid") (PVar "ctorExportsPerUnit") (PVar "decls")) (EBlock (DoLet false false (PVar "localCtors") (EApp (EVar "dedup") (EApp (EVar "unitLocalCtorNames") (EVar "decls")))) (DoLet false false (PVar "localEntries") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "localCtorRenameEntry") (EVar "mid"))) (EVar "localCtors"))) (DoLet false false (PVar "importEntries") (EApp (EApp (EApp (EVar "ctorImportEntries") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls"))) (DoExpr (EBinOp "++" (EVar "localEntries") (EVar "importEntries")))))
(DTypeSig false "unitLocalCtorNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitLocalCtorNames" ((PVar "decls")) (EApp (EApp (EVar "filterList") (EVar "nonReservedCtor")) (EApp (EApp (EDictApp "flatMap") (EVar "localCtorNames")) (EVar "decls"))))
(DTypeSig false "localCtorNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "localCtorNames" ((PCon "DData" PWild PWild PWild (PVar "variants") PWild)) (EApp (EApp (EMethodRef "map") (EVar "variantCtorName")) (EVar "variants")))
(DFunDef false "localCtorNames" ((PCon "DNewtype" PWild PWild PWild (PVar "con") PWild PWild)) (EListLit (EVar "con")))
(DFunDef false "localCtorNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "localCtorNames") (EVar "d")))
(DFunDef false "localCtorNames" (PWild) (EListLit))
(DTypeSig false "localCtorRenameEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "localCtorRenameEntry" ((PVar "mid") (PVar "n")) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")))))
(DTypeSig false "ctorImportEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "ctorImportEntries" (PWild (PVar "ctorExportsPerUnit") (PVar "decls")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "declCtorImportEntries") (EVar "ctorExportsPerUnit"))) (EVar "decls")) (EApp (EVar "coreCtorImportEntries") (EVar "ctorExportsPerUnit"))))
(DTypeSig false "coreCtorImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreCtorImportEntries" ((PVar "ctorExportsPerUnit")) (EMatch (EApp (EApp (EVar "lookupCtorExports") (ELit (LString "core"))) (EVar "ctorExportsPerUnit")) (arm (PCon "Some" (PVar "entries")) () (EApp (EApp (EDictApp "flatMap") (EVar "coreCtorEntry")) (EVar "entries"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "coreCtorEntry" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreCtorEntry" ((PTuple PWild (PVar "ctors"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "n")) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (ELit (LString "core"))) (EVar "n")))))) (EVar "ctors")))
(DTypeSig false "declCtorImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "declCtorImportEntries" ((PVar "ctorExportsPerUnit") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EVar "useCtorPathEntries") (EVar "ctorExportsPerUnit")) (EVar "path")))
(DFunDef false "declCtorImportEntries" ((PVar "ctorExportsPerUnit") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declCtorImportEntries") (EVar "ctorExportsPerUnit")) (EVar "d")))
(DFunDef false "declCtorImportEntries" (PWild PWild) (EListLit))
(DTypeSig false "useCtorPathEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "useCtorPathEntries" ((PVar "ctorExportsPerUnit") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModIdU") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "lookupCtorExports") (EVar "mid")) (EVar "ctorExportsPerUnit")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "typeEntries")) () (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "ctorMemberEntry") (EVar "mid")) (EVar "typeEntries"))) (EVar "members"))) (arm (PCon "UseWild" PWild) () (EApp (EApp (EDictApp "flatMap") (EApp (EVar "typeCtorEntries") (EVar "mid"))) (EVar "typeEntries"))) (arm (PCon "UseName" PWild) () (EListLit)) (arm (PCon "UseAlias" PWild PWild) () (EListLit)))))))))
(DTypeSig false "ctorMemberEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "ctorMemberEntry" ((PVar "mid") (PVar "typeEntries") (PCon "UseMember" (PVar "name") (PVar "wild") PWild PWild)) (EIf (EVar "wild") (EMatch (EApp (EApp (EVar "lookupCtorTypeEntry") (EVar "name")) (EVar "typeEntries")) (arm (PCon "Some" (PVar "ctors")) () (EApp (EApp (EDictApp "flatMap") (EApp (EVar "originCtorEntry") (EVar "mid"))) (EVar "ctors"))) (arm (PCon "None") () (EListLit))) (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "typeEntries"))) (EApp (EApp (EVar "originCtorEntry") (EVar "mid")) (EVar "name")) (EListLit))))
(DTypeSig false "typeCtorEntries" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "typeCtorEntries" ((PVar "mid") (PTuple PWild (PVar "ctors"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "originCtorEntry") (EVar "mid"))) (EVar "ctors")))
(DTypeSig false "originCtorEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "originCtorEntry" ((PVar "mid") (PVar "n")) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")))))
(DTypeSig false "lookupCtorTypeEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "lookupCtorTypeEntry" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupCtorTypeEntry" ((PVar "k") (PCons (PTuple (PVar "t") (PVar "cs")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "t")) (EApp (EVar "Some") (EVar "cs")) (EApp (EApp (EVar "lookupCtorTypeEntry") (EVar "k")) (EVar "rest"))))
(DTypeSig false "lookupCtorExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "lookupCtorExports" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupCtorExports" ((PVar "k") (PCons (PTuple (PVar "m") (PVar "es")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "m")) (EApp (EVar "Some") (EVar "es")) (EApp (EApp (EVar "lookupCtorExports") (EVar "k")) (EVar "rest"))))
(DTypeSig false "mangleModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "mangleModule" ((PVar "exportsPerUnit") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EApp (EVar "mangleUnitU") (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit")) (ETuple (EVar "mid") (EVar "decls")))))
(DTypeSig false "mangleUnitU" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "mangleUnitU" ((PVar "exportsPerUnit") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "rmFn") (EApp (EApp (EApp (EVar "buildUnitRenameMap") (EVar "mid")) (EVar "exportsPerUnit")) (EVar "decls"))) (DoLet false false (PVar "rmCtor") (EApp (EApp (EApp (EVar "buildUnitCtorRenameMap") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls"))) (DoLet false false (PVar "rmList") (EBinOp "++" (EVar "rmFn") (EVar "rmCtor"))) (DoLet false false (PVar "rm") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "rmList"))) (EVar "omEmpty"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "rmList")) (EVar "decls") (EApp (EApp (EMethodRef "map") (EApp (EVar "renameDecl") (EVar "rm"))) (EVar "decls"))))))
(DTypeSig false "buildUnitRenameMap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "buildUnitRenameMap" ((PVar "mid") (PVar "exportsPerUnit") (PVar "decls")) (EBlock (DoLet false false (PVar "localFns") (EApp (EVar "dedup") (EApp (EVar "unitDefNames") (ETuple (EVar "mid") (EVar "decls"))))) (DoLet false false (PVar "localEntries") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "localRenameEntry") (EVar "mid"))) (EVar "localFns"))) (DoLet false false (PVar "importEntries") (EApp (EApp (EApp (EVar "importRenameEntries") (EVar "mid")) (EVar "exportsPerUnit")) (EVar "decls"))) (DoExpr (EBinOp "++" (EVar "localEntries") (EVar "importEntries")))))
(DTypeSig false "localRenameEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "localRenameEntry" ((PVar "mid") (PVar "n")) (EIf (EApp (EVar "isExcludedName") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isExcludedName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isExcludedName" ((PVar "n")) (EBinOp "==" (EVar "n") (ELit (LString "main"))))
(DTypeSig false "importRenameEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "importRenameEntries" (PWild (PVar "exportsPerUnit") (PVar "decls")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "declImportEntries") (EVar "exportsPerUnit"))) (EVar "decls")) (EApp (EVar "coreImportEntries") (EVar "exportsPerUnit"))))
(DTypeSig false "coreImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreImportEntries" ((PVar "exportsPerUnit")) (EMatch (EApp (EApp (EVar "lookupExports") (ELit (LString "core"))) (EVar "exportsPerUnit")) (arm (PCon "Some" (PVar "names")) () (EApp (EApp (EDictApp "flatMap") (EVar "coreEntry")) (EVar "names"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "coreEntry" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreEntry" ((PTuple (PVar "n") (PVar "definer"))) (EIf (EApp (EVar "isExcludedName") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "declImportEntries" ((PVar "exportsPerUnit") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EVar "usePathEntries") (EVar "exportsPerUnit")) (EVar "path")))
(DFunDef false "declImportEntries" ((PVar "exportsPerUnit") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declImportEntries") (EVar "exportsPerUnit")) (EVar "d")))
(DFunDef false "declImportEntries" (PWild PWild) (EListLit))
(DTypeSig false "usePathEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "usePathEntries" ((PVar "exportsPerUnit") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModIdU") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "lookupExports") (EVar "mid")) (EVar "exportsPerUnit")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exports")) () (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EDictApp "flatMap") (EApp (EVar "memberEntry") (EVar "exports"))) (EVar "members"))) (arm (PCon "UseWild" PWild) () (EApp (EApp (EDictApp "flatMap") (EVar "originEntryPair")) (EVar "exports"))) (arm (PCon "UseName" (PVar "ns")) () (EApp (EApp (EVar "originEntry") (EVar "exports")) (EApp (EVar "lastOfPM") (EVar "ns")))) (arm (PCon "UseAlias" PWild (PVar "a")) () (EApp (EApp (EDictApp "flatMap") (EApp (EVar "aliasEntryPair") (EVar "a"))) (EVar "exports"))))))))))
(DTypeSig false "memberEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "memberEntry" ((PVar "exports") (PVar "m")) (EApp (EApp (EApp (EVar "originEntryAs") (EVar "exports")) (EApp (EVar "useMemberOrigin") (EVar "m"))) (EApp (EVar "useMemberLocal") (EVar "m"))))
(DTypeSig false "originEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "originEntry" ((PVar "exports") (PVar "n")) (EApp (EApp (EApp (EVar "originEntryAs") (EVar "exports")) (EVar "n")) (EVar "n")))
(DTypeSig false "originEntryAs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "originEntryAs" ((PVar "exports") (PVar "origin") (PVar "local")) (EIf (EApp (EVar "isExcludedName") (EVar "origin")) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "lookupDefiner") (EVar "origin")) (EVar "exports")) (arm (PCon "Some" (PVar "definer")) () (EListLit (ETuple (EVar "local") (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "origin"))))) (arm (PCon "None") () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "originEntryPair" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "originEntryPair" ((PTuple (PVar "n") (PVar "definer"))) (EIf (EApp (EVar "isExcludedName") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "aliasEntryPair" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "aliasEntryPair" ((PVar "a") (PTuple (PVar "n") (PVar "definer"))) (EIf (EApp (EVar "isExcludedName") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "n")) (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "useModIdU" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useModIdU" ((PCon "UseName" (PVar "ns"))) (EIf (EApp (EVar "lenGt1") (EVar "ns")) (EApp (EVar "joinDot") (EApp (EVar "initList") (EVar "ns"))) (EApp (EApp (EVar "firstOrU") (ELit (LString ""))) (EVar "ns"))))
(DFunDef false "useModIdU" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModIdU" ((PCon "UseWild" (PVar "ns"))) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModIdU" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DTypeSig false "lenGt1" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "lenGt1" ((PCons PWild (PCons PWild PWild))) (EVar "True"))
(DFunDef false "lenGt1" (PWild) (EVar "False"))
(DTypeSig false "firstOrU" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "firstOrU" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "firstOrU" (PWild (PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "lastOfPM" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastOfPM" ((PList)) (ELit (LString "")))
(DFunDef false "lastOfPM" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOfPM" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastOfPM") (EVar "rest")))
(DTypeSig false "lookupExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "lookupExports" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupExports" ((PVar "k") (PCons (PTuple (PVar "m") (PVar "ns")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "m")) (EApp (EVar "Some") (EVar "ns")) (EApp (EApp (EVar "lookupExports") (EVar "k")) (EVar "rest"))))
(DTypeSig false "pubFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pubFnNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "defined") (EApp (EVar "unitDefNames") (ETuple (ELit (LString "")) (EVar "decls")))) (DoLet false false (PVar "pubSigs") (EApp (EVar "pubSigNames") (EVar "decls"))) (DoLet false false (PVar "pubDefs") (EApp (EVar "pubDefNames") (EVar "decls"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "defined")))) (EBinOp "++" (EVar "pubSigs") (EVar "pubDefs"))))))
(DTypeSig false "pubDefNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pubDefNames" ((PList)) (EListLit))
(DFunDef false "pubDefNames" ((PCons (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "pubDefNames") (EVar "rest"))))
(DFunDef false "pubDefNames" ((PCons (PCon "DLetGroup" (PCon "True") (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")) (EApp (EVar "pubDefNames") (EVar "rest"))))
(DFunDef false "pubDefNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "pubDefNames") (EListLit (EVar "d"))) (EApp (EVar "pubDefNames") (EVar "rest"))))
(DFunDef false "pubDefNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubDefNames") (EVar "rest")))
(DTypeSig false "unitDefNames" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitDefNames" ((PTuple PWild (PVar "decls"))) (EApp (EApp (EDictApp "flatMap") (EVar "declDefNames")) (EVar "decls")))
(DTypeSig false "declDefNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declDefNames" ((PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "declDefNames" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")))
(DFunDef false "declDefNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declDefNames") (EVar "d")))
(DFunDef false "declDefNames" (PWild) (EListLit))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "pubSigNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pubSigNames" ((PList)) (EListLit))
(DFunDef false "pubSigNames" ((PCons (PCon "DTypeSig" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "pubSigNames") (EVar "rest"))))
(DFunDef false "pubSigNames" ((PCons (PCon "DExtern" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "pubSigNames") (EVar "rest"))))
(DFunDef false "pubSigNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "pubSigNames") (EListLit (EVar "d"))) (EApp (EVar "pubSigNames") (EVar "rest"))))
(DFunDef false "pubSigNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubSigNames") (EVar "rest")))
(DTypeSig true "mangledName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "mangledName" ((PVar "mid") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "sanitizeId") (EVar "mid")))) (ELit (LString "__"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DTypeSig false "sanitizeId" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sanitizeId" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "s")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))) (ELit (LString ""))))
(DTypeSig false "sanitizeGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "sanitizeGo" ((PVar "s") (PVar "i") (PVar "len") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "acc") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s"))) (DoLet false false (PVar "c2") (EIf (EApp (EVar "safeChar") (EVar "c")) (EVar "c") (ELit (LString "_")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EBinOp "++" (EVar "acc") (EVar "c2")))))))
(DTypeSig true "safeChar" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "safeChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "a"))) (EBinOp "<=" (EVar "c") (ELit (LString "z")))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "A"))) (EBinOp "<=" (EVar "c") (ELit (LString "Z"))))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "0"))) (EBinOp "<=" (EVar "c") (ELit (LString "9"))))) (EBinOp "==" (EVar "c") (ELit (LString "_")))))
(DTypeSig true "hashName" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "hashName" ((PVar "s")) (EApp (EApp (EApp (EVar "hashChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))) (ELit (LInt 5381))))
(DTypeSig false "hashChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "hashChars" ((PVar "cs") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "hashChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 33))) (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "renameDecl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "patVarsListPM") (EVar "ps"))) (EVar "e"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DTypeSig" (PVar "pub") (PVar "n") (PVar "ty"))) (EApp (EApp (EApp (EVar "DTypeSig") (EVar "pub")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EVar "ty")))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EVar "renameIfaceMethod") (EVar "rm"))) (EVar "methods"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EVar "renameImplMethod") (EVar "rm"))) (EVar "methods"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "propParamNamesPM") (EVar "params"))) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EListLit)) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DBench" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DBench") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EListLit)) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EMethodRef "map") (EApp (EVar "renameLetBindDef") (EVar "rm"))) (EVar "binds"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DData" (PVar "vis") (PVar "tyname") (PVar "tps") (PVar "variants") (PVar "derives"))) (EApp (EApp (EApp (EApp (EApp (EVar "DData") (EVar "vis")) (EVar "tyname")) (EVar "tps")) (EApp (EApp (EMethodRef "map") (EApp (EVar "renameVariant") (EVar "rm"))) (EVar "variants"))) (EVar "derives")))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DNewtype" (PVar "pub") (PVar "tyname") (PVar "tps") (PVar "con") (PVar "fty") (PVar "derives"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DNewtype") (EVar "pub")) (EVar "tyname")) (EVar "tps")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "con"))) (EVar "fty")) (EVar "derives")))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "renameDecl") (EVar "rm")) (EVar "d"))))
(DFunDef false "renameDecl" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "renameVariant" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Variant") (TyCon "Variant"))))
(DFunDef false "renameVariant" ((PVar "rm") (PCon "Variant" (PVar "n") (PVar "payload"))) (EApp (EApp (EVar "Variant") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EVar "payload")))
(DTypeSig false "renameLetBindDef" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "renameLetBindDef" ((PVar "rm") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameFunClause") (EVar "rm")) (EListLit))) (EVar "clauses"))))
(DTypeSig false "renameDefName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "renameDefName" ((PVar "rm") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "rm")) (arm (PCon "Some" (PVar "n2")) () (EVar "n2")) (arm (PCon "None") () (EVar "n"))))
(DTypeSig false "renameIfaceMethod" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))
(DFunDef false "renameIfaceMethod" (PWild (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None"))) (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EVar "None")))
(DFunDef false "renameIfaceMethod" ((PVar "rm") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "e"))))) (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "patVarsListPM") (EVar "ps"))) (EVar "e"))))))
(DTypeSig false "renameImplMethod" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))
(DFunDef false "renameImplMethod" ((PVar "rm") (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "patVarsListPM") (EVar "ps"))) (EVar "e"))))
(DTypeSig false "propParamNamesPM" (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "propParamNamesPM" ((PVar "ps")) (EApp (EApp (EMethodRef "map") (EVar "propParamNamePM")) (EVar "ps")))
(DTypeSig false "propParamNamePM" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "propParamNamePM" ((PCon "PropParam" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "renameScoped" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EVar" (PVar "n"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "bound"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "rm")) (arm (PCon "Some" (PVar "n2")) () (EApp (EVar "EVar") (EVar "n2"))) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))) (EIf (EVar "otherwise") (EApp (EVar "EVar") (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "ELam") (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EBinOp "++" (EApp (EVar "patVarsListPM") (EVar "ps")) (EVar "bound"))) (EVar "body"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELet" (PVar "m") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "pv") (EApp (EVar "patVarsPM") (EVar "p"))) (DoLet false false (PVar "b1") (EIf (EVar "r") (EBinOp "++" (EVar "pv") (EVar "bound")) (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "b1")) (EVar "e1"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EBinOp "++" (EVar "pv") (EVar "bound"))) (EVar "e2"))))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELetGroup" (PVar "binds") (PVar "e2"))) (EBlock (DoLet false false (PVar "bnd") (EBinOp "++" (EApp (EVar "letBindNamesPM") (EVar "binds")) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameLetBind") (EVar "rm")) (EVar "bnd"))) (EVar "binds"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bnd")) (EVar "e2"))))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameArm") (EVar "rm")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "f"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "x"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "c"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "t"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "dr"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "l"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "r"))) (EVar "dr")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EUnOp" (PVar "op") (PVar "x") (PVar "dr"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "x"))) (EVar "dr")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "l"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "r"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "n")) (EVar "r")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")) (EVar "r")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EIndex" (PVar "e0") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "i"))) (EVar "r")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs"))) (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EVariantUpdate" (PVar "c") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "c"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameInterp") (EVar "rm")) (EVar "bound"))) (EVar "parts"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameGuardArm") (EVar "rm")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e0")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0")))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESection" (PCon "SecLeft" (PVar "e0") (PVar "op")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "op"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameKv") (EVar "rm")) (EVar "bound"))) (EVar "kvs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EAsPat" (PVar "x") (PVar "sub"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EMethodRef "sub"))))
(DFunDef false "renameScoped" (PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "renameField" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))))
(DFunDef false "renameField" ((PVar "rm") (PVar "bound") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "renameKv" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "renameKv" ((PVar "rm") (PVar "bound") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "k")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "v"))))
(DTypeSig false "renameInterp" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))))
(DFunDef false "renameInterp" (PWild PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "renameInterp" ((PVar "rm") (PVar "bound") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "renameLetBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "LetBind") (TyCon "LetBind")))))
(DFunDef false "renameLetBind" ((PVar "rm") (PVar "bound") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameFunClause") (EVar "rm")) (EVar "bound"))) (EVar "clauses"))))
(DTypeSig false "renameFunClause" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "FunClause") (TyCon "FunClause")))))
(DFunDef false "renameFunClause" ((PVar "rm") (PVar "bound") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EBinOp "++" (EApp (EVar "patVarsListPM") (EVar "ps")) (EVar "bound"))) (EVar "body"))))
(DTypeSig false "renameArm" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Arm") (TyCon "Arm")))))
(DFunDef false "renameArm" ((PVar "rm") (PVar "bound") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "b0") (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "p")) (EVar "bound"))) (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EVar "b0")) (EVar "gs"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EVar "gs2")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "renameGuardArm" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))))
(DFunDef false "renameGuardArm" ((PVar "rm") (PVar "bound") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EVar "bound")) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "gs2")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "renameGuards" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "renameGuards" (PWild (PVar "bound") (PList)) (ETuple (EListLit) (EVar "bound")))
(DFunDef false "renameGuards" ((PVar "rm") (PVar "bound") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EVar "bound")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DFunDef false "renameGuards" ((PVar "rm") (PVar "bound") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "p")) (EVar "bound"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DTypeSig false "renameStmts" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "renameStmts" (PWild PWild (PList)) (EListLit))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "DoExpr") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoBind") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "p")) (EVar "bound"))) (EVar "rest"))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "b1") (EIf (EVar "r") (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "p")) (EVar "bound")) (EVar "bound"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "b1")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "p")) (EVar "bound"))) (EVar "rest"))))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DTypeSig false "letBindNamesPM" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindNamesPM" ((PVar "binds")) (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")))
(DTypeSig false "patVarsPM" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsPM" ((PCon "PVar" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "patVarsPM" ((PCon "PCon" PWild (PVar "args"))) (EApp (EVar "patVarsListPM") (EVar "args")))
(DFunDef false "patVarsPM" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "h")) (EApp (EVar "patVarsPM") (EVar "t"))))
(DFunDef false "patVarsPM" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "patVarsListPM") (EVar "ps")))
(DFunDef false "patVarsPM" ((PCon "PList" (PVar "ps"))) (EApp (EVar "patVarsListPM") (EVar "ps")))
(DFunDef false "patVarsPM" ((PCon "PAs" (PVar "x") (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patVarsPM") (EVar "p"))))
(DFunDef false "patVarsPM" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "recPatFieldVarsPM")) (EVar "fields")))
(DFunDef false "patVarsPM" (PWild) (EListLit))
(DTypeSig false "patVarsListPM" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsListPM" ((PVar "ps")) (EApp (EApp (EDictApp "flatMap") (EVar "patVarsPM")) (EVar "ps")))
(DTypeSig false "renamePat" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PCon" (PVar "n") (PVar "args"))) (EApp (EApp (EVar "PCon") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "args"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCons") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "h"))) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "t"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EMethodRef "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PAs" (PVar "x") (PVar "p"))) (EApp (EApp (EVar "PAs") (EVar "x")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PRec" (PVar "n") (PVar "fields") (PVar "open"))) (EApp (EApp (EApp (EVar "PRec") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renameRecPatField") (EVar "rm"))) (EVar "fields"))) (EVar "open")))
(DFunDef false "renamePat" (PWild (PVar "p")) (EVar "p"))
(DTypeSig false "renameRecPatField" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "RecPatField") (TyCon "RecPatField"))))
(DFunDef false "renameRecPatField" (PWild (PCon "RecPatField" (PVar "label") (PCon "None"))) (EApp (EApp (EVar "RecPatField") (EVar "label")) (EVar "None")))
(DFunDef false "renameRecPatField" ((PVar "rm") (PCon "RecPatField" (PVar "label") (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "RecPatField") (EVar "label")) (EApp (EVar "Some") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p")))))
(DTypeSig false "renamePatsPM" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "renamePatsPM" ((PVar "rm") (PVar "ps")) (EApp (EApp (EMethodRef "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps")))
(DTypeSig false "recPatFieldVarsPM" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recPatFieldVarsPM" ((PCon "RecPatField" (PVar "label") (PCon "None"))) (EListLit (EVar "label")))
(DFunDef false "recPatFieldVarsPM" ((PCon "RecPatField" PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patVarsPM") (EVar "p")))
