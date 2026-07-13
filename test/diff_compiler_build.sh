#!/bin/sh
# diff_compiler_build.sh — gate for the SELF-HOSTED `medaka build`, RE-ROOTED off
# the OCaml oracle (REROOT-PLAN §2d).
#
# The binary under test is produced by the NATIVE `./medaka build` CLI, whose
# emit host is the native ./medaka_emitter (MEDAKA_EMITTER) — i.e. the self-hosted
# build driver (compiler/entries/build_main.mdk) + the Medaka-hosted LLVM emitter
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
# Usage:  sh test/diff_compiler_build.sh
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

# ── Per-fixture worker (parallel fan-out target) ───────────────────────────────
# Re-invoked as `sh "$0" --one <label> <src>`. Shared state via env. These are
# throwaway output-compared binaries, so build them at -O0 (MEDAKA_CLANG_OPT) —
# clang -O2 is ~half the per-build wall time and buys nothing here. Writes
# ok/FAIL to $RESULTDIR/<label>.{status,out}.
if [ "${1:-}" = "--one" ]; then
  label="$2"; src="$3"
  bin="$WORKDIR/$label.bin"
  golden="${src%.mdk}.build.golden"
  st=0; msg=""
  if [ ! -f "$golden" ]; then
    msg="FAIL $label (no .build.golden — run sh test/capture_goldens.sh build_diff)"; st=1
  elif ! MEDAKA_ROOT="$ROOT" MEDAKA_EMITTER="$EMITTER" MEDAKA_CLANG_OPT="${BUILD_OPT:--O0}" \
         "$MEDAKA" build "$src" -o "$bin" >"$WORKDIR/$label.sb.out" 2>"$WORKDIR/$label.sb.err"; then
    msg="$(printf 'FAIL %s (native build)\n%s' "$label" "$(sed 's/^/    /' "$WORKDIR/$label.sb.err" | head -6)")"; st=1
  else
    sb="$("$bin" 2>/dev/null)"; expected="$(cat "$golden")"
    if [ "$sb" = "$expected" ]; then msg="ok   $label"
    else msg="$(printf 'FAIL %s (diff)\n  native  : %s\n  expected: %s' "$label" "$(printf '%s' "$sb" | tr '\n' '|')" "$(printf '%s' "$expected" | tr '\n' '|')")"; st=1; fi
  fi
  printf '%s\n' "$msg" > "$RESULTDIR/$label.out"
  echo "$st" > "$RESULTDIR/$label.status"
  printf '%s\n' "$msg"
  exit 0
fi

[ -x "$MEDAKA" ]  || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -x "$EMITTER" ] || { echo "build native first: make medaka (missing $EMITTER)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then :
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then :
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then :
else echo "libgc (bdw-gc) not found — skipping (install bdw-gc)"; exit 2; fi

WORK="$(mktemp -d)"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$WORK" "$RESULTS"' EXIT

PROGRAMS="arith recur adt list closure maxalias maxprim clampc sum_twocstr sumprod_float numpoly show_debug eq deriving map_impl g4_box_eq foldmap ord_parametric set_literal map_literal set_literal_string monoid_mutual_rec inferred_rec_dict same_head_typeargs letgroup_toplevel float_eform super_returnpos return_pos_most_specific super_method ambns undet_sole undet_chain3b method_constraint_dispatch string_index_slice eq_constraint_op eq_custom_dispatch method_closure_dict poly_unit_main list_index_slice num_hof_ambig record_in_list field_collision pap_wrapped_saturate bimappable_tuple div_by_zero mod_by_zero nonexhaustive comp_tuple comp_list comp_adt_display comp_bool comp_sig_tuple definer_shadow_dispatch definer_shadow_nway semigroup_append_operator negate_num_operator"

# Build the (label, src) worklist: plain programs + the multi-module specials.
{
  for p in $PROGRAMS; do printf '%s\t%s\n' "$p" "$FIX/$p.mdk"; done
  printf '%s\t%s\n' "multimodule"      "$FIX/mm/entry.mdk"
  printf '%s\t%s\n' "l1_twomod"        "$FIX/l1/entry.mdk"
  printf '%s\t%s\n' "nested_subfolder" "$FIX/nested/main.mdk"
  printf '%s\t%s\n' "bimappable_constrained_sibling" "$FIX/bimappable_constrained_sibling/main.mdk"
  printf '%s\t%s\n' "bimappable_tuple_sibling"       "$FIX/bimappable_tuple_sibling/main.mdk"
  printf '%s\t%s\n' "traverse_parametric_sibling"    "$FIX/traverse_parametric_sibling/main.mdk"
} > "$WORK/worklist.tsv"

JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"

# Fan the worklist across an xargs -P pool of --one workers (tab-separated
# label + src passed as two args; see top of file).
ROOT="$ROOT" MEDAKA="$MEDAKA" EMITTER="$EMITTER" BUILD_OPT="${BUILD_OPT:-}" \
WORKDIR="$WORK" RESULTDIR="$RESULTS" \
  xargs -P "$JOBS" -n 2 sh "$0" --one < "$WORK/worklist.tsv"

pass=0; fail=0
for s in "$RESULTS"/*.status; do
  [ -f "$s" ] || continue
  if [ "$(cat "$s")" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done

printf '\n%d ok, %d failing (of %d)\n' "$pass" "$fail" "$((pass+fail))"
[ "$fail" -eq 0 ]
