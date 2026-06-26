#!/bin/sh
# Multi-module EVAL validation for the bootstrap: run the self-hosted
# loader-driven eval path (eval_modules_main.mdk: loader → desugar →
# eval.evalModules over per-module frames) on each multi-module fixture.
#
# Reference: the committed <dir>/main.eval.golden, captured (test/capture_goldens.sh)
# from the OCaml reference `main.exe run <entry>` (real Loader → typecheck →
# eval_modules) while OCaml was trusted.  This is the eval analog of
# diff_compiler_check_modules.sh and the multi-module analog of
# diff_compiler_eval_run.sh.
#
# Each fixture is a directory under test/eval_modules_fixtures/ holding a single
# `main_*.mdk` entry plus its sibling modules.  Fixtures stay on the UNTYPED eval
# path (no return-position dispatch / `=>` constraints).
#
# OCaml-free (REROOT-PLAN.md Phase 2): the self-hosted loader-eval runs as the
# pre-compiled native binary test/bin/eval_modules_main (built by build_oracles.sh).
#
# Usage:  sh test/diff_compiler_eval_modules.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/test/bin/eval_modules_main"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_modules_fixtures"
[ -x "$SELF" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $SELF)"; exit 2; }
strip_unit() { sed '${/^()$/d;}'; }  # drop native runtime's trailing Unit auto-print

pass=0; fail=0
for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  entry="$(ls "$dir"main_*.mdk 2>/dev/null | head -1)"
  [ -n "$entry" ] || { echo "skip $(basename "$dir") (no main_*.mdk)"; continue; }
  name="$(basename "$dir")"
  golden="${dir%/}/main.eval.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh)"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  self="$("$SELF" "$CORE" "$entry" "${dir%/}" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '  ref:  %s\n' "$ref"
    printf '  self: %s\n' "$self"
  fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
