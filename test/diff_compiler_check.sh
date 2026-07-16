#!/bin/sh
# Validation for the COMPOSED self-hosted front-end (compiler/tools/check.mdk): one
# driver runs parse → desugar → resolve → exhaust → typecheck and must reproduce
# each stage's oracle depending on the input category:
#   • diff_fixtures (clean, prelude-using) → the composed driver's TYPES output must
#     CONTAIN every user scheme line committed in the `# TYPES_USER` snapshot
#     (test/snapshots/diff_fixtures_types/<n>.md), proving resolve+exhaust pass,
#     typecheck runs, AND the composed driver agrees with the snapshot runner
#     (diff_compiler_snapshot_types_user.sh) on the USER schemes. See #81 Stage C
#     below for why this is a SUBSET check, not the old full === TYPES === diff;
#   • resolve_fixtures (broken)            → the committed resolve diagnostics
#     golden <name>.expected (== dev/diagdump.exe --resolve at capture), proving
#     the driver routes resolve errors;
#   • import_error_fixtures (bad imports)  → committed .expected golden
#     (UnknownModule S-expression), proving R3: bad imports halt with the right
#     error category rather than falling through to a spurious typecheck error.
# The resolve/import legs compare full sorted output; the clean leg is a subset.
#
# ── #81 Stage C: clean leg repointed to `# TYPES_USER` (was the full === TYPES ===) ──
# The frozen === TYPES === golden dumps ~117 prelude schemes + the user schemes; the
# prelude table is IDENTICAL across all 57 clean fixtures (~90% redundant). The #81
# arc moved that invariant to two focused gates: the whole-prelude-inference dump
# (diff_compiler_snapshot_prelude.sh, ONE core.mdk dump) and the user-only schemes
# (diff_compiler_snapshot_types_user.sh, `# TYPES_USER`). This gate's remaining job
# is to prove the COMPOSED driver (check_main) agrees with the snapshot runner on
# the user schemes WITHOUT re-pinning the prelude table 57×: for each clean fixture,
# every `# TYPES_USER` line must be PRESENT in check_main's TYPES output (subset,
# via grep -Fxv membership — order-independent, no full-dump equality). Proven at
# introduction: 0 missing across all 57, including the match_nonexhaustive fixture's
# `Warning:` line (check_main emits it too, so it needs no special-casing).
#
# OCaml-free (REROOT-PLAN §2b): native host test/bin/check_main; every oracle leg
# is a committed golden (no live main.exe / diagdump re-derivation).
#
# DRIVER-COLLAPSE Phase 4 RE-ROOT (OPTION A, 2026-06-13): the real `medaka check`
# CLI now RESOLVES imports (loadProgram → multi-module typecheck) instead of
# emitting `UnknownModule` for non-core imports.  This gate's host (check_main) is
# the SINGLE-FILE front-end (compiler/tools/check.mdk runCheck) and is UNCHANGED —
# it still exercises the 1-module degenerate case, so the no-import fixtures below
# stay byte-identical (the CLI routes 1-module loads through this same runCheck).
# The import-bearing `check` behaviour (option A) is verified ELSEWHERE, not here:
#   • diff_compiler_check_modules.sh — native multi-module typecheck vs the OCaml
#     MULTI-module oracle (the import-aware path `check` now shares with run/build);
#   • diff_native_cli.sh — the real `./medaka check` CLI vs committed goldens
#     (no-import goldens prove byte-identity), plus its check/repl/run legs.
# The import_error_fixtures below remain SINGLE-FILE (the loader cannot resolve a
# module that does not exist), so check_main still emits UnknownModule for them.
#
# #55 / task #11 (Num-polymorphic integer literals) CLOSED 2026-06-16: the OCaml
# oracle (eac278b) and the compiler typecheck now both infer `sum`/`product :
# a b -> b` via Num-polymorphic literals + ambiguous-Num defaulting, so the TYPES
# leg agrees with the golden — this gate is now all-pass.
#
# Usage:  sh test/diff_compiler_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/test/bin/check_main"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
[ -x "$CHECK" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $CHECK)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }
# Extract the `# TYPES_USER` section (the last section) of a snapshot .md.
tu_section() { awk '/^# TYPES_USER$/{f=1;next} /^# /{f=0} f'; }
pass=0; fail=0

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

for g in "$ROOT"/test/diff_fixtures/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$ROOT/test/diff_fixtures/$fix.mdk" ] || continue
  snap="$ROOT/test/snapshots/diff_fixtures_types/$fix.md"
  [ -f "$snap" ] || { fail=$((fail+1)); printf 'FAIL types/%s (no # TYPES_USER snapshot)\n' "$fix"; continue; }
  # Composed-driver TYPES output (prelude-bearing, as before). Subset check: every
  # committed `# TYPES_USER` line must appear verbatim; prelude schemes are unpinned.
  "$CHECK" "$RT" "$CORE" "$ROOT/test/diff_fixtures/$fix.mdk" 2>/dev/null | strip_unit > "$WORK/self"
  miss="$(tu_section < "$snap" | grep -Fxv -f "$WORK/self")"
  if [ -z "$miss" ]; then pass=$((pass+1)); printf 'ok   types/%s\n' "$fix"
  else fail=$((fail+1)); printf 'FAIL types/%s\n' "$fix"
    printf '%s\n' "$miss" | sed 's/^/  missing from check_main TYPES: /'; fi
done

for f in "$ROOT"/test/resolve_fixtures/*.mdk; do
  name="$(basename "$f")"
  golden="${f%.mdk}.expected"
  [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL resolve/%s (no .expected)\n' "$name"; continue; }
  self="$("$CHECK" "$RT" "$CORE" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  want="$(LC_ALL=C sort < "$golden")"
  if [ "$self" = "$want" ]; then pass=$((pass+1)); printf 'ok   resolve/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL resolve/%s\n' "$name"; fi
done

# R3: import-error fixtures — bad imports should produce UnknownModule (right
# category) not a spurious typecheck error.  Oracle = committed .expected golden.
for f in "$ROOT"/test/import_error_fixtures/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.expected"
  [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL import_error/%s (no .expected)\n' "$name"; continue; }
  self="$("$CHECK" "$RT" "$CORE" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  want="$(LC_ALL=C sort < "$golden")"
  if [ "$self" = "$want" ]; then pass=$((pass+1)); printf 'ok   import_error/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL import_error/%s\n' "$name"
    printf '  want: %s\n  self: %s\n' "$want" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
