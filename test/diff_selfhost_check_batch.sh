#!/bin/sh
# Batched variant of diff_selfhost_check.sh — PROTOTYPE for prelude caching.
# Runs selfhost/check_batch.mdk ONCE over all diff_fixtures + resolve_fixtures
# in a single process (prelude parsed once), then splits the delimited output
# per fixture and compares each against the same oracle the per-file harness uses.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
DIAG="$ROOT/_build/default/dev/diagdump.exe"
BATCH="$ROOT/selfhost/check_batch.mdk"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
[ -x "$MAIN" ] || { echo "build first: dune build --root ."; exit 2; }
pass=0; fail=0

# Collect all target paths (diff fixtures that have a golden, then resolve fixtures)
targets=""
for g in "$ROOT"/test/diff_fixtures/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$ROOT/test/diff_fixtures/$fix.mdk" ] || continue
  targets="$targets $ROOT/test/diff_fixtures/$fix.mdk"
done
for f in "$ROOT"/test/resolve_fixtures/*.mdk; do
  targets="$targets $f"
done

# One process: parse prelude once, emit a delimited section per target.
ALL="$("$MAIN" run "$BATCH" "$RT" "$CORE" $targets 2>/dev/null)"

section() { awk -v p="$1" '$0=="===SELFHOST-FIX=== "p {f=1;next} /^===SELFHOST-FIX=== /{f=0} f'; }

for g in "$ROOT"/test/diff_fixtures/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$ROOT/test/diff_fixtures/$fix.mdk" ] || continue
  self="$(printf '%s' "$ALL" | section "$ROOT/test/diff_fixtures/$fix.mdk" | LC_ALL=C sort)"
  want="$(sed -n '/=== TYPES ===/,/=== EVAL ===/p' "$g" | sed '1d;$d' | LC_ALL=C sort)"
  if [ "$self" = "$want" ]; then pass=$((pass+1)); printf 'ok   types/%s\n' "$fix"
  else fail=$((fail+1)); printf 'FAIL types/%s\n' "$fix"; fi
done

for f in "$ROOT"/test/resolve_fixtures/*.mdk; do
  name="$(basename "$f")"
  self="$(printf '%s' "$ALL" | section "$f" | LC_ALL=C sort)"
  want="$("$DIAG" --resolve "$f" 2>/dev/null | LC_ALL=C sort)"
  if [ "$self" = "$want" ]; then pass=$((pass+1)); printf 'ok   resolve/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL resolve/%s\n' "$name"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
