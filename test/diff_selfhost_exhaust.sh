#!/bin/sh
# Differential validation for the self-hosted EXHAUST stage.
#
# OCaml-free (REROOT-PLAN §2b): native host test/bin/exhaust_main vs the committed
# <name>.expected golden (== dev/diagdump.exe --exhaust at capture: parse →
# Exhaust.check_guard_exhaustiveness on the RAW pre-desugar AST, sorted,
# location-stripped warning strings).  Native output sorted before compare.
# NOTE: this covers GUARD coverage only; match/clause exhaustiveness lives in
# the typecheck-internal check_match and is validated through that stage.
#
# Usage:  sh test/diff_compiler_exhaust.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/exhaust_main"
FIXDIR="$ROOT/test/exhaust_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="$(cat "${f%.mdk}.expected")"
  self="$("$RUN" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  if [ "$self" = "$golden" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s (compiler differs from golden)\n' "$name"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
