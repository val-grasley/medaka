#!/bin/sh
# Differential validation for the self-hosted lexer's COMMENT side channel
# (selfhost/entries/lex_comments_main.mdk: lex → collectComments) against the OCaml
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
RUN="$ROOT/test/bin/lex_comments_main"
FIXDIR="$ROOT/test/comment_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

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
  golden="${f%.mdk}.comments.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh comments)"; fail=$((fail+1)); continue; }
  expected="$(cat "$golden")"
  actual="$("$RUN" "$f" 2>/dev/null | strip_unit)"
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
