#!/bin/sh
# test/lsp_harness.sh — native LSP test harness gate.
#
# Compiles compiler/entries/lsp_harness_main.mdk and runs it: it drives the
# native `medaka lsp` binary over real JSON-RPC (batch — `medaka lsp < requests`)
# and asserts on the framed responses.  v1 fixtures (test/lsp_fixtures/):
#   1. frame-integrity  — every response frame's Content-Length matches the actual
#      UTF-8 byte length (guards the codepoint-vs-byte framing crash).
#   2. multi-module clean — a sibling module's exhaustive Option match reports 0
#      diagnostics via the project path (guards the exhaustiveness-oracle bug).
#   3. type-error surfaces — a genuine error yields >=1 diagnostic.
#   4. unparseable no-crash — documentSymbol on an unparseable file still responds.
#   5. semantic tokens — semanticTokens/full over `List (Expr, Expr) -> Expr`; the
#      three length-4 `Expr` type names all decode to the SAME tokenType (the
#      `type` legend index), the fix for the regex-grammar mis-scope.
#
# Requires ./medaka + ./medaka_emitter pre-built (run `make medaka`).  Exits 0 iff
# every fixture passes.

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MEDAKA="$ROOT/medaka"
EMITTER="$ROOT/medaka_emitter"
if [ ! -x "$MEDAKA" ] || [ ! -x "$EMITTER" ]; then
  echo "FAIL: $MEDAKA / $EMITTER not built — run 'make medaka' first." >&2
  exit 1
fi

BIN="$(mktemp -t lsp_harness.XXXXXX)"
trap 'rm -f "$BIN"' EXIT

# Build the harness from current source (picks up fixture/library edits).
if ! MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" "$MEDAKA" \
       build --allow-internal compiler/entries/lsp_harness_main.mdk -o "$BIN" >/dev/null 2>&1; then
  echo "FAIL: could not build the LSP harness." >&2
  exit 1
fi

# Run it; the harness drives $MEDAKA (the server under test).
OUT="$(MEDAKA="$MEDAKA" MEDAKA_ROOT="$ROOT" "$BIN" 2>&1)"
echo "$OUT"

# Fail on any FAIL line, or if the summary doesn't report 0 failures.
if echo "$OUT" | grep -q '^FAIL '; then exit 1; fi
if ! echo "$OUT" | grep -q '^HARNESS: .* 0 failed$'; then exit 1; fi
exit 0
