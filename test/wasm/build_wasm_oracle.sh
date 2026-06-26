#!/usr/bin/env bash
# build_wasm_oracle.sh — compile the WasmGC emitter entries to native binaries via
# the OCaml-free `medaka build`, so the W2/W5 diff gates run without OCaml.  Peer of
# the ENTRIES rows in test/build_oracles.sh.
#
# DUAL-ENTRY (W5): two emitter binaries are built —
#   * test/bin/wasm_emit_main        — the W1–W4 PRELUDE-FREE scalar/ADT/closure
#     spike entry (annotateProgram path; never produces CMethod/CDict).  Gate:
#     test/wasm/diff_wasm.sh.
#   * test/bin/wasm_emit_typed_main  — the W5 TYPED dispatch entry (elaborateDict
#     path; produces CMethod/CDict/CImplEntry from prelude-free fixtures that define
#     their own minimal interfaces).  Gate: test/wasm/diff_wasm_typed.sh.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
ENTRY="$ROOT/compiler/entries/wasm_emit_main.mdk"
ENTRY_TYPED="$ROOT/compiler/entries/wasm_emit_typed_main.mdk"
ENTRY_MODULES="$ROOT/compiler/entries/wasm_emit_modules_main.mdk"
OUT="$ROOT/test/bin/wasm_emit_main"
OUT_TYPED="$ROOT/test/bin/wasm_emit_typed_main"
OUT_MODULES="$ROOT/test/bin/wasm_emit_modules_main"

command -v clang >/dev/null 2>&1 || { echo "no clang — skipping (W2/W5 oracle needs the native build path)"; exit 2; }
[ -x "$MEDAKA" ] || { echo "build the native compiler first: make medaka"; exit 2; }
[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"

mkdir -p "$ROOT/test/bin"
"$MEDAKA" build "$ENTRY" -o "$OUT" || { echo "build failed for $ENTRY"; exit 1; }
echo "built $ENTRY -> $OUT"
"$MEDAKA" build "$ENTRY_TYPED" -o "$OUT_TYPED" || { echo "build failed for $ENTRY_TYPED"; exit 1; }
echo "built $ENTRY_TYPED -> $OUT_TYPED"
"$MEDAKA" build "$ENTRY_MODULES" -o "$OUT_MODULES" || { echo "build failed for $ENTRY_MODULES"; exit 1; }
echo "built $ENTRY_MODULES -> $OUT_MODULES"
