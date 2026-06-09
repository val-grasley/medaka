#!/bin/sh
# SELF-COMPILE C1 — prove the NATIVE-compiled emitter reproduces the INTERPRETED
# emitter's LLVM IR, byte-for-byte.
#
# The bootstrap_*.sh slices natively compiled each of the SEVEN pipeline stages
# (lex/parse/desugar/resolve/mark/typecheck/eval) and proved each byte-matches the
# tree-walker.  This is the first step of self-hosting the COMPILER BACK-END:
# natively compile the EMITTER ITSELF — selfhost/llvm_emit_modules_main.mdk's whole
# module graph (llvm_emit.mdk + core_ir_lower.mdk + the front end + prelude) — and
# prove the resulting native `emit` binary turns each fixture into the SAME LLVM IR
# the interpreted emitter does.
#
# This is the largest, most string-heavy emit target yet (the `.ll` is ~10 MB) and
# the FIRST time the emitter's OWN code runs natively — so it exercises emitter
# correctness that the earlier slices never did (string building, Emit-record Ref
# state, fresh-id counters, decision-tree lowering of impl bodies).
#
# BUILD.  The native emitter is built by the gap-tolerant bootstrap driver
# (selfhost/llvm_bootstrap_lex_main.mdk: generic, entry-as-arg, gap-recording on,
# private_mangle).  Gap-recording turns the prelude's dead-code gaps into
# placeholders during THIS build; the resulting native binary's own runtime
# emitProgram has gap-recording OFF — identical to the interpreted
# llvm_emit_modules_main — and the fixtures are gap-free, so neither hits a gap.
#
# VALIDATE.  For each test/llvm_fixtures_modules/<dir> (the SAME corpus + invocation
# as diff_selfhost_llvm_modules.sh, EMPTY core prelude, dir as the root):
#   ir_interp = MAIN run llvm_emit_modules_main.mdk <runtime> <empty_core> <entry> <dir>
#   ir_native = ./emit                              <runtime> <empty_core> <entry> <dir>
#   diff ir_native vs ir_interp BYTE-FOR-BYTE.
# No need to clang/run the IR — diff_selfhost_llvm_modules.sh already proves the
# interpreted-emitter IR compiles + runs correctly; native IR == interpreted IR
# byte-for-byte ⇒ it runs correctly too.
#
# UNIT AUTO-PRINT.  llvm_emit_modules_main's `main : <IO, Mut> Unit` `putStr`s the IR
# text (no trailing newline of its own — emitProgram's last line ends in "}\n"), and
# the native runtime ADDITIONALLY auto-prints main's Unit value as a trailing "()\n"
# (runtime/medaka_rt.c mdk_print_unit).  The interpreted driver does NOT auto-print.
# So the invariant native suffix is exactly the interpreted IR bytes ++ "()\n".  We
# append "()\n" to the interpreted IR before the byte-diff — the IR body before that
# suffix is compared byte-for-byte (same convention as the bootstrap_*.sh harnesses).
#
# Usage:  sh test/selfcompile_emit.sh
# Exit:   0 if all 6 fixtures reproduce byte-for-byte;
#         2 if the build is missing, no C compiler, or libgc is absent (opt-in, same
#           skip discipline as the diff_selfhost_llvm*.sh gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
DRIVER="$ROOT/selfhost/llvm_bootstrap_lex_main.mdk"
EMIT="$ROOT/selfhost/llvm_emit_modules_main.mdk"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
SELFHOST="$ROOT/selfhost"
FIXDIR="$ROOT/test/llvm_fixtures_modules"
CC="${CC:-clang}"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping spike"; exit 2; }

# libgc (bdw-gc) detection — VERBATIM from the diff_selfhost_llvm*.sh gates.
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

# Empty prelude — the fixtures are prelude-free (touch only runtime externs), and
# full stdlib/core.mdk is itself outside today's emit subset.  Same as the
# diff_selfhost_llvm_modules.sh <core> arg.
EMPTY_CORE="$WORK/empty_core.mdk"
: > "$EMPTY_CORE"

# 1. Build the native `emit` binary: gap-tolerant driver emits the WHOLE
#    llvm_emit_modules_main module graph (real stdlib/core.mdk prelude at BUILD
#    time so its dead-code gaps become placeholders), clang + medaka_rt.c + libgc +
#    a 512 MB stack.
LL="$WORK/emit.ll"
BIN="$WORK/emit"
echo "building native emitter (this is the largest emit target — ~10 MB IR) ..."
if ! "$MAIN" run "$DRIVER" "$RUNTIME" "$CORE" "$EMIT" "$SELFHOST" > "$LL" 2>"$WORK/emit.err"; then
  echo "FAIL (emit llvm_emit_modules_main): $(cat "$WORK/emit.err")"; exit 1
fi
if ! "$CC" -Wl,-stack_size,0x20000000 $GC_CFLAGS "$LL" "$RT" $GC_LIBS -o "$BIN" 2>"$WORK/cc.err"; then
  echo "FAIL (clang native emitter): $(cat "$WORK/cc.err")"; exit 1
fi

# 2. For each fixture: diff native IR vs interpreted IR byte-for-byte.
pass=0; fail=0
for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  entry="$dir/entry.mdk"
  [ -f "$entry" ] || { echo "skip $(basename "$dir") (no entry.mdk)"; continue; }
  name="$(basename "$dir")"
  # interpreted IR ++ the invariant native Unit auto-print suffix "()\n".
  "$MAIN" run "$EMIT" "$RUNTIME" "$EMPTY_CORE" "$entry" "${dir%/}" > "$WORK/$name.interp" 2>"$WORK/$name.ierr"
  if [ -s "$WORK/$name.ierr" ] && ! [ -s "$WORK/$name.interp" ]; then
    fail=$((fail+1)); printf 'FAIL %s (interp emit)\n%s\n' "$name" "$(cat "$WORK/$name.ierr")"; continue
  fi
  printf '()\n' >> "$WORK/$name.interp"
  # native IR.
  if ! "$BIN" "$RUNTIME" "$EMPTY_CORE" "$entry" "${dir%/}" > "$WORK/$name.native" 2>"$WORK/$name.nerr"; then
    fail=$((fail+1)); printf 'FAIL %s (native emit crashed)\n%s\n' "$name" "$(cat "$WORK/$name.nerr")"; continue
  fi
  if cmp -s "$WORK/$name.interp" "$WORK/$name.native"; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1))
    printf 'FAIL %s (IR diverges)\n' "$name"
    diff "$WORK/$name.interp" "$WORK/$name.native" | head -20
  fi
done

printf '\n%d/%d fixtures reproduce the interpreter IR byte-for-byte\n' "$pass" "$((pass+fail))"
[ "$fail" -eq 0 ]
