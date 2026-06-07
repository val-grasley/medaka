#!/bin/sh
# TYPED equivalence gate for the Stage 2.4 LLVM de-risking spike, slice 6 —
# TYPECLASS DISPATCH (STAGE2-DESIGN.md §2.4a).
#
# The plain harness (diff_selfhost_llvm.sh) drives the prelude-free, dispatch-free
# subset whose oracle is the UNTYPED tree-walker (dev/eval_probe.exe).  Dispatch
# needs types: a return-position method resolves by the RESULT type (RKey), which
# the untyped arg-tag fallback cannot do — and indeed eval_probe renders these
# fixtures WRONG (it leaks the dispatch wrapper, e.g. `<impl@Int:7>`).  So this
# harness swaps the oracle to the TYPED Core IR tree-walker: the SAME lowered Core
# IR the emitter consumes, evaluated by ceval instead of compiled — the equivalence
# the slice proves is exactly emit->clang->run  ==  ceval, over one typed IR.
#
# For each prelude-free dispatch fixture in test/llvm_fixtures_typed/:
#   1. ref  = medaka run core_ir_dict_pp_main.mdk  runtime.mdk <fixture>
#             (desugar -> elaborateDict: route-stamp + dict_pass -> lower -> ceval,
#              pp_value of `main`)
#   2. emit = medaka run llvm_emit_typed_main.mdk  runtime.mdk <fixture>
#             (the SAME front end, final consumer swapped to emit textual LLVM IR)
#   3. clang <emit>.ll runtime/medaka_rt.c -o bin
#   4. self = ./bin
#   diff ref vs self byte-for-byte.
#
# The fixtures are prelude-free (their own interface + impls) and reduce `main` to a
# scalar Int, so the harness passes ONLY runtime.mdk — elaborateDict resolves every
# route without pulling core.mdk's machinery into the emitted scalar module.
#
# Scope: slice 6 — RKey return-position dispatch (single + multi impl; the bootstrap
# path) and RDict/RDictFwd dict-passing (one `=>`-constrained fn).  No arg-tag (RNone)
# dispatch, no nested per-instance requires dicts, no GC.
#
# Usage:  sh test/diff_selfhost_llvm_typed.sh
# Exit:   0 if every fixture's native stdout matches the typed tree-walker; 2 if the
#         build is missing or no C compiler is available (spike is opt-in).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="$ROOT/_build/default/bin/main.exe"
ORACLE="$ROOT/selfhost/core_ir_dict_pp_main.mdk"
EMIT="$ROOT/selfhost/llvm_emit_typed_main.mdk"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
FIXDIR="$ROOT/test/llvm_fixtures_typed"
CC="${CC:-clang}"

[ -x "$MAIN" ] || { echo "build first: dune build --root . (missing $MAIN)"; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping spike"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  ref="$("$MAIN" run "$ORACLE" "$RUNTIME" "$f" 2>/dev/null)"
  ll="$WORK/$name.ll"
  bin="$WORK/$name.bin"
  if ! "$MAIN" run "$EMIT" "$RUNTIME" "$f" > "$ll" 2>"$WORK/emit.err"; then
    fail=$((fail+1)); printf 'FAIL %s (emit)\n%s\n' "$name" "$(cat "$WORK/emit.err")"; continue
  fi
  if ! "$CC" "$ll" "$RT" -o "$bin" 2>"$WORK/cc.err"; then
    fail=$((fail+1)); printf 'FAIL %s (clang)\n%s\n' "$name" "$(cat "$WORK/cc.err")"; continue
  fi
  self="$("$bin" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s (%s)\n' "$name" "$ref"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
