#!/bin/sh
# Validation for the TYPED self-hosted eval path (return-position dispatch / RKey):
# type-check (resolving each return-position method occurrence to its concrete
# impl) then evaluate.  These programs use a USER monad (Box) whose `pure`/do-blocks
# can only be dispatched by the return type, which the untyped path gets wrong.
#
# Reference: the committed test/eval_typed_fixtures/<name>.eval.golden, captured
# (test/capture_goldens.sh) from the reference TYPED path `main.exe run <file>`
# stdout while OCaml was trusted.
# Self-host (OCaml-free, REROOT-PLAN.md Phase 2): the pre-compiled native binary
# test/bin/eval_typed_main (built by test/build_oracles.sh); its stdout must match.
#
# Usage:  sh test/diff_selfhost_eval_typed.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TYPED="$ROOT/test/bin/eval_typed_main"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_typed_fixtures"
[ -x "$TYPED" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $TYPED)"; exit 2; }
strip_unit() { sed '${/^()$/d;}'; }  # drop native runtime's trailing Unit auto-print
pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.eval.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh)"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  self="$("$TYPED" "$RT" "$CORE" "$f" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s (%s)\n' "$name" "$ref"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
