#!/bin/sh
# Multi-module front-end validation for the bootstrap: run the self-hosted
# multi-module typecheck front-end (check_modules_main.mdk: loader → desugar →
# checkModules) over each selfhost module as the ENTRY, and diff the inferred
# per-binding schemes against the OCaml reference doing the same — the real
# Loader + typecheck_module, via dev/tc_module_probe.exe.
#
# This is the "the self-hosted compiler typechecks its own multi-module source"
# diff: every module is loaded with its transitive imports, type-checked against
# the shared prelude, and the entry module's own bindings are compared.
#
# Usage:  sh test/diff_selfhost_check_modules.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
PROBE="$ROOT/_build/default/dev/tc_module_probe.exe"
SELF="$ROOT/selfhost/check_modules_main.mdk"
CORE="$ROOT/stdlib/core.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
SHDIR="$ROOT/selfhost"
[ -x "$MAIN" ]  || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }

MODULES="ast lexer parser sexp desugar marker annotate resolve exhaust loader typecheck eval check"
pass=0; fail=0
for m in $MODULES; do
  [ -f "$SHDIR/$m.mdk" ] || continue
  ref="$("$PROBE" "$SHDIR/$m.mdk" "$SHDIR" 2>/dev/null | LC_ALL=C sort)"
  self="$("$MAIN" run "$SELF" "$RUNTIME" "$CORE" "$SHDIR/$m.mdk" "$SHDIR" 2>/dev/null | LC_ALL=C sort)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$m"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$m"; fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
