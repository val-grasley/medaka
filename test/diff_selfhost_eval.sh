#!/bin/sh
# Differential validation for the self-hosted EVAL stage (SLICE 1: engine core).
#
# Oracle: dev/eval_probe.exe  (parse → desugar → Eval.eval_program ~prelude:false
# → Eval.pp_value of the `main` binding).  This isolates the eval ENGINE from the
# prelude/dispatch layer: fixtures in test/eval_fixtures/ are self-contained /
# prelude-free and aggregate their results into a single `main` value.
#
# For each fixture:  the self-hosted eval (selfhost/eval_main.mdk) must render
# the SAME pp_value as the oracle.  (`otherwise = True` is injected on both sides
# so guards read naturally; everything else the fixture must define itself.)
#
# Usage:  sh test/diff_selfhost_eval.sh
# Exit:   0 if every fixture matches.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/_build/default/dev/eval_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
SELFMAIN="$ROOT/selfhost/eval_main.mdk"
FIXDIR="$ROOT/test/eval_fixtures"

[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  ref="$("$PROBE" "$f" 2>/dev/null)"
  self="$("$MAIN" run "$SELFMAIN" "$f" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
