#!/bin/sh
# Equivalence gate for the Core IR (STAGE2-DESIGN §2.1).
#
# There is no OCaml reference for Core IR — it is a net-new IR.  So it is
# validated by EQUIVALENCE, not against a bespoke oracle: lower the elaborated
# AST to Core IR (core_ir_lower.mdk), evaluate the Core IR (core_ir_eval.mdk),
# and diff its pp_value against the AST tree-walker — dev/eval_probe.exe, the
# SAME oracle selfhost/eval_main.mdk uses.  Core IR is correct iff evaluating it
# matches evaluating the AST.
#
# Scope: the FULL prelude-free engine corpus in test/eval_fixtures/ — slices 1
# (engine core), 3 (records / refs / arrays / ranges / index / slice / blocks)
# and 5 (typeclass dispatch via installed arg-tag VMultis) all covered, so this
# now mirrors selfhost/eval_main.mdk's diff_selfhost_eval.sh fixture-for-fixture.
#
# Usage:  sh test/diff_selfhost_core_ir.sh
# Exit:   0 if every fixture matches the tree-walker.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/_build/default/dev/eval_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
SELFMAIN="$ROOT/selfhost/core_ir_main.mdk"
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
