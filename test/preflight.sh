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
#   * selfcompile_fixpoint    — minutes. Only forced locally on a BACKEND change,
#                               because for the emitter it is the decisive gate and
#                               finding out in CI is too late.
#   * the full 82-gate suite  — CI shards it across 6 hosted runners for free.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${1:-main}"
cd "$ROOT" || exit 1

# committed-vs-base, working tree, INDEX, and untracked. `--cached` is not optional:
# without it a fully-`git add`ed change is invisible here (working-tree diff is empty and
# nothing is committed yet), so `preflight` printed "no changes vs main — nothing to do"
# and exited 0 over a staged rewrite of the compiler. That is the same silent-green
# failure as the gate-existence check below, one step earlier in the pipe.
changed="$(git diff --name-only "$BASE"...HEAD 2>/dev/null; git diff --name-only 2>/dev/null; git diff --name-only --cached 2>/dev/null; git ls-files -o --exclude-standard 2>/dev/null)"
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
# So: the universe is EVERY test/*.sh and test/wasm/*.sh file, MINUS a short,
# stable EXCLUDE list of scripts that are infra (build/capture/orchestrate/
# profile), not pass/fail regression gates over a fixture corpus. This list is
# far more stable than an include-list would be — a new *gate* is added
# constantly; a new *infra utility* is not.
#   build_oracles.sh / build_wasm_oracle.sh / build_native_medaka.sh  — build probes/binaries
#   capture_goldens.sh   — explicitly documented "never in the gate loop" (WRITES fixtures)
#   refresh_seed.sh      — seed maintenance
#   run_gates.sh         — the runner itself
#   preflight.sh         — this script
#   profile_compiler.sh / bench.sh — timing/profiling harnesses, not pass/fail
#   tmc_census.sh        — inspection helper wrapped by diff_compiler_tmc_parity.sh
#                          (its own header: "run standalone to inspect"); its
#                          corpus reference is still picked up via the one-hop
#                          _invokes check on the gate that wraps it
_NONGATE=' build_oracles.sh build_wasm_oracle.sh build_native_medaka.sh capture_goldens.sh refresh_seed.sh run_gates.sh preflight.sh profile_compiler.sh bench.sh tmc_census.sh '
_gate_candidates() {
  for _g in "$ROOT"/test/*.sh "$ROOT"/test/wasm/*.sh; do
    [ -f "$_g" ] || continue
    case "$_NONGATE" in *" $(basename "$_g") "*) continue ;; esac
    printf '%s\n' "$_g"
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

need_fixpoint=0
for f in $changed; do
  case "$f" in
    # ── front-end: everything downstream of it is suspect ──
    compiler/frontend/lexer.mdk)
      add 'diff_compiler_lex*'; add 'diff_compiler_comments'; add 'diff_compiler_positions'
      add 'diff_compiler_parse*'; add 'diff_compiler_snapshot*' ;;
    compiler/frontend/parser.mdk|compiler/frontend/ast.mdk)
      add 'diff_compiler_parse*'; add 'diff_compiler_printer'; add 'diff_compiler_positions'
      add 'diff_compiler_snapshot*'; add 'diff_compiler_fmt' ;;
    compiler/frontend/desugar.mdk)
      add 'diff_compiler_snapshot*'; add 'diff_compiler_eval*' ;;
    compiler/frontend/resolve.mdk|compiler/frontend/marker.mdk)
      add 'diff_compiler_resolve*'; add 'diff_compiler_snapshot*'; add 'diff_compiler_check*' ;;
    compiler/frontend/exhaust.mdk)
      add 'diff_compiler_exhaust'; add 'diff_compiler_check_match' ;;

    # ── types ──
    compiler/types/*)
      add 'diff_compiler_typecheck*'; add 'diff_compiler_check*'; add 'diff_compiler_exhaust'
      add 'diff_compiler_diagnostics'; add 'diff_compiler_eval_typed*' ;;

    # ── eval: also the in-language suite and the capability matrix ──
    compiler/eval/*|compiler/ir/core_ir_eval.mdk)
      add 'diff_compiler_eval*'; add 'diff_compiler_core_ir*'; add 'diff_compiler_ported'
      add 'diff_compiler_test'; add 'diff_compiler_capability_matrix' ;;

    compiler/ir/*)
      add 'diff_compiler_core_ir*'; add 'diff_compiler_llvm*' ;;

    # ── backend: the FIXPOINT is the decisive gate; do not defer it to CI ──
    compiler/backend/*)
      add 'diff_compiler_llvm*'; add 'diff_compiler_build'; add 'diff_compiler_core_ir*'
      add 'diff_compiler_capability_matrix'
      need_fixpoint=1 ;;

    compiler/driver/*)
      add 'diff_compiler_check*'; add 'diff_compiler_diagnostics'; add 'diff_compiler_build' ;;
    compiler/tools/lint*.mdk)      add 'diff_compiler_lint*' ;;
    compiler/tools/fmt.mdk|compiler/tools/printer.mdk) add 'diff_compiler_fmt'; add 'diff_compiler_printer' ;;
    compiler/tools/lsp.mdk)        add 'diff_compiler_lsp*' ;;
    compiler/tools/snapshot.mdk)
                                   add 'diff_compiler_snapshot*' ;;
    compiler/tools/repl.mdk)       add 'diff_compiler_repl' ;;
    compiler/tools/*test*|compiler/tools/doctest.mdk|compiler/tools/prop_runner.mdk)
      add 'diff_compiler_test'; add 'diff_compiler_ported' ;;
    compiler/tools/*)              add 'diff_compiler_check*' ;;
    compiler/support/*)            add 'diff_compiler_*' ;;   # used everywhere — run all

    # ── stdlib / runtime: the extern catalog and every engine's view of it ──
    stdlib/runtime.mdk|runtime/*)
      add 'diff_compiler_capability_matrix'; add 'diff_compiler_eval*'; add 'diff_compiler_test' ;;
    stdlib/*)
      add 'diff_compiler_test'; add 'diff_compiler_snapshot*'
      add 'diff_compiler_lex*' ;;                              # stdlib is IN the snapshot corpus

    # ── a changed gate runs itself ──
    test/diff_compiler_*.sh)
      add "$(basename "$f" .sh)" ;;

    # ── fixture/golden corpus change: run its ACTUAL consumers, not everything.
    # See _gates_for_fixture_dir above. A directory with zero discoverable
    # consumers is a real finding (dead corpus, or a gap in this derivation) —
    # loudly fall back to the full suite rather than silently running nothing.
    test/*fixtures*/*|test/*goldens*/*)
      _fdir="$(_fixture_dir_for "$f")" || _fdir=""
      if [ -z "$_fdir" ]; then
        echo "preflight: WARNING — could not identify a fixture directory for '$f'; falling back to the full diff_compiler_* suite."
        add 'diff_compiler_*'
      else
        _gset="$(_gates_for_fixture_dir "$_fdir")"
        if [ -z "$_gset" ]; then
          echo "preflight: WARNING — '$_fdir' has NO discoverable consumer (checked live references across every test/*.sh and test/wasm/*.sh gate — see _NONGATE for the small infra exclude list — including one hop through any helper script a gate invokes). This is either a DEAD fixture directory or a gap in this derivation — investigate '$_fdir'. Falling back to the full diff_compiler_* suite for safety."
          add 'diff_compiler_*'
        else
          printf 'preflight: %s → %s\n' "$_fdir" "$(printf '%s\n' "$_gset" | xargs -n1 basename | tr '\n' ' ')"
          for _g in $_gset; do
            _pat="${_g#"$ROOT"/test/}"
            add "${_pat%.sh}"
          done
        fi
      fi ;;
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
for f in $changed; do
  case "$f" in
    compiler/*.mdk|compiler/*/*.mdk|stdlib/*.mdk) add 'diff_compiler_snapshot*' ;;
  esac
done

[ -n "$pats" ] || { echo "preflight: no gates map to these changes (docs/config only?) — nothing to run."; exit 0; }

# ── build the compiler ───────────────────────────────────────────────────────
if [ ! -x "$ROOT/medaka_emitter" ]; then
  echo "preflight: no ./medaka_emitter — borrowing one (a fresh worktree cannot cold-bootstrap)"
  for src in /root/medaka/medaka_emitter "$ROOT"/../*/medaka_emitter; do
    [ -x "$src" ] && { cp "$src" "$ROOT/medaka_emitter"; break; }
  done
fi
echo "── building ./medaka ─────────────────────────────────────────"
make -C "$ROOT" medaka >/dev/null 2>&1 || { echo "preflight: make medaka FAILED"; exit 1; }

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
  for g in "$ROOT"/test/$pat.sh; do
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
# 1. The TOTAL must be derived from the same universe `run_gates.sh` uses for
#    its bare-invocation default (`test/diff_compiler_*.sh`), not a hardcoded
#    literal. The gate count has drifted across docs (72/82/83/84 — see
#    AGENTS.md) and WILL drift again; a baked-in number is guaranteed to go
#    stale, and when it does the arithmetic below UNDERFLOWS to a negative
#    "the other -N of 82 gates" the moment ran_count exceeds it (reproduced:
#    a `diff_compiler_*` wildcard match currently pulls in all 83 gates,
#    against a hardcoded 82 → "the other -1 of 82 gates").
# 2. `diff_compiler_engines` is called out here as a standing skip, but a
#    wildcard `add 'diff_compiler_*'` (support/corpus changes) pulls it INTO
#    $gates and it runs above like everything else — printing it here
#    unconditionally then contradicts its own PASS/FAIL line a few lines up.
#    Check whether it actually ran before naming it a skip.
total_gates=$(ls "$ROOT"/test/diff_compiler_*.sh 2>/dev/null | wc -l | tr -d ' ')
ran_count=$(printf '%s\n' $gates | grep -vc '^$')
remaining=$(( total_gates - ran_count ))
if [ "$remaining" -lt 0 ]; then
  # Every gate $gates can contain comes from matching test/diff_compiler_*.sh
  # (the same glob total_gates counts), so ran_count > total_gates should be
  # impossible. Surface it loudly rather than silently clamping and hiding a
  # real bookkeeping bug.
  echo "preflight: INTERNAL INCONSISTENCY — ran_count ($ran_count) exceeds total_gates ($total_gates); the skip-count math below is WRONG. Report this, don't trust the number."
  remaining=0
fi

engines_gate="$ROOT/test/diff_compiler_engines.sh"
case " $gates " in
  *" $engines_gate "*)
    engines_line="  diff_compiler_engines      ran above (pulled in by a wildcard gate match) — not a skip" ;;
  *)
    engines_line="  diff_compiler_engines      the 3-engine differential (346 fixtures × clang)" ;;
esac

cat <<EOF

── NOT RUN LOCALLY (CI runs these on the PR) ─────────────────────
$engines_line
$([ "$need_fixpoint" -eq 1 ] || echo "  selfcompile_fixpoint       (not a backend change)")
  the other $remaining of $total_gates gates

  This preflight is a FILTER, not an authority. A green run here means the gates
  most likely to notice your change did not break — nothing more. Push a branch and
  open a PR; CI runs the full suite on free hosted runners. DO NOT merge on this.
EOF

exit "$rc"
