#!/bin/sh
# test/diff_compiler_entry_exit_codes.sh — "a probe's error path exits 0" regression gate (#440).
#
# THE BUG: compiler/entries/entry_support.mdk — the shared scaffolding behind the
# per-stage probe entry points — contained ZERO `exit` calls against 21 error
# paths, and is imported by 22 entry probes. Every one of those paths printed a
# message to STDERR and then fell through to a 0 exit.
#
# Why that is worse than a cosmetic exit-code nit: a probe's whole output contract
# is "the artifact on STDOUT" (LLVM IR, an S-expr dump, a decl listing). So the
# natural harness shape
#
#     ./medaka_emitter <args> > out.ll || die     # <- never fires
#
# yields an EMPTY out.ll plus SUCCESS on any error — indistinguishable from a real
# emit. The message lands on stderr, so the near-universal `2>/dev/null` idiom
# hides the only evidence. This is the repo's #1 documented failure class ("a step
# that can silently no-op will"; "green" is not "ran"): every wasm gate once
# shelled out to an absent wasm-tools, printed `skipping`, exited 0, and had never
# run; #401's first WAT capture had 38 silently-empty files that would have diffed
# "identical" (empty-vs-empty is a green that proves nothing).
#
# #440 was filed against ONE path (the usage/arity error an agent tripped over)
# and scoped to the emitter binary. That was UNDER-scoped in one direction and
# OVER-scoped in another:
#   * the `medaka` CLI is NOT affected (it exits non-zero on usage errors; its
#     dispatch fallthrough `notYet` does stderr + exit 1 correctly);
#   * but the defect was never emitter-SPECIFIC: it lived in shared entry_support
#     scaffolding, so it was every error path of every probe — including a
#     NONEXISTENT INPUT FILE and a REAL TYPECHECK DIAGNOSTIC, both far likelier in
#     a harness than a wrong arity.
#
# THE FIX: every driver error path routes through `entry_support.failWith`
# (stderr + exit 1) instead of a bare `ePutStrLn`. batchLoop's per-file error arm
# deliberately keeps accumulating across targets and is intentionally NOT changed
# here (see the residual note at the bottom of this file).
#
# WHAT THIS GATE PINS: the five error paths reachable through `driveModules`, each
# asserted on BOTH observables that were blind (exit code AND stdout emptiness),
# plus a CONTROL proving a valid program still emits IR and exits 0 — without the
# control, a probe that failed unconditionally would pass every negative case and
# this gate would be the very "green that proves nothing" it exists to prevent.
#
# Probe binary: test/bin/llvm_emit_modules_main (the emitter entry, built by
# test/build_oracles.sh) — it is `driveModules`' real consumer.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMITBIN="$ROOT/test/bin/llvm_emit_modules_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

[ -x "$EMITBIN" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$EMITBIN") (missing $EMITBIN)"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

GOOD="$TMP/good.mdk"
printf 'main = println "hi"\n' > "$GOOD"

# A bare underived-ADT main: reaches runEmitWith's `underivedMainDiags` arm, which
# printed a real typecheck diagnostic and then exited 0 with empty IR.
UNDISP="$TMP/undisp.mdk"
printf 'data Foo = Foo\n\nmain = Foo\n' > "$UNDISP"

fails=0
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; fails=$((fails + 1)); }

# An error path must do BOTH: exit non-zero AND not pretend to have produced an
# artifact. Asserting only the exit code would miss the half that bites a harness.
expect_fail() {
  label="$1"; shift
  "$EMITBIN" "$@" > "$TMP/out" 2> "$TMP/err"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$label: exited 0 on an ERROR (a redirecting harness sees empty artifact + success)"
    return
  fi
  if [ -s "$TMP/out" ]; then
    fail "$label: exited $rc but wrote $(wc -c < "$TMP/out") bytes to stdout (partial artifact)"
    return
  fi
  if [ ! -s "$TMP/err" ]; then
    fail "$label: exited $rc but printed NOTHING to stderr (silent failure)"
    return
  fi
  pass "$label (exit $rc, stdout empty, diagnostic on stderr)"
}

echo "entry-probe error paths must exit non-zero (#440):"
expect_fail "usage/arity (too few args)"        "$GOOD"
expect_fail "nonexistent runtime.mdk"           "$TMP/NOPE.mdk" "$CORE" "$GOOD"
expect_fail "nonexistent core.mdk"              "$RUNTIME" "$TMP/NOPE.mdk" "$GOOD"
expect_fail "nonexistent entry.mdk"             "$RUNTIME" "$CORE" "$TMP/NOPE.mdk"
expect_fail "underived Display main (typecheck diagnostic)" "$RUNTIME" "$CORE" "$UNDISP"

# CONTROL — the load-bearing half. Proves the five assertions above discriminate:
# a probe broken into always-failing would satisfy every expect_fail.
echo "control (a valid program must still emit IR and exit 0):"
"$EMITBIN" "$RUNTIME" "$CORE" "$GOOD" > "$TMP/out" 2> "$TMP/err"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "valid program: exited $rc — $(head -c 200 "$TMP/err")"
elif [ ! -s "$TMP/out" ]; then
  fail "valid program: exited 0 but emitted NO IR"
elif ! grep -q 'define i32 @mdk_program_main' "$TMP/out"; then
  fail "valid program: emitted $(wc -c < "$TMP/out") bytes with no @mdk_program_main — not real IR"
else
  pass "valid program (exit 0, $(wc -c < "$TMP/out") bytes of IR, defines @mdk_program_main)"
fi

# RESIDUAL, deliberately unpinned: entry_support's `batchLoop` still prints a
# per-file read error and continues to the next target, so a batch probe whose
# every target failed to read exits 0 with an empty artifact. That is the same
# class, but fixing it means giving batchLoop a failure accumulator and changing
# the batch drivers' contract — out of scope for #440's exit-code fix, and not
# asserted here so this gate cannot claim coverage it does not have.

if [ "$fails" -ne 0 ]; then
  echo "FAIL: $fails check(s) failed"
  exit 1
fi
echo "PASS: entry-probe error paths exit non-zero with an empty artifact + a stderr diagnostic"
