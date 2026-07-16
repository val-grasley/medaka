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

# #299 regression guard: `medaka mcp --help`/`-h` must print usage and exit 0
# WITHOUT entering the JSON-RPC read loop, and a bogus arg must be rejected on
# stderr with a nonzero exit — none of the three may block on stdin.  Feed
# stdin that stays open for longer than the alarm so a regression to "argv
# discarded, always read the loop" hangs and gets killed by the alarm (rc
# ~142) instead of silently passing.  Run BEFORE the fixture loop so the gate
# still fails fast if `medaka mcp` itself is missing/unbuilt.
check_mcp_arg () {
  argdesc="$1"; shift
  want_marker="$1"; shift
  tmpout="$(mktemp)"
  perl -e 'alarm 5; exec @ARGV' "$MEDAKA" mcp "$@" < /dev/zero > "$tmpout" 2>"$tmpout.err"
  rc=$?
  out="$(cat "$tmpout")"
  err="$(cat "$tmpout.err")"
  rm -f "$tmpout" "$tmpout.err"
  case "$rc" in
    142) fail=$((fail+1)); printf 'FAIL mcp-arg(%s): hung (killed by alarm)\n' "$argdesc"; return ;;
  esac
  case "$want_marker" in
    usage)
      if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "medaka mcp"; then
        pass=$((pass+1)); printf 'ok   mcp-arg(%s)\n' "$argdesc"
      else
        fail=$((fail+1)); printf 'FAIL mcp-arg(%s): rc=%d out=%s\n' "$argdesc" "$rc" "$out"
      fi
      ;;
    reject)
      if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -qi "unknown argument"; then
        pass=$((pass+1)); printf 'ok   mcp-arg(%s)\n' "$argdesc"
      else
        fail=$((fail+1)); printf 'FAIL mcp-arg(%s): rc=%d err=%s\n' "$argdesc" "$rc" "$err"
      fi
      ;;
  esac
}

if [ -x "$MEDAKA" ]; then
  check_mcp_arg "--help" usage --help
  check_mcp_arg "-h" usage -h
  check_mcp_arg "bogusarg" reject bogusarg
fi

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

# ── opt-in call-logging coverage ─────────────────────────────────────────
#
# Every fixture above runs with MEDAKA_MCP_LOG UNSET, so the loop above only
# ever exercises logMcpCall's no-op branch — zero automated coverage of the
# feature's actual risk: does turning logging ON perturb the stdout protocol
# channel, and is the log file itself well-formed? Re-run the `logging`
# fixture (a tools/call whose client-controlled "name" deliberately embeds a
# raw '\n' and '\t', the exact case that used to split one log record across
# physical lines before method/name were routed through json.escapeString)
# with MEDAKA_MCP_LOG pointed at a fresh mktemp path and assert:
#   1. stdout is BYTE-IDENTICAL to the SAME golden already diffed above —
#      logging must not perturb the protocol channel.
#   2. the log file holds exactly one physical line per logged event (no
#      unescaped newline leaked a record across lines), tab-separated into
#      exactly 4 fields, with `tools/call` appearing EXACTLY ONCE and
#      carrying the escaped tool name plus its stringified arguments.
# Every check below is an exact-count assertion (never ">= 0" / "non-empty")
# so a regression that silently drops all logging can't read as a pass.
log_name="logging"
log_req="$FIXDIR/$log_name.jsonl"
log_golden="$FIXDIR/$log_name.golden"

if [ ! -f "$log_req" ] || [ ! -f "$log_golden" ]; then
  fail=$((fail+1))
  printf 'FAIL logging-on: missing fixture/golden for %s (need test/mcp_fixtures/%s.jsonl + .golden)\n' "$log_name" "$log_name"
else
  logdir="$(mktemp -d)"
  logfile="$logdir/mcp_call.log"
  tmpout="$(mktemp)"
  MEDAKA_MCP_LOG="$logfile" perl -e 'alarm 30; exec @ARGV' "$MEDAKA" mcp < "$log_req" > "$tmpout" 2>/dev/null
  rc=$?
  self_out="$(cat "$tmpout")"
  want_out="$(cat "$log_golden")"
  rm -f "$tmpout"

  if [ "$rc" -ne 0 ]; then
    fail=$((fail+1)); printf 'FAIL logging-on(stdout): medaka mcp exited %d\n' "$rc"
  elif [ "$self_out" != "$want_out" ]; then
    fail=$((fail+1)); printf 'FAIL logging-on(stdout): MEDAKA_MCP_LOG perturbed stdout\n'
    printf '  self:   %s\n' "$self_out"
    printf '  golden: %s\n' "$want_out"
  else
    pass=$((pass+1)); printf 'ok   logging-on(stdout unchanged)\n'
  fi

  if [ ! -s "$logfile" ]; then
    fail=$((fail+1)); printf 'FAIL logging-on(log-file): %s missing or empty\n' "$logfile"
  else
    nlines=$(wc -l < "$logfile" | tr -d ' ')
    nfields_bad=$(awk -F'\t' 'NF!=4' "$logfile" | wc -l | tr -d ' ')
    ncalls=$(awk -F'\t' '$2=="\"tools/call\""' "$logfile" | wc -l | tr -d ' ')
    call_line="$(awk -F'\t' '$2=="\"tools/call\""' "$logfile")"

    if [ "$nlines" -ne 4 ]; then
      fail=$((fail+1)); printf 'FAIL logging-on(log-lines): expected 4 physical lines (initialize, notifications/initialized, tools/call, shutdown), got %s\n' "$nlines"
      cat "$logfile"
    elif [ "$nfields_bad" -ne 0 ]; then
      fail=$((fail+1)); printf 'FAIL logging-on(log-format): %s line(s) do not have exactly 4 tab-separated fields (an embedded \\n/\\t leaked unescaped?)\n' "$nfields_bad"
      cat "$logfile"
    elif [ "$ncalls" -ne 1 ]; then
      fail=$((fail+1)); printf 'FAIL logging-on(tools/call-count): expected exactly 1 tools/call record, found %s\n' "$ncalls"
      cat "$logfile"
    else
      case "$call_line" in
        *'"weird\nname\ttab"'*'"probe":true'*)
          pass=$((pass+1)); printf 'ok   logging-on(tools/call record: name+args escaped correctly)\n'
          ;;
        *)
          fail=$((fail+1)); printf 'FAIL logging-on(tools/call record): unexpected content: %s\n' "$call_line"
          ;;
      esac
    fi
  fi
  rm -rf "$logdir"
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
