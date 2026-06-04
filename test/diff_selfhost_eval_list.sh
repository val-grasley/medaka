#!/bin/sh
# Differential validation for the self-hosted EVAL stage with core.mdk + list.mdk
# loaded — exercises the List combinators (map/filter/zip/sortBy/…) and list
# comprehensions (which desugar over list.mdk's map/filter/concatMap).
#
# Oracle: dev/eval_probe.exe --prepend stdlib/core.mdk stdlib/list.mdk <fixture>
#         (parse+desugar both, prepend, Eval.eval_program ~prelude:false).
# Self-host: eval_prelude_main.mdk core.mdk list.mdk <fixture> — same files
#         parsed by the self-host front-end; pp_value of `main` must match.
#
# Usage:  sh test/diff_selfhost_eval_list.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/_build/default/dev/eval_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
SELFMAIN="$ROOT/selfhost/eval_prelude_main.mdk"
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
