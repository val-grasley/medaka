#!/bin/sh
# diff_compiler_snapshot_types_user.sh — PRELUDE-AWARE, user-only typecheck schemes for
# the real-program corpus, as a snapshot gate. docs/ops/TESTING-DESIGN.md §4.3; #81 (the
# prelude-aware # TYPES arc). Mirrors diff_compiler_snapshot_eval.sh.
#
# ── WHY A SEPARATE SECTION (# TYPES_USER, not # TYPES) ────────────────────────
# The existing `# TYPES` snapshot (diff_compiler_snapshot_types.sh) is prelude-FREE —
# correct for the minimal typecheck_fixtures, which test errors WITHOUT a prelude in
# scope. test/diff_fixtures/ are REAL programs that reference prelude types, so they must
# be typechecked with core.mdk in scope. The probe gates that USED to cover them
# (diff_compiler_typecheck_golden.sh + _batch.sh, RETIRED #81 Stage B1) diffed the
# FULL prelude+user scheme dump — ~120 lines/fixture, ~117 of them the SAME prelude table
# repeated across all 57 fixtures (6,810 lines, ~90% redundant). Snapshotting that
# verbatim is the anti-pattern the snapshot design rejects.
#
# So `# TYPES_USER` (snapshot.mdk `typesUserOf`) typechecks core.mdk ++ fixture but keeps
# ONLY the user program's own scheme lines (name-filtered by funNamesOf — see snapshot.mdk
# for why name-filtering beats full−baseline: context-sensitive prelude inference like
# `abs` leaks otherwise). The whole-prelude-inference invariant those probe gates also
# carried is NOT this gate's job — it moved (#81 Stage B1) to a single full-prelude dump,
# diff_compiler_snapshot_prelude.sh (a `# TYPES` snapshot of stdlib/core.mdk).
#
# Proven at introduction: every `# TYPES_USER` line appears verbatim in the frozen
# diff_fixtures/*.golden `=== TYPES ===` section — 57/57, zero prelude leakage — so the
# user schemes are byte-correct AND prelude-aware.
#
# ── SHARED CORPUS ────────────────────────────────────────────────────────────
# test/diff_fixtures/ is now read by this gate ALSO (also: the frontend snapshot gate's
# diff_fixtures family + the diff_compiler_check.sh / check_batch.sh probe gates, which
# read the frozen `=== TYPES ===`/`=== EVAL ===` goldens). Adding, moving, or deleting a
# fixture there enrolls/de-enrolls it here too.
#
# ── RE-CUTTING ───────────────────────────────────────────────────────────────
# match_nonexhaustive renders a diagnostic `# TYPES_USER` (a non-exhaustive-match
# warning), which is UNBLESSABLE by construction. To re-cut it, DELETE its .md and re-run
# with --new; the clean fixtures re-cut with --bless.
#
# Usage:  sh test/diff_compiler_snapshot_types_user.sh          # CHECK (the gate)
#         sh test/diff_compiler_snapshot_types_user.sh --new    # create MISSING snapshots
#         sh test/diff_compiler_snapshot_types_user.sh --bless <path>...
#
# Exit:   0 if every snapshot matches (or every named fixture blessed), else 1.
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
      "$ROOT"/test/diff_fixtures/*) sub=diff_fixtures_types ;;
      *)
        echo "not part of the snapshot corpus: $p" >&2
        echo "  (corpus: test/diff_fixtures)" >&2
        rc=1; continue ;;
    esac
    "$MEDAKA" snapshot --bless --root "$ROOT" --out "$SNAPDIR/$sub" --stages types_user "$p" || rc=1
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

run_family diff_fixtures_types types_user "$ROOT"/test/diff_fixtures/*.mdk

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
