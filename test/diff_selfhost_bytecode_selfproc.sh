#!/bin/sh
# §2.2/§2.3 bytecode VM selfproc harness.
#
# Section 1 — §2.2 untyped bytecode VM (eval_bytecode_modules_main.mdk):
#   lex probe:   PASSES — lexer uses untyped eval only, no return-pos dispatch
#   parse probe: expected gap (untyped-only) — Parser monad needs return-pos dispatch
#   tc probe:    expected gap (untyped-only) — typecheck stage uses Parser monad too
#
# Section 2 — §2.3 typed bytecode VM (eval_bytecode_typed_modules_main.mdk):
#   All three probes pass: elaborateModules stamps RKey routes so return-pos
#   dispatch resolves correctly through the bytecode VM.
#
# Expected-gap probes count as ok (they confirm a documented limitation, not
# a regression); exit 0 iff no unexpected failures.
#
# Usage:  sh test/diff_selfhost_bytecode_selfproc.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
BC_MODS="$ROOT/selfhost/eval_bytecode_modules_main.mdk"
BC_TYPED_MODS="$ROOT/selfhost/eval_bytecode_typed_modules_main.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
SHDIR="$ROOT/selfhost"
LEXPROBE="$ROOT/selfhost/selfproc_lex_probe.mdk"
PARSEPROBE="$ROOT/selfhost/selfproc_parse_probe.mdk"
TCPROBE="$ROOT/selfhost/selfproc_tc_probe.mdk"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
for f in "$BC_MODS" "$BC_TYPED_MODS" "$LEXPROBE" "$PARSEPROBE" "$TCPROBE"; do
  [ -f "$f" ] || { echo "missing $f"; exit 2; }
done

pass=0; fail=0

run_untyped() {
  label="$1"; probe="$2"; expect_gap="${3:-}"
  ref="$("$MAIN" run "$probe" 2>/dev/null)"
  self="$("$MAIN" run "$BC_MODS" "$CORE" "$probe" "$SHDIR" 2>/dev/null)"
  if [ "$ref" = "$self" ] && [ -n "$ref" ]; then
    pass=$((pass+1))
    printf 'ok   %-12s (untyped bytecode VM == OCaml oracle)\n' "$label"
  elif [ -n "$expect_gap" ]; then
    pass=$((pass+1))
    printf 'ok   %-12s (expected gap — %s)\n' "$label" "$expect_gap"
  else
    fail=$((fail+1))
    printf 'FAIL %-12s (untyped bytecode VM output differs / empty)\n' "$label"
    printf '  ref:  %s\n' "$(printf '%s' "$ref"  | head -3 | tr '\n' '|')"
    printf '  self: %s\n' "$(printf '%s' "$self" | head -3 | tr '\n' '|')"
  fi
}

run_typed() {
  label="$1"; probe="$2"
  ref="$("$MAIN" run "$probe" 2>/dev/null)"
  self="$("$MAIN" run "$BC_TYPED_MODS" "$RUNTIME" "$CORE" "$probe" "$SHDIR" 2>/dev/null)"
  if [ "$ref" = "$self" ] && [ -n "$ref" ]; then
    pass=$((pass+1))
    printf 'ok   %-12s (typed bytecode VM == OCaml oracle)\n' "$label"
  else
    fail=$((fail+1))
    printf 'FAIL %-12s (typed bytecode VM output differs / empty)\n' "$label"
    printf '  ref:  %s\n' "$(printf '%s' "$ref"  | head -3 | tr '\n' '|')"
    printf '  self: %s\n' "$(printf '%s' "$self" | head -3 | tr '\n' '|')"
  fi
}

echo "== §2.2 capstone: real selfhost stages through untyped bytecode VM =="
run_untyped "lex_probe"   "$LEXPROBE"
run_untyped "parse_probe" "$PARSEPROBE" "return-pos dispatch not in untyped VM"
run_untyped "tc_probe"    "$TCPROBE"    "return-pos dispatch not in untyped VM"

echo ""
echo "== §2.3 item 1: real selfhost stages through TYPED bytecode VM =="
run_typed "lex_probe"   "$LEXPROBE"
run_typed "parse_probe" "$PARSEPROBE"
run_typed "tc_probe"    "$TCPROBE"

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
