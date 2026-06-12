#!/bin/sh
# Differential validation for the self-hosted TYPECHECK stage's ERROR PATH on
# shapes that resolve normally pre-screens — TYPECHECK-AUDIT finding D1.
#
# These programs reference an unknown constructor / record / field, or an
# unbound variable.  In the FULL front-end (selfhost/tools/check.mdk) resolve catches
# them first, so the typecheck stage never sees them.  But on the no-resolve
# differential path (dev/tc_probe.exe oracle vs selfhost/typecheck_main.mdk) the
# typecheck stage IS the one that reaches the error.  Before D1 the self-hosted
# typechecker PANICKED (uncatchable interpreter abort) on these; the oracle
# accumulates a `TYPE ERROR: …`.  D1 converts those panics into accumulated
# `typeErrors` entries with byte-identical messages + a fresh-var placeholder so
# inference continues — this harness pins that parity (no panic, == oracle).
#
# Driver: typecheck_main.mdk (bare HM, NO prelude, matches tc_probe.exe).
# The full-front-end check.mdk driver is deliberately NOT tested here: it stops
# at resolve for these shapes (resolve diagnostics, different format), which is
# correct and orthogonal to D1.
#
# Usage:  sh test/diff_selfhost_typecheck_panic_errors.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/_build/default/dev/tc_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
SELF="$ROOT/selfhost/typecheck_main.mdk"
FIXDIR="$ROOT/test/typecheck_panic_fixtures"
[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }
[ -x "$MAIN" ]  || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  ref="$("$PROBE" "$f" 2>/dev/null | LC_ALL=C sort)"
  self="$("$MAIN" run "$SELF" "$f" 2>/dev/null | LC_ALL=C sort)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  --- ref ---\n%s\n  --- self ---\n%s\n' "$name" "$ref" "$self"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
