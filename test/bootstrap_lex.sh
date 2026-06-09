#!/bin/sh
# BOOTSTRAP (B1) — the FIRST native self-compile slice: natively compile the
# self-hosted LEXER and prove its token stream byte-matches the tree-walker
# interpreter over real fixtures.  This is the milestone the whole emitter effort
# has driven toward: a REAL compiler subcommand (the lexer) compiled natively,
# end-to-end (emit textual LLVM IR -> clang -> link libgc + runtime -> run), and
# validated byte-for-byte against `medaka run selfhost/lex_main.mdk`.
#
# Unlike diff_selfhost_llvm_modules.sh (which forces an EMPTY core prelude), this
# pushes the REAL stdlib/core.mdk through emitProgram — the actual bootstrap gate.
# The driver (selfhost/llvm_bootstrap_lex_main.mdk) enables gap-recording before
# emitProgram so the 8 UNREACHABLE dead-code gaps in core.mdk (max/min in
# maximum/minimum, the Arbitrary impls) become harmless "0" placeholders instead
# of aborting.  The byte-diff is the safety net: a gap the lexer ACTUALLY reaches
# would make a fixture diverge and FAIL — a passing diff proves every placeholder
# was dead code.
#
# For each fixture in test/diff_fixtures/*.mdk:
#   oracle = medaka run selfhost/lex_main.mdk <fixture>           (the interpreter)
#   native = ./lex <fixture>   (emit lex_main's graph once -> clang -> run)
# Diff oracle vs native.  The native runtime AUTO-PRINTS main's value
# (lex_main's `main : <IO> Unit` -> a trailing "()\n" via mdk_print_unit) which the
# interpreted oracle does NOT emit; lex_main's `emit` uses `putStr` (no trailing
# newline), so the invariant native suffix is exactly "()\n".  We append "()\n" to
# the oracle output before the diff (the same auto-print convention
# diff_selfhost_llvm_modules.sh relies on).
#
# Usage:  sh test/bootstrap_lex.sh
# Exit:   0 if every fixture's native token stream matches the interpreter;
#         2 if the build is missing, no C compiler, or libgc is absent (the LLVM
#         gates are opt-in — same skip discipline as the other diff gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
ORACLE="$ROOT/selfhost/lex_main.mdk"
EMIT="$ROOT/selfhost/llvm_bootstrap_lex_main.mdk"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
SELFHOST="$ROOT/selfhost"
FIXDIR="$ROOT/test/diff_fixtures"
CC="${CC:-clang}"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping spike"; exit 2; }

# libgc (bdw-gc) detection — VERBATIM from diff_selfhost_llvm_modules.sh.
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

# Emit the native lexer ONCE — lex_main's graph (lexer + util + the REAL core
# prelude) through the gap-tolerant bootstrap driver — then clang+link it.  The
# resulting ./lex is reused across every fixture.
LL="$WORK/lex.ll"
BIN="$WORK/lex"
if ! "$MAIN" run "$EMIT" "$RUNTIME" "$CORE" "$ORACLE" "$SELFHOST" > "$LL" 2>"$WORK/emit.err"; then
  echo "FAIL (emit lex_main): $(cat "$WORK/emit.err")"; exit 1
fi
if ! "$CC" $GC_CFLAGS "$LL" "$RT" $GC_LIBS -o "$BIN" 2>"$WORK/cc.err"; then
  echo "FAIL (clang lex_main): $(cat "$WORK/cc.err")"; exit 1
fi

pass=0; fail=0
for fix in "$FIXDIR"/*.mdk; do
  [ -f "$fix" ] || continue
  name="$(basename "$fix")"
  # oracle IO stdout + the invariant native Unit auto-print.  lex_main's `emit`
  # renders the token stream via `joinNl` (NO trailing newline) and `putStr`, so
  # the oracle ends at the last token (e.g. `EOF`) with no newline.  The native
  # binary appends the runtime Unit auto-print `()\n` directly after that, giving
  # `…EOF()\n`; `$(…)` strips the trailing newline from `self`, leaving `…EOF()`.
  # So append exactly `()` (no surrounding newline) to the oracle to match.
  # (The sibling diff_selfhost_llvm_modules.sh appends `\n()` instead because its
  # oracle output IS newline-terminated — that form is wrong for joinNl output.)
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
