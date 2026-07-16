#!/usr/bin/env bash
# diff_compiler_wasm_shim_parity.sh — WASM-SEMANTICS WH3 (shim parity), MECHANISED.
#
# The wasm engine's observable behaviour is not all in the module: parts of it execute
# in the JS host. There are TWO hosts —
#
#   test/wasm/run.js     the node runner every wasm gate diffs against native
#   playground/worker.js the browser Web Worker, i.e. the 0.1.0 front door
#
# — and WH3 says they must behave identically. Until this gate, NOTHING checked that.
# The two files already carry a shared block (`fmt12g`, and since #370 `mdkStrToFloat`)
# whose header comments say "copied verbatim" / "kept byte-identical" — a comment is not
# a gate. That is exactly the shape of divergence WH3 exists to prevent: the playground
# silently answering differently from the runner every gate trusts, on the ONE surface
# no differential covers, because the runner is the thing the differential runs.
#
# What it proves: each `--- BEGIN SHARED SHIM <name> --- ... --- END SHARED SHIM <name> ---`
# region is byte-identical across both hosts. Text, not behaviour — but the block is pure
# and the host wiring around it is what the wasm gates already exercise, so byte-identity
# of the block plus those gates is what WH3 actually needs.
#
# Cheap on purpose: no compiler, no toolchain, no oracle — a text diff. It is in a
# REQUIRED `gates (frontend)` shard rather than the (advisory) `wasm` job precisely so a
# shim-only PR cannot go green while breaking parity. Add a new shared block by wrapping
# it in the markers in BOTH files; this gate then covers it automatically.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="$ROOT/test/wasm/run.js"
B="$ROOT/playground/worker.js"

for f in "$A" "$B"; do
  [ -f "$f" ] || { echo "FAIL: missing host shim $f"; exit 1; }
done

# The marker names present in run.js drive the comparison. A block that exists in run.js
# but NOT in worker.js is the failure this gate is for, so enumerate from run.js and
# demand each one back from worker.js.
names="$(sed -n 's/^\/\/ --- BEGIN SHARED SHIM \([A-Za-z_][A-Za-z0-9_]*\) ---.*/\1/p' "$A")"

if [ -z "$names" ]; then
  echo "FAIL: no '--- BEGIN SHARED SHIM <name> ---' markers in $A"
  echo "      (this gate would otherwise pass by checking nothing — a skip is not a pass)"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
n=0
for name in $names; do
  n=$((n + 1))
  for side in A B; do
    eval "src=\$$side"
    sed -n "/^\/\/ --- BEGIN SHARED SHIM $name ---/,/^\/\/ --- END SHARED SHIM $name ---/p" \
      "$src" > "$WORK/$side.$name"
    if [ ! -s "$WORK/$side.$name" ]; then
      echo "FAIL $name: block absent from $src"
      fail=$((fail + 1))
      continue 2
    fi
    # An unterminated region silently swallows the rest of the file, which would make a
    # real divergence look like a huge diff instead of a missing END marker.
    grep -q "^// --- END SHARED SHIM $name ---" "$WORK/$side.$name" || {
      echo "FAIL $name: no matching END marker in $src"
      fail=$((fail + 1))
      continue 2
    }
  done
  if diff -u "$WORK/A.$name" "$WORK/B.$name" > "$WORK/d.$name" 2>&1; then
    echo "  ok   $name  ($(grep -c '' "$WORK/A.$name") lines, byte-identical)"
  else
    echo "FAIL $name: run.js and worker.js DIVERGE (WASM-SEMANTICS WH3)"
    echo "      the playground would answer differently from the gated runner."
    sed -n '1,40p' "$WORK/d.$name"
    fail=$((fail + 1))
  fi
done

echo "shim parity: $((n - fail))/$n shared blocks identical across run.js and worker.js"
[ "$fail" -eq 0 ] || exit 1
