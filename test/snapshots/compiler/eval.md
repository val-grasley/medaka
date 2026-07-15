# META
source_lines=3170
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted eval stage — Stage-1 capstone, port of lib/eval.ml's tree-walking
-- interpreter.  SLICE 1: the engine core — literals, variables, application,
-- lambdas, let / letrec / let-groups, match (with guards), if, binary/unary
-- operators, tuples, lists, ADTs (constructors + pattern matching), and
-- recursion.  Deferred to later slices: records/refs/arrays/string-interp/
-- ranges/index/slice, externs (VPrim primitives), and typeclass method dispatch
-- (VMulti tag-filtering / VTypedImpl / EMethodRef / EDictApp).
--
-- The interpreter runs on the OCaml reference (so this code may use the full
-- prelude); only the FIXTURES it evaluates must be self-contained / prelude-free.
-- Validated by rendering pp_value of a program's `main` binding and diffing
-- against dev/eval_probe.exe (Eval.eval_program ~prelude:false → Eval.pp_value).

import frontend.ast.{
  Loc(..),
  Lit(..),
  Ty(..),
  Addr(..),
  Pat(..),
  RecPatField(..),
  Guard(..),
  Arm(..),
  DoStmt(..),
  FieldAssign(..),
  FunClause(..),
  LetBind(..),
  Expr(..),
  Route(..),
  ConPayload(..),
  Field(..),
  Variant(..),
  IfaceMethod(..),
  MethodDefault(..),
  ImplMethod(..),
  UsePath(..),
  UseMember(..),
  useMemberOrigin,
  useMemberLocal,
  qualifiedLocal,
  Decl(..),
}
import support.util.{
  contains,
  listLen,
  reverseL,
  anyList,
  lookupAssoc,
  joinWith,
  fallthroughName,
  noneHeadTag,
  isEmptyL,
  filterList,
  initList,
  mapOption,
  joinDot,
  dedup,
}
-- Reused JSON diagnostic shaping for `medaka run --json` (RUNTIME-DIAGNOSTIC-
-- CHANNEL-DESIGN.md Fork C). diagnostics.mdk sits above frontend/types in the
-- pipeline and does not import eval.mdk (no cycle) — verified by grep before
-- adding this import.
import driver.diagnostics.{Diag(..), Severity(..), cjAllToJson}
-- The uint64 limb library the RNG/hash externs are built on lives in stdlib
-- (`bits64`) now — the compiler is a first-class consumer of it (issue #223).
-- It exports only a `U64` type ALIAS over a tuple, so the import drags no new
-- instance surface (near-free per AGENTS.md) and DCE trims to the fns used here.
import bits64.{
  add64,
  sub64,
  mulLow64,
  xor64,
  shr64,
  mod64,
  ofInt,
  isZero,
  limbAt,
}

-- ── values & environment (mutually recursive) ─────────────────────────────
-- B2 (RUN-EFFECTS): `Value` is EFFECT-POLYMORPHIC — `e` is the row its stored
-- arrows (VPrim / VThunk / VClosureF bodies) may perform.  The differential
-- oracle instantiates `e := <Mut>` (its purity is a type-level guarantee);
-- `medaka run` instantiates `e` at the I/O row its installed extern prims
-- need (see `ioExternBindings`).  `e` is kind-inferred KRow from the `<e>`
-- tails below.  NOTE: `EvalEnv` is deliberately parameterized over the VALUE
-- type `v` (kind *), not over the row — data-decl kind inference is
-- non-transitive (a param used only as another type's row argument is inferred
-- KType and mis-elaborates), so wrapper types thread `Value e` whole.
public export data Value e =
  | VInt Int
  | VFloat Float
  | VString String
  | VChar String
  | VBool Bool
  | VUnit
  | VTuple (List (Value e))
  | VList (List (Value e))
  | VArray (Array (Value e))
  | VCon String (List (Value e))
  | VRecord String (List (String, Value e))
  | VRef (Ref (Value e))
  | VClosure (EvalEnv (Value e)) (List Pat) Expr
  -- like VClosure, but the body is an opaque host function over the fully-
  -- extended env rather than an AST `Expr` — the closure form the Core IR
  -- evaluator (core_ir_eval.mdk) builds, so it can reuse this runtime's apply /
  -- dispatch / fall-through machinery without eval.mdk depending on core_ir.mdk.
  -- A multi-param VClosureF threads param binds through `env` exactly as
  -- VClosure does (partial application keeps the same body fn, growing env).
  | VClosureF (EvalEnv (Value e)) (List Pat) (EvalEnv (Value e) -> <e> Value e)
  | VPrim (Value e -> <e> Value e)
  | VMulti (List (Value e))
  -- a deferred top-level nullary binding; forced + memoised on first lookup, so
  -- point-free defs can reference impls/values installed later (any order)
  | VThunk (Unit -> <e> Value e)
  -- sentinel for `__fallthrough__ ()`: a guard chain fell through, so the
  -- enclosing clause "did not match" and dispatch should try the next one
  -- (stands in for the reference's Impl_no_match exception)
  | VFallthrough
  -- an impl method tagged for typeclass dispatch: head type, impl key, the arg
  -- positions that discriminate, args applied so far, and the underlying value
  | VTypedImpl String String (List Int) Int (Value e)
  -- a runtime dictionary: the impl head tag a constrained function was called at,
  -- passed as a leading argument (EDictAt builds it, dict_pass binds it as a
  -- parameter); an in-body EMethodAt routed RDict reads it to narrow its method.
  -- Phase 83/84 #5: the value list carries this impl's own requires dicts (each
  -- itself a VDict), so a recursive instance (def : List (List Int)) unfolds
  -- level by level — the inner return-position `def` reads its element dict from
  -- the forwarded requires rather than failing arg-tag dispatch.
  | VDict String (List (Value e))

-- an environment is a stack of frames; each frame maps names to mutable cells
-- (so letrec / mutual recursion can back-patch a closure's own binding).
-- Parameterized over the VALUE type (`v := Value e`), not the row — see the
-- kind-inference note on `Value`.
public export data EvalEnv v = EvalEnv (List (List (String, Ref v)))

-- ── value rendering (mirrors lib/eval.ml pp_value byte-for-byte) ───────────
export ppValue : Value e -> String
ppValue (VInt n) = intToString n
ppValue (VFloat f) = floatToString f
ppValue (VString s) = s
ppValue (VChar c) = c
ppValue (VBool True) = "true"
ppValue (VBool False) = "false"
ppValue VUnit = "()"
ppValue (VTuple vs) = "(" ++ joinComma (map ppValue vs) ++ ")"
ppValue (VList vs) = "[" ++ joinComma (map ppValue vs) ++ "]"
ppValue (VArray vs) = "[|" ++ joinComma (map ppValue (arrayToListG vs)) ++ "|]"
ppValue (VCon name []) = name
ppValue (VCon name vs) = "\{name} \{joinSp (map ppValueAtom vs)}"
ppValue (VRecord name fields) = "\{name} { \{joinComma (map ppField fields)} }"
ppValue (VRef cell) = "Ref(" ++ ppValue cell.value ++ ")"
ppValue (VClosure _ _ _) = "<closure>"
ppValue (VClosureF _ _ _) = "<closure>"
ppValue (VPrim _) = "<prim>"
ppValue (VMulti vs) = "<dispatch/" ++ intToString (listLen vs) ++ ">"
ppValue (VTypedImpl t _ _ _ inner) = "<impl@\{t}:\{ppValue inner}>"
ppValue (VThunk _) = "<thunk>"
ppValue (VDict key _) = "<dict:" ++ key ++ ">"
ppValue VFallthrough = "<fallthrough>"

ppField : (String, Value e) -> String
ppField (k, v) = "\{k} = \{ppValue v}"

-- parenthesize compound atoms (VCon with args / tuples) when nested
ppValueAtom : Value e -> String
ppValueAtom (VCon name (x::xs)) = "(" ++ ppValue (VCon name (x::xs)) ++ ")"
ppValueAtom (VTuple vs) = "(" ++ ppValue (VTuple vs) ++ ")"
ppValueAtom v = ppValue v

joinComma : List String -> String
joinComma xs = joinWith ", " xs

joinSp : List String -> String
joinSp xs = joinWith " " xs

-- ── small helpers ─────────────────────────────────────────────────────────
arrayToListG : Array a -> List a
arrayToListG arr = arrayToListGo arr 0 (arrayLength arr)

arrayToListGo : Array a -> Int -> Int -> List a
arrayToListGo arr i n
  | i >= n = []
  | otherwise = arrayGetUnsafe i arr :: arrayToListGo arr (i + 1) n

intSeq : Int -> Int -> List Int
intSeq lo end
  | lo >= end = []
  | otherwise = lo :: intSeq (lo + 1) end

-- Retained for the Core-IR interpreter's CIndex/CStringIndex/CListIndex arms
-- (core_ir_eval.ceval).  Those Core-IR nodes are now unreachable — EIndex is
-- desugared to an `index` method call before lowering (Phase #16b) — but kept in
-- place (tier ii) to shrink the diff, so their eval helper stays too.
listNthAt : List (Value e) -> Int -> Int -> Value e
listNthAt [] orig _ =
  runtimePanic "E-INDEX-OOB" ("index " ++ intToString orig ++ " out of bounds")
listNthAt (x::xs) orig i
  | i <= 0 = x
  | otherwise = listNthAt xs orig (i - 1)

listSliceV : List (Value e) -> Int -> Int -> List (Value e)
listSliceV xs lo hi = listSliceGo xs 0 lo hi

listSliceGo : List (Value e) -> Int -> Int -> Int -> List (Value e)
listSliceGo [] _ _ _ = []
listSliceGo (x::xs) i lo hi
  | i >= hi = []
  | i >= lo = x :: listSliceGo xs (i + 1) lo hi
  | otherwise = listSliceGo xs (i + 1) lo hi

export startsWithAt : String -> Bool
startsWithAt s =
  let cs = stringToChars s
  arrayLength cs > 0 && arrayGetUnsafe 0 cs == '@'

containsInt : Int -> List Int -> Bool
containsInt _ [] = False
containsInt x (y::ys) = x == y || containsInt x ys

-- ── typeclass dispatch: ctor→type table + runtime tag ─────────────────────
-- A process-global ctor→type map (mirrors lib/eval.ml's ctor_to_type Hashtbl);
-- evalProgram seeds it before any dispatch.  Reading it stays pure (ref read).
export ctorToTypeRef : Ref (List (String, String))
ctorToTypeRef = Ref []

export buildCtorToType : List Decl -> List (String, String)
buildCtorToType prog = flatMap ctorTypeEntries prog

ctorTypeEntries : Decl -> List (String, String)
ctorTypeEntries (DData _ tyname _ variants _) =
  map (v => (variantName v, tyname)) variants
ctorTypeEntries (DNewtype _ tyname _ con _ _) = [(con, tyname)]
ctorTypeEntries _ = []

variantName : Variant -> String
variantName (Variant n _) = n

-- named-field constructor field order: maps ctor name → ordered field name list.
-- Only ConNamed variants produce entries; positional ConPos ones produce nothing.
export ctorFieldOrdersRef : Ref (List (String, List String))
ctorFieldOrdersRef = Ref []

-- ARGSTAMP-UNIFY / genuine #21: per (impl-method-name, head-tag) the number of
-- LEADING element-dict params the impl method consumes = (elaborated impl pattern
-- count) - (declared method arity from the interface).  An arg-position RDict site
-- forwards the dispatch dict's nested reqs, but the dict can be OVER-provisioned
-- (the structural dict route + the requires-only impl table can attribute an
-- element req to a List-tagged dict even when THIS method's List impl has no
-- `requires` — two interfaces sharing the head tag).  Emit tolerates this (its
-- dispatch chain loads only reqCount of the matched impl); eval must too: forward
-- only the first reqCount of the dict's reqs.  None ⇒ no entry ⇒ method takes 0
-- leading dicts (forward none).
methodReqCountRef : Ref (List ((String, String), Int))
methodReqCountRef = Ref []

export buildMethodReqCounts : List Decl -> List ((String, String), Int)
buildMethodReqCounts prog =
  let arities = flatMap methodDeclArities prog
  flatMap (implMethodReqCounts arities) prog

-- declared arity of each interface method = number of value args in its signature.
methodDeclArities : Decl -> List (String, Int)
methodDeclArities (DAttrib _ d) = methodDeclArities d
methodDeclArities (DInterface { methods, ... }) = map ifaceMethodArity methods
methodDeclArities _ = []

ifaceMethodArity : IfaceMethod -> (String, Int)
ifaceMethodArity (IfaceMethod mname mty _) = (mname, listLen (argsOfTy mty))

-- one ((method, tag), reqCount) per impl method; reqCount = impl pats - declared arity.
implMethodReqCounts : List (String, Int) -> Decl -> List ((String, String), Int)
implMethodReqCounts arities (DAttrib _ d) = implMethodReqCounts arities d
implMethodReqCounts arities (DImpl { tys = typeArgs, methods, ... }) = match headTyconHead typeArgs
  Some tag => flatMap (implMethodReqCountEntry arities tag) methods
  None => []
implMethodReqCounts _ _ = []

implMethodReqCountEntry : List (String, Int) -> String -> ImplMethod -> List ((String, String), Int)
implMethodReqCountEntry arities tag (ImplMethod mname pats _) =
  let declArity = fromOption (listLen pats) (lookupAssoc mname arities)
  let reqCount = subClampZero (listLen pats) declArity
  [((mname, tag), reqCount)]

subClampZero : Int -> Int -> Int
subClampZero a b = if a - b < 0 then 0 else a - b

takeN : Int -> List a -> List a
takeN n _
  | n <= 0 = []
takeN _ [] = []
takeN n (x::rest) = x :: takeN (n - 1) rest

lookupMethodReqCount : String -> String -> Int
lookupMethodReqCount mname tag =
  lookupReqCount mname tag methodReqCountRef.value

lookupReqCount : String -> String -> List ((String, String), Int) -> Int
lookupReqCount _ _ [] = 0
lookupReqCount mname tag (((m, t), c)::rest)
  | m == mname && t == tag = c
  | otherwise = lookupReqCount mname tag rest

export buildCtorFieldOrders : List Decl -> List (String, List String)
buildCtorFieldOrders prog = flatMap ctorFieldOrderEntries prog

ctorFieldOrderEntries : Decl -> List (String, List String)
ctorFieldOrderEntries (DData _ _ _ variants _) =
  flatMap variantFieldOrder variants
ctorFieldOrderEntries _ = []

variantFieldOrder : Variant -> List (String, List String)
variantFieldOrder (Variant n (ConNamed fs _)) = [(n, map fieldName fs)]
variantFieldOrder _ = []

fieldName : Field -> String
fieldName (Field n _) = n

-- runtime "head type" tag for a value, for filtering VMulti candidates
runtimeTypeTag : Value e -> Option String
runtimeTypeTag (VInt _) = Some "Int"
runtimeTypeTag (VFloat _) = Some "Float"
runtimeTypeTag (VString _) = Some "String"
runtimeTypeTag (VChar _) = Some "Char"
runtimeTypeTag (VBool _) = Some "Bool"
runtimeTypeTag VUnit = Some "Unit"
runtimeTypeTag (VList _) = Some "List"
runtimeTypeTag (VArray _) = Some "Array"
runtimeTypeTag (VTuple vs) = Some (tupleHeadTag (listLen vs))
runtimeTypeTag (VCon cname _) = lookupAssoc cname ctorToTypeRef.value
runtimeTypeTag (VRecord name _) = Some name
runtimeTypeTag (VTypedImpl t _ _ _ _) = Some t
runtimeTypeTag _ = None

-- ── type-structure analysis (specificity + dispatch positions) ────────────
countTyvars : Ty -> Int
countTyvars (TyVar _) = 1
countTyvars (TyCon _ _) = 0
countTyvars (TyApp a b) = countTyvars a + countTyvars b
countTyvars (TyFun a b) = countTyvars a + countTyvars b
countTyvars (TyTuple ts) = sumInts (map countTyvars ts)
countTyvars (TyEffect _ _ t) = countTyvars t
countTyvars (TyConstrained _ t) = countTyvars t

sumInts : List Int -> Int
sumInts [] = 0
sumInts (x::xs) = x + sumInts xs

export tyvarsInArgs : List Ty -> Int
tyvarsInArgs ts = sumInts (map countTyvars ts)

-- TYPECHECK-AUDIT C7: the canonical impl key, mirroring lib/ast.ml's `impl_key`
-- byte-for-byte: `iface ++ "|" ++ <type args, prec-2 pretty> ++ "|" ++ name`.
-- Built from the same source (the impl's AST type args) here at install time and
-- by typecheck at each ground RKey route site, so the two strings agree by
-- construction.  Two impls sharing a head tycon but differing type args
-- (Pair Int Bool vs Pair Bool Int) get DISTINCT keys, so narrowing can pick the
-- one the typechecker chose instead of falling to first-impl-wins.
export implKeyOf : String -> List Ty -> Option String -> String
implKeyOf iface typeArgs nm =
  "\{iface}|\{joinWith " " (map ppTyAtomK typeArgs)}|\{fromOption "" nm}"

-- prec-2 Ty pretty-printer (mirrors lib/ast.ml pp_ty_prec 2 / typecheck's
-- ppTyAtom): wraps applications and arrows, leaves atoms bare.
ppTyK : Ty -> String
ppTyK (TyCon n _) = n
ppTyK (TyVar n) = n
ppTyK (TyApp a b) = "\{ppTyK a} \{ppTyAtomK b}"
ppTyK (TyFun a b) = "\{ppTyFunArgK a} -> \{ppTyK b}"
ppTyK (TyTuple ts) = "(" ++ joinComma (map ppTyK ts) ++ ")"
ppTyK (TyEffect _ _ t) = ppTyK t
ppTyK (TyConstrained _ t) = ppTyK t

ppTyFunArgK : Ty -> String
ppTyFunArgK (TyFun a b) = "(" ++ ppTyK (TyFun a b) ++ ")"
ppTyFunArgK t = ppTyK t

ppTyAtomK : Ty -> String
ppTyAtomK (TyFun a b) = "(" ++ ppTyK (TyFun a b) ++ ")"
ppTyAtomK (TyApp a b) = "(" ++ ppTyK (TyApp a b) ++ ")"
ppTyAtomK t = ppTyK t

-- Native Gap C: an ARITY-DISTINGUISHED tuple dispatch/impl-tag (`__tuple2__`,
-- `__tuple3__`, …).  Each tuple arity gets its OWN impl group / lifted define and
-- its own runtime dispatch tag, so the 2-/3-/4-/5-tuple `Eq`/`Ord`/`Debug` impls
-- no longer coalesce under one mis-arity'd `__tuple__` group.  This is the
-- DISPATCH namespace; it is deliberately distinct from core_ir_lower's MATCH
-- pattern-canonical `tupleName = "__tuple__"` (which stays arity-erased — a match
-- column is arity-homogeneous and carries its arity in HTuple).
export tupleHeadTag : Int -> String
tupleHeadTag n = "__tuple" ++ intToString n ++ "__"

headTycon : Ty -> Option String
headTycon (TyCon n _) = Some n
headTycon (TyApp a _) = headTycon a
headTycon (TyConstrained _ t) = headTycon t
headTycon (TyEffect _ _ t) = headTycon t
headTycon (TyTuple ts) = Some (tupleHeadTag (listLen ts))
headTycon _ = None

-- arg positions of a method type that mention an interface type parameter
dispatchPositionsOf : Ty -> List String -> List Int
dispatchPositionsOf mty params = filterMentions 0 (argsOfTy mty) params

argsOfTy : Ty -> List Ty
argsOfTy (TyConstrained _ t) = argsOfTy t
argsOfTy (TyEffect _ _ t) = argsOfTy t
argsOfTy (TyFun a b) = a :: argsOfTy b
argsOfTy _ = []

filterMentions : Int -> List Ty -> List String -> List Int
filterMentions _ [] _ = []
filterMentions i (t::ts) params
  | tyMentions t params = i :: filterMentions (i + 1) ts params
  | otherwise = filterMentions (i + 1) ts params

tyMentions : Ty -> List String -> Bool
tyMentions (TyVar n) params = contains n params
tyMentions (TyCon _ _) _ = False
tyMentions (TyApp a b) params = tyMentions a params || tyMentions b params
tyMentions (TyFun a b) params = tyMentions a params || tyMentions b params
tyMentions (TyTuple ts) params = anyList (t => tyMentions t params) ts
tyMentions (TyEffect _ _ t) params = tyMentions t params
tyMentions (TyConstrained _ t) params = tyMentions t params

-- ── environment ───────────────────────────────────────────────────────────
export lookupEnv : EvalEnv (Value e) -> String -> <e> Value e
lookupEnv (EvalEnv frames) name = lookupFrames frames name

lookupFrames : List (List (String, Ref (Value e))) -> String -> <e> Value e
lookupFrames [] name = panic ("unbound identifier: " ++ name)
lookupFrames (frame::rest) name = match lookupFrameCell frame name
  Some cell => forceCell cell name
  None => lookupFrames rest name

-- C5 (mirror lib/eval.ml:223 lookup_method): resolve a method occurrence to the
-- coalesced method binding (the dispatcher), looking PAST a nearer same-named
-- non-method shadow.  This matters only when a name is both an interface method and
-- an explicitly-imported standalone (e.g. box's `toList`/`isEmpty` vs Foldable's):
-- evalModules binds the import in a frame AHEAD of the global method binding, so a
-- plain lookupEnv returns the standalone even for a genuine method call.  Walk frames,
-- returning the first METHOD binding — a bare VTypedImpl (single-impl method) or a
-- VMulti whose candidates are VTypedImpls (multi-impl method); a standalone shadow
-- (a VClosure, or a VMulti of plain VClosures from a multi-clause standalone) is
-- skipped.  If no frame binds a method, fall back to the nearest binding (normal
-- lookup) — preserving every non-collision case, where the nearest binding IS the
-- method.  NOTE: in this runtime EVERY top-level group installs as a VMulti (even a
-- single-clause standalone), so the OCaml "first VMulti wins" test is too coarse —
-- the candidates' shape (VTypedImpl vs VClosure) is the real discriminator.
export lookupMethod : EvalEnv (Value e) -> String -> <e> Value e
lookupMethod (EvalEnv frames) name = lookupMethodFrames frames frames name

lookupMethodFrames : List (List (String, Ref (Value e))) -> List (List (String, Ref (Value e))) -> String -> <e> Value e
lookupMethodFrames all [] name = lookupFrames all name
lookupMethodFrames all (frame::rest) name = match lookupFrameCell frame name
  Some cell =>
    if isMethodBinding (forceCell cell name) then
      forceCell cell name
    else
      lookupMethodFrames all rest name
  None => lookupMethodFrames all rest name

-- a method dispatcher binding: a bare VTypedImpl, or a VMulti containing at least one
-- VTypedImpl candidate.  A standalone function (VClosure / VMulti of VClosures) is not.
isMethodBinding : Value e -> Bool
isMethodBinding (VTypedImpl _ _ _ _ _) = True
isMethodBinding (VMulti vs) = anyTypedImpl vs
isMethodBinding _ = False

anyTypedImpl : List (Value e) -> Bool
anyTypedImpl [] = False
anyTypedImpl ((VTypedImpl _ _ _ _ _)::_) = True
anyTypedImpl (_::rest) = anyTypedImpl rest

-- read a cell, forcing + memoising a deferred thunk on first access
-- P0-2(b): black-hole a lazy cell while it is being forced so a non-productive
-- self-reference (`xs = 1 :: xs`; top-level nullary bindings are LAZY and `::`
-- is STRICT, so forcing `xs` re-forces `xs`) is caught as a clean coded
-- E-CYCLIC-VALUE instead of self-forcing to a stack-overflow crash.  Before
-- running the thunk we overwrite the cell with a black-hole thunk that panics
-- if re-entered; on success we memoise the real value, clearing the mark.
forceCell : Ref (Value e) -> String -> <e> Value e
forceCell cell name = match cell.value
  VThunk f => forceMemo cell name f
  v => v

forceMemo : Ref (Value e) -> String -> (Unit -> <e> Value e) -> <e> Value e
forceMemo cell name f =
  let _ = setRef cell (VThunk (blackholeCell name))
  let v = f ()
  let _ = setRef cell v
  v

-- The thunk a cell holds *while it is being forced*.  Re-entering the force of
-- the same cell runs this and raises E-CYCLIC-VALUE, naming the binding.
blackholeCell : String -> Unit -> <e> Value e
blackholeCell name _ =
  runtimePanic
    "E-CYCLIC-VALUE"
    "\{name} refers to itself during initialization (non-productive cyclic value)"

export force : Value e -> <e> Value e
force (VThunk f) = f ()
force v = v

lookupFrameCell : List (String, Ref (Value e)) -> String -> Option (Ref (Value e))
lookupFrameCell [] _ = None
lookupFrameCell ((n, cell)::rest) name
  | n == name = Some cell
  | otherwise = lookupFrameCell rest name

-- ── lexical-address lookup (consumes annotate.mdk's EVarAt; DORMANT, §2.0) ──
-- AGlobal falls back to the by-name scan — identical semantics: it reaches a
-- top-level / prelude / global-method cell past any local frame (the self-host
-- analog of the OCaml lookup_method shadow-bypass).  ALocal indexes (frame,
-- slot) directly; the name check guards against any emit/consume frame-model
-- divergence with a loud panic (never silent corruption).  Frames stay a
-- `List (List ..)`: switching to array frames for true O(1) slot indexing was
-- measured a clear regression under the tree-walker (per-frame `arrayFromList`
-- cost > the by-name scan it saves), so the rep is unchanged — see PERF-NOTES.
lookupAtAddr : EvalEnv (Value e) -> String -> Addr -> <e> Value e
lookupAtAddr env name AGlobal = lookupEnv env name
lookupAtAddr (EvalEnv frames) name (ALocal depth slot) =
  forceCell (addrCell (frameAtDepth frames depth name) slot name) name

frameAtDepth : List (List (String, Ref (Value e))) -> Int -> String -> List (String, Ref (Value e))
frameAtDepth [] _ name = panic ("EVarAt: frame depth out of range for " ++ name)
frameAtDepth (frame::rest) depth name
  | depth <= 0 = frame
  | otherwise = frameAtDepth rest (depth - 1) name

addrCell : List (String, Ref (Value e)) -> Int -> String -> Ref (Value e)
addrCell [] _ name = panic ("EVarAt: slot out of range for " ++ name)
addrCell ((n, cell)::rest) slot name
  | slot > 0 = addrCell rest (slot - 1) name
  | n == name = cell
  | otherwise = panic "EVarAt: slot/name mismatch; want \{name}, found \{n}"

export extendEnv : EvalEnv (Value e) -> List (String, Value e) -> EvalEnv (Value e)
extendEnv (EvalEnv frames) binds = EvalEnv (map cellOf binds :: frames)

cellOf : (String, Value e) -> (String, Ref (Value e))
cellOf (n, v) = (n, Ref v)

export pushFrame : EvalEnv (Value e) -> List (String, Ref (Value e)) -> EvalEnv (Value e)
pushFrame (EvalEnv frames) frame = EvalEnv (frame::frames)

export findCell : List (String, Ref (Value e)) -> String -> Ref (Value e)
findCell [] name = panic ("findCell: missing " ++ name)
findCell ((n, cell)::rest) name
  | n == name = cell
  | otherwise = findCell rest name

-- ── structural equality & ordering (mirror OCaml = / compare on `value`) ───
valueEq : Value e -> Value e -> Bool
valueEq (VInt a) (VInt b) = a == b
valueEq (VFloat a) (VFloat b) = a == b
valueEq (VString a) (VString b) = a == b
valueEq (VChar a) (VChar b) = a == b
valueEq (VBool a) (VBool b) = boolEq a b
valueEq VUnit VUnit = True
valueEq (VTuple a) (VTuple b) = valueListEq a b
valueEq (VList a) (VList b) = valueListEq a b
valueEq (VArray a) (VArray b) = valueListEq (arrayToListG a) (arrayToListG b)
valueEq (VCon n1 a1) (VCon n2 a2) = n1 == n2 && valueListEq a1 a2
valueEq (VRecord n1 f1) (VRecord n2 f2) = n1 == n2 && fieldListEq f1 f2
valueEq (VRef a) (VRef b) = valueEq a.value b.value
valueEq _ _ = False

valueListEq : List (Value e) -> List (Value e) -> Bool
valueListEq [] [] = True
valueListEq (x::xs) (y::ys) = valueEq x y && valueListEq xs ys
valueListEq _ _ = False

fieldListEq : List (String, Value e) -> List (String, Value e) -> Bool
fieldListEq [] [] = True
fieldListEq ((k1, v1)::r1) ((k2, v2)::r2) = k1 == k2
  && valueEq v1 v2
  && fieldListEq r1 r2
fieldListEq _ _ = False

boolEq : Bool -> Bool -> Bool
boolEq True True = True
boolEq False False = True
boolEq _ _ = False

boolToInt : Bool -> Int
boolToInt False = 0
boolToInt True = 1

valueTag : Value e -> Int
valueTag (VInt _) = 0
valueTag (VFloat _) = 1
valueTag (VString _) = 2
valueTag (VChar _) = 3
valueTag (VBool _) = 4
valueTag VUnit = 5
valueTag (VTuple _) = 6
valueTag (VList _) = 7
valueTag (VArray _) = 8
valueTag (VCon _ _) = 9
valueTag (VRecord _ _) = 10
valueTag (VRef _) = 11
valueTag _ = 99

valueCompare : Value e -> Value e -> Ordering
valueCompare (VInt a) (VInt b) = compare a b
valueCompare (VFloat a) (VFloat b) = compare a b
valueCompare (VString a) (VString b) = compare a b
valueCompare (VChar a) (VChar b) = stringCompare a b
valueCompare (VBool a) (VBool b) = compare (boolToInt a) (boolToInt b)
valueCompare VUnit VUnit = Eq
valueCompare (VList a) (VList b) = compareValueLists a b
valueCompare (VArray a) (VArray b) =
  compareValueLists (arrayToListG a) (arrayToListG b)
valueCompare (VTuple a) (VTuple b) = compareValueLists a b
valueCompare (VCon n1 a1) (VCon n2 a2) = match compare n1 n2
  Eq => compareValueLists a1 a2
  o => o
valueCompare a b = compare (valueTag a) (valueTag b)

compareValueLists : List (Value e) -> List (Value e) -> Ordering
compareValueLists [] [] = Eq
compareValueLists [] (_::_) = Lt
compareValueLists (_::_) [] = Gt
compareValueLists (x::xs) (y::ys) = match valueCompare x y
  Eq => compareValueLists xs ys
  o => o

ordLt : Ordering -> Bool
ordLt Lt = True
ordLt _ = False

ordGt : Ordering -> Bool
ordGt Gt = True
ordGt _ = False

-- ── pattern matching ──────────────────────────────────────────────────────
export matchPat : Pat -> Value e -> Option (List (String, Value e))
matchPat (PVar x) v = Some [(x, v)]
matchPat PWild _ = Some []
matchPat (PLit (LInt n)) (VInt m) = if n == m then Some [] else None
matchPat (PLit (LFloat f)) (VFloat g) = if f == g then Some [] else None
matchPat (PLit (LString s)) (VString t) = if s == t then Some [] else None
matchPat (PLit (LChar c)) (VChar d) = if c == d then Some [] else None
matchPat (PLit (LBool b)) (VBool c) = if boolEq b c then Some [] else None
matchPat (PLit LUnit) VUnit = Some []
matchPat (PCon "True" []) (VBool True) = Some []
matchPat (PCon "False" []) (VBool False) = Some []
matchPat (PCon name pats) (VCon name2 vals)
  | name == name2 && listLen pats == listLen vals = matchPats pats vals
  | otherwise = None
matchPat (PCons h t) (VList (x::xs)) = matchCons h t x xs
matchPat (PCons _ _) (VList []) = None
matchPat (PTuple pats) (VTuple vals)
  | listLen pats == listLen vals = matchPats pats vals
  | otherwise = None
matchPat (PList pats) (VList vals)
  | listLen pats == listLen vals = matchPats pats vals
  | otherwise = None
matchPat (PAs x p) v = matchAs x p v
matchPat (PRec _ fields _) (VRecord _ recFields) =
  matchRecFields fields recFields
matchPat (PRec ctor fields _) (VCon ctor2 vals)
  | ctor == ctor2 = match lookupAssoc ctor ctorFieldOrdersRef.value
    Some order => matchRecFields fields (zipFieldOrder order vals)
    None => None
  | otherwise = None
matchPat (PRng (LInt lo) (LInt hi) incl) (VInt v)
  | inIntRange v lo hi incl = Some []
matchPat (PRng (LChar lo) (LChar hi) incl) (VChar c)
  | inCharRange c lo hi incl = Some []
matchPat _ _ = None

inIntRange : Int -> Int -> Int -> Bool -> Bool
inIntRange v lo hi incl = v >= lo && v <= (if incl then hi else hi - 1)

inCharRange : String -> String -> String -> Bool -> Bool
inCharRange c lo hi incl = not (ordLt (stringCompare c lo))
  && charUpper c hi incl

charUpper : String -> String -> Bool -> Bool
charUpper c hi True = not (ordGt (stringCompare c hi))
charUpper c hi False = ordLt (stringCompare c hi)

matchRecFields : List RecPatField -> List (String, Value e) -> Option (List (String, Value e))
matchRecFields [] _ = Some []
matchRecFields ((RecPatField fname mp)::rest) recFields = match lookupAssoc fname recFields
  None => None
  Some v => matchRecField fname mp v rest recFields

-- Zip a registered ctor's field order with its positional VCon vals into a
-- name->value assoc, so a record pattern can match a named-field data variant
-- (mirrors lib/eval.ml match_pat's PRec/VCon arm via ctor_field_order).
zipFieldOrder : List String -> List (Value e) -> List (String, Value e)
zipFieldOrder [] _ = []
zipFieldOrder _ [] = []
zipFieldOrder (f::fs) (v::vs) = (f, v) :: zipFieldOrder fs vs

matchRecField : String -> Option Pat -> Value e -> List RecPatField -> List (String, Value e) -> Option (List (String, Value e))
matchRecField fname None v rest recFields =
  map ((fname, v) :: _) (matchRecFields rest recFields)
matchRecField _ (Some q) v rest recFields = match matchPat q v
  None => None
  Some b => map (b ++ _) (matchRecFields rest recFields)

matchCons : Pat -> Pat -> Value e -> List (Value e) -> Option (List (String, Value e))
matchCons h t x xs = match matchPat h x
  None => None
  Some b1 => map (b1 ++ _) (matchPat t (VList xs))

matchAs : String -> Pat -> Value e -> Option (List (String, Value e))
matchAs x p v = map ((x, v) :: _) (matchPat p v)

matchPats : List Pat -> List (Value e) -> Option (List (String, Value e))
matchPats [] [] = Some []
matchPats (p::ps) (v::vs) = match matchPat p v
  None => None
  Some b => map (b ++ _) (matchPats ps vs)
matchPats _ _ = None

-- ── constructor builders ──────────────────────────────────────────────────
export makeCtor : String -> Int -> Value e
makeCtor name arity = makeCtorGo name arity []

makeCtorGo : String -> Int -> List (Value e) -> Value e
makeCtorGo name arity acc
  | arity <= 0 = VCon name (reverseL acc)
  | otherwise = VPrim (v => makeCtorGo name (arity - 1) (v::acc))

-- ── application ───────────────────────────────────────────────────────────
-- non-colliding alias of `apply` for importers: the prelude (core.mdk) also
-- binds `apply` (function application), so `import eval.{apply}` is ambiguous at
-- a call site; `applyValue` lets core_ir_eval.mdk reuse this runtime's value
-- application unambiguously.
export applyValue : Value e -> Value e -> <e> Value e
applyValue f x = apply f x

-- P0-2(a): guard the host C-stack against unbounded non-tail recursion.  We
-- increment a depth counter on entry, raise a clean E-STACK-OVERFLOW past the
-- limit, and decrement on the balanced return (a runtimePanic is noreturn, so a
-- tripped guard just exits — the counter never needs unwinding).
export apply : Value e -> Value e -> <e> Value e
apply f x =
  let d = evalDepthRef.value + 1
  let _ = setRef evalDepthRef d
  let _ = if d > evalDepthLimit then
    runtimePanic "E-STACK-OVERFLOW" "recursion too deep (evaluator call depth exceeded \{intToString evalDepthLimit}); the tree-walking interpreter has no tail-call optimisation"
  else
    ()
  let r = applyDispatch f x
  let _ = setRef evalDepthRef (d - 1)
  r

applyDispatch : Value e -> Value e -> <e> Value e
applyDispatch f x = match applyOpt f x
  Some v => v
  None => runtimePanic "E-NONEXHAUSTIVE-MATCH" "non-exhaustive match"

applyOpt : Value e -> Value e -> <e> Option (Value e)
applyOpt (VClosure env pats body) arg = applyClosure env pats body arg
applyOpt (VClosureF env pats f) arg = applyClosureF env pats f arg
applyOpt (VPrim f) arg = Some (f arg)
applyOpt (VTypedImpl t key pos seen inner) arg =
  applyTyped t key pos seen inner arg
applyOpt (VMulti vs) arg = collectPartials [] (filterByTag vs arg) arg
applyOpt other _ =
  runtimePanic "E-NOT-A-FUNCTION" ("applied non-function: " ++ ppValue other)

-- pass the arg to the impl's inner value, preserving the dispatch tag across
-- partial applications (so later args still route to the same impl)
applyTyped : String -> String -> List Int -> Int -> Value e -> Value e -> <e> Option (Value e)
applyTyped t key pos seen inner arg =
  map (reTag t key pos (seen + 1)) (applyOpt inner arg)

reTag : String -> String -> List Int -> Int -> Value e -> Value e
reTag t key pos seen r
  | isPartial r = VTypedImpl t key pos seen r
  | otherwise = r

-- filter VMulti candidates by the arg's runtime tag, but only those candidates
-- that are at a dispatching slot; if every tagged candidate is filtered out,
-- keep the original set (mirrors lib/eval.ml's should_filter logic)
filterByTag : List (Value e) -> Value e -> List (Value e)
filterByTag vs arg
  | not (anyList isDispatching vs) = vs
  | otherwise = filterByTagT vs (runtimeTypeTag arg)

filterByTagT : List (Value e) -> Option String -> List (Value e)
filterByTagT vs None = vs
filterByTagT vs (Some tag) = keepOrAll vs (filter (keepCand tag) vs)

keepOrAll : List (Value e) -> List (Value e) -> List (Value e)
keepOrAll original [] = original
keepOrAll _ kept = kept

keepCand : String -> Value e -> Bool
keepCand tag v = not (isDispatching v) || matchesTag tag v

isDispatching : Value e -> Bool
isDispatching (VTypedImpl _ _ pos seen _) = containsInt seen pos
isDispatching _ = False

-- return-position dispatch (RKey): narrow a method's VMulti to the impl whose
-- VTypedImpl tag matches the type the typechecker resolved (no runtime arg).  An
-- empty tag (unresolved / polymorphic — doesn't occur in the compiler) leaves the
-- VMulti for arg-tag fallback.
export narrowMethod : Value e -> String -> <e> Value e
narrowMethod (VMulti vs) "" = VMulti vs
narrowMethod (VMulti vs) tag = stripResolved (pickByTag vs tag)
-- A single-impl interface method binds to a BARE VTypedImpl (never coalesced into
-- a VMulti).  A resolved route (non-empty tag) still has to strip its dispatch
-- wrapper for a nullary return-position body — there's only one impl, so it IS the
-- chosen one — mirroring lib/eval.ml's Phase-96 strip, which fires for any
-- VTypedImpl after routing.  An empty tag (RNone / unresolved) leaves it for
-- arg-tag fallback.
narrowMethod (VTypedImpl t k p s inner) "" = VTypedImpl t k p s inner
narrowMethod (VTypedImpl t k p s inner) _ =
  stripResolved (VTypedImpl t k p s inner)
narrowMethod v _ = v

-- A concrete route tag picks the impl whose VTypedImpl tag matches.  When NO
-- candidate carries the tag, the receiver's impl does not override this method —
-- it inherits the interface DEFAULT.  This is the cross-module case: desugar's
-- same-module `fillImplDefaults` never specialized the default into a tagged
-- VTypedImpl for this impl, so the only correct candidate is the untagged default
-- (installed as a bare VClosure / VThunk, never a VTypedImpl).  Select it so a
-- CONSTRAINED default body (e.g. `foldMap`'s `Monoid m =>`) runs with its
-- forwarded method-level dict instead of leaving the whole VMulti — which would
-- apply every sibling impl's specialized default to the wrong receiver and hard-
-- panic.  Mirrors the LLVM `emitDefaultRKey` default-fallback path.  Only when
-- there is ALSO no default do we leave the whole VMulti for arg-tag fallback.
pickByTag : List (Value e) -> String -> Value e
pickByTag vs tag = match filterList (hasTag tag) vs
  [] => oneOrMultiV (filterList isDefaultCand vs) vs
  matched => oneOrMultiV matched vs

-- an interface-default fallback candidate: installed untagged (VClosure / VThunk),
-- never wrapped in a VTypedImpl dispatch tag.
isDefaultCand : Value e -> Bool
isDefaultCand (VTypedImpl _ _ _ _ _) = False
isDefaultCand _ = True

-- Once a route has pinned a single impl, strip the dispatch wrapper iff its body
-- is a terminal value (a nullary return-position method like `empty`/`minBound`
-- that is never applied — its wrapper must not leak into the program).  A body
-- still awaiting application (a closure / partial impl, e.g. `pure`) keeps the
-- wrapper so `apply` strips the tag on application.  Mirrors lib/eval.ml Phase 96.
stripResolved : Value e -> <e> Value e
stripResolved (VTypedImpl t k p s inner) =
  stripBody (VTypedImpl t k p s inner) inner
stripResolved v = v

stripBody : Value e -> Value e -> <e> Value e
stripBody wrapper (VThunk f) = stripBody wrapper (f ())
stripBody wrapper (VTypedImpl _ _ _ _ inner) = stripBody wrapper inner
stripBody wrapper v = if awaitsArgs v then wrapper else v

awaitsArgs : Value e -> Bool
awaitsArgs (VClosure _ _ _) = True
awaitsArgs (VClosureF _ _ _) = True
awaitsArgs (VPrim _) = True
awaitsArgs (VMulti _) = True
awaitsArgs (VTypedImpl _ _ _ _ _) = True
awaitsArgs _ = False

-- the concrete head tag an EMethodAt route narrows by: RKey is literal; RDict/
-- RDictFwd forward the enclosing function's dict parameter; RNone leaves the
-- VMulti for arg-tag fallback ("").
export routeTag : EvalEnv (Value e) -> Route -> <e> String
routeTag _ RNone = ""
routeTag _ (RKey key _) = key
routeTag env (RDict d) = match lookupEnv env d
  VDict key _ => key
  _ => ""
routeTag env (RDictFwd d) = match lookupEnv env d
  VDict key _ => key
  _ => ""
routeTag _ (RLocal _ _) = ""
-- RScalar tags an arithmetic EBinOp for the backend's Float path; it is never a
-- typeclass dispatch route, so eval never routes a method through it.
routeTag _ (RScalar _) =
  panic "unreachable: RScalar is an arithmetic binop tag, not a dispatch route"

-- a constrained-function occurrence: apply one runtime dictionary per resolved
-- route as a leading argument (matching the dict params dict_pass prepended).
export applyDicts : EvalEnv (Value e) -> Value e -> List Route -> <e> Value e
applyDicts _ v [] = v
applyDicts env v (r::rest) = applyDicts env (apply v (dictOfRoute env r)) rest

-- apply an already-built list of VDict values directly (used to forward an impl's
-- own requires into its body at a return-position RDictFwd site, Phase 83/84 #5).
export applyValues : Value e -> List (Value e) -> <e> Value e
applyValues v [] = v
applyValues v (x::rest) = applyValues (apply v x) rest

-- build the runtime dictionary for one route: RKey builds a structured VDict
-- carrying the impl's own requires dicts recursively (Phase 83/84 #5); RDict/
-- RDictFwd forward the enclosing dict param in full; RNone is a no-op dict.
dictOfRoute : EvalEnv (Value e) -> Route -> <e> Value e
dictOfRoute env (RKey key reqs) = VDict key (map (dictOfRoute env) reqs)
dictOfRoute env (RDict d) = match lookupEnv env d
  VDict key reqs => VDict key reqs
  _ => VDict "" []
dictOfRoute env (RDictFwd d) = match lookupEnv env d
  VDict key reqs => VDict key reqs
  _ => VDict "" []
dictOfRoute _ RNone = VDict "" []
-- S-1: an RLocal route's OWN dicts (the shadowing standalone's `=>` constraints) are
-- applied by evalMethodAt's RLocal arm via applyDicts — they are the call's leading
-- dict ARGS, not a dict witness FOR this route.  So as a *witness* RLocal is still the
-- no-op dict.  (Pre-S1 this arm's comment claimed "RLocal never carries a dict"; that
-- invariant was the S-1 bug and is now false — see ast.mdk's Route doc + S9.)
dictOfRoute _ (RLocal _ _) = VDict "" []
-- RScalar is an arithmetic binop tag (backend Float path), never a dict route.
dictOfRoute _ (RScalar _) =
  panic "unreachable: RScalar is an arithmetic binop tag, not a dispatch route"

-- narrow a method VMulti by a route, returning the narrowed value and any
-- forwarded requires (non-empty only for RDictFwd return-position sites where the
-- enclosing dict carries nested element dicts for the selected impl, Phase 83/84 #5).
export methodAtNarrow : EvalEnv (Value e) -> Value e -> Route -> <e> (Value e, List (Value e))
methodAtNarrow _ v RNone = (v, [])
methodAtNarrow _ v (RKey key _) = (narrowMethod v key, [])
-- ARGSTAMP-UNIFY Phase 2+3 / genuine #21: under eval dict-threading an arg-position
-- RDict site's narrowed impl method ALSO carries leading element-dict params
-- (resolveArgStamps ran on eval too), so forward the dict's nested `reqs` exactly as
-- RDictFwd does — this is what emit's emitDispatchChain does (load fields 1..n, prepend
-- to argOps).  2-level nesting (`debug (List (List a))`) composes through this: the
-- forwarded inner dict (`Debug (List Int)` = VDict "List" [VDict "Int"]) supplies the
-- List impl method's leading `Debug Int` param.  Pre-unify RDict impl methods had NO
-- dict slot (arg-tag), so reqs were discarded; now they need them.
methodAtNarrow env v (RDict d) = match lookupEnv env d
  VDict key reqs => (narrowMethod v key, reqs)
  _ => (v, [])
methodAtNarrow env v (RDictFwd d) = match lookupEnv env d
  VDict key reqs => (narrowMethod v key, reqs)
  _ => (v, [])
-- RLocal: not a method dispatch — the EMethodAt arm resolves the standalone
-- directly (lookupEnv) and never calls methodAtNarrow with RLocal.  This arm
-- exists only to keep the match exhaustive; it returns the value unnarrowed.
methodAtNarrow _ v (RLocal _ _) = (v, [])
-- RScalar is an arithmetic binop tag (backend Float path), never a dispatch route.
methodAtNarrow _ _ (RScalar _) =
  panic "unreachable: RScalar is an arithmetic binop tag, not a dispatch route"

oneOrMultiV : List (Value e) -> List (Value e) -> Value e
oneOrMultiV [v] _ = v
oneOrMultiV [] original = VMulti original
oneOrMultiV many _ = VMulti many

-- TYPECHECK-AUDIT C7: a candidate matches a route string when the string equals
-- EITHER its head tycon (field 1, the args-free RHeadKey-analog route) OR its
-- canonical impl key (field 2, the ground route the typechecker stamps).  The two
-- string spaces are disjoint — a bare head tycon ("Pair") never contains "|",
-- while a canonical key always does — so this can't cross-match.  This is what
-- lets two same-head non-overlapping impls (Pair Int Bool vs Pair Bool Int)
-- narrow to the one the checker picked instead of first-impl-wins.
hasTag : String -> Value e -> Bool
hasTag tag (VTypedImpl t k _ _ _) = t == tag || k == tag
hasTag _ _ = False

matchesTag : String -> Value e -> Bool
matchesTag tag (VTypedImpl t k _ _ _) = t == tag || k == tag
matchesTag _ _ = True

applyClosure : EvalEnv (Value e) -> List Pat -> Expr -> Value e -> <e> Option (Value e)
applyClosure _ [] _ _ = panic "applied closure with no parameters"
applyClosure env [p] body arg = match matchPat p arg
  None => None
  Some binds => fallthroughToNone (eval (extendEnv env binds) body)
applyClosure env (p::ps) body arg =
  map (binds => VClosure (extendEnv env binds) ps body) (matchPat p arg)

-- VClosureF analog of applyClosure: the body is a host fn run on the fully-
-- extended env once the last param binds; partial application keeps the same
-- body fn and grows env (mirrors VClosure exactly).
export applyClosureF : EvalEnv (Value e) -> List Pat -> (EvalEnv (Value e) -> <e> Value e) -> Value e -> <e> Option (Value e)
applyClosureF _ [] _ _ = panic "applied closure with no parameters"
applyClosureF env [p] f arg = match matchPat p arg
  None => None
  Some binds => fallthroughToNone (f (extendEnv env binds))
applyClosureF env (p::ps) f arg =
  map (binds => VClosureF (extendEnv env binds) ps f) (matchPat p arg)

-- a guard chain that fell through (VFallthrough) means this clause didn't match
fallthroughToNone : Value e -> Option (Value e)
fallthroughToNone VFallthrough = None
fallthroughToNone v = Some v

collectPartials : List (Value e) -> List (Value e) -> Value e -> <e> Option (Value e)
collectPartials [] [] _ = panic "no matching impl for dispatch"
collectPartials [v] [] _ = Some v
collectPartials many [] _ = Some (VMulti (reverseL many))
collectPartials acc (v::rest) arg = match applyOpt v arg
  None => collectPartials acc rest arg
  Some r => if isPartial r then collectPartials (r::acc) rest arg else Some r

isPartial : Value e -> Bool
isPartial (VClosure _ _ _) = True
isPartial (VClosureF _ _ _) = True
isPartial (VPrim _) = True
isPartial (VMulti _) = True
isPartial (VTypedImpl _ _ _ _ _) = True
isPartial _ = False

-- ── the evaluator ─────────────────────────────────────────────────────────
export eval : EvalEnv (Value e) -> Expr -> <e> Value e
eval _ (ELit (LInt n)) = VInt n
-- PLAN.md #11: dictPass rewrites every ENumLit to ELit before eval; these arms
-- are defensive for an untyped/non-elaborate eval path (a bare int → VInt; a
-- Float-stamped ref → VFloat, matching eval_arith's value tags).
eval _ (ENumLit n r _) = match r.value
  Some f => VFloat f
  None => VInt n
eval _ (ELit (LFloat f)) = VFloat f
eval _ (ELit (LString s)) = VString s
eval _ (ELit (LChar c)) = VChar c
eval _ (ELit (LBool b)) = VBool b
eval _ (ELit LUnit) = VUnit
eval env (EVar x) = if startsWithAt x then VUnit else lookupEnv env x
-- DORMANT consume arm for the §2.0 lexical-addressing EMIT half: handles an
-- `EVarAt` node (produced by annotate.mdk's annotateProgram) by slot-indexing
-- the frame the address names.  It is NOT wired into the eval pipeline — the
-- drivers do not run annotateProgram, so the AST tree-walker never sees an
-- `EVarAt` (plain `EVar` by-name lookup is used).  Kept as validated Stage-2
-- scaffolding: measured neutral/regressive under THIS tree-walker (the indexed
-- lookup is itself interpreted Medaka, so it doesn't beat the by-name scan it
-- replaces — see PERF-NOTES.md), but the addresses become a real native index
-- in a bytecode VM, where consuming them pays off.  Activate by running
-- annotateProgram in evalProgram/evalModules.
eval env (EVarAt x addr) =
  if startsWithAt x then
    VUnit
  else
    lookupAtAddr env x addr
eval env (EMethodAt name routeRef implRef methodRef) =
  evalMethodAt env name routeRef.value implRef.value methodRef.value

eval env (EDictAt name routesRef) =
  applyDicts env (lookupEnv env name) routesRef.value
eval env (EApp f x) = apply (eval env f) (eval env x)
eval env (ELam pats body) = VClosure env pats body
eval env (ELet _ True (PVar f) e1 e2) = evalRecLet env f e1 e2
eval env (ELet _ _ pat e1 e2) = evalLet env pat e1 e2
eval env (ELetGroup binds body) = evalLetGroup env binds body
eval env (EMatch scrut arms) = evalMatch env (eval env scrut) arms
eval env (EIf c t e) = evalIf env (eval env c) t e
eval env (EBinOp op l r _) = evalBinop env op l r
eval env (EInfix op l r) =
  apply (apply (lookupEnv env op) (eval env l)) (eval env r)
eval env (EUnOp op e _) = evalUnop op (eval env e)
eval env (ETuple es) = VTuple (map (eval env) es)
eval env (EListLit es) = VList (map (eval env) es)
eval env (EArrayLit es) = VArray (arrayFromList (map (eval env) es))
eval env (ERecordCreate name fields) =
  let assigns = map (evalFieldAssign env) fields
  match lookupAssoc name ctorFieldOrdersRef.value
    Some order => VCon name (recordCreateVals name order assigns)
    None => VRecord name assigns
eval env (ERecordUpdate base fields _) =
  evalRecordUpdate (eval env base) (map (evalFieldAssign env) fields)
eval env (EVariantUpdate con base fields) =
  evalVariantUpdate con (eval env base) (map (evalFieldAssign env) fields)
eval env (EFieldAccess e "value" _) = evalValueField (eval env e)
eval env (EFieldAccess e field _) = evalField (eval env e) field
eval env (EAnnot e _) = eval env e
eval env (EHeadAnnot e _) = eval env e
eval env (EBlock stmts) = evalBlock env stmts
-- EIndex is desugared to an `index` method call before eval (Phase #16b); the
-- built-in index path is retired, so no `EIndex` arm here.
eval env (ESlice arr lo hi incl _) =
  evalSlice (eval env arr) (eval env lo) (eval env hi) incl
eval env (ERangeList lo hi incl) =
  evalRange (eval env lo) (eval env hi) incl rangeListMk
eval env (ERangeArray lo hi incl) =
  evalRange (eval env lo) (eval env hi) incl rangeArrayMk
-- ELoc records the current source location before recursing (mirror of
-- lib/eval.ml's ELoc arm, which sets current_loc).  runtimePanic reads
-- currentEvalLoc so a runtime error carries file:L:C.  Purely a side channel
-- for diagnostics: on a successful eval nothing reads it, so valid-program
-- output is byte-identical.
eval env (ELoc l e) =
  let _ = updateEvalLoc l
  eval env e
eval env (EDoOrigin _ e) = eval env e
eval _ _ = panic "eval: unsupported node (slice 2)"

-- C5: an RLocal route is NOT a method dispatch — the typechecker found no impl
-- of this interface for the concrete receiver but the name has an explicitly-
-- imported/local standalone (which the import frame binds ahead of the global
-- method VMulti).  Resolve the standalone with a plain lookupEnv, unnarrowed and
-- with no dict folding (mirror lib/eval.ml:816 EMethodRef RLocal).  Every other
-- route is a genuine method dispatch: resolve the VMulti past any nearer same-
-- named standalone shadow with lookupMethod (C5 / lib/eval.ml:223), then narrow.
evalMethodAt : EvalEnv (Value e) -> String -> Route -> List Route -> List Route -> <e> Value e
-- P0-18: the carried String is the MANGLED standalone symbol on the emit path;
-- "" (the un-mangled run/check path) falls back to the bare method name.
-- S-1: apply the standalone's OWN constraint dicts as leading args (`dicts` is empty
-- for an unconstrained standalone ⇒ applyDicts is the identity ⇒ byte-identical to
-- the pre-S1 bare lookupEnv).  A CONSTRAINED standalone was given leading dict PARAMS
-- by dictPassDecl, so without this the call under-applies by exactly one word per
-- constraint and the first real argument lands in the dict slot.  This is literally
-- the EDictAt arm's body (`applyDicts env (lookupEnv env name) routes`) — the same
-- machinery, now reachable from the shadow arm that the marking prePass consumes.
evalMethodAt env name (RLocal sym dicts) _ _ =
  applyDicts env (lookupEnv env (if sym == "" then name else sym)) dicts
evalMethodAt env name route implRoutes methodRoutes =
  let lm = lookupMethod env name
  let (narrowed, fwdReqs0) = methodAtNarrow env lm route
  let fwdReqs = takeN (lookupMethodReqCount name (routeTag env route)) fwdReqs0
  if awaitsArgs narrowed then
    let v1 = applyDicts env narrowed methodRoutes
    let v2 = applyDicts env v1 implRoutes
    applyValues v2 fwdReqs
  else narrowed
-- ARGSTAMP-UNIFY / genuine #21: the forwarding dict can be OVER-provisioned (a
-- List-tagged dict may carry an element req that THIS method's List impl does not
-- consume — two interfaces sharing the head tag, only one with `requires`).  Emit
-- tolerates this by loading only the matched impl's reqCount dicts; mirror that —
-- forward only the first reqCount of the dict's reqs (reqCount=0 ⇒ none).

-- Mirror lib/eval.ml:869-873 (Phase 103): only fold method-/impl-dicts and
-- forwarded requires onto a value still awaiting application. A terminal
-- nullary return-position impl body (`def = []`, stripped to a bare value by
-- stripResolved) takes no dict params — dict_pass's usesImplDict gate adds none
-- — so applying the route's dicts would over-apply to a constructor/scalar
-- ("applied non-function"). Drop them when the narrowed value awaits no args.

-- Retained for the Core-IR interpreter's CIndex/CStringIndex/CListIndex arms
-- (see the note on listNthAt above): the EIndex eval arm is gone (desugared to
-- `index`), so this is only reachable via the now-unreachable Core-IR nodes.
export evalIndex : Value e -> Value e -> Value e
evalIndex container (VInt i) = evalIndexInt container i
evalIndex _ _ = panic "index is not an Int"

evalIndexInt : Value e -> Int -> Value e
evalIndexInt (VArray a) i
  | i < 0 || i >= arrayLength a =
    runtimePanic "E-INDEX-OOB" ("index " ++ intToString i ++ " out of bounds")
  | otherwise = arrayGetUnsafe i a
evalIndexInt (VList vs) i = listNthAt vs i i
evalIndexInt (VString s) i = stringIndexCp s i
evalIndexInt _ _ = panic "index on non-array/list/string"

-- codepoint-indexed Char (Phase 77)
stringIndexCp : String -> Int -> Value e
stringIndexCp s i
  | i < 0 || i >= stringLength s =
    runtimePanic "E-INDEX-OOB" ("index " ++ intToString i ++ " out of bounds")
  | otherwise = VChar (charToStr (arrayGetUnsafe i (stringToChars s)))

export evalSlice : Value e -> Value e -> Value e -> Bool -> Value e
evalSlice container (VInt lo) (VInt hi) incl = evalSliceInt container lo hi incl
evalSlice _ _ _ _ = panic "slice index must be Int"

evalSliceInt : Value e -> Int -> Int -> Bool -> Value e
evalSliceInt (VArray a) lo hi incl =
  sliceArray a lo (if incl then hi + 1 else hi)
evalSliceInt (VList vs) lo hi incl =
  VList (listSliceV vs lo (if incl then hi + 1 else hi))
evalSliceInt (VString s) lo hi incl =
  VString (stringSlice lo (if incl then hi + 1 else hi) s)
evalSliceInt _ _ _ _ = panic "slice on non-array/list/string"

sliceArray : Array (Value e) -> Int -> Int -> Value e
sliceArray a lo hiX
  | lo < 0 || hiX > arrayLength a || hiX - lo < 0 = runtimePanic "E-SLICE-OOB" "slice [\{intToString lo}..\{intToString (hiX - 1)}] out of bounds"
  | otherwise =
    VArray (arrayMakeWith (hiX - lo) (i => arrayGetUnsafe (lo + i) a))

export evalRange : Value e -> Value e -> Bool -> (List Int -> Value e) -> Value e
evalRange (VInt lo) (VInt hi) incl mk =
  mk (intSeq lo (if incl then hi + 1 else hi))
evalRange _ _ _ _ = panic "range bound must be Int"

export rangeListMk : List Int -> Value e
rangeListMk ns = VList (map VInt ns)

export rangeArrayMk : List Int -> Value e
rangeArrayMk ns = VArray (arrayFromList (map VInt ns))

evalFieldAssign : EvalEnv (Value e) -> FieldAssign -> <e> (String, Value e)
evalFieldAssign env (FieldAssign k e) = (k, eval env e)

-- A named-field DATA constructor (registered in ctorFieldOrdersRef) builds a
-- positional VCon, reordering the field assignments into declaration order
-- (mirrors lib/eval.ml ERecordCreate's ctor_field_order path). Plain record
-- declarations are not registered and fall through to VRecord.
recordCreateVals : String -> List String -> List (String, Value e) -> List (Value e)
recordCreateVals _ [] _ = []
recordCreateVals con (f::fs) assigns = match lookupAssoc f assigns
  Some v => v :: recordCreateVals con fs assigns
  None => panic ("missing field: " ++ f)

export evalRecordUpdate : Value e -> List (String, Value e) -> Value e
evalRecordUpdate (VRecord name existing) updates =
  VRecord name (map (mergeField updates) existing)
evalRecordUpdate _ _ = panic "record update on non-record"

mergeField : List (String, Value e) -> (String, Value e) -> (String, Value e)
mergeField updates (k, v) = match lookupAssoc k updates
  Some v2 => (k, v2)
  None => (k, v)

-- variant (named-field constructor) update: `Con { base | f = v … }`.
-- Looks up the constructor's field order from ctorFieldOrdersRef, then replaces
-- positional values for the named fields in `updates`, keeping the rest.
export evalVariantUpdate : String -> Value e -> List (String, Value e) -> Value e
evalVariantUpdate con (VCon con' vals) updates
  | con == con' =
    VCon con (applyVariantUpdates updates (ctorFieldOrderFor con) vals)
  | otherwise = panic "evalVariantUpdate: expected \{con} got \{con'}"
-- The tree-walking `run` path (compiler/eval/eval.mdk's own `ERecordCreate` arm)
-- never populates `ctorFieldOrdersRef` (only the Core-IR lowering/eval drivers
-- do), so a named-field constructor value on this path is a `VRecord`, never a
-- `VCon`. Mirror `evalRecordUpdate`'s merge, keeping the constructor tag.
evalVariantUpdate con (VRecord con' fields) updates
  | con == con' = VRecord con' (map (mergeField updates) fields)
  | otherwise = panic "evalVariantUpdate: expected \{con} got \{con'}"
evalVariantUpdate con v _ =
  panic "evalVariantUpdate: not a constructor: \{con} got \{ppValue v}"

ctorFieldOrderFor : String -> List String
ctorFieldOrderFor con = match lookupAssoc con ctorFieldOrdersRef.value
  Some fs => fs
  None => panic ("evalVariantUpdate: unknown constructor " ++ con)

applyVariantUpdates : List (String, Value e) -> List String -> List (Value e) -> List (Value e)
applyVariantUpdates _ [] _ = []
applyVariantUpdates _ _ [] = []
applyVariantUpdates updates (f::fs) (v::vs) =
  applyFieldUpdate updates f v :: applyVariantUpdates updates fs vs

applyFieldUpdate : List (String, Value e) -> String -> Value e -> Value e
applyFieldUpdate updates field old = match lookupAssoc field updates
  Some v => v
  None => old

export evalValueField : Value e -> Value e
evalValueField (VRef cell) = cell.value
evalValueField (VRecord _ fields) = match lookupAssoc "value" fields
  Some v => v
  None => panic "record has no field 'value'"
evalValueField _ = panic "field access on non-record/ref"

export evalField : Value e -> String -> Value e
evalField (VRecord _ fields) field = fieldOr fields field
evalField _ _ = panic "field access on non-record"

fieldOr : List (String, Value e) -> String -> Value e
fieldOr fields field = match lookupAssoc field fields
  Some v => v
  None => panic ("unknown field: " ++ field)

-- bare sequential block: value of the last statement is the block's result
evalBlock : EvalEnv (Value e) -> List DoStmt -> <e> Value e
evalBlock _ [] = VUnit
evalBlock env [DoExpr e] = eval env e
evalBlock env [DoLet _ _ pat e] = blockLetLast env pat e
evalBlock env ((DoExpr e)::rest) =
  let _ = eval env e
  evalBlock env rest
evalBlock env ((DoLet _ True (PVar f) e)::rest) = blockRecLet env f e rest
evalBlock env ((DoLet _ _ pat e)::rest) = blockLet env pat e rest
evalBlock env [DoAssign _ e] =
  let _ = eval env e
  VUnit
evalBlock env ((DoAssign x e)::rest) =
  evalBlock (extendEnv env [(x, eval env e)]) rest
evalBlock _ (_::_) = panic "eval: unsupported block statement"

blockLetLast : EvalEnv (Value e) -> Pat -> Expr -> <e> Value e
blockLetLast env pat e = match matchPat pat (eval env e)
  None => runtimePanic "E-LET-REFUTE" "let pattern match failed"
  Some _ => VUnit

blockRecLet : EvalEnv (Value e) -> String -> Expr -> List DoStmt -> <e> Value e
blockRecLet env f e rest =
  let cell = Ref VUnit
  let recEnv = pushFrame env [(f, cell)]
  let v = eval recEnv e
  let _ = setRef cell v
  evalBlock recEnv rest

blockLet : EvalEnv (Value e) -> Pat -> Expr -> List DoStmt -> <e> Value e
blockLet env pat e rest = match matchPat pat (eval env e)
  None => runtimePanic "E-LET-REFUTE" "let pattern match failed"
  Some binds => evalBlock (extendEnv env binds) rest

evalRecLet : EvalEnv (Value e) -> String -> Expr -> Expr -> <e> Value e
evalRecLet env f e1 e2 =
  let cell = Ref VUnit
  let recEnv = pushFrame env [(f, cell)]
  let v = eval recEnv e1
  let _ = setRef cell v
  eval recEnv e2

evalLet : EvalEnv (Value e) -> Pat -> Expr -> Expr -> <e> Value e
evalLet env pat e1 e2 = match matchPat pat (eval env e1)
  None => runtimePanic "E-LET-REFUTE" "let pattern match failed"
  Some binds => eval (extendEnv env binds) e2

evalLetGroup : EvalEnv (Value e) -> List LetBind -> Expr -> <e> Value e
evalLetGroup env binds body =
  let cells = map letBindCell binds
  let env2 = pushFrame env cells
  let _ = installGroup env2 cells binds
  eval env2 body

letBindCell : LetBind -> (String, Ref (Value e))
letBindCell (LetBind name _) = (name, Ref VUnit)

installGroup : EvalEnv (Value e) -> List (String, Ref (Value e)) -> List LetBind -> <e> Unit
installGroup _ _ [] = ()
installGroup env cells ((LetBind name clauses)::rest) =
  let _ = setRef (findCell cells name) (groupValue env (map funClauseToClause clauses))
  installGroup env cells rest

funClauseToClause : FunClause -> (List Pat, Expr)
funClauseToClause (FunClause pats body) = (pats, body)

groupValue : EvalEnv (Value e) -> List (List Pat, Expr) -> <e> Value e
groupValue env [(pats, body)]
  | isNullary pats = eval env body
  | otherwise = VClosure env pats body
groupValue env clauses = VMulti (map (clauseClosure env) clauses)

-- top-level variant: a nullary binding becomes a deferred VThunk (forced on
-- first lookup) so point-free defs can reference values/impls installed later
topGroupValue : EvalEnv (Value e) -> List (List Pat, Expr) -> Value e
topGroupValue env [(pats, body)]
  | isNullary pats = VThunk (_ => eval env body)
  | otherwise = VClosure env pats body
topGroupValue env clauses = VMulti (map (clauseClosure env) clauses)

clauseClosure : EvalEnv (Value e) -> (List Pat, Expr) -> Value e
clauseClosure env (pats, body) = VClosure env pats body

export isNullary : List Pat -> Bool
isNullary [] = True
isNullary _ = False

evalMatch : EvalEnv (Value e) -> Value e -> List Arm -> <e> Value e
evalMatch _ _ [] = runtimePanic "E-NONEXHAUSTIVE-MATCH" "non-exhaustive match"
evalMatch env sv ((Arm pat guards body)::rest) = match matchPat pat sv
  None => evalMatch env sv rest
  Some binds => match runGuards (extendEnv env binds) guards
    Some env2 => eval env2 body
    None => evalMatch env sv rest

runGuards : EvalEnv (Value e) -> List Guard -> <e> Option (EvalEnv (Value e))
runGuards env [] = Some env
runGuards env ((GBool g)::qs) = match eval env g
  VBool True => runGuards env qs
  VCon "True" [] => runGuards env qs
  _ => None
runGuards env ((GBind p e)::qs) = match matchPat p (eval env e)
  Some b => runGuards (extendEnv env b) qs
  None => None

evalIf : EvalEnv (Value e) -> Value e -> Expr -> Expr -> <e> Value e
evalIf env (VBool True) t _ = eval env t
evalIf env (VCon "True" []) t _ = eval env t
evalIf env (VBool False) _ e = eval env e
evalIf env (VCon "False" []) _ e = eval env e
evalIf _ _ _ _ = panic "if condition is not a Bool"

export evalUnop : String -> Value e -> Value e
evalUnop "-" (VInt n) = VInt (0 - n)
evalUnop "-" (VFloat f) = VFloat (0.0 - f)
evalUnop "-" _ = panic "unary minus on non-number"
evalUnop "!" (VBool b) = VBool (not b)
evalUnop "!" _ = panic "'!' on non-Bool"
evalUnop "not" (VBool b) = VBool (not b)
evalUnop "not" _ = panic "'!' on non-Bool"
evalUnop op _ = panic ("unknown unary op: " ++ op)

evalBinop : EvalEnv (Value e) -> String -> Expr -> Expr -> <e> Value e
evalBinop env "|>" l r = apply (eval env r) (eval env l)
evalBinop env ">>" l r = composeFwd (eval env l) (eval env r)
evalBinop env "<<" l r = composeBwd (eval env l) (eval env r)
evalBinop env "&&" l r = evalAnd env (eval env l) r
evalBinop env "||" l r = evalOr env (eval env l) r
evalBinop env "::" l r = consVal (eval env l) (eval env r)
evalBinop env "++" l r = appendVal (eval env l) (eval env r)
evalBinop env op l r = evalArith op (eval env l) (eval env r)

composeFwd : Value e -> Value e -> Value e
composeFwd fv gv = VPrim (x => apply gv (apply fv x))

composeBwd : Value e -> Value e -> Value e
composeBwd fv gv = VPrim (x => apply fv (apply gv x))

evalAnd : EvalEnv (Value e) -> Value e -> Expr -> <e> Value e
evalAnd _ (VBool False) _ = VBool False
evalAnd _ (VCon "False" []) _ = VBool False
evalAnd env (VBool True) r = eval env r
evalAnd env (VCon "True" []) r = eval env r
evalAnd _ _ _ = panic "'&&' on non-Bool"

evalOr : EvalEnv (Value e) -> Value e -> Expr -> <e> Value e
evalOr _ (VBool True) _ = VBool True
evalOr _ (VCon "True" []) _ = VBool True
evalOr env (VBool False) r = eval env r
evalOr env (VCon "False" []) r = eval env r
evalOr _ _ _ = panic "'||' on non-Bool"

export consVal : Value e -> Value e -> Value e
consVal hv (VList xs) = VList (hv::xs)
consVal _ _ = panic "cons (::) rhs is not a list"

export appendVal : Value e -> Value e -> Value e
appendVal (VList a) (VList b) = VList (a ++ b)
appendVal (VString a) (VString b) = VString (a ++ b)
appendVal _ _ =
  panic "'++' requires Semigroup (List, String, or a type with append)"

export evalArith : String -> Value e -> Value e -> Value e
evalArith "+" (VInt a) (VInt b) = VInt (a + b)
evalArith "-" (VInt a) (VInt b) = VInt (a - b)
evalArith "*" (VInt a) (VInt b) = VInt (a * b)
evalArith "/" (VInt a) (VInt b)
  | b == 0 = runtimePanic "E-DIV-ZERO" "division by zero"
  | otherwise = VInt (a / b)
evalArith "%" (VInt a) (VInt b)
  | b == 0 = runtimePanic "E-MOD-ZERO" "modulo by zero"
  | otherwise = VInt (a % b)
evalArith "+" (VFloat a) (VFloat b) = VFloat (a + b)
evalArith "-" (VFloat a) (VFloat b) = VFloat (a - b)
evalArith "*" (VFloat a) (VFloat b) = VFloat (a * b)
evalArith "/" (VFloat a) (VFloat b) = VFloat (a / b)
evalArith "%" (VFloat a) (VFloat b) = VFloat (floatRem a b)
evalArith "==" a b = VBool (valueEq a b)
evalArith "!=" a b = VBool (not (valueEq a b))
evalArith "<" a b = VBool (ordLt (valueCompare a b))
evalArith ">" a b = VBool (ordGt (valueCompare a b))
evalArith "<=" a b = VBool (not (ordGt (valueCompare a b)))
evalArith ">=" a b = VBool (not (ordLt (valueCompare a b)))
evalArith op _ _ = panic ("unknown op '" ++ op ++ "'")

-- ── program driver ────────────────────────────────────────────────────────
export collectCtors : List Decl -> List (String, Value e)
collectCtors prog = flatMap ctorsOfDecl prog

ctorsOfDecl : Decl -> List (String, Value e)
ctorsOfDecl (DData _ _ _ variants _) = map ctorEntry variants
ctorsOfDecl (DNewtype _ _ _ con fty _) =
  [ctorEntry (Variant con (ConPos [fty]))]
ctorsOfDecl _ = []

ctorEntry : Variant -> (String, Value e)
ctorEntry (Variant n payload) = (n, makeCtor n (payloadArity payload))

export payloadArity : ConPayload -> Int
payloadArity (ConPos tys) = listLen tys
payloadArity (ConNamed fs _) = listLen fs

funDefs : List Decl -> List (String, (List Pat, Expr))
funDefs [] = []
funDefs ((DFunDef _ n pats body)::rest) = (n, (pats, body)) :: funDefs rest
-- Top-level `let rec … with …` (DLetGroup): each binding behaves exactly like a
-- multi-clause DFunDef — flatten to (name, (pats, body)) entries so installGroups
-- coalesces its clauses into a VMulti and the names enter the eval frame.  Mirrors
-- lib/eval.ml's DLetGroup install arm.
funDefs ((DLetGroup _ binds)::rest) = letGroupDefs binds ++ funDefs rest
funDefs ((DAttrib _ d)::rest) = funDefs (d::rest)
funDefs (_::rest) = funDefs rest

letGroupDefs : List LetBind -> List (String, (List Pat, Expr))
letGroupDefs [] = []
letGroupDefs ((LetBind n clauses)::rest) = map (clauseDef n) clauses
  ++ letGroupDefs rest

clauseDef : String -> FunClause -> (String, (List Pat, Expr))
clauseDef n (FunClause pats body) = (n, (pats, body))

funGroupNames : List (String, (List Pat, Expr)) -> List String -> List String
funGroupNames [] _ = []
funGroupNames ((n, _)::rest) seen
  | contains n seen = funGroupNames rest seen
  | otherwise = n :: funGroupNames rest (n::seen)

clausesForName : String -> List (String, (List Pat, Expr)) -> List (List Pat, Expr)
clausesForName _ [] = []
clausesForName name ((n, c)::rest)
  | n == name = c :: clausesForName name rest
  | otherwise = clausesForName name rest

-- ── typeclass impl / interface-default installation ───────────────────────
export buildIfaceDispatch : List Decl -> List ((String, String), List Int)
buildIfaceDispatch prog = flatMap ifaceDispatchEntries prog

ifaceDispatchEntries : Decl -> List ((String, String), List Int)
ifaceDispatchEntries (DInterface { name = ifaceName, typarams = typeParams, methods, ... }) = map (ifaceMethodEntry ifaceName typeParams) methods
ifaceDispatchEntries _ = []

ifaceMethodEntry : String -> List String -> IfaceMethod -> ((String, String), List Int)
ifaceMethodEntry ifaceName typeParams (IfaceMethod mname mty _) =
  ((ifaceName, mname), dispatchPositionsOf mty (receiverParam typeParams))

-- The receiver (dispatch) typaram is the FIRST interface param.  A multi-param
-- interface (`FromEntries c e`) dispatches on `c`; a trailing element param `e`
-- in an argument type (`List e`) must NOT mark that argument as a dispatch
-- position (mirror typecheck.mdk's dispatchTyparams).  Single-param: identity.
receiverParam : List String -> List String
receiverParam [] = []
receiverParam (p::_) = [p]

export lookupPositions : String -> String -> List ((String, String), List Int) -> List Int
lookupPositions _ _ [] = [0]
lookupPositions iface mname (((i, m), p)::rest)
  | iface == i && mname == m = p
  | otherwise = lookupPositions iface mname rest

-- A point-free (no-param) impl/default body: if the method is return-position
-- (no discriminating arg) defer it as a memoising VThunk; otherwise eta-expand so
-- the discriminating argument still reaches the body (mirrors lib/eval.ml Phase 121).
--
-- TYPECHECK-AUDIT C6: the nullary return-position thunk is nested in a
-- VTypedImpl's `inner` field inside a VMulti list (not in a Ref cell of its own),
-- so the cell-level forceCell/forceMemo memoisation never reaches it.  stripBody
-- (the only forcer of this thunk, line 608) calls `f ()` directly, so a bare
-- `VThunk (_ => eval env body)` re-evaluates the body — duplicating effects/cost
-- — on every EMethodAt occurrence at the resolved type.  The OCaml oracle
-- (eval.ml:1899-1903) evaluates the nullary return-position body EAGERLY ONCE at
-- binding time.  memoThunk closes the gap: it caches the first force through a
-- private Ref so subsequent forces (whatever path) return the same value without
-- re-running the body — identical VALUE, effects/work run once like the oracle.
implMethodValue : EvalEnv (Value e) -> List Int -> List Pat -> Expr -> Value e
implMethodValue env positions [] body
  | isEmptyL positions = memoThunk env body
  | otherwise = VClosure env [PVar "$eta"] (EApp body (EVar "$eta"))
implMethodValue env _ pats body = VClosure env pats body

-- A VThunk whose body evaluates at most once: the first force writes the result
-- into a private Ref, later forces read it back (no re-evaluation of `body`).
-- The Ref is built ONCE here (captured by the closure), not inside the lambda —
-- otherwise each force would mint a fresh empty cell and never see the cache.
memoThunk : EvalEnv (Value e) -> Expr -> Value e
memoThunk env body = memoThunkOf (Ref None) env body

memoThunkOf : Ref (Option (Value e)) -> EvalEnv (Value e) -> Expr -> Value e
memoThunkOf cell env body = VThunk (_ => forceMemoCell cell env body)

forceMemoCell : Ref (Option (Value e)) -> EvalEnv (Value e) -> Expr -> <e> Value e
forceMemoCell cell env body = match cell.value
  Some v => v
  None => storeMemo cell (eval env body)

storeMemo : Ref (Option (Value e)) -> Value e -> <e> Value e
storeMemo cell v = seqV (setRef cell (Some v)) v

seqV : Unit -> Value e -> Value e
seqV _ v = v

-- one (methodName, (specificity-score, taggedValue)) per impl method / default
declImplEntries : EvalEnv (Value e) -> List ((String, String), List Int) -> Decl -> List (String, (Int, Value e))
declImplEntries env disp (DImpl { iface = ifaceName, tys = typeArgs, methods, ... }) = map (implMethodEntry env disp ifaceName typeArgs) methods
declImplEntries env _ (DInterface { typarams = typeParams, methods, ... }) =
  flatMap (defaultEntry env typeParams) methods
declImplEntries _ _ _ = []

implMethodEntry : EvalEnv (Value e) -> List ((String, String), List Int) -> String -> List Ty -> ImplMethod -> (String, (Int, Value e))
implMethodEntry env disp ifaceName typeArgs (ImplMethod mname pats body) =
  let tag = fromOption noneHeadTag (headTyconHead typeArgs)
  let key = implKeyOf ifaceName typeArgs None
  let positions = lookupPositions ifaceName mname disp
  let inner = implMethodValue env positions pats body
  (mname, (tyvarsInArgs typeArgs, VTypedImpl tag key positions 0 inner))

export headTyconHead : List Ty -> Option String
headTyconHead [] = None
headTyconHead (t::_) = headTycon t

-- interface defaults install untagged (a VClosure) so they act as a fallback
defaultEntry : EvalEnv (Value e) -> List String -> IfaceMethod -> List (String, (Int, Value e))
defaultEntry _ _ (IfaceMethod _ _ None) = []
defaultEntry env typeParams (IfaceMethod mname _ (Some (MethodDefault pats body))) = [(mname, (listLen typeParams, implMethodValue env [] pats body))]

-- coalesce all candidates for each method name into one VMulti, most-specific
-- (fewest type vars) first
export coalesceImpls : List (String, (Int, Value e)) -> List (String, Value e)
coalesceImpls scored =
  map (n => (n, coalesceOne n scored)) (dedup (map fst scored))

coalesceOne : String -> List (String, (Int, Value e)) -> Value e
coalesceOne name scored =
  oneOrMulti (map snd (sortByScore (selectByName name scored)))

oneOrMulti : List (Value e) -> Value e
oneOrMulti [v] = v
oneOrMulti many = VMulti many

selectByName : String -> List (String, (Int, Value e)) -> List (Int, Value e)
selectByName name scored = map snd (filter (e => fst e == name) scored)

sortByScore : List (Int, Value e) -> List (Int, Value e)
sortByScore xs = sortGo xs []

sortGo : List (Int, Value e) -> List (Int, Value e) -> List (Int, Value e)
sortGo [] acc = acc
sortGo (x::xs) acc = sortGo xs (insertScore x acc)

insertScore : (Int, Value e) -> List (Int, Value e) -> List (Int, Value e)
insertScore x [] = [x]
insertScore x (y::ys)
  | fst y <= fst x = y :: insertScore x ys
  | otherwise = x :: y::ys

export implMethodNames : List Decl -> List String
implMethodNames prog = dedup (flatMap implDeclNames prog)

implDeclNames : Decl -> List String
implDeclNames (DImpl { methods, ... }) = map implMethodName methods
implDeclNames (DInterface { methods, ... }) = flatMap defaultName methods
implDeclNames _ = []

implMethodName : ImplMethod -> String
implMethodName (ImplMethod n _ _) = n

defaultName : IfaceMethod -> List String
defaultName (IfaceMethod n _ (Some _)) = [n]
defaultName (IfaceMethod _ _ None) = []

-- DRIVER-COLLAPSE Phase 5: the flat single-frame evalProgram is DELETED.  Its
-- one-by-name-frame install (prelude+user merged) is subsumed by the 1-module
-- case of evalModules (evalOne); the shared helpers it used (cellResult,
-- installGroups, installConsts, coalesceImpls, …) are retained by evalModules.

export cellResult : (String, Ref (Value e)) -> (String, Value e)
cellResult (n, cell) = (n, cell.value)

-- True/False plus `otherwise` (a trivial prelude binding ubiquitous in guards;
-- the eval_probe oracle injects the same so prelude-free fixtures can use it)
export boolSeeds : List (String, Value e)
boolSeeds =
  [("True", VBool True), ("False", VBool False), ("otherwise", VBool True)]

-- ── extern primitives (the stdlib kernel) ─────────────────────────────────
-- Each primitive wraps the native extern, doing the Value-boundary
-- marshalling (e.g. VChar holds a one-codepoint String).  Curried multi-arg
-- externs nest VPrims.  Every wrapped function carries the OPEN row
-- `<Mut | e>` — a closed row here (even a pure one) would pin `Value`'s row
-- parameter at unification and leak at the shared-table joins.  This table
-- holds only the effect-free-observable prims (the differential oracle
-- installs exactly these); real-I/O prims live in `ioExternBindings` below
-- and are installed only by `medaka run`'s driver.
prim1 : (Value e -> <e> Value e) -> Value e
prim1 f = VPrim f

prim2 : (Value e -> Value e -> <e> Value e) -> Value e
prim2 f = VPrim (a => VPrim (b => f a b))

prim3 : (Value e -> Value e -> Value e -> <e> Value e) -> Value e
prim3 f = VPrim (a => VPrim (b => VPrim (c => f a b c)))

prim2M : (Value e -> Value e -> <e> Value e) -> Value e
prim2M f = VPrim (a => VPrim (b => f a b))

prim3M : (Value e -> Value e -> Value e -> <e> Value e) -> Value e
prim3M f = VPrim (a => VPrim (b => VPrim (c => f a b c)))

prim5M : (Value e -> Value e -> Value e -> Value e -> Value e -> <e> Value e) -> Value e
prim5M f =
  VPrim (a => VPrim (b => VPrim (c => VPrim (d => VPrim (x => f a b c d x)))))

prim1M : (Value e -> <e> Value e) -> Value e
prim1M f = VPrim f

-- captured stdout: putStr/putStrLn append here instead of doing real IO, so the
-- output buffer can be diffed against the === EVAL === goldens (no <IO> effect;
-- appending is just <Mut>).  ePutStr/ePutStrLn (stderr) are discarded HERE (the
-- oracle table); under `medaka run` ioExternBindings overrides them with prims
-- that stream to the real host stderr.
export outputRef : Ref String
outputRef = Ref ""

-- Runtime-diagnostic side channels (RUNTIME-DIAGNOSTIC-CHANNEL-DESIGN.md).
-- currentEvalLoc is updated at every ELoc node; currentEvalFile is set once by
-- the run driver to the target path (the parser leaves Loc.file "").  Neither is
-- read on a successful eval, so valid-program output is untouched.
export currentEvalLoc : Ref Loc
currentEvalLoc = Ref (Loc "" 0 0 0 0)

export currentEvalFile : Ref String
currentEvalFile = Ref ""

-- P0-2(a): evaluator recursion-depth guard.  The tree-walker recurses on the
-- host C stack (`eval`->`apply`->`eval`...) with no TCO, so a deep non-tail
-- recursion (e.g. `loop n = 1 + loop (n-1)`) exhausts the 256 MB worker stack
-- and dies with a bare SIGBUS.  Every function application flows through
-- `apply`, so a balanced inc/dec counter there bounds the call depth: past the
-- limit we raise a clean coded E-STACK-OVERFLOW *before* the hard crash.  The
-- limit is tuned just under where `medaka run` empirically hard-crashes for the
-- simplest per-frame program (~28-29k apply frames on the -O0 CLI build); the
-- native signal backstop (runtime/medaka_rt.c) is the ultimate guarantee for
-- heavier-per-frame programs that would crash below this bound.
evalDepthRef : Ref Int
evalDepthRef = Ref 0

evalDepthLimit : Int
evalDepthLimit = 25000

-- Stage 4 (RUNTIME-DIAGNOSTIC-CHANNEL-DESIGN.md Fork C): when set, `runtimePanic`
-- emits the `Diag`-shaped JSON envelope (same shape as `medaka check --json`)
-- instead of located text. Set once by the `run --json` CLI arm; read only at
-- the panic chokepoint, so it is inert (default False) on every other path —
-- including every valid-program eval gate.
export runJsonMode : Ref Bool
runJsonMode = Ref False

-- Update currentEvalLoc from an ELoc span, but IGNORE the placeholder span the
-- non-located `parse` produces (every token collapses to the zero-width
-- `Loc "" 1 0 1 0`).  The prelude (runtime.mdk/core.mdk) is parsed that way, so
-- when a runtime error is reached through a prelude helper (e.g. a literal
-- pattern's Eq comparison, list index dispatch) the prelude's placeholder would
-- otherwise clobber the real user-code span.  A real located atom always has a
-- positive-width span, so this sentinel is unambiguous.
updateEvalLoc : Loc -> Unit
updateEvalLoc (Loc f sl sc el ec)
  | sl == 1 && sc == 0 && el == 1 && ec == 0 = ()
  | otherwise = setRef currentEvalLoc (Loc f sl sc el ec)

-- Chokepoint for user-facing runtime errors.  `panic` is a noreturn C-abort
-- that never returns to Medaka, so the located, coded diagnostic must be
-- formatted INTO the panic string here (Fork B option iii).  The text prefix
-- mirrors resolve.mdk's ppResErrorLocatedF: `file:L:C:` with a 0-based column.
-- Stage 4: when `runJsonMode` is set, format the SAME `Diag` through the
-- exact `cjAllToJson` serializer `medaka check --json` uses (driver.diagnostics),
-- so the envelope ({"files":[{"file":...,"diagnostics":[{code,kind,message,
-- range,severity,source}]}]}) is byte-shape-identical to a compile-time
-- diagnostic. `cjRangeOfLoc` ignores its `src` argument (range comes purely
-- from the Loc), so passing "" needs no source-text threading.
export runtimePanic : String -> String -> a
runtimePanic code msg = match currentEvalLoc.value
  Loc f sl sc el ec =>
    let ff = if f == "" then currentEvalFile.value else f
    -- The string is a COMPLETE, coded runtime diagnostic; mark it with a leading
    -- 0x01 sentinel so the `panic` abort primitive (mdk_panic) prints it verbatim
    -- rather than re-wrapping it in its native-user-panic `[E-PANIC]` banner.
    if runJsonMode.value then
      let diag = Diag SevError code msg (Some (Loc ff sl sc el ec)) None None
      panic "\{fmtSentinel}\{cjAllToJson [(ff, "", [diag])]}"
    else panic "\{fmtSentinel}\{ff}:\{intToString sl}:\{intToString sc}: runtime error [\{code}]: \{msg}"

-- 0x01 marker (see runtimePanic / mdk_panic): a preformatted runtime diagnostic
-- the abort primitive must print verbatim, never re-banner.
-- `\u{01}` (SOH), written as an ESCAPE, not as a raw 0x01 byte. It used to be raw --
-- `medaka fmt`'s string escaper passed control chars through untouched, so the byte
-- survived every reformat. The same defect put a literal NUL in printer.mdk, which
-- made that file BINARY to grep (see printer.mdk's escStringLit note). The escaper
-- now emits \0 and \u{XX}, so this escape round-trips instead of being lowered back.
fmtSentinel : String
fmtSentinel = "\u{01}"

appendOutput : String -> <e> Value e
appendOutput s =
  let _ = setRef outputRef (outputRef.value ++ s)
  -- Snapshot the buffer's raw bytes into the native runtime (O(1)
  -- pointer+length store; no allocation, no observable effect on its own —
  -- see stdlib/runtime.mdk's stashRunStdout doc comment) so a subsequent
  -- abort can flush it.  Called from BOTH the real `medaka run` path and the
  -- pure differential-oracle path (this function is shared), which is fine:
  -- the stash is inert unless `enableRunStdoutFlush` was also called, and
  -- only `evalModulesOutputRun`/`evalModulesOutputAsync` (never the oracle
  -- probes) call that.
  let _ = stashRunStdout outputRef.value
  VUnit

pPutStr : Value e -> <e> Value e
pPutStr (VString s) = appendOutput s
pPutStr _ = panic "putStr: not a String"

pPutStrLn : Value e -> <e> Value e
pPutStrLn (VString s) = appendOutput (s ++ "\n")
pPutStrLn _ = panic "putStrLn: not a String"

pStashRunStdout : Value e -> <e> Value e
pStashRunStdout (VString s) = let _ = stashRunStdout s in VUnit
pStashRunStdout _ = panic "stashRunStdout: not a String"

pEnableRunStdoutFlush : Value e -> <e> Value e
pEnableRunStdoutFlush _ = let _ = enableRunStdoutFlush () in VUnit

pDiscard : Value e -> <e> Value e
pDiscard _ = VUnit

-- The `panic` extern (stdlib/runtime.mdk: `panic : String -> a`) was missing
-- from externBindings, so a user program's own call to `panic "msg"` hit
-- "unbound identifier: panic" instead of aborting — even though the
-- interpreter's OWN internal errors (division by zero, etc.) already route
-- through the real host `panic` (a genuine, unrecoverable abort — no
-- catchable panics, see AGENTS.md).  Wiring the extern to the same host
-- `panic` fixes both `explicit_panic`/`let_else_fail` fixtures.
pPanic : Value e -> <e> a
pPanic v = runtimePanic "E-PANIC" (unString v)

pRef : Value e -> <e> Value e
pRef v = VRef (Ref v)

pSetRef : Value e -> Value e -> <e> Value e
pSetRef (VRef cell) v = doSetRef cell v
pSetRef _ _ = panic "setRef: not a Ref"

doSetRef : Ref (Value e) -> Value e -> <e> Value e
doSetRef cell v =
  let _ = setRef cell v
  VUnit

unString : Value e -> String
unString (VString s) = s
unString _ = panic "expected a String"

unChar : Value e -> Char
unChar (VChar s) = arrayGetUnsafe 0 (stringToChars s)
unChar _ = panic "expected a Char"

orderingToValue : Ordering -> Value e
orderingToValue Lt = VCon "Lt" []
orderingToValue Eq = VCon "Eq" []
orderingToValue Gt = VCon "Gt" []

optionToValue : Option (Value e) -> Value e
optionToValue None = VCon "None" []
optionToValue (Some v) = VCon "Some" [v]

-- ── uint64 emulation over four 16-bit limbs ────────────────────────────────
-- Medaka's Int is a 63-bit fixnum, so the SplitMix64 RNG and the SplitMix64/
-- FNV-1a hashers in runtime/medaka_rt.c — which are pure uint64 arithmetic —
-- cannot be reproduced with native `*`/`shiftRight` (their products and left
-- shifts overflow 64 bits, and Medaka has no wider integer). We instead emulate
-- a uint64 as a 4-tuple of 16-bit limbs `(l0, l1, l2, l3)`, least-significant
-- first, and hand-roll add / multiply-low / xor / shift-right over that rep.
-- Every intermediate stays well under the 63-bit range: a limb < 2^16, a 16×16
-- partial product < 2^32, and a column sum of four such products plus a carry
-- < 2^35 — so no native op ever overflows. The results are byte-identical to
-- the C runtime (self-checked: mix64(42)&mask == 803958421, first SplitMix64
-- draw from state 42 gives `%6+1 == 2`), which is exactly what closes the
-- eval-vs-native RNG/hash divergence (issue #98).

-- Golden ratio increment 0x9E3779B97F4A7C15 as limbs.
u64Golden : (Int, Int, Int, Int)
u64Golden = (31765, 32586, 31161, 40503)  -- 7C15 7F4A 79B9 9E37

-- SplitMix64 finalizer multipliers.
u64Const1 : (Int, Int, Int, Int)
u64Const1 = (58809, 7396, 18285, 48984)  -- 0xBF58476D1CE4E5B9: E5B9 1CE4 476D BF58

u64Const2 : (Int, Int, Int, Int)
u64Const2 = (4587, 4913, 18875, 38096)  -- 0x94D049BB133111EB: 11EB 1331 49BB 94D0

-- FNV-1a 64-bit offset basis 0xCBF29CE484222325 and prime 0x100000001B3.
u64FnvBasis : (Int, Int, Int, Int)
u64FnvBasis = (8997, 33826, 40164, 52210)  -- 2325 8422 9CE4 CBF2

u64FnvPrime : (Int, Int, Int, Int)
u64FnvPrime = (435, 0, 256, 0)  -- 01B3 0000 0100 0000

-- `ofInt`/`add64`/`mulLow64`/`xor64`/`limbAt`/`shr64` (plus the `shiftWords`
-- helper `shr64` needs) are imported from stdlib `bits64` above — the compiler
-- shares the one proven limb library rather than re-deriving it here (#223).

-- SplitMix64 finalizer, then `mix64 x = finalize (x + golden)` — identical to
-- mdk_hash_mix64, and one SplitMix64 step (state += golden; finalize).
u64Finalize : (Int, Int, Int, Int) -> (Int, Int, Int, Int)
u64Finalize z =
  let z1 = mulLow64 (xor64 z (shr64 z 30)) u64Const1
  let z2 = mulLow64 (xor64 z1 (shr64 z1 27)) u64Const2
  xor64 z2 (shr64 z2 31)

u64Mix : (Int, Int, Int, Int) -> (Int, Int, Int, Int)
u64Mix x = u64Finalize (add64 x u64Golden)

-- Low 30 bits (the native MDK_HASH_MASK = 2^30 - 1) as a non-negative Int.
u64Low30 : (Int, Int, Int, Int) -> Int
u64Low30 (a0, a1, _, _) = bitAnd (bitOr a0 (shiftLeft a1 16)) 1073741823

-- uint64 -> Int, for a value known to fit in a positive Medaka Int (< 2^62):
-- the randomFloat mantissa (53 bits) and any `next % range` remainder (< range
-- <= 2^62 - 1) both qualify, so `shiftLeft a3 48` never reaches the sign bit.
u64ToInt : (Int, Int, Int, Int) -> Int
u64ToInt (a0, a1, a2, a3) =
  bitOr (bitOr a0 (shiftLeft a1 16)) (bitOr (shiftLeft a2 32) (shiftLeft a3 48))

-- `sub64` (borrow-propagating subtraction) and `mod64` (exact long division —
-- eval's old `u64Mod`/`u64ModExactGo`/`u64BitAt`/`cmp64` collapse into it, the
-- zero-divisor guard being a harmless superset the RNG never triggers) and
-- `isZero` are imported from stdlib `bits64` above (#223).

-- Bit 63 — the sign bit under a two's-complement (signed long long) reading.
u64Bit63 : (Int, Int, Int, Int) -> Int
u64Bit63 (_, _, _, a3) = bitAnd (shiftRight a3 15) 1

-- uint64 -> signed Medaka Int, interpreting the top bit as a two's-complement
-- sign. Used only where the value is known to land in [-2^62, 2^62 - 1] (a
-- randomInt result is always in [lo, hi]); the sign-extended `hi16 << 48` then
-- has magnitude <= 2^62, so it fits the Int without overflow.
u64ToSignedInt : (Int, Int, Int, Int) -> Int
u64ToSignedInt (a0, a1, a2, a3) =
  let hi16 = if bitAnd a3 32768 == 0 then a3 else a3 - 65536
  bitOr (bitOr a0 (shiftLeft a1 16)) (shiftLeft a2 32) + shiftLeft hi16 48

-- ── deterministic SplitMix64 RNG — byte-identical to runtime/medaka_rt.c ─────
-- State is a uint64 (limb tuple), default 0; `setSeed n` sets state = n. Each
-- draw advances state += golden then finalizes, so the eval draws match the
-- native binary's for every seed (this is what makes `medaka run` == `medaka
-- build` for random* — issue #98). prop_runner.mdk keeps its OWN independent LCG
-- over `rngStateRef` for property-value generation (deliberately unrelated: a
-- passing prop prints `OK (100 tests)` regardless of the draws, and a failing
-- prop's shrunk counterexample is engine-specific — see test/diff_compiler_test.sh).
export rngStateRef : Ref Int
rngStateRef = Ref 123456789

rngU64Ref : Ref (Int, Int, Int, Int)
rngU64Ref = Ref (0, 0, 0, 0)

-- One SplitMix64 step: advance the global state and return the finalized draw.
rngDraw : Unit -> (Int, Int, Int, Int)
rngDraw _ =
  let s = add64 rngU64Ref.value u64Golden
  let _ = setRef rngU64Ref s
  u64Finalize s

-- randomInt lo hi (INCLUSIVE). Mirrors mdk_random_int (medaka_rt.c) EXACTLY,
-- including for spans that overflow a 62-bit Medaka Int: native computes
-- `range = hi - lo + 1` and the modulus in 64-bit, so eval must too, or the
-- draw sequence itself desyncs. Everything is done in uint64 — `hi - lo + 1`
-- via sub64/add64, native's `range <= 0` guard as `zero || sign-bit set`, the
-- modulus with the exact long division, and `lo + rem` back to a signed Int —
-- so no bare 63-bit Int op is ever asked to hold a value it cannot (issue #98).
pRandomInt : Value e -> Value e -> <e> Value e
pRandomInt (VInt lo) (VInt hi) =
  let loU = ofInt lo
  let rangeU = add64 (sub64 (ofInt hi) loU) (ofInt 1)
  if isZero rangeU || u64Bit63 rangeU == 1 then VInt lo
  else
    let rem = mod64 (rngDraw ()) rangeU
    VInt (u64ToSignedInt (add64 loU rem))
pRandomInt _ _ = panic "randomInt: expected Int Int"

pRandomBool : Value e -> <e> Value e
pRandomBool _ = VBool (bitAnd (limbAt (rngDraw ()) 0) 1 == 1)

pRandomFloat : Value e -> <e> Value e
pRandomFloat _ =
  -- `intToFloat 9007199254740992` is the double 2^53 (the mantissa scale); written
  -- via an Int literal because `medaka fmt` corrupts a >= 1e15 float literal (#51).
  let bits = u64ToInt (shr64 (rngDraw ()) 11)
  VFloat (intToFloat bits * (1.0 / intToFloat 9007199254740992) * 2.0 - 1.0)

pRandomChar : Value e -> <e> Value e
pRandomChar _ =
  VChar (charToStr (charFromCodeUnsafe
    (32 + u64ToInt (mod64 (rngDraw ()) (ofInt 95)))))

charFromCodeUnsafe : Int -> Char
-- Intentional cross-file duplicate of the same helper in prop_runner.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
charFromCodeUnsafe n = match charFromCode n
  Some c => c
  None => ' '

pSetSeed : Value e -> <e> Value e
pSetSeed (VInt seed) =
  let _ = setRef rngU64Ref (ofInt seed)
  VUnit
pSetSeed _ = panic "setSeed: expected Int"

-- ORACLE-ONLY frozen constants for the clock/GC externs.  These are the
-- DIFFERENTIAL-ORACLE bindings: the oracle drivers diff captured stdout, so a
-- real clock would make every golden nondeterministic.  They live in the pure
-- `externBindings` table and are OVERRIDDEN under `medaka run` by the real host
-- clock/GC prims in `ioExternBindings` (last-write-wins on the duplicate name —
-- see the note there).  Historically these WERE the only implementation, and the
-- comment here claimed "the interpreter has no FFI to the clock" — a fossil from
-- when eval.mdk was purely a value oracle.  It is compiled by the LLVM backend
-- and linked against runtime/medaka_rt.c; there is no FFI barrier.
pWallTimeSec : Value e -> <e> Value e
pWallTimeSec _ = VFloat 1700000000.0

pMonotonicSec : Value e -> <e> Value e
pMonotonicSec _ = VFloat 1000.0

pSleepMs : Value e -> <e> Value e
pSleepMs (VInt _) = VUnit
pSleepMs _ = panic "sleepMs: expected Int"

pAllocBytes : Value e -> <e> Value e
pAllocBytes _ = VFloat 0.0

-- flushStdout is a genuine no-op under the interpreter's output model: stdout
-- is buffered into `outputRef` and printed only after `main` returns (see
-- `stashRunStdout`/`enableRunStdoutFlush` below), so there is nothing to flush
-- mid-run.  Implemented in the C runtime + LLVM emitter (issue #71); this binds
-- it here so `medaka run`/`medaka test` don't panic `unbound variable`.
pFlushStdout : Value e -> <e> Value e
pFlushStdout VUnit = VUnit
pFlushStdout _ = panic "flushStdout: expected Unit"

-- B2: a FUNCTION (not a top-level value) so every consumer instantiates a
-- fresh row `e` — a top-level Value-typed value would fall to the value
-- restriction (function applications are not generalized) and pin one global
-- row across the oracle and run paths.
export externBindings : Unit -> List (String, Value e)
externBindings _ = [
  ("randomInt", prim2M pRandomInt),
  ("randomBool", prim1M pRandomBool),
  ("randomFloat", prim1M pRandomFloat),
  ("randomChar", prim1M pRandomChar),
  ("setSeed", prim1M pSetSeed),
  ("wallTimeSec", prim1M pWallTimeSec),
  ("monotonicSec", prim1M pMonotonicSec),
  ("sleepMs", prim1M pSleepMs),
  ("allocBytes", prim1M pAllocBytes),
  ("flushStdout", prim1M pFlushStdout),
  ("intToString", prim1 pIntToString),
  ("bitAnd", prim2 pBitAnd),
  ("bitOr", prim2 pBitOr),
  ("bitXor", prim2 pBitXor),
  ("shiftLeft", prim2 pShiftLeft),
  ("shiftRight", prim2 pShiftRight),
  ("bitNot", prim1 pBitNot),
  ("intToFloat", prim1 pIntToFloat),
  ("floatToInt", prim1 pFloatToInt),
  ("floatToString", prim1 pFloatToString),
  ("charToStr", prim1 pCharToStr),
  ("charCode", prim1 pCharCode),
  ("charFromCode", prim1 pCharFromCode),
  ("charToUpper", prim1 pCharToUpper),
  ("charToLower", prim1 pCharToLower),
  ("stringLength", prim1 pStringLength),
  ("stringConcat", prim1 pStringConcat),
  ("stringToChars", prim1 pStringToChars),
  ("stringFromChars", prim1 pStringFromChars),
  ("stringToUtf8Bytes", prim1 pStringToUtf8Bytes),
  ("stringFromUtf8Bytes", prim1 pStringFromUtf8Bytes),
  ("floatRem", prim2 pFloatRem),
  ("sqrt", prim1 pSqrt),
  ("cbrt", prim1 pCbrt),
  ("exp", prim1 pExp),
  ("log", prim1 pLog),
  ("log2", prim1 pLog2),
  ("log10", prim1 pLog10),
  ("sin", prim1 pSin),
  ("cos", prim1 pCos),
  ("tan", prim1 pTan),
  ("asin", prim1 pAsin),
  ("acos", prim1 pAcos),
  ("atan", prim1 pAtan),
  ("sinh", prim1 pSinh),
  ("cosh", prim1 pCosh),
  ("tanh", prim1 pTanh),
  ("floor", prim1 pFloor),
  ("ceil", prim1 pCeil),
  ("round", prim1 pRound),
  ("trunc", prim1 pTrunc),
  ("pow", prim2 pPow),
  ("atan2", prim2 pAtan2),
  ("hypot", prim2 pHypot),
  ("stringToUpper", prim1 pStringToUpper),
  ("stringToLower", prim1 pStringToLower),
  ("stringCompare", prim2 pStringCompare),
  ("stringIndexOf", prim2 pStringIndexOf),
  ("stringSlice", prim3 pStringSlice),
  ("arrayLength", prim1 pArrayLength),
  ("arrayFromList", prim1 pArrayFromList),
  ("arrayGetUnsafe", prim2 pArrayGetUnsafe),
  ("arrayMake", prim2 pArrayMake),
  ("arrayMakeWith", prim2M pArrayMakeWith),
  ("arrayCopy", prim1 pArrayCopy),
  ("arraySetUnsafe", prim3M pArraySetUnsafe),
  ("arrayBlit", prim5M pArrayBlit),
  ("arrayFill", prim2M pArrayFill),
  ("Ref", prim1 pRef),
  ("setRef", prim2M pSetRef),
  ("putStr", prim1M pPutStr),
  ("putStrLn", prim1M pPutStrLn),
  ("ePutStr", prim1M pDiscard),
  ("ePutStrLn", prim1M pDiscard),
  ("stashRunStdout", prim1M pStashRunStdout),
  ("enableRunStdoutFlush", prim1M pEnableRunStdoutFlush),
  ("panic", prim1 pPanic),
  ("indexError", prim1 (s => runtimePanic "E-INDEX-OOB" (unString s))),
  ("debugStringLit", prim1 pDebugStringLit),
  ("debugCharLit", prim1 pDebugCharLit),
  ("stringToFloat", prim1 pStringToFloat),
  ("charIsAlpha", prim1 (charPred charIsAlpha)),
  ("charIsSpace", prim1 (charPred charIsSpace)),
  ("charIsUpper", prim1 (charPred charIsUpper)),
  ("charIsLower", prim1 (charPred charIsLower)),
  ("charIsPunct", prim1 (charPred charIsPunct)),
  ("intMinBound", VInt intMinBound),
  ("intMaxBound", VInt intMaxBound),
  ("charMinBound", VChar (charToStr charMinBound)),
  ("charMaxBound", VChar (charToStr charMaxBound)),
  ("pi", VFloat pi),
  ("e", VFloat e),
  ("intBitsToFloat", prim1 pIntBitsToFloat),
  ("bytesToFloat64", prim2 pBytesToFloat64),
  ("floatToBytes64", prim1 pFloatToBytes64),
  ("hashInt", prim1 pHashInt),
  ("hashFloat", prim1 pHashFloat),
  ("hashString", prim1 pHashString),
  ("hashChar", prim1 pHashChar),
  ("hashBool", prim1 pHashBool),
  (fallthroughName, prim1 (_ => VFallthrough)),
]

pDebugStringLit : Value e -> <e> Value e
pDebugStringLit (VString s) = VString (debugStringLit s)
pDebugStringLit _ = panic "debugStringLit: not a String"

pDebugCharLit : Value e -> <e> Value e
pDebugCharLit (VChar s) = VString (debugCharLit (unChar (VChar s)))
pDebugCharLit _ = panic "debugCharLit: not a Char"

pStringToFloat : Value e -> <e> Value e
pStringToFloat (VString s) = optionToValue (mapOption VFloat (stringToFloat s))
pStringToFloat _ = panic "stringToFloat: not a String"

charPred : (Char -> Bool) -> Value e -> <e> Value e
charPred f (VChar s) = VBool (f (unChar (VChar s)))
charPred _ _ = panic "char predicate: not a Char"

pIntToString : Value e -> <e> Value e
pIntToString (VInt n) = VString (intToString n)
pIntToString _ = panic "intToString: not an Int"

pBitAnd : Value e -> Value e -> <e> Value e
pBitAnd (VInt a) (VInt b) = VInt (bitAnd a b)
pBitAnd _ _ = panic "bitAnd: not Ints"

pBitOr : Value e -> Value e -> <e> Value e
pBitOr (VInt a) (VInt b) = VInt (bitOr a b)
pBitOr _ _ = panic "bitOr: not Ints"

pBitXor : Value e -> Value e -> <e> Value e
pBitXor (VInt a) (VInt b) = VInt (bitXor a b)
pBitXor _ _ = panic "bitXor: not Ints"

pShiftLeft : Value e -> Value e -> <e> Value e
pShiftLeft (VInt a) (VInt b) = VInt (shiftLeft a b)
pShiftLeft _ _ = panic "shiftLeft: not Ints"

pShiftRight : Value e -> Value e -> <e> Value e
pShiftRight (VInt a) (VInt b) = VInt (shiftRight a b)
pShiftRight _ _ = panic "shiftRight: not Ints"

pBitNot : Value e -> <e> Value e
pBitNot (VInt a) = VInt (bitNot a)
pBitNot _ = panic "bitNot: not an Int"

pIntToFloat : Value e -> <e> Value e
pIntToFloat (VInt n) = VFloat (intToFloat n)
pIntToFloat _ = panic "intToFloat: not an Int"

pFloatToInt : Value e -> <e> Value e
pFloatToInt (VFloat f) = VInt (floatToInt f)
pFloatToInt _ = panic "floatToInt: not a Float"

pIntBitsToFloat : Value e -> <e> Value e
pIntBitsToFloat (VInt n) = VFloat (intBitsToFloat n)
pIntBitsToFloat _ = panic "intBitsToFloat: not an Int"

getByte64 : Int -> Array (Value e) -> Int -> Int
getByte64 off arr i = match arrayGetUnsafe (off + i) arr
  VInt b => bitAnd b 255
  _ => panic "bytesToFloat64: array element not Int"

pBytesToFloat64 : Value e -> Value e -> <e> Value e
pBytesToFloat64 (VArray arr) (VInt off)
  | off < 0 || off + 8 > arrayLength arr = runtimePanic "E-INDEX-OOB" ("index " ++ intToString off ++ " out of bounds")
pBytesToFloat64 (VArray arr) (VInt off) =
  -- Build a host Array Int of 8 bytes, then delegate to the C bytesToFloat64.
  -- Avoids the 63-bit integer overflow that plagues assembleBits+intBitsToFloat
  -- when the MSB byte produces a bit pattern > 2^62 - 1.
  let intArr = arrayMakeWith 8 (i => getByte64 off arr i)
  VFloat (bytesToFloat64 intArr 0)
pBytesToFloat64 _ _ = panic "bytesToFloat64: expected Array Int"

pFloatToBytes64 : Value e -> <e> Value e
pFloatToBytes64 (VFloat f) =
  let bs = floatToBytes64 f
  VArray (arrayMakeWith 8 (i => VInt (arrayGetUnsafe i bs)))
pFloatToBytes64 _ = panic "floatToBytes64: not a Float"

-- ── Interpreter Hashable hashers — byte-identical to runtime/medaka_rt.c ─────
-- The native mdk_hash_* are a SplitMix64/FNV-1a spec over uint64. We reproduce
-- them faithfully on the 4-limb uint64 emulation above (issue #98: an approximate
-- mixer made `medaka run` and `medaka build` disagree on hash values, both silent).
-- hashInt/hashChar/hashFloat = mix64 then mask to [0, 2^30); hashString = 64-bit
-- FNV-1a; hashBool = 0/1. `n`/codepoint arrive as the untagged native Int, so a
-- negative Int's two's-complement 64-bit value flows straight into `ofInt`.

-- One 64-bit FNV-1a step: h = (h XOR byte) * prime (low 64 bits).
fnvStep64 : (Int, Int, Int, Int) -> Int -> (Int, Int, Int, Int)
fnvStep64 (h0, h1, h2, h3) byte =
  mulLow64 (bitXor h0 byte, h1, h2, h3) u64FnvPrime

fnvFold64 : List Int -> (Int, Int, Int, Int) -> (Int, Int, Int, Int)
fnvFold64 [] h = h
fnvFold64 (x::xs) h = fnvFold64 xs (fnvStep64 h x)

-- 8 big-endian bytes (bs[0] = MSB, as floatToBytes64 emits) -> uint64 limbs.
bytesBEToU64 : Array Int -> (Int, Int, Int, Int)
bytesBEToU64 bs = (
  bitOr (arrayGetUnsafe 7 bs) (shiftLeft (arrayGetUnsafe 6 bs) 8),
  bitOr (arrayGetUnsafe 5 bs) (shiftLeft (arrayGetUnsafe 4 bs) 8),
  bitOr (arrayGetUnsafe 3 bs) (shiftLeft (arrayGetUnsafe 2 bs) 8),
  bitOr (arrayGetUnsafe 1 bs) (shiftLeft (arrayGetUnsafe 0 bs) 8),
)

pHashInt : Value e -> <e> Value e
pHashInt (VInt n) = VInt (u64Low30 (u64Mix (ofInt n)))
pHashInt _ = panic "hashInt: not an Int"

pHashChar : Value e -> <e> Value e
pHashChar (VChar s) =
  VInt (u64Low30 (u64Mix (ofInt (charCode (arrayGetUnsafe
    0
    (stringToChars s))))))
pHashChar _ = panic "hashChar: not a Char"

pHashBool : Value e -> <e> Value e
pHashBool (VBool b) = VInt (boolToInt b)
pHashBool _ = panic "hashBool: not a Bool"

pHashFloat : Value e -> <e> Value e
pHashFloat (VFloat f) =
  VInt (u64Low30 (u64Mix (bytesBEToU64 (floatToBytes64 f))))
pHashFloat _ = panic "hashFloat: not a Float"

pHashString : Value e -> <e> Value e
pHashString (VString s) =
  VInt (u64Low30 (fnvFold64 (arrayToListG (stringToUtf8Bytes s)) u64FnvBasis))
pHashString _ = panic "hashString: not a String"

pFloatToString : Value e -> <e> Value e
pFloatToString (VFloat f) = VString (floatToString f)
pFloatToString _ = panic "floatToString: not a Float"

pCharToStr : Value e -> <e> Value e
pCharToStr (VChar s) = VString s
pCharToStr _ = panic "charToStr: not a Char"

pCharCode : Value e -> <e> Value e
pCharCode (VChar s) = VInt (charCode (arrayGetUnsafe 0 (stringToChars s)))
pCharCode _ = panic "charCode: not a Char"

pCharFromCode : Value e -> <e> Value e
pCharFromCode (VInt n) = optionToValue (mapOption charToVChar (charFromCode n))
pCharFromCode _ = panic "charFromCode: not an Int"

charToVChar : Char -> Value e
charToVChar c = VChar (charToStr c)

pCharToUpper : Value e -> <e> Value e
pCharToUpper (VChar s) = VChar (charToStr (charToUpper (unChar (VChar s))))
pCharToUpper _ = panic "charToUpper: not a Char"

pCharToLower : Value e -> <e> Value e
pCharToLower (VChar s) = VChar (charToStr (charToLower (unChar (VChar s))))
pCharToLower _ = panic "charToLower: not a Char"

pStringLength : Value e -> <e> Value e
pStringLength (VString s) = VInt (stringLength s)
pStringLength _ = panic "stringLength: not a String"

pStringConcat : Value e -> <e> Value e
pStringConcat (VList vs) = VString (stringConcat (map unString vs))
pStringConcat _ = panic "stringConcat: not a List"

pStringToChars : Value e -> <e> Value e
pStringToChars (VString s) =
  VArray (arrayFromList (map charToVChar (arrayToListG (stringToChars s))))
pStringToChars _ = panic "stringToChars: not a String"

pStringFromChars : Value e -> <e> Value e
pStringFromChars (VArray vs) =
  VString (stringFromChars (arrayFromList (map unChar (arrayToListG vs))))
pStringFromChars _ = panic "stringFromChars: not an Array"

unInt : Value e -> Int
unInt (VInt n) = n
unInt _ = panic "unInt: not an Int"

pStringToUtf8Bytes : Value e -> <e> Value e
pStringToUtf8Bytes (VString s) =
  VArray (arrayFromList (map VInt (arrayToListG (stringToUtf8Bytes s))))
pStringToUtf8Bytes _ = panic "stringToUtf8Bytes: not a String"

pStringFromUtf8Bytes : Value e -> <e> Value e
pStringFromUtf8Bytes (VArray vs) =
  VString (stringFromUtf8Bytes (arrayFromList (map unInt (arrayToListG vs))))
pStringFromUtf8Bytes _ = panic "stringFromUtf8Bytes: not an Array"

pFloatRem : Value e -> Value e -> <e> Value e
pFloatRem (VFloat a) (VFloat b) = VFloat (floatRem a b)
pFloatRem _ _ = panic "floatRem: bad operands"

-- libm math prims — each calls the runtime.mdk extern of the same name, which
-- lowers to the C math.h shim (mirrors pFloatRem calling floatRem).  Native only.
pSqrt : Value e -> <e> Value e
pSqrt (VFloat a) = VFloat (sqrt a)
pSqrt _ = panic "sqrt: not a Float"
pCbrt : Value e -> <e> Value e
pCbrt (VFloat a) = VFloat (cbrt a)
pCbrt _ = panic "cbrt: not a Float"
pExp : Value e -> <e> Value e
pExp (VFloat a) = VFloat (exp a)
pExp _ = panic "exp: not a Float"
pLog : Value e -> <e> Value e
pLog (VFloat a) = VFloat (log a)
pLog _ = panic "log: not a Float"
pLog2 : Value e -> <e> Value e
pLog2 (VFloat a) = VFloat (log2 a)
pLog2 _ = panic "log2: not a Float"
pLog10 : Value e -> <e> Value e
pLog10 (VFloat a) = VFloat (log10 a)
pLog10 _ = panic "log10: not a Float"
pSin : Value e -> <e> Value e
pSin (VFloat a) = VFloat (sin a)
pSin _ = panic "sin: not a Float"
pCos : Value e -> <e> Value e
pCos (VFloat a) = VFloat (cos a)
pCos _ = panic "cos: not a Float"
pTan : Value e -> <e> Value e
pTan (VFloat a) = VFloat (tan a)
pTan _ = panic "tan: not a Float"
pAsin : Value e -> <e> Value e
pAsin (VFloat a) = VFloat (asin a)
pAsin _ = panic "asin: not a Float"
pAcos : Value e -> <e> Value e
pAcos (VFloat a) = VFloat (acos a)
pAcos _ = panic "acos: not a Float"
pAtan : Value e -> <e> Value e
pAtan (VFloat a) = VFloat (atan a)
pAtan _ = panic "atan: not a Float"
pSinh : Value e -> <e> Value e
pSinh (VFloat a) = VFloat (sinh a)
pSinh _ = panic "sinh: not a Float"
pCosh : Value e -> <e> Value e
pCosh (VFloat a) = VFloat (cosh a)
pCosh _ = panic "cosh: not a Float"
pTanh : Value e -> <e> Value e
pTanh (VFloat a) = VFloat (tanh a)
pTanh _ = panic "tanh: not a Float"
pFloor : Value e -> <e> Value e
pFloor (VFloat a) = VFloat (floor a)
pFloor _ = panic "floor: not a Float"
pCeil : Value e -> <e> Value e
pCeil (VFloat a) = VFloat (ceil a)
pCeil _ = panic "ceil: not a Float"
pRound : Value e -> <e> Value e
pRound (VFloat a) = VFloat (round a)
pRound _ = panic "round: not a Float"
pTrunc : Value e -> <e> Value e
pTrunc (VFloat a) = VFloat (trunc a)
pTrunc _ = panic "trunc: not a Float"
pPow : Value e -> Value e -> <e> Value e
pPow (VFloat a) (VFloat b) = VFloat (pow a b)
pPow _ _ = panic "pow: bad operands"
pAtan2 : Value e -> Value e -> <e> Value e
pAtan2 (VFloat a) (VFloat b) = VFloat (atan2 a b)
pAtan2 _ _ = panic "atan2: bad operands"
pHypot : Value e -> Value e -> <e> Value e
pHypot (VFloat a) (VFloat b) = VFloat (hypot a b)
pHypot _ _ = panic "hypot: bad operands"

pStringToUpper : Value e -> <e> Value e
pStringToUpper (VString s) = VString (stringToUpper s)
pStringToUpper _ = panic "stringToUpper: not a String"

pStringToLower : Value e -> <e> Value e
pStringToLower (VString s) = VString (stringToLower s)
pStringToLower _ = panic "stringToLower: not a String"

pStringCompare : Value e -> Value e -> <e> Value e
pStringCompare (VString a) (VString b) = orderingToValue (stringCompare a b)
pStringCompare _ _ = panic "stringCompare: not Strings"

pStringIndexOf : Value e -> Value e -> <e> Value e
pStringIndexOf (VString needle) (VString hay) =
  optionToValue (mapOption VInt (stringIndexOf needle hay))
pStringIndexOf _ _ = panic "stringIndexOf: not Strings"

pStringSlice : Value e -> Value e -> Value e -> <e> Value e
pStringSlice (VInt lo) (VInt hi) (VString s) = VString (stringSlice lo hi s)
pStringSlice _ _ _ = panic "stringSlice: bad operands"

pArrayLength : Value e -> <e> Value e
pArrayLength (VArray a) = VInt (arrayLength a)
pArrayLength _ = panic "arrayLength: not an Array"

pArrayFromList : Value e -> <e> Value e
pArrayFromList (VList vs) = VArray (arrayFromList vs)
pArrayFromList _ = panic "arrayFromList: not a List"

pArrayGetUnsafe : Value e -> Value e -> <e> Value e
pArrayGetUnsafe (VInt i) (VArray a) = arrayGetUnsafe i a
pArrayGetUnsafe _ _ = panic "arrayGetUnsafe: bad operands"

pArrayMake : Value e -> Value e -> <e> Value e
pArrayMake (VInt n) v = VArray (arrayMake n v)
pArrayMake _ _ = panic "arrayMake: bad operands"

-- arrayMakeWith : Int -> (Int -> a) -> Array a — higher-order, so it applies the
-- builder Value back through `apply` (hence <Mut>); builds a list then converts,
-- avoiding passing an effectful builder to the pure native arrayMakeWith extern.
pArrayMakeWith : Value e -> Value e -> <e> Value e
pArrayMakeWith (VInt n) f = VArray (arrayFromList (buildWith f 0 n))
pArrayMakeWith _ _ = panic "arrayMakeWith: bad operands"

-- arrayCopy : Array a -> Array a — a fresh, mutation-independent copy.  Routes
-- to the host `arrayCopy` extern (eval.mdk is compiled by the reference, so the
-- runtime extern is in scope), mirroring lib/eval.ml's Array.copy.
pArrayCopy : Value e -> <e> Value e
pArrayCopy (VArray a) = VArray (arrayCopy a)
pArrayCopy _ = panic "arrayCopy: not an Array"

-- arraySetUnsafe : Int -> a -> Array a -> <Mut> Unit — mutate slot i in place.
-- Routes to the host arraySetUnsafe extern (the native Array is mutable).
pArraySetUnsafe : Value e -> Value e -> Value e -> <e> Value e
pArraySetUnsafe (VInt i) v (VArray a) =
  let _ = arraySetUnsafe i v a
  VUnit
pArraySetUnsafe _ _ _ = panic "arraySetUnsafe: bad operands"

-- arrayFill : a -> Array a -> <Mut> Unit — set every slot to v.  Takes no
-- callback, so it delegates straight to the host extern (unlike the sorts and
-- arrayMakeWith below, whose function argument is a Value closure).
pArrayFill : Value e -> Value e -> <e> Value e
pArrayFill v (VArray a) =
  let _ = arrayFill v a
  VUnit
pArrayFill _ _ = panic "arrayFill: not an Array"

-- arrayBlit : Array a -> Int -> Array a -> Int -> Int -> <Mut> Unit
-- Copies len elements from src[srcOff..] into dst[dstOff..] in place.
-- Mirrors OCaml Array.blit semantics (memmove; handles overlapping regions).
blitGo : Array (Value e) -> Int -> Array (Value e) -> Int -> Int -> <e> Unit
blitGo src srcOff dst dstOff len
  | len <= 0 = ()
  | otherwise =
    let v = arrayGetUnsafe srcOff src
    arraySetUnsafe dstOff v dst
    blitGo src (srcOff + 1) dst (dstOff + 1) (len - 1)

pArrayBlit : Value e -> Value e -> Value e -> Value e -> Value e -> <e> Value e
pArrayBlit (VArray src) (VInt srcOff) (VArray dst) (VInt dstOff) (VInt len) =
  blitGo src srcOff dst dstOff len
  VUnit
pArrayBlit _ _ _ _ _ = panic "arrayBlit: bad operands"

buildWith : Value e -> Int -> Int -> <e> List (Value e)
buildWith f i n =
  if i >= n then
    []
  else
    apply f (VInt i) :: buildWith f (i + 1) n

mkGroup : List (String, (List Pat, Expr)) -> String -> (String, List (List Pat, Expr))
mkGroup defs name = (name, clausesForName name defs)

export installConsts : List (String, Ref (Value e)) -> List (String, Value e) -> <e> Unit
installConsts _ [] = ()
installConsts cells ((n, v)::rest) =
  let _ = setRef (findCell cells n) v
  installConsts cells rest

installGroups : EvalEnv (Value e) -> List (String, Ref (Value e)) -> List (String, List (List Pat, Expr)) -> <e> Unit
installGroups _ _ [] = ()
installGroups env cells ((n, clauses)::rest) =
  let _ = setRef (findCell cells n) (topGroupValue env clauses)
  installGroups env cells rest

export lookupBinding : String -> List (String, Value e) -> Option (Value e)
lookupBinding _ [] = None
lookupBinding name ((n, v)::rest)
  | n == name = Some v
  | otherwise = lookupBinding name rest

-- Shared message + code for the "no `main`" abort — dedups the three former
-- bare `panic "program has no 'main' binding"` sites.  Each site routes through
-- runtimePanic (E-NO-MAIN), matching the compiled/driver path.  NB: kept a plain
-- String constant, NOT a nullary `= runtimePanic …` binding — a top-level value
-- binding is evaluated EAGERLY at native startup, so an aborting nullary would
-- fire on every `medaka` invocation.  The runtimePanic call therefore stays
-- inline at each (lazy) match arm.
export noMainMsg : String
noMainMsg = "program has no 'main' binding"

export evalMain : List Decl -> String
evalMain prog = match lookupBinding "main" (evalOne [] ("__main__", prog))
  Some v => ppValue (force v)
  None => runtimePanic "E-NO-MAIN" noMainMsg

-- Run the program for its OUTPUT (forcing `main`, whose IO side-effects append
-- to outputRef) and return the captured stdout — diffs against === EVAL ===.
-- DRIVER-COLLAPSE Phase 5: the flat evalOutput is DELETED; evalOneOutput (the
-- 1-module case of evalModules) is the surviving OUTPUT entry point.

-- Like evalOutput, but drops any prelude function the user program redefines
-- (mirrors the reference's prelude_for shadow-drop) so a user `sum` doesn't
-- coalesce with the prelude's point-free `sum` into a mixed-arity VMulti.
export evalOutputWith : List Decl -> List Decl -> String
evalOutputWith preludeDecls userDecls = evalOneOutput
  []
  ("__main__", dropShadowed (funNamesOf userDecls) preludeDecls ++ userDecls)

export funNamesOf : List Decl -> List String
funNamesOf decls = map fst (funDefs decls)

export dropShadowedExp : List String -> List Decl -> List Decl
dropShadowedExp names decls = dropShadowed names decls

dropShadowed : List String -> List Decl -> List Decl
dropShadowed _ [] = []
dropShadowed names (d::rest)
  | shadowedFun names d = dropShadowed names rest
  | otherwise = d :: dropShadowed names rest

shadowedFun : List String -> Decl -> Bool
shadowedFun names (DFunDef _ n _ _) = contains n names
shadowedFun _ _ = False

runMainForEffect : List (String, Value e) -> <e> Value e
runMainForEffect binds = match lookupBinding "main" binds
  Some v => force v
  None => runtimePanic "E-NO-MAIN" noMainMsg

-- ── multi-module evaluation (per-module frames over a shared global) ───────
-- Port of lib/eval.ml's eval_modules.  The prelude (core) installs GLOBALLY
-- (all its names global); each loaded module's top-level funDefs are LOCAL, so
-- same-named functions across modules stay isolated (Phase 110), while ctors
-- and impl methods coalesce GLOBALLY into one coherent VMulti per interface
-- method.  Modules arrive dependency-first (loader order); a module's `import`s
-- resolve to the exporting module's cells.  The reference's explicit
-- deferred-thunk install ordering (Phase 125) is unnecessary here: VThunk
-- laziness defers every nullary binding to its first lookup, by which point all
-- modules' impls are installed.
--
-- UNTYPED path (no typecheck / dict-pass / marker), like evalOutput — correct
-- for programs without return-position dispatch (`pure`/`empty`) or
-- `=>`-constrained polymorphism, which is exactly the bootstrap's RKey-only
-- compiler source.  Simplification vs the reference: a module exposes ALL its
-- local funDef cells as exports (not just `pub` ones), which is correct for
-- programs that already passed resolve (a private name is never referenced
-- cross-module), plus the cells re-exported by a `pub import`.
-- parameterized over the value type (v := Value e), like EvalEnv — see the
-- kind-inference note on `Value`
data ModInfo v =
  | ModInfo String (List Decl) (List (String, List (List Pat, Expr))) (List (String, Ref v)) (EvalEnv v)

export evalModules : List Decl -> List (String, List Decl) -> <e> List (String, Value e)
evalModules preludeDecls modules = evalModulesWith [] preludeDecls modules

-- B2 (RUN-EFFECTS): evalModules with EXTRA extern bindings installed alongside
-- externBindings — the seam `medaka run` uses to install real-I/O prims
-- (ioExternBindings) without them ever reaching the differential-oracle
-- drivers, so the oracle's `e := <Mut>` purity stays a type-level guarantee.
export evalModulesWith : List (String, Value e) -> List Decl -> List (String, List Decl) -> <e> List (String, Value e)
evalModulesWith extraExterns preludeDecls modules =
  let externs = externBindings () ++ extraExterns
  let moduleDecls = flatMap snd modules
  let allDecls = preludeDecls ++ moduleDecls
  let _ = setRef ctorToTypeRef (buildCtorToType allDecls)
  let _ = setRef methodReqCountRef (buildMethodReqCounts allDecls)
  let disp = buildIfaceDispatch allDecls
  let ctors = collectCtors allDecls
  let preludeGroups = groupsOf preludeDecls
  let globalNames = map fst boolSeeds ++ map fst externs ++ map fst ctors ++ implMethodNames allDecls ++ map fst preludeGroups
  let globalCells = map (n => (n, Ref VUnit)) globalNames
  let globalEnv = EvalEnv [globalCells]
  let mods = buildModInfos globalCells [] modules
  let implEntries = flatMap (declImplEntries globalEnv disp) preludeDecls ++ flatMap (modImplEntries disp) mods
  let _ = installConsts globalCells boolSeeds
  let _ = installConsts globalCells externs
  let _ = installConsts globalCells ctors
  let _ = installConsts globalCells (coalesceImpls implEntries)
  let _ = installGroups globalEnv globalCells preludeGroups
  let _ = installModGroups mods
  rootLocals mods

-- pass 1: allocate each module's local cells + build its env (imports resolved
-- against already-processed modules, since loader order is dependency-first)
buildModInfos : List (String, Ref (Value e)) -> List (String, List (String, Ref (Value e))) -> List (String, List Decl) -> List (ModInfo (Value e))
buildModInfos _ _ [] = []
buildModInfos globalCells exportsMap ((mid, decls)::rest) =
  let grps = groupsOf decls
  -- P0-9: each module's OWN constructors ALSO live in its LOCAL frame (they stay
  -- in the shared global too — see evalModules — for by-name / `Type(..)`
  -- cross-module ctor imports and back-compat).  The local copy SHADOWS the
  -- global, so a module whose code constructs a same-named ctor that another
  -- module also defines at a different arity (e.g. `map`'s arity-5 `Bin` vs
  -- `set`'s arity-4 `Bin`) builds via ITS OWN `makeCtor` — the shared global is
  -- first-wins and would otherwise pick the wrong module's arity (E-NOT-A-FUNCTION).
  let modCtors = collectCtors decls
  let localCells = map (n => (n, Ref VUnit)) (map fst grps ++ map fst modCtors)
  let imports = importFrameOf exportsMap decls
  let menv = EvalEnv [localCells, imports, globalCells]
  let exports = localCells ++ methodCellsOf globalCells decls ++ pubReexports globalCells exportsMap decls
  ModInfo mid decls grps localCells menv :: buildModInfos globalCells ((mid, exports)::exportsMap) rest

-- IMPORT ALIASING: a module must ALSO export the interface/impl METHODS it declares.
--
-- Methods are not in `localCells`: they are coalesced into ONE GLOBAL cell per bare name
-- (evalModules' `globalNames`/`coalesceImpls`), because impl dispatch is global-by-name.
-- So they were absent from every module's `exports` — the very list resolveMembers /
-- importFrameOf consult to bind an import.  That gap was INVISIBLE while every import
-- kept its origin name: the reference simply fell through to the global frame unchanged.
-- The moment a local name diverges from the origin — either alias form — nothing bound
-- it anywhere, and `import shapes.{area as computeArea}` died with "unbound identifier".
--
-- The exported entry is the SAME global cell, never a copy: that cell holds the
-- coalesced dispatcher, so an alias is a second name for one dispatcher and impl
-- coalescing is untouched.
export methodCellsOf : List (String, Ref (Value e)) -> List Decl -> List (String, Ref (Value e))
methodCellsOf globalCells decls =
  flatMap (methodCell globalCells) (moduleMethodNames decls)

methodCell : List (String, Ref (Value e)) -> String -> List (String, Ref (Value e))
methodCell globalCells n = match lookupAssoc n globalCells
  Some cell => [(n, cell)]
  None => []

-- every interface/impl method name THIS module declares (unlike implMethodNames, an
-- interface method with NO default counts — it still has a global dispatch cell, put
-- there by whichever module impls it).
moduleMethodNames : List Decl -> List String
moduleMethodNames decls = dedup (flatMap moduleMethodNamesOf decls)

moduleMethodNamesOf : Decl -> List String
moduleMethodNamesOf (DImpl { methods, ... }) = map implMethodName methods
moduleMethodNamesOf (DInterface { methods, ... }) = map ifaceMethodNmE methods
moduleMethodNamesOf (DAttrib _ d) = moduleMethodNamesOf d
moduleMethodNamesOf _ = []

ifaceMethodNmE : IfaceMethod -> String
ifaceMethodNmE (IfaceMethod n _ _) = n

-- pass 2: install each module's funDef groups into its own cells (its env)
installModGroups : List (ModInfo (Value e)) -> <e> Unit
installModGroups [] = ()
installModGroups ((ModInfo _ decls grps cells menv)::rest) =
  let _ = installGroups menv cells grps
  -- P0-9: install this module's own ctor values into its local cells (allocated
  -- in buildModInfos), so map/set construct their own arity-correct `Bin`/`Tip`.
  let _ = installConsts cells (collectCtors decls)
  installModGroups rest

-- a module's impl methods / interface defaults close over ITS env but coalesce
-- into the shared global VMulti
modImplEntries : List ((String, String), List Int) -> ModInfo (Value e) -> List (String, (Int, Value e))
modImplEntries disp (ModInfo _ decls _ _ menv) =
  flatMap (declImplEntries menv disp) decls

-- the root module is last in dependency order; its locals hold `main`
rootLocals : List (ModInfo (Value e)) -> <e> List (String, Value e)
rootLocals [] = []
rootLocals [ModInfo _ _ _ cells _] = map cellResult cells
rootLocals (_::rest) = rootLocals rest

-- Like evalModules but returns the root module's FULL eval frame — local ∪
-- imports ∪ globals — flattened to (name, value).  The prop runner evaluates a
-- prop body against this single frame, and a prop references not only the
-- file's own helpers (locals) and imported names but also prelude methods like
-- `eq`/`compare` (globals), which rootLocals alone omits.  Mirrors lib/eval.ml's
-- eval_modules_root_env.
export evalModulesRootEnv : List Decl -> List (String, List Decl) -> <e> List (String, Value e)
evalModulesRootEnv preludeDecls modules =
  evalModulesRootEnvWith [] preludeDecls modules

-- B2 (RUN-EFFECTS), root-env variant: mirror of evalModulesWith for the
-- rootFullEnv path (prop runner + `test "…"` phase + repl).  Installs
-- `externBindings () ++ extraExterns` so a per-driver capability policy
-- (testCapableExterns) can override the frozen clock/GC constants without those
-- prims reaching the differential-oracle probes.  Kept in LOCKSTEP with
-- evalModulesWith — the two module drivers are deliberate parallel copies.
export evalModulesRootEnvWith : List (String, Value e) -> List Decl -> List (String, List Decl) -> <e> List (String, Value e)
evalModulesRootEnvWith extraExterns preludeDecls modules =
  let externs = externBindings () ++ extraExterns
  let moduleDecls = flatMap snd modules
  let allDecls = preludeDecls ++ moduleDecls
  let _ = setRef ctorToTypeRef (buildCtorToType allDecls)
  let _ = setRef methodReqCountRef (buildMethodReqCounts allDecls)
  let disp = buildIfaceDispatch allDecls
  let ctors = collectCtors allDecls
  let preludeGroups = groupsOf preludeDecls
  let globalNames = map fst boolSeeds ++ map fst externs ++ map fst ctors ++ implMethodNames allDecls ++ map fst preludeGroups
  let globalCells = map (n => (n, Ref VUnit)) globalNames
  let globalEnv = EvalEnv [globalCells]
  let mods = buildModInfos globalCells [] modules
  let implEntries = flatMap (declImplEntries globalEnv disp) preludeDecls ++ flatMap (modImplEntries disp) mods
  let _ = installConsts globalCells boolSeeds
  let _ = installConsts globalCells externs
  let _ = installConsts globalCells ctors
  let _ = installConsts globalCells (coalesceImpls implEntries)
  let _ = installGroups globalEnv globalCells preludeGroups
  let _ = installModGroups mods
  rootFullEnv mods globalCells

-- Flatten the root module's frame stack (locals first, then imports, then
-- globals) to an assoc list — local names shadow imports shadow globals, which
-- is the lookup order in its EvalEnv.
rootFullEnv : List (ModInfo (Value e)) -> List (String, Ref (Value e)) -> <e> List (String, Value e)
rootFullEnv [] globalCells = map cellResult globalCells
rootFullEnv [ModInfo _ _ _ cells menv] globalCells = flattenEnv menv
rootFullEnv (_::rest) globalCells = rootFullEnv rest globalCells

flattenEnv : EvalEnv (Value e) -> <e> List (String, Value e)
flattenEnv (EvalEnv frames) = map cellResult (concatList frames)

concatList : List (List a) -> List a
concatList [] = []
concatList (x::xs) = x ++ concatList xs

groupsOf : List Decl -> List (String, List (List Pat, Expr))
groupsOf decls =
  let defs = funDefs decls
  map (mkGroup defs) (funGroupNames defs [])

-- value names a DUse binds, resolved to the exporting module's exported cells
-- (mirrors lib/eval.ml build_imports); names resolving to a ctor/global are
-- omitted (reached via the global frame instead).
export importFrameOf : List (String, List (String, Ref (Value e))) -> List Decl -> List (String, Ref (Value e))
importFrameOf exportsMap decls = flatMap (useImports exportsMap) decls

useImports : List (String, List (String, Ref (Value e))) -> Decl -> List (String, Ref (Value e))
useImports exportsMap (DUse _ path _) = match lookupAssoc (useModuleId path) exportsMap
  None => []
  Some exports => resolveMembers path exports
useImports _ _ = []

-- cells re-exported by a `pub import`.
--
-- `core` re-exports resolve against `globalCells`, not `exportsMap`: core is the
-- implicit prelude, so it is installed straight into the GLOBAL frame and never
-- appears in exportsMap as a module.  Matches resolve's `coreExports` — the two must
-- agree on core's surface or a name resolve accepts would be unbound at eval.
--
-- The re-exporter's export list must really CONTAIN the cell, not merely tolerate the
-- name: an importer that ALIASES it (`import list.{filter as keep}` — legal; it is the
-- `export import` side that may not alias) is bound by `resolveMembers`, which looks the
-- ORIGIN up in this list and enters it under the LOCAL name.  With core absent from
-- exportsMap that lookup missed, `keep` bound nothing, and only an unaliased reference
-- survived — by falling through to the global frame, which is not binding, just luck.
export pubReexports : List (String, Ref (Value e)) -> List (String, List (String, Ref (Value e))) -> List Decl -> List (String, Ref (Value e))
pubReexports globalCells exportsMap decls =
  flatMap (reexport globalCells exportsMap) decls

reexport : List (String, Ref (Value e)) -> List (String, List (String, Ref (Value e))) -> Decl -> List (String, Ref (Value e))
reexport globalCells exportsMap (DUse True path _) =
  let src = if useModuleId path == "core" then
    Some globalCells
  else
    lookupAssoc (useModuleId path) exportsMap
  match src
    None => []
    Some exports => resolveMembers path exports
reexport _ _ _ = []

-- The cells an import binds into the importing module's frame, keyed by the LOCAL name.
-- The origin module's cell is shared by REFERENCE, so an alias is a second name for the
-- very same cell — never a copy.
resolveMembers : UsePath -> List (String, Ref (Value e)) -> List (String, Ref (Value e))
resolveMembers (UseName ns) exports =
  if listLen ns > 1 then
    bindNames [selfBind (lastOfList ns)] exports
  else
    []
resolveMembers (UseGroup _ ms) exports = bindNames (map memberBind ms) exports
resolveMembers (UseWild _) exports = exports
-- `import m as A` → every export of m, under `A.name`.  This is what makes two modules
-- exporting the SAME name importable at once: their cells land under distinct keys, so
-- the importing frame's first-match lookup can no longer collapse them.
resolveMembers (UseAlias _ a) exports = map (qualifyCell a) exports

qualifyCell : String -> (String, Ref (Value e)) -> (String, Ref (Value e))
qualifyCell a (n, cell) = (qualifiedLocal a n, cell)

-- bind (origin, local) pairs: look the cell up by ORIGIN, enter it under LOCAL.
bindNames : List (String, String) -> List (String, Ref (Value e)) -> List (String, Ref (Value e))
bindNames [] _ = []
bindNames ((origin, local)::rest) exports = match lookupAssoc origin exports
  Some cell => (local, cell) :: bindNames rest exports
  None => bindNames rest exports

memberBind : UseMember -> (String, String)
memberBind m = (useMemberOrigin m, useMemberLocal m)

selfBind : String -> (String, String)
selfBind n = (n, n)

useModuleId : UsePath -> String
useModuleId (UseName ns) =
  if listLen ns > 1 then
    joinDot (initList ns)
  else
    firstOrEmpty ns
useModuleId (UseGroup ns _) = joinDot ns
useModuleId (UseWild ns) = joinDot ns
useModuleId (UseAlias ns _) = joinDot ns

lastOfList : List String -> String
lastOfList [] = ""
lastOfList [x] = x
lastOfList (_::rest) = lastOfList rest

firstOrEmpty : List String -> String
firstOrEmpty [] = ""
firstOrEmpty (x::_) = x

-- Run a multi-module program for its OUTPUT (the loader-driven analog of
-- evalOutput): evaluate every module in dependency order, force the root
-- module's `main` for its IO side-effects, return the captured stdout.
export evalModulesOutput : List Decl -> List (String, List Decl) -> String
evalModulesOutput preludeDecls modules =
  let _ = setRef outputRef ""
  let binds = evalModules preludeDecls modules
  let _ = runMainForEffect binds
  outputRef.value

-- ── run-path real-I/O externs (B2, RUN-EFFECTS) ────────────────────────────
-- Real-I/O primitives installed ONLY by `medaka run`'s driver
-- (evalModulesOutputRun) — never by the differential-oracle drivers, so the
-- oracle's `e := <Mut>` instantiation stays pure by type.
--
-- OVERRIDE SEMANTICS: evalModulesWith installs `externBindings () ++ extraExterns`
-- through installConsts, which is LAST-WRITE-WINS on a duplicate name (findCell
-- returns the first cell; installConsts writes each entry in turn).  So an extern
-- present in BOTH tables resolves to the ioExternBindings one under `medaka run`
-- and to the externBindings one under the oracle.  That is deliberate for the
-- clock/GC/stderr prims: the oracle keeps its DETERMINISTIC frozen constants (it
-- diffs output, so a real clock would make it nondeterministic), while `run` — the
-- production engine — gets the real host clock.  Before this seam existed the
-- frozen constants were the ONLY implementation, so `medaka run` silently reported
-- every elapsed interval as 0.0 and silently discarded every byte of stderr.
--
-- STDERR IS UNBUFFERED, STDOUT IS NOT.  putStr/putStrLn append to `outputRef` and
-- the CLI prints the buffer after `main` returns; ePutStr/ePutStrLn below write
-- through to the host stderr IMMEDIATELY.  Streaming is the right call for a
-- diagnostic channel: a log line that only appears after the program finishes is
-- much less useful, and — unlike buffered stdout, which is lost when a program
-- panics — a streamed stderr line survives the abort.  The cost is that stdout and
-- stderr do not interleave in real time when both are redirected to one file;
-- that is a property of the buffered-stdout design, tracked separately as
-- "`run` drops stdout on panic", and streaming stderr is a step toward, not away
-- from, fixing it.
pReadFile : Value e -> <FileRead "_" | e> Value e
pReadFile (VString path) = match readFile path
  Ok s => VCon "Ok" [VString s]
  Err m => VCon "Err" [VString m]
pReadFile _ = panic "readFile: not a String"

-- ── Value marshalling for the I/O prims ───────────────────────────────────
resultToValue : Result String (Value e) -> Value e
resultToValue (Ok v) = VCon "Ok" [v]
resultToValue (Err m) = VCon "Err" [VString m]

unitResultToValue : Result String Unit -> Value e
unitResultToValue r = resultToValue (mapResultOk (_ => VUnit) r)

mapResultOk : (a -> b) -> Result String a -> Result String b
mapResultOk f (Ok v) = Ok (f v)
mapResultOk _ (Err m) = Err m

vStringList : List String -> Value e
vStringList xs = VList (map VString xs)

vIntArray : Array Int -> Value e
vIntArray bs = VArray (arrayFromList (map VInt (arrayToListG bs)))

unIntArray : Value e -> Array Int
unIntArray (VArray vs) = arrayFromList (map unInt (arrayToListG vs))
unIntArray _ = panic "expected an Array of Int"

vOptionString : Option String -> Value e
vOptionString o = optionToValue (mapOption VString o)

-- ── Clock / GC (was: frozen constants) ────────────────────────────────────
pWallTimeSecIO : Value e -> <Clock | e> Value e
pWallTimeSecIO _ = VFloat (wallTimeSec ())

pMonotonicSecIO : Value e -> <Clock | e> Value e
pMonotonicSecIO _ = VFloat (monotonicSec ())

pSleepMsIO : Value e -> <Clock | e> Value e
pSleepMsIO (VInt n) =
  let _ = sleepMs n
  VUnit
pSleepMsIO _ = panic "sleepMs: expected Int"

-- The `exit` extern (stdlib/runtime.mdk: `exit : Int -> <Panic> Unit`) is
-- declared in the catalog but had NO binding anywhere in eval.mdk, so a user
-- program's `exit 0`/`exit 1` hit "unbound identifier: exit" under `medaka
-- run` while the native `medaka build` binary already handled it correctly
-- (llvm_emit.mdk's isAbortExtern groups "exit" with "panic"/"indexError" and
-- lowers it straight to @mdk_exit).
--
-- Deliberately bound HERE (ioExternBindings, `medaka run`-only), NOT in the
-- shared `externBindings` table pPanic/indexError live in: `externBindings` is
-- also installed by `medaka test`/`medaka repl`/`medaka check-policy`'s
-- evalModules, which batches MANY programs (doctests) through one long-lived
-- process. A real process-terminating `exit` bound there would let a single
-- `exit 0` inside one doctest silently kill the entire `medaka test` run with
-- a SUCCESS status, abandoning every doctest after it — exactly the
-- per-driver hazard test/CAPABILITY-EXCEPTIONS.txt flagged this extern as
-- "DEFERRED ON PURPOSE" for. Scoping it to ioExternBindings (installed only by
-- evalModulesOutputRun, `medaka run`'s own driver) avoids that: the pure
-- oracle and the batch test/repl drivers still see "unbound identifier: exit"
-- (unchanged, pre-existing behavior), while `medaka run` — the one driver that
-- ever runs exactly ONE program per process — gets the real thing.
--
-- Unlike `pPanic`, this must NOT route through `runtimePanic` — exit is a
-- silent, coded-free process termination (matching native `mdk_exit`'s bare
-- `exit((int)(tagged >> 1))`), not a diagnostic. So it calls the real `exit`
-- extern directly, same shape as `pSleepMsIO` calling the real `sleepMs`:
-- eval.mdk is itself compiled natively, so this call lowers to a genuine
-- @mdk_exit — a real process exit with the given code. (mdk_exit itself now
-- also flushes the run-stdout stash first — see its comment in
-- runtime/medaka_rt.c — so output printed before the exit call is not lost.)
pExit : Value e -> <e> Value e
pExit (VInt n) =
  let _ = exit n
  VUnit
pExit _ = panic "exit: not an Int"

pAllocBytesIO : Value e -> <IO | e> Value e
pAllocBytesIO _ = VFloat (allocBytes ())

-- ── stderr (was: pDiscard — ALL stderr was silently dropped) ───────────────
pEPutStr : Value e -> <Stderr | e> Value e
pEPutStr (VString s) =
  let _ = ePutStr s
  VUnit
pEPutStr _ = panic "ePutStr: not a String"

pEPutStrLn : Value e -> <Stderr | e> Value e
pEPutStrLn (VString s) =
  let _ = ePutStrLn s
  VUnit
pEPutStrLn _ = panic "ePutStrLn: not a String"

-- ── File ──────────────────────────────────────────────────────────────────
pReadFileBytes : Value e -> <FileRead "_" | e> Value e
pReadFileBytes (VString path) =
  resultToValue (mapResultOk vIntArray (readFileBytes path))
pReadFileBytes _ = panic "readFileBytes: not a String"

pFileExists : Value e -> <FileRead "_" | e> Value e
pFileExists (VString path) = VBool (fileExists path)
pFileExists _ = panic "fileExists: not a String"

pCanonicalizePath : Value e -> <FileRead "_" | e> Value e
pCanonicalizePath (VString path) = VString (canonicalizePath path)
pCanonicalizePath _ = panic "canonicalizePath: not a String"

pListDir : Value e -> <FileRead "_" | e> Value e
pListDir (VString path) = resultToValue (mapResultOk vStringList (listDir path))
pListDir _ = panic "listDir: not a String"

-- statFile : String -> Result String (Int, Bool, Bool, Float)  (size, isDir, isFile, mtime)
pStatFile : Value e -> <FileRead "_" | e> Value e
pStatFile (VString path) = resultToValue (mapResultOk statTuple (statFile path))
pStatFile _ = panic "statFile: not a String"

statTuple : (Int, Bool, Bool, Float) -> Value e
statTuple (sz, isDir, isFile, mtime) =
  VTuple [VInt sz, VBool isDir, VBool isFile, VFloat mtime]

pWriteFile : Value e -> Value e -> <FileWrite "_" | e> Value e
pWriteFile (VString path) (VString s) = unitResultToValue (writeFile path s)
pWriteFile _ _ = panic "writeFile: expected String String"

pWriteFileBytes : Value e -> Value e -> <FileWrite "_" | e> Value e
pWriteFileBytes (VString path) bs =
  unitResultToValue (writeFileBytes path (unIntArray bs))
pWriteFileBytes _ _ = panic "writeFileBytes: expected String (Array Int)"

pAppendFile : Value e -> Value e -> <FileWrite "_" | e> Value e
pAppendFile (VString path) (VString s) = unitResultToValue (appendFile path s)
pAppendFile _ _ = panic "appendFile: expected String String"

pMakeDir : Value e -> <FileWrite "_" | e> Value e
pMakeDir (VString path) = unitResultToValue (makeDir path)
pMakeDir _ = panic "makeDir: not a String"

pRemoveFile : Value e -> <FileWrite "_" | e> Value e
pRemoveFile (VString path) = unitResultToValue (removeFile path)
pRemoveFile _ = panic "removeFile: not a String"

pRemoveDir : Value e -> <FileWrite "_" | e> Value e
pRemoveDir (VString path) = unitResultToValue (removeDir path)
pRemoveDir _ = panic "removeDir: not a String"

pRename : Value e -> Value e -> <FileWrite "_" | e> Value e
pRename (VString old) (VString new) = unitResultToValue (rename old new)
pRename _ _ = panic "rename: expected String String"

-- ── Env ───────────────────────────────────────────────────────────────────
-- `args` is the interpreted PROGRAM's argv, not the host `medaka` process's:
-- under `medaka run [flags] prog.mdk a b c` the program must see ["a","b","c"].
-- The CLI's run arm knows where its own flags/target end, so it publishes the
-- trailing args here (setRef progArgsRef) before driving the evaluator; deriving
-- them inside eval.mdk would mean re-parsing the CLI's own grammar.  Default []
-- keeps every other driver (which never sets it) at "no program args".
export progArgsRef : Ref (List String)
progArgsRef = Ref []

pArgs : Value e -> <Env | e> Value e
pArgs _ = vStringList progArgsRef.value

pGetEnv : Value e -> <Env "_" | e> Value e
pGetEnv (VString name) = vOptionString (getEnv name)
pGetEnv _ = panic "getEnv: not a String"

pExecutablePath : Value e -> <Env | e> Value e
pExecutablePath _ = VString (executablePath ())

pBuildFingerprint : Value e -> <Env | e> Value e
pBuildFingerprint _ = VString (buildFingerprint ())

-- ── Stdin ─────────────────────────────────────────────────────────────────
pReadLine : Value e -> <Stdin | e> Value e
pReadLine _ = VString (readLine ())

pReadLineOpt : Value e -> <Stdin | e> Value e
pReadLineOpt _ = vOptionString (readLineOpt ())

pReadAll : Value e -> <Stdin | e> Value e
pReadAll _ = VString (readAll ())

pReadExactly : Value e -> <Stdin | e> Value e
pReadExactly (VInt n) = vOptionString (readExactly n)
pReadExactly _ = panic "readExactly: expected Int"

export ioExternBindings : Unit -> List (String, Value e)
ioExternBindings _ = [
  -- Clock / GC / stderr — these OVERRIDE the frozen constants in externBindings
  ("wallTimeSec", prim1M pWallTimeSecIO),
  ("monotonicSec", prim1M pMonotonicSecIO),
  ("sleepMs", prim1M pSleepMsIO),
  ("allocBytes", prim1M pAllocBytesIO),
  ("ePutStr", prim1M pEPutStr),
  ("ePutStrLn", prim1M pEPutStrLn),
  -- File
  ("readFile", prim1 pReadFile),
  ("readFileBytes", prim1 pReadFileBytes),
  ("fileExists", prim1 pFileExists),
  ("canonicalizePath", prim1 pCanonicalizePath),
  ("listDir", prim1 pListDir),
  ("statFile", prim1 pStatFile),
  ("writeFile", prim2M pWriteFile),
  ("writeFileBytes", prim2M pWriteFileBytes),
  ("appendFile", prim2M pAppendFile),
  ("makeDir", prim1 pMakeDir),
  ("removeFile", prim1 pRemoveFile),
  ("removeDir", prim1 pRemoveDir),
  ("rename", prim2M pRename),
  -- Env
  ("args", prim1M pArgs),
  ("getEnv", prim1 pGetEnv),
  ("executablePath", prim1M pExecutablePath),
  ("buildFingerprint", prim1M pBuildFingerprint),
  -- Stdin
  ("readLine", prim1M pReadLine),
  ("readLineOpt", prim1M pReadLineOpt),
  ("readAll", prim1M pReadAll),
  ("readExactly", prim1 pReadExactly),
  -- Process
  ("exit", prim1 pExit),
]

-- Capability policy for `medaka test` (all three phases) and `medaka repl`: the
-- SAFE subset of ioExternBindings.  Real clock/GC reads (wallTimeSec /
-- monotonicSec / allocBytes) and stderr writes (ePutStr / ePutStrLn) so a
-- doctest / prop / repl session sees the SAME clock and stderr as `medaka run`
-- (issue #85: the frozen constants in externBindings made `medaka test` diverge
-- from `medaka run`).  DELIBERATELY EXCLUDES: sleepMs (blocks the shared batch
-- process), exit (a single doctest's `exit 0` would terminate the whole
-- long-lived test process and falsely report SUCCESS — THE hazard), and every
-- file / env / stdin / net extern (no sandbox / capability flag in test/repl).
export testCapableExterns : Unit -> List (String, Value e)
testCapableExterns _ = [
  ("wallTimeSec", prim1M pWallTimeSecIO),
  ("monotonicSec", prim1M pMonotonicSecIO),
  ("allocBytes", prim1M pAllocBytesIO),
  ("ePutStr", prim1M pEPutStr),
  ("ePutStrLn", prim1M pEPutStrLn),
]

-- `medaka run`'s output driver: evalModulesOutput plus the real-I/O externs.
-- The row is the coarse `IO` alias: ioExternBindings now spans FileRead/FileWrite/
-- Env/Stdin/Stderr/Clock, and `IO` in a BOUND expands to exactly that join
-- (typecheck.expandIoInBound), so writing them out one by one would buy nothing.
export evalModulesOutputRun : List Decl -> List (String, List Decl) -> <IO> String
evalModulesOutputRun preludeDecls modules =
  let _ = setRef outputRef ""
  -- Only the real `medaka run` CLI driver reaches this function (never the
  -- pure differential-oracle probes — see appendOutput/stashRunStdout above),
  -- so this is the one place it is safe to arm the abort-time flush.
  let _ = enableRunStdoutFlush ()
  let binds = evalModulesWith (ioExternBindings ()) preludeDecls modules
  let _ = runMainForEffect binds
  outputRef.value

-- ASYNC-DESIGN Stage 2 (D5): the `main : Async _` analog of evalModulesOutput.
-- A `main` whose inferred type heads in `Async` forces to an INERT Async value
-- (its row sits unperformed behind `Suspend` thunks), so forcing it alone prints
-- nothing.  Instead drive it through the program's own `runAsync` (looked up in
-- the root module's FULL env — locals ∪ imports ∪ globals — so an imported
-- `runAsync` is reachable), which trampolines the suspensions and performs the
-- stored row, appending to outputRef.  Mirrors bin/main.ml's Run-branch dispatch.
export evalModulesOutputAsync : List Decl -> List (String, List Decl) -> <e> String
evalModulesOutputAsync preludeDecls modules =
  let _ = setRef outputRef ""
  -- Same reasoning as evalModulesOutputRun above: only the real `medaka run`
  -- CLI driver (an Async main) reaches this function.
  let _ = enableRunStdoutFlush ()
  let binds = evalModulesRootEnv preludeDecls modules
  let _ = driveAsyncMain binds
  outputRef.value

driveAsyncMain : List (String, Value e) -> <e> Value e
driveAsyncMain binds = match lookupBinding "main" binds
  None => runtimePanic "E-NO-MAIN" noMainMsg
  Some mv => match lookupBinding "runAsync" binds
    Some rf => apply rf (force mv)
    None => runtimePanic "E-NO-RUNASYNC" "main : Async _ requires `runAsync` in scope. Add `import async`"

-- ── Phase 0 (DRIVER-COLLAPSE): 1-module eval wrappers over evalModules ──────
-- evalOne / evalOneOutput / evalOneRootEnv run a SINGLE program as the degenerate
-- 1-element module map [(rootId, prog)] through the multi-module eval path,
-- mirroring evalProgram / evalOutput / evalModulesRootEnv respectively.  The
-- multi-module driver installs the prelude GLOBALLY and the one module's funDefs as
-- LOCALS over a per-module frame; for a single module with zero imports the root
-- frame is locals ∪ globals, the same surface evalProgram exposes by-name.  The
-- key behavioural difference Phase 0 must characterize: evalProgram merges prelude
-- + user into ONE by-name frame and forces nullary thunks after every impl
-- installs, whereas evalModules uses separate prelude/module install order — the
-- binding/install/thunk-force hazard class (phases 96/103/121/125/134).
export evalOne : List Decl -> (String, List Decl) -> <e> List (String, Value e)
evalOne preludeDecls (rootId, prog) = evalModules preludeDecls [(rootId, prog)]

-- 1-module wrapper over evalModulesWith: the doctest single-file path passes a
-- capability list (testCapableExterns) so a prelude-only doctest sees the same
-- real clock/stderr as `medaka run`.
export evalOneWith : List (String, Value e) -> List Decl -> (String, List Decl) -> <e> List (String, Value e)
evalOneWith extraExterns preludeDecls (rootId, prog) =
  evalModulesWith extraExterns preludeDecls [(rootId, prog)]

-- run a single program for OUTPUT (mirror evalOutput): the 1-module evalModules
-- already forces the root module's `main` for effects and returns captured stdout.
export evalOneOutput : List Decl -> (String, List Decl) -> String
evalOneOutput preludeDecls (rootId, prog) =
  evalModulesOutput preludeDecls [(rootId, prog)]

-- the root module's FULL frame (locals ∪ imports ∪ globals), mirror
-- evalModulesRootEnv — the prop runner needs prelude methods (eq/compare) visible.
export evalOneRootEnv : List Decl -> (String, List Decl) -> <e> List (String, Value e)
evalOneRootEnv preludeDecls (rootId, prog) =
  evalModulesRootEnv preludeDecls [(rootId, prog)]

-- 1-module wrapper over evalModulesRootEnvWith: repl installs a capability list
-- (testCapableExterns) so an interactive session sees the real clock/stderr.
export evalOneRootEnvWith : List (String, Value e) -> List Decl -> (String, List Decl) -> <e> List (String, Value e)
evalOneRootEnvWith extraExterns preludeDecls (rootId, prog) =
  evalModulesRootEnvWith extraExterns preludeDecls [(rootId, prog)]
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "Ty" true) (mem "Addr" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "Route" true) (mem "ConPayload" true) (mem "Field" true) (mem "Variant" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "ImplMethod" true) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberOrigin" false) (mem "useMemberLocal" false) (mem "qualifiedLocal" false) (mem "Decl" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "reverseL" false) (mem "anyList" false) (mem "lookupAssoc" false) (mem "joinWith" false) (mem "fallthroughName" false) (mem "noneHeadTag" false) (mem "isEmptyL" false) (mem "filterList" false) (mem "initList" false) (mem "mapOption" false) (mem "joinDot" false) (mem "dedup" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" true) (mem "Severity" true) (mem "cjAllToJson" false))))
(DUse false (UseGroup ("bits64") ((mem "add64" false) (mem "sub64" false) (mem "mulLow64" false) (mem "xor64" false) (mem "shr64" false) (mem "mod64" false) (mem "ofInt" false) (mem "isZero" false) (mem "limbAt" false))))
(DData Public "Value" ("e") ((variant "VInt" (ConPos (TyCon "Int"))) (variant "VFloat" (ConPos (TyCon "Float"))) (variant "VString" (ConPos (TyCon "String"))) (variant "VChar" (ConPos (TyCon "String"))) (variant "VBool" (ConPos (TyCon "Bool"))) (variant "VUnit" (ConPos)) (variant "VTuple" (ConPos (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))) (variant "VList" (ConPos (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))) (variant "VArray" (ConPos (TyApp (TyCon "Array") (TyApp (TyCon "Value") (TyVar "e"))))) (variant "VCon" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))) (variant "VRecord" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))) (variant "VRef" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (variant "VClosure" (ConPos (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (variant "VClosureF" (ConPos (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))) (variant "VPrim" (ConPos (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))) (variant "VMulti" (ConPos (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))) (variant "VThunk" (ConPos (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))) (variant "VFallthrough" (ConPos)) (variant "VTypedImpl" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))) (variant "VDict" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))) ())
(DData Public "EvalEnv" ("v") ((variant "EvalEnv" (ConPos (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyVar "v")))))))) ())
(DTypeSig true "ppValue" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "String")))
(DFunDef false "ppValue" ((PCon "VInt" (PVar "n"))) (EApp (EVar "intToString") (EVar "n")))
(DFunDef false "ppValue" ((PCon "VFloat" (PVar "f"))) (EApp (EVar "floatToString") (EVar "f")))
(DFunDef false "ppValue" ((PCon "VString" (PVar "s"))) (EVar "s"))
(DFunDef false "ppValue" ((PCon "VChar" (PVar "c"))) (EVar "c"))
(DFunDef false "ppValue" ((PCon "VBool" (PCon "True"))) (ELit (LString "true")))
(DFunDef false "ppValue" ((PCon "VBool" (PCon "False"))) (ELit (LString "false")))
(DFunDef false "ppValue" ((PCon "VUnit")) (ELit (LString "()")))
(DFunDef false "ppValue" ((PCon "VTuple" (PVar "vs"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "joinComma") (EApp (EApp (EVar "map") (EVar "ppValue")) (EVar "vs")))) (ELit (LString ")"))))
(DFunDef false "ppValue" ((PCon "VList" (PVar "vs"))) (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EVar "joinComma") (EApp (EApp (EVar "map") (EVar "ppValue")) (EVar "vs")))) (ELit (LString "]"))))
(DFunDef false "ppValue" ((PCon "VArray" (PVar "vs"))) (EBinOp "++" (EBinOp "++" (ELit (LString "[|")) (EApp (EVar "joinComma") (EApp (EApp (EVar "map") (EVar "ppValue")) (EApp (EVar "arrayToListG") (EVar "vs"))))) (ELit (LString "|]"))))
(DFunDef false "ppValue" ((PCon "VCon" (PVar "name") (PList))) (EVar "name"))
(DFunDef false "ppValue" ((PCon "VCon" (PVar "name") (PVar "vs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "joinSp") (EApp (EApp (EVar "map") (EVar "ppValueAtom")) (EVar "vs"))))) (ELit (LString ""))))
(DFunDef false "ppValue" ((PCon "VRecord" (PVar "name") (PVar "fields"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " { "))) (EApp (EVar "display") (EApp (EVar "joinComma") (EApp (EApp (EVar "map") (EVar "ppField")) (EVar "fields"))))) (ELit (LString " }"))))
(DFunDef false "ppValue" ((PCon "VRef" (PVar "cell"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Ref(")) (EApp (EVar "ppValue") (EFieldAccess (EVar "cell") "value"))) (ELit (LString ")"))))
(DFunDef false "ppValue" ((PCon "VClosure" PWild PWild PWild)) (ELit (LString "<closure>")))
(DFunDef false "ppValue" ((PCon "VClosureF" PWild PWild PWild)) (ELit (LString "<closure>")))
(DFunDef false "ppValue" ((PCon "VPrim" PWild)) (ELit (LString "<prim>")))
(DFunDef false "ppValue" ((PCon "VMulti" (PVar "vs"))) (EBinOp "++" (EBinOp "++" (ELit (LString "<dispatch/")) (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "vs")))) (ELit (LString ">"))))
(DFunDef false "ppValue" ((PCon "VTypedImpl" (PVar "t") PWild PWild PWild (PVar "inner"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<impl@")) (EApp (EVar "display") (EVar "t"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "ppValue") (EVar "inner")))) (ELit (LString ">"))))
(DFunDef false "ppValue" ((PCon "VThunk" PWild)) (ELit (LString "<thunk>")))
(DFunDef false "ppValue" ((PCon "VDict" (PVar "key") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<dict:")) (EVar "key")) (ELit (LString ">"))))
(DFunDef false "ppValue" ((PCon "VFallthrough")) (ELit (LString "<fallthrough>")))
(DTypeSig false "ppField" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "String")))
(DFunDef false "ppField" ((PTuple (PVar "k") (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "k"))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "ppValue") (EVar "v")))) (ELit (LString ""))))
(DTypeSig false "ppValueAtom" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "String")))
(DFunDef false "ppValueAtom" ((PCon "VCon" (PVar "name") (PCons (PVar "x") (PVar "xs")))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppValue") (EApp (EApp (EVar "VCon") (EVar "name")) (EBinOp "::" (EVar "x") (EVar "xs"))))) (ELit (LString ")"))))
(DFunDef false "ppValueAtom" ((PCon "VTuple" (PVar "vs"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppValue") (EApp (EVar "VTuple") (EVar "vs")))) (ELit (LString ")"))))
(DFunDef false "ppValueAtom" ((PVar "v")) (EApp (EVar "ppValue") (EVar "v")))
(DTypeSig false "joinComma" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinComma" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "xs")))
(DTypeSig false "joinSp" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSp" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "xs")))
(DTypeSig false "arrayToListG" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "arrayToListG" ((PVar "arr")) (EApp (EApp (EApp (EVar "arrayToListGo") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "arrayToListGo" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "arrayToListGo" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EApp (EApp (EApp (EVar "arrayToListGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "intSeq" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "intSeq" ((PVar "lo") (PVar "end")) (EIf (EBinOp ">=" (EVar "lo") (EVar "end")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EVar "lo") (EApp (EApp (EVar "intSeq") (EBinOp "+" (EVar "lo") (ELit (LInt 1)))) (EVar "end"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "listNthAt" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "listNthAt" ((PList) (PVar "orig") PWild) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-INDEX-OOB"))) (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EVar "intToString") (EVar "orig"))) (ELit (LString " out of bounds")))))
(DFunDef false "listNthAt" ((PCons (PVar "x") (PVar "xs")) (PVar "orig") (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "x") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "listNthAt") (EVar "xs")) (EVar "orig")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "listSliceV" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "listSliceV" ((PVar "xs") (PVar "lo") (PVar "hi")) (EApp (EApp (EApp (EApp (EVar "listSliceGo") (EVar "xs")) (ELit (LInt 0))) (EVar "lo")) (EVar "hi")))
(DTypeSig false "listSliceGo" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "listSliceGo" ((PList) PWild PWild PWild) (EListLit))
(DFunDef false "listSliceGo" ((PCons (PVar "x") (PVar "xs")) (PVar "i") (PVar "lo") (PVar "hi")) (EIf (EBinOp ">=" (EVar "i") (EVar "hi")) (EListLit) (EIf (EBinOp ">=" (EVar "i") (EVar "lo")) (EBinOp "::" (EVar "x") (EApp (EApp (EApp (EApp (EVar "listSliceGo") (EVar "xs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "lo")) (EVar "hi"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "listSliceGo") (EVar "xs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "lo")) (EVar "hi")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "startsWithAt" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "startsWithAt" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")) (ELit (LChar "@")))))))
(DTypeSig false "containsInt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "containsInt" (PWild (PList)) (EVar "False"))
(DFunDef false "containsInt" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "containsInt") (EVar "x")) (EVar "ys"))))
(DTypeSig true "ctorToTypeRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "ctorToTypeRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "buildCtorToType" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "buildCtorToType" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ctorTypeEntries")) (EVar "prog")))
(DTypeSig false "ctorTypeEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "ctorTypeEntries" ((PCon "DData" PWild (PVar "tyname") PWild (PVar "variants") PWild)) (EApp (EApp (EVar "map") (ELam ((PVar "v")) (ETuple (EApp (EVar "variantName") (EVar "v")) (EVar "tyname")))) (EVar "variants")))
(DFunDef false "ctorTypeEntries" ((PCon "DNewtype" PWild (PVar "tyname") PWild (PVar "con") PWild PWild)) (EListLit (ETuple (EVar "con") (EVar "tyname"))))
(DFunDef false "ctorTypeEntries" (PWild) (EListLit))
(DTypeSig false "variantName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig true "ctorFieldOrdersRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorFieldOrdersRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "methodReqCountRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "methodReqCountRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "buildMethodReqCounts" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "buildMethodReqCounts" ((PVar "prog")) (EBlock (DoLet false false (PVar "arities") (EApp (EApp (EVar "flatMap") (EVar "methodDeclArities")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EVar "implMethodReqCounts") (EVar "arities"))) (EVar "prog")))))
(DTypeSig false "methodDeclArities" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "methodDeclArities" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "methodDeclArities") (EVar "d")))
(DFunDef false "methodDeclArities" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EVar "map") (EVar "ifaceMethodArity")) (EVar "methods")))
(DFunDef false "methodDeclArities" (PWild) (EListLit))
(DTypeSig false "ifaceMethodArity" (TyFun (TyCon "IfaceMethod") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "ifaceMethodArity" ((PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild)) (ETuple (EVar "mname") (EApp (EVar "listLen") (EApp (EVar "argsOfTy") (EVar "mty")))))
(DTypeSig false "implMethodReqCounts" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "implMethodReqCounts" ((PVar "arities") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "implMethodReqCounts") (EVar "arities")) (EVar "d")))
(DFunDef false "implMethodReqCounts" ((PVar "arities") (PRec "DImpl" ((rf "tys" (PVar "typeArgs")) (rf "methods" None)) true)) (EMatch (EApp (EVar "headTyconHead") (EVar "typeArgs")) (arm (PCon "Some" (PVar "tag")) () (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "implMethodReqCountEntry") (EVar "arities")) (EVar "tag"))) (EVar "methods"))) (arm (PCon "None") () (EListLit))))
(DFunDef false "implMethodReqCounts" (PWild PWild) (EListLit))
(DTypeSig false "implMethodReqCountEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "implMethodReqCountEntry" ((PVar "arities") (PVar "tag") (PCon "ImplMethod" (PVar "mname") (PVar "pats") PWild)) (EBlock (DoLet false false (PVar "declArity") (EApp (EApp (EVar "fromOption") (EApp (EVar "listLen") (EVar "pats"))) (EApp (EApp (EVar "lookupAssoc") (EVar "mname")) (EVar "arities")))) (DoLet false false (PVar "reqCount") (EApp (EApp (EVar "subClampZero") (EApp (EVar "listLen") (EVar "pats"))) (EVar "declArity"))) (DoExpr (EListLit (ETuple (ETuple (EVar "mname") (EVar "tag")) (EVar "reqCount"))))))
(DTypeSig false "subClampZero" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "subClampZero" ((PVar "a") (PVar "b")) (EIf (EBinOp "<" (EBinOp "-" (EVar "a") (EVar "b")) (ELit (LInt 0))) (ELit (LInt 0)) (EBinOp "-" (EVar "a") (EVar "b"))))
(DTypeSig false "takeN" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "takeN" ((PVar "n") PWild) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "takeN" (PWild (PList)) (EListLit))
(DFunDef false "takeN" ((PVar "n") (PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeN") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "lookupMethodReqCount" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "lookupMethodReqCount" ((PVar "mname") (PVar "tag")) (EApp (EApp (EApp (EVar "lookupReqCount") (EVar "mname")) (EVar "tag")) (EFieldAccess (EVar "methodReqCountRef") "value")))
(DTypeSig false "lookupReqCount" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Int"))) (TyCon "Int")))))
(DFunDef false "lookupReqCount" (PWild PWild (PList)) (ELit (LInt 0)))
(DFunDef false "lookupReqCount" ((PVar "mname") (PVar "tag") (PCons (PTuple (PTuple (PVar "m") (PVar "t")) (PVar "c")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "m") (EVar "mname")) (EBinOp "==" (EVar "t") (EVar "tag"))) (EVar "c") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lookupReqCount") (EVar "mname")) (EVar "tag")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "buildCtorFieldOrders" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "buildCtorFieldOrders" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ctorFieldOrderEntries")) (EVar "prog")))
(DTypeSig false "ctorFieldOrderEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorFieldOrderEntries" ((PCon "DData" PWild PWild PWild (PVar "variants") PWild)) (EApp (EApp (EVar "flatMap") (EVar "variantFieldOrder")) (EVar "variants")))
(DFunDef false "ctorFieldOrderEntries" (PWild) (EListLit))
(DTypeSig false "variantFieldOrder" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "variantFieldOrder" ((PCon "Variant" (PVar "n") (PCon "ConNamed" (PVar "fs") PWild))) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "fieldName")) (EVar "fs")))))
(DFunDef false "variantFieldOrder" (PWild) (EListLit))
(DTypeSig false "fieldName" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldName" ((PCon "Field" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "runtimeTypeTag" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "runtimeTypeTag" ((PCon "VInt" PWild)) (EApp (EVar "Some") (ELit (LString "Int"))))
(DFunDef false "runtimeTypeTag" ((PCon "VFloat" PWild)) (EApp (EVar "Some") (ELit (LString "Float"))))
(DFunDef false "runtimeTypeTag" ((PCon "VString" PWild)) (EApp (EVar "Some") (ELit (LString "String"))))
(DFunDef false "runtimeTypeTag" ((PCon "VChar" PWild)) (EApp (EVar "Some") (ELit (LString "Char"))))
(DFunDef false "runtimeTypeTag" ((PCon "VBool" PWild)) (EApp (EVar "Some") (ELit (LString "Bool"))))
(DFunDef false "runtimeTypeTag" ((PCon "VUnit")) (EApp (EVar "Some") (ELit (LString "Unit"))))
(DFunDef false "runtimeTypeTag" ((PCon "VList" PWild)) (EApp (EVar "Some") (ELit (LString "List"))))
(DFunDef false "runtimeTypeTag" ((PCon "VArray" PWild)) (EApp (EVar "Some") (ELit (LString "Array"))))
(DFunDef false "runtimeTypeTag" ((PCon "VTuple" (PVar "vs"))) (EApp (EVar "Some") (EApp (EVar "tupleHeadTag") (EApp (EVar "listLen") (EVar "vs")))))
(DFunDef false "runtimeTypeTag" ((PCon "VCon" (PVar "cname") PWild)) (EApp (EApp (EVar "lookupAssoc") (EVar "cname")) (EFieldAccess (EVar "ctorToTypeRef") "value")))
(DFunDef false "runtimeTypeTag" ((PCon "VRecord" (PVar "name") PWild)) (EApp (EVar "Some") (EVar "name")))
(DFunDef false "runtimeTypeTag" ((PCon "VTypedImpl" (PVar "t") PWild PWild PWild PWild)) (EApp (EVar "Some") (EVar "t")))
(DFunDef false "runtimeTypeTag" (PWild) (EVar "None"))
(DTypeSig false "countTyvars" (TyFun (TyCon "Ty") (TyCon "Int")))
(DFunDef false "countTyvars" ((PCon "TyVar" PWild)) (ELit (LInt 1)))
(DFunDef false "countTyvars" ((PCon "TyCon" PWild PWild)) (ELit (LInt 0)))
(DFunDef false "countTyvars" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "+" (EApp (EVar "countTyvars") (EVar "a")) (EApp (EVar "countTyvars") (EVar "b"))))
(DFunDef false "countTyvars" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "+" (EApp (EVar "countTyvars") (EVar "a")) (EApp (EVar "countTyvars") (EVar "b"))))
(DFunDef false "countTyvars" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "sumInts") (EApp (EApp (EVar "map") (EVar "countTyvars")) (EVar "ts"))))
(DFunDef false "countTyvars" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "countTyvars") (EVar "t")))
(DFunDef false "countTyvars" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "countTyvars") (EVar "t")))
(DTypeSig false "sumInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "sumInts" ((PList)) (ELit (LInt 0)))
(DFunDef false "sumInts" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "+" (EVar "x") (EApp (EVar "sumInts") (EVar "xs"))))
(DTypeSig true "tyvarsInArgs" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Int")))
(DFunDef false "tyvarsInArgs" ((PVar "ts")) (EApp (EVar "sumInts") (EApp (EApp (EVar "map") (EVar "countTyvars")) (EVar "ts"))))
(DTypeSig true "implKeyOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))))
(DFunDef false "implKeyOf" ((PVar "iface") (PVar "typeArgs") (PVar "nm")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "|"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "ppTyAtomK")) (EVar "typeArgs"))))) (ELit (LString "|"))) (EApp (EVar "display") (EApp (EApp (EVar "fromOption") (ELit (LString ""))) (EVar "nm")))) (ELit (LString ""))))
(DTypeSig false "ppTyK" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyK" ((PCon "TyCon" (PVar "n") PWild)) (EVar "n"))
(DFunDef false "ppTyK" ((PCon "TyVar" (PVar "n"))) (EVar "n"))
(DFunDef false "ppTyK" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppTyK") (EVar "a")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "ppTyAtomK") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "ppTyK" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppTyFunArgK") (EVar "a")))) (ELit (LString " -> "))) (EApp (EVar "display") (EApp (EVar "ppTyK") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "ppTyK" ((PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "joinComma") (EApp (EApp (EVar "map") (EVar "ppTyK")) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "ppTyK" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "ppTyK") (EVar "t")))
(DFunDef false "ppTyK" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "ppTyK") (EVar "t")))
(DTypeSig false "ppTyFunArgK" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyFunArgK" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppTyK") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "ppTyFunArgK" ((PVar "t")) (EApp (EVar "ppTyK") (EVar "t")))
(DTypeSig false "ppTyAtomK" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyAtomK" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppTyK") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "ppTyAtomK" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppTyK") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "ppTyAtomK" ((PVar "t")) (EApp (EVar "ppTyK") (EVar "t")))
(DTypeSig true "tupleHeadTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "tupleHeadTag" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "__tuple")) (EApp (EVar "intToString") (EVar "n"))) (ELit (LString "__"))))
(DTypeSig false "headTycon" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headTycon" ((PCon "TyCon" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "headTycon" ((PCon "TyApp" (PVar "a") PWild)) (EApp (EVar "headTycon") (EVar "a")))
(DFunDef false "headTycon" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "headTycon") (EVar "t")))
(DFunDef false "headTycon" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "headTycon") (EVar "t")))
(DFunDef false "headTycon" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "Some") (EApp (EVar "tupleHeadTag") (EApp (EVar "listLen") (EVar "ts")))))
(DFunDef false "headTycon" (PWild) (EVar "None"))
(DTypeSig false "dispatchPositionsOf" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "dispatchPositionsOf" ((PVar "mty") (PVar "params")) (EApp (EApp (EApp (EVar "filterMentions") (ELit (LInt 0))) (EApp (EVar "argsOfTy") (EVar "mty"))) (EVar "params")))
(DTypeSig false "argsOfTy" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "argsOfTy" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "argsOfTy") (EVar "t")))
(DFunDef false "argsOfTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "argsOfTy") (EVar "t")))
(DFunDef false "argsOfTy" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "a") (EApp (EVar "argsOfTy") (EVar "b"))))
(DFunDef false "argsOfTy" (PWild) (EListLit))
(DTypeSig false "filterMentions" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "filterMentions" (PWild (PList) PWild) (EListLit))
(DFunDef false "filterMentions" ((PVar "i") (PCons (PVar "t") (PVar "ts")) (PVar "params")) (EIf (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EVar "filterMentions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "filterMentions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tyMentions" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyMentions" ((PCon "TyVar" (PVar "n")) (PVar "params")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "params")))
(DFunDef false "tyMentions" ((PCon "TyCon" PWild PWild) PWild) (EVar "False"))
(DFunDef false "tyMentions" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentions") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentions" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentions") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentions" ((PCon "TyTuple" (PVar "ts")) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))) (EVar "ts")))
(DFunDef false "tyMentions" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentions" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))
(DTypeSig true "lookupEnv" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "lookupEnv" ((PCon "EvalEnv" (PVar "frames")) (PVar "name")) (EApp (EApp (EVar "lookupFrames") (EVar "frames")) (EVar "name")))
(DTypeSig false "lookupFrames" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))) (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "lookupFrames" ((PList) (PVar "name")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "unbound identifier: ")) (EVar "name"))))
(DFunDef false "lookupFrames" ((PCons (PVar "frame") (PVar "rest")) (PVar "name")) (EMatch (EApp (EApp (EVar "lookupFrameCell") (EVar "frame")) (EVar "name")) (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EVar "forceCell") (EVar "cell")) (EVar "name"))) (arm (PCon "None") () (EApp (EApp (EVar "lookupFrames") (EVar "rest")) (EVar "name")))))
(DTypeSig true "lookupMethod" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "lookupMethod" ((PCon "EvalEnv" (PVar "frames")) (PVar "name")) (EApp (EApp (EApp (EVar "lookupMethodFrames") (EVar "frames")) (EVar "frames")) (EVar "name")))
(DTypeSig false "lookupMethodFrames" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))) (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "lookupMethodFrames" ((PVar "all") (PList) (PVar "name")) (EApp (EApp (EVar "lookupFrames") (EVar "all")) (EVar "name")))
(DFunDef false "lookupMethodFrames" ((PVar "all") (PCons (PVar "frame") (PVar "rest")) (PVar "name")) (EMatch (EApp (EApp (EVar "lookupFrameCell") (EVar "frame")) (EVar "name")) (arm (PCon "Some" (PVar "cell")) () (EIf (EApp (EVar "isMethodBinding") (EApp (EApp (EVar "forceCell") (EVar "cell")) (EVar "name"))) (EApp (EApp (EVar "forceCell") (EVar "cell")) (EVar "name")) (EApp (EApp (EApp (EVar "lookupMethodFrames") (EVar "all")) (EVar "rest")) (EVar "name")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "lookupMethodFrames") (EVar "all")) (EVar "rest")) (EVar "name")))))
(DTypeSig false "isMethodBinding" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool")))
(DFunDef false "isMethodBinding" ((PCon "VTypedImpl" PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isMethodBinding" ((PCon "VMulti" (PVar "vs"))) (EApp (EVar "anyTypedImpl") (EVar "vs")))
(DFunDef false "isMethodBinding" (PWild) (EVar "False"))
(DTypeSig false "anyTypedImpl" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "Bool")))
(DFunDef false "anyTypedImpl" ((PList)) (EVar "False"))
(DFunDef false "anyTypedImpl" ((PCons (PCon "VTypedImpl" PWild PWild PWild PWild PWild) PWild)) (EVar "True"))
(DFunDef false "anyTypedImpl" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyTypedImpl") (EVar "rest")))
(DTypeSig false "forceCell" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "forceCell" ((PVar "cell") (PVar "name")) (EMatch (EFieldAccess (EVar "cell") "value") (arm (PCon "VThunk" (PVar "f")) () (EApp (EApp (EApp (EVar "forceMemo") (EVar "cell")) (EVar "name")) (EVar "f"))) (arm (PVar "v") () (EVar "v"))))
(DTypeSig false "forceMemo" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "forceMemo" ((PVar "cell") (PVar "name") (PVar "f")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "VThunk") (EApp (EVar "blackholeCell") (EVar "name"))))) (DoLet false false (PVar "v") (EApp (EVar "f") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cell")) (EVar "v"))) (DoExpr (EVar "v"))))
(DTypeSig false "blackholeCell" (TyFun (TyCon "String") (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "blackholeCell" ((PVar "name") PWild) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-CYCLIC-VALUE"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " refers to itself during initialization (non-productive cyclic value)")))))
(DTypeSig true "force" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "force" ((PCon "VThunk" (PVar "f"))) (EApp (EVar "f") (ELit LUnit)))
(DFunDef false "force" ((PVar "v")) (EVar "v"))
(DTypeSig false "lookupFrameCell" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "lookupFrameCell" ((PList) PWild) (EVar "None"))
(DFunDef false "lookupFrameCell" ((PCons (PTuple (PVar "n") (PVar "cell")) (PVar "rest")) (PVar "name")) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "Some") (EVar "cell")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupFrameCell") (EVar "rest")) (EVar "name")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lookupAtAddr" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyCon "Addr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "lookupAtAddr" ((PVar "env") (PVar "name") (PCon "AGlobal")) (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "name")))
(DFunDef false "lookupAtAddr" ((PCon "EvalEnv" (PVar "frames")) (PVar "name") (PCon "ALocal" (PVar "depth") (PVar "slot"))) (EApp (EApp (EVar "forceCell") (EApp (EApp (EApp (EVar "addrCell") (EApp (EApp (EApp (EVar "frameAtDepth") (EVar "frames")) (EVar "depth")) (EVar "name"))) (EVar "slot")) (EVar "name"))) (EVar "name")))
(DTypeSig false "frameAtDepth" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "frameAtDepth" ((PList) PWild (PVar "name")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "EVarAt: frame depth out of range for ")) (EVar "name"))))
(DFunDef false "frameAtDepth" ((PCons (PVar "frame") (PVar "rest")) (PVar "depth") (PVar "name")) (EIf (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EVar "frame") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "frameAtDepth") (EVar "rest")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "name")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "addrCell" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "addrCell" ((PList) PWild (PVar "name")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "EVarAt: slot out of range for ")) (EVar "name"))))
(DFunDef false "addrCell" ((PCons (PTuple (PVar "n") (PVar "cell")) (PVar "rest")) (PVar "slot") (PVar "name")) (EIf (EBinOp ">" (EVar "slot") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "addrCell") (EVar "rest")) (EBinOp "-" (EVar "slot") (ELit (LInt 1)))) (EVar "name")) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EVar "cell") (EIf (EVar "otherwise") (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "EVarAt: slot/name mismatch; want ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ", found "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "extendEnv" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "extendEnv" ((PCon "EvalEnv" (PVar "frames")) (PVar "binds")) (EApp (EVar "EvalEnv") (EBinOp "::" (EApp (EApp (EVar "map") (EVar "cellOf")) (EVar "binds")) (EVar "frames"))))
(DTypeSig false "cellOf" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))) (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "cellOf" ((PTuple (PVar "n") (PVar "v"))) (ETuple (EVar "n") (EApp (EVar "Ref") (EVar "v"))))
(DTypeSig true "pushFrame" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pushFrame" ((PCon "EvalEnv" (PVar "frames")) (PVar "frame")) (EApp (EVar "EvalEnv") (EBinOp "::" (EVar "frame") (EVar "frames"))))
(DTypeSig true "findCell" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "findCell" ((PList) (PVar "name")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "findCell: missing ")) (EVar "name"))))
(DFunDef false "findCell" ((PCons (PTuple (PVar "n") (PVar "cell")) (PVar "rest")) (PVar "name")) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EVar "cell") (EIf (EVar "otherwise") (EApp (EApp (EVar "findCell") (EVar "rest")) (EVar "name")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "valueEq" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "valueEq" ((PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "valueEq" ((PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "valueEq" ((PCon "VString" (PVar "a")) (PCon "VString" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "valueEq" ((PCon "VChar" (PVar "a")) (PCon "VChar" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "valueEq" ((PCon "VBool" (PVar "a")) (PCon "VBool" (PVar "b"))) (EApp (EApp (EVar "boolEq") (EVar "a")) (EVar "b")))
(DFunDef false "valueEq" ((PCon "VUnit") (PCon "VUnit")) (EVar "True"))
(DFunDef false "valueEq" ((PCon "VTuple" (PVar "a")) (PCon "VTuple" (PVar "b"))) (EApp (EApp (EVar "valueListEq") (EVar "a")) (EVar "b")))
(DFunDef false "valueEq" ((PCon "VList" (PVar "a")) (PCon "VList" (PVar "b"))) (EApp (EApp (EVar "valueListEq") (EVar "a")) (EVar "b")))
(DFunDef false "valueEq" ((PCon "VArray" (PVar "a")) (PCon "VArray" (PVar "b"))) (EApp (EApp (EVar "valueListEq") (EApp (EVar "arrayToListG") (EVar "a"))) (EApp (EVar "arrayToListG") (EVar "b"))))
(DFunDef false "valueEq" ((PCon "VCon" (PVar "n1") (PVar "a1")) (PCon "VCon" (PVar "n2") (PVar "a2"))) (EBinOp "&&" (EBinOp "==" (EVar "n1") (EVar "n2")) (EApp (EApp (EVar "valueListEq") (EVar "a1")) (EVar "a2"))))
(DFunDef false "valueEq" ((PCon "VRecord" (PVar "n1") (PVar "f1")) (PCon "VRecord" (PVar "n2") (PVar "f2"))) (EBinOp "&&" (EBinOp "==" (EVar "n1") (EVar "n2")) (EApp (EApp (EVar "fieldListEq") (EVar "f1")) (EVar "f2"))))
(DFunDef false "valueEq" ((PCon "VRef" (PVar "a")) (PCon "VRef" (PVar "b"))) (EApp (EApp (EVar "valueEq") (EFieldAccess (EVar "a") "value")) (EFieldAccess (EVar "b") "value")))
(DFunDef false "valueEq" (PWild PWild) (EVar "False"))
(DTypeSig false "valueListEq" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "Bool"))))
(DFunDef false "valueListEq" ((PList) (PList)) (EVar "True"))
(DFunDef false "valueListEq" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "&&" (EApp (EApp (EVar "valueEq") (EVar "x")) (EVar "y")) (EApp (EApp (EVar "valueListEq") (EVar "xs")) (EVar "ys"))))
(DFunDef false "valueListEq" (PWild PWild) (EVar "False"))
(DTypeSig false "fieldListEq" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "Bool"))))
(DFunDef false "fieldListEq" ((PList) (PList)) (EVar "True"))
(DFunDef false "fieldListEq" ((PCons (PTuple (PVar "k1") (PVar "v1")) (PVar "r1")) (PCons (PTuple (PVar "k2") (PVar "v2")) (PVar "r2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "k1") (EVar "k2")) (EApp (EApp (EVar "valueEq") (EVar "v1")) (EVar "v2"))) (EApp (EApp (EVar "fieldListEq") (EVar "r1")) (EVar "r2"))))
(DFunDef false "fieldListEq" (PWild PWild) (EVar "False"))
(DTypeSig false "boolEq" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "boolEq" ((PCon "True") (PCon "True")) (EVar "True"))
(DFunDef false "boolEq" ((PCon "False") (PCon "False")) (EVar "True"))
(DFunDef false "boolEq" (PWild PWild) (EVar "False"))
(DTypeSig false "boolToInt" (TyFun (TyCon "Bool") (TyCon "Int")))
(DFunDef false "boolToInt" ((PCon "False")) (ELit (LInt 0)))
(DFunDef false "boolToInt" ((PCon "True")) (ELit (LInt 1)))
(DTypeSig false "valueTag" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Int")))
(DFunDef false "valueTag" ((PCon "VInt" PWild)) (ELit (LInt 0)))
(DFunDef false "valueTag" ((PCon "VFloat" PWild)) (ELit (LInt 1)))
(DFunDef false "valueTag" ((PCon "VString" PWild)) (ELit (LInt 2)))
(DFunDef false "valueTag" ((PCon "VChar" PWild)) (ELit (LInt 3)))
(DFunDef false "valueTag" ((PCon "VBool" PWild)) (ELit (LInt 4)))
(DFunDef false "valueTag" ((PCon "VUnit")) (ELit (LInt 5)))
(DFunDef false "valueTag" ((PCon "VTuple" PWild)) (ELit (LInt 6)))
(DFunDef false "valueTag" ((PCon "VList" PWild)) (ELit (LInt 7)))
(DFunDef false "valueTag" ((PCon "VArray" PWild)) (ELit (LInt 8)))
(DFunDef false "valueTag" ((PCon "VCon" PWild PWild)) (ELit (LInt 9)))
(DFunDef false "valueTag" ((PCon "VRecord" PWild PWild)) (ELit (LInt 10)))
(DFunDef false "valueTag" ((PCon "VRef" PWild)) (ELit (LInt 11)))
(DFunDef false "valueTag" (PWild) (ELit (LInt 99)))
(DTypeSig false "valueCompare" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Ordering"))))
(DFunDef false "valueCompare" ((PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EApp (EVar "compare") (EVar "a")) (EVar "b")))
(DFunDef false "valueCompare" ((PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EApp (EVar "compare") (EVar "a")) (EVar "b")))
(DFunDef false "valueCompare" ((PCon "VString" (PVar "a")) (PCon "VString" (PVar "b"))) (EApp (EApp (EVar "compare") (EVar "a")) (EVar "b")))
(DFunDef false "valueCompare" ((PCon "VChar" (PVar "a")) (PCon "VChar" (PVar "b"))) (EApp (EApp (EVar "stringCompare") (EVar "a")) (EVar "b")))
(DFunDef false "valueCompare" ((PCon "VBool" (PVar "a")) (PCon "VBool" (PVar "b"))) (EApp (EApp (EVar "compare") (EApp (EVar "boolToInt") (EVar "a"))) (EApp (EVar "boolToInt") (EVar "b"))))
(DFunDef false "valueCompare" ((PCon "VUnit") (PCon "VUnit")) (EVar "Eq"))
(DFunDef false "valueCompare" ((PCon "VList" (PVar "a")) (PCon "VList" (PVar "b"))) (EApp (EApp (EVar "compareValueLists") (EVar "a")) (EVar "b")))
(DFunDef false "valueCompare" ((PCon "VArray" (PVar "a")) (PCon "VArray" (PVar "b"))) (EApp (EApp (EVar "compareValueLists") (EApp (EVar "arrayToListG") (EVar "a"))) (EApp (EVar "arrayToListG") (EVar "b"))))
(DFunDef false "valueCompare" ((PCon "VTuple" (PVar "a")) (PCon "VTuple" (PVar "b"))) (EApp (EApp (EVar "compareValueLists") (EVar "a")) (EVar "b")))
(DFunDef false "valueCompare" ((PCon "VCon" (PVar "n1") (PVar "a1")) (PCon "VCon" (PVar "n2") (PVar "a2"))) (EMatch (EApp (EApp (EVar "compare") (EVar "n1")) (EVar "n2")) (arm (PCon "Eq") () (EApp (EApp (EVar "compareValueLists") (EVar "a1")) (EVar "a2"))) (arm (PVar "o") () (EVar "o"))))
(DFunDef false "valueCompare" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "compare") (EApp (EVar "valueTag") (EVar "a"))) (EApp (EVar "valueTag") (EVar "b"))))
(DTypeSig false "compareValueLists" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "Ordering"))))
(DFunDef false "compareValueLists" ((PList) (PList)) (EVar "Eq"))
(DFunDef false "compareValueLists" ((PList) (PCons PWild PWild)) (EVar "Lt"))
(DFunDef false "compareValueLists" ((PCons PWild PWild) (PList)) (EVar "Gt"))
(DFunDef false "compareValueLists" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EMatch (EApp (EApp (EVar "valueCompare") (EVar "x")) (EVar "y")) (arm (PCon "Eq") () (EApp (EApp (EVar "compareValueLists") (EVar "xs")) (EVar "ys"))) (arm (PVar "o") () (EVar "o"))))
(DTypeSig false "ordLt" (TyFun (TyCon "Ordering") (TyCon "Bool")))
(DFunDef false "ordLt" ((PCon "Lt")) (EVar "True"))
(DFunDef false "ordLt" (PWild) (EVar "False"))
(DTypeSig false "ordGt" (TyFun (TyCon "Ordering") (TyCon "Bool")))
(DFunDef false "ordGt" ((PCon "Gt")) (EVar "True"))
(DFunDef false "ordGt" (PWild) (EVar "False"))
(DTypeSig true "matchPat" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "matchPat" ((PCon "PVar" (PVar "x")) (PVar "v")) (EApp (EVar "Some") (EListLit (ETuple (EVar "x") (EVar "v")))))
(DFunDef false "matchPat" ((PCon "PWild") PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "matchPat" ((PCon "PLit" (PCon "LInt" (PVar "n"))) (PCon "VInt" (PVar "m"))) (EIf (EBinOp "==" (EVar "n") (EVar "m")) (EApp (EVar "Some") (EListLit)) (EVar "None")))
(DFunDef false "matchPat" ((PCon "PLit" (PCon "LFloat" (PVar "f"))) (PCon "VFloat" (PVar "g"))) (EIf (EBinOp "==" (EVar "f") (EVar "g")) (EApp (EVar "Some") (EListLit)) (EVar "None")))
(DFunDef false "matchPat" ((PCon "PLit" (PCon "LString" (PVar "s"))) (PCon "VString" (PVar "t"))) (EIf (EBinOp "==" (EVar "s") (EVar "t")) (EApp (EVar "Some") (EListLit)) (EVar "None")))
(DFunDef false "matchPat" ((PCon "PLit" (PCon "LChar" (PVar "c"))) (PCon "VChar" (PVar "d"))) (EIf (EBinOp "==" (EVar "c") (EVar "d")) (EApp (EVar "Some") (EListLit)) (EVar "None")))
(DFunDef false "matchPat" ((PCon "PLit" (PCon "LBool" (PVar "b"))) (PCon "VBool" (PVar "c"))) (EIf (EApp (EApp (EVar "boolEq") (EVar "b")) (EVar "c")) (EApp (EVar "Some") (EListLit)) (EVar "None")))
(DFunDef false "matchPat" ((PCon "PLit" (PCon "LUnit")) (PCon "VUnit")) (EApp (EVar "Some") (EListLit)))
(DFunDef false "matchPat" ((PCon "PCon" (PLit (LString "True")) (PList)) (PCon "VBool" (PCon "True"))) (EApp (EVar "Some") (EListLit)))
(DFunDef false "matchPat" ((PCon "PCon" (PLit (LString "False")) (PList)) (PCon "VBool" (PCon "False"))) (EApp (EVar "Some") (EListLit)))
(DFunDef false "matchPat" ((PCon "PCon" (PVar "name") (PVar "pats")) (PCon "VCon" (PVar "name2") (PVar "vals"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "name") (EVar "name2")) (EBinOp "==" (EApp (EVar "listLen") (EVar "pats")) (EApp (EVar "listLen") (EVar "vals")))) (EApp (EApp (EVar "matchPats") (EVar "pats")) (EVar "vals")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "matchPat" ((PCon "PCons" (PVar "h") (PVar "t")) (PCon "VList" (PCons (PVar "x") (PVar "xs")))) (EApp (EApp (EApp (EApp (EVar "matchCons") (EVar "h")) (EVar "t")) (EVar "x")) (EVar "xs")))
(DFunDef false "matchPat" ((PCon "PCons" PWild PWild) (PCon "VList" (PList))) (EVar "None"))
(DFunDef false "matchPat" ((PCon "PTuple" (PVar "pats")) (PCon "VTuple" (PVar "vals"))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "pats")) (EApp (EVar "listLen") (EVar "vals"))) (EApp (EApp (EVar "matchPats") (EVar "pats")) (EVar "vals")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "matchPat" ((PCon "PList" (PVar "pats")) (PCon "VList" (PVar "vals"))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "pats")) (EApp (EVar "listLen") (EVar "vals"))) (EApp (EApp (EVar "matchPats") (EVar "pats")) (EVar "vals")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "matchPat" ((PCon "PAs" (PVar "x") (PVar "p")) (PVar "v")) (EApp (EApp (EApp (EVar "matchAs") (EVar "x")) (EVar "p")) (EVar "v")))
(DFunDef false "matchPat" ((PCon "PRec" PWild (PVar "fields") PWild) (PCon "VRecord" PWild (PVar "recFields"))) (EApp (EApp (EVar "matchRecFields") (EVar "fields")) (EVar "recFields")))
(DFunDef false "matchPat" ((PCon "PRec" (PVar "ctor") (PVar "fields") PWild) (PCon "VCon" (PVar "ctor2") (PVar "vals"))) (EIf (EBinOp "==" (EVar "ctor") (EVar "ctor2")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "ctor")) (EFieldAccess (EVar "ctorFieldOrdersRef") "value")) (arm (PCon "Some" (PVar "order")) () (EApp (EApp (EVar "matchRecFields") (EVar "fields")) (EApp (EApp (EVar "zipFieldOrder") (EVar "order")) (EVar "vals")))) (arm (PCon "None") () (EVar "None"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "matchPat" ((PCon "PRng" (PCon "LInt" (PVar "lo")) (PCon "LInt" (PVar "hi")) (PVar "incl")) (PCon "VInt" (PVar "v"))) (EIf (EApp (EApp (EApp (EApp (EVar "inIntRange") (EVar "v")) (EVar "lo")) (EVar "hi")) (EVar "incl")) (EApp (EVar "Some") (EListLit)) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "matchPat" ((PCon "PRng" (PCon "LChar" (PVar "lo")) (PCon "LChar" (PVar "hi")) (PVar "incl")) (PCon "VChar" (PVar "c"))) (EIf (EApp (EApp (EApp (EApp (EVar "inCharRange") (EVar "c")) (EVar "lo")) (EVar "hi")) (EVar "incl")) (EApp (EVar "Some") (EListLit)) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "matchPat" (PWild PWild) (EVar "None"))
(DTypeSig false "inIntRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool"))))))
(DFunDef false "inIntRange" ((PVar "v") (PVar "lo") (PVar "hi") (PVar "incl")) (EBinOp "&&" (EBinOp ">=" (EVar "v") (EVar "lo")) (EBinOp "<=" (EVar "v") (EIf (EVar "incl") (EVar "hi") (EBinOp "-" (EVar "hi") (ELit (LInt 1)))))))
(DTypeSig false "inCharRange" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "Bool"))))))
(DFunDef false "inCharRange" ((PVar "c") (PVar "lo") (PVar "hi") (PVar "incl")) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "ordLt") (EApp (EApp (EVar "stringCompare") (EVar "c")) (EVar "lo")))) (EApp (EApp (EApp (EVar "charUpper") (EVar "c")) (EVar "hi")) (EVar "incl"))))
(DTypeSig false "charUpper" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "Bool")))))
(DFunDef false "charUpper" ((PVar "c") (PVar "hi") (PCon "True")) (EApp (EVar "not") (EApp (EVar "ordGt") (EApp (EApp (EVar "stringCompare") (EVar "c")) (EVar "hi")))))
(DFunDef false "charUpper" ((PVar "c") (PVar "hi") (PCon "False")) (EApp (EVar "ordLt") (EApp (EApp (EVar "stringCompare") (EVar "c")) (EVar "hi"))))
(DTypeSig false "matchRecFields" (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "matchRecFields" ((PList) PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "matchRecFields" ((PCons (PCon "RecPatField" (PVar "fname") (PVar "mp")) (PVar "rest")) (PVar "recFields")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "fname")) (EVar "recFields")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EApp (EApp (EApp (EVar "matchRecField") (EVar "fname")) (EVar "mp")) (EVar "v")) (EVar "rest")) (EVar "recFields")))))
(DTypeSig false "zipFieldOrder" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "zipFieldOrder" ((PList) PWild) (EListLit))
(DFunDef false "zipFieldOrder" (PWild (PList)) (EListLit))
(DFunDef false "zipFieldOrder" ((PCons (PVar "f") (PVar "fs")) (PCons (PVar "v") (PVar "vs"))) (EBinOp "::" (ETuple (EVar "f") (EVar "v")) (EApp (EApp (EVar "zipFieldOrder") (EVar "fs")) (EVar "vs"))))
(DTypeSig false "matchRecField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Pat")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))))
(DFunDef false "matchRecField" ((PVar "fname") (PCon "None") (PVar "v") (PVar "rest") (PVar "recFields")) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "fname") (EVar "v")) (EVar "_s")))) (EApp (EApp (EVar "matchRecFields") (EVar "rest")) (EVar "recFields"))))
(DFunDef false "matchRecField" (PWild (PCon "Some" (PVar "q")) (PVar "v") (PVar "rest") (PVar "recFields")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "q")) (EVar "v")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "b") (EVar "_s")))) (EApp (EApp (EVar "matchRecFields") (EVar "rest")) (EVar "recFields"))))))
(DTypeSig false "matchCons" (TyFun (TyCon "Pat") (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "matchCons" ((PVar "h") (PVar "t") (PVar "x") (PVar "xs")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "h")) (EVar "x")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "b1")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "b1") (EVar "_s")))) (EApp (EApp (EVar "matchPat") (EVar "t")) (EApp (EVar "VList") (EVar "xs")))))))
(DTypeSig false "matchAs" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "matchAs" ((PVar "x") (PVar "p") (PVar "v")) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "x") (EVar "v")) (EVar "_s")))) (EApp (EApp (EVar "matchPat") (EVar "p")) (EVar "v"))))
(DTypeSig false "matchPats" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "matchPats" ((PList) (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "matchPats" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "v") (PVar "vs"))) (EMatch (EApp (EApp (EVar "matchPat") (EVar "p")) (EVar "v")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "b") (EVar "_s")))) (EApp (EApp (EVar "matchPats") (EVar "ps")) (EVar "vs"))))))
(DFunDef false "matchPats" (PWild PWild) (EVar "None"))
(DTypeSig true "makeCtor" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "makeCtor" ((PVar "name") (PVar "arity")) (EApp (EApp (EApp (EVar "makeCtorGo") (EVar "name")) (EVar "arity")) (EListLit)))
(DTypeSig false "makeCtorGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "makeCtorGo" ((PVar "name") (PVar "arity") (PVar "acc")) (EIf (EBinOp "<=" (EVar "arity") (ELit (LInt 0))) (EApp (EApp (EVar "VCon") (EVar "name")) (EApp (EVar "reverseL") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EVar "VPrim") (ELam ((PVar "v")) (EApp (EApp (EApp (EVar "makeCtorGo") (EVar "name")) (EBinOp "-" (EVar "arity") (ELit (LInt 1)))) (EBinOp "::" (EVar "v") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "applyValue" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "applyValue" ((PVar "f") (PVar "x")) (EApp (EApp (EVar "apply") (EVar "f")) (EVar "x")))
(DTypeSig true "apply" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "apply" ((PVar "f") (PVar "x")) (EBlock (DoLet false false (PVar "d") (EBinOp "+" (EFieldAccess (EVar "evalDepthRef") "value") (ELit (LInt 1)))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "evalDepthRef")) (EVar "d"))) (DoLet false false PWild (EIf (EBinOp ">" (EVar "d") (EVar "evalDepthLimit")) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-STACK-OVERFLOW"))) (EBinOp "++" (EBinOp "++" (ELit (LString "recursion too deep (evaluator call depth exceeded ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "evalDepthLimit")))) (ELit (LString "); the tree-walking interpreter has no tail-call optimisation")))) (ELit LUnit))) (DoLet false false (PVar "r") (EApp (EApp (EVar "applyDispatch") (EVar "f")) (EVar "x"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "evalDepthRef")) (EBinOp "-" (EVar "d") (ELit (LInt 1))))) (DoExpr (EVar "r"))))
(DTypeSig false "applyDispatch" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "applyDispatch" ((PVar "f") (PVar "x")) (EMatch (EApp (EApp (EVar "applyOpt") (EVar "f")) (EVar "x")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-NONEXHAUSTIVE-MATCH"))) (ELit (LString "non-exhaustive match"))))))
(DTypeSig false "applyOpt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "applyOpt" ((PCon "VClosure" (PVar "env") (PVar "pats") (PVar "body")) (PVar "arg")) (EApp (EApp (EApp (EApp (EVar "applyClosure") (EVar "env")) (EVar "pats")) (EVar "body")) (EVar "arg")))
(DFunDef false "applyOpt" ((PCon "VClosureF" (PVar "env") (PVar "pats") (PVar "f")) (PVar "arg")) (EApp (EApp (EApp (EApp (EVar "applyClosureF") (EVar "env")) (EVar "pats")) (EVar "f")) (EVar "arg")))
(DFunDef false "applyOpt" ((PCon "VPrim" (PVar "f")) (PVar "arg")) (EApp (EVar "Some") (EApp (EVar "f") (EVar "arg"))))
(DFunDef false "applyOpt" ((PCon "VTypedImpl" (PVar "t") (PVar "key") (PVar "pos") (PVar "seen") (PVar "inner")) (PVar "arg")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyTyped") (EVar "t")) (EVar "key")) (EVar "pos")) (EVar "seen")) (EVar "inner")) (EVar "arg")))
(DFunDef false "applyOpt" ((PCon "VMulti" (PVar "vs")) (PVar "arg")) (EApp (EApp (EApp (EVar "collectPartials") (EListLit)) (EApp (EApp (EVar "filterByTag") (EVar "vs")) (EVar "arg"))) (EVar "arg")))
(DFunDef false "applyOpt" ((PVar "other") PWild) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-NOT-A-FUNCTION"))) (EBinOp "++" (ELit (LString "applied non-function: ")) (EApp (EVar "ppValue") (EVar "other")))))
(DTypeSig false "applyTyped" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))))))))))
(DFunDef false "applyTyped" ((PVar "t") (PVar "key") (PVar "pos") (PVar "seen") (PVar "inner") (PVar "arg")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "reTag") (EVar "t")) (EVar "key")) (EVar "pos")) (EBinOp "+" (EVar "seen") (ELit (LInt 1))))) (EApp (EApp (EVar "applyOpt") (EVar "inner")) (EVar "arg"))))
(DTypeSig false "reTag" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "reTag" ((PVar "t") (PVar "key") (PVar "pos") (PVar "seen") (PVar "r")) (EIf (EApp (EVar "isPartial") (EVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "VTypedImpl") (EVar "t")) (EVar "key")) (EVar "pos")) (EVar "seen")) (EVar "r")) (EIf (EVar "otherwise") (EVar "r") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterByTag" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "filterByTag" ((PVar "vs") (PVar "arg")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EVar "isDispatching")) (EVar "vs"))) (EVar "vs") (EIf (EVar "otherwise") (EApp (EApp (EVar "filterByTagT") (EVar "vs")) (EApp (EVar "runtimeTypeTag") (EVar "arg"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterByTagT" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "filterByTagT" ((PVar "vs") (PCon "None")) (EVar "vs"))
(DFunDef false "filterByTagT" ((PVar "vs") (PCon "Some" (PVar "tag"))) (EApp (EApp (EVar "keepOrAll") (EVar "vs")) (EApp (EApp (EVar "filter") (EApp (EVar "keepCand") (EVar "tag"))) (EVar "vs"))))
(DTypeSig false "keepOrAll" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "keepOrAll" ((PVar "original") (PList)) (EVar "original"))
(DFunDef false "keepOrAll" (PWild (PVar "kept")) (EVar "kept"))
(DTypeSig false "keepCand" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "keepCand" ((PVar "tag") (PVar "v")) (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isDispatching") (EVar "v"))) (EApp (EApp (EVar "matchesTag") (EVar "tag")) (EVar "v"))))
(DTypeSig false "isDispatching" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool")))
(DFunDef false "isDispatching" ((PCon "VTypedImpl" PWild PWild (PVar "pos") (PVar "seen") PWild)) (EApp (EApp (EVar "containsInt") (EVar "seen")) (EVar "pos")))
(DFunDef false "isDispatching" (PWild) (EVar "False"))
(DTypeSig true "narrowMethod" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "narrowMethod" ((PCon "VMulti" (PVar "vs")) (PLit (LString ""))) (EApp (EVar "VMulti") (EVar "vs")))
(DFunDef false "narrowMethod" ((PCon "VMulti" (PVar "vs")) (PVar "tag")) (EApp (EVar "stripResolved") (EApp (EApp (EVar "pickByTag") (EVar "vs")) (EVar "tag"))))
(DFunDef false "narrowMethod" ((PCon "VTypedImpl" (PVar "t") (PVar "k") (PVar "p") (PVar "s") (PVar "inner")) (PLit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EVar "VTypedImpl") (EVar "t")) (EVar "k")) (EVar "p")) (EVar "s")) (EVar "inner")))
(DFunDef false "narrowMethod" ((PCon "VTypedImpl" (PVar "t") (PVar "k") (PVar "p") (PVar "s") (PVar "inner")) PWild) (EApp (EVar "stripResolved") (EApp (EApp (EApp (EApp (EApp (EVar "VTypedImpl") (EVar "t")) (EVar "k")) (EVar "p")) (EVar "s")) (EVar "inner"))))
(DFunDef false "narrowMethod" ((PVar "v") PWild) (EVar "v"))
(DTypeSig false "pickByTag" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pickByTag" ((PVar "vs") (PVar "tag")) (EMatch (EApp (EApp (EVar "filterList") (EApp (EVar "hasTag") (EVar "tag"))) (EVar "vs")) (arm (PList) () (EApp (EApp (EVar "oneOrMultiV") (EApp (EApp (EVar "filterList") (EVar "isDefaultCand")) (EVar "vs"))) (EVar "vs"))) (arm (PVar "matched") () (EApp (EApp (EVar "oneOrMultiV") (EVar "matched")) (EVar "vs")))))
(DTypeSig false "isDefaultCand" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool")))
(DFunDef false "isDefaultCand" ((PCon "VTypedImpl" PWild PWild PWild PWild PWild)) (EVar "False"))
(DFunDef false "isDefaultCand" (PWild) (EVar "True"))
(DTypeSig false "stripResolved" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "stripResolved" ((PCon "VTypedImpl" (PVar "t") (PVar "k") (PVar "p") (PVar "s") (PVar "inner"))) (EApp (EApp (EVar "stripBody") (EApp (EApp (EApp (EApp (EApp (EVar "VTypedImpl") (EVar "t")) (EVar "k")) (EVar "p")) (EVar "s")) (EVar "inner"))) (EVar "inner")))
(DFunDef false "stripResolved" ((PVar "v")) (EVar "v"))
(DTypeSig false "stripBody" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "stripBody" ((PVar "wrapper") (PCon "VThunk" (PVar "f"))) (EApp (EApp (EVar "stripBody") (EVar "wrapper")) (EApp (EVar "f") (ELit LUnit))))
(DFunDef false "stripBody" ((PVar "wrapper") (PCon "VTypedImpl" PWild PWild PWild PWild (PVar "inner"))) (EApp (EApp (EVar "stripBody") (EVar "wrapper")) (EVar "inner")))
(DFunDef false "stripBody" ((PVar "wrapper") (PVar "v")) (EIf (EApp (EVar "awaitsArgs") (EVar "v")) (EVar "wrapper") (EVar "v")))
(DTypeSig false "awaitsArgs" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool")))
(DFunDef false "awaitsArgs" ((PCon "VClosure" PWild PWild PWild)) (EVar "True"))
(DFunDef false "awaitsArgs" ((PCon "VClosureF" PWild PWild PWild)) (EVar "True"))
(DFunDef false "awaitsArgs" ((PCon "VPrim" PWild)) (EVar "True"))
(DFunDef false "awaitsArgs" ((PCon "VMulti" PWild)) (EVar "True"))
(DFunDef false "awaitsArgs" ((PCon "VTypedImpl" PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "awaitsArgs" (PWild) (EVar "False"))
(DTypeSig true "routeTag" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Route") (TyEffect () (Some "e") (TyCon "String")))))
(DFunDef false "routeTag" (PWild (PCon "RNone")) (ELit (LString "")))
(DFunDef false "routeTag" (PWild (PCon "RKey" (PVar "key") PWild)) (EVar "key"))
(DFunDef false "routeTag" ((PVar "env") (PCon "RDict" (PVar "d"))) (EMatch (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "d")) (arm (PCon "VDict" (PVar "key") PWild) () (EVar "key")) (arm PWild () (ELit (LString "")))))
(DFunDef false "routeTag" ((PVar "env") (PCon "RDictFwd" (PVar "d"))) (EMatch (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "d")) (arm (PCon "VDict" (PVar "key") PWild) () (EVar "key")) (arm PWild () (ELit (LString "")))))
(DFunDef false "routeTag" (PWild (PCon "RLocal" PWild PWild)) (ELit (LString "")))
(DFunDef false "routeTag" (PWild (PCon "RScalar" PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: RScalar is an arithmetic binop tag, not a dispatch route"))))
(DTypeSig true "applyDicts" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "applyDicts" (PWild (PVar "v") (PList)) (EVar "v"))
(DFunDef false "applyDicts" ((PVar "env") (PVar "v") (PCons (PVar "r") (PVar "rest"))) (EApp (EApp (EApp (EVar "applyDicts") (EVar "env")) (EApp (EApp (EVar "apply") (EVar "v")) (EApp (EApp (EVar "dictOfRoute") (EVar "env")) (EVar "r")))) (EVar "rest")))
(DTypeSig true "applyValues" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "applyValues" ((PVar "v") (PList)) (EVar "v"))
(DFunDef false "applyValues" ((PVar "v") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "applyValues") (EApp (EApp (EVar "apply") (EVar "v")) (EVar "x"))) (EVar "rest")))
(DTypeSig false "dictOfRoute" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Route") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "dictOfRoute" ((PVar "env") (PCon "RKey" (PVar "key") (PVar "reqs"))) (EApp (EApp (EVar "VDict") (EVar "key")) (EApp (EApp (EVar "map") (EApp (EVar "dictOfRoute") (EVar "env"))) (EVar "reqs"))))
(DFunDef false "dictOfRoute" ((PVar "env") (PCon "RDict" (PVar "d"))) (EMatch (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "d")) (arm (PCon "VDict" (PVar "key") (PVar "reqs")) () (EApp (EApp (EVar "VDict") (EVar "key")) (EVar "reqs"))) (arm PWild () (EApp (EApp (EVar "VDict") (ELit (LString ""))) (EListLit)))))
(DFunDef false "dictOfRoute" ((PVar "env") (PCon "RDictFwd" (PVar "d"))) (EMatch (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "d")) (arm (PCon "VDict" (PVar "key") (PVar "reqs")) () (EApp (EApp (EVar "VDict") (EVar "key")) (EVar "reqs"))) (arm PWild () (EApp (EApp (EVar "VDict") (ELit (LString ""))) (EListLit)))))
(DFunDef false "dictOfRoute" (PWild (PCon "RNone")) (EApp (EApp (EVar "VDict") (ELit (LString ""))) (EListLit)))
(DFunDef false "dictOfRoute" (PWild (PCon "RLocal" PWild PWild)) (EApp (EApp (EVar "VDict") (ELit (LString ""))) (EListLit)))
(DFunDef false "dictOfRoute" (PWild (PCon "RScalar" PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: RScalar is an arithmetic binop tag, not a dispatch route"))))
(DTypeSig true "methodAtNarrow" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Route") (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "methodAtNarrow" (PWild (PVar "v") (PCon "RNone")) (ETuple (EVar "v") (EListLit)))
(DFunDef false "methodAtNarrow" (PWild (PVar "v") (PCon "RKey" (PVar "key") PWild)) (ETuple (EApp (EApp (EVar "narrowMethod") (EVar "v")) (EVar "key")) (EListLit)))
(DFunDef false "methodAtNarrow" ((PVar "env") (PVar "v") (PCon "RDict" (PVar "d"))) (EMatch (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "d")) (arm (PCon "VDict" (PVar "key") (PVar "reqs")) () (ETuple (EApp (EApp (EVar "narrowMethod") (EVar "v")) (EVar "key")) (EVar "reqs"))) (arm PWild () (ETuple (EVar "v") (EListLit)))))
(DFunDef false "methodAtNarrow" ((PVar "env") (PVar "v") (PCon "RDictFwd" (PVar "d"))) (EMatch (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "d")) (arm (PCon "VDict" (PVar "key") (PVar "reqs")) () (ETuple (EApp (EApp (EVar "narrowMethod") (EVar "v")) (EVar "key")) (EVar "reqs"))) (arm PWild () (ETuple (EVar "v") (EListLit)))))
(DFunDef false "methodAtNarrow" (PWild (PVar "v") (PCon "RLocal" PWild PWild)) (ETuple (EVar "v") (EListLit)))
(DFunDef false "methodAtNarrow" (PWild PWild (PCon "RScalar" PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: RScalar is an arithmetic binop tag, not a dispatch route"))))
(DTypeSig false "oneOrMultiV" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "oneOrMultiV" ((PList (PVar "v")) PWild) (EVar "v"))
(DFunDef false "oneOrMultiV" ((PList) (PVar "original")) (EApp (EVar "VMulti") (EVar "original")))
(DFunDef false "oneOrMultiV" ((PVar "many") PWild) (EApp (EVar "VMulti") (EVar "many")))
(DTypeSig false "hasTag" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "hasTag" ((PVar "tag") (PCon "VTypedImpl" (PVar "t") (PVar "k") PWild PWild PWild)) (EBinOp "||" (EBinOp "==" (EVar "t") (EVar "tag")) (EBinOp "==" (EVar "k") (EVar "tag"))))
(DFunDef false "hasTag" (PWild PWild) (EVar "False"))
(DTypeSig false "matchesTag" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "matchesTag" ((PVar "tag") (PCon "VTypedImpl" (PVar "t") (PVar "k") PWild PWild PWild)) (EBinOp "||" (EBinOp "==" (EVar "t") (EVar "tag")) (EBinOp "==" (EVar "k") (EVar "tag"))))
(DFunDef false "matchesTag" (PWild PWild) (EVar "True"))
(DTypeSig false "applyClosure" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "applyClosure" (PWild (PList) PWild PWild) (EApp (EVar "panic") (ELit (LString "applied closure with no parameters"))))
(DFunDef false "applyClosure" ((PVar "env") (PList (PVar "p")) (PVar "body") (PVar "arg")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "p")) (EVar "arg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "binds")) () (EApp (EVar "fallthroughToNone") (EApp (EApp (EVar "eval") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "body"))))))
(DFunDef false "applyClosure" ((PVar "env") (PCons (PVar "p") (PVar "ps")) (PVar "body") (PVar "arg")) (EApp (EApp (EVar "map") (ELam ((PVar "binds")) (EApp (EApp (EApp (EVar "VClosure") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "ps")) (EVar "body")))) (EApp (EApp (EVar "matchPat") (EVar "p")) (EVar "arg"))))
(DTypeSig true "applyClosureF" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "applyClosureF" (PWild (PList) PWild PWild) (EApp (EVar "panic") (ELit (LString "applied closure with no parameters"))))
(DFunDef false "applyClosureF" ((PVar "env") (PList (PVar "p")) (PVar "f") (PVar "arg")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "p")) (EVar "arg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "binds")) () (EApp (EVar "fallthroughToNone") (EApp (EVar "f") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds")))))))
(DFunDef false "applyClosureF" ((PVar "env") (PCons (PVar "p") (PVar "ps")) (PVar "f") (PVar "arg")) (EApp (EApp (EVar "map") (ELam ((PVar "binds")) (EApp (EApp (EApp (EVar "VClosureF") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "ps")) (EVar "f")))) (EApp (EApp (EVar "matchPat") (EVar "p")) (EVar "arg"))))
(DTypeSig false "fallthroughToNone" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "fallthroughToNone" ((PCon "VFallthrough")) (EVar "None"))
(DFunDef false "fallthroughToNone" ((PVar "v")) (EApp (EVar "Some") (EVar "v")))
(DTypeSig false "collectPartials" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "collectPartials" ((PList) (PList) PWild) (EApp (EVar "panic") (ELit (LString "no matching impl for dispatch"))))
(DFunDef false "collectPartials" ((PList (PVar "v")) (PList) PWild) (EApp (EVar "Some") (EVar "v")))
(DFunDef false "collectPartials" ((PVar "many") (PList) PWild) (EApp (EVar "Some") (EApp (EVar "VMulti") (EApp (EVar "reverseL") (EVar "many")))))
(DFunDef false "collectPartials" ((PVar "acc") (PCons (PVar "v") (PVar "rest")) (PVar "arg")) (EMatch (EApp (EApp (EVar "applyOpt") (EVar "v")) (EVar "arg")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "collectPartials") (EVar "acc")) (EVar "rest")) (EVar "arg"))) (arm (PCon "Some" (PVar "r")) () (EIf (EApp (EVar "isPartial") (EVar "r")) (EApp (EApp (EApp (EVar "collectPartials") (EBinOp "::" (EVar "r") (EVar "acc"))) (EVar "rest")) (EVar "arg")) (EApp (EVar "Some") (EVar "r"))))))
(DTypeSig false "isPartial" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool")))
(DFunDef false "isPartial" ((PCon "VClosure" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isPartial" ((PCon "VClosureF" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isPartial" ((PCon "VPrim" PWild)) (EVar "True"))
(DFunDef false "isPartial" ((PCon "VMulti" PWild)) (EVar "True"))
(DFunDef false "isPartial" ((PCon "VTypedImpl" PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isPartial" (PWild) (EVar "False"))
(DTypeSig true "eval" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "eval" (PWild (PCon "ELit" (PCon "LInt" (PVar "n")))) (EApp (EVar "VInt") (EVar "n")))
(DFunDef false "eval" (PWild (PCon "ENumLit" (PVar "n") (PVar "r") PWild)) (EMatch (EFieldAccess (EVar "r") "value") (arm (PCon "Some" (PVar "f")) () (EApp (EVar "VFloat") (EVar "f"))) (arm (PCon "None") () (EApp (EVar "VInt") (EVar "n")))))
(DFunDef false "eval" (PWild (PCon "ELit" (PCon "LFloat" (PVar "f")))) (EApp (EVar "VFloat") (EVar "f")))
(DFunDef false "eval" (PWild (PCon "ELit" (PCon "LString" (PVar "s")))) (EApp (EVar "VString") (EVar "s")))
(DFunDef false "eval" (PWild (PCon "ELit" (PCon "LChar" (PVar "c")))) (EApp (EVar "VChar") (EVar "c")))
(DFunDef false "eval" (PWild (PCon "ELit" (PCon "LBool" (PVar "b")))) (EApp (EVar "VBool") (EVar "b")))
(DFunDef false "eval" (PWild (PCon "ELit" (PCon "LUnit"))) (EVar "VUnit"))
(DFunDef false "eval" ((PVar "env") (PCon "EVar" (PVar "x"))) (EIf (EApp (EVar "startsWithAt") (EVar "x")) (EVar "VUnit") (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "x"))))
(DFunDef false "eval" ((PVar "env") (PCon "EVarAt" (PVar "x") (PVar "addr"))) (EIf (EApp (EVar "startsWithAt") (EVar "x")) (EVar "VUnit") (EApp (EApp (EApp (EVar "lookupAtAddr") (EVar "env")) (EVar "x")) (EVar "addr"))))
(DFunDef false "eval" ((PVar "env") (PCon "EMethodAt" (PVar "name") (PVar "routeRef") (PVar "implRef") (PVar "methodRef"))) (EApp (EApp (EApp (EApp (EApp (EVar "evalMethodAt") (EVar "env")) (EVar "name")) (EFieldAccess (EVar "routeRef") "value")) (EFieldAccess (EVar "implRef") "value")) (EFieldAccess (EVar "methodRef") "value")))
(DFunDef false "eval" ((PVar "env") (PCon "EDictAt" (PVar "name") (PVar "routesRef"))) (EApp (EApp (EApp (EVar "applyDicts") (EVar "env")) (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "name"))) (EFieldAccess (EVar "routesRef") "value")))
(DFunDef false "eval" ((PVar "env") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "apply") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "f"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "x"))))
(DFunDef false "eval" ((PVar "env") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "VClosure") (EVar "env")) (EVar "pats")) (EVar "body")))
(DFunDef false "eval" ((PVar "env") (PCon "ELet" PWild (PCon "True") (PCon "PVar" (PVar "f")) (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "evalRecLet") (EVar "env")) (EVar "f")) (EVar "e1")) (EVar "e2")))
(DFunDef false "eval" ((PVar "env") (PCon "ELet" PWild PWild (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "evalLet") (EVar "env")) (EVar "pat")) (EVar "e1")) (EVar "e2")))
(DFunDef false "eval" ((PVar "env") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EVar "evalLetGroup") (EVar "env")) (EVar "binds")) (EVar "body")))
(DFunDef false "eval" ((PVar "env") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EVar "evalMatch") (EVar "env")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "eval" ((PVar "env") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "evalIf") (EVar "env")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "c"))) (EVar "t")) (EVar "e")))
(DFunDef false "eval" ((PVar "env") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") PWild)) (EApp (EApp (EApp (EApp (EVar "evalBinop") (EVar "env")) (EVar "op")) (EVar "l")) (EVar "r")))
(DFunDef false "eval" ((PVar "env") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EVar "apply") (EApp (EApp (EVar "apply") (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "op"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l")))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r"))))
(DFunDef false "eval" ((PVar "env") (PCon "EUnOp" (PVar "op") (PVar "e") PWild)) (EApp (EApp (EVar "evalUnop") (EVar "op")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))))
(DFunDef false "eval" ((PVar "env") (PCon "ETuple" (PVar "es"))) (EApp (EVar "VTuple") (EApp (EApp (EVar "map") (EApp (EVar "eval") (EVar "env"))) (EVar "es"))))
(DFunDef false "eval" ((PVar "env") (PCon "EListLit" (PVar "es"))) (EApp (EVar "VList") (EApp (EApp (EVar "map") (EApp (EVar "eval") (EVar "env"))) (EVar "es"))))
(DFunDef false "eval" ((PVar "env") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EApp (EVar "eval") (EVar "env"))) (EVar "es")))))
(DFunDef false "eval" ((PVar "env") (PCon "ERecordCreate" (PVar "name") (PVar "fields"))) (EBlock (DoLet false false (PVar "assigns") (EApp (EApp (EVar "map") (EApp (EVar "evalFieldAssign") (EVar "env"))) (EVar "fields"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "ctorFieldOrdersRef") "value")) (arm (PCon "Some" (PVar "order")) () (EApp (EApp (EVar "VCon") (EVar "name")) (EApp (EApp (EApp (EVar "recordCreateVals") (EVar "name")) (EVar "order")) (EVar "assigns")))) (arm (PCon "None") () (EApp (EApp (EVar "VRecord") (EVar "name")) (EVar "assigns")))))))
(DFunDef false "eval" ((PVar "env") (PCon "ERecordUpdate" (PVar "base") (PVar "fields") PWild)) (EApp (EApp (EVar "evalRecordUpdate") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "evalFieldAssign") (EVar "env"))) (EVar "fields"))))
(DFunDef false "eval" ((PVar "env") (PCon "EVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "evalVariantUpdate") (EVar "con")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "evalFieldAssign") (EVar "env"))) (EVar "fields"))))
(DFunDef false "eval" ((PVar "env") (PCon "EFieldAccess" (PVar "e") (PLit (LString "value")) PWild)) (EApp (EVar "evalValueField") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))))
(DFunDef false "eval" ((PVar "env") (PCon "EFieldAccess" (PVar "e") (PVar "field") PWild)) (EApp (EApp (EVar "evalField") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))) (EVar "field")))
(DFunDef false "eval" ((PVar "env") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))
(DFunDef false "eval" ((PVar "env") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))
(DFunDef false "eval" ((PVar "env") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "evalBlock") (EVar "env")) (EVar "stmts")))
(DFunDef false "eval" ((PVar "env") (PCon "ESlice" (PVar "arr") (PVar "lo") (PVar "hi") (PVar "incl") PWild)) (EApp (EApp (EApp (EApp (EVar "evalSlice") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "arr"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "eval" ((PVar "env") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "evalRange") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "hi"))) (EVar "incl")) (EVar "rangeListMk")))
(DFunDef false "eval" ((PVar "env") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "evalRange") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "hi"))) (EVar "incl")) (EVar "rangeArrayMk")))
(DFunDef false "eval" ((PVar "env") (PCon "ELoc" (PVar "l") (PVar "e"))) (EBlock (DoLet false false PWild (EApp (EVar "updateEvalLoc") (EVar "l"))) (DoExpr (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))))
(DFunDef false "eval" ((PVar "env") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))
(DFunDef false "eval" (PWild PWild) (EApp (EVar "panic") (ELit (LString "eval: unsupported node (slice 2)"))))
(DTypeSig false "evalMethodAt" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyCon "Route") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "evalMethodAt" ((PVar "env") (PVar "name") (PCon "RLocal" (PVar "sym") (PVar "dicts")) PWild PWild) (EApp (EApp (EApp (EVar "applyDicts") (EVar "env")) (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EVar "name") (EVar "sym")))) (EVar "dicts")))
(DFunDef false "evalMethodAt" ((PVar "env") (PVar "name") (PVar "route") (PVar "implRoutes") (PVar "methodRoutes")) (EBlock (DoLet false false (PVar "lm") (EApp (EApp (EVar "lookupMethod") (EVar "env")) (EVar "name"))) (DoLet false false (PTuple (PVar "narrowed") (PVar "fwdReqs0")) (EApp (EApp (EApp (EVar "methodAtNarrow") (EVar "env")) (EVar "lm")) (EVar "route"))) (DoLet false false (PVar "fwdReqs") (EApp (EApp (EVar "takeN") (EApp (EApp (EVar "lookupMethodReqCount") (EVar "name")) (EApp (EApp (EVar "routeTag") (EVar "env")) (EVar "route")))) (EVar "fwdReqs0"))) (DoExpr (EIf (EApp (EVar "awaitsArgs") (EVar "narrowed")) (EBlock (DoLet false false (PVar "v1") (EApp (EApp (EApp (EVar "applyDicts") (EVar "env")) (EVar "narrowed")) (EVar "methodRoutes"))) (DoLet false false (PVar "v2") (EApp (EApp (EApp (EVar "applyDicts") (EVar "env")) (EVar "v1")) (EVar "implRoutes"))) (DoExpr (EApp (EApp (EVar "applyValues") (EVar "v2")) (EVar "fwdReqs")))) (EVar "narrowed")))))
(DTypeSig true "evalIndex" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "evalIndex" ((PVar "container") (PCon "VInt" (PVar "i"))) (EApp (EApp (EVar "evalIndexInt") (EVar "container")) (EVar "i")))
(DFunDef false "evalIndex" (PWild PWild) (EApp (EVar "panic") (ELit (LString "index is not an Int"))))
(DTypeSig false "evalIndexInt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "evalIndexInt" ((PCon "VArray" (PVar "a")) (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "a")))) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-INDEX-OOB"))) (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EVar "intToString") (EVar "i"))) (ELit (LString " out of bounds")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "evalIndexInt" ((PCon "VList" (PVar "vs")) (PVar "i")) (EApp (EApp (EApp (EVar "listNthAt") (EVar "vs")) (EVar "i")) (EVar "i")))
(DFunDef false "evalIndexInt" ((PCon "VString" (PVar "s")) (PVar "i")) (EApp (EApp (EVar "stringIndexCp") (EVar "s")) (EVar "i")))
(DFunDef false "evalIndexInt" (PWild PWild) (EApp (EVar "panic") (ELit (LString "index on non-array/list/string"))))
(DTypeSig false "stringIndexCp" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "stringIndexCp" ((PVar "s") (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "stringLength") (EVar "s")))) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-INDEX-OOB"))) (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EVar "intToString") (EVar "i"))) (ELit (LString " out of bounds")))) (EIf (EVar "otherwise") (EApp (EVar "VChar") (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EApp (EVar "stringToChars") (EVar "s"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "evalSlice" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Bool") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalSlice" ((PVar "container") (PCon "VInt" (PVar "lo")) (PCon "VInt" (PVar "hi")) (PVar "incl")) (EApp (EApp (EApp (EApp (EVar "evalSliceInt") (EVar "container")) (EVar "lo")) (EVar "hi")) (EVar "incl")))
(DFunDef false "evalSlice" (PWild PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "slice index must be Int"))))
(DTypeSig false "evalSliceInt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalSliceInt" ((PCon "VArray" (PVar "a")) (PVar "lo") (PVar "hi") (PVar "incl")) (EApp (EApp (EApp (EVar "sliceArray") (EVar "a")) (EVar "lo")) (EIf (EVar "incl") (EBinOp "+" (EVar "hi") (ELit (LInt 1))) (EVar "hi"))))
(DFunDef false "evalSliceInt" ((PCon "VList" (PVar "vs")) (PVar "lo") (PVar "hi") (PVar "incl")) (EApp (EVar "VList") (EApp (EApp (EApp (EVar "listSliceV") (EVar "vs")) (EVar "lo")) (EIf (EVar "incl") (EBinOp "+" (EVar "hi") (ELit (LInt 1))) (EVar "hi")))))
(DFunDef false "evalSliceInt" ((PCon "VString" (PVar "s")) (PVar "lo") (PVar "hi") (PVar "incl")) (EApp (EVar "VString") (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EIf (EVar "incl") (EBinOp "+" (EVar "hi") (ELit (LInt 1))) (EVar "hi"))) (EVar "s"))))
(DFunDef false "evalSliceInt" (PWild PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "slice on non-array/list/string"))))
(DTypeSig false "sliceArray" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "sliceArray" ((PVar "a") (PVar "lo") (PVar "hiX")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (EBinOp ">" (EVar "hiX") (EApp (EVar "arrayLength") (EVar "a")))) (EBinOp "<" (EBinOp "-" (EVar "hiX") (EVar "lo")) (ELit (LInt 0)))) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-SLICE-OOB"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "slice [")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "lo")))) (ELit (LString ".."))) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "-" (EVar "hiX") (ELit (LInt 1)))))) (ELit (LString "] out of bounds")))) (EIf (EVar "otherwise") (EApp (EVar "VArray") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "hiX") (EVar "lo"))) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "lo") (EVar "i"))) (EVar "a"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "evalRange" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Bool") (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalRange" ((PCon "VInt" (PVar "lo")) (PCon "VInt" (PVar "hi")) (PVar "incl") (PVar "mk")) (EApp (EVar "mk") (EApp (EApp (EVar "intSeq") (EVar "lo")) (EIf (EVar "incl") (EBinOp "+" (EVar "hi") (ELit (LInt 1))) (EVar "hi")))))
(DFunDef false "evalRange" (PWild PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "range bound must be Int"))))
(DTypeSig true "rangeListMk" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "rangeListMk" ((PVar "ns")) (EApp (EVar "VList") (EApp (EApp (EVar "map") (EVar "VInt")) (EVar "ns"))))
(DTypeSig true "rangeArrayMk" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "rangeArrayMk" ((PVar "ns")) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "VInt")) (EVar "ns")))))
(DTypeSig false "evalFieldAssign" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "FieldAssign") (TyEffect () (Some "e") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalFieldAssign" ((PVar "env") (PCon "FieldAssign" (PVar "k") (PVar "e"))) (ETuple (EVar "k") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))))
(DTypeSig false "recordCreateVals" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "recordCreateVals" (PWild (PList) PWild) (EListLit))
(DFunDef false "recordCreateVals" ((PVar "con") (PCons (PVar "f") (PVar "fs")) (PVar "assigns")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "f")) (EVar "assigns")) (arm (PCon "Some" (PVar "v")) () (EBinOp "::" (EVar "v") (EApp (EApp (EApp (EVar "recordCreateVals") (EVar "con")) (EVar "fs")) (EVar "assigns")))) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "missing field: ")) (EVar "f"))))))
(DTypeSig true "evalRecordUpdate" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "evalRecordUpdate" ((PCon "VRecord" (PVar "name") (PVar "existing")) (PVar "updates")) (EApp (EApp (EVar "VRecord") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "mergeField") (EVar "updates"))) (EVar "existing"))))
(DFunDef false "evalRecordUpdate" (PWild PWild) (EApp (EVar "panic") (ELit (LString "record update on non-record"))))
(DTypeSig false "mergeField" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))) (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "mergeField" ((PVar "updates") (PTuple (PVar "k") (PVar "v"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "k")) (EVar "updates")) (arm (PCon "Some" (PVar "v2")) () (ETuple (EVar "k") (EVar "v2"))) (arm (PCon "None") () (ETuple (EVar "k") (EVar "v")))))
(DTypeSig true "evalVariantUpdate" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "evalVariantUpdate" ((PVar "con") (PCon "VCon" (PVar "con'") (PVar "vals")) (PVar "updates")) (EIf (EBinOp "==" (EVar "con") (EVar "con'")) (EApp (EApp (EVar "VCon") (EVar "con")) (EApp (EApp (EApp (EVar "applyVariantUpdates") (EVar "updates")) (EApp (EVar "ctorFieldOrderFor") (EVar "con"))) (EVar "vals"))) (EIf (EVar "otherwise") (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evalVariantUpdate: expected ")) (EApp (EVar "display") (EVar "con"))) (ELit (LString " got "))) (EApp (EVar "display") (EVar "con'"))) (ELit (LString "")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "evalVariantUpdate" ((PVar "con") (PCon "VRecord" (PVar "con'") (PVar "fields")) (PVar "updates")) (EIf (EBinOp "==" (EVar "con") (EVar "con'")) (EApp (EApp (EVar "VRecord") (EVar "con'")) (EApp (EApp (EVar "map") (EApp (EVar "mergeField") (EVar "updates"))) (EVar "fields"))) (EIf (EVar "otherwise") (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evalVariantUpdate: expected ")) (EApp (EVar "display") (EVar "con"))) (ELit (LString " got "))) (EApp (EVar "display") (EVar "con'"))) (ELit (LString "")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "evalVariantUpdate" ((PVar "con") (PVar "v") PWild) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evalVariantUpdate: not a constructor: ")) (EApp (EVar "display") (EVar "con"))) (ELit (LString " got "))) (EApp (EVar "display") (EApp (EVar "ppValue") (EVar "v")))) (ELit (LString "")))))
(DTypeSig false "ctorFieldOrderFor" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ctorFieldOrderFor" ((PVar "con")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "con")) (EFieldAccess (EVar "ctorFieldOrdersRef") "value")) (arm (PCon "Some" (PVar "fs")) () (EVar "fs")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "evalVariantUpdate: unknown constructor ")) (EVar "con"))))))
(DTypeSig false "applyVariantUpdates" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "applyVariantUpdates" (PWild (PList) PWild) (EListLit))
(DFunDef false "applyVariantUpdates" (PWild PWild (PList)) (EListLit))
(DFunDef false "applyVariantUpdates" ((PVar "updates") (PCons (PVar "f") (PVar "fs")) (PCons (PVar "v") (PVar "vs"))) (EBinOp "::" (EApp (EApp (EApp (EVar "applyFieldUpdate") (EVar "updates")) (EVar "f")) (EVar "v")) (EApp (EApp (EApp (EVar "applyVariantUpdates") (EVar "updates")) (EVar "fs")) (EVar "vs"))))
(DTypeSig false "applyFieldUpdate" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "applyFieldUpdate" ((PVar "updates") (PVar "field") (PVar "old")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "field")) (EVar "updates")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EVar "old"))))
(DTypeSig true "evalValueField" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "evalValueField" ((PCon "VRef" (PVar "cell"))) (EFieldAccess (EVar "cell") "value"))
(DFunDef false "evalValueField" ((PCon "VRecord" PWild (PVar "fields"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (ELit (LString "value"))) (EVar "fields")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "record has no field 'value'"))))))
(DFunDef false "evalValueField" (PWild) (EApp (EVar "panic") (ELit (LString "field access on non-record/ref"))))
(DTypeSig true "evalField" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "evalField" ((PCon "VRecord" PWild (PVar "fields")) (PVar "field")) (EApp (EApp (EVar "fieldOr") (EVar "fields")) (EVar "field")))
(DFunDef false "evalField" (PWild PWild) (EApp (EVar "panic") (ELit (LString "field access on non-record"))))
(DTypeSig false "fieldOr" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "fieldOr" ((PVar "fields") (PVar "field")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "field")) (EVar "fields")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "unknown field: ")) (EVar "field"))))))
(DTypeSig false "evalBlock" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "evalBlock" (PWild (PList)) (EVar "VUnit"))
(DFunDef false "evalBlock" ((PVar "env") (PList (PCon "DoExpr" (PVar "e")))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))
(DFunDef false "evalBlock" ((PVar "env") (PList (PCon "DoLet" PWild PWild (PVar "pat") (PVar "e")))) (EApp (EApp (EApp (EVar "blockLetLast") (EVar "env")) (EVar "pat")) (EVar "e")))
(DFunDef false "evalBlock" ((PVar "env") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))) (DoExpr (EApp (EApp (EVar "evalBlock") (EVar "env")) (EVar "rest")))))
(DFunDef false "evalBlock" ((PVar "env") (PCons (PCon "DoLet" PWild (PCon "True") (PCon "PVar" (PVar "f")) (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "blockRecLet") (EVar "env")) (EVar "f")) (EVar "e")) (EVar "rest")))
(DFunDef false "evalBlock" ((PVar "env") (PCons (PCon "DoLet" PWild PWild (PVar "pat") (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "blockLet") (EVar "env")) (EVar "pat")) (EVar "e")) (EVar "rest")))
(DFunDef false "evalBlock" ((PVar "env") (PList (PCon "DoAssign" PWild (PVar "e")))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "evalBlock" ((PVar "env") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EApp (EApp (EVar "evalBlock") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EListLit (ETuple (EVar "x") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))))) (EVar "rest")))
(DFunDef false "evalBlock" (PWild (PCons PWild PWild)) (EApp (EVar "panic") (ELit (LString "eval: unsupported block statement"))))
(DTypeSig false "blockLetLast" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "blockLetLast" ((PVar "env") (PVar "pat") (PVar "e")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-LET-REFUTE"))) (ELit (LString "let pattern match failed")))) (arm (PCon "Some" PWild) () (EVar "VUnit"))))
(DTypeSig false "blockRecLet" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "blockRecLet" ((PVar "env") (PVar "f") (PVar "e") (PVar "rest")) (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EVar "VUnit"))) (DoLet false false (PVar "recEnv") (EApp (EApp (EVar "pushFrame") (EVar "env")) (EListLit (ETuple (EVar "f") (EVar "cell"))))) (DoLet false false (PVar "v") (EApp (EApp (EVar "eval") (EVar "recEnv")) (EVar "e"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cell")) (EVar "v"))) (DoExpr (EApp (EApp (EVar "evalBlock") (EVar "recEnv")) (EVar "rest")))))
(DTypeSig false "blockLet" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "blockLet" ((PVar "env") (PVar "pat") (PVar "e") (PVar "rest")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-LET-REFUTE"))) (ELit (LString "let pattern match failed")))) (arm (PCon "Some" (PVar "binds")) () (EApp (EApp (EVar "evalBlock") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "rest")))))
(DTypeSig false "evalRecLet" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalRecLet" ((PVar "env") (PVar "f") (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EVar "VUnit"))) (DoLet false false (PVar "recEnv") (EApp (EApp (EVar "pushFrame") (EVar "env")) (EListLit (ETuple (EVar "f") (EVar "cell"))))) (DoLet false false (PVar "v") (EApp (EApp (EVar "eval") (EVar "recEnv")) (EVar "e1"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cell")) (EVar "v"))) (DoExpr (EApp (EApp (EVar "eval") (EVar "recEnv")) (EVar "e2")))))
(DTypeSig false "evalLet" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalLet" ((PVar "env") (PVar "pat") (PVar "e1") (PVar "e2")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e1"))) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-LET-REFUTE"))) (ELit (LString "let pattern match failed")))) (arm (PCon "Some" (PVar "binds")) () (EApp (EApp (EVar "eval") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "e2")))))
(DTypeSig false "evalLetGroup" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalLetGroup" ((PVar "env") (PVar "binds") (PVar "body")) (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EVar "map") (EVar "letBindCell")) (EVar "binds"))) (DoLet false false (PVar "env2") (EApp (EApp (EVar "pushFrame") (EVar "env")) (EVar "cells"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "installGroup") (EVar "env2")) (EVar "cells")) (EVar "binds"))) (DoExpr (EApp (EApp (EVar "eval") (EVar "env2")) (EVar "body")))))
(DTypeSig false "letBindCell" (TyFun (TyCon "LetBind") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "letBindCell" ((PCon "LetBind" (PVar "name") PWild)) (ETuple (EVar "name") (EApp (EVar "Ref") (EVar "VUnit"))))
(DTypeSig false "installGroup" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyEffect () (Some "e") (TyCon "Unit"))))))
(DFunDef false "installGroup" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "installGroup" ((PVar "env") (PVar "cells") (PCons (PCon "LetBind" (PVar "name") (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EApp (EApp (EVar "findCell") (EVar "cells")) (EVar "name"))) (EApp (EApp (EVar "groupValue") (EVar "env")) (EApp (EApp (EVar "map") (EVar "funClauseToClause")) (EVar "clauses"))))) (DoExpr (EApp (EApp (EApp (EVar "installGroup") (EVar "env")) (EVar "cells")) (EVar "rest")))))
(DTypeSig false "funClauseToClause" (TyFun (TyCon "FunClause") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))
(DFunDef false "funClauseToClause" ((PCon "FunClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "pats") (EVar "body")))
(DTypeSig false "groupValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "groupValue" ((PVar "env") (PList (PTuple (PVar "pats") (PVar "body")))) (EIf (EApp (EVar "isNullary") (EVar "pats")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "VClosure") (EVar "env")) (EVar "pats")) (EVar "body")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "groupValue" ((PVar "env") (PVar "clauses")) (EApp (EVar "VMulti") (EApp (EApp (EVar "map") (EApp (EVar "clauseClosure") (EVar "env"))) (EVar "clauses"))))
(DTypeSig false "topGroupValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "topGroupValue" ((PVar "env") (PList (PTuple (PVar "pats") (PVar "body")))) (EIf (EApp (EVar "isNullary") (EVar "pats")) (EApp (EVar "VThunk") (ELam (PWild) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "VClosure") (EVar "env")) (EVar "pats")) (EVar "body")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "topGroupValue" ((PVar "env") (PVar "clauses")) (EApp (EVar "VMulti") (EApp (EApp (EVar "map") (EApp (EVar "clauseClosure") (EVar "env"))) (EVar "clauses"))))
(DTypeSig false "clauseClosure" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "clauseClosure" ((PVar "env") (PTuple (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "VClosure") (EVar "env")) (EVar "pats")) (EVar "body")))
(DTypeSig true "isNullary" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool")))
(DFunDef false "isNullary" ((PList)) (EVar "True"))
(DFunDef false "isNullary" (PWild) (EVar "False"))
(DTypeSig false "evalMatch" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalMatch" (PWild PWild (PList)) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-NONEXHAUSTIVE-MATCH"))) (ELit (LString "non-exhaustive match"))))
(DFunDef false "evalMatch" ((PVar "env") (PVar "sv") (PCons (PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EVar "sv")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "evalMatch") (EVar "env")) (EVar "sv")) (EVar "rest"))) (arm (PCon "Some" (PVar "binds")) () (EMatch (EApp (EApp (EVar "runGuards") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "guards")) (arm (PCon "Some" (PVar "env2")) () (EApp (EApp (EVar "eval") (EVar "env2")) (EVar "body"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "evalMatch") (EVar "env")) (EVar "sv")) (EVar "rest")))))))
(DTypeSig false "runGuards" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "runGuards" ((PVar "env") (PList)) (EApp (EVar "Some") (EVar "env")))
(DFunDef false "runGuards" ((PVar "env") (PCons (PCon "GBool" (PVar "g")) (PVar "qs"))) (EMatch (EApp (EApp (EVar "eval") (EVar "env")) (EVar "g")) (arm (PCon "VBool" (PCon "True")) () (EApp (EApp (EVar "runGuards") (EVar "env")) (EVar "qs"))) (arm (PCon "VCon" (PLit (LString "True")) (PList)) () (EApp (EApp (EVar "runGuards") (EVar "env")) (EVar "qs"))) (arm PWild () (EVar "None"))))
(DFunDef false "runGuards" ((PVar "env") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "qs"))) (EMatch (EApp (EApp (EVar "matchPat") (EVar "p")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "runGuards") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "b"))) (EVar "qs"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "evalIf" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalIf" ((PVar "env") (PCon "VBool" (PCon "True")) (PVar "t") PWild) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "t")))
(DFunDef false "evalIf" ((PVar "env") (PCon "VCon" (PLit (LString "True")) (PList)) (PVar "t") PWild) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "t")))
(DFunDef false "evalIf" ((PVar "env") (PCon "VBool" (PCon "False")) PWild (PVar "e")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))
(DFunDef false "evalIf" ((PVar "env") (PCon "VCon" (PLit (LString "False")) (PList)) PWild (PVar "e")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))
(DFunDef false "evalIf" (PWild PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "if condition is not a Bool"))))
(DTypeSig true "evalUnop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "evalUnop" ((PLit (LString "-")) (PCon "VInt" (PVar "n"))) (EApp (EVar "VInt") (EBinOp "-" (ELit (LInt 0)) (EVar "n"))))
(DFunDef false "evalUnop" ((PLit (LString "-")) (PCon "VFloat" (PVar "f"))) (EApp (EVar "VFloat") (EBinOp "-" (ELit (LFloat 0.0)) (EVar "f"))))
(DFunDef false "evalUnop" ((PLit (LString "-")) PWild) (EApp (EVar "panic") (ELit (LString "unary minus on non-number"))))
(DFunDef false "evalUnop" ((PLit (LString "!")) (PCon "VBool" (PVar "b"))) (EApp (EVar "VBool") (EApp (EVar "not") (EVar "b"))))
(DFunDef false "evalUnop" ((PLit (LString "!")) PWild) (EApp (EVar "panic") (ELit (LString "'!' on non-Bool"))))
(DFunDef false "evalUnop" ((PLit (LString "not")) (PCon "VBool" (PVar "b"))) (EApp (EVar "VBool") (EApp (EVar "not") (EVar "b"))))
(DFunDef false "evalUnop" ((PLit (LString "not")) PWild) (EApp (EVar "panic") (ELit (LString "'!' on non-Bool"))))
(DFunDef false "evalUnop" ((PVar "op") PWild) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "unknown unary op: ")) (EVar "op"))))
(DTypeSig false "evalBinop" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalBinop" ((PVar "env") (PLit (LString "|>")) (PVar "l") (PVar "r")) (EApp (EApp (EVar "apply") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))))
(DFunDef false "evalBinop" ((PVar "env") (PLit (LString ">>")) (PVar "l") (PVar "r")) (EApp (EApp (EVar "composeFwd") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r"))))
(DFunDef false "evalBinop" ((PVar "env") (PLit (LString "<<")) (PVar "l") (PVar "r")) (EApp (EApp (EVar "composeBwd") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r"))))
(DFunDef false "evalBinop" ((PVar "env") (PLit (LString "&&")) (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "evalAnd") (EVar "env")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))) (EVar "r")))
(DFunDef false "evalBinop" ((PVar "env") (PLit (LString "||")) (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "evalOr") (EVar "env")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))) (EVar "r")))
(DFunDef false "evalBinop" ((PVar "env") (PLit (LString "::")) (PVar "l") (PVar "r")) (EApp (EApp (EVar "consVal") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r"))))
(DFunDef false "evalBinop" ((PVar "env") (PLit (LString "++")) (PVar "l") (PVar "r")) (EApp (EApp (EVar "appendVal") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r"))))
(DFunDef false "evalBinop" ((PVar "env") (PVar "op") (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "evalArith") (EVar "op")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r"))))
(DTypeSig false "composeFwd" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "composeFwd" ((PVar "fv") (PVar "gv")) (EApp (EVar "VPrim") (ELam ((PVar "x")) (EApp (EApp (EVar "apply") (EVar "gv")) (EApp (EApp (EVar "apply") (EVar "fv")) (EVar "x"))))))
(DTypeSig false "composeBwd" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "composeBwd" ((PVar "fv") (PVar "gv")) (EApp (EVar "VPrim") (ELam ((PVar "x")) (EApp (EApp (EVar "apply") (EVar "fv")) (EApp (EApp (EVar "apply") (EVar "gv")) (EVar "x"))))))
(DTypeSig false "evalAnd" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalAnd" (PWild (PCon "VBool" (PCon "False")) PWild) (EApp (EVar "VBool") (EVar "False")))
(DFunDef false "evalAnd" (PWild (PCon "VCon" (PLit (LString "False")) (PList)) PWild) (EApp (EVar "VBool") (EVar "False")))
(DFunDef false "evalAnd" ((PVar "env") (PCon "VBool" (PCon "True")) (PVar "r")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r")))
(DFunDef false "evalAnd" ((PVar "env") (PCon "VCon" (PLit (LString "True")) (PList)) (PVar "r")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r")))
(DFunDef false "evalAnd" (PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "'&&' on non-Bool"))))
(DTypeSig false "evalOr" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalOr" (PWild (PCon "VBool" (PCon "True")) PWild) (EApp (EVar "VBool") (EVar "True")))
(DFunDef false "evalOr" (PWild (PCon "VCon" (PLit (LString "True")) (PList)) PWild) (EApp (EVar "VBool") (EVar "True")))
(DFunDef false "evalOr" ((PVar "env") (PCon "VBool" (PCon "False")) (PVar "r")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r")))
(DFunDef false "evalOr" ((PVar "env") (PCon "VCon" (PLit (LString "False")) (PList)) (PVar "r")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r")))
(DFunDef false "evalOr" (PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "'||' on non-Bool"))))
(DTypeSig true "consVal" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "consVal" ((PVar "hv") (PCon "VList" (PVar "xs"))) (EApp (EVar "VList") (EBinOp "::" (EVar "hv") (EVar "xs"))))
(DFunDef false "consVal" (PWild PWild) (EApp (EVar "panic") (ELit (LString "cons (::) rhs is not a list"))))
(DTypeSig true "appendVal" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "appendVal" ((PCon "VList" (PVar "a")) (PCon "VList" (PVar "b"))) (EApp (EVar "VList") (EBinOp "++" (EVar "a") (EVar "b"))))
(DFunDef false "appendVal" ((PCon "VString" (PVar "a")) (PCon "VString" (PVar "b"))) (EApp (EVar "VString") (EBinOp "++" (EVar "a") (EVar "b"))))
(DFunDef false "appendVal" (PWild PWild) (EApp (EVar "panic") (ELit (LString "'++' requires Semigroup (List, String, or a type with append)"))))
(DTypeSig true "evalArith" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "evalArith" ((PLit (LString "+")) (PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EBinOp "+" (EVar "a") (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "-")) (PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EBinOp "-" (EVar "a") (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "*")) (PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EBinOp "*" (EVar "a") (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "/")) (PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EIf (EBinOp "==" (EVar "b") (ELit (LInt 0))) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-DIV-ZERO"))) (ELit (LString "division by zero"))) (EIf (EVar "otherwise") (EApp (EVar "VInt") (EBinOp "/" (EVar "a") (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "evalArith" ((PLit (LString "%")) (PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EIf (EBinOp "==" (EVar "b") (ELit (LInt 0))) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-MOD-ZERO"))) (ELit (LString "modulo by zero"))) (EIf (EVar "otherwise") (EApp (EVar "VInt") (EBinOp "%" (EVar "a") (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "evalArith" ((PLit (LString "+")) (PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EBinOp "+" (EVar "a") (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "-")) (PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EBinOp "-" (EVar "a") (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "*")) (PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EBinOp "*" (EVar "a") (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "/")) (PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EBinOp "/" (EVar "a") (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "%")) (PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EApp (EApp (EVar "floatRem") (EVar "a")) (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "==")) (PVar "a") (PVar "b")) (EApp (EVar "VBool") (EApp (EApp (EVar "valueEq") (EVar "a")) (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "!=")) (PVar "a") (PVar "b")) (EApp (EVar "VBool") (EApp (EVar "not") (EApp (EApp (EVar "valueEq") (EVar "a")) (EVar "b")))))
(DFunDef false "evalArith" ((PLit (LString "<")) (PVar "a") (PVar "b")) (EApp (EVar "VBool") (EApp (EVar "ordLt") (EApp (EApp (EVar "valueCompare") (EVar "a")) (EVar "b")))))
(DFunDef false "evalArith" ((PLit (LString ">")) (PVar "a") (PVar "b")) (EApp (EVar "VBool") (EApp (EVar "ordGt") (EApp (EApp (EVar "valueCompare") (EVar "a")) (EVar "b")))))
(DFunDef false "evalArith" ((PLit (LString "<=")) (PVar "a") (PVar "b")) (EApp (EVar "VBool") (EApp (EVar "not") (EApp (EVar "ordGt") (EApp (EApp (EVar "valueCompare") (EVar "a")) (EVar "b"))))))
(DFunDef false "evalArith" ((PLit (LString ">=")) (PVar "a") (PVar "b")) (EApp (EVar "VBool") (EApp (EVar "not") (EApp (EVar "ordLt") (EApp (EApp (EVar "valueCompare") (EVar "a")) (EVar "b"))))))
(DFunDef false "evalArith" ((PVar "op") PWild PWild) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown op '")) (EVar "op")) (ELit (LString "'")))))
(DTypeSig true "collectCtors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "collectCtors" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ctorsOfDecl")) (EVar "prog")))
(DTypeSig false "ctorsOfDecl" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "ctorsOfDecl" ((PCon "DData" PWild PWild PWild (PVar "variants") PWild)) (EApp (EApp (EVar "map") (EVar "ctorEntry")) (EVar "variants")))
(DFunDef false "ctorsOfDecl" ((PCon "DNewtype" PWild PWild PWild (PVar "con") (PVar "fty") PWild)) (EListLit (EApp (EVar "ctorEntry") (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty")))))))
(DFunDef false "ctorsOfDecl" (PWild) (EListLit))
(DTypeSig false "ctorEntry" (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "ctorEntry" ((PCon "Variant" (PVar "n") (PVar "payload"))) (ETuple (EVar "n") (EApp (EApp (EVar "makeCtor") (EVar "n")) (EApp (EVar "payloadArity") (EVar "payload")))))
(DTypeSig true "payloadArity" (TyFun (TyCon "ConPayload") (TyCon "Int")))
(DFunDef false "payloadArity" ((PCon "ConPos" (PVar "tys"))) (EApp (EVar "listLen") (EVar "tys")))
(DFunDef false "payloadArity" ((PCon "ConNamed" (PVar "fs") PWild)) (EApp (EVar "listLen") (EVar "fs")))
(DTypeSig false "funDefs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "funDefs" ((PList)) (EListLit))
(DFunDef false "funDefs" ((PCons (PCon "DFunDef" PWild (PVar "n") (PVar "pats") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (ETuple (EVar "pats") (EVar "body"))) (EApp (EVar "funDefs") (EVar "rest"))))
(DFunDef false "funDefs" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "letGroupDefs") (EVar "binds")) (EApp (EVar "funDefs") (EVar "rest"))))
(DFunDef false "funDefs" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "funDefs") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "funDefs" ((PCons PWild (PVar "rest"))) (EApp (EVar "funDefs") (EVar "rest")))
(DTypeSig false "letGroupDefs" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "letGroupDefs" ((PList)) (EListLit))
(DFunDef false "letGroupDefs" ((PCons (PCon "LetBind" (PVar "n") (PVar "clauses")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "clauseDef") (EVar "n"))) (EVar "clauses")) (EApp (EVar "letGroupDefs") (EVar "rest"))))
(DTypeSig false "clauseDef" (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clauseDef" ((PVar "n") (PCon "FunClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "n") (ETuple (EVar "pats") (EVar "body"))))
(DTypeSig false "funGroupNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "funGroupNames" ((PList) PWild) (EListLit))
(DFunDef false "funGroupNames" ((PCons (PTuple (PVar "n") PWild) (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "seen")) (EApp (EApp (EVar "funGroupNames") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "n") (EApp (EApp (EVar "funGroupNames") (EVar "rest")) (EBinOp "::" (EVar "n") (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "clausesForName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clausesForName" (PWild (PList)) (EListLit))
(DFunDef false "clausesForName" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "c")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EBinOp "::" (EVar "c") (EApp (EApp (EVar "clausesForName") (EVar "name")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "clausesForName") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "buildIfaceDispatch" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "buildIfaceDispatch" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ifaceDispatchEntries")) (EVar "prog")))
(DTypeSig false "ifaceDispatchEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "ifaceDispatchEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EVar "map") (EApp (EApp (EVar "ifaceMethodEntry") (EVar "ifaceName")) (EVar "typeParams"))) (EVar "methods")))
(DFunDef false "ifaceDispatchEntries" (PWild) (EListLit))
(DTypeSig false "ifaceMethodEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "ifaceMethodEntry" ((PVar "ifaceName") (PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild)) (ETuple (ETuple (EVar "ifaceName") (EVar "mname")) (EApp (EApp (EVar "dispatchPositionsOf") (EVar "mty")) (EApp (EVar "receiverParam") (EVar "typeParams")))))
(DTypeSig false "receiverParam" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "receiverParam" ((PList)) (EListLit))
(DFunDef false "receiverParam" ((PCons (PVar "p") PWild)) (EListLit (EVar "p")))
(DTypeSig true "lookupPositions" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "lookupPositions" (PWild PWild (PList)) (EListLit (ELit (LInt 0))))
(DFunDef false "lookupPositions" ((PVar "iface") (PVar "mname") (PCons (PTuple (PTuple (PVar "i") (PVar "m")) (PVar "p")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "iface") (EVar "i")) (EBinOp "==" (EVar "mname") (EVar "m"))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lookupPositions") (EVar "iface")) (EVar "mname")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implMethodValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "implMethodValue" ((PVar "env") (PVar "positions") (PList) (PVar "body")) (EIf (EApp (EVar "isEmptyL") (EVar "positions")) (EApp (EApp (EVar "memoThunk") (EVar "env")) (EVar "body")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "VClosure") (EVar "env")) (EListLit (EApp (EVar "PVar") (ELit (LString "$eta"))))) (EApp (EApp (EVar "EApp") (EVar "body")) (EApp (EVar "EVar") (ELit (LString "$eta"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "implMethodValue" ((PVar "env") PWild (PVar "pats") (PVar "body")) (EApp (EApp (EApp (EVar "VClosure") (EVar "env")) (EVar "pats")) (EVar "body")))
(DTypeSig false "memoThunk" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "memoThunk" ((PVar "env") (PVar "body")) (EApp (EApp (EApp (EVar "memoThunkOf") (EApp (EVar "Ref") (EVar "None"))) (EVar "env")) (EVar "body")))
(DTypeSig false "memoThunkOf" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "memoThunkOf" ((PVar "cell") (PVar "env") (PVar "body")) (EApp (EVar "VThunk") (ELam (PWild) (EApp (EApp (EApp (EVar "forceMemoCell") (EVar "cell")) (EVar "env")) (EVar "body")))))
(DTypeSig false "forceMemoCell" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "forceMemoCell" ((PVar "cell") (PVar "env") (PVar "body")) (EMatch (EFieldAccess (EVar "cell") "value") (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EApp (EVar "storeMemo") (EVar "cell")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body"))))))
(DTypeSig false "storeMemo" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "storeMemo" ((PVar "cell") (PVar "v")) (EApp (EApp (EVar "seqV") (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "v")))) (EVar "v")))
(DTypeSig false "seqV" (TyFun (TyCon "Unit") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "seqV" (PWild (PVar "v")) (EVar "v"))
(DTypeSig false "declImplEntries" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "declImplEntries" ((PVar "env") (PVar "disp") (PRec "DImpl" ((rf "iface" (PVar "ifaceName")) (rf "tys" (PVar "typeArgs")) (rf "methods" None)) true)) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "implMethodEntry") (EVar "env")) (EVar "disp")) (EVar "ifaceName")) (EVar "typeArgs"))) (EVar "methods")))
(DFunDef false "declImplEntries" ((PVar "env") PWild (PRec "DInterface" ((rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "defaultEntry") (EVar "env")) (EVar "typeParams"))) (EVar "methods")))
(DFunDef false "declImplEntries" (PWild PWild PWild) (EListLit))
(DTypeSig false "implMethodEntry" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "ImplMethod") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "implMethodEntry" ((PVar "env") (PVar "disp") (PVar "ifaceName") (PVar "typeArgs") (PCon "ImplMethod" (PVar "mname") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "tag") (EApp (EApp (EVar "fromOption") (EVar "noneHeadTag")) (EApp (EVar "headTyconHead") (EVar "typeArgs")))) (DoLet false false (PVar "key") (EApp (EApp (EApp (EVar "implKeyOf") (EVar "ifaceName")) (EVar "typeArgs")) (EVar "None"))) (DoLet false false (PVar "positions") (EApp (EApp (EApp (EVar "lookupPositions") (EVar "ifaceName")) (EVar "mname")) (EVar "disp"))) (DoLet false false (PVar "inner") (EApp (EApp (EApp (EApp (EVar "implMethodValue") (EVar "env")) (EVar "positions")) (EVar "pats")) (EVar "body"))) (DoExpr (ETuple (EVar "mname") (ETuple (EApp (EVar "tyvarsInArgs") (EVar "typeArgs")) (EApp (EApp (EApp (EApp (EApp (EVar "VTypedImpl") (EVar "tag")) (EVar "key")) (EVar "positions")) (ELit (LInt 0))) (EVar "inner")))))))
(DTypeSig true "headTyconHead" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headTyconHead" ((PList)) (EVar "None"))
(DFunDef false "headTyconHead" ((PCons (PVar "t") PWild)) (EApp (EVar "headTycon") (EVar "t")))
(DTypeSig false "defaultEntry" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "defaultEntry" (PWild PWild (PCon "IfaceMethod" PWild PWild (PCon "None"))) (EListLit))
(DFunDef false "defaultEntry" ((PVar "env") (PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") PWild (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))))) (EListLit (ETuple (EVar "mname") (ETuple (EApp (EVar "listLen") (EVar "typeParams")) (EApp (EApp (EApp (EApp (EVar "implMethodValue") (EVar "env")) (EListLit)) (EVar "pats")) (EVar "body"))))))
(DTypeSig true "coalesceImpls" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "coalesceImpls" ((PVar "scored")) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EApp (EVar "coalesceOne") (EVar "n")) (EVar "scored"))))) (EApp (EVar "dedup") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "scored")))))
(DTypeSig false "coalesceOne" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "coalesceOne" ((PVar "name") (PVar "scored")) (EApp (EVar "oneOrMulti") (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EVar "sortByScore") (EApp (EApp (EVar "selectByName") (EVar "name")) (EVar "scored"))))))
(DTypeSig false "oneOrMulti" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "oneOrMulti" ((PList (PVar "v"))) (EVar "v"))
(DFunDef false "oneOrMulti" ((PVar "many")) (EApp (EVar "VMulti") (EVar "many")))
(DTypeSig false "selectByName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "selectByName" ((PVar "name") (PVar "scored")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "filter") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "fst") (EVar "e")) (EVar "name")))) (EVar "scored"))))
(DTypeSig false "sortByScore" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "sortByScore" ((PVar "xs")) (EApp (EApp (EVar "sortGo") (EVar "xs")) (EListLit)))
(DTypeSig false "sortGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "sortGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "sortGo" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "sortGo") (EVar "xs")) (EApp (EApp (EVar "insertScore") (EVar "x")) (EVar "acc"))))
(DTypeSig false "insertScore" (TyFun (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "insertScore" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "insertScore" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<=" (EApp (EVar "fst") (EVar "y")) (EApp (EVar "fst") (EVar "x"))) (EBinOp "::" (EVar "y") (EApp (EApp (EVar "insertScore") (EVar "x")) (EVar "ys"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "implMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "implMethodNames" ((PVar "prog")) (EApp (EVar "dedup") (EApp (EApp (EVar "flatMap") (EVar "implDeclNames")) (EVar "prog"))))
(DTypeSig false "implDeclNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "implDeclNames" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "map") (EVar "implMethodName")) (EVar "methods")))
(DFunDef false "implDeclNames" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "defaultName")) (EVar "methods")))
(DFunDef false "implDeclNames" (PWild) (EListLit))
(DTypeSig false "implMethodName" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodName" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "defaultName" (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "defaultName" ((PCon "IfaceMethod" (PVar "n") PWild (PCon "Some" PWild))) (EListLit (EVar "n")))
(DFunDef false "defaultName" ((PCon "IfaceMethod" PWild PWild (PCon "None"))) (EListLit))
(DTypeSig true "cellResult" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))) (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "cellResult" ((PTuple (PVar "n") (PVar "cell"))) (ETuple (EVar "n") (EFieldAccess (EVar "cell") "value")))
(DTypeSig true "boolSeeds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "boolSeeds" () (EListLit (ETuple (ELit (LString "True")) (EApp (EVar "VBool") (EVar "True"))) (ETuple (ELit (LString "False")) (EApp (EVar "VBool") (EVar "False"))) (ETuple (ELit (LString "otherwise")) (EApp (EVar "VBool") (EVar "True")))))
(DTypeSig false "prim1" (TyFun (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "prim1" ((PVar "f")) (EApp (EVar "VPrim") (EVar "f")))
(DTypeSig false "prim2" (TyFun (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "prim2" ((PVar "f")) (EApp (EVar "VPrim") (ELam ((PVar "a")) (EApp (EVar "VPrim") (ELam ((PVar "b")) (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")))))))
(DTypeSig false "prim3" (TyFun (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "prim3" ((PVar "f")) (EApp (EVar "VPrim") (ELam ((PVar "a")) (EApp (EVar "VPrim") (ELam ((PVar "b")) (EApp (EVar "VPrim") (ELam ((PVar "c")) (EApp (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")) (EVar "c")))))))))
(DTypeSig false "prim2M" (TyFun (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "prim2M" ((PVar "f")) (EApp (EVar "VPrim") (ELam ((PVar "a")) (EApp (EVar "VPrim") (ELam ((PVar "b")) (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")))))))
(DTypeSig false "prim3M" (TyFun (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "prim3M" ((PVar "f")) (EApp (EVar "VPrim") (ELam ((PVar "a")) (EApp (EVar "VPrim") (ELam ((PVar "b")) (EApp (EVar "VPrim") (ELam ((PVar "c")) (EApp (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")) (EVar "c")))))))))
(DTypeSig false "prim5M" (TyFun (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "prim5M" ((PVar "f")) (EApp (EVar "VPrim") (ELam ((PVar "a")) (EApp (EVar "VPrim") (ELam ((PVar "b")) (EApp (EVar "VPrim") (ELam ((PVar "c")) (EApp (EVar "VPrim") (ELam ((PVar "d")) (EApp (EVar "VPrim") (ELam ((PVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d")) (EVar "x")))))))))))))
(DTypeSig false "prim1M" (TyFun (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "prim1M" ((PVar "f")) (EApp (EVar "VPrim") (EVar "f")))
(DTypeSig true "outputRef" (TyApp (TyCon "Ref") (TyCon "String")))
(DFunDef false "outputRef" () (EApp (EVar "Ref") (ELit (LString ""))))
(DTypeSig true "currentEvalLoc" (TyApp (TyCon "Ref") (TyCon "Loc")))
(DFunDef false "currentEvalLoc" () (EApp (EVar "Ref") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig true "currentEvalFile" (TyApp (TyCon "Ref") (TyCon "String")))
(DFunDef false "currentEvalFile" () (EApp (EVar "Ref") (ELit (LString ""))))
(DTypeSig false "evalDepthRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "evalDepthRef" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig false "evalDepthLimit" (TyCon "Int"))
(DFunDef false "evalDepthLimit" () (ELit (LInt 25000)))
(DTypeSig true "runJsonMode" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "runJsonMode" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig false "updateEvalLoc" (TyFun (TyCon "Loc") (TyCon "Unit")))
(DFunDef false "updateEvalLoc" ((PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "sl") (ELit (LInt 1))) (EBinOp "==" (EVar "sc") (ELit (LInt 0)))) (EBinOp "==" (EVar "el") (ELit (LInt 1)))) (EBinOp "==" (EVar "ec") (ELit (LInt 0)))) (ELit LUnit) (EIf (EVar "otherwise") (EApp (EApp (EVar "setRef") (EVar "currentEvalLoc")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "runtimePanic" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyVar "a"))))
(DFunDef false "runtimePanic" ((PVar "code") (PVar "msg")) (EMatch (EFieldAccess (EVar "currentEvalLoc") "value") (arm (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) () (EBlock (DoLet false false (PVar "ff") (EIf (EBinOp "==" (EVar "f") (ELit (LString ""))) (EFieldAccess (EVar "currentEvalFile") "value") (EVar "f"))) (DoExpr (EIf (EFieldAccess (EVar "runJsonMode") "value") (EBlock (DoLet false false (PVar "diag") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EVar "code")) (EVar "msg")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "ff")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))) (EVar "None")) (EVar "None"))) (DoExpr (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "fmtSentinel"))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "ff") (ELit (LString "")) (EListLit (EVar "diag"))))))) (ELit (LString "")))))) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "fmtSentinel"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "ff"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ": runtime error ["))) (EApp (EVar "display") (EVar "code"))) (ELit (LString "]: "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))))))))
(DTypeSig false "fmtSentinel" (TyCon "String"))
(DFunDef false "fmtSentinel" () (ELit (LString "\u{01}")))
(DTypeSig false "appendOutput" (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "appendOutput" ((PVar "s")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "outputRef")) (EBinOp "++" (EFieldAccess (EVar "outputRef") "value") (EVar "s")))) (DoLet false false PWild (EApp (EVar "stashRunStdout") (EFieldAccess (EVar "outputRef") "value"))) (DoExpr (EVar "VUnit"))))
(DTypeSig false "pPutStr" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pPutStr" ((PCon "VString" (PVar "s"))) (EApp (EVar "appendOutput") (EVar "s")))
(DFunDef false "pPutStr" (PWild) (EApp (EVar "panic") (ELit (LString "putStr: not a String"))))
(DTypeSig false "pPutStrLn" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pPutStrLn" ((PCon "VString" (PVar "s"))) (EApp (EVar "appendOutput") (EBinOp "++" (EVar "s") (ELit (LString "\n")))))
(DFunDef false "pPutStrLn" (PWild) (EApp (EVar "panic") (ELit (LString "putStrLn: not a String"))))
(DTypeSig false "pStashRunStdout" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStashRunStdout" ((PCon "VString" (PVar "s"))) (ELet false PWild (EApp (EVar "stashRunStdout") (EVar "s")) (EVar "VUnit")))
(DFunDef false "pStashRunStdout" (PWild) (EApp (EVar "panic") (ELit (LString "stashRunStdout: not a String"))))
(DTypeSig false "pEnableRunStdoutFlush" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pEnableRunStdoutFlush" (PWild) (ELet false PWild (EApp (EVar "enableRunStdoutFlush") (ELit LUnit)) (EVar "VUnit")))
(DTypeSig false "pDiscard" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pDiscard" (PWild) (EVar "VUnit"))
(DTypeSig false "pPanic" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyVar "a"))))
(DFunDef false "pPanic" ((PVar "v")) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-PANIC"))) (EApp (EVar "unString") (EVar "v"))))
(DTypeSig false "pRef" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pRef" ((PVar "v")) (EApp (EVar "VRef") (EApp (EVar "Ref") (EVar "v"))))
(DTypeSig false "pSetRef" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pSetRef" ((PCon "VRef" (PVar "cell")) (PVar "v")) (EApp (EApp (EVar "doSetRef") (EVar "cell")) (EVar "v")))
(DFunDef false "pSetRef" (PWild PWild) (EApp (EVar "panic") (ELit (LString "setRef: not a Ref"))))
(DTypeSig false "doSetRef" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "doSetRef" ((PVar "cell") (PVar "v")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cell")) (EVar "v"))) (DoExpr (EVar "VUnit"))))
(DTypeSig false "unString" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "String")))
(DFunDef false "unString" ((PCon "VString" (PVar "s"))) (EVar "s"))
(DFunDef false "unString" (PWild) (EApp (EVar "panic") (ELit (LString "expected a String"))))
(DTypeSig false "unChar" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Char")))
(DFunDef false "unChar" ((PCon "VChar" (PVar "s"))) (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s"))))
(DFunDef false "unChar" (PWild) (EApp (EVar "panic") (ELit (LString "expected a Char"))))
(DTypeSig false "orderingToValue" (TyFun (TyCon "Ordering") (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "orderingToValue" ((PCon "Lt")) (EApp (EApp (EVar "VCon") (ELit (LString "Lt"))) (EListLit)))
(DFunDef false "orderingToValue" ((PCon "Eq")) (EApp (EApp (EVar "VCon") (ELit (LString "Eq"))) (EListLit)))
(DFunDef false "orderingToValue" ((PCon "Gt")) (EApp (EApp (EVar "VCon") (ELit (LString "Gt"))) (EListLit)))
(DTypeSig false "optionToValue" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "optionToValue" ((PCon "None")) (EApp (EApp (EVar "VCon") (ELit (LString "None"))) (EListLit)))
(DFunDef false "optionToValue" ((PCon "Some" (PVar "v"))) (EApp (EApp (EVar "VCon") (ELit (LString "Some"))) (EListLit (EVar "v"))))
(DTypeSig false "u64Golden" (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))
(DFunDef false "u64Golden" () (ETuple (ELit (LInt 31765)) (ELit (LInt 32586)) (ELit (LInt 31161)) (ELit (LInt 40503))))
(DTypeSig false "u64Const1" (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))
(DFunDef false "u64Const1" () (ETuple (ELit (LInt 58809)) (ELit (LInt 7396)) (ELit (LInt 18285)) (ELit (LInt 48984))))
(DTypeSig false "u64Const2" (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))
(DFunDef false "u64Const2" () (ETuple (ELit (LInt 4587)) (ELit (LInt 4913)) (ELit (LInt 18875)) (ELit (LInt 38096))))
(DTypeSig false "u64FnvBasis" (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))
(DFunDef false "u64FnvBasis" () (ETuple (ELit (LInt 8997)) (ELit (LInt 33826)) (ELit (LInt 40164)) (ELit (LInt 52210))))
(DTypeSig false "u64FnvPrime" (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))
(DFunDef false "u64FnvPrime" () (ETuple (ELit (LInt 435)) (ELit (LInt 0)) (ELit (LInt 256)) (ELit (LInt 0))))
(DTypeSig false "u64Finalize" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "u64Finalize" ((PVar "z")) (EBlock (DoLet false false (PVar "z1") (EApp (EApp (EVar "mulLow64") (EApp (EApp (EVar "xor64") (EVar "z")) (EApp (EApp (EVar "shr64") (EVar "z")) (ELit (LInt 30))))) (EVar "u64Const1"))) (DoLet false false (PVar "z2") (EApp (EApp (EVar "mulLow64") (EApp (EApp (EVar "xor64") (EVar "z1")) (EApp (EApp (EVar "shr64") (EVar "z1")) (ELit (LInt 27))))) (EVar "u64Const2"))) (DoExpr (EApp (EApp (EVar "xor64") (EVar "z2")) (EApp (EApp (EVar "shr64") (EVar "z2")) (ELit (LInt 31)))))))
(DTypeSig false "u64Mix" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "u64Mix" ((PVar "x")) (EApp (EVar "u64Finalize") (EApp (EApp (EVar "add64") (EVar "x")) (EVar "u64Golden"))))
(DTypeSig false "u64Low30" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "u64Low30" ((PTuple (PVar "a0") (PVar "a1") PWild PWild)) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "bitOr") (EVar "a0")) (EApp (EApp (EVar "shiftLeft") (EVar "a1")) (ELit (LInt 16))))) (ELit (LInt 1073741823))))
(DTypeSig false "u64ToInt" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "u64ToInt" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "bitOr") (EVar "a0")) (EApp (EApp (EVar "shiftLeft") (EVar "a1")) (ELit (LInt 16))))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EVar "a2")) (ELit (LInt 32)))) (EApp (EApp (EVar "shiftLeft") (EVar "a3")) (ELit (LInt 48))))))
(DTypeSig false "u64Bit63" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "u64Bit63" ((PTuple PWild PWild PWild (PVar "a3"))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "a3")) (ELit (LInt 15)))) (ELit (LInt 1))))
(DTypeSig false "u64ToSignedInt" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "u64ToSignedInt" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EBlock (DoLet false false (PVar "hi16") (EIf (EBinOp "==" (EApp (EApp (EVar "bitAnd") (EVar "a3")) (ELit (LInt 32768))) (ELit (LInt 0))) (EVar "a3") (EBinOp "-" (EVar "a3") (ELit (LInt 65536))))) (DoExpr (EBinOp "+" (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "bitOr") (EVar "a0")) (EApp (EApp (EVar "shiftLeft") (EVar "a1")) (ELit (LInt 16))))) (EApp (EApp (EVar "shiftLeft") (EVar "a2")) (ELit (LInt 32)))) (EApp (EApp (EVar "shiftLeft") (EVar "hi16")) (ELit (LInt 48)))))))
(DTypeSig true "rngStateRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "rngStateRef" () (EApp (EVar "Ref") (ELit (LInt 123456789))))
(DTypeSig false "rngU64Ref" (TyApp (TyCon "Ref") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "rngU64Ref" () (EApp (EVar "Ref") (ETuple (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)))))
(DTypeSig false "rngDraw" (TyFun (TyCon "Unit") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "rngDraw" (PWild) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EVar "add64") (EFieldAccess (EVar "rngU64Ref") "value")) (EVar "u64Golden"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "rngU64Ref")) (EVar "s"))) (DoExpr (EApp (EVar "u64Finalize") (EVar "s")))))
(DTypeSig false "pRandomInt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pRandomInt" ((PCon "VInt" (PVar "lo")) (PCon "VInt" (PVar "hi"))) (EBlock (DoLet false false (PVar "loU") (EApp (EVar "ofInt") (EVar "lo"))) (DoLet false false (PVar "rangeU") (EApp (EApp (EVar "add64") (EApp (EApp (EVar "sub64") (EApp (EVar "ofInt") (EVar "hi"))) (EVar "loU"))) (EApp (EVar "ofInt") (ELit (LInt 1))))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isZero") (EVar "rangeU")) (EBinOp "==" (EApp (EVar "u64Bit63") (EVar "rangeU")) (ELit (LInt 1)))) (EApp (EVar "VInt") (EVar "lo")) (EBlock (DoLet false false (PVar "rem") (EApp (EApp (EVar "mod64") (EApp (EVar "rngDraw") (ELit LUnit))) (EVar "rangeU"))) (DoExpr (EApp (EVar "VInt") (EApp (EVar "u64ToSignedInt") (EApp (EApp (EVar "add64") (EVar "loU")) (EVar "rem"))))))))))
(DFunDef false "pRandomInt" (PWild PWild) (EApp (EVar "panic") (ELit (LString "randomInt: expected Int Int"))))
(DTypeSig false "pRandomBool" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pRandomBool" (PWild) (EApp (EVar "VBool") (EBinOp "==" (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "limbAt") (EApp (EVar "rngDraw") (ELit LUnit))) (ELit (LInt 0)))) (ELit (LInt 1))) (ELit (LInt 1)))))
(DTypeSig false "pRandomFloat" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pRandomFloat" (PWild) (EBlock (DoLet false false (PVar "bits") (EApp (EVar "u64ToInt") (EApp (EApp (EVar "shr64") (EApp (EVar "rngDraw") (ELit LUnit))) (ELit (LInt 11))))) (DoExpr (EApp (EVar "VFloat") (EBinOp "-" (EBinOp "*" (EBinOp "*" (EApp (EVar "intToFloat") (EVar "bits")) (EBinOp "/" (ELit (LFloat 1.0)) (EApp (EVar "intToFloat") (ELit (LInt 9007199254740992))))) (ELit (LFloat 2.0))) (ELit (LFloat 1.0)))))))
(DTypeSig false "pRandomChar" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pRandomChar" (PWild) (EApp (EVar "VChar") (EApp (EVar "charToStr") (EApp (EVar "charFromCodeUnsafe") (EBinOp "+" (ELit (LInt 32)) (EApp (EVar "u64ToInt") (EApp (EApp (EVar "mod64") (EApp (EVar "rngDraw") (ELit LUnit))) (EApp (EVar "ofInt") (ELit (LInt 95))))))))))
(DTypeSig false "charFromCodeUnsafe" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "charFromCodeUnsafe" ((PVar "n")) (EMatch (EApp (EVar "charFromCode") (EVar "n")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (ELit (LChar " ")))))
(DTypeSig false "pSetSeed" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pSetSeed" ((PCon "VInt" (PVar "seed"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "rngU64Ref")) (EApp (EVar "ofInt") (EVar "seed")))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pSetSeed" (PWild) (EApp (EVar "panic") (ELit (LString "setSeed: expected Int"))))
(DTypeSig false "pWallTimeSec" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pWallTimeSec" (PWild) (EApp (EVar "VFloat") (ELit (LFloat 1700000000.0))))
(DTypeSig false "pMonotonicSec" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pMonotonicSec" (PWild) (EApp (EVar "VFloat") (ELit (LFloat 1000.0))))
(DTypeSig false "pSleepMs" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pSleepMs" ((PCon "VInt" PWild)) (EVar "VUnit"))
(DFunDef false "pSleepMs" (PWild) (EApp (EVar "panic") (ELit (LString "sleepMs: expected Int"))))
(DTypeSig false "pAllocBytes" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pAllocBytes" (PWild) (EApp (EVar "VFloat") (ELit (LFloat 0.0))))
(DTypeSig false "pFlushStdout" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pFlushStdout" ((PCon "VUnit")) (EVar "VUnit"))
(DFunDef false "pFlushStdout" (PWild) (EApp (EVar "panic") (ELit (LString "flushStdout: expected Unit"))))
(DTypeSig true "externBindings" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "externBindings" (PWild) (EListLit (ETuple (ELit (LString "randomInt")) (EApp (EVar "prim2M") (EVar "pRandomInt"))) (ETuple (ELit (LString "randomBool")) (EApp (EVar "prim1M") (EVar "pRandomBool"))) (ETuple (ELit (LString "randomFloat")) (EApp (EVar "prim1M") (EVar "pRandomFloat"))) (ETuple (ELit (LString "randomChar")) (EApp (EVar "prim1M") (EVar "pRandomChar"))) (ETuple (ELit (LString "setSeed")) (EApp (EVar "prim1M") (EVar "pSetSeed"))) (ETuple (ELit (LString "wallTimeSec")) (EApp (EVar "prim1M") (EVar "pWallTimeSec"))) (ETuple (ELit (LString "monotonicSec")) (EApp (EVar "prim1M") (EVar "pMonotonicSec"))) (ETuple (ELit (LString "sleepMs")) (EApp (EVar "prim1M") (EVar "pSleepMs"))) (ETuple (ELit (LString "allocBytes")) (EApp (EVar "prim1M") (EVar "pAllocBytes"))) (ETuple (ELit (LString "flushStdout")) (EApp (EVar "prim1M") (EVar "pFlushStdout"))) (ETuple (ELit (LString "intToString")) (EApp (EVar "prim1") (EVar "pIntToString"))) (ETuple (ELit (LString "bitAnd")) (EApp (EVar "prim2") (EVar "pBitAnd"))) (ETuple (ELit (LString "bitOr")) (EApp (EVar "prim2") (EVar "pBitOr"))) (ETuple (ELit (LString "bitXor")) (EApp (EVar "prim2") (EVar "pBitXor"))) (ETuple (ELit (LString "shiftLeft")) (EApp (EVar "prim2") (EVar "pShiftLeft"))) (ETuple (ELit (LString "shiftRight")) (EApp (EVar "prim2") (EVar "pShiftRight"))) (ETuple (ELit (LString "bitNot")) (EApp (EVar "prim1") (EVar "pBitNot"))) (ETuple (ELit (LString "intToFloat")) (EApp (EVar "prim1") (EVar "pIntToFloat"))) (ETuple (ELit (LString "floatToInt")) (EApp (EVar "prim1") (EVar "pFloatToInt"))) (ETuple (ELit (LString "floatToString")) (EApp (EVar "prim1") (EVar "pFloatToString"))) (ETuple (ELit (LString "charToStr")) (EApp (EVar "prim1") (EVar "pCharToStr"))) (ETuple (ELit (LString "charCode")) (EApp (EVar "prim1") (EVar "pCharCode"))) (ETuple (ELit (LString "charFromCode")) (EApp (EVar "prim1") (EVar "pCharFromCode"))) (ETuple (ELit (LString "charToUpper")) (EApp (EVar "prim1") (EVar "pCharToUpper"))) (ETuple (ELit (LString "charToLower")) (EApp (EVar "prim1") (EVar "pCharToLower"))) (ETuple (ELit (LString "stringLength")) (EApp (EVar "prim1") (EVar "pStringLength"))) (ETuple (ELit (LString "stringConcat")) (EApp (EVar "prim1") (EVar "pStringConcat"))) (ETuple (ELit (LString "stringToChars")) (EApp (EVar "prim1") (EVar "pStringToChars"))) (ETuple (ELit (LString "stringFromChars")) (EApp (EVar "prim1") (EVar "pStringFromChars"))) (ETuple (ELit (LString "stringToUtf8Bytes")) (EApp (EVar "prim1") (EVar "pStringToUtf8Bytes"))) (ETuple (ELit (LString "stringFromUtf8Bytes")) (EApp (EVar "prim1") (EVar "pStringFromUtf8Bytes"))) (ETuple (ELit (LString "floatRem")) (EApp (EVar "prim2") (EVar "pFloatRem"))) (ETuple (ELit (LString "sqrt")) (EApp (EVar "prim1") (EVar "pSqrt"))) (ETuple (ELit (LString "cbrt")) (EApp (EVar "prim1") (EVar "pCbrt"))) (ETuple (ELit (LString "exp")) (EApp (EVar "prim1") (EVar "pExp"))) (ETuple (ELit (LString "log")) (EApp (EVar "prim1") (EVar "pLog"))) (ETuple (ELit (LString "log2")) (EApp (EVar "prim1") (EVar "pLog2"))) (ETuple (ELit (LString "log10")) (EApp (EVar "prim1") (EVar "pLog10"))) (ETuple (ELit (LString "sin")) (EApp (EVar "prim1") (EVar "pSin"))) (ETuple (ELit (LString "cos")) (EApp (EVar "prim1") (EVar "pCos"))) (ETuple (ELit (LString "tan")) (EApp (EVar "prim1") (EVar "pTan"))) (ETuple (ELit (LString "asin")) (EApp (EVar "prim1") (EVar "pAsin"))) (ETuple (ELit (LString "acos")) (EApp (EVar "prim1") (EVar "pAcos"))) (ETuple (ELit (LString "atan")) (EApp (EVar "prim1") (EVar "pAtan"))) (ETuple (ELit (LString "sinh")) (EApp (EVar "prim1") (EVar "pSinh"))) (ETuple (ELit (LString "cosh")) (EApp (EVar "prim1") (EVar "pCosh"))) (ETuple (ELit (LString "tanh")) (EApp (EVar "prim1") (EVar "pTanh"))) (ETuple (ELit (LString "floor")) (EApp (EVar "prim1") (EVar "pFloor"))) (ETuple (ELit (LString "ceil")) (EApp (EVar "prim1") (EVar "pCeil"))) (ETuple (ELit (LString "round")) (EApp (EVar "prim1") (EVar "pRound"))) (ETuple (ELit (LString "trunc")) (EApp (EVar "prim1") (EVar "pTrunc"))) (ETuple (ELit (LString "pow")) (EApp (EVar "prim2") (EVar "pPow"))) (ETuple (ELit (LString "atan2")) (EApp (EVar "prim2") (EVar "pAtan2"))) (ETuple (ELit (LString "hypot")) (EApp (EVar "prim2") (EVar "pHypot"))) (ETuple (ELit (LString "stringToUpper")) (EApp (EVar "prim1") (EVar "pStringToUpper"))) (ETuple (ELit (LString "stringToLower")) (EApp (EVar "prim1") (EVar "pStringToLower"))) (ETuple (ELit (LString "stringCompare")) (EApp (EVar "prim2") (EVar "pStringCompare"))) (ETuple (ELit (LString "stringIndexOf")) (EApp (EVar "prim2") (EVar "pStringIndexOf"))) (ETuple (ELit (LString "stringSlice")) (EApp (EVar "prim3") (EVar "pStringSlice"))) (ETuple (ELit (LString "arrayLength")) (EApp (EVar "prim1") (EVar "pArrayLength"))) (ETuple (ELit (LString "arrayFromList")) (EApp (EVar "prim1") (EVar "pArrayFromList"))) (ETuple (ELit (LString "arrayGetUnsafe")) (EApp (EVar "prim2") (EVar "pArrayGetUnsafe"))) (ETuple (ELit (LString "arrayMake")) (EApp (EVar "prim2") (EVar "pArrayMake"))) (ETuple (ELit (LString "arrayMakeWith")) (EApp (EVar "prim2M") (EVar "pArrayMakeWith"))) (ETuple (ELit (LString "arrayCopy")) (EApp (EVar "prim1") (EVar "pArrayCopy"))) (ETuple (ELit (LString "arraySetUnsafe")) (EApp (EVar "prim3M") (EVar "pArraySetUnsafe"))) (ETuple (ELit (LString "arrayBlit")) (EApp (EVar "prim5M") (EVar "pArrayBlit"))) (ETuple (ELit (LString "arrayFill")) (EApp (EVar "prim2M") (EVar "pArrayFill"))) (ETuple (ELit (LString "Ref")) (EApp (EVar "prim1") (EVar "pRef"))) (ETuple (ELit (LString "setRef")) (EApp (EVar "prim2M") (EVar "pSetRef"))) (ETuple (ELit (LString "putStr")) (EApp (EVar "prim1M") (EVar "pPutStr"))) (ETuple (ELit (LString "putStrLn")) (EApp (EVar "prim1M") (EVar "pPutStrLn"))) (ETuple (ELit (LString "ePutStr")) (EApp (EVar "prim1M") (EVar "pDiscard"))) (ETuple (ELit (LString "ePutStrLn")) (EApp (EVar "prim1M") (EVar "pDiscard"))) (ETuple (ELit (LString "stashRunStdout")) (EApp (EVar "prim1M") (EVar "pStashRunStdout"))) (ETuple (ELit (LString "enableRunStdoutFlush")) (EApp (EVar "prim1M") (EVar "pEnableRunStdoutFlush"))) (ETuple (ELit (LString "panic")) (EApp (EVar "prim1") (EVar "pPanic"))) (ETuple (ELit (LString "indexError")) (EApp (EVar "prim1") (ELam ((PVar "s")) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-INDEX-OOB"))) (EApp (EVar "unString") (EVar "s")))))) (ETuple (ELit (LString "debugStringLit")) (EApp (EVar "prim1") (EVar "pDebugStringLit"))) (ETuple (ELit (LString "debugCharLit")) (EApp (EVar "prim1") (EVar "pDebugCharLit"))) (ETuple (ELit (LString "stringToFloat")) (EApp (EVar "prim1") (EVar "pStringToFloat"))) (ETuple (ELit (LString "charIsAlpha")) (EApp (EVar "prim1") (EApp (EVar "charPred") (EVar "charIsAlpha")))) (ETuple (ELit (LString "charIsSpace")) (EApp (EVar "prim1") (EApp (EVar "charPred") (EVar "charIsSpace")))) (ETuple (ELit (LString "charIsUpper")) (EApp (EVar "prim1") (EApp (EVar "charPred") (EVar "charIsUpper")))) (ETuple (ELit (LString "charIsLower")) (EApp (EVar "prim1") (EApp (EVar "charPred") (EVar "charIsLower")))) (ETuple (ELit (LString "charIsPunct")) (EApp (EVar "prim1") (EApp (EVar "charPred") (EVar "charIsPunct")))) (ETuple (ELit (LString "intMinBound")) (EApp (EVar "VInt") (EVar "intMinBound"))) (ETuple (ELit (LString "intMaxBound")) (EApp (EVar "VInt") (EVar "intMaxBound"))) (ETuple (ELit (LString "charMinBound")) (EApp (EVar "VChar") (EApp (EVar "charToStr") (EVar "charMinBound")))) (ETuple (ELit (LString "charMaxBound")) (EApp (EVar "VChar") (EApp (EVar "charToStr") (EVar "charMaxBound")))) (ETuple (ELit (LString "pi")) (EApp (EVar "VFloat") (EVar "pi"))) (ETuple (ELit (LString "e")) (EApp (EVar "VFloat") (EVar "e"))) (ETuple (ELit (LString "intBitsToFloat")) (EApp (EVar "prim1") (EVar "pIntBitsToFloat"))) (ETuple (ELit (LString "bytesToFloat64")) (EApp (EVar "prim2") (EVar "pBytesToFloat64"))) (ETuple (ELit (LString "floatToBytes64")) (EApp (EVar "prim1") (EVar "pFloatToBytes64"))) (ETuple (ELit (LString "hashInt")) (EApp (EVar "prim1") (EVar "pHashInt"))) (ETuple (ELit (LString "hashFloat")) (EApp (EVar "prim1") (EVar "pHashFloat"))) (ETuple (ELit (LString "hashString")) (EApp (EVar "prim1") (EVar "pHashString"))) (ETuple (ELit (LString "hashChar")) (EApp (EVar "prim1") (EVar "pHashChar"))) (ETuple (ELit (LString "hashBool")) (EApp (EVar "prim1") (EVar "pHashBool"))) (ETuple (EVar "fallthroughName") (EApp (EVar "prim1") (ELam (PWild) (EVar "VFallthrough"))))))
(DTypeSig false "pDebugStringLit" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pDebugStringLit" ((PCon "VString" (PVar "s"))) (EApp (EVar "VString") (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "pDebugStringLit" (PWild) (EApp (EVar "panic") (ELit (LString "debugStringLit: not a String"))))
(DTypeSig false "pDebugCharLit" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pDebugCharLit" ((PCon "VChar" (PVar "s"))) (EApp (EVar "VString") (EApp (EVar "debugCharLit") (EApp (EVar "unChar") (EApp (EVar "VChar") (EVar "s"))))))
(DFunDef false "pDebugCharLit" (PWild) (EApp (EVar "panic") (ELit (LString "debugCharLit: not a Char"))))
(DTypeSig false "pStringToFloat" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringToFloat" ((PCon "VString" (PVar "s"))) (EApp (EVar "optionToValue") (EApp (EApp (EVar "mapOption") (EVar "VFloat")) (EApp (EVar "stringToFloat") (EVar "s")))))
(DFunDef false "pStringToFloat" (PWild) (EApp (EVar "panic") (ELit (LString "stringToFloat: not a String"))))
(DTypeSig false "charPred" (TyFun (TyFun (TyCon "Char") (TyCon "Bool")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "charPred" ((PVar "f") (PCon "VChar" (PVar "s"))) (EApp (EVar "VBool") (EApp (EVar "f") (EApp (EVar "unChar") (EApp (EVar "VChar") (EVar "s"))))))
(DFunDef false "charPred" (PWild PWild) (EApp (EVar "panic") (ELit (LString "char predicate: not a Char"))))
(DTypeSig false "pIntToString" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pIntToString" ((PCon "VInt" (PVar "n"))) (EApp (EVar "VString") (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "pIntToString" (PWild) (EApp (EVar "panic") (ELit (LString "intToString: not an Int"))))
(DTypeSig false "pBitAnd" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pBitAnd" ((PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EApp (EApp (EVar "bitAnd") (EVar "a")) (EVar "b"))))
(DFunDef false "pBitAnd" (PWild PWild) (EApp (EVar "panic") (ELit (LString "bitAnd: not Ints"))))
(DTypeSig false "pBitOr" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pBitOr" ((PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EApp (EApp (EVar "bitOr") (EVar "a")) (EVar "b"))))
(DFunDef false "pBitOr" (PWild PWild) (EApp (EVar "panic") (ELit (LString "bitOr: not Ints"))))
(DTypeSig false "pBitXor" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pBitXor" ((PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EApp (EApp (EVar "bitXor") (EVar "a")) (EVar "b"))))
(DFunDef false "pBitXor" (PWild PWild) (EApp (EVar "panic") (ELit (LString "bitXor: not Ints"))))
(DTypeSig false "pShiftLeft" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pShiftLeft" ((PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EApp (EApp (EVar "shiftLeft") (EVar "a")) (EVar "b"))))
(DFunDef false "pShiftLeft" (PWild PWild) (EApp (EVar "panic") (ELit (LString "shiftLeft: not Ints"))))
(DTypeSig false "pShiftRight" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pShiftRight" ((PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EApp (EApp (EVar "shiftRight") (EVar "a")) (EVar "b"))))
(DFunDef false "pShiftRight" (PWild PWild) (EApp (EVar "panic") (ELit (LString "shiftRight: not Ints"))))
(DTypeSig false "pBitNot" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pBitNot" ((PCon "VInt" (PVar "a"))) (EApp (EVar "VInt") (EApp (EVar "bitNot") (EVar "a"))))
(DFunDef false "pBitNot" (PWild) (EApp (EVar "panic") (ELit (LString "bitNot: not an Int"))))
(DTypeSig false "pIntToFloat" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pIntToFloat" ((PCon "VInt" (PVar "n"))) (EApp (EVar "VFloat") (EApp (EVar "intToFloat") (EVar "n"))))
(DFunDef false "pIntToFloat" (PWild) (EApp (EVar "panic") (ELit (LString "intToFloat: not an Int"))))
(DTypeSig false "pFloatToInt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pFloatToInt" ((PCon "VFloat" (PVar "f"))) (EApp (EVar "VInt") (EApp (EVar "floatToInt") (EVar "f"))))
(DFunDef false "pFloatToInt" (PWild) (EApp (EVar "panic") (ELit (LString "floatToInt: not a Float"))))
(DTypeSig false "pIntBitsToFloat" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pIntBitsToFloat" ((PCon "VInt" (PVar "n"))) (EApp (EVar "VFloat") (EApp (EVar "intBitsToFloat") (EVar "n"))))
(DFunDef false "pIntBitsToFloat" (PWild) (EApp (EVar "panic") (ELit (LString "intBitsToFloat: not an Int"))))
(DTypeSig false "getByte64" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "getByte64" ((PVar "off") (PVar "arr") (PVar "i")) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "off") (EVar "i"))) (EVar "arr")) (arm (PCon "VInt" (PVar "b")) () (EApp (EApp (EVar "bitAnd") (EVar "b")) (ELit (LInt 255)))) (arm PWild () (EApp (EVar "panic") (ELit (LString "bytesToFloat64: array element not Int"))))))
(DTypeSig false "pBytesToFloat64" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pBytesToFloat64" ((PCon "VArray" (PVar "arr")) (PCon "VInt" (PVar "off"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "off") (ELit (LInt 0))) (EBinOp ">" (EBinOp "+" (EVar "off") (ELit (LInt 8))) (EApp (EVar "arrayLength") (EVar "arr")))) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-INDEX-OOB"))) (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EVar "intToString") (EVar "off"))) (ELit (LString " out of bounds")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "pBytesToFloat64" ((PCon "VArray" (PVar "arr")) (PCon "VInt" (PVar "off"))) (EBlock (DoLet false false (PVar "intArr") (EApp (EApp (EVar "arrayMakeWith") (ELit (LInt 8))) (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "getByte64") (EVar "off")) (EVar "arr")) (EVar "i"))))) (DoExpr (EApp (EVar "VFloat") (EApp (EApp (EVar "bytesToFloat64") (EVar "intArr")) (ELit (LInt 0)))))))
(DFunDef false "pBytesToFloat64" (PWild PWild) (EApp (EVar "panic") (ELit (LString "bytesToFloat64: expected Array Int"))))
(DTypeSig false "pFloatToBytes64" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pFloatToBytes64" ((PCon "VFloat" (PVar "f"))) (EBlock (DoLet false false (PVar "bs") (EApp (EVar "floatToBytes64") (EVar "f"))) (DoExpr (EApp (EVar "VArray") (EApp (EApp (EVar "arrayMakeWith") (ELit (LInt 8))) (ELam ((PVar "i")) (EApp (EVar "VInt") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "bs")))))))))
(DFunDef false "pFloatToBytes64" (PWild) (EApp (EVar "panic") (ELit (LString "floatToBytes64: not a Float"))))
(DTypeSig false "fnvStep64" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "fnvStep64" ((PTuple (PVar "h0") (PVar "h1") (PVar "h2") (PVar "h3")) (PVar "byte")) (EApp (EApp (EVar "mulLow64") (ETuple (EApp (EApp (EVar "bitXor") (EVar "h0")) (EVar "byte")) (EVar "h1") (EVar "h2") (EVar "h3"))) (EVar "u64FnvPrime")))
(DTypeSig false "fnvFold64" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "fnvFold64" ((PList) (PVar "h")) (EVar "h"))
(DFunDef false "fnvFold64" ((PCons (PVar "x") (PVar "xs")) (PVar "h")) (EApp (EApp (EVar "fnvFold64") (EVar "xs")) (EApp (EApp (EVar "fnvStep64") (EVar "h")) (EVar "x"))))
(DTypeSig false "bytesBEToU64" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "bytesBEToU64" ((PVar "bs")) (ETuple (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 7))) (EVar "bs"))) (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 6))) (EVar "bs"))) (ELit (LInt 8)))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 5))) (EVar "bs"))) (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 4))) (EVar "bs"))) (ELit (LInt 8)))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 3))) (EVar "bs"))) (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 2))) (EVar "bs"))) (ELit (LInt 8)))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 1))) (EVar "bs"))) (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "bs"))) (ELit (LInt 8))))))
(DTypeSig false "pHashInt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pHashInt" ((PCon "VInt" (PVar "n"))) (EApp (EVar "VInt") (EApp (EVar "u64Low30") (EApp (EVar "u64Mix") (EApp (EVar "ofInt") (EVar "n"))))))
(DFunDef false "pHashInt" (PWild) (EApp (EVar "panic") (ELit (LString "hashInt: not an Int"))))
(DTypeSig false "pHashChar" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pHashChar" ((PCon "VChar" (PVar "s"))) (EApp (EVar "VInt") (EApp (EVar "u64Low30") (EApp (EVar "u64Mix") (EApp (EVar "ofInt") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s")))))))))
(DFunDef false "pHashChar" (PWild) (EApp (EVar "panic") (ELit (LString "hashChar: not a Char"))))
(DTypeSig false "pHashBool" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pHashBool" ((PCon "VBool" (PVar "b"))) (EApp (EVar "VInt") (EApp (EVar "boolToInt") (EVar "b"))))
(DFunDef false "pHashBool" (PWild) (EApp (EVar "panic") (ELit (LString "hashBool: not a Bool"))))
(DTypeSig false "pHashFloat" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pHashFloat" ((PCon "VFloat" (PVar "f"))) (EApp (EVar "VInt") (EApp (EVar "u64Low30") (EApp (EVar "u64Mix") (EApp (EVar "bytesBEToU64") (EApp (EVar "floatToBytes64") (EVar "f")))))))
(DFunDef false "pHashFloat" (PWild) (EApp (EVar "panic") (ELit (LString "hashFloat: not a Float"))))
(DTypeSig false "pHashString" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pHashString" ((PCon "VString" (PVar "s"))) (EApp (EVar "VInt") (EApp (EVar "u64Low30") (EApp (EApp (EVar "fnvFold64") (EApp (EVar "arrayToListG") (EApp (EVar "stringToUtf8Bytes") (EVar "s")))) (EVar "u64FnvBasis")))))
(DFunDef false "pHashString" (PWild) (EApp (EVar "panic") (ELit (LString "hashString: not a String"))))
(DTypeSig false "pFloatToString" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pFloatToString" ((PCon "VFloat" (PVar "f"))) (EApp (EVar "VString") (EApp (EVar "floatToString") (EVar "f"))))
(DFunDef false "pFloatToString" (PWild) (EApp (EVar "panic") (ELit (LString "floatToString: not a Float"))))
(DTypeSig false "pCharToStr" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCharToStr" ((PCon "VChar" (PVar "s"))) (EApp (EVar "VString") (EVar "s")))
(DFunDef false "pCharToStr" (PWild) (EApp (EVar "panic") (ELit (LString "charToStr: not a Char"))))
(DTypeSig false "pCharCode" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCharCode" ((PCon "VChar" (PVar "s"))) (EApp (EVar "VInt") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s"))))))
(DFunDef false "pCharCode" (PWild) (EApp (EVar "panic") (ELit (LString "charCode: not a Char"))))
(DTypeSig false "pCharFromCode" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCharFromCode" ((PCon "VInt" (PVar "n"))) (EApp (EVar "optionToValue") (EApp (EApp (EVar "mapOption") (EVar "charToVChar")) (EApp (EVar "charFromCode") (EVar "n")))))
(DFunDef false "pCharFromCode" (PWild) (EApp (EVar "panic") (ELit (LString "charFromCode: not an Int"))))
(DTypeSig false "charToVChar" (TyFun (TyCon "Char") (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "charToVChar" ((PVar "c")) (EApp (EVar "VChar") (EApp (EVar "charToStr") (EVar "c"))))
(DTypeSig false "pCharToUpper" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCharToUpper" ((PCon "VChar" (PVar "s"))) (EApp (EVar "VChar") (EApp (EVar "charToStr") (EApp (EVar "charToUpper") (EApp (EVar "unChar") (EApp (EVar "VChar") (EVar "s")))))))
(DFunDef false "pCharToUpper" (PWild) (EApp (EVar "panic") (ELit (LString "charToUpper: not a Char"))))
(DTypeSig false "pCharToLower" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCharToLower" ((PCon "VChar" (PVar "s"))) (EApp (EVar "VChar") (EApp (EVar "charToStr") (EApp (EVar "charToLower") (EApp (EVar "unChar") (EApp (EVar "VChar") (EVar "s")))))))
(DFunDef false "pCharToLower" (PWild) (EApp (EVar "panic") (ELit (LString "charToLower: not a Char"))))
(DTypeSig false "pStringLength" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringLength" ((PCon "VString" (PVar "s"))) (EApp (EVar "VInt") (EApp (EVar "stringLength") (EVar "s"))))
(DFunDef false "pStringLength" (PWild) (EApp (EVar "panic") (ELit (LString "stringLength: not a String"))))
(DTypeSig false "pStringConcat" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringConcat" ((PCon "VList" (PVar "vs"))) (EApp (EVar "VString") (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (EVar "unString")) (EVar "vs")))))
(DFunDef false "pStringConcat" (PWild) (EApp (EVar "panic") (ELit (LString "stringConcat: not a List"))))
(DTypeSig false "pStringToChars" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringToChars" ((PCon "VString" (PVar "s"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "charToVChar")) (EApp (EVar "arrayToListG") (EApp (EVar "stringToChars") (EVar "s")))))))
(DFunDef false "pStringToChars" (PWild) (EApp (EVar "panic") (ELit (LString "stringToChars: not a String"))))
(DTypeSig false "pStringFromChars" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringFromChars" ((PCon "VArray" (PVar "vs"))) (EApp (EVar "VString") (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "unChar")) (EApp (EVar "arrayToListG") (EVar "vs")))))))
(DFunDef false "pStringFromChars" (PWild) (EApp (EVar "panic") (ELit (LString "stringFromChars: not an Array"))))
(DTypeSig false "unInt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Int")))
(DFunDef false "unInt" ((PCon "VInt" (PVar "n"))) (EVar "n"))
(DFunDef false "unInt" (PWild) (EApp (EVar "panic") (ELit (LString "unInt: not an Int"))))
(DTypeSig false "pStringToUtf8Bytes" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringToUtf8Bytes" ((PCon "VString" (PVar "s"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "VInt")) (EApp (EVar "arrayToListG") (EApp (EVar "stringToUtf8Bytes") (EVar "s")))))))
(DFunDef false "pStringToUtf8Bytes" (PWild) (EApp (EVar "panic") (ELit (LString "stringToUtf8Bytes: not a String"))))
(DTypeSig false "pStringFromUtf8Bytes" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringFromUtf8Bytes" ((PCon "VArray" (PVar "vs"))) (EApp (EVar "VString") (EApp (EVar "stringFromUtf8Bytes") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "unInt")) (EApp (EVar "arrayToListG") (EVar "vs")))))))
(DFunDef false "pStringFromUtf8Bytes" (PWild) (EApp (EVar "panic") (ELit (LString "stringFromUtf8Bytes: not an Array"))))
(DTypeSig false "pFloatRem" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pFloatRem" ((PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EApp (EApp (EVar "floatRem") (EVar "a")) (EVar "b"))))
(DFunDef false "pFloatRem" (PWild PWild) (EApp (EVar "panic") (ELit (LString "floatRem: bad operands"))))
(DTypeSig false "pSqrt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pSqrt" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "sqrt") (EVar "a"))))
(DFunDef false "pSqrt" (PWild) (EApp (EVar "panic") (ELit (LString "sqrt: not a Float"))))
(DTypeSig false "pCbrt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCbrt" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "cbrt") (EVar "a"))))
(DFunDef false "pCbrt" (PWild) (EApp (EVar "panic") (ELit (LString "cbrt: not a Float"))))
(DTypeSig false "pExp" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pExp" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "exp") (EVar "a"))))
(DFunDef false "pExp" (PWild) (EApp (EVar "panic") (ELit (LString "exp: not a Float"))))
(DTypeSig false "pLog" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pLog" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "log") (EVar "a"))))
(DFunDef false "pLog" (PWild) (EApp (EVar "panic") (ELit (LString "log: not a Float"))))
(DTypeSig false "pLog2" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pLog2" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "log2") (EVar "a"))))
(DFunDef false "pLog2" (PWild) (EApp (EVar "panic") (ELit (LString "log2: not a Float"))))
(DTypeSig false "pLog10" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pLog10" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "log10") (EVar "a"))))
(DFunDef false "pLog10" (PWild) (EApp (EVar "panic") (ELit (LString "log10: not a Float"))))
(DTypeSig false "pSin" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pSin" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "sin") (EVar "a"))))
(DFunDef false "pSin" (PWild) (EApp (EVar "panic") (ELit (LString "sin: not a Float"))))
(DTypeSig false "pCos" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCos" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "cos") (EVar "a"))))
(DFunDef false "pCos" (PWild) (EApp (EVar "panic") (ELit (LString "cos: not a Float"))))
(DTypeSig false "pTan" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pTan" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "tan") (EVar "a"))))
(DFunDef false "pTan" (PWild) (EApp (EVar "panic") (ELit (LString "tan: not a Float"))))
(DTypeSig false "pAsin" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pAsin" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "asin") (EVar "a"))))
(DFunDef false "pAsin" (PWild) (EApp (EVar "panic") (ELit (LString "asin: not a Float"))))
(DTypeSig false "pAcos" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pAcos" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "acos") (EVar "a"))))
(DFunDef false "pAcos" (PWild) (EApp (EVar "panic") (ELit (LString "acos: not a Float"))))
(DTypeSig false "pAtan" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pAtan" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "atan") (EVar "a"))))
(DFunDef false "pAtan" (PWild) (EApp (EVar "panic") (ELit (LString "atan: not a Float"))))
(DTypeSig false "pSinh" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pSinh" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "sinh") (EVar "a"))))
(DFunDef false "pSinh" (PWild) (EApp (EVar "panic") (ELit (LString "sinh: not a Float"))))
(DTypeSig false "pCosh" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCosh" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "cosh") (EVar "a"))))
(DFunDef false "pCosh" (PWild) (EApp (EVar "panic") (ELit (LString "cosh: not a Float"))))
(DTypeSig false "pTanh" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pTanh" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "tanh") (EVar "a"))))
(DFunDef false "pTanh" (PWild) (EApp (EVar "panic") (ELit (LString "tanh: not a Float"))))
(DTypeSig false "pFloor" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pFloor" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "floor") (EVar "a"))))
(DFunDef false "pFloor" (PWild) (EApp (EVar "panic") (ELit (LString "floor: not a Float"))))
(DTypeSig false "pCeil" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCeil" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "ceil") (EVar "a"))))
(DFunDef false "pCeil" (PWild) (EApp (EVar "panic") (ELit (LString "ceil: not a Float"))))
(DTypeSig false "pRound" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pRound" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "round") (EVar "a"))))
(DFunDef false "pRound" (PWild) (EApp (EVar "panic") (ELit (LString "round: not a Float"))))
(DTypeSig false "pTrunc" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pTrunc" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "trunc") (EVar "a"))))
(DFunDef false "pTrunc" (PWild) (EApp (EVar "panic") (ELit (LString "trunc: not a Float"))))
(DTypeSig false "pPow" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pPow" ((PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EApp (EApp (EVar "pow") (EVar "a")) (EVar "b"))))
(DFunDef false "pPow" (PWild PWild) (EApp (EVar "panic") (ELit (LString "pow: bad operands"))))
(DTypeSig false "pAtan2" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pAtan2" ((PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EApp (EApp (EVar "atan2") (EVar "a")) (EVar "b"))))
(DFunDef false "pAtan2" (PWild PWild) (EApp (EVar "panic") (ELit (LString "atan2: bad operands"))))
(DTypeSig false "pHypot" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pHypot" ((PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EApp (EApp (EVar "hypot") (EVar "a")) (EVar "b"))))
(DFunDef false "pHypot" (PWild PWild) (EApp (EVar "panic") (ELit (LString "hypot: bad operands"))))
(DTypeSig false "pStringToUpper" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringToUpper" ((PCon "VString" (PVar "s"))) (EApp (EVar "VString") (EApp (EVar "stringToUpper") (EVar "s"))))
(DFunDef false "pStringToUpper" (PWild) (EApp (EVar "panic") (ELit (LString "stringToUpper: not a String"))))
(DTypeSig false "pStringToLower" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringToLower" ((PCon "VString" (PVar "s"))) (EApp (EVar "VString") (EApp (EVar "stringToLower") (EVar "s"))))
(DFunDef false "pStringToLower" (PWild) (EApp (EVar "panic") (ELit (LString "stringToLower: not a String"))))
(DTypeSig false "pStringCompare" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pStringCompare" ((PCon "VString" (PVar "a")) (PCon "VString" (PVar "b"))) (EApp (EVar "orderingToValue") (EApp (EApp (EVar "stringCompare") (EVar "a")) (EVar "b"))))
(DFunDef false "pStringCompare" (PWild PWild) (EApp (EVar "panic") (ELit (LString "stringCompare: not Strings"))))
(DTypeSig false "pStringIndexOf" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pStringIndexOf" ((PCon "VString" (PVar "needle")) (PCon "VString" (PVar "hay"))) (EApp (EVar "optionToValue") (EApp (EApp (EVar "mapOption") (EVar "VInt")) (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "hay")))))
(DFunDef false "pStringIndexOf" (PWild PWild) (EApp (EVar "panic") (ELit (LString "stringIndexOf: not Strings"))))
(DTypeSig false "pStringSlice" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "pStringSlice" ((PCon "VInt" (PVar "lo")) (PCon "VInt" (PVar "hi")) (PCon "VString" (PVar "s"))) (EApp (EVar "VString") (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EVar "hi")) (EVar "s"))))
(DFunDef false "pStringSlice" (PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "stringSlice: bad operands"))))
(DTypeSig false "pArrayLength" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pArrayLength" ((PCon "VArray" (PVar "a"))) (EApp (EVar "VInt") (EApp (EVar "arrayLength") (EVar "a"))))
(DFunDef false "pArrayLength" (PWild) (EApp (EVar "panic") (ELit (LString "arrayLength: not an Array"))))
(DTypeSig false "pArrayFromList" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pArrayFromList" ((PCon "VList" (PVar "vs"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EVar "vs"))))
(DFunDef false "pArrayFromList" (PWild) (EApp (EVar "panic") (ELit (LString "arrayFromList: not a List"))))
(DTypeSig false "pArrayGetUnsafe" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pArrayGetUnsafe" ((PCon "VInt" (PVar "i")) (PCon "VArray" (PVar "a"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a")))
(DFunDef false "pArrayGetUnsafe" (PWild PWild) (EApp (EVar "panic") (ELit (LString "arrayGetUnsafe: bad operands"))))
(DTypeSig false "pArrayMake" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pArrayMake" ((PCon "VInt" (PVar "n")) (PVar "v")) (EApp (EVar "VArray") (EApp (EApp (EVar "arrayMake") (EVar "n")) (EVar "v"))))
(DFunDef false "pArrayMake" (PWild PWild) (EApp (EVar "panic") (ELit (LString "arrayMake: bad operands"))))
(DTypeSig false "pArrayMakeWith" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pArrayMakeWith" ((PCon "VInt" (PVar "n")) (PVar "f")) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "buildWith") (EVar "f")) (ELit (LInt 0))) (EVar "n")))))
(DFunDef false "pArrayMakeWith" (PWild PWild) (EApp (EVar "panic") (ELit (LString "arrayMakeWith: bad operands"))))
(DTypeSig false "pArrayCopy" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pArrayCopy" ((PCon "VArray" (PVar "a"))) (EApp (EVar "VArray") (EApp (EVar "arrayCopy") (EVar "a"))))
(DFunDef false "pArrayCopy" (PWild) (EApp (EVar "panic") (ELit (LString "arrayCopy: not an Array"))))
(DTypeSig false "pArraySetUnsafe" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "pArraySetUnsafe" ((PCon "VInt" (PVar "i")) (PVar "v") (PCon "VArray" (PVar "a"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "v")) (EVar "a"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pArraySetUnsafe" (PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "arraySetUnsafe: bad operands"))))
(DTypeSig false "pArrayFill" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pArrayFill" ((PVar "v") (PCon "VArray" (PVar "a"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "arrayFill") (EVar "v")) (EVar "a"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pArrayFill" (PWild PWild) (EApp (EVar "panic") (ELit (LString "arrayFill: not an Array"))))
(DTypeSig false "blitGo" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit"))))))))
(DFunDef false "blitGo" ((PVar "src") (PVar "srcOff") (PVar "dst") (PVar "dstOff") (PVar "len")) (EIf (EBinOp "<=" (EVar "len") (ELit (LInt 0))) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "v") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "srcOff")) (EVar "src"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "dstOff")) (EVar "v")) (EVar "dst"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "blitGo") (EVar "src")) (EBinOp "+" (EVar "srcOff") (ELit (LInt 1)))) (EVar "dst")) (EBinOp "+" (EVar "dstOff") (ELit (LInt 1)))) (EBinOp "-" (EVar "len") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pArrayBlit" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "pArrayBlit" ((PCon "VArray" (PVar "src")) (PCon "VInt" (PVar "srcOff")) (PCon "VArray" (PVar "dst")) (PCon "VInt" (PVar "dstOff")) (PCon "VInt" (PVar "len"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "blitGo") (EVar "src")) (EVar "srcOff")) (EVar "dst")) (EVar "dstOff")) (EVar "len"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pArrayBlit" (PWild PWild PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "arrayBlit: bad operands"))))
(DTypeSig false "buildWith" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "buildWith" ((PVar "f") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EBinOp "::" (EApp (EApp (EVar "apply") (EVar "f")) (EApp (EVar "VInt") (EVar "i"))) (EApp (EApp (EApp (EVar "buildWith") (EVar "f")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig false "mkGroup" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "mkGroup" ((PVar "defs") (PVar "name")) (ETuple (EVar "name") (EApp (EApp (EVar "clausesForName") (EVar "name")) (EVar "defs"))))
(DTypeSig true "installConsts" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "installConsts" (PWild (PList)) (ELit LUnit))
(DFunDef false "installConsts" ((PVar "cells") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EApp (EApp (EVar "findCell") (EVar "cells")) (EVar "n"))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "installConsts") (EVar "cells")) (EVar "rest")))))
(DTypeSig false "installGroups" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))) (TyEffect () (Some "e") (TyCon "Unit"))))))
(DFunDef false "installGroups" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "installGroups" ((PVar "env") (PVar "cells") (PCons (PTuple (PVar "n") (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EApp (EApp (EVar "findCell") (EVar "cells")) (EVar "n"))) (EApp (EApp (EVar "topGroupValue") (EVar "env")) (EVar "clauses")))) (DoExpr (EApp (EApp (EApp (EVar "installGroups") (EVar "env")) (EVar "cells")) (EVar "rest")))))
(DTypeSig true "lookupBinding" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "lookupBinding" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupBinding" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupBinding") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "noMainMsg" (TyCon "String"))
(DFunDef false "noMainMsg" () (ELit (LString "program has no 'main' binding")))
(DTypeSig true "evalMain" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "evalMain" ((PVar "prog")) (EMatch (EApp (EApp (EVar "lookupBinding") (ELit (LString "main"))) (EApp (EApp (EVar "evalOne") (EListLit)) (ETuple (ELit (LString "__main__")) (EVar "prog")))) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "ppValue") (EApp (EVar "force") (EVar "v")))) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-NO-MAIN"))) (EVar "noMainMsg")))))
(DTypeSig true "evalOutputWith" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "evalOutputWith" ((PVar "preludeDecls") (PVar "userDecls")) (EApp (EApp (EVar "evalOneOutput") (EListLit)) (ETuple (ELit (LString "__main__")) (EBinOp "++" (EApp (EApp (EVar "dropShadowed") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (EVar "preludeDecls")) (EVar "userDecls")))))
(DTypeSig true "funNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "funNamesOf" ((PVar "decls")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "decls"))))
(DTypeSig true "dropShadowedExp" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "dropShadowedExp" ((PVar "names") (PVar "decls")) (EApp (EApp (EVar "dropShadowed") (EVar "names")) (EVar "decls")))
(DTypeSig false "dropShadowed" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "dropShadowed" (PWild (PList)) (EListLit))
(DFunDef false "dropShadowed" ((PVar "names") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EApp (EVar "shadowedFun") (EVar "names")) (EVar "d")) (EApp (EApp (EVar "dropShadowed") (EVar "names")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "d") (EApp (EApp (EVar "dropShadowed") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "shadowedFun" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "shadowedFun" ((PVar "names") (PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "names")))
(DFunDef false "shadowedFun" (PWild PWild) (EVar "False"))
(DTypeSig false "runMainForEffect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "runMainForEffect" ((PVar "binds")) (EMatch (EApp (EApp (EVar "lookupBinding") (ELit (LString "main"))) (EVar "binds")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "force") (EVar "v"))) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-NO-MAIN"))) (EVar "noMainMsg")))))
(DData Private "ModInfo" ("v") ((variant "ModInfo" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyVar "v")))) (TyApp (TyCon "EvalEnv") (TyVar "v"))))) ())
(DTypeSig true "evalModules" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalModules" ((PVar "preludeDecls") (PVar "modules")) (EApp (EApp (EApp (EVar "evalModulesWith") (EListLit)) (EVar "preludeDecls")) (EVar "modules")))
(DTypeSig true "evalModulesWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "evalModulesWith" ((PVar "extraExterns") (PVar "preludeDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "externs") (EBinOp "++" (EApp (EVar "externBindings") (ELit LUnit)) (EVar "extraExterns"))) (DoLet false false (PVar "moduleDecls") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modules"))) (DoLet false false (PVar "allDecls") (EBinOp "++" (EVar "preludeDecls") (EVar "moduleDecls"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "ctorToTypeRef")) (EApp (EVar "buildCtorToType") (EVar "allDecls")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "methodReqCountRef")) (EApp (EVar "buildMethodReqCounts") (EVar "allDecls")))) (DoLet false false (PVar "disp") (EApp (EVar "buildIfaceDispatch") (EVar "allDecls"))) (DoLet false false (PVar "ctors") (EApp (EVar "collectCtors") (EVar "allDecls"))) (DoLet false false (PVar "preludeGroups") (EApp (EVar "groupsOf") (EVar "preludeDecls"))) (DoLet false false (PVar "globalNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "boolSeeds")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "externs"))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "ctors"))) (EApp (EVar "implMethodNames") (EVar "allDecls"))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "preludeGroups")))) (DoLet false false (PVar "globalCells") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "Ref") (EVar "VUnit"))))) (EVar "globalNames"))) (DoLet false false (PVar "globalEnv") (EApp (EVar "EvalEnv") (EListLit (EVar "globalCells")))) (DoLet false false (PVar "mods") (EApp (EApp (EApp (EVar "buildModInfos") (EVar "globalCells")) (EListLit)) (EVar "modules"))) (DoLet false false (PVar "implEntries") (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "declImplEntries") (EVar "globalEnv")) (EVar "disp"))) (EVar "preludeDecls")) (EApp (EApp (EVar "flatMap") (EApp (EVar "modImplEntries") (EVar "disp"))) (EVar "mods")))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "boolSeeds"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "externs"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "ctors"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EApp (EVar "coalesceImpls") (EVar "implEntries")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "installGroups") (EVar "globalEnv")) (EVar "globalCells")) (EVar "preludeGroups"))) (DoLet false false PWild (EApp (EVar "installModGroups") (EVar "mods"))) (DoExpr (EApp (EVar "rootLocals") (EVar "mods")))))
(DTypeSig false "buildModInfos" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyApp (TyCon "ModInfo") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "buildModInfos" (PWild PWild (PList)) (EListLit))
(DFunDef false "buildModInfos" ((PVar "globalCells") (PVar "exportsMap") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EBlock (DoLet false false (PVar "grps") (EApp (EVar "groupsOf") (EVar "decls"))) (DoLet false false (PVar "modCtors") (EApp (EVar "collectCtors") (EVar "decls"))) (DoLet false false (PVar "localCells") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "Ref") (EVar "VUnit"))))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "grps")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "modCtors"))))) (DoLet false false (PVar "imports") (EApp (EApp (EVar "importFrameOf") (EVar "exportsMap")) (EVar "decls"))) (DoLet false false (PVar "menv") (EApp (EVar "EvalEnv") (EListLit (EVar "localCells") (EVar "imports") (EVar "globalCells")))) (DoLet false false (PVar "exports") (EBinOp "++" (EBinOp "++" (EVar "localCells") (EApp (EApp (EVar "methodCellsOf") (EVar "globalCells")) (EVar "decls"))) (EApp (EApp (EApp (EVar "pubReexports") (EVar "globalCells")) (EVar "exportsMap")) (EVar "decls")))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "ModInfo") (EVar "mid")) (EVar "decls")) (EVar "grps")) (EVar "localCells")) (EVar "menv")) (EApp (EApp (EApp (EVar "buildModInfos") (EVar "globalCells")) (EBinOp "::" (ETuple (EVar "mid") (EVar "exports")) (EVar "exportsMap"))) (EVar "rest"))))))
(DTypeSig true "methodCellsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "methodCellsOf" ((PVar "globalCells") (PVar "decls")) (EApp (EApp (EVar "flatMap") (EApp (EVar "methodCell") (EVar "globalCells"))) (EApp (EVar "moduleMethodNames") (EVar "decls"))))
(DTypeSig false "methodCell" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "methodCell" ((PVar "globalCells") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "globalCells")) (arm (PCon "Some" (PVar "cell")) () (EListLit (ETuple (EVar "n") (EVar "cell")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "moduleMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleMethodNames" ((PVar "decls")) (EApp (EVar "dedup") (EApp (EApp (EVar "flatMap") (EVar "moduleMethodNamesOf")) (EVar "decls"))))
(DTypeSig false "moduleMethodNamesOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleMethodNamesOf" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "map") (EVar "implMethodName")) (EVar "methods")))
(DFunDef false "moduleMethodNamesOf" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EVar "map") (EVar "ifaceMethodNmE")) (EVar "methods")))
(DFunDef false "moduleMethodNamesOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "moduleMethodNamesOf") (EVar "d")))
(DFunDef false "moduleMethodNamesOf" (PWild) (EListLit))
(DTypeSig false "ifaceMethodNmE" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodNmE" ((PCon "IfaceMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "installModGroups" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "ModInfo") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyCon "Unit"))))
(DFunDef false "installModGroups" ((PList)) (ELit LUnit))
(DFunDef false "installModGroups" ((PCons (PCon "ModInfo" PWild (PVar "decls") (PVar "grps") (PVar "cells") (PVar "menv")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "installGroups") (EVar "menv")) (EVar "cells")) (EVar "grps"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "cells")) (EApp (EVar "collectCtors") (EVar "decls")))) (DoExpr (EApp (EVar "installModGroups") (EVar "rest")))))
(DTypeSig false "modImplEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "ModInfo") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "modImplEntries" ((PVar "disp") (PCon "ModInfo" PWild (PVar "decls") PWild PWild (PVar "menv"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "declImplEntries") (EVar "menv")) (EVar "disp"))) (EVar "decls")))
(DTypeSig false "rootLocals" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "ModInfo") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "rootLocals" ((PList)) (EListLit))
(DFunDef false "rootLocals" ((PList (PCon "ModInfo" PWild PWild PWild (PVar "cells") PWild))) (EApp (EApp (EVar "map") (EVar "cellResult")) (EVar "cells")))
(DFunDef false "rootLocals" ((PCons PWild (PVar "rest"))) (EApp (EVar "rootLocals") (EVar "rest")))
(DTypeSig true "evalModulesRootEnv" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalModulesRootEnv" ((PVar "preludeDecls") (PVar "modules")) (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EListLit)) (EVar "preludeDecls")) (EVar "modules")))
(DTypeSig true "evalModulesRootEnvWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "evalModulesRootEnvWith" ((PVar "extraExterns") (PVar "preludeDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "externs") (EBinOp "++" (EApp (EVar "externBindings") (ELit LUnit)) (EVar "extraExterns"))) (DoLet false false (PVar "moduleDecls") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "modules"))) (DoLet false false (PVar "allDecls") (EBinOp "++" (EVar "preludeDecls") (EVar "moduleDecls"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "ctorToTypeRef")) (EApp (EVar "buildCtorToType") (EVar "allDecls")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "methodReqCountRef")) (EApp (EVar "buildMethodReqCounts") (EVar "allDecls")))) (DoLet false false (PVar "disp") (EApp (EVar "buildIfaceDispatch") (EVar "allDecls"))) (DoLet false false (PVar "ctors") (EApp (EVar "collectCtors") (EVar "allDecls"))) (DoLet false false (PVar "preludeGroups") (EApp (EVar "groupsOf") (EVar "preludeDecls"))) (DoLet false false (PVar "globalNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "boolSeeds")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "externs"))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "ctors"))) (EApp (EVar "implMethodNames") (EVar "allDecls"))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "preludeGroups")))) (DoLet false false (PVar "globalCells") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "Ref") (EVar "VUnit"))))) (EVar "globalNames"))) (DoLet false false (PVar "globalEnv") (EApp (EVar "EvalEnv") (EListLit (EVar "globalCells")))) (DoLet false false (PVar "mods") (EApp (EApp (EApp (EVar "buildModInfos") (EVar "globalCells")) (EListLit)) (EVar "modules"))) (DoLet false false (PVar "implEntries") (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "declImplEntries") (EVar "globalEnv")) (EVar "disp"))) (EVar "preludeDecls")) (EApp (EApp (EVar "flatMap") (EApp (EVar "modImplEntries") (EVar "disp"))) (EVar "mods")))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "boolSeeds"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "externs"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "ctors"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EApp (EVar "coalesceImpls") (EVar "implEntries")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "installGroups") (EVar "globalEnv")) (EVar "globalCells")) (EVar "preludeGroups"))) (DoLet false false PWild (EApp (EVar "installModGroups") (EVar "mods"))) (DoExpr (EApp (EApp (EVar "rootFullEnv") (EVar "mods")) (EVar "globalCells")))))
(DTypeSig false "rootFullEnv" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "ModInfo") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "rootFullEnv" ((PList) (PVar "globalCells")) (EApp (EApp (EVar "map") (EVar "cellResult")) (EVar "globalCells")))
(DFunDef false "rootFullEnv" ((PList (PCon "ModInfo" PWild PWild PWild (PVar "cells") (PVar "menv"))) (PVar "globalCells")) (EApp (EVar "flattenEnv") (EVar "menv")))
(DFunDef false "rootFullEnv" ((PCons PWild (PVar "rest")) (PVar "globalCells")) (EApp (EApp (EVar "rootFullEnv") (EVar "rest")) (EVar "globalCells")))
(DTypeSig false "flattenEnv" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "flattenEnv" ((PCon "EvalEnv" (PVar "frames"))) (EApp (EApp (EVar "map") (EVar "cellResult")) (EApp (EVar "concatList") (EVar "frames"))))
(DTypeSig false "concatList" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "concatList" ((PList)) (EListLit))
(DFunDef false "concatList" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EVar "x") (EApp (EVar "concatList") (EVar "xs"))))
(DTypeSig false "groupsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "groupsOf" ((PVar "decls")) (EBlock (DoLet false false (PVar "defs") (EApp (EVar "funDefs") (EVar "decls"))) (DoExpr (EApp (EApp (EVar "map") (EApp (EVar "mkGroup") (EVar "defs"))) (EApp (EApp (EVar "funGroupNames") (EVar "defs")) (EListLit))))))
(DTypeSig true "importFrameOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "importFrameOf" ((PVar "exportsMap") (PVar "decls")) (EApp (EApp (EVar "flatMap") (EApp (EVar "useImports") (EVar "exportsMap"))) (EVar "decls")))
(DTypeSig false "useImports" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "useImports" ((PVar "exportsMap") (PCon "DUse" PWild (PVar "path") PWild)) (EMatch (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "useModuleId") (EVar "path"))) (EVar "exportsMap")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exports")) () (EApp (EApp (EVar "resolveMembers") (EVar "path")) (EVar "exports")))))
(DFunDef false "useImports" (PWild PWild) (EListLit))
(DTypeSig true "pubReexports" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "pubReexports" ((PVar "globalCells") (PVar "exportsMap") (PVar "decls")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "reexport") (EVar "globalCells")) (EVar "exportsMap"))) (EVar "decls")))
(DTypeSig false "reexport" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "reexport" ((PVar "globalCells") (PVar "exportsMap") (PCon "DUse" (PCon "True") (PVar "path") PWild)) (EBlock (DoLet false false (PVar "src") (EIf (EBinOp "==" (EApp (EVar "useModuleId") (EVar "path")) (ELit (LString "core"))) (EApp (EVar "Some") (EVar "globalCells")) (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "useModuleId") (EVar "path"))) (EVar "exportsMap")))) (DoExpr (EMatch (EVar "src") (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exports")) () (EApp (EApp (EVar "resolveMembers") (EVar "path")) (EVar "exports")))))))
(DFunDef false "reexport" (PWild PWild PWild) (EListLit))
(DTypeSig false "resolveMembers" (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "resolveMembers" ((PCon "UseName" (PVar "ns")) (PVar "exports")) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EApp (EVar "bindNames") (EListLit (EApp (EVar "selfBind") (EApp (EVar "lastOfList") (EVar "ns"))))) (EVar "exports")) (EListLit)))
(DFunDef false "resolveMembers" ((PCon "UseGroup" PWild (PVar "ms")) (PVar "exports")) (EApp (EApp (EVar "bindNames") (EApp (EApp (EVar "map") (EVar "memberBind")) (EVar "ms"))) (EVar "exports")))
(DFunDef false "resolveMembers" ((PCon "UseWild" PWild) (PVar "exports")) (EVar "exports"))
(DFunDef false "resolveMembers" ((PCon "UseAlias" PWild (PVar "a")) (PVar "exports")) (EApp (EApp (EVar "map") (EApp (EVar "qualifyCell") (EVar "a"))) (EVar "exports")))
(DTypeSig false "qualifyCell" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))) (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "qualifyCell" ((PVar "a") (PTuple (PVar "n") (PVar "cell"))) (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "n")) (EVar "cell")))
(DTypeSig false "bindNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "bindNames" ((PList) PWild) (EListLit))
(DFunDef false "bindNames" ((PCons (PTuple (PVar "origin") (PVar "local")) (PVar "rest")) (PVar "exports")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "origin")) (EVar "exports")) (arm (PCon "Some" (PVar "cell")) () (EBinOp "::" (ETuple (EVar "local") (EVar "cell")) (EApp (EApp (EVar "bindNames") (EVar "rest")) (EVar "exports")))) (arm (PCon "None") () (EApp (EApp (EVar "bindNames") (EVar "rest")) (EVar "exports")))))
(DTypeSig false "memberBind" (TyFun (TyCon "UseMember") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "memberBind" ((PVar "m")) (ETuple (EApp (EVar "useMemberOrigin") (EVar "m")) (EApp (EVar "useMemberLocal") (EVar "m"))))
(DTypeSig false "selfBind" (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "selfBind" ((PVar "n")) (ETuple (EVar "n") (EVar "n")))
(DTypeSig false "useModuleId" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useModuleId" ((PCon "UseName" (PVar "ns"))) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EVar "joinDot") (EApp (EVar "initList") (EVar "ns"))) (EApp (EVar "firstOrEmpty") (EVar "ns"))))
(DFunDef false "useModuleId" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModuleId" ((PCon "UseWild" (PVar "ns"))) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModuleId" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DTypeSig false "lastOfList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastOfList" ((PList)) (ELit (LString "")))
(DFunDef false "lastOfList" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOfList" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastOfList") (EVar "rest")))
(DTypeSig false "firstOrEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "firstOrEmpty" ((PList)) (ELit (LString "")))
(DFunDef false "firstOrEmpty" ((PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig true "evalModulesOutput" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))
(DFunDef false "evalModulesOutput" ((PVar "preludeDecls") (PVar "modules")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false (PVar "binds") (EApp (EApp (EVar "evalModules") (EVar "preludeDecls")) (EVar "modules"))) (DoLet false false PWild (EApp (EVar "runMainForEffect") (EVar "binds"))) (DoExpr (EFieldAccess (EVar "outputRef") "value"))))
(DTypeSig false "pReadFile" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileRead")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pReadFile" ((PCon "VString" (PVar "path"))) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Ok" (PVar "s")) () (EApp (EApp (EVar "VCon") (ELit (LString "Ok"))) (EListLit (EApp (EVar "VString") (EVar "s"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EApp (EVar "VCon") (ELit (LString "Err"))) (EListLit (EApp (EVar "VString") (EVar "m")))))))
(DFunDef false "pReadFile" (PWild) (EApp (EVar "panic") (ELit (LString "readFile: not a String"))))
(DTypeSig false "resultToValue" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "resultToValue" ((PCon "Ok" (PVar "v"))) (EApp (EApp (EVar "VCon") (ELit (LString "Ok"))) (EListLit (EVar "v"))))
(DFunDef false "resultToValue" ((PCon "Err" (PVar "m"))) (EApp (EApp (EVar "VCon") (ELit (LString "Err"))) (EListLit (EApp (EVar "VString") (EVar "m")))))
(DTypeSig false "unitResultToValue" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "unitResultToValue" ((PVar "r")) (EApp (EVar "resultToValue") (EApp (EApp (EVar "mapResultOk") (ELam (PWild) (EVar "VUnit"))) (EVar "r"))))
(DTypeSig false "mapResultOk" (TyFun (TyFun (TyVar "a") (TyVar "b")) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "b")))))
(DFunDef false "mapResultOk" ((PVar "f") (PCon "Ok" (PVar "v"))) (EApp (EVar "Ok") (EApp (EVar "f") (EVar "v"))))
(DFunDef false "mapResultOk" (PWild (PCon "Err" (PVar "m"))) (EApp (EVar "Err") (EVar "m")))
(DTypeSig false "vStringList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "vStringList" ((PVar "xs")) (EApp (EVar "VList") (EApp (EApp (EVar "map") (EVar "VString")) (EVar "xs"))))
(DTypeSig false "vIntArray" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "vIntArray" ((PVar "bs")) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "VInt")) (EApp (EVar "arrayToListG") (EVar "bs"))))))
(DTypeSig false "unIntArray" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "unIntArray" ((PCon "VArray" (PVar "vs"))) (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "unInt")) (EApp (EVar "arrayToListG") (EVar "vs")))))
(DFunDef false "unIntArray" (PWild) (EApp (EVar "panic") (ELit (LString "expected an Array of Int"))))
(DTypeSig false "vOptionString" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "vOptionString" ((PVar "o")) (EApp (EVar "optionToValue") (EApp (EApp (EVar "mapOption") (EVar "VString")) (EVar "o"))))
(DTypeSig false "pWallTimeSecIO" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Clock") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pWallTimeSecIO" (PWild) (EApp (EVar "VFloat") (EApp (EVar "wallTimeSec") (ELit LUnit))))
(DTypeSig false "pMonotonicSecIO" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Clock") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pMonotonicSecIO" (PWild) (EApp (EVar "VFloat") (EApp (EVar "monotonicSec") (ELit LUnit))))
(DTypeSig false "pSleepMsIO" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Clock") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pSleepMsIO" ((PCon "VInt" (PVar "n"))) (EBlock (DoLet false false PWild (EApp (EVar "sleepMs") (EVar "n"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pSleepMsIO" (PWild) (EApp (EVar "panic") (ELit (LString "sleepMs: expected Int"))))
(DTypeSig false "pExit" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pExit" ((PCon "VInt" (PVar "n"))) (EBlock (DoLet false false PWild (EApp (EVar "exit") (EVar "n"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pExit" (PWild) (EApp (EVar "panic") (ELit (LString "exit: not an Int"))))
(DTypeSig false "pAllocBytesIO" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("IO") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pAllocBytesIO" (PWild) (EApp (EVar "VFloat") (EApp (EVar "allocBytes") (ELit LUnit))))
(DTypeSig false "pEPutStr" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Stderr") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pEPutStr" ((PCon "VString" (PVar "s"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStr") (EVar "s"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pEPutStr" (PWild) (EApp (EVar "panic") (ELit (LString "ePutStr: not a String"))))
(DTypeSig false "pEPutStrLn" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Stderr") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pEPutStrLn" ((PCon "VString" (PVar "s"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "s"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pEPutStrLn" (PWild) (EApp (EVar "panic") (ELit (LString "ePutStrLn: not a String"))))
(DTypeSig false "pReadFileBytes" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileRead")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pReadFileBytes" ((PCon "VString" (PVar "path"))) (EApp (EVar "resultToValue") (EApp (EApp (EVar "mapResultOk") (EVar "vIntArray")) (EApp (EVar "readFileBytes") (EVar "path")))))
(DFunDef false "pReadFileBytes" (PWild) (EApp (EVar "panic") (ELit (LString "readFileBytes: not a String"))))
(DTypeSig false "pFileExists" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileRead")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pFileExists" ((PCon "VString" (PVar "path"))) (EApp (EVar "VBool") (EApp (EVar "fileExists") (EVar "path"))))
(DFunDef false "pFileExists" (PWild) (EApp (EVar "panic") (ELit (LString "fileExists: not a String"))))
(DTypeSig false "pCanonicalizePath" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileRead")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCanonicalizePath" ((PCon "VString" (PVar "path"))) (EApp (EVar "VString") (EApp (EVar "canonicalizePath") (EVar "path"))))
(DFunDef false "pCanonicalizePath" (PWild) (EApp (EVar "panic") (ELit (LString "canonicalizePath: not a String"))))
(DTypeSig false "pListDir" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileRead")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pListDir" ((PCon "VString" (PVar "path"))) (EApp (EVar "resultToValue") (EApp (EApp (EVar "mapResultOk") (EVar "vStringList")) (EApp (EVar "listDir") (EVar "path")))))
(DFunDef false "pListDir" (PWild) (EApp (EVar "panic") (ELit (LString "listDir: not a String"))))
(DTypeSig false "pStatFile" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileRead")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStatFile" ((PCon "VString" (PVar "path"))) (EApp (EVar "resultToValue") (EApp (EApp (EVar "mapResultOk") (EVar "statTuple")) (EApp (EVar "statFile") (EVar "path")))))
(DFunDef false "pStatFile" (PWild) (EApp (EVar "panic") (ELit (LString "statFile: not a String"))))
(DTypeSig false "statTuple" (TyFun (TyTuple (TyCon "Int") (TyCon "Bool") (TyCon "Bool") (TyCon "Float")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "statTuple" ((PTuple (PVar "sz") (PVar "isDir") (PVar "isFile") (PVar "mtime"))) (EApp (EVar "VTuple") (EListLit (EApp (EVar "VInt") (EVar "sz")) (EApp (EVar "VBool") (EVar "isDir")) (EApp (EVar "VBool") (EVar "isFile")) (EApp (EVar "VFloat") (EVar "mtime")))))
(DTypeSig false "pWriteFile" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileWrite")) (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pWriteFile" ((PCon "VString" (PVar "path")) (PCon "VString" (PVar "s"))) (EApp (EVar "unitResultToValue") (EApp (EApp (EVar "writeFile") (EVar "path")) (EVar "s"))))
(DFunDef false "pWriteFile" (PWild PWild) (EApp (EVar "panic") (ELit (LString "writeFile: expected String String"))))
(DTypeSig false "pWriteFileBytes" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileWrite")) (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pWriteFileBytes" ((PCon "VString" (PVar "path")) (PVar "bs")) (EApp (EVar "unitResultToValue") (EApp (EApp (EVar "writeFileBytes") (EVar "path")) (EApp (EVar "unIntArray") (EVar "bs")))))
(DFunDef false "pWriteFileBytes" (PWild PWild) (EApp (EVar "panic") (ELit (LString "writeFileBytes: expected String (Array Int)"))))
(DTypeSig false "pAppendFile" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileWrite")) (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pAppendFile" ((PCon "VString" (PVar "path")) (PCon "VString" (PVar "s"))) (EApp (EVar "unitResultToValue") (EApp (EApp (EVar "appendFile") (EVar "path")) (EVar "s"))))
(DFunDef false "pAppendFile" (PWild PWild) (EApp (EVar "panic") (ELit (LString "appendFile: expected String String"))))
(DTypeSig false "pMakeDir" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileWrite")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pMakeDir" ((PCon "VString" (PVar "path"))) (EApp (EVar "unitResultToValue") (EApp (EVar "makeDir") (EVar "path"))))
(DFunDef false "pMakeDir" (PWild) (EApp (EVar "panic") (ELit (LString "makeDir: not a String"))))
(DTypeSig false "pRemoveFile" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileWrite")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pRemoveFile" ((PCon "VString" (PVar "path"))) (EApp (EVar "unitResultToValue") (EApp (EVar "removeFile") (EVar "path"))))
(DFunDef false "pRemoveFile" (PWild) (EApp (EVar "panic") (ELit (LString "removeFile: not a String"))))
(DTypeSig false "pRemoveDir" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileWrite")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pRemoveDir" ((PCon "VString" (PVar "path"))) (EApp (EVar "unitResultToValue") (EApp (EVar "removeDir") (EVar "path"))))
(DFunDef false "pRemoveDir" (PWild) (EApp (EVar "panic") (ELit (LString "removeDir: not a String"))))
(DTypeSig false "pRename" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileWrite")) (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pRename" ((PCon "VString" (PVar "old")) (PCon "VString" (PVar "new"))) (EApp (EVar "unitResultToValue") (EApp (EApp (EVar "rename") (EVar "old")) (EVar "new"))))
(DFunDef false "pRename" (PWild PWild) (EApp (EVar "panic") (ELit (LString "rename: expected String String"))))
(DTypeSig true "progArgsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "progArgsRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "pArgs" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Env") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pArgs" (PWild) (EApp (EVar "vStringList") (EFieldAccess (EVar "progArgsRef") "value")))
(DTypeSig false "pGetEnv" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "Env")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pGetEnv" ((PCon "VString" (PVar "name"))) (EApp (EVar "vOptionString") (EApp (EVar "getEnv") (EVar "name"))))
(DFunDef false "pGetEnv" (PWild) (EApp (EVar "panic") (ELit (LString "getEnv: not a String"))))
(DTypeSig false "pExecutablePath" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Env") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pExecutablePath" (PWild) (EApp (EVar "VString") (EApp (EVar "executablePath") (ELit LUnit))))
(DTypeSig false "pBuildFingerprint" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Env") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pBuildFingerprint" (PWild) (EApp (EVar "VString") (EApp (EVar "buildFingerprint") (ELit LUnit))))
(DTypeSig false "pReadLine" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Stdin") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pReadLine" (PWild) (EApp (EVar "VString") (EApp (EVar "readLine") (ELit LUnit))))
(DTypeSig false "pReadLineOpt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Stdin") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pReadLineOpt" (PWild) (EApp (EVar "vOptionString") (EApp (EVar "readLineOpt") (ELit LUnit))))
(DTypeSig false "pReadAll" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Stdin") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pReadAll" (PWild) (EApp (EVar "VString") (EApp (EVar "readAll") (ELit LUnit))))
(DTypeSig false "pReadExactly" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Stdin") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pReadExactly" ((PCon "VInt" (PVar "n"))) (EApp (EVar "vOptionString") (EApp (EVar "readExactly") (EVar "n"))))
(DFunDef false "pReadExactly" (PWild) (EApp (EVar "panic") (ELit (LString "readExactly: expected Int"))))
(DTypeSig true "ioExternBindings" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "ioExternBindings" (PWild) (EListLit (ETuple (ELit (LString "wallTimeSec")) (EApp (EVar "prim1M") (EVar "pWallTimeSecIO"))) (ETuple (ELit (LString "monotonicSec")) (EApp (EVar "prim1M") (EVar "pMonotonicSecIO"))) (ETuple (ELit (LString "sleepMs")) (EApp (EVar "prim1M") (EVar "pSleepMsIO"))) (ETuple (ELit (LString "allocBytes")) (EApp (EVar "prim1M") (EVar "pAllocBytesIO"))) (ETuple (ELit (LString "ePutStr")) (EApp (EVar "prim1M") (EVar "pEPutStr"))) (ETuple (ELit (LString "ePutStrLn")) (EApp (EVar "prim1M") (EVar "pEPutStrLn"))) (ETuple (ELit (LString "readFile")) (EApp (EVar "prim1") (EVar "pReadFile"))) (ETuple (ELit (LString "readFileBytes")) (EApp (EVar "prim1") (EVar "pReadFileBytes"))) (ETuple (ELit (LString "fileExists")) (EApp (EVar "prim1") (EVar "pFileExists"))) (ETuple (ELit (LString "canonicalizePath")) (EApp (EVar "prim1") (EVar "pCanonicalizePath"))) (ETuple (ELit (LString "listDir")) (EApp (EVar "prim1") (EVar "pListDir"))) (ETuple (ELit (LString "statFile")) (EApp (EVar "prim1") (EVar "pStatFile"))) (ETuple (ELit (LString "writeFile")) (EApp (EVar "prim2M") (EVar "pWriteFile"))) (ETuple (ELit (LString "writeFileBytes")) (EApp (EVar "prim2M") (EVar "pWriteFileBytes"))) (ETuple (ELit (LString "appendFile")) (EApp (EVar "prim2M") (EVar "pAppendFile"))) (ETuple (ELit (LString "makeDir")) (EApp (EVar "prim1") (EVar "pMakeDir"))) (ETuple (ELit (LString "removeFile")) (EApp (EVar "prim1") (EVar "pRemoveFile"))) (ETuple (ELit (LString "removeDir")) (EApp (EVar "prim1") (EVar "pRemoveDir"))) (ETuple (ELit (LString "rename")) (EApp (EVar "prim2M") (EVar "pRename"))) (ETuple (ELit (LString "args")) (EApp (EVar "prim1M") (EVar "pArgs"))) (ETuple (ELit (LString "getEnv")) (EApp (EVar "prim1") (EVar "pGetEnv"))) (ETuple (ELit (LString "executablePath")) (EApp (EVar "prim1M") (EVar "pExecutablePath"))) (ETuple (ELit (LString "buildFingerprint")) (EApp (EVar "prim1M") (EVar "pBuildFingerprint"))) (ETuple (ELit (LString "readLine")) (EApp (EVar "prim1M") (EVar "pReadLine"))) (ETuple (ELit (LString "readLineOpt")) (EApp (EVar "prim1M") (EVar "pReadLineOpt"))) (ETuple (ELit (LString "readAll")) (EApp (EVar "prim1M") (EVar "pReadAll"))) (ETuple (ELit (LString "readExactly")) (EApp (EVar "prim1") (EVar "pReadExactly"))) (ETuple (ELit (LString "exit")) (EApp (EVar "prim1") (EVar "pExit")))))
(DTypeSig true "testCapableExterns" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "testCapableExterns" (PWild) (EListLit (ETuple (ELit (LString "wallTimeSec")) (EApp (EVar "prim1M") (EVar "pWallTimeSecIO"))) (ETuple (ELit (LString "monotonicSec")) (EApp (EVar "prim1M") (EVar "pMonotonicSecIO"))) (ETuple (ELit (LString "allocBytes")) (EApp (EVar "prim1M") (EVar "pAllocBytesIO"))) (ETuple (ELit (LString "ePutStr")) (EApp (EVar "prim1M") (EVar "pEPutStr"))) (ETuple (ELit (LString "ePutStrLn")) (EApp (EVar "prim1M") (EVar "pEPutStrLn")))))
(DTypeSig true "evalModulesOutputRun" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "evalModulesOutputRun" ((PVar "preludeDecls") (PVar "modules")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "enableRunStdoutFlush") (ELit LUnit))) (DoLet false false (PVar "binds") (EApp (EApp (EApp (EVar "evalModulesWith") (EApp (EVar "ioExternBindings") (ELit LUnit))) (EVar "preludeDecls")) (EVar "modules"))) (DoLet false false PWild (EApp (EVar "runMainForEffect") (EVar "binds"))) (DoExpr (EFieldAccess (EVar "outputRef") "value"))))
(DTypeSig true "evalModulesOutputAsync" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyCon "String")))))
(DFunDef false "evalModulesOutputAsync" ((PVar "preludeDecls") (PVar "modules")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "enableRunStdoutFlush") (ELit LUnit))) (DoLet false false (PVar "binds") (EApp (EApp (EVar "evalModulesRootEnv") (EVar "preludeDecls")) (EVar "modules"))) (DoLet false false PWild (EApp (EVar "driveAsyncMain") (EVar "binds"))) (DoExpr (EFieldAccess (EVar "outputRef") "value"))))
(DTypeSig false "driveAsyncMain" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "driveAsyncMain" ((PVar "binds")) (EMatch (EApp (EApp (EVar "lookupBinding") (ELit (LString "main"))) (EVar "binds")) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-NO-MAIN"))) (EVar "noMainMsg"))) (arm (PCon "Some" (PVar "mv")) () (EMatch (EApp (EApp (EVar "lookupBinding") (ELit (LString "runAsync"))) (EVar "binds")) (arm (PCon "Some" (PVar "rf")) () (EApp (EApp (EVar "apply") (EVar "rf")) (EApp (EVar "force") (EVar "mv")))) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-NO-RUNASYNC"))) (ELit (LString "main : Async _ requires `runAsync` in scope. Add `import async`"))))))))
(DTypeSig true "evalOne" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalOne" ((PVar "preludeDecls") (PTuple (PVar "rootId") (PVar "prog"))) (EApp (EApp (EVar "evalModules") (EVar "preludeDecls")) (EListLit (ETuple (EVar "rootId") (EVar "prog")))))
(DTypeSig true "evalOneWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "evalOneWith" ((PVar "extraExterns") (PVar "preludeDecls") (PTuple (PVar "rootId") (PVar "prog"))) (EApp (EApp (EApp (EVar "evalModulesWith") (EVar "extraExterns")) (EVar "preludeDecls")) (EListLit (ETuple (EVar "rootId") (EVar "prog")))))
(DTypeSig true "evalOneOutput" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "String"))))
(DFunDef false "evalOneOutput" ((PVar "preludeDecls") (PTuple (PVar "rootId") (PVar "prog"))) (EApp (EApp (EVar "evalModulesOutput") (EVar "preludeDecls")) (EListLit (ETuple (EVar "rootId") (EVar "prog")))))
(DTypeSig true "evalOneRootEnv" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalOneRootEnv" ((PVar "preludeDecls") (PTuple (PVar "rootId") (PVar "prog"))) (EApp (EApp (EVar "evalModulesRootEnv") (EVar "preludeDecls")) (EListLit (ETuple (EVar "rootId") (EVar "prog")))))
(DTypeSig true "evalOneRootEnvWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "evalOneRootEnvWith" ((PVar "extraExterns") (PVar "preludeDecls") (PTuple (PVar "rootId") (PVar "prog"))) (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EVar "extraExterns")) (EVar "preludeDecls")) (EListLit (ETuple (EVar "rootId") (EVar "prog")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "Ty" true) (mem "Addr" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "Route" true) (mem "ConPayload" true) (mem "Field" true) (mem "Variant" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "ImplMethod" true) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberOrigin" false) (mem "useMemberLocal" false) (mem "qualifiedLocal" false) (mem "Decl" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "reverseL" false) (mem "anyList" false) (mem "lookupAssoc" false) (mem "joinWith" false) (mem "fallthroughName" false) (mem "noneHeadTag" false) (mem "isEmptyL" false) (mem "filterList" false) (mem "initList" false) (mem "mapOption" false) (mem "joinDot" false) (mem "dedup" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Diag" true) (mem "Severity" true) (mem "cjAllToJson" false))))
(DUse false (UseGroup ("bits64") ((mem "add64" false) (mem "sub64" false) (mem "mulLow64" false) (mem "xor64" false) (mem "shr64" false) (mem "mod64" false) (mem "ofInt" false) (mem "isZero" false) (mem "limbAt" false))))
(DData Public "Value" ("e") ((variant "VInt" (ConPos (TyCon "Int"))) (variant "VFloat" (ConPos (TyCon "Float"))) (variant "VString" (ConPos (TyCon "String"))) (variant "VChar" (ConPos (TyCon "String"))) (variant "VBool" (ConPos (TyCon "Bool"))) (variant "VUnit" (ConPos)) (variant "VTuple" (ConPos (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))) (variant "VList" (ConPos (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))) (variant "VArray" (ConPos (TyApp (TyCon "Array") (TyApp (TyCon "Value") (TyVar "e"))))) (variant "VCon" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))) (variant "VRecord" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))) (variant "VRef" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (variant "VClosure" (ConPos (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (variant "VClosureF" (ConPos (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))) (variant "VPrim" (ConPos (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))) (variant "VMulti" (ConPos (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))) (variant "VThunk" (ConPos (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))) (variant "VFallthrough" (ConPos)) (variant "VTypedImpl" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))) (variant "VDict" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))) ())
(DData Public "EvalEnv" ("v") ((variant "EvalEnv" (ConPos (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyVar "v")))))))) ())
(DTypeSig true "ppValue" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "String")))
(DFunDef false "ppValue" ((PCon "VInt" (PVar "n"))) (EApp (EVar "intToString") (EVar "n")))
(DFunDef false "ppValue" ((PCon "VFloat" (PVar "f"))) (EApp (EVar "floatToString") (EVar "f")))
(DFunDef false "ppValue" ((PCon "VString" (PVar "s"))) (EVar "s"))
(DFunDef false "ppValue" ((PCon "VChar" (PVar "c"))) (EVar "c"))
(DFunDef false "ppValue" ((PCon "VBool" (PCon "True"))) (ELit (LString "true")))
(DFunDef false "ppValue" ((PCon "VBool" (PCon "False"))) (ELit (LString "false")))
(DFunDef false "ppValue" ((PCon "VUnit")) (ELit (LString "()")))
(DFunDef false "ppValue" ((PCon "VTuple" (PVar "vs"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "joinComma") (EApp (EApp (EMethodRef "map") (EVar "ppValue")) (EVar "vs")))) (ELit (LString ")"))))
(DFunDef false "ppValue" ((PCon "VList" (PVar "vs"))) (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EVar "joinComma") (EApp (EApp (EMethodRef "map") (EVar "ppValue")) (EVar "vs")))) (ELit (LString "]"))))
(DFunDef false "ppValue" ((PCon "VArray" (PVar "vs"))) (EBinOp "++" (EBinOp "++" (ELit (LString "[|")) (EApp (EVar "joinComma") (EApp (EApp (EMethodRef "map") (EVar "ppValue")) (EApp (EVar "arrayToListG") (EVar "vs"))))) (ELit (LString "|]"))))
(DFunDef false "ppValue" ((PCon "VCon" (PVar "name") (PList))) (EVar "name"))
(DFunDef false "ppValue" ((PCon "VCon" (PVar "name") (PVar "vs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "joinSp") (EApp (EApp (EMethodRef "map") (EVar "ppValueAtom")) (EVar "vs"))))) (ELit (LString ""))))
(DFunDef false "ppValue" ((PCon "VRecord" (PVar "name") (PVar "fields"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " { "))) (EApp (EMethodRef "display") (EApp (EVar "joinComma") (EApp (EApp (EMethodRef "map") (EVar "ppField")) (EVar "fields"))))) (ELit (LString " }"))))
(DFunDef false "ppValue" ((PCon "VRef" (PVar "cell"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Ref(")) (EApp (EVar "ppValue") (EFieldAccess (EVar "cell") "value"))) (ELit (LString ")"))))
(DFunDef false "ppValue" ((PCon "VClosure" PWild PWild PWild)) (ELit (LString "<closure>")))
(DFunDef false "ppValue" ((PCon "VClosureF" PWild PWild PWild)) (ELit (LString "<closure>")))
(DFunDef false "ppValue" ((PCon "VPrim" PWild)) (ELit (LString "<prim>")))
(DFunDef false "ppValue" ((PCon "VMulti" (PVar "vs"))) (EBinOp "++" (EBinOp "++" (ELit (LString "<dispatch/")) (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "vs")))) (ELit (LString ">"))))
(DFunDef false "ppValue" ((PCon "VTypedImpl" (PVar "t") PWild PWild PWild (PVar "inner"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<impl@")) (EApp (EMethodRef "display") (EVar "t"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "ppValue") (EVar "inner")))) (ELit (LString ">"))))
(DFunDef false "ppValue" ((PCon "VThunk" PWild)) (ELit (LString "<thunk>")))
(DFunDef false "ppValue" ((PCon "VDict" (PVar "key") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<dict:")) (EVar "key")) (ELit (LString ">"))))
(DFunDef false "ppValue" ((PCon "VFallthrough")) (ELit (LString "<fallthrough>")))
(DTypeSig false "ppField" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "String")))
(DFunDef false "ppField" ((PTuple (PVar "k") (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "ppValue") (EVar "v")))) (ELit (LString ""))))
(DTypeSig false "ppValueAtom" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "String")))
(DFunDef false "ppValueAtom" ((PCon "VCon" (PVar "name") (PCons (PVar "x") (PVar "xs")))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppValue") (EApp (EApp (EVar "VCon") (EVar "name")) (EBinOp "::" (EVar "x") (EVar "xs"))))) (ELit (LString ")"))))
(DFunDef false "ppValueAtom" ((PCon "VTuple" (PVar "vs"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppValue") (EApp (EVar "VTuple") (EVar "vs")))) (ELit (LString ")"))))
(DFunDef false "ppValueAtom" ((PVar "v")) (EApp (EVar "ppValue") (EVar "v")))
(DTypeSig false "joinComma" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinComma" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "xs")))
(DTypeSig false "joinSp" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSp" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "xs")))
(DTypeSig false "arrayToListG" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "arrayToListG" ((PVar "arr")) (EApp (EApp (EApp (EVar "arrayToListGo") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))
(DTypeSig false "arrayToListGo" (TyFun (TyApp (TyCon "Array") (TyVar "a")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "arrayToListGo" ((PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (EApp (EApp (EApp (EVar "arrayToListGo") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "intSeq" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "intSeq" ((PVar "lo") (PVar "end")) (EIf (EBinOp ">=" (EVar "lo") (EVar "end")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EVar "lo") (EApp (EApp (EVar "intSeq") (EBinOp "+" (EVar "lo") (ELit (LInt 1)))) (EVar "end"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "listNthAt" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "listNthAt" ((PList) (PVar "orig") PWild) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-INDEX-OOB"))) (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EVar "intToString") (EVar "orig"))) (ELit (LString " out of bounds")))))
(DFunDef false "listNthAt" ((PCons (PVar "x") (PVar "xs")) (PVar "orig") (PVar "i")) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "x") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "listNthAt") (EVar "xs")) (EVar "orig")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "listSliceV" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "listSliceV" ((PVar "xs") (PVar "lo") (PVar "hi")) (EApp (EApp (EApp (EApp (EVar "listSliceGo") (EVar "xs")) (ELit (LInt 0))) (EVar "lo")) (EVar "hi")))
(DTypeSig false "listSliceGo" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "listSliceGo" ((PList) PWild PWild PWild) (EListLit))
(DFunDef false "listSliceGo" ((PCons (PVar "x") (PVar "xs")) (PVar "i") (PVar "lo") (PVar "hi")) (EIf (EBinOp ">=" (EVar "i") (EVar "hi")) (EListLit) (EIf (EBinOp ">=" (EVar "i") (EVar "lo")) (EBinOp "::" (EVar "x") (EApp (EApp (EApp (EApp (EVar "listSliceGo") (EVar "xs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "lo")) (EVar "hi"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "listSliceGo") (EVar "xs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "lo")) (EVar "hi")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "startsWithAt" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "startsWithAt" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")) (ELit (LChar "@")))))))
(DTypeSig false "containsInt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "containsInt" (PWild (PList)) (EVar "False"))
(DFunDef false "containsInt" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "containsInt") (EVar "x")) (EVar "ys"))))
(DTypeSig true "ctorToTypeRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "ctorToTypeRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "buildCtorToType" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "buildCtorToType" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ctorTypeEntries")) (EVar "prog")))
(DTypeSig false "ctorTypeEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "ctorTypeEntries" ((PCon "DData" PWild (PVar "tyname") PWild (PVar "variants") PWild)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (ETuple (EApp (EVar "variantName") (EVar "v")) (EVar "tyname")))) (EVar "variants")))
(DFunDef false "ctorTypeEntries" ((PCon "DNewtype" PWild (PVar "tyname") PWild (PVar "con") PWild PWild)) (EListLit (ETuple (EVar "con") (EVar "tyname"))))
(DFunDef false "ctorTypeEntries" (PWild) (EListLit))
(DTypeSig false "variantName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig true "ctorFieldOrdersRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorFieldOrdersRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "methodReqCountRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "methodReqCountRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "buildMethodReqCounts" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Int")))))
(DFunDef false "buildMethodReqCounts" ((PVar "prog")) (EBlock (DoLet false false (PVar "arities") (EApp (EApp (EDictApp "flatMap") (EVar "methodDeclArities")) (EVar "prog"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EVar "implMethodReqCounts") (EVar "arities"))) (EVar "prog")))))
(DTypeSig false "methodDeclArities" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "methodDeclArities" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "methodDeclArities") (EVar "d")))
(DFunDef false "methodDeclArities" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodArity")) (EVar "methods")))
(DFunDef false "methodDeclArities" (PWild) (EListLit))
(DTypeSig false "ifaceMethodArity" (TyFun (TyCon "IfaceMethod") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "ifaceMethodArity" ((PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild)) (ETuple (EVar "mname") (EApp (EVar "listLen") (EApp (EVar "argsOfTy") (EVar "mty")))))
(DTypeSig false "implMethodReqCounts" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Int"))))))
(DFunDef false "implMethodReqCounts" ((PVar "arities") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "implMethodReqCounts") (EVar "arities")) (EVar "d")))
(DFunDef false "implMethodReqCounts" ((PVar "arities") (PRec "DImpl" ((rf "tys" (PVar "typeArgs")) (rf "methods" None)) true)) (EMatch (EApp (EVar "headTyconHead") (EVar "typeArgs")) (arm (PCon "Some" (PVar "tag")) () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "implMethodReqCountEntry") (EVar "arities")) (EVar "tag"))) (EVar "methods"))) (arm (PCon "None") () (EListLit))))
(DFunDef false "implMethodReqCounts" (PWild PWild) (EListLit))
(DTypeSig false "implMethodReqCountEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "String") (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Int")))))))
(DFunDef false "implMethodReqCountEntry" ((PVar "arities") (PVar "tag") (PCon "ImplMethod" (PVar "mname") (PVar "pats") PWild)) (EBlock (DoLet false false (PVar "declArity") (EApp (EApp (EVar "fromOption") (EApp (EVar "listLen") (EVar "pats"))) (EApp (EApp (EVar "lookupAssoc") (EVar "mname")) (EVar "arities")))) (DoLet false false (PVar "reqCount") (EApp (EApp (EVar "subClampZero") (EApp (EVar "listLen") (EVar "pats"))) (EVar "declArity"))) (DoExpr (EListLit (ETuple (ETuple (EVar "mname") (EVar "tag")) (EVar "reqCount"))))))
(DTypeSig false "subClampZero" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "subClampZero" ((PVar "a") (PVar "b")) (EIf (EBinOp "<" (EBinOp "-" (EVar "a") (EVar "b")) (ELit (LInt 0))) (ELit (LInt 0)) (EBinOp "-" (EVar "a") (EVar "b"))))
(DTypeSig false "takeN" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "takeN" ((PVar "n") PWild) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "takeN" (PWild (PList)) (EListLit))
(DFunDef false "takeN" ((PVar "n") (PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeN") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "lookupMethodReqCount" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "lookupMethodReqCount" ((PVar "mname") (PVar "tag")) (EApp (EApp (EApp (EVar "lookupReqCount") (EVar "mname")) (EVar "tag")) (EFieldAccess (EVar "methodReqCountRef") "value")))
(DTypeSig false "lookupReqCount" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Int"))) (TyCon "Int")))))
(DFunDef false "lookupReqCount" (PWild PWild (PList)) (ELit (LInt 0)))
(DFunDef false "lookupReqCount" ((PVar "mname") (PVar "tag") (PCons (PTuple (PTuple (PVar "m") (PVar "t")) (PVar "c")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "m") (EVar "mname")) (EBinOp "==" (EVar "t") (EVar "tag"))) (EVar "c") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lookupReqCount") (EVar "mname")) (EVar "tag")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "buildCtorFieldOrders" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "buildCtorFieldOrders" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ctorFieldOrderEntries")) (EVar "prog")))
(DTypeSig false "ctorFieldOrderEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorFieldOrderEntries" ((PCon "DData" PWild PWild PWild (PVar "variants") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "variantFieldOrder")) (EVar "variants")))
(DFunDef false "ctorFieldOrderEntries" (PWild) (EListLit))
(DTypeSig false "variantFieldOrder" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "variantFieldOrder" ((PCon "Variant" (PVar "n") (PCon "ConNamed" (PVar "fs") PWild))) (EListLit (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "fieldName")) (EVar "fs")))))
(DFunDef false "variantFieldOrder" (PWild) (EListLit))
(DTypeSig false "fieldName" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldName" ((PCon "Field" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "runtimeTypeTag" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "runtimeTypeTag" ((PCon "VInt" PWild)) (EApp (EVar "Some") (ELit (LString "Int"))))
(DFunDef false "runtimeTypeTag" ((PCon "VFloat" PWild)) (EApp (EVar "Some") (ELit (LString "Float"))))
(DFunDef false "runtimeTypeTag" ((PCon "VString" PWild)) (EApp (EVar "Some") (ELit (LString "String"))))
(DFunDef false "runtimeTypeTag" ((PCon "VChar" PWild)) (EApp (EVar "Some") (ELit (LString "Char"))))
(DFunDef false "runtimeTypeTag" ((PCon "VBool" PWild)) (EApp (EVar "Some") (ELit (LString "Bool"))))
(DFunDef false "runtimeTypeTag" ((PCon "VUnit")) (EApp (EVar "Some") (ELit (LString "Unit"))))
(DFunDef false "runtimeTypeTag" ((PCon "VList" PWild)) (EApp (EVar "Some") (ELit (LString "List"))))
(DFunDef false "runtimeTypeTag" ((PCon "VArray" PWild)) (EApp (EVar "Some") (ELit (LString "Array"))))
(DFunDef false "runtimeTypeTag" ((PCon "VTuple" (PVar "vs"))) (EApp (EVar "Some") (EApp (EVar "tupleHeadTag") (EApp (EVar "listLen") (EVar "vs")))))
(DFunDef false "runtimeTypeTag" ((PCon "VCon" (PVar "cname") PWild)) (EApp (EApp (EVar "lookupAssoc") (EVar "cname")) (EFieldAccess (EVar "ctorToTypeRef") "value")))
(DFunDef false "runtimeTypeTag" ((PCon "VRecord" (PVar "name") PWild)) (EApp (EVar "Some") (EVar "name")))
(DFunDef false "runtimeTypeTag" ((PCon "VTypedImpl" (PVar "t") PWild PWild PWild PWild)) (EApp (EVar "Some") (EVar "t")))
(DFunDef false "runtimeTypeTag" (PWild) (EVar "None"))
(DTypeSig false "countTyvars" (TyFun (TyCon "Ty") (TyCon "Int")))
(DFunDef false "countTyvars" ((PCon "TyVar" PWild)) (ELit (LInt 1)))
(DFunDef false "countTyvars" ((PCon "TyCon" PWild PWild)) (ELit (LInt 0)))
(DFunDef false "countTyvars" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "+" (EApp (EVar "countTyvars") (EVar "a")) (EApp (EVar "countTyvars") (EVar "b"))))
(DFunDef false "countTyvars" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "+" (EApp (EVar "countTyvars") (EVar "a")) (EApp (EVar "countTyvars") (EVar "b"))))
(DFunDef false "countTyvars" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "sumInts") (EApp (EApp (EMethodRef "map") (EVar "countTyvars")) (EVar "ts"))))
(DFunDef false "countTyvars" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "countTyvars") (EVar "t")))
(DFunDef false "countTyvars" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "countTyvars") (EVar "t")))
(DTypeSig false "sumInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "sumInts" ((PList)) (ELit (LInt 0)))
(DFunDef false "sumInts" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "+" (EVar "x") (EApp (EVar "sumInts") (EVar "xs"))))
(DTypeSig true "tyvarsInArgs" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Int")))
(DFunDef false "tyvarsInArgs" ((PVar "ts")) (EApp (EVar "sumInts") (EApp (EApp (EMethodRef "map") (EVar "countTyvars")) (EVar "ts"))))
(DTypeSig true "implKeyOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))))
(DFunDef false "implKeyOf" ((PVar "iface") (PVar "typeArgs") (PVar "nm")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "ppTyAtomK")) (EVar "typeArgs"))))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "fromOption") (ELit (LString ""))) (EVar "nm")))) (ELit (LString ""))))
(DTypeSig false "ppTyK" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyK" ((PCon "TyCon" (PVar "n") PWild)) (EVar "n"))
(DFunDef false "ppTyK" ((PCon "TyVar" (PVar "n"))) (EVar "n"))
(DFunDef false "ppTyK" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppTyK") (EVar "a")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "ppTyAtomK") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "ppTyK" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppTyFunArgK") (EVar "a")))) (ELit (LString " -> "))) (EApp (EMethodRef "display") (EApp (EVar "ppTyK") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "ppTyK" ((PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "joinComma") (EApp (EApp (EMethodRef "map") (EVar "ppTyK")) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "ppTyK" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "ppTyK") (EVar "t")))
(DFunDef false "ppTyK" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "ppTyK") (EVar "t")))
(DTypeSig false "ppTyFunArgK" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyFunArgK" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppTyK") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "ppTyFunArgK" ((PVar "t")) (EApp (EVar "ppTyK") (EVar "t")))
(DTypeSig false "ppTyAtomK" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyAtomK" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppTyK") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "ppTyAtomK" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppTyK") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "ppTyAtomK" ((PVar "t")) (EApp (EVar "ppTyK") (EVar "t")))
(DTypeSig true "tupleHeadTag" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "tupleHeadTag" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "__tuple")) (EApp (EVar "intToString") (EVar "n"))) (ELit (LString "__"))))
(DTypeSig false "headTycon" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headTycon" ((PCon "TyCon" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "headTycon" ((PCon "TyApp" (PVar "a") PWild)) (EApp (EVar "headTycon") (EVar "a")))
(DFunDef false "headTycon" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "headTycon") (EVar "t")))
(DFunDef false "headTycon" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "headTycon") (EVar "t")))
(DFunDef false "headTycon" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "Some") (EApp (EVar "tupleHeadTag") (EApp (EVar "listLen") (EVar "ts")))))
(DFunDef false "headTycon" (PWild) (EVar "None"))
(DTypeSig false "dispatchPositionsOf" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "dispatchPositionsOf" ((PVar "mty") (PVar "params")) (EApp (EApp (EApp (EVar "filterMentions") (ELit (LInt 0))) (EApp (EVar "argsOfTy") (EVar "mty"))) (EVar "params")))
(DTypeSig false "argsOfTy" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "argsOfTy" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "argsOfTy") (EVar "t")))
(DFunDef false "argsOfTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "argsOfTy") (EVar "t")))
(DFunDef false "argsOfTy" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "a") (EApp (EVar "argsOfTy") (EVar "b"))))
(DFunDef false "argsOfTy" (PWild) (EListLit))
(DTypeSig false "filterMentions" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "filterMentions" (PWild (PList) PWild) (EListLit))
(DFunDef false "filterMentions" ((PVar "i") (PCons (PVar "t") (PVar "ts")) (PVar "params")) (EIf (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EVar "filterMentions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "filterMentions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tyMentions" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyMentions" ((PCon "TyVar" (PVar "n")) (PVar "params")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "params")))
(DFunDef false "tyMentions" ((PCon "TyCon" PWild PWild) PWild) (EVar "False"))
(DFunDef false "tyMentions" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentions") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentions" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentions") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentions" ((PCon "TyTuple" (PVar "ts")) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))) (EVar "ts")))
(DFunDef false "tyMentions" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentions" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentions") (EVar "t")) (EVar "params")))
(DTypeSig true "lookupEnv" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "lookupEnv" ((PCon "EvalEnv" (PVar "frames")) (PVar "name")) (EApp (EApp (EVar "lookupFrames") (EVar "frames")) (EVar "name")))
(DTypeSig false "lookupFrames" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))) (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "lookupFrames" ((PList) (PVar "name")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "unbound identifier: ")) (EVar "name"))))
(DFunDef false "lookupFrames" ((PCons (PVar "frame") (PVar "rest")) (PVar "name")) (EMatch (EApp (EApp (EVar "lookupFrameCell") (EVar "frame")) (EVar "name")) (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EVar "forceCell") (EVar "cell")) (EVar "name"))) (arm (PCon "None") () (EApp (EApp (EVar "lookupFrames") (EVar "rest")) (EVar "name")))))
(DTypeSig true "lookupMethod" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "lookupMethod" ((PCon "EvalEnv" (PVar "frames")) (PVar "name")) (EApp (EApp (EApp (EVar "lookupMethodFrames") (EVar "frames")) (EVar "frames")) (EVar "name")))
(DTypeSig false "lookupMethodFrames" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))) (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "lookupMethodFrames" ((PVar "all") (PList) (PVar "name")) (EApp (EApp (EVar "lookupFrames") (EDictApp "all")) (EVar "name")))
(DFunDef false "lookupMethodFrames" ((PVar "all") (PCons (PVar "frame") (PVar "rest")) (PVar "name")) (EMatch (EApp (EApp (EVar "lookupFrameCell") (EVar "frame")) (EVar "name")) (arm (PCon "Some" (PVar "cell")) () (EIf (EApp (EVar "isMethodBinding") (EApp (EApp (EVar "forceCell") (EVar "cell")) (EVar "name"))) (EApp (EApp (EVar "forceCell") (EVar "cell")) (EVar "name")) (EApp (EApp (EApp (EVar "lookupMethodFrames") (EDictApp "all")) (EVar "rest")) (EVar "name")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "lookupMethodFrames") (EDictApp "all")) (EVar "rest")) (EVar "name")))))
(DTypeSig false "isMethodBinding" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool")))
(DFunDef false "isMethodBinding" ((PCon "VTypedImpl" PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isMethodBinding" ((PCon "VMulti" (PVar "vs"))) (EApp (EVar "anyTypedImpl") (EVar "vs")))
(DFunDef false "isMethodBinding" (PWild) (EVar "False"))
(DTypeSig false "anyTypedImpl" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "Bool")))
(DFunDef false "anyTypedImpl" ((PList)) (EVar "False"))
(DFunDef false "anyTypedImpl" ((PCons (PCon "VTypedImpl" PWild PWild PWild PWild PWild) PWild)) (EVar "True"))
(DFunDef false "anyTypedImpl" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyTypedImpl") (EVar "rest")))
(DTypeSig false "forceCell" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "forceCell" ((PVar "cell") (PVar "name")) (EMatch (EFieldAccess (EVar "cell") "value") (arm (PCon "VThunk" (PVar "f")) () (EApp (EApp (EApp (EVar "forceMemo") (EVar "cell")) (EVar "name")) (EVar "f"))) (arm (PVar "v") () (EVar "v"))))
(DTypeSig false "forceMemo" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "forceMemo" ((PVar "cell") (PVar "name") (PVar "f")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "VThunk") (EApp (EVar "blackholeCell") (EVar "name"))))) (DoLet false false (PVar "v") (EApp (EVar "f") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cell")) (EVar "v"))) (DoExpr (EVar "v"))))
(DTypeSig false "blackholeCell" (TyFun (TyCon "String") (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "blackholeCell" ((PVar "name") PWild) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-CYCLIC-VALUE"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " refers to itself during initialization (non-productive cyclic value)")))))
(DTypeSig true "force" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "force" ((PCon "VThunk" (PVar "f"))) (EApp (EVar "f") (ELit LUnit)))
(DFunDef false "force" ((PVar "v")) (EVar "v"))
(DTypeSig false "lookupFrameCell" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "lookupFrameCell" ((PList) PWild) (EVar "None"))
(DFunDef false "lookupFrameCell" ((PCons (PTuple (PVar "n") (PVar "cell")) (PVar "rest")) (PVar "name")) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "Some") (EVar "cell")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupFrameCell") (EVar "rest")) (EVar "name")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "lookupAtAddr" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyCon "Addr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "lookupAtAddr" ((PVar "env") (PVar "name") (PCon "AGlobal")) (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "name")))
(DFunDef false "lookupAtAddr" ((PCon "EvalEnv" (PVar "frames")) (PVar "name") (PCon "ALocal" (PVar "depth") (PVar "slot"))) (EApp (EApp (EVar "forceCell") (EApp (EApp (EApp (EVar "addrCell") (EApp (EApp (EApp (EVar "frameAtDepth") (EVar "frames")) (EVar "depth")) (EVar "name"))) (EVar "slot")) (EVar "name"))) (EVar "name")))
(DTypeSig false "frameAtDepth" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "frameAtDepth" ((PList) PWild (PVar "name")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "EVarAt: frame depth out of range for ")) (EVar "name"))))
(DFunDef false "frameAtDepth" ((PCons (PVar "frame") (PVar "rest")) (PVar "depth") (PVar "name")) (EIf (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EVar "frame") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "frameAtDepth") (EVar "rest")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "name")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "addrCell" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "addrCell" ((PList) PWild (PVar "name")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "EVarAt: slot out of range for ")) (EVar "name"))))
(DFunDef false "addrCell" ((PCons (PTuple (PVar "n") (PVar "cell")) (PVar "rest")) (PVar "slot") (PVar "name")) (EIf (EBinOp ">" (EVar "slot") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "addrCell") (EVar "rest")) (EBinOp "-" (EVar "slot") (ELit (LInt 1)))) (EVar "name")) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EVar "cell") (EIf (EVar "otherwise") (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "EVarAt: slot/name mismatch; want ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ", found "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "extendEnv" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "extendEnv" ((PCon "EvalEnv" (PVar "frames")) (PVar "binds")) (EApp (EVar "EvalEnv") (EBinOp "::" (EApp (EApp (EMethodRef "map") (EVar "cellOf")) (EVar "binds")) (EVar "frames"))))
(DTypeSig false "cellOf" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))) (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "cellOf" ((PTuple (PVar "n") (PVar "v"))) (ETuple (EVar "n") (EApp (EVar "Ref") (EVar "v"))))
(DTypeSig true "pushFrame" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pushFrame" ((PCon "EvalEnv" (PVar "frames")) (PVar "frame")) (EApp (EVar "EvalEnv") (EBinOp "::" (EVar "frame") (EVar "frames"))))
(DTypeSig true "findCell" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "findCell" ((PList) (PVar "name")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "findCell: missing ")) (EVar "name"))))
(DFunDef false "findCell" ((PCons (PTuple (PVar "n") (PVar "cell")) (PVar "rest")) (PVar "name")) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EVar "cell") (EIf (EVar "otherwise") (EApp (EApp (EVar "findCell") (EVar "rest")) (EVar "name")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "valueEq" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "valueEq" ((PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "valueEq" ((PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "valueEq" ((PCon "VString" (PVar "a")) (PCon "VString" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "valueEq" ((PCon "VChar" (PVar "a")) (PCon "VChar" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "valueEq" ((PCon "VBool" (PVar "a")) (PCon "VBool" (PVar "b"))) (EApp (EApp (EVar "boolEq") (EVar "a")) (EVar "b")))
(DFunDef false "valueEq" ((PCon "VUnit") (PCon "VUnit")) (EVar "True"))
(DFunDef false "valueEq" ((PCon "VTuple" (PVar "a")) (PCon "VTuple" (PVar "b"))) (EApp (EApp (EVar "valueListEq") (EVar "a")) (EVar "b")))
(DFunDef false "valueEq" ((PCon "VList" (PVar "a")) (PCon "VList" (PVar "b"))) (EApp (EApp (EVar "valueListEq") (EVar "a")) (EVar "b")))
(DFunDef false "valueEq" ((PCon "VArray" (PVar "a")) (PCon "VArray" (PVar "b"))) (EApp (EApp (EVar "valueListEq") (EApp (EVar "arrayToListG") (EVar "a"))) (EApp (EVar "arrayToListG") (EVar "b"))))
(DFunDef false "valueEq" ((PCon "VCon" (PVar "n1") (PVar "a1")) (PCon "VCon" (PVar "n2") (PVar "a2"))) (EBinOp "&&" (EBinOp "==" (EVar "n1") (EVar "n2")) (EApp (EApp (EVar "valueListEq") (EVar "a1")) (EVar "a2"))))
(DFunDef false "valueEq" ((PCon "VRecord" (PVar "n1") (PVar "f1")) (PCon "VRecord" (PVar "n2") (PVar "f2"))) (EBinOp "&&" (EBinOp "==" (EVar "n1") (EVar "n2")) (EApp (EApp (EVar "fieldListEq") (EVar "f1")) (EVar "f2"))))
(DFunDef false "valueEq" ((PCon "VRef" (PVar "a")) (PCon "VRef" (PVar "b"))) (EApp (EApp (EVar "valueEq") (EFieldAccess (EVar "a") "value")) (EFieldAccess (EVar "b") "value")))
(DFunDef false "valueEq" (PWild PWild) (EVar "False"))
(DTypeSig false "valueListEq" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "Bool"))))
(DFunDef false "valueListEq" ((PList) (PList)) (EVar "True"))
(DFunDef false "valueListEq" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EBinOp "&&" (EApp (EApp (EVar "valueEq") (EVar "x")) (EVar "y")) (EApp (EApp (EVar "valueListEq") (EVar "xs")) (EVar "ys"))))
(DFunDef false "valueListEq" (PWild PWild) (EVar "False"))
(DTypeSig false "fieldListEq" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyCon "Bool"))))
(DFunDef false "fieldListEq" ((PList) (PList)) (EVar "True"))
(DFunDef false "fieldListEq" ((PCons (PTuple (PVar "k1") (PVar "v1")) (PVar "r1")) (PCons (PTuple (PVar "k2") (PVar "v2")) (PVar "r2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "k1") (EVar "k2")) (EApp (EApp (EVar "valueEq") (EVar "v1")) (EVar "v2"))) (EApp (EApp (EVar "fieldListEq") (EVar "r1")) (EVar "r2"))))
(DFunDef false "fieldListEq" (PWild PWild) (EVar "False"))
(DTypeSig false "boolEq" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "boolEq" ((PCon "True") (PCon "True")) (EVar "True"))
(DFunDef false "boolEq" ((PCon "False") (PCon "False")) (EVar "True"))
(DFunDef false "boolEq" (PWild PWild) (EVar "False"))
(DTypeSig false "boolToInt" (TyFun (TyCon "Bool") (TyCon "Int")))
(DFunDef false "boolToInt" ((PCon "False")) (ELit (LInt 0)))
(DFunDef false "boolToInt" ((PCon "True")) (ELit (LInt 1)))
(DTypeSig false "valueTag" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Int")))
(DFunDef false "valueTag" ((PCon "VInt" PWild)) (ELit (LInt 0)))
(DFunDef false "valueTag" ((PCon "VFloat" PWild)) (ELit (LInt 1)))
(DFunDef false "valueTag" ((PCon "VString" PWild)) (ELit (LInt 2)))
(DFunDef false "valueTag" ((PCon "VChar" PWild)) (ELit (LInt 3)))
(DFunDef false "valueTag" ((PCon "VBool" PWild)) (ELit (LInt 4)))
(DFunDef false "valueTag" ((PCon "VUnit")) (ELit (LInt 5)))
(DFunDef false "valueTag" ((PCon "VTuple" PWild)) (ELit (LInt 6)))
(DFunDef false "valueTag" ((PCon "VList" PWild)) (ELit (LInt 7)))
(DFunDef false "valueTag" ((PCon "VArray" PWild)) (ELit (LInt 8)))
(DFunDef false "valueTag" ((PCon "VCon" PWild PWild)) (ELit (LInt 9)))
(DFunDef false "valueTag" ((PCon "VRecord" PWild PWild)) (ELit (LInt 10)))
(DFunDef false "valueTag" ((PCon "VRef" PWild)) (ELit (LInt 11)))
(DFunDef false "valueTag" (PWild) (ELit (LInt 99)))
(DTypeSig false "valueCompare" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Ordering"))))
(DFunDef false "valueCompare" ((PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EApp (EMethodRef "compare") (EVar "a")) (EVar "b")))
(DFunDef false "valueCompare" ((PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EApp (EMethodRef "compare") (EVar "a")) (EVar "b")))
(DFunDef false "valueCompare" ((PCon "VString" (PVar "a")) (PCon "VString" (PVar "b"))) (EApp (EApp (EMethodRef "compare") (EVar "a")) (EVar "b")))
(DFunDef false "valueCompare" ((PCon "VChar" (PVar "a")) (PCon "VChar" (PVar "b"))) (EApp (EApp (EVar "stringCompare") (EVar "a")) (EVar "b")))
(DFunDef false "valueCompare" ((PCon "VBool" (PVar "a")) (PCon "VBool" (PVar "b"))) (EApp (EApp (EMethodRef "compare") (EApp (EVar "boolToInt") (EVar "a"))) (EApp (EVar "boolToInt") (EVar "b"))))
(DFunDef false "valueCompare" ((PCon "VUnit") (PCon "VUnit")) (EVar "Eq"))
(DFunDef false "valueCompare" ((PCon "VList" (PVar "a")) (PCon "VList" (PVar "b"))) (EApp (EApp (EVar "compareValueLists") (EVar "a")) (EVar "b")))
(DFunDef false "valueCompare" ((PCon "VArray" (PVar "a")) (PCon "VArray" (PVar "b"))) (EApp (EApp (EVar "compareValueLists") (EApp (EVar "arrayToListG") (EVar "a"))) (EApp (EVar "arrayToListG") (EVar "b"))))
(DFunDef false "valueCompare" ((PCon "VTuple" (PVar "a")) (PCon "VTuple" (PVar "b"))) (EApp (EApp (EVar "compareValueLists") (EVar "a")) (EVar "b")))
(DFunDef false "valueCompare" ((PCon "VCon" (PVar "n1") (PVar "a1")) (PCon "VCon" (PVar "n2") (PVar "a2"))) (EMatch (EApp (EApp (EMethodRef "compare") (EVar "n1")) (EVar "n2")) (arm (PCon "Eq") () (EApp (EApp (EVar "compareValueLists") (EVar "a1")) (EVar "a2"))) (arm (PVar "o") () (EVar "o"))))
(DFunDef false "valueCompare" ((PVar "a") (PVar "b")) (EApp (EApp (EMethodRef "compare") (EApp (EVar "valueTag") (EVar "a"))) (EApp (EVar "valueTag") (EVar "b"))))
(DTypeSig false "compareValueLists" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyCon "Ordering"))))
(DFunDef false "compareValueLists" ((PList) (PList)) (EVar "Eq"))
(DFunDef false "compareValueLists" ((PList) (PCons PWild PWild)) (EVar "Lt"))
(DFunDef false "compareValueLists" ((PCons PWild PWild) (PList)) (EVar "Gt"))
(DFunDef false "compareValueLists" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EMatch (EApp (EApp (EVar "valueCompare") (EVar "x")) (EVar "y")) (arm (PCon "Eq") () (EApp (EApp (EVar "compareValueLists") (EVar "xs")) (EVar "ys"))) (arm (PVar "o") () (EVar "o"))))
(DTypeSig false "ordLt" (TyFun (TyCon "Ordering") (TyCon "Bool")))
(DFunDef false "ordLt" ((PCon "Lt")) (EVar "True"))
(DFunDef false "ordLt" (PWild) (EVar "False"))
(DTypeSig false "ordGt" (TyFun (TyCon "Ordering") (TyCon "Bool")))
(DFunDef false "ordGt" ((PCon "Gt")) (EVar "True"))
(DFunDef false "ordGt" (PWild) (EVar "False"))
(DTypeSig true "matchPat" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "matchPat" ((PCon "PVar" (PVar "x")) (PVar "v")) (EApp (EVar "Some") (EListLit (ETuple (EVar "x") (EVar "v")))))
(DFunDef false "matchPat" ((PCon "PWild") PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "matchPat" ((PCon "PLit" (PCon "LInt" (PVar "n"))) (PCon "VInt" (PVar "m"))) (EIf (EBinOp "==" (EVar "n") (EVar "m")) (EApp (EVar "Some") (EListLit)) (EVar "None")))
(DFunDef false "matchPat" ((PCon "PLit" (PCon "LFloat" (PVar "f"))) (PCon "VFloat" (PVar "g"))) (EIf (EBinOp "==" (EVar "f") (EVar "g")) (EApp (EVar "Some") (EListLit)) (EVar "None")))
(DFunDef false "matchPat" ((PCon "PLit" (PCon "LString" (PVar "s"))) (PCon "VString" (PVar "t"))) (EIf (EBinOp "==" (EVar "s") (EVar "t")) (EApp (EVar "Some") (EListLit)) (EVar "None")))
(DFunDef false "matchPat" ((PCon "PLit" (PCon "LChar" (PVar "c"))) (PCon "VChar" (PVar "d"))) (EIf (EBinOp "==" (EVar "c") (EVar "d")) (EApp (EVar "Some") (EListLit)) (EVar "None")))
(DFunDef false "matchPat" ((PCon "PLit" (PCon "LBool" (PVar "b"))) (PCon "VBool" (PVar "c"))) (EIf (EApp (EApp (EVar "boolEq") (EVar "b")) (EVar "c")) (EApp (EVar "Some") (EListLit)) (EVar "None")))
(DFunDef false "matchPat" ((PCon "PLit" (PCon "LUnit")) (PCon "VUnit")) (EApp (EVar "Some") (EListLit)))
(DFunDef false "matchPat" ((PCon "PCon" (PLit (LString "True")) (PList)) (PCon "VBool" (PCon "True"))) (EApp (EVar "Some") (EListLit)))
(DFunDef false "matchPat" ((PCon "PCon" (PLit (LString "False")) (PList)) (PCon "VBool" (PCon "False"))) (EApp (EVar "Some") (EListLit)))
(DFunDef false "matchPat" ((PCon "PCon" (PVar "name") (PVar "pats")) (PCon "VCon" (PVar "name2") (PVar "vals"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "name") (EVar "name2")) (EBinOp "==" (EApp (EVar "listLen") (EVar "pats")) (EApp (EVar "listLen") (EVar "vals")))) (EApp (EApp (EVar "matchPats") (EVar "pats")) (EVar "vals")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "matchPat" ((PCon "PCons" (PVar "h") (PVar "t")) (PCon "VList" (PCons (PVar "x") (PVar "xs")))) (EApp (EApp (EApp (EApp (EVar "matchCons") (EVar "h")) (EVar "t")) (EVar "x")) (EVar "xs")))
(DFunDef false "matchPat" ((PCon "PCons" PWild PWild) (PCon "VList" (PList))) (EVar "None"))
(DFunDef false "matchPat" ((PCon "PTuple" (PVar "pats")) (PCon "VTuple" (PVar "vals"))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "pats")) (EApp (EVar "listLen") (EVar "vals"))) (EApp (EApp (EVar "matchPats") (EVar "pats")) (EVar "vals")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "matchPat" ((PCon "PList" (PVar "pats")) (PCon "VList" (PVar "vals"))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "pats")) (EApp (EVar "listLen") (EVar "vals"))) (EApp (EApp (EVar "matchPats") (EVar "pats")) (EVar "vals")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "matchPat" ((PCon "PAs" (PVar "x") (PVar "p")) (PVar "v")) (EApp (EApp (EApp (EVar "matchAs") (EVar "x")) (EVar "p")) (EVar "v")))
(DFunDef false "matchPat" ((PCon "PRec" PWild (PVar "fields") PWild) (PCon "VRecord" PWild (PVar "recFields"))) (EApp (EApp (EVar "matchRecFields") (EVar "fields")) (EVar "recFields")))
(DFunDef false "matchPat" ((PCon "PRec" (PVar "ctor") (PVar "fields") PWild) (PCon "VCon" (PVar "ctor2") (PVar "vals"))) (EIf (EBinOp "==" (EVar "ctor") (EVar "ctor2")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "ctor")) (EFieldAccess (EVar "ctorFieldOrdersRef") "value")) (arm (PCon "Some" (PVar "order")) () (EApp (EApp (EVar "matchRecFields") (EVar "fields")) (EApp (EApp (EVar "zipFieldOrder") (EVar "order")) (EVar "vals")))) (arm (PCon "None") () (EVar "None"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "matchPat" ((PCon "PRng" (PCon "LInt" (PVar "lo")) (PCon "LInt" (PVar "hi")) (PVar "incl")) (PCon "VInt" (PVar "v"))) (EIf (EApp (EApp (EApp (EApp (EVar "inIntRange") (EVar "v")) (EVar "lo")) (EVar "hi")) (EVar "incl")) (EApp (EVar "Some") (EListLit)) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "matchPat" ((PCon "PRng" (PCon "LChar" (PVar "lo")) (PCon "LChar" (PVar "hi")) (PVar "incl")) (PCon "VChar" (PVar "c"))) (EIf (EApp (EApp (EApp (EApp (EVar "inCharRange") (EVar "c")) (EVar "lo")) (EVar "hi")) (EVar "incl")) (EApp (EVar "Some") (EListLit)) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "matchPat" (PWild PWild) (EVar "None"))
(DTypeSig false "inIntRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool"))))))
(DFunDef false "inIntRange" ((PVar "v") (PVar "lo") (PVar "hi") (PVar "incl")) (EBinOp "&&" (EBinOp ">=" (EVar "v") (EVar "lo")) (EBinOp "<=" (EVar "v") (EIf (EVar "incl") (EVar "hi") (EBinOp "-" (EVar "hi") (ELit (LInt 1)))))))
(DTypeSig false "inCharRange" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "Bool"))))))
(DFunDef false "inCharRange" ((PVar "c") (PVar "lo") (PVar "hi") (PVar "incl")) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "ordLt") (EApp (EApp (EVar "stringCompare") (EVar "c")) (EVar "lo")))) (EApp (EApp (EApp (EVar "charUpper") (EVar "c")) (EVar "hi")) (EVar "incl"))))
(DTypeSig false "charUpper" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "Bool")))))
(DFunDef false "charUpper" ((PVar "c") (PVar "hi") (PCon "True")) (EApp (EVar "not") (EApp (EVar "ordGt") (EApp (EApp (EVar "stringCompare") (EVar "c")) (EVar "hi")))))
(DFunDef false "charUpper" ((PVar "c") (PVar "hi") (PCon "False")) (EApp (EVar "ordLt") (EApp (EApp (EVar "stringCompare") (EVar "c")) (EVar "hi"))))
(DTypeSig false "matchRecFields" (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "matchRecFields" ((PList) PWild) (EApp (EVar "Some") (EListLit)))
(DFunDef false "matchRecFields" ((PCons (PCon "RecPatField" (PVar "fname") (PVar "mp")) (PVar "rest")) (PVar "recFields")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "fname")) (EVar "recFields")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EApp (EApp (EApp (EVar "matchRecField") (EVar "fname")) (EVar "mp")) (EVar "v")) (EVar "rest")) (EVar "recFields")))))
(DTypeSig false "zipFieldOrder" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "zipFieldOrder" ((PList) PWild) (EListLit))
(DFunDef false "zipFieldOrder" (PWild (PList)) (EListLit))
(DFunDef false "zipFieldOrder" ((PCons (PVar "f") (PVar "fs")) (PCons (PVar "v") (PVar "vs"))) (EBinOp "::" (ETuple (EVar "f") (EVar "v")) (EApp (EApp (EVar "zipFieldOrder") (EVar "fs")) (EVar "vs"))))
(DTypeSig false "matchRecField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Pat")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))))
(DFunDef false "matchRecField" ((PVar "fname") (PCon "None") (PVar "v") (PVar "rest") (PVar "recFields")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "fname") (EVar "v")) (EVar "_s")))) (EApp (EApp (EVar "matchRecFields") (EVar "rest")) (EVar "recFields"))))
(DFunDef false "matchRecField" (PWild (PCon "Some" (PVar "q")) (PVar "v") (PVar "rest") (PVar "recFields")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "q")) (EVar "v")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "b") (EVar "_s")))) (EApp (EApp (EVar "matchRecFields") (EVar "rest")) (EVar "recFields"))))))
(DTypeSig false "matchCons" (TyFun (TyCon "Pat") (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "matchCons" ((PVar "h") (PVar "t") (PVar "x") (PVar "xs")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "h")) (EVar "x")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "b1")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "b1") (EVar "_s")))) (EApp (EApp (EVar "matchPat") (EVar "t")) (EApp (EVar "VList") (EVar "xs")))))))
(DTypeSig false "matchAs" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "matchAs" ((PVar "x") (PVar "p") (PVar "v")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (ETuple (EVar "x") (EVar "v")) (EVar "_s")))) (EApp (EApp (EVar "matchPat") (EVar "p")) (EVar "v"))))
(DTypeSig false "matchPats" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "matchPats" ((PList) (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "matchPats" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "v") (PVar "vs"))) (EMatch (EApp (EApp (EVar "matchPat") (EVar "p")) (EVar "v")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (EVar "b") (EVar "_s")))) (EApp (EApp (EVar "matchPats") (EVar "ps")) (EVar "vs"))))))
(DFunDef false "matchPats" (PWild PWild) (EVar "None"))
(DTypeSig true "makeCtor" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "makeCtor" ((PVar "name") (PVar "arity")) (EApp (EApp (EApp (EVar "makeCtorGo") (EVar "name")) (EVar "arity")) (EListLit)))
(DTypeSig false "makeCtorGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "makeCtorGo" ((PVar "name") (PVar "arity") (PVar "acc")) (EIf (EBinOp "<=" (EVar "arity") (ELit (LInt 0))) (EApp (EApp (EVar "VCon") (EVar "name")) (EApp (EVar "reverseL") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EVar "VPrim") (ELam ((PVar "v")) (EApp (EApp (EApp (EVar "makeCtorGo") (EVar "name")) (EBinOp "-" (EVar "arity") (ELit (LInt 1)))) (EBinOp "::" (EVar "v") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "applyValue" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "applyValue" ((PVar "f") (PVar "x")) (EApp (EApp (EVar "apply") (EVar "f")) (EVar "x")))
(DTypeSig true "apply" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "apply" ((PVar "f") (PVar "x")) (EBlock (DoLet false false (PVar "d") (EBinOp "+" (EFieldAccess (EVar "evalDepthRef") "value") (ELit (LInt 1)))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "evalDepthRef")) (EVar "d"))) (DoLet false false PWild (EIf (EBinOp ">" (EVar "d") (EVar "evalDepthLimit")) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-STACK-OVERFLOW"))) (EBinOp "++" (EBinOp "++" (ELit (LString "recursion too deep (evaluator call depth exceeded ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "evalDepthLimit")))) (ELit (LString "); the tree-walking interpreter has no tail-call optimisation")))) (ELit LUnit))) (DoLet false false (PVar "r") (EApp (EApp (EVar "applyDispatch") (EVar "f")) (EVar "x"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "evalDepthRef")) (EBinOp "-" (EVar "d") (ELit (LInt 1))))) (DoExpr (EVar "r"))))
(DTypeSig false "applyDispatch" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "applyDispatch" ((PVar "f") (PVar "x")) (EMatch (EApp (EApp (EVar "applyOpt") (EVar "f")) (EVar "x")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-NONEXHAUSTIVE-MATCH"))) (ELit (LString "non-exhaustive match"))))))
(DTypeSig false "applyOpt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "applyOpt" ((PCon "VClosure" (PVar "env") (PVar "pats") (PVar "body")) (PVar "arg")) (EApp (EApp (EApp (EApp (EVar "applyClosure") (EVar "env")) (EVar "pats")) (EVar "body")) (EVar "arg")))
(DFunDef false "applyOpt" ((PCon "VClosureF" (PVar "env") (PVar "pats") (PVar "f")) (PVar "arg")) (EApp (EApp (EApp (EApp (EVar "applyClosureF") (EVar "env")) (EVar "pats")) (EVar "f")) (EVar "arg")))
(DFunDef false "applyOpt" ((PCon "VPrim" (PVar "f")) (PVar "arg")) (EApp (EVar "Some") (EApp (EVar "f") (EVar "arg"))))
(DFunDef false "applyOpt" ((PCon "VTypedImpl" (PVar "t") (PVar "key") (PVar "pos") (PVar "seen") (PVar "inner")) (PVar "arg")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "applyTyped") (EVar "t")) (EVar "key")) (EVar "pos")) (EVar "seen")) (EVar "inner")) (EVar "arg")))
(DFunDef false "applyOpt" ((PCon "VMulti" (PVar "vs")) (PVar "arg")) (EApp (EApp (EApp (EVar "collectPartials") (EListLit)) (EApp (EApp (EVar "filterByTag") (EVar "vs")) (EVar "arg"))) (EVar "arg")))
(DFunDef false "applyOpt" ((PVar "other") PWild) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-NOT-A-FUNCTION"))) (EBinOp "++" (ELit (LString "applied non-function: ")) (EApp (EVar "ppValue") (EVar "other")))))
(DTypeSig false "applyTyped" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))))))))))
(DFunDef false "applyTyped" ((PVar "t") (PVar "key") (PVar "pos") (PVar "seen") (PVar "inner") (PVar "arg")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "reTag") (EVar "t")) (EVar "key")) (EVar "pos")) (EBinOp "+" (EVar "seen") (ELit (LInt 1))))) (EApp (EApp (EVar "applyOpt") (EVar "inner")) (EVar "arg"))))
(DTypeSig false "reTag" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "reTag" ((PVar "t") (PVar "key") (PVar "pos") (PVar "seen") (PVar "r")) (EIf (EApp (EVar "isPartial") (EVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "VTypedImpl") (EVar "t")) (EVar "key")) (EVar "pos")) (EVar "seen")) (EVar "r")) (EIf (EVar "otherwise") (EVar "r") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterByTag" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "filterByTag" ((PVar "vs") (PVar "arg")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EVar "isDispatching")) (EVar "vs"))) (EVar "vs") (EIf (EVar "otherwise") (EApp (EApp (EVar "filterByTagT") (EVar "vs")) (EApp (EVar "runtimeTypeTag") (EVar "arg"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterByTagT" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "filterByTagT" ((PVar "vs") (PCon "None")) (EVar "vs"))
(DFunDef false "filterByTagT" ((PVar "vs") (PCon "Some" (PVar "tag"))) (EApp (EApp (EVar "keepOrAll") (EVar "vs")) (EApp (EApp (EMethodRef "filter") (EApp (EVar "keepCand") (EVar "tag"))) (EVar "vs"))))
(DTypeSig false "keepOrAll" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "keepOrAll" ((PVar "original") (PList)) (EVar "original"))
(DFunDef false "keepOrAll" (PWild (PVar "kept")) (EVar "kept"))
(DTypeSig false "keepCand" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "keepCand" ((PVar "tag") (PVar "v")) (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isDispatching") (EVar "v"))) (EApp (EApp (EVar "matchesTag") (EVar "tag")) (EVar "v"))))
(DTypeSig false "isDispatching" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool")))
(DFunDef false "isDispatching" ((PCon "VTypedImpl" PWild PWild (PVar "pos") (PVar "seen") PWild)) (EApp (EApp (EVar "containsInt") (EVar "seen")) (EVar "pos")))
(DFunDef false "isDispatching" (PWild) (EVar "False"))
(DTypeSig true "narrowMethod" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "narrowMethod" ((PCon "VMulti" (PVar "vs")) (PLit (LString ""))) (EApp (EVar "VMulti") (EVar "vs")))
(DFunDef false "narrowMethod" ((PCon "VMulti" (PVar "vs")) (PVar "tag")) (EApp (EVar "stripResolved") (EApp (EApp (EVar "pickByTag") (EVar "vs")) (EVar "tag"))))
(DFunDef false "narrowMethod" ((PCon "VTypedImpl" (PVar "t") (PVar "k") (PVar "p") (PVar "s") (PVar "inner")) (PLit (LString ""))) (EApp (EApp (EApp (EApp (EApp (EVar "VTypedImpl") (EVar "t")) (EVar "k")) (EVar "p")) (EVar "s")) (EVar "inner")))
(DFunDef false "narrowMethod" ((PCon "VTypedImpl" (PVar "t") (PVar "k") (PVar "p") (PVar "s") (PVar "inner")) PWild) (EApp (EVar "stripResolved") (EApp (EApp (EApp (EApp (EApp (EVar "VTypedImpl") (EVar "t")) (EVar "k")) (EVar "p")) (EVar "s")) (EVar "inner"))))
(DFunDef false "narrowMethod" ((PVar "v") PWild) (EVar "v"))
(DTypeSig false "pickByTag" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pickByTag" ((PVar "vs") (PVar "tag")) (EMatch (EApp (EApp (EVar "filterList") (EApp (EVar "hasTag") (EVar "tag"))) (EVar "vs")) (arm (PList) () (EApp (EApp (EVar "oneOrMultiV") (EApp (EApp (EVar "filterList") (EVar "isDefaultCand")) (EVar "vs"))) (EVar "vs"))) (arm (PVar "matched") () (EApp (EApp (EVar "oneOrMultiV") (EVar "matched")) (EVar "vs")))))
(DTypeSig false "isDefaultCand" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool")))
(DFunDef false "isDefaultCand" ((PCon "VTypedImpl" PWild PWild PWild PWild PWild)) (EVar "False"))
(DFunDef false "isDefaultCand" (PWild) (EVar "True"))
(DTypeSig false "stripResolved" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "stripResolved" ((PCon "VTypedImpl" (PVar "t") (PVar "k") (PVar "p") (PVar "s") (PVar "inner"))) (EApp (EApp (EVar "stripBody") (EApp (EApp (EApp (EApp (EApp (EVar "VTypedImpl") (EVar "t")) (EVar "k")) (EVar "p")) (EVar "s")) (EVar "inner"))) (EVar "inner")))
(DFunDef false "stripResolved" ((PVar "v")) (EVar "v"))
(DTypeSig false "stripBody" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "stripBody" ((PVar "wrapper") (PCon "VThunk" (PVar "f"))) (EApp (EApp (EVar "stripBody") (EVar "wrapper")) (EApp (EVar "f") (ELit LUnit))))
(DFunDef false "stripBody" ((PVar "wrapper") (PCon "VTypedImpl" PWild PWild PWild PWild (PVar "inner"))) (EApp (EApp (EVar "stripBody") (EVar "wrapper")) (EVar "inner")))
(DFunDef false "stripBody" ((PVar "wrapper") (PVar "v")) (EIf (EApp (EVar "awaitsArgs") (EVar "v")) (EVar "wrapper") (EVar "v")))
(DTypeSig false "awaitsArgs" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool")))
(DFunDef false "awaitsArgs" ((PCon "VClosure" PWild PWild PWild)) (EVar "True"))
(DFunDef false "awaitsArgs" ((PCon "VClosureF" PWild PWild PWild)) (EVar "True"))
(DFunDef false "awaitsArgs" ((PCon "VPrim" PWild)) (EVar "True"))
(DFunDef false "awaitsArgs" ((PCon "VMulti" PWild)) (EVar "True"))
(DFunDef false "awaitsArgs" ((PCon "VTypedImpl" PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "awaitsArgs" (PWild) (EVar "False"))
(DTypeSig true "routeTag" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Route") (TyEffect () (Some "e") (TyCon "String")))))
(DFunDef false "routeTag" (PWild (PCon "RNone")) (ELit (LString "")))
(DFunDef false "routeTag" (PWild (PCon "RKey" (PVar "key") PWild)) (EVar "key"))
(DFunDef false "routeTag" ((PVar "env") (PCon "RDict" (PVar "d"))) (EMatch (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "d")) (arm (PCon "VDict" (PVar "key") PWild) () (EVar "key")) (arm PWild () (ELit (LString "")))))
(DFunDef false "routeTag" ((PVar "env") (PCon "RDictFwd" (PVar "d"))) (EMatch (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "d")) (arm (PCon "VDict" (PVar "key") PWild) () (EVar "key")) (arm PWild () (ELit (LString "")))))
(DFunDef false "routeTag" (PWild (PCon "RLocal" PWild PWild)) (ELit (LString "")))
(DFunDef false "routeTag" (PWild (PCon "RScalar" PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: RScalar is an arithmetic binop tag, not a dispatch route"))))
(DTypeSig true "applyDicts" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "applyDicts" (PWild (PVar "v") (PList)) (EVar "v"))
(DFunDef false "applyDicts" ((PVar "env") (PVar "v") (PCons (PVar "r") (PVar "rest"))) (EApp (EApp (EApp (EVar "applyDicts") (EVar "env")) (EApp (EApp (EVar "apply") (EVar "v")) (EApp (EApp (EVar "dictOfRoute") (EVar "env")) (EVar "r")))) (EVar "rest")))
(DTypeSig true "applyValues" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "applyValues" ((PVar "v") (PList)) (EVar "v"))
(DFunDef false "applyValues" ((PVar "v") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "applyValues") (EApp (EApp (EVar "apply") (EVar "v")) (EVar "x"))) (EVar "rest")))
(DTypeSig false "dictOfRoute" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Route") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "dictOfRoute" ((PVar "env") (PCon "RKey" (PVar "key") (PVar "reqs"))) (EApp (EApp (EVar "VDict") (EVar "key")) (EApp (EApp (EMethodRef "map") (EApp (EVar "dictOfRoute") (EVar "env"))) (EVar "reqs"))))
(DFunDef false "dictOfRoute" ((PVar "env") (PCon "RDict" (PVar "d"))) (EMatch (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "d")) (arm (PCon "VDict" (PVar "key") (PVar "reqs")) () (EApp (EApp (EVar "VDict") (EVar "key")) (EVar "reqs"))) (arm PWild () (EApp (EApp (EVar "VDict") (ELit (LString ""))) (EListLit)))))
(DFunDef false "dictOfRoute" ((PVar "env") (PCon "RDictFwd" (PVar "d"))) (EMatch (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "d")) (arm (PCon "VDict" (PVar "key") (PVar "reqs")) () (EApp (EApp (EVar "VDict") (EVar "key")) (EVar "reqs"))) (arm PWild () (EApp (EApp (EVar "VDict") (ELit (LString ""))) (EListLit)))))
(DFunDef false "dictOfRoute" (PWild (PCon "RNone")) (EApp (EApp (EVar "VDict") (ELit (LString ""))) (EListLit)))
(DFunDef false "dictOfRoute" (PWild (PCon "RLocal" PWild PWild)) (EApp (EApp (EVar "VDict") (ELit (LString ""))) (EListLit)))
(DFunDef false "dictOfRoute" (PWild (PCon "RScalar" PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: RScalar is an arithmetic binop tag, not a dispatch route"))))
(DTypeSig true "methodAtNarrow" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Route") (TyEffect () (Some "e") (TyTuple (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "methodAtNarrow" (PWild (PVar "v") (PCon "RNone")) (ETuple (EVar "v") (EListLit)))
(DFunDef false "methodAtNarrow" (PWild (PVar "v") (PCon "RKey" (PVar "key") PWild)) (ETuple (EApp (EApp (EVar "narrowMethod") (EVar "v")) (EVar "key")) (EListLit)))
(DFunDef false "methodAtNarrow" ((PVar "env") (PVar "v") (PCon "RDict" (PVar "d"))) (EMatch (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "d")) (arm (PCon "VDict" (PVar "key") (PVar "reqs")) () (ETuple (EApp (EApp (EVar "narrowMethod") (EVar "v")) (EVar "key")) (EVar "reqs"))) (arm PWild () (ETuple (EVar "v") (EListLit)))))
(DFunDef false "methodAtNarrow" ((PVar "env") (PVar "v") (PCon "RDictFwd" (PVar "d"))) (EMatch (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "d")) (arm (PCon "VDict" (PVar "key") (PVar "reqs")) () (ETuple (EApp (EApp (EVar "narrowMethod") (EVar "v")) (EVar "key")) (EVar "reqs"))) (arm PWild () (ETuple (EVar "v") (EListLit)))))
(DFunDef false "methodAtNarrow" (PWild (PVar "v") (PCon "RLocal" PWild PWild)) (ETuple (EVar "v") (EListLit)))
(DFunDef false "methodAtNarrow" (PWild PWild (PCon "RScalar" PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: RScalar is an arithmetic binop tag, not a dispatch route"))))
(DTypeSig false "oneOrMultiV" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "oneOrMultiV" ((PList (PVar "v")) PWild) (EVar "v"))
(DFunDef false "oneOrMultiV" ((PList) (PVar "original")) (EApp (EVar "VMulti") (EVar "original")))
(DFunDef false "oneOrMultiV" ((PVar "many") PWild) (EApp (EVar "VMulti") (EVar "many")))
(DTypeSig false "hasTag" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "hasTag" ((PVar "tag") (PCon "VTypedImpl" (PVar "t") (PVar "k") PWild PWild PWild)) (EBinOp "||" (EBinOp "==" (EVar "t") (EVar "tag")) (EBinOp "==" (EVar "k") (EVar "tag"))))
(DFunDef false "hasTag" (PWild PWild) (EVar "False"))
(DTypeSig false "matchesTag" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool"))))
(DFunDef false "matchesTag" ((PVar "tag") (PCon "VTypedImpl" (PVar "t") (PVar "k") PWild PWild PWild)) (EBinOp "||" (EBinOp "==" (EVar "t") (EVar "tag")) (EBinOp "==" (EVar "k") (EVar "tag"))))
(DFunDef false "matchesTag" (PWild PWild) (EVar "True"))
(DTypeSig false "applyClosure" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "applyClosure" (PWild (PList) PWild PWild) (EApp (EVar "panic") (ELit (LString "applied closure with no parameters"))))
(DFunDef false "applyClosure" ((PVar "env") (PList (PVar "p")) (PVar "body") (PVar "arg")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "p")) (EVar "arg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "binds")) () (EApp (EVar "fallthroughToNone") (EApp (EApp (EVar "eval") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "body"))))))
(DFunDef false "applyClosure" ((PVar "env") (PCons (PVar "p") (PVar "ps")) (PVar "body") (PVar "arg")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "binds")) (EApp (EApp (EApp (EVar "VClosure") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "ps")) (EVar "body")))) (EApp (EApp (EVar "matchPat") (EVar "p")) (EVar "arg"))))
(DTypeSig true "applyClosureF" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "applyClosureF" (PWild (PList) PWild PWild) (EApp (EVar "panic") (ELit (LString "applied closure with no parameters"))))
(DFunDef false "applyClosureF" ((PVar "env") (PList (PVar "p")) (PVar "f") (PVar "arg")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "p")) (EVar "arg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "binds")) () (EApp (EVar "fallthroughToNone") (EApp (EVar "f") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds")))))))
(DFunDef false "applyClosureF" ((PVar "env") (PCons (PVar "p") (PVar "ps")) (PVar "f") (PVar "arg")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "binds")) (EApp (EApp (EApp (EVar "VClosureF") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "ps")) (EVar "f")))) (EApp (EApp (EVar "matchPat") (EVar "p")) (EVar "arg"))))
(DTypeSig false "fallthroughToNone" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "fallthroughToNone" ((PCon "VFallthrough")) (EVar "None"))
(DFunDef false "fallthroughToNone" ((PVar "v")) (EApp (EVar "Some") (EVar "v")))
(DTypeSig false "collectPartials" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "collectPartials" ((PList) (PList) PWild) (EApp (EVar "panic") (ELit (LString "no matching impl for dispatch"))))
(DFunDef false "collectPartials" ((PList (PVar "v")) (PList) PWild) (EApp (EVar "Some") (EVar "v")))
(DFunDef false "collectPartials" ((PVar "many") (PList) PWild) (EApp (EVar "Some") (EApp (EVar "VMulti") (EApp (EVar "reverseL") (EVar "many")))))
(DFunDef false "collectPartials" ((PVar "acc") (PCons (PVar "v") (PVar "rest")) (PVar "arg")) (EMatch (EApp (EApp (EVar "applyOpt") (EVar "v")) (EVar "arg")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "collectPartials") (EVar "acc")) (EVar "rest")) (EVar "arg"))) (arm (PCon "Some" (PVar "r")) () (EIf (EApp (EVar "isPartial") (EVar "r")) (EApp (EApp (EApp (EVar "collectPartials") (EBinOp "::" (EVar "r") (EVar "acc"))) (EVar "rest")) (EVar "arg")) (EApp (EVar "Some") (EVar "r"))))))
(DTypeSig false "isPartial" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Bool")))
(DFunDef false "isPartial" ((PCon "VClosure" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isPartial" ((PCon "VClosureF" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isPartial" ((PCon "VPrim" PWild)) (EVar "True"))
(DFunDef false "isPartial" ((PCon "VMulti" PWild)) (EVar "True"))
(DFunDef false "isPartial" ((PCon "VTypedImpl" PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isPartial" (PWild) (EVar "False"))
(DTypeSig true "eval" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "eval" (PWild (PCon "ELit" (PCon "LInt" (PVar "n")))) (EApp (EVar "VInt") (EVar "n")))
(DFunDef false "eval" (PWild (PCon "ENumLit" (PVar "n") (PVar "r") PWild)) (EMatch (EFieldAccess (EVar "r") "value") (arm (PCon "Some" (PVar "f")) () (EApp (EVar "VFloat") (EVar "f"))) (arm (PCon "None") () (EApp (EVar "VInt") (EVar "n")))))
(DFunDef false "eval" (PWild (PCon "ELit" (PCon "LFloat" (PVar "f")))) (EApp (EVar "VFloat") (EVar "f")))
(DFunDef false "eval" (PWild (PCon "ELit" (PCon "LString" (PVar "s")))) (EApp (EVar "VString") (EVar "s")))
(DFunDef false "eval" (PWild (PCon "ELit" (PCon "LChar" (PVar "c")))) (EApp (EVar "VChar") (EVar "c")))
(DFunDef false "eval" (PWild (PCon "ELit" (PCon "LBool" (PVar "b")))) (EApp (EVar "VBool") (EVar "b")))
(DFunDef false "eval" (PWild (PCon "ELit" (PCon "LUnit"))) (EVar "VUnit"))
(DFunDef false "eval" ((PVar "env") (PCon "EVar" (PVar "x"))) (EIf (EApp (EVar "startsWithAt") (EVar "x")) (EVar "VUnit") (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "x"))))
(DFunDef false "eval" ((PVar "env") (PCon "EVarAt" (PVar "x") (PVar "addr"))) (EIf (EApp (EVar "startsWithAt") (EVar "x")) (EVar "VUnit") (EApp (EApp (EApp (EVar "lookupAtAddr") (EVar "env")) (EVar "x")) (EVar "addr"))))
(DFunDef false "eval" ((PVar "env") (PCon "EMethodAt" (PVar "name") (PVar "routeRef") (PVar "implRef") (PVar "methodRef"))) (EApp (EApp (EApp (EApp (EApp (EVar "evalMethodAt") (EVar "env")) (EVar "name")) (EFieldAccess (EVar "routeRef") "value")) (EFieldAccess (EVar "implRef") "value")) (EFieldAccess (EVar "methodRef") "value")))
(DFunDef false "eval" ((PVar "env") (PCon "EDictAt" (PVar "name") (PVar "routesRef"))) (EApp (EApp (EApp (EVar "applyDicts") (EVar "env")) (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "name"))) (EFieldAccess (EVar "routesRef") "value")))
(DFunDef false "eval" ((PVar "env") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "apply") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "f"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "x"))))
(DFunDef false "eval" ((PVar "env") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "VClosure") (EVar "env")) (EVar "pats")) (EVar "body")))
(DFunDef false "eval" ((PVar "env") (PCon "ELet" PWild (PCon "True") (PCon "PVar" (PVar "f")) (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "evalRecLet") (EVar "env")) (EVar "f")) (EVar "e1")) (EVar "e2")))
(DFunDef false "eval" ((PVar "env") (PCon "ELet" PWild PWild (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "evalLet") (EVar "env")) (EVar "pat")) (EVar "e1")) (EVar "e2")))
(DFunDef false "eval" ((PVar "env") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EVar "evalLetGroup") (EVar "env")) (EVar "binds")) (EVar "body")))
(DFunDef false "eval" ((PVar "env") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EVar "evalMatch") (EVar "env")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "eval" ((PVar "env") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "evalIf") (EVar "env")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "c"))) (EVar "t")) (EVar "e")))
(DFunDef false "eval" ((PVar "env") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") PWild)) (EApp (EApp (EApp (EApp (EVar "evalBinop") (EVar "env")) (EVar "op")) (EVar "l")) (EVar "r")))
(DFunDef false "eval" ((PVar "env") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EVar "apply") (EApp (EApp (EVar "apply") (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EVar "op"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l")))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r"))))
(DFunDef false "eval" ((PVar "env") (PCon "EUnOp" (PVar "op") (PVar "e") PWild)) (EApp (EApp (EVar "evalUnop") (EVar "op")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))))
(DFunDef false "eval" ((PVar "env") (PCon "ETuple" (PVar "es"))) (EApp (EVar "VTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "eval") (EVar "env"))) (EVar "es"))))
(DFunDef false "eval" ((PVar "env") (PCon "EListLit" (PVar "es"))) (EApp (EVar "VList") (EApp (EApp (EMethodRef "map") (EApp (EVar "eval") (EVar "env"))) (EVar "es"))))
(DFunDef false "eval" ((PVar "env") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EApp (EVar "eval") (EVar "env"))) (EVar "es")))))
(DFunDef false "eval" ((PVar "env") (PCon "ERecordCreate" (PVar "name") (PVar "fields"))) (EBlock (DoLet false false (PVar "assigns") (EApp (EApp (EMethodRef "map") (EApp (EVar "evalFieldAssign") (EVar "env"))) (EVar "fields"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "ctorFieldOrdersRef") "value")) (arm (PCon "Some" (PVar "order")) () (EApp (EApp (EVar "VCon") (EVar "name")) (EApp (EApp (EApp (EVar "recordCreateVals") (EVar "name")) (EVar "order")) (EVar "assigns")))) (arm (PCon "None") () (EApp (EApp (EVar "VRecord") (EVar "name")) (EVar "assigns")))))))
(DFunDef false "eval" ((PVar "env") (PCon "ERecordUpdate" (PVar "base") (PVar "fields") PWild)) (EApp (EApp (EVar "evalRecordUpdate") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "evalFieldAssign") (EVar "env"))) (EVar "fields"))))
(DFunDef false "eval" ((PVar "env") (PCon "EVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "evalVariantUpdate") (EVar "con")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "evalFieldAssign") (EVar "env"))) (EVar "fields"))))
(DFunDef false "eval" ((PVar "env") (PCon "EFieldAccess" (PVar "e") (PLit (LString "value")) PWild)) (EApp (EVar "evalValueField") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))))
(DFunDef false "eval" ((PVar "env") (PCon "EFieldAccess" (PVar "e") (PVar "field") PWild)) (EApp (EApp (EVar "evalField") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))) (EVar "field")))
(DFunDef false "eval" ((PVar "env") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))
(DFunDef false "eval" ((PVar "env") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))
(DFunDef false "eval" ((PVar "env") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "evalBlock") (EVar "env")) (EVar "stmts")))
(DFunDef false "eval" ((PVar "env") (PCon "ESlice" (PVar "arr") (PVar "lo") (PVar "hi") (PVar "incl") PWild)) (EApp (EApp (EApp (EApp (EVar "evalSlice") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "arr"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "eval" ((PVar "env") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "evalRange") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "hi"))) (EVar "incl")) (EVar "rangeListMk")))
(DFunDef false "eval" ((PVar "env") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "evalRange") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "hi"))) (EVar "incl")) (EVar "rangeArrayMk")))
(DFunDef false "eval" ((PVar "env") (PCon "ELoc" (PVar "l") (PVar "e"))) (EBlock (DoLet false false PWild (EApp (EVar "updateEvalLoc") (EVar "l"))) (DoExpr (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))))
(DFunDef false "eval" ((PVar "env") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))
(DFunDef false "eval" (PWild PWild) (EApp (EVar "panic") (ELit (LString "eval: unsupported node (slice 2)"))))
(DTypeSig false "evalMethodAt" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyCon "Route") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "evalMethodAt" ((PVar "env") (PVar "name") (PCon "RLocal" (PVar "sym") (PVar "dicts")) PWild PWild) (EApp (EApp (EApp (EVar "applyDicts") (EVar "env")) (EApp (EApp (EVar "lookupEnv") (EVar "env")) (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EVar "name") (EVar "sym")))) (EVar "dicts")))
(DFunDef false "evalMethodAt" ((PVar "env") (PVar "name") (PVar "route") (PVar "implRoutes") (PVar "methodRoutes")) (EBlock (DoLet false false (PVar "lm") (EApp (EApp (EVar "lookupMethod") (EVar "env")) (EVar "name"))) (DoLet false false (PTuple (PVar "narrowed") (PVar "fwdReqs0")) (EApp (EApp (EApp (EVar "methodAtNarrow") (EVar "env")) (EVar "lm")) (EVar "route"))) (DoLet false false (PVar "fwdReqs") (EApp (EApp (EVar "takeN") (EApp (EApp (EVar "lookupMethodReqCount") (EVar "name")) (EApp (EApp (EVar "routeTag") (EVar "env")) (EVar "route")))) (EVar "fwdReqs0"))) (DoExpr (EIf (EApp (EVar "awaitsArgs") (EVar "narrowed")) (EBlock (DoLet false false (PVar "v1") (EApp (EApp (EApp (EVar "applyDicts") (EVar "env")) (EVar "narrowed")) (EVar "methodRoutes"))) (DoLet false false (PVar "v2") (EApp (EApp (EApp (EVar "applyDicts") (EVar "env")) (EVar "v1")) (EVar "implRoutes"))) (DoExpr (EApp (EApp (EVar "applyValues") (EVar "v2")) (EVar "fwdReqs")))) (EVar "narrowed")))))
(DTypeSig true "evalIndex" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "evalIndex" ((PVar "container") (PCon "VInt" (PVar "i"))) (EApp (EApp (EVar "evalIndexInt") (EVar "container")) (EVar "i")))
(DFunDef false "evalIndex" (PWild PWild) (EApp (EVar "panic") (ELit (LString "index is not an Int"))))
(DTypeSig false "evalIndexInt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "evalIndexInt" ((PCon "VArray" (PVar "a")) (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "a")))) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-INDEX-OOB"))) (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EVar "intToString") (EVar "i"))) (ELit (LString " out of bounds")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "evalIndexInt" ((PCon "VList" (PVar "vs")) (PVar "i")) (EApp (EApp (EApp (EVar "listNthAt") (EVar "vs")) (EVar "i")) (EVar "i")))
(DFunDef false "evalIndexInt" ((PCon "VString" (PVar "s")) (PVar "i")) (EApp (EApp (EVar "stringIndexCp") (EVar "s")) (EVar "i")))
(DFunDef false "evalIndexInt" (PWild PWild) (EApp (EVar "panic") (ELit (LString "index on non-array/list/string"))))
(DTypeSig false "stringIndexCp" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "stringIndexCp" ((PVar "s") (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "stringLength") (EVar "s")))) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-INDEX-OOB"))) (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EVar "intToString") (EVar "i"))) (ELit (LString " out of bounds")))) (EIf (EVar "otherwise") (EApp (EVar "VChar") (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EApp (EVar "stringToChars") (EVar "s"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "evalSlice" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Bool") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalSlice" ((PVar "container") (PCon "VInt" (PVar "lo")) (PCon "VInt" (PVar "hi")) (PVar "incl")) (EApp (EApp (EApp (EApp (EVar "evalSliceInt") (EVar "container")) (EVar "lo")) (EVar "hi")) (EVar "incl")))
(DFunDef false "evalSlice" (PWild PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "slice index must be Int"))))
(DTypeSig false "evalSliceInt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalSliceInt" ((PCon "VArray" (PVar "a")) (PVar "lo") (PVar "hi") (PVar "incl")) (EApp (EApp (EApp (EVar "sliceArray") (EVar "a")) (EVar "lo")) (EIf (EVar "incl") (EBinOp "+" (EVar "hi") (ELit (LInt 1))) (EVar "hi"))))
(DFunDef false "evalSliceInt" ((PCon "VList" (PVar "vs")) (PVar "lo") (PVar "hi") (PVar "incl")) (EApp (EVar "VList") (EApp (EApp (EApp (EVar "listSliceV") (EVar "vs")) (EVar "lo")) (EIf (EVar "incl") (EBinOp "+" (EVar "hi") (ELit (LInt 1))) (EVar "hi")))))
(DFunDef false "evalSliceInt" ((PCon "VString" (PVar "s")) (PVar "lo") (PVar "hi") (PVar "incl")) (EApp (EVar "VString") (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EIf (EVar "incl") (EBinOp "+" (EVar "hi") (ELit (LInt 1))) (EVar "hi"))) (EVar "s"))))
(DFunDef false "evalSliceInt" (PWild PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "slice on non-array/list/string"))))
(DTypeSig false "sliceArray" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "sliceArray" ((PVar "a") (PVar "lo") (PVar "hiX")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (EBinOp ">" (EVar "hiX") (EApp (EVar "arrayLength") (EVar "a")))) (EBinOp "<" (EBinOp "-" (EVar "hiX") (EVar "lo")) (ELit (LInt 0)))) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-SLICE-OOB"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "slice [")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "lo")))) (ELit (LString ".."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "-" (EVar "hiX") (ELit (LInt 1)))))) (ELit (LString "] out of bounds")))) (EIf (EVar "otherwise") (EApp (EVar "VArray") (EApp (EApp (EVar "arrayMakeWith") (EBinOp "-" (EVar "hiX") (EVar "lo"))) (ELam ((PVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "lo") (EVar "i"))) (EVar "a"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "evalRange" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Bool") (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalRange" ((PCon "VInt" (PVar "lo")) (PCon "VInt" (PVar "hi")) (PVar "incl") (PVar "mk")) (EApp (EVar "mk") (EApp (EApp (EVar "intSeq") (EVar "lo")) (EIf (EVar "incl") (EBinOp "+" (EVar "hi") (ELit (LInt 1))) (EVar "hi")))))
(DFunDef false "evalRange" (PWild PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "range bound must be Int"))))
(DTypeSig true "rangeListMk" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "rangeListMk" ((PVar "ns")) (EApp (EVar "VList") (EApp (EApp (EMethodRef "map") (EVar "VInt")) (EVar "ns"))))
(DTypeSig true "rangeArrayMk" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "rangeArrayMk" ((PVar "ns")) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "VInt")) (EVar "ns")))))
(DTypeSig false "evalFieldAssign" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "FieldAssign") (TyEffect () (Some "e") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalFieldAssign" ((PVar "env") (PCon "FieldAssign" (PVar "k") (PVar "e"))) (ETuple (EVar "k") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))))
(DTypeSig false "recordCreateVals" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "recordCreateVals" (PWild (PList) PWild) (EListLit))
(DFunDef false "recordCreateVals" ((PVar "con") (PCons (PVar "f") (PVar "fs")) (PVar "assigns")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "f")) (EVar "assigns")) (arm (PCon "Some" (PVar "v")) () (EBinOp "::" (EVar "v") (EApp (EApp (EApp (EVar "recordCreateVals") (EVar "con")) (EVar "fs")) (EVar "assigns")))) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "missing field: ")) (EVar "f"))))))
(DTypeSig true "evalRecordUpdate" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "evalRecordUpdate" ((PCon "VRecord" (PVar "name") (PVar "existing")) (PVar "updates")) (EApp (EApp (EVar "VRecord") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mergeField") (EVar "updates"))) (EVar "existing"))))
(DFunDef false "evalRecordUpdate" (PWild PWild) (EApp (EVar "panic") (ELit (LString "record update on non-record"))))
(DTypeSig false "mergeField" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))) (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "mergeField" ((PVar "updates") (PTuple (PVar "k") (PVar "v"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "k")) (EVar "updates")) (arm (PCon "Some" (PVar "v2")) () (ETuple (EVar "k") (EVar "v2"))) (arm (PCon "None") () (ETuple (EVar "k") (EVar "v")))))
(DTypeSig true "evalVariantUpdate" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "evalVariantUpdate" ((PVar "con") (PCon "VCon" (PVar "con'") (PVar "vals")) (PVar "updates")) (EIf (EBinOp "==" (EVar "con") (EVar "con'")) (EApp (EApp (EVar "VCon") (EVar "con")) (EApp (EApp (EApp (EVar "applyVariantUpdates") (EVar "updates")) (EApp (EVar "ctorFieldOrderFor") (EVar "con"))) (EVar "vals"))) (EIf (EVar "otherwise") (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evalVariantUpdate: expected ")) (EApp (EMethodRef "display") (EVar "con"))) (ELit (LString " got "))) (EApp (EMethodRef "display") (EVar "con'"))) (ELit (LString "")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "evalVariantUpdate" ((PVar "con") (PCon "VRecord" (PVar "con'") (PVar "fields")) (PVar "updates")) (EIf (EBinOp "==" (EVar "con") (EVar "con'")) (EApp (EApp (EVar "VRecord") (EVar "con'")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mergeField") (EVar "updates"))) (EVar "fields"))) (EIf (EVar "otherwise") (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evalVariantUpdate: expected ")) (EApp (EMethodRef "display") (EVar "con"))) (ELit (LString " got "))) (EApp (EMethodRef "display") (EVar "con'"))) (ELit (LString "")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "evalVariantUpdate" ((PVar "con") (PVar "v") PWild) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evalVariantUpdate: not a constructor: ")) (EApp (EMethodRef "display") (EVar "con"))) (ELit (LString " got "))) (EApp (EMethodRef "display") (EApp (EVar "ppValue") (EVar "v")))) (ELit (LString "")))))
(DTypeSig false "ctorFieldOrderFor" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ctorFieldOrderFor" ((PVar "con")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "con")) (EFieldAccess (EVar "ctorFieldOrdersRef") "value")) (arm (PCon "Some" (PVar "fs")) () (EVar "fs")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "evalVariantUpdate: unknown constructor ")) (EVar "con"))))))
(DTypeSig false "applyVariantUpdates" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "applyVariantUpdates" (PWild (PList) PWild) (EListLit))
(DFunDef false "applyVariantUpdates" (PWild PWild (PList)) (EListLit))
(DFunDef false "applyVariantUpdates" ((PVar "updates") (PCons (PVar "f") (PVar "fs")) (PCons (PVar "v") (PVar "vs"))) (EBinOp "::" (EApp (EApp (EApp (EVar "applyFieldUpdate") (EVar "updates")) (EVar "f")) (EVar "v")) (EApp (EApp (EApp (EVar "applyVariantUpdates") (EVar "updates")) (EVar "fs")) (EVar "vs"))))
(DTypeSig false "applyFieldUpdate" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "applyFieldUpdate" ((PVar "updates") (PVar "field") (PVar "old")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "field")) (EVar "updates")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EVar "old"))))
(DTypeSig true "evalValueField" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "evalValueField" ((PCon "VRef" (PVar "cell"))) (EFieldAccess (EVar "cell") "value"))
(DFunDef false "evalValueField" ((PCon "VRecord" PWild (PVar "fields"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (ELit (LString "value"))) (EVar "fields")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "record has no field 'value'"))))))
(DFunDef false "evalValueField" (PWild) (EApp (EVar "panic") (ELit (LString "field access on non-record/ref"))))
(DTypeSig true "evalField" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "evalField" ((PCon "VRecord" PWild (PVar "fields")) (PVar "field")) (EApp (EApp (EVar "fieldOr") (EVar "fields")) (EVar "field")))
(DFunDef false "evalField" (PWild PWild) (EApp (EVar "panic") (ELit (LString "field access on non-record"))))
(DTypeSig false "fieldOr" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "fieldOr" ((PVar "fields") (PVar "field")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "field")) (EVar "fields")) (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (ELit (LString "unknown field: ")) (EVar "field"))))))
(DTypeSig false "evalBlock" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "evalBlock" (PWild (PList)) (EVar "VUnit"))
(DFunDef false "evalBlock" ((PVar "env") (PList (PCon "DoExpr" (PVar "e")))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))
(DFunDef false "evalBlock" ((PVar "env") (PList (PCon "DoLet" PWild PWild (PVar "pat") (PVar "e")))) (EApp (EApp (EApp (EVar "blockLetLast") (EVar "env")) (EVar "pat")) (EVar "e")))
(DFunDef false "evalBlock" ((PVar "env") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))) (DoExpr (EApp (EApp (EVar "evalBlock") (EVar "env")) (EVar "rest")))))
(DFunDef false "evalBlock" ((PVar "env") (PCons (PCon "DoLet" PWild (PCon "True") (PCon "PVar" (PVar "f")) (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "blockRecLet") (EVar "env")) (EVar "f")) (EVar "e")) (EVar "rest")))
(DFunDef false "evalBlock" ((PVar "env") (PCons (PCon "DoLet" PWild PWild (PVar "pat") (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "blockLet") (EVar "env")) (EVar "pat")) (EVar "e")) (EVar "rest")))
(DFunDef false "evalBlock" ((PVar "env") (PList (PCon "DoAssign" PWild (PVar "e")))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "evalBlock" ((PVar "env") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EApp (EApp (EVar "evalBlock") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EListLit (ETuple (EVar "x") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))))) (EVar "rest")))
(DFunDef false "evalBlock" (PWild (PCons PWild PWild)) (EApp (EVar "panic") (ELit (LString "eval: unsupported block statement"))))
(DTypeSig false "blockLetLast" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "blockLetLast" ((PVar "env") (PVar "pat") (PVar "e")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-LET-REFUTE"))) (ELit (LString "let pattern match failed")))) (arm (PCon "Some" PWild) () (EVar "VUnit"))))
(DTypeSig false "blockRecLet" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "blockRecLet" ((PVar "env") (PVar "f") (PVar "e") (PVar "rest")) (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EVar "VUnit"))) (DoLet false false (PVar "recEnv") (EApp (EApp (EVar "pushFrame") (EVar "env")) (EListLit (ETuple (EVar "f") (EVar "cell"))))) (DoLet false false (PVar "v") (EApp (EApp (EVar "eval") (EVar "recEnv")) (EVar "e"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cell")) (EVar "v"))) (DoExpr (EApp (EApp (EVar "evalBlock") (EVar "recEnv")) (EVar "rest")))))
(DTypeSig false "blockLet" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "blockLet" ((PVar "env") (PVar "pat") (PVar "e") (PVar "rest")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-LET-REFUTE"))) (ELit (LString "let pattern match failed")))) (arm (PCon "Some" (PVar "binds")) () (EApp (EApp (EVar "evalBlock") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "rest")))))
(DTypeSig false "evalRecLet" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalRecLet" ((PVar "env") (PVar "f") (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "cell") (EApp (EVar "Ref") (EVar "VUnit"))) (DoLet false false (PVar "recEnv") (EApp (EApp (EVar "pushFrame") (EVar "env")) (EListLit (ETuple (EVar "f") (EVar "cell"))))) (DoLet false false (PVar "v") (EApp (EApp (EVar "eval") (EVar "recEnv")) (EVar "e1"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cell")) (EVar "v"))) (DoExpr (EApp (EApp (EVar "eval") (EVar "recEnv")) (EVar "e2")))))
(DTypeSig false "evalLet" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalLet" ((PVar "env") (PVar "pat") (PVar "e1") (PVar "e2")) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e1"))) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-LET-REFUTE"))) (ELit (LString "let pattern match failed")))) (arm (PCon "Some" (PVar "binds")) () (EApp (EApp (EVar "eval") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "e2")))))
(DTypeSig false "evalLetGroup" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalLetGroup" ((PVar "env") (PVar "binds") (PVar "body")) (EBlock (DoLet false false (PVar "cells") (EApp (EApp (EMethodRef "map") (EVar "letBindCell")) (EVar "binds"))) (DoLet false false (PVar "env2") (EApp (EApp (EVar "pushFrame") (EVar "env")) (EVar "cells"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "installGroup") (EVar "env2")) (EVar "cells")) (EVar "binds"))) (DoExpr (EApp (EApp (EVar "eval") (EVar "env2")) (EVar "body")))))
(DTypeSig false "letBindCell" (TyFun (TyCon "LetBind") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "letBindCell" ((PCon "LetBind" (PVar "name") PWild)) (ETuple (EVar "name") (EApp (EVar "Ref") (EVar "VUnit"))))
(DTypeSig false "installGroup" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyEffect () (Some "e") (TyCon "Unit"))))))
(DFunDef false "installGroup" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "installGroup" ((PVar "env") (PVar "cells") (PCons (PCon "LetBind" (PVar "name") (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EApp (EApp (EVar "findCell") (EVar "cells")) (EVar "name"))) (EApp (EApp (EVar "groupValue") (EVar "env")) (EApp (EApp (EMethodRef "map") (EVar "funClauseToClause")) (EVar "clauses"))))) (DoExpr (EApp (EApp (EApp (EVar "installGroup") (EVar "env")) (EVar "cells")) (EVar "rest")))))
(DTypeSig false "funClauseToClause" (TyFun (TyCon "FunClause") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))
(DFunDef false "funClauseToClause" ((PCon "FunClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "pats") (EVar "body")))
(DTypeSig false "groupValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "groupValue" ((PVar "env") (PList (PTuple (PVar "pats") (PVar "body")))) (EIf (EApp (EVar "isNullary") (EVar "pats")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "VClosure") (EVar "env")) (EVar "pats")) (EVar "body")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "groupValue" ((PVar "env") (PVar "clauses")) (EApp (EVar "VMulti") (EApp (EApp (EMethodRef "map") (EApp (EVar "clauseClosure") (EVar "env"))) (EVar "clauses"))))
(DTypeSig false "topGroupValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "topGroupValue" ((PVar "env") (PList (PTuple (PVar "pats") (PVar "body")))) (EIf (EApp (EVar "isNullary") (EVar "pats")) (EApp (EVar "VThunk") (ELam (PWild) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "VClosure") (EVar "env")) (EVar "pats")) (EVar "body")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "topGroupValue" ((PVar "env") (PVar "clauses")) (EApp (EVar "VMulti") (EApp (EApp (EMethodRef "map") (EApp (EVar "clauseClosure") (EVar "env"))) (EVar "clauses"))))
(DTypeSig false "clauseClosure" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "clauseClosure" ((PVar "env") (PTuple (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "VClosure") (EVar "env")) (EVar "pats")) (EVar "body")))
(DTypeSig true "isNullary" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool")))
(DFunDef false "isNullary" ((PList)) (EVar "True"))
(DFunDef false "isNullary" (PWild) (EVar "False"))
(DTypeSig false "evalMatch" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalMatch" (PWild PWild (PList)) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-NONEXHAUSTIVE-MATCH"))) (ELit (LString "non-exhaustive match"))))
(DFunDef false "evalMatch" ((PVar "env") (PVar "sv") (PCons (PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "matchPat") (EVar "pat")) (EVar "sv")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "evalMatch") (EVar "env")) (EVar "sv")) (EVar "rest"))) (arm (PCon "Some" (PVar "binds")) () (EMatch (EApp (EApp (EVar "runGuards") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "binds"))) (EVar "guards")) (arm (PCon "Some" (PVar "env2")) () (EApp (EApp (EVar "eval") (EVar "env2")) (EVar "body"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "evalMatch") (EVar "env")) (EVar "sv")) (EVar "rest")))))))
(DTypeSig false "runGuards" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyEffect () (Some "e") (TyApp (TyCon "Option") (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "runGuards" ((PVar "env") (PList)) (EApp (EVar "Some") (EVar "env")))
(DFunDef false "runGuards" ((PVar "env") (PCons (PCon "GBool" (PVar "g")) (PVar "qs"))) (EMatch (EApp (EApp (EVar "eval") (EVar "env")) (EVar "g")) (arm (PCon "VBool" (PCon "True")) () (EApp (EApp (EVar "runGuards") (EVar "env")) (EVar "qs"))) (arm (PCon "VCon" (PLit (LString "True")) (PList)) () (EApp (EApp (EVar "runGuards") (EVar "env")) (EVar "qs"))) (arm PWild () (EVar "None"))))
(DFunDef false "runGuards" ((PVar "env") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "qs"))) (EMatch (EApp (EApp (EVar "matchPat") (EVar "p")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e"))) (arm (PCon "Some" (PVar "b")) () (EApp (EApp (EVar "runGuards") (EApp (EApp (EVar "extendEnv") (EVar "env")) (EVar "b"))) (EVar "qs"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "evalIf" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalIf" ((PVar "env") (PCon "VBool" (PCon "True")) (PVar "t") PWild) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "t")))
(DFunDef false "evalIf" ((PVar "env") (PCon "VCon" (PLit (LString "True")) (PList)) (PVar "t") PWild) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "t")))
(DFunDef false "evalIf" ((PVar "env") (PCon "VBool" (PCon "False")) PWild (PVar "e")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))
(DFunDef false "evalIf" ((PVar "env") (PCon "VCon" (PLit (LString "False")) (PList)) PWild (PVar "e")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "e")))
(DFunDef false "evalIf" (PWild PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "if condition is not a Bool"))))
(DTypeSig true "evalUnop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "evalUnop" ((PLit (LString "-")) (PCon "VInt" (PVar "n"))) (EApp (EVar "VInt") (EBinOp "-" (ELit (LInt 0)) (EVar "n"))))
(DFunDef false "evalUnop" ((PLit (LString "-")) (PCon "VFloat" (PVar "f"))) (EApp (EVar "VFloat") (EBinOp "-" (ELit (LFloat 0.0)) (EVar "f"))))
(DFunDef false "evalUnop" ((PLit (LString "-")) PWild) (EApp (EVar "panic") (ELit (LString "unary minus on non-number"))))
(DFunDef false "evalUnop" ((PLit (LString "!")) (PCon "VBool" (PVar "b"))) (EApp (EVar "VBool") (EApp (EVar "not") (EVar "b"))))
(DFunDef false "evalUnop" ((PLit (LString "!")) PWild) (EApp (EVar "panic") (ELit (LString "'!' on non-Bool"))))
(DFunDef false "evalUnop" ((PLit (LString "not")) (PCon "VBool" (PVar "b"))) (EApp (EVar "VBool") (EApp (EVar "not") (EVar "b"))))
(DFunDef false "evalUnop" ((PLit (LString "not")) PWild) (EApp (EVar "panic") (ELit (LString "'!' on non-Bool"))))
(DFunDef false "evalUnop" ((PVar "op") PWild) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "unknown unary op: ")) (EVar "op"))))
(DTypeSig false "evalBinop" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalBinop" ((PVar "env") (PLit (LString "|>")) (PVar "l") (PVar "r")) (EApp (EApp (EVar "apply") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))))
(DFunDef false "evalBinop" ((PVar "env") (PLit (LString ">>")) (PVar "l") (PVar "r")) (EApp (EApp (EVar "composeFwd") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r"))))
(DFunDef false "evalBinop" ((PVar "env") (PLit (LString "<<")) (PVar "l") (PVar "r")) (EApp (EApp (EVar "composeBwd") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r"))))
(DFunDef false "evalBinop" ((PVar "env") (PLit (LString "&&")) (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "evalAnd") (EVar "env")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))) (EVar "r")))
(DFunDef false "evalBinop" ((PVar "env") (PLit (LString "||")) (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "evalOr") (EVar "env")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))) (EVar "r")))
(DFunDef false "evalBinop" ((PVar "env") (PLit (LString "::")) (PVar "l") (PVar "r")) (EApp (EApp (EVar "consVal") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r"))))
(DFunDef false "evalBinop" ((PVar "env") (PLit (LString "++")) (PVar "l") (PVar "r")) (EApp (EApp (EVar "appendVal") (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r"))))
(DFunDef false "evalBinop" ((PVar "env") (PVar "op") (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "evalArith") (EVar "op")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "l"))) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r"))))
(DTypeSig false "composeFwd" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "composeFwd" ((PVar "fv") (PVar "gv")) (EApp (EVar "VPrim") (ELam ((PVar "x")) (EApp (EApp (EVar "apply") (EVar "gv")) (EApp (EApp (EVar "apply") (EVar "fv")) (EVar "x"))))))
(DTypeSig false "composeBwd" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "composeBwd" ((PVar "fv") (PVar "gv")) (EApp (EVar "VPrim") (ELam ((PVar "x")) (EApp (EApp (EVar "apply") (EVar "fv")) (EApp (EApp (EVar "apply") (EVar "gv")) (EVar "x"))))))
(DTypeSig false "evalAnd" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalAnd" (PWild (PCon "VBool" (PCon "False")) PWild) (EApp (EVar "VBool") (EVar "False")))
(DFunDef false "evalAnd" (PWild (PCon "VCon" (PLit (LString "False")) (PList)) PWild) (EApp (EVar "VBool") (EVar "False")))
(DFunDef false "evalAnd" ((PVar "env") (PCon "VBool" (PCon "True")) (PVar "r")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r")))
(DFunDef false "evalAnd" ((PVar "env") (PCon "VCon" (PLit (LString "True")) (PList)) (PVar "r")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r")))
(DFunDef false "evalAnd" (PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "'&&' on non-Bool"))))
(DTypeSig false "evalOr" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "evalOr" (PWild (PCon "VBool" (PCon "True")) PWild) (EApp (EVar "VBool") (EVar "True")))
(DFunDef false "evalOr" (PWild (PCon "VCon" (PLit (LString "True")) (PList)) PWild) (EApp (EVar "VBool") (EVar "True")))
(DFunDef false "evalOr" ((PVar "env") (PCon "VBool" (PCon "False")) (PVar "r")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r")))
(DFunDef false "evalOr" ((PVar "env") (PCon "VCon" (PLit (LString "False")) (PList)) (PVar "r")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "r")))
(DFunDef false "evalOr" (PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "'||' on non-Bool"))))
(DTypeSig true "consVal" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "consVal" ((PVar "hv") (PCon "VList" (PVar "xs"))) (EApp (EVar "VList") (EBinOp "::" (EVar "hv") (EVar "xs"))))
(DFunDef false "consVal" (PWild PWild) (EApp (EVar "panic") (ELit (LString "cons (::) rhs is not a list"))))
(DTypeSig true "appendVal" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "appendVal" ((PCon "VList" (PVar "a")) (PCon "VList" (PVar "b"))) (EApp (EVar "VList") (EBinOp "++" (EVar "a") (EVar "b"))))
(DFunDef false "appendVal" ((PCon "VString" (PVar "a")) (PCon "VString" (PVar "b"))) (EApp (EVar "VString") (EBinOp "++" (EVar "a") (EVar "b"))))
(DFunDef false "appendVal" (PWild PWild) (EApp (EVar "panic") (ELit (LString "'++' requires Semigroup (List, String, or a type with append)"))))
(DTypeSig true "evalArith" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "evalArith" ((PLit (LString "+")) (PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EBinOp "+" (EVar "a") (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "-")) (PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EBinOp "-" (EVar "a") (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "*")) (PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EBinOp "*" (EVar "a") (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "/")) (PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EIf (EBinOp "==" (EVar "b") (ELit (LInt 0))) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-DIV-ZERO"))) (ELit (LString "division by zero"))) (EIf (EVar "otherwise") (EApp (EVar "VInt") (EBinOp "/" (EVar "a") (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "evalArith" ((PLit (LString "%")) (PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EIf (EBinOp "==" (EVar "b") (ELit (LInt 0))) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-MOD-ZERO"))) (ELit (LString "modulo by zero"))) (EIf (EVar "otherwise") (EApp (EVar "VInt") (EBinOp "%" (EVar "a") (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "evalArith" ((PLit (LString "+")) (PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EBinOp "+" (EVar "a") (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "-")) (PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EBinOp "-" (EVar "a") (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "*")) (PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EBinOp "*" (EVar "a") (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "/")) (PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EBinOp "/" (EVar "a") (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "%")) (PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EApp (EApp (EVar "floatRem") (EVar "a")) (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "==")) (PVar "a") (PVar "b")) (EApp (EVar "VBool") (EApp (EApp (EVar "valueEq") (EVar "a")) (EVar "b"))))
(DFunDef false "evalArith" ((PLit (LString "!=")) (PVar "a") (PVar "b")) (EApp (EVar "VBool") (EApp (EVar "not") (EApp (EApp (EVar "valueEq") (EVar "a")) (EVar "b")))))
(DFunDef false "evalArith" ((PLit (LString "<")) (PVar "a") (PVar "b")) (EApp (EVar "VBool") (EApp (EVar "ordLt") (EApp (EApp (EVar "valueCompare") (EVar "a")) (EVar "b")))))
(DFunDef false "evalArith" ((PLit (LString ">")) (PVar "a") (PVar "b")) (EApp (EVar "VBool") (EApp (EVar "ordGt") (EApp (EApp (EVar "valueCompare") (EVar "a")) (EVar "b")))))
(DFunDef false "evalArith" ((PLit (LString "<=")) (PVar "a") (PVar "b")) (EApp (EVar "VBool") (EApp (EVar "not") (EApp (EVar "ordGt") (EApp (EApp (EVar "valueCompare") (EVar "a")) (EVar "b"))))))
(DFunDef false "evalArith" ((PLit (LString ">=")) (PVar "a") (PVar "b")) (EApp (EVar "VBool") (EApp (EVar "not") (EApp (EVar "ordLt") (EApp (EApp (EVar "valueCompare") (EVar "a")) (EVar "b"))))))
(DFunDef false "evalArith" ((PVar "op") PWild PWild) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown op '")) (EVar "op")) (ELit (LString "'")))))
(DTypeSig true "collectCtors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "collectCtors" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ctorsOfDecl")) (EVar "prog")))
(DTypeSig false "ctorsOfDecl" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "ctorsOfDecl" ((PCon "DData" PWild PWild PWild (PVar "variants") PWild)) (EApp (EApp (EMethodRef "map") (EVar "ctorEntry")) (EVar "variants")))
(DFunDef false "ctorsOfDecl" ((PCon "DNewtype" PWild PWild PWild (PVar "con") (PVar "fty") PWild)) (EListLit (EApp (EVar "ctorEntry") (EApp (EApp (EVar "Variant") (EVar "con")) (EApp (EVar "ConPos") (EListLit (EVar "fty")))))))
(DFunDef false "ctorsOfDecl" (PWild) (EListLit))
(DTypeSig false "ctorEntry" (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "ctorEntry" ((PCon "Variant" (PVar "n") (PVar "payload"))) (ETuple (EVar "n") (EApp (EApp (EVar "makeCtor") (EVar "n")) (EApp (EVar "payloadArity") (EVar "payload")))))
(DTypeSig true "payloadArity" (TyFun (TyCon "ConPayload") (TyCon "Int")))
(DFunDef false "payloadArity" ((PCon "ConPos" (PVar "tys"))) (EApp (EVar "listLen") (EVar "tys")))
(DFunDef false "payloadArity" ((PCon "ConNamed" (PVar "fs") PWild)) (EApp (EVar "listLen") (EVar "fs")))
(DTypeSig false "funDefs" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "funDefs" ((PList)) (EListLit))
(DFunDef false "funDefs" ((PCons (PCon "DFunDef" PWild (PVar "n") (PVar "pats") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (ETuple (EVar "pats") (EVar "body"))) (EApp (EVar "funDefs") (EVar "rest"))))
(DFunDef false "funDefs" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "letGroupDefs") (EVar "binds")) (EApp (EVar "funDefs") (EVar "rest"))))
(DFunDef false "funDefs" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "funDefs") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "funDefs" ((PCons PWild (PVar "rest"))) (EApp (EVar "funDefs") (EVar "rest")))
(DTypeSig false "letGroupDefs" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "letGroupDefs" ((PList)) (EListLit))
(DFunDef false "letGroupDefs" ((PCons (PCon "LetBind" (PVar "n") (PVar "clauses")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "clauseDef") (EVar "n"))) (EVar "clauses")) (EApp (EVar "letGroupDefs") (EVar "rest"))))
(DTypeSig false "clauseDef" (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clauseDef" ((PVar "n") (PCon "FunClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "n") (ETuple (EVar "pats") (EVar "body"))))
(DTypeSig false "funGroupNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "funGroupNames" ((PList) PWild) (EListLit))
(DFunDef false "funGroupNames" ((PCons (PTuple (PVar "n") PWild) (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "seen")) (EApp (EApp (EVar "funGroupNames") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "n") (EApp (EApp (EVar "funGroupNames") (EVar "rest")) (EBinOp "::" (EVar "n") (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "clausesForName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "clausesForName" (PWild (PList)) (EListLit))
(DFunDef false "clausesForName" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "c")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EBinOp "::" (EVar "c") (EApp (EApp (EVar "clausesForName") (EVar "name")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "clausesForName") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "buildIfaceDispatch" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "buildIfaceDispatch" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ifaceDispatchEntries")) (EVar "prog")))
(DTypeSig false "ifaceDispatchEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "ifaceDispatchEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ifaceMethodEntry") (EVar "ifaceName")) (EVar "typeParams"))) (EVar "methods")))
(DFunDef false "ifaceDispatchEntries" (PWild) (EListLit))
(DTypeSig false "ifaceMethodEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "ifaceMethodEntry" ((PVar "ifaceName") (PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild)) (ETuple (ETuple (EVar "ifaceName") (EVar "mname")) (EApp (EApp (EVar "dispatchPositionsOf") (EVar "mty")) (EApp (EVar "receiverParam") (EVar "typeParams")))))
(DTypeSig false "receiverParam" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "receiverParam" ((PList)) (EListLit))
(DFunDef false "receiverParam" ((PCons (PVar "p") PWild)) (EListLit (EVar "p")))
(DTypeSig true "lookupPositions" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "lookupPositions" (PWild PWild (PList)) (EListLit (ELit (LInt 0))))
(DFunDef false "lookupPositions" ((PVar "iface") (PVar "mname") (PCons (PTuple (PTuple (PVar "i") (PVar "m")) (PVar "p")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "iface") (EVar "i")) (EBinOp "==" (EVar "mname") (EVar "m"))) (EVar "p") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "lookupPositions") (EVar "iface")) (EVar "mname")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implMethodValue" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "implMethodValue" ((PVar "env") (PVar "positions") (PList) (PVar "body")) (EIf (EApp (EVar "isEmptyL") (EVar "positions")) (EApp (EApp (EVar "memoThunk") (EVar "env")) (EVar "body")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "VClosure") (EVar "env")) (EListLit (EApp (EVar "PVar") (ELit (LString "$eta"))))) (EApp (EApp (EVar "EApp") (EVar "body")) (EApp (EVar "EVar") (ELit (LString "$eta"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "implMethodValue" ((PVar "env") PWild (PVar "pats") (PVar "body")) (EApp (EApp (EApp (EVar "VClosure") (EVar "env")) (EVar "pats")) (EVar "body")))
(DTypeSig false "memoThunk" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "memoThunk" ((PVar "env") (PVar "body")) (EApp (EApp (EApp (EVar "memoThunkOf") (EApp (EVar "Ref") (EVar "None"))) (EVar "env")) (EVar "body")))
(DTypeSig false "memoThunkOf" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "memoThunkOf" ((PVar "cell") (PVar "env") (PVar "body")) (EApp (EVar "VThunk") (ELam (PWild) (EApp (EApp (EApp (EVar "forceMemoCell") (EVar "cell")) (EVar "env")) (EVar "body")))))
(DTypeSig false "forceMemoCell" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Expr") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "forceMemoCell" ((PVar "cell") (PVar "env") (PVar "body")) (EMatch (EFieldAccess (EVar "cell") "value") (arm (PCon "Some" (PVar "v")) () (EVar "v")) (arm (PCon "None") () (EApp (EApp (EVar "storeMemo") (EVar "cell")) (EApp (EApp (EVar "eval") (EVar "env")) (EVar "body"))))))
(DTypeSig false "storeMemo" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "storeMemo" ((PVar "cell") (PVar "v")) (EApp (EApp (EVar "seqV") (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Some") (EVar "v")))) (EVar "v")))
(DTypeSig false "seqV" (TyFun (TyCon "Unit") (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "seqV" (PWild (PVar "v")) (EVar "v"))
(DTypeSig false "declImplEntries" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "declImplEntries" ((PVar "env") (PVar "disp") (PRec "DImpl" ((rf "iface" (PVar "ifaceName")) (rf "tys" (PVar "typeArgs")) (rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "implMethodEntry") (EVar "env")) (EVar "disp")) (EVar "ifaceName")) (EVar "typeArgs"))) (EVar "methods")))
(DFunDef false "declImplEntries" ((PVar "env") PWild (PRec "DInterface" ((rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "defaultEntry") (EVar "env")) (EVar "typeParams"))) (EVar "methods")))
(DFunDef false "declImplEntries" (PWild PWild PWild) (EListLit))
(DTypeSig false "implMethodEntry" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "ImplMethod") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))))))))
(DFunDef false "implMethodEntry" ((PVar "env") (PVar "disp") (PVar "ifaceName") (PVar "typeArgs") (PCon "ImplMethod" (PVar "mname") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "tag") (EApp (EApp (EVar "fromOption") (EVar "noneHeadTag")) (EApp (EVar "headTyconHead") (EVar "typeArgs")))) (DoLet false false (PVar "key") (EApp (EApp (EApp (EVar "implKeyOf") (EVar "ifaceName")) (EVar "typeArgs")) (EVar "None"))) (DoLet false false (PVar "positions") (EApp (EApp (EApp (EVar "lookupPositions") (EVar "ifaceName")) (EVar "mname")) (EVar "disp"))) (DoLet false false (PVar "inner") (EApp (EApp (EApp (EApp (EVar "implMethodValue") (EVar "env")) (EVar "positions")) (EVar "pats")) (EVar "body"))) (DoExpr (ETuple (EVar "mname") (ETuple (EApp (EVar "tyvarsInArgs") (EVar "typeArgs")) (EApp (EApp (EApp (EApp (EApp (EVar "VTypedImpl") (EVar "tag")) (EVar "key")) (EVar "positions")) (ELit (LInt 0))) (EVar "inner")))))))
(DTypeSig true "headTyconHead" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headTyconHead" ((PList)) (EVar "None"))
(DFunDef false "headTyconHead" ((PCons (PVar "t") PWild)) (EApp (EVar "headTycon") (EVar "t")))
(DTypeSig false "defaultEntry" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "defaultEntry" (PWild PWild (PCon "IfaceMethod" PWild PWild (PCon "None"))) (EListLit))
(DFunDef false "defaultEntry" ((PVar "env") (PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") PWild (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))))) (EListLit (ETuple (EVar "mname") (ETuple (EApp (EVar "listLen") (EVar "typeParams")) (EApp (EApp (EApp (EApp (EVar "implMethodValue") (EVar "env")) (EListLit)) (EVar "pats")) (EVar "body"))))))
(DTypeSig true "coalesceImpls" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "coalesceImpls" ((PVar "scored")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EApp (EVar "coalesceOne") (EVar "n")) (EVar "scored"))))) (EApp (EVar "dedup") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "scored")))))
(DTypeSig false "coalesceOne" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "coalesceOne" ((PVar "name") (PVar "scored")) (EApp (EVar "oneOrMulti") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EVar "sortByScore") (EApp (EApp (EVar "selectByName") (EVar "name")) (EVar "scored"))))))
(DTypeSig false "oneOrMulti" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "oneOrMulti" ((PList (PVar "v"))) (EVar "v"))
(DFunDef false "oneOrMulti" ((PVar "many")) (EApp (EVar "VMulti") (EVar "many")))
(DTypeSig false "selectByName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "selectByName" ((PVar "name") (PVar "scored")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "fst") (EVar "e")) (EVar "name")))) (EVar "scored"))))
(DTypeSig false "sortByScore" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "sortByScore" ((PVar "xs")) (EApp (EApp (EVar "sortGo") (EVar "xs")) (EListLit)))
(DTypeSig false "sortGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "sortGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "sortGo" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "sortGo") (EVar "xs")) (EApp (EApp (EVar "insertScore") (EVar "x")) (EVar "acc"))))
(DTypeSig false "insertScore" (TyFun (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "insertScore" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "insertScore" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<=" (EApp (EVar "fst") (EVar "y")) (EApp (EVar "fst") (EVar "x"))) (EBinOp "::" (EVar "y") (EApp (EApp (EVar "insertScore") (EVar "x")) (EVar "ys"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "implMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "implMethodNames" ((PVar "prog")) (EApp (EVar "dedup") (EApp (EApp (EDictApp "flatMap") (EVar "implDeclNames")) (EVar "prog"))))
(DTypeSig false "implDeclNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "implDeclNames" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EVar "implMethodName")) (EVar "methods")))
(DFunDef false "implDeclNames" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "defaultName")) (EVar "methods")))
(DFunDef false "implDeclNames" (PWild) (EListLit))
(DTypeSig false "implMethodName" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodName" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "defaultName" (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "defaultName" ((PCon "IfaceMethod" (PVar "n") PWild (PCon "Some" PWild))) (EListLit (EVar "n")))
(DFunDef false "defaultName" ((PCon "IfaceMethod" PWild PWild (PCon "None"))) (EListLit))
(DTypeSig true "cellResult" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))) (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "cellResult" ((PTuple (PVar "n") (PVar "cell"))) (ETuple (EVar "n") (EFieldAccess (EVar "cell") "value")))
(DTypeSig true "boolSeeds" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "boolSeeds" () (EListLit (ETuple (ELit (LString "True")) (EApp (EVar "VBool") (EVar "True"))) (ETuple (ELit (LString "False")) (EApp (EVar "VBool") (EVar "False"))) (ETuple (ELit (LString "otherwise")) (EApp (EVar "VBool") (EVar "True")))))
(DTypeSig false "prim1" (TyFun (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "prim1" ((PVar "f")) (EApp (EVar "VPrim") (EVar "f")))
(DTypeSig false "prim2" (TyFun (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "prim2" ((PVar "f")) (EApp (EVar "VPrim") (ELam ((PVar "a")) (EApp (EVar "VPrim") (ELam ((PVar "b")) (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")))))))
(DTypeSig false "prim3" (TyFun (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "prim3" ((PVar "f")) (EApp (EVar "VPrim") (ELam ((PVar "a")) (EApp (EVar "VPrim") (ELam ((PVar "b")) (EApp (EVar "VPrim") (ELam ((PVar "c")) (EApp (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")) (EVar "c")))))))))
(DTypeSig false "prim2M" (TyFun (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "prim2M" ((PVar "f")) (EApp (EVar "VPrim") (ELam ((PVar "a")) (EApp (EVar "VPrim") (ELam ((PVar "b")) (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")))))))
(DTypeSig false "prim3M" (TyFun (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "prim3M" ((PVar "f")) (EApp (EVar "VPrim") (ELam ((PVar "a")) (EApp (EVar "VPrim") (ELam ((PVar "b")) (EApp (EVar "VPrim") (ELam ((PVar "c")) (EApp (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")) (EVar "c")))))))))
(DTypeSig false "prim5M" (TyFun (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "prim5M" ((PVar "f")) (EApp (EVar "VPrim") (ELam ((PVar "a")) (EApp (EVar "VPrim") (ELam ((PVar "b")) (EApp (EVar "VPrim") (ELam ((PVar "c")) (EApp (EVar "VPrim") (ELam ((PVar "d")) (EApp (EVar "VPrim") (ELam ((PVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "f") (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d")) (EVar "x")))))))))))))
(DTypeSig false "prim1M" (TyFun (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "prim1M" ((PVar "f")) (EApp (EVar "VPrim") (EVar "f")))
(DTypeSig true "outputRef" (TyApp (TyCon "Ref") (TyCon "String")))
(DFunDef false "outputRef" () (EApp (EVar "Ref") (ELit (LString ""))))
(DTypeSig true "currentEvalLoc" (TyApp (TyCon "Ref") (TyCon "Loc")))
(DFunDef false "currentEvalLoc" () (EApp (EVar "Ref") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig true "currentEvalFile" (TyApp (TyCon "Ref") (TyCon "String")))
(DFunDef false "currentEvalFile" () (EApp (EVar "Ref") (ELit (LString ""))))
(DTypeSig false "evalDepthRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "evalDepthRef" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig false "evalDepthLimit" (TyCon "Int"))
(DFunDef false "evalDepthLimit" () (ELit (LInt 25000)))
(DTypeSig true "runJsonMode" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "runJsonMode" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig false "updateEvalLoc" (TyFun (TyCon "Loc") (TyCon "Unit")))
(DFunDef false "updateEvalLoc" ((PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "sl") (ELit (LInt 1))) (EBinOp "==" (EVar "sc") (ELit (LInt 0)))) (EBinOp "==" (EVar "el") (ELit (LInt 1)))) (EBinOp "==" (EVar "ec") (ELit (LInt 0)))) (ELit LUnit) (EIf (EVar "otherwise") (EApp (EApp (EVar "setRef") (EVar "currentEvalLoc")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "runtimePanic" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyVar "a"))))
(DFunDef false "runtimePanic" ((PVar "code") (PVar "msg")) (EMatch (EFieldAccess (EVar "currentEvalLoc") "value") (arm (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) () (EBlock (DoLet false false (PVar "ff") (EIf (EBinOp "==" (EVar "f") (ELit (LString ""))) (EFieldAccess (EVar "currentEvalFile") "value") (EVar "f"))) (DoExpr (EIf (EFieldAccess (EVar "runJsonMode") "value") (EBlock (DoLet false false (PVar "diag") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EVar "code")) (EVar "msg")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "ff")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))) (EVar "None")) (EVar "None"))) (DoExpr (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "fmtSentinel"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "ff") (ELit (LString "")) (EListLit (EVar "diag"))))))) (ELit (LString "")))))) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "fmtSentinel"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "ff"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ": runtime error ["))) (EApp (EMethodRef "display") (EVar "code"))) (ELit (LString "]: "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))))))))
(DTypeSig false "fmtSentinel" (TyCon "String"))
(DFunDef false "fmtSentinel" () (ELit (LString "\u{01}")))
(DTypeSig false "appendOutput" (TyFun (TyCon "String") (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "appendOutput" ((PVar "s")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "outputRef")) (EBinOp "++" (EFieldAccess (EVar "outputRef") "value") (EVar "s")))) (DoLet false false PWild (EApp (EVar "stashRunStdout") (EFieldAccess (EVar "outputRef") "value"))) (DoExpr (EVar "VUnit"))))
(DTypeSig false "pPutStr" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pPutStr" ((PCon "VString" (PVar "s"))) (EApp (EVar "appendOutput") (EVar "s")))
(DFunDef false "pPutStr" (PWild) (EApp (EVar "panic") (ELit (LString "putStr: not a String"))))
(DTypeSig false "pPutStrLn" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pPutStrLn" ((PCon "VString" (PVar "s"))) (EApp (EVar "appendOutput") (EBinOp "++" (EVar "s") (ELit (LString "\n")))))
(DFunDef false "pPutStrLn" (PWild) (EApp (EVar "panic") (ELit (LString "putStrLn: not a String"))))
(DTypeSig false "pStashRunStdout" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStashRunStdout" ((PCon "VString" (PVar "s"))) (ELet false PWild (EApp (EVar "stashRunStdout") (EVar "s")) (EVar "VUnit")))
(DFunDef false "pStashRunStdout" (PWild) (EApp (EVar "panic") (ELit (LString "stashRunStdout: not a String"))))
(DTypeSig false "pEnableRunStdoutFlush" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pEnableRunStdoutFlush" (PWild) (ELet false PWild (EApp (EVar "enableRunStdoutFlush") (ELit LUnit)) (EVar "VUnit")))
(DTypeSig false "pDiscard" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pDiscard" (PWild) (EVar "VUnit"))
(DTypeSig false "pPanic" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyVar "a"))))
(DFunDef false "pPanic" ((PVar "v")) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-PANIC"))) (EApp (EVar "unString") (EVar "v"))))
(DTypeSig false "pRef" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pRef" ((PVar "v")) (EApp (EVar "VRef") (EApp (EVar "Ref") (EVar "v"))))
(DTypeSig false "pSetRef" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pSetRef" ((PCon "VRef" (PVar "cell")) (PVar "v")) (EApp (EApp (EVar "doSetRef") (EVar "cell")) (EVar "v")))
(DFunDef false "pSetRef" (PWild PWild) (EApp (EVar "panic") (ELit (LString "setRef: not a Ref"))))
(DTypeSig false "doSetRef" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "doSetRef" ((PVar "cell") (PVar "v")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cell")) (EVar "v"))) (DoExpr (EVar "VUnit"))))
(DTypeSig false "unString" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "String")))
(DFunDef false "unString" ((PCon "VString" (PVar "s"))) (EVar "s"))
(DFunDef false "unString" (PWild) (EApp (EVar "panic") (ELit (LString "expected a String"))))
(DTypeSig false "unChar" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Char")))
(DFunDef false "unChar" ((PCon "VChar" (PVar "s"))) (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s"))))
(DFunDef false "unChar" (PWild) (EApp (EVar "panic") (ELit (LString "expected a Char"))))
(DTypeSig false "orderingToValue" (TyFun (TyCon "Ordering") (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "orderingToValue" ((PCon "Lt")) (EApp (EApp (EVar "VCon") (ELit (LString "Lt"))) (EListLit)))
(DFunDef false "orderingToValue" ((PCon "Eq")) (EApp (EApp (EVar "VCon") (ELit (LString "Eq"))) (EListLit)))
(DFunDef false "orderingToValue" ((PCon "Gt")) (EApp (EApp (EVar "VCon") (ELit (LString "Gt"))) (EListLit)))
(DTypeSig false "optionToValue" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "optionToValue" ((PCon "None")) (EApp (EApp (EVar "VCon") (ELit (LString "None"))) (EListLit)))
(DFunDef false "optionToValue" ((PCon "Some" (PVar "v"))) (EApp (EApp (EVar "VCon") (ELit (LString "Some"))) (EListLit (EVar "v"))))
(DTypeSig false "u64Golden" (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))
(DFunDef false "u64Golden" () (ETuple (ELit (LInt 31765)) (ELit (LInt 32586)) (ELit (LInt 31161)) (ELit (LInt 40503))))
(DTypeSig false "u64Const1" (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))
(DFunDef false "u64Const1" () (ETuple (ELit (LInt 58809)) (ELit (LInt 7396)) (ELit (LInt 18285)) (ELit (LInt 48984))))
(DTypeSig false "u64Const2" (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))
(DFunDef false "u64Const2" () (ETuple (ELit (LInt 4587)) (ELit (LInt 4913)) (ELit (LInt 18875)) (ELit (LInt 38096))))
(DTypeSig false "u64FnvBasis" (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))
(DFunDef false "u64FnvBasis" () (ETuple (ELit (LInt 8997)) (ELit (LInt 33826)) (ELit (LInt 40164)) (ELit (LInt 52210))))
(DTypeSig false "u64FnvPrime" (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))
(DFunDef false "u64FnvPrime" () (ETuple (ELit (LInt 435)) (ELit (LInt 0)) (ELit (LInt 256)) (ELit (LInt 0))))
(DTypeSig false "u64Finalize" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "u64Finalize" ((PVar "z")) (EBlock (DoLet false false (PVar "z1") (EApp (EApp (EVar "mulLow64") (EApp (EApp (EVar "xor64") (EVar "z")) (EApp (EApp (EVar "shr64") (EVar "z")) (ELit (LInt 30))))) (EVar "u64Const1"))) (DoLet false false (PVar "z2") (EApp (EApp (EVar "mulLow64") (EApp (EApp (EVar "xor64") (EVar "z1")) (EApp (EApp (EVar "shr64") (EVar "z1")) (ELit (LInt 27))))) (EVar "u64Const2"))) (DoExpr (EApp (EApp (EVar "xor64") (EVar "z2")) (EApp (EApp (EVar "shr64") (EVar "z2")) (ELit (LInt 31)))))))
(DTypeSig false "u64Mix" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "u64Mix" ((PVar "x")) (EApp (EVar "u64Finalize") (EApp (EApp (EVar "add64") (EVar "x")) (EVar "u64Golden"))))
(DTypeSig false "u64Low30" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "u64Low30" ((PTuple (PVar "a0") (PVar "a1") PWild PWild)) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "bitOr") (EVar "a0")) (EApp (EApp (EVar "shiftLeft") (EVar "a1")) (ELit (LInt 16))))) (ELit (LInt 1073741823))))
(DTypeSig false "u64ToInt" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "u64ToInt" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "bitOr") (EVar "a0")) (EApp (EApp (EVar "shiftLeft") (EVar "a1")) (ELit (LInt 16))))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "shiftLeft") (EVar "a2")) (ELit (LInt 32)))) (EApp (EApp (EVar "shiftLeft") (EVar "a3")) (ELit (LInt 48))))))
(DTypeSig false "u64Bit63" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "u64Bit63" ((PTuple PWild PWild PWild (PVar "a3"))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EVar "a3")) (ELit (LInt 15)))) (ELit (LInt 1))))
(DTypeSig false "u64ToSignedInt" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "u64ToSignedInt" ((PTuple (PVar "a0") (PVar "a1") (PVar "a2") (PVar "a3"))) (EBlock (DoLet false false (PVar "hi16") (EIf (EBinOp "==" (EApp (EApp (EVar "bitAnd") (EVar "a3")) (ELit (LInt 32768))) (ELit (LInt 0))) (EVar "a3") (EBinOp "-" (EVar "a3") (ELit (LInt 65536))))) (DoExpr (EBinOp "+" (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "bitOr") (EVar "a0")) (EApp (EApp (EVar "shiftLeft") (EVar "a1")) (ELit (LInt 16))))) (EApp (EApp (EVar "shiftLeft") (EVar "a2")) (ELit (LInt 32)))) (EApp (EApp (EVar "shiftLeft") (EVar "hi16")) (ELit (LInt 48)))))))
(DTypeSig true "rngStateRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "rngStateRef" () (EApp (EVar "Ref") (ELit (LInt 123456789))))
(DTypeSig false "rngU64Ref" (TyApp (TyCon "Ref") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "rngU64Ref" () (EApp (EVar "Ref") (ETuple (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)))))
(DTypeSig false "rngDraw" (TyFun (TyCon "Unit") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "rngDraw" (PWild) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EVar "add64") (EFieldAccess (EVar "rngU64Ref") "value")) (EVar "u64Golden"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "rngU64Ref")) (EVar "s"))) (DoExpr (EApp (EVar "u64Finalize") (EVar "s")))))
(DTypeSig false "pRandomInt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pRandomInt" ((PCon "VInt" (PVar "lo")) (PCon "VInt" (PVar "hi"))) (EBlock (DoLet false false (PVar "loU") (EApp (EVar "ofInt") (EVar "lo"))) (DoLet false false (PVar "rangeU") (EApp (EApp (EVar "add64") (EApp (EApp (EVar "sub64") (EApp (EVar "ofInt") (EVar "hi"))) (EVar "loU"))) (EApp (EVar "ofInt") (ELit (LInt 1))))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "isZero") (EVar "rangeU")) (EBinOp "==" (EApp (EVar "u64Bit63") (EVar "rangeU")) (ELit (LInt 1)))) (EApp (EVar "VInt") (EVar "lo")) (EBlock (DoLet false false (PVar "rem") (EApp (EApp (EVar "mod64") (EApp (EVar "rngDraw") (ELit LUnit))) (EVar "rangeU"))) (DoExpr (EApp (EVar "VInt") (EApp (EVar "u64ToSignedInt") (EApp (EApp (EVar "add64") (EVar "loU")) (EVar "rem"))))))))))
(DFunDef false "pRandomInt" (PWild PWild) (EApp (EVar "panic") (ELit (LString "randomInt: expected Int Int"))))
(DTypeSig false "pRandomBool" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pRandomBool" (PWild) (EApp (EVar "VBool") (EBinOp "==" (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "limbAt") (EApp (EVar "rngDraw") (ELit LUnit))) (ELit (LInt 0)))) (ELit (LInt 1))) (ELit (LInt 1)))))
(DTypeSig false "pRandomFloat" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pRandomFloat" (PWild) (EBlock (DoLet false false (PVar "bits") (EApp (EVar "u64ToInt") (EApp (EApp (EVar "shr64") (EApp (EVar "rngDraw") (ELit LUnit))) (ELit (LInt 11))))) (DoExpr (EApp (EVar "VFloat") (EBinOp "-" (EBinOp "*" (EBinOp "*" (EApp (EVar "intToFloat") (EVar "bits")) (EBinOp "/" (ELit (LFloat 1.0)) (EApp (EVar "intToFloat") (ELit (LInt 9007199254740992))))) (ELit (LFloat 2.0))) (ELit (LFloat 1.0)))))))
(DTypeSig false "pRandomChar" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pRandomChar" (PWild) (EApp (EVar "VChar") (EApp (EVar "charToStr") (EApp (EVar "charFromCodeUnsafe") (EBinOp "+" (ELit (LInt 32)) (EApp (EVar "u64ToInt") (EApp (EApp (EVar "mod64") (EApp (EVar "rngDraw") (ELit LUnit))) (EApp (EVar "ofInt") (ELit (LInt 95))))))))))
(DTypeSig false "charFromCodeUnsafe" (TyFun (TyCon "Int") (TyCon "Char")))
(DFunDef false "charFromCodeUnsafe" ((PVar "n")) (EMatch (EApp (EVar "charFromCode") (EVar "n")) (arm (PCon "Some" (PVar "c")) () (EVar "c")) (arm (PCon "None") () (ELit (LChar " ")))))
(DTypeSig false "pSetSeed" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pSetSeed" ((PCon "VInt" (PVar "seed"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "rngU64Ref")) (EApp (EVar "ofInt") (EVar "seed")))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pSetSeed" (PWild) (EApp (EVar "panic") (ELit (LString "setSeed: expected Int"))))
(DTypeSig false "pWallTimeSec" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pWallTimeSec" (PWild) (EApp (EVar "VFloat") (ELit (LFloat 1700000000.0))))
(DTypeSig false "pMonotonicSec" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pMonotonicSec" (PWild) (EApp (EVar "VFloat") (ELit (LFloat 1000.0))))
(DTypeSig false "pSleepMs" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pSleepMs" ((PCon "VInt" PWild)) (EVar "VUnit"))
(DFunDef false "pSleepMs" (PWild) (EApp (EVar "panic") (ELit (LString "sleepMs: expected Int"))))
(DTypeSig false "pAllocBytes" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pAllocBytes" (PWild) (EApp (EVar "VFloat") (ELit (LFloat 0.0))))
(DTypeSig false "pFlushStdout" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pFlushStdout" ((PCon "VUnit")) (EVar "VUnit"))
(DFunDef false "pFlushStdout" (PWild) (EApp (EVar "panic") (ELit (LString "flushStdout: expected Unit"))))
(DTypeSig true "externBindings" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "externBindings" (PWild) (EListLit (ETuple (ELit (LString "randomInt")) (EApp (EVar "prim2M") (EVar "pRandomInt"))) (ETuple (ELit (LString "randomBool")) (EApp (EVar "prim1M") (EVar "pRandomBool"))) (ETuple (ELit (LString "randomFloat")) (EApp (EVar "prim1M") (EVar "pRandomFloat"))) (ETuple (ELit (LString "randomChar")) (EApp (EVar "prim1M") (EVar "pRandomChar"))) (ETuple (ELit (LString "setSeed")) (EApp (EVar "prim1M") (EVar "pSetSeed"))) (ETuple (ELit (LString "wallTimeSec")) (EApp (EVar "prim1M") (EVar "pWallTimeSec"))) (ETuple (ELit (LString "monotonicSec")) (EApp (EVar "prim1M") (EVar "pMonotonicSec"))) (ETuple (ELit (LString "sleepMs")) (EApp (EVar "prim1M") (EVar "pSleepMs"))) (ETuple (ELit (LString "allocBytes")) (EApp (EVar "prim1M") (EVar "pAllocBytes"))) (ETuple (ELit (LString "flushStdout")) (EApp (EVar "prim1M") (EVar "pFlushStdout"))) (ETuple (ELit (LString "intToString")) (EApp (EVar "prim1") (EVar "pIntToString"))) (ETuple (ELit (LString "bitAnd")) (EApp (EVar "prim2") (EVar "pBitAnd"))) (ETuple (ELit (LString "bitOr")) (EApp (EVar "prim2") (EVar "pBitOr"))) (ETuple (ELit (LString "bitXor")) (EApp (EVar "prim2") (EVar "pBitXor"))) (ETuple (ELit (LString "shiftLeft")) (EApp (EVar "prim2") (EVar "pShiftLeft"))) (ETuple (ELit (LString "shiftRight")) (EApp (EVar "prim2") (EVar "pShiftRight"))) (ETuple (ELit (LString "bitNot")) (EApp (EVar "prim1") (EVar "pBitNot"))) (ETuple (ELit (LString "intToFloat")) (EApp (EVar "prim1") (EVar "pIntToFloat"))) (ETuple (ELit (LString "floatToInt")) (EApp (EVar "prim1") (EVar "pFloatToInt"))) (ETuple (ELit (LString "floatToString")) (EApp (EVar "prim1") (EVar "pFloatToString"))) (ETuple (ELit (LString "charToStr")) (EApp (EVar "prim1") (EVar "pCharToStr"))) (ETuple (ELit (LString "charCode")) (EApp (EVar "prim1") (EVar "pCharCode"))) (ETuple (ELit (LString "charFromCode")) (EApp (EVar "prim1") (EVar "pCharFromCode"))) (ETuple (ELit (LString "charToUpper")) (EApp (EVar "prim1") (EVar "pCharToUpper"))) (ETuple (ELit (LString "charToLower")) (EApp (EVar "prim1") (EVar "pCharToLower"))) (ETuple (ELit (LString "stringLength")) (EApp (EVar "prim1") (EVar "pStringLength"))) (ETuple (ELit (LString "stringConcat")) (EApp (EVar "prim1") (EVar "pStringConcat"))) (ETuple (ELit (LString "stringToChars")) (EApp (EVar "prim1") (EVar "pStringToChars"))) (ETuple (ELit (LString "stringFromChars")) (EApp (EVar "prim1") (EVar "pStringFromChars"))) (ETuple (ELit (LString "stringToUtf8Bytes")) (EApp (EVar "prim1") (EVar "pStringToUtf8Bytes"))) (ETuple (ELit (LString "stringFromUtf8Bytes")) (EApp (EVar "prim1") (EVar "pStringFromUtf8Bytes"))) (ETuple (ELit (LString "floatRem")) (EApp (EVar "prim2") (EVar "pFloatRem"))) (ETuple (ELit (LString "sqrt")) (EApp (EVar "prim1") (EVar "pSqrt"))) (ETuple (ELit (LString "cbrt")) (EApp (EVar "prim1") (EVar "pCbrt"))) (ETuple (ELit (LString "exp")) (EApp (EVar "prim1") (EVar "pExp"))) (ETuple (ELit (LString "log")) (EApp (EVar "prim1") (EVar "pLog"))) (ETuple (ELit (LString "log2")) (EApp (EVar "prim1") (EVar "pLog2"))) (ETuple (ELit (LString "log10")) (EApp (EVar "prim1") (EVar "pLog10"))) (ETuple (ELit (LString "sin")) (EApp (EVar "prim1") (EVar "pSin"))) (ETuple (ELit (LString "cos")) (EApp (EVar "prim1") (EVar "pCos"))) (ETuple (ELit (LString "tan")) (EApp (EVar "prim1") (EVar "pTan"))) (ETuple (ELit (LString "asin")) (EApp (EVar "prim1") (EVar "pAsin"))) (ETuple (ELit (LString "acos")) (EApp (EVar "prim1") (EVar "pAcos"))) (ETuple (ELit (LString "atan")) (EApp (EVar "prim1") (EVar "pAtan"))) (ETuple (ELit (LString "sinh")) (EApp (EVar "prim1") (EVar "pSinh"))) (ETuple (ELit (LString "cosh")) (EApp (EVar "prim1") (EVar "pCosh"))) (ETuple (ELit (LString "tanh")) (EApp (EVar "prim1") (EVar "pTanh"))) (ETuple (ELit (LString "floor")) (EApp (EVar "prim1") (EVar "pFloor"))) (ETuple (ELit (LString "ceil")) (EApp (EVar "prim1") (EVar "pCeil"))) (ETuple (ELit (LString "round")) (EApp (EVar "prim1") (EVar "pRound"))) (ETuple (ELit (LString "trunc")) (EApp (EVar "prim1") (EVar "pTrunc"))) (ETuple (ELit (LString "pow")) (EApp (EVar "prim2") (EVar "pPow"))) (ETuple (ELit (LString "atan2")) (EApp (EVar "prim2") (EVar "pAtan2"))) (ETuple (ELit (LString "hypot")) (EApp (EVar "prim2") (EVar "pHypot"))) (ETuple (ELit (LString "stringToUpper")) (EApp (EVar "prim1") (EVar "pStringToUpper"))) (ETuple (ELit (LString "stringToLower")) (EApp (EVar "prim1") (EVar "pStringToLower"))) (ETuple (ELit (LString "stringCompare")) (EApp (EVar "prim2") (EVar "pStringCompare"))) (ETuple (ELit (LString "stringIndexOf")) (EApp (EVar "prim2") (EVar "pStringIndexOf"))) (ETuple (ELit (LString "stringSlice")) (EApp (EVar "prim3") (EVar "pStringSlice"))) (ETuple (ELit (LString "arrayLength")) (EApp (EVar "prim1") (EVar "pArrayLength"))) (ETuple (ELit (LString "arrayFromList")) (EApp (EVar "prim1") (EVar "pArrayFromList"))) (ETuple (ELit (LString "arrayGetUnsafe")) (EApp (EVar "prim2") (EVar "pArrayGetUnsafe"))) (ETuple (ELit (LString "arrayMake")) (EApp (EVar "prim2") (EVar "pArrayMake"))) (ETuple (ELit (LString "arrayMakeWith")) (EApp (EVar "prim2M") (EVar "pArrayMakeWith"))) (ETuple (ELit (LString "arrayCopy")) (EApp (EVar "prim1") (EVar "pArrayCopy"))) (ETuple (ELit (LString "arraySetUnsafe")) (EApp (EVar "prim3M") (EVar "pArraySetUnsafe"))) (ETuple (ELit (LString "arrayBlit")) (EApp (EVar "prim5M") (EVar "pArrayBlit"))) (ETuple (ELit (LString "arrayFill")) (EApp (EVar "prim2M") (EVar "pArrayFill"))) (ETuple (ELit (LString "Ref")) (EApp (EVar "prim1") (EVar "pRef"))) (ETuple (ELit (LString "setRef")) (EApp (EVar "prim2M") (EVar "pSetRef"))) (ETuple (ELit (LString "putStr")) (EApp (EVar "prim1M") (EVar "pPutStr"))) (ETuple (ELit (LString "putStrLn")) (EApp (EVar "prim1M") (EVar "pPutStrLn"))) (ETuple (ELit (LString "ePutStr")) (EApp (EVar "prim1M") (EVar "pDiscard"))) (ETuple (ELit (LString "ePutStrLn")) (EApp (EVar "prim1M") (EVar "pDiscard"))) (ETuple (ELit (LString "stashRunStdout")) (EApp (EVar "prim1M") (EVar "pStashRunStdout"))) (ETuple (ELit (LString "enableRunStdoutFlush")) (EApp (EVar "prim1M") (EVar "pEnableRunStdoutFlush"))) (ETuple (ELit (LString "panic")) (EApp (EVar "prim1") (EVar "pPanic"))) (ETuple (ELit (LString "indexError")) (EApp (EVar "prim1") (ELam ((PVar "s")) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-INDEX-OOB"))) (EApp (EVar "unString") (EVar "s")))))) (ETuple (ELit (LString "debugStringLit")) (EApp (EVar "prim1") (EVar "pDebugStringLit"))) (ETuple (ELit (LString "debugCharLit")) (EApp (EVar "prim1") (EVar "pDebugCharLit"))) (ETuple (ELit (LString "stringToFloat")) (EApp (EVar "prim1") (EVar "pStringToFloat"))) (ETuple (ELit (LString "charIsAlpha")) (EApp (EVar "prim1") (EApp (EVar "charPred") (EVar "charIsAlpha")))) (ETuple (ELit (LString "charIsSpace")) (EApp (EVar "prim1") (EApp (EVar "charPred") (EVar "charIsSpace")))) (ETuple (ELit (LString "charIsUpper")) (EApp (EVar "prim1") (EApp (EVar "charPred") (EVar "charIsUpper")))) (ETuple (ELit (LString "charIsLower")) (EApp (EVar "prim1") (EApp (EVar "charPred") (EVar "charIsLower")))) (ETuple (ELit (LString "charIsPunct")) (EApp (EVar "prim1") (EApp (EVar "charPred") (EVar "charIsPunct")))) (ETuple (ELit (LString "intMinBound")) (EApp (EVar "VInt") (EVar "intMinBound"))) (ETuple (ELit (LString "intMaxBound")) (EApp (EVar "VInt") (EVar "intMaxBound"))) (ETuple (ELit (LString "charMinBound")) (EApp (EVar "VChar") (EApp (EVar "charToStr") (EVar "charMinBound")))) (ETuple (ELit (LString "charMaxBound")) (EApp (EVar "VChar") (EApp (EVar "charToStr") (EVar "charMaxBound")))) (ETuple (ELit (LString "pi")) (EApp (EVar "VFloat") (EVar "pi"))) (ETuple (ELit (LString "e")) (EApp (EVar "VFloat") (EVar "e"))) (ETuple (ELit (LString "intBitsToFloat")) (EApp (EVar "prim1") (EVar "pIntBitsToFloat"))) (ETuple (ELit (LString "bytesToFloat64")) (EApp (EVar "prim2") (EVar "pBytesToFloat64"))) (ETuple (ELit (LString "floatToBytes64")) (EApp (EVar "prim1") (EVar "pFloatToBytes64"))) (ETuple (ELit (LString "hashInt")) (EApp (EVar "prim1") (EVar "pHashInt"))) (ETuple (ELit (LString "hashFloat")) (EApp (EVar "prim1") (EVar "pHashFloat"))) (ETuple (ELit (LString "hashString")) (EApp (EVar "prim1") (EVar "pHashString"))) (ETuple (ELit (LString "hashChar")) (EApp (EVar "prim1") (EVar "pHashChar"))) (ETuple (ELit (LString "hashBool")) (EApp (EVar "prim1") (EVar "pHashBool"))) (ETuple (EVar "fallthroughName") (EApp (EVar "prim1") (ELam (PWild) (EVar "VFallthrough"))))))
(DTypeSig false "pDebugStringLit" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pDebugStringLit" ((PCon "VString" (PVar "s"))) (EApp (EVar "VString") (EApp (EVar "debugStringLit") (EVar "s"))))
(DFunDef false "pDebugStringLit" (PWild) (EApp (EVar "panic") (ELit (LString "debugStringLit: not a String"))))
(DTypeSig false "pDebugCharLit" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pDebugCharLit" ((PCon "VChar" (PVar "s"))) (EApp (EVar "VString") (EApp (EVar "debugCharLit") (EApp (EVar "unChar") (EApp (EVar "VChar") (EVar "s"))))))
(DFunDef false "pDebugCharLit" (PWild) (EApp (EVar "panic") (ELit (LString "debugCharLit: not a Char"))))
(DTypeSig false "pStringToFloat" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringToFloat" ((PCon "VString" (PVar "s"))) (EApp (EVar "optionToValue") (EApp (EApp (EVar "mapOption") (EVar "VFloat")) (EApp (EVar "stringToFloat") (EVar "s")))))
(DFunDef false "pStringToFloat" (PWild) (EApp (EVar "panic") (ELit (LString "stringToFloat: not a String"))))
(DTypeSig false "charPred" (TyFun (TyFun (TyCon "Char") (TyCon "Bool")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "charPred" ((PVar "f") (PCon "VChar" (PVar "s"))) (EApp (EVar "VBool") (EApp (EVar "f") (EApp (EVar "unChar") (EApp (EVar "VChar") (EVar "s"))))))
(DFunDef false "charPred" (PWild PWild) (EApp (EVar "panic") (ELit (LString "char predicate: not a Char"))))
(DTypeSig false "pIntToString" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pIntToString" ((PCon "VInt" (PVar "n"))) (EApp (EVar "VString") (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "pIntToString" (PWild) (EApp (EVar "panic") (ELit (LString "intToString: not an Int"))))
(DTypeSig false "pBitAnd" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pBitAnd" ((PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EApp (EApp (EVar "bitAnd") (EVar "a")) (EVar "b"))))
(DFunDef false "pBitAnd" (PWild PWild) (EApp (EVar "panic") (ELit (LString "bitAnd: not Ints"))))
(DTypeSig false "pBitOr" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pBitOr" ((PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EApp (EApp (EVar "bitOr") (EVar "a")) (EVar "b"))))
(DFunDef false "pBitOr" (PWild PWild) (EApp (EVar "panic") (ELit (LString "bitOr: not Ints"))))
(DTypeSig false "pBitXor" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pBitXor" ((PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EApp (EApp (EVar "bitXor") (EVar "a")) (EVar "b"))))
(DFunDef false "pBitXor" (PWild PWild) (EApp (EVar "panic") (ELit (LString "bitXor: not Ints"))))
(DTypeSig false "pShiftLeft" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pShiftLeft" ((PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EApp (EApp (EVar "shiftLeft") (EVar "a")) (EVar "b"))))
(DFunDef false "pShiftLeft" (PWild PWild) (EApp (EVar "panic") (ELit (LString "shiftLeft: not Ints"))))
(DTypeSig false "pShiftRight" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pShiftRight" ((PCon "VInt" (PVar "a")) (PCon "VInt" (PVar "b"))) (EApp (EVar "VInt") (EApp (EApp (EVar "shiftRight") (EVar "a")) (EVar "b"))))
(DFunDef false "pShiftRight" (PWild PWild) (EApp (EVar "panic") (ELit (LString "shiftRight: not Ints"))))
(DTypeSig false "pBitNot" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pBitNot" ((PCon "VInt" (PVar "a"))) (EApp (EVar "VInt") (EApp (EVar "bitNot") (EVar "a"))))
(DFunDef false "pBitNot" (PWild) (EApp (EVar "panic") (ELit (LString "bitNot: not an Int"))))
(DTypeSig false "pIntToFloat" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pIntToFloat" ((PCon "VInt" (PVar "n"))) (EApp (EVar "VFloat") (EApp (EVar "intToFloat") (EVar "n"))))
(DFunDef false "pIntToFloat" (PWild) (EApp (EVar "panic") (ELit (LString "intToFloat: not an Int"))))
(DTypeSig false "pFloatToInt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pFloatToInt" ((PCon "VFloat" (PVar "f"))) (EApp (EVar "VInt") (EApp (EVar "floatToInt") (EVar "f"))))
(DFunDef false "pFloatToInt" (PWild) (EApp (EVar "panic") (ELit (LString "floatToInt: not a Float"))))
(DTypeSig false "pIntBitsToFloat" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pIntBitsToFloat" ((PCon "VInt" (PVar "n"))) (EApp (EVar "VFloat") (EApp (EVar "intBitsToFloat") (EVar "n"))))
(DFunDef false "pIntBitsToFloat" (PWild) (EApp (EVar "panic") (ELit (LString "intBitsToFloat: not an Int"))))
(DTypeSig false "getByte64" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "getByte64" ((PVar "off") (PVar "arr") (PVar "i")) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "off") (EVar "i"))) (EVar "arr")) (arm (PCon "VInt" (PVar "b")) () (EApp (EApp (EVar "bitAnd") (EVar "b")) (ELit (LInt 255)))) (arm PWild () (EApp (EVar "panic") (ELit (LString "bytesToFloat64: array element not Int"))))))
(DTypeSig false "pBytesToFloat64" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pBytesToFloat64" ((PCon "VArray" (PVar "arr")) (PCon "VInt" (PVar "off"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "off") (ELit (LInt 0))) (EBinOp ">" (EBinOp "+" (EVar "off") (ELit (LInt 8))) (EApp (EVar "arrayLength") (EVar "arr")))) (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-INDEX-OOB"))) (EBinOp "++" (EBinOp "++" (ELit (LString "index ")) (EApp (EVar "intToString") (EVar "off"))) (ELit (LString " out of bounds")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "pBytesToFloat64" ((PCon "VArray" (PVar "arr")) (PCon "VInt" (PVar "off"))) (EBlock (DoLet false false (PVar "intArr") (EApp (EApp (EVar "arrayMakeWith") (ELit (LInt 8))) (ELam ((PVar "i")) (EApp (EApp (EApp (EVar "getByte64") (EVar "off")) (EVar "arr")) (EVar "i"))))) (DoExpr (EApp (EVar "VFloat") (EApp (EApp (EVar "bytesToFloat64") (EVar "intArr")) (ELit (LInt 0)))))))
(DFunDef false "pBytesToFloat64" (PWild PWild) (EApp (EVar "panic") (ELit (LString "bytesToFloat64: expected Array Int"))))
(DTypeSig false "pFloatToBytes64" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pFloatToBytes64" ((PCon "VFloat" (PVar "f"))) (EBlock (DoLet false false (PVar "bs") (EApp (EVar "floatToBytes64") (EVar "f"))) (DoExpr (EApp (EVar "VArray") (EApp (EApp (EVar "arrayMakeWith") (ELit (LInt 8))) (ELam ((PVar "i")) (EApp (EVar "VInt") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "bs")))))))))
(DFunDef false "pFloatToBytes64" (PWild) (EApp (EVar "panic") (ELit (LString "floatToBytes64: not a Float"))))
(DTypeSig false "fnvStep64" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "fnvStep64" ((PTuple (PVar "h0") (PVar "h1") (PVar "h2") (PVar "h3")) (PVar "byte")) (EApp (EApp (EVar "mulLow64") (ETuple (EApp (EApp (EVar "bitXor") (EVar "h0")) (EVar "byte")) (EVar "h1") (EVar "h2") (EVar "h3"))) (EVar "u64FnvPrime")))
(DTypeSig false "fnvFold64" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "fnvFold64" ((PList) (PVar "h")) (EVar "h"))
(DFunDef false "fnvFold64" ((PCons (PVar "x") (PVar "xs")) (PVar "h")) (EApp (EApp (EVar "fnvFold64") (EVar "xs")) (EApp (EApp (EVar "fnvStep64") (EVar "h")) (EVar "x"))))
(DTypeSig false "bytesBEToU64" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "bytesBEToU64" ((PVar "bs")) (ETuple (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 7))) (EVar "bs"))) (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 6))) (EVar "bs"))) (ELit (LInt 8)))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 5))) (EVar "bs"))) (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 4))) (EVar "bs"))) (ELit (LInt 8)))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 3))) (EVar "bs"))) (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 2))) (EVar "bs"))) (ELit (LInt 8)))) (EApp (EApp (EVar "bitOr") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 1))) (EVar "bs"))) (EApp (EApp (EVar "shiftLeft") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "bs"))) (ELit (LInt 8))))))
(DTypeSig false "pHashInt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pHashInt" ((PCon "VInt" (PVar "n"))) (EApp (EVar "VInt") (EApp (EVar "u64Low30") (EApp (EVar "u64Mix") (EApp (EVar "ofInt") (EVar "n"))))))
(DFunDef false "pHashInt" (PWild) (EApp (EVar "panic") (ELit (LString "hashInt: not an Int"))))
(DTypeSig false "pHashChar" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pHashChar" ((PCon "VChar" (PVar "s"))) (EApp (EVar "VInt") (EApp (EVar "u64Low30") (EApp (EVar "u64Mix") (EApp (EVar "ofInt") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s")))))))))
(DFunDef false "pHashChar" (PWild) (EApp (EVar "panic") (ELit (LString "hashChar: not a Char"))))
(DTypeSig false "pHashBool" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pHashBool" ((PCon "VBool" (PVar "b"))) (EApp (EVar "VInt") (EApp (EVar "boolToInt") (EVar "b"))))
(DFunDef false "pHashBool" (PWild) (EApp (EVar "panic") (ELit (LString "hashBool: not a Bool"))))
(DTypeSig false "pHashFloat" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pHashFloat" ((PCon "VFloat" (PVar "f"))) (EApp (EVar "VInt") (EApp (EVar "u64Low30") (EApp (EVar "u64Mix") (EApp (EVar "bytesBEToU64") (EApp (EVar "floatToBytes64") (EVar "f")))))))
(DFunDef false "pHashFloat" (PWild) (EApp (EVar "panic") (ELit (LString "hashFloat: not a Float"))))
(DTypeSig false "pHashString" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pHashString" ((PCon "VString" (PVar "s"))) (EApp (EVar "VInt") (EApp (EVar "u64Low30") (EApp (EApp (EVar "fnvFold64") (EApp (EVar "arrayToListG") (EApp (EVar "stringToUtf8Bytes") (EVar "s")))) (EVar "u64FnvBasis")))))
(DFunDef false "pHashString" (PWild) (EApp (EVar "panic") (ELit (LString "hashString: not a String"))))
(DTypeSig false "pFloatToString" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pFloatToString" ((PCon "VFloat" (PVar "f"))) (EApp (EVar "VString") (EApp (EVar "floatToString") (EVar "f"))))
(DFunDef false "pFloatToString" (PWild) (EApp (EVar "panic") (ELit (LString "floatToString: not a Float"))))
(DTypeSig false "pCharToStr" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCharToStr" ((PCon "VChar" (PVar "s"))) (EApp (EVar "VString") (EVar "s")))
(DFunDef false "pCharToStr" (PWild) (EApp (EVar "panic") (ELit (LString "charToStr: not a Char"))))
(DTypeSig false "pCharCode" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCharCode" ((PCon "VChar" (PVar "s"))) (EApp (EVar "VInt") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s"))))))
(DFunDef false "pCharCode" (PWild) (EApp (EVar "panic") (ELit (LString "charCode: not a Char"))))
(DTypeSig false "pCharFromCode" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCharFromCode" ((PCon "VInt" (PVar "n"))) (EApp (EVar "optionToValue") (EApp (EApp (EVar "mapOption") (EVar "charToVChar")) (EApp (EVar "charFromCode") (EVar "n")))))
(DFunDef false "pCharFromCode" (PWild) (EApp (EVar "panic") (ELit (LString "charFromCode: not an Int"))))
(DTypeSig false "charToVChar" (TyFun (TyCon "Char") (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "charToVChar" ((PVar "c")) (EApp (EVar "VChar") (EApp (EVar "charToStr") (EVar "c"))))
(DTypeSig false "pCharToUpper" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCharToUpper" ((PCon "VChar" (PVar "s"))) (EApp (EVar "VChar") (EApp (EVar "charToStr") (EApp (EVar "charToUpper") (EApp (EVar "unChar") (EApp (EVar "VChar") (EVar "s")))))))
(DFunDef false "pCharToUpper" (PWild) (EApp (EVar "panic") (ELit (LString "charToUpper: not a Char"))))
(DTypeSig false "pCharToLower" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCharToLower" ((PCon "VChar" (PVar "s"))) (EApp (EVar "VChar") (EApp (EVar "charToStr") (EApp (EVar "charToLower") (EApp (EVar "unChar") (EApp (EVar "VChar") (EVar "s")))))))
(DFunDef false "pCharToLower" (PWild) (EApp (EVar "panic") (ELit (LString "charToLower: not a Char"))))
(DTypeSig false "pStringLength" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringLength" ((PCon "VString" (PVar "s"))) (EApp (EVar "VInt") (EApp (EVar "stringLength") (EVar "s"))))
(DFunDef false "pStringLength" (PWild) (EApp (EVar "panic") (ELit (LString "stringLength: not a String"))))
(DTypeSig false "pStringConcat" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringConcat" ((PCon "VList" (PVar "vs"))) (EApp (EVar "VString") (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (EVar "unString")) (EVar "vs")))))
(DFunDef false "pStringConcat" (PWild) (EApp (EVar "panic") (ELit (LString "stringConcat: not a List"))))
(DTypeSig false "pStringToChars" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringToChars" ((PCon "VString" (PVar "s"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "charToVChar")) (EApp (EVar "arrayToListG") (EApp (EVar "stringToChars") (EVar "s")))))))
(DFunDef false "pStringToChars" (PWild) (EApp (EVar "panic") (ELit (LString "stringToChars: not a String"))))
(DTypeSig false "pStringFromChars" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringFromChars" ((PCon "VArray" (PVar "vs"))) (EApp (EVar "VString") (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "unChar")) (EApp (EVar "arrayToListG") (EVar "vs")))))))
(DFunDef false "pStringFromChars" (PWild) (EApp (EVar "panic") (ELit (LString "stringFromChars: not an Array"))))
(DTypeSig false "unInt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyCon "Int")))
(DFunDef false "unInt" ((PCon "VInt" (PVar "n"))) (EVar "n"))
(DFunDef false "unInt" (PWild) (EApp (EVar "panic") (ELit (LString "unInt: not an Int"))))
(DTypeSig false "pStringToUtf8Bytes" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringToUtf8Bytes" ((PCon "VString" (PVar "s"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "VInt")) (EApp (EVar "arrayToListG") (EApp (EVar "stringToUtf8Bytes") (EVar "s")))))))
(DFunDef false "pStringToUtf8Bytes" (PWild) (EApp (EVar "panic") (ELit (LString "stringToUtf8Bytes: not a String"))))
(DTypeSig false "pStringFromUtf8Bytes" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringFromUtf8Bytes" ((PCon "VArray" (PVar "vs"))) (EApp (EVar "VString") (EApp (EVar "stringFromUtf8Bytes") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "unInt")) (EApp (EVar "arrayToListG") (EVar "vs")))))))
(DFunDef false "pStringFromUtf8Bytes" (PWild) (EApp (EVar "panic") (ELit (LString "stringFromUtf8Bytes: not an Array"))))
(DTypeSig false "pFloatRem" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pFloatRem" ((PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EApp (EApp (EVar "floatRem") (EVar "a")) (EVar "b"))))
(DFunDef false "pFloatRem" (PWild PWild) (EApp (EVar "panic") (ELit (LString "floatRem: bad operands"))))
(DTypeSig false "pSqrt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pSqrt" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "sqrt") (EVar "a"))))
(DFunDef false "pSqrt" (PWild) (EApp (EVar "panic") (ELit (LString "sqrt: not a Float"))))
(DTypeSig false "pCbrt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCbrt" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "cbrt") (EVar "a"))))
(DFunDef false "pCbrt" (PWild) (EApp (EVar "panic") (ELit (LString "cbrt: not a Float"))))
(DTypeSig false "pExp" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pExp" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "exp") (EVar "a"))))
(DFunDef false "pExp" (PWild) (EApp (EVar "panic") (ELit (LString "exp: not a Float"))))
(DTypeSig false "pLog" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pLog" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "log") (EVar "a"))))
(DFunDef false "pLog" (PWild) (EApp (EVar "panic") (ELit (LString "log: not a Float"))))
(DTypeSig false "pLog2" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pLog2" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "log2") (EVar "a"))))
(DFunDef false "pLog2" (PWild) (EApp (EVar "panic") (ELit (LString "log2: not a Float"))))
(DTypeSig false "pLog10" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pLog10" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "log10") (EVar "a"))))
(DFunDef false "pLog10" (PWild) (EApp (EVar "panic") (ELit (LString "log10: not a Float"))))
(DTypeSig false "pSin" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pSin" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "sin") (EVar "a"))))
(DFunDef false "pSin" (PWild) (EApp (EVar "panic") (ELit (LString "sin: not a Float"))))
(DTypeSig false "pCos" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCos" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "cos") (EVar "a"))))
(DFunDef false "pCos" (PWild) (EApp (EVar "panic") (ELit (LString "cos: not a Float"))))
(DTypeSig false "pTan" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pTan" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "tan") (EVar "a"))))
(DFunDef false "pTan" (PWild) (EApp (EVar "panic") (ELit (LString "tan: not a Float"))))
(DTypeSig false "pAsin" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pAsin" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "asin") (EVar "a"))))
(DFunDef false "pAsin" (PWild) (EApp (EVar "panic") (ELit (LString "asin: not a Float"))))
(DTypeSig false "pAcos" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pAcos" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "acos") (EVar "a"))))
(DFunDef false "pAcos" (PWild) (EApp (EVar "panic") (ELit (LString "acos: not a Float"))))
(DTypeSig false "pAtan" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pAtan" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "atan") (EVar "a"))))
(DFunDef false "pAtan" (PWild) (EApp (EVar "panic") (ELit (LString "atan: not a Float"))))
(DTypeSig false "pSinh" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pSinh" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "sinh") (EVar "a"))))
(DFunDef false "pSinh" (PWild) (EApp (EVar "panic") (ELit (LString "sinh: not a Float"))))
(DTypeSig false "pCosh" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCosh" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "cosh") (EVar "a"))))
(DFunDef false "pCosh" (PWild) (EApp (EVar "panic") (ELit (LString "cosh: not a Float"))))
(DTypeSig false "pTanh" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pTanh" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "tanh") (EVar "a"))))
(DFunDef false "pTanh" (PWild) (EApp (EVar "panic") (ELit (LString "tanh: not a Float"))))
(DTypeSig false "pFloor" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pFloor" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "floor") (EVar "a"))))
(DFunDef false "pFloor" (PWild) (EApp (EVar "panic") (ELit (LString "floor: not a Float"))))
(DTypeSig false "pCeil" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCeil" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "ceil") (EVar "a"))))
(DFunDef false "pCeil" (PWild) (EApp (EVar "panic") (ELit (LString "ceil: not a Float"))))
(DTypeSig false "pRound" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pRound" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "round") (EVar "a"))))
(DFunDef false "pRound" (PWild) (EApp (EVar "panic") (ELit (LString "round: not a Float"))))
(DTypeSig false "pTrunc" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pTrunc" ((PCon "VFloat" (PVar "a"))) (EApp (EVar "VFloat") (EApp (EVar "trunc") (EVar "a"))))
(DFunDef false "pTrunc" (PWild) (EApp (EVar "panic") (ELit (LString "trunc: not a Float"))))
(DTypeSig false "pPow" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pPow" ((PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EApp (EApp (EVar "pow") (EVar "a")) (EVar "b"))))
(DFunDef false "pPow" (PWild PWild) (EApp (EVar "panic") (ELit (LString "pow: bad operands"))))
(DTypeSig false "pAtan2" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pAtan2" ((PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EApp (EApp (EVar "atan2") (EVar "a")) (EVar "b"))))
(DFunDef false "pAtan2" (PWild PWild) (EApp (EVar "panic") (ELit (LString "atan2: bad operands"))))
(DTypeSig false "pHypot" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pHypot" ((PCon "VFloat" (PVar "a")) (PCon "VFloat" (PVar "b"))) (EApp (EVar "VFloat") (EApp (EApp (EVar "hypot") (EVar "a")) (EVar "b"))))
(DFunDef false "pHypot" (PWild PWild) (EApp (EVar "panic") (ELit (LString "hypot: bad operands"))))
(DTypeSig false "pStringToUpper" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringToUpper" ((PCon "VString" (PVar "s"))) (EApp (EVar "VString") (EApp (EVar "stringToUpper") (EVar "s"))))
(DFunDef false "pStringToUpper" (PWild) (EApp (EVar "panic") (ELit (LString "stringToUpper: not a String"))))
(DTypeSig false "pStringToLower" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStringToLower" ((PCon "VString" (PVar "s"))) (EApp (EVar "VString") (EApp (EVar "stringToLower") (EVar "s"))))
(DFunDef false "pStringToLower" (PWild) (EApp (EVar "panic") (ELit (LString "stringToLower: not a String"))))
(DTypeSig false "pStringCompare" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pStringCompare" ((PCon "VString" (PVar "a")) (PCon "VString" (PVar "b"))) (EApp (EVar "orderingToValue") (EApp (EApp (EVar "stringCompare") (EVar "a")) (EVar "b"))))
(DFunDef false "pStringCompare" (PWild PWild) (EApp (EVar "panic") (ELit (LString "stringCompare: not Strings"))))
(DTypeSig false "pStringIndexOf" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pStringIndexOf" ((PCon "VString" (PVar "needle")) (PCon "VString" (PVar "hay"))) (EApp (EVar "optionToValue") (EApp (EApp (EVar "mapOption") (EVar "VInt")) (EApp (EApp (EVar "stringIndexOf") (EVar "needle")) (EVar "hay")))))
(DFunDef false "pStringIndexOf" (PWild PWild) (EApp (EVar "panic") (ELit (LString "stringIndexOf: not Strings"))))
(DTypeSig false "pStringSlice" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "pStringSlice" ((PCon "VInt" (PVar "lo")) (PCon "VInt" (PVar "hi")) (PCon "VString" (PVar "s"))) (EApp (EVar "VString") (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EVar "hi")) (EVar "s"))))
(DFunDef false "pStringSlice" (PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "stringSlice: bad operands"))))
(DTypeSig false "pArrayLength" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pArrayLength" ((PCon "VArray" (PVar "a"))) (EApp (EVar "VInt") (EApp (EVar "arrayLength") (EVar "a"))))
(DFunDef false "pArrayLength" (PWild) (EApp (EVar "panic") (ELit (LString "arrayLength: not an Array"))))
(DTypeSig false "pArrayFromList" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pArrayFromList" ((PCon "VList" (PVar "vs"))) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EVar "vs"))))
(DFunDef false "pArrayFromList" (PWild) (EApp (EVar "panic") (ELit (LString "arrayFromList: not a List"))))
(DTypeSig false "pArrayGetUnsafe" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pArrayGetUnsafe" ((PCon "VInt" (PVar "i")) (PCon "VArray" (PVar "a"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a")))
(DFunDef false "pArrayGetUnsafe" (PWild PWild) (EApp (EVar "panic") (ELit (LString "arrayGetUnsafe: bad operands"))))
(DTypeSig false "pArrayMake" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pArrayMake" ((PCon "VInt" (PVar "n")) (PVar "v")) (EApp (EVar "VArray") (EApp (EApp (EVar "arrayMake") (EVar "n")) (EVar "v"))))
(DFunDef false "pArrayMake" (PWild PWild) (EApp (EVar "panic") (ELit (LString "arrayMake: bad operands"))))
(DTypeSig false "pArrayMakeWith" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pArrayMakeWith" ((PCon "VInt" (PVar "n")) (PVar "f")) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "buildWith") (EVar "f")) (ELit (LInt 0))) (EVar "n")))))
(DFunDef false "pArrayMakeWith" (PWild PWild) (EApp (EVar "panic") (ELit (LString "arrayMakeWith: bad operands"))))
(DTypeSig false "pArrayCopy" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pArrayCopy" ((PCon "VArray" (PVar "a"))) (EApp (EVar "VArray") (EApp (EVar "arrayCopy") (EVar "a"))))
(DFunDef false "pArrayCopy" (PWild) (EApp (EVar "panic") (ELit (LString "arrayCopy: not an Array"))))
(DTypeSig false "pArraySetUnsafe" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "pArraySetUnsafe" ((PCon "VInt" (PVar "i")) (PVar "v") (PCon "VArray" (PVar "a"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "v")) (EVar "a"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pArraySetUnsafe" (PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "arraySetUnsafe: bad operands"))))
(DTypeSig false "pArrayFill" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pArrayFill" ((PVar "v") (PCon "VArray" (PVar "a"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "arrayFill") (EVar "v")) (EVar "a"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pArrayFill" (PWild PWild) (EApp (EVar "panic") (ELit (LString "arrayFill: not an Array"))))
(DTypeSig false "blitGo" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyCon "Unit"))))))))
(DFunDef false "blitGo" ((PVar "src") (PVar "srcOff") (PVar "dst") (PVar "dstOff") (PVar "len")) (EIf (EBinOp "<=" (EVar "len") (ELit (LInt 0))) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "v") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "srcOff")) (EVar "src"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "dstOff")) (EVar "v")) (EVar "dst"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "blitGo") (EVar "src")) (EBinOp "+" (EVar "srcOff") (ELit (LInt 1)))) (EVar "dst")) (EBinOp "+" (EVar "dstOff") (ELit (LInt 1)))) (EBinOp "-" (EVar "len") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pArrayBlit" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "pArrayBlit" ((PCon "VArray" (PVar "src")) (PCon "VInt" (PVar "srcOff")) (PCon "VArray" (PVar "dst")) (PCon "VInt" (PVar "dstOff")) (PCon "VInt" (PVar "len"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "blitGo") (EVar "src")) (EVar "srcOff")) (EVar "dst")) (EVar "dstOff")) (EVar "len"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pArrayBlit" (PWild PWild PWild PWild PWild) (EApp (EVar "panic") (ELit (LString "arrayBlit: bad operands"))))
(DTypeSig false "buildWith" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyEffect () (Some "e") (TyApp (TyCon "List") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "buildWith" ((PVar "f") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EBinOp "::" (EApp (EApp (EVar "apply") (EVar "f")) (EApp (EVar "VInt") (EVar "i"))) (EApp (EApp (EApp (EVar "buildWith") (EVar "f")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))))
(DTypeSig false "mkGroup" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "mkGroup" ((PVar "defs") (PVar "name")) (ETuple (EVar "name") (EApp (EApp (EVar "clausesForName") (EVar "name")) (EVar "defs"))))
(DTypeSig true "installConsts" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyCon "Unit")))))
(DFunDef false "installConsts" (PWild (PList)) (ELit LUnit))
(DFunDef false "installConsts" ((PVar "cells") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EApp (EApp (EVar "findCell") (EVar "cells")) (EVar "n"))) (EVar "v"))) (DoExpr (EApp (EApp (EVar "installConsts") (EVar "cells")) (EVar "rest")))))
(DTypeSig false "installGroups" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))) (TyEffect () (Some "e") (TyCon "Unit"))))))
(DFunDef false "installGroups" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "installGroups" ((PVar "env") (PVar "cells") (PCons (PTuple (PVar "n") (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EApp (EApp (EVar "findCell") (EVar "cells")) (EVar "n"))) (EApp (EApp (EVar "topGroupValue") (EVar "env")) (EVar "clauses")))) (DoExpr (EApp (EApp (EApp (EVar "installGroups") (EVar "env")) (EVar "cells")) (EVar "rest")))))
(DTypeSig true "lookupBinding" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "lookupBinding" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupBinding" ((PVar "name") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupBinding") (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "noMainMsg" (TyCon "String"))
(DFunDef false "noMainMsg" () (ELit (LString "program has no 'main' binding")))
(DTypeSig true "evalMain" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "evalMain" ((PVar "prog")) (EMatch (EApp (EApp (EVar "lookupBinding") (ELit (LString "main"))) (EApp (EApp (EVar "evalOne") (EListLit)) (ETuple (ELit (LString "__main__")) (EVar "prog")))) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "ppValue") (EApp (EVar "force") (EVar "v")))) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-NO-MAIN"))) (EVar "noMainMsg")))))
(DTypeSig true "evalOutputWith" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "evalOutputWith" ((PVar "preludeDecls") (PVar "userDecls")) (EApp (EApp (EVar "evalOneOutput") (EListLit)) (ETuple (ELit (LString "__main__")) (EBinOp "++" (EApp (EApp (EVar "dropShadowed") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (EVar "preludeDecls")) (EVar "userDecls")))))
(DTypeSig true "funNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "funNamesOf" ((PVar "decls")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "funDefs") (EVar "decls"))))
(DTypeSig true "dropShadowedExp" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "dropShadowedExp" ((PVar "names") (PVar "decls")) (EApp (EApp (EVar "dropShadowed") (EVar "names")) (EVar "decls")))
(DTypeSig false "dropShadowed" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "dropShadowed" (PWild (PList)) (EListLit))
(DFunDef false "dropShadowed" ((PVar "names") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EApp (EVar "shadowedFun") (EVar "names")) (EVar "d")) (EApp (EApp (EVar "dropShadowed") (EVar "names")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "d") (EApp (EApp (EVar "dropShadowed") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "shadowedFun" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "shadowedFun" ((PVar "names") (PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "names")))
(DFunDef false "shadowedFun" (PWild PWild) (EVar "False"))
(DTypeSig false "runMainForEffect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "runMainForEffect" ((PVar "binds")) (EMatch (EApp (EApp (EVar "lookupBinding") (ELit (LString "main"))) (EVar "binds")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "force") (EVar "v"))) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-NO-MAIN"))) (EVar "noMainMsg")))))
(DData Private "ModInfo" ("v") ((variant "ModInfo" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyVar "v")))) (TyApp (TyCon "EvalEnv") (TyVar "v"))))) ())
(DTypeSig true "evalModules" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalModules" ((PVar "preludeDecls") (PVar "modules")) (EApp (EApp (EApp (EVar "evalModulesWith") (EListLit)) (EVar "preludeDecls")) (EVar "modules")))
(DTypeSig true "evalModulesWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "evalModulesWith" ((PVar "extraExterns") (PVar "preludeDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "externs") (EBinOp "++" (EApp (EVar "externBindings") (ELit LUnit)) (EVar "extraExterns"))) (DoLet false false (PVar "moduleDecls") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modules"))) (DoLet false false (PVar "allDecls") (EBinOp "++" (EVar "preludeDecls") (EVar "moduleDecls"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "ctorToTypeRef")) (EApp (EVar "buildCtorToType") (EVar "allDecls")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "methodReqCountRef")) (EApp (EVar "buildMethodReqCounts") (EVar "allDecls")))) (DoLet false false (PVar "disp") (EApp (EVar "buildIfaceDispatch") (EVar "allDecls"))) (DoLet false false (PVar "ctors") (EApp (EVar "collectCtors") (EVar "allDecls"))) (DoLet false false (PVar "preludeGroups") (EApp (EVar "groupsOf") (EVar "preludeDecls"))) (DoLet false false (PVar "globalNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "boolSeeds")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "externs"))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "ctors"))) (EApp (EVar "implMethodNames") (EVar "allDecls"))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "preludeGroups")))) (DoLet false false (PVar "globalCells") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "Ref") (EVar "VUnit"))))) (EVar "globalNames"))) (DoLet false false (PVar "globalEnv") (EApp (EVar "EvalEnv") (EListLit (EVar "globalCells")))) (DoLet false false (PVar "mods") (EApp (EApp (EApp (EVar "buildModInfos") (EVar "globalCells")) (EListLit)) (EVar "modules"))) (DoLet false false (PVar "implEntries") (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "declImplEntries") (EVar "globalEnv")) (EVar "disp"))) (EVar "preludeDecls")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "modImplEntries") (EVar "disp"))) (EVar "mods")))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "boolSeeds"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "externs"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "ctors"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EApp (EVar "coalesceImpls") (EVar "implEntries")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "installGroups") (EVar "globalEnv")) (EVar "globalCells")) (EVar "preludeGroups"))) (DoLet false false PWild (EApp (EVar "installModGroups") (EVar "mods"))) (DoExpr (EApp (EVar "rootLocals") (EVar "mods")))))
(DTypeSig false "buildModInfos" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyApp (TyCon "ModInfo") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "buildModInfos" (PWild PWild (PList)) (EListLit))
(DFunDef false "buildModInfos" ((PVar "globalCells") (PVar "exportsMap") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EBlock (DoLet false false (PVar "grps") (EApp (EVar "groupsOf") (EVar "decls"))) (DoLet false false (PVar "modCtors") (EApp (EVar "collectCtors") (EVar "decls"))) (DoLet false false (PVar "localCells") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "Ref") (EVar "VUnit"))))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "grps")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "modCtors"))))) (DoLet false false (PVar "imports") (EApp (EApp (EVar "importFrameOf") (EVar "exportsMap")) (EVar "decls"))) (DoLet false false (PVar "menv") (EApp (EVar "EvalEnv") (EListLit (EVar "localCells") (EVar "imports") (EVar "globalCells")))) (DoLet false false (PVar "exports") (EBinOp "++" (EBinOp "++" (EVar "localCells") (EApp (EApp (EVar "methodCellsOf") (EVar "globalCells")) (EVar "decls"))) (EApp (EApp (EApp (EVar "pubReexports") (EVar "globalCells")) (EVar "exportsMap")) (EVar "decls")))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "ModInfo") (EVar "mid")) (EVar "decls")) (EVar "grps")) (EVar "localCells")) (EVar "menv")) (EApp (EApp (EApp (EVar "buildModInfos") (EVar "globalCells")) (EBinOp "::" (ETuple (EVar "mid") (EVar "exports")) (EVar "exportsMap"))) (EVar "rest"))))))
(DTypeSig true "methodCellsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "methodCellsOf" ((PVar "globalCells") (PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "methodCell") (EVar "globalCells"))) (EApp (EVar "moduleMethodNames") (EVar "decls"))))
(DTypeSig false "methodCell" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "methodCell" ((PVar "globalCells") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "globalCells")) (arm (PCon "Some" (PVar "cell")) () (EListLit (ETuple (EVar "n") (EVar "cell")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "moduleMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleMethodNames" ((PVar "decls")) (EApp (EVar "dedup") (EApp (EApp (EDictApp "flatMap") (EVar "moduleMethodNamesOf")) (EVar "decls"))))
(DTypeSig false "moduleMethodNamesOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "moduleMethodNamesOf" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EVar "implMethodName")) (EVar "methods")))
(DFunDef false "moduleMethodNamesOf" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNmE")) (EVar "methods")))
(DFunDef false "moduleMethodNamesOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "moduleMethodNamesOf") (EVar "d")))
(DFunDef false "moduleMethodNamesOf" (PWild) (EListLit))
(DTypeSig false "ifaceMethodNmE" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodNmE" ((PCon "IfaceMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "installModGroups" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "ModInfo") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyCon "Unit"))))
(DFunDef false "installModGroups" ((PList)) (ELit LUnit))
(DFunDef false "installModGroups" ((PCons (PCon "ModInfo" PWild (PVar "decls") (PVar "grps") (PVar "cells") (PVar "menv")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "installGroups") (EVar "menv")) (EVar "cells")) (EVar "grps"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "cells")) (EApp (EVar "collectCtors") (EVar "decls")))) (DoExpr (EApp (EVar "installModGroups") (EVar "rest")))))
(DTypeSig false "modImplEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "ModInfo") (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "modImplEntries" ((PVar "disp") (PCon "ModInfo" PWild (PVar "decls") PWild PWild (PVar "menv"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "declImplEntries") (EVar "menv")) (EVar "disp"))) (EVar "decls")))
(DTypeSig false "rootLocals" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "ModInfo") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "rootLocals" ((PList)) (EListLit))
(DFunDef false "rootLocals" ((PList (PCon "ModInfo" PWild PWild PWild (PVar "cells") PWild))) (EApp (EApp (EMethodRef "map") (EVar "cellResult")) (EVar "cells")))
(DFunDef false "rootLocals" ((PCons PWild (PVar "rest"))) (EApp (EVar "rootLocals") (EVar "rest")))
(DTypeSig true "evalModulesRootEnv" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalModulesRootEnv" ((PVar "preludeDecls") (PVar "modules")) (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EListLit)) (EVar "preludeDecls")) (EVar "modules")))
(DTypeSig true "evalModulesRootEnvWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "evalModulesRootEnvWith" ((PVar "extraExterns") (PVar "preludeDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "externs") (EBinOp "++" (EApp (EVar "externBindings") (ELit LUnit)) (EVar "extraExterns"))) (DoLet false false (PVar "moduleDecls") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "modules"))) (DoLet false false (PVar "allDecls") (EBinOp "++" (EVar "preludeDecls") (EVar "moduleDecls"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "ctorToTypeRef")) (EApp (EVar "buildCtorToType") (EVar "allDecls")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "methodReqCountRef")) (EApp (EVar "buildMethodReqCounts") (EVar "allDecls")))) (DoLet false false (PVar "disp") (EApp (EVar "buildIfaceDispatch") (EVar "allDecls"))) (DoLet false false (PVar "ctors") (EApp (EVar "collectCtors") (EVar "allDecls"))) (DoLet false false (PVar "preludeGroups") (EApp (EVar "groupsOf") (EVar "preludeDecls"))) (DoLet false false (PVar "globalNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "boolSeeds")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "externs"))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "ctors"))) (EApp (EVar "implMethodNames") (EVar "allDecls"))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "preludeGroups")))) (DoLet false false (PVar "globalCells") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "Ref") (EVar "VUnit"))))) (EVar "globalNames"))) (DoLet false false (PVar "globalEnv") (EApp (EVar "EvalEnv") (EListLit (EVar "globalCells")))) (DoLet false false (PVar "mods") (EApp (EApp (EApp (EVar "buildModInfos") (EVar "globalCells")) (EListLit)) (EVar "modules"))) (DoLet false false (PVar "implEntries") (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "declImplEntries") (EVar "globalEnv")) (EVar "disp"))) (EVar "preludeDecls")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "modImplEntries") (EVar "disp"))) (EVar "mods")))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "boolSeeds"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "externs"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EVar "ctors"))) (DoLet false false PWild (EApp (EApp (EVar "installConsts") (EVar "globalCells")) (EApp (EVar "coalesceImpls") (EVar "implEntries")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "installGroups") (EVar "globalEnv")) (EVar "globalCells")) (EVar "preludeGroups"))) (DoLet false false PWild (EApp (EVar "installModGroups") (EVar "mods"))) (DoExpr (EApp (EApp (EVar "rootFullEnv") (EVar "mods")) (EVar "globalCells")))))
(DTypeSig false "rootFullEnv" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "ModInfo") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "rootFullEnv" ((PList) (PVar "globalCells")) (EApp (EApp (EMethodRef "map") (EVar "cellResult")) (EVar "globalCells")))
(DFunDef false "rootFullEnv" ((PList (PCon "ModInfo" PWild PWild PWild (PVar "cells") (PVar "menv"))) (PVar "globalCells")) (EApp (EVar "flattenEnv") (EVar "menv")))
(DFunDef false "rootFullEnv" ((PCons PWild (PVar "rest")) (PVar "globalCells")) (EApp (EApp (EVar "rootFullEnv") (EVar "rest")) (EVar "globalCells")))
(DTypeSig false "flattenEnv" (TyFun (TyApp (TyCon "EvalEnv") (TyApp (TyCon "Value") (TyVar "e"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "flattenEnv" ((PCon "EvalEnv" (PVar "frames"))) (EApp (EApp (EMethodRef "map") (EVar "cellResult")) (EApp (EVar "concatList") (EVar "frames"))))
(DTypeSig false "concatList" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "concatList" ((PList)) (EListLit))
(DFunDef false "concatList" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EVar "x") (EApp (EVar "concatList") (EVar "xs"))))
(DTypeSig false "groupsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "groupsOf" ((PVar "decls")) (EBlock (DoLet false false (PVar "defs") (EApp (EVar "funDefs") (EVar "decls"))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EVar "mkGroup") (EVar "defs"))) (EApp (EApp (EVar "funGroupNames") (EVar "defs")) (EListLit))))))
(DTypeSig true "importFrameOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "importFrameOf" ((PVar "exportsMap") (PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "useImports") (EVar "exportsMap"))) (EVar "decls")))
(DTypeSig false "useImports" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "useImports" ((PVar "exportsMap") (PCon "DUse" PWild (PVar "path") PWild)) (EMatch (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "useModuleId") (EVar "path"))) (EVar "exportsMap")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exports")) () (EApp (EApp (EVar "resolveMembers") (EVar "path")) (EVar "exports")))))
(DFunDef false "useImports" (PWild PWild) (EListLit))
(DTypeSig true "pubReexports" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "pubReexports" ((PVar "globalCells") (PVar "exportsMap") (PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "reexport") (EVar "globalCells")) (EVar "exportsMap"))) (EVar "decls")))
(DTypeSig false "reexport" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "reexport" ((PVar "globalCells") (PVar "exportsMap") (PCon "DUse" (PCon "True") (PVar "path") PWild)) (EBlock (DoLet false false (PVar "src") (EIf (EBinOp "==" (EApp (EVar "useModuleId") (EVar "path")) (ELit (LString "core"))) (EApp (EVar "Some") (EVar "globalCells")) (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "useModuleId") (EVar "path"))) (EVar "exportsMap")))) (DoExpr (EMatch (EVar "src") (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exports")) () (EApp (EApp (EVar "resolveMembers") (EVar "path")) (EVar "exports")))))))
(DFunDef false "reexport" (PWild PWild PWild) (EListLit))
(DTypeSig false "resolveMembers" (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "resolveMembers" ((PCon "UseName" (PVar "ns")) (PVar "exports")) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EApp (EVar "bindNames") (EListLit (EApp (EVar "selfBind") (EApp (EVar "lastOfList") (EVar "ns"))))) (EVar "exports")) (EListLit)))
(DFunDef false "resolveMembers" ((PCon "UseGroup" PWild (PVar "ms")) (PVar "exports")) (EApp (EApp (EVar "bindNames") (EApp (EApp (EMethodRef "map") (EVar "memberBind")) (EVar "ms"))) (EVar "exports")))
(DFunDef false "resolveMembers" ((PCon "UseWild" PWild) (PVar "exports")) (EVar "exports"))
(DFunDef false "resolveMembers" ((PCon "UseAlias" PWild (PVar "a")) (PVar "exports")) (EApp (EApp (EMethodRef "map") (EApp (EVar "qualifyCell") (EVar "a"))) (EVar "exports")))
(DTypeSig false "qualifyCell" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))) (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e")))))))
(DFunDef false "qualifyCell" ((PVar "a") (PTuple (PVar "n") (PVar "cell"))) (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "n")) (EVar "cell")))
(DTypeSig false "bindNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "bindNames" ((PList) PWild) (EListLit))
(DFunDef false "bindNames" ((PCons (PTuple (PVar "origin") (PVar "local")) (PVar "rest")) (PVar "exports")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "origin")) (EVar "exports")) (arm (PCon "Some" (PVar "cell")) () (EBinOp "::" (ETuple (EVar "local") (EVar "cell")) (EApp (EApp (EVar "bindNames") (EVar "rest")) (EVar "exports")))) (arm (PCon "None") () (EApp (EApp (EVar "bindNames") (EVar "rest")) (EVar "exports")))))
(DTypeSig false "memberBind" (TyFun (TyCon "UseMember") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "memberBind" ((PVar "m")) (ETuple (EApp (EVar "useMemberOrigin") (EVar "m")) (EApp (EVar "useMemberLocal") (EVar "m"))))
(DTypeSig false "selfBind" (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "selfBind" ((PVar "n")) (ETuple (EVar "n") (EVar "n")))
(DTypeSig false "useModuleId" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useModuleId" ((PCon "UseName" (PVar "ns"))) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EVar "joinDot") (EApp (EVar "initList") (EVar "ns"))) (EApp (EVar "firstOrEmpty") (EVar "ns"))))
(DFunDef false "useModuleId" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModuleId" ((PCon "UseWild" (PVar "ns"))) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModuleId" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DTypeSig false "lastOfList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastOfList" ((PList)) (ELit (LString "")))
(DFunDef false "lastOfList" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOfList" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastOfList") (EVar "rest")))
(DTypeSig false "firstOrEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "firstOrEmpty" ((PList)) (ELit (LString "")))
(DFunDef false "firstOrEmpty" ((PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig true "evalModulesOutput" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String"))))
(DFunDef false "evalModulesOutput" ((PVar "preludeDecls") (PVar "modules")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false (PVar "binds") (EApp (EApp (EVar "evalModules") (EVar "preludeDecls")) (EVar "modules"))) (DoLet false false PWild (EApp (EVar "runMainForEffect") (EVar "binds"))) (DoExpr (EFieldAccess (EVar "outputRef") "value"))))
(DTypeSig false "pReadFile" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileRead")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pReadFile" ((PCon "VString" (PVar "path"))) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Ok" (PVar "s")) () (EApp (EApp (EVar "VCon") (ELit (LString "Ok"))) (EListLit (EApp (EVar "VString") (EVar "s"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EApp (EVar "VCon") (ELit (LString "Err"))) (EListLit (EApp (EVar "VString") (EVar "m")))))))
(DFunDef false "pReadFile" (PWild) (EApp (EVar "panic") (ELit (LString "readFile: not a String"))))
(DTypeSig false "resultToValue" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Value") (TyVar "e"))) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "resultToValue" ((PCon "Ok" (PVar "v"))) (EApp (EApp (EVar "VCon") (ELit (LString "Ok"))) (EListLit (EVar "v"))))
(DFunDef false "resultToValue" ((PCon "Err" (PVar "m"))) (EApp (EApp (EVar "VCon") (ELit (LString "Err"))) (EListLit (EApp (EVar "VString") (EVar "m")))))
(DTypeSig false "unitResultToValue" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "unitResultToValue" ((PVar "r")) (EApp (EVar "resultToValue") (EApp (EApp (EVar "mapResultOk") (ELam (PWild) (EVar "VUnit"))) (EVar "r"))))
(DTypeSig false "mapResultOk" (TyFun (TyFun (TyVar "a") (TyVar "b")) (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "b")))))
(DFunDef false "mapResultOk" ((PVar "f") (PCon "Ok" (PVar "v"))) (EApp (EVar "Ok") (EApp (EVar "f") (EVar "v"))))
(DFunDef false "mapResultOk" (PWild (PCon "Err" (PVar "m"))) (EApp (EVar "Err") (EVar "m")))
(DTypeSig false "vStringList" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "vStringList" ((PVar "xs")) (EApp (EVar "VList") (EApp (EApp (EMethodRef "map") (EVar "VString")) (EVar "xs"))))
(DTypeSig false "vIntArray" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "vIntArray" ((PVar "bs")) (EApp (EVar "VArray") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "VInt")) (EApp (EVar "arrayToListG") (EVar "bs"))))))
(DTypeSig false "unIntArray" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "unIntArray" ((PCon "VArray" (PVar "vs"))) (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "unInt")) (EApp (EVar "arrayToListG") (EVar "vs")))))
(DFunDef false "unIntArray" (PWild) (EApp (EVar "panic") (ELit (LString "expected an Array of Int"))))
(DTypeSig false "vOptionString" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "vOptionString" ((PVar "o")) (EApp (EVar "optionToValue") (EApp (EApp (EVar "mapOption") (EVar "VString")) (EVar "o"))))
(DTypeSig false "pWallTimeSecIO" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Clock") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pWallTimeSecIO" (PWild) (EApp (EVar "VFloat") (EApp (EVar "wallTimeSec") (ELit LUnit))))
(DTypeSig false "pMonotonicSecIO" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Clock") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pMonotonicSecIO" (PWild) (EApp (EVar "VFloat") (EApp (EVar "monotonicSec") (ELit LUnit))))
(DTypeSig false "pSleepMsIO" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Clock") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pSleepMsIO" ((PCon "VInt" (PVar "n"))) (EBlock (DoLet false false PWild (EApp (EVar "sleepMs") (EVar "n"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pSleepMsIO" (PWild) (EApp (EVar "panic") (ELit (LString "sleepMs: expected Int"))))
(DTypeSig false "pExit" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pExit" ((PCon "VInt" (PVar "n"))) (EBlock (DoLet false false PWild (EApp (EVar "exit") (EVar "n"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pExit" (PWild) (EApp (EVar "panic") (ELit (LString "exit: not an Int"))))
(DTypeSig false "pAllocBytesIO" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("IO") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pAllocBytesIO" (PWild) (EApp (EVar "VFloat") (EApp (EVar "allocBytes") (ELit LUnit))))
(DTypeSig false "pEPutStr" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Stderr") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pEPutStr" ((PCon "VString" (PVar "s"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStr") (EVar "s"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pEPutStr" (PWild) (EApp (EVar "panic") (ELit (LString "ePutStr: not a String"))))
(DTypeSig false "pEPutStrLn" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Stderr") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pEPutStrLn" ((PCon "VString" (PVar "s"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "s"))) (DoExpr (EVar "VUnit"))))
(DFunDef false "pEPutStrLn" (PWild) (EApp (EVar "panic") (ELit (LString "ePutStrLn: not a String"))))
(DTypeSig false "pReadFileBytes" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileRead")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pReadFileBytes" ((PCon "VString" (PVar "path"))) (EApp (EVar "resultToValue") (EApp (EApp (EVar "mapResultOk") (EVar "vIntArray")) (EApp (EVar "readFileBytes") (EVar "path")))))
(DFunDef false "pReadFileBytes" (PWild) (EApp (EVar "panic") (ELit (LString "readFileBytes: not a String"))))
(DTypeSig false "pFileExists" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileRead")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pFileExists" ((PCon "VString" (PVar "path"))) (EApp (EVar "VBool") (EApp (EVar "fileExists") (EVar "path"))))
(DFunDef false "pFileExists" (PWild) (EApp (EVar "panic") (ELit (LString "fileExists: not a String"))))
(DTypeSig false "pCanonicalizePath" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileRead")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pCanonicalizePath" ((PCon "VString" (PVar "path"))) (EApp (EVar "VString") (EApp (EVar "canonicalizePath") (EVar "path"))))
(DFunDef false "pCanonicalizePath" (PWild) (EApp (EVar "panic") (ELit (LString "canonicalizePath: not a String"))))
(DTypeSig false "pListDir" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileRead")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pListDir" ((PCon "VString" (PVar "path"))) (EApp (EVar "resultToValue") (EApp (EApp (EVar "mapResultOk") (EVar "vStringList")) (EApp (EVar "listDir") (EVar "path")))))
(DFunDef false "pListDir" (PWild) (EApp (EVar "panic") (ELit (LString "listDir: not a String"))))
(DTypeSig false "pStatFile" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileRead")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pStatFile" ((PCon "VString" (PVar "path"))) (EApp (EVar "resultToValue") (EApp (EApp (EVar "mapResultOk") (EVar "statTuple")) (EApp (EVar "statFile") (EVar "path")))))
(DFunDef false "pStatFile" (PWild) (EApp (EVar "panic") (ELit (LString "statFile: not a String"))))
(DTypeSig false "statTuple" (TyFun (TyTuple (TyCon "Int") (TyCon "Bool") (TyCon "Bool") (TyCon "Float")) (TyApp (TyCon "Value") (TyVar "e"))))
(DFunDef false "statTuple" ((PTuple (PVar "sz") (PVar "isDir") (PVar "isFile") (PVar "mtime"))) (EApp (EVar "VTuple") (EListLit (EApp (EVar "VInt") (EVar "sz")) (EApp (EVar "VBool") (EVar "isDir")) (EApp (EVar "VBool") (EVar "isFile")) (EApp (EVar "VFloat") (EVar "mtime")))))
(DTypeSig false "pWriteFile" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileWrite")) (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pWriteFile" ((PCon "VString" (PVar "path")) (PCon "VString" (PVar "s"))) (EApp (EVar "unitResultToValue") (EApp (EApp (EVar "writeFile") (EVar "path")) (EVar "s"))))
(DFunDef false "pWriteFile" (PWild PWild) (EApp (EVar "panic") (ELit (LString "writeFile: expected String String"))))
(DTypeSig false "pWriteFileBytes" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileWrite")) (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pWriteFileBytes" ((PCon "VString" (PVar "path")) (PVar "bs")) (EApp (EVar "unitResultToValue") (EApp (EApp (EVar "writeFileBytes") (EVar "path")) (EApp (EVar "unIntArray") (EVar "bs")))))
(DFunDef false "pWriteFileBytes" (PWild PWild) (EApp (EVar "panic") (ELit (LString "writeFileBytes: expected String (Array Int)"))))
(DTypeSig false "pAppendFile" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileWrite")) (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pAppendFile" ((PCon "VString" (PVar "path")) (PCon "VString" (PVar "s"))) (EApp (EVar "unitResultToValue") (EApp (EApp (EVar "appendFile") (EVar "path")) (EVar "s"))))
(DFunDef false "pAppendFile" (PWild PWild) (EApp (EVar "panic") (ELit (LString "appendFile: expected String String"))))
(DTypeSig false "pMakeDir" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileWrite")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pMakeDir" ((PCon "VString" (PVar "path"))) (EApp (EVar "unitResultToValue") (EApp (EVar "makeDir") (EVar "path"))))
(DFunDef false "pMakeDir" (PWild) (EApp (EVar "panic") (ELit (LString "makeDir: not a String"))))
(DTypeSig false "pRemoveFile" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileWrite")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pRemoveFile" ((PCon "VString" (PVar "path"))) (EApp (EVar "unitResultToValue") (EApp (EVar "removeFile") (EVar "path"))))
(DFunDef false "pRemoveFile" (PWild) (EApp (EVar "panic") (ELit (LString "removeFile: not a String"))))
(DTypeSig false "pRemoveDir" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileWrite")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pRemoveDir" ((PCon "VString" (PVar "path"))) (EApp (EVar "unitResultToValue") (EApp (EVar "removeDir") (EVar "path"))))
(DFunDef false "pRemoveDir" (PWild) (EApp (EVar "panic") (ELit (LString "removeDir: not a String"))))
(DTypeSig false "pRename" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "FileWrite")) (Some "e") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "pRename" ((PCon "VString" (PVar "old")) (PCon "VString" (PVar "new"))) (EApp (EVar "unitResultToValue") (EApp (EApp (EVar "rename") (EVar "old")) (EVar "new"))))
(DFunDef false "pRename" (PWild PWild) (EApp (EVar "panic") (ELit (LString "rename: expected String String"))))
(DTypeSig true "progArgsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "progArgsRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "pArgs" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Env") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pArgs" (PWild) (EApp (EVar "vStringList") (EFieldAccess (EVar "progArgsRef") "value")))
(DTypeSig false "pGetEnv" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ((hole "Env")) (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pGetEnv" ((PCon "VString" (PVar "name"))) (EApp (EVar "vOptionString") (EApp (EVar "getEnv") (EVar "name"))))
(DFunDef false "pGetEnv" (PWild) (EApp (EVar "panic") (ELit (LString "getEnv: not a String"))))
(DTypeSig false "pExecutablePath" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Env") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pExecutablePath" (PWild) (EApp (EVar "VString") (EApp (EVar "executablePath") (ELit LUnit))))
(DTypeSig false "pBuildFingerprint" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Env") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pBuildFingerprint" (PWild) (EApp (EVar "VString") (EApp (EVar "buildFingerprint") (ELit LUnit))))
(DTypeSig false "pReadLine" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Stdin") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pReadLine" (PWild) (EApp (EVar "VString") (EApp (EVar "readLine") (ELit LUnit))))
(DTypeSig false "pReadLineOpt" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Stdin") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pReadLineOpt" (PWild) (EApp (EVar "vOptionString") (EApp (EVar "readLineOpt") (ELit LUnit))))
(DTypeSig false "pReadAll" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Stdin") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pReadAll" (PWild) (EApp (EVar "VString") (EApp (EVar "readAll") (ELit LUnit))))
(DTypeSig false "pReadExactly" (TyFun (TyApp (TyCon "Value") (TyVar "e")) (TyEffect ("Stdin") (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "pReadExactly" ((PCon "VInt" (PVar "n"))) (EApp (EVar "vOptionString") (EApp (EVar "readExactly") (EVar "n"))))
(DFunDef false "pReadExactly" (PWild) (EApp (EVar "panic") (ELit (LString "readExactly: expected Int"))))
(DTypeSig true "ioExternBindings" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "ioExternBindings" (PWild) (EListLit (ETuple (ELit (LString "wallTimeSec")) (EApp (EVar "prim1M") (EVar "pWallTimeSecIO"))) (ETuple (ELit (LString "monotonicSec")) (EApp (EVar "prim1M") (EVar "pMonotonicSecIO"))) (ETuple (ELit (LString "sleepMs")) (EApp (EVar "prim1M") (EVar "pSleepMsIO"))) (ETuple (ELit (LString "allocBytes")) (EApp (EVar "prim1M") (EVar "pAllocBytesIO"))) (ETuple (ELit (LString "ePutStr")) (EApp (EVar "prim1M") (EVar "pEPutStr"))) (ETuple (ELit (LString "ePutStrLn")) (EApp (EVar "prim1M") (EVar "pEPutStrLn"))) (ETuple (ELit (LString "readFile")) (EApp (EVar "prim1") (EVar "pReadFile"))) (ETuple (ELit (LString "readFileBytes")) (EApp (EVar "prim1") (EVar "pReadFileBytes"))) (ETuple (ELit (LString "fileExists")) (EApp (EVar "prim1") (EVar "pFileExists"))) (ETuple (ELit (LString "canonicalizePath")) (EApp (EVar "prim1") (EVar "pCanonicalizePath"))) (ETuple (ELit (LString "listDir")) (EApp (EVar "prim1") (EVar "pListDir"))) (ETuple (ELit (LString "statFile")) (EApp (EVar "prim1") (EVar "pStatFile"))) (ETuple (ELit (LString "writeFile")) (EApp (EVar "prim2M") (EVar "pWriteFile"))) (ETuple (ELit (LString "writeFileBytes")) (EApp (EVar "prim2M") (EVar "pWriteFileBytes"))) (ETuple (ELit (LString "appendFile")) (EApp (EVar "prim2M") (EVar "pAppendFile"))) (ETuple (ELit (LString "makeDir")) (EApp (EVar "prim1") (EVar "pMakeDir"))) (ETuple (ELit (LString "removeFile")) (EApp (EVar "prim1") (EVar "pRemoveFile"))) (ETuple (ELit (LString "removeDir")) (EApp (EVar "prim1") (EVar "pRemoveDir"))) (ETuple (ELit (LString "rename")) (EApp (EVar "prim2M") (EVar "pRename"))) (ETuple (ELit (LString "args")) (EApp (EVar "prim1M") (EVar "pArgs"))) (ETuple (ELit (LString "getEnv")) (EApp (EVar "prim1") (EVar "pGetEnv"))) (ETuple (ELit (LString "executablePath")) (EApp (EVar "prim1M") (EVar "pExecutablePath"))) (ETuple (ELit (LString "buildFingerprint")) (EApp (EVar "prim1M") (EVar "pBuildFingerprint"))) (ETuple (ELit (LString "readLine")) (EApp (EVar "prim1M") (EVar "pReadLine"))) (ETuple (ELit (LString "readLineOpt")) (EApp (EVar "prim1M") (EVar "pReadLineOpt"))) (ETuple (ELit (LString "readAll")) (EApp (EVar "prim1M") (EVar "pReadAll"))) (ETuple (ELit (LString "readExactly")) (EApp (EVar "prim1") (EVar "pReadExactly"))) (ETuple (ELit (LString "exit")) (EApp (EVar "prim1") (EVar "pExit")))))
(DTypeSig true "testCapableExterns" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "testCapableExterns" (PWild) (EListLit (ETuple (ELit (LString "wallTimeSec")) (EApp (EVar "prim1M") (EVar "pWallTimeSecIO"))) (ETuple (ELit (LString "monotonicSec")) (EApp (EVar "prim1M") (EVar "pMonotonicSecIO"))) (ETuple (ELit (LString "allocBytes")) (EApp (EVar "prim1M") (EVar "pAllocBytesIO"))) (ETuple (ELit (LString "ePutStr")) (EApp (EVar "prim1M") (EVar "pEPutStr"))) (ETuple (ELit (LString "ePutStrLn")) (EApp (EVar "prim1M") (EVar "pEPutStrLn")))))
(DTypeSig true "evalModulesOutputRun" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect ("IO") None (TyCon "String")))))
(DFunDef false "evalModulesOutputRun" ((PVar "preludeDecls") (PVar "modules")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "enableRunStdoutFlush") (ELit LUnit))) (DoLet false false (PVar "binds") (EApp (EApp (EApp (EVar "evalModulesWith") (EApp (EVar "ioExternBindings") (ELit LUnit))) (EVar "preludeDecls")) (EVar "modules"))) (DoLet false false PWild (EApp (EVar "runMainForEffect") (EVar "binds"))) (DoExpr (EFieldAccess (EVar "outputRef") "value"))))
(DTypeSig true "evalModulesOutputAsync" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyEffect () (Some "e") (TyCon "String")))))
(DFunDef false "evalModulesOutputAsync" ((PVar "preludeDecls") (PVar "modules")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "enableRunStdoutFlush") (ELit LUnit))) (DoLet false false (PVar "binds") (EApp (EApp (EVar "evalModulesRootEnv") (EVar "preludeDecls")) (EVar "modules"))) (DoLet false false PWild (EApp (EVar "driveAsyncMain") (EVar "binds"))) (DoExpr (EFieldAccess (EVar "outputRef") "value"))))
(DTypeSig false "driveAsyncMain" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyEffect () (Some "e") (TyApp (TyCon "Value") (TyVar "e")))))
(DFunDef false "driveAsyncMain" ((PVar "binds")) (EMatch (EApp (EApp (EVar "lookupBinding") (ELit (LString "main"))) (EVar "binds")) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-NO-MAIN"))) (EVar "noMainMsg"))) (arm (PCon "Some" (PVar "mv")) () (EMatch (EApp (EApp (EVar "lookupBinding") (ELit (LString "runAsync"))) (EVar "binds")) (arm (PCon "Some" (PVar "rf")) () (EApp (EApp (EVar "apply") (EVar "rf")) (EApp (EVar "force") (EVar "mv")))) (arm (PCon "None") () (EApp (EApp (EVar "runtimePanic") (ELit (LString "E-NO-RUNASYNC"))) (ELit (LString "main : Async _ requires `runAsync` in scope. Add `import async`"))))))))
(DTypeSig true "evalOne" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalOne" ((PVar "preludeDecls") (PTuple (PVar "rootId") (PVar "prog"))) (EApp (EApp (EVar "evalModules") (EVar "preludeDecls")) (EListLit (ETuple (EVar "rootId") (EVar "prog")))))
(DTypeSig true "evalOneWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "evalOneWith" ((PVar "extraExterns") (PVar "preludeDecls") (PTuple (PVar "rootId") (PVar "prog"))) (EApp (EApp (EApp (EVar "evalModulesWith") (EVar "extraExterns")) (EVar "preludeDecls")) (EListLit (ETuple (EVar "rootId") (EVar "prog")))))
(DTypeSig true "evalOneOutput" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "String"))))
(DFunDef false "evalOneOutput" ((PVar "preludeDecls") (PTuple (PVar "rootId") (PVar "prog"))) (EApp (EApp (EVar "evalModulesOutput") (EVar "preludeDecls")) (EListLit (ETuple (EVar "rootId") (EVar "prog")))))
(DTypeSig true "evalOneRootEnv" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e"))))))))
(DFunDef false "evalOneRootEnv" ((PVar "preludeDecls") (PTuple (PVar "rootId") (PVar "prog"))) (EApp (EApp (EVar "evalModulesRootEnv") (EVar "preludeDecls")) (EListLit (ETuple (EVar "rootId") (EVar "prog")))))
(DTypeSig true "evalOneRootEnvWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))))))))
(DFunDef false "evalOneRootEnvWith" ((PVar "extraExterns") (PVar "preludeDecls") (PTuple (PVar "rootId") (PVar "prog"))) (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EVar "extraExterns")) (EVar "preludeDecls")) (EListLit (ETuple (EVar "rootId") (EVar "prog")))))
