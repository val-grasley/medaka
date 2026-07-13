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
# Usage:  sh test/diff_compiler_snapshot_frontend.sh          # CHECK (the gate)
#         sh test/diff_compiler_snapshot_frontend.sh --new    # create MISSING snapshots
#
# ⚠️ `--new` NEVER overwrites an existing snapshot: rewriting one from the current
# compiler IS blessing, and there is no `--bless` by design (a runner that silently
# re-blesses turns every regression green).  So to REGENERATE a snapshot you must delete
# it first:
#
#     rm test/snapshots/<sub>/<name>.md && sh test/diff_compiler_snapshot_frontend.sh --new
#
# This bites more often than it looks like it will, because the compiler's OWN 50 sources
# are in the corpus: ANY edit to compiler/**.mdk (even one `medaka fmt` reflows) changes
# that file's `# SOURCE` section and fails the gate until its snapshot is re-cut.  That is
# the correct behaviour — the snapshot is meant to notice — but a scoped `--bless` is the
# obvious next piece of tooling.
#
# Exit:   0 if every snapshot matches, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
SNAPDIR="$ROOT/test/snapshots"

[ -x "$MEDAKA" ] || { echo "build the compiler first: make medaka (missing $MEDAKA)"; exit 2; }

MODE="--check"
[ "${1:-}" = "--new" ] && MODE="--new"

fail=0
total=0

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
