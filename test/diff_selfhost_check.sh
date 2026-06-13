#!/bin/sh
# Validation for the COMPOSED self-hosted front-end (selfhost/tools/check.mdk): one
# driver runs parse → desugar → resolve → exhaust → typecheck and must reproduce
# each stage's oracle depending on the input category:
#   • diff_fixtures (clean, prelude-using) → the FROZEN === TYPES === golden (full
#     prelude + user schemes), proving resolve+exhaust pass and typecheck runs;
#   • resolve_fixtures (broken)            → the committed resolve diagnostics
#     golden <name>.expected (== dev/diagdump.exe --resolve at capture), proving
#     the driver routes resolve errors;
#   • import_error_fixtures (bad imports)  → committed .expected golden
#     (UnknownModule S-expression), proving R3: bad imports halt with the right
#     error category rather than falling through to a spurious typecheck error.
# Both sides sorted before compare.
#
# OCaml-free (REROOT-PLAN §2b): native host test/bin/check_main; every oracle leg
# is a committed golden (no live main.exe / diagdump re-derivation).
#
# KNOWN PRE-EXISTING DIVERGENCE (#55, tracked by task #11): the TYPES leg's golden
# prelude has `sum`/`product : a Int -> Int`; the native check infers `a b -> b`,
# so all 25 diff_fixtures TYPES checks MISMATCH — the resolve (14) + import_error (1)
# legs pass.  Expected ~15 ok, 25 failing, identical to the pre-re-root behavior.
# Do NOT alter goldens/fixtures to make the 25 pass.
#
# Usage:  sh test/diff_selfhost_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/test/bin/check_main"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
[ -x "$CHECK" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $CHECK)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }
pass=0; fail=0

for g in "$ROOT"/test/diff_fixtures/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$ROOT/test/diff_fixtures/$fix.mdk" ] || continue
  self="$("$CHECK" "$RT" "$CORE" "$ROOT/test/diff_fixtures/$fix.mdk" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  want="$(sed -n '/=== TYPES ===/,/=== EVAL ===/p' "$g" | sed '1d;$d' | LC_ALL=C sort)"
  if [ "$self" = "$want" ]; then pass=$((pass+1)); printf 'ok   types/%s\n' "$fix"
  else fail=$((fail+1)); printf 'FAIL types/%s\n' "$fix"; fi
done

for f in "$ROOT"/test/resolve_fixtures/*.mdk; do
  name="$(basename "$f")"
  golden="${f%.mdk}.expected"
  [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL resolve/%s (no .expected)\n' "$name"; continue; }
  self="$("$CHECK" "$RT" "$CORE" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  want="$(LC_ALL=C sort < "$golden")"
  if [ "$self" = "$want" ]; then pass=$((pass+1)); printf 'ok   resolve/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL resolve/%s\n' "$name"; fi
done

# R3: import-error fixtures — bad imports should produce UnknownModule (right
# category) not a spurious typecheck error.  Oracle = committed .expected golden.
for f in "$ROOT"/test/import_error_fixtures/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.expected"
  [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL import_error/%s (no .expected)\n' "$name"; continue; }
  self="$("$CHECK" "$RT" "$CORE" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  want="$(LC_ALL=C sort < "$golden")"
  if [ "$self" = "$want" ]; then pass=$((pass+1)); printf 'ok   import_error/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL import_error/%s\n' "$name"
    printf '  want: %s\n  self: %s\n' "$want" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
printf '(NOTE: the 25 types/* fails are the documented #55 sum/product drift, task #11)\n'
[ "$fail" -eq 0 ]
