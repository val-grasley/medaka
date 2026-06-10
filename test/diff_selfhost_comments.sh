#!/bin/sh
# Differential validation for the self-hosted lexer's COMMENT side channel
# (selfhost/lex_comments_main.mdk: lex → collectComments) against the OCaml
# reference dev/comment_dump.exe (Lexer.tokenize_string → take_comments).
#
# Both dump one comment per line as "<line>:<col>:<text>" (1-based line, 0-based
# col, full lexeme incl. `--` / `{- … -}` delimiters; embedded newlines escaped
# to `\n`).  This proves the selfhost lexer surfaces the same comment channel
# lib/fmt.ml's format_program consumes — the prerequisite for porting the
# comment-preserving formatter.
#
# Fixtures: test/comment_fixtures/*.mdk (line/block/leading/trailing comments,
# comments between decls, nested blocks, comments inside strings — which must
# NOT be captured).
#
# Usage:  sh test/diff_selfhost_comments.sh [file.mdk ...]
# Exit:   0 if every file's comment dump matches, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
REF="$ROOT/_build/default/dev/comment_dump.exe"
CMTMAIN="$ROOT/selfhost/lex_comments_main.mdk"
FIXDIR="$ROOT/test/comment_fixtures"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
[ -x "$REF" ]  || { echo "build first: dune build --root . dev/comment_dump.exe"; exit 2; }

if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$FIXDIR/*.mdk"
fi

pass=0
fail=0
for f in $files; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  expected="$("$REF" "$f")"
  actual="$("$MAIN" run "$CMTMAIN" "$f" 2>/dev/null)"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$name"
    printf '  --- expected (lib/) ---\n%s\n  --- actual (selfhost) ---\n%s\n' "$expected" "$actual"
  fi
done

printf '\n%d matched, %d differing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
