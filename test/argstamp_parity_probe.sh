#!/bin/sh
# ARGSTAMP-UNIFY-PLAN.md Phase 0 — TEMP parity probe harness (delete at unification end).
#
# Runs the eval-dict corpus under BOTH argStampEnabled settings (EMIT/ON vs EVAL/OFF)
# and diffs PROGRAM OUTPUT (not IR).  Establishes the Phase-0 baseline:
#   • per-fixture: output under ON, output under OFF, and whether they match
#   • the OFF column is the current eval-driver behaviour (== diff_selfhost_eval_dict golden)
#   • SAME under both  => fixture is fork-invariant at the OUTPUT level (plan's prediction)
#   • DIFFERS          => a fixture the unification must reconcile; named for phase ownership
#
# Driver: test/bin/argstamp_parity_probe (built from selfhost/entries/argstamp_parity_probe.mdk
# via test/build_oracles.sh-style native build).  Arg1 = ON|OFF mode switch.
#
# Usage:  sh test/argstamp_parity_probe.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/test/bin/argstamp_parity_probe"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_dict_fixtures"
[ -x "$PROBE" ] || { echo "build probe first: MEDAKA_ROOT=\$ROOT MEDAKA_EMITTER=\$ROOT/medaka_emitter ./medaka build selfhost/entries/argstamp_parity_probe.mdk -o $PROBE"; exit 2; }
strip_unit() { sed '${/^()$/d;}'; }  # drop native runtime's trailing Unit auto-print

same=0; differ=0; total=0
differing=""
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  total=$((total+1))
  # Merge stderr (2>&1) so a runtime error (e.g. an unbound `$dict_*`, or a
  # `requires Semigroup` panic) is part of the compared output, not silently
  # dropped — a fork that changes a value into a crash MUST count as DIFFER.
  on="$("$PROBE"  ON "$RT" "$CORE" "$f" 2>&1 | strip_unit)"
  off="$("$PROBE" OFF "$RT" "$CORE" "$f" 2>&1 | strip_unit)"
  if [ "$on" = "$off" ]; then
    same=$((same+1)); printf 'SAME   %-40s %s\n' "$name" "$off"
  else
    differ=$((differ+1)); differing="$differing $name"
    printf 'DIFFER %-40s\n  ON : %s\n  OFF: %s\n' "$name" "$on" "$off"
  fi
done
printf '\n%d fixtures: %d output-identical under both flags, %d differ\n' "$total" "$same" "$differ"
[ "$differ" -gt 0 ] && printf 'differing:%s\n' "$differing"
exit 0
