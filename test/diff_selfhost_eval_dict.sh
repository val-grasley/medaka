#!/bin/sh
# Validation for the self-hosted DICT-PASSING eval path: programs whose
# `=>`-constrained functions use a return-position method (empty/minBound/…) at
# the constraint variable's type — which has no discriminating argument, so plain
# arg-tag / RKey dispatch cannot resolve it.  The Monoid (etc.) dictionary the
# caller supplies must be threaded into the function body.
#
# Reference: the committed test/eval_dict_fixtures/<name>.eval.golden, captured
# (test/capture_goldens.sh) from the reference `main.exe run <file>` (which
# dict-passes the whole program) while OCaml was trusted.
#
# BASELINE: this gate is "25 ok, 0 failing" (+batch "25 ok, 0 failing") — ALL PASS.
# The previously-failing fixtures (`method_constraint_foldmap_list`,
# `method_constraint_foldmap_string`, `method_constraint_user_iface`) are now GREEN:
# the method-level-constraint `foldMap : Monoid m =>` gap was CLOSED 2026-06-15 via
# a `crossModuleMethodConstraintsRef` accumulator + registering method dict slots AFTER
# body inference (surviving union-find root), in `compiler/types/typecheck.mdk`.
# Self-host (OCaml-free, REROOT-PLAN.md Phase 2): the pre-compiled native binary
# test/bin/eval_dict_main (built by test/build_oracles.sh) runs the self-hosted dict
# elaboration + eval; its stdout must match the golden.
#
# Usage:  sh test/diff_compiler_eval_dict.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DICT="$ROOT/test/bin/eval_dict_main"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_dict_fixtures"
[ -x "$DICT" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $DICT)"; exit 2; }
strip_unit() { sed '${/^()$/d;}'; }  # drop native runtime's trailing Unit auto-print
pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.eval.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh)"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  self="$("$DICT" "$RT" "$CORE" "$f" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s (%s)\n' "$name" "$ref"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
