#!/bin/sh
# Self-lex validation: run the self-hosted Medaka lexer over REAL .mdk source
# (the stdlib + the lexer itself) and diff its token stream against the OCaml
# reference lexer (dev/lextok.exe).  This is a far stronger test than the curated
# test/diff_fixtures/ corpus — it exercises whatever real code actually uses
# (block comments, the full operator set, …).
#
# FLOAT literal *rendering* is normalized away: OCaml's `token_to_string` prints
# floats with `%g` while Medaka prints them with `floatToString`, so `1.0` shows
# as `FLOAT 1` vs `FLOAT 1.`.  The TFloat token (value + position) is identical —
# this is a host float-formatting difference, not a lexer defect — so we compare
# float token *presence* but not its rendered text.  Any reported diff is a real
# token-kind/position divergence.
#
# Usage:  sh test/diff_selfhost_lex_files.sh [file.mdk ...]
# Exit:   0 if every file's token stream matches (modulo float text), else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
REF="$ROOT/_build/default/dev/lextok.exe"
LEXMAIN="$ROOT/selfhost/lex_main.mdk"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
[ -x "$REF" ]  || { echo "build first: dune build --root . dev/lextok.exe"; exit 2; }

norm() { sed 's/^FLOAT .*/FLOAT/'; }

if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$ROOT/selfhost/lexer.mdk"
  for f in core list array string map set io hash_map hash_set mut_array json test; do
    files="$files $ROOT/stdlib/$f.mdk"
  done
fi

pass=0
fail=0
for f in $files; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  expected="$("$REF" "$f" | norm)"
  actual="$("$MAIN" run "$LEXMAIN" "$f" 2>/dev/null | norm)"
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
