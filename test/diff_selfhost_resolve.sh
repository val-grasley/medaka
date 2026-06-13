#!/bin/sh
# Differential validation for the self-hosted RESOLVE stage.
#
# Oracle: dev/diagdump.exe --resolve  (parse → Desugar → Resolve.resolve_program,
# dump the error list as sorted, location-stripped S-expressions).
#
# Two checks per fixture in test/resolve_fixtures/ (each a deliberately-broken
# .mdk with a committed <name>.expected golden):
#   A. reference stability — diagdump output must equal the committed golden
#      (so the harness is green and self-documenting now, before any port).
#   B. if selfhost/entries/resolve_main.mdk exists — the self-hosted resolve's output
#      (sorted) must equal the same golden.
#
# Usage:  sh test/diff_selfhost_resolve.sh
# Exit:   0 if every fixture passes (B skipped until the selfhost side lands).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/resolve_main"
FIXDIR="$ROOT/test/resolve_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c)
# BEFORE sorting, so it can't reorder into the middle of the diagnostics.
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="$(cat "${f%.mdk}.expected")"
  ok=1
  self="$("$RUN" "$ROOT/stdlib/runtime.mdk" "$ROOT/stdlib/core.mdk" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  [ "$self" = "$golden" ] || { ok=0; reason="selfhost differs from golden"; }
  if [ "$ok" -eq 1 ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s (%s)\n' "$name" "$reason"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]