#!/bin/sh
# diff_compiler_slice_oob.sh — #550 run≠build memory-safety regression.
#
# An out-of-range `arr.[lo..hi]` is well-typed (the bounds are runtime values — you
# cannot statically reject every over-range slice), so `check` ACCEPTs it and this does
# NOT fit the 3-way check==run==build agreement gate. Its invariant is purely RUNTIME:
# `medaka run` raises `[E-SLICE-OOB]` (sliceArray, compiler/eval/eval.mdk); `medaka build`
# + exec previously allocated `hi - lo` slots and copied `a[lo + i]` with NO bounds check
# at all, so `[|1,2,3,4,5|].[2..99]` printed NINETY-SEVEN elements read off the end of the
# heap — raw heap words, live pointers among them, surfaced as ordinary Ints — and exited
# 0. This gate locks that build+exec now aborts IDENTICALLY to run.
#
# ── WHY THIS IS ITS OWN GATE AND NOT A DOCTEST ────────────────────────────────
# EVERY DOCTEST RUNS UNDER THE INTERPRETER, AND THE INTERPRETER IS THE ENGINE THAT WAS
# ALREADY CORRECT HERE. The entire in-language suite is blind to this bug by construction:
# a doctest asserting E-SLICE-OOB passes on a compiler that reads heap. That is exactly how
# this survived. Only a real `build` + exec can see it, so this gate does one.
#
# diff_compiler_engines.sh cannot cover it either: its eval arm classifies ANY interpreter
# `runtime error [E-` as `na` (deliberately — the interpreter has no `exit` primitive, so a
# nonzero exit is never a program-level exit), so an E-SLICE-OOB fixture is ledgered
# `eval:intended-abort` and never compared. See test/ENGINE-DIVERGENCE.md §4.4.
#
# ── WHAT IS ASSERTED (never "nonzero", never "it crashed") ────────────────────
# Per the must-fail suite's doctrine (test/diff_compiler_must_fail.sh): an assertion that
# accepts any failure launders an unrelated regression as evidence. So each trapping case
# pins THREE things, and an unrelated failure misses all of them:
#   * exit code EXACTLY 1 — not "nonzero". The pre-fix bug exited 0; a SIGSEGV exits 139;
#     a clean abort exits 1. Only 1 is the fix.
#   * stdout EMPTY — the pre-fix bug's whole signature was garbage ON STDOUT at exit 0.
#   * stderr EXACTLY the interpreter's own message, byte for byte, INCLUDING THE BOUNDS
#     (`slice [2..98] out of bounds`). Pinning the numbers and not just the `E-SLICE-OOB`
#     code is what catches an off-by-one in the guard: a check that fired on the wrong
#     side of the boundary would still print the code.
# `run`'s message carries a `file:L:C:` prefix that native aborts do not (no native abort
# has one), so run is compared on the SUFFIX and build+exec on the WHOLE line.
#
# THE CONTROL (slice_ok) IS LOAD-BEARING: it pins that every in-bounds slice — including
# `[0..5]` (end == length) and `[0..=4]` (last index, inclusive), the exact boundaries the
# guard must not reject — still returns its value on BOTH engines. Without it, "fixing"
# this gate by making the guard reject everything would read as green. If the control
# breaks, the environment broke, not the bug.
#
# NOT COVERED HERE (deliberate): the WasmGC arm. `--target wasm` needs a separately built
# wasm emitter ($MEDAKA_WASM_EMITTER, via test/wasm/build_wasm_oracle.sh) that this gate's
# shard does not build; the wasm slice guard is exercised by the test/wasm/ gates. Verified
# manually on both forms (2026-07-17): wasm traps the coded [E-SLICE-OOB] line, where it
# previously died with a RAW ENGINE trap ("array element access out of bounds" /
# "requested new array is too large") — memory-safe, but not the coded diagnostic.
#
# Usage:  sh test/diff_compiler_slice_oob.sh
# Exit:   0 all cases pass; 1 on any mismatch; 2 if native medaka/emitter/clang missing
#         (opt-in skip, same discipline as the other build gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
FIX="$ROOT/test/slice_oob_fixtures"
CC="${CC:-clang}"

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }
[ -d "$FIX" ] || { echo "missing fixture dir: $FIX"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

bound() { perl -e 'alarm 60; exec @ARGV' "$@"; }

# assert a trapping fixture: run and build+exec BOTH abort with the exact E-SLICE-OOB
# line for `bounds`, exit exactly 1, and print nothing on stdout.
check_oob() {
  name="$1"; bounds="$2"; src="$FIX/$name.mdk"; bin="$TMP/$name.bin"
  want="runtime error [E-SLICE-OOB]: slice [$bounds] out of bounds"

  bound "$MEDAKA" run "$src" >"$TMP/$name.run.out" 2>"$TMP/$name.run.err"
  run_code=$?
  bound env MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" "$MEDAKA" build "$src" -o "$bin" \
    >"$TMP/$name.build.out" 2>"$TMP/$name.build.err"
  if [ $? -ne 0 ]; then
    fail=$((fail+1)); printf 'FAIL %-26s (build did not compile)\n' "$name"; return
  fi
  bound "$bin" >"$TMP/$name.exec.out" 2>"$TMP/$name.exec.err"
  exec_code=$?

  run_err="$(cat "$TMP/$name.run.err")"
  exec_err="$(cat "$TMP/$name.exec.err")"
  run_out="$(cat "$TMP/$name.run.out")"
  exec_out="$(cat "$TMP/$name.exec.out")"

  # run's line is `<file>:L:C: <want>`; native aborts carry no location prefix.
  run_ok=0
  [ "$run_code" -eq 1 ] && [ -z "$run_out" ] \
    && case "$run_err" in *": $want") run_ok=1 ;; esac
  exec_ok=0
  [ "$exec_code" -eq 1 ] && [ -z "$exec_out" ] && [ "$exec_err" = "$want" ] && exec_ok=1

  if [ "$run_ok" -eq 1 ] && [ "$exec_ok" -eq 1 ]; then
    pass=$((pass+1))
    printf 'ok   %-26s (run=build+exec=1, both "slice [%s] out of bounds", stdout empty)\n' \
      "$name" "$bounds"
  else
    fail=$((fail+1))
    printf 'FAIL %-26s want=%s\n' "$name" "$want"
    printf '       run  exit=%s stdout=%.40s stderr=%s\n' "$run_code" "$run_out" "$run_err"
    printf '       exec exit=%s stdout=%.40s stderr=%s\n' "$exec_code" "$exec_out" "$exec_err"
  fi
}

# assert the control: run and build+exec both exit 0 with identical, correct stdout.
check_ok() {
  name="$1"; src="$FIX/$name.mdk"; bin="$TMP/$name.bin"
  expected='[|2, 3|]
[|2, 3, 4|]
[|1, 2, 3, 4, 5|]
[|1, 2, 3, 4, 5|]
[||]
[||]'

  run_out="$(bound "$MEDAKA" run "$src" 2>/dev/null)"; run_code=$?
  bound env MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" "$MEDAKA" build "$src" -o "$bin" \
    >/dev/null 2>"$TMP/$name.build.err"
  if [ $? -ne 0 ]; then
    fail=$((fail+1)); printf 'CONTROL-BROKE %-16s (build)\n' "$name"; return
  fi
  exec_out="$(bound "$bin" 2>/dev/null)"; exec_code=$?

  if [ "$run_code" -eq 0 ] && [ "$exec_code" -eq 0 ] \
     && [ "$run_out" = "$expected" ] && [ "$exec_out" = "$expected" ]; then
    pass=$((pass+1)); printf 'ok   %-26s (control: 6 in-bounds slices, run == build+exec)\n' "$name"
  else
    fail=$((fail+1))
    printf 'CONTROL-BROKE %-16s an IN-BOUNDS slice changed — the guard over-rejects, or the\n' "$name"
    printf '       environment broke. This is NOT the #550 bug reappearing.\n'
    printf '       run  exit=%s\n%s\n' "$run_code" "$run_out"
    printf '       exec exit=%s\n%s\n' "$exec_code" "$exec_out"
    printf '       want\n%s\n' "$expected"
  fi
}

check_oob slice_oob_half          '2..98'
check_oob slice_oob_incl          '2..99'
check_oob slice_oob_negative      '-2..0'
check_oob slice_oob_inverted      '2..0'
check_oob slice_oob_incl_boundary '0..3'
check_ok  slice_ok

echo
printf 'diff_compiler_slice_oob.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
