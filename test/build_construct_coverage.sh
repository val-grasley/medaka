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

# ── Worker: one fixture. Writes <label>.out (the lines to print) + <label>.st ──
#
# Dispatched BEFORE the toolchain probe below on purpose: the parent has already
# proven clang + libgc are present, and the libgc probe's fallback arm compiles a C
# file. Re-running it in each of 144 workers would spawn 144 pointless clangs.
#
# The old serial `check()` wrote its diff through two FIXED scratch paths
# ($WORK/exp.txt, $WORK/got.txt) shared by every fixture — already a latent footgun,
# and a real race here. The worker keys them on the label instead.
if [ "${1:-}" = "--one" ]; then
  src="$2"
  RD="$3"
  label="$(basename "$src" .mdk)"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  bin="$WORK/$label.bin"
  golden="${src%.mdk}.build.golden"
  out="$RD/$label.out"

  if [ ! -f "$golden" ]; then
    printf 'FAIL %s (no .build.golden — run sh test/capture_goldens.sh build_construct)\n' "$label" > "$out"
    echo fail > "$RD/$label.st"; exit 0
  fi
  if ! MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" \
       "$MEDAKA" build --allow-internal "$src" -o "$bin" >"$WORK/build.out" 2>"$WORK/build.err"; then
    { printf 'FAIL %s (native build)\n' "$label"
      sed 's/^/    /' "$WORK/build.err" | head -5
    } > "$out"
    echo fail > "$RD/$label.st"; exit 0
  fi
  native="$("$bin" 2>/dev/null)"
  expected="$(cat "$golden")"
  if [ "$native" = "$expected" ]; then
    printf 'ok   %s\n' "$label" > "$out"
    echo pass > "$RD/$label.st"
  else
    printf '%s' "$expected" > "$WORK/exp.txt"
    printf '%s' "$native"   > "$WORK/got.txt"
    { printf 'FAIL %s (diff)\n' "$label"
      diff "$WORK/exp.txt" "$WORK/got.txt" | head -8 | sed 's/^/    /'
    } > "$out"
    echo fail > "$RD/$label.st"
  fi
  exit 0
fi

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then :
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then :
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then :
else echo "libgc (bdw-gc) not found — skipping (install bdw-gc)"; exit 2; fi

# Known native-CLI gap DEFERRED (no .build.golden captured; gate skips it):
#   newtype_ctor_fn — a `newtype`'s implicit constructor used as a callable
#     (arity-1 function) or in a match pattern is not recognised by native
#     `check`/`build`: `Unknown constructor: UserId` / `Unbound variable:
#     UserId`. Reproduces on current `./medaka check`/`./medaka build`
#     (verified 2026-07-13; the fixture itself is annotated "Gap D2"). This is
#     a real, narrow compiler gap — not a stale fixture — left for a
#     dedicated newtype-constructor task; do not resurrect it here.
# SKIP is EMPTY — every previously-deferred construct now builds.
#
# Two independent efforts emptied this list from opposite ends:
#   * main (T-3) closed four: tuple_neq, json_parse, mod_reverse_string, type_alias
#   * this branch closed the fifth, newtype_ctor_fn (bug #31) — the "dedicated
#     newtype-constructor task" main's own comment was waiting for. `newtype` ctors
#     were unbound at typecheck (registerData dropped DNewtype) AND at eval
#     (ctorsOfDecl/ctorTypeEntries dropped it too). Both fixed; golden captured.
#
# Keep it empty. A construct that stops building should FAIL here, not be re-added to
# a skip-list — a skip-list cannot notice an accidental fix, so it rots.
SKIP=""

# ── Fan-out (2026-07-14) ──────────────────────────────────────────────────────
# 144 × (`medaka build` + clang), and it used to run them ONE AT A TIME: 282s of
# CPU and 282s of wall, on any machine, forever. It was the second-heaviest gate
# in the suite and the only heavy one that had no fan-out at all, which made
# whichever CI shard hosted it a 282s floor no amount of resharding could lower.
#
# Each fixture is independent: its own source, its own golden, its own output
# binary. `medaka build` stages its scratch IR in a per-PROCESS mktemp dir (fixed
# 2026-07-13 — it used to key on the output BASENAME in global /tmp, which is why
# concurrent builds silently produced each other's binaries), so N of them in
# flight is safe. diff_compiler_engines already runs 346 concurrent `medaka build`s
# over the same emitter and has for weeks.
#
# The verdict and the printed output are UNCHANGED: each worker writes its lines to
# a file and the parent replays them in fixture order, so a parallel run is
# byte-identical to a serial one (verified serial-vs-JOBS=6, 3 runs). JOBS=1
# restores the strictly-serial behaviour.
NCPU="$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
JOBS="${JOBS:-$NCPU}"

RD="$(mktemp -d)"
trap 'rm -rf "$RD"' EXIT

todo=""
for src in "$FIXTURES"/*.mdk; do
  label="$(basename "$src" .mdk)"
  case " $SKIP " in
    *" $label "*)
      printf 'skip %s (known native-CLI gap — see header)\n' "$label" > "$RD/$label.out"
      echo skip > "$RD/$label.st"
      continue ;;
  esac
  todo="$todo $src"
done

# ZERO-COMPARISON guard: an empty fixture dir must not report "0 ok, 0 failing" and
# exit 0 — a gate that compared nothing has proven nothing (docs/ops/TESTING-DESIGN.md §2.3).
[ -n "$todo" ] || { echo "no construct fixtures in $FIXTURES — the gate compared nothing"; exit 2; }

# CI FAST PATH: precompile runtime/medaka_rt.c ONCE, then have every one of the 144
# per-fixture `medaka build`s LINK that object (via MEDAKA_RT_OBJ) instead of
# recompiling the byte-identical runtime each time (~0.6s of clang saved per build).
# The compiler emits the object (`--emit-rt-obj`) with exactly the flags its own link
# uses, so it can't drift; inline-vs-prebuilt is proven byte-identical by
# test/diff_compiler_rt_obj.sh. Best-effort: on failure we don't export it and every
# build falls back to the (unchanged) inline compile. Workers inherit MEDAKA_RT_OBJ
# through the environment (xargs passes it down).
RTOBJ="$RD/medaka_rt.o"
if MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" "$MEDAKA" build --emit-rt-obj "$RTOBJ" >/dev/null 2>&1 && [ -f "$RTOBJ" ]; then
  export MEDAKA_RT_OBJ="$RTOBJ"
fi

# The worker re-derives ROOT/MEDAKA/EMITTER from $0 and the environment exactly as the
# parent did, so nothing needs passing down: MEDAKA_EMITTER (the only env input) is
# already inherited.
printf '%s\n' $todo | xargs -P "$JOBS" -I{} sh "$0" --one {} "$RD"

# Replay in fixture order, so the output is identical to the serial run's.
pass=0; fail=0; skipped=0
for src in "$FIXTURES"/*.mdk; do
  label="$(basename "$src" .mdk)"
  [ -f "$RD/$label.st" ] || {
    printf 'FAIL %s (worker produced no result)\n' "$label"; fail=$((fail+1)); continue
  }
  cat "$RD/$label.out"
  case "$(cat "$RD/$label.st")" in
    pass) pass=$((pass+1)) ;;
    skip) skipped=$((skipped+1)) ;;
    *)    fail=$((fail+1)) ;;
  esac
done

printf '\n%d ok, %d failing, %d skipped (of %d)\n' "$pass" "$fail" "$skipped" "$((pass+fail+skipped))"
[ "$fail" -eq 0 ]
