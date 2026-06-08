#!/bin/sh
# MULTI-MODULE emit+RUN equivalence gate for the native backend — the validation
# foundation for the whole-compiler push (STAGE2-DESIGN.md §2.4 / PLAN.md "Native
# backend").
#
# The single-file typed gate (diff_selfhost_llvm_typed.sh) byte-validates the
# prelude-free dispatch subset; the gaps probe (llvm_emit_gaps_main.mdk) only
# MEASURES emittability of the multi-module path.  Nothing else emits a
# multi-module program, links it, runs it, and diffs the oracle.  This gate fills
# that hole: it is the multi-module analog of diff_selfhost_llvm_typed.sh, giving
# the upcoming E4 arg-position routing port (and the rest of the whole-compiler
# work) a byte-verified harness to grow into.
#
# For each fixture SET (a subdirectory of test/llvm_fixtures_modules/ holding an
# `entry.mdk` with `main` plus its imported sibling module file(s)):
#   1. ref  = medaka run eval_typed_modules_main.mdk <runtime> <core> <entry> <dir>
#             (loader -> desugar -> elaborateModules -> evalModules; captured stdout)
#   2. ll   = medaka run llvm_emit_modules_main.mdk  <runtime> <core> <entry> <dir>
#             (the SAME front end, final consumer swapped to emit textual LLVM IR)
#   3. bin  = clang <ll> runtime/medaka_rt.c -o bin   (compile + link the stub)
#   4. self = ./bin
#   diff ref vs self byte-for-byte.
#
# PRELUDE.  The fixtures are PRELUDE-FREE in the same sense the single-file typed
# gate's are: they touch only runtime externs (intToString/putStrLn/...), so they
# need no core.mdk machinery.  The full stdlib/core.mdk prelude is itself OUTSIDE
# today's emit subset (emitProgram panics on its `max`/`fold` arg-position-dispatch
# gaps — exactly what llvm_emit_gaps_main.mdk's census measures), and emitProgram
# has no dead-code elimination, so passing full core.mdk would emit those gaps and
# abort.  So the gate passes an EMPTY prelude file as the <core> arg — the
# multi-module analog of the single-file gate passing ONLY runtime.mdk.  The
# driver's signature still takes <core> verbatim (it is a drop-in for
# eval_typed_modules_main.mdk and E4-ready), so when more of the prelude becomes
# emittable this gate flips to the real stdlib/core.mdk by changing one variable.
#
# Scope: cross-module DATA (ctor construct/match/call across the boundary),
# cross-module RETURN-POSITION dispatch (RKey, impl at an imported type), and
# cross-module ARG-POSITION ADT dispatch (arg-tag over imported constructors).
# Arg-position dispatch on a PRIMITIVE receiver is deliberately AVOIDED — that is
# the still-gapping case the NEXT task (E4) unlocks; this gate is its harness.
#
# Usage:  sh test/diff_selfhost_llvm_modules.sh
# Exit:   0 if every fixture's native stdout matches the typed multi-module oracle;
#         2 if the build is missing, no C compiler is available, or libgc is absent
#         (the LLVM gates are opt-in — same skip discipline as diff_selfhost_llvm_typed.sh).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
ORACLE="$ROOT/selfhost/eval_typed_modules_main.mdk"
EMIT="$ROOT/selfhost/llvm_emit_modules_main.mdk"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/llvm_fixtures_modules"
CC="${CC:-clang}"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping spike"; exit 2; }

# libgc (bdw-gc) detection — VERBATIM from diff_selfhost_llvm_typed.sh.
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

# Empty prelude — see the PRELUDE note above.  Flip CORE to "$ROOT/stdlib/core.mdk"
# once more of the prelude is emittable.
CORE="$WORK/empty_core.mdk"
: > "$CORE"

pass=0; fail=0
for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  entry="$dir/entry.mdk"
  [ -f "$entry" ] || { echo "skip $(basename "$dir") (no entry.mdk)"; continue; }
  name="$(basename "$dir")"
  # ref = the typed multi-module oracle's CAPTURED IO stdout.  The native runtime
  # ADDITIONALLY auto-prints the value of `main` (every fixture's `main : <IO> Unit`,
  # so that auto-print is invariantly "()\n" — see runtime/medaka_rt.c mdk_print_unit
  # + emitProgram's emitPrint on the main body); the oracle's evalModulesOutput does
  # NOT auto-print the result.  This is the SAME native auto-print convention the
  # single-file gates rely on (their oracle core_ir_dict_pp_main / eval_probe DO
  # auto-print the value, so it matches there).  To keep that convention explicit for
  # the IO-capture oracle, append the invariant Unit print to ref before the diff —
  # the comparison is then native-stdout == oracle-IO-output ++ Unit-result-print,
  # byte-for-byte.
  ref="$("$MAIN" run "$ORACLE" "$RUNTIME" "$CORE" "$entry" "${dir%/}" 2>/dev/null)
()"
  ll="$WORK/$name.ll"
  bin="$WORK/$name.bin"
  if ! "$MAIN" run "$EMIT" "$RUNTIME" "$CORE" "$entry" "${dir%/}" > "$ll" 2>"$WORK/emit.err"; then
    fail=$((fail+1)); printf 'FAIL %s (emit)\n%s\n' "$name" "$(cat "$WORK/emit.err")"; continue
  fi
  if ! "$CC" $GC_CFLAGS "$ll" "$RT" $GC_LIBS -o "$bin" 2>"$WORK/cc.err"; then
    fail=$((fail+1)); printf 'FAIL %s (clang)\n%s\n' "$name" "$(cat "$WORK/cc.err")"; continue
  fi
  self="$("$bin" 2>/dev/null)"
  # one-line label: the IO output (ref without its appended Unit print)
  show="$("$MAIN" run "$ORACLE" "$RUNTIME" "$CORE" "$entry" "${dir%/}" 2>/dev/null | tr '\n' ' ')"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s (%s)\n' "$name" "$show"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
