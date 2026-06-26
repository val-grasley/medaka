#!/bin/sh
# Differential validation for the self-hosted EVAL stage (SLICE 1: engine core).
#
# Reference: the committed test/eval_fixtures/<name>.eval.golden — the pp_value of
# `main` captured (Phase 1, test/capture_goldens.sh) from dev/eval_probe.exe while
# OCaml was trusted (parse → desugar → Eval.eval_program ~prelude:false → pp_value).
# This isolates the eval ENGINE from the prelude/dispatch layer: fixtures in
# test/eval_fixtures/ are self-contained / prelude-free and aggregate their results
# into a single `main` value.
#
# OCaml-free (REROOT-PLAN.md Phase 2): the self-hosted eval runs as the pre-compiled
# native binary test/bin/eval_main (built by test/build_oracles.sh) instead of
# `main.exe run compiler/entries/eval_main.mdk`.  It must render the SAME pp_value as
# the golden.
#
# Usage:  sh test/diff_compiler_eval.sh
# Exit:   0 if every fixture matches.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/eval_main"
FIXDIR="$ROOT/test/eval_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# The native value entry auto-prints main's Unit return as a trailing "()" line
# (runtime/medaka_rt.c); the eval_probe golden has none — drop a sole trailing "()".
strip_unit() { sed '${/^()$/d;}'; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.eval.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh)"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  self="$("$RUN" "$f" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
