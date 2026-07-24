# META
source_lines=3941
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint.mdk — the `medaka lint` framework + seed rules.
--
-- A lint pass runs on the RAW pre-desugar AST (`parse src : List Decl`), exactly
-- like compiler/frontend/exhaust.mdk's standalone `checkGuardExhaustiveness`.
-- The seed rules detect SURFACE shapes (`match` on a bare param, a hand-written
-- `impl Eq`, a fn shadowing a stdlib name) that desugar.mdk lowers away, so this
-- pass must NEVER call desugar — it consumes `parse` output directly.
--
-- Design: adding a rule = write one `List Decl -> List Finding` function and
-- append one `Rule { … }` entry to `allRules` (THE REGISTRY).  The CLI layer (a
-- later agent) filters/severity-overrides that list and passes it to
-- `lintProgram`, so this module knows nothing about flags.
--
-- No stdlib imports (compiler isolation): generic helpers come from
-- support.util, everything else is inline.

import frontend.ast.{
  Loc(..),
  Lit(..),
  Ty(..),
  Pat(..),
  RecPatField(..),
  Guard(..),
  Arm(..),
  ImplMethod(..),
  DoStmt(..),
  Section(..),
  InterpPart(..),
  GuardArm(..),
  FieldAssign(..),
  LetBind(..),
  FunClause(..),
  Expr(..),
  Decl(..),
}
import frontend.parser.{
  Positions,
  DeclPos,
  positionsDecls,
  declPosLine,
  declPosEndLine,
  parseWithPositions,
  parseWithPositionsLocated,
}
import driver.diagnostics.{Severity(..), Diag(..), ppSeverity, readFileSafe}
import support.util.{
  contains,
  listLen,
  anyList,
  allList,
  filterList,
  joinNl,
  isEmptyL,
  isNonEmptyL,
  reverseL,
  splitNl,
  splitOnChar,
  joinWith,
  sortUniqS,
  startsWith,
  stringTrim,
  lookupAssoc,
  dedupBy,
}
import hash_map.{HashMap, new, set, has, findWithDefault}
import tools.printer.{declToString, exprToString}
import support.char.{isAlnum, isLower, isUpper}
import ir.sexp.{exprSexp, patSexp}
import frontend.exhaust.{Oracle, buildOracle, oGetCtors, oGetCtorType}
import frontend.lexer.{Comment, collectComments, commentLine, commentText}

-- ── public types ───────────────────────────────────────────────────────────

-- One lint hit: which rule produced it, the human message, its severity (the
-- CLI may promote this via `lintProgram`), and an optional source span.
public export data Finding =
  | Finding {
      rule : String,
      message : String,
      severity : Severity,
      loc : Option Loc,
    }

-- A registered rule.  `check` is the whole pass for that rule: the target file
-- PATH (so a rule may scope itself, e.g. skip stdlib-owned files) + Positions
-- (for per-decl source locations) + raw decls → hits.  `fix`, when `Some f`, is a
-- per-decl autofixer: given the syntactic constructor
-- `Oracle` (built once from the whole target file's decls — used by the
-- irrefutability logic to recognise single-constructor patterns) and a single
-- decl, it returns `Some replacementDecls` if the rule can safely rewrite that
-- decl, else `None`.  `None` = the rule is not auto-fixable.
-- `enabled`/`severity` are the defaults the CLI may override before running.
public export data Rule =
  | Rule {
      name : String,
      descr : String,
      severity : Severity,
      enabled : Bool,
      check : String -> String -> Positions -> List Decl -> List Finding,
      fix : Option (Oracle -> Decl -> Option (List Decl)),
    }

-- A registered CROSS-FILE rule.  Unlike `Rule` (one file at a time), `check`
-- sees EVERY target file's `(path, Positions, decls)` triple at once, so it can
-- relate definitions across files (e.g. duplicate bodies).  Findings stamp the
-- file path into their `loc`.  Same field-scanner gap as `Rule`: ALL
-- CrossFileRule-record access stays inside this module (the CLI passes/receives
-- only plain data).  Adding a cross-file rule = one `check` fn + one binding +
-- one `allCrossFileRules` entry.
public export data CrossFileRule =
  | CrossFileRule {
      name : String,
      descr : String,
      severity : Severity,
      enabled : Bool,
      check : List (String, Positions, List Decl) -> List Finding,
    }

-- ── rule names (kept in sync between the Rule entry and its Findings) ─────────
ruleNameMatchParam : String
ruleNameMatchParam = "rule-match-on-param"

ruleNameDerivable : String
ruleNameDerivable = "rule-hand-rolled-derivable"

ruleNameStdlibReimpl : String
ruleNameStdlibReimpl = "rule-stdlib-reimpl"

ruleNameDuplicateBody : String
ruleNameDuplicateBody = "rule-duplicate-body"

ruleNameBindThenDestructure : String
ruleNameBindThenDestructure = "rule-bind-then-destructure"

ruleNameLambdaSection : String
ruleNameLambdaSection = "rule-lambda-section"

ruleNameIfMaxMin : String
ruleNameIfMaxMin = "rule-if-max-min"

ruleNameAndThenPureMap : String
ruleNameAndThenPureMap = "rule-andthen-pure-map"

ruleNameDestructureInParam : String
ruleNameDestructureInParam = "rule-destructure-in-param"

ruleNameMissingSignature : String
ruleNameMissingSignature = "rule-missing-signature"

ruleNameNotEq : String
ruleNameNotEq = "rule-not-eq"

ruleNameBoolSimplify : String
ruleNameBoolSimplify = "rule-bool-simplify"

ruleNameRemParity : String
ruleNameRemParity = "rule-rem-parity"

ruleNameDoubleReverse : String
ruleNameDoubleReverse = "rule-double-reverse"

ruleNameWhenUnless : String
ruleNameWhenUnless = "rule-when-unless"

ruleNameComplementPredicate : String
ruleNameComplementPredicate = "rule-complement-predicate"

ruleNameMatchToMap : String
ruleNameMatchToMap = "rule-match-to-map"

ruleNameBindChainToDo : String
ruleNameBindChainToDo = "rule-bind-chain-to-do"

ruleNameDeadCode : String
ruleNameDeadCode = "rule-dead-code"

ruleNameConcatToInterp : String
ruleNameConcatToInterp = "rule-concat-to-interp"

ruleNameSelfShadowExtern : String
ruleNameSelfShadowExtern = "rule-self-shadow-extern"

-- ── the registry ─────────────────────────────────────────────────────────────
-- Each Rule is its own top-level binding (rather than an inline element of the
-- `allRules` list literal) so the LLVM emitter's record-field scanner — which
-- traverses binding bodies but not into list-literal elements — registers the
-- `Rule` field layout.  Adding a rule = write its `check` fn + one `Rule` binding
-- + append it to `allRules`.
matchParamRule : Rule
matchParamRule = Rule {
  name = ruleNameMatchParam,
  descr = "function body is a `match` on a bare parameter (prefer multi-clause; STYLE §8)",
  severity = SevWarning,
  enabled = True,
  check = ruleMatchOnParam,
  fix = Some matchParamFix,
}

derivableRule : Rule
derivableRule = Rule {
  name = ruleNameDerivable,
  descr = "hand-written Eq/Ord/Debug impl that could be `deriving` (STYLE §6)",
  severity = SevWarning,
  enabled = True,
  check = ruleDerivable,
  fix = None,
}

stdlibReimplRule : Rule
stdlibReimplRule = Rule {
  name = ruleNameStdlibReimpl,
  descr = "top-level function shadows a common stdlib/prelude name (STYLE §7a)",
  severity = SevWarning,
  enabled = True,
  check = ruleStdlibReimpl,
  fix = None,
}

bindThenDestructureRule : Rule
bindThenDestructureRule = Rule {
  name = ruleNameBindThenDestructure,
  descr = "do-bind then immediately destructures the bound var with an irrefutable single-arm `match`. Inline the pattern into the bind",
  severity = SevWarning,
  enabled = True,
  check = ruleBindThenDestructure,
  fix = Some bindThenDestructureFix,
}

lambdaSectionRule : Rule
lambdaSectionRule = Rule {
  name = ruleNameLambdaSection,
  descr = "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")",
  severity = SevWarning,
  enabled = True,
  check = ruleLambdaSection,
  fix = Some lambdaSectionFix,
}

ifMaxMinRule : Rule
ifMaxMinRule = Rule {
  name = ruleNameIfMaxMin,
  descr = "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`",
  severity = SevWarning,
  enabled = True,
  check = ruleIfMaxMin,
  fix = Some ifMaxMinFix,
}

andThenPureMapRule : Rule
andThenPureMapRule = Rule {
  name = ruleNameAndThenPureMap,
  descr = "monadic bind whose continuation just wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map` (functor law: m >>= (pure . f) ≡ fmap f m)",
  severity = SevWarning,
  enabled = True,
  check = ruleAndThenPureMap,
  fix = Some andThenPureMapFix,
}

destructureInParamRule : Rule
destructureInParamRule = Rule {
  name = ruleNameDestructureInParam,
  descr = "function body is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple/record/single-ctor). Destructure directly in the parameter position",
  severity = SevWarning,
  enabled = True,
  check = ruleDestructureInParam,
  fix = Some destructureInParamFix,
}

missingSignatureRule : Rule
missingSignatureRule = Rule {
  name = ruleNameMissingSignature,
  descr = "top-level value/function binding has no sibling type signature (name : Type). Add one (Haskell -Wmissing-signatures)",
  severity = SevWarning,
  enabled = True,
  check = ruleMissingSignature,
  fix = None,
}

notEqRule : Rule
notEqRule = Rule {
  name = ruleNameNotEq,
  descr = "negated equality `not (a == b)` / `not (a != b)`. Prefer `a != b` / `a == b`",
  severity = SevWarning,
  enabled = True,
  check = ruleNotEq,
  fix = Some notEqFix,
}

boolSimplifyRule : Rule
boolSimplifyRule = Rule {
  name = ruleNameBoolSimplify,
  descr = "redundant boolean shape (`if c then True else False`, `x == True`, `not (not x)`, …). Simplify",
  severity = SevWarning,
  enabled = True,
  check = ruleBoolSimplify,
  fix = Some boolSimplifyFix,
}

remParityRule : Rule
remParityRule = Rule {
  name = ruleNameRemParity,
  descr = "`n % 2 == 0` / `n % 2 != 0` parity test. Prefer `isEven n` / `isOdd n`",
  severity = SevWarning,
  enabled = True,
  check = ruleRemParity,
  fix = Some remParityFix,
}

doubleReverseRule : Rule
doubleReverseRule = Rule {
  name = ruleNameDoubleReverse,
  descr = "`reverse (reverse x)` is `x`. Drop the double reversal",
  severity = SevWarning,
  enabled = True,
  check = ruleDoubleReverse,
  fix = Some doubleReverseFix,
}

whenUnlessRule : Rule
whenUnlessRule = Rule {
  name = ruleNameWhenUnless,
  descr = "`if b then m else pure ()` / `if b then pure () else m`. Prefer `when b m` / `unless b m`",
  severity = SevWarning,
  enabled = True,
  check = ruleWhenUnless,
  fix = Some whenUnlessFix,
}

complementPredicateRule : Rule
complementPredicateRule = Rule {
  name = ruleNameComplementPredicate,
  descr = "`not (p x)` where `p` has a defined complement predicate (`isEmptyL`/`isSome`/`isOk` & inverses). Call the complement directly",
  severity = SevWarning,
  enabled = True,
  check = ruleComplementPredicate,
  fix = Some complementPredicateFix,
}

matchToMapRule : Rule
matchToMapRule = Rule {
  name = ruleNameMatchToMap,
  descr = "2-arm `match` on Option/Result that reconstructs the failure ctor and re-wraps the success ctor. That IS a functor `map` (hlint 'use fmap')",
  severity = SevWarning,
  enabled = True,
  check = ruleMatchToMap,
  fix = Some matchToMapFix,
}

bindChainToDoRule : Rule
bindChainToDoRule = Rule {
  name = ruleNameBindChainToDo,
  descr = "deep (≥3) nested Result/Option passthrough-bind `match` pyramid. Rewrite as a `do` block (suggest-only)",
  severity = SevWarning,
  enabled = True,
  check = ruleBindChainToDo,
  fix = None,
}

deadCodeRule : Rule
deadCodeRule = Rule {
  name = ruleNameDeadCode,
  descr = "private (unexported) top-level binding is unreachable from the file's exports/main/doctests. Dead code (Haskell -Wunused-top-binds)",
  severity = SevWarning,
  enabled = True,
  check = ruleDeadCode,
  fix = None,
}

concatToInterpRule : Rule
concatToInterpRule = Rule {
  name = ruleNameConcatToInterp,
  descr = "`++` chain mixing string literals and expressions. Prefer string interpolation `\"…\\{e}…\"` (hlint 'use interpolation')",
  severity = SevWarning,
  enabled = True,
  check = ruleConcatToInterp,
  fix = Some concatToInterpFix,
}

selfShadowExternRule : Rule
selfShadowExternRule = Rule {
  name = ruleNameSelfShadowExtern,
  descr = "top-level binding unconditionally forwards to itself (`f s = f s`, `x = x`) — an infinite self-recursion, not a forward to a same-named extern (#266)",
  severity = SevWarning,
  enabled = True,
  check = ruleSelfShadowExtern,
  fix = None,
}

export allRules : List Rule
allRules = [
  matchParamRule,
  derivableRule,
  stdlibReimplRule,
  bindThenDestructureRule,
  lambdaSectionRule,
  ifMaxMinRule,
  andThenPureMapRule,
  destructureInParamRule,
  missingSignatureRule,
  notEqRule,
  boolSimplifyRule,
  remParityRule,
  doubleReverseRule,
  whenUnlessRule,
  complementPredicateRule,
  matchToMapRule,
  bindChainToDoRule,
  deadCodeRule,
  concatToInterpRule,
  selfShadowExternRule,
]

-- ── the cross-file registry ───────────────────────────────────────────────────
-- Each CrossFileRule is its own top-level binding (same field-scanner reason as
-- `Rule`).  Adding a cross-file rule = write its `check` fn + one binding here +
-- append it to `allCrossFileRules`.
duplicateBodyRule : CrossFileRule
duplicateBodyRule = CrossFileRule {
  name = ruleNameDuplicateBody,
  descr = "top-level function body is structurally identical to one in another file (copy-paste; consolidate)",
  severity = SevWarning,
  enabled = True,
  check = ruleDuplicateBody,
}

export allCrossFileRules : List CrossFileRule
allCrossFileRules = [duplicateBodyRule]

-- ── runner ───────────────────────────────────────────────────────────────────

-- Run the enabled rules over a program, collecting every finding.  `pos` carries
-- per-decl source spans so each rule can stamp its finding with the decl's real
-- location.  Each rule's findings are re-stamped with the rule's (possibly
-- CLI-overridden) severity so a `--deny` promotion propagates without the rule
-- knowing about flags.
export lintProgram : List Rule -> String -> String -> Positions -> List Decl -> List Finding
lintProgram rules path src pos prog =
  flatMap (runRuleOn path src pos prog) rules

runRuleOn : String -> String -> Positions -> List Decl -> Rule -> List Finding
runRuleOn path src pos prog r
  | r.enabled = map (restampSeverity r.severity) (r.check path src pos prog)
  | otherwise = []

restampSeverity : Severity -> Finding -> Finding
restampSeverity sev f =
  Finding { rule = f.rule, message = f.message, severity = sev, loc = f.loc }

-- Is the target file part of the stdlib itself?  A `stdlib` path SEGMENT (so
-- `stdlib/core.mdk`, `./stdlib/list.mdk`, `/abs/medaka/stdlib/map.mdk` all match,
-- but `test/lint_fixtures/foo.mdk` does not).  Style rules that flag USER code
-- reimplementing / hand-rolling what the stdlib canonically provides
-- (`rule-stdlib-reimpl`, `rule-hand-rolled-derivable`) must skip stdlib-owned
-- files: those definitions ARE the canonical stdlib, or are hand-written for a
-- deliberate reason (bootstrap ordering, ctor/class name clash, or a non-
-- structural instance whose `deriving` would be semantically WRONG).
isStdlibPath : String -> Bool
isStdlibPath path = contains "stdlib" (splitOnChar '/' path)

-- ── autofix driver (Task A3) ───────────────────────────────────────────────────
-- The CLI calls this for `--fix`.  It is the ONLY place that touches the new
-- `Rule.fix` field (and any other Rule record field): per the documented native
-- field-scanner SIGSEGV gap, all `Rule`-record access must stay inside this
-- module, so the CLI passes only plain data (the `--only`/`--disable` name lists,
-- the source text, the parsed decls + `Positions`) and gets plain data back.
--
-- Algorithm: for each decl, the first active fixable rule whose fixer applies
-- yields `Some replacementDecls`; we render those via the printer and record a
-- splice over the decl's own source line range (`DeclPos` start..end).  Splices
-- are applied bottom-up (descending start line) so earlier line numbers stay
-- valid.  Returns `(rewrittenSource, fixedCount)`; unchanged source if no fix.
export applyFixes : List String -> List String -> String -> List Decl -> Positions -> (String, Int)
applyFixes only disable src prog pos =
  let rules = filterList (ruleActiveFixable only disable) allRules
  let orc = buildOracle prog
  let cmtLines = map commentLine (collectComments src)
  let splices = collectSplices cmtLines orc rules (zipDeclPos prog (positionsDecls pos))
  (applySplices src splices, listLen splices)

-- a rule participates in `--fix` iff it is enabled, passes the --only/--disable
-- filters, AND carries a fixer.
ruleActiveFixable : List String -> List String -> Rule -> Bool
ruleActiveFixable only disable r = r.enabled
  && (isEmptyL only || contains r.name only)
  && not (contains r.name disable)
  && ruleHasFixer r

ruleHasFixer : Rule -> Bool
ruleHasFixer r = match r.fix
  Some _ => True
  None => False

zipDeclPos : List Decl -> List DeclPos -> List (Decl, DeclPos)
zipDeclPos [] _ = []
zipDeclPos _ [] = []
zipDeclPos (d::ds) (p::ps) = (d, p) :: zipDeclPos ds ps

-- one (startLine, endLine, replacementText) per fixed decl, in source order.
--
-- COMMENT-LOSS SAFETY-NET (mirrors `medaka fmt`'s verbatim bail).  The printer
-- carries NO comments, so splicing printer output over a decl's `[startLine,
-- endLine]` span would silently DELETE any comment inside that span.  So before
-- emitting a splice we check `spanHasComment`: if the decl's span contains an
-- interior comment line we SKIP the fix (the rule still WARNS; the source is
-- left untouched).  A leading doc-comment ABOVE the decl is on a line
-- `< declPosLine` → outside the span → the fix is still allowed (no over-bail).
collectSplices : List Int -> Oracle -> List Rule -> List (Decl, DeclPos) -> List (Int, Int, String)
collectSplices _ _ _ [] = []
collectSplices cmtLines orc rules ((d, dp)::rest) = match firstFix orc rules d
  Some newDecls =>
    if spanHasComment cmtLines (declPosLine dp) (declPosEndLine dp) then
      collectSplices cmtLines orc rules rest
    else
      (declPosLine dp, declPosEndLine dp, renderDecls newDecls) :: collectSplices cmtLines orc rules rest
  None => collectSplices cmtLines orc rules rest

-- True iff some comment line falls within the inclusive span `[startLine, endLine]`.
spanHasComment : List Int -> Int -> Int -> Bool
spanHasComment cmtLines startLine endLine =
  anyList (l => startLine <= l && l <= endLine) cmtLines

firstFix : Oracle -> List Rule -> Decl -> Option (List Decl)
firstFix _ [] _ = None
firstFix orc (r::rs) d = match applyRuleFix orc r d
  Some newDecls => Some newDecls
  None => firstFix orc rs d

applyRuleFix : Oracle -> Rule -> Decl -> Option (List Decl)
applyRuleFix orc r d = match r.fix
  Some f => f orc d
  None => None

-- render replacement decls, one per line (printer emits a single decl, no NL).
renderDecls : List Decl -> String
renderDecls ds = joinNl (map declToString ds)

-- apply splices to the source.  `collectSplices` yields them ascending by start
-- line; reversing → descending so each edit leaves lower line numbers valid.
applySplices : String -> List (Int, Int, String) -> String
applySplices src splices = joinNl (foldSplices (splitNl src) (reverseL splices))

foldSplices : List String -> List (Int, Int, String) -> List String
foldSplices lines [] = lines
foldSplices lines ((s, e, txt)::rest) =
  foldSplices (spliceLines lines s e txt) rest

-- replace the 1-based inclusive line range [s..e] with `txt`'s own lines.
spliceLines : List String -> Int -> Int -> String -> List String
spliceLines lines s e txt = takeN (s - 1) lines ++ splitNl txt ++ dropN e lines

takeN : Int -> List a -> List a
takeN n _
  | n <= 0 = []
takeN _ [] = []
takeN n (x::xs) = x :: takeN (n - 1) xs

dropN : Int -> List a -> List a
dropN n xs
  | n <= 0 = xs
dropN _ [] = []
dropN n (_::xs) = dropN (n - 1) xs

-- ── CLI-flag-style finding filters ────────────────────────────────────────────
-- `--disable`/`--only`/`--deny` (and the `medaka_lint` MCP tool's `disable`/
-- `only`/`deny` args) all filter a `List Finding` by rule name, entirely in
-- terms of `Finding.rule` — no `Rule`-record field access, so these are safe
-- to run from any caller.  Shared by `medaka_cli.mdk` (the `medaka lint` CLI,
-- both human and `--json` modes) and `mcp.mdk` (`medaka_lint`) so the two
-- surfaces can never apply the flags differently.

-- Parse --prefix=v1,v2,... from argv; returns [] if not present.
export parseLintFlagList : String -> List String -> List String
parseLintFlagList prefix [] = []
parseLintFlagList prefix (x::rest)
  | startsWith prefix x =
    splitLintNames (stringSlice (stringLength prefix) (stringLength x) x)
  | otherwise = parseLintFlagList prefix rest

-- Split a comma-separated string.  Uses literal ',' to avoid Char-param issues.
-- Exported so a caller with an already-split comma-separated value in hand
-- (rather than a raw `--flag=v1,v2` argv token) — e.g. the `medaka_lint` MCP
-- tool's `deny`/`only`/`disable` args — can reuse the exact same splitter
-- `parseLintFlagList` uses, instead of re-deriving comma-splitting.  NOTE:
-- `splitLintNames ""` returns `[""]`, not `[]` — callers with an optional,
-- possibly-absent value should special-case the empty string themselves
-- (see mcp.mdk's `lintNameListArg`).
export splitLintNames : String -> List String
splitLintNames s = splitLintNamesGo (stringToChars s) s 0 0 (stringLength s)

splitLintNamesGo : Array Char -> String -> Int -> Int -> Int -> List String
splitLintNamesGo chars s start i n
  | i >= n = [stringSlice start n s]
  | arrayGetUnsafe i chars == ',' =
    stringSlice start i s :: splitLintNamesGo chars s (i + 1) (i + 1) n
  | otherwise = splitLintNamesGo chars s start (i + 1) n

-- Apply finding-level filters.  Operates on Finding.rule (a String) so no
-- Rule-record field access is needed by the caller.
export applyFindingFilters : List String -> List String -> List String -> List Finding -> List Finding
applyFindingFilters disable only deny findings =
  let after1 = applyFindingOnly only findings
  let after2 = applyFindingDisable disable after1
  applyFindingDeny deny after2

-- --only: keep findings whose rule is in the list (no-op when empty).
applyFindingOnly : List String -> List Finding -> List Finding
applyFindingOnly [] findings = findings
applyFindingOnly names findings = lintFindingOnlyGo names findings

lintFindingOnlyGo : List String -> List Finding -> List Finding
lintFindingOnlyGo _ [] = []
lintFindingOnlyGo names (f::rest)
  | contains f.rule names = f :: lintFindingOnlyGo names rest
  | otherwise = lintFindingOnlyGo names rest

-- --disable: remove findings whose rule is in the list (no-op when empty).
applyFindingDisable : List String -> List Finding -> List Finding
applyFindingDisable [] findings = findings
applyFindingDisable names findings = lintFindingDisableGo names findings

lintFindingDisableGo : List String -> List Finding -> List Finding
lintFindingDisableGo _ [] = []
lintFindingDisableGo names (f::rest)
  | contains f.rule names = lintFindingDisableGo names rest
  | otherwise = f :: lintFindingDisableGo names rest

-- --deny: promote findings to SevError when their rule is in the list.
export applyFindingDeny : List String -> List Finding -> List Finding
applyFindingDeny [] findings = findings
applyFindingDeny names findings = lintFindingDenyGo names findings

lintFindingDenyGo : List String -> List Finding -> List Finding
lintFindingDenyGo _ [] = []
lintFindingDenyGo names (f::rest)
  | contains f.rule names = Finding {
    rule = f.rule,
    message = f.message,
    severity = SevError,
    loc = f.loc,
  } :: lintFindingDenyGo names rest
  | otherwise = f :: lintFindingDenyGo names rest

export isFindingError : Finding -> Bool
isFindingError f = match f.severity
  SevError => True
  SevWarning => False

-- ── rendering ─────────────────────────────────────────────────────────────────

export findingToDiag : Finding -> Diag
findingToDiag f =
  Diag f.severity f.rule "[\{f.rule}] \{f.message}" f.loc None None

-- Run the full lint pipeline (all rules, inline `-- lint-disable-*` suppression,
-- then the `--disable`/`--only`/`--deny` CLI-flag-style filters) over ONE file
-- and return `(path, src, List Diag)` — exactly the per-file triple
-- `driver.diagnostics.cjAllToJson` expects.  Shared by `medaka lint --json`
-- (medaka_cli.mdk) and the `medaka_lint` MCP tool (mcp.mdk) so both surfaces
-- serialize through the SAME envelope `check --json` uses, with the lint rule
-- name landing in each diagnostic's `code` (via `findingToDiag`).  Uses
-- `readFileSafe` (the same "" -on-read-error helper `checkJsonFile` uses), so
-- an unreadable path parses as empty source and yields `(path, "", [])` —
-- total, no crash, and consistent with `check --json`'s own file-variant
-- behaviour on a missing target.  Uses `parseWithPositionsLocated` (#649) so a
-- `Finding` at a nested sub-expression (`exprRuleFindings`) carries THAT
-- expression's own location, not the enclosing decl's.
export lintFileDiagTriple : List String -> List String -> List String -> String -> <IO> (String, String, List Diag)
lintFileDiagTriple disable only deny path =
  let src = readFileSafe path
  let (decls, pos) = parseWithPositionsLocated src
  let allFindings = applySuppressions src (lintProgram allRules path src pos decls)
  let findings = applyFindingFilters disable only deny allFindings
  (path, src, map findingToDiag findings)

-- One finding per line: `<severity>: [<rule>] <message>` (location-stripped, the
-- golden harness sorts).  Mirror of exhaust.mdk's `exhaustToLines`.  `src` is the
-- raw source text: findings are produced by `lintProgram`, then filtered through
-- the inline-suppression directives (`-- lint-disable-*`) recovered from `src`'s
-- comment side channel (see `applySuppressions`).
export lintToLines : String -> String -> Positions -> List Decl -> String
lintToLines src path pos prog =
  joinNl (map
    findingLine
    (applySuppressions src (lintProgram allRules path src pos prog)))

findingLine : Finding -> String
findingLine f = "\{ppSeverity f.severity}: [\{f.rule}] \{f.message}"

-- ── inline suppression directives (ESLint-style) ──────────────────────────────
-- A finding can be silenced by a `--` line comment whose trimmed body starts
-- with one of these directive keywords (chosen to MIRROR ESLint's
-- `eslint-disable-*` family; keep them exactly unless there's a strong reason):
--
--   `-- lint-disable-next-line [rules]`  suppress findings on the NEXT source line
--   `-- lint-disable-line      [rules]`  suppress findings on THIS comment's line
--   `-- lint-disable-file      [rules]`  suppress the rules ANYWHERE in the file
--
-- With NO rule names the directive applies to ALL rules; otherwise it lists rule
-- ids (comma- and/or space-separated, e.g. `rule-match-on-param, rule-stdlib-reimpl`)
-- matched against a Finding's `rule` field.  Unknown rule names are harmless
-- no-ops.  A finding at line L with rule R is suppressed iff SOME directive both
-- covers R (its rule set is empty or contains R) and whose scope includes L.
--
-- SEAM.  Comments are stripped by the lexer before layout, so the parser never
-- sees them and no rule can observe a directive.  Instead findings are produced
-- FIRST by `lintProgram`, then FILTERED here using the lexer's out-of-band
-- comment side channel (`collectComments src`).  The two lint entry points
-- (`compiler/driver/medaka_cli.mdk` report arm + this module's `lintToLines`,
-- used by `compiler/entries/lint_main.mdk`) call `applySuppressions src findings`
-- right after `lintProgram`.  A finding's line comes from its `loc` (the decl's
-- start line, stamped by `declLocList`); a finding without a `loc` can only be
-- silenced by a whole-file directive.

-- `public export` (not bare `data`) because a Directive is one of the four
-- things `medaka lint --cache` persists per file (#395): the cache round-trips
-- these values through JSON, so tools/lint_cache.mdk needs the constructors.
public export data DirScope = DScopeLine Int | DScopeFile

-- one parsed directive: which source lines it covers + which rule ids it names
-- (empty list = all rules).
public export data Directive = Directive DirScope (List String)

-- Filter out every finding covered by an inline-suppression directive found in
-- the source's comment side channel.
export applySuppressions : String -> List Finding -> List Finding
applySuppressions src findings =
  applySuppressionsDirs (collectDirectives src) findings

-- The same filter, but taking the file's ALREADY-PARSED directives instead of
-- re-deriving them from source.  `--cache` (#395) stores a file's directives in
-- its shard, so a cache hit has them in hand and must not re-run
-- `collectDirectives` (which re-lexes the file — the very cost the cache
-- exists to skip).  `applySuppressions` is this function plus the parse, so the
-- cached and uncached paths share ONE suppression implementation and cannot
-- drift apart.
export applySuppressionsDirs : List Directive -> List Finding -> List Finding
applySuppressionsDirs dirs findings =
  filterList (f => not (isSuppressed dirs f)) findings

-- Cross-file variant: findings anchor to DIFFERENT files, so a single `src`
-- cannot cover them.  Given each file's source (`(path, src)`), silence every
-- finding covered by an inline directive in ITS OWN file's comment side channel.
-- Directives are parsed once per file (not per finding).  General over any
-- cross-file rule; the cross-file report path calls this before flag filters.
export applySuppressionsMulti : List (String, String) -> List Finding -> List Finding
applySuppressionsMulti srcs findings =
  applySuppressionsMultiDirs (map fileDirectivesOf srcs) findings

-- Pre-parsed-directive counterpart of `applySuppressionsMulti`, for the same
-- reason `applySuppressionsDirs` exists: a `--cache` run already holds every
-- file's directives and must not re-lex to recover them.
export applySuppressionsMultiDirs : List (String, List Directive) -> List Finding -> List Finding
applySuppressionsMultiDirs dirTable findings =
  filterList (f => not (findingSuppressedMulti dirTable f)) findings

fileDirectivesOf : (String, String) -> (String, List Directive)
fileDirectivesOf (path, src) = (path, collectDirectives src)

findingSuppressedMulti : List (String, List Directive) -> Finding -> Bool
findingSuppressedMulti dirTable f = match lookupDirs (findingFileOf f) dirTable
  None => False
  Some dirs => isSuppressed dirs f

findingFileOf : Finding -> String
findingFileOf f = match f.loc
  Some (Loc file _ _ _ _) => file
  None => ""

lookupDirs : String -> List (String, List Directive) -> Option (List Directive)
lookupDirs _ [] = None
lookupDirs path ((p, ds)::rest) =
  if p == path then
    Some ds
  else
    lookupDirs path rest

export collectDirectives : String -> List Directive
collectDirectives src =
  flatMap (c => dirToList (parseDirective c)) (collectComments src)

dirToList : Option Directive -> List Directive
dirToList None = []
dirToList (Some d) = [d]

-- A comment becomes a directive iff it is a `--` line comment whose trimmed body
-- (after the `--`) starts with a directive keyword.  `commentText` includes the
-- delimiters, so we strip a leading `--` then re-trim.
parseDirective : Comment -> Option Directive
parseDirective c =
  let body = trimWs (commentText c)
  if startsWith "--" body then
    parseDirectiveBody (commentLine c) (trimWs (stringSlice 2 (stringLength body) body))
  else
    None

parseDirectiveBody : Int -> String -> Option Directive
parseDirectiveBody line s = match matchKeyword "lint-disable-next-line" s
  Some names => Some (Directive (DScopeLine (line + 1)) (parseRuleNames names))
  None => match matchKeyword "lint-disable-line" s
    Some names => Some (Directive (DScopeLine line) (parseRuleNames names))
    None => map (names => Directive DScopeFile (parseRuleNames names)) (matchKeyword "lint-disable-file" s)

-- If `s` starts with keyword `kw` AND the keyword is followed by end-of-string
-- or whitespace (so `lint-disable-lineXYZ` does NOT match), return the trimmed
-- remainder (the rule-name list); else None.
matchKeyword : String -> String -> Option String
matchKeyword kw s
  | startsWith kw s =
    let rest = stringSlice (stringLength kw) (stringLength s) s
    if rest == "" || startsWith " " rest || startsWith "\t" rest then
      Some (trimWs rest)
    else
      None
  | otherwise = None

-- Split a rule-name list on commas and/or spaces, dropping empty fragments.
parseRuleNames : String -> List String
parseRuleNames s =
  filterList nonEmptyStr (flatMap (splitOnChar ' ') (splitOnChar ',' s))

nonEmptyStr : String -> Bool
nonEmptyStr n = n != ""

isSuppressed : List Directive -> Finding -> Bool
isSuppressed dirs f = anyList (dirCoversFinding f) dirs

dirCoversFinding : Finding -> Directive -> Bool
dirCoversFinding f (Directive scope names) = (isEmptyL names || contains f.rule names)
  && scopeMatches (findingLineNo f) scope

scopeMatches : Option Int -> DirScope -> Bool
scopeMatches _ DScopeFile = True
scopeMatches (Some line) (DScopeLine l) = line == l
scopeMatches None (DScopeLine _) = False

findingLineNo : Finding -> Option Int
findingLineNo f = map ((Loc _ l _ _ _) => l) f.loc

-- trim ASCII whitespace from both ends
trimWs : String -> String
trimWs s =
  let cs = stringToChars s
  let n = arrayLength cs
  let a = trimWsStart cs n 0
  let b = trimWsEnd cs a n
  stringSlice a b s

trimWsStart : Array Char -> Int -> Int -> Int
trimWsStart cs n i
  | i >= n = i
  | isWsChar (arrayGetUnsafe i cs) = trimWsStart cs n (i + 1)
  | otherwise = i

trimWsEnd : Array Char -> Int -> Int -> Int
trimWsEnd cs a n
  | n <= a = a
  | isWsChar (arrayGetUnsafe (n - 1) cs) = trimWsEnd cs a (n - 1)
  | otherwise = n

isWsChar : Char -> Bool
isWsChar c = c == ' ' || c == '\t' || c == '\r' || c == '\n'

-- ── small AST helpers ─────────────────────────────────────────────────────────

-- strip the transparent ELoc wrapper(s) to reach the real node
unwrapLoc : Expr -> Expr
unwrapLoc (ELoc _ e) = unwrapLoc e
unwrapLoc e = e

-- ── per-decl source locations (Task B) ─────────────────────────────────────────
-- `Positions` carries one `DeclPos` per top-level decl, parallel to the decl
-- list.  We pair each decl with `Some (Loc … startLine 1 startLine 1)` so a rule
-- can stamp its finding with the decl's REAL start line (decls themselves carry
-- no `Loc`).  This is the only location source the carat path (CLI) needs; the
-- golden line format (`findingLine`) ignores it, so goldens stay location-stripped.
declLocList : Positions -> List Decl -> List (Decl, Option Loc)
declLocList pos prog = zipDeclLoc prog (positionsDecls pos)

zipDeclLoc : List Decl -> List DeclPos -> List (Decl, Option Loc)
zipDeclLoc [] _ = []
zipDeclLoc (d::ds) [] = (d, None) :: zipDeclLoc ds []
zipDeclLoc (d::ds) (p::ps) = (d, Some (declPosToLoc p)) :: zipDeclLoc ds ps

declPosToLoc : DeclPos -> Loc
declPosToLoc p = let l = declPosLine p in Loc "" l 1 l 1

-- ── rule: match-on-param (STYLE §8) ───────────────────────────────────────────
-- A `DFunDef _ name pats body` (or an impl method) whose body is a `match` with
-- ≥2 arms over an `EVar p` where `p` is a bare `PVar p` parameter.  Single-arm
-- matches are skipped (STYLE's "when not to convert").
ruleMatchOnParam : String -> String -> Positions -> List Decl -> List Finding
ruleMatchOnParam _ _ pos prog = flatMap matchParamDeclL (declLocList pos prog)

matchParamDeclL : (Decl, Option Loc) -> List Finding
matchParamDeclL (d, loc) = matchParamDecl loc d

matchParamDecl : Option Loc -> Decl -> List Finding
matchParamDecl loc (DFunDef _ name pats body) =
  matchParamFinding loc name pats body
matchParamDecl loc (DImpl { methods, ... }) =
  flatMap (matchParamMethod loc) methods
matchParamDecl loc (DAttrib _ d) = matchParamDecl loc d
matchParamDecl _ _ = []

matchParamMethod : Option Loc -> ImplMethod -> List Finding
matchParamMethod loc (ImplMethod name pats body) =
  matchParamFinding loc name pats body

matchParamFinding : Option Loc -> String -> List Pat -> Expr -> List Finding
matchParamFinding loc name pats body = match unwrapLoc body
  EMatch scrut arms => matchParamArms loc name pats scrut arms
  _ => []

matchParamArms : Option Loc -> String -> List Pat -> Expr -> List Arm -> List Finding
matchParamArms loc name pats scrut arms
  | listLen arms < 2 = []
  | otherwise = match unwrapLoc scrut
    EVar p => matchParamHit loc name pats p
    _ => []

matchParamHit : Option Loc -> String -> List Pat -> String -> List Finding
matchParamHit loc name pats p
  | anyList (isBareParam p) pats = [
    Finding {
      rule = ruleNameMatchParam,
      message = "function '\{name}' matches on parameter '\{p}' — use a multi-clause function definition",
      severity = SevWarning,
      loc = loc,
    }
  ]
  | otherwise = []

isBareParam : String -> Pat -> Bool
isBareParam p (PVar q _) = p == q
isBareParam _ _ = False

-- ── §8 autofixer (Task A) ──────────────────────────────────────────────────────
-- Rewrites `f x = match x { p1 => e1; p2 => e2 }` → `f p1 = e1` / `f p2 = e2`.
-- SAFE SUBSET ONLY — returns `None` (rule still warns) unless ALL hold:
--   * the decl is a bare `DFunDef` (not attributed: splitting an attributed fn
--     into clauses would duplicate/move the attribute),
--   * its body (under `ELoc`) is an `EMatch` on a bare param `p` with ≥2 arms,
--   * NO arm has a guard — function-clause guards don't round-trip through
--     `DFunDef` (no guard slot),
--   * NO arm with a NON-wildcard pattern references the scrutinee param `p` —
--     after the rewrite `p` is replaced by the arm pattern, so a non-wildcard arm
--     body still mentioning `p` would be left unbound (e.g.
--     `f x = match x { Some v => g x }`).  A `PWild` arm referencing `p` is the
--     EXCEPTION: it is rewritten with `PVar p` (not `_`), which re-binds the
--     scrutinee, so it converts safely.  We test the reference by a conservative
--     whole-word scan of the PRINTED arm body: the printer renders every `EVar p`
--     as the token `p`, so a real reference is never missed (the scan can only
--     over-bail, which is safe).
matchParamFix : Oracle -> Decl -> Option (List Decl)
matchParamFix _ (DFunDef vis name pats body) = match matchBodyOnBareParam pats body
  Some (p, k, arms) => matchParamFixArms vis name pats p k arms
  None => None
matchParamFix _ _ = None

matchParamFixArms : Bool -> String -> List Pat -> String -> Int -> List Arm -> Option (List Decl)
matchParamFixArms vis name pats p k arms
  | listLen arms < 2 = None
  | anyList armHasGuard arms = None
  | anyList (armUnsafeMention p) arms = None
  | otherwise = Some (map (armToClause vis name p pats k) arms)

-- ── SHARED detector (rule-match-on-param + rule-destructure-in-param) ──────────
-- The function-clause body (under `ELoc`) is a `match <p>` whose scrutinee is a
-- bare-`PVar p` parameter at position `k` in `pats`.  Returns `(p, k, arms)`.
-- Arm-count / guard / irrefutability gates live in each rule.  `paramIndex`
-- only yields `Some` when a bare `PVar p` parameter exists, so a `Some` result
-- already guarantees the scrutinee is a bare parameter.
matchBodyOnBareParam : List Pat -> Expr -> Option (String, Int, List Arm)
matchBodyOnBareParam pats body = match unwrapLoc body
  EMatch scrut arms => match unwrapLoc scrut
    EVar p => map (k => (p, k, arms)) (paramIndex p pats)
    _ => None
  _ => None

-- an arm with any guard qualifier (refutable bind or boolean) can't be a clause
armHasGuard : Arm -> Bool
armHasGuard (Arm _ guards _) = isNonEmptyL guards

-- does the arm body still reference the scrutinee param (conservative, printed)
armMentionsParam : String -> Arm -> Bool
armMentionsParam p (Arm _ _ body) = wholeWordIn p (exprToString body)

-- an arm that mentions the scrutinee but CAN'T be safely re-bound.  A `PWild`
-- arm can: we re-emit the clause pattern as `PVar p`, re-binding the scrutinee
-- so the body's reference stays valid.  Any non-wildcard pattern (`c::rest`, or
-- a bare `PVar y` that renames) can't re-bind `p`, so we keep the conservative
-- bail there.
armUnsafeMention : String -> Arm -> Bool
armUnsafeMention p arm = armMentionsParam p arm && not (armPatIsWild arm)

armPatIsWild : Arm -> Bool
armPatIsWild (Arm pat _ _) = patIsWild pat

patIsWild : Pat -> Bool
patIsWild PWild = True
patIsWild _ = False

-- position of the first bare-`PVar p` parameter
paramIndex : String -> List Pat -> Option Int
paramIndex p pats = paramIndexGo p pats 0

paramIndexGo : String -> List Pat -> Int -> Option Int
paramIndexGo _ [] _ = None
paramIndexGo p (pat::rest) i
  | isBareParam p pat = Some i
  | otherwise = paramIndexGo p rest (i + 1)

-- one clause: replace the param at position k with the arm pattern, body = arm
-- rhs.  Special case: a `PWild` arm whose body references the scrutinee `p` is
-- rendered with `PVar p` instead of `_`, re-binding the scrutinee so the body's
-- reference stays valid (the bail in `matchParamFixVar` has already rejected any
-- UNSAFE — non-wildcard — mention).
armToClause : Bool -> String -> String -> List Pat -> Int -> Arm -> Decl
armToClause vis name p pats k (Arm pat _ body) =
  let cpat = if patIsWild pat && wholeWordIn p (exprToString body) then
    PVar p (Loc "" 0 0 0 0)
  else
    pat
  DFunDef vis name (replaceAt k cpat pats) body

replaceAt : Int -> a -> List a -> List a
replaceAt _ _ [] = []
replaceAt 0 x (_::rest) = x::rest
replaceAt n x (y::rest) = y :: replaceAt (n - 1) x rest

-- whole-word (identifier-token) occurrence of `name` in `s`.  Boundaries are any
-- non-identifier char (isAlnum covers alnum/_/').  Over-matches into string
-- literals etc. — that only makes the fix gate MORE conservative, never less.
wholeWordIn : String -> String -> Bool
wholeWordIn name s =
  let cs = stringToChars s
  let nlen = stringLength name
  wholeWordGo name nlen s cs (arrayLength cs) 0

wholeWordGo : String -> Int -> String -> Array Char -> Int -> Int -> Bool
wholeWordGo name nlen s cs n i
  | i + nlen > n = False
  | boundaryAt cs i && boundaryAt cs (i + nlen) && stringSlice i (i + nlen) s == name = True
  | otherwise = wholeWordGo name nlen s cs n (i + 1)

-- position j is a boundary iff at least one neighbour across the candidate edge
-- is NOT an identifier char (or off the ends of the string).
boundaryAt : Array Char -> Int -> Bool
boundaryAt cs j
  | j == 0 = True
  | j >= arrayLength cs = True
  | otherwise = not (isAlnum (arrayGetUnsafe (j - 1) cs))
    || not (isAlnum (arrayGetUnsafe j cs))

-- ── rule: destructure-in-param ────────────────────────────────────────────────
-- The single-arm sibling of `rule-match-on-param`.  A `DFunDef _ name pats body`
-- whose body is a ONE-arm, guard-free `match <p>` over a bare parameter `p`, where
-- the arm pattern is an IRREFUTABLE destructuring pattern (a tuple, or a record /
-- single-payload / nullary constructor of a SINGLE-constructor type) and the arm
-- body does NOT reference `p` anywhere else (Medaka has no as-patterns, so hoisting
-- the pattern into the parameter position drops `p`'s binding).  In that case
-- prefer destructuring directly in the parameter position:
--   `f q = match q { AggQuery { from = t, … } => body }`
--     → `f (AggQuery { from = t, … }) = body`.
-- Irrefutability is proved via the Tier-0 `Oracle`: a constructor whose type has
-- exactly ONE constructor is irrefutable; an unknown ctor (e.g. an imported type
-- not declared in this file) is treated as NOT provably irrefutable → SKIP.  This
-- is deliberately conservative: false negatives are fine, false positives corrupt
-- code (they could turn a total match into a partial function clause).
ruleDestructureInParam : String -> String -> Positions -> List Decl -> List Finding
ruleDestructureInParam _ _ pos prog =
  let orc = buildOracle prog
  flatMap (destructureDeclL orc) (declLocList pos prog)

destructureDeclL : Oracle -> (Decl, Option Loc) -> List Finding
destructureDeclL orc (d, loc) = match d
  DFunDef _ name pats body => destructureFinding orc loc name pats body
  _ => []

destructureFinding : Oracle -> Option Loc -> String -> List Pat -> Expr -> List Finding
destructureFinding orc loc name pats body = match matchBodyOnBareParam pats body
  Some (p, _, arms) => destructureArmsFinding orc loc name p arms
  None => []

destructureArmsFinding : Oracle -> Option Loc -> String -> String -> List Arm -> List Finding
destructureArmsFinding orc loc name p [arm] =
  if destructureArmFires orc p arm then
    [
      Finding {
        rule = ruleNameDestructureInParam,
        message = "function '\{name}' destructures parameter '\{p}' via a single-arm irrefutable `match`. Destructure it directly in the parameter position",
        severity = SevWarning,
        loc = loc,
      }
    ]
  else
    []
destructureArmsFinding _ _ _ _ _ = []

-- the single arm can be hoisted iff: guard-free, its pattern is an irrefutable
-- destructuring pattern (not a bare var/wild/literal), and the arm body does NOT
-- otherwise mention the scrutinee param (conservative printed whole-word scan —
-- over-bail only, matching `armMentionsParam`).
destructureArmFires : Oracle -> String -> Arm -> Bool
destructureArmFires orc p (Arm pat guards body) = isEmptyL guards
  && destructurablePat orc pat
  && not (wholeWordIn p (exprToString body))

-- the TOP pattern is a real destructuring pattern (tuple / record / single-ctor
-- constructor) whose sub-patterns are all irrefutable.  Bare var/wild (pointless
-- to hoist), literals, `::`/`[…]` list patterns and ranges are excluded.
destructurablePat : Oracle -> Pat -> Bool
destructurablePat orc (PTuple ps) = allList (patIrrefutable orc) ps
destructurablePat orc (PCon c ps) = ctorIsSingle orc c
  && allList (patIrrefutable orc) ps
destructurablePat orc (PRec c fs _) = ctorIsSingle orc c
  && allList (recPatFieldIrrefutable orc) fs
destructurablePat _ _ = False

-- irrefutability of an arbitrary (possibly nested) pattern.  A var/wildcard binds
-- unconditionally; a tuple is irrefutable iff every element is; a constructor /
-- record iff its type is single-ctor AND every sub-pattern is; literals, `::`,
-- list and range patterns are refutable.
patIrrefutable : Oracle -> Pat -> Bool
patIrrefutable _ (PVar _ _) = True
patIrrefutable _ PWild = True
patIrrefutable orc (PTuple ps) = allList (patIrrefutable orc) ps
patIrrefutable orc (PCon c ps) = ctorIsSingle orc c
  && allList (patIrrefutable orc) ps
patIrrefutable orc (PRec c fs _) = ctorIsSingle orc c
  && allList (recPatFieldIrrefutable orc) fs
patIrrefutable orc (PAs _ _ p) = patIrrefutable orc p
patIrrefutable _ _ = False

recPatFieldIrrefutable : Oracle -> RecPatField -> Bool
recPatFieldIrrefutable _ (RecPatField _ _ None) = True
recPatFieldIrrefutable orc (RecPatField _ _ (Some p)) = patIrrefutable orc p

-- the constructor `c` belongs to a type declared (or built-in) with EXACTLY one
-- constructor — so a `c …` pattern can never fail to match.  An unknown ctor
-- (its type isn't visible in this file) is NOT provably single → False (SKIP).
ctorIsSingle : Oracle -> String -> Bool
ctorIsSingle orc c = match oGetCtorType orc c
  Some t => match oGetCtors orc t
    Some ctors => listLen ctors == 1
    None => False
  None => False

-- ── destructure-in-param autofixer ────────────────────────────────────────────
-- Reuses the shared `matchBodyOnBareParam` detector and the shared `armToClause`
-- pattern-hoist transform (the N = 1 case).  The `destructureArmFires` gate has
-- already proved the pattern irrefutable and the param unreferenced, so
-- `armToClause`'s PWild re-bind special-case never triggers here.
destructureInParamFix : Oracle -> Decl -> Option (List Decl)
destructureInParamFix orc (DFunDef vis name pats body) = match matchBodyOnBareParam pats body
  Some (p, k, arms) => destructureInParamFixArms orc vis name pats p k arms
  None => None
destructureInParamFix _ _ = None

destructureInParamFixArms : Oracle -> Bool -> String -> List Pat -> String -> Int -> List Arm -> Option (List Decl)
destructureInParamFixArms orc vis name pats p k [arm] =
  if destructureArmFires orc p arm then
    Some [armToClause vis name p pats k arm]
  else
    None
destructureInParamFixArms _ _ _ _ _ _ _ = None

-- ── rule: hand-rolled-derivable (STYLE §6) ────────────────────────────────────
-- A `DImpl` for Eq/Ord/Debug over a single named (TyCon-headed) type.  DImpl
-- carries no loc, so loc = None.
derivableIfaces : List String
derivableIfaces = ["Eq", "Ord", "Debug"]

-- Skip stdlib-owned files entirely: every hand-written `impl Eq/Ord/Debug` in
-- the stdlib is legitimate (a primitive with no `data` decl to derive from, the
-- `Ordering` Eq-ctor/Eq-class clash, a non-structural container instance whose
-- `deriving` would be semantically WRONG, or a bootstrap-prelude type).  For
-- USER code we additionally require the type to have a `data`/`record`
-- declaration whose constructors are visible in the linted file (`oGetCtors`
-- returns `Some`) — a primitive has none, so `impl Eq for Int` is never flagged.
ruleDerivable : String -> String -> Positions -> List Decl -> List Finding
ruleDerivable path _ pos prog
  | isStdlibPath path = []
  | otherwise =
    let orc = buildOracle prog
    flatMap (derivableDeclL orc) (declLocList pos prog)

derivableDeclL : Oracle -> (Decl, Option Loc) -> List Finding
derivableDeclL orc (d, loc) = derivableDecl orc loc d

derivableDecl : Oracle -> Option Loc -> Decl -> List Finding
derivableDecl orc loc (DImpl { iface, tys, ... }) =
  derivableHit orc loc iface tys
derivableDecl orc loc (DAttrib _ d) = derivableDecl orc loc d
derivableDecl _ _ _ = []

derivableHit : Oracle -> Option Loc -> String -> List Ty -> List Finding
derivableHit orc loc iface tys
  | contains iface derivableIfaces = match singleNamedType tys
    Some tyName =>
      if hasUserDataDecl orc tyName then
        [
          Finding {
            rule = ruleNameDerivable,
            message = "hand-written `impl \{iface}` for '\{tyName}' — use `deriving (\{iface})`",
            severity = SevWarning,
            loc = loc,
          }
        ]
      else
        []
    None => []
  | otherwise = []

-- the type has a `data`/`record` declaration (with constructors) visible in the
-- linted file — so `deriving` is actually available for it.  Primitive types
-- (Int/Float/Bool/String/Char/Unit/Array) have no such decl → `oGetCtors` = None.
hasUserDataDecl : Oracle -> String -> Bool
hasUserDataDecl orc tyName = match oGetCtors orc tyName
  Some _ => True
  None => False

-- the head type name iff `tys` is exactly one TyCon-headed type
singleNamedType : List Ty -> Option String
singleNamedType [t] = tyHeadName t
singleNamedType _ = None

tyHeadName : Ty -> Option String
tyHeadName (TyCon n _) = Some n
tyHeadName (TyApp f _) = tyHeadName f
tyHeadName _ = None

-- ── rule: stdlib-reimpl (STYLE §7a) ───────────────────────────────────────────
-- A top-level `DFunDef` whose name is a common stdlib/prelude function.  Extend
-- this curated set as the stdlib grows.
stdlibNames : List String
stdlibNames = [
  "reverse",
  "take",
  "drop",
  "map",
  "filter",
  "flatMap",
  "concatMap",
  "foldl",
  "foldr",
  "length",
  "elem",
  "intercalate",
  "intersperse",
  "zip",
  "zipWith",
]

-- Skip stdlib-owned files: inside the stdlib these top-level names ARE the
-- canonical definitions the rule points USER code at, so flagging them is a pure
-- false positive.  Off the stdlib root the rule fires as before.
ruleStdlibReimpl : String -> String -> Positions -> List Decl -> List Finding
ruleStdlibReimpl path _ pos prog
  | isStdlibPath path = []
  | otherwise =
    -- dedupe by name so a multi-clause function (consecutive DFunDefs) fires once,
    -- keeping the FIRST clause's location.
    map stdlibFinding
      (dedupeNamesLoc (filterList inStdlibPair (flatMap topDefNameL (declLocList pos prog))))

topDefNameL : (Decl, Option Loc) -> List (String, Option Loc)
topDefNameL (DFunDef _ name _ _, loc) = [(name, loc)]
topDefNameL (DAttrib _ d, loc) = topDefNameL (d, loc)
topDefNameL _ = []

inStdlibPair : (String, Option Loc) -> Bool
inStdlibPair (n, _) = inStdlib n

-- keep the first (name, loc) per distinct name, preserving order
-- (#242: order-preserving dedup on the name key → shared support.util.dedupBy)
dedupeNamesLoc : List (String, Option Loc) -> List (String, Option Loc)
dedupeNamesLoc xs = dedupBy fst xs

inStdlib : String -> Bool
inStdlib n = contains n stdlibNames

stdlibFinding : (String, Option Loc) -> Finding
stdlibFinding (name, loc) = Finding {
  rule = ruleNameStdlibReimpl,
  message = "top-level '" ++ name ++ "' shadows a stdlib function — use the stdlib version",
  severity = SevWarning,
  loc = loc,
}

-- ── rule: missing-signature ───────────────────────────────────────────────────
-- Flag a top-level value/function binding (`DFunDef`, incl. through `DAttrib`)
-- whose name has NO sibling top-level `name : Type` signature (`DTypeSig`) in the
-- same file — Haskell's -Wmissing-signatures.  Purely syntactic: build the set of
-- signed names, then report `DFunDef` names absent from it.  `impl`/`interface`
-- method bodies are nested inside their own decl (not top-level `Decl`s), so a
-- `List Decl` walk never sees them; `prop`/`test`/`extern` are their own decl
-- kinds, not `DFunDef`, so they are excluded automatically.  `main` is exempt by
-- name (entry-point boilerplate).  Multi-clause defs dedupe to one finding.
ruleMissingSignature : String -> String -> Positions -> List Decl -> List Finding
ruleMissingSignature _ _ pos prog =
  -- HashMap-as-set: `contains n sigNames` over the signed-name LIST was O(signs)
  -- per def, i.e. O(defs x signs) across the filterList — and in the common case
  -- where most defs ARE signed, signs grows with defs, so this was quadratic. It
  -- is a PURE SCAN (no extra allocation), so the alloc signal is blind to it and
  -- only the `manydefs` shape's lint-stage TIME catches it (the issue-#110 class).
  map
    missingSigFinding
    (filterList
      (missingSigPair (nameSetOf (flatMap topSigNameL prog)))
      (dedupeNamesLoc (flatMap topDefNameL (declLocList pos prog))))

topSigNameL : Decl -> List String
topSigNameL (DTypeSig _ name _) = [name]
topSigNameL (DAttrib _ d) = topSigNameL d
topSigNameL _ = []

missingSigPair : HashMap String Unit -> (String, Option Loc) -> Bool
missingSigPair sigNames (n, _) = not (n == "main" || has n sigNames)

missingSigFinding : (String, Option Loc) -> Finding
missingSigFinding (name, loc) = Finding {
  rule = ruleNameMissingSignature,
  message = "top-level '\{name}' has no type signature. Add a `\{name} : …` declaration",
  severity = SevWarning,
  loc = loc,
}

-- ── rule: self-shadow-extern (#266) ───────────────────────────────────────────
-- A top-level binding that UNCONDITIONALLY forwards to itself, with no branch that
-- could supply a base case.  The classic shape is an extern re-export written under
-- the SAME name — `stringLength s = stringLength s`, intending to forward to the
-- `stringLength` extern but in fact recursing into the local binding forever — and
-- its value-level sibling `x = x`.  Both typecheck with ZERO diagnostics and
-- stack-overflow at runtime (#266, the repo's #1 check-green/run-dies class).
--
-- The predicate is extern-AGNOSTIC — decided from the raw AST alone:
--   * NULLARY binding `x = <body>` fires iff `<body>` is EXACTLY the bare self
--     reference `EVar x` (after stripping ELoc/EAnnot).  That is the forcing loop
--     `x = x`.  `x = f x` / `x = x + 1` are NOT flagged (head isn't the bare self).
--   * N-ARY binding `f a… = <body>` fires iff `<body>` is an application SPINE
--     whose head (after stripping wrappers) is `EVar f` — `f s = f s`,
--     `stringLength s = stringLength s`, `f s = f (s + 1)`: every one loops forever
--     because nothing between the `=` and the self-call can terminate it.
-- A body headed by `if`/`match`/`EGuards`/`let`/lambda is NOT an unconditional
-- self-call (the self-call, if any, sits inside a branch that may also NOT be
-- taken), so legitimate recursion — `fac`, `map`, ANY base-case recursion — is
-- skipped: it never has a bare self-call at the head.  `f x = f` (returns a partial
-- application, no loop) is skipped too — its body is an `EVar`, not an `EApp`.
--
-- To stay sound under MULTI-CLAUSE definitions, a name fires only when EVERY clause
-- of that name is an unconditional self-call: a single non-self clause is a
-- candidate base case (`f [] = 0` beside `f xs = f (tail xs)`), so the whole name
-- is spared.  Purely syntactic, no false-fire risk beyond genuinely-looping code.
ruleSelfShadowExtern : String -> String -> Positions -> List Decl -> List Finding
ruleSelfShadowExtern _ _ pos prog =
  selfShadowFindings (flatMap selfShadowClauseL (declLocList pos prog))

selfShadowFindings : List (String, List Pat, Expr, Option Loc) -> List Finding
selfShadowFindings clauses =
  map
    selfShadowFinding
    (filterList
      (allClausesSelfCall clauses)
      (dedupBy fst (map clauseNameLoc clauses)))

-- one (name, params, body, loc) tuple per top-level DFunDef (through DAttrib)
selfShadowClauseL : (Decl, Option Loc) -> List (String, List Pat, Expr, Option Loc)
selfShadowClauseL (DFunDef _ name pats body, loc) = [(name, pats, body, loc)]
selfShadowClauseL (DAttrib _ d, loc) = selfShadowClauseL (d, loc)
selfShadowClauseL _ = []

clauseNameLoc : (String, List Pat, Expr, Option Loc) -> (String, Option Loc)
clauseNameLoc (n, _, _, l) = (n, l)

-- every clause defining `name` is an unconditional self-call
allClausesSelfCall : List (String, List Pat, Expr, Option Loc) -> (String, Option Loc) -> Bool
allClausesSelfCall clauses (name, _) =
  allList (clauseSelfCallOrOther name) clauses

clauseSelfCallOrOther : String -> (String, List Pat, Expr, Option Loc) -> Bool
clauseSelfCallOrOther name (cn, pats, body, _) = cn != name
  || unconditionalSelfCall name pats body

-- nullary: body is exactly the bare self reference; n-ary: body is an application
-- spine whose head is the bare self reference.
unconditionalSelfCall : String -> List Pat -> Expr -> Bool
unconditionalSelfCall name [] body = isBareSelf name (stripWrap body)
unconditionalSelfCall name _ body = isHeadSelfApp name (stripWrap body)

stripWrap : Expr -> Expr
stripWrap (ELoc _ e) = stripWrap e
stripWrap (EAnnot e _) = stripWrap e
stripWrap e = e

isBareSelf : String -> Expr -> Bool
isBareSelf name (EVar w) = name == w
isBareSelf _ _ = False

isHeadSelfApp : String -> Expr -> Bool
isHeadSelfApp name (EApp f a) = isBareSelf name (appHead (stripWrap f))
isHeadSelfApp _ _ = False

appHead : Expr -> Expr
appHead e = match stripWrap e
  EApp f _ => appHead f
  x => x

selfShadowFinding : (String, Option Loc) -> Finding
selfShadowFinding (name, loc) = Finding {
  rule = ruleNameSelfShadowExtern,
  message = "top-level '\{name}' unconditionally calls itself with no base case — an infinite self-recursion, not a forward to a same-named extern/definition. Rename the binding (give it a distinct name) or add a terminating `match`/`if`/guard",
  severity = SevWarning,
  loc = loc,
}

-- ── rule: bind-then-destructure ───────────────────────────────────────────────
-- Inside any do/bare block, a `v <- e` bind immediately followed by a FINAL
-- statement `match v { pat => body }` (exactly one arm, no guards) where `pat` is
-- IRREFUTABLE (tuple/record/var/wildcard, recursively — OR a single-constructor
-- pattern `PCon c subps` where `c` is the SOLE constructor of its datatype, as
-- decided by the syntactic constructor `Oracle`, with all sub-patterns
-- recursively irrefutable) and `v` does NOT appear free in `body`.  Such a pair
-- is just `pat <- e` with `body` inlined.  Detection recurses into every nested
-- do/bare block in the decl body; the autofix is a pure AST rewrite (the
-- framework re-renders the returned Decl via the printer).
--
-- The `Oracle` is `frontend.exhaust.buildOracle` over the whole target file's
-- decls — a purely SYNTACTIC scan of constructor declarations (no typecheck),
-- so multi-ctor wrappers (`Some v <-`, `Ok x <-`, `Cons`/`Nil`) stay refutable
-- and are skipped, while genuine newtype/single-variant wrappers collapse.
--
-- `v`-not-free-in-`body` uses the same conservative printed whole-word scan the
-- §8 fixer relies on (`wholeWordIn`): it can only over-bail (suppress a real
-- finding), never produce an unsound fix.

-- a pattern is irrefutable iff it is a var/wildcard, a tuple/record whose
-- sub-patterns are all themselves irrefutable, or a single-constructor pattern
-- (the constructor is the only one of its datatype, per the syntactic oracle)
-- whose sub-patterns are all irrefutable.  Everything else (multi-ctor, cons,
-- list, literal, range, as-pattern) is refutable for this rule's purposes.
irrefutablePat : Oracle -> Pat -> Bool
irrefutablePat _ (PVar _ _) = True
irrefutablePat _ PWild = True
irrefutablePat orc (PTuple ps) = not (anyList (refutablePat orc) ps)
irrefutablePat orc (PRec _ fields _) = not (anyList (refutableField orc) fields)
irrefutablePat orc (PCon c subps) = ctorIsSole orc c
  && not (anyList (refutablePat orc) subps)
irrefutablePat _ _ = False

-- the constructor `c` is the unique constructor of its datatype (single-variant
-- `data`, or a record-as-data).  Both queries are pure syntactic oracle lookups.
ctorIsSole : Oracle -> String -> Bool
ctorIsSole orc c = match oGetCtorType orc c
  Some tyName => match oGetCtors orc tyName
    Some ctors => listLen ctors == 1
    None => False
  None => False

refutablePat : Oracle -> Pat -> Bool
refutablePat orc p = not (irrefutablePat orc p)

refutableField : Oracle -> RecPatField -> Bool
refutableField _ (RecPatField _ _ None) = False
refutableField orc (RecPatField _ _ (Some p)) = refutablePat orc p

-- the bound-var/pattern/expr/body of a collapsible bind-then-match tail, plus the
-- statements preceding it.  Returns None when the last two statements don't form
-- the irrefutable single-arm shape.
bindMatchTail : Oracle -> List DoStmt -> Option (List DoStmt, String, Pat, Expr, Expr)
bindMatchTail orc stmts = match splitTail2 stmts
  Some (prefix, DoBind (PVar v _) boundE, DoExpr matchE) =>
    bindMatchArm orc prefix v boundE (unwrapLoc matchE)
  _ => None

bindMatchArm : Oracle -> List DoStmt -> String -> Expr -> Expr -> Option (List DoStmt, String, Pat, Expr, Expr)
bindMatchArm orc prefix v boundE (EMatch scrut [Arm pat [] body])
  | scrutIsVar v (unwrapLoc scrut) && irrefutablePat orc pat && not (wholeWordIn v (exprToString body)) = Some (prefix, v, pat, boundE, body)
  | otherwise = None
bindMatchArm _ _ _ _ _ = None

scrutIsVar : String -> Expr -> Bool
scrutIsVar v (EVar w) = v == w
scrutIsVar _ _ = False

-- last two statements (prefix, second-to-last, last), or None if fewer than 2.
splitTail2 : List DoStmt -> Option (List DoStmt, DoStmt, DoStmt)
splitTail2 stmts = match reverseL stmts
  lst::scd::restRev => Some (reverseL restRev, scd, lst)
  _ => None

-- ── check ────────────────────────────────────────────────────────────────────
ruleBindThenDestructure : String -> String -> Positions -> List Decl -> List Finding
ruleBindThenDestructure _ _ pos prog =
  let orc = buildOracle prog
  flatMap (bindDestructureDeclL orc) (declLocList pos prog)

bindDestructureDeclL : Oracle -> (Decl, Option Loc) -> List Finding
bindDestructureDeclL orc (d, loc) =
  map (bindDestructureFinding loc) (declBindHits orc d)

declBindHits : Oracle -> Decl -> List String
declBindHits orc (DFunDef _ _ _ body) = collectBindHits orc body
declBindHits orc (DAttrib _ d) = declBindHits orc d
declBindHits _ _ = []

bindDestructureFinding : Option Loc -> String -> Finding
bindDestructureFinding loc v = Finding {
  rule = ruleNameBindThenDestructure,
  message = "binds '" ++ v ++ "' then immediately destructures it in a final `match`. Inline the pattern into the bind",
  severity = SevWarning,
  loc = loc,
}

-- collect every collapsible tail's bound-var name, recursing into all sub-exprs.
collectBindHits : Oracle -> Expr -> List String
collectBindHits orc e = tailHitOf orc e
  ++ flatMap (collectBindHits orc) (childExprs e)

tailHitOf : Oracle -> Expr -> List String
tailHitOf orc (EDo stmts) = hitNameOf orc stmts
tailHitOf orc (EBlock stmts) = hitNameOf orc stmts
tailHitOf _ _ = []

hitNameOf : Oracle -> List DoStmt -> List String
hitNameOf orc stmts = match bindMatchTail orc stmts
  Some (_, v, _, _, _) => [v]
  None => []

-- immediate sub-expressions of an expr (order irrelevant; used to recurse).
childExprs : Expr -> List Expr
childExprs (ELoc _ e) = [e]
childExprs (EDoOrigin _ e) = [e]
childExprs (EApp f x) = [f, x]
childExprs (ELam _ b) = [b]
childExprs (ELet _ _ _ e1 e2) = [e1, e2]
childExprs (EMatch s arms) = s :: flatMap armExprs arms
childExprs (EIf c t el) = [c, t, el]
childExprs (EBinOp _ a b _) = [a, b]
childExprs (EUnOp _ a _) = [a]
childExprs (EInfix _ a b) = [a, b]
childExprs (EFieldAccess e _ _) = [e]
childExprs (ETuple es) = es
childExprs (EListLit es) = es
childExprs (EArrayLit es) = es
childExprs (ERangeList lo hi _) = [lo, hi]
childExprs (ERangeArray lo hi _) = [lo, hi]
childExprs (ESlice e lo hi _ _) = [e, lo, hi]
childExprs (ELetGroup binds body) = flatMap letBindExprs binds ++ [body]
childExprs (ESection s) = sectionExprs s
childExprs (EIndex a i _) = [a, i]
childExprs (EAnnot e _) = [e]
childExprs (EHeadAnnot e _) = [e]
childExprs (EBlock stmts) = flatMap stmtExprs stmts
childExprs (EDo stmts) = flatMap stmtExprs stmts
childExprs (EStringInterp parts) = flatMap interpPartExprs parts
childExprs (EGuards arms) = flatMap guardArmExprs arms
childExprs (ERecordCreate _ fs) = map fieldAssignExpr fs
childExprs (ERecordUpdate e fs _) = e :: map fieldAssignExpr fs
childExprs (EVariantUpdate _ e fs) = e :: map fieldAssignExpr fs
childExprs (EMapLit _ kvs) = flatMap kvExprs kvs
childExprs (ESetLit _ es) = es
childExprs (EAsPat _ e) = [e]
childExprs _ = []

armExprs : Arm -> List Expr
armExprs (Arm _ gs body) = flatMap guardExprs gs ++ [body]

guardExprs : Guard -> List Expr
guardExprs (GBool e) = [e]
guardExprs (GBind _ e) = [e]

stmtExprs : DoStmt -> List Expr
stmtExprs (DoExpr e) = [e]
stmtExprs (DoBind _ e) = [e]
stmtExprs (DoLet _ _ _ e) = [e]
stmtExprs (DoAssign _ e) = [e]
stmtExprs (DoFieldAssign _ _ e) = [e]

letBindExprs : LetBind -> List Expr
letBindExprs (LetBind _ clauses) = flatMap funClauseExprs clauses

funClauseExprs : FunClause -> List Expr
funClauseExprs (FunClause _ body) = [body]

sectionExprs : Section -> List Expr
sectionExprs (SecBare _) = []
sectionExprs (SecRight _ e) = [e]
sectionExprs (SecLeft e _) = [e]

interpPartExprs : InterpPart -> List Expr
interpPartExprs (InterpStr _) = []
interpPartExprs (InterpExpr e) = [e]

guardArmExprs : GuardArm -> List Expr
guardArmExprs (GuardArm gs body) = flatMap guardExprs gs ++ [body]

fieldAssignExpr : FieldAssign -> Expr
fieldAssignExpr (FieldAssign _ e) = e

kvExprs : (Expr, Expr) -> List Expr
kvExprs (k, v) = [k, v]

-- ── autofix ──────────────────────────────────────────────────────────────────
-- Rebuild the decl body with every collapsible bind-then-match tail inlined.
-- The rewrite is structural (rebuilds every node), so we detect "did anything
-- change" by comparing the location-stripped sexp of the old vs new body — only
-- then do we return `Some [newDecl]` (the printer re-renders it).
bindThenDestructureFix : Oracle -> Decl -> Option (List Decl)
bindThenDestructureFix orc (DFunDef vis name pats body) =
  let body2 = rewriteBindExpr orc body
  if exprSexp body2 == exprSexp body then
    None
  else
    Some [DFunDef vis name pats body2]
bindThenDestructureFix orc (DAttrib a d) = match bindThenDestructureFix orc d
  Some [d2] => Some [DAttrib a d2]
  _ => None
bindThenDestructureFix _ _ = None

-- recursively rewrite, then collapse the tail of each do/bare block.
rewriteBindExpr : Oracle -> Expr -> Expr
rewriteBindExpr orc (ELoc l e) = ELoc l (rewriteBindExpr orc e)
rewriteBindExpr orc (EDoOrigin l e) = EDoOrigin l (rewriteBindExpr orc e)
rewriteBindExpr orc (EApp f x) =
  EApp (rewriteBindExpr orc f) (rewriteBindExpr orc x)
rewriteBindExpr orc (ELam ps b) = ELam ps (rewriteBindExpr orc b)
rewriteBindExpr orc (ELet m isf p e1 e2) =
  ELet m isf p (rewriteBindExpr orc e1) (rewriteBindExpr orc e2)
rewriteBindExpr orc (EMatch s arms) =
  EMatch (rewriteBindExpr orc s) (map (rewriteBindArm orc) arms)
rewriteBindExpr orc (EIf c t el) =
  EIf (rewriteBindExpr orc c) (rewriteBindExpr orc t) (rewriteBindExpr orc el)
rewriteBindExpr orc (EBinOp op a b r) =
  EBinOp op (rewriteBindExpr orc a) (rewriteBindExpr orc b) r
rewriteBindExpr orc (EUnOp op a r) = EUnOp op (rewriteBindExpr orc a) r
rewriteBindExpr orc (EInfix op a b) =
  EInfix op (rewriteBindExpr orc a) (rewriteBindExpr orc b)
rewriteBindExpr orc (EFieldAccess e f r) =
  EFieldAccess (rewriteBindExpr orc e) f r
rewriteBindExpr orc (ETuple es) = ETuple (map (rewriteBindExpr orc) es)
rewriteBindExpr orc (EListLit es) = EListLit (map (rewriteBindExpr orc) es)
rewriteBindExpr orc (EArrayLit es) = EArrayLit (map (rewriteBindExpr orc) es)
rewriteBindExpr orc (ERangeList lo hi i) =
  ERangeList (rewriteBindExpr orc lo) (rewriteBindExpr orc hi) i
rewriteBindExpr orc (ERangeArray lo hi i) =
  ERangeArray (rewriteBindExpr orc lo) (rewriteBindExpr orc hi) i
rewriteBindExpr orc (ESlice e lo hi i r) =
  ESlice
    (rewriteBindExpr orc e)
    (rewriteBindExpr orc lo)
    (rewriteBindExpr orc hi)
    i
    r
rewriteBindExpr orc (ELetGroup binds body) =
  ELetGroup (map (rewriteBindLet orc) binds) (rewriteBindExpr orc body)
rewriteBindExpr orc (ESection s) = ESection (rewriteBindSection orc s)
rewriteBindExpr orc (EIndex a i r) =
  EIndex (rewriteBindExpr orc a) (rewriteBindExpr orc i) r
rewriteBindExpr orc (EAnnot e t) = EAnnot (rewriteBindExpr orc e) t
rewriteBindExpr orc (EHeadAnnot e t) = EHeadAnnot (rewriteBindExpr orc e) t
rewriteBindExpr orc (EBlock stmts) =
  EBlock (collapseBindTail orc (map (rewriteBindStmt orc) stmts))
rewriteBindExpr orc (EDo stmts) =
  EDo (collapseBindTail orc (map (rewriteBindStmt orc) stmts))
rewriteBindExpr orc (EStringInterp parts) =
  EStringInterp (map (rewriteBindInterp orc) parts)
rewriteBindExpr orc (EGuards arms) =
  EGuards (map (rewriteBindGuardArm orc) arms)
rewriteBindExpr orc (ERecordCreate n fs) =
  ERecordCreate n (map (rewriteBindField orc) fs)
rewriteBindExpr orc (ERecordUpdate e fs r) =
  ERecordUpdate (rewriteBindExpr orc e) (map (rewriteBindField orc) fs) r
rewriteBindExpr orc (EVariantUpdate c e fs) =
  EVariantUpdate c (rewriteBindExpr orc e) (map (rewriteBindField orc) fs)
rewriteBindExpr orc (EMapLit n kvs) = EMapLit n (map (rewriteBindKv orc) kvs)
rewriteBindExpr orc (ESetLit n es) = ESetLit n (map (rewriteBindExpr orc) es)
rewriteBindExpr orc (EAsPat x e) = EAsPat x (rewriteBindExpr orc e)
rewriteBindExpr _ e = e

-- collapse a (already child-rewritten) statement list: if its last two statements
-- are the irrefutable bind-then-match shape, replace them with `pat <- e` plus the
-- arm body's statements spliced inline.
collapseBindTail : Oracle -> List DoStmt -> List DoStmt
collapseBindTail orc stmts = match bindMatchTail orc stmts
  Some (prefix, _, pat, boundE, body) => prefix
    ++ (DoBind pat boundE :: bodyToStmts body)
  None => stmts

-- the arm body as statements: a do/bare block contributes its own statements
-- (flattened into the outer block); anything else becomes a final expr-statement.
bodyToStmts : Expr -> List DoStmt
bodyToStmts e = match unwrapLoc e
  EDo stmts => stmts
  EBlock stmts => stmts
  _ => [DoExpr e]

rewriteBindStmt : Oracle -> DoStmt -> DoStmt
rewriteBindStmt orc (DoExpr e) = DoExpr (rewriteBindExpr orc e)
rewriteBindStmt orc (DoBind p e) = DoBind p (rewriteBindExpr orc e)
rewriteBindStmt orc (DoLet m r p e) = DoLet m r p (rewriteBindExpr orc e)
rewriteBindStmt orc (DoAssign x e) = DoAssign x (rewriteBindExpr orc e)
rewriteBindStmt orc (DoFieldAssign x fs e) =
  DoFieldAssign x fs (rewriteBindExpr orc e)

rewriteBindArm : Oracle -> Arm -> Arm
rewriteBindArm orc (Arm p gs body) =
  Arm p (map (rewriteBindGuard orc) gs) (rewriteBindExpr orc body)

rewriteBindGuard : Oracle -> Guard -> Guard
rewriteBindGuard orc (GBool e) = GBool (rewriteBindExpr orc e)
rewriteBindGuard orc (GBind p e) = GBind p (rewriteBindExpr orc e)

rewriteBindLet : Oracle -> LetBind -> LetBind
rewriteBindLet orc (LetBind n clauses) =
  LetBind n (map (rewriteBindClause orc) clauses)

rewriteBindClause : Oracle -> FunClause -> FunClause
rewriteBindClause orc (FunClause ps body) =
  FunClause ps (rewriteBindExpr orc body)

rewriteBindSection : Oracle -> Section -> Section
rewriteBindSection _ (SecBare op) = SecBare op
rewriteBindSection orc (SecRight op e) = SecRight op (rewriteBindExpr orc e)
rewriteBindSection orc (SecLeft e op) = SecLeft (rewriteBindExpr orc e) op

rewriteBindInterp : Oracle -> InterpPart -> InterpPart
rewriteBindInterp _ (InterpStr s) = InterpStr s
rewriteBindInterp orc (InterpExpr e) = InterpExpr (rewriteBindExpr orc e)

rewriteBindGuardArm : Oracle -> GuardArm -> GuardArm
rewriteBindGuardArm orc (GuardArm gs body) =
  GuardArm (map (rewriteBindGuard orc) gs) (rewriteBindExpr orc body)

rewriteBindField : Oracle -> FieldAssign -> FieldAssign
rewriteBindField orc (FieldAssign n e) = FieldAssign n (rewriteBindExpr orc e)

rewriteBindKv : Oracle -> (Expr, Expr) -> (Expr, Expr)
rewriteBindKv orc (k, v) = (rewriteBindExpr orc k, rewriteBindExpr orc v)

-- ── rule: lambda-section (STYLE "Dogfooding" — operator sections) ─────────────
-- A single-clause lambda whose body is ONE binary operation on its bound
-- parameter(s), rewritable to the canonical operator SECTION idiom:
--   (x => x OP e)   [e free of x]  → (OP e)    right section  ESection (SecRight OP e)
--   (x => e OP x)   [e free of x]  → (e OP _)   left section   ESection (SecLeft e OP)
--   (x y => x OP y)  [x ≠ y]       → (OP)       bare section   ESection (SecBare OP)
--
-- CONSERVATISM (a false positive here CORRUPTS code):
--   * single-param: the param must be EXACTLY one operand of the OUTERMOST binary
--     op (a bare `EVar x` leaf); the OTHER operand must NOT mention x anywhere.
--     So `x => x OP x`, `x => f x OP e`, `x => (x + 1) OP e` all skip.
--   * two-param: body is exactly `EVar x OP EVar y` (in order, distinct names).
--   * only the SYMBOLIC operators the parser accepts as sections round-trip
--     (`sectionOpStr` in parser.mdk): + * / == != < > <= >= && || :: ++ |> >> <<,
--     plus `-` for LEFT/BARE only (a `-` RIGHT section `(- e)` parses as unary
--     negation — EXCLUDED).  Backtick infix (`EInfix`) is NOT handled: the printer
--     emits a word-operator section without backticks, so it would not round-trip.
--   * `ELam` is inherently single-clause / guard-free, so no extra guard check is
--     needed (contrast the §8 match-on-param rule).
-- The check walks the WHOLE decl expression tree (a lambda can nest anywhere) —
-- including impl-method bodies; the fix rebuilds the tree converting every
-- eligible lambda to `ESection`.

-- symbolic operators that round-trip as a section (parser.mdk `sectionOpStr`).
sectionSymOps : List String
sectionSymOps = [
  "+",
  "*",
  "/",
  "==",
  "!=",
  "<",
  ">",
  "<=",
  ">=",
  "&&",
  "||",
  "::",
  "++",
  "|>",
  ">>",
  "<<",
]

-- `-` is a valid LEFT/BARE section but NOT a right section (`(- e)` = negation).
rightSectionOp : String -> Bool
rightSectionOp op = contains op sectionSymOps

leftSectionOp : String -> Bool
leftSectionOp op = op == "-" || contains op sectionSymOps

bareSectionOp : String -> Bool
bareSectionOp op = op == "-" || contains op sectionSymOps

-- an `EVar x` leaf (under any ELoc wrapper)
isEVarNamed : String -> Expr -> Bool
isEVarNamed x e = match unwrapLoc e
  EVar w => w == x
  _ => False

-- does `x` occur (conservatively: anywhere) in `e`?  A nested binder re-binding
-- `x` only makes this OVER-count → we bail (safe), never rewrite unsoundly.
mentionsVar : String -> Expr -> Bool
mentionsVar x e = match unwrapLoc e
  EVar w => w == x
  e2 => anyList (mentionsVar x) (childExprs e2)

-- the section a lambda collapses to, or None if it is not an eligible shape.
lamSection : List Pat -> Expr -> Option Section
lamSection [PVar x _] body = lamSection1 x (unwrapLoc body)
lamSection [PVar x _, PVar y _] body
  | x != y = lamSection2 x y (unwrapLoc body)
  | otherwise = None
lamSection _ _ = None

lamSection1 : String -> Expr -> Option Section
lamSection1 x (EBinOp op a b _)
  | isEVarNamed x a && rightSectionOp op && not (mentionsVar x b) =
    Some (SecRight op b)
  | isEVarNamed x b && leftSectionOp op && not (mentionsVar x a) =
    Some (SecLeft a op)
  | otherwise = None
lamSection1 _ _ = None

lamSection2 : String -> String -> Expr -> Option Section
lamSection2 x y (EBinOp op a b _)
  | isEVarNamed x a && isEVarNamed y b && bareSectionOp op = Some (SecBare op)
  | otherwise = None
lamSection2 _ _ _ = None

-- ── check ─────────────────────────────────────────────────────────────────────
ruleLambdaSection : String -> String -> Positions -> List Decl -> List Finding
ruleLambdaSection _ _ pos prog =
  flatMap lambdaSectionDeclL (declLocList pos prog)

lambdaSectionDeclL : (Decl, Option Loc) -> List Finding
lambdaSectionDeclL (d, loc) = map (lambdaSectionFinding loc) (declLamSections d)

declLamSections : Decl -> List Section
declLamSections (DFunDef _ _ _ body) = collectLamSections body
declLamSections (DImpl { methods, ... }) = flatMap implMethodLamSections methods
declLamSections (DAttrib _ d) = declLamSections d
declLamSections _ = []

implMethodLamSections : ImplMethod -> List Section
implMethodLamSections (ImplMethod _ _ body) = collectLamSections body

-- every eligible lambda anywhere in the expression tree (order irrelevant).
collectLamSections : Expr -> List Section
collectLamSections e = lamHitOf e ++ flatMap collectLamSections (childExprs e)

lamHitOf : Expr -> List Section
lamHitOf (ELam pats body) = optSectionToList (lamSection pats body)
lamHitOf _ = []

optSectionToList : Option Section -> List Section
optSectionToList (Some s) = [s]
optSectionToList None = []

lambdaSectionFinding : Option Loc -> Section -> Finding
lambdaSectionFinding loc s = Finding {
  rule = ruleNameLambdaSection,
  message = "lambda is a single binary operation on its parameter(s). Rewrite as the operator section '" ++ exprToString (ESection s) ++ "'",
  severity = SevWarning,
  loc = loc,
}

-- ── autofix ───────────────────────────────────────────────────────────────────
-- Rebuild the decl body converting every eligible lambda to `ESection`.  Detects
-- "did anything change" by comparing the location-stripped sexp of old vs new.
lambdaSectionFix : Oracle -> Decl -> Option (List Decl)
lambdaSectionFix _ (DFunDef vis name pats body) =
  let body2 = rewriteLamExpr body
  if exprSexp body2 == exprSexp body then
    None
  else
    Some [DFunDef vis name pats body2]
lambdaSectionFix orc (DAttrib a d) = match lambdaSectionFix orc d
  Some [d2] => Some [DAttrib a d2]
  _ => None
lambdaSectionFix _ (DImpl { pub, iface, tys, reqs, methods }) =
  let methods2 = map fixImplMethod methods
  if implMethodsBodyKey methods2 == implMethodsBodyKey methods then
    None
  else
    Some [
      DImpl {
        pub = pub,
        iface = iface,
        tys = tys,
        reqs = reqs,
        methods = methods2,
      }
    ]
lambdaSectionFix _ _ = None

fixImplMethod : ImplMethod -> ImplMethod
fixImplMethod (ImplMethod nm ps body) = ImplMethod nm ps (rewriteLamExpr body)

implMethodsBodyKey : List ImplMethod -> String
implMethodsBodyKey ms = joinNl (map implMethodBodySexp ms)

implMethodBodySexp : ImplMethod -> String
implMethodBodySexp (ImplMethod _ _ body) = exprSexp body

-- if a rewritten lambda is an eligible section, collapse it; else keep it.
tryLamSection : List Pat -> Expr -> Expr
tryLamSection ps b = match lamSection ps b
  Some s => ESection s
  None => ELam ps b

-- recursively rewrite children (bottom-up), then collapse THIS lambda if eligible.
rewriteLamExpr : Expr -> Expr
rewriteLamExpr (ELoc l e) = ELoc l (rewriteLamExpr e)
rewriteLamExpr (EDoOrigin l e) = EDoOrigin l (rewriteLamExpr e)
rewriteLamExpr (EApp f x) = EApp (rewriteLamExpr f) (rewriteLamExpr x)
rewriteLamExpr (ELam ps b) = tryLamSection ps (rewriteLamExpr b)
rewriteLamExpr (ELet m isf p e1 e2) =
  ELet m isf p (rewriteLamExpr e1) (rewriteLamExpr e2)
rewriteLamExpr (EMatch s arms) =
  EMatch (rewriteLamExpr s) (map rewriteLamArm arms)
rewriteLamExpr (EIf c t el) =
  EIf (rewriteLamExpr c) (rewriteLamExpr t) (rewriteLamExpr el)
rewriteLamExpr (EBinOp op a b r) =
  EBinOp op (rewriteLamExpr a) (rewriteLamExpr b) r
rewriteLamExpr (EUnOp op a r) = EUnOp op (rewriteLamExpr a) r
rewriteLamExpr (EInfix op a b) = EInfix op (rewriteLamExpr a) (rewriteLamExpr b)
rewriteLamExpr (EFieldAccess e f r) = EFieldAccess (rewriteLamExpr e) f r
rewriteLamExpr (ETuple es) = ETuple (map rewriteLamExpr es)
rewriteLamExpr (EListLit es) = EListLit (map rewriteLamExpr es)
rewriteLamExpr (EArrayLit es) = EArrayLit (map rewriteLamExpr es)
rewriteLamExpr (ERangeList lo hi i) =
  ERangeList (rewriteLamExpr lo) (rewriteLamExpr hi) i
rewriteLamExpr (ERangeArray lo hi i) =
  ERangeArray (rewriteLamExpr lo) (rewriteLamExpr hi) i
rewriteLamExpr (ESlice e lo hi i r) =
  ESlice (rewriteLamExpr e) (rewriteLamExpr lo) (rewriteLamExpr hi) i r
rewriteLamExpr (ELetGroup binds body) =
  ELetGroup (map rewriteLamLet binds) (rewriteLamExpr body)
rewriteLamExpr (ESection s) = ESection (rewriteLamSection s)
rewriteLamExpr (EIndex a i r) = EIndex (rewriteLamExpr a) (rewriteLamExpr i) r
rewriteLamExpr (EAnnot e t) = EAnnot (rewriteLamExpr e) t
rewriteLamExpr (EHeadAnnot e t) = EHeadAnnot (rewriteLamExpr e) t
rewriteLamExpr (EBlock stmts) = EBlock (map rewriteLamStmt stmts)
rewriteLamExpr (EDo stmts) = EDo (map rewriteLamStmt stmts)
rewriteLamExpr (EStringInterp parts) =
  EStringInterp (map rewriteLamInterp parts)
rewriteLamExpr (EGuards arms) = EGuards (map rewriteLamGuardArm arms)
rewriteLamExpr (ERecordCreate n fs) = ERecordCreate n (map rewriteLamField fs)
rewriteLamExpr (ERecordUpdate e fs r) =
  ERecordUpdate (rewriteLamExpr e) (map rewriteLamField fs) r
rewriteLamExpr (EVariantUpdate c e fs) =
  EVariantUpdate c (rewriteLamExpr e) (map rewriteLamField fs)
rewriteLamExpr (EMapLit n kvs) = EMapLit n (map rewriteLamKv kvs)
rewriteLamExpr (ESetLit n es) = ESetLit n (map rewriteLamExpr es)
rewriteLamExpr (EAsPat x e) = EAsPat x (rewriteLamExpr e)
rewriteLamExpr e = e

rewriteLamStmt : DoStmt -> DoStmt
rewriteLamStmt (DoExpr e) = DoExpr (rewriteLamExpr e)
rewriteLamStmt (DoBind p e) = DoBind p (rewriteLamExpr e)
rewriteLamStmt (DoLet m r p e) = DoLet m r p (rewriteLamExpr e)
rewriteLamStmt (DoAssign x e) = DoAssign x (rewriteLamExpr e)
rewriteLamStmt (DoFieldAssign x fs e) = DoFieldAssign x fs (rewriteLamExpr e)

rewriteLamArm : Arm -> Arm
rewriteLamArm (Arm p gs body) =
  Arm p (map rewriteLamGuard gs) (rewriteLamExpr body)

rewriteLamGuard : Guard -> Guard
rewriteLamGuard (GBool e) = GBool (rewriteLamExpr e)
rewriteLamGuard (GBind p e) = GBind p (rewriteLamExpr e)

rewriteLamLet : LetBind -> LetBind
rewriteLamLet (LetBind n clauses) = LetBind n (map rewriteLamClause clauses)

rewriteLamClause : FunClause -> FunClause
rewriteLamClause (FunClause ps body) = FunClause ps (rewriteLamExpr body)

rewriteLamSection : Section -> Section
rewriteLamSection (SecBare op) = SecBare op
rewriteLamSection (SecRight op e) = SecRight op (rewriteLamExpr e)
rewriteLamSection (SecLeft e op) = SecLeft (rewriteLamExpr e) op

rewriteLamInterp : InterpPart -> InterpPart
rewriteLamInterp (InterpStr s) = InterpStr s
rewriteLamInterp (InterpExpr e) = InterpExpr (rewriteLamExpr e)

rewriteLamGuardArm : GuardArm -> GuardArm
rewriteLamGuardArm (GuardArm gs body) =
  GuardArm (map rewriteLamGuard gs) (rewriteLamExpr body)

rewriteLamField : FieldAssign -> FieldAssign
rewriteLamField (FieldAssign n e) = FieldAssign n (rewriteLamExpr e)

rewriteLamKv : (Expr, Expr) -> (Expr, Expr)
rewriteLamKv (k, v) = (rewriteLamExpr k, rewriteLamExpr v)

-- ── rule: if-max-min (an `if` selecting the larger/smaller of two operands) ────
-- `if a > b then a else b` (and the >=/</<=/reversed-branch variants) select the
-- SAME two operands as the comparison — rewritable to the canonical `max`/`min`
-- prelude methods (always in-scope `Ord` methods).
--
-- CONSERVATISM (a false positive here CORRUPTS code):
--   * the condition must be a comparison `EBinOp` with op in {>, >=, <, <=} —
--     symbolic ops only (backtick `EInfix` comparisons are a DIFFERENT node and
--     are not handled).
--   * `then`/`else` must each be STRUCTURALLY EQUAL (via `ir.sexp.exprSexp`,
--     which already strips source locations — the same comparator
--     `rule-duplicate-body` uses) to one of the two comparison operands, and
--     together must cover BOTH operands (one branch keys to `a`, the other to
--     `b`) — so `if x < 0 then 0 else x` (0 is not an operand) and
--     `if a > b then a else c` (c isn't b) both skip.
--   * if the two operands are themselves structurally identical, skip (the
--     rewrite is a no-op / degenerate — nothing to gain, and it hides which
--     operand the rule "picked").
-- The check walks the WHOLE decl expression tree (an `if` can nest anywhere) —
-- including impl-method bodies; the fix rebuilds the tree converting every
-- eligible `if` to a `max`/`min` application.

-- true for the four symbolic comparison operators this rule handles.
ifMaxMinCompareOp : String -> Bool
ifMaxMinCompareOp op = op == ">" || op == ">=" || op == "<" || op == "<="

-- which prelude fn the idiom collapses to when `then` keys to the LEFT operand
-- and `else` keys to the RIGHT operand (the "normal" orientation).
ifMaxMinFnNormal : String -> String
ifMaxMinFnNormal op
  | op == ">" || op == ">=" = "max"
  | otherwise = "min"

-- ...and when the branches are REVERSED (`then` keys to the right operand).
ifMaxMinFnReversed : String -> String
ifMaxMinFnReversed op
  | op == ">" || op == ">=" = "min"
  | otherwise = "max"

-- a bare literal operand (`ELit`/`ENumLit`) disqualifies the idiom — a
-- clamp-to-constant shape like `if x < 0 then 0 else x` (max x 0) reads as a
-- deliberate clamp, not the "same two operands" max/min idiom this rule
-- targets, so it is conservatively left alone.
isLiteralExpr : Expr -> Bool
isLiteralExpr e = match unwrapLoc e
  ELit _ => True
  ENumLit _ _ _ _ => True
  _ => False

-- does `EIf cond t el` match the idiom?  Returns the prelude fn name plus the
-- comparison's left/right operands (always emitted left-then-right, regardless
-- of which branch order matched) — or `None` if not eligible.
ifMaxMinOf : Expr -> Expr -> Expr -> Option (String, Expr, Expr)
ifMaxMinOf cond t el = match unwrapLoc cond
  EBinOp op a b _ if ifMaxMinCompareOp op =>
    let aK = exprSexp a
    let bK = exprSexp b
    let tK = exprSexp t
    let eK = exprSexp el
    if aK == bK || isLiteralExpr a || isLiteralExpr b then
      None
    else if tK == aK && eK == bK then
      Some (ifMaxMinFnNormal op, a, b)
    else if tK == bK && eK == aK then
      Some (ifMaxMinFnReversed op, a, b)
    else
      None
  _ => None

-- ── check ─────────────────────────────────────────────────────────────────────
ruleIfMaxMin : String -> String -> Positions -> List Decl -> List Finding
ruleIfMaxMin _ _ pos prog = flatMap ifMaxMinDeclL (declLocList pos prog)

ifMaxMinDeclL : (Decl, Option Loc) -> List Finding
ifMaxMinDeclL (d, loc) = map (ifMaxMinFinding loc) (declIfMaxMinHits d)

declIfMaxMinHits : Decl -> List (String, Expr, Expr)
declIfMaxMinHits (DFunDef _ _ _ body) = collectIfMaxMinHits body
declIfMaxMinHits (DImpl { methods, ... }) =
  flatMap implMethodIfMaxMinHits methods
declIfMaxMinHits (DAttrib _ d) = declIfMaxMinHits d
declIfMaxMinHits _ = []

implMethodIfMaxMinHits : ImplMethod -> List (String, Expr, Expr)
implMethodIfMaxMinHits (ImplMethod _ _ body) = collectIfMaxMinHits body

-- every eligible `if` anywhere in the expression tree (order irrelevant).
collectIfMaxMinHits : Expr -> List (String, Expr, Expr)
collectIfMaxMinHits e = ifMaxMinHitOf e
  ++ flatMap collectIfMaxMinHits (childExprs e)

ifMaxMinHitOf : Expr -> List (String, Expr, Expr)
ifMaxMinHitOf (EIf cond t el) = optHitToList (ifMaxMinOf cond t el)
ifMaxMinHitOf _ = []

optHitToList : Option (String, Expr, Expr) -> List (String, Expr, Expr)
optHitToList (Some h) = [h]
optHitToList None = []

ifMaxMinFinding : Option Loc -> (String, Expr, Expr) -> Finding
ifMaxMinFinding loc (fn, a, b) = Finding {
  rule = ruleNameIfMaxMin,
  message = "if-then-else selects the \{if fn == "max" then "larger" else "smaller"} of the same two operands. Rewrite as '\{exprToString (EApp (EApp (EVar fn) a) b)}'",
  severity = SevWarning,
  loc = loc,
}

-- ── autofix ───────────────────────────────────────────────────────────────────
-- Rebuild the decl body converting every eligible `if` to a `max`/`min` call.
-- Detects "did anything change" by comparing the location-stripped sexp of old
-- vs new (same technique `lambdaSectionFix` uses).
ifMaxMinFix : Oracle -> Decl -> Option (List Decl)
ifMaxMinFix _ (DFunDef vis name pats body) =
  let body2 = rewriteIfMaxMinExpr body
  if exprSexp body2 == exprSexp body then
    None
  else
    Some [DFunDef vis name pats body2]
ifMaxMinFix orc (DAttrib a d) = match ifMaxMinFix orc d
  Some [d2] => Some [DAttrib a d2]
  _ => None
ifMaxMinFix _ (DImpl { pub, iface, tys, reqs, methods }) =
  let methods2 = map fixImplMethodIfMaxMin methods
  if implMethodsBodyKey methods2 == implMethodsBodyKey methods then
    None
  else
    Some [
      DImpl {
        pub = pub,
        iface = iface,
        tys = tys,
        reqs = reqs,
        methods = methods2,
      }
    ]
ifMaxMinFix _ _ = None

fixImplMethodIfMaxMin : ImplMethod -> ImplMethod
fixImplMethodIfMaxMin (ImplMethod nm ps body) =
  ImplMethod nm ps (rewriteIfMaxMinExpr body)

-- if a rewritten `if` is an eligible max/min shape, collapse it; else keep it.
tryIfMaxMin : Expr -> Expr -> Expr -> Expr
tryIfMaxMin cond t el = match ifMaxMinOf cond t el
  Some (fn, a, b) => EApp (EApp (EVar fn) a) b
  None => EIf cond t el

-- recursively rewrite children (bottom-up), then collapse THIS `if` if eligible.
rewriteIfMaxMinExpr : Expr -> Expr
rewriteIfMaxMinExpr (ELoc l e) = ELoc l (rewriteIfMaxMinExpr e)
rewriteIfMaxMinExpr (EDoOrigin l e) = EDoOrigin l (rewriteIfMaxMinExpr e)
rewriteIfMaxMinExpr (EApp f x) =
  EApp (rewriteIfMaxMinExpr f) (rewriteIfMaxMinExpr x)
rewriteIfMaxMinExpr (ELam ps b) = ELam ps (rewriteIfMaxMinExpr b)
rewriteIfMaxMinExpr (ELet m isf p e1 e2) =
  ELet m isf p (rewriteIfMaxMinExpr e1) (rewriteIfMaxMinExpr e2)
rewriteIfMaxMinExpr (EMatch s arms) =
  EMatch (rewriteIfMaxMinExpr s) (map rewriteIfMaxMinArm arms)
rewriteIfMaxMinExpr (EIf c t el) =
  tryIfMaxMin
    (rewriteIfMaxMinExpr c)
    (rewriteIfMaxMinExpr t)
    (rewriteIfMaxMinExpr el)
rewriteIfMaxMinExpr (EBinOp op a b r) =
  EBinOp op (rewriteIfMaxMinExpr a) (rewriteIfMaxMinExpr b) r
rewriteIfMaxMinExpr (EUnOp op a r) = EUnOp op (rewriteIfMaxMinExpr a) r
rewriteIfMaxMinExpr (EInfix op a b) =
  EInfix op (rewriteIfMaxMinExpr a) (rewriteIfMaxMinExpr b)
rewriteIfMaxMinExpr (EFieldAccess e f r) =
  EFieldAccess (rewriteIfMaxMinExpr e) f r
rewriteIfMaxMinExpr (ETuple es) = ETuple (map rewriteIfMaxMinExpr es)
rewriteIfMaxMinExpr (EListLit es) = EListLit (map rewriteIfMaxMinExpr es)
rewriteIfMaxMinExpr (EArrayLit es) = EArrayLit (map rewriteIfMaxMinExpr es)
rewriteIfMaxMinExpr (ERangeList lo hi i) =
  ERangeList (rewriteIfMaxMinExpr lo) (rewriteIfMaxMinExpr hi) i
rewriteIfMaxMinExpr (ERangeArray lo hi i) =
  ERangeArray (rewriteIfMaxMinExpr lo) (rewriteIfMaxMinExpr hi) i
rewriteIfMaxMinExpr (ESlice e lo hi i r) =
  ESlice
    (rewriteIfMaxMinExpr e)
    (rewriteIfMaxMinExpr lo)
    (rewriteIfMaxMinExpr hi)
    i
    r
rewriteIfMaxMinExpr (ELetGroup binds body) =
  ELetGroup (map rewriteIfMaxMinLet binds) (rewriteIfMaxMinExpr body)
rewriteIfMaxMinExpr (ESection s) = ESection (rewriteIfMaxMinSection s)
rewriteIfMaxMinExpr (EIndex a i r) =
  EIndex (rewriteIfMaxMinExpr a) (rewriteIfMaxMinExpr i) r
rewriteIfMaxMinExpr (EAnnot e t) = EAnnot (rewriteIfMaxMinExpr e) t
rewriteIfMaxMinExpr (EHeadAnnot e t) = EHeadAnnot (rewriteIfMaxMinExpr e) t
rewriteIfMaxMinExpr (EBlock stmts) = EBlock (map rewriteIfMaxMinStmt stmts)
rewriteIfMaxMinExpr (EDo stmts) = EDo (map rewriteIfMaxMinStmt stmts)
rewriteIfMaxMinExpr (EStringInterp parts) =
  EStringInterp (map rewriteIfMaxMinInterp parts)
rewriteIfMaxMinExpr (EGuards arms) = EGuards (map rewriteIfMaxMinGuardArm arms)
rewriteIfMaxMinExpr (ERecordCreate n fs) =
  ERecordCreate n (map rewriteIfMaxMinField fs)
rewriteIfMaxMinExpr (ERecordUpdate e fs r) =
  ERecordUpdate (rewriteIfMaxMinExpr e) (map rewriteIfMaxMinField fs) r
rewriteIfMaxMinExpr (EVariantUpdate c e fs) =
  EVariantUpdate c (rewriteIfMaxMinExpr e) (map rewriteIfMaxMinField fs)
rewriteIfMaxMinExpr (EMapLit n kvs) = EMapLit n (map rewriteIfMaxMinKv kvs)
rewriteIfMaxMinExpr (ESetLit n es) = ESetLit n (map rewriteIfMaxMinExpr es)
rewriteIfMaxMinExpr (EAsPat x e) = EAsPat x (rewriteIfMaxMinExpr e)
rewriteIfMaxMinExpr e = e

rewriteIfMaxMinStmt : DoStmt -> DoStmt
rewriteIfMaxMinStmt (DoExpr e) = DoExpr (rewriteIfMaxMinExpr e)
rewriteIfMaxMinStmt (DoBind p e) = DoBind p (rewriteIfMaxMinExpr e)
rewriteIfMaxMinStmt (DoLet m r p e) = DoLet m r p (rewriteIfMaxMinExpr e)
rewriteIfMaxMinStmt (DoAssign x e) = DoAssign x (rewriteIfMaxMinExpr e)
rewriteIfMaxMinStmt (DoFieldAssign x fs e) =
  DoFieldAssign x fs (rewriteIfMaxMinExpr e)

rewriteIfMaxMinArm : Arm -> Arm
rewriteIfMaxMinArm (Arm p gs body) =
  Arm p (map rewriteIfMaxMinGuard gs) (rewriteIfMaxMinExpr body)

rewriteIfMaxMinGuard : Guard -> Guard
rewriteIfMaxMinGuard (GBool e) = GBool (rewriteIfMaxMinExpr e)
rewriteIfMaxMinGuard (GBind p e) = GBind p (rewriteIfMaxMinExpr e)

rewriteIfMaxMinLet : LetBind -> LetBind
rewriteIfMaxMinLet (LetBind n clauses) =
  LetBind n (map rewriteIfMaxMinClause clauses)

rewriteIfMaxMinClause : FunClause -> FunClause
rewriteIfMaxMinClause (FunClause ps body) =
  FunClause ps (rewriteIfMaxMinExpr body)

rewriteIfMaxMinSection : Section -> Section
rewriteIfMaxMinSection (SecBare op) = SecBare op
rewriteIfMaxMinSection (SecRight op e) = SecRight op (rewriteIfMaxMinExpr e)
rewriteIfMaxMinSection (SecLeft e op) = SecLeft (rewriteIfMaxMinExpr e) op

rewriteIfMaxMinInterp : InterpPart -> InterpPart
rewriteIfMaxMinInterp (InterpStr s) = InterpStr s
rewriteIfMaxMinInterp (InterpExpr e) = InterpExpr (rewriteIfMaxMinExpr e)

rewriteIfMaxMinGuardArm : GuardArm -> GuardArm
rewriteIfMaxMinGuardArm (GuardArm gs body) =
  GuardArm (map rewriteIfMaxMinGuard gs) (rewriteIfMaxMinExpr body)

rewriteIfMaxMinField : FieldAssign -> FieldAssign
rewriteIfMaxMinField (FieldAssign n e) = FieldAssign n (rewriteIfMaxMinExpr e)

rewriteIfMaxMinKv : (Expr, Expr) -> (Expr, Expr)
rewriteIfMaxMinKv (k, v) = (rewriteIfMaxMinExpr k, rewriteIfMaxMinExpr v)

-- ── rule: andthen-pure-map (a monadic bind that just wraps a pure value) ───────
-- `andThen m (x => pure body)` re-wraps a PURE transformation of `m`'s result
-- back into the monad — exactly the functor law `m >>= (pure . f) ≡ fmap f m`.
-- In Medaka the bind is `andThen`, the wrap is `pure`, and the functor map is
-- `map`, so the idiom collapses to `map (x => body) m`.  When `body` is exactly
-- `f x` (x as `f`'s sole final argument, `f` not mentioning x) it eta-reduces
-- further to `map f m`.
--
-- SOUNDNESS: `Thenable m requires Applicative m`, `Applicative f requires
-- Mappable f` (stdlib/core.mdk), so ANY type with `andThen`/`pure` necessarily
-- has a `map` instance — the rewrite always has a `map` to resolve to.
--
-- CONSERVATISM (a false positive here CORRUPTS code):
--   * the continuation must be a SINGLE-param, plain-`PVar`, guard-free lambda
--     `(x => …)` (an `ELam [PVar x] body`; multi-param / destructuring /
--     `function` forms skip).
--   * the lambda body must be EXACTLY `pure <expr>` — a single application of the
--     bare name `pure` to one argument (an over-applied `pure a b` skips).
--   * the lambda param `x` must occur AT MOST ONCE in `<expr>` (so `x => pure
--     (g x x)` — "x used twice" — is left alone; the general rewrite would still
--     be sound but we stay conservative and, for the eta case, linear).
-- The check walks the WHOLE decl expression tree (the bind can nest anywhere) —
-- including impl-method bodies; the fix rebuilds the tree converting every
-- eligible bind to a `map` application, bottom-up.

-- occurrences of the variable name `x` in `e` (conservative: counts every EVar
-- leaf; a nested binder RE-BINDING x only OVER-counts → since we only rewrite
-- when the count is ≤ 1, over-counting is always SAFE — it can only suppress).
countVar : String -> Expr -> Int
countVar x e = match unwrapLoc e
  EVar w => if w == x then 1 else 0
  e2 => countVarList x (childExprs e2)

countVarList : String -> List Expr -> Int
countVarList _ [] = 0
countVarList x (e::es) = countVar x e + countVarList x es

-- if `arg` is `f x` — x as the SOLE final argument, `f` not mentioning x —
-- return `Some f` (the eta-reduced function); else `None`.
andThenEtaFn : String -> Expr -> Option Expr
andThenEtaFn x arg = match unwrapLoc arg
  EApp f lastArg if isEVarNamed x lastArg && not (mentionsVar x f) => Some f
  _ => None

-- build the `map …` replacement for `andThen m (x => pure arg)`: eta-reduce to
-- `map f m` when `arg` is `f x`, else `map (x => arg) m`.
buildAndThenMap : String -> Expr -> Expr -> Expr
buildAndThenMap x arg m = match andThenEtaFn x arg
  Some f => EApp (EApp (EVar "map") f) m
  None => EApp (EApp (EVar "map") (ELam [PVar x (Loc "" 0 0 0 0)] arg)) m

-- `andThen m (x => pure ARG)` with x occurring ≤ 1× in ARG → Some (the rewritten
-- `map …` expression); anything else → None.
andThenPureMapOf : Expr -> Option Expr
andThenPureMapOf e = match unwrapLoc e
  EApp inner cont => andThenPureMapApp (unwrapLoc inner) cont
  _ => None

andThenPureMapApp : Expr -> Expr -> Option Expr
andThenPureMapApp (EApp hd m) cont
  | isEVarNamed "andThen" hd = andThenPureMapCont m (unwrapLoc cont)
andThenPureMapApp _ _ = None

andThenPureMapCont : Expr -> Expr -> Option Expr
andThenPureMapCont m (ELam [PVar x _] body) =
  andThenPureMapBody m x (unwrapLoc body)
andThenPureMapCont _ _ = None

andThenPureMapBody : Expr -> String -> Expr -> Option Expr
andThenPureMapBody m x (EApp pureHd arg)
  | isEVarNamed "pure" pureHd && countVar x arg <= 1 =
    Some (buildAndThenMap x arg m)
andThenPureMapBody _ _ _ = None

-- ── check ─────────────────────────────────────────────────────────────────────
ruleAndThenPureMap : String -> String -> Positions -> List Decl -> List Finding
ruleAndThenPureMap _ _ pos prog =
  flatMap andThenPureMapDeclL (declLocList pos prog)

andThenPureMapDeclL : (Decl, Option Loc) -> List Finding
andThenPureMapDeclL (d, loc) =
  map (andThenPureMapFinding loc) (declAndThenPureMapHits d)

declAndThenPureMapHits : Decl -> List Expr
declAndThenPureMapHits (DFunDef _ _ _ body) = collectAndThenPureMapHits body
declAndThenPureMapHits (DImpl { methods, ... }) =
  flatMap implMethodAndThenPureMapHits methods
declAndThenPureMapHits (DAttrib _ d) = declAndThenPureMapHits d
declAndThenPureMapHits _ = []

implMethodAndThenPureMapHits : ImplMethod -> List Expr
implMethodAndThenPureMapHits (ImplMethod _ _ body) =
  collectAndThenPureMapHits body

-- every eligible bind anywhere in the expression tree (order irrelevant).  The
-- hit detector matches the RAW `EApp` (never an `ELoc` wrapper) so a location-
-- wrapped bind is counted exactly once — at the unwrapped node the tree walk
-- reaches — rather than twice (mirrors `lamHitOf` / `ifMaxMinHitOf`).
collectAndThenPureMapHits : Expr -> List Expr
collectAndThenPureMapHits e = andThenPureMapHitOf e
  ++ flatMap collectAndThenPureMapHits (childExprs e)

andThenPureMapHitOf : Expr -> List Expr
andThenPureMapHitOf (EApp inner cont) =
  optExprToList (andThenPureMapOf (EApp inner cont))
andThenPureMapHitOf _ = []

optExprToList : Option Expr -> List Expr
optExprToList (Some x) = [x]
optExprToList None = []

andThenPureMapFinding : Option Loc -> Expr -> Finding
andThenPureMapFinding loc rewritten = Finding {
  rule = ruleNameAndThenPureMap,
  message = "monadic bind wraps a pure transformation of its result — rewrite as '" ++ exprToString rewritten ++ "'",
  severity = SevWarning,
  loc = loc,
}

-- ── autofix ───────────────────────────────────────────────────────────────────
-- Rebuild the decl body converting every eligible bind to a `map` call.  Detects
-- "did anything change" by comparing the location-stripped sexp of old vs new
-- (same technique `lambdaSectionFix` / `ifMaxMinFix` use).
andThenPureMapFix : Oracle -> Decl -> Option (List Decl)
andThenPureMapFix _ (DFunDef vis name pats body) =
  let body2 = rewriteAndThenPureMapExpr body
  if exprSexp body2 == exprSexp body then
    None
  else
    Some [DFunDef vis name pats body2]
andThenPureMapFix orc (DAttrib a d) = match andThenPureMapFix orc d
  Some [d2] => Some [DAttrib a d2]
  _ => None
andThenPureMapFix _ (DImpl { pub, iface, tys, reqs, methods }) =
  let methods2 = map fixImplMethodAndThenPureMap methods
  if implMethodsBodyKey methods2 == implMethodsBodyKey methods then
    None
  else
    Some [
      DImpl {
        pub = pub,
        iface = iface,
        tys = tys,
        reqs = reqs,
        methods = methods2,
      }
    ]
andThenPureMapFix _ _ = None

fixImplMethodAndThenPureMap : ImplMethod -> ImplMethod
fixImplMethodAndThenPureMap (ImplMethod nm ps body) =
  ImplMethod nm ps (rewriteAndThenPureMapExpr body)

-- if a rewritten application is an eligible bind, collapse it; else keep it.
tryAndThenPureMap : Expr -> Expr
tryAndThenPureMap e = match andThenPureMapOf e
  Some rewritten => rewritten
  None => e

-- recursively rewrite children (bottom-up), then collapse THIS node if eligible.
rewriteAndThenPureMapExpr : Expr -> Expr
rewriteAndThenPureMapExpr (ELoc l e) = ELoc l (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapExpr (EDoOrigin l e) =
  EDoOrigin l (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapExpr (EApp f x) =
  tryAndThenPureMap (EApp
    (rewriteAndThenPureMapExpr f)
    (rewriteAndThenPureMapExpr x))
rewriteAndThenPureMapExpr (ELam ps b) = ELam ps (rewriteAndThenPureMapExpr b)
rewriteAndThenPureMapExpr (ELet m isf p e1 e2) =
  ELet m isf p (rewriteAndThenPureMapExpr e1) (rewriteAndThenPureMapExpr e2)
rewriteAndThenPureMapExpr (EMatch s arms) =
  EMatch (rewriteAndThenPureMapExpr s) (map rewriteAndThenPureMapArm arms)
rewriteAndThenPureMapExpr (EIf c t el) =
  EIf
    (rewriteAndThenPureMapExpr c)
    (rewriteAndThenPureMapExpr t)
    (rewriteAndThenPureMapExpr el)
rewriteAndThenPureMapExpr (EBinOp op a b r) =
  EBinOp op (rewriteAndThenPureMapExpr a) (rewriteAndThenPureMapExpr b) r
rewriteAndThenPureMapExpr (EUnOp op a r) =
  EUnOp op (rewriteAndThenPureMapExpr a) r
rewriteAndThenPureMapExpr (EInfix op a b) =
  EInfix op (rewriteAndThenPureMapExpr a) (rewriteAndThenPureMapExpr b)
rewriteAndThenPureMapExpr (EFieldAccess e f r) =
  EFieldAccess (rewriteAndThenPureMapExpr e) f r
rewriteAndThenPureMapExpr (ETuple es) =
  ETuple (map rewriteAndThenPureMapExpr es)
rewriteAndThenPureMapExpr (EListLit es) =
  EListLit (map rewriteAndThenPureMapExpr es)
rewriteAndThenPureMapExpr (EArrayLit es) =
  EArrayLit (map rewriteAndThenPureMapExpr es)
rewriteAndThenPureMapExpr (ERangeList lo hi i) =
  ERangeList (rewriteAndThenPureMapExpr lo) (rewriteAndThenPureMapExpr hi) i
rewriteAndThenPureMapExpr (ERangeArray lo hi i) =
  ERangeArray (rewriteAndThenPureMapExpr lo) (rewriteAndThenPureMapExpr hi) i
rewriteAndThenPureMapExpr (ESlice e lo hi i r) =
  ESlice
    (rewriteAndThenPureMapExpr e)
    (rewriteAndThenPureMapExpr lo)
    (rewriteAndThenPureMapExpr hi)
    i
    r
rewriteAndThenPureMapExpr (ELetGroup binds body) =
  ELetGroup
    (map rewriteAndThenPureMapLet binds)
    (rewriteAndThenPureMapExpr body)
rewriteAndThenPureMapExpr (ESection s) =
  ESection (rewriteAndThenPureMapSection s)
rewriteAndThenPureMapExpr (EIndex a i r) =
  EIndex (rewriteAndThenPureMapExpr a) (rewriteAndThenPureMapExpr i) r
rewriteAndThenPureMapExpr (EAnnot e t) = EAnnot (rewriteAndThenPureMapExpr e) t
rewriteAndThenPureMapExpr (EHeadAnnot e t) =
  EHeadAnnot (rewriteAndThenPureMapExpr e) t
rewriteAndThenPureMapExpr (EBlock stmts) =
  EBlock (map rewriteAndThenPureMapStmt stmts)
rewriteAndThenPureMapExpr (EDo stmts) =
  EDo (map rewriteAndThenPureMapStmt stmts)
rewriteAndThenPureMapExpr (EStringInterp parts) =
  EStringInterp (map rewriteAndThenPureMapInterp parts)
rewriteAndThenPureMapExpr (EGuards arms) =
  EGuards (map rewriteAndThenPureMapGuardArm arms)
rewriteAndThenPureMapExpr (ERecordCreate n fs) =
  ERecordCreate n (map rewriteAndThenPureMapField fs)
rewriteAndThenPureMapExpr (ERecordUpdate e fs r) =
  ERecordUpdate
    (rewriteAndThenPureMapExpr e)
    (map rewriteAndThenPureMapField fs)
    r
rewriteAndThenPureMapExpr (EVariantUpdate c e fs) =
  EVariantUpdate
    c
    (rewriteAndThenPureMapExpr e)
    (map rewriteAndThenPureMapField fs)
rewriteAndThenPureMapExpr (EMapLit n kvs) =
  EMapLit n (map rewriteAndThenPureMapKv kvs)
rewriteAndThenPureMapExpr (ESetLit n es) =
  ESetLit n (map rewriteAndThenPureMapExpr es)
rewriteAndThenPureMapExpr (EAsPat x e) = EAsPat x (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapExpr e = e

rewriteAndThenPureMapStmt : DoStmt -> DoStmt
rewriteAndThenPureMapStmt (DoExpr e) = DoExpr (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapStmt (DoBind p e) = DoBind p (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapStmt (DoLet m r p e) =
  DoLet m r p (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapStmt (DoAssign x e) =
  DoAssign x (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapStmt (DoFieldAssign x fs e) =
  DoFieldAssign x fs (rewriteAndThenPureMapExpr e)

rewriteAndThenPureMapArm : Arm -> Arm
rewriteAndThenPureMapArm (Arm p gs body) =
  Arm p (map rewriteAndThenPureMapGuard gs) (rewriteAndThenPureMapExpr body)

rewriteAndThenPureMapGuard : Guard -> Guard
rewriteAndThenPureMapGuard (GBool e) = GBool (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapGuard (GBind p e) = GBind p (rewriteAndThenPureMapExpr e)

rewriteAndThenPureMapLet : LetBind -> LetBind
rewriteAndThenPureMapLet (LetBind n clauses) =
  LetBind n (map rewriteAndThenPureMapClause clauses)

rewriteAndThenPureMapClause : FunClause -> FunClause
rewriteAndThenPureMapClause (FunClause ps body) =
  FunClause ps (rewriteAndThenPureMapExpr body)

rewriteAndThenPureMapSection : Section -> Section
rewriteAndThenPureMapSection (SecBare op) = SecBare op
rewriteAndThenPureMapSection (SecRight op e) =
  SecRight op (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapSection (SecLeft e op) =
  SecLeft (rewriteAndThenPureMapExpr e) op

rewriteAndThenPureMapInterp : InterpPart -> InterpPart
rewriteAndThenPureMapInterp (InterpStr s) = InterpStr s
rewriteAndThenPureMapInterp (InterpExpr e) =
  InterpExpr (rewriteAndThenPureMapExpr e)

rewriteAndThenPureMapGuardArm : GuardArm -> GuardArm
rewriteAndThenPureMapGuardArm (GuardArm gs body) =
  GuardArm (map rewriteAndThenPureMapGuard gs) (rewriteAndThenPureMapExpr body)

rewriteAndThenPureMapField : FieldAssign -> FieldAssign
rewriteAndThenPureMapField (FieldAssign n e) =
  FieldAssign n (rewriteAndThenPureMapExpr e)

rewriteAndThenPureMapKv : (Expr, Expr) -> (Expr, Expr)
rewriteAndThenPureMapKv (k, v) =
  (rewriteAndThenPureMapExpr k, rewriteAndThenPureMapExpr v)

-- ══ batch of local-expression simplification rules (shared generic walk) ═══════
-- The five rules below (`rule-not-eq`, `rule-bool-simplify`, `rule-rem-parity`,
-- `rule-double-reverse`, `rule-when-unless`) are all pure LOCAL-NODE rewrites: a
-- single AST node is recognised and replaced by an equivalent one, anywhere in a
-- decl body.  Rather than each hand-rolling the ~90-line whole-tree walk the
-- earlier rules use (`rewriteLamExpr` &c.), they share ONE generic bottom-up
-- rewriter (`mapChildExprs`/`rewriteExprBU`) plus generic check/fix drivers.  A
-- rule supplies only:
--   * a detector `Expr -> Option Expr` matching the RAW node (NOT under its outer
--     `ELoc` — `childExprs` descends through `ELoc`, so matching the wrapper too
--     would double-count; mirrors `andThenPureMapHitOf`).  It returns the
--     rewritten node.
--   * an excluded-decl-name predicate (a rule whose target idiom IS the body of a
--     stdlib primitive it rewrites TO — `isEven`/`isOdd` for rule-rem-parity,
--     `when`/`unless` for rule-when-unless — must skip that primitive's own
--     definition, or it would rewrite the body to an infinite self-reference).
-- Every rewrite is EXACTLY equivalent (see each rule's soundness note), so the
-- self-compile fixpoint stays byte-identical after the tree is fixed.

-- rebuild every immediate child expr with `g`, reconstructing this node.  Faithful
-- transcription of `rewriteLamExpr`'s node coverage MINUS its `ELam` special-case
-- (here `ELam` is an ordinary node), so the recursion visits the exact same set of
-- sub-expressions the other whole-tree rewriters do.
mapChildExprs : (Expr -> Expr) -> Expr -> Expr
mapChildExprs g (ELoc l e) = ELoc l (g e)
mapChildExprs g (EDoOrigin l e) = EDoOrigin l (g e)
mapChildExprs g (EApp f x) = EApp (g f) (g x)
mapChildExprs g (ELam ps b) = ELam ps (g b)
mapChildExprs g (ELet m isf p e1 e2) = ELet m isf p (g e1) (g e2)
mapChildExprs g (EMatch s arms) = EMatch (g s) (map (mapChildArm g) arms)
mapChildExprs g (EIf c t el) = EIf (g c) (g t) (g el)
mapChildExprs g (EBinOp op a b r) = EBinOp op (g a) (g b) r
mapChildExprs g (EUnOp op a r) = EUnOp op (g a) r
mapChildExprs g (EInfix op a b) = EInfix op (g a) (g b)
mapChildExprs g (EFieldAccess e f r) = EFieldAccess (g e) f r
mapChildExprs g (ETuple es) = ETuple (map g es)
mapChildExprs g (EListLit es) = EListLit (map g es)
mapChildExprs g (EArrayLit es) = EArrayLit (map g es)
mapChildExprs g (ERangeList lo hi i) = ERangeList (g lo) (g hi) i
mapChildExprs g (ERangeArray lo hi i) = ERangeArray (g lo) (g hi) i
mapChildExprs g (ESlice e lo hi i r) = ESlice (g e) (g lo) (g hi) i r
mapChildExprs g (ELetGroup binds body) =
  ELetGroup (map (mapChildLet g) binds) (g body)
mapChildExprs g (ESection s) = ESection (mapChildSection g s)
mapChildExprs g (EIndex a i r) = EIndex (g a) (g i) r
mapChildExprs g (EAnnot e t) = EAnnot (g e) t
mapChildExprs g (EHeadAnnot e t) = EHeadAnnot (g e) t
mapChildExprs g (EBlock stmts) = EBlock (map (mapChildStmt g) stmts)
mapChildExprs g (EDo stmts) = EDo (map (mapChildStmt g) stmts)
mapChildExprs g (EStringInterp parts) =
  EStringInterp (map (mapChildInterp g) parts)
mapChildExprs g (EGuards arms) = EGuards (map (mapChildGuardArm g) arms)
mapChildExprs g (ERecordCreate n fs) =
  ERecordCreate n (map (mapChildField g) fs)
mapChildExprs g (ERecordUpdate e fs r) =
  ERecordUpdate (g e) (map (mapChildField g) fs) r
mapChildExprs g (EVariantUpdate c e fs) =
  EVariantUpdate c (g e) (map (mapChildField g) fs)
mapChildExprs g (EMapLit n kvs) = EMapLit n (map (mapChildKv g) kvs)
mapChildExprs g (ESetLit n es) = ESetLit n (map g es)
mapChildExprs g (EAsPat x e) = EAsPat x (g e)
mapChildExprs _ e = e

mapChildStmt : (Expr -> Expr) -> DoStmt -> DoStmt
mapChildStmt g (DoExpr e) = DoExpr (g e)
mapChildStmt g (DoBind p e) = DoBind p (g e)
mapChildStmt g (DoLet m r p e) = DoLet m r p (g e)
mapChildStmt g (DoAssign x e) = DoAssign x (g e)
mapChildStmt g (DoFieldAssign x fs e) = DoFieldAssign x fs (g e)

mapChildArm : (Expr -> Expr) -> Arm -> Arm
mapChildArm g (Arm p gs body) = Arm p (map (mapChildGuard g) gs) (g body)

mapChildGuard : (Expr -> Expr) -> Guard -> Guard
mapChildGuard g (GBool e) = GBool (g e)
mapChildGuard g (GBind p e) = GBind p (g e)

mapChildLet : (Expr -> Expr) -> LetBind -> LetBind
mapChildLet g (LetBind n clauses) = LetBind n (map (mapChildClause g) clauses)

mapChildClause : (Expr -> Expr) -> FunClause -> FunClause
mapChildClause g (FunClause ps body) = FunClause ps (g body)

mapChildSection : (Expr -> Expr) -> Section -> Section
mapChildSection _ (SecBare op) = SecBare op
mapChildSection g (SecRight op e) = SecRight op (g e)
mapChildSection g (SecLeft e op) = SecLeft (g e) op

mapChildInterp : (Expr -> Expr) -> InterpPart -> InterpPart
mapChildInterp _ (InterpStr s) = InterpStr s
mapChildInterp g (InterpExpr e) = InterpExpr (g e)

mapChildGuardArm : (Expr -> Expr) -> GuardArm -> GuardArm
mapChildGuardArm g (GuardArm gs body) =
  GuardArm (map (mapChildGuard g) gs) (g body)

mapChildField : (Expr -> Expr) -> FieldAssign -> FieldAssign
mapChildField g (FieldAssign n e) = FieldAssign n (g e)

mapChildKv : (Expr -> Expr) -> (Expr, Expr) -> (Expr, Expr)
mapChildKv g (k, v) = (g k, g v)

-- generic bottom-up rewrite: rebuild children first, THEN apply the node-local
-- transform `f` at this (child-rewritten) node.  Bottom-up so a rewrite exposed by
-- an inner one (`not (not (not x))`) is re-collapsed by the enclosing node.
rewriteExprBU : (Expr -> Expr) -> Expr -> Expr
rewriteExprBU f e = f (mapChildExprs (rewriteExprBU f) e)

-- turn a detector into a total node transform (identity where it does not fire).
detApply : (Expr -> Option Expr) -> Expr -> Expr
detApply det e = match det e
  Some e2 => e2
  None => e

-- ── generic check driver ──────────────────────────────────────────────────────
-- Collect one finding per detector hit anywhere in a decl body, skipping decls
-- whose name the exclusion predicate rejects.  `mkFinding loc rewritten` builds
-- the rule's message from the rewritten node (for a helpful "prefer …" hint).
-- `loc` here is the HIT's own location (#649) — the nearest `ELoc` enclosing the
-- matched expression, tracked by `collectRewrites` as it descends — falling back
-- to the decl's location only for a hit with no enclosing `ELoc` on its path at
-- all (the decl-level `loc` threaded in as the initial "nearest so far").
exprRuleFindings : (String -> Bool) -> (Expr -> Option Expr) -> (Option Loc -> Expr -> Finding) -> Positions -> List Decl -> List Finding
exprRuleFindings excl det mkFinding pos prog =
  flatMap (exprRuleDeclL excl det mkFinding) (declLocList pos prog)

exprRuleDeclL : (String -> Bool) -> (Expr -> Option Expr) -> (Option Loc -> Expr -> Finding) -> (Decl, Option Loc) -> List Finding
exprRuleDeclL excl det mkFinding (d, loc) =
  map ((hitLoc, hit) => mkFinding hitLoc hit) (declRewriteHits excl det loc d)

declRewriteHits : (String -> Bool) -> (Expr -> Option Expr) -> Option Loc -> Decl -> List (Option Loc, Expr)
declRewriteHits excl det loc (DFunDef _ name _ body)
  | excl name = []
  | otherwise = collectRewrites loc det body
declRewriteHits _ det loc (DImpl { methods, ... }) =
  flatMap (implMethodRewriteHits loc det) methods
declRewriteHits excl det loc (DAttrib _ d) = declRewriteHits excl det loc d
declRewriteHits _ _ _ _ = []

implMethodRewriteHits : Option Loc -> (Expr -> Option Expr) -> ImplMethod -> List (Option Loc, Expr)
implMethodRewriteHits loc det (ImplMethod _ _ body) =
  collectRewrites loc det body

-- every detector hit anywhere in the tree, paired with ITS OWN location (#649).
-- `curLoc` tracks the nearest enclosing `ELoc` seen so far as we descend,
-- starting from the decl's location (the fallback for a hit with no `ELoc` on
-- its path).  The detector matches the RAW node — an `ELoc`-wrapped node
-- contributes nothing here, `childExprs` descends into it, and its `Loc`
-- becomes the new `curLoc` for everything beneath it — so each real node is
-- counted exactly once, now stamped with the location of the innermost `ELoc`
-- that actually wraps it (mirrors `collectLamSections`).
collectRewrites : Option Loc -> (Expr -> Option Expr) -> Expr -> List (Option Loc, Expr)
collectRewrites _ det (ELoc l e) = collectRewrites (Some l) det e
collectRewrites curLoc det e = optExprToLocList curLoc (det e)
  ++ flatMap (collectRewrites curLoc det) (childExprs e)

optExprToLocList : Option Loc -> Option Expr -> List (Option Loc, Expr)
optExprToLocList _ None = []
optExprToLocList loc (Some x) = [(loc, x)]

-- ── generic fix driver ────────────────────────────────────────────────────────
-- Rebuild the decl body applying `f` bottom-up; return `Some [newDecl]` only when
-- the location-stripped sexp changed (same change-detection the other fixers use).
-- Honors the excluded-decl-name predicate.
exprRuleFix : (String -> Bool) -> (Expr -> Expr) -> Decl -> Option (List Decl)
exprRuleFix excl f (DFunDef vis name pats body)
  | excl name = None
  | otherwise =
    let body2 = rewriteExprBU f body
    if exprSexp body2 == exprSexp body then
      None
    else
      Some [DFunDef vis name pats body2]
exprRuleFix excl f (DAttrib a d) = match exprRuleFix excl f d
  Some [d2] => Some [DAttrib a d2]
  _ => None
exprRuleFix _ f (DImpl { pub, iface, tys, reqs, methods }) =
  let methods2 = map (fixImplMethodWith f) methods
  if implMethodsBodyKey methods2 == implMethodsBodyKey methods then
    None
  else
    Some [
      DImpl {
        pub = pub,
        iface = iface,
        tys = tys,
        reqs = reqs,
        methods = methods2,
      }
    ]
exprRuleFix _ _ _ = None

fixImplMethodWith : (Expr -> Expr) -> ImplMethod -> ImplMethod
fixImplMethodWith f (ImplMethod nm ps body) =
  ImplMethod nm ps (rewriteExprBU f body)

-- no decls are excluded by name (the common case)
noExcl : String -> Bool
noExcl _ = False

-- ── shared node predicates ────────────────────────────────────────────────────

-- `e` is a logical negation `not X` (the `not` prelude fn) or `!X` (unary `!`);
-- return the negated operand `X`.  `not` parses to `EApp (EVar "not") X`.
notArgOf : Expr -> Option Expr
notArgOf (EApp hd x) = if isEVarNamed "not" hd then Some x else None
notArgOf (EUnOp "!" x _) = Some x
notArgOf _ = None

-- build `not e` in the canonical `not <e>` (prelude fn) form the printer renders.
mkNot : Expr -> Expr
mkNot e = EApp (EVar "not") e

isTrueLit : Expr -> Bool
isTrueLit e = isEVarNamed "True" e

isFalseLit : Expr -> Bool
isFalseLit e = isEVarNamed "False" e

isBoolLit : Expr -> Bool
isBoolLit e = isTrueLit e || isFalseLit e

-- `e` is the integer literal `k` — either an `ELit (LInt k)` or a Num-poly
-- `ENumLit k …` (the parser emits the latter for expression int literals; sexp
-- renders both identically, so both must be recognised).
isIntLit : Int -> Expr -> Bool
isIntLit k e = match unwrapLoc e
  ELit (LInt n) => n == k
  ENumLit n _ _ _ => n == k
  _ => False

-- ── rule: concat-to-interp ────────────────────────────────────────────────────
-- An `++` spine that mixes string LITERALS and expressions is string concat that
-- reads better as an interpolated string: `"  " ++ r ++ " = " ++ v` → `"  \{r} = \{v}"`.
--
-- SOUNDNESS.  `\{e}` auto-stringifies its hole; for a String-typed operand `\{s}`
-- renders `s` VERBATIM (identity, no quotes).  In a `++` chain that contains a
-- string LITERAL, `++` forces every operand to `String`, so mapping each
-- non-literal operand `e` → `\{e}` verbatim (preserving any `debug`/`show`
-- wrapper inside the hole) is exactly equivalent.  The printer escapes an
-- `InterpStr` part with the SAME `escSOne` it uses for a plain string literal, so
-- the literal text round-trips byte-for-byte.  Hence the self-compile fixpoint
-- stays byte-identical (interp desugars to the same concat).
--
-- FIRING CONDITION: the `++` spine has ≥1 string-literal operand (confirms String
-- concat, not list `++`) AND ≥2 non-literal operands (≥2 holes — the clear wins;
-- single-hole `"prefix: " ++ x` chains are left alone).  A chain whose literal
-- text already contains a `\{` sequence is SKIPPED (would collide with the
-- interpolation syntax).
--
-- `++` is left-associative (`chainl1`), so a chain nests leftward and a sub-chain
-- would fire again under the shared bottom-up driver; this rule therefore uses a
-- bespoke TOP-DOWN rewrite that fires once at the maximal chain and descends only
-- into hole operands (`rewriteConcatExpr`).

-- flatten a `++` spine into its operands, left-to-right (each still ELoc-wrapped).
concatOperands : Expr -> List Expr
concatOperands e = match unwrapLoc e
  EBinOp "++" l r _ => concatOperands l ++ [r]
  _ => [e]

-- an operand that is a string literal (possibly under ELoc); the decoded value.
strLitValueOf : Expr -> Option String
strLitValueOf e = match unwrapLoc e
  ELit (LString s) => Some s
  _ => None

isStrLitOperand : Expr -> Bool
isStrLitOperand e = match strLitValueOf e
  Some _ => True
  None => False

-- decoded literal value contains the 2-char sequence `\{` (would open an interp
-- hole) — such a literal is unsafe to inline into an interpolated string.
hasBackslashBrace : String -> Bool
hasBackslashBrace s =
  let cs = stringToChars s
  backslashBraceGo cs (arrayLength cs) 0

backslashBraceGo : Array Char -> Int -> Int -> Bool
backslashBraceGo cs n i
  | i + 1 >= n = False
  | arrayGetUnsafe i cs == '\\' && arrayGetUnsafe (i + 1) cs == '{' = True
  | otherwise = backslashBraceGo cs n (i + 1)

-- the chain qualifies: ≥1 literal, ≥2 non-literals, no literal already holds `\{`.
concatChainQualifies : List Expr -> Bool
concatChainQualifies ops =
  let lits = filterExprs isStrLitOperand ops
  let holes = filterExprs (e => not (isStrLitOperand e)) ops
  isNonEmptyL lits
    && listLen holes >= 2
    && not (anyList litHasBackslashBrace lits)

litHasBackslashBrace : Expr -> Bool
litHasBackslashBrace e = match strLitValueOf e
  Some s => hasBackslashBrace s
  None => False

filterExprs : (Expr -> Bool) -> List Expr -> List Expr
filterExprs p es = filter p es

-- build the interpolated-string parts, merging adjacent literal text.  A literal
-- operand contributes its decoded text; a non-literal operand `e` becomes the hole
-- `\{e}` with `e` recursively rewritten (so a nested chain inside a hole is fixed).
buildInterpParts : List Expr -> List InterpPart
buildInterpParts ops = mergeInterpStr (map operandToInterp ops)

operandToInterp : Expr -> InterpPart
operandToInterp e = match strLitValueOf e
  Some s => InterpStr s
  None => InterpExpr (rewriteConcatExpr e)

-- coalesce consecutive `InterpStr` parts into one (cosmetic + matches how the
-- lexer would re-tokenise the emitted string).
mergeInterpStr : List InterpPart -> List InterpPart
mergeInterpStr [] = []
mergeInterpStr ((InterpStr a)::(InterpStr b)::rest) =
  mergeInterpStr (InterpStr (a ++ b) :: rest)
mergeInterpStr (p::rest) = p :: mergeInterpStr rest

-- fire on the RAW node only when it is a qualifying `++` chain top; return the
-- interpolated-string node.
concatChainOf : Expr -> Option Expr
concatChainOf (EBinOp "++" l r rf) =
  let ops = concatOperands (EBinOp "++" l r rf)
  if concatChainQualifies ops then
    Some (EStringInterp (buildInterpParts ops))
  else
    None
concatChainOf _ = None

-- top-down rewrite: fire once at the maximal chain, else descend into children.
rewriteConcatExpr : Expr -> Expr
rewriteConcatExpr e = match concatChainOf e
  Some e2 => e2
  None => mapChildExprs rewriteConcatExpr e

-- one rewritten node per maximal chain; when a chain fires, still look for nested
-- chains inside its hole operands (NOT its consumed `++` spine).
collectConcatHits : Expr -> List Expr
collectConcatHits e = match concatChainOf e
  Some e2 => e2 :: flatMap collectConcatHits (concatOperands e)
  None => flatMap collectConcatHits (childExprs e)

ruleConcatToInterp : String -> String -> Positions -> List Decl -> List Finding
ruleConcatToInterp _ _ pos prog =
  flatMap concatToInterpDeclL (declLocList pos prog)

concatToInterpDeclL : (Decl, Option Loc) -> List Finding
concatToInterpDeclL (d, loc) =
  map (concatToInterpFinding loc) (declConcatHits d)

declConcatHits : Decl -> List Expr
declConcatHits (DFunDef _ _ _ body) = collectConcatHits body
declConcatHits (DImpl { methods, ... }) = flatMap implMethodConcatHits methods
declConcatHits (DAttrib _ d) = declConcatHits d
declConcatHits _ = []

implMethodConcatHits : ImplMethod -> List Expr
implMethodConcatHits (ImplMethod _ _ body) = collectConcatHits body

concatToInterpFinding : Option Loc -> Expr -> Finding
concatToInterpFinding loc rewritten = Finding {
  rule = ruleNameConcatToInterp,
  message = "`++` chain of string literals and expressions. Rewrite as an interpolated string '" ++ exprToString rewritten ++ "'",
  severity = SevWarning,
  loc = loc,
}

concatToInterpFix : Oracle -> Decl -> Option (List Decl)
concatToInterpFix _ (DFunDef vis name pats body) =
  let body2 = rewriteConcatExpr body
  if exprSexp body2 == exprSexp body then
    None
  else
    Some [DFunDef vis name pats body2]
concatToInterpFix orc (DAttrib a d) = match concatToInterpFix orc d
  Some [d2] => Some [DAttrib a d2]
  _ => None
concatToInterpFix _ (DImpl { pub, iface, tys, reqs, methods }) =
  let methods2 = map fixImplMethodConcat methods
  if implMethodsBodyKey methods2 == implMethodsBodyKey methods then
    None
  else
    Some [
      DImpl {
        pub = pub,
        iface = iface,
        tys = tys,
        reqs = reqs,
        methods = methods2,
      }
    ]
concatToInterpFix _ _ = None

fixImplMethodConcat : ImplMethod -> ImplMethod
fixImplMethodConcat (ImplMethod nm ps body) =
  ImplMethod nm ps (rewriteConcatExpr body)

-- ── rule: not-eq ──────────────────────────────────────────────────────────────
-- `not (a == b)` → `a != b`; `not (a != b)` → `a == b` (also the unary-`!` forms).
-- ONLY `==`/`!=` — they are TOTAL, so De Morgan applies unconditionally.  `<`/`>`
-- &c. are deliberately excluded: their complement is unsound for `Float` (NaN
-- makes `not (a < b)` ≠ `a >= b`).  The flipped `EBinOp` reuses the original's
-- route ref (an unresolved parse-time placeholder; re-resolved downstream).
notEqOf : Expr -> Option Expr
notEqOf e = match notArgOf e
  Some inner => match unwrapLoc inner
    EBinOp "==" a b r => Some (EBinOp "!=" a b r)
    EBinOp "!=" a b r => Some (EBinOp "==" a b r)
    _ => None
  None => None

ruleNotEq : String -> String -> Positions -> List Decl -> List Finding
ruleNotEq _ _ pos prog = exprRuleFindings noExcl notEqOf notEqFinding pos prog

notEqFinding : Option Loc -> Expr -> Finding
notEqFinding loc rewritten = Finding {
  rule = ruleNameNotEq,
  message = "negated equality. Rewrite as '" ++ exprToString rewritten ++ "'",
  severity = SevWarning,
  loc = loc,
}

notEqFix : Oracle -> Decl -> Option (List Decl)
notEqFix _ d = exprRuleFix noExcl (detApply notEqOf) d

-- ── rule: bool-simplify ───────────────────────────────────────────────────────
-- Redundant boolean shapes, each rewritten to an EXACTLY equivalent one:
--   if c then True else False → c        if c then False else True → not c
--   x == True → x        x == False → not x        (also True/False on the LEFT)
--   x != True → not x    x != False → x
--   not (not x) → x      (`!(!x)` too)
-- Excluded (per spec): `if c then True else e` → `c || e` (short-circuit/effect
-- risk).  A comparison with bool literals on BOTH sides is left alone.
boolSimplifyOf : Expr -> Option Expr
boolSimplifyOf (EIf c t el) = boolSimplifyIf c (unwrapLoc t) (unwrapLoc el)
boolSimplifyOf (EBinOp op a b _)
  | op == "==" || op == "!=" = boolSimplifyEq op a b
boolSimplifyOf e = match notArgOf e
  Some inner => map (y => y) (notArgOf (unwrapLoc inner))
  None => None

boolSimplifyIf : Expr -> Expr -> Expr -> Option Expr
boolSimplifyIf c t el
  | isTrueLit t && isFalseLit el = Some c
  | isFalseLit t && isTrueLit el = Some (mkNot c)
  | otherwise = None

boolSimplifyEq : String -> Expr -> Expr -> Option Expr
boolSimplifyEq op a b
  | isBoolLit a && isBoolLit b = None
  | isTrueLit b = Some (boolEqResult op a True)
  | isFalseLit b = Some (boolEqResult op a False)
  | isTrueLit a = Some (boolEqResult op b True)
  | isFalseLit a = Some (boolEqResult op b False)
  | otherwise = None

-- the value operand `v`, negated iff (`==` against `False`) or (`!=` against
-- `True`): `keepPositive = (op == "==") == constIsTrue`.
boolEqResult : String -> Expr -> Bool -> Expr
boolEqResult op v constIsTrue = if op == "==" == constIsTrue then v else mkNot v

ruleBoolSimplify : String -> String -> Positions -> List Decl -> List Finding
ruleBoolSimplify _ _ pos prog =
  exprRuleFindings noExcl boolSimplifyOf boolSimplifyFinding pos prog

boolSimplifyFinding : Option Loc -> Expr -> Finding
boolSimplifyFinding loc rewritten = Finding {
  rule = ruleNameBoolSimplify,
  message = "redundant boolean expression — rewrite as '" ++ exprToString rewritten ++ "'",
  severity = SevWarning,
  loc = loc,
}

boolSimplifyFix : Oracle -> Decl -> Option (List Decl)
boolSimplifyFix _ d = exprRuleFix noExcl (detApply boolSimplifyOf) d

-- ── rule: rem-parity ──────────────────────────────────────────────────────────
-- `n % 2 == 0` → `isEven n`; `n % 2 != 0` → `isOdd n` (either operand order).
-- ONLY the `== 0` / `!= 0` comparisons: Medaka's `%` follows the DIVIDEND's sign
-- (`-3 % 2 = -1`), so `n % 2 == 1` is FALSE for negative odd `n` — excluded.
-- Excludes the `isEven`/`isOdd` definitions themselves (their bodies ARE this
-- idiom; rewriting them would produce `isEven n = isEven n`).
remParityExcl : String -> Bool
remParityExcl name = name == "isEven" || name == "isOdd"

remParityOf : Expr -> Option Expr
remParityOf (EBinOp op a b _)
  | op == "==" || op == "!=" =
    if isIntLit 0 b then
      remParityFrom op (unwrapLoc a)
    else if isIntLit 0 a then
      remParityFrom op (unwrapLoc b)
    else
      None
remParityOf _ = None

remParityFrom : String -> Expr -> Option Expr
remParityFrom op (EBinOp "%" n two _)
  | isIntLit 2 two = Some (EApp (EVar (parityFn op)) n)
remParityFrom _ _ = None

parityFn : String -> String
parityFn op = if op == "==" then "isEven" else "isOdd"

ruleRemParity : String -> String -> Positions -> List Decl -> List Finding
ruleRemParity _ _ pos prog =
  exprRuleFindings remParityExcl remParityOf remParityFinding pos prog

remParityFinding : Option Loc -> Expr -> Finding
remParityFinding loc rewritten = Finding {
  rule = ruleNameRemParity,
  message = "parity test. Rewrite as '" ++ exprToString rewritten ++ "'",
  severity = SevWarning,
  loc = loc,
}

remParityFix : Oracle -> Decl -> Option (List Decl)
remParityFix _ d = exprRuleFix remParityExcl (detApply remParityOf) d

-- ── rule: double-reverse ──────────────────────────────────────────────────────
-- `reverse (reverse x)` → `x` (`reverse` is an involution).
doubleReverseOf : Expr -> Option Expr
doubleReverseOf (EApp hd1 arg1)
  | isEVarNamed "reverse" hd1 = match unwrapLoc arg1
    EApp hd2 inner => if isEVarNamed "reverse" hd2 then Some inner else None
    _ => None
doubleReverseOf _ = None

ruleDoubleReverse : String -> String -> Positions -> List Decl -> List Finding
ruleDoubleReverse _ _ pos prog =
  exprRuleFindings noExcl doubleReverseOf doubleReverseFinding pos prog

doubleReverseFinding : Option Loc -> Expr -> Finding
doubleReverseFinding loc rewritten = Finding {
  rule = ruleNameDoubleReverse,
  message = "`reverse (reverse …)` is a no-op. Rewrite as '" ++ exprToString rewritten ++ "'",
  severity = SevWarning,
  loc = loc,
}

doubleReverseFix : Oracle -> Decl -> Option (List Decl)
doubleReverseFix _ d = exprRuleFix noExcl (detApply doubleReverseOf) d

-- ── rule: when-unless ─────────────────────────────────────────────────────────
-- `if b then m else pure ()` → `when b m`; `if b then pure () else m` → `unless b
-- m`.  Fires ONLY when the OTHER branch is EXACTLY `pure ()` (`EApp (EVar "pure")
-- (ELit LUnit)`).  Excludes the `when`/`unless` definitions themselves (their
-- bodies ARE this idiom → rewriting them would yield `when b m = when b m`).
whenUnlessExcl : String -> Bool
whenUnlessExcl name = name == "when" || name == "unless"

isPureUnit : Expr -> Bool
isPureUnit e = match unwrapLoc e
  EApp hd arg => isEVarNamed "pure" hd && isUnitLit (unwrapLoc arg)
  _ => False

isUnitLit : Expr -> Bool
isUnitLit (ELit LUnit) = True
isUnitLit _ = False

whenUnlessOf : Expr -> Option Expr
whenUnlessOf (EIf c t el)
  | isPureUnit el = Some (EApp (EApp (EVar "when") c) t)
  | isPureUnit t = Some (EApp (EApp (EVar "unless") c) el)
  | otherwise = None
whenUnlessOf _ = None

ruleWhenUnless : String -> String -> Positions -> List Decl -> List Finding
ruleWhenUnless _ _ pos prog =
  exprRuleFindings whenUnlessExcl whenUnlessOf whenUnlessFinding pos prog

whenUnlessFinding : Option Loc -> Expr -> Finding
whenUnlessFinding loc rewritten = Finding {
  rule = ruleNameWhenUnless,
  message = "conditional effect with a `pure ()` branch. Rewrite as '" ++ exprToString rewritten ++ "'",
  severity = SevWarning,
  loc = loc,
}

whenUnlessFix : Oracle -> Decl -> Option (List Decl)
whenUnlessFix _ d = exprRuleFix whenUnlessExcl (detApply whenUnlessOf) d

-- ── rule: complement-predicate ────────────────────────────────────────────────
-- `not (p args…)` where `p` is a registered predicate with a defined complement
-- `q`, rewritten to `q args…` (the args carried verbatim).  Curated BIDIRECTIONAL
-- pairs only — the complement must actually exist:
--   isEmptyL ↔ isNonEmptyL   (compiler `support/util.mdk`)
--   isEmptyList ↔ isNonEmptyList  (wasm_emit's private List helper + its complement)
--   isSome ↔ isNone          (prelude `core.mdk`)
--   isOk ↔ isErr             (prelude `core.mdk`)
-- Also matches the unary-`!` form (`notArgOf` handles both).  Purely syntactic —
-- only the exact registered names fire; anything else (`not (isEmptyL x && …)`,
-- `not (someOtherPred x)`) is left alone.  Excludes the complement helpers' OWN
-- definitions (`isNonEmptyL xs = not (isEmptyL xs)`) — their bodies ARE this idiom,
-- so rewriting would produce `isNonEmptyL xs = isNonEmptyL xs`.
complementExcl : String -> Bool
complementExcl name = name == "isNonEmptyL" || name == "isNonEmptyList"

complementOf : String -> Option String
complementOf "isEmptyL" = Some "isNonEmptyL"
complementOf "isNonEmptyL" = Some "isEmptyL"
complementOf "isEmptyList" = Some "isNonEmptyList"
complementOf "isNonEmptyList" = Some "isEmptyList"
complementOf "isSome" = Some "isNone"
complementOf "isNone" = Some "isSome"
complementOf "isOk" = Some "isErr"
complementOf "isErr" = Some "isOk"
complementOf _ = None

-- head var name of a (possibly curried multi-arg) application spine.
appSpineHead : Expr -> Option String
appSpineHead e = match unwrapLoc e
  EVar n => Some n
  EApp hd _ => appSpineHead (unwrapLoc hd)
  _ => None

-- rebuild the spine, renaming only the head var; every arg carried verbatim.
renameSpineHead : String -> Expr -> Expr
renameSpineHead newName e = match unwrapLoc e
  EVar _ => EVar newName
  EApp hd arg => EApp (renameSpineHead newName hd) arg
  _ => e

complementPredOf : Expr -> Option Expr
complementPredOf e = do
  inner <- notArgOf e
  name <- appSpineHead (unwrapLoc inner)
  comp <- complementOf name
  Some (renameSpineHead comp (unwrapLoc inner))

ruleComplementPredicate : String -> String -> Positions -> List Decl -> List Finding
ruleComplementPredicate _ _ pos prog =
  exprRuleFindings
    complementExcl
    complementPredOf
    complementPredicateFinding
    pos
    prog

complementPredicateFinding : Option Loc -> Expr -> Finding
complementPredicateFinding loc rewritten = Finding {
  rule = ruleNameComplementPredicate,
  message = "negated predicate. Rewrite as '" ++ exprToString rewritten ++ "'",
  severity = SevWarning,
  loc = loc,
}

complementPredicateFix : Oracle -> Decl -> Option (List Decl)
complementPredicateFix _ d =
  exprRuleFix complementExcl (detApply complementPredOf) d

-- ── rule: match-to-map ────────────────────────────────────────────────────────
-- A 2-arm `match` on an Option or Result that structurally IS a functor `map`
-- over the success side — rewrite to `map f o` (hlint "use fmap").  Fires on
-- EXACTLY these two shapes (the mapError/bimap variants fire nowhere in-tree):
--   Option: `match o { None => None; Some p => Some <expr> }` → `map (p => <expr>) o`
--   Result: `match r { Err v => Err v; Ok  p => Ok  <expr> }` → `map (p => <expr>) r`
-- Arm order is either way.  ETA-REDUCE to `map f o` when `<expr>` is exactly
-- `f p` (p the plain binder used once as the sole/last argument, `f` not
-- mentioning p).  Firing conditions (census-precision ~100%):
--   (1) EXACTLY 2 arms, NO guards, flat single-expression bodies.
--   (2) ONE Option ctor-pair (None+Some) or ONE Result ctor-pair (Err+Ok); these
--       ctor names belong only to the prelude Option/Result types, so keying off
--       the arm patterns is sound with no type inference.
--   (3) the PASSTHROUGH arm reconstructs VERBATIM: `None => None`, or `Err v =>
--       Err v` with the SAME identifier v (rejects `Err e => Err (…e…)` rebuilds
--       and `None => Some …`).
--   (4) LINCHPIN — the transform arm's body HEAD is literally the SAME ctor
--       wrapping an expression (`Some <expr>` / `Ok <expr>`).  This excludes the
--       `Ok x => f x` / `Ok x => andThen …` BIND chains (they UNWRAP, no re-wrap)
--       which are `andThen`/monadic, NOT map.
-- No self-reference risk: the prelude `map` impls are multi-clause function
-- clauses, not a scrutinee `EMatch`, so `map`'s own definition never fires.

-- pattern is a nullary `PCon name` (e.g. `None`)
isNilPCon : String -> Pat -> Bool
isNilPCon name (PCon n []) = n == name
isNilPCon _ _ = False

-- transform arm: `PCon ctor [binder] => <ctor> <expr>` — the body head is
-- LITERALLY `ctor` (condition 4).  Returns `(binder, <expr>)`.
matchToMapTransform : String -> Pat -> Expr -> Option (Pat, Expr)
matchToMapTransform ctor (PCon c [binder]) body
  | c == ctor = match unwrapLoc body
    EApp hd inner => if isEVarNamed ctor hd then Some (binder, inner) else None
    _ => None
matchToMapTransform _ _ _ = None

-- Result passthrough arm: `Err v => Err v` with the SAME identifier v (condition 3).
matchToMapErrPassthru : Pat -> Expr -> Bool
matchToMapErrPassthru (PCon "Err" [PVar v _]) body = match unwrapLoc body
  EApp hd arg => isEVarNamed "Err" hd && isEVarNamed v arg
  _ => False
matchToMapErrPassthru _ _ = False

-- build the map function: eta-reduce `p => f p` to `f` (reusing `andThenEtaFn`),
-- else a lambda over the (possibly non-simple) binder pattern.
matchToMapFn : Pat -> Expr -> Expr
matchToMapFn (PVar x l) expr = match andThenEtaFn x expr
  Some f => f
  None => ELam [PVar x l] expr
matchToMapFn binder expr = ELam [binder] expr

matchToMapCall : Pat -> Expr -> Expr -> Expr
matchToMapCall binder expr scrut =
  EApp (EApp (EVar "map") (matchToMapFn binder expr)) scrut

-- Option map: (noneArm, someArm) in this order.
matchToMapOption : Expr -> Arm -> Arm -> Option Expr
matchToMapOption scrut (Arm pn gn bn) (Arm ps gs bs)
  | isEmptyL gn && isEmptyL gs && isNilPCon "None" pn && isEVarNamed "None" bn = map ((binder, expr) => matchToMapCall binder expr scrut) (matchToMapTransform "Some" ps bs)
  | otherwise = None

-- Result map: (errArm, okArm) in this order.
matchToMapResult : Expr -> Arm -> Arm -> Option Expr
matchToMapResult scrut (Arm pe ge be) (Arm po go bo)
  | isEmptyL ge && isEmptyL go && matchToMapErrPassthru pe be = map ((binder, expr) => matchToMapCall binder expr scrut) (matchToMapTransform "Ok" po bo)
  | otherwise = None

-- try both ctor-pairs in both arm orders.
matchToMapPair : Expr -> Arm -> Arm -> Option Expr
matchToMapPair scrut a1 a2 = match matchToMapOption scrut a1 a2
  Some e => Some e
  None => match matchToMapOption scrut a2 a1
    Some e => Some e
    None => match matchToMapResult scrut a1 a2
      Some e => Some e
      None => matchToMapResult scrut a2 a1

-- detector (matches the RAW `EMatch`, never its `ELoc` wrapper).
matchToMapOf : Expr -> Option Expr
matchToMapOf (EMatch scrut arms) = match arms
  [a1, a2] => matchToMapPair scrut a1 a2
  _ => None
matchToMapOf _ = None

ruleMatchToMap : String -> String -> Positions -> List Decl -> List Finding
ruleMatchToMap _ _ pos prog =
  exprRuleFindings noExcl matchToMapOf matchToMapFinding pos prog

matchToMapFinding : Option Loc -> Expr -> Finding
matchToMapFinding loc rewritten = Finding {
  rule = ruleNameMatchToMap,
  message = "2-arm match maps over an Option/Result — rewrite as '" ++ exprToString rewritten ++ "'",
  severity = SevWarning,
  loc = loc,
}

matchToMapFix : Oracle -> Decl -> Option (List Decl)
matchToMapFix _ d = exprRuleFix noExcl (detApply matchToMapOf) d

-- ── rule: bind-chain-to-do (SUGGEST-ONLY, no autofix) ─────────────────────────
-- Flag a DEEP (≥3) manual monadic-bind pyramid over Result/Option written as
-- nested `match`, where every level is a verbatim failure-passthrough bind:
--   Result:  match <scrut> { Err v => Err v; Ok <pat> => <cont> }
--   Option:  match <scrut> { None => None;  Some <pat> => <cont> }
-- and `<cont>` continues the chain (another such match, possibly after one or
-- more interspersed `let` bindings that parse as an `EBlock` of `DoLet`s), never
-- a same-ctor re-wrap (`Ok x => Ok (f x)` is a `map` — `rule-match-to-map` owns
-- it, and it is excluded here via the same `matchToMapTransform` linchpin).  The
-- innermost continuation may be a functor `map f m` terminal (which IS the final
-- bind — `do { x <- m; pure (f x) }`) so it counts toward the depth.  The chain
-- must be monad-consistent (all Result OR all Option — a mixed level breaks it).
-- This IS an `EMatch`-recursion recognizer, not the `EApp`-shaped rules; `fix =
-- None` — the conversion to `do` is done by hand.

-- number of passthrough binds in the chain rooted at `e` for the chosen monad
-- (`isResult`), 0 if `e` is not a bind head.  A terminal `map f m` counts as one.
bindChainDepth : Bool -> Expr -> Int
bindChainDepth isResult e =
  let (_, core) = bindChainSplit e
  match bindChainHead isResult core
    Some body => 1 + bindChainDepth isResult body
    None => if bindChainIsTermMap core then 1 else 0

-- strip an `EBlock`'s leading `let`/statements down to its final continuation
-- expression; returns (interspersed-statement exprs, the core continuation).
bindChainSplit : Expr -> (List Expr, Expr)
bindChainSplit e = match unwrapLoc e
  EBlock stmts => match reverseL stmts
    (DoExpr lastE)::revInit => (flatMap stmtExprs (reverseL revInit), lastE)
    _ => ([], EBlock stmts)
  other => ([], other)

-- a two-arm passthrough-bind `match`; returns the success-arm body (the
-- continuation).  Tries both arm orders (the failure arm may come first or last).
bindChainHead : Bool -> Expr -> Option Expr
bindChainHead isResult e = match unwrapLoc e
  EMatch _ arms => match arms
    [a1, a2] => match bindChainTry isResult a1 a2
      Some b => Some b
      None => bindChainTry isResult a2 a1
    _ => None
  _ => None

bindChainTry : Bool -> Arm -> Arm -> Option Expr
bindChainTry isResult failArm (Arm okP okGs okBody)
  | bindChainFailPassthru isResult failArm && isEmptyL okGs && bindChainOkPat isResult okP && not (bindChainRewrap isResult okP okBody) = Some okBody
  | otherwise = None

-- failure arm is a verbatim passthrough: `Err v => Err v` / `None => None`.
bindChainFailPassthru : Bool -> Arm -> Bool
bindChainFailPassthru isResult (Arm p gs body) = isEmptyL gs
  && (if isResult then matchToMapErrPassthru p body else isNilPCon "None" p && isEVarNamed "None" body)

bindChainOkPat : Bool -> Pat -> Bool
bindChainOkPat isResult (PCon c [_]) = c == (if isResult then "Ok" else "Some")
bindChainOkPat _ _ = False

-- success arm re-wraps with the SAME ctor (`Ok x => Ok (f x)`) — that's a `map`,
-- excluded here (owned by `rule-match-to-map`).  Reuses the same linchpin.
bindChainRewrap : Bool -> Pat -> Expr -> Bool
bindChainRewrap isResult p body = match matchToMapTransform (if isResult then "Ok" else "Some") p body
  Some _ => True
  None => False

bindChainIsTermMap : Expr -> Bool
bindChainIsTermMap e = match unwrapLoc e
  EApp inner _ => match unwrapLoc inner
    EApp hd _ => isEVarNamed "map" hd
    _ => False
  _ => False

-- off-chain sub-exprs of a chain (scrutinees, let RHSs, terminal `map` parts, or
-- a plain terminal) — everything EXCEPT the continuation matches, which are
-- consumed by the recursion.  These are re-scanned for INDEPENDENT nested chains
-- so the chain's own sub-levels are never re-reported as separate heads.
bindChainOffChain : Bool -> Expr -> List Expr
bindChainOffChain isResult e =
  let (lets, core) = bindChainSplit e
  match bindChainHead isResult core
    Some body => lets
      ++ (bindChainScrut core :: bindChainOffChain isResult body)
    None =>
      if bindChainIsTermMap core then
        lets ++ bindChainTermMapParts core
      else
        lets ++ [core]

bindChainScrut : Expr -> Expr
bindChainScrut e = match unwrapLoc e
  EMatch s _ => s
  _ => e

bindChainTermMapParts : Expr -> List Expr
bindChainTermMapParts e = match unwrapLoc e
  EApp inner scrut => match unwrapLoc inner
    EApp _ f => [f, scrut]
    _ => [e]
  _ => [e]

-- report a node as a chain HEAD iff its depth (in whichever monad) is ≥ 3; then
-- consume the chain (recurse into off-chain parts only) so sub-levels of the same
-- pyramid never fire.  Otherwise descend generically into children.
bindChainHeads : Expr -> List Expr
bindChainHeads e =
  let rd = bindChainDepth True e
  let od = bindChainDepth False e
  if rd >= 3 || od >= 3 then
    e :: flatMap bindChainHeads (bindChainOffChain (rd >= od) e)
  else
    flatMap bindChainHeads (childExprs e)

bindChainDeclHeads : Decl -> List Expr
bindChainDeclHeads (DFunDef _ _ _ body) = bindChainHeads body
bindChainDeclHeads (DImpl { methods, ... }) = flatMap bindChainImplHeads methods
bindChainDeclHeads (DAttrib _ d) = bindChainDeclHeads d
bindChainDeclHeads _ = []

bindChainImplHeads : ImplMethod -> List Expr
bindChainImplHeads (ImplMethod _ _ body) = bindChainHeads body

ruleBindChainToDo : String -> String -> Positions -> List Decl -> List Finding
ruleBindChainToDo _ _ pos prog = flatMap bindChainDeclL (declLocList pos prog)

bindChainDeclL : (Decl, Option Loc) -> List Finding
bindChainDeclL (d, loc) = map (bindChainFinding loc) (bindChainDeclHeads d)

bindChainFinding : Option Loc -> Expr -> Finding
bindChainFinding loc _ = Finding {
  rule = ruleNameBindChainToDo,
  message = "deep nested Result/Option passthrough-bind `match` chain (≥3 binds). Rewrite as a `do` block",
  severity = SevWarning,
  loc = loc,
}

-- ── rule: dead-code (per-file reachability) ───────────────────────────────────
-- Flag a PRIVATE (unexported) top-level value/function binding that is NOT
-- reachable from the file's roots — Haskell's -Wunused-top-binds.  A private
-- binding has module-local visibility, so a whole-file reachability walk is
-- COMPLETE (nothing outside the file can reference it).
--
-- Roots = every exported (`export`/`public export`) top-level binding, `main`,
-- and every identifier referenced from a reachable decl's body.  Reachability
-- iterates to a fixpoint (a private helper used only by a DEAD private helper is
-- itself dead → both flagged).
--
-- Reference sites that keep a binding LIVE (miss one → false "dead" → we'd delete
-- live code, so we OVER-approximate references — safe direction):
--   * other top-level bindings' bodies (via the reachability graph),
--   * `impl`/`interface`(default)/`prop`/`test`/`bench`/top-level-`let` bodies
--     (seeded as roots — they always run),
--   * identifiers in doctest `>` input lines inside comments.  Doctests live in
--     comments (stripped from the AST), so a helper exercised ONLY by a doctest
--     looks dead but is LIVE under `medaka test`.  We recover them from the
--     lexer's string-aware comment channel (`collectComments`) — NOT a naive
--     grep of the raw text (which would eat `>`/`--` tokens inside string
--     literals).
--
-- References are collected by tokenising the printed decl (`declToString`) into
-- identifier runs: this can only OVER-collect (a name mentioned in a string
-- literal keeps its def alive — safe), never under-collect within a body.
-- Operator-named bindings are NOT flagged (their call sites use operator syntax,
-- not name tokens, so a token scan can't see the reference → risk of false
-- "dead").  `fix = None` (suggest-only — deletion is by hand).
ruleDeadCode : String -> String -> Positions -> List Decl -> List Finding
ruleDeadCode _ src pos prog =
  let reach = reachableNames src prog
  map deadFinding (filterList (deadPair reach) (privateDefLocs pos prog))

deadPair : HashMap String Unit -> (String, Option Loc) -> Bool
deadPair reach (n, _) = not (has n reach)

deadFinding : (String, Option Loc) -> Finding
deadFinding (name, loc) = Finding {
  rule = ruleNameDeadCode,
  message = "private top-level '" ++ name ++ "' is unreachable from exports/main/doctests — remove it (dead code)",
  severity = SevWarning,
  loc = loc,
}

-- private (unexported) top-level fn/value bindings, deduped by name (first loc),
-- restricted to ordinary-identifier names (operator defs are skipped).
-- A binding is a dead-code CANDIDATE iff it is an ordinary-identifier top-level
-- `DFunDef` whose name is NOT exported.  IMPORTANT: the common idiom
-- `export name : T` / `name = …` puts the `export` on the *signature*
-- (`DTypeSig True`), NOT the `DFunDef` — so exportedness is decided by
-- `exportedNames` (which unions DFunDef-pub and DTypeSig-pub), not the DFunDef
-- flag alone.
privateDefLocs : Positions -> List Decl -> List (String, Option Loc)
privateDefLocs pos prog =
  -- HashMap-as-set: `contains` over the exported LIST was O(exports) per decl,
  -- i.e. O(decls x exports) over the filterList — one of this rule's four
  -- List-as-a-set quadratics (see reachableNames).  Membership only; order
  -- irrelevant.
  let exported = nameSetOf (exportedNames prog)
  dedupeNamesLoc (filterList
    (candidatePair exported)
    (flatMap allDefNameL (declLocList pos prog)))

-- Build a HashMap-as-set from a name list (membership testing only).
nameSetOf : List String -> HashMap String Unit
nameSetOf names =
  let s = new ()
  let _ = nameSetInto names s
  s

nameSetInto : List String -> HashMap String Unit -> Unit
nameSetInto [] _ = ()
nameSetInto (n::rest) s =
  let _ = set n () s
  nameSetInto rest s

allDefNameL : (Decl, Option Loc) -> List (String, Option Loc)
allDefNameL (DFunDef _ name _ _, loc) = [(name, loc)]
allDefNameL (DAttrib _ d, loc) = allDefNameL (d, loc)
allDefNameL _ = []

candidatePair : HashMap String Unit -> (String, Option Loc) -> Bool
candidatePair exported (n, _) = isOrdinaryIdent n && not (has n exported)

isOrdinaryIdent : String -> Bool
isOrdinaryIdent s
  | stringLength s == 0 = False
  | otherwise = isIdentStart (arrayGetUnsafe 0 (stringToChars s))

-- the set of names reachable from the file's roots (fixpoint closure).
--
-- HashMap-backed, mirroring ir/dce.mdk's `reachableNames`/`funGraph`/`closure`
-- (the SAME algorithm, whose assoc-list version was retired there for being
-- O(N^2)).  This copy kept the list version and so kept the quadratics: the ref
-- map was an assoc list rebuilt per clause (`acc ++ [(n, rs)]` copies a GROWING
-- list every element) with an O(names) `lookupAssoc`/`replaceAssoc` on each, and
-- the BFS tested membership with `contains` over a `visited` LIST.  Now: O(1)-
-- average membership + O(1) graph lookup -> ~O(names + edges).  Consumed only by
-- `deadPair`'s membership test, so order and duplicates are irrelevant.
reachableNames : String -> List Decl -> HashMap String Unit
reachableNames src prog =
  let refMap = mergeRefs (flatMap defRefPair prog)
  let seed = exportedNames prog ++ ("main" :: flatMap nonDefRefL prog ++ doctestIdents src)
  let visited = new ()
  let _ = bfsReach refMap visited seed
  visited

-- one (defName, bodyRefs) per top-level DFunDef clause; refs are the identifier
-- tokens of the printed decl (deduped).
defRefPair : Decl -> List (String, List String)
defRefPair d = match defNameOf d
  Some name => [(name, sortUniqS (identTokens (declToString (unAttrib d))))]
  None => []

defNameOf : Decl -> Option String
defNameOf (DFunDef _ name _ _) = Some name
defNameOf (DAttrib _ d) = defNameOf d
defNameOf _ = None

unAttrib : Decl -> Decl
unAttrib (DAttrib _ d) = d
unAttrib d = d

exportedNames : List Decl -> List String
exportedNames prog = flatMap exportedNameL prog

exportedNameL : Decl -> List String
exportedNameL (DFunDef True name _ _) = [name]
exportedNameL (DTypeSig True name _) = [name]
exportedNameL (DAttrib _ d) = exportedNameL d
exportedNameL _ = []

-- identifier roots from body-bearing NON-DFunDef decls (impl/interface-default/
-- prop/test/bench/top-level-let).  Deliberately EXCLUDES DTypeSig/DExtern (they
-- NAME a binding, they don't reference it — including a sig would make every
-- signed private helper look reachable) and pure type/import decls.
-- Kinds that NAME a binding or a type/import rather than referencing a value are
-- matched positionally and skipped; everything else (DProp/DTest/DBench/
-- DInterface/DImpl/DLetGroup) is a body-bearing root.
nonDefRefL : Decl -> List String
nonDefRefL (DAttrib _ dd) = nonDefRefL dd
nonDefRefL (DFunDef _ _ _ _) = []
nonDefRefL (DTypeSig _ _ _) = []
nonDefRefL (DExtern _ _ _) = []
nonDefRefL (DData _ _ _ _ _) = []
nonDefRefL (DUse _ _ _) = []
nonDefRefL (DEffect _ _ _) = []
nonDefRefL (DTypeAlias _ _ _ _) = []
nonDefRefL (DNewtype _ _ _ _ _ _) = []
nonDefRefL d = bodyIdents d

bodyIdents : Decl -> List String
bodyIdents d = sortUniqS (identTokens (declToString d))

-- ── reachability fixpoint ─────────────────────────────────────────────────────
-- BFS over the ref graph: pop a name; if already visited skip; else mark visited
-- and enqueue its body refs (only DFunDef keys have refs; every other name is a
-- leaf).  Terminates because `visited` grows monotonically and each name is
-- expanded once.
-- BFS over the ref graph: pop a name; if already visited skip; else mark visited
-- and enqueue its body refs (only DFunDef keys have refs; every other name is a
-- leaf).  Terminates because `visited` grows monotonically and each name is
-- expanded once.  `has`/`set` are O(1) average, so this is ~O(names + edges); the
-- old `contains x visited` over a list made it O(names^2).
bfsReach : HashMap String (List String) -> HashMap String Unit -> List String -> Unit
bfsReach _ _ [] = ()
bfsReach refMap visited (x::rest)
  | has x visited = bfsReach refMap visited rest
  | otherwise =
    let _ = set x () visited
    bfsReach refMap visited (refsOf refMap x ++ rest)

refsOf : HashMap String (List String) -> String -> List String
refsOf refMap n = findWithDefault [] n refMap

-- merge same-named clause ref-lists into one entry per name (union, deduped).
-- HashMap-backed: the old assoc-list version did an O(names) `lookupAssoc` plus
-- either an O(names) `replaceAssoc` or an `acc ++ [(n, rs)]` — which COPIES the
-- whole growing accumulator on every element — making map construction O(D^2) in
-- both time and allocation (the dominant allocator: 56 MB -> 1138 MB across
-- 400 -> 3200 defs).  Refs feed a membership-only closure, so order is irrelevant.
mergeRefs : List (String, List String) -> HashMap String (List String)
mergeRefs pairs =
  let m = new ()
  let _ = mergeRefsGo m pairs
  m

mergeRefsGo : HashMap String (List String) -> List (String, List String) -> Unit
mergeRefsGo _ [] = ()
mergeRefsGo acc ((n, rs)::rest) =
  let _ = set n (sortUniqS (findWithDefault [] n acc ++ rs)) acc
  mergeRefsGo acc rest

-- ── identifier tokeniser ──────────────────────────────────────────────────────
-- Maximal runs of identifier characters that START with a letter or `_`.  Over-
-- approximates references (keywords, field names, ctor names, string-literal
-- words all included) — the safe direction for a dead-code scan.
identTokens : String -> List String
identTokens s =
  let cs = stringToChars s
  identTokGo s cs (arrayLength cs) 0

identTokGo : String -> Array Char -> Int -> Int -> List String
identTokGo s cs n i
  | i >= n = []
  | isIdentStart (arrayGetUnsafe i cs) =
    let j = identEnd cs n (i + 1)
    stringSlice i j s :: identTokGo s cs n j
  | otherwise = identTokGo s cs n (i + 1)

isIdentStart : Char -> Bool
isIdentStart c = isLower c || isUpper c || c == '_'

identEnd : Array Char -> Int -> Int -> Int
identEnd cs n i
  | i >= n = i
  | isAlnum (arrayGetUnsafe i cs) = identEnd cs n (i + 1)
  | otherwise = i

-- ── doctest identifiers (string-aware comment channel) ────────────────────────
-- Identifiers on `>` input lines of doctests (both `-- > expr` line-comment and
-- `{- … > expr … -}` block-comment forms).  `collectComments` is the lexer's
-- string-aware comment scanner, so `>`/`--` inside string literals never leak in.
doctestIdents : String -> List String
doctestIdents src = flatMap commentDocIdents (collectComments src)

commentDocIdents : Comment -> List String
commentDocIdents c =
  let t = commentText c
  if startsWith "{-" t then
    flatMap blockDocLineIdents (splitNl (blockInner t))
  else if startsWith "-- >" t then
    identTokens (dropPrefixN 4 t)
  else
    []

-- strip the outer `{-` `-}` from a block-comment lexeme.
blockInner : String -> String
blockInner t =
  let n = stringLength t
  if n >= 4 then stringSlice 2 (n - 2) t else ""

-- an inner block line is a doctest input iff it trims to `> …`.
blockDocLineIdents : String -> List String
blockDocLineIdents line =
  let tr = stringTrim line
  if startsWith ">" tr then identTokens (dropPrefixN 1 tr) else []

dropPrefixN : Int -> String -> String
dropPrefixN k s = stringSlice k (stringLength s) s

-- ── cross-file runner ─────────────────────────────────────────────────────────
-- Run the enabled cross-file rules over every target file, honoring the same
-- --only/--disable name filters the per-file rules use.  ALL CrossFileRule-record
-- access is confined to this runner (and the registry bindings above), so the CLI
-- stays clear of the field-scanner gap.  --deny promotion is left to the CLI
-- (which already owns it for per-file findings).
export runCrossFileRules : List String -> List String -> List (String, Positions, List Decl) -> List Finding
runCrossFileRules only disable files =
  flatMap (runCrossRuleOn only disable files) allCrossFileRules

runCrossRuleOn : List String -> List String -> List (String, Positions, List Decl) -> CrossFileRule -> List Finding
runCrossRuleOn only disable files r
  | crossRuleActive only disable r =
    map (restampSeverity r.severity) (r.check files)
  | otherwise = []

-- ── the cross-file tier, reached from CACHED per-file inputs (#395) ────────────
-- `runCrossFileRules` needs every file's `(path, Positions, decls)` — i.e. a
-- PARSE of every target, which is exactly what `--cache` skips.  So a cached run
-- reaches the tier through the occurrence lists it persisted per file instead.
--
-- ⚠️ THE SOUNDNESS SEAM.  `fileDupOccs` is the per-file input of ONE rule.  This
-- entry point is therefore only equivalent to `runCrossFileRules` while
-- `allCrossFileRules` is exactly `[duplicateBodyRule]` — a second cross-file
-- rule would have its own per-file inputs, which nothing here caches or feeds
-- it, and it would SILENTLY NOT RUN under `--cache`.  That is a whole rule
-- reporting nothing while exiting 0: this repo's defining failure mode.
--
-- Rather than trust a future agent to read this comment, `crossFileCacheSound`
-- DERIVES the answer from the live registry, and the CLI refuses `--cache`
-- (falling back to a full uncached run) when it goes False.  Adding a cross-file
-- rule then costs a slower lint, never a wrong one — the #395 invariant: a miss
-- is always safe, a wrong hit is silent wrongness.
export crossFileCacheSound : Bool
crossFileCacheSound = match allCrossFileRules
  [r] => r.name == ruleNameDuplicateBody
  _ => False

-- Cached counterpart of `runCrossFileRules`: same --only/--disable gating, same
-- severity restamp, same join — but fed occurrences instead of parses.  Callers
-- MUST check `crossFileCacheSound` first (see above).
export runCrossFileRulesFromOccs : List String -> List String -> List (String, Int, String, String) -> List Finding
runCrossFileRulesFromOccs only disable occs =
  flatMap (runCrossRuleFromOccs only disable occs) allCrossFileRules

-- The `r.name == ruleNameDuplicateBody` conjunct is belt-and-braces behind the
-- CLI's `crossFileCacheSound` check: it means a caller that ignores that check
-- still cannot run `dupJoin` under some OTHER rule's name and severity — it just
-- gets the dup rule alone, which is what the guard would have caught anyway.
runCrossRuleFromOccs : List String -> List String -> List (String, Int, String, String) -> CrossFileRule -> List Finding
runCrossRuleFromOccs only disable occs r
  | crossRuleActive only disable r && r.name == ruleNameDuplicateBody =
    map (restampSeverity r.severity) (dupJoin occs)
  | otherwise = []

crossRuleActive : List String -> List String -> CrossFileRule -> Bool
crossRuleActive only disable r = r.enabled
  && (isEmptyL only || contains r.name only)
  && not (contains r.name disable)

-- ── cross-file rule: duplicate-body (copy-paste detector) ──────────────────────
-- Flags a top-level `DFunDef` whose ELoc-stripped body (+ param-pattern shape) is
-- structurally identical to a top-level function in a DIFFERENT file.  The
-- structural key reuses `ir.sexp.exprSexp` — the location-stripped AST serializer
-- the parse/sexp gates already rely on — so two copy-pasted bodies render to the
-- same string.  HIGH-SIGNAL: only bodies at/above `dupComplexityThreshold` AST
-- nodes are eligible, so trivial bodies (`main = …`, `f x = x`, one-field
-- accessors) never fire.  Same-file duplicates are out of scope (≥2 distinct
-- files required).  Deterministic: keys processed in sorted order, occurrences
-- sorted by (file, line).

-- minimum body complexity (count of AST nodes) to be eligible.  Calibrated so the
-- real stdlib/compiler libraries stay quiet absent genuine duplication.
dupComplexityThreshold : Int
dupComplexityThreshold = 10

-- structural identity key: param-pattern shapes ++ ELoc-stripped body sexp.
structuralKey : List Pat -> Expr -> String
structuralKey pats body =
  "\{joinWith "|" (map patSexp pats)} => \{exprSexp body}"

-- complexity proxy: every `node`/`slist` in the sexp dump emits a '(', so counting
-- '(' counts AST nodes without a second traversal.
bodyComplexity : Expr -> Int
bodyComplexity body =
  let cs = stringToChars (exprSexp body)
  countOpenParens cs (arrayLength cs) 0 0

countOpenParens : Array Char -> Int -> Int -> Int -> Int
countOpenParens cs n i acc
  | i >= n = acc
  | arrayGetUnsafe i cs == '(' = countOpenParens cs n (i + 1) (acc + 1)
  | otherwise = countOpenParens cs n (i + 1) acc

ruleDuplicateBody : List (String, Positions, List Decl) -> List Finding
ruleDuplicateBody files = dupJoin (flatMap fileDupOccs files)

-- THE join: occurrences (from every file) → findings.  Split out of
-- `ruleDuplicateBody` for #395's `--cache`, which reaches the same join from
-- occurrences it deserialized rather than from freshly-parsed decls.  Both
-- callers run THIS function, so a cached run's cross-file findings are computed
-- by the identical code an uncached one runs.
--
-- ⚠️ This split is the whole correctness story of the lint cache.  A cache MUST
-- store the per-file INPUTS to this join (`fileDupOccs`) and re-run it every
-- time — never the findings it returns.  A finding here names file A *because
-- of* file B, so a cached A-finding survives an edit to B that should have
-- retracted it: the finding silently lingers (or, symmetrically, never
-- appears).  Re-running the join is cheap — it measures LINEAR at occs≈10k, as
-- `emitDupGroup`'s scan short-circuits at char 0 on distinct keys — so there is
-- no efficiency argument for caching its output either.  Scenario 3 of
-- test/diff_compiler_lint_cache.sh exists to fail loudly if someone ever tries.
--
-- ⚠️ PERFORMANCE, and a debunking that was itself half-wrong.  This join used to
-- read:
--
--     let keys = sortUniqS (map occKey occs)
--     flatMap (emitDupGroup occs) keys        -- emitDupGroup filters ALL occs
--
-- i.e. for each of ~10k distinct keys, a `filterList` over all ~10k occurrences:
-- 100M string comparisons, QUADRATIC in occurrence count.  #395's spike graded
-- that shape "measured LINEAR at occs=8000" — but what it actually established
-- is that each comparison is O(1) rather than O(key length), because distinct
-- sexp keys mismatch at char 0.  The comparisons are cheap; there are n² of
-- them.  MEASURED here at N vs 2N with a warm cache (which removes the parse and
-- leaves the join exposed): 0.115 s → 0.416 s, a 3.6x growth for 2x the input —
-- quadratic, not the 2.0x of linear.  It cost 0.6 s of a 0.97 s warm run.
--
-- It hid for the same two reasons this repo keeps rediscovering: it was dwarfed
-- by the parse it sat behind (so it never showed up cold), and a pure `List`
-- scan ALLOCATES NOTHING, so `diff_compiler_perf_scaling` — which grades
-- allocation growth, deliberately, because GC bytes are machine-independent —
-- is blind to it (issue #110's class).
--
-- Now: bucket the occurrences by key ONCE (linear), then emit only from the
-- groups that can actually fire.  A group needs ≥2 occurrences across ≥2 files,
-- which in a clean tree is a handful out of ~10k — so the `sortUniqS` that
-- orders the output for determinism now sorts that handful rather than every
-- key.  Same findings, same order.
export dupJoin : List (String, Int, String, String) -> List Finding
dupJoin occs =
  let groups = groupOccsByKey occs
  let live = filterList (k => dupGroupFires (findWithDefault [] k groups)) (dupDistinctKeys occs)
  flatMap
    (k => emitDupGroup (reverseL (findWithDefault [] k groups)))
    (sortUniqS live)

-- key → its occurrences, in one linear pass.  Each bucket accumulates REVERSED
-- (prepend is O(1)); `dupJoin` reverses on the way out so the occurrence order
-- reaching `emitDupGroup` matches the old filter-in-input-order behaviour.
-- (`sortDupOccs` sorts them anyway — this only keeps the pre-sort list identical
-- so the two implementations are diffable.)
groupOccsByKey : List (String, Int, String, String) -> HashMap String (List (String, Int, String, String))
groupOccsByKey occs =
  let m = new ()
  let _ = groupOccsGo m occs
  m

groupOccsGo : HashMap String (List (String, Int, String, String)) -> List (String, Int, String, String) -> Unit
groupOccsGo _ [] = ()
groupOccsGo m (o::rest) =
  let _ = set (occKey o) (o :: findWithDefault [] (occKey o) m) m
  groupOccsGo m rest

-- Distinct keys in first-appearance order.  `keys` on the HashMap would do this
-- too, but its order is bucket order — a function of the hash, so it would make
-- the output depend on table internals.  This is deterministic by construction,
-- and `dupJoin` sorts the survivors regardless.  (A `HashMap String Unit` as the
-- seen-set, rather than a HashSet, only because hash_set's `new`/`has` would
-- collide with hash_map's under this module's flat import list.)
dupDistinctKeys : List (String, Int, String, String) -> List String
dupDistinctKeys occs =
  let seen = new ()
  dupDistinctGo seen occs

dupDistinctGo : HashMap String Unit -> List (String, Int, String, String) -> List String
dupDistinctGo _ [] = []
dupDistinctGo seen (o::rest)
  | has (occKey o) seen = dupDistinctGo seen rest
  | otherwise =
    let _ = set (occKey o) () seen
    occKey o :: dupDistinctGo seen rest

-- Can this key's group emit at all?  ≥2 occurrences spanning ≥2 distinct files.
-- Cheap pre-filter so the sort and `emitDupGroup` only ever see live groups.
dupGroupFires : List (String, Int, String, String) -> Bool
dupGroupFires grp = listLen grp >= 2
  && listLen (sortUniqS (map occFile grp)) >= 2

-- one occurrence per eligible top-level DFunDef: (file, line, name, structuralKey)
export fileDupOccs : (String, Positions, List Decl) -> List (String, Int, String, String)
fileDupOccs (path, pos, decls) =
  flatMap (dupOccOfDecl path) (declLocList pos decls)

dupOccOfDecl : String -> (Decl, Option Loc) -> List (String, Int, String, String)
dupOccOfDecl path (d, loc) = match d
  DFunDef _ name pats body =>
    if bodyComplexity body >= dupComplexityThreshold then
      [(path, locLineOf loc, name, structuralKey pats body)]
    else
      []
  DAttrib _ inner => dupOccOfDecl path (inner, loc)
  _ => []

locLineOf : Option Loc -> Int
locLineOf (Some (Loc _ l _ _ _)) = l
locLineOf None = 1

occFile : (String, Int, String, String) -> String
occFile (f, _, _, _) = f

occLine : (String, Int, String, String) -> Int
occLine (_, l, _, _) = l

occName : (String, Int, String, String) -> String
occName (_, _, n, _) = n

occKey : (String, Int, String, String) -> String
occKey (_, _, _, k) = k

-- emit findings for one structural-key group, but only when it spans ≥2 files.
-- Takes the group itself; `dupJoin` bucketed the occurrences by key and already
-- dropped the groups that cannot fire (see `dupGroupFires`).  The ≥2-file check
-- stays here regardless — this function's contract is "≥2 files or nothing", and
-- it must not depend on its caller having filtered.
emitDupGroup : List (String, Int, String, String) -> List Finding
emitDupGroup grp =
  let distinctFiles = sortUniqS (map occFile grp)
  if listLen distinctFiles < 2 then
    []
  else
    map (dupFinding distinctFiles) (sortDupOccs grp)

dupFinding : List String -> (String, Int, String, String) -> Finding
dupFinding distinctFiles occ =
  let file = occFile occ
  let line = occLine occ
  let others = filterList (!= file) distinctFiles
  Finding {
    rule = ruleNameDuplicateBody,
    message = "function '\{occName occ}' has a body structurally identical to a definition in \{joinWith ", " others} — consolidate into a shared module",
    severity = SevWarning,
    loc = Some (Loc file line 1 line 1),
  }

-- insertion sort occurrences by (file, line) for deterministic output.
sortDupOccs : List (String, Int, String, String) -> List (String, Int, String, String)
sortDupOccs [] = []
sortDupOccs (x::xs) = dupInsert x (sortDupOccs xs)

dupInsert : (String, Int, String, String) -> List (String, Int, String, String) -> List (String, Int, String, String)
dupInsert x [] = [x]
dupInsert x (y::ys)
  | dupOccLe x y = x :: y::ys
  | otherwise = y :: dupInsert x ys

dupOccLe : (String, Int, String, String) -> (String, Int, String, String) -> Bool
dupOccLe a b = match stringCompare (occFile a) (occFile b)
  Lt => True
  Gt => False
  Eq => occLine a <= occLine b
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "Ty" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "ImplMethod" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "parseWithPositions" false) (mem "parseWithPositionsLocated" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true) (mem "Diag" true) (mem "ppSeverity" false) (mem "readFileSafe" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "anyList" false) (mem "allList" false) (mem "filterList" false) (mem "joinNl" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "reverseL" false) (mem "splitNl" false) (mem "splitOnChar" false) (mem "joinWith" false) (mem "sortUniqS" false) (mem "startsWith" false) (mem "stringTrim" false) (mem "lookupAssoc" false) (mem "dedupBy" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "set" false) (mem "has" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "declToString" false) (mem "exprToString" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false) (mem "isLower" false) (mem "isUpper" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false) (mem "patSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false) (mem "buildOracle" false) (mem "oGetCtors" false) (mem "oGetCtorType" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "collectComments" false) (mem "commentLine" false) (mem "commentText" false))))
(DData Public "Finding" () ((variant "Finding" (ConNamed (field "rule" (TyCon "String")) (field "message" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "loc" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Public "Rule" () ((variant "Rule" (ConNamed (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "enabled" (TyCon "Bool")) (field "check" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))) (field "fix" (TyApp (TyCon "Option") (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))))) ())
(DData Public "CrossFileRule" () ((variant "CrossFileRule" (ConNamed (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "enabled" (TyCon "Bool")) (field "check" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))))))) ())
(DTypeSig false "ruleNameMatchParam" (TyCon "String"))
(DFunDef false "ruleNameMatchParam" () (ELit (LString "rule-match-on-param")))
(DTypeSig false "ruleNameDerivable" (TyCon "String"))
(DFunDef false "ruleNameDerivable" () (ELit (LString "rule-hand-rolled-derivable")))
(DTypeSig false "ruleNameStdlibReimpl" (TyCon "String"))
(DFunDef false "ruleNameStdlibReimpl" () (ELit (LString "rule-stdlib-reimpl")))
(DTypeSig false "ruleNameDuplicateBody" (TyCon "String"))
(DFunDef false "ruleNameDuplicateBody" () (ELit (LString "rule-duplicate-body")))
(DTypeSig false "ruleNameBindThenDestructure" (TyCon "String"))
(DFunDef false "ruleNameBindThenDestructure" () (ELit (LString "rule-bind-then-destructure")))
(DTypeSig false "ruleNameLambdaSection" (TyCon "String"))
(DFunDef false "ruleNameLambdaSection" () (ELit (LString "rule-lambda-section")))
(DTypeSig false "ruleNameIfMaxMin" (TyCon "String"))
(DFunDef false "ruleNameIfMaxMin" () (ELit (LString "rule-if-max-min")))
(DTypeSig false "ruleNameAndThenPureMap" (TyCon "String"))
(DFunDef false "ruleNameAndThenPureMap" () (ELit (LString "rule-andthen-pure-map")))
(DTypeSig false "ruleNameDestructureInParam" (TyCon "String"))
(DFunDef false "ruleNameDestructureInParam" () (ELit (LString "rule-destructure-in-param")))
(DTypeSig false "ruleNameMissingSignature" (TyCon "String"))
(DFunDef false "ruleNameMissingSignature" () (ELit (LString "rule-missing-signature")))
(DTypeSig false "ruleNameNotEq" (TyCon "String"))
(DFunDef false "ruleNameNotEq" () (ELit (LString "rule-not-eq")))
(DTypeSig false "ruleNameBoolSimplify" (TyCon "String"))
(DFunDef false "ruleNameBoolSimplify" () (ELit (LString "rule-bool-simplify")))
(DTypeSig false "ruleNameRemParity" (TyCon "String"))
(DFunDef false "ruleNameRemParity" () (ELit (LString "rule-rem-parity")))
(DTypeSig false "ruleNameDoubleReverse" (TyCon "String"))
(DFunDef false "ruleNameDoubleReverse" () (ELit (LString "rule-double-reverse")))
(DTypeSig false "ruleNameWhenUnless" (TyCon "String"))
(DFunDef false "ruleNameWhenUnless" () (ELit (LString "rule-when-unless")))
(DTypeSig false "ruleNameComplementPredicate" (TyCon "String"))
(DFunDef false "ruleNameComplementPredicate" () (ELit (LString "rule-complement-predicate")))
(DTypeSig false "ruleNameMatchToMap" (TyCon "String"))
(DFunDef false "ruleNameMatchToMap" () (ELit (LString "rule-match-to-map")))
(DTypeSig false "ruleNameBindChainToDo" (TyCon "String"))
(DFunDef false "ruleNameBindChainToDo" () (ELit (LString "rule-bind-chain-to-do")))
(DTypeSig false "ruleNameDeadCode" (TyCon "String"))
(DFunDef false "ruleNameDeadCode" () (ELit (LString "rule-dead-code")))
(DTypeSig false "ruleNameConcatToInterp" (TyCon "String"))
(DFunDef false "ruleNameConcatToInterp" () (ELit (LString "rule-concat-to-interp")))
(DTypeSig false "ruleNameSelfShadowExtern" (TyCon "String"))
(DFunDef false "ruleNameSelfShadowExtern" () (ELit (LString "rule-self-shadow-extern")))
(DTypeSig false "matchParamRule" (TyCon "Rule"))
(DFunDef false "matchParamRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameMatchParam")) (fa "descr" (ELit (LString "function body is a `match` on a bare parameter (prefer multi-clause; STYLE §8)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleMatchOnParam")) (fa "fix" (EApp (EVar "Some") (EVar "matchParamFix"))))))
(DTypeSig false "derivableRule" (TyCon "Rule"))
(DFunDef false "derivableRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDerivable")) (fa "descr" (ELit (LString "hand-written Eq/Ord/Debug impl that could be `deriving` (STYLE §6)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDerivable")) (fa "fix" (EVar "None")))))
(DTypeSig false "stdlibReimplRule" (TyCon "Rule"))
(DFunDef false "stdlibReimplRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameStdlibReimpl")) (fa "descr" (ELit (LString "top-level function shadows a common stdlib/prelude name (STYLE §7a)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleStdlibReimpl")) (fa "fix" (EVar "None")))))
(DTypeSig false "bindThenDestructureRule" (TyCon "Rule"))
(DFunDef false "bindThenDestructureRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameBindThenDestructure")) (fa "descr" (ELit (LString "do-bind then immediately destructures the bound var with an irrefutable single-arm `match`. Inline the pattern into the bind"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleBindThenDestructure")) (fa "fix" (EApp (EVar "Some") (EVar "bindThenDestructureFix"))))))
(DTypeSig false "lambdaSectionRule" (TyCon "Rule"))
(DFunDef false "lambdaSectionRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameLambdaSection")) (fa "descr" (ELit (LString "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleLambdaSection")) (fa "fix" (EApp (EVar "Some") (EVar "lambdaSectionFix"))))))
(DTypeSig false "ifMaxMinRule" (TyCon "Rule"))
(DFunDef false "ifMaxMinRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameIfMaxMin")) (fa "descr" (ELit (LString "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleIfMaxMin")) (fa "fix" (EApp (EVar "Some") (EVar "ifMaxMinFix"))))))
(DTypeSig false "andThenPureMapRule" (TyCon "Rule"))
(DFunDef false "andThenPureMapRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameAndThenPureMap")) (fa "descr" (ELit (LString "monadic bind whose continuation just wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map` (functor law: m >>= (pure . f) ≡ fmap f m)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleAndThenPureMap")) (fa "fix" (EApp (EVar "Some") (EVar "andThenPureMapFix"))))))
(DTypeSig false "destructureInParamRule" (TyCon "Rule"))
(DFunDef false "destructureInParamRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDestructureInParam")) (fa "descr" (ELit (LString "function body is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple/record/single-ctor). Destructure directly in the parameter position"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDestructureInParam")) (fa "fix" (EApp (EVar "Some") (EVar "destructureInParamFix"))))))
(DTypeSig false "missingSignatureRule" (TyCon "Rule"))
(DFunDef false "missingSignatureRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameMissingSignature")) (fa "descr" (ELit (LString "top-level value/function binding has no sibling type signature (name : Type). Add one (Haskell -Wmissing-signatures)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleMissingSignature")) (fa "fix" (EVar "None")))))
(DTypeSig false "notEqRule" (TyCon "Rule"))
(DFunDef false "notEqRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameNotEq")) (fa "descr" (ELit (LString "negated equality `not (a == b)` / `not (a != b)`. Prefer `a != b` / `a == b`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleNotEq")) (fa "fix" (EApp (EVar "Some") (EVar "notEqFix"))))))
(DTypeSig false "boolSimplifyRule" (TyCon "Rule"))
(DFunDef false "boolSimplifyRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameBoolSimplify")) (fa "descr" (ELit (LString "redundant boolean shape (`if c then True else False`, `x == True`, `not (not x)`, …). Simplify"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleBoolSimplify")) (fa "fix" (EApp (EVar "Some") (EVar "boolSimplifyFix"))))))
(DTypeSig false "remParityRule" (TyCon "Rule"))
(DFunDef false "remParityRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameRemParity")) (fa "descr" (ELit (LString "`n % 2 == 0` / `n % 2 != 0` parity test. Prefer `isEven n` / `isOdd n`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleRemParity")) (fa "fix" (EApp (EVar "Some") (EVar "remParityFix"))))))
(DTypeSig false "doubleReverseRule" (TyCon "Rule"))
(DFunDef false "doubleReverseRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDoubleReverse")) (fa "descr" (ELit (LString "`reverse (reverse x)` is `x`. Drop the double reversal"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDoubleReverse")) (fa "fix" (EApp (EVar "Some") (EVar "doubleReverseFix"))))))
(DTypeSig false "whenUnlessRule" (TyCon "Rule"))
(DFunDef false "whenUnlessRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameWhenUnless")) (fa "descr" (ELit (LString "`if b then m else pure ()` / `if b then pure () else m`. Prefer `when b m` / `unless b m`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleWhenUnless")) (fa "fix" (EApp (EVar "Some") (EVar "whenUnlessFix"))))))
(DTypeSig false "complementPredicateRule" (TyCon "Rule"))
(DFunDef false "complementPredicateRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameComplementPredicate")) (fa "descr" (ELit (LString "`not (p x)` where `p` has a defined complement predicate (`isEmptyL`/`isSome`/`isOk` & inverses). Call the complement directly"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleComplementPredicate")) (fa "fix" (EApp (EVar "Some") (EVar "complementPredicateFix"))))))
(DTypeSig false "matchToMapRule" (TyCon "Rule"))
(DFunDef false "matchToMapRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameMatchToMap")) (fa "descr" (ELit (LString "2-arm `match` on Option/Result that reconstructs the failure ctor and re-wraps the success ctor. That IS a functor `map` (hlint 'use fmap')"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleMatchToMap")) (fa "fix" (EApp (EVar "Some") (EVar "matchToMapFix"))))))
(DTypeSig false "bindChainToDoRule" (TyCon "Rule"))
(DFunDef false "bindChainToDoRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameBindChainToDo")) (fa "descr" (ELit (LString "deep (≥3) nested Result/Option passthrough-bind `match` pyramid. Rewrite as a `do` block (suggest-only)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleBindChainToDo")) (fa "fix" (EVar "None")))))
(DTypeSig false "deadCodeRule" (TyCon "Rule"))
(DFunDef false "deadCodeRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDeadCode")) (fa "descr" (ELit (LString "private (unexported) top-level binding is unreachable from the file's exports/main/doctests. Dead code (Haskell -Wunused-top-binds)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDeadCode")) (fa "fix" (EVar "None")))))
(DTypeSig false "concatToInterpRule" (TyCon "Rule"))
(DFunDef false "concatToInterpRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameConcatToInterp")) (fa "descr" (ELit (LString "`++` chain mixing string literals and expressions. Prefer string interpolation `\"…\\{e}…\"` (hlint 'use interpolation')"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleConcatToInterp")) (fa "fix" (EApp (EVar "Some") (EVar "concatToInterpFix"))))))
(DTypeSig false "selfShadowExternRule" (TyCon "Rule"))
(DFunDef false "selfShadowExternRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameSelfShadowExtern")) (fa "descr" (ELit (LString "top-level binding unconditionally forwards to itself (`f s = f s`, `x = x`) — an infinite self-recursion, not a forward to a same-named extern (#266)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleSelfShadowExtern")) (fa "fix" (EVar "None")))))
(DTypeSig true "allRules" (TyApp (TyCon "List") (TyCon "Rule")))
(DFunDef false "allRules" () (EListLit (EVar "matchParamRule") (EVar "derivableRule") (EVar "stdlibReimplRule") (EVar "bindThenDestructureRule") (EVar "lambdaSectionRule") (EVar "ifMaxMinRule") (EVar "andThenPureMapRule") (EVar "destructureInParamRule") (EVar "missingSignatureRule") (EVar "notEqRule") (EVar "boolSimplifyRule") (EVar "remParityRule") (EVar "doubleReverseRule") (EVar "whenUnlessRule") (EVar "complementPredicateRule") (EVar "matchToMapRule") (EVar "bindChainToDoRule") (EVar "deadCodeRule") (EVar "concatToInterpRule") (EVar "selfShadowExternRule")))
(DTypeSig false "duplicateBodyRule" (TyCon "CrossFileRule"))
(DFunDef false "duplicateBodyRule" () (ERecordCreate "CrossFileRule" ((fa "name" (EVar "ruleNameDuplicateBody")) (fa "descr" (ELit (LString "top-level function body is structurally identical to one in another file (copy-paste; consolidate)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDuplicateBody")))))
(DTypeSig true "allCrossFileRules" (TyApp (TyCon "List") (TyCon "CrossFileRule")))
(DFunDef false "allCrossFileRules" () (EListLit (EVar "duplicateBodyRule")))
(DTypeSig true "lintProgram" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "lintProgram" ((PVar "rules") (PVar "path") (PVar "src") (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EVar "runRuleOn") (EVar "path")) (EVar "src")) (EVar "pos")) (EVar "prog"))) (EVar "rules")))
(DTypeSig false "runRuleOn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Rule") (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "runRuleOn" ((PVar "path") (PVar "src") (PVar "pos") (PVar "prog") (PVar "r")) (EIf (EFieldAccess (EVar "r") "enabled") (EApp (EApp (EVar "map") (EApp (EVar "restampSeverity") (EFieldAccess (EVar "r") "severity"))) (EApp (EApp (EApp (EApp (EFieldAccess (EVar "r") "check") (EVar "path")) (EVar "src")) (EVar "pos")) (EVar "prog"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "restampSeverity" (TyFun (TyCon "Severity") (TyFun (TyCon "Finding") (TyCon "Finding"))))
(DFunDef false "restampSeverity" ((PVar "sev") (PVar "f")) (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EVar "sev")) (fa "loc" (EFieldAccess (EVar "f") "loc")))))
(DTypeSig false "isStdlibPath" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isStdlibPath" ((PVar "path")) (EApp (EApp (EVar "contains") (ELit (LString "stdlib"))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "path"))))
(DTypeSig true "applyFixes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "applyFixes" ((PVar "only") (PVar "disable") (PVar "src") (PVar "prog") (PVar "pos")) (EBlock (DoLet false false (PVar "rules") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "ruleActiveFixable") (EVar "only")) (EVar "disable"))) (EVar "allRules"))) (DoLet false false (PVar "orc") (EApp (EVar "buildOracle") (EVar "prog"))) (DoLet false false (PVar "cmtLines") (EApp (EApp (EVar "map") (EVar "commentLine")) (EApp (EVar "collectComments") (EVar "src")))) (DoLet false false (PVar "splices") (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EApp (EApp (EVar "zipDeclPos") (EVar "prog")) (EApp (EVar "positionsDecls") (EVar "pos"))))) (DoExpr (ETuple (EApp (EApp (EVar "applySplices") (EVar "src")) (EVar "splices")) (EApp (EVar "listLen") (EVar "splices"))))))
(DTypeSig false "ruleActiveFixable" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Rule") (TyCon "Bool")))))
(DFunDef false "ruleActiveFixable" ((PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EFieldAccess (EVar "r") "enabled") (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only")))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))) (EApp (EVar "ruleHasFixer") (EVar "r"))))
(DTypeSig false "ruleHasFixer" (TyFun (TyCon "Rule") (TyCon "Bool")))
(DFunDef false "ruleHasFixer" ((PVar "r")) (EMatch (EFieldAccess (EVar "r") "fix") (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "zipDeclPos" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))))))
(DFunDef false "zipDeclPos" ((PList) PWild) (EListLit))
(DFunDef false "zipDeclPos" (PWild (PList)) (EListLit))
(DFunDef false "zipDeclPos" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EBinOp "::" (ETuple (EVar "d") (EVar "p")) (EApp (EApp (EVar "zipDeclPos") (EVar "ds")) (EVar "ps"))))
(DTypeSig false "collectSplices" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))))))
(DFunDef false "collectSplices" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "collectSplices" ((PVar "cmtLines") (PVar "orc") (PVar "rules") (PCons (PTuple (PVar "d") (PVar "dp")) (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "firstFix") (EVar "orc")) (EVar "rules")) (EVar "d")) (arm (PCon "Some" (PVar "newDecls")) () (EIf (EApp (EApp (EApp (EVar "spanHasComment") (EVar "cmtLines")) (EApp (EVar "declPosLine") (EVar "dp"))) (EApp (EVar "declPosEndLine") (EVar "dp"))) (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest")) (EBinOp "::" (ETuple (EApp (EVar "declPosLine") (EVar "dp")) (EApp (EVar "declPosEndLine") (EVar "dp")) (EApp (EVar "renderDecls") (EVar "newDecls"))) (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest")))))
(DTypeSig false "spanHasComment" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "spanHasComment" ((PVar "cmtLines") (PVar "startLine") (PVar "endLine")) (EApp (EApp (EVar "anyList") (ELam ((PVar "l")) (EBinOp "&&" (EBinOp "<=" (EVar "startLine") (EVar "l")) (EBinOp "<=" (EVar "l") (EVar "endLine"))))) (EVar "cmtLines")))
(DTypeSig false "firstFix" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "firstFix" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "firstFix" ((PVar "orc") (PCons (PVar "r") (PVar "rs")) (PVar "d")) (EMatch (EApp (EApp (EApp (EVar "applyRuleFix") (EVar "orc")) (EVar "r")) (EVar "d")) (arm (PCon "Some" (PVar "newDecls")) () (EApp (EVar "Some") (EVar "newDecls"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "firstFix") (EVar "orc")) (EVar "rs")) (EVar "d")))))
(DTypeSig false "applyRuleFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Rule") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "applyRuleFix" ((PVar "orc") (PVar "r") (PVar "d")) (EMatch (EFieldAccess (EVar "r") "fix") (arm (PCon "Some" (PVar "f")) () (EApp (EApp (EVar "f") (EVar "orc")) (EVar "d"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "renderDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "renderDecls" ((PVar "ds")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "declToString")) (EVar "ds"))))
(DTypeSig false "applySplices" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyCon "String"))))
(DFunDef false "applySplices" ((PVar "src") (PVar "splices")) (EApp (EVar "joinNl") (EApp (EApp (EVar "foldSplices") (EApp (EVar "splitNl") (EVar "src"))) (EApp (EVar "reverseL") (EVar "splices")))))
(DTypeSig false "foldSplices" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "foldSplices" ((PVar "lines") (PList)) (EVar "lines"))
(DFunDef false "foldSplices" ((PVar "lines") (PCons (PTuple (PVar "s") (PVar "e") (PVar "txt")) (PVar "rest"))) (EApp (EApp (EVar "foldSplices") (EApp (EApp (EApp (EApp (EVar "spliceLines") (EVar "lines")) (EVar "s")) (EVar "e")) (EVar "txt"))) (EVar "rest")))
(DTypeSig false "spliceLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "spliceLines" ((PVar "lines") (PVar "s") (PVar "e") (PVar "txt")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "takeN") (EBinOp "-" (EVar "s") (ELit (LInt 1)))) (EVar "lines")) (EApp (EVar "splitNl") (EVar "txt"))) (EApp (EApp (EVar "dropN") (EVar "e")) (EVar "lines"))))
(DTypeSig false "takeN" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "takeN" ((PVar "n") PWild) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "takeN" (PWild (PList)) (EListLit))
(DFunDef false "takeN" ((PVar "n") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeN") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "xs"))))
(DTypeSig false "dropN" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "dropN" ((PVar "n") (PVar "xs")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EVar "xs") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "dropN" (PWild (PList)) (EListLit))
(DFunDef false "dropN" ((PVar "n") (PCons PWild (PVar "xs"))) (EApp (EApp (EVar "dropN") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "xs")))
(DTypeSig true "parseLintFlagList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "parseLintFlagList" ((PVar "prefix") (PList)) (EListLit))
(DFunDef false "parseLintFlagList" ((PVar "prefix") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "x")) (EApp (EVar "splitLintNames") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "x"))) (EVar "x"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseLintFlagList") (EVar "prefix")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "splitLintNames" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitLintNames" ((PVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EApp (EVar "stringToChars") (EVar "s"))) (EVar "s")) (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))))
(DTypeSig false "splitLintNamesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitLintNamesGo" ((PVar "chars") (PVar "s") (PVar "start") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "n")) (EVar "s"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar ","))) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "i")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EVar "chars")) (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EVar "chars")) (EVar "s")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "applyFindingFilters" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "applyFindingFilters" ((PVar "disable") (PVar "only") (PVar "deny") (PVar "findings")) (EBlock (DoLet false false (PVar "after1") (EApp (EApp (EVar "applyFindingOnly") (EVar "only")) (EVar "findings"))) (DoLet false false (PVar "after2") (EApp (EApp (EVar "applyFindingDisable") (EVar "disable")) (EVar "after1"))) (DoExpr (EApp (EApp (EVar "applyFindingDeny") (EVar "deny")) (EVar "after2")))))
(DTypeSig false "applyFindingOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingOnly" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingOnly" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingOnlyGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingOnlyGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingOnlyGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyFindingDisable" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingDisable" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingDisable" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingDisableGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingDisableGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingDisableGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "applyFindingDeny" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingDeny" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingDeny" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingDenyGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingDenyGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingDenyGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EBinOp "::" (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EVar "SevError")) (fa "loc" (EFieldAccess (EVar "f") "loc")))) (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "isFindingError" (TyFun (TyCon "Finding") (TyCon "Bool")))
(DFunDef false "isFindingError" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "severity") (arm (PCon "SevError") () (EVar "True")) (arm (PCon "SevWarning") () (EVar "False"))))
(DTypeSig true "findingToDiag" (TyFun (TyCon "Finding") (TyCon "Diag")))
(DFunDef false "findingToDiag" ((PVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EFieldAccess (EVar "f") "severity")) (EFieldAccess (EVar "f") "rule")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EVar "display") (EFieldAccess (EVar "f") "rule"))) (ELit (LString "] "))) (EApp (EVar "display") (EFieldAccess (EVar "f") "message"))) (ELit (LString "")))) (EFieldAccess (EVar "f") "loc")) (EVar "None")) (EVar "None")))
(DTypeSig true "lintFileDiagTriple" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))
(DFunDef false "lintFileDiagTriple" ((PVar "disable") (PVar "only") (PVar "deny") (PVar "path")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "path"))) (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositionsLocated") (EVar "src"))) (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressions") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EVar "lintProgram") (EVar "allRules")) (EVar "path")) (EVar "src")) (EVar "pos")) (EVar "decls")))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "allFindings"))) (DoExpr (ETuple (EVar "path") (EVar "src") (EApp (EApp (EVar "map") (EVar "findingToDiag")) (EVar "findings"))))))
(DTypeSig true "lintToLines" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))))
(DFunDef false "lintToLines" ((PVar "src") (PVar "path") (PVar "pos") (PVar "prog")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "findingLine")) (EApp (EApp (EVar "applySuppressions") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EVar "lintProgram") (EVar "allRules")) (EVar "path")) (EVar "src")) (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "findingLine" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "findingLine" ((PVar "f")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppSeverity") (EFieldAccess (EVar "f") "severity")))) (ELit (LString ": ["))) (EApp (EVar "display") (EFieldAccess (EVar "f") "rule"))) (ELit (LString "] "))) (EApp (EVar "display") (EFieldAccess (EVar "f") "message"))) (ELit (LString ""))))
(DData Public "DirScope" () ((variant "DScopeLine" (ConPos (TyCon "Int"))) (variant "DScopeFile" (ConPos))) ())
(DData Public "Directive" () ((variant "Directive" (ConPos (TyCon "DirScope") (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig true "applySuppressions" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressions" ((PVar "src") (PVar "findings")) (EApp (EApp (EVar "applySuppressionsDirs") (EApp (EVar "collectDirectives") (EVar "src"))) (EVar "findings")))
(DTypeSig true "applySuppressionsDirs" (TyFun (TyApp (TyCon "List") (TyCon "Directive")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressionsDirs" ((PVar "dirs") (PVar "findings")) (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EApp (EVar "isSuppressed") (EVar "dirs")) (EVar "f"))))) (EVar "findings")))
(DTypeSig true "applySuppressionsMulti" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressionsMulti" ((PVar "srcs") (PVar "findings")) (EApp (EApp (EVar "applySuppressionsMultiDirs") (EApp (EApp (EVar "map") (EVar "fileDirectivesOf")) (EVar "srcs"))) (EVar "findings")))
(DTypeSig true "applySuppressionsMultiDirs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressionsMultiDirs" ((PVar "dirTable") (PVar "findings")) (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EApp (EVar "findingSuppressedMulti") (EVar "dirTable")) (EVar "f"))))) (EVar "findings")))
(DTypeSig false "fileDirectivesOf" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))))
(DFunDef false "fileDirectivesOf" ((PTuple (PVar "path") (PVar "src"))) (ETuple (EVar "path") (EApp (EVar "collectDirectives") (EVar "src"))))
(DTypeSig false "findingSuppressedMulti" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))) (TyFun (TyCon "Finding") (TyCon "Bool"))))
(DFunDef false "findingSuppressedMulti" ((PVar "dirTable") (PVar "f")) (EMatch (EApp (EApp (EVar "lookupDirs") (EApp (EVar "findingFileOf") (EVar "f"))) (EVar "dirTable")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "dirs")) () (EApp (EApp (EVar "isSuppressed") (EVar "dirs")) (EVar "f")))))
(DTypeSig false "findingFileOf" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "findingFileOf" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "loc") (arm (PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild)) () (EVar "file")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "lookupDirs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Directive"))))))
(DFunDef false "lookupDirs" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupDirs" ((PVar "path") (PCons (PTuple (PVar "p") (PVar "ds")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "p") (EVar "path")) (EApp (EVar "Some") (EVar "ds")) (EApp (EApp (EVar "lookupDirs") (EVar "path")) (EVar "rest"))))
(DTypeSig true "collectDirectives" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive"))))
(DFunDef false "collectDirectives" ((PVar "src")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "c")) (EApp (EVar "dirToList") (EApp (EVar "parseDirective") (EVar "c"))))) (EApp (EVar "collectComments") (EVar "src"))))
(DTypeSig false "dirToList" (TyFun (TyApp (TyCon "Option") (TyCon "Directive")) (TyApp (TyCon "List") (TyCon "Directive"))))
(DFunDef false "dirToList" ((PCon "None")) (EListLit))
(DFunDef false "dirToList" ((PCon "Some" (PVar "d"))) (EListLit (EVar "d")))
(DTypeSig false "parseDirective" (TyFun (TyCon "Comment") (TyApp (TyCon "Option") (TyCon "Directive"))))
(DFunDef false "parseDirective" ((PVar "c")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "trimWs") (EApp (EVar "commentText") (EVar "c")))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "body")) (EApp (EApp (EVar "parseDirectiveBody") (EApp (EVar "commentLine") (EVar "c"))) (EApp (EVar "trimWs") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "body"))) (EVar "body")))) (EVar "None")))))
(DTypeSig false "parseDirectiveBody" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Directive")))))
(DFunDef false "parseDirectiveBody" ((PVar "line") (PVar "s")) (EMatch (EApp (EApp (EVar "matchKeyword") (ELit (LString "lint-disable-next-line"))) (EVar "s")) (arm (PCon "Some" (PVar "names")) () (EApp (EVar "Some") (EApp (EApp (EVar "Directive") (EApp (EVar "DScopeLine") (EBinOp "+" (EVar "line") (ELit (LInt 1))))) (EApp (EVar "parseRuleNames") (EVar "names"))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "matchKeyword") (ELit (LString "lint-disable-line"))) (EVar "s")) (arm (PCon "Some" (PVar "names")) () (EApp (EVar "Some") (EApp (EApp (EVar "Directive") (EApp (EVar "DScopeLine") (EVar "line"))) (EApp (EVar "parseRuleNames") (EVar "names"))))) (arm (PCon "None") () (EApp (EApp (EVar "map") (ELam ((PVar "names")) (EApp (EApp (EVar "Directive") (EVar "DScopeFile")) (EApp (EVar "parseRuleNames") (EVar "names"))))) (EApp (EApp (EVar "matchKeyword") (ELit (LString "lint-disable-file"))) (EVar "s"))))))))
(DTypeSig false "matchKeyword" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "matchKeyword" ((PVar "kw") (PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (EVar "kw")) (EVar "s")) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "kw"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "rest") (ELit (LString ""))) (EApp (EApp (EVar "startsWith") (ELit (LString " "))) (EVar "rest"))) (EApp (EApp (EVar "startsWith") (ELit (LString "\t"))) (EVar "rest"))) (EApp (EVar "Some") (EApp (EVar "trimWs") (EVar "rest"))) (EVar "None")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseRuleNames" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "parseRuleNames" ((PVar "s")) (EApp (EApp (EVar "filterList") (EVar "nonEmptyStr")) (EApp (EApp (EVar "flatMap") (EApp (EVar "splitOnChar") (ELit (LChar " ")))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar ","))) (EVar "s")))))
(DTypeSig false "nonEmptyStr" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nonEmptyStr" ((PVar "n")) (EBinOp "!=" (EVar "n") (ELit (LString ""))))
(DTypeSig false "isSuppressed" (TyFun (TyApp (TyCon "List") (TyCon "Directive")) (TyFun (TyCon "Finding") (TyCon "Bool"))))
(DFunDef false "isSuppressed" ((PVar "dirs") (PVar "f")) (EApp (EApp (EVar "anyList") (EApp (EVar "dirCoversFinding") (EVar "f"))) (EVar "dirs")))
(DTypeSig false "dirCoversFinding" (TyFun (TyCon "Finding") (TyFun (TyCon "Directive") (TyCon "Bool"))))
(DFunDef false "dirCoversFinding" ((PVar "f") (PCon "Directive" (PVar "scope") (PVar "names"))) (EBinOp "&&" (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "names")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names"))) (EApp (EApp (EVar "scopeMatches") (EApp (EVar "findingLineNo") (EVar "f"))) (EVar "scope"))))
(DTypeSig false "scopeMatches" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "DirScope") (TyCon "Bool"))))
(DFunDef false "scopeMatches" (PWild (PCon "DScopeFile")) (EVar "True"))
(DFunDef false "scopeMatches" ((PCon "Some" (PVar "line")) (PCon "DScopeLine" (PVar "l"))) (EBinOp "==" (EVar "line") (EVar "l")))
(DFunDef false "scopeMatches" ((PCon "None") (PCon "DScopeLine" PWild)) (EVar "False"))
(DTypeSig false "findingLineNo" (TyFun (TyCon "Finding") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "findingLineNo" ((PVar "f")) (EApp (EApp (EVar "map") (ELam ((PCon "Loc" PWild (PVar "l") PWild PWild PWild)) (EVar "l"))) (EFieldAccess (EVar "f") "loc")))
(DTypeSig false "trimWs" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trimWs" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "a") (EApp (EApp (EApp (EVar "trimWsStart") (EVar "cs")) (EVar "n")) (ELit (LInt 0)))) (DoLet false false (PVar "b") (EApp (EApp (EApp (EVar "trimWsEnd") (EVar "cs")) (EVar "a")) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "a")) (EVar "b")) (EVar "s")))))
(DTypeSig false "trimWsStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimWsStart" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "i") (EIf (EApp (EVar "isWsChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "trimWsStart") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "trimWsEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimWsEnd" ((PVar "cs") (PVar "a") (PVar "n")) (EIf (EBinOp "<=" (EVar "n") (EVar "a")) (EVar "a") (EIf (EApp (EVar "isWsChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "cs"))) (EApp (EApp (EApp (EVar "trimWsEnd") (EVar "cs")) (EVar "a")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "n") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isWsChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isWsChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar " "))) (EBinOp "==" (EVar "c") (ELit (LChar "\t")))) (EBinOp "==" (EVar "c") (ELit (LChar "\r")))) (EBinOp "==" (EVar "c") (ELit (LChar "\n")))))
(DTypeSig false "unwrapLoc" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "unwrapLoc" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "unwrapLoc") (EVar "e")))
(DFunDef false "unwrapLoc" ((PVar "e")) (EVar "e"))
(DTypeSig false "declLocList" (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "declLocList" ((PVar "pos") (PVar "prog")) (EApp (EApp (EVar "zipDeclLoc") (EVar "prog")) (EApp (EVar "positionsDecls") (EVar "pos"))))
(DTypeSig false "zipDeclLoc" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "zipDeclLoc" ((PList) PWild) (EListLit))
(DFunDef false "zipDeclLoc" ((PCons (PVar "d") (PVar "ds")) (PList)) (EBinOp "::" (ETuple (EVar "d") (EVar "None")) (EApp (EApp (EVar "zipDeclLoc") (EVar "ds")) (EListLit))))
(DFunDef false "zipDeclLoc" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EBinOp "::" (ETuple (EVar "d") (EApp (EVar "Some") (EApp (EVar "declPosToLoc") (EVar "p")))) (EApp (EApp (EVar "zipDeclLoc") (EVar "ds")) (EVar "ps"))))
(DTypeSig false "declPosToLoc" (TyFun (TyCon "DeclPos") (TyCon "Loc")))
(DFunDef false "declPosToLoc" ((PVar "p")) (ELet false (PVar "l") (EApp (EVar "declPosLine") (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "l")) (ELit (LInt 1))) (EVar "l")) (ELit (LInt 1)))))
(DTypeSig false "ruleMatchOnParam" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleMatchOnParam" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "matchParamDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "matchParamDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "matchParamDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "matchParamDecl") (EVar "loc")) (EVar "d")))
(DTypeSig false "matchParamDecl" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "matchParamDecl" ((PVar "loc") (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "matchParamFinding") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "body")))
(DFunDef false "matchParamDecl" ((PVar "loc") (PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EApp (EVar "matchParamMethod") (EVar "loc"))) (EVar "methods")))
(DFunDef false "matchParamDecl" ((PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "matchParamDecl") (EVar "loc")) (EVar "d")))
(DFunDef false "matchParamDecl" (PWild PWild) (EListLit))
(DTypeSig false "matchParamMethod" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "matchParamMethod" ((PVar "loc") (PCon "ImplMethod" (PVar "name") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "matchParamFinding") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "body")))
(DTypeSig false "matchParamFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "matchParamFinding" ((PVar "loc") (PVar "name") (PVar "pats") (PVar "body")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EMatch" (PVar "scrut") (PVar "arms")) () (EApp (EApp (EApp (EApp (EApp (EVar "matchParamArms") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "scrut")) (EVar "arms"))) (arm PWild () (EListLit))))
(DTypeSig false "matchParamArms" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "matchParamArms" ((PVar "loc") (PVar "name") (PVar "pats") (PVar "scrut") (PVar "arms")) (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "arms")) (ELit (LInt 2))) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "unwrapLoc") (EVar "scrut")) (arm (PCon "EVar" (PVar "p")) () (EApp (EApp (EApp (EApp (EVar "matchParamHit") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "p"))) (arm PWild () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchParamHit" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "matchParamHit" ((PVar "loc") (PVar "name") (PVar "pats") (PVar "p")) (EIf (EApp (EApp (EVar "anyList") (EApp (EVar "isBareParam") (EVar "p"))) (EVar "pats")) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameMatchParam")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function '")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' matches on parameter '"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "' — use a multi-clause function definition")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc"))))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isBareParam" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "isBareParam" ((PVar "p") (PCon "PVar" (PVar "q") PWild)) (EBinOp "==" (EVar "p") (EVar "q")))
(DFunDef false "isBareParam" (PWild PWild) (EVar "False"))
(DTypeSig false "matchParamFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "matchParamFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EMatch (EApp (EApp (EVar "matchBodyOnBareParam") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PTuple (PVar "p") (PVar "k") (PVar "arms"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "matchParamFixArms") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "p")) (EVar "k")) (EVar "arms"))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "matchParamFix" (PWild PWild) (EVar "None"))
(DTypeSig false "matchParamFixArms" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "matchParamFixArms" ((PVar "vis") (PVar "name") (PVar "pats") (PVar "p") (PVar "k") (PVar "arms")) (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "arms")) (ELit (LInt 2))) (EVar "None") (EIf (EApp (EApp (EVar "anyList") (EVar "armHasGuard")) (EVar "arms")) (EVar "None") (EIf (EApp (EApp (EVar "anyList") (EApp (EVar "armUnsafeMention") (EVar "p"))) (EVar "arms")) (EVar "None") (EIf (EVar "otherwise") (EApp (EVar "Some") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EApp (EVar "armToClause") (EVar "vis")) (EVar "name")) (EVar "p")) (EVar "pats")) (EVar "k"))) (EVar "arms"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "matchBodyOnBareParam" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Arm")))))))
(DFunDef false "matchBodyOnBareParam" ((PVar "pats") (PVar "body")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EMatch" (PVar "scrut") (PVar "arms")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "scrut")) (arm (PCon "EVar" (PVar "p")) () (EApp (EApp (EVar "map") (ELam ((PVar "k")) (ETuple (EVar "p") (EVar "k") (EVar "arms")))) (EApp (EApp (EVar "paramIndex") (EVar "p")) (EVar "pats")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "armHasGuard" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armHasGuard" ((PCon "Arm" PWild (PVar "guards") PWild)) (EApp (EVar "isNonEmptyL") (EVar "guards")))
(DTypeSig false "armMentionsParam" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armMentionsParam" ((PVar "p") (PCon "Arm" PWild PWild (PVar "body"))) (EApp (EApp (EVar "wholeWordIn") (EVar "p")) (EApp (EVar "exprToString") (EVar "body"))))
(DTypeSig false "armUnsafeMention" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armUnsafeMention" ((PVar "p") (PVar "arm")) (EBinOp "&&" (EApp (EApp (EVar "armMentionsParam") (EVar "p")) (EVar "arm")) (EApp (EVar "not") (EApp (EVar "armPatIsWild") (EVar "arm")))))
(DTypeSig false "armPatIsWild" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armPatIsWild" ((PCon "Arm" (PVar "pat") PWild PWild)) (EApp (EVar "patIsWild") (EVar "pat")))
(DTypeSig false "patIsWild" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patIsWild" ((PCon "PWild")) (EVar "True"))
(DFunDef false "patIsWild" (PWild) (EVar "False"))
(DTypeSig false "paramIndex" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "paramIndex" ((PVar "p") (PVar "pats")) (EApp (EApp (EApp (EVar "paramIndexGo") (EVar "p")) (EVar "pats")) (ELit (LInt 0))))
(DTypeSig false "paramIndexGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "paramIndexGo" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "paramIndexGo" ((PVar "p") (PCons (PVar "pat") (PVar "rest")) (PVar "i")) (EIf (EApp (EApp (EVar "isBareParam") (EVar "p")) (EVar "pat")) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "paramIndexGo") (EVar "p")) (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "armToClause" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Int") (TyFun (TyCon "Arm") (TyCon "Decl"))))))))
(DFunDef false "armToClause" ((PVar "vis") (PVar "name") (PVar "p") (PVar "pats") (PVar "k") (PCon "Arm" (PVar "pat") PWild (PVar "body"))) (EBlock (DoLet false false (PVar "cpat") (EIf (EBinOp "&&" (EApp (EVar "patIsWild") (EVar "pat")) (EApp (EApp (EVar "wholeWordIn") (EVar "p")) (EApp (EVar "exprToString") (EVar "body")))) (EApp (EApp (EVar "PVar") (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EApp (EApp (EApp (EVar "replaceAt") (EVar "k")) (EVar "cpat")) (EVar "pats"))) (EVar "body")))))
(DTypeSig false "replaceAt" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "replaceAt" (PWild PWild (PList)) (EListLit))
(DFunDef false "replaceAt" ((PLit (LInt 0)) (PVar "x") (PCons PWild (PVar "rest"))) (EBinOp "::" (EVar "x") (EVar "rest")))
(DFunDef false "replaceAt" ((PVar "n") (PVar "x") (PCons (PVar "y") (PVar "rest"))) (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "replaceAt") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "x")) (EVar "rest"))))
(DTypeSig false "wholeWordIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "wholeWordIn" ((PVar "name") (PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "nlen") (EApp (EVar "stringLength") (EVar "name"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wholeWordGo") (EVar "name")) (EVar "nlen")) (EVar "s")) (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "wholeWordGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))))
(DFunDef false "wholeWordGo" ((PVar "name") (PVar "nlen") (PVar "s") (PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (EVar "nlen")) (EVar "n")) (EVar "False") (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "boundaryAt") (EVar "cs")) (EVar "i")) (EApp (EApp (EVar "boundaryAt") (EVar "cs")) (EBinOp "+" (EVar "i") (EVar "nlen")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (EVar "nlen"))) (EVar "s")) (EVar "name"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wholeWordGo") (EVar "name")) (EVar "nlen")) (EVar "s")) (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "boundaryAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "boundaryAt" ((PVar "cs") (PVar "j")) (EIf (EBinOp "==" (EVar "j") (ELit (LInt 0))) (EVar "True") (EIf (EBinOp ">=" (EVar "j") (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "True") (EIf (EVar "otherwise") (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isAlnum") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "j") (ELit (LInt 1)))) (EVar "cs")))) (EApp (EVar "not") (EApp (EVar "isAlnum") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "cs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "ruleDestructureInParam" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleDestructureInParam" (PWild PWild (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "orc") (EApp (EVar "buildOracle") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EVar "destructureDeclL") (EVar "orc"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "destructureDeclL" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "destructureDeclL" ((PVar "orc") (PTuple (PVar "d") (PVar "loc"))) (EMatch (EVar "d") (arm (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EVar "destructureFinding") (EVar "orc")) (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "body"))) (arm PWild () (EListLit))))
(DTypeSig false "destructureFinding" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "destructureFinding" ((PVar "orc") (PVar "loc") (PVar "name") (PVar "pats") (PVar "body")) (EMatch (EApp (EApp (EVar "matchBodyOnBareParam") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PTuple (PVar "p") PWild (PVar "arms"))) () (EApp (EApp (EApp (EApp (EApp (EVar "destructureArmsFinding") (EVar "orc")) (EVar "loc")) (EVar "name")) (EVar "p")) (EVar "arms"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "destructureArmsFinding" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "destructureArmsFinding" ((PVar "orc") (PVar "loc") (PVar "name") (PVar "p") (PList (PVar "arm"))) (EIf (EApp (EApp (EApp (EVar "destructureArmFires") (EVar "orc")) (EVar "p")) (EVar "arm")) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDestructureInParam")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function '")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' destructures parameter '"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "' via a single-arm irrefutable `match`. Destructure it directly in the parameter position")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc"))))) (EListLit)))
(DFunDef false "destructureArmsFinding" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "destructureArmFires" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool")))))
(DFunDef false "destructureArmFires" ((PVar "orc") (PVar "p") (PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "guards")) (EApp (EApp (EVar "destructurablePat") (EVar "orc")) (EVar "pat"))) (EApp (EVar "not") (EApp (EApp (EVar "wholeWordIn") (EVar "p")) (EApp (EVar "exprToString") (EVar "body"))))))
(DTypeSig false "destructurablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "destructurablePat" ((PVar "orc") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps")))
(DFunDef false "destructurablePat" ((PVar "orc") (PCon "PCon" (PVar "c") (PVar "ps"))) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps"))))
(DFunDef false "destructurablePat" ((PVar "orc") (PCon "PRec" (PVar "c") (PVar "fs") PWild)) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "recPatFieldIrrefutable") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "destructurablePat" (PWild PWild) (EVar "False"))
(DTypeSig false "patIrrefutable" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "patIrrefutable" (PWild (PCon "PVar" PWild PWild)) (EVar "True"))
(DFunDef false "patIrrefutable" (PWild (PCon "PWild")) (EVar "True"))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps")))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PCon" (PVar "c") (PVar "ps"))) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps"))))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PRec" (PVar "c") (PVar "fs") PWild)) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "recPatFieldIrrefutable") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PAs" PWild PWild (PVar "p"))) (EApp (EApp (EVar "patIrrefutable") (EVar "orc")) (EVar "p")))
(DFunDef false "patIrrefutable" (PWild PWild) (EVar "False"))
(DTypeSig false "recPatFieldIrrefutable" (TyFun (TyCon "Oracle") (TyFun (TyCon "RecPatField") (TyCon "Bool"))))
(DFunDef false "recPatFieldIrrefutable" (PWild (PCon "RecPatField" PWild PWild (PCon "None"))) (EVar "True"))
(DFunDef false "recPatFieldIrrefutable" ((PVar "orc") (PCon "RecPatField" PWild PWild (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "patIrrefutable") (EVar "orc")) (EVar "p")))
(DTypeSig false "ctorIsSingle" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ctorIsSingle" ((PVar "orc") (PVar "c")) (EMatch (EApp (EApp (EVar "oGetCtorType") (EVar "orc")) (EVar "c")) (arm (PCon "Some" (PVar "t")) () (EMatch (EApp (EApp (EVar "oGetCtors") (EVar "orc")) (EVar "t")) (arm (PCon "Some" (PVar "ctors")) () (EBinOp "==" (EApp (EVar "listLen") (EVar "ctors")) (ELit (LInt 1)))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "destructureInParamFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "destructureInParamFix" ((PVar "orc") (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EMatch (EApp (EApp (EVar "matchBodyOnBareParam") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PTuple (PVar "p") (PVar "k") (PVar "arms"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "destructureInParamFixArms") (EVar "orc")) (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "p")) (EVar "k")) (EVar "arms"))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "destructureInParamFix" (PWild PWild) (EVar "None"))
(DTypeSig false "destructureInParamFixArms" (TyFun (TyCon "Oracle") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "destructureInParamFixArms" ((PVar "orc") (PVar "vis") (PVar "name") (PVar "pats") (PVar "p") (PVar "k") (PList (PVar "arm"))) (EIf (EApp (EApp (EApp (EVar "destructureArmFires") (EVar "orc")) (EVar "p")) (EVar "arm")) (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "armToClause") (EVar "vis")) (EVar "name")) (EVar "p")) (EVar "pats")) (EVar "k")) (EVar "arm")))) (EVar "None")))
(DFunDef false "destructureInParamFixArms" (PWild PWild PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "derivableIfaces" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "derivableIfaces" () (EListLit (ELit (LString "Eq")) (ELit (LString "Ord")) (ELit (LString "Debug"))))
(DTypeSig false "ruleDerivable" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleDerivable" ((PVar "path") PWild (PVar "pos") (PVar "prog")) (EIf (EApp (EVar "isStdlibPath") (EVar "path")) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "orc") (EApp (EVar "buildOracle") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EVar "derivableDeclL") (EVar "orc"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "derivableDeclL" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "derivableDeclL" ((PVar "orc") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EApp (EVar "derivableDecl") (EVar "orc")) (EVar "loc")) (EVar "d")))
(DTypeSig false "derivableDecl" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "derivableDecl" ((PVar "orc") (PVar "loc") (PRec "DImpl" ((rf "iface" None) (rf "tys" None)) true)) (EApp (EApp (EApp (EApp (EVar "derivableHit") (EVar "orc")) (EVar "loc")) (EVar "iface")) (EVar "tys")))
(DFunDef false "derivableDecl" ((PVar "orc") (PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "derivableDecl") (EVar "orc")) (EVar "loc")) (EVar "d")))
(DFunDef false "derivableDecl" (PWild PWild PWild) (EListLit))
(DTypeSig false "derivableHit" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "derivableHit" ((PVar "orc") (PVar "loc") (PVar "iface") (PVar "tys")) (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EVar "derivableIfaces")) (EMatch (EApp (EVar "singleNamedType") (EVar "tys")) (arm (PCon "Some" (PVar "tyName")) () (EIf (EApp (EApp (EVar "hasUserDataDecl") (EVar "orc")) (EVar "tyName")) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDerivable")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "hand-written `impl ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "` for '"))) (EApp (EVar "display") (EVar "tyName"))) (ELit (LString "' — use `deriving ("))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString ")`")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc"))))) (EListLit))) (arm (PCon "None") () (EListLit))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hasUserDataDecl" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasUserDataDecl" ((PVar "orc") (PVar "tyName")) (EMatch (EApp (EApp (EVar "oGetCtors") (EVar "orc")) (EVar "tyName")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "singleNamedType" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "singleNamedType" ((PList (PVar "t"))) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "singleNamedType" (PWild) (EVar "None"))
(DTypeSig false "tyHeadName" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "tyHeadName" ((PCon "TyCon" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "tyHeadName" ((PCon "TyApp" (PVar "f") PWild)) (EApp (EVar "tyHeadName") (EVar "f")))
(DFunDef false "tyHeadName" (PWild) (EVar "None"))
(DTypeSig false "stdlibNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "stdlibNames" () (EListLit (ELit (LString "reverse")) (ELit (LString "take")) (ELit (LString "drop")) (ELit (LString "map")) (ELit (LString "filter")) (ELit (LString "flatMap")) (ELit (LString "concatMap")) (ELit (LString "foldl")) (ELit (LString "foldr")) (ELit (LString "length")) (ELit (LString "elem")) (ELit (LString "intercalate")) (ELit (LString "intersperse")) (ELit (LString "zip")) (ELit (LString "zipWith"))))
(DTypeSig false "ruleStdlibReimpl" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleStdlibReimpl" ((PVar "path") PWild (PVar "pos") (PVar "prog")) (EIf (EApp (EVar "isStdlibPath") (EVar "path")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EVar "map") (EVar "stdlibFinding")) (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EVar "filterList") (EVar "inStdlibPair")) (EApp (EApp (EVar "flatMap") (EVar "topDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "topDefNameL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "topDefNameL" ((PTuple (PCon "DFunDef" PWild (PVar "name") PWild PWild) (PVar "loc"))) (EListLit (ETuple (EVar "name") (EVar "loc"))))
(DFunDef false "topDefNameL" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "topDefNameL") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "topDefNameL" (PWild) (EListLit))
(DTypeSig false "inStdlibPair" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool")))
(DFunDef false "inStdlibPair" ((PTuple (PVar "n") PWild)) (EApp (EVar "inStdlib") (EVar "n")))
(DTypeSig false "dedupeNamesLoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "dedupeNamesLoc" ((PVar "xs")) (EApp (EApp (EVar "dedupBy") (EVar "fst")) (EVar "xs")))
(DTypeSig false "inStdlib" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "inStdlib" ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "stdlibNames")))
(DTypeSig false "stdlibFinding" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding")))
(DFunDef false "stdlibFinding" ((PTuple (PVar "name") (PVar "loc"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameStdlibReimpl")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level '")) (EVar "name")) (ELit (LString "' shadows a stdlib function — use the stdlib version")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "ruleMissingSignature" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleMissingSignature" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "map") (EVar "missingSigFinding")) (EApp (EApp (EVar "filterList") (EApp (EVar "missingSigPair") (EApp (EVar "nameSetOf") (EApp (EApp (EVar "flatMap") (EVar "topSigNameL")) (EVar "prog"))))) (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EVar "flatMap") (EVar "topDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))))
(DTypeSig false "topSigNameL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topSigNameL" ((PCon "DTypeSig" PWild (PVar "name") PWild)) (EListLit (EVar "name")))
(DFunDef false "topSigNameL" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topSigNameL") (EVar "d")))
(DFunDef false "topSigNameL" (PWild) (EListLit))
(DTypeSig false "missingSigPair" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "missingSigPair" ((PVar "sigNames") (PTuple (PVar "n") PWild)) (EApp (EVar "not") (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "main"))) (EApp (EApp (EVar "has") (EVar "n")) (EVar "sigNames")))))
(DTypeSig false "missingSigFinding" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding")))
(DFunDef false "missingSigFinding" ((PTuple (PVar "name") (PVar "loc"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameMissingSignature")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level '")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' has no type signature. Add a `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString " : …` declaration")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "ruleSelfShadowExtern" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleSelfShadowExtern" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EVar "selfShadowFindings") (EApp (EApp (EVar "flatMap") (EVar "selfShadowClauseL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))
(DTypeSig false "selfShadowFindings" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "selfShadowFindings" ((PVar "clauses")) (EApp (EApp (EVar "map") (EVar "selfShadowFinding")) (EApp (EApp (EVar "filterList") (EApp (EVar "allClausesSelfCall") (EVar "clauses"))) (EApp (EApp (EVar "dedupBy") (EVar "fst")) (EApp (EApp (EVar "map") (EVar "clauseNameLoc")) (EVar "clauses"))))))
(DTypeSig false "selfShadowClauseL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "selfShadowClauseL" ((PTuple (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body")) (PVar "loc"))) (EListLit (ETuple (EVar "name") (EVar "pats") (EVar "body") (EVar "loc"))))
(DFunDef false "selfShadowClauseL" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "selfShadowClauseL") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "selfShadowClauseL" (PWild) (EListLit))
(DTypeSig false "clauseNameLoc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "clauseNameLoc" ((PTuple (PVar "n") PWild PWild (PVar "l"))) (ETuple (EVar "n") (EVar "l")))
(DTypeSig false "allClausesSelfCall" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "allClausesSelfCall" ((PVar "clauses") (PTuple (PVar "name") PWild)) (EApp (EApp (EVar "allList") (EApp (EVar "clauseSelfCallOrOther") (EVar "name"))) (EVar "clauses")))
(DTypeSig false "clauseSelfCallOrOther" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "clauseSelfCallOrOther" ((PVar "name") (PTuple (PVar "cn") (PVar "pats") (PVar "body") PWild)) (EBinOp "||" (EBinOp "!=" (EVar "cn") (EVar "name")) (EApp (EApp (EApp (EVar "unconditionalSelfCall") (EVar "name")) (EVar "pats")) (EVar "body"))))
(DTypeSig false "unconditionalSelfCall" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "unconditionalSelfCall" ((PVar "name") (PList) (PVar "body")) (EApp (EApp (EVar "isBareSelf") (EVar "name")) (EApp (EVar "stripWrap") (EVar "body"))))
(DFunDef false "unconditionalSelfCall" ((PVar "name") PWild (PVar "body")) (EApp (EApp (EVar "isHeadSelfApp") (EVar "name")) (EApp (EVar "stripWrap") (EVar "body"))))
(DTypeSig false "stripWrap" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripWrap" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stripWrap") (EVar "e")))
(DFunDef false "stripWrap" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "stripWrap") (EVar "e")))
(DFunDef false "stripWrap" ((PVar "e")) (EVar "e"))
(DTypeSig false "isBareSelf" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isBareSelf" ((PVar "name") (PCon "EVar" (PVar "w"))) (EBinOp "==" (EVar "name") (EVar "w")))
(DFunDef false "isBareSelf" (PWild PWild) (EVar "False"))
(DTypeSig false "isHeadSelfApp" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isHeadSelfApp" ((PVar "name") (PCon "EApp" (PVar "f") (PVar "a"))) (EApp (EApp (EVar "isBareSelf") (EVar "name")) (EApp (EVar "appHead") (EApp (EVar "stripWrap") (EVar "f")))))
(DFunDef false "isHeadSelfApp" (PWild PWild) (EVar "False"))
(DTypeSig false "appHead" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "appHead" ((PVar "e")) (EMatch (EApp (EVar "stripWrap") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EVar "appHead") (EVar "f"))) (arm (PVar "x") () (EVar "x"))))
(DTypeSig false "selfShadowFinding" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding")))
(DFunDef false "selfShadowFinding" ((PTuple (PVar "name") (PVar "loc"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameSelfShadowExtern")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level '")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' unconditionally calls itself with no base case — an infinite self-recursion, not a forward to a same-named extern/definition. Rename the binding (give it a distinct name) or add a terminating `match`/`if`/guard")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "irrefutablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "irrefutablePat" (PWild (PCon "PVar" PWild PWild)) (EVar "True"))
(DFunDef false "irrefutablePat" (PWild (PCon "PWild")) (EVar "True"))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutablePat") (EVar "orc"))) (EVar "ps"))))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutableField") (EVar "orc"))) (EVar "fields"))))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PCon" (PVar "c") (PVar "subps"))) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSole") (EVar "orc")) (EVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutablePat") (EVar "orc"))) (EVar "subps")))))
(DFunDef false "irrefutablePat" (PWild PWild) (EVar "False"))
(DTypeSig false "ctorIsSole" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ctorIsSole" ((PVar "orc") (PVar "c")) (EMatch (EApp (EApp (EVar "oGetCtorType") (EVar "orc")) (EVar "c")) (arm (PCon "Some" (PVar "tyName")) () (EMatch (EApp (EApp (EVar "oGetCtors") (EVar "orc")) (EVar "tyName")) (arm (PCon "Some" (PVar "ctors")) () (EBinOp "==" (EApp (EVar "listLen") (EVar "ctors")) (ELit (LInt 1)))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "refutablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "refutablePat" ((PVar "orc") (PVar "p")) (EApp (EVar "not") (EApp (EApp (EVar "irrefutablePat") (EVar "orc")) (EVar "p"))))
(DTypeSig false "refutableField" (TyFun (TyCon "Oracle") (TyFun (TyCon "RecPatField") (TyCon "Bool"))))
(DFunDef false "refutableField" (PWild (PCon "RecPatField" PWild PWild (PCon "None"))) (EVar "False"))
(DFunDef false "refutableField" ((PVar "orc") (PCon "RecPatField" PWild PWild (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "refutablePat") (EVar "orc")) (EVar "p")))
(DTypeSig false "bindMatchTail" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "String") (TyCon "Pat") (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "bindMatchTail" ((PVar "orc") (PVar "stmts")) (EMatch (EApp (EVar "splitTail2") (EVar "stmts")) (arm (PCon "Some" (PTuple (PVar "prefix") (PCon "DoBind" (PCon "PVar" (PVar "v") PWild) (PVar "boundE")) (PCon "DoExpr" (PVar "matchE")))) () (EApp (EApp (EApp (EApp (EApp (EVar "bindMatchArm") (EVar "orc")) (EVar "prefix")) (EVar "v")) (EVar "boundE")) (EApp (EVar "unwrapLoc") (EVar "matchE")))) (arm PWild () (EVar "None"))))
(DTypeSig false "bindMatchArm" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "String") (TyCon "Pat") (TyCon "Expr") (TyCon "Expr")))))))))
(DFunDef false "bindMatchArm" ((PVar "orc") (PVar "prefix") (PVar "v") (PVar "boundE") (PCon "EMatch" (PVar "scrut") (PList (PCon "Arm" (PVar "pat") (PList) (PVar "body"))))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "scrutIsVar") (EVar "v")) (EApp (EVar "unwrapLoc") (EVar "scrut"))) (EApp (EApp (EVar "irrefutablePat") (EVar "orc")) (EVar "pat"))) (EApp (EVar "not") (EApp (EApp (EVar "wholeWordIn") (EVar "v")) (EApp (EVar "exprToString") (EVar "body"))))) (EApp (EVar "Some") (ETuple (EVar "prefix") (EVar "v") (EVar "pat") (EVar "boundE") (EVar "body"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "bindMatchArm" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "scrutIsVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "scrutIsVar" ((PVar "v") (PCon "EVar" (PVar "w"))) (EBinOp "==" (EVar "v") (EVar "w")))
(DFunDef false "scrutIsVar" (PWild PWild) (EVar "False"))
(DTypeSig false "splitTail2" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "DoStmt") (TyCon "DoStmt")))))
(DFunDef false "splitTail2" ((PVar "stmts")) (EMatch (EApp (EVar "reverseL") (EVar "stmts")) (arm (PCons (PVar "lst") (PCons (PVar "scd") (PVar "restRev"))) () (EApp (EVar "Some") (ETuple (EApp (EVar "reverseL") (EVar "restRev")) (EVar "scd") (EVar "lst")))) (arm PWild () (EVar "None"))))
(DTypeSig false "ruleBindThenDestructure" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleBindThenDestructure" (PWild PWild (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "orc") (EApp (EVar "buildOracle") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EVar "bindDestructureDeclL") (EVar "orc"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "bindDestructureDeclL" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "bindDestructureDeclL" ((PVar "orc") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "map") (EApp (EVar "bindDestructureFinding") (EVar "loc"))) (EApp (EApp (EVar "declBindHits") (EVar "orc")) (EVar "d"))))
(DTypeSig false "declBindHits" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declBindHits" ((PVar "orc") (PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EApp (EVar "collectBindHits") (EVar "orc")) (EVar "body")))
(DFunDef false "declBindHits" ((PVar "orc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declBindHits") (EVar "orc")) (EVar "d")))
(DFunDef false "declBindHits" (PWild PWild) (EListLit))
(DTypeSig false "bindDestructureFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "bindDestructureFinding" ((PVar "loc") (PVar "v")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameBindThenDestructure")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "binds '")) (EVar "v")) (ELit (LString "' then immediately destructures it in a final `match`. Inline the pattern into the bind")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "collectBindHits" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectBindHits" ((PVar "orc") (PVar "e")) (EBinOp "++" (EApp (EApp (EVar "tailHitOf") (EVar "orc")) (EVar "e")) (EApp (EApp (EVar "flatMap") (EApp (EVar "collectBindHits") (EVar "orc"))) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "tailHitOf" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tailHitOf" ((PVar "orc") (PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "hitNameOf") (EVar "orc")) (EVar "stmts")))
(DFunDef false "tailHitOf" ((PVar "orc") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "hitNameOf") (EVar "orc")) (EVar "stmts")))
(DFunDef false "tailHitOf" (PWild PWild) (EListLit))
(DTypeSig false "hitNameOf" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "hitNameOf" ((PVar "orc") (PVar "stmts")) (EMatch (EApp (EApp (EVar "bindMatchTail") (EVar "orc")) (EVar "stmts")) (arm (PCon "Some" (PTuple PWild (PVar "v") PWild PWild PWild)) () (EListLit (EVar "v"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "childExprs" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "childExprs" ((PCon "ELoc" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EDoOrigin" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EApp" (PVar "f") (PVar "x"))) (EListLit (EVar "f") (EVar "x")))
(DFunDef false "childExprs" ((PCon "ELam" PWild (PVar "b"))) (EListLit (EVar "b")))
(DFunDef false "childExprs" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EListLit (EVar "e1") (EVar "e2")))
(DFunDef false "childExprs" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EBinOp "::" (EVar "s") (EApp (EApp (EVar "flatMap") (EVar "armExprs")) (EVar "arms"))))
(DFunDef false "childExprs" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EListLit (EVar "c") (EVar "t") (EVar "el")))
(DFunDef false "childExprs" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EListLit (EVar "a") (EVar "b")))
(DFunDef false "childExprs" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EListLit (EVar "a")))
(DFunDef false "childExprs" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EListLit (EVar "a") (EVar "b")))
(DFunDef false "childExprs" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "ETuple" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EListLit" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EArrayLit" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") PWild PWild)) (EListLit (EVar "e") (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "letBindExprs")) (EVar "binds")) (EListLit (EVar "body"))))
(DFunDef false "childExprs" ((PCon "ESection" (PVar "s"))) (EApp (EVar "sectionExprs") (EVar "s")))
(DFunDef false "childExprs" ((PCon "EIndex" (PVar "a") (PVar "i") PWild)) (EListLit (EVar "a") (EVar "i")))
(DFunDef false "childExprs" ((PCon "EAnnot" (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "stmtExprs")) (EVar "stmts")))
(DFunDef false "childExprs" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "stmtExprs")) (EVar "stmts")))
(DFunDef false "childExprs" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "flatMap") (EVar "interpPartExprs")) (EVar "parts")))
(DFunDef false "childExprs" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "flatMap") (EVar "guardArmExprs")) (EVar "arms")))
(DFunDef false "childExprs" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "map") (EVar "fieldAssignExpr")) (EVar "fs")))
(DFunDef false "childExprs" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EBinOp "::" (EVar "e") (EApp (EApp (EVar "map") (EVar "fieldAssignExpr")) (EVar "fs"))))
(DFunDef false "childExprs" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "::" (EVar "e") (EApp (EApp (EVar "map") (EVar "fieldAssignExpr")) (EVar "fs"))))
(DFunDef false "childExprs" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EVar "flatMap") (EVar "kvExprs")) (EVar "kvs")))
(DFunDef false "childExprs" ((PCon "ESetLit" PWild (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EAsPat" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" (PWild) (EListLit))
(DTypeSig false "armExprs" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "armExprs" ((PCon "Arm" PWild (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "guardExprs")) (EVar "gs")) (EListLit (EVar "body"))))
(DTypeSig false "guardExprs" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "guardExprs" ((PCon "GBool" (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "guardExprs" ((PCon "GBind" PWild (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig false "stmtExprs" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "stmtExprs" ((PCon "DoExpr" (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoBind" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoLet" PWild PWild PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoAssign" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig false "letBindExprs" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "letBindExprs" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EVar "flatMap") (EVar "funClauseExprs")) (EVar "clauses")))
(DTypeSig false "funClauseExprs" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "funClauseExprs" ((PCon "FunClause" PWild (PVar "body"))) (EListLit (EVar "body")))
(DTypeSig false "sectionExprs" (TyFun (TyCon "Section") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "sectionExprs" ((PCon "SecBare" PWild)) (EListLit))
(DFunDef false "sectionExprs" ((PCon "SecRight" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "sectionExprs" ((PCon "SecLeft" (PVar "e") PWild)) (EListLit (EVar "e")))
(DTypeSig false "interpPartExprs" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "interpPartExprs" ((PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "interpPartExprs" ((PCon "InterpExpr" (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig false "guardArmExprs" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "guardArmExprs" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "guardExprs")) (EVar "gs")) (EListLit (EVar "body"))))
(DTypeSig false "fieldAssignExpr" (TyFun (TyCon "FieldAssign") (TyCon "Expr")))
(DFunDef false "fieldAssignExpr" ((PCon "FieldAssign" PWild (PVar "e"))) (EVar "e"))
(DTypeSig false "kvExprs" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "kvExprs" ((PTuple (PVar "k") (PVar "v"))) (EListLit (EVar "k") (EVar "v")))
(DTypeSig false "bindThenDestructureFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "bindThenDestructureFix" ((PVar "orc") (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "body2") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2"))))))))
(DFunDef false "bindThenDestructureFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "bindThenDestructureFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "bindThenDestructureFix" (PWild PWild) (EVar "None"))
(DTypeSig false "rewriteBindExpr" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "f"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "x"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "b"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e1"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e2"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "s"))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindArm") (EVar "orc"))) (EVar "arms"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "c"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "t"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "el"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "b"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "lo"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "lo"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "lo"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "hi"))) (EVar "i")) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindLet") (EVar "orc"))) (EVar "binds"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EApp (EVar "rewriteBindSection") (EVar "orc")) (EVar "s"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EIndex" (PVar "a") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "i"))) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "collapseBindTail") (EVar "orc")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindStmt") (EVar "orc"))) (EVar "stmts")))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EVar "collapseBindTail") (EVar "orc")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindStmt") (EVar "orc"))) (EVar "stmts")))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindInterp") (EVar "orc"))) (EVar "parts"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindGuardArm") (EVar "orc"))) (EVar "arms"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindField") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindField") (EVar "orc"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindField") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindKv") (EVar "orc"))) (EVar "kvs"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindExpr" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "collapseBindTail" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "collapseBindTail" ((PVar "orc") (PVar "stmts")) (EMatch (EApp (EApp (EVar "bindMatchTail") (EVar "orc")) (EVar "stmts")) (arm (PCon "Some" (PTuple (PVar "prefix") PWild (PVar "pat") (PVar "boundE") (PVar "body"))) () (EBinOp "++" (EVar "prefix") (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "pat")) (EVar "boundE")) (EApp (EVar "bodyToStmts") (EVar "body"))))) (arm (PCon "None") () (EVar "stmts"))))
(DTypeSig false "bodyToStmts" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "bodyToStmts" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EDo" (PVar "stmts")) () (EVar "stmts")) (arm (PCon "EBlock" (PVar "stmts")) () (EVar "stmts")) (arm PWild () (EListLit (EApp (EVar "DoExpr") (EVar "e"))))))
(DTypeSig false "rewriteBindStmt" (TyFun (TyCon "Oracle") (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindArm" (TyFun (TyCon "Oracle") (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "rewriteBindArm" ((PVar "orc") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindGuard") (EVar "orc"))) (EVar "gs"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DTypeSig false "rewriteBindGuard" (TyFun (TyCon "Oracle") (TyFun (TyCon "Guard") (TyCon "Guard"))))
(DFunDef false "rewriteBindGuard" ((PVar "orc") (PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindGuard" ((PVar "orc") (PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindLet" (TyFun (TyCon "Oracle") (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "rewriteBindLet" ((PVar "orc") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindClause") (EVar "orc"))) (EVar "clauses"))))
(DTypeSig false "rewriteBindClause" (TyFun (TyCon "Oracle") (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "rewriteBindClause" ((PVar "orc") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DTypeSig false "rewriteBindSection" (TyFun (TyCon "Oracle") (TyFun (TyCon "Section") (TyCon "Section"))))
(DFunDef false "rewriteBindSection" (PWild (PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteBindSection" ((PVar "orc") (PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindSection" ((PVar "orc") (PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteBindInterp" (TyFun (TyCon "Oracle") (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "rewriteBindInterp" (PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteBindInterp" ((PVar "orc") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindGuardArm" (TyFun (TyCon "Oracle") (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "rewriteBindGuardArm" ((PVar "orc") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindGuard") (EVar "orc"))) (EVar "gs"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DTypeSig false "rewriteBindField" (TyFun (TyCon "Oracle") (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "rewriteBindField" ((PVar "orc") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindKv" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "rewriteBindKv" ((PVar "orc") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "k")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "v"))))
(DTypeSig false "sectionSymOps" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "sectionSymOps" () (EListLit (ELit (LString "+")) (ELit (LString "*")) (ELit (LString "/")) (ELit (LString "==")) (ELit (LString "!=")) (ELit (LString "<")) (ELit (LString ">")) (ELit (LString "<=")) (ELit (LString ">=")) (ELit (LString "&&")) (ELit (LString "||")) (ELit (LString "::")) (ELit (LString "++")) (ELit (LString "|>")) (ELit (LString ">>")) (ELit (LString "<<"))))
(DTypeSig false "rightSectionOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "rightSectionOp" ((PVar "op")) (EApp (EApp (EVar "contains") (EVar "op")) (EVar "sectionSymOps")))
(DTypeSig false "leftSectionOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "leftSectionOp" ((PVar "op")) (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EApp (EApp (EVar "contains") (EVar "op")) (EVar "sectionSymOps"))))
(DTypeSig false "bareSectionOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "bareSectionOp" ((PVar "op")) (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EApp (EApp (EVar "contains") (EVar "op")) (EVar "sectionSymOps"))))
(DTypeSig false "isEVarNamed" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isEVarNamed" ((PVar "x") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "w")) () (EBinOp "==" (EVar "w") (EVar "x"))) (arm PWild () (EVar "False"))))
(DTypeSig false "mentionsVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "mentionsVar" ((PVar "x") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "w")) () (EBinOp "==" (EVar "w") (EVar "x"))) (arm (PVar "e2") () (EApp (EApp (EVar "anyList") (EApp (EVar "mentionsVar") (EVar "x"))) (EApp (EVar "childExprs") (EVar "e2"))))))
(DTypeSig false "lamSection" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Section")))))
(DFunDef false "lamSection" ((PList (PCon "PVar" (PVar "x") PWild)) (PVar "body")) (EApp (EApp (EVar "lamSection1") (EVar "x")) (EApp (EVar "unwrapLoc") (EVar "body"))))
(DFunDef false "lamSection" ((PList (PCon "PVar" (PVar "x") PWild) (PCon "PVar" (PVar "y") PWild)) (PVar "body")) (EIf (EBinOp "!=" (EVar "x") (EVar "y")) (EApp (EApp (EApp (EVar "lamSection2") (EVar "x")) (EVar "y")) (EApp (EVar "unwrapLoc") (EVar "body"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "lamSection" (PWild PWild) (EVar "None"))
(DTypeSig false "lamSection1" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Section")))))
(DFunDef false "lamSection1" ((PVar "x") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "a")) (EApp (EVar "rightSectionOp") (EVar "op"))) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "x")) (EVar "b")))) (EApp (EVar "Some") (EApp (EApp (EVar "SecRight") (EVar "op")) (EVar "b"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "b")) (EApp (EVar "leftSectionOp") (EVar "op"))) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "x")) (EVar "a")))) (EApp (EVar "Some") (EApp (EApp (EVar "SecLeft") (EVar "a")) (EVar "op"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "lamSection1" (PWild PWild) (EVar "None"))
(DTypeSig false "lamSection2" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Section"))))))
(DFunDef false "lamSection2" ((PVar "x") (PVar "y") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "a")) (EApp (EApp (EVar "isEVarNamed") (EVar "y")) (EVar "b"))) (EApp (EVar "bareSectionOp") (EVar "op"))) (EApp (EVar "Some") (EApp (EVar "SecBare") (EVar "op"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "lamSection2" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "ruleLambdaSection" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleLambdaSection" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "lambdaSectionDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "lambdaSectionDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "lambdaSectionDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "map") (EApp (EVar "lambdaSectionFinding") (EVar "loc"))) (EApp (EVar "declLamSections") (EVar "d"))))
(DTypeSig false "declLamSections" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "declLamSections" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "collectLamSections") (EVar "body")))
(DFunDef false "declLamSections" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "implMethodLamSections")) (EVar "methods")))
(DFunDef false "declLamSections" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declLamSections") (EVar "d")))
(DFunDef false "declLamSections" (PWild) (EListLit))
(DTypeSig false "implMethodLamSections" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "implMethodLamSections" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectLamSections") (EVar "body")))
(DTypeSig false "collectLamSections" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "collectLamSections" ((PVar "e")) (EBinOp "++" (EApp (EVar "lamHitOf") (EVar "e")) (EApp (EApp (EVar "flatMap") (EVar "collectLamSections")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "lamHitOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "lamHitOf" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EVar "optSectionToList") (EApp (EApp (EVar "lamSection") (EVar "pats")) (EVar "body"))))
(DFunDef false "lamHitOf" (PWild) (EListLit))
(DTypeSig false "optSectionToList" (TyFun (TyApp (TyCon "Option") (TyCon "Section")) (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "optSectionToList" ((PCon "Some" (PVar "s"))) (EListLit (EVar "s")))
(DFunDef false "optSectionToList" ((PCon "None")) (EListLit))
(DTypeSig false "lambdaSectionFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Section") (TyCon "Finding"))))
(DFunDef false "lambdaSectionFinding" ((PVar "loc") (PVar "s")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameLambdaSection")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "lambda is a single binary operation on its parameter(s). Rewrite as the operator section '")) (EApp (EVar "exprToString") (EApp (EVar "ESection") (EVar "s")))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "lambdaSectionFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lambdaSectionFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteLamExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2"))))))))
(DFunDef false "lambdaSectionFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "lambdaSectionFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "lambdaSectionFix" (PWild (PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EVar "map") (EVar "fixImplMethod")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (ERecordCreate "DImpl" ((fa "pub" (EVar "pub")) (fa "iface" (EVar "iface")) (fa "tys" (EVar "tys")) (fa "reqs" (EVar "reqs")) (fa "methods" (EVar "methods2"))))))))))
(DFunDef false "lambdaSectionFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethod" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethod" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "implMethodsBodyKey" (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "String")))
(DFunDef false "implMethodsBodyKey" ((PVar "ms")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "implMethodBodySexp")) (EVar "ms"))))
(DTypeSig false "implMethodBodySexp" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodBodySexp" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "exprSexp") (EVar "body")))
(DTypeSig false "tryLamSection" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "tryLamSection" ((PVar "ps") (PVar "b")) (EMatch (EApp (EApp (EVar "lamSection") (EVar "ps")) (EVar "b")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "ESection") (EVar "s"))) (arm (PCon "None") () (EApp (EApp (EVar "ELam") (EVar "ps")) (EVar "b")))))
(DTypeSig false "rewriteLamExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteLamExpr" ((PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamExpr" ((PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamExpr" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EVar "rewriteLamExpr") (EVar "f"))) (EApp (EVar "rewriteLamExpr") (EVar "x"))))
(DFunDef false "rewriteLamExpr" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "tryLamSection") (EVar "ps")) (EApp (EVar "rewriteLamExpr") (EVar "b"))))
(DFunDef false "rewriteLamExpr" ((PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e1"))) (EApp (EVar "rewriteLamExpr") (EVar "e2"))))
(DFunDef false "rewriteLamExpr" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "rewriteLamExpr") (EVar "s"))) (EApp (EApp (EVar "map") (EVar "rewriteLamArm")) (EVar "arms"))))
(DFunDef false "rewriteLamExpr" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EVar "rewriteLamExpr") (EVar "c"))) (EApp (EVar "rewriteLamExpr") (EVar "t"))) (EApp (EVar "rewriteLamExpr") (EVar "el"))))
(DFunDef false "rewriteLamExpr" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EApp (EVar "rewriteLamExpr") (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EApp (EVar "rewriteLamExpr") (EVar "b"))))
(DFunDef false "rewriteLamExpr" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "rewriteLamExpr") (EVar "lo"))) (EApp (EVar "rewriteLamExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteLamExpr" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "rewriteLamExpr") (EVar "lo"))) (EApp (EVar "rewriteLamExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteLamExpr" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EApp (EVar "rewriteLamExpr") (EVar "lo"))) (EApp (EVar "rewriteLamExpr") (EVar "hi"))) (EVar "i")) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EVar "rewriteLamLet")) (EVar "binds"))) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DFunDef false "rewriteLamExpr" ((PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EVar "rewriteLamSection") (EVar "s"))))
(DFunDef false "rewriteLamExpr" ((PCon "EIndex" (PVar "a") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EApp (EVar "rewriteLamExpr") (EVar "i"))) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteLamExpr" ((PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteLamExpr" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "map") (EVar "rewriteLamStmt")) (EVar "stmts"))))
(DFunDef false "rewriteLamExpr" ((PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EVar "map") (EVar "rewriteLamStmt")) (EVar "stmts"))))
(DFunDef false "rewriteLamExpr" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EVar "rewriteLamInterp")) (EVar "parts"))))
(DFunDef false "rewriteLamExpr" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EVar "rewriteLamGuardArm")) (EVar "arms"))))
(DFunDef false "rewriteLamExpr" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteLamField")) (EVar "fs"))))
(DFunDef false "rewriteLamExpr" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EApp (EApp (EVar "map") (EVar "rewriteLamField")) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EApp (EApp (EVar "map") (EVar "rewriteLamField")) (EVar "fs"))))
(DFunDef false "rewriteLamExpr" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteLamKv")) (EVar "kvs"))))
(DFunDef false "rewriteLamExpr" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamExpr" ((PVar "e")) (EVar "e"))
(DTypeSig false "rewriteLamStmt" (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))
(DFunDef false "rewriteLamStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamStmt" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamStmt" ((PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamArm" (TyFun (TyCon "Arm") (TyCon "Arm")))
(DFunDef false "rewriteLamArm" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EVar "map") (EVar "rewriteLamGuard")) (EVar "gs"))) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "rewriteLamGuard" (TyFun (TyCon "Guard") (TyCon "Guard")))
(DFunDef false "rewriteLamGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamLet" (TyFun (TyCon "LetBind") (TyCon "LetBind")))
(DFunDef false "rewriteLamLet" ((PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteLamClause")) (EVar "clauses"))))
(DTypeSig false "rewriteLamClause" (TyFun (TyCon "FunClause") (TyCon "FunClause")))
(DFunDef false "rewriteLamClause" ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "rewriteLamSection" (TyFun (TyCon "Section") (TyCon "Section")))
(DFunDef false "rewriteLamSection" ((PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteLamSection" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamSection" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteLamInterp" (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))
(DFunDef false "rewriteLamInterp" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteLamInterp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamGuardArm" (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))
(DFunDef false "rewriteLamGuardArm" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EVar "map") (EVar "rewriteLamGuard")) (EVar "gs"))) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "rewriteLamField" (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))
(DFunDef false "rewriteLamField" ((PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamKv" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteLamKv" ((PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EVar "rewriteLamExpr") (EVar "k")) (EApp (EVar "rewriteLamExpr") (EVar "v"))))
(DTypeSig false "ifMaxMinCompareOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "ifMaxMinCompareOp" ((PVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (EBinOp "==" (EVar "op") (ELit (LString "<")))) (EBinOp "==" (EVar "op") (ELit (LString "<=")))))
(DTypeSig false "ifMaxMinFnNormal" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifMaxMinFnNormal" ((PVar "op")) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (ELit (LString "max")) (EIf (EVar "otherwise") (ELit (LString "min")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifMaxMinFnReversed" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifMaxMinFnReversed" ((PVar "op")) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (ELit (LString "min")) (EIf (EVar "otherwise") (ELit (LString "max")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isLiteralExpr" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isLiteralExpr" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" PWild) () (EVar "True")) (arm (PCon "ENumLit" PWild PWild PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "ifMaxMinOf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "ifMaxMinOf" ((PVar "cond") (PVar "t") (PVar "el")) (EMatch (EApp (EVar "unwrapLoc") (EVar "cond")) (arm (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild) ((GBool (EApp (EVar "ifMaxMinCompareOp") (EVar "op")))) (EBlock (DoLet false false (PVar "aK") (EApp (EVar "exprSexp") (EVar "a"))) (DoLet false false (PVar "bK") (EApp (EVar "exprSexp") (EVar "b"))) (DoLet false false (PVar "tK") (EApp (EVar "exprSexp") (EVar "t"))) (DoLet false false (PVar "eK") (EApp (EVar "exprSexp") (EVar "el"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "aK") (EVar "bK")) (EApp (EVar "isLiteralExpr") (EVar "a"))) (EApp (EVar "isLiteralExpr") (EVar "b"))) (EVar "None") (EIf (EBinOp "&&" (EBinOp "==" (EVar "tK") (EVar "aK")) (EBinOp "==" (EVar "eK") (EVar "bK"))) (EApp (EVar "Some") (ETuple (EApp (EVar "ifMaxMinFnNormal") (EVar "op")) (EVar "a") (EVar "b"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "tK") (EVar "bK")) (EBinOp "==" (EVar "eK") (EVar "aK"))) (EApp (EVar "Some") (ETuple (EApp (EVar "ifMaxMinFnReversed") (EVar "op")) (EVar "a") (EVar "b"))) (EVar "None"))))))) (arm PWild () (EVar "None"))))
(DTypeSig false "ruleIfMaxMin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleIfMaxMin" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ifMaxMinDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "ifMaxMinDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "ifMaxMinDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "map") (EApp (EVar "ifMaxMinFinding") (EVar "loc"))) (EApp (EVar "declIfMaxMinHits") (EVar "d"))))
(DTypeSig false "declIfMaxMinHits" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "declIfMaxMinHits" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "collectIfMaxMinHits") (EVar "body")))
(DFunDef false "declIfMaxMinHits" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "implMethodIfMaxMinHits")) (EVar "methods")))
(DFunDef false "declIfMaxMinHits" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declIfMaxMinHits") (EVar "d")))
(DFunDef false "declIfMaxMinHits" (PWild) (EListLit))
(DTypeSig false "implMethodIfMaxMinHits" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "implMethodIfMaxMinHits" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectIfMaxMinHits") (EVar "body")))
(DTypeSig false "collectIfMaxMinHits" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "collectIfMaxMinHits" ((PVar "e")) (EBinOp "++" (EApp (EVar "ifMaxMinHitOf") (EVar "e")) (EApp (EApp (EVar "flatMap") (EVar "collectIfMaxMinHits")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "ifMaxMinHitOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "ifMaxMinHitOf" ((PCon "EIf" (PVar "cond") (PVar "t") (PVar "el"))) (EApp (EVar "optHitToList") (EApp (EApp (EApp (EVar "ifMaxMinOf") (EVar "cond")) (EVar "t")) (EVar "el"))))
(DFunDef false "ifMaxMinHitOf" (PWild) (EListLit))
(DTypeSig false "optHitToList" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "optHitToList" ((PCon "Some" (PVar "h"))) (EListLit (EVar "h")))
(DFunDef false "optHitToList" ((PCon "None")) (EListLit))
(DTypeSig false "ifMaxMinFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")) (TyCon "Finding"))))
(DFunDef false "ifMaxMinFinding" ((PVar "loc") (PTuple (PVar "fn") (PVar "a") (PVar "b"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameIfMaxMin")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if-then-else selects the ")) (EApp (EVar "display") (EIf (EBinOp "==" (EVar "fn") (ELit (LString "max"))) (ELit (LString "larger")) (ELit (LString "smaller"))))) (ELit (LString " of the same two operands. Rewrite as '"))) (EApp (EVar "display") (EApp (EVar "exprToString") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b"))))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "ifMaxMinFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "ifMaxMinFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2"))))))))
(DFunDef false "ifMaxMinFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "ifMaxMinFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "ifMaxMinFix" (PWild (PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EVar "map") (EVar "fixImplMethodIfMaxMin")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (ERecordCreate "DImpl" ((fa "pub" (EVar "pub")) (fa "iface" (EVar "iface")) (fa "tys" (EVar "tys")) (fa "reqs" (EVar "reqs")) (fa "methods" (EVar "methods2"))))))))))
(DFunDef false "ifMaxMinFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodIfMaxMin" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethodIfMaxMin" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "tryIfMaxMin" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "tryIfMaxMin" ((PVar "cond") (PVar "t") (PVar "el")) (EMatch (EApp (EApp (EApp (EVar "ifMaxMinOf") (EVar "cond")) (EVar "t")) (EVar "el")) (arm (PCon "Some" (PTuple (PVar "fn") (PVar "a") (PVar "b"))) () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "EIf") (EVar "cond")) (EVar "t")) (EVar "el")))))
(DTypeSig false "rewriteIfMaxMinExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "f"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "x"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "b"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e1"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e2"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "s"))) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinArm")) (EVar "arms"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "tryIfMaxMin") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "c"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "t"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "el"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "b"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "lo"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "lo"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "lo"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "hi"))) (EVar "i")) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinLet")) (EVar "binds"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EVar "rewriteIfMaxMinSection") (EVar "s"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EIndex" (PVar "a") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "i"))) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinStmt")) (EVar "stmts"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinStmt")) (EVar "stmts"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinInterp")) (EVar "parts"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinGuardArm")) (EVar "arms"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinField")) (EVar "fs"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinField")) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinField")) (EVar "fs"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinKv")) (EVar "kvs"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PVar "e")) (EVar "e"))
(DTypeSig false "rewriteIfMaxMinStmt" (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinArm" (TyFun (TyCon "Arm") (TyCon "Arm")))
(DFunDef false "rewriteIfMaxMinArm" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinGuard")) (EVar "gs"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "rewriteIfMaxMinGuard" (TyFun (TyCon "Guard") (TyCon "Guard")))
(DFunDef false "rewriteIfMaxMinGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinLet" (TyFun (TyCon "LetBind") (TyCon "LetBind")))
(DFunDef false "rewriteIfMaxMinLet" ((PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinClause")) (EVar "clauses"))))
(DTypeSig false "rewriteIfMaxMinClause" (TyFun (TyCon "FunClause") (TyCon "FunClause")))
(DFunDef false "rewriteIfMaxMinClause" ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "rewriteIfMaxMinSection" (TyFun (TyCon "Section") (TyCon "Section")))
(DFunDef false "rewriteIfMaxMinSection" ((PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteIfMaxMinSection" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinSection" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteIfMaxMinInterp" (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))
(DFunDef false "rewriteIfMaxMinInterp" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteIfMaxMinInterp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinGuardArm" (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))
(DFunDef false "rewriteIfMaxMinGuardArm" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinGuard")) (EVar "gs"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "rewriteIfMaxMinField" (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))
(DFunDef false "rewriteIfMaxMinField" ((PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinKv" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteIfMaxMinKv" ((PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EVar "rewriteIfMaxMinExpr") (EVar "k")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "v"))))
(DTypeSig false "countVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Int"))))
(DFunDef false "countVar" ((PVar "x") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "w")) () (EIf (EBinOp "==" (EVar "w") (EVar "x")) (ELit (LInt 1)) (ELit (LInt 0)))) (arm (PVar "e2") () (EApp (EApp (EVar "countVarList") (EVar "x")) (EApp (EVar "childExprs") (EVar "e2"))))))
(DTypeSig false "countVarList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Int"))))
(DFunDef false "countVarList" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "countVarList" ((PVar "x") (PCons (PVar "e") (PVar "es"))) (EBinOp "+" (EApp (EApp (EVar "countVar") (EVar "x")) (EVar "e")) (EApp (EApp (EVar "countVarList") (EVar "x")) (EVar "es"))))
(DTypeSig false "andThenEtaFn" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "andThenEtaFn" ((PVar "x") (PVar "arg")) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg")) (arm (PCon "EApp" (PVar "f") (PVar "lastArg")) ((GBool (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "lastArg")) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "x")) (EVar "f")))))) (EApp (EVar "Some") (EVar "f"))) (arm PWild () (EVar "None"))))
(DTypeSig false "buildAndThenMap" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "buildAndThenMap" ((PVar "x") (PVar "arg") (PVar "m")) (EMatch (EApp (EApp (EVar "andThenEtaFn") (EVar "x")) (EVar "arg")) (arm (PCon "Some" (PVar "f")) () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "map")))) (EVar "f"))) (EVar "m"))) (arm (PCon "None") () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "map")))) (EApp (EApp (EVar "ELam") (EListLit (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))) (EVar "arg")))) (EVar "m")))))
(DTypeSig false "andThenPureMapOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "andThenPureMapOf" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "inner") (PVar "cont")) () (EApp (EApp (EVar "andThenPureMapApp") (EApp (EVar "unwrapLoc") (EVar "inner"))) (EVar "cont"))) (arm PWild () (EVar "None"))))
(DTypeSig false "andThenPureMapApp" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "andThenPureMapApp" ((PCon "EApp" (PVar "hd") (PVar "m")) (PVar "cont")) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "andThen"))) (EVar "hd")) (EApp (EApp (EVar "andThenPureMapCont") (EVar "m")) (EApp (EVar "unwrapLoc") (EVar "cont"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "andThenPureMapApp" (PWild PWild) (EVar "None"))
(DTypeSig false "andThenPureMapCont" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "andThenPureMapCont" ((PVar "m") (PCon "ELam" (PList (PCon "PVar" (PVar "x") PWild)) (PVar "body"))) (EApp (EApp (EApp (EVar "andThenPureMapBody") (EVar "m")) (EVar "x")) (EApp (EVar "unwrapLoc") (EVar "body"))))
(DFunDef false "andThenPureMapCont" (PWild PWild) (EVar "None"))
(DTypeSig false "andThenPureMapBody" (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "andThenPureMapBody" ((PVar "m") (PVar "x") (PCon "EApp" (PVar "pureHd") (PVar "arg"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (ELit (LString "pure"))) (EVar "pureHd")) (EBinOp "<=" (EApp (EApp (EVar "countVar") (EVar "x")) (EVar "arg")) (ELit (LInt 1)))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "buildAndThenMap") (EVar "x")) (EVar "arg")) (EVar "m"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "andThenPureMapBody" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "ruleAndThenPureMap" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleAndThenPureMap" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "andThenPureMapDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "andThenPureMapDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "andThenPureMapDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "map") (EApp (EVar "andThenPureMapFinding") (EVar "loc"))) (EApp (EVar "declAndThenPureMapHits") (EVar "d"))))
(DTypeSig false "declAndThenPureMapHits" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "declAndThenPureMapHits" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "collectAndThenPureMapHits") (EVar "body")))
(DFunDef false "declAndThenPureMapHits" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "implMethodAndThenPureMapHits")) (EVar "methods")))
(DFunDef false "declAndThenPureMapHits" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declAndThenPureMapHits") (EVar "d")))
(DFunDef false "declAndThenPureMapHits" (PWild) (EListLit))
(DTypeSig false "implMethodAndThenPureMapHits" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "implMethodAndThenPureMapHits" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectAndThenPureMapHits") (EVar "body")))
(DTypeSig false "collectAndThenPureMapHits" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "collectAndThenPureMapHits" ((PVar "e")) (EBinOp "++" (EApp (EVar "andThenPureMapHitOf") (EVar "e")) (EApp (EApp (EVar "flatMap") (EVar "collectAndThenPureMapHits")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "andThenPureMapHitOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "andThenPureMapHitOf" ((PCon "EApp" (PVar "inner") (PVar "cont"))) (EApp (EVar "optExprToList") (EApp (EVar "andThenPureMapOf") (EApp (EApp (EVar "EApp") (EVar "inner")) (EVar "cont")))))
(DFunDef false "andThenPureMapHitOf" (PWild) (EListLit))
(DTypeSig false "optExprToList" (TyFun (TyApp (TyCon "Option") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "optExprToList" ((PCon "Some" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "optExprToList" ((PCon "None")) (EListLit))
(DTypeSig false "andThenPureMapFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "andThenPureMapFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameAndThenPureMap")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "monadic bind wraps a pure transformation of its result — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "andThenPureMapFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "andThenPureMapFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2"))))))))
(DFunDef false "andThenPureMapFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "andThenPureMapFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "andThenPureMapFix" (PWild (PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EVar "map") (EVar "fixImplMethodAndThenPureMap")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (ERecordCreate "DImpl" ((fa "pub" (EVar "pub")) (fa "iface" (EVar "iface")) (fa "tys" (EVar "tys")) (fa "reqs" (EVar "reqs")) (fa "methods" (EVar "methods2"))))))))))
(DFunDef false "andThenPureMapFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodAndThenPureMap" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethodAndThenPureMap" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "tryAndThenPureMap" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "tryAndThenPureMap" ((PVar "e")) (EMatch (EApp (EVar "andThenPureMapOf") (EVar "e")) (arm (PCon "Some" (PVar "rewritten")) () (EVar "rewritten")) (arm (PCon "None") () (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "tryAndThenPureMap") (EApp (EApp (EVar "EApp") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "f"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "x")))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "b"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e1"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e2"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "s"))) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapArm")) (EVar "arms"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "c"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "t"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "el"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "b"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "lo"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "lo"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "lo"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "hi"))) (EVar "i")) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapLet")) (EVar "binds"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EVar "rewriteAndThenPureMapSection") (EVar "s"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EIndex" (PVar "a") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "i"))) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapStmt")) (EVar "stmts"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapStmt")) (EVar "stmts"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapInterp")) (EVar "parts"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapGuardArm")) (EVar "arms"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapField")) (EVar "fs"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapField")) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapField")) (EVar "fs"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapKv")) (EVar "kvs"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PVar "e")) (EVar "e"))
(DTypeSig false "rewriteAndThenPureMapStmt" (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapArm" (TyFun (TyCon "Arm") (TyCon "Arm")))
(DFunDef false "rewriteAndThenPureMapArm" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapGuard")) (EVar "gs"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "rewriteAndThenPureMapGuard" (TyFun (TyCon "Guard") (TyCon "Guard")))
(DFunDef false "rewriteAndThenPureMapGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapLet" (TyFun (TyCon "LetBind") (TyCon "LetBind")))
(DFunDef false "rewriteAndThenPureMapLet" ((PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapClause")) (EVar "clauses"))))
(DTypeSig false "rewriteAndThenPureMapClause" (TyFun (TyCon "FunClause") (TyCon "FunClause")))
(DFunDef false "rewriteAndThenPureMapClause" ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "rewriteAndThenPureMapSection" (TyFun (TyCon "Section") (TyCon "Section")))
(DFunDef false "rewriteAndThenPureMapSection" ((PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteAndThenPureMapSection" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapSection" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteAndThenPureMapInterp" (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))
(DFunDef false "rewriteAndThenPureMapInterp" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteAndThenPureMapInterp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapGuardArm" (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))
(DFunDef false "rewriteAndThenPureMapGuardArm" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapGuard")) (EVar "gs"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "rewriteAndThenPureMapField" (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))
(DFunDef false "rewriteAndThenPureMapField" ((PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapKv" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteAndThenPureMapKv" ((PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "k")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "v"))))
(DTypeSig false "mapChildExprs" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EVar "g") (EVar "f"))) (EApp (EVar "g") (EVar "x"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EVar "g") (EVar "b"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EVar "g") (EVar "e1"))) (EApp (EVar "g") (EVar "e2"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "g") (EVar "s"))) (EApp (EApp (EVar "map") (EApp (EVar "mapChildArm") (EVar "g"))) (EVar "arms"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EVar "g") (EVar "c"))) (EApp (EVar "g") (EVar "t"))) (EApp (EVar "g") (EVar "el"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "g") (EVar "a"))) (EApp (EVar "g") (EVar "b"))) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "g") (EVar "a"))) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "g") (EVar "a"))) (EApp (EVar "g") (EVar "b"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "g") (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "i")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "i")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "g") (EVar "e"))) (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "i")) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EApp (EVar "mapChildLet") (EVar "g"))) (EVar "binds"))) (EApp (EVar "g") (EVar "body"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EApp (EVar "mapChildSection") (EVar "g")) (EVar "s"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EIndex" (PVar "a") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EVar "g") (EVar "a"))) (EApp (EVar "g") (EVar "i"))) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "g") (EVar "e"))) (EVar "t")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "g") (EVar "e"))) (EVar "t")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "map") (EApp (EVar "mapChildStmt") (EVar "g"))) (EVar "stmts"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EVar "map") (EApp (EVar "mapChildStmt") (EVar "g"))) (EVar "stmts"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EApp (EVar "mapChildInterp") (EVar "g"))) (EVar "parts"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EApp (EVar "mapChildGuardArm") (EVar "g"))) (EVar "arms"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "mapChildField") (EVar "g"))) (EVar "fs"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "g") (EVar "e"))) (EApp (EApp (EVar "map") (EApp (EVar "mapChildField") (EVar "g"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "g") (EVar "e"))) (EApp (EApp (EVar "map") (EApp (EVar "mapChildField") (EVar "g"))) (EVar "fs"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "mapChildKv") (EVar "g"))) (EVar "kvs"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildExprs" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "mapChildStmt" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "mapChildStmt" ((PVar "g") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildStmt" ((PVar "g") (PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildStmt" ((PVar "g") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildStmt" ((PVar "g") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildStmt" ((PVar "g") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapChildArm" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "mapChildArm" ((PVar "g") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EVar "map") (EApp (EVar "mapChildGuard") (EVar "g"))) (EVar "gs"))) (EApp (EVar "g") (EVar "body"))))
(DTypeSig false "mapChildGuard" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Guard") (TyCon "Guard"))))
(DFunDef false "mapChildGuard" ((PVar "g") (PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildGuard" ((PVar "g") (PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapChildLet" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "mapChildLet" ((PVar "g") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "mapChildClause") (EVar "g"))) (EVar "clauses"))))
(DTypeSig false "mapChildClause" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "mapChildClause" ((PVar "g") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "g") (EVar "body"))))
(DTypeSig false "mapChildSection" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Section") (TyCon "Section"))))
(DFunDef false "mapChildSection" (PWild (PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "mapChildSection" ((PVar "g") (PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildSection" ((PVar "g") (PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "g") (EVar "e"))) (EVar "op")))
(DTypeSig false "mapChildInterp" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "mapChildInterp" (PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "mapChildInterp" ((PVar "g") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapChildGuardArm" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "mapChildGuardArm" ((PVar "g") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EVar "map") (EApp (EVar "mapChildGuard") (EVar "g"))) (EVar "gs"))) (EApp (EVar "g") (EVar "body"))))
(DTypeSig false "mapChildField" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "mapChildField" ((PVar "g") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapChildKv" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "mapChildKv" ((PVar "g") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EVar "g") (EVar "k")) (EApp (EVar "g") (EVar "v"))))
(DTypeSig false "rewriteExprBU" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteExprBU" ((PVar "f") (PVar "e")) (EApp (EVar "f") (EApp (EApp (EVar "mapChildExprs") (EApp (EVar "rewriteExprBU") (EVar "f"))) (EVar "e"))))
(DTypeSig false "detApply" (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "detApply" ((PVar "det") (PVar "e")) (EMatch (EApp (EVar "det") (EVar "e")) (arm (PCon "Some" (PVar "e2")) () (EVar "e2")) (arm (PCon "None") () (EVar "e"))))
(DTypeSig false "exprRuleFindings" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))) (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "exprRuleFindings" ((PVar "excl") (PVar "det") (PVar "mkFinding") (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "exprRuleDeclL") (EVar "excl")) (EVar "det")) (EVar "mkFinding"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "exprRuleDeclL" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))) (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "exprRuleDeclL" ((PVar "excl") (PVar "det") (PVar "mkFinding") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "hitLoc") (PVar "hit"))) (EApp (EApp (EVar "mkFinding") (EVar "hitLoc")) (EVar "hit")))) (EApp (EApp (EApp (EApp (EVar "declRewriteHits") (EVar "excl")) (EVar "det")) (EVar "loc")) (EVar "d"))))
(DTypeSig false "declRewriteHits" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr"))))))))
(DFunDef false "declRewriteHits" ((PVar "excl") (PVar "det") (PVar "loc") (PCon "DFunDef" PWild (PVar "name") PWild (PVar "body"))) (EIf (EApp (EVar "excl") (EVar "name")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "collectRewrites") (EVar "loc")) (EVar "det")) (EVar "body")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "declRewriteHits" (PWild (PVar "det") (PVar "loc") (PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "implMethodRewriteHits") (EVar "loc")) (EVar "det"))) (EVar "methods")))
(DFunDef false "declRewriteHits" ((PVar "excl") (PVar "det") (PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "declRewriteHits") (EVar "excl")) (EVar "det")) (EVar "loc")) (EVar "d")))
(DFunDef false "declRewriteHits" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "implMethodRewriteHits" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr")))))))
(DFunDef false "implMethodRewriteHits" ((PVar "loc") (PVar "det") (PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EApp (EApp (EVar "collectRewrites") (EVar "loc")) (EVar "det")) (EVar "body")))
(DTypeSig false "collectRewrites" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr")))))))
(DFunDef false "collectRewrites" (PWild (PVar "det") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EVar "collectRewrites") (EApp (EVar "Some") (EVar "l"))) (EVar "det")) (EVar "e")))
(DFunDef false "collectRewrites" ((PVar "curLoc") (PVar "det") (PVar "e")) (EBinOp "++" (EApp (EApp (EVar "optExprToLocList") (EVar "curLoc")) (EApp (EVar "det") (EVar "e"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "collectRewrites") (EVar "curLoc")) (EVar "det"))) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "optExprToLocList" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Expr")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr"))))))
(DFunDef false "optExprToLocList" (PWild (PCon "None")) (EListLit))
(DFunDef false "optExprToLocList" ((PVar "loc") (PCon "Some" (PVar "x"))) (EListLit (ETuple (EVar "loc") (EVar "x"))))
(DTypeSig false "exprRuleFix" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "exprRuleFix" ((PVar "excl") (PVar "f") (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EIf (EApp (EVar "excl") (EVar "name")) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "body2") (EApp (EApp (EVar "rewriteExprBU") (EVar "f")) (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "exprRuleFix" ((PVar "excl") (PVar "f") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "excl")) (EVar "f")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "exprRuleFix" (PWild (PVar "f") (PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EVar "map") (EApp (EVar "fixImplMethodWith") (EVar "f"))) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (ERecordCreate "DImpl" ((fa "pub" (EVar "pub")) (fa "iface" (EVar "iface")) (fa "tys" (EVar "tys")) (fa "reqs" (EVar "reqs")) (fa "methods" (EVar "methods2"))))))))))
(DFunDef false "exprRuleFix" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodWith" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))
(DFunDef false "fixImplMethodWith" ((PVar "f") (PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EApp (EVar "rewriteExprBU") (EVar "f")) (EVar "body"))))
(DTypeSig false "noExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "noExcl" (PWild) (EVar "False"))
(DTypeSig false "notArgOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "notArgOf" ((PCon "EApp" (PVar "hd") (PVar "x"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "not"))) (EVar "hd")) (EApp (EVar "Some") (EVar "x")) (EVar "None")))
(DFunDef false "notArgOf" ((PCon "EUnOp" (PLit (LString "!")) (PVar "x") PWild)) (EApp (EVar "Some") (EVar "x")))
(DFunDef false "notArgOf" (PWild) (EVar "None"))
(DTypeSig false "mkNot" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "mkNot" ((PVar "e")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "not")))) (EVar "e")))
(DTypeSig false "isTrueLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isTrueLit" ((PVar "e")) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "True"))) (EVar "e")))
(DTypeSig false "isFalseLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isFalseLit" ((PVar "e")) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "False"))) (EVar "e")))
(DTypeSig false "isBoolLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isBoolLit" ((PVar "e")) (EBinOp "||" (EApp (EVar "isTrueLit") (EVar "e")) (EApp (EVar "isFalseLit") (EVar "e"))))
(DTypeSig false "isIntLit" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isIntLit" ((PVar "k") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" (PCon "LInt" (PVar "n"))) () (EBinOp "==" (EVar "n") (EVar "k"))) (arm (PCon "ENumLit" (PVar "n") PWild PWild PWild) () (EBinOp "==" (EVar "n") (EVar "k"))) (arm PWild () (EVar "False"))))
(DTypeSig false "concatOperands" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "concatOperands" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "l") (PVar "r") PWild) () (EBinOp "++" (EApp (EVar "concatOperands") (EVar "l")) (EListLit (EVar "r")))) (arm PWild () (EListLit (EVar "e")))))
(DTypeSig false "strLitValueOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "strLitValueOf" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" (PCon "LString" (PVar "s"))) () (EApp (EVar "Some") (EVar "s"))) (arm PWild () (EVar "None"))))
(DTypeSig false "isStrLitOperand" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isStrLitOperand" ((PVar "e")) (EMatch (EApp (EVar "strLitValueOf") (EVar "e")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "hasBackslashBrace" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasBackslashBrace" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "backslashBraceGo") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "backslashBraceGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "backslashBraceGo" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\\"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "{")))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "backslashBraceGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "concatChainQualifies" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool")))
(DFunDef false "concatChainQualifies" ((PVar "ops")) (EBlock (DoLet false false (PVar "lits") (EApp (EApp (EVar "filterExprs") (EVar "isStrLitOperand")) (EVar "ops"))) (DoLet false false (PVar "holes") (EApp (EApp (EVar "filterExprs") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isStrLitOperand") (EVar "e"))))) (EVar "ops"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "lits")) (EBinOp ">=" (EApp (EVar "listLen") (EVar "holes")) (ELit (LInt 2)))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EVar "litHasBackslashBrace")) (EVar "lits")))))))
(DTypeSig false "litHasBackslashBrace" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "litHasBackslashBrace" ((PVar "e")) (EMatch (EApp (EVar "strLitValueOf") (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "hasBackslashBrace") (EVar "s"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "filterExprs" (TyFun (TyFun (TyCon "Expr") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "filterExprs" ((PVar "p") (PVar "es")) (EApp (EApp (EVar "filter") (EVar "p")) (EVar "es")))
(DTypeSig false "buildInterpParts" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "InterpPart"))))
(DFunDef false "buildInterpParts" ((PVar "ops")) (EApp (EVar "mergeInterpStr") (EApp (EApp (EVar "map") (EVar "operandToInterp")) (EVar "ops"))))
(DTypeSig false "operandToInterp" (TyFun (TyCon "Expr") (TyCon "InterpPart")))
(DFunDef false "operandToInterp" ((PVar "e")) (EMatch (EApp (EVar "strLitValueOf") (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "InterpStr") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "InterpExpr") (EApp (EVar "rewriteConcatExpr") (EVar "e"))))))
(DTypeSig false "mergeInterpStr" (TyFun (TyApp (TyCon "List") (TyCon "InterpPart")) (TyApp (TyCon "List") (TyCon "InterpPart"))))
(DFunDef false "mergeInterpStr" ((PList)) (EListLit))
(DFunDef false "mergeInterpStr" ((PCons (PCon "InterpStr" (PVar "a")) (PCons (PCon "InterpStr" (PVar "b")) (PVar "rest")))) (EApp (EVar "mergeInterpStr") (EBinOp "::" (EApp (EVar "InterpStr") (EBinOp "++" (EVar "a") (EVar "b"))) (EVar "rest"))))
(DFunDef false "mergeInterpStr" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EVar "p") (EApp (EVar "mergeInterpStr") (EVar "rest"))))
(DTypeSig false "concatChainOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "concatChainOf" ((PCon "EBinOp" (PLit (LString "++")) (PVar "l") (PVar "r") (PVar "rf"))) (EBlock (DoLet false false (PVar "ops") (EApp (EVar "concatOperands") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "++"))) (EVar "l")) (EVar "r")) (EVar "rf")))) (DoExpr (EIf (EApp (EVar "concatChainQualifies") (EVar "ops")) (EApp (EVar "Some") (EApp (EVar "EStringInterp") (EApp (EVar "buildInterpParts") (EVar "ops")))) (EVar "None")))))
(DFunDef false "concatChainOf" (PWild) (EVar "None"))
(DTypeSig false "rewriteConcatExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteConcatExpr" ((PVar "e")) (EMatch (EApp (EVar "concatChainOf") (EVar "e")) (arm (PCon "Some" (PVar "e2")) () (EVar "e2")) (arm (PCon "None") () (EApp (EApp (EVar "mapChildExprs") (EVar "rewriteConcatExpr")) (EVar "e")))))
(DTypeSig false "collectConcatHits" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "collectConcatHits" ((PVar "e")) (EMatch (EApp (EVar "concatChainOf") (EVar "e")) (arm (PCon "Some" (PVar "e2")) () (EBinOp "::" (EVar "e2") (EApp (EApp (EVar "flatMap") (EVar "collectConcatHits")) (EApp (EVar "concatOperands") (EVar "e"))))) (arm (PCon "None") () (EApp (EApp (EVar "flatMap") (EVar "collectConcatHits")) (EApp (EVar "childExprs") (EVar "e"))))))
(DTypeSig false "ruleConcatToInterp" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleConcatToInterp" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "concatToInterpDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "concatToInterpDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "concatToInterpDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "map") (EApp (EVar "concatToInterpFinding") (EVar "loc"))) (EApp (EVar "declConcatHits") (EVar "d"))))
(DTypeSig false "declConcatHits" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "declConcatHits" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "collectConcatHits") (EVar "body")))
(DFunDef false "declConcatHits" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "implMethodConcatHits")) (EVar "methods")))
(DFunDef false "declConcatHits" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declConcatHits") (EVar "d")))
(DFunDef false "declConcatHits" (PWild) (EListLit))
(DTypeSig false "implMethodConcatHits" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "implMethodConcatHits" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectConcatHits") (EVar "body")))
(DTypeSig false "concatToInterpFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "concatToInterpFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameConcatToInterp")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`++` chain of string literals and expressions. Rewrite as an interpolated string '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "concatToInterpFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "concatToInterpFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteConcatExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2"))))))))
(DFunDef false "concatToInterpFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "concatToInterpFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "concatToInterpFix" (PWild (PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EVar "map") (EVar "fixImplMethodConcat")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (ERecordCreate "DImpl" ((fa "pub" (EVar "pub")) (fa "iface" (EVar "iface")) (fa "tys" (EVar "tys")) (fa "reqs" (EVar "reqs")) (fa "methods" (EVar "methods2"))))))))))
(DFunDef false "concatToInterpFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodConcat" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethodConcat" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteConcatExpr") (EVar "body"))))
(DTypeSig false "notEqOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "notEqOf" ((PVar "e")) (EMatch (EApp (EVar "notArgOf") (EVar "e")) (arm (PCon "Some" (PVar "inner")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "inner")) (arm (PCon "EBinOp" (PLit (LString "==")) (PVar "a") (PVar "b") (PVar "r")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "!="))) (EVar "a")) (EVar "b")) (EVar "r")))) (arm (PCon "EBinOp" (PLit (LString "!=")) (PVar "a") (PVar "b") (PVar "r")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "=="))) (EVar "a")) (EVar "b")) (EVar "r")))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "ruleNotEq" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleNotEq" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "noExcl")) (EVar "notEqOf")) (EVar "notEqFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "notEqFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "notEqFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameNotEq")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "negated equality. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "notEqFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "notEqFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "notEqOf"))) (EVar "d")))
(DTypeSig false "boolSimplifyOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "boolSimplifyOf" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "boolSimplifyIf") (EVar "c")) (EApp (EVar "unwrapLoc") (EVar "t"))) (EApp (EVar "unwrapLoc") (EVar "el"))))
(DFunDef false "boolSimplifyOf" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EBinOp "==" (EVar "op") (ELit (LString "!=")))) (EApp (EApp (EApp (EVar "boolSimplifyEq") (EVar "op")) (EVar "a")) (EVar "b")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "boolSimplifyOf" ((PVar "e")) (EMatch (EApp (EVar "notArgOf") (EVar "e")) (arm (PCon "Some" (PVar "inner")) () (EApp (EApp (EVar "map") (ELam ((PVar "y")) (EVar "y"))) (EApp (EVar "notArgOf") (EApp (EVar "unwrapLoc") (EVar "inner"))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "boolSimplifyIf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "boolSimplifyIf" ((PVar "c") (PVar "t") (PVar "el")) (EIf (EBinOp "&&" (EApp (EVar "isTrueLit") (EVar "t")) (EApp (EVar "isFalseLit") (EVar "el"))) (EApp (EVar "Some") (EVar "c")) (EIf (EBinOp "&&" (EApp (EVar "isFalseLit") (EVar "t")) (EApp (EVar "isTrueLit") (EVar "el"))) (EApp (EVar "Some") (EApp (EVar "mkNot") (EVar "c"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "boolSimplifyEq" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "boolSimplifyEq" ((PVar "op") (PVar "a") (PVar "b")) (EIf (EBinOp "&&" (EApp (EVar "isBoolLit") (EVar "a")) (EApp (EVar "isBoolLit") (EVar "b"))) (EVar "None") (EIf (EApp (EVar "isTrueLit") (EVar "b")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "a")) (EVar "True"))) (EIf (EApp (EVar "isFalseLit") (EVar "b")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "a")) (EVar "False"))) (EIf (EApp (EVar "isTrueLit") (EVar "a")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "b")) (EVar "True"))) (EIf (EApp (EVar "isFalseLit") (EVar "a")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "b")) (EVar "False"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "boolEqResult" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyCon "Expr")))))
(DFunDef false "boolEqResult" ((PVar "op") (PVar "v") (PVar "constIsTrue")) (EIf (EBinOp "==" (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EVar "constIsTrue")) (EVar "v") (EApp (EVar "mkNot") (EVar "v"))))
(DTypeSig false "ruleBoolSimplify" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleBoolSimplify" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "noExcl")) (EVar "boolSimplifyOf")) (EVar "boolSimplifyFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "boolSimplifyFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "boolSimplifyFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameBoolSimplify")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "redundant boolean expression — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "boolSimplifyFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "boolSimplifyFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "boolSimplifyOf"))) (EVar "d")))
(DTypeSig false "remParityExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "remParityExcl" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "isEven"))) (EBinOp "==" (EVar "name") (ELit (LString "isOdd")))))
(DTypeSig false "remParityOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "remParityOf" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EBinOp "==" (EVar "op") (ELit (LString "!=")))) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 0))) (EVar "b")) (EApp (EApp (EVar "remParityFrom") (EVar "op")) (EApp (EVar "unwrapLoc") (EVar "a"))) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 0))) (EVar "a")) (EApp (EApp (EVar "remParityFrom") (EVar "op")) (EApp (EVar "unwrapLoc") (EVar "b"))) (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "remParityOf" (PWild) (EVar "None"))
(DTypeSig false "remParityFrom" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "remParityFrom" ((PVar "op") (PCon "EBinOp" (PLit (LString "%")) (PVar "n") (PVar "two") PWild)) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 2))) (EVar "two")) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EApp (EVar "parityFn") (EVar "op")))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "remParityFrom" (PWild PWild) (EVar "None"))
(DTypeSig false "parityFn" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "parityFn" ((PVar "op")) (EIf (EBinOp "==" (EVar "op") (ELit (LString "=="))) (ELit (LString "isEven")) (ELit (LString "isOdd"))))
(DTypeSig false "ruleRemParity" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleRemParity" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "remParityExcl")) (EVar "remParityOf")) (EVar "remParityFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "remParityFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "remParityFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameRemParity")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "parity test. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "remParityFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "remParityFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "remParityExcl")) (EApp (EVar "detApply") (EVar "remParityOf"))) (EVar "d")))
(DTypeSig false "doubleReverseOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "doubleReverseOf" ((PCon "EApp" (PVar "hd1") (PVar "arg1"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd1")) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg1")) (arm (PCon "EApp" (PVar "hd2") (PVar "inner")) () (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd2")) (EApp (EVar "Some") (EVar "inner")) (EVar "None"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "doubleReverseOf" (PWild) (EVar "None"))
(DTypeSig false "ruleDoubleReverse" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleDoubleReverse" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "noExcl")) (EVar "doubleReverseOf")) (EVar "doubleReverseFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "doubleReverseFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "doubleReverseFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDoubleReverse")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`reverse (reverse …)` is a no-op. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "doubleReverseFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "doubleReverseFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "doubleReverseOf"))) (EVar "d")))
(DTypeSig false "whenUnlessExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "whenUnlessExcl" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "when"))) (EBinOp "==" (EVar "name") (ELit (LString "unless")))))
(DTypeSig false "isPureUnit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isPureUnit" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "hd") (PVar "arg")) () (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (ELit (LString "pure"))) (EVar "hd")) (EApp (EVar "isUnitLit") (EApp (EVar "unwrapLoc") (EVar "arg"))))) (arm PWild () (EVar "False"))))
(DTypeSig false "isUnitLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isUnitLit" ((PCon "ELit" (PCon "LUnit"))) (EVar "True"))
(DFunDef false "isUnitLit" (PWild) (EVar "False"))
(DTypeSig false "whenUnlessOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "whenUnlessOf" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EIf (EApp (EVar "isPureUnit") (EVar "el")) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "when")))) (EVar "c"))) (EVar "t"))) (EIf (EApp (EVar "isPureUnit") (EVar "t")) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "unless")))) (EVar "c"))) (EVar "el"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "whenUnlessOf" (PWild) (EVar "None"))
(DTypeSig false "ruleWhenUnless" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleWhenUnless" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "whenUnlessExcl")) (EVar "whenUnlessOf")) (EVar "whenUnlessFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "whenUnlessFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "whenUnlessFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameWhenUnless")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "conditional effect with a `pure ()` branch. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "whenUnlessFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "whenUnlessFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "whenUnlessExcl")) (EApp (EVar "detApply") (EVar "whenUnlessOf"))) (EVar "d")))
(DTypeSig false "complementExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "complementExcl" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "isNonEmptyL"))) (EBinOp "==" (EVar "name") (ELit (LString "isNonEmptyList")))))
(DTypeSig false "complementOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "complementOf" ((PLit (LString "isEmptyL"))) (EApp (EVar "Some") (ELit (LString "isNonEmptyL"))))
(DFunDef false "complementOf" ((PLit (LString "isNonEmptyL"))) (EApp (EVar "Some") (ELit (LString "isEmptyL"))))
(DFunDef false "complementOf" ((PLit (LString "isEmptyList"))) (EApp (EVar "Some") (ELit (LString "isNonEmptyList"))))
(DFunDef false "complementOf" ((PLit (LString "isNonEmptyList"))) (EApp (EVar "Some") (ELit (LString "isEmptyList"))))
(DFunDef false "complementOf" ((PLit (LString "isSome"))) (EApp (EVar "Some") (ELit (LString "isNone"))))
(DFunDef false "complementOf" ((PLit (LString "isNone"))) (EApp (EVar "Some") (ELit (LString "isSome"))))
(DFunDef false "complementOf" ((PLit (LString "isOk"))) (EApp (EVar "Some") (ELit (LString "isErr"))))
(DFunDef false "complementOf" ((PLit (LString "isErr"))) (EApp (EVar "Some") (ELit (LString "isOk"))))
(DFunDef false "complementOf" (PWild) (EVar "None"))
(DTypeSig false "appSpineHead" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "appSpineHead" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "EApp" (PVar "hd") PWild) () (EApp (EVar "appSpineHead") (EApp (EVar "unwrapLoc") (EVar "hd")))) (arm PWild () (EVar "None"))))
(DTypeSig false "renameSpineHead" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "renameSpineHead" ((PVar "newName") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" PWild) () (EApp (EVar "EVar") (EVar "newName"))) (arm (PCon "EApp" (PVar "hd") (PVar "arg")) () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "renameSpineHead") (EVar "newName")) (EVar "hd"))) (EVar "arg"))) (arm PWild () (EVar "e"))))
(DTypeSig false "complementPredOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "complementPredOf" ((PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EVar "notArgOf") (EVar "e"))) (ELam ((PVar "inner")) (EApp (EApp (EVar "andThen") (EApp (EVar "appSpineHead") (EApp (EVar "unwrapLoc") (EVar "inner")))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "complementOf") (EVar "name"))) (ELam ((PVar "comp")) (EApp (EVar "Some") (EApp (EApp (EVar "renameSpineHead") (EVar "comp")) (EApp (EVar "unwrapLoc") (EVar "inner")))))))))))
(DTypeSig false "ruleComplementPredicate" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleComplementPredicate" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "complementExcl")) (EVar "complementPredOf")) (EVar "complementPredicateFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "complementPredicateFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "complementPredicateFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameComplementPredicate")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "negated predicate. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "complementPredicateFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "complementPredicateFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "complementExcl")) (EApp (EVar "detApply") (EVar "complementPredOf"))) (EVar "d")))
(DTypeSig false "isNilPCon" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "isNilPCon" ((PVar "name") (PCon "PCon" (PVar "n") (PList))) (EBinOp "==" (EVar "n") (EVar "name")))
(DFunDef false "isNilPCon" (PWild PWild) (EVar "False"))
(DTypeSig false "matchToMapTransform" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "Pat") (TyCon "Expr")))))))
(DFunDef false "matchToMapTransform" ((PVar "ctor") (PCon "PCon" (PVar "c") (PList (PVar "binder"))) (PVar "body")) (EIf (EBinOp "==" (EVar "c") (EVar "ctor")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EApp" (PVar "hd") (PVar "inner")) () (EIf (EApp (EApp (EVar "isEVarNamed") (EVar "ctor")) (EVar "hd")) (EApp (EVar "Some") (ETuple (EVar "binder") (EVar "inner"))) (EVar "None"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "matchToMapTransform" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "matchToMapErrPassthru" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "matchToMapErrPassthru" ((PCon "PCon" (PLit (LString "Err")) (PList (PCon "PVar" (PVar "v") PWild))) (PVar "body")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EApp" (PVar "hd") (PVar "arg")) () (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (ELit (LString "Err"))) (EVar "hd")) (EApp (EApp (EVar "isEVarNamed") (EVar "v")) (EVar "arg")))) (arm PWild () (EVar "False"))))
(DFunDef false "matchToMapErrPassthru" (PWild PWild) (EVar "False"))
(DTypeSig false "matchToMapFn" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "matchToMapFn" ((PCon "PVar" (PVar "x") (PVar "l")) (PVar "expr")) (EMatch (EApp (EApp (EVar "andThenEtaFn") (EVar "x")) (EVar "expr")) (arm (PCon "Some" (PVar "f")) () (EVar "f")) (arm (PCon "None") () (EApp (EApp (EVar "ELam") (EListLit (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "l")))) (EVar "expr")))))
(DFunDef false "matchToMapFn" ((PVar "binder") (PVar "expr")) (EApp (EApp (EVar "ELam") (EListLit (EVar "binder"))) (EVar "expr")))
(DTypeSig false "matchToMapCall" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "matchToMapCall" ((PVar "binder") (PVar "expr") (PVar "scrut")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "map")))) (EApp (EApp (EVar "matchToMapFn") (EVar "binder")) (EVar "expr")))) (EVar "scrut")))
(DTypeSig false "matchToMapOption" (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "matchToMapOption" ((PVar "scrut") (PCon "Arm" (PVar "pn") (PVar "gn") (PVar "bn")) (PCon "Arm" (PVar "ps") (PVar "gs") (PVar "bs"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "gn")) (EApp (EVar "isEmptyL") (EVar "gs"))) (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "pn"))) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "None"))) (EVar "bn"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "binder") (PVar "expr"))) (EApp (EApp (EApp (EVar "matchToMapCall") (EVar "binder")) (EVar "expr")) (EVar "scrut")))) (EApp (EApp (EApp (EVar "matchToMapTransform") (ELit (LString "Some"))) (EVar "ps")) (EVar "bs"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchToMapResult" (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "matchToMapResult" ((PVar "scrut") (PCon "Arm" (PVar "pe") (PVar "ge") (PVar "be")) (PCon "Arm" (PVar "po") (PVar "go") (PVar "bo"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "ge")) (EApp (EVar "isEmptyL") (EVar "go"))) (EApp (EApp (EVar "matchToMapErrPassthru") (EVar "pe")) (EVar "be"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "binder") (PVar "expr"))) (EApp (EApp (EApp (EVar "matchToMapCall") (EVar "binder")) (EVar "expr")) (EVar "scrut")))) (EApp (EApp (EApp (EVar "matchToMapTransform") (ELit (LString "Ok"))) (EVar "po")) (EVar "bo"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchToMapPair" (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "matchToMapPair" ((PVar "scrut") (PVar "a1") (PVar "a2")) (EMatch (EApp (EApp (EApp (EVar "matchToMapOption") (EVar "scrut")) (EVar "a1")) (EVar "a2")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Some") (EVar "e"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "matchToMapOption") (EVar "scrut")) (EVar "a2")) (EVar "a1")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Some") (EVar "e"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "matchToMapResult") (EVar "scrut")) (EVar "a1")) (EVar "a2")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Some") (EVar "e"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "matchToMapResult") (EVar "scrut")) (EVar "a2")) (EVar "a1")))))))))
(DTypeSig false "matchToMapOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "matchToMapOf" ((PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EMatch (EVar "arms") (arm (PList (PVar "a1") (PVar "a2")) () (EApp (EApp (EApp (EVar "matchToMapPair") (EVar "scrut")) (EVar "a1")) (EVar "a2"))) (arm PWild () (EVar "None"))))
(DFunDef false "matchToMapOf" (PWild) (EVar "None"))
(DTypeSig false "ruleMatchToMap" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleMatchToMap" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "noExcl")) (EVar "matchToMapOf")) (EVar "matchToMapFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "matchToMapFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "matchToMapFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameMatchToMap")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "2-arm match maps over an Option/Result — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "matchToMapFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "matchToMapFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "matchToMapOf"))) (EVar "d")))
(DTypeSig false "bindChainDepth" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyCon "Int"))))
(DFunDef false "bindChainDepth" ((PVar "isResult") (PVar "e")) (EBlock (DoLet false false (PTuple PWild (PVar "core")) (EApp (EVar "bindChainSplit") (EVar "e"))) (DoExpr (EMatch (EApp (EApp (EVar "bindChainHead") (EVar "isResult")) (EVar "core")) (arm (PCon "Some" (PVar "body")) () (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "bindChainDepth") (EVar "isResult")) (EVar "body")))) (arm (PCon "None") () (EIf (EApp (EVar "bindChainIsTermMap") (EVar "core")) (ELit (LInt 1)) (ELit (LInt 0))))))))
(DTypeSig false "bindChainSplit" (TyFun (TyCon "Expr") (TyTuple (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "bindChainSplit" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBlock" (PVar "stmts")) () (EMatch (EApp (EVar "reverseL") (EVar "stmts")) (arm (PCons (PCon "DoExpr" (PVar "lastE")) (PVar "revInit")) () (ETuple (EApp (EApp (EVar "flatMap") (EVar "stmtExprs")) (EApp (EVar "reverseL") (EVar "revInit"))) (EVar "lastE"))) (arm PWild () (ETuple (EListLit) (EApp (EVar "EBlock") (EVar "stmts")))))) (arm (PVar "other") () (ETuple (EListLit) (EVar "other")))))
(DTypeSig false "bindChainHead" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "bindChainHead" ((PVar "isResult") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EMatch" PWild (PVar "arms")) () (EMatch (EVar "arms") (arm (PList (PVar "a1") (PVar "a2")) () (EMatch (EApp (EApp (EApp (EVar "bindChainTry") (EVar "isResult")) (EVar "a1")) (EVar "a2")) (arm (PCon "Some" (PVar "b")) () (EApp (EVar "Some") (EVar "b"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "bindChainTry") (EVar "isResult")) (EVar "a2")) (EVar "a1"))))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "bindChainTry" (TyFun (TyCon "Bool") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "bindChainTry" ((PVar "isResult") (PVar "failArm") (PCon "Arm" (PVar "okP") (PVar "okGs") (PVar "okBody"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "bindChainFailPassthru") (EVar "isResult")) (EVar "failArm")) (EApp (EVar "isEmptyL") (EVar "okGs"))) (EApp (EApp (EVar "bindChainOkPat") (EVar "isResult")) (EVar "okP"))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "bindChainRewrap") (EVar "isResult")) (EVar "okP")) (EVar "okBody")))) (EApp (EVar "Some") (EVar "okBody")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bindChainFailPassthru" (TyFun (TyCon "Bool") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "bindChainFailPassthru" ((PVar "isResult") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "gs")) (EIf (EVar "isResult") (EApp (EApp (EVar "matchToMapErrPassthru") (EVar "p")) (EVar "body")) (EBinOp "&&" (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "p")) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "None"))) (EVar "body"))))))
(DTypeSig false "bindChainOkPat" (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "bindChainOkPat" ((PVar "isResult") (PCon "PCon" (PVar "c") (PList PWild))) (EBinOp "==" (EVar "c") (EIf (EVar "isResult") (ELit (LString "Ok")) (ELit (LString "Some")))))
(DFunDef false "bindChainOkPat" (PWild PWild) (EVar "False"))
(DTypeSig false "bindChainRewrap" (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "bindChainRewrap" ((PVar "isResult") (PVar "p") (PVar "body")) (EMatch (EApp (EApp (EApp (EVar "matchToMapTransform") (EIf (EVar "isResult") (ELit (LString "Ok")) (ELit (LString "Some")))) (EVar "p")) (EVar "body")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "bindChainIsTermMap" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "bindChainIsTermMap" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "inner") PWild) () (EMatch (EApp (EVar "unwrapLoc") (EVar "inner")) (arm (PCon "EApp" (PVar "hd") PWild) () (EApp (EApp (EVar "isEVarNamed") (ELit (LString "map"))) (EVar "hd"))) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig false "bindChainOffChain" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "bindChainOffChain" ((PVar "isResult") (PVar "e")) (EBlock (DoLet false false (PTuple (PVar "lets") (PVar "core")) (EApp (EVar "bindChainSplit") (EVar "e"))) (DoExpr (EMatch (EApp (EApp (EVar "bindChainHead") (EVar "isResult")) (EVar "core")) (arm (PCon "Some" (PVar "body")) () (EBinOp "++" (EVar "lets") (EBinOp "::" (EApp (EVar "bindChainScrut") (EVar "core")) (EApp (EApp (EVar "bindChainOffChain") (EVar "isResult")) (EVar "body"))))) (arm (PCon "None") () (EIf (EApp (EVar "bindChainIsTermMap") (EVar "core")) (EBinOp "++" (EVar "lets") (EApp (EVar "bindChainTermMapParts") (EVar "core"))) (EBinOp "++" (EVar "lets") (EListLit (EVar "core")))))))))
(DTypeSig false "bindChainScrut" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "bindChainScrut" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EMatch" (PVar "s") PWild) () (EVar "s")) (arm PWild () (EVar "e"))))
(DTypeSig false "bindChainTermMapParts" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "bindChainTermMapParts" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "inner") (PVar "scrut")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "inner")) (arm (PCon "EApp" PWild (PVar "f")) () (EListLit (EVar "f") (EVar "scrut"))) (arm PWild () (EListLit (EVar "e"))))) (arm PWild () (EListLit (EVar "e")))))
(DTypeSig false "bindChainHeads" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "bindChainHeads" ((PVar "e")) (EBlock (DoLet false false (PVar "rd") (EApp (EApp (EVar "bindChainDepth") (EVar "True")) (EVar "e"))) (DoLet false false (PVar "od") (EApp (EApp (EVar "bindChainDepth") (EVar "False")) (EVar "e"))) (DoExpr (EIf (EBinOp "||" (EBinOp ">=" (EVar "rd") (ELit (LInt 3))) (EBinOp ">=" (EVar "od") (ELit (LInt 3)))) (EBinOp "::" (EVar "e") (EApp (EApp (EVar "flatMap") (EVar "bindChainHeads")) (EApp (EApp (EVar "bindChainOffChain") (EBinOp ">=" (EVar "rd") (EVar "od"))) (EVar "e")))) (EApp (EApp (EVar "flatMap") (EVar "bindChainHeads")) (EApp (EVar "childExprs") (EVar "e")))))))
(DTypeSig false "bindChainDeclHeads" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "bindChainDeclHeads" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "bindChainHeads") (EVar "body")))
(DFunDef false "bindChainDeclHeads" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "bindChainImplHeads")) (EVar "methods")))
(DFunDef false "bindChainDeclHeads" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "bindChainDeclHeads") (EVar "d")))
(DFunDef false "bindChainDeclHeads" (PWild) (EListLit))
(DTypeSig false "bindChainImplHeads" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "bindChainImplHeads" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "bindChainHeads") (EVar "body")))
(DTypeSig false "ruleBindChainToDo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleBindChainToDo" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "bindChainDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "bindChainDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "bindChainDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "map") (EApp (EVar "bindChainFinding") (EVar "loc"))) (EApp (EVar "bindChainDeclHeads") (EVar "d"))))
(DTypeSig false "bindChainFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "bindChainFinding" ((PVar "loc") PWild) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameBindChainToDo")) (fa "message" (ELit (LString "deep nested Result/Option passthrough-bind `match` chain (≥3 binds). Rewrite as a `do` block"))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "ruleDeadCode" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleDeadCode" (PWild (PVar "src") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "reach") (EApp (EApp (EVar "reachableNames") (EVar "src")) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "map") (EVar "deadFinding")) (EApp (EApp (EVar "filterList") (EApp (EVar "deadPair") (EVar "reach"))) (EApp (EApp (EVar "privateDefLocs") (EVar "pos")) (EVar "prog")))))))
(DTypeSig false "deadPair" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "deadPair" ((PVar "reach") (PTuple (PVar "n") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "n")) (EVar "reach"))))
(DTypeSig false "deadFinding" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding")))
(DFunDef false "deadFinding" ((PTuple (PVar "name") (PVar "loc"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDeadCode")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "private top-level '")) (EVar "name")) (ELit (LString "' is unreachable from exports/main/doctests — remove it (dead code)")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "privateDefLocs" (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "privateDefLocs" ((PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "exported") (EApp (EVar "nameSetOf") (EApp (EVar "exportedNames") (EVar "prog")))) (DoExpr (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EVar "filterList") (EApp (EVar "candidatePair") (EVar "exported"))) (EApp (EApp (EVar "flatMap") (EVar "allDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))))
(DTypeSig false "nameSetOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "nameSetOf" ((PVar "names")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "nameSetInto") (EVar "names")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "nameSetInto" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyCon "Unit"))))
(DFunDef false "nameSetInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "nameSetInto" ((PCons (PVar "n") (PVar "rest")) (PVar "s")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "set") (EVar "n")) (ELit LUnit)) (EVar "s"))) (DoExpr (EApp (EApp (EVar "nameSetInto") (EVar "rest")) (EVar "s")))))
(DTypeSig false "allDefNameL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "allDefNameL" ((PTuple (PCon "DFunDef" PWild (PVar "name") PWild PWild) (PVar "loc"))) (EListLit (ETuple (EVar "name") (EVar "loc"))))
(DFunDef false "allDefNameL" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "allDefNameL") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "allDefNameL" (PWild) (EListLit))
(DTypeSig false "candidatePair" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "candidatePair" ((PVar "exported") (PTuple (PVar "n") PWild)) (EBinOp "&&" (EApp (EVar "isOrdinaryIdent") (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "n")) (EVar "exported")))))
(DTypeSig false "isOrdinaryIdent" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isOrdinaryIdent" ((PVar "s")) (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))) (EVar "False") (EIf (EVar "otherwise") (EApp (EVar "isIdentStart") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reachableNames" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "reachableNames" ((PVar "src") (PVar "prog")) (EBlock (DoLet false false (PVar "refMap") (EApp (EVar "mergeRefs") (EApp (EApp (EVar "flatMap") (EVar "defRefPair")) (EVar "prog")))) (DoLet false false (PVar "seed") (EBinOp "++" (EApp (EVar "exportedNames") (EVar "prog")) (EBinOp "::" (ELit (LString "main")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "nonDefRefL")) (EVar "prog")) (EApp (EVar "doctestIdents") (EVar "src")))))) (DoLet false false (PVar "visited") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "bfsReach") (EVar "refMap")) (EVar "visited")) (EVar "seed"))) (DoExpr (EVar "visited"))))
(DTypeSig false "defRefPair" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "defRefPair" ((PVar "d")) (EMatch (EApp (EVar "defNameOf") (EVar "d")) (arm (PCon "Some" (PVar "name")) () (EListLit (ETuple (EVar "name") (EApp (EVar "sortUniqS") (EApp (EVar "identTokens") (EApp (EVar "declToString") (EApp (EVar "unAttrib") (EVar "d")))))))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "defNameOf" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "defNameOf" ((PCon "DFunDef" PWild (PVar "name") PWild PWild)) (EApp (EVar "Some") (EVar "name")))
(DFunDef false "defNameOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "defNameOf") (EVar "d")))
(DFunDef false "defNameOf" (PWild) (EVar "None"))
(DTypeSig false "unAttrib" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "unAttrib" ((PCon "DAttrib" PWild (PVar "d"))) (EVar "d"))
(DFunDef false "unAttrib" ((PVar "d")) (EVar "d"))
(DTypeSig false "exportedNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "exportedNames" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "exportedNameL")) (EVar "prog")))
(DTypeSig false "exportedNameL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "exportedNameL" ((PCon "DFunDef" (PCon "True") (PVar "name") PWild PWild)) (EListLit (EVar "name")))
(DFunDef false "exportedNameL" ((PCon "DTypeSig" (PCon "True") (PVar "name") PWild)) (EListLit (EVar "name")))
(DFunDef false "exportedNameL" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "exportedNameL") (EVar "d")))
(DFunDef false "exportedNameL" (PWild) (EListLit))
(DTypeSig false "nonDefRefL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "nonDefRefL" ((PCon "DAttrib" PWild (PVar "dd"))) (EApp (EVar "nonDefRefL") (EVar "dd")))
(DFunDef false "nonDefRefL" ((PCon "DFunDef" PWild PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DTypeSig" PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DExtern" PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DData" PWild PWild PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DUse" PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DEffect" PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DTypeAlias" PWild PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DNewtype" PWild PWild PWild PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PVar "d")) (EApp (EVar "bodyIdents") (EVar "d")))
(DTypeSig false "bodyIdents" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "bodyIdents" ((PVar "d")) (EApp (EVar "sortUniqS") (EApp (EVar "identTokens") (EApp (EVar "declToString") (EVar "d")))))
(DTypeSig false "bfsReach" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "bfsReach" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "bfsReach" ((PVar "refMap") (PVar "visited") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "has") (EVar "x")) (EVar "visited")) (EApp (EApp (EApp (EVar "bfsReach") (EVar "refMap")) (EVar "visited")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "set") (EVar "x")) (ELit LUnit)) (EVar "visited"))) (DoExpr (EApp (EApp (EApp (EVar "bfsReach") (EVar "refMap")) (EVar "visited")) (EBinOp "++" (EApp (EApp (EVar "refsOf") (EVar "refMap")) (EVar "x")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refsOf" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "refsOf" ((PVar "refMap") (PVar "n")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "refMap")))
(DTypeSig false "mergeRefs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "mergeRefs" ((PVar "pairs")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "mergeRefsGo") (EVar "m")) (EVar "pairs"))) (DoExpr (EVar "m"))))
(DTypeSig false "mergeRefsGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Unit"))))
(DFunDef false "mergeRefsGo" (PWild (PList)) (ELit LUnit))
(DFunDef false "mergeRefsGo" ((PVar "acc") (PCons (PTuple (PVar "n") (PVar "rs")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "set") (EVar "n")) (EApp (EVar "sortUniqS") (EBinOp "++" (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "acc")) (EVar "rs")))) (EVar "acc"))) (DoExpr (EApp (EApp (EVar "mergeRefsGo") (EVar "acc")) (EVar "rest")))))
(DTypeSig false "identTokens" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "identTokens" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "identTokGo") (EVar "s")) (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "identTokGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "identTokGo" ((PVar "s") (PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EApp (EVar "isIdentStart") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EBlock (DoLet false false (PVar "j") (EApp (EApp (EApp (EVar "identEnd") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EVar "j")) (EVar "s")) (EApp (EApp (EApp (EApp (EVar "identTokGo") (EVar "s")) (EVar "cs")) (EVar "n")) (EVar "j"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "identTokGo") (EVar "s")) (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isIdentStart" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isIdentStart" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EApp (EVar "isLower") (EVar "c")) (EApp (EVar "isUpper") (EVar "c"))) (EBinOp "==" (EVar "c") (ELit (LChar "_")))))
(DTypeSig false "identEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identEnd" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "i") (EIf (EApp (EVar "isAlnum") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "identEnd") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "doctestIdents" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doctestIdents" ((PVar "src")) (EApp (EApp (EVar "flatMap") (EVar "commentDocIdents")) (EApp (EVar "collectComments") (EVar "src"))))
(DTypeSig false "commentDocIdents" (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "commentDocIdents" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "commentText") (EVar "c"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "{-"))) (EVar "t")) (EApp (EApp (EVar "flatMap") (EVar "blockDocLineIdents")) (EApp (EVar "splitNl") (EApp (EVar "blockInner") (EVar "t")))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "-- >"))) (EVar "t")) (EApp (EVar "identTokens") (EApp (EApp (EVar "dropPrefixN") (ELit (LInt 4))) (EVar "t"))) (EListLit))))))
(DTypeSig false "blockInner" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "blockInner" ((PVar "t")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "t"))) (DoExpr (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "t")) (ELit (LString ""))))))
(DTypeSig false "blockDocLineIdents" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "blockDocLineIdents" ((PVar "line")) (EBlock (DoLet false false (PVar "tr") (EApp (EVar "stringTrim") (EVar "line"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString ">"))) (EVar "tr")) (EApp (EVar "identTokens") (EApp (EApp (EVar "dropPrefixN") (ELit (LInt 1))) (EVar "tr"))) (EListLit)))))
(DTypeSig false "dropPrefixN" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "dropPrefixN" ((PVar "k") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "k")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))
(DTypeSig true "runCrossFileRules" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "runCrossFileRules" ((PVar "only") (PVar "disable") (PVar "files")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "runCrossRuleOn") (EVar "only")) (EVar "disable")) (EVar "files"))) (EVar "allCrossFileRules")))
(DTypeSig false "runCrossRuleOn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "CrossFileRule") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "runCrossRuleOn" ((PVar "only") (PVar "disable") (PVar "files") (PVar "r")) (EIf (EApp (EApp (EApp (EVar "crossRuleActive") (EVar "only")) (EVar "disable")) (EVar "r")) (EApp (EApp (EVar "map") (EApp (EVar "restampSeverity") (EFieldAccess (EVar "r") "severity"))) (EApp (EFieldAccess (EVar "r") "check") (EVar "files"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "crossFileCacheSound" (TyCon "Bool"))
(DFunDef false "crossFileCacheSound" () (EMatch (EVar "allCrossFileRules") (arm (PList (PVar "r")) () (EBinOp "==" (EFieldAccess (EVar "r") "name") (EVar "ruleNameDuplicateBody"))) (arm PWild () (EVar "False"))))
(DTypeSig true "runCrossFileRulesFromOccs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "runCrossFileRulesFromOccs" ((PVar "only") (PVar "disable") (PVar "occs")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "runCrossRuleFromOccs") (EVar "only")) (EVar "disable")) (EVar "occs"))) (EVar "allCrossFileRules")))
(DTypeSig false "runCrossRuleFromOccs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CrossFileRule") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "runCrossRuleFromOccs" ((PVar "only") (PVar "disable") (PVar "occs") (PVar "r")) (EIf (EBinOp "&&" (EApp (EApp (EApp (EVar "crossRuleActive") (EVar "only")) (EVar "disable")) (EVar "r")) (EBinOp "==" (EFieldAccess (EVar "r") "name") (EVar "ruleNameDuplicateBody"))) (EApp (EApp (EVar "map") (EApp (EVar "restampSeverity") (EFieldAccess (EVar "r") "severity"))) (EApp (EVar "dupJoin") (EVar "occs"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "crossRuleActive" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CrossFileRule") (TyCon "Bool")))))
(DFunDef false "crossRuleActive" ((PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EFieldAccess (EVar "r") "enabled") (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only")))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))))
(DTypeSig false "dupComplexityThreshold" (TyCon "Int"))
(DFunDef false "dupComplexityThreshold" () (ELit (LInt 10)))
(DTypeSig false "structuralKey" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "String"))))
(DFunDef false "structuralKey" ((PVar "pats") (PVar "body")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString "|"))) (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "pats"))))) (ELit (LString " => "))) (EApp (EVar "display") (EApp (EVar "exprSexp") (EVar "body")))) (ELit (LString ""))))
(DTypeSig false "bodyComplexity" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "bodyComplexity" ((PVar "body")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EApp (EVar "exprSexp") (EVar "body")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "countOpenParens") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DTypeSig false "countOpenParens" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "countOpenParens" ((PVar "cs") (PVar "n") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "("))) (EApp (EApp (EApp (EApp (EVar "countOpenParens") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "countOpenParens") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "ruleDuplicateBody" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "ruleDuplicateBody" ((PVar "files")) (EApp (EVar "dupJoin") (EApp (EApp (EVar "flatMap") (EVar "fileDupOccs")) (EVar "files"))))
(DTypeSig true "dupJoin" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "dupJoin" ((PVar "occs")) (EBlock (DoLet false false (PVar "groups") (EApp (EVar "groupOccsByKey") (EVar "occs"))) (DoLet false false (PVar "live") (EApp (EApp (EVar "filterList") (ELam ((PVar "k")) (EApp (EVar "dupGroupFires") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "k")) (EVar "groups"))))) (EApp (EVar "dupDistinctKeys") (EVar "occs")))) (DoExpr (EApp (EApp (EVar "flatMap") (ELam ((PVar "k")) (EApp (EVar "emitDupGroup") (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "k")) (EVar "groups")))))) (EApp (EVar "sortUniqS") (EVar "live"))))))
(DTypeSig false "groupOccsByKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "groupOccsByKey" ((PVar "occs")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "groupOccsGo") (EVar "m")) (EVar "occs"))) (DoExpr (EVar "m"))))
(DTypeSig false "groupOccsGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "groupOccsGo" (PWild (PList)) (ELit LUnit))
(DFunDef false "groupOccsGo" ((PVar "m") (PCons (PVar "o") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "set") (EApp (EVar "occKey") (EVar "o"))) (EBinOp "::" (EVar "o") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EApp (EVar "occKey") (EVar "o"))) (EVar "m")))) (EVar "m"))) (DoExpr (EApp (EApp (EVar "groupOccsGo") (EVar "m")) (EVar "rest")))))
(DTypeSig false "dupDistinctKeys" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dupDistinctKeys" ((PVar "occs")) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "dupDistinctGo") (EVar "seen")) (EVar "occs")))))
(DTypeSig false "dupDistinctGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "dupDistinctGo" (PWild (PList)) (EListLit))
(DFunDef false "dupDistinctGo" ((PVar "seen") (PCons (PVar "o") (PVar "rest"))) (EIf (EApp (EApp (EVar "has") (EApp (EVar "occKey") (EVar "o"))) (EVar "seen")) (EApp (EApp (EVar "dupDistinctGo") (EVar "seen")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "set") (EApp (EVar "occKey") (EVar "o"))) (ELit LUnit)) (EVar "seen"))) (DoExpr (EBinOp "::" (EApp (EVar "occKey") (EVar "o")) (EApp (EApp (EVar "dupDistinctGo") (EVar "seen")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupGroupFires" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyCon "Bool")))
(DFunDef false "dupGroupFires" ((PVar "grp")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "grp")) (ELit (LInt 2))) (EBinOp ">=" (EApp (EVar "listLen") (EApp (EVar "sortUniqS") (EApp (EApp (EVar "map") (EVar "occFile")) (EVar "grp")))) (ELit (LInt 2)))))
(DTypeSig true "fileDupOccs" (TyFun (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))))
(DFunDef false "fileDupOccs" ((PTuple (PVar "path") (PVar "pos") (PVar "decls"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "dupOccOfDecl") (EVar "path"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "decls"))))
(DTypeSig false "dupOccOfDecl" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dupOccOfDecl" ((PVar "path") (PTuple (PVar "d") (PVar "loc"))) (EMatch (EVar "d") (arm (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body")) () (EIf (EBinOp ">=" (EApp (EVar "bodyComplexity") (EVar "body")) (EVar "dupComplexityThreshold")) (EListLit (ETuple (EVar "path") (EApp (EVar "locLineOf") (EVar "loc")) (EVar "name") (EApp (EApp (EVar "structuralKey") (EVar "pats")) (EVar "body")))) (EListLit))) (arm (PCon "DAttrib" PWild (PVar "inner")) () (EApp (EApp (EVar "dupOccOfDecl") (EVar "path")) (ETuple (EVar "inner") (EVar "loc")))) (arm PWild () (EListLit))))
(DTypeSig false "locLineOf" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int")))
(DFunDef false "locLineOf" ((PCon "Some" (PCon "Loc" PWild (PVar "l") PWild PWild PWild))) (EVar "l"))
(DFunDef false "locLineOf" ((PCon "None")) (ELit (LInt 1)))
(DTypeSig false "occFile" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "occFile" ((PTuple (PVar "f") PWild PWild PWild)) (EVar "f"))
(DTypeSig false "occLine" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "Int")))
(DFunDef false "occLine" ((PTuple PWild (PVar "l") PWild PWild)) (EVar "l"))
(DTypeSig false "occName" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "occName" ((PTuple PWild PWild (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "occKey" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "occKey" ((PTuple PWild PWild PWild (PVar "k"))) (EVar "k"))
(DTypeSig false "emitDupGroup" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "emitDupGroup" ((PVar "grp")) (EBlock (DoLet false false (PVar "distinctFiles") (EApp (EVar "sortUniqS") (EApp (EApp (EVar "map") (EVar "occFile")) (EVar "grp")))) (DoExpr (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "distinctFiles")) (ELit (LInt 2))) (EListLit) (EApp (EApp (EVar "map") (EApp (EVar "dupFinding") (EVar "distinctFiles"))) (EApp (EVar "sortDupOccs") (EVar "grp")))))))
(DTypeSig false "dupFinding" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "Finding"))))
(DFunDef false "dupFinding" ((PVar "distinctFiles") (PVar "occ")) (EBlock (DoLet false false (PVar "file") (EApp (EVar "occFile") (EVar "occ"))) (DoLet false false (PVar "line") (EApp (EVar "occLine") (EVar "occ"))) (DoLet false false (PVar "others") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "!=" (EVar "_s") (EVar "file")))) (EVar "distinctFiles"))) (DoExpr (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDuplicateBody")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function '")) (EApp (EVar "display") (EApp (EVar "occName") (EVar "occ")))) (ELit (LString "' has a body structurally identical to a definition in "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "others")))) (ELit (LString " — consolidate into a shared module")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EVar "line")) (ELit (LInt 1))) (EVar "line")) (ELit (LInt 1))))))))))
(DTypeSig false "sortDupOccs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))))
(DFunDef false "sortDupOccs" ((PList)) (EListLit))
(DFunDef false "sortDupOccs" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "dupInsert") (EVar "x")) (EApp (EVar "sortDupOccs") (EVar "xs"))))
(DTypeSig false "dupInsert" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dupInsert" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "dupInsert" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EApp (EApp (EVar "dupOccLe") (EVar "x")) (EVar "y")) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "dupInsert") (EVar "x")) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupOccLe" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "dupOccLe" ((PVar "a") (PVar "b")) (EMatch (EApp (EApp (EVar "stringCompare") (EApp (EVar "occFile") (EVar "a"))) (EApp (EVar "occFile") (EVar "b"))) (arm (PCon "Lt") () (EVar "True")) (arm (PCon "Gt") () (EVar "False")) (arm (PCon "Eq") () (EBinOp "<=" (EApp (EVar "occLine") (EVar "a")) (EApp (EVar "occLine") (EVar "b"))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "Ty" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "ImplMethod" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "parseWithPositions" false) (mem "parseWithPositionsLocated" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true) (mem "Diag" true) (mem "ppSeverity" false) (mem "readFileSafe" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "anyList" false) (mem "allList" false) (mem "filterList" false) (mem "joinNl" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "reverseL" false) (mem "splitNl" false) (mem "splitOnChar" false) (mem "joinWith" false) (mem "sortUniqS" false) (mem "startsWith" false) (mem "stringTrim" false) (mem "lookupAssoc" false) (mem "dedupBy" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "set" false) (mem "has" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "declToString" false) (mem "exprToString" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false) (mem "isLower" false) (mem "isUpper" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false) (mem "patSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false) (mem "buildOracle" false) (mem "oGetCtors" false) (mem "oGetCtorType" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Comment" false) (mem "collectComments" false) (mem "commentLine" false) (mem "commentText" false))))
(DData Public "Finding" () ((variant "Finding" (ConNamed (field "rule" (TyCon "String")) (field "message" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "loc" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Public "Rule" () ((variant "Rule" (ConNamed (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "enabled" (TyCon "Bool")) (field "check" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))) (field "fix" (TyApp (TyCon "Option") (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))))) ())
(DData Public "CrossFileRule" () ((variant "CrossFileRule" (ConNamed (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "severity" (TyCon "Severity")) (field "enabled" (TyCon "Bool")) (field "check" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))))))) ())
(DTypeSig false "ruleNameMatchParam" (TyCon "String"))
(DFunDef false "ruleNameMatchParam" () (ELit (LString "rule-match-on-param")))
(DTypeSig false "ruleNameDerivable" (TyCon "String"))
(DFunDef false "ruleNameDerivable" () (ELit (LString "rule-hand-rolled-derivable")))
(DTypeSig false "ruleNameStdlibReimpl" (TyCon "String"))
(DFunDef false "ruleNameStdlibReimpl" () (ELit (LString "rule-stdlib-reimpl")))
(DTypeSig false "ruleNameDuplicateBody" (TyCon "String"))
(DFunDef false "ruleNameDuplicateBody" () (ELit (LString "rule-duplicate-body")))
(DTypeSig false "ruleNameBindThenDestructure" (TyCon "String"))
(DFunDef false "ruleNameBindThenDestructure" () (ELit (LString "rule-bind-then-destructure")))
(DTypeSig false "ruleNameLambdaSection" (TyCon "String"))
(DFunDef false "ruleNameLambdaSection" () (ELit (LString "rule-lambda-section")))
(DTypeSig false "ruleNameIfMaxMin" (TyCon "String"))
(DFunDef false "ruleNameIfMaxMin" () (ELit (LString "rule-if-max-min")))
(DTypeSig false "ruleNameAndThenPureMap" (TyCon "String"))
(DFunDef false "ruleNameAndThenPureMap" () (ELit (LString "rule-andthen-pure-map")))
(DTypeSig false "ruleNameDestructureInParam" (TyCon "String"))
(DFunDef false "ruleNameDestructureInParam" () (ELit (LString "rule-destructure-in-param")))
(DTypeSig false "ruleNameMissingSignature" (TyCon "String"))
(DFunDef false "ruleNameMissingSignature" () (ELit (LString "rule-missing-signature")))
(DTypeSig false "ruleNameNotEq" (TyCon "String"))
(DFunDef false "ruleNameNotEq" () (ELit (LString "rule-not-eq")))
(DTypeSig false "ruleNameBoolSimplify" (TyCon "String"))
(DFunDef false "ruleNameBoolSimplify" () (ELit (LString "rule-bool-simplify")))
(DTypeSig false "ruleNameRemParity" (TyCon "String"))
(DFunDef false "ruleNameRemParity" () (ELit (LString "rule-rem-parity")))
(DTypeSig false "ruleNameDoubleReverse" (TyCon "String"))
(DFunDef false "ruleNameDoubleReverse" () (ELit (LString "rule-double-reverse")))
(DTypeSig false "ruleNameWhenUnless" (TyCon "String"))
(DFunDef false "ruleNameWhenUnless" () (ELit (LString "rule-when-unless")))
(DTypeSig false "ruleNameComplementPredicate" (TyCon "String"))
(DFunDef false "ruleNameComplementPredicate" () (ELit (LString "rule-complement-predicate")))
(DTypeSig false "ruleNameMatchToMap" (TyCon "String"))
(DFunDef false "ruleNameMatchToMap" () (ELit (LString "rule-match-to-map")))
(DTypeSig false "ruleNameBindChainToDo" (TyCon "String"))
(DFunDef false "ruleNameBindChainToDo" () (ELit (LString "rule-bind-chain-to-do")))
(DTypeSig false "ruleNameDeadCode" (TyCon "String"))
(DFunDef false "ruleNameDeadCode" () (ELit (LString "rule-dead-code")))
(DTypeSig false "ruleNameConcatToInterp" (TyCon "String"))
(DFunDef false "ruleNameConcatToInterp" () (ELit (LString "rule-concat-to-interp")))
(DTypeSig false "ruleNameSelfShadowExtern" (TyCon "String"))
(DFunDef false "ruleNameSelfShadowExtern" () (ELit (LString "rule-self-shadow-extern")))
(DTypeSig false "matchParamRule" (TyCon "Rule"))
(DFunDef false "matchParamRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameMatchParam")) (fa "descr" (ELit (LString "function body is a `match` on a bare parameter (prefer multi-clause; STYLE §8)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleMatchOnParam")) (fa "fix" (EApp (EVar "Some") (EVar "matchParamFix"))))))
(DTypeSig false "derivableRule" (TyCon "Rule"))
(DFunDef false "derivableRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDerivable")) (fa "descr" (ELit (LString "hand-written Eq/Ord/Debug impl that could be `deriving` (STYLE §6)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDerivable")) (fa "fix" (EVar "None")))))
(DTypeSig false "stdlibReimplRule" (TyCon "Rule"))
(DFunDef false "stdlibReimplRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameStdlibReimpl")) (fa "descr" (ELit (LString "top-level function shadows a common stdlib/prelude name (STYLE §7a)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleStdlibReimpl")) (fa "fix" (EVar "None")))))
(DTypeSig false "bindThenDestructureRule" (TyCon "Rule"))
(DFunDef false "bindThenDestructureRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameBindThenDestructure")) (fa "descr" (ELit (LString "do-bind then immediately destructures the bound var with an irrefutable single-arm `match`. Inline the pattern into the bind"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleBindThenDestructure")) (fa "fix" (EApp (EVar "Some") (EVar "bindThenDestructureFix"))))))
(DTypeSig false "lambdaSectionRule" (TyCon "Rule"))
(DFunDef false "lambdaSectionRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameLambdaSection")) (fa "descr" (ELit (LString "lambda whose body is a single binary op on its parameter(s). Prefer an operator section (STYLE \"Dogfooding\")"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleLambdaSection")) (fa "fix" (EApp (EVar "Some") (EVar "lambdaSectionFix"))))))
(DTypeSig false "ifMaxMinRule" (TyCon "Rule"))
(DFunDef false "ifMaxMinRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameIfMaxMin")) (fa "descr" (ELit (LString "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleIfMaxMin")) (fa "fix" (EApp (EVar "Some") (EVar "ifMaxMinFix"))))))
(DTypeSig false "andThenPureMapRule" (TyCon "Rule"))
(DFunDef false "andThenPureMapRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameAndThenPureMap")) (fa "descr" (ELit (LString "monadic bind whose continuation just wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map` (functor law: m >>= (pure . f) ≡ fmap f m)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleAndThenPureMap")) (fa "fix" (EApp (EVar "Some") (EVar "andThenPureMapFix"))))))
(DTypeSig false "destructureInParamRule" (TyCon "Rule"))
(DFunDef false "destructureInParamRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDestructureInParam")) (fa "descr" (ELit (LString "function body is a single-arm `match` on a bare parameter with an irrefutable pattern (tuple/record/single-ctor). Destructure directly in the parameter position"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDestructureInParam")) (fa "fix" (EApp (EVar "Some") (EVar "destructureInParamFix"))))))
(DTypeSig false "missingSignatureRule" (TyCon "Rule"))
(DFunDef false "missingSignatureRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameMissingSignature")) (fa "descr" (ELit (LString "top-level value/function binding has no sibling type signature (name : Type). Add one (Haskell -Wmissing-signatures)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleMissingSignature")) (fa "fix" (EVar "None")))))
(DTypeSig false "notEqRule" (TyCon "Rule"))
(DFunDef false "notEqRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameNotEq")) (fa "descr" (ELit (LString "negated equality `not (a == b)` / `not (a != b)`. Prefer `a != b` / `a == b`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleNotEq")) (fa "fix" (EApp (EVar "Some") (EVar "notEqFix"))))))
(DTypeSig false "boolSimplifyRule" (TyCon "Rule"))
(DFunDef false "boolSimplifyRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameBoolSimplify")) (fa "descr" (ELit (LString "redundant boolean shape (`if c then True else False`, `x == True`, `not (not x)`, …). Simplify"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleBoolSimplify")) (fa "fix" (EApp (EVar "Some") (EVar "boolSimplifyFix"))))))
(DTypeSig false "remParityRule" (TyCon "Rule"))
(DFunDef false "remParityRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameRemParity")) (fa "descr" (ELit (LString "`n % 2 == 0` / `n % 2 != 0` parity test. Prefer `isEven n` / `isOdd n`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleRemParity")) (fa "fix" (EApp (EVar "Some") (EVar "remParityFix"))))))
(DTypeSig false "doubleReverseRule" (TyCon "Rule"))
(DFunDef false "doubleReverseRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDoubleReverse")) (fa "descr" (ELit (LString "`reverse (reverse x)` is `x`. Drop the double reversal"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDoubleReverse")) (fa "fix" (EApp (EVar "Some") (EVar "doubleReverseFix"))))))
(DTypeSig false "whenUnlessRule" (TyCon "Rule"))
(DFunDef false "whenUnlessRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameWhenUnless")) (fa "descr" (ELit (LString "`if b then m else pure ()` / `if b then pure () else m`. Prefer `when b m` / `unless b m`"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleWhenUnless")) (fa "fix" (EApp (EVar "Some") (EVar "whenUnlessFix"))))))
(DTypeSig false "complementPredicateRule" (TyCon "Rule"))
(DFunDef false "complementPredicateRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameComplementPredicate")) (fa "descr" (ELit (LString "`not (p x)` where `p` has a defined complement predicate (`isEmptyL`/`isSome`/`isOk` & inverses). Call the complement directly"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleComplementPredicate")) (fa "fix" (EApp (EVar "Some") (EVar "complementPredicateFix"))))))
(DTypeSig false "matchToMapRule" (TyCon "Rule"))
(DFunDef false "matchToMapRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameMatchToMap")) (fa "descr" (ELit (LString "2-arm `match` on Option/Result that reconstructs the failure ctor and re-wraps the success ctor. That IS a functor `map` (hlint 'use fmap')"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleMatchToMap")) (fa "fix" (EApp (EVar "Some") (EVar "matchToMapFix"))))))
(DTypeSig false "bindChainToDoRule" (TyCon "Rule"))
(DFunDef false "bindChainToDoRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameBindChainToDo")) (fa "descr" (ELit (LString "deep (≥3) nested Result/Option passthrough-bind `match` pyramid. Rewrite as a `do` block (suggest-only)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleBindChainToDo")) (fa "fix" (EVar "None")))))
(DTypeSig false "deadCodeRule" (TyCon "Rule"))
(DFunDef false "deadCodeRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameDeadCode")) (fa "descr" (ELit (LString "private (unexported) top-level binding is unreachable from the file's exports/main/doctests. Dead code (Haskell -Wunused-top-binds)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDeadCode")) (fa "fix" (EVar "None")))))
(DTypeSig false "concatToInterpRule" (TyCon "Rule"))
(DFunDef false "concatToInterpRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameConcatToInterp")) (fa "descr" (ELit (LString "`++` chain mixing string literals and expressions. Prefer string interpolation `\"…\\{e}…\"` (hlint 'use interpolation')"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleConcatToInterp")) (fa "fix" (EApp (EVar "Some") (EVar "concatToInterpFix"))))))
(DTypeSig false "selfShadowExternRule" (TyCon "Rule"))
(DFunDef false "selfShadowExternRule" () (ERecordCreate "Rule" ((fa "name" (EVar "ruleNameSelfShadowExtern")) (fa "descr" (ELit (LString "top-level binding unconditionally forwards to itself (`f s = f s`, `x = x`) — an infinite self-recursion, not a forward to a same-named extern (#266)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleSelfShadowExtern")) (fa "fix" (EVar "None")))))
(DTypeSig true "allRules" (TyApp (TyCon "List") (TyCon "Rule")))
(DFunDef false "allRules" () (EListLit (EVar "matchParamRule") (EVar "derivableRule") (EVar "stdlibReimplRule") (EVar "bindThenDestructureRule") (EVar "lambdaSectionRule") (EVar "ifMaxMinRule") (EVar "andThenPureMapRule") (EVar "destructureInParamRule") (EVar "missingSignatureRule") (EVar "notEqRule") (EVar "boolSimplifyRule") (EVar "remParityRule") (EVar "doubleReverseRule") (EVar "whenUnlessRule") (EVar "complementPredicateRule") (EVar "matchToMapRule") (EVar "bindChainToDoRule") (EVar "deadCodeRule") (EVar "concatToInterpRule") (EVar "selfShadowExternRule")))
(DTypeSig false "duplicateBodyRule" (TyCon "CrossFileRule"))
(DFunDef false "duplicateBodyRule" () (ERecordCreate "CrossFileRule" ((fa "name" (EVar "ruleNameDuplicateBody")) (fa "descr" (ELit (LString "top-level function body is structurally identical to one in another file (copy-paste; consolidate)"))) (fa "severity" (EVar "SevWarning")) (fa "enabled" (EVar "True")) (fa "check" (EVar "ruleDuplicateBody")))))
(DTypeSig true "allCrossFileRules" (TyApp (TyCon "List") (TyCon "CrossFileRule")))
(DFunDef false "allCrossFileRules" () (EListLit (EVar "duplicateBodyRule")))
(DTypeSig true "lintProgram" (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "lintProgram" ((PVar "rules") (PVar "path") (PVar "src") (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EVar "runRuleOn") (EVar "path")) (EVar "src")) (EVar "pos")) (EVar "prog"))) (EVar "rules")))
(DTypeSig false "runRuleOn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Rule") (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "runRuleOn" ((PVar "path") (PVar "src") (PVar "pos") (PVar "prog") (PVar "r")) (EIf (EFieldAccess (EVar "r") "enabled") (EApp (EApp (EMethodRef "map") (EApp (EVar "restampSeverity") (EFieldAccess (EVar "r") "severity"))) (EApp (EApp (EApp (EApp (EFieldAccess (EVar "r") "check") (EVar "path")) (EVar "src")) (EVar "pos")) (EVar "prog"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "restampSeverity" (TyFun (TyCon "Severity") (TyFun (TyCon "Finding") (TyCon "Finding"))))
(DFunDef false "restampSeverity" ((PVar "sev") (PVar "f")) (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EVar "sev")) (fa "loc" (EFieldAccess (EVar "f") "loc")))))
(DTypeSig false "isStdlibPath" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isStdlibPath" ((PVar "path")) (EApp (EApp (EVar "contains") (ELit (LString "stdlib"))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "path"))))
(DTypeSig true "applyFixes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Positions") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "applyFixes" ((PVar "only") (PVar "disable") (PVar "src") (PVar "prog") (PVar "pos")) (EBlock (DoLet false false (PVar "rules") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "ruleActiveFixable") (EVar "only")) (EVar "disable"))) (EVar "allRules"))) (DoLet false false (PVar "orc") (EApp (EVar "buildOracle") (EVar "prog"))) (DoLet false false (PVar "cmtLines") (EApp (EApp (EMethodRef "map") (EVar "commentLine")) (EApp (EVar "collectComments") (EVar "src")))) (DoLet false false (PVar "splices") (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EApp (EApp (EVar "zipDeclPos") (EVar "prog")) (EApp (EVar "positionsDecls") (EVar "pos"))))) (DoExpr (ETuple (EApp (EApp (EVar "applySplices") (EVar "src")) (EVar "splices")) (EApp (EVar "listLen") (EVar "splices"))))))
(DTypeSig false "ruleActiveFixable" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Rule") (TyCon "Bool")))))
(DFunDef false "ruleActiveFixable" ((PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EFieldAccess (EVar "r") "enabled") (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only")))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))) (EApp (EVar "ruleHasFixer") (EVar "r"))))
(DTypeSig false "ruleHasFixer" (TyFun (TyCon "Rule") (TyCon "Bool")))
(DFunDef false "ruleHasFixer" ((PVar "r")) (EMatch (EFieldAccess (EVar "r") "fix") (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "zipDeclPos" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))))))
(DFunDef false "zipDeclPos" ((PList) PWild) (EListLit))
(DFunDef false "zipDeclPos" (PWild (PList)) (EListLit))
(DFunDef false "zipDeclPos" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EBinOp "::" (ETuple (EVar "d") (EVar "p")) (EApp (EApp (EVar "zipDeclPos") (EVar "ds")) (EVar "ps"))))
(DTypeSig false "collectSplices" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "DeclPos"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))))))))
(DFunDef false "collectSplices" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "collectSplices" ((PVar "cmtLines") (PVar "orc") (PVar "rules") (PCons (PTuple (PVar "d") (PVar "dp")) (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "firstFix") (EVar "orc")) (EVar "rules")) (EVar "d")) (arm (PCon "Some" (PVar "newDecls")) () (EIf (EApp (EApp (EApp (EVar "spanHasComment") (EVar "cmtLines")) (EApp (EVar "declPosLine") (EVar "dp"))) (EApp (EVar "declPosEndLine") (EVar "dp"))) (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest")) (EBinOp "::" (ETuple (EApp (EVar "declPosLine") (EVar "dp")) (EApp (EVar "declPosEndLine") (EVar "dp")) (EApp (EVar "renderDecls") (EVar "newDecls"))) (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "collectSplices") (EVar "cmtLines")) (EVar "orc")) (EVar "rules")) (EVar "rest")))))
(DTypeSig false "spanHasComment" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "spanHasComment" ((PVar "cmtLines") (PVar "startLine") (PVar "endLine")) (EApp (EApp (EVar "anyList") (ELam ((PVar "l")) (EBinOp "&&" (EBinOp "<=" (EVar "startLine") (EVar "l")) (EBinOp "<=" (EVar "l") (EVar "endLine"))))) (EVar "cmtLines")))
(DTypeSig false "firstFix" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "Rule")) (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "firstFix" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "firstFix" ((PVar "orc") (PCons (PVar "r") (PVar "rs")) (PVar "d")) (EMatch (EApp (EApp (EApp (EVar "applyRuleFix") (EVar "orc")) (EVar "r")) (EVar "d")) (arm (PCon "Some" (PVar "newDecls")) () (EApp (EVar "Some") (EVar "newDecls"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "firstFix") (EVar "orc")) (EVar "rs")) (EVar "d")))))
(DTypeSig false "applyRuleFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Rule") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "applyRuleFix" ((PVar "orc") (PVar "r") (PVar "d")) (EMatch (EFieldAccess (EVar "r") "fix") (arm (PCon "Some" (PVar "f")) () (EApp (EApp (EVar "f") (EVar "orc")) (EVar "d"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "renderDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "renderDecls" ((PVar "ds")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "declToString")) (EVar "ds"))))
(DTypeSig false "applySplices" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyCon "String"))))
(DFunDef false "applySplices" ((PVar "src") (PVar "splices")) (EApp (EVar "joinNl") (EApp (EApp (EVar "foldSplices") (EApp (EVar "splitNl") (EVar "src"))) (EApp (EVar "reverseL") (EVar "splices")))))
(DTypeSig false "foldSplices" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "foldSplices" ((PVar "lines") (PList)) (EVar "lines"))
(DFunDef false "foldSplices" ((PVar "lines") (PCons (PTuple (PVar "s") (PVar "e") (PVar "txt")) (PVar "rest"))) (EApp (EApp (EVar "foldSplices") (EApp (EApp (EApp (EApp (EVar "spliceLines") (EVar "lines")) (EVar "s")) (EVar "e")) (EVar "txt"))) (EVar "rest")))
(DTypeSig false "spliceLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "spliceLines" ((PVar "lines") (PVar "s") (PVar "e") (PVar "txt")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "takeN") (EBinOp "-" (EVar "s") (ELit (LInt 1)))) (EVar "lines")) (EApp (EVar "splitNl") (EVar "txt"))) (EApp (EApp (EVar "dropN") (EVar "e")) (EVar "lines"))))
(DTypeSig false "takeN" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "takeN" ((PVar "n") PWild) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "takeN" (PWild (PList)) (EListLit))
(DFunDef false "takeN" ((PVar "n") (PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "takeN") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "xs"))))
(DTypeSig false "dropN" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "dropN" ((PVar "n") (PVar "xs")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EVar "xs") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "dropN" (PWild (PList)) (EListLit))
(DFunDef false "dropN" ((PVar "n") (PCons PWild (PVar "xs"))) (EApp (EApp (EVar "dropN") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "xs")))
(DTypeSig true "parseLintFlagList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "parseLintFlagList" ((PVar "prefix") (PList)) (EListLit))
(DFunDef false "parseLintFlagList" ((PVar "prefix") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "x")) (EApp (EVar "splitLintNames") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "x"))) (EVar "x"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseLintFlagList") (EVar "prefix")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "splitLintNames" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitLintNames" ((PVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EApp (EVar "stringToChars") (EVar "s"))) (EVar "s")) (ELit (LInt 0))) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))))
(DTypeSig false "splitLintNamesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitLintNamesGo" ((PVar "chars") (PVar "s") (PVar "start") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "n")) (EVar "s"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar ","))) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "start")) (EVar "i")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EVar "chars")) (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "splitLintNamesGo") (EVar "chars")) (EVar "s")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "applyFindingFilters" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "applyFindingFilters" ((PVar "disable") (PVar "only") (PVar "deny") (PVar "findings")) (EBlock (DoLet false false (PVar "after1") (EApp (EApp (EVar "applyFindingOnly") (EVar "only")) (EVar "findings"))) (DoLet false false (PVar "after2") (EApp (EApp (EVar "applyFindingDisable") (EVar "disable")) (EVar "after1"))) (DoExpr (EApp (EApp (EVar "applyFindingDeny") (EVar "deny")) (EVar "after2")))))
(DTypeSig false "applyFindingOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingOnly" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingOnly" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingOnlyGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingOnlyGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingOnlyGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lintFindingOnlyGo") (EVar "names")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "applyFindingDisable" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingDisable" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingDisable" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingDisableGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingDisableGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingDisableGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingDisableGo") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "applyFindingDeny" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applyFindingDeny" ((PList) (PVar "findings")) (EVar "findings"))
(DFunDef false "applyFindingDeny" ((PVar "names") (PVar "findings")) (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "findings")))
(DTypeSig false "lintFindingDenyGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "lintFindingDenyGo" (PWild (PList)) (EListLit))
(DFunDef false "lintFindingDenyGo" ((PVar "names") (PCons (PVar "f") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names")) (EBinOp "::" (ERecordCreate "Finding" ((fa "rule" (EFieldAccess (EVar "f") "rule")) (fa "message" (EFieldAccess (EVar "f") "message")) (fa "severity" (EVar "SevError")) (fa "loc" (EFieldAccess (EVar "f") "loc")))) (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "f") (EApp (EApp (EVar "lintFindingDenyGo") (EVar "names")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "isFindingError" (TyFun (TyCon "Finding") (TyCon "Bool")))
(DFunDef false "isFindingError" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "severity") (arm (PCon "SevError") () (EVar "True")) (arm (PCon "SevWarning") () (EVar "False"))))
(DTypeSig true "findingToDiag" (TyFun (TyCon "Finding") (TyCon "Diag")))
(DFunDef false "findingToDiag" ((PVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EFieldAccess (EVar "f") "severity")) (EFieldAccess (EVar "f") "rule")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EMethodRef "display") (EFieldAccess (EVar "f") "rule"))) (ELit (LString "] "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "f") "message"))) (ELit (LString "")))) (EFieldAccess (EVar "f") "loc")) (EVar "None")) (EVar "None")))
(DTypeSig true "lintFileDiagTriple" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))
(DFunDef false "lintFileDiagTriple" ((PVar "disable") (PVar "only") (PVar "deny") (PVar "path")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "path"))) (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositionsLocated") (EVar "src"))) (DoLet false false (PVar "allFindings") (EApp (EApp (EVar "applySuppressions") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EVar "lintProgram") (EVar "allRules")) (EVar "path")) (EVar "src")) (EVar "pos")) (EVar "decls")))) (DoLet false false (PVar "findings") (EApp (EApp (EApp (EApp (EVar "applyFindingFilters") (EVar "disable")) (EVar "only")) (EVar "deny")) (EVar "allFindings"))) (DoExpr (ETuple (EVar "path") (EVar "src") (EApp (EApp (EMethodRef "map") (EVar "findingToDiag")) (EVar "findings"))))))
(DTypeSig true "lintToLines" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))))
(DFunDef false "lintToLines" ((PVar "src") (PVar "path") (PVar "pos") (PVar "prog")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "findingLine")) (EApp (EApp (EVar "applySuppressions") (EVar "src")) (EApp (EApp (EApp (EApp (EApp (EVar "lintProgram") (EVar "allRules")) (EVar "path")) (EVar "src")) (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "findingLine" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "findingLine" ((PVar "f")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppSeverity") (EFieldAccess (EVar "f") "severity")))) (ELit (LString ": ["))) (EApp (EMethodRef "display") (EFieldAccess (EVar "f") "rule"))) (ELit (LString "] "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "f") "message"))) (ELit (LString ""))))
(DData Public "DirScope" () ((variant "DScopeLine" (ConPos (TyCon "Int"))) (variant "DScopeFile" (ConPos))) ())
(DData Public "Directive" () ((variant "Directive" (ConPos (TyCon "DirScope") (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig true "applySuppressions" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressions" ((PVar "src") (PVar "findings")) (EApp (EApp (EVar "applySuppressionsDirs") (EApp (EVar "collectDirectives") (EVar "src"))) (EVar "findings")))
(DTypeSig true "applySuppressionsDirs" (TyFun (TyApp (TyCon "List") (TyCon "Directive")) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressionsDirs" ((PVar "dirs") (PVar "findings")) (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EApp (EVar "isSuppressed") (EVar "dirs")) (EVar "f"))))) (EVar "findings")))
(DTypeSig true "applySuppressionsMulti" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressionsMulti" ((PVar "srcs") (PVar "findings")) (EApp (EApp (EVar "applySuppressionsMultiDirs") (EApp (EApp (EMethodRef "map") (EVar "fileDirectivesOf")) (EVar "srcs"))) (EVar "findings")))
(DTypeSig true "applySuppressionsMultiDirs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))) (TyFun (TyApp (TyCon "List") (TyCon "Finding")) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "applySuppressionsMultiDirs" ((PVar "dirTable") (PVar "findings")) (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EVar "not") (EApp (EApp (EVar "findingSuppressedMulti") (EVar "dirTable")) (EVar "f"))))) (EVar "findings")))
(DTypeSig false "fileDirectivesOf" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))))
(DFunDef false "fileDirectivesOf" ((PTuple (PVar "path") (PVar "src"))) (ETuple (EVar "path") (EApp (EVar "collectDirectives") (EVar "src"))))
(DTypeSig false "findingSuppressedMulti" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))) (TyFun (TyCon "Finding") (TyCon "Bool"))))
(DFunDef false "findingSuppressedMulti" ((PVar "dirTable") (PVar "f")) (EMatch (EApp (EApp (EVar "lookupDirs") (EApp (EVar "findingFileOf") (EVar "f"))) (EVar "dirTable")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "dirs")) () (EApp (EApp (EVar "isSuppressed") (EVar "dirs")) (EVar "f")))))
(DTypeSig false "findingFileOf" (TyFun (TyCon "Finding") (TyCon "String")))
(DFunDef false "findingFileOf" ((PVar "f")) (EMatch (EFieldAccess (EVar "f") "loc") (arm (PCon "Some" (PCon "Loc" (PVar "file") PWild PWild PWild PWild)) () (EVar "file")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "lookupDirs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Directive"))))))
(DFunDef false "lookupDirs" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupDirs" ((PVar "path") (PCons (PTuple (PVar "p") (PVar "ds")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "p") (EVar "path")) (EApp (EVar "Some") (EVar "ds")) (EApp (EApp (EVar "lookupDirs") (EVar "path")) (EVar "rest"))))
(DTypeSig true "collectDirectives" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Directive"))))
(DFunDef false "collectDirectives" ((PVar "src")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "c")) (EApp (EVar "dirToList") (EApp (EVar "parseDirective") (EVar "c"))))) (EApp (EVar "collectComments") (EVar "src"))))
(DTypeSig false "dirToList" (TyFun (TyApp (TyCon "Option") (TyCon "Directive")) (TyApp (TyCon "List") (TyCon "Directive"))))
(DFunDef false "dirToList" ((PCon "None")) (EListLit))
(DFunDef false "dirToList" ((PCon "Some" (PVar "d"))) (EListLit (EVar "d")))
(DTypeSig false "parseDirective" (TyFun (TyCon "Comment") (TyApp (TyCon "Option") (TyCon "Directive"))))
(DFunDef false "parseDirective" ((PVar "c")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "trimWs") (EApp (EVar "commentText") (EVar "c")))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "--"))) (EVar "body")) (EApp (EApp (EVar "parseDirectiveBody") (EApp (EVar "commentLine") (EVar "c"))) (EApp (EVar "trimWs") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "body"))) (EVar "body")))) (EVar "None")))))
(DTypeSig false "parseDirectiveBody" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Directive")))))
(DFunDef false "parseDirectiveBody" ((PVar "line") (PVar "s")) (EMatch (EApp (EApp (EVar "matchKeyword") (ELit (LString "lint-disable-next-line"))) (EVar "s")) (arm (PCon "Some" (PVar "names")) () (EApp (EVar "Some") (EApp (EApp (EVar "Directive") (EApp (EVar "DScopeLine") (EBinOp "+" (EVar "line") (ELit (LInt 1))))) (EApp (EVar "parseRuleNames") (EVar "names"))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "matchKeyword") (ELit (LString "lint-disable-line"))) (EVar "s")) (arm (PCon "Some" (PVar "names")) () (EApp (EVar "Some") (EApp (EApp (EVar "Directive") (EApp (EVar "DScopeLine") (EVar "line"))) (EApp (EVar "parseRuleNames") (EVar "names"))))) (arm (PCon "None") () (EApp (EApp (EMethodRef "map") (ELam ((PVar "names")) (EApp (EApp (EVar "Directive") (EVar "DScopeFile")) (EApp (EVar "parseRuleNames") (EVar "names"))))) (EApp (EApp (EVar "matchKeyword") (ELit (LString "lint-disable-file"))) (EVar "s"))))))))
(DTypeSig false "matchKeyword" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "matchKeyword" ((PVar "kw") (PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (EVar "kw")) (EVar "s")) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "kw"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "rest") (ELit (LString ""))) (EApp (EApp (EVar "startsWith") (ELit (LString " "))) (EVar "rest"))) (EApp (EApp (EVar "startsWith") (ELit (LString "\t"))) (EVar "rest"))) (EApp (EVar "Some") (EApp (EVar "trimWs") (EVar "rest"))) (EVar "None")))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "parseRuleNames" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "parseRuleNames" ((PVar "s")) (EApp (EApp (EVar "filterList") (EVar "nonEmptyStr")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "splitOnChar") (ELit (LChar " ")))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar ","))) (EVar "s")))))
(DTypeSig false "nonEmptyStr" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nonEmptyStr" ((PVar "n")) (EBinOp "!=" (EVar "n") (ELit (LString ""))))
(DTypeSig false "isSuppressed" (TyFun (TyApp (TyCon "List") (TyCon "Directive")) (TyFun (TyCon "Finding") (TyCon "Bool"))))
(DFunDef false "isSuppressed" ((PVar "dirs") (PVar "f")) (EApp (EApp (EVar "anyList") (EApp (EVar "dirCoversFinding") (EVar "f"))) (EVar "dirs")))
(DTypeSig false "dirCoversFinding" (TyFun (TyCon "Finding") (TyFun (TyCon "Directive") (TyCon "Bool"))))
(DFunDef false "dirCoversFinding" ((PVar "f") (PCon "Directive" (PVar "scope") (PVar "names"))) (EBinOp "&&" (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "names")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "f") "rule")) (EVar "names"))) (EApp (EApp (EVar "scopeMatches") (EApp (EVar "findingLineNo") (EVar "f"))) (EVar "scope"))))
(DTypeSig false "scopeMatches" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "DirScope") (TyCon "Bool"))))
(DFunDef false "scopeMatches" (PWild (PCon "DScopeFile")) (EVar "True"))
(DFunDef false "scopeMatches" ((PCon "Some" (PVar "line")) (PCon "DScopeLine" (PVar "l"))) (EBinOp "==" (EVar "line") (EVar "l")))
(DFunDef false "scopeMatches" ((PCon "None") (PCon "DScopeLine" PWild)) (EVar "False"))
(DTypeSig false "findingLineNo" (TyFun (TyCon "Finding") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "findingLineNo" ((PVar "f")) (EApp (EApp (EMethodRef "map") (ELam ((PCon "Loc" PWild (PVar "l") PWild PWild PWild)) (EVar "l"))) (EFieldAccess (EVar "f") "loc")))
(DTypeSig false "trimWs" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "trimWs" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "a") (EApp (EApp (EApp (EVar "trimWsStart") (EVar "cs")) (EVar "n")) (ELit (LInt 0)))) (DoLet false false (PVar "b") (EApp (EApp (EApp (EVar "trimWsEnd") (EVar "cs")) (EVar "a")) (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "stringSlice") (EVar "a")) (EVar "b")) (EVar "s")))))
(DTypeSig false "trimWsStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimWsStart" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "i") (EIf (EApp (EVar "isWsChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "trimWsStart") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "trimWsEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trimWsEnd" ((PVar "cs") (PVar "a") (PVar "n")) (EIf (EBinOp "<=" (EVar "n") (EVar "a")) (EVar "a") (EIf (EApp (EVar "isWsChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "cs"))) (EApp (EApp (EApp (EVar "trimWsEnd") (EVar "cs")) (EVar "a")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "n") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isWsChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isWsChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar " "))) (EBinOp "==" (EVar "c") (ELit (LChar "\t")))) (EBinOp "==" (EVar "c") (ELit (LChar "\r")))) (EBinOp "==" (EVar "c") (ELit (LChar "\n")))))
(DTypeSig false "unwrapLoc" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "unwrapLoc" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "unwrapLoc") (EVar "e")))
(DFunDef false "unwrapLoc" ((PVar "e")) (EVar "e"))
(DTypeSig false "declLocList" (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "declLocList" ((PVar "pos") (PVar "prog")) (EApp (EApp (EVar "zipDeclLoc") (EVar "prog")) (EApp (EVar "positionsDecls") (EVar "pos"))))
(DTypeSig false "zipDeclLoc" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "zipDeclLoc" ((PList) PWild) (EListLit))
(DFunDef false "zipDeclLoc" ((PCons (PVar "d") (PVar "ds")) (PList)) (EBinOp "::" (ETuple (EVar "d") (EVar "None")) (EApp (EApp (EVar "zipDeclLoc") (EVar "ds")) (EListLit))))
(DFunDef false "zipDeclLoc" ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EBinOp "::" (ETuple (EVar "d") (EApp (EVar "Some") (EApp (EVar "declPosToLoc") (EVar "p")))) (EApp (EApp (EVar "zipDeclLoc") (EVar "ds")) (EVar "ps"))))
(DTypeSig false "declPosToLoc" (TyFun (TyCon "DeclPos") (TyCon "Loc")))
(DFunDef false "declPosToLoc" ((PVar "p")) (ELet false (PVar "l") (EApp (EVar "declPosLine") (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "l")) (ELit (LInt 1))) (EVar "l")) (ELit (LInt 1)))))
(DTypeSig false "ruleMatchOnParam" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleMatchOnParam" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "matchParamDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "matchParamDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "matchParamDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "matchParamDecl") (EVar "loc")) (EVar "d")))
(DTypeSig false "matchParamDecl" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "matchParamDecl" ((PVar "loc") (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "matchParamFinding") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "body")))
(DFunDef false "matchParamDecl" ((PVar "loc") (PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "matchParamMethod") (EVar "loc"))) (EVar "methods")))
(DFunDef false "matchParamDecl" ((PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "matchParamDecl") (EVar "loc")) (EVar "d")))
(DFunDef false "matchParamDecl" (PWild PWild) (EListLit))
(DTypeSig false "matchParamMethod" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "matchParamMethod" ((PVar "loc") (PCon "ImplMethod" (PVar "name") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "matchParamFinding") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "body")))
(DTypeSig false "matchParamFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "matchParamFinding" ((PVar "loc") (PVar "name") (PVar "pats") (PVar "body")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EMatch" (PVar "scrut") (PVar "arms")) () (EApp (EApp (EApp (EApp (EApp (EVar "matchParamArms") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "scrut")) (EVar "arms"))) (arm PWild () (EListLit))))
(DTypeSig false "matchParamArms" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "matchParamArms" ((PVar "loc") (PVar "name") (PVar "pats") (PVar "scrut") (PVar "arms")) (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "arms")) (ELit (LInt 2))) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EVar "unwrapLoc") (EVar "scrut")) (arm (PCon "EVar" (PVar "p")) () (EApp (EApp (EApp (EApp (EVar "matchParamHit") (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "p"))) (arm PWild () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchParamHit" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "matchParamHit" ((PVar "loc") (PVar "name") (PVar "pats") (PVar "p")) (EIf (EApp (EApp (EVar "anyList") (EApp (EVar "isBareParam") (EVar "p"))) (EVar "pats")) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameMatchParam")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' matches on parameter '"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "' — use a multi-clause function definition")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc"))))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isBareParam" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "isBareParam" ((PVar "p") (PCon "PVar" (PVar "q") PWild)) (EBinOp "==" (EVar "p") (EVar "q")))
(DFunDef false "isBareParam" (PWild PWild) (EVar "False"))
(DTypeSig false "matchParamFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "matchParamFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EMatch (EApp (EApp (EVar "matchBodyOnBareParam") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PTuple (PVar "p") (PVar "k") (PVar "arms"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "matchParamFixArms") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "p")) (EVar "k")) (EVar "arms"))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "matchParamFix" (PWild PWild) (EVar "None"))
(DTypeSig false "matchParamFixArms" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "matchParamFixArms" ((PVar "vis") (PVar "name") (PVar "pats") (PVar "p") (PVar "k") (PVar "arms")) (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "arms")) (ELit (LInt 2))) (EVar "None") (EIf (EApp (EApp (EVar "anyList") (EVar "armHasGuard")) (EVar "arms")) (EVar "None") (EIf (EApp (EApp (EVar "anyList") (EApp (EVar "armUnsafeMention") (EVar "p"))) (EVar "arms")) (EVar "None") (EIf (EVar "otherwise") (EApp (EVar "Some") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EApp (EVar "armToClause") (EVar "vis")) (EVar "name")) (EVar "p")) (EVar "pats")) (EVar "k"))) (EVar "arms"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "matchBodyOnBareParam" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int") (TyApp (TyCon "List") (TyCon "Arm")))))))
(DFunDef false "matchBodyOnBareParam" ((PVar "pats") (PVar "body")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EMatch" (PVar "scrut") (PVar "arms")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "scrut")) (arm (PCon "EVar" (PVar "p")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "k")) (ETuple (EVar "p") (EVar "k") (EVar "arms")))) (EApp (EApp (EVar "paramIndex") (EVar "p")) (EVar "pats")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "armHasGuard" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armHasGuard" ((PCon "Arm" PWild (PVar "guards") PWild)) (EApp (EVar "isNonEmptyL") (EVar "guards")))
(DTypeSig false "armMentionsParam" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armMentionsParam" ((PVar "p") (PCon "Arm" PWild PWild (PVar "body"))) (EApp (EApp (EVar "wholeWordIn") (EVar "p")) (EApp (EVar "exprToString") (EVar "body"))))
(DTypeSig false "armUnsafeMention" (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "armUnsafeMention" ((PVar "p") (PVar "arm")) (EBinOp "&&" (EApp (EApp (EVar "armMentionsParam") (EVar "p")) (EVar "arm")) (EApp (EVar "not") (EApp (EVar "armPatIsWild") (EVar "arm")))))
(DTypeSig false "armPatIsWild" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armPatIsWild" ((PCon "Arm" (PVar "pat") PWild PWild)) (EApp (EVar "patIsWild") (EVar "pat")))
(DTypeSig false "patIsWild" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patIsWild" ((PCon "PWild")) (EVar "True"))
(DFunDef false "patIsWild" (PWild) (EVar "False"))
(DTypeSig false "paramIndex" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "paramIndex" ((PVar "p") (PVar "pats")) (EApp (EApp (EApp (EVar "paramIndexGo") (EVar "p")) (EVar "pats")) (ELit (LInt 0))))
(DTypeSig false "paramIndexGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "paramIndexGo" (PWild (PList) PWild) (EVar "None"))
(DFunDef false "paramIndexGo" ((PVar "p") (PCons (PVar "pat") (PVar "rest")) (PVar "i")) (EIf (EApp (EApp (EVar "isBareParam") (EVar "p")) (EVar "pat")) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "paramIndexGo") (EVar "p")) (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "armToClause" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Int") (TyFun (TyCon "Arm") (TyCon "Decl"))))))))
(DFunDef false "armToClause" ((PVar "vis") (PVar "name") (PVar "p") (PVar "pats") (PVar "k") (PCon "Arm" (PVar "pat") PWild (PVar "body"))) (EBlock (DoLet false false (PVar "cpat") (EIf (EBinOp "&&" (EApp (EVar "patIsWild") (EVar "pat")) (EApp (EApp (EVar "wholeWordIn") (EVar "p")) (EApp (EVar "exprToString") (EVar "body")))) (EApp (EApp (EVar "PVar") (EVar "p")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EApp (EApp (EApp (EVar "replaceAt") (EVar "k")) (EVar "cpat")) (EVar "pats"))) (EVar "body")))))
(DTypeSig false "replaceAt" (TyFun (TyCon "Int") (TyFun (TyVar "a") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "replaceAt" (PWild PWild (PList)) (EListLit))
(DFunDef false "replaceAt" ((PLit (LInt 0)) (PVar "x") (PCons PWild (PVar "rest"))) (EBinOp "::" (EVar "x") (EVar "rest")))
(DFunDef false "replaceAt" ((PVar "n") (PVar "x") (PCons (PVar "y") (PVar "rest"))) (EBinOp "::" (EVar "y") (EApp (EApp (EApp (EVar "replaceAt") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "x")) (EVar "rest"))))
(DTypeSig false "wholeWordIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "wholeWordIn" ((PVar "name") (PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "nlen") (EApp (EVar "stringLength") (EVar "name"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wholeWordGo") (EVar "name")) (EVar "nlen")) (EVar "s")) (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "wholeWordGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))))
(DFunDef false "wholeWordGo" ((PVar "name") (PVar "nlen") (PVar "s") (PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">" (EBinOp "+" (EVar "i") (EVar "nlen")) (EVar "n")) (EVar "False") (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "boundaryAt") (EVar "cs")) (EVar "i")) (EApp (EApp (EVar "boundaryAt") (EVar "cs")) (EBinOp "+" (EVar "i") (EVar "nlen")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (EVar "nlen"))) (EVar "s")) (EVar "name"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "wholeWordGo") (EVar "name")) (EVar "nlen")) (EVar "s")) (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "boundaryAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "boundaryAt" ((PVar "cs") (PVar "j")) (EIf (EBinOp "==" (EVar "j") (ELit (LInt 0))) (EVar "True") (EIf (EBinOp ">=" (EVar "j") (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "True") (EIf (EVar "otherwise") (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isAlnum") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "j") (ELit (LInt 1)))) (EVar "cs")))) (EApp (EVar "not") (EApp (EVar "isAlnum") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "cs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "ruleDestructureInParam" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleDestructureInParam" (PWild PWild (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "orc") (EApp (EVar "buildOracle") (EVar "prog"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EVar "destructureDeclL") (EVar "orc"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "destructureDeclL" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "destructureDeclL" ((PVar "orc") (PTuple (PVar "d") (PVar "loc"))) (EMatch (EVar "d") (arm (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EVar "destructureFinding") (EVar "orc")) (EVar "loc")) (EVar "name")) (EVar "pats")) (EVar "body"))) (arm PWild () (EListLit))))
(DTypeSig false "destructureFinding" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "destructureFinding" ((PVar "orc") (PVar "loc") (PVar "name") (PVar "pats") (PVar "body")) (EMatch (EApp (EApp (EVar "matchBodyOnBareParam") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PTuple (PVar "p") PWild (PVar "arms"))) () (EApp (EApp (EApp (EApp (EApp (EVar "destructureArmsFinding") (EVar "orc")) (EVar "loc")) (EVar "name")) (EVar "p")) (EVar "arms"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "destructureArmsFinding" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "destructureArmsFinding" ((PVar "orc") (PVar "loc") (PVar "name") (PVar "p") (PList (PVar "arm"))) (EIf (EApp (EApp (EApp (EVar "destructureArmFires") (EVar "orc")) (EVar "p")) (EVar "arm")) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDestructureInParam")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' destructures parameter '"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "' via a single-arm irrefutable `match`. Destructure it directly in the parameter position")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc"))))) (EListLit)))
(DFunDef false "destructureArmsFinding" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "destructureArmFires" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyFun (TyCon "Arm") (TyCon "Bool")))))
(DFunDef false "destructureArmFires" ((PVar "orc") (PVar "p") (PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "guards")) (EApp (EApp (EVar "destructurablePat") (EVar "orc")) (EVar "pat"))) (EApp (EVar "not") (EApp (EApp (EVar "wholeWordIn") (EVar "p")) (EApp (EVar "exprToString") (EVar "body"))))))
(DTypeSig false "destructurablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "destructurablePat" ((PVar "orc") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps")))
(DFunDef false "destructurablePat" ((PVar "orc") (PCon "PCon" (PVar "c") (PVar "ps"))) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps"))))
(DFunDef false "destructurablePat" ((PVar "orc") (PCon "PRec" (PVar "c") (PVar "fs") PWild)) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "recPatFieldIrrefutable") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "destructurablePat" (PWild PWild) (EVar "False"))
(DTypeSig false "patIrrefutable" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "patIrrefutable" (PWild (PCon "PVar" PWild PWild)) (EVar "True"))
(DFunDef false "patIrrefutable" (PWild (PCon "PWild")) (EVar "True"))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps")))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PCon" (PVar "c") (PVar "ps"))) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "patIrrefutable") (EVar "orc"))) (EVar "ps"))))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PRec" (PVar "c") (PVar "fs") PWild)) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EApp (EVar "allList") (EApp (EVar "recPatFieldIrrefutable") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "patIrrefutable" ((PVar "orc") (PCon "PAs" PWild PWild (PVar "p"))) (EApp (EApp (EVar "patIrrefutable") (EVar "orc")) (EVar "p")))
(DFunDef false "patIrrefutable" (PWild PWild) (EVar "False"))
(DTypeSig false "recPatFieldIrrefutable" (TyFun (TyCon "Oracle") (TyFun (TyCon "RecPatField") (TyCon "Bool"))))
(DFunDef false "recPatFieldIrrefutable" (PWild (PCon "RecPatField" PWild PWild (PCon "None"))) (EVar "True"))
(DFunDef false "recPatFieldIrrefutable" ((PVar "orc") (PCon "RecPatField" PWild PWild (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "patIrrefutable") (EVar "orc")) (EVar "p")))
(DTypeSig false "ctorIsSingle" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ctorIsSingle" ((PVar "orc") (PVar "c")) (EMatch (EApp (EApp (EVar "oGetCtorType") (EVar "orc")) (EVar "c")) (arm (PCon "Some" (PVar "t")) () (EMatch (EApp (EApp (EVar "oGetCtors") (EVar "orc")) (EVar "t")) (arm (PCon "Some" (PVar "ctors")) () (EBinOp "==" (EApp (EVar "listLen") (EVar "ctors")) (ELit (LInt 1)))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "destructureInParamFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "destructureInParamFix" ((PVar "orc") (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EMatch (EApp (EApp (EVar "matchBodyOnBareParam") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PTuple (PVar "p") (PVar "k") (PVar "arms"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "destructureInParamFixArms") (EVar "orc")) (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "p")) (EVar "k")) (EVar "arms"))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "destructureInParamFix" (PWild PWild) (EVar "None"))
(DTypeSig false "destructureInParamFixArms" (TyFun (TyCon "Oracle") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))))))
(DFunDef false "destructureInParamFixArms" ((PVar "orc") (PVar "vis") (PVar "name") (PVar "pats") (PVar "p") (PVar "k") (PList (PVar "arm"))) (EIf (EApp (EApp (EApp (EVar "destructureArmFires") (EVar "orc")) (EVar "p")) (EVar "arm")) (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "armToClause") (EVar "vis")) (EVar "name")) (EVar "p")) (EVar "pats")) (EVar "k")) (EVar "arm")))) (EVar "None")))
(DFunDef false "destructureInParamFixArms" (PWild PWild PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "derivableIfaces" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "derivableIfaces" () (EListLit (ELit (LString "Eq")) (ELit (LString "Ord")) (ELit (LString "Debug"))))
(DTypeSig false "ruleDerivable" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleDerivable" ((PVar "path") PWild (PVar "pos") (PVar "prog")) (EIf (EApp (EVar "isStdlibPath") (EVar "path")) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "orc") (EApp (EVar "buildOracle") (EVar "prog"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EVar "derivableDeclL") (EVar "orc"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "derivableDeclL" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "derivableDeclL" ((PVar "orc") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EApp (EVar "derivableDecl") (EVar "orc")) (EVar "loc")) (EVar "d")))
(DTypeSig false "derivableDecl" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "derivableDecl" ((PVar "orc") (PVar "loc") (PRec "DImpl" ((rf "iface" None) (rf "tys" None)) true)) (EApp (EApp (EApp (EApp (EVar "derivableHit") (EVar "orc")) (EVar "loc")) (EVar "iface")) (EVar "tys")))
(DFunDef false "derivableDecl" ((PVar "orc") (PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "derivableDecl") (EVar "orc")) (EVar "loc")) (EVar "d")))
(DFunDef false "derivableDecl" (PWild PWild PWild) (EListLit))
(DTypeSig false "derivableHit" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "derivableHit" ((PVar "orc") (PVar "loc") (PVar "iface") (PVar "tys")) (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EVar "derivableIfaces")) (EMatch (EApp (EVar "singleNamedType") (EVar "tys")) (arm (PCon "Some" (PVar "tyName")) () (EIf (EApp (EApp (EVar "hasUserDataDecl") (EVar "orc")) (EVar "tyName")) (EListLit (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDerivable")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "hand-written `impl ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "` for '"))) (EApp (EMethodRef "display") (EVar "tyName"))) (ELit (LString "' — use `deriving ("))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString ")`")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc"))))) (EListLit))) (arm (PCon "None") () (EListLit))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hasUserDataDecl" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasUserDataDecl" ((PVar "orc") (PVar "tyName")) (EMatch (EApp (EApp (EVar "oGetCtors") (EVar "orc")) (EVar "tyName")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "singleNamedType" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "singleNamedType" ((PList (PVar "t"))) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "singleNamedType" (PWild) (EVar "None"))
(DTypeSig false "tyHeadName" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "tyHeadName" ((PCon "TyCon" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "tyHeadName" ((PCon "TyApp" (PVar "f") PWild)) (EApp (EVar "tyHeadName") (EVar "f")))
(DFunDef false "tyHeadName" (PWild) (EVar "None"))
(DTypeSig false "stdlibNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "stdlibNames" () (EListLit (ELit (LString "reverse")) (ELit (LString "take")) (ELit (LString "drop")) (ELit (LString "map")) (ELit (LString "filter")) (ELit (LString "flatMap")) (ELit (LString "concatMap")) (ELit (LString "foldl")) (ELit (LString "foldr")) (ELit (LString "length")) (ELit (LString "elem")) (ELit (LString "intercalate")) (ELit (LString "intersperse")) (ELit (LString "zip")) (ELit (LString "zipWith"))))
(DTypeSig false "ruleStdlibReimpl" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleStdlibReimpl" ((PVar "path") PWild (PVar "pos") (PVar "prog")) (EIf (EApp (EVar "isStdlibPath") (EVar "path")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "map") (EVar "stdlibFinding")) (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EVar "filterList") (EVar "inStdlibPair")) (EApp (EApp (EDictApp "flatMap") (EVar "topDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "topDefNameL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "topDefNameL" ((PTuple (PCon "DFunDef" PWild (PVar "name") PWild PWild) (PVar "loc"))) (EListLit (ETuple (EVar "name") (EVar "loc"))))
(DFunDef false "topDefNameL" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "topDefNameL") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "topDefNameL" (PWild) (EListLit))
(DTypeSig false "inStdlibPair" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool")))
(DFunDef false "inStdlibPair" ((PTuple (PVar "n") PWild)) (EApp (EVar "inStdlib") (EVar "n")))
(DTypeSig false "dedupeNamesLoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "dedupeNamesLoc" ((PVar "xs")) (EApp (EApp (EVar "dedupBy") (EVar "fst")) (EVar "xs")))
(DTypeSig false "inStdlib" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "inStdlib" ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "stdlibNames")))
(DTypeSig false "stdlibFinding" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding")))
(DFunDef false "stdlibFinding" ((PTuple (PVar "name") (PVar "loc"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameStdlibReimpl")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level '")) (EVar "name")) (ELit (LString "' shadows a stdlib function — use the stdlib version")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "ruleMissingSignature" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleMissingSignature" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EMethodRef "map") (EVar "missingSigFinding")) (EApp (EApp (EVar "filterList") (EApp (EVar "missingSigPair") (EApp (EVar "nameSetOf") (EApp (EApp (EDictApp "flatMap") (EVar "topSigNameL")) (EVar "prog"))))) (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EDictApp "flatMap") (EVar "topDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))))
(DTypeSig false "topSigNameL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topSigNameL" ((PCon "DTypeSig" PWild (PVar "name") PWild)) (EListLit (EVar "name")))
(DFunDef false "topSigNameL" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topSigNameL") (EVar "d")))
(DFunDef false "topSigNameL" (PWild) (EListLit))
(DTypeSig false "missingSigPair" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "missingSigPair" ((PVar "sigNames") (PTuple (PVar "n") PWild)) (EApp (EVar "not") (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "main"))) (EApp (EApp (EVar "has") (EVar "n")) (EVar "sigNames")))))
(DTypeSig false "missingSigFinding" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding")))
(DFunDef false "missingSigFinding" ((PTuple (PVar "name") (PVar "loc"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameMissingSignature")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' has no type signature. Add a `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " : …` declaration")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "ruleSelfShadowExtern" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleSelfShadowExtern" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EVar "selfShadowFindings") (EApp (EApp (EDictApp "flatMap") (EVar "selfShadowClauseL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))
(DTypeSig false "selfShadowFindings" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "selfShadowFindings" ((PVar "clauses")) (EApp (EApp (EMethodRef "map") (EVar "selfShadowFinding")) (EApp (EApp (EVar "filterList") (EApp (EVar "allClausesSelfCall") (EVar "clauses"))) (EApp (EApp (EVar "dedupBy") (EVar "fst")) (EApp (EApp (EMethodRef "map") (EVar "clauseNameLoc")) (EVar "clauses"))))))
(DTypeSig false "selfShadowClauseL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "selfShadowClauseL" ((PTuple (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body")) (PVar "loc"))) (EListLit (ETuple (EVar "name") (EVar "pats") (EVar "body") (EVar "loc"))))
(DFunDef false "selfShadowClauseL" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "selfShadowClauseL") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "selfShadowClauseL" (PWild) (EListLit))
(DTypeSig false "clauseNameLoc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "clauseNameLoc" ((PTuple (PVar "n") PWild PWild (PVar "l"))) (ETuple (EVar "n") (EVar "l")))
(DTypeSig false "allClausesSelfCall" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "allClausesSelfCall" ((PVar "clauses") (PTuple (PVar "name") PWild)) (EApp (EApp (EVar "allList") (EApp (EVar "clauseSelfCallOrOther") (EVar "name"))) (EVar "clauses")))
(DTypeSig false "clauseSelfCallOrOther" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "clauseSelfCallOrOther" ((PVar "name") (PTuple (PVar "cn") (PVar "pats") (PVar "body") PWild)) (EBinOp "||" (EBinOp "!=" (EVar "cn") (EVar "name")) (EApp (EApp (EApp (EVar "unconditionalSelfCall") (EVar "name")) (EVar "pats")) (EVar "body"))))
(DTypeSig false "unconditionalSelfCall" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "unconditionalSelfCall" ((PVar "name") (PList) (PVar "body")) (EApp (EApp (EVar "isBareSelf") (EVar "name")) (EApp (EVar "stripWrap") (EVar "body"))))
(DFunDef false "unconditionalSelfCall" ((PVar "name") PWild (PVar "body")) (EApp (EApp (EVar "isHeadSelfApp") (EVar "name")) (EApp (EVar "stripWrap") (EVar "body"))))
(DTypeSig false "stripWrap" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripWrap" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stripWrap") (EVar "e")))
(DFunDef false "stripWrap" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "stripWrap") (EVar "e")))
(DFunDef false "stripWrap" ((PVar "e")) (EVar "e"))
(DTypeSig false "isBareSelf" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isBareSelf" ((PVar "name") (PCon "EVar" (PVar "w"))) (EBinOp "==" (EVar "name") (EVar "w")))
(DFunDef false "isBareSelf" (PWild PWild) (EVar "False"))
(DTypeSig false "isHeadSelfApp" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isHeadSelfApp" ((PVar "name") (PCon "EApp" (PVar "f") (PVar "a"))) (EApp (EApp (EVar "isBareSelf") (EVar "name")) (EApp (EVar "appHead") (EApp (EVar "stripWrap") (EVar "f")))))
(DFunDef false "isHeadSelfApp" (PWild PWild) (EVar "False"))
(DTypeSig false "appHead" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "appHead" ((PVar "e")) (EMatch (EApp (EVar "stripWrap") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EVar "appHead") (EVar "f"))) (arm (PVar "x") () (EVar "x"))))
(DTypeSig false "selfShadowFinding" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding")))
(DFunDef false "selfShadowFinding" ((PTuple (PVar "name") (PVar "loc"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameSelfShadowExtern")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' unconditionally calls itself with no base case — an infinite self-recursion, not a forward to a same-named extern/definition. Rename the binding (give it a distinct name) or add a terminating `match`/`if`/guard")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "irrefutablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "irrefutablePat" (PWild (PCon "PVar" PWild PWild)) (EVar "True"))
(DFunDef false "irrefutablePat" (PWild (PCon "PWild")) (EVar "True"))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutablePat") (EVar "orc"))) (EVar "ps"))))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutableField") (EVar "orc"))) (EVar "fields"))))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PCon" (PVar "c") (PVar "subps"))) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSole") (EVar "orc")) (EVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutablePat") (EVar "orc"))) (EVar "subps")))))
(DFunDef false "irrefutablePat" (PWild PWild) (EVar "False"))
(DTypeSig false "ctorIsSole" (TyFun (TyCon "Oracle") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ctorIsSole" ((PVar "orc") (PVar "c")) (EMatch (EApp (EApp (EVar "oGetCtorType") (EVar "orc")) (EVar "c")) (arm (PCon "Some" (PVar "tyName")) () (EMatch (EApp (EApp (EVar "oGetCtors") (EVar "orc")) (EVar "tyName")) (arm (PCon "Some" (PVar "ctors")) () (EBinOp "==" (EApp (EVar "listLen") (EVar "ctors")) (ELit (LInt 1)))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "refutablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "refutablePat" ((PVar "orc") (PVar "p")) (EApp (EVar "not") (EApp (EApp (EVar "irrefutablePat") (EVar "orc")) (EVar "p"))))
(DTypeSig false "refutableField" (TyFun (TyCon "Oracle") (TyFun (TyCon "RecPatField") (TyCon "Bool"))))
(DFunDef false "refutableField" (PWild (PCon "RecPatField" PWild PWild (PCon "None"))) (EVar "False"))
(DFunDef false "refutableField" ((PVar "orc") (PCon "RecPatField" PWild PWild (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "refutablePat") (EVar "orc")) (EVar "p")))
(DTypeSig false "bindMatchTail" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "String") (TyCon "Pat") (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "bindMatchTail" ((PVar "orc") (PVar "stmts")) (EMatch (EApp (EVar "splitTail2") (EVar "stmts")) (arm (PCon "Some" (PTuple (PVar "prefix") (PCon "DoBind" (PCon "PVar" (PVar "v") PWild) (PVar "boundE")) (PCon "DoExpr" (PVar "matchE")))) () (EApp (EApp (EApp (EApp (EApp (EVar "bindMatchArm") (EVar "orc")) (EVar "prefix")) (EVar "v")) (EVar "boundE")) (EApp (EVar "unwrapLoc") (EVar "matchE")))) (arm PWild () (EVar "None"))))
(DTypeSig false "bindMatchArm" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "String") (TyCon "Pat") (TyCon "Expr") (TyCon "Expr")))))))))
(DFunDef false "bindMatchArm" ((PVar "orc") (PVar "prefix") (PVar "v") (PVar "boundE") (PCon "EMatch" (PVar "scrut") (PList (PCon "Arm" (PVar "pat") (PList) (PVar "body"))))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "scrutIsVar") (EVar "v")) (EApp (EVar "unwrapLoc") (EVar "scrut"))) (EApp (EApp (EVar "irrefutablePat") (EVar "orc")) (EVar "pat"))) (EApp (EVar "not") (EApp (EApp (EVar "wholeWordIn") (EVar "v")) (EApp (EVar "exprToString") (EVar "body"))))) (EApp (EVar "Some") (ETuple (EVar "prefix") (EVar "v") (EVar "pat") (EVar "boundE") (EVar "body"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "bindMatchArm" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "scrutIsVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "scrutIsVar" ((PVar "v") (PCon "EVar" (PVar "w"))) (EBinOp "==" (EVar "v") (EVar "w")))
(DFunDef false "scrutIsVar" (PWild PWild) (EVar "False"))
(DTypeSig false "splitTail2" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "DoStmt") (TyCon "DoStmt")))))
(DFunDef false "splitTail2" ((PVar "stmts")) (EMatch (EApp (EVar "reverseL") (EVar "stmts")) (arm (PCons (PVar "lst") (PCons (PVar "scd") (PVar "restRev"))) () (EApp (EVar "Some") (ETuple (EApp (EVar "reverseL") (EVar "restRev")) (EVar "scd") (EVar "lst")))) (arm PWild () (EVar "None"))))
(DTypeSig false "ruleBindThenDestructure" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleBindThenDestructure" (PWild PWild (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "orc") (EApp (EVar "buildOracle") (EVar "prog"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EVar "bindDestructureDeclL") (EVar "orc"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "bindDestructureDeclL" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "bindDestructureDeclL" ((PVar "orc") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "bindDestructureFinding") (EVar "loc"))) (EApp (EApp (EVar "declBindHits") (EVar "orc")) (EVar "d"))))
(DTypeSig false "declBindHits" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declBindHits" ((PVar "orc") (PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EApp (EVar "collectBindHits") (EVar "orc")) (EVar "body")))
(DFunDef false "declBindHits" ((PVar "orc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declBindHits") (EVar "orc")) (EVar "d")))
(DFunDef false "declBindHits" (PWild PWild) (EListLit))
(DTypeSig false "bindDestructureFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "bindDestructureFinding" ((PVar "loc") (PVar "v")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameBindThenDestructure")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "binds '")) (EVar "v")) (ELit (LString "' then immediately destructures it in a final `match`. Inline the pattern into the bind")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "collectBindHits" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectBindHits" ((PVar "orc") (PVar "e")) (EBinOp "++" (EApp (EApp (EVar "tailHitOf") (EVar "orc")) (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "collectBindHits") (EVar "orc"))) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "tailHitOf" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tailHitOf" ((PVar "orc") (PCon "EDo" (PVar "stmts"))) (EApp (EApp (EVar "hitNameOf") (EVar "orc")) (EVar "stmts")))
(DFunDef false "tailHitOf" ((PVar "orc") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "hitNameOf") (EVar "orc")) (EVar "stmts")))
(DFunDef false "tailHitOf" (PWild PWild) (EListLit))
(DTypeSig false "hitNameOf" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "hitNameOf" ((PVar "orc") (PVar "stmts")) (EMatch (EApp (EApp (EVar "bindMatchTail") (EVar "orc")) (EVar "stmts")) (arm (PCon "Some" (PTuple PWild (PVar "v") PWild PWild PWild)) () (EListLit (EVar "v"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "childExprs" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "childExprs" ((PCon "ELoc" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EDoOrigin" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EApp" (PVar "f") (PVar "x"))) (EListLit (EVar "f") (EVar "x")))
(DFunDef false "childExprs" ((PCon "ELam" PWild (PVar "b"))) (EListLit (EVar "b")))
(DFunDef false "childExprs" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EListLit (EVar "e1") (EVar "e2")))
(DFunDef false "childExprs" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EBinOp "::" (EVar "s") (EApp (EApp (EDictApp "flatMap") (EVar "armExprs")) (EVar "arms"))))
(DFunDef false "childExprs" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EListLit (EVar "c") (EVar "t") (EVar "el")))
(DFunDef false "childExprs" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EListLit (EVar "a") (EVar "b")))
(DFunDef false "childExprs" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EListLit (EVar "a")))
(DFunDef false "childExprs" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EListLit (EVar "a") (EVar "b")))
(DFunDef false "childExprs" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "ETuple" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EListLit" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EArrayLit" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") PWild PWild)) (EListLit (EVar "e") (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "letBindExprs")) (EVar "binds")) (EListLit (EVar "body"))))
(DFunDef false "childExprs" ((PCon "ESection" (PVar "s"))) (EApp (EVar "sectionExprs") (EVar "s")))
(DFunDef false "childExprs" ((PCon "EIndex" (PVar "a") (PVar "i") PWild)) (EListLit (EVar "a") (EVar "i")))
(DFunDef false "childExprs" ((PCon "EAnnot" (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "stmtExprs")) (EVar "stmts")))
(DFunDef false "childExprs" ((PCon "EDo" (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "stmtExprs")) (EVar "stmts")))
(DFunDef false "childExprs" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EDictApp "flatMap") (EVar "interpPartExprs")) (EVar "parts")))
(DFunDef false "childExprs" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EDictApp "flatMap") (EVar "guardArmExprs")) (EVar "arms")))
(DFunDef false "childExprs" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EMethodRef "map") (EVar "fieldAssignExpr")) (EVar "fs")))
(DFunDef false "childExprs" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EBinOp "::" (EVar "e") (EApp (EApp (EMethodRef "map") (EVar "fieldAssignExpr")) (EVar "fs"))))
(DFunDef false "childExprs" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "::" (EVar "e") (EApp (EApp (EMethodRef "map") (EVar "fieldAssignExpr")) (EVar "fs"))))
(DFunDef false "childExprs" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EDictApp "flatMap") (EVar "kvExprs")) (EVar "kvs")))
(DFunDef false "childExprs" ((PCon "ESetLit" PWild (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EAsPat" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" (PWild) (EListLit))
(DTypeSig false "armExprs" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "armExprs" ((PCon "Arm" PWild (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "guardExprs")) (EVar "gs")) (EListLit (EVar "body"))))
(DTypeSig false "guardExprs" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "guardExprs" ((PCon "GBool" (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "guardExprs" ((PCon "GBind" PWild (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig false "stmtExprs" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "stmtExprs" ((PCon "DoExpr" (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoBind" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoLet" PWild PWild PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoAssign" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig false "letBindExprs" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "letBindExprs" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EDictApp "flatMap") (EVar "funClauseExprs")) (EVar "clauses")))
(DTypeSig false "funClauseExprs" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "funClauseExprs" ((PCon "FunClause" PWild (PVar "body"))) (EListLit (EVar "body")))
(DTypeSig false "sectionExprs" (TyFun (TyCon "Section") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "sectionExprs" ((PCon "SecBare" PWild)) (EListLit))
(DFunDef false "sectionExprs" ((PCon "SecRight" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "sectionExprs" ((PCon "SecLeft" (PVar "e") PWild)) (EListLit (EVar "e")))
(DTypeSig false "interpPartExprs" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "interpPartExprs" ((PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "interpPartExprs" ((PCon "InterpExpr" (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig false "guardArmExprs" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "guardArmExprs" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "guardExprs")) (EVar "gs")) (EListLit (EVar "body"))))
(DTypeSig false "fieldAssignExpr" (TyFun (TyCon "FieldAssign") (TyCon "Expr")))
(DFunDef false "fieldAssignExpr" ((PCon "FieldAssign" PWild (PVar "e"))) (EVar "e"))
(DTypeSig false "kvExprs" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "kvExprs" ((PTuple (PVar "k") (PVar "v"))) (EListLit (EVar "k") (EVar "v")))
(DTypeSig false "bindThenDestructureFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "bindThenDestructureFix" ((PVar "orc") (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "body2") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2"))))))))
(DFunDef false "bindThenDestructureFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "bindThenDestructureFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "bindThenDestructureFix" (PWild PWild) (EVar "None"))
(DTypeSig false "rewriteBindExpr" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "f"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "x"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "b"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e1"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e2"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "s"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindArm") (EVar "orc"))) (EVar "arms"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "c"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "t"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "el"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "b"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "lo"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "lo"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "lo"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "hi"))) (EVar "i")) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindLet") (EVar "orc"))) (EVar "binds"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EApp (EVar "rewriteBindSection") (EVar "orc")) (EVar "s"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EIndex" (PVar "a") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "i"))) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "collapseBindTail") (EVar "orc")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindStmt") (EVar "orc"))) (EVar "stmts")))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EVar "collapseBindTail") (EVar "orc")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindStmt") (EVar "orc"))) (EVar "stmts")))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindInterp") (EVar "orc"))) (EVar "parts"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindGuardArm") (EVar "orc"))) (EVar "arms"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindField") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindField") (EVar "orc"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindField") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindKv") (EVar "orc"))) (EVar "kvs"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindExpr" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "collapseBindTail" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "collapseBindTail" ((PVar "orc") (PVar "stmts")) (EMatch (EApp (EApp (EVar "bindMatchTail") (EVar "orc")) (EVar "stmts")) (arm (PCon "Some" (PTuple (PVar "prefix") PWild (PVar "pat") (PVar "boundE") (PVar "body"))) () (EBinOp "++" (EVar "prefix") (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "pat")) (EVar "boundE")) (EApp (EVar "bodyToStmts") (EVar "body"))))) (arm (PCon "None") () (EVar "stmts"))))
(DTypeSig false "bodyToStmts" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "bodyToStmts" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EDo" (PVar "stmts")) () (EVar "stmts")) (arm (PCon "EBlock" (PVar "stmts")) () (EVar "stmts")) (arm PWild () (EListLit (EApp (EVar "DoExpr") (EVar "e"))))))
(DTypeSig false "rewriteBindStmt" (TyFun (TyCon "Oracle") (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindArm" (TyFun (TyCon "Oracle") (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "rewriteBindArm" ((PVar "orc") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindGuard") (EVar "orc"))) (EVar "gs"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DTypeSig false "rewriteBindGuard" (TyFun (TyCon "Oracle") (TyFun (TyCon "Guard") (TyCon "Guard"))))
(DFunDef false "rewriteBindGuard" ((PVar "orc") (PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindGuard" ((PVar "orc") (PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindLet" (TyFun (TyCon "Oracle") (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "rewriteBindLet" ((PVar "orc") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindClause") (EVar "orc"))) (EVar "clauses"))))
(DTypeSig false "rewriteBindClause" (TyFun (TyCon "Oracle") (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "rewriteBindClause" ((PVar "orc") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DTypeSig false "rewriteBindSection" (TyFun (TyCon "Oracle") (TyFun (TyCon "Section") (TyCon "Section"))))
(DFunDef false "rewriteBindSection" (PWild (PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteBindSection" ((PVar "orc") (PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindSection" ((PVar "orc") (PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteBindInterp" (TyFun (TyCon "Oracle") (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "rewriteBindInterp" (PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteBindInterp" ((PVar "orc") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindGuardArm" (TyFun (TyCon "Oracle") (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "rewriteBindGuardArm" ((PVar "orc") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindGuard") (EVar "orc"))) (EVar "gs"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DTypeSig false "rewriteBindField" (TyFun (TyCon "Oracle") (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "rewriteBindField" ((PVar "orc") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindKv" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "rewriteBindKv" ((PVar "orc") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "k")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "v"))))
(DTypeSig false "sectionSymOps" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "sectionSymOps" () (EListLit (ELit (LString "+")) (ELit (LString "*")) (ELit (LString "/")) (ELit (LString "==")) (ELit (LString "!=")) (ELit (LString "<")) (ELit (LString ">")) (ELit (LString "<=")) (ELit (LString ">=")) (ELit (LString "&&")) (ELit (LString "||")) (ELit (LString "::")) (ELit (LString "++")) (ELit (LString "|>")) (ELit (LString ">>")) (ELit (LString "<<"))))
(DTypeSig false "rightSectionOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "rightSectionOp" ((PVar "op")) (EApp (EApp (EVar "contains") (EVar "op")) (EVar "sectionSymOps")))
(DTypeSig false "leftSectionOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "leftSectionOp" ((PVar "op")) (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EApp (EApp (EVar "contains") (EVar "op")) (EVar "sectionSymOps"))))
(DTypeSig false "bareSectionOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "bareSectionOp" ((PVar "op")) (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EApp (EApp (EVar "contains") (EVar "op")) (EVar "sectionSymOps"))))
(DTypeSig false "isEVarNamed" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isEVarNamed" ((PVar "x") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "w")) () (EBinOp "==" (EVar "w") (EVar "x"))) (arm PWild () (EVar "False"))))
(DTypeSig false "mentionsVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "mentionsVar" ((PVar "x") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "w")) () (EBinOp "==" (EVar "w") (EVar "x"))) (arm (PVar "e2") () (EApp (EApp (EVar "anyList") (EApp (EVar "mentionsVar") (EVar "x"))) (EApp (EVar "childExprs") (EVar "e2"))))))
(DTypeSig false "lamSection" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Section")))))
(DFunDef false "lamSection" ((PList (PCon "PVar" (PVar "x") PWild)) (PVar "body")) (EApp (EApp (EVar "lamSection1") (EVar "x")) (EApp (EVar "unwrapLoc") (EVar "body"))))
(DFunDef false "lamSection" ((PList (PCon "PVar" (PVar "x") PWild) (PCon "PVar" (PVar "y") PWild)) (PVar "body")) (EIf (EBinOp "!=" (EVar "x") (EVar "y")) (EApp (EApp (EApp (EVar "lamSection2") (EVar "x")) (EVar "y")) (EApp (EVar "unwrapLoc") (EVar "body"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "lamSection" (PWild PWild) (EVar "None"))
(DTypeSig false "lamSection1" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Section")))))
(DFunDef false "lamSection1" ((PVar "x") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "a")) (EApp (EVar "rightSectionOp") (EVar "op"))) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "x")) (EVar "b")))) (EApp (EVar "Some") (EApp (EApp (EVar "SecRight") (EVar "op")) (EVar "b"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "b")) (EApp (EVar "leftSectionOp") (EVar "op"))) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "x")) (EVar "a")))) (EApp (EVar "Some") (EApp (EApp (EVar "SecLeft") (EVar "a")) (EVar "op"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "lamSection1" (PWild PWild) (EVar "None"))
(DTypeSig false "lamSection2" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Section"))))))
(DFunDef false "lamSection2" ((PVar "x") (PVar "y") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "a")) (EApp (EApp (EVar "isEVarNamed") (EVar "y")) (EVar "b"))) (EApp (EVar "bareSectionOp") (EVar "op"))) (EApp (EVar "Some") (EApp (EVar "SecBare") (EVar "op"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "lamSection2" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "ruleLambdaSection" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleLambdaSection" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "lambdaSectionDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "lambdaSectionDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "lambdaSectionDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "lambdaSectionFinding") (EVar "loc"))) (EApp (EVar "declLamSections") (EVar "d"))))
(DTypeSig false "declLamSections" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "declLamSections" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "collectLamSections") (EVar "body")))
(DFunDef false "declLamSections" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "implMethodLamSections")) (EVar "methods")))
(DFunDef false "declLamSections" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declLamSections") (EVar "d")))
(DFunDef false "declLamSections" (PWild) (EListLit))
(DTypeSig false "implMethodLamSections" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "implMethodLamSections" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectLamSections") (EVar "body")))
(DTypeSig false "collectLamSections" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "collectLamSections" ((PVar "e")) (EBinOp "++" (EApp (EVar "lamHitOf") (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EVar "collectLamSections")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "lamHitOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "lamHitOf" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EVar "optSectionToList") (EApp (EApp (EVar "lamSection") (EVar "pats")) (EVar "body"))))
(DFunDef false "lamHitOf" (PWild) (EListLit))
(DTypeSig false "optSectionToList" (TyFun (TyApp (TyCon "Option") (TyCon "Section")) (TyApp (TyCon "List") (TyCon "Section"))))
(DFunDef false "optSectionToList" ((PCon "Some" (PVar "s"))) (EListLit (EVar "s")))
(DFunDef false "optSectionToList" ((PCon "None")) (EListLit))
(DTypeSig false "lambdaSectionFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Section") (TyCon "Finding"))))
(DFunDef false "lambdaSectionFinding" ((PVar "loc") (PVar "s")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameLambdaSection")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "lambda is a single binary operation on its parameter(s). Rewrite as the operator section '")) (EApp (EVar "exprToString") (EApp (EVar "ESection") (EVar "s")))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "lambdaSectionFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "lambdaSectionFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteLamExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2"))))))))
(DFunDef false "lambdaSectionFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "lambdaSectionFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "lambdaSectionFix" (PWild (PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EMethodRef "map") (EVar "fixImplMethod")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (ERecordCreate "DImpl" ((fa "pub" (EVar "pub")) (fa "iface" (EVar "iface")) (fa "tys" (EVar "tys")) (fa "reqs" (EVar "reqs")) (fa "methods" (EVar "methods2"))))))))))
(DFunDef false "lambdaSectionFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethod" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethod" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "implMethodsBodyKey" (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyCon "String")))
(DFunDef false "implMethodsBodyKey" ((PVar "ms")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "implMethodBodySexp")) (EVar "ms"))))
(DTypeSig false "implMethodBodySexp" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodBodySexp" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "exprSexp") (EVar "body")))
(DTypeSig false "tryLamSection" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "tryLamSection" ((PVar "ps") (PVar "b")) (EMatch (EApp (EApp (EVar "lamSection") (EVar "ps")) (EVar "b")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "ESection") (EVar "s"))) (arm (PCon "None") () (EApp (EApp (EVar "ELam") (EVar "ps")) (EVar "b")))))
(DTypeSig false "rewriteLamExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteLamExpr" ((PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamExpr" ((PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamExpr" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EVar "rewriteLamExpr") (EVar "f"))) (EApp (EVar "rewriteLamExpr") (EVar "x"))))
(DFunDef false "rewriteLamExpr" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "tryLamSection") (EVar "ps")) (EApp (EVar "rewriteLamExpr") (EVar "b"))))
(DFunDef false "rewriteLamExpr" ((PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e1"))) (EApp (EVar "rewriteLamExpr") (EVar "e2"))))
(DFunDef false "rewriteLamExpr" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "rewriteLamExpr") (EVar "s"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamArm")) (EVar "arms"))))
(DFunDef false "rewriteLamExpr" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EVar "rewriteLamExpr") (EVar "c"))) (EApp (EVar "rewriteLamExpr") (EVar "t"))) (EApp (EVar "rewriteLamExpr") (EVar "el"))))
(DFunDef false "rewriteLamExpr" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EApp (EVar "rewriteLamExpr") (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EApp (EVar "rewriteLamExpr") (EVar "b"))))
(DFunDef false "rewriteLamExpr" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "rewriteLamExpr") (EVar "lo"))) (EApp (EVar "rewriteLamExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteLamExpr" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "rewriteLamExpr") (EVar "lo"))) (EApp (EVar "rewriteLamExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteLamExpr" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EApp (EVar "rewriteLamExpr") (EVar "lo"))) (EApp (EVar "rewriteLamExpr") (EVar "hi"))) (EVar "i")) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamLet")) (EVar "binds"))) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DFunDef false "rewriteLamExpr" ((PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EVar "rewriteLamSection") (EVar "s"))))
(DFunDef false "rewriteLamExpr" ((PCon "EIndex" (PVar "a") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EVar "rewriteLamExpr") (EVar "a"))) (EApp (EVar "rewriteLamExpr") (EVar "i"))) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteLamExpr" ((PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteLamExpr" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamStmt")) (EVar "stmts"))))
(DFunDef false "rewriteLamExpr" ((PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamStmt")) (EVar "stmts"))))
(DFunDef false "rewriteLamExpr" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamInterp")) (EVar "parts"))))
(DFunDef false "rewriteLamExpr" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamGuardArm")) (EVar "arms"))))
(DFunDef false "rewriteLamExpr" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamField")) (EVar "fs"))))
(DFunDef false "rewriteLamExpr" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamField")) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteLamExpr" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamField")) (EVar "fs"))))
(DFunDef false "rewriteLamExpr" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamKv")) (EVar "kvs"))))
(DFunDef false "rewriteLamExpr" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamExpr")) (EVar "es"))))
(DFunDef false "rewriteLamExpr" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamExpr" ((PVar "e")) (EVar "e"))
(DTypeSig false "rewriteLamStmt" (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))
(DFunDef false "rewriteLamStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamStmt" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamStmt" ((PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamArm" (TyFun (TyCon "Arm") (TyCon "Arm")))
(DFunDef false "rewriteLamArm" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamGuard")) (EVar "gs"))) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "rewriteLamGuard" (TyFun (TyCon "Guard") (TyCon "Guard")))
(DFunDef false "rewriteLamGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamLet" (TyFun (TyCon "LetBind") (TyCon "LetBind")))
(DFunDef false "rewriteLamLet" ((PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteLamClause")) (EVar "clauses"))))
(DTypeSig false "rewriteLamClause" (TyFun (TyCon "FunClause") (TyCon "FunClause")))
(DFunDef false "rewriteLamClause" ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "rewriteLamSection" (TyFun (TyCon "Section") (TyCon "Section")))
(DFunDef false "rewriteLamSection" ((PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteLamSection" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DFunDef false "rewriteLamSection" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "rewriteLamExpr") (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteLamInterp" (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))
(DFunDef false "rewriteLamInterp" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteLamInterp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamGuardArm" (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))
(DFunDef false "rewriteLamGuardArm" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EMethodRef "map") (EVar "rewriteLamGuard")) (EVar "gs"))) (EApp (EVar "rewriteLamExpr") (EVar "body"))))
(DTypeSig false "rewriteLamField" (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))
(DFunDef false "rewriteLamField" ((PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "rewriteLamExpr") (EVar "e"))))
(DTypeSig false "rewriteLamKv" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteLamKv" ((PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EVar "rewriteLamExpr") (EVar "k")) (EApp (EVar "rewriteLamExpr") (EVar "v"))))
(DTypeSig false "ifMaxMinCompareOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "ifMaxMinCompareOp" ((PVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (EBinOp "==" (EVar "op") (ELit (LString "<")))) (EBinOp "==" (EVar "op") (ELit (LString "<=")))))
(DTypeSig false "ifMaxMinFnNormal" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifMaxMinFnNormal" ((PVar "op")) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (ELit (LString "max")) (EIf (EVar "otherwise") (ELit (LString "min")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifMaxMinFnReversed" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifMaxMinFnReversed" ((PVar "op")) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (ELit (LString "min")) (EIf (EVar "otherwise") (ELit (LString "max")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isLiteralExpr" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isLiteralExpr" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" PWild) () (EVar "True")) (arm (PCon "ENumLit" PWild PWild PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "ifMaxMinOf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "ifMaxMinOf" ((PVar "cond") (PVar "t") (PVar "el")) (EMatch (EApp (EVar "unwrapLoc") (EVar "cond")) (arm (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild) ((GBool (EApp (EVar "ifMaxMinCompareOp") (EVar "op")))) (EBlock (DoLet false false (PVar "aK") (EApp (EVar "exprSexp") (EVar "a"))) (DoLet false false (PVar "bK") (EApp (EVar "exprSexp") (EVar "b"))) (DoLet false false (PVar "tK") (EApp (EVar "exprSexp") (EVar "t"))) (DoLet false false (PVar "eK") (EApp (EVar "exprSexp") (EVar "el"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "aK") (EVar "bK")) (EApp (EVar "isLiteralExpr") (EVar "a"))) (EApp (EVar "isLiteralExpr") (EVar "b"))) (EVar "None") (EIf (EBinOp "&&" (EBinOp "==" (EVar "tK") (EVar "aK")) (EBinOp "==" (EVar "eK") (EVar "bK"))) (EApp (EVar "Some") (ETuple (EApp (EVar "ifMaxMinFnNormal") (EVar "op")) (EVar "a") (EVar "b"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "tK") (EVar "bK")) (EBinOp "==" (EVar "eK") (EVar "aK"))) (EApp (EVar "Some") (ETuple (EApp (EVar "ifMaxMinFnReversed") (EVar "op")) (EVar "a") (EVar "b"))) (EVar "None"))))))) (arm PWild () (EVar "None"))))
(DTypeSig false "ruleIfMaxMin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleIfMaxMin" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ifMaxMinDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "ifMaxMinDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "ifMaxMinDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ifMaxMinFinding") (EVar "loc"))) (EApp (EVar "declIfMaxMinHits") (EVar "d"))))
(DTypeSig false "declIfMaxMinHits" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "declIfMaxMinHits" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "collectIfMaxMinHits") (EVar "body")))
(DFunDef false "declIfMaxMinHits" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "implMethodIfMaxMinHits")) (EVar "methods")))
(DFunDef false "declIfMaxMinHits" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declIfMaxMinHits") (EVar "d")))
(DFunDef false "declIfMaxMinHits" (PWild) (EListLit))
(DTypeSig false "implMethodIfMaxMinHits" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "implMethodIfMaxMinHits" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectIfMaxMinHits") (EVar "body")))
(DTypeSig false "collectIfMaxMinHits" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "collectIfMaxMinHits" ((PVar "e")) (EBinOp "++" (EApp (EVar "ifMaxMinHitOf") (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EVar "collectIfMaxMinHits")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "ifMaxMinHitOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "ifMaxMinHitOf" ((PCon "EIf" (PVar "cond") (PVar "t") (PVar "el"))) (EApp (EVar "optHitToList") (EApp (EApp (EApp (EVar "ifMaxMinOf") (EVar "cond")) (EVar "t")) (EVar "el"))))
(DFunDef false "ifMaxMinHitOf" (PWild) (EListLit))
(DTypeSig false "optHitToList" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "optHitToList" ((PCon "Some" (PVar "h"))) (EListLit (EVar "h")))
(DFunDef false "optHitToList" ((PCon "None")) (EListLit))
(DTypeSig false "ifMaxMinFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")) (TyCon "Finding"))))
(DFunDef false "ifMaxMinFinding" ((PVar "loc") (PTuple (PVar "fn") (PVar "a") (PVar "b"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameIfMaxMin")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if-then-else selects the ")) (EApp (EMethodRef "display") (EIf (EBinOp "==" (EVar "fn") (ELit (LString "max"))) (ELit (LString "larger")) (ELit (LString "smaller"))))) (ELit (LString " of the same two operands. Rewrite as '"))) (EApp (EMethodRef "display") (EApp (EVar "exprToString") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b"))))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "ifMaxMinFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "ifMaxMinFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2"))))))))
(DFunDef false "ifMaxMinFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "ifMaxMinFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "ifMaxMinFix" (PWild (PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EMethodRef "map") (EVar "fixImplMethodIfMaxMin")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (ERecordCreate "DImpl" ((fa "pub" (EVar "pub")) (fa "iface" (EVar "iface")) (fa "tys" (EVar "tys")) (fa "reqs" (EVar "reqs")) (fa "methods" (EVar "methods2"))))))))))
(DFunDef false "ifMaxMinFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodIfMaxMin" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethodIfMaxMin" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "tryIfMaxMin" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "tryIfMaxMin" ((PVar "cond") (PVar "t") (PVar "el")) (EMatch (EApp (EApp (EApp (EVar "ifMaxMinOf") (EVar "cond")) (EVar "t")) (EVar "el")) (arm (PCon "Some" (PTuple (PVar "fn") (PVar "a") (PVar "b"))) () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "EIf") (EVar "cond")) (EVar "t")) (EVar "el")))))
(DTypeSig false "rewriteIfMaxMinExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "f"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "x"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "b"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e1"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e2"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "s"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinArm")) (EVar "arms"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "tryIfMaxMin") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "c"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "t"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "el"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "b"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "lo"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "lo"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "lo"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "hi"))) (EVar "i")) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinLet")) (EVar "binds"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EVar "rewriteIfMaxMinSection") (EVar "s"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EIndex" (PVar "a") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "i"))) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinStmt")) (EVar "stmts"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinStmt")) (EVar "stmts"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinInterp")) (EVar "parts"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinGuardArm")) (EVar "arms"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinField")) (EVar "fs"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinField")) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinField")) (EVar "fs"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinKv")) (EVar "kvs"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PVar "e")) (EVar "e"))
(DTypeSig false "rewriteIfMaxMinStmt" (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinArm" (TyFun (TyCon "Arm") (TyCon "Arm")))
(DFunDef false "rewriteIfMaxMinArm" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinGuard")) (EVar "gs"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "rewriteIfMaxMinGuard" (TyFun (TyCon "Guard") (TyCon "Guard")))
(DFunDef false "rewriteIfMaxMinGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinLet" (TyFun (TyCon "LetBind") (TyCon "LetBind")))
(DFunDef false "rewriteIfMaxMinLet" ((PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinClause")) (EVar "clauses"))))
(DTypeSig false "rewriteIfMaxMinClause" (TyFun (TyCon "FunClause") (TyCon "FunClause")))
(DFunDef false "rewriteIfMaxMinClause" ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "rewriteIfMaxMinSection" (TyFun (TyCon "Section") (TyCon "Section")))
(DFunDef false "rewriteIfMaxMinSection" ((PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteIfMaxMinSection" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinSection" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteIfMaxMinInterp" (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))
(DFunDef false "rewriteIfMaxMinInterp" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteIfMaxMinInterp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinGuardArm" (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))
(DFunDef false "rewriteIfMaxMinGuardArm" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinGuard")) (EVar "gs"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "rewriteIfMaxMinField" (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))
(DFunDef false "rewriteIfMaxMinField" ((PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinKv" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteIfMaxMinKv" ((PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EVar "rewriteIfMaxMinExpr") (EVar "k")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "v"))))
(DTypeSig false "countVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Int"))))
(DFunDef false "countVar" ((PVar "x") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "w")) () (EIf (EBinOp "==" (EVar "w") (EVar "x")) (ELit (LInt 1)) (ELit (LInt 0)))) (arm (PVar "e2") () (EApp (EApp (EVar "countVarList") (EVar "x")) (EApp (EVar "childExprs") (EVar "e2"))))))
(DTypeSig false "countVarList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Int"))))
(DFunDef false "countVarList" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "countVarList" ((PVar "x") (PCons (PVar "e") (PVar "es"))) (EBinOp "+" (EApp (EApp (EVar "countVar") (EVar "x")) (EVar "e")) (EApp (EApp (EVar "countVarList") (EVar "x")) (EVar "es"))))
(DTypeSig false "andThenEtaFn" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "andThenEtaFn" ((PVar "x") (PVar "arg")) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg")) (arm (PCon "EApp" (PVar "f") (PVar "lastArg")) ((GBool (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (EVar "x")) (EVar "lastArg")) (EApp (EVar "not") (EApp (EApp (EVar "mentionsVar") (EVar "x")) (EVar "f")))))) (EApp (EVar "Some") (EVar "f"))) (arm PWild () (EVar "None"))))
(DTypeSig false "buildAndThenMap" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "buildAndThenMap" ((PVar "x") (PVar "arg") (PVar "m")) (EMatch (EApp (EApp (EVar "andThenEtaFn") (EVar "x")) (EVar "arg")) (arm (PCon "Some" (PVar "f")) () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "map")))) (EVar "f"))) (EVar "m"))) (arm (PCon "None") () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "map")))) (EApp (EApp (EVar "ELam") (EListLit (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))) (EVar "arg")))) (EVar "m")))))
(DTypeSig false "andThenPureMapOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "andThenPureMapOf" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "inner") (PVar "cont")) () (EApp (EApp (EVar "andThenPureMapApp") (EApp (EVar "unwrapLoc") (EVar "inner"))) (EVar "cont"))) (arm PWild () (EVar "None"))))
(DTypeSig false "andThenPureMapApp" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "andThenPureMapApp" ((PCon "EApp" (PVar "hd") (PVar "m")) (PVar "cont")) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "andThen"))) (EVar "hd")) (EApp (EApp (EVar "andThenPureMapCont") (EVar "m")) (EApp (EVar "unwrapLoc") (EVar "cont"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "andThenPureMapApp" (PWild PWild) (EVar "None"))
(DTypeSig false "andThenPureMapCont" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "andThenPureMapCont" ((PVar "m") (PCon "ELam" (PList (PCon "PVar" (PVar "x") PWild)) (PVar "body"))) (EApp (EApp (EApp (EVar "andThenPureMapBody") (EVar "m")) (EVar "x")) (EApp (EVar "unwrapLoc") (EVar "body"))))
(DFunDef false "andThenPureMapCont" (PWild PWild) (EVar "None"))
(DTypeSig false "andThenPureMapBody" (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "andThenPureMapBody" ((PVar "m") (PVar "x") (PCon "EApp" (PVar "pureHd") (PVar "arg"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (ELit (LString "pure"))) (EVar "pureHd")) (EBinOp "<=" (EApp (EApp (EVar "countVar") (EVar "x")) (EVar "arg")) (ELit (LInt 1)))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "buildAndThenMap") (EVar "x")) (EVar "arg")) (EVar "m"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "andThenPureMapBody" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "ruleAndThenPureMap" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleAndThenPureMap" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "andThenPureMapDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "andThenPureMapDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "andThenPureMapDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "andThenPureMapFinding") (EVar "loc"))) (EApp (EVar "declAndThenPureMapHits") (EVar "d"))))
(DTypeSig false "declAndThenPureMapHits" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "declAndThenPureMapHits" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "collectAndThenPureMapHits") (EVar "body")))
(DFunDef false "declAndThenPureMapHits" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "implMethodAndThenPureMapHits")) (EVar "methods")))
(DFunDef false "declAndThenPureMapHits" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declAndThenPureMapHits") (EVar "d")))
(DFunDef false "declAndThenPureMapHits" (PWild) (EListLit))
(DTypeSig false "implMethodAndThenPureMapHits" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "implMethodAndThenPureMapHits" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectAndThenPureMapHits") (EVar "body")))
(DTypeSig false "collectAndThenPureMapHits" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "collectAndThenPureMapHits" ((PVar "e")) (EBinOp "++" (EApp (EVar "andThenPureMapHitOf") (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EVar "collectAndThenPureMapHits")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "andThenPureMapHitOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "andThenPureMapHitOf" ((PCon "EApp" (PVar "inner") (PVar "cont"))) (EApp (EVar "optExprToList") (EApp (EVar "andThenPureMapOf") (EApp (EApp (EVar "EApp") (EVar "inner")) (EVar "cont")))))
(DFunDef false "andThenPureMapHitOf" (PWild) (EListLit))
(DTypeSig false "optExprToList" (TyFun (TyApp (TyCon "Option") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "optExprToList" ((PCon "Some" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "optExprToList" ((PCon "None")) (EListLit))
(DTypeSig false "andThenPureMapFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "andThenPureMapFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameAndThenPureMap")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "monadic bind wraps a pure transformation of its result — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "andThenPureMapFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "andThenPureMapFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2"))))))))
(DFunDef false "andThenPureMapFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "andThenPureMapFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "andThenPureMapFix" (PWild (PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EMethodRef "map") (EVar "fixImplMethodAndThenPureMap")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (ERecordCreate "DImpl" ((fa "pub" (EVar "pub")) (fa "iface" (EVar "iface")) (fa "tys" (EVar "tys")) (fa "reqs" (EVar "reqs")) (fa "methods" (EVar "methods2"))))))))))
(DFunDef false "andThenPureMapFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodAndThenPureMap" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethodAndThenPureMap" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "tryAndThenPureMap" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "tryAndThenPureMap" ((PVar "e")) (EMatch (EApp (EVar "andThenPureMapOf") (EVar "e")) (arm (PCon "Some" (PVar "rewritten")) () (EVar "rewritten")) (arm (PCon "None") () (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "tryAndThenPureMap") (EApp (EApp (EVar "EApp") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "f"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "x")))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "b"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e1"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e2"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "s"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapArm")) (EVar "arms"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "c"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "t"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "el"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "b"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "lo"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "lo"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "lo"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "hi"))) (EVar "i")) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapLet")) (EVar "binds"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EVar "rewriteAndThenPureMapSection") (EVar "s"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EIndex" (PVar "a") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "i"))) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapStmt")) (EVar "stmts"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapStmt")) (EVar "stmts"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapInterp")) (EVar "parts"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapGuardArm")) (EVar "arms"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapField")) (EVar "fs"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapField")) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapField")) (EVar "fs"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapKv")) (EVar "kvs"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PVar "e")) (EVar "e"))
(DTypeSig false "rewriteAndThenPureMapStmt" (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapArm" (TyFun (TyCon "Arm") (TyCon "Arm")))
(DFunDef false "rewriteAndThenPureMapArm" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapGuard")) (EVar "gs"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "rewriteAndThenPureMapGuard" (TyFun (TyCon "Guard") (TyCon "Guard")))
(DFunDef false "rewriteAndThenPureMapGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapLet" (TyFun (TyCon "LetBind") (TyCon "LetBind")))
(DFunDef false "rewriteAndThenPureMapLet" ((PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapClause")) (EVar "clauses"))))
(DTypeSig false "rewriteAndThenPureMapClause" (TyFun (TyCon "FunClause") (TyCon "FunClause")))
(DFunDef false "rewriteAndThenPureMapClause" ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "rewriteAndThenPureMapSection" (TyFun (TyCon "Section") (TyCon "Section")))
(DFunDef false "rewriteAndThenPureMapSection" ((PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteAndThenPureMapSection" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapSection" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteAndThenPureMapInterp" (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))
(DFunDef false "rewriteAndThenPureMapInterp" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteAndThenPureMapInterp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapGuardArm" (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))
(DFunDef false "rewriteAndThenPureMapGuardArm" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapGuard")) (EVar "gs"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "rewriteAndThenPureMapField" (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))
(DFunDef false "rewriteAndThenPureMapField" ((PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapKv" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteAndThenPureMapKv" ((PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "k")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "v"))))
(DTypeSig false "mapChildExprs" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EVar "g") (EVar "f"))) (EApp (EVar "g") (EVar "x"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EVar "g") (EVar "b"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EVar "g") (EVar "e1"))) (EApp (EVar "g") (EVar "e2"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "g") (EVar "s"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapChildArm") (EVar "g"))) (EVar "arms"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EVar "g") (EVar "c"))) (EApp (EVar "g") (EVar "t"))) (EApp (EVar "g") (EVar "el"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "g") (EVar "a"))) (EApp (EVar "g") (EVar "b"))) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "g") (EVar "a"))) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "g") (EVar "a"))) (EApp (EVar "g") (EVar "b"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "g") (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "i")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "i")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "g") (EVar "e"))) (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "i")) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapChildLet") (EVar "g"))) (EVar "binds"))) (EApp (EVar "g") (EVar "body"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EApp (EVar "mapChildSection") (EVar "g")) (EVar "s"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EIndex" (PVar "a") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EVar "g") (EVar "a"))) (EApp (EVar "g") (EVar "i"))) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "g") (EVar "e"))) (EVar "t")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "g") (EVar "e"))) (EVar "t")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapChildStmt") (EVar "g"))) (EVar "stmts"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EDo" (PVar "stmts"))) (EApp (EVar "EDo") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapChildStmt") (EVar "g"))) (EVar "stmts"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapChildInterp") (EVar "g"))) (EVar "parts"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapChildGuardArm") (EVar "g"))) (EVar "arms"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapChildField") (EVar "g"))) (EVar "fs"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "g") (EVar "e"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapChildField") (EVar "g"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "g") (EVar "e"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapChildField") (EVar "g"))) (EVar "fs"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapChildKv") (EVar "g"))) (EVar "kvs"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildExprs" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "mapChildStmt" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "mapChildStmt" ((PVar "g") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildStmt" ((PVar "g") (PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildStmt" ((PVar "g") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildStmt" ((PVar "g") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildStmt" ((PVar "g") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapChildArm" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "mapChildArm" ((PVar "g") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapChildGuard") (EVar "g"))) (EVar "gs"))) (EApp (EVar "g") (EVar "body"))))
(DTypeSig false "mapChildGuard" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Guard") (TyCon "Guard"))))
(DFunDef false "mapChildGuard" ((PVar "g") (PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildGuard" ((PVar "g") (PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapChildLet" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "mapChildLet" ((PVar "g") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapChildClause") (EVar "g"))) (EVar "clauses"))))
(DTypeSig false "mapChildClause" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "mapChildClause" ((PVar "g") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "g") (EVar "body"))))
(DTypeSig false "mapChildSection" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Section") (TyCon "Section"))))
(DFunDef false "mapChildSection" (PWild (PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "mapChildSection" ((PVar "g") (PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildSection" ((PVar "g") (PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "g") (EVar "e"))) (EVar "op")))
(DTypeSig false "mapChildInterp" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "mapChildInterp" (PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "mapChildInterp" ((PVar "g") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapChildGuardArm" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "mapChildGuardArm" ((PVar "g") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapChildGuard") (EVar "g"))) (EVar "gs"))) (EApp (EVar "g") (EVar "body"))))
(DTypeSig false "mapChildField" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "mapChildField" ((PVar "g") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapChildKv" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "mapChildKv" ((PVar "g") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EVar "g") (EVar "k")) (EApp (EVar "g") (EVar "v"))))
(DTypeSig false "rewriteExprBU" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteExprBU" ((PVar "f") (PVar "e")) (EApp (EVar "f") (EApp (EApp (EVar "mapChildExprs") (EApp (EVar "rewriteExprBU") (EVar "f"))) (EVar "e"))))
(DTypeSig false "detApply" (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "detApply" ((PVar "det") (PVar "e")) (EMatch (EApp (EVar "det") (EVar "e")) (arm (PCon "Some" (PVar "e2")) () (EVar "e2")) (arm (PCon "None") () (EVar "e"))))
(DTypeSig false "exprRuleFindings" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))) (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "exprRuleFindings" ((PVar "excl") (PVar "det") (PVar "mkFinding") (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "exprRuleDeclL") (EVar "excl")) (EVar "det")) (EVar "mkFinding"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "exprRuleDeclL" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))) (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "exprRuleDeclL" ((PVar "excl") (PVar "det") (PVar "mkFinding") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "hitLoc") (PVar "hit"))) (EApp (EApp (EVar "mkFinding") (EVar "hitLoc")) (EVar "hit")))) (EApp (EApp (EApp (EApp (EVar "declRewriteHits") (EVar "excl")) (EVar "det")) (EVar "loc")) (EVar "d"))))
(DTypeSig false "declRewriteHits" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr"))))))))
(DFunDef false "declRewriteHits" ((PVar "excl") (PVar "det") (PVar "loc") (PCon "DFunDef" PWild (PVar "name") PWild (PVar "body"))) (EIf (EApp (EVar "excl") (EVar "name")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "collectRewrites") (EVar "loc")) (EVar "det")) (EVar "body")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "declRewriteHits" (PWild (PVar "det") (PVar "loc") (PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "implMethodRewriteHits") (EVar "loc")) (EVar "det"))) (EVar "methods")))
(DFunDef false "declRewriteHits" ((PVar "excl") (PVar "det") (PVar "loc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "declRewriteHits") (EVar "excl")) (EVar "det")) (EVar "loc")) (EVar "d")))
(DFunDef false "declRewriteHits" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "implMethodRewriteHits" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr")))))))
(DFunDef false "implMethodRewriteHits" ((PVar "loc") (PVar "det") (PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EApp (EApp (EVar "collectRewrites") (EVar "loc")) (EVar "det")) (EVar "body")))
(DTypeSig false "collectRewrites" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr")))))))
(DFunDef false "collectRewrites" (PWild (PVar "det") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EVar "collectRewrites") (EApp (EVar "Some") (EVar "l"))) (EVar "det")) (EVar "e")))
(DFunDef false "collectRewrites" ((PVar "curLoc") (PVar "det") (PVar "e")) (EBinOp "++" (EApp (EApp (EVar "optExprToLocList") (EVar "curLoc")) (EApp (EVar "det") (EVar "e"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "collectRewrites") (EVar "curLoc")) (EVar "det"))) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "optExprToLocList" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Expr")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Expr"))))))
(DFunDef false "optExprToLocList" (PWild (PCon "None")) (EListLit))
(DFunDef false "optExprToLocList" ((PVar "loc") (PCon "Some" (PVar "x"))) (EListLit (ETuple (EVar "loc") (EVar "x"))))
(DTypeSig false "exprRuleFix" (TyFun (TyFun (TyCon "String") (TyCon "Bool")) (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "exprRuleFix" ((PVar "excl") (PVar "f") (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EIf (EApp (EVar "excl") (EVar "name")) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "body2") (EApp (EApp (EVar "rewriteExprBU") (EVar "f")) (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "exprRuleFix" ((PVar "excl") (PVar "f") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "excl")) (EVar "f")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "exprRuleFix" (PWild (PVar "f") (PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EMethodRef "map") (EApp (EVar "fixImplMethodWith") (EVar "f"))) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (ERecordCreate "DImpl" ((fa "pub" (EVar "pub")) (fa "iface" (EVar "iface")) (fa "tys" (EVar "tys")) (fa "reqs" (EVar "reqs")) (fa "methods" (EVar "methods2"))))))))))
(DFunDef false "exprRuleFix" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodWith" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))
(DFunDef false "fixImplMethodWith" ((PVar "f") (PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EApp (EVar "rewriteExprBU") (EVar "f")) (EVar "body"))))
(DTypeSig false "noExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "noExcl" (PWild) (EVar "False"))
(DTypeSig false "notArgOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "notArgOf" ((PCon "EApp" (PVar "hd") (PVar "x"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "not"))) (EVar "hd")) (EApp (EVar "Some") (EVar "x")) (EVar "None")))
(DFunDef false "notArgOf" ((PCon "EUnOp" (PLit (LString "!")) (PVar "x") PWild)) (EApp (EVar "Some") (EVar "x")))
(DFunDef false "notArgOf" (PWild) (EVar "None"))
(DTypeSig false "mkNot" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "mkNot" ((PVar "e")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "not")))) (EVar "e")))
(DTypeSig false "isTrueLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isTrueLit" ((PVar "e")) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "True"))) (EVar "e")))
(DTypeSig false "isFalseLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isFalseLit" ((PVar "e")) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "False"))) (EVar "e")))
(DTypeSig false "isBoolLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isBoolLit" ((PVar "e")) (EBinOp "||" (EApp (EVar "isTrueLit") (EVar "e")) (EApp (EVar "isFalseLit") (EVar "e"))))
(DTypeSig false "isIntLit" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isIntLit" ((PVar "k") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" (PCon "LInt" (PVar "n"))) () (EBinOp "==" (EVar "n") (EVar "k"))) (arm (PCon "ENumLit" (PVar "n") PWild PWild PWild) () (EBinOp "==" (EVar "n") (EVar "k"))) (arm PWild () (EVar "False"))))
(DTypeSig false "concatOperands" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "concatOperands" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBinOp" (PLit (LString "++")) (PVar "l") (PVar "r") PWild) () (EBinOp "++" (EApp (EVar "concatOperands") (EVar "l")) (EListLit (EVar "r")))) (arm PWild () (EListLit (EVar "e")))))
(DTypeSig false "strLitValueOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "strLitValueOf" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" (PCon "LString" (PVar "s"))) () (EApp (EVar "Some") (EVar "s"))) (arm PWild () (EVar "None"))))
(DTypeSig false "isStrLitOperand" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isStrLitOperand" ((PVar "e")) (EMatch (EApp (EVar "strLitValueOf") (EVar "e")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "hasBackslashBrace" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasBackslashBrace" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EVar "backslashBraceGo") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "backslashBraceGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "backslashBraceGo" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "n")) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\\"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "{")))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "backslashBraceGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "concatChainQualifies" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool")))
(DFunDef false "concatChainQualifies" ((PVar "ops")) (EBlock (DoLet false false (PVar "lits") (EApp (EApp (EVar "filterExprs") (EVar "isStrLitOperand")) (EVar "ops"))) (DoLet false false (PVar "holes") (EApp (EApp (EVar "filterExprs") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isStrLitOperand") (EVar "e"))))) (EVar "ops"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "lits")) (EBinOp ">=" (EApp (EVar "listLen") (EVar "holes")) (ELit (LInt 2)))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EVar "litHasBackslashBrace")) (EVar "lits")))))))
(DTypeSig false "litHasBackslashBrace" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "litHasBackslashBrace" ((PVar "e")) (EMatch (EApp (EVar "strLitValueOf") (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "hasBackslashBrace") (EVar "s"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "filterExprs" (TyFun (TyFun (TyCon "Expr") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "filterExprs" ((PVar "p") (PVar "es")) (EApp (EApp (EMethodRef "filter") (EVar "p")) (EVar "es")))
(DTypeSig false "buildInterpParts" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "InterpPart"))))
(DFunDef false "buildInterpParts" ((PVar "ops")) (EApp (EVar "mergeInterpStr") (EApp (EApp (EMethodRef "map") (EVar "operandToInterp")) (EVar "ops"))))
(DTypeSig false "operandToInterp" (TyFun (TyCon "Expr") (TyCon "InterpPart")))
(DFunDef false "operandToInterp" ((PVar "e")) (EMatch (EApp (EVar "strLitValueOf") (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "InterpStr") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "InterpExpr") (EApp (EVar "rewriteConcatExpr") (EVar "e"))))))
(DTypeSig false "mergeInterpStr" (TyFun (TyApp (TyCon "List") (TyCon "InterpPart")) (TyApp (TyCon "List") (TyCon "InterpPart"))))
(DFunDef false "mergeInterpStr" ((PList)) (EListLit))
(DFunDef false "mergeInterpStr" ((PCons (PCon "InterpStr" (PVar "a")) (PCons (PCon "InterpStr" (PVar "b")) (PVar "rest")))) (EApp (EVar "mergeInterpStr") (EBinOp "::" (EApp (EVar "InterpStr") (EBinOp "++" (EVar "a") (EVar "b"))) (EVar "rest"))))
(DFunDef false "mergeInterpStr" ((PCons (PVar "p") (PVar "rest"))) (EBinOp "::" (EVar "p") (EApp (EVar "mergeInterpStr") (EVar "rest"))))
(DTypeSig false "concatChainOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "concatChainOf" ((PCon "EBinOp" (PLit (LString "++")) (PVar "l") (PVar "r") (PVar "rf"))) (EBlock (DoLet false false (PVar "ops") (EApp (EVar "concatOperands") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "++"))) (EVar "l")) (EVar "r")) (EVar "rf")))) (DoExpr (EIf (EApp (EVar "concatChainQualifies") (EVar "ops")) (EApp (EVar "Some") (EApp (EVar "EStringInterp") (EApp (EVar "buildInterpParts") (EVar "ops")))) (EVar "None")))))
(DFunDef false "concatChainOf" (PWild) (EVar "None"))
(DTypeSig false "rewriteConcatExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteConcatExpr" ((PVar "e")) (EMatch (EApp (EVar "concatChainOf") (EVar "e")) (arm (PCon "Some" (PVar "e2")) () (EVar "e2")) (arm (PCon "None") () (EApp (EApp (EVar "mapChildExprs") (EVar "rewriteConcatExpr")) (EVar "e")))))
(DTypeSig false "collectConcatHits" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "collectConcatHits" ((PVar "e")) (EMatch (EApp (EVar "concatChainOf") (EVar "e")) (arm (PCon "Some" (PVar "e2")) () (EBinOp "::" (EVar "e2") (EApp (EApp (EDictApp "flatMap") (EVar "collectConcatHits")) (EApp (EVar "concatOperands") (EVar "e"))))) (arm (PCon "None") () (EApp (EApp (EDictApp "flatMap") (EVar "collectConcatHits")) (EApp (EVar "childExprs") (EVar "e"))))))
(DTypeSig false "ruleConcatToInterp" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleConcatToInterp" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "concatToInterpDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "concatToInterpDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "concatToInterpDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "concatToInterpFinding") (EVar "loc"))) (EApp (EVar "declConcatHits") (EVar "d"))))
(DTypeSig false "declConcatHits" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "declConcatHits" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "collectConcatHits") (EVar "body")))
(DFunDef false "declConcatHits" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "implMethodConcatHits")) (EVar "methods")))
(DFunDef false "declConcatHits" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declConcatHits") (EVar "d")))
(DFunDef false "declConcatHits" (PWild) (EListLit))
(DTypeSig false "implMethodConcatHits" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "implMethodConcatHits" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectConcatHits") (EVar "body")))
(DTypeSig false "concatToInterpFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "concatToInterpFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameConcatToInterp")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`++` chain of string literals and expressions. Rewrite as an interpolated string '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "concatToInterpFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "concatToInterpFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteConcatExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2"))))))))
(DFunDef false "concatToInterpFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "concatToInterpFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "concatToInterpFix" (PWild (PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EMethodRef "map") (EVar "fixImplMethodConcat")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (ERecordCreate "DImpl" ((fa "pub" (EVar "pub")) (fa "iface" (EVar "iface")) (fa "tys" (EVar "tys")) (fa "reqs" (EVar "reqs")) (fa "methods" (EVar "methods2"))))))))))
(DFunDef false "concatToInterpFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodConcat" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethodConcat" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteConcatExpr") (EVar "body"))))
(DTypeSig false "notEqOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "notEqOf" ((PVar "e")) (EMatch (EApp (EVar "notArgOf") (EVar "e")) (arm (PCon "Some" (PVar "inner")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "inner")) (arm (PCon "EBinOp" (PLit (LString "==")) (PVar "a") (PVar "b") (PVar "r")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "!="))) (EVar "a")) (EVar "b")) (EVar "r")))) (arm (PCon "EBinOp" (PLit (LString "!=")) (PVar "a") (PVar "b") (PVar "r")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "=="))) (EVar "a")) (EVar "b")) (EVar "r")))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "ruleNotEq" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleNotEq" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "noExcl")) (EVar "notEqOf")) (EVar "notEqFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "notEqFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "notEqFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameNotEq")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "negated equality. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "notEqFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "notEqFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "notEqOf"))) (EVar "d")))
(DTypeSig false "boolSimplifyOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "boolSimplifyOf" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "boolSimplifyIf") (EVar "c")) (EApp (EVar "unwrapLoc") (EVar "t"))) (EApp (EVar "unwrapLoc") (EVar "el"))))
(DFunDef false "boolSimplifyOf" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EBinOp "==" (EVar "op") (ELit (LString "!=")))) (EApp (EApp (EApp (EVar "boolSimplifyEq") (EVar "op")) (EVar "a")) (EVar "b")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "boolSimplifyOf" ((PVar "e")) (EMatch (EApp (EVar "notArgOf") (EVar "e")) (arm (PCon "Some" (PVar "inner")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "y")) (EVar "y"))) (EApp (EVar "notArgOf") (EApp (EVar "unwrapLoc") (EVar "inner"))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "boolSimplifyIf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "boolSimplifyIf" ((PVar "c") (PVar "t") (PVar "el")) (EIf (EBinOp "&&" (EApp (EVar "isTrueLit") (EVar "t")) (EApp (EVar "isFalseLit") (EVar "el"))) (EApp (EVar "Some") (EVar "c")) (EIf (EBinOp "&&" (EApp (EVar "isFalseLit") (EVar "t")) (EApp (EVar "isTrueLit") (EVar "el"))) (EApp (EVar "Some") (EApp (EVar "mkNot") (EVar "c"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "boolSimplifyEq" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "boolSimplifyEq" ((PVar "op") (PVar "a") (PVar "b")) (EIf (EBinOp "&&" (EApp (EVar "isBoolLit") (EVar "a")) (EApp (EVar "isBoolLit") (EVar "b"))) (EVar "None") (EIf (EApp (EVar "isTrueLit") (EVar "b")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "a")) (EVar "True"))) (EIf (EApp (EVar "isFalseLit") (EVar "b")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "a")) (EVar "False"))) (EIf (EApp (EVar "isTrueLit") (EVar "a")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "b")) (EVar "True"))) (EIf (EApp (EVar "isFalseLit") (EVar "a")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "b")) (EVar "False"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "boolEqResult" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyCon "Expr")))))
(DFunDef false "boolEqResult" ((PVar "op") (PVar "v") (PVar "constIsTrue")) (EIf (EBinOp "==" (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EVar "constIsTrue")) (EVar "v") (EApp (EVar "mkNot") (EVar "v"))))
(DTypeSig false "ruleBoolSimplify" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleBoolSimplify" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "noExcl")) (EVar "boolSimplifyOf")) (EVar "boolSimplifyFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "boolSimplifyFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "boolSimplifyFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameBoolSimplify")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "redundant boolean expression — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "boolSimplifyFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "boolSimplifyFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "boolSimplifyOf"))) (EVar "d")))
(DTypeSig false "remParityExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "remParityExcl" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "isEven"))) (EBinOp "==" (EVar "name") (ELit (LString "isOdd")))))
(DTypeSig false "remParityOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "remParityOf" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EBinOp "==" (EVar "op") (ELit (LString "!=")))) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 0))) (EVar "b")) (EApp (EApp (EVar "remParityFrom") (EVar "op")) (EApp (EVar "unwrapLoc") (EVar "a"))) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 0))) (EVar "a")) (EApp (EApp (EVar "remParityFrom") (EVar "op")) (EApp (EVar "unwrapLoc") (EVar "b"))) (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "remParityOf" (PWild) (EVar "None"))
(DTypeSig false "remParityFrom" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "remParityFrom" ((PVar "op") (PCon "EBinOp" (PLit (LString "%")) (PVar "n") (PVar "two") PWild)) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 2))) (EVar "two")) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EApp (EVar "parityFn") (EVar "op")))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "remParityFrom" (PWild PWild) (EVar "None"))
(DTypeSig false "parityFn" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "parityFn" ((PVar "op")) (EIf (EBinOp "==" (EVar "op") (ELit (LString "=="))) (ELit (LString "isEven")) (ELit (LString "isOdd"))))
(DTypeSig false "ruleRemParity" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleRemParity" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "remParityExcl")) (EVar "remParityOf")) (EVar "remParityFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "remParityFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "remParityFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameRemParity")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "parity test. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "remParityFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "remParityFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "remParityExcl")) (EApp (EVar "detApply") (EVar "remParityOf"))) (EVar "d")))
(DTypeSig false "doubleReverseOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "doubleReverseOf" ((PCon "EApp" (PVar "hd1") (PVar "arg1"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd1")) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg1")) (arm (PCon "EApp" (PVar "hd2") (PVar "inner")) () (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd2")) (EApp (EVar "Some") (EVar "inner")) (EVar "None"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "doubleReverseOf" (PWild) (EVar "None"))
(DTypeSig false "ruleDoubleReverse" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleDoubleReverse" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "noExcl")) (EVar "doubleReverseOf")) (EVar "doubleReverseFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "doubleReverseFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "doubleReverseFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDoubleReverse")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`reverse (reverse …)` is a no-op. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "doubleReverseFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "doubleReverseFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "doubleReverseOf"))) (EVar "d")))
(DTypeSig false "whenUnlessExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "whenUnlessExcl" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "when"))) (EBinOp "==" (EVar "name") (ELit (LString "unless")))))
(DTypeSig false "isPureUnit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isPureUnit" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "hd") (PVar "arg")) () (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (ELit (LString "pure"))) (EVar "hd")) (EApp (EVar "isUnitLit") (EApp (EVar "unwrapLoc") (EVar "arg"))))) (arm PWild () (EVar "False"))))
(DTypeSig false "isUnitLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isUnitLit" ((PCon "ELit" (PCon "LUnit"))) (EVar "True"))
(DFunDef false "isUnitLit" (PWild) (EVar "False"))
(DTypeSig false "whenUnlessOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "whenUnlessOf" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EIf (EApp (EVar "isPureUnit") (EVar "el")) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "when")))) (EVar "c"))) (EVar "t"))) (EIf (EApp (EVar "isPureUnit") (EVar "t")) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "unless")))) (EVar "c"))) (EVar "el"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "whenUnlessOf" (PWild) (EVar "None"))
(DTypeSig false "ruleWhenUnless" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleWhenUnless" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "whenUnlessExcl")) (EVar "whenUnlessOf")) (EVar "whenUnlessFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "whenUnlessFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "whenUnlessFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameWhenUnless")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "conditional effect with a `pure ()` branch. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "whenUnlessFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "whenUnlessFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "whenUnlessExcl")) (EApp (EVar "detApply") (EVar "whenUnlessOf"))) (EVar "d")))
(DTypeSig false "complementExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "complementExcl" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "isNonEmptyL"))) (EBinOp "==" (EVar "name") (ELit (LString "isNonEmptyList")))))
(DTypeSig false "complementOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "complementOf" ((PLit (LString "isEmptyL"))) (EApp (EVar "Some") (ELit (LString "isNonEmptyL"))))
(DFunDef false "complementOf" ((PLit (LString "isNonEmptyL"))) (EApp (EVar "Some") (ELit (LString "isEmptyL"))))
(DFunDef false "complementOf" ((PLit (LString "isEmptyList"))) (EApp (EVar "Some") (ELit (LString "isNonEmptyList"))))
(DFunDef false "complementOf" ((PLit (LString "isNonEmptyList"))) (EApp (EVar "Some") (ELit (LString "isEmptyList"))))
(DFunDef false "complementOf" ((PLit (LString "isSome"))) (EApp (EVar "Some") (ELit (LString "isNone"))))
(DFunDef false "complementOf" ((PLit (LString "isNone"))) (EApp (EVar "Some") (ELit (LString "isSome"))))
(DFunDef false "complementOf" ((PLit (LString "isOk"))) (EApp (EVar "Some") (ELit (LString "isErr"))))
(DFunDef false "complementOf" ((PLit (LString "isErr"))) (EApp (EVar "Some") (ELit (LString "isOk"))))
(DFunDef false "complementOf" (PWild) (EVar "None"))
(DTypeSig false "appSpineHead" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "appSpineHead" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "EApp" (PVar "hd") PWild) () (EApp (EVar "appSpineHead") (EApp (EVar "unwrapLoc") (EVar "hd")))) (arm PWild () (EVar "None"))))
(DTypeSig false "renameSpineHead" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "renameSpineHead" ((PVar "newName") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" PWild) () (EApp (EVar "EVar") (EVar "newName"))) (arm (PCon "EApp" (PVar "hd") (PVar "arg")) () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "renameSpineHead") (EVar "newName")) (EVar "hd"))) (EVar "arg"))) (arm PWild () (EVar "e"))))
(DTypeSig false "complementPredOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "complementPredOf" ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "notArgOf") (EVar "e"))) (ELam ((PVar "inner")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "appSpineHead") (EApp (EVar "unwrapLoc") (EVar "inner")))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "complementOf") (EVar "name"))) (ELam ((PVar "comp")) (EApp (EVar "Some") (EApp (EApp (EVar "renameSpineHead") (EVar "comp")) (EApp (EVar "unwrapLoc") (EVar "inner")))))))))))
(DTypeSig false "ruleComplementPredicate" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleComplementPredicate" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "complementExcl")) (EVar "complementPredOf")) (EVar "complementPredicateFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "complementPredicateFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "complementPredicateFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameComplementPredicate")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "negated predicate. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "complementPredicateFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "complementPredicateFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "complementExcl")) (EApp (EVar "detApply") (EVar "complementPredOf"))) (EVar "d")))
(DTypeSig false "isNilPCon" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "isNilPCon" ((PVar "name") (PCon "PCon" (PVar "n") (PList))) (EBinOp "==" (EVar "n") (EVar "name")))
(DFunDef false "isNilPCon" (PWild PWild) (EVar "False"))
(DTypeSig false "matchToMapTransform" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "Pat") (TyCon "Expr")))))))
(DFunDef false "matchToMapTransform" ((PVar "ctor") (PCon "PCon" (PVar "c") (PList (PVar "binder"))) (PVar "body")) (EIf (EBinOp "==" (EVar "c") (EVar "ctor")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EApp" (PVar "hd") (PVar "inner")) () (EIf (EApp (EApp (EVar "isEVarNamed") (EVar "ctor")) (EVar "hd")) (EApp (EVar "Some") (ETuple (EVar "binder") (EVar "inner"))) (EVar "None"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "matchToMapTransform" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "matchToMapErrPassthru" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "matchToMapErrPassthru" ((PCon "PCon" (PLit (LString "Err")) (PList (PCon "PVar" (PVar "v") PWild))) (PVar "body")) (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EApp" (PVar "hd") (PVar "arg")) () (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (ELit (LString "Err"))) (EVar "hd")) (EApp (EApp (EVar "isEVarNamed") (EVar "v")) (EVar "arg")))) (arm PWild () (EVar "False"))))
(DFunDef false "matchToMapErrPassthru" (PWild PWild) (EVar "False"))
(DTypeSig false "matchToMapFn" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "matchToMapFn" ((PCon "PVar" (PVar "x") (PVar "l")) (PVar "expr")) (EMatch (EApp (EApp (EVar "andThenEtaFn") (EVar "x")) (EVar "expr")) (arm (PCon "Some" (PVar "f")) () (EVar "f")) (arm (PCon "None") () (EApp (EApp (EVar "ELam") (EListLit (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "l")))) (EVar "expr")))))
(DFunDef false "matchToMapFn" ((PVar "binder") (PVar "expr")) (EApp (EApp (EVar "ELam") (EListLit (EVar "binder"))) (EVar "expr")))
(DTypeSig false "matchToMapCall" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "matchToMapCall" ((PVar "binder") (PVar "expr") (PVar "scrut")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "map")))) (EApp (EApp (EVar "matchToMapFn") (EVar "binder")) (EVar "expr")))) (EVar "scrut")))
(DTypeSig false "matchToMapOption" (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "matchToMapOption" ((PVar "scrut") (PCon "Arm" (PVar "pn") (PVar "gn") (PVar "bn")) (PCon "Arm" (PVar "ps") (PVar "gs") (PVar "bs"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "gn")) (EApp (EVar "isEmptyL") (EVar "gs"))) (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "pn"))) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "None"))) (EVar "bn"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "binder") (PVar "expr"))) (EApp (EApp (EApp (EVar "matchToMapCall") (EVar "binder")) (EVar "expr")) (EVar "scrut")))) (EApp (EApp (EApp (EVar "matchToMapTransform") (ELit (LString "Some"))) (EVar "ps")) (EVar "bs"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchToMapResult" (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "matchToMapResult" ((PVar "scrut") (PCon "Arm" (PVar "pe") (PVar "ge") (PVar "be")) (PCon "Arm" (PVar "po") (PVar "go") (PVar "bo"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "ge")) (EApp (EVar "isEmptyL") (EVar "go"))) (EApp (EApp (EVar "matchToMapErrPassthru") (EVar "pe")) (EVar "be"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "binder") (PVar "expr"))) (EApp (EApp (EApp (EVar "matchToMapCall") (EVar "binder")) (EVar "expr")) (EVar "scrut")))) (EApp (EApp (EApp (EVar "matchToMapTransform") (ELit (LString "Ok"))) (EVar "po")) (EVar "bo"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchToMapPair" (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "matchToMapPair" ((PVar "scrut") (PVar "a1") (PVar "a2")) (EMatch (EApp (EApp (EApp (EVar "matchToMapOption") (EVar "scrut")) (EVar "a1")) (EVar "a2")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Some") (EVar "e"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "matchToMapOption") (EVar "scrut")) (EVar "a2")) (EVar "a1")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Some") (EVar "e"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "matchToMapResult") (EVar "scrut")) (EVar "a1")) (EVar "a2")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Some") (EVar "e"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "matchToMapResult") (EVar "scrut")) (EVar "a2")) (EVar "a1")))))))))
(DTypeSig false "matchToMapOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "matchToMapOf" ((PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EMatch (EVar "arms") (arm (PList (PVar "a1") (PVar "a2")) () (EApp (EApp (EApp (EVar "matchToMapPair") (EVar "scrut")) (EVar "a1")) (EVar "a2"))) (arm PWild () (EVar "None"))))
(DFunDef false "matchToMapOf" (PWild) (EVar "None"))
(DTypeSig false "ruleMatchToMap" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleMatchToMap" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "noExcl")) (EVar "matchToMapOf")) (EVar "matchToMapFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "matchToMapFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "matchToMapFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameMatchToMap")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "2-arm match maps over an Option/Result — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "matchToMapFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "matchToMapFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "matchToMapOf"))) (EVar "d")))
(DTypeSig false "bindChainDepth" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyCon "Int"))))
(DFunDef false "bindChainDepth" ((PVar "isResult") (PVar "e")) (EBlock (DoLet false false (PTuple PWild (PVar "core")) (EApp (EVar "bindChainSplit") (EVar "e"))) (DoExpr (EMatch (EApp (EApp (EVar "bindChainHead") (EVar "isResult")) (EVar "core")) (arm (PCon "Some" (PVar "body")) () (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "bindChainDepth") (EVar "isResult")) (EVar "body")))) (arm (PCon "None") () (EIf (EApp (EVar "bindChainIsTermMap") (EVar "core")) (ELit (LInt 1)) (ELit (LInt 0))))))))
(DTypeSig false "bindChainSplit" (TyFun (TyCon "Expr") (TyTuple (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "bindChainSplit" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EBlock" (PVar "stmts")) () (EMatch (EApp (EVar "reverseL") (EVar "stmts")) (arm (PCons (PCon "DoExpr" (PVar "lastE")) (PVar "revInit")) () (ETuple (EApp (EApp (EDictApp "flatMap") (EVar "stmtExprs")) (EApp (EVar "reverseL") (EVar "revInit"))) (EVar "lastE"))) (arm PWild () (ETuple (EListLit) (EApp (EVar "EBlock") (EVar "stmts")))))) (arm (PVar "other") () (ETuple (EListLit) (EVar "other")))))
(DTypeSig false "bindChainHead" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "bindChainHead" ((PVar "isResult") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EMatch" PWild (PVar "arms")) () (EMatch (EVar "arms") (arm (PList (PVar "a1") (PVar "a2")) () (EMatch (EApp (EApp (EApp (EVar "bindChainTry") (EVar "isResult")) (EVar "a1")) (EVar "a2")) (arm (PCon "Some" (PVar "b")) () (EApp (EVar "Some") (EVar "b"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "bindChainTry") (EVar "isResult")) (EVar "a2")) (EVar "a1"))))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "bindChainTry" (TyFun (TyCon "Bool") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "bindChainTry" ((PVar "isResult") (PVar "failArm") (PCon "Arm" (PVar "okP") (PVar "okGs") (PVar "okBody"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "bindChainFailPassthru") (EVar "isResult")) (EVar "failArm")) (EApp (EVar "isEmptyL") (EVar "okGs"))) (EApp (EApp (EVar "bindChainOkPat") (EVar "isResult")) (EVar "okP"))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "bindChainRewrap") (EVar "isResult")) (EVar "okP")) (EVar "okBody")))) (EApp (EVar "Some") (EVar "okBody")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bindChainFailPassthru" (TyFun (TyCon "Bool") (TyFun (TyCon "Arm") (TyCon "Bool"))))
(DFunDef false "bindChainFailPassthru" ((PVar "isResult") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "gs")) (EIf (EVar "isResult") (EApp (EApp (EVar "matchToMapErrPassthru") (EVar "p")) (EVar "body")) (EBinOp "&&" (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "p")) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "None"))) (EVar "body"))))))
(DTypeSig false "bindChainOkPat" (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "bindChainOkPat" ((PVar "isResult") (PCon "PCon" (PVar "c") (PList PWild))) (EBinOp "==" (EVar "c") (EIf (EVar "isResult") (ELit (LString "Ok")) (ELit (LString "Some")))))
(DFunDef false "bindChainOkPat" (PWild PWild) (EVar "False"))
(DTypeSig false "bindChainRewrap" (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "bindChainRewrap" ((PVar "isResult") (PVar "p") (PVar "body")) (EMatch (EApp (EApp (EApp (EVar "matchToMapTransform") (EIf (EVar "isResult") (ELit (LString "Ok")) (ELit (LString "Some")))) (EVar "p")) (EVar "body")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "bindChainIsTermMap" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "bindChainIsTermMap" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "inner") PWild) () (EMatch (EApp (EVar "unwrapLoc") (EVar "inner")) (arm (PCon "EApp" (PVar "hd") PWild) () (EApp (EApp (EVar "isEVarNamed") (ELit (LString "map"))) (EVar "hd"))) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig false "bindChainOffChain" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "bindChainOffChain" ((PVar "isResult") (PVar "e")) (EBlock (DoLet false false (PTuple (PVar "lets") (PVar "core")) (EApp (EVar "bindChainSplit") (EVar "e"))) (DoExpr (EMatch (EApp (EApp (EVar "bindChainHead") (EVar "isResult")) (EVar "core")) (arm (PCon "Some" (PVar "body")) () (EBinOp "++" (EVar "lets") (EBinOp "::" (EApp (EVar "bindChainScrut") (EVar "core")) (EApp (EApp (EVar "bindChainOffChain") (EVar "isResult")) (EVar "body"))))) (arm (PCon "None") () (EIf (EApp (EVar "bindChainIsTermMap") (EVar "core")) (EBinOp "++" (EVar "lets") (EApp (EVar "bindChainTermMapParts") (EVar "core"))) (EBinOp "++" (EVar "lets") (EListLit (EVar "core")))))))))
(DTypeSig false "bindChainScrut" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "bindChainScrut" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EMatch" (PVar "s") PWild) () (EVar "s")) (arm PWild () (EVar "e"))))
(DTypeSig false "bindChainTermMapParts" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "bindChainTermMapParts" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "inner") (PVar "scrut")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "inner")) (arm (PCon "EApp" PWild (PVar "f")) () (EListLit (EVar "f") (EVar "scrut"))) (arm PWild () (EListLit (EVar "e"))))) (arm PWild () (EListLit (EVar "e")))))
(DTypeSig false "bindChainHeads" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "bindChainHeads" ((PVar "e")) (EBlock (DoLet false false (PVar "rd") (EApp (EApp (EVar "bindChainDepth") (EVar "True")) (EVar "e"))) (DoLet false false (PVar "od") (EApp (EApp (EVar "bindChainDepth") (EVar "False")) (EVar "e"))) (DoExpr (EIf (EBinOp "||" (EBinOp ">=" (EVar "rd") (ELit (LInt 3))) (EBinOp ">=" (EVar "od") (ELit (LInt 3)))) (EBinOp "::" (EVar "e") (EApp (EApp (EDictApp "flatMap") (EVar "bindChainHeads")) (EApp (EApp (EVar "bindChainOffChain") (EBinOp ">=" (EVar "rd") (EVar "od"))) (EVar "e")))) (EApp (EApp (EDictApp "flatMap") (EVar "bindChainHeads")) (EApp (EVar "childExprs") (EVar "e")))))))
(DTypeSig false "bindChainDeclHeads" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "bindChainDeclHeads" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "bindChainHeads") (EVar "body")))
(DFunDef false "bindChainDeclHeads" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "bindChainImplHeads")) (EVar "methods")))
(DFunDef false "bindChainDeclHeads" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "bindChainDeclHeads") (EVar "d")))
(DFunDef false "bindChainDeclHeads" (PWild) (EListLit))
(DTypeSig false "bindChainImplHeads" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "bindChainImplHeads" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "bindChainHeads") (EVar "body")))
(DTypeSig false "ruleBindChainToDo" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleBindChainToDo" (PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "bindChainDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "bindChainDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "bindChainDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "bindChainFinding") (EVar "loc"))) (EApp (EVar "bindChainDeclHeads") (EVar "d"))))
(DTypeSig false "bindChainFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "bindChainFinding" ((PVar "loc") PWild) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameBindChainToDo")) (fa "message" (ELit (LString "deep nested Result/Option passthrough-bind `match` chain (≥3 binds). Rewrite as a `do` block"))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "ruleDeadCode" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "ruleDeadCode" (PWild (PVar "src") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "reach") (EApp (EApp (EVar "reachableNames") (EVar "src")) (EVar "prog"))) (DoExpr (EApp (EApp (EMethodRef "map") (EVar "deadFinding")) (EApp (EApp (EVar "filterList") (EApp (EVar "deadPair") (EVar "reach"))) (EApp (EApp (EVar "privateDefLocs") (EVar "pos")) (EVar "prog")))))))
(DTypeSig false "deadPair" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "deadPair" ((PVar "reach") (PTuple (PVar "n") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "n")) (EVar "reach"))))
(DTypeSig false "deadFinding" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding")))
(DFunDef false "deadFinding" ((PTuple (PVar "name") (PVar "loc"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDeadCode")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "private top-level '")) (EVar "name")) (ELit (LString "' is unreachable from exports/main/doctests — remove it (dead code)")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "privateDefLocs" (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "privateDefLocs" ((PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "exported") (EApp (EVar "nameSetOf") (EApp (EVar "exportedNames") (EVar "prog")))) (DoExpr (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EVar "filterList") (EApp (EVar "candidatePair") (EVar "exported"))) (EApp (EApp (EDictApp "flatMap") (EVar "allDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))))
(DTypeSig false "nameSetOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit"))))
(DFunDef false "nameSetOf" ((PVar "names")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "nameSetInto") (EVar "names")) (EVar "s"))) (DoExpr (EVar "s"))))
(DTypeSig false "nameSetInto" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyCon "Unit"))))
(DFunDef false "nameSetInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "nameSetInto" ((PCons (PVar "n") (PVar "rest")) (PVar "s")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "set") (EVar "n")) (ELit LUnit)) (EVar "s"))) (DoExpr (EApp (EApp (EVar "nameSetInto") (EVar "rest")) (EVar "s")))))
(DTypeSig false "allDefNameL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "allDefNameL" ((PTuple (PCon "DFunDef" PWild (PVar "name") PWild PWild) (PVar "loc"))) (EListLit (ETuple (EVar "name") (EVar "loc"))))
(DFunDef false "allDefNameL" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "allDefNameL") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "allDefNameL" (PWild) (EListLit))
(DTypeSig false "candidatePair" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "candidatePair" ((PVar "exported") (PTuple (PVar "n") PWild)) (EBinOp "&&" (EApp (EVar "isOrdinaryIdent") (EVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "has") (EVar "n")) (EVar "exported")))))
(DTypeSig false "isOrdinaryIdent" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isOrdinaryIdent" ((PVar "s")) (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))) (EVar "False") (EIf (EVar "otherwise") (EApp (EVar "isIdentStart") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "s")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reachableNames" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "reachableNames" ((PVar "src") (PVar "prog")) (EBlock (DoLet false false (PVar "refMap") (EApp (EVar "mergeRefs") (EApp (EApp (EDictApp "flatMap") (EVar "defRefPair")) (EVar "prog")))) (DoLet false false (PVar "seed") (EBinOp "++" (EApp (EVar "exportedNames") (EVar "prog")) (EBinOp "::" (ELit (LString "main")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "nonDefRefL")) (EVar "prog")) (EApp (EVar "doctestIdents") (EVar "src")))))) (DoLet false false (PVar "visited") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EApp (EVar "bfsReach") (EVar "refMap")) (EVar "visited")) (EVar "seed"))) (DoExpr (EVar "visited"))))
(DTypeSig false "defRefPair" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "defRefPair" ((PVar "d")) (EMatch (EApp (EVar "defNameOf") (EVar "d")) (arm (PCon "Some" (PVar "name")) () (EListLit (ETuple (EVar "name") (EApp (EVar "sortUniqS") (EApp (EVar "identTokens") (EApp (EVar "declToString") (EApp (EVar "unAttrib") (EVar "d")))))))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "defNameOf" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "defNameOf" ((PCon "DFunDef" PWild (PVar "name") PWild PWild)) (EApp (EVar "Some") (EVar "name")))
(DFunDef false "defNameOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "defNameOf") (EVar "d")))
(DFunDef false "defNameOf" (PWild) (EVar "None"))
(DTypeSig false "unAttrib" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "unAttrib" ((PCon "DAttrib" PWild (PVar "d"))) (EVar "d"))
(DFunDef false "unAttrib" ((PVar "d")) (EVar "d"))
(DTypeSig false "exportedNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "exportedNames" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "exportedNameL")) (EVar "prog")))
(DTypeSig false "exportedNameL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "exportedNameL" ((PCon "DFunDef" (PCon "True") (PVar "name") PWild PWild)) (EListLit (EVar "name")))
(DFunDef false "exportedNameL" ((PCon "DTypeSig" (PCon "True") (PVar "name") PWild)) (EListLit (EVar "name")))
(DFunDef false "exportedNameL" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "exportedNameL") (EVar "d")))
(DFunDef false "exportedNameL" (PWild) (EListLit))
(DTypeSig false "nonDefRefL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "nonDefRefL" ((PCon "DAttrib" PWild (PVar "dd"))) (EApp (EVar "nonDefRefL") (EVar "dd")))
(DFunDef false "nonDefRefL" ((PCon "DFunDef" PWild PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DTypeSig" PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DExtern" PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DData" PWild PWild PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DUse" PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DEffect" PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DTypeAlias" PWild PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PCon "DNewtype" PWild PWild PWild PWild PWild PWild)) (EListLit))
(DFunDef false "nonDefRefL" ((PVar "d")) (EApp (EVar "bodyIdents") (EVar "d")))
(DTypeSig false "bodyIdents" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "bodyIdents" ((PVar "d")) (EApp (EVar "sortUniqS") (EApp (EVar "identTokens") (EApp (EVar "declToString") (EVar "d")))))
(DTypeSig false "bfsReach" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "bfsReach" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "bfsReach" ((PVar "refMap") (PVar "visited") (PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EApp (EVar "has") (EVar "x")) (EVar "visited")) (EApp (EApp (EApp (EVar "bfsReach") (EVar "refMap")) (EVar "visited")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "set") (EVar "x")) (ELit LUnit)) (EVar "visited"))) (DoExpr (EApp (EApp (EApp (EVar "bfsReach") (EVar "refMap")) (EVar "visited")) (EBinOp "++" (EApp (EApp (EVar "refsOf") (EVar "refMap")) (EVar "x")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "refsOf" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "refsOf" ((PVar "refMap") (PVar "n")) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "refMap")))
(DTypeSig false "mergeRefs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "mergeRefs" ((PVar "pairs")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "mergeRefsGo") (EVar "m")) (EVar "pairs"))) (DoExpr (EVar "m"))))
(DTypeSig false "mergeRefsGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Unit"))))
(DFunDef false "mergeRefsGo" (PWild (PList)) (ELit LUnit))
(DFunDef false "mergeRefsGo" ((PVar "acc") (PCons (PTuple (PVar "n") (PVar "rs")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "set") (EVar "n")) (EApp (EVar "sortUniqS") (EBinOp "++" (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "n")) (EVar "acc")) (EVar "rs")))) (EVar "acc"))) (DoExpr (EApp (EApp (EVar "mergeRefsGo") (EVar "acc")) (EVar "rest")))))
(DTypeSig false "identTokens" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "identTokens" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "identTokGo") (EVar "s")) (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))))))
(DTypeSig false "identTokGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "identTokGo" ((PVar "s") (PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit) (EIf (EApp (EVar "isIdentStart") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EBlock (DoLet false false (PVar "j") (EApp (EApp (EApp (EVar "identEnd") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EVar "j")) (EVar "s")) (EApp (EApp (EApp (EApp (EVar "identTokGo") (EVar "s")) (EVar "cs")) (EVar "n")) (EVar "j"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "identTokGo") (EVar "s")) (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isIdentStart" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isIdentStart" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EApp (EVar "isLower") (EVar "c")) (EApp (EVar "isUpper") (EVar "c"))) (EBinOp "==" (EVar "c") (ELit (LChar "_")))))
(DTypeSig false "identEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "identEnd" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "i") (EIf (EApp (EVar "isAlnum") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "identEnd") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "doctestIdents" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "doctestIdents" ((PVar "src")) (EApp (EApp (EDictApp "flatMap") (EVar "commentDocIdents")) (EApp (EVar "collectComments") (EVar "src"))))
(DTypeSig false "commentDocIdents" (TyFun (TyCon "Comment") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "commentDocIdents" ((PVar "c")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "commentText") (EVar "c"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "{-"))) (EVar "t")) (EApp (EApp (EDictApp "flatMap") (EVar "blockDocLineIdents")) (EApp (EVar "splitNl") (EApp (EVar "blockInner") (EVar "t")))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "-- >"))) (EVar "t")) (EApp (EVar "identTokens") (EApp (EApp (EVar "dropPrefixN") (ELit (LInt 4))) (EVar "t"))) (EListLit))))))
(DTypeSig false "blockInner" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "blockInner" ((PVar "t")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "t"))) (DoExpr (EIf (EBinOp ">=" (EVar "n") (ELit (LInt 4))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EBinOp "-" (EVar "n") (ELit (LInt 2)))) (EVar "t")) (ELit (LString ""))))))
(DTypeSig false "blockDocLineIdents" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "blockDocLineIdents" ((PVar "line")) (EBlock (DoLet false false (PVar "tr") (EApp (EVar "stringTrim") (EVar "line"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (ELit (LString ">"))) (EVar "tr")) (EApp (EVar "identTokens") (EApp (EApp (EVar "dropPrefixN") (ELit (LInt 1))) (EVar "tr"))) (EListLit)))))
(DTypeSig false "dropPrefixN" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "dropPrefixN" ((PVar "k") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "k")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))
(DTypeSig true "runCrossFileRules" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "runCrossFileRules" ((PVar "only") (PVar "disable") (PVar "files")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "runCrossRuleOn") (EVar "only")) (EVar "disable")) (EVar "files"))) (EVar "allCrossFileRules")))
(DTypeSig false "runCrossRuleOn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "CrossFileRule") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "runCrossRuleOn" ((PVar "only") (PVar "disable") (PVar "files") (PVar "r")) (EIf (EApp (EApp (EApp (EVar "crossRuleActive") (EVar "only")) (EVar "disable")) (EVar "r")) (EApp (EApp (EMethodRef "map") (EApp (EVar "restampSeverity") (EFieldAccess (EVar "r") "severity"))) (EApp (EFieldAccess (EVar "r") "check") (EVar "files"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "crossFileCacheSound" (TyCon "Bool"))
(DFunDef false "crossFileCacheSound" () (EMatch (EVar "allCrossFileRules") (arm (PList (PVar "r")) () (EBinOp "==" (EFieldAccess (EVar "r") "name") (EVar "ruleNameDuplicateBody"))) (arm PWild () (EVar "False"))))
(DTypeSig true "runCrossFileRulesFromOccs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "runCrossFileRulesFromOccs" ((PVar "only") (PVar "disable") (PVar "occs")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "runCrossRuleFromOccs") (EVar "only")) (EVar "disable")) (EVar "occs"))) (EVar "allCrossFileRules")))
(DTypeSig false "runCrossRuleFromOccs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyFun (TyCon "CrossFileRule") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "runCrossRuleFromOccs" ((PVar "only") (PVar "disable") (PVar "occs") (PVar "r")) (EIf (EBinOp "&&" (EApp (EApp (EApp (EVar "crossRuleActive") (EVar "only")) (EVar "disable")) (EVar "r")) (EBinOp "==" (EFieldAccess (EVar "r") "name") (EVar "ruleNameDuplicateBody"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "restampSeverity") (EFieldAccess (EVar "r") "severity"))) (EApp (EVar "dupJoin") (EVar "occs"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "crossRuleActive" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CrossFileRule") (TyCon "Bool")))))
(DFunDef false "crossRuleActive" ((PVar "only") (PVar "disable") (PVar "r")) (EBinOp "&&" (EBinOp "&&" (EFieldAccess (EVar "r") "enabled") (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "only")) (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "only")))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "r") "name")) (EVar "disable")))))
(DTypeSig false "dupComplexityThreshold" (TyCon "Int"))
(DFunDef false "dupComplexityThreshold" () (ELit (LInt 10)))
(DTypeSig false "structuralKey" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "String"))))
(DFunDef false "structuralKey" ((PVar "pats") (PVar "body")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString "|"))) (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "pats"))))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EApp (EVar "exprSexp") (EVar "body")))) (ELit (LString ""))))
(DTypeSig false "bodyComplexity" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "bodyComplexity" ((PVar "body")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EApp (EVar "exprSexp") (EVar "body")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "countOpenParens") (EVar "cs")) (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0))) (ELit (LInt 0))))))
(DTypeSig false "countOpenParens" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "countOpenParens" ((PVar "cs") (PVar "n") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "acc") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "("))) (EApp (EApp (EApp (EApp (EVar "countOpenParens") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "countOpenParens") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "ruleDuplicateBody" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "ruleDuplicateBody" ((PVar "files")) (EApp (EVar "dupJoin") (EApp (EApp (EDictApp "flatMap") (EVar "fileDupOccs")) (EVar "files"))))
(DTypeSig true "dupJoin" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "dupJoin" ((PVar "occs")) (EBlock (DoLet false false (PVar "groups") (EApp (EVar "groupOccsByKey") (EVar "occs"))) (DoLet false false (PVar "live") (EApp (EApp (EVar "filterList") (ELam ((PVar "k")) (EApp (EVar "dupGroupFires") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "k")) (EVar "groups"))))) (EApp (EVar "dupDistinctKeys") (EVar "occs")))) (DoExpr (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "k")) (EApp (EVar "emitDupGroup") (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "k")) (EVar "groups")))))) (EApp (EVar "sortUniqS") (EVar "live"))))))
(DTypeSig false "groupOccsByKey" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "groupOccsByKey" ((PVar "occs")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "groupOccsGo") (EVar "m")) (EVar "occs"))) (DoExpr (EVar "m"))))
(DTypeSig false "groupOccsGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyCon "Unit"))))
(DFunDef false "groupOccsGo" (PWild (PList)) (ELit LUnit))
(DFunDef false "groupOccsGo" ((PVar "m") (PCons (PVar "o") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "set") (EApp (EVar "occKey") (EVar "o"))) (EBinOp "::" (EVar "o") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EApp (EVar "occKey") (EVar "o"))) (EVar "m")))) (EVar "m"))) (DoExpr (EApp (EApp (EVar "groupOccsGo") (EVar "m")) (EVar "rest")))))
(DTypeSig false "dupDistinctKeys" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dupDistinctKeys" ((PVar "occs")) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "dupDistinctGo") (EVar "seen")) (EVar "occs")))))
(DTypeSig false "dupDistinctGo" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "dupDistinctGo" (PWild (PList)) (EListLit))
(DFunDef false "dupDistinctGo" ((PVar "seen") (PCons (PVar "o") (PVar "rest"))) (EIf (EApp (EApp (EVar "has") (EApp (EVar "occKey") (EVar "o"))) (EVar "seen")) (EApp (EApp (EVar "dupDistinctGo") (EVar "seen")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "set") (EApp (EVar "occKey") (EVar "o"))) (ELit LUnit)) (EVar "seen"))) (DoExpr (EBinOp "::" (EApp (EVar "occKey") (EVar "o")) (EApp (EApp (EVar "dupDistinctGo") (EVar "seen")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupGroupFires" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyCon "Bool")))
(DFunDef false "dupGroupFires" ((PVar "grp")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "grp")) (ELit (LInt 2))) (EBinOp ">=" (EApp (EVar "listLen") (EApp (EVar "sortUniqS") (EApp (EApp (EMethodRef "map") (EVar "occFile")) (EVar "grp")))) (ELit (LInt 2)))))
(DTypeSig true "fileDupOccs" (TyFun (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))))
(DFunDef false "fileDupOccs" ((PTuple (PVar "path") (PVar "pos") (PVar "decls"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "dupOccOfDecl") (EVar "path"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "decls"))))
(DTypeSig false "dupOccOfDecl" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dupOccOfDecl" ((PVar "path") (PTuple (PVar "d") (PVar "loc"))) (EMatch (EVar "d") (arm (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body")) () (EIf (EBinOp ">=" (EApp (EVar "bodyComplexity") (EVar "body")) (EVar "dupComplexityThreshold")) (EListLit (ETuple (EVar "path") (EApp (EVar "locLineOf") (EVar "loc")) (EVar "name") (EApp (EApp (EVar "structuralKey") (EVar "pats")) (EVar "body")))) (EListLit))) (arm (PCon "DAttrib" PWild (PVar "inner")) () (EApp (EApp (EVar "dupOccOfDecl") (EVar "path")) (ETuple (EVar "inner") (EVar "loc")))) (arm PWild () (EListLit))))
(DTypeSig false "locLineOf" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Int")))
(DFunDef false "locLineOf" ((PCon "Some" (PCon "Loc" PWild (PVar "l") PWild PWild PWild))) (EVar "l"))
(DFunDef false "locLineOf" ((PCon "None")) (ELit (LInt 1)))
(DTypeSig false "occFile" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "occFile" ((PTuple (PVar "f") PWild PWild PWild)) (EVar "f"))
(DTypeSig false "occLine" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "Int")))
(DFunDef false "occLine" ((PTuple PWild (PVar "l") PWild PWild)) (EVar "l"))
(DTypeSig false "occName" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "occName" ((PTuple PWild PWild (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "occKey" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "occKey" ((PTuple PWild PWild PWild (PVar "k"))) (EVar "k"))
(DTypeSig false "emitDupGroup" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "emitDupGroup" ((PVar "grp")) (EBlock (DoLet false false (PVar "distinctFiles") (EApp (EVar "sortUniqS") (EApp (EApp (EMethodRef "map") (EVar "occFile")) (EVar "grp")))) (DoExpr (EIf (EBinOp "<" (EApp (EVar "listLen") (EVar "distinctFiles")) (ELit (LInt 2))) (EListLit) (EApp (EApp (EMethodRef "map") (EApp (EVar "dupFinding") (EVar "distinctFiles"))) (EApp (EVar "sortDupOccs") (EVar "grp")))))))
(DTypeSig false "dupFinding" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "Finding"))))
(DFunDef false "dupFinding" ((PVar "distinctFiles") (PVar "occ")) (EBlock (DoLet false false (PVar "file") (EApp (EVar "occFile") (EVar "occ"))) (DoLet false false (PVar "line") (EApp (EVar "occLine") (EVar "occ"))) (DoLet false false (PVar "others") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "!=" (EVar "_s") (EVar "file")))) (EVar "distinctFiles"))) (DoExpr (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDuplicateBody")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function '")) (EApp (EMethodRef "display") (EApp (EVar "occName") (EVar "occ")))) (ELit (LString "' has a body structurally identical to a definition in "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "others")))) (ELit (LString " — consolidate into a shared module")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EVar "line")) (ELit (LInt 1))) (EVar "line")) (ELit (LInt 1))))))))))
(DTypeSig false "sortDupOccs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))))
(DFunDef false "sortDupOccs" ((PList)) (EListLit))
(DFunDef false "sortDupOccs" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "dupInsert") (EVar "x")) (EApp (EVar "sortDupOccs") (EVar "xs"))))
(DTypeSig false "dupInsert" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dupInsert" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "dupInsert" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EApp (EApp (EVar "dupOccLe") (EVar "x")) (EVar "y")) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "dupInsert") (EVar "x")) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupOccLe" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "dupOccLe" ((PVar "a") (PVar "b")) (EMatch (EApp (EApp (EVar "stringCompare") (EApp (EVar "occFile") (EVar "a"))) (EApp (EVar "occFile") (EVar "b"))) (arm (PCon "Lt") () (EVar "True")) (arm (PCon "Gt") () (EVar "False")) (arm (PCon "Eq") () (EBinOp "<=" (EApp (EVar "occLine") (EVar "a")) (EApp (EVar "occLine") (EVar "b"))))))
