#!/usr/bin/env bash
# diff_wasm_typed.sh — Slice W5 differential gate (WASMGC-DESIGN §8, typeclass
# dispatch).  The DISPATCH peer of test/wasm/diff_wasm.sh, mirroring the LLVM split
# (diff_compiler_llvm_typed.sh): the W1–W4 scalar/ADT/closure fixtures stay on the
# PRELUDE-FREE annotate entry (wasm_emit_main, never produces CMethod/CDict); the W5
# DISPATCH fixtures go through the TYPED single-file entry (wasm_emit_typed_main),
# which runs elaborateDict and so DOES produce CMethod/CDict/CImplEntry.
#
# Entry strategy = DUAL-ENTRY (see compiler/entries/wasm_emit_typed_main.mdk header).
# The wholesale modules+DCE switch is NOT usable: DCE retains every prelude
# impl/interface whole (dict-passing dispatch can't prune an impl soundly), so a
# real `medaka build` of even a minimal `Eq Color` fixture emits ~274 prelude impl
# functions (Debug/Display strings, Num Float arith, Char/tuple impls) — all
# out-of-slice WasmGC gaps (W6/W7).  The prelude-free typed fixtures define their own
# minimal interfaces; elaborateDict resolves every route with NO prelude surface.
#
# For each fixture in test/wasm/fixtures_typed/:
#   1. oracle = `./medaka build <fixture>` + run (the OCaml-free native-compiled
#      binary's auto-printed value main — same oracle as diff_wasm.sh).
#   2. emit   = test/bin/wasm_emit_typed_main <runtime.mdk> <fixture>  → WAT
#   3. assemble + validate with wasm-tools; run under Node>=22; diff stdout.
#
# Reports N/M; non-zero exit on any divergence.  Opt-in skip (exit 2) when the
# toolchain (wasm-tools / Node>=22 / clang) is unavailable.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
EMITBIN="$ROOT/test/bin/wasm_emit_typed_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/wasm/fixtures_typed"
RUNJS="$ROOT/test/wasm/run.js"
CC="${CC:-clang}"

command -v wasm-tools >/dev/null 2>&1 || { echo "wasm-tools not on PATH — skipping W5 gate"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) — skipping W5 gate"; exit 2; }
[ -x "$MEDAKA" ] || { echo "build the native compiler first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITBIN" ] || { echo "build the wasm typed emitter: sh test/wasm/build_wasm_oracle.sh (missing $EMITBIN)"; exit 2; }

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
  echo "W5 SKIP  Node >= 22 required for the finalized WasmGC encoding (have $($NODE --version 2>/dev/null))"
  exit 2
fi

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

  # 2. emit WAT via the TYPED entry (runtime.mdk only — no prelude)
  wat="$WORK/$name.wat"
  if ! "$EMITBIN" "$RUNTIME" "$f" > "$wat" 2>"$WORK/emit.err"; then
    fail=$((fail+1)); printf 'FAIL %s (wasm emit)\n%s\n' "$name" "$(cat "$WORK/emit.err")"; continue
  fi

  # 3. assemble + validate
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
