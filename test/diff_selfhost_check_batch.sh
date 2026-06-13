#!/bin/sh
# Batched variant of diff_selfhost_check.sh — PROTOTYPE for prelude caching.
# Runs test/bin/check_batch ONCE over all diff_fixtures + resolve_fixtures
# in a single process (prelude parsed once), then splits the delimited output
# per fixture and compares each against the same committed golden the per-file
# harness uses.
#
# OCaml-free (REROOT-PLAN §2b): native host test/bin/check_batch; oracle legs are
# the FROZEN diff_fixtures === TYPES === golden + resolve_fixtures/*.expected
# (== dev/diagdump.exe --resolve at capture).  No live main.exe / diagdump.
#
# KNOWN PRE-EXISTING DIVERGENCE (#55, tracked by task #11): native infers
# `sum`/`product : a b -> b` vs the golden's `a Int -> Int`, so all 25 diff_fixtures
# TYPES sections MISMATCH; the 14 resolve sections pass.  Expected ~14 ok, 25
# failing, identical to the pre-re-root behavior.  Do NOT edit goldens/fixtures.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BATCH="$ROOT/test/bin/check_batch"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
[ -x "$BATCH" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $BATCH)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }
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
ALL="$("$BATCH" "$RT" "$CORE" $targets 2>/dev/null | strip_unit)"

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
  golden="${f%.mdk}.expected"
  [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL resolve/%s (no .expected)\n' "$name"; continue; }
  self="$(printf '%s' "$ALL" | section "$f" | LC_ALL=C sort)"
  want="$(LC_ALL=C sort < "$golden")"
  if [ "$self" = "$want" ]; then pass=$((pass+1)); printf 'ok   resolve/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL resolve/%s\n' "$name"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
printf '(NOTE: the 25 types/* fails are the documented #55 sum/product drift, task #11)\n'
[ "$fail" -eq 0 ]
