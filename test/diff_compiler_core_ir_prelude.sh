#!/bin/sh
# Prelude-loaded equivalence gate for the Core IR (STAGE2-DESIGN §2.1).
#
# Where diff_compiler_core_ir.sh isolates the engine on prelude-free fixtures,
# this exercises real prelude dispatch — the typeclass methods defined in
# core.mdk (Eq/Ord/Debug/Display/Num + deriving) — flowing through the Core IR's
# slice-5 impl install + arg-tag VMultis.
#
# Reference: the committed test/eval_prelude_fixtures/<name>.eval.golden (captured
# from dev/eval_probe.exe --prelude, the SAME oracle diff_compiler_eval_prelude.sh
# uses).
#
# OCaml-free (REROOT-PLAN.md Phase 2): the self-hosted Core-IR eval runs as the
# pre-compiled native binary test/bin/core_ir_prelude_main (build_oracles.sh).
#
# Usage:  sh test/diff_compiler_core_ir_prelude.sh
# Exit:   0 if every fixture matches.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/core_ir_prelude_main"
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
