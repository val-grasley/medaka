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

# ── A gate is identified by its PATH, not its basename ────────────────────────
#
# Gates do not all live in test/. `sqlite/test/*_oracle.sh` (22 differential gates
# against the real sqlite3 CLI) and test/native_fixtures/run.sh are gates too, and
# basenames COLLIDE across those roots (test/native_fixtures/run.sh vs
# playground/e2e/run.sh both stem to "run"). A results dir keyed on the basename
# would silently overwrite one gate's status with another's — "this didn't run"
# masquerading as "this passed", which is the one thing this suite exists to
# prevent. So key on the repo-relative path.
#
# The leading `test_` is stripped so the ~119 gates under test/ keep their familiar
# labels (diff_compiler_lexer, not test_diff_compiler_lexer) — only gates outside
# test/ gain a prefix, and they had no label before because they never ran.
gate_name() {
  printf '%s\n' "${1#"$ROOT"/}" | sed -e 's|\.sh$||' -e 's|/|_|g' -e 's|^test_||'
}

# Gates outside test/ (the sqlite oracles) locate the tree through these rather
# than by walking up from $0. Defaults only — an explicit value always wins.
export MEDAKA_ROOT="${MEDAKA_ROOT:-$ROOT}"
export MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"

# ── Worker mode: run one gate, record its status ──────────────────────────────
if [ "${1:-}" = "--run-one" ]; then
  g="$2"
  rd="$3"
  name="$(gate_name "$g")"
  # ── HONOR THE SHEBANG. Do not hardcode `sh`. ────────────────────────────────
  #
  # This ran EVERY gate with `sh` — which on Debian is dash. But 6 gates under test/
  # are `#!/usr/bin/env bash` and use bashisms (`local`, `set -o pipefail`, process
  # substitution, `${BASH_SOURCE[0]}`), and THREE OF THEM ARE ALREADY IN CI SHARDS:
  # diff_compiler_engines, diff_compiler_lint_multi, diff_compiler_tmc_parity. They
  # have been run under the wrong interpreter this whole time. They happen to survive
  # it; that is luck, not design, and "the gate ran under an interpreter it wasn't
  # written for" is not a property you want to be lucky about.
  #
  # It stopped being luck the moment the sqlite oracles were enrolled: all 22 are
  # `#!/usr/bin/env bash`, and under dash all 22 FAILED — while passing perfectly when
  # invoked directly. A gate that fails only because the runner picked the wrong shell
  # is the purest form of the bug this suite exists to prevent: the result says
  # "the compiler is broken" and means "the harness is broken".
  case "$(head -n 1 "$g")" in
    *bash*) _shell=bash ;;
    *)      _shell=sh ;;
  esac
  if JOBS="${INNER_JOBS:-1}" "$_shell" "$g" >"$rd/$name.log" 2>&1; then
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

#
# A pattern resolves against BOTH `$ROOT/test/` and `$ROOT/`, so a shard can name a
# gate that does not live under test/ — e.g. 'sqlite/test/*_oracle' (the 22
# differential gates against the real sqlite3 CLI, which had never run in CI at all
# because no pattern could even REACH them). A bare pattern like 'diff_compiler_*'
# matches nothing at the repo root, so this is backwards-compatible.
#
# build_oracles.sh --for and diff_compiler_ci_shard_coverage.sh resolve patterns the
# SAME way. All three must agree: if the coverage gate believed a shard pattern
# selected a gate that run_gates.sh could not actually glob, CI would certify
# coverage of a gate that silently never ran.
gates=""
for pat in "$@"; do
  for g in "$ROOT"/test/$pat.sh "$ROOT"/$pat.sh; do
    [ -f "$g" ] || continue
    case " $gates " in
      *" $g "*) ;;              # already selected by an earlier pattern
      *) gates="$gates $g" ;;
    esac
  done
done
[ -n "$gates" ] || { echo "no gates match: $*"; exit 1; }

# ── STALE ORACLES: refuse to run. A stale oracle does not fail — it LIES. ────────
#
# test/bin/* are compiled probe binaries. If one predates the compiler source, every
# gate that reads it is testing a compiler that no longer exists — and it reports a
# perfectly ordinary-looking FAIL. There is no way to tell that from a real regression
# by reading the output, and three agents were burned by it in one day:
#
#   * one saw `unbound variable 'areaOf'` — THE EXACT SYMPTOM OF THE BUG IT WAS FIXING —
#     emitted by a binary built before its own fix, and nearly re-diagnosed it;
#   * one saw diff_compiler_tmc_parity report `llvm=0 wasm=5` and read it as "my merge
#     broke the dispatch-group path". The LLVM probe was simply pre-merge;
#   * one chased a red eval_modules/core_ir_modules/llvm_modules trio that was purely age.
#
# So this is not a warning. A run against stale oracles PROVED NOTHING about the current
# source, and "proved nothing" must never be reported as pass OR as a compiler failure —
# that conflation is this suite's entire reason for existing (see the header).
#
# ⚠️ DISABLED IN CI ON PURPOSE — mtime is the WRONG SIGNAL THERE, and this is not a
# cop-out, it is the stronger check winning.
#
# CI restores test/bin from an actions/cache whose KEY IS A CONTENT HASH of compiler/**,
# stdlib/**, runtime/** and the build scripts. A cache HIT therefore means the oracles were
# built from exactly this source — proven by hash, not inferred from a clock. Meanwhile
# `actions/checkout` stamps every source file with a FRESH mtime, and the cache restores the
# binaries with their ORIGINAL (older) mtimes. So mtime says "stale" about oracles that are
# provably current, and this check red-lit all six shards on its first CI run.
#
# A content-hash key is STRICTLY STRONGER than an mtime comparison: mtime can be fooled by a
# touch, a checkout, or a clock skew; a hash cannot. Keep the weak local heuristic for local
# trees (where there is no hash to consult) and defer to the strong one where it exists.
#
# Also skipped by NO_STALE_CHECK=1 (build_oracles.sh's own internal invocations).
if [ -z "${NO_STALE_CHECK:-}" ] && [ -z "${CI:-}" ] && [ -d "$ROOT/test/bin" ]; then
  newest_src=0
  for f in $(find "$ROOT/compiler" "$ROOT/stdlib" -name '*.mdk'; \
             find "$ROOT/runtime" -name '*.c' -o -name '*.h'); do
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
    [ "$m" -gt "$newest_src" ] && newest_src=$m
  done

  # Check ONLY the probes the SELECTED gates actually read — derived from the gate
  # scripts themselves (the same `test/bin/<name>` scrape build_oracles.sh --for uses),
  # not every file in test/bin.
  #
  # Checking all of test/bin was wrong and I shipped it for about five minutes: the wasm
  # probes are built by a DIFFERENT script (test/wasm/build_wasm_oracle.sh) and are not in
  # build_oracles' ENTRIES, so they are routinely older than source — which would have
  # blocked an unrelated `diff_compiler_lexer` run over a probe it never opens. Scope the
  # complaint to what this run actually depends on.
  #
  # This still catches the real cases: diff_compiler_tmc_parity DOES read the wasm probes,
  # so a stale one is flagged when — and only when — that gate is selected. That is exactly
  # the false RED that cost an agent a wrong diagnosis (`llvm=0 wasm=5`, from a pre-merge
  # LLVM probe).
  needed=""
  for g in $gates; do
    for o in $(grep -ohE 'test/bin/[a-z_0-9]+' "$g" 2>/dev/null | sed 's|test/bin/||' | sort -u); do
      case " $needed " in *" $o "*) ;; *) needed="$needed $o" ;; esac
    done
  done

  stale=""
  n_stale=0
  for o in $needed; do
    b="$ROOT/test/bin/$o"
    [ -f "$b" ] || continue          # MISSING is a different failure — the phantom-skip
                                     # path below owns it, and says so in its own words.
    m=$(stat -c %Y "$b" 2>/dev/null || stat -f %m "$b" 2>/dev/null)
    if [ "${m:-0}" -lt "$newest_src" ]; then
      n_stale=$((n_stale + 1))
      [ "$n_stale" -le 6 ] && stale="$stale  $o
"
    fi
  done

  if [ "$n_stale" -gt 0 ]; then
    echo "════════════════════════════════════════════════════════════════════"
    echo "STALE ORACLES ($n_stale) — REFUSING TO RUN."
    echo
    printf '%s' "$stale"
    [ "$n_stale" -gt 6 ] && echo "  ... and $((n_stale - 6)) more"
    echo
    echo "These probe binaries are OLDER than compiler/ stdlib/ runtime/ source."
    echo "A gate reading one is testing a compiler that no longer exists — and it"
    echo "reports an ordinary-looking FAIL that is INDISTINGUISHABLE from a real"
    echo "regression. Agents have re-diagnosed their own already-fixed bug from one."
    echo
    echo "  Rebuild:  FORCE=1 sh test/build_oracles.sh                  # all"
    echo "            FORCE=1 sh test/build_oracles.sh --for '<gate>'   # just these"
    echo
    echo "(Override with NO_STALE_CHECK=1 only if you know exactly why.)"
    echo "════════════════════════════════════════════════════════════════════"
    exit 1
  fi
fi

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
  echo "(logs in the run's temp dir; re-run a single gate by its path, e.g. sh test/<name>.sh"
  echo " — a name like sqlite_test_oracle is the repo-relative path with '/' as '_')"
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
