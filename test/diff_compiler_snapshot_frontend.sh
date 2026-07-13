#!/bin/sh
# diff_compiler_snapshot_frontend.sh — the front-end (parse / desugar / mark) family, as
# ONE snapshot gate.  TESTING-DESIGN.md §4.3.
#
# REPLACES five bash gates and everything they needed to exist:
#
#   diff_compiler_parse.sh          compiler/entries/parse_main.mdk    test/bin/parse_main
#   diff_compiler_desugar.sh        compiler/entries/desugar_main.mdk  test/bin/desugar_main
#   diff_compiler_desugar_batch.sh  compiler/entries/desugar_batch.mdk test/bin/desugar_batch
#   diff_compiler_mark.sh           compiler/entries/mark_main.mdk     test/bin/mark_main
#   diff_compiler_mark_batch.sh     compiler/entries/mark_batch.mdk    test/bin/mark_batch
#   bootstrap_parse.sh / bootstrap_desugar.sh / bootstrap_mark.sh  (see below)
#
# ...and it replaces the 368 `.{parse,desugar,mark,boot_parse,boot_desugar,boot_mark}
# .golden` files scattered across five directories with ONE `.md` per fixture.
#
# The `_batch` gates vanish with ZERO replacement: they existed ONLY to amortize process
# spawn (`medaka run desugar_main.mdk <f>` once per file re-loaded every module).  The
# snapshot runner calls the stages as FUNCTIONS, in-process, so "batch" is not a thing
# that can exist here.
#
# The three `bootstrap_*` gates went too, and they were pure duplication: since the OCaml
# reference was deleted (2026-06-26) they ran the SAME binary (test/bin/parse_main) over
# the SAME corpus against `.boot_parse.golden` — and all 96 boot_* goldens are BYTE-
# IDENTICAL to their `.{parse,desugar,mark}.golden` twins (verified), because
# capture_goldens.sh regenerates both from the same probe.  Two gates, one signal.
#
# ── the corpus, and why `--stages` differs per row ───────────────────────────
# Each row below is exactly the corpus + stage set the gate it replaces drove:
#
#   parse_fixtures       parse,desugar,mark   (all three old gates read it)
#   parse_only_fixtures  parse                (deliberately excluded from desugar/mark —
#                                              constructs the parser accepts but the
#                                              downstream stages do not handle yet)
#   stdlib               desugar,mark         (no .parse.golden ever existed for these)
#   diff_fixtures        desugar,mark
#   compiler             desugar,mark         — the compiler's own 50 sources
#
# Nothing is added and nothing is dropped.  Snapshotting the compiler's sources with the
# FULL stage set would be actively harmful, not merely slow: single-file, with no import
# resolution and no core prelude, `# TYPES` is a wall of bogus `Unbound variable` errors
# and `# CORE_IR` is a 180 KB single line.  `stages=` in each `# META` records the choice.
#
# Usage:  sh test/diff_compiler_snapshot_frontend.sh              # CHECK (the gate)
#         sh test/diff_compiler_snapshot_frontend.sh --new        # create MISSING snapshots
#         sh test/diff_compiler_snapshot_frontend.sh --bless <path>...
#                                                                 # re-cut the NAMED ones
#
# `--new` never overwrites (rewriting an existing snapshot from the current compiler IS
# blessing), so re-cutting is `--bless`'s job — and `--bless` REQUIRES you to name what
# you are approving.  There is no whole-suite bless here and there will not be one:
#
#     sh test/diff_compiler_snapshot_frontend.sh --bless compiler/frontend/lexer.mdk
#     sh test/diff_compiler_snapshot_frontend.sh --bless compiler/frontend   # a dir, fine
#     sh test/diff_compiler_snapshot_frontend.sh --bless                     # REFUSED
#
# `--bless` also refuses, per-fixture, to rewrite a section carrying compiler diagnostic
# prose (a `# PARSE` holding a parse error, a `# TYPES` holding a TYPE ERROR or a match
# warning, a `# CRASH`).  Those are graded against compiler/ERROR-QUALITY.md and must be
# READ, not rubber-stamped; to re-cut one you must `rm` the `.md` and `--new` it, which
# lands in review as a delete+add.  See compiler/tools/snapshot.mdk's header for the
# three locks and why each one is there.
#
# WHY BLESS EXISTS AT ALL: the compiler's OWN 50 sources are in this corpus, so ANY edit
# to compiler/**.mdk — including a pure `medaka fmt` reflow — changes that file's
# `# SOURCE` section and fails this gate.  Before `--bless`, the only way out was
# `rm` + `--new`, on every compiler PR.  The review gate is not the absence of a bless
# button; it is `git diff` on the snapshot dir, which every CI shard ends with.
#
# Blessing takes FIXTURE paths (`.mdk`), not snapshot `.md` paths: --out flattens five
# source roots into snapshot dirs by basename, so `.md` -> fixture is not invertible.
# This script owns that map (the `bless_one` case below) — it is the same table as the
# `run_family` calls, and if you add a family you must add it in both places.
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

# ── --bless <path>... ─────────────────────────────────────────────────────────
# Scoped, and scoped LOUDLY: a bless naming nothing is an error, not a no-op that
# quietly blesses the world.
if [ "${1:-}" = "--bless" ]; then
  shift
  if [ "$#" -eq 0 ]; then
    echo "--bless requires explicit fixture paths — there is no whole-suite bless." >&2
    echo "  e.g.  sh test/diff_compiler_snapshot_frontend.sh --bless compiler/frontend/lexer.mdk" >&2
    exit 1
  fi
  rc=0
  for p in "$@"; do
    case "$p" in /*) ;; *) p="$(cd "$(dirname "$p")" 2>/dev/null && pwd)/$(basename "$p")" ;; esac
    [ -e "$p" ] || { echo "no such path: $p" >&2; rc=1; continue; }
    # Which family owns it?  Same table as the run_family calls at the bottom.
    # `--stages` is deliberately NOT passed: an existing snapshot names its own stage set
    # in `# META`, and a bless must re-cut the stages the file already has — never widen
    # them behind the author's back.
    case "$p" in
      "$ROOT"/test/parse_only_fixtures/*) sub=parse_only_fixtures ;;
      "$ROOT"/test/parse_fixtures/*)      sub=parse_fixtures ;;
      "$ROOT"/test/diff_fixtures/*)       sub=diff_fixtures ;;
      "$ROOT"/stdlib/*|"$ROOT"/stdlib)    sub=stdlib ;;
      "$ROOT"/compiler/*|"$ROOT"/compiler) sub=compiler ;;
      *)
        echo "not part of the snapshot corpus: $p" >&2
        echo "  (corpus: test/parse_fixtures, test/parse_only_fixtures, test/diff_fixtures, stdlib, compiler)" >&2
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
  printf '%-22s %s\n' "$sub" "$(printf '%s\n' "$out" | tail -1)"
  printf '%s\n' "$out" | grep -E '^(.*: (FAIL|ERROR))' | sed 's/^/    /'
}

run_family parse_fixtures      parse,desugar,mark "$ROOT"/test/parse_fixtures/*.mdk
run_family parse_only_fixtures parse              "$ROOT"/test/parse_only_fixtures/*.mdk
run_family stdlib              desugar,mark       "$ROOT"/stdlib/*.mdk
run_family diff_fixtures       desugar,mark       "$ROOT"/test/diff_fixtures/*.mdk
run_family compiler            desugar,mark \
  "$ROOT"/compiler/frontend/*.mdk "$ROOT"/compiler/types/*.mdk \
  "$ROOT"/compiler/ir/*.mdk "$ROOT"/compiler/backend/*.mdk \
  "$ROOT"/compiler/eval/*.mdk "$ROOT"/compiler/driver/*.mdk \
  "$ROOT"/compiler/tools/*.mdk "$ROOT"/compiler/support/*.mdk

printf '\n%d fixtures, %s\n' "$total" "$([ "$fail" -eq 0 ] && echo 'all snapshots match' || echo 'SNAPSHOTS DIFFER')"
[ "$fail" -eq 0 ]
