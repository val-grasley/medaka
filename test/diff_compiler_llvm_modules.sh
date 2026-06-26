#!/bin/sh
# MULTI-MODULE emit+RUN equivalence gate for the native backend — the validation
# foundation for the whole-compiler push (STAGE2-DESIGN.md §2.4 / PLAN.md "Native
# backend").
#
# The multi-module analog of diff_compiler_llvm_typed.sh: emit a multi-module
# program, link it, run it, and diff the committed value golden.
#
# For each fixture SET (a subdirectory of test/llvm_fixtures_modules/ holding an
# `entry.mdk` with `main` plus its imported sibling module file(s)):
#   1. ref  = test/llvm_fixtures_modules/<dir>/entry.eval.golden
#             (captured from `main.exe run eval_typed_modules_main.mdk <runtime>
#              <empty-core> <entry> <dir>` — loader -> desugar -> elaborateModules
#              -> evalModules; the program's CAPTURED IO stdout, NO Unit auto-print)
#   2. ll   = test/bin/llvm_emit_modules_main <runtime> <empty-core> <entry> <dir>
#             (the SAME front end, final consumer swapped to emit textual LLVM IR)
#   3. bin  = clang <ll> runtime/medaka_rt.c -o bin   (compile + link the stub)
#   4. self = ./bin  (the native runtime ADDITIONALLY auto-prints main's Unit result
#             as a trailing "()" line; strip_unit removes it so it matches the
#             IO-capture golden — see runtime/medaka_rt.c mdk_print_unit)
#   diff ref vs self byte-for-byte.
#
# PRELUDE.  The fixtures are PRELUDE-FREE (they touch only runtime externs), so the
# gate passes an EMPTY prelude file as the <core> arg — the multi-module analog of
# the single-file gate passing ONLY runtime.mdk.
#
# Scope: cross-module DATA, cross-module RETURN-POSITION dispatch (RKey), and
# cross-module ARG-POSITION ADT dispatch.  Arg-position dispatch on a PRIMITIVE
# receiver is deliberately AVOIDED.
#
# OCaml-free (REROOT-PLAN.md Phase 2): the emitter runs as the pre-compiled native
# binary test/bin/llvm_emit_modules_main (built by test/build_oracles.sh); the
# reference is the committed entry.eval.golden.
#
# Usage:  sh test/diff_compiler_llvm_modules.sh
# Exit:   0 if every fixture's native stdout matches the golden; 2 if the build is
#         missing, no C compiler is available, or libgc is absent (opt-in).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMITBIN="$ROOT/test/bin/llvm_emit_modules_main"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/llvm_fixtures_modules"
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

# Empty prelude file (see PRELUDE note above).
CORE="$WORK/empty_core.mdk"
 > "$CORE"

# The native binary auto-prints main's Unit result as a trailing "()"; the
# IO-capture golden has none — drop a sole trailing "()" line from native stdout.
strip_unit() { perl -0pe 's/\(\)\s*\z//'; }

pass=0; fail=0
for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  entry="$dir/entry.mdk"
  [ -f "$entry" ] || { echo "skip $(basename "$dir") (no entry.mdk)"; continue; }
  name="$(basename "$dir")"
  golden="${dir%/}/entry.eval.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh)"; fail=$((fail+1)); continue; }
  ref="$(cat "$golden")"
  ll="$WORK/$name.ll"
  bin="$WORK/$name.bin"
  if ! "$EMITBIN" "$RUNTIME" "$CORE" "$entry" "${dir%/}" > "$WORK/raw.ll" 2>"$WORK/emit.err"; then
    fail=$((fail+1)); printf 'FAIL %s (emit)\n%s\n' "$name" "$(cat "$WORK/emit.err")"; continue
  fi
  strip_unit < "$WORK/raw.ll" > "$ll"
  if ! "$CC" $GC_CFLAGS "$ll" "$RT" $GC_LIBS -o "$bin" 2>"$WORK/cc.err"; then
    fail=$((fail+1)); printf 'FAIL %s (clang)\n%s\n' "$name" "$(cat "$WORK/cc.err")"; continue
  fi
  self="$("$bin" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s (%s)\n' "$name" "$(printf '%s' "$ref" | tr '\n' ' ')"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
