#!/bin/sh
# Differential validation for the self-hosted LINT stage.
#
# OCaml-free: native host test/bin/lint_main vs the committed <name>.expected
# golden (parse → tools.lint.lintToLines → one "severity: [rule] message" per
# line, sorted, location-stripped).  Native output sorted before compare.
# Mirror of diff_compiler_exhaust.sh.
#
# Usage:  sh test/diff_compiler_lint.sh
#         CAPTURE=1 sh test/diff_compiler_lint.sh   # (re)capture goldens
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/lint_main"
FIXDIR="$ROOT/test/lint_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$RUN") (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

if [ "${CAPTURE:-0}" = "1" ]; then
  for f in "$FIXDIR"/*.mdk; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    golden="${f%.mdk}.expected"
    "$RUN" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort > "$golden"
    printf 'captured %s\n' "$name"
  done
  printf '\ngoldens captured in %s\n' "$FIXDIR"
  exit 0
fi

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
