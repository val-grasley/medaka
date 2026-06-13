#!/bin/sh
# diff_selfhost_build.sh — gate for the SELF-HOSTED `medaka build`, RE-ROOTED off
# the OCaml oracle (REROOT-PLAN §2d).
#
# The binary under test is produced by the NATIVE `./medaka build` CLI, whose
# emit host is the native ./medaka_emitter (MEDAKA_EMITTER) — i.e. the self-hosted
# build driver (selfhost/entries/build_main.mdk) + the Medaka-hosted LLVM emitter
# + clang, with NO OCaml in the loop.  For each fixture (test/build_diff_fixtures/
# *.mdk, formerly inline heredocs) it builds the native binary and diffs its stdout
# against the committed `<fixture>.build.golden`.
#
# The golden is the program's runtime stdout captured from the OCaml-built binary
# while OCaml was the validated backend oracle (sh test/capture_goldens.sh
# build_diff).  The OCaml CLI and the self-hosted driver invoke the SAME emitter +
# clang command, so the two binaries are behaviourally identical; the golden thus
# captures the backend's actual output, including any parked native dispatch gaps
# (#54/#21/#55 — e.g. map_impl exercises Map `toList`/compare).  Only stdout is
# compared (not exit code), matching the original `2>/dev/null` discipline.
#
# Usage:  sh test/diff_selfhost_build.sh
# Exit:   0 if every native binary's stdout == golden;
#         1 on any build/diff failure;
#         2 if the native medaka/emitter is missing, no C compiler, or libgc
#           is absent (opt-in skip, same discipline as the other LLVM gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
FIX="$ROOT/test/build_diff_fixtures"
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

pass=0; fail=0

check() { # $1=label  $2=mdk-path
  label="$1"; src="$2"
  bin="$WORK/$label.bin"
  golden="${src%.mdk}.build.golden"
  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (no .build.golden — run sh test/capture_goldens.sh build_diff)\n' "$label"; return
  fi
  if ! MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" \
       "$MEDAKA" build "$src" -o "$bin" >"$WORK/$label.sb.out" 2>"$WORK/$label.sb.err"; then
    fail=$((fail+1)); printf 'FAIL %s (native build)\n' "$label"
    sed 's/^/    /' "$WORK/$label.sb.err" | head -6
    return
  fi
  sb="$("$bin" 2>/dev/null)"
  expected="$(cat "$golden")"
  if [ "$sb" = "$expected" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$label"
  else
    fail=$((fail+1)); printf 'FAIL %s (diff)\n' "$label"
    printf '  native  : %s\n' "$(printf '%s' "$sb" | tr '\n' '|')"
    printf '  expected: %s\n' "$(printf '%s' "$expected" | tr '\n' '|')"
  fi
}

PROGRAMS="arith recur adt list closure maxalias maxprim clampc sum_twocstr sumprod_float numpoly show_debug eq deriving map_impl g4_box_eq foldmap ord_parametric"
for p in $PROGRAMS; do
  check "$p" "$FIX/$p.mdk"
done
check "multimodule" "$FIX/mm/entry.mdk"
check "l1_twomod" "$FIX/l1/entry.mdk"
check "nested_subfolder" "$FIX/nested/main.mdk"

printf '\n%d ok, %d failing (of %d)\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
