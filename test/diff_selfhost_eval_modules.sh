#!/bin/sh
# Multi-module EVAL validation for the bootstrap: run the self-hosted
# loader-driven eval path (eval_modules_main.mdk: loader → desugar →
# eval.evalModules over per-module frames) on each multi-module fixture, and
# diff its captured stdout against the OCaml reference doing the same — `medaka
# run <entry>`, which drives the real Loader → typecheck → eval_modules.  This
# is the eval analog of diff_selfhost_check_modules.sh (which validates the
# typecheck front-end), and the multi-module analog of diff_selfhost_eval_run.sh.
#
# Each fixture is a directory under test/eval_modules_fixtures/ holding a single
# `main_*.mdk` entry plus its sibling modules.  Fixtures stay on the UNTYPED
# eval path (no return-position dispatch / `=>` constraints), so untyped
# self-hosted eval and the typed reference produce identical output.
#
# Usage:  sh test/diff_selfhost_eval_modules.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
SELF="$ROOT/selfhost/eval_modules_main.mdk"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_modules_fixtures"
[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }

pass=0; fail=0
for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  entry="$(ls "$dir"main_*.mdk 2>/dev/null | head -1)"
  [ -n "$entry" ] || { echo "skip $(basename "$dir") (no main_*.mdk)"; continue; }
  name="$(basename "$dir")"
  ref="$("$MAIN" run "$entry" 2>&1)"
  self="$("$MAIN" run "$SELF" "$CORE" "$entry" "${dir%/}" 2>&1)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '  ref:  %s\n' "$ref"
    printf '  self: %s\n' "$self"
  fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
