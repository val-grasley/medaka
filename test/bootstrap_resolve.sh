#!/bin/sh
# BOOTSTRAP (B4) — natively compiled self-hosted RESOLVE stage == reference over
# resolve_fixtures.  OCaml-free (REROOT-PLAN §2e): reference = committed golden
# captured from `main.exe run selfhost/entries/resolve_main.mdk runtime core <fixture>`
# (test/capture_goldens.sh boot_resolve); native = test/bin/resolve_main with the
# SAME positional args (runtime core fixture).  Strip the native trailing "()"
# before the diff.  See bootstrap_lex.sh for the full rationale.
#
# Usage:  sh test/bootstrap_resolve.sh
# Exit:   0 all match; 2 oracle binary missing (run sh test/build_oracles.sh).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/resolve_main"
FIXDIR="$ROOT/test/resolve_fixtures"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

pass=0; fail=0
for fix in "$FIXDIR"/*.mdk; do
  [ -f "$fix" ] || continue
  name="$(basename "$fix")"
  golden="${fix%.mdk}.boot_resolve.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (no .boot_resolve.golden — run sh test/capture_goldens.sh boot_resolve)\n' "$name"; continue
  fi
  ref="$(cat "$golden")"
  self="$("$RUN" "$RUNTIME" "$CORE" "$fix" 2>/dev/null | strip_unit)"
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
