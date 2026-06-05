#!/bin/sh
# TYPED Core IR equivalence gate (STAGE2-DESIGN §2.1) — the Core-IR analog of
# diff_selfhost_eval_typed.sh.  Drives the only path that exercises the Core-IR
# evaluator's CMethod arm: return-position dispatch (RKey).  These programs use a
# USER monad (Box) whose `pure` / do-blocks dispatch by the RETURN type, which the
# untyped arg-tag fallback gets wrong — so they validate that lowering the
# typechecker's stamped EMethodAt routes into immutable CMethod nodes and
# narrowing them in ceval reproduces the reference exactly.
#
# Oracle: the reference TYPED path — `medaka run <file>` stdout (the SAME oracle
# selfhost/eval_typed_main.mdk uses).
#
# Usage:  sh test/diff_selfhost_core_ir_typed.sh
# Exit:   0 if every fixture matches.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
TYPED="$ROOT/selfhost/core_ir_typed_main.mdk"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_typed_fixtures"
[ -x "$MAIN" ] || { echo "build first: dune build --root ."; exit 2; }
pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  ref="$("$MAIN" run "$f" 2>/dev/null)"
  self="$("$MAIN" run "$TYPED" "$RT" "$CORE" "$f" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s (%s)\n' "$name" "$ref"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
