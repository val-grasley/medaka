#!/bin/sh
# build_construct_coverage.sh — coverage gate for the NATIVE `medaka build`,
# RE-ROOTED off the OCaml oracle (REROOT-PLAN §2d).
#
# For each construct fixture (test/construct_fixtures/*.mdk) it builds a native
# binary via the NATIVE `./medaka build` (emit host = ./medaka_emitter) and
# diffs the binary's stdout against the committed `<fixture>.build.golden`.
# The golden is the program's runtime stdout captured from the OCaml-built binary
# while OCaml was the validated backend oracle (sh test/capture_goldens.sh
# build_construct).  No OCaml at gate time.
#
# Goldens capture the BACKEND's actual output, incl. the parked native dispatch
# gaps (#54/#21/#55) — a fixture whose binary segfaults or prints nothing has an
# empty golden, which the native binary reproduces.  Only stdout is compared (not
# exit code), matching the original gate's `2>/dev/null` discipline.
#
# ── T-3 triage (2026-07-13) ──────────────────────────────────────────────────
# This gate was RED for months (excluded via test/CI-COVERAGE-EXCEPTIONS.txt)
# with "1 FAILING, 5 skipped" never looked at. Both turned out stale:
#   - FAILING `let_else` used the `let PAT = EXPR else DEFAULT` construct, which
#     was REMOVED from the language (see test/check_removed_constructs.sh). The
#     fixture + its .build.golden were retired, not resurrected.
#   - Of the 5 documented SKIPs, 4 (`tuple_neq`, `json_parse`,
#     `mod_reverse_string`, `type_alias`) turned out to be fixed already —
#     their documented gaps (operator-section `not`, multi-module stdlib
#     import resolution, type-alias unification) no longer reproduce on
#     current `./medaka build`. Verified individually, goldens captured, moved
#     into the normal pass set. Only `newtype_ctor_fn` is still a real,
#     reproducing gap (see below) and remains skipped.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
FIXTURES="$ROOT/test/construct_fixtures"
CC="${CC:-clang}"

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then :
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then :
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then :
else echo "libgc (bdw-gc) not found — skipping (install bdw-gc)"; exit 2; fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# SKIP is EMPTY — every previously-deferred construct now builds.
#
# Two independent efforts emptied this list from opposite ends:
#   * main (T-3, "build_construct_coverage is RED and unexamined") closed four:
#       tuple_neq, json_parse, mod_reverse_string, type_alias
#   * this branch closed the fifth, newtype_ctor_fn (bug #31) — the "dedicated
#     newtype-constructor task" main's own comment was waiting for. `newtype`
#     ctors were unbound at typecheck (registerData dropped DNewtype) AND at
#     eval (ctorsOfDecl/ctorTypeEntries dropped it too). Both fixed; golden
#     captured.
#
# Keep it empty. A construct that stops building should FAIL here, not be
# re-added to a skip-list — a skip-list cannot notice an accidental fix, so it
# rots. If something must be deferred, ledger it with a reason and an owner.
SKIP=""
skipped=0

pass=0; fail=0

check() {
  src="$1"
  label="$(basename "$src" .mdk)"
  bin="$WORK/$label.bin"
  golden="${src%.mdk}.build.golden"

  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (no .build.golden — run sh test/capture_goldens.sh build_construct)\n' "$label"; return
  fi
  if ! MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" \
       "$MEDAKA" build --allow-internal "$src" -o "$bin" >"$WORK/$label.out" 2>"$WORK/$label.err"; then
    fail=$((fail+1)); printf 'FAIL %s (native build)\n' "$label"
    sed 's/^/    /' "$WORK/$label.err" | head -5
    return
  fi
  native="$("$bin" 2>/dev/null)"
  expected="$(cat "$golden")"
  if [ "$native" = "$expected" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$label"
  else
    fail=$((fail+1)); printf 'FAIL %s (diff)\n' "$label"
    printf '%s' "$expected" > "$WORK/exp.txt"
    printf '%s' "$native"   > "$WORK/got.txt"
    diff "$WORK/exp.txt" "$WORK/got.txt" | head -8 | sed 's/^/    /'
  fi
}

for src in "$FIXTURES"/*.mdk; do
  label="$(basename "$src" .mdk)"
  case " $SKIP " in *" $label "*) skipped=$((skipped+1)); printf 'skip %s (known native-CLI gap — see header)\n' "$label"; continue ;; esac
  check "$src"
done

printf '\n%d ok, %d failing, %d skipped (of %d)\n' "$pass" "$fail" "$skipped" "$((pass+fail+skipped))"
[ "$fail" -eq 0 ]
