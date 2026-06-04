#!/bin/sh
# Full-prelude validation for the self-hosted TYPECHECK stage: type-check
# core.mdk + each diff_fixtures program and match the committed === TYPES ===
# golden (the reference's whole-program inference: the entire prelude's schemes
# plus the user program's), byte-for-byte.
#
# Self-host: typecheck_main.mdk seeds runtime.mdk's externs, then infers schemes
# for (core.mdk ++ fixture). Both sides sorted before compare.
#
# Usage:  sh test/diff_selfhost_typecheck_golden.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
SELF="$ROOT/selfhost/typecheck_main.mdk"
CORE="$ROOT/stdlib/core.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/diff_fixtures"
[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
tmp="$(mktemp)"
pass=0; fail=0
for g in "$FIXDIR"/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$FIXDIR/$fix.mdk" ] || continue
  cat "$CORE" "$FIXDIR/$fix.mdk" > "$tmp"
  self="$("$MAIN" run "$SELF" "$RUNTIME" "$tmp" 2>/dev/null | LC_ALL=C sort)"
  golden="$(sed -n '/=== TYPES ===/,/=== EVAL ===/p' "$g" | sed '1d;$d' | LC_ALL=C sort)"
  if [ "$golden" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$fix"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$fix"; fi
done
rm -f "$tmp"
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
