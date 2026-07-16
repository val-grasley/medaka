#!/bin/sh
# Batched variant of diff_compiler_eval_run.sh — PROTOTYPE for prelude caching.
# One process: parse core.mdk + list.mdk once, run every diff_fixtures program,
# split the delimited output, compare each against its === EVAL === golden.
#
# OCaml-free (REROOT-PLAN.md Phase 2): runs the pre-compiled native binary
# test/bin/eval_run_batch (built by test/build_oracles.sh) instead of `main.exe run`.
# Reference is the committed === EVAL === golden.  The native runtime auto-prints
# main's Unit return as one trailing "()" line at end-of-output; strip_unit removes
# it before sectioning so the final fixture's section is not polluted by it.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BATCH="$ROOT/test/bin/eval_run_batch"
CORE="$ROOT/stdlib/core.mdk"; LIST="$ROOT/stdlib/list.mdk"
FIXDIR="$ROOT/test/diff_fixtures"
[ -x "$BATCH" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$BATCH") (missing $BATCH)"; exit 2; }
strip_unit() { sed '${/^()$/d;}'; }

targets=""
for g in "$FIXDIR"/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$FIXDIR/$fix.mdk" ] || continue
  case "$fix" in numlit_*) continue ;; esac   # require typed fromInt elaboration; covered by the typed gates
  targets="$targets $FIXDIR/$fix.mdk"
done

ALL="$("$BATCH" "$CORE" "$LIST" $targets 2>/dev/null | strip_unit)"
section() { awk -v p="$1" '$0=="===SELFHOST-FIX=== "p {f=1;next} /^===SELFHOST-FIX=== /{f=0} f'; }

pass=0; fail=0
for g in "$FIXDIR"/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$FIXDIR/$fix.mdk" ] || continue
  case "$fix" in numlit_*) continue ;; esac   # require typed fromInt elaboration; covered by the typed gates
  self="$(printf '%s' "$ALL" | section "$FIXDIR/$fix.mdk")"
  golden="$(sed -n '/=== EVAL ===/,$p' "$g" | sed '1d')"
  if [ "$self" = "$golden" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$fix"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$fix"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
