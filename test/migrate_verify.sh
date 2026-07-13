#!/bin/sh
# migrate_verify.sh — the ACCEPTANCE TEST for the snapshot migration (TESTING-DESIGN.md
# §4.3).  For every fixture in the parse/desugar/mark family, prove that the section
# `medaka snapshot` renders is BYTE-IDENTICAL to the golden the old bash gate compared
# against.  This is the go/no-go: if it does not hold, the migration is wrong (or the
# old gate was hiding something) and NOTHING gets deleted.
#
#   sh test/migrate_verify.sh            # verify against the OLD goldens
#
# ── the one rule that makes this test mean anything ──────────────────────────
#
# The old gates each carried a copy of:
#
#     strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }
#
# — the native runtime auto-prints `main`'s Unit value, so every probe's stdout ended in
# a stray `()` that the gate sed'd off.  That transform is applied HERE to the OLD side
# ONLY.  The snapshot runner calls the stage as a FUNCTION and never spawns a probe, so
# its output has no `()` to strip.  Applying strip_unit to the new side too would
# "prove" the two agree modulo the very artifact being removed — a false green on the
# exact question this test exists to answer.  (In practice the goldens on disk are
# ALREADY stripped, so strip_unit is a no-op on them; it is applied anyway, because the
# claim being tested is "the new output equals what the OLD GATE compared against", and
# the old gate's expected value is `strip_unit`-shaped by construction.)
#
# The ONE other old-side fixup, and why it is not cheating: `test/capture_goldens.sh`
# wrote every golden through `printf '%s' "$(...)"`, and command substitution eats
# trailing newlines — so all 231 goldens in this family end WITHOUT a final newline
# (verified: 231 without, 0 with).  The old gate never noticed, because it compared
# `"$(cat golden)"` against `"$(probe | strip_unit)"` and `$( )` strips the newline off
# BOTH sides.  A snapshot section is a canonical block terminated by exactly one
# newline.  So the old side gets its final newline restored — a uniform, content-free
# re-termination of a value the old gate could not see either way.  The NEW side is
# never touched: it is compared as the raw bytes `medaka snapshot` wrote.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
AWKF="$ROOT/test/snap_section.awk"
SNAPDIR="${SNAPDIR:-$ROOT/test/snapshots}"

[ -x "$MEDAKA" ] || { echo "build the compiler first: make medaka (missing $MEDAKA)"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The old gate's own transform, verbatim from diff_compiler_{parse,desugar,mark}.sh.
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

# old-side only: strip_unit, then restore the final newline `$( )` ate at capture time.
# (`awk 1` re-terminates the last line and leaves an empty file empty — which is exactly
# the snapshot runner's `blockOf`: empty, or newline-terminated exactly once.)
old_side() { strip_unit < "$1" | awk 1; }

pass=0
fail=0
nogold=0
failed_list=""

# verify_one <fixture.mdk> <snapshot-dir> <SECTION> <golden-suffix>
verify_one() {
  fix="$1"; dir="$2"; sec="$3"; suf="$4"
  base="$(basename "${fix%.mdk}")"
  snap="$dir/$base.md"
  golden="${fix%.mdk}.$suf.golden"

  if [ ! -f "$golden" ]; then
    nogold=$((nogold + 1))
    printf 'NO-GOLDEN %s (%s)\n' "$fix" "$suf"
    return
  fi
  [ -f "$snap" ] || { fail=$((fail + 1)); failed_list="$failed_list$fix:$sec(no snapshot)\n"; printf 'FAIL %s %s — no snapshot %s\n' "$fix" "$sec" "$snap"; return; }

  awk -v want="$sec" -f "$AWKF" "$snap" > "$TMP/new"
  old_side "$golden" > "$TMP/old"

  if cmp -s "$TMP/old" "$TMP/new"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_list="$failed_list$fix:$sec\n"
    printf 'FAIL %s [%s] vs %s\n' "$fix" "$sec" "$golden"
    diff "$TMP/old" "$TMP/new" | head -12 | sed 's/^/    /'
  fi
}

# ── the family, corpus by corpus.  Each row is exactly the corpus + stage set the old
# gate drove; nothing is added and nothing is dropped. ────────────────────────────────

# 1. parse_fixtures — diff_compiler_{parse,desugar,mark}.sh all read it.
for f in "$ROOT"/test/parse_fixtures/*.mdk; do
  verify_one "$f" "$SNAPDIR/parse_fixtures" PARSE parse
  verify_one "$f" "$SNAPDIR/parse_fixtures" DESUGAR desugar
  verify_one "$f" "$SNAPDIR/parse_fixtures" MARK mark
done

# 2. parse_only_fixtures — PARSE only, by design (downstream stages do not handle it).
for f in "$ROOT"/test/parse_only_fixtures/*.mdk; do
  verify_one "$f" "$SNAPDIR/parse_only_fixtures" PARSE parse
done

# 3. the desugar/mark corpus — stdlib + diff_fixtures + the compiler's own sources.
for f in "$ROOT"/stdlib/*.mdk; do
  verify_one "$f" "$SNAPDIR/stdlib" DESUGAR desugar
  verify_one "$f" "$SNAPDIR/stdlib" MARK mark
done
for f in "$ROOT"/test/diff_fixtures/*.mdk; do
  verify_one "$f" "$SNAPDIR/diff_fixtures" DESUGAR desugar
  verify_one "$f" "$SNAPDIR/diff_fixtures" MARK mark
done
for f in "$ROOT"/compiler/frontend/*.mdk "$ROOT"/compiler/types/*.mdk \
         "$ROOT"/compiler/ir/*.mdk "$ROOT"/compiler/backend/*.mdk \
         "$ROOT"/compiler/eval/*.mdk "$ROOT"/compiler/driver/*.mdk \
         "$ROOT"/compiler/tools/*.mdk "$ROOT"/compiler/support/*.mdk; do
  verify_one "$f" "$SNAPDIR/compiler" DESUGAR desugar
  verify_one "$f" "$SNAPDIR/compiler" MARK mark
done

printf '\n── migrate_verify ────────────────────────────────\n'
printf '%d sections byte-identical to the old golden\n' "$pass"
printf '%d sections DIFFERING\n' "$fail"
printf '%d goldens missing (fixture had no old golden at all)\n' "$nogold"
if [ "$fail" -ne 0 ]; then
  printf '\ndiffering:\n'
  printf "$failed_list"
fi
[ "$fail" -eq 0 ] && [ "$nogold" -eq 0 ]
