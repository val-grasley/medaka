#!/bin/sh
# Differential validation for the self-hosted EVAL stage WITH the prelude loaded
# (slice 4b).  Where diff_compiler_eval.sh isolates the engine (prelude:false),
# this exercises real prelude dispatch: typeclass methods defined in core.mdk
# (Eq/Ord/Debug/Display/Num + deriving) running through the self-hosted eval.
#
# Reference: the committed test/eval_prelude_fixtures/<name>.eval.golden, captured
# (test/capture_goldens.sh) from dev/eval_probe.exe --prelude <fixture> (the
# embedded core.mdk → pp_value of `main`) while OCaml was trusted.
# Self-host (OCaml-free, REROOT-PLAN.md Phase 2): the pre-compiled native binary
# test/bin/eval_prelude_main (built by test/build_oracles.sh) prepends the *parsed*
# stdlib/core.mdk, then evaluates — pp_value of `main` must match byte-for-byte.
#
# Usage:  sh test/diff_compiler_eval_prelude.sh
# Exit:   0 if every fixture matches.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/eval_prelude_main"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_prelude_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }
strip_unit() { sed '${/^()$/d;}'; }  # drop native runtime's trailing Unit auto-print

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.eval.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh)"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  self="$("$RUN" "$CORE" "$f" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
