#!/bin/sh
# TYPED multi-module EVAL validation for the bootstrap: run the self-hosted TYPED
# loader-driven eval path (eval_typed_modules_main.mdk: loader -> desugar ->
# elaborateModules route-stamping -> eval.evalModules over per-module frames) on
# each fixture WITH the real stdlib/core.mdk prelude, and diff its captured stdout
# against the OCaml reference doing the same (`medaka run <entry>`).
#
# This is the TYPED analog of diff_selfhost_eval_modules.sh (which stays on the
# UNTYPED path): the fixtures here exercise interface-method dispatch that only
# resolves once the typed pipeline stamps routes (return-position / RLocal / etc.),
# so the untyped path would diverge.
#
# C5 (TYPECHECK-AUDIT) regression: standalone_vs_method exercises a name that is
# BOTH an imported standalone function AND an interface method (box's `toList`/
# `isEmpty` on a Box with no Foldable impl) ALONGSIDE the genuine Foldable methods
# on List/Option.  Before the fix the self-host typed eval panicked
# (`non-exhaustive match`, eval.mdk) where the oracle printed the right result;
# this is a LOADER-ONLY divergence (a green single-file doctest), so it must live in
# a multi-module gate.
#
# Usage:  sh test/diff_selfhost_eval_typed_modules.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
SELF="$ROOT/selfhost/eval_typed_modules_main.mdk"
CORE="$ROOT/stdlib/core.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/eval_typed_modules_fixtures"
[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }

pass=0; fail=0
for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  entry="$dir/main.mdk"
  [ -f "$entry" ] || { echo "skip $(basename "$dir") (no main.mdk)"; continue; }
  name="$(basename "$dir")"
  ref="$("$MAIN" run "$entry" 2>&1)"
  self="$("$MAIN" run "$SELF" "$RUNTIME" "$CORE" "$entry" "${dir%/}" 2>&1)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '  ref:  %s\n' "$ref"
    printf '  self: %s\n' "$self"
  fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
