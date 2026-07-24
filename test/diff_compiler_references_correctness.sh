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
CAPTURE="${CAPTURE:-0}"

[ -x "$SELF" ] || {
  echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one refindex_main (missing $SELF)"
  exit 2
}

rc=0

# Dump one fixture project (rooted at <dir>/main.mdk) and diff against
# <dir>/expected.golden, with the fixture's absolute path prefix stripped so the
# golden is machine-independent (`#` delimiter — the path contains `/`, never `#`).
check_project() {
  fixdir="$1"; what="$2"
  gold="$fixdir/expected.golden"
  [ -d "$fixdir" ] || { echo "missing fixture dir $fixdir"; rc=2; return; }
  out="$("$SELF" --dump "$RT" "$CORE" "$fixdir/main.mdk" "$fixdir" 2>&1 | sed "s#$fixdir/##g")"

  if [ "$CAPTURE" = 1 ]; then
    printf '%s\n' "$out" > "$gold"
    echo "captured $gold ($(printf '%s\n' "$out" | grep -c '') lines)"
    return
  fi

  [ -f "$gold" ] || {
    echo "no golden at $gold — capture it: CAPTURE=1 sh test/diff_compiler_references_correctness.sh"
    rc=2; return
  }

  if printf '%s\n' "$out" | diff -u "$gold" - > /dev/null 2>&1; then
    echo "PASS: $what dump matches golden."
    return
  fi

  echo "FAIL: reference-index dump DIFFERS from $gold"
  echo "  ($what — a binder DEF/USE Loc or BinderKey moved.)"
  printf '%s\n' "$out" | diff -u "$gold" - | head -60
  rc=1
}

# The original 4-module corpus: shadowing / alias / re-export / same-name / namespace.
check_project "$ROOT/test/references_fixtures/correctness" \
  "reference-index correctness (shadowing / alias / re-export / same-name / namespace)"

# #913 Inc 2: every param/local binder records its DEF at its OWN name-token Loc,
# not the enclosing declaration's loc (fn param `p` ≠ `incByOne`'s loc; the
# `let tmp` local sits at the let token, not `shadowLet`'s loc).
check_project "$ROOT/test/references_fixtures/binder_loc" \
  "reference-index binder-Loc (#913 Inc 2: each binder at its own name token)"

exit "$rc"
