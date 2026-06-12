#!/bin/sh
# Validation for selfhost/driver/diagnostics.mdk: compares structured diagnostic output
# against the OCaml reference (dev/diagdump.exe --analyze).
#
# The oracle strips source locations from messages (the selfhost AST is
# location-stripped and cannot reproduce them).  Both sides are sorted before
# comparison so ordering differences don't matter.
#
# Coverage:
#   • resolve_fixtures  — error accumulation (multiple errors, no exit-on-first)
#   • exhaust_fixtures  — guard-exhaustiveness warnings
#   • check_match_fixtures — non-exhaustive-match warnings
#   • clean programs    — no diagnostics expected (a sample from diff_fixtures)
#
# Parse-error fixtures are excluded: the selfhost parser panics on parse errors
# (returns List Decl, not Result) and cannot surface them as structured Diags.
# Type-error oracle/selfhost messages differ in unification order (pre-existing
# selfhost limitation) — excluded from this gate, covered by diff_selfhost_check.
#
# Usage: sh test/diff_selfhost_diagnostics.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
DIAG="$ROOT/_build/default/dev/diagdump.exe"
DIAG_MAIN="$ROOT/selfhost/diagnostics_main.mdk"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
[ -x "$MAIN" ] || { echo "build first: dune build --root ."; exit 2; }
pass=0; fail=0

run_case() {
  category="$1"; name="$2"; f="$3"
  oracle="$("$DIAG" --analyze "$f" 2>/dev/null | LC_ALL=C sort)"
  self="$("$MAIN" run "$DIAG_MAIN" "$RT" "$CORE" "$f" 2>/dev/null | LC_ALL=C sort)"
  if [ "$oracle" = "$self" ]; then
    pass=$((pass+1)); printf 'ok   %s/%s\n' "$category" "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s/%s\n' "$category" "$name"
    printf '  oracle: %s\n  self:   %s\n' "$oracle" "$self"
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

# clean programs — no diagnostics expected (spot-check)
for f in "$ROOT"/test/diff_fixtures/let_binding.mdk \
         "$ROOT"/test/diff_fixtures/basic_adt.mdk \
         "$ROOT"/test/diff_fixtures/records.mdk; do
  [ -f "$f" ] || continue
  run_case "clean" "$(basename "$f")" "$f"
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
