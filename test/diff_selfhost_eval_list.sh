#!/bin/sh
# Differential validation for the self-hosted EVAL stage with core.mdk + list.mdk
# loaded — exercises the List combinators (map/filter/zip/sortBy/…) and list
# comprehensions (which desugar over list.mdk's map/filter/concatMap).
#
# Reference: the committed test/eval_list_fixtures/<name>.eval.golden, captured
# (test/capture_goldens.sh) from dev/eval_probe.exe --prepend stdlib/core.mdk
# stdlib/list.mdk <fixture> while OCaml was trusted.
# Self-host (OCaml-free, REROOT-PLAN.md Phase 2): the pre-compiled native binary
# test/bin/eval_prelude_main (built by test/build_oracles.sh) parses the SAME files
# with the self-host front-end; pp_value of `main` must match the golden.
#
# Usage:  sh test/diff_selfhost_eval_list.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/eval_prelude_main"
CORE="$ROOT/stdlib/core.mdk"
LIST="$ROOT/stdlib/list.mdk"
FIXDIR="$ROOT/test/eval_list_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }
strip_unit() { sed '${/^()$/d;}'; }  # drop native runtime's trailing Unit auto-print

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.eval.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh)"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  self="$("$RUN" "$CORE" "$LIST" "$f" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
