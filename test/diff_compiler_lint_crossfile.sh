#!/bin/sh
# Cross-file lint gate: exercises BOTH multi-file features added on lint-crossfile.
#   1. Recursive directory walk — the fixture dir has a NESTED subdir whose .mdk
#      carries a per-file finding; a top-level-only walk would miss it.
#   2. Cross-file rule tier — `rule-duplicate-body` fires on two files (one nested)
#      that share an identical non-trivial body, and stays QUIET on trivial /
#      unique bodies.
# Uses the ./medaka CLI directly (cross-file orchestration lives in runLintCmd).
#
# Usage:  sh test/diff_compiler_lint_crossfile.sh
#         CAPTURE=1 sh test/diff_compiler_lint_crossfile.sh   # (re)capture golden
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/lint_crossfile_fixtures"
GOLDEN="$FIXDIR/crossfile.expected"

[ -x "$MEDAKA" ] || { echo "build ./medaka first (missing $MEDAKA)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return) and normalise the
# absolute ROOT path to "ROOT/" so goldens are machine-portable.
strip_and_norm() { sed '$ s/()$//; ${/^$/d;}' | sed "s|$ROOT/|ROOT/|g"; }

run_lint() {
  MEDAKA_ROOT="$ROOT" "$MEDAKA" lint "$FIXDIR" 2>/dev/null | strip_and_norm
}

if [ "${CAPTURE:-0}" = "1" ]; then
  run_lint > "$GOLDEN"
  printf 'captured crossfile.expected in %s\n' "$FIXDIR"
  exit 0
fi

[ -f "$GOLDEN" ] || { echo "golden missing — run: CAPTURE=1 sh $0"; exit 2; }

golden="$(cat "$GOLDEN")"
self="$(run_lint)"
if [ "$self" = "$golden" ]; then
  printf 'ok   lint cross-file (recursive walk + duplicate-body)\n\n1 ok, 0 failing\n'
  exit 0
else
  printf 'FAIL lint cross-file (recursive walk + duplicate-body)\n'
  diff <(printf '%s\n' "$golden") <(printf '%s\n' "$self") || true
  printf '\n0 ok, 1 failing\n'
  exit 1
fi
