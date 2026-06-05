#!/bin/sh
# Batch variant of diff_selfhost_check_modules.sh.
#
# The original runs ONE process per module entry (12 processes), each loading
# the entry's whole import-closure, typechecking it, but emitting only the entry
# module's schemes — so shared lower modules (ast, lexer, parser, …) get
# re-typechecked in up to 12 closures.  A module's schemes depend only on its
# dependency-closure (which precedes it in topo order), so they are identical
# whether the module is checked alone or inside a larger union closure.  This
# variant exploits that: it runs check_all_main.mdk (which emits EVERY module in
# the closure, each section preceded by `## MODULE <mid>`) over a small COVERING
# SET of entries whose closures union to all target modules, and diffs each
# target module's section — taken from the first run that produced it — against
# its per-module OCaml oracle (dev/tc_module_probe.exe).
#
# Covering set: a single synthetic entry (selfhost/all_modules_entry.mdk) imports
# one name from every selfhost module, so loadProgram pulls them ALL into one
# union closure — ONE process emits all 12 modules' schemes (check.mdk exports
# `runCheck` so it can be pulled in too).  1 process instead of 12; every shared
# module is typechecked exactly once.  Same oracle, same per-module
# byte-for-byte comparison as the original.
#
# Usage:  sh test/diff_selfhost_check_modules_batch.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
PROBE="$ROOT/_build/default/dev/tc_module_probe.exe"
SELF="$ROOT/selfhost/check_all_main.mdk"
CORE="$ROOT/stdlib/core.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
SHDIR="$ROOT/selfhost"
[ -x "$MAIN" ]  || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }
[ -f "$SELF" ]  || { echo "missing $SELF"; exit 2; }

TARGETS="ast lexer parser sexp desugar marker resolve exhaust loader typecheck eval check"
ENTRIES="all_modules_entry"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Run check_all_main once per covering entry; save each combined --all dump.
for e in $ENTRIES; do
  "$MAIN" run "$SELF" "$RUNTIME" "$CORE" "$SHDIR/$e.mdk" "$SHDIR" 2>/dev/null > "$TMP/run_$e.txt"
done

# Extract module <mid>'s section (lines between its `## MODULE mid` marker and
# the next marker) from a combined dump; empty if absent.
section() {  # section <dumpfile> <mid>
  awk -v M="$2" '
    /^## MODULE /{cur=($3==M)?1:0; next}
    cur{print}
  ' "$1"
}

pass=0; fail=0
for m in $TARGETS; do
  [ -f "$SHDIR/$m.mdk" ] || continue
  # take the section from the first covering entry whose dump contains it
  self=""
  found=0
  for e in $ENTRIES; do
    if grep -q "^## MODULE $m\$" "$TMP/run_$e.txt"; then
      self="$(section "$TMP/run_$e.txt" "$m" | LC_ALL=C sort)"
      found=1
      break
    fi
  done
  if [ "$found" -eq 0 ]; then
    fail=$((fail+1)); printf 'FAIL %s  (not covered by any entry)\n' "$m"; continue
  fi
  ref="$("$PROBE" "$SHDIR/$m.mdk" "$SHDIR" 2>/dev/null | LC_ALL=C sort)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$m"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$m"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
