#!/bin/sh
# THE SELF-PROCESSING CLOSURE — the decisive self-hosting milestone
# (selfhost/README.md §"The bootstrap (#3)" -> "Self-processing target").
#
# Runs the self-hosted compiler over the selfhost/*.mdk sources THEMSELVES and
# diffs against the OCaml reference doing the same.  Two legs:
#
#  LEG A — front-end "checks itself" (typecheck closure).
#    Feeds the WHOLE selfhost source through the self-hosted multi-module
#    front-end (loader -> desugar -> checkModules) in ONE process, using
#    selfhost/all_modules_entry.mdk as the aggregate entry (its imports force
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
#    Runs a real selfhost stage module (the lexer) through the SELF-HOSTED eval
#    path (eval.mdk's evalModules) over an embedded Medaka snippet, and diffs its
#    token stream against the eval_modules oracle (`medaka run <probe>` = OCaml
#    Loader -> typecheck -> eval_modules).  Byte-identical output proves the
#    self-hosted untyped evaluator correctly EXECUTES a real selfhost stage.
#    (The parser/typecheck stages use return-position Parser-monad dispatch the
#    untyped self-hosted eval cannot yet resolve — see PLAN.md; the lexer uses
#    none, so it is the executable slice today.)
#
# Usage:  sh test/diff_selfhost_selfproc.sh
# Exit:   0 iff every module's front-end output matches AND the eval leg matches.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
PROBE="$ROOT/_build/default/dev/tc_module_probe.exe"
CHECK_ALL="$ROOT/selfhost/check_all_main.mdk"
EVAL_MODS="$ROOT/selfhost/eval_modules_main.mdk"
EVAL_TYPED_MODS="$ROOT/selfhost/eval_typed_modules_main.mdk"
ENTRY="$ROOT/selfhost/all_modules_entry.mdk"
LEXPROBE="$ROOT/selfhost/selfproc_lex_probe.mdk"
PARSEPROBE="$ROOT/selfhost/selfproc_parse_probe.mdk"
TCPROBE="$ROOT/selfhost/selfproc_tc_probe.mdk"
CORE="$ROOT/stdlib/core.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
SHDIR="$ROOT/selfhost"
[ -x "$MAIN" ]  || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }
for f in "$CHECK_ALL" "$EVAL_MODS" "$EVAL_TYPED_MODS" "$ENTRY" "$LEXPROBE" "$PARSEPROBE" "$TCPROBE"; do
  [ -f "$f" ] || { echo "missing $f"; exit 2; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# ── LEG A: front-end self-processing (typecheck closure) ───────────────────
echo "== LEG A: self-hosted front-end typechecks its own source =="
MODULES="ast lexer parser sexp desugar marker resolve exhaust loader typecheck eval check"

# One full-closure run emits every module's schemes (sections marked
# `## MODULE <mid>`).  all_modules_entry imports one name from each module so the
# loader pulls them all into a single union closure.
"$MAIN" run "$CHECK_ALL" "$RUNTIME" "$CORE" "$ENTRY" "$SHDIR" 2>/dev/null > "$TMP/all.txt"

# Extract module <mid>'s section (lines between its marker and the next).
section() {  # section <dumpfile> <mid>
  awk -v M="$2" '/^## MODULE /{cur=($3==M)?1:0; next} cur{print}' "$1"
}

for m in $MODULES; do
  [ -f "$SHDIR/$m.mdk" ] || continue
  if ! grep -q "^## MODULE $m\$" "$TMP/all.txt"; then
    fail=$((fail+1)); printf 'FAIL %-10s (not covered by aggregate entry closure)\n' "$m"; continue
  fi
  self="$(section "$TMP/all.txt" "$m" | LC_ALL=C sort)"
  ref="$("$PROBE" "$SHDIR/$m.mdk" "$SHDIR" 2>/dev/null | LC_ALL=C sort)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %-10s (schemes match reference)\n' "$m"
  else fail=$((fail+1)); printf 'FAIL %-10s (schemes differ from reference)\n' "$m"; fi
done

# ── LEG B: eval engine self-execution (eval_modules over a real stage) ─────
echo
echo "== LEG B: self-hosted eval executes a real selfhost stage (lexer) =="
ref_b="$("$MAIN" run "$LEXPROBE" 2>/dev/null)"
self_b="$("$MAIN" run "$EVAL_MODS" "$CORE" "$LEXPROBE" "$SHDIR" 2>/dev/null)"
if [ "$ref_b" = "$self_b" ] && [ -n "$ref_b" ]; then
  pass=$((pass+1)); printf 'ok   %-10s (self-hosted eval == eval_modules oracle)\n' "lex_probe"
else
  fail=$((fail+1)); printf 'FAIL %-10s (eval output differs / empty)\n' "lex_probe"
  printf '  ref:  %s\n' "$(printf '%s' "$ref_b"  | tr '\n' ' ')"
  printf '  self: %s\n' "$(printf '%s' "$self_b" | tr '\n' ' ')"
fi

# ── LEG C: TYPED eval runs a stage that needs return-position dispatch ─────
# The parser (selfhost/parser.mdk) is built on a `Parser` monad whose
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
ref_c="$("$MAIN" run "$PARSEPROBE" 2>/dev/null)"
self_c="$("$MAIN" run "$EVAL_TYPED_MODS" "$RUNTIME" "$CORE" "$PARSEPROBE" "$SHDIR" 2>/dev/null)"
if [ "$ref_c" = "$self_c" ] && [ -n "$ref_c" ]; then
  pass=$((pass+1)); printf 'ok   %-10s (typed self-hosted eval == eval_modules oracle)\n' "parse_probe"
else
  fail=$((fail+1)); printf 'FAIL %-10s (typed eval output differs / empty)\n' "parse_probe"
  printf '  ref:  %s\n' "$(printf '%s' "$ref_c"  | tr '\n' ' ')"
  printf '  self: %s\n' "$(printf '%s' "$self_c" | tr '\n' ' ')"
fi

# ── LEG D: TYPED eval runs the TYPECHECKER stage (typecheck.mdk) ───────────
# The typechecker (selfhost/typecheck.mdk) is the deepest stage to execute on
# the self-hosted eval: it drives Ref-based union-find mutation (the `<Mut>`
# effect) over a larger primitive surface than the parser, and — like the
# parser — threads return-position dispatch through its monadic surface, so the
# UNTYPED eval_modules path (Leg B) cannot run it.  The TYPED multi-module path
# (eval_typed_modules_main.mdk -> typecheck.elaborateModules) route-stamps it,
# then evalModules runs it on the self-hosted eval's <Mut> kernel.  Running
# checkToLines over an embedded snippet and matching the eval_modules oracle
# proves the typed self-hosted eval EXECUTES the typechecker stage of the
# compiler's own source — at which point EVERY monadic selfhost stage runs on
# the self-hosted eval.
echo
echo "== LEG D: TYPED self-hosted eval executes the TYPECHECKER stage (typecheck) =="
ref_d="$("$MAIN" run "$TCPROBE" 2>/dev/null)"
self_d="$("$MAIN" run "$EVAL_TYPED_MODS" "$RUNTIME" "$CORE" "$TCPROBE" "$SHDIR" 2>/dev/null)"
if [ "$ref_d" = "$self_d" ] && [ -n "$ref_d" ]; then
  pass=$((pass+1)); printf 'ok   %-10s (typed self-hosted eval == eval_modules oracle)\n' "tc_probe"
else
  fail=$((fail+1)); printf 'FAIL %-10s (typed eval output differs / empty)\n' "tc_probe"
  printf '  ref:  %s\n' "$(printf '%s' "$ref_d"  | tr '\n' ' ')"
  printf '  self: %s\n' "$(printf '%s' "$self_d" | tr '\n' ' ')"
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
