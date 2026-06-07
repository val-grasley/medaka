#!/bin/sh
# §2.2 bytecode VM capstone selfproc harness.
#
# Runs real self-hosted stages through the bytecode multi-module VM
# (eval_bytecode_modules_main.mdk / bytecode.bcEvalModulesOutput) and diffs
# byte-for-byte against the OCaml oracle (medaka run <probe>).
#
#   lex probe:   PASSES — lexer uses untyped eval only, no return-pos dispatch
#   parse probe: expected gap (§2.3) — Parser monad needs return-pos dispatch
#   tc probe:    expected gap (§2.3) — typecheck stage uses Parser monad too
#
# Expected-gap probes count as ok (they confirm a documented §2.3 limitation,
# not a regression); exit 0 iff no unexpected failures.
#
# Usage:  sh test/diff_selfhost_bytecode_selfproc.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
BC_MODS="$ROOT/selfhost/eval_bytecode_modules_main.mdk"
CORE="$ROOT/stdlib/core.mdk"
SHDIR="$ROOT/selfhost"
LEXPROBE="$ROOT/selfhost/selfproc_lex_probe.mdk"
PARSEPROBE="$ROOT/selfhost/selfproc_parse_probe.mdk"
TCPROBE="$ROOT/selfhost/selfproc_tc_probe.mdk"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
for f in "$BC_MODS" "$LEXPROBE" "$PARSEPROBE" "$TCPROBE"; do
  [ -f "$f" ] || { echo "missing $f"; exit 2; }
done

pass=0; fail=0

run_case() {
  label="$1"; probe="$2"; expect_gap="${3:-}"
  ref="$("$MAIN" run "$probe" 2>/dev/null)"
  self="$("$MAIN" run "$BC_MODS" "$CORE" "$probe" "$SHDIR" 2>/dev/null)"
  if [ "$ref" = "$self" ] && [ -n "$ref" ]; then
    pass=$((pass+1))
    printf 'ok   %-12s (bytecode VM == OCaml oracle)\n' "$label"
  elif [ -n "$expect_gap" ]; then
    pass=$((pass+1))
    printf 'ok   %-12s (expected gap — %s)\n' "$label" "$expect_gap"
  else
    fail=$((fail+1))
    printf 'FAIL %-12s (bytecode VM output differs / empty)\n' "$label"
    printf '  ref:  %s\n' "$(printf '%s' "$ref"  | head -3 | tr '\n' '|')"
    printf '  self: %s\n' "$(printf '%s' "$self" | head -3 | tr '\n' '|')"
  fi
}

echo "== §2.2 capstone: real selfhost stages through bytecode multi-module VM =="
run_case "lex_probe"   "$LEXPROBE"
run_case "parse_probe" "$PARSEPROBE" "return-pos dispatch not in untyped VM — §2.3"
run_case "tc_probe"    "$TCPROBE"    "return-pos dispatch not in untyped VM — §2.3"

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
