#!/bin/sh
# diff_compiler_preflight_base.sh — preflight must not blame other people's commits on you.
#
# THE BUG THIS PINS (#560)
# -----------------------
# `preflight.sh` derives the gate set from `git diff $BASE...HEAD`. It defaulted
# $BASE to LOCAL `main` — a ref that, in a worktree, is UNMAINTAINABLE: `main` is
# checked out in the primary tree, so `git checkout main` in an agent worktree
# fails outright and NOTHING an agent does can advance it. It sits at whatever the
# last `git pull` in the primary tree left.
#
# Three-dot ALREADY handles a base that has ADVANCED past the fork point (it diffs
# from the merge-base), so an "ahead" base is harmless. The failure is a base
# BEHIND the fork point: the merge-base drags back and every commit that landed in
# between is attributed to your branch. Measured on the real repo: a diff touching
# ONLY parser.mdk grew to 22 files, enrolled the wasm gates and the 2.5-min clang
# storm, then exited 2 having run NOTHING.
#
# ⚠️ The STEP-0 `git merge-base --is-ancestor <tip> HEAD && echo BASE_OK` assert
# every agent runs CANNOT catch this: it proves ANCESTRY, not FRESHNESS, and a
# stale `main` IS an ancestor. It passed, correctly, throughout the bug's life.
#
# WHY A SYNTHETIC REPO, AND WHY IT IS NOT A FAKE TEST
# ---------------------------------------------------
# The bug only exists in a specific git shape (local main BEHIND the branch's fork
# point). The ambient checkout is not reliably in that shape — and in CI it is a
# shallow merge ref with no `main` at all — so this builds the shape from scratch
# with `git init`. It depends on git and nothing else: no compiler, no oracle, no
# `./medaka`, ~0 CPU-s, so it runs anywhere and is parked in the cheapest shard.
#
# It is SELF-VALIDATING, which is the part that matters. A fixture is a claim about
# the BROKEN build, so only the broken build can check it — assertion 2 below
# re-runs the SAME repo against the STALE base and demands it still sees the
# phantom file. If the fixture ever stops encoding the bug (a git behaviour change,
# a botched edit), assertion 2 fails loudly rather than letting assertion 1 pass
# vacuously against a repo that no longer reproduces anything.
#
# Exit: 0 all assertions hold; 1 otherwise.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/test/lib_scratch.sh"

fails=0
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdk-pf-base.XXXXXX")" || {
  echo "FAIL: could not create scratch dir — refusing to skip."
  exit 1
}
trap 'rm -rf "$WORK"' EXIT INT TERM

# ── Build the shape ──────────────────────────────────────────────────────────
#
#   A ── B(origin/main)             A: base. B: ANOTHER agent's wasm_emit commit.
#   │      └── C(topic, HEAD)       C: OUR commit, parser.mdk only.
#   └── main                        main PINNED at A — as in a real worktree.
#
#   merge-base(main,        HEAD) = A  -> diff = {wasm_emit.mdk, parser.mdk}  WRONG
#   merge-base(origin/main, HEAD) = B  -> diff = {parser.mdk}                 RIGHT
setup() {
  cd "$WORK" || return 1
  git init -q . || return 1
  # `git init -b` needs git 2.28+; symbolic-ref works on every version and on both
  # platforms (the dual-platform invariant: this must run on the macOS box too).
  git symbolic-ref HEAD refs/heads/main || return 1
  git config user.email preflight@test.invalid || return 1
  git config user.name preflight || return 1
  git config commit.gpgsign false || return 1

  mkdir -p test compiler/frontend compiler/backend || return 1
  echo base >compiler/frontend/parser.mdk
  echo base >compiler/backend/wasm_emit.mdk
  # The script under test, committed in the BASE commit so it is not itself part of
  # any diff below.
  cp "$ROOT/test/preflight.sh" "$ROOT/test/lib_scratch.sh" test/ || return 1

  git add test compiler || return 1
  git commit -qm A || return 1
  a="$(git rev-parse HEAD)"
  git update-ref refs/remotes/origin/main "$a" || return 1

  # Another agent lands a backend commit. origin/main advances; main cannot.
  echo other-agent >>compiler/backend/wasm_emit.mdk
  git add compiler/backend/wasm_emit.mdk || return 1
  git commit -qm B || return 1
  b="$(git rev-parse HEAD)"
  git update-ref refs/remotes/origin/main "$b" || return 1
  git update-ref refs/heads/main "$a" || return 1

  # Our branch, correctly forked from the CURRENT origin/main.
  git checkout -q -b topic "$b" || return 1
  echo ours >>compiler/frontend/parser.mdk
  git add compiler/frontend/parser.mdk || return 1
  git commit -qm C || return 1
}

setup || {
  echo "FAIL: could not build the synthetic repo — refusing to report green on a setup that did not run."
  exit 1
}

# Extract preflight's "changed vs X" block: the indented lines after the banner, up
# to the blank line that ends it. preflight then FAILS in this repo (its map points
# at real gate scripts that a synthetic tree does not have) — irrelevant and
# deliberately not asserted on; the file list is printed before that and is the
# whole contract under test. The emptiness guards below are what keep that from
# becoming a silent pass.
changed_for() {
  PREFLIGHT_DRY=1 sh test/preflight.sh ${1:+"$1"} 2>&1 |
    awk '/^── changed vs /{inblk=1; next} inblk && /^  /{print $1} inblk && /^$/{exit}'
}

# ── 1. DEFAULT base: must see OUR file and ONLY our file ─────────────────────
fresh="$(changed_for)"
if [ -z "$fresh" ]; then
  fail "default base produced an EMPTY file list — preflight changed shape; this gate is no longer testing anything."
else
  echo "$fresh" | grep -qx 'compiler/frontend/parser.mdk' ||
    fail "default base did not report our own changed file (compiler/frontend/parser.mdk). Got: $(echo "$fresh" | tr '\n' ' ')"
  if echo "$fresh" | grep -qx 'compiler/backend/wasm_emit.mdk'; then
    fail "#560 REGRESSION: default base attributed ANOTHER agent's commit (compiler/backend/wasm_emit.mdk) to this branch. It would enrol the wasm/backend gates for a diff that never touched them."
  fi
fi

# ── 2. The fixture must actually reproduce the bug (self-validation) ─────────
# Same repo, STALE base. This MUST still see the phantom file: it is the proof that
# assertion 1 passed because the fix works, not because the shape is wrong.
stale="$(changed_for main)"
if [ -z "$stale" ]; then
  fail "stale base produced an EMPTY file list — cannot confirm this fixture still encodes #560."
else
  echo "$stale" | grep -qx 'compiler/backend/wasm_emit.mdk' ||
    fail "the synthetic repo NO LONGER REPRODUCES #560 (stale base 'main' did not pick up the phantom wasm_emit.mdk), so assertion 1 above proves nothing. Fix the fixture, do not delete this check."
fi

# ── 3. A stale EXPLICIT base must be LABELLED, not silently believed ─────────
PREFLIGHT_DRY=1 sh test/preflight.sh main 2>&1 | grep -q 'BEHIND' ||
  fail "a base behind the fork point produced NO staleness warning — the contaminated list would read as plausible."

# ── 4. An unresolvable base must FAIL, never silent-green ────────────────────
# `git diff <bad-ref>...HEAD 2>/dev/null` fails silently, leaving an empty diff and
# "nothing to do", exit 0 — a green over real committed work.
# NB: unpiped on purpose. `cmd | head; echo $?` reads the LAST stage's status, so a
# pipe here would silently assert nothing.
if PREFLIGHT_DRY=1 sh test/preflight.sh definitely-no-such-ref >/dev/null 2>&1; then
  fail "an unresolvable base exited 0 — a green that tested nothing over committed work."
fi

if [ "$fails" -ne 0 ]; then
  echo "diff_compiler_preflight_base: $fails assertion(s) FAILED"
  exit 1
fi
echo "diff_compiler_preflight_base: PASS (4 assertions)"
