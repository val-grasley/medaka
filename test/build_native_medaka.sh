#!/bin/sh
# BUILD THE NATIVE `medaka` CLI — OCaml-free, from the checked-in IR seed.
#
# This is the canonical build of the native compiler post-milestone-flip: it uses
# NO `dune` / OCaml `main.exe` / interpreter anywhere.  Flow:
#
#   1. test/bootstrap_from_seed.sh  ->  ./medaka_emitter
#      (clang the committed seed selfhost/seed/emitter.ll into a native emitter,
#       verifying C3a: the seed reproduces from current sources byte-for-byte).
#   2. ./medaka_emitter <runtime> <core> selfhost/driver/medaka_cli.mdk <selfhost> <stdlib>
#       ->  medaka_cli.ll   (the native emitter emitting the CLI's module graph;
#       trim the trailing interpreter Unit `()` if present).
#   3. clang(medaka_cli.ll) + runtime/medaka_rt.c + libgc  ->  ./medaka
#
# The result is a self-contained ~1.4 MB native `medaka` binary that does
# check/fmt/new/build/run/test/repl/lsp with no OCaml at runtime OR build time.
# (`medaka build` itself shells out to an emitter; set MEDAKA_EMITTER=./medaka_emitter
#  so user builds are also OCaml-free — see the printed hint at the end.)
#
# OPT-IN like the other LLVM scripts: skips cleanly (exit 2) when clang or libgc
# is absent.
#
# Usage:  sh test/build_native_medaka.sh [output-path]   (default ./medaka)
# Exit:   0 on success; 2 if clang/libgc absent (opt-in skip); 1 on any failure.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="${CC:-clang}"
STACK_SIZE="${STACK_SIZE:-0x20000000}"
OUT="${1:-$ROOT/medaka}"
EMITTER="$ROOT/medaka_emitter"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
CLI="$ROOT/selfhost/driver/medaka_cli.mdk"
SELFHOST="$ROOT/selfhost"
STDLIB="$ROOT/stdlib"

# ---- STEP 1: bootstrap the native emitter from the seed (OCaml-free) --------
echo "step 1: bootstrap native emitter from seed ..."
if ! sh "$ROOT/test/bootstrap_from_seed.sh" "$EMITTER"; then
  rc=$?
  [ "$rc" = 2 ] && { echo "skipping (clang/libgc absent)"; exit 2; }
  echo "FAIL: bootstrap_from_seed did not produce $EMITTER"; exit 1
fi

# Resolve GC flags the same way bootstrap_from_seed does (it already proved they exist).
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then
  GC_CFLAGS="$(pkg-config --cflags bdw-gc)"; GC_LIBS="$(pkg-config --libs bdw-gc)"
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then
  GC_CFLAGS="-I$GC_PREFIX/include"; GC_LIBS="-L$GC_PREFIX/lib -lgc"
else
  GC_CFLAGS=""; GC_LIBS="-lgc"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

trim_unit() {
  f="$1"
  if [ "$(tail -c 3 "$f" | od -An -tx1 | tr -d ' \n')" = "28290a" ]; then
    head -c $(( $(wc -c < "$f") - 3 )) "$f" > "$f.trim" && mv "$f.trim" "$f"
  fi
}

# ---- STEP 2: native emitter emits the medaka_cli graph ----------------------
CLI_LL="$WORK/medaka_cli.ll"
echo "step 2: medaka_emitter -> medaka_cli.ll ..."
if ! "$EMITTER" "$RUNTIME" "$CORE" "$CLI" "$SELFHOST" "$STDLIB" > "$CLI_LL" 2>"$WORK/emit.err"; then
  echo "FAIL (emitter crashed compiling medaka_cli.mdk):"; cat "$WORK/emit.err"; exit 1
fi
trim_unit "$CLI_LL"
[ -s "$CLI_LL" ] || { echo "FAIL: empty IR for medaka_cli.mdk"; cat "$WORK/emit.err"; exit 1; }

# ---- STEP 3: clang the CLI IR into the native medaka binary ------------------
echo "step 3: clang(medaka_cli.ll) -> $OUT ..."
if ! "$CC" -Wl,-stack_size,"$STACK_SIZE" $GC_CFLAGS "$CLI_LL" "$RT" $GC_LIBS -o "$OUT" 2>"$WORK/cc.err"; then
  echo "FAIL (clang medaka): $(cat "$WORK/cc.err")"; exit 1
fi

echo
echo "BUILT $OUT — native, OCaml-free."
echo "For OCaml-free user builds too, export MEDAKA_EMITTER=$EMITTER (so 'medaka build' uses the native emitter)."
