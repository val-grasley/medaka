#!/bin/sh
# Differential validation for the self-hosted parser: selfhost/parse_main.mdk
# (lex → parse → selfhost/ir/sexp.mdk structural dump) vs the OCaml reference
# dev/astdump.exe (parse → strip_locs → canonical S-expression).
#
# Runs over test/parse_fixtures/ + test/parse_only_fixtures/ — small .mdk programs
# scoped to what the parser currently handles (the corpus grows as the
# recursive-descent port grows; the stage is done when it covers the real
# test/diff_fixtures/ files).  FLOAT literal text is normalized away (OCaml %g vs
# floatToString), like the lexer harness.
#
# parse_only_fixtures/ holds constructs the parser accepts but the *downstream*
# self-host stages (desugar/mark/…) don't handle yet — type aliases, newtypes,
# Map/Set literals, attributes, top-level let-groups — so they must NOT go in the
# shared parse_fixtures/ corpus that diff_selfhost_{desugar,mark}.sh also read.
#
# Usage:  sh test/diff_selfhost_parse.sh [file.mdk ...]
# Exit:   0 if every file's AST dump matches, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
REF="$ROOT/_build/default/dev/astdump.exe"
PARSEMAIN="$ROOT/selfhost/parse_main.mdk"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
[ -x "$REF" ]  || { echo "build first: dune build --root . dev/astdump.exe"; exit 2; }

norm() { sed 's/(LFloat [^)]*)/(LFloat)/g'; }

if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$ROOT/test/parse_fixtures/*.mdk $ROOT/test/parse_only_fixtures/*.mdk"
fi

pass=0
fail=0
for f in $files; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  expected="$("$REF" "$f" | norm)"
  actual="$("$MAIN" run "$PARSEMAIN" "$f" 2>/dev/null | norm)"
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
