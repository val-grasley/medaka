#!/bin/sh
# Equivalence gate for the Core IR (STAGE2-DESIGN §2.1).
#
# There is no OCaml reference for Core IR — it is a net-new IR.  So it is
# validated by EQUIVALENCE: lower the elaborated AST to Core IR
# (core_ir_lower.mdk), evaluate the Core IR (core_ir_eval.mdk), and diff its
# pp_value against the AST tree-walker reference — the committed
# test/eval_fixtures/<name>.eval.golden (captured from dev/eval_probe.exe, the
# SAME oracle diff_selfhost_eval.sh uses).  Core IR is correct iff evaluating it
# matches evaluating the AST.
#
# Scope: the FULL prelude-free engine corpus in test/eval_fixtures/.
#
# OCaml-free (REROOT-PLAN.md Phase 2): the self-hosted Core-IR eval runs as the
# pre-compiled native binary test/bin/core_ir_main (built by build_oracles.sh).
#
# Usage:  sh test/diff_selfhost_core_ir.sh
# Exit:   0 if every fixture matches the golden.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/core_ir_main"
FIXDIR="$ROOT/test/eval_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }
strip_unit() { sed '${/^()$/d;}'; }  # drop native runtime's trailing Unit auto-print

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.eval.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh)"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  self="$("$RUN" "$f" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
