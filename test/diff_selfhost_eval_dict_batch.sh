#!/bin/sh
# Batched variant of diff_compiler_eval_dict.sh — prelude caching.
#
# OCaml-free (REROOT-PLAN.md Phase 2): one process, the pre-compiled native binary
# test/bin/eval_dict_batch (built by test/build_oracles.sh).  Reference is the
# committed <name>.eval.golden (captured from `main.exe run <file>`).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BATCH="$ROOT/test/bin/eval_dict_batch"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_dict_fixtures"
[ -x "$BATCH" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $BATCH)"; exit 2; }

targets=""
for f in "$FIXDIR"/*.mdk; do [ -f "$f" ] && targets="$targets $f"; done

ALL="$("$BATCH" "$RT" "$CORE" $targets 2>/dev/null | sed '${/^()$/d;}')"
section() { awk -v p="$1" '$0=="===SELFHOST-FIX=== "p {f=1;next} /^===SELFHOST-FIX=== /{f=0} f'; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.eval.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh)"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  self="$(printf '%s' "$ALL" | section "$f")"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s (%s)\n' "$name" "$ref"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
