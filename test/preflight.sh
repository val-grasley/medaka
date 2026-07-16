#!/bin/sh
# preflight.sh — the LOCAL agent loop. Fast, targeted, and deliberately INCOMPLETE.
#
#   sh test/preflight.sh [base-ref]        # default base: main
#
# WHY THIS EXISTS
# ---------------
# An agent that changes `parser.mdk` used to run `FORCE=1 build_oracles.sh`, which
# builds ALL 54 oracle binaries (54 × `medaka build` + clang) when it needs FOUR.
# On a shared box with several agents that is the single biggest source of CPU
# waste. This script derives the gate set from the DIFF, derives the oracle set from
# those gates, and builds only what it needs.
#
# ⚠️ THIS IS A FILTER, NOT AN AUTHORITY. ⚠️
# ------------------------------------------
# It runs a SUBSET. A green preflight does NOT mean the change is good — it means
# the change did not break the gates most likely to notice. **CI, running the FULL
# suite on a pull request, is the authority.** Nothing merges on a green preflight.
#
# That distinction is load-bearing. This project's whole testing overhaul exists
# because the suite used to report green while silently testing nothing (a missing
# oracle exited 2 = SKIP != FAIL; a gate that could not even be parsed by dash was
# counted as "skipped" for months). A targeted local run RE-INTRODUCES exactly that
# hazard if anyone mistakes it for the real suite. So this script ENDS by printing
# what it did not run. Do not make it quiet.
#
# WHAT IT DELIBERATELY SKIPS (CI runs these):
#   * diff_compiler_engines   — 346 fixtures × clang. The clang storm. ~2.5 min.
#     ⚠️ That skip lives in ONE place — the LOCAL_SKIP block, which is BELOW the
#     PREFLIGHT_DRY exit. It must never be expressed in the change→gate map: CI reads
#     that map to narrow its PR run, so a "local" skip written there is not local. See
#     #402 and the LOCAL_SKIP comment.
#   * selfcompile_fixpoint    — minutes. Only forced locally on a BACKEND change,
#                               because for the emitter it is the decisive gate and
#                               finding out in CI is too late.
#   * the full 82-gate suite  — CI shards it across 6 hosted runners for free.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Keep the build/test write-storm OUT OF RAM (/tmp is a RAM-backed tmpfs).
. "$ROOT/test/lib_scratch.sh"
mdk_warn_if_tmp_full
BASE="${1:-main}"
cd "$ROOT" || exit 1

# ── Where the changed-file list comes from ───────────────────────────────────
#
# Normally: git, relative to $BASE. But CI cannot use that. On a `pull_request`
# event `actions/checkout` gives a SHALLOW checkout of the PR's MERGE ref, so
# there is no `main` branch locally and no merge-base to three-dot against; the
# `detect` job already resolves base/head SHAs (fetching them explicitly) and
# diffs them itself. PREFLIGHT_CHANGED_FILE lets it hand that list straight in.
#
# This parameterizes only the INPUT ("what changed"), never the DERIVATION
# ("which gates does that touch"). The derivation below stays the single
# implementation — CI narrowing its PR run must not become a second, drifting
# copy of this file's change→gate map. See .github/workflows/ci.yml.
if [ -n "${PREFLIGHT_CHANGED_FILE:-}" ]; then
  [ -f "$PREFLIGHT_CHANGED_FILE" ] || {
    echo "preflight: PREFLIGHT_CHANGED_FILE='$PREFLIGHT_CHANGED_FILE' does not exist."
    exit 1
  }
  changed="$(cat "$PREFLIGHT_CHANGED_FILE")"
  BASE="(PREFLIGHT_CHANGED_FILE)"
else
  # committed-vs-base, working tree, INDEX, and untracked. `--cached` is not optional:
  # without it a fully-`git add`ed change is invisible here (working-tree diff is empty and
  # nothing is committed yet), so `preflight` printed "no changes vs main — nothing to do"
  # and exited 0 over a staged rewrite of the compiler. That is the same silent-green
  # failure as the gate-existence check below, one step earlier in the pipe.
  changed="$(git diff --name-only "$BASE"...HEAD 2>/dev/null; git diff --name-only 2>/dev/null; git diff --name-only --cached 2>/dev/null; git ls-files -o --exclude-standard 2>/dev/null)"
fi
changed="$(printf '%s\n' "$changed" | sort -u | grep -v '^$')"

if [ -z "$changed" ]; then
  echo "preflight: no changes vs $BASE — nothing to do."
  exit 0
fi

echo "── changed vs $BASE ──────────────────────────────────────────"
printf '%s\n' "$changed" | sed 's/^/  /'
echo

# ── changed path → gate patterns ─────────────────────────────────────────────
# Deliberately CONSERVATIVE: a change to an early stage cascades downstream, so we
# select downstream gates too. When in doubt, run MORE. A false positive costs
# seconds; a false negative costs a red CI and a round-trip.
pats=""
add() { case " $pats " in *" $1 "*) ;; *) pats="$pats $1" ;; esac; }

# ── fixture/golden directory → its ACTUAL consumers ──────────────────────────
#
# Naively, ANY change under a `*fixtures*`/`*goldens*` dir used to `add
# 'diff_compiler_*'` — every gate, including `diff_compiler_engines` (346
# fixtures × clang, the single most expensive gate in the tree). That is every
# well-behaved bug fix, since a regression fixture is required with every fix.
#
# Fix: derive the consuming gates from the gate SCRIPTS, same philosophy as the
# rest of this file (and `build_oracles.sh --for`) — never a hand-maintained
# fixture-dir→gate map, which drifts. AGENTS.md already prescribes this
# procedure manually ("Before touching a fixture dir, find every consumer:
# `grep -rl '<fixture_dir>' test/`. Then run all of them.") — this automates it.
#
# "gate" candidate universe. First cut was an INCLUDE-list by naming family
# (diff_compiler_*, bootstrap_*, selfcompile_*, wasm/diff_*) — wrong: this repo
# has plenty of real corpus-consuming gates outside those families
# (cross_project_twonames.sh reads test/cross_project_fixtures/twonames/goldens,
# check_removed_constructs.sh, effect_*_domain.sh, build_construct_coverage.sh,
# manifest_emit.sh, lsp_harness.sh, assemble_check_main.sh, w1.sh, …), so an
# include-list silently produced FALSE "no consumer found" on real corpora —
# exactly the failure mode this derivation exists to prevent. An include-list
# by naming convention also rots the same way a hand-maintained map does: every
# new gate with a novel name needs a new entry.
#
# So: the universe is EVERY GATE, MINUS the scripts that are infra (build/capture/
# orchestrate/profile) rather than pass/fail regression gates over a corpus. An
# EXCLUDE-list is far more stable than an include-list — a new *gate* is added
# constantly; a new *infra utility* is not.
#
# ⚠️ The exclude-list is NOT written here. It is test/CI-COVERAGE-TOOLS.txt — see
# _gate_candidates below for why a second copy of it in this file was itself a bug.
# ── THE GATE UNIVERSE: every TRACKED-OR-UNTRACKED-NOT-IGNORED .sh in the repo
#    that is not a TOOL ─────────────────────────────────────────────────────
#
# This used to enumerate `test/*.sh` + `test/wasm/*.sh`, filtered by a hand-written
# _NONGATE list. Both halves were the same bug, and it is the bug this whole workstream
# exists to kill:
#
#   * The ROOTS were a curated pair of globs. So the derivation could not see
#     test/native_fixtures/run.sh (a SUBDIRECTORY of test/), the 22
#     sqlite/test/*oracle.sh gates, or playground/e2e/run.sh — 24 real gates. A corpus
#     consumed only by one of those derived ZERO consumers, hit the fallback, and ran
#     the full 83-gate suite while proving nothing about what actually reads it.
#   * _NONGATE was a SECOND, hand-maintained copy of the tools list, free to drift from
#     test/CI-COVERAGE-TOOLS.txt — the file that already answers "is this a gate?" and
#     that diff_compiler_ci_shard_coverage.sh treats as authoritative.
#
# So: one source of truth (CI-COVERAGE-TOOLS.txt), and the same universe the coverage
# gate enumerates. This makes preflight the FIFTH consumer of one rule, alongside
# run_gates.sh, build_oracles.sh --for, the coverage gate, and preflight's own pattern
# resolver. A derivation that disagreed with the other four would quietly under-run.
#
# `git ls-files`, not a filesystem walk: this box keeps ~30 agent worktrees under
# `.claude/worktrees/`, and a `find` from the main checkout would happily enumerate every
# OTHER worktree's copy of every gate. `git -C "$ROOT" ls-files` (tracked and, via
# `-o --exclude-standard`, untracked-not-ignored) stays scoped to THIS worktree's
# working tree, so it can't leak another worktree's files the way `find` would.
#
# Tracked-only was itself a bug (#257): `changed` (~line 68) deliberately folds in
# untracked-not-ignored files via `git ls-files -o --exclude-standard` so a brand-new,
# not-yet-`git add`ed gate script is exercised — but a tracked-only candidate universe
# couldn't count that same file, so `total_gates` undercounted by exactly the untracked
# gates in `$gates`. The union below mirrors the same `-o --exclude-standard` `changed`
# already uses, so the denominator covers exactly what `$gates` can ever contain.
_TOOLS=" $(grep -v '^[[:space:]]*#' "$ROOT/test/CI-COVERAGE-TOOLS.txt" 2>/dev/null \
           | awk 'NF { print $1 }' | tr '\n' ' ')"
_gate_candidates() {
  { git -C "$ROOT" ls-files '*.sh' 2>/dev/null; \
    git -C "$ROOT" ls-files -o --exclude-standard '*.sh' 2>/dev/null; } \
    | sort -u | while IFS= read -r _rel; do
    case "$_TOOLS" in *" ${_rel%.sh} "*) continue ;; esac
    [ -f "$ROOT/$_rel" ] || continue
    printf '%s\n' "$ROOT/$_rel"
  done
}

# Live (non-comment) reference to fixture-dir $2 inside file $1. Comments are
# stripped FIRST (full-line `#...` only) so a gate's header PROSE can't be
# mistaken for a live dependency — the exact bug `run_gates.sh`'s stale-oracle
# scrape has today (it greps `test/bin/...` including comment blocks, so a gate
# whose header says "REPLACES test/bin/parse_main" is believed to depend on a
# probe it never opens). Word-boundaries on both sides so `llvm_fixtures`
# cannot match `llvm_fixtures_modules`/`llvm_fixtures_typed` (real sibling
# corpora in this tree), and so `test/diff_fixtures` cannot match inside
# `test/snapshots/diff_fixtures` (also real, also distinct).
_refs() {
  grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -qE "(^|[^A-Za-z0-9_])$2([^A-Za-z0-9_]|\$)"
}

# Other test/*.sh or test/wasm/*.sh scripts $1 ACTUALLY INVOKES (live,
# non-comment). Anchored on the literal `sh "$ROOT/test/...` idiom this repo
# uses EVERY real invocation site (verified: 9/9 real invocations in test/*.sh
# use this exact quoted-$ROOT form). Deliberately NOT a bare `test/[name].sh`
# scrape — this codebase is full of human-readable hint strings like
# `echo "build oracles first: sh test/build_oracles.sh"` that name a script
# without invoking it; a bare scrape (the same shape as run_gates.sh's stale-
# oracle `test/bin/...` bug) falsely turned diff_compiler_new.sh into an
# "indirect consumer" of test/llvm_fixtures via its unrelated
# `echo "no golden tree ... run sh test/capture_goldens.sh"` error message,
# ballooning one fixture's consumer set from 3 gates to 42. Caught by testing
# this derivation against the real corpus before trusting it.
_invokes() {
  grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -ohE 'sh "\$ROOT/test/(wasm/)?[A-Za-z0-9_]+\.sh' \
    | sed 's/^sh "\$ROOT\///' | sort -u
}

# Does gate $1 consume fixture dir $2 — directly, OR indirectly via one hop
# through a helper it invokes? (Real case: diff_compiler_tmc_parity.sh never
# mentions test/wasm/fixtures itself — it shells to test/tmc_census.sh, and
# THAT script reads the corpus. Missing this one-hop case would silently drop
# a genuine consumer, exactly the false-negative this derivation must avoid.)
_consumes() {
  _gate="$1"; _d="$2"
  _refs "$_gate" "$_d" && return 0
  for _h in $(_invokes "$_gate"); do
    _hp="$ROOT/$_h"
    [ -f "$_hp" ] && [ "$_hp" != "$_gate" ] && _refs "$_hp" "$_d" && return 0
  done
  return 1
}

# Fixture directory for a changed path: climb from its parent to the nearest
# ancestor whose name contains "fixtures" or "goldens".
_fixture_dir_for() {
  _fd="$(dirname "$1")"
  while [ "$_fd" != "." ] && [ "$_fd" != "/" ] && [ "$_fd" != "test" ]; do
    case "$(basename "$_fd")" in
      *fixtures*|*goldens*) printf '%s\n' "$_fd"; return 0 ;;
    esac
    _fd="$(dirname "$_fd")"
  done
  return 1
}

# Gates that consume fixture dir $1. If the exact dir has no direct/one-hop
# consumer, climb to its parent and retry — some gates key off the PARENT, not
# the leaf (real case: test/snapshots/diff_fixtures is a snapshot-golden
# subdir; diff_compiler_snapshot_frontend.sh reads `$ROOT/test/snapshots`
# as a whole via SNAPDIR, never the literal string "test/snapshots/diff_fixtures").
# Stops before climbing to bare "test" (which would trivially match everything).
_gates_for_fixture_dir() {
  _d="$1"
  while : ; do
    _found=""
    for _g in $(_gate_candidates); do
      _consumes "$_g" "$_d" && _found="$_found
$_g"
    done
    if [ -n "$_found" ]; then
      printf '%s\n' "$_found" | grep -v '^$'
      return 0
    fi
    _parent="$(dirname "$_d")"
    case "$_parent" in
      test|.) return 1 ;;
    esac
    _d="$_parent"
  done
}

# ── UNMAPPED: a changed path that hits NO arm of the table below ─────────────
#
# The table is a semantic map (path → the gates that could plausibly notice a change
# there). Plenty of real paths are outside it: Makefile, .github/**, test/run_gates.sh,
# test/CI-COVERAGE-*.txt, compiler/entries/**, .claude/**, playground/**, and every
# prose .md. Locally that is harmless — preflight is a filter, and an unmapped file
# just contributes no gates.
#
# But the moment a CONSUMER uses this derivation to decide what to SKIP, "contributes
# no gates" and "I have no opinion about this file" become dangerously different
# answers, and this script was returning the first for both. So it now says which
# files it had no opinion about. .github/workflows/ci.yml reads this list and refuses
# to narrow a PR run when anything on it is not provably prose — i.e. an unmapped file
# widens CI back to the full suite rather than silently shrinking it.
#
# It is also a genuine local finding: `compiler/entries/*.mdk` (the oracle probe
# sources) hits no arm, so a change there derives only the snapshot gates today —
# under-running the gates that read the oracle it builds. Being loud about it is how
# that gets fixed rather than forgotten.
unmapped=""
note_unmapped() { case " $unmapped " in *" $1 "*) ;; *) unmapped="$unmapped $1" ;; esac; }

# ── BLAST RADIUS: the changed path is used EVERYWHERE. Run the whole suite. ───
#
# `add 'diff_compiler_*'` was doing double duty here and it is NOT the same thing as
# "the whole suite". That glob selects the 85 test/diff_compiler_*.sh gates and MISSES
# every gate outside the family — build_cmd, the 4 bootstrap_*, the 3 selfcompile_*,
# check_syntax_examples, cross_project_*, manifest_emit, lsp_harness, diff_net,
# diff_native_*, the 4 effect_*_domain, native_fixtures/run, and all 22
# sqlite/test/*oracle. For a prelude change, every one of those is in the blast radius.
#
# So a blast-radius path now raises a distinct FLAG rather than widening a glob. Locally
# it still adds 'diff_compiler_*' (unchanged behaviour — preflight is a fast filter and
# is explicit that it under-runs). But it SAYS SO, and CI reads the flag and refuses to
# narrow the PR run at all.
full_suite=0
full_reasons=""
mark_full() {
  full_suite=1
  case " $full_reasons " in *" $1 "*) ;; *) full_reasons="$full_reasons $1" ;; esac
  add 'diff_compiler_*'
}

need_fixpoint=0
for f in $changed; do
  case "$f" in
    # ── front-end: everything downstream of it is suspect ──
    compiler/frontend/lexer.mdk)
      add 'diff_compiler_lex*'
      add 'diff_compiler_parse*'; add 'diff_compiler_snapshot*' ;;
    compiler/frontend/parser.mdk|compiler/frontend/ast.mdk)
      add 'diff_compiler_parse*'
      add 'diff_compiler_snapshot*'; add 'diff_compiler_fmt' ;;
    compiler/frontend/desugar.mdk)
      add 'diff_compiler_snapshot*'; add 'diff_compiler_eval*' ;;
    compiler/frontend/resolve.mdk|compiler/frontend/marker.mdk)
      add 'diff_compiler_resolve*'; add 'diff_compiler_snapshot*'; add 'diff_compiler_check*' ;;
    compiler/frontend/exhaust.mdk)
      add 'diff_compiler_exhaust'; add 'diff_compiler_check_match' ;;

    # ── types ── (also the TYPES snapshot family: typecheck.mdk renders the
    #    `# TYPES` section of test/snapshots/typecheck{,_panic}_fixtures, #81 R5)
    compiler/types/*)
      add 'diff_compiler_typecheck*'; add 'diff_compiler_snapshot*'
      add 'diff_compiler_check*'; add 'diff_compiler_exhaust'
      add 'diff_compiler_diagnostics'; add 'diff_compiler_eval_typed*' ;;

    # ── THE THREE ENGINES ─────────────────────────────────────────────────────
    #
    # diff_compiler_engines is the differential that proves eval == native == wasm on
    # the SAME programs (it found 4 bug classes on its first run). Its subject is not a
    # directory — it is the three engines themselves, and each one has an owning arm:
    #
    #     eval    -> compiler/eval/* , compiler/ir/core_ir_eval.mdk
    #     native  -> compiler/backend/llvm_emit.mdk
    #     wasm    -> compiler/backend/wasm_emit.mdk
    #
    # ...and compiler/ir/* is the Core IR lowering that FEEDS two of the three, so a
    # change there moves what the differential compares just as directly.
    #
    # None of those arms derived it (#402). A WasmGC emitter change derived the llvm,
    # core_ir and snapshot gates and NOT the gate whose entire job is to notice that the
    # wasm engine now disagrees with the other two. It is the exclusion this file's own
    # rule warns about — "when in doubt, run MORE" — and ci.yml's: "a gate wrongly
    # INCLUDED costs CI minutes, which are free on a public repo. A gate wrongly
    # EXCLUDED is a bug that reaches the queue."
    #
    # The CI cost is close to nil: `engines` owns its runner alone, so it is wall-clock
    # parallel with the shard a backend/eval/ir change is already paying for (backend is
    # 5.3 min against engines' 5.8 min). Locally it costs nothing at all — LOCAL_SKIP
    # drops it below the PREFLIGHT_DRY exit, which is the whole point of that block.

    # ── eval: also the in-language suite and the capability matrix ──
    # diff_compiler_snapshot* covers diff_compiler_snapshot_eval, whose `# EVAL`
    # section is produced by the eval pipeline — an eval.mdk change moves it.
    compiler/eval/*|compiler/ir/core_ir_eval.mdk)
      add 'diff_compiler_eval*'; add 'diff_compiler_snapshot*'; add 'diff_compiler_core_ir*'
      add 'diff_compiler_ported'; add 'diff_compiler_test'; add 'diff_compiler_capability_matrix'
      add 'diff_compiler_engines' ;;

    compiler/ir/*)
      add 'diff_compiler_core_ir*'; add 'diff_compiler_llvm*'; add 'diff_compiler_snapshot*'
      add 'diff_compiler_engines' ;;

    # ── backend: the FIXPOINT is the decisive gate; do not defer it to CI ──
    #
    # diff_compiler_tmc_parity is here and NOT on the arms above: it proves both backends
    # TMC the SAME functions, and the shared analysis it guards (backend/trmc_analysis.mdk)
    # plus both emitters that consume it all live under this arm. It self-provisions its
    # own emit probes, so it needs no oracle wiring here.
    compiler/backend/*)
      add 'diff_compiler_llvm*'; add 'diff_compiler_build'; add 'diff_compiler_core_ir*'
      add 'diff_compiler_capability_matrix'
      add 'diff_compiler_engines'; add 'diff_compiler_tmc_parity'
      need_fixpoint=1 ;;

    compiler/driver/*)
      add 'diff_compiler_check*'; add 'diff_compiler_diagnostics'; add 'diff_compiler_build' ;;
    compiler/tools/lint*.mdk)      add 'diff_compiler_lint*' ;;
    compiler/tools/fmt.mdk|compiler/tools/printer.mdk) add 'diff_compiler_fmt'; add 'diff_compiler_snapshot*' ;;
    compiler/tools/lsp.mdk)        add 'diff_compiler_lsp*' ;;
    compiler/tools/snapshot.mdk)
                                   add 'diff_compiler_snapshot*' ;;
    compiler/tools/repl.mdk)       add 'diff_compiler_repl' ;;
    compiler/tools/*test*|compiler/tools/doctest.mdk|compiler/tools/prop_runner.mdk)
      add 'diff_compiler_test'; add 'diff_compiler_ported' ;;
    compiler/tools/*)              add 'diff_compiler_check*' ;;

    # ── the compiler's private mini-stdlib: used by every stage. ──
    compiler/support/*)            mark_full 'compiler/support' ;;

    # ── the oracle probe SOURCES. Changing one changes the BINARY the gates read. ──
    # There was no arm for these at all, so `compiler/entries/eval_main.mdk` derived
    # only the snapshot gates — i.e. preflight would rebuild the very probe that
    # diff_compiler_eval reads and then not run diff_compiler_eval.
    compiler/entries/*)            mark_full 'compiler/entries' ;;

    # ── stdlib / runtime: BLAST RADIUS. This arm used to be the narrowest in the file. ──
    #
    # It derived FIVE gates for `stdlib/core.mdk` — the IMPLICIT PRELUDE, prepended to
    # every program the compiler ever sees. A change there moves essentially every
    # golden in the tree (eval, core_ir, llvm, engines, typecheck, check, build, …), and
    # preflight would have reported green having run lexer + snapshot + doctests.
    # AGENTS.md already says this in prose — "stdlib/core.mdk → it is used *everywhere*;
    # the blast radius genuinely is the whole suite" — the map just never agreed with it.
    #
    # The whole of stdlib/, not just core: `medaka build` links the entire stdlib root
    # into every binary, `runtime.mdk` is the extern catalog every engine reads, and
    # since 2026-06-29 the COMPILER ITSELF imports stdlib (support/ordmap.mdk wraps
    # stdlib `Map`), so `stdlib/map.mdk` is transitively compiler source. runtime/ is the
    # C runtime linked into every binary. There is no narrow answer here that is true.
    stdlib/*|runtime/*)            mark_full 'stdlib-or-runtime' ;;

    # ── a changed GATE SCRIPT runs itself ─────────────────────────────────────
    #
    # ⚠️ CASE-ARM ORDER IS LOAD-BEARING, AND THIS ARM MUST STAY ABOVE THE CORPUS ARM.
    # `test/native_fixtures/run.sh` matches BOTH this arm and `test/*fixtures*/*` below,
    # and in a `case` the FIRST match wins. The split is deliberate and is the whole rule:
    #
    #     you changed a GATE      -> run that gate
    #     you changed a FIXTURE   -> derive the gates that CONSUME that fixture dir
    #
    # Not covered by the corpus derivation, and not redundant with it: the derivation
    # answers "who READS this corpus", which is a different question from "I edited this
    # gate's own code".
    #
    # The pattern is the repo-relative path minus `.sh`, minus a leading `test/` —
    # 'diff_compiler_lexer', 'native_fixtures/run', 'build_cmd'. run_gates.sh,
    # build_oracles.sh --for and the coverage gate all resolve a slash-bearing pattern
    # from the repo ROOT, so these are exactly the names CI's shards use.
    #
    # ── …but ONLY if the gate still EXISTS (#337) ────────────────────────────
    # `changed` (see the `git diff --name-only` at the top) lists DELETED paths too,
    # and a deleted gate script derives a gate NAME with no backing script — which the
    # "matches NO gate" guard below then treats as a broken map and ABORTS on. That is
    # a false positive: the map is fine, the gate is simply gone. You cannot run a gate
    # that does not exist, and its absence is not a coverage gap in YOUR diff.
    #
    # This bites hardest via a STALE LOCAL `main`: `git diff main...HEAD` forks at an old
    # merge-base, so every gate deleted on main since then reads as "deleted by you".
    # That is exactly how #337 reproduced — `test/diff_compiler_check_modules_batch.sh`,
    # deleted in 00afa27d, aborted `make preflight` for agents who had never heard of it.
    #
    # Derived from the filesystem, NOT an exception list: nothing here is named, so this
    # cannot drift the way a hand-maintained skip list would.
    test/diff_compiler_*.sh|test/build_cmd.sh|test/native_fixtures/run.sh)
      _p="${f#test/}"
      if [ -f "$ROOT/$f" ]; then
        add "${_p%.sh}"
      else
        echo "preflight: note — gate '${_p%.sh}' is DELETED in this diff; nothing to run for it."
      fi ;;

    # ── the snapshot corpus: goldens, but NOT in a *fixtures*/*goldens* directory ──
    #
    # `_fixture_dir_for` only fires for a path with a `*fixtures*`/`*goldens*` ancestor,
    # and `test/snapshots/{compiler,stdlib,...}` has neither — so these 167 golden .md
    # files hit NO arm at all. That is not a corner case: AGENTS.md REQUIRES the moved
    # snapshot be blessed in the SAME COMMIT as the source change that moved it, so the
    # single most common compiler PR in this repo carries one. Leaving them unmapped
    # makes every such PR look like "I have no opinion about this file".
    #
    # Only the snapshot gates read them, and they read the tree as a whole (SNAPDIR),
    # never a per-file path — so the answer is the same for every file under it.
    test/snapshots/*)              add 'diff_compiler_snapshot*' ;;

    # ── sqlite: the derivation structurally CANNOT reach it ───────────────────
    # `_fixture_dir_for` only fires for a path with a `*fixtures*`/`*goldens*` ancestor
    # directory. The SQLite corpus has none — its goldens sit loose in `sqlite/test/`
    # next to the oracles that read them — so the corpus derivation never triggers and
    # these gates would derive NOTHING. That is not a redundant arm; it is the only
    # thing standing between "edit the SQLite library" and "preflight runs nothing about
    # it and prints green".
    sqlite/test/*|sqlite/lib/*|sqlite/*.mdk|sqlite/medaka.toml)
      add 'sqlite/test/*oracle' ;;

    # ── fixture/golden corpus change: run its ACTUAL consumers, not everything.
    # See _gates_for_fixture_dir above. A directory with zero discoverable
    # consumers is a real finding (dead corpus, or a gap in this derivation) —
    # loudly fall back to the full suite rather than silently running nothing.
    #
    # T8 note: this now composes with the gates that do not live in test/. The
    # derivation scans the FULL gate universe (see _gate_candidates), so
    # `test/native_fixtures/*.mdk` correctly derives `native_fixtures/run` and
    # `test/build_cmd_fixtures/*` correctly derives `build_cmd` — no explicit arm
    # needed for either, and none is present. Before the universe was widened, both
    # corpora had ZERO discoverable consumers and hit the full-suite fallback.
    test/*fixtures*/*|test/*goldens*/*)
      _fdir="$(_fixture_dir_for "$f")" || _fdir=""
      if [ -z "$_fdir" ]; then
        echo "preflight: WARNING — could not identify a fixture directory for '$f'; falling back to the FULL suite."
        mark_full "unidentifiable-fixture-dir:$f"
      else
        _gset="$(_gates_for_fixture_dir "$_fdir")"
        # A corpus DELETED in this diff has no consumers because it no longer exists —
        # that is not the "dead fixture or derivation gap" the warning below diagnoses,
        # and widening to the full suite over it is pure cost (#337). Same stale-`main`
        # trigger as the deleted-gate arm above: test/core_ir_sexp_fixtures, removed in
        # b5170cab by the snapshot migration, dragged agents into the full 84-gate suite.
        # `_fixture_dir_for` is purely lexical, so it happily names a dir that is gone.
        if [ ! -d "$ROOT/$_fdir" ]; then
          echo "preflight: note — fixture dir '$_fdir' is DELETED in this diff; nothing to run for it."
        elif [ -z "$_gset" ]; then
          echo "preflight: WARNING — '$_fdir' has NO discoverable consumer (checked live references across every tracked gate script in the repo — every .sh not listed in test/CI-COVERAGE-TOOLS.txt, which now includes sqlite/test/, test/native_fixtures/ and playground/e2e/ — including one hop through any helper script a gate invokes). This is either a DEAD fixture directory or a gap in this derivation — investigate '$_fdir'. Falling back to the FULL suite for safety."
          mark_full "no-consumer:$_fdir"
        else
          # Report each fixture dir ONCE, however many of its files changed. Adding a
          # .mdk plus its .expected golden is the normal case and printed the same
          # derivation line twice, which reads like the derivation ran twice.
          case " ${_reported_dirs:-} " in
            *" $_fdir "*) ;;
            *) _reported_dirs="${_reported_dirs:-} $_fdir"
               printf 'preflight: %s → %s\n' "$_fdir" \
                 "$(printf '%s\n' "$_gset" | xargs -n1 basename | tr '\n' ' ')" ;;
          esac
          for _g in $_gset; do
            _pat="${_g#"$ROOT"/test/}"
            add "${_pat%.sh}"
          done
        fi
      fi ;;

    # ── no arm matched: record it, do not silently ignore it. See `unmapped` above.
    *) note_unmapped "$f" ;;
  esac
done

# ── the snapshot corpus is not a fixture dir; it is the SOURCE TREE ──────────
# Every compiler/**.mdk and stdlib/*.mdk is IN the snapshot corpus (each one carries its
# own `# SOURCE` section), so ANY edit to one moves its snapshot — a pure `medaka fmt`
# reflow is enough. That cuts across every arm of the table above, and `case` fires only
# its FIRST matching arm, so it cannot be expressed there: a second pass is the only
# correct shape.
#
# Without this, preflight reported GREEN on (say) a compiler/eval/ change while
# diff_compiler_snapshot_frontend was red — the exact "your change would have been tested
# by NOTHING" failure the gate-existence check below exists to prevent, one level up.
#
# ── the SAME reasoning applies to LEG A of diff_compiler_selfproc (#189) ─────
# LEG A runs the WHOLE compiler/*.mdk source through itself in one union closure
# (compiler/entries/all_modules_entry.mdk forces every module in) and diffs each
# module's inferred schemes against test/selfproc_goldens/legA/<module>.golden.
# ANY compiler/*.mdk change that adds/renames/removes a top-level binding can move
# that module's legA golden — same shape as the snapshot corpus, and for the same
# reason: no single arm of the table above names this gate, so it never fires there.
# Bit #161 and #185 identically (each needed a second rebless commit after CI, not
# preflight, caught it).
#
# stdlib/core.mdk and stdlib/runtime.mdk belong in this trigger too — for a DIFFERENT
# reason than the compiler modules. legA's closure is not just compiler source: the
# harness passes $CORE (stdlib/core.mdk, the implicit prelude) and $RUNTIME
# (stdlib/runtime.mdk, the extern catalog) into check_all_main
# (diff_compiler_selfproc.sh:103 — `"$CHECK_ALL" "$RUNTIME" "$CORE" "$ENTRY" ...`). A
# prelude- or runtime-signature change can therefore shift the inferred schemes of the
# COMPILER modules that reference it, moving a compiler module's legA golden even though
# core/runtime carry no golden of their own (the legA golden set is exactly the 13
# compiler-only dotted mids in MODULES — verified: `ls test/selfproc_goldens/legA/`).
# So the stdlib side of this trigger is scoped to exactly the two files legA loads by
# name. A LEAF stdlib module (map, set, …) is not passed into the closure by name, so it
# gets no entry here; a change to one still reaches selfproc via the blast-radius
# `stdlib/*|runtime/*` arm above (which does `add 'diff_compiler_*'`, matching selfproc).
for f in $changed; do
  case "$f" in
    compiler/*.mdk|compiler/*/*.mdk|stdlib/*.mdk) add 'diff_compiler_snapshot*' ;;
  esac
  case "$f" in
    compiler/*.mdk|compiler/*/*.mdk|stdlib/core.mdk|stdlib/runtime.mdk) add 'diff_compiler_selfproc' ;;
  esac
done

# ── resolve gates → the ORACLES they actually need ───────────────────────────
#
# ⚠️ A PATTERN THAT MATCHES ZERO GATES IS AN ERROR, NOT AN EMPTY SET.
#
# The change→gate map above hardcodes gate-name globs. When a gate is RENAMED or
# DELETED — which the snapshot migration does, on purpose, family by family — a stale
# glob silently matches NOTHING. The mapped file then resolves to NO GATE AT ALL, and
# preflight cheerfully reports success having tested that file with nothing.
#
# This ALREADY happened: the snapshot migration deleted diff_compiler_{parse,desugar,
# mark,desugar_batch,mark_batch}.sh, and preflight's `'diff_compiler_desugar*'` /
# `'diff_compiler_mark*'` globs went dead. A change to frontend/desugar.mdk would have
# mapped to zero gates and passed.
#
# It is the same bug as `$ROOT/compiler/*.mdk` globbing to zero files after the
# subfolder reorg (which silently dropped the compiler's own sources from the desugar
# corpus), and the same as a gate matching no CI shard. "This didn't run" must never be
# indistinguishable from "this passed."
gates=""
for pat in $pats; do
  matched=0
  # Resolve against BOTH $ROOT/test/ and $ROOT/ — the same rule run_gates.sh,
  # build_oracles.sh --for and diff_compiler_ci_shard_coverage.sh use, so a pattern
  # naming a gate outside test/ ('sqlite/test/*oracle') resolves identically in all
  # four. Without this arm, preflight's own "matches NO gate" guard fired on the very
  # patterns its change→gate map had just emitted.
  for g in "$ROOT"/test/$pat.sh "$ROOT"/$pat.sh; do
    [ -f "$g" ] || continue
    matched=1
    case " $gates " in *" $g "*) ;; *) gates="$gates $g" ;; esac
  done
  if [ "$matched" -eq 0 ]; then
    echo "preflight: FAIL — the change→gate map points at '$pat', which matches NO gate."
    echo "  A gate was probably renamed or deleted (the snapshot migration does this)."
    echo "  Your change would have been tested by NOTHING. Fix the map in $0."
    exit 1
  fi
done

# ── PREFLIGHT_DRY=1: print the derived gate set and stop ──────────────────────
# The change→gate derivation is the part most likely to silently under-run, and it was
# the only part with no way to inspect it short of a full 5-minute build+run. Now you
# can ask it what it WOULD run, which is also how the T8/T15 integration cases are
# verified.
#
# It is ALSO what .github/workflows/ci.yml's `detect` job runs to narrow the
# `pull_request` gate run (the `merge_group` run stays FULL). So it must be free —
# no `make medaka`, no oracle build, nothing but the derivation. It runs BEFORE the
# build for exactly that reason; do not move the build back above it.
#
# Three machine-readable prefixes, deliberately stable — CI parses them:
#   GATE      <repo-relative path of a gate this diff selects>
#   UNMAPPED  <changed path the map has NO OPINION about>
#   FULL      <reason this diff has whole-suite blast radius>
# CI narrows a `pull_request` run ONLY when there is no FULL line and every UNMAPPED
# path is provably prose (its own docs allowlist decides that). Anything else widens
# it back to the full suite. `merge_group` is never narrowed, whatever this prints.
#
# ⚠️ EVERYTHING ABOVE THIS EXIT IS A STATEMENT ABOUT THE DIFF, NOT ABOUT THIS BOX (#402).
# CI cannot tell the two apart — it just reads the GATE lines. So a gate this script
# declines to RUN for local cost reasons must still be PRINTED here, and must be dropped
# below, in LOCAL_SKIP. Putting a cost decision above this line silently exports it to
# every PR: `gates (engines)` reported SUCCESS in 5s having run ZERO gates on every
# backend PR because `diff_compiler_engines` was "locally skipped" by being absent from
# the map that CI reads.
if [ -n "${PREFLIGHT_DRY:-}" ]; then
  printf '── would run %s gate(s) ─────\n' "$(printf '%s\n' $gates | grep -c .)"
  for g in $gates; do printf '  GATE      %s\n' "${g#"$ROOT"/}"; done
  if [ "$full_suite" -eq 1 ]; then
    printf '── BLAST RADIUS: this diff touches something used everywhere ─────\n'
    for r in $full_reasons; do printf '  FULL      %s\n' "$r"; done
    printf '  (locally that means the 85 diff_compiler_* gates; in CI it means the whole suite.)\n'
  fi
  if [ -n "$unmapped" ]; then
    printf '── %s path(s) the change→gate map has NO OPINION about ─────\n' \
      "$(printf '%s\n' $unmapped | grep -c .)"
    for u in $unmapped; do printf '  UNMAPPED  %s\n' "$u"; done
  fi
  exit 0
fi

[ -n "$pats" ] || { echo "preflight: no gates map to these changes (docs/config only?) — nothing to run."; exit 0; }

# ── LOCAL_SKIP: what THIS BOX declines to pay for. Not what the diff misses. ──
#
# ⚠️ THIS BLOCK IS BELOW THE PREFLIGHT_DRY EXIT ON PURPOSE. DO NOT MOVE IT UP. (#402)
#
# The two questions this script answers are different, and only one of them is CI's:
#
#     which gates does this diff TOUCH?   -> the change→gate map above. CI READS THIS.
#     which of those will I run HERE?     -> this block. Local only. CI never sees it.
#
# They were the same answer until #402, and the map was where the cost decision lived —
# `diff_compiler_engines` was skipped locally by simply never being added. .github/
# workflows/ci.yml derives its `pull_request` gate set by running this script with
# PREFLIGHT_DRY=1 (deliberately — one derivation, not two drifting copies), so it
# inherited the omission and skipped the gate on the PR too. `gates (engines)` reported
# SUCCESS in 5 seconds having run ZERO gates on every backend change, while the summary
# at the bottom of this file promised "CI runs these on the PR". Both halves were
# reasonable; composing them made the suite lie.
#
# The cost is real and the local skip is deliberate: 346 fixtures × (medaka build +
# clang), ~2.5 min, on a box several agents share. It just is not a claim about the diff.
#
# Only an EXACT pattern is dropped. A wildcard ('diff_compiler_*', a blast-radius diff)
# that still matches the gate legitimately pulls it back in and it runs like any other —
# the re-resolve below is what makes that fall out for free rather than needing a rule.
LOCAL_SKIP='diff_compiler_engines'

local_skipped=""
_np=""
for _p in $pats; do
  case " $LOCAL_SKIP " in
    *" $_p "*) local_skipped="$local_skipped $_p" ;;
    *)         _np="$_np $_p" ;;
  esac
done
pats="$_np"

if [ -n "$local_skipped" ]; then
  # Re-resolve the surviving patterns against the same two roots the resolver above
  # uses, so `$gates` keeps describing exactly what will run. Re-resolving (rather than
  # subtracting a path) is what preserves the wildcard case: if 'diff_compiler_*' is
  # still in $pats it matches the skipped gate again and it comes back, correctly.
  gates=""
  for pat in $pats; do
    for g in "$ROOT"/test/$pat.sh "$ROOT"/$pat.sh; do
      [ -f "$g" ] || continue
      case " $gates " in *" $g "*) ;; *) gates="$gates $g" ;; esac
    done
  done
  [ -n "$pats" ] || {
    echo "preflight: every gate this diff derives is a local-only skip ($local_skipped) — nothing to run HERE."
    echo "  That is a LOCAL cost decision, not a coverage gap: CI's pull_request run derives and RUNS them."
    exit 0
  }
fi

# ── BLAST RADIUS: say so BEFORE you spend the box on it (#492) ───────────────
#
# `mark_full` adds the `diff_compiler_*` catch-all, so for a blast-radius path
# (stdlib/core.mdk, compiler/support/*, compiler/entries/*, …) `make preflight` IS the
# full 84-gate suite — the exact thing AGENTS.md tells agents never to run locally. The
# WIDENING IS CORRECT AND STAYS: a prelude change moves essentially every golden, and a
# narrow preflight would report green having run lexer + snapshot + doctests.
#
# The bug was that it was INVISIBLE. PREFLIGHT_DRY has printed this banner for a while,
# but the run path — the one agents actually take — said nothing, so an agent obeyed
# "the loop", the shared box hit load 30, and the agent got blamed for ignoring a brief
# they had followed to the letter. Two were killed for this in one session. An
# instruction that silently expands into what another instruction forbids is worse than
# either alone: the person who obeys is the one who pays.
#
# So: announce it, and offer a documented way out that does NOT lie about coverage.
# PREFLIGHT_NO_FULL=1 runs NOTHING and says so — it deliberately does NOT fall back to a
# narrower subset, because a suite that reports green while testing less than it appears
# to is this repo's #1 hazard, and the whole point here is that the narrow set is wrong.
if [ "$full_suite" -eq 1 ]; then
  echo
  echo "── ⚠️  BLAST RADIUS — THIS IS THE FULL SUITE ─────────────────"
  for r in $full_reasons; do echo "  FULL      $r"; done
  echo "  A path in this diff is used everywhere, so the change→gate map widened to the"
  echo "  'diff_compiler_*' catch-all: this run IS the whole local gate suite, not a"
  echo "  targeted subset. On this SHARED box that takes the load average past 10 and"
  echo "  turns everyone else's 30-second gate into minutes."
  echo
  echo "  The widening is CORRECT — a prelude/support change moves essentially every"
  echo "  golden, and a narrow run here would be green for the wrong reason."
  echo "  Preferred: push and let CI run it across its parallel runners."
  echo
  echo "  To decline locally:  PREFLIGHT_NO_FULL=1 sh test/preflight.sh"
  echo "  Exact command this run is about to become:"
  echo "      sh test/run_gates.sh $pats"
  echo
  if [ -n "${PREFLIGHT_NO_FULL:-}" ]; then
    echo "── PREFLIGHT_NO_FULL=1 — DECLINED. RAN NOTHING. ──────────────"
    echo "  This is NOT a pass and NOT a coverage statement: zero gates ran here."
    echo "  Nothing about this diff has been verified locally. Push and let CI answer —"
    echo "  CI is the authority regardless (preflight is a filter, never an authority)."
    exit 0
  fi
fi

# ── build the compiler ───────────────────────────────────────────────────────
#
# NO EMITTER BORROW. `make medaka` cold-bootstraps from compiler/seed/emitter.ll.gz.
#
# This block used to `cp` an emitter out of /root/medaka or a SIBLING WORKTREE, on the
# stated grounds that "a fresh worktree cannot cold-bootstrap". That justification is
# FALSE — measured on 2026-07-16 in a fresh worktree with no ./medaka_emitter:
#
#     BOOTSTRAP-FROM-SEED PASS: built .../medaka_emitter OCaml-free from the gzipped seed.
#
# and AGENTS.md says so directly: "A fresh worktree has NO ./medaka_emitter and that is
# FINE — it cold-bootstraps from compiler/seed/emitter.ll.gz and works."
#
# The borrow was actively harmful. AGENTS.md bans exactly this cp for worktree-isolated
# subagents: reading from a tree that is not yours can trip the auto-mode isolation
# classifier, and the denial is STATEFUL — it carries forward and blocks every later
# `make` you attempt, including a clean cold-bootstrap entirely inside your own worktree.
# An agent lost a whole session to this cp on 2026-07-16. So THE SANCTIONED AGENT LOOP
# was silently performing the one command the docs tell agents never to run, in the tree
# of whichever sibling agent happened to be live. Same disease as #492 and #470: the
# tooling made the banned path the silent default.
#
# The cost of not borrowing is the SEED BOOTSTRAP ONLY — measured 31s on this box
# (2026-07-16, `time sh test/bootstrap_from_seed.sh` -> real 0m31.003s, exit 0). It is not
# the ~1m52s a fresh `make medaka` takes: stages A and B run in the BORROW path too, because
# `cp` copies the emitter binary but NOT $ROOT/.medaka_emitter.srcstamp, so the borrowed
# emitter reads as "provenance unknown" and gets rebuilt from source anyway
# (build_native_medaka.sh:212-221 — "fresh bootstrap, or copied in from another tree" is ONE
# branch). Borrowing buys 31s and risks the session. Do not reintroduce it.
echo "── building ./medaka ─────────────────────────────────────────"
make -C "$ROOT" medaka >/dev/null 2>&1 || { echo "preflight: make medaka FAILED"; exit 1; }

# Build this diff's oracles by DELEGATING to build_oracles.sh --for. Do not re-derive
# the set here.
#
# preflight used to scrape `test/bin/<name>` out of the gate scripts itself, with the
# same one-line grep build_oracles uses — but WITHOUT build_oracles' crucial second
# step: intersecting the scraped names against the authoritative ENTRIES list. The grep
# matches COMMENTS, and diff_compiler_snapshot_frontend.sh:9 carries a comment naming
# `test/bin/desugar_batch` — an oracle whose entry was deleted when that gate was
# migrated into the snapshot corpus. So preflight dutifully tried to build a
# nonexistent oracle and hard-failed:
#
#     preflight: oracle build FAILED: desugar_batch
#
# after ~4.5 minutes of building. That made preflight — THE agent inner loop — unusable
# for ANY compiler-source change, since snapshot_frontend is in almost every gate set.
#
# The bug is not really the grep. It is that TWO PLACES derived the same set and only one
# of them knew the rule. So now there is one: build_oracles.sh --for is the single source
# of truth for "which oracles does this gate set need", and preflight calls it. Same
# derivation, one implementation, cannot drift again.
printf '── building the oracles these gates read ─────\n'
if ! sh "$ROOT/test/build_oracles.sh" --for $pats; then
  echo "preflight: oracle build FAILED"
  exit 1
fi

# ── run the targeted gates ───────────────────────────────────────────────────
echo
echo "── gates ─────────────────────────────────────────────────────"
rc=0
sh "$ROOT/test/run_gates.sh" $pats || rc=$?

# ── the fixpoint, for backend changes only ───────────────────────────────────
if [ "$need_fixpoint" -eq 1 ]; then
  echo
  echo "── selfcompile fixpoint (you touched the backend — this is THE decisive gate) ──"
  sh "$ROOT/test/selfcompile_fixpoint.sh" 2>&1 | grep -E 'C3a|C3b' || rc=1
fi

# ── SAY WHAT YOU DID NOT RUN. Never be quiet about this. ─────────────────────
#
# Two things this block must get right, both learned the hard way:
#
# 1. The TOTAL must be derived from the SAME universe `$gates` is actually drawn
#    from — not a narrower glob that happens to be convenient. `$gates` is
#    populated from three sources: the static change→gate pattern table
#    (`diff_compiler_*`, `sqlite/test/*oracle`, `native_fixtures/run`,
#    `build_cmd`, …), the "you edited a gate script" self-run arm, and
#    `_gates_for_fixture_dir`'s corpus-consumer scan — and that last one can name
#    ANY gate in the repo, not just a `diff_compiler_*` one (`bootstrap_*`,
#    `selfcompile_*`, the 22 `sqlite/test/*oracle` gates, `wasm/*`,
#    `cross_project_*`, …). A total that counts only `test/diff_compiler_*.sh`
#    undercounts that universe, and the moment enough non-`diff_compiler_*`
#    gates get pulled in, `ran_count` exceeds it (issue #113: 118 ran vs 87
#    counted, on a change whose fixture dir had non-`diff_compiler_*` consumers).
#    `_gate_candidates()` (defined above, ~line 144) is already the
#    authoritative "what is a gate" universe — it is the SAME function
#    `_gates_for_fixture_dir` walks to find corpus consumers, and every pattern
#    the static table adds names a gate that is a member of it (verified: none
#    of `diff_compiler_*`, `sqlite/test/*oracle`, `native_fixtures/run`, or
#    `build_cmd` appear in test/CI-COVERAGE-TOOLS.txt, the exclude-list
#    `_gate_candidates()` subtracts). So it is the correct denominator: every
#    gate `$gates` can ever contain is, by construction, counted here too — no
#    more baked-in literal to drift (72/82/83/84/87 — see AGENTS.md).
# 2. `diff_compiler_engines` is called out here as a standing skip, but a
#    wildcard `add 'diff_compiler_*'` (support/corpus changes) pulls it INTO
#    $gates and it runs above like everything else — printing it here
#    unconditionally then contradicts its own PASS/FAIL line a few lines up.
#    Check whether it actually ran before naming it a skip.
total_gates=$(_gate_candidates | wc -l | tr -d ' ')
ran_count=$(printf '%s\n' $gates | grep -vc '^$')
remaining=$(( total_gates - ran_count ))
if [ "$remaining" -lt 0 ]; then
  # $gates only ever gains a member by resolving a pattern to a real .sh file
  # (~line 480), and every pattern this script emits — the static table, the
  # gate-self-run arm, and _gates_for_fixture_dir's corpus-consumer scan — names
  # a file drawn from the same _gate_candidates() universe total_gates counts,
  # so ran_count > total_gates should be impossible. Surface it loudly rather
  # than silently clamping and hiding a real bookkeeping bug (this guard is
  # what caught #113 in the first place — keep it as a backstop).
  echo "preflight: INTERNAL INCONSISTENCY — ran_count ($ran_count) exceeds total_gates ($total_gates); the skip-count math below is WRONG. Report this, don't trust the number."
  remaining=0
fi

# WHERE a skipped gate actually runs is not one answer, it is three — and printing the
# wrong one is how #402 stayed invisible. "CI runs these on the PR" was asserted
# unconditionally, including for gates the PR run had ALSO just been told to skip.
# Say which of the three this is, every time.
engines_gate="$ROOT/test/diff_compiler_engines.sh"
case " $gates $local_skipped " in
  *" $engines_gate "*)
    engines_line="  diff_compiler_engines      ran above (pulled in by a wildcard gate match) — not a skip" ;;
  *" diff_compiler_engines "*)
    engines_line="  diff_compiler_engines      the 3-engine differential (346 fixtures × clang). This diff
                             DOES touch it — skipped HERE for cost only; CI's PR run
                             derives it and RUNS it." ;;
  *)
    engines_line="  diff_compiler_engines      not derived for this diff — so the PR's \`gates (engines)\`
                             shard will no-op too. It runs FULL in the merge queue." ;;
esac

cat <<EOF

── NOT RUN LOCALLY ───────────────────────────────────────────────
$engines_line
$([ "$need_fixpoint" -eq 1 ] || echo "  selfcompile_fixpoint       (not a backend change) — the \`soundness\` check runs it on every event; it is never narrowed.")
  the other $remaining of $total_gates gates

  This preflight is a FILTER, not an authority. A green run here means the gates
  most likely to notice your change did not break — nothing more. Push a branch and
  open a PR; CI runs the full suite on free hosted runners. DO NOT merge on this.
EOF

exit "$rc"
