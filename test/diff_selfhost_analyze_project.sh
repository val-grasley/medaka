#!/bin/sh
# test/diff_selfhost_analyze_project.sh — differential gate for the self-hosted
# PROJECT-WIDE diagnostics (Stage 4 Phase B.10.5: analyzeProject).
#
# Mirrors lib/diagnostics.ml's analyze_project: load a root file's transitive
# import graph, run resolve/typecheck per module, and BUCKET diagnostics BY FILE
# (clean files publish []).  The self-hosted analyzeProject (selfhost/
# diagnostics.mdk, driven by selfhost/entries/diagnostics_project_main.mdk) is diffed
# against the OCaml oracle `medaka check --json <entry>`, which routes through the
# real analyze_project and emits a per-file "files" array.
#
# Per fixture, for EACH file in the graph we assert the buckets agree on:
#   • the per-file diagnostic COUNT,
#   • each diagnostic's SEVERITY, and
#   • each diagnostic's MESSAGE
# (sorted, so order/hashtbl differences between the two pipelines don't matter).
# A CLEAN file must bucket to [] on both sides; a file with a type error keeps its
# diagnostic WITHOUT blanking the clean files (the "bad import doesn't sink the
# batch" property).
#
# START POSITION: where the self-hosted Diag carries a span (type errors, via the
# ELoc substrate), diagnostics_project_main emits it as `severity@line:col:` —
# this gate additionally asserts that START position equals the OCaml LSP range
# start for the matching diagnostic.  Resolve diagnostics carry no span on the
# selfhost side (None → positionless), matching analyze_project's resolve loc
# fallback; those are compared on (severity,message) only.
#
# Message TEXT for TYPE errors can diverge by unification order (the documented
# selfhost limitation, cf. diff_selfhost_diagnostics.sh).  Fixtures here use type
# errors whose message is stable across both pipelines (`Type mismatch: A vs B`);
# if a future fixture's type message diverges, compare its (count,severity) only.
#
# Usage: sh test/diff_selfhost_analyze_project.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/test/bin/diagnostics_project_main"
RT="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/analyze_project_fixtures"
[ -x "$SELF" ] || { echo "build oracles first: sh test/build_oracles.sh (missing $SELF)"; exit 2; }

pass=0; fail=0

for d in "$FIXDIR"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  root="${d%/}"
  entry="$(ls "$d"root_*.mdk "$d"main_*.mdk 2>/dev/null | head -1)"
  [ -n "$entry" ] || { echo "skip $name (no root_*.mdk / main_*.mdk entry)"; continue; }

  # OCaml-free (REROOT-PLAN §2b): the oracle JSON is the committed
  # <dir>/oracle.json captured from `medaka check --json` by capture_goldens.sh;
  # the self-hosted analyzeProject runs as the native diagnostics_project_main.
  golden="$root/oracle.json"
  [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL %s (no oracle.json — run sh test/capture_goldens.sh analyze_project)\n' "$name"; continue; }
  oracle_json="$(cat "$golden")"
  # Strip the native value-entry's trailing "()" (Unit return; runtime/medaka_rt.c)
  # appended to the last output line, so it can't corrupt the final "## FILE" path.
  self_text="$(perl -e 'alarm 180; exec @ARGV' \
      "$SELF" "$RT" "$CORE" "$entry" "$root" 2>/dev/null | sed '$ s/()$//; ${/^$/d;}')"

  ORACLE_JSON="$oracle_json" SELF_TEXT="$self_text" python3 - "$name" <<'PY'
import sys, os, json, re
name = sys.argv[1]

# ── OCaml oracle: {basename: [(sev,msg,startline,startcol), ...]} ──
oracle = {}
oj = json.loads(os.environ["ORACLE_JSON"])
for f in oj.get("files", []):
    base = os.path.basename(f["file"])
    items = []
    for x in f["diagnostics"]:
        r = x.get("range", {}).get("start", {})
        items.append((x["severity"], x["message"], r.get("line"), r.get("character")))
    oracle[base] = items

# ── selfhost: parse "## FILE <path>" blocks, lines are
#    "<sev>@<line>:<col>: <msg>"  or  "<sev>: <msg>" ──
SEVCODE = {"error": 1, "warning": 2}
self = {}
cur = None
for line in os.environ["SELF_TEXT"].splitlines():
    if line.startswith("## FILE "):
        cur = os.path.basename(line[len("## FILE "):].strip())
        self.setdefault(cur, [])
    elif cur is not None and line.strip():
        m = re.match(r'^(error|warning)@(\d+):(\d+): (.*)$', line)
        if m:
            self[cur].append((SEVCODE[m.group(1)], m.group(4), int(m.group(2)), int(m.group(3))))
        else:
            m2 = re.match(r'^(error|warning): (.*)$', line)
            assert m2, "unparsable selfhost diag line: %r" % line
            self[cur].append((SEVCODE[m2.group(1)], m2.group(2), None, None))

# Compare the FILE SETS first.
ofiles, sfiles = set(oracle), set(self)
if ofiles != sfiles:
    sys.stderr.write("FILE SET mismatch %s: oracle=%s self=%s\n" % (name, sorted(ofiles), sorted(sfiles)))
    sys.exit(1)

# Per file, compare the (severity,message) MULTISET (sorted) and, for any
# diagnostic the selfhost located, assert its START matches the oracle's start
# for the same (severity,message).
ok = True
for base in sorted(ofiles):
    o = oracle[base]; s = self[base]
    o_sm = sorted((sev, msg) for (sev, msg, _, _) in o)
    s_sm = sorted((sev, msg) for (sev, msg, _, _) in s)
    if o_sm != s_sm:
        sys.stderr.write("  %s/%s: (sev,msg) mismatch\n    oracle=%s\n    self  =%s\n"
                         % (name, base, o_sm, s_sm))
        ok = False
        continue
    # Located-diagnostic START check: for each selfhost diag that carries a
    # position, find an oracle diag with the same (sev,msg) and equal start.
    for (sev, msg, ln, col) in s:
        if ln is None:
            continue
        starts = [(ol, oc) for (osev, omsg, ol, oc) in o if osev == sev and omsg == msg]
        if (ln, col) not in starts:
            sys.stderr.write("  %s/%s: START mismatch for %r: self=(%d,%d) oracle_starts=%s\n"
                             % (name, base, msg, ln, col, starts))
            ok = False

sys.exit(0 if ok else 1)
PY
  if [ $? -eq 0 ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$name"; fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
