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

# ── Per-fixture worker (parallel fan-out target); shared state via env ─────────
# Oracle at -O2 (not -O0): TCO fixtures need clang tail-call opt to avoid overflow.
if [ "${1:-}" = "--one" ]; then
  f="$2"; name="$(basename "$f")"
  obin="$WORKDIR/$name.oracle"; wat="$WORKDIR/$name.wat"; wasm="$WORKDIR/$name.wasm"
  st=0; msg=""
  if ! MEDAKA_CLANG_OPT="${WASM_ORACLE_OPT:--O2}" "$MEDAKA" build "$f" -o "$obin" >"$WORKDIR/$name.build.err" 2>&1; then
    msg="$(printf 'FAIL %s (oracle build)\n%s' "$name" "$(cat "$WORKDIR/$name.build.err")")"; st=1
  else
    ref="$("$obin" 2>/dev/null)"
    if ! "$EMITBIN" "$RUNTIME" "$f" > "$wat" 2>"$WORKDIR/$name.emit.err"; then
      msg="$(printf 'FAIL %s (wasm emit)\n%s' "$name" "$(cat "$WORKDIR/$name.emit.err")")"; st=1
    elif ! wasm-tools parse "$wat" -o "$wasm" 2>"$WORKDIR/$name.parse.err"; then
      msg="$(printf 'FAIL %s (wasm-tools parse)\n%s' "$name" "$(cat "$WORKDIR/$name.parse.err")")"; st=1
    elif ! wasm-tools validate --features=all "$wasm" 2>"$WORKDIR/$name.val.err"; then
      msg="$(printf 'FAIL %s (wasm-tools validate)\n%s' "$name" "$(cat "$WORKDIR/$name.val.err")")"; st=1
    else
      got="$("$NODE" "$RUNJS" "$wasm" 2>"$WORKDIR/$name.run.err")"
      if [ "$ref" = "$got" ]; then msg="ok   $name"
      else msg="$(printf 'FAIL %s\n  oracle: %s\n  wasm  : %s\n  (%s)' "$name" "$ref" "$got" "$(cat "$WORKDIR/$name.run.err")")"; st=1; fi
    fi
  fi
  echo "$st" > "$RESULTDIR/$name.status"
  printf '%s\n' "$msg"
  exit 0
fi

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
RESULTS="$(mktemp -d)"
trap 'rm -rf "$WORK" "$RESULTS"' EXIT

JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
NODE_ABS="$(command -v "$NODE" 2>/dev/null || echo "$NODE")"
ls "$FIXDIR"/*.mdk 2>/dev/null \
  | MEDAKA="$MEDAKA" EMITBIN="$EMITBIN" RUNTIME="$RUNTIME" NODE="$NODE_ABS" RUNJS="$RUNJS" \
    MEDAKA_EMITTER="${MEDAKA_EMITTER:-$EMITTER}" WASM_ORACLE_OPT="${WASM_ORACLE_OPT:-}" \
    WORKDIR="$WORK" RESULTDIR="$RESULTS" \
    xargs -P "$JOBS" -n 1 -I{} sh "$0" --one {}

pass=0; fail=0
for s in "$RESULTS"/*.status; do
  [ -f "$s" ] || continue
  if [ "$(cat "$s")" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
