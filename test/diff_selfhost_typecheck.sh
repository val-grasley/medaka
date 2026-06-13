#!/bin/sh
# Differential validation for the self-hosted TYPECHECK stage (SLICE 1, HM core).
# OCaml-free (REROOT-PLAN §2b): native host test/bin/typecheck_main vs a committed
# golden captured from dev/tc_probe.exe (check_program_no_prelude → pp_scheme per
# binding) by test/capture_goldens.sh.  Both the golden and the native output are
# sorted; fixtures are self-contained / prelude-free.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/typecheck_main"
FIXDIR="$ROOT/test/typecheck_fixtures"
[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.tc.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh tc)"; fail=$((fail+1)); continue; }
  ref="$(LC_ALL=C sort < "$golden")"
  self="$("$RUN" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  --- ref ---\n%s\n  --- self ---\n%s\n' "$name" "$ref" "$self"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
