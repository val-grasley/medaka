#!/bin/sh
# Equivalence gate for the Stage 2.4 LLVM de-risking spike (STAGE2-DESIGN.md §2.4).
#
# Proves the decided native toolchain end-to-end — EMIT textual LLVM IR + shell
# out to clang (no llc/opt, no C++ bindings) — against the committed value golden.
#
# For each prelude-free fixture in test/llvm_fixtures/:
#   1. ref  = test/llvm_fixtures/<name>.eval.golden   (the program VALUE — IR is
#             symbol-renaming-volatile, but the program's runtime stdout is stable,
#             see MEMORY "Diff gates compare OUTPUT not IR").
#             REGENERATE WITH: sh test/capture_goldens.sh --frozen llvm_eval
#             (these goldens were originally captured from the OCaml dev/eval_probe.exe,
#             which was REMOVED 2026-06-26; the regenerator replays steps 2–4 below.)
#   2. emit = test/bin/llvm_emit_main <fixture>       (Core IR -> textual LLVM IR)
#   3. clang <emit>.ll runtime/medaka_rt.c -o bin     (compile + link the stub)
#   4. self = ./bin                                   (run the native binary)
#   diff ref vs self byte-for-byte.
#
# Scope: slices 1–5b.  No arrays/dispatch/GC.
#
# OCaml-free (REROOT-PLAN.md Phase 2): the emitter runs as the pre-compiled native
# binary test/bin/llvm_emit_main (built by test/build_oracles.sh) instead of
# `main.exe run`; the reference is the committed .eval.golden.
#
# Usage:  sh test/diff_compiler_llvm.sh
# Exit:   0 if every fixture's native stdout matches the golden; 2 if the build is
#         missing or no C compiler is available (spike is opt-in).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMITBIN="$ROOT/test/bin/llvm_emit_main"
RT="$ROOT/runtime/medaka_rt.c"
FIXDIR="$ROOT/test/llvm_fixtures"
CC="${CC:-clang}"

# ── Per-fixture worker (parallel fan-out target) ───────────────────────────────
# Re-invoked as `sh "$0" --one <fixture>` under an xargs -P pool. All shared state
# (paths, GC flags, prebuilt runtime .o, result dir) arrives via env so the worker
# skips the one-time GC detection below. Writes ok/FAIL to $RESULTDIR/<name>.{status,out}.
if [ "${1:-}" = "--one" ]; then
  f="$2"
  name="$(basename "$f")"
  golden="${f%.mdk}.eval.golden"
  ll="$WORKDIR/$name.ll"; bin="$WORKDIR/$name.bin"
  st=0; out=""
  # Emit to a raw temp file and check $EMITBIN's OWN exit status directly
  # (dash has no `set -o pipefail`, so `cmd | perl` in an `if !` tests perl's
  # exit status, not the emitter's — see #632/#443). Only on a successful emit
  # do we run the `()`-strip post-process into $ll.
  raw="$WORKDIR/$name.raw.ll"
  if [ ! -f "$golden" ]; then
    out="no golden for $name (run sh test/capture_goldens.sh --frozen llvm_eval)"; st=1
  else
    "$EMITBIN" "$f" > "$raw" 2>"$WORKDIR/$name.emit.err"
    emit_rc=$?
    if [ "$emit_rc" -ne 0 ]; then
      out="$(printf 'FAIL %s (emit)\n%s' "$name" "$(cat "$WORKDIR/$name.emit.err")")"; st=1
    elif ! perl -0pe 's/\(\)\s*\z//' "$raw" > "$ll"; then
      out="FAIL $name (postprocess: perl failed on emitted IR)"; st=1
    elif ! "$CC" $GC_CFLAGS "$ll" "$RTOBJ" $GC_LIBS -lm -o "$bin" 2>"$WORKDIR/$name.cc.err"; then
      out="$(printf 'FAIL %s (clang)\n%s' "$name" "$(cat "$WORKDIR/$name.cc.err")")"; st=1
    else
      ref="$(cat "$golden")"; self="$("$bin" 2>/dev/null)"
      if [ "$ref" = "$self" ]; then out="ok   $name"
      else out="$(printf 'FAIL %s\n  ref : %s\n  self: %s' "$name" "$ref" "$self")"; st=1; fi
    fi
  fi
  printf '%s\n' "$out" > "$RESULTDIR/$name.out"
  echo "$st" > "$RESULTDIR/$name.status"
  printf '%s\n' "$out"
  exit 0
fi

[ -x "$EMITBIN" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$EMITBIN") (missing $EMITBIN)"; exit 2; }
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

# Precompile the C runtime ONCE (every fixture links the same medaka_rt.c — no
# point recompiling it 194 times). Fall back to the .c source if -c fails.
RTOBJ="$WORK/medaka_rt.o"
if ! "$CC" $GC_CFLAGS -c "$RT" -o "$RTOBJ" 2>/dev/null; then RTOBJ="$RT"; fi

JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"

# Fan the fixtures across an xargs -P pool of --one workers (see top of file).
fixtures="$(ls "$FIXDIR"/*.mdk 2>/dev/null)"
n_fixtures=0
if [ -n "$fixtures" ]; then
  n_fixtures="$(printf '%s\n' "$fixtures" | wc -l | tr -d ' ')"
  printf '%s\n' "$fixtures" \
    | EMITBIN="$EMITBIN" CC="$CC" GC_CFLAGS="$GC_CFLAGS" GC_LIBS="$GC_LIBS" \
      RTOBJ="$RTOBJ" WORKDIR="$WORK" RESULTDIR="$RESULTS" \
      xargs -P "$JOBS" -n 1 -I{} sh "$0" --one {}
fi

pass=0; fail=0; seen=0
for s in "$RESULTS"/*.status; do
  [ -f "$s" ] || continue
  seen=$((seen+1))
  if [ "$(cat "$s")" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done

# Completeness check (issue #637): a worker killed mid-run under xargs -P
# writes no .status file at all, so it would otherwise vanish from BOTH
# pass and fail — a silently-shrunk "green" run.
if [ "$seen" -ne "$n_fixtures" ]; then
  missing=$((n_fixtures - seen))
  echo "FAIL: $missing of $n_fixtures workers produced no result — a worker died/was killed; this run is INCOMPLETE, not green."
  exit 1
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
