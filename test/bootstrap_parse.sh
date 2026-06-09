#!/bin/sh
# BOOTSTRAP (B2) — the SECOND native self-compile slice: natively compile the
# self-hosted PARSER and prove its AST S-expression byte-matches the tree-walker
# interpreter over real fixtures.  The parser exercises far more of the compiler
# than the lexer (more ADTs, records, typeclass dispatch, prelude), so this gate
# surfaces emitter-correctness bugs the lexer never reached.
#
# Like bootstrap_lex.sh (and unlike diff_selfhost_llvm_modules.sh, which forces
# an EMPTY core prelude), this pushes the REAL stdlib/core.mdk through
# emitProgram — the actual bootstrap gate.  The driver
# (selfhost/llvm_bootstrap_lex_main.mdk) is GENERIC: it takes the entry as an
# argument, enables gap-recording so the UNREACHABLE dead-code gaps in core.mdk
# become harmless "0" placeholders, runs the REAL emitProgram, and applies
# private_mangle.mangleUnits.  The byte-diff is the safety net: a gap the parser
# ACTUALLY reaches would make a fixture diverge and FAIL.
#
# For each fixture in test/parse_fixtures/*.mdk:
#   oracle = medaka run selfhost/parse_main.mdk <fixture>          (the interpreter)
#   native = ./parse <fixture>  (emit parse_main's graph once -> clang -> run)
# Both sides emit SELFHOST S-expressions (native selfhost vs interpreted
# selfhost), so — unlike diff_selfhost_parse.sh (selfhost-vs-OCaml, needs float
# normalization) — a raw byte-diff is correct here.
#
# parse_main's `main : <IO> Unit` -> the native runtime auto-prints main's Unit
# value as a trailing "()\n"; parse_main's `putStr (programToSexp …)` has NO
# trailing newline, so the invariant native suffix is exactly "()\n".  We append
# "()" to the oracle output before the diff (same convention as bootstrap_lex.sh).
#
# Usage:  sh test/bootstrap_parse.sh
# Exit:   0 if every fixture's native AST matches the interpreter;
#         2 if the build is missing, no C compiler, or libgc is absent (the LLVM
#         gates are opt-in — same skip discipline as the other diff gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
ORACLE="$ROOT/selfhost/parse_main.mdk"
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

LL="$WORK/parse.ll"
BIN="$WORK/parse"
if ! "$MAIN" run "$EMIT" "$RUNTIME" "$CORE" "$ORACLE" "$SELFHOST" > "$LL" 2>"$WORK/emit.err"; then
  echo "FAIL (emit parse_main): $(cat "$WORK/emit.err")"; exit 1
fi
# `-Wl,-stack_size` grows the MAIN-THREAD stack (default ~8 MB on macOS): the
# self-hosted combinator parser recurses deeply (the precedence ladder + the
# `andThen`/`runP` monad chain), so a real-file-sized source can overflow the
# default stack and SIGSEGV.  512 MB clears every realistic input (mirrors
# bootstrap_lex.sh; the small fixtures here never need it — future-proofing).
if ! "$CC" -Wl,-stack_size,0x20000000 $GC_CFLAGS "$LL" "$RT" $GC_LIBS -o "$BIN" 2>"$WORK/cc.err"; then
  echo "FAIL (clang parse_main): $(cat "$WORK/cc.err")"; exit 1
fi

pass=0; fail=0
for fix in "$FIXDIR"/*.mdk; do
  [ -f "$fix" ] || continue
  name="$(basename "$fix")"
  # oracle IO stdout + the invariant native Unit auto-print.  parse_main's `main`
  # renders the AST via `putStr (programToSexp …)` (NO trailing newline), so the
  # oracle ends at the last char with no newline.  The native binary appends the
  # runtime Unit auto-print `()\n`; `$(…)` strips the trailing newline, leaving
  # `…()`.  So append exactly `()` (no surrounding newline) to the oracle.
  ref="$("$MAIN" run "$ORACLE" "$fix" 2>/dev/null)()"
  self="$("$BIN" "$fix" 2>/dev/null)"
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
