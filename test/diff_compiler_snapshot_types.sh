#!/bin/sh
# diff_compiler_snapshot_types.sh — the TYPECHECK families, as ONE snapshot gate.
# docs/ops/TESTING-DESIGN.md §4.3.  Sibling of diff_compiler_snapshot_frontend.sh.
#
# REPLACES two bash gates and the frozen `.tc.golden` corpora they read:
#
#   diff_compiler_typecheck.sh              test/typecheck_fixtures/*.tc.golden        (14)
#   diff_compiler_typecheck_panic_errors.sh test/typecheck_panic_fixtures/*.tc.golden  (7)
#
# Each fixture's `# TYPES` section (the types stage run single-file, no resolve, no
# prelude — the SAME `check_program_no_prelude → pp_scheme per binding` render the old
# `dev/tc_probe.exe` oracle produced) is now ONE `.md` under test/snapshots/, byte-
# identical to the sorted `.tc.golden` it replaces after the native trailing-`()` strip
# (surveyed 14/14 + 7/7, #81 R5).  The old gates SORTED both sides to bridge a stale
# OCaml golden; the snapshot renders in declaration order and the goldens already agree
# with that order, so no sort is needed here — the snapshot pins the stream MORE tightly.
#
# The `typecheck_panic_fixtures` `# TYPES` sections hold `TYPE ERROR: …` prose (the D1
# audit finding: shapes resolve pre-screens, so on the no-resolve differential path the
# typecheck stage IS the one that reaches the error, and accumulates it rather than
# panicking).  snapshot.mdk's bless-lock therefore REFUSES to rewrite them — to re-cut
# one you `rm` the `.md` and `--new` it, landing in review as a delete+add.  Under
# `--check` (the gate) the section is compared normally.
#
# NOT migrated here (deliberately out of scope — partial/divergent, not byte-identical):
# diff_compiler_typecheck_errors.sh / _golden / check_match, and the typecheck_main
# oracle probe they still drive.  This gate touches only the two clean families.
#
# Usage:  sh test/diff_compiler_snapshot_types.sh              # CHECK (the gate)
#         sh test/diff_compiler_snapshot_types.sh --new        # create MISSING snapshots
#         sh test/diff_compiler_snapshot_types.sh --bless <path>...
#                                                              # re-cut the NAMED ones
#
# `--bless` takes FIXTURE paths (`.mdk`), not snapshot `.md` paths, and REQUIRES you to
# name what you are approving — there is no whole-suite bless.  See the frontend gate's
# header and compiler/tools/snapshot.mdk for the three locks and why each is there.
#
# Exit:   0 if every snapshot matches (or every named fixture blessed), else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# $MEDAKA honoured so the pre-commit hook (which resolves the binary itself, falling back
# to PATH) drives the SAME gate rather than a second copy of the family table.
MEDAKA="${MEDAKA:-$ROOT/medaka}"
SNAPDIR="$ROOT/test/snapshots"

[ -x "$MEDAKA" ] || { echo "build the compiler first: make medaka (missing $MEDAKA)"; exit 2; }

fail=0
total=0
compared=0
skipped=0

# ── --bless <path>... ─────────────────────────────────────────────────────────
# Scoped, and scoped LOUDLY: a bless naming nothing is an error, not a no-op that
# quietly blesses the world.
if [ "${1:-}" = "--bless" ]; then
  shift
  if [ "$#" -eq 0 ]; then
    echo "--bless requires explicit fixture paths — there is no whole-suite bless." >&2
    echo "  e.g.  sh test/diff_compiler_snapshot_types.sh --bless test/typecheck_fixtures/adts.mdk" >&2
    exit 1
  fi
  rc=0
  for p in "$@"; do
    # Tolerate repeated flags: `--bless A --bless B` is a natural spelling, and
    # without this the second literal `--bless` is resolved as a PATH (cwd-relative)
    # and reported "not part of the snapshot corpus" — a confusing half-success.
    [ "$p" = "--bless" ] && continue
    case "$p" in /*) ;; *) p="$(cd "$(dirname "$p")" 2>/dev/null && pwd)/$(basename "$p")" ;; esac
    [ -e "$p" ] || { echo "no such path: $p" >&2; rc=1; continue; }
    # Which family owns it?  Same table as the run_family calls at the bottom.
    # `--stages` is deliberately NOT passed: an existing snapshot names its own stage set
    # in `# META`, and a bless must re-cut the stages the file already has.
    case "$p" in
      "$ROOT"/test/typecheck_fixtures/*)       sub=typecheck_fixtures ;;
      "$ROOT"/test/typecheck_panic_fixtures/*) sub=typecheck_panic_fixtures ;;
      *)
        echo "not part of the snapshot corpus: $p" >&2
        echo "  (corpus: test/typecheck_fixtures, test/typecheck_panic_fixtures)" >&2
        rc=1; continue ;;
    esac
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
  # Count what was actually COMPARED (pass) vs merely walked past (skipped). The summary
  # below MUST NOT claim a match on the strength of fixtures it never opened.
  p="$(printf '%s\n' "$out" | sed -n 's/.*— \([0-9]*\) pass,.*/\1/p')"
  s="$(printf '%s\n' "$out" | sed -n 's/.*, \([0-9]*\) skipped,.*/\1/p')"
  compared=$((compared + ${p:-0}))
  skipped=$((skipped + ${s:-0}))
  printf '%-26s %s\n' "$sub" "$(printf '%s\n' "$out" | tail -1)"
  printf '%s\n' "$out" | grep -E '^(.*: (FAIL|ERROR))' | sed 's/^/    /'
}

run_family typecheck_fixtures       types "$ROOT"/test/typecheck_fixtures/*.mdk
run_family typecheck_panic_fixtures types "$ROOT"/test/typecheck_panic_fixtures/*.mdk

# ── THE SUMMARY MUST DESCRIBE WHAT IT ACTUALLY DID ───────────────────────────
# "compared" is pass count, never total: under --new (which skips fixtures that already
# have a snapshot) a fail==0 that compared NOTHING is not a pass.  See the frontend
# gate's header for the incident that made this the reporting contract.
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
