#!/bin/sh
# Differential gate for the self-hosted FORMATTER (compiler/entries/fmt_main.mdk).
#
# OCaml-free (REROOT-PLAN §2c): native host test/bin/fmt_main vs a committed
# golden captured from `main.exe fmt --stdout <f>` (test/capture_goldens.sh fmt).
# The gate applies `norm` (float-text normalization) to BOTH the golden and the
# native output, and strip_unit's the native binary's trailing "()" Unit auto-print
# before the compare.  Sibling golden: <fixture>.fmt.golden.
#
# Usage:  sh test/diff_compiler_fmt.sh [files...]
# Exit:   0 if every fixture's native formatting matches the golden;
#         2 if the oracle binary is missing (run sh test/build_oracles.sh first).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/fmt_main"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Normalize volatile float text (mirrors the original gate's both-sides norm).
norm() { sed -E 's/-?[0-9]+\.[0-9eE+-]+/<F>/g'; }
# Drop the native value entry's trailing "()" (Unit auto-print; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$ROOT/test/fmt_fixtures/*.mdk $ROOT/test/parse_fixtures/*.mdk"
fi

pass=0
fail=0
for f in $files; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.fmt.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (no .fmt.golden — run sh test/capture_goldens.sh fmt)\n' "$name"; continue
  fi
  expected="$(norm < "$golden")"
  actual="$("$RUN" "$f" 2>/dev/null | strip_unit | norm)"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$name"
  fi
done

printf '\n%d matched, %d differing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
