#!/bin/sh
# must_fail_census.sh — the OTHER half of the must-fail ratchet (#569).
#
# test/diff_compiler_must_fail.sh (the gate) drains one direction: a fix lands, the pin
# stops holding, the gate goes RED and says to close the issue. This script drains the
# directions the GATE STRUCTURALLY CANNOT SEE, because they need the GitHub API:
#
#   HALF 1  PINNED-BUT-CLOSED: an issue is CLOSED but its fixture still pins it  -> TRACKER lies
#   HALF 2  a new open+verified issue has no fixture             -> a pinning candidate
#   HALF 3  a NOT-PINNABLE ledger entry's issue is CLOSED        -> a stale exemption
#
# ── ⭐ HALF 1 IS THE POINT: THE CORPUS IS AN ORACLE FOR THE TRACKER ─────────────
#
# When a fixture and its issue disagree, ask which one is EVIDENCE:
#   * the fixture JUST RAN AGAINST THE BINARY. It is a measurement.
#   * the issue's state is a HUMAN ASSERTION, made by someone who believed they fixed it.
# So `CLOSED + still REPROduces` means THE ISSUE IS WRONG, not the fixture. That happens
# constantly: closed as a dupe, closed in error, a reverted fix, a `Fixes #N` that didn't,
# or the `Fixes **#N**` bold-trap that already left four fixed issues open in this repo.
#
# This is not hypothetical. When #547's own triage re-derived the backlog it was WRONG
# ABOUT FIVE CLOSES OUT OF SIX — and THREE of those five were closed on the grounds that
# "the affordance already exists". A fixture would have REFUSED all three, because the bug
# still reproduced regardless of what the affordance did. Half 1 is a machine that catches
# that specific error, which is the most common way this tracker lies.
#
# Prior art, one level down: sqlite/findings/verify_compiler_bugs.sh ships a bug list with
# a script that re-runs every repro and prints OPEN/FIXED. `.claude/ORCHESTRATING.md` calls
# it "the model... every bug corpus should ship its own verifier" — and it is the only
# reason we know 4 of those 11 SQLite bugs had silently self-fixed. This is that, pointed
# at the tracker instead of one project.
#
# ── ⚠️ IT REPORTS. IT NEVER ACTS. ─────────────────────────────────────────────
#
# No auto-reopen, no auto-close, no auto-delete, ever. Given `CLOSED + still REPROs` this
# script CANNOT distinguish "closed in error" (reopen it) from "the fixture drifted onto a
# different bug" (fix the fixture) — and acting would encode a conclusion it has no
# evidence for. A DIAGNOSTIC REPORTS WHAT IT OBSERVED, NOT WHAT IT CONCLUDED. It prints
# both facts and stops; a human judges.
#
# ── WHY THIS IS NIGHTLY AND NOT IN `soundness` ────────────────────────────────
#
# ⭐ A REQUIRED CHECK MUST BE CAUSED BY THE DIFF IT GATES.
#
# That one line settles gate placement, and it is why `soundness` hosts the must-fail GATE
# (a diff can fix a bug) but must never host this CENSUS (no diff can close an issue).
# Blocking an innocent PR on repo state its diff never touched is the "not your break"
# problem `.claude/HANDOFF.md` exists to mitigate. Three more reasons, any one sufficient:
#   * `soundness` is required on every PR AND every merge-queue entry — one API blip or
#     rate-limit and NOTHING in the repo merges;
#   * every agent runs the gate locally via `make gates`/preflight with no `gh` auth, so it
#     would have to SKIP ("this didn't run" looking like "this passed" — the cardinal sin
#     this whole suite exists to prevent) or FAIL, breaking the loop;
#   * fork PRs get a restricted token.
#
# ── FINDINGS ARE FILED, NOT FAILED. INFRA FAILURE *IS* A FAILURE. ─────────────
#
# Mirrors nightly.yml's `fuzz-diff` job exactly. A finding here is news for a human, not a
# broken build, so it never fails. But reading ZERO fixtures, or an unauthenticated `gh`,
# is an INFRA failure and exits nonzero — a census that graded nothing must never look
# like a clean one.
#
# Usage:
#   sh test/must_fail_census.sh            # halves 1+3, and half 2 as a 7-day DELTA
#   sh test/must_fail_census.sh --all      # half 2 over the WHOLE backlog (deliberate sweep)
#   MUST_FAIL_CENSUS_WINDOW_DAYS=14 sh test/must_fail_census.sh
# Exit: 0 ran successfully — ALWAYS, whether it found something or not. Read the
#       `census-status: findings|clean` marker line in the output for the actual signal
#       (nightly.yml greps it into a `findings` step output); 2 INFRA: no fixtures, no gh,
#       or the API refused — the only real failure. (#593: findings used to exit 1, which
#       made this script a permanent false-red gate failure under `make preflight` — any
#       caller that derives a gate set from a changed must_fail_fixtures/ path and treats
#       nonzero exit as failure, exactly what this script's own header already promised it
#       would never do. The findings signal now lives ONLY in the marker line below.)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXDIR="$ROOT/test/must_fail_fixtures"
LEDGER="$ROOT/test/MUST-FAIL-NOT-PINNABLE.txt"
# ── THE WINDOW MUST MATCH THE NIGHTLY CADENCE. ────────────────────────────────
#
# 2 days, not 7. This was 7 until it was RUN: a 7-day window on a job that runs EVERY
# NIGHT re-reports the same issue SEVEN NIGHTS RUNNING — which is the nagging the delta
# exists to prevent, arriving by a different door. The window is a "since the last run"
# delta, so it must be the cadence (1 day) plus enough slack to survive one missed night
# (hence 2). The cost of the slack is that an issue can appear in two consecutive reports;
# the cost of NOT having it is that a single failed nightly drops that day's issues
# forever. Two duplicate rows beats a permanent hole.
WINDOW="${MUST_FAIL_CENSUS_WINDOW_DAYS:-2}"

ALL=0
[ "${1:-}" = "--all" ] && ALL=1

[ -d "$FIXDIR" ] || { echo "INFRA: missing fixture dir: $FIXDIR"; exit 2; }
command -v gh >/dev/null 2>&1 || {
  echo "INFRA: \`gh\` not found. This census reads issue state from the GitHub API;"
  echo "       it cannot run offline. That is WHY it is nightly and not a gate —"
  echo "       see this script's header. Refusing to report a clean census."
  exit 2
}
gh auth status >/dev/null 2>&1 || {
  echo "INFRA: \`gh\` is not authenticated (\`gh auth status\` failed). Refusing to"
  echo "       report a clean census from an API this script cannot read."
  exit 2
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

findings=0

# ── Enumerate the corpus. DERIVED from the directory listing; nothing is registered. ──
: > "$TMP/pinned"
for d in "$FIXDIR"/*/; do
  [ -d "$d" ] || continue
  [ -f "$d/claim.txt" ] || continue
  n="$(sed -n 's/^issue:[[:space:]]*//p' "$d/claim.txt" | head -1)"
  [ -n "$n" ] || continue
  printf '%s\t%s\n' "$n" "$(basename "$d")" >> "$TMP/pinned"
done

# A census that read ZERO fixtures is an infra failure, not an empty-and-clean corpus.
if [ ! -s "$TMP/pinned" ]; then
  echo "INFRA: read ZERO fixtures from $FIXDIR — a census that graded nothing must never"
  echo "       report clean. (Is the corpus really empty, or is this a harness bug?)"
  exit 2
fi

echo "must-fail census — the corpus is the EVIDENCE; the tracker is the CLAIM."
echo "Findings are reported for a human to judge. This script never reopens, closes,"
echo "or deletes anything."
echo

# ══ HALF 1: PINNED-BUT-CLOSED — issue CLOSED but the fixture still pins it ════
#
# This is the network-tolerant home of the PINNED-BUT-CLOSED verdict (#581): the fourth
# verdict beside the GATE's REPRO / DRAINED / CONTROL-BROKE. The gate cannot emit it — it
# is offline and cannot read issue state (see diff_compiler_must_fail.sh's REPRO comment).
# The gate proves each fixture still REPRODUCES on every PR; this census proves the tracker
# still agrees. When they disagree — pin says BROKEN, tracker says FIXED — one is wrong.
echo "── PINNED-BUT-CLOSED: issues CLOSED whose fixture still pins a LIVE bug ──"
h1=0
while IFS="$(printf '\t')" read -r n dir; do
  state="$(gh issue view "$n" --json state -q .state 2>/dev/null)" || state=""
  if [ -z "$state" ]; then
    # Do NOT silently treat an unreadable issue as OK. It might be the one that matters.
    echo "  ⚠️  #$n — could NOT read issue state (deleted, transferred, or the API refused)."
    echo "      fixture: test/must_fail_fixtures/$dir/"
    findings=$((findings+1)); h1=$((h1+1))
    continue
  fi
  if [ "$state" = "CLOSED" ]; then
    what="$(sed -n 's/^what:[[:space:]]*//p' "$FIXDIR/$dir/claim.txt" | head -1)"
    echo "  🚨 PINNED-BUT-CLOSED  #$n — the pin says BROKEN, the tracker says FIXED. One is wrong."
    echo "      fixture: test/must_fail_fixtures/$dir/"
    echo "      pins:    $what"
    echo "      The gate re-runs this fixture against the binary on every PR; issue state is an assertion."
    echo "      Judge which is wrong — do NOT assume the fixture is:"
    echo "        * closed in error / as a dupe / a reverted fix  -> REOPEN #$n"
    echo "        * the fixture drifted onto a different bug      -> fix the fixture"
    echo "      (This script will not act on either; see its header.)"
    findings=$((findings+1)); h1=$((h1+1))
  fi
done < "$TMP/pinned"
[ "$h1" -eq 0 ] && echo "  none — every pinned issue is still open."
echo

# ══ HALF 3: a NOT-PINNABLE entry whose issue is CLOSED ════════════════════════
# The gate owns the other direction (an entry that now HAS a fixture); it needs no API.
echo "── NOT-PINNABLE entries whose issue is CLOSED (stale exemptions) ────────"
h3=0
if [ -f "$LEDGER" ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    n="${line%% *}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    state="$(gh issue view "$n" --json state -q .state 2>/dev/null)" || state=""
    if [ "$state" = "CLOSED" ]; then
      echo "  #$n is CLOSED — its NOT-PINNABLE entry has no subject left. Remove the line"
      echo "      from test/MUST-FAIL-NOT-PINNABLE.txt. An exemption that outlives its bug"
      echo "      silently swallows a real future finding."
      findings=$((findings+1)); h3=$((h3+1))
    fi
  done < "$LEDGER"
fi
[ "$h3" -eq 0 ] && echo "  none — every exemption still has a live subject."
echo

# ══ HALF 2: pinning candidates ═══════════════════════════════════════════════
#
# ⚠️ REPORT, NEVER FAIL, AND NEVER COUNT. Most open+verified issues are LEGITIMATELY
# un-pinnable: gate/CI defects, doc defects, perf, code health — none has a `main.mdk` to
# pin or an exact observable to grade. A coverage RATIO here would invent a 100% target and
# drive exactly the false pins the gate's `control:` mechanism exists to prevent. So this
# prints ROWS and no totals, and a human judges each one.
if [ "$ALL" -eq 1 ]; then
  echo "── pinning candidates: THE WHOLE BACKLOG (--all, a deliberate sweep) ────"
  since=""
else
  since="$(date -u -d "@$(( $(date -u +%s) - WINDOW * 86400 ))" +%Y-%m-%d 2>/dev/null \
           || date -u -v-"${WINDOW}"d +%Y-%m-%d 2>/dev/null)"
  if [ -z "$since" ]; then
    echo "INFRA: could not compute the window date with either GNU or BSD \`date\`."
    exit 2
  fi
  echo "── pinning candidates: NEW in the last ${WINDOW} days (since $since) ──────────"
fi

# One API call, not one per issue.
gh issue list --state open --label verified --limit 300 \
  --json number,title,labels,createdAt > "$TMP/open.json" 2>/dev/null || {
  echo "INFRA: \`gh issue list\` failed — cannot derive the candidate set."
  exit 2
}

cut -f1 "$TMP/pinned" | sort -u > "$TMP/pinned_ids"
sed -n 's/^\([0-9][0-9]*\) .*/\1/p' "$LEDGER" 2>/dev/null | sort -u > "$TMP/ledgered_ids"

python3 - "$TMP/open.json" "$TMP/pinned_ids" "$TMP/ledgered_ids" "$since" <<'PY' > "$TMP/cands"
import json, sys
doc = json.load(open(sys.argv[1]))
pinned = {l.strip() for l in open(sys.argv[2]) if l.strip()}
ledgered = {l.strip() for l in open(sys.argv[3]) if l.strip()}
since = sys.argv[4]
for i in sorted(doc, key=lambda x: x["number"]):
    n = str(i["number"])
    labs = [l["name"] for l in i["labels"]]
    if "needs-repro" in labs:      # an unreproduced claim must never be pinned
        continue
    if n in pinned or n in ledgered:
        continue
    if since and i["createdAt"][:10] < since:
        continue
    sev = next((l for l in labs if l.startswith("S")), "")
    print(f'  #{n}  {sev:<22}  {i["title"][:88]}')
PY

if [ -s "$TMP/cands" ]; then
  cat "$TMP/cands"
  echo
  echo "  Each row is a CANDIDATE, not a task. Most of the tracker is legitimately"
  echo "  un-pinnable (a gate defect, a doc defect, perf, code health — no main.mdk to"
  echo "  pin, no exact observable to grade). If one is out of shape, say so ONCE in"
  echo "  test/MUST-FAIL-NOT-PINNABLE.txt with a reason, and it stops appearing."
  findings=$((findings+1))
else
  echo "  none."
fi
echo

# ── ⚠️ THE ACCEPTED COST, SAID OUT LOUD. ─────────────────────────────────────
#
# The delta does NOT "self-drain by construction" — it drains BY TIME, which is FORGETTING,
# not resolving. An issue appears in one window, nobody acts, and it is never mentioned here
# again. That is a real cost and it is accepted deliberately (a full nightly census is ~88
# rows, which gets skimmed once and muted — and then the mechanism built to drain ledgers is
# itself the largest un-drained ledger in the repo). But a tool that quietly stops covering
# something WHILE LOOKING LIKE COVERAGE is the thing this entire suite fights, so it says so
# every single run rather than only in a design doc nobody re-reads.
if [ "$ALL" -eq 0 ]; then
  echo "⚠️  This is a ${WINDOW}-DAY DELTA, not a backlog, and it does NOT 'self-drain by"
  echo "    construction'. It drains BY TIME, which is FORGETTING, not resolving: an issue"
  echo "    appears in one window, nobody acts, and it is NEVER MENTIONED HERE AGAIN."
  echo "    That is an accepted cost, not coverage. A tool that quietly stops covering"
  echo "    something while LOOKING like coverage is what this whole suite fights, so it"
  echo "    says so every run rather than only in a design doc nobody re-reads."
  echo "      -> \`sh test/must_fail_census.sh --all\` sweeps the whole backlog on demand."
  echo
  echo "    Why a delta anyway: it catches an issue when PINNING IS CHEAPEST — while the"
  echo "    filer still HAS THE REPRO IN HAND. A two-day-old issue has a live repro sitting"
  echo "    in a transcript; a cold one from March needs somebody to reconstruct it from"
  echo "    scratch. That is the real failure mode this targets: a bug lands, nobody pins"
  echo "    it, and it silently self-fixes with nothing to notice. The alternative — the"
  echo "    whole backlog, nightly — is ~88 rows that get skimmed once and muted, and then"
  echo "    the mechanism built to drain ledgers is the biggest un-drained ledger here."
  echo
  echo "    Two more limits, said out loud rather than discovered later:"
  echo "      * the key is createdAt, a PROXY for 'became a candidate'. An OLD issue newly"
  echo "        labelled \`verified\` will NOT surface here. --all is the recovery."
  echo "      * a failed nightly drops that night's issues; the ${WINDOW}-day window exists"
  echo "        to survive exactly one such miss, at the cost of a possible repeat row."
  echo
fi

if [ "$findings" -gt 0 ]; then
  echo "census: findings above need a human. (Nightly FILES these; it does not fail.)"
  # #593: findings are a STATUS, not a gate failure — this script is advisory (see the
  # header). The machine-readable signal moves to this marker line; nightly.yml greps it
  # into a `findings` step output. Exit stays 0 like any other successful run so a
  # preflight/CI caller that derives a gate set from a must_fail_fixtures/ change and
  # treats nonzero as failure does not get a permanent false red.
  echo "census-status: findings"
  exit 0
fi
echo "census: no findings."
echo "census-status: clean"
exit 0
