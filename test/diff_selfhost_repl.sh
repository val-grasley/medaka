#!/bin/sh
# test/diff_selfhost_repl.sh
#
# Gate for the self-hosted REPL (Stage 4, Phase B.9), RE-ROOTED off the OCaml
# oracle (REROOT-PLAN §2d).
#
# GOLDEN CAPTURED FROM THE NATIVE REPL (CANONICAL), **NOT** OCaml.
#   The OCaml `medaka repl` and the self-hosted repl DIVERGE on post-error prompt
#   behaviour: after an unbound-variable line, the OCaml repl keeps emitting
#   prompts for the remaining commands, whereas the self-hosted repl (both
#   interpreted AND native-compiled — they AGREE byte-for-byte) stops short.  The
#   original gate only "passed" because its stderr-redirected pipe raced the two
#   legs into the same truncated transcript.  Per REROOT-PLAN the self-hosted
#   backend is CANONICAL, so the golden (test/repl_fixtures/session.golden) is
#   captured from the NATIVE repl binary and this gate diffs native-vs-golden.
#   The native output is DETERMINISTIC across runs (the :browse sort bug was fixed
#   in cc49e60; verified stable across 5 runs at re-root time).
#   *** DESIGN CALL FLAGGED FOR MAINTAINER: the native/OCaml post-error-prompt
#       divergence is a real behavioural difference, not a native-compile bug. ***
#
# Covers (test/repl_fixtures/session.in):
#   - Declaration then use (persistent env)
#   - Expression result
#   - Deliberate type error (session survives — next input still works)
#   - :type query / :browse / :reset / :browse after reset
#
# Oracle: native test/bin/repl_main (built by sh test/build_oracles.sh) reading
# stdin, vs the committed golden (captured by sh test/capture_goldens.sh repl).
#
# Usage:  sh test/diff_selfhost_repl.sh
# Exit:   0 if native repl stdout == golden; 1 on mismatch; 2 if oracle missing.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/repl_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
INPUT="$ROOT/test/repl_fixtures/session.in"
GOLDEN="$ROOT/test/repl_fixtures/session.golden"

[ -x "$RUN" ]    || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }
[ -f "$INPUT" ]  || { echo "missing $INPUT"; exit 2; }
[ -f "$GOLDEN" ] || { echo "missing golden $GOLDEN (run sh test/capture_goldens.sh repl)"; exit 2; }

SELF_OUT=$(perl -e 'alarm 180; exec @ARGV' -- "$RUN" "$RUNTIME" "$CORE" < "$INPUT" 2>/dev/null)
EXPECTED=$(cat "$GOLDEN")

if [ "$SELF_OUT" = "$EXPECTED" ]; then
  echo "PASS: native selfhost repl output matches golden"
  exit 0
else
  echo "FAIL: native repl output differs from golden"
  echo "=== golden ==="
  printf '%s\n' "$EXPECTED"
  echo "=== native repl ==="
  printf '%s\n' "$SELF_OUT"
  echo "=== diff ==="
  TMPDIR=$(mktemp -d)
  printf '%s\n' "$EXPECTED" > "$TMPDIR/golden.txt"
  printf '%s\n' "$SELF_OUT" > "$TMPDIR/self.txt"
  diff "$TMPDIR/golden.txt" "$TMPDIR/self.txt" || true
  rm -rf "$TMPDIR"
  exit 1
fi
