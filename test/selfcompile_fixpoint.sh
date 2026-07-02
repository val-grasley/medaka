#!/bin/sh
# SELF-COMPILE C3 — TRUE SELF-HOSTING FIXPOINT.  The native emitter compiles the
# EMITTER ITSELF and reproduces its own output byte-for-byte.
#
# C1 (test/selfcompile_emit.sh) proved a NATIVE-compiled emitter reproduces the
# INTERPRETED emitter's IR on small fixtures.  C2 (test/selfcompile_lex.sh) had the
# native emitter compile the REAL self-hosted lexer driver, native-emitted IR
# byte-identical to the interpreter's.  C3 closes the loop: use the gap-tolerant
# emitter driver (compiler/entries/llvm_bootstrap_lex_main.mdk) — whose module graph IS the
# whole emitter + front-end + prelude, the LARGEST program in the tree — as BOTH the
# compiler AND the program being compiled.  "The compiler compiles itself and
# reproduces itself."
#
# ── OCaml-FREE (REROOT-PLAN Phase 0, §2f) ──────────────────────────────────────
# This gate NO LONGER invokes the OCaml host (`main.exe run`) or `dune`.  The
# reference emission is bootstrapped from the COMMITTED gzipped seed
# (compiler/seed/emitter.ll.gz) — exactly the cold path of build_native_medaka.sh /
# bootstrap_from_seed.sh — instead of from the interpreter.
#
# SEMANTIC NOTE (what the gate now proves vs. before):
#   BEFORE:  C3a = "native emitA == FRESH OCaml-interpreted emission of the driver".
#            That was a cross-implementation check (native == OCaml interpreter).
#   NOW:     C3a = "native emitter reproduces the CONVERGED seed-bootstrapped
#            reference".  The reference is derived purely from the committed seed,
#            so this is native self-consistency, not a cross-impl check.
#   Why this is NOT a weakening at fixpoint:  the seed lags the gap-tolerant driver
#   by exactly ONE generation (the seed was minted from the llvm_emit_modules_main
#   graph; the gap-tolerant driver's emission needs one extra turn of the crank to
#   converge).  Empirically (2026-06-12) the converged reference REF — produced by
#   the seed-built emitter re-emitting the driver ONCE — is BYTE-IDENTICAL to the
#   OCaml interpreter's emission of the same driver.  So at fixpoint the seed path
#   reproduces precisely what the retired OCaml oracle produced.  The lost
#   cross-impl check is compensated per REROOT-PLAN §5 blocker #3 by running the
#   OCaml-oracle'd fixpoint ONCE per soak checkpoint (manual; see git history of
#   this file for the pre-Phase-0 OCaml version).
#
# THE BOOTSTRAP CHAIN (gap-tolerant driver = D):
#   seed_emitter (clang of the gz seed)
#       --emit D-->  SEED_IR   (gen N-1 emission style)
#   clang(SEED_IR) = emitA
#       --emit D-->  REF       (CONVERGED reference; == old OCaml INTERP.ll)
#   clang(REF)     = emitB
#       --emit D-->  IR1
#   C3a (reproduction):  IR1 == REF byte-for-byte.
#   clang(IR1)     = emitC
#       --emit D-->  IR2
#   C3b (fixpoint):      IR1 == IR2 byte-for-byte — the compiled compiler
#                        reproduces its own output.  FIXPOINT.
#
# STACK.  arm64 macOS HARD-CAPS -Wl,-stack_size at 0x20000000 (512 MiB — the linker
# rejects anything larger).  The whole-emitter emit still FITS within 512 MiB, so the
# max-allowed stack flag suffices and NO big-stack worker thread is needed.
#
# UNIT AUTO-PRINT.  The driver's `main : <IO, Mut> Unit` writes the IR via putStr,
# then the native runtime auto-prints main's Unit as a trailing "()\n".  emitProgram's
# IR ends in "}\n"; we strip the trailing "()\n" (3 bytes) from every native emit so
# the .ll is pure IR usable both for clang and the byte-diff.  (All emissions here are
# native, so every one is trimmed — there is no longer an un-trimmed interp oracle.)
#
# Usage:  sh test/selfcompile_fixpoint.sh
# Exit:   0 iff C3a (IR1==REF) AND C3b (IR1==IR2) both hold;
#         2 if the seed is missing, no C compiler, or libgc is absent (opt-in);
#         1 on any divergence or build/emit failure.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED_GZ="$ROOT/compiler/seed/emitter.ll.gz"
DRIVER="$ROOT/compiler/entries/llvm_bootstrap_lex_main.mdk"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
SELFHOST="$ROOT/compiler"
STDLIB="$ROOT/stdlib"
CC="${CC:-clang}"

STACK_SIZE="${STACK_SIZE:-0x20000000}"

# The fixpoint does three big SELF-COMPILE emits (REF, IR1, IR2) one after another
# — the emitter churns ~15 GB transient garbage over a ~100 MB live set, so a large
# GC heap defers collections (~110→9) and cuts each emit ~30%. These runs are
# serial (no concurrency), so the extra RSS doesn't contend. Measured 27s→22s.
# User env value wins.
export GC_INITIAL_HEAP_SIZE="${GC_INITIAL_HEAP_SIZE:-1073741824}"

[ -f "$SEED_GZ" ] || { echo "missing seed: $SEED_GZ (mint with test/refresh_seed.sh)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping spike"; exit 2; }
command -v gunzip >/dev/null 2>&1 || { echo "gunzip not found (needed to expand the seed)"; exit 2; }

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

trim_unit() {
  f="$1"
  if [ "$(tail -c 3 "$f" | od -An -tx1 | tr -d ' \n')" = "28290a" ]; then
    head -c $(( $(wc -c < "$f") - 3 )) "$f" > "$f.trim" && mv "$f.trim" "$f"
  fi
}

# emit <binary> -> stdout : run a native emitter over the gap-tolerant driver graph.
emit() { "$1" "$RUNTIME" "$CORE" "$DRIVER" "$SELFHOST" "$STDLIB"; }
clang_ir() { # clang_ir <in.ll> <out-bin>  (errfile $WORK/$(basename out).cc.err)
  "$CC" -Wl,-stack_size,"$STACK_SIZE" $GC_CFLAGS "$1" "$RT" $GC_LIBS -o "$2" 2>"$WORK/$(basename "$2").cc.err"
}

# ── seed bootstrap (replaces the old `$MAIN run` interpreted emission) ──────────
SEED="$WORK/seed.ll"
echo "step 0: gunzip committed seed ..."
if ! gunzip -c "$SEED_GZ" > "$SEED" 2>"$WORK/gz.err"; then
  echo "FAIL (gunzip seed): $(cat "$WORK/gz.err")"; exit 1
fi
SEED_EMITTER="$WORK/seed_emitter"
echo "step 0: clang(seed) -> seed_emitter (stack $STACK_SIZE) ..."
if ! clang_ir "$SEED" "$SEED_EMITTER"; then
  echo "FAIL (clang seed): $(cat "$WORK/seed_emitter.cc.err")"; exit 1
fi

SEED_IR="$WORK/SEED_IR.ll"
EMITA="$WORK/emitA"
echo "step 0: seed_emitter -> gap-tolerant driver IR (gen N-1) ..."
if ! emit "$SEED_EMITTER" > "$SEED_IR" 2>"$WORK/seedir.err"; then
  echo "FAIL (seed_emitter emit):"; cat "$WORK/seedir.err"; exit 1
fi
trim_unit "$SEED_IR"
echo "step 0: clang(SEED_IR) -> emitA (stack $STACK_SIZE) ..."
if ! clang_ir "$SEED_IR" "$EMITA"; then
  echo "FAIL (clang emitA): $(cat "$WORK/emitA.cc.err")"; exit 1
fi

# REF = the CONVERGED reference (emitA re-emitting the driver once).  This is the
# OCaml-free replacement for the old INTERP.ll C3a oracle; it is byte-identical to
# the interpreter's emission at fixpoint (see SEMANTIC NOTE above).
REF="$WORK/REF.ll"
echo "step 1: emitA -> REF (converged seed-bootstrapped reference; replaces INTERP.ll) ..."
if ! emit "$EMITA" > "$REF" 2>"$WORK/ref.err"; then
  echo "FAIL (emitA emit — likely stack overflow):"; cat "$WORK/ref.err"; exit 1
fi
trim_unit "$REF"

# emitB = clang(REF); IR1 = emitB emitting the driver.
EMITB="$WORK/emitB"
IR1="$WORK/IR1.ll"
echo "step 2: clang(REF) -> emitB ..."
if ! clang_ir "$REF" "$EMITB"; then
  echo "FAIL (clang emitB): $(cat "$WORK/emitB.cc.err")"; exit 1
fi
echo "step 2: IR1 — emitB emitting the emitter graph (the biggest emit; slow) ..."
if ! emit "$EMITB" > "$IR1" 2>"$WORK/IR1.err"; then
  echo "FAIL (native-emit emitter crashed — likely stack overflow):"; cat "$WORK/IR1.err"; exit 1
fi
trim_unit "$IR1"

c3a=0
if cmp -s "$REF" "$IR1"; then
  c3a=1
  echo "C3a PASS: IR1 (native) == seed-bootstrapped converged reference, byte-for-byte"
else
  echo "C3a FAIL: native IR1 differs from the converged seed-bootstrapped reference"
  cmp "$REF" "$IR1" | head -5
  diff "$REF" "$IR1" | head -30
fi

# emitC = clang(IR1); IR2 = emitC emitting the driver — the fixpoint check.
EMITC="$WORK/emitC"
echo "step 3: clang IR1 -> emitC (stack $STACK_SIZE) ..."
if ! clang_ir "$IR1" "$EMITC"; then
  echo "FAIL (clang emitC): $(cat "$WORK/emitC.cc.err")"; exit 1
fi
IR2="$WORK/IR2.ll"
echo "step 3: IR2 — emitC emitting the emitter graph ..."
if ! emit "$EMITC" > "$IR2" 2>"$WORK/IR2.err"; then
  echo "FAIL (emitC native-emit crashed):"; cat "$WORK/IR2.err"; exit 1
fi
trim_unit "$IR2"

c3b=0
if cmp -s "$IR1" "$IR2"; then
  c3b=1
  echo "C3b PASS: IR1 == IR2 byte-for-byte — FIXPOINT (the compiled compiler reproduces its own output)"
else
  echo "C3b FAIL: IR1 differs from IR2 (no fixpoint)"
  cmp "$IR1" "$IR2" | head -5
  diff "$IR1" "$IR2" | head -30
fi

echo
printf 'C3a (IR1==seed-ref): %s   C3b (IR1==IR2 fixpoint): %s\n' \
  "$([ "$c3a" -eq 1 ] && echo YES || echo NO)" \
  "$([ "$c3b" -eq 1 ] && echo YES || echo NO)"
[ "$c3a" -eq 1 ] && [ "$c3b" -eq 1 ]
