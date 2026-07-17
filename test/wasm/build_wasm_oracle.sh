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
#   * test/bin/wasm_emit_modules_main — the MULTI-MODULE entry.  Gates:
#     test/wasm/diff_wasm_modules.sh, test/wasm/diff_sqlite.sh, test/build_wasm_cmd.sh,
#     and (the only one it needs) test/diff_compiler_engines.sh:144.
#
# ── --modules-only ────────────────────────────────────────────────────────────
# Build ONLY wasm_emit_modules_main.  diff_compiler_engines.sh reads exactly one of
# the three (`WASMBIN=…/wasm_emit_modules_main`, :144) and never the other two, so the
# `engines` CI shard — which wants the wasm arm and nothing else — would otherwise pay
# ~2.6x for binaries no gate on that runner opens.  The DEFAULT is unchanged and builds
# all three: the `wasm:` job's five gates need all of them.
set -u

MODULES_ONLY=0
for a in "$@"; do
  case "$a" in
    --modules-only) MODULES_ONLY=1 ;;
    *) echo "usage: $0 [--modules-only]" >&2; exit 2 ;;
  esac
done

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
# --allow-internal: the emitter entries pull in the compiler graph, which uses the
# internal-only array-kernel externs (arrayGetUnsafe, …) — the same flag the LLVM
# entry oracles pass in test/build_oracles.sh.
if [ "$MODULES_ONLY" = 0 ]; then
  "$MEDAKA" build --allow-internal "$ENTRY" -o "$OUT" || { echo "build failed for $ENTRY"; exit 1; }
  echo "built $ENTRY -> $OUT"
  "$MEDAKA" build --allow-internal "$ENTRY_TYPED" -o "$OUT_TYPED" || { echo "build failed for $ENTRY_TYPED"; exit 1; }
  echo "built $ENTRY_TYPED -> $OUT_TYPED"
fi
"$MEDAKA" build --allow-internal "$ENTRY_MODULES" -o "$OUT_MODULES" || { echo "build failed for $ENTRY_MODULES"; exit 1; }
echo "built $ENTRY_MODULES -> $OUT_MODULES"
