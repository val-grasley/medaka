#!/usr/bin/env bash
# build_playground_wasm.sh — Stage-2 playground artifact builder.
#
# Produces the in-browser Medaka COMBINED compiler: the diagnostics+emit entry
# (selfhost/entries/playground_main.mdk) self-compiled to a WasmGC module.  Unlike
# compiler.wasm (the bare emit entry, which TRAPS on a broken program), this module
# runs the front end once and EITHER prints check --json diagnostics (broken) OR
# emits the program's WAT (clean), demuxed by a first-line marker — so the browser
# can surface compile errors with NO server.  See playground/compile.mjs for the
# host-side seam and the marker protocol.
#
# Idempotent.  Emits into playground/dist/ (gitignored):
#   * playground.wasm   — the combined compiler, as WasmGC  (do NOT commit)
#   * runtime.mdk       — copy of stdlib/runtime.mdk (browser feeds via vfs)
#   * core.mdk          — copy of stdlib/core.mdk     (browser feeds via vfs)
#
# Pipeline:
#   1. make medaka                         -> native OCaml-free compiler (./medaka)
#      test/wasm/build_wasm_oracle.sh       -> test/bin/wasm_emit_modules_main
#   2. wasm_emit_modules_main <runtime> <core> <ENTRY=playground_main.mdk> selfhost stdlib
#        -> playground.wat ; wasm-tools parse -> playground.wasm ; validate
#
# NOTE the two ROOT dirs `selfhost stdlib`: playground_main.mdk imports both
# selfhost modules AND stdlib/json (+ transitively hash_map via dce.mdk), so BOTH
# roots are required or the loader reports `unknown module: …`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/playground/dist"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
EMITBIN="$ROOT/test/bin/wasm_emit_modules_main"
ENTRY="$ROOT/selfhost/entries/playground_main.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

command -v wasm-tools >/dev/null 2>&1 || { echo "FAIL: wasm-tools not on PATH"; exit 2; }
command -v dune >/dev/null 2>&1 || export PATH="$HOME/.opam/5.4.1/bin:$PATH"

mkdir -p "$DIST"

# ── step 1: native compiler + the native modules-emitter binary ──────────────────
echo "[1/2] building native compiler + wasm emitter binary ..."
( cd "$ROOT" && make medaka )
[ -x "$EMITTER" ] && export MEDAKA_EMITTER="$EMITTER"
( cd "$ROOT" && bash test/wasm/build_wasm_oracle.sh )
[ -x "$MEDAKA" ]  || { echo "FAIL: missing $MEDAKA";  exit 1; }
[ -x "$EMITBIN" ] || { echo "FAIL: missing $EMITBIN"; exit 1; }

# ── step 2: compile the combined entry to wasm (playground.wasm) ─────────────────
echo "[2/2] compiling the combined diagnostics+emit entry to WasmGC ..."
WAT="$DIST/playground.wat"
WASM="$DIST/playground.wasm"
"$EMITBIN" "$RUNTIME" "$CORE" "$ENTRY" "$ROOT/selfhost" "$ROOT/stdlib" > "$WAT"
[ -s "$WAT" ] || { echo "FAIL: emitter produced empty WAT"; exit 1; }
echo "  playground.wat: $(wc -l < "$WAT") lines"

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
for f in playground.wasm runtime.mdk core.mdk; do
  [ -f "$DIST/$f" ] && printf '  %-16s %10d bytes\n' "$f" "$(wc -c < "$DIST/$f")"
done
echo "DONE"
