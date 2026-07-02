#!/bin/sh
# run_gates.sh — run the differential compiler gates concurrently.
#
# The ~72 test/diff_compiler_*.sh gates are independent (each streams the pre-built
# test/bin/<oracle> over goldens through pipes, or uses `mktemp -d` scratch — no
# shared fixed temp paths), so they parallelize cleanly. This runner fans them out
# across a job pool and prints a PASS/FAIL summary.
#
# Usage:
#   sh test/run_gates.sh                 # all diff_compiler_*.sh, JOBS=logical CPUs
#   sh test/run_gates.sh 'pattern*'      # only gates whose basename matches the glob
#   JOBS=4 sh test/run_gates.sh          # cap concurrency
#
# Exit: 0 if every selected gate passes, else 1. Per-gate exit 2 (skipped: oracle
#       missing / opt-in) is reported as SKIP, not FAIL.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NCPU="$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
# Outer pool: how many gates run at once. Inner pool (INNER_JOBS, exported as JOBS
# to each gate): a heavy gate's own fixture fan-out. Nesting the two naively gives
# OUTER×INNER concurrent processes and oversubscribes; but the gates are latency-
# bound (thousands of tiny process spawns/execs), so a little oversubscription
# hides that latency — but too much (outer=NCPU × inner) causes scheduling spikes.
# Measured sweet spot on a 10-core box: outer≈0.6·NCPU, inner=3 (stable ~34s full
# suite vs 47s at outer=NCPU vs 125s fully serial). Tune with JOBS/INNER_JOBS.
JOBS="${JOBS:-$(( (NCPU * 3 + 2) / 5 ))}"
[ "${JOBS:-0}" -ge 2 ] 2>/dev/null || JOBS=2
INNER_JOBS="${INNER_JOBS:-3}"
RESULTDIR="$(mktemp -d)"
trap 'rm -rf "$RESULTDIR"' EXIT

# ── Worker mode: run one gate, record its status ──────────────────────────────
if [ "${1:-}" = "--run-one" ]; then
  g="$2"
  rd="$3"
  name="$(basename "$g" .sh)"
  if JOBS="${INNER_JOBS:-1}" sh "$g" >"$rd/$name.log" 2>&1; then
    st=0
  else
    st=$?
  fi
  echo "$st" >"$rd/$name.status"
  case "$st" in
    0) printf 'PASS  %s\n' "$name" ;;
    2) printf 'SKIP  %s\n' "$name" ;;
    *) printf 'FAIL  %s\n' "$name" ;;
  esac
  exit 0
fi

pat="${1:-diff_compiler_*}"
gates=""
for g in "$ROOT"/test/$pat.sh; do
  [ -f "$g" ] || continue
  gates="$gates $g"
done
[ -n "$gates" ] || { echo "no gates match: $pat"; exit 1; }

export INNER_JOBS
printf '%s\n' $gates \
  | xargs -P "$JOBS" -n 1 -I{} sh "$0" --run-one {} "$RESULTDIR"

# ── Summary ───────────────────────────────────────────────────────────────────
pass=0; fail=0; skip=0; failed=""
for s in "$RESULTDIR"/*.status; do
  [ -f "$s" ] || continue
  name="$(basename "$s" .status)"
  st="$(cat "$s")"
  case "$st" in
    0) pass=$((pass+1)) ;;
    2) skip=$((skip+1)) ;;
    *) fail=$((fail+1)); failed="$failed $name" ;;
  esac
done

printf '\n=== gates: %d passed, %d failed, %d skipped (JOBS=%s) ===\n' "$pass" "$fail" "$skip" "$JOBS"
if [ "$fail" -gt 0 ]; then
  echo "FAILED:$failed"
  echo "(logs in the run's temp dir; re-run a single gate with: sh test/<name>.sh)"
  exit 1
fi
exit 0
