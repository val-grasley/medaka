#!/bin/sh
# Round-trip gate for the Core IR S-expression serializer (STAGE2-DESIGN §2.1).
#
# The "frozen IR is faithful" property: lower a source program to Core IR,
# serialize to S-expression, parse back, evaluate, and assert the result is
# byte-identical to the reference — the committed test/eval_fixtures/<name>.eval.golden
# (captured from dev/eval_probe.exe, the AST tree-walker).
#
# This is a stronger claim than the snapshot gate (diff_compiler_snapshot_core_ir.sh):
# the round-trip checks that a deserialized CProgram evaluates identically to a
# freshly-lowered one, proving the serialization is semantics-faithful / lossless.
#
# Pipeline for each fixture:
#   medaka source → lower → cprogramToSexp → parseCProgram → cevalMain → pp_value
#                       ↑                                                      ↓
#                test/bin/core_ir_roundtrip_main                  diff against golden
#
# OCaml-free (REROOT-PLAN.md Phase 2): runs as the pre-compiled native binary
# test/bin/core_ir_roundtrip_main (built by build_oracles.sh).
#
# Usage:  sh test/diff_compiler_core_ir_roundtrip.sh
# Exit:   0 if every fixture passes the round-trip.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RT="$ROOT/test/bin/core_ir_roundtrip_main"
FIXDIR="$ROOT/test/eval_fixtures"

[ -x "$RT" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RT)"; exit 2; }
strip_unit() { sed '${/^()$/d;}'; }  # drop native runtime's trailing Unit auto-print

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.eval.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh)"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  self="$("$RT" "$f" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
