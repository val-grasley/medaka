#!/bin/sh
# test/diff_compiler_references_scaling.sh — the LINEARITY detector for the
# cross-file reference index (compiler/tools/refindex.mdk, #254 Stage 0).
#
# WHY A SEPARATE GATE (the alloc gate is BLIND here)
# --------------------------------------------------
# diff_compiler_perf_scaling.sh grades GC ALLOCATION growth. A reference-index
# quadratic is the classic "a List used as a set/map, scanned once per element"
# shape — it costs TIME/OPERATIONS quadratically while allocating almost nothing
# extra per scan. An allocation-graded gate cannot see it. So this gate grades a
# deterministic **OPERATION COUNT** instead: the index-builder counts every
# hash get/set + Ref-list push it performs (compiler/tools/refindex.mdk `riOps`),
# and refindex_main prints it as `OPS <n>`. Op-count is machine-independent and
# noise-free (like allocation) but SEES a non-allocating scan.
#
# WHAT IT MEASURES
# ----------------
# A synthetic project of N modules (and again 2N), each with M small functions
# that reference an imported base symbol. Total tokens double from N to 2N, so:
#
#     linear build  O(total tokens)  ->  OPS(2N)/OPS(N) ~= 2.0
#     quadratic                       ->  ~= 4.0            <-- what we hunt
#
# PLUS a FLAT-QUERY assertion: the entry module's own content is IDENTICAL at N
# and 2N (only its bare-import list grows, which produces no occurrences), so the
# work a `binderAt` on it would do — `occCountFor entry`, printed as `OCC <n>` —
# must be EXACTLY EQUAL across the doubling. A per-query re-walk of the whole
# project would make OCC grow with N; a correct O(clicked-file) query holds it
# flat. This catches the "queries got O(project)" regression the OPS ratio alone
# would miss.
#
# Determinism note: OPS excludes the constant prelude-seeding cost (refindex
# resets its counter after seeding core/runtime), so the ratio is a clean signal
# of PROJECT-indexing growth, not diluted by a large fixed term.
#
# Usage: sh test/diff_compiler_references_scaling.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/test/bin/refindex_main"
RT="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

[ -x "$SELF" ] || {
  echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one refindex_main (missing $SELF)"
  exit 2
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

# M functions per module (fixed); N chosen so the linear term dominates the
# fixed base+entry overhead, keeping the ideal ratio close to 2.0.
M=12
N=40

# gen <dir> <N> <M> : emit a synthetic project.
#   base.mdk   — defines `gbase` (the shared referenced symbol). No imports.
#   m<i>.mdk    — import base.{gbase}; M functions, each references gbase twice.
#   main.mdk    — the ENTRY: import base.{gbase} + bare-import every m<i> (so the
#                 loader pulls them into the graph) + M FIXED functions. Its own
#                 occurrence count does not depend on N (imports add no refs).
gen() {
  d="$1"; n="$2"; m="$3"
  mkdir -p "$d"
  printf 'export gbase : Int -> Int\ngbase x = x + 1\n' > "$d/base.mdk"

  # modules m1..mN
  i=1
  while [ "$i" -le "$n" ]; do
    {
      echo 'import base.{gbase}'
      j=0
      while [ "$j" -lt "$m" ]; do
        echo "f${i}_${j} x = gbase (gbase x)"
        j=$((j + 1))
      done
    } > "$d/m${i}.mdk"
    i=$((i + 1))
  done

  # entry
  {
    echo 'import base.{gbase}'
    i=1
    while [ "$i" -le "$n" ]; do
      echo "import m${i}"
      i=$((i + 1))
    done
    j=0
    while [ "$j" -lt "$m" ]; do
      echo "hf${j} x = gbase x + gbase x"
      j=$((j + 1))
    done
  } > "$d/main.mdk"
}

# run <dir> : print "OPS OCC" for the built index over <dir>/main.mdk.
run() {
  d="$1"
  out="$("$SELF" "$RT" "$CORE" "$d/main.mdk" "$d" 2>/dev/null)"
  ops="$(printf '%s\n' "$out" | awk '$1=="OPS"{print $2}')"
  occ="$(printf '%s\n' "$out" | awk '$1=="OCC"{print $2}')"
  printf '%s %s\n' "$ops" "$occ"
}

gen "$WORK/n" "$N" "$M"
gen "$WORK/n2" "$((N * 2))" "$M"

read OPS_N OCC_N <<EOF
$(run "$WORK/n")
EOF
read OPS_2N OCC_2N <<EOF
$(run "$WORK/n2")
EOF

echo "N=$N  M=$M"
echo "  OPS: N=$OPS_N  2N=$OPS_2N"
echo "  OCC(entry): N=$OCC_N  2N=$OCC_2N"

fail=0

# sanity: the index actually did work
case "$OPS_N" in
  '' | 0) echo "FAIL: no OPS reported at N (refindex_main produced no output?)"; fail=1 ;;
esac
case "$OCC_N" in
  '' | 0) echo "FAIL: entry has no indexed occurrences (OCC=$OCC_N) — flat-query test is vacuous"; fail=1 ;;
esac

# ── primary: OPS ratio must be ~linear (< 3.0). Quadratic would be ~4.0. ──────
if [ "$fail" -eq 0 ]; then
  verdict="$(awk -v a="$OPS_N" -v b="$OPS_2N" 'BEGIN{
    if (a+0==0) { print "err"; exit }
    r=b/a; printf "%.3f", r
  }')"
  echo "  OPS ratio (2N/N) = $verdict  (linear~2.0, quadratic~4.0)"
  bad="$(awk -v a="$OPS_N" -v b="$OPS_2N" 'BEGIN{ print (a+0>0 && b/a >= 3.0) ? 1 : 0 }')"
  if [ "$bad" -eq 1 ]; then
    echo "FAIL: OPS scaling is super-linear (ratio >= 3.0) — the index build went quadratic."
    fail=1
  fi
fi

# ── secondary: FLAT query. OCC(entry) must be identical across the doubling. ──
if [ "$fail" -eq 0 ]; then
  if [ "$OCC_N" != "$OCC_2N" ]; then
    echo "FAIL: OCC(entry) changed with project size ($OCC_N -> $OCC_2N) — a query re-walks the whole project instead of O(clicked-file)."
    fail=1
  fi
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: references index build is linear and queries are flat."
  exit 0
fi
exit 1
