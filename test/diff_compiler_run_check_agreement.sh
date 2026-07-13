#!/bin/sh
# run == check == build agreement gate (beta P0-1 / P0-17 / P0-18).
#
# The single biggest systemic beta-hardening finding (qa-beta-2026-07-07/FINDINGS.md
# theme #1): `medaka run` does not reject the same programs `medaka check` rejects.
# `check` runs the full diagnostic pass (resolve + typecheck + constraint/coherence/
# no-impl checks) and is treated here as the SOURCE OF TRUTH for whether a program
# is well-formed. `run` currently gates only on resolve errors + hadTypeErrors()
# (unification failures) — it misses constraint/no-impl/coherence errors, so it
# silently EXECUTES some ill-typed programs (P0-1). There is also a smaller
# opposite-direction gap (P0-17/P0-18): a few programs make `run` (and sometimes
# `build`) refuse where `check` is silent — usually because `check` itself has a
# missing diagnostic (e.g. P0-17: an impl silently missing a method), so `run`'s
# rejection isn't "run is stricter", it's "run hit a hole check should have caught
# earlier and reported properly".
#
# THIS GATE IS INTENTIONALLY PARTIALLY RED ON CURRENT MAIN. It exists to document
# and lock in the exact scope of the divergence so a follow-up fix can drive it to
# green, not to represent already-fixed behavior. Do not "fix" this gate by
# loosening its assertions — fix the compiler, which will turn fixtures green.
#
# Corpus: test/run_check_agreement_fixtures/<name>.mdk, each paired with a
# <name>.expected file containing exactly REJECT or ACCEPT — check's ACTUAL
# verdict on current main (REJECT = check exits nonzero; ACCEPT = check exits 0).
# That is the fixture's source-of-truth verdict; a fixture PASSES iff check, run,
# AND build (accept-vs-reject, by exit code only — message quality is out of
# scope, that's P1-8/ERROR-QUALITY.md) all agree with .expected. See the header
# comment in each fixture for which FINDINGS.md item it's from and which direction
# it diverges (if any) on current main.
#
# T-6: every ACCEPT fixture MUST also ship a <name>.out file pinning the exact
# expected stdout — this is REQUIRED, not optional. A missing .out on an ACCEPT
# fixture is graded FAIL (value column = NOPIN), never silently skipped. Why
# required rather than merely optional: without a mandatory pin, a fixture where
# `run` and `build` agree on the SAME WRONG value sails through undetected (they
# agree with each other, just not with reality — this is exactly the shape the
# record-update shadow bug would have hidden in), and a contributor adding a new
# ACCEPT fixture gets no signal that they forgot to pin ground truth. REJECT
# fixtures never execute (check rejects before run/build produce output), so
# they are exempt — a .out on a REJECT fixture would be meaningless; there is no
# ledgered exception list because no current ACCEPT fixture has a legitimate
# reason to lack one (all output is deterministic). When minting a .out, DO NOT
# blindly capture whatever the binary currently prints as truth — read the
# fixture source and confirm the value is actually correct before pinning it.
#
# Usage:  sh test/diff_compiler_run_check_agreement.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/run_check_agreement_fixtures"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -d "$FIXDIR" ] || { echo "missing fixture dir: $FIXDIR"; exit 2; }

bound() { perl -e 'alarm 60; exec @ARGV' "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

printf '%-46s %-8s %-6s %-6s %-6s %-6s %s\n' 'fixture' 'expect' 'check' 'run' 'build' 'value' 'result'
printf '%-46s %-8s %-6s %-6s %-6s %-6s %s\n' '--------------------------------------------' '--------' '------' '------' '------' '------' '------'

for f in "$FIXDIR"/*.mdk; do
  base="$(basename "$f" .mdk)"
  expfile="$FIXDIR/$base.expected"
  if [ ! -f "$expfile" ]; then
    fail=$((fail+1))
    printf '%-46s %-8s %s\n' "$base" 'MISSING' 'no .expected file'
    continue
  fi
  expected="$(cat "$expfile" | tr -d '[:space:]')"

  bound "$MEDAKA" check "$f" >/dev/null 2>&1
  check_code=$?
  bound "$MEDAKA" run "$f" >"$TMP/run_$base.out" 2>/dev/null
  run_code=$?
  bound "$MEDAKA" build "$f" -o "$TMP/out_$base" >/dev/null 2>&1
  build_code=$?

  if [ "$check_code" -ne 0 ]; then check_v='REJECT'; else check_v='ACCEPT'; fi
  if [ "$run_code" -ne 0 ]; then run_v='REJECT'; else run_v='ACCEPT'; fi
  if [ "$build_code" -ne 0 ]; then build_v='REJECT'; else build_v='ACCEPT'; fi

  # P0-20: exit codes are NOT enough.  The bug this corpus exists to catch had `build`
  # exit 0 while printing a WRONG NUMBER (a Bool rendered through intToString), which an
  # accept-vs-reject gate cannot see — it would have graded that fixture PASS.  So for an
  # ACCEPT fixture also require the two ENGINES to agree on the VALUE (`run` stdout ==
  # the built binary's stdout), AND (T-6) require a `.out` file pinning that value to be
  # present and correct — a missing `.out` is its own FAIL category (NOPIN), not a skip,
  # because two engines agreeing with each other proves nothing if they agree on garbage.
  value_v='-'
  if [ "$expected" = 'ACCEPT' ]; then
    if [ ! -f "$FIXDIR/$base.out" ]; then
      value_v='NOPIN'
    elif [ "$run_v" = 'ACCEPT' ] && [ "$build_v" = 'ACCEPT' ]; then
      "$TMP/out_$base" >"$TMP/build_$base.out" 2>/dev/null
      if ! cmp -s "$TMP/run_$base.out" "$TMP/build_$base.out"; then
        value_v='DIFF'
      elif ! cmp -s "$FIXDIR/$base.out" "$TMP/run_$base.out"; then
        value_v='WRONG'
      else
        value_v='ok'
      fi
    fi
  fi

  if [ "$check_v" = "$expected" ] && [ "$run_v" = "$expected" ] && [ "$build_v" = "$expected" ] \
     && [ "$value_v" != 'DIFF' ] && [ "$value_v" != 'WRONG' ] && [ "$value_v" != 'NOPIN' ]; then
    pass=$((pass+1))
    result='PASS'
  else
    fail=$((fail+1))
    result='FAIL'
  fi
  printf '%-46s %-8s %-6s %-6s %-6s %-6s %s\n' "$base" "$expected" "$check_v" "$run_v" "$build_v" "$value_v" "$result"
done

echo
printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"

# This gate is GREEN and load-bearing: it exits nonzero on any disagreement.  (It used to
# print "RED expected on current main until the run==check fix lands" unconditionally —
# stale since the P0-1/P0-17/P0-18/P0-19 fixes; a gate that announces its own redness
# trains readers to ignore it.)
[ "$fail" -eq 0 ]
