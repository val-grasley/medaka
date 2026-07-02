#!/bin/sh
# TYPED equivalence gate for the Stage 2.4 LLVM de-risking spike, slices 6–7 —
# TYPECLASS DISPATCH (STAGE2-DESIGN.md §2.4a).
#
# Dispatch needs types: a return-position method resolves by the RESULT type (RKey),
# which the untyped arg-tag fallback cannot do (eval_probe renders these fixtures
# WRONG).  So the reference is the TYPED Core IR tree-walker value, captured into
# <name>.eval.golden from `main.exe run core_ir_dict_pp_main.mdk runtime.mdk <fixture>`
# (desugar -> elaborateDict: route-stamp + dict_pass -> lower -> ceval, pp_value of
# `main`) while OCaml was trusted.  The equivalence the slice proves is exactly
# emit->clang->run == that typed-ceval value, over one typed IR.
#
# For each prelude-free dispatch fixture in test/llvm_fixtures_typed/:
#   1. ref  = test/llvm_fixtures_typed/<name>.eval.golden   (the typed-ceval value)
#   2. emit = test/bin/llvm_emit_typed_main runtime.mdk <fixture>
#             (the SAME front end, final consumer swapped to emit textual LLVM IR)
#   3. clang <emit>.ll runtime/medaka_rt.c -o bin
#   4. self = ./bin
#   diff ref vs self byte-for-byte.
#
# The fixtures are prelude-free (their own interface + impls) and reduce `main` to a
# scalar Int, so the harness passes ONLY runtime.mdk.
#
# Scope: slice 6 (RKey return-position dispatch + RDict/RDictFwd dict-passing) and
# slice 7 (arg-position arg-tag dispatch).  No nested per-instance requires dicts, no GC.
#
# OCaml-free (REROOT-PLAN.md Phase 2): the emitter runs as the pre-compiled native
# binary test/bin/llvm_emit_typed_main (built by test/build_oracles.sh); the reference
# is the committed .eval.golden.
#
# Usage:  sh test/diff_compiler_llvm_typed.sh
# Exit:   0 if every fixture's native stdout matches the golden; 2 if the build is
#         missing or no C compiler is available (spike is opt-in).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMITBIN="$ROOT/test/bin/llvm_emit_typed_main"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/llvm_fixtures_typed"
CC="${CC:-clang}"

# ── Per-fixture worker (parallel fan-out target); shared state via env ─────────
if [ "${1:-}" = "--one" ]; then
  f="$2"
  name="$(basename "$f")"
  golden="${f%.mdk}.eval.golden"
  ll="$WORKDIR/$name.ll"; bin="$WORKDIR/$name.bin"
  st=0; msg=""
  if [ ! -f "$golden" ]; then
    msg="no golden for $name (run sh test/capture_goldens.sh)"; st=1
  elif ! "$EMITBIN" "$RUNTIME" "$f" 2>"$WORKDIR/$name.emit.err" | perl -0pe 's/\(\)\s*\z//' > "$ll"; then
    msg="$(printf 'FAIL %s (emit)\n%s' "$name" "$(cat "$WORKDIR/$name.emit.err")")"; st=1
  elif ! "$CC" $GC_CFLAGS "$ll" "$RTOBJ" $GC_LIBS -o "$bin" 2>"$WORKDIR/$name.cc.err"; then
    msg="$(printf 'FAIL %s (clang)\n%s' "$name" "$(cat "$WORKDIR/$name.cc.err")")"; st=1
  else
    ref="$(cat "$golden")"; self="$("$bin" 2>/dev/null)"
    if [ "$ref" = "$self" ]; then msg="ok   $name ($ref)"
    else msg="$(printf 'FAIL %s\n  ref : %s\n  self: %s' "$name" "$ref" "$self")"; st=1; fi
  fi
  printf '%s\n' "$msg" > "$RESULTDIR/$name.out"
  echo "$st" > "$RESULTDIR/$name.status"
  printf '%s\n' "$msg"
  exit 0
fi

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
RESULTS="$(mktemp -d)"
trap 'rm -rf "$WORK" "$RESULTS"' EXIT

# Precompile the C runtime once (shared by all fixtures); fall back to source.
RTOBJ="$WORK/medaka_rt.o"
if ! "$CC" $GC_CFLAGS -c "$RT" -o "$RTOBJ" 2>/dev/null; then RTOBJ="$RT"; fi

JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"

ls "$FIXDIR"/*.mdk 2>/dev/null \
  | EMITBIN="$EMITBIN" RUNTIME="$RUNTIME" CC="$CC" GC_CFLAGS="$GC_CFLAGS" GC_LIBS="$GC_LIBS" \
    RTOBJ="$RTOBJ" WORKDIR="$WORK" RESULTDIR="$RESULTS" \
    xargs -P "$JOBS" -n 1 -I{} sh "$0" --one {}

pass=0; fail=0
for s in "$RESULTS"/*.status; do
  [ -f "$s" ] || continue
  if [ "$(cat "$s")" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
