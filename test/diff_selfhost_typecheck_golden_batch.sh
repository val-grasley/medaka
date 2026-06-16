#!/bin/sh
# Batched variant of diff_selfhost_typecheck_golden.sh — prelude caching.
# Parses runtime + core ONCE; infers schemes for (core ++ fixture) per fixture.
#
# OCaml-free (REROOT-PLAN §2b): native host test/bin/typecheck_golden_batch vs the
# FROZEN === TYPES === section of diff_fixtures/*.golden.
#
# #55 / task #11 (Num-polymorphic integer literals) CLOSED 2026-06-16: both the
# OCaml oracle (eac278b) and the selfhost typecheck now infer `sum`/`product :
# a b -> b` via Num-polymorphic literals + ambiguous-Num defaulting, so the
# goldens and the native typecheck agree — this gate is now all-pass.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BATCH="$ROOT/test/bin/typecheck_golden_batch"
CORE="$ROOT/stdlib/core.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/diff_fixtures"
[ -x "$BATCH" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $BATCH)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

targets=""
for g in "$FIXDIR"/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$FIXDIR/$fix.mdk" ] || continue
  targets="$targets $FIXDIR/$fix.mdk"
done

ALL="$("$BATCH" "$RUNTIME" "$CORE" $targets 2>/dev/null | strip_unit)"
section() { awk -v p="$1" '$0=="===SELFHOST-FIX=== "p {f=1;next} /^===SELFHOST-FIX=== /{f=0} f'; }

pass=0; fail=0
for g in "$FIXDIR"/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$FIXDIR/$fix.mdk" ] || continue
  self="$(printf '%s' "$ALL" | section "$FIXDIR/$fix.mdk" | LC_ALL=C sort)"
  golden="$(sed -n '/=== TYPES ===/,/=== EVAL ===/p' "$g" | sed '1d;$d' | LC_ALL=C sort)"
  if [ "$golden" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$fix"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$fix"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
