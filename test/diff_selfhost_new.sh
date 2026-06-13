#!/bin/sh
# Differential gate: selfhost/entries/new_main.mdk vs the `medaka new` scaffold.
#
# OCaml-free (REROOT-PLAN §2c): native host test/bin/new_main scaffolds a project
# tree in a temp dir; the reference is a committed golden tree under
# test/new_golden/myapp captured from `main.exe new myapp`
# (test/capture_goldens.sh new).  Diffs the produced tree (file list + byte content)
# vs the golden.  Cleans up on success; leaves the temp dir on failure.
set -e
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/new_main"
GOLD="$ROOT/test/new_golden/myapp"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }
[ -d "$GOLD" ] || { echo "no golden tree $GOLD — run sh test/capture_goldens.sh new"; exit 2; }

pass=0; fail=0
NAME="myapp"

TMPSELF="$(mktemp -d)"
cleanup() { rm -rf "$TMPSELF"; }
trap cleanup EXIT

# Run the native selfhost scaffolder in an isolated temp dir.
(cd "$TMPSELF" && "$RUN" "$NAME" > /dev/null 2>&1) \
  || { echo "FAIL: test/bin/new_main exited non-zero"; fail=$((fail+1)); }

if [ "$fail" -eq 0 ]; then
  if diff -r "$TMPSELF/$NAME" "$GOLD" > /dev/null 2>&1; then
    pass=$((pass+1))
    printf 'ok   new/%s\n' "$NAME"
  else
    fail=$((fail+1))
    printf 'FAIL new/%s (file content differs)\n' "$NAME"
    diff -r "$TMPSELF/$NAME" "$GOLD" || true
  fi
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
