#!/bin/sh
# Batched variant of diff_compiler_check.sh — PROTOTYPE for prelude caching.
# Runs test/bin/check_batch ONCE over all diff_fixtures + resolve_fixtures
# in a single process (prelude parsed once), then splits the delimited output
# per fixture and compares each against the same oracle the per-file harness uses.
#
# OCaml-free (REROOT-PLAN §2b): native host test/bin/check_batch; oracle legs are
# the clean fixtures' committed `# TYPES_USER` snapshots (subset check, see below)
# + resolve_fixtures/*.expected (== dev/diagdump.exe --resolve at capture).  No
# live main.exe / diagdump.
#
# ── #81 Stage C: clean leg repointed to `# TYPES_USER` (was the full === TYPES ===) ──
# Mirrors diff_compiler_check.sh: the clean diff_fixtures leg no longer diffs the
# full ~117-line prelude+user === TYPES === golden (that redundant table moved to
# diff_compiler_snapshot_prelude.sh + diff_compiler_snapshot_types_user.sh). Here we
# prove the BATCHED composed driver's per-fixture TYPES output CONTAINS every user
# scheme line committed in test/snapshots/diff_fixtures_types/<n>.md (subset, via
# grep -Fxv membership). Prelude schemes are intentionally unpinned.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BATCH="$ROOT/test/bin/check_batch"
RT="$ROOT/stdlib/runtime.mdk"; CORE="$ROOT/stdlib/core.mdk"
[ -x "$BATCH" ] || { echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$BATCH") (missing $BATCH)"; exit 2; }

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }
# Extract the `# TYPES_USER` section (the last section) of a snapshot .md.
tu_section() { awk '/^# TYPES_USER$/{f=1;next} /^# /{f=0} f'; }
pass=0; fail=0

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Collect all target paths (diff fixtures that have a golden, then resolve fixtures)
targets=""
for g in "$ROOT"/test/diff_fixtures/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$ROOT/test/diff_fixtures/$fix.mdk" ] || continue
  targets="$targets $ROOT/test/diff_fixtures/$fix.mdk"
done
for f in "$ROOT"/test/resolve_fixtures/*.mdk; do
  targets="$targets $f"
done

# One process: parse prelude once, emit a delimited section per target.
ALL="$("$BATCH" "$RT" "$CORE" $targets 2>/dev/null | strip_unit)"

section() { awk -v p="$1" '$0=="===SELFHOST-FIX=== "p {f=1;next} /^===SELFHOST-FIX=== /{f=0} f'; }

for g in "$ROOT"/test/diff_fixtures/*.golden; do
  fix="$(basename "$g" .golden)"
  [ -f "$ROOT/test/diff_fixtures/$fix.mdk" ] || continue
  snap="$ROOT/test/snapshots/diff_fixtures_types/$fix.md"
  [ -f "$snap" ] || { fail=$((fail+1)); printf 'FAIL types/%s (no # TYPES_USER snapshot)\n' "$fix"; continue; }
  printf '%s' "$ALL" | section "$ROOT/test/diff_fixtures/$fix.mdk" > "$WORK/self"
  miss="$(tu_section < "$snap" | grep -Fxv -f "$WORK/self")"
  if [ -z "$miss" ]; then pass=$((pass+1)); printf 'ok   types/%s\n' "$fix"
  else fail=$((fail+1)); printf 'FAIL types/%s\n' "$fix"
    printf '%s\n' "$miss" | sed 's/^/  missing from check_batch TYPES: /'; fi
done

for f in "$ROOT"/test/resolve_fixtures/*.mdk; do
  name="$(basename "$f")"
  golden="${f%.mdk}.expected"
  [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL resolve/%s (no .expected)\n' "$name"; continue; }
  self="$(printf '%s' "$ALL" | section "$f" | LC_ALL=C sort)"
  want="$(LC_ALL=C sort < "$golden")"
  if [ "$self" = "$want" ]; then pass=$((pass+1)); printf 'ok   resolve/%s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL resolve/%s\n' "$name"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
