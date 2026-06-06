#!/bin/sh
# Equivalence gate for the Stage 2.4 LLVM de-risking spike (STAGE2-DESIGN.md §2.4).
#
# Proves the decided native toolchain end-to-end — EMIT textual LLVM IR + shell
# out to clang (no llc/opt, no C++ bindings) — against the tree-walker oracle, the
# same equivalence-gate shape selfhost/eval_main.mdk and core_ir_main.mdk use.
#
# For each prelude-free fixture in test/llvm_fixtures/:
#   1. ref  = dev/eval_probe.exe <fixture>            (the AST tree-walker oracle)
#   2. emit = medaka run llvm_emit_main.mdk <fixture> (Core IR -> textual LLVM IR)
#   3. clang <emit>.ll runtime/medaka_rt.c -o bin     (compile + link the stub)
#   4. self = ./bin                                   (run the native binary)
#   diff ref vs self byte-for-byte.
#
# Scope: slices 1–2 — slice 1 (integer/float arithmetic, comparisons, let, if,
# top-level value bindings, type-directed print) + slice 2 (top-level Int
# functions and saturated direct calls; self-recursive tail calls via musttail).
# No closures/ADTs/records/dispatch/GC.
#
# Usage:  sh test/diff_selfhost_llvm.sh
# Exit:   0 if every fixture's native stdout matches the tree-walker; 2 if the
#         build is missing or no C compiler is available (spike is opt-in).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/_build/default/dev/eval_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
EMIT="$ROOT/selfhost/llvm_emit_main.mdk"
RT="$ROOT/runtime/medaka_rt.c"
FIXDIR="$ROOT/test/llvm_fixtures"
CC="${CC:-clang}"

[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping spike"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  ref="$("$PROBE" "$f" 2>/dev/null)"
  ll="$WORK/$name.ll"
  bin="$WORK/$name.bin"
  if ! "$MAIN" run "$EMIT" "$f" > "$ll" 2>"$WORK/emit.err"; then
    fail=$((fail+1)); printf 'FAIL %s (emit)\n%s\n' "$name" "$(cat "$WORK/emit.err")"; continue
  fi
  if ! "$CC" "$ll" "$RT" -o "$bin" 2>"$WORK/cc.err"; then
    fail=$((fail+1)); printf 'FAIL %s (clang)\n%s\n' "$name" "$(cat "$WORK/cc.err")"; continue
  fi
  self="$("$bin" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
