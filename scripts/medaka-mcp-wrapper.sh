#!/usr/bin/env bash
set -euo pipefail
# Resolve the repo root: prefer Claude Code's CLAUDE_PROJECT_DIR (set in the
# server's env), else derive from this script's own location. Robust to cwd.
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export MEDAKA_ROOT="$ROOT"

# Fail LOUDLY on a missing binary. Without this, a checkout with no built
# `medaka` surfaces only as an opaque "Failed to connect" — the server dies on
# a nonexistent exec and Claude Code cannot say why. stdout is the JSON-RPC
# channel, so the actionable message goes to stderr (which the MCP client logs
# on connection failure). We deliberately do NOT build here: `make medaka` can
# take minutes and would time out the MCP handshake, and we do NOT fall back to
# another checkout's binary — the tools ARE the compiler's behavior, so a
# worktree must answer with its OWN binary or it silently reports the wrong
# compiler's results.
if [ ! -x "$ROOT/medaka" ]; then
  echo "medaka mcp: no built binary at $ROOT/medaka — run 'make medaka' in that checkout, then reconnect the MCP server (/mcp)." >&2
  exit 1
fi

exec "$ROOT/medaka" mcp "$@"
