#!/bin/sh
# Batch variant of diff_compiler_check_modules.sh.
#
# Runs check_all_main once over a COVERING SET of entries whose import-closures
# union to all target modules (here: a single synthetic all_modules_entry that
# imports one name from every compiler module), emitting EVERY module's schemes
# (each section preceded by `## MODULE <mid>`), then diffs each target module's
# section against a committed per-module golden captured from the OCaml reference
# (dev/tc_module_probe.exe).  1 process instead of 12.
#
# OCaml-free (REROOT-PLAN §2b): native host test/bin/check_all_main; the oracle is
# a committed <m>.tcmod.golden per target module (captured by capture_goldens.sh).
#
# NOTE: the $TARGETS modules are referenced as compiler/<m>.mdk paths that no
# longer exist (modules moved into compiler/frontend/ etc.), so this gate has been
# DORMANT (skips every target → 0 ok, 0 failing) since before this re-root —
# preserved verbatim, now OCaml-free.
#
# Usage:  sh test/diff_compiler_check_modules_batch.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/test/bin/check_all_main"
CORE="$ROOT/stdlib/core.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
SHDIR="$ROOT/compiler"
STDLIB="$ROOT/stdlib"
[ -x "$SELF" ]  || { echo "build oracles first: sh test/build_oracles.sh (missing $SELF)"; exit 2; }

TARGETS="ast lexer parser sexp desugar marker annotate resolve exhaust loader typecheck eval check"
ENTRIES="all_modules_entry"

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Run check_all_main once per covering entry; save each combined --all dump.
for e in $ENTRIES; do
  "$SELF" "$RUNTIME" "$CORE" "$SHDIR/entries/$e.mdk" "$SHDIR" "$STDLIB" 2>/dev/null | strip_unit > "$TMP/run_$e.txt"
done

# Extract module <mid>'s section from a combined dump; empty if absent.
section() {  # section <dumpfile> <mid>
  awk -v M="$2" '
    /^## MODULE /{cur=($3==M)?1:0; next}
    cur{print}
  ' "$1"
}

pass=0; fail=0
for m in $TARGETS; do
  [ -f "$SHDIR/$m.mdk" ] || continue
  golden="$SHDIR/$m.tcmod.golden"
  [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL %s (no .tcmod.golden)\n' "$m"; continue; }
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
  ref="$(LC_ALL=C sort < "$golden")"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$m"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$m"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
