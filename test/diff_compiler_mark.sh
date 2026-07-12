#!/bin/sh
# Differential validation for the self-hosted MARK stage:
#   compiler/entries/mark_main.mdk  (lex → parse → desugar → compiler/ir/sexp.mdk dump)
# vs the OCaml reference
#   dev/astdump.exe --mark  (parse → Desugar.desugar_program → strip_locs → S-expr)
#
# Method_marker rewrites interface-method / constrained-fn EVar occurrences to
# EMethodRef / EDictApp (refs left unfilled until typecheck).  The reference
# --mark dump renders them as (EMethodRef "name") / (EDictApp "name"); the
# compiler side needs those two nodes in ast.mdk + sexp.mdk.  FLOAT literal text
# is normalized away (OCaml %g vs floatToString), like the other harnesses.
#
# Usage:  sh test/diff_compiler_mark.sh [file.mdk ...]
#         (default corpus: stdlib + diff_fixtures + parse_fixtures + compiler)
# Exit:   0 if every file matches (or the compiler entry isn't ported yet), else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/mark_main"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

norm() { sed 's/(LFloat [^)]*)/(LFloat)/g'; }

if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$ROOT/stdlib/*.mdk $ROOT/test/diff_fixtures/*.mdk $ROOT/test/parse_fixtures/*.mdk $ROOT/compiler/*.mdk"
fi

pass=0
fail=0
for f in $files; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.mark.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh --frozen mark)"; fail=$((fail+1)); continue; }
  expected="$(norm < "$golden")"
  actual="$("$RUN" "$ROOT/stdlib/core.mdk" "$f" 2>/dev/null | strip_unit | norm)"
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