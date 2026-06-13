#!/bin/sh
# Differential validation for the self-hosted type-aware MATCH-exhaustiveness
# check (`check_match` in lib/exhaust.ml, invoked per EMatch from typecheck).
#
# OCaml-free (REROOT-PLAN §2b): native host test/bin/check_match_main vs the
# committed <name>.expected golden (== dev/diagdump.exe --check-match at capture:
# parse → Desugar → Typecheck.check_program_no_prelude, ONLY non-exhaustive-MATCH
# warnings, location-stripped).  The non-exhaustive fixtures hold one warning, the
# exhaustive controls hold an empty golden.  Native output sorted before compare.
# NOTE: this is the type-aware counterpart of diff_selfhost_exhaust.sh (which
# covers the standalone GUARD-coverage pass on the raw AST).
#
# Usage:  sh test/diff_selfhost_check_match.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/check_match_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/check_match_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="$(cat "${f%.mdk}.expected")"
  self="$("$RUN" "$RUNTIME" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  if [ "$self" = "$golden" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s (selfhost differs from golden)\n' "$name"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
