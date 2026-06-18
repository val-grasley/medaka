#!/bin/sh
# test/diff_selfhost_check_json.sh — differential gate for `medaka check --json`.
#
# Compares ./medaka check --json <fixture> against the OCaml oracle
# _build/default/bin/main.exe check --json <fixture>, byte-identical per fixture,
# with the absolute fixture path replaced by a stable placeholder so the output
# is path-stable (no /Users/... in diffs).
#
# Fixtures: test/check_json_fixtures/
#   clean.mdk       — no errors → empty diagnostics array
#   type_mismatch.mdk — 1 + "x" → No impl of Num for String
#   no_impl.mdk     — debug of type with no Debug impl
#   multi_stmt.mdk  — multi-binding clean file
#   sig_mismatch.mdk — signature mismatch (Int → String body)
#
# NOTE: parse-error fixtures are excluded — the selfhost parser produces a
# different error message ("parse error" lowercase vs "Parse error") and a
# different line number than the OCaml oracle.  This is a pre-existing
# divergence in the selfhost parser, not a check --json issue.
#
# Usage:  sh test/diff_selfhost_check_json.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="$ROOT/medaka"
ORACLE="$ROOT/_build/default/bin/main.exe"
FIXDIR="$ROOT/test/check_json_fixtures"
RT="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

[ -x "$NATIVE" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }
[ -x "$ORACLE" ] || { echo "SKIP: OCaml oracle not built — run: dune build --root $ROOT"; exit 2; }
[ -d "$FIXDIR" ] || { echo "FAIL: missing $FIXDIR"; exit 1; }

export MEDAKA_ROOT="$ROOT"

pass=0; fail=0

for mdk in "$FIXDIR"/*.mdk; do
  name="$(basename "$mdk" .mdk)"

  # Run both sides; replace the absolute path with a stable placeholder.
  native_out="$(perl -e 'alarm 60; exec @ARGV' \
      "$NATIVE" check --json "$mdk" 2>&1 | sed "s|$mdk|<fixture>|g")"
  oracle_out="$(perl -e 'alarm 60; exec @ARGV' \
      "$ORACLE" check --json "$mdk" 2>&1 | sed "s|$mdk|<fixture>|g")"

  if [ "$native_out" = "$oracle_out" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '  native: %s\n' "$native_out"
    printf '  ocaml:  %s\n' "$oracle_out"
  fi
done

echo ""
printf '%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
