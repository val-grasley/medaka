#!/usr/bin/env bash
# diff_compiler_tmc_parity.sh — BOTH backends apply TMC to the SAME functions.
#
# Wraps test/tmc_census.sh: emits the pinned corpus (stack fixtures + wasm TMC
# fixtures + the compiler front-end module graph) through the LLVM and WasmGC
# emitters — on BOTH the prelude-free probe arm and the SHIPPING arm (the real
# `medaka build` pair, with typecheck + dictPass) — extracts each backend's
# per-function TMC decisions (the `; tmc:` / `;; tmc:` census markers both
# emitters write — fn name + mode: `trmc`, `group-root`, `group:<root>`), and
# FAILS on any set difference OR any missed `-- EXPECT-TMC:` coverage pin.
# This is the TMC-parity arc's acceptance gate: the shared detection/eligibility
# analysis (backend/trmc_analysis.mdk) guarantees parity by construction; this
# gate keeps any future backend-local gate from silently re-splitting the sets.
# The pins guard what parity cannot: both backends dropping the SAME function
# (the dict-param veto shipped exactly that way — WASM-TMC-GAP-DESIGN.md §3).
#
# Exit: 0 all corpus items match; 1 any DIFF/emit failure; 2 toolchain missing
# (wasm probe binaries not built — sh test/wasm/build_wasm_oracle.sh).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Self-provision the emit probes (CI shards build only build_oracles.sh oracles, and the
# emit probes are NOT in its ENTRIES — a SKIP here would silently drop the parity signal).
#
# Check EVERY probe the census reads, not just the first one. This used to test only
# wasm_emit_main, so a tree that happened to have that one but not wasm_emit_modules_main
# sailed past the guard and then died inside tmc_census.sh with
# "missing test/bin/wasm_emit_modules_main" — which reads like a regression and is not one.
# A guard that checks a subset of its dependencies is a guard that lies.
_need=""
for _p in llvm_emit_main wasm_emit_main wasm_emit_modules_main; do
  [ -x "$ROOT/test/bin/$_p" ] || _need="$_need $_p"
done
[ -z "$_need" ] || {
  echo "emit probes missing:$_need — building ..."
  # build_wasm_oracle.sh provides ONLY the wasm probes; llvm_emit_main is a
  # build_oracles.sh oracle.  Provision each from its actual producer — a
  # provision step that runs the wrong builder "succeeds" and then skips, which
  # reads like a toolchain problem and is not one (this gate did exactly that).
  case "$_need" in *llvm_emit_main*)
    FORCE=1 JOBS=1 sh "$ROOT/test/build_oracles.sh" --build-one llvm_emit_main > /dev/null 2>&1 ;;
  esac
  case "$_need" in *wasm_emit*)
    sh "$ROOT/test/wasm/build_wasm_oracle.sh" > /dev/null 2>&1 ;;
  esac
  for _p in llvm_emit_main wasm_emit_main wasm_emit_modules_main; do
    [ -x "$ROOT/test/bin/$_p" ] || {
      echo "skipping (could not build emit probe: $_p)"
      exit 2
    }
  done
}

OUT="$(mktemp -d /tmp/tmc_parity.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

if ! sh "$ROOT/test/tmc_census.sh" "$OUT" > "$OUT/census.log" 2>&1; then
  # Coverage pins (-- EXPECT-TMC) are checked against the SHIPPING sets: parity
  # between two sets that BOTH dropped a function is vacuous, so a pinned fn
  # missing from EITHER backend's shipping TMC set fails the census — report it
  # as the coverage failure it is, not as an emit error.
  if grep -q '^PINFAIL ' "$OUT/SUMMARY" 2>/dev/null; then
    echo "FAIL — TMC coverage pins missing from a backend's SHIPPING set:"
    grep '^PINFAIL ' "$OUT/SUMMARY"
    exit 1
  fi
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
# "# CRASH: cannot read fixture" and then passing forever. See docs/ops/TESTING-DESIGN.md §0.0.
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
