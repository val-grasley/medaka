# META
source_lines=1281
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/snapshot.mdk — `medaka snapshot`, the in-process snapshot runner
-- (TESTING-DESIGN.md §4.3, R0).
--
-- WHY THIS EXISTS.  `compiler/entries/*.mdk` (70 probe binaries), `test/bin/*` (53
-- compiled oracles) and `test/build_oracles.sh` all exist for ONE reason: bash
-- cannot call a function, only spawn a process.  Every stage terminal is already a
-- `-> String` export, so a driver written in Medaka calls them DIRECTLY, in-process,
-- and one fixture yields every stage's output from a single traversal.
--
-- THE FILE FORMAT (Roc's).  One Markdown file per fixture, one section per stage:
--
--     # META      key=value lines (authored: isolate=true, stages=…; maintained: source_lines)
--     # SOURCE    the fixture, verbatim
--     # TOKENS    lexer
--     # PARSE     parser (via parseResult — see below)
--     # DESUGAR   desugar
--     # MARK      method_marker, against the desugared stdlib/core.mdk prelude
--     # TYPES     typecheck
--     # CORE_IR   Core IR s-expr
--     # LLVM      LLVM text IR
--     # WASM      WasmGC text IR
--     # EVAL      interpreter stdout
--     # CRASH     stderr of a fixture that killed the runner (supervisor-written)
--
-- ── INVARIANT: a section is present only if it was MEANT to be ───────────────
-- `stages=` in `# META` (or `--stages` on the command line, which is how a corpus is
-- first created) restricts a fixture to a subset of the stages.  A restricted fixture
-- is not "partially snapshotted" — the omitted sections are ones that carry no signal
-- for it, and rendering them would be WORSE than not:
--
--   The desugar/mark corpus includes the compiler's own 50 sources and stdlib's 28.
--   Snapshotting those single-file, with no import resolution and no core prelude, makes
--   `# TYPES` a wall of bogus `Unbound variable: otherwise` errors and `# CORE_IR` a
--   180 KB single line — 725 KB and 4.5 s for `frontend/lexer.mdk` ALONE.  Blessing that
--   as an expectation is how a golden corpus rots: nobody reads it, so nothing in it can
--   ever fail meaningfully.  A stage is snapshotted where it is MEANINGFUL, and `stages=`
--   in the file records the choice where the next reader will see it.
--
-- ── INVARIANT: the section-header grammar ────────────────────────────────────
-- A section header is `^# <NAME>$` where <NAME> is one of `snapSections` — ANCHORED,
-- all-caps, nothing trailing.  `isHeaderLine` is the single enforcement point.
--
-- `# SOURCE` is read back by exact LINE COUNT (`source_lines` in `# META`), NEVER by
-- scanning for the next header.  Medaka is indentation-sensitive and `#` is not a
-- comment character, so a fixture may legitimately contain a line that reads exactly
-- `# TOKENS` (inside a multi-line string, say) — scanning for the next header would
-- silently truncate the source and corrupt the file.  Counting lines cannot.
--
-- The other sections ARE delimited by scanning, so a RENDERED section whose content
-- contains a header-shaped line would be ambiguous.  Rather than escape (which would
-- make snapshots unreadable) the runner REFUSES: `sectionCollides` fails the fixture
-- loudly instead of writing a file that will not round-trip.  In practice no stage
-- emits `# TOKENS`-shaped lines; the check is there so it can never happen silently.
--
-- ── parseResult, not parse ───────────────────────────────────────────────────
-- `parse` is partial: it panics `E-PANIC: parse error`.  `parseResult` returns
-- `Result ParseError (List Decl)`.  Using it means a fixture that fails to parse
-- renders a `# PARSE` section holding the diagnostic instead of killing the process —
-- which is what makes the front-end error corpora snapshot-able at all.
--
-- ── one elaboration mode ─────────────────────────────────────────────────────
-- Elaboration is single-mode (#157): TYPES / CORE_IR / EVAL / LLVM / WASM all
-- elaborate identically, so this runner can render every section of every fixture
-- in one process with no per-stage or per-fixture mode flag to save and restore.
--
-- ── crash-resume ─────────────────────────────────────────────────────────────
-- ~12 of 1,461 fixtures genuinely panic (and `stack_overflow_fixtures` SIGSEGVs the C
-- stack — uncatchable in principle).  Forking per fixture to protect 0.8% would cost a
-- 25x slowdown against a 49ms spawn floor, so instead a SUPERVISOR spawns a WORKER over
-- a chunk of fixtures.  The worker streams each rendered section to stdout, flushing as
-- it goes; `runCommand` captures the child's stdout/stderr through temp FILES, so a
-- SIGSEGV loses nothing already flushed.  On a crash the supervisor takes the last
-- `BEGIN` with no matching `END` as the killer, records the child's stderr as that
-- fixture's `# CRASH` section, and respawns over the remainder of the chunk.  A fixture
-- carrying `isolate=true` in `# META` is given a chunk of its own up front, so a known
-- crasher costs zero respawns in steady state.
--
-- The worker RENDERS; the supervisor COMPARES and WRITES.  Keeping all file IO in the
-- supervisor is what lets a crashed fixture still get a snapshot: the supervisor already
-- holds every section the worker streamed before it died.
--
-- ── the three modes, and why `--bless` has three locks on it ─────────────────
--
--   --check   compare; write nothing.                             (the gate)
--   --new     create a MISSING snapshot; never touch an existing one.
--   --bless   rewrite an EXISTING snapshot from the current compiler; never create one.
--
-- Blessing is how a golden suite dies.  Every survey point in TESTING-DESIGN.md §3.1
-- says the same thing: a bless button with no friction turns every regression green,
-- because the author who broke it is also the one who presses it.  So `--bless` carries
-- exactly the three locks the surveyed tools converged on:
--
--   1. SCOPED (OCaml's rule).  `--bless` requires explicit targets; there is no
--      whole-suite bless and there will not be one.  OCaml has `make promote` with a
--      scope and deliberately "no analogue to `make all`" — naming what you approve is
--      the friction, and it is the only part of the design that survives without CI.
--      Enforced in `medaka_cli.mdk` (a bless with no targets EXITS) and again in
--      `test/diff_compiler_snapshot_frontend.sh` (`--bless` without paths is refused).
--
--   2. NON-CREATING (GHC's rule: accept cannot create a golden).  `--bless` on a fixture
--      with no `.md` FAILS and points at `--new`.  If a broken stage could mint its own
--      expectations, the whole corpus is worth nothing — a stage that starts emitting
--      garbage would simply write the garbage down as correct.
--
--   3. DIAGNOSTICS ARE NEVER BLESSABLE (Zig's rule: it ships NO bless for expected error
--      text, and that is *why* its errors are good).  This repo grades diagnostics in
--      `compiler/ERROR-QUALITY.md` against a scored corpus; an auto-blessable diagnostic
--      golden is actively hostile to that, because it lets a message regress and be
--      re-blessed without anyone reading it.  So a fixture whose DIFFERING sections
--      include a diagnostic-bearing one is REFUSED, whole.  Fix it, or `rm` the `.md` and
--      `--new` it — which is a deliberate, visible act that shows up in review as a
--      delete+add rather than a one-line edit.
--
-- ── mechanism for (3): the RENDERER tags, the FILE records, the BLESSER refuses ──
--
-- NOT a section allowlist, and the reason is `# PARSE`.  The same section name holds a
-- blessable s-expr dump for a fixture that parses, and a *parse error message* for one
-- that does not.  A static allowlist would have to pick one: mark PARSE unblessable and
-- the main use case dies (a `medaka fmt` reflow of a compiler source rewrites exactly
-- PARSE/DESUGAR/MARK); mark it blessable and error prose regresses in silence.
-- Diagnostic-ness is a property of the RENDER, not of the section name.
--
-- So the WORKER tags a section diagnostic at the point it renders one, where the fact is
-- structural rather than a text sniff (`SECD` on the wire instead of `SEC`):
--
--     PARSE   diagnostic iff it came from `parseResult`'s Err branch.
--     TYPES   diagnostic iff the pass accumulated a TYPE ERROR or a match warning
--             (`hadTypeErrors` / `hadMatchWarnings` — the accumulators themselves, not
--             a grep for "TYPE ERROR:" in the text the renderer just produced).
--     CRASH   always — it is a stderr dump by construction.
--     (a future `# DIAGNOSTICS` section marks itself the same way, at its render site.)
--
-- The supervisor then records the set in `# META` as `diagnostics=PARSE,…`, so the fact
-- is visible to a human reading the `.md` and, critically, so the refusal ALSO fires on
-- the STORED snapshot: a section that is diagnostic in the file but clean in the fresh
-- render (a diagnostic that just *disappeared*) is equally unblessable.  That direction
-- matters — it is the one where a stage silently stops reporting an error.

import frontend.ast.{Decl}
import frontend.lexer.{
  tokenize,
  tokenToString,
  collectComments,
  Comment,
  commentLine,
  commentCol,
  commentText,
}
import frontend.parser.{
  parseResult,
  parseErrorLine,
  parseErrorCol,
  parseErrorMessage,
  parseWithPositions,
  Positions,
  DeclPos,
  positionsDecls,
  positionsVariantLines,
  positionsLastContentLine,
  declPosLine,
  declPosEndLine,
}
import tools.printer.{programToString}
import frontend.desugar.{desugar}
import frontend.marker.{markWithPrelude}
import ir.sexp.{programToSexp}
import ir.core_ir.{CProgram}
import ir.core_ir_lower.{
  lowerProgram,
  lowerProgramEmit,
  returnsSelfTable,
  selfFnParamTable,
  methodIfaceTable,
  methodConstraintIfaces,
  ctorFieldTypeNames,
  declSigTypeNames,
}
import ir.core_ir_sexp.{cprogramToSexp}
import types.annotate.{annotateProgram}
import types.typecheck.{
  checkToLinesWithRuntime,
  setCoherenceUserDecls,
  elaborateOne,
  elaborateDict,
  constrainedSigNames,
  mainTypeIsUnit,
  mainTypeIsFloat,
  hadTypeErrors,
  hadMatchWarnings,
  resetTypeErrorsSticky,
}
import eval.eval.{evalOneOutput, funNamesOf, dropShadowedExp, noMainMsg}
import backend.llvm_emit.{
  emitProgram,
  installReturnsSelf,
  installSelfFnParams,
  installMethodIface,
  installMethodConstraintIfaces,
  installCtorFieldTypes,
  installDeclSigTypes,
  installMainIsUnitHint,
  installMainIsFloatHint,
  enableGapRecord,
  resetGaps,
  gapEvents,
}
-- `backend.wasm_emit` also exports `emitProgram`, colliding with the LLVM one above.
-- A member alias renames it on import, so BOTH backends are driven from ONE process
-- over ONE lowered CProgram.  (This is what retired `tools/snap_wasm.mdk`, a re-export
-- shim that existed solely because Medaka had no import aliasing.)
import backend.wasm_emit.{
  emitProgram as wasmText,
  installDeclRetTypes,
  installCtorFloatFields,
  enableGapRecordW,
  resetGapsW,
  gapEventsW,
}
import support.util.{
  joinNl,
  joinWith,
  splitNl,
  startsWith,
  anyList,
  reverseL,
  filterList,
}
import support.path.{chopExt, baseOf}
import string.{
  split,
  replaceAll,
  trim,
  trimRight,
  take,
  drop,
  toInt,
  toFloat,
  toUpper,
}

-- ── section vocabulary ───────────────────────────────────────────────────────

-- Canonical FILE order.  (The worker renders in a different order — OFF-mode stages
-- before ON-mode ones — and the supervisor reorders into this.)
export snapSections : List String
snapSections = [
  "META",
  "SOURCE",
  "TOKENS",
  "COMMENTS",
  "POSITIONS",
  "PARSE",
  "PRINTER",
  "DESUGAR",
  "MARK",
  "TYPES",
  "TYPES_USER",
  "CORE_IR",
  "LLVM",
  "WASM",
  "EVAL",
  "CRASH",
]

-- The ONE enforcement point for the header grammar: `^# <NAME>$`, anchored, exact.
export isHeaderLine : String -> Bool
isHeaderLine l = anyList (n => l == "# \{n}") snapSections

-- A rendered section whose content contains a header-shaped line cannot round-trip.
sectionCollides : String -> Bool
sectionCollides content = anyList isHeaderLine (splitNl content)

-- ── modes ────────────────────────────────────────────────────────────────────
-- See the header block: Check is the gate, New creates only what is missing, Bless
-- rewrites only what already exists (and never a diagnostic).
-- `public export`, not plain `export`: a plain `export data` exports the type
-- ABSTRACTLY (no constructors), so medaka_cli's `import tools.snapshot.{SnapMode(..)}`
-- had nothing to bind and every SnapCheck/SnapNew/SnapBless there was unbound.
-- It ran anyway — the emitter's ctor table is global, so the built binary worked
-- while the source was ill-typed, and `make medaka` does not gate on type errors.
-- Only test/typecheck_compiler_source.sh catches this. That is why that gate exists.
public export data SnapMode = SnapCheck | SnapNew | SnapBless

-- ── a rendered section ───────────────────────────────────────────────────────
-- (name, content, isDiagnostic).  The flag is set by the WORKER at the render site and
-- carried over the wire (`SECD`), because only the renderer knows structurally whether
-- what it produced is compiler diagnostic prose.  Sections read back FROM a file carry
-- no flag — there the fact lives in `# META`'s `diagnostics=` line instead.
type RunSec = (String, String, Bool)

secName : RunSec -> String
secName (n, _, _) = n

secBody : RunSec -> String
secBody (_, b, _) = b

secIsDiag : RunSec -> Bool
secIsDiag (_, _, d) = d

-- Drop the flags: everything downstream of the diagnostic check works on (name, body)
-- pairs, exactly as a file-parsed snapshot does.
secPairs : List RunSec -> List (String, String)
secPairs secs = map (s => (secName s, secBody s)) secs

diagNamesOf : List RunSec -> List String
diagNamesOf secs = map secName (filterList secIsDiag secs)

-- ── stage selection ──────────────────────────────────────────────────────────
--
-- A stage set is a list of section names.  `[]` means EVERY stage — so the default,
-- and every existing caller, is unchanged.

-- `--stages parse,desugar,mark` (case-insensitive; `# META` stores the canonical
-- upper-case form).  An unknown name is a HARD ERROR rather than a silent no-op: a
-- typo'd stage would otherwise omit the very section the run was meant to check and
-- report a clean pass — the exact silent-green failure this harness exists to kill.
export parseStages : String -> Result String (List String)
parseStages spec =
  let names = filterList (!= "") (map (s => toUpper (trim s)) (split "," spec))
  match filterList (n => not (anyList (== n) snapSections)) names
    [] => Ok names
    bad => Err "unknown stage(s): \{joinWith ", " bad} (known: \{joinWith ", " snapSections})"

-- SOURCE is never optional (it is the input, and `source_lines` is what makes the file
-- readable back); META is synthesized.  Everything else is gated.
wants : List String -> String -> Bool
wants [] _ = True
wants sel n = anyList (== n) sel

-- ── content hygiene ──────────────────────────────────────────────────────────

-- Drop the trailing "" that splitNl yields for a newline-terminated string.
contentLines : String -> List String
contentLines "" = []
contentLines s = dropTrailingEmpty (splitNl s)

dropTrailingEmpty : List String -> List String
dropTrailingEmpty [] = []
dropTrailingEmpty [""] = []
dropTrailingEmpty (x::rest) = x :: dropTrailingEmpty rest

-- Canonical block: either empty, or newline-terminated exactly once.
blockOf : List String -> String
blockOf [] = ""
blockOf ls = "\{joinNl ls}\n"

-- ── normalization (TESTING-DESIGN.md §4.5, Law 1) ────────────────────────────
--
-- LAW: normalize the ACTUAL output; NEVER put a wildcard in the EXPECTED.  Both
-- ppx_expect and Dune shipped regex matchers in goldens and then REMOVED them — a
-- golden containing a wildcard cannot be regenerated, so the expectation rots into
-- something no tool can rewrite and no human can verify.  So every rule below runs
-- over freshly-rendered output only, on its way in; the .md on disk is literal text
-- compared byte-for-byte.
--
-- Every normalization rule is a hole in the test, so the set is deliberately minimal:
--
--   1. the absolute repo root       -> <ROOT>
--   2. mktemp build scratch dirs    -> <TMP>   (per-invocation since cc1a5fb3)
--   3. duration literals            -> <T>
--   4. trailing whitespace + exactly one final newline   (`canonText`, ALL sections)
--
-- ⚠️ AND THE SET IS SCOPED, not just small: rules 1–3 run ONLY on the sections that RUN
-- something — `# EVAL`'s stdout and `# CRASH`'s stderr (`isRunSection`).  Every other
-- section is a pure, deterministic function of the fixture's SOURCE TEXT, so a
-- `/tmp/medaka_build_…`, a `0.5s` or an absolute path appearing in one can ONLY have
-- come from the source itself — and rewriting it does not hide noise, it DESTROYS
-- content.
--
-- This is not hypothetical; it is why the rule is here.  The migration's own
-- byte-identity check (test/migrate_verify.sh) caught the blanket normalizer red-handed
-- on TWO of the compiler's own sources:
--
--   • driver/build_cmd.mdk holds the literal mktemp template "/tmp/medaka_build_XXXXXX",
--     which normalized to `(ELit (LString "<TMP>"))` in its PARSE/DESUGAR/MARK dumps —
--     silently blinding those sections to the template.
--   • THIS FILE holds the bare prefix `tmpPrefix = "/tmp/medaka_build_"`, and `normTmp`'s
--     unconditional `drop 6` (which assumes a 6-char mktemp suffix always follows) ate
--     the closing `")))` instead, emitting a TRUNCATED, structurally invalid s-expr line:
--         (DFunDef false "tmpPrefix" () (ELit (LString "<TMP>
--
-- A normalizer that can corrupt the thing it normalizes must not be pointed at anything
-- it is not needed for.  (`drop 6` is still unconditional inside `normTmp` — it is sound
-- for a REAL mktemp path, which is all it now ever sees.)
--
-- NOT included: any symbol-hash / gensym rule.  The self-compile fixpoint reproduces
-- byte-identical IR, which is direct evidence that emission is deterministic per
-- program, so such a rule would buy nothing and blind the LLVM/WASM sections to real
-- codegen churn.  It goes in only if something is PROVEN nondeterministic.
--
-- `# SOURCE` and `# META` get neither: SOURCE is the input (normalizing it would mean
-- comparing the fixture against a doctored copy of itself), and META is authored.
isRunSection : String -> Bool
isRunSection n = n == "EVAL" || n == "CRASH"

-- trailing whitespace + exactly one final newline.  ALL rendered sections.
canonText : String -> String
canonText text = blockOf (map trimRight (contentLines text))

export normalizeText : String -> String -> String
normalizeText root text = blockOf (map (normalizeLine root) (contentLines text))

normalizeLine : String -> String -> String
normalizeLine root line =
  trimRight (normDurations (normTmp (replaceAll root "<ROOT>" line)))

-- `mktemp -d /tmp/medaka_build_XXXXXX` — the suffix is exactly 6 random chars, so the
-- random run has a known length and needs no scanner.
normTmp : String -> String
normTmp line = match split tmpPrefix line
  [] => line
  [only] => only
  first::rest => joinWith "<TMP>" (first :: map (drop 6) rest)

tmpPrefix : String
tmpPrefix = "/tmp/medaka_build_"

-- Word-wise, so it can only fire on a STANDALONE duration token (`0.197s`, `12ms`).
-- Splitting on " " and rejoining with " " is lossless (runs of spaces survive as empty
-- words), and no LLVM/WAT token is duration-shaped, so the IR sections are untouched.
normDurations : String -> String
normDurations line = joinWith " " (map durWord (split " " line))

durWord : String -> String
durWord w = if isDuration w then "<T>" else w

isDuration : String -> Bool
isDuration w =
  let body = durBody w
  if body == "" then False else isNumeric body

-- strip a trailing "ms" or "s"; "" means "not a duration-shaped word".
durBody : String -> String
durBody w
  | endsWithStr "ms" w = take (stringLength w - 2) w
  | endsWithStr "s" w = take (stringLength w - 1) w
  | otherwise = ""

endsWithStr : String -> String -> Bool
endsWithStr suf s =
  let n = stringLength s
  let m = stringLength suf
  if m > n then False else drop (n - m) s == suf

-- digits, or digits with a decimal point — reuse the parsers rather than classify chars.
isNumeric : String -> Bool
isNumeric s = match toInt s
  Some _ => True
  None => match toFloat s
    Some _ => True
    None => False

-- ── stage rendering ──────────────────────────────────────────────────────────

tokensOf : String -> String
tokensOf src = blockOf (map tokenToString (tokenize src))

-- # COMMENTS renders the lexer's comment side-channel, one per line as
-- `<line>:<col>:<text>` (1-based line, 0-based col, full lexeme incl. `--`/`{- -}`
-- delimiters; embedded newlines escaped to `\n`).  Renders the comment channel the
-- retired diff_compiler_comments gate checked, in-process (lex -> collectComments).
commentsOf : String -> String
commentsOf src = blockOf (map renderComment (collectComments src))

renderComment : Comment -> String
renderComment c = "\{intToString (commentLine c)}:\{intToString (commentCol c)}:\{escNl (commentText c)}"

escNl : String -> String
escNl s = stringConcat (escNlFrom (stringToChars s) 0)

escNlFrom : Array Char -> Int -> List String
escNlFrom cs i
  | i >= arrayLength cs = []
  | arrayGetUnsafe i cs == '\n' = "\\n" :: escNlFrom cs (i + 1)
  | otherwise = charToStr (arrayGetUnsafe i cs) :: escNlFrom cs (i + 1)

-- # POSITIONS renders the parser's per-decl (line:end_line) + variant-line +
-- last-content-line side-channel, in the DECLS/VARIANTS/LASTLINE form the retired
-- diff_compiler_positions gate (positions_main = parseWithPositions) checked.
positionsOf : String -> String
positionsOf src = match parseWithPositions src
  (_decls, pos) => renderPositions pos

renderPositions : Positions -> String
renderPositions p =
  let decls = stringConcat (map renderDeclPos (positionsDecls p))
  let vars = stringConcat (map renderVariant (positionsVariantLines p))
  "=== DECLS ===\n\{decls}=== VARIANTS ===\n\{vars}=== LASTLINE ===\n\{intToString (positionsLastContentLine p)}\n"

renderDeclPos : DeclPos -> String
renderDeclPos d =
  "\{intToString (declPosLine d)}:\{intToString (declPosEndLine d)}\n"

renderVariant : Int -> String
renderVariant n = "\{intToString n}\n"

parseErrText : Int -> Int -> String -> String
parseErrText line col msg =
  "parse error at \{intToString line}:\{intToString col}: \{msg}\n"

-- Marked against the DESUGARED prelude, which is exactly what the pipeline does
-- (`marker.mdk` runs after desugar+resolve) and exactly what the old `mark_main` probe
-- did (`markWithPrelude (desugar (parse core.mdk)) (desugar (parse target))`).
markOf : List Decl -> List Decl -> String
markOf coreDecls d = programToSexp (markWithPrelude coreDecls d)

-- Returns the rendered section AND whether it carries diagnostic prose.  A `# TYPES`
-- section is either a scheme dump (`f : Int -> Int`) or a wall of `TYPE ERROR:` lines,
-- and it may carry `W-*` match warnings alongside the schemes — both are graded prose
-- under ERROR-QUALITY.md, so either makes the section unblessable.  Keyed on the
-- typecheck accumulators, never on the text: a renderer that greps its own output for
-- "TYPE ERROR:" is one reworded message away from silently becoming blessable.
typesOf : List Decl -> List Decl -> (String, Bool)
typesOf runtimeDecls d =
  let _ = setCoherenceUserDecls d
  let _ = resetTypeErrorsSticky ()
  let text = checkToLinesWithRuntime runtimeDecls [] d
  (text, hadTypeErrors () || hadMatchWarnings ())

-- `# TYPES_USER` — the PRELUDE-AWARE user-only variant.  `# TYPES` above is
-- prelude-FREE (`checkToLinesWithRuntime runtimeDecls [] d`): correct for the minimal
-- typecheck_fixtures (which test errors *without* a prelude in scope), but WRONG for a
-- real program that references prelude types — every prelude reference would be an
-- unbound-name error.  This variant typechecks `coreDecls ++ d` (prelude in scope) so
-- the user schemes infer correctly, then keeps ONLY the user program's own bindings.
--
-- WHY name-filter, not `full − prelude_baseline` (measured): a prelude function whose
-- inferred scheme is context-sensitive (`abs : a -> a` under ambiguous-Num defaulting
-- resolves differently per fixture) does NOT cancel against a fixed prelude baseline and
-- LEAKS in as a false user line.  Keying on the NAME is exact: keep a scheme line iff
-- its binding name is in `funNamesOf d` (the DESUGARED user decls, so deriving-generated
-- functions are covered).  User data CONSTRUCTORS never appear in the scheme dump (it is
-- top-level function bindings only), so `funNamesOf` alone is the complete user-name set.
-- A user binding that SHADOWS a prelude name is in `funNamesOf d`, so its (user) scheme
-- is kept.  See [[project_81_prelude_aware_types_design]] — the filter lives here because
-- compiler/types/typecheck.mdk is LOCKED by ws:typecheck.
--
-- The ERROR/warning path is NOT filtered: on a type error `checkToLinesWithRuntime`
-- returns `TYPE ERROR:` lines instead of a scheme dump, and match warnings are appended
-- as `Warning:` prose — neither is a `name : scheme` line, and both must survive so the
-- section still reports the diagnostic (and stays unblessable).
typesUserOf : List Decl -> List Decl -> List Decl -> (String, Bool)
typesUserOf runtimeDecls coreDecls d =
  let _ = setCoherenceUserDecls d
  let _ = resetTypeErrorsSticky ()
  let full = checkToLinesWithRuntime runtimeDecls coreDecls d
  let diag = hadTypeErrors () || hadMatchWarnings ()
  -- Filter the SUCCESS path (scheme dump) only; a diagnostic run has no schemes to trim.
  let text = if hadTypeErrors () then full
             else blockOf (filterList (userSchemeLine (funNamesOf d)) (contentLines full))
  (text, diag)

-- Keep a `# TYPES_USER` line iff it is NOT a scheme line (a `Warning:` / blank line has
-- no ` : ` separator ⇒ ≤1 split part ⇒ kept) OR its binding name is a user binding.
-- Type syntax uses `->`/`=>`, never ` : `, so the first ` : ` is always the name/scheme
-- boundary; a nested record ` : ` only adds parts AFTER the name, so `nm` stays correct.
userSchemeLine : List String -> String -> Bool
userSchemeLine userNames line = match split " : " line
  nm::_::_ => anyList (== nm) userNames
  _ => True

-- PRELUDE-FREE, exactly as entries/core_ir_dump_main.mdk (which is what the existing
-- core_ir_sexp goldens are captured from): lower the USER program only.  Elaborating
-- against the prelude instead would splice ~110 KB of identical prelude IR into every
-- single snapshot — the section is here to show what the fixture lowers to, and the
-- dispatch-bearing lowering is already covered by `# LLVM`.
coreIrOf : List Decl -> String
coreIrOf d = cprogramToSexp (lowerProgram (annotateProgram d))

evalOf : List Decl -> List Decl -> List Decl -> String
evalOf runtimeDecls coreDecls d =
  let livePrelude = dropShadowedExp (funNamesOf d) coreDecls
  evalOneOutput
    []
    ("__main__", elaborateOne runtimeDecls livePrelude ("__user__", d))

-- ── the emit path (BOTH backends, ONE lowered CProgram) ──────────────────────
--
-- `elaborateDict` -> `lowerProgramEmit` runs ONCE and the resulting CProgram feeds
-- llvm_emit AND wasm_emit (whose colliding `emitProgram` is import-aliased to
-- `wasmText` above).
--
-- PRELUDE-FREE (runtime.mdk only, no core.mdk) — the exact shape of
-- entries/llvm_emit_typed_main.mdk and wasm_emit_typed_main.mdk, which are what the
-- diff_compiler_llvm_typed and wasm gates already drive.  This is not a shortcut, it is
-- forced: DCE retains every impl/interface WHOLE (dispatch is runtime dict-passing, so
-- pruning an impl would be a silent miscompile), so elaborating against core.mdk drags
-- in ~274 prelude impl functions no matter what the fixture uses.  Measured: that put
-- an 80,190-line WASM section into a 3-line fixture's snapshot.  A snapshot corpus that
-- pastes the whole prelude's IR into all 1,461 files is not a corpus, it is a mistake.
-- (The dispatch fixtures define their own minimal interfaces for exactly this reason.
-- Wiring the full modules+DCE build path behind a `# META` key is R1's business.)
--
-- GAP CENSUS is ON for both backends.  The WasmGC emitter PANICS at the first node it
-- cannot lower, and it only implements 74 of 134 externs — so without census mode a
-- `# WASM` section would kill the runner on most fixtures.  In census mode the emitter
-- records the gap, substitutes a placeholder, and keeps going; the recorded gaps are
-- appended to the section as backend-native comments, which is precisely FORK 1's
-- point: wasm coverage drift becomes a visible diff instead of silence.
emitBoth : String -> List String -> List Decl -> List Decl -> <IO> Unit
emitBoth root sel runtimeDecls userDecls =
  let userNames = funNamesOf userDecls
  let dictNames = constrainedSigNames userDecls
  let allDecls = elaborateDict runtimeDecls dictNames userNames userDecls
  let cp = lowerProgramEmit allDecls
  let _ = if wants sel "LLVM" then
    emitSection root "LLVM" (llvmOf runtimeDecls allDecls cp)
  else
    ()
  if wants sel "WASM" then
    emitSection root "WASM" (wasmOf runtimeDecls allDecls cp)
  else
    ()

llvmOf : List Decl -> List Decl -> CProgram -> String
llvmOf runtimeDecls allDecls cp =
  let _ = installReturnsSelf (returnsSelfTable allDecls)
  let _ = installSelfFnParams (selfFnParamTable allDecls)
  let _ = installMethodIface (methodIfaceTable allDecls)
  let _ = installMethodConstraintIfaces (methodConstraintIfaces allDecls)
  let _ = installCtorFieldTypes (ctorFieldTypeNames allDecls)
  let _ = installDeclSigTypes (declSigTypeNames runtimeDecls ++ declSigTypeNames allDecls)
  let _ = installMainIsUnitHint (mainTypeIsUnit ())
  let _ = installMainIsFloatHint (mainTypeIsFloat ())
  let _ = resetGaps ()
  let _ = enableGapRecord ()
  let text = emitProgram cp
  withGaps ";" text (gapEvents ())

wasmOf : List Decl -> List Decl -> CProgram -> String
wasmOf runtimeDecls allDecls cp =
  let _ = installDeclRetTypes (declSigTypeNames runtimeDecls ++ declSigTypeNames allDecls)
  let _ = installCtorFloatFields (ctorFieldTypeNames allDecls)
  let _ = resetGapsW ()
  let _ = enableGapRecordW ()
  let text = wasmText cp
  withGaps ";;" text (gapEventsW ())

withGaps : String -> String -> List String -> String
withGaps _ text [] = text
withGaps cmt text gaps =
  blockOf (contentLines text ++ map (g => "\{cmt} GAP: \{g}") gaps)

-- ── the worker: render + stream ──────────────────────────────────────────────
--
-- Wire protocol (stdout, one line each).  Every CONTENT line is prefixed with a
-- literal `D`, which is why a section may safely contain anything at all — including
-- lines that look like protocol lines or like headers:
--
--     BEGIN <path>
--     SEC <NAME>      -- an ordinary section
--     SECD <NAME>     -- a DIAGNOSTIC-bearing section (never blessable; see the header)
--     D<line>...
--     END <path>
--
-- Flushed after every section, so a SIGSEGV mid-fixture still leaves the supervisor
-- with every section completed before it.

putLineFlush : String -> <IO> Unit
putLineFlush s =
  let _ = putStrLn s
  flushStdout ()

emitSection : String -> String -> String -> <IO> Unit
emitSection root name content = emitSectionTagged root name content False

-- The ONE place a section is declared diagnostic-bearing.  Called at the render site,
-- where the fact is structural (see the header block's mechanism note).
emitDiagSection : String -> String -> String -> <IO> Unit
emitDiagSection root name content = emitSectionTagged root name content True

emitSectionTagged : String -> String -> String -> Bool -> <IO> Unit
emitSectionTagged root name content diag = emitRawTagged
  name
  (if isRunSection name then normalizeText root content else canonText content)
  diag

-- SOURCE bypasses normalization: it is the input, verbatim.
emitRaw : String -> String -> <IO> Unit
emitRaw name content = emitRawTagged name content False

emitRawTagged : String -> String -> Bool -> <IO> Unit
emitRawTagged name content diag =
  let _ = putStrLn (if diag then "SECD \{name}" else "SEC \{name}")
  let _ = putStr (encodeLines (contentLines content))
  flushStdout ()

encodeLines : List String -> String
encodeLines ls = stringConcat (map (l => "D\{l}\n") ls)

export runSnapshotWorker : String -> List String -> List String -> <IO> Unit
runSnapshotWorker root sel files = match loadPrelude root
  Err msg =>
    let _ = ePutStrLn msg
    exit 1
  Ok (runtimeDecls, coreDecls) =>
    workerLoop root sel runtimeDecls coreDecls files

loadPrelude : String -> <IO> Result String (List Decl, List Decl)
loadPrelude root = match readFile "\{root}/stdlib/runtime.mdk"
  Err e => Err "snapshot: cannot read stdlib/runtime.mdk: \{e}"
  Ok rsrc => match readFile "\{root}/stdlib/core.mdk"
    Err e => Err "snapshot: cannot read stdlib/core.mdk: \{e}"
    Ok csrc => match parseResult rsrc
      Err _ => Err "snapshot: stdlib/runtime.mdk does not parse"
      Ok rd => match parseResult csrc
        Err _ => Err "snapshot: stdlib/core.mdk does not parse"
        Ok cd => Ok (desugar rd, desugar cd)

workerLoop : String -> List String -> List Decl -> List Decl -> List String -> <IO> Unit
workerLoop _ _ _ _ [] = ()
workerLoop root sel runtimeDecls coreDecls (f::rest) =
  let _ = workerOne root sel runtimeDecls coreDecls f
  workerLoop root sel runtimeDecls coreDecls rest

workerOne : String -> List String -> List Decl -> List Decl -> String -> <IO> Unit
workerOne root sel runtimeDecls coreDecls path =
  let _ = putLineFlush "BEGIN \{path}"
  let _ = workerRender root sel runtimeDecls coreDecls path
  putLineFlush "END \{path}"

workerRender : String -> List String -> List Decl -> List Decl -> String -> <IO> Unit
workerRender root sel runtimeDecls coreDecls path = match readFile path
  Err msg => emitDiagSection root "CRASH" "cannot read fixture: \{msg}\n"
  Ok src =>
    -- SOURCE is emitted RAW — never normalized, never reflowed.
    let _ = emitRaw "SOURCE" src
    let _ = if wants sel "TOKENS" then emitSection root "TOKENS" (tokensOf src) else ()
    let _ = if wants sel "COMMENTS" then emitSection root "COMMENTS" (commentsOf src) else ()
    let _ = if wants sel "POSITIONS" then emitSection root "POSITIONS" (positionsOf src) else ()
    match parseResult src
      -- parseResult, not parse: a parse failure is a rendered section, not a panic.
      --
      -- Emitted even when PARSE is not in `stages`: a fixture that suddenly stops
      -- parsing must not render as an empty snapshot.  The extra section makes the
      -- run's sections differ from the file's, so `--check` FAILS — which is the point.
      --
      -- DIAGNOSTIC: this is the one branch where `# PARSE` holds error prose rather than
      -- an s-expr dump, and it is why diagnostic-ness cannot be a per-section-name
      -- allowlist.  Tagged here, at the only site that can know.
      Err e => emitDiagSection root "PARSE" (parseErrText (parseErrorLine e) (parseErrorCol e) (parseErrorMessage e))
      Ok decls => workerStages root sel runtimeDecls coreDecls decls

workerStages : String -> List String -> List Decl -> List Decl -> List Decl -> <IO> Unit
workerStages root sel runtimeDecls coreDecls decls =
  let _ = if wants sel "PARSE" then emitSection root "PARSE" (programToSexp decls) else ()
  -- # PRINTER: reprinted source (AST -> source via tools.printer.programToString).
  -- Renders the comment-preserving reprint the retired diff_compiler_printer gate
  -- checked, in-process; decls here is the parseResult Ok list, identical to `parse`
  -- for a parseable fixture.
  let _ = if wants sel "PRINTER" then emitSection root "PRINTER" (programToString decls) else ()
  let d = desugar decls
  let _ = if wants sel "DESUGAR" then emitSection root "DESUGAR" (programToSexp d) else ()
  let _ = if wants sel "MARK" then emitSection root "MARK" (markOf coreDecls d) else ()
  -- OFF-mode (eval-path) stages first...
  let _ = if wants sel "TYPES" then emitTypes root runtimeDecls d else ()
  let _ = if wants sel "TYPES_USER" then emitTypesUser root runtimeDecls coreDecls d else ()
  let _ = if wants sel "CORE_IR" then emitSection root "CORE_IR" (coreIrOf d) else ()
  -- ...then the RUNNABLE stages, but ONLY for a fixture that has a `main`.
  --
  -- Most front-end fixtures (the whole parse/desugar corpus) are decl soup with no
  -- entry point, and both the interpreter (E-NO-MAIN) and the emitter's main-hint
  -- installers assume one.  Actually RUNNING them would fire the crash-resume machinery
  -- on the common case (a real SIGSEGV mid-chunk, costing a respawn) and — for the
  -- LLVM/WASM emitters, whose main-hint installers assume a `main` — could misbehave in
  -- ways that are hard to distinguish from a real crash.  So the runnable stages are
  -- OMITTED for a no-`main` fixture — with ONE exception:
  --
  -- when `# EVAL` is explicitly requested (only the eval-family gates do, never the
  -- parse/desugar corpus), a no-`main` program's OBSERVABLE behaviour under `medaka run`
  -- IS the E-NO-MAIN runtime error — that is the whole point of test/eval_error_fixtures/
  -- no_main.mdk.  We surface it as a STATIC `# CRASH` diagnostic (the exact text
  -- `runtimePanic "E-NO-MAIN" noMainMsg` prints, envelope inlined from eval.mdk:1754,
  -- message reused from `noMainMsg` so it cannot drift) rather than by actually letting
  -- the interpreter abort — a static emit is byte-identical to the real crash's
  -- normalized `# CRASH` but costs zero respawns and never trips crash-resume.
  if hasMain d then
    -- EMIT first ... then EVAL, dead last.
    --
    -- EVAL goes last because it is the only stage that RUNS the fixture, so it is by
    -- far the likeliest to take the process down — and whatever kills it must not also
    -- cost us the LLVM/WASM sections.  (Concretely: llvm_fixtures/abort_exit_after_output
    -- calls `exit`, which the interpreter does not implement — CAPABILITY-EXCEPTIONS.txt
    -- BUG(T7) — so its EVAL panics while both backends emit it perfectly well.)
    let _ = if wants sel "LLVM" || wants sel "WASM" then
      emitBoth root sel runtimeDecls d
    else
      ()
    if wants sel "EVAL" then emitSection root "EVAL" (evalOf runtimeDecls coreDecls d) else ()
  else
    if wants sel "EVAL" then
      emitDiagSection root "CRASH" ":0:0: runtime error [E-NO-MAIN]: \{noMainMsg}\n"
    else
      ()

-- `# TYPES` is diagnostic-bearing exactly when the pass it just ran accumulated an error
-- or a warning — so the tag is decided from `typesOf`'s second component, not from the
-- shape of the lines it produced.
emitTypes : String -> List Decl -> List Decl -> <IO> Unit
emitTypes root runtimeDecls d =
  let (text, diag) = typesOf runtimeDecls d
  emitSectionTagged root "TYPES" text diag

-- `# TYPES_USER` is diagnostic-bearing on the same accumulator keying as `# TYPES`.
emitTypesUser : String -> List Decl -> List Decl -> List Decl -> <IO> Unit
emitTypesUser root runtimeDecls coreDecls d =
  let (text, diag) = typesUserOf runtimeDecls coreDecls d
  emitSectionTagged root "TYPES_USER" text diag

hasMain : List Decl -> Bool
hasMain d = anyList (== "main") (funNamesOf d)

-- ── the supervisor: spawn, survive crashes, compare/write ────────────────────

-- A worker handles a chunk of fixtures.  Small enough that a crash re-runs little and
-- the captured stdout stays a sane size; large enough that the 49ms spawn floor is
-- amortized to nothing.
chunkSize : Int
chunkSize = 25

-- One worker process: the stage set it runs under, and the fixtures it runs.
type Chunk = (List String, List String)

export runSnapshotSupervisor : String -> SnapMode -> Bool -> Option String -> List String -> List String -> <IO> Bool
runSnapshotSupervisor root mode forceIsolate outDir cli files =
  let results = superviseChunks root mode outDir (chunksOf root outDir forceIsolate cli files)
  reportResults results

-- Group into chunks, but give any fixture whose META says `isolate=true` a chunk of its
-- own — a known crasher then costs ZERO respawns in steady state.
chunksOf : String -> Option String -> Bool -> List String -> List String -> <IO> List Chunk
chunksOf _ _ _ _ [] = []
chunksOf root outDir forceIsolate cli (f::rest) =
  let meta = metaOf root outDir f
  let sel = stagesIn cli meta
  if forceIsolate || isIsolatedIn meta then (sel, [f]) :: chunksOf root outDir forceIsolate cli rest
  else
    let (grp, tail2) = takeRun root outDir forceIsolate cli sel (chunkSize - 1) rest
    (sel, f::grp) :: chunksOf root outDir forceIsolate cli tail2

-- A worker process carries ONE `--stages`, so a run of fixtures is groupable only while
-- their stage sets agree — mixing them would silently render the wrong stages for some.
takeRun : String -> Option String -> Bool -> List String -> List String -> Int -> List String -> <IO> (List String, List String)
takeRun _ _ _ _ _ _ [] = ([], [])
takeRun root outDir forceIsolate cli sel n (f::rest) =
  if n <= 0 then ([], f::rest)
  else
    let meta = metaOf root outDir f
    if forceIsolate || isIsolatedIn meta || stagesIn cli meta != sel then ([], f::rest)
    else
      let (grp, tail2) = takeRun root outDir forceIsolate cli sel (n - 1) rest
      (f::grp, tail2)

-- The fixture's EXISTING snapshot's `# META` lines.  Must consult the same --out
-- directory the run will write to, or a corpus kept out-of-tree would silently never
-- isolate anything (and would never see its own `stages=`).
metaOf : String -> Option String -> String -> <IO> List String
metaOf root outDir f = match readFile (snapPathOf root outDir f)
  Err _ => []
  Ok text => contentLines (sectionOf "META" (parseSnapshot text))

isIsolatedIn : List String -> Bool
isIsolatedIn meta = anyList (l => trimRight l == "isolate=true") meta

-- `--stages` wins (that is how a corpus is CREATED); else the fixture's own `stages=`
-- (so `--check` needs no flag and the file is self-describing); else every stage.
stagesIn : List String -> List String -> List String
stagesIn (s::rest) _ = s::rest
stagesIn [] meta = metaStages meta

-- A malformed `stages=` yields [] == every stage, so the run renders MORE sections than
-- the file holds and `--check` FAILS.  Never the other way round: a corrupt META must
-- not be able to shrink what gets checked.
metaStages : List String -> List String
metaStages [] = []
metaStages (l::rest) =
  if startsWith "stages=" l then match parseStages (drop 7 l)
    Ok ns => ns
    Err _ => []
  else metaStages rest

superviseChunks : String -> SnapMode -> Option String -> List Chunk -> <IO> List SnapResult
superviseChunks _ _ _ [] = []
superviseChunks root mode outDir ((sel, fs)::rest) =
  let here = runChunk root mode outDir sel fs
  here ++ superviseChunks root mode outDir rest

-- Run one chunk in a child.  On a crash: bank every fixture the child COMPLETED, write
-- the crasher's snapshot from the sections it managed to stream plus its stderr, then
-- respawn over what is left of the chunk.
runChunk : String -> SnapMode -> Option String -> List String -> List String -> <IO> List SnapResult
runChunk _ _ _ _ [] = []
runChunk root mode outDir sel pending = match runCommand (executablePath ()) (workerArgv root sel pending)
  Err e => map (f => (f, "ERROR spawn failed: \{e}", False)) pending
  Ok (code, out, err) =>
    let streamed = parseStream out
    let done = map fixtureOf streamed
    let banked = map (settle root mode outDir sel) streamed
    let missing = notIn done pending
    -- COMPLETENESS, not exit code, decides whether the worker survived.  A fixture that
    -- calls `exit 0` kills the worker with a SUCCESS status, so `code == 0` would report
    -- a clean run while silently dropping every fixture after it.  "Every pending fixture
    -- reached its END" is the only claim worth trusting.
    if missing == [] then
      banked
    else
      -- the child died: the last BEGIN with no END names the killer.
      match lastBegun out
        None => banked ++ map (f => (f, "ERROR worker died with no BEGIN (exit \{intToString code})", False)) missing
        Some victim =>
          -- the victim's own snapshot = whatever it streamed before dying + its stderr.
          -- `# CRASH` is a stderr dump, so it is diagnostic BY CONSTRUCTION — which makes
          -- a crashing fixture's snapshot permanently unblessable.  That is intended: the
          -- day a panic message changes, someone reads it.
          let crashSecs = streamTail out ++ [("CRASH", normalizeText root err, True)]
          let (_, v, _) = settle root mode outDir sel (victim, crashSecs)
          let remaining = afterFirst victim pending
          banked ++ [(victim, v, True)] ++ runChunk root mode outDir sel remaining

workerArgv : String -> List String -> List String -> List String
workerArgv root [] files = ["snapshot", "--worker", "--root", root] ++ files
workerArgv root sel files = ["snapshot", "--worker", "--root", root, "--stages", joinWith "," sel]
  ++ files

notIn : List String -> List String -> List String
notIn done xs = filterList (x => not (anyList (== x) done)) xs

afterFirst : String -> List String -> List String
afterFirst _ [] = []
afterFirst victim (x::rest) =
  if x == victim then
    rest
  else
    afterFirst victim rest

-- ── worker-stream decoding ───────────────────────────────────────────────────
-- A fixture reaches the supervisor as (path, [(section, content)]).

-- COMPLETED fixtures only — a fixture is banked when its `END` arrives.  An
-- unterminated trailing fixture is the crash victim and is deliberately NOT returned
-- here; the supervisor picks it up via `streamTail`.  (Returning it from both is what
-- made a crashed fixture get settled twice — written as NEW, then re-settled as SKIP.)
parseStream : String -> List (String, List RunSec)
parseStream out = streamGo (splitNl out) "" [] []

-- PERFORMANCE, and it is not incidental.  Both accumulators below are built NEWEST-FIRST
-- — the open section is the head of `secs`, and its lines are consed onto the head of
-- its own list — then reversed once at the end.  The obvious shape (append the line to
-- the section's string as it arrives) is QUADRATIC in the section's size, because each
-- append copies the whole string built so far.  A single 80,190-line WASM section made
-- that decoder take over ten minutes; consing makes the same input linear.
--
-- `SECD ` is checked BEFORE `SEC ` reads its name, and neither collides with the `D`
-- content prefix (both start `S`), so a content line may still say anything at all.
streamGo : List String -> String -> Sections -> List (String, Sections) -> List (String, List RunSec)
streamGo [] _ _ acc = map settleSecs (reverseL acc)
streamGo (l::rest) cur secs acc
  | startsWith "BEGIN " l = streamGo rest (drop 6 l) [] acc
  | startsWith "END " l = streamGo rest "" [] (flushCur cur secs acc)
  | startsWith "SECD " l = streamGo rest cur ((drop 5 l, True, [])::secs) acc
  | startsWith "SEC " l = streamGo rest cur ((drop 4 l, False, [])::secs) acc
  | startsWith "D" l = streamGo rest cur (pushLine (drop 1 l) secs) acc
  | otherwise = streamGo rest cur secs acc

-- The sections of the fixture that was in flight when the worker died (last BEGIN with
-- no END) — everything it managed to flush before the crash.
streamTail : String -> List RunSec
streamTail out = streamTailGo (splitNl out) "" []

streamTailGo : List String -> String -> Sections -> List RunSec
streamTailGo [] "" _ = []
streamTailGo [] _ secs = closeSecs secs
streamTailGo (l::rest) cur secs
  | startsWith "BEGIN " l = streamTailGo rest (drop 6 l) []
  | startsWith "END " l = streamTailGo rest "" []
  | startsWith "SECD " l = streamTailGo rest cur ((drop 5 l, True, [])::secs)
  | startsWith "SEC " l = streamTailGo rest cur ((drop 4 l, False, [])::secs)
  | startsWith "D" l = streamTailGo rest cur (pushLine (drop 1 l) secs)
  | otherwise = streamTailGo rest cur secs

-- open sections, newest first; each one's lines newest first.
type Sections = List (String, Bool, List String)

pushLine : String -> Sections -> Sections
pushLine _ [] = []
pushLine l ((n, d, ls)::rest) = (n, d, l::ls)::rest

closeSecs : Sections -> List RunSec
closeSecs secs = map closeSec (reverseL secs)

closeSec : (String, Bool, List String) -> RunSec
closeSec (n, d, ls) = (n, blockOf (reverseL ls), d)

settleSecs : (String, Sections) -> (String, List RunSec)
settleSecs (p, secs) = (p, closeSecs secs)

flushCur : String -> Sections -> List (String, Sections) -> List (String, Sections)
flushCur "" _ acc = acc
flushCur cur secs acc = (cur, secs)::acc

fixtureOf : (String, List RunSec) -> String
fixtureOf (p, _) = p

-- the last fixture the worker announced but never finished == the one that killed it.
lastBegun : String -> Option String
lastBegun out = lastBegunGo (splitNl out) None

lastBegunGo : List String -> Option String -> Option String
lastBegunGo [] cur = cur
lastBegunGo (l::rest) cur
  | startsWith "BEGIN " l = lastBegunGo rest (Some (drop 6 l))
  | startsWith "END " l = lastBegunGo rest None
  | otherwise = lastBegunGo rest cur

-- ── snapshot file: assemble / parse / compare ────────────────────────────────

snapPathOf : String -> Option String -> String -> String
snapPathOf _ None f = "\{chopExt f}.md"
snapPathOf _ (Some dir) f = "\{dir}/\{chopExt (baseOf f)}.md"

sectionOf : String -> List (String, String) -> String
sectionOf _ [] = ""
sectionOf n ((k, v)::rest) = if k == n then v else sectionOf n rest

hasSection : String -> List (String, String) -> Bool
hasSection n secs = anyList (== n) (map fst2 secs)

fst2 : (String, String) -> String
fst2 (a, _) = a

-- Assemble in canonical FILE order, skipping sections the run did not produce.  META is
-- SYNTHESIZED here: `source_lines` (which is what makes SOURCE readable back without
-- scanning) plus any authored keys carried over from the existing file.
renderSnapshot : List String -> List (String, String) -> String
renderSnapshot metaExtra secs =
  let src = sectionOf "SOURCE" secs
  let meta = blockOf (["source_lines=\{intToString (length (contentLines src))}"] ++ metaExtra)
  let body = flatMap (n => renderOne n secs) (filterList (!= "META") snapSections)
  stringConcat (["# META\n", meta] ++ body)

renderOne : String -> List (String, String) -> List String
renderOne n secs =
  if hasSection n secs then
    ["# \{n}\n", sectionOf n secs]
  else
    []

-- The META block: the keys the runner MAINTAINS (`source_lines`, `stages`,
-- `diagnostics`) followed by every authored key it does not (e.g. `isolate=true`), which
-- survives a rewrite.
metaLinesFor : List String -> List RunSec -> List String
metaLinesFor sel secs = stagesLine sel
  ++ diagLine (diagNamesOf secs)
  ++ metaExtraOf (secPairs secs)

stagesLine : List String -> List String
stagesLine [] = []
stagesLine sel = ["stages=\{joinWith "," sel}"]

-- `diagnostics=PARSE,TYPES` — the sections of THIS snapshot that hold compiler
-- diagnostic prose, and are therefore not `--bless`-able.  Written by the runner so the
-- fact is visible to a human opening the `.md`, and so the bless refusal also fires on
-- the STORED file (see `blockedDiags`).
diagLine : List String -> List String
diagLine [] = []
diagLine ns = ["diagnostics=\{joinWith "," ns}"]

metaExtraOf : List (String, String) -> List String
metaExtraOf secs =
  filterList isAuthoredMetaLine (contentLines (sectionOf "META" secs))

isAuthoredMetaLine : String -> Bool
isAuthoredMetaLine l = not (startsWith "source_lines=" l)
  && not (startsWith "stages=" l)
  && not (startsWith "diagnostics=" l)

-- The `diagnostics=` names recorded in an EXISTING snapshot's `# META`.
metaDiagsOf : List (String, String) -> List String
metaDiagsOf secs = metaDiagsIn (contentLines (sectionOf "META" secs))

metaDiagsIn : List String -> List String
metaDiagsIn [] = []
metaDiagsIn (l::rest) =
  if startsWith "diagnostics=" l then
    filterList (!= "") (map (s => toUpper (trim s)) (split "," (drop 12 l)))
  else
    metaDiagsIn rest

-- Read a snapshot back.  SOURCE is taken by exact line count from META; every other
-- section is delimited by the header grammar.
export parseSnapshot : String -> List (String, String)
parseSnapshot text =
  let ls = splitNl text
  collectSections ls (metaSourceLines ls)

metaSourceLines : List String -> Int
metaSourceLines [] = 0
metaSourceLines (l::rest) =
  if startsWith "source_lines=" l then match toInt (drop 13 l)
    Some n => n
    None => 0
  else metaSourceLines rest

collectSections : List String -> Int -> List (String, String)
collectSections [] _ = []
collectSections (l::rest) n =
  if isHeaderLine l then
    let name = drop 2 l
    if name == "SOURCE" then
      let (body, tail2) = splitAtN n rest
      ("SOURCE", blockOf body) :: collectSections tail2 n
    else
      let (body, tail2) = untilHeader rest
      (name, blockOf (dropTrailingEmpty body)) :: collectSections tail2 n
  else collectSections rest n

splitAtN : Int -> List String -> (List String, List String)
splitAtN _ [] = ([], [])
splitAtN n (x::rest) =
  if n <= 0 then ([], x::rest)
  else
    let (a, b) = splitAtN (n - 1) rest
    (x::a, b)

untilHeader : List String -> (List String, List String)
untilHeader [] = ([], [])
untilHeader (x::rest) =
  if isHeaderLine x then ([], x::rest)
  else
    let (a, b) = untilHeader rest
    (x::a, b)

-- ── verdicts ─────────────────────────────────────────────────────────────────

-- (path, verdict, crashed?).  `crashed` is tracked out-of-band rather than sniffed
-- back out of the verdict string: a crashed fixture's verdict is an ordinary
-- NEW/PASS/FAIL (its `# CRASH` section is just another section to write or compare),
-- so the fact that it took the worker down with it has nowhere else to live.
type SnapResult = (String, String, Bool)

settle : String -> SnapMode -> Option String -> List String -> (String, List RunSec) -> <IO> SnapResult
settle root mode outDir sel (path, secs) =
  (path, settleVerdict root mode outDir sel path secs, False)

settleVerdict : String -> SnapMode -> Option String -> List String -> String -> List RunSec -> <IO> String
settleVerdict root mode outDir sel path secs =
  match badSections secs
    -- the header-grammar invariant: refuse to write a file that cannot round-trip.
    (n::_) => "FAIL section \{n} contains a line matching the section-header grammar"
    [] =>
      let snapPath = snapPathOf root outDir path
      match readOpt snapPath
        None => verdictMissing mode snapPath sel secs
        Some prev => verdictExisting mode snapPath sel secs prev

-- No snapshot on disk yet.
--   --check  a fixture with no expectation FAILS — never a silent pass.
--   --new    create it.  This is the ONLY path that creates a snapshot.
--   --bless  REFUSE (lock 2).  A bless that can mint an expectation is a stage writing
--            down its own output as correct; that single affordance is what would make
--            the whole corpus worthless.
verdictMissing : SnapMode -> String -> List String -> List RunSec -> <IO> String
verdictMissing SnapCheck snapPath _ _ =
  "FAIL no snapshot (\{snapPath}); run `medaka snapshot --new`"
verdictMissing SnapBless snapPath _ _ = "FAIL no snapshot (\{snapPath}); --bless never creates one — run `medaka snapshot --new` first"
verdictMissing SnapNew snapPath sel secs = match writeSnap snapPath sel secs
  Err e => "ERROR cannot write \{snapPath}: \{e}"
  Ok _ => "NEW \{snapPath}"

verdictExisting : SnapMode -> String -> List String -> List RunSec -> String -> <IO> String
verdictExisting SnapCheck _ _ secs prev = compareSnap prev secs
-- `--new` NEVER overwrites: rewriting an existing snapshot from the current compiler IS
-- blessing, and blessing has a door of its own, with locks on it.
verdictExisting SnapNew snapPath _ _ _ = "SKIP exists (\{snapPath})"
verdictExisting SnapBless snapPath sel secs prev =
  let prevSecs = parseSnapshot prev
  match diffSections prevSecs (secPairs secs)
    -- Nothing to approve.  A bless over an already-matching snapshot writes NOTHING (so
    -- it cannot churn `stat` times or reflow a file nobody asked it to touch).
    [] => "PASS"
    ds => match blockedDiags prevSecs secs ds
      (b::bs) => diagRefusal snapPath (b::bs)
      [] => match writeSnap snapPath sel secs
        Err e => "ERROR cannot write \{snapPath}: \{e}"
        Ok _ => "BLESS \{snapPath} (\{joinWith ", " ds})"

-- The DIFFERING sections that carry diagnostic prose — either in the FRESH render (the
-- worker tagged them at their render site) or in the STORED snapshot (`# META`'s
-- `diagnostics=`).  Both directions count, and the second is the one that matters most:
-- a section that WAS a diagnostic and now is not means a stage quietly stopped reporting
-- an error, which is a worse bug than a reworded message and must not slide through on a
-- clean-looking render.
blockedDiags : List (String, String) -> List RunSec -> List String -> List String
blockedDiags prevSecs secs ds =
  let diags = metaDiagsOf prevSecs ++ diagNamesOf secs
  filterList (n => anyList (== n) diags) ds

-- Lock 3.  Zig ships no bless at all for expected error text, and that is precisely why
-- its diagnostics are good; this repo grades its own against ERROR-QUALITY.md, so an
-- auto-blessable diagnostic golden would let a graded message rot unread.  The escape
-- hatch is deliberately louder than a bless: delete the file and re-cut it, which lands
-- in review as a delete+add.
diagRefusal : String -> List String -> String
diagRefusal snapPath names =
  let what = joinWith ", " names
  let why = "diagnostic text is never auto-blessable (compiler/ERROR-QUALITY.md grades it)."
  let how = "READ the new message; if it is genuinely better, `rm \{snapPath}` and re-cut it with `medaka snapshot --new`."
  "FAIL refusing to bless diagnostic section(s) \{what} in \{snapPath}: \{why} \{how}"

writeSnap : String -> List String -> List RunSec -> <IO> Result String Unit
writeSnap snapPath sel secs =
  writeFile snapPath (renderSnapshot (metaLinesFor sel secs) (secPairs secs))

badSections : List RunSec -> List String
badSections secs =
  map secName (filterList (s => sectionCollides (secBody s)) secs)

compareSnap : String -> List RunSec -> String
compareSnap prev secs = match diffSections (parseSnapshot prev) (secPairs secs)
  [] => "PASS"
  ds => "FAIL differing sections: \{joinWith ", " ds}"

-- Compare only the sections the run actually produced, plus flag any the snapshot has
-- and the run does not (a stage that used to render and now does not is a regression).
diffSections : List (String, String) -> List (String, String) -> List String
diffSections want got =
  let names = filterList (!= "META") snapSections
  filterList (n => sectionOf n want != sectionOf n got) names

readOpt : String -> <IO> Option String
readOpt p = match readFile p
  Err _ => None
  Ok s => Some s

-- ── reporting ────────────────────────────────────────────────────────────────

-- Failures are printed, and so is every BLESS: a rewrite that is not named on stdout is
-- a rewrite nobody reviewed.  (`git diff` is the actual review gate — this is just the
-- receipt.)
reportResults : List SnapResult -> <IO> Bool
reportResults results =
  let bad = filterList (r => isBad (verdictOf r)) results
  let _ = mapUnit printResult (filterList (r => startsWith "BLESS" (verdictOf r)) results)
  let _ = mapUnit printResult bad
  let _ = putStrLn (summaryLine results)
  bad == []

verdictOf : SnapResult -> String
verdictOf (_, v, _) = v

isBad : String -> Bool
isBad v = startsWith "FAIL" v || startsWith "ERROR" v

printResult : SnapResult -> <IO> Unit
printResult (p, v, _) = putStrLn "\{p}: \{v}"

summaryLine : List SnapResult -> String
summaryLine results =
  let n = length results
  let pass = countWith "PASS" results
  let new = countWith "NEW" results
  let bless = countWith "BLESS" results
  let skip = countWith "SKIP" results
  let fail = length (filterList (r => isBad (verdictOf r)) results)
  let crashed = length (filterList crashedOf results)
  "snapshot: \{intToString n} fixtures — \{intToString pass} pass, \{intToString new} new, \{intToString bless} blessed, \{intToString skip} skipped, \{intToString fail} failed, \{intToString crashed} crashed"

countWith : String -> List SnapResult -> Int
countWith p results =
  length (filterList (r => startsWith p (verdictOf r)) results)

-- A crash is RECORDED, not fatal: the fixture still gets a snapshot (with a `# CRASH`
-- section) and an ordinary verdict, so this is the only place the crash is visible.
crashedOf : SnapResult -> Bool
crashedOf (_, _, c) = c

mapUnit : (a -> <IO> Unit) -> List a -> <IO> Unit
mapUnit _ [] = ()
mapUnit f (x::rest) =
  let _ = f x
  mapUnit f rest
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "tokenize" false) (mem "tokenToString" false) (mem "collectComments" false) (mem "Comment" false) (mem "commentLine" false) (mem "commentCol" false) (mem "commentText" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseResult" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false) (mem "parseWithPositions" false) (mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "positionsVariantLines" false) (mem "positionsLastContentLine" false) (mem "declPosLine" false) (mem "declPosEndLine" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "programToString" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "markWithPrelude" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "programToSexp" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" false))))
(DUse false (UseGroup ("ir" "core_ir_lower") ((mem "lowerProgram" false) (mem "lowerProgramEmit" false) (mem "returnsSelfTable" false) (mem "selfFnParamTable" false) (mem "methodIfaceTable" false) (mem "methodConstraintIfaces" false) (mem "ctorFieldTypeNames" false) (mem "declSigTypeNames" false))))
(DUse false (UseGroup ("ir" "core_ir_sexp") ((mem "cprogramToSexp" false))))
(DUse false (UseGroup ("types" "annotate") ((mem "annotateProgram" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "checkToLinesWithRuntime" false) (mem "setCoherenceUserDecls" false) (mem "elaborateOne" false) (mem "elaborateDict" false) (mem "constrainedSigNames" false) (mem "mainTypeIsUnit" false) (mem "mainTypeIsFloat" false) (mem "hadTypeErrors" false) (mem "hadMatchWarnings" false) (mem "resetTypeErrorsSticky" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "evalOneOutput" false) (mem "funNamesOf" false) (mem "dropShadowedExp" false) (mem "noMainMsg" false))))
(DUse false (UseGroup ("backend" "llvm_emit") ((mem "emitProgram" false) (mem "installReturnsSelf" false) (mem "installSelfFnParams" false) (mem "installMethodIface" false) (mem "installMethodConstraintIfaces" false) (mem "installCtorFieldTypes" false) (mem "installDeclSigTypes" false) (mem "installMainIsUnitHint" false) (mem "installMainIsFloatHint" false) (mem "enableGapRecord" false) (mem "resetGaps" false) (mem "gapEvents" false))))
(DUse false (UseGroup ("backend" "wasm_emit") ((mem "emitProgram" false "wasmText") (mem "installDeclRetTypes" false) (mem "installCtorFloatFields" false) (mem "enableGapRecordW" false) (mem "resetGapsW" false) (mem "gapEventsW" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "joinWith" false) (mem "splitNl" false) (mem "startsWith" false) (mem "anyList" false) (mem "reverseL" false) (mem "filterList" false))))
(DUse false (UseGroup ("support" "path") ((mem "chopExt" false) (mem "baseOf" false))))
(DUse false (UseGroup ("string") ((mem "split" false) (mem "replaceAll" false) (mem "trim" false) (mem "trimRight" false) (mem "take" false) (mem "drop" false) (mem "toInt" false) (mem "toFloat" false) (mem "toUpper" false))))
(DTypeSig true "snapSections" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "snapSections" () (EListLit (ELit (LString "META")) (ELit (LString "SOURCE")) (ELit (LString "TOKENS")) (ELit (LString "COMMENTS")) (ELit (LString "POSITIONS")) (ELit (LString "PARSE")) (ELit (LString "PRINTER")) (ELit (LString "DESUGAR")) (ELit (LString "MARK")) (ELit (LString "TYPES")) (ELit (LString "TYPES_USER")) (ELit (LString "CORE_IR")) (ELit (LString "LLVM")) (ELit (LString "WASM")) (ELit (LString "EVAL")) (ELit (LString "CRASH"))))
(DTypeSig true "isHeaderLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHeaderLine" ((PVar "l")) (EApp (EApp (EVar "anyList") (ELam ((PVar "n")) (EBinOp "==" (EVar "l") (EBinOp "++" (EBinOp "++" (ELit (LString "# ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))))) (EVar "snapSections")))
(DTypeSig false "sectionCollides" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "sectionCollides" ((PVar "content")) (EApp (EApp (EVar "anyList") (EVar "isHeaderLine")) (EApp (EVar "splitNl") (EVar "content"))))
(DData Public "SnapMode" () ((variant "SnapCheck" (ConPos)) (variant "SnapNew" (ConPos)) (variant "SnapBless" (ConPos))) ())
(DTypeAlias false "RunSec" () (TyTuple (TyCon "String") (TyCon "String") (TyCon "Bool")))
(DTypeSig false "secName" (TyFun (TyCon "RunSec") (TyCon "String")))
(DFunDef false "secName" ((PTuple (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "secBody" (TyFun (TyCon "RunSec") (TyCon "String")))
(DFunDef false "secBody" ((PTuple PWild (PVar "b") PWild)) (EVar "b"))
(DTypeSig false "secIsDiag" (TyFun (TyCon "RunSec") (TyCon "Bool")))
(DFunDef false "secIsDiag" ((PTuple PWild PWild (PVar "d"))) (EVar "d"))
(DTypeSig false "secPairs" (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "secPairs" ((PVar "secs")) (EApp (EApp (EVar "map") (ELam ((PVar "s")) (ETuple (EApp (EVar "secName") (EVar "s")) (EApp (EVar "secBody") (EVar "s"))))) (EVar "secs")))
(DTypeSig false "diagNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "diagNamesOf" ((PVar "secs")) (EApp (EApp (EVar "map") (EVar "secName")) (EApp (EApp (EVar "filterList") (EVar "secIsDiag")) (EVar "secs"))))
(DTypeSig true "parseStages" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "parseStages" ((PVar "spec")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "!=" (EVar "_s") (ELit (LString ""))))) (EApp (EApp (EVar "map") (ELam ((PVar "s")) (EApp (EVar "toUpper") (EApp (EVar "trim") (EVar "s"))))) (EApp (EApp (EVar "split") (ELit (LString ","))) (EVar "spec"))))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EVar "snapSections"))))) (EVar "names")) (arm (PList) () (EApp (EVar "Ok") (EVar "names"))) (arm (PVar "bad") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "unknown stage(s): ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "bad")))) (ELit (LString " (known: "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "snapSections")))) (ELit (LString ")")))))))))
(DTypeSig false "wants" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "wants" ((PList) PWild) (EVar "True"))
(DFunDef false "wants" ((PVar "sel") (PVar "n")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EVar "sel")))
(DTypeSig false "contentLines" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "contentLines" ((PLit (LString ""))) (EListLit))
(DFunDef false "contentLines" ((PVar "s")) (EApp (EVar "dropTrailingEmpty") (EApp (EVar "splitNl") (EVar "s"))))
(DTypeSig false "dropTrailingEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropTrailingEmpty" ((PList)) (EListLit))
(DFunDef false "dropTrailingEmpty" ((PList (PLit (LString "")))) (EListLit))
(DFunDef false "dropTrailingEmpty" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "dropTrailingEmpty") (EVar "rest"))))
(DTypeSig false "blockOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "blockOf" ((PList)) (ELit (LString "")))
(DFunDef false "blockOf" ((PVar "ls")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "joinNl") (EVar "ls")))) (ELit (LString "\n"))))
(DTypeSig false "isRunSection" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isRunSection" ((PVar "n")) (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "EVAL"))) (EBinOp "==" (EVar "n") (ELit (LString "CRASH")))))
(DTypeSig false "canonText" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "canonText" ((PVar "text")) (EApp (EVar "blockOf") (EApp (EApp (EVar "map") (EVar "trimRight")) (EApp (EVar "contentLines") (EVar "text")))))
(DTypeSig true "normalizeText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "normalizeText" ((PVar "root") (PVar "text")) (EApp (EVar "blockOf") (EApp (EApp (EVar "map") (EApp (EVar "normalizeLine") (EVar "root"))) (EApp (EVar "contentLines") (EVar "text")))))
(DTypeSig false "normalizeLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "normalizeLine" ((PVar "root") (PVar "line")) (EApp (EVar "trimRight") (EApp (EVar "normDurations") (EApp (EVar "normTmp") (EApp (EApp (EApp (EVar "replaceAll") (EVar "root")) (ELit (LString "<ROOT>"))) (EVar "line"))))))
(DTypeSig false "normTmp" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normTmp" ((PVar "line")) (EMatch (EApp (EApp (EVar "split") (EVar "tmpPrefix")) (EVar "line")) (arm (PList) () (EVar "line")) (arm (PList (PVar "only")) () (EVar "only")) (arm (PCons (PVar "first") (PVar "rest")) () (EApp (EApp (EVar "joinWith") (ELit (LString "<TMP>"))) (EBinOp "::" (EVar "first") (EApp (EApp (EVar "map") (EApp (EVar "drop") (ELit (LInt 6)))) (EVar "rest")))))))
(DTypeSig false "tmpPrefix" (TyCon "String"))
(DFunDef false "tmpPrefix" () (ELit (LString "/tmp/medaka_build_")))
(DTypeSig false "normDurations" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normDurations" ((PVar "line")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "durWord")) (EApp (EApp (EVar "split") (ELit (LString " "))) (EVar "line")))))
(DTypeSig false "durWord" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "durWord" ((PVar "w")) (EIf (EApp (EVar "isDuration") (EVar "w")) (ELit (LString "<T>")) (EVar "w")))
(DTypeSig false "isDuration" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDuration" ((PVar "w")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "durBody") (EVar "w"))) (DoExpr (EIf (EBinOp "==" (EVar "body") (ELit (LString ""))) (EVar "False") (EApp (EVar "isNumeric") (EVar "body"))))))
(DTypeSig false "durBody" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "durBody" ((PVar "w")) (EIf (EApp (EApp (EVar "endsWithStr") (ELit (LString "ms"))) (EVar "w")) (EApp (EApp (EVar "take") (EBinOp "-" (EApp (EVar "stringLength") (EVar "w")) (ELit (LInt 2)))) (EVar "w")) (EIf (EApp (EApp (EVar "endsWithStr") (ELit (LString "s"))) (EVar "w")) (EApp (EApp (EVar "take") (EBinOp "-" (EApp (EVar "stringLength") (EVar "w")) (ELit (LInt 1)))) (EVar "w")) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "endsWithStr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "endsWithStr" ((PVar "suf") (PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoLet false false (PVar "m") (EApp (EVar "stringLength") (EVar "suf"))) (DoExpr (EIf (EBinOp ">" (EVar "m") (EVar "n")) (EVar "False") (EBinOp "==" (EApp (EApp (EVar "drop") (EBinOp "-" (EVar "n") (EVar "m"))) (EVar "s")) (EVar "suf"))))))
(DTypeSig false "isNumeric" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isNumeric" ((PVar "s")) (EMatch (EApp (EVar "toInt") (EVar "s")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EMatch (EApp (EVar "toFloat") (EVar "s")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "tokensOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "tokensOf" ((PVar "src")) (EApp (EVar "blockOf") (EApp (EApp (EVar "map") (EVar "tokenToString")) (EApp (EVar "tokenize") (EVar "src")))))
(DTypeSig false "commentsOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "commentsOf" ((PVar "src")) (EApp (EVar "blockOf") (EApp (EApp (EVar "map") (EVar "renderComment")) (EApp (EVar "collectComments") (EVar "src")))))
(DTypeSig false "renderComment" (TyFun (TyCon "Comment") (TyCon "String")))
(DFunDef false "renderComment" ((PVar "c")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "commentLine") (EVar "c"))))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "commentCol") (EVar "c"))))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "escNl") (EApp (EVar "commentText") (EVar "c"))))) (ELit (LString ""))))
(DTypeSig false "escNl" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escNl" ((PVar "s")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "escNlFrom") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0)))))
(DTypeSig false "escNlFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "escNlFrom" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EBinOp "::" (ELit (LString "\\n")) (EApp (EApp (EVar "escNlFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "escNlFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "positionsOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "positionsOf" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositions") (EVar "src")) (arm (PTuple (PVar "_decls") (PVar "pos")) () (EApp (EVar "renderPositions") (EVar "pos")))))
(DTypeSig false "renderPositions" (TyFun (TyCon "Positions") (TyCon "String")))
(DFunDef false "renderPositions" ((PVar "p")) (EBlock (DoLet false false (PVar "decls") (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (EVar "renderDeclPos")) (EApp (EVar "positionsDecls") (EVar "p"))))) (DoLet false false (PVar "vars") (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (EVar "renderVariant")) (EApp (EVar "positionsVariantLines") (EVar "p"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "=== DECLS ===\n")) (EApp (EVar "display") (EVar "decls"))) (ELit (LString "=== VARIANTS ===\n"))) (EApp (EVar "display") (EVar "vars"))) (ELit (LString "=== LASTLINE ===\n"))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "positionsLastContentLine") (EVar "p"))))) (ELit (LString "\n"))))))
(DTypeSig false "renderDeclPos" (TyFun (TyCon "DeclPos") (TyCon "String")))
(DFunDef false "renderDeclPos" ((PVar "d")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "declPosLine") (EVar "d"))))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "declPosEndLine") (EVar "d"))))) (ELit (LString "\n"))))
(DTypeSig false "renderVariant" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "renderVariant" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "\n"))))
(DTypeSig false "parseErrText" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "parseErrText" ((PVar "line") (PVar "col") (PVar "msg")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "parse error at ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString "\n"))))
(DTypeSig false "markOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "markOf" ((PVar "coreDecls") (PVar "d")) (EApp (EVar "programToSexp") (EApp (EApp (EVar "markWithPrelude") (EVar "coreDecls")) (EVar "d"))))
(DTypeSig false "typesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "String") (TyCon "Bool")))))
(DFunDef false "typesOf" ((PVar "runtimeDecls") (PVar "d")) (EBlock (DoLet false false PWild (EApp (EVar "setCoherenceUserDecls") (EVar "d"))) (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "text") (EApp (EApp (EApp (EVar "checkToLinesWithRuntime") (EVar "runtimeDecls")) (EListLit)) (EVar "d"))) (DoExpr (ETuple (EVar "text") (EBinOp "||" (EApp (EVar "hadTypeErrors") (ELit LUnit)) (EApp (EVar "hadMatchWarnings") (ELit LUnit)))))))
(DTypeSig false "typesUserOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "typesUserOf" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "d")) (EBlock (DoLet false false PWild (EApp (EVar "setCoherenceUserDecls") (EVar "d"))) (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "full") (EApp (EApp (EApp (EVar "checkToLinesWithRuntime") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "d"))) (DoLet false false (PVar "diag") (EBinOp "||" (EApp (EVar "hadTypeErrors") (ELit LUnit)) (EApp (EVar "hadMatchWarnings") (ELit LUnit)))) (DoLet false false (PVar "text") (EIf (EApp (EVar "hadTypeErrors") (ELit LUnit)) (EVar "full") (EApp (EVar "blockOf") (EApp (EApp (EVar "filterList") (EApp (EVar "userSchemeLine") (EApp (EVar "funNamesOf") (EVar "d")))) (EApp (EVar "contentLines") (EVar "full")))))) (DoExpr (ETuple (EVar "text") (EVar "diag")))))
(DTypeSig false "userSchemeLine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "userSchemeLine" ((PVar "userNames") (PVar "line")) (EMatch (EApp (EApp (EVar "split") (ELit (LString " : "))) (EVar "line")) (arm (PCons (PVar "nm") (PCons PWild PWild)) () (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "nm")))) (EVar "userNames"))) (arm PWild () (EVar "True"))))
(DTypeSig false "coreIrOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "coreIrOf" ((PVar "d")) (EApp (EVar "cprogramToSexp") (EApp (EVar "lowerProgram") (EApp (EVar "annotateProgram") (EVar "d")))))
(DTypeSig false "evalOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))
(DFunDef false "evalOf" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "d")) (EBlock (DoLet false false (PVar "livePrelude") (EApp (EApp (EVar "dropShadowedExp") (EApp (EVar "funNamesOf") (EVar "d"))) (EVar "coreDecls"))) (DoExpr (EApp (EApp (EVar "evalOneOutput") (EListLit)) (ETuple (ELit (LString "__main__")) (EApp (EApp (EApp (EVar "elaborateOne") (EVar "runtimeDecls")) (EVar "livePrelude")) (ETuple (ELit (LString "__user__")) (EVar "d"))))))))
(DTypeSig false "emitBoth" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "emitBoth" ((PVar "root") (PVar "sel") (PVar "runtimeDecls") (PVar "userDecls")) (EBlock (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (DoLet false false (PVar "dictNames") (EApp (EVar "constrainedSigNames") (EVar "userDecls"))) (DoLet false false (PVar "allDecls") (EApp (EApp (EApp (EApp (EVar "elaborateDict") (EVar "runtimeDecls")) (EVar "dictNames")) (EVar "userNames")) (EVar "userDecls"))) (DoLet false false (PVar "cp") (EApp (EVar "lowerProgramEmit") (EVar "allDecls"))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "LLVM"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "LLVM"))) (EApp (EApp (EApp (EVar "llvmOf") (EVar "runtimeDecls")) (EVar "allDecls")) (EVar "cp"))) (ELit LUnit))) (DoExpr (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "WASM"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "WASM"))) (EApp (EApp (EApp (EVar "wasmOf") (EVar "runtimeDecls")) (EVar "allDecls")) (EVar "cp"))) (ELit LUnit)))))
(DTypeSig false "llvmOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "CProgram") (TyCon "String")))))
(DFunDef false "llvmOf" ((PVar "runtimeDecls") (PVar "allDecls") (PVar "cp")) (EBlock (DoLet false false PWild (EApp (EVar "installReturnsSelf") (EApp (EVar "returnsSelfTable") (EVar "allDecls")))) (DoLet false false PWild (EApp (EVar "installSelfFnParams") (EApp (EVar "selfFnParamTable") (EVar "allDecls")))) (DoLet false false PWild (EApp (EVar "installMethodIface") (EApp (EVar "methodIfaceTable") (EVar "allDecls")))) (DoLet false false PWild (EApp (EVar "installMethodConstraintIfaces") (EApp (EVar "methodConstraintIfaces") (EVar "allDecls")))) (DoLet false false PWild (EApp (EVar "installCtorFieldTypes") (EApp (EVar "ctorFieldTypeNames") (EVar "allDecls")))) (DoLet false false PWild (EApp (EVar "installDeclSigTypes") (EBinOp "++" (EApp (EVar "declSigTypeNames") (EVar "runtimeDecls")) (EApp (EVar "declSigTypeNames") (EVar "allDecls"))))) (DoLet false false PWild (EApp (EVar "installMainIsUnitHint") (EApp (EVar "mainTypeIsUnit") (ELit LUnit)))) (DoLet false false PWild (EApp (EVar "installMainIsFloatHint") (EApp (EVar "mainTypeIsFloat") (ELit LUnit)))) (DoLet false false PWild (EApp (EVar "resetGaps") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "enableGapRecord") (ELit LUnit))) (DoLet false false (PVar "text") (EApp (EVar "emitProgram") (EVar "cp"))) (DoExpr (EApp (EApp (EApp (EVar "withGaps") (ELit (LString ";"))) (EVar "text")) (EApp (EVar "gapEvents") (ELit LUnit))))))
(DTypeSig false "wasmOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "CProgram") (TyCon "String")))))
(DFunDef false "wasmOf" ((PVar "runtimeDecls") (PVar "allDecls") (PVar "cp")) (EBlock (DoLet false false PWild (EApp (EVar "installDeclRetTypes") (EBinOp "++" (EApp (EVar "declSigTypeNames") (EVar "runtimeDecls")) (EApp (EVar "declSigTypeNames") (EVar "allDecls"))))) (DoLet false false PWild (EApp (EVar "installCtorFloatFields") (EApp (EVar "ctorFieldTypeNames") (EVar "allDecls")))) (DoLet false false PWild (EApp (EVar "resetGapsW") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "enableGapRecordW") (ELit LUnit))) (DoLet false false (PVar "text") (EApp (EVar "wasmText") (EVar "cp"))) (DoExpr (EApp (EApp (EApp (EVar "withGaps") (ELit (LString ";;"))) (EVar "text")) (EApp (EVar "gapEventsW") (ELit LUnit))))))
(DTypeSig false "withGaps" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "withGaps" (PWild (PVar "text") (PList)) (EVar "text"))
(DFunDef false "withGaps" ((PVar "cmt") (PVar "text") (PVar "gaps")) (EApp (EVar "blockOf") (EBinOp "++" (EApp (EVar "contentLines") (EVar "text")) (EApp (EApp (EVar "map") (ELam ((PVar "g")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "cmt"))) (ELit (LString " GAP: "))) (EApp (EVar "display") (EVar "g"))) (ELit (LString ""))))) (EVar "gaps")))))
(DTypeSig false "putLineFlush" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "putLineFlush" ((PVar "s")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "s"))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "emitSection" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitSection" ((PVar "root") (PVar "name") (PVar "content")) (EApp (EApp (EApp (EApp (EVar "emitSectionTagged") (EVar "root")) (EVar "name")) (EVar "content")) (EVar "False")))
(DTypeSig false "emitDiagSection" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitDiagSection" ((PVar "root") (PVar "name") (PVar "content")) (EApp (EApp (EApp (EApp (EVar "emitSectionTagged") (EVar "root")) (EVar "name")) (EVar "content")) (EVar "True")))
(DTypeSig false "emitSectionTagged" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "emitSectionTagged" ((PVar "root") (PVar "name") (PVar "content") (PVar "diag")) (EApp (EApp (EApp (EVar "emitRawTagged") (EVar "name")) (EIf (EApp (EVar "isRunSection") (EVar "name")) (EApp (EApp (EVar "normalizeText") (EVar "root")) (EVar "content")) (EApp (EVar "canonText") (EVar "content")))) (EVar "diag")))
(DTypeSig false "emitRaw" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitRaw" ((PVar "name") (PVar "content")) (EApp (EApp (EApp (EVar "emitRawTagged") (EVar "name")) (EVar "content")) (EVar "False")))
(DTypeSig false "emitRawTagged" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitRawTagged" ((PVar "name") (PVar "content") (PVar "diag")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EIf (EVar "diag") (EBinOp "++" (EBinOp "++" (ELit (LString "SECD ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "SEC ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "encodeLines") (EApp (EVar "contentLines") (EVar "content"))))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "encodeLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "encodeLines" ((PVar "ls")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (ELam ((PVar "l")) (EBinOp "++" (EBinOp "++" (ELit (LString "D")) (EApp (EVar "display") (EVar "l"))) (ELit (LString "\n"))))) (EVar "ls"))))
(DTypeSig true "runSnapshotWorker" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "runSnapshotWorker" ((PVar "root") (PVar "sel") (PVar "files")) (EMatch (EApp (EVar "loadPrelude") (EVar "root")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PTuple (PVar "runtimeDecls") (PVar "coreDecls"))) () (EApp (EApp (EApp (EApp (EApp (EVar "workerLoop") (EVar "root")) (EVar "sel")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "files")))))
(DTypeSig false "loadPrelude" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "loadPrelude" ((PVar "root")) (EMatch (EApp (EVar "readFile") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/stdlib/runtime.mdk")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "snapshot: cannot read stdlib/runtime.mdk: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/stdlib/core.mdk")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "snapshot: cannot read stdlib/core.mdk: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "parseResult") (EVar "rsrc")) (arm (PCon "Err" PWild) () (EApp (EVar "Err") (ELit (LString "snapshot: stdlib/runtime.mdk does not parse")))) (arm (PCon "Ok" (PVar "rd")) () (EMatch (EApp (EVar "parseResult") (EVar "csrc")) (arm (PCon "Err" PWild) () (EApp (EVar "Err") (ELit (LString "snapshot: stdlib/core.mdk does not parse")))) (arm (PCon "Ok" (PVar "cd")) () (EApp (EVar "Ok") (ETuple (EApp (EVar "desugar") (EVar "rd")) (EApp (EVar "desugar") (EVar "cd")))))))))))))
(DTypeSig false "workerLoop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "workerLoop" (PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "workerLoop" ((PVar "root") (PVar "sel") (PVar "runtimeDecls") (PVar "coreDecls") (PCons (PVar "f") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "workerOne") (EVar "root")) (EVar "sel")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "workerLoop") (EVar "root")) (EVar "sel")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "rest")))))
(DTypeSig false "workerOne" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "workerOne" ((PVar "root") (PVar "sel") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "path")) (EBlock (DoLet false false PWild (EApp (EVar "putLineFlush") (EBinOp "++" (EBinOp "++" (ELit (LString "BEGIN ")) (EApp (EVar "display") (EVar "path"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "workerRender") (EVar "root")) (EVar "sel")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "path"))) (DoExpr (EApp (EVar "putLineFlush") (EBinOp "++" (EBinOp "++" (ELit (LString "END ")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "")))))))
(DTypeSig false "workerRender" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "workerRender" ((PVar "root") (PVar "sel") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "msg")) () (EApp (EApp (EApp (EVar "emitDiagSection") (EVar "root")) (ELit (LString "CRASH"))) (EBinOp "++" (EBinOp "++" (ELit (LString "cannot read fixture: ")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString "\n"))))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "emitRaw") (ELit (LString "SOURCE"))) (EVar "src"))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "TOKENS"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "TOKENS"))) (EApp (EVar "tokensOf") (EVar "src"))) (ELit LUnit))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "COMMENTS"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "COMMENTS"))) (EApp (EVar "commentsOf") (EVar "src"))) (ELit LUnit))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "POSITIONS"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "POSITIONS"))) (EApp (EVar "positionsOf") (EVar "src"))) (ELit LUnit))) (DoExpr (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "emitDiagSection") (EVar "root")) (ELit (LString "PARSE"))) (EApp (EApp (EApp (EVar "parseErrText") (EApp (EVar "parseErrorLine") (EVar "e"))) (EApp (EVar "parseErrorCol") (EVar "e"))) (EApp (EVar "parseErrorMessage") (EVar "e"))))) (arm (PCon "Ok" (PVar "decls")) () (EApp (EApp (EApp (EApp (EApp (EVar "workerStages") (EVar "root")) (EVar "sel")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "decls")))))))))
(DTypeSig false "workerStages" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "workerStages" ((PVar "root") (PVar "sel") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "decls")) (EBlock (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "PARSE"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "PARSE"))) (EApp (EVar "programToSexp") (EVar "decls"))) (ELit LUnit))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "PRINTER"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "PRINTER"))) (EApp (EVar "programToString") (EVar "decls"))) (ELit LUnit))) (DoLet false false (PVar "d") (EApp (EVar "desugar") (EVar "decls"))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "DESUGAR"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "DESUGAR"))) (EApp (EVar "programToSexp") (EVar "d"))) (ELit LUnit))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "MARK"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "MARK"))) (EApp (EApp (EVar "markOf") (EVar "coreDecls")) (EVar "d"))) (ELit LUnit))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "TYPES"))) (EApp (EApp (EApp (EVar "emitTypes") (EVar "root")) (EVar "runtimeDecls")) (EVar "d")) (ELit LUnit))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "TYPES_USER"))) (EApp (EApp (EApp (EApp (EVar "emitTypesUser") (EVar "root")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "d")) (ELit LUnit))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "CORE_IR"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "CORE_IR"))) (EApp (EVar "coreIrOf") (EVar "d"))) (ELit LUnit))) (DoExpr (EIf (EApp (EVar "hasMain") (EVar "d")) (EBlock (DoLet false false PWild (EIf (EBinOp "||" (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "LLVM"))) (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "WASM")))) (EApp (EApp (EApp (EApp (EVar "emitBoth") (EVar "root")) (EVar "sel")) (EVar "runtimeDecls")) (EVar "d")) (ELit LUnit))) (DoExpr (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "EVAL"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "EVAL"))) (EApp (EApp (EApp (EVar "evalOf") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "d"))) (ELit LUnit)))) (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "EVAL"))) (EApp (EApp (EApp (EVar "emitDiagSection") (EVar "root")) (ELit (LString "CRASH"))) (EBinOp "++" (EBinOp "++" (ELit (LString ":0:0: runtime error [E-NO-MAIN]: ")) (EApp (EVar "display") (EVar "noMainMsg"))) (ELit (LString "\n")))) (ELit LUnit))))))
(DTypeSig false "emitTypes" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitTypes" ((PVar "root") (PVar "runtimeDecls") (PVar "d")) (EBlock (DoLet false false (PTuple (PVar "text") (PVar "diag")) (EApp (EApp (EVar "typesOf") (EVar "runtimeDecls")) (EVar "d"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "emitSectionTagged") (EVar "root")) (ELit (LString "TYPES"))) (EVar "text")) (EVar "diag")))))
(DTypeSig false "emitTypesUser" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "emitTypesUser" ((PVar "root") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "d")) (EBlock (DoLet false false (PTuple (PVar "text") (PVar "diag")) (EApp (EApp (EApp (EVar "typesUserOf") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "d"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "emitSectionTagged") (EVar "root")) (ELit (LString "TYPES_USER"))) (EVar "text")) (EVar "diag")))))
(DTypeSig false "hasMain" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasMain" ((PVar "d")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (ELit (LString "main"))))) (EApp (EVar "funNamesOf") (EVar "d"))))
(DTypeSig false "chunkSize" (TyCon "Int"))
(DFunDef false "chunkSize" () (ELit (LInt 25)))
(DTypeAlias false "Chunk" () (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DTypeSig true "runSnapshotSupervisor" (TyFun (TyCon "String") (TyFun (TyCon "SnapMode") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runSnapshotSupervisor" ((PVar "root") (PVar "mode") (PVar "forceIsolate") (PVar "outDir") (PVar "cli") (PVar "files")) (EBlock (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EVar "superviseChunks") (EVar "root")) (EVar "mode")) (EVar "outDir")) (EApp (EApp (EApp (EApp (EApp (EVar "chunksOf") (EVar "root")) (EVar "outDir")) (EVar "forceIsolate")) (EVar "cli")) (EVar "files")))) (DoExpr (EApp (EVar "reportResults") (EVar "results")))))
(DTypeSig false "chunksOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Chunk")))))))))
(DFunDef false "chunksOf" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "chunksOf" ((PVar "root") (PVar "outDir") (PVar "forceIsolate") (PVar "cli") (PCons (PVar "f") (PVar "rest"))) (EBlock (DoLet false false (PVar "meta") (EApp (EApp (EApp (EVar "metaOf") (EVar "root")) (EVar "outDir")) (EVar "f"))) (DoLet false false (PVar "sel") (EApp (EApp (EVar "stagesIn") (EVar "cli")) (EVar "meta"))) (DoExpr (EIf (EBinOp "||" (EVar "forceIsolate") (EApp (EVar "isIsolatedIn") (EVar "meta"))) (EBinOp "::" (ETuple (EVar "sel") (EListLit (EVar "f"))) (EApp (EApp (EApp (EApp (EApp (EVar "chunksOf") (EVar "root")) (EVar "outDir")) (EVar "forceIsolate")) (EVar "cli")) (EVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "grp") (PVar "tail2")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "takeRun") (EVar "root")) (EVar "outDir")) (EVar "forceIsolate")) (EVar "cli")) (EVar "sel")) (EBinOp "-" (EVar "chunkSize") (ELit (LInt 1)))) (EVar "rest"))) (DoExpr (EBinOp "::" (ETuple (EVar "sel") (EBinOp "::" (EVar "f") (EVar "grp"))) (EApp (EApp (EApp (EApp (EApp (EVar "chunksOf") (EVar "root")) (EVar "outDir")) (EVar "forceIsolate")) (EVar "cli")) (EVar "tail2")))))))))
(DTypeSig false "takeRun" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))))))
(DFunDef false "takeRun" (PWild PWild PWild PWild PWild PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "takeRun" ((PVar "root") (PVar "outDir") (PVar "forceIsolate") (PVar "cli") (PVar "sel") (PVar "n") (PCons (PVar "f") (PVar "rest"))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ETuple (EListLit) (EBinOp "::" (EVar "f") (EVar "rest"))) (EBlock (DoLet false false (PVar "meta") (EApp (EApp (EApp (EVar "metaOf") (EVar "root")) (EVar "outDir")) (EVar "f"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EVar "forceIsolate") (EApp (EVar "isIsolatedIn") (EVar "meta"))) (EBinOp "!=" (EApp (EApp (EVar "stagesIn") (EVar "cli")) (EVar "meta")) (EVar "sel"))) (ETuple (EListLit) (EBinOp "::" (EVar "f") (EVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "grp") (PVar "tail2")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "takeRun") (EVar "root")) (EVar "outDir")) (EVar "forceIsolate")) (EVar "cli")) (EVar "sel")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "f") (EVar "grp")) (EVar "tail2")))))))))
(DTypeSig false "metaOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "metaOf" ((PVar "root") (PVar "outDir") (PVar "f")) (EMatch (EApp (EVar "readFile") (EApp (EApp (EApp (EVar "snapPathOf") (EVar "root")) (EVar "outDir")) (EVar "f"))) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "text")) () (EApp (EVar "contentLines") (EApp (EApp (EVar "sectionOf") (ELit (LString "META"))) (EApp (EVar "parseSnapshot") (EVar "text")))))))
(DTypeSig false "isIsolatedIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isIsolatedIn" ((PVar "meta")) (EApp (EApp (EVar "anyList") (ELam ((PVar "l")) (EBinOp "==" (EApp (EVar "trimRight") (EVar "l")) (ELit (LString "isolate=true"))))) (EVar "meta")))
(DTypeSig false "stagesIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "stagesIn" ((PCons (PVar "s") (PVar "rest")) PWild) (EBinOp "::" (EVar "s") (EVar "rest")))
(DFunDef false "stagesIn" ((PList) (PVar "meta")) (EApp (EVar "metaStages") (EVar "meta")))
(DTypeSig false "metaStages" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "metaStages" ((PList)) (EListLit))
(DFunDef false "metaStages" ((PCons (PVar "l") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "stages="))) (EVar "l")) (EMatch (EApp (EVar "parseStages") (EApp (EApp (EVar "drop") (ELit (LInt 7))) (EVar "l"))) (arm (PCon "Ok" (PVar "ns")) () (EVar "ns")) (arm (PCon "Err" PWild) () (EListLit))) (EApp (EVar "metaStages") (EVar "rest"))))
(DTypeSig false "superviseChunks" (TyFun (TyCon "String") (TyFun (TyCon "SnapMode") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "SnapResult"))))))))
(DFunDef false "superviseChunks" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "superviseChunks" ((PVar "root") (PVar "mode") (PVar "outDir") (PCons (PTuple (PVar "sel") (PVar "fs")) (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EApp (EApp (EApp (EApp (EApp (EVar "runChunk") (EVar "root")) (EVar "mode")) (EVar "outDir")) (EVar "sel")) (EVar "fs"))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EApp (EApp (EVar "superviseChunks") (EVar "root")) (EVar "mode")) (EVar "outDir")) (EVar "rest"))))))
(DTypeSig false "runChunk" (TyFun (TyCon "String") (TyFun (TyCon "SnapMode") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "SnapResult")))))))))
(DFunDef false "runChunk" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "runChunk" ((PVar "root") (PVar "mode") (PVar "outDir") (PVar "sel") (PVar "pending")) (EMatch (EApp (EApp (EVar "runCommand") (EApp (EVar "executablePath") (ELit LUnit))) (EApp (EApp (EApp (EVar "workerArgv") (EVar "root")) (EVar "sel")) (EVar "pending"))) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EVar "map") (ELam ((PVar "f")) (ETuple (EVar "f") (EBinOp "++" (EBinOp "++" (ELit (LString "ERROR spawn failed: ")) (EApp (EVar "display") (EVar "e"))) (ELit (LString ""))) (EVar "False")))) (EVar "pending"))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "streamed") (EApp (EVar "parseStream") (EVar "out"))) (DoLet false false (PVar "done") (EApp (EApp (EVar "map") (EVar "fixtureOf")) (EVar "streamed"))) (DoLet false false (PVar "banked") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "settle") (EVar "root")) (EVar "mode")) (EVar "outDir")) (EVar "sel"))) (EVar "streamed"))) (DoLet false false (PVar "missing") (EApp (EApp (EVar "notIn") (EVar "done")) (EVar "pending"))) (DoExpr (EIf (EBinOp "==" (EVar "missing") (EListLit)) (EVar "banked") (EMatch (EApp (EVar "lastBegun") (EVar "out")) (arm (PCon "None") () (EBinOp "++" (EVar "banked") (EApp (EApp (EVar "map") (ELam ((PVar "f")) (ETuple (EVar "f") (EBinOp "++" (EBinOp "++" (ELit (LString "ERROR worker died with no BEGIN (exit ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ")"))) (EVar "False")))) (EVar "missing")))) (arm (PCon "Some" (PVar "victim")) () (EBlock (DoLet false false (PVar "crashSecs") (EBinOp "++" (EApp (EVar "streamTail") (EVar "out")) (EListLit (ETuple (ELit (LString "CRASH")) (EApp (EApp (EVar "normalizeText") (EVar "root")) (EVar "err")) (EVar "True"))))) (DoLet false false (PTuple PWild (PVar "v") PWild) (EApp (EApp (EApp (EApp (EApp (EVar "settle") (EVar "root")) (EVar "mode")) (EVar "outDir")) (EVar "sel")) (ETuple (EVar "victim") (EVar "crashSecs")))) (DoLet false false (PVar "remaining") (EApp (EApp (EVar "afterFirst") (EVar "victim")) (EVar "pending"))) (DoExpr (EBinOp "++" (EBinOp "++" (EVar "banked") (EListLit (ETuple (EVar "victim") (EVar "v") (EVar "True")))) (EApp (EApp (EApp (EApp (EApp (EVar "runChunk") (EVar "root")) (EVar "mode")) (EVar "outDir")) (EVar "sel")) (EVar "remaining")))))))))))))
(DTypeSig false "workerArgv" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "workerArgv" ((PVar "root") (PList) (PVar "files")) (EBinOp "++" (EListLit (ELit (LString "snapshot")) (ELit (LString "--worker")) (ELit (LString "--root")) (EVar "root")) (EVar "files")))
(DFunDef false "workerArgv" ((PVar "root") (PVar "sel") (PVar "files")) (EBinOp "++" (EListLit (ELit (LString "snapshot")) (ELit (LString "--worker")) (ELit (LString "--root")) (EVar "root") (ELit (LString "--stages")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "sel"))) (EVar "files")))
(DTypeSig false "notIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "notIn" ((PVar "done") (PVar "xs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "x")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "x")))) (EVar "done"))))) (EVar "xs")))
(DTypeSig false "afterFirst" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "afterFirst" (PWild (PList)) (EListLit))
(DFunDef false "afterFirst" ((PVar "victim") (PCons (PVar "x") (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EVar "victim")) (EVar "rest") (EApp (EApp (EVar "afterFirst") (EVar "victim")) (EVar "rest"))))
(DTypeSig false "parseStream" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "RunSec"))))))
(DFunDef false "parseStream" ((PVar "out")) (EApp (EApp (EApp (EApp (EVar "streamGo") (EApp (EVar "splitNl") (EVar "out"))) (ELit (LString ""))) (EListLit)) (EListLit)))
(DTypeSig false "streamGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Sections") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Sections"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "RunSec")))))))))
(DFunDef false "streamGo" ((PList) PWild PWild (PVar "acc")) (EApp (EApp (EVar "map") (EVar "settleSecs")) (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "streamGo" ((PCons (PVar "l") (PVar "rest")) (PVar "cur") (PVar "secs") (PVar "acc")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "BEGIN "))) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "streamGo") (EVar "rest")) (EApp (EApp (EVar "drop") (ELit (LInt 6))) (EVar "l"))) (EListLit)) (EVar "acc")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "END "))) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "streamGo") (EVar "rest")) (ELit (LString ""))) (EListLit)) (EApp (EApp (EApp (EVar "flushCur") (EVar "cur")) (EVar "secs")) (EVar "acc"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "SECD "))) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "streamGo") (EVar "rest")) (EVar "cur")) (EBinOp "::" (ETuple (EApp (EApp (EVar "drop") (ELit (LInt 5))) (EVar "l")) (EVar "True") (EListLit)) (EVar "secs"))) (EVar "acc")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "SEC "))) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "streamGo") (EVar "rest")) (EVar "cur")) (EBinOp "::" (ETuple (EApp (EApp (EVar "drop") (ELit (LInt 4))) (EVar "l")) (EVar "False") (EListLit)) (EVar "secs"))) (EVar "acc")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "D"))) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "streamGo") (EVar "rest")) (EVar "cur")) (EApp (EApp (EVar "pushLine") (EApp (EApp (EVar "drop") (ELit (LInt 1))) (EVar "l"))) (EVar "secs"))) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "streamGo") (EVar "rest")) (EVar "cur")) (EVar "secs")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "streamTail" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RunSec"))))
(DFunDef false "streamTail" ((PVar "out")) (EApp (EApp (EApp (EVar "streamTailGo") (EApp (EVar "splitNl") (EVar "out"))) (ELit (LString ""))) (EListLit)))
(DTypeSig false "streamTailGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Sections") (TyApp (TyCon "List") (TyCon "RunSec"))))))
(DFunDef false "streamTailGo" ((PList) (PLit (LString "")) PWild) (EListLit))
(DFunDef false "streamTailGo" ((PList) PWild (PVar "secs")) (EApp (EVar "closeSecs") (EVar "secs")))
(DFunDef false "streamTailGo" ((PCons (PVar "l") (PVar "rest")) (PVar "cur") (PVar "secs")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "BEGIN "))) (EVar "l")) (EApp (EApp (EApp (EVar "streamTailGo") (EVar "rest")) (EApp (EApp (EVar "drop") (ELit (LInt 6))) (EVar "l"))) (EListLit)) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "END "))) (EVar "l")) (EApp (EApp (EApp (EVar "streamTailGo") (EVar "rest")) (ELit (LString ""))) (EListLit)) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "SECD "))) (EVar "l")) (EApp (EApp (EApp (EVar "streamTailGo") (EVar "rest")) (EVar "cur")) (EBinOp "::" (ETuple (EApp (EApp (EVar "drop") (ELit (LInt 5))) (EVar "l")) (EVar "True") (EListLit)) (EVar "secs"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "SEC "))) (EVar "l")) (EApp (EApp (EApp (EVar "streamTailGo") (EVar "rest")) (EVar "cur")) (EBinOp "::" (ETuple (EApp (EApp (EVar "drop") (ELit (LInt 4))) (EVar "l")) (EVar "False") (EListLit)) (EVar "secs"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "D"))) (EVar "l")) (EApp (EApp (EApp (EVar "streamTailGo") (EVar "rest")) (EVar "cur")) (EApp (EApp (EVar "pushLine") (EApp (EApp (EVar "drop") (ELit (LInt 1))) (EVar "l"))) (EVar "secs"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "streamTailGo") (EVar "rest")) (EVar "cur")) (EVar "secs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeAlias false "Sections" () (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")))))
(DTypeSig false "pushLine" (TyFun (TyCon "String") (TyFun (TyCon "Sections") (TyCon "Sections"))))
(DFunDef false "pushLine" (PWild (PList)) (EListLit))
(DFunDef false "pushLine" ((PVar "l") (PCons (PTuple (PVar "n") (PVar "d") (PVar "ls")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EVar "d") (EBinOp "::" (EVar "l") (EVar "ls"))) (EVar "rest")))
(DTypeSig false "closeSecs" (TyFun (TyCon "Sections") (TyApp (TyCon "List") (TyCon "RunSec"))))
(DFunDef false "closeSecs" ((PVar "secs")) (EApp (EApp (EVar "map") (EVar "closeSec")) (EApp (EVar "reverseL") (EVar "secs"))))
(DTypeSig false "closeSec" (TyFun (TyTuple (TyCon "String") (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "RunSec")))
(DFunDef false "closeSec" ((PTuple (PVar "n") (PVar "d") (PVar "ls"))) (ETuple (EVar "n") (EApp (EVar "blockOf") (EApp (EVar "reverseL") (EVar "ls"))) (EVar "d")))
(DTypeSig false "settleSecs" (TyFun (TyTuple (TyCon "String") (TyCon "Sections")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "RunSec")))))
(DFunDef false "settleSecs" ((PTuple (PVar "p") (PVar "secs"))) (ETuple (EVar "p") (EApp (EVar "closeSecs") (EVar "secs"))))
(DTypeSig false "flushCur" (TyFun (TyCon "String") (TyFun (TyCon "Sections") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Sections"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Sections")))))))
(DFunDef false "flushCur" ((PLit (LString "")) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "flushCur" ((PVar "cur") (PVar "secs") (PVar "acc")) (EBinOp "::" (ETuple (EVar "cur") (EVar "secs")) (EVar "acc")))
(DTypeSig false "fixtureOf" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "RunSec"))) (TyCon "String")))
(DFunDef false "fixtureOf" ((PTuple (PVar "p") PWild)) (EVar "p"))
(DTypeSig false "lastBegun" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "lastBegun" ((PVar "out")) (EApp (EApp (EVar "lastBegunGo") (EApp (EVar "splitNl") (EVar "out"))) (EVar "None")))
(DTypeSig false "lastBegunGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lastBegunGo" ((PList) (PVar "cur")) (EVar "cur"))
(DFunDef false "lastBegunGo" ((PCons (PVar "l") (PVar "rest")) (PVar "cur")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "BEGIN "))) (EVar "l")) (EApp (EApp (EVar "lastBegunGo") (EVar "rest")) (EApp (EVar "Some") (EApp (EApp (EVar "drop") (ELit (LInt 6))) (EVar "l")))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "END "))) (EVar "l")) (EApp (EApp (EVar "lastBegunGo") (EVar "rest")) (EVar "None")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lastBegunGo") (EVar "rest")) (EVar "cur")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "snapPathOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "snapPathOf" (PWild (PCon "None") (PVar "f")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "chopExt") (EVar "f")))) (ELit (LString ".md"))))
(DFunDef false "snapPathOf" (PWild (PCon "Some" (PVar "dir")) (PVar "f")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EVar "display") (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "f"))))) (ELit (LString ".md"))))
(DTypeSig false "sectionOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "String"))))
(DFunDef false "sectionOf" (PWild (PList)) (ELit (LString "")))
(DFunDef false "sectionOf" ((PVar "n") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EVar "v") (EApp (EApp (EVar "sectionOf") (EVar "n")) (EVar "rest"))))
(DTypeSig false "hasSection" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "hasSection" ((PVar "n") (PVar "secs")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EApp (EApp (EVar "map") (EVar "fst2")) (EVar "secs"))))
(DTypeSig false "fst2" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "fst2" ((PTuple (PVar "a") PWild)) (EVar "a"))
(DTypeSig false "renderSnapshot" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "String"))))
(DFunDef false "renderSnapshot" ((PVar "metaExtra") (PVar "secs")) (EBlock (DoLet false false (PVar "src") (EApp (EApp (EVar "sectionOf") (ELit (LString "SOURCE"))) (EVar "secs"))) (DoLet false false (PVar "meta") (EApp (EVar "blockOf") (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "source_lines=")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "length") (EApp (EVar "contentLines") (EVar "src")))))) (ELit (LString "")))) (EVar "metaExtra")))) (DoLet false false (PVar "body") (EApp (EApp (EVar "flatMap") (ELam ((PVar "n")) (EApp (EApp (EVar "renderOne") (EVar "n")) (EVar "secs")))) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "!=" (EVar "_s") (ELit (LString "META"))))) (EVar "snapSections")))) (DoExpr (EApp (EVar "stringConcat") (EBinOp "++" (EListLit (ELit (LString "# META\n")) (EVar "meta")) (EVar "body"))))))
(DTypeSig false "renderOne" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "renderOne" ((PVar "n") (PVar "secs")) (EIf (EApp (EApp (EVar "hasSection") (EVar "n")) (EVar "secs")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "# ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "\n"))) (EApp (EApp (EVar "sectionOf") (EVar "n")) (EVar "secs"))) (EListLit)))
(DTypeSig false "metaLinesFor" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "metaLinesFor" ((PVar "sel") (PVar "secs")) (EBinOp "++" (EBinOp "++" (EApp (EVar "stagesLine") (EVar "sel")) (EApp (EVar "diagLine") (EApp (EVar "diagNamesOf") (EVar "secs")))) (EApp (EVar "metaExtraOf") (EApp (EVar "secPairs") (EVar "secs")))))
(DTypeSig false "stagesLine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stagesLine" ((PList)) (EListLit))
(DFunDef false "stagesLine" ((PVar "sel")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "stages=")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "sel")))) (ELit (LString "")))))
(DTypeSig false "diagLine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "diagLine" ((PList)) (EListLit))
(DFunDef false "diagLine" ((PVar "ns")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "diagnostics=")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "ns")))) (ELit (LString "")))))
(DTypeSig false "metaExtraOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "metaExtraOf" ((PVar "secs")) (EApp (EApp (EVar "filterList") (EVar "isAuthoredMetaLine")) (EApp (EVar "contentLines") (EApp (EApp (EVar "sectionOf") (ELit (LString "META"))) (EVar "secs")))))
(DTypeSig false "isAuthoredMetaLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isAuthoredMetaLine" ((PVar "l")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "source_lines="))) (EVar "l"))) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "stages="))) (EVar "l")))) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "diagnostics="))) (EVar "l")))))
(DTypeSig false "metaDiagsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "metaDiagsOf" ((PVar "secs")) (EApp (EVar "metaDiagsIn") (EApp (EVar "contentLines") (EApp (EApp (EVar "sectionOf") (ELit (LString "META"))) (EVar "secs")))))
(DTypeSig false "metaDiagsIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "metaDiagsIn" ((PList)) (EListLit))
(DFunDef false "metaDiagsIn" ((PCons (PVar "l") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "diagnostics="))) (EVar "l")) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "!=" (EVar "_s") (ELit (LString ""))))) (EApp (EApp (EVar "map") (ELam ((PVar "s")) (EApp (EVar "toUpper") (EApp (EVar "trim") (EVar "s"))))) (EApp (EApp (EVar "split") (ELit (LString ","))) (EApp (EApp (EVar "drop") (ELit (LInt 12))) (EVar "l"))))) (EApp (EVar "metaDiagsIn") (EVar "rest"))))
(DTypeSig true "parseSnapshot" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "parseSnapshot" ((PVar "text")) (EBlock (DoLet false false (PVar "ls") (EApp (EVar "splitNl") (EVar "text"))) (DoExpr (EApp (EApp (EVar "collectSections") (EVar "ls")) (EApp (EVar "metaSourceLines") (EVar "ls"))))))
(DTypeSig false "metaSourceLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))
(DFunDef false "metaSourceLines" ((PList)) (ELit (LInt 0)))
(DFunDef false "metaSourceLines" ((PCons (PVar "l") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "source_lines="))) (EVar "l")) (EMatch (EApp (EVar "toInt") (EApp (EApp (EVar "drop") (ELit (LInt 13))) (EVar "l"))) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (ELit (LInt 0)))) (EApp (EVar "metaSourceLines") (EVar "rest"))))
(DTypeSig false "collectSections" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "collectSections" ((PList) PWild) (EListLit))
(DFunDef false "collectSections" ((PCons (PVar "l") (PVar "rest")) (PVar "n")) (EIf (EApp (EVar "isHeaderLine") (EVar "l")) (EBlock (DoLet false false (PVar "name") (EApp (EApp (EVar "drop") (ELit (LInt 2))) (EVar "l"))) (DoExpr (EIf (EBinOp "==" (EVar "name") (ELit (LString "SOURCE"))) (EBlock (DoLet false false (PTuple (PVar "body") (PVar "tail2")) (EApp (EApp (EVar "splitAtN") (EVar "n")) (EVar "rest"))) (DoExpr (EBinOp "::" (ETuple (ELit (LString "SOURCE")) (EApp (EVar "blockOf") (EVar "body"))) (EApp (EApp (EVar "collectSections") (EVar "tail2")) (EVar "n"))))) (EBlock (DoLet false false (PTuple (PVar "body") (PVar "tail2")) (EApp (EVar "untilHeader") (EVar "rest"))) (DoExpr (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "blockOf") (EApp (EVar "dropTrailingEmpty") (EVar "body")))) (EApp (EApp (EVar "collectSections") (EVar "tail2")) (EVar "n")))))))) (EApp (EApp (EVar "collectSections") (EVar "rest")) (EVar "n"))))
(DTypeSig false "splitAtN" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "splitAtN" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "splitAtN" ((PVar "n") (PCons (PVar "x") (PVar "rest"))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ETuple (EListLit) (EBinOp "::" (EVar "x") (EVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EApp (EVar "splitAtN") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "x") (EVar "a")) (EVar "b"))))))
(DTypeSig false "untilHeader" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "untilHeader" ((PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "untilHeader" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EVar "isHeaderLine") (EVar "x")) (ETuple (EListLit) (EBinOp "::" (EVar "x") (EVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EVar "untilHeader") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "x") (EVar "a")) (EVar "b"))))))
(DTypeAlias false "SnapResult" () (TyTuple (TyCon "String") (TyCon "String") (TyCon "Bool")))
(DTypeSig false "settle" (TyFun (TyCon "String") (TyFun (TyCon "SnapMode") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "RunSec"))) (TyEffect ("IO") None (TyCon "SnapResult"))))))))
(DFunDef false "settle" ((PVar "root") (PVar "mode") (PVar "outDir") (PVar "sel") (PTuple (PVar "path") (PVar "secs"))) (ETuple (EVar "path") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "settleVerdict") (EVar "root")) (EVar "mode")) (EVar "outDir")) (EVar "sel")) (EVar "path")) (EVar "secs")) (EVar "False")))
(DTypeSig false "settleVerdict" (TyFun (TyCon "String") (TyFun (TyCon "SnapMode") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyEffect ("IO") None (TyCon "String")))))))))
(DFunDef false "settleVerdict" ((PVar "root") (PVar "mode") (PVar "outDir") (PVar "sel") (PVar "path") (PVar "secs")) (EMatch (EApp (EVar "badSections") (EVar "secs")) (arm (PCons (PVar "n") PWild) () (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL section ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString " contains a line matching the section-header grammar")))) (arm (PList) () (EBlock (DoLet false false (PVar "snapPath") (EApp (EApp (EApp (EVar "snapPathOf") (EVar "root")) (EVar "outDir")) (EVar "path"))) (DoExpr (EMatch (EApp (EVar "readOpt") (EVar "snapPath")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "verdictMissing") (EVar "mode")) (EVar "snapPath")) (EVar "sel")) (EVar "secs"))) (arm (PCon "Some" (PVar "prev")) () (EApp (EApp (EApp (EApp (EApp (EVar "verdictExisting") (EVar "mode")) (EVar "snapPath")) (EVar "sel")) (EVar "secs")) (EVar "prev")))))))))
(DTypeSig false "verdictMissing" (TyFun (TyCon "SnapMode") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyEffect ("IO") None (TyCon "String")))))))
(DFunDef false "verdictMissing" ((PCon "SnapCheck") (PVar "snapPath") PWild PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL no snapshot (")) (EApp (EVar "display") (EVar "snapPath"))) (ELit (LString "); run `medaka snapshot --new`"))))
(DFunDef false "verdictMissing" ((PCon "SnapBless") (PVar "snapPath") PWild PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL no snapshot (")) (EApp (EVar "display") (EVar "snapPath"))) (ELit (LString "); --bless never creates one — run `medaka snapshot --new` first"))))
(DFunDef false "verdictMissing" ((PCon "SnapNew") (PVar "snapPath") (PVar "sel") (PVar "secs")) (EMatch (EApp (EApp (EApp (EVar "writeSnap") (EVar "snapPath")) (EVar "sel")) (EVar "secs")) (arm (PCon "Err" (PVar "e")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ERROR cannot write ")) (EApp (EVar "display") (EVar "snapPath"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (arm (PCon "Ok" PWild) () (EBinOp "++" (EBinOp "++" (ELit (LString "NEW ")) (EApp (EVar "display") (EVar "snapPath"))) (ELit (LString ""))))))
(DTypeSig false "verdictExisting" (TyFun (TyCon "SnapMode") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))))))
(DFunDef false "verdictExisting" ((PCon "SnapCheck") PWild PWild (PVar "secs") (PVar "prev")) (EApp (EApp (EVar "compareSnap") (EVar "prev")) (EVar "secs")))
(DFunDef false "verdictExisting" ((PCon "SnapNew") (PVar "snapPath") PWild PWild PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "SKIP exists (")) (EApp (EVar "display") (EVar "snapPath"))) (ELit (LString ")"))))
(DFunDef false "verdictExisting" ((PCon "SnapBless") (PVar "snapPath") (PVar "sel") (PVar "secs") (PVar "prev")) (EBlock (DoLet false false (PVar "prevSecs") (EApp (EVar "parseSnapshot") (EVar "prev"))) (DoExpr (EMatch (EApp (EApp (EVar "diffSections") (EVar "prevSecs")) (EApp (EVar "secPairs") (EVar "secs"))) (arm (PList) () (ELit (LString "PASS"))) (arm (PVar "ds") () (EMatch (EApp (EApp (EApp (EVar "blockedDiags") (EVar "prevSecs")) (EVar "secs")) (EVar "ds")) (arm (PCons (PVar "b") (PVar "bs")) () (EApp (EApp (EVar "diagRefusal") (EVar "snapPath")) (EBinOp "::" (EVar "b") (EVar "bs")))) (arm (PList) () (EMatch (EApp (EApp (EApp (EVar "writeSnap") (EVar "snapPath")) (EVar "sel")) (EVar "secs")) (arm (PCon "Err" (PVar "e")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ERROR cannot write ")) (EApp (EVar "display") (EVar "snapPath"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "e"))) (ELit (LString "")))) (arm (PCon "Ok" PWild) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "BLESS ")) (EApp (EVar "display") (EVar "snapPath"))) (ELit (LString " ("))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "ds")))) (ELit (LString ")"))))))))))))
(DTypeSig false "blockedDiags" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "blockedDiags" ((PVar "prevSecs") (PVar "secs") (PVar "ds")) (EBlock (DoLet false false (PVar "diags") (EBinOp "++" (EApp (EVar "metaDiagsOf") (EVar "prevSecs")) (EApp (EVar "diagNamesOf") (EVar "secs")))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EVar "diags")))) (EVar "ds")))))
(DTypeSig false "diagRefusal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "diagRefusal" ((PVar "snapPath") (PVar "names")) (EBlock (DoLet false false (PVar "what") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "names"))) (DoLet false false (PVar "why") (ELit (LString "diagnostic text is never auto-blessable (compiler/ERROR-QUALITY.md grades it)."))) (DoLet false false (PVar "how") (EBinOp "++" (EBinOp "++" (ELit (LString "READ the new message; if it is genuinely better, `rm ")) (EApp (EVar "display") (EVar "snapPath"))) (ELit (LString "` and re-cut it with `medaka snapshot --new`.")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL refusing to bless diagnostic section(s) ")) (EApp (EVar "display") (EVar "what"))) (ELit (LString " in "))) (EApp (EVar "display") (EVar "snapPath"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "why"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "how"))) (ELit (LString ""))))))
(DTypeSig false "writeSnap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "writeSnap" ((PVar "snapPath") (PVar "sel") (PVar "secs")) (EApp (EApp (EVar "writeFile") (EVar "snapPath")) (EApp (EApp (EVar "renderSnapshot") (EApp (EApp (EVar "metaLinesFor") (EVar "sel")) (EVar "secs"))) (EApp (EVar "secPairs") (EVar "secs")))))
(DTypeSig false "badSections" (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "badSections" ((PVar "secs")) (EApp (EApp (EVar "map") (EVar "secName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "s")) (EApp (EVar "sectionCollides") (EApp (EVar "secBody") (EVar "s"))))) (EVar "secs"))))
(DTypeSig false "compareSnap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyCon "String"))))
(DFunDef false "compareSnap" ((PVar "prev") (PVar "secs")) (EMatch (EApp (EApp (EVar "diffSections") (EApp (EVar "parseSnapshot") (EVar "prev"))) (EApp (EVar "secPairs") (EVar "secs"))) (arm (PList) () (ELit (LString "PASS"))) (arm (PVar "ds") () (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL differing sections: ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "ds")))) (ELit (LString ""))))))
(DTypeSig false "diffSections" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "diffSections" ((PVar "want") (PVar "got")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "!=" (EVar "_s") (ELit (LString "META"))))) (EVar "snapSections"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EBinOp "!=" (EApp (EApp (EVar "sectionOf") (EVar "n")) (EVar "want")) (EApp (EApp (EVar "sectionOf") (EVar "n")) (EVar "got"))))) (EVar "names")))))
(DTypeSig false "readOpt" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "readOpt" ((PVar "p")) (EMatch (EApp (EVar "readFile") (EVar "p")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "s")) () (EApp (EVar "Some") (EVar "s")))))
(DTypeSig false "reportResults" (TyFun (TyApp (TyCon "List") (TyCon "SnapResult")) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "reportResults" ((PVar "results")) (EBlock (DoLet false false (PVar "bad") (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EVar "isBad") (EApp (EVar "verdictOf") (EVar "r"))))) (EVar "results"))) (DoLet false false PWild (EApp (EApp (EVar "mapUnit") (EVar "printResult")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "startsWith") (ELit (LString "BLESS"))) (EApp (EVar "verdictOf") (EVar "r"))))) (EVar "results")))) (DoLet false false PWild (EApp (EApp (EVar "mapUnit") (EVar "printResult")) (EVar "bad"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "summaryLine") (EVar "results")))) (DoExpr (EBinOp "==" (EVar "bad") (EListLit)))))
(DTypeSig false "verdictOf" (TyFun (TyCon "SnapResult") (TyCon "String")))
(DFunDef false "verdictOf" ((PTuple PWild (PVar "v") PWild)) (EVar "v"))
(DTypeSig false "isBad" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isBad" ((PVar "v")) (EBinOp "||" (EApp (EApp (EVar "startsWith") (ELit (LString "FAIL"))) (EVar "v")) (EApp (EApp (EVar "startsWith") (ELit (LString "ERROR"))) (EVar "v"))))
(DTypeSig false "printResult" (TyFun (TyCon "SnapResult") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printResult" ((PTuple (PVar "p") (PVar "v") PWild)) (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "p"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "")))))
(DTypeSig false "summaryLine" (TyFun (TyApp (TyCon "List") (TyCon "SnapResult")) (TyCon "String")))
(DFunDef false "summaryLine" ((PVar "results")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "length") (EVar "results"))) (DoLet false false (PVar "pass") (EApp (EApp (EVar "countWith") (ELit (LString "PASS"))) (EVar "results"))) (DoLet false false (PVar "new") (EApp (EApp (EVar "countWith") (ELit (LString "NEW"))) (EVar "results"))) (DoLet false false (PVar "bless") (EApp (EApp (EVar "countWith") (ELit (LString "BLESS"))) (EVar "results"))) (DoLet false false (PVar "skip") (EApp (EApp (EVar "countWith") (ELit (LString "SKIP"))) (EVar "results"))) (DoLet false false (PVar "fail") (EApp (EVar "length") (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EVar "isBad") (EApp (EVar "verdictOf") (EVar "r"))))) (EVar "results")))) (DoLet false false (PVar "crashed") (EApp (EVar "length") (EApp (EApp (EVar "filterList") (EVar "crashedOf")) (EVar "results")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "snapshot: ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " fixtures — "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "pass")))) (ELit (LString " pass, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "new")))) (ELit (LString " new, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "bless")))) (ELit (LString " blessed, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "skip")))) (ELit (LString " skipped, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "fail")))) (ELit (LString " failed, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "crashed")))) (ELit (LString " crashed"))))))
(DTypeSig false "countWith" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "SnapResult")) (TyCon "Int"))))
(DFunDef false "countWith" ((PVar "p") (PVar "results")) (EApp (EVar "length") (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "startsWith") (EVar "p")) (EApp (EVar "verdictOf") (EVar "r"))))) (EVar "results"))))
(DTypeSig false "crashedOf" (TyFun (TyCon "SnapResult") (TyCon "Bool")))
(DFunDef false "crashedOf" ((PTuple PWild PWild (PVar "c"))) (EVar "c"))
(DTypeSig false "mapUnit" (TyFun (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "mapUnit" (PWild (PList)) (ELit LUnit))
(DFunDef false "mapUnit" ((PVar "f") (PCons (PVar "x") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "f") (EVar "x"))) (DoExpr (EApp (EApp (EVar "mapUnit") (EVar "f")) (EVar "rest")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "tokenize" false) (mem "tokenToString" false) (mem "collectComments" false) (mem "Comment" false) (mem "commentLine" false) (mem "commentCol" false) (mem "commentText" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseResult" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false) (mem "parseWithPositions" false) (mem "Positions" false) (mem "DeclPos" false) (mem "positionsDecls" false) (mem "positionsVariantLines" false) (mem "positionsLastContentLine" false) (mem "declPosLine" false) (mem "declPosEndLine" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "programToString" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "markWithPrelude" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "programToSexp" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" false))))
(DUse false (UseGroup ("ir" "core_ir_lower") ((mem "lowerProgram" false) (mem "lowerProgramEmit" false) (mem "returnsSelfTable" false) (mem "selfFnParamTable" false) (mem "methodIfaceTable" false) (mem "methodConstraintIfaces" false) (mem "ctorFieldTypeNames" false) (mem "declSigTypeNames" false))))
(DUse false (UseGroup ("ir" "core_ir_sexp") ((mem "cprogramToSexp" false))))
(DUse false (UseGroup ("types" "annotate") ((mem "annotateProgram" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "checkToLinesWithRuntime" false) (mem "setCoherenceUserDecls" false) (mem "elaborateOne" false) (mem "elaborateDict" false) (mem "constrainedSigNames" false) (mem "mainTypeIsUnit" false) (mem "mainTypeIsFloat" false) (mem "hadTypeErrors" false) (mem "hadMatchWarnings" false) (mem "resetTypeErrorsSticky" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "evalOneOutput" false) (mem "funNamesOf" false) (mem "dropShadowedExp" false) (mem "noMainMsg" false))))
(DUse false (UseGroup ("backend" "llvm_emit") ((mem "emitProgram" false) (mem "installReturnsSelf" false) (mem "installSelfFnParams" false) (mem "installMethodIface" false) (mem "installMethodConstraintIfaces" false) (mem "installCtorFieldTypes" false) (mem "installDeclSigTypes" false) (mem "installMainIsUnitHint" false) (mem "installMainIsFloatHint" false) (mem "enableGapRecord" false) (mem "resetGaps" false) (mem "gapEvents" false))))
(DUse false (UseGroup ("backend" "wasm_emit") ((mem "emitProgram" false "wasmText") (mem "installDeclRetTypes" false) (mem "installCtorFloatFields" false) (mem "enableGapRecordW" false) (mem "resetGapsW" false) (mem "gapEventsW" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "joinWith" false) (mem "splitNl" false) (mem "startsWith" false) (mem "anyList" false) (mem "reverseL" false) (mem "filterList" false))))
(DUse false (UseGroup ("support" "path") ((mem "chopExt" false) (mem "baseOf" false))))
(DUse false (UseGroup ("string") ((mem "split" false) (mem "replaceAll" false) (mem "trim" false) (mem "trimRight" false) (mem "take" false) (mem "drop" false) (mem "toInt" false) (mem "toFloat" false) (mem "toUpper" false))))
(DTypeSig true "snapSections" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "snapSections" () (EListLit (ELit (LString "META")) (ELit (LString "SOURCE")) (ELit (LString "TOKENS")) (ELit (LString "COMMENTS")) (ELit (LString "POSITIONS")) (ELit (LString "PARSE")) (ELit (LString "PRINTER")) (ELit (LString "DESUGAR")) (ELit (LString "MARK")) (ELit (LString "TYPES")) (ELit (LString "TYPES_USER")) (ELit (LString "CORE_IR")) (ELit (LString "LLVM")) (ELit (LString "WASM")) (ELit (LString "EVAL")) (ELit (LString "CRASH"))))
(DTypeSig true "isHeaderLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHeaderLine" ((PVar "l")) (EApp (EApp (EVar "anyList") (ELam ((PVar "n")) (EBinOp "==" (EVar "l") (EBinOp "++" (EBinOp "++" (ELit (LString "# ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))))) (EVar "snapSections")))
(DTypeSig false "sectionCollides" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "sectionCollides" ((PVar "content")) (EApp (EApp (EVar "anyList") (EVar "isHeaderLine")) (EApp (EVar "splitNl") (EVar "content"))))
(DData Public "SnapMode" () ((variant "SnapCheck" (ConPos)) (variant "SnapNew" (ConPos)) (variant "SnapBless" (ConPos))) ())
(DTypeAlias false "RunSec" () (TyTuple (TyCon "String") (TyCon "String") (TyCon "Bool")))
(DTypeSig false "secName" (TyFun (TyCon "RunSec") (TyCon "String")))
(DFunDef false "secName" ((PTuple (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "secBody" (TyFun (TyCon "RunSec") (TyCon "String")))
(DFunDef false "secBody" ((PTuple PWild (PVar "b") PWild)) (EVar "b"))
(DTypeSig false "secIsDiag" (TyFun (TyCon "RunSec") (TyCon "Bool")))
(DFunDef false "secIsDiag" ((PTuple PWild PWild (PVar "d"))) (EVar "d"))
(DTypeSig false "secPairs" (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "secPairs" ((PVar "secs")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (ETuple (EApp (EVar "secName") (EVar "s")) (EApp (EVar "secBody") (EVar "s"))))) (EVar "secs")))
(DTypeSig false "diagNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "diagNamesOf" ((PVar "secs")) (EApp (EApp (EMethodRef "map") (EVar "secName")) (EApp (EApp (EVar "filterList") (EVar "secIsDiag")) (EVar "secs"))))
(DTypeSig true "parseStages" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "parseStages" ((PVar "spec")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "!=" (EVar "_s") (ELit (LString ""))))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (EApp (EVar "toUpper") (EApp (EVar "trim") (EVar "s"))))) (EApp (EApp (EVar "split") (ELit (LString ","))) (EVar "spec"))))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EVar "snapSections"))))) (EVar "names")) (arm (PList) () (EApp (EVar "Ok") (EVar "names"))) (arm (PVar "bad") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "unknown stage(s): ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "bad")))) (ELit (LString " (known: "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "snapSections")))) (ELit (LString ")")))))))))
(DTypeSig false "wants" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "wants" ((PList) PWild) (EVar "True"))
(DFunDef false "wants" ((PVar "sel") (PVar "n")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EVar "sel")))
(DTypeSig false "contentLines" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "contentLines" ((PLit (LString ""))) (EListLit))
(DFunDef false "contentLines" ((PVar "s")) (EApp (EVar "dropTrailingEmpty") (EApp (EVar "splitNl") (EVar "s"))))
(DTypeSig false "dropTrailingEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropTrailingEmpty" ((PList)) (EListLit))
(DFunDef false "dropTrailingEmpty" ((PList (PLit (LString "")))) (EListLit))
(DFunDef false "dropTrailingEmpty" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "dropTrailingEmpty") (EVar "rest"))))
(DTypeSig false "blockOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "blockOf" ((PList)) (ELit (LString "")))
(DFunDef false "blockOf" ((PVar "ls")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "joinNl") (EVar "ls")))) (ELit (LString "\n"))))
(DTypeSig false "isRunSection" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isRunSection" ((PVar "n")) (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "EVAL"))) (EBinOp "==" (EVar "n") (ELit (LString "CRASH")))))
(DTypeSig false "canonText" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "canonText" ((PVar "text")) (EApp (EVar "blockOf") (EApp (EApp (EMethodRef "map") (EVar "trimRight")) (EApp (EVar "contentLines") (EVar "text")))))
(DTypeSig true "normalizeText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "normalizeText" ((PVar "root") (PVar "text")) (EApp (EVar "blockOf") (EApp (EApp (EMethodRef "map") (EApp (EVar "normalizeLine") (EVar "root"))) (EApp (EVar "contentLines") (EVar "text")))))
(DTypeSig false "normalizeLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "normalizeLine" ((PVar "root") (PVar "line")) (EApp (EVar "trimRight") (EApp (EVar "normDurations") (EApp (EVar "normTmp") (EApp (EApp (EApp (EVar "replaceAll") (EVar "root")) (ELit (LString "<ROOT>"))) (EVar "line"))))))
(DTypeSig false "normTmp" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normTmp" ((PVar "line")) (EMatch (EApp (EApp (EVar "split") (EVar "tmpPrefix")) (EVar "line")) (arm (PList) () (EVar "line")) (arm (PList (PVar "only")) () (EVar "only")) (arm (PCons (PVar "first") (PVar "rest")) () (EApp (EApp (EVar "joinWith") (ELit (LString "<TMP>"))) (EBinOp "::" (EVar "first") (EApp (EApp (EMethodRef "map") (EApp (EVar "drop") (ELit (LInt 6)))) (EVar "rest")))))))
(DTypeSig false "tmpPrefix" (TyCon "String"))
(DFunDef false "tmpPrefix" () (ELit (LString "/tmp/medaka_build_")))
(DTypeSig false "normDurations" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "normDurations" ((PVar "line")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "durWord")) (EApp (EApp (EVar "split") (ELit (LString " "))) (EVar "line")))))
(DTypeSig false "durWord" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "durWord" ((PVar "w")) (EIf (EApp (EVar "isDuration") (EVar "w")) (ELit (LString "<T>")) (EVar "w")))
(DTypeSig false "isDuration" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDuration" ((PVar "w")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "durBody") (EVar "w"))) (DoExpr (EIf (EBinOp "==" (EVar "body") (ELit (LString ""))) (EVar "False") (EApp (EVar "isNumeric") (EVar "body"))))))
(DTypeSig false "durBody" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "durBody" ((PVar "w")) (EIf (EApp (EApp (EVar "endsWithStr") (ELit (LString "ms"))) (EVar "w")) (EApp (EApp (EVar "take") (EBinOp "-" (EApp (EVar "stringLength") (EVar "w")) (ELit (LInt 2)))) (EVar "w")) (EIf (EApp (EApp (EVar "endsWithStr") (ELit (LString "s"))) (EVar "w")) (EApp (EApp (EVar "take") (EBinOp "-" (EApp (EVar "stringLength") (EVar "w")) (ELit (LInt 1)))) (EVar "w")) (EIf (EVar "otherwise") (ELit (LString "")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "endsWithStr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "endsWithStr" ((PVar "suf") (PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoLet false false (PVar "m") (EApp (EVar "stringLength") (EVar "suf"))) (DoExpr (EIf (EBinOp ">" (EVar "m") (EVar "n")) (EVar "False") (EBinOp "==" (EApp (EApp (EVar "drop") (EBinOp "-" (EVar "n") (EVar "m"))) (EVar "s")) (EVar "suf"))))))
(DTypeSig false "isNumeric" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isNumeric" ((PVar "s")) (EMatch (EApp (EVar "toInt") (EVar "s")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EMatch (EApp (EVar "toFloat") (EVar "s")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "tokensOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "tokensOf" ((PVar "src")) (EApp (EVar "blockOf") (EApp (EApp (EMethodRef "map") (EVar "tokenToString")) (EApp (EVar "tokenize") (EVar "src")))))
(DTypeSig false "commentsOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "commentsOf" ((PVar "src")) (EApp (EVar "blockOf") (EApp (EApp (EMethodRef "map") (EVar "renderComment")) (EApp (EVar "collectComments") (EVar "src")))))
(DTypeSig false "renderComment" (TyFun (TyCon "Comment") (TyCon "String")))
(DFunDef false "renderComment" ((PVar "c")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "commentLine") (EVar "c"))))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "commentCol") (EVar "c"))))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "escNl") (EApp (EVar "commentText") (EVar "c"))))) (ELit (LString ""))))
(DTypeSig false "escNl" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escNl" ((PVar "s")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "escNlFrom") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0)))))
(DTypeSig false "escNlFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "escNlFrom" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EBinOp "::" (ELit (LString "\\n")) (EApp (EApp (EVar "escNlFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "charToStr") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "escNlFrom") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "positionsOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "positionsOf" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositions") (EVar "src")) (arm (PTuple (PVar "_decls") (PVar "pos")) () (EApp (EVar "renderPositions") (EVar "pos")))))
(DTypeSig false "renderPositions" (TyFun (TyCon "Positions") (TyCon "String")))
(DFunDef false "renderPositions" ((PVar "p")) (EBlock (DoLet false false (PVar "decls") (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (EVar "renderDeclPos")) (EApp (EVar "positionsDecls") (EVar "p"))))) (DoLet false false (PVar "vars") (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (EVar "renderVariant")) (EApp (EVar "positionsVariantLines") (EVar "p"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "=== DECLS ===\n")) (EApp (EMethodRef "display") (EVar "decls"))) (ELit (LString "=== VARIANTS ===\n"))) (EApp (EMethodRef "display") (EVar "vars"))) (ELit (LString "=== LASTLINE ===\n"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "positionsLastContentLine") (EVar "p"))))) (ELit (LString "\n"))))))
(DTypeSig false "renderDeclPos" (TyFun (TyCon "DeclPos") (TyCon "String")))
(DFunDef false "renderDeclPos" ((PVar "d")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "declPosLine") (EVar "d"))))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "declPosEndLine") (EVar "d"))))) (ELit (LString "\n"))))
(DTypeSig false "renderVariant" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "renderVariant" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "\n"))))
(DTypeSig false "parseErrText" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "parseErrText" ((PVar "line") (PVar "col") (PVar "msg")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "parse error at ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString "\n"))))
(DTypeSig false "markOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String"))))
(DFunDef false "markOf" ((PVar "coreDecls") (PVar "d")) (EApp (EVar "programToSexp") (EApp (EApp (EVar "markWithPrelude") (EVar "coreDecls")) (EVar "d"))))
(DTypeSig false "typesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "String") (TyCon "Bool")))))
(DFunDef false "typesOf" ((PVar "runtimeDecls") (PVar "d")) (EBlock (DoLet false false PWild (EApp (EVar "setCoherenceUserDecls") (EVar "d"))) (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "text") (EApp (EApp (EApp (EVar "checkToLinesWithRuntime") (EVar "runtimeDecls")) (EListLit)) (EVar "d"))) (DoExpr (ETuple (EVar "text") (EBinOp "||" (EApp (EVar "hadTypeErrors") (ELit LUnit)) (EApp (EVar "hadMatchWarnings") (ELit LUnit)))))))
(DTypeSig false "typesUserOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "typesUserOf" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "d")) (EBlock (DoLet false false PWild (EApp (EVar "setCoherenceUserDecls") (EVar "d"))) (DoLet false false PWild (EApp (EVar "resetTypeErrorsSticky") (ELit LUnit))) (DoLet false false (PVar "full") (EApp (EApp (EApp (EVar "checkToLinesWithRuntime") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "d"))) (DoLet false false (PVar "diag") (EBinOp "||" (EApp (EVar "hadTypeErrors") (ELit LUnit)) (EApp (EVar "hadMatchWarnings") (ELit LUnit)))) (DoLet false false (PVar "text") (EIf (EApp (EVar "hadTypeErrors") (ELit LUnit)) (EVar "full") (EApp (EVar "blockOf") (EApp (EApp (EVar "filterList") (EApp (EVar "userSchemeLine") (EApp (EVar "funNamesOf") (EVar "d")))) (EApp (EVar "contentLines") (EVar "full")))))) (DoExpr (ETuple (EVar "text") (EVar "diag")))))
(DTypeSig false "userSchemeLine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "userSchemeLine" ((PVar "userNames") (PVar "line")) (EMatch (EApp (EApp (EVar "split") (ELit (LString " : "))) (EVar "line")) (arm (PCons (PVar "nm") (PCons PWild PWild)) () (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "nm")))) (EVar "userNames"))) (arm PWild () (EVar "True"))))
(DTypeSig false "coreIrOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "coreIrOf" ((PVar "d")) (EApp (EVar "cprogramToSexp") (EApp (EVar "lowerProgram") (EApp (EVar "annotateProgram") (EVar "d")))))
(DTypeSig false "evalOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))
(DFunDef false "evalOf" ((PVar "runtimeDecls") (PVar "coreDecls") (PVar "d")) (EBlock (DoLet false false (PVar "livePrelude") (EApp (EApp (EVar "dropShadowedExp") (EApp (EVar "funNamesOf") (EVar "d"))) (EVar "coreDecls"))) (DoExpr (EApp (EApp (EVar "evalOneOutput") (EListLit)) (ETuple (ELit (LString "__main__")) (EApp (EApp (EApp (EVar "elaborateOne") (EVar "runtimeDecls")) (EVar "livePrelude")) (ETuple (ELit (LString "__user__")) (EVar "d"))))))))
(DTypeSig false "emitBoth" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "emitBoth" ((PVar "root") (PVar "sel") (PVar "runtimeDecls") (PVar "userDecls")) (EBlock (DoLet false false (PVar "userNames") (EApp (EVar "funNamesOf") (EVar "userDecls"))) (DoLet false false (PVar "dictNames") (EApp (EVar "constrainedSigNames") (EVar "userDecls"))) (DoLet false false (PVar "allDecls") (EApp (EApp (EApp (EApp (EVar "elaborateDict") (EVar "runtimeDecls")) (EVar "dictNames")) (EVar "userNames")) (EVar "userDecls"))) (DoLet false false (PVar "cp") (EApp (EVar "lowerProgramEmit") (EVar "allDecls"))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "LLVM"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "LLVM"))) (EApp (EApp (EApp (EVar "llvmOf") (EVar "runtimeDecls")) (EVar "allDecls")) (EVar "cp"))) (ELit LUnit))) (DoExpr (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "WASM"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "WASM"))) (EApp (EApp (EApp (EVar "wasmOf") (EVar "runtimeDecls")) (EVar "allDecls")) (EVar "cp"))) (ELit LUnit)))))
(DTypeSig false "llvmOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "CProgram") (TyCon "String")))))
(DFunDef false "llvmOf" ((PVar "runtimeDecls") (PVar "allDecls") (PVar "cp")) (EBlock (DoLet false false PWild (EApp (EVar "installReturnsSelf") (EApp (EVar "returnsSelfTable") (EVar "allDecls")))) (DoLet false false PWild (EApp (EVar "installSelfFnParams") (EApp (EVar "selfFnParamTable") (EVar "allDecls")))) (DoLet false false PWild (EApp (EVar "installMethodIface") (EApp (EVar "methodIfaceTable") (EVar "allDecls")))) (DoLet false false PWild (EApp (EVar "installMethodConstraintIfaces") (EApp (EVar "methodConstraintIfaces") (EVar "allDecls")))) (DoLet false false PWild (EApp (EVar "installCtorFieldTypes") (EApp (EVar "ctorFieldTypeNames") (EVar "allDecls")))) (DoLet false false PWild (EApp (EVar "installDeclSigTypes") (EBinOp "++" (EApp (EVar "declSigTypeNames") (EVar "runtimeDecls")) (EApp (EVar "declSigTypeNames") (EVar "allDecls"))))) (DoLet false false PWild (EApp (EVar "installMainIsUnitHint") (EApp (EVar "mainTypeIsUnit") (ELit LUnit)))) (DoLet false false PWild (EApp (EVar "installMainIsFloatHint") (EApp (EVar "mainTypeIsFloat") (ELit LUnit)))) (DoLet false false PWild (EApp (EVar "resetGaps") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "enableGapRecord") (ELit LUnit))) (DoLet false false (PVar "text") (EApp (EVar "emitProgram") (EVar "cp"))) (DoExpr (EApp (EApp (EApp (EVar "withGaps") (ELit (LString ";"))) (EVar "text")) (EApp (EVar "gapEvents") (ELit LUnit))))))
(DTypeSig false "wasmOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "CProgram") (TyCon "String")))))
(DFunDef false "wasmOf" ((PVar "runtimeDecls") (PVar "allDecls") (PVar "cp")) (EBlock (DoLet false false PWild (EApp (EVar "installDeclRetTypes") (EBinOp "++" (EApp (EVar "declSigTypeNames") (EVar "runtimeDecls")) (EApp (EVar "declSigTypeNames") (EVar "allDecls"))))) (DoLet false false PWild (EApp (EVar "installCtorFloatFields") (EApp (EVar "ctorFieldTypeNames") (EVar "allDecls")))) (DoLet false false PWild (EApp (EVar "resetGapsW") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "enableGapRecordW") (ELit LUnit))) (DoLet false false (PVar "text") (EApp (EVar "wasmText") (EVar "cp"))) (DoExpr (EApp (EApp (EApp (EVar "withGaps") (ELit (LString ";;"))) (EVar "text")) (EApp (EVar "gapEventsW") (ELit LUnit))))))
(DTypeSig false "withGaps" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "withGaps" (PWild (PVar "text") (PList)) (EVar "text"))
(DFunDef false "withGaps" ((PVar "cmt") (PVar "text") (PVar "gaps")) (EApp (EVar "blockOf") (EBinOp "++" (EApp (EVar "contentLines") (EVar "text")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "g")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "cmt"))) (ELit (LString " GAP: "))) (EApp (EMethodRef "display") (EVar "g"))) (ELit (LString ""))))) (EVar "gaps")))))
(DTypeSig false "putLineFlush" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "putLineFlush" ((PVar "s")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EVar "s"))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "emitSection" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitSection" ((PVar "root") (PVar "name") (PVar "content")) (EApp (EApp (EApp (EApp (EVar "emitSectionTagged") (EVar "root")) (EVar "name")) (EVar "content")) (EVar "False")))
(DTypeSig false "emitDiagSection" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitDiagSection" ((PVar "root") (PVar "name") (PVar "content")) (EApp (EApp (EApp (EApp (EVar "emitSectionTagged") (EVar "root")) (EVar "name")) (EVar "content")) (EVar "True")))
(DTypeSig false "emitSectionTagged" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "emitSectionTagged" ((PVar "root") (PVar "name") (PVar "content") (PVar "diag")) (EApp (EApp (EApp (EVar "emitRawTagged") (EVar "name")) (EIf (EApp (EVar "isRunSection") (EVar "name")) (EApp (EApp (EVar "normalizeText") (EVar "root")) (EVar "content")) (EApp (EVar "canonText") (EVar "content")))) (EVar "diag")))
(DTypeSig false "emitRaw" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emitRaw" ((PVar "name") (PVar "content")) (EApp (EApp (EApp (EVar "emitRawTagged") (EVar "name")) (EVar "content")) (EVar "False")))
(DTypeSig false "emitRawTagged" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitRawTagged" ((PVar "name") (PVar "content") (PVar "diag")) (EBlock (DoLet false false PWild (EApp (EVar "putStrLn") (EIf (EVar "diag") (EBinOp "++" (EBinOp "++" (ELit (LString "SECD ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "SEC ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))))) (DoLet false false PWild (EApp (EVar "putStr") (EApp (EVar "encodeLines") (EApp (EVar "contentLines") (EVar "content"))))) (DoExpr (EApp (EVar "flushStdout") (ELit LUnit)))))
(DTypeSig false "encodeLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "encodeLines" ((PVar "ls")) (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (ELam ((PVar "l")) (EBinOp "++" (EBinOp "++" (ELit (LString "D")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "\n"))))) (EVar "ls"))))
(DTypeSig true "runSnapshotWorker" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "runSnapshotWorker" ((PVar "root") (PVar "sel") (PVar "files")) (EMatch (EApp (EVar "loadPrelude") (EVar "root")) (arm (PCon "Err" (PVar "msg")) () (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1)))))) (arm (PCon "Ok" (PTuple (PVar "runtimeDecls") (PVar "coreDecls"))) () (EApp (EApp (EApp (EApp (EApp (EVar "workerLoop") (EVar "root")) (EVar "sel")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "files")))))
(DTypeSig false "loadPrelude" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "loadPrelude" ((PVar "root")) (EMatch (EApp (EVar "readFile") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/stdlib/runtime.mdk")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "snapshot: cannot read stdlib/runtime.mdk: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "rsrc")) () (EMatch (EApp (EVar "readFile") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/stdlib/core.mdk")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "snapshot: cannot read stdlib/core.mdk: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "csrc")) () (EMatch (EApp (EVar "parseResult") (EVar "rsrc")) (arm (PCon "Err" PWild) () (EApp (EVar "Err") (ELit (LString "snapshot: stdlib/runtime.mdk does not parse")))) (arm (PCon "Ok" (PVar "rd")) () (EMatch (EApp (EVar "parseResult") (EVar "csrc")) (arm (PCon "Err" PWild) () (EApp (EVar "Err") (ELit (LString "snapshot: stdlib/core.mdk does not parse")))) (arm (PCon "Ok" (PVar "cd")) () (EApp (EVar "Ok") (ETuple (EApp (EVar "desugar") (EVar "rd")) (EApp (EVar "desugar") (EVar "cd")))))))))))))
(DTypeSig false "workerLoop" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "workerLoop" (PWild PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "workerLoop" ((PVar "root") (PVar "sel") (PVar "runtimeDecls") (PVar "coreDecls") (PCons (PVar "f") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "workerOne") (EVar "root")) (EVar "sel")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "workerLoop") (EVar "root")) (EVar "sel")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "rest")))))
(DTypeSig false "workerOne" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "workerOne" ((PVar "root") (PVar "sel") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "path")) (EBlock (DoLet false false PWild (EApp (EVar "putLineFlush") (EBinOp "++" (EBinOp "++" (ELit (LString "BEGIN ")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString ""))))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EVar "workerRender") (EVar "root")) (EVar "sel")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "path"))) (DoExpr (EApp (EVar "putLineFlush") (EBinOp "++" (EBinOp "++" (ELit (LString "END ")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "")))))))
(DTypeSig false "workerRender" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "workerRender" ((PVar "root") (PVar "sel") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "msg")) () (EApp (EApp (EApp (EVar "emitDiagSection") (EVar "root")) (ELit (LString "CRASH"))) (EBinOp "++" (EBinOp "++" (ELit (LString "cannot read fixture: ")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString "\n"))))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false PWild (EApp (EApp (EVar "emitRaw") (ELit (LString "SOURCE"))) (EVar "src"))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "TOKENS"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "TOKENS"))) (EApp (EVar "tokensOf") (EVar "src"))) (ELit LUnit))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "COMMENTS"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "COMMENTS"))) (EApp (EVar "commentsOf") (EVar "src"))) (ELit LUnit))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "POSITIONS"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "POSITIONS"))) (EApp (EVar "positionsOf") (EVar "src"))) (ELit LUnit))) (DoExpr (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EApp (EVar "emitDiagSection") (EVar "root")) (ELit (LString "PARSE"))) (EApp (EApp (EApp (EVar "parseErrText") (EApp (EVar "parseErrorLine") (EVar "e"))) (EApp (EVar "parseErrorCol") (EVar "e"))) (EApp (EVar "parseErrorMessage") (EVar "e"))))) (arm (PCon "Ok" (PVar "decls")) () (EApp (EApp (EApp (EApp (EApp (EVar "workerStages") (EVar "root")) (EVar "sel")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "decls")))))))))
(DTypeSig false "workerStages" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Unit"))))))))
(DFunDef false "workerStages" ((PVar "root") (PVar "sel") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "decls")) (EBlock (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "PARSE"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "PARSE"))) (EApp (EVar "programToSexp") (EVar "decls"))) (ELit LUnit))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "PRINTER"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "PRINTER"))) (EApp (EVar "programToString") (EVar "decls"))) (ELit LUnit))) (DoLet false false (PVar "d") (EApp (EVar "desugar") (EVar "decls"))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "DESUGAR"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "DESUGAR"))) (EApp (EVar "programToSexp") (EVar "d"))) (ELit LUnit))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "MARK"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "MARK"))) (EApp (EApp (EVar "markOf") (EVar "coreDecls")) (EVar "d"))) (ELit LUnit))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "TYPES"))) (EApp (EApp (EApp (EVar "emitTypes") (EVar "root")) (EVar "runtimeDecls")) (EVar "d")) (ELit LUnit))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "TYPES_USER"))) (EApp (EApp (EApp (EApp (EVar "emitTypesUser") (EVar "root")) (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "d")) (ELit LUnit))) (DoLet false false PWild (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "CORE_IR"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "CORE_IR"))) (EApp (EVar "coreIrOf") (EVar "d"))) (ELit LUnit))) (DoExpr (EIf (EApp (EVar "hasMain") (EVar "d")) (EBlock (DoLet false false PWild (EIf (EBinOp "||" (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "LLVM"))) (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "WASM")))) (EApp (EApp (EApp (EApp (EVar "emitBoth") (EVar "root")) (EVar "sel")) (EVar "runtimeDecls")) (EVar "d")) (ELit LUnit))) (DoExpr (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "EVAL"))) (EApp (EApp (EApp (EVar "emitSection") (EVar "root")) (ELit (LString "EVAL"))) (EApp (EApp (EApp (EVar "evalOf") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "d"))) (ELit LUnit)))) (EIf (EApp (EApp (EVar "wants") (EVar "sel")) (ELit (LString "EVAL"))) (EApp (EApp (EApp (EVar "emitDiagSection") (EVar "root")) (ELit (LString "CRASH"))) (EBinOp "++" (EBinOp "++" (ELit (LString ":0:0: runtime error [E-NO-MAIN]: ")) (EApp (EMethodRef "display") (EVar "noMainMsg"))) (ELit (LString "\n")))) (ELit LUnit))))))
(DTypeSig false "emitTypes" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "emitTypes" ((PVar "root") (PVar "runtimeDecls") (PVar "d")) (EBlock (DoLet false false (PTuple (PVar "text") (PVar "diag")) (EApp (EApp (EVar "typesOf") (EVar "runtimeDecls")) (EVar "d"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "emitSectionTagged") (EVar "root")) (ELit (LString "TYPES"))) (EVar "text")) (EVar "diag")))))
(DTypeSig false "emitTypesUser" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyEffect ("IO") None (TyCon "Unit")))))))
(DFunDef false "emitTypesUser" ((PVar "root") (PVar "runtimeDecls") (PVar "coreDecls") (PVar "d")) (EBlock (DoLet false false (PTuple (PVar "text") (PVar "diag")) (EApp (EApp (EApp (EVar "typesUserOf") (EVar "runtimeDecls")) (EVar "coreDecls")) (EVar "d"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "emitSectionTagged") (EVar "root")) (ELit (LString "TYPES_USER"))) (EVar "text")) (EVar "diag")))))
(DTypeSig false "hasMain" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasMain" ((PVar "d")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (ELit (LString "main"))))) (EApp (EVar "funNamesOf") (EVar "d"))))
(DTypeSig false "chunkSize" (TyCon "Int"))
(DFunDef false "chunkSize" () (ELit (LInt 25)))
(DTypeAlias false "Chunk" () (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DTypeSig true "runSnapshotSupervisor" (TyFun (TyCon "String") (TyFun (TyCon "SnapMode") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Bool")))))))))
(DFunDef false "runSnapshotSupervisor" ((PVar "root") (PVar "mode") (PVar "forceIsolate") (PVar "outDir") (PVar "cli") (PVar "files")) (EBlock (DoLet false false (PVar "results") (EApp (EApp (EApp (EApp (EVar "superviseChunks") (EVar "root")) (EVar "mode")) (EVar "outDir")) (EApp (EApp (EApp (EApp (EApp (EVar "chunksOf") (EVar "root")) (EVar "outDir")) (EVar "forceIsolate")) (EVar "cli")) (EVar "files")))) (DoExpr (EApp (EVar "reportResults") (EVar "results")))))
(DTypeSig false "chunksOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "Chunk")))))))))
(DFunDef false "chunksOf" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "chunksOf" ((PVar "root") (PVar "outDir") (PVar "forceIsolate") (PVar "cli") (PCons (PVar "f") (PVar "rest"))) (EBlock (DoLet false false (PVar "meta") (EApp (EApp (EApp (EVar "metaOf") (EVar "root")) (EVar "outDir")) (EVar "f"))) (DoLet false false (PVar "sel") (EApp (EApp (EVar "stagesIn") (EVar "cli")) (EVar "meta"))) (DoExpr (EIf (EBinOp "||" (EVar "forceIsolate") (EApp (EVar "isIsolatedIn") (EVar "meta"))) (EBinOp "::" (ETuple (EVar "sel") (EListLit (EVar "f"))) (EApp (EApp (EApp (EApp (EApp (EVar "chunksOf") (EVar "root")) (EVar "outDir")) (EVar "forceIsolate")) (EVar "cli")) (EVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "grp") (PVar "tail2")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "takeRun") (EVar "root")) (EVar "outDir")) (EVar "forceIsolate")) (EVar "cli")) (EVar "sel")) (EBinOp "-" (EVar "chunkSize") (ELit (LInt 1)))) (EVar "rest"))) (DoExpr (EBinOp "::" (ETuple (EVar "sel") (EBinOp "::" (EVar "f") (EVar "grp"))) (EApp (EApp (EApp (EApp (EApp (EVar "chunksOf") (EVar "root")) (EVar "outDir")) (EVar "forceIsolate")) (EVar "cli")) (EVar "tail2")))))))))
(DTypeSig false "takeRun" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))))))
(DFunDef false "takeRun" (PWild PWild PWild PWild PWild PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "takeRun" ((PVar "root") (PVar "outDir") (PVar "forceIsolate") (PVar "cli") (PVar "sel") (PVar "n") (PCons (PVar "f") (PVar "rest"))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ETuple (EListLit) (EBinOp "::" (EVar "f") (EVar "rest"))) (EBlock (DoLet false false (PVar "meta") (EApp (EApp (EApp (EVar "metaOf") (EVar "root")) (EVar "outDir")) (EVar "f"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EVar "forceIsolate") (EApp (EVar "isIsolatedIn") (EVar "meta"))) (EBinOp "!=" (EApp (EApp (EVar "stagesIn") (EVar "cli")) (EVar "meta")) (EVar "sel"))) (ETuple (EListLit) (EBinOp "::" (EVar "f") (EVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "grp") (PVar "tail2")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "takeRun") (EVar "root")) (EVar "outDir")) (EVar "forceIsolate")) (EVar "cli")) (EVar "sel")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "f") (EVar "grp")) (EVar "tail2")))))))))
(DTypeSig false "metaOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "metaOf" ((PVar "root") (PVar "outDir") (PVar "f")) (EMatch (EApp (EVar "readFile") (EApp (EApp (EApp (EVar "snapPathOf") (EVar "root")) (EVar "outDir")) (EVar "f"))) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "text")) () (EApp (EVar "contentLines") (EApp (EApp (EVar "sectionOf") (ELit (LString "META"))) (EApp (EVar "parseSnapshot") (EVar "text")))))))
(DTypeSig false "isIsolatedIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isIsolatedIn" ((PVar "meta")) (EApp (EApp (EVar "anyList") (ELam ((PVar "l")) (EBinOp "==" (EApp (EVar "trimRight") (EVar "l")) (ELit (LString "isolate=true"))))) (EVar "meta")))
(DTypeSig false "stagesIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "stagesIn" ((PCons (PVar "s") (PVar "rest")) PWild) (EBinOp "::" (EVar "s") (EVar "rest")))
(DFunDef false "stagesIn" ((PList) (PVar "meta")) (EApp (EVar "metaStages") (EVar "meta")))
(DTypeSig false "metaStages" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "metaStages" ((PList)) (EListLit))
(DFunDef false "metaStages" ((PCons (PVar "l") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "stages="))) (EVar "l")) (EMatch (EApp (EVar "parseStages") (EApp (EApp (EVar "drop") (ELit (LInt 7))) (EVar "l"))) (arm (PCon "Ok" (PVar "ns")) () (EVar "ns")) (arm (PCon "Err" PWild) () (EListLit))) (EApp (EVar "metaStages") (EVar "rest"))))
(DTypeSig false "superviseChunks" (TyFun (TyCon "String") (TyFun (TyCon "SnapMode") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "SnapResult"))))))))
(DFunDef false "superviseChunks" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "superviseChunks" ((PVar "root") (PVar "mode") (PVar "outDir") (PCons (PTuple (PVar "sel") (PVar "fs")) (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EApp (EApp (EApp (EApp (EApp (EVar "runChunk") (EVar "root")) (EVar "mode")) (EVar "outDir")) (EVar "sel")) (EVar "fs"))) (DoExpr (EBinOp "++" (EVar "here") (EApp (EApp (EApp (EApp (EVar "superviseChunks") (EVar "root")) (EVar "mode")) (EVar "outDir")) (EVar "rest"))))))
(DTypeSig false "runChunk" (TyFun (TyCon "String") (TyFun (TyCon "SnapMode") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyCon "List") (TyCon "SnapResult")))))))))
(DFunDef false "runChunk" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "runChunk" ((PVar "root") (PVar "mode") (PVar "outDir") (PVar "sel") (PVar "pending")) (EMatch (EApp (EApp (EVar "runCommand") (EApp (EVar "executablePath") (ELit LUnit))) (EApp (EApp (EApp (EVar "workerArgv") (EVar "root")) (EVar "sel")) (EVar "pending"))) (arm (PCon "Err" (PVar "e")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (ETuple (EVar "f") (EBinOp "++" (EBinOp "++" (ELit (LString "ERROR spawn failed: ")) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString ""))) (EVar "False")))) (EVar "pending"))) (arm (PCon "Ok" (PTuple (PVar "code") (PVar "out") (PVar "err"))) () (EBlock (DoLet false false (PVar "streamed") (EApp (EVar "parseStream") (EVar "out"))) (DoLet false false (PVar "done") (EApp (EApp (EMethodRef "map") (EVar "fixtureOf")) (EVar "streamed"))) (DoLet false false (PVar "banked") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "settle") (EVar "root")) (EVar "mode")) (EVar "outDir")) (EVar "sel"))) (EVar "streamed"))) (DoLet false false (PVar "missing") (EApp (EApp (EVar "notIn") (EVar "done")) (EVar "pending"))) (DoExpr (EIf (EBinOp "==" (EVar "missing") (EListLit)) (EVar "banked") (EMatch (EApp (EVar "lastBegun") (EVar "out")) (arm (PCon "None") () (EBinOp "++" (EVar "banked") (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (ETuple (EVar "f") (EBinOp "++" (EBinOp "++" (ELit (LString "ERROR worker died with no BEGIN (exit ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "code")))) (ELit (LString ")"))) (EVar "False")))) (EVar "missing")))) (arm (PCon "Some" (PVar "victim")) () (EBlock (DoLet false false (PVar "crashSecs") (EBinOp "++" (EApp (EVar "streamTail") (EVar "out")) (EListLit (ETuple (ELit (LString "CRASH")) (EApp (EApp (EVar "normalizeText") (EVar "root")) (EVar "err")) (EVar "True"))))) (DoLet false false (PTuple PWild (PVar "v") PWild) (EApp (EApp (EApp (EApp (EApp (EVar "settle") (EVar "root")) (EVar "mode")) (EVar "outDir")) (EVar "sel")) (ETuple (EVar "victim") (EVar "crashSecs")))) (DoLet false false (PVar "remaining") (EApp (EApp (EVar "afterFirst") (EVar "victim")) (EVar "pending"))) (DoExpr (EBinOp "++" (EBinOp "++" (EVar "banked") (EListLit (ETuple (EVar "victim") (EVar "v") (EVar "True")))) (EApp (EApp (EApp (EApp (EApp (EVar "runChunk") (EVar "root")) (EVar "mode")) (EVar "outDir")) (EVar "sel")) (EVar "remaining")))))))))))))
(DTypeSig false "workerArgv" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "workerArgv" ((PVar "root") (PList) (PVar "files")) (EBinOp "++" (EListLit (ELit (LString "snapshot")) (ELit (LString "--worker")) (ELit (LString "--root")) (EVar "root")) (EVar "files")))
(DFunDef false "workerArgv" ((PVar "root") (PVar "sel") (PVar "files")) (EBinOp "++" (EListLit (ELit (LString "snapshot")) (ELit (LString "--worker")) (ELit (LString "--root")) (EVar "root") (ELit (LString "--stages")) (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "sel"))) (EVar "files")))
(DTypeSig false "notIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "notIn" ((PVar "done") (PVar "xs")) (EApp (EApp (EVar "filterList") (ELam ((PVar "x")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "x")))) (EVar "done"))))) (EVar "xs")))
(DTypeSig false "afterFirst" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "afterFirst" (PWild (PList)) (EListLit))
(DFunDef false "afterFirst" ((PVar "victim") (PCons (PVar "x") (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EVar "victim")) (EVar "rest") (EApp (EApp (EVar "afterFirst") (EVar "victim")) (EVar "rest"))))
(DTypeSig false "parseStream" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "RunSec"))))))
(DFunDef false "parseStream" ((PVar "out")) (EApp (EApp (EApp (EApp (EVar "streamGo") (EApp (EVar "splitNl") (EVar "out"))) (ELit (LString ""))) (EListLit)) (EListLit)))
(DTypeSig false "streamGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Sections") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Sections"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "RunSec")))))))))
(DFunDef false "streamGo" ((PList) PWild PWild (PVar "acc")) (EApp (EApp (EMethodRef "map") (EVar "settleSecs")) (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "streamGo" ((PCons (PVar "l") (PVar "rest")) (PVar "cur") (PVar "secs") (PVar "acc")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "BEGIN "))) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "streamGo") (EVar "rest")) (EApp (EApp (EVar "drop") (ELit (LInt 6))) (EVar "l"))) (EListLit)) (EVar "acc")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "END "))) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "streamGo") (EVar "rest")) (ELit (LString ""))) (EListLit)) (EApp (EApp (EApp (EVar "flushCur") (EVar "cur")) (EVar "secs")) (EVar "acc"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "SECD "))) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "streamGo") (EVar "rest")) (EVar "cur")) (EBinOp "::" (ETuple (EApp (EApp (EVar "drop") (ELit (LInt 5))) (EVar "l")) (EVar "True") (EListLit)) (EVar "secs"))) (EVar "acc")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "SEC "))) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "streamGo") (EVar "rest")) (EVar "cur")) (EBinOp "::" (ETuple (EApp (EApp (EVar "drop") (ELit (LInt 4))) (EVar "l")) (EVar "False") (EListLit)) (EVar "secs"))) (EVar "acc")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "D"))) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "streamGo") (EVar "rest")) (EVar "cur")) (EApp (EApp (EVar "pushLine") (EApp (EApp (EVar "drop") (ELit (LInt 1))) (EVar "l"))) (EVar "secs"))) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "streamGo") (EVar "rest")) (EVar "cur")) (EVar "secs")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "streamTail" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "RunSec"))))
(DFunDef false "streamTail" ((PVar "out")) (EApp (EApp (EApp (EVar "streamTailGo") (EApp (EVar "splitNl") (EVar "out"))) (ELit (LString ""))) (EListLit)))
(DTypeSig false "streamTailGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "Sections") (TyApp (TyCon "List") (TyCon "RunSec"))))))
(DFunDef false "streamTailGo" ((PList) (PLit (LString "")) PWild) (EListLit))
(DFunDef false "streamTailGo" ((PList) PWild (PVar "secs")) (EApp (EVar "closeSecs") (EVar "secs")))
(DFunDef false "streamTailGo" ((PCons (PVar "l") (PVar "rest")) (PVar "cur") (PVar "secs")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "BEGIN "))) (EVar "l")) (EApp (EApp (EApp (EVar "streamTailGo") (EVar "rest")) (EApp (EApp (EVar "drop") (ELit (LInt 6))) (EVar "l"))) (EListLit)) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "END "))) (EVar "l")) (EApp (EApp (EApp (EVar "streamTailGo") (EVar "rest")) (ELit (LString ""))) (EListLit)) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "SECD "))) (EVar "l")) (EApp (EApp (EApp (EVar "streamTailGo") (EVar "rest")) (EVar "cur")) (EBinOp "::" (ETuple (EApp (EApp (EVar "drop") (ELit (LInt 5))) (EVar "l")) (EVar "True") (EListLit)) (EVar "secs"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "SEC "))) (EVar "l")) (EApp (EApp (EApp (EVar "streamTailGo") (EVar "rest")) (EVar "cur")) (EBinOp "::" (ETuple (EApp (EApp (EVar "drop") (ELit (LInt 4))) (EVar "l")) (EVar "False") (EListLit)) (EVar "secs"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "D"))) (EVar "l")) (EApp (EApp (EApp (EVar "streamTailGo") (EVar "rest")) (EVar "cur")) (EApp (EApp (EVar "pushLine") (EApp (EApp (EVar "drop") (ELit (LInt 1))) (EVar "l"))) (EVar "secs"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "streamTailGo") (EVar "rest")) (EVar "cur")) (EVar "secs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeAlias false "Sections" () (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String")))))
(DTypeSig false "pushLine" (TyFun (TyCon "String") (TyFun (TyCon "Sections") (TyCon "Sections"))))
(DFunDef false "pushLine" (PWild (PList)) (EListLit))
(DFunDef false "pushLine" ((PVar "l") (PCons (PTuple (PVar "n") (PVar "d") (PVar "ls")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EVar "d") (EBinOp "::" (EVar "l") (EVar "ls"))) (EVar "rest")))
(DTypeSig false "closeSecs" (TyFun (TyCon "Sections") (TyApp (TyCon "List") (TyCon "RunSec"))))
(DFunDef false "closeSecs" ((PVar "secs")) (EApp (EApp (EMethodRef "map") (EVar "closeSec")) (EApp (EVar "reverseL") (EVar "secs"))))
(DTypeSig false "closeSec" (TyFun (TyTuple (TyCon "String") (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "RunSec")))
(DFunDef false "closeSec" ((PTuple (PVar "n") (PVar "d") (PVar "ls"))) (ETuple (EVar "n") (EApp (EVar "blockOf") (EApp (EVar "reverseL") (EVar "ls"))) (EVar "d")))
(DTypeSig false "settleSecs" (TyFun (TyTuple (TyCon "String") (TyCon "Sections")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "RunSec")))))
(DFunDef false "settleSecs" ((PTuple (PVar "p") (PVar "secs"))) (ETuple (EVar "p") (EApp (EVar "closeSecs") (EVar "secs"))))
(DTypeSig false "flushCur" (TyFun (TyCon "String") (TyFun (TyCon "Sections") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Sections"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Sections")))))))
(DFunDef false "flushCur" ((PLit (LString "")) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "flushCur" ((PVar "cur") (PVar "secs") (PVar "acc")) (EBinOp "::" (ETuple (EVar "cur") (EVar "secs")) (EVar "acc")))
(DTypeSig false "fixtureOf" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "RunSec"))) (TyCon "String")))
(DFunDef false "fixtureOf" ((PTuple (PVar "p") PWild)) (EVar "p"))
(DTypeSig false "lastBegun" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "lastBegun" ((PVar "out")) (EApp (EApp (EVar "lastBegunGo") (EApp (EVar "splitNl") (EVar "out"))) (EVar "None")))
(DTypeSig false "lastBegunGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lastBegunGo" ((PList) (PVar "cur")) (EVar "cur"))
(DFunDef false "lastBegunGo" ((PCons (PVar "l") (PVar "rest")) (PVar "cur")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "BEGIN "))) (EVar "l")) (EApp (EApp (EVar "lastBegunGo") (EVar "rest")) (EApp (EVar "Some") (EApp (EApp (EVar "drop") (ELit (LInt 6))) (EVar "l")))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "END "))) (EVar "l")) (EApp (EApp (EVar "lastBegunGo") (EVar "rest")) (EVar "None")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lastBegunGo") (EVar "rest")) (EVar "cur")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "snapPathOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "snapPathOf" (PWild (PCon "None") (PVar "f")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "chopExt") (EVar "f")))) (ELit (LString ".md"))))
(DFunDef false "snapPathOf" (PWild (PCon "Some" (PVar "dir")) (PVar "f")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EApp (EVar "chopExt") (EApp (EVar "baseOf") (EVar "f"))))) (ELit (LString ".md"))))
(DTypeSig false "sectionOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "String"))))
(DFunDef false "sectionOf" (PWild (PList)) (ELit (LString "")))
(DFunDef false "sectionOf" ((PVar "n") (PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EVar "v") (EApp (EApp (EVar "sectionOf") (EVar "n")) (EVar "rest"))))
(DTypeSig false "hasSection" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "hasSection" ((PVar "n") (PVar "secs")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EApp (EApp (EMethodRef "map") (EVar "fst2")) (EVar "secs"))))
(DTypeSig false "fst2" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "fst2" ((PTuple (PVar "a") PWild)) (EVar "a"))
(DTypeSig false "renderSnapshot" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "String"))))
(DFunDef false "renderSnapshot" ((PVar "metaExtra") (PVar "secs")) (EBlock (DoLet false false (PVar "src") (EApp (EApp (EVar "sectionOf") (ELit (LString "SOURCE"))) (EVar "secs"))) (DoLet false false (PVar "meta") (EApp (EVar "blockOf") (EBinOp "++" (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "source_lines=")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EMethodRef "length") (EApp (EVar "contentLines") (EVar "src")))))) (ELit (LString "")))) (EVar "metaExtra")))) (DoLet false false (PVar "body") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "n")) (EApp (EApp (EVar "renderOne") (EVar "n")) (EVar "secs")))) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "!=" (EVar "_s") (ELit (LString "META"))))) (EVar "snapSections")))) (DoExpr (EApp (EVar "stringConcat") (EBinOp "++" (EListLit (ELit (LString "# META\n")) (EVar "meta")) (EVar "body"))))))
(DTypeSig false "renderOne" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "renderOne" ((PVar "n") (PVar "secs")) (EIf (EApp (EApp (EVar "hasSection") (EVar "n")) (EVar "secs")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "# ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "\n"))) (EApp (EApp (EVar "sectionOf") (EVar "n")) (EVar "secs"))) (EListLit)))
(DTypeSig false "metaLinesFor" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "metaLinesFor" ((PVar "sel") (PVar "secs")) (EBinOp "++" (EBinOp "++" (EApp (EVar "stagesLine") (EVar "sel")) (EApp (EVar "diagLine") (EApp (EVar "diagNamesOf") (EVar "secs")))) (EApp (EVar "metaExtraOf") (EApp (EVar "secPairs") (EVar "secs")))))
(DTypeSig false "stagesLine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stagesLine" ((PList)) (EListLit))
(DFunDef false "stagesLine" ((PVar "sel")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "stages=")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "sel")))) (ELit (LString "")))))
(DTypeSig false "diagLine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "diagLine" ((PList)) (EListLit))
(DFunDef false "diagLine" ((PVar "ns")) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "diagnostics=")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "ns")))) (ELit (LString "")))))
(DTypeSig false "metaExtraOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "metaExtraOf" ((PVar "secs")) (EApp (EApp (EVar "filterList") (EVar "isAuthoredMetaLine")) (EApp (EVar "contentLines") (EApp (EApp (EVar "sectionOf") (ELit (LString "META"))) (EVar "secs")))))
(DTypeSig false "isAuthoredMetaLine" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isAuthoredMetaLine" ((PVar "l")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "source_lines="))) (EVar "l"))) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "stages="))) (EVar "l")))) (EApp (EVar "not") (EApp (EApp (EVar "startsWith") (ELit (LString "diagnostics="))) (EVar "l")))))
(DTypeSig false "metaDiagsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "metaDiagsOf" ((PVar "secs")) (EApp (EVar "metaDiagsIn") (EApp (EVar "contentLines") (EApp (EApp (EVar "sectionOf") (ELit (LString "META"))) (EVar "secs")))))
(DTypeSig false "metaDiagsIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "metaDiagsIn" ((PList)) (EListLit))
(DFunDef false "metaDiagsIn" ((PCons (PVar "l") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "diagnostics="))) (EVar "l")) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "!=" (EVar "_s") (ELit (LString ""))))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (EApp (EVar "toUpper") (EApp (EVar "trim") (EVar "s"))))) (EApp (EApp (EVar "split") (ELit (LString ","))) (EApp (EApp (EVar "drop") (ELit (LInt 12))) (EVar "l"))))) (EApp (EVar "metaDiagsIn") (EVar "rest"))))
(DTypeSig true "parseSnapshot" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "parseSnapshot" ((PVar "text")) (EBlock (DoLet false false (PVar "ls") (EApp (EVar "splitNl") (EVar "text"))) (DoExpr (EApp (EApp (EVar "collectSections") (EVar "ls")) (EApp (EVar "metaSourceLines") (EVar "ls"))))))
(DTypeSig false "metaSourceLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))
(DFunDef false "metaSourceLines" ((PList)) (ELit (LInt 0)))
(DFunDef false "metaSourceLines" ((PCons (PVar "l") (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "source_lines="))) (EVar "l")) (EMatch (EApp (EVar "toInt") (EApp (EApp (EVar "drop") (ELit (LInt 13))) (EVar "l"))) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (ELit (LInt 0)))) (EApp (EVar "metaSourceLines") (EVar "rest"))))
(DTypeSig false "collectSections" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "collectSections" ((PList) PWild) (EListLit))
(DFunDef false "collectSections" ((PCons (PVar "l") (PVar "rest")) (PVar "n")) (EIf (EApp (EVar "isHeaderLine") (EVar "l")) (EBlock (DoLet false false (PVar "name") (EApp (EApp (EVar "drop") (ELit (LInt 2))) (EVar "l"))) (DoExpr (EIf (EBinOp "==" (EVar "name") (ELit (LString "SOURCE"))) (EBlock (DoLet false false (PTuple (PVar "body") (PVar "tail2")) (EApp (EApp (EVar "splitAtN") (EVar "n")) (EVar "rest"))) (DoExpr (EBinOp "::" (ETuple (ELit (LString "SOURCE")) (EApp (EVar "blockOf") (EVar "body"))) (EApp (EApp (EVar "collectSections") (EVar "tail2")) (EVar "n"))))) (EBlock (DoLet false false (PTuple (PVar "body") (PVar "tail2")) (EApp (EVar "untilHeader") (EVar "rest"))) (DoExpr (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "blockOf") (EApp (EVar "dropTrailingEmpty") (EVar "body")))) (EApp (EApp (EVar "collectSections") (EVar "tail2")) (EVar "n")))))))) (EApp (EApp (EVar "collectSections") (EVar "rest")) (EVar "n"))))
(DTypeSig false "splitAtN" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "splitAtN" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "splitAtN" ((PVar "n") (PCons (PVar "x") (PVar "rest"))) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ETuple (EListLit) (EBinOp "::" (EVar "x") (EVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EApp (EVar "splitAtN") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "x") (EVar "a")) (EVar "b"))))))
(DTypeSig false "untilHeader" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "untilHeader" ((PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "untilHeader" ((PCons (PVar "x") (PVar "rest"))) (EIf (EApp (EVar "isHeaderLine") (EVar "x")) (ETuple (EListLit) (EBinOp "::" (EVar "x") (EVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EVar "untilHeader") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "x") (EVar "a")) (EVar "b"))))))
(DTypeAlias false "SnapResult" () (TyTuple (TyCon "String") (TyCon "String") (TyCon "Bool")))
(DTypeSig false "settle" (TyFun (TyCon "String") (TyFun (TyCon "SnapMode") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "RunSec"))) (TyEffect ("IO") None (TyCon "SnapResult"))))))))
(DFunDef false "settle" ((PVar "root") (PVar "mode") (PVar "outDir") (PVar "sel") (PTuple (PVar "path") (PVar "secs"))) (ETuple (EVar "path") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "settleVerdict") (EVar "root")) (EVar "mode")) (EVar "outDir")) (EVar "sel")) (EVar "path")) (EVar "secs")) (EVar "False")))
(DTypeSig false "settleVerdict" (TyFun (TyCon "String") (TyFun (TyCon "SnapMode") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyEffect ("IO") None (TyCon "String")))))))))
(DFunDef false "settleVerdict" ((PVar "root") (PVar "mode") (PVar "outDir") (PVar "sel") (PVar "path") (PVar "secs")) (EMatch (EApp (EVar "badSections") (EVar "secs")) (arm (PCons (PVar "n") PWild) () (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL section ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " contains a line matching the section-header grammar")))) (arm (PList) () (EBlock (DoLet false false (PVar "snapPath") (EApp (EApp (EApp (EVar "snapPathOf") (EVar "root")) (EVar "outDir")) (EVar "path"))) (DoExpr (EMatch (EApp (EVar "readOpt") (EVar "snapPath")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "verdictMissing") (EVar "mode")) (EVar "snapPath")) (EVar "sel")) (EVar "secs"))) (arm (PCon "Some" (PVar "prev")) () (EApp (EApp (EApp (EApp (EApp (EVar "verdictExisting") (EVar "mode")) (EVar "snapPath")) (EVar "sel")) (EVar "secs")) (EVar "prev")))))))))
(DTypeSig false "verdictMissing" (TyFun (TyCon "SnapMode") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyEffect ("IO") None (TyCon "String")))))))
(DFunDef false "verdictMissing" ((PCon "SnapCheck") (PVar "snapPath") PWild PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL no snapshot (")) (EApp (EMethodRef "display") (EVar "snapPath"))) (ELit (LString "); run `medaka snapshot --new`"))))
(DFunDef false "verdictMissing" ((PCon "SnapBless") (PVar "snapPath") PWild PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL no snapshot (")) (EApp (EMethodRef "display") (EVar "snapPath"))) (ELit (LString "); --bless never creates one — run `medaka snapshot --new` first"))))
(DFunDef false "verdictMissing" ((PCon "SnapNew") (PVar "snapPath") (PVar "sel") (PVar "secs")) (EMatch (EApp (EApp (EApp (EVar "writeSnap") (EVar "snapPath")) (EVar "sel")) (EVar "secs")) (arm (PCon "Err" (PVar "e")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ERROR cannot write ")) (EApp (EMethodRef "display") (EVar "snapPath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (arm (PCon "Ok" PWild) () (EBinOp "++" (EBinOp "++" (ELit (LString "NEW ")) (EApp (EMethodRef "display") (EVar "snapPath"))) (ELit (LString ""))))))
(DTypeSig false "verdictExisting" (TyFun (TyCon "SnapMode") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "String"))))))))
(DFunDef false "verdictExisting" ((PCon "SnapCheck") PWild PWild (PVar "secs") (PVar "prev")) (EApp (EApp (EVar "compareSnap") (EVar "prev")) (EVar "secs")))
(DFunDef false "verdictExisting" ((PCon "SnapNew") (PVar "snapPath") PWild PWild PWild) (EBinOp "++" (EBinOp "++" (ELit (LString "SKIP exists (")) (EApp (EMethodRef "display") (EVar "snapPath"))) (ELit (LString ")"))))
(DFunDef false "verdictExisting" ((PCon "SnapBless") (PVar "snapPath") (PVar "sel") (PVar "secs") (PVar "prev")) (EBlock (DoLet false false (PVar "prevSecs") (EApp (EVar "parseSnapshot") (EVar "prev"))) (DoExpr (EMatch (EApp (EApp (EVar "diffSections") (EVar "prevSecs")) (EApp (EVar "secPairs") (EVar "secs"))) (arm (PList) () (ELit (LString "PASS"))) (arm (PVar "ds") () (EMatch (EApp (EApp (EApp (EVar "blockedDiags") (EVar "prevSecs")) (EVar "secs")) (EVar "ds")) (arm (PCons (PVar "b") (PVar "bs")) () (EApp (EApp (EVar "diagRefusal") (EVar "snapPath")) (EBinOp "::" (EVar "b") (EVar "bs")))) (arm (PList) () (EMatch (EApp (EApp (EApp (EVar "writeSnap") (EVar "snapPath")) (EVar "sel")) (EVar "secs")) (arm (PCon "Err" (PVar "e")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ERROR cannot write ")) (EApp (EMethodRef "display") (EVar "snapPath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "e"))) (ELit (LString "")))) (arm (PCon "Ok" PWild) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "BLESS ")) (EApp (EMethodRef "display") (EVar "snapPath"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "ds")))) (ELit (LString ")"))))))))))))
(DTypeSig false "blockedDiags" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "blockedDiags" ((PVar "prevSecs") (PVar "secs") (PVar "ds")) (EBlock (DoLet false false (PVar "diags") (EBinOp "++" (EApp (EVar "metaDiagsOf") (EVar "prevSecs")) (EApp (EVar "diagNamesOf") (EVar "secs")))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EVar "diags")))) (EVar "ds")))))
(DTypeSig false "diagRefusal" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "diagRefusal" ((PVar "snapPath") (PVar "names")) (EBlock (DoLet false false (PVar "what") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "names"))) (DoLet false false (PVar "why") (ELit (LString "diagnostic text is never auto-blessable (compiler/ERROR-QUALITY.md grades it)."))) (DoLet false false (PVar "how") (EBinOp "++" (EBinOp "++" (ELit (LString "READ the new message; if it is genuinely better, `rm ")) (EApp (EMethodRef "display") (EVar "snapPath"))) (ELit (LString "` and re-cut it with `medaka snapshot --new`.")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL refusing to bless diagnostic section(s) ")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString " in "))) (EApp (EMethodRef "display") (EVar "snapPath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "how"))) (ELit (LString ""))))))
(DTypeSig false "writeSnap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Unit")))))))
(DFunDef false "writeSnap" ((PVar "snapPath") (PVar "sel") (PVar "secs")) (EApp (EApp (EVar "writeFile") (EVar "snapPath")) (EApp (EApp (EVar "renderSnapshot") (EApp (EApp (EVar "metaLinesFor") (EVar "sel")) (EVar "secs"))) (EApp (EVar "secPairs") (EVar "secs")))))
(DTypeSig false "badSections" (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "badSections" ((PVar "secs")) (EApp (EApp (EMethodRef "map") (EVar "secName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "s")) (EApp (EVar "sectionCollides") (EApp (EVar "secBody") (EVar "s"))))) (EVar "secs"))))
(DTypeSig false "compareSnap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunSec")) (TyCon "String"))))
(DFunDef false "compareSnap" ((PVar "prev") (PVar "secs")) (EMatch (EApp (EApp (EVar "diffSections") (EApp (EVar "parseSnapshot") (EVar "prev"))) (EApp (EVar "secPairs") (EVar "secs"))) (arm (PList) () (ELit (LString "PASS"))) (arm (PVar "ds") () (EBinOp "++" (EBinOp "++" (ELit (LString "FAIL differing sections: ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "ds")))) (ELit (LString ""))))))
(DTypeSig false "diffSections" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "diffSections" ((PVar "want") (PVar "got")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "!=" (EVar "_s") (ELit (LString "META"))))) (EVar "snapSections"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EBinOp "!=" (EApp (EApp (EVar "sectionOf") (EVar "n")) (EVar "want")) (EApp (EApp (EVar "sectionOf") (EVar "n")) (EVar "got"))))) (EVar "names")))))
(DTypeSig false "readOpt" (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "readOpt" ((PVar "p")) (EMatch (EApp (EVar "readFile") (EVar "p")) (arm (PCon "Err" PWild) () (EVar "None")) (arm (PCon "Ok" (PVar "s")) () (EApp (EVar "Some") (EVar "s")))))
(DTypeSig false "reportResults" (TyFun (TyApp (TyCon "List") (TyCon "SnapResult")) (TyEffect ("IO") None (TyCon "Bool"))))
(DFunDef false "reportResults" ((PVar "results")) (EBlock (DoLet false false (PVar "bad") (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EVar "isBad") (EApp (EVar "verdictOf") (EVar "r"))))) (EVar "results"))) (DoLet false false PWild (EApp (EApp (EVar "mapUnit") (EVar "printResult")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "startsWith") (ELit (LString "BLESS"))) (EApp (EVar "verdictOf") (EVar "r"))))) (EVar "results")))) (DoLet false false PWild (EApp (EApp (EVar "mapUnit") (EVar "printResult")) (EVar "bad"))) (DoLet false false PWild (EApp (EVar "putStrLn") (EApp (EVar "summaryLine") (EVar "results")))) (DoExpr (EBinOp "==" (EVar "bad") (EListLit)))))
(DTypeSig false "verdictOf" (TyFun (TyCon "SnapResult") (TyCon "String")))
(DFunDef false "verdictOf" ((PTuple PWild (PVar "v") PWild)) (EVar "v"))
(DTypeSig false "isBad" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isBad" ((PVar "v")) (EBinOp "||" (EApp (EApp (EVar "startsWith") (ELit (LString "FAIL"))) (EVar "v")) (EApp (EApp (EVar "startsWith") (ELit (LString "ERROR"))) (EVar "v"))))
(DTypeSig false "printResult" (TyFun (TyCon "SnapResult") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "printResult" ((PTuple (PVar "p") (PVar "v") PWild)) (EApp (EVar "putStrLn") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "")))))
(DTypeSig false "summaryLine" (TyFun (TyApp (TyCon "List") (TyCon "SnapResult")) (TyCon "String")))
(DFunDef false "summaryLine" ((PVar "results")) (EBlock (DoLet false false (PVar "n") (EApp (EMethodRef "length") (EVar "results"))) (DoLet false false (PVar "pass") (EApp (EApp (EVar "countWith") (ELit (LString "PASS"))) (EVar "results"))) (DoLet false false (PVar "new") (EApp (EApp (EVar "countWith") (ELit (LString "NEW"))) (EVar "results"))) (DoLet false false (PVar "bless") (EApp (EApp (EVar "countWith") (ELit (LString "BLESS"))) (EVar "results"))) (DoLet false false (PVar "skip") (EApp (EApp (EVar "countWith") (ELit (LString "SKIP"))) (EVar "results"))) (DoLet false false (PVar "fail") (EApp (EMethodRef "length") (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EVar "isBad") (EApp (EVar "verdictOf") (EVar "r"))))) (EVar "results")))) (DoLet false false (PVar "crashed") (EApp (EMethodRef "length") (EApp (EApp (EVar "filterList") (EVar "crashedOf")) (EVar "results")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "snapshot: ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " fixtures — "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "pass")))) (ELit (LString " pass, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "new")))) (ELit (LString " new, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "bless")))) (ELit (LString " blessed, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "skip")))) (ELit (LString " skipped, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "fail")))) (ELit (LString " failed, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "crashed")))) (ELit (LString " crashed"))))))
(DTypeSig false "countWith" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "SnapResult")) (TyCon "Int"))))
(DFunDef false "countWith" ((PVar "p") (PVar "results")) (EApp (EMethodRef "length") (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "startsWith") (EVar "p")) (EApp (EVar "verdictOf") (EVar "r"))))) (EVar "results"))))
(DTypeSig false "crashedOf" (TyFun (TyCon "SnapResult") (TyCon "Bool")))
(DFunDef false "crashedOf" ((PTuple PWild PWild (PVar "c"))) (EVar "c"))
(DTypeSig false "mapUnit" (TyFun (TyFun (TyVar "a") (TyEffect ("IO") None (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "mapUnit" (PWild (PList)) (ELit LUnit))
(DFunDef false "mapUnit" ((PVar "f") (PCons (PVar "x") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EVar "f") (EVar "x"))) (DoExpr (EApp (EApp (EVar "mapUnit") (EVar "f")) (EVar "rest")))))
