#!/bin/sh
# test/diff_compiler_codemod.sh — gate for `medaka codemod effect-labels`.
#
# Drives the built native ./medaka (no separate oracle binary — codemod is a CLI
# subcommand) over test/codemod_fixtures/*.mdk.  Three legs per fixture:
#
#   leg 1 (golden):     ./medaka codemod effect-labels <flags> --stdout <fixture>
#                       must byte-match the committed <fixture>.codemod.golden.
#   leg 2 (idempotence): feeding the GOLDEN back through the same transform must
#                       reproduce the golden exactly (no residue, stable output).
#   leg 3 (dry-run):    the default (no --write/--stdout) dry-run exits 1 on a
#                       fixture that changes and 0 on the no-op fixture, so
#                       idempotence is a plain exit-code check like `fmt --check`.
#
# Per-fixture flags: every fixture strips `Mut,Panic` except `rename_panic_exit`,
# which exercises `--rename Panic=Exit` (dedupe + rename).  The `noop` fixture is
# the sole expected no-change file (dry-run exit 0).
#
# Regenerate goldens after an intentional change:
#   sh test/diff_compiler_codemod.sh --bless
#
# Usage:  sh test/diff_compiler_codemod.sh [--bless]
# Exit:   0 if every leg passes; 1 on any mismatch; 2 if ./medaka is not built.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="$ROOT/medaka"
FIX="$ROOT/test/codemod_fixtures"

[ -x "$NATIVE" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }
export MEDAKA_ROOT="$ROOT"

bless=0
[ "${1:-}" = "--bless" ] && bless=1

# Per-fixture flag selection (basename without extension).
flags_for() {
  case "$1" in
    rename_panic_exit) echo "--rename Panic=Exit" ;;
    *) echo "--strip Mut,Panic" ;;
  esac
}

# The single expected no-op fixture (dry-run must exit 0).
is_noop() { [ "$1" = "noop" ]; }

pass=0
fail=0
for f in "$FIX"/*.mdk; do
  [ -f "$f" ] || continue
  base="$(basename "$f" .mdk)"
  golden="$FIX/$base.codemod.golden"
  flags="$(flags_for "$base")"

  if [ "$bless" -eq 1 ]; then
    # shellcheck disable=SC2086
    "$NATIVE" codemod effect-labels $flags --stdout "$f" > "$golden"
    printf 'blessed %s\n' "$base"
    continue
  fi

  [ -f "$golden" ] || { printf 'FAIL %s (no golden — run: sh test/diff_compiler_codemod.sh --bless)\n' "$base"; fail=$((fail+1)); continue; }

  # leg 1 — golden diff.
  # shellcheck disable=SC2086
  actual="$("$NATIVE" codemod effect-labels $flags --stdout "$f" 2>/dev/null)"
  if [ "$actual" != "$(cat "$golden")" ]; then
    printf 'FAIL %s (leg 1: output != golden)\n' "$base"; fail=$((fail+1)); continue
  fi

  # leg 2 — idempotence: golden fed back through == golden.
  # shellcheck disable=SC2086
  again="$("$NATIVE" codemod effect-labels $flags --stdout "$golden" 2>/dev/null)"
  if [ "$again" != "$(cat "$golden")" ]; then
    printf 'FAIL %s (leg 2: not idempotent)\n' "$base"; fail=$((fail+1)); continue
  fi

  # leg 3 — dry-run exit code.
  # shellcheck disable=SC2086
  "$NATIVE" codemod effect-labels $flags "$f" >/dev/null 2>&1
  code=$?
  if is_noop "$base"; then
    want=0
  else
    want=1
  fi
  if [ "$code" != "$want" ]; then
    printf 'FAIL %s (leg 3: dry-run exit %s, want %s)\n' "$base" "$code" "$want"; fail=$((fail+1)); continue
  fi

  printf 'ok   %s\n' "$base"
  pass=$((pass + 1))
done

if [ "$bless" -eq 1 ]; then
  echo "goldens regenerated"
  exit 0
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
