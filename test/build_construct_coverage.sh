#!/usr/bin/env bash
# test/build_construct_coverage.sh — Stage 3 #2b construct-coverage gate.
#
# For each fixture in test/construct_fixtures/*.mdk:
#   1. medaka build → native binary
#   2. Run native binary; compare with medaka run (oracle)
#   3. Native auto-prints `()` for main : <IO* Unit; oracle doesn't — match expected
#
# Opt-in skip: requires clang + libgc (same as build_cmd.sh).
# Run:  bash test/build_construct_coverage.sh
#
# The PASS set covers the constructs verified native==interpreter as of 2026-06-10.
# GAPs are documented in selfhost/CONSTRUCT-COVERAGE.md.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
FIXTURES="$ROOT/test/construct_fixtures"
CC="${CC:-clang}"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }

# libgc probe (same logic as build_cmd.sh)
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then :
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then :
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then :
else echo "libgc (bdw-gc) not found — skipping (install bdw-gc)"; exit 2; fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0

check() {
  local src="$1"
  local label
  label="$(basename "$src" .mdk)"
  local bin="$WORK/$label.bin"

  if ! "$MAIN" build "$src" -o "$bin" >"$WORK/$label.out" 2>"$WORK/$label.err"; then
    fail=$((fail+1))
    printf 'FAIL %s (build)\n' "$label"
    sed 's/^/    /' "$WORK/$label.err" | head -5
    return
  fi

  local native oracle expected
  native="$("$bin" 2>/dev/null)"
  oracle="$("$MAIN" run "$src" 2>/dev/null)"
  expected="$oracle
()"

  if [ "$native" = "$expected" ]; then
    pass=$((pass+1))
    printf 'ok   %s\n' "$label"
  else
    fail=$((fail+1))
    printf 'FAIL %s (diff)\n' "$label"
    printf '%s' "$expected" > "$WORK/exp.txt"
    printf '%s' "$native"   > "$WORK/got.txt"
    diff "$WORK/exp.txt" "$WORK/got.txt" | head -8 | sed 's/^/    /'
  fi
}

for src in "$FIXTURES"/*.mdk; do
  check "$src"
done

printf '\n%d ok, %d failing (of %d)\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
