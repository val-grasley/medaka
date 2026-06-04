#!/bin/sh
# Validation for the self-hosted DICT-PASSING eval path: programs whose
# `=>`-constrained functions use a return-position method (empty/minBound/…) at
# the constraint variable's type — which has no discriminating argument, so plain
# arg-tag / RKey dispatch cannot resolve it.  The Monoid (etc.) dictionary the
# caller supplies must be threaded into the function body.  Oracle = the reference
# `medaka run <file>` (which dict-passes the whole program); self = the
# self-hosted dict elaboration + eval.
#
# Usage:  sh test/diff_selfhost_eval_dict.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
DICT="$ROOT/selfhost/eval_dict_main.mdk"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_dict_fixtures"
[ -x "$MAIN" ] || { echo "build first: dune build --root ."; exit 2; }
pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  ref="$("$MAIN" run "$f" 2>/dev/null)"
  self="$("$MAIN" run "$DICT" "$RT" "$CORE" "$f" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s (%s)\n' "$name" "$ref"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
