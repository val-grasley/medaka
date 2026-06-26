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
# #55 / task #11 (Num-polymorphic integer literals) CLOSED 2026-06-16: previously
# the native typecheck inferred `sum`/`product : a b -> b` where the OCaml golden
# had `a Int -> Int`, mismatching every fixture's whole-prelude TYPES dump.  Both
# the OCaml oracle (commit eac278b) and the compiler typecheck now infer the
# polymorphic `a b -> b` via Num-polymorphic literals + ambiguous-Num defaulting,
# so the goldens and the native typecheck agree — this gate is now all-pass.
#
# Usage:  sh test/diff_compiler_typecheck_golden.sh
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
[ "$fail" -eq 0 ]
