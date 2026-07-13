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
# Exit: 0 if every selected gate passes, else 1. Per-gate exit 2 is reported as
#       SKIP only when the skip is a GENUINE opt-in toolchain-absence (no C
#       compiler / no libgc / no wasm-tools on PATH — see LEGIT_SKIP_RE below).
#       An exit-2 whose message says an oracle/binary was never built
#       (test/bin/* or ./medaka missing) means the gate executed ZERO tests —
#       that is infra rot, not an opt-in skip, and is reclassified as FAIL (see
#       the --run-one worker). Invariant: this script must never exit 0 having
#       executed no tests (either every gate skipped, or none ran at all).
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

# A gate's exit-2 skip message is only a LEGITIMATE opt-in skip when it names a
# genuinely-absent piece of the platform toolchain. Every other exit-2 (a
# missing test/bin/* oracle, a missing ./medaka, a missing golden/fixture) means
# the gate never actually compared anything — reclassified as FAIL below.
LEGIT_SKIP_RE='no C compiler|libgc \(bdw-gc\)|not on PATH'

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
  if [ "$st" = 2 ] && ! grep -qE "$LEGIT_SKIP_RE" "$rd/$name.log"; then
    st=9   # phantom skip: oracle/binary never built — a bug, not an opt-in skip
  fi
  echo "$st" >"$rd/$name.status"
  case "$st" in
    0) printf 'PASS  %s\n' "$name" ;;
    2) printf 'SKIP  %s\n' "$name" ;;
    9) printf 'FAIL* %s  (phantom skip: oracle/binary not built — see log)\n' "$name" ;;
    *) printf 'FAIL  %s\n' "$name" ;;
  esac
  exit 0
fi

# Accept MULTIPLE patterns, so the suite can be sharded across CI jobs:
#   sh test/run_gates.sh 'diff_compiler_lex*' 'diff_compiler_parse*'
# Do NOT be tempted to pass a brace expansion ('diff_compiler_{lex*,parse*}') —
# this script runs under POSIX sh (dash on Debian), which does NOT expand braces.
# It would silently glob to nothing; the "no gates match" guard below is what turns
# that into a loud failure instead of a green no-op.
#
# A gate matching two patterns is deduped, so overlapping shards are safe.
[ "$#" -gt 0 ] || set -- 'diff_compiler_*'

gates=""
for pat in "$@"; do
  for g in "$ROOT"/test/$pat.sh; do
    [ -f "$g" ] || continue
    case " $gates " in
      *" $g "*) ;;              # already selected by an earlier pattern
      *) gates="$gates $g" ;;
    esac
  done
done
[ -n "$gates" ] || { echo "no gates match: $*"; exit 1; }

export INNER_JOBS
printf '%s\n' $gates \
  | xargs -P "$JOBS" -n 1 -I{} sh "$0" --run-one {} "$RESULTDIR"

# ── Summary ───────────────────────────────────────────────────────────────────
# status 9 = "phantom skip": the gate exited 2 because its oracle/binary was never
# built. That IS a failure (a gate that ran nothing must not report green — see the
# header), but it is a DIFFERENT failure from "the compiler is broken", and the
# summary must not conflate them.
#
# On a fresh worktree with no test/bin, EVERY oracle-reading gate phantom-skips, and
# the old summary printed a bare "63 failed" — which reads as a catastrophic
# regression. An agent hit exactly this tonight and had to read the per-gate
# annotations to discover the real message was just "you haven't built the oracles".
# Being loud is right; being loud AND misleading is not.
pass=0; fail=0; skip=0; phantom=0; failed=""
for s in "$RESULTDIR"/*.status; do
  [ -f "$s" ] || continue
  name="$(basename "$s" .status)"
  st="$(cat "$s")"
  case "$st" in
    0) pass=$((pass+1)) ;;
    2) skip=$((skip+1)) ;;
    9) fail=$((fail+1)); phantom=$((phantom+1)); failed="$failed $name" ;;
    *) fail=$((fail+1)); failed="$failed $name" ;;
  esac
done

printf '\n=== gates: %d passed, %d failed, %d skipped (JOBS=%s) ===\n' "$pass" "$fail" "$skip" "$JOBS"
if [ "$fail" -gt 0 ]; then
  # If EVERY failure is a phantom skip, the compiler is fine — you just have no
  # oracles. Say that, instead of printing a bare failure count that reads like a
  # catastrophic regression.
  if [ "$phantom" -eq "$fail" ]; then
    cat <<EOF
FAIL: none of these gates could run — their oracle binaries are not built.
      This is NOT a compiler regression. test/bin/ is not committed, so a fresh
      clone or worktree has no oracles.

      Build them:  sh test/build_oracles.sh --for 'diff_compiler_*'
                   (52 oracles, ~2 min, foreground — the safe recipe)

      Or just what you need:
                   sh test/preflight.sh          # derives them from your diff
                   sh test/build_oracles.sh --for '<gate-pattern>'

      (These gates are counted as FAILED, not skipped, on purpose: a gate that ran
       nothing must never report green. That is a deliberate fix — a fresh clone
       used to run ZERO tests and print "0 failed".)
EOF
    echo "PHANTOM-SKIPPED:$failed"
    exit 1
  fi
  echo "FAILED:$failed"
  [ "$phantom" -gt 0 ] && echo "  ($phantom of these are phantom skips: oracle not built — see above)"
  echo "(logs in the run's temp dir; re-run a single gate with: sh test/<name>.sh)"
  exit 1
fi
# Invariant: never report success having executed zero tests — a run where
# every gate skipped (even for a "legitimate" toolchain-absent reason) ran no
# comparisons and must not exit 0.
if [ "$pass" -eq 0 ]; then
  echo "FAIL: 0 gates passed ($skip skipped, $fail failed) — no tests were actually executed"
  exit 1
fi
exit 0
