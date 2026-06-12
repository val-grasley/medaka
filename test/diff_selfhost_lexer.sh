#!/bin/sh
# Differential validation for the self-hosted Medaka lexer (selfhost/frontend/lexer.mdk)
# against the OCaml reference.
#
# For each fixture in test/diff_fixtures/, run the Medaka lexer ON THE
# INTERPRETER over the fixture source and diff its token stream against the
# golden's `=== TOKENS ===` section (those goldens are produced by the OCaml
# `Lexer.tokenize_string` — see test/thorough/gen_golden.ml). As lib/lexer.mll
# is ported into selfhost/frontend/lexer.mdk, fixtures flip from FAIL to ok; the port is
# done for this stage when all pass.
#
# Usage:  sh test/diff_selfhost_lexer.sh
# Exit:   0 if every fixture matches, 1 otherwise.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
FIXDIR="$ROOT/test/diff_fixtures"
LEXMAIN="$ROOT/selfhost/lex_main.mdk"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }

# Extract the lines between '=== TOKENS ===' and the next '=== ' header.
golden_tokens() {
  awk '/^=== TOKENS ===$/ {f=1; next} /^=== / {f=0} f' "$1"
}

# Positive control: an empty source must lex to exactly "NEWLINE\nEOF". This
# proves the comparison reports `ok` correctly, independent of the fixture loop.
empty_src="$(mktemp)"; : > "$empty_src"
ctrl_actual="$("$MAIN" run "$LEXMAIN" "$empty_src" 2>/dev/null)"
rm -f "$empty_src"
ctrl_expected="$(printf 'NEWLINE\nEOF')"
if [ "$ctrl_actual" = "$ctrl_expected" ]; then
  printf 'ok   <positive-control: empty source>\n'
else
  printf 'FAIL <positive-control: empty source>\n'
  printf '     expected: %s\n     actual:   %s\n' "$ctrl_expected" "$ctrl_actual"
fi

pass=0
fail=0
for mdk in "$FIXDIR"/*.mdk; do
  [ -f "$mdk" ] || continue
  base="$(basename "${mdk%.mdk}")"
  golden="${mdk%.mdk}.golden"
  [ -f "$golden" ] || continue
  expected="$(golden_tokens "$golden")"
  actual="$("$MAIN" run "$LEXMAIN" "$mdk" 2>/dev/null)"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$base"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$base"
  fi
done

printf '\n%d passed, %d failed (of %d fixtures)\n' "$pass" "$fail" "$((pass + fail))"
[ "$fail" -eq 0 ]
