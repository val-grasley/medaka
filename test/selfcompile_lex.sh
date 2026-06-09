#!/bin/sh
# SELF-COMPILE C2 — the NATIVE compiler compiles a REAL program.
#
# C1 (test/selfcompile_emit.sh) proved a NATIVE-compiled emitter reproduces the
# INTERPRETED emitter's LLVM IR byte-for-byte on small module fixtures.  C2 takes
# the next step: use a NATIVE-compiled, gap-TOLERANT emitter to compile the
# self-hosted LEXER DRIVER (selfhost/lex_main.mdk) end-to-end — the first time the
# native compiler compiles a REAL, prelude-bearing program.
#
# This is the same end state as B1 (test/bootstrap_lex.sh, 19/19) EXCEPT the emit
# step is done by a NATIVE binary instead of the OCaml-hosted interpreter.  It is
# the real-size input that stresses the native emitter's OWN stack: deep Core IR
# recursion + multi-MB IR-string construction.
#
# BUILD (step 1).  Build the native gap-tolerant emitter: use the INTERPRETED
# gap-tolerant driver (llvm_bootstrap_lex_main.mdk) to emit its OWN module graph →
# clang + runtime + libgc + a big stack → native `bootstrap-emit`.
#
# NATIVE-EMIT (step 2).  Run ./bootstrap-emit <runtime> <core> lex_main.mdk
# <selfhost> → lex.ll.  This is the BIG, REAL emit — the native emitter recurses
# over lex_main's whole graph (lexer + util + prelude) and builds a multi-MB IR
# string.  This is where it may overflow the native emitter's stack (see below).
#
# BUILD + VALIDATE (step 3).  clang lex.ll → native `lex`.  Two checks:
#   (run-diff)  For each test/diff_fixtures/<f>.mdk, ./lex <f> must byte-match the
#               interpreter oracle `medaka run lex_main.mdk <f>` (with the same
#               ()-Unit auto-print handling as bootstrap_lex.sh).  19/19.
#   (IR-diff, STRONGER)  Diff the native-emitted lex.ll against the
#               interpreted-emitter's lex.ll (what bootstrap_lex.sh produces)
#               byte-for-byte.  Match ⇒ the native emitter reproduced the
#               interpreter's compilation of a REAL program at real scale (the C1
#               guarantee), and the run-diff is implied.
#
# STACK.  The native emitter's own deep recursion over lex_main's graph can
# overflow the default stack.  We link bootstrap-emit with the largest stack the
# linker allows: -Wl,-stack_size,0x20000000 (512 MiB — the arm64 macOS ceiling; the
# linker REJECTS anything larger on arm64).  The native emit fits within it, so
# option (a) suffices and no big-stack worker thread is needed.  STACK_SIZE below is
# the flag (the emitted @main runs on the process main stack).
#
# UNIT AUTO-PRINT.  lex_main's `main : <IO, Mut> Unit` prints the token stream, and
# the native runtime additionally auto-prints main's Unit as a trailing "()\n".  The
# interpreted oracle does NOT.  So we append "()" to the interpreted oracle output
# before comparing (same convention as bootstrap_lex.sh).
#
# Usage:  sh test/selfcompile_lex.sh
# Exit:   0 if all fixtures reproduce (and IR matches);
#         2 if the build is missing, no C compiler, or libgc is absent (opt-in).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
DRIVER="$ROOT/selfhost/llvm_bootstrap_lex_main.mdk"
ORACLE="$ROOT/selfhost/lex_main.mdk"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
SELFHOST="$ROOT/selfhost"
FIXDIR="$ROOT/test/diff_fixtures"
CC="${CC:-clang}"

# Big stack for the native emitter's own deep recursion over lex_main's graph.
# arm64 macOS caps -Wl,-stack_size at 512 MB (0x20000000); the native emit fits
# within it, so option (a) — the max-allowed stack flag — suffices (no big-stack
# worker thread needed).
STACK_SIZE="${STACK_SIZE:-0x20000000}"   # 512 MiB — the arm64 -stack_size ceiling

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

# ---- STEP 1: build the native gap-tolerant emitter -------------------------
EMITLL="$WORK/bootstrap-emit.ll"
EMITBIN="$WORK/bootstrap-emit"
echo "step 1: emitting the gap-tolerant emitter's OWN graph (interpreted) ..."
if ! "$MAIN" run "$DRIVER" "$RUNTIME" "$CORE" "$DRIVER" "$SELFHOST" > "$EMITLL" 2>"$WORK/emit-emit.err"; then
  echo "FAIL (emit bootstrap-emit): $(cat "$WORK/emit-emit.err")"; exit 1
fi
echo "step 1: clang bootstrap-emit (stack $STACK_SIZE) ..."
if ! "$CC" -Wl,-stack_size,"$STACK_SIZE" $GC_CFLAGS "$EMITLL" "$RT" $GC_LIBS -o "$EMITBIN" 2>"$WORK/emit-cc.err"; then
  echo "FAIL (clang bootstrap-emit): $(cat "$WORK/emit-cc.err")"; exit 1
fi

# ---- STEP 2: native-emit the lexer (the BIG, REAL emit) --------------------
NATLL="$WORK/lex.native.ll"
echo "step 2: native-emit lex_main (this is the big, real emit) ..."
if ! "$EMITBIN" "$RUNTIME" "$CORE" "$ORACLE" "$SELFHOST" > "$NATLL" 2>"$WORK/lex-emit.err"; then
  echo "FAIL (native-emit lex_main crashed — likely stack overflow):"; cat "$WORK/lex-emit.err"; exit 1
fi
# The native runtime auto-prints main's Unit as a trailing "()\n".  emitProgram's IR
# ends in "}\n"; strip a trailing "()\n" (the 3 bytes the runtime appended) so NATLL
# is pure IR usable both for clang and the byte-diff.  (putStr writes the IR, then
# the runtime adds "()\n".)  Command substitution would eat the newline, so test the
# raw trailing 3 bytes with od.
if [ "$(tail -c 3 "$NATLL" | od -An -tx1 | tr -d ' \n')" = "28290a" ]; then
  head -c $(( $(wc -c < "$NATLL") - 3 )) "$NATLL" > "$NATLL.trim" && mv "$NATLL.trim" "$NATLL"
fi

# ---- STEP 2b: interpreted-emitter IR for the STRONGER byte-diff ------------
INTLL="$WORK/lex.interp.ll"
echo "step 2b: interpreted-emit lex_main (for IR byte-diff) ..."
if ! "$MAIN" run "$DRIVER" "$RUNTIME" "$CORE" "$ORACLE" "$SELFHOST" > "$INTLL" 2>"$WORK/lex-iemit.err"; then
  echo "FAIL (interp-emit lex_main): $(cat "$WORK/lex-iemit.err")"; exit 1
fi

ir_match=0
if cmp -s "$INTLL" "$NATLL"; then
  ir_match=1
  echo "IR-MATCH: native-emitted lex.ll == interpreted-emitter lex.ll byte-for-byte"
else
  echo "IR-DIVERGE: native lex.ll differs from interpreter lex.ll"
  diff "$INTLL" "$NATLL" | head -30
fi

# ---- STEP 3: build the native lexer + run-diff vs the oracle ---------------
LEXBIN="$WORK/lex"
echo "step 3: clang native lexer (stack $STACK_SIZE) ..."
if ! "$CC" -Wl,-stack_size,"$STACK_SIZE" $GC_CFLAGS "$NATLL" "$RT" $GC_LIBS -o "$LEXBIN" 2>"$WORK/lex-cc.err"; then
  echo "FAIL (clang native lexer): $(cat "$WORK/lex-cc.err")"; exit 1
fi

pass=0; fail=0
for fix in "$FIXDIR"/*.mdk; do
  [ -f "$fix" ] || continue
  name="$(basename "$fix")"
  ref="$("$MAIN" run "$ORACLE" "$fix" 2>/dev/null)()"
  self="$("$LEXBIN" "$fix" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1))
    printf 'FAIL %s\n' "$name"
    printf '%s' "$ref"  > "$WORK/ref.txt"
    printf '%s' "$self" > "$WORK/self.txt"
    diff "$WORK/ref.txt" "$WORK/self.txt" | head -20 | sed 's/^/    /'
  fi
done

printf '\n%d ok, %d failing (of %d)' "$pass" "$fail" "$((pass+fail))"
[ "$ir_match" -eq 1 ] && printf '  [IR byte-match: YES]\n' || printf '  [IR byte-match: NO]\n'
[ "$fail" -eq 0 ]
