#!/bin/sh
# Regression gate for the `net` feature (networking staging bite 3).
#
# Net fixtures CANNOT use the normal test/diff_compiler_llvm.sh gate: that gate
# goldens against the tree-walking interpreter, and net externs are
# deliberately UNBOUND under the interpreter (NATIVE/LLVM build-only, like
# fs/io's file externs — see stdlib/net.mdk's module doc / NET-DESIGN.md §6).
# So this is a dedicated build-and-run gate: for each fixture under
# test/net_fixtures/, `medaka build` it (native LLVM target, native emitter
# host), run the resulting binary, and diff its stdout against a committed
# `<name>.expected` file. No interpreter leg, no golden capture step.
#
# Also asserts the wasm-side guard: `medaka build --target wasm` on a
# net-importing program must FAIL (not miscompile) — WasmGC has no raw-socket
# equivalent (compiler/backend/wasm_emit.mdk's `isNetExternW` gap). This leg
# is best-effort: it needs `wasm-tools` on PATH AND a pre-built
# MEDAKA_WASM_EMITTER (test/bin/wasm_emit_modules_main, built by
# test/wasm/build_wasm_oracle.sh); without that combo the wasm build fails for
# an unrelated reason (no wasm-tools / missing emitter) rather than exercising
# the net-specific gap, so the leg is SKIPPED rather than reported as a false
# pass or fail.
#
# Usage:  sh test/diff_net.sh
# Exit:   0 if every fixture matches its .expected AND (when checkable) the
#         wasm-reject leg fails as expected; 1 otherwise; 2 if the native
#         `medaka` / `medaka_emitter` build is missing.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
FIXDIR="$ROOT/test/net_fixtures"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0

# ── build+run fixtures vs .expected ────────────────────────────────────────
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .mdk)"
  expected="$FIXDIR/$name.expected"
  if [ ! -f "$expected" ]; then
    fail=$((fail+1)); printf 'FAIL %s (no .expected)\n' "$name"; continue
  fi
  want="$(cat "$expected")"
  bin="$WORK/$name.bin"
  if ! ( export MEDAKA_ROOT="$ROOT"; export MEDAKA_EMITTER="$EMITTER"; bound "$MEDAKA" build "$f" -o "$bin" ) >"$WORK/build.out" 2>"$WORK/build.err"; then
    fail=$((fail+1)); printf 'FAIL %s (build)\n%s\n' "$name" "$(cat "$WORK/build.err")"; continue
  fi
  if [ ! -x "$bin" ]; then
    fail=$((fail+1)); printf 'FAIL %s (no binary produced)\n' "$name"; continue
  fi
  got="$(bound "$bin" 2>"$WORK/run.err")"
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$name" "$want" "$got"
  fi
done

# ── wasm-reject: net must fail (not miscompile) on --target wasm ──────────
WASM_EMITTER="${MEDAKA_WASM_EMITTER:-$ROOT/test/bin/wasm_emit_modules_main}"
if ! command -v wasm-tools >/dev/null 2>&1; then
  printf 'skip wasm-reject (no wasm-tools on PATH)\n'
elif [ ! -x "$WASM_EMITTER" ]; then
  printf 'skip wasm-reject (no wasm emitter oracle — build with: sh test/wasm/build_wasm_oracle.sh)\n'
else
  wasmf="$FIXDIR/net_loopback.mdk"
  wasm_out="$WORK/net_loopback_wasm"
  if ( export MEDAKA_ROOT="$ROOT"; export MEDAKA_EMITTER="$EMITTER"; export MEDAKA_WASM_EMITTER="$WASM_EMITTER"; bound "$MEDAKA" build --target wasm "$wasmf" -o "$wasm_out" ) >"$WORK/wasm.out" 2>"$WORK/wasm.err"; then
    fail=$((fail+1)); printf 'FAIL wasm-reject (build --target wasm succeeded, expected failure)\n'
  else
    if grep -q 'native-only' "$WORK/wasm.err" "$WORK/wasm.out" 2>/dev/null; then
      pass=$((pass+1)); printf 'ok   wasm-reject (failed with native-only diagnostic)\n'
    else
      pass=$((pass+1)); printf 'ok   wasm-reject (failed as expected; diagnostic did not mention native-only)\n'
      printf '  stderr: %s\n' "$(cat "$WORK/wasm.err")"
    fi
  fi
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
