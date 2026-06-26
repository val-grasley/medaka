#!/bin/sh
# test/diff_compiler_check_json.sh — gate for `medaka check --json`.
#
# OCaml-free (LIB-REMOVAL-DESIGN §6 Stage A): compares ./medaka check --json
# <fixture> against a committed native golden
# (test/check_json_fixtures/<name>.check_json.golden), byte-identical per fixture,
# with the absolute fixture path replaced by a stable placeholder so the output
# is path-stable (no /Users/... in diffs).  The committed goldens were captured
# from the canonical native ./medaka — no live OCaml oracle.
#
# Fixtures: test/check_json_fixtures/
#   clean.mdk         — no errors → empty diagnostics array
#   type_mismatch.mdk — 1 + "x" → No impl of Num for String
#   no_impl.mdk       — debug of type with no Debug impl
#   multi_stmt.mdk    — multi-binding clean file
#   sig_mismatch.mdk  — signature mismatch (Int → String body)
#   parse_error.mdk / resolve_* — diagnostics surfaced by the native front end
#
# To regenerate the goldens: sh test/capture_goldens.sh check_json
#
# Usage:  sh test/diff_compiler_check_json.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="$ROOT/medaka"
FIXDIR="$ROOT/test/check_json_fixtures"

[ -x "$NATIVE" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }
[ -d "$FIXDIR" ] || { echo "FAIL: missing $FIXDIR"; exit 1; }

export MEDAKA_ROOT="$ROOT"

pass=0; fail=0

for mdk in "$FIXDIR"/*.mdk; do
  name="$(basename "$mdk" .mdk)"
  golden="${mdk%.mdk}.check_json.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (missing golden %s)\n' "$name" "$golden"; continue
  fi

  # Run native; replace the absolute path with a stable placeholder.
  tmpout="$(mktemp)"
  perl -e 'alarm 60; exec @ARGV' "$NATIVE" check --json "$mdk" > "$tmpout" 2>&1
  native_out="$(sed "s|$mdk|<fixture>|g" "$tmpout")"
  rm -f "$tmpout"
  ref_out="$(cat "$golden")"

  if [ "$native_out" = "$ref_out" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '  native: %s\n' "$native_out"
    printf '  golden: %s\n' "$ref_out"
  fi
done

echo ""
printf '%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
