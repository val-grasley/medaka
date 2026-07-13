#!/bin/sh
# diff_compiler_ci_shard_coverage.sh — every gate must be in exactly ONE CI shard.
#
# CI runs the 80+ diff_compiler_*.sh gates SHARDED across parallel hosted runners,
# each shard selected by a glob pattern in .github/workflows/ci.yml. A gate whose
# name matches NO shard's pattern is never run in CI — silently. It still passes
# locally, `run_gates.sh` still counts it, and nothing anywhere says it was skipped.
#
# THIS IS NOT HYPOTHETICAL. It happened the same day the sharding landed: the new
# perf-scaling gate (diff_compiler_perf_scaling.sh) matched none of the six shard
# patterns and would have silently never run in CI. It was caught only because
# someone ran this check by hand — which is exactly the wrong way to depend on it.
#
# So the check is now a GATE. A coverage check you have to remember to run is a
# coverage check that will eventually not get run.
#
# It is the same bug class this whole suite was hardened against, one level up:
#   * a missing oracle exited 2 = SKIP != FAIL  -> a fresh clone ran ZERO tests and
#     printed "0 failed"
#   * a gate dash could not parse exited 2      -> "skipped" for MONTHS, while also
#     failing
#   * `$ROOT/compiler/*.mdk` matched zero files -> the compiler's own sources fell
#     out of the desugar/mark corpora at the subfolder reorg
#   * a gate matching no CI shard               -> never runs, reports nothing
# Every one is "this didn't run" being indistinguishable from "this passed".
#
# Usage:  sh test/diff_compiler_ci_shard_coverage.sh
# Exit:   0 every gate is in exactly one shard; 1 a gate is uncovered or duplicated.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT/.github/workflows/ci.yml"

[ -f "$WF" ] || { echo "no CI workflow at $WF — nothing to check"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found (needed to parse the workflow YAML)"; exit 2; }

python3 - "$ROOT" "$WF" <<'PY'
import sys, glob, pathlib, re

root, wf = sys.argv[1], sys.argv[2]

try:
    import yaml
    doc = yaml.safe_load(open(wf))
    shards = doc['jobs']['gates']['strategy']['matrix']['include']
    pats = {e['name']: e['pattern'] for e in shards}
except Exception:
    # No PyYAML? Fall back to a regex over the `pattern:` lines. Do NOT silently
    # pass — a coverage check that cannot read the workflow must say so.
    txt = pathlib.Path(wf).read_text()
    found = re.findall(r'- name: (\w+)\n\s+pattern: "([^"]+)"', txt)
    if not found:
        print("FAIL: could not parse any shard patterns out of the workflow.")
        print("      This is a HARNESS failure, not a pass — refusing to certify coverage.")
        sys.exit(1)
    pats = dict(found)

all_gates = {pathlib.Path(p).stem for p in glob.glob(f'{root}/test/diff_compiler_*.sh')}
if not all_gates:
    print("FAIL: found no diff_compiler_*.sh gates at all (harness bug)")
    sys.exit(1)

seen, dupes = {}, []
for name, pat in pats.items():
    for g in re.findall(r"'([^']+)'", pat):
        for p in glob.glob(f'{root}/test/{g}.sh'):
            stem = pathlib.Path(p).stem
            if stem in seen:
                dupes.append((stem, seen[stem], name))
            seen[stem] = name

missing = sorted(all_gates - set(seen))

for name in pats:
    n = sum(1 for v in seen.values() if v == name)
    print(f"  {name:<10} {n:>2} gates")
print(f"  {'TOTAL':<10} {len(seen):>2} of {len(all_gates)}")

rc = 0
if missing:
    print()
    print("FAIL: these gates match NO CI shard and would SILENTLY NEVER RUN in CI:")
    for m in missing:
        print(f"       {m}")
    print("       Add them to a shard's `pattern` in .github/workflows/ci.yml.")
    rc = 1
if dupes:
    print()
    print("FAIL: these gates are in MORE THAN ONE shard (wasted CI time, confusing failures):")
    for g, a, b in dupes:
        print(f"       {g}: in both '{a}' and '{b}'")
    rc = 1
if rc == 0:
    print()
    print("PASS: every gate is in exactly one CI shard (0 missing, 0 duplicated).")
sys.exit(rc)
PY
