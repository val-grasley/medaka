#!/bin/sh
# Batched variant of diff_compiler_eval_list.sh — prelude caching.
#
# OCaml-free (REROOT-PLAN.md Phase 2): one process, the pre-compiled native binary
# test/bin/eval_list_batch (built by test/build_oracles.sh), parses core.mdk +
# list.mdk once and runs every fixture, splitting its delimited output.  Reference
# is the committed <name>.eval.golden (captured from dev/eval_probe.exe --prepend).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BATCH="$ROOT/test/bin/eval_list_batch"
CORE="$ROOT/stdlib/core.mdk"; LIST="$ROOT/stdlib/list.mdk"
FIXDIR="$ROOT/test/eval_list_fixtures"
[ -x "$BATCH" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$BATCH") (missing $BATCH)"; exit 2; }

targets=""
for f in "$FIXDIR"/*.mdk; do [ -f "$f" ] && targets="$targets $f"; done

ALL="$("$BATCH" "$CORE" "$LIST" $targets 2>/dev/null | sed '${/^()$/d;}')"
section() { awk -v p="$1" '$0=="===SELFHOST-FIX=== "p {f=1;next} /^===SELFHOST-FIX=== /{f=0} f'; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.eval.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh)"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  self="$(printf '%s' "$ALL" | section "$f")"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
