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
FIXDIR="$ROOT/test/check_module_fixtures"
pass=0; fail=0

# ── 1. selfhost library modules (each as the entry) ─────────────────────────
for m in $MODULES; do
  [ -f "$SHDIR/$m.mdk" ] || continue
  ref="$("$PROBE" "$SHDIR/$m.mdk" "$SHDIR" 2>/dev/null | LC_ALL=C sort)"
  self="$("$MAIN" run "$SELF" "$RUNTIME" "$CORE" "$SHDIR/$m.mdk" "$SHDIR" 2>/dev/null | LC_ALL=C sort)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$m"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$m"; fi
done

# ── 2. multi-module fixtures (TYPECHECK-AUDIT C8) ───────────────────────────
# Each test/check_module_fixtures/<name>/ holds a small set of .mdk modules, an
# `entry` file naming the entry module, and a committed `expected` golden of the
# entry's sorted schemes.  Per fixture: (A) reference stability (probe == golden)
# and (B) self-host parity (check_modules_main == golden).  The C8(a) fixture
# (iface_method_export) regresses to `unbound variable: show2` without the
# publicValNames interface-method export fix.  [C8(b)'s bad-default-body case is
# NOT a plain-check fixture: default-body inference is gated on implInferEnabled,
# OFF on this plain-check driver — it's exercised on the LLVM emit path instead
# (diff_selfhost_llvm_modules), where the gate is ON.]
if [ -d "$FIXDIR" ]; then
  for d in "$FIXDIR"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    root="${d%/}"
    [ -f "$d/entry" ]    || { echo "FAIL fixture/$name (no entry file)"; fail=$((fail+1)); continue; }
    [ -f "$d/expected" ] || { echo "FAIL fixture/$name (no expected file)"; fail=$((fail+1)); continue; }
    entry="$root/$(cat "$d/entry")"
    golden="$(cat "$d/expected")"
    ref="$("$PROBE" "$entry" "$root" 2>/dev/null | LC_ALL=C sort)"
    ok=1; reason=""
    [ "$ref" = "$golden" ] || { ok=0; reason="reference drifted from golden"; }
    if [ "$ok" -eq 1 ]; then
      self="$("$MAIN" run "$SELF" "$RUNTIME" "$CORE" "$entry" "$root" 2>/dev/null | LC_ALL=C sort)"
      [ "$self" = "$golden" ] || { ok=0; reason="selfhost differs from reference"; }
    fi
    if [ "$ok" -eq 1 ]; then pass=$((pass+1)); printf 'ok   fixture/%s\n' "$name"
    else fail=$((fail+1)); printf 'FAIL fixture/%s (%s)\n' "$name" "$reason"; fi
  done
fi

# ── 3. R2: cycle-chain error format (loader.mdk) ────────────────────────────
# Create a minimal a→b→a cycle in a tmpdir, run check_modules_main over it, and
# verify the selfhost emits the full chain "cyclic dependency: a → b → a" to
# stderr (mirroring the OCaml oracle's CyclicDependency formatting).
CTMP="$(mktemp -d)"
trap 'rm -rf "$CTMP"' EXIT
printf 'import b.{bar}\nexport foo : Int\nfoo = 1\n' > "$CTMP/a.mdk"
printf 'import a.{foo}\nexport bar : Int\nbar = 2\n' > "$CTMP/b.mdk"
cycle_self="$("$MAIN" run "$SELF" "$RUNTIME" "$CORE" "$CTMP/a.mdk" "$CTMP" 2>&1 >/dev/null)"
want_cycle="cyclic dependency: a → b → a"
if [ "$cycle_self" = "$want_cycle" ]; then pass=$((pass+1)); printf 'ok   cycle/a-b-a\n'
else fail=$((fail+1)); printf 'FAIL cycle/a-b-a (got: %s)\n' "$cycle_self"; fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
