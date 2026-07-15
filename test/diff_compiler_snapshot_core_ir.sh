#!/bin/sh
# diff_compiler_snapshot_core_ir.sh — the Core IR s-expr family, as ONE snapshot gate.
# docs/ops/TESTING-DESIGN.md §4.3.  Sibling of diff_compiler_snapshot_frontend.sh.
#
# REPLACES one bash gate and the frozen `.sexp` corpus it read:
#
#   diff_compiler_core_ir_sexp.sh           test/core_ir_sexp_fixtures/*.sexp     (23)
#
# Each fixture's `# CORE_IR` section (the Core IR s-expr dump the old
# core_ir_dump_main probe produced) is now ONE `.md` under test/snapshots/eval_fixtures/,
# byte-identical to the `.sexp` golden it replaces after the native trailing-`()` strip
# (surveyed 23/23, #81).  The corpus test/eval_fixtures/*.mdk is SHARED (KEPT); only the
# gate-only .sexp goldens retire with the gate.
#
# NOT migrated (out of scope — a different mechanism, NOT the static sexp dump):
# core_ir / core_ir_typed / core_ir_list / core_ir_prelude assert on Core-IR INTERPRETER
# output (cevalOutput), and core_ir_dump_main's oracle survives only as documented lineage
# (snapshot.mdk cites it as what the CORE_IR render reproduces); this gate touches only
# the one clean sexp-dump gate.
#
# Usage:  sh test/diff_compiler_snapshot_core_ir.sh              # CHECK (the gate)
#         sh test/diff_compiler_snapshot_core_ir.sh --new        # create MISSING snapshots
#         sh test/diff_compiler_snapshot_core_ir.sh --bless <path>...
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
    echo "  e.g.  sh test/diff_compiler_snapshot_core_ir.sh --bless test/eval_fixtures/adts.mdk" >&2
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
      "$ROOT"/test/eval_fixtures/*)       sub=eval_fixtures ;;
      *)
        echo "not part of the snapshot corpus: $p" >&2
        echo "  (corpus: test/eval_fixtures)" >&2
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

run_family eval_fixtures       core_ir "$ROOT"/test/eval_fixtures/*.mdk

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
