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
#     test/bin/core_ir_dump_main "$f" | sed '${/^()$/d;}' \
#       > test/core_ir_sexp_fixtures/"$name".sexp
#   done
#
# Usage:  sh test/diff_selfhost_core_ir_sexp.sh
# Exit:   0 if every fixture matches its golden.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# OCaml-free (REROOT-PLAN.md Phase 2): the Core-IR S-expression dump runs as the
# pre-compiled native binary test/bin/core_ir_dump_main (built by
# test/build_oracles.sh).  This is already a SELF-CONSISTENCY snapshot gate — the
# reference is the committed .sexp golden, never a live OCaml oracle.  The native
# runtime auto-prints main's Unit return as a trailing "()" line; strip_unit drops it.
DUMP="$ROOT/test/bin/core_ir_dump_main"
FIXDIR="$ROOT/test/eval_fixtures"
GOLDDIR="$ROOT/test/core_ir_sexp_fixtures"

[ -x "$DUMP" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $DUMP)"; exit 2; }
[ -d "$GOLDDIR" ] || { echo "no goldens yet — run the regeneration loop above"; exit 2; }
strip_unit() { sed '${/^()$/d;}'; }

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .mdk)"
  gold="$GOLDDIR/${name}.sexp"
  [ -f "$gold" ] || { printf 'MISSING golden: %s\n' "$name"; fail=$((fail+1)); continue; }
  self="$("$DUMP" "$f" 2>/dev/null | strip_unit)"
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
