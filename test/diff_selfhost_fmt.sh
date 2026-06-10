#!/bin/sh
# Differential validation for the self-hosted comment-preserving formatter:
# selfhost/fmt_main.mdk (parseWithPositions + collectComments → fmt.formatProgram,
# a port of lib/printer.ml's `format_program`) vs the OCaml `medaka fmt --stdout`
# oracle (the same `format_program`, driven by lib/fmt.ml).
#
# Unlike diff_selfhost_printer.sh (which isolates the AST→source core), this gate
# exercises the COMMENT-INTERLEAVING path: leading/standalone comments with
# blank-line gaps, trailing inline comments, between-decl comments, interior
# `data`-variant comments, and block comments.
#
# Runs over test/fmt_fixtures/ (comment-heavy cases authored for this gate) plus
# test/parse_fixtures/ (the comment-FREE corpus the other selfhost gates use —
# confirms the no-comment path stays byte-identical too).
#
# Usage:  sh test/diff_selfhost_fmt.sh [file.mdk ...]
# Exit:   0 if every file's formatting matches, else 1.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
FMTMAIN="$ROOT/selfhost/fmt_main.mdk"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }

# Normalize float-literal text (OCaml %g vs selfhost floatToString) so a float
# literal does not spuriously fail; matches the other selfhost gates.
norm() { sed -E 's/-?[0-9]+\.[0-9eE+-]+/<F>/g'; }

if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$ROOT/test/fmt_fixtures/*.mdk $ROOT/test/parse_fixtures/*.mdk"
fi

pass=0
fail=0
for f in $files; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  expected="$("$MAIN" fmt --stdout "$f" 2>/dev/null | norm)"
  actual="$("$MAIN" run "$FMTMAIN" "$f" 2>/dev/null | norm)"
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
