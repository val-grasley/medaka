#!/usr/bin/env bash
# build_site.sh — assemble a deployable static site folder for the Medaka playground.
#
# Produces playground/site/ containing exactly what a static CDN needs:
#   index.html
#   main.js
#   editor.js  medaka_lang.js  medaka_tokenizer.js  diagnostics_map.js
#   language-worker.js
#   compile.mjs
#   compiler-worker.js
#   worker.js
#   vendor/wat2wasm/wat2wasm.js
#   vendor/wat2wasm/wat2wasm_bg.wasm
#   vendor/wat2wasm/wat2wasm.d.ts   (if present)
#   vendor/codemirror/codemirror.js
#   dist/playground.wasm
#   dist/runtime.mdk
#   dist/core.mdk
#
# Runs build_playground_wasm.sh first if dist/playground.wasm is missing.
# playground/site/ is gitignored — do NOT commit it.
#
# Deploy: upload playground/site/ to any static host (GitHub Pages, Cloudflare
# Pages, Netlify, etc.) with no server-side logic needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SITE="$SCRIPT_DIR/site"
DIST="$SCRIPT_DIR/dist"

# ── Build dist artifacts if missing ─────────────────────────────────────────
if [ ! -f "$DIST/playground.wasm" ]; then
  echo "[build_site] dist/playground.wasm not found — running build_playground_wasm.sh ..."
  bash "$SCRIPT_DIR/build_playground_wasm.sh"
fi

[ -f "$DIST/playground.wasm" ] || { echo "FAIL: dist/playground.wasm still missing after build"; exit 1; }
[ -f "$DIST/runtime.mdk" ]     || { echo "FAIL: dist/runtime.mdk missing"; exit 1; }
[ -f "$DIST/core.mdk" ]        || { echo "FAIL: dist/core.mdk missing"; exit 1; }

# ── Assemble site/ ───────────────────────────────────────────────────────────
echo "[build_site] assembling $SITE ..."
rm -rf "$SITE"
mkdir -p "$SITE/vendor/wat2wasm" "$SITE/vendor/codemirror" "$SITE/dist"

# Static page + JS glue (editor modules included)
cp "$SCRIPT_DIR/index.html"          "$SITE/"
cp "$SCRIPT_DIR/main.js"             "$SITE/"
cp "$SCRIPT_DIR/editor.js"           "$SITE/"
cp "$SCRIPT_DIR/medaka_lang.js"      "$SITE/"
cp "$SCRIPT_DIR/medaka_tokenizer.js" "$SITE/"
cp "$SCRIPT_DIR/diagnostics_map.js"  "$SITE/"
cp "$SCRIPT_DIR/language-worker.js"  "$SITE/"
cp "$SCRIPT_DIR/compile.mjs"         "$SITE/"
cp "$SCRIPT_DIR/compiler-worker.js"  "$SITE/"
cp "$SCRIPT_DIR/worker.js"           "$SITE/"

# Committed wat2wasm assembler blob
cp "$SCRIPT_DIR/vendor/wat2wasm/wat2wasm.js"      "$SITE/vendor/wat2wasm/"
cp "$SCRIPT_DIR/vendor/wat2wasm/wat2wasm_bg.wasm" "$SITE/vendor/wat2wasm/"
[ -f "$SCRIPT_DIR/vendor/wat2wasm/wat2wasm.d.ts" ] && \
  cp "$SCRIPT_DIR/vendor/wat2wasm/wat2wasm.d.ts" "$SITE/vendor/wat2wasm/"

# Committed CodeMirror 6 single-ESM bundle (see build_editor.sh)
cp "$SCRIPT_DIR/vendor/codemirror/codemirror.js" "$SITE/vendor/codemirror/"

# Compiler wasm + stdlib sources
cp "$DIST/playground.wasm" "$SITE/dist/"
cp "$DIST/runtime.mdk"     "$SITE/dist/"
cp "$DIST/core.mdk"        "$SITE/dist/"

# ── Report ───────────────────────────────────────────────────────────────────
echo
echo "site contents:"
find "$SITE" -type f | sort | while read -r f; do
  size=$(wc -c < "$f" | tr -d ' ')
  printf '  %-55s %10d bytes\n' "${f#$SITE/}" "$size"
done
echo
TOTAL=$(find "$SITE" -type f -exec wc -c {} + 2>/dev/null | tail -1 | awk '{print $1}')
echo "total: $TOTAL bytes ($(( TOTAL / 1024 )) KB)"
echo
echo "deploy: upload playground/site/ to any static host (GitHub Pages, Cloudflare Pages, Netlify, etc.)"
