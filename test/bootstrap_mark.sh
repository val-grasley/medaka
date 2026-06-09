#!/bin/sh
# BOOTSTRAP (B5) — the FIFTH native self-compile slice: natively compile the
# self-hosted METHOD-MARKER stage (rewrites interface-method / constrained-fn
# EVar occurrences to EMethodRef / EDictApp) and prove its canonical marked-AST
# S-expressions byte-match the tree-walker interpreter over real fixtures.
#
# Unlike B4 (THREE file args: runtime + core + target), mark_main takes TWO
# file-path args:
#   <prelude.mdk> <target.mdk>
# It parses+desugars the prelude (stdlib/core.mdk) and the target, marks the
# target against the prelude (markWithPrelude), and putStrs the marked AST.
# Native `args ()` returns argv[1..] (mdk_args), so both reach mark_main.
#
# Like bootstrap_{lex,parse,desugar,resolve}.sh, this pushes the REAL
# stdlib/core.mdk through emitProgram at EMIT time (the actual bootstrap gate).
# The driver (selfhost/llvm_bootstrap_lex_main.mdk) is GENERIC: entry =
# mark_main as an argument, gap-recording on, real emitProgram,
# private_mangle.mangleUnits.  Note mark_main READING the prelude at RUNTIME is
# separate from the emit-time prelude.
#
# For each fixture in test/parse_fixtures/*.mdk:
#   oracle = medaka run selfhost/mark_main.mdk <core> <fixture>
#   native = ./mark <core> <fixture>
# Both sides emit SELFHOST S-exprs (native selfhost vs interpreted selfhost)
# running the SAME deterministic marker, so a raw byte-diff is correct —
# NO sort, NO float normalization.
#
# mark_main's `main : <IO> Unit` -> the native runtime auto-prints main's Unit
# value as a trailing "()\n"; mark_main's `putStr (programToSexp …)` has NO
# trailing newline, so the invariant native suffix is exactly "()\n".  We append
# "()" to the oracle output before the diff (same convention as bootstrap_*.sh).
#
# Usage:  sh test/bootstrap_mark.sh
# Exit:   0 if every fixture's native marked AST matches the interpreter;
#         2 if the build is missing, no C compiler, or libgc is absent (the LLVM
#         gates are opt-in — same skip discipline as the other diff gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
ORACLE="$ROOT/selfhost/mark_main.mdk"
EMIT="$ROOT/selfhost/llvm_bootstrap_lex_main.mdk"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
SELFHOST="$ROOT/selfhost"
FIXDIR="$ROOT/test/parse_fixtures"
CC="${CC:-clang}"

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

LL="$WORK/mark.ll"
BIN="$WORK/mark"
if ! "$MAIN" run "$EMIT" "$RUNTIME" "$CORE" "$ORACLE" "$SELFHOST" > "$LL" 2>"$WORK/emit.err"; then
  echo "FAIL (emit mark_main): $(cat "$WORK/emit.err")"; exit 1
fi
if ! "$CC" -Wl,-stack_size,0x20000000 $GC_CFLAGS "$LL" "$RT" $GC_LIBS -o "$BIN" 2>"$WORK/cc.err"; then
  echo "FAIL (clang mark_main): $(cat "$WORK/cc.err")"; exit 1
fi

pass=0; fail=0
for fix in "$FIXDIR"/*.mdk; do
  [ -f "$fix" ] || continue
  name="$(basename "$fix")"
  ref="$("$MAIN" run "$ORACLE" "$CORE" "$fix" 2>/dev/null)()"
  self="$("$BIN" "$CORE" "$fix" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1))
    printf 'FAIL %s\n' "$name"
    printf '%s' "$ref"  > "$WORK/ref.txt"
    printf '%s' "$self" > "$WORK/self.txt"
    diff "$WORK/ref.txt" "$WORK/self.txt" | head -20 | sed 's/^/    /'
  fi
done

printf '\n%d ok, %d failing (of %d)\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
