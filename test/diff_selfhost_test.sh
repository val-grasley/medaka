#!/bin/sh
# Differential validation for the self-hosted `medaka test` machinery
# (selfhost/entries/test_main.mdk: doctest extraction + running + property tests).
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
#   test/selfhost_test_fixtures/mixed.mdk  passing + FAILING doctest + prop
#
# DEFERRED (pre-existing selfhost/native gaps, NOT gate-rerooting regressions):
#   stdlib/string.mdk  — full Unicode case-folding: native toUpper "Straße" yields
#     "STRAßE" not "STRASSE" (the native runtime's toUpper/toLower don't expand ß /
#     fold accented chars).  2 doctest FAILs vs the OCaml golden.
#   stdlib/{mut_array,array,map}.mdk — the #55 `$dict_sum_1` panic on the eval/test
#     path is FIXED (see test/selfhost_test_fixtures/sum_dict.mdk, now in the default
#     set, for the focused regression).  These full modules stay DEFERRED only for
#     OTHER reasons: array/mut_array carry props whose shrunk counterexamples are
#     RNG-draw-dependent (differ across impls), and map additionally needs the
#     hash-table work below.  `medaka test stdlib/{array,mut_array}.mdk` now run clean
#     end-to-end natively (no `$dict_*` unbound) — add to the gate once their props are
#     made RNG-independent (or trimmed to passing-only).
#   stdlib/hash_map.mdk / hash_set.mdk — need byte-identical hashInt/hashString
#     (SplitMix64 / FNV-1a) in the selfhost eval oracle (64-bit wrapping bitwise,
#     no Int64 extern yet).
#   error-path doctests — selfhost eval has no per-binding panic recovery.
#
# Passing props only (`OK (100 tests)` is RNG-independent); a failing prop's shrunk
# counterexample depends on the RNG draw, which differs across implementations.
#
# Usage:  sh test/diff_selfhost_test.sh [file.mdk ...]
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
         $ROOT/test/selfhost_test_fixtures/mixed.mdk \
         $ROOT/test/selfhost_test_fixtures/sum_dict.mdk \
         $ROOT/test/selfhost_test_fixtures/mappable_not_foldable.mdk \
         $ROOT/test/selfhost_test_fixtures/shadow_impl_tolist.mdk"
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
    printf '  --- expected (golden) ---\n%s\n  --- actual (selfhost) ---\n%s\n' "$expected" "$actual"
  fi
done

printf '\n%d matched, %d differing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
