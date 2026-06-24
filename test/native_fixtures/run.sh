#!/bin/sh
# Native-only regression assertions for two selfhost lexer/parser fixes.
# Requires ./medaka built (FORCE_EMITTER_REBUILD=1 make medaka).
#   #2  `/=` → located, helpful error (not a mislocated "Parse error").
#   #3  multiline `let` RHS (bare-INDENT block) followed by `if/then/else`
#       must `check` cleanly (oracle accepts it; the bug was selfhost-parser).
# These are NATIVE-ONLY: the frozen OCaml oracle mislocates #2 and accepts #3
# (so they are deliberately NOT in test/diff_fixtures/).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
M="$ROOT/medaka"
FIX="$ROOT/test/native_fixtures"
[ -x "$M" ] || { echo "build ./medaka first: FORCE_EMITTER_REBUILD=1 make medaka"; exit 2; }

fail=0

# #2: located error at the `/=` column with the hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/slasheq_error.mdk" 2>&1)"
case "$out" in
  *":7: unexpected '/=' (did you mean '!=' for not-equal?)"*)
    echo "ok   slasheq_error (located /= diagnostic)" ;;
  *) echo "FAIL slasheq_error: got [$out]"; fail=1 ;;
esac

# #3: multiline let RHS + if/then/else checks cleanly (exit 0).
perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/let_multiline_rhs_if.mdk" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "ok   let_multiline_rhs_if (indented let RHS parses)"
else
  echo "FAIL let_multiline_rhs_if: check returned non-zero"; fail=1
fi

[ $fail -eq 0 ] && echo "all native_fixtures pass" || echo "native_fixtures FAILED"
exit $fail
