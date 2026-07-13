# META
source_lines=876
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted exhaust stage — Stage 4 port of `lib/exhaust.ml`'s standalone
-- `check_guard_exhaustiveness` (Phase 91(2)).  Runs on the RAW (pre-desugar)
-- AST — function/where guards are still `EGuards` nodes — and warns when a
-- multi-clause group's guards may fall through with nothing guaranteed to
-- produce a value, *unless* the non-falling-through clauses' patterns already
-- cover every input (decided by the Maranget pattern-matrix `useful` recursion).
--
-- Needs no prelude: the constructor oracle is built from the file's own data
-- decls plus the syntactic builtins (Bool/List/Unit).  Validated byte-for-byte
-- against `dev/diagdump.exe --exhaust` (test/diff_compiler_exhaust.sh).  The
-- match/clause exhaustiveness (`check_match`) is type-aware and lives in
-- typecheck, so it is out of scope here.

import frontend.ast.{
  Lit(..),
  Loc,
  Ty(..),
  Constraint(..),
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
import list.{replicate, take, drop}
import support.ordmap.{
  OrdMap,
  omEmpty,
  omInsert,
  omLookup,
  omHasKey,
  omFromPairs,
}
import support.util.{
  contains,
  allList,
  anyList,
  listLen,
  reverseL,
  joinNl,
  joinWith,
  orElseOpt,
  reverseL,
}

-- ── small helpers ─────────────────────────────────────────────────────────

-- ── synthetic tuple constructor names ─────────────────────────────────────
-- (exported so the type-aware `check_match` exhaustiveness in typecheck.mdk can
-- reuse the same synthetic per-arity tuple constructor names.)
export tupleCtorName : Int -> String
tupleCtorName n = "__tuple\{n}__"

-- recover the arity from a tupleCtorName result, else None
tupleArityOfName : String -> Option Int
tupleArityOfName c =
  let cs = stringToChars c
  tupleArityCheck cs (arrayLength cs)

tupleArityCheck : Array Char -> Int -> Option Int
tupleArityCheck cs n
  | n > 9 && charsPrefixTuple cs && charsSuffixUnder cs n =
    parseDigits cs 7 (n - 2)
  | otherwise = None

charsPrefixTuple : Array Char -> Bool
charsPrefixTuple cs = arrayGetUnsafe 0 cs == '_'
  && arrayGetUnsafe 1 cs == '_'
  && arrayGetUnsafe 2 cs == 't'
  && arrayGetUnsafe 3 cs == 'u'
  && arrayGetUnsafe 4 cs == 'p'
  && arrayGetUnsafe 5 cs == 'l'
  && arrayGetUnsafe 6 cs == 'e'

charsSuffixUnder : Array Char -> Int -> Bool
charsSuffixUnder cs n = arrayGetUnsafe (n - 2) cs == '_'
  && arrayGetUnsafe (n - 1) cs == '_'

parseDigits : Array Char -> Int -> Int -> Option Int
parseDigits cs start end = parseDigitsGo cs start end 0 False

parseDigitsGo : Array Char -> Int -> Int -> Int -> Bool -> Option Int
parseDigitsGo cs i end acc seen
  | i >= end = if seen then Some acc else None
  | isDigitC (arrayGetUnsafe i cs) = parseDigitsGo cs (i + 1) end (acc * 10 + digitVal (arrayGetUnsafe i cs)) True
  | otherwise = None

isDigitC : Char -> Bool
isDigitC c = c >= '0' && c <= '9'

digitVal : Char -> Int
digitVal c = charCode c - charCode '0'

-- ── the constructor oracle ────────────────────────────────────────────────
-- type → its constructors; ctor → arity; ctor → its type.  User data first so
-- it overrides the builtins (mirrors Hashtbl.replace's last-wins for find).
-- (exported, with `buildOracle`, so typecheck.mdk's `check_match` can reuse the
-- same oracle + matrix machinery — see the note at the top of this file.)
public export data Oracle = Oracle {
    typeCtors : OrdMap (List String),
    ctorArity : OrdMap Int,
    ctorType : OrdMap String,
    ctorFields : OrdMap (List String),  -- ctor → declared field names in order (DData ConNamed variants)
  }

export buildOracle : List Decl -> Oracle
buildOracle prog = Oracle {
  typeCtors = oracleMap (flatMap dataTypeCtors prog ++ builtinTypeCtors),
  ctorArity = oracleMap (flatMap dataArity prog ++ builtinArity),
  ctorType = oracleMap (flatMap dataCtorType prog ++ builtinCtorType),
  ctorFields = oracleMap (flatMap dataCtorFields prog),
}

-- PERF: the oracle's four tables used to be plain association LISTS, so every
-- ctor→arity / type→ctors lookup was an O(#ctors) scan.  `usefulCovered` does one
-- per signature constructor, which makes it O(#ctors²) on a wide ADT.  An OrdMap
-- makes each lookup O(log n).
--
-- The lists were consulted with `lookupAssoc`, which returns the FIRST match — the
-- convention the tables are built for (user data is placed ahead of the builtins so
-- it shadows them, and an earlier `data` decl shadows a later one).  `omFromPairs`
-- is last-write-wins, so the pairs are REVERSED before folding them in, which
-- reproduces first-match-wins exactly.
oracleMap : List (String, a) -> OrdMap a
oracleMap pairs = omFromPairs (reverseL pairs) omEmpty

builtinTypeCtors : List (String, List String)
builtinTypeCtors =
  [("Bool", ["True", "False"]), ("List", ["Cons", "Nil"]), ("Unit", ["Unit"])]

builtinArity : List (String, Int)
builtinArity = [("True", 0), ("False", 0), ("Cons", 2), ("Nil", 0), ("Unit", 0)]

builtinCtorType : List (String, String)
builtinCtorType = [
  ("True", "Bool"),
  ("False", "Bool"),
  ("Cons", "List"),
  ("Nil", "List"),
  ("Unit", "Unit"),
]

dataTypeCtors : Decl -> List (String, List String)
dataTypeCtors (DData _ tyname _ variants _) =
  [(tyname, map variantName variants)]
dataTypeCtors _ = []

dataArity : Decl -> List (String, Int)
dataArity (DData _ _ _ variants _) = map variantArity variants
dataArity _ = []

dataCtorType : Decl -> List (String, String)
dataCtorType (DData _ tyname _ variants _) =
  map (variantCtorType tyname) variants
dataCtorType _ = []

variantName : Variant -> String
variantName (Variant n _) = n

variantArity : Variant -> (String, Int)
variantArity (Variant n (ConPos tys)) = (n, listLen tys)
variantArity (Variant n (ConNamed fs _)) = (n, listLen fs)

variantCtorType : String -> Variant -> (String, String)
variantCtorType tyname (Variant n _) = (n, tyname)

dataCtorFields : Decl -> List (String, List String)
dataCtorFields (DData _ _ _ variants _) = flatMap variantCtorFields variants
dataCtorFields _ = []

variantCtorFields : Variant -> List (String, List String)
variantCtorFields (Variant n (ConNamed fs _)) = [(n, map fieldName fs)]
variantCtorFields _ = []

fieldName : Field -> String
fieldName (Field n _) = n

oGetCtorFields : Oracle -> String -> Option (List String)
oGetCtorFields oracle c = omLookup c oracle.ctorFields

export oGetCtors : Oracle -> String -> Option (List String)
oGetCtors oracle t
  | (Some _) <- tupleArityOfName t = Some [t]
  | otherwise = omLookup t oracle.typeCtors

export oGetCtorType : Oracle -> String -> Option String
oGetCtorType oracle c
  | (Some _) <- tupleArityOfName c = Some c
  | otherwise = omLookup c oracle.ctorType

oGetArity : Oracle -> String -> Int
oGetArity oracle c
  | (Some a) <- tupleArityOfName c = a
  | otherwise = fromOption 0 (omLookup c oracle.ctorArity)

-- ── pattern → canonical matrix pattern ────────────────────────────────────
export desugarPat : Oracle -> Pat -> Pat
desugarPat _ PWild = PWild
desugarPat _ (PVar _) = PWild
desugarPat _ (PLit (LBool True)) = PCon "True" []
desugarPat _ (PLit (LBool False)) = PCon "False" []
desugarPat _ (PLit LUnit) = PCon "Unit" []
desugarPat _ (PLit l) = PLit l
desugarPat oracle (PTuple ps) =
  PCon (tupleCtorName (listLen ps)) (map (desugarPat oracle) ps)
desugarPat oracle (PCon c args) = PCon c (map (desugarPat oracle) args)
desugarPat oracle (PCons h t) =
  PCon "Cons" [desugarPat oracle h, desugarPat oracle t]
desugarPat _ (PList []) = PCon "Nil" []
desugarPat oracle (PList (h::rest)) =
  PCon "Cons" [desugarPat oracle h, desugarPat oracle (PList rest)]
desugarPat oracle (PAs _ p) = desugarPat oracle p
desugarPat _ (PRec _ _ True) = PWild
desugarPat oracle (PRec name fields _) =
  -- Lower a record pattern to a constructor-tagged row.
  -- For each declared field (in declaration order) use the sub-pattern if
  -- mentioned in this pattern, otherwise PWild.  Falls back to PWild if the
  -- constructor's field layout is unknown (e.g. builtins).
  match oGetCtorFields oracle name
    None => PWild
    Some fieldOrder => PCon name (map (lookupRecField oracle fields) fieldOrder)
desugarPat _ (PRng _ _ _) = PWild

lookupRecField : Oracle -> List RecPatField -> String -> Pat
lookupRecField oracle fields fn = match findRecField fn fields
  None => PWild
  Some None => PWild      -- field pun: binds, irrefutable → wildcard for coverage
  Some (Some p) => desugarPat oracle p

findRecField : String -> List RecPatField -> Option (Option Pat)
findRecField _ [] = None
findRecField fn ((RecPatField f mPat)::rest)
  | f == fn = Some mPat
  | otherwise = findRecField fn rest

-- ── matrix operations ─────────────────────────────────────────────────────
-- PERF: these three used to share one higher-order `filterMapRows f pmat`, with
-- `f` a partial application (`specConRow c arity`).  A call to an OPAQUE function
-- value goes through the runtime's generic apply path, which allocates per call —
-- and these are the innermost loop of the Maranget recursion, run once per matrix
-- ROW per signature CONSTRUCTOR.  On an N-constructor ADT matched by N arms that
-- is N² generic applies, and it was the single largest allocation source in
-- exhaustiveness checking (~108 MB at N=1000).  Open-coding each as a direct
-- recursion makes the inner call a statically-known one: same rows, same order,
-- no allocation per row visited.
specializeCon : String -> Int -> List (List Pat) -> List (List Pat)
specializeCon _ _ [] = []
specializeCon c arity (row::rest) = match specConRow c arity row
  Some r => r :: specializeCon c arity rest
  None => specializeCon c arity rest

specConRow : String -> Int -> List Pat -> Option (List Pat)
specConRow _ _ [] = None
specConRow c _ ((PCon c2 args)::rest)
  | c2 == c = Some (args ++ rest)
  | otherwise = None
specConRow _ arity (PWild::rest) = Some (replicate arity PWild ++ rest)
specConRow _ _ _ = None

specializeLit : Lit -> List (List Pat) -> List (List Pat)
specializeLit _ [] = []
specializeLit l (row::rest) = match specLitRow l row
  Some r => r :: specializeLit l rest
  None => specializeLit l rest

specLitRow : Lit -> List Pat -> Option (List Pat)
specLitRow _ [] = None
specLitRow l ((PLit l2)::rest) = if l2 == l then Some rest else None
specLitRow _ (PWild::rest) = Some rest
specLitRow _ _ = None

defaultMatrix : List (List Pat) -> List (List Pat)
defaultMatrix [] = []
defaultMatrix (row::rest) = match defRow row
  Some r => r :: defaultMatrix rest
  None => defaultMatrix rest

defRow : List Pat -> Option (List Pat)
defRow (PWild::rest) = Some rest
defRow _ = None

headCtors : List (List Pat) -> List String
headCtors [] = []
headCtors (((PCon c _)::_)::rest) = c :: headCtors rest
headCtors (_::rest) = headCtors rest

inferCol0Type : Oracle -> List (List Pat) -> Option String
inferCol0Type oracle pmat = tryEachType oracle (headCtors pmat)

tryEachType : Oracle -> List String -> Option String
tryEachType _ [] = None
tryEachType oracle (c::cs) = match oGetCtorType oracle c
  Some t => Some t
  None => tryEachType oracle cs

-- ── usefulness (the Maranget recursion) ───────────────────────────────────
export useful : Oracle -> Option String -> List (List Pat) -> List Pat -> Bool
useful _ _ [] _ = True
useful _ _ (_::_) [] = False
useful oracle col0 pmat (h::restQ) = usefulHead oracle col0 pmat h restQ

usefulHead : Oracle -> Option String -> List (List Pat) -> Pat -> List Pat -> Bool
usefulHead oracle _ pmat (PCon c args) restQ =
  useful oracle None (specializeCon c (listLen args) pmat) (args ++ restQ)
usefulHead oracle _ pmat (PLit l) restQ = useful oracle None (specializeLit l pmat) restQ
  || useful oracle None (defaultMatrix pmat) restQ
usefulHead oracle col0 pmat _ restQ = usefulWild oracle col0 pmat restQ

usefulWild : Oracle -> Option String -> List (List Pat) -> List Pat -> Bool
usefulWild oracle col0 pmat restQ =
  let col0t = orElseOpt col0 (inferCol0Type oracle pmat)
  usefulWildCtors oracle (bindCtors oracle col0t) pmat restQ

bindCtors : Oracle -> Option String -> Option (List String)
bindCtors _ None = None
bindCtors oracle (Some t) = oGetCtors oracle t

usefulWildCtors : Oracle -> Option (List String) -> List (List Pat) -> List Pat -> Bool
usefulWildCtors oracle None pmat restQ =
  useful oracle None (defaultMatrix pmat) restQ
usefulWildCtors oracle (Some ctors) pmat restQ =
  usefulCovered oracle ctors pmat restQ

-- PERF: this is the hot spot of the whole checker.  It used to
--   (a) decide coverage with `allCovered ctors (headCtors pmat)` — an O(#ctors ×
--       #rows) list-membership scan; and
--   (b) call `specializeCon` once per signature constructor, each call re-scanning
--       the ENTIRE matrix.
-- Both are O(N²) for an N-constructor `data` matched by N arms, and together they
-- were the dominant cost of exhaustiveness checking.
--
-- Instead, bucket the matrix's rows by head constructor in ONE pass.  The bucket
-- KEYS are exactly the head-constructor set, so coverage becomes an O(log N) lookup
-- per constructor; and each branch is handed its own rows rather than re-filtering
-- all of them.
--
-- One subtlety: a WILDCARD-headed row belongs to EVERY constructor's specialised
-- matrix, so buckets alone do not reproduce `specializeCon` when the matrix has
-- one.  Rather than splice wildcard rows back into each bucket (which would also
-- move them to the end, perturbing row order), we fall back to the original
-- per-constructor scan in that case.  It is rare and self-limiting: `allCovered`
-- holds with a wildcard row present only when the match already names every
-- constructor AND adds a redundant catch-all — which we warn about anyway.
usefulCovered : Oracle -> List String -> List (List Pat) -> List Pat -> Bool
usefulCovered oracle ctors pmat restQ =
  usefulBuckets oracle ctors pmat restQ (headBuckets pmat omEmpty)

usefulBuckets : Oracle -> List String -> List (List Pat) -> List Pat -> OrdMap (List (List Pat)) -> Bool
usefulBuckets oracle ctors pmat restQ buckets
  | not (allCovered ctors buckets) =
    useful oracle None (defaultMatrix pmat) restQ
  | anyWildHead pmat = anyList (usefulBranch oracle pmat restQ) ctors
  | otherwise = anyList (usefulBranchIn oracle buckets restQ) ctors

-- The matrix's rows grouped by head constructor, with that head STRIPPED
-- (`args ++ rest`) — i.e. exactly the rows `specializeCon c` keeps, for every `c`
-- at once, provided no row has a wildcard head (see `usefulCovered`).  Rows are
-- prepended, so a bucket comes out in reverse row order and is reversed on read.
headBuckets : List (List Pat) -> OrdMap (List (List Pat)) -> OrdMap (List (List Pat))
headBuckets [] acc = acc
headBuckets (row::rest) acc = headBuckets rest (headBucketRow row acc)

headBucketRow : List Pat -> OrdMap (List (List Pat)) -> OrdMap (List (List Pat))
headBucketRow ((PCon c args)::tl) acc =
  omInsert c (args ++ tl :: fromOption [] (omLookup c acc)) acc
headBucketRow _ acc = acc

anyWildHead : List (List Pat) -> Bool
anyWildHead [] = False
anyWildHead ((PWild::_)::_) = True
anyWildHead (_::rest) = anyWildHead rest

-- The signature is fully covered when every constructor heads at least one row —
-- i.e. has a bucket.  (Same predicate as the old `allCovered ctors (headCtors
-- pmat)`: `headCtors` collects exactly the `PCon` heads, which are exactly the
-- bucket keys.)
allCovered : List String -> OrdMap (List (List Pat)) -> Bool
allCovered ctors buckets = allList (c => omHasKey c buckets) ctors

usefulBranch : Oracle -> List (List Pat) -> List Pat -> String -> Bool
usefulBranch oracle pmat restQ c =
  let a = oGetArity oracle c
  useful oracle None (specializeCon c a pmat) (replicate a PWild ++ restQ)

-- `usefulBranch` with the constructor's rows taken from the prebuilt bucket instead
-- of re-scanning the matrix.  Only reached when the matrix has no wildcard-headed
-- row, where the bucket IS `specializeCon c a pmat` — same rows, same order.
usefulBranchIn : Oracle -> OrdMap (List (List Pat)) -> List Pat -> String -> Bool
usefulBranchIn oracle buckets restQ c =
  let a = oGetArity oracle c
  let rows = reverseL (fromOption [] (omLookup c buckets))
  useful oracle None rows (replicate a PWild ++ restQ)

-- ── redundant / unreachable-arm detection ─────────────────────────────────
-- The dual of exhaustiveness: an arm is UNREACHABLE when its pattern matches no
-- value the EARLIER arms don't already catch — i.e. its query pattern is not
-- `useful` against the matrix of the preceding arm patterns.  `checkMatchRedundant`
-- (typecheck) folds arms left-to-right and feeds only UNGUARDED predecessors into
-- `precMatrix` (a guarded arm may fail its guard at runtime, so it can't render a
-- later same-shape arm dead) — which is exactly what keeps this conservative: we
-- flag an arm only when it is provably dead via unconditional predecessors.
export patUnreachable : Oracle -> Option String -> List (List Pat) -> Pat -> Bool
patUnreachable oracle col0 precMatrix qpat =
  not (useful oracle col0 precMatrix [qpat])

-- Does the (RAW, pre-desugar) pattern contain a range anywhere?  `desugarPat`
-- collapses a `PRng` to `PWild` (the matrix machinery can't reason about the
-- values a range covers), which OVER-approximates its coverage.  That's harmless
-- for the exhaustiveness direction (it only ever makes the check miss a
-- non-exhaustive match — never a false warning), but for redundancy it would let
-- a preceding range arm masquerade as a catch-all and falsely flag every later
-- arm.  So `checkMatchRedundant` uses this to keep range-bearing arms OUT of the
-- accumulated covered-matrix: we never claim a range covers anything, staying
-- conservative (we may miss a genuinely-dead arm covered only by a range, but we
-- never flag a reachable one).
export patHasRange : Pat -> Bool
patHasRange (PRng _ _ _) = True
patHasRange (PCon _ args) = anyList patHasRange args
patHasRange (PCons h t) = patHasRange h || patHasRange t
patHasRange (PTuple ps) = anyList patHasRange ps
patHasRange (PList ps) = anyList patHasRange ps
patHasRange (PAs _ p) = patHasRange p
patHasRange (PRec _ fields _) = anyList recFieldHasRange fields
patHasRange _ = False

recFieldHasRange : RecPatField -> Bool
recFieldHasRange (RecPatField _ None) = False
recFieldHasRange (RecPatField _ (Some p)) = patHasRange p

-- ── witness extraction (the Maranget `I` algorithm) ───────────────────────
-- A witness-producing companion to `useful`: when the ALL-WILDCARD query of
-- `ncols` columns is useful against `pmat` (i.e. the match is non-exhaustive),
-- return a concrete uncovered pattern vector; `None` when the match is
-- exhaustive.  `checkMatchExhaustive` drives it with `ncols = 1` (a single
-- scrutinee column) and reads the head witness pattern for the diagnostic.
-- This mirrors `useful`'s wildcard-query path exactly — constructor-complete
-- columns recurse into each branch; an incomplete column NAMES a missing
-- constructor and recurses on the default matrix — so the two never disagree
-- on whether the warning fires.
export usefulWitness : Oracle -> Option String -> List (List Pat) -> Int -> Option (List Pat)
usefulWitness _ _ [] ncols = Some (replicate ncols PWild)
usefulWitness _ _ (_::_) 0 = None
usefulWitness oracle col0 pmat ncols =
  let col0t = orElseOpt col0 (inferCol0Type oracle pmat)
  witnessWild oracle (bindCtors oracle col0t) pmat ncols

-- An unknown/open column (no signature — e.g. an Int scrutinee matched by
-- literals): recurse on the default matrix and prepend a bare wildcard head.
witnessWild : Oracle -> Option (List String) -> List (List Pat) -> Int -> Option (List Pat)
witnessWild oracle None pmat ncols =
  witnessPrepend
    PWild
    (usefulWitness oracle None (defaultMatrix pmat) (ncols - 1))
witnessWild oracle (Some ctors) pmat ncols = witnessSig oracle ctors pmat ncols

witnessSig : Oracle -> List String -> List (List Pat) -> Int -> Option (List Pat)
witnessSig oracle ctors pmat ncols
  | allCovered ctors (headBuckets pmat omEmpty) =
    firstWitnessBranch oracle ctors pmat ncols
  | otherwise = map (missingCtorPat oracle ctors (headCtors pmat) :: _) (usefulWitness oracle None (defaultMatrix pmat) (ncols - 1))

-- Complete signature at this column: the first constructor branch that is still
-- useful yields the (possibly nested) witness.
firstWitnessBranch : Oracle -> List String -> List (List Pat) -> Int -> Option (List Pat)
firstWitnessBranch _ [] _ _ = None
firstWitnessBranch oracle (c::cs) pmat ncols = match witnessBranch oracle c pmat ncols
  Some w => Some w
  None => firstWitnessBranch oracle cs pmat ncols

witnessBranch : Oracle -> String -> List (List Pat) -> Int -> Option (List Pat)
witnessBranch oracle c pmat ncols =
  let a = oGetArity oracle c
  map
    (ws => PCon c (take a ws) :: drop a ws)
    (usefulWitness oracle None (specializeCon c a pmat) (a + ncols - 1))

witnessPrepend : Pat -> Option (List Pat) -> Option (List Pat)
witnessPrepend _ None = None
witnessPrepend p (Some ws) = Some (p::ws)

-- The first constructor of the signature not present at the column head, wrapped
-- with wildcard arguments (its arity).  Falls back to a bare wildcard if every
-- listed constructor is present (shouldn't happen on the incomplete branch).
missingCtorPat : Oracle -> List String -> List String -> Pat
missingCtorPat oracle ctors present = match firstMissing ctors present
  None => PWild
  Some c => PCon c (replicate (oGetArity oracle c) PWild)

firstMissing : List String -> List String -> Option String
firstMissing [] _ = None
firstMissing (c::cs) present =
  if contains c present then
    firstMissing cs present
  else
    Some c

-- ── witness → compact surface syntax ──────────────────────────────────────
-- Render a witness pattern for the diagnostic message.  Witnesses only ever
-- carry `PCon`/`PWild`, so the general pattern printer is overkill; this maps
-- the canonical matrix constructors back to their surface form (`[]`/`::`/
-- tuples/`()`) and names user constructors with wildcard arguments.
export renderWitness : Pat -> String
renderWitness p = renderWit False p

renderWit : Bool -> Pat -> String
renderWit paren (PCon c args) = renderConWit paren c args
renderWit _ _ = "_"

renderConWit : Bool -> String -> List Pat -> String
renderConWit paren c args
  | c == "Nil" = "[]"
  | c == "Cons" = renderCons paren args
  | c == "Unit" = "()"
  | (Some _) <- tupleArityOfName c =
    "(\{joinWith ", " (map (renderWit False) args)})"
  | isEmptyArgs args = c
  | otherwise =
    parenWrapWit paren "\{c} \{joinWith " " (map (renderWit True) args)}"

renderCons : Bool -> List Pat -> String
renderCons paren (h::t::_) =
  parenWrapWit paren "\{renderWit True h} :: \{renderWit False t}"
renderCons _ _ = "_ :: _"

isEmptyArgs : List Pat -> Bool
isEmptyArgs [] = True
isEmptyArgs (_::_) = False

parenWrapWit : Bool -> String -> String
parenWrapWit True s = "(\{s})"
parenWrapWit False s = s

-- ── guard totality ────────────────────────────────────────────────────────
isIrrefutablePat : Pat -> Bool
isIrrefutablePat (PVar _) = True
isIrrefutablePat PWild = True
isIrrefutablePat (PTuple ps) = allList isIrrefutablePat ps
isIrrefutablePat (PAs _ p) = isIrrefutablePat p
isIrrefutablePat (PRec _ fields _) = allList recFieldIrrefutable fields
isIrrefutablePat _ = False

recFieldIrrefutable : RecPatField -> Bool
recFieldIrrefutable (RecPatField _ None) = True
recFieldIrrefutable (RecPatField _ (Some p)) = isIrrefutablePat p

boolAlwaysTrue : Expr -> Bool
-- strip ELoc (mirror of lib/exhaust.ml's `strip_eloc`): guard conditions arrive
-- wrapped from the parser, so `otherwise`/`True` must be matched through it.
boolAlwaysTrue (ELoc _ e) = boolAlwaysTrue e
boolAlwaysTrue (EDoOrigin _ e) = boolAlwaysTrue e
boolAlwaysTrue (EVar "otherwise") = True
boolAlwaysTrue (EVar "True") = True
boolAlwaysTrue (ELit (LBool True)) = True
boolAlwaysTrue _ = False

guardAlwaysFires : Guard -> Bool
guardAlwaysFires (GBool e) = boolAlwaysTrue e
guardAlwaysFires (GBind p _) = isIrrefutablePat p

guardsDecidablyExhaustive : List Guard -> Bool
guardsDecidablyExhaustive gs = allList guardAlwaysFires gs

guardArmsTotal : List GuardArm -> Bool
guardArmsTotal arms = anyList guardArmTotal arms

guardArmTotal : GuardArm -> Bool
guardArmTotal (GuardArm gs _) = guardsDecidablyExhaustive gs

-- a clause is (params, body); decide guard totality / guarded-partiality
clauseGuardsTotal : (List Pat, Expr) -> Bool
clauseGuardsTotal (_, EGuards arms) = guardArmsTotal arms
clauseGuardsTotal _ = True

clauseIsGuardedPartial : (List Pat, Expr) -> Bool
clauseIsGuardedPartial (_, EGuards arms) = not (guardArmsTotal arms)
clauseIsGuardedPartial _ = False

clausePats : (List Pat, Expr) -> List Pat
clausePats (pats, _) = pats

-- ── check one same-name clause group ──────────────────────────────────────
guardWarning : String
guardWarning = "Warning: guards may not be exhaustive"

-- Each warning carries an optional per-group source location (recovered from the
-- first clause body's `ELoc` wrapper), so the CLI can render `file:L:C:` like the
-- `match`-path non-exhaustiveness warnings do.
checkGroup : Oracle -> String -> List (List Pat, Expr) -> List (String, Option Loc)
checkGroup oracle name clauses
  -- A group with a *guarded partial* clause → the guard may fall through; keep
  -- the flat "guards may not be exhaustive" wording (guard gaps aren't named by a
  -- constructor witness).
  | anyList clauseIsGuardedPartial clauses = checkGroupCovered oracle clauses
  -- Otherwise a plain constructor-matching group: warn when its patterns don't
  -- cover every constructor, naming the missing case like the `match` path.
  | otherwise = checkGroupClauses oracle name clauses

checkGroupCovered : Oracle -> List (List Pat, Expr) -> List (String, Option Loc)
checkGroupCovered oracle clauses =
  let arity = groupArity clauses
  let rows = totalClauseRows oracle clauses
  let query = [desugarPat oracle (PTuple (replicate arity PWild))]
  if useful oracle (Some (tupleCtorName arity)) rows query then
    [(guardWarning, groupLoc clauses)]
  else
    []

-- Constructor-coverage check for a non-guarded multi-clause group.  Builds the
-- all-wildcard query and, when it is still useful (some value escapes every
-- clause), names the missing case via `usefulWitness`/`renderWitness` — the same
-- witness machinery the `match` path uses (typecheck.mdk's `nonExhaustiveMsg`).
checkGroupClauses : Oracle -> String -> List (List Pat, Expr) -> List (String, Option Loc)
checkGroupClauses oracle name clauses =
  let arity = groupArity clauses
  let rows = totalClauseRows oracle clauses
  let query = [desugarPat oracle (PTuple (replicate arity PWild))]
  if useful oracle (Some (tupleCtorName arity)) rows query then
    [(nonExhaustiveClausesMsg oracle name arity rows, groupLoc clauses)]
  else
    []

-- Build the specialised message.  The clause params are packed into one tuple
-- column, so the witness is a single tuple pattern; for a one-param function we
-- unwrap it so the case reads `Blue`, not `(Blue)` (parity with `match`).  Falls
-- back to a generic wording when no witness is recoverable.
nonExhaustiveClausesMsg : Oracle -> String -> Int -> List (List Pat) -> String
nonExhaustiveClausesMsg oracle name arity rows = match usefulWitness oracle (Some (tupleCtorName arity)) rows 1
  Some (w::_) =>
    let witnessStr = renderClauseWitness arity w
    let hint = "add a '\{witnessStr}' clause, or a '_' catch-all clause."
    "Warning: non-exhaustive clauses of '\{name}'. Missing case: '\{witnessStr}'; \{hint}"
  _ => "Warning: non-exhaustive clauses of '\{name}'. Not all cases are covered"

-- Arity-1 witnesses are a 1-tuple wrapper around the single missing pattern;
-- unwrap so the rendered case is the bare pattern.  Higher arities render as the
-- tuple across all columns.
renderClauseWitness : Int -> Pat -> String
renderClauseWitness 1 (PCon _ (inner::_)) = renderWitness inner
renderClauseWitness _ w = renderWitness w

-- Per-group loc: the first clause body carries the parser's `ELoc` wrapper.
groupLoc : List (List Pat, Expr) -> Option Loc
groupLoc [] = None
groupLoc ((_, body)::_) = clauseBodyLoc body

clauseBodyLoc : Expr -> Option Loc
clauseBodyLoc (ELoc l _) = Some l
clauseBodyLoc (EDoOrigin l _) = Some l
clauseBodyLoc _ = None

groupArity : List (List Pat, Expr) -> Int
groupArity [] = 0
groupArity (c::_) = listLen (clausePats c)

-- one matrix row per non-falling-through clause (its params wrapped as a tuple)
totalClauseRows : Oracle -> List (List Pat, Expr) -> List (List Pat)
totalClauseRows _ [] = []
totalClauseRows oracle (c::rest)
  | clauseGuardsTotal c =
    [desugarPat oracle (PTuple (clausePats c))] :: totalClauseRows oracle rest
  | otherwise = totalClauseRows oracle rest

-- ── group same-name (name, clause) pairs, first-seen order ────────────────
-- Keeps the group NAME (the constructor-coverage message names the function),
-- and each group's clauses in source order.
--
-- PERF: O(n log n).  This used to be O(n²) TWICE over — `firstSeenNames` did a
-- linear `contains` against a growing seen-LIST per item, and then, for EVERY
-- distinct name, `clausesForName` rescanned the WHOLE `items` list.  `check`
-- runs this over every top-level DFunDef in the module (twice: once via
-- analyzeLocated, once via runCheck), so a 2k-function module cost ~4M full-list
-- walks — it was the dominant cost of `medaka check` on a large file.  Now one
-- pass buckets clauses by name in an OrdMap (each bucket accumulated front-first,
-- hence `reverseL` on read-back) and records first-seen names via O(log n)
-- membership; a second pass reads each name's bucket back out.
groupByName : List (String, (List Pat, Expr)) -> List (String, List (List Pat, Expr))
groupByName items =
  let buckets = bucketClauses items omEmpty
  map (n => (n, reverseL (bucketFor n buckets))) (firstSeenNames items omEmpty)

-- A clause group keyed by function name (the bucket map groupByName folds into).
type ClauseBuckets = OrdMap (List (List Pat, Expr))

-- Accumulate each clause under its name, newest-first (so one cons per item).
bucketClauses : List (String, (List Pat, Expr)) -> ClauseBuckets -> ClauseBuckets
bucketClauses [] acc = acc
bucketClauses ((n, c)::rest) acc =
  bucketClauses rest (omInsert n (c :: bucketFor n acc) acc)

bucketFor : String -> ClauseBuckets -> List (List Pat, Expr)
bucketFor n acc = match omLookup n acc
  Some cs => cs
  None => []

firstSeenNames : List (String, (List Pat, Expr)) -> OrdMap Unit -> List String
firstSeenNames [] _ = []
firstSeenNames ((n, _)::rest) seen
  | omHasKey n seen = firstSeenNames rest seen
  | otherwise = n :: firstSeenNames rest (omInsert n () seen)

-- ── collect where-group (ELetGroup) clause groups from an expr tree ────────
letGroupWarnings : Oracle -> Expr -> List (String, Option Loc)
letGroupWarnings oracle body =
  flatMap (checkLetBind oracle) (collectLetBinds body)

checkLetBind : Oracle -> LetBind -> List (String, Option Loc)
checkLetBind oracle (LetBind name funclauses) =
  checkGroup oracle name (map funClauseToClause funclauses)

funClauseToClause : FunClause -> (List Pat, Expr)
funClauseToClause (FunClause pats body) = (pats, body)

-- every LetBind from every ELetGroup anywhere in the tree (recurses into
-- clause bodies and the result expr)
collectLetBinds : Expr -> List LetBind
collectLetBinds (ELetGroup binds body) = binds
  ++ flatMap collectLetBindInner binds
  ++ collectLetBinds body
collectLetBinds (EApp a b) = collectLetBinds a ++ collectLetBinds b
collectLetBinds (ELam _ b) = collectLetBinds b
collectLetBinds (ELet _ _ _ e1 e2) = collectLetBinds e1 ++ collectLetBinds e2
collectLetBinds (EMatch e0 arms) = collectLetBinds e0
  ++ flatMap collectArmBinds arms
collectLetBinds (EIf c t el) = collectLetBinds c
  ++ collectLetBinds t
  ++ collectLetBinds el
collectLetBinds (EBinOp _ a b _) = collectLetBinds a ++ collectLetBinds b
collectLetBinds (EUnOp _ a _) = collectLetBinds a
collectLetBinds (EInfix _ a b) = collectLetBinds a ++ collectLetBinds b
collectLetBinds (EFieldAccess e0 _ _) = collectLetBinds e0
collectLetBinds (ERecordCreate _ fs) = flatMap fieldAssignBinds fs
collectLetBinds (ERecordUpdate e0 fs _) = collectLetBinds e0
  ++ flatMap fieldAssignBinds fs
collectLetBinds (EVariantUpdate _ e0 fs) = collectLetBinds e0
  ++ flatMap fieldAssignBinds fs
collectLetBinds (EArrayLit es) = flatMap collectLetBinds es
collectLetBinds (EListLit es) = flatMap collectLetBinds es
collectLetBinds (ETuple es) = flatMap collectLetBinds es
collectLetBinds (EIndex e0 i _) = collectLetBinds e0 ++ collectLetBinds i
collectLetBinds (ERangeList lo hi _) = collectLetBinds lo ++ collectLetBinds hi
collectLetBinds (ERangeArray lo hi _) = collectLetBinds lo ++ collectLetBinds hi
collectLetBinds (ESlice e0 lo hi _ _) = collectLetBinds e0
  ++ collectLetBinds lo
  ++ collectLetBinds hi
collectLetBinds (EBlock stmts) = flatMap doStmtBinds stmts
collectLetBinds (EDo stmts) = flatMap doStmtBinds stmts
collectLetBinds (EAnnot e0 _) = collectLetBinds e0
collectLetBinds (EStringInterp parts) = flatMap interpBinds parts
collectLetBinds (EGuards arms) = flatMap guardArmBinds arms
collectLetBinds (ESection (SecRight _ e0)) = collectLetBinds e0
collectLetBinds (ESection (SecLeft e0 _)) = collectLetBinds e0
collectLetBinds (ELoc _ e) = collectLetBinds e
collectLetBinds (EDoOrigin _ e) = collectLetBinds e
collectLetBinds _ = []

collectLetBindInner : LetBind -> List LetBind
collectLetBindInner (LetBind _ funclauses) = flatMap funClauseBinds funclauses

funClauseBinds : FunClause -> List LetBind
funClauseBinds (FunClause _ body) = collectLetBinds body

collectArmBinds : Arm -> List LetBind
collectArmBinds (Arm _ gs body) = flatMap guardBinds gs ++ collectLetBinds body

guardBinds : Guard -> List LetBind
guardBinds (GBool e) = collectLetBinds e
guardBinds (GBind _ e) = collectLetBinds e

guardArmBinds : GuardArm -> List LetBind
guardArmBinds (GuardArm gs body) = flatMap guardBinds gs ++ collectLetBinds body

fieldAssignBinds : FieldAssign -> List LetBind
fieldAssignBinds (FieldAssign _ e) = collectLetBinds e

doStmtBinds : DoStmt -> List LetBind
doStmtBinds (DoExpr e) = collectLetBinds e
doStmtBinds (DoBind _ e) = collectLetBinds e
doStmtBinds (DoLet _ _ _ e) = collectLetBinds e
doStmtBinds (DoAssign _ e) = collectLetBinds e
doStmtBinds (DoFieldAssign _ _ e) = collectLetBinds e

interpBinds : InterpPart -> List LetBind
interpBinds (InterpStr _) = []
interpBinds (InterpExpr e) = collectLetBinds e

-- ── top-level entry ───────────────────────────────────────────────────────
-- `checkGuardExhaustivenessWith oracleDecls checkDecls` builds the constructor
-- oracle from `oracleDecls` (a SUPERSET — runtime + core + every loaded module)
-- while only CHECKING the function groups in `checkDecls` (the target module).
-- The superset lets the multi-clause path see IMPORTED ADTs
-- (`Expr`/`Decl`/`Result`/…) and stop false-flagging exhaustive functions over
-- them.  Each warning carries an optional per-group loc.
--
-- P0-9: `checkDecls` (the target module's OWN decls) is prepended so its
-- constructors WIN the oracle's first-wins bare-name tables.  Two loaded modules
-- can define a same-named ctor at different arities (`map`'s arity-5 `Bin` vs
-- `set`'s arity-4 `Bin`); this pass runs pre-typecheck with no scrutinee type, so
-- it infers each column's type from the pattern's ctor name (`inferCol0Type` →
-- `oGetCtorType`) and reads its arity (`oGetArity`) — both first-wins.  Without
-- this ordering a superset would resolve the target module's own `Bin` to the
-- OTHER module's arity/type, producing a spurious W-NONEXHAUSTIVE-CLAUSES warning
-- against a genuinely exhaustive group.  (`buildOracle` is duplicate-tolerant, so
-- the checkDecls⊆oracleDecls overlap is harmless.)
export checkGuardExhaustivenessWith : List Decl -> List Decl -> List (String, Option Loc)
checkGuardExhaustivenessWith oracleDecls checkDecls =
  let oracle = buildOracle (checkDecls ++ oracleDecls)
  flatMap (checkNamedGroup oracle) (groupByName (topFunDefClauses checkDecls))
    ++ flatMap (declBodyWarnings oracle) checkDecls

checkNamedGroup : Oracle -> (String, List (List Pat, Expr)) -> List (String, Option Loc)
checkNamedGroup oracle (name, clauses) = checkGroup oracle name clauses

-- Back-compat: build the oracle from the checked decls only (the historical
-- entry-only oracle) and drop the loc channel to a plain message list.
export checkGuardExhaustiveness : List Decl -> List String
checkGuardExhaustiveness prog = map fst (checkGuardExhaustivenessWith prog prog)

topFunDefClauses : List Decl -> List (String, (List Pat, Expr))
topFunDefClauses [] = []
topFunDefClauses ((DFunDef _ n pats body)::rest) =
  (n, (pats, body)) :: topFunDefClauses rest
topFunDefClauses (_::rest) = topFunDefClauses rest

declBodyWarnings : Oracle -> Decl -> List (String, Option Loc)
declBodyWarnings oracle (DFunDef _ _ _ body) = letGroupWarnings oracle body
declBodyWarnings oracle (DImpl { methods, ... }) = flatMap (checkNamedGroup oracle) (groupByName (implClauses methods))
  ++ flatMap (implMethodBodyWarnings oracle) methods
declBodyWarnings oracle (DInterface { methods, ... }) =
  flatMap (ifaceMethodWarnings oracle) methods
declBodyWarnings oracle (DProp _ _ _ body) = letGroupWarnings oracle body
declBodyWarnings oracle (DTest _ _ body) = letGroupWarnings oracle body
declBodyWarnings oracle (DBench _ _ body) = letGroupWarnings oracle body
declBodyWarnings _ _ = []

implClauses : List ImplMethod -> List (String, (List Pat, Expr))
implClauses [] = []
implClauses ((ImplMethod n pats body)::rest) =
  (n, (pats, body)) :: implClauses rest

implMethodBodyWarnings : Oracle -> ImplMethod -> List (String, Option Loc)
implMethodBodyWarnings oracle (ImplMethod _ _ body) =
  letGroupWarnings oracle body

ifaceMethodWarnings : Oracle -> IfaceMethod -> List (String, Option Loc)
ifaceMethodWarnings _ (IfaceMethod _ _ None) = []
ifaceMethodWarnings oracle (IfaceMethod _ _ (Some (MethodDefault _ body))) =
  letGroupWarnings oracle body

-- one warning per line (the harness sorts); oracle built from a superset of decls
export exhaustToLinesWith : List Decl -> List Decl -> String
exhaustToLinesWith oracleDecls checkDecls =
  joinNl (map fst (checkGuardExhaustivenessWith oracleDecls checkDecls))

-- entry-only oracle (self-contained single file: no imports available)
export exhaustToLines : List Decl -> String
exhaustToLines prog = exhaustToLinesWith prog prog
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Loc" false) (mem "Ty" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true))))
(DUse false (UseGroup ("list") ((mem "replicate" false) (mem "take" false) (mem "drop" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "allList" false) (mem "anyList" false) (mem "listLen" false) (mem "reverseL" false) (mem "joinNl" false) (mem "joinWith" false) (mem "orElseOpt" false) (mem "reverseL" false))))
(DTypeSig true "tupleCtorName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "tupleCtorName" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "__tuple")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "__"))))
(DTypeSig false "tupleArityOfName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "tupleArityOfName" ((PVar "c")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "c"))) (DoExpr (EApp (EApp (EVar "tupleArityCheck") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))))))
(DTypeSig false "tupleArityCheck" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "tupleArityCheck" ((PVar "cs") (PVar "n")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 9))) (EApp (EVar "charsPrefixTuple") (EVar "cs"))) (EApp (EApp (EVar "charsSuffixUnder") (EVar "cs")) (EVar "n"))) (EApp (EApp (EApp (EVar "parseDigits") (EVar "cs")) (ELit (LInt 7))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "charsPrefixTuple" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Bool")))
(DFunDef false "charsPrefixTuple" ((PVar "cs")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")) (ELit (LChar "_"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 1))) (EVar "cs")) (ELit (LChar "_")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 2))) (EVar "cs")) (ELit (LChar "t")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 3))) (EVar "cs")) (ELit (LChar "u")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 4))) (EVar "cs")) (ELit (LChar "p")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 5))) (EVar "cs")) (ELit (LChar "l")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 6))) (EVar "cs")) (ELit (LChar "e")))))
(DTypeSig false "charsSuffixUnder" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "charsSuffixUnder" ((PVar "cs") (PVar "n")) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "cs")) (ELit (LChar "_"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "_")))))
(DTypeSig false "parseDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "parseDigits" ((PVar "cs") (PVar "start") (PVar "end")) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigitsGo") (EVar "cs")) (EVar "start")) (EVar "end")) (ELit (LInt 0))) (EVar "False")))
(DTypeSig false "parseDigitsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "parseDigitsGo" ((PVar "cs") (PVar "i") (PVar "end") (PVar "acc") (PVar "seen")) (EIf (EBinOp ">=" (EVar "i") (EVar "end")) (EIf (EVar "seen") (EApp (EVar "Some") (EVar "acc")) (EVar "None")) (EIf (EApp (EVar "isDigitC") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigitsGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "end")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EApp (EVar "digitVal") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))) (EVar "True")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isDigitC" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isDigitC" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9")))))
(DTypeSig false "digitVal" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "digitVal" ((PVar "c")) (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (EApp (EVar "charCode") (ELit (LChar "0")))))
(DData Public "Oracle" () ((variant "Oracle" (ConNamed (field "typeCtors" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "ctorArity" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "ctorType" (TyApp (TyCon "OrdMap") (TyCon "String"))) (field "ctorFields" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))) ())
(DTypeSig true "buildOracle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Oracle")))
(DFunDef false "buildOracle" ((PVar "prog")) (ERecordCreate "Oracle" ((fa "typeCtors" (EApp (EVar "oracleMap") (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "dataTypeCtors")) (EVar "prog")) (EVar "builtinTypeCtors")))) (fa "ctorArity" (EApp (EVar "oracleMap") (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "dataArity")) (EVar "prog")) (EVar "builtinArity")))) (fa "ctorType" (EApp (EVar "oracleMap") (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "dataCtorType")) (EVar "prog")) (EVar "builtinCtorType")))) (fa "ctorFields" (EApp (EVar "oracleMap") (EApp (EApp (EVar "flatMap") (EVar "dataCtorFields")) (EVar "prog")))))))
(DTypeSig false "oracleMap" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "OrdMap") (TyVar "a"))))
(DFunDef false "oracleMap" ((PVar "pairs")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "pairs"))) (EVar "omEmpty")))
(DTypeSig false "builtinTypeCtors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "builtinTypeCtors" () (EListLit (ETuple (ELit (LString "Bool")) (EListLit (ELit (LString "True")) (ELit (LString "False")))) (ETuple (ELit (LString "List")) (EListLit (ELit (LString "Cons")) (ELit (LString "Nil")))) (ETuple (ELit (LString "Unit")) (EListLit (ELit (LString "Unit"))))))
(DTypeSig false "builtinArity" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "builtinArity" () (EListLit (ETuple (ELit (LString "True")) (ELit (LInt 0))) (ETuple (ELit (LString "False")) (ELit (LInt 0))) (ETuple (ELit (LString "Cons")) (ELit (LInt 2))) (ETuple (ELit (LString "Nil")) (ELit (LInt 0))) (ETuple (ELit (LString "Unit")) (ELit (LInt 0)))))
(DTypeSig false "builtinCtorType" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "builtinCtorType" () (EListLit (ETuple (ELit (LString "True")) (ELit (LString "Bool"))) (ETuple (ELit (LString "False")) (ELit (LString "Bool"))) (ETuple (ELit (LString "Cons")) (ELit (LString "List"))) (ETuple (ELit (LString "Nil")) (ELit (LString "List"))) (ETuple (ELit (LString "Unit")) (ELit (LString "Unit")))))
(DTypeSig false "dataTypeCtors" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dataTypeCtors" ((PCon "DData" PWild (PVar "tyname") PWild (PVar "variants") PWild)) (EListLit (ETuple (EVar "tyname") (EApp (EApp (EVar "map") (EVar "variantName")) (EVar "variants")))))
(DFunDef false "dataTypeCtors" (PWild) (EListLit))
(DTypeSig false "dataArity" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "dataArity" ((PCon "DData" PWild PWild PWild (PVar "variants") PWild)) (EApp (EApp (EVar "map") (EVar "variantArity")) (EVar "variants")))
(DFunDef false "dataArity" (PWild) (EListLit))
(DTypeSig false "dataCtorType" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "dataCtorType" ((PCon "DData" PWild (PVar "tyname") PWild (PVar "variants") PWild)) (EApp (EApp (EVar "map") (EApp (EVar "variantCtorType") (EVar "tyname"))) (EVar "variants")))
(DFunDef false "dataCtorType" (PWild) (EListLit))
(DTypeSig false "variantName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "variantArity" (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "variantArity" ((PCon "Variant" (PVar "n") (PCon "ConPos" (PVar "tys")))) (ETuple (EVar "n") (EApp (EVar "listLen") (EVar "tys"))))
(DFunDef false "variantArity" ((PCon "Variant" (PVar "n") (PCon "ConNamed" (PVar "fs") PWild))) (ETuple (EVar "n") (EApp (EVar "listLen") (EVar "fs"))))
(DTypeSig false "variantCtorType" (TyFun (TyCon "String") (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "variantCtorType" ((PVar "tyname") (PCon "Variant" (PVar "n") PWild)) (ETuple (EVar "n") (EVar "tyname")))
(DTypeSig false "dataCtorFields" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dataCtorFields" ((PCon "DData" PWild PWild PWild (PVar "variants") PWild)) (EApp (EApp (EVar "flatMap") (EVar "variantCtorFields")) (EVar "variants")))
(DFunDef false "dataCtorFields" (PWild) (EListLit))
(DTypeSig false "variantCtorFields" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "variantCtorFields" ((PCon "Variant" (PVar "n") (PCon "ConNamed" (PVar "fs") PWild))) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "fieldName")) (EVar "fs")))))
(DFunDef false "variantCtorFields" (PWild) (EListLit))
(DTypeSig false "fieldName" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldName" ((PCon "Field" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "oGetCtorFields" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "oGetCtorFields" ((PVar "oracle") (PVar "c")) (EApp (EApp (EVar "omLookup") (EVar "c")) (EFieldAccess (EVar "oracle") "ctorFields")))
(DTypeSig true "oGetCtors" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "oGetCtors" ((PVar "oracle") (PVar "t")) (EMatch (EApp (EVar "tupleArityOfName") (EVar "t")) (arm (PCon "Some" PWild) () (EApp (EVar "Some") (EListLit (EVar "t")))) (arm PWild () (EIf (EVar "otherwise") (EApp (EApp (EVar "omLookup") (EVar "t")) (EFieldAccess (EVar "oracle") "typeCtors")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "oGetCtorType" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "oGetCtorType" ((PVar "oracle") (PVar "c")) (EMatch (EApp (EVar "tupleArityOfName") (EVar "c")) (arm (PCon "Some" PWild) () (EApp (EVar "Some") (EVar "c"))) (arm PWild () (EIf (EVar "otherwise") (EApp (EApp (EVar "omLookup") (EVar "c")) (EFieldAccess (EVar "oracle") "ctorType")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "oGetArity" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "oGetArity" ((PVar "oracle") (PVar "c")) (EMatch (EApp (EVar "tupleArityOfName") (EVar "c")) (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm PWild () (EIf (EVar "otherwise") (EApp (EApp (EVar "fromOption") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "c")) (EFieldAccess (EVar "oracle") "ctorArity"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "desugarPat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "desugarPat" (PWild (PCon "PWild")) (EVar "PWild"))
(DFunDef false "desugarPat" (PWild (PCon "PVar" PWild)) (EVar "PWild"))
(DFunDef false "desugarPat" (PWild (PCon "PLit" (PCon "LBool" (PCon "True")))) (EApp (EApp (EVar "PCon") (ELit (LString "True"))) (EListLit)))
(DFunDef false "desugarPat" (PWild (PCon "PLit" (PCon "LBool" (PCon "False")))) (EApp (EApp (EVar "PCon") (ELit (LString "False"))) (EListLit)))
(DFunDef false "desugarPat" (PWild (PCon "PLit" (PCon "LUnit"))) (EApp (EApp (EVar "PCon") (ELit (LString "Unit"))) (EListLit)))
(DFunDef false "desugarPat" (PWild (PCon "PLit" (PVar "l"))) (EApp (EVar "PLit") (EVar "l")))
(DFunDef false "desugarPat" ((PVar "oracle") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "PCon") (EApp (EVar "tupleCtorName") (EApp (EVar "listLen") (EVar "ps")))) (EApp (EApp (EVar "map") (EApp (EVar "desugarPat") (EVar "oracle"))) (EVar "ps"))))
(DFunDef false "desugarPat" ((PVar "oracle") (PCon "PCon" (PVar "c") (PVar "args"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EVar "map") (EApp (EVar "desugarPat") (EVar "oracle"))) (EVar "args"))))
(DFunDef false "desugarPat" ((PVar "oracle") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCon") (ELit (LString "Cons"))) (EListLit (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EVar "h")) (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EVar "t")))))
(DFunDef false "desugarPat" (PWild (PCon "PList" (PList))) (EApp (EApp (EVar "PCon") (ELit (LString "Nil"))) (EListLit)))
(DFunDef false "desugarPat" ((PVar "oracle") (PCon "PList" (PCons (PVar "h") (PVar "rest")))) (EApp (EApp (EVar "PCon") (ELit (LString "Cons"))) (EListLit (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EVar "h")) (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EApp (EVar "PList") (EVar "rest"))))))
(DFunDef false "desugarPat" ((PVar "oracle") (PCon "PAs" PWild (PVar "p"))) (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EVar "p")))
(DFunDef false "desugarPat" (PWild (PCon "PRec" PWild PWild (PCon "True"))) (EVar "PWild"))
(DFunDef false "desugarPat" ((PVar "oracle") (PCon "PRec" (PVar "name") (PVar "fields") PWild)) (EMatch (EApp (EApp (EVar "oGetCtorFields") (EVar "oracle")) (EVar "name")) (arm (PCon "None") () (EVar "PWild")) (arm (PCon "Some" (PVar "fieldOrder")) () (EApp (EApp (EVar "PCon") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "lookupRecField") (EVar "oracle")) (EVar "fields"))) (EVar "fieldOrder"))))))
(DFunDef false "desugarPat" (PWild (PCon "PRng" PWild PWild PWild)) (EVar "PWild"))
(DTypeSig false "lookupRecField" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyFun (TyCon "String") (TyCon "Pat")))))
(DFunDef false "lookupRecField" ((PVar "oracle") (PVar "fields") (PVar "fn")) (EMatch (EApp (EApp (EVar "findRecField") (EVar "fn")) (EVar "fields")) (arm (PCon "None") () (EVar "PWild")) (arm (PCon "Some" (PCon "None")) () (EVar "PWild")) (arm (PCon "Some" (PCon "Some" (PVar "p"))) () (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EVar "p")))))
(DTypeSig false "findRecField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyApp (TyCon "Option") (TyApp (TyCon "Option") (TyCon "Pat"))))))
(DFunDef false "findRecField" (PWild (PList)) (EVar "None"))
(DFunDef false "findRecField" ((PVar "fn") (PCons (PCon "RecPatField" (PVar "f") (PVar "mPat")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "f") (EVar "fn")) (EApp (EVar "Some") (EVar "mPat")) (EIf (EVar "otherwise") (EApp (EApp (EVar "findRecField") (EVar "fn")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "specializeCon" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))))))
(DFunDef false "specializeCon" (PWild PWild (PList)) (EListLit))
(DFunDef false "specializeCon" ((PVar "c") (PVar "arity") (PCons (PVar "row") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "specConRow") (EVar "c")) (EVar "arity")) (EVar "row")) (arm (PCon "Some" (PVar "r")) () (EBinOp "::" (EVar "r") (EApp (EApp (EApp (EVar "specializeCon") (EVar "c")) (EVar "arity")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "specializeCon") (EVar "c")) (EVar "arity")) (EVar "rest")))))
(DTypeSig false "specConRow" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat")))))))
(DFunDef false "specConRow" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "specConRow" ((PVar "c") PWild (PCons (PCon "PCon" (PVar "c2") (PVar "args")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "c2") (EVar "c")) (EApp (EVar "Some") (EBinOp "++" (EVar "args") (EVar "rest"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "specConRow" (PWild (PVar "arity") (PCons (PCon "PWild") (PVar "rest"))) (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EVar "replicate") (EVar "arity")) (EVar "PWild")) (EVar "rest"))))
(DFunDef false "specConRow" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "specializeLit" (TyFun (TyCon "Lit") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))))))
(DFunDef false "specializeLit" (PWild (PList)) (EListLit))
(DFunDef false "specializeLit" ((PVar "l") (PCons (PVar "row") (PVar "rest"))) (EMatch (EApp (EApp (EVar "specLitRow") (EVar "l")) (EVar "row")) (arm (PCon "Some" (PVar "r")) () (EBinOp "::" (EVar "r") (EApp (EApp (EVar "specializeLit") (EVar "l")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "specializeLit") (EVar "l")) (EVar "rest")))))
(DTypeSig false "specLitRow" (TyFun (TyCon "Lit") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))))))
(DFunDef false "specLitRow" (PWild (PList)) (EVar "None"))
(DFunDef false "specLitRow" ((PVar "l") (PCons (PCon "PLit" (PVar "l2")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "l2") (EVar "l")) (EApp (EVar "Some") (EVar "rest")) (EVar "None")))
(DFunDef false "specLitRow" (PWild (PCons (PCon "PWild") (PVar "rest"))) (EApp (EVar "Some") (EVar "rest")))
(DFunDef false "specLitRow" (PWild PWild) (EVar "None"))
(DTypeSig false "defaultMatrix" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "defaultMatrix" ((PList)) (EListLit))
(DFunDef false "defaultMatrix" ((PCons (PVar "row") (PVar "rest"))) (EMatch (EApp (EVar "defRow") (EVar "row")) (arm (PCon "Some" (PVar "r")) () (EBinOp "::" (EVar "r") (EApp (EVar "defaultMatrix") (EVar "rest")))) (arm (PCon "None") () (EApp (EVar "defaultMatrix") (EVar "rest")))))
(DTypeSig false "defRow" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "defRow" ((PCons (PCon "PWild") (PVar "rest"))) (EApp (EVar "Some") (EVar "rest")))
(DFunDef false "defRow" (PWild) (EVar "None"))
(DTypeSig false "headCtors" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "headCtors" ((PList)) (EListLit))
(DFunDef false "headCtors" ((PCons (PCons (PCon "PCon" (PVar "c") PWild) PWild) (PVar "rest"))) (EBinOp "::" (EVar "c") (EApp (EVar "headCtors") (EVar "rest"))))
(DFunDef false "headCtors" ((PCons PWild (PVar "rest"))) (EApp (EVar "headCtors") (EVar "rest")))
(DTypeSig false "inferCol0Type" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "inferCol0Type" ((PVar "oracle") (PVar "pmat")) (EApp (EApp (EVar "tryEachType") (EVar "oracle")) (EApp (EVar "headCtors") (EVar "pmat"))))
(DTypeSig false "tryEachType" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "tryEachType" (PWild (PList)) (EVar "None"))
(DFunDef false "tryEachType" ((PVar "oracle") (PCons (PVar "c") (PVar "cs"))) (EMatch (EApp (EApp (EVar "oGetCtorType") (EVar "oracle")) (EVar "c")) (arm (PCon "Some" (PVar "t")) () (EApp (EVar "Some") (EVar "t"))) (arm (PCon "None") () (EApp (EApp (EVar "tryEachType") (EVar "oracle")) (EVar "cs")))))
(DTypeSig true "useful" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool"))))))
(DFunDef false "useful" (PWild PWild (PList) PWild) (EVar "True"))
(DFunDef false "useful" (PWild PWild (PCons PWild PWild) (PList)) (EVar "False"))
(DFunDef false "useful" ((PVar "oracle") (PVar "col0") (PVar "pmat") (PCons (PVar "h") (PVar "restQ"))) (EApp (EApp (EApp (EApp (EApp (EVar "usefulHead") (EVar "oracle")) (EVar "col0")) (EVar "pmat")) (EVar "h")) (EVar "restQ")))
(DTypeSig false "usefulHead" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool")))))))
(DFunDef false "usefulHead" ((PVar "oracle") PWild (PVar "pmat") (PCon "PCon" (PVar "c") (PVar "args")) (PVar "restQ")) (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "None")) (EApp (EApp (EApp (EVar "specializeCon") (EVar "c")) (EApp (EVar "listLen") (EVar "args"))) (EVar "pmat"))) (EBinOp "++" (EVar "args") (EVar "restQ"))))
(DFunDef false "usefulHead" ((PVar "oracle") PWild (PVar "pmat") (PCon "PLit" (PVar "l")) (PVar "restQ")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "None")) (EApp (EApp (EVar "specializeLit") (EVar "l")) (EVar "pmat"))) (EVar "restQ")) (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "None")) (EApp (EVar "defaultMatrix") (EVar "pmat"))) (EVar "restQ"))))
(DFunDef false "usefulHead" ((PVar "oracle") (PVar "col0") (PVar "pmat") PWild (PVar "restQ")) (EApp (EApp (EApp (EApp (EVar "usefulWild") (EVar "oracle")) (EVar "col0")) (EVar "pmat")) (EVar "restQ")))
(DTypeSig false "usefulWild" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool"))))))
(DFunDef false "usefulWild" ((PVar "oracle") (PVar "col0") (PVar "pmat") (PVar "restQ")) (EBlock (DoLet false false (PVar "col0t") (EApp (EApp (EVar "orElseOpt") (EVar "col0")) (EApp (EApp (EVar "inferCol0Type") (EVar "oracle")) (EVar "pmat")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "usefulWildCtors") (EVar "oracle")) (EApp (EApp (EVar "bindCtors") (EVar "oracle")) (EVar "col0t"))) (EVar "pmat")) (EVar "restQ")))))
(DTypeSig false "bindCtors" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "bindCtors" (PWild (PCon "None")) (EVar "None"))
(DFunDef false "bindCtors" ((PVar "oracle") (PCon "Some" (PVar "t"))) (EApp (EApp (EVar "oGetCtors") (EVar "oracle")) (EVar "t")))
(DTypeSig false "usefulWildCtors" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool"))))))
(DFunDef false "usefulWildCtors" ((PVar "oracle") (PCon "None") (PVar "pmat") (PVar "restQ")) (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "None")) (EApp (EVar "defaultMatrix") (EVar "pmat"))) (EVar "restQ")))
(DFunDef false "usefulWildCtors" ((PVar "oracle") (PCon "Some" (PVar "ctors")) (PVar "pmat") (PVar "restQ")) (EApp (EApp (EApp (EApp (EVar "usefulCovered") (EVar "oracle")) (EVar "ctors")) (EVar "pmat")) (EVar "restQ")))
(DTypeSig false "usefulCovered" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool"))))))
(DFunDef false "usefulCovered" ((PVar "oracle") (PVar "ctors") (PVar "pmat") (PVar "restQ")) (EApp (EApp (EApp (EApp (EApp (EVar "usefulBuckets") (EVar "oracle")) (EVar "ctors")) (EVar "pmat")) (EVar "restQ")) (EApp (EApp (EVar "headBuckets") (EVar "pmat")) (EVar "omEmpty"))))
(DTypeSig false "usefulBuckets" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))) (TyCon "Bool")))))))
(DFunDef false "usefulBuckets" ((PVar "oracle") (PVar "ctors") (PVar "pmat") (PVar "restQ") (PVar "buckets")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "allCovered") (EVar "ctors")) (EVar "buckets"))) (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "None")) (EApp (EVar "defaultMatrix") (EVar "pmat"))) (EVar "restQ")) (EIf (EApp (EVar "anyWildHead") (EVar "pmat")) (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "usefulBranch") (EVar "oracle")) (EVar "pmat")) (EVar "restQ"))) (EVar "ctors")) (EIf (EVar "otherwise") (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "usefulBranchIn") (EVar "oracle")) (EVar "buckets")) (EVar "restQ"))) (EVar "ctors")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "headBuckets" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))))))
(DFunDef false "headBuckets" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "headBuckets" ((PCons (PVar "row") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "headBuckets") (EVar "rest")) (EApp (EApp (EVar "headBucketRow") (EVar "row")) (EVar "acc"))))
(DTypeSig false "headBucketRow" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))))))
(DFunDef false "headBucketRow" ((PCons (PCon "PCon" (PVar "c") (PVar "args")) (PVar "tl")) (PVar "acc")) (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (EBinOp "::" (EBinOp "++" (EVar "args") (EVar "tl")) (EApp (EApp (EVar "fromOption") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "acc"))))) (EVar "acc")))
(DFunDef false "headBucketRow" (PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "anyWildHead" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyCon "Bool")))
(DFunDef false "anyWildHead" ((PList)) (EVar "False"))
(DFunDef false "anyWildHead" ((PCons (PCons (PCon "PWild") PWild) PWild)) (EVar "True"))
(DFunDef false "anyWildHead" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyWildHead") (EVar "rest")))
(DTypeSig false "allCovered" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))) (TyCon "Bool"))))
(DFunDef false "allCovered" ((PVar "ctors") (PVar "buckets")) (EApp (EApp (EVar "allList") (ELam ((PVar "c")) (EApp (EApp (EVar "omHasKey") (EVar "c")) (EVar "buckets")))) (EVar "ctors")))
(DTypeSig false "usefulBranch" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "usefulBranch" ((PVar "oracle") (PVar "pmat") (PVar "restQ") (PVar "c")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "oGetArity") (EVar "oracle")) (EVar "c"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "None")) (EApp (EApp (EApp (EVar "specializeCon") (EVar "c")) (EVar "a")) (EVar "pmat"))) (EBinOp "++" (EApp (EApp (EVar "replicate") (EVar "a")) (EVar "PWild")) (EVar "restQ"))))))
(DTypeSig false "usefulBranchIn" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "usefulBranchIn" ((PVar "oracle") (PVar "buckets") (PVar "restQ") (PVar "c")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "oGetArity") (EVar "oracle")) (EVar "c"))) (DoLet false false (PVar "rows") (EApp (EVar "reverseL") (EApp (EApp (EVar "fromOption") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "buckets"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "None")) (EVar "rows")) (EBinOp "++" (EApp (EApp (EVar "replicate") (EVar "a")) (EVar "PWild")) (EVar "restQ"))))))
(DTypeSig true "patUnreachable" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Pat") (TyCon "Bool"))))))
(DFunDef false "patUnreachable" ((PVar "oracle") (PVar "col0") (PVar "precMatrix") (PVar "qpat")) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "col0")) (EVar "precMatrix")) (EListLit (EVar "qpat")))))
(DTypeSig true "patHasRange" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patHasRange" ((PCon "PRng" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patHasRange" ((PCon "PCon" PWild (PVar "args"))) (EApp (EApp (EVar "anyList") (EVar "patHasRange")) (EVar "args")))
(DFunDef false "patHasRange" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "||" (EApp (EVar "patHasRange") (EVar "h")) (EApp (EVar "patHasRange") (EVar "t"))))
(DFunDef false "patHasRange" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EVar "patHasRange")) (EVar "ps")))
(DFunDef false "patHasRange" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EVar "patHasRange")) (EVar "ps")))
(DFunDef false "patHasRange" ((PCon "PAs" PWild (PVar "p"))) (EApp (EVar "patHasRange") (EVar "p")))
(DFunDef false "patHasRange" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "anyList") (EVar "recFieldHasRange")) (EVar "fields")))
(DFunDef false "patHasRange" (PWild) (EVar "False"))
(DTypeSig false "recFieldHasRange" (TyFun (TyCon "RecPatField") (TyCon "Bool")))
(DFunDef false "recFieldHasRange" ((PCon "RecPatField" PWild (PCon "None"))) (EVar "False"))
(DFunDef false "recFieldHasRange" ((PCon "RecPatField" PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patHasRange") (EVar "p")))
(DTypeSig true "usefulWitness" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))))))))
(DFunDef false "usefulWitness" (PWild PWild (PList) (PVar "ncols")) (EApp (EVar "Some") (EApp (EApp (EVar "replicate") (EVar "ncols")) (EVar "PWild"))))
(DFunDef false "usefulWitness" (PWild PWild (PCons PWild PWild) (PLit (LInt 0))) (EVar "None"))
(DFunDef false "usefulWitness" ((PVar "oracle") (PVar "col0") (PVar "pmat") (PVar "ncols")) (EBlock (DoLet false false (PVar "col0t") (EApp (EApp (EVar "orElseOpt") (EVar "col0")) (EApp (EApp (EVar "inferCol0Type") (EVar "oracle")) (EVar "pmat")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "witnessWild") (EVar "oracle")) (EApp (EApp (EVar "bindCtors") (EVar "oracle")) (EVar "col0t"))) (EVar "pmat")) (EVar "ncols")))))
(DTypeSig false "witnessWild" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))))))))
(DFunDef false "witnessWild" ((PVar "oracle") (PCon "None") (PVar "pmat") (PVar "ncols")) (EApp (EApp (EVar "witnessPrepend") (EVar "PWild")) (EApp (EApp (EApp (EApp (EVar "usefulWitness") (EVar "oracle")) (EVar "None")) (EApp (EVar "defaultMatrix") (EVar "pmat"))) (EBinOp "-" (EVar "ncols") (ELit (LInt 1))))))
(DFunDef false "witnessWild" ((PVar "oracle") (PCon "Some" (PVar "ctors")) (PVar "pmat") (PVar "ncols")) (EApp (EApp (EApp (EApp (EVar "witnessSig") (EVar "oracle")) (EVar "ctors")) (EVar "pmat")) (EVar "ncols")))
(DTypeSig false "witnessSig" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))))))))
(DFunDef false "witnessSig" ((PVar "oracle") (PVar "ctors") (PVar "pmat") (PVar "ncols")) (EIf (EApp (EApp (EVar "allCovered") (EVar "ctors")) (EApp (EApp (EVar "headBuckets") (EVar "pmat")) (EVar "omEmpty"))) (EApp (EApp (EApp (EApp (EVar "firstWitnessBranch") (EVar "oracle")) (EVar "ctors")) (EVar "pmat")) (EVar "ncols")) (EIf (EVar "otherwise") (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EApp (EApp (EApp (EVar "missingCtorPat") (EVar "oracle")) (EVar "ctors")) (EApp (EVar "headCtors") (EVar "pmat"))) (EVar "_s")))) (EApp (EApp (EApp (EApp (EVar "usefulWitness") (EVar "oracle")) (EVar "None")) (EApp (EVar "defaultMatrix") (EVar "pmat"))) (EBinOp "-" (EVar "ncols") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "firstWitnessBranch" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))))))))
(DFunDef false "firstWitnessBranch" (PWild (PList) PWild PWild) (EVar "None"))
(DFunDef false "firstWitnessBranch" ((PVar "oracle") (PCons (PVar "c") (PVar "cs")) (PVar "pmat") (PVar "ncols")) (EMatch (EApp (EApp (EApp (EApp (EVar "witnessBranch") (EVar "oracle")) (EVar "c")) (EVar "pmat")) (EVar "ncols")) (arm (PCon "Some" (PVar "w")) () (EApp (EVar "Some") (EVar "w"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "firstWitnessBranch") (EVar "oracle")) (EVar "cs")) (EVar "pmat")) (EVar "ncols")))))
(DTypeSig false "witnessBranch" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))))))))
(DFunDef false "witnessBranch" ((PVar "oracle") (PVar "c") (PVar "pmat") (PVar "ncols")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "oGetArity") (EVar "oracle")) (EVar "c"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "ws")) (EBinOp "::" (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EVar "take") (EVar "a")) (EVar "ws"))) (EApp (EApp (EVar "drop") (EVar "a")) (EVar "ws"))))) (EApp (EApp (EApp (EApp (EVar "usefulWitness") (EVar "oracle")) (EVar "None")) (EApp (EApp (EApp (EVar "specializeCon") (EVar "c")) (EVar "a")) (EVar "pmat"))) (EBinOp "-" (EBinOp "+" (EVar "a") (EVar "ncols")) (ELit (LInt 1))))))))
(DTypeSig false "witnessPrepend" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))))))
(DFunDef false "witnessPrepend" (PWild (PCon "None")) (EVar "None"))
(DFunDef false "witnessPrepend" ((PVar "p") (PCon "Some" (PVar "ws"))) (EApp (EVar "Some") (EBinOp "::" (EVar "p") (EVar "ws"))))
(DTypeSig false "missingCtorPat" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Pat")))))
(DFunDef false "missingCtorPat" ((PVar "oracle") (PVar "ctors") (PVar "present")) (EMatch (EApp (EApp (EVar "firstMissing") (EVar "ctors")) (EVar "present")) (arm (PCon "None") () (EVar "PWild")) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EVar "replicate") (EApp (EApp (EVar "oGetArity") (EVar "oracle")) (EVar "c"))) (EVar "PWild"))))))
(DTypeSig false "firstMissing" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "firstMissing" ((PList) PWild) (EVar "None"))
(DFunDef false "firstMissing" ((PCons (PVar "c") (PVar "cs")) (PVar "present")) (EIf (EApp (EApp (EVar "contains") (EVar "c")) (EVar "present")) (EApp (EApp (EVar "firstMissing") (EVar "cs")) (EVar "present")) (EApp (EVar "Some") (EVar "c"))))
(DTypeSig true "renderWitness" (TyFun (TyCon "Pat") (TyCon "String")))
(DFunDef false "renderWitness" ((PVar "p")) (EApp (EApp (EVar "renderWit") (EVar "False")) (EVar "p")))
(DTypeSig false "renderWit" (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyCon "String"))))
(DFunDef false "renderWit" ((PVar "paren") (PCon "PCon" (PVar "c") (PVar "args"))) (EApp (EApp (EApp (EVar "renderConWit") (EVar "paren")) (EVar "c")) (EVar "args")))
(DFunDef false "renderWit" (PWild PWild) (ELit (LString "_")))
(DTypeSig false "renderConWit" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "String")))))
(DFunDef false "renderConWit" ((PVar "paren") (PVar "c") (PVar "args")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "Nil"))) (ELit (LString "[]")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "Cons"))) (EApp (EApp (EVar "renderCons") (EVar "paren")) (EVar "args")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "Unit"))) (ELit (LString "()")) (EMatch (EApp (EVar "tupleArityOfName") (EVar "c")) (arm (PCon "Some" PWild) () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EApp (EVar "renderWit") (EVar "False"))) (EVar "args"))))) (ELit (LString ")")))) (arm PWild () (EIf (EApp (EVar "isEmptyArgs") (EVar "args")) (EVar "c") (EIf (EVar "otherwise") (EApp (EApp (EVar "parenWrapWit") (EVar "paren")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "c"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EApp (EVar "renderWit") (EVar "True"))) (EVar "args"))))) (ELit (LString "")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "renderCons" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "String"))))
(DFunDef false "renderCons" ((PVar "paren") (PCons (PVar "h") (PCons (PVar "t") PWild))) (EApp (EApp (EVar "parenWrapWit") (EVar "paren")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "renderWit") (EVar "True")) (EVar "h")))) (ELit (LString " :: "))) (EApp (EVar "display") (EApp (EApp (EVar "renderWit") (EVar "False")) (EVar "t")))) (ELit (LString "")))))
(DFunDef false "renderCons" (PWild PWild) (ELit (LString "_ :: _")))
(DTypeSig false "isEmptyArgs" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool")))
(DFunDef false "isEmptyArgs" ((PList)) (EVar "True"))
(DFunDef false "isEmptyArgs" ((PCons PWild PWild)) (EVar "False"))
(DTypeSig false "parenWrapWit" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "parenWrapWit" ((PCon "True") (PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EVar "s"))) (ELit (LString ")"))))
(DFunDef false "parenWrapWit" ((PCon "False") (PVar "s")) (EVar "s"))
(DTypeSig false "isIrrefutablePat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isIrrefutablePat" ((PCon "PVar" PWild)) (EVar "True"))
(DFunDef false "isIrrefutablePat" ((PCon "PWild")) (EVar "True"))
(DFunDef false "isIrrefutablePat" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EVar "isIrrefutablePat")) (EVar "ps")))
(DFunDef false "isIrrefutablePat" ((PCon "PAs" PWild (PVar "p"))) (EApp (EVar "isIrrefutablePat") (EVar "p")))
(DFunDef false "isIrrefutablePat" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "allList") (EVar "recFieldIrrefutable")) (EVar "fields")))
(DFunDef false "isIrrefutablePat" (PWild) (EVar "False"))
(DTypeSig false "recFieldIrrefutable" (TyFun (TyCon "RecPatField") (TyCon "Bool")))
(DFunDef false "recFieldIrrefutable" ((PCon "RecPatField" PWild (PCon "None"))) (EVar "True"))
(DFunDef false "recFieldIrrefutable" ((PCon "RecPatField" PWild (PCon "Some" (PVar "p")))) (EApp (EVar "isIrrefutablePat") (EVar "p")))
(DTypeSig false "boolAlwaysTrue" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "boolAlwaysTrue" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "boolAlwaysTrue") (EVar "e")))
(DFunDef false "boolAlwaysTrue" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "boolAlwaysTrue") (EVar "e")))
(DFunDef false "boolAlwaysTrue" ((PCon "EVar" (PLit (LString "otherwise")))) (EVar "True"))
(DFunDef false "boolAlwaysTrue" ((PCon "EVar" (PLit (LString "True")))) (EVar "True"))
(DFunDef false "boolAlwaysTrue" ((PCon "ELit" (PCon "LBool" (PCon "True")))) (EVar "True"))
(DFunDef false "boolAlwaysTrue" (PWild) (EVar "False"))
(DTypeSig false "guardAlwaysFires" (TyFun (TyCon "Guard") (TyCon "Bool")))
(DFunDef false "guardAlwaysFires" ((PCon "GBool" (PVar "e"))) (EApp (EVar "boolAlwaysTrue") (EVar "e")))
(DFunDef false "guardAlwaysFires" ((PCon "GBind" (PVar "p") PWild)) (EApp (EVar "isIrrefutablePat") (EVar "p")))
(DTypeSig false "guardsDecidablyExhaustive" (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Bool")))
(DFunDef false "guardsDecidablyExhaustive" ((PVar "gs")) (EApp (EApp (EVar "allList") (EVar "guardAlwaysFires")) (EVar "gs")))
(DTypeSig false "guardArmsTotal" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyCon "Bool")))
(DFunDef false "guardArmsTotal" ((PVar "arms")) (EApp (EApp (EVar "anyList") (EVar "guardArmTotal")) (EVar "arms")))
(DTypeSig false "guardArmTotal" (TyFun (TyCon "GuardArm") (TyCon "Bool")))
(DFunDef false "guardArmTotal" ((PCon "GuardArm" (PVar "gs") PWild)) (EApp (EVar "guardsDecidablyExhaustive") (EVar "gs")))
(DTypeSig false "clauseGuardsTotal" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyCon "Bool")))
(DFunDef false "clauseGuardsTotal" ((PTuple PWild (PCon "EGuards" (PVar "arms")))) (EApp (EVar "guardArmsTotal") (EVar "arms")))
(DFunDef false "clauseGuardsTotal" (PWild) (EVar "True"))
(DTypeSig false "clauseIsGuardedPartial" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyCon "Bool")))
(DFunDef false "clauseIsGuardedPartial" ((PTuple PWild (PCon "EGuards" (PVar "arms")))) (EApp (EVar "not") (EApp (EVar "guardArmsTotal") (EVar "arms"))))
(DFunDef false "clauseIsGuardedPartial" (PWild) (EVar "False"))
(DTypeSig false "clausePats" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "clausePats" ((PTuple (PVar "pats") PWild)) (EVar "pats"))
(DTypeSig false "guardWarning" (TyCon "String"))
(DFunDef false "guardWarning" () (ELit (LString "Warning: guards may not be exhaustive")))
(DTypeSig false "checkGroup" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))))
(DFunDef false "checkGroup" ((PVar "oracle") (PVar "name") (PVar "clauses")) (EIf (EApp (EApp (EVar "anyList") (EVar "clauseIsGuardedPartial")) (EVar "clauses")) (EApp (EApp (EVar "checkGroupCovered") (EVar "oracle")) (EVar "clauses")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "checkGroupClauses") (EVar "oracle")) (EVar "name")) (EVar "clauses")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "checkGroupCovered" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "checkGroupCovered" ((PVar "oracle") (PVar "clauses")) (EBlock (DoLet false false (PVar "arity") (EApp (EVar "groupArity") (EVar "clauses"))) (DoLet false false (PVar "rows") (EApp (EApp (EVar "totalClauseRows") (EVar "oracle")) (EVar "clauses"))) (DoLet false false (PVar "query") (EListLit (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EApp (EVar "PTuple") (EApp (EApp (EVar "replicate") (EVar "arity")) (EVar "PWild")))))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EApp (EVar "Some") (EApp (EVar "tupleCtorName") (EVar "arity")))) (EVar "rows")) (EVar "query")) (EListLit (ETuple (EVar "guardWarning") (EApp (EVar "groupLoc") (EVar "clauses")))) (EListLit)))))
(DTypeSig false "checkGroupClauses" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))))
(DFunDef false "checkGroupClauses" ((PVar "oracle") (PVar "name") (PVar "clauses")) (EBlock (DoLet false false (PVar "arity") (EApp (EVar "groupArity") (EVar "clauses"))) (DoLet false false (PVar "rows") (EApp (EApp (EVar "totalClauseRows") (EVar "oracle")) (EVar "clauses"))) (DoLet false false (PVar "query") (EListLit (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EApp (EVar "PTuple") (EApp (EApp (EVar "replicate") (EVar "arity")) (EVar "PWild")))))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EApp (EVar "Some") (EApp (EVar "tupleCtorName") (EVar "arity")))) (EVar "rows")) (EVar "query")) (EListLit (ETuple (EApp (EApp (EApp (EApp (EVar "nonExhaustiveClausesMsg") (EVar "oracle")) (EVar "name")) (EVar "arity")) (EVar "rows")) (EApp (EVar "groupLoc") (EVar "clauses")))) (EListLit)))))
(DTypeSig false "nonExhaustiveClausesMsg" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyCon "String"))))))
(DFunDef false "nonExhaustiveClausesMsg" ((PVar "oracle") (PVar "name") (PVar "arity") (PVar "rows")) (EMatch (EApp (EApp (EApp (EApp (EVar "usefulWitness") (EVar "oracle")) (EApp (EVar "Some") (EApp (EVar "tupleCtorName") (EVar "arity")))) (EVar "rows")) (ELit (LInt 1))) (arm (PCon "Some" (PCons (PVar "w") PWild)) () (EBlock (DoLet false false (PVar "witnessStr") (EApp (EApp (EVar "renderClauseWitness") (EVar "arity")) (EVar "w"))) (DoLet false false (PVar "hint") (EBinOp "++" (EBinOp "++" (ELit (LString "add a '")) (EApp (EVar "display") (EVar "witnessStr"))) (ELit (LString "' clause, or a '_' catch-all clause.")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Warning: non-exhaustive clauses of '")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "'. Missing case: '"))) (EApp (EVar "display") (EVar "witnessStr"))) (ELit (LString "'; "))) (EApp (EVar "display") (EVar "hint"))) (ELit (LString "")))))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "Warning: non-exhaustive clauses of '")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "'. Not all cases are covered"))))))
(DTypeSig false "renderClauseWitness" (TyFun (TyCon "Int") (TyFun (TyCon "Pat") (TyCon "String"))))
(DFunDef false "renderClauseWitness" ((PLit (LInt 1)) (PCon "PCon" PWild (PCons (PVar "inner") PWild))) (EApp (EVar "renderWitness") (EVar "inner")))
(DFunDef false "renderClauseWitness" (PWild (PVar "w")) (EApp (EVar "renderWitness") (EVar "w")))
(DTypeSig false "groupLoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "groupLoc" ((PList)) (EVar "None"))
(DFunDef false "groupLoc" ((PCons (PTuple PWild (PVar "body")) PWild)) (EApp (EVar "clauseBodyLoc") (EVar "body")))
(DTypeSig false "clauseBodyLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "clauseBodyLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "clauseBodyLoc" ((PCon "EDoOrigin" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "clauseBodyLoc" (PWild) (EVar "None"))
(DTypeSig false "groupArity" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyCon "Int")))
(DFunDef false "groupArity" ((PList)) (ELit (LInt 0)))
(DFunDef false "groupArity" ((PCons (PVar "c") PWild)) (EApp (EVar "listLen") (EApp (EVar "clausePats") (EVar "c"))))
(DTypeSig false "totalClauseRows" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))))))
(DFunDef false "totalClauseRows" (PWild (PList)) (EListLit))
(DFunDef false "totalClauseRows" ((PVar "oracle") (PCons (PVar "c") (PVar "rest"))) (EIf (EApp (EVar "clauseGuardsTotal") (EVar "c")) (EBinOp "::" (EListLit (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EApp (EVar "PTuple") (EApp (EVar "clausePats") (EVar "c"))))) (EApp (EApp (EVar "totalClauseRows") (EVar "oracle")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "totalClauseRows") (EVar "oracle")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "groupByName" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "groupByName" ((PVar "items")) (EBlock (DoLet false false (PVar "buckets") (EApp (EApp (EVar "bucketClauses") (EVar "items")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "reverseL") (EApp (EApp (EVar "bucketFor") (EVar "n")) (EVar "buckets")))))) (EApp (EApp (EVar "firstSeenNames") (EVar "items")) (EVar "omEmpty"))))))
(DTypeAlias false "ClauseBuckets" () (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DTypeSig false "bucketClauses" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "ClauseBuckets") (TyCon "ClauseBuckets"))))
(DFunDef false "bucketClauses" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "bucketClauses" ((PCons (PTuple (PVar "n") (PVar "c")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "bucketClauses") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "::" (EVar "c") (EApp (EApp (EVar "bucketFor") (EVar "n")) (EVar "acc")))) (EVar "acc"))))
(DTypeSig false "bucketFor" (TyFun (TyCon "String") (TyFun (TyCon "ClauseBuckets") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "bucketFor" ((PVar "n") (PVar "acc")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "acc")) (arm (PCon "Some" (PVar "cs")) () (EVar "cs")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "firstSeenNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "firstSeenNames" ((PList) PWild) (EListLit))
(DFunDef false "firstSeenNames" ((PCons (PTuple (PVar "n") PWild) (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "seen")) (EApp (EApp (EVar "firstSeenNames") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "n") (EApp (EApp (EVar "firstSeenNames") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "letGroupWarnings" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "letGroupWarnings" ((PVar "oracle") (PVar "body")) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkLetBind") (EVar "oracle"))) (EApp (EVar "collectLetBinds") (EVar "body"))))
(DTypeSig false "checkLetBind" (TyFun (TyCon "Oracle") (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "checkLetBind" ((PVar "oracle") (PCon "LetBind" (PVar "name") (PVar "funclauses"))) (EApp (EApp (EApp (EVar "checkGroup") (EVar "oracle")) (EVar "name")) (EApp (EApp (EVar "map") (EVar "funClauseToClause")) (EVar "funclauses"))))
(DTypeSig false "funClauseToClause" (TyFun (TyCon "FunClause") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))
(DFunDef false "funClauseToClause" ((PCon "FunClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "pats") (EVar "body")))
(DTypeSig false "collectLetBinds" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "collectLetBinds" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EBinOp "++" (EVar "binds") (EApp (EApp (EVar "flatMap") (EVar "collectLetBindInner")) (EVar "binds"))) (EApp (EVar "collectLetBinds") (EVar "body"))))
(DFunDef false "collectLetBinds" ((PCon "EApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "a")) (EApp (EVar "collectLetBinds") (EVar "b"))))
(DFunDef false "collectLetBinds" ((PCon "ELam" PWild (PVar "b"))) (EApp (EVar "collectLetBinds") (EVar "b")))
(DFunDef false "collectLetBinds" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "e1")) (EApp (EVar "collectLetBinds") (EVar "e2"))))
(DFunDef false "collectLetBinds" ((PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "e0")) (EApp (EApp (EVar "flatMap") (EVar "collectArmBinds")) (EVar "arms"))))
(DFunDef false "collectLetBinds" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "c")) (EApp (EVar "collectLetBinds") (EVar "t"))) (EApp (EVar "collectLetBinds") (EVar "el"))))
(DFunDef false "collectLetBinds" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "a")) (EApp (EVar "collectLetBinds") (EVar "b"))))
(DFunDef false "collectLetBinds" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EVar "collectLetBinds") (EVar "a")))
(DFunDef false "collectLetBinds" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "a")) (EApp (EVar "collectLetBinds") (EVar "b"))))
(DFunDef false "collectLetBinds" ((PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EVar "collectLetBinds") (EVar "e0")))
(DFunDef false "collectLetBinds" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "flatMap") (EVar "fieldAssignBinds")) (EVar "fs")))
(DFunDef false "collectLetBinds" ((PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild)) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "e0")) (EApp (EApp (EVar "flatMap") (EVar "fieldAssignBinds")) (EVar "fs"))))
(DFunDef false "collectLetBinds" ((PCon "EVariantUpdate" PWild (PVar "e0") (PVar "fs"))) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "e0")) (EApp (EApp (EVar "flatMap") (EVar "fieldAssignBinds")) (EVar "fs"))))
(DFunDef false "collectLetBinds" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "collectLetBinds")) (EVar "es")))
(DFunDef false "collectLetBinds" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "collectLetBinds")) (EVar "es")))
(DFunDef false "collectLetBinds" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EVar "collectLetBinds")) (EVar "es")))
(DFunDef false "collectLetBinds" ((PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "e0")) (EApp (EVar "collectLetBinds") (EVar "i"))))
(DFunDef false "collectLetBinds" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "lo")) (EApp (EVar "collectLetBinds") (EVar "hi"))))
(DFunDef false "collectLetBinds" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "lo")) (EApp (EVar "collectLetBinds") (EVar "hi"))))
(DFunDef false "collectLetBinds" ((PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "e0")) (EApp (EVar "collectLetBinds") (EVar "lo"))) (EApp (EVar "collectLetBinds") (EVar "hi"))))
(DFunDef false "collectLetBinds" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "doStmtBinds")) (EVar "stmts")))
(DFunDef false "collectLetBinds" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "doStmtBinds")) (EVar "stmts")))
(DFunDef false "collectLetBinds" ((PCon "EAnnot" (PVar "e0") PWild)) (EApp (EVar "collectLetBinds") (EVar "e0")))
(DFunDef false "collectLetBinds" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "flatMap") (EVar "interpBinds")) (EVar "parts")))
(DFunDef false "collectLetBinds" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "flatMap") (EVar "guardArmBinds")) (EVar "arms")))
(DFunDef false "collectLetBinds" ((PCon "ESection" (PCon "SecRight" PWild (PVar "e0")))) (EApp (EVar "collectLetBinds") (EVar "e0")))
(DFunDef false "collectLetBinds" ((PCon "ESection" (PCon "SecLeft" (PVar "e0") PWild))) (EApp (EVar "collectLetBinds") (EVar "e0")))
(DFunDef false "collectLetBinds" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DFunDef false "collectLetBinds" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DFunDef false "collectLetBinds" (PWild) (EListLit))
(DTypeSig false "collectLetBindInner" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "collectLetBindInner" ((PCon "LetBind" PWild (PVar "funclauses"))) (EApp (EApp (EVar "flatMap") (EVar "funClauseBinds")) (EVar "funclauses")))
(DTypeSig false "funClauseBinds" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "funClauseBinds" ((PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "collectLetBinds") (EVar "body")))
(DTypeSig false "collectArmBinds" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "collectArmBinds" ((PCon "Arm" PWild (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "guardBinds")) (EVar "gs")) (EApp (EVar "collectLetBinds") (EVar "body"))))
(DTypeSig false "guardBinds" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "guardBinds" ((PCon "GBool" (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DFunDef false "guardBinds" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DTypeSig false "guardArmBinds" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "guardArmBinds" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "guardBinds")) (EVar "gs")) (EApp (EVar "collectLetBinds") (EVar "body"))))
(DTypeSig false "fieldAssignBinds" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "fieldAssignBinds" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DTypeSig false "doStmtBinds" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "doStmtBinds" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DFunDef false "doStmtBinds" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DFunDef false "doStmtBinds" ((PCon "DoLet" PWild PWild PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DFunDef false "doStmtBinds" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DFunDef false "doStmtBinds" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DTypeSig false "interpBinds" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "interpBinds" ((PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "interpBinds" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DTypeSig true "checkGuardExhaustivenessWith" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "checkGuardExhaustivenessWith" ((PVar "oracleDecls") (PVar "checkDecls")) (EBlock (DoLet false false (PVar "oracle") (EApp (EVar "buildOracle") (EBinOp "++" (EVar "checkDecls") (EVar "oracleDecls")))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "checkNamedGroup") (EVar "oracle"))) (EApp (EVar "groupByName") (EApp (EVar "topFunDefClauses") (EVar "checkDecls")))) (EApp (EApp (EVar "flatMap") (EApp (EVar "declBodyWarnings") (EVar "oracle"))) (EVar "checkDecls"))))))
(DTypeSig false "checkNamedGroup" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "checkNamedGroup" ((PVar "oracle") (PTuple (PVar "name") (PVar "clauses"))) (EApp (EApp (EApp (EVar "checkGroup") (EVar "oracle")) (EVar "name")) (EVar "clauses")))
(DTypeSig true "checkGuardExhaustiveness" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "checkGuardExhaustiveness" ((PVar "prog")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "checkGuardExhaustivenessWith") (EVar "prog")) (EVar "prog"))))
(DTypeSig false "topFunDefClauses" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "topFunDefClauses" ((PList)) (EListLit))
(DFunDef false "topFunDefClauses" ((PCons (PCon "DFunDef" PWild (PVar "n") (PVar "pats") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (ETuple (EVar "pats") (EVar "body"))) (EApp (EVar "topFunDefClauses") (EVar "rest"))))
(DFunDef false "topFunDefClauses" ((PCons PWild (PVar "rest"))) (EApp (EVar "topFunDefClauses") (EVar "rest")))
(DTypeSig false "declBodyWarnings" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "declBodyWarnings" ((PVar "oracle") (PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EApp (EVar "letGroupWarnings") (EVar "oracle")) (EVar "body")))
(DFunDef false "declBodyWarnings" ((PVar "oracle") (PRec "DImpl" ((rf "methods" None)) true)) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "checkNamedGroup") (EVar "oracle"))) (EApp (EVar "groupByName") (EApp (EVar "implClauses") (EVar "methods")))) (EApp (EApp (EVar "flatMap") (EApp (EVar "implMethodBodyWarnings") (EVar "oracle"))) (EVar "methods"))))
(DFunDef false "declBodyWarnings" ((PVar "oracle") (PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EApp (EVar "ifaceMethodWarnings") (EVar "oracle"))) (EVar "methods")))
(DFunDef false "declBodyWarnings" ((PVar "oracle") (PCon "DProp" PWild PWild PWild (PVar "body"))) (EApp (EApp (EVar "letGroupWarnings") (EVar "oracle")) (EVar "body")))
(DFunDef false "declBodyWarnings" ((PVar "oracle") (PCon "DTest" PWild PWild (PVar "body"))) (EApp (EApp (EVar "letGroupWarnings") (EVar "oracle")) (EVar "body")))
(DFunDef false "declBodyWarnings" ((PVar "oracle") (PCon "DBench" PWild PWild (PVar "body"))) (EApp (EApp (EVar "letGroupWarnings") (EVar "oracle")) (EVar "body")))
(DFunDef false "declBodyWarnings" (PWild PWild) (EListLit))
(DTypeSig false "implClauses" (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "implClauses" ((PList)) (EListLit))
(DFunDef false "implClauses" ((PCons (PCon "ImplMethod" (PVar "n") (PVar "pats") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (ETuple (EVar "pats") (EVar "body"))) (EApp (EVar "implClauses") (EVar "rest"))))
(DTypeSig false "implMethodBodyWarnings" (TyFun (TyCon "Oracle") (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "implMethodBodyWarnings" ((PVar "oracle") (PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EApp (EVar "letGroupWarnings") (EVar "oracle")) (EVar "body")))
(DTypeSig false "ifaceMethodWarnings" (TyFun (TyCon "Oracle") (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "ifaceMethodWarnings" (PWild (PCon "IfaceMethod" PWild PWild (PCon "None"))) (EListLit))
(DFunDef false "ifaceMethodWarnings" ((PVar "oracle") (PCon "IfaceMethod" PWild PWild (PCon "Some" (PCon "MethodDefault" PWild (PVar "body"))))) (EApp (EApp (EVar "letGroupWarnings") (EVar "oracle")) (EVar "body")))
(DTypeSig true "exhaustToLinesWith" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "exhaustToLinesWith" ((PVar "oracleDecls") (PVar "checkDecls")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "checkGuardExhaustivenessWith") (EVar "oracleDecls")) (EVar "checkDecls")))))
(DTypeSig true "exhaustToLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "exhaustToLines" ((PVar "prog")) (EApp (EApp (EVar "exhaustToLinesWith") (EVar "prog")) (EVar "prog")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Loc" false) (mem "Ty" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true))))
(DUse false (UseGroup ("list") ((mem "replicate" false) (mem "take" false) (mem "drop" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "allList" false) (mem "anyList" false) (mem "listLen" false) (mem "reverseL" false) (mem "joinNl" false) (mem "joinWith" false) (mem "orElseOpt" false) (mem "reverseL" false))))
(DTypeSig true "tupleCtorName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "tupleCtorName" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "__tuple")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "__"))))
(DTypeSig false "tupleArityOfName" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "tupleArityOfName" ((PVar "c")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "c"))) (DoExpr (EApp (EApp (EVar "tupleArityCheck") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))))))
(DTypeSig false "tupleArityCheck" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "tupleArityCheck" ((PVar "cs") (PVar "n")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 9))) (EApp (EVar "charsPrefixTuple") (EVar "cs"))) (EApp (EApp (EVar "charsSuffixUnder") (EVar "cs")) (EVar "n"))) (EApp (EApp (EApp (EVar "parseDigits") (EVar "cs")) (ELit (LInt 7))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "charsPrefixTuple" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Bool")))
(DFunDef false "charsPrefixTuple" ((PVar "cs")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")) (ELit (LChar "_"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 1))) (EVar "cs")) (ELit (LChar "_")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 2))) (EVar "cs")) (ELit (LChar "t")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 3))) (EVar "cs")) (ELit (LChar "u")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 4))) (EVar "cs")) (ELit (LChar "p")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 5))) (EVar "cs")) (ELit (LChar "l")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 6))) (EVar "cs")) (ELit (LChar "e")))))
(DTypeSig false "charsSuffixUnder" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "charsSuffixUnder" ((PVar "cs") (PVar "n")) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "cs")) (ELit (LChar "_"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "_")))))
(DTypeSig false "parseDigits" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "parseDigits" ((PVar "cs") (PVar "start") (PVar "end")) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigitsGo") (EVar "cs")) (EVar "start")) (EVar "end")) (ELit (LInt 0))) (EVar "False")))
(DTypeSig false "parseDigitsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "parseDigitsGo" ((PVar "cs") (PVar "i") (PVar "end") (PVar "acc") (PVar "seen")) (EIf (EBinOp ">=" (EVar "i") (EVar "end")) (EIf (EVar "seen") (EApp (EVar "Some") (EVar "acc")) (EVar "None")) (EIf (EApp (EVar "isDigitC") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EApp (EApp (EVar "parseDigitsGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "end")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EApp (EVar "digitVal") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))) (EVar "True")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isDigitC" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isDigitC" ((PVar "c")) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LChar "0"))) (EBinOp "<=" (EVar "c") (ELit (LChar "9")))))
(DTypeSig false "digitVal" (TyFun (TyCon "Char") (TyCon "Int")))
(DFunDef false "digitVal" ((PVar "c")) (EBinOp "-" (EApp (EVar "charCode") (EVar "c")) (EApp (EVar "charCode") (ELit (LChar "0")))))
(DData Public "Oracle" () ((variant "Oracle" (ConNamed (field "typeCtors" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "ctorArity" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "ctorType" (TyApp (TyCon "OrdMap") (TyCon "String"))) (field "ctorFields" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))) ())
(DTypeSig true "buildOracle" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Oracle")))
(DFunDef false "buildOracle" ((PVar "prog")) (ERecordCreate "Oracle" ((fa "typeCtors" (EApp (EVar "oracleMap") (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "dataTypeCtors")) (EVar "prog")) (EVar "builtinTypeCtors")))) (fa "ctorArity" (EApp (EVar "oracleMap") (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "dataArity")) (EVar "prog")) (EVar "builtinArity")))) (fa "ctorType" (EApp (EVar "oracleMap") (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "dataCtorType")) (EVar "prog")) (EVar "builtinCtorType")))) (fa "ctorFields" (EApp (EVar "oracleMap") (EApp (EApp (EDictApp "flatMap") (EVar "dataCtorFields")) (EVar "prog")))))))
(DTypeSig false "oracleMap" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "OrdMap") (TyVar "a"))))
(DFunDef false "oracleMap" ((PVar "pairs")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "pairs"))) (EVar "omEmpty")))
(DTypeSig false "builtinTypeCtors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "builtinTypeCtors" () (EListLit (ETuple (ELit (LString "Bool")) (EListLit (ELit (LString "True")) (ELit (LString "False")))) (ETuple (ELit (LString "List")) (EListLit (ELit (LString "Cons")) (ELit (LString "Nil")))) (ETuple (ELit (LString "Unit")) (EListLit (ELit (LString "Unit"))))))
(DTypeSig false "builtinArity" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "builtinArity" () (EListLit (ETuple (ELit (LString "True")) (ELit (LInt 0))) (ETuple (ELit (LString "False")) (ELit (LInt 0))) (ETuple (ELit (LString "Cons")) (ELit (LInt 2))) (ETuple (ELit (LString "Nil")) (ELit (LInt 0))) (ETuple (ELit (LString "Unit")) (ELit (LInt 0)))))
(DTypeSig false "builtinCtorType" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "builtinCtorType" () (EListLit (ETuple (ELit (LString "True")) (ELit (LString "Bool"))) (ETuple (ELit (LString "False")) (ELit (LString "Bool"))) (ETuple (ELit (LString "Cons")) (ELit (LString "List"))) (ETuple (ELit (LString "Nil")) (ELit (LString "List"))) (ETuple (ELit (LString "Unit")) (ELit (LString "Unit")))))
(DTypeSig false "dataTypeCtors" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dataTypeCtors" ((PCon "DData" PWild (PVar "tyname") PWild (PVar "variants") PWild)) (EListLit (ETuple (EVar "tyname") (EApp (EApp (EMethodRef "map") (EVar "variantName")) (EVar "variants")))))
(DFunDef false "dataTypeCtors" (PWild) (EListLit))
(DTypeSig false "dataArity" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "dataArity" ((PCon "DData" PWild PWild PWild (PVar "variants") PWild)) (EApp (EApp (EMethodRef "map") (EVar "variantArity")) (EVar "variants")))
(DFunDef false "dataArity" (PWild) (EListLit))
(DTypeSig false "dataCtorType" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "dataCtorType" ((PCon "DData" PWild (PVar "tyname") PWild (PVar "variants") PWild)) (EApp (EApp (EMethodRef "map") (EApp (EVar "variantCtorType") (EVar "tyname"))) (EVar "variants")))
(DFunDef false "dataCtorType" (PWild) (EListLit))
(DTypeSig false "variantName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "variantArity" (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "variantArity" ((PCon "Variant" (PVar "n") (PCon "ConPos" (PVar "tys")))) (ETuple (EVar "n") (EApp (EVar "listLen") (EVar "tys"))))
(DFunDef false "variantArity" ((PCon "Variant" (PVar "n") (PCon "ConNamed" (PVar "fs") PWild))) (ETuple (EVar "n") (EApp (EVar "listLen") (EVar "fs"))))
(DTypeSig false "variantCtorType" (TyFun (TyCon "String") (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "variantCtorType" ((PVar "tyname") (PCon "Variant" (PVar "n") PWild)) (ETuple (EVar "n") (EVar "tyname")))
(DTypeSig false "dataCtorFields" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dataCtorFields" ((PCon "DData" PWild PWild PWild (PVar "variants") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "variantCtorFields")) (EVar "variants")))
(DFunDef false "dataCtorFields" (PWild) (EListLit))
(DTypeSig false "variantCtorFields" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "variantCtorFields" ((PCon "Variant" (PVar "n") (PCon "ConNamed" (PVar "fs") PWild))) (EListLit (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "fieldName")) (EVar "fs")))))
(DFunDef false "variantCtorFields" (PWild) (EListLit))
(DTypeSig false "fieldName" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldName" ((PCon "Field" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "oGetCtorFields" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "oGetCtorFields" ((PVar "oracle") (PVar "c")) (EApp (EApp (EVar "omLookup") (EVar "c")) (EFieldAccess (EVar "oracle") "ctorFields")))
(DTypeSig true "oGetCtors" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "oGetCtors" ((PVar "oracle") (PVar "t")) (EMatch (EApp (EVar "tupleArityOfName") (EVar "t")) (arm (PCon "Some" PWild) () (EApp (EVar "Some") (EListLit (EVar "t")))) (arm PWild () (EIf (EVar "otherwise") (EApp (EApp (EVar "omLookup") (EVar "t")) (EFieldAccess (EVar "oracle") "typeCtors")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "oGetCtorType" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "oGetCtorType" ((PVar "oracle") (PVar "c")) (EMatch (EApp (EVar "tupleArityOfName") (EVar "c")) (arm (PCon "Some" PWild) () (EApp (EVar "Some") (EVar "c"))) (arm PWild () (EIf (EVar "otherwise") (EApp (EApp (EVar "omLookup") (EVar "c")) (EFieldAccess (EVar "oracle") "ctorType")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "oGetArity" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "oGetArity" ((PVar "oracle") (PVar "c")) (EMatch (EApp (EVar "tupleArityOfName") (EVar "c")) (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm PWild () (EIf (EVar "otherwise") (EApp (EApp (EVar "fromOption") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "c")) (EFieldAccess (EVar "oracle") "ctorArity"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "desugarPat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "desugarPat" (PWild (PCon "PWild")) (EVar "PWild"))
(DFunDef false "desugarPat" (PWild (PCon "PVar" PWild)) (EVar "PWild"))
(DFunDef false "desugarPat" (PWild (PCon "PLit" (PCon "LBool" (PCon "True")))) (EApp (EApp (EVar "PCon") (ELit (LString "True"))) (EListLit)))
(DFunDef false "desugarPat" (PWild (PCon "PLit" (PCon "LBool" (PCon "False")))) (EApp (EApp (EVar "PCon") (ELit (LString "False"))) (EListLit)))
(DFunDef false "desugarPat" (PWild (PCon "PLit" (PCon "LUnit"))) (EApp (EApp (EVar "PCon") (ELit (LString "Unit"))) (EListLit)))
(DFunDef false "desugarPat" (PWild (PCon "PLit" (PVar "l"))) (EApp (EVar "PLit") (EVar "l")))
(DFunDef false "desugarPat" ((PVar "oracle") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "PCon") (EApp (EVar "tupleCtorName") (EApp (EVar "listLen") (EVar "ps")))) (EApp (EApp (EMethodRef "map") (EApp (EVar "desugarPat") (EVar "oracle"))) (EVar "ps"))))
(DFunDef false "desugarPat" ((PVar "oracle") (PCon "PCon" (PVar "c") (PVar "args"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EMethodRef "map") (EApp (EVar "desugarPat") (EVar "oracle"))) (EVar "args"))))
(DFunDef false "desugarPat" ((PVar "oracle") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCon") (ELit (LString "Cons"))) (EListLit (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EVar "h")) (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EVar "t")))))
(DFunDef false "desugarPat" (PWild (PCon "PList" (PList))) (EApp (EApp (EVar "PCon") (ELit (LString "Nil"))) (EListLit)))
(DFunDef false "desugarPat" ((PVar "oracle") (PCon "PList" (PCons (PVar "h") (PVar "rest")))) (EApp (EApp (EVar "PCon") (ELit (LString "Cons"))) (EListLit (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EVar "h")) (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EApp (EVar "PList") (EVar "rest"))))))
(DFunDef false "desugarPat" ((PVar "oracle") (PCon "PAs" PWild (PVar "p"))) (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EVar "p")))
(DFunDef false "desugarPat" (PWild (PCon "PRec" PWild PWild (PCon "True"))) (EVar "PWild"))
(DFunDef false "desugarPat" ((PVar "oracle") (PCon "PRec" (PVar "name") (PVar "fields") PWild)) (EMatch (EApp (EApp (EVar "oGetCtorFields") (EVar "oracle")) (EVar "name")) (arm (PCon "None") () (EVar "PWild")) (arm (PCon "Some" (PVar "fieldOrder")) () (EApp (EApp (EVar "PCon") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "lookupRecField") (EVar "oracle")) (EVar "fields"))) (EVar "fieldOrder"))))))
(DFunDef false "desugarPat" (PWild (PCon "PRng" PWild PWild PWild)) (EVar "PWild"))
(DTypeSig false "lookupRecField" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyFun (TyCon "String") (TyCon "Pat")))))
(DFunDef false "lookupRecField" ((PVar "oracle") (PVar "fields") (PVar "fn")) (EMatch (EApp (EApp (EVar "findRecField") (EVar "fn")) (EVar "fields")) (arm (PCon "None") () (EVar "PWild")) (arm (PCon "Some" (PCon "None")) () (EVar "PWild")) (arm (PCon "Some" (PCon "Some" (PVar "p"))) () (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EVar "p")))))
(DTypeSig false "findRecField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyApp (TyCon "Option") (TyApp (TyCon "Option") (TyCon "Pat"))))))
(DFunDef false "findRecField" (PWild (PList)) (EVar "None"))
(DFunDef false "findRecField" ((PVar "fn") (PCons (PCon "RecPatField" (PVar "f") (PVar "mPat")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "f") (EVar "fn")) (EApp (EVar "Some") (EVar "mPat")) (EIf (EVar "otherwise") (EApp (EApp (EVar "findRecField") (EVar "fn")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "specializeCon" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))))))
(DFunDef false "specializeCon" (PWild PWild (PList)) (EListLit))
(DFunDef false "specializeCon" ((PVar "c") (PVar "arity") (PCons (PVar "row") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "specConRow") (EVar "c")) (EVar "arity")) (EVar "row")) (arm (PCon "Some" (PVar "r")) () (EBinOp "::" (EVar "r") (EApp (EApp (EApp (EVar "specializeCon") (EVar "c")) (EVar "arity")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "specializeCon") (EVar "c")) (EVar "arity")) (EVar "rest")))))
(DTypeSig false "specConRow" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat")))))))
(DFunDef false "specConRow" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "specConRow" ((PVar "c") PWild (PCons (PCon "PCon" (PVar "c2") (PVar "args")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "c2") (EVar "c")) (EApp (EVar "Some") (EBinOp "++" (EVar "args") (EVar "rest"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "specConRow" (PWild (PVar "arity") (PCons (PCon "PWild") (PVar "rest"))) (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EVar "replicate") (EVar "arity")) (EVar "PWild")) (EVar "rest"))))
(DFunDef false "specConRow" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "specializeLit" (TyFun (TyCon "Lit") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))))))
(DFunDef false "specializeLit" (PWild (PList)) (EListLit))
(DFunDef false "specializeLit" ((PVar "l") (PCons (PVar "row") (PVar "rest"))) (EMatch (EApp (EApp (EVar "specLitRow") (EVar "l")) (EVar "row")) (arm (PCon "Some" (PVar "r")) () (EBinOp "::" (EVar "r") (EApp (EApp (EVar "specializeLit") (EVar "l")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "specializeLit") (EVar "l")) (EVar "rest")))))
(DTypeSig false "specLitRow" (TyFun (TyCon "Lit") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))))))
(DFunDef false "specLitRow" (PWild (PList)) (EVar "None"))
(DFunDef false "specLitRow" ((PVar "l") (PCons (PCon "PLit" (PVar "l2")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "l2") (EVar "l")) (EApp (EVar "Some") (EVar "rest")) (EVar "None")))
(DFunDef false "specLitRow" (PWild (PCons (PCon "PWild") (PVar "rest"))) (EApp (EVar "Some") (EVar "rest")))
(DFunDef false "specLitRow" (PWild PWild) (EVar "None"))
(DTypeSig false "defaultMatrix" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "defaultMatrix" ((PList)) (EListLit))
(DFunDef false "defaultMatrix" ((PCons (PVar "row") (PVar "rest"))) (EMatch (EApp (EVar "defRow") (EVar "row")) (arm (PCon "Some" (PVar "r")) () (EBinOp "::" (EVar "r") (EApp (EVar "defaultMatrix") (EVar "rest")))) (arm (PCon "None") () (EApp (EVar "defaultMatrix") (EVar "rest")))))
(DTypeSig false "defRow" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "defRow" ((PCons (PCon "PWild") (PVar "rest"))) (EApp (EVar "Some") (EVar "rest")))
(DFunDef false "defRow" (PWild) (EVar "None"))
(DTypeSig false "headCtors" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "headCtors" ((PList)) (EListLit))
(DFunDef false "headCtors" ((PCons (PCons (PCon "PCon" (PVar "c") PWild) PWild) (PVar "rest"))) (EBinOp "::" (EVar "c") (EApp (EVar "headCtors") (EVar "rest"))))
(DFunDef false "headCtors" ((PCons PWild (PVar "rest"))) (EApp (EVar "headCtors") (EVar "rest")))
(DTypeSig false "inferCol0Type" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "inferCol0Type" ((PVar "oracle") (PVar "pmat")) (EApp (EApp (EVar "tryEachType") (EVar "oracle")) (EApp (EVar "headCtors") (EVar "pmat"))))
(DTypeSig false "tryEachType" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "tryEachType" (PWild (PList)) (EVar "None"))
(DFunDef false "tryEachType" ((PVar "oracle") (PCons (PVar "c") (PVar "cs"))) (EMatch (EApp (EApp (EVar "oGetCtorType") (EVar "oracle")) (EVar "c")) (arm (PCon "Some" (PVar "t")) () (EApp (EVar "Some") (EVar "t"))) (arm (PCon "None") () (EApp (EApp (EVar "tryEachType") (EVar "oracle")) (EVar "cs")))))
(DTypeSig true "useful" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool"))))))
(DFunDef false "useful" (PWild PWild (PList) PWild) (EVar "True"))
(DFunDef false "useful" (PWild PWild (PCons PWild PWild) (PList)) (EVar "False"))
(DFunDef false "useful" ((PVar "oracle") (PVar "col0") (PVar "pmat") (PCons (PVar "h") (PVar "restQ"))) (EApp (EApp (EApp (EApp (EApp (EVar "usefulHead") (EVar "oracle")) (EVar "col0")) (EVar "pmat")) (EVar "h")) (EVar "restQ")))
(DTypeSig false "usefulHead" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool")))))))
(DFunDef false "usefulHead" ((PVar "oracle") PWild (PVar "pmat") (PCon "PCon" (PVar "c") (PVar "args")) (PVar "restQ")) (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "None")) (EApp (EApp (EApp (EVar "specializeCon") (EVar "c")) (EApp (EVar "listLen") (EVar "args"))) (EVar "pmat"))) (EBinOp "++" (EVar "args") (EVar "restQ"))))
(DFunDef false "usefulHead" ((PVar "oracle") PWild (PVar "pmat") (PCon "PLit" (PVar "l")) (PVar "restQ")) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "None")) (EApp (EApp (EVar "specializeLit") (EVar "l")) (EVar "pmat"))) (EVar "restQ")) (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "None")) (EApp (EVar "defaultMatrix") (EVar "pmat"))) (EVar "restQ"))))
(DFunDef false "usefulHead" ((PVar "oracle") (PVar "col0") (PVar "pmat") PWild (PVar "restQ")) (EApp (EApp (EApp (EApp (EVar "usefulWild") (EVar "oracle")) (EVar "col0")) (EVar "pmat")) (EVar "restQ")))
(DTypeSig false "usefulWild" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool"))))))
(DFunDef false "usefulWild" ((PVar "oracle") (PVar "col0") (PVar "pmat") (PVar "restQ")) (EBlock (DoLet false false (PVar "col0t") (EApp (EApp (EVar "orElseOpt") (EVar "col0")) (EApp (EApp (EVar "inferCol0Type") (EVar "oracle")) (EVar "pmat")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "usefulWildCtors") (EVar "oracle")) (EApp (EApp (EVar "bindCtors") (EVar "oracle")) (EVar "col0t"))) (EVar "pmat")) (EVar "restQ")))))
(DTypeSig false "bindCtors" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "bindCtors" (PWild (PCon "None")) (EVar "None"))
(DFunDef false "bindCtors" ((PVar "oracle") (PCon "Some" (PVar "t"))) (EApp (EApp (EVar "oGetCtors") (EVar "oracle")) (EVar "t")))
(DTypeSig false "usefulWildCtors" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool"))))))
(DFunDef false "usefulWildCtors" ((PVar "oracle") (PCon "None") (PVar "pmat") (PVar "restQ")) (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "None")) (EApp (EVar "defaultMatrix") (EVar "pmat"))) (EVar "restQ")))
(DFunDef false "usefulWildCtors" ((PVar "oracle") (PCon "Some" (PVar "ctors")) (PVar "pmat") (PVar "restQ")) (EApp (EApp (EApp (EApp (EVar "usefulCovered") (EVar "oracle")) (EVar "ctors")) (EVar "pmat")) (EVar "restQ")))
(DTypeSig false "usefulCovered" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool"))))))
(DFunDef false "usefulCovered" ((PVar "oracle") (PVar "ctors") (PVar "pmat") (PVar "restQ")) (EApp (EApp (EApp (EApp (EApp (EVar "usefulBuckets") (EVar "oracle")) (EVar "ctors")) (EVar "pmat")) (EVar "restQ")) (EApp (EApp (EVar "headBuckets") (EVar "pmat")) (EVar "omEmpty"))))
(DTypeSig false "usefulBuckets" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))) (TyCon "Bool")))))))
(DFunDef false "usefulBuckets" ((PVar "oracle") (PVar "ctors") (PVar "pmat") (PVar "restQ") (PVar "buckets")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "allCovered") (EVar "ctors")) (EVar "buckets"))) (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "None")) (EApp (EVar "defaultMatrix") (EVar "pmat"))) (EVar "restQ")) (EIf (EApp (EVar "anyWildHead") (EVar "pmat")) (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "usefulBranch") (EVar "oracle")) (EVar "pmat")) (EVar "restQ"))) (EVar "ctors")) (EIf (EVar "otherwise") (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "usefulBranchIn") (EVar "oracle")) (EVar "buckets")) (EVar "restQ"))) (EVar "ctors")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "headBuckets" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))))))
(DFunDef false "headBuckets" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "headBuckets" ((PCons (PVar "row") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "headBuckets") (EVar "rest")) (EApp (EApp (EVar "headBucketRow") (EVar "row")) (EVar "acc"))))
(DTypeSig false "headBucketRow" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))))))
(DFunDef false "headBucketRow" ((PCons (PCon "PCon" (PVar "c") (PVar "args")) (PVar "tl")) (PVar "acc")) (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (EBinOp "::" (EBinOp "++" (EVar "args") (EVar "tl")) (EApp (EApp (EVar "fromOption") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "acc"))))) (EVar "acc")))
(DFunDef false "headBucketRow" (PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "anyWildHead" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyCon "Bool")))
(DFunDef false "anyWildHead" ((PList)) (EVar "False"))
(DFunDef false "anyWildHead" ((PCons (PCons (PCon "PWild") PWild) PWild)) (EVar "True"))
(DFunDef false "anyWildHead" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyWildHead") (EVar "rest")))
(DTypeSig false "allCovered" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))) (TyCon "Bool"))))
(DFunDef false "allCovered" ((PVar "ctors") (PVar "buckets")) (EApp (EApp (EVar "allList") (ELam ((PVar "c")) (EApp (EApp (EVar "omHasKey") (EVar "c")) (EVar "buckets")))) (EVar "ctors")))
(DTypeSig false "usefulBranch" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "usefulBranch" ((PVar "oracle") (PVar "pmat") (PVar "restQ") (PVar "c")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "oGetArity") (EVar "oracle")) (EVar "c"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "None")) (EApp (EApp (EApp (EVar "specializeCon") (EVar "c")) (EVar "a")) (EVar "pmat"))) (EBinOp "++" (EApp (EApp (EVar "replicate") (EVar "a")) (EVar "PWild")) (EVar "restQ"))))))
(DTypeSig false "usefulBranchIn" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat")))) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "usefulBranchIn" ((PVar "oracle") (PVar "buckets") (PVar "restQ") (PVar "c")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "oGetArity") (EVar "oracle")) (EVar "c"))) (DoLet false false (PVar "rows") (EApp (EVar "reverseL") (EApp (EApp (EVar "fromOption") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "buckets"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "None")) (EVar "rows")) (EBinOp "++" (EApp (EApp (EVar "replicate") (EVar "a")) (EVar "PWild")) (EVar "restQ"))))))
(DTypeSig true "patUnreachable" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Pat") (TyCon "Bool"))))))
(DFunDef false "patUnreachable" ((PVar "oracle") (PVar "col0") (PVar "precMatrix") (PVar "qpat")) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EVar "col0")) (EVar "precMatrix")) (EListLit (EVar "qpat")))))
(DTypeSig true "patHasRange" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patHasRange" ((PCon "PRng" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patHasRange" ((PCon "PCon" PWild (PVar "args"))) (EApp (EApp (EVar "anyList") (EVar "patHasRange")) (EVar "args")))
(DFunDef false "patHasRange" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "||" (EApp (EVar "patHasRange") (EVar "h")) (EApp (EVar "patHasRange") (EVar "t"))))
(DFunDef false "patHasRange" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EVar "patHasRange")) (EVar "ps")))
(DFunDef false "patHasRange" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EVar "patHasRange")) (EVar "ps")))
(DFunDef false "patHasRange" ((PCon "PAs" PWild (PVar "p"))) (EApp (EVar "patHasRange") (EVar "p")))
(DFunDef false "patHasRange" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "anyList") (EVar "recFieldHasRange")) (EVar "fields")))
(DFunDef false "patHasRange" (PWild) (EVar "False"))
(DTypeSig false "recFieldHasRange" (TyFun (TyCon "RecPatField") (TyCon "Bool")))
(DFunDef false "recFieldHasRange" ((PCon "RecPatField" PWild (PCon "None"))) (EVar "False"))
(DFunDef false "recFieldHasRange" ((PCon "RecPatField" PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patHasRange") (EVar "p")))
(DTypeSig true "usefulWitness" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))))))))
(DFunDef false "usefulWitness" (PWild PWild (PList) (PVar "ncols")) (EApp (EVar "Some") (EApp (EApp (EVar "replicate") (EVar "ncols")) (EVar "PWild"))))
(DFunDef false "usefulWitness" (PWild PWild (PCons PWild PWild) (PLit (LInt 0))) (EVar "None"))
(DFunDef false "usefulWitness" ((PVar "oracle") (PVar "col0") (PVar "pmat") (PVar "ncols")) (EBlock (DoLet false false (PVar "col0t") (EApp (EApp (EVar "orElseOpt") (EVar "col0")) (EApp (EApp (EVar "inferCol0Type") (EVar "oracle")) (EVar "pmat")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "witnessWild") (EVar "oracle")) (EApp (EApp (EVar "bindCtors") (EVar "oracle")) (EVar "col0t"))) (EVar "pmat")) (EVar "ncols")))))
(DTypeSig false "witnessWild" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))))))))
(DFunDef false "witnessWild" ((PVar "oracle") (PCon "None") (PVar "pmat") (PVar "ncols")) (EApp (EApp (EVar "witnessPrepend") (EVar "PWild")) (EApp (EApp (EApp (EApp (EVar "usefulWitness") (EVar "oracle")) (EVar "None")) (EApp (EVar "defaultMatrix") (EVar "pmat"))) (EBinOp "-" (EVar "ncols") (ELit (LInt 1))))))
(DFunDef false "witnessWild" ((PVar "oracle") (PCon "Some" (PVar "ctors")) (PVar "pmat") (PVar "ncols")) (EApp (EApp (EApp (EApp (EVar "witnessSig") (EVar "oracle")) (EVar "ctors")) (EVar "pmat")) (EVar "ncols")))
(DTypeSig false "witnessSig" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))))))))
(DFunDef false "witnessSig" ((PVar "oracle") (PVar "ctors") (PVar "pmat") (PVar "ncols")) (EIf (EApp (EApp (EVar "allCovered") (EVar "ctors")) (EApp (EApp (EVar "headBuckets") (EVar "pmat")) (EVar "omEmpty"))) (EApp (EApp (EApp (EApp (EVar "firstWitnessBranch") (EVar "oracle")) (EVar "ctors")) (EVar "pmat")) (EVar "ncols")) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EApp (EApp (EApp (EVar "missingCtorPat") (EVar "oracle")) (EVar "ctors")) (EApp (EVar "headCtors") (EVar "pmat"))) (EVar "_s")))) (EApp (EApp (EApp (EApp (EVar "usefulWitness") (EVar "oracle")) (EVar "None")) (EApp (EVar "defaultMatrix") (EVar "pmat"))) (EBinOp "-" (EVar "ncols") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "firstWitnessBranch" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))))))))
(DFunDef false "firstWitnessBranch" (PWild (PList) PWild PWild) (EVar "None"))
(DFunDef false "firstWitnessBranch" ((PVar "oracle") (PCons (PVar "c") (PVar "cs")) (PVar "pmat") (PVar "ncols")) (EMatch (EApp (EApp (EApp (EApp (EVar "witnessBranch") (EVar "oracle")) (EVar "c")) (EVar "pmat")) (EVar "ncols")) (arm (PCon "Some" (PVar "w")) () (EApp (EVar "Some") (EVar "w"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "firstWitnessBranch") (EVar "oracle")) (EVar "cs")) (EVar "pmat")) (EVar "ncols")))))
(DTypeSig false "witnessBranch" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))))))))
(DFunDef false "witnessBranch" ((PVar "oracle") (PVar "c") (PVar "pmat") (PVar "ncols")) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "oGetArity") (EVar "oracle")) (EVar "c"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "ws")) (EBinOp "::" (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EVar "take") (EVar "a")) (EVar "ws"))) (EApp (EApp (EVar "drop") (EVar "a")) (EVar "ws"))))) (EApp (EApp (EApp (EApp (EVar "usefulWitness") (EVar "oracle")) (EVar "None")) (EApp (EApp (EApp (EVar "specializeCon") (EVar "c")) (EVar "a")) (EVar "pmat"))) (EBinOp "-" (EBinOp "+" (EVar "a") (EVar "ncols")) (ELit (LInt 1))))))))
(DTypeSig false "witnessPrepend" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Pat"))))))
(DFunDef false "witnessPrepend" (PWild (PCon "None")) (EVar "None"))
(DFunDef false "witnessPrepend" ((PVar "p") (PCon "Some" (PVar "ws"))) (EApp (EVar "Some") (EBinOp "::" (EVar "p") (EVar "ws"))))
(DTypeSig false "missingCtorPat" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Pat")))))
(DFunDef false "missingCtorPat" ((PVar "oracle") (PVar "ctors") (PVar "present")) (EMatch (EApp (EApp (EVar "firstMissing") (EVar "ctors")) (EVar "present")) (arm (PCon "None") () (EVar "PWild")) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EVar "replicate") (EApp (EApp (EVar "oGetArity") (EVar "oracle")) (EVar "c"))) (EVar "PWild"))))))
(DTypeSig false "firstMissing" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "firstMissing" ((PList) PWild) (EVar "None"))
(DFunDef false "firstMissing" ((PCons (PVar "c") (PVar "cs")) (PVar "present")) (EIf (EApp (EApp (EVar "contains") (EVar "c")) (EVar "present")) (EApp (EApp (EVar "firstMissing") (EVar "cs")) (EVar "present")) (EApp (EVar "Some") (EVar "c"))))
(DTypeSig true "renderWitness" (TyFun (TyCon "Pat") (TyCon "String")))
(DFunDef false "renderWitness" ((PVar "p")) (EApp (EApp (EVar "renderWit") (EVar "False")) (EVar "p")))
(DTypeSig false "renderWit" (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyCon "String"))))
(DFunDef false "renderWit" ((PVar "paren") (PCon "PCon" (PVar "c") (PVar "args"))) (EApp (EApp (EApp (EVar "renderConWit") (EVar "paren")) (EVar "c")) (EVar "args")))
(DFunDef false "renderWit" (PWild PWild) (ELit (LString "_")))
(DTypeSig false "renderConWit" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "String")))))
(DFunDef false "renderConWit" ((PVar "paren") (PVar "c") (PVar "args")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "Nil"))) (ELit (LString "[]")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "Cons"))) (EApp (EApp (EVar "renderCons") (EVar "paren")) (EVar "args")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "Unit"))) (ELit (LString "()")) (EMatch (EApp (EVar "tupleArityOfName") (EVar "c")) (arm (PCon "Some" PWild) () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renderWit") (EVar "False"))) (EVar "args"))))) (ELit (LString ")")))) (arm PWild () (EIf (EApp (EVar "isEmptyArgs") (EVar "args")) (EVar "c") (EIf (EVar "otherwise") (EApp (EApp (EVar "parenWrapWit") (EVar "paren")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "c"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renderWit") (EVar "True"))) (EVar "args"))))) (ELit (LString "")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "renderCons" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "String"))))
(DFunDef false "renderCons" ((PVar "paren") (PCons (PVar "h") (PCons (PVar "t") PWild))) (EApp (EApp (EVar "parenWrapWit") (EVar "paren")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "renderWit") (EVar "True")) (EVar "h")))) (ELit (LString " :: "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "renderWit") (EVar "False")) (EVar "t")))) (ELit (LString "")))))
(DFunDef false "renderCons" (PWild PWild) (ELit (LString "_ :: _")))
(DTypeSig false "isEmptyArgs" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool")))
(DFunDef false "isEmptyArgs" ((PList)) (EVar "True"))
(DFunDef false "isEmptyArgs" ((PCons PWild PWild)) (EVar "False"))
(DTypeSig false "parenWrapWit" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "parenWrapWit" ((PCon "True") (PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString ")"))))
(DFunDef false "parenWrapWit" ((PCon "False") (PVar "s")) (EVar "s"))
(DTypeSig false "isIrrefutablePat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isIrrefutablePat" ((PCon "PVar" PWild)) (EVar "True"))
(DFunDef false "isIrrefutablePat" ((PCon "PWild")) (EVar "True"))
(DFunDef false "isIrrefutablePat" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EVar "isIrrefutablePat")) (EVar "ps")))
(DFunDef false "isIrrefutablePat" ((PCon "PAs" PWild (PVar "p"))) (EApp (EVar "isIrrefutablePat") (EVar "p")))
(DFunDef false "isIrrefutablePat" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "allList") (EVar "recFieldIrrefutable")) (EVar "fields")))
(DFunDef false "isIrrefutablePat" (PWild) (EVar "False"))
(DTypeSig false "recFieldIrrefutable" (TyFun (TyCon "RecPatField") (TyCon "Bool")))
(DFunDef false "recFieldIrrefutable" ((PCon "RecPatField" PWild (PCon "None"))) (EVar "True"))
(DFunDef false "recFieldIrrefutable" ((PCon "RecPatField" PWild (PCon "Some" (PVar "p")))) (EApp (EVar "isIrrefutablePat") (EVar "p")))
(DTypeSig false "boolAlwaysTrue" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "boolAlwaysTrue" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "boolAlwaysTrue") (EVar "e")))
(DFunDef false "boolAlwaysTrue" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "boolAlwaysTrue") (EVar "e")))
(DFunDef false "boolAlwaysTrue" ((PCon "EVar" (PLit (LString "otherwise")))) (EVar "True"))
(DFunDef false "boolAlwaysTrue" ((PCon "EVar" (PLit (LString "True")))) (EVar "True"))
(DFunDef false "boolAlwaysTrue" ((PCon "ELit" (PCon "LBool" (PCon "True")))) (EVar "True"))
(DFunDef false "boolAlwaysTrue" (PWild) (EVar "False"))
(DTypeSig false "guardAlwaysFires" (TyFun (TyCon "Guard") (TyCon "Bool")))
(DFunDef false "guardAlwaysFires" ((PCon "GBool" (PVar "e"))) (EApp (EVar "boolAlwaysTrue") (EVar "e")))
(DFunDef false "guardAlwaysFires" ((PCon "GBind" (PVar "p") PWild)) (EApp (EVar "isIrrefutablePat") (EVar "p")))
(DTypeSig false "guardsDecidablyExhaustive" (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Bool")))
(DFunDef false "guardsDecidablyExhaustive" ((PVar "gs")) (EApp (EApp (EVar "allList") (EVar "guardAlwaysFires")) (EVar "gs")))
(DTypeSig false "guardArmsTotal" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyCon "Bool")))
(DFunDef false "guardArmsTotal" ((PVar "arms")) (EApp (EApp (EVar "anyList") (EVar "guardArmTotal")) (EVar "arms")))
(DTypeSig false "guardArmTotal" (TyFun (TyCon "GuardArm") (TyCon "Bool")))
(DFunDef false "guardArmTotal" ((PCon "GuardArm" (PVar "gs") PWild)) (EApp (EVar "guardsDecidablyExhaustive") (EVar "gs")))
(DTypeSig false "clauseGuardsTotal" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyCon "Bool")))
(DFunDef false "clauseGuardsTotal" ((PTuple PWild (PCon "EGuards" (PVar "arms")))) (EApp (EVar "guardArmsTotal") (EVar "arms")))
(DFunDef false "clauseGuardsTotal" (PWild) (EVar "True"))
(DTypeSig false "clauseIsGuardedPartial" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyCon "Bool")))
(DFunDef false "clauseIsGuardedPartial" ((PTuple PWild (PCon "EGuards" (PVar "arms")))) (EApp (EVar "not") (EApp (EVar "guardArmsTotal") (EVar "arms"))))
(DFunDef false "clauseIsGuardedPartial" (PWild) (EVar "False"))
(DTypeSig false "clausePats" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "clausePats" ((PTuple (PVar "pats") PWild)) (EVar "pats"))
(DTypeSig false "guardWarning" (TyCon "String"))
(DFunDef false "guardWarning" () (ELit (LString "Warning: guards may not be exhaustive")))
(DTypeSig false "checkGroup" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))))
(DFunDef false "checkGroup" ((PVar "oracle") (PVar "name") (PVar "clauses")) (EIf (EApp (EApp (EVar "anyList") (EVar "clauseIsGuardedPartial")) (EVar "clauses")) (EApp (EApp (EVar "checkGroupCovered") (EVar "oracle")) (EVar "clauses")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "checkGroupClauses") (EVar "oracle")) (EVar "name")) (EVar "clauses")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "checkGroupCovered" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "checkGroupCovered" ((PVar "oracle") (PVar "clauses")) (EBlock (DoLet false false (PVar "arity") (EApp (EVar "groupArity") (EVar "clauses"))) (DoLet false false (PVar "rows") (EApp (EApp (EVar "totalClauseRows") (EVar "oracle")) (EVar "clauses"))) (DoLet false false (PVar "query") (EListLit (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EApp (EVar "PTuple") (EApp (EApp (EVar "replicate") (EVar "arity")) (EVar "PWild")))))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EApp (EVar "Some") (EApp (EVar "tupleCtorName") (EVar "arity")))) (EVar "rows")) (EVar "query")) (EListLit (ETuple (EVar "guardWarning") (EApp (EVar "groupLoc") (EVar "clauses")))) (EListLit)))))
(DTypeSig false "checkGroupClauses" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))))
(DFunDef false "checkGroupClauses" ((PVar "oracle") (PVar "name") (PVar "clauses")) (EBlock (DoLet false false (PVar "arity") (EApp (EVar "groupArity") (EVar "clauses"))) (DoLet false false (PVar "rows") (EApp (EApp (EVar "totalClauseRows") (EVar "oracle")) (EVar "clauses"))) (DoLet false false (PVar "query") (EListLit (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EApp (EVar "PTuple") (EApp (EApp (EVar "replicate") (EVar "arity")) (EVar "PWild")))))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EVar "useful") (EVar "oracle")) (EApp (EVar "Some") (EApp (EVar "tupleCtorName") (EVar "arity")))) (EVar "rows")) (EVar "query")) (EListLit (ETuple (EApp (EApp (EApp (EApp (EVar "nonExhaustiveClausesMsg") (EVar "oracle")) (EVar "name")) (EVar "arity")) (EVar "rows")) (EApp (EVar "groupLoc") (EVar "clauses")))) (EListLit)))))
(DTypeSig false "nonExhaustiveClausesMsg" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))) (TyCon "String"))))))
(DFunDef false "nonExhaustiveClausesMsg" ((PVar "oracle") (PVar "name") (PVar "arity") (PVar "rows")) (EMatch (EApp (EApp (EApp (EApp (EVar "usefulWitness") (EVar "oracle")) (EApp (EVar "Some") (EApp (EVar "tupleCtorName") (EVar "arity")))) (EVar "rows")) (ELit (LInt 1))) (arm (PCon "Some" (PCons (PVar "w") PWild)) () (EBlock (DoLet false false (PVar "witnessStr") (EApp (EApp (EVar "renderClauseWitness") (EVar "arity")) (EVar "w"))) (DoLet false false (PVar "hint") (EBinOp "++" (EBinOp "++" (ELit (LString "add a '")) (EApp (EMethodRef "display") (EVar "witnessStr"))) (ELit (LString "' clause, or a '_' catch-all clause.")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Warning: non-exhaustive clauses of '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "'. Missing case: '"))) (EApp (EMethodRef "display") (EVar "witnessStr"))) (ELit (LString "'; "))) (EApp (EMethodRef "display") (EVar "hint"))) (ELit (LString "")))))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "Warning: non-exhaustive clauses of '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "'. Not all cases are covered"))))))
(DTypeSig false "renderClauseWitness" (TyFun (TyCon "Int") (TyFun (TyCon "Pat") (TyCon "String"))))
(DFunDef false "renderClauseWitness" ((PLit (LInt 1)) (PCon "PCon" PWild (PCons (PVar "inner") PWild))) (EApp (EVar "renderWitness") (EVar "inner")))
(DFunDef false "renderClauseWitness" (PWild (PVar "w")) (EApp (EVar "renderWitness") (EVar "w")))
(DTypeSig false "groupLoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "groupLoc" ((PList)) (EVar "None"))
(DFunDef false "groupLoc" ((PCons (PTuple PWild (PVar "body")) PWild)) (EApp (EVar "clauseBodyLoc") (EVar "body")))
(DTypeSig false "clauseBodyLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "clauseBodyLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "clauseBodyLoc" ((PCon "EDoOrigin" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "clauseBodyLoc" (PWild) (EVar "None"))
(DTypeSig false "groupArity" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyCon "Int")))
(DFunDef false "groupArity" ((PList)) (ELit (LInt 0)))
(DFunDef false "groupArity" ((PCons (PVar "c") PWild)) (EApp (EVar "listLen") (EApp (EVar "clausePats") (EVar "c"))))
(DTypeSig false "totalClauseRows" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Pat"))))))
(DFunDef false "totalClauseRows" (PWild (PList)) (EListLit))
(DFunDef false "totalClauseRows" ((PVar "oracle") (PCons (PVar "c") (PVar "rest"))) (EIf (EApp (EVar "clauseGuardsTotal") (EVar "c")) (EBinOp "::" (EListLit (EApp (EApp (EVar "desugarPat") (EVar "oracle")) (EApp (EVar "PTuple") (EApp (EVar "clausePats") (EVar "c"))))) (EApp (EApp (EVar "totalClauseRows") (EVar "oracle")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "totalClauseRows") (EVar "oracle")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "groupByName" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "groupByName" ((PVar "items")) (EBlock (DoLet false false (PVar "buckets") (EApp (EApp (EVar "bucketClauses") (EVar "items")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EVar "reverseL") (EApp (EApp (EVar "bucketFor") (EVar "n")) (EVar "buckets")))))) (EApp (EApp (EVar "firstSeenNames") (EVar "items")) (EVar "omEmpty"))))))
(DTypeAlias false "ClauseBuckets" () (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DTypeSig false "bucketClauses" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "ClauseBuckets") (TyCon "ClauseBuckets"))))
(DFunDef false "bucketClauses" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "bucketClauses" ((PCons (PTuple (PVar "n") (PVar "c")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "bucketClauses") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "::" (EVar "c") (EApp (EApp (EVar "bucketFor") (EVar "n")) (EVar "acc")))) (EVar "acc"))))
(DTypeSig false "bucketFor" (TyFun (TyCon "String") (TyFun (TyCon "ClauseBuckets") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "bucketFor" ((PVar "n") (PVar "acc")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "acc")) (arm (PCon "Some" (PVar "cs")) () (EVar "cs")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "firstSeenNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "firstSeenNames" ((PList) PWild) (EListLit))
(DFunDef false "firstSeenNames" ((PCons (PTuple (PVar "n") PWild) (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "seen")) (EApp (EApp (EVar "firstSeenNames") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "n") (EApp (EApp (EVar "firstSeenNames") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "letGroupWarnings" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "letGroupWarnings" ((PVar "oracle") (PVar "body")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkLetBind") (EVar "oracle"))) (EApp (EVar "collectLetBinds") (EVar "body"))))
(DTypeSig false "checkLetBind" (TyFun (TyCon "Oracle") (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "checkLetBind" ((PVar "oracle") (PCon "LetBind" (PVar "name") (PVar "funclauses"))) (EApp (EApp (EApp (EVar "checkGroup") (EVar "oracle")) (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "funClauseToClause")) (EVar "funclauses"))))
(DTypeSig false "funClauseToClause" (TyFun (TyCon "FunClause") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))
(DFunDef false "funClauseToClause" ((PCon "FunClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "pats") (EVar "body")))
(DTypeSig false "collectLetBinds" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "collectLetBinds" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EBinOp "++" (EVar "binds") (EApp (EApp (EDictApp "flatMap") (EVar "collectLetBindInner")) (EVar "binds"))) (EApp (EVar "collectLetBinds") (EVar "body"))))
(DFunDef false "collectLetBinds" ((PCon "EApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "a")) (EApp (EVar "collectLetBinds") (EVar "b"))))
(DFunDef false "collectLetBinds" ((PCon "ELam" PWild (PVar "b"))) (EApp (EVar "collectLetBinds") (EVar "b")))
(DFunDef false "collectLetBinds" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "e1")) (EApp (EVar "collectLetBinds") (EVar "e2"))))
(DFunDef false "collectLetBinds" ((PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EVar "collectArmBinds")) (EVar "arms"))))
(DFunDef false "collectLetBinds" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "c")) (EApp (EVar "collectLetBinds") (EVar "t"))) (EApp (EVar "collectLetBinds") (EVar "el"))))
(DFunDef false "collectLetBinds" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "a")) (EApp (EVar "collectLetBinds") (EVar "b"))))
(DFunDef false "collectLetBinds" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EVar "collectLetBinds") (EVar "a")))
(DFunDef false "collectLetBinds" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "a")) (EApp (EVar "collectLetBinds") (EVar "b"))))
(DFunDef false "collectLetBinds" ((PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EVar "collectLetBinds") (EVar "e0")))
(DFunDef false "collectLetBinds" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EDictApp "flatMap") (EVar "fieldAssignBinds")) (EVar "fs")))
(DFunDef false "collectLetBinds" ((PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild)) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EVar "fieldAssignBinds")) (EVar "fs"))))
(DFunDef false "collectLetBinds" ((PCon "EVariantUpdate" PWild (PVar "e0") (PVar "fs"))) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EVar "fieldAssignBinds")) (EVar "fs"))))
(DFunDef false "collectLetBinds" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "collectLetBinds")) (EVar "es")))
(DFunDef false "collectLetBinds" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "collectLetBinds")) (EVar "es")))
(DFunDef false "collectLetBinds" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EVar "collectLetBinds")) (EVar "es")))
(DFunDef false "collectLetBinds" ((PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "e0")) (EApp (EVar "collectLetBinds") (EVar "i"))))
(DFunDef false "collectLetBinds" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "lo")) (EApp (EVar "collectLetBinds") (EVar "hi"))))
(DFunDef false "collectLetBinds" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "lo")) (EApp (EVar "collectLetBinds") (EVar "hi"))))
(DFunDef false "collectLetBinds" ((PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectLetBinds") (EVar "e0")) (EApp (EVar "collectLetBinds") (EVar "lo"))) (EApp (EVar "collectLetBinds") (EVar "hi"))))
(DFunDef false "collectLetBinds" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "doStmtBinds")) (EVar "stmts")))
(DFunDef false "collectLetBinds" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "doStmtBinds")) (EVar "stmts")))
(DFunDef false "collectLetBinds" ((PCon "EAnnot" (PVar "e0") PWild)) (EApp (EVar "collectLetBinds") (EVar "e0")))
(DFunDef false "collectLetBinds" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EDictApp "flatMap") (EVar "interpBinds")) (EVar "parts")))
(DFunDef false "collectLetBinds" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EDictApp "flatMap") (EVar "guardArmBinds")) (EVar "arms")))
(DFunDef false "collectLetBinds" ((PCon "ESection" (PCon "SecRight" PWild (PVar "e0")))) (EApp (EVar "collectLetBinds") (EVar "e0")))
(DFunDef false "collectLetBinds" ((PCon "ESection" (PCon "SecLeft" (PVar "e0") PWild))) (EApp (EVar "collectLetBinds") (EVar "e0")))
(DFunDef false "collectLetBinds" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DFunDef false "collectLetBinds" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DFunDef false "collectLetBinds" (PWild) (EListLit))
(DTypeSig false "collectLetBindInner" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "collectLetBindInner" ((PCon "LetBind" PWild (PVar "funclauses"))) (EApp (EApp (EDictApp "flatMap") (EVar "funClauseBinds")) (EVar "funclauses")))
(DTypeSig false "funClauseBinds" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "funClauseBinds" ((PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "collectLetBinds") (EVar "body")))
(DTypeSig false "collectArmBinds" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "collectArmBinds" ((PCon "Arm" PWild (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "guardBinds")) (EVar "gs")) (EApp (EVar "collectLetBinds") (EVar "body"))))
(DTypeSig false "guardBinds" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "guardBinds" ((PCon "GBool" (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DFunDef false "guardBinds" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DTypeSig false "guardArmBinds" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "guardArmBinds" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "guardBinds")) (EVar "gs")) (EApp (EVar "collectLetBinds") (EVar "body"))))
(DTypeSig false "fieldAssignBinds" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "fieldAssignBinds" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DTypeSig false "doStmtBinds" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "doStmtBinds" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DFunDef false "doStmtBinds" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DFunDef false "doStmtBinds" ((PCon "DoLet" PWild PWild PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DFunDef false "doStmtBinds" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DFunDef false "doStmtBinds" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DTypeSig false "interpBinds" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "interpBinds" ((PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "interpBinds" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "collectLetBinds") (EVar "e")))
(DTypeSig true "checkGuardExhaustivenessWith" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "checkGuardExhaustivenessWith" ((PVar "oracleDecls") (PVar "checkDecls")) (EBlock (DoLet false false (PVar "oracle") (EApp (EVar "buildOracle") (EBinOp "++" (EVar "checkDecls") (EVar "oracleDecls")))) (DoExpr (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkNamedGroup") (EVar "oracle"))) (EApp (EVar "groupByName") (EApp (EVar "topFunDefClauses") (EVar "checkDecls")))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "declBodyWarnings") (EVar "oracle"))) (EVar "checkDecls"))))))
(DTypeSig false "checkNamedGroup" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "checkNamedGroup" ((PVar "oracle") (PTuple (PVar "name") (PVar "clauses"))) (EApp (EApp (EApp (EVar "checkGroup") (EVar "oracle")) (EVar "name")) (EVar "clauses")))
(DTypeSig true "checkGuardExhaustiveness" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "checkGuardExhaustiveness" ((PVar "prog")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "checkGuardExhaustivenessWith") (EVar "prog")) (EVar "prog"))))
(DTypeSig false "topFunDefClauses" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "topFunDefClauses" ((PList)) (EListLit))
(DFunDef false "topFunDefClauses" ((PCons (PCon "DFunDef" PWild (PVar "n") (PVar "pats") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (ETuple (EVar "pats") (EVar "body"))) (EApp (EVar "topFunDefClauses") (EVar "rest"))))
(DFunDef false "topFunDefClauses" ((PCons PWild (PVar "rest"))) (EApp (EVar "topFunDefClauses") (EVar "rest")))
(DTypeSig false "declBodyWarnings" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "declBodyWarnings" ((PVar "oracle") (PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EApp (EVar "letGroupWarnings") (EVar "oracle")) (EVar "body")))
(DFunDef false "declBodyWarnings" ((PVar "oracle") (PRec "DImpl" ((rf "methods" None)) true)) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkNamedGroup") (EVar "oracle"))) (EApp (EVar "groupByName") (EApp (EVar "implClauses") (EVar "methods")))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "implMethodBodyWarnings") (EVar "oracle"))) (EVar "methods"))))
(DFunDef false "declBodyWarnings" ((PVar "oracle") (PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "ifaceMethodWarnings") (EVar "oracle"))) (EVar "methods")))
(DFunDef false "declBodyWarnings" ((PVar "oracle") (PCon "DProp" PWild PWild PWild (PVar "body"))) (EApp (EApp (EVar "letGroupWarnings") (EVar "oracle")) (EVar "body")))
(DFunDef false "declBodyWarnings" ((PVar "oracle") (PCon "DTest" PWild PWild (PVar "body"))) (EApp (EApp (EVar "letGroupWarnings") (EVar "oracle")) (EVar "body")))
(DFunDef false "declBodyWarnings" ((PVar "oracle") (PCon "DBench" PWild PWild (PVar "body"))) (EApp (EApp (EVar "letGroupWarnings") (EVar "oracle")) (EVar "body")))
(DFunDef false "declBodyWarnings" (PWild PWild) (EListLit))
(DTypeSig false "implClauses" (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "implClauses" ((PList)) (EListLit))
(DFunDef false "implClauses" ((PCons (PCon "ImplMethod" (PVar "n") (PVar "pats") (PVar "body")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (ETuple (EVar "pats") (EVar "body"))) (EApp (EVar "implClauses") (EVar "rest"))))
(DTypeSig false "implMethodBodyWarnings" (TyFun (TyCon "Oracle") (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "implMethodBodyWarnings" ((PVar "oracle") (PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EApp (EVar "letGroupWarnings") (EVar "oracle")) (EVar "body")))
(DTypeSig false "ifaceMethodWarnings" (TyFun (TyCon "Oracle") (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "ifaceMethodWarnings" (PWild (PCon "IfaceMethod" PWild PWild (PCon "None"))) (EListLit))
(DFunDef false "ifaceMethodWarnings" ((PVar "oracle") (PCon "IfaceMethod" PWild PWild (PCon "Some" (PCon "MethodDefault" PWild (PVar "body"))))) (EApp (EApp (EVar "letGroupWarnings") (EVar "oracle")) (EVar "body")))
(DTypeSig true "exhaustToLinesWith" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "exhaustToLinesWith" ((PVar "oracleDecls") (PVar "checkDecls")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "checkGuardExhaustivenessWith") (EVar "oracleDecls")) (EVar "checkDecls")))))
(DTypeSig true "exhaustToLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "exhaustToLines" ((PVar "prog")) (EApp (EApp (EVar "exhaustToLinesWith") (EVar "prog")) (EVar "prog")))
