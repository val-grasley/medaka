#!/bin/sh
# Native stack-safety gate for TRMC (tail-recursion-modulo-cons) Phase 1
# (TRMC-DESIGN.md, PLAN #56).
#
# A user-written cons-tail list builder (`upto m n = m :: upto (m+1) n`) used to
# SIGSEGV (139) at ~70-80k cons cells on the native LLVM backend, because the
# recursive call sat in the LAST arg of a `::` and every frame stayed live to the
# base case.  TRMC rewrites such a builder into an O(1)-stack destination-passing
# loop (no recursive `call`), so a deep list (2,000,000 elements) now builds and
# is consumed without overflow.
#
# For each fixture in test/stack_fixtures/:
#   ref  = dev/eval_probe.exe <fixture>            (the tree-walker oracle)
#   emit = medaka run llvm_emit_main.mdk <fixture> (Core IR -> textual LLVM IR)
#   clang <emit>.ll runtime/medaka_rt.c -o bin     (LARGE stack for the consumer)
#   self = ./bin
# diff ref vs self byte-for-byte AND require exit 0 (no SIGSEGV).
#
# Usage:  sh test/diff_native_stack.sh
# Exit:   0 if every fixture's native stdout matches the oracle and exits 0; 2 if
#         the build is missing or no C compiler / libgc is available (opt-in).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/_build/default/dev/eval_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
EMIT="$ROOT/selfhost/llvm_emit_main.mdk"
EMIT_TYPED="$ROOT/selfhost/llvm_emit_typed_main.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
RT="$ROOT/runtime/medaka_rt.c"
FIXDIR="$ROOT/test/stack_fixtures"
FIXDIR_TYPED="$ROOT/test/stack_fixtures_typed"
CC="${CC:-clang}"

[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then
  GC_CFLAGS="$(pkg-config --cflags bdw-gc)"; GC_LIBS="$(pkg-config --libs bdw-gc)"
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then
  GC_CFLAGS="-I$GC_PREFIX/include"; GC_LIBS="-L$GC_PREFIX/lib -lgc"
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then
  GC_CFLAGS=""; GC_LIBS="-lgc"
else
  echo "libgc (bdw-gc) not found — skipping (install bdw-gc, or set GC_PREFIX)"; exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0

# compile a .ll to a native binary (large stack + -O2; darwin -stack_size, else
# a plain -O2 link), run it, and diff stdout against the oracle `ref`.  Sets the
# global pass/fail counters.  Link with the production build's large stack + -O2
# (build_cmd.mdk).  TRMC makes the BUILDER an O(1)-stack loop (pre-TRMC it SIGSEGV'd
# at ~80k cells regardless of stack size — frames grew unboundedly).  The large
# stack additionally gives Boehm GC's RECURSIVE mark room for very deep (>~1M)
# linked lists — a separate, pre-existing native-runtime limitation, NOT TRMC.
compile_run_check() {
  cr_name="$1"; cr_ll="$2"; cr_ref="$3"
  cr_bin="$WORK/$cr_name.bin"
  if ! "$CC" -O2 -Wl,-stack_size,0x20000000 $GC_CFLAGS "$cr_ll" "$RT" $GC_LIBS -o "$cr_bin" 2>"$WORK/cc.err"; then
    if ! "$CC" -O2 $GC_CFLAGS "$cr_ll" "$RT" $GC_LIBS -o "$cr_bin" 2>"$WORK/cc.err"; then
      fail=$((fail+1)); printf 'FAIL %s (clang)\n%s\n' "$cr_name" "$(cat "$WORK/cc.err")"; return
    fi
  fi
  cr_self="$("$cr_bin" 2>/dev/null)"; cr_code=$?
  if [ "$cr_code" -ne 0 ]; then
    fail=$((fail+1)); printf 'FAIL %s (exit %d — SIGSEGV/overflow?)\n  ref : %s\n' "$cr_name" "$cr_code" "$cr_ref"; return
  fi
  if [ "$cr_ref" = "$cr_self" ]; then pass=$((pass+1)); printf 'ok   %s (%s)\n' "$cr_name" "$cr_self"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$cr_name" "$cr_ref" "$cr_self"; fi
}

# Pass 1 — prelude-free fixtures (top-level builders: Axis A / Phase 1).  Oracle =
# bare eval_probe; emit = llvm_emit_main (no marking, no dispatch).
n_pf=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  n_pf=$((n_pf+1))
  name="$(basename "$f")"
  ref="$("$PROBE" "$f" 2>/dev/null)"
  ll="$WORK/$name.ll"
  if ! "$MAIN" run "$EMIT" "$f" > "$ll" 2>"$WORK/emit.err"; then
    fail=$((fail+1)); printf 'FAIL %s (emit)\n%s\n' "$name" "$(cat "$WORK/emit.err")"; continue
  fi
  compile_run_check "$name" "$ll" "$ref"
done

# Pass 2 — TYPED / stdlib-method fixtures (dispatched impls: Phase 2 B-dispatch).
# A stdlib method (`map`/`filterMap`) needs the prelude, so the oracle is
# `eval_probe --prelude` and the emit path is the TYPED driver (runtime + core →
# llvm_emit.emitProgram, the only driver that produces CMethod dispatch nodes).
n_ty=0
if [ -d "$FIXDIR_TYPED" ]; then
  for f in "$FIXDIR_TYPED"/*.mdk; do
    [ -f "$f" ] || continue
    n_ty=$((n_ty+1))
    name="$(basename "$f")"
    ref="$("$PROBE" --prelude "$f" 2>/dev/null)"
    ll="$WORK/$name.ll"
    if ! "$MAIN" run "$EMIT_TYPED" "$RUNTIME" "$CORE" "$f" > "$ll" 2>"$WORK/emit.err"; then
      fail=$((fail+1)); printf 'FAIL %s (emit)\n%s\n' "$name" "$(cat "$WORK/emit.err")"; continue
    fi
    compile_run_check "$name" "$ll" "$ref"
  done
fi

printf '\n%d prelude-free + %d typed = %d fixtures: %d ok, %d failing\n' "$n_pf" "$n_ty" "$((n_pf+n_ty))" "$pass" "$fail"
[ "$fail" -eq 0 ]

