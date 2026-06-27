#!/bin/sh
# Differential validation for the self-hosted parser's NON-panicking, structured
# parse-error path (compiler/frontend/parser.mdk `parseResult`), driven by
# compiler/entries/parse_result_main.mdk.
#
# This is the LSP prerequisite (Stage 4 task #24): a parser should yield parse
# errors as DATA (a structured, located `Result ParseError (List Decl)`), not
# abort the process.  The legacy `parse` entry still panics (validated by
# diff_compiler_parse_errors.sh); `parseResult` is purely additive and must
# return a structured value instead.
#
# Per parser-error fixture, the gate asserts:
#   A. Oracle agreement — astdump.exe (the OCaml reference) reports a parse error
#      with an `L:C` location, confirming the fixture is a genuine parse error.
#   B. NO PANIC — `medaka run compiler/entries/parse_result_main.mdk <fix>` exits 0.
#      (Contrast diff_compiler_parse_errors.sh, which requires the panicking
#       parse_main to exit NON-zero on the same inputs.)
#   C. Structured + located — the driver prints `parse error L:C` with L a real
#      source line (>= the first non-comment line) and C >= 0 — i.e. the error
#      was returned as a located `ParseError`, not blanked or mislocated to 1:0.
#   D. Valid-file sanity — a well-formed program yields `ok` (exit 0).
#
# Why this gate does NOT require byte-exact L:C parity with the oracle:
#   The OCaml parser is Menhir-generated; its reported column is `lex_curr_p`
#   (the cursor AFTER the lookahead token that wedged the LR automaton).  The
#   self-hosted recursive-descent combinator instead reports the offset of the
#   token where a parse function gave up (often the operator or the leftover
#   token).  These are structurally different cursors and cannot be aligned
#   without rewriting the combinator's failure positions — out of scope for an
#   ADDITIVE error-as-value entry.  The oracle's L:C is recorded per fixture for
#   transparency (line agreement is reported, not enforced).  See the matching
#   note in diff_compiler_parse_errors.sh.
#
# Usage:  sh test/diff_compiler_parse_result.sh
# Exit:   0 if every fixture passes, else 1.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/parse_result_main"
FIXDIR="$ROOT/test/parse_error_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# run_self drops the native value entry's trailing "()" (Unit return;
# runtime/medaka_rt.c) so the structured `parse error L:C` / `ok` line stands alone.
run_self() { perl -e 'alarm 120; exec @ARGV' "$RUN" "$1" 2>&1 | sed '$ s/()$//; ${/^$/d;}'; }

# OCaml-oracle L:C, frozen per fixture in <name>.parse_result_oracle by
# test/capture_goldens.sh (REROOT-PLAN §2b).  Confirms the fixture is a genuine
# located parse error; the self-host location is NOT required to match.
oracle_lc() {
  golden="${1%.mdk}.parse_result_oracle"
  [ -f "$golden" ] && cat "$golden"
}

# The parser-error fixtures (lexer-error fixtures are excluded: the
# self-hosted lexer aborts on those before the parser runs).
PARSER_FIXTURES="bad_second_decl dangling_plus leading_rparen"

pass=0; fail=0

for name in $PARSER_FIXTURES; do
  f="$FIXDIR/$name.mdk"
  [ -f "$f" ] || { fail=$((fail+1)); printf 'FAIL %s (missing fixture)\n' "$name"; continue; }

  ok=1; reason=""

  # A. Oracle must report a parse error with a location.
  olc="$(oracle_lc "$f")"
  [ -n "$olc" ] || { ok=0; reason="oracle did not report a located parse error"; }

  # B. + C. Self-hosted parseResult: exit 0 (no panic) + structured `parse error L:C`.
  if [ "$ok" -eq 1 ]; then
    sout="$(run_self "$f")"; scode=$?
    if [ "$scode" -ne 0 ]; then
      ok=0; reason="compiler exited $scode (parseResult must NOT panic; out=[$sout])"
    else
      slc="$(printf '%s\n' "$sout" | sed -n 's/^parse error \([0-9]*:[0-9]*\)$/\1/p' | head -1)"
      if [ -z "$slc" ]; then
        ok=0; reason="compiler did not emit a structured 'parse error L:C' (got [$sout])"
      else
        sline="${slc%%:*}"; scol="${slc##*:}"
        # Real source begins after the 2-line `-- …` header in each fixture.
        if [ "$sline" -lt 3 ] 2>/dev/null; then
          ok=0; reason="located line $sline is not a real source line (header is 1-2)"
        elif [ "$scol" -lt 0 ] 2>/dev/null; then
          ok=0; reason="located col $scol < 0"
        fi
      fi
    fi
  fi

  if [ "$ok" -eq 1 ]; then
    pass=$((pass+1))
    # Report oracle-vs-self for transparency; line agreement noted, not enforced.
    oline="${olc%%:*}"
    if [ "$oline" = "$sline" ]; then agree="line✓"; else agree="line oracle=$oline self=$sline"; fi
    printf 'ok   %-18s oracle=%-7s self=%-7s (%s)\n' "$name" "$olc" "$slc" "$agree"
  else
    fail=$((fail+1)); printf 'FAIL %-18s (%s)\n' "$name" "$reason"
  fi
done

# D. Valid-file sanity: a well-formed program must parse to `ok` with no panic.
GOOD="$(mktemp -t pr_good.XXXXXX).mdk"
printf 'f = 1\ng x = x + 1\n' > "$GOOD"
gout="$(run_self "$GOOD")"; gcode=$?
rm -f "$GOOD"
if [ "$gcode" -eq 0 ] && [ "$gout" = "ok" ]; then
  pass=$((pass+1)); printf 'ok   %-18s (valid file -> ok)\n' "valid_program"
else
  fail=$((fail+1)); printf 'FAIL %-18s (got [%s] exit %s, want ok)\n' "valid_program" "$gout" "$gcode"
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
