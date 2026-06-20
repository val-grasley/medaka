#!/usr/bin/env bash
# build_wasm_cmd.sh — end-to-end gate for the `medaka build --target wasm` CLI flag
# (PLAYGROUND-DESIGN §2.1, Stage 1).  Peer of test/build_cmd.sh (native) and
# test/wasm/diff_wasm_modules.sh (entry-binary oracle).
#
# The point is to exercise the REAL CLI FLAG PATH, not the entry binary: drive each
# fixture through `./medaka build --target wasm <entry> -o out.wasm`, run the
# produced .wasm under test/wasm/run.js (Node >= 22 for the finalized WasmGC
# encoding), and assert its stdout == the native `./medaka build` oracle's stdout
# for the same program.
#
# The wasm CLI path needs a COMPILED wasm emitter binary (MEDAKA_WASM_EMITTER) —
# `medaka run <entry>` can't resolve the `args` extern (native-interp run mode),
# exactly as the LLVM path needs MEDAKA_EMITTER.  This gate builds it via
# test/wasm/build_wasm_oracle.sh if absent.
#
# Usage:  bash test/build_wasm_cmd.sh
# Exit:   0 if every fixture's CLI-built wasm stdout == native oracle stdout;
#         1 on any build/diff failure;
#         2 if medaka/emitter missing, no clang/wasm-tools, or Node < 22 (skip).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
WASMEMIT="${MEDAKA_WASM_EMITTER:-$ROOT/test/bin/wasm_emit_modules_main}"
FIXDIR="$ROOT/test/wasm/fixtures_modules"
RUNJS="$ROOT/test/wasm/run.js"
CC="${CC:-clang}"

command -v wasm-tools >/dev/null 2>&1 || { echo "wasm-tools not on PATH — skipping"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) — skipping"; exit 2; }
[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }

# The CLI build re-invokes ./medaka (and the LLVM emitter for the native oracle)
# from the repo root; supply the same env the other gates use.
export MEDAKA_ROOT="$ROOT"
export MEDAKA="$MEDAKA"
export MEDAKA_EMITTER="$EMITTER"

# Build the compiled wasm emitter binary the CLI's wasm path uses, if absent.
if [ ! -x "$WASMEMIT" ]; then
  sh "$ROOT/test/wasm/build_wasm_oracle.sh" >/dev/null 2>&1 || { echo "could not build wasm emitter oracle"; exit 2; }
fi
[ -x "$WASMEMIT" ] || { echo "missing wasm emitter binary: $WASMEMIT"; exit 2; }
export MEDAKA_WASM_EMITTER="$WASMEMIT"

# Engine: Node >= 22 for the finalized Wasm 3.0 GC encoding (mirrors diff_wasm_modules.sh).
NODE=node
major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$major" -lt 22 ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1090
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
  major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
fi
if [ "$major" -lt 22 ]; then
  echo "SKIP  Node >= 22 required for the finalized WasmGC encoding (have $($NODE --version 2>/dev/null))"
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0

# A small, real-prelude compute+print corpus exercising the CLI flag path.
FIXTURES="rp_int_arith.mdk rp_sum_list.mdk rp_length_list.mdk mm_sum"

run_fixture() {
  name="$1"; entry="$2"

  # Native oracle: the default `medaka build` (no --target).
  obin="$WORK/$name.oracle"
  if ! "$MEDAKA" build "$entry" -o "$obin" >"$WORK/obuild.err" 2>&1; then
    fail=$((fail+1)); printf 'FAIL %s (native oracle build)\n%s\n' "$name" "$(cat "$WORK/obuild.err")"; return
  fi
  ref="$("$obin" 2>/dev/null)"

  # CLI under test: `medaka build --target wasm`.
  wasm="$WORK/$name.wasm"
  if ! "$MEDAKA" build --target wasm "$entry" -o "$wasm" >"$WORK/wbuild.err" 2>&1; then
    fail=$((fail+1)); printf 'FAIL %s (medaka build --target wasm)\n%s\n' "$name" "$(cat "$WORK/wbuild.err")"; return
  fi

  got="$("$NODE" "$RUNJS" "$wasm" 2>"$WORK/run.err")"
  if [ "$ref" = "$got" ]; then
    pass=$((pass+1)); printf 'ok   %s -> %s\n' "$name" "$ref"
  else
    fail=$((fail+1)); printf 'FAIL %s\n  native: %s\n  wasm  : %s\n  (%s)\n' "$name" "$ref" "$got" "$(cat "$WORK/run.err")"
  fi
}

for f in $FIXTURES; do
  if [ -f "$FIXDIR/$f" ]; then
    run_fixture "$f" "$FIXDIR/$f"
  elif [ -f "$FIXDIR/$f/entry.mdk" ]; then
    run_fixture "$f" "$FIXDIR/$f/entry.mdk"
  else
    fail=$((fail+1)); printf 'FAIL %s (fixture missing)\n' "$f"
  fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
