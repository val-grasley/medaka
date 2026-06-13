#!/bin/sh
# Differential validation for self-hosted TYPE ERROR accumulation.
#
# OCaml-free (REROOT-PLAN §2b): both self-hosted drivers run as native binaries
# and are diffed against a committed golden captured from dev/tc_probe.exe
# (parse → Desugar → check_program_no_prelude, first Type_error → "TYPE ERROR: …")
# by test/capture_goldens.sh.  Both sides sorted (order irrelevant for the
# single-error fixtures).
#
# Two drivers tested:
#   A. test/bin/typecheck_main  — bare HM engine, no prelude, matches tc_probe
#   B. test/bin/check_main      — full composed front-end with prelude; same error
#
# Usage:  sh test/diff_selfhost_typecheck_errors.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC_MAIN="$ROOT/test/bin/typecheck_main"
CHECK="$ROOT/test/bin/check_main"
RT="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/typecheck_error_fixtures"

[ -x "$TC_MAIN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $TC_MAIN)"; exit 2; }
[ -x "$CHECK"   ] || { echo "build oracles first: sh test/build_oracles.sh (missing $CHECK)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

pass=0; fail=0

for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.tc.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh tc)"; fail=$((fail+2)); continue; }
  ref="$(LC_ALL=C sort < "$golden")"

  # Driver A: typecheck_main (bare HM, no prelude)
  selfA="$("$TC_MAIN" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  if [ "$selfA" = "$ref" ]; then
    pass=$((pass+1)); printf 'ok   tc_main/%s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL tc_main/%s\n  self: %s\n   ref: %s\n' "$name" "$selfA" "$ref"
  fi

  # Driver B: check_main (full front-end with prelude)
  selfB="$("$CHECK" "$RT" "$CORE" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  if [ "$selfB" = "$ref" ]; then
    pass=$((pass+1)); printf 'ok   check/%s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL check/%s\n  self: %s\n   ref: %s\n' "$name" "$selfB" "$ref"
  fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
