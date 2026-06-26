#!/bin/sh
# Differential validation for the self-hosted parser: compiler/entries/parse_main.mdk
# (lex → parse → compiler/ir/sexp.mdk structural dump) vs the OCaml reference
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
# shared parse_fixtures/ corpus that diff_compiler_{desugar,mark}.sh also read.
#
# Usage:  sh test/diff_compiler_parse.sh [file.mdk ...]
# Exit:   0 if every file's AST dump matches, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/parse_main"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

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
  golden="${f%.mdk}.parse.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh parse)"; fail=$((fail+1)); continue; }
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
