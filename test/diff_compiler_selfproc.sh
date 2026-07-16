#!/bin/sh
# THE SELF-PROCESSING CLOSURE — the decisive self-hosting milestone
# (compiler/README.md §"The bootstrap (#3)" -> "Self-processing target").
#
# Runs the self-hosted compiler over the compiler/*.mdk sources THEMSELVES and
# diffs against the OCaml reference doing the same.  Two legs:
#
#  LEG A — front-end "checks itself" (typecheck closure).
#    Feeds the WHOLE compiler source through the self-hosted multi-module
#    front-end (loader -> desugar -> checkModules) in ONE process, using
#    compiler/entries/all_modules_entry.mdk as the aggregate entry (its imports force
#    loadProgram to pull every module into a single union closure).
#    check_all_main.mdk emits every module's inferred schemes, each section
#    preceded by `## MODULE <mid>`; we diff each module's section against the
#    OCaml reference front-end (real Loader + threaded typecheck_module, via
#    dev/tc_module_probe.exe).  The self-hosted front-end is itself EXECUTED by
#    the OCaml eval_modules oracle (`medaka run check_all_main.mdk ...`), so a
#    pass means: self-hosted front-end (run on eval_modules) == OCaml-native
#    front-end, for all 12 modules of its own source.
#
#  LEG B — eval engine "runs itself" (eval_modules over a real stage module).
#    Runs a real compiler stage module (the lexer) through the SELF-HOSTED eval
#    path (eval.mdk's evalModules) over an embedded Medaka snippet, and diffs its
#    token stream against the eval_modules oracle (`medaka run <probe>` = OCaml
#    Loader -> typecheck -> eval_modules).  Byte-identical output proves the
#    self-hosted untyped evaluator correctly EXECUTES a real compiler stage.
#    (The parser/typecheck stages use return-position Parser-monad dispatch the
#    untyped self-hosted eval cannot yet resolve — see PLAN.md; the lexer uses
#    none, so it is the executable slice today.)
#
# Usage:  sh test/diff_compiler_selfproc.sh
# Exit:   0 iff every module's front-end output matches AND the eval leg matches.
# OCaml-free (REROOT-PLAN.md Phase 3 / §2c):
#   * HOST: the self-hosted entries run as pre-compiled native binaries under
#     test/bin/ (check_all_main, eval_modules_main, eval_typed_modules_main),
#     built by test/build_oracles.sh — replacing the OCaml interpreter host.
#   * ORACLE (legs B/C/D): the reference probe output is the committed golden
#     test/selfproc_goldens/{lex,parse,tc}_probe.golden, captured from the OCaml
#     reference eval by test/capture_goldens.sh while
#     OCaml was trusted.  The gate strips the native runtime's trailing "()" from
#     the self-hosted eval output before comparing.
#   * LEG A (fixed 2026-07-13): used to iterate flat module names (ast lexer ...)
#     that no longer exist under the folder layout, so `[ -f "$SHDIR/$m.mdk" ]`
#     silently `continue`d for all 12 modules and the leg checked nothing — a
#     silent regression from the 2026-06-12 Phase-A subfolder move (1c0cebfd),
#     which updated the files but not this lookup. MODULES now holds dotted mids
#     (frontend.ast, ...) matching the `## MODULE <mid>` marker + `import
#     frontend.ast` style; the per-module lookup maps mid -> subfolder path
#     (tr '.' '/'). Reference: per-module goldens under
#     test/selfproc_goldens/legA/, captured from the native self-hosted
#     front-end itself (no OCaml oracle left) via
#     `sh test/capture_goldens.sh --frozen selfproc_legA`.
#
# Usage:  sh test/diff_compiler_selfproc.sh
# Exit:   0 iff every module's front-end output matches AND the eval leg matches.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_ALL="$ROOT/test/bin/check_all_main"
EVAL_MODS="$ROOT/test/bin/eval_modules_main"
EVAL_TYPED_MODS="$ROOT/test/bin/eval_typed_modules_main"
ENTRY="$ROOT/compiler/entries/all_modules_entry.mdk"
LEXPROBE="$ROOT/compiler/entries/selfproc_lex_probe.mdk"
PARSEPROBE="$ROOT/compiler/entries/selfproc_parse_probe.mdk"
TCPROBE="$ROOT/compiler/entries/selfproc_tc_probe.mdk"
GOLDDIR="$ROOT/test/selfproc_goldens"
LEGA_GOLD="$GOLDDIR/legA"
CORE="$ROOT/stdlib/core.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
SHDIR="$ROOT/compiler"
STDLIB="$ROOT/stdlib"
# Collect ALL missing oracles before failing — naming only the first costs a
# round-trip per oracle in a fresh worktree (#398).
_missing=""
[ -x "$CHECK_ALL" ] || _missing="$_missing $CHECK_ALL"
[ -x "$EVAL_MODS" ] || _missing="$_missing $EVAL_MODS"
[ -x "$EVAL_TYPED_MODS" ] || _missing="$_missing $EVAL_TYPED_MODS"
if [ -n "$_missing" ]; then
  echo "build oracles first — missing:"
  for _m in $_missing; do
    echo "  FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$_m")  (missing $_m)"
  done
  exit 2
fi
for f in "$ENTRY" "$LEXPROBE" "$PARSEPROBE" "$TCPROBE"; do
  [ -f "$f" ] || { echo "missing $f"; exit 2; }
done
for g in "$GOLDDIR/lex_probe.golden" "$GOLDDIR/parse_probe.golden" "$GOLDDIR/tc_probe.golden"; do
  [ -f "$g" ] || { echo "missing golden $g — run: sh test/capture_goldens.sh selfproc"; exit 2; }
done

# The native runtime auto-prints main's Unit return as a trailing "()" appended to
# the last (no-trailing-newline) line of probe output; the OCaml-captured golden
# has none.  strip_unit drops a single trailing "()" token from a $()-captured string.
strip_unit() { s="$1"; printf '%s' "${s%()}"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# ── LEG A: front-end self-processing (typecheck closure) ───────────────────
echo "== LEG A: self-hosted front-end typechecks its own source =="
# mid = dotted module id (post-reorg, matches `import frontend.ast.{…}` style and
# the `## MODULE <mid>` marker emitted by checkModulesAllLines — see
# compiler/types/typecheck.mdk). Bare flat names (pre-2026-06-12 Phase-A reorg)
# no longer exist on disk or in the dump, which is why this leg silently checked
# nothing for a while (`$SHDIR/$m.mdk` never matched) — fixed by mapping mid ->
# subfolder path below.
MODULES="frontend.ast frontend.lexer frontend.parser ir.sexp frontend.desugar frontend.marker types.annotate frontend.resolve frontend.exhaust driver.loader types.typecheck eval.eval tools.check"

# One full-closure run emits every module's schemes (sections marked
# `## MODULE <mid>`).  all_modules_entry imports one name from each module so the
# loader pulls them all into a single union closure.
"$CHECK_ALL" "$RUNTIME" "$CORE" "$ENTRY" "$SHDIR" "$STDLIB" 2>/dev/null > "$TMP/all.txt"

# Extract module <mid>'s section (lines between its marker and the next).
section() {  # section <dumpfile> <mid>
  awk -v M="$2" '/^## MODULE /{cur=($3==M)?1:0; next} cur{print}' "$1"
}

for m in $MODULES; do
  mpath="$(printf '%s' "$m" | tr '.' '/')"
  [ -f "$SHDIR/$mpath.mdk" ] || continue
  if ! grep -q "^## MODULE $m\$" "$TMP/all.txt"; then
    fail=$((fail+1)); printf 'FAIL %-10s (not covered by aggregate entry closure)\n' "$m"; continue
  fi
  golden="$LEGA_GOLD/$m.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %-10s (no golden — run: sh test/capture_goldens.sh --frozen selfproc_legA)\n' "$m"; continue
  fi
  self="$(section "$TMP/all.txt" "$m" | LC_ALL=C sort)"
  ref="$(LC_ALL=C sort "$golden")"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %-10s (schemes match reference)\n' "$m"
  else fail=$((fail+1)); printf 'FAIL %-10s (schemes differ from reference)\n' "$m"; fi
done

# ── LEG B: eval engine self-execution (eval_modules over a real stage) ─────
echo
echo "== LEG B: self-hosted eval executes a real compiler stage (lexer) =="
ref_b="$(cat "$GOLDDIR/lex_probe.golden")"
self_b="$(strip_unit "$("$EVAL_MODS" "$CORE" "$LEXPROBE" "$SHDIR" "$STDLIB" 2>/dev/null)")"
if [ "$ref_b" = "$self_b" ] && [ -n "$ref_b" ]; then
  pass=$((pass+1)); printf 'ok   %-10s (self-hosted eval == golden reference)\n' "lex_probe"
else
  fail=$((fail+1)); printf 'FAIL %-10s (eval output differs / empty)\n' "lex_probe"
  printf '  ref:  %s\n' "$(printf '%s' "$ref_b"  | tr '\n' ' ')"
  printf '  self: %s\n' "$(printf '%s' "$self_b" | tr '\n' ' ')"
fi

# ── LEG C: TYPED eval runs a stage that needs return-position dispatch ─────
# The parser (compiler/frontend/parser.mdk) is built on a `Parser` monad whose
# `pure`/`andThen` are return-position method dispatch — which the UNTYPED
# eval_modules path (Leg B) cannot resolve (it panics "no matching clause").
# The TYPED multi-module path threads the marker + typecheck.elaborate route-
# stamping through the loader's module graph (eval_typed_modules_main.mdk ->
# typecheck.elaborateModules), so the self-hosted eval narrows each method site
# by its RKey route.  Running parser.mdk over an embedded snippet and matching
# the eval_modules oracle proves the typed self-hosted eval EXECUTES a real
# Parser-monad stage of the compiler's own source.
echo
echo "== LEG C: TYPED self-hosted eval executes a Parser-monad stage (parser) =="
ref_c="$(cat "$GOLDDIR/parse_probe.golden")"
self_c="$(strip_unit "$("$EVAL_TYPED_MODS" "$RUNTIME" "$CORE" "$PARSEPROBE" "$SHDIR" "$STDLIB" 2>/dev/null)")"
if [ "$ref_c" = "$self_c" ] && [ -n "$ref_c" ]; then
  pass=$((pass+1)); printf 'ok   %-10s (typed self-hosted eval == golden reference)\n' "parse_probe"
else
  fail=$((fail+1)); printf 'FAIL %-10s (typed eval output differs / empty)\n' "parse_probe"
  printf '  ref:  %s\n' "$(printf '%s' "$ref_c"  | tr '\n' ' ')"
  printf '  self: %s\n' "$(printf '%s' "$self_c" | tr '\n' ' ')"
fi

# ── LEG D: TYPED eval runs the TYPECHECKER stage (typecheck.mdk) ───────────
# The typechecker (compiler/types/typecheck.mdk) is the deepest stage to execute on
# the self-hosted eval: it drives Ref-based union-find mutation (the `<Mut>`
# effect) over a larger primitive surface than the parser, and — like the
# parser — threads return-position dispatch through its monadic surface, so the
# UNTYPED eval_modules path (Leg B) cannot run it.  The TYPED multi-module path
# (eval_typed_modules_main.mdk -> typecheck.elaborateModules) route-stamps it,
# then evalModules runs it on the self-hosted eval's <Mut> kernel.  Running
# checkToLines over an embedded snippet and matching the eval_modules oracle
# proves the typed self-hosted eval EXECUTES the typechecker stage of the
# compiler's own source — at which point EVERY monadic compiler stage runs on
# the self-hosted eval.
echo
echo "== LEG D: TYPED self-hosted eval executes the TYPECHECKER stage (typecheck) =="
ref_d="$(cat "$GOLDDIR/tc_probe.golden")"
self_d="$(strip_unit "$("$EVAL_TYPED_MODS" "$RUNTIME" "$CORE" "$TCPROBE" "$SHDIR" "$STDLIB" 2>/dev/null)")"
if [ "$ref_d" = "$self_d" ] && [ -n "$ref_d" ]; then
  pass=$((pass+1)); printf 'ok   %-10s (typed self-hosted eval == golden reference)\n' "tc_probe"
else
  fail=$((fail+1)); printf 'FAIL %-10s (typed eval output differs / empty)\n' "tc_probe"
  printf '  ref:  %s\n' "$(printf '%s' "$ref_d"  | tr '\n' ' ')"
  printf '  self: %s\n' "$(printf '%s' "$self_d" | tr '\n' ' ')"
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
