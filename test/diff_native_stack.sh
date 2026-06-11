#!/bin/sh
# Native stack-safety gate for TRMC (tail-recursion-modulo-cons) Phase 1
# (TRMC-DESIGN.md, PLAN #56).
#
# A user-written cons-tail list builder (`upto m n = m :: upto (m+1) n`) used to
# SIGSEGV (139) at ~70-80k cons cells on the native LLVM backend, because the
# recursive call sat in the LAST arg of a `::` and every frame stayed live to the
# base case.  TRMC rewrites such a builder into an O(1)-stack destination-passing
# loop (no recursive `call`), so a deep list (2,000,000 elements) now builds and
# is consumed without overflow.
#
# For each fixture in test/stack_fixtures/:
#   ref  = dev/eval_probe.exe <fixture>            (the tree-walker oracle)
#   emit = medaka run llvm_emit_main.mdk <fixture> (Core IR -> textual LLVM IR)
#   clang <emit>.ll runtime/medaka_rt.c -o bin     (LARGE stack for the consumer)
#   self = ./bin
# diff ref vs self byte-for-byte AND require exit 0 (no SIGSEGV).
#
# Usage:  sh test/diff_native_stack.sh
# Exit:   0 if every fixture's native stdout matches the oracle and exits 0; 2 if
#         the build is missing or no C compiler / libgc is available (opt-in).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/_build/default/dev/eval_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
EMIT="$ROOT/selfhost/llvm_emit_main.mdk"
RT="$ROOT/runtime/medaka_rt.c"
FIXDIR="$ROOT/test/stack_fixtures"
CC="${CC:-clang}"

[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then
  GC_CFLAGS="$(pkg-config --cflags bdw-gc)"; GC_LIBS="$(pkg-config --libs bdw-gc)"
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then
  GC_CFLAGS="-I$GC_PREFIX/include"; GC_LIBS="-L$GC_PREFIX/lib -lgc"
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then
  GC_CFLAGS=""; GC_LIBS="-lgc"
else
  echo "libgc (bdw-gc) not found — skipping (install bdw-gc, or set GC_PREFIX)"; exit 2
fi

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
  # Link with the production build's large stack + -O2 (build_cmd.mdk).  TRMC makes
  # the BUILDER an O(1)-stack loop (pre-TRMC it SIGSEGV'd at ~80k cells regardless
  # of stack size — frames grew unboundedly).  The large stack additionally gives
  # Boehm GC's RECURSIVE mark room for very deep (>~1M) linked lists — a separate,
  # pre-existing native-runtime limitation, NOT a TRMC concern (TRMC-DESIGN.md).
  if ! "$CC" -O2 -Wl,-stack_size,0x20000000 $GC_CFLAGS "$ll" "$RT" $GC_LIBS -o "$bin" 2>"$WORK/cc.err"; then
    # -Wl,-stack_size is darwin-specific; on Linux a default-stack link + ulimit -s
    # unlimited covers it.
    if ! "$CC" -O2 $GC_CFLAGS "$ll" "$RT" $GC_LIBS -o "$bin" 2>"$WORK/cc.err"; then
      fail=$((fail+1)); printf 'FAIL %s (clang)\n%s\n' "$name" "$(cat "$WORK/cc.err")"; continue
    fi
  fi
  self="$("$bin" 2>/dev/null)"; code=$?
  if [ "$code" -ne 0 ]; then
    fail=$((fail+1)); printf 'FAIL %s (exit %d — SIGSEGV/overflow?)\n  ref : %s\n' "$name" "$code" "$ref"; continue
  fi
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s (%s)\n' "$name" "$self"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
