#!/bin/sh
# TYPED multi-module EVAL validation: run the self-hosted TYPED loader-driven eval
# path (eval_typed_modules_main.mdk: loader -> desugar -> elaborateModules
# route-stamping -> eval.evalModules over per-module frames) on each fixture WITH
# the real stdlib/core.mdk prelude.
#
# Reference: the committed <dir>/main.eval.golden, captured (test/capture_goldens.sh)
# from the OCaml reference `main.exe run <entry>` while OCaml was trusted.  This is
# the TYPED analog of diff_compiler_eval_modules.sh: the fixtures exercise
# interface-method dispatch that only resolves once the typed pipeline stamps
# routes, so the untyped path would diverge.
#
# C5 (TYPECHECK-AUDIT) regression: standalone_vs_method exercises a name that is
# BOTH an imported standalone function AND an interface method (box's `toList`/
# `isEmpty` on a Box with no Foldable impl) ALONGSIDE the genuine Foldable methods
# on List/Option.  This is a LOADER-ONLY divergence (a green single-file doctest),
# so it must live in a multi-module gate.
#
# OCaml-free (REROOT-PLAN.md Phase 2): the self-hosted typed loader-eval runs as
# the pre-compiled native binary test/bin/eval_typed_modules_main (build_oracles.sh).
#
# Usage:  sh test/diff_compiler_eval_typed_modules.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/test/bin/eval_typed_modules_main"
CORE="$ROOT/stdlib/core.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/eval_typed_modules_fixtures"
[ -x "$SELF" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $SELF)"; exit 2; }
strip_unit() { sed '${/^()$/d;}'; }  # drop native runtime's trailing Unit auto-print

pass=0; fail=0
for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  entry="$dir/main.mdk"
  [ -f "$entry" ] || { echo "skip $(basename "$dir") (no main.mdk)"; continue; }
  name="$(basename "$dir")"
  golden="${dir%/}/main.eval.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh)"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  self="$("$SELF" "$RUNTIME" "$CORE" "$entry" "${dir%/}" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '  ref:  %s\n' "$ref"
    printf '  self: %s\n' "$self"
  fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
