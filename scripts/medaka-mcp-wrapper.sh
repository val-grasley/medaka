#!/usr/bin/env bash
set -euo pipefail
# Resolve the repo root: prefer Claude Code's CLAUDE_PROJECT_DIR (set in the
# server's env), else derive from this script's own location. Robust to cwd.
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export MEDAKA_ROOT="$ROOT"
exec "$ROOT/medaka" mcp "$@"
