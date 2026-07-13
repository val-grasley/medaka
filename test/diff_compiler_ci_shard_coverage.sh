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

# ── EVERY gate family, not just diff_compiler_*. ──────────────────────────────
#
# This gate used to enumerate ONLY test/diff_compiler_*.sh — and so it certified
# "82/82 covered, PASS" while the ENTIRE WasmGC BACKEND (4 gates, 153 fixtures, one
# of Medaka's two production backends) ran in NO CI job at all. Four real codegen
# failures had been sitting in it, unseen, because nothing was looking.
#
# The coverage gate had the same blind spot as the thing it was policing: it only
# checked the family it already knew about. A completeness check that defines its own
# scope will always certify itself complete. So the scope is now every gate script,
# and anything deliberately left out must say so out loud in CI-COVERAGE-EXCEPTIONS.txt.
GATE_GLOBS = [
    'test/diff_compiler_*.sh',
    'test/wasm/diff_*.sh',
    'test/bootstrap_*.sh',
    'test/selfcompile_fixpoint.sh',
    'test/typecheck_compiler_source.sh',
]
all_gates = set()
for g in GATE_GLOBS:
    all_gates |= {pathlib.Path(p).stem for p in glob.glob(f'{root}/{g}')}
if not all_gates:
    print("FAIL: found no gate scripts at all (harness bug)")
    sys.exit(1)

# A gate counts as covered if a shard pattern globs it OR the workflow names it
# literally in some step (that is how the `soundness` job runs the fixpoint and the
# compiler-source typecheck — they are not sharded, they are named).
wf_text = pathlib.Path(wf).read_text()

# Exceptions LEDGER: deliberately-not-in-CI, each with a reason. See the file header
# for why this is a ledger and not a skip-list.
exc = {}
exc_path = pathlib.Path(root) / 'test' / 'CI-COVERAGE-EXCEPTIONS.txt'
if exc_path.exists():
    for line in exc_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        stem, _, reason = line.partition(' ')
        exc[stem] = reason.strip()

seen, dupes = {}, []
for name, pat in pats.items():
    for g in re.findall(r"'([^']+)'", pat):
        for p in glob.glob(f'{root}/test/{g}.sh'):
            stem = pathlib.Path(p).stem
            if stem in seen:
                dupes.append((stem, seen[stem], name))
            seen[stem] = name

named = {g for g in all_gates if g not in seen and re.search(rf'\b{re.escape(g)}\.sh\b', wf_text)}
missing = sorted(all_gates - set(seen) - named - set(exc))

for name in pats:
    n = sum(1 for v in seen.values() if v == name)
    print(f"  {name:<10} {n:>2} gates")
print(f"  {'named':<10} {len(named):>2} gates (run by name, unsharded — e.g. the soundness job)")
if exc:
    print(f"  {'EXCEPTED':<10} {len(exc):>2} gates (NOT run in CI — ledger below)")
print(f"  {'TOTAL':<10} {len(seen) + len(named):>2} of {len(all_gates)} covered")

rc = 0
if exc:
    print()
    print("  CI-COVERAGE-EXCEPTIONS.txt — these gates do NOT run in CI:")
    for stem, reason in sorted(exc.items()):
        live = " (ledger entry is STALE — this gate no longer exists)" if stem not in all_gates else ""
        print(f"       {stem}: {reason}{live}")
    # A ledger entry for a gate that no longer exists is rot — the exact failure mode
    # a plain skip-list has. Fail on it, so the ledger cannot quietly outlive its gate.
    stale = sorted(set(exc) - all_gates)
    if stale:
        print()
        print("FAIL: the exceptions ledger names gates that DO NOT EXIST:")
        for s in stale:
            print(f"       {s}")
        print("       Remove them from test/CI-COVERAGE-EXCEPTIONS.txt.")
        rc = 1

if missing:
    print()
    print("FAIL: these gates match NO CI shard and would SILENTLY NEVER RUN in CI:")
    for m in missing:
        print(f"       {m}")
    print("       Add them to a shard's `pattern` in .github/workflows/ci.yml, run them")
    print("       by name in a job, or add them to test/CI-COVERAGE-EXCEPTIONS.txt WITH A REASON.")
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
