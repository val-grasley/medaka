#!/bin/sh
# TYPED Core IR equivalence gate (STAGE2-DESIGN §2.1) — the Core-IR analog of
# diff_selfhost_eval_typed.sh.  Drives the Core-IR evaluator's CMethod arm:
# return-position dispatch (RKey).  These programs use a USER monad (Box) whose
# `pure` / do-blocks dispatch by the RETURN type, which the untyped arg-tag fallback
# gets wrong.
#
# Reference: the committed test/eval_typed_fixtures/<name>.eval.golden (captured
# from the reference TYPED path `main.exe run <file>`, the SAME oracle
# diff_selfhost_eval_typed.sh uses).
#
# OCaml-free (REROOT-PLAN.md Phase 2): the self-hosted typed Core-IR eval runs as
# the pre-compiled native binary test/bin/core_ir_typed_main (build_oracles.sh).
#
# Usage:  sh test/diff_selfhost_core_ir_typed.sh
# Exit:   0 if every fixture matches.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TYPED="$ROOT/test/bin/core_ir_typed_main"
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
