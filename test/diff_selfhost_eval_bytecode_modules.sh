#!/bin/sh
# Slice 6 of Stage 2 §2.2 bytecode VM: multi-module per-module frames.
# eval_bytecode_modules_main.mdk loads <entry> + its transitive imports,
# desugars + annotates each, LOWERS them per-module to Core IR and evaluates
# them in per-module bytecode frames over the shared prelude
# (bytecode.bcEvalModulesOutput), printing the root module's `main` stdout.
# Diffs byte-for-byte against `medaka run <entry>` — the SAME oracle
# diff_selfhost_eval_modules.sh and diff_selfhost_core_ir_modules.sh use.
#
# Usage:  sh test/diff_selfhost_eval_bytecode_modules.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
SELF="$ROOT/selfhost/eval_bytecode_modules_main.mdk"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_modules_fixtures"
[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }

pass=0; fail=0
for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  entry="$(ls "$dir"main_*.mdk 2>/dev/null | head -1)"
  [ -n "$entry" ] || { echo "skip $(basename "$dir") (no main_*.mdk)"; continue; }
  name="$(basename "$dir")"
  ref="$("$MAIN" run "$entry" 2>&1)"
  self="$("$MAIN" run "$SELF" "$CORE" "$entry" "${dir%/}" 2>&1)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '  ref:  %s\n' "$ref"
    printf '  self: %s\n' "$self"
  fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
