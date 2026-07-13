#!/bin/sh
# diff_compiler_ci_shard_coverage.sh — every gate must be in exactly ONE CI shard.
#
# CI runs the 80+ diff_compiler_*.sh gates SHARDED across parallel hosted runners,
# each shard selected by a glob pattern in .github/workflows/ci.yml. A gate whose
# name matches NO shard's pattern is never run in CI — silently. It still passes
# locally, `run_gates.sh` still counts it, and nothing anywhere says it was skipped.
#
# This gate scans EVERY workflow file under .github/workflows/, not just ci.yml —
# a gate that is deliberately unsuited to the PR path (a slow tree-wide scan, a
# nondeterministic fuzzer) can be "named" by a step in a scheduled workflow
# (e.g. nightly.yml) instead, and that counts as covered too. Only ci.yml's
# `gates` job matrix contributes shard `pattern:` entries (that's the only job
# with a `strategy.matrix.include` shape) — a NAMED reference (a gate script
# invoked literally in a `run:` step, in ANY workflow file) is enough either way.
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
WFDIR="$ROOT/.github/workflows"

[ -d "$WFDIR" ] || { echo "no workflow dir at $WFDIR — nothing to check"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found (needed to parse the workflow YAML)"; exit 2; }

python3 - "$ROOT" "$WFDIR" <<'PY'
import sys, glob, pathlib, re, subprocess

root, wfdir = sys.argv[1], sys.argv[2]

wf_paths = sorted(pathlib.Path(wfdir).glob('*.yml')) + sorted(pathlib.Path(wfdir).glob('*.yaml'))
if not wf_paths:
    print(f"FAIL: no workflow files under {wfdir} — nothing to check")
    sys.exit(1)

# `pats` (shard name -> glob pattern) only ever comes from a job shaped like
# ci.yml's `gates` job (a `strategy.matrix.include` list of {name, pattern}
# dicts) — but that shape isn't unique to ci.yml BY DESIGN: any workflow file
# may define shard-style matrix coverage and it is picked up the same way.
# `wf_text` is the concatenation of every workflow file's raw text, so a gate
# named literally in a `run:` step in ANY workflow (e.g. nightly.yml) counts.
pats = {}
wf_text_parts = []
parse_failed = []
for wf in wf_paths:
    txt = wf.read_text()
    wf_text_parts.append(txt)
    try:
        import yaml
        doc = yaml.safe_load(txt)
        for job in (doc.get('jobs') or {}).values():
            include = (((job or {}).get('strategy') or {}).get('matrix') or {}).get('include')
            if not include:
                continue
            for e in include:
                if 'name' in e and 'pattern' in e:
                    pats[e['name']] = e['pattern']
    except Exception:
        # No PyYAML, or this file didn't parse? Fall back to a regex over the
        # `pattern:` lines for THIS file. Do NOT silently drop it — a coverage
        # check that cannot read a workflow must say so, not pretend it's empty.
        found = re.findall(r'- name: (\w+)\n\s+pattern: "([^"]+)"', txt)
        if found:
            pats.update(dict(found))
        else:
            parse_failed.append(str(wf))

wf_text = '\n'.join(wf_text_parts)

if parse_failed and not pats:
    print("FAIL: could not parse any shard patterns out of any workflow, and these files")
    print("      could not even be regex-scanned as a fallback:")
    for p in parse_failed:
        print(f"       {p}")
    print("      This is a HARNESS failure, not a pass — refusing to certify coverage.")
    sys.exit(1)

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
# EVERY script under test/ and test/wasm/. Not a curated list of globs.
#
# The curated version enumerated `test/diff_compiler_*.sh` (later plus wasm/bootstrap) and
# so certified coverage while a DOZEN REAL GATES had never run in CI: cross_project_*,
# diff_native_cli, diff_native_stack, diff_net, the four effect_*_domain gates,
# selfcompile_emit, manifest_emit, lsp_harness, fuzz_diff, build_construct_coverage,
# check_removed_constructs. I wrote that curated list MYSELF, one day after building this
# gate to catch exactly this — because I listed the globs I already knew about.
#
# So the scope is now EVERYTHING, and every script must be classified exactly once:
#   in a CI shard  |  named by a job  |  in the EXCEPTIONS ledger  |  in the TOOLS list.
# A new script that is none of the four fails this gate. That is the point: you cannot
# add a gate and forget to run it, and you cannot quietly shrink the scope.
#
# ── AND IT DID IT AGAIN, ONE LEVEL UP (fixed 2026-07-13) ──────────────────────
#
# The line above used to read:
#
#     all_gates = {pathlib.Path(p).stem
#                  for p in glob.glob(f'{root}/test/*.sh') + glob.glob(f'{root}/test/wasm/*.sh')}
#
# "EVERYTHING" meant everything *under test/*. So this gate — whose entire reason for
# existing is the sentence "a completeness check that defines its own scope will always
# certify itself complete" — DEFINED ITS OWN SCOPE, AND CERTIFIED ITSELF COMPLETE. It
# printed "106 of 110 covered, PASS" while THIRTY-EIGHT scripts sat outside its two globs,
# including 24 REAL GATES that ran nowhere:
#
#   sqlite/test/*_oracle.sh    22 differential gates diffing the pure-Medaka SQLite
#                              library against the real sqlite3 CLI. All 22 green. None ran.
#   test/native_fixtures/run.sh  11 native-only regression assertions — in a SUBDIRECTORY
#                              of test/, so even the `test/*.sh` glob missed it. RED: 2
#                              failing, and nobody knew (see the EXCEPTIONS ledger).
#   playground/e2e/run.sh      the Playwright browser harness.
#
# Two separate blind spots, same shape: a curated glob list (`test/*.sh`, `test/wasm/*.sh`)
# instead of an actual enumeration. So the scope is now literally EVERY `.sh` IN THE REPO.
# Not test/. Not a list of roots someone remembered. The whole tree.
#
# A gate is identified by its REPO-RELATIVE PATH (minus `.sh`), not its basename: basenames
# COLLIDE across roots (test/native_fixtures/run.sh vs playground/e2e/run.sh both stem to
# "run"), and a ledger keyed on a colliding name is a ledger that classifies the wrong file.
# Enumerate TRACKED scripts, via `git ls-files` — not a filesystem walk.
#
# A `glob('**/*.sh')` happens to work only because Python's `**` silently skips
# dot-directories, and this box keeps ~30 agent worktrees under `.claude/worktrees/`.
# One `find`-based rewrite, or one `include_hidden=True`, and this gate would enumerate
# every OTHER worktree's copy of every gate. Depending on a glob's dotfile behavior for
# correctness is exactly the kind of luck this gate exists to remove — so ask git, which
# knows what is actually in the repo, and gets build artifacts and node_modules right for
# free. (A gate must be a tracked file; an untracked .sh is a scratch script.)
out = subprocess.run(['git', '-C', root, 'ls-files', '-z', '*.sh'],
                     capture_output=True, text=True)
if out.returncode != 0:
    print(f"FAIL: `git ls-files` failed in {root} — cannot enumerate the gate universe.")
    print("      Refusing to certify coverage from a partial list.")
    sys.exit(1)
all_gates = {p[:-3] for p in out.stdout.split('\0') if p.endswith('.sh')}
if not all_gates:
    print("FAIL: found no scripts at all in the repo (harness bug)")
    sys.exit(1)

# TOOLS: scripts that are not gates. See test/CI-COVERAGE-TOOLS.txt for why this file
# exists and what listing a script here asserts.
tools = set()
tools_path = pathlib.Path(root) / 'test' / 'CI-COVERAGE-TOOLS.txt'
if tools_path.exists():
    for line in tools_path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            tools.add(line.split()[0])
all_gates -= tools

# A gate counts as covered if a shard pattern globs it OR any workflow file names
# it literally in some step (that is how the `soundness` job runs the fixpoint and
# the compiler-source typecheck — they are not sharded, they are named; it is also
# how a scheduled workflow like nightly.yml covers a gate unsuited to the PR path).
# `wf_text` was already built as the concatenation of every workflow file, above.

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

# A shard pattern resolves against BOTH `$ROOT/test/` and `$ROOT/` — the SAME rule
# run_gates.sh and build_oracles.sh --for use, so all three agree on which gates a
# pattern selects. They MUST agree: if this gate believed a pattern selected a gate
# that run_gates.sh could not actually glob, CI would certify coverage of a gate that
# silently never ran — the exact bug, reintroduced through the back door.
seen, dupes = {}, []
for name, pat in pats.items():
    for g in re.findall(r"'([^']+)'", pat):
        for p in glob.glob(f'{root}/test/{g}.sh') + glob.glob(f'{root}/{g}.sh'):
            key = str(pathlib.Path(p).relative_to(root))[:-3]
            if key in seen and seen[key] != name:
                dupes.append((key, seen[key], name))
            seen[key] = name

# "Named" = a workflow step invokes the script by its repo-relative path (that is how
# the `soundness` job runs the fixpoint + the compiler-source typecheck, and how
# nightly.yml runs check_removed_constructs / fuzz_diff). Matching on the PATH, not on
# a bare basename, is what keeps `run.sh` from matching two different gates.
named = {g for g in all_gates
         if g not in seen and re.search(rf'(?<![\w/-]){re.escape(g)}\.sh\b', wf_text)}
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
