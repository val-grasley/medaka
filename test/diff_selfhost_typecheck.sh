#!/bin/sh
# Differential validation for the self-hosted TYPECHECK stage (SLICE 1, HM core).
# Oracle: dev/tc_probe.exe (check_program_no_prelude -> pp_scheme per binding).
# Self-host: selfhost/typecheck_main.mdk (HM inference -> `name : scheme`).
# Fixtures are self-contained / prelude-free; both outputs sorted before compare.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/_build/default/dev/tc_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
SELF="$ROOT/selfhost/typecheck_main.mdk"
FIXDIR="$ROOT/test/typecheck_fixtures"
[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }
pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  ref="$("$PROBE" "$f" 2>/dev/null | LC_ALL=C sort)"
  self="$("$MAIN" run "$SELF" "$f" 2>/dev/null | LC_ALL=C sort)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  --- ref ---\n%s\n  --- self ---\n%s\n' "$name" "$ref" "$self"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
