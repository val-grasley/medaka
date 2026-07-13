#!/bin/sh
# test/diff_compiler_ported.sh — gate for the in-language ported test suite.
#
# test/ported/*.mdk holds 323 `test "…" = <Expectation>` assertions ported from
# the old OCaml alcotest suites (test/ported/README.md). Nothing ran them until
# this gate: no Makefile target, hook, or other gate globbed test/ported/. This
# gate runs each file under the native ./medaka and requires: (1) the process
# exits 0 (medaka test already exits nonzero on a failing/erroring assertion —
# P0-6, see diff_compiler_test.sh), and (2) it did not panic/crash (a crash also
# exits nonzero, but is reported distinctly below since it aborts the WHOLE file
# — every assertion after the panic site never ran, unlike an ordinary FAIL).
#
# No OCaml/oracle comparison here (these files have no golden — `medaka test`'s
# own pass/fail report IS the check), so this only needs the native ./medaka,
# not a test/bin/* oracle.
#
# Usage:  sh test/diff_compiler_ported.sh
# Exit:   0 if every file's every assertion passes; nonzero otherwise.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="$ROOT/medaka"
DIR="$ROOT/test/ported"

[ -x "$NATIVE" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }

files="test_eval_ported.mdk test_run_ported.mdk test_loader_ported.mdk"

pass=0; fail=0
for f in $files; do
  path="$DIR/$f"
  [ -f "$path" ] || { fail=$((fail+1)); printf 'FAIL %s (missing file)\n' "$f"; continue; }
  # stdout/stderr captured SEPARATELY (not merged via 2>&1): the native runtime
  # runs the deeply-recursive compiler on a worker pthread (runtime/medaka_rt.c)
  # and a panic's stderr write can interleave mid-line with the worker's still-
  # buffered stdout when both land in one merged stream — a real race, harmless
  # to the exit-code check below but it garbles text-matching on a combined
  # capture, so classify PANIC from stderr alone.
  errfile="$(mktemp)"
  out="$("$NATIVE" test "$path" 2>"$errfile")"
  code=$?
  err="$(cat "$errfile")"; rm -f "$errfile"
  summary="$(printf '%s\n' "$out" | grep -E ': [0-9]+/[0-9]+ passed' | tail -1)"
  if [ "$code" -eq 0 ]; then
    pass=$((pass+1))
    printf 'ok   %s (%s)\n' "$f" "${summary:-all assertions passed}"
  elif printf '%s\n' "$err" | grep -q '^runtime error \[E-PANIC\]'; then
    fail=$((fail+1))
    printf 'FAIL %s — PANICKED (aborted mid-suite, assertions after the panic never ran)\n' "$f"
    printf '%s\n' "$err" | grep '^runtime error' | sed 's/^/       /'
  else
    fail=$((fail+1))
    printf 'FAIL %s (%s)\n' "$f" "${summary:-exit $code}"
    printf '%s\n' "$out" | grep '^  FAIL' | sed 's/^/       /'
  fi
done

printf '\n%d file(s) fully passing, %d failing/panicking\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
