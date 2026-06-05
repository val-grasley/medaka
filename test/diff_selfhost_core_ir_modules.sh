#!/bin/sh
# Multi-module equivalence gate for the Core IR (STAGE2-DESIGN §2.1) — the
# loader-driven analog of test/diff_selfhost_core_ir.sh, broadening the §2.1
# equivalence proof to the eval_modules corpus (per-module Core-IR frames).
#
# Self-host: core_ir_modules_main.mdk loads <entry> + its transitive imports,
# desugars + annotates each, LOWERS them per-module to Core IR, and evaluates
# them in per-module frames over the shared prelude (cevalModules), printing the
# root module's `main` stdout.  Diffs byte-for-byte against the OCaml reference
# doing the same through the AST — `medaka run <entry>` (real Loader → typecheck
# → eval_modules), the SAME oracle test/diff_selfhost_eval_modules.sh uses.  So
# this is to eval_modules_main what diff_selfhost_core_ir.sh is to eval_main: the
# Core IR is correct on the loader-driven path iff its output matches the AST
# tree-walker's across module boundaries.
#
# Each fixture is a directory under test/eval_modules_fixtures/ holding a single
# `main_*.mdk` entry plus its sibling modules.  Fixtures stay on the UNTYPED path
# (no return-position dispatch / `=>` constraints).
#
# Usage:  sh test/diff_selfhost_core_ir_modules.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
SELF="$ROOT/selfhost/core_ir_modules_main.mdk"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/eval_modules_fixtures"
[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }

pass=0; fail=0
for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  entry="$(ls "$dir"main_*.mdk 2>/dev/null | head -1)"
  [ -n "$entry" ] || { echo "skip $(basename "$dir") (no main_*.mdk)"; continue; }
  name="$(basename "$dir")"
  ref="$("$MAIN" run "$entry" 2>&1)"
  self="$("$MAIN" run "$SELF" "$CORE" "$entry" "${dir%/}" 2>&1)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '  ref:  %s\n' "$ref"
    printf '  self: %s\n' "$self"
  fi
done
printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
