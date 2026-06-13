#!/bin/sh
# Full-prelude validation for the self-hosted TYPECHECK stage: type-check
# core.mdk + each diff_fixtures program and match the committed === TYPES ===
# golden (the reference's whole-program inference: the entire prelude's schemes
# plus the user program's), byte-for-byte.
#
# OCaml-free (REROOT-PLAN §2b): native host test/bin/typecheck_main seeds
# runtime.mdk's externs, then infers schemes for (core.mdk ++ fixture); compared
# to the FROZEN === TYPES === section of the committed diff_fixtures/*.golden
# (no live OCaml re-derivation).  Both sides sorted.
#
# KNOWN PRE-EXISTING DIVERGENCE (#55, tracked by task #11 / Num-poly-literals):
# the native typecheck infers `sum`/`product : a b -> b` where the golden (OCaml)
# has `a Int -> Int`.  That prelude scheme appears in EVERY fixture's whole-prelude
# TYPES dump, so ALL 25 fixtures MISMATCH on those two lines — 0 ok, 25 failing
# is the CORRECT, documented state, identical to the pre-re-root behavior (the
# OCaml-host leg failed the same 25).  Do NOT "fix" by editing goldens/fixtures.
#
# Usage:  sh test/diff_selfhost_typecheck_golden.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/typecheck_main"
CORE="$ROOT/stdlib/core.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/diff_fixtures"
[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

tmp="$(mktemp)"
pass=0; fail=0
for g in "$FIXDIR"/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$FIXDIR/$fix.mdk" ] || continue
  cat "$CORE" "$FIXDIR/$fix.mdk" > "$tmp"
  self="$("$RUN" "$RUNTIME" "$tmp" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  golden="$(sed -n '/=== TYPES ===/,/=== EVAL ===/p' "$g" | sed '1d;$d' | LC_ALL=C sort)"
  if [ "$golden" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$fix"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$fix"; fi
done
rm -f "$tmp"
printf '\n%d ok, %d failing\n' "$pass" "$fail"
printf '(NOTE: all-fail is the documented #55 sum/product drift, task #11 — not a regression)\n'
[ "$fail" -eq 0 ]
