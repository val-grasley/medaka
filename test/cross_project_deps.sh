#!/bin/sh
# Cross-project dependency resolution gate (native loader).
#
# A project's medaka.toml may declare a [dependencies] section of the form
#
#     [dependencies]
#     <name> = "<relative-or-abs-path-to-sibling-project-root>"
#
# An import whose FIRST dotted segment equals a declared dep name is resolved by
# stripping that segment and resolving the remainder under the dep's root
# (`minilib.lib.minilib` -> `<minilib-root>/lib/minilib.mdk`).  A dep's OWN
# stdlib imports still resolve via the normal stdlib root.  This is a NATIVE /
# loader-only feature (selfhost/driver/loader.mdk); the frozen OCaml oracle is
# untouched, so this is a fresh dedicated gate (no oracle leg).
#
# Fixture (test/cross_project_fixtures/):
#   minilib/        — a single-module dependency project (lib/minilib.mdk, which
#                     itself `import list.{reverse, sort}` from stdlib).
#   consumer/       — declares `minilib = "../minilib"` and
#                     `import minilib.lib.minilib.{revSorted, double}`.
#
# Asserts native `medaka check` / `run` / `build`+exec all resolve the
# cross-project import and produce the expected output.  Goldens strip any
# absolute path so they are location-independent.
#
# Usage:  sh test/cross_project_deps.sh
# Exit:   0 if every subtest matches, else 1.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
FIX="$ROOT/test/cross_project_fixtures"
GOLD="$ROOT/test/cross_project_fixtures/goldens"
CONSUMER="$FIX/consumer/main.mdk"

[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

export MEDAKA_ROOT="$ROOT"
export MEDAKA_EMITTER="$EMITTER"

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }

# Replace the repo root with a stable token so goldens are location-independent.
strip_paths() { sed "s#$ROOT#<ROOT>#g"; }
# Unit-main no longer auto-prints, but keep the safety net (see diff_native_cli.sh).
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
got=$(bound "$MEDAKA" check "$CONSUMER" 2>&1 | strip_paths)
check_one check "$got"

# ── run ────────────────────────────────────────────────────────────────────
got=$(bound "$MEDAKA" run "$CONSUMER" 2>&1 | strip_unit | strip_paths)
check_one run "$got"

# ── build + exec ─────────────────────────────────────────────────────────────
OUT="$(mktemp)"
bound "$MEDAKA" build "$CONSUMER" -o "$OUT" >/dev/null 2>&1
got=$(bound "$OUT" 2>&1 | strip_unit | strip_paths)
rm -f "$OUT"
check_one build "$got"

echo "cross_project_deps: $pass/$((pass + fail))"
[ "$fail" -eq 0 ]
