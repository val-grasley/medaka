#!/bin/sh
# Core IR equivalence gate with core.mdk + list.mdk loaded (STAGE2-DESIGN §2.1).
#
# Like diff_compiler_core_ir_prelude.sh but adds stdlib/list.mdk to the prelude,
# so list combinators + comprehensions (desugared over List) run through the
# Core IR.  Reference: the committed test/eval_list_fixtures/<name>.eval.golden
# (captured from dev/eval_probe.exe --prepend core.mdk list.mdk, the SAME oracle
# diff_compiler_eval_list.sh uses).
#
# OCaml-free (REROOT-PLAN.md Phase 2): the self-hosted Core-IR eval runs as the
# pre-compiled native binary test/bin/core_ir_prelude_main (build_oracles.sh).
#
# Usage:  sh test/diff_compiler_core_ir_list.sh
# Exit:   0 if every fixture matches.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/core_ir_prelude_main"
CORE="$ROOT/stdlib/core.mdk"
LIST="$ROOT/stdlib/list.mdk"
FIXDIR="$ROOT/test/eval_list_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$RUN") (missing $RUN)"; exit 2; }
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
