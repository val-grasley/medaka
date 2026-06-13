#!/bin/sh
# BOOTSTRAP (B6) — natively compiled self-hosted TYPECHECK stage == reference over
# typecheck_fixtures.  OCaml-free (REROOT-PLAN §2e): reference = committed golden
# captured from `main.exe run selfhost/entries/typecheck_main.mdk <fixture>`
# (test/capture_goldens.sh boot_typecheck); native = test/bin/typecheck_main.
# Strip the native trailing "()" before the diff.  See bootstrap_lex.sh.
#
# Usage:  sh test/bootstrap_typecheck.sh
# Exit:   0 all match; 2 oracle binary missing (run sh test/build_oracles.sh).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/typecheck_main"
FIXDIR="$ROOT/test/typecheck_fixtures"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

pass=0; fail=0
for fix in "$FIXDIR"/*.mdk; do
  [ -f "$fix" ] || continue
  name="$(basename "$fix")"
  golden="${fix%.mdk}.boot_typecheck.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (no .boot_typecheck.golden — run sh test/capture_goldens.sh boot_typecheck)\n' "$name"; continue
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
