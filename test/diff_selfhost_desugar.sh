#!/bin/sh
# Differential validation for the self-hosted DESUGAR stage:
#   selfhost/desugar_main.mdk  (lex → parse → desugar → selfhost/sexp.mdk dump)
# vs the OCaml reference
#   dev/astdump.exe --desugar  (parse → Desugar.desugar_program → strip_locs → S-expr)
#
# Desugar lowers surface sugar (EGuards/EDo/ESection/EStringInterp/EListComp/
# EFunction/…) to core nodes that selfhost/sexp.mdk already renders, so no new
# dump rendering is needed — only the selfhost desugar pass.  FLOAT literal text
# is normalized away (OCaml %g vs floatToString), like the other harnesses.
#
# Usage:  sh test/diff_selfhost_desugar.sh [file.mdk ...]
#         (default corpus: stdlib + diff_fixtures + parse_fixtures + selfhost)
# Exit:   0 if every file matches (or the selfhost entry isn't ported yet), else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
REF="$ROOT/_build/default/dev/astdump.exe"
DESUGARMAIN="$ROOT/selfhost/desugar_main.mdk"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
[ -x "$REF" ]  || { echo "build first: dune build --root . dev/astdump.exe"; exit 2; }

if [ ! -f "$DESUGARMAIN" ]; then
  echo "pending: selfhost/desugar_main.mdk not yet ported — reference side ready."
  echo "         (run: $REF --desugar <file>  to see the target dump)"
  exit 0
fi

norm() { sed 's/(LFloat [^)]*)/(LFloat)/g'; }

if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$ROOT/stdlib/*.mdk $ROOT/test/diff_fixtures/*.mdk $ROOT/test/parse_fixtures/*.mdk $ROOT/selfhost/*.mdk"
fi

pass=0
fail=0
for f in $files; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  expected="$("$REF" --desugar "$f" 2>/dev/null | norm)"
  actual="$("$MAIN" run "$DESUGARMAIN" "$f" 2>/dev/null | norm)"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$name"
  fi
done

printf '\n%d matched, %d differing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]