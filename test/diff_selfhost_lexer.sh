#!/bin/sh
# Differential validation for the self-hosted Medaka lexer (compiler/frontend/lexer.mdk)
# against the OCaml reference.
#
# For each fixture in test/diff_fixtures/, run the Medaka lexer ON THE
# INTERPRETER over the fixture source and diff its token stream against the
# golden's `=== TOKENS ===` section (those goldens are produced by the OCaml
# `Lexer.tokenize_string` — see test/thorough/gen_golden.ml). As lib/lexer.mll
# is ported into compiler/frontend/lexer.mdk, fixtures flip from FAIL to ok; the port is
# done for this stage when all pass.
#
# Usage:  sh test/diff_compiler_lexer.sh
# Exit:   0 if every fixture matches, 1 otherwise.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/lex_main"
FIXDIR="$ROOT/test/diff_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# The native value entry auto-prints main's Unit return as a trailing "()"
# (runtime/medaka_rt.c) — appended to the final dump line (no newline) or as a
# sole "()" line.  The OCaml-captured golden has none; drop it.
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

# Normalize float-token text: collapse "FLOAT <value>" → "FLOAT" so that host
# float-formatting differences (OCaml %g "2" vs native "2.0") don't cause false
# failures.  This mirrors the normalization in diff_compiler_lex_files.sh.
norm() { sed 's/^FLOAT .*/FLOAT/'; }

# Extract the lines between '=== TOKENS ===' and the next '=== ' header.
golden_tokens() {
  awk '/^=== TOKENS ===$/ {f=1; next} /^=== / {f=0} f' "$1"
}

# Positive control: an empty source must lex to exactly "NEWLINE\nEOF". This
# proves the comparison reports `ok` correctly, independent of the fixture loop.
empty_src="$(mktemp)"; : > "$empty_src"
ctrl_actual="$("$RUN" "$empty_src" 2>/dev/null | strip_unit)"
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
  expected="$(golden_tokens "$golden" | norm)"
  actual="$("$RUN" "$mdk" 2>/dev/null | strip_unit | norm)"
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
