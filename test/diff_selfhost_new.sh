#!/bin/sh
# Differential gate: selfhost/new_main.mdk vs OCaml `medaka new`.
# Runs both in temp dirs, diffs the produced project trees (file list + byte
# content).  Cleans up on success; leaves dirs on failure for inspection.
set -e
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
SELFMAIN="$ROOT/selfhost/new_main.mdk"

[ -x "$MAIN" ] || { echo "build first: dune build --root ."; exit 2; }

pass=0; fail=0
NAME="myapp"

TMPSELF="$(mktemp -d)"
TMPREF="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPSELF" "$TMPREF"
}
trap cleanup EXIT

# Run selfhost
(cd "$TMPSELF" && "$MAIN" run "$SELFMAIN" "$NAME" > /dev/null 2>&1) \
  || { echo "FAIL: selfhost/new_main.mdk exited non-zero"; fail=$((fail+1)); }

# Run reference
(cd "$TMPREF" && "$MAIN" new "$NAME" > /dev/null 2>&1) \
  || { echo "FAIL: medaka new exited non-zero"; fail=$((fail+1)); }

if [ "$fail" -eq 0 ]; then
  if diff -r "$TMPSELF/$NAME" "$TMPREF/$NAME" > /dev/null 2>&1; then
    pass=$((pass+1))
    printf 'ok   new/%s\n' "$NAME"
  else
    fail=$((fail+1))
    printf 'FAIL new/%s (file content differs)\n' "$NAME"
    diff -r "$TMPSELF/$NAME" "$TMPREF/$NAME" || true
  fi
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
