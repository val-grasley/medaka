# META
source_lines=4636
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted Medaka parser — Stage 1 port of `lib/parser.mly`.  A monadic
-- *combinator* parser over `List Token` from the lexer: a `Parser` monad
-- (`Mappable`/`Applicative`/`Thenable` impls) with `do`-notation, and
-- combinators (`many`/`sepBy1`/`choice`/`chainl1`).  Precedence is the stratified
-- ladder from parser.mly, one function per level.  Validated by the structural
-- dump against `dev/astdump.exe` (see test/diff_compiler_parse.sh).
--
-- (Chosen over the direct recursive-descent version after Phase 136 unblocked
-- recursive polymorphic combinators and a perf comparison showed monadic
-- combinators are perf-neutral here — it dogfoods Thenable/do far more.)
--
-- COVERAGE: the arithmetic+boolean+comparison+cons+append operator ladder, `=>`
-- lambdas, single-line `if`/`let … in`, `match` with indented arms, postfix
-- field access, the full pattern hierarchy, the type grammar, and top-level
-- `DFunDef`/`DTypeSig`.  Multi-statement indented blocks, the remaining decl
-- forms, and the rest of the operator ladder come in later slices.

import frontend.ast.{
  DeriveRef(..),
  Lit(..),
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
  Loc(..),
  UseMember(..),
  UsePath(..),
  useMemberOrigin,
  useMemberAlias,
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
  Attr(..),
  Route(..),
}
import frontend.lexer.{
  Token(..),
  tokenize,
  tokenizeWithLines,
  tokenizeWithOffsets,
  tokenizeWithOffsetPairs,
  offsetToLineCol,
  lineStartsOf,
  offsetToLineColFast,
  describeToken,
}
import support.util.{reverseL, joinWith}
import support.char.{isUpper}

-- ── The Parser monad ────────────────────────────────────────────────────
-- `PErr` is a RECOVERABLE failure: `orElse` may try the other alternative and
-- `many` may treat it as "no more items".  `PFatal` is a COMMITTED failure: the
-- input is unambiguously this production and unambiguously wrong, so no
-- alternative may paper over it and no `many` may swallow it — it propagates
-- straight out to `resultDeclsResult`, which locates it like any other error.
-- Without this channel a deep, well-worded rejection (e.g. the #171 bare-2^62
-- literal) is discarded by the enclosing `many (appArg …)` and the user sees a
-- generic "unexpected INT" from the leftover-token path instead.
public export data PR a = POk a Int | PErr String Int | PFatal String Int
public export data Parser a = Parser (Array Token -> Int -> PR a)

runP : Parser a -> Array Token -> Int -> PR a
runP (Parser f) toks pos = f toks pos

mapPR : (a -> b) -> PR a -> PR b
mapPR f (POk a pos) = POk (f a) pos
mapPR _ (PErr e pos) = PErr e pos
mapPR _ (PFatal e pos) = PFatal e pos

impl Mappable Parser where
  map f pa = Parser (toks pos => mapPR f (runP pa toks pos))

apPR : Parser (a -> b) -> Parser a -> Array Token -> Int -> PR b
apPR pf pa toks pos = match runP pf toks pos
  POk f pos1 => mapPR f (runP pa toks pos1)
  PErr e pos1 => PErr e pos1
  PFatal e pos1 => PFatal e pos1

impl Applicative Parser where
  pure x = Parser (toks pos => POk x pos)
  ap pf pa = Parser (toks pos => apPR pf pa toks pos)

bindPR : Parser a -> (a -> Parser b) -> Array Token -> Int -> PR b
bindPR pa k toks pos = match runP pa toks pos
  POk a pos1 => runP (k a) toks pos1
  PErr e pos1 => PErr e pos1
  PFatal e pos1 => PFatal e pos1

impl Thenable Parser where
  andThen pa k = Parser (toks pos => bindPR pa k toks pos)

-- ── Primitives ──────────────────────────────────────────────────────────
peekTok : Array Token -> Int -> Token
peekTok toks pos
  | pos < arrayLength toks = arrayGetUnsafe pos toks
  | otherwise = TEof

failP : String -> Parser a
failP msg = Parser (toks pos => PErr msg pos)

-- A COMMITTED failure at the current token (see `PR`).  Use only where no other
-- production could possibly claim the token — the message is guaranteed to reach
-- the user, so a wrong one cannot be backtracked away.
fatalP : String -> Parser a
fatalP msg = Parser (toks pos => PFatal msg pos)

-- A COMMITTED failure reported at an EXPLICIT, previously-captured token index
-- rather than the current position — for when the offending construct starts
-- earlier than where the parser actually notices the problem (e.g. `public` on
-- a non-`data` decl: the mistake is the leading `public` token, not whatever
-- follows `public export`).  `pos0` comes from a `getPos` taken before the
-- construct was consumed; the current position is discarded (never consumes).
-- Must be `PFatal`, not `PErr`: a `PErr` reported at `pos0` (the decl's own
-- start position) is indistinguishable from "no progress" to `many`'s
-- swallow-and-retry / `deepenLeftover` recovery (`pos2 > pos` fails when
-- pos2 == the decl start), which discards the message for a generic
-- "unexpected `public`" instead.  `PFatal` bypasses that recovery machinery
-- entirely (`manyGo`'s `PFatal e q => PFatal e q` propagates straight out),
-- so it is only safe where — as here — no alternative production could ever
-- have claimed this token (see `fatalP` above).
fatalAtP : String -> Int -> Parser a
fatalAtP msg pos0 = Parser (toks _pos => PFatal msg pos0)

peekP : Parser Token
peekP = Parser (toks pos => POk (peekTok toks pos) pos)

-- Peek the token ONE PAST the current (lookahead-2) without consuming.  Used by
-- the WS-4 product effect-param clause to disambiguate a product axis (`Host=`)
-- from a comma-separated next atom: a `TUpper` immediately FOLLOWED by `TEqual`
-- starts a product axis.  Pure read of `pos + 1` (no advance).
peek2P : Parser Token
peek2P = Parser (toks pos => POk (peekTok toks (pos + 1)) pos)

-- Read the current token index without consuming.  Used by the position
-- side-channel (`parseWithPositions`) to capture per-decl / per-variant token
-- spans; does not affect parsing (it's a pure read of `pos`).
getPos : Parser Int
getPos = Parser (toks pos => POk pos pos)

-- ── Source-location capture (Phase B.10.2) ──────────────────────────────────
-- The `located` combinator wraps an expr production in a transparent `ELoc`,
-- mirroring parser.mly's `ELoc (of_pos $startpos $endpos, …)`.  parser.mly gets
-- line/col from Menhir's positions; here we recover them out of band from the
-- token→char-offset array (`tokenizeWithOffsets`) + the source chars, the same
-- machinery the structured parse-error path (`mkLocated`) already uses.  Both
-- are stashed in module refs by the parse entry points before parsing; the
-- Parser monad itself is untouched (its token stream stays byte-identical).
-- When unset (a caller that didn't populate them, e.g. a bare `runP`), `located`
-- falls back to a zero loc — still transparent, just position-less.
locSrcRef : Ref String
locSrcRef = Ref ""

locOffsRef : Ref (Array (Int, Int))
locOffsRef = Ref (arrayFromList [])

-- Precomputed sorted line-start char offsets for `locSrcRef`'s source, so
-- `locOfSpan` resolves each offset in O(log N) via binary search instead of
-- re-walking the whole source from 0 (which made the located-parse pass O(N²)).
locLineStartsRef : Ref (Array Int)
locLineStartsRef = Ref (arrayFromList [0])

setLocState : String -> Array (Int, Int) -> Unit
setLocState src offs =
  let _ = setRef locSrcRef src
  let _ = setRef locLineStartsRef (lineStartsOf src)
  setRef locOffsRef offs

-- start char offset of token `i` (0 when out of range / unset).
tokOffsetAt : Int -> Int
tokOffsetAt i =
  let offs = locOffsRef.value
  if i >= 0 && i < arrayLength offs then fst (arrayGetUnsafe i offs) else 0

-- end char offset of token `i` — one past its last character (0 when out of range / unset).
tokEndOffsetAt : Int -> Int
tokEndOffsetAt i =
  let offs = locOffsRef.value
  if i >= 0 && i < arrayLength offs then snd (arrayGetUnsafe i offs) else 0

-- Build a `Loc` from a [start, end) token-index span.  start → the span's first
-- token's START offset; end → the last consumed token's END offset (one past its
-- last character), matching Menhir's `$endpos`.  Both start and end offsets are
-- now exact: `tokenizeWithOffsetPairs` threads the lexer-computed end (the next
-- scan position after each token) through the layout pass.  For a single-token
-- expr (`"x"`) start_col < end_col = start_col + token_length, matching the
-- OCaml LSP's range exactly.  `file` is left "" for the caller to fill.
locOfSpan : Int -> Int -> Loc
locOfSpan startIdx endIdx =
  let lineStarts = locLineStartsRef.value
  let lastIdx = if endIdx > startIdx then endIdx - 1 else startIdx
  match offsetToLineColFast lineStarts (tokOffsetAt startIdx)
    (sl, sc) => match offsetToLineColFast lineStarts (tokEndOffsetAt lastIdx)
      (el, ec) => Loc "" sl sc el ec

-- Wrap an expr production in a transparent ELoc capturing its token span.
located : Parser Expr -> Parser Expr
located p = do
  s <- getPos
  e <- p
  q <- getPos
  pure (ELoc (locOfSpan s q) e)

advance : Parser Token
advance = Parser (toks pos => advanceR (peekTok toks pos) pos)

advanceR : Token -> Int -> PR Token
advanceR TEof pos = PErr "unexpected end of input" pos
advanceR t pos = POk t (pos + 1)

-- consume one token, yield the given value
emit : a -> Parser a
emit x = do
  advance
  pure x

expectTok : Token -> Parser Unit
expectTok t = do
  x <- peekP
  expectGo t x

expectGo : Token -> Token -> Parser Unit
expectGo t x =
  if x == t then
    emit ()
  else
    failP "unexpected \{describeToken x}; expected \{describeToken t}"

identNameP : Parser String
identNameP = do
  t <- peekP
  identNameFor t

identNameFor : Token -> Parser String
identNameFor (TIdent x) = emit x
identNameFor _ = failP "expected identifier"

-- ── Combinators ─────────────────────────────────────────────────────────
orElse : Parser a -> Parser a -> Parser a
orElse pa pb = Parser (toks pos => orElseR pa pb toks pos)

-- On a double failure, keep the FURTHEST-reached error (larger token index)
-- rather than always the second alternative's.  This is the classic
-- recursive-descent furthest-failure heuristic: the alternative that consumed
-- more input before failing is almost always the intended parse, so its error
-- (the offending token deep in the body) is the useful one to surface — instead
-- of the shallow re-report at the construct's head.  Ties prefer `pb` (the prior
-- behaviour).  Success of either branch is returned unchanged, so parse results
-- are byte-identical; only which message a doomed parse carries changes.
orElseR : Parser a -> Parser a -> Array Token -> Int -> PR a
orElseR pa pb toks pos = match runP pa toks pos
  POk x q => POk x q
  PFatal ea qa => PFatal ea qa
  PErr ea qa => orElseRb ea qa (runP pb toks pos)

orElseRb : String -> Int -> PR a -> PR a
orElseRb _ _ (POk y q) = POk y q
orElseRb _ _ (PFatal eb qb) = PFatal eb qb
orElseRb ea qa (PErr eb qb)
  | qa > qb = PErr ea qa
  | otherwise = PErr eb qb

choice : List (Parser a) -> Parser a
choice [] = failP "no alternative"
choice (p::ps) = orElse p (choice ps)

-- zero or more; primitive + progress-guarded so it can never loop
many : Parser a -> Parser (List a)
many p = Parser (toks pos => manyGo p toks pos [])

manyGo : Parser a -> Array Token -> Int -> List a -> PR (List a)
manyGo p toks pos acc = match runP p toks pos
  POk x pos2 => manyStep p toks pos pos2 acc x
  PFatal e q => PFatal e q
  PErr _ _ => POk (reverseL acc) pos

manyStep : Parser a -> Array Token -> Int -> Int -> List a -> a -> PR (List a)
manyStep p toks pos pos2 acc x
  | pos2 > pos = manyGo p toks pos2 (x::acc)
  | otherwise = POk (reverseL (x::acc)) pos2

sepThen : Parser b -> Parser a -> Parser a
sepThen sep p = do
  sep
  p

sepBy1 : Parser a -> Parser b -> Parser (List a)
sepBy1 p sep = do
  x <- p
  xs <- many (sepThen sep p)
  pure (x::xs)

-- Consume an OPTIONAL trailing comma that `sepBy1` left positioned at (a
-- trailing comma backtracks the failed element parse, leaving the parser AT the
-- comma).  Additive: a non-comma token is left untouched, so existing
-- (comma-free) input parses identically.  Insert between `sepBy1` and the
-- closing-delimiter `expectTok` to accept the trailing-comma-on-break form the
-- formatter emits.
optTrailingComma : Parser Unit
optTrailingComma = do
  t <- peekP
  optTrailingCommaFor t

optTrailingCommaFor : Token -> Parser Unit
optTrailingCommaFor TComma = do
  advance
  pure ()
optTrailingCommaFor _ = pure ()

-- Like `optTrailingComma`, but a no-op for a single-element paren group — a
-- trailing comma after one element (`(x,)`) is NOT accepted, so `(x)` keeps its
-- "parenthesized x" meaning (no 1-tuple ambiguity).
optTrailingCommaTuple : List a -> Parser Unit
optTrailingCommaTuple [_] = pure ()
optTrailingCommaTuple _ = optTrailingComma

-- Structurally identical to stdlib/byteparser.mdk's chainl1, but over a
-- different parser type (token Parser vs ByteParser) with no shared Monad
-- typeclass to hang a single generic version off of — not soundly shareable.
chainl1 : Parser a -> Parser (a -> a -> a) -> Parser a
-- lint-disable-next-line rule-duplicate-body
chainl1 p op = do
  x <- p
  chainl1Rest p op x

chainl1Rest : Parser a -> Parser (a -> a -> a) -> a -> Parser a
chainl1Rest p op x = orElse (chainl1More p op x) (pure x)

chainl1More : Parser a -> Parser (a -> a -> a) -> a -> Parser a
chainl1More p op x = do
  f <- op
  y <- p
  chainl1Rest p op (f x y)

-- NB: recurse through a do-continuation (lazy), not by passing `skipNewlines`
-- as a strict argument — the latter forces the value while it's being defined
-- (a recursive-value init cycle → CamlinternalLazy.Undefined under strict eval).
skipNewlines : Parser Unit
skipNewlines = do
  t <- peekP
  skipNlFor t

skipNlFor : Token -> Parser Unit
skipNlFor TNewline = do
  advance
  skipNewlines
skipNlFor _ = pure ()

-- ── Expressions ─────────────────────────────────────────────────────────
-- ladder: lam → or → and → cmp → cons → append → add → mul → app → postfix → atom
parseExpr : Parser Expr
parseExpr = do
  e <- parseAssign
  orElse (annotTail e) (pure e)

-- `:=` reference assignment (mutation). Looser than lambda so the RHS may be a
-- full lambda (`r := x => x`), right-associative (`a := b := c` ⇒ `a := (b := c)`)
-- like OCaml. Desugars to `setRef lhs rhs` in `desugar.mdk` (an `EBinOp ":="` node
-- survives resolve/typecheck only up to that lowering).
parseAssign : Parser Expr
parseAssign = do
  e <- parseLam
  orElse (assignTail e) (pure e)

assignTail : Expr -> Parser Expr
assignTail lhs = located (assignTailRaw lhs)

assignTailRaw : Expr -> Parser Expr
assignTailRaw lhs = do
  expectTok TColonEq
  rhs <- parseAssign
  pure (EBinOp ":=" lhs rhs (Ref RNone))

-- expression type annotation `e : ty` (loosest level)
annotTail : Expr -> Parser Expr
annotTail e = do
  expectTok TColon
  t <- parseTy
  pure (EAnnot e t)

parseLam : Parser Expr
parseLam = do
  e <- parsePipe
  orElse (lamTail e) (pure e)

-- `|>` pipe (loosest operator), then `>>`/`<<` composition, then `||`…
parsePipe : Parser Expr
parsePipe = chainl1 parseCompose (binOp TPipeRight "|>")

parseCompose : Parser Expr
parseCompose =
  chainl1 parseOr (choice [binOp TRCompose ">>", binOp TLCompose "<<"])

lamTail : Expr -> Parser Expr
lamTail e = located (lamTailRaw e)

-- The body reads via `parseRhsExpr`, not a bare `parseExpr`: `=>` is a layout
-- herald (LAYOUT-SEMANTICS.md §7.1) — it is absent from the lexer's
-- `canEndExpr`, so `g x =>⏎  body` opens a bare-INDENT block, and a bare
-- `parseExpr` has no TIndent case to read it.  Same production the decl body
-- (`parseBody`) and a let/where RHS (`parseRhsExpr`) already use.
lamTailRaw : Expr -> Parser Expr
lamTailRaw e = do
  expectTok TFatArrow
  body <- parseRhsExpr
  pure (ELam (exprToParams e) body)

-- convert a lambda LHS expression to a parameter-pattern list (mirrors the
-- reference `expr_to_pats`): an EApp spine with a lowercase head is a multi-arg
-- lambda (one pattern per spine element); an uppercase head is a single
-- constructor pattern; anything else is a single pattern.
exprToParams : Expr -> List Pat
exprToParams (ELoc _ e) = exprToParams e
exprToParams (EApp f x) = appToParams (EApp f x)
exprToParams e = [exprToPat e]

appToParams : Expr -> List Pat
appToParams app = paramsForHead (spineHead app) app

paramsForHead : Expr -> Expr -> List Pat
paramsForHead (EVar c) app = paramsForCtor c app
paramsForHead _ app = map exprToPat (spineList app)

paramsForCtor : String -> Expr -> List Pat
paramsForCtor c app
  | isCtorName c = [exprToPat app]
  | otherwise = map exprToPat (spineList app)

-- head of an EApp spine.  App nodes are un-wrapped (the app level builds bare
-- EApp), but the leaf head is ELoc-wrapped — strip it so callers can match the
-- raw `EVar`/etc. shape.
spineHead : Expr -> Expr
spineHead (EApp f _) = spineHead f
spineHead (ELoc _ e) = spineHead e
spineHead e = e

-- flatten an EApp spine into [head, arg1, arg2, …]
spineList : Expr -> List Expr
spineList e = spineOnto e []

spineOnto : Expr -> List Expr -> List Expr
spineOnto (ELoc _ e) acc = spineOnto e acc
spineOnto (EApp f x) acc = spineOnto f (x::acc)
spineOnto e acc = e::acc

exprToPat : Expr -> Pat
exprToPat (ELoc _ e) = exprToPat e
exprToPat (EVar "_") = PWild
exprToPat (EVar x) = ctorOrVar x
exprToPat (ELit l) = PLit l
-- PLAN.md #11 §0.4: an integer in pattern (binding-LHS) position stays a
-- monomorphic `Int` pattern; only EXPRESSION-position integers go polymorphic.
exprToPat (ENumLit n _ _ _) = PLit (LInt n)
exprToPat (ETuple es) = PTuple (map exprToPat es)
exprToPat (EListLit es) = PList (map exprToPat es)
exprToPat (EBinOp "::" a b _) = PCons (exprToPat a) (exprToPat b)
-- `(x :: _)` in a binding LHS: the `_` was eaten by the left-section rewrite
-- (parenResult/leftSectionOrExpr); recover it as a cons pattern (mirrors the
-- reference `expr_to_pat`'s `SecLeft (a, "::")` case).
exprToPat (ESection (SecLeft a "::")) = PCons (exprToPat a) PWild
exprToPat (EAsPat x sub) = PAs x (exprToPat sub)
exprToPat (EApp f x) = appToPat (EApp f x)
exprToPat _ = PWild

ctorOrVar : String -> Pat
ctorOrVar x
  | isCtorName x = PCon x []
  | otherwise = PVar x

-- constructor-application pattern: the spine head must be uppercase
appToPat : Expr -> Pat
appToPat app = appToPatH (spineHead app) (spineList app)

appToPatH : Expr -> List Expr -> Pat
appToPatH (EVar c) spine = appToPatCtor c spine
appToPatH _ _ = PWild

appToPatCtor : String -> List Expr -> Pat
appToPatCtor c spine
  | isCtorName c = PCon c (map exprToPat (dropFirst spine))
  | otherwise = PWild

dropFirst : List a -> List a
dropFirst [] = []
dropFirst (_::xs) = xs

isCtorName : String -> Bool
isCtorName s = isCtorChars (stringToChars s)

isCtorChars : Array Char -> Bool
isCtorChars cs
  | arrayLength cs == 0 = False
  | otherwise = isUpper (arrayGetUnsafe 0 cs)

-- Peel transparent ELoc wrappers to expose the underlying expr shape.  Mirrors
-- parser.mly's local `strip` (used before `expr_to_pat`/section detection): the
-- binding-LHS→pattern conversions and section recovery match on the raw node
-- kind, so they must see through the ELoc the atom level now puts on leaves.
stripLoc : Expr -> Expr
stripLoc (ELoc _ e) = stripLoc e
stripLoc e = e

binOp : Token -> String -> Parser (Expr -> Expr -> Expr)
binOp tk op = do
  expectTok tk
  pure (l r => EBinOp op l r (Ref RNone))

parseOr : Parser Expr
parseOr = chainl1 parseAnd (binOp TOr "||")

parseAnd : Parser Expr
parseAnd = chainl1 parseCmp (binOp TAnd "&&")

parseCmp : Parser Expr
parseCmp = chainl1 parseCons cmpOp

cmpOp : Parser (Expr -> Expr -> Expr)
cmpOp = choice
  [
    binOp TEqEq "==",
    binOp TNeq "!=",
    binOp TLt "<",
    binOp TGt ">",
    binOp TLeq "<=",
    binOp TGeq ">=",
  ]

-- `::` is right-associative
parseCons : Parser Expr
parseCons = do
  x <- parseAppend
  orElse (consTail x) (pure x)

consTail : Expr -> Parser Expr
consTail x = do
  expectTok TCons
  y <- parseCons
  pure (EBinOp "::" x y (Ref RNone))

parseAppend : Parser Expr
parseAppend = chainl1 parseAdd (binOp TPlusPlus "++")

parseAdd : Parser Expr
parseAdd = chainl1
  parseMul
  (choice [binOp TPlus "+", binOp TMinus "-", binOp TMinusTight "-"])

parseMul : Parser Expr
parseMul = chainl1
  parseUnary
  (choice [binOp TStar "*", binOp TSlash "/", binOp TMod "%"])

-- ── The 2^62 int literal: legal only under a unary `-` (#171) ───────────────
-- `Int` is 63-bit (`word = (n << 1) | 1`), spanning [-2^62, 2^62-1].  The lexer
-- sees only unsigned digits — the `-` is a separate token — so its magnitude
-- guard (`intLitOverflows`) must admit 2^62 to keep the minimum -2^62 writable,
-- and `parseIntFrom` wraps that magnitude to `intMinBound` on the spot.  The
-- SIGN only exists here, in the parser, so this is the only place the remaining
-- asymmetry can be resolved: 2^62 is in range as a negative and out of range as
-- a positive.  C, Rust and Haskell all carry the same INT_MIN literal asymmetry.
--
-- A `TInt` carrying exactly `intMinBound` can ONLY have come from the digit
-- string 2^62 (every admissible smaller magnitude parses non-negative), so the
-- value is an exact discriminator and needs no extra token.  Every site that
-- consumes a `TInt` in POSITIVE position rejects it (`intLitTooBigMsg`); the
-- negation sites consume the token themselves and keep the value as-is —
-- `negate intMinBound` wraps back to `intMinBound`, which is the wanted number.
-- Rejection is FATAL: an enclosing `many (appArg …)` would otherwise swallow a
-- recoverable failure and the user would get "unexpected INT" instead.
--
-- Written as arithmetic rather than as the literal `-4611686018427387904` so
-- that the constant does not depend on the very rule it defines.
intMinLit : Int
intMinLit = 0 - 4611686018427387903 - 1

isIntMinLit : Int -> Bool
isIntMinLit n = n == intMinLit

-- Named as a String, not as a `Parser a`: a `rejectIntMinLit = fatalP msg` would be
-- a constructor APPLICATION, which is not generalized — the `a` would monomorphise
-- to whichever site typechecked first (`Parser Lit`) and clash with the rest.
-- `fatalP` is a function, so each call site instantiates it freshly; this is the
-- same shape every `failP "…"` in this file already uses.
-- Per ERROR-QUALITY.md §4.5 the message states WHAT is wrong and the actionable
-- "what to do" belongs in a `help:` line, so the intMinBound advice lives in
-- `parseErrHelpFix` (`compiler/driver/diagnostics.mdk`), not here.  Two prefixes
-- are load-bearing and must move together with that function:
--   * "integer literal too large" — `parseErrCode` keys on it for L-INT-OVERFLOW,
--     shared DELIBERATELY with the lexer's out-of-range message (#171);
--   * the full "(max 4611686018427387903)" text — `parseErrHelpFix` keys on it to
--     attach the help to THIS message only.  The lexer's sibling message ends
--     "(max magnitude 2^62)" and must NOT get this help: for a literal that far
--     out of range the `-` advice is useless, since no sign makes it fit.
intLitTooBigMsg : String
intLitTooBigMsg = "integer literal too large for Int (max 4611686018427387903)"

-- unary minus, tighter than `*` (a leading `-` in operand position)
parseUnary : Parser Expr
parseUnary = do
  t <- peekP
  unaryFor t

unaryFor : Token -> Parser Expr
unaryFor TMinus = negUnary
unaryFor TMinusTight = negUnary
unaryFor TBang = do
  advance
  e <- parseUnary
  pure (EUnOp "!" e (Ref RNone))
unaryFor _ = parseInfix

-- `-` in operand position.  A directly-following 2^62 literal is FUSED into a
-- single negative `ENumLit` (the token already carries `intMinBound`), which is
-- both the value `EUnOp "-"` would have computed and the only shape that keeps
-- `-4611686018427387904` writable now that the bare literal is rejected.  Same
-- fusion `negLitArgFor` already does for a tight negative argument.  Anything
-- else keeps the ordinary `EUnOp "-"` shape.
negUnary : Parser Expr
negUnary = do
  t2 <- peek2P
  negUnaryFor t2

negUnaryFor : Token -> Parser Expr
negUnaryFor (TInt n lx)
  | isIntMinLit n = located (do
    advance
    advance
    pure (ENumLit n (Ref None) (Ref RNone) ("-" ++ lx)))
negUnaryFor _ = do
  advance
  e <- parseUnary
  pure (EUnOp "-" e (Ref RNone))

-- backtick infix application (``a `div` b``) has been removed.  The lexer still
-- produces `TBacktickIdent` as a sentinel; a pre-grammar scan surfaces a located
-- hint pointing at the backtick operator.
parseInfix : Parser Expr
parseInfix = parseApp

parseApp : Parser Expr
parseApp = do
  head <- parseAspat
  args <- many (appArg (headIsNumeric head))
  pure (applyAll head args)

-- One application argument.  Normally an aspat, but a TIGHT negative literal
-- (`f -1` / `f -1.5`, lexed as TMinusTight INT/FLOAT) is grabbed as a
-- negative-numeric argument when the application HEAD is non-numeric.  A numeric
-- head (`5 -1`) never grabs, so the TMinusTight falls through to parseAdd's
-- binary minus and stays subtraction (Rule C, head-gated).
appArg : Bool -> Parser Expr
appArg headNum = orElse (negLitArg headNum) parseAspat

negLitArg : Bool -> Parser Expr
negLitArg True = failP "numeric head: tight minus stays subtraction"
negLitArg False = do
  t <- peekP
  t2 <- peek2P
  negLitArgFor t t2

negLitArgFor : Token -> Token -> Parser Expr
negLitArgFor TMinusTight (TInt n lx) = do
  advance
  advance
  pure (ENumLit (negate n) (Ref None) (Ref RNone) ("-" ++ lx))
negLitArgFor TMinusTight (TFloat f) = do
  advance
  advance
  pure (ELit (LFloat (negate f)))
negLitArgFor _ _ = failP "not a tight negative literal argument"

-- Is the application head a numeric literal (so a following `-N` is subtraction,
-- not a negative argument)?  Strip the transparent ELoc wrapper first.
headIsNumeric : Expr -> Bool
headIsNumeric (ELoc _ e) = headIsNumeric e
headIsNumeric (ENumLit _ _ _ _) = True
headIsNumeric (ELit (LInt _)) = True
headIsNumeric (ELit (LFloat _)) = True
headIsNumeric _ = False

-- the as-pattern operator level (`expr_aspat`): `IDENT AS_AT postfix` → EAsPat
-- (a binding-LHS as-pattern, e.g. a lambda param `xs@rest =>`); else a postfix.
-- AS_AT is only emitted by the lexer when `@` directly follows an identifier.
parseAspat : Parser Expr
parseAspat = orElse parseAspatAt parsePostfix

parseAspatAt : Parser Expr
parseAspatAt = located parseAspatAtRaw

parseAspatAtRaw : Parser Expr
parseAspatAtRaw = do
  x <- identNameP
  expectTok TAsAt
  sub <- parsePostfix
  pure (EAsPat x sub)

applyAll : Expr -> List Expr -> Expr
applyAll head [] = head
applyAll head (a::rest) = applyAll (EApp head a) rest

parsePostfix : Parser Expr
parsePostfix = do
  e <- parseAtom
  postfixTail e

postfixTail : Expr -> Parser Expr
postfixTail e = orElse (bracketIndexTail e) (orElse (dotTail e) (pure e))

-- bare `a[i]` postfix indexing (no dot) — fires only on the adjacency-lexed
-- TLBracketTight token, so a spaced `a [i]` (application to a list literal)
-- is untouched. Builds the SAME EIndex node dotTail's `.[i]` produces. Bare
-- slice `a[i..j]`/`a[i..=j]` is deferred (#17) — clean error, not ESlice.
bracketIndexTail : Expr -> Parser Expr
bracketIndexTail e = do
  expectTok TLBracketTight
  lo <- parseExpr
  t <- peekP
  bracketIndexRest e lo t

bracketIndexRest : Expr -> Expr -> Token -> Parser Expr
bracketIndexRest _ _ TDotDot =
  failP "bare slice `a[i..j]` is not yet supported — use `a.[i..j]`"
bracketIndexRest _ _ TDotDotEq =
  failP "bare slice `a[i..=j]` is not yet supported — use `a.[i..=j]`"
bracketIndexRest e lo TRBracket = do
  advance
  postfixTail (EIndex e lo (Ref "Array"))
bracketIndexRest _ _ _ = failP "expected ']' in index expression"

-- after a `.`: a field access `.field`, an index `.[i]`, or a slice `.[lo..hi]`
dotTail : Expr -> Parser Expr
dotTail e = do
  expectTok TDot
  t <- peekP
  dotFor e t

dotFor : Expr -> Token -> Parser Expr
dotFor e TLBracket = indexOrSlice e
dotFor e _ = do
  f <- identNameP
  postfixTail (EFieldAccess e f (Ref ""))

indexOrSlice : Expr -> Parser Expr
indexOrSlice e = do
  expectTok TLBracket
  lo <- parseExpr
  t <- peekP
  indexOrSliceRest e lo t

indexOrSliceRest : Expr -> Expr -> Token -> Parser Expr
indexOrSliceRest e lo TDotDot = sliceHi e lo False
indexOrSliceRest e lo TDotDotEq = sliceHi e lo True
indexOrSliceRest e lo TRBracket = do
  advance
  postfixTail (EIndex e lo (Ref "Array"))
indexOrSliceRest _ _ _ = failP "expected .. ..= or ] in index/slice"

sliceHi : Expr -> Expr -> Bool -> Parser Expr
sliceHi e lo incl = do
  advance
  hi <- parseExpr
  expectTok TRBracket
  postfixTail (ESlice e lo hi incl (Ref "Array"))

-- Atom level (`expr_atom` + the statement-form productions in parser.mly).
-- Wrapped in a transparent ELoc capturing the atom's token span, mirroring
-- parser.mly where every atom and every let/if/match/function/do production is
-- `ELoc (of_pos $startpos $endpos, …)`.  Binop/app/unary/postfix levels stay
-- un-wrapped (exactly like parser.mly's `mkbin`/`EApp` rules), so their span is
-- implicit from their wrapped leaf operands.
parseAtom : Parser Expr
parseAtom = located parseAtomRaw

parseAtomRaw : Parser Expr
parseAtomRaw = do
  t <- peekP
  match t
    TInt n _ if isIntMinLit n => fatalP intLitTooBigMsg
    TInt n lx => emit (ENumLit n (Ref None) (Ref RNone) lx)
    TFloat f => emit (ELit (LFloat f))
    TString s => emit (ELit (LString s))
    TChar s => emit (ELit (LChar s))
    TIdent x => emit (EVar x)
    TUpper x => parseUpperAtom x
    TUnderscore => emit (EVar "_")
    TLParen => parseParen
    TLBracket => parseListE
    TLArray => parseArray
    TLBrace => parseRecordUpdate
    TIf => parseIf
    TLet => parseLet
    TMatch => parseMatch
    TDo => parseDo
    TInterpOpen _ => parseInterp
    _ => failP "expected atom"

-- a constructor (`Upper`) atom, or a record literal `Upper { field = e, … }`
parseUpperAtom : String -> Parser Expr
parseUpperAtom x = do
  advance
  t <- peekP
  upperTail x t

upperTail : String -> Token -> Parser Expr
upperTail x TLBrace = upperBrace x
upperTail x _ = pure (EVar x)

-- After `Con {`: a constructor-tagged variant update `Con { e | f = v, … }`
-- (a `|` follows the leading expr), or the unified `Con { kv_or_e, … }` form,
-- which classifies (mirroring lib/parser.mly) into a record create (`f = v`
-- fields + puns), a map literal (`k => v` entries), or a set literal (bare
-- elements).  `orElse` backtracks, so try the update form first — its leading
-- `parseExpr` fails fast at the first `=`/`=>`/`,`/`}` (no `|`).
upperBrace : String -> Parser Expr
upperBrace x = do
  expectTok TLBrace
  orElse (variantUpdateTail x) (braceItems x)

variantUpdateTail : String -> Parser Expr
variantUpdateTail x = do
  e <- parseExpr
  expectTok TPipe
  fields <- sepBy1 recordFieldExpr (expectTok TComma)
  optTrailingComma
  expectTok TRBrace
  pure (EVariantUpdate x e (map (desugarDottedField e) fields))

-- a kv_or_e item: a record field `f = v`, a map entry `k => v`, or a bare
-- element/pun.  The classification of the whole brace picks the node kind.
data KvItem = KvField String Expr | KvKV Expr Expr | KvElem Expr

braceItems : String -> Parser Expr
braceItems x = do
  t <- peekP
  braceItemsFor x t

braceItemsFor : String -> Token -> Parser Expr
braceItemsFor x TRBrace = do
  advance
  pure (classifyBrace x [])
braceItemsFor x _ = do
  items <- sepBy1 parseKvOrE (expectTok TComma)
  optTrailingComma
  expectTok TRBrace
  pure (classifyBrace x items)

-- `IDENT = expr` → field; `key => expr` → map entry; else a bare element.  The
-- key is parsed at the pipe level (like the reference `expr_pipe`) so a `=>`
-- ends the key rather than starting a lambda.
parseKvOrE : Parser KvItem
parseKvOrE = orElse parseKvField (orElse parseKvBlockElem parseKvKVorElem)

-- Gate B: a bare-INDENT block as a record-field / set-element value.
parseKvBlockElem : Parser KvItem
parseKvBlockElem = do
  e <- parseBracketBlock
  pure (KvElem e)

parseKvField : Parser KvItem
parseKvField = do
  name <- identNameP
  expectTok TEqual
  e <- parseBracketElem
  pure (KvField name e)

parseKvKVorElem : Parser KvItem
parseKvKVorElem = do
  e <- parsePipe
  t <- peekP
  kvKVorElemFor e t

kvKVorElemFor : Expr -> Token -> Parser KvItem
kvKVorElemFor e TFatArrow = do
  advance
  v <- parseExpr
  pure (KvKV e v)
kvKVorElemFor e _ = pure (KvElem e)

-- classify: any field → record create (Elem puns to `n = n`); else any map
-- entry → map literal; else → set literal.  (Mirrors lib/parser.mly's
-- `UPPER LBRACE … RBRACE` action; mixed-kind braces are user errors.)
classifyBrace : String -> List KvItem -> Expr
classifyBrace name items
  | anyField items = ERecordCreate name (map kvToField items)
  | anyKV items = EMapLit name (kvPairs items)
  | otherwise = ESetLit name (kvElems items)

anyField : List KvItem -> Bool
anyField [] = False
anyField ((KvField _ _)::_) = True
anyField (_::rest) = anyField rest

anyKV : List KvItem -> Bool
anyKV [] = False
anyKV ((KvKV _ _)::_) = True
anyKV (_::rest) = anyKV rest

kvToField : KvItem -> FieldAssign
kvToField (KvField n e) = FieldAssign n e
kvToField (KvElem e) = kvElemToField (stripLoc e)
kvToField _ = FieldAssign "_" (ELit LUnit)

-- a bare element in a record-literal brace is a pun `{ x }` → `{ x = x }`.
kvElemToField : Expr -> FieldAssign
kvElemToField (EVar n) = FieldAssign n (EVar n)
kvElemToField _ = FieldAssign "_" (ELit LUnit)

kvPairs : List KvItem -> List (Expr, Expr)
kvPairs [] = []
kvPairs ((KvKV k v)::rest) = (k, v) :: kvPairs rest
kvPairs (_::rest) = kvPairs rest

kvElems : List KvItem -> List Expr
kvElems [] = []
kvElems ((KvElem e)::rest) = e :: kvElems rest
kvElems (_::rest) = kvElems rest

-- record update `{ e | field = e, … }`, including nested dotted-path fields
-- `{ p | a.b.c = v }` desugared to nested ERecordUpdates.
parseRecordUpdate : Parser Expr
parseRecordUpdate = do
  expectTok TLBrace
  e <- parseExpr
  expectTok TPipe
  fields <- sepBy1 recordFieldExpr (expectTok TComma)
  optTrailingComma
  expectTok TRBrace
  pure (ERecordUpdate e (map (desugarDottedField e) fields) (Ref ""))

-- a record-update field `path = expr` (dotted path) or a pun `name`
-- (mirrors lib/parser.mly `record_field_expr`).
recordFieldExpr : Parser (List String, Expr)
recordFieldExpr = do
  path <- sepBy1 identNameP (expectTok TDot)
  t <- peekP
  recordFieldExprRest path t

recordFieldExprRest : List String -> Token -> Parser (List String, Expr)
recordFieldExprRest path TEqual = do
  advance
  e <- parseBracketElem
  pure (path, e)
recordFieldExprRest [x] _ = pure ([x], EVar x)
recordFieldExprRest _ _ = failP "expected = in record-update field"

-- desugar a dotted-path update field against the update base:
-- `{ base | a.b.c = v }` → ("a", { base.a | b = { base.a.b | c = v } })
-- (mirrors lib/parser.mly `desugar_dotted_field`).
desugarDottedField : Expr -> (List String, Expr) -> FieldAssign
desugarDottedField base (path, value) = match path
  [field] => FieldAssign field value
  field::rest =>
    FieldAssign field (dottedGo (EFieldAccess base field (Ref "")) rest value)
  [] => FieldAssign "_" value

dottedGo : Expr -> List String -> Expr -> Expr
dottedGo cur [f] value = ERecordUpdate cur [FieldAssign f value] (Ref "")
dottedGo cur (f::fs) value = ERecordUpdate
  cur
  [FieldAssign f (dottedGo (EFieldAccess cur f (Ref "")) fs value)]
  (Ref "")
dottedGo cur [] value = value

-- interpolated string: INTERP_OPEN <expr> (INTERP_MID <expr>)* INTERP_END,
-- assembled into alternating InterpStr / InterpExpr parts
parseInterp : Parser Expr
parseInterp = do
  s0 <- interpOpenStr
  rest <- interpRest
  pure (EStringInterp (InterpStr s0 :: rest))

interpOpenStr : Parser String
interpOpenStr = do
  t <- peekP
  interpOpenFor t

interpOpenFor : Token -> Parser String
interpOpenFor (TInterpOpen s) = emit s
interpOpenFor _ = failP "expected interpolation open"

interpRest : Parser (List InterpPart)
interpRest = do
  e <- parseExpr
  t <- peekP
  interpRestFor e t

interpRestFor : Expr -> Token -> Parser (List InterpPart)
interpRestFor e (TInterpMid s) = do
  advance
  rest <- interpRest
  pure (InterpExpr e :: InterpStr s :: rest)
interpRestFor e (TInterpEnd s) = do
  advance
  pure [InterpExpr e, InterpStr s]
interpRestFor e _ = failP "expected interpolation mid/end"

-- Bracket block-expressions (LAYOUT-BRACKETS-DESIGN.md, Gate B).  The locked
-- herald set is match/do/record/bare-INDENT block.  All of those
-- EXCEPT the bare-INDENT block already reach bracket element positions because
-- parseAtomRaw dispatches TMatch/TDo (and records via TUpper/TLBrace)
-- as atoms, so parseExpr reaches them.  The one herald NOT reachable from the
-- expression chain is the bare-INDENT block (it lives only in the decl-body
-- `indentedBody`).  parseBracketBlock is the dedicated, contained reader for it;
-- parseBracketElem admits it in bracket element positions WITHOUT folding the
-- bare-INDENT block into parseAtom/parseExpr generally (mirrors parser.mly's
-- `bracket_block`/`bracket_elem`).
-- NOTE (staging): the LEXER does not yet emit INDENT/NEWLINE/DEDENT inside
-- brackets (Stage 3, pending), so these readers are not reachable on real input
-- yet — they exist so the grammar has a target the future lexer tokens land on.
parseBracketBlock : Parser Expr
parseBracketBlock = do
  expectTok TIndent
  stmts <- parseStmts
  expectTok TDedent
  pure (blockOrExpr stmts)

-- a bracket element: a bare-INDENT block, or an ordinary expression.
parseBracketElem : Parser Expr
parseBracketElem = orElse parseBracketBlock parseExpr

parseParen : Parser Expr
parseParen = do
  expectTok TLParen
  t <- peekP
  parenFor t

-- inside parens: `()` unit, an operator section `(op)`/`(op e)`/`(e op _)`,
-- a tuple, or a plain parenthesised expression
parenFor : Token -> Parser Expr
parenFor TRParen = emit (ELit LUnit)
parenFor TMinus = orElse bareMinusSection parseParenExpr
parenFor TMinusTight = orElse bareMinusSection parseParenExpr
parenFor t = parenSectionOr t

parenSectionOr : Token -> Parser Expr
parenSectionOr t = match sectionOpStr t
  Some op => parseSectionOp op
  None => parseParenExpr

-- `(-)` is a bare section; `(-e)` is a parenthesised unary minus (orElse falls
-- through). MINUS is excluded from the SecRight form, matching the grammar.
bareMinusSection : Parser Expr
bareMinusSection = do
  expectMinus
  expectTok TRParen
  pure (ESection (SecBare "-"))

-- Accept either spacing of bare minus (TMinus or the asymmetric-spaced
-- TMinusTight) wherever a `-` operator token is required.
expectMinus : Parser Unit
expectMinus = do
  t <- peekP
  expectMinusGo t

expectMinusGo : Token -> Parser Unit
expectMinusGo TMinus = emit ()
expectMinusGo TMinusTight = emit ()
expectMinusGo _ = failP "expected -"

parseSectionOp : String -> Parser Expr
parseSectionOp op = do
  advance
  t <- peekP
  sectionTail op t

sectionTail : String -> Token -> Parser Expr
sectionTail op TRParen = do
  advance
  pure (ESection (SecBare op))
sectionTail op _ = do
  e <- parseExpr
  expectTok TRParen
  pure (ESection (SecRight op e))

parseParenExpr : Parser Expr
parseParenExpr = do
  es <- sepBy1 parseBracketElem (expectTok TComma)
  optTrailingCommaTuple es
  expectTok TRParen
  pure (parenResult es)

parenResult : List Expr -> Expr
parenResult [e] = leftSectionOrExpr e
parenResult es = ETuple es

-- a single `(e op _)` becomes a left section; otherwise just the inner expr.
-- The `_` placeholder is a wrapped atom (`ELoc (EVar "_")`), so strip the RHS
-- operand before matching (mirrors parser.mly's local `strip` in this rule).
-- On no match we return the ORIGINAL expr untouched (keeping its wrappers).
leftSectionOrExpr : Expr -> Expr
leftSectionOrExpr e = leftSectionGo e (stripLoc e)

leftSectionGo : Expr -> Expr -> Expr
leftSectionGo orig (EBinOp op lhs rhs _) =
  leftSectionRhs orig op lhs (stripLoc rhs)
leftSectionGo orig _ = orig

leftSectionRhs : Expr -> String -> Expr -> Expr -> Expr
leftSectionRhs _ op lhs (EVar "_") = ESection (SecLeft lhs op)
leftSectionRhs orig _ _ _ = orig

-- section_op (no MINUS): tokens that can head an operator section
sectionOpStr : Token -> Option String
sectionOpStr TPlus = Some "+"
sectionOpStr TStar = Some "*"
sectionOpStr TSlash = Some "/"
sectionOpStr TEqEq = Some "=="
sectionOpStr TNeq = Some "!="
sectionOpStr TLt = Some "<"
sectionOpStr TGt = Some ">"
sectionOpStr TLeq = Some "<="
sectionOpStr TGeq = Some ">="
sectionOpStr TAnd = Some "&&"
sectionOpStr TOr = Some "||"
sectionOpStr TCons = Some "::"
sectionOpStr TPlusPlus = Some "++"
sectionOpStr TPipeRight = Some "|>"
sectionOpStr TRCompose = Some ">>"
sectionOpStr TLCompose = Some "<<"
sectionOpStr _ = None

parseListE : Parser Expr
parseListE = do
  expectTok TLBracket
  t <- peekP
  listFor t

listFor : Token -> Parser Expr
listFor TRBracket = emit (EListLit [])
listFor _ = do
  first <- parseBracketElem
  t <- peekP
  listRest first t

-- after the first element: `..`/`..=` range, `,` more elements, or `]` close
listRest : Expr -> Token -> Parser Expr
listRest first TDotDot = rangeAfter first False
listRest first TDotDotEq = rangeAfter first True
listRest first TComma = do
  advance
  t <- peekP
  listAfterComma first t
listRest first TRBracket = do
  advance
  pure (EListLit [first])
listRest _ _ = failP "expected , .. ..= or ]"

-- after the first element and a comma: a `]` here is a trailing comma on a
-- single-element list (`[x,]`); otherwise parse the remaining elements (and
-- accept a trailing comma after them too).
listAfterComma : Expr -> Token -> Parser Expr
listAfterComma first TRBracket = do
  advance
  pure (EListLit [first])
listAfterComma first _ = do
  rest <- sepBy1 parseBracketElem (expectTok TComma)
  optTrailingComma
  expectTok TRBracket
  pure (EListLit (first::rest))

rangeAfter : Expr -> Bool -> Parser Expr
rangeAfter lo incl = do
  advance
  hi <- parseExpr
  expectTok TRBracket
  pure (ERangeList lo hi incl)

-- array literal `[| e, … |]`
parseArray : Parser Expr
parseArray = do
  expectTok TLArray
  t <- peekP
  arrayFor t

arrayFor : Token -> Parser Expr
arrayFor TRArray = emit (EArrayLit [])
arrayFor _ = do
  first <- parseBracketElem
  t <- peekP
  arrayRest first t

-- after the first element: `..`/`..=` array range, `,` more elements, or `|]`
arrayRest : Expr -> Token -> Parser Expr
arrayRest first TDotDot = arrayRangeAfter first False
arrayRest first TDotDotEq = arrayRangeAfter first True
arrayRest first TComma = do
  advance
  t <- peekP
  arrayAfterComma first t
arrayRest first TRArray = do
  advance
  pure (EArrayLit [first])
arrayRest _ _ = failP "expected , .. ..= or |]"

-- single-element trailing comma `[|x,|]`: a `|]` after the comma closes it.
arrayAfterComma : Expr -> Token -> Parser Expr
arrayAfterComma first TRArray = do
  advance
  pure (EArrayLit [first])
arrayAfterComma first _ = do
  rest <- sepBy1 parseBracketElem (expectTok TComma)
  optTrailingComma
  expectTok TRArray
  pure (EArrayLit (first::rest))

arrayRangeAfter : Expr -> Bool -> Parser Expr
arrayRangeAfter lo incl = do
  advance
  hi <- parseExpr
  expectTok TRArray
  pure (ERangeArray lo hi incl)

parseIf : Parser Expr
parseIf = do
  expectTok TIf
  t <- peekP
  ifKind t

ifKind : Token -> Parser Expr
ifKind TLet = ifLet
ifKind _ = ifPlain

-- `if let pat = e then t else f` desugars (at parse) to a two-arm match, exactly
-- like lib/parser.mly: `match e { pat => t; _ => f }`.  Always has an else.
ifLet : Parser Expr
ifLet = do
  expectTok TLet
  pat <- parsePat
  expectTok TEqual
  scrut <- parseExpr
  expectTok TThen
  thenE <- parseExpr
  expectTok TElse
  elseE <- parseExpr
  pure (EMatch scrut [Arm pat [] thenE, Arm PWild [] elseE])

ifPlain : Parser Expr
ifPlain = do
  cond <- parseExpr
  expectTok TThen
  thenE <- parseBranch
  elseE <- elseBranch
  pure (EIf cond thenE elseE)

-- `else` is optional; an else-less `if` defaults the else branch to unit
elseBranch : Parser Expr
elseBranch = orElse elsePresent (pure (ELit LUnit))

elsePresent : Parser Expr
elsePresent = do
  expectTok TElse
  parseBranch

-- a then/else branch is either an inline expr or an indented statement block
parseBranch : Parser Expr
parseBranch = orElse branchBlock parseExpr

branchBlock : Parser Expr
branchBlock = do
  expectTok TIndent
  stmts <- parseStmts
  expectTok TDedent
  pure (blockOrExpr stmts)

-- expression-level `let`: `let [mut] pat = e in e2`, function-let
-- `let f a… = e in e2`, annotated `let [mut] x : ty = e in e2`, and
-- mutually-recursive `let rec f = … with g = … in e2` (→ ELetGroup).  Mirrors
-- the `expr_lam` LET productions in lib/parser.mly.
parseLet : Parser Expr
parseLet = do
  expectTok TLet
  t <- peekP
  letExprKind t

letExprKind : Token -> Parser Expr
-- beta mutability model: `let mut` has been removed (bindings are immutable).
-- It is rejected here at the parser so the `mut` flag is never constructed
-- anywhere downstream. See `letMutRemovedMsg`.
letExprKind TMut = failP letMutRemovedMsg
letExprKind TRec = letRecExpr
letExprKind (TIdent name) = letIdentExpr name
letExprKind _ = letPatExpr

-- The single parser rejection message for `let mut` (used at both the
-- expression-level and statement-level `let` productions). Points at `Ref`/`:=`.
letMutRemovedMsg : String
letMutRemovedMsg = "`let mut` has been removed — bindings are immutable. For mutable state use a `Ref` cell: `let x = Ref 0`, write `x := newValue`, and read it with `x.value`"

-- `record` is no longer a keyword: a single-constructor named-field product is
-- the degenerate case of `data`, so declare a record with the `data X = { … }`
-- short form.  A pre-grammar token scan surfaces a clean, located hint (pointing
-- at `record`) for users arriving from other languages.
recordRemovedMsg : String
recordRemovedMsg =
  "`record` is not a keyword — declare a record as `data X = { field : T, … }`"

-- `function` is no longer a keyword: the point-free one-arg match it wrote
-- (`function\n  pat => body`) is redundant with `x => match x { pat => body }`
-- and with multi-clause definitions. A pre-grammar token scan surfaces a
-- clean, located hint (pointing at `function`).
functionRemovedMsg : String
functionRemovedMsg = "`function` is not a keyword — use `x => match x { … }` or a multi-clause definition"

-- IDENT-led: function-let `let f a… = e` (params present), annotated
-- `let x : ty = e`, or plain `let x = e`, each followed by `in e2`
letIdentExpr : String -> Parser Expr
letIdentExpr name = do
  advance
  params <- many parseParamPat
  t <- peekP
  letIdentExprRest name params t

letIdentExprRest : String -> List Pat -> Token -> Parser Expr
letIdentExprRest name [] TColon = do
  advance
  ty <- parseTy
  expectTok TEqual
  e1 <- parseExpr
  expectTok TIn
  e2 <- parseExpr
  pure (ELet False False (PVar name) (EAnnot e1 ty) e2)
letIdentExprRest name [] TEqual = do
  advance
  e1 <- parseExpr
  expectTok TIn
  e2 <- parseExpr
  pure (ELet False False (PVar name) e1 e2)
letIdentExprRest name params TEqual = do
  advance
  e1 <- parseExpr
  expectTok TIn
  e2 <- parseExpr
  pure (ELet False True (PVar name) (curryLam params e1) e2)
letIdentExprRest _ _ _ = failP "expected : or = in let"

-- non-IDENT pattern: `let (a, b) = e in e2`, `let Some x = e in e2`, …
letPatExpr : Parser Expr
letPatExpr = do
  pat <- parsePat
  expectTok TEqual
  e1 <- parseExpr
  expectTok TIn
  e2 <- parseExpr
  pure (ELet False False pat e1 e2)

-- `let rec f a… = e in e2` → ELetGroup with a single binding (Phase 57 inline
-- form). Mutual-recursion grouping via `with` has been removed — each
-- recursive binding is its own `let rec`.
letRecExpr : Parser Expr
letRecExpr = do
  expectTok TRec
  clause <- letRecInlineClause
  expectTok TIn
  e2 <- parseExpr
  pure (ELetGroup (coalesceClauses [clause]) e2)

letRecInlineClause : Parser (String, List Pat, Expr)
letRecInlineClause = do
  name <- identNameP
  pats <- many parseParamPat
  expectTok TEqual
  body <- parseExpr
  pure (name, pats, body)

parseMatch : Parser Expr
parseMatch = do
  expectTok TMatch
  scrut <- parseExpr
  expectTok TIndent
  arms <- parseArms
  expectTok TDedent
  pure (EMatch scrut arms)

parseArms : Parser (List Arm)
parseArms = do
  skipNewlines
  armsLoop

armsLoop : Parser (List Arm)
armsLoop = orElse armsCons (pure [])

armsCons : Parser (List Arm)
armsCons = do
  a <- parseArm
  skipNewlines
  rest <- armsLoop
  pure (a::rest)

parseArm : Parser Arm
parseArm = do
  pat <- parsePat
  guards <- armGuardOpt
  expectTok TFatArrow
  body <- orElse branchBlock parseBodyExpr
  pure (Arm pat guards body)

-- optional match-arm guard: `if g, g…` (NB: uses `if`, not `|`)
armGuardOpt : Parser (List Guard)
armGuardOpt = do
  t <- peekP
  armGuardFor t

armGuardFor : Token -> Parser (List Guard)
armGuardFor TIf = do
  advance
  sepBy1 parseGuard (expectTok TComma)
armGuardFor _ = pure []

-- ── Patterns ────────────────────────────────────────────────────────────
-- A full pattern is a cons-pattern; the as-pattern `x@p` is a cons HEAD, so `@`
-- binds tighter than `::` (see parsePatCons/parseAsPat below).  AS_AT is the
-- lexer's `@`-adjacent-to-ident token; if it doesn't follow, orElse backtracks.
parsePat : Parser Pat
parsePat = parsePatCons

-- `@` binds TIGHTER than `::`: `t@(A _)::rest` is `PCons (PAs t (A _)) rest`,
-- not `PAs t (PCons (A _) rest)` (#812).  So the as-pattern is parsed as a cons
-- HEAD (below), and its sub-pattern is a `parsePatApp` — an application/atom that
-- does NOT swallow a following `::` tail.
parseAsPat : Parser Pat
parseAsPat = do
  x <- identNameP
  expectTok TAsAt
  sub <- parsePatApp
  pure (PAs x sub)

parsePatCons : Parser Pat
parsePatCons = do
  p <- orElse parseAsPat parsePatApp
  orElse (patConsTail p) (pure p)

patConsTail : Pat -> Parser Pat
patConsTail p = do
  expectTok TCons
  q <- parsePatCons
  pure (PCons p q)

parsePatApp : Parser Pat
parsePatApp = do
  t <- peekP
  patAppFor t

patAppFor : Token -> Parser Pat
patAppFor (TUpper c) = do
  advance
  t <- peekP
  upperPatRest c t
patAppFor _ = parsePatAtom

-- after an uppercase ctor in pattern position: a record pattern `C { … }`,
-- else a constructor application `C p…`
upperPatRest : String -> Token -> Parser Pat
upperPatRest c TLBrace = recordPat c
upperPatRest c _ = do
  args <- many parsePatAtom
  pure (PCon c args)

-- record pattern: `C { field, field = pat, … }` with an optional `...` rest
recordPat : String -> Parser Pat
recordPat c = do
  expectTok TLBrace
  fr <- recordPatFields
  expectTok TRBrace
  pure (mkRec c fr)

mkRec : String -> (List RecPatField, Bool) -> Pat
mkRec c (fields, rest) = PRec c fields rest

recordPatFields : Parser (List RecPatField, Bool)
recordPatFields = do
  t <- peekP
  recordPatFieldsFor t

recordPatFieldsFor : Token -> Parser (List RecPatField, Bool)
recordPatFieldsFor TEllipsis = do
  advance
  pure ([], True)
-- trailing comma: a `}` directly after a comma closes the field list (also
-- accepts an empty `C {}` record pattern, which is harmless and additive)
recordPatFieldsFor TRBrace = pure ([], False)
recordPatFieldsFor _ = do
  f <- recordPatField
  t <- peekP
  recordPatFieldsRest f t

recordPatFieldsRest : RecPatField -> Token -> Parser (List RecPatField, Bool)
recordPatFieldsRest f TComma = do
  advance
  fr <- recordPatFields
  pure (consField f fr)
recordPatFieldsRest f _ = pure ([f], False)

consField : RecPatField -> (List RecPatField, Bool) -> (List RecPatField, Bool)
consField f (fs, rest) = (f::fs, rest)

recordPatField : Parser RecPatField
recordPatField = do
  name <- identNameP
  t <- peekP
  recordPatFieldRest name t

recordPatFieldRest : String -> Token -> Parser RecPatField
recordPatFieldRest name TEqual = do
  advance
  p <- parsePat
  pure (RecPatField name (Some p))
recordPatFieldRest name _ = pure (RecPatField name None)

-- A reserved keyword sitting where a pattern-variable / identifier is expected is
-- ALWAYS an error — no keyword starts a legal pattern — and the generic "expected
-- pattern" (or a downstream layout/`: or =` complaint, once `many`/`orElse` has
-- swallowed the recoverable failure) hides the real cause: the NAME is reserved.
-- `reservedIdentKeyword` returns the SOURCE SPELLING of any lowercase-lexeme
-- keyword token (the full `keywordOrIdent` table in lexer.mdk — the identifiers a
-- user would plausibly try as a name), or None for a structural token (`=`, `(`,
-- `,`, …) whose presence is the ordinary end-of-pattern signal that MUST stay a
-- recoverable `failP` so `many parseParamPat` / list-cons parsing terminates.
-- `mut`/`record`/`function`/`with` are listed for a complete enumeration of the
-- table but never reach this arm on the loader/user-facing path (`parseResult`/
-- `parseLocatedResult`): a pre-grammar token scan —`letMutRemovedMsg` etc.,
-- ~parser.mdk:4108— preempts them there. The narrower internal `parse`/
-- `parseLocated` entry (self-typecheck tool) runs no such scan, so the arm can
-- fire for them — harmless, since none is ever a legal identifier under any
-- channel.
-- ⚠️ `let`/`if`/`then`/`else`/`rec` are DELIBERATELY absent (→ None → recoverable
-- "expected pattern"): `if` legitimately follows a pattern as a match-arm GUARD
-- (`pat if cond => body`) and `rec` legitimately follows `let` (`let rec go = …`),
-- so `many parsePatAtom` / the let-binder path MUST stay recoverable at them (a
-- fatal here miscompiles the compiler's own guarded arms and every `let rec`); the
-- others are implausible as identifiers and kept generic so existing handling
-- never regresses.
reservedIdentKeyword : Token -> Option String
reservedIdentKeyword TWith = Some "with"
reservedIdentKeyword TMut = Some "mut"
reservedIdentKeyword TIn = Some "in"
reservedIdentKeyword TMatch = Some "match"
reservedIdentKeyword TData = Some "data"
reservedIdentKeyword TRecord = Some "record"
reservedIdentKeyword TInterface = Some "interface"
reservedIdentKeyword TDefault = Some "default"
reservedIdentKeyword TImpl = Some "impl"
reservedIdentKeyword TImport = Some "import"
reservedIdentKeyword TExport = Some "export"
reservedIdentKeyword TPublic = Some "public"
reservedIdentKeyword TWhere = Some "where"
reservedIdentKeyword TOf = Some "of"
reservedIdentKeyword TDo = Some "do"
reservedIdentKeyword TAs = Some "as"
reservedIdentKeyword TExtern = Some "extern"
reservedIdentKeyword TRequires = Some "requires"
reservedIdentKeyword TDeriving = Some "deriving"
reservedIdentKeyword TType = Some "type"
reservedIdentKeyword TNewtype = Some "newtype"
reservedIdentKeyword TProp = Some "prop"
reservedIdentKeyword TTest = Some "test"
reservedIdentKeyword TBench = Some "bench"
reservedIdentKeyword TEffect = Some "effect"
reservedIdentKeyword TFunction = Some "function"
reservedIdentKeyword _ = None

reservedKeywordMsg : String -> String
reservedKeywordMsg name = "`\{name}` is a reserved keyword — it can't be used as a variable or pattern name. Rename it (e.g. `\{name}_`)."

-- Committed (`fatalP`) so the message reaches the user through the enclosing
-- `many`/`orElse` (which discard a recoverable `PErr`) — the same channel
-- `intLitTooBigMsg` uses.  A structural token stays a recoverable `failP`.
reservedOrPatFail : Token -> Parser Pat
reservedOrPatFail t = match reservedIdentKeyword t
  Some name => fatalP (reservedKeywordMsg name)
  None => failP "expected pattern"

parsePatAtom : Parser Pat
parsePatAtom = do
  t <- peekP
  match t
    TIdent x => emit (PVar x)
    TUnderscore => emit PWild
    TInt n _ if isIntMinLit n => fatalP intLitTooBigMsg
    TInt n _ => intPatRest (LInt n)
    TMinus => negIntPat
    TMinusTight => negIntPat
    TFloat f => emit (PLit (LFloat f))
    TString s => emit (PLit (LString s))
    TChar s => charPatRest (LChar s)
    TUpper c => do
      advance
      t2 <- peekP
      upperAtomRest c t2
    TLParen => parsePatParen
    TLBracket => parsePatList
    _ => reservedOrPatFail t

-- atom-level uppercase: a record pattern `C { … }` or a bare nullary ctor `C`
-- (an *applied* ctor `C p…` needs parens at atom level, like the OCaml grammar).
-- Mirrors lib/parser.mly's `pat_atom: UPPER | UPPER LBRACE record_pat_fields RBRACE`.
upperAtomRest : String -> Token -> Parser Pat
upperAtomRest c TLBrace = recordPat c
upperAtomRest c _ = pure (PCon c [])

-- A function-definition parameter: a `pat_atom`, plus the `@` as-pattern
-- (`x@atom`).  Mirrors lib/parser.mly's `param_pat = pat_atom | IDENT AS_AT
-- pat_atom`.  `orElse` backtracks, so a plain-ident / non-`@` param falls
-- through to parsePatAtom.
parseParamPat : Parser Pat
parseParamPat = orElse parseParamAsPat parsePatAtom

parseParamAsPat : Parser Pat
parseParamAsPat = do
  x <- identNameP
  expectTok TAsAt
  sub <- parsePatAtom
  pure (PAs x sub)

-- an int literal pattern, or a range pattern `lo..hi` / `lo..=hi`
intPatRest : Lit -> Parser Pat
intPatRest lo = do
  advance
  t <- peekP
  rngPatRest lo intBound t

-- a negative int literal pattern `-N`, or a negative-bound range `-N..hi`
-- Mirrors OCaml grammar: only `MINUS INT` followed by `..` or `..=` is valid;
-- a bare `-1` literal pattern is not accepted (consistent with OCaml parser).
negIntPat : Parser Pat
negIntPat = do
  advance
  t <- peekP
  match t
    TInt n _ => negIntRng (LInt (negate n))
    _ => failP "expected integer after -"
-- consume MINUS

-- After parsing MINUS INT, require a `..` or `..=` (range is mandatory).
negIntRng : Lit -> Parser Pat
negIntRng lo = do
  advance
  t <- peekP
  match t
    TDotDot => do
      advance
      hi <- intBound
      pure (PRng lo hi False)
    TDotDotEq => do
      advance
      hi <- intBound
      pure (PRng lo hi True)
    _ => failP "expected .. or ..= after negative range bound"
-- consume INT

charPatRest : Lit -> Parser Pat
charPatRest lo = do
  advance
  t <- peekP
  rngPatRest lo charBound t

rngPatRest : Lit -> Parser Lit -> Token -> Parser Pat
rngPatRest lo bound TDotDot = do
  advance
  hi <- bound
  pure (PRng lo hi False)
rngPatRest lo bound TDotDotEq = do
  advance
  hi <- bound
  pure (PRng lo hi True)
rngPatRest lo _ _ = pure (PLit lo)

intBound : Parser Lit
intBound = do
  t <- peekP
  intBoundFor t

intBoundFor : Token -> Parser Lit
intBoundFor (TInt n _)
  | isIntMinLit n = fatalP intLitTooBigMsg
intBoundFor (TInt n _) = emit (LInt n)
intBoundFor TMinus = do
  advance
  t <- peekP
  match t
    TInt n _ => emit (LInt (negate n))
    _ => failP "expected integer after - in range bound"
intBoundFor TMinusTight = do
  advance
  t <- peekP
  match t
    TInt n _ => emit (LInt (negate n))
    _ => failP "expected integer after - in range bound"
intBoundFor _ = failP "expected int range bound"

charBound : Parser Lit
charBound = do
  t <- peekP
  charBoundFor t

charBoundFor : Token -> Parser Lit
charBoundFor (TChar s) = emit (LChar s)
charBoundFor _ = failP "expected char range bound"

tuplePatOrSingle : List Pat -> Pat
tuplePatOrSingle [p] = p
tuplePatOrSingle ps = PTuple ps

parsePatParen : Parser Pat
parsePatParen = do
  expectTok TLParen
  t <- peekP
  patParenFor t

patParenFor : Token -> Parser Pat
patParenFor TRParen = emit (PLit LUnit)
patParenFor _ = do
  ps <- sepBy1 parsePat (expectTok TComma)
  optTrailingCommaTuple ps
  expectTok TRParen
  pure (tuplePatOrSingle ps)

parsePatList : Parser Pat
parsePatList = do
  expectTok TLBracket
  t <- peekP
  patListFor t

patListFor : Token -> Parser Pat
patListFor TRBracket = emit (PList [])
patListFor _ = do
  ps <- sepBy1 parsePat (expectTok TComma)
  optTrailingComma
  expectTok TRBracket
  pure (PList ps)

-- ── Types ───────────────────────────────────────────────────────────────
-- a full type is a function/effect type, optionally prefixed by a constraint
-- list: `C a => ty`.  The constraint LHS is itself parsed as a ty_fun and
-- reinterpreted by `extractConstraints` below: a `TyApp` spine bottoming at a
-- `TyCon` head → `Constraint I args` at ANY arity; `TyTuple` → many.
-- ⚠️ It reads the WHOLE spine on purpose.  Matching only one level
-- (`TyApp (TyCon I) a`) silently dropped every >=2-arg constraint — `Ix a i` is
-- `TyApp (TyApp (TyCon Ix) a) i`, whose outer TyApp holds a TyApp, not a TyCon,
-- so it fell through to `_ = []` and the constraint vanished at exit 0 (#604).
parseTy : Parser Ty
parseTy = do
  lhs <- parseTyFun
  orElse (constraintTail lhs) (pure lhs)

constraintTail : Ty -> Parser Ty
constraintTail lhs = do
  expectTok TFatArrow
  rhs <- parseTy
  pure (TyConstrained (extractConstraints lhs) rhs)

extractConstraints : Ty -> List Constraint
extractConstraints (TyApp f a) = match tyAppSpine (TyApp f a)
  Some (iface, args) => [Constraint iface args]
  None => []
extractConstraints (TyCon iface _) = [Constraint iface []]
extractConstraints (TyTuple cs) = concatMapC cs
extractConstraints _ = []

-- `Ix a i` parses as a left-nested TyApp spine (TyApp (TyApp (TyCon Ix) a) i),
-- so a constraint head must be FLATTENED, not matched one-arg-deep: matching only
-- `TyApp (TyCon iface _) arg` silently DROPPED every constraint of arity >= 2 (it
-- fell through to the `_ = []` arm), leaving `TyConstrained [] ty` — a signature
-- whose constraints do not exist, which typecheck then never enforced and the
-- printer rendered as `() => ty`, source that does not parse (#604).  Recurse the
-- whole spine rather than adding a 2-arg arm: that is the same trap one width over.
tyAppSpine : Ty -> Option (String, List Ty)
tyAppSpine t = tyAppSpineAcc t []

-- descends the spine outermost-first, prepending each argument, so the accumulator
-- arrives in source order at the TyCon head (`Ix a i` -> ("Ix", [a, i])).
tyAppSpineAcc : Ty -> List Ty -> Option (String, List Ty)
tyAppSpineAcc (TyCon iface _) acc = Some (iface, acc)
tyAppSpineAcc (TyApp f a) acc = tyAppSpineAcc f (a::acc)
tyAppSpineAcc _ _ = None

concatMapC : List Ty -> List Constraint
concatMapC [] = []
concatMapC (t::rest) = extractConstraints t ++ concatMapC rest

parseTyFun : Parser Ty
parseTyFun = do
  t <- peekP
  tyFor t

tyFor : Token -> Parser Ty
tyFor TLt = parseEffectTy
tyFor _ = do
  left <- parseTyApp
  orElse (tyArrowTail left) (pure left)

-- `< labels? (| tail)? > ty` — an effect-annotated type.  A bare lowercase ident
-- inside the angles is the tail var (no labels), e.g. `<e> a`.
parseEffectTy : Parser Ty
parseEffectTy = do
  expectTok TLt
  body <- effectBody
  expectTok TGt
  inner <- parseTy
  pure (mkEffect body inner)

mkEffect : (List (String, Option String), Option String) -> Ty -> Ty
mkEffect (labels, tail) inner = TyEffect labels tail inner

effectBody : Parser (List (String, Option String), Option String)
effectBody = do
  t <- peekP
  effectBodyFor t

effectBodyFor : Token -> Parser (List (String, Option String), Option String)
effectBodyFor (TUpper _) = do
  labels <- sepBy1 effAtomP (expectTok TComma)
  tail <- pipeTail
  pure (labels, tail)
effectBodyFor (TIdent _) = do
  v <- identNameP
  pure ([], Some v)
effectBodyFor _ = pure ([], None)

-- a row atom is a label with an optional Prefix-pattern param:
-- `Foo` (atomic), `Net "a.com/*"` (written param), or `Net _` (an inferred
-- hole — filled at each call site by the known-prefix analysis, v2 Stage 2b).
effAtomP : Parser (String, Option String)
effAtomP = do
  l <- upperNameP
  p <- effParamP
  pure (l, p)

effParamP : Parser (Option String)
effParamP = do
  t <- peekP
  t2 <- peek2P
  effParamDispatch t t2

-- WS-4: a `TUpper` axis-name immediately followed by `TEqual` (`Host=`) starts a
-- PRODUCT param (keyword-axes, Option A).  Otherwise fall through to the existing
-- single-domain clauses (string / hole / brace-set / none).  This is the only
-- ambiguity point: a bare `TUpper` with NO following `=` is the next comma-less
-- atom — but atoms are comma-SEPARATED, so a label-juxtaposed upper can only be a
-- product axis; the `= ` lookahead distinguishes it cleanly with zero collision.
effParamDispatch : Token -> Token -> Parser (Option String)
effParamDispatch (TUpper _) TEqual = productParamP
effParamDispatch t _ = effParamFor t

-- parse `Host="…" Method={…} …` (space-separated axes; loop while peek is an
-- upper-name followed by `=`).  Encode into the carrier sentinel `@P{…;…}`.
productParamP : Parser (Option String)
productParamP = do
  axes <- productAxes
  pure (Some (encodeProductParam axes))

productAxes : Parser (List (String, String))
productAxes = do
  a <- productAxis
  rest <- productAxesMore
  pure (a::rest)

productAxesMore : Parser (List (String, String))
productAxesMore = do
  t <- peekP
  t2 <- peek2P
  productAxesMoreFor t t2

productAxesMoreFor : Token -> Token -> Parser (List (String, String))
productAxesMoreFor (TUpper _) TEqual = productAxes
productAxesMoreFor _ _ = pure []

-- one `Axis=val` axis: val is `"…"` (Prefix) or `{a,b}` (Set).  Returns the
-- axis name and the per-axis carrier value (`"…"` kept quoted; `{a,b}` re-encoded).
productAxis : Parser (String, String)
productAxis = do
  name <- upperNameP
  expectTok TEqual
  v <- productAxisVal
  pure (name, v)

productAxisVal : Parser String
productAxisVal = do
  t <- peekP
  productAxisValFor t

productAxisValFor : Token -> Parser String
productAxisValFor (TString s) = do
  advance
  pure ("\"" ++ s ++ "\"")  -- Prefix axis: keep quoted for the decoder
productAxisValFor TLBrace = do
  expectTok TLBrace
  elems <- sepBy1 stringLitP (expectTok TComma)
  expectTok TRBrace
  pure (encodeSetParam elems)  -- Set axis: `{a,b}` (same as the Set carrier)
productAxisValFor _ = failP "expected product axis value (\"prefix\" or {set})"

effParamFor : Token -> Parser (Option String)
effParamFor (TString s) = do
  advance
  pure (Some s)
effParamFor TUnderscore = do
  advance
  pure (Some "_")  -- v2 Stage 2b inferred hole (`<Net _>`)
effParamFor TLBrace = do
  -- v2 WS-3 Set-domain literal `<Foo {"a", "b"}>`.  Encode the element strings
  -- into the existing `Option String` carrier as `{a,b}` (sentinel `{` prefix);
  -- `atomOfWritten`/`decodeSetParam` (typecheck) decode it.  This keeps the
  -- carrier type unchanged ⇒ no `TyEffect` AST ripple.
  expectTok TLBrace
  elems <- sepBy1 stringLitP (expectTok TComma)
  expectTok TRBrace
  pure (Some (encodeSetParam elems))
effParamFor _ = pure None

-- join Set elements into the `{a,b,c}` carrier form (commas separate; Set
-- authority tokens contain no commas/braces).
encodeSetParam : List String -> String
encodeSetParam elems = "{" ++ joinComma elems ++ "}"

-- WS-4: encode product axes into the carrier sentinel `@P{Axis=val;Axis=val}`
-- (mirror of `encodeSetParam`; `decodeProductParam` in typecheck.mdk decodes it).
-- Each val is already in its per-axis carrier form (`"prefix"` or `{a,b}`).  The
-- sentinel `@P{` prefix + `;` separator round-trips through the `Option String`
-- carrier with no AST `TyEffect` ripple.
encodeProductParam : List (String, String) -> String
encodeProductParam axes = "@P{" ++ joinSemi (map encodeAxis axes) ++ "}"

encodeAxis : (String, String) -> String
encodeAxis (name, v) = "\{name}=\{v}"

joinSemi : List String -> String
joinSemi xs = joinWith ";" xs

joinComma : List String -> String
joinComma xs = joinWith "," xs

pipeTail : Parser (Option String)
pipeTail = do
  t <- peekP
  pipeTailFor t

pipeTailFor : Token -> Parser (Option String)
pipeTailFor TPipe = do
  advance
  v <- identNameP
  pure (Some v)
pipeTailFor _ = pure None

upperNameP : Parser String
upperNameP = do
  t <- peekP
  upperNameFor t

upperNameFor : Token -> Parser String
upperNameFor (TUpper c) = emit c
upperNameFor _ = failP "expected effect label"

tyArrowTail : Ty -> Parser Ty
tyArrowTail left = do
  expectTok TArrow
  t <- peekP
  indented <- tyArrowSkipLayout t
  right <- parseTy
  when
    indented
    (do
      skipNewlines
      expectTok TDedent)
  pure (TyFun left right)

-- Skip NEWLINE or INDENT that can follow a trailing `->` in a type signature.
-- Returns True if an INDENT was consumed (caller must then consume the matching DEDENT).
tyArrowSkipLayout : Token -> Parser Bool
tyArrowSkipLayout TNewline = do
  advance
  pure False
tyArrowSkipLayout TIndent = do
  advance
  pure True
tyArrowSkipLayout _ = pure False

parseTyApp : Parser Ty
parseTyApp = do
  head <- parseTyAtom
  args <- many parseTyAtom
  pure (tyApplyAll head args)

tyApplyAll : Ty -> List Ty -> Ty
tyApplyAll head [] = head
tyApplyAll head (a::rest) = tyApplyAll (TyApp head a) rest

parseTyAtom : Parser Ty
parseTyAtom = do
  t <- peekP
  match t
    TUpper c => do
      s <- getPos
      advance
      q <- getPos
      pure (TyCon c (Some (locOfSpan s q)))
    TIdent v => emit (TyVar v)
    TLParen => parseTyParen
    _ => failP "expected type atom"

tyTupleOrSingle : List Ty -> Ty
tyTupleOrSingle [t] = t
tyTupleOrSingle ts = TyTuple ts

parseTyParen : Parser Ty
parseTyParen = do
  expectTok TLParen
  t <- peekP
  parseTyParenBody t

-- A leading comma right after `(` can only be the bare tuple type constructor
-- `(,)`/`(,,)`/… (arities 2–5) — a normal parenthesized/tuple type always starts
-- with a type atom.  Everything else is the existing `(a)` / `(a, b)` / `(a -> b)`
-- path.
parseTyParenBody : Token -> Parser Ty
parseTyParenBody TComma = parseTupleCtorTail 0
parseTyParenBody _ = do
  ts <- sepBy1 parseTy (expectTok TComma)
  optTrailingCommaTuple ts
  expectTok TRParen
  pure (tyTupleOrSingle ts)

-- Count the commas of a bare tuple constructor `( , , … )`; arity = commas + 1.
-- Lowers to `TyCon "__tupleN__"`, the same dispatch tag typecheck uses
-- (`tupleHeadTagTc`), so the unsaturated head can bind a higher-kinded class
-- param (`impl Bimappable (,)`).
parseTupleCtorTail : Int -> Parser Ty
parseTupleCtorTail commas = do
  t <- peekP
  tupleCtorTailFor commas t

tupleCtorTailFor : Int -> Token -> Parser Ty
tupleCtorTailFor commas TComma = do
  advance
  parseTupleCtorTail (commas + 1)
tupleCtorTailFor commas TRParen = do
  advance
  tupleCtorTyOfArity (commas + 1)
tupleCtorTailFor _ _ = failP "expected , or ) in tuple type constructor"

tupleCtorTyOfArity : Int -> Parser Ty
tupleCtorTyOfArity n =
  if n >= 2 && n <= 5 then
    pure (TyCon (tupleCtorTyName n) None)
  else
    failP "tuple type constructor arity must be 2..5"

tupleCtorTyName : Int -> String
tupleCtorTyName 2 = "__tuple2__"
tupleCtorTyName 3 = "__tuple3__"
tupleCtorTyName 4 = "__tuple4__"
tupleCtorTyName 5 = "__tuple5__"
tupleCtorTyName _ = "__tuple0__"

-- ── Declarations + program ──────────────────────────────────────────────
-- top-level dispatch.  `export`/`public export` are prefixes: `export` sets
-- is_pub on a non-data decl (or DataAbstract on data/record); `public export`
-- yields DataPublic.  `import`/`export import` → DUse; `extern` → DExtern.
parseDecl : Parser Decl
parseDecl = do
  t <- peekP
  match t
    TImport => parseImport False
    TExport => afterExport
    TPublic => afterPublic
    TData => parseData VisPrivate
    TExtern => parseExtern False
    TProp => parseProp False
    TTest => parseTest False
    TBench => parseBench False
    TEffect => parseEffect False
    TInterface => parseInterface False False
    TImpl => parseImpl False
    TDefault => afterDefault False
    TType => parseTypeAlias False
    TNewtype => parseNewtype False
    TLet => parseLetGroupDecl False
    TAt => parseAttrib
    _ => parseFunOrSig False

-- `default` prefixes an interface (marks its default methods).  `default impl`
-- has been removed — afterDefaultFor surfaces a located hint for it.
afterDefault : Bool -> Parser Decl
afterDefault pub = do
  expectTok TDefault
  skipNewlines
  t <- peekP
  afterDefaultFor pub t

afterDefaultFor : Bool -> Token -> Parser Decl
afterDefaultFor pub TInterface = parseInterface pub True
afterDefaultFor _ TImpl = failP defaultImplRemovedMsg
afterDefaultFor _ _ = failP "expected interface after default"

afterExport : Parser Decl
afterExport = do
  expectTok TExport
  skipNewlines
  t <- peekP
  match t
    TImport => parseImport True
    TData => parseData VisAbstract
    TExtern => parseExtern True
    TProp => parseProp True
    TTest => parseTest True
    TBench => parseBench True
    TEffect => parseEffect True
    TInterface => parseInterface True False
    TImpl => parseImpl True
    TDefault => afterDefault True
    TType => parseTypeAlias True
    TNewtype => parseNewtype True
    TLet => parseLetGroupDecl True
    _ => parseFunOrSig True

afterPublic : Parser Decl
afterPublic = do
  pubPos <- getPos
  expectTok TPublic
  skipNewlines
  expectTok TExport
  skipNewlines
  t <- peekP
  afterPublicFor pubPos t

-- `public` is meaningful only in front of `data` (it selects `VisPublic`
-- instead of the plain-`export` `VisAbstract`); anything else is a user
-- mistake, not a grammar gap.  The error is reported at `pubPos` — the
-- `public` token itself, captured before it was consumed — rather than at
-- whatever token follows `public export`, so the caret lands on the actual
-- problem and `parseErrHelpFix` (`compiler/driver/diagnostics.mdk`) can offer
-- a `fix` that deletes exactly the `public` token at that same location.
afterPublicFor : Int -> Token -> Parser Decl
afterPublicFor _ TData = parseData VisPublic
afterPublicFor pubPos _ =
  fatalAtP "`public` only applies to `data` declarations" pubPos

parseFunOrSig : Bool -> Parser Decl
parseFunOrSig pub = do
  name <- identNameP
  params <- many parseParamPat
  t <- peekP
  match t
    TColon => do
      advance
      ty <- parseTy
      skipNewlines
      pure (DTypeSig pub name ty)
    TEqual => do
      advance
      body <- parseBody
      skipNewlines
      pure (DFunDef pub name params body)
    TIndent => do
      advance
      arms <- parseGuardArms
      body <- guardArmsWhereOpt arms
      expectTok TDedent
      skipNewlines
      pure (DFunDef pub name params body)
    TPipe => do
      arm <- parseGuardArm
      skipNewlines
      pure (DFunDef pub name params (EGuards [arm]))
    _ => failP "expected : or = in definition"

-- ── extern + import declarations ─────────────────────────────────────────
parseExtern : Bool -> Parser Decl
parseExtern pub = do
  expectTok TExtern
  name <- externName
  expectTok TColon
  ty <- parseTy
  skipNewlines
  pure (DExtern pub name ty)

-- ── type alias / newtype / top-level let-group / attributes ──────────────
-- `type Name a… = ty`
parseTypeAlias : Bool -> Parser Decl
parseTypeAlias pub = do
  expectTok TType
  name <- upperNameP
  params <- many lowerNameP
  expectTok TEqual
  ty <- parseTy
  skipNewlines
  pure (DTypeAlias pub name params ty)

-- `newtype Name a… = Con ty [deriving (…)]`
parseNewtype : Bool -> Parser Decl
parseNewtype pub = do
  expectTok TNewtype
  name <- upperNameP
  params <- many lowerNameP
  expectTok TEqual
  con <- upperNameP
  fty <- parseTy
  derives <- derivingClause
  skipNewlines
  pure (DNewtype pub name params con fty derives)

-- top-level `let rec f a… = body` → DLetGroup with a single binding.
-- Mutual-recursion grouping via `with` has been removed — each recursive
-- top-level binding is its own `let rec`.
parseLetGroupDecl : Bool -> Parser Decl
parseLetGroupDecl pub = do
  expectTok TLet
  expectTok TRec
  c <- letRecDeclClause
  skipNewlines
  pure (DLetGroup pub (coalesceClauses [c]))

letRecDeclClause : Parser (String, List Pat, Expr)
letRecDeclClause = do
  name <- identNameP
  pats <- many parseParamPat
  expectTok TEqual
  body <- parseBody
  pure (name, pats, body)

-- declaration attribute `@deprecated "msg"` / `@inline` / `@must_use` wrapping
-- the following decl (mirrors lib/parser.mly `AT IDENT [STRING] newlines decl`).
parseAttrib : Parser Decl
parseAttrib = do
  expectTok TAt
  name <- identNameP
  t <- peekP
  attr <- attrArg name t
  skipNewlines
  inner <- parseDecl
  pure (DAttrib [attr] inner)

attrArg : String -> Token -> Parser Attr
attrArg name (TString msg) = do
  advance
  pure (mkAttr name (Some msg))
attrArg name _ = pure (mkAttr name None)

mkAttr : String -> Option String -> Attr
mkAttr "deprecated" (Some msg) = AttrDeprecated msg
mkAttr "must_use" _ = AttrMustUse
mkAttr _ _ = AttrInline

externName : Parser String
externName = do
  t <- peekP
  externNameFor t

externNameFor : Token -> Parser String
externNameFor (TIdent x) = emit x
externNameFor (TUpper x) = emit x
externNameFor _ = failP "expected extern name"

parseImport : Bool -> Parser Decl
parseImport pub = do
  s <- getPos
  expectTok TImport
  quals <- importQuals
  path <- importPathFor quals
  e <- getPos
  noExportedAlias pub path
  skipNewlines
  pure (DUse pub path (locOfSpan s e))

-- An `export import` may NOT be aliased, in either form.  Both would re-export a name
-- that does not exist in the module that actually defines it:
--
--   `export import m as A`        binds `A.name` — names meaningful only against OUR
--                                 private alias, which an importer could not write.
--   `export import m.{a as b}`    would re-export `b`, but a module's export table maps
--                                 (name → defining module) and the real symbol is
--                                 rebuilt from that pair — so `b` would rebuild as
--                                 `m__b`, while the symbol is `m__a`.
--
-- Rejecting is the honest option: an alias is FILE-LOCAL.  Re-export the module
-- (`export import m`) or the member under its own name (`export import m.{a}`), and let
-- the importer alias it.
noExportedAlias : Bool -> UsePath -> Parser Unit
noExportedAlias True (UseAlias _ a) =
  failP
    "`export import … as \{a}` is not allowed — a module alias is file-local (it binds `\{a}.name`, which an importer could not write). Re-export the module itself (`export import m`) and let the importer choose its own alias."
noExportedAlias True (UseGroup _ members) = failIfAliasedMember members
noExportedAlias _ _ = pure ()

failIfAliasedMember : List UseMember -> Parser Unit
failIfAliasedMember [] = pure ()
failIfAliasedMember (m::rest) = match useMemberAlias m
  Some a => failP "`export import` cannot rename a member — re-exporting `\{useMemberOrigin m}` as `\{a}` would export a name its defining module does not have. Re-export it under its own name (`export import m.{\{useMemberOrigin m}}`) and let the importer alias it."
  None => failIfAliasedMember rest

importQuals : Parser (List String)
importQuals = do
  first <- importIdent
  rest <- importQualRest
  pure (first::rest)

importQualRest : Parser (List String)
importQualRest = do
  t <- peekP
  importQualRestFor t

importQualRestFor : Token -> Parser (List String)
importQualRestFor TDot = do
  advance
  x <- importIdent
  rest <- importQualRest
  pure (x::rest)
importQualRestFor _ = pure []

importIdent : Parser String
importIdent = do
  t <- peekP
  importIdentFor t

-- a path component: a lowercase module name, an Uppercase name (e.g.
-- `collections.HashMap`), or a keyword that is legal as a path component
-- (`test`, `record`, `data`, `type`).
importIdentFor : Token -> Parser String
importIdentFor (TIdent x) = emit x
importIdentFor (TUpper x) = emit x
importIdentFor TTest = emit "test"
importIdentFor TRecord = emit "record"
importIdentFor TData = emit "data"
importIdentFor TType = emit "type"
importIdentFor _ = failP "expected import path component"

importPathFor : List String -> Parser UsePath
importPathFor quals = do
  t <- peekP
  importPathForT quals t

importPathForT : List String -> Token -> Parser UsePath
importPathForT quals TDotLBrace = do
  advance
  ms <- sepBy1 importMember (expectTok TComma)
  optTrailingComma
  expectTok TRBrace
  noTrailingAlias "a selective import"
  pure (UseGroup quals ms)
importPathForT quals TDotStar = do
  advance
  noTrailingAlias "a wildcard import"
  pure (UseWild quals)
importPathForT quals TAs = do
  advance
  a <- aliasName
  pure (UseAlias quals a)
importPathForT quals _ = pure (UseName quals)

-- `import m.{a, b} as A` / `import m.* as A` are REJECTED, not silently ignored.
-- Both forms are self-contradictory: the group/wildcard says "bind these names
-- unqualified HERE", the alias says "bind them only under `A.`".  A module alias
-- (`import m as A`) already covers everything the module exports, and a member alias
-- (`import m.{a as b}`) covers renaming a single name — so neither form loses power.
noTrailingAlias : String -> Parser Unit
noTrailingAlias what = do
  t <- peekP
  noTrailingAliasFor what t

noTrailingAliasFor : String -> Token -> Parser Unit
noTrailingAliasFor what TAs =
  failP
    "`as` cannot alias \{what} — write `import m as A` to alias the whole module (then use `A.name`), or `import m.{name as alias}` to rename one member"
noTrailingAliasFor _ _ = pure ()

importMember : Parser UseMember
importMember = do
  s <- getPos
  t <- peekP
  importMemberFor s t

importMemberFor : Int -> Token -> Parser UseMember
importMemberFor s (TIdent x) = do
  advance
  memberAliasOrNot s x False
importMemberFor s (TUpper x) = do
  advance
  withAllOrNot s x
importMemberFor _ _ = failP "expected import member"

withAllOrNot : Int -> String -> Parser UseMember
withAllOrNot s x = do
  t <- peekP
  withAllFor s x t

-- An Uppercase member is a TYPE, CONSTRUCTOR or INTERFACE, and none of those may be
-- aliased.  Impl coherence and constructor identity are resolved on the REAL name
-- globally, so binding one under a local alias would be a silent soundness hole, not a
-- rename.  Reject it here rather than accept-and-ignore.
withAllFor : Int -> String -> Token -> Parser UseMember
withAllFor s x TLParen = do
  advance
  expectTok TDotDot
  expectTok TRParen
  q <- getPos
  noMemberAlias x
  pure (UseMember x True (locOfSpan s q) None)
withAllFor s x _ = do
  q <- getPos
  noMemberAlias x
  pure (UseMember x False (locOfSpan s q) None)

noMemberAlias : String -> Parser Unit
noMemberAlias x = do
  t <- peekP
  noMemberAliasFor x t

noMemberAliasFor : String -> Token -> Parser Unit
noMemberAliasFor x TAs =
  failP
    "`\{x}` is a type or constructor and cannot be aliased — only a value member can be renamed (`import m.{name as alias}`). Import it under its own name."
noMemberAliasFor _ _ = pure ()

-- a value member's optional `as <alias>`: `import m.{a as b}` binds m's `a` under `b`.
memberAliasOrNot : Int -> String -> Bool -> Parser UseMember
memberAliasOrNot s x allCtors = do
  t <- peekP
  memberAliasFor s x allCtors t

memberAliasFor : Int -> String -> Bool -> Token -> Parser UseMember
memberAliasFor s x allCtors TAs = do
  advance
  a <- memberAliasName
  q <- getPos
  pure (UseMember x allCtors (locOfSpan s q) (Some a))
memberAliasFor s x allCtors _ = do
  q <- getPos
  pure (UseMember x allCtors (locOfSpan s q) None)

-- A value member's alias is itself a value name ⇒ lowercase.
memberAliasName : Parser String
memberAliasName = do
  t <- peekP
  memberAliasNameFor t

memberAliasNameFor : Token -> Parser String
memberAliasNameFor (TIdent x) = emit x
memberAliasNameFor (TUpper x) =
  failP
    "a value member's alias must be lowercase — `as \{x}` names a type or constructor"
memberAliasNameFor _ = failP "expected alias name after `as`"

-- A MODULE alias must be Uppercase.  It is referenced as `A.name`, which parses as a
-- field access on `A`; requiring uppercase keeps it unambiguous against `rec.field` on
-- a lowercase local (record fields are accessed with the same `.`).
aliasName : Parser String
aliasName = do
  t <- peekP
  aliasNameFor t

aliasNameFor : Token -> Parser String
aliasNameFor (TUpper x) = emit x
aliasNameFor (TIdent x) =
  failP
    "a module alias must be capitalized — `as \{x}` should be an Uppercase name (it is used as a qualifier, `Alias.name`)"
aliasNameFor _ = failP "expected alias name after `as`"

-- ── prop / test / bench declarations ─────────────────────────────────────
stringLitP : Parser String
stringLitP = do
  t <- peekP
  stringLitFor t

stringLitFor : Token -> Parser String
stringLitFor (TString s) = emit s
stringLitFor _ = failP "expected string literal"

parseProp : Bool -> Parser Decl
parseProp pub = do
  expectTok TProp
  name <- stringLitP
  params <- many propParam
  expectTok TEqual
  body <- parseBody
  skipNewlines
  pure (DProp pub name params body)

propParam : Parser PropParam
propParam = do
  expectTok TLParen
  name <- identNameP
  expectTok TColon
  ty <- parseTy
  expectTok TRParen
  pure (PropParam name ty)

-- `TTest` at a decl head is ambiguous between the two things `test` can mean:
-- the start of a `test "…" = …` block, or an ordinary (but reserved, so
-- illegal) declaration name (`test = 2`, #646).  Capture the keyword's own
-- position BEFORE consuming it, then peek: a string literal confirms the
-- block production and we proceed as before; anything else means the user
-- wrote `test` as a plain name, so report it the same way #532/#630 report
-- every other reserved-word collision — `fatalP` (not `failP`) so the
-- message survives the enclosing `many`'s swallow-and-retry recovery, at the
-- captured `testPos` so the caret lands on `test`, not on whatever token
-- (`=`) happened to be where the string label was expected.
parseTest : Bool -> Parser Decl
parseTest pub = do
  testPos <- getPos
  expectTok TTest
  t <- peekP
  parseTestRest pub testPos t

parseTestRest : Bool -> Int -> Token -> Parser Decl
parseTestRest pub _ (TString _) = do
  name <- stringLitP
  expectTok TEqual
  body <- parseBody
  skipNewlines
  pure (DTest pub name body)
parseTestRest _ testPos _ = fatalAtP (reservedKeywordMsg "test") testPos

parseBench : Bool -> Parser Decl
parseBench pub = do
  expectTok TBench
  name <- stringLitP
  expectTok TEqual
  body <- parseBody
  skipNewlines
  pure (DBench pub name body)

-- `effect Foo` declares a user/platform effect label (Phase 146 gap 2).
-- `effect Foo` (atomic), `effect Net Prefix` (domain-carrying).  The optional
-- domain is a bare UPPER after the label; only `Prefix` is accepted in v2.
parseEffect : Bool -> Parser Decl
parseEffect pub = do
  expectTok TEffect
  name <- upperNameP
  dom <- effDomainP
  skipNewlines
  pure (DEffect pub name dom)

effDomainP : Parser (Option String)
effDomainP = do
  t <- peekP
  effDomainFor t

effDomainFor : Token -> Parser (Option String)
effDomainFor (TUpper d) = do
  advance
  pure (Some d)
effDomainFor _ = pure None

-- ── interface declarations ───────────────────────────────────────────────
parseInterface : Bool -> Bool -> Parser Decl
parseInterface pub isDefault = do
  expectTok TInterface
  name <- upperNameP
  typarams <- many lowerNameP
  supers <- ifaceSuper
  methods <- ifaceBody
  pure
    DInterface {
      pub = pub,
      def = isDefault,
      name = name,
      typarams = typarams,
      supers = supers,
      methods = methods,
    }

-- optional `requires Iface a, …` superclass list
ifaceSuper : Parser (List Super)
ifaceSuper = do
  t <- peekP
  ifaceSuperFor t

ifaceSuperFor : Token -> Parser (List Super)
ifaceSuperFor TRequires = do
  advance
  sepBy1 ifaceSuperEntry (expectTok TComma)
ifaceSuperFor _ = pure []

ifaceSuperEntry : Parser Super
ifaceSuperEntry = do
  name <- upperNameP
  params <- many lowerNameP
  pure (Super name params)

-- `where INDENT members DEDENT` body, or a marker interface (optional where)
ifaceBody : Parser (List IfaceMethod)
ifaceBody = do
  t <- peekP
  ifaceBodyFor t

ifaceBodyFor : Token -> Parser (List IfaceMethod)
ifaceBodyFor TWhere = do
  advance
  t <- peekP
  ifaceWhereBody t
ifaceBodyFor _ = do
  skipNewlines
  pure []

ifaceWhereBody : Token -> Parser (List IfaceMethod)
ifaceWhereBody TIndent = do
  advance
  ms <- ifaceMembers
  expectTok TDedent
  skipNewlines
  pure ms
ifaceWhereBody _ = do
  skipNewlines
  pure []

ifaceMembers : Parser (List IfaceMethod)
ifaceMembers = do
  skipNewlines
  ifaceMembersLoop

ifaceMembersLoop : Parser (List IfaceMethod)
ifaceMembersLoop = orElse ifaceMembersCons (pure [])

ifaceMembersCons : Parser (List IfaceMethod)
ifaceMembersCons = do
  m <- ifaceMember
  skipNewlines
  rest <- ifaceMembersLoop
  pure (m::rest)

-- a method signature `name : ty`, or a default method `name pats = body`
ifaceMember : Parser IfaceMethod
ifaceMember = do
  name <- identNameP
  pats <- many parseParamPat
  t <- peekP
  ifaceMemberRest name pats t

ifaceMemberRest : String -> List Pat -> Token -> Parser IfaceMethod
ifaceMemberRest name _ TColon = do
  advance
  ty <- parseTy
  pure (IfaceMethod name ty None)
ifaceMemberRest name pats TEqual = do
  advance
  body <- parseBody
  pure (IfaceMethod name (TyVar "_") (Some (MethodDefault pats body)))
ifaceMemberRest _ _ _ = failP "expected : or = in interface member"

-- ── impl declarations ────────────────────────────────────────────────────
parseImpl : Bool -> Parser Decl
parseImpl pub = do
  expectTok TImpl
  t <- peekP
  implHead pub t

-- `impl Iface tyargs…`.  (Named impls — `impl name of Iface …` — have been
-- removed; a lowercase head or a stray `of` now yields a clean parse error.)
implHead : Bool -> Token -> Parser Decl
implHead pub (TUpper u) = do
  advance
  implRest pub u
implHead pub (TIdent _) = failP namedImplRemovedMsg
implHead _ _ = failP "expected impl head"

implRest : Bool -> String -> Parser Decl
implRest pub iface = do
  tyargs <- many parseTyAtom
  reqs <- implRequires
  methods <- implBody
  pure
    DImpl {
      pub = pub,
      iface = iface,
      tys = tyargs,
      reqs = reqs,
      methods = methods,
    }

namedImplRemovedMsg : String
namedImplRemovedMsg = "named impls (`impl name of Iface`) have been removed — use a plain `impl Iface` (wrap the type in a newtype for a second instance)"

defaultImplRemovedMsg : String
defaultImplRemovedMsg = "`default impl` has been removed — use a plain `impl` (specialization picks the most-specific instance automatically)"

-- optional `requires Iface tyargs…, …`
implRequires : Parser (List Require)
implRequires = do
  t <- peekP
  implRequiresFor t

implRequiresFor : Token -> Parser (List Require)
implRequiresFor TRequires = do
  advance
  sepBy1 implRequireEntry (expectTok TComma)
implRequiresFor _ = pure []

implRequireEntry : Parser Require
implRequireEntry = do
  iface <- upperNameP
  tys <- many parseTyAtom
  pure (Require iface tys)

implBody : Parser (List ImplMethod)
implBody = do
  t <- peekP
  implBodyFor t

implBodyFor : Token -> Parser (List ImplMethod)
implBodyFor TWhere = do
  advance
  t <- peekP
  implWhereBody t
implBodyFor _ = do
  skipNewlines
  pure []

implWhereBody : Token -> Parser (List ImplMethod)
implWhereBody TIndent = do
  advance
  ms <- implMethods
  expectTok TDedent
  skipNewlines
  pure ms
implWhereBody _ = do
  skipNewlines
  pure []

implMethods : Parser (List ImplMethod)
implMethods = do
  skipNewlines
  implMethodsLoop

implMethodsLoop : Parser (List ImplMethod)
implMethodsLoop = orElse implMethodsCons (pure [])

implMethodsCons : Parser (List ImplMethod)
implMethodsCons = do
  m <- implMethod
  skipNewlines
  rest <- implMethodsLoop
  pure (m::rest)

-- impl methods are `name pats = body` (multi-clause = repeated entries)
implMethod : Parser ImplMethod
implMethod = do
  name <- identNameP
  pats <- many parseParamPat
  expectTok TEqual
  body <- parseBody
  pure (ImplMethod name pats body)

-- a Haskell-style `where` scoping over ALL guard arms (it sits at the guards'
-- indentation, inside their INDENT block): `guards WHERE INDENT bindings DEDENT
-- newlines` → ELetGroup wrapping the EGuards.  Mirrors lib/parser.mly line 406.
guardArmsWhereOpt : List GuardArm -> Parser Expr
guardArmsWhereOpt arms = do
  t <- peekP
  guardArmsWhereFor arms t

guardArmsWhereFor : List GuardArm -> Token -> Parser Expr
guardArmsWhereFor arms TWhere = do
  advance
  expectTok TIndent
  binds <- parseWhereBindings
  expectTok TDedent
  skipNewlines
  pure (ELetGroup (coalesceClauses binds) (EGuards arms))
guardArmsWhereFor arms _ = pure (EGuards arms)

-- function guards: an INDENT block of `| guard, … = body` arms
parseGuardArms : Parser (List GuardArm)
parseGuardArms = do
  skipNewlines
  guardArmsLoop

guardArmsLoop : Parser (List GuardArm)
guardArmsLoop = orElse guardArmsCons (pure [])

guardArmsCons : Parser (List GuardArm)
guardArmsCons = do
  a <- parseGuardArm
  skipNewlines
  rest <- guardArmsLoop
  pure (a::rest)

parseGuardArm : Parser GuardArm
parseGuardArm = do
  expectTok TPipe
  guards <- sepBy1 parseGuard (expectTok TComma)
  expectTok TEqual
  body <- parseBody
  pure (GuardArm guards body)

-- A guard qualifier parses at the `expr_or` level (mirrors the reference
-- `guard_qual`): NOT full `parseExpr`, so a trailing `=>` in a match-arm guard
-- isn't swallowed as a lambda, and `<-`/`,` stay as the bind/separator tokens.
parseGuard : Parser Guard
parseGuard = do
  e <- parseOr
  t <- peekP
  guardFor e t

guardFor : Expr -> Token -> Parser Guard
guardFor e TLArrow = do
  advance
  rhs <- parseOr
  pure (GBind (exprToPat e) rhs)
guardFor e _ = pure (GBool e)

-- ── data / record declarations ──────────────────────────────────────────
lowerNameP : Parser String
lowerNameP = do
  t <- peekP
  lowerNameFor t

lowerNameFor : Token -> Parser String
lowerNameFor (TIdent x) = emit x
lowerNameFor _ = failP "expected type parameter"

parseData : DataVis -> Parser Decl
parseData vis = do
  expectTok TData
  name <- upperNameP
  params <- many lowerNameP
  bodyAndDerives <- dataBody name
  let variants = fst bodyAndDerives
  let blockDerives = snd bodyAndDerives
  outerDerives <- derivingClause
  skipNewlines
  pure (DData
    vis
    name
    params
    variants
    (combineDerives blockDerives outerDerives))
-- block form may carry `deriving (…)` INSIDE the INDENT span (own line or
-- trailing the last constructor); that is captured by dataBody.  The inline
-- form leaves derives empty here and the trailing derivingClause picks it up.

-- block-form deriving (inside the INDENT) and inline-form deriving (after the
-- DEDENT) are mutually exclusive in practice; prefer whichever is non-empty.
combineDerives : List DeriveRef -> List DeriveRef -> List DeriveRef
combineDerives [] outer = outer
combineDerives block _ = block

-- inline (`= …`) or block (`INDENT = … DEDENT`) variant list.  Returns the
-- variants paired with any deriving names found INSIDE a block body (empty for
-- the inline form).
dataBody : String -> Parser (List Variant, List DeriveRef)
dataBody tyName = do
  t <- peekP
  dataBodyFor tyName t

dataBodyFor : String -> Token -> Parser (List Variant, List DeriveRef)
dataBodyFor tyName TEqual = do
  advance
  t <- peekP
  dataAfterEq tyName t
dataBodyFor tyName TIndent = do
  advance
  expectTok TEqual
  vs <- dataVariantsN tyName
  derives <- derivingClause
  skipNewlines
  expectTok TDedent
  pure (vs, derives)
-- `deriving (…)` may sit INSIDE the block (the lexer keeps the indented
-- deriving line within the INDENT/DEDENT), so consume it before the DEDENT.
-- derivingClause stops at the RPAREN; skip its trailing NEWLINE so the DEDENT
-- is the next token.

dataBodyFor _ _ = pure ([], [])

-- After a header-line `=` (inline `data Foo = …`) the body is EITHER an inline
-- variant list on the same line, OR — the new multiline form — a line-final `=`
-- followed by an indented block whose variants each carry a leading `|`:
--   data Foo =
--     | Bar
--     | Baz
-- An INDENT here means the latter (the `=` was line-final).  The leading `|`
-- before the first variant is optional (lenient); the formatter always emits it.
-- `deriving (…)` inside the block is consumed before the DEDENT, mirroring the
-- old `TIndent` block form.
dataAfterEq : String -> Token -> Parser (List Variant, List DeriveRef)
dataAfterEq tyName TIndent = do
  advance
  skipNewlines
  _ <- optPipe
  vs <- dataVariantsN tyName
  derives <- derivingClause
  skipNewlines
  expectTok TDedent
  pure (vs, derives)
dataAfterEq tyName _ = do
  vs <- dataVariantsN tyName
  pure (vs, [])

-- Consume a leading `|` if present (the new multiline form's per-variant pipe
-- also prefixes the first variant); a no-op otherwise.
optPipe : Parser Unit
optPipe = do
  t <- peekP
  optPipeFor t

optPipeFor : Token -> Parser Unit
optPipeFor TPipe = do
  advance
  pure ()
optPipeFor _ = pure ()

-- Variant list with the tycon name in scope, so the anonymous short form
-- `data X = { … }` (a single brace-group, no ctor name, no `|`) can synthesize
-- a single named constructor whose name is the tycon name (`X`), flagged
-- `nameOmitted = True` so the printer round-trips the short form.  Any other
-- shape falls through to the normal `dataVariants` path.  A leading `{` is the
-- unambiguous trigger — no legal named/positional variant starts with `{`.
dataVariantsN : String -> Parser (List Variant)
dataVariantsN tyName = do
  t <- peekP
  dataVariantsNFor tyName t

dataVariantsNFor : String -> Token -> Parser (List Variant)
dataVariantsNFor tyName TLBrace = do
  fields <- parseNamedFields
  pure [Variant tyName (ConNamed fields True)]
dataVariantsNFor _ _ = dataVariants

dataVariants : Parser (List Variant)
dataVariants = do
  v <- parseVariant
  rest <- variantsRest
  pure (v::rest)

variantsRest : Parser (List Variant)
variantsRest = do
  skipNewlines
  t <- peekP
  variantsRestFor t

variantsRestFor : Token -> Parser (List Variant)
variantsRestFor TPipe = do
  advance
  v <- parseVariant
  rest <- variantsRest
  pure (v::rest)
variantsRestFor _ = pure []

parseVariant : Parser Variant
parseVariant = do
  name <- upperNameP
  payload <- parsePayload
  pure (Variant name payload)

parsePayload : Parser ConPayload
parsePayload = do
  t <- peekP
  payloadFor t

payloadFor : Token -> Parser ConPayload
payloadFor TLBrace = parseNamedPayload
payloadFor _ = do
  tys <- many parseTyAtom
  pure (ConPos tys)

parseNamedPayload : Parser ConPayload
parseNamedPayload = do
  fields <- parseNamedFields
  pure (ConNamed fields False)

-- The brace-group of a named-field payload: `{ f0 : T0, f1 : T1, … }`.  Shared
-- by the explicit-name form (`parseNamedPayload`) and the anonymous short form
-- (`data X = { … }`, `dataAnonVariant`).
parseNamedFields : Parser (List Field)
parseNamedFields = do
  expectTok TLBrace
  fields <- sepBy1 parseField (expectTok TComma)
  optTrailingComma
  expectTok TRBrace
  pure fields

parseField : Parser Field
parseField = do
  name <- identNameP
  expectTok TColon
  t <- parseTy
  pure (Field name t)

-- `deriving (Name, …)`, after the variant/field block; optional
derivingClause : Parser (List DeriveRef)
derivingClause = do
  skipNewlines
  t <- peekP
  derivingFor t

derivingFor : Token -> Parser (List DeriveRef)
derivingFor TDeriving = do
  advance
  expectTok TLParen
  names <- sepBy1 derivedNameP (expectTok TComma)
  expectTok TRParen
  pure names
derivingFor _ = pure []

-- One name in a `deriving (…)` list, wrapped with its own token span so a
-- "cannot derive" diagnostic underlines the NAME.  Real only on the
-- `parseLocated` path (`parse` leaves the loc refs unset → placeholder), the
-- same convention `TyCon`'s `Option Loc` already follows.
derivedNameP : Parser DeriveRef
derivedNameP = do
  s <- getPos
  n <- upperNameP
  q <- getPos
  pure (DeriveRef n (Some (locOfSpan s q)))

-- a decl body is an inline expr, or an INDENT block of statements: a single
-- expression statement unwraps to that expr; anything else becomes an EBlock
parseBody : Parser Expr
parseBody = orElse indentedBody parseBodyExpr

-- an inline body expr, optionally followed by a Haskell-style `where` block:
-- `<expr> INDENT where INDENT bindings DEDENT NEWLINE DEDENT` → ELetGroup
parseBodyExpr : Parser Expr
parseBodyExpr = do
  e <- parseExpr
  orElse (whereEol e) (orElse (whereTail e) (pure e))

-- end-of-line `where` (the `where` sits on the body line):
-- `<expr> WHERE INDENT bindings DEDENT` → ELetGroup
whereEol : Expr -> Parser Expr
whereEol e = do
  expectTok TWhere
  expectTok TIndent
  binds <- parseWhereBindings
  expectTok TDedent
  pure (ELetGroup (coalesceClauses binds) e)

whereTail : Expr -> Parser Expr
whereTail e = do
  expectTok TIndent
  expectTok TWhere
  expectTok TIndent
  binds <- parseWhereBindings
  expectTok TDedent
  skipNewlines
  expectTok TDedent
  pure (ELetGroup (coalesceClauses binds) e)

parseWhereBindings : Parser (List (String, List Pat, Expr))
parseWhereBindings = do
  skipNewlines
  whereBindingsLoop

whereBindingsLoop : Parser (List (String, List Pat, Expr))
whereBindingsLoop = orElse whereBindingsCons (pure [])

whereBindingsCons : Parser (List (String, List Pat, Expr))
whereBindingsCons = do
  b <- parseWhereBinding
  skipNewlines
  rest <- whereBindingsLoop
  pure (b::rest)

parseWhereBinding : Parser (String, List Pat, Expr)
parseWhereBinding = do
  name <- identNameP
  pats <- many parseParamPat
  t <- peekP
  whereBindRest name pats t

whereBindRest : String -> List Pat -> Token -> Parser (String, List Pat, Expr)
-- annotated binding `go : ty = body` (no params only, mirrors let-in / block-let)
whereBindRest name [] TColon = do
  advance
  ty <- parseTy
  expectTok TEqual
  body <- parseExpr
  pure (name, [], EAnnot body ty)
whereBindRest name pats TEqual = do
  advance
  body <- parseExpr
  pure (name, pats, body)
whereBindRest name pats TIndent = do
  advance
  arms <- parseGuardArms
  expectTok TDedent
  pure (name, pats, EGuards arms)
whereBindRest name pats TPipe = do
  arm <- parseGuardArm
  pure (name, pats, EGuards [arm])
whereBindRest _ _ _ = failP "expected where binding body"

-- group CONSECUTIVE same-name bindings into one LetBind (mirrors the reference
-- `coalesce_clauses`), so `go … = …` over several lines becomes one entry
coalesceClauses : List (String, List Pat, Expr) -> List LetBind
coalesceClauses [] = []
coalesceClauses ((name, ps, b)::rest) = coalesceGo name [FunClause ps b] rest

coalesceGo : String -> List FunClause -> List (String, List Pat, Expr) -> List LetBind
coalesceGo name acc [] = [LetBind name (reverseL acc)]
coalesceGo name acc ((n, ps, b)::rest) = coalesceStep name acc n ps b rest

coalesceStep : String -> List FunClause -> String -> List Pat -> Expr -> List (String, List Pat, Expr) -> List LetBind
coalesceStep name acc n ps b rest
  | n == name = coalesceGo name (FunClause ps b :: acc) rest
  | otherwise =
    LetBind name (reverseL acc) :: coalesceGo n [FunClause ps b] rest

indentedBody : Parser Expr
indentedBody = do
  expectTok TIndent
  stmts <- parseStmts
  expectTok TDedent
  pure (blockOrExpr stmts)

blockOrExpr : List DoStmt -> Expr
blockOrExpr [DoExpr e] = e
blockOrExpr stmts = EBlock stmts

-- `do <INDENT stmt block DEDENT>` → a monadic do-block
parseDo : Parser Expr
parseDo = do
  expectTok TDo
  expectTok TIndent
  stmts <- parseStmts
  expectTok TDedent
  pure (EDo stmts)

-- statements, NEWLINE-separated, until the block's DEDENT
-- A statement-let / where RHS, or a lambda body (`lamTailRaw`): a bare-INDENT
-- block (the RHS sits on its own indented line, e.g. `let n =\n    length pairs`
-- or `g x =>\n  g + x`), or an ordinary expression.  Every herald that opens
-- such a block is one `canEndExpr` omits — see LAYOUT-SEMANTICS.md §7.1.
-- Mirrors parser.mly's `expr_no_block` including the
-- `INDENT nonempty_list(stmt) DEDENT` production, which lets a let binding's RHS
-- be an indented block.  Without this the lexer's (correct, oracle-identical)
-- `LET n EQUAL INDENT … DEDENT` stream had no parser rule and failed to parse.
parseRhsExpr : Parser Expr
parseRhsExpr = orElse parseBracketBlock parseExpr

parseStmts : Parser (List DoStmt)
parseStmts = do
  skipNewlines
  stmtsLoop

stmtsLoop : Parser (List DoStmt)
stmtsLoop = orElse stmtsCons (pure [])

stmtsCons : Parser (List DoStmt)
stmtsCons = do
  ss <- parseStmt
  skipNewlines
  rest <- stmtsLoop
  pure (ss ++ rest)

-- one surface statement → one OR MORE DoStmts (an annotated do-bind
-- `x : ty <- e` expands to two: the bind + a shadowing annotated let)
parseStmt : Parser (List DoStmt)
parseStmt = do
  t <- peekP
  stmtFor t

stmtFor : Token -> Parser (List DoStmt)
stmtFor TLet = do
  s <- parseLetStmt
  pure [s]
stmtFor _ = parseExprStmt

-- a `let` statement: `let mut p = e`, function-let `let f a… = e`, plain
-- `let p = e`, let-in (→ DoExpr), or let-else `let p = e else alt`
parseLetStmt : Parser DoStmt
parseLetStmt = do
  expectTok TLet
  t <- peekP
  letKind t

letKind : Token -> Parser DoStmt
-- beta mutability model: `let mut` has been removed — rejected at the parser
-- (see `letMutRemovedMsg`), so no `mut` flag is ever built downstream.
letKind TMut = failP letMutRemovedMsg
letKind TRec = letRecStmt
letKind (TIdent name) = letIdent name
letKind _ = letPat

-- REC-led: block-level `let rec f a… = e [in/else]` (#645). A plain
-- function-let is already self-recursive (`letFunTailFor` always builds an
-- `isRec=True` node), so `rec` here only matters for the zero-param value
-- form (`let rec x = …`, otherwise non-recursive) — but both shapes are
-- accepted, mirroring top-level `let rec`/expr-level `letRecExpr`. Reuses
-- `letFunTailFor` rather than duplicating its `in`/no-`in` tail dispatch.
letRecStmt : Parser DoStmt
letRecStmt = do
  expectTok TRec
  name <- identNameP
  pats <- many parseParamPat
  expectTok TEqual
  e1 <- parseRhsExpr
  t <- peekP
  letFunTailFor name pats e1 t

-- IDENT-led: function-let `let f a… = e` (params present), annotated
-- `let x : ty = e`, or plain `let x = e [in/else]`
letIdent : String -> Parser DoStmt
letIdent name = do
  advance
  pats <- many parseParamPat
  t <- peekP
  letIdentBody name pats t

-- annotation (`: ty`) only on the no-params case, mirroring the let-in path
letIdentBody : String -> List Pat -> Token -> Parser DoStmt
letIdentBody name [] TColon = do
  advance
  ty <- parseTy
  expectTok TEqual
  e1 <- parseRhsExpr
  letIdentRest name [] (EAnnot e1 ty)
letIdentBody name pats _ = do
  expectTok TEqual
  e1 <- parseRhsExpr
  letIdentRest name pats e1

letIdentRest : String -> List Pat -> Expr -> Parser DoStmt
letIdentRest name [] e1 = do
  t <- peekP
  letTailFor (PVar name) e1 t
letIdentRest name pats e1 = do
  t <- peekP
  letFunTailFor name pats e1 t

-- `let f params = e1 in e2` → DoExpr (ELet); without `in` → DoLet (stmt)
letFunTailFor : String -> List Pat -> Expr -> Token -> Parser DoStmt
letFunTailFor name pats e1 TIn = do
  advance
  e2 <- parseExpr
  pure (DoExpr (ELet False True (PVar name) (curryLam pats e1) e2))
letFunTailFor name pats e1 _ =
  pure (DoLet False True (PVar name) (curryLam pats e1))

-- non-IDENT-led pattern: `let (a, b) = e`, `let Some v = e`, …
letPat : Parser DoStmt
letPat = do
  pat <- parsePat
  expectTok TEqual
  e1 <- parseRhsExpr
  t <- peekP
  letTailFor pat e1 t

letTailFor : Pat -> Expr -> Token -> Parser DoStmt
letTailFor pat e1 TIn = do
  advance
  e2 <- parseExpr
  pure (DoExpr (ELet False False pat e1 e2))
letTailFor pat e1 _ = pure (DoLet False False pat e1)

-- mirror the reference `curry_lam`: one single-arg ELam per param
curryLam : List Pat -> Expr -> Expr
curryLam [] body = body
curryLam (p::ps) body = ELam [p] (curryLam ps body)

-- `pat <- e` is a DoBind (LHS parsed as an expr, reinterpreted); `lhs = e` is
-- an assignment (DoAssign / DoFieldAssign); else a bare DoExpr
parseExprStmt : Parser (List DoStmt)
parseExprStmt = do
  e <- parseExpr
  t <- peekP
  exprStmtFor e t

exprStmtFor : Expr -> Token -> Parser (List DoStmt)
exprStmtFor e TLArrow = do
  advance
  rhs <- parseExpr
  pure (bindStmts e rhs)
exprStmtFor e TEqual = do
  advance
  rhs <- parseExpr
  s <- assignFromLhs e rhs
  pure [s]
exprStmtFor e _ = pure [DoExpr e]

-- `pat <- e` → one DoBind; an annotated var LHS `x : ty <- e` → the bind PLUS a
-- shadowing `let x = (x : ty)` so x is bound AND its declared type is enforced
-- (there is no annotated-pattern node to carry the type on the binder directly)
bindStmts : Expr -> Expr -> List DoStmt
bindStmts lhs rhs = match stripLoc lhs
  EAnnot inner ty => bindAnnot inner ty rhs
  _ => [DoBind (exprToPat lhs) rhs]

bindAnnot : Expr -> Ty -> Expr -> List DoStmt
bindAnnot inner ty rhs = match stripLoc inner
  EVar x =>
    [DoBind (PVar x) rhs, DoLet False False (PVar x) (EAnnot (EVar x) ty)]
  other => [DoBind (exprToPat other) rhs]

-- a `lhs = rhs` statement: bare var → DoAssign, field path → DoFieldAssign
assignFromLhs : Expr -> Expr -> Parser DoStmt
assignFromLhs lhs rhs = match flattenFieldPath lhs
  Some (x, []) => pure (DoAssign x rhs)
  Some (x, fs) => pure (DoFieldAssign x fs rhs)
  None => failP "invalid assignment target in do-block"

-- `a` → Some (a, []); `a.b.c` → Some (a, [b, c]); anything else → None.
-- Strips ELoc wrappers (the base var and any sub-access are wrapped atoms).
flattenFieldPath : Expr -> Option (String, List String)
flattenFieldPath (ELoc _ e) = flattenFieldPath e
flattenFieldPath (EVar x) = Some (x, [])
flattenFieldPath (EFieldAccess inner f _) =
  fieldPathExtend (flattenFieldPath inner) f
flattenFieldPath _ = None

fieldPathExtend : Option (String, List String) -> String -> Option (String, List String)
fieldPathExtend (Some (x, fs)) f = Some (x, fs ++ [f])
fieldPathExtend None _ = None

-- skip layout noise (NEWLINE/INDENT/DEDENT) between top-level decls; recurse
-- through a do-continuation (see skipNewlines) to avoid a recursive-value cycle
skipNoise : Parser Unit
skipNoise = do
  t <- peekP
  skipNoiseFor t

skipNoiseFor : Token -> Parser Unit
skipNoiseFor TNewline = afterNoise
skipNoiseFor TIndent = afterNoise
skipNoiseFor TDedent = afterNoise
skipNoiseFor _ = pure ()

afterNoise : Parser Unit
afterNoise = do
  advance
  skipNoise

declThenNoise : Parser Decl
declThenNoise = do
  d <- parseDecl
  skipNoise
  pure d

parseProgram : Parser (List Decl)
parseProgram = do
  skipNoise
  many declThenNoise

-- ── Position side-channel ─────────────────────────────────────────────────
-- Mirrors lib/parser_state.ml's three channels, surfaced for `medaka fmt`'s
-- comment-interleaving engine (lib/printer.ml `format_program`):
--   * decl_positions  — per top-level decl, a (line, end_line) pair, in source
--                        order;
--   * variant_lines   — start line of each `data` variant, flat across the file
--                        in decl order;
--   * last_content_line — the line of the last non-trivia token in the file.
-- These are computed *out of band* from the token/line arrays produced by
-- `tokenizeWithLines`: parsing itself is untouched (the AST has no `loc`).  Each
-- decl is parsed with its start/end token index captured via `getPos`; lines
-- come from the parallel line array; variant start lines are re-derived from the
-- decl's token span (the data-body's depth-0 `=`/`|` separators).
-- Third field (#331, increment 1): the decl's NAME-token span, `None` when the
-- decl has no single name token (e.g. `DImpl`'s head — see F4/increment 5) or
-- when the name-finder can't locate one.  Additive — every existing consumer
-- reads only `declPosLine`/`declPosEndLine` (never a positional match on
-- `DeclPos`), so this is snapshot-invisible (`snapshot.mdk:renderDeclPos`
-- reads accessors only) and requires no change anywhere but this file and the
-- LSP consumers that want the real span.
-- Fourth field (#331, increment 2 — child-name spans, channel-first): the
-- ORDERED list of the decl's document-outline CHILD name-token `Loc`s (variant
-- ctors, record fields, interface/impl methods, the single let-bind), in the
-- EXACT order `lsp.mdk:symbolPartsOfDecl` emits them.  `Some l` per child whose
-- name token was located, `None` where the finder missed (the LSP falls back to
-- the parent decl range for that child).  `[]` for decls with no outline
-- children.  Also additive/accessor-only, so still snapshot-invisible.
-- ⚠️ INVARIANT: this list's order/length must track `symbolPartsOfDecl`'s
-- child traversal exactly — guarded by `test/mcp_fixtures/child_spans.mdk`.
public export data DeclPos =
  | DeclPos Int Int (Option Loc) (List (Option Loc))  -- (line, end_line), 1-based; name Loc; child name Locs
public export data Positions =
  | Positions (List DeclPos) (List Int) Int (List (List Int))
-- decl positions, variant start lines, last_content_line, per-decl reflow-unit
-- lines.  The last field mirrors variant_lines: one entry per top-level decl (in
-- decl order), giving the source line of each top-level reflow unit of that
-- decl's RHS — continuation-op operands for a chain body, or block statements
-- for a bare/do-block body (empty otherwise).  `medaka fmt` uses it to anchor
-- per-unit trailing comments (finding "L").  Computed out-of-band from the
-- token/line arrays like the other channels — the AST carries no locations and
-- `parse` never sees it.

export positionsDecls : Positions -> List DeclPos
positionsDecls (Positions ds _ _ _) = ds

export positionsVariantLines : Positions -> List Int
positionsVariantLines (Positions _ vs _ _) = vs

export positionsLastContentLine : Positions -> Int
positionsLastContentLine (Positions _ _ l _) = l

export positionsChainLines : Positions -> List (List Int)
positionsChainLines (Positions _ _ _ cl) = cl

export declPosLine : DeclPos -> Int
declPosLine (DeclPos l _ _ _) = l

export declPosEndLine : DeclPos -> Int
declPosEndLine (DeclPos _ e _ _) = e

-- The decl's NAME-token `Loc` (#331), or `None` for a decl with no single name
-- token or where the name-finder couldn't resolve one — callers fall back to
-- the (line, 0)..(end_line, 0) range built from `declPosLine`/`declPosEndLine`.
export declPosNameLoc : DeclPos -> Option Loc
declPosNameLoc (DeclPos _ _ nl _) = nl

-- The decl's ordered CHILD name-token `Loc`s (#331, increment 2), in
-- `symbolPartsOfDecl` outline order; `[]` for childless decls.  Per-child `None`
-- where the finder missed (LSP falls back to the parent range for that child).
export declPosChildLocs : DeclPos -> List (Option Loc)
declPosChildLocs (DeclPos _ _ _ cs) = cs

-- Parse one decl, capturing the (startTokIdx, endTokIdx) span around it.
declWithSpan : Parser (Decl, Int, Int)
declWithSpan = do
  s <- getPos
  d <- parseDecl
  e <- getPos
  pure (d, s, e)

-- Program parse that records each decl's token span, mirroring parseProgram's
-- skipNoise + many declThenNoise but threading spans.
spanDeclThenNoise : Parser (Decl, Int, Int)
spanDeclThenNoise = do
  ds <- declWithSpan
  skipNoise
  pure ds

programWithSpans : Parser (List (Decl, Int, Int))
programWithSpans = do
  skipNoise
  many spanDeclThenNoise

-- Layout-noise predicate over the token array (NEWLINE/INDENT/DEDENT).
isNoiseTok : Token -> Bool
isNoiseTok TNewline = True
isNoiseTok TIndent = True
isNoiseTok TDedent = True
isNoiseTok _ = False

-- Last content (non-noise) token index strictly below `e`, scanning back from
-- e-1 down to `s`.  Returns `s` if none (degenerate; a decl always has content).
lastContentIdx : Array Token -> Int -> Int -> Int
lastContentIdx toks s i
  | i < s = s
  | isNoiseTok (arrayGetUnsafe i toks) = lastContentIdx toks s (i - 1)
  | otherwise = i

-- 1-based source line of token index `i` from the parallel line array.
lineAt : Array Int -> Int -> Int
lineAt lines i
  | i < arrayLength lines = arrayGetUnsafe i lines
  | otherwise = 0

-- ── decl NAME span (#331, increment 1) ──────────────────────────────────────
-- `declPosOf` (below) gives every decl a LINE-only range; the LSP's
-- `selectionRange` / definition range wants the decl's real NAME-token span
-- (`SOURCE-POSITION-DESIGN.md`, Increment 1). The parser already knows each
-- decl's kind and is positioned at its name token as it builds the node, so —
-- rather than re-deriving "where's the name" from source TEXT
-- (`columnAfterName`'s fragile approach, `lsp.mdk`) — scan the token KINDS
-- from the decl's start index over its known leading modifier/keyword tokens
-- to the name-role token, and mint a `Loc` for it via the same
-- `offsetToLineColFast` service `locOfSpan` uses. No lexer change: the
-- (start,end) offset pairs already exist (`tokenizeWithOffsetPairs`); this
-- only adds a name-token FINDER over token kinds already produced.

-- `Loc` for a [startIdx, endIdx) token span, given an EXPLICIT offset-pairs
-- array instead of `locOfSpan`'s global `locOffsRef`/`locLineStartsRef`
-- state. Used by the decl/child name-span finders below, which already carry
-- `offs`/`lineStarts` as plain locals from their caller — no need to round-trip
-- through the global refs `setLocState` maintains for the `located` combinator.
-- (Until increment 3 / I6 this separation was also load-bearing: priming the
-- globals here would have retroactively given `parseWithPositionsOpt` real
-- expression `ELoc`s ahead of that increment. `parseWithPositionsOpt` now
-- primes `setLocState` itself with the same `offs`, so both loc systems agree;
-- this function stays parameterized purely so the name-span finders don't need
-- global state.) Same arithmetic as `locOfSpan`, just parameterized.
locOfSpanWith : Array (Int, Int) -> Array Int -> Int -> Int -> Loc
locOfSpanWith offs lineStarts startIdx endIdx =
  let lastIdx = if endIdx > startIdx then endIdx - 1 else startIdx
  let startOff = tokOffsetAtArr offs startIdx
  let endOff = tokEndOffsetAtArr offs lastIdx
  match offsetToLineColFast lineStarts startOff
    (sl, sc) => match offsetToLineColFast lineStarts endOff
      (el, ec) => Loc "" sl sc el ec

-- start/end char offset of token `i` in an explicit offset-pairs array (0 when
-- out of range) — the non-global-state twin of `tokOffsetAt`/`tokEndOffsetAt`.
tokOffsetAtArr : Array (Int, Int) -> Int -> Int
tokOffsetAtArr offs i =
  if i >= 0 && i < arrayLength offs then
    fst (arrayGetUnsafe i offs)
  else
    0

tokEndOffsetAtArr : Array (Int, Int) -> Int -> Int
tokEndOffsetAtArr offs i =
  if i >= 0 && i < arrayLength offs then
    snd (arrayGetUnsafe i offs)
  else
    0

-- Leading tokens that can precede a decl's own head keyword/name: visibility
-- modifiers (`public`, `export`), the `default` marker (legal only before
-- `interface`, but harmless to skip generically — a stray `default` elsewhere
-- is a parse error, so no successfully-parsed `Decl` can have one out of
-- place), and layout noise (NEWLINE/INDENT/DEDENT — `afterExport`/
-- `afterPublic` both call `skipNewlines` after consuming their own keyword, so
-- noise can in principle appear between two modifiers).
isLeadingModifierTok : Token -> Bool
isLeadingModifierTok TPublic = True
isLeadingModifierTok TExport = True
isLeadingModifierTok TDefault = True
isLeadingModifierTok t = isNoiseTok t

-- Skip forward over leading modifier/noise tokens to the decl's own head token.
skipLeadingModifiers : Array Token -> Int -> Int
skipLeadingModifiers toks i
  | i < arrayLength toks && isLeadingModifierTok (arrayGetUnsafe i toks) =
    skipLeadingModifiers toks (i + 1)
  | otherwise = i

isTStringTok : Token -> Bool
isTStringTok (TString _) = True
isTStringTok _ = False

tokIdxOrNone : Array Token -> Int -> Option Int
tokIdxOrNone toks i = if i >= 0 && i < arrayLength toks then Some i else None

-- The decl's NAME-token index, given `i` already past any leading modifiers:
-- for kinds with a head keyword (`data`/`extern`/`prop`/`test`/`bench`/
-- `interface`/`type`/`newtype`/`let rec`), skip it (skipping any further
-- noise) and land on the name; for kinds with no head keyword (`DTypeSig`/
-- `DFunDef`), `i` IS already the name. `None` for kinds with no single name
-- token — `DImpl`'s head (F4, deferred to increment 5 — see
-- SOURCE-POSITION-DESIGN.md §6) and `DUse` (never surfaces in the LSP
-- outline/definition paths, `symbolPartsOfDecl`/`declDefines`, so it needs no
-- span here).
declNameTokIdxAt : Array Token -> Decl -> Int -> Option Int
declNameTokIdxAt toks (DAttrib _ inner) i =
  -- `@name ["arg"]` NEWLINE* — mirrors `parseAttrib`. A stacked attribute
  -- (`DAttrib` wrapping another `DAttrib`) recurses via `declNameTokIdx`,
  -- which re-skips modifiers/noise before dispatching on the inner decl kind.
  let i1 = i + 1  -- '@'
  let i2 = i1 + 1  -- attribute name ident
  let i3 = if i2 < arrayLength toks && isTStringTok (arrayGetUnsafe i2 toks) then i2 + 1 else i2
  declNameTokIdx toks inner i3
declNameTokIdxAt toks (DTypeSig _ _ _) i = tokIdxOrNone toks i
declNameTokIdxAt toks (DFunDef _ _ _ _) i = tokIdxOrNone toks i
declNameTokIdxAt toks (DExtern _ _ _) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DData _ _ _ _ _) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DEffect _ _ _) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DProp _ _ _ _) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DTest _ _ _) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DBench _ _ _) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DInterface { ... }) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DTypeAlias _ _ _ _) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DNewtype _ _ _ _ _ _) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DLetGroup _ _) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 2))  -- `let` `rec`
declNameTokIdxAt toks (DImpl { ... }) i = None  -- F4, increment 5
declNameTokIdxAt toks (DUse _ _ _) i = None

-- Entry point: skip leading modifiers, then dispatch on decl kind.
declNameTokIdx : Array Token -> Decl -> Int -> Option Int
declNameTokIdx toks d i = declNameTokIdxAt toks d (skipLeadingModifiers toks i)

-- The decl's NAME-token `Loc` (#331), or `None` — see `declNameTokIdxAt`.
declNameSpanOf : Array Token -> Array (Int, Int) -> Array Int -> (Decl, Int, Int) -> Option Loc
declNameSpanOf toks offs lineStarts (d, s, _e) = map
  (nameIdx => locOfSpanWith offs lineStarts nameIdx (nameIdx + 1))
  (declNameTokIdx toks d s)

-- ── decl CHILD name spans (#331, increment 2 — channel-first) ────────────────
-- The document-outline CHILDREN of a decl — variant constructors, record
-- fields, interface/impl methods, and the (single, at top level) let-bind —
-- each want their OWN name-token `Loc` for the LSP outline, instead of reusing
-- the parent decl's whole-line range (`lsp.mdk:symbolPartsOfDecl`).  Like the
-- decl-name finder above, this reads token KINDS structurally from the decl's
-- token span (no AST loc fields — that AST-field migration is increment 4) and
-- mints each `Loc` via `locOfSpanWith`.
--
-- ⚠️ THE CRITICAL INVARIANT: the returned list's ORDER and LENGTH must match
-- `lsp.mdk:symbolPartsOfDecl`'s child-traversal order EXACTLY (a nameOmitted
-- record variant → one entry per field; any other variant → its single ctor;
-- interface/impl → each method in `methods` order; let group → its single
-- bind).  If they desync, a `Loc` attaches to the WRONG child — a silent wrong
-- answer.  Guarded by `test/mcp_fixtures/child_spans.mdk`.

-- Unwrap `@attrib`-stacked wrappers to the underlying decl (for kind dispatch;
-- the token span still spans the attribute prefix, but no child structural
-- marker — `where`/`=`/`|`/`{` — lives inside an attribute head, so scanning
-- the whole span is safe).
innerDeclOf : Decl -> Decl
innerDeclOf (DAttrib _ d) = innerDeclOf d
innerDeclOf d = d

-- Child NAME-token indices, in `symbolPartsOfDecl` outline order (see invariant).
declChildNameIdxs : Array Token -> (Decl, Int, Int) -> List (Option Int)
declChildNameIdxs toks (d, s, e) = match innerDeclOf d
  DData _ _ _ variants _ => dataChildIdxs toks s e variants
  DInterface { ... } => methodNameIdxs toks s e
  DImpl { ... } => methodNameIdxs toks s e
  -- A top-level `DLetGroup` always holds exactly ONE bind (`parseLetGroupDecl`
  -- → `coalesceClauses [c]`), whose name IS the decl name — reuse the decl-name
  -- finder on the ORIGINAL `d` (so `@attrib`/modifier skipping is handled).
  DLetGroup _ _ => [declNameTokIdx toks d s]
  _ => []

-- ── variants + record fields ────────────────────────────────────────────────
-- Index-returning twin of `variantStartsIn`/`variantStartsGo`: the token index
-- (skipping layout noise) immediately after each depth-0 `=`/`|` variant
-- boundary.  One entry per variant, in source order — mirrors the boundary
-- logic exactly so its count tracks `variantStartsIn`'s (and the AST variants).
variantBoundaryIdxs : Array Token -> Int -> Int -> List Int
variantBoundaryIdxs toks s e = variantBoundaryGo toks s e 0 False

variantBoundaryGo : Array Token -> Int -> Int -> Int -> Bool -> List Int
variantBoundaryGo toks i e depth seenEq
  | i >= e = []
  | otherwise = variantBoundaryAt toks i e depth seenEq (arrayGetUnsafe i toks)

variantBoundaryAt : Array Token -> Int -> Int -> Int -> Bool -> Token -> List Int
variantBoundaryAt toks i e depth seenEq t
  | isOpenDelim t = variantBoundaryGo toks (i + 1) e (depth + 1) seenEq
  | isCloseDelim t = variantBoundaryGo toks (i + 1) e (depth - 1) seenEq
  | depth == 0 && not seenEq && t == TEqual && nextSigIsPipe toks e (i + 1) =
    variantBoundaryGo toks (i + 1) e depth True
  | depth == 0 && not seenEq && t == TEqual = firstContentAt toks (i + 1) e :: variantBoundaryGo toks (i + 1) e depth True
  | depth == 0 && seenEq && t == TPipe = firstContentAt toks (i + 1) e :: variantBoundaryGo toks (i + 1) e depth seenEq
  | otherwise = variantBoundaryGo toks (i + 1) e depth seenEq

-- Zip the AST variants with their boundary token indices, mirroring
-- `lsp.mdk:variantSymChildren`: a nameOmitted record variant (`data X = { … }`,
-- `ConNamed _ True`) expands to one index per field (the boundary points at the
-- `{`); any other variant contributes its single ctor-name index (the boundary
-- IS the ctor name token).  Fewer boundaries than variants → `None` fallback.
dataChildIdxs : Array Token -> Int -> Int -> List Variant -> List (Option Int)
dataChildIdxs toks s e variants =
  zipVariantIdxs toks e variants (variantBoundaryIdxs toks s e)

zipVariantIdxs : Array Token -> Int -> List Variant -> List Int -> List (Option Int)
zipVariantIdxs _ _ [] _ = []
zipVariantIdxs toks e ((Variant _ (ConNamed fs True))::vs) (b::bs) = zipFieldIdxs fs (fieldNameIdxsIn toks (b + 1) e)
  ++ zipVariantIdxs toks e vs bs
zipVariantIdxs toks e ((Variant _ _)::vs) (b::bs) =
  Some b :: zipVariantIdxs toks e vs bs
zipVariantIdxs toks e (v::vs) [] = variantNoneIdxs v
  ++ zipVariantIdxs toks e vs []

-- `None` placeholders for a variant with no boundary (shouldn't happen): one per
-- field for a nameOmitted record, else a single `None` for the ctor.
variantNoneIdxs : Variant -> List (Option Int)
variantNoneIdxs (Variant _ (ConNamed fs True)) = map (_ => None) fs
variantNoneIdxs (Variant _ _) = [None]

-- Field-name token indices inside a brace group, starting just past the `{`
-- (`i`): the first content token after `{` and after each depth-1 `,`, until the
-- matching `}` (depth back to 0).  Mirrors `parseNamedFields`/`parseField`
-- (`identNameP` after `{`/`,`).  A trailing `,` before `}` records nothing (the
-- next content is the close brace, which drops depth to 0 and stops).
fieldNameIdxsIn : Array Token -> Int -> Int -> List Int
fieldNameIdxsIn toks i e = fieldNameGo toks i e 1 True

fieldNameGo : Array Token -> Int -> Int -> Int -> Bool -> List Int
fieldNameGo toks i e depth atStart
  | i >= e = []
  | depth <= 0 = []
  | otherwise = fieldNameStep toks i e depth atStart (arrayGetUnsafe i toks)

fieldNameStep : Array Token -> Int -> Int -> Int -> Bool -> Token -> List Int
fieldNameStep toks i e depth atStart t
  | isOpenDelim t = fieldNameGo toks (i + 1) e (depth + 1) False
  | isCloseDelim t = fieldNameGo toks (i + 1) e (depth - 1) False
  | depth == 1 && t == TComma = fieldNameGo toks (i + 1) e depth True
  | isNoiseTok t = fieldNameGo toks (i + 1) e depth atStart
  | atStart && depth == 1 = i :: fieldNameGo toks (i + 1) e depth False
  | otherwise = fieldNameGo toks (i + 1) e depth False

-- Pair AST fields 1:1 with found field-name indices (defensive `None` when the
-- finder ran short).
zipFieldIdxs : List Field -> List Int -> List (Option Int)
zipFieldIdxs [] _ = []
zipFieldIdxs (_::fs) (i::is) = Some i :: zipFieldIdxs fs is
zipFieldIdxs (_::fs) [] = None :: zipFieldIdxs fs []

-- ── interface / impl methods ────────────────────────────────────────────────
-- Method names inside the `where INDENT … DEDENT` body: the first content token
-- at the block's base layout depth (1) after the opening INDENT and after each
-- base-level NEWLINE.  Nested blocks (a default method's multi-line body) raise
-- the depth so their tokens are skipped.  Marker interfaces / single-line
-- `where` (no INDENT) yield `[]` — matching an empty `methods` list.
methodNameIdxs : Array Token -> Int -> Int -> List (Option Int)
methodNameIdxs toks s e = match findWhereIdx toks s e
  None => []
  Some w =>
    let after = skipNewlineToks toks (w + 1) e
    if after < e && arrayGetUnsafe after toks == TIndent then
      methodNameGo toks (after + 1) e 1 True
    else
      []

findWhereIdx : Array Token -> Int -> Int -> Option Int
findWhereIdx toks i e
  | i >= e = None
  | arrayGetUnsafe i toks == TWhere = Some i
  | otherwise = findWhereIdx toks (i + 1) e

-- Skip only NEWLINE tokens (not INDENT/DEDENT) — used to reach the opening
-- INDENT of a `where` body without stepping over it.
skipNewlineToks : Array Token -> Int -> Int -> Int
skipNewlineToks toks i e
  | i < e && arrayGetUnsafe i toks == TNewline = skipNewlineToks toks (i + 1) e
  | otherwise = i

methodNameGo : Array Token -> Int -> Int -> Int -> Bool -> List (Option Int)
methodNameGo toks i e depth atStart
  | i >= e = []
  | depth <= 0 = []
  | otherwise = methodNameStep toks i e depth atStart (arrayGetUnsafe i toks)

methodNameStep : Array Token -> Int -> Int -> Int -> Bool -> Token -> List (Option Int)
methodNameStep toks i e depth _ TIndent =
  methodNameGo toks (i + 1) e (depth + 1) False
methodNameStep toks i e depth _ TDedent =
  methodNameGo toks (i + 1) e (depth - 1) False
methodNameStep toks i e depth _ TNewline =
  methodNameGo toks (i + 1) e depth (depth == 1)
methodNameStep toks i e depth atStart _
  | atStart && depth == 1 = Some i :: methodNameGo toks (i + 1) e depth False
  | otherwise = methodNameGo toks (i + 1) e depth False

-- The decl's CHILD name-token `Loc`s (#331, increment 2), in outline order.
declChildSpansOf : Array Token -> Array (Int, Int) -> Array Int -> (Decl, Int, Int) -> List (Option Loc)
declChildSpansOf toks offs lineStarts span = map
  (idxOpt => map (idx => locOfSpanWith offs lineStarts idx (idx + 1)) idxOpt)
  (declChildNameIdxs toks span)

-- Build a DeclPos from a captured (start, end) token span: start line is the
-- line of the first token; end line is the line of the last *content* token in
-- the span (mirrors lib/parser_state.record_decl_pos's last_content_line fixup,
-- which pins end_line to the decl's final non-trivia token). The third field
-- is the decl's NAME-token span (#331, additive — see `declNameSpanOf`).
declPosOf : Array Token -> Array Int -> Array (Int, Int) -> Array Int -> (Decl, Int, Int) -> DeclPos
declPosOf toks lines offs lineStarts (d, s, e) = DeclPos
  (lineAt lines s)
  (lineAt lines (lastContentIdx toks s (e - 1)))
  (declNameSpanOf toks offs lineStarts (d, s, e))
  (declChildSpansOf toks offs lineStarts (d, s, e))

-- Re-derive a data decl's variant start lines from its token span.  Within a
-- `data` body the only `|` at delimiter-depth 0 are variant separators (the
-- leading `=` introduces the first variant; each later `|` a subsequent one);
-- payloads keep any `|` inside ()/[]/{}/[| |].  So we walk the span tracking
-- delimiter depth and emit the line of the token *after* the first depth-0 `=`
-- and after each depth-0 `|`.
variantStartsIn : Array Token -> Array Int -> Int -> Int -> List Int
variantStartsIn toks lines i e = variantStartsGo toks lines i e 0 False

-- `depth` = delimiter nesting; `seenEq` = whether the body's `=` was passed.
variantStartsGo : Array Token -> Array Int -> Int -> Int -> Int -> Bool -> List Int
variantStartsGo toks lines i e depth seenEq
  | i >= e = []
  | otherwise =
    variantStartsAt toks lines i e depth seenEq (arrayGetUnsafe i toks)

variantStartsAt : Array Token -> Array Int -> Int -> Int -> Int -> Bool -> Token -> List Int
variantStartsAt toks lines i e depth seenEq t
  | isOpenDelim t = variantStartsGo toks lines (i + 1) e (depth + 1) seenEq
  | isCloseDelim t = variantStartsGo toks lines (i + 1) e (depth - 1) seenEq
  | depth == 0 && not seenEq && t == TEqual && nextSigIsPipe toks e (i + 1) =
    -- New `data Foo =\n  | …` form: the first variant is introduced by a `|`,
    -- not by `=`, so record NO line here (the leading `|` records it below).
    variantStartsGo toks lines (i + 1) e depth True
  | depth == 0 && not seenEq && t == TEqual =
    -- Old/inline form: a constructor follows `=`, so record the line after `=`.
    lineAt lines (i + 1) :: variantStartsGo toks lines (i + 1) e depth True
  | depth == 0 && seenEq && t == TPipe = lineAt lines (i + 1) :: variantStartsGo toks lines (i + 1) e depth seenEq
  | otherwise = variantStartsGo toks lines (i + 1) e depth seenEq

-- Is the next significant token at/after `j` (skipping layout: NEWLINE/INDENT/
-- DEDENT) a `|`?  Distinguishes the new `data Foo =\n  | V` form (pipe-introduced
-- first variant) from the old/inline form (constructor directly after `=`).
nextSigIsPipe : Array Token -> Int -> Int -> Bool
nextSigIsPipe toks e j
  | j >= e = False
  | isLayoutTok (arrayGetUnsafe j toks) = nextSigIsPipe toks e (j + 1)
  | otherwise = arrayGetUnsafe j toks == TPipe

isLayoutTok : Token -> Bool
isLayoutTok TNewline = True
isLayoutTok TIndent = True
isLayoutTok TDedent = True
isLayoutTok _ = False

isOpenDelim : Token -> Bool
isOpenDelim TLParen = True
isOpenDelim TLBracket = True
isOpenDelim TLBracketTight = True
isOpenDelim TLBrace = True
isOpenDelim TLArray = True
isOpenDelim _ = False

isCloseDelim : Token -> Bool
isCloseDelim TRParen = True
isCloseDelim TRBracket = True
isCloseDelim TRBrace = True
isCloseDelim TRArray = True
isCloseDelim _ = False

-- Is the parsed decl a `data` declaration?  (Variant lines are emitted only
-- for these, mirroring lib/parser_state.record_variant_line, which fires from
-- the data-variant grammar productions.)
isDataDecl : Decl -> Bool
isDataDecl (DData _ _ _ _ _) = True
isDataDecl _ = False

-- Flat list of every data decl's variant start lines, in decl order.
allVariantLines : Array Token -> Array Int -> List (Decl, Int, Int) -> List Int
allVariantLines toks lines [] = []
allVariantLines toks lines ((d, s, e)::rest)
  | isDataDecl d = variantStartsIn toks lines s e
    ++ allVariantLines toks lines rest
  | otherwise = allVariantLines toks lines rest

-- ── Chain operand lines (for fmt comment interleaving, finding "L") ─────────
-- For a decl whose RHS is a top-level continuation-op chain, derive the source
-- line of each operand from the token span, IN THE SAME ORDER `printChain`/
-- `collectChain` visit them (head first, then each right in source order).
-- fmt zips these with the chain's per-operand trailing comments.
--
-- Splitting is by the chain's TOP operator token only (from the AST body): a
-- higher-precedence sibling op (e.g. `&&` inside a `||` chain) is part of an
-- operand, not a boundary — matching `collectChain`, which peels only the same
-- op.  This also makes the mapping idempotent once fmt drops redundant parens
-- (the un-parenthesised `&&` stays operand-internal on a re-format).

-- The set of continuation operators (mirror of printer.isContinuationOp).
isContinuationOpStr : String -> Bool
-- Intentional cross-file duplicate of the same helper in printer.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
isContinuationOpStr op = op == "|>"
  || op == ">>"
  || op == "<<"
  || op == "&&"
  || op == "||"
  || op == "++"

-- Does token `t` spell the continuation operator `op`?
chainOpTokEq : String -> Token -> Bool
chainOpTokEq "&&" TAnd = True
chainOpTokEq "||" TOr = True
chainOpTokEq "|>" TPipeRight = True
chainOpTokEq ">>" TRCompose = True
chainOpTokEq "<<" TLCompose = True
chainOpTokEq "++" TPlusPlus = True
chainOpTokEq _ _ = False

-- The top-level continuation operator of a decl's body, if any (peels ELoc; the
-- outermost EBinOp is the lowest-precedence / top operator the parser built).
declChainTopOp : Decl -> Option String
declChainTopOp (DAttrib _ inner) = declChainTopOp inner
declChainTopOp (DFunDef _ _ _ body) = bodyChainTopOp body
declChainTopOp _ = None

bodyChainTopOp : Expr -> Option String
bodyChainTopOp (ELoc _ e) = bodyChainTopOp e
bodyChainTopOp (EBinOp op _ _ _) =
  if isContinuationOpStr op then
    Some op
  else
    None
bodyChainTopOp _ = None

-- First content (non-layout) token index at/after `i`, bounded by `e`.
firstContentAt : Array Token -> Int -> Int -> Int
firstContentAt toks i e
  | i >= e = e
  | isNoiseTok (arrayGetUnsafe i toks) = firstContentAt toks (i + 1) e
  | otherwise = i

-- Index just past the first depth-0 `=` (the definitional `=`) in [s, e); `e`
-- if none (degenerate).  Delimiters guard against a `=` inside a record/etc.
rhsStartIdx : Array Token -> Int -> Int -> Int -> Int
rhsStartIdx toks i e depth
  | i >= e = e
  | isOpenDelim (arrayGetUnsafe i toks) = rhsStartIdx toks (i + 1) e (depth + 1)
  | isCloseDelim (arrayGetUnsafe i toks) =
    rhsStartIdx toks (i + 1) e (depth - 1)
  | depth == 0 && arrayGetUnsafe i toks == TEqual = i + 1
  | otherwise = rhsStartIdx toks (i + 1) e depth

-- Operand lines of the top-`op` chain in the RHS [rs, e): the head's first
-- content line, then each depth-0 `op`-token's following operand's first
-- content line.  Recording the OPERAND line (not the operator line) places the
-- trailing comment correctly for both leading- and trailing-operator styles.
chainOperandLines : Array Token -> Array Int -> String -> Int -> Int -> List Int
chainOperandLines toks lines op rs e =
  let h = firstContentAt toks rs e
  if h >= e then [] else lineAt lines h :: chainOpLinesGo toks lines op rs e 0

chainOpLinesGo : Array Token -> Array Int -> String -> Int -> Int -> Int -> List Int
chainOpLinesGo toks lines op i e depth
  | i >= e = []
  | otherwise = chainOpLinesAt toks lines op i e depth (arrayGetUnsafe i toks)

chainOpLinesAt : Array Token -> Array Int -> String -> Int -> Int -> Int -> Token -> List Int
chainOpLinesAt toks lines op i e depth t
  | isOpenDelim t = chainOpLinesGo toks lines op (i + 1) e (depth + 1)
  | isCloseDelim t = chainOpLinesGo toks lines op (i + 1) e (depth - 1)
  | depth == 0 && chainOpTokEq op t = lineAt lines (firstContentAt toks (i + 1) e) :: chainOpLinesGo toks lines op (i + 1) e depth
  | otherwise = chainOpLinesGo toks lines op (i + 1) e depth

-- ── Block statement lines (Stage 5: block/do interior comments) ────────────
-- For a decl whose body is a top-level bare block (EBlock) or do-block (EDo),
-- the first-content line of each statement at the block's top indent level, so
-- fmt can anchor each statement's trailing comment.  A continuation after a
-- nested block or a multi-line statement is NOT counted as a new statement, so
-- such blocks yield a line count that won't match the AST and fmt falls back to
-- the verbatim safety-net (never dropping or misplacing a comment).

declBlockRhs : Decl -> Bool
declBlockRhs (DAttrib _ inner) = declBlockRhs inner
declBlockRhs (DFunDef _ _ _ body) = bodyIsBlock body
declBlockRhs _ = False

bodyIsBlock : Expr -> Bool
bodyIsBlock (ELoc _ e) = bodyIsBlock e
bodyIsBlock (EBlock _) = True
bodyIsBlock (EDo _) = True
bodyIsBlock _ = False

-- Index just past the first INDENT in [i, e) (the block opener); `e` if none.
firstIndentIdx : Array Token -> Int -> Int -> Int
firstIndentIdx toks i e
  | i >= e = e
  | arrayGetUnsafe i toks == TIndent = i + 1
  | otherwise = firstIndentIdx toks (i + 1) e

blockStmtLines : Array Token -> Array Int -> Int -> Int -> List Int
blockStmtLines toks lines rs e =
  let bi = firstIndentIdx toks rs e
  if bi >= e then [] else blockStmtGo toks lines bi e 1 True

-- `ind` = INDENT depth relative to the block (opens at 1); `atStart` = the next
-- content token begins a new top-level statement (set past the opening INDENT
-- and after each NEWLINE at depth 1, cleared after a nested DEDENT so an `else`/
-- continuation is not miscounted).
blockStmtGo : Array Token -> Array Int -> Int -> Int -> Int -> Bool -> List Int
blockStmtGo toks lines i e ind atStart
  | i >= e = []
  | ind <= 0 = []
  | otherwise = blockStmtAt toks lines i e ind atStart (arrayGetUnsafe i toks)

blockStmtAt : Array Token -> Array Int -> Int -> Int -> Int -> Bool -> Token -> List Int
blockStmtAt toks lines i e ind atStart t
  | t == TIndent = blockStmtGo toks lines (i + 1) e (ind + 1) False
  | t == TDedent = blockStmtGo toks lines (i + 1) e (ind - 1) False
  | t == TNewline = blockStmtGo toks lines (i + 1) e ind (ind == 1)
  | atStart && ind == 1 =
    lineAt lines i :: blockStmtGo toks lines (i + 1) e ind False
  | otherwise = blockStmtGo toks lines (i + 1) e ind False

-- Per-decl reflow-unit lines: chain operand lines for a continuation-chain body,
-- else block statement lines for a bare/do-block body, else empty.
declChainLines : Array Token -> Array Int -> Decl -> Int -> Int -> List Int
declChainLines toks lines d s e = match declChainTopOp d
  Some op => chainOperandLines toks lines op (rhsStartIdx toks s e 0) e
  None =>
    if declBlockRhs d then
      blockStmtLines toks lines (rhsStartIdx toks s e 0) e
    else
      []

-- Flat list (one entry per decl, in decl order) of every decl's chain operand
-- lines, parallel to the decl list — fmt consumes it in lockstep.
allChainLines : Array Token -> Array Int -> List (Decl, Int, Int) -> List (List Int)
allChainLines toks lines [] = []
allChainLines toks lines ((d, s, e)::rest) =
  declChainLines toks lines d s e :: allChainLines toks lines rest

-- last_content_line: line of the last content token across the whole file.
lastContentLineOf : Array Token -> Array Int -> List (Decl, Int, Int) -> Int
lastContentLineOf toks lines spans = lastContentLineGo toks lines spans 0

lastContentLineGo : Array Token -> Array Int -> List (Decl, Int, Int) -> Int -> Int
lastContentLineGo toks lines [] acc = acc
lastContentLineGo toks lines ((_, s, e)::rest) acc =
  lastContentLineGo
    toks
    lines
    rest
    (lineAt lines (lastContentIdx toks s (e - 1)))

-- Parse `src` and return the position side-channel alongside the decls.  The
-- non-panicking `parseWithPositionsOpt` does the work; this wrapper preserves the
-- panic-on-unparseable behaviour the compiler + `medaka fmt` rely on.
export parseWithPositions : String -> (List Decl, Positions)
parseWithPositions src = match parseWithPositionsOpt src
  Some r => r
  None => panic "parse error"

-- Historically: `parseWithPositions` PLUS real per-expression `ELoc` locations
-- (#649), via a SEPARATE `tokenizeWithOffsetPairs` pass + `setLocState` primed
-- ahead of deferring to `parseWithPositions` — because plain
-- `parseWithPositions` (→ `parseWithPositionsOpt`) never called `setLocState`
-- itself, so every `located` atom in its returned tree carried `located`'s
-- zero-loc placeholder, NOT a real span. That gap is what let `medaka lint`'s
-- `exprRuleFindings` driver collapse every finding onto the decl's location
-- instead of the specific sub-expression's own.
--
-- #331 increment 3 / I6 unifies the two entries: `parseWithPositionsOpt` now
-- primes `setLocState` itself (using the SAME offset pairs it already
-- computes for the decl/child name-span finders), so `parseWithPositions`
-- already returns real expression `ELoc`s. This function is now a plain alias
-- kept for its existing callers (`compiler/tools/lint.mdk`'s
-- `lintFileDiagTriple` and `compiler/driver/medaka_cli.mdk`'s
-- `lintFileFresh`) — no separate tokenize pass, no separate `setLocState`
-- call; the double-tokenize this used to cost is gone.
export parseWithPositionsLocated : String -> (List Decl, Positions)
parseWithPositionsLocated src = parseWithPositions src

-- Non-panicking positions parse for the LSP.  Returns `None` when the source
-- doesn't parse (instead of `panic "parse error"`), so documentSymbol / definition
-- / inlayHint degrade to empty results rather than crashing the whole server —
-- files are unparseable constantly mid-edit.
export parseWithPositionsOpt : String -> Option (List Decl, Positions)
parseWithPositionsOpt src = match tokenizeWithLines src
  (tokList, lineList) =>
    let toks = arrayFromList tokList
    let lines = arrayFromList lineList
    -- #331/#649 (increment 3, I6): a second tokenize pass for the (start,end)
    -- offset pairs the decl NAME-span finder needs (`declNameSpanOf`).  Its
    -- token stream is byte-identical to `tokenizeWithLines`'s (both documented
    -- as such), so the indices line up with `toks`/`spans` below.  The SAME
    -- `offs` also primes `setLocState`, so `located`'s expression `ELoc`s
    -- carry real spans too — this used to be deliberately skipped (see the old
    -- `locOfSpanWith` header note, now stale) so that `parseWithPositionsOpt`
    -- and `parseWithPositionsLocated` stayed two different-fidelity entries;
    -- unifying them (I6) is the whole point of this increment, so every
    -- caller — LSP `documentSymbols`/`definition`/`inlayHint` included — now
    -- gets real sub-expression positions for free, at the SAME one-extra-pass
    -- cost this function already paid.
    match tokenizeWithOffsetPairs src
      (_, offPairList) =>
        let offs = arrayFromList offPairList
        let nameLineStarts = lineStartsOf src
        let _ = setLocState src offs
        match runP programWithSpans toks 0
          PErr _ _ => None
          PFatal _ _ => None
          POk spans pos => if peekTok toks pos == TEof then
            let decls = map ((d, _s, _e) => d) spans
            let dps = map (declPosOf toks lines offs nameLineStarts) spans
            let vls = allVariantLines toks lines spans
            let lcl = lastContentLineOf toks lines spans
            let cls = allChainLines toks lines spans
            Some (decls, Positions dps vls lcl cls)
          else None

-- Check that the parse consumed all tokens (no trailing garbage), panic on error.
-- Mirrors lib/loader.ml: raises Failure "Parse error" on Parser.Error or Failure.
resultDecls : Array Token -> PR (List Decl) -> List Decl
resultDecls _ (PErr _ _) = panic "parse error"
resultDecls _ (PFatal _ _) = panic "parse error"
resultDecls toks (POk ds pos)
  | peekTok toks pos == TEof = ds
  | otherwise = panic "parse error"

-- A lexer error (unterminated string / block comment, invalid escape, stray
-- character) reaches the token stream as a terminal `TLexError msg` (see
-- `firstLexError` below).  The panicking entry must surface THAT specific
-- message rather than the generic "parse error" the grammar's own failure
-- produces once it runs off the end of a truncated/garbled token stream —
-- otherwise a parser-only caller (no `firstLexError` pre-scan of its own,
-- e.g. `compiler/entries/parse_main.mdk`) degrades every lexer error to the
-- same uninformative string, while `parseResult` (used by the CLI `check`
-- path) already special-cases it.  Shares `firstLexError` with `parseResult`
-- so both entries agree on wording.
export parse : String -> List Decl
parse src =
  let toks = arrayFromList (tokenize src)
  match firstLexError toks 0
    Some (_, msg) => panic msg
    None => resultDecls toks (runP parseProgram toks 0)

-- Position-populating parse entry for B.10.2b (LSP).  Sets the loc-state refs
-- (src + token offsets) so the ELoc wrappers carry REAL line/col, then parses.
-- Separate from `parse` (which stays pure / placeholder-loc) because `setRef`
-- is <Mut> and `parse` is called from pure contexts across the pipeline; the
-- token stream is byte-identical (`tokenizeWithOffsets` vs `tokenize`).
export parseLocated : String -> List Decl
parseLocated src = match tokenizeWithOffsetPairs src
  (tokList, offPairs) =>
    let _ = setLocState src (arrayFromList offPairs)
    let toks = arrayFromList tokList
    resultDecls toks (runP parseProgram toks 0)

-- ── Structured parse errors (non-panicking entry) ───────────────────────────
-- The LSP prerequisite (Stage 4 task #24): a parser should yield errors as
-- DATA, not abort.  The combinator already threads errors as values internally
-- (`PR a = POk | PErr String Int`); only the top boundary (`resultDecls`,
-- `parseWithPositions`) panics on `PErr` / leftover tokens.  `parseResult` is a
-- purely-additive non-panicking entry: it returns the same parse on success and
-- a located, structured `ParseError` on failure, leaving `parse` byte-identical.
--
-- `ParseError line col message` mirrors `lib/loader.ml`'s
--   ParseError { file; line; col; message }
-- (the `file` field is the caller's concern — not carried here), with the same
-- `L:C` numbering the OCaml oracle prints: 1-based line, 0-based column derived
-- from the error token's char offset via the lexer's `offsetToLineCol`.
public export data ParseError = ParseError Int Int String

export parseErrorLine : ParseError -> Int
parseErrorLine (ParseError l _ _) = l

export parseErrorCol : ParseError -> Int
parseErrorCol (ParseError _ c _) = c

export parseErrorMessage : ParseError -> String
parseErrorMessage (ParseError _ _ m) = m

-- Char offset of token index `i` from the parallel offset array.  Two synthetic
-- tail tokens (a trailing NEWLINE and the EOF) carry offset 0 rather than a real
-- source position, so an end-of-input failure must NOT resolve through them or
-- it mislocates to 1:0.  `locateOffset` therefore pins any failure AT-OR-AFTER
-- the last real token (TEof, or an index past the array) to the source length —
-- i.e. end-of-file — and otherwise returns the token's own offset.
offsetAt : Array Int -> Int -> Int -> Int
offsetAt offs srcLen i
  | i < arrayLength offs = arrayGetUnsafe i offs
  | otherwise = srcLen

-- Resolve a failing token index to a char offset, treating the EOF / past-end
-- positions as end-of-file (srcLen) so a dangling-operator / unexpected-EOF
-- error lands at the file's end rather than the synthetic token's bogus 0.
locateOffset : Array Token -> Array Int -> Int -> Int -> Int
locateOffset toks offs srcLen pos
  | pos >= arrayLength toks = srcLen
  | peekTok toks pos == TEof = srcLen
  | otherwise = offsetAt offs srcLen pos

-- Non-panicking analog of `resultDecls`: turn a finished parse into a structured
-- result.  `PErr msg pos` → located error at `pos`; a `POk` that did not consume
-- through `TEof` → "parse error" at the first leftover token (mirroring the
-- OCaml oracle, which reports the cursor where the grammar got stuck).
resultDeclsResult : String -> Array Token -> Array Int -> Int -> PR (List Decl) -> Result ParseError (List Decl)
resultDeclsResult src toks offs srcLen (PErr msg pos) =
  Err (mkLocated src toks offs srcLen msg pos)
resultDeclsResult src toks offs srcLen (PFatal msg pos) =
  Err (mkLocated src toks offs srcLen msg pos)
resultDeclsResult src toks offs srcLen (POk ds pos)
  | peekTok toks pos == TEof = Ok ds
  | otherwise = Err (deepenLeftover src toks offs srcLen pos)

-- A leftover-token `POk` means `many declThenNoise` stopped: the next decl failed
-- to parse and its real error was swallowed (both `many` and the `orElse`s inside
-- the decl discard failed alternatives).  The cursor sits at the START of that
-- un-parseable decl, so a bare report there just names the decl head
-- (`unexpected \`main\``).  Re-run `parseDecl` from that cursor to recover the
-- FURTHEST failure inside the body — `orElseR` now propagates the deeper of two
-- failed alternatives — and locate the error AT that offending token.  Fall back
-- to the plain leftover message when the re-run reaches no deeper than the cursor
-- (so already-well-located parse errors keep their exact spot).
deepenLeftover : String -> Array Token -> Array Int -> Int -> Int -> ParseError
deepenLeftover src toks offs srcLen pos = match runP parseDecl toks pos
  PFatal msg2 pos2 => mkLocated src toks offs srcLen msg2 pos2
  PErr msg2 pos2 if pos2 > pos => mkLocated src toks offs srcLen msg2 pos2
  _ => mkLocated src toks offs srcLen (unexpectedLeftoverMsg src toks offs srcLen pos) pos

-- offset(idx) → (line,col) → ParseError, single place so both arms agree.
mkLocated : String -> Array Token -> Array Int -> Int -> String -> Int -> ParseError
mkLocated src toks offs srcLen msg pos = match offsetToLineCol src (locateOffset toks offs srcLen pos)
  (line, col) => ParseError line col msg

-- Is the char at `offset` the first non-whitespace character on its line?  If
-- so, return `Some col` where `col` is its (0-based, tab-not-expanded — same
-- convention as `offsetToLineCol`) column; otherwise `None`.  Used to detect a
-- leftover-token parse error caused by a misindented line (dedented to a
-- column that doesn't match any enclosing block) so the message can hint at
-- the fix instead of just naming the unexpected token.
leadingIndentAt : String -> Int -> Option Int
leadingIndentAt src offset =
  let chars = stringToChars src
  let lineStart = leadingIndentLineStart chars (offset - 1)
  if leadingIndentAllBlank chars lineStart offset then
    Some (offset - lineStart)
  else
    None

leadingIndentLineStart : Array Char -> Int -> Int
leadingIndentLineStart chars i
  | i < 0 = 0
  | arrayGetUnsafe i chars == '\n' = i + 1
  | otherwise = leadingIndentLineStart chars (i - 1)

leadingIndentAllBlank : Array Char -> Int -> Int -> Bool
leadingIndentAllBlank chars i limit
  | i >= limit = True
  | otherwise = match arrayGetUnsafe i chars
    ' ' => leadingIndentAllBlank chars (i + 1) limit
    '\t' => leadingIndentAllBlank chars (i + 1) limit
    _ => False

-- Build the leftover-token "unexpected `X`" message, appending an
-- indentation-aware hint when the token is the sole content that dedented
-- this line to a column that doesn't line up with the surrounding block.
unexpectedLeftoverMsg : String -> Array Token -> Array Int -> Int -> Int -> String
unexpectedLeftoverMsg src toks offs srcLen pos =
  let base = "unexpected " ++ describeToken (peekTok toks pos)
  let offset = locateOffset toks offs srcLen pos
  match leadingIndentAt src offset
    Some col if col > 0 => leadingIndentMsg (peekTok toks pos) base col
    _ => base

-- `->` is deliberately absent from the leading-operator continuation set
-- (LAYOUT-SEMANTICS.md §5: the 7 leading ops are `|> >> << && || ++ ::`;
-- arrows are excluded on both the leading AND trailing side). So a line that
-- starts with `->` is rejected at ANY indentation — the generic
-- "indentation doesn't match" message is false here (re-indenting can never
-- fix it) and names the wrong root cause (#66). Name the true one and the
-- real fix: put `->` at the end of the previous line instead, where it
-- heralds the indented continuation the writer wanted.
leadingIndentMsg : Token -> String -> Int -> String
leadingIndentMsg TArrow base col = "\{base}. A line can't start with `->` — it's not a supported continuation at any indentation; put `->` at the end of the previous line instead (e.g. `f : Int ->` then an indented `Int`)"
leadingIndentMsg _ base col = "\{base}. Indentation (column \{intToString col}) doesn't match the enclosing block"

-- A lexer error (unterminated string / block comment, invalid escape, stray
-- character) is surfaced as a terminal `TLexError msg` token carrying the
-- offending offset (in the parallel offset array) rather than a raw panic.
-- Detecting it here — before the grammar runs — lets it flow through the SAME
-- located `ParseError` path as a real parse error, so the driver renders it
-- `file:L:C: msg` (identical treatment to `unexpected '/='`).  Returns the token
-- index + message of the first such token, or `None`.
firstLexError : Array Token -> Int -> Option (Int, String)
firstLexError toks i
  | i >= arrayLength toks = None
  | otherwise = match peekTok toks i
    TLexError msg => Some (i, msg)
    _ => firstLexError toks (i + 1)

-- `/=` is not a Medaka operator (not-equal is spelled `!=`); the lexer tags it
-- as a distinct `TSlashEq` so we can locate it precisely and suggest the fix,
-- rather than letting it split into `/` `=` and mislocate to end-of-file.
-- Index of the first `TSlashEq` in the stream, or -1 if absent.
firstSlashEqIdx : Array Token -> Int -> Int
firstSlashEqIdx toks i
  | i >= arrayLength toks = 0 - 1
  | peekTok toks i == TSlashEq = i
  | otherwise = firstSlashEqIdx toks (i + 1)

-- beta mutability model: `let mut` has been removed. `mut` (TMut) is a keyword
-- with no remaining valid use, so its presence is always the removed `let mut`.
-- A pre-grammar token scan surfaces a clean, located error (pointing at `mut`)
-- instead of the recursive-descent's swallowed-then-"expected dedent" fallback
-- (`stmtsLoop`'s `orElse … (pure [])` discards a failed statement's own error).
firstMutIdx : Array Token -> Int -> Int
firstMutIdx toks i
  | i >= arrayLength toks = 0 - 1
  | peekTok toks i == TMut = i
  | otherwise = firstMutIdx toks (i + 1)

-- `record` has been removed as a declaration keyword (records are now the
-- `data X = { … }` short form).  `record` (TRecord) is a reserved word with no
-- remaining valid use, so its presence is always the removed keyword.  A
-- pre-grammar token scan surfaces a located hint (pointing at `record`).
-- Index of the first `TRecord` in the stream, or -1 if absent.
firstRecordIdx : Array Token -> Int -> Int
firstRecordIdx toks i
  | i >= arrayLength toks = 0 - 1
  | peekTok toks i == TRecord = i
  | otherwise = firstRecordIdx toks (i + 1)

-- `function` has been removed as a keyword: a point-free one-arg match is
-- spelled `x => match x { … }`, or as a multi-clause definition.  `function`
-- (TFunction) is a reserved word with no remaining valid use, so its presence
-- is always the removed keyword.  A pre-grammar token scan surfaces a located
-- hint (pointing at `function`).
-- Index of the first `TFunction` in the stream, or -1 if absent.
firstFunctionIdx : Array Token -> Int -> Int
firstFunctionIdx toks i
  | i >= arrayLength toks = 0 - 1
  | peekTok toks i == TFunction = i
  | otherwise = firstFunctionIdx toks (i + 1)

-- Scan forward from token index `i` (depth=accumulated INDENT/DEDENT) looking
-- for `TIn` at depth=0 before the enclosing block exits (a `TDedent` that would
-- take depth below 0, or `TEof`).  Returns True if the inline `let` is
-- well-formed (has a matching `in`), False if it is missing one.
scanForLetIn : Array Token -> Int -> Int -> Bool
scanForLetIn toks i depth
  | i >= arrayLength toks = False
  | peekTok toks i == TIn && depth == 0 = True
  | peekTok toks i == TIndent = scanForLetIn toks (i + 1) (depth + 1)
  | peekTok toks i == TDedent && depth == 0 = False
  | peekTok toks i == TDedent = scanForLetIn toks (i + 1) (depth - 1)
  | peekTok toks i == TEof = False
  | otherwise = scanForLetIn toks (i + 1) depth

-- Find the first inline `let` that follows `else` or `then` and is missing
-- its `in` (the continuation body is on the next line instead).  Returns the
-- token index of the offending `let`, or -1 if no such pattern is found.
-- Called as a pre-scan in `parseResult` so the helpful error is surfaced
-- before the grammar absorbs the failure as a "leftover tokens" error at 2:0.
firstInlineLetMissingIn : Array Token -> Int -> Int
firstInlineLetMissingIn toks i
  | i + 1 >= arrayLength toks = 0 - 1
  | (peekTok toks i == TElse || peekTok toks i == TThen) && peekTok toks (i + 1) == TLet = if scanForLetIn toks (i + 2) 0 then firstInlineLetMissingIn toks (i + 1) else i + 1
  | otherwise = firstInlineLetMissingIn toks (i + 1)

inlineLetMissingInMsg : String
inlineLetMissingInMsg = "inline 'let' requires 'in': 'else let x = e in body'. For a multi-statement body, put 'else' on its own line and indent"

-- `case … of` is a Haskell-ism: Medaka spells pattern matching `match e` with
-- indented `pattern => body` arms and has no `of` keyword after a bare `case`
-- ident (`case` itself is not reserved — it lexes as a plain `TIdent`).
-- Discriminator: a `TIdent "case"` followed by a `TOf` before the enclosing
-- block exits, with NO intervening `TImpl` — `of` is otherwise only valid
-- right after `impl X Y of …`, so if an `impl`/`TImpl` appears first, the
-- `TOf` we'd find belongs to THAT construct, not this `case`, and we must not
-- match. Depth-tracked the same way `scanForLetIn` bounds its search.
caseHasOfBeforeBoundary : Array Token -> Int -> Int -> Bool
caseHasOfBeforeBoundary toks i depth
  | i >= arrayLength toks = False
  | peekTok toks i == TOf = True
  | peekTok toks i == TImpl = False
  | peekTok toks i == TIndent = caseHasOfBeforeBoundary toks (i + 1) (depth + 1)
  | peekTok toks i == TDedent && depth == 0 = False
  | peekTok toks i == TDedent = caseHasOfBeforeBoundary toks (i + 1) (depth - 1)
  | peekTok toks i == TEof = False
  | otherwise = caseHasOfBeforeBoundary toks (i + 1) depth

-- Index of the first `case` ident that resolves to a Haskell `case … of`
-- (per the discriminator above), or -1 if none.
firstHsCaseOfIdx : Array Token -> Int -> Int
firstHsCaseOfIdx toks i
  | i >= arrayLength toks = 0 - 1
  | peekTok toks i == TIdent "case" =
    if caseHasOfBeforeBoundary toks (i + 1) 0 then
      i
    else
      firstHsCaseOfIdx toks (i + 1)
  | otherwise = firstHsCaseOfIdx toks (i + 1)

hsCaseOfMsg : String
hsCaseOfMsg = "Medaka has no 'case … of'. Use 'match e' with indented 'pattern => body' arms"

-- Backtick infix application (``x `f` y``) has been removed.  `TBacktickIdent`
-- is a sentinel with no remaining valid use, so its presence is always the
-- removed construct.  A pre-grammar token scan surfaces a located hint.
-- Index of the first `TBacktickIdent` in the stream, or -1 if absent.
firstBacktickIdx : Array Token -> Int -> Int
firstBacktickIdx toks i
  | i >= arrayLength toks = 0 - 1
  | otherwise = match peekTok toks i
    TBacktickIdent _ => i
    _ => firstBacktickIdx toks (i + 1)

backtickInfixMsg : String
backtickInfixMsg = "backtick infix application (`f`) is not supported — use prefix application `f x y`"

-- `let rec … with …` mutual-recursion grouping has been removed: each
-- recursive binding is its own `let rec`. `with` (TWith) is now used nowhere
-- else in the grammar, so its presence is always the removed construct.  A
-- pre-grammar token scan surfaces a located hint (pointing at `with`).
-- Index of the first `TWith` in the stream, or -1 if absent.
firstWithIdx : Array Token -> Int -> Int
firstWithIdx toks i
  | i >= arrayLength toks = 0 - 1
  | peekTok toks i == TWith = i
  | otherwise = firstWithIdx toks (i + 1)

letRecWithRemovedMsg : String
letRecWithRemovedMsg = "`let rec … with` (mutual-recursion grouping) has been removed — define each binding as a separate `let rec`"

-- Haskell type signature (`f :: T`) vs Medaka's single-colon `f : T`: `::` is
-- Medaka's CONS operator (`x :: xs`), a legitimate infix op that appears all
-- over real bodies/guards (`f = 1 :: [2,3]`, `f x | y :: z = …`) AND in match-
-- arm cons patterns (`x :: rest => …`), which sit right after the INDENT that
-- opens the match body — so "immediately after any INDENT" is NOT a safe
-- boundary (that regressed on exactly this shape). The only position that is
-- NEVER legal Medaka is a TOP-LEVEL decl-head ident (depth 0 — outside every
-- block) IMMEDIATELY followed by `::`: no valid grammar production puts `::`
-- right after a fresh top-level decl head. Discriminator: `depth == 0` AND
-- `boundary` (true at the very start of the stream, right after a NEWLINE
-- seen at depth 0, or right after a DEDENT that returns to depth 0 — i.e. the
-- position a new top-level decl can start) AND `TIdent` immediately followed
-- by `TCons`. `depth` is the same INDENT/DEDENT counter `scanForLetIn` uses.
isPlainIdentTok : Token -> Bool
isPlainIdentTok (TIdent _) = True
isPlainIdentTok _ = False

-- Returns the index of the offending `::` (for location purposes), or -1.
firstHsSigIdx : Array Token -> Int -> Int -> Bool -> Int
firstHsSigIdx toks i depth boundary
  | i >= arrayLength toks = 0 - 1
  | boundary && depth == 0 && isPlainIdentTok (peekTok toks i) && peekTok toks (i + 1) == TCons = i + 1
  | peekTok toks i == TIndent = firstHsSigIdx toks (i + 1) (depth + 1) False
  | peekTok toks i == TDedent =
    firstHsSigIdx toks (i + 1) (depth - 1) (depth - 1 == 0)
  | peekTok toks i == TNewline = firstHsSigIdx toks (i + 1) depth (depth == 0)
  | otherwise = firstHsSigIdx toks (i + 1) depth False

hsSigMsg : String
hsSigMsg =
  "Use '::' for List cons. A type signature uses a single colon: 'f : T'"

-- ── Stage-2 foreign-syntax pre-scans (PARSE-ERROR-LOCATION-DESIGN §3) ─────────
-- Each mirrors the existing `/=`/`case…of`/`::` hints: a pure token scan that
-- fires ONLY on shapes that are never valid Medaka, returning the offending token
-- index so the located `ParseError` dodges the `1:0` collapse.  Every scanner
-- carries a valid-input safety proof in its comment; the risk is a false positive
-- on VALID code (esp. records vs braces — see `firstBraceBlockIdx`).

-- A bracket opener / closer (paren, bracket, brace) — used to track nesting so a
-- scan only reasons about tokens at its own bracket level.
isBracketOpenTok : Token -> Bool
isBracketOpenTok TLParen = True
isBracketOpenTok TLBracket = True
isBracketOpenTok TLBracketTight = True
isBracketOpenTok TLBrace = True
isBracketOpenTok _ = False

isBracketCloseTok : Token -> Bool
isBracketCloseTok TRParen = True
isBracketCloseTok TRBracket = True
isBracketCloseTok TRBrace = True
isBracketCloseTok _ = False

-- `/* … */`: Medaka's block comments are `{- … -}` and its line comments `--`.
-- The lexer tags `/` `*` as two ordinary operator tokens (`TSlash`, `TStar`);
-- an adjacent `TSlash TStar` (`/*`) is NEVER valid Medaka — `/` is binary divide
-- and `*` has no prefix form, so `1 / *x` cannot parse.  Located at the `/`.
firstBlockCommentIdx : Array Token -> Int -> Int
firstBlockCommentIdx toks i
  | i + 1 >= arrayLength toks = 0 - 1
  | peekTok toks i == TSlash && peekTok toks (i + 1) == TStar = i
  | otherwise = firstBlockCommentIdx toks (i + 1)

blockCommentMsg : String
blockCommentMsg = "Medaka has no '/* … */' block comments. Use '{- … -}' (block) or '--' (line)"

-- Brace-block `if` (`if cond { … } else { … }`): C-style braces used as an if
-- body.  SAFETY (the sharp hazard — braces vs record literals `{ f = v }` /
-- `{ r | f = v }`): a VALID `if` ALWAYS has `then` at if-level before any body,
-- so we scan the if-header at if-bracket-level and ABORT the moment we see a
-- `then` at that level.  A record literal in the CONDITION (`if {x}.b then …`)
-- is thus always excused — its `then` follows.  We only fire when a `{` appears
-- at if-level AND the header ends (an `else`/newline/eof at if-level) with NO
-- `then` — which no valid `if` ever does.  So valid records (which never sit in
-- an `if` header without a following `then`) cannot trip this.  Located at `{`.
braceBlockFrom : Array Token -> Int -> Int -> Int -> Int
braceBlockFrom toks i depth cand
  | i >= arrayLength toks = if depth == 0 then cand else 0 - 1
  | peekTok toks i == TThen && depth == 0 = 0 - 1
  | peekTok toks i == TElse && depth == 0 = cand
  | (peekTok toks i == TNewline || peekTok toks i == TEof) && depth == 0 = cand
  | peekTok toks i == TLBrace && depth == 0 && cand < 0 =
    braceBlockFrom toks (i + 1) (depth + 1) i
  | isBracketOpenTok (peekTok toks i) =
    braceBlockFrom toks (i + 1) (depth + 1) cand
  | isBracketCloseTok (peekTok toks i) =
    braceBlockFrom toks (i + 1) (depth - 1) cand
  | otherwise = braceBlockFrom toks (i + 1) depth cand

firstBraceBlockIdx : Array Token -> Int -> Int
firstBraceBlockIdx toks i
  | i >= arrayLength toks = 0 - 1
  | peekTok toks i == TIf =
    if braceBlockFrom toks (i + 1) 0 (0 - 1) >= 0 then
      braceBlockFrom toks (i + 1) 0 (0 - 1)
    else
      firstBraceBlockIdx toks (i + 1)
  | otherwise = firstBraceBlockIdx toks (i + 1)

braceBlockMsg : String
braceBlockMsg = "unexpected '{'. Medaka has no brace blocks; use 'then'/'else' with indentation, not '{ … }'"

-- `for`/`while` loops and `def`/`function`-style headers: these lex as plain
-- `TIdent`s (`for`, `while`, `def` are NOT reserved).  A foreign loop/def is
-- recognised by a line that STARTS with one of these words and ENDS in a trailing
-- `:` (C/Python statement colon) with NO `=` on that line.  SAFETY: a valid decl
-- named `for`/`while`/`def` is a binding or function head — it ALWAYS has `=`
-- (`for = e`, `for x = e`), so `sawEq` excludes it; a valid TYPE SIGNATURE
-- (`for : Int`) has its type AFTER the colon, so the colon is not trailing
-- (`lastColon` is False at the line break).  A trailing `:` with no `=` is never
-- valid Medaka.  Located at the keyword.
isForeignKwTok : Token -> Bool
isForeignKwTok (TIdent "for") = True
isForeignKwTok (TIdent "while") = True
isForeignKwTok (TIdent "def") = True
isForeignKwTok (TIdent "elif") = True
isForeignKwTok (TIdent "class") = True
isForeignKwTok (TIdent "try") = True
isForeignKwTok (TIdent "except") = True
isForeignKwTok (TIdent "finally") = True
isForeignKwTok _ = False

lineTrailingColonNoEq : Array Token -> Int -> Int -> Bool -> Bool -> Bool
lineTrailingColonNoEq toks i depth lastColon sawEq
  | i >= arrayLength toks = lastColon && not sawEq
  | depth == 0 && (peekTok toks i == TNewline || peekTok toks i == TEof || peekTok toks i == TIndent || peekTok toks i == TDedent) = lastColon && not sawEq
  | peekTok toks i == TEqual && depth == 0 =
    lineTrailingColonNoEq toks (i + 1) depth False True
  | peekTok toks i == TColon && depth == 0 =
    lineTrailingColonNoEq toks (i + 1) depth True sawEq
  | isBracketOpenTok (peekTok toks i) =
    lineTrailingColonNoEq toks (i + 1) (depth + 1) False sawEq
  | isBracketCloseTok (peekTok toks i) =
    lineTrailingColonNoEq toks (i + 1) (depth - 1) False sawEq
  | otherwise = lineTrailingColonNoEq toks (i + 1) depth False sawEq

firstForeignKwIdx : Array Token -> Int -> Bool -> Int
firstForeignKwIdx toks i lineStart
  | i >= arrayLength toks = 0 - 1
  | lineStart && isForeignKwTok (peekTok toks i) && lineTrailingColonNoEq toks i 0 False False = i
  | peekTok toks i == TNewline || peekTok toks i == TIndent || peekTok toks i == TDedent = firstForeignKwIdx toks (i + 1) True
  | otherwise = firstForeignKwIdx toks (i + 1) False

foreignKwMsg : Token -> String
foreignKwMsg (TIdent "def") =
  "Medaka has no 'def'. Define a function as 'f x = …'"
foreignKwMsg (TIdent "while") =
  "Medaka has no 'while' loops. Use recursion or list functions"
foreignKwMsg (TIdent "elif") = "Medaka has no 'elif'. Chain conditions with 'else if', or use function guards"
foreignKwMsg (TIdent "class") = "Medaka has no 'class'. Define a type with 'data'/'record', or an interface with 'interface'"
foreignKwMsg (TIdent "try") = "Medaka has no 'try'/exceptions. Return errors as values with 'Result'/'Option'"
foreignKwMsg (TIdent "except") = "Medaka has no 'except'/exceptions. Handle errors as values with 'Result'/'Option'"
foreignKwMsg (TIdent "finally") = "Medaka has no 'finally'/exceptions. Errors are values ('Result'/'Option'), not caught"
foreignKwMsg _ = "Medaka has no 'for' loops. Use recursion or list functions like 'map'/'forEach'/'fold'"

-- `;` statement terminator: the lexer surfaces a stray `;` as a `TLexError
-- "unexpected character ';'"`.  We recognise that message and replace it with a
-- beginner hint (Medaka is newline/indentation-separated).  Located at the `;`.
semicolonMsg : String
semicolonMsg =
  "Medaka has no statement terminator ';'. Separate statements with newlines"

-- Parse `src`, returning `Ok decls` or a structured, located `Err ParseError`.
-- Purely additive: does NOT touch the panicking `parse` path the happy-path
-- drivers (check / eval / fmt) rely on.
export parseResult : String -> Result ParseError (List Decl)
parseResult src = match tokenizeWithOffsets src
  (tokList, offList) => parseResultWith src tokList offList

-- Non-panicking located parse: the `parseResult` of `parseLocated`.  Sets the
-- loc-state refs from the (start, end) offset pairs — so the ELoc wrappers carry
-- REAL line/col, exactly as `parseLocated` does — then runs the SAME scanners and
-- grammar as `parseResult` via the shared `parseResultWith` body.  The loader
-- uses this so a parse/lex error in an imported module surfaces as located DATA
-- (issue #100) instead of `parseLocated`'s `panic "parse error"`.
--
-- `tokenizeWithOffsetPairs` yields the byte-identical token stream
-- `tokenizeWithOffsets` does (both are `layout*` over the same chars) and its
-- pair STARTS are exactly the latter's offsets, so `map fst` feeds
-- `parseResultWith` the array it expects — one tokenize, not two.
export parseLocatedResult : String -> Result ParseError (List Decl)
parseLocatedResult src = match tokenizeWithOffsetPairs src
  (tokList, offPairs) =>
    let _ = setLocState src (arrayFromList offPairs)
    parseResultWith src tokList (map fst offPairs)

-- Shared body of `parseResult` / `parseLocatedResult`: the removed-construct and
-- lex-error pre-scans, then the grammar, over an ALREADY-tokenized stream.  Split
-- out so the located entry does not have to tokenize a second time (the loader
-- parses every module in the graph through it).
parseResultWith : String -> List Token -> List Int -> Result ParseError (List Decl)
parseResultWith src tokList offList =
  let toks = arrayFromList tokList
  let offs = arrayFromList offList
  let srcLen = stringLength src
  let seIdx = firstSlashEqIdx toks 0
  let lmIdx = firstMutIdx toks 0
  let recIdx = firstRecordIdx toks 0
  let fnIdx = firstFunctionIdx toks 0
  let ilIdx = firstInlineLetMissingIn toks 0
  let coIdx = firstHsCaseOfIdx toks 0
  let btIdx = firstBacktickIdx toks 0
  let wiIdx = firstWithIdx toks 0
  let sigIdx = firstHsSigIdx toks 0 0 True
  let bcIdx = firstBlockCommentIdx toks 0
  let bbIdx = firstBraceBlockIdx toks 0
  let fkwIdx = firstForeignKwIdx toks 0 True
  match firstLexError toks 0
    Some (leIdx, leMsg) =>
      let leMsg2 = if leMsg == "unexpected character ';'" then
        semicolonMsg
      else
        leMsg
      Err (mkLocated src toks offs srcLen leMsg2 leIdx)
    None =>
      if seIdx >= 0 then
        Err (mkLocated src toks offs srcLen "unexpected '/='. (Did you mean '!='?)" seIdx)
      else if lmIdx >= 0 then
        Err (mkLocated src toks offs srcLen letMutRemovedMsg lmIdx)
      else if recIdx >= 0 then
        Err (mkLocated src toks offs srcLen recordRemovedMsg recIdx)
      else if fnIdx >= 0 then
        Err (mkLocated src toks offs srcLen functionRemovedMsg fnIdx)
      else if ilIdx >= 0 then
        Err (mkLocated src toks offs srcLen inlineLetMissingInMsg ilIdx)
      else if coIdx >= 0 then
        Err (mkLocated src toks offs srcLen hsCaseOfMsg coIdx)
      else if btIdx >= 0 then
        Err (mkLocated src toks offs srcLen backtickInfixMsg btIdx)
      else if wiIdx >= 0 then
        Err (mkLocated src toks offs srcLen letRecWithRemovedMsg wiIdx)
      else if sigIdx >= 0 then
        Err (mkLocated src toks offs srcLen hsSigMsg sigIdx)
      else if bcIdx >= 0 then
        Err (mkLocated src toks offs srcLen blockCommentMsg bcIdx)
      else if bbIdx >= 0 then
        Err (mkLocated src toks offs srcLen braceBlockMsg bbIdx)
      else if fkwIdx >= 0 then
        Err (mkLocated src toks offs srcLen (foreignKwMsg (peekTok toks fkwIdx)) fkwIdx)
      else
        resultDeclsResult src toks offs srcLen (runP parseProgram toks 0)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "DeriveRef" true) (mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "Loc" true) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberOrigin" false) (mem "useMemberAlias" false) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true) (mem "Attr" true) (mem "Route" true))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "tokenize" false) (mem "tokenizeWithLines" false) (mem "tokenizeWithOffsets" false) (mem "tokenizeWithOffsetPairs" false) (mem "offsetToLineCol" false) (mem "lineStartsOf" false) (mem "offsetToLineColFast" false) (mem "describeToken" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinWith" false))))
(DUse false (UseGroup ("support" "char") ((mem "isUpper" false))))
(DData Public "PR" ("a") ((variant "POk" (ConPos (TyVar "a") (TyCon "Int"))) (variant "PErr" (ConPos (TyCon "String") (TyCon "Int"))) (variant "PFatal" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DData Public "Parser" ("a") ((variant "Parser" (ConPos (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyVar "a"))))))) ())
(DTypeSig false "runP" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyVar "a"))))))
(DFunDef false "runP" ((PCon "Parser" (PVar "f")) (PVar "toks") (PVar "pos")) (EApp (EApp (EVar "f") (EVar "toks")) (EVar "pos")))
(DTypeSig false "mapPR" (TyFun (TyFun (TyVar "a") (TyVar "b")) (TyFun (TyApp (TyCon "PR") (TyVar "a")) (TyApp (TyCon "PR") (TyVar "b")))))
(DFunDef false "mapPR" ((PVar "f") (PCon "POk" (PVar "a") (PVar "pos"))) (EApp (EApp (EVar "POk") (EApp (EVar "f") (EVar "a"))) (EVar "pos")))
(DFunDef false "mapPR" (PWild (PCon "PErr" (PVar "e") (PVar "pos"))) (EApp (EApp (EVar "PErr") (EVar "e")) (EVar "pos")))
(DFunDef false "mapPR" (PWild (PCon "PFatal" (PVar "e") (PVar "pos"))) (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "pos")))
(DImpl false "Mappable" ((TyCon "Parser")) () ((im "map" ((PVar "f") (PVar "pa")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "mapPR") (EVar "f")) (EApp (EApp (EApp (EVar "runP") (EVar "pa")) (EVar "toks")) (EVar "pos"))))))))
(DTypeSig false "apPR" (TyFun (TyApp (TyCon "Parser") (TyFun (TyVar "a") (TyVar "b"))) (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyVar "b")))))))
(DFunDef false "apPR" ((PVar "pf") (PVar "pa") (PVar "toks") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runP") (EVar "pf")) (EVar "toks")) (EVar "pos")) (arm (PCon "POk" (PVar "f") (PVar "pos1")) () (EApp (EApp (EVar "mapPR") (EVar "f")) (EApp (EApp (EApp (EVar "runP") (EVar "pa")) (EVar "toks")) (EVar "pos1")))) (arm (PCon "PErr" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PErr") (EVar "e")) (EVar "pos1"))) (arm (PCon "PFatal" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "pos1")))))
(DImpl false "Applicative" ((TyCon "Parser")) () ((im "pure" ((PVar "x")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "POk") (EVar "x")) (EVar "pos"))))) (im "ap" ((PVar "pf") (PVar "pa")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "apPR") (EVar "pf")) (EVar "pa")) (EVar "toks")) (EVar "pos")))))))
(DTypeSig false "bindPR" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyApp (TyCon "Parser") (TyVar "b"))) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyVar "b")))))))
(DFunDef false "bindPR" ((PVar "pa") (PVar "k") (PVar "toks") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runP") (EVar "pa")) (EVar "toks")) (EVar "pos")) (arm (PCon "POk" (PVar "a") (PVar "pos1")) () (EApp (EApp (EApp (EVar "runP") (EApp (EVar "k") (EVar "a"))) (EVar "toks")) (EVar "pos1"))) (arm (PCon "PErr" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PErr") (EVar "e")) (EVar "pos1"))) (arm (PCon "PFatal" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "pos1")))))
(DImpl false "Thenable" ((TyCon "Parser")) () ((im "andThen" ((PVar "pa") (PVar "k")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "bindPR") (EVar "pa")) (EVar "k")) (EVar "toks")) (EVar "pos")))))))
(DTypeSig false "peekTok" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Token"))))
(DFunDef false "peekTok" ((PVar "toks") (PVar "pos")) (EIf (EBinOp "<" (EVar "pos") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EVar "toks")) (EIf (EVar "otherwise") (EVar "TEof") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "failP" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyVar "a"))))
(DFunDef false "failP" ((PVar "msg")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "PErr") (EVar "msg")) (EVar "pos")))))
(DTypeSig false "fatalP" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyVar "a"))))
(DFunDef false "fatalP" ((PVar "msg")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "PFatal") (EVar "msg")) (EVar "pos")))))
(DTypeSig false "fatalAtP" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyVar "a")))))
(DFunDef false "fatalAtP" ((PVar "msg") (PVar "pos0")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "_pos")) (EApp (EApp (EVar "PFatal") (EVar "msg")) (EVar "pos0")))))
(DTypeSig false "peekP" (TyApp (TyCon "Parser") (TyCon "Token")))
(DFunDef false "peekP" () (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "POk") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EVar "pos")))))
(DTypeSig false "peek2P" (TyApp (TyCon "Parser") (TyCon "Token")))
(DFunDef false "peek2P" () (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "POk") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EVar "pos")))))
(DTypeSig false "getPos" (TyApp (TyCon "Parser") (TyCon "Int")))
(DFunDef false "getPos" () (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "POk") (EVar "pos")) (EVar "pos")))))
(DTypeSig false "locSrcRef" (TyApp (TyCon "Ref") (TyCon "String")))
(DFunDef false "locSrcRef" () (EApp (EVar "Ref") (ELit (LString ""))))
(DTypeSig false "locOffsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "locOffsRef" () (EApp (EVar "Ref") (EApp (EVar "arrayFromList") (EListLit))))
(DTypeSig false "locLineStartsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "locLineStartsRef" () (EApp (EVar "Ref") (EApp (EVar "arrayFromList") (EListLit (ELit (LInt 0))))))
(DTypeSig false "setLocState" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "Unit"))))
(DFunDef false "setLocState" ((PVar "src") (PVar "offs")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "locSrcRef")) (EVar "src"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "locLineStartsRef")) (EApp (EVar "lineStartsOf") (EVar "src")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "locOffsRef")) (EVar "offs")))))
(DTypeSig false "tokOffsetAt" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "tokOffsetAt" ((PVar "i")) (EBlock (DoLet false false (PVar "offs") (EFieldAccess (EVar "locOffsRef") "value")) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs")))) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs"))) (ELit (LInt 0))))))
(DTypeSig false "tokEndOffsetAt" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "tokEndOffsetAt" ((PVar "i")) (EBlock (DoLet false false (PVar "offs") (EFieldAccess (EVar "locOffsRef") "value")) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs")))) (EApp (EVar "snd") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs"))) (ELit (LInt 0))))))
(DTypeSig false "locOfSpan" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Loc"))))
(DFunDef false "locOfSpan" ((PVar "startIdx") (PVar "endIdx")) (EBlock (DoLet false false (PVar "lineStarts") (EFieldAccess (EVar "locLineStartsRef") "value")) (DoLet false false (PVar "lastIdx") (EIf (EBinOp ">" (EVar "endIdx") (EVar "startIdx")) (EBinOp "-" (EVar "endIdx") (ELit (LInt 1))) (EVar "startIdx"))) (DoExpr (EMatch (EApp (EApp (EVar "offsetToLineColFast") (EVar "lineStarts")) (EApp (EVar "tokOffsetAt") (EVar "startIdx"))) (arm (PTuple (PVar "sl") (PVar "sc")) () (EMatch (EApp (EApp (EVar "offsetToLineColFast") (EVar "lineStarts")) (EApp (EVar "tokEndOffsetAt") (EVar "lastIdx"))) (arm (PTuple (PVar "el") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))))))))
(DTypeSig false "located" (TyFun (TyApp (TyCon "Parser") (TyCon "Expr")) (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "located" ((PVar "p")) (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "andThen") (EVar "p")) (ELam ((PVar "e")) (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "pure") (EApp (EApp (EVar "ELoc") (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "q"))) (EVar "e"))))))))))
(DTypeSig false "advance" (TyApp (TyCon "Parser") (TyCon "Token")))
(DFunDef false "advance" () (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "advanceR") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EVar "pos")))))
(DTypeSig false "advanceR" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyCon "Token")))))
(DFunDef false "advanceR" ((PCon "TEof") (PVar "pos")) (EApp (EApp (EVar "PErr") (ELit (LString "unexpected end of input"))) (EVar "pos")))
(DFunDef false "advanceR" ((PVar "t") (PVar "pos")) (EApp (EApp (EVar "POk") (EVar "t")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))
(DTypeSig false "emit" (TyFun (TyVar "a") (TyApp (TyCon "Parser") (TyVar "a"))))
(DFunDef false "emit" ((PVar "x")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EVar "x")))))
(DTypeSig false "expectTok" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "expectTok" ((PVar "t")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "x")) (EApp (EApp (EVar "expectGo") (EVar "t")) (EVar "x")))))
(DTypeSig false "expectGo" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit")))))
(DFunDef false "expectGo" ((PVar "t") (PVar "x")) (EIf (EBinOp "==" (EVar "x") (EVar "t")) (EApp (EVar "emit") (ELit LUnit)) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "unexpected ")) (EApp (EVar "display") (EApp (EVar "describeToken") (EVar "x")))) (ELit (LString "; expected "))) (EApp (EVar "display") (EApp (EVar "describeToken") (EVar "t")))) (ELit (LString ""))))))
(DTypeSig false "identNameP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "identNameP" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "identNameFor") (EVar "t")))))
(DTypeSig false "identNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "identNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "identNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected identifier"))))
(DTypeSig false "orElse" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyApp (TyCon "Parser") (TyVar "a")))))
(DFunDef false "orElse" ((PVar "pa") (PVar "pb")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "orElseR") (EVar "pa")) (EVar "pb")) (EVar "toks")) (EVar "pos")))))
(DTypeSig false "orElseR" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyVar "a")))))))
(DFunDef false "orElseR" ((PVar "pa") (PVar "pb") (PVar "toks") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runP") (EVar "pa")) (EVar "toks")) (EVar "pos")) (arm (PCon "POk" (PVar "x") (PVar "q")) () (EApp (EApp (EVar "POk") (EVar "x")) (EVar "q"))) (arm (PCon "PFatal" (PVar "ea") (PVar "qa")) () (EApp (EApp (EVar "PFatal") (EVar "ea")) (EVar "qa"))) (arm (PCon "PErr" (PVar "ea") (PVar "qa")) () (EApp (EApp (EApp (EVar "orElseRb") (EVar "ea")) (EVar "qa")) (EApp (EApp (EApp (EVar "runP") (EVar "pb")) (EVar "toks")) (EVar "pos"))))))
(DTypeSig false "orElseRb" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "PR") (TyVar "a")) (TyApp (TyCon "PR") (TyVar "a"))))))
(DFunDef false "orElseRb" (PWild PWild (PCon "POk" (PVar "y") (PVar "q"))) (EApp (EApp (EVar "POk") (EVar "y")) (EVar "q")))
(DFunDef false "orElseRb" (PWild PWild (PCon "PFatal" (PVar "eb") (PVar "qb"))) (EApp (EApp (EVar "PFatal") (EVar "eb")) (EVar "qb")))
(DFunDef false "orElseRb" ((PVar "ea") (PVar "qa") (PCon "PErr" (PVar "eb") (PVar "qb"))) (EIf (EBinOp ">" (EVar "qa") (EVar "qb")) (EApp (EApp (EVar "PErr") (EVar "ea")) (EVar "qa")) (EIf (EVar "otherwise") (EApp (EApp (EVar "PErr") (EVar "eb")) (EVar "qb")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "choice" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Parser") (TyVar "a"))) (TyApp (TyCon "Parser") (TyVar "a"))))
(DFunDef false "choice" ((PList)) (EApp (EVar "failP") (ELit (LString "no alternative"))))
(DFunDef false "choice" ((PCons (PVar "p") (PVar "ps"))) (EApp (EApp (EVar "orElse") (EVar "p")) (EApp (EVar "choice") (EVar "ps"))))
(DTypeSig false "many" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "many" ((PVar "p")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "toks")) (EVar "pos")) (EListLit)))))
(DTypeSig false "manyGo" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "PR") (TyApp (TyCon "List") (TyVar "a"))))))))
(DFunDef false "manyGo" ((PVar "p") (PVar "toks") (PVar "pos") (PVar "acc")) (EMatch (EApp (EApp (EApp (EVar "runP") (EVar "p")) (EVar "toks")) (EVar "pos")) (arm (PCon "POk" (PVar "x") (PVar "pos2")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "manyStep") (EVar "p")) (EVar "toks")) (EVar "pos")) (EVar "pos2")) (EVar "acc")) (EVar "x"))) (arm (PCon "PFatal" (PVar "e") (PVar "q")) () (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "q"))) (arm (PCon "PErr" PWild PWild) () (EApp (EApp (EVar "POk") (EApp (EVar "reverseL") (EVar "acc"))) (EVar "pos")))))
(DTypeSig false "manyStep" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyVar "a") (TyApp (TyCon "PR") (TyApp (TyCon "List") (TyVar "a"))))))))))
(DFunDef false "manyStep" ((PVar "p") (PVar "toks") (PVar "pos") (PVar "pos2") (PVar "acc") (PVar "x")) (EIf (EBinOp ">" (EVar "pos2") (EVar "pos")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "toks")) (EVar "pos2")) (EBinOp "::" (EVar "x") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "POk") (EApp (EVar "reverseL") (EBinOp "::" (EVar "x") (EVar "acc")))) (EVar "pos2")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sepThen" (TyFun (TyApp (TyCon "Parser") (TyVar "b")) (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyApp (TyCon "Parser") (TyVar "a")))))
(DFunDef false "sepThen" ((PVar "sep") (PVar "p")) (EApp (EApp (EVar "andThen") (EVar "sep")) (ELam (PWild) (EVar "p"))))
(DTypeSig false "sepBy1" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Parser") (TyVar "b")) (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sepBy1" ((PVar "p") (PVar "sep")) (EApp (EApp (EVar "andThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EApp (EApp (EVar "sepThen") (EVar "sep")) (EVar "p")))) (ELam ((PVar "xs")) (EApp (EVar "pure") (EBinOp "::" (EVar "x") (EVar "xs"))))))))
(DTypeSig false "optTrailingComma" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "optTrailingComma" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "optTrailingCommaFor") (EVar "t")))))
(DTypeSig false "optTrailingCommaFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "optTrailingCommaFor" ((PCon "TComma")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (ELit LUnit)))))
(DFunDef false "optTrailingCommaFor" (PWild) (EApp (EVar "pure") (ELit LUnit)))
(DTypeSig false "optTrailingCommaTuple" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "optTrailingCommaTuple" ((PList PWild)) (EApp (EVar "pure") (ELit LUnit)))
(DFunDef false "optTrailingCommaTuple" (PWild) (EVar "optTrailingComma"))
(DTypeSig false "chainl1" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Parser") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))) (TyApp (TyCon "Parser") (TyVar "a")))))
(DFunDef false "chainl1" ((PVar "p") (PVar "op")) (EApp (EApp (EVar "andThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EApp (EVar "chainl1Rest") (EVar "p")) (EVar "op")) (EVar "x")))))
(DTypeSig false "chainl1Rest" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Parser") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))) (TyFun (TyVar "a") (TyApp (TyCon "Parser") (TyVar "a"))))))
(DFunDef false "chainl1Rest" ((PVar "p") (PVar "op") (PVar "x")) (EApp (EApp (EVar "orElse") (EApp (EApp (EApp (EVar "chainl1More") (EVar "p")) (EVar "op")) (EVar "x"))) (EApp (EVar "pure") (EVar "x"))))
(DTypeSig false "chainl1More" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Parser") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))) (TyFun (TyVar "a") (TyApp (TyCon "Parser") (TyVar "a"))))))
(DFunDef false "chainl1More" ((PVar "p") (PVar "op") (PVar "x")) (EApp (EApp (EVar "andThen") (EVar "op")) (ELam ((PVar "f")) (EApp (EApp (EVar "andThen") (EVar "p")) (ELam ((PVar "y")) (EApp (EApp (EApp (EVar "chainl1Rest") (EVar "p")) (EVar "op")) (EApp (EApp (EVar "f") (EVar "x")) (EVar "y"))))))))
(DTypeSig false "skipNewlines" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "skipNewlines" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "skipNlFor") (EVar "t")))))
(DTypeSig false "skipNlFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "skipNlFor" ((PCon "TNewline")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EVar "skipNewlines"))))
(DFunDef false "skipNlFor" (PWild) (EApp (EVar "pure") (ELit LUnit)))
(DTypeSig false "parseExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseExpr" () (EApp (EApp (EVar "andThen") (EVar "parseAssign")) (ELam ((PVar "e")) (EApp (EApp (EVar "orElse") (EApp (EVar "annotTail") (EVar "e"))) (EApp (EVar "pure") (EVar "e"))))))
(DTypeSig false "parseAssign" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAssign" () (EApp (EApp (EVar "andThen") (EVar "parseLam")) (ELam ((PVar "e")) (EApp (EApp (EVar "orElse") (EApp (EVar "assignTail") (EVar "e"))) (EApp (EVar "pure") (EVar "e"))))))
(DTypeSig false "assignTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "assignTail" ((PVar "lhs")) (EApp (EVar "located") (EApp (EVar "assignTailRaw") (EVar "lhs"))))
(DTypeSig false "assignTailRaw" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "assignTailRaw" ((PVar "lhs")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TColonEq"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseAssign")) (ELam ((PVar "rhs")) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString ":="))) (EVar "lhs")) (EVar "rhs")) (EApp (EVar "Ref") (EVar "RNone")))))))))
(DTypeSig false "annotTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "annotTail" ((PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseTy")) (ELam ((PVar "t")) (EApp (EVar "pure") (EApp (EApp (EVar "EAnnot") (EVar "e")) (EVar "t"))))))))
(DTypeSig false "parseLam" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseLam" () (EApp (EApp (EVar "andThen") (EVar "parsePipe")) (ELam ((PVar "e")) (EApp (EApp (EVar "orElse") (EApp (EVar "lamTail") (EVar "e"))) (EApp (EVar "pure") (EVar "e"))))))
(DTypeSig false "parsePipe" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parsePipe" () (EApp (EApp (EVar "chainl1") (EVar "parseCompose")) (EApp (EApp (EVar "binOp") (EVar "TPipeRight")) (ELit (LString "|>")))))
(DTypeSig false "parseCompose" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseCompose" () (EApp (EApp (EVar "chainl1") (EVar "parseOr")) (EApp (EVar "choice") (EListLit (EApp (EApp (EVar "binOp") (EVar "TRCompose")) (ELit (LString ">>"))) (EApp (EApp (EVar "binOp") (EVar "TLCompose")) (ELit (LString "<<")))))))
(DTypeSig false "lamTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "lamTail" ((PVar "e")) (EApp (EVar "located") (EApp (EVar "lamTailRaw") (EVar "e"))))
(DTypeSig false "lamTailRaw" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "lamTailRaw" ((PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TFatArrow"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseRhsExpr")) (ELam ((PVar "body")) (EApp (EVar "pure") (EApp (EApp (EVar "ELam") (EApp (EVar "exprToParams") (EVar "e"))) (EVar "body"))))))))
(DTypeSig false "exprToParams" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "exprToParams" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "exprToParams") (EVar "e")))
(DFunDef false "exprToParams" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "appToParams") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))))
(DFunDef false "exprToParams" ((PVar "e")) (EListLit (EApp (EVar "exprToPat") (EVar "e"))))
(DTypeSig false "appToParams" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "appToParams" ((PVar "app")) (EApp (EApp (EVar "paramsForHead") (EApp (EVar "spineHead") (EVar "app"))) (EVar "app")))
(DTypeSig false "paramsForHead" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "paramsForHead" ((PCon "EVar" (PVar "c")) (PVar "app")) (EApp (EApp (EVar "paramsForCtor") (EVar "c")) (EVar "app")))
(DFunDef false "paramsForHead" (PWild (PVar "app")) (EApp (EApp (EVar "map") (EVar "exprToPat")) (EApp (EVar "spineList") (EVar "app"))))
(DTypeSig false "paramsForCtor" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "paramsForCtor" ((PVar "c") (PVar "app")) (EIf (EApp (EVar "isCtorName") (EVar "c")) (EListLit (EApp (EVar "exprToPat") (EVar "app"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "map") (EVar "exprToPat")) (EApp (EVar "spineList") (EVar "app"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "spineHead" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "spineHead" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "spineHead") (EVar "f")))
(DFunDef false "spineHead" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "spineHead") (EVar "e")))
(DFunDef false "spineHead" ((PVar "e")) (EVar "e"))
(DTypeSig false "spineList" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "spineList" ((PVar "e")) (EApp (EApp (EVar "spineOnto") (EVar "e")) (EListLit)))
(DTypeSig false "spineOnto" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "spineOnto" ((PCon "ELoc" PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EVar "spineOnto") (EVar "e")) (EVar "acc")))
(DFunDef false "spineOnto" ((PCon "EApp" (PVar "f") (PVar "x")) (PVar "acc")) (EApp (EApp (EVar "spineOnto") (EVar "f")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DFunDef false "spineOnto" ((PVar "e") (PVar "acc")) (EBinOp "::" (EVar "e") (EVar "acc")))
(DTypeSig false "exprToPat" (TyFun (TyCon "Expr") (TyCon "Pat")))
(DFunDef false "exprToPat" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "exprToPat") (EVar "e")))
(DFunDef false "exprToPat" ((PCon "EVar" (PLit (LString "_")))) (EVar "PWild"))
(DFunDef false "exprToPat" ((PCon "EVar" (PVar "x"))) (EApp (EVar "ctorOrVar") (EVar "x")))
(DFunDef false "exprToPat" ((PCon "ELit" (PVar "l"))) (EApp (EVar "PLit") (EVar "l")))
(DFunDef false "exprToPat" ((PCon "ENumLit" (PVar "n") PWild PWild PWild)) (EApp (EVar "PLit") (EApp (EVar "LInt") (EVar "n"))))
(DFunDef false "exprToPat" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "PTuple") (EApp (EApp (EVar "map") (EVar "exprToPat")) (EVar "es"))))
(DFunDef false "exprToPat" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "PList") (EApp (EApp (EVar "map") (EVar "exprToPat")) (EVar "es"))))
(DFunDef false "exprToPat" ((PCon "EBinOp" (PLit (LString "::")) (PVar "a") (PVar "b") PWild)) (EApp (EApp (EVar "PCons") (EApp (EVar "exprToPat") (EVar "a"))) (EApp (EVar "exprToPat") (EVar "b"))))
(DFunDef false "exprToPat" ((PCon "ESection" (PCon "SecLeft" (PVar "a") (PLit (LString "::"))))) (EApp (EApp (EVar "PCons") (EApp (EVar "exprToPat") (EVar "a"))) (EVar "PWild")))
(DFunDef false "exprToPat" ((PCon "EAsPat" (PVar "x") (PVar "sub"))) (EApp (EApp (EVar "PAs") (EVar "x")) (EApp (EVar "exprToPat") (EVar "sub"))))
(DFunDef false "exprToPat" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "appToPat") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))))
(DFunDef false "exprToPat" (PWild) (EVar "PWild"))
(DTypeSig false "ctorOrVar" (TyFun (TyCon "String") (TyCon "Pat")))
(DFunDef false "ctorOrVar" ((PVar "x")) (EIf (EApp (EVar "isCtorName") (EVar "x")) (EApp (EApp (EVar "PCon") (EVar "x")) (EListLit)) (EIf (EVar "otherwise") (EApp (EVar "PVar") (EVar "x")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "appToPat" (TyFun (TyCon "Expr") (TyCon "Pat")))
(DFunDef false "appToPat" ((PVar "app")) (EApp (EApp (EVar "appToPatH") (EApp (EVar "spineHead") (EVar "app"))) (EApp (EVar "spineList") (EVar "app"))))
(DTypeSig false "appToPatH" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Pat"))))
(DFunDef false "appToPatH" ((PCon "EVar" (PVar "c")) (PVar "spine")) (EApp (EApp (EVar "appToPatCtor") (EVar "c")) (EVar "spine")))
(DFunDef false "appToPatH" (PWild PWild) (EVar "PWild"))
(DTypeSig false "appToPatCtor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Pat"))))
(DFunDef false "appToPatCtor" ((PVar "c") (PVar "spine")) (EIf (EApp (EVar "isCtorName") (EVar "c")) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EVar "map") (EVar "exprToPat")) (EApp (EVar "dropFirst") (EVar "spine")))) (EIf (EVar "otherwise") (EVar "PWild") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dropFirst" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "dropFirst" ((PList)) (EListLit))
(DFunDef false "dropFirst" ((PCons PWild (PVar "xs"))) (EVar "xs"))
(DTypeSig false "isCtorName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isCtorName" ((PVar "s")) (EApp (EVar "isCtorChars") (EApp (EVar "stringToChars") (EVar "s"))))
(DTypeSig false "isCtorChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Bool")))
(DFunDef false "isCtorChars" ((PVar "cs")) (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EVar "False") (EIf (EVar "otherwise") (EApp (EVar "isUpper") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "stripLoc" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripLoc" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stripLoc") (EVar "e")))
(DFunDef false "stripLoc" ((PVar "e")) (EVar "e"))
(DTypeSig false "binOp" (TyFun (TyCon "Token") (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "binOp" ((PVar "tk") (PVar "op")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "tk"))) (ELam (PWild) (EApp (EVar "pure") (ELam ((PVar "l") (PVar "r")) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EApp (EVar "Ref") (EVar "RNone"))))))))
(DTypeSig false "parseOr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseOr" () (EApp (EApp (EVar "chainl1") (EVar "parseAnd")) (EApp (EApp (EVar "binOp") (EVar "TOr")) (ELit (LString "||")))))
(DTypeSig false "parseAnd" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAnd" () (EApp (EApp (EVar "chainl1") (EVar "parseCmp")) (EApp (EApp (EVar "binOp") (EVar "TAnd")) (ELit (LString "&&")))))
(DTypeSig false "parseCmp" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseCmp" () (EApp (EApp (EVar "chainl1") (EVar "parseCons")) (EVar "cmpOp")))
(DTypeSig false "cmpOp" (TyApp (TyCon "Parser") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "cmpOp" () (EApp (EVar "choice") (EListLit (EApp (EApp (EVar "binOp") (EVar "TEqEq")) (ELit (LString "=="))) (EApp (EApp (EVar "binOp") (EVar "TNeq")) (ELit (LString "!="))) (EApp (EApp (EVar "binOp") (EVar "TLt")) (ELit (LString "<"))) (EApp (EApp (EVar "binOp") (EVar "TGt")) (ELit (LString ">"))) (EApp (EApp (EVar "binOp") (EVar "TLeq")) (ELit (LString "<="))) (EApp (EApp (EVar "binOp") (EVar "TGeq")) (ELit (LString ">="))))))
(DTypeSig false "parseCons" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseCons" () (EApp (EApp (EVar "andThen") (EVar "parseAppend")) (ELam ((PVar "x")) (EApp (EApp (EVar "orElse") (EApp (EVar "consTail") (EVar "x"))) (EApp (EVar "pure") (EVar "x"))))))
(DTypeSig false "consTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "consTail" ((PVar "x")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TCons"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseCons")) (ELam ((PVar "y")) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "::"))) (EVar "x")) (EVar "y")) (EApp (EVar "Ref") (EVar "RNone")))))))))
(DTypeSig false "parseAppend" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAppend" () (EApp (EApp (EVar "chainl1") (EVar "parseAdd")) (EApp (EApp (EVar "binOp") (EVar "TPlusPlus")) (ELit (LString "++")))))
(DTypeSig false "parseAdd" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAdd" () (EApp (EApp (EVar "chainl1") (EVar "parseMul")) (EApp (EVar "choice") (EListLit (EApp (EApp (EVar "binOp") (EVar "TPlus")) (ELit (LString "+"))) (EApp (EApp (EVar "binOp") (EVar "TMinus")) (ELit (LString "-"))) (EApp (EApp (EVar "binOp") (EVar "TMinusTight")) (ELit (LString "-")))))))
(DTypeSig false "parseMul" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseMul" () (EApp (EApp (EVar "chainl1") (EVar "parseUnary")) (EApp (EVar "choice") (EListLit (EApp (EApp (EVar "binOp") (EVar "TStar")) (ELit (LString "*"))) (EApp (EApp (EVar "binOp") (EVar "TSlash")) (ELit (LString "/"))) (EApp (EApp (EVar "binOp") (EVar "TMod")) (ELit (LString "%")))))))
(DTypeSig false "intMinLit" (TyCon "Int"))
(DFunDef false "intMinLit" () (EBinOp "-" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 4611686018427387903))) (ELit (LInt 1))))
(DTypeSig false "isIntMinLit" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isIntMinLit" ((PVar "n")) (EBinOp "==" (EVar "n") (EVar "intMinLit")))
(DTypeSig false "intLitTooBigMsg" (TyCon "String"))
(DFunDef false "intLitTooBigMsg" () (ELit (LString "integer literal too large for Int (max 4611686018427387903)")))
(DTypeSig false "parseUnary" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseUnary" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "unaryFor") (EVar "t")))))
(DTypeSig false "unaryFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "unaryFor" ((PCon "TMinus")) (EVar "negUnary"))
(DFunDef false "unaryFor" ((PCon "TMinusTight")) (EVar "negUnary"))
(DFunDef false "unaryFor" ((PCon "TBang")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseUnary")) (ELam ((PVar "e")) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "EUnOp") (ELit (LString "!"))) (EVar "e")) (EApp (EVar "Ref") (EVar "RNone")))))))))
(DFunDef false "unaryFor" (PWild) (EVar "parseInfix"))
(DTypeSig false "negUnary" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "negUnary" () (EApp (EApp (EVar "andThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EVar "negUnaryFor") (EVar "t2")))))
(DTypeSig false "negUnaryFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "negUnaryFor" ((PCon "TInt" (PVar "n") (PVar "lx"))) (EIf (EApp (EVar "isIntMinLit") (EVar "n")) (EApp (EVar "located") (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EApp (EVar "Ref") (EVar "None"))) (EApp (EVar "Ref") (EVar "RNone"))) (EBinOp "++" (ELit (LString "-")) (EVar "lx"))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "negUnaryFor" (PWild) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseUnary")) (ELam ((PVar "e")) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "EUnOp") (ELit (LString "-"))) (EVar "e")) (EApp (EVar "Ref") (EVar "RNone")))))))))
(DTypeSig false "parseInfix" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseInfix" () (EVar "parseApp"))
(DTypeSig false "parseApp" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseApp" () (EApp (EApp (EVar "andThen") (EVar "parseAspat")) (ELam ((PVar "head")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EApp (EVar "appArg") (EApp (EVar "headIsNumeric") (EVar "head"))))) (ELam ((PVar "args")) (EApp (EVar "pure") (EApp (EApp (EVar "applyAll") (EVar "head")) (EVar "args"))))))))
(DTypeSig false "appArg" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "appArg" ((PVar "headNum")) (EApp (EApp (EVar "orElse") (EApp (EVar "negLitArg") (EVar "headNum"))) (EVar "parseAspat")))
(DTypeSig false "negLitArg" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "negLitArg" ((PCon "True")) (EApp (EVar "failP") (ELit (LString "numeric head: tight minus stays subtraction"))))
(DFunDef false "negLitArg" ((PCon "False")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "andThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EVar "negLitArgFor") (EVar "t")) (EVar "t2")))))))
(DTypeSig false "negLitArgFor" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "negLitArgFor" ((PCon "TMinusTight") (PCon "TInt" (PVar "n") (PVar "lx"))) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EVar "ENumLit") (EApp (EVar "negate") (EVar "n"))) (EApp (EVar "Ref") (EVar "None"))) (EApp (EVar "Ref") (EVar "RNone"))) (EBinOp "++" (ELit (LString "-")) (EVar "lx")))))))))
(DFunDef false "negLitArgFor" ((PCon "TMinusTight") (PCon "TFloat" (PVar "f"))) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "ELit") (EApp (EVar "LFloat") (EApp (EVar "negate") (EVar "f"))))))))))
(DFunDef false "negLitArgFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "not a tight negative literal argument"))))
(DTypeSig false "headIsNumeric" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "headIsNumeric" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "headIsNumeric") (EVar "e")))
(DFunDef false "headIsNumeric" ((PCon "ENumLit" PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "headIsNumeric" ((PCon "ELit" (PCon "LInt" PWild))) (EVar "True"))
(DFunDef false "headIsNumeric" ((PCon "ELit" (PCon "LFloat" PWild))) (EVar "True"))
(DFunDef false "headIsNumeric" (PWild) (EVar "False"))
(DTypeSig false "parseAspat" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAspat" () (EApp (EApp (EVar "orElse") (EVar "parseAspatAt")) (EVar "parsePostfix")))
(DTypeSig false "parseAspatAt" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAspatAt" () (EApp (EVar "located") (EVar "parseAspatAtRaw")))
(DTypeSig false "parseAspatAtRaw" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAspatAtRaw" () (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "x")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TAsAt"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parsePostfix")) (ELam ((PVar "sub")) (EApp (EVar "pure") (EApp (EApp (EVar "EAsPat") (EVar "x")) (EVar "sub"))))))))))
(DTypeSig false "applyAll" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "applyAll" ((PVar "head") (PList)) (EVar "head"))
(DFunDef false "applyAll" ((PVar "head") (PCons (PVar "a") (PVar "rest"))) (EApp (EApp (EVar "applyAll") (EApp (EApp (EVar "EApp") (EVar "head")) (EVar "a"))) (EVar "rest")))
(DTypeSig false "parsePostfix" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parsePostfix" () (EApp (EApp (EVar "andThen") (EVar "parseAtom")) (ELam ((PVar "e")) (EApp (EVar "postfixTail") (EVar "e")))))
(DTypeSig false "postfixTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "postfixTail" ((PVar "e")) (EApp (EApp (EVar "orElse") (EApp (EVar "bracketIndexTail") (EVar "e"))) (EApp (EApp (EVar "orElse") (EApp (EVar "dotTail") (EVar "e"))) (EApp (EVar "pure") (EVar "e")))))
(DTypeSig false "bracketIndexTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "bracketIndexTail" ((PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLBracketTight"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "lo")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "bracketIndexRest") (EVar "e")) (EVar "lo")) (EVar "t")))))))))
(DTypeSig false "bracketIndexRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "bracketIndexRest" (PWild PWild (PCon "TDotDot")) (EApp (EVar "failP") (ELit (LString "bare slice `a[i..j]` is not yet supported — use `a.[i..j]`"))))
(DFunDef false "bracketIndexRest" (PWild PWild (PCon "TDotDotEq")) (EApp (EVar "failP") (ELit (LString "bare slice `a[i..=j]` is not yet supported — use `a.[i..=j]`"))))
(DFunDef false "bracketIndexRest" ((PVar "e") (PVar "lo") (PCon "TRBracket")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "postfixTail") (EApp (EApp (EApp (EVar "EIndex") (EVar "e")) (EVar "lo")) (EApp (EVar "Ref") (ELit (LString "Array"))))))))
(DFunDef false "bracketIndexRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected ']' in index expression"))))
(DTypeSig false "dotTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "dotTail" ((PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDot"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dotFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "dotFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "dotFor" ((PVar "e") (PCon "TLBracket")) (EApp (EVar "indexOrSlice") (EVar "e")))
(DFunDef false "dotFor" ((PVar "e") PWild) (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "f")) (EApp (EVar "postfixTail") (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "e")) (EVar "f")) (EApp (EVar "Ref") (ELit (LString ""))))))))
(DTypeSig false "indexOrSlice" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "indexOrSlice" ((PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLBracket"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "lo")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "indexOrSliceRest") (EVar "e")) (EVar "lo")) (EVar "t")))))))))
(DTypeSig false "indexOrSliceRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "indexOrSliceRest" ((PVar "e") (PVar "lo") (PCon "TDotDot")) (EApp (EApp (EApp (EVar "sliceHi") (EVar "e")) (EVar "lo")) (EVar "False")))
(DFunDef false "indexOrSliceRest" ((PVar "e") (PVar "lo") (PCon "TDotDotEq")) (EApp (EApp (EApp (EVar "sliceHi") (EVar "e")) (EVar "lo")) (EVar "True")))
(DFunDef false "indexOrSliceRest" ((PVar "e") (PVar "lo") (PCon "TRBracket")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "postfixTail") (EApp (EApp (EApp (EVar "EIndex") (EVar "e")) (EVar "lo")) (EApp (EVar "Ref") (ELit (LString "Array"))))))))
(DFunDef false "indexOrSliceRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected .. ..= or ] in index/slice"))))
(DTypeSig false "sliceHi" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "sliceHi" ((PVar "e") (PVar "lo") (PVar "incl")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "hi")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EVar "postfixTail") (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EVar "e")) (EVar "lo")) (EVar "hi")) (EVar "incl")) (EApp (EVar "Ref") (ELit (LString "Array"))))))))))))
(DTypeSig false "parseAtom" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAtom" () (EApp (EVar "located") (EVar "parseAtomRaw")))
(DTypeSig false "parseAtomRaw" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAtomRaw" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") PWild) ((GBool (EApp (EVar "isIntMinLit") (EVar "n")))) (EApp (EVar "fatalP") (EVar "intLitTooBigMsg"))) (arm (PCon "TInt" (PVar "n") (PVar "lx")) () (EApp (EVar "emit") (EApp (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EApp (EVar "Ref") (EVar "None"))) (EApp (EVar "Ref") (EVar "RNone"))) (EVar "lx")))) (arm (PCon "TFloat" (PVar "f")) () (EApp (EVar "emit") (EApp (EVar "ELit") (EApp (EVar "LFloat") (EVar "f"))))) (arm (PCon "TString" (PVar "s")) () (EApp (EVar "emit") (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "s"))))) (arm (PCon "TChar" (PVar "s")) () (EApp (EVar "emit") (EApp (EVar "ELit") (EApp (EVar "LChar") (EVar "s"))))) (arm (PCon "TIdent" (PVar "x")) () (EApp (EVar "emit") (EApp (EVar "EVar") (EVar "x")))) (arm (PCon "TUpper" (PVar "x")) () (EApp (EVar "parseUpperAtom") (EVar "x"))) (arm (PCon "TUnderscore") () (EApp (EVar "emit") (EApp (EVar "EVar") (ELit (LString "_"))))) (arm (PCon "TLParen") () (EVar "parseParen")) (arm (PCon "TLBracket") () (EVar "parseListE")) (arm (PCon "TLArray") () (EVar "parseArray")) (arm (PCon "TLBrace") () (EVar "parseRecordUpdate")) (arm (PCon "TIf") () (EVar "parseIf")) (arm (PCon "TLet") () (EVar "parseLet")) (arm (PCon "TMatch") () (EVar "parseMatch")) (arm (PCon "TDo") () (EVar "parseDo")) (arm (PCon "TInterpOpen" PWild) () (EVar "parseInterp")) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected atom"))))))))
(DTypeSig false "parseUpperAtom" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parseUpperAtom" ((PVar "x")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "upperTail") (EVar "x")) (EVar "t")))))))
(DTypeSig false "upperTail" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "upperTail" ((PVar "x") (PCon "TLBrace")) (EApp (EVar "upperBrace") (EVar "x")))
(DFunDef false "upperTail" ((PVar "x") PWild) (EApp (EVar "pure") (EApp (EVar "EVar") (EVar "x"))))
(DTypeSig false "upperBrace" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "upperBrace" ((PVar "x")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EVar "orElse") (EApp (EVar "variantUpdateTail") (EVar "x"))) (EApp (EVar "braceItems") (EVar "x"))))))
(DTypeSig false "variantUpdateTail" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "variantUpdateTail" ((PVar "x")) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "recordFieldExpr")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "fields")) (EApp (EApp (EVar "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "x")) (EVar "e")) (EApp (EApp (EVar "map") (EApp (EVar "desugarDottedField") (EVar "e"))) (EVar "fields")))))))))))))))
(DData Private "KvItem" () ((variant "KvField" (ConPos (TyCon "String") (TyCon "Expr"))) (variant "KvKV" (ConPos (TyCon "Expr") (TyCon "Expr"))) (variant "KvElem" (ConPos (TyCon "Expr")))) ())
(DTypeSig false "braceItems" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "braceItems" ((PVar "x")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "braceItemsFor") (EVar "x")) (EVar "t")))))
(DTypeSig false "braceItemsFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "braceItemsFor" ((PVar "x") (PCon "TRBrace")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EVar "classifyBrace") (EVar "x")) (EListLit))))))
(DFunDef false "braceItemsFor" ((PVar "x") PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parseKvOrE")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "items")) (EApp (EApp (EVar "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EVar "classifyBrace") (EVar "x")) (EVar "items"))))))))))
(DTypeSig false "parseKvOrE" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvOrE" () (EApp (EApp (EVar "orElse") (EVar "parseKvField")) (EApp (EApp (EVar "orElse") (EVar "parseKvBlockElem")) (EVar "parseKvKVorElem"))))
(DTypeSig false "parseKvBlockElem" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvBlockElem" () (EApp (EApp (EVar "andThen") (EVar "parseBracketBlock")) (ELam ((PVar "e")) (EApp (EVar "pure") (EApp (EVar "KvElem") (EVar "e"))))))
(DTypeSig false "parseKvField" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvField" () (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseBracketElem")) (ELam ((PVar "e")) (EApp (EVar "pure") (EApp (EApp (EVar "KvField") (EVar "name")) (EVar "e"))))))))))
(DTypeSig false "parseKvKVorElem" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvKVorElem" () (EApp (EApp (EVar "andThen") (EVar "parsePipe")) (ELam ((PVar "e")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "kvKVorElemFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "kvKVorElemFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "KvItem")))))
(DFunDef false "kvKVorElemFor" ((PVar "e") (PCon "TFatArrow")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "v")) (EApp (EVar "pure") (EApp (EApp (EVar "KvKV") (EVar "e")) (EVar "v"))))))))
(DFunDef false "kvKVorElemFor" ((PVar "e") PWild) (EApp (EVar "pure") (EApp (EVar "KvElem") (EVar "e"))))
(DTypeSig false "classifyBrace" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyCon "Expr"))))
(DFunDef false "classifyBrace" ((PVar "name") (PVar "items")) (EIf (EApp (EVar "anyField") (EVar "items")) (EApp (EApp (EVar "ERecordCreate") (EVar "name")) (EApp (EApp (EVar "map") (EVar "kvToField")) (EVar "items"))) (EIf (EApp (EVar "anyKV") (EVar "items")) (EApp (EApp (EVar "EMapLit") (EVar "name")) (EApp (EVar "kvPairs") (EVar "items"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ESetLit") (EVar "name")) (EApp (EVar "kvElems") (EVar "items"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "anyField" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyCon "Bool")))
(DFunDef false "anyField" ((PList)) (EVar "False"))
(DFunDef false "anyField" ((PCons (PCon "KvField" PWild PWild) PWild)) (EVar "True"))
(DFunDef false "anyField" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyField") (EVar "rest")))
(DTypeSig false "anyKV" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyCon "Bool")))
(DFunDef false "anyKV" ((PList)) (EVar "False"))
(DFunDef false "anyKV" ((PCons (PCon "KvKV" PWild PWild) PWild)) (EVar "True"))
(DFunDef false "anyKV" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyKV") (EVar "rest")))
(DTypeSig false "kvToField" (TyFun (TyCon "KvItem") (TyCon "FieldAssign")))
(DFunDef false "kvToField" ((PCon "KvField" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EVar "e")))
(DFunDef false "kvToField" ((PCon "KvElem" (PVar "e"))) (EApp (EVar "kvElemToField") (EApp (EVar "stripLoc") (EVar "e"))))
(DFunDef false "kvToField" (PWild) (EApp (EApp (EVar "FieldAssign") (ELit (LString "_"))) (EApp (EVar "ELit") (EVar "LUnit"))))
(DTypeSig false "kvElemToField" (TyFun (TyCon "Expr") (TyCon "FieldAssign")))
(DFunDef false "kvElemToField" ((PCon "EVar" (PVar "n"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "EVar") (EVar "n"))))
(DFunDef false "kvElemToField" (PWild) (EApp (EApp (EVar "FieldAssign") (ELit (LString "_"))) (EApp (EVar "ELit") (EVar "LUnit"))))
(DTypeSig false "kvPairs" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "kvPairs" ((PList)) (EListLit))
(DFunDef false "kvPairs" ((PCons (PCon "KvKV" (PVar "k") (PVar "v")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EVar "kvPairs") (EVar "rest"))))
(DFunDef false "kvPairs" ((PCons PWild (PVar "rest"))) (EApp (EVar "kvPairs") (EVar "rest")))
(DTypeSig false "kvElems" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "kvElems" ((PList)) (EListLit))
(DFunDef false "kvElems" ((PCons (PCon "KvElem" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EVar "e") (EApp (EVar "kvElems") (EVar "rest"))))
(DFunDef false "kvElems" ((PCons PWild (PVar "rest"))) (EApp (EVar "kvElems") (EVar "rest")))
(DTypeSig false "parseRecordUpdate" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseRecordUpdate" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "recordFieldExpr")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "fields")) (EApp (EApp (EVar "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "e")) (EApp (EApp (EVar "map") (EApp (EVar "desugarDottedField") (EVar "e"))) (EVar "fields"))) (EApp (EVar "Ref") (ELit (LString ""))))))))))))))))))
(DTypeSig false "recordFieldExpr" (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr"))))
(DFunDef false "recordFieldExpr" () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "identNameP")) (EApp (EVar "expectTok") (EVar "TDot")))) (ELam ((PVar "path")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "recordFieldExprRest") (EVar "path")) (EVar "t")))))))
(DTypeSig false "recordFieldExprRest" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr"))))))
(DFunDef false "recordFieldExprRest" ((PVar "path") (PCon "TEqual")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseBracketElem")) (ELam ((PVar "e")) (EApp (EVar "pure") (ETuple (EVar "path") (EVar "e"))))))))
(DFunDef false "recordFieldExprRest" ((PList (PVar "x")) PWild) (EApp (EVar "pure") (ETuple (EListLit (EVar "x")) (EApp (EVar "EVar") (EVar "x")))))
(DFunDef false "recordFieldExprRest" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected = in record-update field"))))
(DTypeSig false "desugarDottedField" (TyFun (TyCon "Expr") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr")) (TyCon "FieldAssign"))))
(DFunDef false "desugarDottedField" ((PVar "base") (PTuple (PVar "path") (PVar "value"))) (EMatch (EVar "path") (arm (PList (PVar "field")) () (EApp (EApp (EVar "FieldAssign") (EVar "field")) (EVar "value"))) (arm (PCons (PVar "field") (PVar "rest")) () (EApp (EApp (EVar "FieldAssign") (EVar "field")) (EApp (EApp (EApp (EVar "dottedGo") (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "base")) (EVar "field")) (EApp (EVar "Ref") (ELit (LString ""))))) (EVar "rest")) (EVar "value")))) (arm (PList) () (EApp (EApp (EVar "FieldAssign") (ELit (LString "_"))) (EVar "value")))))
(DTypeSig false "dottedGo" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "dottedGo" ((PVar "cur") (PList (PVar "f")) (PVar "value")) (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "cur")) (EListLit (EApp (EApp (EVar "FieldAssign") (EVar "f")) (EVar "value")))) (EApp (EVar "Ref") (ELit (LString "")))))
(DFunDef false "dottedGo" ((PVar "cur") (PCons (PVar "f") (PVar "fs")) (PVar "value")) (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "cur")) (EListLit (EApp (EApp (EVar "FieldAssign") (EVar "f")) (EApp (EApp (EApp (EVar "dottedGo") (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "cur")) (EVar "f")) (EApp (EVar "Ref") (ELit (LString ""))))) (EVar "fs")) (EVar "value"))))) (EApp (EVar "Ref") (ELit (LString "")))))
(DFunDef false "dottedGo" ((PVar "cur") (PList) (PVar "value")) (EVar "value"))
(DTypeSig false "parseInterp" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseInterp" () (EApp (EApp (EVar "andThen") (EVar "interpOpenStr")) (ELam ((PVar "s0")) (EApp (EApp (EVar "andThen") (EVar "interpRest")) (ELam ((PVar "rest")) (EApp (EVar "pure") (EApp (EVar "EStringInterp") (EBinOp "::" (EApp (EVar "InterpStr") (EVar "s0")) (EVar "rest")))))))))
(DTypeSig false "interpOpenStr" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "interpOpenStr" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "interpOpenFor") (EVar "t")))))
(DTypeSig false "interpOpenFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "interpOpenFor" ((PCon "TInterpOpen" (PVar "s"))) (EApp (EVar "emit") (EVar "s")))
(DFunDef false "interpOpenFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected interpolation open"))))
(DTypeSig false "interpRest" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "InterpPart"))))
(DFunDef false "interpRest" () (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "interpRestFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "interpRestFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "InterpPart"))))))
(DFunDef false "interpRestFor" ((PVar "e") (PCon "TInterpMid" (PVar "s"))) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "interpRest")) (ELam ((PVar "rest")) (EApp (EVar "pure") (EBinOp "::" (EApp (EVar "InterpExpr") (EVar "e")) (EBinOp "::" (EApp (EVar "InterpStr") (EVar "s")) (EVar "rest")))))))))
(DFunDef false "interpRestFor" ((PVar "e") (PCon "TInterpEnd" (PVar "s"))) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EListLit (EApp (EVar "InterpExpr") (EVar "e")) (EApp (EVar "InterpStr") (EVar "s")))))))
(DFunDef false "interpRestFor" ((PVar "e") PWild) (EApp (EVar "failP") (ELit (LString "expected interpolation mid/end"))))
(DTypeSig false "parseBracketBlock" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBracketBlock" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseStmts")) (ELam ((PVar "stmts")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "blockOrExpr") (EVar "stmts"))))))))))
(DTypeSig false "parseBracketElem" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBracketElem" () (EApp (EApp (EVar "orElse") (EVar "parseBracketBlock")) (EVar "parseExpr")))
(DTypeSig false "parseParen" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseParen" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "parenFor") (EVar "t")))))))
(DTypeSig false "parenFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parenFor" ((PCon "TRParen")) (EApp (EVar "emit") (EApp (EVar "ELit") (EVar "LUnit"))))
(DFunDef false "parenFor" ((PCon "TMinus")) (EApp (EApp (EVar "orElse") (EVar "bareMinusSection")) (EVar "parseParenExpr")))
(DFunDef false "parenFor" ((PCon "TMinusTight")) (EApp (EApp (EVar "orElse") (EVar "bareMinusSection")) (EVar "parseParenExpr")))
(DFunDef false "parenFor" ((PVar "t")) (EApp (EVar "parenSectionOr") (EVar "t")))
(DTypeSig false "parenSectionOr" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parenSectionOr" ((PVar "t")) (EMatch (EApp (EVar "sectionOpStr") (EVar "t")) (arm (PCon "Some" (PVar "op")) () (EApp (EVar "parseSectionOp") (EVar "op"))) (arm (PCon "None") () (EVar "parseParenExpr"))))
(DTypeSig false "bareMinusSection" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "bareMinusSection" () (EApp (EApp (EVar "andThen") (EVar "expectMinus")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "ESection") (EApp (EVar "SecBare") (ELit (LString "-"))))))))))
(DTypeSig false "expectMinus" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "expectMinus" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "expectMinusGo") (EVar "t")))))
(DTypeSig false "expectMinusGo" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "expectMinusGo" ((PCon "TMinus")) (EApp (EVar "emit") (ELit LUnit)))
(DFunDef false "expectMinusGo" ((PCon "TMinusTight")) (EApp (EVar "emit") (ELit LUnit)))
(DFunDef false "expectMinusGo" (PWild) (EApp (EVar "failP") (ELit (LString "expected -"))))
(DTypeSig false "parseSectionOp" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parseSectionOp" ((PVar "op")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "sectionTail") (EVar "op")) (EVar "t")))))))
(DTypeSig false "sectionTail" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "sectionTail" ((PVar "op") (PCon "TRParen")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "ESection") (EApp (EVar "SecBare") (EVar "op")))))))
(DFunDef false "sectionTail" ((PVar "op") PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EVar "e")))))))))
(DTypeSig false "parseParenExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseParenExpr" () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parseBracketElem")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "es")) (EApp (EApp (EVar "andThen") (EApp (EVar "optTrailingCommaTuple") (EVar "es"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "parenResult") (EVar "es"))))))))))
(DTypeSig false "parenResult" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr")))
(DFunDef false "parenResult" ((PList (PVar "e"))) (EApp (EVar "leftSectionOrExpr") (EVar "e")))
(DFunDef false "parenResult" ((PVar "es")) (EApp (EVar "ETuple") (EVar "es")))
(DTypeSig false "leftSectionOrExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "leftSectionOrExpr" ((PVar "e")) (EApp (EApp (EVar "leftSectionGo") (EVar "e")) (EApp (EVar "stripLoc") (EVar "e"))))
(DTypeSig false "leftSectionGo" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "leftSectionGo" ((PVar "orig") (PCon "EBinOp" (PVar "op") (PVar "lhs") (PVar "rhs") PWild)) (EApp (EApp (EApp (EApp (EVar "leftSectionRhs") (EVar "orig")) (EVar "op")) (EVar "lhs")) (EApp (EVar "stripLoc") (EVar "rhs"))))
(DFunDef false "leftSectionGo" ((PVar "orig") PWild) (EVar "orig"))
(DTypeSig false "leftSectionRhs" (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "leftSectionRhs" (PWild (PVar "op") (PVar "lhs") (PCon "EVar" (PLit (LString "_")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EVar "lhs")) (EVar "op"))))
(DFunDef false "leftSectionRhs" ((PVar "orig") PWild PWild PWild) (EVar "orig"))
(DTypeSig false "sectionOpStr" (TyFun (TyCon "Token") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "sectionOpStr" ((PCon "TPlus")) (EApp (EVar "Some") (ELit (LString "+"))))
(DFunDef false "sectionOpStr" ((PCon "TStar")) (EApp (EVar "Some") (ELit (LString "*"))))
(DFunDef false "sectionOpStr" ((PCon "TSlash")) (EApp (EVar "Some") (ELit (LString "/"))))
(DFunDef false "sectionOpStr" ((PCon "TEqEq")) (EApp (EVar "Some") (ELit (LString "=="))))
(DFunDef false "sectionOpStr" ((PCon "TNeq")) (EApp (EVar "Some") (ELit (LString "!="))))
(DFunDef false "sectionOpStr" ((PCon "TLt")) (EApp (EVar "Some") (ELit (LString "<"))))
(DFunDef false "sectionOpStr" ((PCon "TGt")) (EApp (EVar "Some") (ELit (LString ">"))))
(DFunDef false "sectionOpStr" ((PCon "TLeq")) (EApp (EVar "Some") (ELit (LString "<="))))
(DFunDef false "sectionOpStr" ((PCon "TGeq")) (EApp (EVar "Some") (ELit (LString ">="))))
(DFunDef false "sectionOpStr" ((PCon "TAnd")) (EApp (EVar "Some") (ELit (LString "&&"))))
(DFunDef false "sectionOpStr" ((PCon "TOr")) (EApp (EVar "Some") (ELit (LString "||"))))
(DFunDef false "sectionOpStr" ((PCon "TCons")) (EApp (EVar "Some") (ELit (LString "::"))))
(DFunDef false "sectionOpStr" ((PCon "TPlusPlus")) (EApp (EVar "Some") (ELit (LString "++"))))
(DFunDef false "sectionOpStr" ((PCon "TPipeRight")) (EApp (EVar "Some") (ELit (LString "|>"))))
(DFunDef false "sectionOpStr" ((PCon "TRCompose")) (EApp (EVar "Some") (ELit (LString ">>"))))
(DFunDef false "sectionOpStr" ((PCon "TLCompose")) (EApp (EVar "Some") (ELit (LString "<<"))))
(DFunDef false "sectionOpStr" (PWild) (EVar "None"))
(DTypeSig false "parseListE" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseListE" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLBracket"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "listFor") (EVar "t")))))))
(DTypeSig false "listFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "listFor" ((PCon "TRBracket")) (EApp (EVar "emit") (EApp (EVar "EListLit") (EListLit))))
(DFunDef false "listFor" (PWild) (EApp (EApp (EVar "andThen") (EVar "parseBracketElem")) (ELam ((PVar "first")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "listRest") (EVar "first")) (EVar "t")))))))
(DTypeSig false "listRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "listRest" ((PVar "first") (PCon "TDotDot")) (EApp (EApp (EVar "rangeAfter") (EVar "first")) (EVar "False")))
(DFunDef false "listRest" ((PVar "first") (PCon "TDotDotEq")) (EApp (EApp (EVar "rangeAfter") (EVar "first")) (EVar "True")))
(DFunDef false "listRest" ((PVar "first") (PCon "TComma")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "listAfterComma") (EVar "first")) (EVar "t")))))))
(DFunDef false "listRest" ((PVar "first") (PCon "TRBracket")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "EListLit") (EListLit (EVar "first")))))))
(DFunDef false "listRest" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected , .. ..= or ]"))))
(DTypeSig false "listAfterComma" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "listAfterComma" ((PVar "first") (PCon "TRBracket")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "EListLit") (EListLit (EVar "first")))))))
(DFunDef false "listAfterComma" ((PVar "first") PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parseBracketElem")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "rest")) (EApp (EApp (EVar "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "EListLit") (EBinOp "::" (EVar "first") (EVar "rest")))))))))))
(DTypeSig false "rangeAfter" (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "rangeAfter" ((PVar "lo") (PVar "incl")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "hi")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "ERangeList") (EVar "lo")) (EVar "hi")) (EVar "incl"))))))))))
(DTypeSig false "parseArray" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseArray" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLArray"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "arrayFor") (EVar "t")))))))
(DTypeSig false "arrayFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "arrayFor" ((PCon "TRArray")) (EApp (EVar "emit") (EApp (EVar "EArrayLit") (EListLit))))
(DFunDef false "arrayFor" (PWild) (EApp (EApp (EVar "andThen") (EVar "parseBracketElem")) (ELam ((PVar "first")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "arrayRest") (EVar "first")) (EVar "t")))))))
(DTypeSig false "arrayRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TDotDot")) (EApp (EApp (EVar "arrayRangeAfter") (EVar "first")) (EVar "False")))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TDotDotEq")) (EApp (EApp (EVar "arrayRangeAfter") (EVar "first")) (EVar "True")))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TComma")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "arrayAfterComma") (EVar "first")) (EVar "t")))))))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TRArray")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "EArrayLit") (EListLit (EVar "first")))))))
(DFunDef false "arrayRest" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected , .. ..= or |]"))))
(DTypeSig false "arrayAfterComma" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "arrayAfterComma" ((PVar "first") (PCon "TRArray")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "EArrayLit") (EListLit (EVar "first")))))))
(DFunDef false "arrayAfterComma" ((PVar "first") PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parseBracketElem")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "rest")) (EApp (EApp (EVar "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRArray"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "EArrayLit") (EBinOp "::" (EVar "first") (EVar "rest")))))))))))
(DTypeSig false "arrayRangeAfter" (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "arrayRangeAfter" ((PVar "lo") (PVar "incl")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "hi")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRArray"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "ERangeArray") (EVar "lo")) (EVar "hi")) (EVar "incl"))))))))))
(DTypeSig false "parseIf" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseIf" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TIf"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "ifKind") (EVar "t")))))))
(DTypeSig false "ifKind" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "ifKind" ((PCon "TLet")) (EVar "ifLet"))
(DFunDef false "ifKind" (PWild) (EVar "ifPlain"))
(DTypeSig false "ifLet" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "ifLet" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parsePat")) (ELam ((PVar "pat")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "scrut")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TThen"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "thenE")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TElse"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "elseE")) (EApp (EVar "pure") (EApp (EApp (EVar "EMatch") (EVar "scrut")) (EListLit (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EListLit)) (EVar "thenE")) (EApp (EApp (EApp (EVar "Arm") (EVar "PWild")) (EListLit)) (EVar "elseE"))))))))))))))))))))))
(DTypeSig false "ifPlain" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "ifPlain" () (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "cond")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TThen"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseBranch")) (ELam ((PVar "thenE")) (EApp (EApp (EVar "andThen") (EVar "elseBranch")) (ELam ((PVar "elseE")) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "EIf") (EVar "cond")) (EVar "thenE")) (EVar "elseE"))))))))))))
(DTypeSig false "elseBranch" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "elseBranch" () (EApp (EApp (EVar "orElse") (EVar "elsePresent")) (EApp (EVar "pure") (EApp (EVar "ELit") (EVar "LUnit")))))
(DTypeSig false "elsePresent" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "elsePresent" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TElse"))) (ELam (PWild) (EVar "parseBranch"))))
(DTypeSig false "parseBranch" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBranch" () (EApp (EApp (EVar "orElse") (EVar "branchBlock")) (EVar "parseExpr")))
(DTypeSig false "branchBlock" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "branchBlock" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseStmts")) (ELam ((PVar "stmts")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "blockOrExpr") (EVar "stmts"))))))))))
(DTypeSig false "parseLet" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseLet" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "letExprKind") (EVar "t")))))))
(DTypeSig false "letExprKind" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "letExprKind" ((PCon "TMut")) (EApp (EVar "failP") (EVar "letMutRemovedMsg")))
(DFunDef false "letExprKind" ((PCon "TRec")) (EVar "letRecExpr"))
(DFunDef false "letExprKind" ((PCon "TIdent" (PVar "name"))) (EApp (EVar "letIdentExpr") (EVar "name")))
(DFunDef false "letExprKind" (PWild) (EVar "letPatExpr"))
(DTypeSig false "letMutRemovedMsg" (TyCon "String"))
(DFunDef false "letMutRemovedMsg" () (ELit (LString "`let mut` has been removed — bindings are immutable. For mutable state use a `Ref` cell: `let x = Ref 0`, write `x := newValue`, and read it with `x.value`")))
(DTypeSig false "recordRemovedMsg" (TyCon "String"))
(DFunDef false "recordRemovedMsg" () (ELit (LString "`record` is not a keyword — declare a record as `data X = { field : T, … }`")))
(DTypeSig false "functionRemovedMsg" (TyCon "String"))
(DFunDef false "functionRemovedMsg" () (ELit (LString "`function` is not a keyword — use `x => match x { … }` or a multi-clause definition")))
(DTypeSig false "letIdentExpr" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "letIdentExpr" ((PVar "name")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "params")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "letIdentExprRest") (EVar "name")) (EVar "params")) (EVar "t")))))))))
(DTypeSig false "letIdentExprRest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "letIdentExprRest" ((PVar "name") (PList) (PCon "TColon")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "False")) (EVar "False")) (EApp (EVar "PVar") (EVar "name"))) (EApp (EApp (EVar "EAnnot") (EVar "e1")) (EVar "ty"))) (EVar "e2"))))))))))))))))
(DFunDef false "letIdentExprRest" ((PVar "name") (PList) (PCon "TEqual")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "False")) (EVar "False")) (EApp (EVar "PVar") (EVar "name"))) (EVar "e1")) (EVar "e2"))))))))))))
(DFunDef false "letIdentExprRest" ((PVar "name") (PVar "params") (PCon "TEqual")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "False")) (EVar "True")) (EApp (EVar "PVar") (EVar "name"))) (EApp (EApp (EVar "curryLam") (EVar "params")) (EVar "e1"))) (EVar "e2"))))))))))))
(DFunDef false "letIdentExprRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected : or = in let"))))
(DTypeSig false "letPatExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "letPatExpr" () (EApp (EApp (EVar "andThen") (EVar "parsePat")) (ELam ((PVar "pat")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "False")) (EVar "False")) (EVar "pat")) (EVar "e1")) (EVar "e2"))))))))))))))
(DTypeSig false "letRecExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "letRecExpr" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRec"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "letRecInlineClause")) (ELam ((PVar "clause")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EVar "pure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EListLit (EVar "clause")))) (EVar "e2"))))))))))))
(DTypeSig false "letRecInlineClause" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))
(DFunDef false "letRecInlineClause" () (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "body")) (EApp (EVar "pure") (ETuple (EVar "name") (EVar "pats") (EVar "body"))))))))))))
(DTypeSig false "parseMatch" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseMatch" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TMatch"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "scrut")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseArms")) (ELam ((PVar "arms")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EVar "EMatch") (EVar "scrut")) (EVar "arms"))))))))))))))
(DTypeSig false "parseArms" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Arm"))))
(DFunDef false "parseArms" () (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "armsLoop"))))
(DTypeSig false "armsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Arm"))))
(DFunDef false "armsLoop" () (EApp (EApp (EVar "orElse") (EVar "armsCons")) (EApp (EVar "pure") (EListLit))))
(DTypeSig false "armsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Arm"))))
(DFunDef false "armsCons" () (EApp (EApp (EVar "andThen") (EVar "parseArm")) (ELam ((PVar "a")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "armsLoop")) (ELam ((PVar "rest")) (EApp (EVar "pure") (EBinOp "::" (EVar "a") (EVar "rest"))))))))))
(DTypeSig false "parseArm" (TyApp (TyCon "Parser") (TyCon "Arm")))
(DFunDef false "parseArm" () (EApp (EApp (EVar "andThen") (EVar "parsePat")) (ELam ((PVar "pat")) (EApp (EApp (EVar "andThen") (EVar "armGuardOpt")) (ELam ((PVar "guards")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TFatArrow"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "orElse") (EVar "branchBlock")) (EVar "parseBodyExpr"))) (ELam ((PVar "body")) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EVar "guards")) (EVar "body"))))))))))))
(DTypeSig false "armGuardOpt" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Guard"))))
(DFunDef false "armGuardOpt" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "armGuardFor") (EVar "t")))))
(DTypeSig false "armGuardFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Guard")))))
(DFunDef false "armGuardFor" ((PCon "TIf")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "sepBy1") (EVar "parseGuard")) (EApp (EVar "expectTok") (EVar "TComma"))))))
(DFunDef false "armGuardFor" (PWild) (EApp (EVar "pure") (EListLit)))
(DTypeSig false "parsePat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePat" () (EVar "parsePatCons"))
(DTypeSig false "parseAsPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parseAsPat" () (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "x")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TAsAt"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parsePatApp")) (ELam ((PVar "sub")) (EApp (EVar "pure") (EApp (EApp (EVar "PAs") (EVar "x")) (EVar "sub"))))))))))
(DTypeSig false "parsePatCons" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatCons" () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "orElse") (EVar "parseAsPat")) (EVar "parsePatApp"))) (ELam ((PVar "p")) (EApp (EApp (EVar "orElse") (EApp (EVar "patConsTail") (EVar "p"))) (EApp (EVar "pure") (EVar "p"))))))
(DTypeSig false "patConsTail" (TyFun (TyCon "Pat") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patConsTail" ((PVar "p")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TCons"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parsePatCons")) (ELam ((PVar "q")) (EApp (EVar "pure") (EApp (EApp (EVar "PCons") (EVar "p")) (EVar "q"))))))))
(DTypeSig false "parsePatApp" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatApp" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "patAppFor") (EVar "t")))))
(DTypeSig false "patAppFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patAppFor" ((PCon "TUpper" (PVar "c"))) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "upperPatRest") (EVar "c")) (EVar "t")))))))
(DFunDef false "patAppFor" (PWild) (EVar "parsePatAtom"))
(DTypeSig false "upperPatRest" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat")))))
(DFunDef false "upperPatRest" ((PVar "c") (PCon "TLBrace")) (EApp (EVar "recordPat") (EVar "c")))
(DFunDef false "upperPatRest" ((PVar "c") PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "parsePatAtom"))) (ELam ((PVar "args")) (EApp (EVar "pure") (EApp (EApp (EVar "PCon") (EVar "c")) (EVar "args"))))))
(DTypeSig false "recordPat" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "recordPat" ((PVar "c")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "recordPatFields")) (ELam ((PVar "fr")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EVar "mkRec") (EVar "c")) (EVar "fr"))))))))))
(DTypeSig false "mkRec" (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")) (TyCon "Pat"))))
(DFunDef false "mkRec" ((PVar "c") (PTuple (PVar "fields") (PVar "rest"))) (EApp (EApp (EApp (EVar "PRec") (EVar "c")) (EVar "fields")) (EVar "rest")))
(DTypeSig false "recordPatFields" (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool"))))
(DFunDef false "recordPatFields" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "recordPatFieldsFor") (EVar "t")))))
(DTypeSig false "recordPatFieldsFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")))))
(DFunDef false "recordPatFieldsFor" ((PCon "TEllipsis")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (ETuple (EListLit) (EVar "True"))))))
(DFunDef false "recordPatFieldsFor" ((PCon "TRBrace")) (EApp (EVar "pure") (ETuple (EListLit) (EVar "False"))))
(DFunDef false "recordPatFieldsFor" (PWild) (EApp (EApp (EVar "andThen") (EVar "recordPatField")) (ELam ((PVar "f")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "recordPatFieldsRest") (EVar "f")) (EVar "t")))))))
(DTypeSig false "recordPatFieldsRest" (TyFun (TyCon "RecPatField") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool"))))))
(DFunDef false "recordPatFieldsRest" ((PVar "f") (PCon "TComma")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "recordPatFields")) (ELam ((PVar "fr")) (EApp (EVar "pure") (EApp (EApp (EVar "consField") (EVar "f")) (EVar "fr"))))))))
(DFunDef false "recordPatFieldsRest" ((PVar "f") PWild) (EApp (EVar "pure") (ETuple (EListLit (EVar "f")) (EVar "False"))))
(DTypeSig false "consField" (TyFun (TyCon "RecPatField") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")) (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")))))
(DFunDef false "consField" ((PVar "f") (PTuple (PVar "fs") (PVar "rest"))) (ETuple (EBinOp "::" (EVar "f") (EVar "fs")) (EVar "rest")))
(DTypeSig false "recordPatField" (TyApp (TyCon "Parser") (TyCon "RecPatField")))
(DFunDef false "recordPatField" () (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "recordPatFieldRest") (EVar "name")) (EVar "t")))))))
(DTypeSig false "recordPatFieldRest" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "RecPatField")))))
(DFunDef false "recordPatFieldRest" ((PVar "name") (PCon "TEqual")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parsePat")) (ELam ((PVar "p")) (EApp (EVar "pure") (EApp (EApp (EVar "RecPatField") (EVar "name")) (EApp (EVar "Some") (EVar "p")))))))))
(DFunDef false "recordPatFieldRest" ((PVar "name") PWild) (EApp (EVar "pure") (EApp (EApp (EVar "RecPatField") (EVar "name")) (EVar "None"))))
(DTypeSig false "reservedIdentKeyword" (TyFun (TyCon "Token") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TWith")) (EApp (EVar "Some") (ELit (LString "with"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TMut")) (EApp (EVar "Some") (ELit (LString "mut"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TIn")) (EApp (EVar "Some") (ELit (LString "in"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TMatch")) (EApp (EVar "Some") (ELit (LString "match"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TData")) (EApp (EVar "Some") (ELit (LString "data"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TRecord")) (EApp (EVar "Some") (ELit (LString "record"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TInterface")) (EApp (EVar "Some") (ELit (LString "interface"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TDefault")) (EApp (EVar "Some") (ELit (LString "default"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TImpl")) (EApp (EVar "Some") (ELit (LString "impl"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TImport")) (EApp (EVar "Some") (ELit (LString "import"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TExport")) (EApp (EVar "Some") (ELit (LString "export"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TPublic")) (EApp (EVar "Some") (ELit (LString "public"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TWhere")) (EApp (EVar "Some") (ELit (LString "where"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TOf")) (EApp (EVar "Some") (ELit (LString "of"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TDo")) (EApp (EVar "Some") (ELit (LString "do"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TAs")) (EApp (EVar "Some") (ELit (LString "as"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TExtern")) (EApp (EVar "Some") (ELit (LString "extern"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TRequires")) (EApp (EVar "Some") (ELit (LString "requires"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TDeriving")) (EApp (EVar "Some") (ELit (LString "deriving"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TType")) (EApp (EVar "Some") (ELit (LString "type"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TNewtype")) (EApp (EVar "Some") (ELit (LString "newtype"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TProp")) (EApp (EVar "Some") (ELit (LString "prop"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TTest")) (EApp (EVar "Some") (ELit (LString "test"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TBench")) (EApp (EVar "Some") (ELit (LString "bench"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TEffect")) (EApp (EVar "Some") (ELit (LString "effect"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TFunction")) (EApp (EVar "Some") (ELit (LString "function"))))
(DFunDef false "reservedIdentKeyword" (PWild) (EVar "None"))
(DTypeSig false "reservedKeywordMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "reservedKeywordMsg" ((PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is a reserved keyword — it can't be used as a variable or pattern name. Rename it (e.g. `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "_`)."))))
(DTypeSig false "reservedOrPatFail" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "reservedOrPatFail" ((PVar "t")) (EMatch (EApp (EVar "reservedIdentKeyword") (EVar "t")) (arm (PCon "Some" (PVar "name")) () (EApp (EVar "fatalP") (EApp (EVar "reservedKeywordMsg") (EVar "name")))) (arm (PCon "None") () (EApp (EVar "failP") (ELit (LString "expected pattern"))))))
(DTypeSig false "parsePatAtom" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatAtom" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TIdent" (PVar "x")) () (EApp (EVar "emit") (EApp (EVar "PVar") (EVar "x")))) (arm (PCon "TUnderscore") () (EApp (EVar "emit") (EVar "PWild"))) (arm (PCon "TInt" (PVar "n") PWild) ((GBool (EApp (EVar "isIntMinLit") (EVar "n")))) (EApp (EVar "fatalP") (EVar "intLitTooBigMsg"))) (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "intPatRest") (EApp (EVar "LInt") (EVar "n")))) (arm (PCon "TMinus") () (EVar "negIntPat")) (arm (PCon "TMinusTight") () (EVar "negIntPat")) (arm (PCon "TFloat" (PVar "f")) () (EApp (EVar "emit") (EApp (EVar "PLit") (EApp (EVar "LFloat") (EVar "f"))))) (arm (PCon "TString" (PVar "s")) () (EApp (EVar "emit") (EApp (EVar "PLit") (EApp (EVar "LString") (EVar "s"))))) (arm (PCon "TChar" (PVar "s")) () (EApp (EVar "charPatRest") (EApp (EVar "LChar") (EVar "s")))) (arm (PCon "TUpper" (PVar "c")) () (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t2")) (EApp (EApp (EVar "upperAtomRest") (EVar "c")) (EVar "t2"))))))) (arm (PCon "TLParen") () (EVar "parsePatParen")) (arm (PCon "TLBracket") () (EVar "parsePatList")) (arm PWild () (EApp (EVar "reservedOrPatFail") (EVar "t")))))))
(DTypeSig false "upperAtomRest" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat")))))
(DFunDef false "upperAtomRest" ((PVar "c") (PCon "TLBrace")) (EApp (EVar "recordPat") (EVar "c")))
(DFunDef false "upperAtomRest" ((PVar "c") PWild) (EApp (EVar "pure") (EApp (EApp (EVar "PCon") (EVar "c")) (EListLit))))
(DTypeSig false "parseParamPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parseParamPat" () (EApp (EApp (EVar "orElse") (EVar "parseParamAsPat")) (EVar "parsePatAtom")))
(DTypeSig false "parseParamAsPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parseParamAsPat" () (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "x")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TAsAt"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parsePatAtom")) (ELam ((PVar "sub")) (EApp (EVar "pure") (EApp (EApp (EVar "PAs") (EVar "x")) (EVar "sub"))))))))))
(DTypeSig false "intPatRest" (TyFun (TyCon "Lit") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "intPatRest" ((PVar "lo")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "rngPatRest") (EVar "lo")) (EVar "intBound")) (EVar "t")))))))
(DTypeSig false "negIntPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "negIntPat" () (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "negIntRng") (EApp (EVar "LInt") (EApp (EVar "negate") (EVar "n"))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected integer after -"))))))))))
(DTypeSig false "negIntRng" (TyFun (TyCon "Lit") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "negIntRng" ((PVar "lo")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TDotDot") () (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "intBound")) (ELam ((PVar "hi")) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "False")))))))) (arm (PCon "TDotDotEq") () (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "intBound")) (ELam ((PVar "hi")) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "True")))))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected .. or ..= after negative range bound"))))))))))
(DTypeSig false "charPatRest" (TyFun (TyCon "Lit") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "charPatRest" ((PVar "lo")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "rngPatRest") (EVar "lo")) (EVar "charBound")) (EVar "t")))))))
(DTypeSig false "rngPatRest" (TyFun (TyCon "Lit") (TyFun (TyApp (TyCon "Parser") (TyCon "Lit")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))))
(DFunDef false "rngPatRest" ((PVar "lo") (PVar "bound") (PCon "TDotDot")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "bound")) (ELam ((PVar "hi")) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "False"))))))))
(DFunDef false "rngPatRest" ((PVar "lo") (PVar "bound") (PCon "TDotDotEq")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "bound")) (ELam ((PVar "hi")) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "True"))))))))
(DFunDef false "rngPatRest" ((PVar "lo") PWild PWild) (EApp (EVar "pure") (EApp (EVar "PLit") (EVar "lo"))))
(DTypeSig false "intBound" (TyApp (TyCon "Parser") (TyCon "Lit")))
(DFunDef false "intBound" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "intBoundFor") (EVar "t")))))
(DTypeSig false "intBoundFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Lit"))))
(DFunDef false "intBoundFor" ((PCon "TInt" (PVar "n") PWild)) (EIf (EApp (EVar "isIntMinLit") (EVar "n")) (EApp (EVar "fatalP") (EVar "intLitTooBigMsg")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "intBoundFor" ((PCon "TInt" (PVar "n") PWild)) (EApp (EVar "emit") (EApp (EVar "LInt") (EVar "n"))))
(DFunDef false "intBoundFor" ((PCon "TMinus")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "emit") (EApp (EVar "LInt") (EApp (EVar "negate") (EVar "n"))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected integer after - in range bound"))))))))))
(DFunDef false "intBoundFor" ((PCon "TMinusTight")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "emit") (EApp (EVar "LInt") (EApp (EVar "negate") (EVar "n"))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected integer after - in range bound"))))))))))
(DFunDef false "intBoundFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected int range bound"))))
(DTypeSig false "charBound" (TyApp (TyCon "Parser") (TyCon "Lit")))
(DFunDef false "charBound" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "charBoundFor") (EVar "t")))))
(DTypeSig false "charBoundFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Lit"))))
(DFunDef false "charBoundFor" ((PCon "TChar" (PVar "s"))) (EApp (EVar "emit") (EApp (EVar "LChar") (EVar "s"))))
(DFunDef false "charBoundFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected char range bound"))))
(DTypeSig false "tuplePatOrSingle" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Pat")))
(DFunDef false "tuplePatOrSingle" ((PList (PVar "p"))) (EVar "p"))
(DFunDef false "tuplePatOrSingle" ((PVar "ps")) (EApp (EVar "PTuple") (EVar "ps")))
(DTypeSig false "parsePatParen" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatParen" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "patParenFor") (EVar "t")))))))
(DTypeSig false "patParenFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patParenFor" ((PCon "TRParen")) (EApp (EVar "emit") (EApp (EVar "PLit") (EVar "LUnit"))))
(DFunDef false "patParenFor" (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parsePat")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ps")) (EApp (EApp (EVar "andThen") (EApp (EVar "optTrailingCommaTuple") (EVar "ps"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "tuplePatOrSingle") (EVar "ps"))))))))))
(DTypeSig false "parsePatList" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatList" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLBracket"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "patListFor") (EVar "t")))))))
(DTypeSig false "patListFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patListFor" ((PCon "TRBracket")) (EApp (EVar "emit") (EApp (EVar "PList") (EListLit))))
(DFunDef false "patListFor" (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parsePat")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ps")) (EApp (EApp (EVar "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "PList") (EVar "ps"))))))))))
(DTypeSig false "parseTy" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTy" () (EApp (EApp (EVar "andThen") (EVar "parseTyFun")) (ELam ((PVar "lhs")) (EApp (EApp (EVar "orElse") (EApp (EVar "constraintTail") (EVar "lhs"))) (EApp (EVar "pure") (EVar "lhs"))))))
(DTypeSig false "constraintTail" (TyFun (TyCon "Ty") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "constraintTail" ((PVar "lhs")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TFatArrow"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseTy")) (ELam ((PVar "rhs")) (EApp (EVar "pure") (EApp (EApp (EVar "TyConstrained") (EApp (EVar "extractConstraints") (EVar "lhs"))) (EVar "rhs"))))))))
(DTypeSig false "extractConstraints" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Constraint"))))
(DFunDef false "extractConstraints" ((PCon "TyApp" (PVar "f") (PVar "a"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "f")) (EVar "a"))) (arm (PCon "Some" (PTuple (PVar "iface") (PVar "args"))) () (EListLit (EApp (EApp (EVar "Constraint") (EVar "iface")) (EVar "args")))) (arm (PCon "None") () (EListLit))))
(DFunDef false "extractConstraints" ((PCon "TyCon" (PVar "iface") PWild)) (EListLit (EApp (EApp (EVar "Constraint") (EVar "iface")) (EListLit))))
(DFunDef false "extractConstraints" ((PCon "TyTuple" (PVar "cs"))) (EApp (EVar "concatMapC") (EVar "cs")))
(DFunDef false "extractConstraints" (PWild) (EListLit))
(DTypeSig false "tyAppSpine" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty"))))))
(DFunDef false "tyAppSpine" ((PVar "t")) (EApp (EApp (EVar "tyAppSpineAcc") (EVar "t")) (EListLit)))
(DTypeSig false "tyAppSpineAcc" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty")))))))
(DFunDef false "tyAppSpineAcc" ((PCon "TyCon" (PVar "iface") PWild) (PVar "acc")) (EApp (EVar "Some") (ETuple (EVar "iface") (EVar "acc"))))
(DFunDef false "tyAppSpineAcc" ((PCon "TyApp" (PVar "f") (PVar "a")) (PVar "acc")) (EApp (EApp (EVar "tyAppSpineAcc") (EVar "f")) (EBinOp "::" (EVar "a") (EVar "acc"))))
(DFunDef false "tyAppSpineAcc" (PWild PWild) (EVar "None"))
(DTypeSig false "concatMapC" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Constraint"))))
(DFunDef false "concatMapC" ((PList)) (EListLit))
(DFunDef false "concatMapC" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "++" (EApp (EVar "extractConstraints") (EVar "t")) (EApp (EVar "concatMapC") (EVar "rest"))))
(DTypeSig false "parseTyFun" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyFun" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "tyFor") (EVar "t")))))
(DTypeSig false "tyFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tyFor" ((PCon "TLt")) (EVar "parseEffectTy"))
(DFunDef false "tyFor" (PWild) (EApp (EApp (EVar "andThen") (EVar "parseTyApp")) (ELam ((PVar "left")) (EApp (EApp (EVar "orElse") (EApp (EVar "tyArrowTail") (EVar "left"))) (EApp (EVar "pure") (EVar "left"))))))
(DTypeSig false "parseEffectTy" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseEffectTy" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLt"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "effectBody")) (ELam ((PVar "body")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TGt"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseTy")) (ELam ((PVar "inner")) (EApp (EVar "pure") (EApp (EApp (EVar "mkEffect") (EVar "body")) (EVar "inner"))))))))))))
(DTypeSig false "mkEffect" (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "mkEffect" ((PTuple (PVar "labels") (PVar "tail")) (PVar "inner")) (EApp (EApp (EApp (EVar "TyEffect") (EVar "labels")) (EVar "tail")) (EVar "inner")))
(DTypeSig false "effectBody" (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "effectBody" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "effectBodyFor") (EVar "t")))))
(DTypeSig false "effectBodyFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "effectBodyFor" ((PCon "TUpper" PWild)) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "effAtomP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "labels")) (EApp (EApp (EVar "andThen") (EVar "pipeTail")) (ELam ((PVar "tail")) (EApp (EVar "pure") (ETuple (EVar "labels") (EVar "tail"))))))))
(DFunDef false "effectBodyFor" ((PCon "TIdent" PWild)) (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "v")) (EApp (EVar "pure") (ETuple (EListLit) (EApp (EVar "Some") (EVar "v")))))))
(DFunDef false "effectBodyFor" (PWild) (EApp (EVar "pure") (ETuple (EListLit) (EVar "None"))))
(DTypeSig false "effAtomP" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "effAtomP" () (EApp (EApp (EVar "andThen") (EVar "upperNameP")) (ELam ((PVar "l")) (EApp (EApp (EVar "andThen") (EVar "effParamP")) (ELam ((PVar "p")) (EApp (EVar "pure") (ETuple (EVar "l") (EVar "p"))))))))
(DTypeSig false "effParamP" (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "effParamP" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "andThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EVar "effParamDispatch") (EVar "t")) (EVar "t2")))))))
(DTypeSig false "effParamDispatch" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "effParamDispatch" ((PCon "TUpper" PWild) (PCon "TEqual")) (EVar "productParamP"))
(DFunDef false "effParamDispatch" ((PVar "t") PWild) (EApp (EVar "effParamFor") (EVar "t")))
(DTypeSig false "productParamP" (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "productParamP" () (EApp (EApp (EVar "andThen") (EVar "productAxes")) (ELam ((PVar "axes")) (EApp (EVar "pure") (EApp (EVar "Some") (EApp (EVar "encodeProductParam") (EVar "axes")))))))
(DTypeSig false "productAxes" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "productAxes" () (EApp (EApp (EVar "andThen") (EVar "productAxis")) (ELam ((PVar "a")) (EApp (EApp (EVar "andThen") (EVar "productAxesMore")) (ELam ((PVar "rest")) (EApp (EVar "pure") (EBinOp "::" (EVar "a") (EVar "rest"))))))))
(DTypeSig false "productAxesMore" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "productAxesMore" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "andThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EVar "productAxesMoreFor") (EVar "t")) (EVar "t2")))))))
(DTypeSig false "productAxesMoreFor" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "productAxesMoreFor" ((PCon "TUpper" PWild) (PCon "TEqual")) (EVar "productAxes"))
(DFunDef false "productAxesMoreFor" (PWild PWild) (EApp (EVar "pure") (EListLit)))
(DTypeSig false "productAxis" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "productAxis" () (EApp (EApp (EVar "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "productAxisVal")) (ELam ((PVar "v")) (EApp (EVar "pure") (ETuple (EVar "name") (EVar "v"))))))))))
(DTypeSig false "productAxisVal" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "productAxisVal" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "productAxisValFor") (EVar "t")))))
(DTypeSig false "productAxisValFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "productAxisValFor" ((PCon "TString" (PVar "s"))) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\"")))))))
(DFunDef false "productAxisValFor" ((PCon "TLBrace")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "stringLitP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "elems")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "encodeSetParam") (EVar "elems"))))))))))
(DFunDef false "productAxisValFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected product axis value (\"prefix\" or {set})"))))
(DTypeSig false "effParamFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "effParamFor" ((PCon "TString" (PVar "s"))) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "Some") (EVar "s"))))))
(DFunDef false "effParamFor" ((PCon "TUnderscore")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "Some") (ELit (LString "_")))))))
(DFunDef false "effParamFor" ((PCon "TLBrace")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "stringLitP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "elems")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "Some") (EApp (EVar "encodeSetParam") (EVar "elems")))))))))))
(DFunDef false "effParamFor" (PWild) (EApp (EVar "pure") (EVar "None")))
(DTypeSig false "encodeSetParam" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "encodeSetParam" ((PVar "elems")) (EBinOp "++" (EBinOp "++" (ELit (LString "{")) (EApp (EVar "joinComma") (EVar "elems"))) (ELit (LString "}"))))
(DTypeSig false "encodeProductParam" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "String")))
(DFunDef false "encodeProductParam" ((PVar "axes")) (EBinOp "++" (EBinOp "++" (ELit (LString "@P{")) (EApp (EVar "joinSemi") (EApp (EApp (EVar "map") (EVar "encodeAxis")) (EVar "axes")))) (ELit (LString "}"))))
(DTypeSig false "encodeAxis" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "encodeAxis" ((PTuple (PVar "name") (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "="))) (EApp (EVar "display") (EVar "v"))) (ELit (LString ""))))
(DTypeSig false "joinSemi" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSemi" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString ";"))) (EVar "xs")))
(DTypeSig false "joinComma" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinComma" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "xs")))
(DTypeSig false "pipeTail" (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "pipeTail" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "pipeTailFor") (EVar "t")))))
(DTypeSig false "pipeTailFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "pipeTailFor" ((PCon "TPipe")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "v")) (EApp (EVar "pure") (EApp (EVar "Some") (EVar "v"))))))))
(DFunDef false "pipeTailFor" (PWild) (EApp (EVar "pure") (EVar "None")))
(DTypeSig false "upperNameP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "upperNameP" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "upperNameFor") (EVar "t")))))
(DTypeSig false "upperNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "upperNameFor" ((PCon "TUpper" (PVar "c"))) (EApp (EVar "emit") (EVar "c")))
(DFunDef false "upperNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected effect label"))))
(DTypeSig false "tyArrowTail" (TyFun (TyCon "Ty") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tyArrowTail" ((PVar "left")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TArrow"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "andThen") (EApp (EVar "tyArrowSkipLayout") (EVar "t"))) (ELam ((PVar "indented")) (EApp (EApp (EVar "andThen") (EVar "parseTy")) (ELam ((PVar "right")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "when") (EVar "indented")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "expectTok") (EVar "TDedent")))))) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EVar "TyFun") (EVar "left")) (EVar "right"))))))))))))))
(DTypeSig false "tyArrowSkipLayout" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Bool"))))
(DFunDef false "tyArrowSkipLayout" ((PCon "TNewline")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EVar "False")))))
(DFunDef false "tyArrowSkipLayout" ((PCon "TIndent")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EVar "True")))))
(DFunDef false "tyArrowSkipLayout" (PWild) (EApp (EVar "pure") (EVar "False")))
(DTypeSig false "parseTyApp" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyApp" () (EApp (EApp (EVar "andThen") (EVar "parseTyAtom")) (ELam ((PVar "head")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "args")) (EApp (EVar "pure") (EApp (EApp (EVar "tyApplyAll") (EVar "head")) (EVar "args"))))))))
(DTypeSig false "tyApplyAll" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty"))))
(DFunDef false "tyApplyAll" ((PVar "head") (PList)) (EVar "head"))
(DFunDef false "tyApplyAll" ((PVar "head") (PCons (PVar "a") (PVar "rest"))) (EApp (EApp (EVar "tyApplyAll") (EApp (EApp (EVar "TyApp") (EVar "head")) (EVar "a"))) (EVar "rest")))
(DTypeSig false "parseTyAtom" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyAtom" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TUpper" (PVar "c")) () (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "pure") (EApp (EApp (EVar "TyCon") (EVar "c")) (EApp (EVar "Some") (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "q")))))))))))) (arm (PCon "TIdent" (PVar "v")) () (EApp (EVar "emit") (EApp (EVar "TyVar") (EVar "v")))) (arm (PCon "TLParen") () (EVar "parseTyParen")) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected type atom"))))))))
(DTypeSig false "tyTupleOrSingle" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty")))
(DFunDef false "tyTupleOrSingle" ((PList (PVar "t"))) (EVar "t"))
(DFunDef false "tyTupleOrSingle" ((PVar "ts")) (EApp (EVar "TyTuple") (EVar "ts")))
(DTypeSig false "parseTyParen" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyParen" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "parseTyParenBody") (EVar "t")))))))
(DTypeSig false "parseTyParenBody" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "parseTyParenBody" ((PCon "TComma")) (EApp (EVar "parseTupleCtorTail") (ELit (LInt 0))))
(DFunDef false "parseTyParenBody" (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parseTy")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ts")) (EApp (EApp (EVar "andThen") (EApp (EVar "optTrailingCommaTuple") (EVar "ts"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "tyTupleOrSingle") (EVar "ts"))))))))))
(DTypeSig false "parseTupleCtorTail" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "parseTupleCtorTail" ((PVar "commas")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "tupleCtorTailFor") (EVar "commas")) (EVar "t")))))
(DTypeSig false "tupleCtorTailFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty")))))
(DFunDef false "tupleCtorTailFor" ((PVar "commas") (PCon "TComma")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "parseTupleCtorTail") (EBinOp "+" (EVar "commas") (ELit (LInt 1)))))))
(DFunDef false "tupleCtorTailFor" ((PVar "commas") (PCon "TRParen")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "tupleCtorTyOfArity") (EBinOp "+" (EVar "commas") (ELit (LInt 1)))))))
(DFunDef false "tupleCtorTailFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected , or ) in tuple type constructor"))))
(DTypeSig false "tupleCtorTyOfArity" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tupleCtorTyOfArity" ((PVar "n")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "<=" (EVar "n") (ELit (LInt 5)))) (EApp (EVar "pure") (EApp (EApp (EVar "TyCon") (EApp (EVar "tupleCtorTyName") (EVar "n"))) (EVar "None"))) (EApp (EVar "failP") (ELit (LString "tuple type constructor arity must be 2..5")))))
(DTypeSig false "tupleCtorTyName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 2))) (ELit (LString "__tuple2__")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 3))) (ELit (LString "__tuple3__")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 4))) (ELit (LString "__tuple4__")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 5))) (ELit (LString "__tuple5__")))
(DFunDef false "tupleCtorTyName" (PWild) (ELit (LString "__tuple0__")))
(DTypeSig false "parseDecl" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "parseDecl" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TImport") () (EApp (EVar "parseImport") (EVar "False"))) (arm (PCon "TExport") () (EVar "afterExport")) (arm (PCon "TPublic") () (EVar "afterPublic")) (arm (PCon "TData") () (EApp (EVar "parseData") (EVar "VisPrivate"))) (arm (PCon "TExtern") () (EApp (EVar "parseExtern") (EVar "False"))) (arm (PCon "TProp") () (EApp (EVar "parseProp") (EVar "False"))) (arm (PCon "TTest") () (EApp (EVar "parseTest") (EVar "False"))) (arm (PCon "TBench") () (EApp (EVar "parseBench") (EVar "False"))) (arm (PCon "TEffect") () (EApp (EVar "parseEffect") (EVar "False"))) (arm (PCon "TInterface") () (EApp (EApp (EVar "parseInterface") (EVar "False")) (EVar "False"))) (arm (PCon "TImpl") () (EApp (EVar "parseImpl") (EVar "False"))) (arm (PCon "TDefault") () (EApp (EVar "afterDefault") (EVar "False"))) (arm (PCon "TType") () (EApp (EVar "parseTypeAlias") (EVar "False"))) (arm (PCon "TNewtype") () (EApp (EVar "parseNewtype") (EVar "False"))) (arm (PCon "TLet") () (EApp (EVar "parseLetGroupDecl") (EVar "False"))) (arm (PCon "TAt") () (EVar "parseAttrib")) (arm PWild () (EApp (EVar "parseFunOrSig") (EVar "False")))))))
(DTypeSig false "afterDefault" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "afterDefault" ((PVar "pub")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDefault"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "afterDefaultFor") (EVar "pub")) (EVar "t")))))))))
(DTypeSig false "afterDefaultFor" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "afterDefaultFor" ((PVar "pub") (PCon "TInterface")) (EApp (EApp (EVar "parseInterface") (EVar "pub")) (EVar "True")))
(DFunDef false "afterDefaultFor" (PWild (PCon "TImpl")) (EApp (EVar "failP") (EVar "defaultImplRemovedMsg")))
(DFunDef false "afterDefaultFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected interface after default"))))
(DTypeSig false "afterExport" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "afterExport" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TExport"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TImport") () (EApp (EVar "parseImport") (EVar "True"))) (arm (PCon "TData") () (EApp (EVar "parseData") (EVar "VisAbstract"))) (arm (PCon "TExtern") () (EApp (EVar "parseExtern") (EVar "True"))) (arm (PCon "TProp") () (EApp (EVar "parseProp") (EVar "True"))) (arm (PCon "TTest") () (EApp (EVar "parseTest") (EVar "True"))) (arm (PCon "TBench") () (EApp (EVar "parseBench") (EVar "True"))) (arm (PCon "TEffect") () (EApp (EVar "parseEffect") (EVar "True"))) (arm (PCon "TInterface") () (EApp (EApp (EVar "parseInterface") (EVar "True")) (EVar "False"))) (arm (PCon "TImpl") () (EApp (EVar "parseImpl") (EVar "True"))) (arm (PCon "TDefault") () (EApp (EVar "afterDefault") (EVar "True"))) (arm (PCon "TType") () (EApp (EVar "parseTypeAlias") (EVar "True"))) (arm (PCon "TNewtype") () (EApp (EVar "parseNewtype") (EVar "True"))) (arm (PCon "TLet") () (EApp (EVar "parseLetGroupDecl") (EVar "True"))) (arm PWild () (EApp (EVar "parseFunOrSig") (EVar "True")))))))))))
(DTypeSig false "afterPublic" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "afterPublic" () (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "pubPos")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TPublic"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TExport"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "afterPublicFor") (EVar "pubPos")) (EVar "t")))))))))))))))
(DTypeSig false "afterPublicFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "afterPublicFor" (PWild (PCon "TData")) (EApp (EVar "parseData") (EVar "VisPublic")))
(DFunDef false "afterPublicFor" ((PVar "pubPos") PWild) (EApp (EApp (EVar "fatalAtP") (ELit (LString "`public` only applies to `data` declarations"))) (EVar "pubPos")))
(DTypeSig false "parseFunOrSig" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseFunOrSig" ((PVar "pub")) (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "params")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TColon") () (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "DTypeSig") (EVar "pub")) (EVar "name")) (EVar "ty")))))))))) (arm (PCon "TEqual") () (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "body")))))))))) (arm (PCon "TIndent") () (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseGuardArms")) (ELam ((PVar "arms")) (EApp (EApp (EVar "andThen") (EApp (EVar "guardArmsWhereOpt") (EVar "arms"))) (ELam ((PVar "body")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "body")))))))))))))) (arm (PCon "TPipe") () (EApp (EApp (EVar "andThen") (EVar "parseGuardArm")) (ELam ((PVar "arm")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EVar "EGuards") (EListLit (EVar "arm")))))))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected : or = in definition"))))))))))))
(DTypeSig false "parseExtern" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseExtern" ((PVar "pub")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TExtern"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "externName")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "DExtern") (EVar "pub")) (EVar "name")) (EVar "ty"))))))))))))))
(DTypeSig false "parseTypeAlias" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseTypeAlias" ((PVar "pub")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TType"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "lowerNameP"))) (ELam ((PVar "params")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EVar "DTypeAlias") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "ty"))))))))))))))))
(DTypeSig false "parseNewtype" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseNewtype" ((PVar "pub")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TNewtype"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "lowerNameP"))) (ELam ((PVar "params")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "upperNameP")) (ELam ((PVar "con")) (EApp (EApp (EVar "andThen") (EVar "parseTy")) (ELam ((PVar "fty")) (EApp (EApp (EVar "andThen") (EVar "derivingClause")) (ELam ((PVar "derives")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DNewtype") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "con")) (EVar "fty")) (EVar "derives"))))))))))))))))))))
(DTypeSig false "parseLetGroupDecl" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseLetGroupDecl" ((PVar "pub")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRec"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "letRecDeclClause")) (ELam ((PVar "c")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EVar "coalesceClauses") (EListLit (EVar "c"))))))))))))))
(DTypeSig false "letRecDeclClause" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))
(DFunDef false "letRecDeclClause" () (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EVar "pure") (ETuple (EVar "name") (EVar "pats") (EVar "body"))))))))))))
(DTypeSig false "parseAttrib" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "parseAttrib" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TAt"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "attrArg") (EVar "name")) (EVar "t"))) (ELam ((PVar "attr")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseDecl")) (ELam ((PVar "inner")) (EApp (EVar "pure") (EApp (EApp (EVar "DAttrib") (EListLit (EVar "attr"))) (EVar "inner"))))))))))))))))
(DTypeSig false "attrArg" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Attr")))))
(DFunDef false "attrArg" ((PVar "name") (PCon "TString" (PVar "msg"))) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EVar "mkAttr") (EVar "name")) (EApp (EVar "Some") (EVar "msg")))))))
(DFunDef false "attrArg" ((PVar "name") PWild) (EApp (EVar "pure") (EApp (EApp (EVar "mkAttr") (EVar "name")) (EVar "None"))))
(DTypeSig false "mkAttr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Attr"))))
(DFunDef false "mkAttr" ((PLit (LString "deprecated")) (PCon "Some" (PVar "msg"))) (EApp (EVar "AttrDeprecated") (EVar "msg")))
(DFunDef false "mkAttr" ((PLit (LString "must_use")) PWild) (EVar "AttrMustUse"))
(DFunDef false "mkAttr" (PWild PWild) (EVar "AttrInline"))
(DTypeSig false "externName" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "externName" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "externNameFor") (EVar "t")))))
(DTypeSig false "externNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "externNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "externNameFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "externNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected extern name"))))
(DTypeSig false "parseImport" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseImport" ((PVar "pub")) (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TImport"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "importQuals")) (ELam ((PVar "quals")) (EApp (EApp (EVar "andThen") (EApp (EVar "importPathFor") (EVar "quals"))) (ELam ((PVar "path")) (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "noExportedAlias") (EVar "pub")) (EVar "path"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "DUse") (EVar "pub")) (EVar "path")) (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "e")))))))))))))))))))
(DTypeSig false "noExportedAlias" (TyFun (TyCon "Bool") (TyFun (TyCon "UsePath") (TyApp (TyCon "Parser") (TyCon "Unit")))))
(DFunDef false "noExportedAlias" ((PCon "True") (PCon "UseAlias" PWild (PVar "a"))) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`export import … as ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "` is not allowed — a module alias is file-local (it binds `"))) (EApp (EVar "display") (EVar "a"))) (ELit (LString ".name`, which an importer could not write). Re-export the module itself (`export import m`) and let the importer choose its own alias.")))))
(DFunDef false "noExportedAlias" ((PCon "True") (PCon "UseGroup" PWild (PVar "members"))) (EApp (EVar "failIfAliasedMember") (EVar "members")))
(DFunDef false "noExportedAlias" (PWild PWild) (EApp (EVar "pure") (ELit LUnit)))
(DTypeSig false "failIfAliasedMember" (TyFun (TyApp (TyCon "List") (TyCon "UseMember")) (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "failIfAliasedMember" ((PList)) (EApp (EVar "pure") (ELit LUnit)))
(DFunDef false "failIfAliasedMember" ((PCons (PVar "m") (PVar "rest"))) (EMatch (EApp (EVar "useMemberAlias") (EVar "m")) (arm (PCon "Some" (PVar "a")) () (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`export import` cannot rename a member — re-exporting `")) (EApp (EVar "display") (EApp (EVar "useMemberOrigin") (EVar "m")))) (ELit (LString "` as `"))) (EApp (EVar "display") (EVar "a"))) (ELit (LString "` would export a name its defining module does not have. Re-export it under its own name (`export import m.{"))) (EApp (EVar "display") (EApp (EVar "useMemberOrigin") (EVar "m")))) (ELit (LString "}`) and let the importer alias it."))))) (arm (PCon "None") () (EApp (EVar "failIfAliasedMember") (EVar "rest")))))
(DTypeSig false "importQuals" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "importQuals" () (EApp (EApp (EVar "andThen") (EVar "importIdent")) (ELam ((PVar "first")) (EApp (EApp (EVar "andThen") (EVar "importQualRest")) (ELam ((PVar "rest")) (EApp (EVar "pure") (EBinOp "::" (EVar "first") (EVar "rest"))))))))
(DTypeSig false "importQualRest" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "importQualRest" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "importQualRestFor") (EVar "t")))))
(DTypeSig false "importQualRestFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importQualRestFor" ((PCon "TDot")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "importIdent")) (ELam ((PVar "x")) (EApp (EApp (EVar "andThen") (EVar "importQualRest")) (ELam ((PVar "rest")) (EApp (EVar "pure") (EBinOp "::" (EVar "x") (EVar "rest"))))))))))
(DFunDef false "importQualRestFor" (PWild) (EApp (EVar "pure") (EListLit)))
(DTypeSig false "importIdent" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "importIdent" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "importIdentFor") (EVar "t")))))
(DTypeSig false "importIdentFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "importIdentFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "importIdentFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "importIdentFor" ((PCon "TTest")) (EApp (EVar "emit") (ELit (LString "test"))))
(DFunDef false "importIdentFor" ((PCon "TRecord")) (EApp (EVar "emit") (ELit (LString "record"))))
(DFunDef false "importIdentFor" ((PCon "TData")) (EApp (EVar "emit") (ELit (LString "data"))))
(DFunDef false "importIdentFor" ((PCon "TType")) (EApp (EVar "emit") (ELit (LString "type"))))
(DFunDef false "importIdentFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected import path component"))))
(DTypeSig false "importPathFor" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Parser") (TyCon "UsePath"))))
(DFunDef false "importPathFor" ((PVar "quals")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "importPathForT") (EVar "quals")) (EVar "t")))))
(DTypeSig false "importPathForT" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UsePath")))))
(DFunDef false "importPathForT" ((PVar "quals") (PCon "TDotLBrace")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "importMember")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ms")) (EApp (EApp (EVar "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "noTrailingAlias") (ELit (LString "a selective import")))) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EVar "UseGroup") (EVar "quals")) (EVar "ms"))))))))))))))
(DFunDef false "importPathForT" ((PVar "quals") (PCon "TDotStar")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "noTrailingAlias") (ELit (LString "a wildcard import")))) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "UseWild") (EVar "quals"))))))))
(DFunDef false "importPathForT" ((PVar "quals") (PCon "TAs")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "aliasName")) (ELam ((PVar "a")) (EApp (EVar "pure") (EApp (EApp (EVar "UseAlias") (EVar "quals")) (EVar "a"))))))))
(DFunDef false "importPathForT" ((PVar "quals") PWild) (EApp (EVar "pure") (EApp (EVar "UseName") (EVar "quals"))))
(DTypeSig false "noTrailingAlias" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "noTrailingAlias" ((PVar "what")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "noTrailingAliasFor") (EVar "what")) (EVar "t")))))
(DTypeSig false "noTrailingAliasFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit")))))
(DFunDef false "noTrailingAliasFor" ((PVar "what") (PCon "TAs")) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "`as` cannot alias ")) (EApp (EVar "display") (EVar "what"))) (ELit (LString " — write `import m as A` to alias the whole module (then use `A.name`), or `import m.{name as alias}` to rename one member")))))
(DFunDef false "noTrailingAliasFor" (PWild PWild) (EApp (EVar "pure") (ELit LUnit)))
(DTypeSig false "importMember" (TyApp (TyCon "Parser") (TyCon "UseMember")))
(DFunDef false "importMember" () (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "importMemberFor") (EVar "s")) (EVar "t")))))))
(DTypeSig false "importMemberFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UseMember")))))
(DFunDef false "importMemberFor" ((PVar "s") (PCon "TIdent" (PVar "x"))) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EApp (EVar "memberAliasOrNot") (EVar "s")) (EVar "x")) (EVar "False")))))
(DFunDef false "importMemberFor" ((PVar "s") (PCon "TUpper" (PVar "x"))) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "withAllOrNot") (EVar "s")) (EVar "x")))))
(DFunDef false "importMemberFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected import member"))))
(DTypeSig false "withAllOrNot" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "UseMember")))))
(DFunDef false "withAllOrNot" ((PVar "s") (PVar "x")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "withAllFor") (EVar "s")) (EVar "x")) (EVar "t")))))
(DTypeSig false "withAllFor" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UseMember"))))))
(DFunDef false "withAllFor" ((PVar "s") (PVar "x") (PCon "TLParen")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDotDot"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EVar "andThen") (EApp (EVar "noMemberAlias") (EVar "x"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "True")) (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "q"))) (EVar "None"))))))))))))))
(DFunDef false "withAllFor" ((PVar "s") (PVar "x") PWild) (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EVar "andThen") (EApp (EVar "noMemberAlias") (EVar "x"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "False")) (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "q"))) (EVar "None"))))))))
(DTypeSig false "noMemberAlias" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "noMemberAlias" ((PVar "x")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "noMemberAliasFor") (EVar "x")) (EVar "t")))))
(DTypeSig false "noMemberAliasFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit")))))
(DFunDef false "noMemberAliasFor" ((PVar "x") (PCon "TAs")) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "` is a type or constructor and cannot be aliased — only a value member can be renamed (`import m.{name as alias}`). Import it under its own name.")))))
(DFunDef false "noMemberAliasFor" (PWild PWild) (EApp (EVar "pure") (ELit LUnit)))
(DTypeSig false "memberAliasOrNot" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "UseMember"))))))
(DFunDef false "memberAliasOrNot" ((PVar "s") (PVar "x") (PVar "allCtors")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "memberAliasFor") (EVar "s")) (EVar "x")) (EVar "allCtors")) (EVar "t")))))
(DTypeSig false "memberAliasFor" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UseMember")))))))
(DFunDef false "memberAliasFor" ((PVar "s") (PVar "x") (PVar "allCtors") (PCon "TAs")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "memberAliasName")) (ELam ((PVar "a")) (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "allCtors")) (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "q"))) (EApp (EVar "Some") (EVar "a")))))))))))
(DFunDef false "memberAliasFor" ((PVar "s") (PVar "x") (PVar "allCtors") PWild) (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "allCtors")) (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "q"))) (EVar "None"))))))
(DTypeSig false "memberAliasName" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "memberAliasName" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "memberAliasNameFor") (EVar "t")))))
(DTypeSig false "memberAliasNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "memberAliasNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "memberAliasNameFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "a value member's alias must be lowercase — `as ")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "` names a type or constructor")))))
(DFunDef false "memberAliasNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected alias name after `as`"))))
(DTypeSig false "aliasName" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "aliasName" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "aliasNameFor") (EVar "t")))))
(DTypeSig false "aliasNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "aliasNameFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "aliasNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "a module alias must be capitalized — `as ")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "` should be an Uppercase name (it is used as a qualifier, `Alias.name`)")))))
(DFunDef false "aliasNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected alias name after `as`"))))
(DTypeSig false "stringLitP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "stringLitP" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "stringLitFor") (EVar "t")))))
(DTypeSig false "stringLitFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "stringLitFor" ((PCon "TString" (PVar "s"))) (EApp (EVar "emit") (EVar "s")))
(DFunDef false "stringLitFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected string literal"))))
(DTypeSig false "parseProp" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseProp" ((PVar "pub")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TProp"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "stringLitP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "propParam"))) (ELam ((PVar "params")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "body"))))))))))))))))
(DTypeSig false "propParam" (TyApp (TyCon "Parser") (TyCon "PropParam")))
(DFunDef false "propParam" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EVar "PropParam") (EVar "name")) (EVar "ty"))))))))))))))
(DTypeSig false "parseTest" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseTest" ((PVar "pub")) (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "testPos")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TTest"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "parseTestRest") (EVar "pub")) (EVar "testPos")) (EVar "t")))))))))
(DTypeSig false "parseTestRest" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl"))))))
(DFunDef false "parseTestRest" ((PVar "pub") PWild (PCon "TString" PWild)) (EApp (EApp (EVar "andThen") (EVar "stringLitP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EVar "body"))))))))))))
(DFunDef false "parseTestRest" (PWild (PVar "testPos") PWild) (EApp (EApp (EVar "fatalAtP") (EApp (EVar "reservedKeywordMsg") (ELit (LString "test")))) (EVar "testPos")))
(DTypeSig false "parseBench" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseBench" ((PVar "pub")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TBench"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "stringLitP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "DBench") (EVar "pub")) (EVar "name")) (EVar "body"))))))))))))))
(DTypeSig false "parseEffect" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseEffect" ((PVar "pub")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEffect"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EVar "effDomainP")) (ELam ((PVar "dom")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "DEffect") (EVar "pub")) (EVar "name")) (EVar "dom"))))))))))))
(DTypeSig false "effDomainP" (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "effDomainP" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "effDomainFor") (EVar "t")))))
(DTypeSig false "effDomainFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "effDomainFor" ((PCon "TUpper" (PVar "d"))) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "Some") (EVar "d"))))))
(DFunDef false "effDomainFor" (PWild) (EApp (EVar "pure") (EVar "None")))
(DTypeSig false "parseInterface" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "parseInterface" ((PVar "pub") (PVar "isDefault")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TInterface"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "lowerNameP"))) (ELam ((PVar "typarams")) (EApp (EApp (EVar "andThen") (EVar "ifaceSuper")) (ELam ((PVar "supers")) (EApp (EApp (EVar "andThen") (EVar "ifaceBody")) (ELam ((PVar "methods")) (EApp (EVar "pure") (ERecordCreate "DInterface" ((fa "pub" (EVar "pub")) (fa "def" (EVar "isDefault")) (fa "name" (EVar "name")) (fa "typarams" (EVar "typarams")) (fa "supers" (EVar "supers")) (fa "methods" (EVar "methods"))))))))))))))))
(DTypeSig false "ifaceSuper" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Super"))))
(DFunDef false "ifaceSuper" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "ifaceSuperFor") (EVar "t")))))
(DTypeSig false "ifaceSuperFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Super")))))
(DFunDef false "ifaceSuperFor" ((PCon "TRequires")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "sepBy1") (EVar "ifaceSuperEntry")) (EApp (EVar "expectTok") (EVar "TComma"))))))
(DFunDef false "ifaceSuperFor" (PWild) (EApp (EVar "pure") (EListLit)))
(DTypeSig false "ifaceSuperEntry" (TyApp (TyCon "Parser") (TyCon "Super")))
(DFunDef false "ifaceSuperEntry" () (EApp (EApp (EVar "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "lowerNameP"))) (ELam ((PVar "params")) (EApp (EVar "pure") (EApp (EApp (EVar "Super") (EVar "name")) (EVar "params"))))))))
(DTypeSig false "ifaceBody" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceBody" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "ifaceBodyFor") (EVar "t")))))
(DTypeSig false "ifaceBodyFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "ifaceBodyFor" ((PCon "TWhere")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "ifaceWhereBody") (EVar "t")))))))
(DFunDef false "ifaceBodyFor" (PWild) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EListLit)))))
(DTypeSig false "ifaceWhereBody" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "ifaceWhereBody" ((PCon "TIndent")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "ifaceMembers")) (ELam ((PVar "ms")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EVar "ms")))))))))))
(DFunDef false "ifaceWhereBody" (PWild) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EListLit)))))
(DTypeSig false "ifaceMembers" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceMembers" () (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "ifaceMembersLoop"))))
(DTypeSig false "ifaceMembersLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceMembersLoop" () (EApp (EApp (EVar "orElse") (EVar "ifaceMembersCons")) (EApp (EVar "pure") (EListLit))))
(DTypeSig false "ifaceMembersCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceMembersCons" () (EApp (EApp (EVar "andThen") (EVar "ifaceMember")) (ELam ((PVar "m")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "ifaceMembersLoop")) (ELam ((PVar "rest")) (EApp (EVar "pure") (EBinOp "::" (EVar "m") (EVar "rest"))))))))))
(DTypeSig false "ifaceMember" (TyApp (TyCon "Parser") (TyCon "IfaceMethod")))
(DFunDef false "ifaceMember" () (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "ifaceMemberRest") (EVar "name")) (EVar "pats")) (EVar "t")))))))))
(DTypeSig false "ifaceMemberRest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "IfaceMethod"))))))
(DFunDef false "ifaceMemberRest" ((PVar "name") PWild (PCon "TColon")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "name")) (EVar "ty")) (EVar "None"))))))))
(DFunDef false "ifaceMemberRest" ((PVar "name") (PVar "pats") (PCon "TEqual")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "name")) (EApp (EVar "TyVar") (ELit (LString "_")))) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "pats")) (EVar "body"))))))))))
(DFunDef false "ifaceMemberRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected : or = in interface member"))))
(DTypeSig false "parseImpl" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseImpl" ((PVar "pub")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TImpl"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "implHead") (EVar "pub")) (EVar "t")))))))
(DTypeSig false "implHead" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "implHead" ((PVar "pub") (PCon "TUpper" (PVar "u"))) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "implRest") (EVar "pub")) (EVar "u")))))
(DFunDef false "implHead" ((PVar "pub") (PCon "TIdent" PWild)) (EApp (EVar "failP") (EVar "namedImplRemovedMsg")))
(DFunDef false "implHead" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected impl head"))))
(DTypeSig false "implRest" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "implRest" ((PVar "pub") (PVar "iface")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "tyargs")) (EApp (EApp (EVar "andThen") (EVar "implRequires")) (ELam ((PVar "reqs")) (EApp (EApp (EVar "andThen") (EVar "implBody")) (ELam ((PVar "methods")) (EApp (EVar "pure") (ERecordCreate "DImpl" ((fa "pub" (EVar "pub")) (fa "iface" (EVar "iface")) (fa "tys" (EVar "tyargs")) (fa "reqs" (EVar "reqs")) (fa "methods" (EVar "methods"))))))))))))
(DTypeSig false "namedImplRemovedMsg" (TyCon "String"))
(DFunDef false "namedImplRemovedMsg" () (ELit (LString "named impls (`impl name of Iface`) have been removed — use a plain `impl Iface` (wrap the type in a newtype for a second instance)")))
(DTypeSig false "defaultImplRemovedMsg" (TyCon "String"))
(DFunDef false "defaultImplRemovedMsg" () (ELit (LString "`default impl` has been removed — use a plain `impl` (specialization picks the most-specific instance automatically)")))
(DTypeSig false "implRequires" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Require"))))
(DFunDef false "implRequires" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "implRequiresFor") (EVar "t")))))
(DTypeSig false "implRequiresFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Require")))))
(DFunDef false "implRequiresFor" ((PCon "TRequires")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "sepBy1") (EVar "implRequireEntry")) (EApp (EVar "expectTok") (EVar "TComma"))))))
(DFunDef false "implRequiresFor" (PWild) (EApp (EVar "pure") (EListLit)))
(DTypeSig false "implRequireEntry" (TyApp (TyCon "Parser") (TyCon "Require")))
(DFunDef false "implRequireEntry" () (EApp (EApp (EVar "andThen") (EVar "upperNameP")) (ELam ((PVar "iface")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "tys")) (EApp (EVar "pure") (EApp (EApp (EVar "Require") (EVar "iface")) (EVar "tys"))))))))
(DTypeSig false "implBody" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))
(DFunDef false "implBody" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "implBodyFor") (EVar "t")))))
(DTypeSig false "implBodyFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod")))))
(DFunDef false "implBodyFor" ((PCon "TWhere")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "implWhereBody") (EVar "t")))))))
(DFunDef false "implBodyFor" (PWild) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EListLit)))))
(DTypeSig false "implWhereBody" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod")))))
(DFunDef false "implWhereBody" ((PCon "TIndent")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "implMethods")) (ELam ((PVar "ms")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EVar "ms")))))))))))
(DFunDef false "implWhereBody" (PWild) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EListLit)))))
(DTypeSig false "implMethods" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))
(DFunDef false "implMethods" () (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "implMethodsLoop"))))
(DTypeSig false "implMethodsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))
(DFunDef false "implMethodsLoop" () (EApp (EApp (EVar "orElse") (EVar "implMethodsCons")) (EApp (EVar "pure") (EListLit))))
(DTypeSig false "implMethodsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))
(DFunDef false "implMethodsCons" () (EApp (EApp (EVar "andThen") (EVar "implMethod")) (ELam ((PVar "m")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "implMethodsLoop")) (ELam ((PVar "rest")) (EApp (EVar "pure") (EBinOp "::" (EVar "m") (EVar "rest"))))))))))
(DTypeSig false "implMethod" (TyApp (TyCon "Parser") (TyCon "ImplMethod")))
(DFunDef false "implMethod" () (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EVar "pure") (EApp (EApp (EApp (EVar "ImplMethod") (EVar "name")) (EVar "pats")) (EVar "body"))))))))))))
(DTypeSig false "guardArmsWhereOpt" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "guardArmsWhereOpt" ((PVar "arms")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "guardArmsWhereFor") (EVar "arms")) (EVar "t")))))
(DTypeSig false "guardArmsWhereFor" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "guardArmsWhereFor" ((PVar "arms") (PCon "TWhere")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseWhereBindings")) (ELam ((PVar "binds")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EVar "binds"))) (EApp (EVar "EGuards") (EVar "arms")))))))))))))))
(DFunDef false "guardArmsWhereFor" ((PVar "arms") PWild) (EApp (EVar "pure") (EApp (EVar "EGuards") (EVar "arms"))))
(DTypeSig false "parseGuardArms" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "GuardArm"))))
(DFunDef false "parseGuardArms" () (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "guardArmsLoop"))))
(DTypeSig false "guardArmsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "GuardArm"))))
(DFunDef false "guardArmsLoop" () (EApp (EApp (EVar "orElse") (EVar "guardArmsCons")) (EApp (EVar "pure") (EListLit))))
(DTypeSig false "guardArmsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "GuardArm"))))
(DFunDef false "guardArmsCons" () (EApp (EApp (EVar "andThen") (EVar "parseGuardArm")) (ELam ((PVar "a")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "guardArmsLoop")) (ELam ((PVar "rest")) (EApp (EVar "pure") (EBinOp "::" (EVar "a") (EVar "rest"))))))))))
(DTypeSig false "parseGuardArm" (TyApp (TyCon "Parser") (TyCon "GuardArm")))
(DFunDef false "parseGuardArm" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parseGuard")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "guards")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EVar "pure") (EApp (EApp (EVar "GuardArm") (EVar "guards")) (EVar "body"))))))))))))
(DTypeSig false "parseGuard" (TyApp (TyCon "Parser") (TyCon "Guard")))
(DFunDef false "parseGuard" () (EApp (EApp (EVar "andThen") (EVar "parseOr")) (ELam ((PVar "e")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "guardFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "guardFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Guard")))))
(DFunDef false "guardFor" ((PVar "e") (PCon "TLArrow")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseOr")) (ELam ((PVar "rhs")) (EApp (EVar "pure") (EApp (EApp (EVar "GBind") (EApp (EVar "exprToPat") (EVar "e"))) (EVar "rhs"))))))))
(DFunDef false "guardFor" ((PVar "e") PWild) (EApp (EVar "pure") (EApp (EVar "GBool") (EVar "e"))))
(DTypeSig false "lowerNameP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "lowerNameP" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "lowerNameFor") (EVar "t")))))
(DTypeSig false "lowerNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "lowerNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "lowerNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected type parameter"))))
(DTypeSig false "parseData" (TyFun (TyCon "DataVis") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseData" ((PVar "vis")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TData"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "lowerNameP"))) (ELam ((PVar "params")) (EApp (EApp (EVar "andThen") (EApp (EVar "dataBody") (EVar "name"))) (ELam ((PVar "bodyAndDerives")) (ELet false (PVar "variants") (EApp (EVar "fst") (EVar "bodyAndDerives")) (ELet false (PVar "blockDerives") (EApp (EVar "snd") (EVar "bodyAndDerives")) (EApp (EApp (EVar "andThen") (EVar "derivingClause")) (ELam ((PVar "outerDerives")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EApp (EVar "DData") (EVar "vis")) (EVar "name")) (EVar "params")) (EVar "variants")) (EApp (EApp (EVar "combineDerives") (EVar "blockDerives")) (EVar "outerDerives")))))))))))))))))))
(DTypeSig false "combineDerives" (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyApp (TyCon "List") (TyCon "DeriveRef")))))
(DFunDef false "combineDerives" ((PList) (PVar "outer")) (EVar "outer"))
(DFunDef false "combineDerives" ((PVar "block") PWild) (EVar "block"))
(DTypeSig false "dataBody" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "DeriveRef"))))))
(DFunDef false "dataBody" ((PVar "tyName")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dataBodyFor") (EVar "tyName")) (EVar "t")))))
(DTypeSig false "dataBodyFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "DeriveRef")))))))
(DFunDef false "dataBodyFor" ((PVar "tyName") (PCon "TEqual")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dataAfterEq") (EVar "tyName")) (EVar "t")))))))
(DFunDef false "dataBodyFor" ((PVar "tyName") (PCon "TIndent")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "dataVariantsN") (EVar "tyName"))) (ELam ((PVar "vs")) (EApp (EApp (EVar "andThen") (EVar "derivingClause")) (ELam ((PVar "derives")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "pure") (ETuple (EVar "vs") (EVar "derives"))))))))))))))))
(DFunDef false "dataBodyFor" (PWild PWild) (EApp (EVar "pure") (ETuple (EListLit) (EListLit))))
(DTypeSig false "dataAfterEq" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "DeriveRef")))))))
(DFunDef false "dataAfterEq" ((PVar "tyName") (PCon "TIndent")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "optPipe")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "dataVariantsN") (EVar "tyName"))) (ELam ((PVar "vs")) (EApp (EApp (EVar "andThen") (EVar "derivingClause")) (ELam ((PVar "derives")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "pure") (ETuple (EVar "vs") (EVar "derives"))))))))))))))))))
(DFunDef false "dataAfterEq" ((PVar "tyName") PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "dataVariantsN") (EVar "tyName"))) (ELam ((PVar "vs")) (EApp (EVar "pure") (ETuple (EVar "vs") (EListLit))))))
(DTypeSig false "optPipe" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "optPipe" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "optPipeFor") (EVar "t")))))
(DTypeSig false "optPipeFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "optPipeFor" ((PCon "TPipe")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "pure") (ELit LUnit)))))
(DFunDef false "optPipeFor" (PWild) (EApp (EVar "pure") (ELit LUnit)))
(DTypeSig false "dataVariantsN" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Variant")))))
(DFunDef false "dataVariantsN" ((PVar "tyName")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dataVariantsNFor") (EVar "tyName")) (EVar "t")))))
(DTypeSig false "dataVariantsNFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Variant"))))))
(DFunDef false "dataVariantsNFor" ((PVar "tyName") (PCon "TLBrace")) (EApp (EApp (EVar "andThen") (EVar "parseNamedFields")) (ELam ((PVar "fields")) (EApp (EVar "pure") (EListLit (EApp (EApp (EVar "Variant") (EVar "tyName")) (EApp (EApp (EVar "ConNamed") (EVar "fields")) (EVar "True"))))))))
(DFunDef false "dataVariantsNFor" (PWild PWild) (EVar "dataVariants"))
(DTypeSig false "dataVariants" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Variant"))))
(DFunDef false "dataVariants" () (EApp (EApp (EVar "andThen") (EVar "parseVariant")) (ELam ((PVar "v")) (EApp (EApp (EVar "andThen") (EVar "variantsRest")) (ELam ((PVar "rest")) (EApp (EVar "pure") (EBinOp "::" (EVar "v") (EVar "rest"))))))))
(DTypeSig false "variantsRest" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Variant"))))
(DFunDef false "variantsRest" () (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "variantsRestFor") (EVar "t")))))))
(DTypeSig false "variantsRestFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Variant")))))
(DFunDef false "variantsRestFor" ((PCon "TPipe")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseVariant")) (ELam ((PVar "v")) (EApp (EApp (EVar "andThen") (EVar "variantsRest")) (ELam ((PVar "rest")) (EApp (EVar "pure") (EBinOp "::" (EVar "v") (EVar "rest"))))))))))
(DFunDef false "variantsRestFor" (PWild) (EApp (EVar "pure") (EListLit)))
(DTypeSig false "parseVariant" (TyApp (TyCon "Parser") (TyCon "Variant")))
(DFunDef false "parseVariant" () (EApp (EApp (EVar "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EVar "parsePayload")) (ELam ((PVar "payload")) (EApp (EVar "pure") (EApp (EApp (EVar "Variant") (EVar "name")) (EVar "payload"))))))))
(DTypeSig false "parsePayload" (TyApp (TyCon "Parser") (TyCon "ConPayload")))
(DFunDef false "parsePayload" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "payloadFor") (EVar "t")))))
(DTypeSig false "payloadFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "ConPayload"))))
(DFunDef false "payloadFor" ((PCon "TLBrace")) (EVar "parseNamedPayload"))
(DFunDef false "payloadFor" (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "tys")) (EApp (EVar "pure") (EApp (EVar "ConPos") (EVar "tys"))))))
(DTypeSig false "parseNamedPayload" (TyApp (TyCon "Parser") (TyCon "ConPayload")))
(DFunDef false "parseNamedPayload" () (EApp (EApp (EVar "andThen") (EVar "parseNamedFields")) (ELam ((PVar "fields")) (EApp (EVar "pure") (EApp (EApp (EVar "ConNamed") (EVar "fields")) (EVar "False"))))))
(DTypeSig false "parseNamedFields" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Field"))))
(DFunDef false "parseNamedFields" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parseField")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "fields")) (EApp (EApp (EVar "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EVar "pure") (EVar "fields")))))))))))
(DTypeSig false "parseField" (TyApp (TyCon "Parser") (TyCon "Field")))
(DFunDef false "parseField" () (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseTy")) (ELam ((PVar "t")) (EApp (EVar "pure") (EApp (EApp (EVar "Field") (EVar "name")) (EVar "t"))))))))))
(DTypeSig false "derivingClause" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DeriveRef"))))
(DFunDef false "derivingClause" () (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "derivingFor") (EVar "t")))))))
(DTypeSig false "derivingFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DeriveRef")))))
(DFunDef false "derivingFor" ((PCon "TDeriving")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "sepBy1") (EVar "derivedNameP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "names")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "pure") (EVar "names")))))))))))
(DFunDef false "derivingFor" (PWild) (EApp (EVar "pure") (EListLit)))
(DTypeSig false "derivedNameP" (TyApp (TyCon "Parser") (TyCon "DeriveRef")))
(DFunDef false "derivedNameP" () (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "andThen") (EVar "upperNameP")) (ELam ((PVar "n")) (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "pure") (EApp (EApp (EVar "DeriveRef") (EVar "n")) (EApp (EVar "Some") (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "q"))))))))))))
(DTypeSig false "parseBody" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBody" () (EApp (EApp (EVar "orElse") (EVar "indentedBody")) (EVar "parseBodyExpr")))
(DTypeSig false "parseBodyExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBodyExpr" () (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EVar "orElse") (EApp (EVar "whereEol") (EVar "e"))) (EApp (EApp (EVar "orElse") (EApp (EVar "whereTail") (EVar "e"))) (EApp (EVar "pure") (EVar "e")))))))
(DTypeSig false "whereEol" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "whereEol" ((PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TWhere"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseWhereBindings")) (ELam ((PVar "binds")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EVar "binds"))) (EVar "e"))))))))))))
(DTypeSig false "whereTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "whereTail" ((PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TWhere"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseWhereBindings")) (ELam ((PVar "binds")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EVar "binds"))) (EVar "e"))))))))))))))))))
(DTypeSig false "parseWhereBindings" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "parseWhereBindings" () (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "whereBindingsLoop"))))
(DTypeSig false "whereBindingsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "whereBindingsLoop" () (EApp (EApp (EVar "orElse") (EVar "whereBindingsCons")) (EApp (EVar "pure") (EListLit))))
(DTypeSig false "whereBindingsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "whereBindingsCons" () (EApp (EApp (EVar "andThen") (EVar "parseWhereBinding")) (ELam ((PVar "b")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "whereBindingsLoop")) (ELam ((PVar "rest")) (EApp (EVar "pure") (EBinOp "::" (EVar "b") (EVar "rest"))))))))))
(DTypeSig false "parseWhereBinding" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))
(DFunDef false "parseWhereBinding" () (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "whereBindRest") (EVar "name")) (EVar "pats")) (EVar "t")))))))))
(DTypeSig false "whereBindRest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "whereBindRest" ((PVar "name") (PList) (PCon "TColon")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "body")) (EApp (EVar "pure") (ETuple (EVar "name") (EListLit) (EApp (EApp (EVar "EAnnot") (EVar "body")) (EVar "ty")))))))))))))
(DFunDef false "whereBindRest" ((PVar "name") (PVar "pats") (PCon "TEqual")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "body")) (EApp (EVar "pure") (ETuple (EVar "name") (EVar "pats") (EVar "body"))))))))
(DFunDef false "whereBindRest" ((PVar "name") (PVar "pats") (PCon "TIndent")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseGuardArms")) (ELam ((PVar "arms")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "pure") (ETuple (EVar "name") (EVar "pats") (EApp (EVar "EGuards") (EVar "arms")))))))))))
(DFunDef false "whereBindRest" ((PVar "name") (PVar "pats") (PCon "TPipe")) (EApp (EApp (EVar "andThen") (EVar "parseGuardArm")) (ELam ((PVar "arm")) (EApp (EVar "pure") (ETuple (EVar "name") (EVar "pats") (EApp (EVar "EGuards") (EListLit (EVar "arm"))))))))
(DFunDef false "whereBindRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected where binding body"))))
(DTypeSig false "coalesceClauses" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "coalesceClauses" ((PList)) (EListLit))
(DFunDef false "coalesceClauses" ((PCons (PTuple (PVar "name") (PVar "ps") (PVar "b")) (PVar "rest"))) (EApp (EApp (EApp (EVar "coalesceGo") (EVar "name")) (EListLit (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "b")))) (EVar "rest")))
(DTypeSig false "coalesceGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "LetBind"))))))
(DFunDef false "coalesceGo" ((PVar "name") (PVar "acc") (PList)) (EListLit (EApp (EApp (EVar "LetBind") (EVar "name")) (EApp (EVar "reverseL") (EVar "acc")))))
(DFunDef false "coalesceGo" ((PVar "name") (PVar "acc") (PCons (PTuple (PVar "n") (PVar "ps") (PVar "b")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "coalesceStep") (EVar "name")) (EVar "acc")) (EVar "n")) (EVar "ps")) (EVar "b")) (EVar "rest")))
(DTypeSig false "coalesceStep" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "LetBind")))))))))
(DFunDef false "coalesceStep" ((PVar "name") (PVar "acc") (PVar "n") (PVar "ps") (PVar "b") (PVar "rest")) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EApp (EVar "coalesceGo") (EVar "name")) (EBinOp "::" (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "b")) (EVar "acc"))) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "LetBind") (EVar "name")) (EApp (EVar "reverseL") (EVar "acc"))) (EApp (EApp (EApp (EVar "coalesceGo") (EVar "n")) (EListLit (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "b")))) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "indentedBody" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "indentedBody" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseStmts")) (ELam ((PVar "stmts")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "blockOrExpr") (EVar "stmts"))))))))))
(DTypeSig false "blockOrExpr" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Expr")))
(DFunDef false "blockOrExpr" ((PList (PCon "DoExpr" (PVar "e")))) (EVar "e"))
(DFunDef false "blockOrExpr" ((PVar "stmts")) (EApp (EVar "EBlock") (EVar "stmts")))
(DTypeSig false "parseDo" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseDo" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDo"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseStmts")) (ELam ((PVar "stmts")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "pure") (EApp (EVar "EDo") (EVar "stmts"))))))))))))
(DTypeSig false "parseRhsExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseRhsExpr" () (EApp (EApp (EVar "orElse") (EVar "parseBracketBlock")) (EVar "parseExpr")))
(DTypeSig false "parseStmts" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "parseStmts" () (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "stmtsLoop"))))
(DTypeSig false "stmtsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "stmtsLoop" () (EApp (EApp (EVar "orElse") (EVar "stmtsCons")) (EApp (EVar "pure") (EListLit))))
(DTypeSig false "stmtsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "stmtsCons" () (EApp (EApp (EVar "andThen") (EVar "parseStmt")) (ELam ((PVar "ss")) (EApp (EApp (EVar "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "stmtsLoop")) (ELam ((PVar "rest")) (EApp (EVar "pure") (EBinOp "++" (EVar "ss") (EVar "rest"))))))))))
(DTypeSig false "parseStmt" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "parseStmt" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "stmtFor") (EVar "t")))))
(DTypeSig false "stmtFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "stmtFor" ((PCon "TLet")) (EApp (EApp (EVar "andThen") (EVar "parseLetStmt")) (ELam ((PVar "s")) (EApp (EVar "pure") (EListLit (EVar "s"))))))
(DFunDef false "stmtFor" (PWild) (EVar "parseExprStmt"))
(DTypeSig false "parseLetStmt" (TyApp (TyCon "Parser") (TyCon "DoStmt")))
(DFunDef false "parseLetStmt" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "letKind") (EVar "t")))))))
(DTypeSig false "letKind" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))
(DFunDef false "letKind" ((PCon "TMut")) (EApp (EVar "failP") (EVar "letMutRemovedMsg")))
(DFunDef false "letKind" ((PCon "TRec")) (EVar "letRecStmt"))
(DFunDef false "letKind" ((PCon "TIdent" (PVar "name"))) (EApp (EVar "letIdent") (EVar "name")))
(DFunDef false "letKind" (PWild) (EVar "letPat"))
(DTypeSig false "letRecStmt" (TyApp (TyCon "Parser") (TyCon "DoStmt")))
(DFunDef false "letRecStmt" () (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TRec"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "letFunTailFor") (EVar "name")) (EVar "pats")) (EVar "e1")) (EVar "t")))))))))))))))
(DTypeSig false "letIdent" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))
(DFunDef false "letIdent" ((PVar "name")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "letIdentBody") (EVar "name")) (EVar "pats")) (EVar "t")))))))))
(DTypeSig false "letIdentBody" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))))
(DFunDef false "letIdentBody" ((PVar "name") (PList) (PCon "TColon")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EApp (EVar "letIdentRest") (EVar "name")) (EListLit)) (EApp (EApp (EVar "EAnnot") (EVar "e1")) (EVar "ty"))))))))))))
(DFunDef false "letIdentBody" ((PVar "name") (PVar "pats") PWild) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EApp (EVar "letIdentRest") (EVar "name")) (EVar "pats")) (EVar "e1")))))))
(DTypeSig false "letIdentRest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))))
(DFunDef false "letIdentRest" ((PVar "name") (PList) (PVar "e1")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "letTailFor") (EApp (EVar "PVar") (EVar "name"))) (EVar "e1")) (EVar "t")))))
(DFunDef false "letIdentRest" ((PVar "name") (PVar "pats") (PVar "e1")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "letFunTailFor") (EVar "name")) (EVar "pats")) (EVar "e1")) (EVar "t")))))
(DTypeSig false "letFunTailFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt")))))))
(DFunDef false "letFunTailFor" ((PVar "name") (PVar "pats") (PVar "e1") (PCon "TIn")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EVar "pure") (EApp (EVar "DoExpr") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "False")) (EVar "True")) (EApp (EVar "PVar") (EVar "name"))) (EApp (EApp (EVar "curryLam") (EVar "pats")) (EVar "e1"))) (EVar "e2")))))))))
(DFunDef false "letFunTailFor" ((PVar "name") (PVar "pats") (PVar "e1") PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "False")) (EVar "True")) (EApp (EVar "PVar") (EVar "name"))) (EApp (EApp (EVar "curryLam") (EVar "pats")) (EVar "e1")))))
(DTypeSig false "letPat" (TyApp (TyCon "Parser") (TyCon "DoStmt")))
(DFunDef false "letPat" () (EApp (EApp (EVar "andThen") (EVar "parsePat")) (ELam ((PVar "pat")) (EApp (EApp (EVar "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "letTailFor") (EVar "pat")) (EVar "e1")) (EVar "t")))))))))))
(DTypeSig false "letTailFor" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))))
(DFunDef false "letTailFor" ((PVar "pat") (PVar "e1") (PCon "TIn")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EVar "pure") (EApp (EVar "DoExpr") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "False")) (EVar "False")) (EVar "pat")) (EVar "e1")) (EVar "e2")))))))))
(DFunDef false "letTailFor" ((PVar "pat") (PVar "e1") PWild) (EApp (EVar "pure") (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "False")) (EVar "False")) (EVar "pat")) (EVar "e1"))))
(DTypeSig false "curryLam" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "curryLam" ((PList) (PVar "body")) (EVar "body"))
(DFunDef false "curryLam" ((PCons (PVar "p") (PVar "ps")) (PVar "body")) (EApp (EApp (EVar "ELam") (EListLit (EVar "p"))) (EApp (EApp (EVar "curryLam") (EVar "ps")) (EVar "body"))))
(DTypeSig false "parseExprStmt" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "parseExprStmt" () (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "exprStmtFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "exprStmtFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "exprStmtFor" ((PVar "e") (PCon "TLArrow")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "rhs")) (EApp (EVar "pure") (EApp (EApp (EVar "bindStmts") (EVar "e")) (EVar "rhs"))))))))
(DFunDef false "exprStmtFor" ((PVar "e") (PCon "TEqual")) (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "andThen") (EVar "parseExpr")) (ELam ((PVar "rhs")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "assignFromLhs") (EVar "e")) (EVar "rhs"))) (ELam ((PVar "s")) (EApp (EVar "pure") (EListLit (EVar "s"))))))))))
(DFunDef false "exprStmtFor" ((PVar "e") PWild) (EApp (EVar "pure") (EListLit (EApp (EVar "DoExpr") (EVar "e")))))
(DTypeSig false "bindStmts" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "bindStmts" ((PVar "lhs") (PVar "rhs")) (EMatch (EApp (EVar "stripLoc") (EVar "lhs")) (arm (PCon "EAnnot" (PVar "inner") (PVar "ty")) () (EApp (EApp (EApp (EVar "bindAnnot") (EVar "inner")) (EVar "ty")) (EVar "rhs"))) (arm PWild () (EListLit (EApp (EApp (EVar "DoBind") (EApp (EVar "exprToPat") (EVar "lhs"))) (EVar "rhs"))))))
(DTypeSig false "bindAnnot" (TyFun (TyCon "Expr") (TyFun (TyCon "Ty") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "bindAnnot" ((PVar "inner") (PVar "ty") (PVar "rhs")) (EMatch (EApp (EVar "stripLoc") (EVar "inner")) (arm (PCon "EVar" (PVar "x")) () (EListLit (EApp (EApp (EVar "DoBind") (EApp (EVar "PVar") (EVar "x"))) (EVar "rhs")) (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "False")) (EVar "False")) (EApp (EVar "PVar") (EVar "x"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "EVar") (EVar "x"))) (EVar "ty"))))) (arm (PVar "other") () (EListLit (EApp (EApp (EVar "DoBind") (EApp (EVar "exprToPat") (EVar "other"))) (EVar "rhs"))))))
(DTypeSig false "assignFromLhs" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "DoStmt")))))
(DFunDef false "assignFromLhs" ((PVar "lhs") (PVar "rhs")) (EMatch (EApp (EVar "flattenFieldPath") (EVar "lhs")) (arm (PCon "Some" (PTuple (PVar "x") (PList))) () (EApp (EVar "pure") (EApp (EApp (EVar "DoAssign") (EVar "x")) (EVar "rhs")))) (arm (PCon "Some" (PTuple (PVar "x") (PVar "fs"))) () (EApp (EVar "pure") (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EVar "rhs")))) (arm (PCon "None") () (EApp (EVar "failP") (ELit (LString "invalid assignment target in do-block"))))))
(DTypeSig false "flattenFieldPath" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "flattenFieldPath" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "flattenFieldPath") (EVar "e")))
(DFunDef false "flattenFieldPath" ((PCon "EVar" (PVar "x"))) (EApp (EVar "Some") (ETuple (EVar "x") (EListLit))))
(DFunDef false "flattenFieldPath" ((PCon "EFieldAccess" (PVar "inner") (PVar "f") PWild)) (EApp (EApp (EVar "fieldPathExtend") (EApp (EVar "flattenFieldPath") (EVar "inner"))) (EVar "f")))
(DFunDef false "flattenFieldPath" (PWild) (EVar "None"))
(DTypeSig false "fieldPathExtend" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "fieldPathExtend" ((PCon "Some" (PTuple (PVar "x") (PVar "fs"))) (PVar "f")) (EApp (EVar "Some") (ETuple (EVar "x") (EBinOp "++" (EVar "fs") (EListLit (EVar "f"))))))
(DFunDef false "fieldPathExtend" ((PCon "None") PWild) (EVar "None"))
(DTypeSig false "skipNoise" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "skipNoise" () (EApp (EApp (EVar "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "skipNoiseFor") (EVar "t")))))
(DTypeSig false "skipNoiseFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "skipNoiseFor" ((PCon "TNewline")) (EVar "afterNoise"))
(DFunDef false "skipNoiseFor" ((PCon "TIndent")) (EVar "afterNoise"))
(DFunDef false "skipNoiseFor" ((PCon "TDedent")) (EVar "afterNoise"))
(DFunDef false "skipNoiseFor" (PWild) (EApp (EVar "pure") (ELit LUnit)))
(DTypeSig false "afterNoise" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "afterNoise" () (EApp (EApp (EVar "andThen") (EVar "advance")) (ELam (PWild) (EVar "skipNoise"))))
(DTypeSig false "declThenNoise" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "declThenNoise" () (EApp (EApp (EVar "andThen") (EVar "parseDecl")) (ELam ((PVar "d")) (EApp (EApp (EVar "andThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EVar "pure") (EVar "d")))))))
(DTypeSig false "parseProgram" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parseProgram" () (EApp (EApp (EVar "andThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EVar "many") (EVar "declThenNoise")))))
(DData Public "DeclPos" () ((variant "DeclPos" (ConPos (TyCon "Int") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Public "Positions" () ((variant "Positions" (ConPos (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DTypeSig true "positionsDecls" (TyFun (TyCon "Positions") (TyApp (TyCon "List") (TyCon "DeclPos"))))
(DFunDef false "positionsDecls" ((PCon "Positions" (PVar "ds") PWild PWild PWild)) (EVar "ds"))
(DTypeSig true "positionsVariantLines" (TyFun (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "positionsVariantLines" ((PCon "Positions" PWild (PVar "vs") PWild PWild)) (EVar "vs"))
(DTypeSig true "positionsLastContentLine" (TyFun (TyCon "Positions") (TyCon "Int")))
(DFunDef false "positionsLastContentLine" ((PCon "Positions" PWild PWild (PVar "l") PWild)) (EVar "l"))
(DTypeSig true "positionsChainLines" (TyFun (TyCon "Positions") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "positionsChainLines" ((PCon "Positions" PWild PWild PWild (PVar "cl"))) (EVar "cl"))
(DTypeSig true "declPosLine" (TyFun (TyCon "DeclPos") (TyCon "Int")))
(DFunDef false "declPosLine" ((PCon "DeclPos" (PVar "l") PWild PWild PWild)) (EVar "l"))
(DTypeSig true "declPosEndLine" (TyFun (TyCon "DeclPos") (TyCon "Int")))
(DFunDef false "declPosEndLine" ((PCon "DeclPos" PWild (PVar "e") PWild PWild)) (EVar "e"))
(DTypeSig true "declPosNameLoc" (TyFun (TyCon "DeclPos") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "declPosNameLoc" ((PCon "DeclPos" PWild PWild (PVar "nl") PWild)) (EVar "nl"))
(DTypeSig true "declPosChildLocs" (TyFun (TyCon "DeclPos") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "declPosChildLocs" ((PCon "DeclPos" PWild PWild PWild (PVar "cs"))) (EVar "cs"))
(DTypeSig false "declWithSpan" (TyApp (TyCon "Parser") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "declWithSpan" () (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "andThen") (EVar "parseDecl")) (ELam ((PVar "d")) (EApp (EApp (EVar "andThen") (EVar "getPos")) (ELam ((PVar "e")) (EApp (EVar "pure") (ETuple (EVar "d") (EVar "s") (EVar "e"))))))))))
(DTypeSig false "spanDeclThenNoise" (TyApp (TyCon "Parser") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "spanDeclThenNoise" () (EApp (EApp (EVar "andThen") (EVar "declWithSpan")) (ELam ((PVar "ds")) (EApp (EApp (EVar "andThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EVar "pure") (EVar "ds")))))))
(DTypeSig false "programWithSpans" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "programWithSpans" () (EApp (EApp (EVar "andThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EVar "many") (EVar "spanDeclThenNoise")))))
(DTypeSig false "isNoiseTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isNoiseTok" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "isNoiseTok" ((PCon "TIndent")) (EVar "True"))
(DFunDef false "isNoiseTok" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "isNoiseTok" (PWild) (EVar "False"))
(DTypeSig false "lastContentIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "lastContentIdx" ((PVar "toks") (PVar "s") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (EVar "s")) (EVar "s") (EIf (EApp (EVar "isNoiseTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EVar "lastContentIdx") (EVar "toks")) (EVar "s")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lineAt" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lineAt" ((PVar "lines") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "lines"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "lines")) (EIf (EVar "otherwise") (ELit (LInt 0)) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "locOfSpanWith" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Loc"))))))
(DFunDef false "locOfSpanWith" ((PVar "offs") (PVar "lineStarts") (PVar "startIdx") (PVar "endIdx")) (EBlock (DoLet false false (PVar "lastIdx") (EIf (EBinOp ">" (EVar "endIdx") (EVar "startIdx")) (EBinOp "-" (EVar "endIdx") (ELit (LInt 1))) (EVar "startIdx"))) (DoLet false false (PVar "startOff") (EApp (EApp (EVar "tokOffsetAtArr") (EVar "offs")) (EVar "startIdx"))) (DoLet false false (PVar "endOff") (EApp (EApp (EVar "tokEndOffsetAtArr") (EVar "offs")) (EVar "lastIdx"))) (DoExpr (EMatch (EApp (EApp (EVar "offsetToLineColFast") (EVar "lineStarts")) (EVar "startOff")) (arm (PTuple (PVar "sl") (PVar "sc")) () (EMatch (EApp (EApp (EVar "offsetToLineColFast") (EVar "lineStarts")) (EVar "endOff")) (arm (PTuple (PVar "el") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))))))))
(DTypeSig false "tokOffsetAtArr" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "tokOffsetAtArr" ((PVar "offs") (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs")))) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs"))) (ELit (LInt 0))))
(DTypeSig false "tokEndOffsetAtArr" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "tokEndOffsetAtArr" ((PVar "offs") (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs")))) (EApp (EVar "snd") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs"))) (ELit (LInt 0))))
(DTypeSig false "isLeadingModifierTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLeadingModifierTok" ((PCon "TPublic")) (EVar "True"))
(DFunDef false "isLeadingModifierTok" ((PCon "TExport")) (EVar "True"))
(DFunDef false "isLeadingModifierTok" ((PCon "TDefault")) (EVar "True"))
(DFunDef false "isLeadingModifierTok" ((PVar "t")) (EApp (EVar "isNoiseTok") (EVar "t")))
(DTypeSig false "skipLeadingModifiers" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "skipLeadingModifiers" ((PVar "toks") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EVar "isLeadingModifierTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")))) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isTStringTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isTStringTok" ((PCon "TString" PWild)) (EVar "True"))
(DFunDef false "isTStringTok" (PWild) (EVar "False"))
(DTypeSig false "tokIdxOrNone" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "tokIdxOrNone" ((PVar "toks") (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks")))) (EApp (EVar "Some") (EVar "i")) (EVar "None")))
(DTypeSig false "declNameTokIdxAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DAttrib" PWild (PVar "inner")) (PVar "i")) (EBlock (DoLet false false (PVar "i1") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (DoLet false false (PVar "i2") (EBinOp "+" (EVar "i1") (ELit (LInt 1)))) (DoLet false false (PVar "i3") (EIf (EBinOp "&&" (EBinOp "<" (EVar "i2") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EVar "isTStringTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i2")) (EVar "toks")))) (EBinOp "+" (EVar "i2") (ELit (LInt 1))) (EVar "i2"))) (DoExpr (EApp (EApp (EApp (EVar "declNameTokIdx") (EVar "toks")) (EVar "inner")) (EVar "i3")))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DTypeSig" PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EVar "i")))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DFunDef" PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EVar "i")))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DExtern" PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DData" PWild PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DEffect" PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DProp" PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DTest" PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DBench" PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PRec "DInterface" () true) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DTypeAlias" PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DNewtype" PWild PWild PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DLetGroup" PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PRec "DImpl" () true) (PVar "i")) (EVar "None"))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DUse" PWild PWild PWild) (PVar "i")) (EVar "None"))
(DTypeSig false "declNameTokIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "declNameTokIdx" ((PVar "toks") (PVar "d") (PVar "i")) (EApp (EApp (EApp (EVar "declNameTokIdxAt") (EVar "toks")) (EVar "d")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EVar "i"))))
(DTypeSig false "declNameSpanOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "declNameSpanOf" ((PVar "toks") (PVar "offs") (PVar "lineStarts") (PTuple (PVar "d") (PVar "s") (PVar "_e"))) (EApp (EApp (EVar "map") (ELam ((PVar "nameIdx")) (EApp (EApp (EApp (EApp (EVar "locOfSpanWith") (EVar "offs")) (EVar "lineStarts")) (EVar "nameIdx")) (EBinOp "+" (EVar "nameIdx") (ELit (LInt 1)))))) (EApp (EApp (EApp (EVar "declNameTokIdx") (EVar "toks")) (EVar "d")) (EVar "s"))))
(DTypeSig false "innerDeclOf" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "innerDeclOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "innerDeclOf") (EVar "d")))
(DFunDef false "innerDeclOf" ((PVar "d")) (EVar "d"))
(DTypeSig false "declChildNameIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "declChildNameIdxs" ((PVar "toks") (PTuple (PVar "d") (PVar "s") (PVar "e"))) (EMatch (EApp (EVar "innerDeclOf") (EVar "d")) (arm (PCon "DData" PWild PWild PWild (PVar "variants") PWild) () (EApp (EApp (EApp (EApp (EVar "dataChildIdxs") (EVar "toks")) (EVar "s")) (EVar "e")) (EVar "variants"))) (arm (PRec "DInterface" () true) () (EApp (EApp (EApp (EVar "methodNameIdxs") (EVar "toks")) (EVar "s")) (EVar "e"))) (arm (PRec "DImpl" () true) () (EApp (EApp (EApp (EVar "methodNameIdxs") (EVar "toks")) (EVar "s")) (EVar "e"))) (arm (PCon "DLetGroup" PWild PWild) () (EListLit (EApp (EApp (EApp (EVar "declNameTokIdx") (EVar "toks")) (EVar "d")) (EVar "s")))) (arm PWild () (EListLit))))
(DTypeSig false "variantBoundaryIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "variantBoundaryIdxs" ((PVar "toks") (PVar "s") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EVar "s")) (EVar "e")) (ELit (LInt 0))) (EVar "False")))
(DTypeSig false "variantBoundaryGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "variantBoundaryGo" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryAt") (EVar "toks")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "variantBoundaryAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "variantBoundaryAt" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EBinOp "==" (EVar "t") (EVar "TEqual"))) (EApp (EApp (EApp (EVar "nextSigIsPipe") (EVar "toks")) (EVar "e")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EBinOp "==" (EVar "t") (EVar "TEqual"))) (EBinOp "::" (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EVar "seenEq")) (EBinOp "==" (EVar "t") (EVar "TPipe"))) (EBinOp "::" (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "dataChildIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "dataChildIdxs" ((PVar "toks") (PVar "s") (PVar "e") (PVar "variants")) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "variants")) (EApp (EApp (EApp (EVar "variantBoundaryIdxs") (EVar "toks")) (EVar "s")) (EVar "e"))))
(DTypeSig false "zipVariantIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "zipVariantIdxs" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "zipVariantIdxs" ((PVar "toks") (PVar "e") (PCons (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True"))) (PVar "vs")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "++" (EApp (EApp (EVar "zipFieldIdxs") (EVar "fs")) (EApp (EApp (EApp (EVar "fieldNameIdxsIn") (EVar "toks")) (EBinOp "+" (EVar "b") (ELit (LInt 1)))) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "vs")) (EVar "bs"))))
(DFunDef false "zipVariantIdxs" ((PVar "toks") (PVar "e") (PCons (PCon "Variant" PWild PWild) (PVar "vs")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "::" (EApp (EVar "Some") (EVar "b")) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "vs")) (EVar "bs"))))
(DFunDef false "zipVariantIdxs" ((PVar "toks") (PVar "e") (PCons (PVar "v") (PVar "vs")) (PList)) (EBinOp "++" (EApp (EVar "variantNoneIdxs") (EVar "v")) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "vs")) (EListLit))))
(DTypeSig false "variantNoneIdxs" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "variantNoneIdxs" ((PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True")))) (EApp (EApp (EVar "map") (ELam (PWild) (EVar "None"))) (EVar "fs")))
(DFunDef false "variantNoneIdxs" ((PCon "Variant" PWild PWild)) (EListLit (EVar "None")))
(DTypeSig false "fieldNameIdxsIn" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "fieldNameIdxsIn" ((PVar "toks") (PVar "i") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EVar "i")) (EVar "e")) (ELit (LInt 1))) (EVar "True")))
(DTypeSig false "fieldNameGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "fieldNameGo" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameStep") (EVar "toks")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "atStart")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "fieldNameStep" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "fieldNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 1))) (EBinOp "==" (EVar "t") (EVar "TComma"))) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True")) (EIf (EApp (EVar "isNoiseTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "atStart")) (EIf (EBinOp "&&" (EVar "atStart") (EBinOp "==" (EVar "depth") (ELit (LInt 1)))) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "zipFieldIdxs" (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "zipFieldIdxs" ((PList) PWild) (EListLit))
(DFunDef false "zipFieldIdxs" ((PCons PWild (PVar "fs")) (PCons (PVar "i") (PVar "is"))) (EBinOp "::" (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EVar "zipFieldIdxs") (EVar "fs")) (EVar "is"))))
(DFunDef false "zipFieldIdxs" ((PCons PWild (PVar "fs")) (PList)) (EBinOp "::" (EVar "None") (EApp (EApp (EVar "zipFieldIdxs") (EVar "fs")) (EListLit))))
(DTypeSig false "methodNameIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "methodNameIdxs" ((PVar "toks") (PVar "s") (PVar "e")) (EMatch (EApp (EApp (EApp (EVar "findWhereIdx") (EVar "toks")) (EVar "s")) (EVar "e")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "w")) () (EBlock (DoLet false false (PVar "after") (EApp (EApp (EApp (EVar "skipNewlineToks") (EVar "toks")) (EBinOp "+" (EVar "w") (ELit (LInt 1)))) (EVar "e"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "after") (EVar "e")) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "after")) (EVar "toks")) (EVar "TIndent"))) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "after") (ELit (LInt 1)))) (EVar "e")) (ELit (LInt 1))) (EVar "True")) (EListLit)))))))
(DTypeSig false "findWhereIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "findWhereIdx" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")) (EVar "TWhere")) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "findWhereIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "skipNewlineToks" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipNewlineToks" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EVar "e")) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")) (EVar "TNewline"))) (EApp (EApp (EApp (EVar "skipNewlineToks") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "methodNameGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "methodNameGo" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "methodNameStep") (EVar "toks")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "atStart")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "methodNameStep" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))))))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") PWild (PCon "TIndent")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "False")))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") PWild (PCon "TDedent")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "False")))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") PWild (PCon "TNewline")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EBinOp "==" (EVar "depth") (ELit (LInt 1)))))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart") PWild) (EIf (EBinOp "&&" (EVar "atStart") (EBinOp "==" (EVar "depth") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declChildSpansOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))))))))
(DFunDef false "declChildSpansOf" ((PVar "toks") (PVar "offs") (PVar "lineStarts") (PVar "span")) (EApp (EApp (EVar "map") (ELam ((PVar "idxOpt")) (EApp (EApp (EVar "map") (ELam ((PVar "idx")) (EApp (EApp (EApp (EApp (EVar "locOfSpanWith") (EVar "offs")) (EVar "lineStarts")) (EVar "idx")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))))) (EVar "idxOpt")))) (EApp (EApp (EVar "declChildNameIdxs") (EVar "toks")) (EVar "span"))))
(DTypeSig false "declPosOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyCon "DeclPos")))))))
(DFunDef false "declPosOf" ((PVar "toks") (PVar "lines") (PVar "offs") (PVar "lineStarts") (PTuple (PVar "d") (PVar "s") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DeclPos") (EApp (EApp (EVar "lineAt") (EVar "lines")) (EVar "s"))) (EApp (EApp (EVar "lineAt") (EVar "lines")) (EApp (EApp (EApp (EVar "lastContentIdx") (EVar "toks")) (EVar "s")) (EBinOp "-" (EVar "e") (ELit (LInt 1)))))) (EApp (EApp (EApp (EApp (EVar "declNameSpanOf") (EVar "toks")) (EVar "offs")) (EVar "lineStarts")) (ETuple (EVar "d") (EVar "s") (EVar "e")))) (EApp (EApp (EApp (EApp (EVar "declChildSpansOf") (EVar "toks")) (EVar "offs")) (EVar "lineStarts")) (ETuple (EVar "d") (EVar "s") (EVar "e")))))
(DTypeSig false "variantStartsIn" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "variantStartsIn" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EVar "i")) (EVar "e")) (ELit (LInt 0))) (EVar "False")))
(DTypeSig false "variantStartsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "variantStartsGo" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsAt") (EVar "toks")) (EVar "lines")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "variantStartsAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "variantStartsAt" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EBinOp "==" (EVar "t") (EVar "TEqual"))) (EApp (EApp (EApp (EVar "nextSigIsPipe") (EVar "toks")) (EVar "e")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EBinOp "==" (EVar "t") (EVar "TEqual"))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EVar "seenEq")) (EBinOp "==" (EVar "t") (EVar "TPipe"))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "nextSigIsPipe" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "nextSigIsPipe" ((PVar "toks") (PVar "e") (PVar "j")) (EIf (EBinOp ">=" (EVar "j") (EVar "e")) (EVar "False") (EIf (EApp (EVar "isLayoutTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "toks"))) (EApp (EApp (EApp (EVar "nextSigIsPipe") (EVar "toks")) (EVar "e")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "toks")) (EVar "TPipe")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isLayoutTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLayoutTok" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "isLayoutTok" ((PCon "TIndent")) (EVar "True"))
(DFunDef false "isLayoutTok" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "isLayoutTok" (PWild) (EVar "False"))
(DTypeSig false "isOpenDelim" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isOpenDelim" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLBracketTight")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLArray")) (EVar "True"))
(DFunDef false "isOpenDelim" (PWild) (EVar "False"))
(DTypeSig false "isCloseDelim" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isCloseDelim" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "isCloseDelim" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "isCloseDelim" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "isCloseDelim" ((PCon "TRArray")) (EVar "True"))
(DFunDef false "isCloseDelim" (PWild) (EVar "False"))
(DTypeSig false "isDataDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isDataDecl" ((PCon "DData" PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isDataDecl" (PWild) (EVar "False"))
(DTypeSig false "allVariantLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "allVariantLines" ((PVar "toks") (PVar "lines") (PList)) (EListLit))
(DFunDef false "allVariantLines" ((PVar "toks") (PVar "lines") (PCons (PTuple (PVar "d") (PVar "s") (PVar "e")) (PVar "rest"))) (EIf (EApp (EVar "isDataDecl") (EVar "d")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "variantStartsIn") (EVar "toks")) (EVar "lines")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EVar "allVariantLines") (EVar "toks")) (EVar "lines")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "allVariantLines") (EVar "toks")) (EVar "lines")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isContinuationOpStr" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isContinuationOpStr" ((PVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "|>"))) (EBinOp "==" (EVar "op") (ELit (LString ">>")))) (EBinOp "==" (EVar "op") (ELit (LString "<<")))) (EBinOp "==" (EVar "op") (ELit (LString "&&")))) (EBinOp "==" (EVar "op") (ELit (LString "||")))) (EBinOp "==" (EVar "op") (ELit (LString "++")))))
(DTypeSig false "chainOpTokEq" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyCon "Bool"))))
(DFunDef false "chainOpTokEq" ((PLit (LString "&&")) (PCon "TAnd")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "||")) (PCon "TOr")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "|>")) (PCon "TPipeRight")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString ">>")) (PCon "TRCompose")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "<<")) (PCon "TLCompose")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "++")) (PCon "TPlusPlus")) (EVar "True"))
(DFunDef false "chainOpTokEq" (PWild PWild) (EVar "False"))
(DTypeSig false "declChainTopOp" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "declChainTopOp" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declChainTopOp") (EVar "inner")))
(DFunDef false "declChainTopOp" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "bodyChainTopOp") (EVar "body")))
(DFunDef false "declChainTopOp" (PWild) (EVar "None"))
(DTypeSig false "bodyChainTopOp" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "bodyChainTopOp" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "bodyChainTopOp") (EVar "e")))
(DFunDef false "bodyChainTopOp" ((PCon "EBinOp" (PVar "op") PWild PWild PWild)) (EIf (EApp (EVar "isContinuationOpStr") (EVar "op")) (EApp (EVar "Some") (EVar "op")) (EVar "None")))
(DFunDef false "bodyChainTopOp" (PWild) (EVar "None"))
(DTypeSig false "firstContentAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstContentAt" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "e") (EIf (EApp (EVar "isNoiseTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "rhsStartIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "rhsStartIdx" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "e") (EIf (EApp (EVar "isOpenDelim") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isCloseDelim") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")) (EVar "TEqual"))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "chainOperandLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "chainOperandLines" ((PVar "toks") (PVar "lines") (PVar "op") (PVar "rs") (PVar "e")) (EBlock (DoLet false false (PVar "h") (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EVar "rs")) (EVar "e"))) (DoExpr (EIf (EBinOp ">=" (EVar "h") (EVar "e")) (EListLit) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EVar "h")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EVar "rs")) (EVar "e")) (ELit (LInt 0))))))))
(DTypeSig false "chainOpLinesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "chainOpLinesGo" ((PVar "toks") (PVar "lines") (PVar "op") (PVar "i") (PVar "e") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesAt") (EVar "toks")) (EVar "lines")) (EVar "op")) (EVar "i")) (EVar "e")) (EVar "depth")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "chainOpLinesAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "chainOpLinesAt" ((PVar "toks") (PVar "lines") (PVar "op") (PVar "i") (PVar "e") (PVar "depth") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EApp (EVar "chainOpTokEq") (EVar "op")) (EVar "t"))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "declBlockRhs" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "declBlockRhs" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declBlockRhs") (EVar "inner")))
(DFunDef false "declBlockRhs" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "bodyIsBlock") (EVar "body")))
(DFunDef false "declBlockRhs" (PWild) (EVar "False"))
(DTypeSig false "bodyIsBlock" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "bodyIsBlock" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "bodyIsBlock") (EVar "e")))
(DFunDef false "bodyIsBlock" ((PCon "EBlock" PWild)) (EVar "True"))
(DFunDef false "bodyIsBlock" ((PCon "EDo" PWild)) (EVar "True"))
(DFunDef false "bodyIsBlock" (PWild) (EVar "False"))
(DTypeSig false "firstIndentIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstIndentIdx" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "e") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")) (EVar "TIndent")) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstIndentIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "blockStmtLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "blockStmtLines" ((PVar "toks") (PVar "lines") (PVar "rs") (PVar "e")) (EBlock (DoLet false false (PVar "bi") (EApp (EApp (EApp (EVar "firstIndentIdx") (EVar "toks")) (EVar "rs")) (EVar "e"))) (DoExpr (EIf (EBinOp ">=" (EVar "bi") (EVar "e")) (EListLit) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EVar "bi")) (EVar "e")) (ELit (LInt 1))) (EVar "True"))))))
(DTypeSig false "blockStmtGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "blockStmtGo" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "ind") (PVar "atStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EBinOp "<=" (EVar "ind") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtAt") (EVar "toks")) (EVar "lines")) (EVar "i")) (EVar "e")) (EVar "ind")) (EVar "atStart")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "blockStmtAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "blockStmtAt" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "ind") (PVar "atStart") (PVar "t")) (EIf (EBinOp "==" (EVar "t") (EVar "TIndent")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "ind") (ELit (LInt 1)))) (EVar "False")) (EIf (EBinOp "==" (EVar "t") (EVar "TDedent")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "ind") (ELit (LInt 1)))) (EVar "False")) (EIf (EBinOp "==" (EVar "t") (EVar "TNewline")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "ind")) (EBinOp "==" (EVar "ind") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EVar "atStart") (EBinOp "==" (EVar "ind") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EVar "i")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "ind")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "ind")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "declChainLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "declChainLines" ((PVar "toks") (PVar "lines") (PVar "d") (PVar "s") (PVar "e")) (EMatch (EApp (EVar "declChainTopOp") (EVar "d")) (arm (PCon "Some" (PVar "op")) () (EApp (EApp (EApp (EApp (EApp (EVar "chainOperandLines") (EVar "toks")) (EVar "lines")) (EVar "op")) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EVar "s")) (EVar "e")) (ELit (LInt 0)))) (EVar "e"))) (arm (PCon "None") () (EIf (EApp (EVar "declBlockRhs") (EVar "d")) (EApp (EApp (EApp (EApp (EVar "blockStmtLines") (EVar "toks")) (EVar "lines")) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EVar "s")) (EVar "e")) (ELit (LInt 0)))) (EVar "e")) (EListLit)))))
(DTypeSig false "allChainLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "allChainLines" ((PVar "toks") (PVar "lines") (PList)) (EListLit))
(DFunDef false "allChainLines" ((PVar "toks") (PVar "lines") (PCons (PTuple (PVar "d") (PVar "s") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "declChainLines") (EVar "toks")) (EVar "lines")) (EVar "d")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EVar "allChainLines") (EVar "toks")) (EVar "lines")) (EVar "rest"))))
(DTypeSig false "lastContentLineOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyCon "Int")))))
(DFunDef false "lastContentLineOf" ((PVar "toks") (PVar "lines") (PVar "spans")) (EApp (EApp (EApp (EApp (EVar "lastContentLineGo") (EVar "toks")) (EVar "lines")) (EVar "spans")) (ELit (LInt 0))))
(DTypeSig false "lastContentLineGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "lastContentLineGo" ((PVar "toks") (PVar "lines") (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lastContentLineGo" ((PVar "toks") (PVar "lines") (PCons (PTuple PWild (PVar "s") (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "lastContentLineGo") (EVar "toks")) (EVar "lines")) (EVar "rest")) (EApp (EApp (EVar "lineAt") (EVar "lines")) (EApp (EApp (EApp (EVar "lastContentIdx") (EVar "toks")) (EVar "s")) (EBinOp "-" (EVar "e") (ELit (LInt 1)))))))
(DTypeSig true "parseWithPositions" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))))
(DFunDef false "parseWithPositions" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "Some" (PVar "r")) () (EVar "r")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "parse error"))))))
(DTypeSig true "parseWithPositionsLocated" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))))
(DFunDef false "parseWithPositionsLocated" ((PVar "src")) (EApp (EVar "parseWithPositions") (EVar "src")))
(DTypeSig true "parseWithPositionsOpt" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")))))
(DFunDef false "parseWithPositionsOpt" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithLines") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "lineList")) () (EBlock (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EVar "tokList"))) (DoLet false false (PVar "lines") (EApp (EVar "arrayFromList") (EVar "lineList"))) (DoExpr (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple PWild (PVar "offPairList")) () (EBlock (DoLet false false (PVar "offs") (EApp (EVar "arrayFromList") (EVar "offPairList"))) (DoLet false false (PVar "nameLineStarts") (EApp (EVar "lineStartsOf") (EVar "src"))) (DoLet false false PWild (EApp (EApp (EVar "setLocState") (EVar "src")) (EVar "offs"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "runP") (EVar "programWithSpans")) (EVar "toks")) (ELit (LInt 0))) (arm (PCon "PErr" PWild PWild) () (EVar "None")) (arm (PCon "PFatal" PWild PWild) () (EVar "None")) (arm (PCon "POk" (PVar "spans") (PVar "pos")) () (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos")) (EVar "TEof")) (EBlock (DoLet false false (PVar "decls") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "d") (PVar "_s") (PVar "_e"))) (EVar "d"))) (EVar "spans"))) (DoLet false false (PVar "dps") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "declPosOf") (EVar "toks")) (EVar "lines")) (EVar "offs")) (EVar "nameLineStarts"))) (EVar "spans"))) (DoLet false false (PVar "vls") (EApp (EApp (EApp (EVar "allVariantLines") (EVar "toks")) (EVar "lines")) (EVar "spans"))) (DoLet false false (PVar "lcl") (EApp (EApp (EApp (EVar "lastContentLineOf") (EVar "toks")) (EVar "lines")) (EVar "spans"))) (DoLet false false (PVar "cls") (EApp (EApp (EApp (EVar "allChainLines") (EVar "toks")) (EVar "lines")) (EVar "spans"))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "decls") (EApp (EApp (EApp (EApp (EVar "Positions") (EVar "dps")) (EVar "vls")) (EVar "lcl")) (EVar "cls")))))) (EVar "None")))))))))))))
(DTypeSig false "resultDecls" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "PR") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "resultDecls" (PWild (PCon "PErr" PWild PWild)) (EApp (EVar "panic") (ELit (LString "parse error"))))
(DFunDef false "resultDecls" (PWild (PCon "PFatal" PWild PWild)) (EApp (EVar "panic") (ELit (LString "parse error"))))
(DFunDef false "resultDecls" ((PVar "toks") (PCon "POk" (PVar "ds") (PVar "pos"))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos")) (EVar "TEof")) (EVar "ds") (EIf (EVar "otherwise") (EApp (EVar "panic") (ELit (LString "parse error"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "parse" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parse" ((PVar "src")) (EBlock (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EApp (EVar "tokenize") (EVar "src")))) (DoExpr (EMatch (EApp (EApp (EVar "firstLexError") (EVar "toks")) (ELit (LInt 0))) (arm (PCon "Some" (PTuple PWild (PVar "msg"))) () (EApp (EVar "panic") (EVar "msg"))) (arm (PCon "None") () (EApp (EApp (EVar "resultDecls") (EVar "toks")) (EApp (EApp (EApp (EVar "runP") (EVar "parseProgram")) (EVar "toks")) (ELit (LInt 0)))))))))
(DTypeSig true "parseLocated" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parseLocated" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "offPairs")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "setLocState") (EVar "src")) (EApp (EVar "arrayFromList") (EVar "offPairs")))) (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EVar "tokList"))) (DoExpr (EApp (EApp (EVar "resultDecls") (EVar "toks")) (EApp (EApp (EApp (EVar "runP") (EVar "parseProgram")) (EVar "toks")) (ELit (LInt 0)))))))))
(DData Public "ParseError" () ((variant "ParseError" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "String")))) ())
(DTypeSig true "parseErrorLine" (TyFun (TyCon "ParseError") (TyCon "Int")))
(DFunDef false "parseErrorLine" ((PCon "ParseError" (PVar "l") PWild PWild)) (EVar "l"))
(DTypeSig true "parseErrorCol" (TyFun (TyCon "ParseError") (TyCon "Int")))
(DFunDef false "parseErrorCol" ((PCon "ParseError" PWild (PVar "c") PWild)) (EVar "c"))
(DTypeSig true "parseErrorMessage" (TyFun (TyCon "ParseError") (TyCon "String")))
(DFunDef false "parseErrorMessage" ((PCon "ParseError" PWild PWild (PVar "m"))) (EVar "m"))
(DTypeSig false "offsetAt" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offsetAt" ((PVar "offs") (PVar "srcLen") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs")) (EIf (EVar "otherwise") (EVar "srcLen") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "locateOffset" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "locateOffset" ((PVar "toks") (PVar "offs") (PVar "srcLen") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "srcLen") (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos")) (EVar "TEof")) (EVar "srcLen") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "offsetAt") (EVar "offs")) (EVar "srcLen")) (EVar "pos")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "resultDeclsResult" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "PR") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "resultDeclsResult" ((PVar "src") (PVar "toks") (PVar "offs") (PVar "srcLen") (PCon "PErr" (PVar "msg") (PVar "pos"))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "msg")) (EVar "pos"))))
(DFunDef false "resultDeclsResult" ((PVar "src") (PVar "toks") (PVar "offs") (PVar "srcLen") (PCon "PFatal" (PVar "msg") (PVar "pos"))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "msg")) (EVar "pos"))))
(DFunDef false "resultDeclsResult" ((PVar "src") (PVar "toks") (PVar "offs") (PVar "srcLen") (PCon "POk" (PVar "ds") (PVar "pos"))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos")) (EVar "TEof")) (EApp (EVar "Ok") (EVar "ds")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "deepenLeftover") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "pos"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "deepenLeftover" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "ParseError")))))))
(DFunDef false "deepenLeftover" ((PVar "src") (PVar "toks") (PVar "offs") (PVar "srcLen") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runP") (EVar "parseDecl")) (EVar "toks")) (EVar "pos")) (arm (PCon "PFatal" (PVar "msg2") (PVar "pos2")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "msg2")) (EVar "pos2"))) (arm (PCon "PErr" (PVar "msg2") (PVar "pos2")) ((GBool (EBinOp ">" (EVar "pos2") (EVar "pos")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "msg2")) (EVar "pos2"))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EApp (EApp (EApp (EApp (EApp (EVar "unexpectedLeftoverMsg") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "pos"))) (EVar "pos")))))
(DTypeSig false "mkLocated" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "ParseError"))))))))
(DFunDef false "mkLocated" ((PVar "src") (PVar "toks") (PVar "offs") (PVar "srcLen") (PVar "msg") (PVar "pos")) (EMatch (EApp (EApp (EVar "offsetToLineCol") (EVar "src")) (EApp (EApp (EApp (EApp (EVar "locateOffset") (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "pos"))) (arm (PTuple (PVar "line") (PVar "col")) () (EApp (EApp (EApp (EVar "ParseError") (EVar "line")) (EVar "col")) (EVar "msg")))))
(DTypeSig false "leadingIndentAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "leadingIndentAt" ((PVar "src") (PVar "offset")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "lineStart") (EApp (EApp (EVar "leadingIndentLineStart") (EVar "chars")) (EBinOp "-" (EVar "offset") (ELit (LInt 1))))) (DoExpr (EIf (EApp (EApp (EApp (EVar "leadingIndentAllBlank") (EVar "chars")) (EVar "lineStart")) (EVar "offset")) (EApp (EVar "Some") (EBinOp "-" (EVar "offset") (EVar "lineStart"))) (EVar "None")))))
(DTypeSig false "leadingIndentLineStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "leadingIndentLineStart" ((PVar "chars") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar "\n"))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EApp (EVar "leadingIndentLineStart") (EVar "chars")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "leadingIndentAllBlank" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "leadingIndentAllBlank" ((PVar "chars") (PVar "i") (PVar "limit")) (EIf (EBinOp ">=" (EVar "i") (EVar "limit")) (EVar "True") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (arm (PLit (LChar " ")) () (EApp (EApp (EApp (EVar "leadingIndentAllBlank") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "limit"))) (arm (PLit (LChar "\t")) () (EApp (EApp (EApp (EVar "leadingIndentAllBlank") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "limit"))) (arm PWild () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "unexpectedLeftoverMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))))
(DFunDef false "unexpectedLeftoverMsg" ((PVar "src") (PVar "toks") (PVar "offs") (PVar "srcLen") (PVar "pos")) (EBlock (DoLet false false (PVar "base") (EBinOp "++" (ELit (LString "unexpected ")) (EApp (EVar "describeToken") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))))) (DoLet false false (PVar "offset") (EApp (EApp (EApp (EApp (EVar "locateOffset") (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "pos"))) (DoExpr (EMatch (EApp (EApp (EVar "leadingIndentAt") (EVar "src")) (EVar "offset")) (arm (PCon "Some" (PVar "col")) ((GBool (EBinOp ">" (EVar "col") (ELit (LInt 0))))) (EApp (EApp (EApp (EVar "leadingIndentMsg") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EVar "base")) (EVar "col"))) (arm PWild () (EVar "base"))))))
(DTypeSig false "leadingIndentMsg" (TyFun (TyCon "Token") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "leadingIndentMsg" ((PCon "TArrow") (PVar "base") (PVar "col")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "base"))) (ELit (LString ". A line can't start with `->` — it's not a supported continuation at any indentation; put `->` at the end of the previous line instead (e.g. `f : Int ->` then an indented `Int`)"))))
(DFunDef false "leadingIndentMsg" (PWild (PVar "base") (PVar "col")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "base"))) (ELit (LString ". Indentation (column "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ") doesn't match the enclosing block"))))
(DTypeSig false "firstLexError" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "String"))))))
(DFunDef false "firstLexError" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (arm (PCon "TLexError" (PVar "msg")) () (EApp (EVar "Some") (ETuple (EVar "i") (EVar "msg")))) (arm PWild () (EApp (EApp (EVar "firstLexError") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "firstSlashEqIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstSlashEqIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TSlashEq")) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EVar "firstSlashEqIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstMutIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstMutIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TMut")) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EVar "firstMutIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstRecordIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstRecordIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TRecord")) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EVar "firstRecordIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstFunctionIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstFunctionIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TFunction")) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EVar "firstFunctionIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "scanForLetIn" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "scanForLetIn" ((PVar "toks") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TIn")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "True") (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TIndent")) (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TDedent")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TDedent")) (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TEof")) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "firstInlineLetMissingIn" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstInlineLetMissingIn" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TElse")) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TThen"))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "TLet"))) (EIf (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (ELit (LInt 0))) (EApp (EApp (EVar "firstInlineLetMissingIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EVar "firstInlineLetMissingIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "inlineLetMissingInMsg" (TyCon "String"))
(DFunDef false "inlineLetMissingInMsg" () (ELit (LString "inline 'let' requires 'in': 'else let x = e in body'. For a multi-statement body, put 'else' on its own line and indent")))
(DTypeSig false "caseHasOfBeforeBoundary" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "caseHasOfBeforeBoundary" ((PVar "toks") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TOf")) (EVar "True") (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TImpl")) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TIndent")) (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TDedent")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TDedent")) (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TEof")) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "firstHsCaseOfIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstHsCaseOfIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EApp (EVar "TIdent") (ELit (LString "case")))) (EIf (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0))) (EVar "i") (EApp (EApp (EVar "firstHsCaseOfIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "firstHsCaseOfIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "hsCaseOfMsg" (TyCon "String"))
(DFunDef false "hsCaseOfMsg" () (ELit (LString "Medaka has no 'case … of'. Use 'match e' with indented 'pattern => body' arms")))
(DTypeSig false "firstBacktickIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstBacktickIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (arm (PCon "TBacktickIdent" PWild) () (EVar "i")) (arm PWild () (EApp (EApp (EVar "firstBacktickIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "backtickInfixMsg" (TyCon "String"))
(DFunDef false "backtickInfixMsg" () (ELit (LString "backtick infix application (`f`) is not supported — use prefix application `f x y`")))
(DTypeSig false "firstWithIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstWithIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TWith")) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EVar "firstWithIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "letRecWithRemovedMsg" (TyCon "String"))
(DFunDef false "letRecWithRemovedMsg" () (ELit (LString "`let rec … with` (mutual-recursion grouping) has been removed — define each binding as a separate `let rec`")))
(DTypeSig false "isPlainIdentTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isPlainIdentTok" ((PCon "TIdent" PWild)) (EVar "True"))
(DFunDef false "isPlainIdentTok" (PWild) (EVar "False"))
(DTypeSig false "firstHsSigIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Int"))))))
(DFunDef false "firstHsSigIdx" ((PVar "toks") (PVar "i") (PVar "depth") (PVar "boundary")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "boundary") (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "isPlainIdentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "TCons"))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TIndent")) (EApp (EApp (EApp (EApp (EVar "firstHsSigIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TDedent")) (EApp (EApp (EApp (EApp (EVar "firstHsSigIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EBinOp "==" (EBinOp "-" (EVar "depth") (ELit (LInt 1))) (ELit (LInt 0)))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TNewline")) (EApp (EApp (EApp (EApp (EVar "firstHsSigIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "firstHsSigIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "hsSigMsg" (TyCon "String"))
(DFunDef false "hsSigMsg" () (ELit (LString "Use '::' for List cons. A type signature uses a single colon: 'f : T'")))
(DTypeSig false "isBracketOpenTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isBracketOpenTok" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "isBracketOpenTok" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "isBracketOpenTok" ((PCon "TLBracketTight")) (EVar "True"))
(DFunDef false "isBracketOpenTok" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "isBracketOpenTok" (PWild) (EVar "False"))
(DTypeSig false "isBracketCloseTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isBracketCloseTok" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "isBracketCloseTok" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "isBracketCloseTok" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "isBracketCloseTok" (PWild) (EVar "False"))
(DTypeSig false "firstBlockCommentIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstBlockCommentIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TSlash")) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "TStar"))) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EVar "firstBlockCommentIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "blockCommentMsg" (TyCon "String"))
(DFunDef false "blockCommentMsg" () (ELit (LString "Medaka has no '/* … */' block comments. Use '{- … -}' (block) or '--' (line)")))
(DTypeSig false "braceBlockFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "braceBlockFrom" ((PVar "toks") (PVar "i") (PVar "depth") (PVar "cand")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EIf (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EVar "cand") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TThen")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TElse")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "cand") (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TNewline")) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TEof"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "cand") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TLBrace")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EBinOp "<" (EVar "cand") (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "i")) (EIf (EApp (EVar "isBracketOpenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "cand")) (EIf (EApp (EVar "isBracketCloseTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "cand")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "cand")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "firstBraceBlockIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstBraceBlockIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TIf")) (EIf (EBinOp ">=" (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EVar "firstBraceBlockIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "firstBraceBlockIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "braceBlockMsg" (TyCon "String"))
(DFunDef false "braceBlockMsg" () (ELit (LString "unexpected '{'. Medaka has no brace blocks; use 'then'/'else' with indentation, not '{ … }'")))
(DTypeSig false "isForeignKwTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "for")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "while")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "def")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "elif")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "class")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "try")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "except")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "finally")))) (EVar "True"))
(DFunDef false "isForeignKwTok" (PWild) (EVar "False"))
(DTypeSig false "lineTrailingColonNoEq" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool")))))))
(DFunDef false "lineTrailingColonNoEq" ((PVar "toks") (PVar "i") (PVar "depth") (PVar "lastColon") (PVar "sawEq")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "&&" (EVar "lastColon") (EApp (EVar "not") (EVar "sawEq"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TNewline")) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TEof"))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TIndent"))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TDedent")))) (EBinOp "&&" (EVar "lastColon") (EApp (EVar "not") (EVar "sawEq"))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TEqual")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EVar "True")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TColon")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "True")) (EVar "sawEq")) (EIf (EApp (EVar "isBracketOpenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EVar "sawEq")) (EIf (EApp (EVar "isBracketCloseTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EVar "sawEq")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EVar "sawEq")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "firstForeignKwIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Int")))))
(DFunDef false "firstForeignKwIdx" ((PVar "toks") (PVar "i") (PVar "lineStart")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "&&" (EVar "lineStart") (EApp (EVar "isForeignKwTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EVar "i")) (ELit (LInt 0))) (EVar "False")) (EVar "False"))) (EVar "i") (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TNewline")) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TIndent"))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TDedent"))) (EApp (EApp (EApp (EVar "firstForeignKwIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "True")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstForeignKwIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "foreignKwMsg" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "foreignKwMsg" ((PCon "TIdent" (PLit (LString "def")))) (ELit (LString "Medaka has no 'def'. Define a function as 'f x = …'")))
(DFunDef false "foreignKwMsg" ((PCon "TIdent" (PLit (LString "while")))) (ELit (LString "Medaka has no 'while' loops. Use recursion or list functions")))
(DFunDef false "foreignKwMsg" ((PCon "TIdent" (PLit (LString "elif")))) (ELit (LString "Medaka has no 'elif'. Chain conditions with 'else if', or use function guards")))
(DFunDef false "foreignKwMsg" ((PCon "TIdent" (PLit (LString "class")))) (ELit (LString "Medaka has no 'class'. Define a type with 'data'/'record', or an interface with 'interface'")))
(DFunDef false "foreignKwMsg" ((PCon "TIdent" (PLit (LString "try")))) (ELit (LString "Medaka has no 'try'/exceptions. Return errors as values with 'Result'/'Option'")))
(DFunDef false "foreignKwMsg" ((PCon "TIdent" (PLit (LString "except")))) (ELit (LString "Medaka has no 'except'/exceptions. Handle errors as values with 'Result'/'Option'")))
(DFunDef false "foreignKwMsg" ((PCon "TIdent" (PLit (LString "finally")))) (ELit (LString "Medaka has no 'finally'/exceptions. Errors are values ('Result'/'Option'), not caught")))
(DFunDef false "foreignKwMsg" (PWild) (ELit (LString "Medaka has no 'for' loops. Use recursion or list functions like 'map'/'forEach'/'fold'")))
(DTypeSig false "semicolonMsg" (TyCon "String"))
(DFunDef false "semicolonMsg" () (ELit (LString "Medaka has no statement terminator ';'. Separate statements with newlines")))
(DTypeSig true "parseResult" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "parseResult" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsets") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "offList")) () (EApp (EApp (EApp (EVar "parseResultWith") (EVar "src")) (EVar "tokList")) (EVar "offList")))))
(DTypeSig true "parseLocatedResult" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "parseLocatedResult" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "offPairs")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "setLocState") (EVar "src")) (EApp (EVar "arrayFromList") (EVar "offPairs")))) (DoExpr (EApp (EApp (EApp (EVar "parseResultWith") (EVar "src")) (EVar "tokList")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "offPairs"))))))))
(DTypeSig false "parseResultWith" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "parseResultWith" ((PVar "src") (PVar "tokList") (PVar "offList")) (EBlock (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EVar "tokList"))) (DoLet false false (PVar "offs") (EApp (EVar "arrayFromList") (EVar "offList"))) (DoLet false false (PVar "srcLen") (EApp (EVar "stringLength") (EVar "src"))) (DoLet false false (PVar "seIdx") (EApp (EApp (EVar "firstSlashEqIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "lmIdx") (EApp (EApp (EVar "firstMutIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "recIdx") (EApp (EApp (EVar "firstRecordIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "fnIdx") (EApp (EApp (EVar "firstFunctionIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "ilIdx") (EApp (EApp (EVar "firstInlineLetMissingIn") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "coIdx") (EApp (EApp (EVar "firstHsCaseOfIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "btIdx") (EApp (EApp (EVar "firstBacktickIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "wiIdx") (EApp (EApp (EVar "firstWithIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "sigIdx") (EApp (EApp (EApp (EApp (EVar "firstHsSigIdx") (EVar "toks")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "True"))) (DoLet false false (PVar "bcIdx") (EApp (EApp (EVar "firstBlockCommentIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "bbIdx") (EApp (EApp (EVar "firstBraceBlockIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "fkwIdx") (EApp (EApp (EApp (EVar "firstForeignKwIdx") (EVar "toks")) (ELit (LInt 0))) (EVar "True"))) (DoExpr (EMatch (EApp (EApp (EVar "firstLexError") (EVar "toks")) (ELit (LInt 0))) (arm (PCon "Some" (PTuple (PVar "leIdx") (PVar "leMsg"))) () (EBlock (DoLet false false (PVar "leMsg2") (EIf (EBinOp "==" (EVar "leMsg") (ELit (LString "unexpected character ';'"))) (EVar "semicolonMsg") (EVar "leMsg"))) (DoExpr (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "leMsg2")) (EVar "leIdx")))))) (arm (PCon "None") () (EIf (EBinOp ">=" (EVar "seIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (ELit (LString "unexpected '/='. (Did you mean '!='?)"))) (EVar "seIdx"))) (EIf (EBinOp ">=" (EVar "lmIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "letMutRemovedMsg")) (EVar "lmIdx"))) (EIf (EBinOp ">=" (EVar "recIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "recordRemovedMsg")) (EVar "recIdx"))) (EIf (EBinOp ">=" (EVar "fnIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "functionRemovedMsg")) (EVar "fnIdx"))) (EIf (EBinOp ">=" (EVar "ilIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "inlineLetMissingInMsg")) (EVar "ilIdx"))) (EIf (EBinOp ">=" (EVar "coIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "hsCaseOfMsg")) (EVar "coIdx"))) (EIf (EBinOp ">=" (EVar "btIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "backtickInfixMsg")) (EVar "btIdx"))) (EIf (EBinOp ">=" (EVar "wiIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "letRecWithRemovedMsg")) (EVar "wiIdx"))) (EIf (EBinOp ">=" (EVar "sigIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "hsSigMsg")) (EVar "sigIdx"))) (EIf (EBinOp ">=" (EVar "bcIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "blockCommentMsg")) (EVar "bcIdx"))) (EIf (EBinOp ">=" (EVar "bbIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "braceBlockMsg")) (EVar "bbIdx"))) (EIf (EBinOp ">=" (EVar "fkwIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EApp (EVar "foreignKwMsg") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "fkwIdx")))) (EVar "fkwIdx"))) (EApp (EApp (EApp (EApp (EApp (EVar "resultDeclsResult") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EApp (EApp (EApp (EVar "runP") (EVar "parseProgram")) (EVar "toks")) (ELit (LInt 0)))))))))))))))))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "DeriveRef" true) (mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "Loc" true) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberOrigin" false) (mem "useMemberAlias" false) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true) (mem "Attr" true) (mem "Route" true))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "tokenize" false) (mem "tokenizeWithLines" false) (mem "tokenizeWithOffsets" false) (mem "tokenizeWithOffsetPairs" false) (mem "offsetToLineCol" false) (mem "lineStartsOf" false) (mem "offsetToLineColFast" false) (mem "describeToken" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinWith" false))))
(DUse false (UseGroup ("support" "char") ((mem "isUpper" false))))
(DData Public "PR" ("a") ((variant "POk" (ConPos (TyVar "a") (TyCon "Int"))) (variant "PErr" (ConPos (TyCon "String") (TyCon "Int"))) (variant "PFatal" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DData Public "Parser" ("a") ((variant "Parser" (ConPos (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyVar "a"))))))) ())
(DTypeSig false "runP" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyVar "a"))))))
(DFunDef false "runP" ((PCon "Parser" (PVar "f")) (PVar "toks") (PVar "pos")) (EApp (EApp (EVar "f") (EVar "toks")) (EVar "pos")))
(DTypeSig false "mapPR" (TyFun (TyFun (TyVar "a") (TyVar "b")) (TyFun (TyApp (TyCon "PR") (TyVar "a")) (TyApp (TyCon "PR") (TyVar "b")))))
(DFunDef false "mapPR" ((PVar "f") (PCon "POk" (PVar "a") (PVar "pos"))) (EApp (EApp (EVar "POk") (EApp (EVar "f") (EVar "a"))) (EVar "pos")))
(DFunDef false "mapPR" (PWild (PCon "PErr" (PVar "e") (PVar "pos"))) (EApp (EApp (EVar "PErr") (EVar "e")) (EVar "pos")))
(DFunDef false "mapPR" (PWild (PCon "PFatal" (PVar "e") (PVar "pos"))) (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "pos")))
(DImpl false "Mappable" ((TyCon "Parser")) () ((im "map" ((PVar "f") (PVar "pa")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "mapPR") (EVar "f")) (EApp (EApp (EApp (EVar "runP") (EVar "pa")) (EVar "toks")) (EVar "pos"))))))))
(DTypeSig false "apPR" (TyFun (TyApp (TyCon "Parser") (TyFun (TyVar "a") (TyVar "b"))) (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyVar "b")))))))
(DFunDef false "apPR" ((PVar "pf") (PVar "pa") (PVar "toks") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runP") (EVar "pf")) (EVar "toks")) (EVar "pos")) (arm (PCon "POk" (PVar "f") (PVar "pos1")) () (EApp (EApp (EVar "mapPR") (EVar "f")) (EApp (EApp (EApp (EVar "runP") (EVar "pa")) (EVar "toks")) (EVar "pos1")))) (arm (PCon "PErr" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PErr") (EVar "e")) (EVar "pos1"))) (arm (PCon "PFatal" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "pos1")))))
(DImpl false "Applicative" ((TyCon "Parser")) () ((im "pure" ((PVar "x")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "POk") (EVar "x")) (EVar "pos"))))) (im "ap" ((PVar "pf") (PVar "pa")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "apPR") (EVar "pf")) (EVar "pa")) (EVar "toks")) (EVar "pos")))))))
(DTypeSig false "bindPR" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyFun (TyVar "a") (TyApp (TyCon "Parser") (TyVar "b"))) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyVar "b")))))))
(DFunDef false "bindPR" ((PVar "pa") (PVar "k") (PVar "toks") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runP") (EVar "pa")) (EVar "toks")) (EVar "pos")) (arm (PCon "POk" (PVar "a") (PVar "pos1")) () (EApp (EApp (EApp (EVar "runP") (EApp (EVar "k") (EVar "a"))) (EVar "toks")) (EVar "pos1"))) (arm (PCon "PErr" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PErr") (EVar "e")) (EVar "pos1"))) (arm (PCon "PFatal" (PVar "e") (PVar "pos1")) () (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "pos1")))))
(DImpl false "Thenable" ((TyCon "Parser")) () ((im "andThen" ((PVar "pa") (PVar "k")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "bindPR") (EVar "pa")) (EVar "k")) (EVar "toks")) (EVar "pos")))))))
(DTypeSig false "peekTok" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Token"))))
(DFunDef false "peekTok" ((PVar "toks") (PVar "pos")) (EIf (EBinOp "<" (EVar "pos") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EVar "toks")) (EIf (EVar "otherwise") (EVar "TEof") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "failP" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyVar "a"))))
(DFunDef false "failP" ((PVar "msg")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "PErr") (EVar "msg")) (EVar "pos")))))
(DTypeSig false "fatalP" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyVar "a"))))
(DFunDef false "fatalP" ((PVar "msg")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "PFatal") (EVar "msg")) (EVar "pos")))))
(DTypeSig false "fatalAtP" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyVar "a")))))
(DFunDef false "fatalAtP" ((PVar "msg") (PVar "pos0")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "_pos")) (EApp (EApp (EVar "PFatal") (EVar "msg")) (EVar "pos0")))))
(DTypeSig false "peekP" (TyApp (TyCon "Parser") (TyCon "Token")))
(DFunDef false "peekP" () (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "POk") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EVar "pos")))))
(DTypeSig false "peek2P" (TyApp (TyCon "Parser") (TyCon "Token")))
(DFunDef false "peek2P" () (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "POk") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))) (EVar "pos")))))
(DTypeSig false "getPos" (TyApp (TyCon "Parser") (TyCon "Int")))
(DFunDef false "getPos" () (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "POk") (EVar "pos")) (EVar "pos")))))
(DTypeSig false "locSrcRef" (TyApp (TyCon "Ref") (TyCon "String")))
(DFunDef false "locSrcRef" () (EApp (EVar "Ref") (ELit (LString ""))))
(DTypeSig false "locOffsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "locOffsRef" () (EApp (EVar "Ref") (EApp (EVar "arrayFromList") (EListLit))))
(DTypeSig false "locLineStartsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "locLineStartsRef" () (EApp (EVar "Ref") (EApp (EVar "arrayFromList") (EListLit (ELit (LInt 0))))))
(DTypeSig false "setLocState" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "Unit"))))
(DFunDef false "setLocState" ((PVar "src") (PVar "offs")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "locSrcRef")) (EVar "src"))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "locLineStartsRef")) (EApp (EVar "lineStartsOf") (EVar "src")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "locOffsRef")) (EVar "offs")))))
(DTypeSig false "tokOffsetAt" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "tokOffsetAt" ((PVar "i")) (EBlock (DoLet false false (PVar "offs") (EFieldAccess (EVar "locOffsRef") "value")) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs")))) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs"))) (ELit (LInt 0))))))
(DTypeSig false "tokEndOffsetAt" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "tokEndOffsetAt" ((PVar "i")) (EBlock (DoLet false false (PVar "offs") (EFieldAccess (EVar "locOffsRef") "value")) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs")))) (EApp (EVar "snd") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs"))) (ELit (LInt 0))))))
(DTypeSig false "locOfSpan" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Loc"))))
(DFunDef false "locOfSpan" ((PVar "startIdx") (PVar "endIdx")) (EBlock (DoLet false false (PVar "lineStarts") (EFieldAccess (EVar "locLineStartsRef") "value")) (DoLet false false (PVar "lastIdx") (EIf (EBinOp ">" (EVar "endIdx") (EVar "startIdx")) (EBinOp "-" (EVar "endIdx") (ELit (LInt 1))) (EVar "startIdx"))) (DoExpr (EMatch (EApp (EApp (EVar "offsetToLineColFast") (EVar "lineStarts")) (EApp (EVar "tokOffsetAt") (EVar "startIdx"))) (arm (PTuple (PVar "sl") (PVar "sc")) () (EMatch (EApp (EApp (EVar "offsetToLineColFast") (EVar "lineStarts")) (EApp (EVar "tokEndOffsetAt") (EVar "lastIdx"))) (arm (PTuple (PVar "el") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))))))))
(DTypeSig false "located" (TyFun (TyApp (TyCon "Parser") (TyCon "Expr")) (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "located" ((PVar "p")) (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "andThen") (EVar "p")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "ELoc") (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "q"))) (EVar "e"))))))))))
(DTypeSig false "advance" (TyApp (TyCon "Parser") (TyCon "Token")))
(DFunDef false "advance" () (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EVar "advanceR") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EVar "pos")))))
(DTypeSig false "advanceR" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyCon "Token")))))
(DFunDef false "advanceR" ((PCon "TEof") (PVar "pos")) (EApp (EApp (EVar "PErr") (ELit (LString "unexpected end of input"))) (EVar "pos")))
(DFunDef false "advanceR" ((PVar "t") (PVar "pos")) (EApp (EApp (EVar "POk") (EVar "t")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))))
(DTypeSig false "emit" (TyFun (TyVar "a") (TyApp (TyCon "Parser") (TyVar "a"))))
(DFunDef false "emit" ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EVar "x")))))
(DTypeSig false "expectTok" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "expectTok" ((PVar "t")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "x")) (EApp (EApp (EVar "expectGo") (EVar "t")) (EVar "x")))))
(DTypeSig false "expectGo" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit")))))
(DFunDef false "expectGo" ((PVar "t") (PVar "x")) (EIf (EBinOp "==" (EVar "x") (EVar "t")) (EApp (EVar "emit") (ELit LUnit)) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "unexpected ")) (EApp (EMethodRef "display") (EApp (EVar "describeToken") (EVar "x")))) (ELit (LString "; expected "))) (EApp (EMethodRef "display") (EApp (EVar "describeToken") (EVar "t")))) (ELit (LString ""))))))
(DTypeSig false "identNameP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "identNameP" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "identNameFor") (EVar "t")))))
(DTypeSig false "identNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "identNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "identNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected identifier"))))
(DTypeSig false "orElse#shadow" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyApp (TyCon "Parser") (TyVar "a")))))
(DFunDef false "orElse#shadow" ((PVar "pa") (PVar "pb")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "orElseR") (EVar "pa")) (EVar "pb")) (EVar "toks")) (EVar "pos")))))
(DTypeSig false "orElseR" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyVar "a")))))))
(DFunDef false "orElseR" ((PVar "pa") (PVar "pb") (PVar "toks") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runP") (EVar "pa")) (EVar "toks")) (EVar "pos")) (arm (PCon "POk" (PVar "x") (PVar "q")) () (EApp (EApp (EVar "POk") (EVar "x")) (EVar "q"))) (arm (PCon "PFatal" (PVar "ea") (PVar "qa")) () (EApp (EApp (EVar "PFatal") (EVar "ea")) (EVar "qa"))) (arm (PCon "PErr" (PVar "ea") (PVar "qa")) () (EApp (EApp (EApp (EVar "orElseRb") (EVar "ea")) (EVar "qa")) (EApp (EApp (EApp (EVar "runP") (EVar "pb")) (EVar "toks")) (EVar "pos"))))))
(DTypeSig false "orElseRb" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "PR") (TyVar "a")) (TyApp (TyCon "PR") (TyVar "a"))))))
(DFunDef false "orElseRb" (PWild PWild (PCon "POk" (PVar "y") (PVar "q"))) (EApp (EApp (EVar "POk") (EVar "y")) (EVar "q")))
(DFunDef false "orElseRb" (PWild PWild (PCon "PFatal" (PVar "eb") (PVar "qb"))) (EApp (EApp (EVar "PFatal") (EVar "eb")) (EVar "qb")))
(DFunDef false "orElseRb" ((PVar "ea") (PVar "qa") (PCon "PErr" (PVar "eb") (PVar "qb"))) (EIf (EBinOp ">" (EVar "qa") (EVar "qb")) (EApp (EApp (EVar "PErr") (EVar "ea")) (EVar "qa")) (EIf (EVar "otherwise") (EApp (EApp (EVar "PErr") (EVar "eb")) (EVar "qb")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "choice" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Parser") (TyVar "a"))) (TyApp (TyCon "Parser") (TyVar "a"))))
(DFunDef false "choice" ((PList)) (EApp (EVar "failP") (ELit (LString "no alternative"))))
(DFunDef false "choice" ((PCons (PVar "p") (PVar "ps"))) (EApp (EApp (EVar "orElse#shadow") (EVar "p")) (EApp (EVar "choice") (EVar "ps"))))
(DTypeSig false "many" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "many" ((PVar "p")) (EApp (EVar "Parser") (ELam ((PVar "toks") (PVar "pos")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "toks")) (EVar "pos")) (EListLit)))))
(DTypeSig false "manyGo" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "PR") (TyApp (TyCon "List") (TyVar "a"))))))))
(DFunDef false "manyGo" ((PVar "p") (PVar "toks") (PVar "pos") (PVar "acc")) (EMatch (EApp (EApp (EApp (EVar "runP") (EVar "p")) (EVar "toks")) (EVar "pos")) (arm (PCon "POk" (PVar "x") (PVar "pos2")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "manyStep") (EVar "p")) (EVar "toks")) (EVar "pos")) (EVar "pos2")) (EVar "acc")) (EVar "x"))) (arm (PCon "PFatal" (PVar "e") (PVar "q")) () (EApp (EApp (EVar "PFatal") (EVar "e")) (EVar "q"))) (arm (PCon "PErr" PWild PWild) () (EApp (EApp (EVar "POk") (EApp (EVar "reverseL") (EVar "acc"))) (EVar "pos")))))
(DTypeSig false "manyStep" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyVar "a") (TyApp (TyCon "PR") (TyApp (TyCon "List") (TyVar "a"))))))))))
(DFunDef false "manyStep" ((PVar "p") (PVar "toks") (PVar "pos") (PVar "pos2") (PVar "acc") (PVar "x")) (EIf (EBinOp ">" (EVar "pos2") (EVar "pos")) (EApp (EApp (EApp (EApp (EVar "manyGo") (EVar "p")) (EVar "toks")) (EVar "pos2")) (EBinOp "::" (EVar "x") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "POk") (EApp (EVar "reverseL") (EBinOp "::" (EVar "x") (EVar "acc")))) (EVar "pos2")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sepThen" (TyFun (TyApp (TyCon "Parser") (TyVar "b")) (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyApp (TyCon "Parser") (TyVar "a")))))
(DFunDef false "sepThen" ((PVar "sep") (PVar "p")) (EApp (EApp (EMethodRef "andThen") (EVar "sep")) (ELam (PWild) (EVar "p"))))
(DTypeSig false "sepBy1" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Parser") (TyVar "b")) (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "sepBy1" ((PVar "p") (PVar "sep")) (EApp (EApp (EMethodRef "andThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EApp (EApp (EVar "sepThen") (EVar "sep")) (EVar "p")))) (ELam ((PVar "xs")) (EApp (EMethodRef "pure") (EBinOp "::" (EVar "x") (EVar "xs"))))))))
(DTypeSig false "optTrailingComma" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "optTrailingComma" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "optTrailingCommaFor") (EVar "t")))))
(DTypeSig false "optTrailingCommaFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "optTrailingCommaFor" ((PCon "TComma")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (ELit LUnit)))))
(DFunDef false "optTrailingCommaFor" (PWild) (EApp (EMethodRef "pure") (ELit LUnit)))
(DTypeSig false "optTrailingCommaTuple" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "optTrailingCommaTuple" ((PList PWild)) (EApp (EMethodRef "pure") (ELit LUnit)))
(DFunDef false "optTrailingCommaTuple" (PWild) (EVar "optTrailingComma"))
(DTypeSig false "chainl1" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Parser") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))) (TyApp (TyCon "Parser") (TyVar "a")))))
(DFunDef false "chainl1" ((PVar "p") (PVar "op")) (EApp (EApp (EMethodRef "andThen") (EVar "p")) (ELam ((PVar "x")) (EApp (EApp (EApp (EVar "chainl1Rest") (EVar "p")) (EVar "op")) (EVar "x")))))
(DTypeSig false "chainl1Rest" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Parser") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))) (TyFun (TyVar "a") (TyApp (TyCon "Parser") (TyVar "a"))))))
(DFunDef false "chainl1Rest" ((PVar "p") (PVar "op") (PVar "x")) (EApp (EApp (EVar "orElse#shadow") (EApp (EApp (EApp (EVar "chainl1More") (EVar "p")) (EVar "op")) (EVar "x"))) (EApp (EMethodRef "pure") (EVar "x"))))
(DTypeSig false "chainl1More" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyFun (TyApp (TyCon "Parser") (TyFun (TyVar "a") (TyFun (TyVar "a") (TyVar "a")))) (TyFun (TyVar "a") (TyApp (TyCon "Parser") (TyVar "a"))))))
(DFunDef false "chainl1More" ((PVar "p") (PVar "op") (PVar "x")) (EApp (EApp (EMethodRef "andThen") (EVar "op")) (ELam ((PVar "f")) (EApp (EApp (EMethodRef "andThen") (EVar "p")) (ELam ((PVar "y")) (EApp (EApp (EApp (EVar "chainl1Rest") (EVar "p")) (EVar "op")) (EApp (EApp (EVar "f") (EVar "x")) (EVar "y"))))))))
(DTypeSig false "skipNewlines" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "skipNewlines" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "skipNlFor") (EVar "t")))))
(DTypeSig false "skipNlFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "skipNlFor" ((PCon "TNewline")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EVar "skipNewlines"))))
(DFunDef false "skipNlFor" (PWild) (EApp (EMethodRef "pure") (ELit LUnit)))
(DTypeSig false "parseExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseExpr" () (EApp (EApp (EMethodRef "andThen") (EVar "parseAssign")) (ELam ((PVar "e")) (EApp (EApp (EVar "orElse#shadow") (EApp (EVar "annotTail") (EVar "e"))) (EApp (EMethodRef "pure") (EVar "e"))))))
(DTypeSig false "parseAssign" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAssign" () (EApp (EApp (EMethodRef "andThen") (EVar "parseLam")) (ELam ((PVar "e")) (EApp (EApp (EVar "orElse#shadow") (EApp (EVar "assignTail") (EVar "e"))) (EApp (EMethodRef "pure") (EVar "e"))))))
(DTypeSig false "assignTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "assignTail" ((PVar "lhs")) (EApp (EVar "located") (EApp (EVar "assignTailRaw") (EVar "lhs"))))
(DTypeSig false "assignTailRaw" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "assignTailRaw" ((PVar "lhs")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TColonEq"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseAssign")) (ELam ((PVar "rhs")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString ":="))) (EVar "lhs")) (EVar "rhs")) (EApp (EVar "Ref") (EVar "RNone")))))))))
(DTypeSig false "annotTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "annotTail" ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseTy")) (ELam ((PVar "t")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "EAnnot") (EVar "e")) (EVar "t"))))))))
(DTypeSig false "parseLam" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseLam" () (EApp (EApp (EMethodRef "andThen") (EVar "parsePipe")) (ELam ((PVar "e")) (EApp (EApp (EVar "orElse#shadow") (EApp (EVar "lamTail") (EVar "e"))) (EApp (EMethodRef "pure") (EVar "e"))))))
(DTypeSig false "parsePipe" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parsePipe" () (EApp (EApp (EVar "chainl1") (EVar "parseCompose")) (EApp (EApp (EVar "binOp") (EVar "TPipeRight")) (ELit (LString "|>")))))
(DTypeSig false "parseCompose" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseCompose" () (EApp (EApp (EVar "chainl1") (EVar "parseOr")) (EApp (EVar "choice") (EListLit (EApp (EApp (EVar "binOp") (EVar "TRCompose")) (ELit (LString ">>"))) (EApp (EApp (EVar "binOp") (EVar "TLCompose")) (ELit (LString "<<")))))))
(DTypeSig false "lamTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "lamTail" ((PVar "e")) (EApp (EVar "located") (EApp (EVar "lamTailRaw") (EVar "e"))))
(DTypeSig false "lamTailRaw" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "lamTailRaw" ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TFatArrow"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseRhsExpr")) (ELam ((PVar "body")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "ELam") (EApp (EVar "exprToParams") (EVar "e"))) (EVar "body"))))))))
(DTypeSig false "exprToParams" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "exprToParams" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "exprToParams") (EVar "e")))
(DFunDef false "exprToParams" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "appToParams") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))))
(DFunDef false "exprToParams" ((PVar "e")) (EListLit (EApp (EVar "exprToPat") (EVar "e"))))
(DTypeSig false "appToParams" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "appToParams" ((PVar "app")) (EApp (EApp (EVar "paramsForHead") (EApp (EVar "spineHead") (EVar "app"))) (EVar "app")))
(DTypeSig false "paramsForHead" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "paramsForHead" ((PCon "EVar" (PVar "c")) (PVar "app")) (EApp (EApp (EVar "paramsForCtor") (EVar "c")) (EVar "app")))
(DFunDef false "paramsForHead" (PWild (PVar "app")) (EApp (EApp (EMethodRef "map") (EVar "exprToPat")) (EApp (EVar "spineList") (EVar "app"))))
(DTypeSig false "paramsForCtor" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "paramsForCtor" ((PVar "c") (PVar "app")) (EIf (EApp (EVar "isCtorName") (EVar "c")) (EListLit (EApp (EVar "exprToPat") (EVar "app"))) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "map") (EVar "exprToPat")) (EApp (EVar "spineList") (EVar "app"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "spineHead" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "spineHead" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "spineHead") (EVar "f")))
(DFunDef false "spineHead" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "spineHead") (EVar "e")))
(DFunDef false "spineHead" ((PVar "e")) (EVar "e"))
(DTypeSig false "spineList" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "spineList" ((PVar "e")) (EApp (EApp (EVar "spineOnto") (EVar "e")) (EListLit)))
(DTypeSig false "spineOnto" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "spineOnto" ((PCon "ELoc" PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EVar "spineOnto") (EVar "e")) (EVar "acc")))
(DFunDef false "spineOnto" ((PCon "EApp" (PVar "f") (PVar "x")) (PVar "acc")) (EApp (EApp (EVar "spineOnto") (EVar "f")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DFunDef false "spineOnto" ((PVar "e") (PVar "acc")) (EBinOp "::" (EVar "e") (EVar "acc")))
(DTypeSig false "exprToPat" (TyFun (TyCon "Expr") (TyCon "Pat")))
(DFunDef false "exprToPat" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "exprToPat") (EVar "e")))
(DFunDef false "exprToPat" ((PCon "EVar" (PLit (LString "_")))) (EVar "PWild"))
(DFunDef false "exprToPat" ((PCon "EVar" (PVar "x"))) (EApp (EVar "ctorOrVar") (EVar "x")))
(DFunDef false "exprToPat" ((PCon "ELit" (PVar "l"))) (EApp (EVar "PLit") (EVar "l")))
(DFunDef false "exprToPat" ((PCon "ENumLit" (PVar "n") PWild PWild PWild)) (EApp (EVar "PLit") (EApp (EVar "LInt") (EVar "n"))))
(DFunDef false "exprToPat" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "PTuple") (EApp (EApp (EMethodRef "map") (EVar "exprToPat")) (EVar "es"))))
(DFunDef false "exprToPat" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "PList") (EApp (EApp (EMethodRef "map") (EVar "exprToPat")) (EVar "es"))))
(DFunDef false "exprToPat" ((PCon "EBinOp" (PLit (LString "::")) (PVar "a") (PVar "b") PWild)) (EApp (EApp (EVar "PCons") (EApp (EVar "exprToPat") (EVar "a"))) (EApp (EVar "exprToPat") (EVar "b"))))
(DFunDef false "exprToPat" ((PCon "ESection" (PCon "SecLeft" (PVar "a") (PLit (LString "::"))))) (EApp (EApp (EVar "PCons") (EApp (EVar "exprToPat") (EVar "a"))) (EVar "PWild")))
(DFunDef false "exprToPat" ((PCon "EAsPat" (PVar "x") (PVar "sub"))) (EApp (EApp (EVar "PAs") (EVar "x")) (EApp (EVar "exprToPat") (EMethodRef "sub"))))
(DFunDef false "exprToPat" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "appToPat") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))))
(DFunDef false "exprToPat" (PWild) (EVar "PWild"))
(DTypeSig false "ctorOrVar" (TyFun (TyCon "String") (TyCon "Pat")))
(DFunDef false "ctorOrVar" ((PVar "x")) (EIf (EApp (EVar "isCtorName") (EVar "x")) (EApp (EApp (EVar "PCon") (EVar "x")) (EListLit)) (EIf (EVar "otherwise") (EApp (EVar "PVar") (EVar "x")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "appToPat" (TyFun (TyCon "Expr") (TyCon "Pat")))
(DFunDef false "appToPat" ((PVar "app")) (EApp (EApp (EVar "appToPatH") (EApp (EVar "spineHead") (EVar "app"))) (EApp (EVar "spineList") (EVar "app"))))
(DTypeSig false "appToPatH" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Pat"))))
(DFunDef false "appToPatH" ((PCon "EVar" (PVar "c")) (PVar "spine")) (EApp (EApp (EVar "appToPatCtor") (EVar "c")) (EVar "spine")))
(DFunDef false "appToPatH" (PWild PWild) (EVar "PWild"))
(DTypeSig false "appToPatCtor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Pat"))))
(DFunDef false "appToPatCtor" ((PVar "c") (PVar "spine")) (EIf (EApp (EVar "isCtorName") (EVar "c")) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EMethodRef "map") (EVar "exprToPat")) (EApp (EVar "dropFirst") (EVar "spine")))) (EIf (EVar "otherwise") (EVar "PWild") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dropFirst" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "dropFirst" ((PList)) (EListLit))
(DFunDef false "dropFirst" ((PCons PWild (PVar "xs"))) (EVar "xs"))
(DTypeSig false "isCtorName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isCtorName" ((PVar "s")) (EApp (EVar "isCtorChars") (EApp (EVar "stringToChars") (EVar "s"))))
(DTypeSig false "isCtorChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Bool")))
(DFunDef false "isCtorChars" ((PVar "cs")) (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EVar "False") (EIf (EVar "otherwise") (EApp (EVar "isUpper") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "stripLoc" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripLoc" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stripLoc") (EVar "e")))
(DFunDef false "stripLoc" ((PVar "e")) (EVar "e"))
(DTypeSig false "binOp" (TyFun (TyCon "Token") (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "binOp" ((PVar "tk") (PVar "op")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "tk"))) (ELam (PWild) (EApp (EMethodRef "pure") (ELam ((PVar "l") (PVar "r")) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EApp (EVar "Ref") (EVar "RNone"))))))))
(DTypeSig false "parseOr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseOr" () (EApp (EApp (EVar "chainl1") (EVar "parseAnd")) (EApp (EApp (EVar "binOp") (EVar "TOr")) (ELit (LString "||")))))
(DTypeSig false "parseAnd" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAnd" () (EApp (EApp (EVar "chainl1") (EVar "parseCmp")) (EApp (EApp (EVar "binOp") (EVar "TAnd")) (ELit (LString "&&")))))
(DTypeSig false "parseCmp" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseCmp" () (EApp (EApp (EVar "chainl1") (EVar "parseCons")) (EVar "cmpOp")))
(DTypeSig false "cmpOp" (TyApp (TyCon "Parser") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "cmpOp" () (EApp (EVar "choice") (EListLit (EApp (EApp (EVar "binOp") (EVar "TEqEq")) (ELit (LString "=="))) (EApp (EApp (EVar "binOp") (EVar "TNeq")) (ELit (LString "!="))) (EApp (EApp (EVar "binOp") (EVar "TLt")) (ELit (LString "<"))) (EApp (EApp (EVar "binOp") (EVar "TGt")) (ELit (LString ">"))) (EApp (EApp (EVar "binOp") (EVar "TLeq")) (ELit (LString "<="))) (EApp (EApp (EVar "binOp") (EVar "TGeq")) (ELit (LString ">="))))))
(DTypeSig false "parseCons" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseCons" () (EApp (EApp (EMethodRef "andThen") (EVar "parseAppend")) (ELam ((PVar "x")) (EApp (EApp (EVar "orElse#shadow") (EApp (EVar "consTail") (EVar "x"))) (EApp (EMethodRef "pure") (EVar "x"))))))
(DTypeSig false "consTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "consTail" ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TCons"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseCons")) (ELam ((PVar "y")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "::"))) (EVar "x")) (EVar "y")) (EApp (EVar "Ref") (EVar "RNone")))))))))
(DTypeSig false "parseAppend" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAppend" () (EApp (EApp (EVar "chainl1") (EVar "parseAdd")) (EApp (EApp (EVar "binOp") (EVar "TPlusPlus")) (ELit (LString "++")))))
(DTypeSig false "parseAdd" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAdd" () (EApp (EApp (EVar "chainl1") (EVar "parseMul")) (EApp (EVar "choice") (EListLit (EApp (EApp (EVar "binOp") (EVar "TPlus")) (ELit (LString "+"))) (EApp (EApp (EVar "binOp") (EVar "TMinus")) (ELit (LString "-"))) (EApp (EApp (EVar "binOp") (EVar "TMinusTight")) (ELit (LString "-")))))))
(DTypeSig false "parseMul" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseMul" () (EApp (EApp (EVar "chainl1") (EVar "parseUnary")) (EApp (EVar "choice") (EListLit (EApp (EApp (EVar "binOp") (EVar "TStar")) (ELit (LString "*"))) (EApp (EApp (EVar "binOp") (EVar "TSlash")) (ELit (LString "/"))) (EApp (EApp (EVar "binOp") (EVar "TMod")) (ELit (LString "%")))))))
(DTypeSig false "intMinLit" (TyCon "Int"))
(DFunDef false "intMinLit" () (EBinOp "-" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 4611686018427387903))) (ELit (LInt 1))))
(DTypeSig false "isIntMinLit" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isIntMinLit" ((PVar "n")) (EBinOp "==" (EVar "n") (EVar "intMinLit")))
(DTypeSig false "intLitTooBigMsg" (TyCon "String"))
(DFunDef false "intLitTooBigMsg" () (ELit (LString "integer literal too large for Int (max 4611686018427387903)")))
(DTypeSig false "parseUnary" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseUnary" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "unaryFor") (EVar "t")))))
(DTypeSig false "unaryFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "unaryFor" ((PCon "TMinus")) (EVar "negUnary"))
(DFunDef false "unaryFor" ((PCon "TMinusTight")) (EVar "negUnary"))
(DFunDef false "unaryFor" ((PCon "TBang")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseUnary")) (ELam ((PVar "e")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "EUnOp") (ELit (LString "!"))) (EVar "e")) (EApp (EVar "Ref") (EVar "RNone")))))))))
(DFunDef false "unaryFor" (PWild) (EVar "parseInfix"))
(DTypeSig false "negUnary" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "negUnary" () (EApp (EApp (EMethodRef "andThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EVar "negUnaryFor") (EVar "t2")))))
(DTypeSig false "negUnaryFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "negUnaryFor" ((PCon "TInt" (PVar "n") (PVar "lx"))) (EIf (EApp (EVar "isIntMinLit") (EVar "n")) (EApp (EVar "located") (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EApp (EVar "Ref") (EVar "None"))) (EApp (EVar "Ref") (EVar "RNone"))) (EBinOp "++" (ELit (LString "-")) (EVar "lx"))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "negUnaryFor" (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseUnary")) (ELam ((PVar "e")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "EUnOp") (ELit (LString "-"))) (EVar "e")) (EApp (EVar "Ref") (EVar "RNone")))))))))
(DTypeSig false "parseInfix" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseInfix" () (EVar "parseApp"))
(DTypeSig false "parseApp" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseApp" () (EApp (EApp (EMethodRef "andThen") (EVar "parseAspat")) (ELam ((PVar "head")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EApp (EVar "appArg") (EApp (EVar "headIsNumeric") (EVar "head"))))) (ELam ((PVar "args")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "applyAll") (EVar "head")) (EVar "args"))))))))
(DTypeSig false "appArg" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "appArg" ((PVar "headNum")) (EApp (EApp (EVar "orElse#shadow") (EApp (EVar "negLitArg") (EVar "headNum"))) (EVar "parseAspat")))
(DTypeSig false "negLitArg" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "negLitArg" ((PCon "True")) (EApp (EVar "failP") (ELit (LString "numeric head: tight minus stays subtraction"))))
(DFunDef false "negLitArg" ((PCon "False")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "andThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EVar "negLitArgFor") (EVar "t")) (EVar "t2")))))))
(DTypeSig false "negLitArgFor" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "negLitArgFor" ((PCon "TMinusTight") (PCon "TInt" (PVar "n") (PVar "lx"))) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EVar "ENumLit") (EApp (EMethodRef "negate") (EVar "n"))) (EApp (EVar "Ref") (EVar "None"))) (EApp (EVar "Ref") (EVar "RNone"))) (EBinOp "++" (ELit (LString "-")) (EVar "lx")))))))))
(DFunDef false "negLitArgFor" ((PCon "TMinusTight") (PCon "TFloat" (PVar "f"))) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "ELit") (EApp (EVar "LFloat") (EApp (EMethodRef "negate") (EVar "f"))))))))))
(DFunDef false "negLitArgFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "not a tight negative literal argument"))))
(DTypeSig false "headIsNumeric" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "headIsNumeric" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "headIsNumeric") (EVar "e")))
(DFunDef false "headIsNumeric" ((PCon "ENumLit" PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "headIsNumeric" ((PCon "ELit" (PCon "LInt" PWild))) (EVar "True"))
(DFunDef false "headIsNumeric" ((PCon "ELit" (PCon "LFloat" PWild))) (EVar "True"))
(DFunDef false "headIsNumeric" (PWild) (EVar "False"))
(DTypeSig false "parseAspat" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAspat" () (EApp (EApp (EVar "orElse#shadow") (EVar "parseAspatAt")) (EVar "parsePostfix")))
(DTypeSig false "parseAspatAt" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAspatAt" () (EApp (EVar "located") (EVar "parseAspatAtRaw")))
(DTypeSig false "parseAspatAtRaw" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAspatAtRaw" () (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TAsAt"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parsePostfix")) (ELam ((PVar "sub")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "EAsPat") (EVar "x")) (EMethodRef "sub"))))))))))
(DTypeSig false "applyAll" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "applyAll" ((PVar "head") (PList)) (EVar "head"))
(DFunDef false "applyAll" ((PVar "head") (PCons (PVar "a") (PVar "rest"))) (EApp (EApp (EVar "applyAll") (EApp (EApp (EVar "EApp") (EVar "head")) (EVar "a"))) (EVar "rest")))
(DTypeSig false "parsePostfix" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parsePostfix" () (EApp (EApp (EMethodRef "andThen") (EVar "parseAtom")) (ELam ((PVar "e")) (EApp (EVar "postfixTail") (EVar "e")))))
(DTypeSig false "postfixTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "postfixTail" ((PVar "e")) (EApp (EApp (EVar "orElse#shadow") (EApp (EVar "bracketIndexTail") (EVar "e"))) (EApp (EApp (EVar "orElse#shadow") (EApp (EVar "dotTail") (EVar "e"))) (EApp (EMethodRef "pure") (EVar "e")))))
(DTypeSig false "bracketIndexTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "bracketIndexTail" ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLBracketTight"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "lo")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "bracketIndexRest") (EVar "e")) (EVar "lo")) (EVar "t")))))))))
(DTypeSig false "bracketIndexRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "bracketIndexRest" (PWild PWild (PCon "TDotDot")) (EApp (EVar "failP") (ELit (LString "bare slice `a[i..j]` is not yet supported — use `a.[i..j]`"))))
(DFunDef false "bracketIndexRest" (PWild PWild (PCon "TDotDotEq")) (EApp (EVar "failP") (ELit (LString "bare slice `a[i..=j]` is not yet supported — use `a.[i..=j]`"))))
(DFunDef false "bracketIndexRest" ((PVar "e") (PVar "lo") (PCon "TRBracket")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "postfixTail") (EApp (EApp (EApp (EVar "EIndex") (EVar "e")) (EVar "lo")) (EApp (EVar "Ref") (ELit (LString "Array"))))))))
(DFunDef false "bracketIndexRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected ']' in index expression"))))
(DTypeSig false "dotTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "dotTail" ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDot"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dotFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "dotFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "dotFor" ((PVar "e") (PCon "TLBracket")) (EApp (EVar "indexOrSlice") (EVar "e")))
(DFunDef false "dotFor" ((PVar "e") PWild) (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "f")) (EApp (EVar "postfixTail") (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "e")) (EVar "f")) (EApp (EVar "Ref") (ELit (LString ""))))))))
(DTypeSig false "indexOrSlice" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "indexOrSlice" ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLBracket"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "lo")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "indexOrSliceRest") (EVar "e")) (EVar "lo")) (EVar "t")))))))))
(DTypeSig false "indexOrSliceRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "indexOrSliceRest" ((PVar "e") (PVar "lo") (PCon "TDotDot")) (EApp (EApp (EApp (EVar "sliceHi") (EVar "e")) (EVar "lo")) (EVar "False")))
(DFunDef false "indexOrSliceRest" ((PVar "e") (PVar "lo") (PCon "TDotDotEq")) (EApp (EApp (EApp (EVar "sliceHi") (EVar "e")) (EVar "lo")) (EVar "True")))
(DFunDef false "indexOrSliceRest" ((PVar "e") (PVar "lo") (PCon "TRBracket")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "postfixTail") (EApp (EApp (EApp (EVar "EIndex") (EVar "e")) (EVar "lo")) (EApp (EVar "Ref") (ELit (LString "Array"))))))))
(DFunDef false "indexOrSliceRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected .. ..= or ] in index/slice"))))
(DTypeSig false "sliceHi" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "sliceHi" ((PVar "e") (PVar "lo") (PVar "incl")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "hi")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EVar "postfixTail") (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EVar "e")) (EVar "lo")) (EVar "hi")) (EVar "incl")) (EApp (EVar "Ref") (ELit (LString "Array"))))))))))))
(DTypeSig false "parseAtom" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAtom" () (EApp (EVar "located") (EVar "parseAtomRaw")))
(DTypeSig false "parseAtomRaw" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAtomRaw" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") PWild) ((GBool (EApp (EVar "isIntMinLit") (EVar "n")))) (EApp (EVar "fatalP") (EVar "intLitTooBigMsg"))) (arm (PCon "TInt" (PVar "n") (PVar "lx")) () (EApp (EVar "emit") (EApp (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EApp (EVar "Ref") (EVar "None"))) (EApp (EVar "Ref") (EVar "RNone"))) (EVar "lx")))) (arm (PCon "TFloat" (PVar "f")) () (EApp (EVar "emit") (EApp (EVar "ELit") (EApp (EVar "LFloat") (EVar "f"))))) (arm (PCon "TString" (PVar "s")) () (EApp (EVar "emit") (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "s"))))) (arm (PCon "TChar" (PVar "s")) () (EApp (EVar "emit") (EApp (EVar "ELit") (EApp (EVar "LChar") (EVar "s"))))) (arm (PCon "TIdent" (PVar "x")) () (EApp (EVar "emit") (EApp (EVar "EVar") (EVar "x")))) (arm (PCon "TUpper" (PVar "x")) () (EApp (EVar "parseUpperAtom") (EVar "x"))) (arm (PCon "TUnderscore") () (EApp (EVar "emit") (EApp (EVar "EVar") (ELit (LString "_"))))) (arm (PCon "TLParen") () (EVar "parseParen")) (arm (PCon "TLBracket") () (EVar "parseListE")) (arm (PCon "TLArray") () (EVar "parseArray")) (arm (PCon "TLBrace") () (EVar "parseRecordUpdate")) (arm (PCon "TIf") () (EVar "parseIf")) (arm (PCon "TLet") () (EVar "parseLet")) (arm (PCon "TMatch") () (EVar "parseMatch")) (arm (PCon "TDo") () (EVar "parseDo")) (arm (PCon "TInterpOpen" PWild) () (EVar "parseInterp")) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected atom"))))))))
(DTypeSig false "parseUpperAtom" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parseUpperAtom" ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "upperTail") (EVar "x")) (EVar "t")))))))
(DTypeSig false "upperTail" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "upperTail" ((PVar "x") (PCon "TLBrace")) (EApp (EVar "upperBrace") (EVar "x")))
(DFunDef false "upperTail" ((PVar "x") PWild) (EApp (EMethodRef "pure") (EApp (EVar "EVar") (EVar "x"))))
(DTypeSig false "upperBrace" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "upperBrace" ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EVar "orElse#shadow") (EApp (EVar "variantUpdateTail") (EVar "x"))) (EApp (EVar "braceItems") (EVar "x"))))))
(DTypeSig false "variantUpdateTail" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "variantUpdateTail" ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "recordFieldExpr")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "fields")) (EApp (EApp (EMethodRef "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "x")) (EVar "e")) (EApp (EApp (EMethodRef "map") (EApp (EVar "desugarDottedField") (EVar "e"))) (EVar "fields")))))))))))))))
(DData Private "KvItem" () ((variant "KvField" (ConPos (TyCon "String") (TyCon "Expr"))) (variant "KvKV" (ConPos (TyCon "Expr") (TyCon "Expr"))) (variant "KvElem" (ConPos (TyCon "Expr")))) ())
(DTypeSig false "braceItems" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "braceItems" ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "braceItemsFor") (EVar "x")) (EVar "t")))))
(DTypeSig false "braceItemsFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "braceItemsFor" ((PVar "x") (PCon "TRBrace")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EVar "classifyBrace") (EVar "x")) (EListLit))))))
(DFunDef false "braceItemsFor" ((PVar "x") PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parseKvOrE")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "items")) (EApp (EApp (EMethodRef "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EVar "classifyBrace") (EVar "x")) (EVar "items"))))))))))
(DTypeSig false "parseKvOrE" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvOrE" () (EApp (EApp (EVar "orElse#shadow") (EVar "parseKvField")) (EApp (EApp (EVar "orElse#shadow") (EVar "parseKvBlockElem")) (EVar "parseKvKVorElem"))))
(DTypeSig false "parseKvBlockElem" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvBlockElem" () (EApp (EApp (EMethodRef "andThen") (EVar "parseBracketBlock")) (ELam ((PVar "e")) (EApp (EMethodRef "pure") (EApp (EVar "KvElem") (EVar "e"))))))
(DTypeSig false "parseKvField" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvField" () (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseBracketElem")) (ELam ((PVar "e")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "KvField") (EVar "name")) (EVar "e"))))))))))
(DTypeSig false "parseKvKVorElem" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvKVorElem" () (EApp (EApp (EMethodRef "andThen") (EVar "parsePipe")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "kvKVorElemFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "kvKVorElemFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "KvItem")))))
(DFunDef false "kvKVorElemFor" ((PVar "e") (PCon "TFatArrow")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "v")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "KvKV") (EVar "e")) (EVar "v"))))))))
(DFunDef false "kvKVorElemFor" ((PVar "e") PWild) (EApp (EMethodRef "pure") (EApp (EVar "KvElem") (EVar "e"))))
(DTypeSig false "classifyBrace" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyCon "Expr"))))
(DFunDef false "classifyBrace" ((PVar "name") (PVar "items")) (EIf (EApp (EVar "anyField") (EVar "items")) (EApp (EApp (EVar "ERecordCreate") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "kvToField")) (EVar "items"))) (EIf (EApp (EVar "anyKV") (EVar "items")) (EApp (EApp (EVar "EMapLit") (EVar "name")) (EApp (EVar "kvPairs") (EVar "items"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ESetLit") (EVar "name")) (EApp (EVar "kvElems") (EVar "items"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "anyField" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyCon "Bool")))
(DFunDef false "anyField" ((PList)) (EVar "False"))
(DFunDef false "anyField" ((PCons (PCon "KvField" PWild PWild) PWild)) (EVar "True"))
(DFunDef false "anyField" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyField") (EVar "rest")))
(DTypeSig false "anyKV" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyCon "Bool")))
(DFunDef false "anyKV" ((PList)) (EVar "False"))
(DFunDef false "anyKV" ((PCons (PCon "KvKV" PWild PWild) PWild)) (EVar "True"))
(DFunDef false "anyKV" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyKV") (EVar "rest")))
(DTypeSig false "kvToField" (TyFun (TyCon "KvItem") (TyCon "FieldAssign")))
(DFunDef false "kvToField" ((PCon "KvField" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EVar "e")))
(DFunDef false "kvToField" ((PCon "KvElem" (PVar "e"))) (EApp (EVar "kvElemToField") (EApp (EVar "stripLoc") (EVar "e"))))
(DFunDef false "kvToField" (PWild) (EApp (EApp (EVar "FieldAssign") (ELit (LString "_"))) (EApp (EVar "ELit") (EVar "LUnit"))))
(DTypeSig false "kvElemToField" (TyFun (TyCon "Expr") (TyCon "FieldAssign")))
(DFunDef false "kvElemToField" ((PCon "EVar" (PVar "n"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "EVar") (EVar "n"))))
(DFunDef false "kvElemToField" (PWild) (EApp (EApp (EVar "FieldAssign") (ELit (LString "_"))) (EApp (EVar "ELit") (EVar "LUnit"))))
(DTypeSig false "kvPairs" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "kvPairs" ((PList)) (EListLit))
(DFunDef false "kvPairs" ((PCons (PCon "KvKV" (PVar "k") (PVar "v")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EVar "kvPairs") (EVar "rest"))))
(DFunDef false "kvPairs" ((PCons PWild (PVar "rest"))) (EApp (EVar "kvPairs") (EVar "rest")))
(DTypeSig false "kvElems" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "kvElems" ((PList)) (EListLit))
(DFunDef false "kvElems" ((PCons (PCon "KvElem" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EVar "e") (EApp (EVar "kvElems") (EVar "rest"))))
(DFunDef false "kvElems" ((PCons PWild (PVar "rest"))) (EApp (EVar "kvElems") (EVar "rest")))
(DTypeSig false "parseRecordUpdate" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseRecordUpdate" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "recordFieldExpr")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "fields")) (EApp (EApp (EMethodRef "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "e")) (EApp (EApp (EMethodRef "map") (EApp (EVar "desugarDottedField") (EVar "e"))) (EVar "fields"))) (EApp (EVar "Ref") (ELit (LString ""))))))))))))))))))
(DTypeSig false "recordFieldExpr" (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr"))))
(DFunDef false "recordFieldExpr" () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "identNameP")) (EApp (EVar "expectTok") (EVar "TDot")))) (ELam ((PVar "path")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "recordFieldExprRest") (EVar "path")) (EVar "t")))))))
(DTypeSig false "recordFieldExprRest" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr"))))))
(DFunDef false "recordFieldExprRest" ((PVar "path") (PCon "TEqual")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseBracketElem")) (ELam ((PVar "e")) (EApp (EMethodRef "pure") (ETuple (EVar "path") (EVar "e"))))))))
(DFunDef false "recordFieldExprRest" ((PList (PVar "x")) PWild) (EApp (EMethodRef "pure") (ETuple (EListLit (EVar "x")) (EApp (EVar "EVar") (EVar "x")))))
(DFunDef false "recordFieldExprRest" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected = in record-update field"))))
(DTypeSig false "desugarDottedField" (TyFun (TyCon "Expr") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr")) (TyCon "FieldAssign"))))
(DFunDef false "desugarDottedField" ((PVar "base") (PTuple (PVar "path") (PVar "value"))) (EMatch (EVar "path") (arm (PList (PVar "field")) () (EApp (EApp (EVar "FieldAssign") (EVar "field")) (EVar "value"))) (arm (PCons (PVar "field") (PVar "rest")) () (EApp (EApp (EVar "FieldAssign") (EVar "field")) (EApp (EApp (EApp (EVar "dottedGo") (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "base")) (EVar "field")) (EApp (EVar "Ref") (ELit (LString ""))))) (EVar "rest")) (EVar "value")))) (arm (PList) () (EApp (EApp (EVar "FieldAssign") (ELit (LString "_"))) (EVar "value")))))
(DTypeSig false "dottedGo" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "dottedGo" ((PVar "cur") (PList (PVar "f")) (PVar "value")) (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "cur")) (EListLit (EApp (EApp (EVar "FieldAssign") (EVar "f")) (EVar "value")))) (EApp (EVar "Ref") (ELit (LString "")))))
(DFunDef false "dottedGo" ((PVar "cur") (PCons (PVar "f") (PVar "fs")) (PVar "value")) (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "cur")) (EListLit (EApp (EApp (EVar "FieldAssign") (EVar "f")) (EApp (EApp (EApp (EVar "dottedGo") (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "cur")) (EVar "f")) (EApp (EVar "Ref") (ELit (LString ""))))) (EVar "fs")) (EVar "value"))))) (EApp (EVar "Ref") (ELit (LString "")))))
(DFunDef false "dottedGo" ((PVar "cur") (PList) (PVar "value")) (EVar "value"))
(DTypeSig false "parseInterp" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseInterp" () (EApp (EApp (EMethodRef "andThen") (EVar "interpOpenStr")) (ELam ((PVar "s0")) (EApp (EApp (EMethodRef "andThen") (EVar "interpRest")) (ELam ((PVar "rest")) (EApp (EMethodRef "pure") (EApp (EVar "EStringInterp") (EBinOp "::" (EApp (EVar "InterpStr") (EVar "s0")) (EVar "rest")))))))))
(DTypeSig false "interpOpenStr" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "interpOpenStr" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "interpOpenFor") (EVar "t")))))
(DTypeSig false "interpOpenFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "interpOpenFor" ((PCon "TInterpOpen" (PVar "s"))) (EApp (EVar "emit") (EVar "s")))
(DFunDef false "interpOpenFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected interpolation open"))))
(DTypeSig false "interpRest" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "InterpPart"))))
(DFunDef false "interpRest" () (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "interpRestFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "interpRestFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "InterpPart"))))))
(DFunDef false "interpRestFor" ((PVar "e") (PCon "TInterpMid" (PVar "s"))) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "interpRest")) (ELam ((PVar "rest")) (EApp (EMethodRef "pure") (EBinOp "::" (EApp (EVar "InterpExpr") (EVar "e")) (EBinOp "::" (EApp (EVar "InterpStr") (EVar "s")) (EVar "rest")))))))))
(DFunDef false "interpRestFor" ((PVar "e") (PCon "TInterpEnd" (PVar "s"))) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EListLit (EApp (EVar "InterpExpr") (EVar "e")) (EApp (EVar "InterpStr") (EVar "s")))))))
(DFunDef false "interpRestFor" ((PVar "e") PWild) (EApp (EVar "failP") (ELit (LString "expected interpolation mid/end"))))
(DTypeSig false "parseBracketBlock" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBracketBlock" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseStmts")) (ELam ((PVar "stmts")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "blockOrExpr") (EVar "stmts"))))))))))
(DTypeSig false "parseBracketElem" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBracketElem" () (EApp (EApp (EVar "orElse#shadow") (EVar "parseBracketBlock")) (EVar "parseExpr")))
(DTypeSig false "parseParen" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseParen" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "parenFor") (EVar "t")))))))
(DTypeSig false "parenFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parenFor" ((PCon "TRParen")) (EApp (EVar "emit") (EApp (EVar "ELit") (EVar "LUnit"))))
(DFunDef false "parenFor" ((PCon "TMinus")) (EApp (EApp (EVar "orElse#shadow") (EVar "bareMinusSection")) (EVar "parseParenExpr")))
(DFunDef false "parenFor" ((PCon "TMinusTight")) (EApp (EApp (EVar "orElse#shadow") (EVar "bareMinusSection")) (EVar "parseParenExpr")))
(DFunDef false "parenFor" ((PVar "t")) (EApp (EVar "parenSectionOr") (EVar "t")))
(DTypeSig false "parenSectionOr" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parenSectionOr" ((PVar "t")) (EMatch (EApp (EVar "sectionOpStr") (EVar "t")) (arm (PCon "Some" (PVar "op")) () (EApp (EVar "parseSectionOp") (EVar "op"))) (arm (PCon "None") () (EVar "parseParenExpr"))))
(DTypeSig false "bareMinusSection" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "bareMinusSection" () (EApp (EApp (EMethodRef "andThen") (EVar "expectMinus")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "ESection") (EApp (EVar "SecBare") (ELit (LString "-"))))))))))
(DTypeSig false "expectMinus" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "expectMinus" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "expectMinusGo") (EVar "t")))))
(DTypeSig false "expectMinusGo" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "expectMinusGo" ((PCon "TMinus")) (EApp (EVar "emit") (ELit LUnit)))
(DFunDef false "expectMinusGo" ((PCon "TMinusTight")) (EApp (EVar "emit") (ELit LUnit)))
(DFunDef false "expectMinusGo" (PWild) (EApp (EVar "failP") (ELit (LString "expected -"))))
(DTypeSig false "parseSectionOp" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parseSectionOp" ((PVar "op")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "sectionTail") (EVar "op")) (EVar "t")))))))
(DTypeSig false "sectionTail" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "sectionTail" ((PVar "op") (PCon "TRParen")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "ESection") (EApp (EVar "SecBare") (EVar "op")))))))
(DFunDef false "sectionTail" ((PVar "op") PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EVar "e")))))))))
(DTypeSig false "parseParenExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseParenExpr" () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parseBracketElem")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "es")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "optTrailingCommaTuple") (EVar "es"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "parenResult") (EVar "es"))))))))))
(DTypeSig false "parenResult" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr")))
(DFunDef false "parenResult" ((PList (PVar "e"))) (EApp (EVar "leftSectionOrExpr") (EVar "e")))
(DFunDef false "parenResult" ((PVar "es")) (EApp (EVar "ETuple") (EVar "es")))
(DTypeSig false "leftSectionOrExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "leftSectionOrExpr" ((PVar "e")) (EApp (EApp (EVar "leftSectionGo") (EVar "e")) (EApp (EVar "stripLoc") (EVar "e"))))
(DTypeSig false "leftSectionGo" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "leftSectionGo" ((PVar "orig") (PCon "EBinOp" (PVar "op") (PVar "lhs") (PVar "rhs") PWild)) (EApp (EApp (EApp (EApp (EVar "leftSectionRhs") (EVar "orig")) (EVar "op")) (EVar "lhs")) (EApp (EVar "stripLoc") (EVar "rhs"))))
(DFunDef false "leftSectionGo" ((PVar "orig") PWild) (EVar "orig"))
(DTypeSig false "leftSectionRhs" (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "leftSectionRhs" (PWild (PVar "op") (PVar "lhs") (PCon "EVar" (PLit (LString "_")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EVar "lhs")) (EVar "op"))))
(DFunDef false "leftSectionRhs" ((PVar "orig") PWild PWild PWild) (EVar "orig"))
(DTypeSig false "sectionOpStr" (TyFun (TyCon "Token") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "sectionOpStr" ((PCon "TPlus")) (EApp (EVar "Some") (ELit (LString "+"))))
(DFunDef false "sectionOpStr" ((PCon "TStar")) (EApp (EVar "Some") (ELit (LString "*"))))
(DFunDef false "sectionOpStr" ((PCon "TSlash")) (EApp (EVar "Some") (ELit (LString "/"))))
(DFunDef false "sectionOpStr" ((PCon "TEqEq")) (EApp (EVar "Some") (ELit (LString "=="))))
(DFunDef false "sectionOpStr" ((PCon "TNeq")) (EApp (EVar "Some") (ELit (LString "!="))))
(DFunDef false "sectionOpStr" ((PCon "TLt")) (EApp (EVar "Some") (ELit (LString "<"))))
(DFunDef false "sectionOpStr" ((PCon "TGt")) (EApp (EVar "Some") (ELit (LString ">"))))
(DFunDef false "sectionOpStr" ((PCon "TLeq")) (EApp (EVar "Some") (ELit (LString "<="))))
(DFunDef false "sectionOpStr" ((PCon "TGeq")) (EApp (EVar "Some") (ELit (LString ">="))))
(DFunDef false "sectionOpStr" ((PCon "TAnd")) (EApp (EVar "Some") (ELit (LString "&&"))))
(DFunDef false "sectionOpStr" ((PCon "TOr")) (EApp (EVar "Some") (ELit (LString "||"))))
(DFunDef false "sectionOpStr" ((PCon "TCons")) (EApp (EVar "Some") (ELit (LString "::"))))
(DFunDef false "sectionOpStr" ((PCon "TPlusPlus")) (EApp (EVar "Some") (ELit (LString "++"))))
(DFunDef false "sectionOpStr" ((PCon "TPipeRight")) (EApp (EVar "Some") (ELit (LString "|>"))))
(DFunDef false "sectionOpStr" ((PCon "TRCompose")) (EApp (EVar "Some") (ELit (LString ">>"))))
(DFunDef false "sectionOpStr" ((PCon "TLCompose")) (EApp (EVar "Some") (ELit (LString "<<"))))
(DFunDef false "sectionOpStr" (PWild) (EVar "None"))
(DTypeSig false "parseListE" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseListE" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLBracket"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "listFor") (EVar "t")))))))
(DTypeSig false "listFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "listFor" ((PCon "TRBracket")) (EApp (EVar "emit") (EApp (EVar "EListLit") (EListLit))))
(DFunDef false "listFor" (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseBracketElem")) (ELam ((PVar "first")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "listRest") (EVar "first")) (EVar "t")))))))
(DTypeSig false "listRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "listRest" ((PVar "first") (PCon "TDotDot")) (EApp (EApp (EVar "rangeAfter") (EVar "first")) (EVar "False")))
(DFunDef false "listRest" ((PVar "first") (PCon "TDotDotEq")) (EApp (EApp (EVar "rangeAfter") (EVar "first")) (EVar "True")))
(DFunDef false "listRest" ((PVar "first") (PCon "TComma")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "listAfterComma") (EVar "first")) (EVar "t")))))))
(DFunDef false "listRest" ((PVar "first") (PCon "TRBracket")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "EListLit") (EListLit (EVar "first")))))))
(DFunDef false "listRest" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected , .. ..= or ]"))))
(DTypeSig false "listAfterComma" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "listAfterComma" ((PVar "first") (PCon "TRBracket")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "EListLit") (EListLit (EVar "first")))))))
(DFunDef false "listAfterComma" ((PVar "first") PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parseBracketElem")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "rest")) (EApp (EApp (EMethodRef "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "EListLit") (EBinOp "::" (EVar "first") (EVar "rest")))))))))))
(DTypeSig false "rangeAfter" (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "rangeAfter" ((PVar "lo") (PVar "incl")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "hi")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "ERangeList") (EVar "lo")) (EVar "hi")) (EVar "incl"))))))))))
(DTypeSig false "parseArray" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseArray" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLArray"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "arrayFor") (EVar "t")))))))
(DTypeSig false "arrayFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "arrayFor" ((PCon "TRArray")) (EApp (EVar "emit") (EApp (EVar "EArrayLit") (EListLit))))
(DFunDef false "arrayFor" (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseBracketElem")) (ELam ((PVar "first")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "arrayRest") (EVar "first")) (EVar "t")))))))
(DTypeSig false "arrayRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TDotDot")) (EApp (EApp (EVar "arrayRangeAfter") (EVar "first")) (EVar "False")))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TDotDotEq")) (EApp (EApp (EVar "arrayRangeAfter") (EVar "first")) (EVar "True")))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TComma")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "arrayAfterComma") (EVar "first")) (EVar "t")))))))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TRArray")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "EArrayLit") (EListLit (EVar "first")))))))
(DFunDef false "arrayRest" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected , .. ..= or |]"))))
(DTypeSig false "arrayAfterComma" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "arrayAfterComma" ((PVar "first") (PCon "TRArray")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "EArrayLit") (EListLit (EVar "first")))))))
(DFunDef false "arrayAfterComma" ((PVar "first") PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parseBracketElem")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "rest")) (EApp (EApp (EMethodRef "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRArray"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "EArrayLit") (EBinOp "::" (EVar "first") (EVar "rest")))))))))))
(DTypeSig false "arrayRangeAfter" (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "arrayRangeAfter" ((PVar "lo") (PVar "incl")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "hi")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRArray"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "ERangeArray") (EVar "lo")) (EVar "hi")) (EVar "incl"))))))))))
(DTypeSig false "parseIf" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseIf" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TIf"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "ifKind") (EVar "t")))))))
(DTypeSig false "ifKind" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "ifKind" ((PCon "TLet")) (EVar "ifLet"))
(DFunDef false "ifKind" (PWild) (EVar "ifPlain"))
(DTypeSig false "ifLet" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "ifLet" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parsePat")) (ELam ((PVar "pat")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "scrut")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TThen"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "thenE")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TElse"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "elseE")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "EMatch") (EVar "scrut")) (EListLit (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EListLit)) (EVar "thenE")) (EApp (EApp (EApp (EVar "Arm") (EVar "PWild")) (EListLit)) (EVar "elseE"))))))))))))))))))))))
(DTypeSig false "ifPlain" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "ifPlain" () (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "cond")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TThen"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseBranch")) (ELam ((PVar "thenE")) (EApp (EApp (EMethodRef "andThen") (EVar "elseBranch")) (ELam ((PVar "elseE")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "EIf") (EVar "cond")) (EVar "thenE")) (EVar "elseE"))))))))))))
(DTypeSig false "elseBranch" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "elseBranch" () (EApp (EApp (EVar "orElse#shadow") (EVar "elsePresent")) (EApp (EMethodRef "pure") (EApp (EVar "ELit") (EVar "LUnit")))))
(DTypeSig false "elsePresent" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "elsePresent" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TElse"))) (ELam (PWild) (EVar "parseBranch"))))
(DTypeSig false "parseBranch" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBranch" () (EApp (EApp (EVar "orElse#shadow") (EVar "branchBlock")) (EVar "parseExpr")))
(DTypeSig false "branchBlock" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "branchBlock" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseStmts")) (ELam ((PVar "stmts")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "blockOrExpr") (EVar "stmts"))))))))))
(DTypeSig false "parseLet" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseLet" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "letExprKind") (EVar "t")))))))
(DTypeSig false "letExprKind" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "letExprKind" ((PCon "TMut")) (EApp (EVar "failP") (EVar "letMutRemovedMsg")))
(DFunDef false "letExprKind" ((PCon "TRec")) (EVar "letRecExpr"))
(DFunDef false "letExprKind" ((PCon "TIdent" (PVar "name"))) (EApp (EVar "letIdentExpr") (EVar "name")))
(DFunDef false "letExprKind" (PWild) (EVar "letPatExpr"))
(DTypeSig false "letMutRemovedMsg" (TyCon "String"))
(DFunDef false "letMutRemovedMsg" () (ELit (LString "`let mut` has been removed — bindings are immutable. For mutable state use a `Ref` cell: `let x = Ref 0`, write `x := newValue`, and read it with `x.value`")))
(DTypeSig false "recordRemovedMsg" (TyCon "String"))
(DFunDef false "recordRemovedMsg" () (ELit (LString "`record` is not a keyword — declare a record as `data X = { field : T, … }`")))
(DTypeSig false "functionRemovedMsg" (TyCon "String"))
(DFunDef false "functionRemovedMsg" () (ELit (LString "`function` is not a keyword — use `x => match x { … }` or a multi-clause definition")))
(DTypeSig false "letIdentExpr" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "letIdentExpr" ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "params")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "letIdentExprRest") (EVar "name")) (EVar "params")) (EVar "t")))))))))
(DTypeSig false "letIdentExprRest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "letIdentExprRest" ((PVar "name") (PList) (PCon "TColon")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "False")) (EVar "False")) (EApp (EVar "PVar") (EVar "name"))) (EApp (EApp (EVar "EAnnot") (EVar "e1")) (EVar "ty"))) (EVar "e2"))))))))))))))))
(DFunDef false "letIdentExprRest" ((PVar "name") (PList) (PCon "TEqual")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "False")) (EVar "False")) (EApp (EVar "PVar") (EVar "name"))) (EVar "e1")) (EVar "e2"))))))))))))
(DFunDef false "letIdentExprRest" ((PVar "name") (PVar "params") (PCon "TEqual")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "False")) (EVar "True")) (EApp (EVar "PVar") (EVar "name"))) (EApp (EApp (EVar "curryLam") (EVar "params")) (EVar "e1"))) (EVar "e2"))))))))))))
(DFunDef false "letIdentExprRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected : or = in let"))))
(DTypeSig false "letPatExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "letPatExpr" () (EApp (EApp (EMethodRef "andThen") (EVar "parsePat")) (ELam ((PVar "pat")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "False")) (EVar "False")) (EVar "pat")) (EVar "e1")) (EVar "e2"))))))))))))))
(DTypeSig false "letRecExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "letRecExpr" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRec"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "letRecInlineClause")) (ELam ((PVar "clause")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EListLit (EVar "clause")))) (EVar "e2"))))))))))))
(DTypeSig false "letRecInlineClause" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))
(DFunDef false "letRecInlineClause" () (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "body")) (EApp (EMethodRef "pure") (ETuple (EVar "name") (EVar "pats") (EVar "body"))))))))))))
(DTypeSig false "parseMatch" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseMatch" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TMatch"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "scrut")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseArms")) (ELam ((PVar "arms")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EVar "EMatch") (EVar "scrut")) (EVar "arms"))))))))))))))
(DTypeSig false "parseArms" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Arm"))))
(DFunDef false "parseArms" () (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "armsLoop"))))
(DTypeSig false "armsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Arm"))))
(DFunDef false "armsLoop" () (EApp (EApp (EVar "orElse#shadow") (EVar "armsCons")) (EApp (EMethodRef "pure") (EListLit))))
(DTypeSig false "armsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Arm"))))
(DFunDef false "armsCons" () (EApp (EApp (EMethodRef "andThen") (EVar "parseArm")) (ELam ((PVar "a")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "armsLoop")) (ELam ((PVar "rest")) (EApp (EMethodRef "pure") (EBinOp "::" (EVar "a") (EVar "rest"))))))))))
(DTypeSig false "parseArm" (TyApp (TyCon "Parser") (TyCon "Arm")))
(DFunDef false "parseArm" () (EApp (EApp (EMethodRef "andThen") (EVar "parsePat")) (ELam ((PVar "pat")) (EApp (EApp (EMethodRef "andThen") (EVar "armGuardOpt")) (ELam ((PVar "guards")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TFatArrow"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "orElse#shadow") (EVar "branchBlock")) (EVar "parseBodyExpr"))) (ELam ((PVar "body")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EVar "guards")) (EVar "body"))))))))))))
(DTypeSig false "armGuardOpt" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Guard"))))
(DFunDef false "armGuardOpt" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "armGuardFor") (EVar "t")))))
(DTypeSig false "armGuardFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Guard")))))
(DFunDef false "armGuardFor" ((PCon "TIf")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "sepBy1") (EVar "parseGuard")) (EApp (EVar "expectTok") (EVar "TComma"))))))
(DFunDef false "armGuardFor" (PWild) (EApp (EMethodRef "pure") (EListLit)))
(DTypeSig false "parsePat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePat" () (EVar "parsePatCons"))
(DTypeSig false "parseAsPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parseAsPat" () (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TAsAt"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parsePatApp")) (ELam ((PVar "sub")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "PAs") (EVar "x")) (EMethodRef "sub"))))))))))
(DTypeSig false "parsePatCons" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatCons" () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "orElse#shadow") (EVar "parseAsPat")) (EVar "parsePatApp"))) (ELam ((PVar "p")) (EApp (EApp (EVar "orElse#shadow") (EApp (EVar "patConsTail") (EVar "p"))) (EApp (EMethodRef "pure") (EVar "p"))))))
(DTypeSig false "patConsTail" (TyFun (TyCon "Pat") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patConsTail" ((PVar "p")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TCons"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parsePatCons")) (ELam ((PVar "q")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "PCons") (EVar "p")) (EVar "q"))))))))
(DTypeSig false "parsePatApp" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatApp" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "patAppFor") (EVar "t")))))
(DTypeSig false "patAppFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patAppFor" ((PCon "TUpper" (PVar "c"))) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "upperPatRest") (EVar "c")) (EVar "t")))))))
(DFunDef false "patAppFor" (PWild) (EVar "parsePatAtom"))
(DTypeSig false "upperPatRest" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat")))))
(DFunDef false "upperPatRest" ((PVar "c") (PCon "TLBrace")) (EApp (EVar "recordPat") (EVar "c")))
(DFunDef false "upperPatRest" ((PVar "c") PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "parsePatAtom"))) (ELam ((PVar "args")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "PCon") (EVar "c")) (EVar "args"))))))
(DTypeSig false "recordPat" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "recordPat" ((PVar "c")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "recordPatFields")) (ELam ((PVar "fr")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EVar "mkRec") (EVar "c")) (EVar "fr"))))))))))
(DTypeSig false "mkRec" (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")) (TyCon "Pat"))))
(DFunDef false "mkRec" ((PVar "c") (PTuple (PVar "fields") (PVar "rest"))) (EApp (EApp (EApp (EVar "PRec") (EVar "c")) (EVar "fields")) (EVar "rest")))
(DTypeSig false "recordPatFields" (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool"))))
(DFunDef false "recordPatFields" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "recordPatFieldsFor") (EVar "t")))))
(DTypeSig false "recordPatFieldsFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")))))
(DFunDef false "recordPatFieldsFor" ((PCon "TEllipsis")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (ETuple (EListLit) (EVar "True"))))))
(DFunDef false "recordPatFieldsFor" ((PCon "TRBrace")) (EApp (EMethodRef "pure") (ETuple (EListLit) (EVar "False"))))
(DFunDef false "recordPatFieldsFor" (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "recordPatField")) (ELam ((PVar "f")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "recordPatFieldsRest") (EVar "f")) (EVar "t")))))))
(DTypeSig false "recordPatFieldsRest" (TyFun (TyCon "RecPatField") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool"))))))
(DFunDef false "recordPatFieldsRest" ((PVar "f") (PCon "TComma")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "recordPatFields")) (ELam ((PVar "fr")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "consField") (EVar "f")) (EVar "fr"))))))))
(DFunDef false "recordPatFieldsRest" ((PVar "f") PWild) (EApp (EMethodRef "pure") (ETuple (EListLit (EVar "f")) (EVar "False"))))
(DTypeSig false "consField" (TyFun (TyCon "RecPatField") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")) (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")))))
(DFunDef false "consField" ((PVar "f") (PTuple (PVar "fs") (PVar "rest"))) (ETuple (EBinOp "::" (EVar "f") (EVar "fs")) (EVar "rest")))
(DTypeSig false "recordPatField" (TyApp (TyCon "Parser") (TyCon "RecPatField")))
(DFunDef false "recordPatField" () (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "recordPatFieldRest") (EVar "name")) (EVar "t")))))))
(DTypeSig false "recordPatFieldRest" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "RecPatField")))))
(DFunDef false "recordPatFieldRest" ((PVar "name") (PCon "TEqual")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parsePat")) (ELam ((PVar "p")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "RecPatField") (EVar "name")) (EApp (EVar "Some") (EVar "p")))))))))
(DFunDef false "recordPatFieldRest" ((PVar "name") PWild) (EApp (EMethodRef "pure") (EApp (EApp (EVar "RecPatField") (EVar "name")) (EVar "None"))))
(DTypeSig false "reservedIdentKeyword" (TyFun (TyCon "Token") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TWith")) (EApp (EVar "Some") (ELit (LString "with"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TMut")) (EApp (EVar "Some") (ELit (LString "mut"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TIn")) (EApp (EVar "Some") (ELit (LString "in"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TMatch")) (EApp (EVar "Some") (ELit (LString "match"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TData")) (EApp (EVar "Some") (ELit (LString "data"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TRecord")) (EApp (EVar "Some") (ELit (LString "record"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TInterface")) (EApp (EVar "Some") (ELit (LString "interface"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TDefault")) (EApp (EVar "Some") (ELit (LString "default"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TImpl")) (EApp (EVar "Some") (ELit (LString "impl"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TImport")) (EApp (EVar "Some") (ELit (LString "import"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TExport")) (EApp (EVar "Some") (ELit (LString "export"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TPublic")) (EApp (EVar "Some") (ELit (LString "public"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TWhere")) (EApp (EVar "Some") (ELit (LString "where"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TOf")) (EApp (EVar "Some") (ELit (LString "of"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TDo")) (EApp (EVar "Some") (ELit (LString "do"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TAs")) (EApp (EVar "Some") (ELit (LString "as"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TExtern")) (EApp (EVar "Some") (ELit (LString "extern"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TRequires")) (EApp (EVar "Some") (ELit (LString "requires"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TDeriving")) (EApp (EVar "Some") (ELit (LString "deriving"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TType")) (EApp (EVar "Some") (ELit (LString "type"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TNewtype")) (EApp (EVar "Some") (ELit (LString "newtype"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TProp")) (EApp (EVar "Some") (ELit (LString "prop"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TTest")) (EApp (EVar "Some") (ELit (LString "test"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TBench")) (EApp (EVar "Some") (ELit (LString "bench"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TEffect")) (EApp (EVar "Some") (ELit (LString "effect"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TFunction")) (EApp (EVar "Some") (ELit (LString "function"))))
(DFunDef false "reservedIdentKeyword" (PWild) (EVar "None"))
(DTypeSig false "reservedKeywordMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "reservedKeywordMsg" ((PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is a reserved keyword — it can't be used as a variable or pattern name. Rename it (e.g. `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "_`)."))))
(DTypeSig false "reservedOrPatFail" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "reservedOrPatFail" ((PVar "t")) (EMatch (EApp (EVar "reservedIdentKeyword") (EVar "t")) (arm (PCon "Some" (PVar "name")) () (EApp (EVar "fatalP") (EApp (EVar "reservedKeywordMsg") (EVar "name")))) (arm (PCon "None") () (EApp (EVar "failP") (ELit (LString "expected pattern"))))))
(DTypeSig false "parsePatAtom" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatAtom" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TIdent" (PVar "x")) () (EApp (EVar "emit") (EApp (EVar "PVar") (EVar "x")))) (arm (PCon "TUnderscore") () (EApp (EVar "emit") (EVar "PWild"))) (arm (PCon "TInt" (PVar "n") PWild) ((GBool (EApp (EVar "isIntMinLit") (EVar "n")))) (EApp (EVar "fatalP") (EVar "intLitTooBigMsg"))) (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "intPatRest") (EApp (EVar "LInt") (EVar "n")))) (arm (PCon "TMinus") () (EVar "negIntPat")) (arm (PCon "TMinusTight") () (EVar "negIntPat")) (arm (PCon "TFloat" (PVar "f")) () (EApp (EVar "emit") (EApp (EVar "PLit") (EApp (EVar "LFloat") (EVar "f"))))) (arm (PCon "TString" (PVar "s")) () (EApp (EVar "emit") (EApp (EVar "PLit") (EApp (EVar "LString") (EVar "s"))))) (arm (PCon "TChar" (PVar "s")) () (EApp (EVar "charPatRest") (EApp (EVar "LChar") (EVar "s")))) (arm (PCon "TUpper" (PVar "c")) () (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t2")) (EApp (EApp (EVar "upperAtomRest") (EVar "c")) (EVar "t2"))))))) (arm (PCon "TLParen") () (EVar "parsePatParen")) (arm (PCon "TLBracket") () (EVar "parsePatList")) (arm PWild () (EApp (EVar "reservedOrPatFail") (EVar "t")))))))
(DTypeSig false "upperAtomRest" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat")))))
(DFunDef false "upperAtomRest" ((PVar "c") (PCon "TLBrace")) (EApp (EVar "recordPat") (EVar "c")))
(DFunDef false "upperAtomRest" ((PVar "c") PWild) (EApp (EMethodRef "pure") (EApp (EApp (EVar "PCon") (EVar "c")) (EListLit))))
(DTypeSig false "parseParamPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parseParamPat" () (EApp (EApp (EVar "orElse#shadow") (EVar "parseParamAsPat")) (EVar "parsePatAtom")))
(DTypeSig false "parseParamAsPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parseParamAsPat" () (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TAsAt"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parsePatAtom")) (ELam ((PVar "sub")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "PAs") (EVar "x")) (EMethodRef "sub"))))))))))
(DTypeSig false "intPatRest" (TyFun (TyCon "Lit") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "intPatRest" ((PVar "lo")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "rngPatRest") (EVar "lo")) (EVar "intBound")) (EVar "t")))))))
(DTypeSig false "negIntPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "negIntPat" () (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "negIntRng") (EApp (EVar "LInt") (EApp (EMethodRef "negate") (EVar "n"))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected integer after -"))))))))))
(DTypeSig false "negIntRng" (TyFun (TyCon "Lit") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "negIntRng" ((PVar "lo")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TDotDot") () (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "intBound")) (ELam ((PVar "hi")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "False")))))))) (arm (PCon "TDotDotEq") () (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "intBound")) (ELam ((PVar "hi")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "True")))))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected .. or ..= after negative range bound"))))))))))
(DTypeSig false "charPatRest" (TyFun (TyCon "Lit") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "charPatRest" ((PVar "lo")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "rngPatRest") (EVar "lo")) (EVar "charBound")) (EVar "t")))))))
(DTypeSig false "rngPatRest" (TyFun (TyCon "Lit") (TyFun (TyApp (TyCon "Parser") (TyCon "Lit")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))))
(DFunDef false "rngPatRest" ((PVar "lo") (PVar "bound") (PCon "TDotDot")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "bound")) (ELam ((PVar "hi")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "False"))))))))
(DFunDef false "rngPatRest" ((PVar "lo") (PVar "bound") (PCon "TDotDotEq")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "bound")) (ELam ((PVar "hi")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "True"))))))))
(DFunDef false "rngPatRest" ((PVar "lo") PWild PWild) (EApp (EMethodRef "pure") (EApp (EVar "PLit") (EVar "lo"))))
(DTypeSig false "intBound" (TyApp (TyCon "Parser") (TyCon "Lit")))
(DFunDef false "intBound" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "intBoundFor") (EVar "t")))))
(DTypeSig false "intBoundFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Lit"))))
(DFunDef false "intBoundFor" ((PCon "TInt" (PVar "n") PWild)) (EIf (EApp (EVar "isIntMinLit") (EVar "n")) (EApp (EVar "fatalP") (EVar "intLitTooBigMsg")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "intBoundFor" ((PCon "TInt" (PVar "n") PWild)) (EApp (EVar "emit") (EApp (EVar "LInt") (EVar "n"))))
(DFunDef false "intBoundFor" ((PCon "TMinus")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "emit") (EApp (EVar "LInt") (EApp (EMethodRef "negate") (EVar "n"))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected integer after - in range bound"))))))))))
(DFunDef false "intBoundFor" ((PCon "TMinusTight")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "emit") (EApp (EVar "LInt") (EApp (EMethodRef "negate") (EVar "n"))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected integer after - in range bound"))))))))))
(DFunDef false "intBoundFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected int range bound"))))
(DTypeSig false "charBound" (TyApp (TyCon "Parser") (TyCon "Lit")))
(DFunDef false "charBound" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "charBoundFor") (EVar "t")))))
(DTypeSig false "charBoundFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Lit"))))
(DFunDef false "charBoundFor" ((PCon "TChar" (PVar "s"))) (EApp (EVar "emit") (EApp (EVar "LChar") (EVar "s"))))
(DFunDef false "charBoundFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected char range bound"))))
(DTypeSig false "tuplePatOrSingle" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Pat")))
(DFunDef false "tuplePatOrSingle" ((PList (PVar "p"))) (EVar "p"))
(DFunDef false "tuplePatOrSingle" ((PVar "ps")) (EApp (EVar "PTuple") (EVar "ps")))
(DTypeSig false "parsePatParen" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatParen" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "patParenFor") (EVar "t")))))))
(DTypeSig false "patParenFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patParenFor" ((PCon "TRParen")) (EApp (EVar "emit") (EApp (EVar "PLit") (EVar "LUnit"))))
(DFunDef false "patParenFor" (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parsePat")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ps")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "optTrailingCommaTuple") (EVar "ps"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "tuplePatOrSingle") (EVar "ps"))))))))))
(DTypeSig false "parsePatList" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatList" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLBracket"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "patListFor") (EVar "t")))))))
(DTypeSig false "patListFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patListFor" ((PCon "TRBracket")) (EApp (EVar "emit") (EApp (EVar "PList") (EListLit))))
(DFunDef false "patListFor" (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parsePat")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ps")) (EApp (EApp (EMethodRef "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "PList") (EVar "ps"))))))))))
(DTypeSig false "parseTy" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTy" () (EApp (EApp (EMethodRef "andThen") (EVar "parseTyFun")) (ELam ((PVar "lhs")) (EApp (EApp (EVar "orElse#shadow") (EApp (EVar "constraintTail") (EVar "lhs"))) (EApp (EMethodRef "pure") (EVar "lhs"))))))
(DTypeSig false "constraintTail" (TyFun (TyCon "Ty") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "constraintTail" ((PVar "lhs")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TFatArrow"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseTy")) (ELam ((PVar "rhs")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "TyConstrained") (EApp (EVar "extractConstraints") (EVar "lhs"))) (EVar "rhs"))))))))
(DTypeSig false "extractConstraints" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Constraint"))))
(DFunDef false "extractConstraints" ((PCon "TyApp" (PVar "f") (PVar "a"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "f")) (EVar "a"))) (arm (PCon "Some" (PTuple (PVar "iface") (PVar "args"))) () (EListLit (EApp (EApp (EVar "Constraint") (EVar "iface")) (EVar "args")))) (arm (PCon "None") () (EListLit))))
(DFunDef false "extractConstraints" ((PCon "TyCon" (PVar "iface") PWild)) (EListLit (EApp (EApp (EVar "Constraint") (EVar "iface")) (EListLit))))
(DFunDef false "extractConstraints" ((PCon "TyTuple" (PVar "cs"))) (EApp (EVar "concatMapC") (EVar "cs")))
(DFunDef false "extractConstraints" (PWild) (EListLit))
(DTypeSig false "tyAppSpine" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty"))))))
(DFunDef false "tyAppSpine" ((PVar "t")) (EApp (EApp (EVar "tyAppSpineAcc") (EVar "t")) (EListLit)))
(DTypeSig false "tyAppSpineAcc" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty")))))))
(DFunDef false "tyAppSpineAcc" ((PCon "TyCon" (PVar "iface") PWild) (PVar "acc")) (EApp (EVar "Some") (ETuple (EVar "iface") (EVar "acc"))))
(DFunDef false "tyAppSpineAcc" ((PCon "TyApp" (PVar "f") (PVar "a")) (PVar "acc")) (EApp (EApp (EVar "tyAppSpineAcc") (EVar "f")) (EBinOp "::" (EVar "a") (EVar "acc"))))
(DFunDef false "tyAppSpineAcc" (PWild PWild) (EVar "None"))
(DTypeSig false "concatMapC" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Constraint"))))
(DFunDef false "concatMapC" ((PList)) (EListLit))
(DFunDef false "concatMapC" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "++" (EApp (EVar "extractConstraints") (EVar "t")) (EApp (EVar "concatMapC") (EVar "rest"))))
(DTypeSig false "parseTyFun" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyFun" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "tyFor") (EVar "t")))))
(DTypeSig false "tyFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tyFor" ((PCon "TLt")) (EVar "parseEffectTy"))
(DFunDef false "tyFor" (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseTyApp")) (ELam ((PVar "left")) (EApp (EApp (EVar "orElse#shadow") (EApp (EVar "tyArrowTail") (EVar "left"))) (EApp (EMethodRef "pure") (EVar "left"))))))
(DTypeSig false "parseEffectTy" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseEffectTy" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLt"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "effectBody")) (ELam ((PVar "body")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TGt"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseTy")) (ELam ((PVar "inner")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "mkEffect") (EVar "body")) (EVar "inner"))))))))))))
(DTypeSig false "mkEffect" (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "mkEffect" ((PTuple (PVar "labels") (PVar "tail")) (PVar "inner")) (EApp (EApp (EApp (EVar "TyEffect") (EVar "labels")) (EVar "tail")) (EVar "inner")))
(DTypeSig false "effectBody" (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "effectBody" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "effectBodyFor") (EVar "t")))))
(DTypeSig false "effectBodyFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "effectBodyFor" ((PCon "TUpper" PWild)) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "effAtomP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "labels")) (EApp (EApp (EMethodRef "andThen") (EVar "pipeTail")) (ELam ((PVar "tail")) (EApp (EMethodRef "pure") (ETuple (EVar "labels") (EVar "tail"))))))))
(DFunDef false "effectBodyFor" ((PCon "TIdent" PWild)) (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "v")) (EApp (EMethodRef "pure") (ETuple (EListLit) (EApp (EVar "Some") (EVar "v")))))))
(DFunDef false "effectBodyFor" (PWild) (EApp (EMethodRef "pure") (ETuple (EListLit) (EVar "None"))))
(DTypeSig false "effAtomP" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "effAtomP" () (EApp (EApp (EMethodRef "andThen") (EVar "upperNameP")) (ELam ((PVar "l")) (EApp (EApp (EMethodRef "andThen") (EVar "effParamP")) (ELam ((PVar "p")) (EApp (EMethodRef "pure") (ETuple (EVar "l") (EVar "p"))))))))
(DTypeSig false "effParamP" (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "effParamP" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "andThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EVar "effParamDispatch") (EVar "t")) (EVar "t2")))))))
(DTypeSig false "effParamDispatch" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "effParamDispatch" ((PCon "TUpper" PWild) (PCon "TEqual")) (EVar "productParamP"))
(DFunDef false "effParamDispatch" ((PVar "t") PWild) (EApp (EVar "effParamFor") (EVar "t")))
(DTypeSig false "productParamP" (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "productParamP" () (EApp (EApp (EMethodRef "andThen") (EVar "productAxes")) (ELam ((PVar "axes")) (EApp (EMethodRef "pure") (EApp (EVar "Some") (EApp (EVar "encodeProductParam") (EVar "axes")))))))
(DTypeSig false "productAxes" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "productAxes" () (EApp (EApp (EMethodRef "andThen") (EVar "productAxis")) (ELam ((PVar "a")) (EApp (EApp (EMethodRef "andThen") (EVar "productAxesMore")) (ELam ((PVar "rest")) (EApp (EMethodRef "pure") (EBinOp "::" (EVar "a") (EVar "rest"))))))))
(DTypeSig false "productAxesMore" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "productAxesMore" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "andThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EVar "productAxesMoreFor") (EVar "t")) (EVar "t2")))))))
(DTypeSig false "productAxesMoreFor" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "productAxesMoreFor" ((PCon "TUpper" PWild) (PCon "TEqual")) (EVar "productAxes"))
(DFunDef false "productAxesMoreFor" (PWild PWild) (EApp (EMethodRef "pure") (EListLit)))
(DTypeSig false "productAxis" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "productAxis" () (EApp (EApp (EMethodRef "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "productAxisVal")) (ELam ((PVar "v")) (EApp (EMethodRef "pure") (ETuple (EVar "name") (EVar "v"))))))))))
(DTypeSig false "productAxisVal" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "productAxisVal" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "productAxisValFor") (EVar "t")))))
(DTypeSig false "productAxisValFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "productAxisValFor" ((PCon "TString" (PVar "s"))) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\"")))))))
(DFunDef false "productAxisValFor" ((PCon "TLBrace")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "stringLitP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "elems")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "encodeSetParam") (EVar "elems"))))))))))
(DFunDef false "productAxisValFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected product axis value (\"prefix\" or {set})"))))
(DTypeSig false "effParamFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "effParamFor" ((PCon "TString" (PVar "s"))) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "Some") (EVar "s"))))))
(DFunDef false "effParamFor" ((PCon "TUnderscore")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "Some") (ELit (LString "_")))))))
(DFunDef false "effParamFor" ((PCon "TLBrace")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "stringLitP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "elems")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "Some") (EApp (EVar "encodeSetParam") (EVar "elems")))))))))))
(DFunDef false "effParamFor" (PWild) (EApp (EMethodRef "pure") (EVar "None")))
(DTypeSig false "encodeSetParam" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "encodeSetParam" ((PVar "elems")) (EBinOp "++" (EBinOp "++" (ELit (LString "{")) (EApp (EVar "joinComma") (EVar "elems"))) (ELit (LString "}"))))
(DTypeSig false "encodeProductParam" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "String")))
(DFunDef false "encodeProductParam" ((PVar "axes")) (EBinOp "++" (EBinOp "++" (ELit (LString "@P{")) (EApp (EVar "joinSemi") (EApp (EApp (EMethodRef "map") (EVar "encodeAxis")) (EVar "axes")))) (ELit (LString "}"))))
(DTypeSig false "encodeAxis" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "encodeAxis" ((PTuple (PVar "name") (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "="))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString ""))))
(DTypeSig false "joinSemi" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSemi" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString ";"))) (EVar "xs")))
(DTypeSig false "joinComma" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinComma" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "xs")))
(DTypeSig false "pipeTail" (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "pipeTail" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "pipeTailFor") (EVar "t")))))
(DTypeSig false "pipeTailFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "pipeTailFor" ((PCon "TPipe")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "v")) (EApp (EMethodRef "pure") (EApp (EVar "Some") (EVar "v"))))))))
(DFunDef false "pipeTailFor" (PWild) (EApp (EMethodRef "pure") (EVar "None")))
(DTypeSig false "upperNameP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "upperNameP" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "upperNameFor") (EVar "t")))))
(DTypeSig false "upperNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "upperNameFor" ((PCon "TUpper" (PVar "c"))) (EApp (EVar "emit") (EVar "c")))
(DFunDef false "upperNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected effect label"))))
(DTypeSig false "tyArrowTail" (TyFun (TyCon "Ty") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tyArrowTail" ((PVar "left")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TArrow"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "tyArrowSkipLayout") (EVar "t"))) (ELam ((PVar "indented")) (EApp (EApp (EMethodRef "andThen") (EVar "parseTy")) (ELam ((PVar "right")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EDictApp "when") (EVar "indented")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "expectTok") (EVar "TDedent")))))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EVar "TyFun") (EVar "left")) (EVar "right"))))))))))))))
(DTypeSig false "tyArrowSkipLayout" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Bool"))))
(DFunDef false "tyArrowSkipLayout" ((PCon "TNewline")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EVar "False")))))
(DFunDef false "tyArrowSkipLayout" ((PCon "TIndent")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EVar "True")))))
(DFunDef false "tyArrowSkipLayout" (PWild) (EApp (EMethodRef "pure") (EVar "False")))
(DTypeSig false "parseTyApp" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyApp" () (EApp (EApp (EMethodRef "andThen") (EVar "parseTyAtom")) (ELam ((PVar "head")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "args")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "tyApplyAll") (EVar "head")) (EVar "args"))))))))
(DTypeSig false "tyApplyAll" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty"))))
(DFunDef false "tyApplyAll" ((PVar "head") (PList)) (EVar "head"))
(DFunDef false "tyApplyAll" ((PVar "head") (PCons (PVar "a") (PVar "rest"))) (EApp (EApp (EVar "tyApplyAll") (EApp (EApp (EVar "TyApp") (EVar "head")) (EVar "a"))) (EVar "rest")))
(DTypeSig false "parseTyAtom" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyAtom" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TUpper" (PVar "c")) () (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "TyCon") (EVar "c")) (EApp (EVar "Some") (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "q")))))))))))) (arm (PCon "TIdent" (PVar "v")) () (EApp (EVar "emit") (EApp (EVar "TyVar") (EVar "v")))) (arm (PCon "TLParen") () (EVar "parseTyParen")) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected type atom"))))))))
(DTypeSig false "tyTupleOrSingle" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty")))
(DFunDef false "tyTupleOrSingle" ((PList (PVar "t"))) (EVar "t"))
(DFunDef false "tyTupleOrSingle" ((PVar "ts")) (EApp (EVar "TyTuple") (EVar "ts")))
(DTypeSig false "parseTyParen" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyParen" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "parseTyParenBody") (EVar "t")))))))
(DTypeSig false "parseTyParenBody" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "parseTyParenBody" ((PCon "TComma")) (EApp (EVar "parseTupleCtorTail") (ELit (LInt 0))))
(DFunDef false "parseTyParenBody" (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parseTy")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ts")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "optTrailingCommaTuple") (EVar "ts"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "tyTupleOrSingle") (EVar "ts"))))))))))
(DTypeSig false "parseTupleCtorTail" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "parseTupleCtorTail" ((PVar "commas")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "tupleCtorTailFor") (EVar "commas")) (EVar "t")))))
(DTypeSig false "tupleCtorTailFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty")))))
(DFunDef false "tupleCtorTailFor" ((PVar "commas") (PCon "TComma")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "parseTupleCtorTail") (EBinOp "+" (EVar "commas") (ELit (LInt 1)))))))
(DFunDef false "tupleCtorTailFor" ((PVar "commas") (PCon "TRParen")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "tupleCtorTyOfArity") (EBinOp "+" (EVar "commas") (ELit (LInt 1)))))))
(DFunDef false "tupleCtorTailFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected , or ) in tuple type constructor"))))
(DTypeSig false "tupleCtorTyOfArity" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tupleCtorTyOfArity" ((PVar "n")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "<=" (EVar "n") (ELit (LInt 5)))) (EApp (EMethodRef "pure") (EApp (EApp (EVar "TyCon") (EApp (EVar "tupleCtorTyName") (EVar "n"))) (EVar "None"))) (EApp (EVar "failP") (ELit (LString "tuple type constructor arity must be 2..5")))))
(DTypeSig false "tupleCtorTyName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 2))) (ELit (LString "__tuple2__")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 3))) (ELit (LString "__tuple3__")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 4))) (ELit (LString "__tuple4__")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 5))) (ELit (LString "__tuple5__")))
(DFunDef false "tupleCtorTyName" (PWild) (ELit (LString "__tuple0__")))
(DTypeSig false "parseDecl" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "parseDecl" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TImport") () (EApp (EVar "parseImport") (EVar "False"))) (arm (PCon "TExport") () (EVar "afterExport")) (arm (PCon "TPublic") () (EVar "afterPublic")) (arm (PCon "TData") () (EApp (EVar "parseData") (EVar "VisPrivate"))) (arm (PCon "TExtern") () (EApp (EVar "parseExtern") (EVar "False"))) (arm (PCon "TProp") () (EApp (EVar "parseProp") (EVar "False"))) (arm (PCon "TTest") () (EApp (EVar "parseTest") (EVar "False"))) (arm (PCon "TBench") () (EApp (EVar "parseBench") (EVar "False"))) (arm (PCon "TEffect") () (EApp (EVar "parseEffect") (EVar "False"))) (arm (PCon "TInterface") () (EApp (EApp (EVar "parseInterface") (EVar "False")) (EVar "False"))) (arm (PCon "TImpl") () (EApp (EVar "parseImpl") (EVar "False"))) (arm (PCon "TDefault") () (EApp (EVar "afterDefault") (EVar "False"))) (arm (PCon "TType") () (EApp (EVar "parseTypeAlias") (EVar "False"))) (arm (PCon "TNewtype") () (EApp (EVar "parseNewtype") (EVar "False"))) (arm (PCon "TLet") () (EApp (EVar "parseLetGroupDecl") (EVar "False"))) (arm (PCon "TAt") () (EVar "parseAttrib")) (arm PWild () (EApp (EVar "parseFunOrSig") (EVar "False")))))))
(DTypeSig false "afterDefault" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "afterDefault" ((PVar "pub")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDefault"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "afterDefaultFor") (EVar "pub")) (EVar "t")))))))))
(DTypeSig false "afterDefaultFor" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "afterDefaultFor" ((PVar "pub") (PCon "TInterface")) (EApp (EApp (EVar "parseInterface") (EVar "pub")) (EVar "True")))
(DFunDef false "afterDefaultFor" (PWild (PCon "TImpl")) (EApp (EVar "failP") (EVar "defaultImplRemovedMsg")))
(DFunDef false "afterDefaultFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected interface after default"))))
(DTypeSig false "afterExport" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "afterExport" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TExport"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TImport") () (EApp (EVar "parseImport") (EVar "True"))) (arm (PCon "TData") () (EApp (EVar "parseData") (EVar "VisAbstract"))) (arm (PCon "TExtern") () (EApp (EVar "parseExtern") (EVar "True"))) (arm (PCon "TProp") () (EApp (EVar "parseProp") (EVar "True"))) (arm (PCon "TTest") () (EApp (EVar "parseTest") (EVar "True"))) (arm (PCon "TBench") () (EApp (EVar "parseBench") (EVar "True"))) (arm (PCon "TEffect") () (EApp (EVar "parseEffect") (EVar "True"))) (arm (PCon "TInterface") () (EApp (EApp (EVar "parseInterface") (EVar "True")) (EVar "False"))) (arm (PCon "TImpl") () (EApp (EVar "parseImpl") (EVar "True"))) (arm (PCon "TDefault") () (EApp (EVar "afterDefault") (EVar "True"))) (arm (PCon "TType") () (EApp (EVar "parseTypeAlias") (EVar "True"))) (arm (PCon "TNewtype") () (EApp (EVar "parseNewtype") (EVar "True"))) (arm (PCon "TLet") () (EApp (EVar "parseLetGroupDecl") (EVar "True"))) (arm PWild () (EApp (EVar "parseFunOrSig") (EVar "True")))))))))))
(DTypeSig false "afterPublic" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "afterPublic" () (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "pubPos")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TPublic"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TExport"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "afterPublicFor") (EVar "pubPos")) (EVar "t")))))))))))))))
(DTypeSig false "afterPublicFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "afterPublicFor" (PWild (PCon "TData")) (EApp (EVar "parseData") (EVar "VisPublic")))
(DFunDef false "afterPublicFor" ((PVar "pubPos") PWild) (EApp (EApp (EVar "fatalAtP") (ELit (LString "`public` only applies to `data` declarations"))) (EVar "pubPos")))
(DTypeSig false "parseFunOrSig" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseFunOrSig" ((PVar "pub")) (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "params")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TColon") () (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "DTypeSig") (EVar "pub")) (EVar "name")) (EVar "ty")))))))))) (arm (PCon "TEqual") () (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "body")))))))))) (arm (PCon "TIndent") () (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseGuardArms")) (ELam ((PVar "arms")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "guardArmsWhereOpt") (EVar "arms"))) (ELam ((PVar "body")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "body")))))))))))))) (arm (PCon "TPipe") () (EApp (EApp (EMethodRef "andThen") (EVar "parseGuardArm")) (ELam ((PVar "arm")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EVar "EGuards") (EListLit (EVar "arm")))))))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected : or = in definition"))))))))))))
(DTypeSig false "parseExtern" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseExtern" ((PVar "pub")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TExtern"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "externName")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "DExtern") (EVar "pub")) (EVar "name")) (EVar "ty"))))))))))))))
(DTypeSig false "parseTypeAlias" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseTypeAlias" ((PVar "pub")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TType"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "lowerNameP"))) (ELam ((PVar "params")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EVar "DTypeAlias") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "ty"))))))))))))))))
(DTypeSig false "parseNewtype" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseNewtype" ((PVar "pub")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TNewtype"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "lowerNameP"))) (ELam ((PVar "params")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "upperNameP")) (ELam ((PVar "con")) (EApp (EApp (EMethodRef "andThen") (EVar "parseTy")) (ELam ((PVar "fty")) (EApp (EApp (EMethodRef "andThen") (EVar "derivingClause")) (ELam ((PVar "derives")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DNewtype") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "con")) (EVar "fty")) (EVar "derives"))))))))))))))))))))
(DTypeSig false "parseLetGroupDecl" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseLetGroupDecl" ((PVar "pub")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRec"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "letRecDeclClause")) (ELam ((PVar "c")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EVar "coalesceClauses") (EListLit (EVar "c"))))))))))))))
(DTypeSig false "letRecDeclClause" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))
(DFunDef false "letRecDeclClause" () (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EMethodRef "pure") (ETuple (EVar "name") (EVar "pats") (EVar "body"))))))))))))
(DTypeSig false "parseAttrib" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "parseAttrib" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TAt"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "attrArg") (EVar "name")) (EVar "t"))) (ELam ((PVar "attr")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseDecl")) (ELam ((PVar "inner")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "DAttrib") (EListLit (EVar "attr"))) (EVar "inner"))))))))))))))))
(DTypeSig false "attrArg" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Attr")))))
(DFunDef false "attrArg" ((PVar "name") (PCon "TString" (PVar "msg"))) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EVar "mkAttr") (EVar "name")) (EApp (EVar "Some") (EVar "msg")))))))
(DFunDef false "attrArg" ((PVar "name") PWild) (EApp (EMethodRef "pure") (EApp (EApp (EVar "mkAttr") (EVar "name")) (EVar "None"))))
(DTypeSig false "mkAttr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Attr"))))
(DFunDef false "mkAttr" ((PLit (LString "deprecated")) (PCon "Some" (PVar "msg"))) (EApp (EVar "AttrDeprecated") (EVar "msg")))
(DFunDef false "mkAttr" ((PLit (LString "must_use")) PWild) (EVar "AttrMustUse"))
(DFunDef false "mkAttr" (PWild PWild) (EVar "AttrInline"))
(DTypeSig false "externName" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "externName" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "externNameFor") (EVar "t")))))
(DTypeSig false "externNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "externNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "externNameFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "externNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected extern name"))))
(DTypeSig false "parseImport" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseImport" ((PVar "pub")) (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TImport"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "importQuals")) (ELam ((PVar "quals")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "importPathFor") (EVar "quals"))) (ELam ((PVar "path")) (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "noExportedAlias") (EVar "pub")) (EVar "path"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "DUse") (EVar "pub")) (EVar "path")) (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "e")))))))))))))))))))
(DTypeSig false "noExportedAlias" (TyFun (TyCon "Bool") (TyFun (TyCon "UsePath") (TyApp (TyCon "Parser") (TyCon "Unit")))))
(DFunDef false "noExportedAlias" ((PCon "True") (PCon "UseAlias" PWild (PVar "a"))) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`export import … as ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "` is not allowed — a module alias is file-local (it binds `"))) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString ".name`, which an importer could not write). Re-export the module itself (`export import m`) and let the importer choose its own alias.")))))
(DFunDef false "noExportedAlias" ((PCon "True") (PCon "UseGroup" PWild (PVar "members"))) (EApp (EVar "failIfAliasedMember") (EVar "members")))
(DFunDef false "noExportedAlias" (PWild PWild) (EApp (EMethodRef "pure") (ELit LUnit)))
(DTypeSig false "failIfAliasedMember" (TyFun (TyApp (TyCon "List") (TyCon "UseMember")) (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "failIfAliasedMember" ((PList)) (EApp (EMethodRef "pure") (ELit LUnit)))
(DFunDef false "failIfAliasedMember" ((PCons (PVar "m") (PVar "rest"))) (EMatch (EApp (EVar "useMemberAlias") (EVar "m")) (arm (PCon "Some" (PVar "a")) () (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`export import` cannot rename a member — re-exporting `")) (EApp (EMethodRef "display") (EApp (EVar "useMemberOrigin") (EVar "m")))) (ELit (LString "` as `"))) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "` would export a name its defining module does not have. Re-export it under its own name (`export import m.{"))) (EApp (EMethodRef "display") (EApp (EVar "useMemberOrigin") (EVar "m")))) (ELit (LString "}`) and let the importer alias it."))))) (arm (PCon "None") () (EApp (EVar "failIfAliasedMember") (EVar "rest")))))
(DTypeSig false "importQuals" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "importQuals" () (EApp (EApp (EMethodRef "andThen") (EVar "importIdent")) (ELam ((PVar "first")) (EApp (EApp (EMethodRef "andThen") (EVar "importQualRest")) (ELam ((PVar "rest")) (EApp (EMethodRef "pure") (EBinOp "::" (EVar "first") (EVar "rest"))))))))
(DTypeSig false "importQualRest" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "importQualRest" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "importQualRestFor") (EVar "t")))))
(DTypeSig false "importQualRestFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importQualRestFor" ((PCon "TDot")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "importIdent")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EVar "importQualRest")) (ELam ((PVar "rest")) (EApp (EMethodRef "pure") (EBinOp "::" (EVar "x") (EVar "rest"))))))))))
(DFunDef false "importQualRestFor" (PWild) (EApp (EMethodRef "pure") (EListLit)))
(DTypeSig false "importIdent" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "importIdent" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "importIdentFor") (EVar "t")))))
(DTypeSig false "importIdentFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "importIdentFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "importIdentFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "importIdentFor" ((PCon "TTest")) (EApp (EVar "emit") (ELit (LString "test"))))
(DFunDef false "importIdentFor" ((PCon "TRecord")) (EApp (EVar "emit") (ELit (LString "record"))))
(DFunDef false "importIdentFor" ((PCon "TData")) (EApp (EVar "emit") (ELit (LString "data"))))
(DFunDef false "importIdentFor" ((PCon "TType")) (EApp (EVar "emit") (ELit (LString "type"))))
(DFunDef false "importIdentFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected import path component"))))
(DTypeSig false "importPathFor" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Parser") (TyCon "UsePath"))))
(DFunDef false "importPathFor" ((PVar "quals")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "importPathForT") (EVar "quals")) (EVar "t")))))
(DTypeSig false "importPathForT" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UsePath")))))
(DFunDef false "importPathForT" ((PVar "quals") (PCon "TDotLBrace")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "importMember")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ms")) (EApp (EApp (EMethodRef "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "noTrailingAlias") (ELit (LString "a selective import")))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EVar "UseGroup") (EVar "quals")) (EVar "ms"))))))))))))))
(DFunDef false "importPathForT" ((PVar "quals") (PCon "TDotStar")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "noTrailingAlias") (ELit (LString "a wildcard import")))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "UseWild") (EVar "quals"))))))))
(DFunDef false "importPathForT" ((PVar "quals") (PCon "TAs")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "aliasName")) (ELam ((PVar "a")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "UseAlias") (EVar "quals")) (EVar "a"))))))))
(DFunDef false "importPathForT" ((PVar "quals") PWild) (EApp (EMethodRef "pure") (EApp (EVar "UseName") (EVar "quals"))))
(DTypeSig false "noTrailingAlias" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "noTrailingAlias" ((PVar "what")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "noTrailingAliasFor") (EVar "what")) (EVar "t")))))
(DTypeSig false "noTrailingAliasFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit")))))
(DFunDef false "noTrailingAliasFor" ((PVar "what") (PCon "TAs")) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "`as` cannot alias ")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString " — write `import m as A` to alias the whole module (then use `A.name`), or `import m.{name as alias}` to rename one member")))))
(DFunDef false "noTrailingAliasFor" (PWild PWild) (EApp (EMethodRef "pure") (ELit LUnit)))
(DTypeSig false "importMember" (TyApp (TyCon "Parser") (TyCon "UseMember")))
(DFunDef false "importMember" () (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "importMemberFor") (EVar "s")) (EVar "t")))))))
(DTypeSig false "importMemberFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UseMember")))))
(DFunDef false "importMemberFor" ((PVar "s") (PCon "TIdent" (PVar "x"))) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EApp (EVar "memberAliasOrNot") (EVar "s")) (EVar "x")) (EVar "False")))))
(DFunDef false "importMemberFor" ((PVar "s") (PCon "TUpper" (PVar "x"))) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "withAllOrNot") (EVar "s")) (EVar "x")))))
(DFunDef false "importMemberFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected import member"))))
(DTypeSig false "withAllOrNot" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "UseMember")))))
(DFunDef false "withAllOrNot" ((PVar "s") (PVar "x")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "withAllFor") (EVar "s")) (EVar "x")) (EVar "t")))))
(DTypeSig false "withAllFor" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UseMember"))))))
(DFunDef false "withAllFor" ((PVar "s") (PVar "x") (PCon "TLParen")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDotDot"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "noMemberAlias") (EVar "x"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "True")) (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "q"))) (EVar "None"))))))))))))))
(DFunDef false "withAllFor" ((PVar "s") (PVar "x") PWild) (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "noMemberAlias") (EVar "x"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "False")) (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "q"))) (EVar "None"))))))))
(DTypeSig false "noMemberAlias" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "noMemberAlias" ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "noMemberAliasFor") (EVar "x")) (EVar "t")))))
(DTypeSig false "noMemberAliasFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit")))))
(DFunDef false "noMemberAliasFor" ((PVar "x") (PCon "TAs")) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "` is a type or constructor and cannot be aliased — only a value member can be renamed (`import m.{name as alias}`). Import it under its own name.")))))
(DFunDef false "noMemberAliasFor" (PWild PWild) (EApp (EMethodRef "pure") (ELit LUnit)))
(DTypeSig false "memberAliasOrNot" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "UseMember"))))))
(DFunDef false "memberAliasOrNot" ((PVar "s") (PVar "x") (PVar "allCtors")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "memberAliasFor") (EVar "s")) (EVar "x")) (EVar "allCtors")) (EVar "t")))))
(DTypeSig false "memberAliasFor" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UseMember")))))))
(DFunDef false "memberAliasFor" ((PVar "s") (PVar "x") (PVar "allCtors") (PCon "TAs")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "memberAliasName")) (ELam ((PVar "a")) (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "allCtors")) (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "q"))) (EApp (EVar "Some") (EVar "a")))))))))))
(DFunDef false "memberAliasFor" ((PVar "s") (PVar "x") (PVar "allCtors") PWild) (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "allCtors")) (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "q"))) (EVar "None"))))))
(DTypeSig false "memberAliasName" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "memberAliasName" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "memberAliasNameFor") (EVar "t")))))
(DTypeSig false "memberAliasNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "memberAliasNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "memberAliasNameFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "a value member's alias must be lowercase — `as ")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "` names a type or constructor")))))
(DFunDef false "memberAliasNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected alias name after `as`"))))
(DTypeSig false "aliasName" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "aliasName" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "aliasNameFor") (EVar "t")))))
(DTypeSig false "aliasNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "aliasNameFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "aliasNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "a module alias must be capitalized — `as ")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "` should be an Uppercase name (it is used as a qualifier, `Alias.name`)")))))
(DFunDef false "aliasNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected alias name after `as`"))))
(DTypeSig false "stringLitP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "stringLitP" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "stringLitFor") (EVar "t")))))
(DTypeSig false "stringLitFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "stringLitFor" ((PCon "TString" (PVar "s"))) (EApp (EVar "emit") (EVar "s")))
(DFunDef false "stringLitFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected string literal"))))
(DTypeSig false "parseProp" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseProp" ((PVar "pub")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TProp"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "stringLitP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "propParam"))) (ELam ((PVar "params")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "body"))))))))))))))))
(DTypeSig false "propParam" (TyApp (TyCon "Parser") (TyCon "PropParam")))
(DFunDef false "propParam" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EVar "PropParam") (EVar "name")) (EVar "ty"))))))))))))))
(DTypeSig false "parseTest" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseTest" ((PVar "pub")) (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "testPos")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TTest"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "parseTestRest") (EVar "pub")) (EVar "testPos")) (EVar "t")))))))))
(DTypeSig false "parseTestRest" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl"))))))
(DFunDef false "parseTestRest" ((PVar "pub") PWild (PCon "TString" PWild)) (EApp (EApp (EMethodRef "andThen") (EVar "stringLitP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EVar "body"))))))))))))
(DFunDef false "parseTestRest" (PWild (PVar "testPos") PWild) (EApp (EApp (EVar "fatalAtP") (EApp (EVar "reservedKeywordMsg") (ELit (LString "test")))) (EVar "testPos")))
(DTypeSig false "parseBench" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseBench" ((PVar "pub")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TBench"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "stringLitP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "DBench") (EVar "pub")) (EVar "name")) (EVar "body"))))))))))))))
(DTypeSig false "parseEffect" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseEffect" ((PVar "pub")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEffect"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EVar "effDomainP")) (ELam ((PVar "dom")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "DEffect") (EVar "pub")) (EVar "name")) (EVar "dom"))))))))))))
(DTypeSig false "effDomainP" (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "effDomainP" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "effDomainFor") (EVar "t")))))
(DTypeSig false "effDomainFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "effDomainFor" ((PCon "TUpper" (PVar "d"))) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "Some") (EVar "d"))))))
(DFunDef false "effDomainFor" (PWild) (EApp (EMethodRef "pure") (EVar "None")))
(DTypeSig false "parseInterface" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "parseInterface" ((PVar "pub") (PVar "isDefault")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TInterface"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "lowerNameP"))) (ELam ((PVar "typarams")) (EApp (EApp (EMethodRef "andThen") (EVar "ifaceSuper")) (ELam ((PVar "supers")) (EApp (EApp (EMethodRef "andThen") (EVar "ifaceBody")) (ELam ((PVar "methods")) (EApp (EMethodRef "pure") (ERecordCreate "DInterface" ((fa "pub" (EVar "pub")) (fa "def" (EVar "isDefault")) (fa "name" (EVar "name")) (fa "typarams" (EVar "typarams")) (fa "supers" (EVar "supers")) (fa "methods" (EVar "methods"))))))))))))))))
(DTypeSig false "ifaceSuper" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Super"))))
(DFunDef false "ifaceSuper" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "ifaceSuperFor") (EVar "t")))))
(DTypeSig false "ifaceSuperFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Super")))))
(DFunDef false "ifaceSuperFor" ((PCon "TRequires")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "sepBy1") (EVar "ifaceSuperEntry")) (EApp (EVar "expectTok") (EVar "TComma"))))))
(DFunDef false "ifaceSuperFor" (PWild) (EApp (EMethodRef "pure") (EListLit)))
(DTypeSig false "ifaceSuperEntry" (TyApp (TyCon "Parser") (TyCon "Super")))
(DFunDef false "ifaceSuperEntry" () (EApp (EApp (EMethodRef "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "lowerNameP"))) (ELam ((PVar "params")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "Super") (EVar "name")) (EVar "params"))))))))
(DTypeSig false "ifaceBody" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceBody" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "ifaceBodyFor") (EVar "t")))))
(DTypeSig false "ifaceBodyFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "ifaceBodyFor" ((PCon "TWhere")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "ifaceWhereBody") (EVar "t")))))))
(DFunDef false "ifaceBodyFor" (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EListLit)))))
(DTypeSig false "ifaceWhereBody" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "ifaceWhereBody" ((PCon "TIndent")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "ifaceMembers")) (ELam ((PVar "ms")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EVar "ms")))))))))))
(DFunDef false "ifaceWhereBody" (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EListLit)))))
(DTypeSig false "ifaceMembers" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceMembers" () (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "ifaceMembersLoop"))))
(DTypeSig false "ifaceMembersLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceMembersLoop" () (EApp (EApp (EVar "orElse#shadow") (EVar "ifaceMembersCons")) (EApp (EMethodRef "pure") (EListLit))))
(DTypeSig false "ifaceMembersCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceMembersCons" () (EApp (EApp (EMethodRef "andThen") (EVar "ifaceMember")) (ELam ((PVar "m")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "ifaceMembersLoop")) (ELam ((PVar "rest")) (EApp (EMethodRef "pure") (EBinOp "::" (EVar "m") (EVar "rest"))))))))))
(DTypeSig false "ifaceMember" (TyApp (TyCon "Parser") (TyCon "IfaceMethod")))
(DFunDef false "ifaceMember" () (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "ifaceMemberRest") (EVar "name")) (EVar "pats")) (EVar "t")))))))))
(DTypeSig false "ifaceMemberRest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "IfaceMethod"))))))
(DFunDef false "ifaceMemberRest" ((PVar "name") PWild (PCon "TColon")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "name")) (EVar "ty")) (EVar "None"))))))))
(DFunDef false "ifaceMemberRest" ((PVar "name") (PVar "pats") (PCon "TEqual")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "name")) (EApp (EVar "TyVar") (ELit (LString "_")))) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "pats")) (EVar "body"))))))))))
(DFunDef false "ifaceMemberRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected : or = in interface member"))))
(DTypeSig false "parseImpl" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseImpl" ((PVar "pub")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TImpl"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "implHead") (EVar "pub")) (EVar "t")))))))
(DTypeSig false "implHead" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "implHead" ((PVar "pub") (PCon "TUpper" (PVar "u"))) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "implRest") (EVar "pub")) (EVar "u")))))
(DFunDef false "implHead" ((PVar "pub") (PCon "TIdent" PWild)) (EApp (EVar "failP") (EVar "namedImplRemovedMsg")))
(DFunDef false "implHead" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected impl head"))))
(DTypeSig false "implRest" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "implRest" ((PVar "pub") (PVar "iface")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "tyargs")) (EApp (EApp (EMethodRef "andThen") (EVar "implRequires")) (ELam ((PVar "reqs")) (EApp (EApp (EMethodRef "andThen") (EVar "implBody")) (ELam ((PVar "methods")) (EApp (EMethodRef "pure") (ERecordCreate "DImpl" ((fa "pub" (EVar "pub")) (fa "iface" (EVar "iface")) (fa "tys" (EVar "tyargs")) (fa "reqs" (EVar "reqs")) (fa "methods" (EVar "methods"))))))))))))
(DTypeSig false "namedImplRemovedMsg" (TyCon "String"))
(DFunDef false "namedImplRemovedMsg" () (ELit (LString "named impls (`impl name of Iface`) have been removed — use a plain `impl Iface` (wrap the type in a newtype for a second instance)")))
(DTypeSig false "defaultImplRemovedMsg" (TyCon "String"))
(DFunDef false "defaultImplRemovedMsg" () (ELit (LString "`default impl` has been removed — use a plain `impl` (specialization picks the most-specific instance automatically)")))
(DTypeSig false "implRequires" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Require"))))
(DFunDef false "implRequires" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "implRequiresFor") (EVar "t")))))
(DTypeSig false "implRequiresFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Require")))))
(DFunDef false "implRequiresFor" ((PCon "TRequires")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "sepBy1") (EVar "implRequireEntry")) (EApp (EVar "expectTok") (EVar "TComma"))))))
(DFunDef false "implRequiresFor" (PWild) (EApp (EMethodRef "pure") (EListLit)))
(DTypeSig false "implRequireEntry" (TyApp (TyCon "Parser") (TyCon "Require")))
(DFunDef false "implRequireEntry" () (EApp (EApp (EMethodRef "andThen") (EVar "upperNameP")) (ELam ((PVar "iface")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "tys")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "Require") (EVar "iface")) (EVar "tys"))))))))
(DTypeSig false "implBody" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))
(DFunDef false "implBody" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "implBodyFor") (EVar "t")))))
(DTypeSig false "implBodyFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod")))))
(DFunDef false "implBodyFor" ((PCon "TWhere")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "implWhereBody") (EVar "t")))))))
(DFunDef false "implBodyFor" (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EListLit)))))
(DTypeSig false "implWhereBody" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod")))))
(DFunDef false "implWhereBody" ((PCon "TIndent")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "implMethods")) (ELam ((PVar "ms")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EVar "ms")))))))))))
(DFunDef false "implWhereBody" (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EListLit)))))
(DTypeSig false "implMethods" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))
(DFunDef false "implMethods" () (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "implMethodsLoop"))))
(DTypeSig false "implMethodsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))
(DFunDef false "implMethodsLoop" () (EApp (EApp (EVar "orElse#shadow") (EVar "implMethodsCons")) (EApp (EMethodRef "pure") (EListLit))))
(DTypeSig false "implMethodsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))
(DFunDef false "implMethodsCons" () (EApp (EApp (EMethodRef "andThen") (EVar "implMethod")) (ELam ((PVar "m")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "implMethodsLoop")) (ELam ((PVar "rest")) (EApp (EMethodRef "pure") (EBinOp "::" (EVar "m") (EVar "rest"))))))))))
(DTypeSig false "implMethod" (TyApp (TyCon "Parser") (TyCon "ImplMethod")))
(DFunDef false "implMethod" () (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "ImplMethod") (EVar "name")) (EVar "pats")) (EVar "body"))))))))))))
(DTypeSig false "guardArmsWhereOpt" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "guardArmsWhereOpt" ((PVar "arms")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "guardArmsWhereFor") (EVar "arms")) (EVar "t")))))
(DTypeSig false "guardArmsWhereFor" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "guardArmsWhereFor" ((PVar "arms") (PCon "TWhere")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseWhereBindings")) (ELam ((PVar "binds")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EVar "binds"))) (EApp (EVar "EGuards") (EVar "arms")))))))))))))))
(DFunDef false "guardArmsWhereFor" ((PVar "arms") PWild) (EApp (EMethodRef "pure") (EApp (EVar "EGuards") (EVar "arms"))))
(DTypeSig false "parseGuardArms" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "GuardArm"))))
(DFunDef false "parseGuardArms" () (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "guardArmsLoop"))))
(DTypeSig false "guardArmsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "GuardArm"))))
(DFunDef false "guardArmsLoop" () (EApp (EApp (EVar "orElse#shadow") (EVar "guardArmsCons")) (EApp (EMethodRef "pure") (EListLit))))
(DTypeSig false "guardArmsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "GuardArm"))))
(DFunDef false "guardArmsCons" () (EApp (EApp (EMethodRef "andThen") (EVar "parseGuardArm")) (ELam ((PVar "a")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "guardArmsLoop")) (ELam ((PVar "rest")) (EApp (EMethodRef "pure") (EBinOp "::" (EVar "a") (EVar "rest"))))))))))
(DTypeSig false "parseGuardArm" (TyApp (TyCon "Parser") (TyCon "GuardArm")))
(DFunDef false "parseGuardArm" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parseGuard")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "guards")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "GuardArm") (EVar "guards")) (EVar "body"))))))))))))
(DTypeSig false "parseGuard" (TyApp (TyCon "Parser") (TyCon "Guard")))
(DFunDef false "parseGuard" () (EApp (EApp (EMethodRef "andThen") (EVar "parseOr")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "guardFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "guardFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Guard")))))
(DFunDef false "guardFor" ((PVar "e") (PCon "TLArrow")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseOr")) (ELam ((PVar "rhs")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "GBind") (EApp (EVar "exprToPat") (EVar "e"))) (EVar "rhs"))))))))
(DFunDef false "guardFor" ((PVar "e") PWild) (EApp (EMethodRef "pure") (EApp (EVar "GBool") (EVar "e"))))
(DTypeSig false "lowerNameP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "lowerNameP" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "lowerNameFor") (EVar "t")))))
(DTypeSig false "lowerNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "lowerNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "lowerNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected type parameter"))))
(DTypeSig false "parseData" (TyFun (TyCon "DataVis") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseData" ((PVar "vis")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TData"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "lowerNameP"))) (ELam ((PVar "params")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "dataBody") (EVar "name"))) (ELam ((PVar "bodyAndDerives")) (ELet false (PVar "variants") (EApp (EVar "fst") (EVar "bodyAndDerives")) (ELet false (PVar "blockDerives") (EApp (EVar "snd") (EVar "bodyAndDerives")) (EApp (EApp (EMethodRef "andThen") (EVar "derivingClause")) (ELam ((PVar "outerDerives")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EApp (EVar "DData") (EVar "vis")) (EVar "name")) (EVar "params")) (EVar "variants")) (EApp (EApp (EVar "combineDerives") (EVar "blockDerives")) (EVar "outerDerives")))))))))))))))))))
(DTypeSig false "combineDerives" (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyApp (TyCon "List") (TyCon "DeriveRef")))))
(DFunDef false "combineDerives" ((PList) (PVar "outer")) (EVar "outer"))
(DFunDef false "combineDerives" ((PVar "block") PWild) (EVar "block"))
(DTypeSig false "dataBody" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "DeriveRef"))))))
(DFunDef false "dataBody" ((PVar "tyName")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dataBodyFor") (EVar "tyName")) (EVar "t")))))
(DTypeSig false "dataBodyFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "DeriveRef")))))))
(DFunDef false "dataBodyFor" ((PVar "tyName") (PCon "TEqual")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dataAfterEq") (EVar "tyName")) (EVar "t")))))))
(DFunDef false "dataBodyFor" ((PVar "tyName") (PCon "TIndent")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "dataVariantsN") (EVar "tyName"))) (ELam ((PVar "vs")) (EApp (EApp (EMethodRef "andThen") (EVar "derivingClause")) (ELam ((PVar "derives")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "pure") (ETuple (EVar "vs") (EVar "derives"))))))))))))))))
(DFunDef false "dataBodyFor" (PWild PWild) (EApp (EMethodRef "pure") (ETuple (EListLit) (EListLit))))
(DTypeSig false "dataAfterEq" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "DeriveRef")))))))
(DFunDef false "dataAfterEq" ((PVar "tyName") (PCon "TIndent")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "optPipe")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "dataVariantsN") (EVar "tyName"))) (ELam ((PVar "vs")) (EApp (EApp (EMethodRef "andThen") (EVar "derivingClause")) (ELam ((PVar "derives")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "pure") (ETuple (EVar "vs") (EVar "derives"))))))))))))))))))
(DFunDef false "dataAfterEq" ((PVar "tyName") PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "dataVariantsN") (EVar "tyName"))) (ELam ((PVar "vs")) (EApp (EMethodRef "pure") (ETuple (EVar "vs") (EListLit))))))
(DTypeSig false "optPipe" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "optPipe" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "optPipeFor") (EVar "t")))))
(DTypeSig false "optPipeFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "optPipeFor" ((PCon "TPipe")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "pure") (ELit LUnit)))))
(DFunDef false "optPipeFor" (PWild) (EApp (EMethodRef "pure") (ELit LUnit)))
(DTypeSig false "dataVariantsN" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Variant")))))
(DFunDef false "dataVariantsN" ((PVar "tyName")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dataVariantsNFor") (EVar "tyName")) (EVar "t")))))
(DTypeSig false "dataVariantsNFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Variant"))))))
(DFunDef false "dataVariantsNFor" ((PVar "tyName") (PCon "TLBrace")) (EApp (EApp (EMethodRef "andThen") (EVar "parseNamedFields")) (ELam ((PVar "fields")) (EApp (EMethodRef "pure") (EListLit (EApp (EApp (EVar "Variant") (EVar "tyName")) (EApp (EApp (EVar "ConNamed") (EVar "fields")) (EVar "True"))))))))
(DFunDef false "dataVariantsNFor" (PWild PWild) (EVar "dataVariants"))
(DTypeSig false "dataVariants" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Variant"))))
(DFunDef false "dataVariants" () (EApp (EApp (EMethodRef "andThen") (EVar "parseVariant")) (ELam ((PVar "v")) (EApp (EApp (EMethodRef "andThen") (EVar "variantsRest")) (ELam ((PVar "rest")) (EApp (EMethodRef "pure") (EBinOp "::" (EVar "v") (EVar "rest"))))))))
(DTypeSig false "variantsRest" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Variant"))))
(DFunDef false "variantsRest" () (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "variantsRestFor") (EVar "t")))))))
(DTypeSig false "variantsRestFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Variant")))))
(DFunDef false "variantsRestFor" ((PCon "TPipe")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseVariant")) (ELam ((PVar "v")) (EApp (EApp (EMethodRef "andThen") (EVar "variantsRest")) (ELam ((PVar "rest")) (EApp (EMethodRef "pure") (EBinOp "::" (EVar "v") (EVar "rest"))))))))))
(DFunDef false "variantsRestFor" (PWild) (EApp (EMethodRef "pure") (EListLit)))
(DTypeSig false "parseVariant" (TyApp (TyCon "Parser") (TyCon "Variant")))
(DFunDef false "parseVariant" () (EApp (EApp (EMethodRef "andThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EVar "parsePayload")) (ELam ((PVar "payload")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "Variant") (EVar "name")) (EVar "payload"))))))))
(DTypeSig false "parsePayload" (TyApp (TyCon "Parser") (TyCon "ConPayload")))
(DFunDef false "parsePayload" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "payloadFor") (EVar "t")))))
(DTypeSig false "payloadFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "ConPayload"))))
(DFunDef false "payloadFor" ((PCon "TLBrace")) (EVar "parseNamedPayload"))
(DFunDef false "payloadFor" (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "tys")) (EApp (EMethodRef "pure") (EApp (EVar "ConPos") (EVar "tys"))))))
(DTypeSig false "parseNamedPayload" (TyApp (TyCon "Parser") (TyCon "ConPayload")))
(DFunDef false "parseNamedPayload" () (EApp (EApp (EMethodRef "andThen") (EVar "parseNamedFields")) (ELam ((PVar "fields")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "ConNamed") (EVar "fields")) (EVar "False"))))))
(DTypeSig false "parseNamedFields" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Field"))))
(DFunDef false "parseNamedFields" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "parseField")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "fields")) (EApp (EApp (EMethodRef "andThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EMethodRef "pure") (EVar "fields")))))))))))
(DTypeSig false "parseField" (TyApp (TyCon "Parser") (TyCon "Field")))
(DFunDef false "parseField" () (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseTy")) (ELam ((PVar "t")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "Field") (EVar "name")) (EVar "t"))))))))))
(DTypeSig false "derivingClause" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DeriveRef"))))
(DFunDef false "derivingClause" () (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "derivingFor") (EVar "t")))))))
(DTypeSig false "derivingFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DeriveRef")))))
(DFunDef false "derivingFor" ((PCon "TDeriving")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "sepBy1") (EVar "derivedNameP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "names")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "pure") (EVar "names")))))))))))
(DFunDef false "derivingFor" (PWild) (EApp (EMethodRef "pure") (EListLit)))
(DTypeSig false "derivedNameP" (TyApp (TyCon "Parser") (TyCon "DeriveRef")))
(DFunDef false "derivedNameP" () (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "andThen") (EVar "upperNameP")) (ELam ((PVar "n")) (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "DeriveRef") (EVar "n")) (EApp (EVar "Some") (EApp (EApp (EVar "locOfSpan") (EVar "s")) (EVar "q"))))))))))))
(DTypeSig false "parseBody" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBody" () (EApp (EApp (EVar "orElse#shadow") (EVar "indentedBody")) (EVar "parseBodyExpr")))
(DTypeSig false "parseBodyExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBodyExpr" () (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EVar "orElse#shadow") (EApp (EVar "whereEol") (EVar "e"))) (EApp (EApp (EVar "orElse#shadow") (EApp (EVar "whereTail") (EVar "e"))) (EApp (EMethodRef "pure") (EVar "e")))))))
(DTypeSig false "whereEol" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "whereEol" ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TWhere"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseWhereBindings")) (ELam ((PVar "binds")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EVar "binds"))) (EVar "e"))))))))))))
(DTypeSig false "whereTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "whereTail" ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TWhere"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseWhereBindings")) (ELam ((PVar "binds")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EVar "binds"))) (EVar "e"))))))))))))))))))
(DTypeSig false "parseWhereBindings" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "parseWhereBindings" () (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "whereBindingsLoop"))))
(DTypeSig false "whereBindingsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "whereBindingsLoop" () (EApp (EApp (EVar "orElse#shadow") (EVar "whereBindingsCons")) (EApp (EMethodRef "pure") (EListLit))))
(DTypeSig false "whereBindingsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "whereBindingsCons" () (EApp (EApp (EMethodRef "andThen") (EVar "parseWhereBinding")) (ELam ((PVar "b")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "whereBindingsLoop")) (ELam ((PVar "rest")) (EApp (EMethodRef "pure") (EBinOp "::" (EVar "b") (EVar "rest"))))))))))
(DTypeSig false "parseWhereBinding" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))
(DFunDef false "parseWhereBinding" () (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "whereBindRest") (EVar "name")) (EVar "pats")) (EVar "t")))))))))
(DTypeSig false "whereBindRest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "whereBindRest" ((PVar "name") (PList) (PCon "TColon")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "body")) (EApp (EMethodRef "pure") (ETuple (EVar "name") (EListLit) (EApp (EApp (EVar "EAnnot") (EVar "body")) (EVar "ty")))))))))))))
(DFunDef false "whereBindRest" ((PVar "name") (PVar "pats") (PCon "TEqual")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "body")) (EApp (EMethodRef "pure") (ETuple (EVar "name") (EVar "pats") (EVar "body"))))))))
(DFunDef false "whereBindRest" ((PVar "name") (PVar "pats") (PCon "TIndent")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseGuardArms")) (ELam ((PVar "arms")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "pure") (ETuple (EVar "name") (EVar "pats") (EApp (EVar "EGuards") (EVar "arms")))))))))))
(DFunDef false "whereBindRest" ((PVar "name") (PVar "pats") (PCon "TPipe")) (EApp (EApp (EMethodRef "andThen") (EVar "parseGuardArm")) (ELam ((PVar "arm")) (EApp (EMethodRef "pure") (ETuple (EVar "name") (EVar "pats") (EApp (EVar "EGuards") (EListLit (EVar "arm"))))))))
(DFunDef false "whereBindRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected where binding body"))))
(DTypeSig false "coalesceClauses" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "coalesceClauses" ((PList)) (EListLit))
(DFunDef false "coalesceClauses" ((PCons (PTuple (PVar "name") (PVar "ps") (PVar "b")) (PVar "rest"))) (EApp (EApp (EApp (EVar "coalesceGo") (EVar "name")) (EListLit (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "b")))) (EVar "rest")))
(DTypeSig false "coalesceGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "LetBind"))))))
(DFunDef false "coalesceGo" ((PVar "name") (PVar "acc") (PList)) (EListLit (EApp (EApp (EVar "LetBind") (EVar "name")) (EApp (EVar "reverseL") (EVar "acc")))))
(DFunDef false "coalesceGo" ((PVar "name") (PVar "acc") (PCons (PTuple (PVar "n") (PVar "ps") (PVar "b")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "coalesceStep") (EVar "name")) (EVar "acc")) (EVar "n")) (EVar "ps")) (EVar "b")) (EVar "rest")))
(DTypeSig false "coalesceStep" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "List") (TyCon "LetBind")))))))))
(DFunDef false "coalesceStep" ((PVar "name") (PVar "acc") (PVar "n") (PVar "ps") (PVar "b") (PVar "rest")) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EApp (EVar "coalesceGo") (EVar "name")) (EBinOp "::" (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "b")) (EVar "acc"))) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "LetBind") (EVar "name")) (EApp (EVar "reverseL") (EVar "acc"))) (EApp (EApp (EApp (EVar "coalesceGo") (EVar "n")) (EListLit (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "b")))) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "indentedBody" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "indentedBody" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseStmts")) (ELam ((PVar "stmts")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "blockOrExpr") (EVar "stmts"))))))))))
(DTypeSig false "blockOrExpr" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Expr")))
(DFunDef false "blockOrExpr" ((PList (PCon "DoExpr" (PVar "e")))) (EVar "e"))
(DFunDef false "blockOrExpr" ((PVar "stmts")) (EApp (EVar "EBlock") (EVar "stmts")))
(DTypeSig false "parseDo" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseDo" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDo"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseStmts")) (ELam ((PVar "stmts")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "pure") (EApp (EVar "EDo") (EVar "stmts"))))))))))))
(DTypeSig false "parseRhsExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseRhsExpr" () (EApp (EApp (EVar "orElse#shadow") (EVar "parseBracketBlock")) (EVar "parseExpr")))
(DTypeSig false "parseStmts" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "parseStmts" () (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "stmtsLoop"))))
(DTypeSig false "stmtsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "stmtsLoop" () (EApp (EApp (EVar "orElse#shadow") (EVar "stmtsCons")) (EApp (EMethodRef "pure") (EListLit))))
(DTypeSig false "stmtsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "stmtsCons" () (EApp (EApp (EMethodRef "andThen") (EVar "parseStmt")) (ELam ((PVar "ss")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "stmtsLoop")) (ELam ((PVar "rest")) (EApp (EMethodRef "pure") (EBinOp "++" (EVar "ss") (EVar "rest"))))))))))
(DTypeSig false "parseStmt" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "parseStmt" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "stmtFor") (EVar "t")))))
(DTypeSig false "stmtFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "stmtFor" ((PCon "TLet")) (EApp (EApp (EMethodRef "andThen") (EVar "parseLetStmt")) (ELam ((PVar "s")) (EApp (EMethodRef "pure") (EListLit (EVar "s"))))))
(DFunDef false "stmtFor" (PWild) (EVar "parseExprStmt"))
(DTypeSig false "parseLetStmt" (TyApp (TyCon "Parser") (TyCon "DoStmt")))
(DFunDef false "parseLetStmt" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "letKind") (EVar "t")))))))
(DTypeSig false "letKind" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))
(DFunDef false "letKind" ((PCon "TMut")) (EApp (EVar "failP") (EVar "letMutRemovedMsg")))
(DFunDef false "letKind" ((PCon "TRec")) (EVar "letRecStmt"))
(DFunDef false "letKind" ((PCon "TIdent" (PVar "name"))) (EApp (EVar "letIdent") (EVar "name")))
(DFunDef false "letKind" (PWild) (EVar "letPat"))
(DTypeSig false "letRecStmt" (TyApp (TyCon "Parser") (TyCon "DoStmt")))
(DFunDef false "letRecStmt" () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TRec"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "letFunTailFor") (EVar "name")) (EVar "pats")) (EVar "e1")) (EVar "t")))))))))))))))
(DTypeSig false "letIdent" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))
(DFunDef false "letIdent" ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "letIdentBody") (EVar "name")) (EVar "pats")) (EVar "t")))))))))
(DTypeSig false "letIdentBody" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))))
(DFunDef false "letIdentBody" ((PVar "name") (PList) (PCon "TColon")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EApp (EVar "letIdentRest") (EVar "name")) (EListLit)) (EApp (EApp (EVar "EAnnot") (EVar "e1")) (EVar "ty"))))))))))))
(DFunDef false "letIdentBody" ((PVar "name") (PVar "pats") PWild) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EApp (EVar "letIdentRest") (EVar "name")) (EVar "pats")) (EVar "e1")))))))
(DTypeSig false "letIdentRest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))))
(DFunDef false "letIdentRest" ((PVar "name") (PList) (PVar "e1")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "letTailFor") (EApp (EVar "PVar") (EVar "name"))) (EVar "e1")) (EVar "t")))))
(DFunDef false "letIdentRest" ((PVar "name") (PVar "pats") (PVar "e1")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "letFunTailFor") (EVar "name")) (EVar "pats")) (EVar "e1")) (EVar "t")))))
(DTypeSig false "letFunTailFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt")))))))
(DFunDef false "letFunTailFor" ((PVar "name") (PVar "pats") (PVar "e1") (PCon "TIn")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EMethodRef "pure") (EApp (EVar "DoExpr") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "False")) (EVar "True")) (EApp (EVar "PVar") (EVar "name"))) (EApp (EApp (EVar "curryLam") (EVar "pats")) (EVar "e1"))) (EVar "e2")))))))))
(DFunDef false "letFunTailFor" ((PVar "name") (PVar "pats") (PVar "e1") PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "False")) (EVar "True")) (EApp (EVar "PVar") (EVar "name"))) (EApp (EApp (EVar "curryLam") (EVar "pats")) (EVar "e1")))))
(DTypeSig false "letPat" (TyApp (TyCon "Parser") (TyCon "DoStmt")))
(DFunDef false "letPat" () (EApp (EApp (EMethodRef "andThen") (EVar "parsePat")) (ELam ((PVar "pat")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "letTailFor") (EVar "pat")) (EVar "e1")) (EVar "t")))))))))))
(DTypeSig false "letTailFor" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))))
(DFunDef false "letTailFor" ((PVar "pat") (PVar "e1") (PCon "TIn")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EMethodRef "pure") (EApp (EVar "DoExpr") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "False")) (EVar "False")) (EVar "pat")) (EVar "e1")) (EVar "e2")))))))))
(DFunDef false "letTailFor" ((PVar "pat") (PVar "e1") PWild) (EApp (EMethodRef "pure") (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "False")) (EVar "False")) (EVar "pat")) (EVar "e1"))))
(DTypeSig false "curryLam" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "curryLam" ((PList) (PVar "body")) (EVar "body"))
(DFunDef false "curryLam" ((PCons (PVar "p") (PVar "ps")) (PVar "body")) (EApp (EApp (EVar "ELam") (EListLit (EVar "p"))) (EApp (EApp (EVar "curryLam") (EVar "ps")) (EVar "body"))))
(DTypeSig false "parseExprStmt" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "parseExprStmt" () (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "exprStmtFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "exprStmtFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "exprStmtFor" ((PVar "e") (PCon "TLArrow")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "rhs")) (EApp (EMethodRef "pure") (EApp (EApp (EVar "bindStmts") (EVar "e")) (EVar "rhs"))))))))
(DFunDef false "exprStmtFor" ((PVar "e") (PCon "TEqual")) (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "andThen") (EVar "parseExpr")) (ELam ((PVar "rhs")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "assignFromLhs") (EVar "e")) (EVar "rhs"))) (ELam ((PVar "s")) (EApp (EMethodRef "pure") (EListLit (EVar "s"))))))))))
(DFunDef false "exprStmtFor" ((PVar "e") PWild) (EApp (EMethodRef "pure") (EListLit (EApp (EVar "DoExpr") (EVar "e")))))
(DTypeSig false "bindStmts" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "bindStmts" ((PVar "lhs") (PVar "rhs")) (EMatch (EApp (EVar "stripLoc") (EVar "lhs")) (arm (PCon "EAnnot" (PVar "inner") (PVar "ty")) () (EApp (EApp (EApp (EVar "bindAnnot") (EVar "inner")) (EVar "ty")) (EVar "rhs"))) (arm PWild () (EListLit (EApp (EApp (EVar "DoBind") (EApp (EVar "exprToPat") (EVar "lhs"))) (EVar "rhs"))))))
(DTypeSig false "bindAnnot" (TyFun (TyCon "Expr") (TyFun (TyCon "Ty") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "bindAnnot" ((PVar "inner") (PVar "ty") (PVar "rhs")) (EMatch (EApp (EVar "stripLoc") (EVar "inner")) (arm (PCon "EVar" (PVar "x")) () (EListLit (EApp (EApp (EVar "DoBind") (EApp (EVar "PVar") (EVar "x"))) (EVar "rhs")) (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "False")) (EVar "False")) (EApp (EVar "PVar") (EVar "x"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "EVar") (EVar "x"))) (EVar "ty"))))) (arm (PVar "other") () (EListLit (EApp (EApp (EVar "DoBind") (EApp (EVar "exprToPat") (EVar "other"))) (EVar "rhs"))))))
(DTypeSig false "assignFromLhs" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "DoStmt")))))
(DFunDef false "assignFromLhs" ((PVar "lhs") (PVar "rhs")) (EMatch (EApp (EVar "flattenFieldPath") (EVar "lhs")) (arm (PCon "Some" (PTuple (PVar "x") (PList))) () (EApp (EMethodRef "pure") (EApp (EApp (EVar "DoAssign") (EVar "x")) (EVar "rhs")))) (arm (PCon "Some" (PTuple (PVar "x") (PVar "fs"))) () (EApp (EMethodRef "pure") (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EVar "rhs")))) (arm (PCon "None") () (EApp (EVar "failP") (ELit (LString "invalid assignment target in do-block"))))))
(DTypeSig false "flattenFieldPath" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "flattenFieldPath" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "flattenFieldPath") (EVar "e")))
(DFunDef false "flattenFieldPath" ((PCon "EVar" (PVar "x"))) (EApp (EVar "Some") (ETuple (EVar "x") (EListLit))))
(DFunDef false "flattenFieldPath" ((PCon "EFieldAccess" (PVar "inner") (PVar "f") PWild)) (EApp (EApp (EVar "fieldPathExtend") (EApp (EVar "flattenFieldPath") (EVar "inner"))) (EVar "f")))
(DFunDef false "flattenFieldPath" (PWild) (EVar "None"))
(DTypeSig false "fieldPathExtend" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "fieldPathExtend" ((PCon "Some" (PTuple (PVar "x") (PVar "fs"))) (PVar "f")) (EApp (EVar "Some") (ETuple (EVar "x") (EBinOp "++" (EVar "fs") (EListLit (EVar "f"))))))
(DFunDef false "fieldPathExtend" ((PCon "None") PWild) (EVar "None"))
(DTypeSig false "skipNoise" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "skipNoise" () (EApp (EApp (EMethodRef "andThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "skipNoiseFor") (EVar "t")))))
(DTypeSig false "skipNoiseFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "skipNoiseFor" ((PCon "TNewline")) (EVar "afterNoise"))
(DFunDef false "skipNoiseFor" ((PCon "TIndent")) (EVar "afterNoise"))
(DFunDef false "skipNoiseFor" ((PCon "TDedent")) (EVar "afterNoise"))
(DFunDef false "skipNoiseFor" (PWild) (EApp (EMethodRef "pure") (ELit LUnit)))
(DTypeSig false "afterNoise" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "afterNoise" () (EApp (EApp (EMethodRef "andThen") (EVar "advance")) (ELam (PWild) (EVar "skipNoise"))))
(DTypeSig false "declThenNoise" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "declThenNoise" () (EApp (EApp (EMethodRef "andThen") (EVar "parseDecl")) (ELam ((PVar "d")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EMethodRef "pure") (EVar "d")))))))
(DTypeSig false "parseProgram" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parseProgram" () (EApp (EApp (EMethodRef "andThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EVar "many") (EVar "declThenNoise")))))
(DData Public "DeclPos" () ((variant "DeclPos" (ConPos (TyCon "Int") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Public "Positions" () ((variant "Positions" (ConPos (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DTypeSig true "positionsDecls" (TyFun (TyCon "Positions") (TyApp (TyCon "List") (TyCon "DeclPos"))))
(DFunDef false "positionsDecls" ((PCon "Positions" (PVar "ds") PWild PWild PWild)) (EVar "ds"))
(DTypeSig true "positionsVariantLines" (TyFun (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "positionsVariantLines" ((PCon "Positions" PWild (PVar "vs") PWild PWild)) (EVar "vs"))
(DTypeSig true "positionsLastContentLine" (TyFun (TyCon "Positions") (TyCon "Int")))
(DFunDef false "positionsLastContentLine" ((PCon "Positions" PWild PWild (PVar "l") PWild)) (EVar "l"))
(DTypeSig true "positionsChainLines" (TyFun (TyCon "Positions") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "positionsChainLines" ((PCon "Positions" PWild PWild PWild (PVar "cl"))) (EVar "cl"))
(DTypeSig true "declPosLine" (TyFun (TyCon "DeclPos") (TyCon "Int")))
(DFunDef false "declPosLine" ((PCon "DeclPos" (PVar "l") PWild PWild PWild)) (EVar "l"))
(DTypeSig true "declPosEndLine" (TyFun (TyCon "DeclPos") (TyCon "Int")))
(DFunDef false "declPosEndLine" ((PCon "DeclPos" PWild (PVar "e") PWild PWild)) (EVar "e"))
(DTypeSig true "declPosNameLoc" (TyFun (TyCon "DeclPos") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "declPosNameLoc" ((PCon "DeclPos" PWild PWild (PVar "nl") PWild)) (EVar "nl"))
(DTypeSig true "declPosChildLocs" (TyFun (TyCon "DeclPos") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "declPosChildLocs" ((PCon "DeclPos" PWild PWild PWild (PVar "cs"))) (EVar "cs"))
(DTypeSig false "declWithSpan" (TyApp (TyCon "Parser") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "declWithSpan" () (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "andThen") (EVar "parseDecl")) (ELam ((PVar "d")) (EApp (EApp (EMethodRef "andThen") (EVar "getPos")) (ELam ((PVar "e")) (EApp (EMethodRef "pure") (ETuple (EVar "d") (EVar "s") (EVar "e"))))))))))
(DTypeSig false "spanDeclThenNoise" (TyApp (TyCon "Parser") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "spanDeclThenNoise" () (EApp (EApp (EMethodRef "andThen") (EVar "declWithSpan")) (ELam ((PVar "ds")) (EApp (EApp (EMethodRef "andThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EMethodRef "pure") (EVar "ds")))))))
(DTypeSig false "programWithSpans" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "programWithSpans" () (EApp (EApp (EMethodRef "andThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EVar "many") (EVar "spanDeclThenNoise")))))
(DTypeSig false "isNoiseTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isNoiseTok" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "isNoiseTok" ((PCon "TIndent")) (EVar "True"))
(DFunDef false "isNoiseTok" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "isNoiseTok" (PWild) (EVar "False"))
(DTypeSig false "lastContentIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "lastContentIdx" ((PVar "toks") (PVar "s") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (EVar "s")) (EVar "s") (EIf (EApp (EVar "isNoiseTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EVar "lastContentIdx") (EVar "toks")) (EVar "s")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lineAt" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lineAt" ((PVar "lines") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "lines"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "lines")) (EIf (EVar "otherwise") (ELit (LInt 0)) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "locOfSpanWith" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Loc"))))))
(DFunDef false "locOfSpanWith" ((PVar "offs") (PVar "lineStarts") (PVar "startIdx") (PVar "endIdx")) (EBlock (DoLet false false (PVar "lastIdx") (EIf (EBinOp ">" (EVar "endIdx") (EVar "startIdx")) (EBinOp "-" (EVar "endIdx") (ELit (LInt 1))) (EVar "startIdx"))) (DoLet false false (PVar "startOff") (EApp (EApp (EVar "tokOffsetAtArr") (EVar "offs")) (EVar "startIdx"))) (DoLet false false (PVar "endOff") (EApp (EApp (EVar "tokEndOffsetAtArr") (EVar "offs")) (EVar "lastIdx"))) (DoExpr (EMatch (EApp (EApp (EVar "offsetToLineColFast") (EVar "lineStarts")) (EVar "startOff")) (arm (PTuple (PVar "sl") (PVar "sc")) () (EMatch (EApp (EApp (EVar "offsetToLineColFast") (EVar "lineStarts")) (EVar "endOff")) (arm (PTuple (PVar "el") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")))))))))
(DTypeSig false "tokOffsetAtArr" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "tokOffsetAtArr" ((PVar "offs") (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs")))) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs"))) (ELit (LInt 0))))
(DTypeSig false "tokEndOffsetAtArr" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "tokEndOffsetAtArr" ((PVar "offs") (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs")))) (EApp (EVar "snd") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs"))) (ELit (LInt 0))))
(DTypeSig false "isLeadingModifierTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLeadingModifierTok" ((PCon "TPublic")) (EVar "True"))
(DFunDef false "isLeadingModifierTok" ((PCon "TExport")) (EVar "True"))
(DFunDef false "isLeadingModifierTok" ((PCon "TDefault")) (EVar "True"))
(DFunDef false "isLeadingModifierTok" ((PVar "t")) (EApp (EVar "isNoiseTok") (EVar "t")))
(DTypeSig false "skipLeadingModifiers" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "skipLeadingModifiers" ((PVar "toks") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EVar "isLeadingModifierTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")))) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isTStringTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isTStringTok" ((PCon "TString" PWild)) (EVar "True"))
(DFunDef false "isTStringTok" (PWild) (EVar "False"))
(DTypeSig false "tokIdxOrNone" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "tokIdxOrNone" ((PVar "toks") (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks")))) (EApp (EVar "Some") (EVar "i")) (EVar "None")))
(DTypeSig false "declNameTokIdxAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DAttrib" PWild (PVar "inner")) (PVar "i")) (EBlock (DoLet false false (PVar "i1") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (DoLet false false (PVar "i2") (EBinOp "+" (EVar "i1") (ELit (LInt 1)))) (DoLet false false (PVar "i3") (EIf (EBinOp "&&" (EBinOp "<" (EVar "i2") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EVar "isTStringTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i2")) (EVar "toks")))) (EBinOp "+" (EVar "i2") (ELit (LInt 1))) (EVar "i2"))) (DoExpr (EApp (EApp (EApp (EVar "declNameTokIdx") (EVar "toks")) (EVar "inner")) (EVar "i3")))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DTypeSig" PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EVar "i")))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DFunDef" PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EVar "i")))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DExtern" PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DData" PWild PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DEffect" PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DProp" PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DTest" PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DBench" PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PRec "DInterface" () true) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DTypeAlias" PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DNewtype" PWild PWild PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DLetGroup" PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PRec "DImpl" () true) (PVar "i")) (EVar "None"))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DUse" PWild PWild PWild) (PVar "i")) (EVar "None"))
(DTypeSig false "declNameTokIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "declNameTokIdx" ((PVar "toks") (PVar "d") (PVar "i")) (EApp (EApp (EApp (EVar "declNameTokIdxAt") (EVar "toks")) (EVar "d")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EVar "i"))))
(DTypeSig false "declNameSpanOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "declNameSpanOf" ((PVar "toks") (PVar "offs") (PVar "lineStarts") (PTuple (PVar "d") (PVar "s") (PVar "_e"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "nameIdx")) (EApp (EApp (EApp (EApp (EVar "locOfSpanWith") (EVar "offs")) (EVar "lineStarts")) (EVar "nameIdx")) (EBinOp "+" (EVar "nameIdx") (ELit (LInt 1)))))) (EApp (EApp (EApp (EVar "declNameTokIdx") (EVar "toks")) (EVar "d")) (EVar "s"))))
(DTypeSig false "innerDeclOf" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "innerDeclOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "innerDeclOf") (EVar "d")))
(DFunDef false "innerDeclOf" ((PVar "d")) (EVar "d"))
(DTypeSig false "declChildNameIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "declChildNameIdxs" ((PVar "toks") (PTuple (PVar "d") (PVar "s") (PVar "e"))) (EMatch (EApp (EVar "innerDeclOf") (EVar "d")) (arm (PCon "DData" PWild PWild PWild (PVar "variants") PWild) () (EApp (EApp (EApp (EApp (EVar "dataChildIdxs") (EVar "toks")) (EVar "s")) (EVar "e")) (EVar "variants"))) (arm (PRec "DInterface" () true) () (EApp (EApp (EApp (EVar "methodNameIdxs") (EVar "toks")) (EVar "s")) (EVar "e"))) (arm (PRec "DImpl" () true) () (EApp (EApp (EApp (EVar "methodNameIdxs") (EVar "toks")) (EVar "s")) (EVar "e"))) (arm (PCon "DLetGroup" PWild PWild) () (EListLit (EApp (EApp (EApp (EVar "declNameTokIdx") (EVar "toks")) (EVar "d")) (EVar "s")))) (arm PWild () (EListLit))))
(DTypeSig false "variantBoundaryIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "variantBoundaryIdxs" ((PVar "toks") (PVar "s") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EVar "s")) (EVar "e")) (ELit (LInt 0))) (EVar "False")))
(DTypeSig false "variantBoundaryGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "variantBoundaryGo" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryAt") (EVar "toks")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "variantBoundaryAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "variantBoundaryAt" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EBinOp "==" (EVar "t") (EVar "TEqual"))) (EApp (EApp (EApp (EVar "nextSigIsPipe") (EVar "toks")) (EVar "e")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EBinOp "==" (EVar "t") (EVar "TEqual"))) (EBinOp "::" (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EVar "seenEq")) (EBinOp "==" (EVar "t") (EVar "TPipe"))) (EBinOp "::" (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "dataChildIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "dataChildIdxs" ((PVar "toks") (PVar "s") (PVar "e") (PVar "variants")) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "variants")) (EApp (EApp (EApp (EVar "variantBoundaryIdxs") (EVar "toks")) (EVar "s")) (EVar "e"))))
(DTypeSig false "zipVariantIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "zipVariantIdxs" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "zipVariantIdxs" ((PVar "toks") (PVar "e") (PCons (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True"))) (PVar "vs")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "++" (EApp (EApp (EVar "zipFieldIdxs") (EVar "fs")) (EApp (EApp (EApp (EVar "fieldNameIdxsIn") (EVar "toks")) (EBinOp "+" (EVar "b") (ELit (LInt 1)))) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "vs")) (EVar "bs"))))
(DFunDef false "zipVariantIdxs" ((PVar "toks") (PVar "e") (PCons (PCon "Variant" PWild PWild) (PVar "vs")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "::" (EApp (EVar "Some") (EVar "b")) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "vs")) (EVar "bs"))))
(DFunDef false "zipVariantIdxs" ((PVar "toks") (PVar "e") (PCons (PVar "v") (PVar "vs")) (PList)) (EBinOp "++" (EApp (EVar "variantNoneIdxs") (EVar "v")) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "vs")) (EListLit))))
(DTypeSig false "variantNoneIdxs" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "variantNoneIdxs" ((PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True")))) (EApp (EApp (EMethodRef "map") (ELam (PWild) (EVar "None"))) (EVar "fs")))
(DFunDef false "variantNoneIdxs" ((PCon "Variant" PWild PWild)) (EListLit (EVar "None")))
(DTypeSig false "fieldNameIdxsIn" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "fieldNameIdxsIn" ((PVar "toks") (PVar "i") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EVar "i")) (EVar "e")) (ELit (LInt 1))) (EVar "True")))
(DTypeSig false "fieldNameGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "fieldNameGo" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameStep") (EVar "toks")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "atStart")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "fieldNameStep" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "fieldNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 1))) (EBinOp "==" (EVar "t") (EVar "TComma"))) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True")) (EIf (EApp (EVar "isNoiseTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "atStart")) (EIf (EBinOp "&&" (EVar "atStart") (EBinOp "==" (EVar "depth") (ELit (LInt 1)))) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "zipFieldIdxs" (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "zipFieldIdxs" ((PList) PWild) (EListLit))
(DFunDef false "zipFieldIdxs" ((PCons PWild (PVar "fs")) (PCons (PVar "i") (PVar "is"))) (EBinOp "::" (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EVar "zipFieldIdxs") (EVar "fs")) (EVar "is"))))
(DFunDef false "zipFieldIdxs" ((PCons PWild (PVar "fs")) (PList)) (EBinOp "::" (EVar "None") (EApp (EApp (EVar "zipFieldIdxs") (EVar "fs")) (EListLit))))
(DTypeSig false "methodNameIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "methodNameIdxs" ((PVar "toks") (PVar "s") (PVar "e")) (EMatch (EApp (EApp (EApp (EVar "findWhereIdx") (EVar "toks")) (EVar "s")) (EVar "e")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "w")) () (EBlock (DoLet false false (PVar "after") (EApp (EApp (EApp (EVar "skipNewlineToks") (EVar "toks")) (EBinOp "+" (EVar "w") (ELit (LInt 1)))) (EVar "e"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "after") (EVar "e")) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "after")) (EVar "toks")) (EVar "TIndent"))) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "after") (ELit (LInt 1)))) (EVar "e")) (ELit (LInt 1))) (EVar "True")) (EListLit)))))))
(DTypeSig false "findWhereIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "findWhereIdx" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")) (EVar "TWhere")) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "findWhereIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "skipNewlineToks" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipNewlineToks" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EVar "e")) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")) (EVar "TNewline"))) (EApp (EApp (EApp (EVar "skipNewlineToks") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "methodNameGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "methodNameGo" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "methodNameStep") (EVar "toks")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "atStart")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "methodNameStep" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))))))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") PWild (PCon "TIndent")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "False")))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") PWild (PCon "TDedent")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "False")))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") PWild (PCon "TNewline")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EBinOp "==" (EVar "depth") (ELit (LInt 1)))))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart") PWild) (EIf (EBinOp "&&" (EVar "atStart") (EBinOp "==" (EVar "depth") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declChildSpansOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))))))))
(DFunDef false "declChildSpansOf" ((PVar "toks") (PVar "offs") (PVar "lineStarts") (PVar "span")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "idxOpt")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "idx")) (EApp (EApp (EApp (EApp (EVar "locOfSpanWith") (EVar "offs")) (EVar "lineStarts")) (EVar "idx")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))))) (EVar "idxOpt")))) (EApp (EApp (EVar "declChildNameIdxs") (EVar "toks")) (EVar "span"))))
(DTypeSig false "declPosOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyCon "DeclPos")))))))
(DFunDef false "declPosOf" ((PVar "toks") (PVar "lines") (PVar "offs") (PVar "lineStarts") (PTuple (PVar "d") (PVar "s") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DeclPos") (EApp (EApp (EVar "lineAt") (EVar "lines")) (EVar "s"))) (EApp (EApp (EVar "lineAt") (EVar "lines")) (EApp (EApp (EApp (EVar "lastContentIdx") (EVar "toks")) (EVar "s")) (EBinOp "-" (EVar "e") (ELit (LInt 1)))))) (EApp (EApp (EApp (EApp (EVar "declNameSpanOf") (EVar "toks")) (EVar "offs")) (EVar "lineStarts")) (ETuple (EVar "d") (EVar "s") (EVar "e")))) (EApp (EApp (EApp (EApp (EVar "declChildSpansOf") (EVar "toks")) (EVar "offs")) (EVar "lineStarts")) (ETuple (EVar "d") (EVar "s") (EVar "e")))))
(DTypeSig false "variantStartsIn" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "variantStartsIn" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EVar "i")) (EVar "e")) (ELit (LInt 0))) (EVar "False")))
(DTypeSig false "variantStartsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "variantStartsGo" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsAt") (EVar "toks")) (EVar "lines")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "variantStartsAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "variantStartsAt" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EBinOp "==" (EVar "t") (EVar "TEqual"))) (EApp (EApp (EApp (EVar "nextSigIsPipe") (EVar "toks")) (EVar "e")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EBinOp "==" (EVar "t") (EVar "TEqual"))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EVar "seenEq")) (EBinOp "==" (EVar "t") (EVar "TPipe"))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "nextSigIsPipe" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "nextSigIsPipe" ((PVar "toks") (PVar "e") (PVar "j")) (EIf (EBinOp ">=" (EVar "j") (EVar "e")) (EVar "False") (EIf (EApp (EVar "isLayoutTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "toks"))) (EApp (EApp (EApp (EVar "nextSigIsPipe") (EVar "toks")) (EVar "e")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "toks")) (EVar "TPipe")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isLayoutTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLayoutTok" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "isLayoutTok" ((PCon "TIndent")) (EVar "True"))
(DFunDef false "isLayoutTok" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "isLayoutTok" (PWild) (EVar "False"))
(DTypeSig false "isOpenDelim" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isOpenDelim" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLBracketTight")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "isOpenDelim" ((PCon "TLArray")) (EVar "True"))
(DFunDef false "isOpenDelim" (PWild) (EVar "False"))
(DTypeSig false "isCloseDelim" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isCloseDelim" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "isCloseDelim" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "isCloseDelim" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "isCloseDelim" ((PCon "TRArray")) (EVar "True"))
(DFunDef false "isCloseDelim" (PWild) (EVar "False"))
(DTypeSig false "isDataDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isDataDecl" ((PCon "DData" PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "isDataDecl" (PWild) (EVar "False"))
(DTypeSig false "allVariantLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "allVariantLines" ((PVar "toks") (PVar "lines") (PList)) (EListLit))
(DFunDef false "allVariantLines" ((PVar "toks") (PVar "lines") (PCons (PTuple (PVar "d") (PVar "s") (PVar "e")) (PVar "rest"))) (EIf (EApp (EVar "isDataDecl") (EVar "d")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "variantStartsIn") (EVar "toks")) (EVar "lines")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EVar "allVariantLines") (EVar "toks")) (EVar "lines")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "allVariantLines") (EVar "toks")) (EVar "lines")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isContinuationOpStr" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isContinuationOpStr" ((PVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "|>"))) (EBinOp "==" (EVar "op") (ELit (LString ">>")))) (EBinOp "==" (EVar "op") (ELit (LString "<<")))) (EBinOp "==" (EVar "op") (ELit (LString "&&")))) (EBinOp "==" (EVar "op") (ELit (LString "||")))) (EBinOp "==" (EVar "op") (ELit (LString "++")))))
(DTypeSig false "chainOpTokEq" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyCon "Bool"))))
(DFunDef false "chainOpTokEq" ((PLit (LString "&&")) (PCon "TAnd")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "||")) (PCon "TOr")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "|>")) (PCon "TPipeRight")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString ">>")) (PCon "TRCompose")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "<<")) (PCon "TLCompose")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "++")) (PCon "TPlusPlus")) (EVar "True"))
(DFunDef false "chainOpTokEq" (PWild PWild) (EVar "False"))
(DTypeSig false "declChainTopOp" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "declChainTopOp" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declChainTopOp") (EVar "inner")))
(DFunDef false "declChainTopOp" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "bodyChainTopOp") (EVar "body")))
(DFunDef false "declChainTopOp" (PWild) (EVar "None"))
(DTypeSig false "bodyChainTopOp" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "bodyChainTopOp" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "bodyChainTopOp") (EVar "e")))
(DFunDef false "bodyChainTopOp" ((PCon "EBinOp" (PVar "op") PWild PWild PWild)) (EIf (EApp (EVar "isContinuationOpStr") (EVar "op")) (EApp (EVar "Some") (EVar "op")) (EVar "None")))
(DFunDef false "bodyChainTopOp" (PWild) (EVar "None"))
(DTypeSig false "firstContentAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstContentAt" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "e") (EIf (EApp (EVar "isNoiseTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "rhsStartIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "rhsStartIdx" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "e") (EIf (EApp (EVar "isOpenDelim") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isCloseDelim") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")) (EVar "TEqual"))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "chainOperandLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "chainOperandLines" ((PVar "toks") (PVar "lines") (PVar "op") (PVar "rs") (PVar "e")) (EBlock (DoLet false false (PVar "h") (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EVar "rs")) (EVar "e"))) (DoExpr (EIf (EBinOp ">=" (EVar "h") (EVar "e")) (EListLit) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EVar "h")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EVar "rs")) (EVar "e")) (ELit (LInt 0))))))))
(DTypeSig false "chainOpLinesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "chainOpLinesGo" ((PVar "toks") (PVar "lines") (PVar "op") (PVar "i") (PVar "e") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesAt") (EVar "toks")) (EVar "lines")) (EVar "op")) (EVar "i")) (EVar "e")) (EVar "depth")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "chainOpLinesAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "chainOpLinesAt" ((PVar "toks") (PVar "lines") (PVar "op") (PVar "i") (PVar "e") (PVar "depth") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EApp (EVar "chainOpTokEq") (EVar "op")) (EVar "t"))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "declBlockRhs" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "declBlockRhs" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declBlockRhs") (EVar "inner")))
(DFunDef false "declBlockRhs" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "bodyIsBlock") (EVar "body")))
(DFunDef false "declBlockRhs" (PWild) (EVar "False"))
(DTypeSig false "bodyIsBlock" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "bodyIsBlock" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "bodyIsBlock") (EVar "e")))
(DFunDef false "bodyIsBlock" ((PCon "EBlock" PWild)) (EVar "True"))
(DFunDef false "bodyIsBlock" ((PCon "EDo" PWild)) (EVar "True"))
(DFunDef false "bodyIsBlock" (PWild) (EVar "False"))
(DTypeSig false "firstIndentIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstIndentIdx" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "e") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")) (EVar "TIndent")) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstIndentIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "blockStmtLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "blockStmtLines" ((PVar "toks") (PVar "lines") (PVar "rs") (PVar "e")) (EBlock (DoLet false false (PVar "bi") (EApp (EApp (EApp (EVar "firstIndentIdx") (EVar "toks")) (EVar "rs")) (EVar "e"))) (DoExpr (EIf (EBinOp ">=" (EVar "bi") (EVar "e")) (EListLit) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EVar "bi")) (EVar "e")) (ELit (LInt 1))) (EVar "True"))))))
(DTypeSig false "blockStmtGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "blockStmtGo" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "ind") (PVar "atStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EBinOp "<=" (EVar "ind") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtAt") (EVar "toks")) (EVar "lines")) (EVar "i")) (EVar "e")) (EVar "ind")) (EVar "atStart")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "blockStmtAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "blockStmtAt" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "ind") (PVar "atStart") (PVar "t")) (EIf (EBinOp "==" (EVar "t") (EVar "TIndent")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "ind") (ELit (LInt 1)))) (EVar "False")) (EIf (EBinOp "==" (EVar "t") (EVar "TDedent")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "ind") (ELit (LInt 1)))) (EVar "False")) (EIf (EBinOp "==" (EVar "t") (EVar "TNewline")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "ind")) (EBinOp "==" (EVar "ind") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EVar "atStart") (EBinOp "==" (EVar "ind") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EVar "i")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "ind")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "ind")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "declChainLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "declChainLines" ((PVar "toks") (PVar "lines") (PVar "d") (PVar "s") (PVar "e")) (EMatch (EApp (EVar "declChainTopOp") (EVar "d")) (arm (PCon "Some" (PVar "op")) () (EApp (EApp (EApp (EApp (EApp (EVar "chainOperandLines") (EVar "toks")) (EVar "lines")) (EVar "op")) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EVar "s")) (EVar "e")) (ELit (LInt 0)))) (EVar "e"))) (arm (PCon "None") () (EIf (EApp (EVar "declBlockRhs") (EVar "d")) (EApp (EApp (EApp (EApp (EVar "blockStmtLines") (EVar "toks")) (EVar "lines")) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EVar "s")) (EVar "e")) (ELit (LInt 0)))) (EVar "e")) (EListLit)))))
(DTypeSig false "allChainLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "allChainLines" ((PVar "toks") (PVar "lines") (PList)) (EListLit))
(DFunDef false "allChainLines" ((PVar "toks") (PVar "lines") (PCons (PTuple (PVar "d") (PVar "s") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "declChainLines") (EVar "toks")) (EVar "lines")) (EVar "d")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EVar "allChainLines") (EVar "toks")) (EVar "lines")) (EVar "rest"))))
(DTypeSig false "lastContentLineOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyCon "Int")))))
(DFunDef false "lastContentLineOf" ((PVar "toks") (PVar "lines") (PVar "spans")) (EApp (EApp (EApp (EApp (EVar "lastContentLineGo") (EVar "toks")) (EVar "lines")) (EVar "spans")) (ELit (LInt 0))))
(DTypeSig false "lastContentLineGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "lastContentLineGo" ((PVar "toks") (PVar "lines") (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lastContentLineGo" ((PVar "toks") (PVar "lines") (PCons (PTuple PWild (PVar "s") (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "lastContentLineGo") (EVar "toks")) (EVar "lines")) (EVar "rest")) (EApp (EApp (EVar "lineAt") (EVar "lines")) (EApp (EApp (EApp (EVar "lastContentIdx") (EVar "toks")) (EVar "s")) (EBinOp "-" (EVar "e") (ELit (LInt 1)))))))
(DTypeSig true "parseWithPositions" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))))
(DFunDef false "parseWithPositions" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "Some" (PVar "r")) () (EVar "r")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "parse error"))))))
(DTypeSig true "parseWithPositionsLocated" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))))
(DFunDef false "parseWithPositionsLocated" ((PVar "src")) (EApp (EVar "parseWithPositions") (EVar "src")))
(DTypeSig true "parseWithPositionsOpt" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")))))
(DFunDef false "parseWithPositionsOpt" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithLines") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "lineList")) () (EBlock (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EVar "tokList"))) (DoLet false false (PVar "lines") (EApp (EVar "arrayFromList") (EVar "lineList"))) (DoExpr (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple PWild (PVar "offPairList")) () (EBlock (DoLet false false (PVar "offs") (EApp (EVar "arrayFromList") (EVar "offPairList"))) (DoLet false false (PVar "nameLineStarts") (EApp (EVar "lineStartsOf") (EVar "src"))) (DoLet false false PWild (EApp (EApp (EVar "setLocState") (EVar "src")) (EVar "offs"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "runP") (EVar "programWithSpans")) (EVar "toks")) (ELit (LInt 0))) (arm (PCon "PErr" PWild PWild) () (EVar "None")) (arm (PCon "PFatal" PWild PWild) () (EVar "None")) (arm (PCon "POk" (PVar "spans") (PVar "pos")) () (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos")) (EVar "TEof")) (EBlock (DoLet false false (PVar "decls") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "d") (PVar "_s") (PVar "_e"))) (EVar "d"))) (EVar "spans"))) (DoLet false false (PVar "dps") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "declPosOf") (EVar "toks")) (EVar "lines")) (EVar "offs")) (EVar "nameLineStarts"))) (EVar "spans"))) (DoLet false false (PVar "vls") (EApp (EApp (EApp (EVar "allVariantLines") (EVar "toks")) (EVar "lines")) (EVar "spans"))) (DoLet false false (PVar "lcl") (EApp (EApp (EApp (EVar "lastContentLineOf") (EVar "toks")) (EVar "lines")) (EVar "spans"))) (DoLet false false (PVar "cls") (EApp (EApp (EApp (EVar "allChainLines") (EVar "toks")) (EVar "lines")) (EVar "spans"))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "decls") (EApp (EApp (EApp (EApp (EVar "Positions") (EVar "dps")) (EVar "vls")) (EVar "lcl")) (EVar "cls")))))) (EVar "None")))))))))))))
(DTypeSig false "resultDecls" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "PR") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "resultDecls" (PWild (PCon "PErr" PWild PWild)) (EApp (EVar "panic") (ELit (LString "parse error"))))
(DFunDef false "resultDecls" (PWild (PCon "PFatal" PWild PWild)) (EApp (EVar "panic") (ELit (LString "parse error"))))
(DFunDef false "resultDecls" ((PVar "toks") (PCon "POk" (PVar "ds") (PVar "pos"))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos")) (EVar "TEof")) (EVar "ds") (EIf (EVar "otherwise") (EApp (EVar "panic") (ELit (LString "parse error"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "parse" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parse" ((PVar "src")) (EBlock (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EApp (EVar "tokenize") (EVar "src")))) (DoExpr (EMatch (EApp (EApp (EVar "firstLexError") (EVar "toks")) (ELit (LInt 0))) (arm (PCon "Some" (PTuple PWild (PVar "msg"))) () (EApp (EVar "panic") (EVar "msg"))) (arm (PCon "None") () (EApp (EApp (EVar "resultDecls") (EVar "toks")) (EApp (EApp (EApp (EVar "runP") (EVar "parseProgram")) (EVar "toks")) (ELit (LInt 0)))))))))
(DTypeSig true "parseLocated" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parseLocated" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "offPairs")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "setLocState") (EVar "src")) (EApp (EVar "arrayFromList") (EVar "offPairs")))) (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EVar "tokList"))) (DoExpr (EApp (EApp (EVar "resultDecls") (EVar "toks")) (EApp (EApp (EApp (EVar "runP") (EVar "parseProgram")) (EVar "toks")) (ELit (LInt 0)))))))))
(DData Public "ParseError" () ((variant "ParseError" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "String")))) ())
(DTypeSig true "parseErrorLine" (TyFun (TyCon "ParseError") (TyCon "Int")))
(DFunDef false "parseErrorLine" ((PCon "ParseError" (PVar "l") PWild PWild)) (EVar "l"))
(DTypeSig true "parseErrorCol" (TyFun (TyCon "ParseError") (TyCon "Int")))
(DFunDef false "parseErrorCol" ((PCon "ParseError" PWild (PVar "c") PWild)) (EVar "c"))
(DTypeSig true "parseErrorMessage" (TyFun (TyCon "ParseError") (TyCon "String")))
(DFunDef false "parseErrorMessage" ((PCon "ParseError" PWild PWild (PVar "m"))) (EVar "m"))
(DTypeSig false "offsetAt" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "offsetAt" ((PVar "offs") (PVar "srcLen") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs")) (EIf (EVar "otherwise") (EVar "srcLen") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "locateOffset" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "locateOffset" ((PVar "toks") (PVar "offs") (PVar "srcLen") (PVar "pos")) (EIf (EBinOp ">=" (EVar "pos") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "srcLen") (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos")) (EVar "TEof")) (EVar "srcLen") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "offsetAt") (EVar "offs")) (EVar "srcLen")) (EVar "pos")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "resultDeclsResult" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "PR") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "resultDeclsResult" ((PVar "src") (PVar "toks") (PVar "offs") (PVar "srcLen") (PCon "PErr" (PVar "msg") (PVar "pos"))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "msg")) (EVar "pos"))))
(DFunDef false "resultDeclsResult" ((PVar "src") (PVar "toks") (PVar "offs") (PVar "srcLen") (PCon "PFatal" (PVar "msg") (PVar "pos"))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "msg")) (EVar "pos"))))
(DFunDef false "resultDeclsResult" ((PVar "src") (PVar "toks") (PVar "offs") (PVar "srcLen") (PCon "POk" (PVar "ds") (PVar "pos"))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos")) (EVar "TEof")) (EApp (EVar "Ok") (EVar "ds")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EVar "deepenLeftover") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "pos"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "deepenLeftover" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "ParseError")))))))
(DFunDef false "deepenLeftover" ((PVar "src") (PVar "toks") (PVar "offs") (PVar "srcLen") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runP") (EVar "parseDecl")) (EVar "toks")) (EVar "pos")) (arm (PCon "PFatal" (PVar "msg2") (PVar "pos2")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "msg2")) (EVar "pos2"))) (arm (PCon "PErr" (PVar "msg2") (PVar "pos2")) ((GBool (EBinOp ">" (EVar "pos2") (EVar "pos")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "msg2")) (EVar "pos2"))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EApp (EApp (EApp (EApp (EApp (EVar "unexpectedLeftoverMsg") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "pos"))) (EVar "pos")))))
(DTypeSig false "mkLocated" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "ParseError"))))))))
(DFunDef false "mkLocated" ((PVar "src") (PVar "toks") (PVar "offs") (PVar "srcLen") (PVar "msg") (PVar "pos")) (EMatch (EApp (EApp (EVar "offsetToLineCol") (EVar "src")) (EApp (EApp (EApp (EApp (EVar "locateOffset") (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "pos"))) (arm (PTuple (PVar "line") (PVar "col")) () (EApp (EApp (EApp (EVar "ParseError") (EVar "line")) (EVar "col")) (EVar "msg")))))
(DTypeSig false "leadingIndentAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "leadingIndentAt" ((PVar "src") (PVar "offset")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "lineStart") (EApp (EApp (EVar "leadingIndentLineStart") (EVar "chars")) (EBinOp "-" (EVar "offset") (ELit (LInt 1))))) (DoExpr (EIf (EApp (EApp (EApp (EVar "leadingIndentAllBlank") (EVar "chars")) (EVar "lineStart")) (EVar "offset")) (EApp (EVar "Some") (EBinOp "-" (EVar "offset") (EVar "lineStart"))) (EVar "None")))))
(DTypeSig false "leadingIndentLineStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "leadingIndentLineStart" ((PVar "chars") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar "\n"))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EApp (EVar "leadingIndentLineStart") (EVar "chars")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "leadingIndentAllBlank" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "leadingIndentAllBlank" ((PVar "chars") (PVar "i") (PVar "limit")) (EIf (EBinOp ">=" (EVar "i") (EVar "limit")) (EVar "True") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (arm (PLit (LChar " ")) () (EApp (EApp (EApp (EVar "leadingIndentAllBlank") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "limit"))) (arm (PLit (LChar "\t")) () (EApp (EApp (EApp (EVar "leadingIndentAllBlank") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "limit"))) (arm PWild () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "unexpectedLeftoverMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))))
(DFunDef false "unexpectedLeftoverMsg" ((PVar "src") (PVar "toks") (PVar "offs") (PVar "srcLen") (PVar "pos")) (EBlock (DoLet false false (PVar "base") (EBinOp "++" (ELit (LString "unexpected ")) (EApp (EVar "describeToken") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))))) (DoLet false false (PVar "offset") (EApp (EApp (EApp (EApp (EVar "locateOffset") (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "pos"))) (DoExpr (EMatch (EApp (EApp (EVar "leadingIndentAt") (EVar "src")) (EVar "offset")) (arm (PCon "Some" (PVar "col")) ((GBool (EBinOp ">" (EVar "col") (ELit (LInt 0))))) (EApp (EApp (EApp (EVar "leadingIndentMsg") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EVar "base")) (EVar "col"))) (arm PWild () (EVar "base"))))))
(DTypeSig false "leadingIndentMsg" (TyFun (TyCon "Token") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "leadingIndentMsg" ((PCon "TArrow") (PVar "base") (PVar "col")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "base"))) (ELit (LString ". A line can't start with `->` — it's not a supported continuation at any indentation; put `->` at the end of the previous line instead (e.g. `f : Int ->` then an indented `Int`)"))))
(DFunDef false "leadingIndentMsg" (PWild (PVar "base") (PVar "col")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "base"))) (ELit (LString ". Indentation (column "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ") doesn't match the enclosing block"))))
(DTypeSig false "firstLexError" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "String"))))))
(DFunDef false "firstLexError" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (arm (PCon "TLexError" (PVar "msg")) () (EApp (EVar "Some") (ETuple (EVar "i") (EVar "msg")))) (arm PWild () (EApp (EApp (EVar "firstLexError") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "firstSlashEqIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstSlashEqIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TSlashEq")) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EVar "firstSlashEqIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstMutIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstMutIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TMut")) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EVar "firstMutIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstRecordIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstRecordIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TRecord")) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EVar "firstRecordIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "firstFunctionIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstFunctionIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TFunction")) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EVar "firstFunctionIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "scanForLetIn" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "scanForLetIn" ((PVar "toks") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TIn")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "True") (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TIndent")) (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TDedent")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TDedent")) (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TEof")) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "firstInlineLetMissingIn" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstInlineLetMissingIn" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TElse")) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TThen"))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "TLet"))) (EIf (EApp (EApp (EApp (EVar "scanForLetIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (ELit (LInt 0))) (EApp (EApp (EVar "firstInlineLetMissingIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EVar "firstInlineLetMissingIn") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "inlineLetMissingInMsg" (TyCon "String"))
(DFunDef false "inlineLetMissingInMsg" () (ELit (LString "inline 'let' requires 'in': 'else let x = e in body'. For a multi-statement body, put 'else' on its own line and indent")))
(DTypeSig false "caseHasOfBeforeBoundary" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "caseHasOfBeforeBoundary" ((PVar "toks") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TOf")) (EVar "True") (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TImpl")) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TIndent")) (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TDedent")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TDedent")) (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TEof")) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "firstHsCaseOfIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstHsCaseOfIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EApp (EVar "TIdent") (ELit (LString "case")))) (EIf (EApp (EApp (EApp (EVar "caseHasOfBeforeBoundary") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0))) (EVar "i") (EApp (EApp (EVar "firstHsCaseOfIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "firstHsCaseOfIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "hsCaseOfMsg" (TyCon "String"))
(DFunDef false "hsCaseOfMsg" () (ELit (LString "Medaka has no 'case … of'. Use 'match e' with indented 'pattern => body' arms")))
(DTypeSig false "firstBacktickIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstBacktickIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (arm (PCon "TBacktickIdent" PWild) () (EVar "i")) (arm PWild () (EApp (EApp (EVar "firstBacktickIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "backtickInfixMsg" (TyCon "String"))
(DFunDef false "backtickInfixMsg" () (ELit (LString "backtick infix application (`f`) is not supported — use prefix application `f x y`")))
(DTypeSig false "firstWithIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstWithIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TWith")) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EVar "firstWithIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "letRecWithRemovedMsg" (TyCon "String"))
(DFunDef false "letRecWithRemovedMsg" () (ELit (LString "`let rec … with` (mutual-recursion grouping) has been removed — define each binding as a separate `let rec`")))
(DTypeSig false "isPlainIdentTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isPlainIdentTok" ((PCon "TIdent" PWild)) (EVar "True"))
(DFunDef false "isPlainIdentTok" (PWild) (EVar "False"))
(DTypeSig false "firstHsSigIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Int"))))))
(DFunDef false "firstHsSigIdx" ((PVar "toks") (PVar "i") (PVar "depth") (PVar "boundary")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "boundary") (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EVar "isPlainIdentTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "TCons"))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TIndent")) (EApp (EApp (EApp (EApp (EVar "firstHsSigIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TDedent")) (EApp (EApp (EApp (EApp (EVar "firstHsSigIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EBinOp "==" (EBinOp "-" (EVar "depth") (ELit (LInt 1))) (ELit (LInt 0)))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TNewline")) (EApp (EApp (EApp (EApp (EVar "firstHsSigIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "firstHsSigIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "hsSigMsg" (TyCon "String"))
(DFunDef false "hsSigMsg" () (ELit (LString "Use '::' for List cons. A type signature uses a single colon: 'f : T'")))
(DTypeSig false "isBracketOpenTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isBracketOpenTok" ((PCon "TLParen")) (EVar "True"))
(DFunDef false "isBracketOpenTok" ((PCon "TLBracket")) (EVar "True"))
(DFunDef false "isBracketOpenTok" ((PCon "TLBracketTight")) (EVar "True"))
(DFunDef false "isBracketOpenTok" ((PCon "TLBrace")) (EVar "True"))
(DFunDef false "isBracketOpenTok" (PWild) (EVar "False"))
(DTypeSig false "isBracketCloseTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isBracketCloseTok" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "isBracketCloseTok" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "isBracketCloseTok" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "isBracketCloseTok" (PWild) (EVar "False"))
(DTypeSig false "firstBlockCommentIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstBlockCommentIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TSlash")) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "TStar"))) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EVar "firstBlockCommentIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "blockCommentMsg" (TyCon "String"))
(DFunDef false "blockCommentMsg" () (ELit (LString "Medaka has no '/* … */' block comments. Use '{- … -}' (block) or '--' (line)")))
(DTypeSig false "braceBlockFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "braceBlockFrom" ((PVar "toks") (PVar "i") (PVar "depth") (PVar "cand")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EIf (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EVar "cand") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TThen")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TElse")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "cand") (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TNewline")) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TEof"))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EVar "cand") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TLBrace")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EBinOp "<" (EVar "cand") (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "i")) (EIf (EApp (EVar "isBracketOpenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "cand")) (EIf (EApp (EVar "isBracketCloseTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "cand")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "cand")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "firstBraceBlockIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "firstBraceBlockIdx" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TIf")) (EIf (EBinOp ">=" (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "braceBlockFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1)))) (EApp (EApp (EVar "firstBraceBlockIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "firstBraceBlockIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "braceBlockMsg" (TyCon "String"))
(DFunDef false "braceBlockMsg" () (ELit (LString "unexpected '{'. Medaka has no brace blocks; use 'then'/'else' with indentation, not '{ … }'")))
(DTypeSig false "isForeignKwTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "for")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "while")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "def")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "elif")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "class")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "try")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "except")))) (EVar "True"))
(DFunDef false "isForeignKwTok" ((PCon "TIdent" (PLit (LString "finally")))) (EVar "True"))
(DFunDef false "isForeignKwTok" (PWild) (EVar "False"))
(DTypeSig false "lineTrailingColonNoEq" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool")))))))
(DFunDef false "lineTrailingColonNoEq" ((PVar "toks") (PVar "i") (PVar "depth") (PVar "lastColon") (PVar "sawEq")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "&&" (EVar "lastColon") (EApp (EVar "not") (EVar "sawEq"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TNewline")) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TEof"))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TIndent"))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TDedent")))) (EBinOp "&&" (EVar "lastColon") (EApp (EVar "not") (EVar "sawEq"))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TEqual")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EVar "True")) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TColon")) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "True")) (EVar "sawEq")) (EIf (EApp (EVar "isBracketOpenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EVar "sawEq")) (EIf (EApp (EVar "isBracketCloseTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EVar "sawEq")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EVar "False")) (EVar "sawEq")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "firstForeignKwIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Int")))))
(DFunDef false "firstForeignKwIdx" ((PVar "toks") (PVar "i") (PVar "lineStart")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EIf (EBinOp "&&" (EBinOp "&&" (EVar "lineStart") (EApp (EVar "isForeignKwTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EApp (EApp (EApp (EApp (EApp (EVar "lineTrailingColonNoEq") (EVar "toks")) (EVar "i")) (ELit (LInt 0))) (EVar "False")) (EVar "False"))) (EVar "i") (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TNewline")) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TIndent"))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (EVar "TDedent"))) (EApp (EApp (EApp (EVar "firstForeignKwIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "True")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstForeignKwIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "foreignKwMsg" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "foreignKwMsg" ((PCon "TIdent" (PLit (LString "def")))) (ELit (LString "Medaka has no 'def'. Define a function as 'f x = …'")))
(DFunDef false "foreignKwMsg" ((PCon "TIdent" (PLit (LString "while")))) (ELit (LString "Medaka has no 'while' loops. Use recursion or list functions")))
(DFunDef false "foreignKwMsg" ((PCon "TIdent" (PLit (LString "elif")))) (ELit (LString "Medaka has no 'elif'. Chain conditions with 'else if', or use function guards")))
(DFunDef false "foreignKwMsg" ((PCon "TIdent" (PLit (LString "class")))) (ELit (LString "Medaka has no 'class'. Define a type with 'data'/'record', or an interface with 'interface'")))
(DFunDef false "foreignKwMsg" ((PCon "TIdent" (PLit (LString "try")))) (ELit (LString "Medaka has no 'try'/exceptions. Return errors as values with 'Result'/'Option'")))
(DFunDef false "foreignKwMsg" ((PCon "TIdent" (PLit (LString "except")))) (ELit (LString "Medaka has no 'except'/exceptions. Handle errors as values with 'Result'/'Option'")))
(DFunDef false "foreignKwMsg" ((PCon "TIdent" (PLit (LString "finally")))) (ELit (LString "Medaka has no 'finally'/exceptions. Errors are values ('Result'/'Option'), not caught")))
(DFunDef false "foreignKwMsg" (PWild) (ELit (LString "Medaka has no 'for' loops. Use recursion or list functions like 'map'/'forEach'/'fold'")))
(DTypeSig false "semicolonMsg" (TyCon "String"))
(DFunDef false "semicolonMsg" () (ELit (LString "Medaka has no statement terminator ';'. Separate statements with newlines")))
(DTypeSig true "parseResult" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "parseResult" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsets") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "offList")) () (EApp (EApp (EApp (EVar "parseResultWith") (EVar "src")) (EVar "tokList")) (EVar "offList")))))
(DTypeSig true "parseLocatedResult" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "parseLocatedResult" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "offPairs")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "setLocState") (EVar "src")) (EApp (EVar "arrayFromList") (EVar "offPairs")))) (DoExpr (EApp (EApp (EApp (EVar "parseResultWith") (EVar "src")) (EVar "tokList")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "offPairs"))))))))
(DTypeSig false "parseResultWith" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "parseResultWith" ((PVar "src") (PVar "tokList") (PVar "offList")) (EBlock (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EVar "tokList"))) (DoLet false false (PVar "offs") (EApp (EVar "arrayFromList") (EVar "offList"))) (DoLet false false (PVar "srcLen") (EApp (EVar "stringLength") (EVar "src"))) (DoLet false false (PVar "seIdx") (EApp (EApp (EVar "firstSlashEqIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "lmIdx") (EApp (EApp (EVar "firstMutIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "recIdx") (EApp (EApp (EVar "firstRecordIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "fnIdx") (EApp (EApp (EVar "firstFunctionIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "ilIdx") (EApp (EApp (EVar "firstInlineLetMissingIn") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "coIdx") (EApp (EApp (EVar "firstHsCaseOfIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "btIdx") (EApp (EApp (EVar "firstBacktickIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "wiIdx") (EApp (EApp (EVar "firstWithIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "sigIdx") (EApp (EApp (EApp (EApp (EVar "firstHsSigIdx") (EVar "toks")) (ELit (LInt 0))) (ELit (LInt 0))) (EVar "True"))) (DoLet false false (PVar "bcIdx") (EApp (EApp (EVar "firstBlockCommentIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "bbIdx") (EApp (EApp (EVar "firstBraceBlockIdx") (EVar "toks")) (ELit (LInt 0)))) (DoLet false false (PVar "fkwIdx") (EApp (EApp (EApp (EVar "firstForeignKwIdx") (EVar "toks")) (ELit (LInt 0))) (EVar "True"))) (DoExpr (EMatch (EApp (EApp (EVar "firstLexError") (EVar "toks")) (ELit (LInt 0))) (arm (PCon "Some" (PTuple (PVar "leIdx") (PVar "leMsg"))) () (EBlock (DoLet false false (PVar "leMsg2") (EIf (EBinOp "==" (EVar "leMsg") (ELit (LString "unexpected character ';'"))) (EVar "semicolonMsg") (EVar "leMsg"))) (DoExpr (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "leMsg2")) (EVar "leIdx")))))) (arm (PCon "None") () (EIf (EBinOp ">=" (EVar "seIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (ELit (LString "unexpected '/='. (Did you mean '!='?)"))) (EVar "seIdx"))) (EIf (EBinOp ">=" (EVar "lmIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "letMutRemovedMsg")) (EVar "lmIdx"))) (EIf (EBinOp ">=" (EVar "recIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "recordRemovedMsg")) (EVar "recIdx"))) (EIf (EBinOp ">=" (EVar "fnIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "functionRemovedMsg")) (EVar "fnIdx"))) (EIf (EBinOp ">=" (EVar "ilIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "inlineLetMissingInMsg")) (EVar "ilIdx"))) (EIf (EBinOp ">=" (EVar "coIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "hsCaseOfMsg")) (EVar "coIdx"))) (EIf (EBinOp ">=" (EVar "btIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "backtickInfixMsg")) (EVar "btIdx"))) (EIf (EBinOp ">=" (EVar "wiIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "letRecWithRemovedMsg")) (EVar "wiIdx"))) (EIf (EBinOp ">=" (EVar "sigIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "hsSigMsg")) (EVar "sigIdx"))) (EIf (EBinOp ">=" (EVar "bcIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "blockCommentMsg")) (EVar "bcIdx"))) (EIf (EBinOp ">=" (EVar "bbIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "braceBlockMsg")) (EVar "bbIdx"))) (EIf (EBinOp ">=" (EVar "fkwIdx") (ELit (LInt 0))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EApp (EVar "foreignKwMsg") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "fkwIdx")))) (EVar "fkwIdx"))) (EApp (EApp (EApp (EApp (EApp (EVar "resultDeclsResult") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EApp (EApp (EApp (EVar "runP") (EVar "parseProgram")) (EVar "toks")) (ELit (LInt 0)))))))))))))))))))))
