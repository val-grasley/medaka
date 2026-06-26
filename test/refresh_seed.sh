# RE-MINT the checked-in IR seed (compiler/seed/emitter.ll.gz) — OCaml-FREE.
#
# The seed is the textual LLVM IR of the BUILD driver
# (compiler/entries/llvm_emit_modules_main.mdk) emitting its OWN module graph.  It is the
# COLD-START bootstrap entry point: test/bootstrap_from_seed.sh rebuilds a native
# emitter from it WITHOUT OCaml.  Because the native emitter reproduces this IR
# byte-for-byte (the C3b fixpoint property), the seed can be minted by the NATIVE
# emitter — no `medaka run` / OCaml interpreter needed.
#
# Flow:
#   1. Ensure ./medaka_emitter is CURRENT: warm-rebuild it from source via
#      build_native_medaka.sh (OCaml-free; cold-bootstraps from the existing seed if
#      there is no emitter yet).  This is what makes the mint reflect current source.
#   2. ./medaka_emitter <runtime> <core> <build-driver> <compiler> <stdlib>  ->  IR
#      (the native emitter emitting the build driver's own graph; trim trailing ()).
#   3. gzip -> compiler/seed/emitter.ll.gz   (committed; ~1.7 MB vs ~11.5 MB raw).
#
# Run on-demand (per-release / deliberate refresh), NOT per-PR.
#
# Usage:  sh test/refresh_seed.sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMITTER="$ROOT/medaka_emitter"
DRIVER="$ROOT/compiler/entries/llvm_emit_modules_main.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
SELFHOST="$ROOT/compiler"
STDLIB="$ROOT/stdlib"
SEED_GZ="$ROOT/compiler/seed/emitter.ll.gz"

# 1. Make the native emitter current from CURRENT source (OCaml-free; cold-bootstraps
#    from the existing seed if no emitter binary exists yet).  Build to a scratch
#    `medaka` we discard — we only need the up-to-date $EMITTER side effect.
echo "ensuring native emitter is current from source (OCaml-free) ..."
FORCE_EMITTER_REBUILD=1 sh "$ROOT/test/build_native_medaka.sh" "$(mktemp)" >/dev/null
[ -x "$EMITTER" ] || { echo "FAIL: no $EMITTER after warm rebuild"; exit 1; }

trim_unit() {
  f="$1"
  if [ "$(tail -c 3 "$f" | od -An -tx1 | tr -d ' \n')" = "28290a" ]; then
    head -c $(( $(wc -c < "$f") - 3 )) "$f" > "$f.trim" && mv "$f.trim" "$f"
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 2. Native emitter emits the build driver's own graph -> the seed IR.
TMP="$WORK/seed.ll"
echo "minting seed: NATIVE emission of the build driver's own graph ..."
"$EMITTER" "$RUNTIME" "$CORE" "$DRIVER" "$SELFHOST" "$STDLIB" > "$TMP"
trim_unit "$TMP"
[ -s "$TMP" ] || { echo "FAIL: empty seed IR"; exit 1; }

# 3. gzip the minted seed into the committed location.
mkdir -p "$(dirname "$SEED_GZ")"
gzip -9 -c "$TMP" > "$SEED_GZ"
echo "seed refreshed: $SEED_GZ ($(wc -c < "$SEED_GZ") bytes gz, $(wc -c < "$TMP") bytes raw)"
