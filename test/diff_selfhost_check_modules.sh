#!/bin/sh
# Multi-module front-end validation for the bootstrap: run the self-hosted
# multi-module typecheck front-end (check_modules_main: loader → desugar →
# checkModules) over each entry, and diff the inferred per-binding schemes against
# a committed golden captured from the OCaml reference (the real Loader +
# typecheck_module, via dev/tc_module_probe.exe).
#
# OCaml-free (REROOT-PLAN §2b): native host test/bin/check_modules_main; oracle
# legs are committed goldens (per-fixture <dir>/oracle.tcmod, captured by
# test/capture_goldens.sh) — no live tc_module_probe / main.exe.
#
# NOTE: the $MODULES per-library-module leg below targets selfhost/<m>.mdk paths
# that no longer exist (the modules moved into selfhost/frontend/ etc.), so it has
# been DORMANT (skips every module) since before this re-root — preserved verbatim
# so the gate's live legs (the fixtures + the cycle check) are unchanged.
#
# Usage:  sh test/diff_selfhost_check_modules.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/test/bin/check_modules_main"
CORE="$ROOT/stdlib/core.mdk"
RUNTIME="$ROOT/stdlib/runtime.mdk"
SHDIR="$ROOT/selfhost"
[ -x "$SELF" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $SELF)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

MODULES="ast lexer parser sexp desugar marker annotate resolve exhaust loader typecheck eval check"
FIXDIR="$ROOT/test/check_module_fixtures"
pass=0; fail=0

# ── 1. selfhost library modules (each as the entry) — DORMANT (see header) ──
for m in $MODULES; do
  [ -f "$SHDIR/$m.mdk" ] || continue
  golden="$SHDIR/$m.tcmod.golden"
  [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL %s (no .tcmod.golden)\n' "$m"; continue; }
  ref="$(LC_ALL=C sort < "$golden")"
  self="$("$SELF" "$RUNTIME" "$CORE" "$SHDIR/$m.mdk" "$SHDIR" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$m"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$m"; fi
done

# ── 2. multi-module fixtures (TYPECHECK-AUDIT C8) ───────────────────────────
# Each test/check_module_fixtures/<name>/ holds a small set of .mdk modules, an
# `entry` file naming the entry module, and a committed `oracle.tcmod` golden of
# the entry's sorted schemes (captured from dev/tc_module_probe.exe).  The C8(a)
# fixture (iface_method_export) regresses to `unbound variable: show2` without the
# publicValNames interface-method export fix.
if [ -d "$FIXDIR" ]; then
  for d in "$FIXDIR"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    root="${d%/}"
    [ -f "$d/entry" ]        || { echo "FAIL fixture/$name (no entry file)"; fail=$((fail+1)); continue; }
    [ -f "$d/oracle.tcmod" ] || { echo "FAIL fixture/$name (no oracle.tcmod — run sh test/capture_goldens.sh tcmod)"; fail=$((fail+1)); continue; }
    entry="$root/$(cat "$d/entry")"
    golden="$(LC_ALL=C sort < "$d/oracle.tcmod")"
    self="$("$SELF" "$RUNTIME" "$CORE" "$entry" "$root" 2>/dev/null | strip_unit | LC_ALL=C sort)"
    if [ "$self" = "$golden" ]; then pass=$((pass+1)); printf 'ok   fixture/%s\n' "$name"
    else fail=$((fail+1)); printf 'FAIL fixture/%s (selfhost differs from golden)\n' "$name"; fi
  done
fi

# ── 3. R2: cycle-chain error format (loader.mdk) ────────────────────────────
# Create a minimal a→b→a cycle in a tmpdir, run check_modules_main over it, and
# verify the selfhost emits the full chain "cyclic dependency: a → b → a".
CTMP="$(mktemp -d)"
trap 'rm -rf "$CTMP"' EXIT
printf 'import b.{bar}\nexport foo : Int\nfoo = 1\n' > "$CTMP/a.mdk"
printf 'import a.{foo}\nexport bar : Int\nbar = 2\n' > "$CTMP/b.mdk"
cycle_self="$("$SELF" "$RUNTIME" "$CORE" "$CTMP/a.mdk" "$CTMP" 2>&1 >/dev/null)"
want_cycle="cyclic dependency: a → b → a"
if [ "$cycle_self" = "$want_cycle" ]; then pass=$((pass+1)); printf 'ok   cycle/a-b-a\n'
else fail=$((fail+1)); printf 'FAIL cycle/a-b-a (got: %s)\n' "$cycle_self"; fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
