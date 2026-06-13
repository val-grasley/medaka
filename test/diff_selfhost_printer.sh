#!/bin/sh
# Differential validation for the self-hosted pretty printer:
# selfhost/entries/printer_main.mdk (lex → parse → printer.programToString) vs the OCaml
# reference dev/print_probe.exe (parse → Printer.program_to_string).
#
# Both sides go parse → AST→source.  This isolates the printer: it diffs the
# AST→source rendering only, NOT the comment-interleaving format_program path
# (which depends on the lexer comment side-channel the self-host parser does not
# surface).  A byte-identical match means selfhost/tools/printer.mdk reproduces
# lib/printer.ml's layout, precedence, and spelling exactly.
#
# Runs over test/parse_fixtures/ — the same small corpus diff_selfhost_parse.sh
# uses.  FLOAT literal text would be normalized away (OCaml %g vs floatToString),
# like the parser/lexer harnesses, though no fixture currently contains a float
# literal.
#
# Usage:  sh test/diff_selfhost_printer.sh [file.mdk ...]
# Exit:   0 if every file's reprint matches, else 1.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/printer_main"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
# Printer output ends in a newline, so the "()" is a sole final line here.
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

# Normalize float-literal text (OCaml %g vs selfhost floatToString) so a float
# literal does not spuriously fail; no fixture exercises this today.
norm() { sed -E 's/-?[0-9]+\.[0-9eE+-]+/<F>/g'; }

if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$ROOT/test/parse_fixtures/*.mdk"
fi

pass=0
fail=0
for f in $files; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.printer.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh printer)"; fail=$((fail+1)); continue; }
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
