#!/bin/sh
# Differential validation for the self-hosted DESUGAR stage:
#   selfhost/entries/desugar_main.mdk  (lex → parse → desugar → selfhost/ir/sexp.mdk dump)
# vs the OCaml reference
#   dev/astdump.exe --desugar  (parse → Desugar.desugar_program → strip_locs → S-expr)
#
# Desugar lowers surface sugar (EGuards/EDo/ESection/EStringInterp/EListComp/
# EFunction/…) to core nodes that selfhost/ir/sexp.mdk already renders, so no new
# dump rendering is needed — only the selfhost desugar pass.  FLOAT literal text
# is normalized away (OCaml %g vs floatToString), like the other harnesses.
#
# Usage:  sh test/diff_selfhost_desugar.sh [file.mdk ...]
#         (default corpus: stdlib + diff_fixtures + parse_fixtures + selfhost)
# Exit:   0 if every file matches (or the selfhost entry isn't ported yet), else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/desugar_main"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

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
  golden="${f%.mdk}.desugar.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh desugar)"; fail=$((fail+1)); continue; }
  expected="$(norm < "$golden")"
  actual="$("$RUN" "$f" 2>/dev/null | strip_unit | norm)"
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