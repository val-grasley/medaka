#!/bin/sh
# Differential validation for the self-hosted MARK stage:
#   selfhost/mark_main.mdk  (lex → parse → desugar → selfhost/sexp.mdk dump)
# vs the OCaml reference
#   dev/astdump.exe --mark  (parse → Desugar.desugar_program → strip_locs → S-expr)
#
# Method_marker rewrites interface-method / constrained-fn EVar occurrences to
# EMethodRef / EDictApp (refs left unfilled until typecheck).  The reference
# --mark dump renders them as (EMethodRef "name") / (EDictApp "name"); the
# selfhost side needs those two nodes in ast.mdk + sexp.mdk.  FLOAT literal text
# is normalized away (OCaml %g vs floatToString), like the other harnesses.
#
# Usage:  sh test/diff_selfhost_mark.sh [file.mdk ...]
#         (default corpus: stdlib + diff_fixtures + parse_fixtures + selfhost)
# Exit:   0 if every file matches (or the selfhost entry isn't ported yet), else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
REF="$ROOT/_build/default/dev/astdump.exe"
MARKMAIN="$ROOT/selfhost/mark_main.mdk"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
[ -x "$REF" ]  || { echo "build first: dune build --root . dev/astdump.exe"; exit 2; }

if [ ! -f "$MARKMAIN" ]; then
  echo "pending: selfhost/mark_main.mdk not yet ported — reference side ready."
  echo "         (run: $REF --mark <file>  to see the target dump)"
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
  expected="$("$REF" --mark "$f" 2>/dev/null | norm)"
  actual="$("$MAIN" run "$MARKMAIN" "$f" 2>/dev/null | norm)"
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