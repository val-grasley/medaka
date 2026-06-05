#!/bin/sh
# Batched variant of diff_selfhost_eval_run.sh — PROTOTYPE for prelude caching.
# One process: parse core.mdk + list.mdk once, run every diff_fixtures program,
# split the delimited output, compare each against its === EVAL === golden.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
BATCH="$ROOT/selfhost/eval_run_batch.mdk"
CORE="$ROOT/stdlib/core.mdk"; LIST="$ROOT/stdlib/list.mdk"
FIXDIR="$ROOT/test/diff_fixtures"
[ -x "$MAIN" ] || { echo "build first: dune build --root ."; exit 2; }

targets=""
for g in "$FIXDIR"/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$FIXDIR/$fix.mdk" ] || continue
  targets="$targets $FIXDIR/$fix.mdk"
done

ALL="$("$MAIN" run "$BATCH" "$CORE" "$LIST" $targets 2>/dev/null)"
section() { awk -v p="$1" '$0=="===SELFHOST-FIX=== "p {f=1;next} /^===SELFHOST-FIX=== /{f=0} f'; }

pass=0; fail=0
for g in "$FIXDIR"/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$FIXDIR/$fix.mdk" ] || continue
  self="$(printf '%s' "$ALL" | section "$FIXDIR/$fix.mdk")"
  golden="$(sed -n '/=== EVAL ===/,$p' "$g" | sed '1d')"
  if [ "$self" = "$golden" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$fix"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$fix"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
