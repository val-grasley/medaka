#!/bin/sh
# Core IR equivalence gate with core.mdk + list.mdk loaded (STAGE2-DESIGN §2.1).
#
# Like diff_selfhost_core_ir_prelude.sh but adds stdlib/list.mdk to the prelude,
# so list combinators + comprehensions (desugared over List) run through the
# Core IR.  Equivalence oracle: dev/eval_probe.exe --prepend core.mdk list.mdk
# <fixture> (the SAME oracle selfhost/eval_prelude_main.mdk uses for this set).
#
# Usage:  sh test/diff_selfhost_core_ir_list.sh
# Exit:   0 if every fixture matches.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/_build/default/dev/eval_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
SELFMAIN="$ROOT/selfhost/core_ir_prelude_main.mdk"
CORE="$ROOT/stdlib/core.mdk"
LIST="$ROOT/stdlib/list.mdk"
FIXDIR="$ROOT/test/eval_list_fixtures"

[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  ref="$("$PROBE" --prepend "$CORE" "$LIST" "$f" 2>/dev/null)"
  self="$("$MAIN" run "$SELFMAIN" "$CORE" "$LIST" "$f" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
