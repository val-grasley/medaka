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

# ── KNOWN FAILURES ───────────────────────────────────────────────────────────
# These files fail on REAL INTERPRETER BUGS, not test rot. They are recorded here
# rather than skipped, following the same model as diff_compiler_engines.sh's
# ledger and CAPABILITY-EXCEPTIONS.txt (and rustc's tests/crashes): each entry
# asserts the CURRENT, WRONG behavior, so that
#   (a) the bug cannot get any worse silently, and
#   (b) an ACCIDENTAL FIX is detected — if a listed file starts passing, this gate
#       FAILS and tells you to promote it.
# A plain skip-list cannot do (b), and a skip-list is exactly how test/ported/
# rotted in the first place (nothing ran it for months). Do not "simplify" this
# into a skip.
#
# Both bugs are the same family as the 36 remaining interpreter-extern gaps
# (test/CAPABILITY-EXCEPTIONS.txt, category BUG) — eval.mdk was written as a value
# ORACLE and was silently promoted to be the production `medaka run` engine when
# the OCaml reference compiler was deleted (2026-06-26).
#
#   test_run_ported.mdk     charIsAlpha on a non-ASCII char ('é') panics
#                           "no matching impl for dispatch" (line 135). Unicode
#                           char classification is not implemented in the interpreter.
#   test_loader_ported.mdk  "eval: unsupported node (slice 2)" — the interpreter
#                           does not lower slice syntax. Independently recorded by
#                           the engine census as `eval:unsupported-node`.
KNOWN_FAIL="test_run_ported.mdk test_loader_ported.mdk"

is_known() {
  for k in $KNOWN_FAIL; do [ "$k" = "$1" ] && return 0; done
  return 1
}

pass=0; fail=0; known=0; promote=0
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
    if is_known "$f"; then
      # ACCIDENTAL FIX. Someone fixed the underlying interpreter bug. Fail loudly:
      # an un-promoted known-failure silently becomes a skip, and then rots.
      promote=$((promote+1))
      printf 'PROMOTE %s — it now PASSES (%s) but is still listed in KNOWN_FAIL.\n' "$f" "${summary:-all assertions passed}"
      printf '        The underlying interpreter bug is FIXED. Remove it from KNOWN_FAIL in %s\n' "$0"
      printf '        and drop its row from test/CAPABILITY-EXCEPTIONS.txt if applicable.\n'
    else
      pass=$((pass+1))
      printf 'ok   %s (%s)\n' "$f" "${summary:-all assertions passed}"
    fi
  elif printf '%s\n' "$err" | grep -q '^runtime error \[E-PANIC\]'; then
    if is_known "$f"; then
      known=$((known+1))
      printf 'known %s — PANICKED (known interpreter bug; see KNOWN_FAIL in %s)\n' "$f" "$(basename "$0")"
      printf '%s\n' "$err" | grep '^runtime error' | sed 's/^/       /'
    else
      fail=$((fail+1))
      printf 'FAIL %s — PANICKED (aborted mid-suite, assertions after the panic never ran)\n' "$f"
      printf '%s\n' "$err" | grep '^runtime error' | sed 's/^/       /'
    fi
  else
    if is_known "$f"; then
      known=$((known+1))
      printf 'known %s (%s) — known interpreter bug\n' "$f" "${summary:-exit $code}"
    else
      fail=$((fail+1))
      printf 'FAIL %s (%s)\n' "$f" "${summary:-exit $code}"
      printf '%s\n' "$out" | grep '^  FAIL' | sed 's/^/       /'
    fi
  fi
done

printf '\n%d passing, %d known-failing, %d unexpected-failing, %d awaiting-promotion\n' \
  "$pass" "$known" "$fail" "$promote"

# Never exit 0 having compared nothing.
[ $((pass + known + fail + promote)) -gt 0 ] || {
  echo "FAIL: the gate ran no files at all"; exit 1; }

[ "$fail" -eq 0 ] && [ "$promote" -eq 0 ]
