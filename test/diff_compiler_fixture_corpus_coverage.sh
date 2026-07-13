#!/bin/sh
# diff_compiler_fixture_corpus_coverage.sh — every fixture/golden corpus must be
# CONSUMED by at least one gate.
#
# diff_compiler_ci_shard_coverage.sh proves every GATE SCRIPT runs in CI. It says
# nothing about the inverse: whether a fixture/golden DIRECTORY is ever read by
# any gate at all. A corpus can exist, look authoritative, even be cited in a
# design doc as "the spec's enforcement" — and be exercised by nothing. That is
# how test/shadow_fixtures/ (the SHADOW-SEMANTICS decision matrix — one fixture
# per matrix cell) sat wired into NO gate: every cell had to be checked by hand.
# Same bug class as ci_shard_coverage, one axis over: "this didn't run" must
# never look like "this passed" — for CORPORA, not just gates.
#
# ⚠️ THIS DERIVATION IS DELIBERATELY THE SAME ONE test/preflight.sh ALREADY
# COMPUTES for its fixture-dir → consuming-gates arm (see preflight.sh's
# "fixture/golden directory → its ACTUAL consumers" section). preflight.sh is a
# DO-NOT-TOUCH file for this change, so the RULE is duplicated here rather than
# shared code — but it IS the same rule, named explicitly so the two cannot
# silently drift into two different answers for "does gate G consume corpus D":
#   1. Comments are stripped before grepping — a header comment naming a corpus
#      is NOT a dependency (the exact bug run_gates.sh's stale-oracle scrape has).
#   2. Live word-boundary reference to the corpus's full relative path (not just
#      its basename — `test/llvm_fixtures` must not match `test/llvm_fixtures_modules`,
#      and `test/diff_fixtures` must not match inside `test/snapshots/diff_fixtures`).
#   3. One hop through a helper the gate actually invokes (preflight's
#      diff_compiler_tmc_parity / test/tmc_census.sh example) counts as consuming.
#   4. If the exact leaf directory has no consumer, climb to the parent and retry
#      (preflight's SNAPDIR case: diff_compiler_snapshot_frontend.sh never spells
#      out "test/snapshots/diff_fixtures", it reads test/snapshots as a whole).
#
# ONE EXTENSION beyond preflight, found empirically while building this gate:
# preflight's one-hop only follows into another *.sh helper. That missed a real
# consumer — test/lsp_harness.sh builds and runs compiler/entries/lsp_harness_main.mdk
# via `"$MEDAKA" build … lsp_harness_main.mdk`, and THAT Medaka source is what
# contains the literal `test/lsp_fixtures` path (compiler/entries/lsp_harness_main.mdk:382).
# A fixture corpus can therefore be consumed by a compiled Medaka entry point, not
# just a shell helper — so the one-hop here also follows a `.mdk` path that
# appears on a line containing the word "build" or "run" (the invocation idiom
# every gate in this tree uses), and checks THAT file for the live reference.
# Verified this doesn't false-positive: an untargeted "any .mdk substring
# anywhere in the gate" version wrongly credited test/snapshots/* via
# compiler/driver/medaka_cli.mdk, which merely prints a `medaka snapshot --bless
# --out test/snapshots/compiler …` USAGE STRING — not real consumption. Anchoring
# on the build/run invocation line removed that false positive.
#
# ── the "which .sh files are TOOLS, not gates" question is not re-derived here ──
# A script that only WRITES a corpus (capture_goldens.sh) or MEASURES without a
# verdict (bench.sh, profile_compiler.sh) must not count as a "consumer" — that
# would let a corpus with zero real checks report covered. Rather than hand-roll a
# second exclusion list (the exact drift hazard this whole project keeps finding),
# this gate reuses test/CI-COVERAGE-TOOLS.txt — the sibling ci_shard_coverage.sh's
# own maintained ledger of non-gate scripts — as the exclusion set.
#
# ── gate universe: every TRACKED *.sh, via `git ls-files` ────────────────────
# NOT a filesystem walk, and NOT `test/*.sh`. Two reasons: real gates live
# outside test/ (sqlite/test/*_oracle.sh, playground/e2e/run.sh), and this box
# keeps ~30 agent worktrees under .claude/worktrees/ — a `find`-based walk would
# enumerate every other worktree's copy of every gate. `git ls-files` is scoped
# to THIS worktree's own tracked tree, which is exactly what's wanted.
#
# ── the ledger (test/FIXTURE-CORPUS-EXCEPTIONS.txt) is BIDIRECTIONAL ─────────
# A genuinely-unconsumed corpus may be ledgered with a reason + owning task. Per
# test/CHECK-REMOVED-CONSTRUCTS-LEDGER.txt's model, this is a LEDGER, not a
# skip-list: a ledgered corpus that later GAINS a real consumer FAILS too,
# demanding the entry's deletion. A skip-list cannot see that direction; that is
# the whole reason this is a ledger.
#
# Usage:  sh test/diff_compiler_fixture_corpus_coverage.sh
# Exit:   0 every corpus has a consumer or a ledger entry; 1 otherwise.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "python3 not found (needed for this gate)"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git not found (needed for this gate)"; exit 2; }

python3 - "$ROOT" <<'PY'
import sys, os, re, subprocess, pathlib

root = sys.argv[1]

def git_ls():
    out = subprocess.check_output(['git', 'ls-files'], cwd=root).decode()
    return out.splitlines()

files = git_ls()
fileset = set(files)

# ── 1. every fixture/golden corpus: nearest ancestor dir (from each tracked
#      file) whose basename contains "fixtures" or "goldens". Mirrors
#      preflight.sh's _fixture_dir_for (climb from the file's parent; stop at
#      the first matching ancestor; never climb past bare "test").
def fixture_dir_for(f):
    d = os.path.dirname(f)
    while d not in ('', '.', '/'):
        base = os.path.basename(d)
        if 'fixtures' in base or 'goldens' in base:
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent
    return None

corpora = set()
for f in files:
    d = fixture_dir_for(f)
    if d:
        corpora.add(d)

if not corpora:
    print("FAIL: found no fixture/golden directories at all (harness bug)")
    sys.exit(1)

# ── 2. gate candidates: every tracked *.sh, minus test/CI-COVERAGE-TOOLS.txt
#      (the sibling ci_shard_coverage.sh's own ledger of non-gate scripts —
#      reused rather than re-derived; see header).
tools = set()
tools_path = pathlib.Path(root) / 'test' / 'CI-COVERAGE-TOOLS.txt'
if tools_path.exists():
    for line in tools_path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            tools.add(line.split()[0])

sh_files = [f for f in files if f.endswith('.sh')]
candidates = [f for f in sh_files if pathlib.Path(f).stem not in tools]

if not candidates:
    print("FAIL: found no gate-candidate *.sh scripts (harness bug, or CI-COVERAGE-TOOLS.txt swallowed everything)")
    sys.exit(1)

# ── 3. live (comments-stripped) reference + one-hop resolution ───────────────
def strip_comments(text):
    return '\n'.join(l for l in text.splitlines() if not re.match(r'^\s*#', l))

_cache = {}
def content(f):
    if f not in _cache:
        try:
            _cache[f] = strip_comments(pathlib.Path(root, f).read_text(errors='replace'))
        except Exception:
            _cache[f] = ''
    return _cache[f]

def refs(f, d):
    pat = re.compile(r'(^|[^A-Za-z0-9_])' + re.escape(d) + r'([^A-Za-z0-9_]|$)', re.M)
    return bool(pat.search(content(f)))

# one hop through another *.sh this gate invokes (preflight's `sh "$ROOT/...` idiom)
def invokes_sh(f):
    pat = re.compile(r'sh "\$ROOT/([A-Za-z0-9_./]+\.sh)')
    return set(pat.findall(content(f)))

# one hop through a .mdk this gate builds/runs (the lsp_harness extension — see
# header). Anchored to a line containing "build" or "run" so an unrelated .mdk
# mention elsewhere in the gate (e.g. a usage/help string) cannot false-positive.
def invokes_mdk(f):
    out = set()
    for line in content(f).splitlines():
        if re.search(r'\b(build|run)\b', line):
            out |= set(re.findall(r'\b([A-Za-z0-9_./]+\.mdk)\b', line))
    return out

def consumes(gate, d):
    if refs(gate, d):
        return True
    for h in invokes_sh(gate):
        if h != gate and h in fileset and refs(h, d):
            return True
    for h in invokes_mdk(gate):
        if h in fileset and refs(h, d):
            return True
    return False

# corpus dir -> consuming gates, climbing to the parent if the leaf has none
# (preflight's SNAPDIR fallback). Never climbs past bare "test".
def consumers_for(d0):
    d = d0
    while True:
        found = [g for g in candidates if consumes(g, d)]
        if found:
            return found
        parent = os.path.dirname(d)
        if parent in ('test', '.', ''):
            return []
        d = parent

results = {d: consumers_for(d) for d in sorted(corpora)}

# ── 4. the ledger (bidirectional) ─────────────────────────────────────────────
exc = {}
exc_path = pathlib.Path(root) / 'test' / 'FIXTURE-CORPUS-EXCEPTIONS.txt'
if exc_path.exists():
    for line in exc_path.read_text().splitlines():
        line = line.rstrip('\n')
        if not line.strip() or line.strip().startswith('#'):
            continue
        if '\t' not in line:
            print(f"FAIL: malformed ledger line (expected TAB-separated '<corpus>\\t<reason>'): {line!r}")
            sys.exit(1)
        stem, _, reason = line.partition('\t')
        exc[stem.strip()] = reason.strip()

for d in sorted(corpora):
    n = len(results[d])
    marker = f"({n} consumer{'s' if n != 1 else ''})" if n else "(0 consumers)"
    print(f"  {d:<45} {marker}")

rc = 0

if exc:
    print()
    print("  FIXTURE-CORPUS-EXCEPTIONS.txt — ledgered as deliberately unconsumed:")
    for stem, reason in sorted(exc.items()):
        gone = stem not in corpora
        tag = " (STALE — this corpus no longer exists)" if gone else ""
        print(f"       {stem}: {reason}{tag}")

    stale_gone = sorted(set(exc) - corpora)
    if stale_gone:
        print()
        print("FAIL: the ledger names corpora that DO NOT EXIST — remove these lines from")
        print("      test/FIXTURE-CORPUS-EXCEPTIONS.txt:")
        for s in stale_gone:
            print(f"       {s}")
        rc = 1

    # BIDIRECTIONAL: a ledgered corpus that GAINED a real consumer is stale too.
    # This is the direction a skip-list cannot see — the whole point of a ledger.
    now_consumed = sorted(stem for stem in exc if stem in corpora and results.get(stem))
    if now_consumed:
        print()
        print("FAIL: these corpora are ledgered as unconsumed but NOW HAVE a consumer —")
        print("      delete their line from test/FIXTURE-CORPUS-EXCEPTIONS.txt:")
        for s in now_consumed:
            print(f"       {s}  (now consumed by: {', '.join(sorted(os.path.basename(g) for g in results[s]))})")
        rc = 1

missing = sorted(d for d in corpora if not results[d] and d not in exc)
if missing:
    print()
    print("FAIL: these fixture/golden corpora are consumed by NO gate (checked every")
    print("      tracked *.sh, minus test/CI-COVERAGE-TOOLS.txt, live references only,")
    print("      one hop through an invoked .sh or .mdk build/run target, climbing to")
    print("      the parent directory if the leaf has no direct consumer):")
    for m in missing:
        print(f"       {m}")
    print("       Wire it into (or delete it as dead), or add it to")
    print("       test/FIXTURE-CORPUS-EXCEPTIONS.txt WITH A REASON AND AN OWNER.")
    rc = 1

if rc == 0:
    print()
    print(f"PASS: all {len(corpora)} fixture/golden corpora are consumed by a gate or ledgered ({len(exc)} ledgered).")
sys.exit(rc)
PY
