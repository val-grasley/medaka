#!/bin/sh
# True-execution (stdout) equivalence gate for the Core IR (STAGE2-DESIGN §2.1) —
# broadens the §2.1 equivalence proof to the eval_run corpus (the === EVAL ===
# goldens), the Core-IR analog of test/diff_selfhost_eval_run.sh.
#
# Self-host: core_ir_run_main.mdk prepends core.mdk + list.mdk, annotates +
# LOWERS the program to Core IR, evaluates it for its OUTPUT (putStr/putStrLn
# captured into an output buffer), and prints the captured stdout.  Diffs against
# the committed === EVAL === golden (the reference's program stdout) byte-for-byte
# — the SAME goldens diff_selfhost_eval_run.sh matches.  So this is to
# eval_run_main what diff_selfhost_core_ir.sh is to eval_main: the Core IR is
# correct on the true-execution path iff its captured stdout matches the AST
# tree-walker's.  Command substitution rstrips trailing newlines on both sides.
#
# Usage:  sh test/diff_selfhost_core_ir_run.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
RUN="$ROOT/selfhost/core_ir_run_main.mdk"
CORE="$ROOT/stdlib/core.mdk"; LIST="$ROOT/stdlib/list.mdk"
FIXDIR="$ROOT/test/diff_fixtures"
[ -x "$MAIN" ] || { echo "build first: dune build --root ."; exit 2; }
pass=0; fail=0
for g in "$FIXDIR"/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$FIXDIR/$fix.mdk" ] || continue
  self="$("$MAIN" run "$RUN" "$CORE" "$LIST" "$FIXDIR/$fix.mdk" 2>/dev/null)"
  golden="$(sed -n '/=== EVAL ===/,$p' "$g" | sed '1d')"
  if [ "$self" = "$golden" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$fix"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$fix"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
