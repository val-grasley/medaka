# META
source_lines=1479
stages=DESUGAR,MARK
# SOURCE
-- elaborated-AST → Core IR lowering (STAGE2-DESIGN §2.1).  Consumes the SAME
-- desugared (and, on the typed path, marked + route-stamped) AST the tree-walker
-- consumes, and produces `core_ir.mdk`'s backend-neutral IR.
--
-- The lowering is where the surface→primitive collapse happens (see core_ir.mdk
-- header): `&&`/`||` become short-circuiting `CIf`, `|>` becomes `CApp`, the
-- composition operators become explicit `CLam`s, type annotations are erased,
-- and the typechecker's mutable dispatch `Ref Route` cells are *read out* into
-- immutable `CMethod`/`CDict` nodes.  Everything else is a structural one-to-one
-- map (the IR deliberately stays close to the core AST so the equivalence gate
-- is a clean diff, not a rewrite).

import frontend.ast.{
  Lit(..),
  Loc(..),
  Pat(..),
  RecPatField(..),
  Expr(..),
  Arm(..),
  Guard(..),
  DoStmt(..),
  FieldAssign(..),
  LetBind(..),
  FunClause(..),
  Addr(..),
  Decl(..),
  Variant(..),
  ConPayload(..),
  Field(..),
  Ty(..),
  Constraint(..),
  IfaceMethod(..),
  MethodDefault(..),
  ImplMethod(..),
  Route(..),
}
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
import eval.eval.{
  buildCtorToType,
  buildCtorFieldOrders,
  ctorFieldOrdersRef,
  installDispatchTables,
  lookupPositions,
  tyvarsInArgs,
  headTyconHead,
  implKeyOf,
}
import list.{replicate}
import support.ordmap.{OrdMap, omEmpty, omInsert, omHasKey}
import backend.private_mangle.{sanitizeId}
import support.util.{
  contains,
  listLen,
  allList,
  anyList,
  lookupAssoc,
  noneHeadTag,
  isEmptyL,
  isNonEmptyL,
  reverseL,
  startsWith,
}

-- a synthetic binder for the lowered composition operators; constructed
-- directly (never parsed) so the unusual name is harmless.
composeVar : String
composeVar = "$cf"

-- ── expressions ────────────────────────────────────────────────────────────
export lower : Expr -> CExpr
lower (ELit l) = CLit l
-- PLAN.md #11: dictPass rewrites every ENumLit to ELit before lowering; this
-- arm is defensive (a non-rewritten path) — a Float-stamped ref lowers to a
-- float constant, else an int.
lower (ENumLit n r _ _) = match r.value
  Some f => CLit (LFloat f)
  None => CLit (LInt n)
lower (EVar x) = CVar x AGlobal
-- #837: strip the resolve-only binding-id tag; lower exactly as bare EVar.
lower (EVarId x _) = CVar x AGlobal
lower (EVarAt x addr) = CVar x addr
lower (EApp f x) = CApp (lower f) (lower x)
lower (ELam pats body) = CLam pats (lower body)
lower (ELet _ recFlag pat e1 e2) = CLet recFlag pat (lower e1) (lower e2)
lower (ELetGroup binds body) = CLetGroup (map lowerBind binds) (lower body)
lower (EMatch scrut arms) = lowerMatch (lower scrut) arms
lower (EIf c t e) = CIf (lower c) (lower t) (lower e)
lower (EBinOp op l r route) = lowerBinop op l r (scalarTagOfRoute route.value)
lower (EInfix op l r) = CApp (CApp (CVar op AGlobal) (lower l)) (lower r)
lower (EUnOp op e _) = CUnOp op (lower e)
lower (ETuple es) = CTuple (map lower es)
lower (EListLit es) = CList (map lower es)
lower (EArrayLit es) = CArray (map lower es)
lower (ERangeList lo hi incl) = CRangeList (lower lo) (lower hi) incl
lower (ERangeArray lo hi incl) = CRangeArray (lower lo) (lower hi) incl
lower (EIndex a i r) =
  if r.value == "String" then
    CStringIndex (lower a) (lower i)
  else if r.value == "List" then
    CListIndex (lower a) (lower i)
  else
    CIndex (lower a) (lower i)
lower (ESlice a lo hi incl r) =
  if r.value == "String" then
    CStringSlice (lower a) (lower lo) (lower hi) incl
  else if r.value == "List" then
    CListSlice (lower a) (lower lo) (lower hi) incl
  else
    CSlice (lower a) (lower lo) (lower hi) incl
lower (EFieldAccess e f r) = CFieldAccess (lower e) f r.value
lower (ERecordCreate name fields) = CRecord name (map lowerField fields)
lower (ERecordUpdate base fields r) =
  CRecordUpdate r.value (lower base) (map lowerField fields)
lower (EVariantUpdate con base fields) =
  CVariantUpdate con (lower base) (map lowerField fields)
lower (EBlock stmts) = CBlock (map lowerStmt stmts)
-- SHARED-FLOAT-RESIDUAL §3(C): dictPass wraps a scalar-tagged arithmetic binop in
-- `EAnnot (EBinOp …) (TyCon tag)` (the ref-cell route does not survive to here, a
-- node does).  Read the tag into CBinPrim's scalar field so the emitter picks the
-- Float primitive.  Must precede the transparent `EAnnot e _` strip below.
lower (EAnnot (EBinOp op l r _) (TyCon tag _)) = lowerBinop op l r tag
lower (EAnnot e _) = lower e
lower (EHeadAnnot e _) = lower e
-- dispatch: read the typechecker-filled route out of the mutable cell, making it
-- structural + immutable in the IR (slice 5; present so the lowering is total).
-- (instance-`requires` impl dicts — the second ref — are unsupported in the Core
-- IR experiment; drop them, the core_ir fixtures carry no requires-impls)
lower (EMethodAt name routeRef implRef methodRef) =
  CMethod name routeRef.value implRef.value methodRef.value
lower (EDictAt name routesRef) = CDict name routesRef.value
-- ELoc is STRIPPED here: no source-location wrapper reaches the Core IR, so the
-- emitted IR for any program is byte-identical to the un-wrapped tree.  This is
-- the fixpoint guarantee (the transparent strip that keeps the C3 IR stable).
lower (ELoc _ e) = lower e
lower (EDoOrigin _ e) = lower e
lower other = panic ("core_ir lower: unsupported node " ++ nodeTag other)

-- surface binops that are really sugar are lowered to primitive control flow /
-- application here; only the genuinely-primitive ops survive as CBinPrim.
-- the scalar-type tag carried on an EBinOp's route ("Float"/"Int" for a stamped
-- monomorphic concrete-primitive arithmetic operand; "" otherwise).  Only
-- RScalar carries it; every dispatch route (RKey/RDict/…) means "unstamped".
scalarTagOfRoute : Route -> String
scalarTagOfRoute (RScalar s) = s
scalarTagOfRoute _ = ""

lowerBinop : String -> Expr -> Expr -> String -> CExpr
lowerBinop "&&" l r _ = CIf (lower l) (lower r) (CLit (LBool False))
lowerBinop "||" l r _ = CIf (lower l) (CLit (LBool True)) (lower r)
lowerBinop "|>" l r _ = CApp (lower r) (lower l)
lowerBinop ">>" l r _ = composeLam (lower l) (lower r)
lowerBinop "<<" l r _ = composeLam (lower r) (lower l)
lowerBinop op l r tag = CBinPrim op (lower l) (lower r) tag

-- (f >> g) ≡ \x -> g (f x).  composeLam first second ≡ \x -> second (first x).
composeLam : CExpr -> CExpr -> CExpr
composeLam first second = CLam
  [PVar composeVar (Loc "" 0 0 0 0)]
  (CApp second (CApp first (CVar composeVar AGlobal)))

lowerArm : Arm -> CArm
lowerArm (Arm pat guards body) = CArm pat (map lowerGuard guards) (lower body)

lowerGuard : Guard -> CGuard
lowerGuard (GBool e) = CGBool (lower e)
lowerGuard (GBind p e) = CGBind p (lower e)

-- ── decision-tree match compilation (§2.1) ─────────────────────────────────
-- Compile a `match`'s ordered arms into a CDecision (decision tree) when every
-- arm pattern is tree-able; otherwise emit the ordered-arm CMatch unchanged.
-- The fall-back keeps the proven ordered path for record/range patterns the
-- tree compiler doesn't model — correctness first, the tree captures the win on
-- the constructor/list/tuple/literal matches that dominate the lexer + parser.
lowerMatch : CExpr -> List Arm -> CExpr
lowerMatch cscrut arms
  | allList armTreeable arms =
    CDecision cscrut (map lowerArm arms) (compileArms arms)
  | otherwise = CMatch cscrut (map lowerArm arms)

armTreeable : Arm -> Bool
armTreeable (Arm pat _ _) = treeablePat pat

-- a pattern is tree-able if it is built only from constructors / lists / tuples
-- / literals / vars / wildcards / as-patterns / record / range patterns.
-- PRng and PRec canonicalize to PWild in the matrix (see canonPat); arms
-- containing them are marked as "needs guard" (patNeedsGuard) so the tree
-- emits CTGuard leaves that fall through on matchPat failure, preserving the
-- ordered semantics exactly.
treeablePat : Pat -> Bool
treeablePat PWild = True
treeablePat (PVar _ _) = True
treeablePat (PLit _) = True
treeablePat (PCon _ args) = allList treeablePat args
treeablePat (PCons h t) = treeablePat h && treeablePat t
treeablePat (PList ps) = allList treeablePat ps
treeablePat (PTuple ps) = allList treeablePat ps
treeablePat (PAs _ _ p) = treeablePat p
treeablePat (PRng _ _ _) = True
treeablePat (PRec _ _ _) = True

compileArms : List Arm -> CTree
compileArms arms = compileTree (map armHasGuard arms) (initialRows arms 0)

-- an arm whose pattern (recursively) contains PRng or PRec may not match the
-- scrutinee at the leaf even though the matrix treated it as a wildcard — the
-- tree leaf must therefore be a CTGuard (fall-through on matchPat failure) rather
-- than a CTLeaf (which assumes the pattern is guaranteed to match the scrutinee).
armHasGuard : Arm -> Bool
armHasGuard (Arm pat gs _) = isNonEmptyL gs || patNeedsGuard pat

patNeedsGuard : Pat -> Bool
patNeedsGuard (PRng _ _ _) = True
patNeedsGuard (PRec _ _ _) = True
patNeedsGuard (PCon _ args) = anyList patNeedsGuard args
patNeedsGuard (PCons h t) = patNeedsGuard h || patNeedsGuard t
patNeedsGuard (PList ps) = anyList patNeedsGuard ps
patNeedsGuard (PTuple ps) = anyList patNeedsGuard ps
patNeedsGuard (PAs _ _ p) = patNeedsGuard p
patNeedsGuard _ = False

-- one matrix row per arm: its (canonicalised) pattern as a single column, paired
-- with the arm's index (the leaves carry it back to the original CArm).
initialRows : List Arm -> Int -> List (List Pat, Int)
initialRows [] _ = []
initialRows ((Arm pat _ _)::rest) i =
  ([canonPat pat], i) :: initialRows rest (i + 1)

-- ── the Maranget recursion, emitting a tree (mirrors exhaust.mdk's matrix ops,
-- re-implemented here over index-carrying rows since exhaust's are stage-local).
-- Always discriminates the leftmost column; a row's index rides along through
-- specialization so the leaf knows which arm it selected.
-- exported for the LLVM backend (slice 7): arg-position dispatch coalesces an
-- impl method's clauses into a decision tree via this same Maranget compiler —
-- the backend-neutral transform Axis-1 designates as shared by both backends
-- (only leaf emission differs: bytecode SWITCH vs LLVM switch/br).
export compileTree : List Bool -> List (List Pat, Int) -> CTree
compileTree _ [] = CTFail
compileTree guards (row::rest) = compileRows guards row rest (row::rest)

compileRows : List Bool -> (List Pat, Int) -> List (List Pat, Int) -> List (List Pat, Int) -> CTree
compileRows guards (pats, i) rest rows
  | allWild pats = leafOrGuard guards i rest
  | anyList rowHasCon rows = buildConSwitch guards rows
  | anyList rowHasLit rows = buildLitSwitch guards rows
  | otherwise = CTDrop (compileTree guards (map dropHead rows))

-- the first (highest-priority still-viable) row matches everything reaching
-- here: a guarded clause becomes a CTGuard whose failure resumes at `rest`; an
-- unguarded one terminates (later rows are unreachable, exactly as ordered).
leafOrGuard : List Bool -> Int -> List (List Pat, Int) -> CTree
leafOrGuard guards i rest
  | nthBool guards i = CTGuard i (compileTree guards rest)
  | otherwise = CTLeaf i

buildConSwitch : List Bool -> List (List Pat, Int) -> CTree
buildConSwitch guards rows =
  CTSwitch
    (map (conBranch guards rows) (distinctConHeads rows))
    (compileTree guards (defaultMatrix rows))

conBranch : List Bool -> List (List Pat, Int) -> (String, Int) -> CTBranch
conBranch guards rows (c, a) =
  CTBranch (decodeHead c a) (compileTree guards (specializeCon c a rows))

buildLitSwitch : List Bool -> List (List Pat, Int) -> CTree
buildLitSwitch guards rows =
  CTSwitch
    (map (litBranch guards rows) (distinctLits rows))
    (compileTree guards (defaultMatrix rows))

litBranch : List Bool -> List (List Pat, Int) -> Lit -> CTBranch
litBranch guards rows l =
  CTBranch (HLit l) (compileTree guards (specializeLit l rows))

-- map a canonical constructor name + arity to the runtime head the evaluator
-- tests with (the synthetic list/tuple/unit names canonPat introduced map back
-- to their real Value shapes; everything else is a plain named constructor).
-- The built-in forms key off RESERVED synthetic names (`__cons__`/`__nil__`/
-- `__unit__`/`__tuple__`, all un-writable as user ctors) — NOT the user-facing
-- `Cons`/`Nil`/`Unit`. A user `data T = Cons … | Nil` therefore lowers its
-- ctors to `HCon "Cons"`/`HCon "Nil"` (→ VCon shapes), not the built-in list
-- heads; aliasing the two was a silent ceval miscompile (decodeHead bug).
decodeHead : String -> Int -> CHead
decodeHead "__cons__" _ = HCons
decodeHead "__nil__" _ = HNil
decodeHead "__unit__" _ = HUnit
decodeHead "__tuple__" a = HTuple a
decodeHead c a = HCon c a

-- ── canonical patterns for the matrix (mirror exhaust.mdk's desugarPat) ─────
-- Var → wildcard; lists → reserved __cons__/__nil__ chains; tuples → __tuple__;
-- Unit literal → reserved __unit__; Bool literals → True/False nullary ctors —
-- so specialization is uniform. The list/unit forms use RESERVED synthetic names
-- (not the user-facing `Cons`/`Nil`/`Unit`) so a user ctor of the same name can't
-- alias the built-in head. Only tree-able patterns reach here (PRng/PRec gated).
tupleName : String
tupleName = "__tuple__"

-- reserved synthetic head names for the built-in list/unit forms. Like
-- `tupleName`, these are un-writable as user constructors (lower-case + leading
-- `__`), so a user ctor literally named `Cons`/`Nil`/`Unit` keeps its own name
-- through the matrix and lowers to `HCon`, never the built-in list/unit heads.
consName : String
consName = "__cons__"

nilName : String
nilName = "__nil__"

unitName : String
unitName = "__unit__"

-- exported for the LLVM backend (slice 7): impl-method clauses are canonicalised
-- into the matrix form before `compileTree` (same as `initialRows` does for match
-- arms) — part of the shared backend-neutral decision-tree pass (Axis-1).
export canonPat : Pat -> Pat
canonPat (PVar _ _) = PWild
canonPat PWild = PWild
canonPat (PLit (LBool True)) = PCon "True" []
canonPat (PLit (LBool False)) = PCon "False" []
canonPat (PLit LUnit) = PCon unitName []
canonPat (PLit l) = PLit l
canonPat (PTuple ps) = PCon tupleName (map canonPat ps)
canonPat (PCon c args) = PCon c (map canonPat args)
canonPat (PCons h t) = PCon consName [canonPat h, canonPat t]
canonPat (PList []) = PCon nilName []
canonPat (PList (h::r)) = PCon consName [canonPat h, canonPat (PList r)]
canonPat (PAs _ _ p) = canonPat p
canonPat (PRng _ _ _) = PWild
canonPat (PRec _ _ _) = PWild

-- ── matrix predicates / column analysis ────────────────────────────────────
allWild : List Pat -> Bool
allWild ps = allList isWildPat ps

isWildPat : Pat -> Bool
isWildPat PWild = True
isWildPat _ = False

rowHasCon : (List Pat, Int) -> Bool
rowHasCon ((PCon _ _)::_, _) = True
rowHasCon _ = False

rowHasLit : (List Pat, Int) -> Bool
rowHasLit ((PLit _)::_, _) = True
rowHasLit _ = False

dropHead : (List Pat, Int) -> (List Pat, Int)
dropHead (_::ps, i) = (ps, i)
dropHead ([], i) = ([], i)

-- distinct head constructors present in column 0, first-seen order, each with
-- its arity (uniform per name in a well-typed column).
distinctConHeads : List (List Pat, Int) -> List (String, Int)
distinctConHeads rows = dedupHeads (colHeads rows) omEmpty

colHeads : List (List Pat, Int) -> List (String, Int)
colHeads [] = []
colHeads (((PCon c args)::_, _)::rest) = (c, listLen args) :: colHeads rest
colHeads (_::rest) = colHeads rest

-- First-seen dedup by constructor name.  `seen` is an `OrdMap`-backed membership
-- set (O(log n) test/insert) rather than a growing `List` scanned with `contains`
-- per head — that scan was O(arms^2) on an N-arm match over an N-ctor type (#960).
-- The output is still built at each head's FIRST occurrence, recursing on `rest`
-- unchanged, so first-occurrence ordering is byte-identical to the old list form.
dedupHeads : List (String, Int) -> OrdMap Unit -> List (String, Int)
dedupHeads [] _ = []
dedupHeads ((c, a)::rest) seen
  | omHasKey c seen = dedupHeads rest seen
  | otherwise = (c, a) :: dedupHeads rest (omInsert c () seen)

distinctLits : List (List Pat, Int) -> List Lit
distinctLits rows = dedupLits (colLits rows) omEmpty

colLits : List (List Pat, Int) -> List Lit
colLits [] = []
colLits (((PLit l)::_, _)::rest) = l :: colLits rest
colLits (_::rest) = colLits rest

-- First-seen dedup of the column's literal heads.  Mirrors #960's `dedupHeads`
-- fix: the old `seen` List scanned with `anyList (l == _)` per literal was
-- O(arms^2) on an N-arm literal match (a lexer/opcode/state-machine dispatch),
-- and — unlike `dedupHeads`' `contains` — the scan used the UNcounted `anyList`
-- AND each `Eq Lit` compare allocated, so the quadratic was invisible to the op
-- arm yet superlinear in allocation (#970).  `seen` is now an `OrdMap Unit`
-- membership set keyed by `litKey` (an injective, Eq-exact string render of the
-- literal): O(log n) test/insert.  The output is still built at each literal's
-- FIRST occurrence, recursing on `rest` unchanged, so first-occurrence order —
-- and therefore the emitted literal-switch — is byte-identical to the old form.
dedupLits : List Lit -> OrdMap Unit -> List Lit
dedupLits [] _ = []
dedupLits (l::rest) seen =
  let k = litKey l
  match omHasKey k seen
    True => dedupLits rest seen
    False => l :: dedupLits rest (omInsert k () seen)

-- A total, injective, Eq-exact string key for a match-column literal.  Each
-- constructor gets a distinct one-char tag, so keys can never collide ACROSS
-- constructors (the tag partitions the space); WITHIN a constructor the render
-- is injective, so `litKey a == litKey b`  iff  `a == b` (derived `Eq Lit`) —
-- exactly the membership test the old `anyList (l == _)` performed, preserving
-- dedup semantics.  Float note: -0.0 is normalised to +0.0 (they are `Eq`-equal
-- and the old `==` deduped them); NaN cannot be written as a pattern literal so
-- its `NaN != NaN` edge is unreachable here.  LBool/LUnit are canonicalised to
-- constructors before lowering (see `canonPat`), so those arms never reach this
-- function but are kept total.
litKey : Lit -> String
litKey (LInt n) = "i" ++ intToString n
litKey (LChar c) = "c" ++ c
litKey (LString s) = "s" ++ s
litKey (LFloat f) = "f" ++ floatToString (normLitZero f)
litKey (LBool True) = "bT"
litKey (LBool False) = "bF"
litKey LUnit = "u"

-- collapse -0.0 to +0.0 so the float key matches `Eq Lit` (which treats them
-- equal); a no-op for every other value.
normLitZero : Float -> Float
normLitZero f = if f == 0.0 then 0.0 else f

-- ── matrix specialization / default (over index-carrying rows) ─────────────
filterMapRows : ((List Pat, Int) -> Option (List Pat, Int)) -> List (List Pat, Int) -> List (List Pat, Int)
filterMapRows _ [] = []
filterMapRows f (r::rest) = match f r
  Some r2 => r2 :: filterMapRows f rest
  None => filterMapRows f rest

-- specialize on constructor c (arity): a matching head expands to its fields
-- ++ the rest; a wildcard head spreads `arity` wildcards; anything else drops.
specializeCon : String -> Int -> List (List Pat, Int) -> List (List Pat, Int)
specializeCon c arity rows = filterMapRows (specConRow c arity) rows

specConRow : String -> Int -> (List Pat, Int) -> Option (List Pat, Int)
specConRow c _ ((PCon c2 args)::rest, i) =
  if c2 == c then
    Some (args ++ rest, i)
  else
    None
specConRow _ arity (PWild::rest, i) = Some (replicate arity PWild ++ rest, i)
specConRow _ _ _ = None

-- specialize on a literal: a matching/​wildcard head drops (arity 0), else drop.
specializeLit : Lit -> List (List Pat, Int) -> List (List Pat, Int)
specializeLit l rows = filterMapRows (specLitRow l) rows

specLitRow : Lit -> (List Pat, Int) -> Option (List Pat, Int)
specLitRow l ((PLit l2)::rest, i) = if litEq l2 l then Some (rest, i) else None
specLitRow _ (PWild::rest, i) = Some (rest, i)
specLitRow _ _ = None

-- Alloc-free structural equality on literals, identical in result to the derived
-- `Eq Lit`.  `specLitRow` compares a literal ONCE PER (row × distinct-literal)
-- while lowering a literal switch, i.e. O(arms^2) compares on an N-arm match; the
-- derived `Eq Lit` (`mdk_impl_Lit_eq`) allocates on every call (verified by
-- profiling — GC_malloc_kind ← mdk_alloc ← mdk_impl_Lit_eq dominated the lowering
-- of a wide literal match), so those O(arms^2) compares allocated O(arms^2) too.
-- Comparing the primitive fields directly allocates nothing — exactly why the
-- constructor path (`specConRow`, a `String ==`) is already alloc-linear (#970).
litEq : Lit -> Lit -> Bool
litEq (LInt a) (LInt b) = a == b
litEq (LFloat a) (LFloat b) = a == b
litEq (LString a) (LString b) = a == b
litEq (LChar a) (LChar b) = a == b
litEq (LBool a) (LBool b) = a == b
litEq LUnit LUnit = True
litEq _ _ = False

-- the default matrix: rows whose head is a wildcard (head dropped); used for the
-- switch's default branch and (when column 0 is all wildcards) CTDrop.
defaultMatrix : List (List Pat, Int) -> List (List Pat, Int)
defaultMatrix rows = filterMapRows defRow rows

defRow : (List Pat, Int) -> Option (List Pat, Int)
defRow (PWild::rest, i) = Some (rest, i)
defRow _ = None

-- ── small local helpers ────────────────────────────────────────────────────

nthBool : List Bool -> Int -> Bool
nthBool (b::_) 0 = b
nthBool (_::rest) n = nthBool rest (n - 1)
nthBool [] _ = False

lowerField : FieldAssign -> CField
lowerField (FieldAssign k e) = CField k (lower e)

lowerBind : LetBind -> CBind
lowerBind (LetBind name clauses) = CBind name (map lowerClause clauses)

lowerClause : FunClause -> CClause
lowerClause (FunClause pats body) = CClause pats (lower body)

lowerStmt : DoStmt -> CStmt
lowerStmt (DoExpr e) = CSExpr (lower e)
lowerStmt (DoLet b _ pat e) = CSLet b pat (lower e)
lowerStmt (DoAssign x e) = CSAssign x (lower e)
lowerStmt _ = panic "core_ir lower: unsupported block statement"

-- ── programs ───────────────────────────────────────────────────────────────
-- Coalesce top-level multi-clause `DFunDef`s into one CBind per name (preserving
-- first-appearance order, exactly as eval.mdk's funGroupNames), gather the ctor
-- arity + ctor→type tables.  Interfaces/impls are slice-5 (no dispatch yet).
export lowerProgram : List Decl -> CProgram
lowerProgram prog =
  let _ = setRef ctorFieldOrdersRef (buildCtorFieldOrders prog)
  CProgram
    (lowerGroups prog)
    (ctorArities prog)
    (buildCtorToType prog)
    (lowerImpls prog)

-- ── record-pattern → positional-constructor-pattern rewrite (native backend) ──
-- The LLVM emitter has no record-pattern path: records / named-field variants are
-- heap CELLS `[tag | field0 | field1 | …]` exactly like positional constructors,
-- so a `match` on one is destructured by the SAME cellTag-test + positional
-- field-extraction machinery `PCon` already drives (emitDecision / bindPattern).
-- A `PRec "T" recFields open` is therefore lowered to `PCon "T" [sub-pattern per
-- field IN DECLARED ORDER]`: each declared field of `T` contributes (a) the
-- matching `RecPatField`'s sub-pattern, (b) `PVar label` if it is a pun (`None`),
-- or (c) `PWild` if the field is unnamed in the pattern (covers both the open
-- `..` form and a fully-specified record naming a subset).  After the rewrite no
-- PRec reaches canonPat / bindPattern, so the emitter needs no record-specific code.
--
-- This is an EMIT-ONLY transform: the tree-walking core_ir_eval evaluates a record
-- to a by-name `VRecord` and matches `PRec` by label, so it must NOT see the
-- positional `PCon` rewrite (a `PCon` would not match a `VRecord`).  Hence it lives
-- in `lowerProgramEmit` — which the LLVM emit drivers call — NOT in the shared
-- `lowerProgram` that core_ir_main / core_ir_eval use.  The field-order map is
-- DECLARED order (DData named-field variants), the same order
-- the emitter's record cell layout / recFieldTable use, so the positional indices
-- line up with the cell's stored field offsets (verified by the fixture byte-diff).
export lowerProgramEmit : List Decl -> CProgram
lowerProgramEmit prog =
  hoistNullaryMemo (rewriteProgramRecPats
    (buildRecPatFieldOrders prog)
    (lowerProgram prog))

-- type/ctor name → [field label in declared order], from every DData named-field
-- (`ConNamed`) variant — records are the `data X = { … }` short form, whose
-- synthesized ctor is a ConNamed variant.  (`DInterface`/`DImpl` are themselves
-- named-field variants of the AST's `Decl` type — declared in ast.mdk via `data
-- Decl = … | DInterface { … }` — so a self-hosted compiler that destructures them
-- gets their orders through the `DData ConNamed` branch when ast.mdk is in `prog`.)
buildRecPatFieldOrders : List Decl -> List (String, List String)
buildRecPatFieldOrders prog = flatMap recPatFieldOrderEntries prog

recPatFieldOrderEntries : Decl -> List (String, List String)
recPatFieldOrderEntries (DData _ _ _ variants _) =
  flatMap variantNamedOrder variants
recPatFieldOrderEntries (DAttrib _ inner) = recPatFieldOrderEntries inner
recPatFieldOrderEntries _ = []

variantNamedOrder : Variant -> List (String, List String)
variantNamedOrder (Variant n (ConNamed fs _)) = [(n, map fieldLabel fs)]
variantNamedOrder _ = []

fieldLabel : Field -> String
fieldLabel (Field n _) = n

-- the single pattern rewrite: a record pattern becomes a positional constructor
-- pattern over the type's declared field order; recurse into EVERY nested form.
rewritePat : List (String, List String) -> Pat -> Pat
rewritePat fo (PRec name recFields _) = match lookupAssoc name fo
  Some labels => PCon name (map (recPatForLabel fo recFields) labels)
  None => PRec name (map (rewriteRecPatField fo) recFields) False
-- no declared order found (e.g. an anonymous record with no `data`): leave the
-- PRec untouched — the emitter's existing gap-path reports it, no silent miscompile.

rewritePat fo (PCon c args) = PCon c (map (rewritePat fo) args)
rewritePat fo (PCons h t) = PCons (rewritePat fo h) (rewritePat fo t)
rewritePat fo (PTuple ps) = PTuple (map (rewritePat fo) ps)
rewritePat fo (PList ps) = PList (map (rewritePat fo) ps)
rewritePat fo (PAs x l p) = PAs x l (rewritePat fo p)
rewritePat _ p = p

-- the sub-pattern bound to declared field `label`: the named field's sub-pattern
-- (recursively rewritten), `PVar label` for a pun, or `PWild` when the field is
-- not named in the pattern (open `..` / subset).
recPatForLabel : List (String, List String) -> List RecPatField -> String -> Pat
recPatForLabel fo recFields label = match findRecField label recFields
  Some (RecPatField _ fl (Some sub)) => rewritePat fo sub
  Some (RecPatField _ fl None) => PVar label fl
  None => PWild

findRecField : String -> List RecPatField -> Option RecPatField
findRecField _ [] = None
findRecField label ((RecPatField l fl sub)::rest)
  | l == label = Some (RecPatField l fl sub)
  | otherwise = findRecField label rest

rewriteRecPatField : List (String, List String) -> RecPatField -> RecPatField
rewriteRecPatField fo (RecPatField l fl (Some sub)) =
  RecPatField l fl (Some (rewritePat fo sub))
rewriteRecPatField _ (RecPatField l fl None) = RecPatField l fl None

-- ── apply the rewrite to every pattern position the lowered Core IR carries ───
-- Walks the whole program (groups + impls), rewriting every pattern and — for a
-- CDecision — RECOMPILING its decision tree from the rewritten arms (the tree was
-- built from the original PRec arms, which canonPat wildcarded; the rewritten PCon
-- arms compile to a proper constructor switch with no needs-guard fall-through).
rewriteProgramRecPats : List (String, List String) -> CProgram -> CProgram
rewriteProgramRecPats fo (CProgram groups ctorArs ctorTypes implEntries) =
  CProgram
    (map (rewriteBindRP fo) groups)
    ctorArs
    ctorTypes
    (map (rewriteImplRP fo) implEntries)

rewriteBindRP : List (String, List String) -> CBind -> CBind
rewriteBindRP fo (CBind n clauses) = CBind n (map (rewriteClauseRP fo) clauses)

rewriteClauseRP : List (String, List String) -> CClause -> CClause
rewriteClauseRP fo (CClause pats body) =
  CClause (map (rewritePat fo) pats) (rewriteExprRP fo body)

rewriteImplRP : List (String, List String) -> CImplEntry -> CImplEntry
rewriteImplRP fo (CImplEntry n s (CImplTagged tag key iface ps pats body)) =
  CImplEntry
    n
    s
    (CImplTagged
      tag
      key
      iface
      ps
      (map (rewritePat fo) pats)
      (rewriteExprRP fo body))
rewriteImplRP fo (CImplEntry n s (CImplDefault pats body)) =
  CImplEntry
    n
    s
    (CImplDefault (map (rewritePat fo) pats) (rewriteExprRP fo body))

rewriteExprRP : List (String, List String) -> CExpr -> CExpr
rewriteExprRP _ (CLit l) = CLit l
rewriteExprRP _ (CVar x addr) = CVar x addr
rewriteExprRP fo (CApp f x) = CApp (rewriteExprRP fo f) (rewriteExprRP fo x)
rewriteExprRP fo (CLam pats body) =
  CLam (map (rewritePat fo) pats) (rewriteExprRP fo body)
rewriteExprRP fo (CLet r pat e1 e2) =
  CLet r (rewritePat fo pat) (rewriteExprRP fo e1) (rewriteExprRP fo e2)
rewriteExprRP fo (CLetGroup binds body) =
  CLetGroup (map (rewriteBindRP fo) binds) (rewriteExprRP fo body)
rewriteExprRP fo (CMatch scrut arms) =
  CMatch (rewriteExprRP fo scrut) (map (rewriteArmRP fo) arms)
rewriteExprRP fo (CDecision scrut arms _) =
  let arms2 = map (rewriteArmRP fo) arms
  CDecision (rewriteExprRP fo scrut) arms2 (compileArmsC arms2)
rewriteExprRP fo (CIf c t e) =
  CIf (rewriteExprRP fo c) (rewriteExprRP fo t) (rewriteExprRP fo e)
rewriteExprRP fo (CBinPrim op l r tag) =
  CBinPrim op (rewriteExprRP fo l) (rewriteExprRP fo r) tag
rewriteExprRP fo (CUnOp op x) = CUnOp op (rewriteExprRP fo x)
rewriteExprRP fo (CTuple es) = CTuple (map (rewriteExprRP fo) es)
rewriteExprRP fo (CList es) = CList (map (rewriteExprRP fo) es)
rewriteExprRP fo (CRecord name fields) =
  CRecord name (map (rewriteFieldRP fo) fields)
rewriteExprRP fo (CFieldAccess ex f n) = CFieldAccess (rewriteExprRP fo ex) f n
rewriteExprRP fo (CRecordUpdate name base fields) =
  CRecordUpdate name (rewriteExprRP fo base) (map (rewriteFieldRP fo) fields)
rewriteExprRP fo (CVariantUpdate con base fields) =
  CVariantUpdate con (rewriteExprRP fo base) (map (rewriteFieldRP fo) fields)
rewriteExprRP fo (CArray es) = CArray (map (rewriteExprRP fo) es)
rewriteExprRP fo (CRangeList lo hi incl) =
  CRangeList (rewriteExprRP fo lo) (rewriteExprRP fo hi) incl
rewriteExprRP fo (CRangeArray lo hi incl) =
  CRangeArray (rewriteExprRP fo lo) (rewriteExprRP fo hi) incl
rewriteExprRP fo (CIndex a i) = CIndex (rewriteExprRP fo a) (rewriteExprRP fo i)
rewriteExprRP fo (CSlice a lo hi incl) =
  CSlice (rewriteExprRP fo a) (rewriteExprRP fo lo) (rewriteExprRP fo hi) incl
rewriteExprRP fo (CStringIndex a i) =
  CStringIndex (rewriteExprRP fo a) (rewriteExprRP fo i)
rewriteExprRP fo (CStringSlice a lo hi incl) =
  CStringSlice
    (rewriteExprRP fo a)
    (rewriteExprRP fo lo)
    (rewriteExprRP fo hi)
    incl
rewriteExprRP fo (CListIndex a i) =
  CListIndex (rewriteExprRP fo a) (rewriteExprRP fo i)
rewriteExprRP fo (CListSlice a lo hi incl) =
  CListSlice
    (rewriteExprRP fo a)
    (rewriteExprRP fo lo)
    (rewriteExprRP fo hi)
    incl
rewriteExprRP fo (CBlock stmts) = CBlock (map (rewriteStmtRP fo) stmts)
rewriteExprRP _ (CMethod name r ir mr) = CMethod name r ir mr
rewriteExprRP _ (CDict name rs) = CDict name rs

rewriteArmRP : List (String, List String) -> CArm -> CArm
rewriteArmRP fo (CArm pat guards body) =
  CArm
    (rewritePat fo pat)
    (map (rewriteGuardRP fo) guards)
    (rewriteExprRP fo body)

rewriteGuardRP : List (String, List String) -> CGuard -> CGuard
rewriteGuardRP fo (CGBool e) = CGBool (rewriteExprRP fo e)
rewriteGuardRP fo (CGBind p e) = CGBind (rewritePat fo p) (rewriteExprRP fo e)

rewriteStmtRP : List (String, List String) -> CStmt -> CStmt
rewriteStmtRP fo (CSExpr e) = CSExpr (rewriteExprRP fo e)
rewriteStmtRP fo (CSLet r pat e) =
  CSLet r (rewritePat fo pat) (rewriteExprRP fo e)
rewriteStmtRP fo (CSAssign x e) = CSAssign x (rewriteExprRP fo e)

rewriteFieldRP : List (String, List String) -> CField -> CField
rewriteFieldRP fo (CField k e) = CField k (rewriteExprRP fo e)

-- ── #719: nullary return-position impl-method CAF memoisation (emit backends) ──
-- A point-free (nullary) RETURN-POSITION impl method at a fixed concrete type
-- (`theUnit : a`; RKey-dispatched, no discriminating argument) is a per-instance
-- CAF: eval evaluates its body ONCE and shares the value at every occurrence at
-- that type (eval.mdk implMethodValue/memoThunk, TYPECHECK-AUDIT C6).  Both emit
-- backends, however, lowered each occurrence to a fresh `call
-- @mdk_impl_<tag>_<method>()`, re-running the body — duplicating any side effect
-- (issue #719, silent run != build on the LLVM and WasmGC backends).
--
-- Fix (emit-only, so BOTH backends inherit it via lowerProgramEmit — the eval arm
-- already memoises): HOIST each such occurrence to a synthesized top-level value
-- binding `$memo_<tag>_<method> = <the nullary CMethod>` and replace the occurrence
-- with a reference to it.  The existing top-level value-global CAF machinery (#561
-- lazy globals) then computes the body once, memoises it, and black-holes a cyclic
-- self-force into E-CYCLIC-VALUE — the SAME machinery that already makes a top-level
-- `x = theUnit : Box` correct on both backends.  No new memo infrastructure.
--
-- Gated to EXACTLY eval's memoThunk case: an RKey route with NO nested (parametric-
-- impl) dicts and NO impl/method dict routes (`CMethod _ (RKey tag []) [] []`), whose
-- resolved impl is RETURN-position (`positions == []`) AND point-free (`pats == []`).
-- A method WITH arguments (non-empty pats), a discriminating-arg method (non-empty
-- positions), a runtime-dict route (RDict/RDictFwd), or a dict-parametric impl
-- (non-empty routes) is NOT hoisted — it keeps its per-call semantics.
--
-- Only occurrences that ACTUALLY appear are hoisted: the walk records each rewritten
-- (tag, method) into memoRefsRef so no dead CAF global is emitted.  The module Ref
-- (reset per hoistNullaryMemo call — lowerProgramEmit is the single caller) keeps the
-- structural walk to one pass without tupling a collector through every CExpr case.
memoRefsRef : Ref (List (String, String))
memoRefsRef = Ref []

-- the (method, SELECTOR) instances that are per-instance CAFs — see the gate above.
-- The selector is the string an RKey occurrence of this instance actually carries:
-- the bare head when this is the SOLE impl at (method, head), else the canonical C7
-- key (TYPECHECK-AUDIT C7).  #731 item 2: two same-head impls (`Foo (MyPair Int
-- Bool)` vs `Foo (MyPair Bool Int)`) share the head `MyPair` but the occurrence route
-- carries the KEY `Foo|(MyPair Int Bool)|`; keying memo on the bare head made
-- `isMemoKey` miss on the collision, so the occurrence was never hoisted and the side
-- effect duplicated on build.  Keying on the same selector the route carries fixes it.
memoKeys : List CImplEntry -> List (String, String)
memoKeys entries = memoKeysGo entries entries

memoKeysGo : List CImplEntry -> List CImplEntry -> List (String, String)
memoKeysGo _ [] = []
memoKeysGo all ((CImplEntry m _ (CImplTagged tag key _ positions pats _))::rest)
  | isEmptyL positions && isEmptyL pats =
    (m, memoSelector all m tag key) :: memoKeysGo all rest
memoKeysGo all (_::rest) = memoKeysGo all rest

-- the string an RKey occurrence of (method, head-tag) carries — bare head when the
-- head is the sole impl of (method, head), else the canonical C7 key.  Mirrors the
-- emitter's implFnSymTag/keyForSite choice (C7), so the CAF and the occurrence agree.
memoSelector : List CImplEntry -> String -> String -> String -> String
memoSelector all method tag key =
  if headTagUniqueL all method tag then
    tag
  else
    key

-- does the head tycon [tag] of [method] have a single impl, or several distinct C7
-- keys (a same-head collision)?  Counts DISTINCT keys, not raw entries (the joint
-- prelude+module list duplicates each prelude impl, and a multi-clause impl
-- contributes several entries sharing one key).  Mirror of llvm_emit.headTagUnique.
headTagUniqueL : List CImplEntry -> String -> String -> Bool
headTagUniqueL entries method tag =
  listLen (distinctKeysAtHeadL entries method tag []) <= 1

distinctKeysAtHeadL : List CImplEntry -> String -> String -> List String -> List String
distinctKeysAtHeadL [] _ _ acc = acc
distinctKeysAtHeadL ((CImplEntry n _ (CImplTagged t k _ _ _ _))::rest) method tag acc
  | n == method && t == tag && not (contains k acc) =
    distinctKeysAtHeadL rest method tag (k::acc)
  | otherwise = distinctKeysAtHeadL rest method tag acc
distinctKeysAtHeadL (_::rest) method tag acc =
  distinctKeysAtHeadL rest method tag acc

isMemoKey : List (String, String) -> String -> String -> Bool
isMemoKey [] _ _ = False
isMemoKey ((m2, t2)::rest) m tag = m == m2 && tag == t2 || isMemoKey rest m tag

-- #731 item 1: the (method, selector) instances whose dispatch is UNAMBIGUOUS by
-- STATIC KNOWLEDGE regardless of route — exactly one tagged impl and no interface
-- default.  Such a nullary method reached through a runtime-dict route (RDict/
-- RDictFwd — a polymorphic caller forwarding a concrete dict) can only ever resolve
-- to that ONE impl, so its per-instance CAF is statically the same one an RKey
-- occurrence would name and is hoistable identically.  A method with ≥2 impls needs
-- the RUNTIME-resolved tag (not statically hoistable) and is left per-call — the
-- residual multi-impl RDict case tracked separately.  Subset of `keys` (already
-- nullary/return-position/no-requires), so it never over-memoises past eval.
soleMemoKeys : List CImplEntry -> List (String, String) -> List (String, String)
soleMemoKeys _ [] = []
soleMemoKeys entries ((m, sel)::rest)
  | taggedImplCount entries m 1 == 1 && not (hasDefaultL entries m) =
    (m, sel) :: soleMemoKeys entries rest
  | otherwise = soleMemoKeys entries rest

-- distinct C7 keys of [method]'s tagged impls (short-circuits at [cap]: this only
-- ever asks "is it exactly 1?", so counting past 2 is wasted work on a big table).
taggedImplCount : List CImplEntry -> String -> Int -> Int
taggedImplCount entries method cap =
  listLen (distinctImplKeysL entries method cap [])

distinctImplKeysL : List CImplEntry -> String -> Int -> List String -> List String
distinctImplKeysL [] _ _ acc = acc
distinctImplKeysL _ _ cap acc
  | listLen acc > cap = acc
distinctImplKeysL ((CImplEntry n _ (CImplTagged _ k _ _ _ _))::rest) method cap acc
  | n == method && not (contains k acc) =
    distinctImplKeysL rest method cap (k::acc)
  | otherwise = distinctImplKeysL rest method cap acc
distinctImplKeysL (_::rest) method cap acc =
  distinctImplKeysL rest method cap acc

hasDefaultL : List CImplEntry -> String -> Bool
hasDefaultL [] _ = False
hasDefaultL ((CImplEntry n _ (CImplDefault _ _))::rest) m = n == m
  || hasDefaultL rest m
hasDefaultL (_::rest) m = hasDefaultL rest m

-- the (method, selector) instances hoistable through a runtime-dict route (item 1),
-- reset per hoistNullaryMemo call.  Read only by the RDict/RDictFwd hoistExpr arm.
soleMemoKeysRef : Ref (List (String, String))
soleMemoKeysRef = Ref []

-- #747: ALL (method, selector) memo keys of the program (nullary/return-position/
-- no-requires impls), computed once in hoistNullaryMemo.  Read by the RDict/RDictFwd
-- MULTI-impl arm of hoistDictNullary to enumerate every impl tag of the method so a
-- `$memo_<selector>_<method>` CAF is synthesized for each.  The occurrence stays a
-- runtime dispatch; the emit backends' dispatch chain forces the matching per-tag CAF
-- (per-runtime-tag memoisation), so each resolved tag's side effect fires once — the
-- same sharing eval's per-VTypedImpl memoThunk gives regardless of route.
allMemoKeysRef : Ref (List (String, String))
allMemoKeysRef = Ref []

-- the synthesized CAF binding name for a memoised (selector, method) instance.  The
-- `$` prefix is the internal-binder convention (cf. composeVar `$cf`), so it cannot
-- collide with a user/prelude binding; it flows verbatim into `@mdk_g_<name>`.  The
-- selector is sanitized (`sanitizeId`, the shared mangling helper): a C7 key carries
-- `|`/`(`/`)`/spaces, none legal in that global symbol.  A bare head tag is
-- alphanumeric so `sanitizeId` is the identity on it — every pre-#731 CAF name (all
-- unique-head) stays byte-identical, keeping the fixpoint fixed.
memoBindName : String -> String -> String
memoBindName selector method = "$memo_\{sanitizeId selector}_\{method}"

recordMemoRef : String -> String -> Unit
recordMemoRef tag method = setRef memoRefsRef ((tag, method)::memoRefsRef.value)

-- #731 item 1 / #747: rewrite a runtime-dict-routed nullary occurrence.
--   • single-impl (soleMemoKeysRef): the runtime dict can only ever resolve to the
--     ONE impl, so hoist the occurrence itself to that shared CAF (statically the
--     same one an RKey occurrence names) — #731 item 1, unchanged.
--   • multi-impl (#747): the resolved tag is only known at runtime, so the occurrence
--     STAYS a dispatch — but synthesize a `$memo_<selector>_<method>` CAF for EVERY
--     impl tag of the method (recordMultiImplMemo).  The emit backends' dispatch chain
--     forces the matching per-tag CAF instead of re-calling the impl fn, so each
--     resolved tag's side effect fires once, shared across routes (matching eval's
--     per-VTypedImpl memoThunk).  Distinct tags carry distinct CAFs → memoise
--     independently.  A method with no nullary/return-position impl records nothing.
hoistDictNullary : String -> Route -> CExpr
hoistDictNullary name route = match lookupAssoc name soleMemoKeysRef.value
  Some sel =>
    let _ = recordMemoRef sel name
    CVar (memoBindName sel name) AGlobal
  None =>
    let _ = recordMultiImplMemo name
    CMethod name route [] []

-- #747: synthesize one per-tag CAF for every nullary/return-position impl of a
-- multi-impl method reached via a runtime-dict route.  Records each (selector, method)
-- into memoRefsRef so hoistNullaryMemo prepends a `$memo_<selector>_<method>` value
-- bind (dedupPairs collapses repeats).  Only fires for methods that appear in the
-- program's memo keys — a nullary occurrence of a NON-memoisable method records
-- nothing, leaving its per-call dispatch untouched.
recordMultiImplMemo : String -> Unit
recordMultiImplMemo name = recordMultiImplMemoGo name allMemoKeysRef.value

recordMultiImplMemoGo : String -> List (String, String) -> Unit
recordMultiImplMemoGo _ [] = ()
recordMultiImplMemoGo name ((m, sel)::rest)
  | m == name =
    let _ = recordMemoRef sel name in recordMultiImplMemoGo name rest
  | otherwise = recordMultiImplMemoGo name rest

-- the whole-program hoist: rewrite every memoisable occurrence to a CAF reference,
-- then prepend one synthesized CAF value-bind per referenced instance.  A no-op (the
-- byte-identical old program) when the program defines no memoisable nullary method.
hoistNullaryMemo : CProgram -> CProgram
hoistNullaryMemo (CProgram groups ctorArs ctorTypes implEntries) =
  let keys = memoKeys implEntries
  if isEmptyL keys then CProgram groups ctorArs ctorTypes implEntries
  else
    let _ = setRef memoRefsRef []
    let _ = setRef soleMemoKeysRef (soleMemoKeys implEntries keys)
    let _ = setRef allMemoKeysRef keys
    let groups2 = map (hoistBind keys) groups
    let impls2 = map (hoistImpl keys) implEntries
    let refs = dedupPairs (reverseL memoRefsRef.value) []
    CProgram (map memoCafBind refs ++ groups2) ctorArs ctorTypes impls2

memoCafBind : (String, String) -> CBind
memoCafBind (tag, method) = CBind
  (memoBindName tag method)
  [CClause [] (CMethod method (RKey tag []) [] [])]

dedupPairs : List (String, String) -> List (String, String) -> List (String, String)
dedupPairs [] _ = []
dedupPairs (p::rest) seen
  | pairMember p seen = dedupPairs rest seen
  | otherwise = p :: dedupPairs rest (p::seen)

pairMember : (String, String) -> List (String, String) -> Bool
pairMember _ [] = False
pairMember (a, b) ((a2, b2)::rest) = a == a2 && b == b2
  || pairMember (a, b) rest

hoistBind : List (String, String) -> CBind -> CBind
hoistBind keys (CBind n clauses) = CBind n (map (hoistClause keys) clauses)

hoistClause : List (String, String) -> CClause -> CClause
hoistClause keys (CClause pats body) = CClause pats (hoistExpr keys body)

hoistImpl : List (String, String) -> CImplEntry -> CImplEntry
hoistImpl keys (CImplEntry n s (CImplTagged tag key iface pos pats body)) =
  CImplEntry n s (CImplTagged tag key iface pos pats (hoistExpr keys body))
hoistImpl keys (CImplEntry n s (CImplDefault pats body)) =
  CImplEntry n s (CImplDefault pats (hoistExpr keys body))

-- the structural walk (mirrors rewriteExprRP), rewriting ONLY the gated CMethod
-- occurrence; everything else recurses unchanged.
hoistExpr : List (String, String) -> CExpr -> CExpr
hoistExpr keys (CMethod name (RKey tag []) [] []) =
  if isMemoKey keys name tag then
    let _ = recordMemoRef tag name
    CVar (memoBindName tag name) AGlobal
  else CMethod name (RKey tag []) [] []
-- #731 item 1: a nullary return-position method reached via a runtime-dict route
-- (RDictFwd from a polymorphic caller forwarding a concrete dict, or a plain RDict)
-- resolves — when the method has exactly one impl and no default — statically to
-- that one impl.  eval memoises it globally per resolved tag (the SAME memoThunk a
-- direct RKey occurrence hits); hoist it to the SAME CAF the RKey path uses so the
-- side effect fires once on build too, shared across routes.  A multi-impl method's
-- tag is only known at runtime, so it stays a per-call dispatch (unchanged).
hoistExpr _ (CMethod name (RDict d) [] []) = hoistDictNullary name (RDict d)
hoistExpr _ (CMethod name (RDictFwd d) [] []) =
  hoistDictNullary name (RDictFwd d)
hoistExpr _ (CMethod name r ir mr) = CMethod name r ir mr
hoistExpr _ (CLit l) = CLit l
hoistExpr _ (CVar x addr) = CVar x addr
hoistExpr keys (CApp f x) = CApp (hoistExpr keys f) (hoistExpr keys x)
hoistExpr keys (CLam pats body) = CLam pats (hoistExpr keys body)
hoistExpr keys (CLet r pat e1 e2) =
  CLet r pat (hoistExpr keys e1) (hoistExpr keys e2)
hoistExpr keys (CLetGroup binds body) =
  CLetGroup (map (hoistBind keys) binds) (hoistExpr keys body)
hoistExpr keys (CMatch scrut arms) =
  CMatch (hoistExpr keys scrut) (map (hoistArm keys) arms)
hoistExpr keys (CDecision scrut arms tree) =
  CDecision (hoistExpr keys scrut) (map (hoistArm keys) arms) tree
hoistExpr keys (CIf c t e) =
  CIf (hoistExpr keys c) (hoistExpr keys t) (hoistExpr keys e)
hoistExpr keys (CBinPrim op l r tag) =
  CBinPrim op (hoistExpr keys l) (hoistExpr keys r) tag
hoistExpr keys (CUnOp op x) = CUnOp op (hoistExpr keys x)
hoistExpr keys (CTuple es) = CTuple (map (hoistExpr keys) es)
hoistExpr keys (CList es) = CList (map (hoistExpr keys) es)
hoistExpr keys (CRecord name fields) =
  CRecord name (map (hoistField keys) fields)
hoistExpr keys (CFieldAccess ex f n) = CFieldAccess (hoistExpr keys ex) f n
hoistExpr keys (CRecordUpdate name base fields) =
  CRecordUpdate name (hoistExpr keys base) (map (hoistField keys) fields)
hoistExpr keys (CVariantUpdate con base fields) =
  CVariantUpdate con (hoistExpr keys base) (map (hoistField keys) fields)
hoistExpr keys (CArray es) = CArray (map (hoistExpr keys) es)
hoistExpr keys (CRangeList lo hi incl) =
  CRangeList (hoistExpr keys lo) (hoistExpr keys hi) incl
hoistExpr keys (CRangeArray lo hi incl) =
  CRangeArray (hoistExpr keys lo) (hoistExpr keys hi) incl
hoistExpr keys (CIndex a i) = CIndex (hoistExpr keys a) (hoistExpr keys i)
hoistExpr keys (CSlice a lo hi incl) =
  CSlice (hoistExpr keys a) (hoistExpr keys lo) (hoistExpr keys hi) incl
hoistExpr keys (CStringIndex a i) =
  CStringIndex (hoistExpr keys a) (hoistExpr keys i)
hoistExpr keys (CStringSlice a lo hi incl) =
  CStringSlice (hoistExpr keys a) (hoistExpr keys lo) (hoistExpr keys hi) incl
hoistExpr keys (CListIndex a i) =
  CListIndex (hoistExpr keys a) (hoistExpr keys i)
hoistExpr keys (CListSlice a lo hi incl) =
  CListSlice (hoistExpr keys a) (hoistExpr keys lo) (hoistExpr keys hi) incl
hoistExpr keys (CBlock stmts) = CBlock (map (hoistStmt keys) stmts)
hoistExpr _ (CDict name rs) = CDict name rs

hoistArm : List (String, String) -> CArm -> CArm
hoistArm keys (CArm pat guards body) =
  CArm pat (map (hoistGuard keys) guards) (hoistExpr keys body)

hoistGuard : List (String, String) -> CGuard -> CGuard
hoistGuard keys (CGBool e) = CGBool (hoistExpr keys e)
hoistGuard keys (CGBind p e) = CGBind p (hoistExpr keys e)

hoistStmt : List (String, String) -> CStmt -> CStmt
hoistStmt keys (CSExpr e) = CSExpr (hoistExpr keys e)
hoistStmt keys (CSLet r pat e) = CSLet r pat (hoistExpr keys e)
hoistStmt keys (CSAssign x e) = CSAssign x (hoistExpr keys e)

hoistField : List (String, String) -> CField -> CField
hoistField keys (CField k e) = CField k (hoistExpr keys e)

-- recompile a CDecision's tree from rewritten arms (same call lowerMatch makes).
compileArmsC : List CArm -> CTree
compileArmsC arms = compileTree (map carmHasGuard arms) (cInitialRows arms 0)

carmHasGuard : CArm -> Bool
carmHasGuard (CArm pat gs _) = isNonEmptyL gs || patNeedsGuard pat

cInitialRows : List CArm -> Int -> List (List Pat, Int)
cInitialRows [] _ = []
cInitialRows ((CArm pat _ _)::rest) i =
  ([canonPat pat], i) :: cInitialRows rest (i + 1)

-- the top-level function-group half of lowerProgram, exposed for the multi-module
-- driver (core_ir_eval.cevalModules), which lowers each module's groups separately
-- (per-module local frames) rather than as one flat program.
export lowerGroups : List Decl -> List CBind
lowerGroups prog = lgGroup (funClausesOf prog)

-- O(n log n) group-by-name, IDENTICAL output to
-- `map (n => CBind n (clausesFor n clauses)) (groupNames clauses [])`: preserves
-- clause order within a name AND first-occurrence order of names, via an
-- index-carrying merge sort (no map, no typeclass dispatch). Replaces the old
-- O(names·clauses) groupNames+clausesFor rescan. Elements are ((name, idx), clause).
lgGroup : List (String, CClause) -> List CBind
lgGroup clauses =
  let groups = lgRuns (lgSortName (lgTag clauses 0))
  map lgToBind (lgSortIdx groups)

lgTag : List (String, CClause) -> Int -> List ((String, Int), CClause)
lgTag [] _ = []
lgTag ((n, c)::rest) i = ((n, i), c) :: lgTag rest (i + 1)

lgSplit : List a -> (List a, List a)
lgSplit [] = ([], [])
lgSplit [x] = ([x], [])
lgSplit (x::y::rest) =
  let (a, b) = lgSplit rest
  (x::a, y::b)

-- merge sort by name, ascending-index tiebreak (stable ⇒ clause order preserved).
lgSortName : List ((String, Int), CClause) -> List ((String, Int), CClause)
lgSortName [] = []
lgSortName [x] = [x]
lgSortName xs =
  let (a, b) = lgSplit xs
  lgMergeName (lgSortName a) (lgSortName b)

lgMergeName : List ((String, Int), CClause) -> List ((String, Int), CClause) -> List ((String, Int), CClause)
lgMergeName [] ys = ys
lgMergeName xs [] = xs
lgMergeName (((n1, i1), c1)::xs) (((n2, i2), c2)::ys) = match stringCompare n1 n2
  Lt => ((n1, i1), c1) :: lgMergeName xs (((n2, i2), c2)::ys)
  Gt => ((n2, i2), c2) :: lgMergeName (((n1, i1), c1)::xs) ys
  Eq =>
    if i1 <= i2 then
      ((n1, i1), c1) :: lgMergeName xs (((n2, i2), c2)::ys)
    else
      ((n2, i2), c2) :: lgMergeName (((n1, i1), c1)::xs) ys

-- collapse runs of equal name (now contiguous, index-ascending) into
-- ((name, firstIdx), clausesInOrder).
lgRuns : List ((String, Int), CClause) -> List ((String, Int), List CClause)
lgRuns [] = []
lgRuns (((n, i), c)::rest) =
  let (cs, others) = lgSpan n rest
  ((n, i), c::cs) :: lgRuns others

lgSpan : String -> List ((String, Int), CClause) -> (List CClause, List ((String, Int), CClause))
lgSpan _ [] = ([], [])
lgSpan n (((m, j), c)::rest) =
  if m == n then
    let (cs, o) = lgSpan n rest
    (c::cs, o)
  else ([], ((m, j), c)::rest)

-- order groups by first-occurrence index (== groupNames order).
lgSortIdx : List ((String, Int), List CClause) -> List ((String, Int), List CClause)
lgSortIdx [] = []
lgSortIdx [x] = [x]
lgSortIdx xs =
  let (a, b) = lgSplit xs
  lgMergeIdx (lgSortIdx a) (lgSortIdx b)

lgMergeIdx : List ((String, Int), List CClause) -> List ((String, Int), List CClause) -> List ((String, Int), List CClause)
lgMergeIdx [] ys = ys
lgMergeIdx xs [] = xs
lgMergeIdx (((n1, i1), cs1)::xs) (((n2, i2), cs2)::ys) =
  if i1 <= i2 then
    ((n1, i1), cs1) :: lgMergeIdx xs (((n2, i2), cs2)::ys)
  else
    ((n2, i2), cs2) :: lgMergeIdx (((n1, i1), cs1)::xs) ys

lgToBind : ((String, Int), List CClause) -> CBind
lgToBind ((n, _), cs) = CBind n cs

-- ── typeclass impls / interface defaults (slice 5) ─────────────────────────
-- Mirror eval.mdk's `declImplEntries` exactly: build the iface dispatch-position
-- table once, then emit one CImplEntry per impl-method clause (tagged by the
-- impl's concrete type head) and per interface default (untagged fallback).  The
-- method BODY is lowered to CExpr; the tag / positions / score are pure AST
-- computations reused from eval.mdk so the Core IR stays Ty-free.
-- #315/#413: installDispatchTables both BUILDS the dispatch table (as
-- buildIfaceDispatch did) and installs it alongside the method reqCount table that
-- applyMethodDicts consults.  cevalProgram is handed a CProgram and so has no decls
-- of its own to derive them from; lowering is the last point that still does.
-- Without this the Core-IR interpreter's reqCount lookups all returned None and
-- #413's fix was inert there (proven: `impl S (List a) requires S a where s _ = 2`
-- ran correctly under `medaka run` but panicked "applied non-function: 2" under
-- core_ir_typed_main).  The emit path lowers through here too and never reads the
-- tables, so installing is a no-op for it.
lowerImpls : List Decl -> List CImplEntry
lowerImpls prog = lowerImplsWith (installDispatchTables prog) prog

-- lowerImpls against a PRE-BUILT dispatch table — the multi-module driver builds
-- one `disp` from all modules' decls jointly (an impl in module B for an interface
-- in the prelude needs the prelude's dispatch positions), then lowers each
-- module's impls against it.
export lowerImplsWith : List ((String, String), List Int) -> List Decl -> List CImplEntry
lowerImplsWith disp prog = flatMap (lowerDeclImpl disp) prog

lowerDeclImpl : List ((String, String), List Int) -> Decl -> List CImplEntry
lowerDeclImpl disp (DImpl { iface = ifaceName, tys = typeArgs, methods, ... }) = map (lowerImplMethod disp ifaceName typeArgs) methods
lowerDeclImpl _ (DInterface { typarams = typeParams, methods, ... }) =
  flatMap (lowerDefault typeParams) methods
lowerDeclImpl _ _ = []

lowerImplMethod : List ((String, String), List Int) -> String -> List Ty -> ImplMethod -> CImplEntry
lowerImplMethod disp ifaceName typeArgs (ImplMethod mname pats body) =
  let tag = fromOption noneHeadTag (headTyconHead typeArgs)
  let key = implKeyOf ifaceName typeArgs None
  let positions = lookupPositions ifaceName mname disp
  CImplEntry
    mname
    (tyvarsInArgs typeArgs)
    (CImplTagged tag key ifaceName positions pats (lower body))

lowerDefault : List String -> IfaceMethod -> List CImplEntry
lowerDefault _ (IfaceMethod _ _ None) = []
lowerDefault typeParams (IfaceMethod mname _ (Some (MethodDefault pats body))) = [CImplEntry mname (listLen typeParams) (CImplDefault pats (lower body))]

-- ── returns-self table (native backend: method-call RESULT-type inference) ───
-- Per (interface, method): does the method's RESULT type mention an interface
-- type parameter?  This is the result-side analogue of `dispatchPositionsOf`'s
-- per-arg `tyMentions` (eval.mdk) — True for a container method whose result is
-- the self/container type (`map`/`ap`/`andThen` at a container impl all return
-- the container), False for a method returning a scalar/element/concrete type
-- (`compare : a -> a -> Ordering`).  The LLVM emitter reads it to statically type
-- a method-call result: a `returnsSelf` method dispatched (RKey) at type `T`
-- yields `tagToLTy T`, so a downstream `++`/`::` on that result picks the right
-- list/string instruction instead of falling to the `LTInt` default (the last
-- EMITTER-GAPS.md #3 residual: `ap@List` / `andThen@List`, whose `++` operand is
-- a CALL result like `map f xs` / `f x`, not a param).
export returnsSelfTable : List Decl -> List ((String, String), Bool)
returnsSelfTable prog = flatMap ifaceReturnsSelfEntries prog

ifaceReturnsSelfEntries : Decl -> List ((String, String), Bool)
ifaceReturnsSelfEntries (DInterface { name = ifaceName, typarams = typeParams, methods, ... }) = map (m => ifaceReturnsSelfEntry ifaceName typeParams m) methods
ifaceReturnsSelfEntries _ = []

ifaceReturnsSelfEntry : String -> List String -> IfaceMethod -> ((String, String), Bool)
ifaceReturnsSelfEntry ifaceName typeParams (IfaceMethod mname mty _) = (
  (ifaceName, mname),
  tyMentionsParams (methodResultTy mty) (headParamOnly typeParams),
)

-- Only the HEAD (first) interface type parameter — the one whose concrete
-- instantiation names the impl's dispatch/head tag (`headTyconHead typeArgs`
-- takes typeArgs[0]).  A method's result is the self/container type ONLY when it
-- mentions THIS param; the emitter then types the RKey result as `tagToLTy
-- headTag`.  A multi-param interface (`Ix c v`) whose result mentions a NON-head
-- param (`v`, the element) is NOT self-returning: typing its Char/element result
-- as `tagToLTy headTag` (e.g. LTStr for `impl Ix String Char`) would route a
-- downstream `==` through @mdk_string_eq, dereferencing a Char immediate as a
-- String pointer → SIGSEGV.  (Previously ALL typeParams were checked, mis-marking
-- `ix` self-returning and mis-typing its array-slot Char result.)
headParamOnly : List String -> List String
headParamOnly [] = []
headParamOnly (p::_) = [p]

-- the RESULT type of a method type: the final tail after stripping the TyFun
-- argument chain (and any leading constraint/effect wrappers).
methodResultTy : Ty -> Ty
methodResultTy (TyConstrained _ t) = methodResultTy t
methodResultTy (TyEffect _ _ t) = methodResultTy t
methodResultTy (TyFun _ b) = methodResultTy b
methodResultTy t = t

-- does a type mention one of the given interface type-parameter names? (the
-- result-side twin of eval.mdk's non-exported `tyMentions`).
tyMentionsParams : Ty -> List String -> Bool
tyMentionsParams (TyVar n) params = contains n params
tyMentionsParams (TyCon _ _) _ = False
tyMentionsParams (TyApp a b) params = tyMentionsParams a params
  || tyMentionsParams b params
tyMentionsParams (TyFun a b) params = tyMentionsParams a params
  || tyMentionsParams b params
tyMentionsParams (TyTuple ts) params =
  anyList (t => tyMentionsParams t params) ts
tyMentionsParams (TyEffect _ _ t) params = tyMentionsParams t params
tyMentionsParams (TyConstrained _ t) params = tyMentionsParams t params

-- ── self-returning function-PARAM table (native backend) ────────────────────
-- Per (interface, method): the ARGUMENT positions whose type is a FUNCTION whose
-- RESULT mentions the interface/self type variable — i.e. a callback that yields
-- the container.  e.g. `andThen : m a -> (a -> m b) -> m b` has param 1 of type
-- `a -> m b`, a function returning self.  The emitter types the APPLICATION of
-- such a param (`f x`) as the container (`tagToLTy tag`), closing `andThen@List`
-- where the `++` LEFT operand `f x` is an indirect call the method-call
-- inference (returnsSelfTable) cannot reach.  Result-side analogue scoped to
-- function-typed params, not the whole-method result.
export selfFnParamTable : List Decl -> List ((String, String), List Int)
selfFnParamTable prog = flatMap ifaceSelfFnParamEntries prog

ifaceSelfFnParamEntries : Decl -> List ((String, String), List Int)
ifaceSelfFnParamEntries (DInterface { name = ifaceName, typarams = typeParams, methods, ... }) = map (m => ifaceSelfFnParamEntry ifaceName typeParams m) methods
ifaceSelfFnParamEntries _ = []

ifaceSelfFnParamEntry : String -> List String -> IfaceMethod -> ((String, String), List Int)
ifaceSelfFnParamEntry ifaceName typeParams (IfaceMethod mname mty _) =
  ((ifaceName, mname), selfFnPositions 0 (methodArgTys mty) typeParams)

-- the argument types of a method type (the a's of `a -> a -> … -> r`).
methodArgTys : Ty -> List Ty
methodArgTys (TyConstrained _ t) = methodArgTys t
methodArgTys (TyEffect _ _ t) = methodArgTys t
methodArgTys (TyFun a b) = a :: methodArgTys b
methodArgTys _ = []

-- ── method → (interface, full-arity) table (native backend: default methods) ─
-- Per interface method name: the interface it belongs to and its full argument
-- arity (from the declared signature `a -> b -> … -> r`).  The LLVM emitter reads
-- it to emit an interface DEFAULT method (a `CImplDefault` body the type's `impl`
-- did not override): the arity drives eta-expansion of a point-free default
-- (`filter p = filterMap …` is arity-1 point-free but the method is arity-2), and
-- the interface name lets the emitter recognise inner SAME-interface method calls
-- in the default body and re-stamp them to the concrete dispatch tag (so the
-- partially-applied inner `filterMap` lowers to a direct `@mdk_impl_<tag>_filterMap`
-- call instead of an un-dispatchable arg-tag fallback).  Keyed by BARE method name
-- (interface method names are distinct across the prelude's interfaces).
export methodIfaceTable : List Decl -> List (String, (String, Int))
methodIfaceTable prog = flatMap ifaceMethodArityEntries prog

ifaceMethodArityEntries : Decl -> List (String, (String, Int))
ifaceMethodArityEntries (DInterface { name = ifaceName, methods, ... }) =
  map (m => ifaceMethodArityEntry ifaceName m) methods
ifaceMethodArityEntries _ = []

ifaceMethodArityEntry : String -> IfaceMethod -> (String, (String, Int))
ifaceMethodArityEntry ifaceName (IfaceMethod mname mty _) =
  (mname, (ifaceName, listLen (methodArgTys mty)))

-- ── method → method-level constraint INTERFACE names (native backend, G7) ────
-- Per interface method that carries a method-level `=>` constraint (foldMap's
-- `Monoid m =>`): the interface name of each such constraint, IN SLOT ORDER —
-- the SAME order typecheck's `methodConstraintSlotIds`/`resolveMethodDicts` fill
-- the method occurrence's `methRoutes` list.  This lets the default-body emitter
-- map a cross-interface method (e.g. the `empty` in foldMap's default, a Monoid
-- method whose dict is threaded per-call by the RESULT type, not the container)
-- to the threaded method-dict PARAM and dispatch it at run time — so one shared
-- `@mdk_default_foldMap_List` serves both a List-monoid and a String-monoid fold.
-- A constraint over ONLY interface params contributes no slot (it dispatches via
-- the impl, not a per-call dict); mirrors typecheck's `constraintIsMethodLevel`.
export methodConstraintIfaces : List Decl -> List (String, List String)
methodConstraintIfaces prog = flatMap methodConstraintIfaceEntries prog

methodConstraintIfaceEntries : Decl -> List (String, List String)
methodConstraintIfaceEntries (DInterface { typarams, methods, ... }) =
  flatMap (m => methodConstraintIfaceEntry typarams m) methods
methodConstraintIfaceEntries _ = []

methodConstraintIfaceEntry : List String -> IfaceMethod -> List (String, List String)
methodConstraintIfaceEntry typarams (IfaceMethod mname mty _) =
  let ifaces = methodLevelConstraintIfaces typarams mty
  if isEmptyL ifaces then [] else [(mname, ifaces)]

-- the interface name of each method-level constraint in [ty], in declaration
-- order (peels TyConstrained/TyEffect like methodConstraintSlotIds).
methodLevelConstraintIfaces : List String -> Ty -> List String
methodLevelConstraintIfaces typarams (TyConstrained cs t) = flatMap (c => constraintIfaceIfMethodLevel typarams c) cs
  ++ methodLevelConstraintIfaces typarams t
methodLevelConstraintIfaces typarams (TyEffect _ _ t) =
  methodLevelConstraintIfaces typarams t
methodLevelConstraintIfaces _ _ = []

constraintIfaceIfMethodLevel : List String -> Constraint -> List String
constraintIfaceIfMethodLevel typarams (Constraint ifaceName args)
  | constraintArgsMentionNonParam typarams args = [ifaceName]
  | otherwise = []

-- a constraint is method-level iff one of its argument types mentions a tyvar
-- that is NOT an interface param (so the dict is supplied per-call).
constraintArgsMentionNonParam : List String -> List Ty -> Bool
constraintArgsMentionNonParam typarams args =
  anyList (t => tyMentionsNonParam t typarams) args

tyMentionsNonParam : Ty -> List String -> Bool
tyMentionsNonParam (TyVar n) params = not (contains n params)
tyMentionsNonParam (TyCon _ _) _ = False
tyMentionsNonParam (TyApp a b) params = tyMentionsNonParam a params
  || tyMentionsNonParam b params
tyMentionsNonParam (TyFun a b) params = tyMentionsNonParam a params
  || tyMentionsNonParam b params
tyMentionsNonParam (TyTuple ts) params =
  anyList (t => tyMentionsNonParam t params) ts
tyMentionsNonParam (TyEffect _ _ t) params = tyMentionsNonParam t params
tyMentionsNonParam (TyConstrained _ t) params = tyMentionsNonParam t params

-- ── constructor → DECLARED field type-head names (native backend, Gap E2) ────
-- Per data-constructor name: the head type-name of each declared field, IN
-- DECLARED ORDER (e.g. `Rect Float Float` → ("Rect", ["Float","Float"])).  The
-- LLVM emitter (`bindFields`) reads it to type a match-bound field VARIABLE from
-- the ctor's declared field type rather than guessing from body-use (`paramUseTy`,
-- which defaults Float fields to LTInt → integer arith on a boxed-Float word →
-- SIGSEGV; Gap E2).  A field whose type is not a simple type-constructor head
-- (polymorphic `TyVar`, applied/function/tuple types) maps to "" — the emitter
-- treats "" / unknown-scalar names as "fall back to paramUseTy/LTInt", so the
-- change is ADDITIVE: only fields with a known scalar head (Float/Bool/Int/…)
-- change typing.  Both positional (`ConPos`) and named-field (`ConNamed`)
-- payloads are covered, in the same DECLARED order the cell layout stores.
export ctorFieldTypeNames : List Decl -> List (String, List String)
ctorFieldTypeNames prog = flatMap ctorFieldTypeEntries prog

ctorFieldTypeEntries : Decl -> List (String, List String)
ctorFieldTypeEntries (DData _ _ _ variants _) =
  map variantFieldTypeEntry variants
ctorFieldTypeEntries (DNewtype _ _ _ con fieldTy _) =
  [(con, [tyHeadName fieldTy])]
ctorFieldTypeEntries _ = []

variantFieldTypeEntry : Variant -> (String, List String)
variantFieldTypeEntry (Variant name (ConPos tys)) = (name, map tyHeadName tys)
variantFieldTypeEntry (Variant name (ConNamed fields _)) =
  (name, map fieldTyHeadName fields)

fieldTyHeadName : Field -> String
fieldTyHeadName (Field _ ty) = tyHeadName ty

-- the head type-CONSTRUCTOR name of a field type, or "" if it has no simple head
-- (TyVar / TyFun / TyTuple / applied types) — the emitter treats "" as "unknown".
tyHeadName : Ty -> String
tyHeadName (TyCon n _) = n
-- G3: a type VARIABLE head (`a` in `Num a => a -> a`) yields its var name, so the
-- emitter's declSig table can recognise a polymorphic Num param (isTypeVarName) and
-- route its arithmetic through the runtime tag-dispatched @mdk_num_* helpers.
-- ADDITIVE for every other consumer: a var name (lowercase) is not a known scalar,
-- so `fieldNameToLTy` maps it to None exactly as the old "" did (ctor-field /
-- record-field LTy seeding is unchanged); only the new G3 check reads the name.
tyHeadName (TyVar n) = n
tyHeadName (TyApp a _) = tyHeadName a
tyHeadName (TyConstrained _ t) = tyHeadName t
tyHeadName (TyEffect _ _ t) = tyHeadName t
tyHeadName _ = ""

-- ── function → DECLARED param/return type-head names (native backend, Gap E1) ─
-- Per top-level function name (from its `DTypeSig` annotation): the head
-- type-name of each declared PARAMETER (in order) plus the declared RETURN type
-- head, e.g. `double : Float -> Float` → ("double", (["Float"], "Float")).  The
-- LLVM emitter's signature inference (`inferSigs`/`inferParamTys`/`paramUseTy`)
-- otherwise recovers param/return LTys purely from BODY USE; a literal-free
-- annotated body like `double x = x + x` has no Float anchor → param defaults
-- LTInt → integer arith on a boxed-Float word → garbage (Gap E1).  Seeding the
-- DECLARED scalar type wins over the body-use guess.  A non-scalar head (TyVar /
-- applied / function / tuple) maps to "" and the emitter falls back to the
-- existing guess, so the seed is ADDITIVE: only known-scalar declared params/
-- returns change typing (and `Int`-annotated fns seed LTInt = current default).
export declSigTypeNames : List Decl -> List (String, (List String, String))
declSigTypeNames prog = flatMap declSigTypeEntries prog

declSigTypeEntries : Decl -> List (String, (List String, String))
declSigTypeEntries (DTypeSig _ name ty) =
  [(name, (map tyHeadName (methodArgTys ty), tyHeadName (methodRetTy ty)))]
declSigTypeEntries (DExtern _ name ty) =
  [(name, (map tyHeadName (methodArgTys ty), tyHeadName (methodRetTy ty)))]
declSigTypeEntries (DAttrib _ inner) = declSigTypeEntries inner
declSigTypeEntries _ = []

-- the RESULT type of a (possibly-constrained, possibly-effectful) function type
-- (the `r` of `a -> b -> … -> r`); a non-function type is its own result.
methodRetTy : Ty -> Ty
methodRetTy (TyConstrained _ t) = methodRetTy t
methodRetTy (TyEffect _ _ t) = methodRetTy t
methodRetTy (TyFun _ b) = methodRetTy b
methodRetTy t = t

-- positions (0-based) whose type is a TyFun whose result mentions a param.
selfFnPositions : Int -> List Ty -> List String -> List Int
selfFnPositions _ [] _ = []
selfFnPositions i (t::ts) params
  | tyIsFunReturningSelf t params = i :: selfFnPositions (i + 1) ts params
  | otherwise = selfFnPositions (i + 1) ts params

tyIsFunReturningSelf : Ty -> List String -> Bool
tyIsFunReturningSelf (TyFun _ b) params =
  tyMentionsParams (methodResultTy b) params
tyIsFunReturningSelf (TyConstrained _ t) params = tyIsFunReturningSelf t params
tyIsFunReturningSelf (TyEffect _ _ t) params = tyIsFunReturningSelf t params
tyIsFunReturningSelf _ _ = False

funClausesOf : List Decl -> List (String, CClause)
funClausesOf [] = []
funClausesOf ((DFunDef _ n pats body)::rest) =
  (n, CClause pats (lower body)) :: funClausesOf rest
-- Top-level `let rec … with …` (DLetGroup): flatten each binding's clauses
-- into (name, CClause) entries, mirroring eval.mdk's funDefs/letGroupDefs.
funClausesOf ((DLetGroup _ binds)::rest) = letGroupClausesOf binds
  ++ funClausesOf rest
funClausesOf ((DAttrib _ d)::rest) = funClausesOf (d::rest)
funClausesOf (_::rest) = funClausesOf rest

letGroupClausesOf : List LetBind -> List (String, CClause)
letGroupClausesOf [] = []
letGroupClausesOf ((LetBind n clauses)::rest) = map (lowerLetBind n) clauses
  ++ letGroupClausesOf rest

lowerLetBind : String -> FunClause -> (String, CClause)
lowerLetBind n (FunClause pats body) = (n, CClause pats (lower body))

ctorArities : List Decl -> List (String, Int)
ctorArities [] = []
ctorArities ((DData _ _ _ variants _)::rest) = map variantArity variants
  ++ ctorArities rest
-- A newtype is structurally a single-constructor, single-field data type, so its
-- constructor is a callable arity-1 ctor (matches the oracle's `make_ctor con 1`).
-- Without this the emitter sees `UserId 42` as an unbound variable.
ctorArities ((DNewtype _ _ _ con _ _)::rest) = (con, 1) :: ctorArities rest
ctorArities (_::rest) = ctorArities rest

variantArity : Variant -> (String, Int)
variantArity (Variant n payload) = (n, payloadArityL payload)

payloadArityL : ConPayload -> Int
payloadArityL (ConPos tys) = listLen tys
payloadArityL (ConNamed fs _) = listLen fs

-- a readable tag for the unsupported-node panic
nodeTag : Expr -> String
nodeTag (ESection _) = "ESection"
nodeTag (EGuards _) = "EGuards"
nodeTag (EDo _) = "EDo"
nodeTag (EStringInterp _) = "EStringInterp"
nodeTag (EVariantUpdate _ _ _) = "EVariantUpdate"
nodeTag (EMapLit _ _) = "EMapLit"
nodeTag (ESetLit _ _) = "ESetLit"
nodeTag (EAsPat _ _) = "EAsPat"
nodeTag (EMethodRef _) = "EMethodRef"
nodeTag (EDictApp _) = "EDictApp"
nodeTag _ = "?"
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Loc" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Expr" true) (mem "Arm" true) (mem "Guard" true) (mem "DoStmt" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "Addr" true) (mem "Decl" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "Ty" true) (mem "Constraint" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "ImplMethod" true) (mem "Route" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CProgram" true) (mem "CTree" true) (mem "CTBranch" true) (mem "CHead" true))))
(DUse false (UseGroup ("eval" "eval") ((mem "buildCtorToType" false) (mem "buildCtorFieldOrders" false) (mem "ctorFieldOrdersRef" false) (mem "installDispatchTables" false) (mem "lookupPositions" false) (mem "tyvarsInArgs" false) (mem "headTyconHead" false) (mem "implKeyOf" false))))
(DUse false (UseGroup ("list") ((mem "replicate" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("backend" "private_mangle") ((mem "sanitizeId" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "allList" false) (mem "anyList" false) (mem "lookupAssoc" false) (mem "noneHeadTag" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "reverseL" false) (mem "startsWith" false))))
(DTypeSig false "composeVar" (TyCon "String"))
(DFunDef false "composeVar" () (ELit (LString "$cf")))
(DTypeSig true "lower" (TyFun (TyCon "Expr") (TyCon "CExpr")))
(DFunDef false "lower" ((PCon "ELit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "lower" ((PCon "ENumLit" (PVar "n") (PVar "r") PWild PWild)) (EMatch (EFieldAccess (EVar "r") "value") (arm (PCon "Some" (PVar "f")) () (EApp (EVar "CLit") (EApp (EVar "LFloat") (EVar "f")))) (arm (PCon "None") () (EApp (EVar "CLit") (EApp (EVar "LInt") (EVar "n"))))))
(DFunDef false "lower" ((PCon "EVar" (PVar "x"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "AGlobal")))
(DFunDef false "lower" ((PCon "EVarId" (PVar "x") PWild)) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "AGlobal")))
(DFunDef false "lower" ((PCon "EVarAt" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "lower" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EVar "lower") (EVar "f"))) (EApp (EVar "lower") (EVar "x"))))
(DFunDef false "lower" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EVar "lower") (EVar "body"))))
(DFunDef false "lower" ((PCon "ELet" PWild (PVar "recFlag") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "recFlag")) (EVar "pat")) (EApp (EVar "lower") (EVar "e1"))) (EApp (EVar "lower") (EVar "e2"))))
(DFunDef false "lower" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EVar "map") (EVar "lowerBind")) (EVar "binds"))) (EApp (EVar "lower") (EVar "body"))))
(DFunDef false "lower" ((PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "lowerMatch") (EApp (EVar "lower") (EVar "scrut"))) (EVar "arms")))
(DFunDef false "lower" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "lower") (EVar "c"))) (EApp (EVar "lower") (EVar "t"))) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lower" ((PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "route"))) (EApp (EApp (EApp (EApp (EVar "lowerBinop") (EVar "op")) (EVar "l")) (EVar "r")) (EApp (EVar "scalarTagOfRoute") (EFieldAccess (EVar "route") "value"))))
(DFunDef false "lower" ((PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "CVar") (EVar "op")) (EVar "AGlobal"))) (EApp (EVar "lower") (EVar "l")))) (EApp (EVar "lower") (EVar "r"))))
(DFunDef false "lower" ((PCon "EUnOp" (PVar "op") (PVar "e") PWild)) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lower" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EVar "map") (EVar "lower")) (EVar "es"))))
(DFunDef false "lower" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EVar "map") (EVar "lower")) (EVar "es"))))
(DFunDef false "lower" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EVar "map") (EVar "lower")) (EVar "es"))))
(DFunDef false "lower" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")))
(DFunDef false "lower" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")))
(DFunDef false "lower" ((PCon "EIndex" (PVar "a") (PVar "i") (PVar "r"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "value") (ELit (LString "String"))) (EApp (EApp (EVar "CStringIndex") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "i"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "value") (ELit (LString "List"))) (EApp (EApp (EVar "CListIndex") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "i"))))))
(DFunDef false "lower" ((PCon "ESlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl") (PVar "r"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "value") (ELit (LString "String"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "value") (ELit (LString "List"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")))))
(DFunDef false "lower" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EVar "lower") (EVar "e"))) (EVar "f")) (EFieldAccess (EVar "r") "value")))
(DFunDef false "lower" ((PCon "ERecordCreate" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EVar "map") (EVar "lowerField")) (EVar "fields"))))
(DFunDef false "lower" ((PCon "ERecordUpdate" (PVar "base") (PVar "fields") (PVar "r"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EFieldAccess (EVar "r") "value")) (EApp (EVar "lower") (EVar "base"))) (EApp (EApp (EVar "map") (EVar "lowerField")) (EVar "fields"))))
(DFunDef false "lower" ((PCon "EVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EVar "lower") (EVar "base"))) (EApp (EApp (EVar "map") (EVar "lowerField")) (EVar "fields"))))
(DFunDef false "lower" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EVar "map") (EVar "lowerStmt")) (EVar "stmts"))))
(DFunDef false "lower" ((PCon "EAnnot" (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") PWild) (PCon "TyCon" (PVar "tag") PWild))) (EApp (EApp (EApp (EApp (EVar "lowerBinop") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "tag")))
(DFunDef false "lower" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PCon "EMethodAt" (PVar "name") (PVar "routeRef") (PVar "implRef") (PVar "methodRef"))) (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EFieldAccess (EVar "routeRef") "value")) (EFieldAccess (EVar "implRef") "value")) (EFieldAccess (EVar "methodRef") "value")))
(DFunDef false "lower" ((PCon "EDictAt" (PVar "name") (PVar "routesRef"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EFieldAccess (EVar "routesRef") "value")))
(DFunDef false "lower" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir lower: unsupported node ")) (EApp (EVar "nodeTag") (EVar "other")))))
(DTypeSig false "scalarTagOfRoute" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "scalarTagOfRoute" ((PCon "RScalar" (PVar "s"))) (EVar "s"))
(DFunDef false "scalarTagOfRoute" (PWild) (ELit (LString "")))
(DTypeSig false "lowerBinop" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyCon "CExpr"))))))
(DFunDef false "lowerBinop" ((PLit (LString "&&")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "lower") (EVar "r"))) (EApp (EVar "CLit") (EApp (EVar "LBool") (EVar "False")))))
(DFunDef false "lowerBinop" ((PLit (LString "||")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "CLit") (EApp (EVar "LBool") (EVar "True")))) (EApp (EVar "lower") (EVar "r"))))
(DFunDef false "lowerBinop" ((PLit (LString "|>")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EVar "CApp") (EApp (EVar "lower") (EVar "r"))) (EApp (EVar "lower") (EVar "l"))))
(DFunDef false "lowerBinop" ((PLit (LString ">>")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EVar "composeLam") (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "lower") (EVar "r"))))
(DFunDef false "lowerBinop" ((PLit (LString "<<")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EVar "composeLam") (EApp (EVar "lower") (EVar "r"))) (EApp (EVar "lower") (EVar "l"))))
(DFunDef false "lowerBinop" ((PVar "op") (PVar "l") (PVar "r") (PVar "tag")) (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "lower") (EVar "r"))) (EVar "tag")))
(DTypeSig false "composeLam" (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "composeLam" ((PVar "first") (PVar "second")) (EApp (EApp (EVar "CLam") (EListLit (EApp (EApp (EVar "PVar") (EVar "composeVar")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))) (EApp (EApp (EVar "CApp") (EVar "second")) (EApp (EApp (EVar "CApp") (EVar "first")) (EApp (EApp (EVar "CVar") (EVar "composeVar")) (EVar "AGlobal"))))))
(DTypeSig false "lowerArm" (TyFun (TyCon "Arm") (TyCon "CArm")))
(DFunDef false "lowerArm" ((PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EApp (EApp (EVar "map") (EVar "lowerGuard")) (EVar "guards"))) (EApp (EVar "lower") (EVar "body"))))
(DTypeSig false "lowerGuard" (TyFun (TyCon "Guard") (TyCon "CGuard")))
(DFunDef false "lowerGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EVar "lower") (EVar "e"))))
(DTypeSig false "lowerMatch" (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "CExpr"))))
(DFunDef false "lowerMatch" ((PVar "cscrut") (PVar "arms")) (EIf (EApp (EApp (EVar "allList") (EVar "armTreeable")) (EVar "arms")) (EApp (EApp (EApp (EVar "CDecision") (EVar "cscrut")) (EApp (EApp (EVar "map") (EVar "lowerArm")) (EVar "arms"))) (EApp (EVar "compileArms") (EVar "arms"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "CMatch") (EVar "cscrut")) (EApp (EApp (EVar "map") (EVar "lowerArm")) (EVar "arms"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "armTreeable" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armTreeable" ((PCon "Arm" (PVar "pat") PWild PWild)) (EApp (EVar "treeablePat") (EVar "pat")))
(DTypeSig false "treeablePat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "treeablePat" ((PCon "PWild")) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PVar" PWild PWild)) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PLit" PWild)) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PCon" PWild (PVar "args"))) (EApp (EApp (EVar "allList") (EVar "treeablePat")) (EVar "args")))
(DFunDef false "treeablePat" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "&&" (EApp (EVar "treeablePat") (EVar "h")) (EApp (EVar "treeablePat") (EVar "t"))))
(DFunDef false "treeablePat" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "allList") (EVar "treeablePat")) (EVar "ps")))
(DFunDef false "treeablePat" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EVar "treeablePat")) (EVar "ps")))
(DFunDef false "treeablePat" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "treeablePat") (EVar "p")))
(DFunDef false "treeablePat" ((PCon "PRng" PWild PWild PWild)) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PRec" PWild PWild PWild)) (EVar "True"))
(DTypeSig false "compileArms" (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "CTree")))
(DFunDef false "compileArms" ((PVar "arms")) (EApp (EApp (EVar "compileTree") (EApp (EApp (EVar "map") (EVar "armHasGuard")) (EVar "arms"))) (EApp (EApp (EVar "initialRows") (EVar "arms")) (ELit (LInt 0)))))
(DTypeSig false "armHasGuard" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armHasGuard" ((PCon "Arm" (PVar "pat") (PVar "gs") PWild)) (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "gs")) (EApp (EVar "patNeedsGuard") (EVar "pat"))))
(DTypeSig false "patNeedsGuard" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patNeedsGuard" ((PCon "PRng" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patNeedsGuard" ((PCon "PRec" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patNeedsGuard" ((PCon "PCon" PWild (PVar "args"))) (EApp (EApp (EVar "anyList") (EVar "patNeedsGuard")) (EVar "args")))
(DFunDef false "patNeedsGuard" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "||" (EApp (EVar "patNeedsGuard") (EVar "h")) (EApp (EVar "patNeedsGuard") (EVar "t"))))
(DFunDef false "patNeedsGuard" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EVar "patNeedsGuard")) (EVar "ps")))
(DFunDef false "patNeedsGuard" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EVar "patNeedsGuard")) (EVar "ps")))
(DFunDef false "patNeedsGuard" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "patNeedsGuard") (EVar "p")))
(DFunDef false "patNeedsGuard" (PWild) (EVar "False"))
(DTypeSig false "initialRows" (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "initialRows" ((PList) PWild) (EListLit))
(DFunDef false "initialRows" ((PCons (PCon "Arm" (PVar "pat") PWild PWild) (PVar "rest")) (PVar "i")) (EBinOp "::" (ETuple (EListLit (EApp (EVar "canonPat") (EVar "pat"))) (EVar "i")) (EApp (EApp (EVar "initialRows") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "compileTree" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))
(DFunDef false "compileTree" (PWild (PList)) (EVar "CTFail"))
(DFunDef false "compileTree" ((PVar "guards") (PCons (PVar "row") (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "compileRows") (EVar "guards")) (EVar "row")) (EVar "rest")) (EBinOp "::" (EVar "row") (EVar "rest"))))
(DTypeSig false "compileRows" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))))
(DFunDef false "compileRows" ((PVar "guards") (PTuple (PVar "pats") (PVar "i")) (PVar "rest") (PVar "rows")) (EIf (EApp (EVar "allWild") (EVar "pats")) (EApp (EApp (EApp (EVar "leafOrGuard") (EVar "guards")) (EVar "i")) (EVar "rest")) (EIf (EApp (EApp (EVar "anyList") (EVar "rowHasCon")) (EVar "rows")) (EApp (EApp (EVar "buildConSwitch") (EVar "guards")) (EVar "rows")) (EIf (EApp (EApp (EVar "anyList") (EVar "rowHasLit")) (EVar "rows")) (EApp (EApp (EVar "buildLitSwitch") (EVar "guards")) (EVar "rows")) (EIf (EVar "otherwise") (EApp (EVar "CTDrop") (EApp (EApp (EVar "compileTree") (EVar "guards")) (EApp (EApp (EVar "map") (EVar "dropHead")) (EVar "rows")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "leafOrGuard" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree")))))
(DFunDef false "leafOrGuard" ((PVar "guards") (PVar "i") (PVar "rest")) (EIf (EApp (EApp (EVar "nthBool") (EVar "guards")) (EVar "i")) (EApp (EApp (EVar "CTGuard") (EVar "i")) (EApp (EApp (EVar "compileTree") (EVar "guards")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EVar "CTLeaf") (EVar "i")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "buildConSwitch" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))
(DFunDef false "buildConSwitch" ((PVar "guards") (PVar "rows")) (EApp (EApp (EVar "CTSwitch") (EApp (EApp (EVar "map") (EApp (EApp (EVar "conBranch") (EVar "guards")) (EVar "rows"))) (EApp (EVar "distinctConHeads") (EVar "rows")))) (EApp (EApp (EVar "compileTree") (EVar "guards")) (EApp (EVar "defaultMatrix") (EVar "rows")))))
(DTypeSig false "conBranch" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CTBranch")))))
(DFunDef false "conBranch" ((PVar "guards") (PVar "rows") (PTuple (PVar "c") (PVar "a"))) (EApp (EApp (EVar "CTBranch") (EApp (EApp (EVar "decodeHead") (EVar "c")) (EVar "a"))) (EApp (EApp (EVar "compileTree") (EVar "guards")) (EApp (EApp (EApp (EVar "specializeCon") (EVar "c")) (EVar "a")) (EVar "rows")))))
(DTypeSig false "buildLitSwitch" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))
(DFunDef false "buildLitSwitch" ((PVar "guards") (PVar "rows")) (EApp (EApp (EVar "CTSwitch") (EApp (EApp (EVar "map") (EApp (EApp (EVar "litBranch") (EVar "guards")) (EVar "rows"))) (EApp (EVar "distinctLits") (EVar "rows")))) (EApp (EApp (EVar "compileTree") (EVar "guards")) (EApp (EVar "defaultMatrix") (EVar "rows")))))
(DTypeSig false "litBranch" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyFun (TyCon "Lit") (TyCon "CTBranch")))))
(DFunDef false "litBranch" ((PVar "guards") (PVar "rows") (PVar "l")) (EApp (EApp (EVar "CTBranch") (EApp (EVar "HLit") (EVar "l"))) (EApp (EApp (EVar "compileTree") (EVar "guards")) (EApp (EApp (EVar "specializeLit") (EVar "l")) (EVar "rows")))))
(DTypeSig false "decodeHead" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "CHead"))))
(DFunDef false "decodeHead" ((PLit (LString "__cons__")) PWild) (EVar "HCons"))
(DFunDef false "decodeHead" ((PLit (LString "__nil__")) PWild) (EVar "HNil"))
(DFunDef false "decodeHead" ((PLit (LString "__unit__")) PWild) (EVar "HUnit"))
(DFunDef false "decodeHead" ((PLit (LString "__tuple__")) (PVar "a")) (EApp (EVar "HTuple") (EVar "a")))
(DFunDef false "decodeHead" ((PVar "c") (PVar "a")) (EApp (EApp (EVar "HCon") (EVar "c")) (EVar "a")))
(DTypeSig false "tupleName" (TyCon "String"))
(DFunDef false "tupleName" () (ELit (LString "__tuple__")))
(DTypeSig false "consName" (TyCon "String"))
(DFunDef false "consName" () (ELit (LString "__cons__")))
(DTypeSig false "nilName" (TyCon "String"))
(DFunDef false "nilName" () (ELit (LString "__nil__")))
(DTypeSig false "unitName" (TyCon "String"))
(DFunDef false "unitName" () (ELit (LString "__unit__")))
(DTypeSig true "canonPat" (TyFun (TyCon "Pat") (TyCon "Pat")))
(DFunDef false "canonPat" ((PCon "PVar" PWild PWild)) (EVar "PWild"))
(DFunDef false "canonPat" ((PCon "PWild")) (EVar "PWild"))
(DFunDef false "canonPat" ((PCon "PLit" (PCon "LBool" (PCon "True")))) (EApp (EApp (EVar "PCon") (ELit (LString "True"))) (EListLit)))
(DFunDef false "canonPat" ((PCon "PLit" (PCon "LBool" (PCon "False")))) (EApp (EApp (EVar "PCon") (ELit (LString "False"))) (EListLit)))
(DFunDef false "canonPat" ((PCon "PLit" (PCon "LUnit"))) (EApp (EApp (EVar "PCon") (EVar "unitName")) (EListLit)))
(DFunDef false "canonPat" ((PCon "PLit" (PVar "l"))) (EApp (EVar "PLit") (EVar "l")))
(DFunDef false "canonPat" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "PCon") (EVar "tupleName")) (EApp (EApp (EVar "map") (EVar "canonPat")) (EVar "ps"))))
(DFunDef false "canonPat" ((PCon "PCon" (PVar "c") (PVar "args"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EVar "map") (EVar "canonPat")) (EVar "args"))))
(DFunDef false "canonPat" ((PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCon") (EVar "consName")) (EListLit (EApp (EVar "canonPat") (EVar "h")) (EApp (EVar "canonPat") (EVar "t")))))
(DFunDef false "canonPat" ((PCon "PList" (PList))) (EApp (EApp (EVar "PCon") (EVar "nilName")) (EListLit)))
(DFunDef false "canonPat" ((PCon "PList" (PCons (PVar "h") (PVar "r")))) (EApp (EApp (EVar "PCon") (EVar "consName")) (EListLit (EApp (EVar "canonPat") (EVar "h")) (EApp (EVar "canonPat") (EApp (EVar "PList") (EVar "r"))))))
(DFunDef false "canonPat" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "canonPat") (EVar "p")))
(DFunDef false "canonPat" ((PCon "PRng" PWild PWild PWild)) (EVar "PWild"))
(DFunDef false "canonPat" ((PCon "PRec" PWild PWild PWild)) (EVar "PWild"))
(DTypeSig false "allWild" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool")))
(DFunDef false "allWild" ((PVar "ps")) (EApp (EApp (EVar "allList") (EVar "isWildPat")) (EVar "ps")))
(DTypeSig false "isWildPat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isWildPat" ((PCon "PWild")) (EVar "True"))
(DFunDef false "isWildPat" (PWild) (EVar "False"))
(DTypeSig false "rowHasCon" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "rowHasCon" ((PTuple (PCons (PCon "PCon" PWild PWild) PWild) PWild)) (EVar "True"))
(DFunDef false "rowHasCon" (PWild) (EVar "False"))
(DTypeSig false "rowHasLit" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "rowHasLit" ((PTuple (PCons (PCon "PLit" PWild) PWild) PWild)) (EVar "True"))
(DFunDef false "rowHasLit" (PWild) (EVar "False"))
(DTypeSig false "dropHead" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))
(DFunDef false "dropHead" ((PTuple (PCons PWild (PVar "ps")) (PVar "i"))) (ETuple (EVar "ps") (EVar "i")))
(DFunDef false "dropHead" ((PTuple (PList) (PVar "i"))) (ETuple (EListLit) (EVar "i")))
(DTypeSig false "distinctConHeads" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "distinctConHeads" ((PVar "rows")) (EApp (EApp (EVar "dedupHeads") (EApp (EVar "colHeads") (EVar "rows"))) (EVar "omEmpty")))
(DTypeSig false "colHeads" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "colHeads" ((PList)) (EListLit))
(DFunDef false "colHeads" ((PCons (PTuple (PCons (PCon "PCon" (PVar "c") (PVar "args")) PWild) PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "c") (EApp (EVar "listLen") (EVar "args"))) (EApp (EVar "colHeads") (EVar "rest"))))
(DFunDef false "colHeads" ((PCons PWild (PVar "rest"))) (EApp (EVar "colHeads") (EVar "rest")))
(DTypeSig false "dedupHeads" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "dedupHeads" ((PList) PWild) (EListLit))
(DFunDef false "dedupHeads" ((PCons (PTuple (PVar "c") (PVar "a")) (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "c")) (EVar "seen")) (EApp (EApp (EVar "dedupHeads") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "c") (EVar "a")) (EApp (EApp (EVar "dedupHeads") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (ELit LUnit)) (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "distinctLits" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Lit"))))
(DFunDef false "distinctLits" ((PVar "rows")) (EApp (EApp (EVar "dedupLits") (EApp (EVar "colLits") (EVar "rows"))) (EVar "omEmpty")))
(DTypeSig false "colLits" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Lit"))))
(DFunDef false "colLits" ((PList)) (EListLit))
(DFunDef false "colLits" ((PCons (PTuple (PCons (PCon "PLit" (PVar "l")) PWild) PWild) (PVar "rest"))) (EBinOp "::" (EVar "l") (EApp (EVar "colLits") (EVar "rest"))))
(DFunDef false "colLits" ((PCons PWild (PVar "rest"))) (EApp (EVar "colLits") (EVar "rest")))
(DTypeSig false "dedupLits" (TyFun (TyApp (TyCon "List") (TyCon "Lit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "Lit")))))
(DFunDef false "dedupLits" ((PList) PWild) (EListLit))
(DFunDef false "dedupLits" ((PCons (PVar "l") (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "k") (EApp (EVar "litKey") (EVar "l"))) (DoExpr (EMatch (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "seen")) (arm (PCon "True") () (EApp (EApp (EVar "dedupLits") (EVar "rest")) (EVar "seen"))) (arm (PCon "False") () (EBinOp "::" (EVar "l") (EApp (EApp (EVar "dedupLits") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (ELit LUnit)) (EVar "seen")))))))))
(DTypeSig false "litKey" (TyFun (TyCon "Lit") (TyCon "String")))
(DFunDef false "litKey" ((PCon "LInt" (PVar "n"))) (EBinOp "++" (ELit (LString "i")) (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "litKey" ((PCon "LChar" (PVar "c"))) (EBinOp "++" (ELit (LString "c")) (EVar "c")))
(DFunDef false "litKey" ((PCon "LString" (PVar "s"))) (EBinOp "++" (ELit (LString "s")) (EVar "s")))
(DFunDef false "litKey" ((PCon "LFloat" (PVar "f"))) (EBinOp "++" (ELit (LString "f")) (EApp (EVar "floatToString") (EApp (EVar "normLitZero") (EVar "f")))))
(DFunDef false "litKey" ((PCon "LBool" (PCon "True"))) (ELit (LString "bT")))
(DFunDef false "litKey" ((PCon "LBool" (PCon "False"))) (ELit (LString "bF")))
(DFunDef false "litKey" ((PCon "LUnit")) (ELit (LString "u")))
(DTypeSig false "normLitZero" (TyFun (TyCon "Float") (TyCon "Float")))
(DFunDef false "normLitZero" ((PVar "f")) (EIf (EBinOp "==" (EVar "f") (ELit (LFloat 0.0))) (ELit (LFloat 0.0)) (EVar "f")))
(DTypeSig false "filterMapRows" (TyFun (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "filterMapRows" (PWild (PList)) (EListLit))
(DFunDef false "filterMapRows" ((PVar "f") (PCons (PVar "r") (PVar "rest"))) (EMatch (EApp (EVar "f") (EVar "r")) (arm (PCon "Some" (PVar "r2")) () (EBinOp "::" (EVar "r2") (EApp (EApp (EVar "filterMapRows") (EVar "f")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "filterMapRows") (EVar "f")) (EVar "rest")))))
(DTypeSig false "specializeCon" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))))
(DFunDef false "specializeCon" ((PVar "c") (PVar "arity") (PVar "rows")) (EApp (EApp (EVar "filterMapRows") (EApp (EApp (EVar "specConRow") (EVar "c")) (EVar "arity"))) (EVar "rows")))
(DTypeSig false "specConRow" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))))
(DFunDef false "specConRow" ((PVar "c") PWild (PTuple (PCons (PCon "PCon" (PVar "c2") (PVar "args")) (PVar "rest")) (PVar "i"))) (EIf (EBinOp "==" (EVar "c2") (EVar "c")) (EApp (EVar "Some") (ETuple (EBinOp "++" (EVar "args") (EVar "rest")) (EVar "i"))) (EVar "None")))
(DFunDef false "specConRow" (PWild (PVar "arity") (PTuple (PCons (PCon "PWild") (PVar "rest")) (PVar "i"))) (EApp (EVar "Some") (ETuple (EBinOp "++" (EApp (EApp (EVar "replicate") (EVar "arity")) (EVar "PWild")) (EVar "rest")) (EVar "i"))))
(DFunDef false "specConRow" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "specializeLit" (TyFun (TyCon "Lit") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "specializeLit" ((PVar "l") (PVar "rows")) (EApp (EApp (EVar "filterMapRows") (EApp (EVar "specLitRow") (EVar "l"))) (EVar "rows")))
(DTypeSig false "specLitRow" (TyFun (TyCon "Lit") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "specLitRow" ((PVar "l") (PTuple (PCons (PCon "PLit" (PVar "l2")) (PVar "rest")) (PVar "i"))) (EIf (EApp (EApp (EVar "litEq") (EVar "l2")) (EVar "l")) (EApp (EVar "Some") (ETuple (EVar "rest") (EVar "i"))) (EVar "None")))
(DFunDef false "specLitRow" (PWild (PTuple (PCons (PCon "PWild") (PVar "rest")) (PVar "i"))) (EApp (EVar "Some") (ETuple (EVar "rest") (EVar "i"))))
(DFunDef false "specLitRow" (PWild PWild) (EVar "None"))
(DTypeSig false "litEq" (TyFun (TyCon "Lit") (TyFun (TyCon "Lit") (TyCon "Bool"))))
(DFunDef false "litEq" ((PCon "LInt" (PVar "a")) (PCon "LInt" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "litEq" ((PCon "LFloat" (PVar "a")) (PCon "LFloat" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "litEq" ((PCon "LString" (PVar "a")) (PCon "LString" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "litEq" ((PCon "LChar" (PVar "a")) (PCon "LChar" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "litEq" ((PCon "LBool" (PVar "a")) (PCon "LBool" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "litEq" ((PCon "LUnit") (PCon "LUnit")) (EVar "True"))
(DFunDef false "litEq" (PWild PWild) (EVar "False"))
(DTypeSig false "defaultMatrix" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))
(DFunDef false "defaultMatrix" ((PVar "rows")) (EApp (EApp (EVar "filterMapRows") (EVar "defRow")) (EVar "rows")))
(DTypeSig false "defRow" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))
(DFunDef false "defRow" ((PTuple (PCons (PCon "PWild") (PVar "rest")) (PVar "i"))) (EApp (EVar "Some") (ETuple (EVar "rest") (EVar "i"))))
(DFunDef false "defRow" (PWild) (EVar "None"))
(DTypeSig false "nthBool" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "nthBool" ((PCons (PVar "b") PWild) (PLit (LInt 0))) (EVar "b"))
(DFunDef false "nthBool" ((PCons PWild (PVar "rest")) (PVar "n")) (EApp (EApp (EVar "nthBool") (EVar "rest")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))))
(DFunDef false "nthBool" ((PList) PWild) (EVar "False"))
(DTypeSig false "lowerField" (TyFun (TyCon "FieldAssign") (TyCon "CField")))
(DFunDef false "lowerField" ((PCon "FieldAssign" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EVar "lower") (EVar "e"))))
(DTypeSig false "lowerBind" (TyFun (TyCon "LetBind") (TyCon "CBind")))
(DFunDef false "lowerBind" ((PCon "LetBind" (PVar "name") (PVar "clauses"))) (EApp (EApp (EVar "CBind") (EVar "name")) (EApp (EApp (EVar "map") (EVar "lowerClause")) (EVar "clauses"))))
(DTypeSig false "lowerClause" (TyFun (TyCon "FunClause") (TyCon "CClause")))
(DFunDef false "lowerClause" ((PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EVar "lower") (EVar "body"))))
(DTypeSig false "lowerStmt" (TyFun (TyCon "DoStmt") (TyCon "CStmt")))
(DFunDef false "lowerStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerStmt" ((PCon "DoLet" (PVar "b") PWild (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "b")) (EVar "pat")) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerStmt" (PWild) (EApp (EVar "panic") (ELit (LString "core_ir lower: unsupported block statement"))))
(DTypeSig true "lowerProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CProgram")))
(DFunDef false "lowerProgram" ((PVar "prog")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "ctorFieldOrdersRef")) (EApp (EVar "buildCtorFieldOrders") (EVar "prog")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EVar "lowerGroups") (EVar "prog"))) (EApp (EVar "ctorArities") (EVar "prog"))) (EApp (EVar "buildCtorToType") (EVar "prog"))) (EApp (EVar "lowerImpls") (EVar "prog"))))))
(DTypeSig true "lowerProgramEmit" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CProgram")))
(DFunDef false "lowerProgramEmit" ((PVar "prog")) (EApp (EVar "hoistNullaryMemo") (EApp (EApp (EVar "rewriteProgramRecPats") (EApp (EVar "buildRecPatFieldOrders") (EVar "prog"))) (EApp (EVar "lowerProgram") (EVar "prog")))))
(DTypeSig false "buildRecPatFieldOrders" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "buildRecPatFieldOrders" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "recPatFieldOrderEntries")) (EVar "prog")))
(DTypeSig false "recPatFieldOrderEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "recPatFieldOrderEntries" ((PCon "DData" PWild PWild PWild (PVar "variants") PWild)) (EApp (EApp (EVar "flatMap") (EVar "variantNamedOrder")) (EVar "variants")))
(DFunDef false "recPatFieldOrderEntries" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "recPatFieldOrderEntries") (EVar "inner")))
(DFunDef false "recPatFieldOrderEntries" (PWild) (EListLit))
(DTypeSig false "variantNamedOrder" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "variantNamedOrder" ((PCon "Variant" (PVar "n") (PCon "ConNamed" (PVar "fs") PWild))) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "fieldLabel")) (EVar "fs")))))
(DFunDef false "variantNamedOrder" (PWild) (EListLit))
(DTypeSig false "fieldLabel" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldLabel" ((PCon "Field" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "rewritePat" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PRec" (PVar "name") (PVar "recFields") PWild)) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "fo")) (arm (PCon "Some" (PVar "labels")) () (EApp (EApp (EVar "PCon") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "recPatForLabel") (EVar "fo")) (EVar "recFields"))) (EVar "labels")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "PRec") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteRecPatField") (EVar "fo"))) (EVar "recFields"))) (EVar "False")))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PCon" (PVar "c") (PVar "args"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EVar "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "args"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCons") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "h"))) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "t"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EVar "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "ps"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EVar "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "ps"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PAs" (PVar "x") (PVar "l") (PVar "p"))) (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EVar "l")) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "p"))))
(DFunDef false "rewritePat" (PWild (PVar "p")) (EVar "p"))
(DTypeSig false "recPatForLabel" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyFun (TyCon "String") (TyCon "Pat")))))
(DFunDef false "recPatForLabel" ((PVar "fo") (PVar "recFields") (PVar "label")) (EMatch (EApp (EApp (EVar "findRecField") (EVar "label")) (EVar "recFields")) (arm (PCon "Some" (PCon "RecPatField" PWild (PVar "fl") (PCon "Some" (PVar "sub")))) () (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "sub"))) (arm (PCon "Some" (PCon "RecPatField" PWild (PVar "fl") (PCon "None"))) () (EApp (EApp (EVar "PVar") (EVar "label")) (EVar "fl"))) (arm (PCon "None") () (EVar "PWild"))))
(DTypeSig false "findRecField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyApp (TyCon "Option") (TyCon "RecPatField")))))
(DFunDef false "findRecField" (PWild (PList)) (EVar "None"))
(DFunDef false "findRecField" ((PVar "label") (PCons (PCon "RecPatField" (PVar "l") (PVar "fl") (PVar "sub")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "l") (EVar "label")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "RecPatField") (EVar "l")) (EVar "fl")) (EVar "sub"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "findRecField") (EVar "label")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "rewriteRecPatField" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "RecPatField") (TyCon "RecPatField"))))
(DFunDef false "rewriteRecPatField" ((PVar "fo") (PCon "RecPatField" (PVar "l") (PVar "fl") (PCon "Some" (PVar "sub")))) (EApp (EApp (EApp (EVar "RecPatField") (EVar "l")) (EVar "fl")) (EApp (EVar "Some") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "sub")))))
(DFunDef false "rewriteRecPatField" (PWild (PCon "RecPatField" (PVar "l") (PVar "fl") (PCon "None"))) (EApp (EApp (EApp (EVar "RecPatField") (EVar "l")) (EVar "fl")) (EVar "None")))
(DTypeSig false "rewriteProgramRecPats" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "rewriteProgramRecPats" ((PVar "fo") (PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "implEntries"))) (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindRP") (EVar "fo"))) (EVar "groups"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteImplRP") (EVar "fo"))) (EVar "implEntries"))))
(DTypeSig false "rewriteBindRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "rewriteBindRP" ((PVar "fo") (PCon "CBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteClauseRP") (EVar "fo"))) (EVar "clauses"))))
(DTypeSig false "rewriteClauseRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "rewriteClauseRP" ((PVar "fo") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EApp (EApp (EVar "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DTypeSig false "rewriteImplRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "rewriteImplRP" ((PVar "fo") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "ps")) (EApp (EApp (EVar "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body")))))
(DFunDef false "rewriteImplRP" ((PVar "fo") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplDefault" (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EVar "CImplDefault") (EApp (EApp (EVar "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body")))))
(DTypeSig false "rewriteExprRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "rewriteExprRP" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "rewriteExprRP" (PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "f"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "x"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EApp (EApp (EVar "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "pat"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e1"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e2"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindRP") (EVar "fo"))) (EVar "binds"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteArmRP") (EVar "fo"))) (EVar "arms"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBlock (DoLet false false (PVar "arms2") (EApp (EApp (EVar "map") (EApp (EVar "rewriteArmRP") (EVar "fo"))) (EVar "arms"))) (DoExpr (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "scrut"))) (EVar "arms2")) (EApp (EVar "compileArmsC") (EVar "arms2"))))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "c"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "t"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag"))) (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "l"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "r"))) (EVar "tag")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "x"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EVar "map") (EApp (EVar "rewriteExprRP") (EVar "fo"))) (EVar "es"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EVar "map") (EApp (EVar "rewriteExprRP") (EVar "fo"))) (EVar "es"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteFieldRP") (EVar "fo"))) (EVar "fields"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CFieldAccess" (PVar "ex") (PVar "f") (PVar "n"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "ex"))) (EVar "f")) (EVar "n")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteFieldRP") (EVar "fo"))) (EVar "fields"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteFieldRP") (EVar "fo"))) (EVar "fields"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EVar "map") (EApp (EVar "rewriteExprRP") (EVar "fo"))) (EVar "es"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "i"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "i"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "i"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EVar "map") (EApp (EVar "rewriteStmtRP") (EVar "fo"))) (EVar "stmts"))))
(DFunDef false "rewriteExprRP" (PWild (PCon "CMethod" (PVar "name") (PVar "r") (PVar "ir") (PVar "mr"))) (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "r")) (EVar "ir")) (EVar "mr")))
(DFunDef false "rewriteExprRP" (PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "rewriteArmRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "rewriteArmRP" ((PVar "fo") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "pat"))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteGuardRP") (EVar "fo"))) (EVar "guards"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DTypeSig false "rewriteGuardRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "rewriteGuardRP" ((PVar "fo") (PCon "CGBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteGuardRP" ((PVar "fo") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "p"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DTypeSig false "rewriteStmtRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "rewriteStmtRP" ((PVar "fo") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteStmtRP" ((PVar "fo") (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "pat"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteStmtRP" ((PVar "fo") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DTypeSig false "rewriteFieldRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "rewriteFieldRP" ((PVar "fo") (PCon "CField" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DTypeSig false "memoRefsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "memoRefsRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "memoKeys" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "memoKeys" ((PVar "entries")) (EApp (EApp (EVar "memoKeysGo") (EVar "entries")) (EVar "entries")))
(DTypeSig false "memoKeysGo" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "memoKeysGo" (PWild (PList)) (EListLit))
(DFunDef false "memoKeysGo" ((PVar "all") (PCons (PCon "CImplEntry" (PVar "m") PWild (PCon "CImplTagged" (PVar "tag") (PVar "key") PWild (PVar "positions") (PVar "pats") PWild)) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "positions")) (EApp (EVar "isEmptyL") (EVar "pats"))) (EBinOp "::" (ETuple (EVar "m") (EApp (EApp (EApp (EApp (EVar "memoSelector") (EVar "all")) (EVar "m")) (EVar "tag")) (EVar "key"))) (EApp (EApp (EVar "memoKeysGo") (EVar "all")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "memoKeysGo" ((PVar "all") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "memoKeysGo") (EVar "all")) (EVar "rest")))
(DTypeSig false "memoSelector" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "memoSelector" ((PVar "all") (PVar "method") (PVar "tag") (PVar "key")) (EIf (EApp (EApp (EApp (EVar "headTagUniqueL") (EVar "all")) (EVar "method")) (EVar "tag")) (EVar "tag") (EVar "key")))
(DTypeSig false "headTagUniqueL" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "headTagUniqueL" ((PVar "entries") (PVar "method") (PVar "tag")) (EBinOp "<=" (EApp (EVar "listLen") (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "entries")) (EVar "method")) (EVar "tag")) (EListLit))) (ELit (LInt 1))))
(DTypeSig false "distinctKeysAtHeadL" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "distinctKeysAtHeadL" ((PList) PWild PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "distinctKeysAtHeadL" ((PCons (PCon "CImplEntry" (PVar "n") PWild (PCon "CImplTagged" (PVar "t") (PVar "k") PWild PWild PWild PWild)) (PVar "rest")) (PVar "method") (PVar "tag") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "method")) (EBinOp "==" (EVar "t") (EVar "tag"))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "k")) (EVar "acc")))) (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EBinOp "::" (EVar "k") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "distinctKeysAtHeadL" ((PCons PWild (PVar "rest")) (PVar "method") (PVar "tag") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EVar "acc")))
(DTypeSig false "isMemoKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isMemoKey" ((PList) PWild PWild) (EVar "False"))
(DFunDef false "isMemoKey" ((PCons (PTuple (PVar "m2") (PVar "t2")) (PVar "rest")) (PVar "m") (PVar "tag")) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EVar "m") (EVar "m2")) (EBinOp "==" (EVar "tag") (EVar "t2"))) (EApp (EApp (EApp (EVar "isMemoKey") (EVar "rest")) (EVar "m")) (EVar "tag"))))
(DTypeSig false "soleMemoKeys" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "soleMemoKeys" (PWild (PList)) (EListLit))
(DFunDef false "soleMemoKeys" ((PVar "entries") (PCons (PTuple (PVar "m") (PVar "sel")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EApp (EVar "taggedImplCount") (EVar "entries")) (EVar "m")) (ELit (LInt 1))) (ELit (LInt 1))) (EApp (EVar "not") (EApp (EApp (EVar "hasDefaultL") (EVar "entries")) (EVar "m")))) (EBinOp "::" (ETuple (EVar "m") (EVar "sel")) (EApp (EApp (EVar "soleMemoKeys") (EVar "entries")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "soleMemoKeys") (EVar "entries")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "taggedImplCount" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "taggedImplCount" ((PVar "entries") (PVar "method") (PVar "cap")) (EApp (EVar "listLen") (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "entries")) (EVar "method")) (EVar "cap")) (EListLit))))
(DTypeSig false "distinctImplKeysL" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "distinctImplKeysL" ((PList) PWild PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "distinctImplKeysL" (PWild PWild (PVar "cap") (PVar "acc")) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "acc")) (EVar "cap")) (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "distinctImplKeysL" ((PCons (PCon "CImplEntry" (PVar "n") PWild (PCon "CImplTagged" PWild (PVar "k") PWild PWild PWild PWild)) (PVar "rest")) (PVar "method") (PVar "cap") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "method")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "k")) (EVar "acc")))) (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EBinOp "::" (EVar "k") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "distinctImplKeysL" ((PCons PWild (PVar "rest")) (PVar "method") (PVar "cap") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EVar "acc")))
(DTypeSig false "hasDefaultL" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasDefaultL" ((PList) PWild) (EVar "False"))
(DFunDef false "hasDefaultL" ((PCons (PCon "CImplEntry" (PVar "n") PWild (PCon "CImplDefault" PWild PWild)) (PVar "rest")) (PVar "m")) (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "m")) (EApp (EApp (EVar "hasDefaultL") (EVar "rest")) (EVar "m"))))
(DFunDef false "hasDefaultL" ((PCons PWild (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "hasDefaultL") (EVar "rest")) (EVar "m")))
(DTypeSig false "soleMemoKeysRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "soleMemoKeysRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "allMemoKeysRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "allMemoKeysRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "memoBindName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "memoBindName" ((PVar "selector") (PVar "method")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "$memo_")) (EApp (EVar "display") (EApp (EVar "sanitizeId") (EVar "selector")))) (ELit (LString "_"))) (EApp (EVar "display") (EVar "method"))) (ELit (LString ""))))
(DTypeSig false "recordMemoRef" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "recordMemoRef" ((PVar "tag") (PVar "method")) (EApp (EApp (EVar "setRef") (EVar "memoRefsRef")) (EBinOp "::" (ETuple (EVar "tag") (EVar "method")) (EFieldAccess (EVar "memoRefsRef") "value"))))
(DTypeSig false "hoistDictNullary" (TyFun (TyCon "String") (TyFun (TyCon "Route") (TyCon "CExpr"))))
(DFunDef false "hoistDictNullary" ((PVar "name") (PVar "route")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "soleMemoKeysRef") "value")) (arm (PCon "Some" (PVar "sel")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "recordMemoRef") (EVar "sel")) (EVar "name"))) (DoExpr (EApp (EApp (EVar "CVar") (EApp (EApp (EVar "memoBindName") (EVar "sel")) (EVar "name"))) (EVar "AGlobal"))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "recordMultiImplMemo") (EVar "name"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "route")) (EListLit)) (EListLit)))))))
(DTypeSig false "recordMultiImplMemo" (TyFun (TyCon "String") (TyCon "Unit")))
(DFunDef false "recordMultiImplMemo" ((PVar "name")) (EApp (EApp (EVar "recordMultiImplMemoGo") (EVar "name")) (EFieldAccess (EVar "allMemoKeysRef") "value")))
(DTypeSig false "recordMultiImplMemoGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "recordMultiImplMemoGo" (PWild (PList)) (ELit LUnit))
(DFunDef false "recordMultiImplMemoGo" ((PVar "name") (PCons (PTuple (PVar "m") (PVar "sel")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "name")) (ELet false PWild (EApp (EApp (EVar "recordMemoRef") (EVar "sel")) (EVar "name")) (EApp (EApp (EVar "recordMultiImplMemoGo") (EVar "name")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "recordMultiImplMemoGo") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hoistNullaryMemo" (TyFun (TyCon "CProgram") (TyCon "CProgram")))
(DFunDef false "hoistNullaryMemo" ((PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "implEntries"))) (EBlock (DoLet false false (PVar "keys") (EApp (EVar "memoKeys") (EVar "implEntries"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "keys")) (EApp (EApp (EApp (EApp (EVar "CProgram") (EVar "groups")) (EVar "ctorArs")) (EVar "ctorTypes")) (EVar "implEntries")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "memoRefsRef")) (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "soleMemoKeysRef")) (EApp (EApp (EVar "soleMemoKeys") (EVar "implEntries")) (EVar "keys")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "allMemoKeysRef")) (EVar "keys"))) (DoLet false false (PVar "groups2") (EApp (EApp (EVar "map") (EApp (EVar "hoistBind") (EVar "keys"))) (EVar "groups"))) (DoLet false false (PVar "impls2") (EApp (EApp (EVar "map") (EApp (EVar "hoistImpl") (EVar "keys"))) (EVar "implEntries"))) (DoLet false false (PVar "refs") (EApp (EApp (EVar "dedupPairs") (EApp (EVar "reverseL") (EFieldAccess (EVar "memoRefsRef") "value"))) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CProgram") (EBinOp "++" (EApp (EApp (EVar "map") (EVar "memoCafBind")) (EVar "refs")) (EVar "groups2"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EVar "impls2"))))))))
(DTypeSig false "memoCafBind" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "CBind")))
(DFunDef false "memoCafBind" ((PTuple (PVar "tag") (PVar "method"))) (EApp (EApp (EVar "CBind") (EApp (EApp (EVar "memoBindName") (EVar "tag")) (EVar "method"))) (EListLit (EApp (EApp (EVar "CClause") (EListLit)) (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "method")) (EApp (EApp (EVar "RKey") (EVar "tag")) (EListLit))) (EListLit)) (EListLit))))))
(DTypeSig false "dedupPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "dedupPairs" ((PList) PWild) (EListLit))
(DFunDef false "dedupPairs" ((PCons (PVar "p") (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "pairMember") (EVar "p")) (EVar "seen")) (EApp (EApp (EVar "dedupPairs") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "p") (EApp (EApp (EVar "dedupPairs") (EVar "rest")) (EBinOp "::" (EVar "p") (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pairMember" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "pairMember" (PWild (PList)) (EVar "False"))
(DFunDef false "pairMember" ((PTuple (PVar "a") (PVar "b")) (PCons (PTuple (PVar "a2") (PVar "b2")) (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "a2")) (EBinOp "==" (EVar "b") (EVar "b2"))) (EApp (EApp (EVar "pairMember") (ETuple (EVar "a") (EVar "b"))) (EVar "rest"))))
(DTypeSig false "hoistBind" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "hoistBind" ((PVar "keys") (PCon "CBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "hoistClause") (EVar "keys"))) (EVar "clauses"))))
(DTypeSig false "hoistClause" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "hoistClause" ((PVar "keys") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "body"))))
(DTypeSig false "hoistImpl" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "hoistImpl" ((PVar "keys") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "pos") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "pos")) (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "body")))))
(DFunDef false "hoistImpl" ((PVar "keys") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplDefault" (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EVar "CImplDefault") (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "body")))))
(DTypeSig false "hoistExpr" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CMethod" (PVar "name") (PCon "RKey" (PVar "tag") (PList)) (PList) (PList))) (EIf (EApp (EApp (EApp (EVar "isMemoKey") (EVar "keys")) (EVar "name")) (EVar "tag")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "recordMemoRef") (EVar "tag")) (EVar "name"))) (DoExpr (EApp (EApp (EVar "CVar") (EApp (EApp (EVar "memoBindName") (EVar "tag")) (EVar "name"))) (EVar "AGlobal")))) (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EApp (EApp (EVar "RKey") (EVar "tag")) (EListLit))) (EListLit)) (EListLit))))
(DFunDef false "hoistExpr" (PWild (PCon "CMethod" (PVar "name") (PCon "RDict" (PVar "d")) (PList) (PList))) (EApp (EApp (EVar "hoistDictNullary") (EVar "name")) (EApp (EVar "RDict") (EVar "d"))))
(DFunDef false "hoistExpr" (PWild (PCon "CMethod" (PVar "name") (PCon "RDictFwd" (PVar "d")) (PList) (PList))) (EApp (EApp (EVar "hoistDictNullary") (EVar "name")) (EApp (EVar "RDictFwd") (EVar "d"))))
(DFunDef false "hoistExpr" (PWild (PCon "CMethod" (PVar "name") (PVar "r") (PVar "ir") (PVar "mr"))) (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "r")) (EVar "ir")) (EVar "mr")))
(DFunDef false "hoistExpr" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "hoistExpr" (PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "f"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "x"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "body"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e1"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e2"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EVar "map") (EApp (EVar "hoistBind") (EVar "keys"))) (EVar "binds"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "body"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EVar "hoistArm") (EVar "keys"))) (EVar "arms"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EVar "hoistArm") (EVar "keys"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "c"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "t"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag"))) (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "l"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "r"))) (EVar "tag")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "x"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EVar "map") (EApp (EVar "hoistExpr") (EVar "keys"))) (EVar "es"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EVar "map") (EApp (EVar "hoistExpr") (EVar "keys"))) (EVar "es"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "hoistField") (EVar "keys"))) (EVar "fields"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CFieldAccess" (PVar "ex") (PVar "f") (PVar "n"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "ex"))) (EVar "f")) (EVar "n")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "hoistField") (EVar "keys"))) (EVar "fields"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "hoistField") (EVar "keys"))) (EVar "fields"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EVar "map") (EApp (EVar "hoistExpr") (EVar "keys"))) (EVar "es"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "i"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "i"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "i"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EVar "map") (EApp (EVar "hoistStmt") (EVar "keys"))) (EVar "stmts"))))
(DFunDef false "hoistExpr" (PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "hoistArm" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "hoistArm" ((PVar "keys") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EApp (EApp (EVar "map") (EApp (EVar "hoistGuard") (EVar "keys"))) (EVar "guards"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "body"))))
(DTypeSig false "hoistGuard" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "hoistGuard" ((PVar "keys") (PCon "CGBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e"))))
(DFunDef false "hoistGuard" ((PVar "keys") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e"))))
(DTypeSig false "hoistStmt" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "hoistStmt" ((PVar "keys") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e"))))
(DFunDef false "hoistStmt" ((PVar "keys") (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e"))))
(DFunDef false "hoistStmt" ((PVar "keys") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e"))))
(DTypeSig false "hoistField" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "hoistField" ((PVar "keys") (PCon "CField" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e"))))
(DTypeSig false "compileArmsC" (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyCon "CTree")))
(DFunDef false "compileArmsC" ((PVar "arms")) (EApp (EApp (EVar "compileTree") (EApp (EApp (EVar "map") (EVar "carmHasGuard")) (EVar "arms"))) (EApp (EApp (EVar "cInitialRows") (EVar "arms")) (ELit (LInt 0)))))
(DTypeSig false "carmHasGuard" (TyFun (TyCon "CArm") (TyCon "Bool")))
(DFunDef false "carmHasGuard" ((PCon "CArm" (PVar "pat") (PVar "gs") PWild)) (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "gs")) (EApp (EVar "patNeedsGuard") (EVar "pat"))))
(DTypeSig false "cInitialRows" (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "cInitialRows" ((PList) PWild) (EListLit))
(DFunDef false "cInitialRows" ((PCons (PCon "CArm" (PVar "pat") PWild PWild) (PVar "rest")) (PVar "i")) (EBinOp "::" (ETuple (EListLit (EApp (EVar "canonPat") (EVar "pat"))) (EVar "i")) (EApp (EApp (EVar "cInitialRows") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "lowerGroups" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CBind"))))
(DFunDef false "lowerGroups" ((PVar "prog")) (EApp (EVar "lgGroup") (EApp (EVar "funClausesOf") (EVar "prog"))))
(DTypeSig false "lgGroup" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause"))) (TyApp (TyCon "List") (TyCon "CBind"))))
(DFunDef false "lgGroup" ((PVar "clauses")) (EBlock (DoLet false false (PVar "groups") (EApp (EVar "lgRuns") (EApp (EVar "lgSortName") (EApp (EApp (EVar "lgTag") (EVar "clauses")) (ELit (LInt 0)))))) (DoExpr (EApp (EApp (EVar "map") (EVar "lgToBind")) (EApp (EVar "lgSortIdx") (EVar "groups"))))))
(DTypeSig false "lgTag" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause"))) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))))))
(DFunDef false "lgTag" ((PList) PWild) (EListLit))
(DFunDef false "lgTag" ((PCons (PTuple (PVar "n") (PVar "c")) (PVar "rest")) (PVar "i")) (EBinOp "::" (ETuple (ETuple (EVar "n") (EVar "i")) (EVar "c")) (EApp (EApp (EVar "lgTag") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "lgSplit" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "lgSplit" ((PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "lgSplit" ((PList (PVar "x"))) (ETuple (EListLit (EVar "x")) (EListLit)))
(DFunDef false "lgSplit" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EVar "lgSplit") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "x") (EVar "a")) (EBinOp "::" (EVar "y") (EVar "b"))))))
(DTypeSig false "lgSortName" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause")))))
(DFunDef false "lgSortName" ((PList)) (EListLit))
(DFunDef false "lgSortName" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "lgSortName" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EVar "lgSplit") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "lgMergeName") (EApp (EVar "lgSortName") (EVar "a"))) (EApp (EVar "lgSortName") (EVar "b"))))))
(DTypeSig false "lgMergeName" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))))))
(DFunDef false "lgMergeName" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "lgMergeName" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "lgMergeName" ((PCons (PTuple (PTuple (PVar "n1") (PVar "i1")) (PVar "c1")) (PVar "xs")) (PCons (PTuple (PTuple (PVar "n2") (PVar "i2")) (PVar "c2")) (PVar "ys"))) (EMatch (EApp (EApp (EVar "stringCompare") (EVar "n1")) (EVar "n2")) (arm (PCon "Lt") () (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EApp (EApp (EVar "lgMergeName") (EVar "xs")) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EVar "ys"))))) (arm (PCon "Gt") () (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EApp (EApp (EVar "lgMergeName") (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EVar "xs"))) (EVar "ys")))) (arm (PCon "Eq") () (EIf (EBinOp "<=" (EVar "i1") (EVar "i2")) (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EApp (EApp (EVar "lgMergeName") (EVar "xs")) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EVar "ys")))) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EApp (EApp (EVar "lgMergeName") (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EVar "xs"))) (EVar "ys")))))))
(DTypeSig false "lgRuns" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause"))))))
(DFunDef false "lgRuns" ((PList)) (EListLit))
(DFunDef false "lgRuns" ((PCons (PTuple (PTuple (PVar "n") (PVar "i")) (PVar "c")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "cs") (PVar "others")) (EApp (EApp (EVar "lgSpan") (EVar "n")) (EVar "rest"))) (DoExpr (EBinOp "::" (ETuple (ETuple (EVar "n") (EVar "i")) (EBinOp "::" (EVar "c") (EVar "cs"))) (EApp (EVar "lgRuns") (EVar "others"))))))
(DTypeSig false "lgSpan" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyTuple (TyApp (TyCon "List") (TyCon "CClause")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause")))))))
(DFunDef false "lgSpan" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "lgSpan" ((PVar "n") (PCons (PTuple (PTuple (PVar "m") (PVar "j")) (PVar "c")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EBlock (DoLet false false (PTuple (PVar "cs") (PVar "o")) (EApp (EApp (EVar "lgSpan") (EVar "n")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "c") (EVar "cs")) (EVar "o")))) (ETuple (EListLit) (EBinOp "::" (ETuple (ETuple (EVar "m") (EVar "j")) (EVar "c")) (EVar "rest")))))
(DTypeSig false "lgSortIdx" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause"))))))
(DFunDef false "lgSortIdx" ((PList)) (EListLit))
(DFunDef false "lgSortIdx" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "lgSortIdx" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EVar "lgSplit") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "lgMergeIdx") (EApp (EVar "lgSortIdx") (EVar "a"))) (EApp (EVar "lgSortIdx") (EVar "b"))))))
(DTypeSig false "lgMergeIdx" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))))))
(DFunDef false "lgMergeIdx" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "lgMergeIdx" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "lgMergeIdx" ((PCons (PTuple (PTuple (PVar "n1") (PVar "i1")) (PVar "cs1")) (PVar "xs")) (PCons (PTuple (PTuple (PVar "n2") (PVar "i2")) (PVar "cs2")) (PVar "ys"))) (EIf (EBinOp "<=" (EVar "i1") (EVar "i2")) (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "cs1")) (EApp (EApp (EVar "lgMergeIdx") (EVar "xs")) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "cs2")) (EVar "ys")))) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "cs2")) (EApp (EApp (EVar "lgMergeIdx") (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "cs1")) (EVar "xs"))) (EVar "ys")))))
(DTypeSig false "lgToBind" (TyFun (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause"))) (TyCon "CBind")))
(DFunDef false "lgToBind" ((PTuple (PTuple (PVar "n") PWild) (PVar "cs"))) (EApp (EApp (EVar "CBind") (EVar "n")) (EVar "cs")))
(DTypeSig false "lowerImpls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CImplEntry"))))
(DFunDef false "lowerImpls" ((PVar "prog")) (EApp (EApp (EVar "lowerImplsWith") (EApp (EVar "installDispatchTables") (EVar "prog"))) (EVar "prog")))
(DTypeSig true "lowerImplsWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CImplEntry")))))
(DFunDef false "lowerImplsWith" ((PVar "disp") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EVar "lowerDeclImpl") (EVar "disp"))) (EVar "prog")))
(DTypeSig false "lowerDeclImpl" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "CImplEntry")))))
(DFunDef false "lowerDeclImpl" ((PVar "disp") (PRec "DImpl" ((rf "iface" (PVar "ifaceName")) (rf "tys" (PVar "typeArgs")) (rf "methods" None)) true)) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "lowerImplMethod") (EVar "disp")) (EVar "ifaceName")) (EVar "typeArgs"))) (EVar "methods")))
(DFunDef false "lowerDeclImpl" (PWild (PRec "DInterface" ((rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EApp (EVar "lowerDefault") (EVar "typeParams"))) (EVar "methods")))
(DFunDef false "lowerDeclImpl" (PWild PWild) (EListLit))
(DTypeSig false "lowerImplMethod" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "ImplMethod") (TyCon "CImplEntry"))))))
(DFunDef false "lowerImplMethod" ((PVar "disp") (PVar "ifaceName") (PVar "typeArgs") (PCon "ImplMethod" (PVar "mname") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "tag") (EApp (EApp (EVar "fromOption") (EVar "noneHeadTag")) (EApp (EVar "headTyconHead") (EVar "typeArgs")))) (DoLet false false (PVar "key") (EApp (EApp (EApp (EVar "implKeyOf") (EVar "ifaceName")) (EVar "typeArgs")) (EVar "None"))) (DoLet false false (PVar "positions") (EApp (EApp (EApp (EVar "lookupPositions") (EVar "ifaceName")) (EVar "mname")) (EVar "disp"))) (DoExpr (EApp (EApp (EApp (EVar "CImplEntry") (EVar "mname")) (EApp (EVar "tyvarsInArgs") (EVar "typeArgs"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "ifaceName")) (EVar "positions")) (EVar "pats")) (EApp (EVar "lower") (EVar "body")))))))
(DTypeSig false "lowerDefault" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "CImplEntry")))))
(DFunDef false "lowerDefault" (PWild (PCon "IfaceMethod" PWild PWild (PCon "None"))) (EListLit))
(DFunDef false "lowerDefault" ((PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") PWild (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))))) (EListLit (EApp (EApp (EApp (EVar "CImplEntry") (EVar "mname")) (EApp (EVar "listLen") (EVar "typeParams"))) (EApp (EApp (EVar "CImplDefault") (EVar "pats")) (EApp (EVar "lower") (EVar "body"))))))
(DTypeSig true "returnsSelfTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "returnsSelfTable" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ifaceReturnsSelfEntries")) (EVar "prog")))
(DTypeSig false "ifaceReturnsSelfEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "ifaceReturnsSelfEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "ifaceReturnsSelfEntry") (EVar "ifaceName")) (EVar "typeParams")) (EVar "m")))) (EVar "methods")))
(DFunDef false "ifaceReturnsSelfEntries" (PWild) (EListLit))
(DTypeSig false "ifaceReturnsSelfEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "ifaceReturnsSelfEntry" ((PVar "ifaceName") (PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild)) (ETuple (ETuple (EVar "ifaceName") (EVar "mname")) (EApp (EApp (EVar "tyMentionsParams") (EApp (EVar "methodResultTy") (EVar "mty"))) (EApp (EVar "headParamOnly") (EVar "typeParams")))))
(DTypeSig false "headParamOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "headParamOnly" ((PList)) (EListLit))
(DFunDef false "headParamOnly" ((PCons (PVar "p") PWild)) (EListLit (EVar "p")))
(DTypeSig false "methodResultTy" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "methodResultTy" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodResultTy") (EVar "t")))
(DFunDef false "methodResultTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "methodResultTy") (EVar "t")))
(DFunDef false "methodResultTy" ((PCon "TyFun" PWild (PVar "b"))) (EApp (EVar "methodResultTy") (EVar "b")))
(DFunDef false "methodResultTy" ((PVar "t")) (EVar "t"))
(DTypeSig false "tyMentionsParams" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyMentionsParams" ((PCon "TyVar" (PVar "n")) (PVar "params")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "params")))
(DFunDef false "tyMentionsParams" ((PCon "TyCon" PWild PWild) PWild) (EVar "False"))
(DFunDef false "tyMentionsParams" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsParams") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsParams" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsParams") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsParams" ((PCon "TyTuple" (PVar "ts")) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))) (EVar "ts")))
(DFunDef false "tyMentionsParams" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsParams" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))
(DTypeSig true "selfFnParamTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "selfFnParamTable" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ifaceSelfFnParamEntries")) (EVar "prog")))
(DTypeSig false "ifaceSelfFnParamEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "ifaceSelfFnParamEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "ifaceSelfFnParamEntry") (EVar "ifaceName")) (EVar "typeParams")) (EVar "m")))) (EVar "methods")))
(DFunDef false "ifaceSelfFnParamEntries" (PWild) (EListLit))
(DTypeSig false "ifaceSelfFnParamEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "ifaceSelfFnParamEntry" ((PVar "ifaceName") (PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild)) (ETuple (ETuple (EVar "ifaceName") (EVar "mname")) (EApp (EApp (EApp (EVar "selfFnPositions") (ELit (LInt 0))) (EApp (EVar "methodArgTys") (EVar "mty"))) (EVar "typeParams"))))
(DTypeSig false "methodArgTys" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "methodArgTys" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodArgTys") (EVar "t")))
(DFunDef false "methodArgTys" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "methodArgTys") (EVar "t")))
(DFunDef false "methodArgTys" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "a") (EApp (EVar "methodArgTys") (EVar "b"))))
(DFunDef false "methodArgTys" (PWild) (EListLit))
(DTypeSig true "methodIfaceTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "methodIfaceTable" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ifaceMethodArityEntries")) (EVar "prog")))
(DTypeSig false "ifaceMethodArityEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "ifaceMethodArityEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "methods" None)) true)) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EVar "ifaceMethodArityEntry") (EVar "ifaceName")) (EVar "m")))) (EVar "methods")))
(DFunDef false "ifaceMethodArityEntries" (PWild) (EListLit))
(DTypeSig false "ifaceMethodArityEntry" (TyFun (TyCon "String") (TyFun (TyCon "IfaceMethod") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "ifaceMethodArityEntry" ((PVar "ifaceName") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild)) (ETuple (EVar "mname") (ETuple (EVar "ifaceName") (EApp (EVar "listLen") (EApp (EVar "methodArgTys") (EVar "mty"))))))
(DTypeSig true "methodConstraintIfaces" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodConstraintIfaces" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "methodConstraintIfaceEntries")) (EVar "prog")))
(DTypeSig false "methodConstraintIfaceEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodConstraintIfaceEntries" ((PRec "DInterface" ((rf "typarams" None) (rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (ELam ((PVar "m")) (EApp (EApp (EVar "methodConstraintIfaceEntry") (EVar "typarams")) (EVar "m")))) (EVar "methods")))
(DFunDef false "methodConstraintIfaceEntries" (PWild) (EListLit))
(DTypeSig false "methodConstraintIfaceEntry" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "methodConstraintIfaceEntry" ((PVar "typarams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild)) (EBlock (DoLet false false (PVar "ifaces") (EApp (EApp (EVar "methodLevelConstraintIfaces") (EVar "typarams")) (EVar "mty"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "ifaces")) (EListLit) (EListLit (ETuple (EVar "mname") (EVar "ifaces")))))))
(DTypeSig false "methodLevelConstraintIfaces" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "methodLevelConstraintIfaces" ((PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (ELam ((PVar "c")) (EApp (EApp (EVar "constraintIfaceIfMethodLevel") (EVar "typarams")) (EVar "c")))) (EVar "cs")) (EApp (EApp (EVar "methodLevelConstraintIfaces") (EVar "typarams")) (EVar "t"))))
(DFunDef false "methodLevelConstraintIfaces" ((PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "methodLevelConstraintIfaces") (EVar "typarams")) (EVar "t")))
(DFunDef false "methodLevelConstraintIfaces" (PWild PWild) (EListLit))
(DTypeSig false "constraintIfaceIfMethodLevel" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "constraintIfaceIfMethodLevel" ((PVar "typarams") (PCon "Constraint" (PVar "ifaceName") (PVar "args"))) (EIf (EApp (EApp (EVar "constraintArgsMentionNonParam") (EVar "typarams")) (EVar "args")) (EListLit (EVar "ifaceName")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "constraintArgsMentionNonParam" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "constraintArgsMentionNonParam" ((PVar "typarams") (PVar "args")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "typarams")))) (EVar "args")))
(DTypeSig false "tyMentionsNonParam" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyMentionsNonParam" ((PCon "TyVar" (PVar "n")) (PVar "params")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "params"))))
(DFunDef false "tyMentionsNonParam" ((PCon "TyCon" PWild PWild) PWild) (EVar "False"))
(DFunDef false "tyMentionsNonParam" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsNonParam") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsNonParam" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsNonParam") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsNonParam" ((PCon "TyTuple" (PVar "ts")) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))) (EVar "ts")))
(DFunDef false "tyMentionsNonParam" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsNonParam" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))
(DTypeSig true "ctorFieldTypeNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorFieldTypeNames" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ctorFieldTypeEntries")) (EVar "prog")))
(DTypeSig false "ctorFieldTypeEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorFieldTypeEntries" ((PCon "DData" PWild PWild PWild (PVar "variants") PWild)) (EApp (EApp (EVar "map") (EVar "variantFieldTypeEntry")) (EVar "variants")))
(DFunDef false "ctorFieldTypeEntries" ((PCon "DNewtype" PWild PWild PWild (PVar "con") (PVar "fieldTy") PWild)) (EListLit (ETuple (EVar "con") (EListLit (EApp (EVar "tyHeadName") (EVar "fieldTy"))))))
(DFunDef false "ctorFieldTypeEntries" (PWild) (EListLit))
(DTypeSig false "variantFieldTypeEntry" (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "variantFieldTypeEntry" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PVar "tys")))) (ETuple (EVar "name") (EApp (EApp (EVar "map") (EVar "tyHeadName")) (EVar "tys"))))
(DFunDef false "variantFieldTypeEntry" ((PCon "Variant" (PVar "name") (PCon "ConNamed" (PVar "fields") PWild))) (ETuple (EVar "name") (EApp (EApp (EVar "map") (EVar "fieldTyHeadName")) (EVar "fields"))))
(DTypeSig false "fieldTyHeadName" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldTyHeadName" ((PCon "Field" PWild (PVar "ty"))) (EApp (EVar "tyHeadName") (EVar "ty")))
(DTypeSig false "tyHeadName" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "tyHeadName" ((PCon "TyCon" (PVar "n") PWild)) (EVar "n"))
(DFunDef false "tyHeadName" ((PCon "TyVar" (PVar "n"))) (EVar "n"))
(DFunDef false "tyHeadName" ((PCon "TyApp" (PVar "a") PWild)) (EApp (EVar "tyHeadName") (EVar "a")))
(DFunDef false "tyHeadName" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "tyHeadName" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "tyHeadName" (PWild) (ELit (LString "")))
(DTypeSig true "declSigTypeNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "declSigTypeNames" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "declSigTypeEntries")) (EVar "prog")))
(DTypeSig false "declSigTypeEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "declSigTypeEntries" ((PCon "DTypeSig" PWild (PVar "name") (PVar "ty"))) (EListLit (ETuple (EVar "name") (ETuple (EApp (EApp (EVar "map") (EVar "tyHeadName")) (EApp (EVar "methodArgTys") (EVar "ty"))) (EApp (EVar "tyHeadName") (EApp (EVar "methodRetTy") (EVar "ty")))))))
(DFunDef false "declSigTypeEntries" ((PCon "DExtern" PWild (PVar "name") (PVar "ty"))) (EListLit (ETuple (EVar "name") (ETuple (EApp (EApp (EVar "map") (EVar "tyHeadName")) (EApp (EVar "methodArgTys") (EVar "ty"))) (EApp (EVar "tyHeadName") (EApp (EVar "methodRetTy") (EVar "ty")))))))
(DFunDef false "declSigTypeEntries" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declSigTypeEntries") (EVar "inner")))
(DFunDef false "declSigTypeEntries" (PWild) (EListLit))
(DTypeSig false "methodRetTy" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "methodRetTy" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodRetTy") (EVar "t")))
(DFunDef false "methodRetTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "methodRetTy") (EVar "t")))
(DFunDef false "methodRetTy" ((PCon "TyFun" PWild (PVar "b"))) (EApp (EVar "methodRetTy") (EVar "b")))
(DFunDef false "methodRetTy" ((PVar "t")) (EVar "t"))
(DTypeSig false "selfFnPositions" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "selfFnPositions" (PWild (PList) PWild) (EListLit))
(DFunDef false "selfFnPositions" ((PVar "i") (PCons (PVar "t") (PVar "ts")) (PVar "params")) (EIf (EApp (EApp (EVar "tyIsFunReturningSelf") (EVar "t")) (EVar "params")) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EVar "selfFnPositions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "selfFnPositions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tyIsFunReturningSelf" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyIsFunReturningSelf" ((PCon "TyFun" PWild (PVar "b")) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EApp (EVar "methodResultTy") (EVar "b"))) (EVar "params")))
(DFunDef false "tyIsFunReturningSelf" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyIsFunReturningSelf") (EVar "t")) (EVar "params")))
(DFunDef false "tyIsFunReturningSelf" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyIsFunReturningSelf") (EVar "t")) (EVar "params")))
(DFunDef false "tyIsFunReturningSelf" (PWild PWild) (EVar "False"))
(DTypeSig false "funClausesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause")))))
(DFunDef false "funClausesOf" ((PList)) (EListLit))
(DFunDef false "funClausesOf" ((PCons (PCon "DFunDef" PWild (PVar "n") (PVar "pats") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EVar "lower") (EVar "body")))) (EApp (EVar "funClausesOf") (EVar "rest"))))
(DFunDef false "funClausesOf" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "letGroupClausesOf") (EVar "binds")) (EApp (EVar "funClausesOf") (EVar "rest"))))
(DFunDef false "funClausesOf" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "funClausesOf") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "funClausesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "funClausesOf") (EVar "rest")))
(DTypeSig false "letGroupClausesOf" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause")))))
(DFunDef false "letGroupClausesOf" ((PList)) (EListLit))
(DFunDef false "letGroupClausesOf" ((PCons (PCon "LetBind" (PVar "n") (PVar "clauses")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "lowerLetBind") (EVar "n"))) (EVar "clauses")) (EApp (EVar "letGroupClausesOf") (EVar "rest"))))
(DTypeSig false "lowerLetBind" (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyTuple (TyCon "String") (TyCon "CClause")))))
(DFunDef false "lowerLetBind" ((PVar "n") (PCon "FunClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "n") (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EVar "lower") (EVar "body")))))
(DTypeSig false "ctorArities" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "ctorArities" ((PList)) (EListLit))
(DFunDef false "ctorArities" ((PCons (PCon "DData" PWild PWild PWild (PVar "variants") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "variantArity")) (EVar "variants")) (EApp (EVar "ctorArities") (EVar "rest"))))
(DFunDef false "ctorArities" ((PCons (PCon "DNewtype" PWild PWild PWild (PVar "con") PWild PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "con") (ELit (LInt 1))) (EApp (EVar "ctorArities") (EVar "rest"))))
(DFunDef false "ctorArities" ((PCons PWild (PVar "rest"))) (EApp (EVar "ctorArities") (EVar "rest")))
(DTypeSig false "variantArity" (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "variantArity" ((PCon "Variant" (PVar "n") (PVar "payload"))) (ETuple (EVar "n") (EApp (EVar "payloadArityL") (EVar "payload"))))
(DTypeSig false "payloadArityL" (TyFun (TyCon "ConPayload") (TyCon "Int")))
(DFunDef false "payloadArityL" ((PCon "ConPos" (PVar "tys"))) (EApp (EVar "listLen") (EVar "tys")))
(DFunDef false "payloadArityL" ((PCon "ConNamed" (PVar "fs") PWild)) (EApp (EVar "listLen") (EVar "fs")))
(DTypeSig false "nodeTag" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "nodeTag" ((PCon "ESection" PWild)) (ELit (LString "ESection")))
(DFunDef false "nodeTag" ((PCon "EGuards" PWild)) (ELit (LString "EGuards")))
(DFunDef false "nodeTag" ((PCon "EDo" PWild)) (ELit (LString "EDo")))
(DFunDef false "nodeTag" ((PCon "EStringInterp" PWild)) (ELit (LString "EStringInterp")))
(DFunDef false "nodeTag" ((PCon "EVariantUpdate" PWild PWild PWild)) (ELit (LString "EVariantUpdate")))
(DFunDef false "nodeTag" ((PCon "EMapLit" PWild PWild)) (ELit (LString "EMapLit")))
(DFunDef false "nodeTag" ((PCon "ESetLit" PWild PWild)) (ELit (LString "ESetLit")))
(DFunDef false "nodeTag" ((PCon "EAsPat" PWild PWild)) (ELit (LString "EAsPat")))
(DFunDef false "nodeTag" ((PCon "EMethodRef" PWild)) (ELit (LString "EMethodRef")))
(DFunDef false "nodeTag" ((PCon "EDictApp" PWild)) (ELit (LString "EDictApp")))
(DFunDef false "nodeTag" (PWild) (ELit (LString "?")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Loc" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Expr" true) (mem "Arm" true) (mem "Guard" true) (mem "DoStmt" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "Addr" true) (mem "Decl" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "Ty" true) (mem "Constraint" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "ImplMethod" true) (mem "Route" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CProgram" true) (mem "CTree" true) (mem "CTBranch" true) (mem "CHead" true))))
(DUse false (UseGroup ("eval" "eval") ((mem "buildCtorToType" false) (mem "buildCtorFieldOrders" false) (mem "ctorFieldOrdersRef" false) (mem "installDispatchTables" false) (mem "lookupPositions" false) (mem "tyvarsInArgs" false) (mem "headTyconHead" false) (mem "implKeyOf" false))))
(DUse false (UseGroup ("list") ((mem "replicate" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("backend" "private_mangle") ((mem "sanitizeId" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "allList" false) (mem "anyList" false) (mem "lookupAssoc" false) (mem "noneHeadTag" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "reverseL" false) (mem "startsWith" false))))
(DTypeSig false "composeVar" (TyCon "String"))
(DFunDef false "composeVar" () (ELit (LString "$cf")))
(DTypeSig true "lower" (TyFun (TyCon "Expr") (TyCon "CExpr")))
(DFunDef false "lower" ((PCon "ELit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "lower" ((PCon "ENumLit" (PVar "n") (PVar "r") PWild PWild)) (EMatch (EFieldAccess (EVar "r") "value") (arm (PCon "Some" (PVar "f")) () (EApp (EVar "CLit") (EApp (EVar "LFloat") (EVar "f")))) (arm (PCon "None") () (EApp (EVar "CLit") (EApp (EVar "LInt") (EVar "n"))))))
(DFunDef false "lower" ((PCon "EVar" (PVar "x"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "AGlobal")))
(DFunDef false "lower" ((PCon "EVarId" (PVar "x") PWild)) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "AGlobal")))
(DFunDef false "lower" ((PCon "EVarAt" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "lower" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EVar "lower") (EVar "f"))) (EApp (EVar "lower") (EVar "x"))))
(DFunDef false "lower" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EVar "lower") (EVar "body"))))
(DFunDef false "lower" ((PCon "ELet" PWild (PVar "recFlag") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "recFlag")) (EVar "pat")) (EApp (EVar "lower") (EVar "e1"))) (EApp (EVar "lower") (EVar "e2"))))
(DFunDef false "lower" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EMethodRef "map") (EVar "lowerBind")) (EVar "binds"))) (EApp (EVar "lower") (EVar "body"))))
(DFunDef false "lower" ((PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "lowerMatch") (EApp (EVar "lower") (EVar "scrut"))) (EVar "arms")))
(DFunDef false "lower" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "lower") (EVar "c"))) (EApp (EVar "lower") (EVar "t"))) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lower" ((PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "route"))) (EApp (EApp (EApp (EApp (EVar "lowerBinop") (EVar "op")) (EVar "l")) (EVar "r")) (EApp (EVar "scalarTagOfRoute") (EFieldAccess (EVar "route") "value"))))
(DFunDef false "lower" ((PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "CVar") (EVar "op")) (EVar "AGlobal"))) (EApp (EVar "lower") (EVar "l")))) (EApp (EVar "lower") (EVar "r"))))
(DFunDef false "lower" ((PCon "EUnOp" (PVar "op") (PVar "e") PWild)) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lower" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EMethodRef "map") (EVar "lower")) (EVar "es"))))
(DFunDef false "lower" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EMethodRef "map") (EVar "lower")) (EVar "es"))))
(DFunDef false "lower" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EMethodRef "map") (EVar "lower")) (EVar "es"))))
(DFunDef false "lower" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")))
(DFunDef false "lower" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")))
(DFunDef false "lower" ((PCon "EIndex" (PVar "a") (PVar "i") (PVar "r"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "value") (ELit (LString "String"))) (EApp (EApp (EVar "CStringIndex") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "i"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "value") (ELit (LString "List"))) (EApp (EApp (EVar "CListIndex") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "i"))))))
(DFunDef false "lower" ((PCon "ESlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl") (PVar "r"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "value") (ELit (LString "String"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "value") (ELit (LString "List"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")))))
(DFunDef false "lower" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EVar "lower") (EVar "e"))) (EVar "f")) (EFieldAccess (EVar "r") "value")))
(DFunDef false "lower" ((PCon "ERecordCreate" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "lowerField")) (EVar "fields"))))
(DFunDef false "lower" ((PCon "ERecordUpdate" (PVar "base") (PVar "fields") (PVar "r"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EFieldAccess (EVar "r") "value")) (EApp (EVar "lower") (EVar "base"))) (EApp (EApp (EMethodRef "map") (EVar "lowerField")) (EVar "fields"))))
(DFunDef false "lower" ((PCon "EVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EVar "lower") (EVar "base"))) (EApp (EApp (EMethodRef "map") (EVar "lowerField")) (EVar "fields"))))
(DFunDef false "lower" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EMethodRef "map") (EVar "lowerStmt")) (EVar "stmts"))))
(DFunDef false "lower" ((PCon "EAnnot" (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") PWild) (PCon "TyCon" (PVar "tag") PWild))) (EApp (EApp (EApp (EApp (EVar "lowerBinop") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "tag")))
(DFunDef false "lower" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PCon "EMethodAt" (PVar "name") (PVar "routeRef") (PVar "implRef") (PVar "methodRef"))) (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EFieldAccess (EVar "routeRef") "value")) (EFieldAccess (EVar "implRef") "value")) (EFieldAccess (EVar "methodRef") "value")))
(DFunDef false "lower" ((PCon "EDictAt" (PVar "name") (PVar "routesRef"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EFieldAccess (EVar "routesRef") "value")))
(DFunDef false "lower" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir lower: unsupported node ")) (EApp (EVar "nodeTag") (EVar "other")))))
(DTypeSig false "scalarTagOfRoute" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "scalarTagOfRoute" ((PCon "RScalar" (PVar "s"))) (EVar "s"))
(DFunDef false "scalarTagOfRoute" (PWild) (ELit (LString "")))
(DTypeSig false "lowerBinop" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyCon "CExpr"))))))
(DFunDef false "lowerBinop" ((PLit (LString "&&")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "lower") (EVar "r"))) (EApp (EVar "CLit") (EApp (EVar "LBool") (EVar "False")))))
(DFunDef false "lowerBinop" ((PLit (LString "||")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "CLit") (EApp (EVar "LBool") (EVar "True")))) (EApp (EVar "lower") (EVar "r"))))
(DFunDef false "lowerBinop" ((PLit (LString "|>")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EVar "CApp") (EApp (EVar "lower") (EVar "r"))) (EApp (EVar "lower") (EVar "l"))))
(DFunDef false "lowerBinop" ((PLit (LString ">>")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EVar "composeLam") (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "lower") (EVar "r"))))
(DFunDef false "lowerBinop" ((PLit (LString "<<")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EVar "composeLam") (EApp (EVar "lower") (EVar "r"))) (EApp (EVar "lower") (EVar "l"))))
(DFunDef false "lowerBinop" ((PVar "op") (PVar "l") (PVar "r") (PVar "tag")) (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "lower") (EVar "r"))) (EVar "tag")))
(DTypeSig false "composeLam" (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "composeLam" ((PVar "first") (PVar "second")) (EApp (EApp (EVar "CLam") (EListLit (EApp (EApp (EVar "PVar") (EVar "composeVar")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))) (EApp (EApp (EVar "CApp") (EVar "second")) (EApp (EApp (EVar "CApp") (EVar "first")) (EApp (EApp (EVar "CVar") (EVar "composeVar")) (EVar "AGlobal"))))))
(DTypeSig false "lowerArm" (TyFun (TyCon "Arm") (TyCon "CArm")))
(DFunDef false "lowerArm" ((PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EApp (EApp (EMethodRef "map") (EVar "lowerGuard")) (EVar "guards"))) (EApp (EVar "lower") (EVar "body"))))
(DTypeSig false "lowerGuard" (TyFun (TyCon "Guard") (TyCon "CGuard")))
(DFunDef false "lowerGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EVar "lower") (EVar "e"))))
(DTypeSig false "lowerMatch" (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "CExpr"))))
(DFunDef false "lowerMatch" ((PVar "cscrut") (PVar "arms")) (EIf (EApp (EApp (EVar "allList") (EVar "armTreeable")) (EVar "arms")) (EApp (EApp (EApp (EVar "CDecision") (EVar "cscrut")) (EApp (EApp (EMethodRef "map") (EVar "lowerArm")) (EVar "arms"))) (EApp (EVar "compileArms") (EVar "arms"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "CMatch") (EVar "cscrut")) (EApp (EApp (EMethodRef "map") (EVar "lowerArm")) (EVar "arms"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "armTreeable" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armTreeable" ((PCon "Arm" (PVar "pat") PWild PWild)) (EApp (EVar "treeablePat") (EVar "pat")))
(DTypeSig false "treeablePat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "treeablePat" ((PCon "PWild")) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PVar" PWild PWild)) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PLit" PWild)) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PCon" PWild (PVar "args"))) (EApp (EApp (EVar "allList") (EVar "treeablePat")) (EVar "args")))
(DFunDef false "treeablePat" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "&&" (EApp (EVar "treeablePat") (EVar "h")) (EApp (EVar "treeablePat") (EVar "t"))))
(DFunDef false "treeablePat" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "allList") (EVar "treeablePat")) (EVar "ps")))
(DFunDef false "treeablePat" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EVar "treeablePat")) (EVar "ps")))
(DFunDef false "treeablePat" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "treeablePat") (EVar "p")))
(DFunDef false "treeablePat" ((PCon "PRng" PWild PWild PWild)) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PRec" PWild PWild PWild)) (EVar "True"))
(DTypeSig false "compileArms" (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "CTree")))
(DFunDef false "compileArms" ((PVar "arms")) (EApp (EApp (EVar "compileTree") (EApp (EApp (EMethodRef "map") (EVar "armHasGuard")) (EVar "arms"))) (EApp (EApp (EVar "initialRows") (EVar "arms")) (ELit (LInt 0)))))
(DTypeSig false "armHasGuard" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armHasGuard" ((PCon "Arm" (PVar "pat") (PVar "gs") PWild)) (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "gs")) (EApp (EVar "patNeedsGuard") (EVar "pat"))))
(DTypeSig false "patNeedsGuard" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patNeedsGuard" ((PCon "PRng" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patNeedsGuard" ((PCon "PRec" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patNeedsGuard" ((PCon "PCon" PWild (PVar "args"))) (EApp (EApp (EVar "anyList") (EVar "patNeedsGuard")) (EVar "args")))
(DFunDef false "patNeedsGuard" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "||" (EApp (EVar "patNeedsGuard") (EVar "h")) (EApp (EVar "patNeedsGuard") (EVar "t"))))
(DFunDef false "patNeedsGuard" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EVar "patNeedsGuard")) (EVar "ps")))
(DFunDef false "patNeedsGuard" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EVar "patNeedsGuard")) (EVar "ps")))
(DFunDef false "patNeedsGuard" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "patNeedsGuard") (EVar "p")))
(DFunDef false "patNeedsGuard" (PWild) (EVar "False"))
(DTypeSig false "initialRows" (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "initialRows" ((PList) PWild) (EListLit))
(DFunDef false "initialRows" ((PCons (PCon "Arm" (PVar "pat") PWild PWild) (PVar "rest")) (PVar "i")) (EBinOp "::" (ETuple (EListLit (EApp (EVar "canonPat") (EVar "pat"))) (EVar "i")) (EApp (EApp (EVar "initialRows") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "compileTree" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))
(DFunDef false "compileTree" (PWild (PList)) (EVar "CTFail"))
(DFunDef false "compileTree" ((PVar "guards") (PCons (PVar "row") (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "compileRows") (EVar "guards")) (EVar "row")) (EVar "rest")) (EBinOp "::" (EVar "row") (EVar "rest"))))
(DTypeSig false "compileRows" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))))
(DFunDef false "compileRows" ((PVar "guards") (PTuple (PVar "pats") (PVar "i")) (PVar "rest") (PVar "rows")) (EIf (EApp (EVar "allWild") (EVar "pats")) (EApp (EApp (EApp (EVar "leafOrGuard") (EVar "guards")) (EVar "i")) (EVar "rest")) (EIf (EApp (EApp (EVar "anyList") (EVar "rowHasCon")) (EVar "rows")) (EApp (EApp (EVar "buildConSwitch") (EVar "guards")) (EVar "rows")) (EIf (EApp (EApp (EVar "anyList") (EVar "rowHasLit")) (EVar "rows")) (EApp (EApp (EVar "buildLitSwitch") (EVar "guards")) (EVar "rows")) (EIf (EVar "otherwise") (EApp (EVar "CTDrop") (EApp (EApp (EVar "compileTree") (EVar "guards")) (EApp (EApp (EMethodRef "map") (EVar "dropHead")) (EVar "rows")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "leafOrGuard" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree")))))
(DFunDef false "leafOrGuard" ((PVar "guards") (PVar "i") (PVar "rest")) (EIf (EApp (EApp (EVar "nthBool") (EVar "guards")) (EVar "i")) (EApp (EApp (EVar "CTGuard") (EVar "i")) (EApp (EApp (EVar "compileTree") (EVar "guards")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EVar "CTLeaf") (EVar "i")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "buildConSwitch" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))
(DFunDef false "buildConSwitch" ((PVar "guards") (PVar "rows")) (EApp (EApp (EVar "CTSwitch") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "conBranch") (EVar "guards")) (EVar "rows"))) (EApp (EVar "distinctConHeads") (EVar "rows")))) (EApp (EApp (EVar "compileTree") (EVar "guards")) (EApp (EVar "defaultMatrix") (EVar "rows")))))
(DTypeSig false "conBranch" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CTBranch")))))
(DFunDef false "conBranch" ((PVar "guards") (PVar "rows") (PTuple (PVar "c") (PVar "a"))) (EApp (EApp (EVar "CTBranch") (EApp (EApp (EVar "decodeHead") (EVar "c")) (EVar "a"))) (EApp (EApp (EVar "compileTree") (EVar "guards")) (EApp (EApp (EApp (EVar "specializeCon") (EVar "c")) (EVar "a")) (EVar "rows")))))
(DTypeSig false "buildLitSwitch" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))
(DFunDef false "buildLitSwitch" ((PVar "guards") (PVar "rows")) (EApp (EApp (EVar "CTSwitch") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "litBranch") (EVar "guards")) (EVar "rows"))) (EApp (EVar "distinctLits") (EVar "rows")))) (EApp (EApp (EVar "compileTree") (EVar "guards")) (EApp (EVar "defaultMatrix") (EVar "rows")))))
(DTypeSig false "litBranch" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyFun (TyCon "Lit") (TyCon "CTBranch")))))
(DFunDef false "litBranch" ((PVar "guards") (PVar "rows") (PVar "l")) (EApp (EApp (EVar "CTBranch") (EApp (EVar "HLit") (EVar "l"))) (EApp (EApp (EVar "compileTree") (EVar "guards")) (EApp (EApp (EVar "specializeLit") (EVar "l")) (EVar "rows")))))
(DTypeSig false "decodeHead" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "CHead"))))
(DFunDef false "decodeHead" ((PLit (LString "__cons__")) PWild) (EVar "HCons"))
(DFunDef false "decodeHead" ((PLit (LString "__nil__")) PWild) (EVar "HNil"))
(DFunDef false "decodeHead" ((PLit (LString "__unit__")) PWild) (EVar "HUnit"))
(DFunDef false "decodeHead" ((PLit (LString "__tuple__")) (PVar "a")) (EApp (EVar "HTuple") (EVar "a")))
(DFunDef false "decodeHead" ((PVar "c") (PVar "a")) (EApp (EApp (EVar "HCon") (EVar "c")) (EVar "a")))
(DTypeSig false "tupleName" (TyCon "String"))
(DFunDef false "tupleName" () (ELit (LString "__tuple__")))
(DTypeSig false "consName" (TyCon "String"))
(DFunDef false "consName" () (ELit (LString "__cons__")))
(DTypeSig false "nilName" (TyCon "String"))
(DFunDef false "nilName" () (ELit (LString "__nil__")))
(DTypeSig false "unitName" (TyCon "String"))
(DFunDef false "unitName" () (ELit (LString "__unit__")))
(DTypeSig true "canonPat" (TyFun (TyCon "Pat") (TyCon "Pat")))
(DFunDef false "canonPat" ((PCon "PVar" PWild PWild)) (EVar "PWild"))
(DFunDef false "canonPat" ((PCon "PWild")) (EVar "PWild"))
(DFunDef false "canonPat" ((PCon "PLit" (PCon "LBool" (PCon "True")))) (EApp (EApp (EVar "PCon") (ELit (LString "True"))) (EListLit)))
(DFunDef false "canonPat" ((PCon "PLit" (PCon "LBool" (PCon "False")))) (EApp (EApp (EVar "PCon") (ELit (LString "False"))) (EListLit)))
(DFunDef false "canonPat" ((PCon "PLit" (PCon "LUnit"))) (EApp (EApp (EVar "PCon") (EVar "unitName")) (EListLit)))
(DFunDef false "canonPat" ((PCon "PLit" (PVar "l"))) (EApp (EVar "PLit") (EVar "l")))
(DFunDef false "canonPat" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "PCon") (EVar "tupleName")) (EApp (EApp (EMethodRef "map") (EVar "canonPat")) (EVar "ps"))))
(DFunDef false "canonPat" ((PCon "PCon" (PVar "c") (PVar "args"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EMethodRef "map") (EVar "canonPat")) (EVar "args"))))
(DFunDef false "canonPat" ((PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCon") (EVar "consName")) (EListLit (EApp (EVar "canonPat") (EVar "h")) (EApp (EVar "canonPat") (EVar "t")))))
(DFunDef false "canonPat" ((PCon "PList" (PList))) (EApp (EApp (EVar "PCon") (EVar "nilName")) (EListLit)))
(DFunDef false "canonPat" ((PCon "PList" (PCons (PVar "h") (PVar "r")))) (EApp (EApp (EVar "PCon") (EVar "consName")) (EListLit (EApp (EVar "canonPat") (EVar "h")) (EApp (EVar "canonPat") (EApp (EVar "PList") (EVar "r"))))))
(DFunDef false "canonPat" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "canonPat") (EVar "p")))
(DFunDef false "canonPat" ((PCon "PRng" PWild PWild PWild)) (EVar "PWild"))
(DFunDef false "canonPat" ((PCon "PRec" PWild PWild PWild)) (EVar "PWild"))
(DTypeSig false "allWild" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool")))
(DFunDef false "allWild" ((PVar "ps")) (EApp (EApp (EVar "allList") (EVar "isWildPat")) (EVar "ps")))
(DTypeSig false "isWildPat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isWildPat" ((PCon "PWild")) (EVar "True"))
(DFunDef false "isWildPat" (PWild) (EVar "False"))
(DTypeSig false "rowHasCon" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "rowHasCon" ((PTuple (PCons (PCon "PCon" PWild PWild) PWild) PWild)) (EVar "True"))
(DFunDef false "rowHasCon" (PWild) (EVar "False"))
(DTypeSig false "rowHasLit" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "rowHasLit" ((PTuple (PCons (PCon "PLit" PWild) PWild) PWild)) (EVar "True"))
(DFunDef false "rowHasLit" (PWild) (EVar "False"))
(DTypeSig false "dropHead" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))
(DFunDef false "dropHead" ((PTuple (PCons PWild (PVar "ps")) (PVar "i"))) (ETuple (EVar "ps") (EVar "i")))
(DFunDef false "dropHead" ((PTuple (PList) (PVar "i"))) (ETuple (EListLit) (EVar "i")))
(DTypeSig false "distinctConHeads" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "distinctConHeads" ((PVar "rows")) (EApp (EApp (EVar "dedupHeads") (EApp (EVar "colHeads") (EVar "rows"))) (EVar "omEmpty")))
(DTypeSig false "colHeads" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "colHeads" ((PList)) (EListLit))
(DFunDef false "colHeads" ((PCons (PTuple (PCons (PCon "PCon" (PVar "c") (PVar "args")) PWild) PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "c") (EApp (EVar "listLen") (EVar "args"))) (EApp (EVar "colHeads") (EVar "rest"))))
(DFunDef false "colHeads" ((PCons PWild (PVar "rest"))) (EApp (EVar "colHeads") (EVar "rest")))
(DTypeSig false "dedupHeads" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "dedupHeads" ((PList) PWild) (EListLit))
(DFunDef false "dedupHeads" ((PCons (PTuple (PVar "c") (PVar "a")) (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "c")) (EVar "seen")) (EApp (EApp (EVar "dedupHeads") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "c") (EVar "a")) (EApp (EApp (EVar "dedupHeads") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (ELit LUnit)) (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "distinctLits" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Lit"))))
(DFunDef false "distinctLits" ((PVar "rows")) (EApp (EApp (EVar "dedupLits") (EApp (EVar "colLits") (EVar "rows"))) (EVar "omEmpty")))
(DTypeSig false "colLits" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Lit"))))
(DFunDef false "colLits" ((PList)) (EListLit))
(DFunDef false "colLits" ((PCons (PTuple (PCons (PCon "PLit" (PVar "l")) PWild) PWild) (PVar "rest"))) (EBinOp "::" (EVar "l") (EApp (EVar "colLits") (EVar "rest"))))
(DFunDef false "colLits" ((PCons PWild (PVar "rest"))) (EApp (EVar "colLits") (EVar "rest")))
(DTypeSig false "dedupLits" (TyFun (TyApp (TyCon "List") (TyCon "Lit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "Lit")))))
(DFunDef false "dedupLits" ((PList) PWild) (EListLit))
(DFunDef false "dedupLits" ((PCons (PVar "l") (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "k") (EApp (EVar "litKey") (EVar "l"))) (DoExpr (EMatch (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "seen")) (arm (PCon "True") () (EApp (EApp (EVar "dedupLits") (EVar "rest")) (EVar "seen"))) (arm (PCon "False") () (EBinOp "::" (EVar "l") (EApp (EApp (EVar "dedupLits") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (ELit LUnit)) (EVar "seen")))))))))
(DTypeSig false "litKey" (TyFun (TyCon "Lit") (TyCon "String")))
(DFunDef false "litKey" ((PCon "LInt" (PVar "n"))) (EBinOp "++" (ELit (LString "i")) (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "litKey" ((PCon "LChar" (PVar "c"))) (EBinOp "++" (ELit (LString "c")) (EVar "c")))
(DFunDef false "litKey" ((PCon "LString" (PVar "s"))) (EBinOp "++" (ELit (LString "s")) (EVar "s")))
(DFunDef false "litKey" ((PCon "LFloat" (PVar "f"))) (EBinOp "++" (ELit (LString "f")) (EApp (EVar "floatToString") (EApp (EVar "normLitZero") (EVar "f")))))
(DFunDef false "litKey" ((PCon "LBool" (PCon "True"))) (ELit (LString "bT")))
(DFunDef false "litKey" ((PCon "LBool" (PCon "False"))) (ELit (LString "bF")))
(DFunDef false "litKey" ((PCon "LUnit")) (ELit (LString "u")))
(DTypeSig false "normLitZero" (TyFun (TyCon "Float") (TyCon "Float")))
(DFunDef false "normLitZero" ((PVar "f")) (EIf (EBinOp "==" (EVar "f") (ELit (LFloat 0.0))) (ELit (LFloat 0.0)) (EVar "f")))
(DTypeSig false "filterMapRows" (TyFun (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "filterMapRows" (PWild (PList)) (EListLit))
(DFunDef false "filterMapRows" ((PVar "f") (PCons (PVar "r") (PVar "rest"))) (EMatch (EApp (EVar "f") (EVar "r")) (arm (PCon "Some" (PVar "r2")) () (EBinOp "::" (EVar "r2") (EApp (EApp (EVar "filterMapRows") (EVar "f")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "filterMapRows") (EVar "f")) (EVar "rest")))))
(DTypeSig false "specializeCon" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))))
(DFunDef false "specializeCon" ((PVar "c") (PVar "arity") (PVar "rows")) (EApp (EApp (EVar "filterMapRows") (EApp (EApp (EVar "specConRow") (EVar "c")) (EVar "arity"))) (EVar "rows")))
(DTypeSig false "specConRow" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))))
(DFunDef false "specConRow" ((PVar "c") PWild (PTuple (PCons (PCon "PCon" (PVar "c2") (PVar "args")) (PVar "rest")) (PVar "i"))) (EIf (EBinOp "==" (EVar "c2") (EVar "c")) (EApp (EVar "Some") (ETuple (EBinOp "++" (EVar "args") (EVar "rest")) (EVar "i"))) (EVar "None")))
(DFunDef false "specConRow" (PWild (PVar "arity") (PTuple (PCons (PCon "PWild") (PVar "rest")) (PVar "i"))) (EApp (EVar "Some") (ETuple (EBinOp "++" (EApp (EApp (EVar "replicate") (EVar "arity")) (EVar "PWild")) (EVar "rest")) (EVar "i"))))
(DFunDef false "specConRow" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "specializeLit" (TyFun (TyCon "Lit") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "specializeLit" ((PVar "l") (PVar "rows")) (EApp (EApp (EVar "filterMapRows") (EApp (EVar "specLitRow") (EVar "l"))) (EVar "rows")))
(DTypeSig false "specLitRow" (TyFun (TyCon "Lit") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "specLitRow" ((PVar "l") (PTuple (PCons (PCon "PLit" (PVar "l2")) (PVar "rest")) (PVar "i"))) (EIf (EApp (EApp (EVar "litEq") (EVar "l2")) (EVar "l")) (EApp (EVar "Some") (ETuple (EVar "rest") (EVar "i"))) (EVar "None")))
(DFunDef false "specLitRow" (PWild (PTuple (PCons (PCon "PWild") (PVar "rest")) (PVar "i"))) (EApp (EVar "Some") (ETuple (EVar "rest") (EVar "i"))))
(DFunDef false "specLitRow" (PWild PWild) (EVar "None"))
(DTypeSig false "litEq" (TyFun (TyCon "Lit") (TyFun (TyCon "Lit") (TyCon "Bool"))))
(DFunDef false "litEq" ((PCon "LInt" (PVar "a")) (PCon "LInt" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "litEq" ((PCon "LFloat" (PVar "a")) (PCon "LFloat" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "litEq" ((PCon "LString" (PVar "a")) (PCon "LString" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "litEq" ((PCon "LChar" (PVar "a")) (PCon "LChar" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "litEq" ((PCon "LBool" (PVar "a")) (PCon "LBool" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "litEq" ((PCon "LUnit") (PCon "LUnit")) (EVar "True"))
(DFunDef false "litEq" (PWild PWild) (EVar "False"))
(DTypeSig false "defaultMatrix" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))
(DFunDef false "defaultMatrix" ((PVar "rows")) (EApp (EApp (EVar "filterMapRows") (EVar "defRow")) (EVar "rows")))
(DTypeSig false "defRow" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))
(DFunDef false "defRow" ((PTuple (PCons (PCon "PWild") (PVar "rest")) (PVar "i"))) (EApp (EVar "Some") (ETuple (EVar "rest") (EVar "i"))))
(DFunDef false "defRow" (PWild) (EVar "None"))
(DTypeSig false "nthBool" (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "nthBool" ((PCons (PVar "b") PWild) (PLit (LInt 0))) (EVar "b"))
(DFunDef false "nthBool" ((PCons PWild (PVar "rest")) (PVar "n")) (EApp (EApp (EVar "nthBool") (EVar "rest")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))))
(DFunDef false "nthBool" ((PList) PWild) (EVar "False"))
(DTypeSig false "lowerField" (TyFun (TyCon "FieldAssign") (TyCon "CField")))
(DFunDef false "lowerField" ((PCon "FieldAssign" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EVar "lower") (EVar "e"))))
(DTypeSig false "lowerBind" (TyFun (TyCon "LetBind") (TyCon "CBind")))
(DFunDef false "lowerBind" ((PCon "LetBind" (PVar "name") (PVar "clauses"))) (EApp (EApp (EVar "CBind") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "lowerClause")) (EVar "clauses"))))
(DTypeSig false "lowerClause" (TyFun (TyCon "FunClause") (TyCon "CClause")))
(DFunDef false "lowerClause" ((PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EVar "lower") (EVar "body"))))
(DTypeSig false "lowerStmt" (TyFun (TyCon "DoStmt") (TyCon "CStmt")))
(DFunDef false "lowerStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerStmt" ((PCon "DoLet" (PVar "b") PWild (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "b")) (EVar "pat")) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerStmt" (PWild) (EApp (EVar "panic") (ELit (LString "core_ir lower: unsupported block statement"))))
(DTypeSig true "lowerProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CProgram")))
(DFunDef false "lowerProgram" ((PVar "prog")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "ctorFieldOrdersRef")) (EApp (EVar "buildCtorFieldOrders") (EVar "prog")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EVar "lowerGroups") (EVar "prog"))) (EApp (EVar "ctorArities") (EVar "prog"))) (EApp (EVar "buildCtorToType") (EVar "prog"))) (EApp (EVar "lowerImpls") (EVar "prog"))))))
(DTypeSig true "lowerProgramEmit" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CProgram")))
(DFunDef false "lowerProgramEmit" ((PVar "prog")) (EApp (EVar "hoistNullaryMemo") (EApp (EApp (EVar "rewriteProgramRecPats") (EApp (EVar "buildRecPatFieldOrders") (EVar "prog"))) (EApp (EVar "lowerProgram") (EVar "prog")))))
(DTypeSig false "buildRecPatFieldOrders" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "buildRecPatFieldOrders" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "recPatFieldOrderEntries")) (EVar "prog")))
(DTypeSig false "recPatFieldOrderEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "recPatFieldOrderEntries" ((PCon "DData" PWild PWild PWild (PVar "variants") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "variantNamedOrder")) (EVar "variants")))
(DFunDef false "recPatFieldOrderEntries" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "recPatFieldOrderEntries") (EVar "inner")))
(DFunDef false "recPatFieldOrderEntries" (PWild) (EListLit))
(DTypeSig false "variantNamedOrder" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "variantNamedOrder" ((PCon "Variant" (PVar "n") (PCon "ConNamed" (PVar "fs") PWild))) (EListLit (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "fieldLabel")) (EVar "fs")))))
(DFunDef false "variantNamedOrder" (PWild) (EListLit))
(DTypeSig false "fieldLabel" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldLabel" ((PCon "Field" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "rewritePat" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PRec" (PVar "name") (PVar "recFields") PWild)) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "fo")) (arm (PCon "Some" (PVar "labels")) () (EApp (EApp (EVar "PCon") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "recPatForLabel") (EVar "fo")) (EVar "recFields"))) (EVar "labels")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "PRec") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteRecPatField") (EVar "fo"))) (EVar "recFields"))) (EVar "False")))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PCon" (PVar "c") (PVar "args"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "args"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCons") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "h"))) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "t"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "ps"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "ps"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PAs" (PVar "x") (PVar "l") (PVar "p"))) (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EVar "l")) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "p"))))
(DFunDef false "rewritePat" (PWild (PVar "p")) (EVar "p"))
(DTypeSig false "recPatForLabel" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyFun (TyCon "String") (TyCon "Pat")))))
(DFunDef false "recPatForLabel" ((PVar "fo") (PVar "recFields") (PVar "label")) (EMatch (EApp (EApp (EVar "findRecField") (EVar "label")) (EVar "recFields")) (arm (PCon "Some" (PCon "RecPatField" PWild (PVar "fl") (PCon "Some" (PVar "sub")))) () (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EMethodRef "sub"))) (arm (PCon "Some" (PCon "RecPatField" PWild (PVar "fl") (PCon "None"))) () (EApp (EApp (EVar "PVar") (EVar "label")) (EVar "fl"))) (arm (PCon "None") () (EVar "PWild"))))
(DTypeSig false "findRecField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyApp (TyCon "Option") (TyCon "RecPatField")))))
(DFunDef false "findRecField" (PWild (PList)) (EVar "None"))
(DFunDef false "findRecField" ((PVar "label") (PCons (PCon "RecPatField" (PVar "l") (PVar "fl") (PVar "sub")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "l") (EVar "label")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "RecPatField") (EVar "l")) (EVar "fl")) (EMethodRef "sub"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "findRecField") (EVar "label")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "rewriteRecPatField" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "RecPatField") (TyCon "RecPatField"))))
(DFunDef false "rewriteRecPatField" ((PVar "fo") (PCon "RecPatField" (PVar "l") (PVar "fl") (PCon "Some" (PVar "sub")))) (EApp (EApp (EApp (EVar "RecPatField") (EVar "l")) (EVar "fl")) (EApp (EVar "Some") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EMethodRef "sub")))))
(DFunDef false "rewriteRecPatField" (PWild (PCon "RecPatField" (PVar "l") (PVar "fl") (PCon "None"))) (EApp (EApp (EApp (EVar "RecPatField") (EVar "l")) (EVar "fl")) (EVar "None")))
(DTypeSig false "rewriteProgramRecPats" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "rewriteProgramRecPats" ((PVar "fo") (PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "implEntries"))) (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindRP") (EVar "fo"))) (EVar "groups"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteImplRP") (EVar "fo"))) (EVar "implEntries"))))
(DTypeSig false "rewriteBindRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "rewriteBindRP" ((PVar "fo") (PCon "CBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteClauseRP") (EVar "fo"))) (EVar "clauses"))))
(DTypeSig false "rewriteClauseRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "rewriteClauseRP" ((PVar "fo") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DTypeSig false "rewriteImplRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "rewriteImplRP" ((PVar "fo") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "ps")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body")))))
(DFunDef false "rewriteImplRP" ((PVar "fo") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplDefault" (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EVar "CImplDefault") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body")))))
(DTypeSig false "rewriteExprRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "rewriteExprRP" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "rewriteExprRP" (PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "f"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "x"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "pat"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e1"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e2"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindRP") (EVar "fo"))) (EVar "binds"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteArmRP") (EVar "fo"))) (EVar "arms"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBlock (DoLet false false (PVar "arms2") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteArmRP") (EVar "fo"))) (EVar "arms"))) (DoExpr (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "scrut"))) (EVar "arms2")) (EApp (EVar "compileArmsC") (EVar "arms2"))))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "c"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "t"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag"))) (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "l"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "r"))) (EVar "tag")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "x"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteExprRP") (EVar "fo"))) (EVar "es"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteExprRP") (EVar "fo"))) (EVar "es"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteFieldRP") (EVar "fo"))) (EVar "fields"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CFieldAccess" (PVar "ex") (PVar "f") (PVar "n"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "ex"))) (EVar "f")) (EVar "n")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteFieldRP") (EVar "fo"))) (EVar "fields"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteFieldRP") (EVar "fo"))) (EVar "fields"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteExprRP") (EVar "fo"))) (EVar "es"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "i"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "i"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "i"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteStmtRP") (EVar "fo"))) (EVar "stmts"))))
(DFunDef false "rewriteExprRP" (PWild (PCon "CMethod" (PVar "name") (PVar "r") (PVar "ir") (PVar "mr"))) (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "r")) (EVar "ir")) (EVar "mr")))
(DFunDef false "rewriteExprRP" (PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "rewriteArmRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "rewriteArmRP" ((PVar "fo") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "pat"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteGuardRP") (EVar "fo"))) (EVar "guards"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DTypeSig false "rewriteGuardRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "rewriteGuardRP" ((PVar "fo") (PCon "CGBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteGuardRP" ((PVar "fo") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "p"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DTypeSig false "rewriteStmtRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "rewriteStmtRP" ((PVar "fo") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteStmtRP" ((PVar "fo") (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "pat"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteStmtRP" ((PVar "fo") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DTypeSig false "rewriteFieldRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "rewriteFieldRP" ((PVar "fo") (PCon "CField" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DTypeSig false "memoRefsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "memoRefsRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "memoKeys" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "memoKeys" ((PVar "entries")) (EApp (EApp (EVar "memoKeysGo") (EVar "entries")) (EVar "entries")))
(DTypeSig false "memoKeysGo" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "memoKeysGo" (PWild (PList)) (EListLit))
(DFunDef false "memoKeysGo" ((PVar "all") (PCons (PCon "CImplEntry" (PVar "m") PWild (PCon "CImplTagged" (PVar "tag") (PVar "key") PWild (PVar "positions") (PVar "pats") PWild)) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "positions")) (EApp (EVar "isEmptyL") (EVar "pats"))) (EBinOp "::" (ETuple (EVar "m") (EApp (EApp (EApp (EApp (EVar "memoSelector") (EDictApp "all")) (EVar "m")) (EVar "tag")) (EVar "key"))) (EApp (EApp (EVar "memoKeysGo") (EDictApp "all")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "memoKeysGo" ((PVar "all") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "memoKeysGo") (EDictApp "all")) (EVar "rest")))
(DTypeSig false "memoSelector" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "memoSelector" ((PVar "all") (PVar "method") (PVar "tag") (PVar "key")) (EIf (EApp (EApp (EApp (EVar "headTagUniqueL") (EDictApp "all")) (EVar "method")) (EVar "tag")) (EVar "tag") (EVar "key")))
(DTypeSig false "headTagUniqueL" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "headTagUniqueL" ((PVar "entries") (PVar "method") (PVar "tag")) (EBinOp "<=" (EApp (EVar "listLen") (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "entries")) (EVar "method")) (EVar "tag")) (EListLit))) (ELit (LInt 1))))
(DTypeSig false "distinctKeysAtHeadL" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "distinctKeysAtHeadL" ((PList) PWild PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "distinctKeysAtHeadL" ((PCons (PCon "CImplEntry" (PVar "n") PWild (PCon "CImplTagged" (PVar "t") (PVar "k") PWild PWild PWild PWild)) (PVar "rest")) (PVar "method") (PVar "tag") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "method")) (EBinOp "==" (EVar "t") (EVar "tag"))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "k")) (EVar "acc")))) (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EBinOp "::" (EVar "k") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "distinctKeysAtHeadL" ((PCons PWild (PVar "rest")) (PVar "method") (PVar "tag") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EVar "acc")))
(DTypeSig false "isMemoKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isMemoKey" ((PList) PWild PWild) (EVar "False"))
(DFunDef false "isMemoKey" ((PCons (PTuple (PVar "m2") (PVar "t2")) (PVar "rest")) (PVar "m") (PVar "tag")) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EVar "m") (EVar "m2")) (EBinOp "==" (EVar "tag") (EVar "t2"))) (EApp (EApp (EApp (EVar "isMemoKey") (EVar "rest")) (EVar "m")) (EVar "tag"))))
(DTypeSig false "soleMemoKeys" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "soleMemoKeys" (PWild (PList)) (EListLit))
(DFunDef false "soleMemoKeys" ((PVar "entries") (PCons (PTuple (PVar "m") (PVar "sel")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EApp (EVar "taggedImplCount") (EVar "entries")) (EVar "m")) (ELit (LInt 1))) (ELit (LInt 1))) (EApp (EVar "not") (EApp (EApp (EVar "hasDefaultL") (EVar "entries")) (EVar "m")))) (EBinOp "::" (ETuple (EVar "m") (EVar "sel")) (EApp (EApp (EVar "soleMemoKeys") (EVar "entries")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "soleMemoKeys") (EVar "entries")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "taggedImplCount" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "taggedImplCount" ((PVar "entries") (PVar "method") (PVar "cap")) (EApp (EVar "listLen") (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "entries")) (EVar "method")) (EVar "cap")) (EListLit))))
(DTypeSig false "distinctImplKeysL" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "distinctImplKeysL" ((PList) PWild PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "distinctImplKeysL" (PWild PWild (PVar "cap") (PVar "acc")) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "acc")) (EVar "cap")) (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "distinctImplKeysL" ((PCons (PCon "CImplEntry" (PVar "n") PWild (PCon "CImplTagged" PWild (PVar "k") PWild PWild PWild PWild)) (PVar "rest")) (PVar "method") (PVar "cap") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "method")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "k")) (EVar "acc")))) (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EBinOp "::" (EVar "k") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "distinctImplKeysL" ((PCons PWild (PVar "rest")) (PVar "method") (PVar "cap") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EVar "acc")))
(DTypeSig false "hasDefaultL" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasDefaultL" ((PList) PWild) (EVar "False"))
(DFunDef false "hasDefaultL" ((PCons (PCon "CImplEntry" (PVar "n") PWild (PCon "CImplDefault" PWild PWild)) (PVar "rest")) (PVar "m")) (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "m")) (EApp (EApp (EVar "hasDefaultL") (EVar "rest")) (EVar "m"))))
(DFunDef false "hasDefaultL" ((PCons PWild (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "hasDefaultL") (EVar "rest")) (EVar "m")))
(DTypeSig false "soleMemoKeysRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "soleMemoKeysRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "allMemoKeysRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "allMemoKeysRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "memoBindName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "memoBindName" ((PVar "selector") (PVar "method")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "$memo_")) (EApp (EMethodRef "display") (EApp (EVar "sanitizeId") (EVar "selector")))) (ELit (LString "_"))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString ""))))
(DTypeSig false "recordMemoRef" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "recordMemoRef" ((PVar "tag") (PVar "method")) (EApp (EApp (EVar "setRef") (EVar "memoRefsRef")) (EBinOp "::" (ETuple (EVar "tag") (EVar "method")) (EFieldAccess (EVar "memoRefsRef") "value"))))
(DTypeSig false "hoistDictNullary" (TyFun (TyCon "String") (TyFun (TyCon "Route") (TyCon "CExpr"))))
(DFunDef false "hoistDictNullary" ((PVar "name") (PVar "route")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "soleMemoKeysRef") "value")) (arm (PCon "Some" (PVar "sel")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "recordMemoRef") (EVar "sel")) (EVar "name"))) (DoExpr (EApp (EApp (EVar "CVar") (EApp (EApp (EVar "memoBindName") (EVar "sel")) (EVar "name"))) (EVar "AGlobal"))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EVar "recordMultiImplMemo") (EVar "name"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "route")) (EListLit)) (EListLit)))))))
(DTypeSig false "recordMultiImplMemo" (TyFun (TyCon "String") (TyCon "Unit")))
(DFunDef false "recordMultiImplMemo" ((PVar "name")) (EApp (EApp (EVar "recordMultiImplMemoGo") (EVar "name")) (EFieldAccess (EVar "allMemoKeysRef") "value")))
(DTypeSig false "recordMultiImplMemoGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "recordMultiImplMemoGo" (PWild (PList)) (ELit LUnit))
(DFunDef false "recordMultiImplMemoGo" ((PVar "name") (PCons (PTuple (PVar "m") (PVar "sel")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "name")) (ELet false PWild (EApp (EApp (EVar "recordMemoRef") (EVar "sel")) (EVar "name")) (EApp (EApp (EVar "recordMultiImplMemoGo") (EVar "name")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "recordMultiImplMemoGo") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hoistNullaryMemo" (TyFun (TyCon "CProgram") (TyCon "CProgram")))
(DFunDef false "hoistNullaryMemo" ((PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "implEntries"))) (EBlock (DoLet false false (PVar "keys") (EApp (EVar "memoKeys") (EVar "implEntries"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "keys")) (EApp (EApp (EApp (EApp (EVar "CProgram") (EVar "groups")) (EVar "ctorArs")) (EVar "ctorTypes")) (EVar "implEntries")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "memoRefsRef")) (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "soleMemoKeysRef")) (EApp (EApp (EVar "soleMemoKeys") (EVar "implEntries")) (EVar "keys")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "allMemoKeysRef")) (EVar "keys"))) (DoLet false false (PVar "groups2") (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistBind") (EVar "keys"))) (EVar "groups"))) (DoLet false false (PVar "impls2") (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistImpl") (EVar "keys"))) (EVar "implEntries"))) (DoLet false false (PVar "refs") (EApp (EApp (EVar "dedupPairs") (EApp (EVar "reverseL") (EFieldAccess (EVar "memoRefsRef") "value"))) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CProgram") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "memoCafBind")) (EVar "refs")) (EVar "groups2"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EVar "impls2"))))))))
(DTypeSig false "memoCafBind" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "CBind")))
(DFunDef false "memoCafBind" ((PTuple (PVar "tag") (PVar "method"))) (EApp (EApp (EVar "CBind") (EApp (EApp (EVar "memoBindName") (EVar "tag")) (EVar "method"))) (EListLit (EApp (EApp (EVar "CClause") (EListLit)) (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "method")) (EApp (EApp (EVar "RKey") (EVar "tag")) (EListLit))) (EListLit)) (EListLit))))))
(DTypeSig false "dedupPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "dedupPairs" ((PList) PWild) (EListLit))
(DFunDef false "dedupPairs" ((PCons (PVar "p") (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "pairMember") (EVar "p")) (EVar "seen")) (EApp (EApp (EVar "dedupPairs") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "p") (EApp (EApp (EVar "dedupPairs") (EVar "rest")) (EBinOp "::" (EVar "p") (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pairMember" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "pairMember" (PWild (PList)) (EVar "False"))
(DFunDef false "pairMember" ((PTuple (PVar "a") (PVar "b")) (PCons (PTuple (PVar "a2") (PVar "b2")) (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "a2")) (EBinOp "==" (EVar "b") (EVar "b2"))) (EApp (EApp (EVar "pairMember") (ETuple (EVar "a") (EVar "b"))) (EVar "rest"))))
(DTypeSig false "hoistBind" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "hoistBind" ((PVar "keys") (PCon "CBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistClause") (EVar "keys"))) (EVar "clauses"))))
(DTypeSig false "hoistClause" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "hoistClause" ((PVar "keys") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "body"))))
(DTypeSig false "hoistImpl" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "hoistImpl" ((PVar "keys") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "pos") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "pos")) (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "body")))))
(DFunDef false "hoistImpl" ((PVar "keys") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplDefault" (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EVar "CImplDefault") (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "body")))))
(DTypeSig false "hoistExpr" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CMethod" (PVar "name") (PCon "RKey" (PVar "tag") (PList)) (PList) (PList))) (EIf (EApp (EApp (EApp (EVar "isMemoKey") (EVar "keys")) (EVar "name")) (EVar "tag")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "recordMemoRef") (EVar "tag")) (EVar "name"))) (DoExpr (EApp (EApp (EVar "CVar") (EApp (EApp (EVar "memoBindName") (EVar "tag")) (EVar "name"))) (EVar "AGlobal")))) (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EApp (EApp (EVar "RKey") (EVar "tag")) (EListLit))) (EListLit)) (EListLit))))
(DFunDef false "hoistExpr" (PWild (PCon "CMethod" (PVar "name") (PCon "RDict" (PVar "d")) (PList) (PList))) (EApp (EApp (EVar "hoistDictNullary") (EVar "name")) (EApp (EVar "RDict") (EVar "d"))))
(DFunDef false "hoistExpr" (PWild (PCon "CMethod" (PVar "name") (PCon "RDictFwd" (PVar "d")) (PList) (PList))) (EApp (EApp (EVar "hoistDictNullary") (EVar "name")) (EApp (EVar "RDictFwd") (EVar "d"))))
(DFunDef false "hoistExpr" (PWild (PCon "CMethod" (PVar "name") (PVar "r") (PVar "ir") (PVar "mr"))) (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "r")) (EVar "ir")) (EVar "mr")))
(DFunDef false "hoistExpr" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "hoistExpr" (PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "f"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "x"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "body"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e1"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e2"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistBind") (EVar "keys"))) (EVar "binds"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "body"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistArm") (EVar "keys"))) (EVar "arms"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistArm") (EVar "keys"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "c"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "t"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag"))) (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "l"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "r"))) (EVar "tag")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "x"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistExpr") (EVar "keys"))) (EVar "es"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistExpr") (EVar "keys"))) (EVar "es"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistField") (EVar "keys"))) (EVar "fields"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CFieldAccess" (PVar "ex") (PVar "f") (PVar "n"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "ex"))) (EVar "f")) (EVar "n")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistField") (EVar "keys"))) (EVar "fields"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistField") (EVar "keys"))) (EVar "fields"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistExpr") (EVar "keys"))) (EVar "es"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "i"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "i"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "i"))))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "keys") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistStmt") (EVar "keys"))) (EVar "stmts"))))
(DFunDef false "hoistExpr" (PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "hoistArm" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "hoistArm" ((PVar "keys") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistGuard") (EVar "keys"))) (EVar "guards"))) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "body"))))
(DTypeSig false "hoistGuard" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "hoistGuard" ((PVar "keys") (PCon "CGBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e"))))
(DFunDef false "hoistGuard" ((PVar "keys") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e"))))
(DTypeSig false "hoistStmt" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "hoistStmt" ((PVar "keys") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e"))))
(DFunDef false "hoistStmt" ((PVar "keys") (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e"))))
(DFunDef false "hoistStmt" ((PVar "keys") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e"))))
(DTypeSig false "hoistField" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "hoistField" ((PVar "keys") (PCon "CField" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EApp (EVar "hoistExpr") (EVar "keys")) (EVar "e"))))
(DTypeSig false "compileArmsC" (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyCon "CTree")))
(DFunDef false "compileArmsC" ((PVar "arms")) (EApp (EApp (EVar "compileTree") (EApp (EApp (EMethodRef "map") (EVar "carmHasGuard")) (EVar "arms"))) (EApp (EApp (EVar "cInitialRows") (EVar "arms")) (ELit (LInt 0)))))
(DTypeSig false "carmHasGuard" (TyFun (TyCon "CArm") (TyCon "Bool")))
(DFunDef false "carmHasGuard" ((PCon "CArm" (PVar "pat") (PVar "gs") PWild)) (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "gs")) (EApp (EVar "patNeedsGuard") (EVar "pat"))))
(DTypeSig false "cInitialRows" (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "cInitialRows" ((PList) PWild) (EListLit))
(DFunDef false "cInitialRows" ((PCons (PCon "CArm" (PVar "pat") PWild PWild) (PVar "rest")) (PVar "i")) (EBinOp "::" (ETuple (EListLit (EApp (EVar "canonPat") (EVar "pat"))) (EVar "i")) (EApp (EApp (EVar "cInitialRows") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "lowerGroups" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CBind"))))
(DFunDef false "lowerGroups" ((PVar "prog")) (EApp (EVar "lgGroup") (EApp (EVar "funClausesOf") (EVar "prog"))))
(DTypeSig false "lgGroup" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause"))) (TyApp (TyCon "List") (TyCon "CBind"))))
(DFunDef false "lgGroup" ((PVar "clauses")) (EBlock (DoLet false false (PVar "groups") (EApp (EVar "lgRuns") (EApp (EVar "lgSortName") (EApp (EApp (EVar "lgTag") (EVar "clauses")) (ELit (LInt 0)))))) (DoExpr (EApp (EApp (EMethodRef "map") (EVar "lgToBind")) (EApp (EVar "lgSortIdx") (EVar "groups"))))))
(DTypeSig false "lgTag" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause"))) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))))))
(DFunDef false "lgTag" ((PList) PWild) (EListLit))
(DFunDef false "lgTag" ((PCons (PTuple (PVar "n") (PVar "c")) (PVar "rest")) (PVar "i")) (EBinOp "::" (ETuple (ETuple (EVar "n") (EVar "i")) (EVar "c")) (EApp (EApp (EVar "lgTag") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "lgSplit" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "lgSplit" ((PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "lgSplit" ((PList (PVar "x"))) (ETuple (EListLit (EVar "x")) (EListLit)))
(DFunDef false "lgSplit" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EVar "lgSplit") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "x") (EVar "a")) (EBinOp "::" (EVar "y") (EVar "b"))))))
(DTypeSig false "lgSortName" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause")))))
(DFunDef false "lgSortName" ((PList)) (EListLit))
(DFunDef false "lgSortName" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "lgSortName" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EVar "lgSplit") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "lgMergeName") (EApp (EVar "lgSortName") (EVar "a"))) (EApp (EVar "lgSortName") (EVar "b"))))))
(DTypeSig false "lgMergeName" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))))))
(DFunDef false "lgMergeName" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "lgMergeName" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "lgMergeName" ((PCons (PTuple (PTuple (PVar "n1") (PVar "i1")) (PVar "c1")) (PVar "xs")) (PCons (PTuple (PTuple (PVar "n2") (PVar "i2")) (PVar "c2")) (PVar "ys"))) (EMatch (EApp (EApp (EVar "stringCompare") (EVar "n1")) (EVar "n2")) (arm (PCon "Lt") () (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EApp (EApp (EVar "lgMergeName") (EVar "xs")) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EVar "ys"))))) (arm (PCon "Gt") () (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EApp (EApp (EVar "lgMergeName") (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EVar "xs"))) (EVar "ys")))) (arm (PCon "Eq") () (EIf (EBinOp "<=" (EVar "i1") (EVar "i2")) (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EApp (EApp (EVar "lgMergeName") (EVar "xs")) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EVar "ys")))) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EApp (EApp (EVar "lgMergeName") (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EVar "xs"))) (EVar "ys")))))))
(DTypeSig false "lgRuns" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause"))))))
(DFunDef false "lgRuns" ((PList)) (EListLit))
(DFunDef false "lgRuns" ((PCons (PTuple (PTuple (PVar "n") (PVar "i")) (PVar "c")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "cs") (PVar "others")) (EApp (EApp (EVar "lgSpan") (EVar "n")) (EVar "rest"))) (DoExpr (EBinOp "::" (ETuple (ETuple (EVar "n") (EVar "i")) (EBinOp "::" (EVar "c") (EVar "cs"))) (EApp (EVar "lgRuns") (EVar "others"))))))
(DTypeSig false "lgSpan" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyTuple (TyApp (TyCon "List") (TyCon "CClause")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause")))))))
(DFunDef false "lgSpan" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "lgSpan" ((PVar "n") (PCons (PTuple (PTuple (PVar "m") (PVar "j")) (PVar "c")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EBlock (DoLet false false (PTuple (PVar "cs") (PVar "o")) (EApp (EApp (EVar "lgSpan") (EVar "n")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "c") (EVar "cs")) (EVar "o")))) (ETuple (EListLit) (EBinOp "::" (ETuple (ETuple (EVar "m") (EVar "j")) (EVar "c")) (EVar "rest")))))
(DTypeSig false "lgSortIdx" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause"))))))
(DFunDef false "lgSortIdx" ((PList)) (EListLit))
(DFunDef false "lgSortIdx" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "lgSortIdx" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EVar "lgSplit") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "lgMergeIdx") (EApp (EVar "lgSortIdx") (EVar "a"))) (EApp (EVar "lgSortIdx") (EVar "b"))))))
(DTypeSig false "lgMergeIdx" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))))))
(DFunDef false "lgMergeIdx" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "lgMergeIdx" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "lgMergeIdx" ((PCons (PTuple (PTuple (PVar "n1") (PVar "i1")) (PVar "cs1")) (PVar "xs")) (PCons (PTuple (PTuple (PVar "n2") (PVar "i2")) (PVar "cs2")) (PVar "ys"))) (EIf (EBinOp "<=" (EVar "i1") (EVar "i2")) (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "cs1")) (EApp (EApp (EVar "lgMergeIdx") (EVar "xs")) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "cs2")) (EVar "ys")))) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "cs2")) (EApp (EApp (EVar "lgMergeIdx") (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "cs1")) (EVar "xs"))) (EVar "ys")))))
(DTypeSig false "lgToBind" (TyFun (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause"))) (TyCon "CBind")))
(DFunDef false "lgToBind" ((PTuple (PTuple (PVar "n") PWild) (PVar "cs"))) (EApp (EApp (EVar "CBind") (EVar "n")) (EVar "cs")))
(DTypeSig false "lowerImpls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CImplEntry"))))
(DFunDef false "lowerImpls" ((PVar "prog")) (EApp (EApp (EVar "lowerImplsWith") (EApp (EVar "installDispatchTables") (EVar "prog"))) (EVar "prog")))
(DTypeSig true "lowerImplsWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CImplEntry")))))
(DFunDef false "lowerImplsWith" ((PVar "disp") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "lowerDeclImpl") (EVar "disp"))) (EVar "prog")))
(DTypeSig false "lowerDeclImpl" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "CImplEntry")))))
(DFunDef false "lowerDeclImpl" ((PVar "disp") (PRec "DImpl" ((rf "iface" (PVar "ifaceName")) (rf "tys" (PVar "typeArgs")) (rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "lowerImplMethod") (EVar "disp")) (EVar "ifaceName")) (EVar "typeArgs"))) (EVar "methods")))
(DFunDef false "lowerDeclImpl" (PWild (PRec "DInterface" ((rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "lowerDefault") (EVar "typeParams"))) (EVar "methods")))
(DFunDef false "lowerDeclImpl" (PWild PWild) (EListLit))
(DTypeSig false "lowerImplMethod" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "ImplMethod") (TyCon "CImplEntry"))))))
(DFunDef false "lowerImplMethod" ((PVar "disp") (PVar "ifaceName") (PVar "typeArgs") (PCon "ImplMethod" (PVar "mname") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "tag") (EApp (EApp (EVar "fromOption") (EVar "noneHeadTag")) (EApp (EVar "headTyconHead") (EVar "typeArgs")))) (DoLet false false (PVar "key") (EApp (EApp (EApp (EVar "implKeyOf") (EVar "ifaceName")) (EVar "typeArgs")) (EVar "None"))) (DoLet false false (PVar "positions") (EApp (EApp (EApp (EVar "lookupPositions") (EVar "ifaceName")) (EVar "mname")) (EVar "disp"))) (DoExpr (EApp (EApp (EApp (EVar "CImplEntry") (EVar "mname")) (EApp (EVar "tyvarsInArgs") (EVar "typeArgs"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "ifaceName")) (EVar "positions")) (EVar "pats")) (EApp (EVar "lower") (EVar "body")))))))
(DTypeSig false "lowerDefault" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "CImplEntry")))))
(DFunDef false "lowerDefault" (PWild (PCon "IfaceMethod" PWild PWild (PCon "None"))) (EListLit))
(DFunDef false "lowerDefault" ((PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") PWild (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))))) (EListLit (EApp (EApp (EApp (EVar "CImplEntry") (EVar "mname")) (EApp (EVar "listLen") (EVar "typeParams"))) (EApp (EApp (EVar "CImplDefault") (EVar "pats")) (EApp (EVar "lower") (EVar "body"))))))
(DTypeSig true "returnsSelfTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "returnsSelfTable" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ifaceReturnsSelfEntries")) (EVar "prog")))
(DTypeSig false "ifaceReturnsSelfEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "ifaceReturnsSelfEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "ifaceReturnsSelfEntry") (EVar "ifaceName")) (EVar "typeParams")) (EVar "m")))) (EVar "methods")))
(DFunDef false "ifaceReturnsSelfEntries" (PWild) (EListLit))
(DTypeSig false "ifaceReturnsSelfEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "ifaceReturnsSelfEntry" ((PVar "ifaceName") (PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild)) (ETuple (ETuple (EVar "ifaceName") (EVar "mname")) (EApp (EApp (EVar "tyMentionsParams") (EApp (EVar "methodResultTy") (EVar "mty"))) (EApp (EVar "headParamOnly") (EVar "typeParams")))))
(DTypeSig false "headParamOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "headParamOnly" ((PList)) (EListLit))
(DFunDef false "headParamOnly" ((PCons (PVar "p") PWild)) (EListLit (EVar "p")))
(DTypeSig false "methodResultTy" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "methodResultTy" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodResultTy") (EVar "t")))
(DFunDef false "methodResultTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "methodResultTy") (EVar "t")))
(DFunDef false "methodResultTy" ((PCon "TyFun" PWild (PVar "b"))) (EApp (EVar "methodResultTy") (EVar "b")))
(DFunDef false "methodResultTy" ((PVar "t")) (EVar "t"))
(DTypeSig false "tyMentionsParams" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyMentionsParams" ((PCon "TyVar" (PVar "n")) (PVar "params")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "params")))
(DFunDef false "tyMentionsParams" ((PCon "TyCon" PWild PWild) PWild) (EVar "False"))
(DFunDef false "tyMentionsParams" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsParams") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsParams" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsParams") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsParams" ((PCon "TyTuple" (PVar "ts")) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))) (EVar "ts")))
(DFunDef false "tyMentionsParams" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsParams" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))
(DTypeSig true "selfFnParamTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "selfFnParamTable" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ifaceSelfFnParamEntries")) (EVar "prog")))
(DTypeSig false "ifaceSelfFnParamEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "ifaceSelfFnParamEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "ifaceSelfFnParamEntry") (EVar "ifaceName")) (EVar "typeParams")) (EVar "m")))) (EVar "methods")))
(DFunDef false "ifaceSelfFnParamEntries" (PWild) (EListLit))
(DTypeSig false "ifaceSelfFnParamEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "ifaceSelfFnParamEntry" ((PVar "ifaceName") (PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild)) (ETuple (ETuple (EVar "ifaceName") (EVar "mname")) (EApp (EApp (EApp (EVar "selfFnPositions") (ELit (LInt 0))) (EApp (EVar "methodArgTys") (EVar "mty"))) (EVar "typeParams"))))
(DTypeSig false "methodArgTys" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "methodArgTys" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodArgTys") (EVar "t")))
(DFunDef false "methodArgTys" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "methodArgTys") (EVar "t")))
(DFunDef false "methodArgTys" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "a") (EApp (EVar "methodArgTys") (EVar "b"))))
(DFunDef false "methodArgTys" (PWild) (EListLit))
(DTypeSig true "methodIfaceTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "methodIfaceTable" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ifaceMethodArityEntries")) (EVar "prog")))
(DTypeSig false "ifaceMethodArityEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "ifaceMethodArityEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EVar "ifaceMethodArityEntry") (EVar "ifaceName")) (EVar "m")))) (EVar "methods")))
(DFunDef false "ifaceMethodArityEntries" (PWild) (EListLit))
(DTypeSig false "ifaceMethodArityEntry" (TyFun (TyCon "String") (TyFun (TyCon "IfaceMethod") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "ifaceMethodArityEntry" ((PVar "ifaceName") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild)) (ETuple (EVar "mname") (ETuple (EVar "ifaceName") (EApp (EVar "listLen") (EApp (EVar "methodArgTys") (EVar "mty"))))))
(DTypeSig true "methodConstraintIfaces" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodConstraintIfaces" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "methodConstraintIfaceEntries")) (EVar "prog")))
(DTypeSig false "methodConstraintIfaceEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodConstraintIfaceEntries" ((PRec "DInterface" ((rf "typarams" None) (rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "m")) (EApp (EApp (EVar "methodConstraintIfaceEntry") (EVar "typarams")) (EVar "m")))) (EVar "methods")))
(DFunDef false "methodConstraintIfaceEntries" (PWild) (EListLit))
(DTypeSig false "methodConstraintIfaceEntry" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "methodConstraintIfaceEntry" ((PVar "typarams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild)) (EBlock (DoLet false false (PVar "ifaces") (EApp (EApp (EVar "methodLevelConstraintIfaces") (EVar "typarams")) (EVar "mty"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "ifaces")) (EListLit) (EListLit (ETuple (EVar "mname") (EVar "ifaces")))))))
(DTypeSig false "methodLevelConstraintIfaces" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "methodLevelConstraintIfaces" ((PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "c")) (EApp (EApp (EVar "constraintIfaceIfMethodLevel") (EVar "typarams")) (EVar "c")))) (EVar "cs")) (EApp (EApp (EVar "methodLevelConstraintIfaces") (EVar "typarams")) (EVar "t"))))
(DFunDef false "methodLevelConstraintIfaces" ((PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "methodLevelConstraintIfaces") (EVar "typarams")) (EVar "t")))
(DFunDef false "methodLevelConstraintIfaces" (PWild PWild) (EListLit))
(DTypeSig false "constraintIfaceIfMethodLevel" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "constraintIfaceIfMethodLevel" ((PVar "typarams") (PCon "Constraint" (PVar "ifaceName") (PVar "args"))) (EIf (EApp (EApp (EVar "constraintArgsMentionNonParam") (EVar "typarams")) (EVar "args")) (EListLit (EVar "ifaceName")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "constraintArgsMentionNonParam" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "constraintArgsMentionNonParam" ((PVar "typarams") (PVar "args")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "typarams")))) (EVar "args")))
(DTypeSig false "tyMentionsNonParam" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyMentionsNonParam" ((PCon "TyVar" (PVar "n")) (PVar "params")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "params"))))
(DFunDef false "tyMentionsNonParam" ((PCon "TyCon" PWild PWild) PWild) (EVar "False"))
(DFunDef false "tyMentionsNonParam" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsNonParam") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsNonParam" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsNonParam") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsNonParam" ((PCon "TyTuple" (PVar "ts")) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))) (EVar "ts")))
(DFunDef false "tyMentionsNonParam" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsNonParam" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))
(DTypeSig true "ctorFieldTypeNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorFieldTypeNames" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ctorFieldTypeEntries")) (EVar "prog")))
(DTypeSig false "ctorFieldTypeEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorFieldTypeEntries" ((PCon "DData" PWild PWild PWild (PVar "variants") PWild)) (EApp (EApp (EMethodRef "map") (EVar "variantFieldTypeEntry")) (EVar "variants")))
(DFunDef false "ctorFieldTypeEntries" ((PCon "DNewtype" PWild PWild PWild (PVar "con") (PVar "fieldTy") PWild)) (EListLit (ETuple (EVar "con") (EListLit (EApp (EVar "tyHeadName") (EVar "fieldTy"))))))
(DFunDef false "ctorFieldTypeEntries" (PWild) (EListLit))
(DTypeSig false "variantFieldTypeEntry" (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "variantFieldTypeEntry" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PVar "tys")))) (ETuple (EVar "name") (EApp (EApp (EMethodRef "map") (EVar "tyHeadName")) (EVar "tys"))))
(DFunDef false "variantFieldTypeEntry" ((PCon "Variant" (PVar "name") (PCon "ConNamed" (PVar "fields") PWild))) (ETuple (EVar "name") (EApp (EApp (EMethodRef "map") (EVar "fieldTyHeadName")) (EVar "fields"))))
(DTypeSig false "fieldTyHeadName" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldTyHeadName" ((PCon "Field" PWild (PVar "ty"))) (EApp (EVar "tyHeadName") (EVar "ty")))
(DTypeSig false "tyHeadName" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "tyHeadName" ((PCon "TyCon" (PVar "n") PWild)) (EVar "n"))
(DFunDef false "tyHeadName" ((PCon "TyVar" (PVar "n"))) (EVar "n"))
(DFunDef false "tyHeadName" ((PCon "TyApp" (PVar "a") PWild)) (EApp (EVar "tyHeadName") (EVar "a")))
(DFunDef false "tyHeadName" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "tyHeadName" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "tyHeadName" (PWild) (ELit (LString "")))
(DTypeSig true "declSigTypeNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "declSigTypeNames" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "declSigTypeEntries")) (EVar "prog")))
(DTypeSig false "declSigTypeEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "declSigTypeEntries" ((PCon "DTypeSig" PWild (PVar "name") (PVar "ty"))) (EListLit (ETuple (EVar "name") (ETuple (EApp (EApp (EMethodRef "map") (EVar "tyHeadName")) (EApp (EVar "methodArgTys") (EVar "ty"))) (EApp (EVar "tyHeadName") (EApp (EVar "methodRetTy") (EVar "ty")))))))
(DFunDef false "declSigTypeEntries" ((PCon "DExtern" PWild (PVar "name") (PVar "ty"))) (EListLit (ETuple (EVar "name") (ETuple (EApp (EApp (EMethodRef "map") (EVar "tyHeadName")) (EApp (EVar "methodArgTys") (EVar "ty"))) (EApp (EVar "tyHeadName") (EApp (EVar "methodRetTy") (EVar "ty")))))))
(DFunDef false "declSigTypeEntries" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declSigTypeEntries") (EVar "inner")))
(DFunDef false "declSigTypeEntries" (PWild) (EListLit))
(DTypeSig false "methodRetTy" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "methodRetTy" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodRetTy") (EVar "t")))
(DFunDef false "methodRetTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "methodRetTy") (EVar "t")))
(DFunDef false "methodRetTy" ((PCon "TyFun" PWild (PVar "b"))) (EApp (EVar "methodRetTy") (EVar "b")))
(DFunDef false "methodRetTy" ((PVar "t")) (EVar "t"))
(DTypeSig false "selfFnPositions" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "selfFnPositions" (PWild (PList) PWild) (EListLit))
(DFunDef false "selfFnPositions" ((PVar "i") (PCons (PVar "t") (PVar "ts")) (PVar "params")) (EIf (EApp (EApp (EVar "tyIsFunReturningSelf") (EVar "t")) (EVar "params")) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EVar "selfFnPositions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "selfFnPositions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tyIsFunReturningSelf" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyIsFunReturningSelf" ((PCon "TyFun" PWild (PVar "b")) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EApp (EVar "methodResultTy") (EVar "b"))) (EVar "params")))
(DFunDef false "tyIsFunReturningSelf" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyIsFunReturningSelf") (EVar "t")) (EVar "params")))
(DFunDef false "tyIsFunReturningSelf" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyIsFunReturningSelf") (EVar "t")) (EVar "params")))
(DFunDef false "tyIsFunReturningSelf" (PWild PWild) (EVar "False"))
(DTypeSig false "funClausesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause")))))
(DFunDef false "funClausesOf" ((PList)) (EListLit))
(DFunDef false "funClausesOf" ((PCons (PCon "DFunDef" PWild (PVar "n") (PVar "pats") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EVar "lower") (EVar "body")))) (EApp (EVar "funClausesOf") (EVar "rest"))))
(DFunDef false "funClausesOf" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "letGroupClausesOf") (EVar "binds")) (EApp (EVar "funClausesOf") (EVar "rest"))))
(DFunDef false "funClausesOf" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "funClausesOf") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "funClausesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "funClausesOf") (EVar "rest")))
(DTypeSig false "letGroupClausesOf" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause")))))
(DFunDef false "letGroupClausesOf" ((PList)) (EListLit))
(DFunDef false "letGroupClausesOf" ((PCons (PCon "LetBind" (PVar "n") (PVar "clauses")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "lowerLetBind") (EVar "n"))) (EVar "clauses")) (EApp (EVar "letGroupClausesOf") (EVar "rest"))))
(DTypeSig false "lowerLetBind" (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyTuple (TyCon "String") (TyCon "CClause")))))
(DFunDef false "lowerLetBind" ((PVar "n") (PCon "FunClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "n") (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EVar "lower") (EVar "body")))))
(DTypeSig false "ctorArities" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "ctorArities" ((PList)) (EListLit))
(DFunDef false "ctorArities" ((PCons (PCon "DData" PWild PWild PWild (PVar "variants") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "variantArity")) (EVar "variants")) (EApp (EVar "ctorArities") (EVar "rest"))))
(DFunDef false "ctorArities" ((PCons (PCon "DNewtype" PWild PWild PWild (PVar "con") PWild PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "con") (ELit (LInt 1))) (EApp (EVar "ctorArities") (EVar "rest"))))
(DFunDef false "ctorArities" ((PCons PWild (PVar "rest"))) (EApp (EVar "ctorArities") (EVar "rest")))
(DTypeSig false "variantArity" (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "variantArity" ((PCon "Variant" (PVar "n") (PVar "payload"))) (ETuple (EVar "n") (EApp (EVar "payloadArityL") (EVar "payload"))))
(DTypeSig false "payloadArityL" (TyFun (TyCon "ConPayload") (TyCon "Int")))
(DFunDef false "payloadArityL" ((PCon "ConPos" (PVar "tys"))) (EApp (EVar "listLen") (EVar "tys")))
(DFunDef false "payloadArityL" ((PCon "ConNamed" (PVar "fs") PWild)) (EApp (EVar "listLen") (EVar "fs")))
(DTypeSig false "nodeTag" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "nodeTag" ((PCon "ESection" PWild)) (ELit (LString "ESection")))
(DFunDef false "nodeTag" ((PCon "EGuards" PWild)) (ELit (LString "EGuards")))
(DFunDef false "nodeTag" ((PCon "EDo" PWild)) (ELit (LString "EDo")))
(DFunDef false "nodeTag" ((PCon "EStringInterp" PWild)) (ELit (LString "EStringInterp")))
(DFunDef false "nodeTag" ((PCon "EVariantUpdate" PWild PWild PWild)) (ELit (LString "EVariantUpdate")))
(DFunDef false "nodeTag" ((PCon "EMapLit" PWild PWild)) (ELit (LString "EMapLit")))
(DFunDef false "nodeTag" ((PCon "ESetLit" PWild PWild)) (ELit (LString "ESetLit")))
(DFunDef false "nodeTag" ((PCon "EAsPat" PWild PWild)) (ELit (LString "EAsPat")))
(DFunDef false "nodeTag" ((PCon "EMethodRef" PWild)) (ELit (LString "EMethodRef")))
(DFunDef false "nodeTag" ((PCon "EDictApp" PWild)) (ELit (LString "EDictApp")))
(DFunDef false "nodeTag" (PWild) (ELit (LString "?")))
