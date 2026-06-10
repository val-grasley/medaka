#!/bin/sh
# test/diff_selfhost_repl.sh
#
# Differential gate for the self-hosted REPL (Phase B.9).
# Pipes a fixed input script through both the OCaml reference REPL and the
# self-hosted REPL, compares stdout (stderr suppressed on both sides to avoid
# location-format divergence in error messages).
#
# Covers:
#   - Declaration then use (persistent env)
#   - Expression result
#   - Deliberate type error (session survives — next input still works)
#   - :type query
#   - :browse (user bindings)
#   - :reset (clears session)
#   - :browse after reset
#   - Multiple bindings

set -e

WDIR=$(cd "$(dirname "$0")/.." && pwd)
MAIN="$WDIR/_build/default/bin/main.exe"
RUNTIME="$WDIR/stdlib/runtime.mdk"
CORE="$WDIR/stdlib/core.mdk"
SELFHOST_REPL="$WDIR/selfhost/repl_main.mdk"

# Fixed input script — each line is one REPL input.
# Error case: `badname` is unbound, error goes to stderr (suppressed), session
# continues and the next expression `x + 1` still evaluates.
INPUT='x = 42
y = x + 1
[x, y]
badname
x + 1
:type x
:browse
:reset
:browse
:quit
'

OCaml_OUT=$(printf '%s' "$INPUT" | \
  perl -e 'alarm 30; exec @ARGV' "$MAIN" repl 2>/dev/null)

SELF_OUT=$(printf '%s' "$INPUT" | \
  perl -e 'alarm 180; exec @ARGV' "$MAIN" run "$SELFHOST_REPL" "$RUNTIME" "$CORE" 2>/dev/null)

if [ "$OCaml_OUT" = "$SELF_OUT" ]; then
  echo "PASS: selfhost repl output matches OCaml repl"
  exit 0
else
  echo "FAIL: outputs differ"
  echo "=== OCaml REPL ==="
  printf '%s\n' "$OCaml_OUT"
  echo "=== Selfhost REPL ==="
  printf '%s\n' "$SELF_OUT"
  echo "=== diff ==="
  TMPDIR=$(mktemp -d)
  printf '%s\n' "$OCaml_OUT" > "$TMPDIR/ocaml.txt"
  printf '%s\n' "$SELF_OUT" > "$TMPDIR/self.txt"
  diff "$TMPDIR/ocaml.txt" "$TMPDIR/self.txt" || true
  rm -rf "$TMPDIR"
  exit 1
fi
