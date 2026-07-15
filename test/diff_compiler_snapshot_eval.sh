#!/bin/sh
# diff_compiler_snapshot_eval.sh — the self-hosted EVAL families, as ONE snapshot gate.
# docs/ops/TESTING-DESIGN.md §4.3; mirrors diff_compiler_snapshot_frontend.sh (#81 R6).
#
# REPLACES two bash gates and the per-fixture .eval.golden compare they drove:
#
#   diff_compiler_eval_dict.sh    test/bin/eval_dict_main    eval_dict_fixtures  (26)
#   diff_compiler_eval_typed.sh   test/bin/eval_typed_main   eval_typed_fixtures (4)
#
# Both fixture corpora were surveyed byte-identical between the snapshot `# EVAL`
# section (produced in-process by `medaka snapshot --stages eval`) and the committed
# `.eval.golden` the deleted gates diffed against — 26/26 and 4/4 (#81 R6). The
# snapshot runner calls the elaborate+eval pipeline as a FUNCTION, in-process, so the
# per-file process spawn the old gate paid is gone.
#
# ── WHAT IS AND IS NOT DELETED ───────────────────────────────────────────────
# Only the two MAIN gate SCRIPTS are removed. The `.eval.golden` files, the fixtures,
# and the eval_dict_main / eval_typed_main probes all SURVIVE, because they are SHARED:
#
#   * diff_compiler_eval_dict_batch.sh / diff_compiler_eval_typed_batch.sh — the
#     out-of-scope BATCH gates — read the SAME `<name>.eval.golden` files and the SAME
#     fixture dirs. Deleting the goldens would break them.
#   * fuzz_diff.sh drives test/bin/eval_dict_main as its differential oracle.
#   * capture_goldens.sh regenerates those goldens (for the surviving batch gates).
#
# So this gate is an ADDITIONAL, in-process check over the same corpus, and the deletion
# is narrow by necessity. See #81 R6 for the full manifest.
#
# Usage:  sh test/diff_compiler_snapshot_eval.sh              # CHECK (the gate)
#         sh test/diff_compiler_snapshot_eval.sh --new        # create MISSING snapshots
#         sh test/diff_compiler_snapshot_eval.sh --bless <path>...
#                                                             # re-cut the NAMED ones
#
# `--new` never overwrites (rewriting an existing snapshot from the current compiler IS
# blessing), so re-cutting is `--bless`'s job — and `--bless` REQUIRES you to name what
# you are approving. There is no whole-suite bless. Blessing takes FIXTURE paths (`.mdk`),
# not snapshot `.md` paths: --out flattens source roots into snapshot dirs by basename,
# so `.md` -> fixture is not invertible. This script owns that map (the `bless_one` case
# below) — it is the same table as the `run_family` calls, and if you add a family you
# must add it in both places.
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
    echo "  e.g.  sh test/diff_compiler_snapshot_eval.sh --bless test/eval_dict_fixtures/adt_deriving_ord.mdk" >&2
    exit 1
  fi
  rc=0
  for p in "$@"; do
    [ "$p" = "--bless" ] && continue
    case "$p" in /*) ;; *) p="$(cd "$(dirname "$p")" 2>/dev/null && pwd)/$(basename "$p")" ;; esac
    [ -e "$p" ] || { echo "no such path: $p" >&2; rc=1; continue; }
    # Which family owns it?  Same table as the run_family calls at the bottom.
    case "$p" in
      "$ROOT"/test/eval_dict_fixtures/*)  sub=eval_dict_fixtures ;;
      "$ROOT"/test/eval_typed_fixtures/*) sub=eval_typed_fixtures ;;
      *)
        echo "not part of the snapshot corpus: $p" >&2
        echo "  (corpus: test/eval_dict_fixtures, test/eval_typed_fixtures)" >&2
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
  p="$(printf '%s\n' "$out" | sed -n 's/.*— \([0-9]*\) pass,.*/\1/p')"
  s="$(printf '%s\n' "$out" | sed -n 's/.*, \([0-9]*\) skipped,.*/\1/p')"
  compared=$((compared + ${p:-0}))
  skipped=$((skipped + ${s:-0}))
  printf '%-22s %s\n' "$sub" "$(printf '%s\n' "$out" | tail -1)"
  printf '%s\n' "$out" | grep -E '^(.*: (FAIL|ERROR))' | sed 's/^/    /'
}

run_family eval_dict_fixtures  eval "$ROOT"/test/eval_dict_fixtures/*.mdk
run_family eval_typed_fixtures eval "$ROOT"/test/eval_typed_fixtures/*.mdk

# ── THE SUMMARY MUST DESCRIBE WHAT IT ACTUALLY DID ───────────────────────────
# It reports COMPARED, and never says "match" about a fixture it skipped. (--new skips
# every fixture that already has a snapshot, by design — so 0-compared is not a pass.)
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
