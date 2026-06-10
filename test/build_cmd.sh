#!/usr/bin/env bash
# test/build_cmd.sh — gate for `medaka build`: native-compile a user program
# via the LLVM backend and verify native output == interpreter (eval_probe) output.
#
# Stage 3 item 1: first user-facing entry to the LLVM backend.
#
# PRELUDE STATUS: `medaka build` currently passes an EMPTY prelude because
# `maximum`/`minimum` in core.mdk trigger the `max`/`min` arg-tag dispatch gap
# (EMITTER-GAPS.md gap #12 residual, 2 events) even for unreachable code.
# The flip to the real prelude is a one-line change in lib/build_cmd.ml once
# the D3b gap is closed (Stage 3 item 2b).  Until then these fixtures are
# prelude-free (no typeclass dispatch, no `println` — they use runtime externs
# directly and return plain values that the runtime auto-prints).
#
# The unit_head fixture directly validates the E20 gap closure (HUnit switch
# head — the final census-A emitter gap).
#
# Usage: bash test/build_cmd.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
PROBE="$ROOT/_build/default/dev/eval_probe.exe"
CC="${CC:-clang}"

[ -x "$MAIN"  ] || { echo "build first: dune build --root . (missing $MAIN)";  exit 2; }
[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0

run_case() {
  local name="$1" fpath="$2"
  local ref native
  ref="$("$PROBE" "$fpath" 2>/dev/null)"
  if ! "$MAIN" build --output "$WORK/$name" "$fpath" > "$WORK/$name.build.out" 2>&1; then
    fail=$((fail+1))
    printf 'FAIL %s (build failed)\n' "$name"
    cat "$WORK/$name.build.out"
    return
  fi
  native="$("$WORK/$name" 2>/dev/null)"
  if [ "$ref" = "$native" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1))
    printf 'FAIL %s\n  ref   : %s\n  native: %s\n' "$name" "$ref" "$native"
  fi
}

FIXDIR="$ROOT/test/llvm_fixtures"

# E20: unit-head switch — validates the HUnit irrefutable-descent fix.
# f () = 42; g x () = x + 1; main = f () + g 10 ()  → 53
run_case "unit_head"        "$FIXDIR/unit_head.mdk"

# Representative set covering key emitter features (prelude-free):
run_case "fn_factorial"     "$FIXDIR/fn_factorial.mdk"
run_case "adt_option"       "$FIXDIR/adt_option.mdk"
run_case "list_sum"         "$FIXDIR/list_sum.mdk"
run_case "global_ref_mut"   "$FIXDIR/global_ref_mut.mdk"
run_case "match_bool_true"  "$FIXDIR/match_bool_true.mdk"
run_case "guard_match_ctor" "$FIXDIR/guard_match_ctor.mdk"
run_case "str_concat"       "$FIXDIR/str_concat.mdk"

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
