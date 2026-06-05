#!/bin/sh
# Differential validation for the self-hosted parser/lexer *rejection* path.
#
# Each fixture in test/parse_error_fixtures/ is a deliberately malformed .mdk
# program with a committed <name>.expected golden (the normalized error message).
#
# Per fixture, three checks:
#   A. Oracle stability — astdump.exe must agree with the committed golden
#      (ensures the golden is correct and stays in sync with the reference).
#   B. Self-hosted rejection — medaka run selfhost/parse_main.mdk must exit
#      non-zero on the bad input.
#   C. Self-hosted message — the self-hosted panic message must equal the golden.
#
# Normalization:
#   Oracle   (astdump stderr): "Fatal error: exception Failure("MESSAGE")" → MESSAGE,
#            then strip the trailing " L:C" location suffix from parse-error messages
#            (the self-hosted combinator parser cannot reconstruct the exact byte
#            offset the Menhir-generated OCaml parser reports).
#   Selfhost (medaka run stderr): "file:line:col: panic: panic: MESSAGE" → MESSAGE,
#            extracted by taking the first panic-bearing line and stripping the prefix.
#
# Usage:  sh test/diff_selfhost_parse_errors.sh
# Exit:   0 if every fixture passes, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="$ROOT/_build/default/dev/astdump.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
PARSEMAIN="$ROOT/selfhost/parse_main.mdk"
FIXDIR="$ROOT/test/parse_error_fixtures"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
[ -x "$REF"  ] || { echo "build first: dune build --root . (missing $REF)";  exit 2; }

# Extract the error message from astdump's Fatal-error stderr line, then strip
# any trailing " L:C" location suffix from parse-error messages.
norm_oracle() {
  grep "^Fatal error:" | head -1 \
    | sed 's/^Fatal error: exception Failure("//;s/")$//' \
    | sed 's/^\(parse error\) [0-9]*:[0-9]*/\1/'
}

# Extract the error message from medaka run's panic stderr line.
# Format: "file:line:col: panic: panic: MESSAGE [newline context block]"
# The greedy ".*panic: " eats up to and including the final "panic: ", leaving MESSAGE.
norm_self() {
  grep "panic:" | head -1 | sed 's/.*panic: //'
}

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "${f%.mdk}")"
  golden_file="${f%.mdk}.expected"
  golden="$(cat "$golden_file" | tr -d '\n')"

  ok=1; reason=""

  # A. Oracle must match golden
  oracle_out="$("$REF" "$f" 2>&1 | norm_oracle)"
  [ "$oracle_out" = "$golden" ] || { ok=0; reason="oracle: got \"$oracle_out\" want \"$golden\""; }

  # B. Self-hosted must exit non-zero
  if [ "$ok" -eq 1 ]; then
    "$MAIN" run "$PARSEMAIN" "$f" >/dev/null 2>&1
    exit_code=$?
    [ "$exit_code" -ne 0 ] || { ok=0; reason="selfhost exited 0 (should reject)"; }
  fi

  # C. Self-hosted message must match golden
  if [ "$ok" -eq 1 ]; then
    self_out="$("$MAIN" run "$PARSEMAIN" "$f" 2>&1 >/dev/null | norm_self)"
    [ "$self_out" = "$golden" ] || { ok=0; reason="selfhost: got \"$self_out\" want \"$golden\""; }
  fi

  if [ "$ok" -eq 1 ]; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'FAIL %s (%s)\n' "$name" "$reason"
  fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
