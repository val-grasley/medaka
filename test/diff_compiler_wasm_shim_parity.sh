#!/usr/bin/env bash
# diff_compiler_wasm_shim_parity.sh — WASM-SEMANTICS WH3 (shim parity), MECHANISED.
#
# The wasm engine's observable behaviour is not all in the module: parts of it execute
# in the JS host. There are THREE hosts —
#
#   test/wasm/run.js       the node runner every wasm gate diffs against native
#   playground/worker.js   the browser Web Worker that runs the USER's compiled program
#   playground/compile.mjs the seam that runs the COMPILER itself (playground.wasm) —
#                          imported by playground/compiler-worker.js, language-worker.js
#                          and the node drivers (dev_compile_node.mjs, client_flow_test.mjs,
#                          lang_query_test.mjs)
#
# — and WH3 says they must behave identically. Until this gate, NOTHING checked that.
# The files already carry a shared block (`fmt12g`, and since #370 `mdkStrToFloat`)
# whose header comments say "copied verbatim" / "kept byte-identical" — a comment is not
# a gate. That is exactly the shape of divergence WH3 exists to prevent: the playground
# silently answering differently from the runner every gate trusts, on the ONE surface
# no differential covers, because the runner is the thing the differential runs.
#
# ⚠️ THE FILE SET IS ITSELF THE HAZARD (#543).  This gate shipped comparing only run.js
# and worker.js, and the docs said "the TWO JS host shims" — but compile.mjs is a third
# copy of BOTH blocks and it was excluded, so:
#   * #370's fix updated the two gated copies and left compile.mjs on raw `Number()`
#     (the exact S0 the fix removed) AND missing the new `mdk_str_to_float_ok` import,
#     which LinkError'd the playground dead at instantiate; and
#   * compile.mjs's `fmt12g` silently stayed on the pre-#361 `%.12g` (toExponential(11))
#     formatter while the gated pair moved to shortest-repr.
# Both were invisible precisely BECAUSE the gate enumerated a set of two.  A gate that
# checks a SUBSET of the copies manufactures confidence about the ones it skips.  So the
# host set below is DERIVED (grep for the marker), never encoded: a new copy enrols itself
# the moment it exists, with no edit to this file and no count to go stale.
#
# What it proves: each `--- BEGIN SHARED SHIM <name> --- ... --- END SHARED SHIM <name> ---`
# region is byte-identical across every host. Text, not behaviour — but the block is pure
# and the host wiring around it is what the wasm gates already exercise, so byte-identity
# of the block plus those gates is what WH3 actually needs.
#
# Cheap on purpose: no compiler, no toolchain, no oracle — a text diff. It is in a
# REQUIRED `gates (frontend)` shard rather than the (advisory) `wasm` job precisely so a
# shim-only PR cannot go green while breaking parity. Add a new shared block by wrapping
# it in the markers in EVERY file below; this gate then covers it automatically.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# run.js is the reference: it is the runner every wasm differential already trusts.
REF="$ROOT/test/wasm/run.js"

# ── DERIVE the host set; do NOT encode it ────────────────────────────────────────
# The whole point of #543 is that a hardcoded set of hosts silently excluded the one
# that mattered. An encoded list here would reproduce that defect INSIDE the gate built
# to prevent it: a fourth host (a Cloudflare Worker variant, an SSR seam, a CLI wrapper)
# would pass "3/3 ok" forever because the gate never looked at it. So the set is a QUERY,
# not a constant — any file carrying a BEGIN SHARED SHIM marker is a host, automatically,
# the moment it exists. Adding a copy enrols it with no edit to this file.
[ -f "$REF" ] || { echo "FAIL: missing reference host shim $REF"; exit 1; }

# A host is a file that CARRIES a marker line, so anchor on the real thing: `^// --- BEGIN
# SHARED SHIM <name> ---`. Matching the bare phrase instead would sweep in every file that
# merely TALKS about the markers — this script (its own sed patterns), the docs, the
# workstream notes — which is a self-match, not a host.
PEERS="$(grep -rlE '^// --- BEGIN SHARED SHIM [A-Za-z_]' "$ROOT/test" "$ROOT/playground" 2>/dev/null \
  | grep -Fxv "$REF" | sort)"

# A derived set that comes back EMPTY is the gate checking nothing — the failure mode this
# gate's own header calls out ("a skip is not a pass"). We know of at least two peers, so
# an empty derivation means the query broke (a moved directory, a renamed marker), not that
# the tree is clean.
if [ -z "$PEERS" ]; then
  echo "FAIL: derived ZERO peer host shims besides $REF"
  echo "      (expected at least playground/worker.js + playground/compile.mjs — the"
  echo "       marker query broke; a gate that checks nothing must never report green)"
  exit 1
fi

# The marker names present in run.js drive the comparison. A block that exists in run.js
# but NOT in a peer is the failure this gate is for, so enumerate from run.js and
# demand each one back from every peer.
names="$(sed -n 's/^\/\/ --- BEGIN SHARED SHIM \([A-Za-z_][A-Za-z0-9_]*\) ---.*/\1/p' "$REF")"

if [ -z "$names" ]; then
  echo "FAIL: no '--- BEGIN SHARED SHIM <name> ---' markers in $REF"
  echo "      (this gate would otherwise pass by checking nothing — a skip is not a pass)"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# extract_block <file> <name> <out> — 0 on a well-formed block, 1 otherwise (reason on stdout).
extract_block() {
  _f="$1"; _name="$2"; _out="$3"
  sed -n "/^\/\/ --- BEGIN SHARED SHIM $_name ---/,/^\/\/ --- END SHARED SHIM $_name ---/p" \
    "$_f" > "$_out"
  if [ ! -s "$_out" ]; then
    echo "FAIL $_name: block absent from $_f"
    return 1
  fi
  # An unterminated region silently swallows the rest of the file, which would make a
  # real divergence look like a huge diff instead of a missing END marker.
  grep -q "^// --- END SHARED SHIM $_name ---" "$_out" || {
    echo "FAIL $_name: no matching END marker in $_f"
    return 1
  }
  return 0
}

nhosts=$(( $(echo $PEERS | wc -w) + 1 ))
fail=0
n=0
for name in $names; do
  n=$((n + 1))
  extract_block "$REF" "$name" "$WORK/REF.$name" || { fail=$((fail + 1)); continue; }

  bad=0
  for peer in $PEERS; do
    tag="$(basename "$peer")"
    extract_block "$peer" "$name" "$WORK/$tag.$name" || { bad=1; continue; }
    if ! diff -u "$WORK/REF.$name" "$WORK/$tag.$name" > "$WORK/d.$tag.$name" 2>&1; then
      echo "FAIL $name: run.js and $tag DIVERGE (WASM-SEMANTICS WH3)"
      echo "      the playground would answer differently from the gated runner."
      sed -n '1,40p' "$WORK/d.$tag.$name"
      bad=1
    fi
  done

  if [ "$bad" -eq 0 ]; then
    echo "  ok   $name  ($(grep -c '' "$WORK/REF.$name") lines, byte-identical across $nhosts hosts)"
  else
    fail=$((fail + 1))
  fi
done

hostlist="run.js$(for p in $PEERS; do printf ', %s' "$(basename "$p")"; done)"
echo "shim parity: $((n - fail))/$n shared blocks identical across $nhosts hosts ($hostlist)"
[ "$fail" -eq 0 ] || exit 1
