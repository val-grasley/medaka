#!/bin/sh
# BOOTSTRAP (B7) — natively compiled self-hosted EVAL stage == reference over
# eval_fixtures.  OCaml-free (REROOT-PLAN §2e): reference = committed golden
# captured from `main.exe run selfhost/entries/eval_main.mdk <fixture>`
# (test/capture_goldens.sh boot_eval); native = test/bin/eval_main.
#
# eval_main's `main` `putStrLn`s "<value>\n"; the native binary additionally
# auto-prints main's Unit as "()\n", so native stdout is "<value>\n()\n".  The
# golden holds the raw reference "<value>"; strip_unit drops the trailing "()"
# line from the native output before the byte-for-byte compare.
#
# Usage:  sh test/bootstrap_eval.sh
# Exit:   0 all match; 2 oracle binary missing (run sh test/build_oracles.sh).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/eval_main"
FIXDIR="$ROOT/test/eval_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

pass=0; fail=0
for fix in "$FIXDIR"/*.mdk; do
  [ -f "$fix" ] || continue
  name="$(basename "$fix")"
  golden="${fix%.mdk}.boot_eval.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (no .boot_eval.golden — run sh test/capture_goldens.sh boot_eval)\n' "$name"; continue
  fi
  ref="$(cat "$golden")"
  self="$("$RUN" "$fix" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1))
    printf 'FAIL %s\n' "$name"
    printf '    ref : %s\n' "$ref"
    printf '    self: %s\n' "$self"
  fi
done

printf '\n%d ok, %d failing (of %d)\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
