#!/bin/sh
# SELF-COMPILE C3 — TRUE SELF-HOSTING FIXPOINT.  The native emitter compiles the
# EMITTER ITSELF and reproduces its own output byte-for-byte.
#
# C1 (test/selfcompile_emit.sh) proved a NATIVE-compiled emitter reproduces the
# INTERPRETED emitter's IR on small fixtures.  C2 (test/selfcompile_lex.sh) had the
# native emitter compile the REAL self-hosted lexer driver, native-emitted IR
# byte-identical to the interpreter's.  C3 closes the loop: use the gap-tolerant
# emitter driver (selfhost/llvm_bootstrap_lex_main.mdk) — whose module graph IS the
# whole emitter + front-end + prelude, the LARGEST program in the tree — as BOTH the
# compiler AND the program being compiled.  "The compiler compiles itself and
# reproduces itself."
#
# emitter-A (step 1).  Native gap-tolerant emitter, built exactly as C2 builds its
# native emitter: the INTERPRETED gap-tolerant driver emits llvm_bootstrap_lex_main's
# OWN module graph → clang + runtime + libgc + big stack → native `emitA`.  This
# interpreted emission is ALSO the C3a oracle (the interpreted emitter's emission of
# the emitter graph), kept as INTERP.ll.
#
# IR1 (step 2).  emitA emits llvm_bootstrap_lex_main's graph again — the native
# emitter compiling the WHOLE emitter.  This is the biggest emit in the project
# (~10 MB IR, deep Core-IR recursion + huge string construction).
#   C3a (reproduction):  IR1 must equal INTERP.ll byte-for-byte (the C1/C2 guarantee
#                        at emitter-self scale).
#
# emitter-B (step 3).  clang(IR1) → native `emitB`.  IR2 = emitB emitting the same
# emitter graph.
#   C3b (fixpoint):  IR1 == IR2 byte-for-byte — the compiled compiler reproduces its
#                    own output.  FIXPOINT.
#
# STACK.  C2 established that arm64 macOS HARD-CAPS -Wl,-stack_size at 0x20000000
# (512 MiB — the linker rejects anything larger).  The whole-emitter emit is bigger
# than the lexer's, but it still FITS within 512 MiB (measured: native emit completes
# without overflow, IR byte-identical to the interpreter), so the max-allowed stack
# flag suffices and NO big-stack worker thread is needed.  The emitted program entry
# is @main running on the process main stack, as before.
#
# UNIT AUTO-PRINT.  The driver's `main : <IO, Mut> Unit` writes the IR via putStr,
# then the native runtime auto-prints main's Unit as a trailing "()\n".  emitProgram's
# IR ends in "}\n"; we strip the trailing "()\n" (3 bytes) from every native emit so
# the .ll is pure IR usable both for clang and the byte-diff.  The interpreted oracle
# does NOT auto-print, so INTERP.ll needs no trim.
#
# Usage:  sh test/selfcompile_fixpoint.sh
# Exit:   0 iff C3a (IR1==INTERP) AND C3b (IR1==IR2) both hold;
#         2 if the build is missing, no C compiler, or libgc is absent (opt-in);
#         1 on any divergence or build/emit failure.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
DRIVER="$ROOT/selfhost/llvm_bootstrap_lex_main.mdk"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
SELFHOST="$ROOT/selfhost"
CC="${CC:-clang}"

# 512 MiB — the arm64 -stack_size ceiling.  The whole-emitter native emit fits.
STACK_SIZE="${STACK_SIZE:-0x20000000}"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
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

# strip a trailing "()\n" (3 bytes the native runtime appends for main's Unit) so the
# file is pure IR.  $1 = path to a native-emitted .ll (modified in place).
trim_unit() {
  f="$1"
  if [ "$(tail -c 3 "$f" | od -An -tx1 | tr -d ' \n')" = "28290a" ]; then
    head -c $(( $(wc -c < "$f") - 3 )) "$f" > "$f.trim" && mv "$f.trim" "$f"
  fi
}

# ---- STEP 1: build emitter-A (native gap-tolerant emitter) ------------------
# The INTERPRETED emission of the driver graph is both the source for emitA AND the
# C3a oracle, so keep it as INTERP.ll.  (Pure interpreter output — no Unit trim.)
INTERP="$WORK/INTERP.ll"
EMITALL="$WORK/emitA.ll"
EMITA="$WORK/emitA"
echo "step 1: emitting the emitter's OWN graph (interpreted) ..."
if ! "$MAIN" run "$DRIVER" "$RUNTIME" "$CORE" "$DRIVER" "$SELFHOST" > "$INTERP" 2>"$WORK/emitA-emit.err"; then
  echo "FAIL (interp-emit emitter graph): $(cat "$WORK/emitA-emit.err")"; exit 1
fi
cp "$INTERP" "$EMITALL"
echo "step 1: clang emitA (stack $STACK_SIZE) ..."
if ! "$CC" -Wl,-stack_size,"$STACK_SIZE" $GC_CFLAGS "$EMITALL" "$RT" $GC_LIBS -o "$EMITA" 2>"$WORK/emitA-cc.err"; then
  echo "FAIL (clang emitA): $(cat "$WORK/emitA-cc.err")"; exit 1
fi

# ---- STEP 2: IR1 — native emitter compiles the WHOLE emitter ---------------
IR1="$WORK/IR1.ll"
echo "step 2: IR1 — emitA emitting the emitter graph (the biggest emit; slow) ..."
if ! "$EMITA" "$RUNTIME" "$CORE" "$DRIVER" "$SELFHOST" > "$IR1" 2>"$WORK/IR1.err"; then
  echo "FAIL (native-emit emitter crashed — likely stack overflow):"; cat "$WORK/IR1.err"; exit 1
fi
trim_unit "$IR1"

# ---- C3a: IR1 == interpreted emission --------------------------------------
c3a=0
if cmp -s "$INTERP" "$IR1"; then
  c3a=1
  echo "C3a PASS: IR1 (native) == interpreted emission of the emitter, byte-for-byte"
else
  echo "C3a FAIL: native IR1 differs from the interpreter's emission"
  cmp "$INTERP" "$IR1" | head -5
  diff "$INTERP" "$IR1" | head -30
fi

# ---- STEP 3: emitter-B from IR1, then IR2 ----------------------------------
EMITB="$WORK/emitB"
echo "step 3: clang IR1 -> emitB (stack $STACK_SIZE) ..."
if ! "$CC" -Wl,-stack_size,"$STACK_SIZE" $GC_CFLAGS "$IR1" "$RT" $GC_LIBS -o "$EMITB" 2>"$WORK/emitB-cc.err"; then
  echo "FAIL (clang emitB): $(cat "$WORK/emitB-cc.err")"; exit 1
fi
IR2="$WORK/IR2.ll"
echo "step 3: IR2 — emitB emitting the emitter graph ..."
if ! "$EMITB" "$RUNTIME" "$CORE" "$DRIVER" "$SELFHOST" > "$IR2" 2>"$WORK/IR2.err"; then
  echo "FAIL (emitB native-emit crashed):"; cat "$WORK/IR2.err"; exit 1
fi
trim_unit "$IR2"

# ---- C3b: IR1 == IR2 (fixpoint) --------------------------------------------
c3b=0
if cmp -s "$IR1" "$IR2"; then
  c3b=1
  echo "C3b PASS: IR1 == IR2 byte-for-byte — FIXPOINT (the compiled compiler reproduces its own output)"
else
  echo "C3b FAIL: IR1 differs from IR2 (no fixpoint)"
  cmp "$IR1" "$IR2" | head -5
  diff "$IR1" "$IR2" | head -30
fi

echo
printf 'C3a (IR1==interp): %s   C3b (IR1==IR2 fixpoint): %s\n' \
  "$([ "$c3a" -eq 1 ] && echo YES || echo NO)" \
  "$([ "$c3b" -eq 1 ] && echo YES || echo NO)"
[ "$c3a" -eq 1 ] && [ "$c3b" -eq 1 ]
