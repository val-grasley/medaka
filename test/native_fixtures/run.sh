#!/bin/sh
# Native-only regression assertions for two compiler lexer/parser fixes.
# Requires ./medaka built (FORCE_EMITTER_REBUILD=1 make medaka).
#   #2  `/=` → located, helpful error (not a mislocated "Parse error").
#   #3  multiline `let` RHS (bare-INDENT block) followed by `if/then/else`
#       must `check` cleanly (oracle accepts it; the bug was compiler-parser).
# These are NATIVE-ONLY: the frozen OCaml oracle mislocates #2 and accepts #3
# (so they are deliberately NOT in test/diff_fixtures/).
#
# ── THIS GATE RAN NOWHERE UNTIL 2026-07-13 (T8) ──────────────────────────────
#
# It is a real gate — 11 assertions, `exit $fail` — but nothing invoked it. Not
# run_gates.sh (which globs only `test/diff_compiler_*.sh`), not the Makefile, not
# ci.yml. And it lives one directory DOWN from test/, so even the coverage gate that
# polices "every gate must run in CI" could not see it: that gate enumerated
# `test/*.sh` + `test/wasm/*.sh`, and this is `test/native_fixtures/run.sh`.
#
# When it was finally run, it was RED — 9 ok, 2 failing — and had been for an unknown
# length of time. One failure was a REAL COMPILER BUG (see the EXPECTED-FAILURE ledger
# below); the other was a stale assertion in this file, pinning an em-dash the
# diagnostic no longer uses (the message itself is correct, and better). That is what
# a gate nobody runs decays into: you cannot tell the regression from the rot.
#
# ── EXPECTED-FAILURE LEDGER ──────────────────────────────────────────────────
#
# A LEDGER, NOT A SKIP-LIST (see test/CHECK-REMOVED-CONSTRUCTS-LEDGER.txt for the
# canonical statement). An assertion named in XFAIL below is expected to FAIL, for the
# stated reason. The gate diffs expectation against reality in BOTH directions:
#
#   an XFAIL assertion that PASSES  -> FAIL ("accidentally fixed — delete the entry")
#   any other assertion that FAILS  -> FAIL (an ordinary regression)
#
# The first direction is the one a skip-list structurally cannot see, and it is why
# this is a ledger. Every entry needs a reason and an owning task.
#
# (empty — method_shadow_run's T-12 entry was deleted when the S2 inversion landed.)
XFAIL=''

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
M="$ROOT/medaka"
FIX="$ROOT/test/native_fixtures"
[ -x "$M" ] || { echo "build ./medaka first: FORCE_EMITTER_REBUILD=1 make medaka"; exit 2; }

fail=0
xfail_ok=0        # ledgered failures that are still failing (as expected)
xfail_fixed=""    # ledgered failures that now PASS — the ledger is stale

is_xfail() { case " $XFAIL " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ok <assertion-name> / bad <assertion-name> <detail> — route each verdict through the
# ledger so an accidental fix is as loud as a regression.
ok() {
  if is_xfail "$1"; then
    xfail_fixed="$xfail_fixed $1"
    echo "XPASS $1 — ledgered as failing, but it PASSES now"
  else
    echo "ok   $1"
  fi
}
bad() {
  if is_xfail "$1"; then
    xfail_ok=$((xfail_ok + 1))
    echo "xfail $1 (known — see the EXPECTED-FAILURE ledger in this file)"
  else
    echo "FAIL $1: $2"; fail=$((fail + 1))
  fi
}

# #2: located error at the `/=` column with the hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/slasheq_error.mdk" 2>&1)"
case "$out" in
  *":7: unexpected '/='. (Did you mean '!='?)"*)
    ok slasheq_error ;;
  *) bad slasheq_error "got [$out]" ;;
esac

# #3: multiline let RHS + if/then/else checks cleanly (exit 0).
perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/let_multiline_rhs_if.mdk" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  ok let_multiline_rhs_if
else
  bad let_multiline_rhs_if "check returned non-zero"
fi

# method-name shadow (facet 1): a user top-level fn shadowing a prelude interface
# method (`eq`/`gt`) with applied-type params must `check` cleanly (exit 0).  The
# flat single-file path used to flatten core+user and let the user scheme shadow
# the method in core's own prop/`neq` bodies → spurious "List Int vs Int".  The
# oracle accepts it (method-marks the prop ref), so this is NATIVE-only assurance.
perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/method_shadow_check.mdk" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  ok method_shadow_check
else
  bad method_shadow_check "check returned non-zero"
fi

# method-name shadow (facet 2): a DIRECT call to the user's shadowing `eq` must
# resolve to the USER's definition on the EVAL path (run), matching build + the
# oracle, even though `List Int` HAS an `Eq` impl (the eval path used to arg-stamp
# the `Eq (List a)` impl → False; the user's `eq` returns True).
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" run "$FIX/method_shadow_run.mdk" 2>&1)"
case "$out" in
  True) ok method_shadow_run ;;
  *) bad method_shadow_run "expected True, got [$out]" ;;
esac

# inline-let missing-in: located error at the `let` keyword with a hint.
# Before the fix, native reported 2:0 ("if" line) with no hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/inline_let_missing_in.mdk" 2>&1)"
case "$out" in
  *"inline 'let' requires 'in'"*)
    ok inline_let_missing_in ;;
  *) bad inline_let_missing_in "got [$out]" ;;
esac

# arrayBlit + arraySetUnsafe in native interpreter: MutArray.push triggers both.
# Before the fix: "unbound identifier: arrayBlit" on the 3rd push (first grow).
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" run "$FIX/mut_array_push.mdk" 2>&1)"
case "$out" in
  ok) ok mut_array_push ;;
  *) bad mut_array_push "expected 'ok', got [$out]" ;;
esac

# PARSE-ERROR-LOCATION Stage 1 (caret) + Stage 2 (foreign-syntax hints).
# Each foreign-syntax mistake is located (dodging the old `1:0` collapse) with a
# beginner-grade hint, rendered through the shared caret block (a `^` line).

# Stage 2: C-style brace block on `if` — located at the `{` (col 15) with the hint,
# AND the Stage-1 caret block (the `^` line proves the snippet renderer fired).
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/brace_block_if.mdk" 2>&1)"
case "$out" in
  *":1:15: unexpected '{'"*"Medaka has no brace blocks"*"^"*)
    ok brace_block_if ;;
  *) bad brace_block_if "got [$out]" ;;
esac

# Stage 2: `for` loop — located at the `for` keyword with the recursion hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/for_loop.mdk" 2>&1)"
case "$out" in
  *"Medaka has no 'for' loops"*) ok for_loop ;;
  *) bad for_loop "got [$out]" ;;
esac

# Stage 2: `def` function header — located at the `def` keyword with the hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/def_keyword.mdk" 2>&1)"
case "$out" in
  *":1:0: Medaka has no 'def'"*) ok def_keyword ;;
  *) bad def_keyword "got [$out]" ;;
esac

# Stage 2: `/* … */` block comment — located at the `/` with the `{- -}`/`--` hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/block_comment.mdk" 2>&1)"
case "$out" in
  *"Medaka has no '/* … */' block comments"*)
    ok block_comment ;;
  *) bad block_comment "got [$out]" ;;
esac

# Stage 2: trailing `;` statement terminator — located at the `;` with the hint.
out="$(perl -e 'alarm 30; exec @ARGV' -- "$M" check "$FIX/semicolon_stmt.mdk" 2>&1)"
case "$out" in
  *"Medaka has no statement terminator ';'"*)
    ok semicolon_stmt ;;
  *) bad semicolon_stmt "got [$out]" ;;
esac

echo

# ── The ledger bites in BOTH directions ───────────────────────────────────────
# A regression fails. An ACCIDENTAL FIX also fails — an XFAIL entry that starts
# passing means the ledger is now a lie, and a lie nobody is forced to notice is
# exactly how a skip-list rots into permanent blindness.
if [ -n "$xfail_fixed" ]; then
  echo "FAIL: these assertions are ledgered as EXPECTED-FAILING, but they now PASS:"
  for a in $xfail_fixed; do echo "       $a"; done
  echo "       They got fixed. DELETE them from XFAIL at the top of this file (and"
  echo "       close the task named in the EXPECTED-FAILURE ledger there)."
  fail=$((fail + 1))
fi

if [ "$fail" -eq 0 ]; then
  echo "native_fixtures: PASS ($xfail_ok known-failing, ledgered)"
else
  echo "native_fixtures: FAILED ($fail)"
fi
exit $fail
