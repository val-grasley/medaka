#!/bin/sh
# Differential validation for the self-hosted type-aware MATCH-exhaustiveness
# check (`check_match` in lib/exhaust.ml, invoked per EMatch from typecheck).
#
# Oracle: dev/diagdump.exe --check-match  (parse → Desugar →
# Typecheck.check_program_no_prelude; keeps ONLY the non-exhaustive-MATCH
# warnings — guard/clause/redundancy warnings filtered out — sorted, with the
# location prefix stripped).
# NOTE: this is the type-aware counterpart of diff_selfhost_exhaust.sh (which
# covers the standalone GUARD-coverage pass on the raw AST).
#
# Two checks per fixture in test/check_match_fixtures/ (each a .mdk with a
# committed <name>.expected golden — the non-exhaustive fixtures hold one
# warning, the exhaustive controls hold an empty golden):
#   A. reference stability — diagdump output must equal the committed golden.
#   B. if selfhost/check_match_main.mdk exists — the self-hosted check's output
#      (sorted) must equal the same golden.
#
# Usage:  sh test/diff_selfhost_check_match.sh
# Exit:   0 if every fixture passes (B skipped until the selfhost side lands).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIAG="$ROOT/_build/default/dev/diagdump.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
SELFMAIN="$ROOT/selfhost/check_match_main.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/check_match_fixtures"

[ -x "$DIAG" ] || { echo "build first: dune build --root . (missing $DIAG)"; exit 2; }

have_self=0
[ -f "$SELFMAIN" ] && have_self=1
[ "$have_self" -eq 0 ] && echo "note: selfhost/check_match_main.mdk not yet ported — checking reference vs goldens only."

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="$(cat "${f%.mdk}.expected")"
  ref="$("$DIAG" --check-match "$f" 2>/dev/null)"
  ok=1
  [ "$ref" = "$golden" ] || { ok=0; reason="reference drifted from golden"; }
  if [ "$ok" -eq 1 ] && [ "$have_self" -eq 1 ]; then
    self="$("$MAIN" run "$SELFMAIN" "$RUNTIME" "$f" 2>/dev/null | LC_ALL=C sort)"
    [ "$self" = "$golden" ] || { ok=0; reason="selfhost differs from reference"; }
  fi
  if [ "$ok" -eq 1 ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s (%s)\n' "$name" "$reason"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
