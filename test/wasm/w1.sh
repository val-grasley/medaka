#!/usr/bin/env bash
# Slice W1 gate — WasmGC toolchain proof.
# Assembles a hand-written WasmGC module, validates it, runs it under Node
# (the CI engine, WASMGC-DESIGN fork c), and checks the program output. Also
# cross-checks that Wasmtime (the production edge engine) accepts the module.
# Seed of the future `diff_wasm.sh` differential gate (WASMGC-DESIGN §8).
#
# ENGINE REQUIREMENT: Node >= 22. wasm-tools emits the finalized Wasm 3.0
# WasmGC opcode encoding; Node 20.x's V8 implements an older draft encoding and
# fails ("invalid array index"). Node 24 runs it unflagged. (Engine-drift risk,
# WASMGC-DESIGN §11.)
set -euo pipefail
cd "$(dirname "$0")"

WAT=w1_add.wat
WASM=w1_add.wasm
EXPECT=3

# pick a new-enough node (fall back to nvm 24 if the default is too old)
NODE=node
major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
if [ "$major" -lt 22 ]; then
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 && nvm use 24 >/dev/null 2>&1 || true
  major=$("$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
fi
if [ "$major" -lt 22 ]; then
  echo "W1 SKIP  Node >= 22 required for the finalized WasmGC encoding (have $($NODE --version 2>/dev/null))"
  exit 2
fi

wasm-tools parse "$WAT" -o "$WASM"
wasm-tools validate --features=all "$WASM"

# production-engine acceptance cross-check (no run: custom import has no CLI host)
if command -v wasmtime >/dev/null 2>&1; then
  wasmtime compile -W gc,tail-call "$WASM" -o /tmp/w1_add.cwasm >/dev/null 2>&1 \
    && echo "wasmtime: accepts module" || { echo "wasmtime: REJECTED module"; exit 1; }
  rm -f /tmp/w1_add.cwasm
fi

GOT=$("$NODE" run.js "$WASM")
if [ "$GOT" = "$EXPECT" ]; then
  echo "W1 PASS  (node $($NODE --version): got '$GOT')"
else
  echo "W1 FAIL  expected '$EXPECT' got '$GOT'"
  exit 1
fi
