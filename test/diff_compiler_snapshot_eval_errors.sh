#!/bin/sh
# diff_compiler_snapshot_eval_errors.sh — the self-hosted RUNTIME-ERROR corpus, as a
# snapshot gate.  docs/ops/TESTING-DESIGN.md §4.3; mirrors diff_compiler_snapshot_eval.sh
# (#81 R6).
#
# REPLACES the probe-driven gate and the per-fixture `.expected` golden it diffed:
#
#   diff_compiler_eval_errors.sh   test/bin/eval_prelude_main   eval_error_fixtures (9)
#
# Each fixture in test/eval_error_fixtures/ type-checks but fails at RUN time (division
# by zero, OOB index/slice, non-exhaustive match, …).  The old gate ran the shared
# eval_prelude_main probe once per fixture and compared its stderr, normalized, to a
# committed `<name>.expected`.  The snapshot runner drives the same elaborate+eval
# pipeline IN-PROCESS: for a fixture that aborts, the crash supervisor banks the coded
# runtime diagnostic into the fixture's `# CRASH` section (a stderr dump, diagnostic
# by construction), so the per-file process spawn the old gate paid is gone.
#
# ── THE no_main SPECIAL CASE (why this is a C-track gate, not a pure mint) ────
# 8 of the 9 fixtures ABORT the worker, so their `# CRASH` is written by the supervisor
# exactly as a real crash would be — surveyed byte-identical to the deleted gate's
# `.expected` (8/8).  The 9th, no_main.mdk, has no `main`, so it never runs and never
# crashes: the interpreter's E-NO-MAIN is a driver-level check, not a runtime abort.
# The snapshot runner therefore emits it as a STATIC `# CRASH` diagnostic — the exact
# text `runtimePanic "E-NO-MAIN" noMainMsg` would print — from the no-`main` branch of
# workerStages (compiler/tools/snapshot.mdk), WITHOUT running the crash-loop machinery.
# That closes a real gap too: before this, a no-`main` program snapshotted as silently
# empty.  See #81 (eval_errors) for the write-up.
#
# ── RE-CUTTING: rm + --new, NOT --bless ──────────────────────────────────────
# Every section here is `# CRASH` — diagnostic by construction, hence PERMANENTLY
# UNBLESSABLE (the runner refuses `--bless` on a diagnostic section, by design: a crash
# dump must never be rubber-stamped).  To re-cut after an intended change, DELETE the
# `.md` and re-run with --new.  The --bless path below exists only to give a precise
# error ("unblessable") instead of a confusing one.
#
# ── WHAT IS AND IS NOT DELETED ───────────────────────────────────────────────
# The gate SCRIPT and the 9 `.expected` goldens are removed (the `# CRASH` sections now
# own that truth).  The eval_error_fixtures `.mdk` and the SHARED eval_prelude_main probe
# SURVIVE — the probe is driven by other eval gates and fuzz_diff.sh.
#
# Usage:  sh test/diff_compiler_snapshot_eval_errors.sh          # CHECK (the gate)
#         sh test/diff_compiler_snapshot_eval_errors.sh --new    # create MISSING snapshots
#         sh test/diff_compiler_snapshot_eval_errors.sh --bless <path>...   # (refused: unblessable)
#
# Exit:   0 if every snapshot matches, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
SNAPDIR="$ROOT/test/snapshots"

[ -x "$MEDAKA" ] || { echo "build the compiler first: make medaka (missing $MEDAKA)"; exit 2; }

fail=0
total=0
compared=0
skipped=0

# ── --bless <path>... ─────────────────────────────────────────────────────────
if [ "${1:-}" = "--bless" ]; then
  shift
  if [ "$#" -eq 0 ]; then
    echo "--bless requires explicit fixture paths — there is no whole-suite bless." >&2
    exit 1
  fi
  rc=0
  for p in "$@"; do
    [ "$p" = "--bless" ] && continue
    case "$p" in /*) ;; *) p="$(cd "$(dirname "$p")" 2>/dev/null && pwd)/$(basename "$p")" ;; esac
    [ -e "$p" ] || { echo "no such path: $p" >&2; rc=1; continue; }
    case "$p" in
      "$ROOT"/test/eval_error_fixtures/*) sub=eval_error_fixtures ;;
      *)
        echo "not part of the snapshot corpus: $p" >&2
        echo "  (corpus: test/eval_error_fixtures)" >&2
        rc=1; continue ;;
    esac
    # Every section is # CRASH (diagnostic) — the runner will refuse this and say so.
    "$MEDAKA" snapshot --bless --root "$ROOT" --out "$SNAPDIR/$sub" "$p" || rc=1
  done
  exit "$rc"
fi

MODE="--check"
[ "${1:-}" = "--new" ] && MODE="--new"

# run_family <subdir> <stages> <glob...>
run_family() {
  sub="$1"; shift
  stages="$1"; shift
  mkdir -p "$SNAPDIR/$sub"
  out="$("$MEDAKA" snapshot "$MODE" --root "$ROOT" --out "$SNAPDIR/$sub" --stages "$stages" "$@" 2>&1)" || fail=1
  n="$(printf '%s\n' "$out" | sed -n 's/^snapshot: \([0-9]*\) fixtures.*/\1/p')"
  total=$((total + ${n:-0}))
  p="$(printf '%s\n' "$out" | sed -n 's/.*— \([0-9]*\) pass,.*/\1/p')"
  s="$(printf '%s\n' "$out" | sed -n 's/.*, \([0-9]*\) skipped,.*/\1/p')"
  compared=$((compared + ${p:-0}))
  skipped=$((skipped + ${s:-0}))
  printf '%-22s %s\n' "$sub" "$(printf '%s\n' "$out" | tail -1)"
  printf '%s\n' "$out" | grep -E '^(.*: (FAIL|ERROR))' | sed 's/^/    /'
}

# stages=eval: the eval path is what RUNS (and, for these, aborts) the fixture; the
# supervisor banks the abort into # CRASH.  no_main takes the static-diagnostic branch.
run_family eval_error_fixtures eval "$ROOT"/test/eval_error_fixtures/*.mdk

# ── THE SUMMARY MUST DESCRIBE WHAT IT ACTUALLY DID ───────────────────────────
printf '\n'
if [ "$fail" -ne 0 ]; then
  printf '%d fixtures — %d compared, %d skipped: SNAPSHOTS DIFFER\n' "$total" "$compared" "$skipped"
elif [ "$compared" -eq 0 ]; then
  printf '%d fixtures — %d compared, %d skipped: NOTHING COMPARED (this is not a pass)\n' \
    "$total" "$compared" "$skipped"
  [ "$MODE" != "--check" ] || exit 1
elif [ "$skipped" -ne 0 ]; then
  printf '%d fixtures — %d compared and matching, %d SKIPPED (not compared)\n' \
    "$total" "$compared" "$skipped"
else
  printf '%d fixtures, all %d compared and matching\n' "$total" "$compared"
fi
[ "$fail" -eq 0 ]
