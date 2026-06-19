#!/usr/bin/env bash
# diff_wasm.sh — Slice W2 differential gate (WASMGC-DESIGN.md §8).  Peer of
# test/diff_selfhost_llvm.sh: for every fixture in the W2 corpus, emit a WasmGC
# WAT module, assemble+validate it with wasm-tools, run it under a WasmGC engine
# (Node >= 22), and diff its stdout against the ORACLE.
#
# ── The oracle (OCaml-free) ──────────────────────────────────────────────────
# The native-COMPILED binary `./medaka build <fixture> && ./<bin>`.  This is the
# faithful peer of the LLVM gate's oracle (eval_probe / a compiled binary that
# AUTO-PRINTS the value `main`).  NOTE: `./medaka run <fixture>` (the interpreter)
# does NOT auto-print a value main (Phase "Unit main no auto-print"); only the
# native-compiled binary applies the pp_value auto-print contract.  The WasmGC
# emitter mirrors that auto-print, so the compiled binary is the correct oracle —
# both are OCaml-free.  (This resolves the task's "diff against `medaka run`"
# framing, which would print nothing for these value mains.)
#
# Reports N/M passing; non-zero exit if any fixture diverges.  Opt-in skip (exit 2)
# when the toolchain (wasm-tools / Node>=22 / clang) is unavailable, mirroring the
# other native diff scripts.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
EMITBIN="$ROOT/test/bin/wasm_emit_main"
FIXDIR="$ROOT/test/wasm/fixtures"
RUNJS="$ROOT/test/wasm/run.js"
CC="${CC:-clang}"

command -v wasm-tools >/dev/null 2>&1 || { echo "wasm-tools not on PATH — skipping W2 gate"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) — skipping W2 gate"; exit 2; }
[ -x "$MEDAKA" ] || { echo "build the native compiler first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITBIN" ] || { echo "build the wasm emitter oracle: sh test/wasm/build_wasm_oracle.sh (missing $EMITBIN)"; exit 2; }

# ── Node >= 22 selection (finalized WasmGC encoding — see test/wasm/w1.sh) ─────
NODE=node
major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$major" -lt 22 ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
  major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
fi
if [ "$major" -lt 22 ]; then
  echo "W2 SKIP  Node >= 22 required for the finalized WasmGC encoding (have $($NODE --version 2>/dev/null))"
  exit 2
fi

# the native-compiled oracle needs the native emitter so `medaka build` is OCaml-free.
[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"

  # 1. oracle = native-compiled binary stdout
  obin="$WORK/$name.oracle"
  if ! "$MEDAKA" build "$f" -o "$obin" >"$WORK/build.err" 2>&1; then
    fail=$((fail+1)); printf 'FAIL %s (oracle build)\n%s\n' "$name" "$(cat "$WORK/build.err")"; continue
  fi
  ref="$("$obin" 2>/dev/null)"

  # 2. emit WAT
  wat="$WORK/$name.wat"
  if ! "$EMITBIN" "$f" > "$wat" 2>"$WORK/emit.err"; then
    fail=$((fail+1)); printf 'FAIL %s (wasm emit)\n%s\n' "$name" "$(cat "$WORK/emit.err")"; continue
  fi

  # 3. assemble + validate (the clang analogue)
  wasm="$WORK/$name.wasm"
  if ! wasm-tools parse "$wat" -o "$wasm" 2>"$WORK/parse.err"; then
    fail=$((fail+1)); printf 'FAIL %s (wasm-tools parse)\n%s\n' "$name" "$(cat "$WORK/parse.err")"; continue
  fi
  if ! wasm-tools validate --features=all "$wasm" 2>"$WORK/val.err"; then
    fail=$((fail+1)); printf 'FAIL %s (wasm-tools validate)\n%s\n' "$name" "$(cat "$WORK/val.err")"; continue
  fi

  # 4. run under Node, diff stdout
  got="$("$NODE" "$RUNJS" "$wasm" 2>"$WORK/run.err")"
  if [ "$ref" = "$got" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n  oracle: %s\n  wasm  : %s\n  (%s)\n' "$name" "$ref" "$got" "$(cat "$WORK/run.err")"
  fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
