#!/bin/sh
# Snapshot gate for the Core IR S-expression serializer (STAGE2-DESIGN §2.1).
#
# There is no OCaml reference for the Core IR dump — Core IR is selfhost-only.
# This harness validates by SELF-CONSISTENCY (snapshot goldens): the first run
# establishes what the serializer produces; future runs detect any accidental
# drift in the lowering or the serializer without needing an external oracle.
#
# For each fixture in test/eval_fixtures/:
#   parse → desugar → annotate → lower → cprogramToSexp (core_ir_dump_main.mdk)
# and diff the output against the committed golden in test/core_ir_sexp_fixtures/.
#
# To regenerate all goldens (after an intentional IR/serializer change):
#   for f in test/eval_fixtures/*.mdk; do
#     name=$(basename "$f" .mdk)
#     ./_build/default/bin/main.exe run selfhost/core_ir_dump_main.mdk "$f" \
#       > test/core_ir_sexp_fixtures/"$name".sexp
#   done
#
# Usage:  sh test/diff_selfhost_core_ir_sexp.sh
# Exit:   0 if every fixture matches its golden.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
DUMP="$ROOT/selfhost/core_ir_dump_main.mdk"
FIXDIR="$ROOT/test/eval_fixtures"
GOLDDIR="$ROOT/test/core_ir_sexp_fixtures"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
[ -d "$GOLDDIR" ] || { echo "no goldens yet — run the regeneration loop above"; exit 2; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .mdk)"
  gold="$GOLDDIR/${name}.sexp"
  [ -f "$gold" ] || { printf 'MISSING golden: %s\n' "$name"; fail=$((fail+1)); continue; }
  self="$("$MAIN" run "$DUMP" "$f" 2>/dev/null)"
  expected="$(cat "$gold")"
  if [ "$self" = "$expected" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1))
    printf 'FAIL %s\n' "$name"
    printf '%s\n' "$expected" > /tmp/_cir_sexp_exp.txt
    printf '%s\n' "$self"     > /tmp/_cir_sexp_got.txt
    diff /tmp/_cir_sexp_exp.txt /tmp/_cir_sexp_got.txt | head -20
  fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
