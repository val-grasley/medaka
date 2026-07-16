#!/bin/sh
# Differential validation for the self-hosted LINT AUTOFIX (`--fix`, STYLE §8).
#
# OCaml-free: native host test/bin/lint_fix_main applies every fixable rule's
# fixer to each fixture and prints the rewritten source; compared byte-for-byte
# to the committed <name>.fixed golden.  A fixture whose `.fixed` equals its
# `.mdk` proves the safe-subset guard (the fixer declined to touch it).
#
# Usage:  sh test/diff_compiler_lint_fix.sh
#         CAPTURE=1 sh test/diff_compiler_lint_fix.sh   # (re)capture goldens
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/lint_fix_main"
FIXDIR="$ROOT/test/lint_fix_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$RUN") (missing $RUN)"; exit 2; }

if [ "${CAPTURE:-0}" = "1" ]; then
  for f in "$FIXDIR"/*.mdk; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    golden="${f%.mdk}.fixed"
    "$RUN" "$f" 2>/dev/null > "$golden"
    printf 'captured %s\n' "$name"
  done
  printf '\ngoldens captured in %s\n' "$FIXDIR"
  exit 0
fi

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="$(cat "${f%.mdk}.fixed")"
  self="$("$RUN" "$f" 2>/dev/null)"
  if [ "$self" = "$golden" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s (fixer output differs from golden)\n' "$name"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
