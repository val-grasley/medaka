#!/bin/sh
# §2.3 item 2 — dict-passing corpus through the TYPED bytecode VM.
#
# Uses selfhost/eval_bytecode_typed_dict_main.mdk as the self-hosted driver:
#   desugar → elaborateDict (typecheck stamps routes, dict_pass prepends leading
#   dict params) → lowerProgram → bcEvalOutput
#
# Oracle: `medaka run <fixture>` (the reference OCaml interpreter, which also
# dict-passes the whole program via elaborateDict in its typed path).
# All 17 fixtures in test/eval_dict_fixtures/ must match byte-for-byte.
#
# Usage:  sh test/diff_selfhost_bytecode_eval_dict.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
DICT_BC="$ROOT/selfhost/eval_bytecode_typed_dict_main.mdk"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_dict_fixtures"
[ -x "$MAIN" ] || { echo "build first: dune build --root ."; exit 2; }
[ -f "$DICT_BC" ] || { echo "missing $DICT_BC"; exit 2; }
pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  ref="$("$MAIN" run "$f" 2>/dev/null)"
  self="$("$MAIN" run "$DICT_BC" "$RT" "$CORE" "$f" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s (%s)\n' "$name" "$ref"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
