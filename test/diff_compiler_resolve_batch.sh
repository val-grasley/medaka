#!/bin/sh
# Batched variant of diff_compiler_resolve.sh — prelude caching.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/resolve_batch"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/resolve_fixtures"
[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

targets=""
for f in "$FIXDIR"/*.mdk; do [ -f "$f" ] && targets="$targets $f"; done

ALL="$("$RUN" "$RT" "$CORE" $targets 2>/dev/null | sed '$ s/()$//; ${/^$/d;}')"
section() { awk -v p="$1" '$0=="===SELFHOST-FIX=== "p {f=1;next} /^===SELFHOST-FIX=== /{f=0} f'; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="$(cat "${f%.mdk}.expected")"
  ok=1
  self="$(printf '%s' "$ALL" | section "$f" | LC_ALL=C sort)"
  [ "$self" = "$golden" ] || { ok=0; reason="compiler differs from golden"; }
  if [ "$ok" -eq 1 ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s (%s)\n' "$name" "$reason"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
