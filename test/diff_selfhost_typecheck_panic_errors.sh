#!/bin/sh
# Differential validation for the self-hosted TYPECHECK stage's ERROR PATH on
# shapes that resolve normally pre-screens — TYPECHECK-AUDIT finding D1.
#
# These programs reference an unknown constructor / record / field, or an
# unbound variable.  In the FULL front-end (compiler/tools/check.mdk) resolve catches
# them first, so the typecheck stage never sees them.  But on the no-resolve
# differential path (the tc_probe oracle vs compiler/entries/typecheck_main.mdk) the
# typecheck stage IS the one that reaches the error.  Before D1 the self-hosted
# typechecker PANICKED (uncatchable interpreter abort) on these; the oracle
# accumulates a `TYPE ERROR: …`.  D1 converts those panics into accumulated
# `typeErrors` entries with byte-identical messages + a fresh-var placeholder so
# inference continues — this harness pins that parity (no panic, == oracle).
#
# OCaml-free (REROOT-PLAN §2b): native host test/bin/typecheck_main vs a committed
# golden captured from dev/tc_probe.exe (bare HM, NO prelude) by
# test/capture_goldens.sh.  Driver = typecheck_main (the full-front-end check.mdk
# driver is deliberately NOT tested here: it stops at resolve for these shapes).
#
# Usage:  sh test/diff_compiler_typecheck_panic_errors.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/typecheck_main"
FIXDIR="$ROOT/test/typecheck_panic_fixtures"
[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.tc.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh tc)"; fail=$((fail+1)); continue; }
  ref="$(LC_ALL=C sort < "$golden")"
  self="$("$RUN" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  --- ref ---\n%s\n  --- self ---\n%s\n' "$name" "$ref" "$self"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
