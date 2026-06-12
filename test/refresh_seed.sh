#!/bin/sh
# RE-MINT the checked-in IR seed (selfhost/seed/emitter.ll.gz) — OCaml-FREE.
#
# The seed is the textual LLVM IR of the BUILD driver
# (selfhost/llvm_emit_modules_main.mdk) emitting its OWN module graph.  It is the
# COLD-START bootstrap entry point: test/bootstrap_from_seed.sh rebuilds a native
# emitter from it WITHOUT OCaml.  Because the native emitter reproduces this IR
# byte-for-byte (the C3b fixpoint property), the seed can be minted by the NATIVE
# emitter — no `medaka run` / OCaml interpreter needed.
#
# Flow:
#   1. Ensure ./medaka_emitter is CURRENT: warm-rebuild it from source via
#      build_native_medaka.sh (OCaml-free; cold-bootstraps from the existing seed if
#      there is no emitter yet).  This is what makes the mint reflect current source.
#   2. ./medaka_emitter <runtime> <core> <build-driver> <selfhost> <stdlib>  ->  IR
#      (the native emitter emitting the build driver's own graph; trim trailing ()).
#   3. gzip -> selfhost/seed/emitter.ll.gz   (committed; ~1.7 MB vs ~11.5 MB raw).
#
# Optional cross-check: if the OCaml oracle (_build/default/bin/main.exe) happens to
# be built, diff the native mint against an interpreted mint — informational only,
# never required (CHECK_OCAML=0 to skip).
#
# Run on-demand (per-release / deliberate refresh), NOT per-PR.
#
# Usage:  sh test/refresh_seed.sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMITTER="$ROOT/medaka_emitter"
DRIVER="$ROOT/selfhost/llvm_emit_modules_main.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
SELFHOST="$ROOT/selfhost"
STDLIB="$ROOT/stdlib"
SEED_GZ="$ROOT/selfhost/seed/emitter.ll.gz"
CHECK_OCAML="${CHECK_OCAML:-1}"

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

# Optional cross-check against an interpreted mint (informational; never required).
MAIN="$ROOT/_build/default/bin/main.exe"
if [ "$CHECK_OCAML" = "1" ] && [ -x "$MAIN" ]; then
  OC="$WORK/seed_ocaml.ll"
  if "$MAIN" run "$DRIVER" "$RUNTIME" "$CORE" "$DRIVER" "$SELFHOST" "$STDLIB" > "$OC" 2>/dev/null; then
    trim_unit "$OC"
    if cmp -s "$TMP" "$OC"; then
      echo "cross-check: native mint == OCaml mint, byte-for-byte (C3b holds)."
    else
      echo "cross-check WARN: native mint differs from OCaml mint (informational):"
      cmp "$TMP" "$OC" | head -3
    fi
  fi
fi

# 3. gzip the minted seed into the committed location.
mkdir -p "$(dirname "$SEED_GZ")"
gzip -9 -c "$TMP" > "$SEED_GZ"
echo "seed refreshed: $SEED_GZ ($(wc -c < "$SEED_GZ") bytes gz, $(wc -c < "$TMP") bytes raw)"
