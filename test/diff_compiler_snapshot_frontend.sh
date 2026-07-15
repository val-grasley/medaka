#!/bin/sh
# diff_compiler_snapshot_frontend.sh — the front-end (parse / desugar / mark) family, as
# ONE snapshot gate.  docs/ops/TESTING-DESIGN.md §4.3.
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
#   diff_fixtures        tokens,desugar,mark  (TOKENS absorbs diff_compiler_lexer.sh — the
#                                              # TOKENS render is byte-identical to the
#                                              lex_main probe, proven 57/57 over this
#                                              corpus; #81 R4.  It pins the native token
#                                              stream MORE tightly than the old gate,
#                                              which norm'd FLOAT away to bridge a stale
#                                              OCaml golden — the snapshot keeps FLOAT 1.0.)
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
compared=0
skipped=0

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
    # Tolerate repeated flags: `--bless A --bless B` is a natural spelling, and
    # without this the second literal `--bless` is resolved as a PATH (cwd-relative)
    # and reported "not part of the snapshot corpus" — a confusing half-success.
    [ "$p" = "--bless" ] && continue
    case "$p" in /*) ;; *) p="$(cd "$(dirname "$p")" 2>/dev/null && pwd)/$(basename "$p")" ;; esac
    [ -e "$p" ] || { echo "no such path: $p" >&2; rc=1; continue; }
    # Which family owns it?  Same table as the run_family calls at the bottom.
    # `--stages` is deliberately NOT passed: an existing snapshot names its own stage set
    # in `# META`, and a bless must re-cut the stages the file already has — never widen
    # them behind the author's back.
    case "$p" in
      "$ROOT"/test/parse_only_fixtures/*) sub=parse_only_fixtures ;;
      "$ROOT"/test/parse_fixtures/*)      sub=parse_fixtures ;;
      "$ROOT"/test/comment_fixtures/*)    sub=comment_fixtures ;;
      "$ROOT"/test/positions_fixtures/*)  sub=positions_fixtures ;;
      "$ROOT"/test/diff_fixtures/*)       sub=diff_fixtures ;;
      "$ROOT"/stdlib/*|"$ROOT"/stdlib)    sub=stdlib ;;
      "$ROOT"/compiler/*|"$ROOT"/compiler) sub=compiler ;;
      *)
        echo "not part of the snapshot corpus: $p" >&2
        echo "  (corpus: test/parse_fixtures, test/parse_only_fixtures, test/comment_fixtures, test/positions_fixtures, test/diff_fixtures, stdlib, compiler)" >&2
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
  printf '%-22s %s\n' "$sub" "$(printf '%s\n' "$out" | tail -1)"
  printf '%s\n' "$out" | grep -E '^(.*: (FAIL|ERROR))' | sed 's/^/    /'
}

run_family parse_fixtures      parse,printer,desugar,mark "$ROOT"/test/parse_fixtures/*.mdk
run_family parse_only_fixtures parse              "$ROOT"/test/parse_only_fixtures/*.mdk
run_family positions_fixtures  positions          "$ROOT"/test/positions_fixtures/*.mdk
run_family comment_fixtures    comments           "$ROOT"/test/comment_fixtures/*.mdk
run_family stdlib              desugar,mark       "$ROOT"/stdlib/*.mdk
run_family diff_fixtures       tokens,desugar,mark "$ROOT"/test/diff_fixtures/*.mdk
run_family compiler            desugar,mark \
  "$ROOT"/compiler/frontend/*.mdk "$ROOT"/compiler/types/*.mdk \
  "$ROOT"/compiler/ir/*.mdk "$ROOT"/compiler/backend/*.mdk \
  "$ROOT"/compiler/eval/*.mdk "$ROOT"/compiler/driver/*.mdk \
  "$ROOT"/compiler/tools/*.mdk "$ROOT"/compiler/support/*.mdk

# ── THE SUMMARY MUST DESCRIBE WHAT IT ACTUALLY DID ───────────────────────────
#
# This line used to read `$total fixtures, all snapshots match` whenever `fail` was 0 —
# regardless of whether a single snapshot had been COMPARED. Under `--new` (which skips
# every fixture that already has a snapshot, by design) that meant:
#
#     compiler   snapshot: 50 fixtures — 0 pass, 0 new, 0 blessed, 50 SKIPPED, 0 failed
#     168 fixtures, all snapshots match          <- compared NOTHING. Exit 0.
#
# An agent ran exactly this after editing three compiler sources, read "all snapshots
# match", and would have shipped stale goldens had it not distrusted the harness. The
# per-corpus line was honest; the SUMMARY lied, and the summary is what people read.
#
# That is this suite's defining bug class — "this didn't run" being indistinguishable from
# "this passed" — living inside the snapshot harness built to eradicate it. Of course it
# is: the harness is the newest code here, and the bug is not a typo, it is an ASSUMPTION
# (fail==0 means everything matched) that is only true in --check mode.
#
# So the summary now reports COMPARED, and never says "match" about a fixture it skipped.
printf '\n'
if [ "$fail" -ne 0 ]; then
  printf '%d fixtures — %d compared, %d skipped: SNAPSHOTS DIFFER\n' "$total" "$compared" "$skipped"
elif [ "$compared" -eq 0 ]; then
  # Not a pass. In --check this means the corpus was empty or unreadable; in --new/--bless
  # it just means nothing needed doing. Either way: say so, do not claim a match.
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
