#!/bin/sh
# Multi-file lint gate: invokes the CLI with a directory target and diffs output.
# Uses the ./medaka CLI directly (multi-file orchestration lives in runLintCmd,
# not the lint_main oracle binary).
#
# Usage:  sh test/diff_compiler_lint_multi.sh
#         CAPTURE=1 sh test/diff_compiler_lint_multi.sh   # (re)capture golden
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/lint_multi_fixtures"
GOLDEN="$FIXDIR/multi.expected"

[ -x "$MEDAKA" ] || { echo "build ./medaka first (missing $MEDAKA)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
# Also normalise absolute ROOT path to "$ROOT" so goldens are machine-portable.
strip_and_norm() { sed '$ s/()$//; ${/^$/d;}' | sed "s|$ROOT/|ROOT/|g"; }

run_lint() {
  MEDAKA_ROOT="$ROOT" "$MEDAKA" lint "$FIXDIR" 2>/dev/null | strip_and_norm
}

if [ "${CAPTURE:-0}" = "1" ]; then
  run_lint > "$GOLDEN"
  printf 'captured multi.expected in %s\n' "$FIXDIR"
  exit 0
fi

[ -f "$GOLDEN" ] || { echo "golden missing — run: CAPTURE=1 sh $0"; exit 2; }

golden="$(cat "$GOLDEN")"
self="$(run_lint)"
if [ "$self" = "$golden" ]; then
  printf 'ok   lint multi-file (directory target)\n\n1 ok, 0 failing\n'
  exit 0
else
  printf 'FAIL lint multi-file (directory target)\n'
  diff <(printf '%s\n' "$golden") <(printf '%s\n' "$self") || true
  printf '\n0 ok, 1 failing\n'
  exit 1
fi
