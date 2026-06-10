#!/bin/sh
# Differential validation for the self-hosted eval stage: RUNTIME ERROR messages.
#
# Each fixture in test/eval_error_fixtures/ is a program that type-checks but
# fails at evaluation time.  A committed <name>.expected golden holds the
# normalized error message text (no location, no "panic:" prefix).
#
# Per fixture, three checks:
#   A. Oracle stability — main.exe run <fixture> must produce the expected message
#      on stderr (ensures the golden matches the reference OCaml eval).
#   B. Self-hosted must exit non-zero on the bad input.
#   C. Self-hosted message must equal the golden.
#
# Normalization — both sides produce an stderr line of the form:
#   Reference: "file:line:col: panic: MESSAGE"
#   Selfhost:  "file:line:col: panic: panic: MESSAGE"
# The greedy ".*panic: " strips everything up to and including the final
# "panic: " prefix, leaving just MESSAGE, making both sides directly comparable.
#
# Usage:  sh test/diff_selfhost_eval_errors.sh
# Exit:   0 if every fixture passes, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
EVALM="$ROOT/selfhost/eval_main.mdk"
FIXDIR="$ROOT/test/eval_error_fixtures"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }

# Extract the error message from a "…: panic: MESSAGE" or "error: MESSAGE" stderr line.
# Greedy ".*panic: " matches up to and including the final "panic: " on the line.
# The "error: MESSAGE" branch handles oracle errors that are not runtime panics
# (e.g. "program has no 'main' binding" which main.exe emits as "error: …").
norm_msg() {
  grep -E "panic:|^error:" | head -1 | sed -E 's/.*panic: //; s/^error: //'
}

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "${f%.mdk}")"
  golden_file="${f%.mdk}.expected"
  golden="$(cat "$golden_file" | tr -d '\n')"

  ok=1; reason=""

  # A. Oracle (main.exe run <fixture>) must match golden
  oracle_out="$("$MAIN" run "$f" 2>&1 | norm_msg)"
  [ "$oracle_out" = "$golden" ] || { ok=0; reason="oracle: got \"$oracle_out\" want \"$golden\""; }

  # B. Self-hosted must exit non-zero
  if [ "$ok" -eq 1 ]; then
    "$MAIN" run "$EVALM" "$f" >/dev/null 2>&1
    exit_code=$?
    [ "$exit_code" -ne 0 ] || { ok=0; reason="selfhost exited 0 (should error)"; }
  fi

  # C. Self-hosted message must match golden
  if [ "$ok" -eq 1 ]; then
    self_out="$("$MAIN" run "$EVALM" "$f" 2>&1 >/dev/null | norm_msg)"
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
