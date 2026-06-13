#!/bin/sh
# BOOTSTRAP (B2) — natively compiled self-hosted PARSE stage == reference parser
# over parse_fixtures.  OCaml-free (REROOT-PLAN §2e): reference = committed golden
# captured from `main.exe run selfhost/entries/parse_main.mdk <fixture>`
# (test/capture_goldens.sh boot_parse); native = test/bin/parse_main (the
# parse_main entry native-compiled by `./medaka build`, test/build_oracles.sh).
# The native runtime auto-prints main's Unit value as a trailing "()"; strip it
# before the diff.  See bootstrap_lex.sh for the full rationale.
#
# Usage:  sh test/bootstrap_parse.sh
# Exit:   0 all match; 2 oracle binary missing (run sh test/build_oracles.sh).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/parse_main"
FIXDIR="$ROOT/test/parse_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

pass=0; fail=0
for fix in "$FIXDIR"/*.mdk; do
  [ -f "$fix" ] || continue
  name="$(basename "$fix")"
  golden="${fix%.mdk}.boot_parse.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (no .boot_parse.golden — run sh test/capture_goldens.sh boot_parse)\n' "$name"; continue
  fi
  ref="$(cat "$golden")"
  self="$("$RUN" "$fix" 2>/dev/null | strip_unit)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '%s' "$ref"  > "$ROOT/.boot_ref.$$"
    printf '%s' "$self" > "$ROOT/.boot_self.$$"
    diff "$ROOT/.boot_ref.$$" "$ROOT/.boot_self.$$" | head -20 | sed 's/^/    /'
    rm -f "$ROOT/.boot_ref.$$" "$ROOT/.boot_self.$$"
  fi
done

printf '\n%d ok, %d failing (of %d)\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
