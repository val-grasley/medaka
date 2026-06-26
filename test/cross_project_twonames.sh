#!/bin/sh
# Cross-project TWO-NAMES module-identity gate (native loader, F1b corner).
#
# The residual corner of the F1b module-identity fix: ONE physical dependency
# file reached under TWO different dep NAMES.  The entry app declares the shared
# project as `sh = "../shared"`; an intermediate dependency (`mid`) declares the
# SAME directory as `core2 = "../shared"`.  The two declarations join to DIFFERENT
# literal `..`-bearing root strings (`app/../shared` vs `mid/../shared`) yet
# realpath to the same directory.  The shared module declares an `export impl`, so
# loading it twice (under two canonical ids) trips `conflicting impl` — UNLESS the
# loader realpath-canonicalizes both dep roots so both spellings collapse to one
# canonical module id and the file loads ONCE (compiler/driver/loader.mdk's
# canonicalizePath in canonicalModId / revLookupRoot).
#
# Fixture (test/cross_project_fixtures/twonames/):
#   shared/   — the shared dep (lib/shared.mdk: an `export impl Tagger Int`).
#   mid/      — declares `core2 = "../shared"`, imports `core2.lib.shared`.
#   app/      — declares `sh = "../shared"` + `mid = "../mid"`, imports both.
#
# Asserts native `medaka check` / `run` / `build`+exec all resolve the two-names
# import to ONE module (no `conflicting impl`).  NATIVE / loader-only feature; the
# frozen OCaml oracle is untouched, so this is a dedicated gate (no oracle leg).
#
# Usage:  sh test/cross_project_twonames.sh
# Exit:   0 if every subtest matches, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
FIX="$ROOT/test/cross_project_fixtures/twonames"
GOLD="$FIX/goldens"
APP="$FIX/app/main.mdk"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

export MEDAKA_ROOT="$ROOT"
export MEDAKA_EMITTER="$EMITTER"

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }

strip_paths() { sed "s#$ROOT#<ROOT>#g"; }
strip_unit() { sed '${/^0$/d;}'; }

pass=0; fail=0

check_one() {
  name="$1"; got="$2"; goldf="$GOLD/$name.golden"
  if [ ! -f "$goldf" ]; then
    echo "MISSING GOLDEN: $goldf"; fail=$((fail + 1)); return
  fi
  if [ "$got" = "$(cat "$goldf")" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $name"
    echo "  --- expected ---"; cat "$goldf" | sed 's/^/  /'
    echo "  --- got ---";      printf '%s\n' "$got" | sed 's/^/  /'
  fi
}

# ── check ──────────────────────────────────────────────────────────────────
got=$(bound "$MEDAKA" check "$APP" 2>&1 | strip_paths)
check_one check "$got"

# ── run ────────────────────────────────────────────────────────────────────
got=$(bound "$MEDAKA" run "$APP" 2>&1 | strip_unit | strip_paths)
check_one run "$got"

# ── build + exec ─────────────────────────────────────────────────────────────
OUT="$(mktemp)"
bound "$MEDAKA" build "$APP" -o "$OUT" >/dev/null 2>&1
got=$(bound "$OUT" 2>&1 | strip_unit | strip_paths)
rm -f "$OUT"
check_one build "$got"

echo "cross_project_twonames: $pass/$((pass + fail))"
[ "$fail" -eq 0 ]
