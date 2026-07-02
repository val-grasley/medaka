#!/bin/sh
# Regression gate for the multi-DIRECTORY-target resolveLintTargets bug: passing
# MULTIPLE directory args used to be returned as-is (no expansion), so neither
# directory's .mdk files were discovered and the cross-file rule tier silently
# saw nothing. Invokes the CLI with TWO directory targets and diffs output.
# Uses the ./medaka CLI directly (multi-file orchestration lives in runLintCmd,
# not the lint_main oracle binary).
#
# Usage:  sh test/diff_compiler_lint_multi_dir.sh
#         CAPTURE=1 sh test/diff_compiler_lint_multi_dir.sh   # (re)capture golden
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/lint_multi_dir_fixtures"
GOLDEN="$FIXDIR/multi_dir.expected"

[ -x "$MEDAKA" ] || { echo "build ./medaka first (missing $MEDAKA)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
# Also normalise absolute ROOT path to "ROOT/" so goldens are machine-portable.
strip_and_norm() { sed '$ s/()$//; ${/^$/d;}' | sed "s|$ROOT/|ROOT/|g"; }

run_lint() {
  MEDAKA_ROOT="$ROOT" "$MEDAKA" lint "$FIXDIR/dirA" "$FIXDIR/dirB" 2>/dev/null | strip_and_norm
}

if [ "${CAPTURE:-0}" = "1" ]; then
  run_lint > "$GOLDEN"
  printf 'captured multi_dir.expected in %s\n' "$FIXDIR"
  exit 0
fi

[ -f "$GOLDEN" ] || { echo "golden missing — run: CAPTURE=1 sh $0"; exit 2; }

golden="$(cat "$GOLDEN")"
self="$(run_lint)"
if [ "$self" = "$golden" ]; then
  printf 'ok   lint multi-directory-target (two dir args, cross-file dup)\n\n1 ok, 0 failing\n'
  exit 0
else
  printf 'FAIL lint multi-directory-target (two dir args, cross-file dup)\n'
  gtmp="$(mktemp)"; stmp="$(mktemp)"
  printf '%s\n' "$golden" > "$gtmp"
  printf '%s\n' "$self" > "$stmp"
  diff "$gtmp" "$stmp" || true
  rm -f "$gtmp" "$stmp"
  printf '\n0 ok, 1 failing\n'
  exit 1
fi
