#!/bin/sh
# Self-lex validation: run the self-hosted Medaka lexer over REAL .mdk source
# (the stdlib + the lexer itself) and diff its token stream against the OCaml
# reference lexer (dev/lextok.exe).  This is a far stronger test than the curated
# test/diff_fixtures/ corpus — it exercises whatever real code actually uses
# (block comments, the full operator set, …).
#
# Compared LITERALLY against the golden, including FLOAT token text: both the
# golden (test/capture_goldens.sh, tag lextok) and the "actual" side run the same
# native `tokenToString`/`floatToString` (OCaml removed 2026-06-26), so there is
# no cross-engine formatting skew left to normalize away. Any reported diff is a
# real token-kind/position/text divergence.
#
# Usage:  sh test/diff_compiler_lex_files.sh [file.mdk ...]
# Exit:   0 if every file's token stream matches literally, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/lex_main"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

if [ "$#" -gt 0 ]; then
  files="$*"
else
  files="$ROOT/compiler/frontend/lexer.mdk"
  for f in core list array string map set io hash_map hash_set mut_array json test; do
    files="$files $ROOT/stdlib/$f.mdk"
  done
fi

pass=0
fail=0
for f in $files; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.lextok.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh lextok)"; fail=$((fail+1)); continue; }
  expected="$(cat "$golden")"
  actual="$("$RUN" "$f" 2>/dev/null | strip_unit)"
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
