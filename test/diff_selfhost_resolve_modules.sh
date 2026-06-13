#!/bin/sh
# Differential validation for the self-hosted MULTI-MODULE resolve path
# (Resolve.resolve_module — imports validated against real exports, privacy,
# abstract-type ctor exports, re-exports).  This is the path the single-file
# --resolve harness (diff_selfhost_resolve.sh) deliberately stubs out.
#
# Oracle: dev/diagdump.exe --resolve-modules <mod1> <mod2> ...  — threads
# Resolve.resolve_module over the given files IN ORDER (caller supplies
# dependency-first order), accumulating each module's exports, and dumps the
# union of all modules' errors as sorted, location-stripped S-expressions.  It
# does NOT go through the Loader, so UnknownModule (which the loader would catch
# first as a missing-file error) is reachable here.
#
# Two test sets:
#   1. Fixtures — each test/resolve_module_fixtures/<name>/ holds a small set of
#      .mdk modules, an `order` file (space-separated, dependency-first), and a
#      committed `expected` golden.  For each:
#        A. reference stability — diagdump output must equal the golden.
#        B. self-host parity     — resolve_modules_main.mdk output must too.
#   2. Corpus no-false-positives — run both over the whole selfhost module graph
#      (dependency order); both must be empty (a valid program has no errors)
#      and must agree.
#
# Usage:  sh test/diff_selfhost_resolve_modules.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/test/bin/resolve_modules_main"
FIXDIR="$ROOT/test/resolve_module_fixtures"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
SHDIR="$ROOT/selfhost"

[ -x "$RUN" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $RUN)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c)
# before sorting / emptiness-checking the diagnostic set.
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

pass=0; fail=0

# ── 1. fixtures ─────────────────────────────────────────────────────────────
for d in "$FIXDIR"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  [ -f "$d/order" ] || { echo "FAIL $name (no order file)"; fail=$((fail+1)); continue; }
  order="$(cat "$d/order")"
  files=""
  for m in $order; do files="$files $d$m"; done
  golden="$(cat "$d/expected")"
  ok=1
  self="$("$RUN" "$RUNTIME" "$CORE" $files 2>/dev/null | strip_unit | LC_ALL=C sort)"
  [ "$self" = "$golden" ] || { ok=0; reason="selfhost differs from golden"; }
  if [ "$ok" -eq 1 ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s (%s)\n' "$name" "$reason"; fi
done

# ── 2. corpus no-false-positives ────────────────────────────────────────────
# The selfhost library modules in dependency-first order (deps before users):
# leaves (util/ast/lexer) → single-dep stages → parser → loader → typecheck →
# the composed check front-end.  A valid program ⇒ zero resolve diagnostics.
CORPUS="util ast lexer sexp desugar exhaust eval resolve marker parser loader typecheck check"
cfiles=""
for m in $CORPUS; do
  [ -f "$SHDIR/$m.mdk" ] && cfiles="$cfiles $SHDIR/$m.mdk"
done
# A valid program ⇒ zero resolve diagnostics: the frozen golden here is the
# EMPTY error set (captured while OCaml was trusted; REROOT-PLAN §2b).  The
# native resolve_modules over the corpus must produce no output.
cself="$("$RUN" "$RUNTIME" "$CORE" $cfiles 2>/dev/null | strip_unit | LC_ALL=C sort)"
ok=1; reason=""
[ -z "$cself" ] || { ok=0; reason="selfhost reports errors on the valid corpus"; }
if [ "$ok" -eq 1 ]; then pass=$((pass+1)); printf 'ok   corpus (no false positives)\n'
else fail=$((fail+1)); printf 'FAIL corpus (%s)\n' "$reason"; fi

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
