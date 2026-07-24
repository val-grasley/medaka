#!/bin/sh
# diff_compiler_perf_stage_census.sh — a self-auditing META-gate: every pipeline stage
# the profilers emit must be GRADED by the perf gate or explicitly WAIVED. #886, epic #880.
#
# WHY THIS GATE EXISTS.
# Two of the perf-CI-coverage workstream's holes — the O(modules²) family and multi-module
# resolve — happened the same way: a WHOLE PIPELINE PASS was unmeasured and nothing in CI
# forced it to be. Adding N fixtures does not fix that class; making COVERAGE ITSELF a
# derived, self-draining property does. This gate is to the perf arms what
# diff_compiler_ci_shard_coverage.sh is to the CI shards: it refuses to let an unmeasured
# stage exist silently.
#
# WHAT IT DOES (pure text analysis — no compiler build, no oracle, fast + safe):
#   1. DERIVES the authoritative stage list by PARSING the `emitPhaseAO … "<stage>"` labels
#      out of compiler/entries/profile_main.mdk and profile_modules_main.mdk. It is NEVER a
#      hardcoded copy — a hardcoded census rots exactly like the thing it audits (DERIVE,
#      don't encode). The labels are static string literals today; if a profiler ever emits a
#      COMPUTED stage name this gate cannot see it and says so (a real finding about the
#      profiler's shape), rather than certifying a hole it can't observe.
#   2. Asserts every derived stage is GRADED (its name is in diff_compiler_perf_scaling.sh's
#      TIME_STAGES or OP_STAGES — both parsed live from that gate, not copied) OR WAIVED (a
#      line in test/PERF-STAGE-WAIVERS.txt with a reason). Neither -> FAIL, naming the stage
#      and the profiler file:line that emits it. THE SELF-DRAIN: a future new profiler stage
#      with no grading and no waiver reds CI until someone grades or waives it.
#   3. RATCHETS the waiver ledger, mirroring ci_shard_coverage's "ledger names a gate that
#      doesn't exist" check: a waiver for a stage the profilers no longer emit -> FAIL
#      (stale); a waiver for a stage that is now graded -> FAIL (orphan).
#   4. Prints `checked N stages`. N == 0 is a HARD FAILURE — a census that measured nothing
#      must never report green ("green" is not "ran"; every wasm gate once shelled out to an
#      absent tool, printed "skipping", and exited 0).
#
# It also verifies the perf gate keeps its OWN per-arm non-zero guards (backend_graded>0 and
# ops_graded>0) — those are what stop the perf gate exiting 0 having graded nothing, and a
# census of coverage should notice if they are deleted.
#
# Usage:  sh test/diff_compiler_perf_stage_census.sh
# Exit:   0 every derived stage is graded or waived (ledger clean); 1 otherwise.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PROFILERS="compiler/entries/profile_main.mdk compiler/entries/profile_modules_main.mdk"
PERF_GATE="test/diff_compiler_perf_scaling.sh"
WAIVERS="test/PERF-STAGE-WAIVERS.txt"

for f in $PROFILERS $PERF_GATE; do
  [ -f "$ROOT/$f" ] || { echo "FAIL: missing $f — cannot run the pass-coverage census."; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "python3 not found (needed for the census set logic)"; exit 2; }

python3 - "$ROOT" "$PERF_GATE" "$WAIVERS" $PROFILERS <<'PY'
import sys, re, pathlib

root      = pathlib.Path(sys.argv[1])
perf_gate = sys.argv[2]
waivers   = sys.argv[3]
profilers = sys.argv[4:]

# ── 1. DERIVE the stage list by parsing the profiler labels ──────────────────
# Each stage is the FIRST string literal of an `emitPhaseAO on "<stage>" …` call. The call
# head is either inline (`emitPhaseAO on "stage" …`) or a bare token whose args wrap to the
# next lines (the wasm-emit call does this). The IMPORT line `emitPhaseAO,` is NOT a call and
# must not trigger — it is excluded by requiring the token be followed by `on` or by nothing.
CALL_HEAD = re.compile(r'emitPhaseAO\s+on\b|emitPhaseAO\s*$')
STRLIT    = re.compile(r'"([^"]*)"')

stages = {}      # stage name -> "file:line" of its first occurrence (for reporting/naming)
dynamic = []     # call heads whose label we could NOT resolve to a static string literal
for pf in profilers:
    lines = (root / pf).read_text().splitlines()
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        stripped = line.lstrip()
        if stripped.startswith('--'):            # a commented-out example is not a real call
            i += 1
            continue
        if CALL_HEAD.search(line):
            head_ln = i + 1
            # Scan this line and following lines for the first string literal = the label.
            label = None
            j = i
            while j < n and j < i + 6:           # a label always lands within a few lines
                m = STRLIT.search(lines[j])
                if m:
                    label = m.group(1)
                    lbl_ln = j + 1
                    break
                j += 1
            if label is None:
                dynamic.append(f"{pf}:{head_ln}")
            else:
                stages.setdefault(label, f"{pf}:{lbl_ln}")
            i = (j if label is not None else i) + 1
            continue
        i += 1

# ── 2. DERIVE the graded set from the perf gate's TIME_STAGES / OP_STAGES ─────
gate_txt = (root / perf_gate).read_text()
def stage_list(var):
    m = re.search(rf'^{var}="([^"]*)"', gate_txt, re.M)
    return m.group(1).split() if m else None

time_stages = stage_list("TIME_STAGES")
op_stages   = stage_list("OP_STAGES")

rc = 0
if time_stages is None or op_stages is None:
    print("FAIL: could not parse TIME_STAGES / OP_STAGES out of " + perf_gate)
    print("      The census derives the GRADED set from those two assignments; if their")
    print("      shape changed, this gate must be taught the new shape (do not hardcode).")
    sys.exit(1)

graded = set(time_stages) | set(op_stages)

# ── read the waiver ledger ───────────────────────────────────────────────────
waived = {}
wp = root / waivers
if wp.exists():
    for ln in wp.read_text().splitlines():
        s = ln.strip()
        if not s or s.startswith('#'):
            continue
        stage, _, reason = s.partition(' ')
        waived[stage] = reason.strip()

# ── report ───────────────────────────────────────────────────────────────────
print(f"pass-coverage census — {len(stages)} distinct stages derived from the profilers")
print(f"  TIME_STAGES : {' '.join(time_stages)}")
print(f"  OP_STAGES   : {' '.join(op_stages)}")
print()
for st in sorted(stages):
    if st in graded:
        arms = []
        if st in time_stages: arms.append("TIME")
        if st in op_stages:   arms.append("OP")
        print(f"  GRADED  {st:<16} ({'+'.join(arms)})   {stages[st]}")
    elif st in waived:
        print(f"  WAIVED  {st:<16} {stages[st]}   — {waived[st]}")
    else:
        print(f"  UNGRADED {st:<15} {stages[st]}   *** neither graded nor waived ***")

# ── 3. the assertions ────────────────────────────────────────────────────────
if dynamic:
    print()
    print("FAIL: an emitPhaseAO call head has a stage label this gate could NOT resolve to a")
    print("      static string literal — so the census cannot see whether it is measured:")
    for d in dynamic:
        print(f"       {d}")
    print("      This is a real finding about the profiler's shape. Either give the stage a")
    print("      string-literal label, or teach this census how to derive the computed name.")
    rc = 1

missing = sorted(s for s in stages if s not in graded and s not in waived)
if missing:
    print()
    print("FAIL: these profiler stages are NEITHER graded nor waived — an UNMEASURED PASS")
    print("      would ship silently, the exact class this census exists to prevent:")
    for m in missing:
        print(f"       {m}   (emitted at {stages[m]})")
    print(f"      Grade it (add it to TIME_STAGES/OP_STAGES in {perf_gate}, or a bespoke arm),")
    print(f"      or WAIVE it with a reason in {waivers}.")
    rc = 1

# ledger ratchet: stale (stage no longer emitted) and orphan (stage now graded)
stale  = sorted(w for w in waived if w not in stages)
orphan = sorted(w for w in waived if w in graded)
if stale:
    print()
    print(f"FAIL: {waivers} waives stages the profilers NO LONGER emit (stale — the ledger")
    print("      must not outlive its stage):")
    for s in stale:
        print(f"       {s}")
    rc = 1
if orphan:
    print()
    print(f"FAIL: {waivers} waives stages that are NOW GRADED (orphan — grading superseded the")
    print("      waiver; remove the waiver so the stage is measured, not excused):")
    for o in orphan:
        print(f"       {o}")
    rc = 1

# ── the perf gate's own per-arm non-zero guards must still exist ──────────────
for guard, label in (
        (r'backend_graded"?\s*-eq\s*0', "backend_graded>0 (backend TIME arm, #359)"),
        (r'ops_graded"?\s*-eq\s*0',     "ops_graded>0 (op-count arm, #884)")):
    if not re.search(guard, gate_txt):
        print()
        print(f"FAIL: {perf_gate} no longer guards {label} — that assertion is what stops the")
        print("      perf gate exiting 0 having graded nothing on that arm. Restore it.")
        rc = 1

# ── 4. N == 0 is a hard failure ──────────────────────────────────────────────
if not stages:
    print()
    print("FAIL: derived 0 stages from the profilers — the census matched nothing and would")
    print("      have reported green. The derivation is broken, not the tree.")
    sys.exit(1)

print()
if rc == 0:
    print(f"PASS: checked {len(stages)} stages — every one is graded or waived, ledger clean.")
else:
    print(f"checked {len(stages)} stages — see failures above.")
sys.exit(rc)
PY
