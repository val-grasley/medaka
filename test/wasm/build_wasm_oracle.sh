#!/usr/bin/env bash
# build_wasm_oracle.sh — compile the WasmGC emitter entry to a native binary
# (test/bin/wasm_emit_main) via the OCaml-free `medaka build`, so the W2 diff gate
# runs without OCaml.  Peer of the ENTRIES rows in test/build_oracles.sh; kept as a
# small standalone helper while the WasmGC backend is in its slice-by-slice arc.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
ENTRY="$ROOT/selfhost/entries/wasm_emit_main.mdk"
OUT="$ROOT/test/bin/wasm_emit_main"

command -v clang >/dev/null 2>&1 || { echo "no clang — skipping (W2 oracle needs the native build path)"; exit 2; }
[ -x "$MEDAKA" ] || { echo "build the native compiler first: make medaka"; exit 2; }
[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"

mkdir -p "$ROOT/test/bin"
"$MEDAKA" build "$ENTRY" -o "$OUT" || { echo "build failed for $ENTRY"; exit 1; }
echo "built $ENTRY -> $OUT"
