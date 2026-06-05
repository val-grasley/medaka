#!/bin/sh
# Batched variant of diff_selfhost_resolve.sh — prelude caching.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIAG="$ROOT/_build/default/dev/diagdump.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
BATCH="$ROOT/selfhost/resolve_batch.mdk"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/resolve_fixtures"
[ -x "$DIAG" ] || { echo "build first: dune build --root . (missing $DIAG)"; exit 2; }

targets=""
for f in "$FIXDIR"/*.mdk; do [ -f "$f" ] && targets="$targets $f"; done

ALL="$("$MAIN" run "$BATCH" "$RT" "$CORE" $targets 2>/dev/null)"
section() { awk -v p="$1" '$0=="===SELFHOST-FIX=== "p {f=1;next} /^===SELFHOST-FIX=== /{f=0} f'; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="$(cat "${f%.mdk}.expected")"
  ref="$("$DIAG" --resolve "$f" 2>/dev/null)"
  ok=1
  [ "$ref" = "$golden" ] || { ok=0; reason="reference drifted from golden"; }
  if [ "$ok" -eq 1 ]; then
    self="$(printf '%s' "$ALL" | section "$f" | LC_ALL=C sort)"
    [ "$self" = "$golden" ] || { ok=0; reason="selfhost differs from reference"; }
  fi
  if [ "$ok" -eq 1 ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s (%s)\n' "$name" "$reason"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
