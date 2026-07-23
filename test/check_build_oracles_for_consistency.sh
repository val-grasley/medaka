#!/bin/sh
# check_build_oracles_for_consistency.sh — assert build_oracles.sh --for's broad
# wildcard derivation is the UNION of its own narrower per-gate derivations (#832).
#
# WHY THIS GATE EXISTS.
# `test/build_oracles.sh --for '<gate-pattern>'` derives the oracle set a gate
# pattern needs by grepping every MATCHED gate script for `test/bin/<name>` and
# intersecting against the static $ENTRIES table (see build_oracles.sh's own
# header). #816 filed #832 believing the broad family pattern `'diff_compiler_*'`
# derived a SMALLER set than the union of its own narrower same-family patterns —
# i.e. that some gate's oracle need got dropped when it was matched alongside 96
# siblings instead of alone. Direct verification (this gate, and the `--for --list`
# peek mode it depends on — added alongside it) did not reproduce that gap: the
# derivation is a straightforward per-gate grep+union, and nothing about pattern
# BREADTH can drop an entry the algorithm would otherwise find. What #816 actually
# lacked was a way to SEE the derived set without a real build to compare it
# against — `--build-one <name>` "chasers" were the only way to check, one guess
# at a time.
#
# So rather than leave the (unreproduced, but plausible-shaped) worry unguarded,
# this gate makes the invariant a permanent, cheap assertion: for the
# `diff_compiler_*` family, the broad pattern's derived set MUST equal the union
# of every individual matching gate's own derived set. It cannot currently fail —
# that IS the point: it pins the invariant so a FUTURE change to the --for
# matching logic (an early exit, a `head -N` cap, a broken dedup) trips this gate
# instead of silently reintroducing #832's shape. See test/MUST-FAIL-NOT-PINNABLE.txt
# for why #832 itself could not be pinned as a must_fail fixture (no program-shaped
# observable — the defect, if any, lives in a shell script, not compiled output),
# and why landing this assert is what retires that ledger line.
#
# Needs no clang/libgc/medaka — `--for --list` (added alongside this gate) derives
# the set with plain grep/sed over test/*.sh and the static $ENTRIES table, so this
# runs anywhere, instantly, before any compiler exists.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BO="$ROOT/test/build_oracles.sh"

# The broad, whole-family pattern this gate's fresh-worktree recipe (AGENTS.md)
# names by name.
broad="$(sh "$BO" --for --list 'diff_compiler_*' | sort -u)"

# The union of EVERY individual `diff_compiler_*.sh` gate's own derived set —
# each one is the narrowest possible "same-family" pattern for that gate (an
# exact, non-wildcard basename), so their union is definitionally what the broad
# wildcard ought to produce. Derived from the filesystem, not a hand-listed set:
# a new diff_compiler_*.sh gate is covered the moment it is added.
checked=0
union=""
for f in "$ROOT"/test/diff_compiler_*.sh; do
  [ -f "$f" ] || continue
  checked=$((checked + 1))
  name="$(basename "$f" .sh)"
  for o in $(sh "$BO" --for --list "$name" 2>/dev/null); do
    case " $union " in *" $o "*) ;; *) union="$union $o" ;; esac
  done
done
union="$(printf '%s\n' $union | sort -u)"

# N == 0 must be a failure, not a silent pass — a glob that matched nothing would
# make "broad == union" trivially (and wrongly) true.
if [ "$checked" -eq 0 ]; then
  echo "FAIL: checked 0 diff_compiler_*.sh gates — this gate matched nothing and" >&2
  echo "      would have reported PASS on an empty comparison. The glob is broken," >&2
  echo "      not the tree." >&2
  exit 1
fi

# Plain set-difference via shell loops + exact-line grep (no `comm`/process-
# substitution — this script stays POSIX `sh`, run via dash in CI and bash on
# macOS alike). Membership is tested with `grep -xF` against the whole
# (newline-separated, from `sort -u`) string rather than a `case " $x "*`
# space-delimited scan, since the separator here is a newline, not a space.
missing_from_broad=""
for o in $union; do
  printf '%s\n' "$broad" | grep -qxF "$o" || missing_from_broad="$missing_from_broad $o"
done
extra_in_broad=""
for o in $broad; do
  printf '%s\n' "$union" | grep -qxF "$o" || extra_in_broad="$extra_in_broad $o"
done

if [ -n "$missing_from_broad" ] || [ -n "$extra_in_broad" ]; then
  echo "FAIL: 'diff_compiler_*' derives a DIFFERENT oracle set than the union of" >&2
  echo "      its $checked individual gate scripts (#832's exact shape)." >&2
  if [ -n "$missing_from_broad" ]; then
    echo "  in the per-gate union but MISSING from the broad wildcard:" >&2
    printf '    %s\n' $missing_from_broad >&2
  fi
  if [ -n "$extra_in_broad" ]; then
    echo "  in the broad wildcard but not read by ANY individual gate:" >&2
    printf '    %s\n' $extra_in_broad >&2
  fi
  exit 1
fi

n="$(printf '%s\n' $broad | grep -vc '^$')"
echo "PASS: 'diff_compiler_*' derives exactly the $n-oracle union of its $checked gates."
