#!/bin/sh
# OCAML-FREE BOOTSTRAP / SEED-CURRENCY GATE — rebuild the native Medaka emitter from
# the checked-in gzipped IR seed (compiler/seed/emitter.ll.gz), NO `medaka run`/OCaml.
#
# Two roles:
#   • `make bootstrap` (strict, default): release/CI gate that the committed seed is
#     CURRENT — gunzip(seed) builds seed_emitter, which re-emits the build-driver graph
#     to emitter2.ll; C3a asserts seed == emitter2 byte-for-byte (hard fail on drift).
#   • COLD-START build leg (SEED_TOLERANT=1, set by build_native_medaka.sh): a C3a
#     mismatch is only a WARNING — a lagging seed still builds a working emitter_v0
#     (clang'd from emitter2.ll = the CURRENT-source re-emission), which then compiles
#     current source.  The build never aborts on a slightly-old seed.
#
# Flow (mirrors test/selfcompile_fixpoint.sh MINUS the interpreted `$MAIN run` emit
# step — the seed REPLACES it):
#   1. gunzip(seed.gz) -> seed.ll ; clang(seed.ll)+runtime+libgc -> seed_emitter
#   2. seed_emitter <runtime> <core> <build-driver> <compiler> <stdlib> -> emitter2.ll
#      (the seed emitter re-emitting the build driver's own graph; trim trailing ()).
#   3. C3a check:  cmp -s seed.ll  emitter2.ll  (strict: fail; tolerant: warn).
#   4. clang(emitter2.ll) -> medaka_emitter   (the bootstrapped native emitter binary,
#      usable as MEDAKA_EMITTER for `medaka build`).
#
# OPT-IN like the other LLVM gates: skips cleanly (exit 2) when clang or libgc is
# absent.  Run on-demand / per-release, NOT per-PR.
#
# Usage:  sh test/bootstrap_from_seed.sh [out-path] [tolerant]
#         SEED_TOLERANT=1 sh test/bootstrap_from_seed.sh   (cold-start build leg)
# Exit:   0 iff seed_emitter builds, (strict) emitter2 == seed, and medaka_emitter builds;
#         2 if clang/libgc absent (opt-in skip); 1 on any divergence or build failure.
#
# Artifacts (in repo root, for the MEDAKA_EMITTER build check):  ./medaka_emitter
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED_GZ="$ROOT/compiler/seed/emitter.ll.gz"
DRIVER="$ROOT/compiler/entries/llvm_emit_modules_main.mdk"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
SELFHOST="$ROOT/compiler"
STDLIB="$ROOT/stdlib"
CC="${CC:-clang}"
STACK_SIZE="${STACK_SIZE:-0x20000000}"
OUT="${1:-$ROOT/medaka_emitter}"

# ── SEED POLICY (changed 2026-07-13): re-mint only when NECESSARY ─────────────
#
# There are TWO different properties here, and conflating them is what drove 41
# re-mints (86 MB — 40% of the whole repo's git history is dead seed blobs):
#
#   (a) the seed WORKS   — gunzip(seed) builds an emitter that can compile the
#                          CURRENT compiler source. This is genuinely REQUIRED.
#   (b) the seed IS CURRENT — its IR is byte-identical to what current source
#                          emits today (C3a). This is a DRIFT DETECTOR, not a
#                          requirement.
#
# You only ever NEED (a). Demanding (b) forces a re-mint on ANY emitter-graph
# change, which is why the seed was re-minted four times in two days.
#
# And (a) survives FAR longer than (b) — demonstrated on 2026-07-13: the seed was
# stale (C3a FAILING) and CI's cold bootstrap from it passed anyway, seven times
# over. A lagging seed still builds a working emitter_v0.
#
# So the DEFAULT is now TOLERANT: C3a drift is a WARNING; the hard failure is
# reserved for a seed that can no longer do its job. Byte-currency is checked
# EXPLICITLY at checkpoints (`make bootstrap`, or SEED_STRICT=1) and re-minted
# then — not reflexively on every emitter touch.
#
#   default / CI      -> tolerant: seed must WORK. Drift warns.
#   make bootstrap    -> strict:   seed must be byte-CURRENT. Use at checkpoints,
#   SEED_STRICT=1        release, or before cutting a seed re-mint.
#
# ⚠️ Do NOT "simplify" this back into one strict gate. The point is that a drift
# warning is INFORMATIVE and a build failure is ACTIONABLE, and they are not the
# same event.
SEED_TOLERANT="${SEED_TOLERANT:-1}"
[ "${SEED_STRICT:-0}" = "1" ] && SEED_TOLERANT=0
[ "${2:-}" = "tolerant" ] && SEED_TOLERANT=1
[ "${2:-}" = "strict" ] && SEED_TOLERANT=0

[ -f "$SEED_GZ" ] || { echo "missing seed: $SEED_GZ (mint with test/refresh_seed.sh)"; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping (opt-in)"; exit 2; }
command -v gunzip >/dev/null 2>&1 || { echo "gunzip not found (needed to expand the seed)"; exit 1; }

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then
  GC_CFLAGS="$(pkg-config --cflags bdw-gc)"; GC_LIBS="$(pkg-config --libs bdw-gc)"
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then
  GC_CFLAGS="-I$GC_PREFIX/include"; GC_LIBS="-L$GC_PREFIX/lib -lgc"
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then
  GC_CFLAGS=""; GC_LIBS="-lgc"
else
  echo "libgc (bdw-gc) not found — skipping (opt-in; install bdw-gc or set GC_PREFIX)"; exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Expand the gzipped committed seed to plain LLVM IR for clang.
SEED="$WORK/seed.ll"
if ! gunzip -c "$SEED_GZ" > "$SEED" 2>"$WORK/gz.err"; then
  echo "FAIL (gunzip seed): $(cat "$WORK/gz.err")"; exit 1
fi

trim_unit() {
  f="$1"
  if [ "$(tail -c 3 "$f" | od -An -tx1 | tr -d ' \n')" = "28290a" ]; then
    head -c $(( $(wc -c < "$f") - 3 )) "$f" > "$f.trim" && mv "$f.trim" "$f"
  fi
}

# ---- STEP 1: clang the SEED into a native emitter (NO OCaml) ----------------
SEED_EMITTER="$WORK/seed_emitter"
echo "step 1: clang(seed) -> seed_emitter (stack $STACK_SIZE) ..."
if ! "$CC" -pthread $GC_CFLAGS "$SEED" "$RT" $GC_LIBS -lm -o "$SEED_EMITTER" 2>"$WORK/cc1.err"; then
  echo "FAIL (clang seed): $(cat "$WORK/cc1.err")"; exit 1
fi

# ---- STEP 2: seed_emitter re-emits the build driver's graph from CURRENT srcs --
EMITTER2="$WORK/emitter2.ll"
echo "step 2: seed_emitter re-emitting the build driver's graph ..."
if ! "$SEED_EMITTER" "$RUNTIME" "$CORE" "$DRIVER" "$SELFHOST" "$STDLIB" > "$EMITTER2" 2>"$WORK/e2.err"; then
  echo "FAIL (seed_emitter crashed):"; cat "$WORK/e2.err"; exit 1
fi
trim_unit "$EMITTER2"

# ---- STEP 3: C3a — seed reproduces from current sources --------------------
if cmp -s "$SEED" "$EMITTER2"; then
  echo "C3a PASS: seed == native re-emission from current sources, byte-for-byte"
else
  if [ "$SEED_TOLERANT" = "1" ]; then
    echo "C3a WARN: committed seed differs from native re-emission (lagging seed)."
    echo "  -> building from emitter2 anyway (tolerant cold-start); re-mint with: sh test/refresh_seed.sh"
  else
    echo "C3a FAIL: seed differs from native re-emission (stale seed or emitter changed)"
    echo "  -> refresh with: sh test/refresh_seed.sh"
    cmp "$SEED" "$EMITTER2" | head -3; diff "$SEED" "$EMITTER2" | head -20
    exit 1
  fi
fi

# ---- STEP 4: clang emitter2 -> the bootstrapped native emitter binary -------
# Build at -O2 (like the warm path in build_native_medaka.sh): this IS the reused
# workhorse emitter, kept as medaka_emitter until the next source change, so a
# cold-cloned repo gets the ~30%-faster emitter immediately. EMITTER_OPT overrides.
echo "step 4: clang(emitter2) -> $OUT ..."
if ! "$CC" -pthread "${EMITTER_OPT:--O2}" $GC_CFLAGS "$EMITTER2" "$RT" $GC_LIBS -lm -o "$OUT" 2>"$WORK/cc2.err"; then
  echo "FAIL (clang medaka_emitter): $(cat "$WORK/cc2.err")"; exit 1
fi

echo
echo "BOOTSTRAP-FROM-SEED PASS: built $OUT OCaml-free from the gzipped seed."
