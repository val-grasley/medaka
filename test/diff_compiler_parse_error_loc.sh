#!/bin/sh
# test/diff_compiler_parse_error_loc.sh — regression gate for bug P0-11.
#
# Body-level parse errors used to ALL report at the declaration head
# (`file:1:0: unexpected `main``) because `orElse`/`many` backtracking discarded
# the furthest-reached failure position (see compiler/frontend/parser.mdk
# `orElseR` + `deepenLeftover`).  The fix makes `orElse` keep the deeper of two
# failed alternatives and re-runs `parseDecl` at the leftover cursor to recover
# the offending-token location.
#
# Each fixture in test/parse_error_loc_fixtures/ is a program whose syntax error
# is on a body line (NOT the decl head).  Its committed <name>.expected holds the
# 1-based `L:C` at which the FIXED compiler locates the error, derived from
# `medaka check --json`'s first-diagnostic start (`line`+1, `character`).
#
# Per fixture the gate asserts:
#   A. `check --json` emits a first diagnostic whose start L:C == the golden, AND
#   B. that L:C is NOT `1:0` (the pre-fix decl-head collapse P0-11 locked out).
#
# Regenerate goldens after an intentional location change:
#   sh test/diff_compiler_parse_error_loc.sh --capture
#
# Usage:  sh test/diff_compiler_parse_error_loc.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="$ROOT/medaka"
FIXDIR="$ROOT/test/parse_error_loc_fixtures"
CAPTURE=0
[ "${1:-}" = "--capture" ] && CAPTURE=1

[ -x "$NATIVE" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }
[ -d "$FIXDIR" ] || { echo "FAIL: missing $FIXDIR"; exit 1; }

export MEDAKA_ROOT="$ROOT"

# 1-based L:C of the first diagnostic's start from `check --json`.
first_lc() {
  perl -e 'alarm 60; exec @ARGV' "$NATIVE" check --json "$1" 2>&1 \
    | perl -ne 'if(/"start":\{"character":(\d+),"line":(\d+)\}/){print(($2+1).":".$1);exit}'
}

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .mdk)"
  golden_file="${f%.mdk}.expected"
  lc="$(first_lc "$f")"

  if [ "$CAPTURE" -eq 1 ]; then
    printf '%s\n' "$lc" > "$golden_file"
    printf 'captured %-20s %s\n' "$name" "$lc"
    continue
  fi

  [ -f "$golden_file" ] || { fail=$((fail+1)); printf 'FAIL %-20s (missing golden)\n' "$name"; continue; }
  want="$(cat "$golden_file" | tr -d '\n')"

  if [ -z "$lc" ]; then
    fail=$((fail+1)); printf 'FAIL %-20s (no diagnostic emitted)\n' "$name"
  elif [ "$lc" = "1:0" ]; then
    fail=$((fail+1)); printf 'FAIL %-20s (P0-11 regression: located at decl head 1:0)\n' "$name"
  elif [ "$lc" != "$want" ]; then
    fail=$((fail+1)); printf 'FAIL %-20s (got %s want %s)\n' "$name" "$lc" "$want"
  else
    pass=$((pass+1)); printf 'ok   %-20s %s\n' "$name" "$lc"
  fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
