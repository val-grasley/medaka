#!/bin/sh
# BOOTSTRAP (B7) — the SEVENTH and LAST per-stage native self-compile slice:
# natively compile the self-hosted EVAL stage (the tree-walking interpreter
# itself — ~1765 lines: closures/env/match, VMulti untyped typeclass dispatch,
# externBindings primitive table, pp_value rendering) and prove its rendered
# `main` value byte-matches the tree-walker interpreter over real fixtures.
#
# With B7, ALL SEVEN pipeline stages (lex → parse → desugar → resolve → mark →
# typecheck → eval) are individually native-compiled and proven equal to the
# interpreter.
#
# eval_main takes ONE file-path arg:
#   <target.mdk>
# It parses + desugars a self-contained / prelude-free program, evaluates it via
# the UNTYPED engine path (arg-tag "first impl wins" runtime VMulti dispatch — no
# marker/typecheck), and putStrLn's `pp_value` of the `main` binding.  The
# fixtures (test/eval_fixtures/*.mdk) aggregate their results into a single
# `main` value, so the output is ONE deterministic pp_value line.  Both sides run
# the SAME eval, so there is NO sort and NO float normalization — the value
# content is compared byte-for-byte.
#
# Like bootstrap_{lex,parse,desugar,resolve,mark,typecheck}.sh, this pushes the
# REAL stdlib/core.mdk + parser.mdk + desugar.mdk + the ~1765-line eval.mdk
# through emitProgram at EMIT time (the actual bootstrap gate).  The driver
# (selfhost/llvm_bootstrap_lex_main.mdk) is GENERIC: entry = eval_main as an
# argument, gap-recording on, real emitProgram, private_mangle.mangleUnits.
#
# For each fixture in test/eval_fixtures/*.mdk:
#   oracle = medaka run selfhost/eval_main.mdk <fixture>   (interpreter)
#   native = ./eval <fixture>                              (native-compiled)
# Both sides render the SAME `main` value via pp_value.
#
# eval_main's `main : <IO, Mut> Unit` -> the native runtime auto-prints main's
# Unit value as a trailing "()\n"; eval_main's `putStrLn (pp_value …)` emits
# "<value>\n", so the invariant native suffix is exactly "<value>\n()\n".  We
# append "()" to the oracle output (same convention as the prior bootstrap_*.sh);
# under $(…) command substitution the trailing newline is stripped on both sides,
# so oracle "<value>\n()" matches native "<value>\n()".  The value content
# preceding "()" is compared byte-for-byte.
#
# Usage:  sh test/bootstrap_eval.sh
# Exit:   0 if every fixture's native value matches the interpreter;
#         2 if the build is missing, no C compiler, or libgc is absent.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
ORACLE="$ROOT/selfhost/eval_main.mdk"
EMIT="$ROOT/selfhost/llvm_bootstrap_lex_main.mdk"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
SELFHOST="$ROOT/selfhost"
FIXDIR="$ROOT/test/eval_fixtures"
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

LL="$WORK/eval.ll"
BIN="$WORK/eval"
if ! "$MAIN" run "$EMIT" "$RUNTIME" "$CORE" "$ORACLE" "$SELFHOST" > "$LL" 2>"$WORK/emit.err"; then
  echo "FAIL (emit eval_main): $(cat "$WORK/emit.err")"; exit 1
fi
if ! "$CC" -Wl,-stack_size,0x20000000 $GC_CFLAGS "$LL" "$RT" $GC_LIBS -o "$BIN" 2>"$WORK/cc.err"; then
  echo "FAIL (clang eval_main): $(cat "$WORK/cc.err")"; exit 1
fi

pass=0; fail=0
for fix in "$FIXDIR"/*.mdk; do
  [ -f "$fix" ] || continue
  name="$(basename "$fix")"
  # The interpreted oracle's `putStrLn` prints "<value>\n"; $(…) strips the trailing
  # newline, leaving "<value>".  The native binary additionally auto-prints main's
  # Unit as "()\n", so its stdout is "<value>\n()\n" → $(…) → "<value>\n()".  Rebuild
  # the oracle to the same shape: "<value>" + newline + "()".  The value content is
  # compared byte-for-byte; only the invariant Unit-auto-print suffix is appended.
  ref="$("$MAIN" run "$ORACLE" "$fix" 2>/dev/null)
()"
  self="$("$BIN" "$fix" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1))
    printf 'FAIL %s\n' "$name"
    printf '    ref : %s\n' "$ref"
    printf '    self: %s\n' "$self"
  fi
done

printf '\n%d ok, %d failing (of %d)\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
