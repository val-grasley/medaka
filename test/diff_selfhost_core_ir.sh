#!/bin/sh
# Equivalence gate for the Core IR (STAGE2-DESIGN §2.1, slice 1).
#
# There is no OCaml reference for Core IR — it is a net-new IR.  So it is
# validated by EQUIVALENCE, not against a bespoke oracle: lower the elaborated
# AST to Core IR (core_ir_lower.mdk), evaluate the Core IR (core_ir_eval.mdk),
# and diff its pp_value against the AST tree-walker — dev/eval_probe.exe, the
# SAME oracle selfhost/eval_main.mdk uses.  Core IR is correct iff evaluating it
# matches evaluating the AST.
#
# Scope: SLICE 1 (engine core) — the prelude-free fixtures in test/eval_fixtures/
# whose nodes the Core IR evaluator covers (literals, vars, app, lambdas,
# let/letrec/let-groups, match+guards, if, primitive binops, unary ops, tuples,
# lists, ADTs, blocks, externs).  Fixtures needing records/refs/arrays/ranges
# (slice 3) or typeclass dispatch (slice 5) are intentionally NOT listed yet;
# add them here as those slices land.  (The full eval_fixtures set is the
# eventual target — see selfhost/eval_main.mdk's diff_selfhost_eval.sh.)
#
# Usage:  sh test/diff_selfhost_core_ir.sh
# Exit:   0 if every listed fixture matches the tree-walker.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/_build/default/dev/eval_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
SELFMAIN="$ROOT/selfhost/core_ir_main.mdk"
FIXDIR="$ROOT/test/eval_fixtures"

[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }

# slice-1 supported fixtures
SLICE1="adt_nested guarded_clauses letrec_mutual shadow_closure patterns_misc \
hof_compose list_ops guards_where string_kernel"

pass=0; fail=0
for name in $SLICE1; do
  f="$FIXDIR/$name.mdk"
  [ -f "$f" ] || { echo "MISSING $name.mdk"; fail=$((fail+1)); continue; }
  ref="$("$PROBE" "$f" 2>/dev/null)"
  self="$("$MAIN" run "$SELFMAIN" "$f" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing (slice 1)\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
