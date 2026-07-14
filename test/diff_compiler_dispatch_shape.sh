#!/bin/sh
# diff_compiler_dispatch_shape.sh — the SHAPE gate for typeclass dispatch (issue #118).
#
# ⚠️ WHY THIS EXISTS.  Every other gate in the tree is a BEHAVIOUR gate: it runs a
# program and compares its output.  Dispatch codegen has a property that no behaviour
# gate can see, because both shapes compute the same answer:
#
#     the impl if-chain must be OUTLINED — emitted ONCE per method, in a shared
#     `@mdk_disp_<method>_<nMeth>_<nArgs>` define — NOT inlined at every dispatch site.
#
# Inlining it at each site is perfectly correct and 100% green on all 83 gates.  It is
# also what made emitted IR grow as `Σ over sites of (#impls of that site's method)`:
# on the 9-line fixture below there are ~107 dispatch sites but only ~9 distinct chains
# between them, so the duplicated arms were ~80% of the module's 32,896 lines.  Fixing
# that (2026-07-14) cut the fixture's IR by 64%, its build by 28% and its binary by 47%.
#
# Nothing pinned it.  A future emitter change that mints a dispatcher PER SITE (thread
# anything site-derived into `dispFnName`), or re-inlines the chain, or adds a third
# emit entry point that forgets to reset `dispCacheRef`, would hand all of that back —
# silently, with every behaviour gate green.  This gate is the only thing that notices.
#
# THREE ASSERTIONS, each derived from the emitted IR — no golden, nothing to bless:
#
#   A. OUTLINED.  Zero dispatch-chain arms (`dispyes*` / `ddispyes*` labels) appear
#      outside a `@mdk_disp_*` define.  Catches re-inlining the chain at the site.
#
#   B. SHARED, i.e. O(methods) not O(sites).  Dispatcher CALL sites must outnumber
#      dispatcher DEFINES several-fold.  Per-site minting drives that ratio to exactly
#      1.0; the healthy fixture sits near 12.  The floor is 4 — well clear of noise,
#      and any change that pushes it under 4 has broken the sharing.
#
#   C. PROGRAM-INDEPENDENT PRELUDE — the property #118 actually needs, stated as a test.
#      Compile TWO different programs.  Of the defines they have in common, the ONLY
#      bodies allowed to differ are the `@mdk_disp_*` dispatchers themselves (which are
#      per-program by construction) and `mdk_program_main`.  In particular NO
#      `@mdk_impl_*` body may differ: before outlining, `mdk_impl_List_eq` embedded the
#      whole program's impl set and so changed every time a user declared a type (23
#      defines differed).  Now it does not (4 differ, all of them allowed).  That is the
#      precondition for shipping a reusable `prelude.o` — and the thing that will rot
#      first and most silently.
#
# The two probe programs are written into a temp dir, NOT into a fixture corpus: a
# fixture directory is a shared corpus and adding to one silently enrols you in gates
# you never named (AGENTS.md).  This gate owns its inputs.
#
# Usage:  sh test/diff_compiler_dispatch_shape.sh
# Exit:   0 all three assertions hold
#         1 an assertion failed (the shape regressed)
#         2 native medaka/emitter not built (opt-in skip, same as the other LLVM gates)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }

export MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdk-dispshape.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

# ── the two probes ───────────────────────────────────────────────────────────
# P1 and P2 differ ONLY in how many `deriving (Eq, Ord, Debug)` types they declare.
# Each extra type adds one arm to every Eq/Ord/Debug chain in the program — so under
# the OLD inline-chain codegen every prelude define that dispatched (mdk_impl_List_eq,
# mdk_impl___tuple2___compare, …) had a DIFFERENT body in P1 than in P2.  That is
# exactly what assertion C forbids.
cat > "$WORK/p1.mdk" <<'MDK'
data Color = Red | Green | Blue deriving (Eq, Ord, Debug)

main =
  let xs = [1, 2, 3]
  let ys = [1, 2, 3]
  println (xs == ys)
MDK

{
  printf 'data Color = Red | Green | Blue deriving (Eq, Ord, Debug)\n'
  i=1
  while [ "$i" -le 12 ]; do
    printf 'data D%s = A%s | B%s deriving (Eq, Ord, Debug)\n' "$i" "$i" "$i"
    i=$((i + 1))
  done
  printf '\nmain =\n  let xs = [1, 2, 3]\n  let ys = [1, 2, 3]\n  println (xs == ys)\n'
} > "$WORK/p2.mdk"

for p in p1 p2; do
  if ! "$MEDAKA" build --keep-ir "$WORK/$p.mdk" -o "$WORK/$p" > "$WORK/$p.build.log" 2>&1; then
    echo "FAIL: could not build the $p probe:"; cat "$WORK/$p.build.log"; exit 1
  fi
  [ -s "$WORK/$p.ll" ] || { echo "FAIL: no IR kept for $p (expected $WORK/$p.ll)"; exit 1; }
done

fails=0

# ── A. the chain is OUTLINED ─────────────────────────────────────────────────
# Walk the IR tracking the enclosing define; any dispatch arm outside @mdk_disp_* is
# an inlined chain.
stray="$(awk '
  /^define /        { cur = ""; if (match($0, /@mdk_disp_[A-Za-z0-9_]+/)) cur = "disp"; next }
  /^d?dispyes[0-9]+:/ { if (cur != "disp") n++ }
  END               { print n + 0 }
' "$WORK/p2.ll")"

if [ "$stray" -ne 0 ]; then
  echo "FAIL [A outlined]: $stray dispatch-chain arm(s) emitted OUTSIDE a @mdk_disp_* define."
  echo "  The impl if-chain has been re-inlined at the dispatch site. That is correct but"
  echo "  it re-introduces the O(sites x impls) IR blow-up issue #118 removed."
  fails=$((fails + 1))
else
  echo "PASS [A outlined]  no dispatch arm outside a @mdk_disp_* define"
fi

# ── B. dispatchers are SHARED (O(methods), not O(sites)) ─────────────────────
defs="$(grep -c '^define .*@mdk_disp_' "$WORK/p2.ll" || true)"
calls="$(grep -c 'call i64 @mdk_disp_' "$WORK/p2.ll" || true)"

if [ "$defs" -eq 0 ]; then
  echo "FAIL [B shared]: no @mdk_disp_* dispatcher defines at all."
  if [ "$stray" -ne 0 ]; then
    echo "  (A also failed: the chain is being inlined at the site again, so no dispatcher"
    echo "   is ever minted. Fix A — B is a consequence.)"
  else
    echo "  No dispatch chain anywhere: the probe has stopped exercising runtime-dict"
    echo "  dispatch, so this gate is checking NOTHING. Fix the probe, do not delete this."
  fi
  fails=$((fails + 1))
elif [ "$((calls))" -lt "$((defs * 4))" ]; then
  echo "FAIL [B shared]: $calls call sites for $defs dispatcher defines (ratio < 4x)."
  echo "  Dispatchers are no longer SHARED across sites — a per-site dispatcher (ratio 1.0)"
  echo "  costs the same IR as the inline chain it replaced. Check dispFnName for a"
  echo "  site-derived component, and that every emit entry point resets dispCacheRef."
  fails=$((fails + 1))
else
  echo "PASS [B shared]    $calls call sites share $defs dispatcher defines ($((calls / defs))x)"
fi

# ── C. prelude defines are PROGRAM-INDEPENDENT ───────────────────────────────
# Explode each module into one file per define, then byte-compare the two programs'
# common defines. (Files + `cmp` rather than a hash: `md5sum` is GNU-only and this
# tree must run on macOS too — AGENTS.md's dual-platform invariant.)
explode() {
  mkdir -p "$2"
  awk -v out="$2" '
    /^define / {
      if (match($0, /@[A-Za-z0-9_.$]+/)) name = substr($0, RSTART + 1, RLENGTH - 1)
      f = out "/" name; print $0 > f; inside = 1; next
    }
    inside {
      print $0 > f
      if ($0 == "}") { close(f); inside = 0 }
    }
  ' "$1"
}

explode "$WORK/p1.ll" "$WORK/d1"
explode "$WORK/p2.ll" "$WORK/d2"

: > "$WORK/differ"
for f in "$WORK/d1"/*; do
  nm="$(basename "$f")"
  [ -f "$WORK/d2/$nm" ] || continue          # not common to both programs — not our business
  cmp -s "$f" "$WORK/d2/$nm" || echo "$nm" >> "$WORK/differ"
done

# the only bodies allowed to differ between two different programs
bad="$(grep -v -e '^mdk_disp_' -e '^mdk_program_main$' "$WORK/differ" || true)"
nbad="$(printf '%s\n' "$bad" | grep -c . || true)"
ndiff="$(grep -c . "$WORK/differ" || true)"

if [ "$nbad" -ne 0 ]; then
  echo "FAIL [C program-independent]: $nbad define(s) common to BOTH programs have"
  echo "  DIFFERENT bodies, and are not dispatchers:"
  printf '%s\n' "$bad" | sed 's/^/      /'
  echo "  A prelude define's body must not depend on what the USER program declares."
  echo "  It does again — so the impl set is leaking back into prelude bodies, and a"
  echo "  reusable prelude.o (issue #118) is off the table. This is the invariant that"
  echo "  the -64% IR win is made of."
  fails=$((fails + 1))
else
  echo "PASS [C program-independent]  of the defines common to both programs, only $ndiff differ,"
  echo "                              all of them @mdk_disp_*/mdk_program_main (allowed)"
fi

echo
if [ "$fails" -ne 0 ]; then
  echo "DISPATCH SHAPE: $fails assertion(s) FAILED"
  exit 1
fi
echo "DISPATCH SHAPE: all 3 assertions hold (outlined / shared / program-independent)"
exit 0
