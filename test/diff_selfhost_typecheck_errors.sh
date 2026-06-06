#!/bin/sh
# Differential validation for self-hosted TYPE ERROR accumulation.
#
# Oracle: dev/tc_probe.exe  (parse → Desugar → check_program_no_prelude,
# catches the first Type_error exception and prints "TYPE ERROR: <msg>").
#
# For each deliberately ill-typed fixture in test/typecheck_error_fixtures/,
# both the self-hosted and the reference must emit identical "TYPE ERROR: …"
# output.  Both sides are sorted before comparison (order doesn't matter for
# single-error fixtures).
#
# Two drivers tested:
#   A. typecheck_main.mdk  — bare HM engine, no prelude, matches tc_probe.exe
#   B. check.mdk           — full composed front-end with prelude; same error
#
# Usage:  sh test/diff_selfhost_typecheck_errors.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
TC="$ROOT/_build/default/dev/tc_probe.exe"
TC_MAIN="$ROOT/selfhost/typecheck_main.mdk"
CHECK="$ROOT/selfhost/check.mdk"
RT="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/typecheck_error_fixtures"

[ -x "$MAIN" ] || { echo "build first: dune build --root ."; exit 2; }
[ -x "$TC"   ] || { echo "build first: dune build --root ."; exit 2; }

pass=0; fail=0

for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  ref="$("$TC" "$f" 2>/dev/null | LC_ALL=C sort)"

  # Driver A: typecheck_main (bare HM, no prelude)
  selfA="$("$MAIN" run "$TC_MAIN" "$f" 2>/dev/null | LC_ALL=C sort)"
  if [ "$selfA" = "$ref" ]; then
    pass=$((pass+1)); printf 'ok   tc_main/%s\n' "$name"
  else
    fail=$((fail+1))
    printf 'FAIL tc_main/%s\n  self: %s\n   ref: %s\n' "$name" "$selfA" "$ref"
  fi

  # Driver B: check.mdk (full front-end with prelude)
  selfB="$("$MAIN" run "$CHECK" "$RT" "$CORE" "$f" 2>/dev/null | LC_ALL=C sort)"
  if [ "$selfB" = "$ref" ]; then
    pass=$((pass+1)); printf 'ok   check/%s\n' "$name"
  else
    fail=$((fail+1))
    printf 'FAIL check/%s\n  self: %s\n   ref: %s\n' "$name" "$selfB" "$ref"
  fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
