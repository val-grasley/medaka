#!/usr/bin/env bash
# Build the browser WAT->wasm assembler and stage the shippable artifacts.
#
# Produces a self-contained `_bg.wasm` + hand-loadable JS glue (--target web)
# and copies them into playground/vendor/wat2wasm/ so the static playground has
# NO build dependency (the wasm is a few hundred KB; committing it is fine).
#
# Pinned `wat` crate = 1.252.0 (matches native wasm-tools 1.252.0).
#
# Idempotent: safe to re-run; prints artifact paths + sizes.
set -euo pipefail

# shellcheck disable=SC1090
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRATE_DIR="$SCRIPT_DIR/wat2wasm"
VENDOR_DIR="$SCRIPT_DIR/vendor/wat2wasm"

echo "==> Building wat2wasm (wasm-pack, --target web --release)"
wasm-pack build "$CRATE_DIR" --target web --release --out-dir "$CRATE_DIR/pkg"

echo "==> Staging artifacts into $VENDOR_DIR"
mkdir -p "$VENDOR_DIR"
cp "$CRATE_DIR/pkg/wat2wasm_bg.wasm" "$VENDOR_DIR/"
cp "$CRATE_DIR/pkg/wat2wasm.js"      "$VENDOR_DIR/"
# .d.ts is handy for editors; ship it too (tiny, text).
[ -f "$CRATE_DIR/pkg/wat2wasm.d.ts" ] && cp "$CRATE_DIR/pkg/wat2wasm.d.ts" "$VENDOR_DIR/"

echo "==> Artifacts:"
for f in "$VENDOR_DIR"/*; do
  size=$(wc -c < "$f" | tr -d ' ')
  printf '    %s  (%s bytes)\n' "$f" "$size"
done
echo "==> Done."
