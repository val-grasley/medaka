#!/bin/sh
# Native-only regression assertions for two compiler lexer/parser fixes.
# Requires ./medaka built (FORCE_EMITTER_REBUILD=1 make medaka).
#   #2  `/=` → located, helpful error (not a mislocated "Parse error").
#   #3  multiline `let` RHS (bare-INDENT block) followed by `if/then/else`
#       must `check` cleanly (oracle accepts it; the bug was compiler-parser).
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

# method-name shadow (facet 1): a user top-level fn shadowing a prelude interface
# method (`eq`/`gt`) with applied-type params must `check` cleanly (exit 0).  The
# flat single-file path used to flatten core+user and let the user scheme shadow
# the method in core's own prop/`neq` bodies → spurious "List Int vs Int".  The
# oracle accepts it (method-marks the prop ref), so this is NATIVE-only assurance.
perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/method_shadow_check.mdk" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "ok   method_shadow_check (user fn shadowing eq/gt checks)"
else
  echo "FAIL method_shadow_check: check returned non-zero"; fail=1
fi

# method-name shadow (facet 2): a DIRECT call to the user's shadowing `eq` must
# resolve to the USER's definition on the EVAL path (run), matching build + the
# oracle, even though `List Int` HAS an `Eq` impl (the eval path used to arg-stamp
# the `Eq (List a)` impl → False; the user's `eq` returns True).
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" run "$FIX/method_shadow_run.mdk" 2>&1)"
case "$out" in
  True) echo "ok   method_shadow_run (eval routes to user's eq, run==build==oracle)" ;;
  *) echo "FAIL method_shadow_run: expected True, got [$out]"; fail=1 ;;
esac

# inline-let missing-in: located error at the `let` keyword with a hint.
# Before the fix, native reported 2:0 ("if" line) with no hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/inline_let_missing_in.mdk" 2>&1)"
case "$out" in
  *"inline 'let' requires 'in'"*)
    echo "ok   inline_let_missing_in (located helpful diagnostic at let keyword)" ;;
  *) echo "FAIL inline_let_missing_in: got [$out]"; fail=1 ;;
esac

# arrayBlit + arraySetUnsafe in native interpreter: MutArray.push triggers both.
# Before the fix: "unbound identifier: arrayBlit" on the 3rd push (first grow).
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" run "$FIX/mut_array_push.mdk" 2>&1)"
case "$out" in
  ok) echo "ok   mut_array_push (arrayBlit + arraySetUnsafe in native interp)" ;;
  *) echo "FAIL mut_array_push: expected 'ok', got [$out]"; fail=1 ;;
esac

# PARSE-ERROR-LOCATION Stage 1 (caret) + Stage 2 (foreign-syntax hints).
# Each foreign-syntax mistake is located (dodging the old `1:0` collapse) with a
# beginner-grade hint, rendered through the shared caret block (a `^` line).

# Stage 2: C-style brace block on `if` — located at the `{` (col 15) with the hint,
# AND the Stage-1 caret block (the `^` line proves the snippet renderer fired).
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/brace_block_if.mdk" 2>&1)"
case "$out" in
  *":1:15: unexpected '{' — Medaka has no brace blocks"*"^"*)
    echo "ok   brace_block_if (located brace hint + caret)" ;;
  *) echo "FAIL brace_block_if: got [$out]"; fail=1 ;;
esac

# Stage 2: `for` loop — located at the `for` keyword with the recursion hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/for_loop.mdk" 2>&1)"
case "$out" in
  *"Medaka has no 'for' loops"*) echo "ok   for_loop (located for hint)" ;;
  *) echo "FAIL for_loop: got [$out]"; fail=1 ;;
esac

# Stage 2: `def` function header — located at the `def` keyword with the hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/def_keyword.mdk" 2>&1)"
case "$out" in
  *":1:0: Medaka has no 'def'"*) echo "ok   def_keyword (located def hint)" ;;
  *) echo "FAIL def_keyword: got [$out]"; fail=1 ;;
esac

# Stage 2: `/* … */` block comment — located at the `/` with the `{- -}`/`--` hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/block_comment.mdk" 2>&1)"
case "$out" in
  *"Medaka has no '/* … */' block comments"*)
    echo "ok   block_comment (located block-comment hint)" ;;
  *) echo "FAIL block_comment: got [$out]"; fail=1 ;;
esac

# Stage 2: trailing `;` statement terminator — located at the `;` with the hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/semicolon_stmt.mdk" 2>&1)"
case "$out" in
  *"Medaka has no statement terminator ';'"*)
    echo "ok   semicolon_stmt (located semicolon hint)" ;;
  *) echo "FAIL semicolon_stmt: got [$out]"; fail=1 ;;
esac

[ $fail -eq 0 ] && echo "all native_fixtures pass" || echo "native_fixtures FAILED"
exit $fail
