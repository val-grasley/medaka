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

# self-provision the wasm emit probes (CI shards build only build_oracles.sh
# oracles; a SKIP here would silently drop the parity signal — build instead).
[ -x "$ROOT/test/bin/wasm_emit_main" ] || {
  echo "wasm emit probes missing — building (sh test/wasm/build_wasm_oracle.sh) ..."
  sh "$ROOT/test/wasm/build_wasm_oracle.sh" > /dev/null 2>&1 || {
    echo "skipping (could not build the wasm emit probes)"
    exit 2
  }
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

# ⚠️ NEVER EXIT 0 HAVING COMPARED NOTHING.
#
# Without this, an empty SUMMARY (a broken corpus glob, a census that emitted no
# rows, a TMC pass that stopped qualifying anything) printed
#
#     tmc parity: 0/0 corpus items — both backends TMC identical function sets
#
# and exited 0. Two sets that are both EMPTY are trivially "identical", so the gate
# reported success while proving nothing at all.
#
# That is this repo's defining bug class — "this didn't run" being indistinguishable
# from "this passed". It has already appeared as: a missing oracle exiting 2 = SKIP
# (a fresh clone ran ZERO tests and printed "0 failed"); a gate dash could not parse,
# "skipped" for months while ALSO failing; `$ROOT/compiler/*.mdk` globbing to zero
# files so the compiler's own sources silently left the corpus; a preflight glob
# matching zero gates; a snapshot target that could not be read rendering as
# "# CRASH: cannot read fixture" and then passing forever. See TESTING-DESIGN.md §0.0.
#
# A parity gate is especially prone to it: parity between two empty sets is vacuous.
if [ "$n" -eq 0 ]; then
  echo "FAIL: the TMC parity census produced ZERO corpus items — this gate compared NOTHING."
  echo "      Two empty sets are trivially 'identical'; that is not a pass."
  echo "      Check test/tmc_census.sh's corpus glob and its SUMMARY output."
  exit 1
fi

echo "tmc parity: $n/$n corpus items — both backends TMC identical function sets"
exit 0
