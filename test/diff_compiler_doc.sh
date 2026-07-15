#!/bin/sh
# Differential gate for `medaka doc` (compiler/tools/doc.mdk via the native CLI).
#
# `medaka doc` was ported to the native CLI in 96b62efb ("feat(cli): port `medaka
# doc` to the native CLI (single-file)") but shipped with ZERO regression
# coverage — test/doc_fixtures/ (14 real .mdk fixtures) had no consumer at all
# (see test/FIXTURE-CORPUS-EXCEPTIONS.txt). This gate closes that hole.
#
# Drives the real `./medaka doc <fixture>` CLI (not an entry probe — `doc` has
# no standalone test/bin/* oracle) against a committed golden per fixture:
# test/doc_goldens/<name>.doc.golden. `medaka doc` output is deterministic (the
# `# <title>` header comes from the fixture's basename, not its path — verified
# identical when invoked from a different cwd/absolute path) and embeds no
# timestamp, so a plain literal compare is sound.
#
# Usage:  sh test/diff_compiler_doc.sh
#         CAPTURE=1 sh test/diff_compiler_doc.sh   # (re)capture goldens via the
#                                                   # EXACT same invocation the
#                                                   # gate reads with — single
#                                                   # source of truth, goldens
#                                                   # can never drift from the
#                                                   # read path.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# $MEDAKA honoured for local runs against a borrowed/pre-built binary; CI (which
# builds ./medaka before running gates) falls back to $ROOT/medaka.
MEDAKA="${MEDAKA:-$ROOT/medaka}"
FIXDIR="$ROOT/test/doc_fixtures"
GOLDENDIR="$ROOT/test/doc_goldens"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

if [ "${CAPTURE:-0}" = "1" ]; then
  mkdir -p "$GOLDENDIR"
  n=0
  for f in "$FIXDIR"/*.mdk; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    name="$(basename "$f" .mdk)"
    "$MEDAKA" doc "$f" > "$GOLDENDIR/$name.doc.golden" 2>/dev/null
    printf 'captured %s\n' "$name"
  done
  printf '\ngoldens captured for %d fixtures in %s\n' "$n" "$GOLDENDIR"
  [ "$n" -gt 0 ] || { echo "NO FIXTURES FOUND under $FIXDIR — refusing to report a pass on zero input"; exit 1; }
  exit 0
fi

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .mdk)"
  golden="$GOLDENDIR/$name.doc.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail + 1))
    printf 'FAIL %s (no golden — run CAPTURE=1 sh test/diff_compiler_doc.sh)\n' "$name"
    continue
  fi
  expected="$(cat "$golden")"
  actual="$("$MEDAKA" doc "$f" 2>/dev/null)"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s (medaka doc output differs from golden)\n' "$name"
  fi
done

# 0-checked must fail: a gate that iterated no fixtures proves nothing and must
# never report green (see e.g. diff_compiler_snapshot_frontend.sh's "NOTHING
# COMPARED" branch for the same house rule).
if [ "$((pass + fail))" -eq 0 ]; then
  printf '\nNO FIXTURES FOUND under %s — 0 checked, refusing to pass\n' "$FIXDIR"
  exit 1
fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
