# META
source_lines=1079
stages=DESUGAR,MARK
# SOURCE
-- compiler/diagnostics.mdk — structured error pipeline (Phase A.4)
--
-- Mirrors lib/diagnostics.ml: runs all pipeline stages accumulating diagnostics
-- WITHOUT exit-on-first-error, returning a structured List Diag.
--
-- Design note: lib/diagnostics.ml carries Ast.loc (file/line/col) on every
-- Diag because the OCaml AST threads source positions through every node.
-- B.10.2b: the compiler AST now carries expr-level spans via the transparent
-- `ELoc` wrapper, and typecheck pairs each error with the `currentLoc` span in
-- effect at the push site (`checkProgramDiags` returns `(msg, Option Loc)`).  So
-- `Diag` carries an `Option Loc` — `Some` for type errors (expr-level span),
-- `None` for resolve / guard / match-exhaustiveness diagnostics, which the
-- compiler pipeline does not yet attribute to a span (they fall back to the
-- whole-document range in the LSP).
--
-- Output format for the diff gate (diagdump --analyze):
--   "error: <message>"   or   "warning: <message>"
-- one per line, sorted by the harness.

import frontend.ast.{Decl, Loc(..)}
import frontend.parser.{
  parse,
  parseLocated,
  parseResult,
  ParseError,
  parseErrorLine,
  parseErrorCol,
  parseErrorMessage,
}
import frontend.desugar.{desugar, checkDerives}
import frontend.resolve.{
  ResError,
  resolveProgram,
  resolveProgramG2,
  internalGuardFor,
  ppResError,
  resErrorLoc,
  resErrorCode,
  resErrorDidYouMean,
  resolveModule,
  ModuleExports,
}
import frontend.exhaust.{checkGuardExhaustivenessWith}
import types.typecheck.{
  checkProgramDiags,
  checkModulesDiags,
  checkModules,
  entryOwnSchemes,
  Scheme(..),
  setCoherenceUserDecls,
  TcDiag(..),
  tcMsg,
}
import driver.loader.{
  LoadMsg,
  LoadParseFailed,
  loadProgramFilesLocatedCached,
  loadProgramFilesLocatedCachedE,
  loadProgramE,
  projectTrustedMods,
  entrySearchRoots,
  findImportLoc,
  unknownModuleIdOf,
  availableModulesText,
  availableModulesHint,
}
import support.path.{dirOf}
import driver.main_autoprint.{
  shouldAutoPrintMain,
  autoPrintWrapModules,
  underivedMainDiags,
}
import support.util.{
  joinNl,
  lookupAssoc,
  startsWith,
  anyList,
  filterList,
  contains,
}
import json.{Json, JInt, JString, JArray, jObject, stringify}

-- ── types ──────────────────────────────────────────────────────────────────

public export data Severity = SevError | SevWarning

-- A structured diagnostic: severity + human-readable message + an optional
-- source span (B.10.2b).  `Some` for type errors (expr-level span from the
-- ELoc substrate); `None` for resolve / guard / match diagnostics the compiler
-- pipeline does not yet locate.
-- Stage 1 (DIAGNOSTIC-CODES-DESIGN): every Diag carries a stable machine-readable
-- `Code` (a kebab string, e.g. "T-TYPE-MISMATCH") authored at its producing site.
-- The JSON `kind` is DERIVED from the code prefix (`codeKind`), never stored — so
-- authors supply exactly one token.  The CLI text renderers (`ppDiag`/
-- `ppDiagCliSrc`) deliberately ignore the code (JSON-only for Stage 1), keeping the
-- human-facing CLI output byte-identical.
-- Stage 2 (DIAGNOSTIC-CODES-DESIGN §6): a Diag optionally carries a human `help`
-- hint (Option String) and a machine-applicable `fix` (Option Fix).  Both are
-- surfaced JSON-only (CLI text is unchanged) and are `None` for most diagnostics;
-- today only did-you-mean (resolve UnboundVariable with a suggestion) populates
-- them.  A `Fix` replaces its `Loc` span with the replacement string.
public export data Fix = Fix Loc String

public export data Diag =
  | Diag Severity String String (Option Loc) (Option String) (Option Fix)

-- Smart constructor for a diagnostic with no structured help/fix (the common
-- case) — keeps the ~15 plain construction sites terse.
export mkDiag : Severity -> String -> String -> Option Loc -> Diag
mkDiag sev code msg loc = Diag sev code msg loc None None

-- Build the (help, fix) pair for a resolve error's structured suggestion.  Only
-- did-you-mean yields both today: `help` is prose; `fix` replaces the misspelled
-- identifier's OWN span (its loc start, end = start + name length) with the
-- suggested name — an exact, single-span, agent-applicable edit.
export resErrorHelpFix : ResError -> (Option String, Option Fix)
resErrorHelpFix e = match resErrorDidYouMean e
  Some (bad, sug) =>
    let help = Some "did you mean '\{sug}'?"
    let fix = map ((Loc f sl sc _ _) => Fix (Loc f sl sc sl (sc + stringLength bad)) sug) (resErrorLoc e)
    (help, fix)
  None => (None, None)

-- Convert a resolve error to a Diag, attaching structured help/fix (did-you-mean).
export diagOfResError : ResError -> Diag
diagOfResError e =
  let (help, fix) = resErrorHelpFix e
  Diag SevError (resErrorCode e) (ppResError e) (resErrorLoc e) help fix

-- Convert a typecheck error `TcDiag` to a Diag.  #159: the code, span, and any
-- structured help/fix (e.g. the record-field did-you-mean that
-- `pushTypeErrorHelpFixAt` attaches) now ride INSIDE the TcDiag — no message-keyed
-- side-channel lookup.  A type-error TcDiag always carries SevError severity.
export diagOfTypeError : TcDiag -> Diag
diagOfTypeError (TcDiag code _ loc msg help fix) =
  Diag SevError code msg loc help (map fixOfLocRepl fix)

fixOfLocRepl : (Loc, String) -> Fix
fixOfLocRepl (l, r) = Fix l r

-- Convert a non-exhaustive-match warning `TcDiag` (whose `msg` is the full
-- "Warning: …" string, carrying its captured loc and any actionable-fix hint as
-- `help`) to a Diag.  #159: the hint rides in the TcDiag's `help` field — no
-- `matchWarningHelp` lookup.  The `W-*` code and the prefix strip are computed
-- here from the full message.  No machine `fix` — the hint has no single
-- mechanical edit.
diagOfMatchWarning : TcDiag -> Diag
diagOfMatchWarning (TcDiag _ _ loc w help _) =
  Diag SevWarning (matchWarnCode w) (stripWarnPrefix w) loc help None

-- The two typecheck match warnings share the `matchWarnings` channel but carry
-- distinct codes; disambiguate by the message shape (the unreachable-arm warning
-- names an "unreachable match arm", the exhaustiveness one does not).
matchWarnCode : String -> String
matchWarnCode w
  | startsWith "Warning: unreachable match arm" w = "W-UNREACHABLE-ARM"
  | otherwise = "W-NONEXHAUSTIVE"

-- Derive the JSON `kind` from a code's per-stage prefix (DIAGNOSTIC-CODES-DESIGN
-- §2): L→lex, P→parse, R→resolve, T→type, W→warning.  An unrecognized prefix
-- falls back to "error".
export codeKind : String -> String
codeKind code
  | startsWith "L-" code = "lex"
  | startsWith "P-" code = "parse"
  | startsWith "R-" code = "resolve"
  | startsWith "T-" code = "type"
  | startsWith "W-" code = "warning"
  | startsWith "rule-" code = "lint"
  | otherwise = "error"

-- The reserved-keyword-in-identifier-position diagnostic (parser.mdk's
-- `reservedKeywordMsg`) reads ``<word>` is a reserved keyword — …`.  Its stable
-- marker is the substring "is a reserved keyword" (the word itself varies, so a
-- prefix match won't do); the offending keyword is the text between the first
-- pair of backticks.  Recover it here — from the message the diagnostic already
-- carries, no re-lex — so both the code mapping and the rename `fix` can reuse it.
isReservedKwMsg : String -> Bool
isReservedKwMsg msg = match stringIndexOf "is a reserved keyword" msg
  Some _ => True
  None => False

wordBetweenBackticks : String -> Option String
wordBetweenBackticks msg = match stringIndexOf "`" msg
  None => None
  Some i =>
    let rest = stringSlice (i + 1) (stringLength msg) msg
    map (j => stringSlice 0 j rest) (stringIndexOf "`" rest)

-- Every backtick-quoted substring in `msg`, in order. The malformed-literal
-- lex messages (#677) embed BOTH the offending spelling and the suggested
-- one (`` `bad`: … write `good` ``), so a two-element read of this list is
-- exactly the (old, new) pair a machine `fix` needs — without re-deriving
-- either from the diagnostic's single-point `Loc`, which only pins the START
-- column, not a length.
allBacktickWords : String -> List String
allBacktickWords msg = match stringIndexOf "`" msg
  None => []
  Some i =>
    let rest = stringSlice (i + 1) (stringLength msg) msg
    match stringIndexOf "`" rest
      None => []
      Some j =>
        let word = stringSlice 0 j rest
        let after = stringSlice (j + 1) (stringLength rest) rest
        word :: allBacktickWords after

twoBacktickWords : String -> Option (String, String)
twoBacktickWords msg = match allBacktickWords msg
  a::b::_ => Some (a, b)
  _ => None

-- A whole-literal replacement `Fix`, spanning exactly `[sc, sc + len(old))` —
-- the malformed spelling — replaced with the suggested one.
oldNewFixOf : String -> Int -> Int -> (String, String) -> Fix
oldNewFixOf f sl sc (old, new) =
  Fix (Loc f sl sc sl (sc + stringLength old)) new

-- Stable code for a parse/lex diagnostic, recovered at the ParseError→Diag
-- boundary from the message (a lexer TLexError surfaces as a ParseError; lexer
-- messages map to `L-*`, specifically recognized parse errors to their own `P-*`,
-- and everything else to the umbrella `P-PARSE`).
--
-- The guard clauses below ARE the list — do not restate their number here. This
-- comment used to count them ("the four lexer messages", "the two special parse
-- cases"); both counts had silently rotted, in the one file whose whole job is
-- mapping messages to codes. A count encodes a fact with no derivation and no
-- expiry (.claude/ORCHESTRATING.md, "DERIVE, don't encode"), so it goes stale the
-- next time anyone adds a clause and nothing notices — which is exactly how it
-- rotted, unremarked, twice. Read the clauses; they cannot lie.
export parseErrCode : String -> String
parseErrCode msg
  | startsWith "unterminated string" msg = "L-UNTERMINATED-STRING"
  | startsWith "unterminated block" msg = "L-UNTERMINATED-COMMENT"
  | startsWith "invalid escape" msg = "L-BAD-ESCAPE"
  | startsWith "unicode escape" msg = "L-BAD-UNICODE-ESCAPE"
  | startsWith "bare unicode escape" msg = "L-BARE-UNICODE-ESCAPE"
  | startsWith "character literal" msg = "L-BAD-CHAR-LITERAL"
  | startsWith "unexpected '\\'" msg = "L-HS-LAMBDA"
  | startsWith "Medaka has no '$'" msg = "L-HS-DOLLAR"
  | startsWith "unexpected character" msg = "L-BAD-CHAR"
  | startsWith "integer literal too large" msg = "L-INT-OVERFLOW"
  | startsWith "float literal out of range" msg = "L-FLOAT-OVERFLOW"
  | startsWith "malformed radix literal" msg = "L-MALFORMED-RADIX"
  | startsWith "malformed float literal" msg = "L-MALFORMED-FLOAT"
  | startsWith "unexpected end of input" msg = "P-UNEXPECTED-EOF"
  | startsWith "unexpected '/='" msg = "P-BAD-NEQ"
  | startsWith "Medaka has no 'case" msg = "P-HS-CASE"
  | startsWith "Use '::' for List cons" msg = "P-HS-SIG"
  | startsWith "Medaka has no '/* " msg = "L-BLOCKCOMMENT"
  | startsWith "unexpected '{'. Medaka has no brace" msg = "P-BRACE-BLOCK"
  | startsWith "Medaka has no 'for'" msg = "P-FOR-WHILE"
  | startsWith "Medaka has no 'while'" msg = "P-FOR-WHILE"
  | startsWith "Medaka has no 'def'" msg = "P-DEF-KEYWORD"
  | startsWith "Medaka has no statement terminator" msg = "L-SEMICOLON"
  | isReservedKwMsg msg = "P-RESERVED-KEYWORD"
  | otherwise = "P-PARSE"

-- Build the (help, fix) pair for the two parse-error hints with a clean,
-- mechanical single-token fix (the Haskell `::`-signature carveout and the
-- `/=`-inequality hint).  Both hints' pre-scan already reports a `Loc` whose
-- start col points at the offending token's first character (verified against
-- `medaka check --json`: `::` and `/=` both start exactly at `sc`), so the fix
-- span is `[sc, sc+2)` — the two-character token — regardless of the diag's
-- own (single-char, display-only) range.  Every other parse hint (`\x->`, `$`,
-- `case…of`) needs a multi-edit rewrite, so it stays help/message-only (no
-- `fix`) — this is deliberately narrow, not a general parse-error-fix engine.
export parseErrHelpFix : String -> Loc -> (Option String, Option Fix)
parseErrHelpFix msg (Loc f sl sc el ec)
  | startsWith "Use '::' for List cons" msg = (
    Some "replace '::' with ':' for a type signature",
    Some (Fix (Loc f sl sc sl (sc + 2)) ":"),
  )
  | startsWith "unexpected '/='" msg = (
    Some "replace '/=' with '!=' for not-equal",
    Some (Fix (Loc f sl sc sl (sc + 2)) "!="),
  )
  | startsWith "integer literal too large for Int (max 4611686018427387903)" msg = (Some "`Int` is 63-bit, spanning [-4611686018427387904, 4611686018427387903]; 4611686018427387904 fits only as the NEGATIVE -4611686018427387904, so write it with its `-`", None)
  -- Malformed radix/float literals (#677): the lexer already embeds BOTH the
  -- offending spelling and its suggested fix in backticks (`` `bad` … `good` ``),
  -- so the fix span is `[sc, sc + len(bad))` — the malformed literal itself,
  -- starting exactly where the diag is anchored (the lexer raises the error at
  -- the literal's own start, not a downstream victim). When the literal has no
  -- safe suggested spelling (`0x_`, digits nowhere in sight), the message
  -- carries only the one `bad` backtick pair and `twoBacktickWords` returns
  -- `None` — help stays, `fix` doesn't.
  -- Bare `\uXXXX` unicode escape (#515): the lexer's message already embeds
  -- both spellings as the first two backtick pairs (`` `\uXXXX` `` then
  -- `` `\u{XXXX}` ``), so this reuses the SAME (old, new) machinery the
  -- malformed-radix/malformed-float hints use just above — no bespoke
  -- fix-building needed.
  | startsWith "bare unicode escape" msg = (
    Some "Medaka's unicode escape is braced (`\\u{XXXX}`) — there is no bare `\\uXXXX` form",
    map (oldNewFixOf f sl sc) (twoBacktickWords msg),
  )
  | startsWith "malformed radix literal" msg = (
    Some "the digit separator '_' can only appear BETWEEN digits, never immediately after the base prefix ('0x'/'0b'/'0o')",
    map (oldNewFixOf f sl sc) (twoBacktickWords msg),
  )
  | startsWith "malformed float literal" msg = (
    Some "Medaka requires a digit on both sides of the decimal point in a float literal",
    map (oldNewFixOf f sl sc) (twoBacktickWords msg),
  )
  -- A reserved keyword used as a name: rename by appending `_` (any reserved word
  -- + `_` is a legal identifier).  The diagnostic's `sc` already points at the
  -- keyword's first char, so the fix span is `[sc, sc + len(word))` — the same
  -- `sc + stringLength …` span the did-you-mean resolve fix uses.
  | isReservedKwMsg msg = match wordBetweenBackticks msg
    Some w => (
      Some "rename it — appending `_` (e.g. `\{w}_`) makes any reserved word a valid identifier",
      Some (Fix (Loc f sl sc sl (sc + stringLength w)) "\{w}_"),
    )
    None => (None, None)
  -- `public` in front of anything but `data` (#67): `afterPublicFor`
  -- (`compiler/frontend/parser.mdk`) now reports this AT the `public` token
  -- itself (captured via `getPos` before it's consumed), so `sc` already
  -- points at its first char — the fix is a clean single-token deletion, the
  -- same shape as the reserved-keyword rename above.
  | startsWith "`public` only applies to `data` declarations" msg = (
    Some "`public` only makes a `data` export its constructors too; a function or value is exported with plain `export` — drop `public` here",
    Some (Fix (Loc f sl sc sl (sc + stringLength "public")) ""),
  )
  | otherwise = (None, None)

-- ── rendering ──────────────────────────────────────────────────────────────

export ppSeverity : Severity -> String
ppSeverity SevError = "error"
ppSeverity SevWarning = "warning"

-- Render a diagnostic as "severity: message" (loc-free, diffable against
-- the location-stripped oracle — the loc is consumed by the LSP, not this text
-- form, so the diff gate stays byte-identical).
export ppDiag : Diag -> String
ppDiag (Diag sev _ msg _ _ _) = "\{ppSeverity sev}: \{msg}"

-- Plain-text CLI renderer (Stage-A positioned output, Stage-C carat block).
-- line is 1-based (matches the oracle's plain-text convention); col is 0-based.
-- With a loc this reproduces the OCaml oracle's carat diagnostic byte-for-byte
-- (bin/main.ml `show_snippet` :14-24):
--
--     file:line:col: message
--       |
--     N | <source line>
--       | <col spaces>^
--
-- None loc → loc-free "severity: message" (resolve errors with no node span,
-- whole-doc range).  `src` is the target file's source text (to echo the
-- offending line); when the source line can't be read the carat block is
-- omitted (mirrors `show_snippet`'s `None -> ()`), leaving just the header.
export ppDiagCli : String -> Diag -> String
ppDiagCli file diag = ppDiagCliSrc "" file diag

-- Stage-C: carat-aware renderer.  `src` carries the file's source text.
export ppDiagCliSrc : String -> String -> Diag -> String
ppDiagCliSrc src file (Diag _ _ msg (Some (Loc _ sl sc _ _)) _ _) =
  let header = "\{file}:\{intToString sl}:\{intToString sc}: \{msg}"
  match nthLine src sl
    None => header
    Some lineText =>
      "\{header}\n  |\n\{intToString sl} | \{lineText}\n  | \{spaces sc}^"
ppDiagCliSrc _ _ (Diag _ _ msg None _ _) = "<unknown location>: " ++ msg

-- `spaces n` = a string of n space characters (the oracle's `String.make col ' '`).
spaces : Int -> String
-- Intentional cross-file duplicate of the same helper in printer.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
spaces n
  | n <= 0 = ""
  | otherwise = " " ++ spaces (n - 1)

-- 1-based Nth line of `src` (`\n`-separated), or None if out of range — mirrors
-- the oracle's `List.split_on_char '\n' source` then `List.nth_opt (line-1)`.
nthLine : String -> Int -> Option String
nthLine src n = nthLineGo (stringToChars src) 0 (stringLength src) 1 n ""

nthLineGo : Array Char -> Int -> Int -> Int -> Int -> String -> Option String
nthLineGo cs i len cur target acc
  | i >= len = if cur == target then Some acc else None
  | arrayGetUnsafe i cs == '\n' =
    if cur == target then
      Some acc
    else
      nthLineGo cs (i + 1) len (cur + 1) target ""
  | otherwise = nthLineGo cs (i + 1) len cur target (acc ++ charToStr (arrayGetUnsafe i cs))

-- ── single-file analysis ───────────────────────────────────────────────────
--
-- Mirrors lib/diagnostics.ml's `analyze`: runs parse → desugar → resolve →
-- guard-exhaustiveness → typecheck, accumulating all stages' diagnostics.
-- Does NOT stop on the first error (errors accumulate).
--
-- Arguments: runtimeSrc (runtime.mdk source), coreSrc (core.mdk source),
-- progSrc (target source).

export analyze : String -> String -> String -> List Diag
analyze runtimeSrc coreSrc progSrc =
  analyzeFrom runtimeSrc coreSrc (parse progSrc) []

-- B.10.2b: the LSP path runs the same pipeline but parses the target with
-- `parseLocated` so the ELoc wrappers carry REAL line/col spans (the pure
-- `parse` carries placeholder locs).  Type-error Diags then surface the true
-- expr-level span; runtime/core stay on `parse` (their locs are never reported).
export analyzeLocated : String -> String -> String -> List Diag
analyzeLocated runtimeSrc coreSrc progSrc =
  analyzeFrom runtimeSrc coreSrc (parseLocated progSrc) []

-- B.10.x: like analyzeLocated but enforcing the internal-extern guard unless
-- `allowInternal` is set (the single-file `medaka check` error path).  Other
-- callers (LSP, playground) keep `analyzeLocated`, which is unguarded.
export analyzeLocatedG : Bool -> String -> String -> String -> List Diag
analyzeLocatedG allowInternal runtimeSrc coreSrc progSrc =
  analyzeFrom
    runtimeSrc
    coreSrc
    (parseLocated progSrc)
    (internalGuardFor allowInternal)

-- Shared analysis body, parameterised over the already-parsed target program
-- (so `analyze` can pass placeholder-loc `parse` decls and `analyzeLocated` can
-- pass real-loc `parseLocated` decls without duplicating the pipeline).
-- `internalGuard` is the internal-extern guard list (empty ⇒ unrestricted).
analyzeFrom : String -> String -> List Decl -> List String -> List Diag
analyzeFrom runtimeSrc coreSrc raw internalGuard =
  let desugared = desugar raw
  let runtimeP = desugar (parse runtimeSrc)
  let coreP = desugar (parse coreSrc)
  -- Oracle superset = target + prelude (runtime + core) so exhaustiveness of a
  -- multi-clause function over a prelude ADT (Result/Option/…) isn't false-flagged.
  let guardWarns = checkGuardExhaustivenessWith (raw ++ runtimeP ++ coreP) raw
  -- Derives live only on the RAW tree (`desugar` clears the field), so this reads
  -- `raw`, not `desugared`.
  let deriveDiags = map deriveErrToDiag (checkDerives raw)
  let resErrs = resolveProgramG2 internalGuard runtimeP coreP desugared
  let resDiags = map diagOfResError resErrs
  let _ = setCoherenceUserDecls desugared
  let tcDiags = match resErrs
    [] =>
      let (tcErrs, tcWarns) = checkProgramDiags runtimeP coreP desugared
      map diagOfTypeError tcErrs ++ map diagOfMatchWarning tcWarns
    _ => []
  -- AUTO-PRINT visibility (composite-main design §10): a bare non-Unit VALUE main
  -- (`main = (Red, 5)`) is auto-printed via `Display` at emit, so its Display
  -- obligation must surface in `check`/LSP/playground too — not only at `build`.
  -- Mirror the emit driver's wrap+recheck: wrap `main = <e>` → `main = println <e>`
  -- and re-run the check gate on the wrapped single module (underivedMainDiags).
  -- Gated on shouldAutoPrintMain (needs the elaborate above to have set main's
  -- type), so a Unit/Async/function main and a satisfied value main add nothing.
  let autoDiags = match resErrs
    [] => filterNewDiags tcDiags (autoPrintObligationDiags runtimeP coreP desugared)
    _ => []
  let guardDiags = map guardWarnToDiag guardWarns
  deriveDiags ++ guardDiags ++ resDiags ++ tcDiags ++ autoDiags

-- The auto-print Display obligation for a bare non-Unit value main, as located
-- Diags (empty when the wrap doesn't fire or the obligation is satisfied).
-- underivedMainDiags re-runs the WHOLE check on the wrapped program, so it also
-- re-reports every non-auto-print error already in `tcDiags`; `filterNewDiags`
-- (at the call site) drops those, keeping only the wrap-introduced obligation.
autoPrintObligationDiags : List Decl -> List Decl -> List Decl -> List Diag
autoPrintObligationDiags runtimeP coreP desugared =
  let modules = [("__main__", desugared)]
  if shouldAutoPrintMain coreP modules then
    map diagOfTypeError (underivedMainDiags runtimeP coreP (autoPrintWrapModules modules))
  else
    []

diagMsg : Diag -> String
diagMsg (Diag _ _ m _ _ _) = m

-- Keep only [news] Diags whose message isn't already present in [existing] — so
-- the auto-print re-check contributes ONLY its wrap-introduced obligation, never a
-- duplicate of an error the primary check already reported.
filterNewDiags : List Diag -> List Diag -> List Diag
filterNewDiags existing news =
  filterList (d => not (anyList (e => diagMsg e == diagMsg d) existing)) news
-- resolve over runtime + core (prelude) + target

-- resolve has no per-error loc in the compiler pipeline → None.

-- Stage the user decls for coherence (mirrors check.mdk's setCoherenceUserDecls).

-- Only run typecheck when resolve found no errors (same gate as diagnostics.ml).

-- each tcErr is (msg, Option Loc): carry the captured span (B.10.2b).

-- Strip the leading "Warning: " prefix that exhaust/typecheck include in their
-- warning strings, so ppDiag emits "warning: <msg>" not "warning: Warning: <msg>".
-- Convert an exhaustiveness warning (message + optional per-group loc) to a Diag,
-- keying the stable code off the message shape: a constructor-coverage warning on
-- a multi-clause function is `W-NONEXHAUSTIVE-CLAUSES`; a guard gap stays
-- `W-GUARD-INEXHAUSTIVE`.
-- #421: an unknown `deriving (…)` name.  An ERROR, not a warning: the clause
-- silently generated NOTHING, so the program is already broken — it just fails
-- later and elsewhere ("No impl of Banana for X" at the first use site), or never,
-- if that impl is only needed on a rare path.  Naming it where it is written is
-- the whole point.
deriveErrToDiag : (String, Option Loc) -> Diag
deriveErrToDiag (msg, loc) = mkDiag SevError "R-CANNOT-DERIVE" msg loc

guardWarnToDiag : (String, Option Loc) -> Diag
guardWarnToDiag (msg, loc) =
  mkDiag SevWarning (exhaustWarnCode msg) (stripWarnPrefix msg) loc

exhaustWarnCode : String -> String
exhaustWarnCode msg
  | startsWith "Warning: non-exhaustive clauses" msg = "W-NONEXHAUSTIVE-CLAUSES"
  | otherwise = "W-GUARD-INEXHAUSTIVE"

stripWarnPrefix : String -> String
stripWarnPrefix s =
  if stringSlice 0 9 s == "Warning: " then
    stringSlice 9 (stringLength s) s
  else
    s

-- ── text entry point (for diff gate) ──────────────────────────────────────

export analyzeToLines : String -> String -> String -> String
analyzeToLines runtimeSrc coreSrc progSrc =
  joinNl (map ppDiag (analyze runtimeSrc coreSrc progSrc))

-- ── helpers ────────────────────────────────────────────────────────────────

-- ── multi-file / project-wide analysis (B.10.5) ─────────────────────────────
--
-- Mirror of lib/diagnostics.ml's `analyze_project` (:335-479): load a root file's
-- transitive import graph with an unsaved-buffer override, then run desugar /
-- resolve / typecheck per module, BUCKETING every diagnostic by its file so the
-- LSP can publish one set of squiggles per file.  Clean files publish `[]` (their
-- bucket is seeded empty), and a bad file does NOT sink the batch — the
-- Result-returning loader + the per-module resolve/typecheck threading make
-- "continue past a broken file" natural (no try/catch needed).
--
-- Selfhost deviations from the OCaml model, all faithful where it matters:
--   * Buckets / the last-good cache are ASSOCIATION LISTS (`List (file, …)`), not
--     a Hashtbl/Map — the established compiler idiom (cf. lsp.mdk's `Docs`); a
--     project opens a handful of files so linear scan is fine, and `Map` is not in
--     the implicit prelude (it lives in stdlib/map.mdk, unreachable from the
--     single-root compiler tree).
--   * Per-module TYPECHECK threads the shared prelude (core) + runtime externs
--     through the exported multi-module `checkModulesDiags`, which runs each
--     module ISOLATED via `checkModuleFull` (only earlier modules' PUBLIC
--     schemes/data are seeded) and harvests that module's own diagnostics by
--     snapshotting the typeErrors/matchWarnings refs after its check (each module
--     starts with resetState ()).  This keeps a private same-named helper in one
--     module from colliding with a different-typed one in another — the
--     per-module-frame property the OCaml `typecheck_module` has.  Resolve uses
--     the exported per-module `resolveModule` directly (it threads exports).

-- A per-file bucket of diagnostics, in dependency order.  Newest pushed last.
-- file → reversed-or-forward diag list; we keep forward order by appending.

-- Look a file's bucket up in the assoc list (None = not seeded yet).
lookupBucket : String -> List (String, List Diag) -> Option (List Diag)
lookupBucket _ [] = None
lookupBucket f ((k, v)::rest)
  | k == f = Some v
  | otherwise = lookupBucket f rest

-- Replace (or insert) a file's bucket.  Preserves order: an existing key keeps
-- its position; a new key is appended at the end (so files appear in load order).
putBucket : String -> List Diag -> List (String, List Diag) -> List (String, List Diag)
putBucket f v [] = [(f, v)]
putBucket f v ((k, old)::rest)
  | k == f = (f, v)::rest
  | otherwise = (k, old) :: putBucket f v rest

-- Append one diagnostic to a file's bucket (seeding the bucket if absent).
pushDiag : String -> Diag -> List (String, List Diag) -> List (String, List Diag)
pushDiag f d buckets = match lookupBucket f buckets
  None => putBucket f [d] buckets
  Some ds => putBucket f (ds ++ [d]) buckets

-- Seed an empty bucket for a file (no-op if already present) so a clean file
-- still appears in the result with `[]` (mirror the empty-bucket seeding).
seedBucket : String -> List (String, List Diag) -> List (String, List Diag)
seedBucket f buckets = match lookupBucket f buckets
  None => putBucket f [] buckets
  Some _ => buckets

-- Append a whole list of diagnostics to one file's bucket.
pushDiags : String -> List Diag -> List (String, List Diag) -> List (String, List Diag)
pushDiags _ [] buckets = buckets
pushDiags f (d::ds) buckets = pushDiags f ds (pushDiag f d buckets)

-- ── last-good-source cache + wrapped read (mirror wrapped_read) ─────────────
--
-- The cache is a `Ref (List (file, lastSourceThatParsed))`.  `wrappedRead` is the
-- callback handed to the loader: it consults the user's `read` (open buffers),
-- and when the current buffer FAILS to parse it (a) records the real parse-error
-- diagnostic in `staleRef` (so the user still sees the squiggle) and (b) returns
-- the last source that parsed (so one broken file doesn't blank the whole
-- project's downstream analysis).  A buffer that parses updates the cache.

cachePut : String -> String -> List (String, String) -> List (String, String)
cachePut f v xs = (f, v) :: cacheRemove f xs

cacheRemove : String -> List (String, String) -> List (String, String)
cacheRemove _ [] = []
cacheRemove f ((k, v)::rest)
  | k == f = cacheRemove f rest
  | otherwise = (k, v) :: cacheRemove f rest

-- The wrapped read callback.  `cacheRef` persists last-good sources across
-- analyses (threaded by the caller); `staleRef` collects this round's parse
-- errors (file → Diag) to append after the graph analysis.
wrappedRead : Ref (List (String, String)) -> Ref (List (String, Diag)) -> (String -> Option String) -> String -> Option String
wrappedRead cacheRef staleRef read path = match read path
  None => None
  Some src => match parseResult src
    Ok _ =>
      let _ = setRef cacheRef (cachePut path src cacheRef.value)
      Some src
    Err e =>
      let _ = setRef staleRef ((path, parseErrDiag path e)::staleRef.value)
      match lookupAssoc path cacheRef.value
        Some good => Some good
        None => Some src  -- no cached version → use the broken one
-- fall back to the last source that parsed

-- A parse-error `Loc` for the editing buffer (1-based line, 0-based col), so the
-- LSP can squiggle the offending token (mirror parseResult's located line/col).
parseErrLoc : String -> ParseError -> Loc
parseErrLoc path e =
  let ln = parseErrorLine e
  let c = parseErrorCol e
  Loc path ln c ln (c + 1)

-- A located parse/lex `Diag` for `path`, carrying the stable `P-*`/`L-*` code and
-- any machine-applicable fix.  One definition shared by the stale-buffer path and
-- the loader's `LoadParseFailed` path (#100) so an imported module's parse error
-- is byte-for-byte the diagnostic that file gets when checked directly.
export parseErrDiag : String -> ParseError -> Diag
parseErrDiag path e =
  let ploc = parseErrLoc path e
  let (phelp, pfix) = parseErrHelpFix (parseErrorMessage e) ploc
  Diag
    SevError
    (parseErrCode (parseErrorMessage e))
    (parseErrorMessage e)
    (Some ploc)
    phelp
    pfix

-- ── project analysis ────────────────────────────────────────────────────────
--
-- runtimeSrc / coreSrc seed the extern + prelude scope (as in `analyze`); `read`
-- supplies open-buffer overrides; entry + roots drive the loader.  Returns one
-- (file, List Diag) per file in the graph (clean files → []).
--
-- LSP latency (parse-cache): the LSP runs this on EVERY didChange.  `parseCacheRef`
-- is a session-lived source→decls memo threaded by the caller; the import graph is
-- loaded via loadProgramFilesLocatedCached so an UNCHANGED dependency module skips
-- re-parsing (only the edited entry buffer's new source misses).  The runtime/core
-- prelude desugar is memoized in the SAME cache (keyed by its source) — constant
-- across the session.  Passing a fresh `Ref []` reproduces the old uncached cost
-- exactly (correctness is identical; only the wall-clock per keystroke drops).

-- Memoized prelude desugar: parse+desugar the runtime/core source once per session,
-- keyed by source in the shared parse cache (its keys never collide with a module's
-- source).  A miss parses+desugars and inserts; a hit returns the cached decls.
preludeDesugared : Ref (List (String, List Decl)) -> String -> List Decl
preludeDesugared parseCacheRef src = match lookupAssoc src parseCacheRef.value
  Some decls => decls
  None =>
    let decls = desugar (parse src)
    let _ = setRef parseCacheRef ((src, decls)::parseCacheRef.value)
    decls

export analyzeProject : Ref (List (String, String)) -> Ref (List (String, List Decl)) -> (String -> Option String) -> String -> List String -> String -> String -> <IO> List (String, List Diag)
analyzeProject cacheRef parseCacheRef read entry roots runtimeSrc coreSrc =
  let staleRef = newStale ()
  let wread = p => wrappedRead cacheRef staleRef read p
  let runtimeP = preludeDesugared parseCacheRef runtimeSrc
  let coreP = preludeDesugared parseCacheRef coreSrc
  match loadProgramFilesLocatedCachedE parseCacheRef wread entry roots
    -- #100: a parse/lex error in a dependency is attributed to THAT module's file
    -- with its own located `P-*`/`L-*` diag — this is the LSP's most common input
    -- (a half-typed buffer), and it used to reach here as a panic that took the
    -- whole didChange response with it.
    Err (LoadParseFailed mpath _ pe) =>
      appendStale staleRef [(mpath, [parseErrDiag mpath pe])]
    Err (LoadMsg e) =>
      appendStale staleRef [(entry, [mkDiag SevError "R-MODULE-LOAD" e None])]
    Ok mods =>
      let seeded = seedAll (map midPath mods) []
      let afterRes = resolvePass runtimeP coreP [] mods seeded
      let afterTc = typecheckPass runtimeP coreP [] mods afterRes
      appendStale staleRef afterTc
-- A load error (cycle / unknown module / unreadable file) is attributed to the
-- entry file (the compiler loader returns a single Err string without a per-file
-- split, unlike the OCaml attribute_load_error; entry is the conservative
-- fallback there too for cycle/ambiguous).

-- LSP project-aware hover/completion: load the graph rooted at `entry` (the same
-- loader + cache + read disk-fallback analyzeProject uses) and return the ENTRY
-- module's own top-level schemes.  Running `checkModules` ALSO populates the
-- typecheck hover side-channels (localSchemesOut/seedSchemesOut) for the entry
-- module (checked last), so its locals and its import-scoped seed (runtime + core
-- + imported names) are available to the hover lookup fallback chain.  None on a
-- load error (a buffer with an unresolved import) — hover then degrades to null.
export projectEntrySchemes : Ref (List (String, String)) -> Ref (List (String, List Decl)) -> (String -> Option String) -> String -> List String -> String -> String -> <IO> Option (List (String, Scheme))
projectEntrySchemes cacheRef parseCacheRef read entry roots runtimeSrc coreSrc =
  let staleRef = newStale ()
  let wread = p => wrappedRead cacheRef staleRef read p
  let runtimeP = preludeDesugared parseCacheRef runtimeSrc
  let coreP = preludeDesugared parseCacheRef coreSrc
  match loadProgramFilesLocatedCached parseCacheRef wread entry roots
    Err _ => None
    Ok mods => Some (entryOwnSchemes (checkModules runtimeP coreP (map midToDesugaredPair mods)))

-- resolve per module (threading exports), bucketing by file.

-- typecheck per module via prefix-diff, bucketing by file.

-- finally fold in the stale parse-error diagnostics (and seed their files).

-- newStale: a fresh per-call stale-collection Ref.
newStale : Unit -> Ref (List (String, Diag))
newStale _ = Ref []

-- (modId, path, decls) → path (the bucket key) and the desugared decls helper.
midPath : (String, String, List Decl) -> String
midPath (_, p, _) = p

seedAll : List String -> List (String, List Diag) -> List (String, List Diag)
seedAll [] buckets = buckets
seedAll (f::fs) buckets = seedAll fs (seedBucket f buckets)

-- Append the collected stale parse-error diagnostics into their files' buckets
-- (seeding the bucket first so the file appears even if it produced nothing else).
appendStale : Ref (List (String, Diag)) -> List (String, List Diag) -> List (String, List Diag)
appendStale staleRef buckets = foldStale staleRef.value buckets

foldStale : List (String, Diag) -> List (String, List Diag) -> List (String, List Diag)
foldStale [] buckets = buckets
foldStale ((path, d)::rest) buckets =
  foldStale rest (pushDiag path d (seedBucket path buckets))

-- ── resolve pass (per module, threading exports) ────────────────────────────
-- Mirror analyze_project's resolve loop: resolveModule per module in dependency
-- order, accumulating ModuleExports, bucketing each module's errors by its file.
-- Resolve errors have no per-error loc in the compiler pipeline → None.
resolvePass : List Decl -> List Decl -> List ModuleExports -> List (String, String, List Decl) -> List (String, List Diag) -> List (String, List Diag)
resolvePass _ _ _ [] buckets = buckets
resolvePass rt core known ((mid, path, prog)::rest) buckets =
  let desugared = desugar prog
  let (exp, errs) = resolveModule rt core known mid desugared
  let diags = map diagOfResError errs
  resolvePass rt core (exp::known) rest (pushDiags path diags buckets)

-- ── typecheck pass (per module, ISOLATED) ───────────────────────────────────
-- Run the shared multi-module typecheck (`checkModulesDiags`): core + runtime are
-- seeded ONCE and each module is checked in its OWN frame via `checkModuleFull`
-- (only earlier modules' PUBLIC schemes/data carry forward), harvesting that
-- module's own diagnostics from the typeErrors/matchWarnings refs.  This gives the
-- per-module isolation OCaml's `typecheck_module` has, so a private helper named
-- the same across two modules but with different types never collides.
-- Guard-exhaustiveness warnings still come from the RAW (pre-desugar) module decls
-- (checkGuardExhaustiveness needs the surface `EGuards` shape, gone after desugar),
-- bucketed per file alongside the module's type diagnostics.
typecheckPass : List Decl -> List Decl -> List Decl -> List (String, String, List Decl) -> List (String, List Diag) -> List (String, List Diag)
typecheckPass runtimeP coreP _ mods buckets =
  let modPairs = map midToDesugaredPair mods
  let tcByMid = checkModulesDiags runtimeP coreP modPairs
  -- Oracle superset = prelude + EVERY loaded module's decls, so a multi-clause
  -- function over an imported ADT isn't false-flagged as non-exhaustive.
  let oracleDecls = runtimeP ++ coreP ++ flatMap rawDeclsOfMod mods
  foldModuleTc oracleDecls mods tcByMid buckets

rawDeclsOfMod : (String, String, List Decl) -> List Decl
rawDeclsOfMod (_, _, prog) = prog

-- (mid, path, rawDecls) → (mid, desugared decls) for checkModulesDiags.
midToDesugaredPair : (String, String, List Decl) -> (String, List Decl)
midToDesugaredPair (mid, _, prog) = (mid, desugar prog)

-- Whenever `import` is present the multi-module path runs BOTH resolve and
-- typecheck over the same file, and an unbound name is a resolve-phase fact —
-- resolve already reported it (with the did-you-mean / import hint) before
-- typecheck ever ran. Typecheck's own `T-UNBOUND` for that identical
-- occurrence is therefore pure duplication; only the resolve diagnostic
-- carries the actionable hint, so it's the one that should survive. Matched by
-- (code pair, identical Loc) — never by message text, and never by code alone
-- (two DIFFERENT unbound names must each keep their own diagnostic).
diagLoc : Diag -> Option Loc
diagLoc (Diag _ _ _ loc _ _) = loc

diagCode : Diag -> String
diagCode (Diag _ code _ _ _ _) = code

locEq : Loc -> Loc -> Bool
locEq (Loc f1 sl1 sc1 el1 ec1) (Loc f2 sl2 sc2 el2 ec2) = f1 == f2
  && sl1 == sl2
  && sc1 == sc2
  && el1 == el2
  && ec1 == ec2

-- True when `d` is a T-UNBOUND diagnostic whose Loc exactly matches an
-- R-UNBOUND diagnostic already sitting in this file's bucket (i.e. resolve
-- already reported this exact occurrence).
isRedundantUnbound : List Diag -> Diag -> Bool
isRedundantUnbound existing d
  | diagCode d != "T-UNBOUND" = False
  | otherwise = match diagLoc d
    None => False
    Some dl => anyList (e => diagCode e == "R-UNBOUND" && (match diagLoc e
      Some el => locEq dl el
      None => False)) existing

-- For each (mid, path, rawProg): look up its harvested (errs, warns) by mid, wrap
-- them as Diags (preserving each type error's Option Loc), fold in this module's
-- guard-exhaustiveness warnings from the raw decls, and bucket by path.
foldModuleTc : List Decl -> List (String, String, List Decl) -> List (String, (List TcDiag, List TcDiag)) -> List (String, List Diag) -> List (String, List Diag)
foldModuleTc _ [] _ buckets = buckets
foldModuleTc oracleDecls ((mid, path, prog)::rest) tcByMid buckets =
  let (tcErrs, tcWarns) = lookupTcDiags mid tcByMid
  let existing = match lookupBucket path buckets
    Some ds => ds
    None => []
  let errDiags = filterList (d => not (isRedundantUnbound existing d)) (map diagOfTypeError tcErrs)
  let warnDiags = map diagOfMatchWarning tcWarns
  let guardWarns = checkGuardExhaustivenessWith oracleDecls prog
  let guardDiags = map guardWarnToDiag guardWarns
  let deriveDiags = map deriveErrToDiag (checkDerives prog)
  let buckets2 = pushDiags path (deriveDiags ++ guardDiags ++ errDiags ++ warnDiags) buckets
  foldModuleTc oracleDecls rest tcByMid buckets2

lookupTcDiags : String -> List (String, (List TcDiag, List TcDiag)) -> (List TcDiag, List TcDiag)
lookupTcDiags _ [] = ([], [])
lookupTcDiags mid ((m, d)::rest)
  | m == mid = d
  | otherwise = lookupTcDiags mid rest

-- ── project text entry point (diff gate) ────────────────────────────────────
-- Render the per-file buckets as one block per file:
--   "## FILE <path>"  followed by each diag's "severity: message" line.
-- The harness splits on the marker and sorts each file's lines, diffing against
-- the OCaml analyze_project's per-file buckets.
export analyzeProjectToLines : Ref (List (String, String)) -> (String -> Option String) -> String -> List String -> String -> String -> <IO> String
analyzeProjectToLines cacheRef read entry roots runtimeSrc coreSrc =
  let parseCacheRef = Ref []
  joinNl (projectLines (analyzeProject
    cacheRef
    parseCacheRef
    read
    entry
    roots
    runtimeSrc
    coreSrc))

projectLines : List (String, List Diag) -> List String
projectLines [] = []
projectLines ((file, ds)::rest) =
  "## FILE " ++ file :: map ppDiagLoc ds ++ projectLines rest

-- Render a diagnostic for the project gate WITH its start position, so the diff
-- can assert positions (the loc is otherwise consumed only by the LSP JSON).
--   "<severity>@<line>:<col>: <message>"   (0-based LSP line/col, mirror
--   range_of_loc: line = startLine-1, character = startCol)
--   "<severity>: <message>"                when the diag carries no loc (None →
--   whole-document range in the LSP; positionless here).
ppDiagLoc : Diag -> String
ppDiagLoc (Diag sev _ msg None _ _) = "\{ppSeverity sev}: \{msg}"
ppDiagLoc (Diag sev _ msg (Some (Loc _ sl sc _ _)) _ _) =
  "\{ppSeverity sev}@\{intToString (sl - 1)}:\{intToString sc}: \{msg}"

-- ── check --json JSON shaping ────────────────────────────────────────────────
-- Shared by medaka_cli.mdk (`medaka check --json`) and playground_main.mdk
-- (wasm playground). Field/key ordering matches OCaml/Yojson alphabetical
-- insertion so the JSON is byte-identical to `medaka check --json`:
--   file entry:   file, diagnostics
--   diagnostic:   message, range, severity, source
--   range:        end, start
--   position:     character, line

-- Build a 0-based LSP Position JSON: { "character": ch, "line": line }
-- (alphabetical: character < line)
export cjPosition : Int -> Int -> Json
cjPosition line ch = jObject [("character", JInt ch), ("line", JInt line)]

-- Build an LSP Range JSON: { "end": ..., "start": ... }
-- (alphabetical: end < start)
export cjRange : Int -> Int -> Int -> Int -> Json
cjRange sl sc el ec =
  jObject [("end", cjPosition el ec), ("start", cjPosition sl sc)]

-- Map an Option Loc to a range (mirror of rangeOfLoc in lsp.mdk).
-- A `None` loc renders the oracle's dummy range {0,0}-{0,0} (lib/diagnostics.ml's
-- `loc_or_dummy` → `dummy_loc` = line 1 col 0 → 0-based {0,0}), NOT a whole-doc
-- span — so resolve / build-phase errors with no node span (Stage B) match the
-- oracle byte-for-byte.
export cjRangeOfLoc : String -> Option Loc -> Json
cjRangeOfLoc src (Some (Loc _ sl sc el ec)) = cjRange (sl - 1) sc (el - 1) ec
cjRangeOfLoc src None = cjRange 0 0 0 0

-- Severity code: Error=1, Warning=2.
cjSevCode : Severity -> Int
cjSevCode SevError = 1
cjSevCode _ = 2

-- Build one diagnostic JSON object with alphabetical field order:
-- { "code": ..., "kind": ..., "message": ..., "range": ..., "severity": ...,
--   "source": "medaka" }.  Stage 1 (DIAGNOSTIC-CODES-DESIGN): every diagnostic
-- (error OR warning) now carries its stable `code` + derived `kind`, a bare
-- `message`, and its REAL loc-derived range.  Warnings are rendered exactly like
-- errors — the old oracle-compat special arm (which baked "path:L:C: Warning:"
-- into the message and emitted a {0,0} dummy range) is gone, so a non-exhaustive
-- match warning now reports a real span.  `path` is unused (kept for the caller's
-- uniform call shape).
-- Stage 2: a single optional JSON field — `[]` when absent so the key is omitted
-- entirely (keeps every non-suggestion diagnostic's JSON byte-identical to Stage 1).
export optField : String -> Option Json -> List (String, Json)
optField k (Some v) = [(k, v)]
optField _ None = []

-- Render a machine-applicable Fix as { "range": {...}, "replacement": "..." },
-- the range covering exactly the span to overwrite (mirrors the LSP text edit).
export cjFixJson : Fix -> Json
cjFixJson (Fix (Loc _ sl sc el ec) repl) = jObject
  [("range", cjRange (sl - 1) sc (el - 1) ec), ("replacement", JString repl)]

export cjDiagnostic : String -> String -> Diag -> Json
cjDiagnostic _ src (Diag sev code msg loc help fix) =
  jObject
    ([("code", JString code)] ++ optField "fix" (map cjFixJson fix) ++ optField "help" (map JString help) ++ [("kind", JString (codeKind code)), ("message", JString msg), ("range", cjRangeOfLoc src loc), ("severity", JInt (cjSevCode sev)), ("source", JString "medaka")])

-- Build the per-file entry: { "file": path, "diagnostics": [...] }.
-- `src` is the file's source text (for whole-doc range fallback).
-- `diags` is the List Diag from analyzeProject.
export cjFileEntry : String -> String -> List Diag -> Json
cjFileEntry path src diags = jObject
  [
    ("file", JString path),
    ("diagnostics", JArray (arrayFromList (map (cjDiagnostic path src) diags))),
  ]

cjTriple : (String, String, List Diag) -> Json
cjTriple (path, src, diags) = cjFileEntry path src diags

-- Serialize the analyzeProject result as the top-level JSON object:
-- { "files": [ { "file": ..., "diagnostics": [...] }, ... ] }
-- Needs sources for whole-doc range fallback.
export cjAllToJson : List (String, String, List Diag) -> String
cjAllToJson triples = stringify (jObject
  [("files", JArray (arrayFromList (map cjTriple triples)))])

-- Read each file's source for the range fallback.  On read error, use "" so
-- diagnostics still serialize (the error itself is in the diag list).
export readDiagSrc : (String, List Diag) -> <IO> (String, String, List Diag)
readDiagSrc (path, diags) = match readFile path
  Ok src => (path, src, diags)
  Err _ => (path, "", diags)

-- Normalize an emitted diagnostic `file` path to project-root-relative (#298).
-- Target + project imports resolve relative to cwd and stay relative, but a
-- stdlib dependency resolves through the absolute stdlibDir root and would
-- otherwise be echoed verbatim — leaking the private worktree layout and making
-- the response internally inconsistent + goldens non-portable.  Stripping the
-- project-root prefix turns `<root>/stdlib/list.mdk` into `stdlib/list.mdk`,
-- matching the already-relative target + project imports (we run from the root,
-- so root == cwd).  A path without the prefix (already relative) passes through.
export relDiagPath : String -> String -> String
relDiagPath root path =
  let pre = root ++ "/"
  if startsWith pre path then
    stringSlice (stringLength pre) (stringLength path) path
  else
    path

relDiagTriple : String -> (String, String, List Diag) -> (String, String, List Diag)
relDiagTriple root (path, src, diags) = (relDiagPath root path, src, diags)

-- ── check → structured-diagnostics JSON ─────────────────────────────────────
--
-- Shared by `medaka check --json` (runCheckJsonCmd in medaka_cli) and the
-- `medaka mcp` medaka_check tool.  Both return (jsonString, hasError): the
-- {"files":[...]} JSON `medaka check --json` emits, plus whether any diagnostic
-- is a hard error (severity 1).  The caller decides what to do — the CLI prints +
-- `exit 1`; MCP wraps the string in a tool result and sets `isError` — so the
-- serializer + routing live in ONE place, byte-for-byte.

-- True iff the diagnostic is a hard error (severity 1), not a warning.
export diagIsError : Diag -> Bool
diagIsError (Diag SevError _ _ _ _ _) = True
diagIsError _ = False

cjHasErrD : (String, List Diag) -> Bool
cjHasErrD (_, diags) = anyList diagIsError diags

-- readFile that yields "" on error (any real read failure surfaces as a diag).
-- Shared with medaka_cli's driver code (which imports it) so the two don't
-- diverge — the one canonical "read a target, tolerate a missing file" helper.
export readFileSafe : String -> <IO> String
readFileSafe path = match readFile path
  Ok src => src
  Err _ => ""

-- The single located parse-error diagnostic, as the {"files":[...]} JSON string.
-- Mirrors runCheckJsonCmd's inline parse-error diag (built inline, not via
-- cjDiagnostic) so a hard parse failure still carries a stable `code`, a range,
-- and — for the two single-token hints — a machine-applicable `fix`.
export cjParseErrJson : String -> String -> ParseError -> String
cjParseErrJson target src e =
  let ln = parseErrorLine e - 1
  let col = parseErrorCol e
  let r = cjRange ln col ln (col + 1)
  let pcode = parseErrCode (parseErrorMessage e)
  let ploc = Loc target (parseErrorLine e) col (parseErrorLine e) (col + 1)
  let (phelp, pfix) = parseErrHelpFix (parseErrorMessage e) ploc
  let diagJson = jObject ([("code", JString pcode)] ++ optField "fix" (map cjFixJson pfix) ++ optField "help" (map JString phelp) ++ [("kind", JString (codeKind pcode)), ("message", JString (parseErrorMessage e)), ("range", r), ("severity", JInt 1), ("source", JString "medaka")])
  let filesJson = jObject [("file", JString target), ("diagnostics", JArray (arrayFromList [diagJson]))]
  stringify (jObject [("files", JArray (arrayFromList [filesJson]))])

-- Single-module check → JSON.  Parse errors are detected FIRST; otherwise the
-- single-file located pipeline runs and its diags serialize via cjAllToJson.
-- Pure — NO import resolution — so it is exactly right for inline `source` (no
-- file on disk to resolve imports against) and for a no-import file.  `target` is
-- the value that lands in each diagnostic's `file` field (cjRangeOfLoc ignores the
-- filename inside each Loc), so an inline check can pass a stable synthetic name.
export checkJsonSingle : Bool -> String -> String -> String -> String -> (String, Bool)
checkJsonSingle allowInternal rsrc csrc target src = match parseResult src
  Err e => (cjParseErrJson target src e, True)
  Ok _ =>
    let diags = analyzeLocatedG allowInternal rsrc csrc src
    (cjAllToJson [(target, src, diags)], anyList diagIsError diags)

-- File check → JSON.  Reads `target`, then routes exactly like runCheckJsonCmd:
-- parse error → single diag; load error (bad import) → R-MODULE-LOAD diag with the
-- import span + available-modules hint; single module → checkJsonSingle (honouring
-- the owning-root trust signal); multi-module → analyzeProject.  `stdlibDir` is the
-- <root>/stdlib dir; roots are derived from the target's directory + stdlibDir.
export checkJsonFile : Bool -> String -> String -> String -> String -> <IO> (String, Bool)
checkJsonFile allowInternal rsrc csrc target stdlibDir =
  let src = readFileSafe target
  let roots = entrySearchRoots (dirOf target) ++ [stdlibDir]
  match parseResult src
    Err e => (cjParseErrJson target src e, True)
    Ok _ => match loadProgramE target roots
      -- #100: a parse/lex error in an IMPORTED module serializes exactly like one
      -- in the entry — same `P-*`/`L-*` code, same real range — only attributed to
      -- the MODULE's file and rendered against the module's OWN source.
      Err (LoadParseFailed mpath msrc pe) => (cjParseErrJson mpath msrc pe, True)
      Err (LoadMsg lmsg) =>
        let mloc = match unknownModuleIdOf lmsg
          None => None
          Some mid => findImportLoc mid (parseLocated src)
        let mhelp = match unknownModuleIdOf lmsg
          None => None
          Some _ => match availableModulesText stdlibDir
            "" => None
            txt => Some txt
        let jmsg = lmsg ++ (match unknownModuleIdOf lmsg
          None => ""
          Some _ => availableModulesHint stdlibDir)
        (
          cjAllToJson [(target, src, [Diag SevError "R-MODULE-LOAD" jmsg mloc mhelp None])],
          True,
        )
      Ok mods => match mods
        [(mid, _)] =>
          let trusted = projectTrustedMods target roots stdlibDir mods
          checkJsonSingle
            (allowInternal || contains mid trusted)
            rsrc
            csrc
            target
            src
        _ =>
          let cacheRef = Ref []
          let parseCacheRef = Ref []
          let results = analyzeProject cacheRef parseCacheRef (_ => None) target roots rsrc csrc
          let triples = map readDiagSrc results
          let root = dirOf stdlibDir
          (
            cjAllToJson (map (relDiagTriple root) triples),
            anyList cjHasErrD results,
          )
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseResult" false) (mem "ParseError" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false) (mem "checkDerives" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "ResError" false) (mem "resolveProgram" false) (mem "resolveProgramG2" false) (mem "internalGuardFor" false) (mem "ppResError" false) (mem "resErrorLoc" false) (mem "resErrorCode" false) (mem "resErrorDidYouMean" false) (mem "resolveModule" false) (mem "ModuleExports" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "checkGuardExhaustivenessWith" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "checkProgramDiags" false) (mem "checkModulesDiags" false) (mem "checkModules" false) (mem "entryOwnSchemes" false) (mem "Scheme" true) (mem "setCoherenceUserDecls" false) (mem "TcDiag" true) (mem "tcMsg" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "LoadMsg" false) (mem "LoadParseFailed" false) (mem "loadProgramFilesLocatedCached" false) (mem "loadProgramFilesLocatedCachedE" false) (mem "loadProgramE" false) (mem "projectTrustedMods" false) (mem "entrySearchRoots" false) (mem "findImportLoc" false) (mem "unknownModuleIdOf" false) (mem "availableModulesText" false) (mem "availableModulesHint" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DUse false (UseGroup ("driver" "main_autoprint") ((mem "shouldAutoPrintMain" false) (mem "autoPrintWrapModules" false) (mem "underivedMainDiags" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "lookupAssoc" false) (mem "startsWith" false) (mem "anyList" false) (mem "filterList" false) (mem "contains" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JInt" false) (mem "JString" false) (mem "JArray" false) (mem "jObject" false) (mem "stringify" false))))
(DData Public "Severity" () ((variant "SevError" (ConPos)) (variant "SevWarning" (ConPos))) ())
(DData Public "Fix" () ((variant "Fix" (ConPos (TyCon "Loc") (TyCon "String")))) ())
(DData Public "Diag" () ((variant "Diag" (ConPos (TyCon "Severity") (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Fix"))))) ())
(DTypeSig true "mkDiag" (TyFun (TyCon "Severity") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Diag"))))))
(DFunDef false "mkDiag" ((PVar "sev") (PVar "code") (PVar "msg") (PVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "sev")) (EVar "code")) (EVar "msg")) (EVar "loc")) (EVar "None")) (EVar "None")))
(DTypeSig true "resErrorHelpFix" (TyFun (TyCon "ResError") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Fix")))))
(DFunDef false "resErrorHelpFix" ((PVar "e")) (EMatch (EApp (EVar "resErrorDidYouMean") (EVar "e")) (arm (PCon "Some" (PTuple (PVar "bad") (PVar "sug"))) () (EBlock (DoLet false false (PVar "help") (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "did you mean '")) (EApp (EVar "display") (EVar "sug"))) (ELit (LString "'?"))))) (DoLet false false (PVar "fix") (EApp (EApp (EVar "map") (ELam ((PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") PWild PWild)) (EApp (EApp (EVar "Fix") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (EApp (EVar "stringLength") (EVar "bad"))))) (EVar "sug")))) (EApp (EVar "resErrorLoc") (EVar "e")))) (DoExpr (ETuple (EVar "help") (EVar "fix"))))) (arm (PCon "None") () (ETuple (EVar "None") (EVar "None")))))
(DTypeSig true "diagOfResError" (TyFun (TyCon "ResError") (TyCon "Diag")))
(DFunDef false "diagOfResError" ((PVar "e")) (EBlock (DoLet false false (PTuple (PVar "help") (PVar "fix")) (EApp (EVar "resErrorHelpFix") (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "resErrorCode") (EVar "e"))) (EApp (EVar "ppResError") (EVar "e"))) (EApp (EVar "resErrorLoc") (EVar "e"))) (EVar "help")) (EVar "fix")))))
(DTypeSig true "diagOfTypeError" (TyFun (TyCon "TcDiag") (TyCon "Diag")))
(DFunDef false "diagOfTypeError" ((PCon "TcDiag" (PVar "code") PWild (PVar "loc") (PVar "msg") (PVar "help") (PVar "fix"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EVar "code")) (EVar "msg")) (EVar "loc")) (EVar "help")) (EApp (EApp (EVar "map") (EVar "fixOfLocRepl")) (EVar "fix"))))
(DTypeSig false "fixOfLocRepl" (TyFun (TyTuple (TyCon "Loc") (TyCon "String")) (TyCon "Fix")))
(DFunDef false "fixOfLocRepl" ((PTuple (PVar "l") (PVar "r"))) (EApp (EApp (EVar "Fix") (EVar "l")) (EVar "r")))
(DTypeSig false "diagOfMatchWarning" (TyFun (TyCon "TcDiag") (TyCon "Diag")))
(DFunDef false "diagOfMatchWarning" ((PCon "TcDiag" PWild PWild (PVar "loc") (PVar "w") (PVar "help") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevWarning")) (EApp (EVar "matchWarnCode") (EVar "w"))) (EApp (EVar "stripWarnPrefix") (EVar "w"))) (EVar "loc")) (EVar "help")) (EVar "None")))
(DTypeSig false "matchWarnCode" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "matchWarnCode" ((PVar "w")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Warning: unreachable match arm"))) (EVar "w")) (ELit (LString "W-UNREACHABLE-ARM")) (EIf (EVar "otherwise") (ELit (LString "W-NONEXHAUSTIVE")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "codeKind" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "codeKind" ((PVar "code")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "L-"))) (EVar "code")) (ELit (LString "lex")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "P-"))) (EVar "code")) (ELit (LString "parse")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "R-"))) (EVar "code")) (ELit (LString "resolve")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "T-"))) (EVar "code")) (ELit (LString "type")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "W-"))) (EVar "code")) (ELit (LString "warning")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "rule-"))) (EVar "code")) (ELit (LString "lint")) (EIf (EVar "otherwise") (ELit (LString "error")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "isReservedKwMsg" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isReservedKwMsg" ((PVar "msg")) (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "is a reserved keyword"))) (EVar "msg")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "wordBetweenBackticks" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "wordBetweenBackticks" ((PVar "msg")) (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "`"))) (EVar "msg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "msg"))) (EVar "msg"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "j")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "j")) (EVar "rest")))) (EApp (EApp (EVar "stringIndexOf") (ELit (LString "`"))) (EVar "rest"))))))))
(DTypeSig false "allBacktickWords" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "allBacktickWords" ((PVar "msg")) (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "`"))) (EVar "msg")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "msg"))) (EVar "msg"))) (DoExpr (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "`"))) (EVar "rest")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "j")) () (EBlock (DoLet false false (PVar "word") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "j")) (EVar "rest"))) (DoLet false false (PVar "after") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "rest"))) (EVar "rest"))) (DoExpr (EBinOp "::" (EVar "word") (EApp (EVar "allBacktickWords") (EVar "after"))))))))))))
(DTypeSig false "twoBacktickWords" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "twoBacktickWords" ((PVar "msg")) (EMatch (EApp (EVar "allBacktickWords") (EVar "msg")) (arm (PCons (PVar "a") (PCons (PVar "b") PWild)) () (EApp (EVar "Some") (ETuple (EVar "a") (EVar "b")))) (arm PWild () (EVar "None"))))
(DTypeSig false "oldNewFixOf" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Fix"))))))
(DFunDef false "oldNewFixOf" ((PVar "f") (PVar "sl") (PVar "sc") (PTuple (PVar "old") (PVar "new"))) (EApp (EApp (EVar "Fix") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (EApp (EVar "stringLength") (EVar "old"))))) (EVar "new")))
(DTypeSig true "parseErrCode" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "parseErrCode" ((PVar "msg")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unterminated string"))) (EVar "msg")) (ELit (LString "L-UNTERMINATED-STRING")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unterminated block"))) (EVar "msg")) (ELit (LString "L-UNTERMINATED-COMMENT")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "invalid escape"))) (EVar "msg")) (ELit (LString "L-BAD-ESCAPE")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unicode escape"))) (EVar "msg")) (ELit (LString "L-BAD-UNICODE-ESCAPE")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "bare unicode escape"))) (EVar "msg")) (ELit (LString "L-BARE-UNICODE-ESCAPE")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "character literal"))) (EVar "msg")) (ELit (LString "L-BAD-CHAR-LITERAL")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unexpected '\\'"))) (EVar "msg")) (ELit (LString "L-HS-LAMBDA")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Medaka has no '$'"))) (EVar "msg")) (ELit (LString "L-HS-DOLLAR")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unexpected character"))) (EVar "msg")) (ELit (LString "L-BAD-CHAR")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "integer literal too large"))) (EVar "msg")) (ELit (LString "L-INT-OVERFLOW")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "float literal out of range"))) (EVar "msg")) (ELit (LString "L-FLOAT-OVERFLOW")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "malformed radix literal"))) (EVar "msg")) (ELit (LString "L-MALFORMED-RADIX")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "malformed float literal"))) (EVar "msg")) (ELit (LString "L-MALFORMED-FLOAT")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unexpected end of input"))) (EVar "msg")) (ELit (LString "P-UNEXPECTED-EOF")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unexpected '/='"))) (EVar "msg")) (ELit (LString "P-BAD-NEQ")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Medaka has no 'case"))) (EVar "msg")) (ELit (LString "P-HS-CASE")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Use '::' for List cons"))) (EVar "msg")) (ELit (LString "P-HS-SIG")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Medaka has no '/* "))) (EVar "msg")) (ELit (LString "L-BLOCKCOMMENT")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unexpected '{'. Medaka has no brace"))) (EVar "msg")) (ELit (LString "P-BRACE-BLOCK")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Medaka has no 'for'"))) (EVar "msg")) (ELit (LString "P-FOR-WHILE")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Medaka has no 'while'"))) (EVar "msg")) (ELit (LString "P-FOR-WHILE")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Medaka has no 'def'"))) (EVar "msg")) (ELit (LString "P-DEF-KEYWORD")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Medaka has no statement terminator"))) (EVar "msg")) (ELit (LString "L-SEMICOLON")) (EIf (EApp (EVar "isReservedKwMsg") (EVar "msg")) (ELit (LString "P-RESERVED-KEYWORD")) (EIf (EVar "otherwise") (ELit (LString "P-PARSE")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))))))))))))))))))
(DTypeSig true "parseErrHelpFix" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Fix"))))))
(DFunDef false "parseErrHelpFix" ((PVar "msg") (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Use '::' for List cons"))) (EVar "msg")) (ETuple (EApp (EVar "Some") (ELit (LString "replace '::' with ':' for a type signature"))) (EApp (EVar "Some") (EApp (EApp (EVar "Fix") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (ELit (LInt 2))))) (ELit (LString ":"))))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unexpected '/='"))) (EVar "msg")) (ETuple (EApp (EVar "Some") (ELit (LString "replace '/=' with '!=' for not-equal"))) (EApp (EVar "Some") (EApp (EApp (EVar "Fix") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (ELit (LInt 2))))) (ELit (LString "!="))))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "integer literal too large for Int (max 4611686018427387903)"))) (EVar "msg")) (ETuple (EApp (EVar "Some") (ELit (LString "`Int` is 63-bit, spanning [-4611686018427387904, 4611686018427387903]; 4611686018427387904 fits only as the NEGATIVE -4611686018427387904, so write it with its `-`"))) (EVar "None")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "bare unicode escape"))) (EVar "msg")) (ETuple (EApp (EVar "Some") (ELit (LString "Medaka's unicode escape is braced (`\\u{XXXX}`) — there is no bare `\\uXXXX` form"))) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "oldNewFixOf") (EVar "f")) (EVar "sl")) (EVar "sc"))) (EApp (EVar "twoBacktickWords") (EVar "msg")))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "malformed radix literal"))) (EVar "msg")) (ETuple (EApp (EVar "Some") (ELit (LString "the digit separator '_' can only appear BETWEEN digits, never immediately after the base prefix ('0x'/'0b'/'0o')"))) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "oldNewFixOf") (EVar "f")) (EVar "sl")) (EVar "sc"))) (EApp (EVar "twoBacktickWords") (EVar "msg")))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "malformed float literal"))) (EVar "msg")) (ETuple (EApp (EVar "Some") (ELit (LString "Medaka requires a digit on both sides of the decimal point in a float literal"))) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "oldNewFixOf") (EVar "f")) (EVar "sl")) (EVar "sc"))) (EApp (EVar "twoBacktickWords") (EVar "msg")))) (EIf (EApp (EVar "isReservedKwMsg") (EVar "msg")) (EMatch (EApp (EVar "wordBetweenBackticks") (EVar "msg")) (arm (PCon "Some" (PVar "w")) () (ETuple (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "rename it — appending `_` (e.g. `")) (EApp (EVar "display") (EVar "w"))) (ELit (LString "_`) makes any reserved word a valid identifier")))) (EApp (EVar "Some") (EApp (EApp (EVar "Fix") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (EApp (EVar "stringLength") (EVar "w"))))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "w"))) (ELit (LString "_"))))))) (arm (PCon "None") () (ETuple (EVar "None") (EVar "None")))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "`public` only applies to `data` declarations"))) (EVar "msg")) (ETuple (EApp (EVar "Some") (ELit (LString "`public` only makes a `data` export its constructors too; a function or value is exported with plain `export` — drop `public` here"))) (EApp (EVar "Some") (EApp (EApp (EVar "Fix") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (EApp (EVar "stringLength") (ELit (LString "public")))))) (ELit (LString ""))))) (EIf (EVar "otherwise") (ETuple (EVar "None") (EVar "None")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))
(DTypeSig true "ppSeverity" (TyFun (TyCon "Severity") (TyCon "String")))
(DFunDef false "ppSeverity" ((PCon "SevError")) (ELit (LString "error")))
(DFunDef false "ppSeverity" ((PCon "SevWarning")) (ELit (LString "warning")))
(DTypeSig true "ppDiag" (TyFun (TyCon "Diag") (TyCon "String")))
(DFunDef false "ppDiag" ((PCon "Diag" (PVar "sev") PWild (PVar "msg") PWild PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig true "ppDiagCli" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String"))))
(DFunDef false "ppDiagCli" ((PVar "file") (PVar "diag")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (ELit (LString ""))) (EVar "file")) (EVar "diag")))
(DTypeSig true "ppDiagCliSrc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String")))))
(DFunDef false "ppDiagCliSrc" ((PVar "src") (PVar "file") (PCon "Diag" PWild PWild (PVar "msg") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild)) PWild PWild)) (EBlock (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "nthLine") (EVar "src")) (EVar "sl")) (arm (PCon "None") () (EVar "header")) (arm (PCon "Some" (PVar "lineText")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "header"))) (ELit (LString "\n  |\n"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString " | "))) (EApp (EVar "display") (EVar "lineText"))) (ELit (LString "\n  | "))) (EApp (EVar "display") (EApp (EVar "spaces") (EVar "sc")))) (ELit (LString "^"))))))))
(DFunDef false "ppDiagCliSrc" (PWild PWild (PCon "Diag" PWild PWild (PVar "msg") (PCon "None") PWild PWild)) (EBinOp "++" (ELit (LString "<unknown location>: ")) (EVar "msg")))
(DTypeSig false "spaces" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "spaces" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EIf (EVar "otherwise") (EBinOp "++" (ELit (LString " ")) (EApp (EVar "spaces") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "nthLine" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "nthLine" ((PVar "src") (PVar "n")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nthLineGo") (EApp (EVar "stringToChars") (EVar "src"))) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "src"))) (ELit (LInt 1))) (EVar "n")) (ELit (LString ""))))
(DTypeSig false "nthLineGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))))
(DFunDef false "nthLineGo" ((PVar "cs") (PVar "i") (PVar "len") (PVar "cur") (PVar "target") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EIf (EBinOp "==" (EVar "cur") (EVar "target")) (EApp (EVar "Some") (EVar "acc")) (EVar "None")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EIf (EBinOp "==" (EVar "cur") (EVar "target")) (EApp (EVar "Some") (EVar "acc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nthLineGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EBinOp "+" (EVar "cur") (ELit (LInt 1)))) (EVar "target")) (ELit (LString "")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nthLineGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EVar "cur")) (EVar "target")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "analyze" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "analyze" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "progSrc")) (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parse") (EVar "progSrc"))) (EListLit)))
(DTypeSig true "analyzeLocated" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "analyzeLocated" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "progSrc")) (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parseLocated") (EVar "progSrc"))) (EListLit)))
(DTypeSig true "analyzeLocatedG" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "analyzeLocatedG" ((PVar "allowInternal") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "progSrc")) (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parseLocated") (EVar "progSrc"))) (EApp (EVar "internalGuardFor") (EVar "allowInternal"))))
(DTypeSig false "analyzeFrom" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "analyzeFrom" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "raw") (PVar "internalGuard")) (EBlock (DoLet false false (PVar "desugared") (EApp (EVar "desugar") (EVar "raw"))) (DoLet false false (PVar "runtimeP") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "runtimeSrc")))) (DoLet false false (PVar "coreP") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "coreSrc")))) (DoLet false false (PVar "guardWarns") (EApp (EApp (EVar "checkGuardExhaustivenessWith") (EBinOp "++" (EBinOp "++" (EVar "raw") (EVar "runtimeP")) (EVar "coreP"))) (EVar "raw"))) (DoLet false false (PVar "deriveDiags") (EApp (EApp (EVar "map") (EVar "deriveErrToDiag")) (EApp (EVar "checkDerives") (EVar "raw")))) (DoLet false false (PVar "resErrs") (EApp (EApp (EApp (EApp (EVar "resolveProgramG2") (EVar "internalGuard")) (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared"))) (DoLet false false (PVar "resDiags") (EApp (EApp (EVar "map") (EVar "diagOfResError")) (EVar "resErrs"))) (DoLet false false PWild (EApp (EVar "setCoherenceUserDecls") (EVar "desugared"))) (DoLet false false (PVar "tcDiags") (EMatch (EVar "resErrs") (arm (PList) () (EBlock (DoLet false false (PTuple (PVar "tcErrs") (PVar "tcWarns")) (EApp (EApp (EApp (EVar "checkProgramDiags") (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "map") (EVar "diagOfTypeError")) (EVar "tcErrs")) (EApp (EApp (EVar "map") (EVar "diagOfMatchWarning")) (EVar "tcWarns")))))) (arm PWild () (EListLit)))) (DoLet false false (PVar "autoDiags") (EMatch (EVar "resErrs") (arm (PList) () (EApp (EApp (EVar "filterNewDiags") (EVar "tcDiags")) (EApp (EApp (EApp (EVar "autoPrintObligationDiags") (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared")))) (arm PWild () (EListLit)))) (DoLet false false (PVar "guardDiags") (EApp (EApp (EVar "map") (EVar "guardWarnToDiag")) (EVar "guardWarns"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "deriveDiags") (EVar "guardDiags")) (EVar "resDiags")) (EVar "tcDiags")) (EVar "autoDiags")))))
(DTypeSig false "autoPrintObligationDiags" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "autoPrintObligationDiags" ((PVar "runtimeP") (PVar "coreP") (PVar "desugared")) (EBlock (DoLet false false (PVar "modules") (EListLit (ETuple (ELit (LString "__main__")) (EVar "desugared")))) (DoExpr (EIf (EApp (EApp (EVar "shouldAutoPrintMain") (EVar "coreP")) (EVar "modules")) (EApp (EApp (EVar "map") (EVar "diagOfTypeError")) (EApp (EApp (EApp (EVar "underivedMainDiags") (EVar "runtimeP")) (EVar "coreP")) (EApp (EVar "autoPrintWrapModules") (EVar "modules")))) (EListLit)))))
(DTypeSig false "diagMsg" (TyFun (TyCon "Diag") (TyCon "String")))
(DFunDef false "diagMsg" ((PCon "Diag" PWild PWild (PVar "m") PWild PWild PWild)) (EVar "m"))
(DTypeSig false "filterNewDiags" (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "filterNewDiags" ((PVar "existing") (PVar "news")) (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "diagMsg") (EVar "e")) (EApp (EVar "diagMsg") (EVar "d"))))) (EVar "existing"))))) (EVar "news")))
(DTypeSig false "deriveErrToDiag" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Diag")))
(DFunDef false "deriveErrToDiag" ((PTuple (PVar "msg") (PVar "loc"))) (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (ELit (LString "R-CANNOT-DERIVE"))) (EVar "msg")) (EVar "loc")))
(DTypeSig false "guardWarnToDiag" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Diag")))
(DFunDef false "guardWarnToDiag" ((PTuple (PVar "msg") (PVar "loc"))) (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevWarning")) (EApp (EVar "exhaustWarnCode") (EVar "msg"))) (EApp (EVar "stripWarnPrefix") (EVar "msg"))) (EVar "loc")))
(DTypeSig false "exhaustWarnCode" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "exhaustWarnCode" ((PVar "msg")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Warning: non-exhaustive clauses"))) (EVar "msg")) (ELit (LString "W-NONEXHAUSTIVE-CLAUSES")) (EIf (EVar "otherwise") (ELit (LString "W-GUARD-INEXHAUSTIVE")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "stripWarnPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripWarnPrefix" ((PVar "s")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 9))) (EVar "s")) (ELit (LString "Warning: "))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 9))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "s")))
(DTypeSig true "analyzeToLines" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "analyzeToLines" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "progSrc")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "ppDiag")) (EApp (EApp (EApp (EVar "analyze") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "progSrc")))))
(DTypeSig false "lookupBucket" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "lookupBucket" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupBucket" ((PVar "f") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "f")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupBucket") (EVar "f")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "putBucket" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "putBucket" ((PVar "f") (PVar "v") (PList)) (EListLit (ETuple (EVar "f") (EVar "v"))))
(DFunDef false "putBucket" ((PVar "f") (PVar "v") (PCons (PTuple (PVar "k") (PVar "old")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "f")) (EBinOp "::" (ETuple (EVar "f") (EVar "v")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "old")) (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EVar "v")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pushDiag" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "pushDiag" ((PVar "f") (PVar "d") (PVar "buckets")) (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "f")) (EVar "buckets")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EListLit (EVar "d"))) (EVar "buckets"))) (arm (PCon "Some" (PVar "ds")) () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EBinOp "++" (EVar "ds") (EListLit (EVar "d")))) (EVar "buckets")))))
(DTypeSig false "seedBucket" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "seedBucket" ((PVar "f") (PVar "buckets")) (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "f")) (EVar "buckets")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EListLit)) (EVar "buckets"))) (arm (PCon "Some" PWild) () (EVar "buckets"))))
(DTypeSig false "pushDiags" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "pushDiags" (PWild (PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "pushDiags" ((PVar "f") (PCons (PVar "d") (PVar "ds")) (PVar "buckets")) (EApp (EApp (EApp (EVar "pushDiags") (EVar "f")) (EVar "ds")) (EApp (EApp (EApp (EVar "pushDiag") (EVar "f")) (EVar "d")) (EVar "buckets"))))
(DTypeSig false "cachePut" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "cachePut" ((PVar "f") (PVar "v") (PVar "xs")) (EBinOp "::" (ETuple (EVar "f") (EVar "v")) (EApp (EApp (EVar "cacheRemove") (EVar "f")) (EVar "xs"))))
(DTypeSig false "cacheRemove" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "cacheRemove" (PWild (PList)) (EListLit))
(DFunDef false "cacheRemove" ((PVar "f") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "f")) (EApp (EApp (EVar "cacheRemove") (EVar "f")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "cacheRemove") (EVar "f")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "wrappedRead" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "wrappedRead" ((PVar "cacheRef") (PVar "staleRef") (PVar "read") (PVar "path")) (EMatch (EApp (EVar "read") (EVar "path")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cacheRef")) (EApp (EApp (EApp (EVar "cachePut") (EVar "path")) (EVar "src")) (EFieldAccess (EVar "cacheRef") "value")))) (DoExpr (EApp (EVar "Some") (EVar "src"))))) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "staleRef")) (EBinOp "::" (ETuple (EVar "path") (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))) (EFieldAccess (EVar "staleRef") "value")))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "path")) (EFieldAccess (EVar "cacheRef") "value")) (arm (PCon "Some" (PVar "good")) () (EApp (EVar "Some") (EVar "good"))) (arm (PCon "None") () (EApp (EVar "Some") (EVar "src")))))))))))
(DTypeSig false "parseErrLoc" (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "Loc"))))
(DFunDef false "parseErrLoc" ((PVar "path") (PVar "e")) (EBlock (DoLet false false (PVar "ln") (EApp (EVar "parseErrorLine") (EVar "e"))) (DoLet false false (PVar "c") (EApp (EVar "parseErrorCol") (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EVar "ln")) (EVar "c")) (EVar "ln")) (EBinOp "+" (EVar "c") (ELit (LInt 1)))))))
(DTypeSig true "parseErrDiag" (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "Diag"))))
(DFunDef false "parseErrDiag" ((PVar "path") (PVar "e")) (EBlock (DoLet false false (PVar "ploc") (EApp (EApp (EVar "parseErrLoc") (EVar "path")) (EVar "e"))) (DoLet false false (PTuple (PVar "phelp") (PVar "pfix")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (EApp (EVar "parseErrorMessage") (EVar "e"))) (EApp (EVar "Some") (EVar "ploc"))) (EVar "phelp")) (EVar "pfix")))))
(DTypeSig false "preludeDesugared" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "preludeDesugared" ((PVar "parseCacheRef") (PVar "src")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EFieldAccess (EVar "parseCacheRef") "value")) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "decls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "src")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "parseCacheRef")) (EBinOp "::" (ETuple (EVar "src") (EVar "decls")) (EFieldAccess (EVar "parseCacheRef") "value")))) (DoExpr (EVar "decls"))))))
(DTypeSig true "analyzeProject" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))
(DFunDef false "analyzeProject" ((PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "staleRef") (EApp (EVar "newStale") (ELit LUnit))) (DoLet false false (PVar "wread") (ELam ((PVar "p")) (EApp (EApp (EApp (EApp (EVar "wrappedRead") (EVar "cacheRef")) (EVar "staleRef")) (EVar "read")) (EVar "p")))) (DoLet false false (PVar "runtimeP") (EApp (EApp (EVar "preludeDesugared") (EVar "parseCacheRef")) (EVar "runtimeSrc"))) (DoLet false false (PVar "coreP") (EApp (EApp (EVar "preludeDesugared") (EVar "parseCacheRef")) (EVar "coreSrc"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "loadProgramFilesLocatedCachedE") (EVar "parseCacheRef")) (EVar "wread")) (EVar "entry")) (EVar "roots")) (arm (PCon "Err" (PCon "LoadParseFailed" (PVar "mpath") PWild (PVar "pe"))) () (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EListLit (ETuple (EVar "mpath") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "mpath")) (EVar "pe"))))))) (arm (PCon "Err" (PCon "LoadMsg" (PVar "e"))) () (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EListLit (ETuple (EVar "entry") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "e")) (EVar "None"))))))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "seeded") (EApp (EApp (EVar "seedAll") (EApp (EApp (EVar "map") (EVar "midPath")) (EVar "mods"))) (EListLit))) (DoLet false false (PVar "afterRes") (EApp (EApp (EApp (EApp (EApp (EVar "resolvePass") (EVar "runtimeP")) (EVar "coreP")) (EListLit)) (EVar "mods")) (EVar "seeded"))) (DoLet false false (PVar "afterTc") (EApp (EApp (EApp (EApp (EApp (EVar "typecheckPass") (EVar "runtimeP")) (EVar "coreP")) (EListLit)) (EVar "mods")) (EVar "afterRes"))) (DoExpr (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EVar "afterTc")))))))))
(DTypeSig true "projectEntrySchemes" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))))))
(DFunDef false "projectEntrySchemes" ((PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "staleRef") (EApp (EVar "newStale") (ELit LUnit))) (DoLet false false (PVar "wread") (ELam ((PVar "p")) (EApp (EApp (EApp (EApp (EVar "wrappedRead") (EVar "cacheRef")) (EVar "staleRef")) (EVar "read")) (EVar "p")))) (DoLet false false (PVar "runtimeP") (EApp (EApp (EVar "preludeDesugared") (EVar "parseCacheRef")) (EVar "runtimeSrc"))) (DoLet false false (PVar "coreP") (EApp (EApp (EVar "preludeDesugared") (EVar "parseCacheRef")) (EVar "coreSrc"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "loadProgramFilesLocatedCached") (EVar "parseCacheRef")) (EVar "wread")) (EVar "entry")) (EVar "roots")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "mods")) () (EApp (EVar "Some") (EApp (EVar "entryOwnSchemes") (EApp (EApp (EApp (EVar "checkModules") (EVar "runtimeP")) (EVar "coreP")) (EApp (EApp (EVar "map") (EVar "midToDesugaredPair")) (EVar "mods"))))))))))
(DTypeSig false "newStale" (TyFun (TyCon "Unit") (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag"))))))
(DFunDef false "newStale" (PWild) (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "midPath" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "String")))
(DFunDef false "midPath" ((PTuple PWild (PVar "p") PWild)) (EVar "p"))
(DTypeSig false "seedAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "seedAll" ((PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "seedAll" ((PCons (PVar "f") (PVar "fs")) (PVar "buckets")) (EApp (EApp (EVar "seedAll") (EVar "fs")) (EApp (EApp (EVar "seedBucket") (EVar "f")) (EVar "buckets"))))
(DTypeSig false "appendStale" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "appendStale" ((PVar "staleRef") (PVar "buckets")) (EApp (EApp (EVar "foldStale") (EFieldAccess (EVar "staleRef") "value")) (EVar "buckets")))
(DTypeSig false "foldStale" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "foldStale" ((PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "foldStale" ((PCons (PTuple (PVar "path") (PVar "d")) (PVar "rest")) (PVar "buckets")) (EApp (EApp (EVar "foldStale") (EVar "rest")) (EApp (EApp (EApp (EVar "pushDiag") (EVar "path")) (EVar "d")) (EApp (EApp (EVar "seedBucket") (EVar "path")) (EVar "buckets")))))
(DTypeSig false "resolvePass" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "resolvePass" (PWild PWild PWild (PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "resolvePass" ((PVar "rt") (PVar "core") (PVar "known") (PCons (PTuple (PVar "mid") (PVar "path") (PVar "prog")) (PVar "rest")) (PVar "buckets")) (EBlock (DoLet false false (PVar "desugared") (EApp (EVar "desugar") (EVar "prog"))) (DoLet false false (PTuple (PVar "exp") (PVar "errs")) (EApp (EApp (EApp (EApp (EApp (EVar "resolveModule") (EVar "rt")) (EVar "core")) (EVar "known")) (EVar "mid")) (EVar "desugared"))) (DoLet false false (PVar "diags") (EApp (EApp (EVar "map") (EVar "diagOfResError")) (EVar "errs"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "resolvePass") (EVar "rt")) (EVar "core")) (EBinOp "::" (EVar "exp") (EVar "known"))) (EVar "rest")) (EApp (EApp (EApp (EVar "pushDiags") (EVar "path")) (EVar "diags")) (EVar "buckets"))))))
(DTypeSig false "typecheckPass" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "typecheckPass" ((PVar "runtimeP") (PVar "coreP") PWild (PVar "mods") (PVar "buckets")) (EBlock (DoLet false false (PVar "modPairs") (EApp (EApp (EVar "map") (EVar "midToDesugaredPair")) (EVar "mods"))) (DoLet false false (PVar "tcByMid") (EApp (EApp (EApp (EVar "checkModulesDiags") (EVar "runtimeP")) (EVar "coreP")) (EVar "modPairs"))) (DoLet false false (PVar "oracleDecls") (EBinOp "++" (EBinOp "++" (EVar "runtimeP") (EVar "coreP")) (EApp (EApp (EVar "flatMap") (EVar "rawDeclsOfMod")) (EVar "mods")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foldModuleTc") (EVar "oracleDecls")) (EVar "mods")) (EVar "tcByMid")) (EVar "buckets")))))
(DTypeSig false "rawDeclsOfMod" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "rawDeclsOfMod" ((PTuple PWild PWild (PVar "prog"))) (EVar "prog"))
(DTypeSig false "midToDesugaredPair" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "midToDesugaredPair" ((PTuple (PVar "mid") PWild (PVar "prog"))) (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "prog"))))
(DTypeSig false "diagLoc" (TyFun (TyCon "Diag") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "diagLoc" ((PCon "Diag" PWild PWild PWild (PVar "loc") PWild PWild)) (EVar "loc"))
(DTypeSig false "diagCode" (TyFun (TyCon "Diag") (TyCon "String")))
(DFunDef false "diagCode" ((PCon "Diag" PWild (PVar "code") PWild PWild PWild PWild)) (EVar "code"))
(DTypeSig false "locEq" (TyFun (TyCon "Loc") (TyFun (TyCon "Loc") (TyCon "Bool"))))
(DFunDef false "locEq" ((PCon "Loc" (PVar "f1") (PVar "sl1") (PVar "sc1") (PVar "el1") (PVar "ec1")) (PCon "Loc" (PVar "f2") (PVar "sl2") (PVar "sc2") (PVar "el2") (PVar "ec2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "f1") (EVar "f2")) (EBinOp "==" (EVar "sl1") (EVar "sl2"))) (EBinOp "==" (EVar "sc1") (EVar "sc2"))) (EBinOp "==" (EVar "el1") (EVar "el2"))) (EBinOp "==" (EVar "ec1") (EVar "ec2"))))
(DTypeSig false "isRedundantUnbound" (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyCon "Diag") (TyCon "Bool"))))
(DFunDef false "isRedundantUnbound" ((PVar "existing") (PVar "d")) (EIf (EBinOp "!=" (EApp (EVar "diagCode") (EVar "d")) (ELit (LString "T-UNBOUND"))) (EVar "False") (EIf (EVar "otherwise") (EMatch (EApp (EVar "diagLoc") (EVar "d")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "dl")) () (EApp (EApp (EVar "anyList") (ELam ((PVar "e")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "diagCode") (EVar "e")) (ELit (LString "R-UNBOUND"))) (EMatch (EApp (EVar "diagLoc") (EVar "e")) (arm (PCon "Some" (PVar "el")) () (EApp (EApp (EVar "locEq") (EVar "dl")) (EVar "el"))) (arm (PCon "None") () (EVar "False")))))) (EVar "existing")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "foldModuleTc" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))
(DFunDef false "foldModuleTc" (PWild (PList) PWild (PVar "buckets")) (EVar "buckets"))
(DFunDef false "foldModuleTc" ((PVar "oracleDecls") (PCons (PTuple (PVar "mid") (PVar "path") (PVar "prog")) (PVar "rest")) (PVar "tcByMid") (PVar "buckets")) (EBlock (DoLet false false (PTuple (PVar "tcErrs") (PVar "tcWarns")) (EApp (EApp (EVar "lookupTcDiags") (EVar "mid")) (EVar "tcByMid"))) (DoLet false false (PVar "existing") (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "path")) (EVar "buckets")) (arm (PCon "Some" (PVar "ds")) () (EVar "ds")) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "errDiags") (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EApp (EVar "isRedundantUnbound") (EVar "existing")) (EVar "d"))))) (EApp (EApp (EVar "map") (EVar "diagOfTypeError")) (EVar "tcErrs")))) (DoLet false false (PVar "warnDiags") (EApp (EApp (EVar "map") (EVar "diagOfMatchWarning")) (EVar "tcWarns"))) (DoLet false false (PVar "guardWarns") (EApp (EApp (EVar "checkGuardExhaustivenessWith") (EVar "oracleDecls")) (EVar "prog"))) (DoLet false false (PVar "guardDiags") (EApp (EApp (EVar "map") (EVar "guardWarnToDiag")) (EVar "guardWarns"))) (DoLet false false (PVar "deriveDiags") (EApp (EApp (EVar "map") (EVar "deriveErrToDiag")) (EApp (EVar "checkDerives") (EVar "prog")))) (DoLet false false (PVar "buckets2") (EApp (EApp (EApp (EVar "pushDiags") (EVar "path")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "deriveDiags") (EVar "guardDiags")) (EVar "errDiags")) (EVar "warnDiags"))) (EVar "buckets"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foldModuleTc") (EVar "oracleDecls")) (EVar "rest")) (EVar "tcByMid")) (EVar "buckets2")))))
(DTypeSig false "lookupTcDiags" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))
(DFunDef false "lookupTcDiags" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "lookupTcDiags" ((PVar "mid") (PCons (PTuple (PVar "m") (PVar "d")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "mid")) (EVar "d") (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupTcDiags") (EVar "mid")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "analyzeProjectToLines" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))))))
(DFunDef false "analyzeProjectToLines" ((PVar "cacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EListLit))) (DoExpr (EApp (EVar "joinNl") (EApp (EVar "projectLines") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "cacheRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")))))))
(DTypeSig false "projectLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "projectLines" ((PList)) (EListLit))
(DFunDef false "projectLines" ((PCons (PTuple (PVar "file") (PVar "ds")) (PVar "rest"))) (EBinOp "::" (EBinOp "++" (ELit (LString "## FILE ")) (EVar "file")) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "ppDiagLoc")) (EVar "ds")) (EApp (EVar "projectLines") (EVar "rest")))))
(DTypeSig false "ppDiagLoc" (TyFun (TyCon "Diag") (TyCon "String")))
(DFunDef false "ppDiagLoc" ((PCon "Diag" (PVar "sev") PWild (PVar "msg") (PCon "None") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))
(DFunDef false "ppDiagLoc" ((PCon "Diag" (PVar "sev") PWild (PVar "msg") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild)) PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString "@"))) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig true "cjPosition" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "cjPosition" ((PVar "line") (PVar "ch")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "ch"))) (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))))))
(DTypeSig true "cjRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "cjRange" ((PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "end")) (EApp (EApp (EVar "cjPosition") (EVar "el")) (EVar "ec"))) (ETuple (ELit (LString "start")) (EApp (EApp (EVar "cjPosition") (EVar "sl")) (EVar "sc"))))))
(DTypeSig true "cjRangeOfLoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Json"))))
(DFunDef false "cjRangeOfLoc" ((PVar "src") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EApp (EApp (EApp (EApp (EVar "cjRange") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))) (EVar "sc")) (EBinOp "-" (EVar "el") (ELit (LInt 1)))) (EVar "ec")))
(DFunDef false "cjRangeOfLoc" ((PVar "src") (PCon "None")) (EApp (EApp (EApp (EApp (EVar "cjRange") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "cjSevCode" (TyFun (TyCon "Severity") (TyCon "Int")))
(DFunDef false "cjSevCode" ((PCon "SevError")) (ELit (LInt 1)))
(DFunDef false "cjSevCode" (PWild) (ELit (LInt 2)))
(DTypeSig true "optField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Json")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "optField" ((PVar "k") (PCon "Some" (PVar "v"))) (EListLit (ETuple (EVar "k") (EVar "v"))))
(DFunDef false "optField" (PWild (PCon "None")) (EListLit))
(DTypeSig true "cjFixJson" (TyFun (TyCon "Fix") (TyCon "Json")))
(DFunDef false "cjFixJson" ((PCon "Fix" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (PVar "repl"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EApp (EApp (EVar "cjRange") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))) (EVar "sc")) (EBinOp "-" (EVar "el") (ELit (LInt 1)))) (EVar "ec"))) (ETuple (ELit (LString "replacement")) (EApp (EVar "JString") (EVar "repl"))))))
(DTypeSig true "cjDiagnostic" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "Json")))))
(DFunDef false "cjDiagnostic" (PWild (PVar "src") (PCon "Diag" (PVar "sev") (PVar "code") (PVar "msg") (PVar "loc") (PVar "help") (PVar "fix"))) (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JString") (EVar "code")))) (EApp (EApp (EVar "optField") (ELit (LString "fix"))) (EApp (EApp (EVar "map") (EVar "cjFixJson")) (EVar "fix")))) (EApp (EApp (EVar "optField") (ELit (LString "help"))) (EApp (EApp (EVar "map") (EVar "JString")) (EVar "help")))) (EListLit (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EApp (EVar "codeKind") (EVar "code")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))) (ETuple (ELit (LString "range")) (EApp (EApp (EVar "cjRangeOfLoc") (EVar "src")) (EVar "loc"))) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (EApp (EVar "cjSevCode") (EVar "sev")))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka"))))))))
(DTypeSig true "cjFileEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Json")))))
(DFunDef false "cjFileEntry" ((PVar "path") (PVar "src") (PVar "diags")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EApp (EApp (EVar "cjDiagnostic") (EVar "path")) (EVar "src"))) (EVar "diags"))))))))
(DTypeSig false "cjTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Json")))
(DFunDef false "cjTriple" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EApp (EVar "cjFileEntry") (EVar "path")) (EVar "src")) (EVar "diags")))
(DTypeSig true "cjAllToJson" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "String")))
(DFunDef false "cjAllToJson" ((PVar "triples")) (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "files")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "cjTriple")) (EVar "triples")))))))))
(DTypeSig true "readDiagSrc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "readDiagSrc" ((PTuple (PVar "path") (PVar "diags"))) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Ok" (PVar "src")) () (ETuple (EVar "path") (EVar "src") (EVar "diags"))) (arm (PCon "Err" PWild) () (ETuple (EVar "path") (ELit (LString "")) (EVar "diags")))))
(DTypeSig true "relDiagPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "relDiagPath" ((PVar "root") (PVar "path")) (EBlock (DoLet false false (PVar "pre") (EBinOp "++" (EVar "root") (ELit (LString "/")))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "pre")) (EVar "path")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "pre"))) (EApp (EVar "stringLength") (EVar "path"))) (EVar "path")) (EVar "path")))))
(DTypeSig false "relDiagTriple" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "relDiagTriple" ((PVar "root") (PTuple (PVar "path") (PVar "src") (PVar "diags"))) (ETuple (EApp (EApp (EVar "relDiagPath") (EVar "root")) (EVar "path")) (EVar "src") (EVar "diags")))
(DTypeSig true "diagIsError" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "diagIsError" ((PCon "Diag" (PCon "SevError") PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "diagIsError" (PWild) (EVar "False"))
(DTypeSig false "cjHasErrD" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "cjHasErrD" ((PTuple PWild (PVar "diags"))) (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags")))
(DTypeSig true "readFileSafe" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "readFileSafe" ((PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Ok" (PVar "src")) () (EVar "src")) (arm (PCon "Err" PWild) () (ELit (LString "")))))
(DTypeSig true "cjParseErrJson" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "cjParseErrJson" ((PVar "target") (PVar "src") (PVar "e")) (EBlock (DoLet false false (PVar "ln") (EBinOp "-" (EApp (EVar "parseErrorLine") (EVar "e")) (ELit (LInt 1)))) (DoLet false false (PVar "col") (EApp (EVar "parseErrorCol") (EVar "e"))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EApp (EVar "cjRange") (EVar "ln")) (EVar "col")) (EVar "ln")) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (DoLet false false (PVar "pcode") (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (DoLet false false (PVar "ploc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "target")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EVar "col")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "phelp") (PVar "pfix")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoLet false false (PVar "diagJson") (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JString") (EVar "pcode")))) (EApp (EApp (EVar "optField") (ELit (LString "fix"))) (EApp (EApp (EVar "map") (EVar "cjFixJson")) (EVar "pfix")))) (EApp (EApp (EVar "optField") (ELit (LString "help"))) (EApp (EApp (EVar "map") (EVar "JString")) (EVar "phelp")))) (EListLit (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EApp (EVar "codeKind") (EVar "pcode")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EApp (EVar "parseErrorMessage") (EVar "e")))) (ETuple (ELit (LString "range")) (EVar "r")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka")))))))) (DoLet false false (PVar "filesJson") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "target"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EListLit (EVar "diagJson")))))))) (DoExpr (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "files")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EListLit (EVar "filesJson")))))))))))
(DTypeSig true "checkJsonSingle" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "Bool"))))))))
(DFunDef false "checkJsonSingle" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (ETuple (EApp (EApp (EApp (EVar "cjParseErrJson") (EVar "target")) (EVar "src")) (EVar "e")) (EVar "True"))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "src"))) (DoExpr (ETuple (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "target") (EVar "src") (EVar "diags")))) (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags"))))))))
(DTypeSig true "checkJsonFile" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "Bool")))))))))
(DFunDef false "checkJsonFile" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "stdlibDir")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "target"))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (ETuple (EApp (EApp (EApp (EVar "cjParseErrJson") (EVar "target")) (EVar "src")) (EVar "e")) (EVar "True"))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "loadProgramE") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PCon "LoadParseFailed" (PVar "mpath") (PVar "msrc") (PVar "pe"))) () (ETuple (EApp (EApp (EApp (EVar "cjParseErrJson") (EVar "mpath")) (EVar "msrc")) (EVar "pe")) (EVar "True"))) (arm (PCon "Err" (PCon "LoadMsg" (PVar "lmsg"))) () (EBlock (DoLet false false (PVar "mloc") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "mid")) () (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "src")))))) (DoLet false false (PVar "mhelp") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" PWild) () (EMatch (EApp (EVar "availableModulesText") (EVar "stdlibDir")) (arm (PLit (LString "")) () (EVar "None")) (arm (PVar "txt") () (EApp (EVar "Some") (EVar "txt"))))))) (DoLet false false (PVar "jmsg") (EBinOp "++" (EVar "lmsg") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" PWild) () (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))))) (DoExpr (ETuple (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "target") (EVar "src") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "jmsg")) (EVar "mloc")) (EVar "mhelp")) (EVar "None")))))) (EVar "True"))))) (arm (PCon "Ok" (PVar "mods")) () (EMatch (EVar "mods") (arm (PList (PTuple (PVar "mid") PWild)) () (EBlock (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonSingle") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "src"))))) (arm PWild () (EBlock (DoLet false false (PVar "cacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "cacheRef")) (EVar "parseCacheRef")) (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc"))) (DoLet false false (PVar "triples") (EApp (EApp (EVar "map") (EVar "readDiagSrc")) (EVar "results"))) (DoLet false false (PVar "root") (EApp (EVar "dirOf") (EVar "stdlibDir"))) (DoExpr (ETuple (EApp (EVar "cjAllToJson") (EApp (EApp (EVar "map") (EApp (EVar "relDiagTriple") (EVar "root"))) (EVar "triples"))) (EApp (EApp (EVar "anyList") (EVar "cjHasErrD")) (EVar "results"))))))))))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false) (mem "parseResult" false) (mem "ParseError" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false) (mem "checkDerives" false))))
(DUse false (UseGroup ("frontend" "resolve") ((mem "ResError" false) (mem "resolveProgram" false) (mem "resolveProgramG2" false) (mem "internalGuardFor" false) (mem "ppResError" false) (mem "resErrorLoc" false) (mem "resErrorCode" false) (mem "resErrorDidYouMean" false) (mem "resolveModule" false) (mem "ModuleExports" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "checkGuardExhaustivenessWith" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "checkProgramDiags" false) (mem "checkModulesDiags" false) (mem "checkModules" false) (mem "entryOwnSchemes" false) (mem "Scheme" true) (mem "setCoherenceUserDecls" false) (mem "TcDiag" true) (mem "tcMsg" false))))
(DUse false (UseGroup ("driver" "loader") ((mem "LoadMsg" false) (mem "LoadParseFailed" false) (mem "loadProgramFilesLocatedCached" false) (mem "loadProgramFilesLocatedCachedE" false) (mem "loadProgramE" false) (mem "projectTrustedMods" false) (mem "entrySearchRoots" false) (mem "findImportLoc" false) (mem "unknownModuleIdOf" false) (mem "availableModulesText" false) (mem "availableModulesHint" false))))
(DUse false (UseGroup ("support" "path") ((mem "dirOf" false))))
(DUse false (UseGroup ("driver" "main_autoprint") ((mem "shouldAutoPrintMain" false) (mem "autoPrintWrapModules" false) (mem "underivedMainDiags" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "lookupAssoc" false) (mem "startsWith" false) (mem "anyList" false) (mem "filterList" false) (mem "contains" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JInt" false) (mem "JString" false) (mem "JArray" false) (mem "jObject" false) (mem "stringify" false))))
(DData Public "Severity" () ((variant "SevError" (ConPos)) (variant "SevWarning" (ConPos))) ())
(DData Public "Fix" () ((variant "Fix" (ConPos (TyCon "Loc") (TyCon "String")))) ())
(DData Public "Diag" () ((variant "Diag" (ConPos (TyCon "Severity") (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Fix"))))) ())
(DTypeSig true "mkDiag" (TyFun (TyCon "Severity") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Diag"))))))
(DFunDef false "mkDiag" ((PVar "sev") (PVar "code") (PVar "msg") (PVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "sev")) (EVar "code")) (EVar "msg")) (EVar "loc")) (EVar "None")) (EVar "None")))
(DTypeSig true "resErrorHelpFix" (TyFun (TyCon "ResError") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Fix")))))
(DFunDef false "resErrorHelpFix" ((PVar "e")) (EMatch (EApp (EVar "resErrorDidYouMean") (EVar "e")) (arm (PCon "Some" (PTuple (PVar "bad") (PVar "sug"))) () (EBlock (DoLet false false (PVar "help") (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "did you mean '")) (EApp (EMethodRef "display") (EVar "sug"))) (ELit (LString "'?"))))) (DoLet false false (PVar "fix") (EApp (EApp (EMethodRef "map") (ELam ((PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") PWild PWild)) (EApp (EApp (EVar "Fix") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (EApp (EVar "stringLength") (EVar "bad"))))) (EVar "sug")))) (EApp (EVar "resErrorLoc") (EVar "e")))) (DoExpr (ETuple (EVar "help") (EVar "fix"))))) (arm (PCon "None") () (ETuple (EVar "None") (EVar "None")))))
(DTypeSig true "diagOfResError" (TyFun (TyCon "ResError") (TyCon "Diag")))
(DFunDef false "diagOfResError" ((PVar "e")) (EBlock (DoLet false false (PTuple (PVar "help") (PVar "fix")) (EApp (EVar "resErrorHelpFix") (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "resErrorCode") (EVar "e"))) (EApp (EVar "ppResError") (EVar "e"))) (EApp (EVar "resErrorLoc") (EVar "e"))) (EVar "help")) (EVar "fix")))))
(DTypeSig true "diagOfTypeError" (TyFun (TyCon "TcDiag") (TyCon "Diag")))
(DFunDef false "diagOfTypeError" ((PCon "TcDiag" (PVar "code") PWild (PVar "loc") (PVar "msg") (PVar "help") (PVar "fix"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EVar "code")) (EVar "msg")) (EVar "loc")) (EVar "help")) (EApp (EApp (EMethodRef "map") (EVar "fixOfLocRepl")) (EVar "fix"))))
(DTypeSig false "fixOfLocRepl" (TyFun (TyTuple (TyCon "Loc") (TyCon "String")) (TyCon "Fix")))
(DFunDef false "fixOfLocRepl" ((PTuple (PVar "l") (PVar "r"))) (EApp (EApp (EVar "Fix") (EVar "l")) (EVar "r")))
(DTypeSig false "diagOfMatchWarning" (TyFun (TyCon "TcDiag") (TyCon "Diag")))
(DFunDef false "diagOfMatchWarning" ((PCon "TcDiag" PWild PWild (PVar "loc") (PVar "w") (PVar "help") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevWarning")) (EApp (EVar "matchWarnCode") (EVar "w"))) (EApp (EVar "stripWarnPrefix") (EVar "w"))) (EVar "loc")) (EVar "help")) (EVar "None")))
(DTypeSig false "matchWarnCode" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "matchWarnCode" ((PVar "w")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Warning: unreachable match arm"))) (EVar "w")) (ELit (LString "W-UNREACHABLE-ARM")) (EIf (EVar "otherwise") (ELit (LString "W-NONEXHAUSTIVE")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "codeKind" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "codeKind" ((PVar "code")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "L-"))) (EVar "code")) (ELit (LString "lex")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "P-"))) (EVar "code")) (ELit (LString "parse")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "R-"))) (EVar "code")) (ELit (LString "resolve")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "T-"))) (EVar "code")) (ELit (LString "type")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "W-"))) (EVar "code")) (ELit (LString "warning")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "rule-"))) (EVar "code")) (ELit (LString "lint")) (EIf (EVar "otherwise") (ELit (LString "error")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "isReservedKwMsg" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isReservedKwMsg" ((PVar "msg")) (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "is a reserved keyword"))) (EVar "msg")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "wordBetweenBackticks" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "wordBetweenBackticks" ((PVar "msg")) (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "`"))) (EVar "msg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "msg"))) (EVar "msg"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "j")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "j")) (EVar "rest")))) (EApp (EApp (EVar "stringIndexOf") (ELit (LString "`"))) (EVar "rest"))))))))
(DTypeSig false "allBacktickWords" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "allBacktickWords" ((PVar "msg")) (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "`"))) (EVar "msg")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "msg"))) (EVar "msg"))) (DoExpr (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "`"))) (EVar "rest")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "j")) () (EBlock (DoLet false false (PVar "word") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "j")) (EVar "rest"))) (DoLet false false (PVar "after") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "rest"))) (EVar "rest"))) (DoExpr (EBinOp "::" (EVar "word") (EApp (EVar "allBacktickWords") (EVar "after"))))))))))))
(DTypeSig false "twoBacktickWords" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "twoBacktickWords" ((PVar "msg")) (EMatch (EApp (EVar "allBacktickWords") (EVar "msg")) (arm (PCons (PVar "a") (PCons (PVar "b") PWild)) () (EApp (EVar "Some") (ETuple (EVar "a") (EVar "b")))) (arm PWild () (EVar "None"))))
(DTypeSig false "oldNewFixOf" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Fix"))))))
(DFunDef false "oldNewFixOf" ((PVar "f") (PVar "sl") (PVar "sc") (PTuple (PVar "old") (PVar "new"))) (EApp (EApp (EVar "Fix") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (EApp (EVar "stringLength") (EVar "old"))))) (EVar "new")))
(DTypeSig true "parseErrCode" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "parseErrCode" ((PVar "msg")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unterminated string"))) (EVar "msg")) (ELit (LString "L-UNTERMINATED-STRING")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unterminated block"))) (EVar "msg")) (ELit (LString "L-UNTERMINATED-COMMENT")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "invalid escape"))) (EVar "msg")) (ELit (LString "L-BAD-ESCAPE")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unicode escape"))) (EVar "msg")) (ELit (LString "L-BAD-UNICODE-ESCAPE")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "bare unicode escape"))) (EVar "msg")) (ELit (LString "L-BARE-UNICODE-ESCAPE")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "character literal"))) (EVar "msg")) (ELit (LString "L-BAD-CHAR-LITERAL")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unexpected '\\'"))) (EVar "msg")) (ELit (LString "L-HS-LAMBDA")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Medaka has no '$'"))) (EVar "msg")) (ELit (LString "L-HS-DOLLAR")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unexpected character"))) (EVar "msg")) (ELit (LString "L-BAD-CHAR")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "integer literal too large"))) (EVar "msg")) (ELit (LString "L-INT-OVERFLOW")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "float literal out of range"))) (EVar "msg")) (ELit (LString "L-FLOAT-OVERFLOW")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "malformed radix literal"))) (EVar "msg")) (ELit (LString "L-MALFORMED-RADIX")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "malformed float literal"))) (EVar "msg")) (ELit (LString "L-MALFORMED-FLOAT")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unexpected end of input"))) (EVar "msg")) (ELit (LString "P-UNEXPECTED-EOF")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unexpected '/='"))) (EVar "msg")) (ELit (LString "P-BAD-NEQ")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Medaka has no 'case"))) (EVar "msg")) (ELit (LString "P-HS-CASE")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Use '::' for List cons"))) (EVar "msg")) (ELit (LString "P-HS-SIG")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Medaka has no '/* "))) (EVar "msg")) (ELit (LString "L-BLOCKCOMMENT")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unexpected '{'. Medaka has no brace"))) (EVar "msg")) (ELit (LString "P-BRACE-BLOCK")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Medaka has no 'for'"))) (EVar "msg")) (ELit (LString "P-FOR-WHILE")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Medaka has no 'while'"))) (EVar "msg")) (ELit (LString "P-FOR-WHILE")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Medaka has no 'def'"))) (EVar "msg")) (ELit (LString "P-DEF-KEYWORD")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Medaka has no statement terminator"))) (EVar "msg")) (ELit (LString "L-SEMICOLON")) (EIf (EApp (EVar "isReservedKwMsg") (EVar "msg")) (ELit (LString "P-RESERVED-KEYWORD")) (EIf (EVar "otherwise") (ELit (LString "P-PARSE")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))))))))))))))))))
(DTypeSig true "parseErrHelpFix" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyTuple (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Fix"))))))
(DFunDef false "parseErrHelpFix" ((PVar "msg") (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Use '::' for List cons"))) (EVar "msg")) (ETuple (EApp (EVar "Some") (ELit (LString "replace '::' with ':' for a type signature"))) (EApp (EVar "Some") (EApp (EApp (EVar "Fix") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (ELit (LInt 2))))) (ELit (LString ":"))))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "unexpected '/='"))) (EVar "msg")) (ETuple (EApp (EVar "Some") (ELit (LString "replace '/=' with '!=' for not-equal"))) (EApp (EVar "Some") (EApp (EApp (EVar "Fix") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (ELit (LInt 2))))) (ELit (LString "!="))))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "integer literal too large for Int (max 4611686018427387903)"))) (EVar "msg")) (ETuple (EApp (EVar "Some") (ELit (LString "`Int` is 63-bit, spanning [-4611686018427387904, 4611686018427387903]; 4611686018427387904 fits only as the NEGATIVE -4611686018427387904, so write it with its `-`"))) (EVar "None")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "bare unicode escape"))) (EVar "msg")) (ETuple (EApp (EVar "Some") (ELit (LString "Medaka's unicode escape is braced (`\\u{XXXX}`) — there is no bare `\\uXXXX` form"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "oldNewFixOf") (EVar "f")) (EVar "sl")) (EVar "sc"))) (EApp (EVar "twoBacktickWords") (EVar "msg")))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "malformed radix literal"))) (EVar "msg")) (ETuple (EApp (EVar "Some") (ELit (LString "the digit separator '_' can only appear BETWEEN digits, never immediately after the base prefix ('0x'/'0b'/'0o')"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "oldNewFixOf") (EVar "f")) (EVar "sl")) (EVar "sc"))) (EApp (EVar "twoBacktickWords") (EVar "msg")))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "malformed float literal"))) (EVar "msg")) (ETuple (EApp (EVar "Some") (ELit (LString "Medaka requires a digit on both sides of the decimal point in a float literal"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "oldNewFixOf") (EVar "f")) (EVar "sl")) (EVar "sc"))) (EApp (EVar "twoBacktickWords") (EVar "msg")))) (EIf (EApp (EVar "isReservedKwMsg") (EVar "msg")) (EMatch (EApp (EVar "wordBetweenBackticks") (EVar "msg")) (arm (PCon "Some" (PVar "w")) () (ETuple (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "rename it — appending `_` (e.g. `")) (EApp (EMethodRef "display") (EVar "w"))) (ELit (LString "_`) makes any reserved word a valid identifier")))) (EApp (EVar "Some") (EApp (EApp (EVar "Fix") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (EApp (EVar "stringLength") (EVar "w"))))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "w"))) (ELit (LString "_"))))))) (arm (PCon "None") () (ETuple (EVar "None") (EVar "None")))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "`public` only applies to `data` declarations"))) (EVar "msg")) (ETuple (EApp (EVar "Some") (ELit (LString "`public` only makes a `data` export its constructors too; a function or value is exported with plain `export` — drop `public` here"))) (EApp (EVar "Some") (EApp (EApp (EVar "Fix") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (EApp (EVar "stringLength") (ELit (LString "public")))))) (ELit (LString ""))))) (EIf (EVar "otherwise") (ETuple (EVar "None") (EVar "None")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))
(DTypeSig true "ppSeverity" (TyFun (TyCon "Severity") (TyCon "String")))
(DFunDef false "ppSeverity" ((PCon "SevError")) (ELit (LString "error")))
(DFunDef false "ppSeverity" ((PCon "SevWarning")) (ELit (LString "warning")))
(DTypeSig true "ppDiag" (TyFun (TyCon "Diag") (TyCon "String")))
(DFunDef false "ppDiag" ((PCon "Diag" (PVar "sev") PWild (PVar "msg") PWild PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig true "ppDiagCli" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String"))))
(DFunDef false "ppDiagCli" ((PVar "file") (PVar "diag")) (EApp (EApp (EApp (EVar "ppDiagCliSrc") (ELit (LString ""))) (EVar "file")) (EVar "diag")))
(DTypeSig true "ppDiagCliSrc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "String")))))
(DFunDef false "ppDiagCliSrc" ((PVar "src") (PVar "file") (PCon "Diag" PWild PWild (PVar "msg") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild)) PWild PWild)) (EBlock (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "nthLine") (EVar "src")) (EVar "sl")) (arm (PCon "None") () (EVar "header")) (arm (PCon "Some" (PVar "lineText")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "header"))) (ELit (LString "\n  |\n"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EVar "lineText"))) (ELit (LString "\n  | "))) (EApp (EMethodRef "display") (EApp (EVar "spaces") (EVar "sc")))) (ELit (LString "^"))))))))
(DFunDef false "ppDiagCliSrc" (PWild PWild (PCon "Diag" PWild PWild (PVar "msg") (PCon "None") PWild PWild)) (EBinOp "++" (ELit (LString "<unknown location>: ")) (EVar "msg")))
(DTypeSig false "spaces" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "spaces" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EIf (EVar "otherwise") (EBinOp "++" (ELit (LString " ")) (EApp (EVar "spaces") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "nthLine" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "nthLine" ((PVar "src") (PVar "n")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nthLineGo") (EApp (EVar "stringToChars") (EVar "src"))) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "src"))) (ELit (LInt 1))) (EVar "n")) (ELit (LString ""))))
(DTypeSig false "nthLineGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))))
(DFunDef false "nthLineGo" ((PVar "cs") (PVar "i") (PVar "len") (PVar "cur") (PVar "target") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EIf (EBinOp "==" (EVar "cur") (EVar "target")) (EApp (EVar "Some") (EVar "acc")) (EVar "None")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EIf (EBinOp "==" (EVar "cur") (EVar "target")) (EApp (EVar "Some") (EVar "acc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nthLineGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EBinOp "+" (EVar "cur") (ELit (LInt 1)))) (EVar "target")) (ELit (LString "")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "nthLineGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EVar "cur")) (EVar "target")) (EBinOp "++" (EVar "acc") (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "analyze" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "analyze" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "progSrc")) (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parse") (EVar "progSrc"))) (EListLit)))
(DTypeSig true "analyzeLocated" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "analyzeLocated" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "progSrc")) (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parseLocated") (EVar "progSrc"))) (EListLit)))
(DTypeSig true "analyzeLocatedG" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "analyzeLocatedG" ((PVar "allowInternal") (PVar "runtimeSrc") (PVar "coreSrc") (PVar "progSrc")) (EApp (EApp (EApp (EApp (EVar "analyzeFrom") (EVar "runtimeSrc")) (EVar "coreSrc")) (EApp (EVar "parseLocated") (EVar "progSrc"))) (EApp (EVar "internalGuardFor") (EVar "allowInternal"))))
(DTypeSig false "analyzeFrom" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "analyzeFrom" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "raw") (PVar "internalGuard")) (EBlock (DoLet false false (PVar "desugared") (EApp (EVar "desugar") (EVar "raw"))) (DoLet false false (PVar "runtimeP") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "runtimeSrc")))) (DoLet false false (PVar "coreP") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "coreSrc")))) (DoLet false false (PVar "guardWarns") (EApp (EApp (EVar "checkGuardExhaustivenessWith") (EBinOp "++" (EBinOp "++" (EVar "raw") (EVar "runtimeP")) (EVar "coreP"))) (EVar "raw"))) (DoLet false false (PVar "deriveDiags") (EApp (EApp (EMethodRef "map") (EVar "deriveErrToDiag")) (EApp (EVar "checkDerives") (EVar "raw")))) (DoLet false false (PVar "resErrs") (EApp (EApp (EApp (EApp (EVar "resolveProgramG2") (EVar "internalGuard")) (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared"))) (DoLet false false (PVar "resDiags") (EApp (EApp (EMethodRef "map") (EVar "diagOfResError")) (EVar "resErrs"))) (DoLet false false PWild (EApp (EVar "setCoherenceUserDecls") (EVar "desugared"))) (DoLet false false (PVar "tcDiags") (EMatch (EVar "resErrs") (arm (PList) () (EBlock (DoLet false false (PTuple (PVar "tcErrs") (PVar "tcWarns")) (EApp (EApp (EApp (EVar "checkProgramDiags") (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared"))) (DoExpr (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "diagOfTypeError")) (EVar "tcErrs")) (EApp (EApp (EMethodRef "map") (EVar "diagOfMatchWarning")) (EVar "tcWarns")))))) (arm PWild () (EListLit)))) (DoLet false false (PVar "autoDiags") (EMatch (EVar "resErrs") (arm (PList) () (EApp (EApp (EVar "filterNewDiags") (EVar "tcDiags")) (EApp (EApp (EApp (EVar "autoPrintObligationDiags") (EVar "runtimeP")) (EVar "coreP")) (EVar "desugared")))) (arm PWild () (EListLit)))) (DoLet false false (PVar "guardDiags") (EApp (EApp (EMethodRef "map") (EVar "guardWarnToDiag")) (EVar "guardWarns"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "deriveDiags") (EVar "guardDiags")) (EVar "resDiags")) (EVar "tcDiags")) (EVar "autoDiags")))))
(DTypeSig false "autoPrintObligationDiags" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "autoPrintObligationDiags" ((PVar "runtimeP") (PVar "coreP") (PVar "desugared")) (EBlock (DoLet false false (PVar "modules") (EListLit (ETuple (ELit (LString "__main__")) (EVar "desugared")))) (DoExpr (EIf (EApp (EApp (EVar "shouldAutoPrintMain") (EVar "coreP")) (EVar "modules")) (EApp (EApp (EMethodRef "map") (EVar "diagOfTypeError")) (EApp (EApp (EApp (EVar "underivedMainDiags") (EVar "runtimeP")) (EVar "coreP")) (EApp (EVar "autoPrintWrapModules") (EVar "modules")))) (EListLit)))))
(DTypeSig false "diagMsg" (TyFun (TyCon "Diag") (TyCon "String")))
(DFunDef false "diagMsg" ((PCon "Diag" PWild PWild (PVar "m") PWild PWild PWild)) (EVar "m"))
(DTypeSig false "filterNewDiags" (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyApp (TyCon "List") (TyCon "Diag")))))
(DFunDef false "filterNewDiags" ((PVar "existing") (PVar "news")) (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "diagMsg") (EVar "e")) (EApp (EVar "diagMsg") (EVar "d"))))) (EVar "existing"))))) (EVar "news")))
(DTypeSig false "deriveErrToDiag" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Diag")))
(DFunDef false "deriveErrToDiag" ((PTuple (PVar "msg") (PVar "loc"))) (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (ELit (LString "R-CANNOT-DERIVE"))) (EVar "msg")) (EVar "loc")))
(DTypeSig false "guardWarnToDiag" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Diag")))
(DFunDef false "guardWarnToDiag" ((PTuple (PVar "msg") (PVar "loc"))) (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevWarning")) (EApp (EVar "exhaustWarnCode") (EVar "msg"))) (EApp (EVar "stripWarnPrefix") (EVar "msg"))) (EVar "loc")))
(DTypeSig false "exhaustWarnCode" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "exhaustWarnCode" ((PVar "msg")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "Warning: non-exhaustive clauses"))) (EVar "msg")) (ELit (LString "W-NONEXHAUSTIVE-CLAUSES")) (EIf (EVar "otherwise") (ELit (LString "W-GUARD-INEXHAUSTIVE")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "stripWarnPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stripWarnPrefix" ((PVar "s")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 9))) (EVar "s")) (ELit (LString "Warning: "))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 9))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "s")))
(DTypeSig true "analyzeToLines" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "analyzeToLines" ((PVar "runtimeSrc") (PVar "coreSrc") (PVar "progSrc")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "ppDiag")) (EApp (EApp (EApp (EVar "analyze") (EVar "runtimeSrc")) (EVar "coreSrc")) (EVar "progSrc")))))
(DTypeSig false "lookupBucket" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "lookupBucket" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupBucket" ((PVar "f") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "f")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupBucket") (EVar "f")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "putBucket" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "putBucket" ((PVar "f") (PVar "v") (PList)) (EListLit (ETuple (EVar "f") (EVar "v"))))
(DFunDef false "putBucket" ((PVar "f") (PVar "v") (PCons (PTuple (PVar "k") (PVar "old")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "f")) (EBinOp "::" (ETuple (EVar "f") (EVar "v")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "old")) (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EVar "v")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "pushDiag" (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "pushDiag" ((PVar "f") (PVar "d") (PVar "buckets")) (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "f")) (EVar "buckets")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EListLit (EVar "d"))) (EVar "buckets"))) (arm (PCon "Some" (PVar "ds")) () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EBinOp "++" (EVar "ds") (EListLit (EVar "d")))) (EVar "buckets")))))
(DTypeSig false "seedBucket" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "seedBucket" ((PVar "f") (PVar "buckets")) (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "f")) (EVar "buckets")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "putBucket") (EVar "f")) (EListLit)) (EVar "buckets"))) (arm (PCon "Some" PWild) () (EVar "buckets"))))
(DTypeSig false "pushDiags" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))
(DFunDef false "pushDiags" (PWild (PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "pushDiags" ((PVar "f") (PCons (PVar "d") (PVar "ds")) (PVar "buckets")) (EApp (EApp (EApp (EVar "pushDiags") (EVar "f")) (EVar "ds")) (EApp (EApp (EApp (EVar "pushDiag") (EVar "f")) (EVar "d")) (EVar "buckets"))))
(DTypeSig false "cachePut" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "cachePut" ((PVar "f") (PVar "v") (PVar "xs")) (EBinOp "::" (ETuple (EVar "f") (EVar "v")) (EApp (EApp (EVar "cacheRemove") (EVar "f")) (EVar "xs"))))
(DTypeSig false "cacheRemove" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "cacheRemove" (PWild (PList)) (EListLit))
(DFunDef false "cacheRemove" ((PVar "f") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "f")) (EApp (EApp (EVar "cacheRemove") (EVar "f")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EApp (EVar "cacheRemove") (EVar "f")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "wrappedRead" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "wrappedRead" ((PVar "cacheRef") (PVar "staleRef") (PVar "read") (PVar "path")) (EMatch (EApp (EVar "read") (EVar "path")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "src")) () (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "cacheRef")) (EApp (EApp (EApp (EVar "cachePut") (EVar "path")) (EVar "src")) (EFieldAccess (EVar "cacheRef") "value")))) (DoExpr (EApp (EVar "Some") (EVar "src"))))) (arm (PCon "Err" (PVar "e")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "staleRef")) (EBinOp "::" (ETuple (EVar "path") (EApp (EApp (EVar "parseErrDiag") (EVar "path")) (EVar "e"))) (EFieldAccess (EVar "staleRef") "value")))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "path")) (EFieldAccess (EVar "cacheRef") "value")) (arm (PCon "Some" (PVar "good")) () (EApp (EVar "Some") (EVar "good"))) (arm (PCon "None") () (EApp (EVar "Some") (EVar "src")))))))))))
(DTypeSig false "parseErrLoc" (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "Loc"))))
(DFunDef false "parseErrLoc" ((PVar "path") (PVar "e")) (EBlock (DoLet false false (PVar "ln") (EApp (EVar "parseErrorLine") (EVar "e"))) (DoLet false false (PVar "c") (EApp (EVar "parseErrorCol") (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EVar "ln")) (EVar "c")) (EVar "ln")) (EBinOp "+" (EVar "c") (ELit (LInt 1)))))))
(DTypeSig true "parseErrDiag" (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "Diag"))))
(DFunDef false "parseErrDiag" ((PVar "path") (PVar "e")) (EBlock (DoLet false false (PVar "ploc") (EApp (EApp (EVar "parseErrLoc") (EVar "path")) (EVar "e"))) (DoLet false false (PTuple (PVar "phelp") (PVar "pfix")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (EApp (EVar "parseErrorMessage") (EVar "e"))) (EApp (EVar "Some") (EVar "ploc"))) (EVar "phelp")) (EVar "pfix")))))
(DTypeSig false "preludeDesugared" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "preludeDesugared" ((PVar "parseCacheRef") (PVar "src")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "src")) (EFieldAccess (EVar "parseCacheRef") "value")) (arm (PCon "Some" (PVar "decls")) () (EVar "decls")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "decls") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "src")))) (DoLet false false PWild (EApp (EApp (EVar "setRef") (EVar "parseCacheRef")) (EBinOp "::" (ETuple (EVar "src") (EVar "decls")) (EFieldAccess (EVar "parseCacheRef") "value")))) (DoExpr (EVar "decls"))))))
(DTypeSig true "analyzeProject" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))))))
(DFunDef false "analyzeProject" ((PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "staleRef") (EApp (EVar "newStale") (ELit LUnit))) (DoLet false false (PVar "wread") (ELam ((PVar "p")) (EApp (EApp (EApp (EApp (EVar "wrappedRead") (EVar "cacheRef")) (EVar "staleRef")) (EVar "read")) (EVar "p")))) (DoLet false false (PVar "runtimeP") (EApp (EApp (EVar "preludeDesugared") (EVar "parseCacheRef")) (EVar "runtimeSrc"))) (DoLet false false (PVar "coreP") (EApp (EApp (EVar "preludeDesugared") (EVar "parseCacheRef")) (EVar "coreSrc"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "loadProgramFilesLocatedCachedE") (EVar "parseCacheRef")) (EVar "wread")) (EVar "entry")) (EVar "roots")) (arm (PCon "Err" (PCon "LoadParseFailed" (PVar "mpath") PWild (PVar "pe"))) () (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EListLit (ETuple (EVar "mpath") (EListLit (EApp (EApp (EVar "parseErrDiag") (EVar "mpath")) (EVar "pe"))))))) (arm (PCon "Err" (PCon "LoadMsg" (PVar "e"))) () (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EListLit (ETuple (EVar "entry") (EListLit (EApp (EApp (EApp (EApp (EVar "mkDiag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "e")) (EVar "None"))))))) (arm (PCon "Ok" (PVar "mods")) () (EBlock (DoLet false false (PVar "seeded") (EApp (EApp (EVar "seedAll") (EApp (EApp (EMethodRef "map") (EVar "midPath")) (EVar "mods"))) (EListLit))) (DoLet false false (PVar "afterRes") (EApp (EApp (EApp (EApp (EApp (EVar "resolvePass") (EVar "runtimeP")) (EVar "coreP")) (EListLit)) (EVar "mods")) (EVar "seeded"))) (DoLet false false (PVar "afterTc") (EApp (EApp (EApp (EApp (EApp (EVar "typecheckPass") (EVar "runtimeP")) (EVar "coreP")) (EListLit)) (EVar "mods")) (EVar "afterRes"))) (DoExpr (EApp (EApp (EVar "appendStale") (EVar "staleRef")) (EVar "afterTc")))))))))
(DTypeSig true "projectEntrySchemes" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))))))))))
(DFunDef false "projectEntrySchemes" ((PVar "cacheRef") (PVar "parseCacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "staleRef") (EApp (EVar "newStale") (ELit LUnit))) (DoLet false false (PVar "wread") (ELam ((PVar "p")) (EApp (EApp (EApp (EApp (EVar "wrappedRead") (EVar "cacheRef")) (EVar "staleRef")) (EVar "read")) (EVar "p")))) (DoLet false false (PVar "runtimeP") (EApp (EApp (EVar "preludeDesugared") (EVar "parseCacheRef")) (EVar "runtimeSrc"))) (DoLet false false (PVar "coreP") (EApp (EApp (EVar "preludeDesugared") (EVar "parseCacheRef")) (EVar "coreSrc"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "loadProgramFilesLocatedCached") (EVar "parseCacheRef")) (EVar "wread")) (EVar "entry")) (EVar "roots")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "mods")) () (EApp (EVar "Some") (EApp (EVar "entryOwnSchemes") (EApp (EApp (EApp (EVar "checkModules") (EVar "runtimeP")) (EVar "coreP")) (EApp (EApp (EMethodRef "map") (EVar "midToDesugaredPair")) (EVar "mods"))))))))))
(DTypeSig false "newStale" (TyFun (TyCon "Unit") (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag"))))))
(DFunDef false "newStale" (PWild) (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "midPath" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyCon "String")))
(DFunDef false "midPath" ((PTuple PWild (PVar "p") PWild)) (EVar "p"))
(DTypeSig false "seedAll" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "seedAll" ((PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "seedAll" ((PCons (PVar "f") (PVar "fs")) (PVar "buckets")) (EApp (EApp (EVar "seedAll") (EVar "fs")) (EApp (EApp (EVar "seedBucket") (EVar "f")) (EVar "buckets"))))
(DTypeSig false "appendStale" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "appendStale" ((PVar "staleRef") (PVar "buckets")) (EApp (EApp (EVar "foldStale") (EFieldAccess (EVar "staleRef") "value")) (EVar "buckets")))
(DTypeSig false "foldStale" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Diag"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))
(DFunDef false "foldStale" ((PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "foldStale" ((PCons (PTuple (PVar "path") (PVar "d")) (PVar "rest")) (PVar "buckets")) (EApp (EApp (EVar "foldStale") (EVar "rest")) (EApp (EApp (EApp (EVar "pushDiag") (EVar "path")) (EVar "d")) (EApp (EApp (EVar "seedBucket") (EVar "path")) (EVar "buckets")))))
(DTypeSig false "resolvePass" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "resolvePass" (PWild PWild PWild (PList) (PVar "buckets")) (EVar "buckets"))
(DFunDef false "resolvePass" ((PVar "rt") (PVar "core") (PVar "known") (PCons (PTuple (PVar "mid") (PVar "path") (PVar "prog")) (PVar "rest")) (PVar "buckets")) (EBlock (DoLet false false (PVar "desugared") (EApp (EVar "desugar") (EVar "prog"))) (DoLet false false (PTuple (PVar "exp") (PVar "errs")) (EApp (EApp (EApp (EApp (EApp (EVar "resolveModule") (EVar "rt")) (EVar "core")) (EVar "known")) (EVar "mid")) (EVar "desugared"))) (DoLet false false (PVar "diags") (EApp (EApp (EMethodRef "map") (EVar "diagOfResError")) (EVar "errs"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "resolvePass") (EVar "rt")) (EVar "core")) (EBinOp "::" (EVar "exp") (EVar "known"))) (EVar "rest")) (EApp (EApp (EApp (EVar "pushDiags") (EVar "path")) (EVar "diags")) (EVar "buckets"))))))
(DTypeSig false "typecheckPass" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))))))
(DFunDef false "typecheckPass" ((PVar "runtimeP") (PVar "coreP") PWild (PVar "mods") (PVar "buckets")) (EBlock (DoLet false false (PVar "modPairs") (EApp (EApp (EMethodRef "map") (EVar "midToDesugaredPair")) (EVar "mods"))) (DoLet false false (PVar "tcByMid") (EApp (EApp (EApp (EVar "checkModulesDiags") (EVar "runtimeP")) (EVar "coreP")) (EVar "modPairs"))) (DoLet false false (PVar "oracleDecls") (EBinOp "++" (EBinOp "++" (EVar "runtimeP") (EVar "coreP")) (EApp (EApp (EDictApp "flatMap") (EVar "rawDeclsOfMod")) (EVar "mods")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foldModuleTc") (EVar "oracleDecls")) (EVar "mods")) (EVar "tcByMid")) (EVar "buckets")))))
(DTypeSig false "rawDeclsOfMod" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "rawDeclsOfMod" ((PTuple PWild PWild (PVar "prog"))) (EVar "prog"))
(DTypeSig false "midToDesugaredPair" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "midToDesugaredPair" ((PTuple (PVar "mid") PWild (PVar "prog"))) (ETuple (EVar "mid") (EApp (EVar "desugar") (EVar "prog"))))
(DTypeSig false "diagLoc" (TyFun (TyCon "Diag") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "diagLoc" ((PCon "Diag" PWild PWild PWild (PVar "loc") PWild PWild)) (EVar "loc"))
(DTypeSig false "diagCode" (TyFun (TyCon "Diag") (TyCon "String")))
(DFunDef false "diagCode" ((PCon "Diag" PWild (PVar "code") PWild PWild PWild PWild)) (EVar "code"))
(DTypeSig false "locEq" (TyFun (TyCon "Loc") (TyFun (TyCon "Loc") (TyCon "Bool"))))
(DFunDef false "locEq" ((PCon "Loc" (PVar "f1") (PVar "sl1") (PVar "sc1") (PVar "el1") (PVar "ec1")) (PCon "Loc" (PVar "f2") (PVar "sl2") (PVar "sc2") (PVar "el2") (PVar "ec2"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "f1") (EVar "f2")) (EBinOp "==" (EVar "sl1") (EVar "sl2"))) (EBinOp "==" (EVar "sc1") (EVar "sc2"))) (EBinOp "==" (EVar "el1") (EVar "el2"))) (EBinOp "==" (EVar "ec1") (EVar "ec2"))))
(DTypeSig false "isRedundantUnbound" (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyFun (TyCon "Diag") (TyCon "Bool"))))
(DFunDef false "isRedundantUnbound" ((PVar "existing") (PVar "d")) (EIf (EBinOp "!=" (EApp (EVar "diagCode") (EVar "d")) (ELit (LString "T-UNBOUND"))) (EVar "False") (EIf (EVar "otherwise") (EMatch (EApp (EVar "diagLoc") (EVar "d")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "dl")) () (EApp (EApp (EVar "anyList") (ELam ((PVar "e")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "diagCode") (EVar "e")) (ELit (LString "R-UNBOUND"))) (EMatch (EApp (EVar "diagLoc") (EVar "e")) (arm (PCon "Some" (PVar "el")) () (EApp (EApp (EVar "locEq") (EVar "dl")) (EVar "el"))) (arm (PCon "None") () (EVar "False")))))) (EVar "existing")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "foldModuleTc" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))))))))
(DFunDef false "foldModuleTc" (PWild (PList) PWild (PVar "buckets")) (EVar "buckets"))
(DFunDef false "foldModuleTc" ((PVar "oracleDecls") (PCons (PTuple (PVar "mid") (PVar "path") (PVar "prog")) (PVar "rest")) (PVar "tcByMid") (PVar "buckets")) (EBlock (DoLet false false (PTuple (PVar "tcErrs") (PVar "tcWarns")) (EApp (EApp (EVar "lookupTcDiags") (EVar "mid")) (EVar "tcByMid"))) (DoLet false false (PVar "existing") (EMatch (EApp (EApp (EVar "lookupBucket") (EVar "path")) (EVar "buckets")) (arm (PCon "Some" (PVar "ds")) () (EVar "ds")) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "errDiags") (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EApp (EVar "isRedundantUnbound") (EVar "existing")) (EVar "d"))))) (EApp (EApp (EMethodRef "map") (EVar "diagOfTypeError")) (EVar "tcErrs")))) (DoLet false false (PVar "warnDiags") (EApp (EApp (EMethodRef "map") (EVar "diagOfMatchWarning")) (EVar "tcWarns"))) (DoLet false false (PVar "guardWarns") (EApp (EApp (EVar "checkGuardExhaustivenessWith") (EVar "oracleDecls")) (EVar "prog"))) (DoLet false false (PVar "guardDiags") (EApp (EApp (EMethodRef "map") (EVar "guardWarnToDiag")) (EVar "guardWarns"))) (DoLet false false (PVar "deriveDiags") (EApp (EApp (EMethodRef "map") (EVar "deriveErrToDiag")) (EApp (EVar "checkDerives") (EVar "prog")))) (DoLet false false (PVar "buckets2") (EApp (EApp (EApp (EVar "pushDiags") (EVar "path")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "deriveDiags") (EVar "guardDiags")) (EVar "errDiags")) (EVar "warnDiags"))) (EVar "buckets"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foldModuleTc") (EVar "oracleDecls")) (EVar "rest")) (EVar "tcByMid")) (EVar "buckets2")))))
(DTypeSig false "lookupTcDiags" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))) (TyTuple (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))
(DFunDef false "lookupTcDiags" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "lookupTcDiags" ((PVar "mid") (PCons (PTuple (PVar "m") (PVar "d")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "mid")) (EVar "d") (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupTcDiags") (EVar "mid")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "analyzeProjectToLines" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String")))))))))
(DFunDef false "analyzeProjectToLines" ((PVar "cacheRef") (PVar "read") (PVar "entry") (PVar "roots") (PVar "runtimeSrc") (PVar "coreSrc")) (EBlock (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EListLit))) (DoExpr (EApp (EVar "joinNl") (EApp (EVar "projectLines") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "cacheRef")) (EVar "parseCacheRef")) (EVar "read")) (EVar "entry")) (EVar "roots")) (EVar "runtimeSrc")) (EVar "coreSrc")))))))
(DTypeSig false "projectLines" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "projectLines" ((PList)) (EListLit))
(DFunDef false "projectLines" ((PCons (PTuple (PVar "file") (PVar "ds")) (PVar "rest"))) (EBinOp "::" (EBinOp "++" (ELit (LString "## FILE ")) (EVar "file")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "ppDiagLoc")) (EVar "ds")) (EApp (EVar "projectLines") (EVar "rest")))))
(DTypeSig false "ppDiagLoc" (TyFun (TyCon "Diag") (TyCon "String")))
(DFunDef false "ppDiagLoc" ((PCon "Diag" (PVar "sev") PWild (PVar "msg") (PCon "None") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))
(DFunDef false "ppDiagLoc" ((PCon "Diag" (PVar "sev") PWild (PVar "msg") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") PWild PWild)) PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppSeverity") (EVar "sev")))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig true "cjPosition" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "cjPosition" ((PVar "line") (PVar "ch")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "ch"))) (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))))))
(DTypeSig true "cjRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "cjRange" ((PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "end")) (EApp (EApp (EVar "cjPosition") (EVar "el")) (EVar "ec"))) (ETuple (ELit (LString "start")) (EApp (EApp (EVar "cjPosition") (EVar "sl")) (EVar "sc"))))))
(DTypeSig true "cjRangeOfLoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Json"))))
(DFunDef false "cjRangeOfLoc" ((PVar "src") (PCon "Some" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EApp (EApp (EApp (EApp (EVar "cjRange") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))) (EVar "sc")) (EBinOp "-" (EVar "el") (ELit (LInt 1)))) (EVar "ec")))
(DFunDef false "cjRangeOfLoc" ((PVar "src") (PCon "None")) (EApp (EApp (EApp (EApp (EVar "cjRange") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "cjSevCode" (TyFun (TyCon "Severity") (TyCon "Int")))
(DFunDef false "cjSevCode" ((PCon "SevError")) (ELit (LInt 1)))
(DFunDef false "cjSevCode" (PWild) (ELit (LInt 2)))
(DTypeSig true "optField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Json")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Json"))))))
(DFunDef false "optField" ((PVar "k") (PCon "Some" (PVar "v"))) (EListLit (ETuple (EVar "k") (EVar "v"))))
(DFunDef false "optField" (PWild (PCon "None")) (EListLit))
(DTypeSig true "cjFixJson" (TyFun (TyCon "Fix") (TyCon "Json")))
(DFunDef false "cjFixJson" ((PCon "Fix" (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (PVar "repl"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "range")) (EApp (EApp (EApp (EApp (EVar "cjRange") (EBinOp "-" (EVar "sl") (ELit (LInt 1)))) (EVar "sc")) (EBinOp "-" (EVar "el") (ELit (LInt 1)))) (EVar "ec"))) (ETuple (ELit (LString "replacement")) (EApp (EVar "JString") (EVar "repl"))))))
(DTypeSig true "cjDiagnostic" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Diag") (TyCon "Json")))))
(DFunDef false "cjDiagnostic" (PWild (PVar "src") (PCon "Diag" (PVar "sev") (PVar "code") (PVar "msg") (PVar "loc") (PVar "help") (PVar "fix"))) (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JString") (EVar "code")))) (EApp (EApp (EVar "optField") (ELit (LString "fix"))) (EApp (EApp (EMethodRef "map") (EVar "cjFixJson")) (EVar "fix")))) (EApp (EApp (EVar "optField") (ELit (LString "help"))) (EApp (EApp (EMethodRef "map") (EVar "JString")) (EVar "help")))) (EListLit (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EApp (EVar "codeKind") (EVar "code")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EVar "msg"))) (ETuple (ELit (LString "range")) (EApp (EApp (EVar "cjRangeOfLoc") (EVar "src")) (EVar "loc"))) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (EApp (EVar "cjSevCode") (EVar "sev")))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka"))))))))
(DTypeSig true "cjFileEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Diag")) (TyCon "Json")))))
(DFunDef false "cjFileEntry" ((PVar "path") (PVar "src") (PVar "diags")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "path"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "cjDiagnostic") (EVar "path")) (EVar "src"))) (EVar "diags"))))))))
(DTypeSig false "cjTriple" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Json")))
(DFunDef false "cjTriple" ((PTuple (PVar "path") (PVar "src") (PVar "diags"))) (EApp (EApp (EApp (EVar "cjFileEntry") (EVar "path")) (EVar "src")) (EVar "diags")))
(DTypeSig true "cjAllToJson" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag")))) (TyCon "String")))
(DFunDef false "cjAllToJson" ((PVar "triples")) (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "files")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "cjTriple")) (EVar "triples")))))))))
(DTypeSig true "readDiagSrc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "readDiagSrc" ((PTuple (PVar "path") (PVar "diags"))) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Ok" (PVar "src")) () (ETuple (EVar "path") (EVar "src") (EVar "diags"))) (arm (PCon "Err" PWild) () (ETuple (EVar "path") (ELit (LString "")) (EVar "diags")))))
(DTypeSig true "relDiagPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "relDiagPath" ((PVar "root") (PVar "path")) (EBlock (DoLet false false (PVar "pre") (EBinOp "++" (EVar "root") (ELit (LString "/")))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "pre")) (EVar "path")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "pre"))) (EApp (EVar "stringLength") (EVar "path"))) (EVar "path")) (EVar "path")))))
(DTypeSig false "relDiagTriple" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))))))
(DFunDef false "relDiagTriple" ((PVar "root") (PTuple (PVar "path") (PVar "src") (PVar "diags"))) (ETuple (EApp (EApp (EVar "relDiagPath") (EVar "root")) (EVar "path")) (EVar "src") (EVar "diags")))
(DTypeSig true "diagIsError" (TyFun (TyCon "Diag") (TyCon "Bool")))
(DFunDef false "diagIsError" ((PCon "Diag" (PCon "SevError") PWild PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "diagIsError" (PWild) (EVar "False"))
(DTypeSig false "cjHasErrD" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Diag"))) (TyCon "Bool")))
(DFunDef false "cjHasErrD" ((PTuple PWild (PVar "diags"))) (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags")))
(DTypeSig true "readFileSafe" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "readFileSafe" ((PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Ok" (PVar "src")) () (EVar "src")) (arm (PCon "Err" PWild) () (ELit (LString "")))))
(DTypeSig true "cjParseErrJson" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ParseError") (TyCon "String")))))
(DFunDef false "cjParseErrJson" ((PVar "target") (PVar "src") (PVar "e")) (EBlock (DoLet false false (PVar "ln") (EBinOp "-" (EApp (EVar "parseErrorLine") (EVar "e")) (ELit (LInt 1)))) (DoLet false false (PVar "col") (EApp (EVar "parseErrorCol") (EVar "e"))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EApp (EVar "cjRange") (EVar "ln")) (EVar "col")) (EVar "ln")) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (DoLet false false (PVar "pcode") (EApp (EVar "parseErrCode") (EApp (EVar "parseErrorMessage") (EVar "e")))) (DoLet false false (PVar "ploc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "target")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EVar "col")) (EApp (EVar "parseErrorLine") (EVar "e"))) (EBinOp "+" (EVar "col") (ELit (LInt 1))))) (DoLet false false (PTuple (PVar "phelp") (PVar "pfix")) (EApp (EApp (EVar "parseErrHelpFix") (EApp (EVar "parseErrorMessage") (EVar "e"))) (EVar "ploc"))) (DoLet false false (PVar "diagJson") (EApp (EVar "jObject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ETuple (ELit (LString "code")) (EApp (EVar "JString") (EVar "pcode")))) (EApp (EApp (EVar "optField") (ELit (LString "fix"))) (EApp (EApp (EMethodRef "map") (EVar "cjFixJson")) (EVar "pfix")))) (EApp (EApp (EVar "optField") (ELit (LString "help"))) (EApp (EApp (EMethodRef "map") (EVar "JString")) (EVar "phelp")))) (EListLit (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EApp (EVar "codeKind") (EVar "pcode")))) (ETuple (ELit (LString "message")) (EApp (EVar "JString") (EApp (EVar "parseErrorMessage") (EVar "e")))) (ETuple (ELit (LString "range")) (EVar "r")) (ETuple (ELit (LString "severity")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "source")) (EApp (EVar "JString") (ELit (LString "medaka")))))))) (DoLet false false (PVar "filesJson") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "file")) (EApp (EVar "JString") (EVar "target"))) (ETuple (ELit (LString "diagnostics")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EListLit (EVar "diagJson")))))))) (DoExpr (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "files")) (EApp (EVar "JArray") (EApp (EVar "arrayFromList") (EListLit (EVar "filesJson")))))))))))
(DTypeSig true "checkJsonSingle" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "Bool"))))))))
(DFunDef false "checkJsonSingle" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (ETuple (EApp (EApp (EApp (EVar "cjParseErrJson") (EVar "target")) (EVar "src")) (EVar "e")) (EVar "True"))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EApp (EVar "analyzeLocatedG") (EVar "allowInternal")) (EVar "rsrc")) (EVar "csrc")) (EVar "src"))) (DoExpr (ETuple (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "target") (EVar "src") (EVar "diags")))) (EApp (EApp (EVar "anyList") (EVar "diagIsError")) (EVar "diags"))))))))
(DTypeSig true "checkJsonFile" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyTuple (TyCon "String") (TyCon "Bool")))))))))
(DFunDef false "checkJsonFile" ((PVar "allowInternal") (PVar "rsrc") (PVar "csrc") (PVar "target") (PVar "stdlibDir")) (EBlock (DoLet false false (PVar "src") (EApp (EVar "readFileSafe") (EVar "target"))) (DoLet false false (PVar "roots") (EBinOp "++" (EApp (EVar "entrySearchRoots") (EApp (EVar "dirOf") (EVar "target"))) (EListLit (EVar "stdlibDir")))) (DoExpr (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (ETuple (EApp (EApp (EApp (EVar "cjParseErrJson") (EVar "target")) (EVar "src")) (EVar "e")) (EVar "True"))) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "loadProgramE") (EVar "target")) (EVar "roots")) (arm (PCon "Err" (PCon "LoadParseFailed" (PVar "mpath") (PVar "msrc") (PVar "pe"))) () (ETuple (EApp (EApp (EApp (EVar "cjParseErrJson") (EVar "mpath")) (EVar "msrc")) (EVar "pe")) (EVar "True"))) (arm (PCon "Err" (PCon "LoadMsg" (PVar "lmsg"))) () (EBlock (DoLet false false (PVar "mloc") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "mid")) () (EApp (EApp (EVar "findImportLoc") (EVar "mid")) (EApp (EVar "parseLocated") (EVar "src")))))) (DoLet false false (PVar "mhelp") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" PWild) () (EMatch (EApp (EVar "availableModulesText") (EVar "stdlibDir")) (arm (PLit (LString "")) () (EVar "None")) (arm (PVar "txt") () (EApp (EVar "Some") (EVar "txt"))))))) (DoLet false false (PVar "jmsg") (EBinOp "++" (EVar "lmsg") (EMatch (EApp (EVar "unknownModuleIdOf") (EVar "lmsg")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" PWild) () (EApp (EVar "availableModulesHint") (EVar "stdlibDir")))))) (DoExpr (ETuple (EApp (EVar "cjAllToJson") (EListLit (ETuple (EVar "target") (EVar "src") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Diag") (EVar "SevError")) (ELit (LString "R-MODULE-LOAD"))) (EVar "jmsg")) (EVar "mloc")) (EVar "mhelp")) (EVar "None")))))) (EVar "True"))))) (arm (PCon "Ok" (PVar "mods")) () (EMatch (EVar "mods") (arm (PList (PTuple (PVar "mid") PWild)) () (EBlock (DoLet false false (PVar "trusted") (EApp (EApp (EApp (EApp (EVar "projectTrustedMods") (EVar "target")) (EVar "roots")) (EVar "stdlibDir")) (EVar "mods"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "checkJsonSingle") (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trusted")))) (EVar "rsrc")) (EVar "csrc")) (EVar "target")) (EVar "src"))))) (arm PWild () (EBlock (DoLet false false (PVar "cacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "parseCacheRef") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "analyzeProject") (EVar "cacheRef")) (EVar "parseCacheRef")) (ELam (PWild) (EVar "None"))) (EVar "target")) (EVar "roots")) (EVar "rsrc")) (EVar "csrc"))) (DoLet false false (PVar "triples") (EApp (EApp (EMethodRef "map") (EVar "readDiagSrc")) (EVar "results"))) (DoLet false false (PVar "root") (EApp (EVar "dirOf") (EVar "stdlibDir"))) (DoExpr (ETuple (EApp (EVar "cjAllToJson") (EApp (EApp (EMethodRef "map") (EApp (EVar "relDiagTriple") (EVar "root"))) (EVar "triples"))) (EApp (EApp (EVar "anyList") (EVar "cjHasErrD")) (EVar "results"))))))))))))))
