#!/bin/sh
# diff_compiler_rt_obj.sh — PROOF GATE for the MEDAKA_RT_OBJ build fast path.
#
# `medaka build` normally compiles runtime/medaka_rt.c inline on every build. The
# CI fast path precompiles that runtime ONCE (`medaka build --emit-rt-obj <path>`)
# and links the object via MEDAKA_RT_OBJ, so the heavy gates (diff_compiler_engines,
# build_construct_coverage, build_oracles) skip ~0.6s of redundant clang per build.
#
# That is only sound if the two link paths — inline `medaka_rt.c` vs prebuilt
# `medaka_rt.o` — produce the SAME binary. A one-time manual check (36/36 fixtures)
# proved they do; THIS GATE makes the proof permanent, so a future change to
# build_cmd.mdk / medaka_rt.c / the emitter that made the two paths diverge is
# caught here instead of silently miscompiling every fast-path build.
#
# For a sample of fixtures, at BOTH opt levels the suite uses (-O0 for oracles, -O2
# for the default/engines path), it builds each fixture TWICE — once inline, once
# with MEDAKA_RT_OBJ — and asserts the two binaries are byte-identical (whole file,
# not just .text: on this toolchain the prebuilt-object link reproduces the exact
# bytes of the inline compile, so we hold to the strictest possible check; if a
# future toolchain perturbs only non-.text metadata, relax to a .text compare and
# say why here).
#
# Usage:  sh test/diff_compiler_rt_obj.sh
# Exit:   0 if every (fixture, opt) pair is byte-identical inline-vs-prebuilt;
#         1 on any divergence or build failure;
#         2 if the native medaka/emitter is missing, no C compiler, or libgc is
#           absent (opt-in skip, same discipline as the other LLVM gates).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
EMITTER="${MEDAKA_EMITTER:-$ROOT/medaka_emitter}"
CC="${CC:-clang}"

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }

# libgc probe (mirror the other native gates' opt-in skip).
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then :
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then :
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then :
else echo "libgc (bdw-gc) not found — skipping (install bdw-gc)"; exit 2; fi

export MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER"

# A small, cheap, representative sample: an ordinary ADT program, both refutable-
# guard shapes (they exercise a nontrivial slice of the runtime), and a couple of
# construct fixtures. Kept small on purpose — this gate is a correctness tripwire,
# not a coverage sweep, and each entry is TWO builds × TWO opt levels.
SAMPLE="
$ROOT/test/llvm_fixtures/guard_match_ctor.mdk
$ROOT/test/llvm_fixtures/guard_refut_clause.mdk
$ROOT/test/llvm_fixtures/guard_refut_clause_chain.mdk
$ROOT/test/construct_fixtures/tuple_neq.mdk
$ROOT/test/construct_fixtures/type_alias.mdk
"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

checked=0
identical=0
fail=0

for OPT in -O0 -O2; do
  rtobj="$W/medaka_rt$OPT.o"
  if ! MEDAKA_CLANG_OPT="$OPT" "$MEDAKA" build --emit-rt-obj "$rtobj" >/dev/null 2>&1 || [ ! -f "$rtobj" ]; then
    echo "FAIL: could not --emit-rt-obj at $OPT"; fail=$((fail+1)); continue
  fi
  for src in $SAMPLE; do
    [ -f "$src" ] || { echo "FAIL: missing sample fixture $src"; fail=$((fail+1)); continue; }
    label="$(basename "$src" .mdk)"
    inline="$W/$label$OPT.inline"
    prebuilt="$W/$label$OPT.prebuilt"
    if ! MEDAKA_CLANG_OPT="$OPT" "$MEDAKA" build --allow-internal "$src" -o "$inline" >/dev/null 2>&1; then
      echo "FAIL: inline build failed ($label $OPT)"; fail=$((fail+1)); continue
    fi
    if ! MEDAKA_RT_OBJ="$rtobj" MEDAKA_CLANG_OPT="$OPT" "$MEDAKA" build --allow-internal "$src" -o "$prebuilt" >/dev/null 2>&1; then
      echo "FAIL: prebuilt build failed ($label $OPT)"; fail=$((fail+1)); continue
    fi
    checked=$((checked+1))
    if cmp -s "$inline" "$prebuilt"; then
      identical=$((identical+1))
      printf 'ok   %-28s %s  byte-identical\n' "$label" "$OPT"
    else
      fail=$((fail+1))
      printf 'FAIL %-28s %s  inline vs prebuilt DIFFER\n' "$label" "$OPT"
    fi
  done
done

# ZERO-COMPARISON guard (docs/ops/TESTING-DESIGN.md §2.3): a gate that compared
# nothing has proven nothing.
[ "$checked" -gt 0 ] || { echo "the sample built nothing — the gate proved nothing"; exit 2; }

printf '\n%d/%d fixture-builds byte-identical inline-vs-prebuilt (%d checked)\n' \
  "$identical" "$checked" "$checked"

# EXIT STATUS — gated EXPLICITLY on $fail. Every failure path above (a failed
# --emit-rt-obj, a missing fixture, a failed inline/prebuilt build, and a byte
# MISMATCH) increments $fail, and a byte-identity proof gate that observed a
# mismatch MUST exit nonzero — otherwise it is exactly the "detected a divergence
# and reported success" bug this whole optimization is guarding against. An
# explicit `exit` (not a trailing `[ "$fail" -eq 0 ]`) is deliberate: the trailing-
# test idiom leaves the final status to the shell's fall-off-the-end behavior,
# which an EXIT trap (`rm -rf "$W"` above) can override to 0 on some shells
# (notably macOS's bash-3.2 /bin/sh) — a silent green over a real mismatch. An
# explicit `exit N` is preserved through the trap on every shell.
if [ "$fail" -ne 0 ]; then
  printf 'FAILED: %d fixture-build(s) diverged inline-vs-prebuilt (or failed to build)\n' "$fail" >&2
  exit 1
fi
exit 0
