#!/bin/sh
# Differential validation for the self-hosted `medaka test` machinery
# (compiler/entries/test_main.mdk: doctest extraction + running + property tests).
#
# OCaml-free (REROOT-PLAN §2c): native host test/bin/test_main vs a committed
# golden captured from `main.exe test <f>` (test/capture_goldens.sh test).  Sibling
# golden: <fixture>.test.golden.  The native binary takes the SAME positional args
# as the interpreted entry did (runtime core file root); strip_unit drops its
# trailing "()" Unit auto-print before the compare.
#
# Each fixture's golden is the OCaml `medaka test` report — `running doctests in
# <f>`, one `ok`/`FAIL`/`ERROR` line per example (loc + input; FAIL adds
# expected/actual), the `<f>: P/T passed` summary, and for prop-bearing files the
# `Testing "<name>" ... OK (100 tests)` + `N passed, M failed` prop report.
#
# DEFAULT FIXTURE SCOPE — the modules the self-hosted test_main genuinely
# reproduces (native == interp == OCaml):
#   stdlib/core.mdk   core-as-prelude-AND-target: full doctest + prop suite
#   stdlib/json.mdk   multi-module doctests (imports list + string)
#   stdlib/toml.mdk   multi-module doctests (imports string)
#   stdlib/list.mdk   multi-module doctests + passing props
#   stdlib/set.mdk    single-file doctests + props (Set literal, EHeadAnnot)
#   test/compiler_test_fixtures/mixed.mdk  passing + FAILING doctest + prop
#   test/compiler_test_fixtures/blockquote_and_valid.mdk  GH #55: a malformed
#     example (Markdown blockquote) does not abort the file — the valid
#     examples before AND after it still run
#
# DEFERRED (pre-existing compiler/native gaps, NOT gate-rerooting regressions):
#   stdlib/string.mdk  — full Unicode case-folding: native toUpper "Straße" yields
#     "STRAßE" not "STRASSE" (the native runtime's toUpper/toLower don't expand ß /
#     fold accented chars).  2 doctest FAILs vs the OCaml golden.
#   stdlib/{mut_array,array,map}.mdk — the #55 `$dict_sum_1` panic on the eval/test
#     path is FIXED (see test/compiler_test_fixtures/sum_dict.mdk, now in the default
#     set, for the focused regression).  These full modules stay DEFERRED only for
#     OTHER reasons: array/mut_array carry props whose shrunk counterexamples are
#     RNG-draw-dependent (differ across impls), and map additionally needs the
#     hash-table work below.  `medaka test stdlib/{array,mut_array}.mdk` now run clean
#     end-to-end natively (no `$dict_*` unbound) — add to the gate once their props are
#     made RNG-independent (or trimmed to passing-only).
#   error-path doctests — compiler eval has no per-binding panic recovery.
#
# hash_map.mdk / hash_set.mdk (P0-10, un-deferred): the interpreter (compiler
# eval.mdk) previously had no hashInt/hashString/etc externs at all — `medaka run`
# panicked "unbound identifier: hashString" before any doctest could execute.
# Fixed by binding a simple deterministic interpreter-local hasher (xorshift for
# Int/Char/Bool, FNV-1a for Float/String bytes, masked to [0, 2^30)) — NOT
# byte-identical to the native runtime's SplitMix64/FNV-1a (mdk_hash_*), which
# hash_map/hash_set never need: `hash key % cap` only has to be INTRA-engine
# consistent, and every doctest in these two files asserts on size/get/has/eq/
# keys/values results, never on raw bucket layout, so cross-engine hash identity
# is not gate-observable. Both files' doctests are in the default set now.
#
# Passing props only (`OK (100 tests)` is RNG-independent); a failing prop's shrunk
# counterexample depends on the RNG draw, which differs across implementations.
#
# Usage:  sh test/diff_compiler_test.sh [file.mdk ...]
# Exit:   0 if every fixture's native report matches its golden;
#         2 if the oracle binary is missing (run sh test/build_oracles.sh first).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/test_main"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit auto-print; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$ROOT/stdlib/core.mdk \
         $ROOT/stdlib/json.mdk \
         $ROOT/stdlib/toml.mdk \
         $ROOT/stdlib/list.mdk \
         $ROOT/stdlib/set.mdk \
         $ROOT/stdlib/async.mdk \
         $ROOT/stdlib/byteparser.mdk \
         $ROOT/stdlib/bytebuilder.mdk \
         $ROOT/stdlib/hash_map.mdk \
         $ROOT/stdlib/hash_set.mdk \
         $ROOT/test/compiler_test_fixtures/mixed.mdk \
         $ROOT/test/compiler_test_fixtures/sum_dict.mdk \
         $ROOT/test/compiler_test_fixtures/mappable_not_foldable.mdk \
         $ROOT/test/compiler_test_fixtures/shadow_impl_tolist.mdk \
         $ROOT/test/compiler_test_fixtures/blockquote_and_valid.mdk"
fi

pass=0
fail=0
for f in $files; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.test.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (no .test.golden — run sh test/capture_goldens.sh test)\n' "$name"; continue
  fi
  root="$(dirname "$f")"
  expected="$(cat "$golden")"
  actual="$("$RUN" "$RUNTIME" "$CORE" "$f" "$root" 2>/dev/null | sed "s#$ROOT/##g" | strip_unit)"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$name"
    printf '  --- expected (golden) ---\n%s\n  --- actual (compiler) ---\n%s\n' "$expected" "$actual"
  fi
done

# P0-6 regression: `medaka test` must exit nonzero iff any doctest/prop FAILED
# or ERRORED (a printed "N passed, M failed" report used to always exit 0 —
# a CI trap). test/bin/test_main is the native-built oracle for
# compiler/entries/test_main.mdk, so it carries the same exit-code fix.
"$RUN" "$RUNTIME" "$CORE" "$ROOT/test/compiler_test_fixtures/mixed.mdk" "$ROOT/test/compiler_test_fixtures" >/dev/null 2>&1
mixed_code=$?
if [ "$mixed_code" -ne 0 ]; then
  pass=$((pass + 1)); printf 'ok   mixed.mdk exit code (%d != 0, has a FAILing doctest)\n' "$mixed_code"
else
  fail=$((fail + 1)); printf 'FAIL mixed.mdk exit code: expected nonzero (has a failing doctest), got 0\n'
fi

"$RUN" "$RUNTIME" "$CORE" "$ROOT/stdlib/list.mdk" "$ROOT/stdlib" >/dev/null 2>&1
list_code=$?
if [ "$list_code" -eq 0 ]; then
  pass=$((pass + 1)); printf 'ok   list.mdk exit code (0, all-passing suite)\n'
else
  fail=$((fail + 1)); printf 'FAIL list.mdk exit code: expected 0 (all-passing), got %d\n' "$list_code"
fi

# `test "…" = <Expectation>` runner regression (Phase 127 restored 2026-07-11):
# discovery + eval + per-test report + summary + exit code.  The fixture imports
# `test` (in stdlib), so stdlib must be a search root alongside the fixture dir.
td="$ROOT/test/compiler_test_fixtures/test_decls.mdk"
td_out="$("$RUN" "$RUNTIME" "$CORE" "$td" "$ROOT/test/compiler_test_fixtures" "$ROOT/stdlib" 2>/dev/null | sed "s#$ROOT/##g")"
td_code=0
"$RUN" "$RUNTIME" "$CORE" "$td" "$ROOT/test/compiler_test_fixtures" "$ROOT/stdlib" >/dev/null 2>&1 || td_code=$?
td_expected="running tests in test/compiler_test_fixtures/test_decls.mdk
  ok   test/compiler_test_fixtures/test_decls.mdk:8: passing assertion
  FAIL test/compiler_test_fixtures/test_decls.mdk:9: failing assertion
       expected 1 but got 2
  FAIL test/compiler_test_fixtures/test_decls.mdk:10: explicit fail
       boom

test/compiler_test_fixtures/test_decls.mdk: 1/3 passed (2 failed, 0 errors)"
if printf '%s' "$td_out" | grep -qF "$td_expected"; then
  pass=$((pass + 1)); printf 'ok   test_decls.mdk (test-decl runner: discovery + ok/FAIL report + summary)\n'
else
  fail=$((fail + 1)); printf 'FAIL test_decls.mdk report mismatch\n  --- expected ---\n%s\n  --- actual ---\n%s\n' "$td_expected" "$td_out"
fi
if [ "$td_code" -ne 0 ]; then
  pass=$((pass + 1)); printf 'ok   test_decls.mdk exit code (%d != 0, has FAILing tests)\n' "$td_code"
else
  fail=$((fail + 1)); printf 'FAIL test_decls.mdk exit code: expected nonzero (has failing tests), got 0\n'
fi

# Issue #416 (S1): a NEGATIVE hash from a contract-compliant `Hashable` impl (the
# contract requires eq-agreement ONLY, not non-negativity) used to reach a negative
# bucket index and an OOB `arrayGetUnsafe` in hash_map/hash_set `slotOf` — under
# eval a misleading "no matching impl for dispatch" panic, and once BUILT a
# segfault.  This is the EVAL-side guard; the native one is
# test/build_diff_fixtures/hash_negative_hash.mdk (diff_compiler_build.sh).
# Like test_decls above it imports stdlib (`test`, `hash_map`, `hash_set`), so
# stdlib must be a search root alongside the fixture dir — hence a bespoke block
# rather than a row in the single-root $files loop.
nh="$ROOT/test/compiler_test_fixtures/hash_negative_hash.mdk"
nh_out="$("$RUN" "$RUNTIME" "$CORE" "$nh" "$ROOT/test/compiler_test_fixtures" "$ROOT/stdlib" 2>/dev/null | sed "s#$ROOT/##g")"
nh_expected="running doctests in test/compiler_test_fixtures/hash_negative_hash.mdk
  (no doctests found)
running tests in test/compiler_test_fixtures/hash_negative_hash.mdk
  ok   test/compiler_test_fixtures/hash_negative_hash.mdk:32: hash_map: negative hash finds its key (#416)
  ok   test/compiler_test_fixtures/hash_negative_hash.mdk:35: hash_set: negative hash finds its element (#416)
  ok   test/compiler_test_fixtures/hash_negative_hash.mdk:38: hash_map: intMinBound hash (#416)
  ok   test/compiler_test_fixtures/hash_negative_hash.mdk:40: hash_set: intMinBound hash (#416)

test/compiler_test_fixtures/hash_negative_hash.mdk: 4/4 passed"
if [ "$nh_out" = "$nh_expected" ]; then
  pass=$((pass + 1)); printf 'ok   hash_negative_hash.mdk (#416: negative Hashable hash does not OOB the bucket array)\n'
else
  fail=$((fail + 1)); printf 'FAIL hash_negative_hash.mdk report mismatch\n  --- expected ---\n%s\n  --- actual ---\n%s\n' "$nh_expected" "$nh_out"
fi

printf '\n%d matched, %d differing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
