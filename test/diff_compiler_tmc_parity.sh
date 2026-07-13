#!/usr/bin/env bash
# diff_compiler_tmc_parity.sh — BOTH backends apply TMC to the SAME functions.
#
# Wraps test/tmc_census.sh: emits the pinned corpus (stack fixtures + wasm TMC
# fixtures + the compiler front-end module graph) through the LLVM and WasmGC
# emitters, extracts each backend's per-function TMC decisions (the `; tmc:` /
# `;; tmc:` census markers both emitters write — fn name + mode: `trmc`,
# `group-root`, `group:<root>`), and FAILS on any set difference.  This is the
# TMC-parity arc's acceptance gate: the shared detection/eligibility analysis
# (backend/trmc_analysis.mdk) guarantees parity by construction; this gate keeps
# any future backend-local gate from silently re-splitting the sets.
#
# Exit: 0 all corpus items match; 1 any DIFF/emit failure; 2 toolchain missing
# (wasm probe binaries not built — sh test/wasm/build_wasm_oracle.sh).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[ -x "$ROOT/test/bin/wasm_emit_main" ] || {
  echo "skipping (build the wasm emit probes first: sh test/wasm/build_wasm_oracle.sh)"
  exit 2
}

OUT="$(mktemp -d /tmp/tmc_parity.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

if ! sh "$ROOT/test/tmc_census.sh" "$OUT" > "$OUT/census.log" 2>&1; then
  echo "FAIL (census emit error)"
  tail -20 "$OUT/census.log"
  exit 1
fi

if grep -q '^DIFF ' "$OUT/SUMMARY"; then
  echo "FAIL — the backends TMC different function sets:"
  grep -A 10 '^DIFF ' "$OUT/SUMMARY"
  exit 1
fi

n="$(grep -c '^same ' "$OUT/SUMMARY")"
echo "tmc parity: $n/$n corpus items — both backends TMC identical function sets"
exit 0
