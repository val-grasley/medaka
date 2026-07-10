#!/bin/sh
# diff_compiler_let_refute.sh — P0-2c run≠build soundness regression.
#
# A refutable block-`let` with NO `else` (`let (Some y) = None`) is well-typed
# (`check` ACCEPTs it — you cannot statically reject every failing refutable let),
# so it does NOT fit the 3-way check==run==build agreement gate. Its invariant is
# purely RUNTIME: `medaka run` traps `[E-LET-REFUTE]` (nonzero); `medaka build` +
# exec previously SIGSEGV'd (exit 139) because the emitter destructured a
# mismatching cell with no tag check. This gate locks that build+exec now traps
# IDENTICALLY — it asserts the distinguishing signal (nonzero exit AND the
# `E-LET-REFUTE` stderr message, which a raw SIGSEGV lacks), not just stdout
# (empty for both a trap and a segfault, so stdout-only gates miss this bug).
#
# Cases:
#   refute_fail — run & build+exec BOTH nonzero + stderr has E-LET-REFUTE (the fix)
#   refute_ok   — matching scrutinee: run & build+exec both print 7, exit 0 (fast
#                 path through the tag check)
#   refute_expr — expression-level `let pat = e in body` analog: same trap
# The irrefutable fast path (tuple / single-ctor PCon) is locked separately by
# run_check_agreement_fixtures/p0_2c_irrefutable_let_ok (byte-identical goldens by
# the LLVM differential).
#
# Usage:  sh test/diff_compiler_let_refute.sh
# Exit:   0 all cases pass; 1 on any mismatch; 2 if native medaka/emitter/clang
#         missing (opt-in skip, same discipline as the other build gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
FIX="$ROOT/test/let_refute_fixtures"
CC="${CC:-clang}"

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

bound() { perl -e 'alarm 60; exec @ARGV' "$@"; }

# assert a trapping fixture: run and build+exec both exit nonzero AND both emit
# `[E-LET-REFUTE]` on stderr (proving a clean trap, NOT a SIGSEGV).
check_trap() {
  name="$1"; src="$FIX/$name.mdk"; bin="$TMP/$name.bin"

  bound "$MEDAKA" run "$src" >"$TMP/$name.run.out" 2>"$TMP/$name.run.err"
  run_code=$?
  bound env MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" "$MEDAKA" build "$src" -o "$bin" \
    >"$TMP/$name.build.out" 2>"$TMP/$name.build.err"
  build_code=$?
  if [ "$build_code" -ne 0 ]; then
    fail=$((fail+1)); printf 'FAIL %-24s (build did not compile)\n' "$name"; return
  fi
  bound "$bin" >"$TMP/$name.exec.out" 2>"$TMP/$name.exec.err"
  exec_code=$?

  if [ "$run_code" -ne 0 ] && grep -q 'E-LET-REFUTE' "$TMP/$name.run.err" \
     && [ "$exec_code" -ne 0 ] && grep -q 'E-LET-REFUTE' "$TMP/$name.exec.err"; then
    pass=$((pass+1)); printf 'ok   %-24s (run=%s build+exec=%s, both E-LET-REFUTE)\n' "$name" "$run_code" "$exec_code"
  else
    fail=$((fail+1))
    printf 'FAIL %-24s run=%s(%s) exec=%s(%s)\n' "$name" "$run_code" \
      "$(tr -d '\n' <"$TMP/$name.run.err" | head -c 60)" "$exec_code" \
      "$(tr -d '\n' <"$TMP/$name.exec.err" | head -c 60)"
  fi
}

# assert a succeeding fixture: run and build+exec both exit 0 with matching stdout.
check_ok() {
  name="$1"; expected="$2"; src="$FIX/$name.mdk"; bin="$TMP/$name.bin"

  run_out="$(bound "$MEDAKA" run "$src" 2>/dev/null)"; run_code=$?
  bound env MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" "$MEDAKA" build "$src" -o "$bin" \
    >/dev/null 2>"$TMP/$name.build.err"
  if [ $? -ne 0 ]; then fail=$((fail+1)); printf 'FAIL %-24s (build)\n' "$name"; return; fi
  exec_out="$(bound "$bin" 2>/dev/null)"; exec_code=$?

  if [ "$run_code" -eq 0 ] && [ "$exec_code" -eq 0 ] \
     && [ "$run_out" = "$expected" ] && [ "$exec_out" = "$expected" ]; then
    pass=$((pass+1)); printf 'ok   %-24s (run=build+exec=%s)\n' "$name" "$expected"
  else
    fail=$((fail+1))
    printf 'FAIL %-24s run=%s/%s exec=%s/%s exp=%s\n' "$name" "$run_code" "$run_out" "$exec_code" "$exec_out" "$expected"
  fi
}

check_trap p0_2c_refutable_let
check_trap p0_2c_refutable_let_expr
check_ok   p0_2c_refutable_let_ok 7

echo
printf 'diff_compiler_let_refute.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
