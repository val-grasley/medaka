#!/bin/sh
# Execution validation for the self-hosted eval: RUN each diff_fixtures program
# for its OUTPUT (putStr/putStrLn captured into an output buffer) and match the
# committed === EVAL === golden (the reference's program stdout) byte-for-byte.
#
# Self-host: eval_run_main.mdk prepends core.mdk + list.mdk, evaluates the
# program, and prints the captured stdout.  Command substitution rstrips trailing
# newlines on both sides (gen_golden rstrips the golden).
#
# This is the "true execution" path (vs eval_main's pp_value of `main`): the
# program actually performs its IO.  dict_pass is unneeded for these — none use
# return-position dispatch, so the untyped tree evals identically.
#
# OCaml-free (REROOT-PLAN.md Phase 2): the eval_run stage runs as the pre-compiled
# native binary test/bin/eval_run_main (built by test/build_oracles.sh) instead of
# `main.exe run`.  The reference is the committed === EVAL === golden, captured
# while OCaml was trusted — no live OCaml oracle here.  The native runtime
# auto-prints main's Unit return as a trailing "()" line; strip_unit removes it
# (the goldens, captured from OCaml `run`, carry no such line).
#
# Usage:  sh test/diff_selfhost_eval_run.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/eval_run_main"
CORE="$ROOT/stdlib/core.mdk"; LIST="$ROOT/stdlib/list.mdk"
FIXDIR="$ROOT/test/diff_fixtures"
[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }
strip_unit() { sed '${/^()$/d;}'; }
pass=0; fail=0
for g in "$FIXDIR"/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$FIXDIR/$fix.mdk" ] || continue
  self="$("$RUN" "$CORE" "$LIST" "$FIXDIR/$fix.mdk" 2>/dev/null | strip_unit)"
  golden="$(sed -n '/=== EVAL ===/,$p' "$g" | sed '1d')"
  if [ "$self" = "$golden" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$fix"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$fix"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
