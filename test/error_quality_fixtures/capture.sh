#!/bin/sh
# capture.sh — error-quality evaluation corpus baseline capture.
#
# For every fixture under test/error_quality_fixtures/<stage>/*.mdk this runs the
# appropriate `medaka` subcommand under a timeout and records the CURRENT stderr
# (+ exit code) into a sibling <fixture>.out golden.  This is a BASELINE snapshot
# of the compiler's error output — it does NOT grade the messages.
#
# Subcommand per stage subdir:
#   lex/ parse/ resolve/ typecheck/ exhaust/ effect/  -> medaka check
#   eval/                                              -> medaka run
#   build/                                             -> medaka build
#
# Path stability: absolute "$ROOT/" prefixes are rewritten to "ROOT/" (mirrors
# test/diff_compiler_lint_multi.sh) so goldens are relocatable.  The fixture's own
# path is left as the relative test/... form the compiler was invoked with.
#
# Usage:
#   sh test/error_quality_fixtures/capture.sh          # capture/refresh all .out goldens
#   CHECK=1 sh test/error_quality_fixtures/capture.sh  # compare against existing goldens, no write
#
# Exit: 0 always in CAPTURE mode; in CHECK mode 0 if all match else 1.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/medaka"
DIR="$ROOT/test/error_quality_fixtures"
TIMEOUT=60

[ -x "$BIN" ] || { echo "build first: make medaka (missing $BIN)"; exit 2; }

# Map a stage subdir to a medaka subcommand.
subcmd_for() {
  case "$1" in
    eval)  echo run ;;
    build) echo build ;;
    *)     echo check ;;
  esac
}

# Run a command with a hard timeout without relying on GNU coreutils `timeout`.
run_timed() {
  perl -e 'alarm shift; exec @ARGV or exit 127' "$TIMEOUT" "$@"
}

# Strip absolute build-root prefixes so goldens are path-stable.
strip_paths() {
  sed "s|$ROOT/|ROOT/|g"
}

check_mode="${CHECK:-0}"
total=0; captured=0; mismatched=0; errored_exit=0; clean_exit=0

for stage_dir in "$DIR"/*/; do
  stage="$(basename "$stage_dir")"
  cmd="$(subcmd_for "$stage")"
  for f in "$stage_dir"*.mdk; do
    [ -f "$f" ] || continue
    total=$((total + 1))
    rel="test/error_quality_fixtures/$stage/$(basename "$f")"
    # Invoke with the relative path (keeps captured diagnostics path-stable).
    # Capture STDERR (errors + runtime failures) in full. A clean `check` dumps the
    # whole inferred-signature list to STDOUT (noise) — so from stdout we keep only
    # diagnostic lines (Warning:/warning:/Error:/error:), which is where the
    # exhaustiveness/redundancy WARNINGS are emitted.
    errf="$(mktemp)"; outf="$(mktemp)"
    ( cd "$ROOT" && run_timed "$BIN" "$cmd" "$rel" >"$outf" 2>"$errf" )
    code=$?
    stdout_diag="$(grep -iE '^(warning|error):' "$outf" || true)"
    body="$( { cat "$errf"; [ -n "$stdout_diag" ] && printf '%s\n' "$stdout_diag"; } | strip_paths )"
    rm -f "$errf" "$outf"
    record="$(printf 'cmd: medaka %s\nexit: %s\n---\n%s\n' "$cmd" "$code" "$body")"

    if [ "$code" -eq 0 ]; then
      clean_exit=$((clean_exit + 1))
    else
      errored_exit=$((errored_exit + 1))
    fi

    golden="${f%.mdk}.out"
    if [ "$check_mode" = "1" ]; then
      if [ -f "$golden" ] && [ "$(cat "$golden")" = "$record" ]; then
        :
      else
        mismatched=$((mismatched + 1))
        printf 'DIFF %s\n' "$rel"
      fi
    else
      printf '%s\n' "$record" > "$golden"
      captured=$((captured + 1))
    fi
  done
done

echo "----------------------------------------"
echo "fixtures:        $total"
echo "exited nonzero:  $errored_exit"
echo "exited zero:     $clean_exit"
if [ "$check_mode" = "1" ]; then
  echo "goldens differing: $mismatched"
  [ "$mismatched" -eq 0 ] && echo "CHECK: all goldens match" || echo "CHECK: $mismatched mismatch(es)"
  [ "$mismatched" -eq 0 ] || exit 1
else
  echo "goldens written: $captured"
fi
exit 0
