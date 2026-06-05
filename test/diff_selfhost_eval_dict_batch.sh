#!/bin/sh
# Batched variant of diff_selfhost_eval_dict.sh — prelude caching.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
BATCH="$ROOT/selfhost/eval_dict_batch.mdk"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_dict_fixtures"
[ -x "$MAIN" ] || { echo "build first: dune build --root ."; exit 2; }

targets=""
for f in "$FIXDIR"/*.mdk; do [ -f "$f" ] && targets="$targets $f"; done

ALL="$("$MAIN" run "$BATCH" "$RT" "$CORE" $targets 2>/dev/null)"
section() { awk -v p="$1" '$0=="===SELFHOST-FIX=== "p {f=1;next} /^===SELFHOST-FIX=== /{f=0} f'; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  ref="$("$MAIN" run "$f" 2>/dev/null)"
  self="$(printf '%s' "$ALL" | section "$f")"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s (%s)\n' "$name" "$ref"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
