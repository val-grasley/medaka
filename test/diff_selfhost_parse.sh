#!/bin/sh
# Differential validation for the self-hosted parser: selfhost/parse_main.mdk
# (parse → AST → selfhost/sexp.mdk structural dump) vs the OCaml reference
# dev/astdump.exe (parse → strip_locs → canonical S-expression).
#
# SCAFFOLD STAGE: there is no recursive-descent parser yet. parse_main.mdk dumps
# a hand-built control AST, and this script's positive control confirms the dump
# FORMAT agrees with dev/astdump.exe on the equivalent source — so when the
# parser lands, a structural match means a correct parse. At that point
# parse_main becomes file-driven and this script will diff it over the fixtures +
# real .mdk files (FLOAT text normalized), exactly like
# test/diff_selfhost_lex_files.sh.
#
# Usage:  sh test/diff_selfhost_parse.sh
# Exit:   0 if the control matches, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
REF="$ROOT/_build/default/dev/astdump.exe"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
[ -x "$REF" ]  || { echo "build first: dune build --root . dev/astdump.exe"; exit 2; }

norm() { sed 's/(LFloat [^)]*)/(LFloat)/g'; }

# Positive control: the dump of parse_main.mdk's hand-built AST must equal the
# reference dump of the equivalent source.
ctrl="$ROOT/.parse_control.mdk"
printf 'inc : Int -> Int\ninc x = x + 1\n' > "$ctrl"
expected="$("$REF" "$ctrl" | norm)"
actual="$("$MAIN" run "$ROOT/selfhost/parse_main.mdk" 2>/dev/null | norm)"
rm -f "$ctrl"

if [ "$expected" = "$actual" ]; then
  echo "ok   <positive-control: dump format agrees>"
  echo ""
  echo "1 passed, 0 failed"
  exit 0
else
  echo "FAIL <positive-control: dump format>"
  printf '  expected:\n%s\n  actual:\n%s\n' "$expected" "$actual"
  echo ""
  echo "0 passed, 1 failed"
  exit 1
fi
