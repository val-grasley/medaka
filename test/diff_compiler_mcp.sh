#!/bin/sh
# test/diff_compiler_mcp.sh — golden JSON-RPC transcript gate for `medaka mcp`
# (#253, part of #246; depends on #247's transport).
#
# Feeds a canned newline-delimited JSON-RPC request stream to `./medaka mcp`
# on stdin, captures stdout, and diffs it against a committed golden — same
# shape as test/diff_compiler_check_json.sh, but for the MCP stdio transport
# instead of `check --json`.
#
# EXTENSIBILITY (the whole point of this gate, per #253): it is a FIXTURE-DIR
# LOOP, not a single hardcoded transcript. Each fixture is a pair:
#   test/mcp_fixtures/<name>.jsonl   — the request stream (one JSON-RPC
#                                      message per line, notifications have
#                                      no "id" and get no response line)
#   test/mcp_fixtures/<name>.golden  — the exact expected stdout (one
#                                      response line per request; notification
#                                      lines produce ZERO golden lines)
# To add a fixture for a new tool (#248/#249/#250/#251/#252/#255): drop a new
# <name>.jsonl + capture its <name>.golden (CAPTURE=1, below) — no edits to
# this script.
#
# PATH-STABILITY (non-negotiable — see golden-path-stability rule): the T1
# handshake fixture below is naturally path-free (no file arguments are
# involved), so its golden is asserted byte-for-byte with no normalization.
# ⚠️ A LATER fixture whose tool result embeds a file path (e.g. a `check`/
# `lint`/`type_at` tool operating on a fixture file) MUST either (a) use a
# path RELATIVE to a fixed cwd this script controls, or (b) have its runner
# sed the absolute path to a stable placeholder before diffing/capturing —
# same idiom as diff_compiler_check_json.sh's `sed "s|$mdk|<fixture>|g"`.
# Do not bake an absolute worktree path into a committed golden.
#
# To regenerate all goldens: CAPTURE=1 sh test/diff_compiler_mcp.sh
#
# Usage: sh test/diff_compiler_mcp.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/mcp_fixtures"

[ -x "$MEDAKA" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }
[ -d "$FIXDIR" ] || { echo "FAIL: missing $FIXDIR"; exit 1; }

export MEDAKA_ROOT="$ROOT"

# Run the server with a FIXED cwd = repo root so a fixture request carrying a
# repo-relative `file` path (e.g. medaka_type_at's test/mcp_fixtures/...) resolves
# deterministically no matter where this gate was invoked from (run_gates.sh's
# worker inherits the caller's cwd and never cd's).  The tool responses stay
# path-free, so this only affects request-path resolution, not golden stability.
cd "$ROOT" || { echo "FAIL: cannot cd to $ROOT"; exit 1; }

pass=0; fail=0

for req in "$FIXDIR"/*.jsonl; do
  [ -f "$req" ] || continue
  name="$(basename "$req" .jsonl)"
  golden="$FIXDIR/$name.golden"

  tmpout="$(mktemp)"
  perl -e 'alarm 30; exec @ARGV' "$MEDAKA" mcp < "$req" > "$tmpout" 2>/dev/null
  rc=$?
  self_out="$(cat "$tmpout")"
  rm -f "$tmpout"

  if [ "${CAPTURE:-0}" = "1" ]; then
    printf '%s\n' "$self_out" > "$golden"
    printf 'CAPTURE %s\n' "$golden"
    continue
  fi

  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (missing golden %s)\n' "$name" "$golden"; continue
  fi
  want_out="$(cat "$golden")"

  # A fixture passes ONLY when the server exits 0 AND its stdout matches the
  # golden.  Checking the exit code is not inert once #248 puts real
  # compiler-pipeline code behind tools/call: a tool that emits its correct
  # response lines and THEN segfaults/panics before the loop's clean EOF exit
  # would still match the golden — the "gate passes over a crashed process"
  # failure mode.  A nonzero rc also catches the SIGALRM timeout kill (hung
  # server → rc ~142), which truncated-output-≠-golden would not reliably.
  # A crash is reported DISTINCTLY from a diff mismatch so a later #248
  # debugger can tell "crashed" from "wrong output" at a glance.
  if [ "$rc" -ne 0 ]; then
    fail=$((fail+1)); printf 'FAIL %s: medaka mcp exited %d\n' "$name" "$rc"
    printf '  self:   %s\n' "$self_out"
  elif [ "$self_out" = "$want_out" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '  self:   %s\n' "$self_out"
    printf '  golden: %s\n' "$want_out"
  fi
done

if [ "${CAPTURE:-0}" = "1" ]; then
  exit 0
fi

echo ""
total=$((pass+fail))
printf 'checked %d fixture(s): %d ok, %d failing\n' "$total" "$pass" "$fail"

# A gate that silently compares zero fixtures must FAIL, not report green —
# otherwise a typo'd FIXDIR or an empty corpus reads as a pass forever.
if [ "$total" -eq 0 ]; then
  echo "FAIL: no fixtures found under $FIXDIR (checked 0 — treating as failure)"
  exit 1
fi

[ "$fail" -eq 0 ]
