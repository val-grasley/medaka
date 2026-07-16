#!/bin/sh
# test/diff_compiler_check_json.sh — gate for `medaka check --json`.
#
# OCaml-free (LIB-REMOVAL-DESIGN §6 Stage A): compares ./medaka check --json
# <fixture> against a committed native golden
# (test/check_json_fixtures/<name>.check_json.golden), byte-identical per fixture,
# with the absolute fixture path replaced by a stable placeholder so the output
# is path-stable (no /Users/... in diffs).  The committed goldens were captured
# from the canonical native ./medaka — no live OCaml oracle.
#
# Fixtures: test/check_json_fixtures/
#   clean.mdk         — no errors → empty diagnostics array
#   type_mismatch.mdk — 1 + "x" → No impl of Num for String
#   no_impl.mdk       — debug of type with no Debug impl
#   multi_stmt.mdk    — multi-binding clean file
#   sig_mismatch.mdk  — signature mismatch (Int → String body)
#   parse_error.mdk / resolve_* — diagnostics surfaced by the native front end
#
# Also: test/check_json_fixtures/projects/<name>/ — MULTI-MODULE project fixtures
# (medaka.toml + main.mdk entry importing a sibling), run through the multi-module
# `check --json` path and diffed against <name>/check_json.golden.  These lock in
# the #159 fix that an IMPORTED (non-last) module's error carries its `help`/`fix`
# in `--json` (the pre-#159 message-keyed side-channel dropped it for non-last
# modules).  See the project-loop comment below.
#
# To regenerate the goldens: sh test/capture_goldens.sh check_json  (single-file),
#   and  CAPTURE=1 sh test/diff_compiler_check_json.sh  (project fixtures).
#
# Usage:  sh test/diff_compiler_check_json.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="$ROOT/medaka"
FIXDIR="$ROOT/test/check_json_fixtures"

[ -x "$NATIVE" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }
[ -d "$FIXDIR" ] || { echo "FAIL: missing $FIXDIR"; exit 1; }

export MEDAKA_ROOT="$ROOT"

pass=0; fail=0

for mdk in "$FIXDIR"/*.mdk; do
  name="$(basename "$mdk" .mdk)"
  golden="${mdk%.mdk}.check_json.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (missing golden %s)\n' "$name" "$golden"; continue
  fi

  # Run native; replace the absolute path with a stable placeholder.
  tmpout="$(mktemp)"
  perl -e 'alarm 60; exec @ARGV' "$NATIVE" check --json "$mdk" > "$tmpout" 2>&1
  native_out="$(sed "s|$mdk|<fixture>|g" "$tmpout")"
  rm -f "$tmpout"
  ref_out="$(cat "$golden")"

  if [ "$native_out" = "$ref_out" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '  native: %s\n' "$native_out"
    printf '  golden: %s\n' "$ref_out"
  fi
done

# ── multi-module project fixtures (#159 regression lock) ────────────────────
# Each test/check_json_fixtures/projects/<name>/ is a small medaka.toml project
# whose entry main.mdk imports a sibling module.  `check --json <entry>` routes
# through the multi-module analyzeProject path and emits a per-file "files" array.
# The committed check_json.golden asserts the FULL diagnostic — INCLUDING `help`
# and `fix{range,replacement}` — on the IMPORTED (non-last) module's error.
# Before #159 those two structured fields were DROPPED for any non-last module
# (the message-keyed help side-channel was cleared per module by resetState and
# looked up only after the LAST module processed), so this golden fails against
# that old behaviour.  TcDiag carries help/fix per-diagnostic, so it survives.
# The project dir's absolute path is placeholdered to <proj>/ for path-stability.
# Regenerate:  CAPTURE=1 sh test/diff_compiler_check_json.sh
PROJDIR="$FIXDIR/projects"
if [ -d "$PROJDIR" ]; then
  for d in "$PROJDIR"/*/; do
    [ -d "$d" ] || continue
    name="project/$(basename "$d")"
    entry="${d}main.mdk"
    golden="${d}check_json.golden"
    if [ ! -f "$entry" ]; then
      fail=$((fail+1)); printf 'FAIL %s (no main.mdk entry)\n' "$name"; continue
    fi
    tmpout="$(mktemp)"
    perl -e 'alarm 120; exec @ARGV' "$NATIVE" check --json "$entry" > "$tmpout" 2>&1
    # Diagnostic `file` paths are normalized to project-root-relative (#298), so the
    # dep files land as $ROOT-relative, not absolute.  Placeholder both the absolute
    # dir (defensive) and its $ROOT-relative form so the golden stays `<proj>/…`.
    rel_d="${d#$ROOT/}"
    native_out="$(sed -e "s|$d|<proj>/|g" -e "s|$rel_d|<proj>/|g" "$tmpout")"
    rm -f "$tmpout"
    if [ "${CAPTURE:-0}" = "1" ]; then
      printf '%s\n' "$native_out" > "$golden"
      printf 'CAPTURE %s\n' "$golden"; continue
    fi
    if [ ! -f "$golden" ]; then
      fail=$((fail+1)); printf 'FAIL %s (missing golden %s)\n' "$name" "$golden"; continue
    fi
    ref_out="$(cat "$golden")"
    if [ "$native_out" = "$ref_out" ]; then
      pass=$((pass+1)); printf 'ok   %s\n' "$name"
    else
      fail=$((fail+1)); printf 'FAIL %s\n' "$name"
      printf '  native: %s\n' "$native_out"
      printf '  golden: %s\n' "$ref_out"
    fi
  done
fi

echo ""
printf '%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
