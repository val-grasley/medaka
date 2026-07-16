#!/bin/sh
# Validation for compiler/driver/diagnostics.mdk: compares structured diagnostic
# output against a committed golden captured from dev/diagdump.exe --analyze.
#
# OCaml-free (REROOT-PLAN §2b): native host test/bin/diagnostics_main vs the
# committed <name>.analyze.golden (sorted diagdump --analyze output, captured by
# test/capture_goldens.sh).  The oracle strips source locations from messages
# (the compiler AST is location-stripped and cannot reproduce them).  Native
# output sorted before comparison.
#
# Coverage:
#   • resolve_fixtures  — error accumulation (multiple errors, no exit-on-first)
#   • exhaust_fixtures  — guard-exhaustiveness warnings
#   • check_match_fixtures — non-exhaustive-match warnings
#
# Parse-error fixtures are excluded: the compiler parser panics on parse errors.
# Type-error oracle/compiler messages differ in unification order (pre-existing
# compiler limitation) — excluded; covered by diff_compiler_check.
#
# Usage: sh test/diff_compiler_diagnostics.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/diagnostics_main"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
[ -x "$RUN" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$RUN") (missing $RUN)"; exit 2; }
pass=0; fail=0

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

run_case() {
  category="$1"; name="$2"; f="$3"
  golden="${f%.mdk}.analyze.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s/%s (no .analyze.golden — run sh test/capture_goldens.sh diag_analyze)\n' "$category" "$name"; return
  fi
  want="$(LC_ALL=C sort < "$golden")"
  self="$("$RUN" "$RT" "$CORE" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  if [ "$want" = "$self" ]; then
    pass=$((pass+1)); printf 'ok   %s/%s\n' "$category" "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s/%s\n' "$category" "$name"
    printf '  golden: %s\n  self:   %s\n' "$want" "$self"
  fi
}

# resolve fixtures — error accumulation
for f in "$ROOT"/test/resolve_fixtures/*.mdk; do
  run_case "resolve" "$(basename "$f")" "$f"
done

# exhaust fixtures — guard-exhaustiveness warnings
for f in "$ROOT"/test/exhaust_fixtures/*.mdk; do
  run_case "exhaust" "$(basename "$f")" "$f"
done

# check_match fixtures — non-exhaustive-match warnings
for f in "$ROOT"/test/check_match_fixtures/*.mdk; do
  run_case "check_match" "$(basename "$f")" "$f"
done

# clean programs — no diagnostics expected (spot-check; skipped if absent)
for f in "$ROOT"/test/diff_fixtures/let_binding.mdk \
         "$ROOT"/test/diff_fixtures/basic_adt.mdk \
         "$ROOT"/test/diff_fixtures/records.mdk; do
  [ -f "$f" ] || continue
  run_case "clean" "$(basename "$f")" "$f"
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
