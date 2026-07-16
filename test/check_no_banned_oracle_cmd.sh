#!/bin/sh
# banned-oracle-cmd: self-referential
# check_no_banned_oracle_cmd.sh — no script may PRESCRIBE the bare `build_oracles.sh`.
#
# WHY THIS GATE EXISTS (#478 -> #525 -> #527).
# Bare `sh test/build_oracles.sh` builds ALL oracles and spawns an `xargs -P` pool that
# AGENTS.md documents as "outlives the agent's turn and gets RESPAWNED by the harness —
# it has killed several agents". The safety rule lives in AGENTS.md and ORCHESTRATING.md;
# for months ~54 gate scripts contradicted it in their own FAIL messages — at exactly the
# moment a reader is most likely to obey, right after a gate failed.
#
# ⭐ THE REASON THIS IS A GATE AND NOT A SWEEP. #478 fixed 52 scripts and MISSED two —
# `diff_compiler_engines.sh` (the 3-engine differential, on the CI critical path) and
# `fuzz_diff.sh` — because #478 scoped itself with a grep keyed on a fixed English phrase
# ("build oracles first: ..."), and those two worded the same hazard differently. The fix
# was 52/52 complete against a set that was itself wrong. A SWEEP'S SCOPE IS AN ENCODED
# FACT TOO, and a wording-keyed grep confirms itself. So this gate keys on BEHAVIOR —
# "does this line tell someone to run build_oracles.sh without a targeting flag?" — which
# is the property that actually matters and does not vary with phrasing.
#
# The safe forms it accepts (all TARGETED, none spawn the pool):
#   --build-one <entry>   one oracle
#   --for '<gate-pat>'    the set a gate needs, derived from the gate script itself
#   --list                names only, builds nothing
#
# ⚠️ SCOPE: MESSAGES, not invocations. This flags a line that PRINTS the bare command
# (echo/printf/log) — one that TELLS A READER to run it. It deliberately does NOT flag a
# script that *invokes* build-all itself: ops/provision.sh and scripts/docker-dev.sh
# provision a fresh box, where building every oracle is the correct, documented job (no-args
# build-all is supported on purpose — see #474). The hazard is a message a human or agent
# COPIES, not a tool doing its own work.
#
# That distinction is this gate's PARSER, not a ledger. An earlier draft flagged both and
# would have needed an exception list naming provision/docker-dev — which rots the moment a
# third build-all tool appears. Per ORCHESTRATING.md: "a gate that has to excuse its own
# false positives is a gate with a parsing bug — fix the parser, not the ledger."
#
# Text-only: needs no compiler, so it is an UNGUARDED step in the `soundness` job rather
# than a gate shard. Per AGENTS.md's own rule — "a gate must RUN where the bug lands" —
# a shard-resident check is skipped when detect sets docs_only=true.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

checked=0
bad=0

# Every tracked .sh in the repo. Derived from git, not a hand-listed set: a new script is
# covered the moment it is added, with nothing to remember.
for f in $(git ls-files '*.sh'); do
  checked=$((checked + 1))

  # SELF-REFERENTIAL OPT-OUT. Two files must name the bare command to do their job:
  # build_oracles.sh (its own usage/docs — it IS the tool, not a caller) and this gate
  # (whose FAIL/PASS text quotes the thing it forbids). A file DECLARES ITSELF with the
  # marker below instead of being named in a list here, so the opt-out lives with the file
  # that needs it and is greppable — mirroring the repo's `-- lint-disable-file <rule>`
  # idiom. A central list here would rot; a third file wanting this marker is a signal
  # worth a human look, not a silent edit to this script.
  #
  # ⚠️ This gate flagged ITSELF in CI while passing locally — `git ls-files` lists only
  # TRACKED files, so an untracked new script is invisible to its own check. If you add a
  # script here, `git add` it BEFORE trusting a local run. (Same trap caught
  # diff_compiler_ci_shard_coverage.sh's green in the same commit — it enumerates the same
  # way.)
  grep -q '^# banned-oracle-cmd: self-referential' "$f" && continue

  # Strip COMMENT lines before matching. A comment discussing the hazard (preflight.sh does
  # exactly this, describing the very pattern this gate enforces) is not a prescription.
  # Parse it properly rather than ledger an exception: per ORCHESTRATING.md, "a gate that
  # has to excuse its own false positives is a gate with a parsing bug — fix the parser,
  # not the ledger."
  # Is the command named inside a QUOTED STRING? That is the discriminator between
  # "prints it for a reader to copy" and "runs it". We keep only the double-quoted spans of
  # each line and ask whether build_oracles.sh appears THERE — so
  #   FORCE=1 sh test/build_oracles.sh || echo "(build_oracles reported errors)"
  # is correctly NOT a hit (the invocation is unquoted; the quoted span never names it),
  # while
  #   echo "missing $b — run sh test/build_oracles.sh"
  # is. Approximate (it cannot parse shell), but it keys on the property that matters and
  # needs no exception list.
  hits=""
  while IFS= read -r ln; do
    n="${ln%%:*}"; body="${ln#*:}"
    case "$(printf '%s' "$body" | sed 's/^[[:space:]]*//')" in '#'*) continue ;; esac
    # NAMING is tested on the quoted span (is it printed for a reader?), but TARGETING is
    # tested on the WHOLE LINE — because a real call site quotes only the path and leaves
    # the flag outside it:  sh "$ROOT/test/build_oracles.sh" --build-one llvm_emit_main
    # Testing the flag against the quoted span alone reported every such call site as a
    # violation.
    quoted="$(printf '%s' "$body" | grep -o '"[^"]*"' || true)"
    printf '%s' "$quoted" | grep -q 'build_oracles\.sh' || continue
    printf '%s' "$body" | grep -q -- '--build-one\|--for\|--list' && continue
    hits="$hits
      $n:$(printf '%s' "$body" | sed 's/^[[:space:]]*//')"
  done <<EOF
$(grep -n 'build_oracles\.sh' "$f" || true)
EOF
  hits="$(printf '%s' "$hits" | sed '/^$/d')"

  [ -z "$hits" ] && continue

  if [ "$bad" -eq 0 ]; then
    echo "FAIL: these scripts prescribe the BARE build_oracles.sh — the command AGENTS.md"
    echo "      documents as having killed several agents (it spawns the xargs -P pool):"
    echo
  fi
  bad=$((bad + 1))
  echo "  $f"
  printf '%s\n' "$hits"
done

if [ "$bad" -gt 0 ]; then
  echo
  echo "  Name a TARGETED form instead, deriving the oracle name from the path the script"
  echo "  already holds — so it cannot drift if an oracle is renamed:"
  echo '      FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$RUN")'
  echo "  For a gate needing several oracles, --for '<gate-name>' derives the set from the"
  echo "  gate script itself (which is how CI does it), so there is no list to maintain."
  exit 1
fi

# N == 0 MUST be a failure, not a pass. A gate that can silently no-op will: every wasm gate
# once shelled out to an absent `wasm-tools`, printed "skipping" and exited 0, so the WasmGC
# tandem gate had never once run on this machine. "Green" is not "ran".
if [ "$checked" -eq 0 ]; then
  echo "FAIL: checked 0 scripts — this gate matched nothing and would have reported green."
  echo "      \`git ls-files '*.sh'\` returned nothing; the gate is broken, not the tree."
  exit 1
fi

echo "PASS: checked $checked shell scripts — none prescribe the bare build_oracles.sh."
