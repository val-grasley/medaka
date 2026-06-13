#!/bin/sh
# SELF-COMPILE C3 for the BUILD DRIVER — verify the STRICT multi-module emit driver
# (selfhost/entries/llvm_emit_modules_main.mdk, the one `medaka build` actually shells out to)
# fixpoints, not just the gap-tolerant bootstrap driver.
#
# ── OCaml-FREE (REROOT-PLAN Phase 0, §2f) ──────────────────────────────────────
# Reference emission is bootstrapped from the COMMITTED gzipped seed
# (selfhost/seed/emitter.ll.gz), not from `main.exe run` (no OCaml, no `dune`).
# The seed IS minted from THIS build driver's graph, so the seed converges on it
# in a single re-emit (empirically SEED_IR == REF, and REF == the OCaml
# interpreter's emission, byte-for-byte — 2026-06-12).  The three-stage chain below
# is identical to test/selfcompile_fixpoint.sh; see that file's SEMANTIC NOTE for
# why the seed-bootstrapped reference is not a weakening at fixpoint.
#
# Chain (DRIVER = llvm_emit_modules_main.mdk = D):
#   seed_emitter (clang of gz seed) --emit D--> SEED_IR ; clang -> emitA
#   emitA --emit D--> REF   (converged reference; == old OCaml INTERP.ll)
#   clang(REF) -> emitB ; IR1 = emitB --emit D-->   C3a: IR1 == REF
#   clang(IR1) -> emitC ; IR2 = emitC --emit D-->   C3b: IR1 == IR2 (fixpoint)
#
# If C3a or C3b FAIL for this driver, the seed cannot be minted from it — STOP.
#
# Usage:  sh test/selfcompile_build_fixpoint.sh
# Exit:   0 iff C3a AND C3b hold; 2 if seed/clang/libgc missing (opt-in); 1 on divergence.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED_GZ="$ROOT/selfhost/seed/emitter.ll.gz"
DRIVER="$ROOT/selfhost/entries/llvm_emit_modules_main.mdk"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
SELFHOST="$ROOT/selfhost"
STDLIB="$ROOT/stdlib"
CC="${CC:-clang}"
STACK_SIZE="${STACK_SIZE:-0x20000000}"

[ -f "$SEED_GZ" ] || { echo "missing seed: $SEED_GZ (mint with test/refresh_seed.sh)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }
command -v gunzip >/dev/null 2>&1 || { echo "gunzip not found (needed to expand the seed)"; exit 2; }

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

trim_unit() {
  f="$1"
  if [ "$(tail -c 3 "$f" | od -An -tx1 | tr -d ' \n')" = "28290a" ]; then
    head -c $(( $(wc -c < "$f") - 3 )) "$f" > "$f.trim" && mv "$f.trim" "$f"
  fi
}

emit() { "$1" "$RUNTIME" "$CORE" "$DRIVER" "$SELFHOST" "$STDLIB"; }
clang_ir() { "$CC" -Wl,-stack_size,"$STACK_SIZE" $GC_CFLAGS "$1" "$RT" $GC_LIBS -o "$2" 2>"$WORK/$(basename "$2").cc.err"; }

# ── seed bootstrap (replaces the old `$MAIN run` interpreted emission) ──────────
SEED="$WORK/seed.ll"
echo "step 0: gunzip committed seed ..."
if ! gunzip -c "$SEED_GZ" > "$SEED" 2>"$WORK/gz.err"; then
  echo "FAIL (gunzip seed): $(cat "$WORK/gz.err")"; exit 1
fi
SEED_EMITTER="$WORK/seed_emitter"
echo "step 0: clang(seed) -> seed_emitter ..."
if ! clang_ir "$SEED" "$SEED_EMITTER"; then
  echo "FAIL (clang seed): $(cat "$WORK/seed_emitter.cc.err")"; exit 1
fi
SEED_IR="$WORK/SEED_IR.ll"; EMITA="$WORK/emitA"
echo "step 0: seed_emitter -> build driver IR ..."
if ! emit "$SEED_EMITTER" > "$SEED_IR" 2>"$WORK/seedir.err"; then
  echo "FAIL (seed_emitter emit):"; cat "$WORK/seedir.err"; exit 1
fi
trim_unit "$SEED_IR"
echo "step 0: clang(SEED_IR) -> emitA ..."
if ! clang_ir "$SEED_IR" "$EMITA"; then
  echo "FAIL (clang emitA): $(cat "$WORK/emitA.cc.err")"; exit 1
fi

# REF = the converged reference (replaces the old INTERP.ll C3a oracle).
REF="$WORK/REF.ll"
echo "step 1: emitA -> REF (converged seed-bootstrapped reference; replaces INTERP.ll) ..."
if ! emit "$EMITA" > "$REF" 2>"$WORK/ref.err"; then
  echo "FAIL (emitA emit):"; cat "$WORK/ref.err"; exit 1
fi
trim_unit "$REF"

EMITB="$WORK/emitB"; IR1="$WORK/IR1.ll"
echo "step 2: clang(REF) -> emitB ..."
if ! clang_ir "$REF" "$EMITB"; then
  echo "FAIL (clang emitB): $(cat "$WORK/emitB.cc.err")"; exit 1
fi
echo "step 2: IR1 — emitB re-emitting the build driver's graph ..."
if ! emit "$EMITB" > "$IR1" 2>"$WORK/ir1.err"; then
  echo "FAIL (native emitB crashed):"; cat "$WORK/ir1.err"; exit 1
fi
trim_unit "$IR1"

c3a=0
if cmp -s "$REF" "$IR1"; then c3a=1; echo "C3a PASS: IR1 == seed-bootstrapped reference, byte-for-byte"
else echo "C3a FAIL"; cmp "$REF" "$IR1" | head -3; diff "$REF" "$IR1" | head -20; fi

EMITC="$WORK/emitC"
echo "step 3: clang IR1 -> emitC ..."
if ! clang_ir "$IR1" "$EMITC"; then
  echo "FAIL (clang emitC): $(cat "$WORK/emitC.cc.err")"; exit 1
fi
IR2="$WORK/IR2.ll"
echo "step 3: IR2 — emitC re-emitting ..."
if ! emit "$EMITC" > "$IR2" 2>"$WORK/ir2.err"; then
  echo "FAIL (emitC crashed):"; cat "$WORK/ir2.err"; exit 1
fi
trim_unit "$IR2"

c3b=0
if cmp -s "$IR1" "$IR2"; then c3b=1; echo "C3b PASS: IR1 == IR2 — FIXPOINT"
else echo "C3b FAIL"; cmp "$IR1" "$IR2" | head -3; diff "$IR1" "$IR2" | head -20; fi

echo
printf 'BUILD-DRIVER C3a (IR1==seed-ref): %s   C3b (IR1==IR2): %s\n' \
  "$([ "$c3a" -eq 1 ] && echo YES || echo NO)" \
  "$([ "$c3b" -eq 1 ] && echo YES || echo NO)"
[ "$c3a" -eq 1 ] && [ "$c3b" -eq 1 ]
