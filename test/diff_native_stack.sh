#!/bin/sh
# diff_native_stack.sh — deep-recursion / large-stack native-backend gate.
#
# Fixtures in test/stack_fixtures{,_typed}/ build a single deep-recursion `main`
# value (e.g. a 2_000_000-element fold).  Each fixture is native-compiled via the
# self-hosted LLVM emitter, clang'd with a 512 MiB stack, run, and its stdout
# compared against a frozen GOLDEN.
#
# OCaml-free (REROOT-PLAN.md Phase 3 / §2d):
#   * emitter HOST: the pre-compiled native emitter test/bin/llvm_emit_main
#     (plain) / test/bin/llvm_emit_typed_main (typed), built by
#     test/build_oracles.sh — replaces the OCaml-hosted llvm_emit*_main run.
#   * value ORACLE: the committed <fixture>.eval.golden (the pp_value of `main`)
#     captured by test/capture_goldens.sh from the OCaml value probe while OCaml
#     was trusted — replaces the live OCaml value oracle.  Fixed fixtures => golden.
#
# Usage:  sh test/diff_native_stack.sh
# Exit:   0 all match; 2 opt-in skip (no clang/libgc, or oracles not built).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMITBIN="$ROOT/test/bin/llvm_emit_main"
EMITBIN_TYPED="$ROOT/test/bin/llvm_emit_typed_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
RT="$ROOT/runtime/medaka_rt.c"
FIXDIR="$ROOT/test/stack_fixtures"
FIXDIR_TYPED="$ROOT/test/stack_fixtures_typed"
CC="${CC:-clang}"

# Collect ALL missing oracles before failing — naming only the first costs a
# round-trip per oracle in a fresh worktree (#398).
_missing=""
[ -x "$EMITBIN" ] || _missing="$_missing $EMITBIN"
[ -x "$EMITBIN_TYPED" ] || _missing="$_missing $EMITBIN_TYPED"
if [ -n "$_missing" ]; then
  echo "build oracles first — missing:"
  for _m in $_missing; do
    echo "  FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$_m")  (missing $_m)"
  done
  exit 2
fi
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

# The native emitter binaries auto-print main's Unit return as a trailing "()\n"
# appended to the emitted IR text; clang rejects it as a stray top-level entity.
# Strip a sole trailing "()\n" (bytes 28 29 0a) from the .ll before compiling.
trim_unit_ll() {
  f="$1"
  if [ "$(tail -c 3 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "28290a" ]; then
    head -c $(( $(wc -c < "$f") - 3 )) "$f" > "$f.trim" && mv "$f.trim" "$f"
  fi
}

pass=0; fail=0

# compile_run_check NAME LLFILE GOLDENFILE
compile_run_check() {
  cr_name="$1"; cr_ll="$2"; cr_golden="$3"
  cr_bin="$WORK/$cr_name.bin"
  if [ ! -f "$cr_golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (no golden — run sh test/capture_goldens.sh stack)\n' "$cr_name"; return
  fi
  cr_ref="$(cat "$cr_golden")"
  if ! "$CC" -O2 -pthread $GC_CFLAGS "$cr_ll" "$RT" $GC_LIBS -lm -o "$cr_bin" 2>"$WORK/cc.err"; then
    fail=$((fail+1)); printf 'FAIL %s (clang)\n%s\n' "$cr_name" "$(cat "$WORK/cc.err")"; return
  fi
  # The native runtime auto-prints main's Unit return as a trailing "()" line; the
  # value golden has none — drop a sole trailing "()".
  cr_self="$("$cr_bin" 2>/dev/null | sed '${/^()$/d;}')"; cr_code=$?
  if [ "$cr_code" -ne 0 ]; then
    fail=$((fail+1)); printf 'FAIL %s (exit %d — SIGSEGV/overflow?)\n  ref : %s\n' "$cr_name" "$cr_code" "$cr_ref"; return
  fi
  if [ "$cr_ref" = "$cr_self" ]; then pass=$((pass+1)); printf 'ok   %s (%s)\n' "$cr_name" "$cr_self"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$cr_name" "$cr_ref" "$cr_self"; fi
}

# Prelude-free fixtures: native emitter test/bin/llvm_emit_main <file>.
n_pf=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  n_pf=$((n_pf+1))
  name="$(basename "$f")"
  golden="${f%.mdk}.eval.golden"
  ll="$WORK/$name.ll"
  if ! "$EMITBIN" "$f" > "$ll" 2>"$WORK/emit.err"; then
    fail=$((fail+1)); printf 'FAIL %s (emit)\n%s\n' "$name" "$(cat "$WORK/emit.err")"; continue
  fi
  trim_unit_ll "$ll"
  compile_run_check "$name" "$ll" "$golden"
done

# Typed fixtures: native typed emitter test/bin/llvm_emit_typed_main <runtime> <core> <file>.
n_ty=0
if [ -d "$FIXDIR_TYPED" ]; then
  for f in "$FIXDIR_TYPED"/*.mdk; do
    [ -f "$f" ] || continue
    n_ty=$((n_ty+1))
    name="$(basename "$f")"
    golden="${f%.mdk}.eval.golden"
    ll="$WORK/$name.ll"
    if ! "$EMITBIN_TYPED" "$RUNTIME" "$CORE" "$f" > "$ll" 2>"$WORK/emit.err"; then
      fail=$((fail+1)); printf 'FAIL %s (emit)\n%s\n' "$name" "$(cat "$WORK/emit.err")"; continue
    fi
    trim_unit_ll "$ll"
    compile_run_check "$name" "$ll" "$golden"
  done
fi

printf '\n%d prelude-free + %d typed = %d fixtures: %d ok, %d failing\n' "$n_pf" "$n_ty" "$((n_pf+n_ty))" "$pass" "$fail"
[ "$fail" -eq 0 ]
