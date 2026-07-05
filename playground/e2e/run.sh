#!/usr/bin/env bash
# playground/e2e/run.sh — run the Playwright e2e harness against the CM6
# playground, driving the SYSTEM Google Chrome (no Playwright browser
# download — TLS-blocked on this machine). See README.md for the full story.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYGROUND_ROOT="$(cd "$HERE/.." && pwd)"
PORT="${PORT:-8099}"
SCREENSHOT_DIR="$HERE/screenshots"

# ── node v24+ required (system default may be v20, which can't run the
#    finalized-WasmGC module the playground ships). ──────────────────────────
NODE24="$HOME/.nvm/versions/node/v24.17.0/bin"
if [ -d "$NODE24" ]; then
  export PATH="$NODE24:$PATH"
fi
NODE_MAJOR="$(node -e 'console.log(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
if [ "$NODE_MAJOR" -lt 24 ]; then
  echo "ERROR: node v24+ required (found $(node -v 2>/dev/null || echo none))." >&2
  echo "Install/enable node v24, e.g. via nvm, then re-run." >&2
  exit 1
fi

# ── dist/ must already be built — this harness does not build the 2.6MB wasm.
if [ ! -f "$PLAYGROUND_ROOT/dist/playground.wasm" ]; then
  echo "ERROR: $PLAYGROUND_ROOT/dist/playground.wasm is missing." >&2
  echo "Build it first: bash $PLAYGROUND_ROOT/build_playground_wasm.sh" >&2
  echo "(or copy an already-built playground/dist/ from another checkout)." >&2
  exit 1
fi

# ── npm deps (playwright) ────────────────────────────────────────────────────
if [ ! -d "$HERE/node_modules/playwright" ]; then
  echo "Installing e2e devDependencies (playwright) ..."
  (cd "$HERE" && npm install --no-audit --no-fund)
fi

mkdir -p "$SCREENSHOT_DIR"
rm -f "$SCREENSHOT_DIR"/*.png

# ── run ───────────────────────────────────────────────────────────────────────
STATUS=0
node "$HERE/lib/run-server-and-tests.mjs" "$PLAYGROUND_ROOT" "$PORT" "$SCREENSHOT_DIR" || STATUS=$?

echo
if [ "$STATUS" -eq 0 ]; then
  echo "e2e harness: PASS"
else
  echo "e2e harness: FAIL (exit $STATUS)"
fi
echo "Screenshots: $SCREENSHOT_DIR"
exit "$STATUS"
