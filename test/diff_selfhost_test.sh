#!/bin/sh
# Differential validation for the self-hosted `medaka test` machinery
# (selfhost/test_main.mdk: doctest extraction + running + property tests)
# against the OCaml reference `medaka test <file>` (Test_cmd + Doctest +
# Prop_runner).
#
# For each fixture the two emit the same doctest report — `running doctests in
# <f>`, one `ok`/`FAIL`/`ERROR` line per example (with the same loc + input,
# and for FAIL the same expected/actual), the `<f>: P/T passed[ (F failed, E
# errors)]` summary — and, for files declaring props, the same prop report
# (`Testing "<name>" ... OK (100 tests)` + `N passed, M failed`).
#
# Coverage spans BOTH Phase-92 doctest paths and the prop phase:
#   stdlib/string.mdk    single-file doctests (block-comment examples)
#   stdlib/mut_array.mdk single-file doctests
#   stdlib/array.mdk     single-file doctests + props (needs the arrayCopy oracle
#                        extern in selfhost/eval/eval.mdk)
#   stdlib/map.mdk       single-file doctests + props (Map literal head-pins via
#                        the EHeadAnnot infer arm in selfhost/types/typecheck.mdk)
#   stdlib/set.mdk       single-file doctests + props (Set literal, EHeadAnnot)
#   stdlib/json.mdk      multi-module doctests (imports list + string)
#   stdlib/toml.mdk      multi-module doctests (imports string)
#   stdlib/list.mdk      multi-module doctests + passing PROPS
#   stdlib/core.mdk      core-as-prelude-AND-target (programIsCore): full doctest
#                        + prop suite, all passing props
#   test/selfhost_test_fixtures/mixed.mdk
#                        single-file: passing + FAILING doctest + block-comment
#                        + a passing prop (exercises the FAIL report path)
#
# STILL OUT OF SCOPE (selfhost-pipeline capability gaps, not doctest-machinery):
#   stdlib/hash_map.mdk / hash_set.mdk — need byte-identical hashInt/hashString
#     (SplitMix64 / FNV-1a) in the selfhost eval oracle.  Those algorithms require
#     64-bit wrapping bitwise xor/shift, which selfhost Medaka has no extern for
#     (Int is 63-bit, no bitwise / Int64).  The doctests render keys/values/debug
#     in hash order, so a non-identical hash diverges.  Needs a new bitwise/Int64
#     extern (add-primitive) before these can join the fixture set.
#   error-path doctests — a doctest whose evaluation panics.  OCaml's
#     eval_suppressed traps the per-binding panic (native `try ... with`) and
#     reports one `ERROR` line; the selfhost eval oracle has no panic-catch
#     primitive, so a panic aborts the whole run.  Needs a recover/try capability.
#
# Property output is matched only for PASSING props (`OK (100 tests)` is
# RNG-independent).  A FAILING prop's shrunk counterexample depends on the draw,
# which differs across the three RNGs in play (the reference externs' SplitMix64,
# OCaml's `Random` module in Prop_runner, and selfhost eval's LCG), so failing
# props are intentionally not in the fixture set.  Likewise an ERROR-path
# doctest (one whose evaluation panics) is out of scope: the selfhost eval
# oracle has no per-binding exception recovery, so a panic aborts the run rather
# than reporting one `ERROR` line — see selfhost/README.md / the port report.
#
# Usage:  sh test/diff_selfhost_test.sh [file.mdk ...]
# Exit:   0 if every fixture's `medaka test` output matches, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
TESTMAIN="$ROOT/selfhost/test_main.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }

if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$ROOT/stdlib/core.mdk \
         $ROOT/stdlib/string.mdk \
         $ROOT/stdlib/mut_array.mdk \
         $ROOT/stdlib/json.mdk \
         $ROOT/stdlib/toml.mdk \
         $ROOT/stdlib/list.mdk \
         $ROOT/stdlib/array.mdk \
         $ROOT/stdlib/map.mdk \
         $ROOT/stdlib/set.mdk \
         $ROOT/test/selfhost_test_fixtures/mixed.mdk"
fi

pass=0
fail=0
for f in $files; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  # The reference resolves siblings relative to the file's project root; the
  # selfhost driver needs the import root passed explicitly.  Pass the file's
  # directory as the sole root (stdlib siblings / self-contained fixtures).
  root="$(dirname "$f")"
  expected="$("$MAIN" test "$f" 2>/dev/null)"
  actual="$("$MAIN" run "$TESTMAIN" "$RUNTIME" "$CORE" "$f" "$root" 2>/dev/null)"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$name"
    printf '  --- expected (medaka test) ---\n%s\n  --- actual (selfhost) ---\n%s\n' "$expected" "$actual"
  fi
done

printf '\n%d matched, %d differing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
