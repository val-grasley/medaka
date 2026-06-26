#!/usr/bin/env bash
# build_compiler_wasm.sh — Stage-0 playground artifact builder.
#
# Produces the in-browser Medaka compiler: the multi-module WasmGC emitter
# (compiler/entries/wasm_emit_modules_main.mdk) self-compiled to a wasm module.
# Running that wasm under a WasmGC host (Node>=22 now, the browser later) with the
# host IO ABI in test/wasm/run.js + an in-memory vfs takes a user .mdk program and
# emits the user program's WAT on stdout — NO server, NO native binary at runtime.
#
# Idempotent. Emits into playground/dist/ (gitignored):
#   * compiler.wasm     — the compiler itself, as WasmGC (do NOT commit)
#   * runtime.mdk       — copy of stdlib/runtime.mdk (browser feeds via vfs)
#   * core.mdk          — copy of stdlib/core.mdk     (browser feeds via vfs)
#
# Pipeline (steps 1-2 of the Stage-0 task):
#   1. make medaka                     -> native OCaml-free compiler  (./medaka)
#      bash test/wasm/build_wasm_oracle.sh -> test/bin/wasm_emit_modules_main
#   2. wasm_emit_modules_main <runtime> <core> <ENTRY=the emitter itself> compiler stdlib
#        -> compiler.wat ; wasm-tools parse -> compiler.wasm ; validate
#
# NOTE the two ROOT dirs `compiler stdlib`: the emitter graph imports both compiler
# modules AND stdlib/hash_map (compiler/ir/dce.mdk), so BOTH roots are required or
# the loader reports `unknown module: hash_map`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/playground/dist"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
EMITBIN="$ROOT/test/bin/wasm_emit_modules_main"
ENTRY="$ROOT/compiler/entries/wasm_emit_modules_main.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

command -v wasm-tools >/dev/null 2>&1 || { echo "FAIL: wasm-tools not on PATH"; exit 2; }

# opam env may be needed for `make`/`dune`; only prepend if dune is missing.
command -v dune >/dev/null 2>&1 || export PATH="$HOME/.opam/5.4.1/bin:$PATH"

mkdir -p "$DIST"

# ── step 1: native compiler + the native modules-emitter binary ──────────────────
echo "[1/2] building native compiler + wasm emitter binary ..."
( cd "$ROOT" && make medaka )
[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"
( cd "$ROOT" && bash test/wasm/build_wasm_oracle.sh )
[ -x "$MEDAKA" ]  || { echo "FAIL: missing $MEDAKA";  exit 1; }
[ -x "$EMITBIN" ] || { echo "FAIL: missing $EMITBIN"; exit 1; }

# ── step 2: self-compile the emitter to wasm (compiler.wasm) ─────────────────────
echo "[2/2] self-compiling the emitter to WasmGC ..."
WAT="$DIST/compiler.wat"
WASM="$DIST/compiler.wasm"
"$EMITBIN" "$RUNTIME" "$CORE" "$ENTRY" "$ROOT/compiler" "$ROOT/stdlib" > "$WAT"
[ -s "$WAT" ] || { echo "FAIL: emitter produced empty WAT"; exit 1; }
echo "  compiler.wat: $(wc -l < "$WAT") lines"

wasm-tools parse "$WAT" -o "$WASM"
echo "  ASSEMBLE_OK"
wasm-tools validate --features=all "$WASM"
echo "  VALIDATE_OK"
rm -f "$WAT"   # keep dist lean; WAT is huge and regenerable

# ── stage the stdlib sources the browser vfs will feed ───────────────────────────
cp "$RUNTIME" "$DIST/runtime.mdk"
cp "$CORE"    "$DIST/core.mdk"

echo
echo "artifacts in $DIST:"
for f in compiler.wasm runtime.mdk core.mdk; do
  [ -f "$DIST/$f" ] && printf '  %-14s %10d bytes\n' "$f" "$(wc -c < "$DIST/$f")"
done
echo "DONE"
