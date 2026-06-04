#!/bin/sh
# Validation for the COMPOSED self-hosted front-end (selfhost/check.mdk): one
# driver runs parse → desugar → resolve → exhaust → typecheck and must reproduce
# each stage's oracle depending on the input category:
#   • diff_fixtures (clean, prelude-using) → the === TYPES === golden (full
#     prelude + user schemes), proving resolve+exhaust pass and typecheck runs;
#   • resolve_fixtures (broken)            → the resolve diagnostics
#     (dev/diagdump.exe --resolve), proving the driver routes resolve errors.
# Both sides sorted before compare.  (exhaust_fixtures emit warning + schemes;
# validated by the standalone exhaust harness.)
#
# Usage:  sh test/diff_selfhost_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
DIAG="$ROOT/_build/default/dev/diagdump.exe"
CHECK="$ROOT/selfhost/check.mdk"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
[ -x "$MAIN" ] || { echo "build first: dune build --root ."; exit 2; }
pass=0; fail=0

for g in "$ROOT"/test/diff_fixtures/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$ROOT/test/diff_fixtures/$fix.mdk" ] || continue
  self="$("$MAIN" run "$CHECK" "$RT" "$CORE" "$ROOT/test/diff_fixtures/$fix.mdk" 2>/dev/null | LC_ALL=C sort)"
  want="$(sed -n '/=== TYPES ===/,/=== EVAL ===/p' "$g" | sed '1d;$d' | LC_ALL=C sort)"
  if [ "$self" = "$want" ]; then pass=$((pass+1)); printf 'ok   types/%s\n' "$fix"
  else fail=$((fail+1)); printf 'FAIL types/%s\n' "$fix"; fi
done

for f in "$ROOT"/test/resolve_fixtures/*.mdk; do
  name="$(basename "$f")"
  self="$("$MAIN" run "$CHECK" "$RT" "$CORE" "$f" 2>/dev/null | LC_ALL=C sort)"
  want="$("$DIAG" --resolve "$f" 2>/dev/null | LC_ALL=C sort)"
  if [ "$self" = "$want" ]; then pass=$((pass+1)); printf 'ok   resolve/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL resolve/%s\n' "$name"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
