#!/bin/sh
# test/diff_compiler_run_stdout_flush.sh — "run drops stdout on panic" regression gate.
#
# Before this fix, `medaka run` buffered a program's stdout in an in-language
# Ref<String> (eval.mdk's outputRef) and only wrote it to real stdout with ONE
# final `putStr` call after `main` returned NORMALLY (medaka_cli.mdk's
# `runProgramOutput`).  Medaka panics are NOT catchable (no exception handling,
# no unwind), so a panicking program's ALREADY-PRINTED output was silently
# discarded — the printed trace before the crash never reached the terminal.
#
# That defeated the standard probe for "did this ill-typed/failing program
# actually EXECUTE": put a `println` sentinel before the suspect expression and
# check whether it shows up. Under the bug, the sentinel was invisible whether
# the program ran or not, AND the exit code was 1 either way — both obvious
# observables were blind. Bug #40 (multi-module `run` executing ill-typed
# programs) was nearly closed as "not reproducible" on exactly that basis.
#
# THE FIX: `medaka run`'s driver (evalModulesOutputRun/evalModulesOutputAsync)
# arms a flush via a new `enableRunStdoutFlush` call; every print
# (appendOutput) snapshots the buffer's raw bytes into the native runtime via
# `stashRunStdout`; every abort path in runtime/medaka_rt.c (mdk_panic,
# mdk_div_zero, mdk_mod_zero, mdk_nonexhaustive_match, mdk_let_refute, mdk_oob,
# and the SIGSEGV/SIGBUS fault handler) flushes that snapshot via write(2)
# BEFORE printing its own diagnostic and exiting. Both the stash and the flush
# are no-ops unless `medaka run`'s own driver armed them, so a compiled
# `medaka build` binary (which never calls either extern) and the pure
# differential-oracle eval probes (evalModulesOutput, which never calls
# enableRunStdoutFlush) are provably unaffected.
#
# WHY NOT test/diff_compiler_run_check_agreement.sh: that gate's fixtures are
# each pinned to a single check-verdict (ACCEPT or REJECT) that `run`/`build`
# must AGREE with — it structurally cannot represent a fixture that check
# ACCEPTS (well-typed) but that panics at RUNTIME for an unrelated reason
# (index-OOB, non-exhaustive match, …), which is exactly this bug's shape.
#
# Corpus: test/run_stdout_flush_fixtures/<name>.mdk. Every fixture prints the
# literal line "SENTINEL" before triggering an abort. For the three "coded"
# abort paths that route through `exit()` on BOTH engines (index_oob.mdk,
# panic.mdk, nonexhaustive_match.mdk) this gate also asserts `medaka run`'s
# stdout is BYTE-IDENTICAL to the compiled binary's stdout (the reference:
# `medaka build` + running the binary already prints SENTINEL correctly, since
# `exit()` -- unlike the raw-signal `_exit()` path -- flushes libc's stdio
# buffer automatically).
#
# stack_overflow_depth_guard.mdk and raw_panic_site.mdk are `run`-ONLY checks
# (see their own file-header comments for why they cannot be fairly compared
# against `medaka build`'s binary — a synthetic interpreter-only depth guard
# and a `run`-only missing-extern gap, respectively, both pre-existing and out
# of this bug's scope).
#
# stack_overflow_build.mdk is the companion `build`-ONLY check for the
# "build drops stdout on a real SIGSEGV" bug (2026-07-14): a compiled binary's
# println writes through libc's BUFFERED stdout, which every coded abort path
# (mdk_panic et al) gets flushed for free via `exit()`, but the SIGSEGV/SIGBUS
# fault handler must call `_exit()` (fflush/fwrite are not async-signal-safe),
# which skips that flush -- so a compiled binary that prints then genuinely
# overflows its 256 MB worker stack used to lose everything already printed
# (confirmed empirically: exit 134, empty stdout). Fixed by
# runtime/medaka_rt.c's mdk_flush_build_stdout_on_fatal_signal (mirrors
# mdk_flush_run_stdout_on_abort's pointer+length-snapshot-then-write(2)
# approach, but tracks the NATIVE stdout stream mdk_fwrite_str writes through,
# not the interpreter's outputRef). It turned out entirely practical to
# exercise from a fast, portable fixture (contrary to an earlier note here
# calling this "impractical") — the same non-tail `loop` shape as
# stack_overflow_depth_guard.mdk, built and run as a real binary, reliably
# overflows in well under a second on both Linux and macOS.
#
# Usage:  sh test/diff_compiler_run_stdout_flush.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/run_stdout_flush_fixtures"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -d "$FIXDIR" ] || { echo "missing fixture dir: $FIXDIR"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

check_one() {
  name="$1"; mode="$2"
  f="$FIXDIR/$name.mdk"

  if [ "$mode" = 'build-only' ]; then
    # `medaka run` is not exercised at all here: this fixture is about a real
    # SIGSEGV in a COMPILED binary (mdk_flush_build_stdout_on_fatal_signal),
    # not the interpreter's own (unrelated) synthetic depth guard, which would
    # catch the same source first via a completely different, already-covered
    # code path (see stack_overflow_depth_guard.mdk).
    if ! "$MEDAKA" build "$f" -o "$TMP/$name.bin" >"$TMP/$name.build.log" 2>&1; then
      echo "FAIL $name: \`medaka build\` failed to compile — cannot test"
      cat "$TMP/$name.build.log"
      fail=$((fail+1)); return
    fi
    "$TMP/$name.bin" >"$TMP/$name.bin.out" 2>"$TMP/$name.bin.err"
    bin_code=$?
    if [ "$bin_code" -eq 0 ]; then
      echo "FAIL $name: the built binary exited 0 (expected a nonzero abort)"
      fail=$((fail+1)); return
    fi
    if ! grep -q '^SENTINEL$' "$TMP/$name.bin.out"; then
      echo "FAIL $name: SENTINEL missing from the built binary's stdout — the fix regressed"
      echo "  bin stdout: $(cat "$TMP/$name.bin.out")"
      fail=$((fail+1)); return
    fi
    echo "ok   $name (build-only: SENTINEL present, exit $bin_code)"
    pass=$((pass+1)); return
  fi

  "$MEDAKA" run "$f" >"$TMP/$name.run.out" 2>"$TMP/$name.run.err"
  run_code=$?

  if [ "$run_code" -eq 0 ]; then
    echo "FAIL $name: \`medaka run\` exited 0 (expected a nonzero abort)"
    fail=$((fail+1)); return
  fi
  if ! grep -q '^SENTINEL$' "$TMP/$name.run.out"; then
    echo "FAIL $name: SENTINEL missing from \`run\`'s stdout — the fix regressed"
    echo "  run stdout: $(cat "$TMP/$name.run.out")"
    fail=$((fail+1)); return
  fi

  if [ "$mode" = 'run-only' ]; then
    echo "ok   $name (run-only: SENTINEL present, exit $run_code)"
    pass=$((pass+1)); return
  fi

  # mode = 'run-vs-build': also require run's stdout byte-identical to the
  # compiled binary's stdout (build already gets this right via exit()'s
  # automatic libc stdio flush; this is the "run now matches build" half).
  if ! "$MEDAKA" build "$f" -o "$TMP/$name.bin" >"$TMP/$name.build.log" 2>&1; then
    echo "FAIL $name: \`medaka build\` failed to compile — cannot compare"
    cat "$TMP/$name.build.log"
    fail=$((fail+1)); return
  fi
  "$TMP/$name.bin" >"$TMP/$name.bin.out" 2>"$TMP/$name.bin.err"
  bin_code=$?
  if [ "$bin_code" -eq 0 ]; then
    echo "FAIL $name: the built binary exited 0 (expected a nonzero abort)"
    fail=$((fail+1)); return
  fi
  if ! cmp -s "$TMP/$name.run.out" "$TMP/$name.bin.out"; then
    echo "FAIL $name: run stdout != build stdout"
    echo "  run  : $(cat "$TMP/$name.run.out")"
    echo "  build: $(cat "$TMP/$name.bin.out")"
    fail=$((fail+1)); return
  fi
  echo "ok   $name (run stdout == build stdout, both exit nonzero)"
  pass=$((pass+1))
}

check_one index_oob run-vs-build
check_one panic run-vs-build
check_one nonexhaustive_match run-vs-build
check_one stack_overflow_depth_guard run-only
check_one raw_panic_site run-only
check_one stack_overflow_build build-only

echo
echo "diff_compiler_run_stdout_flush.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
