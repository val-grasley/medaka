#!/bin/sh
# Differential gate for test/index_fixtures/ — the `Index` interface's
# prelude-vs-user-file dispatch regression corpus (#16a/#16c, tracked in #72).
#
# test/index_fixtures/ had TWO fixtures with ZERO gate consumers — written as
# manual-verification-only files (each carrying a "Run with: medaka run …"
# header comment) and never wired into an automated gate
# (test/FIXTURE-CORPUS-EXCEPTIONS.txt:30). #16c's bare_bracket_index.mdk moved
# to test/run_check_agreement_fixtures/ (it needs no special flags, and that
# gate is STRONGER — it pins check==run==build agreement AND the printed
# value). #16a's prelude_index_dispatch.mdk stays here: its header documents
# needing `--allow-internal` (a prelude-defined multi-param interface dispatch
# regression touching internal machinery), a flag run_check_agreement's fixed
# `check`/`run`/`build` invocations cannot pass. This gate closes that hole.
#
# Note: verified empirically (2026-07-15) that the CURRENT binary accepts and
# runs prelude_index_dispatch.mdk identically with or without --allow-internal
# (no diagnostic either way — `index` dispatch happens inside the ALREADY-
# TRUSTED stdlib array/list/string modules, not in the calling file itself).
# This gate still passes --allow-internal, matching the fixture's own
# documented invocation and hedging against a future tightening of the
# internal-extern trust guard (compiler/frontend/resolve.mdk's
# `internalGuardFor`) that would make the flag load-bearing again.
#
# Drives the real `./medaka run --allow-internal <fixture>` CLI against a
# committed golden per fixture: test/index_goldens/<name>.index.golden.
# Output is deterministic (plain println of Strings/Chars via a container
# Index impl, no timestamps/paths), so a plain literal compare is sound.
#
# Usage:  sh test/diff_compiler_index.sh
#         CAPTURE=1 sh test/diff_compiler_index.sh   # (re)capture goldens via
#                                                     # the EXACT same invocation
#                                                     # the gate reads with.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# $MEDAKA honoured for local runs against a borrowed/pre-built binary; CI (which
# builds ./medaka before running gates) falls back to $ROOT/medaka.
MEDAKA="${MEDAKA:-$ROOT/medaka}"
FIXDIR="$ROOT/test/index_fixtures"
GOLDENDIR="$ROOT/test/index_goldens"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

if [ "${CAPTURE:-0}" = "1" ]; then
  mkdir -p "$GOLDENDIR"
  n=0
  for f in "$FIXDIR"/*.mdk; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    name="$(basename "$f" .mdk)"
    "$MEDAKA" run --allow-internal "$f" > "$GOLDENDIR/$name.index.golden" 2>/dev/null
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
  golden="$GOLDENDIR/$name.index.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail + 1))
    printf 'FAIL %s (no golden — run CAPTURE=1 sh test/diff_compiler_index.sh)\n' "$name"
    continue
  fi
  expected="$(cat "$golden")"
  actual="$("$MEDAKA" run --allow-internal "$f" 2>/dev/null)"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s (medaka run --allow-internal output differs from golden)\n' "$name"
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
