#!/bin/sh
# Round-trip gate for the Core IR S-expression serializer (STAGE2-DESIGN §2.1).
#
# The "frozen IR is faithful" property: lower a source program to Core IR,
# serialize to S-expression, parse back, evaluate, and assert the result is
# byte-identical to the reference (dev/eval_probe.exe — the AST tree-walker).
#
# This is a stronger claim than the snapshot gate (diff_selfhost_core_ir_sexp.sh):
# the snapshot just checks the dump text is stable; the round-trip checks that
# a deserialized CProgram evaluates identically to a freshly-lowered one, proving
# the serialization is semantics-faithful / lossless w.r.t. the computation.
#
# Pipeline for each fixture:
#   medaka source → lower → cprogramToSexp → parseCProgram → cevalMain → pp_value
#                       ↑                                                      ↓
#                   core_ir_roundtrip_main.mdk           diff against eval_probe
#
# Usage:  sh test/diff_selfhost_core_ir_roundtrip.sh
# Exit:   0 if every fixture passes the round-trip.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/_build/default/dev/eval_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
RT="$ROOT/selfhost/core_ir_roundtrip_main.mdk"
FIXDIR="$ROOT/test/eval_fixtures"

[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  ref="$("$PROBE" "$f" 2>/dev/null)"
  self="$("$MAIN" run "$RT" "$f" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
