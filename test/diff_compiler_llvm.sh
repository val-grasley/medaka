#!/bin/sh
# Equivalence gate for the Stage 2.4 LLVM de-risking spike (STAGE2-DESIGN.md §2.4).
#
# Proves the decided native toolchain end-to-end — EMIT textual LLVM IR + shell
# out to clang (no llc/opt, no C++ bindings) — against the committed value golden.
#
# For each prelude-free fixture in test/llvm_fixtures/:
#   1. ref  = test/llvm_fixtures/<name>.eval.golden   (captured from dev/eval_probe.exe;
#             the program VALUE — IR is symbol-renaming-volatile, but the program's
#             runtime stdout is stable, see MEMORY "Diff gates compare OUTPUT not IR")
#   2. emit = test/bin/llvm_emit_main <fixture>       (Core IR -> textual LLVM IR)
#   3. clang <emit>.ll runtime/medaka_rt.c -o bin     (compile + link the stub)
#   4. self = ./bin                                   (run the native binary)
#   diff ref vs self byte-for-byte.
#
# Scope: slices 1–5b.  No arrays/dispatch/GC.
#
# OCaml-free (REROOT-PLAN.md Phase 2): the emitter runs as the pre-compiled native
# binary test/bin/llvm_emit_main (built by test/build_oracles.sh) instead of
# `main.exe run`; the reference is the committed .eval.golden.
#
# Usage:  sh test/diff_compiler_llvm.sh
# Exit:   0 if every fixture's native stdout matches the golden; 2 if the build is
#         missing or no C compiler is available (spike is opt-in).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMITBIN="$ROOT/test/bin/llvm_emit_main"
RT="$ROOT/runtime/medaka_rt.c"
FIXDIR="$ROOT/test/llvm_fixtures"
CC="${CC:-clang}"

[ -x "$EMITBIN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $EMITBIN)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping spike"; exit 2; }

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then
  GC_CFLAGS="$(pkg-config --cflags bdw-gc)"; GC_LIBS="$(pkg-config --libs bdw-gc)"
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then
  GC_CFLAGS="-I$GC_PREFIX/include"; GC_LIBS="-L$GC_PREFIX/lib -lgc"
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then
  GC_CFLAGS=""; GC_LIBS="-lgc"
else
  echo "libgc (bdw-gc) not found — skipping spike (install bdw-gc, or set GC_PREFIX)"; exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The native emitter binary auto-prints main's Unit return as a trailing "()" line
# after the IR (runtime/medaka_rt.c); strip a sole trailing "()" before clang.
strip_unit() { perl -0pe 's/\(\)\s*\z//'; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.eval.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh)"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  ll="$WORK/$name.ll"
  bin="$WORK/$name.bin"
  if ! "$EMITBIN" "$f" > "$WORK/raw.ll" 2>"$WORK/emit.err"; then
    fail=$((fail+1)); printf 'FAIL %s (emit)\n%s\n' "$name" "$(cat "$WORK/emit.err")"; continue
  fi
  strip_unit < "$WORK/raw.ll" > "$ll"
  if ! "$CC" $GC_CFLAGS "$ll" "$RT" $GC_LIBS -o "$bin" 2>"$WORK/cc.err"; then
    fail=$((fail+1)); printf 'FAIL %s (clang)\n%s\n' "$name" "$(cat "$WORK/cc.err")"; continue
  fi
  self="$("$bin" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
