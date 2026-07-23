#!/bin/sh
# test/diff_compiler_references_correctness.sh — the CORRECTNESS gate for the
# cross-file reference index (compiler/tools/refindex.mdk, #254 Stage 0).
#
# WHAT IT PROVES (the "match binders, not strings" property, permanently)
# ----------------------------------------------------------------------
# Runs refindex_main --dump over the 4-module correctness project
# (test/references_fixtures/correctness/) and diffs the per-BinderKey dump
# against a captured golden. The fixture is built so ONE dump exercises every
# resolution hazard at once:
#
#   * shadowing              — a LOCAL `g` in main.topG gets a distinct `local`
#                              key; the imported top-level `g` keeps its own uses.
#   * member alias `helper as hh`, module alias `D.helper`, AND the re-export
#     chain `import reexport.{helper}` — all three spellings collapse to the ONE
#     origin key `defs<TAB>val<TAB>helper`.
#   * same name, two modules — `defs.shared` and `other.shared` are distinct keys.
#   * namespace clash        — `Color` (type) vs `Red` (ctor) are distinct keys.
#
# A regression that keyed by spelling (or lost import-origin threading) would
# merge or split these keys and MOVE this golden — that is the whole point.
#
# The dump prints absolute file uris, so paths are normalized to the fixture-
# relative basename before diffing, keeping the golden machine/worktree-stable.
#
# Usage: sh test/diff_compiler_references_correctness.sh
#   CAPTURE=1 sh test/diff_compiler_references_correctness.sh   — re-mint the golden
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/test/bin/refindex_main"
RT="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/references_fixtures/correctness"
GOLD="$FIXDIR/expected.golden"
CAPTURE="${CAPTURE:-0}"

[ -x "$SELF" ] || {
  echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one refindex_main (missing $SELF)"
  exit 2
}
[ -d "$FIXDIR" ] || { echo "missing fixture dir $FIXDIR"; exit 2; }

# Native dump, with the fixture's absolute path prefix stripped so the golden is
# machine-independent (`#` delimiter — the path contains `/`, never `#`).
out="$("$SELF" --dump "$RT" "$CORE" "$FIXDIR/main.mdk" "$FIXDIR" 2>&1 | sed "s#$FIXDIR/##g")"

if [ "$CAPTURE" = 1 ]; then
  printf '%s\n' "$out" > "$GOLD"
  echo "captured $GOLD ($(printf '%s\n' "$out" | grep -c '') lines)"
  exit 0
fi

[ -f "$GOLD" ] || {
  echo "no golden at $GOLD — capture it: CAPTURE=1 sh test/diff_compiler_references_correctness.sh"
  exit 2
}

if printf '%s\n' "$out" | diff -u "$GOLD" - > /dev/null 2>&1; then
  echo "PASS: reference-index correctness dump matches golden (shadowing / alias / re-export / same-name / namespace)."
  exit 0
fi

echo "FAIL: reference-index dump DIFFERS from $GOLD"
echo "  (a BinderKey moved — shadowing/alias/re-export/same-name/namespace resolution changed.)"
printf '%s\n' "$out" | diff -u "$GOLD" - | head -60
exit 1
