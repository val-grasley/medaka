#!/bin/sh
# Differential validation for the self-hosted parser's POSITION side channel
# (selfhost/positions_main.mdk: parse → parseWithPositions) against the OCaml
# reference dev/positions_dump.exe (lib/parser_state.ml's decl_positions /
# variant_lines / last_content_line, filled via lib/fmt.ml's tracking_token).
#
# Both dump three sections:
#   === DECLS ===     one "<line>:<end_line>" per top-level decl (source order)
#   === VARIANTS ===  start line of each `data` variant (flat, decl order)
#   === LASTLINE ===  last_content_line
#
# This proves the selfhost parser surfaces the same position channel
# lib/printer.ml's format_program buckets comments against — the prerequisite
# for porting the comment-preserving formatter (`medaka fmt`).  Positions are
# OUT OF BAND: the parsed token stream / AST is untouched (see the parse / parse-
# error / check harnesses, which must still pass byte-identical).
#
# Fixtures: test/positions_fixtures/*.mdk (multiple decls, multi-line decls,
# `data` decls with several variants, decls separated by blank lines, a mix).
#
# Usage:  sh test/diff_selfhost_positions.sh [file.mdk ...]
# Exit:   0 if every file's position dump matches, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
REF="$ROOT/_build/default/dev/positions_dump.exe"
POSMAIN="$ROOT/selfhost/positions_main.mdk"
FIXDIR="$ROOT/test/positions_fixtures"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
[ -x "$REF" ]  || { echo "build first: dune build --root . dev/positions_dump.exe"; exit 2; }

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
  actual="$("$MAIN" run "$POSMAIN" "$f" 2>/dev/null)"
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
