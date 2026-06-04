#!/bin/sh
# Differential validation for the self-hosted EVAL stage WITH the prelude loaded
# (slice 4b).  Where diff_selfhost_eval.sh isolates the engine (prelude:false),
# this exercises real prelude dispatch: typeclass methods defined in core.mdk
# (Eq/Ord/Debug/Display/Num + deriving) running through the self-hosted eval.
#
# Oracle: dev/eval_probe.exe --prelude  (Eval.eval_program ~prelude:true → the
# embedded core.mdk → pp_value of `main`).
# Self-host: eval_prelude_main.mdk prepends the *parsed* stdlib/core.mdk, then
# evaluates — pp_value of `main` must match byte-for-byte.
#
# Usage:  sh test/diff_selfhost_eval_prelude.sh
# Exit:   0 if every fixture matches.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/_build/default/dev/eval_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
SELFMAIN="$ROOT/selfhost/eval_prelude_main.mdk"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_prelude_fixtures"

[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  ref="$("$PROBE" --prelude "$f" 2>/dev/null)"
  self="$("$MAIN" run "$SELFMAIN" "$CORE" "$f" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
