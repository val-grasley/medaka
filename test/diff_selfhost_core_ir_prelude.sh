#!/bin/sh
# Prelude-loaded equivalence gate for the Core IR (STAGE2-DESIGN §2.1).
#
# Where diff_selfhost_core_ir.sh isolates the engine on prelude-free fixtures,
# this exercises real prelude dispatch — the typeclass methods defined in
# core.mdk (Eq/Ord/Debug/Display/Num + deriving) — flowing through the Core IR's
# slice-5 impl install + arg-tag VMultis, validated by EQUIVALENCE against the
# AST tree-walker over genuine stdlib code.
#
# Oracle: dev/eval_probe.exe --prelude  (the embedded core.mdk → pp_value of
# `main`) — the SAME oracle selfhost/eval_prelude_main.mdk diffs against.
# Self-host: core_ir_prelude_main.mdk prepends the *parsed* stdlib/core.mdk,
# annotates + lowers to Core IR, evaluates it; pp_value of `main` must match
# byte-for-byte.
#
# Usage:  sh test/diff_selfhost_core_ir_prelude.sh
# Exit:   0 if every fixture matches.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/_build/default/dev/eval_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
SELFMAIN="$ROOT/selfhost/core_ir_prelude_main.mdk"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_prelude_fixtures"

[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  ref="$("$PROBE" --prelude "$f" 2>/dev/null)"
  self="$("$MAIN" run "$SELFMAIN" "$CORE" "$f" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
