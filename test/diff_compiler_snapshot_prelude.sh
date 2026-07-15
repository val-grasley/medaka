#!/bin/sh
# diff_compiler_snapshot_prelude.sh — the WHOLE-PRELUDE inference invariant, as ONE snapshot.
# docs/ops/TESTING-DESIGN.md §4.3; #81 (the prelude-aware # TYPES arc, Stage B).
# Mirrors diff_compiler_snapshot_eval.sh / diff_compiler_snapshot_types.sh.
#
# ── WHAT THIS PINS ────────────────────────────────────────────────────────────
# The prelude-FREE `# TYPES` stage (diff_compiler_snapshot_types.sh) typechecks a
# program with NO prelude in scope. Applied to stdlib/core.mdk — the file that IS the
# prelude — that is exactly `checkToLinesWithRuntime runtime [] core`: infer a scheme
# for every prelude binding, from the prelude alone. So a single `# TYPES` dump of
# stdlib/core.mdk is the whole prelude scheme table (~117 schemes: andThen, all, abs,
# map, pure, foldr, length, elem, …) as ONE self-consistent inference.
#
# ── WHY IT REPLACES THE PER-FIXTURE FULL DUMPS ───────────────────────────────
# The retired probe gates (diff_compiler_typecheck_golden.sh + _batch.sh, #81 Stage B1)
# diffed the FULL prelude+user scheme dump per diff_fixtures program — ~120 lines each,
# ~117 of them the SAME prelude table repeated across all 57 fixtures. That redundant
# whole-program dump split into two invariants:
#   * the USER program's own schemes, prelude-aware  -> # TYPES_USER (#312,
#     diff_compiler_snapshot_types_user.sh), one per fixture;
#   * the whole-prelude-inference invariant they ALSO carried -> THIS gate, ONE dump.
#
# NOT byte-identical to any per-fixture golden's baseline, and it must not be: a
# per-fixture full dump carries context-sensitive prelude schemes (e.g. `abs` resolved
# under that fixture's ambiguous-Num defaulting), whereas the core-alone dump is the
# prelude's SELF-consistent inference — the correct single invariant.
#
# ── SHARED CORPUS ────────────────────────────────────────────────────────────
# Reads stdlib/core.mdk. Any change to core.mdk that perturbs an inferred prelude scheme
# moves this snapshot — re-bless it in the same commit (that is the invariant firing).
#
# Usage:  sh test/diff_compiler_snapshot_prelude.sh              # CHECK (the gate)
#         sh test/diff_compiler_snapshot_prelude.sh --new        # create MISSING snapshot
#         sh test/diff_compiler_snapshot_prelude.sh --bless stdlib/core.mdk
#
# `--new` never overwrites (rewriting an existing snapshot IS blessing); re-cutting is
# `--bless`'s job and REQUIRES you to name the fixture. There is no whole-suite bless.
#
# Exit:   0 if the snapshot matches (or the named fixture blessed), else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# $MEDAKA honoured so the pre-commit hook drives the SAME gate rather than a second copy.
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
    echo "--bless requires an explicit fixture path — there is no whole-suite bless." >&2
    echo "  e.g.  sh test/diff_compiler_snapshot_prelude.sh --bless stdlib/core.mdk" >&2
    exit 1
  fi
  rc=0
  for p in "$@"; do
    [ "$p" = "--bless" ] && continue
    case "$p" in /*) ;; *) p="$(cd "$(dirname "$p")" 2>/dev/null && pwd)/$(basename "$p")" ;; esac
    [ -e "$p" ] || { echo "no such path: $p" >&2; rc=1; continue; }
    case "$p" in
      "$ROOT"/stdlib/core.mdk) sub=prelude ;;
      *)
        echo "not part of the snapshot corpus: $p" >&2
        echo "  (corpus: stdlib/core.mdk)" >&2
        rc=1; continue ;;
    esac
    "$MEDAKA" snapshot --bless --root "$ROOT" --out "$SNAPDIR/$sub" --stages types "$p" || rc=1
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

run_family prelude types "$ROOT"/stdlib/core.mdk

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
