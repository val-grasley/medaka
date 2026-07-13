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

changed="$(git diff --name-only "$BASE"...HEAD 2>/dev/null; git diff --name-only 2>/dev/null; git ls-files -o --exclude-standard 2>/dev/null)"
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

need_fixpoint=0
for f in $changed; do
  case "$f" in
    # ── front-end: everything downstream of it is suspect ──
    compiler/frontend/lexer.mdk)
      add 'diff_compiler_lex*'; add 'diff_compiler_comments'; add 'diff_compiler_positions'
      add 'diff_compiler_parse*'; add 'diff_compiler_desugar*'; add 'diff_compiler_mark*' ;;
    compiler/frontend/parser.mdk|compiler/frontend/ast.mdk)
      add 'diff_compiler_parse*'; add 'diff_compiler_printer'; add 'diff_compiler_positions'
      add 'diff_compiler_desugar*'; add 'diff_compiler_mark*'; add 'diff_compiler_fmt' ;;
    compiler/frontend/desugar.mdk)
      add 'diff_compiler_desugar*'; add 'diff_compiler_mark*'; add 'diff_compiler_eval*' ;;
    compiler/frontend/resolve.mdk|compiler/frontend/marker.mdk)
      add 'diff_compiler_resolve*'; add 'diff_compiler_mark*'; add 'diff_compiler_check*' ;;
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
    compiler/tools/repl.mdk)       add 'diff_compiler_repl' ;;
    compiler/tools/*test*|compiler/tools/doctest.mdk|compiler/tools/prop_runner.mdk)
      add 'diff_compiler_test'; add 'diff_compiler_ported' ;;
    compiler/tools/*)              add 'diff_compiler_check*' ;;
    compiler/support/*)            add 'diff_compiler_*' ;;   # used everywhere — run all

    # ── stdlib / runtime: the extern catalog and every engine's view of it ──
    stdlib/runtime.mdk|runtime/*)
      add 'diff_compiler_capability_matrix'; add 'diff_compiler_eval*'; add 'diff_compiler_test' ;;
    stdlib/*)
      add 'diff_compiler_test'; add 'diff_compiler_desugar*'; add 'diff_compiler_mark*'
      add 'diff_compiler_lex*' ;;                              # stdlib carries golden siblings

    # ── a changed gate runs itself ──
    test/diff_compiler_*.sh)
      add "$(basename "$f" .sh)" ;;
    test/*fixtures*/*|test/*goldens*/*)
      add 'diff_compiler_*' ;;                                 # corpus change: run everything
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
gates=""
for pat in $pats; do
  for g in "$ROOT"/test/$pat.sh; do
    [ -f "$g" ] || continue
    case " $gates " in *" $g "*) ;; *) gates="$gates $g" ;; esac
  done
done

oracles=""
for g in $gates; do
  for o in $(grep -ohE 'test/bin/[a-z_0-9]+' "$g" 2>/dev/null | sed 's|test/bin/||' | sort -u); do
    case " $oracles " in *" $o "*) ;; *) oracles="$oracles $o" ;; esac
  done
done

n_o=$(printf '%s\n' $oracles | grep -vc '^$' 2>/dev/null || echo 0)
echo "── building %s of 54 oracles (only what these gates read) ─────" >/dev/null
printf '── building %s of 54 oracles (only what these gates read) ─────\n' "$n_o"
for o in $oracles; do
  printf '  %s\n' "$o"
  FORCE=1 JOBS=1 sh "$ROOT/test/build_oracles.sh" --build-one "$o" >/dev/null 2>&1 \
    || { echo "preflight: oracle build FAILED: $o"; exit 1; }
done

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
cat <<EOF

── NOT RUN LOCALLY (CI runs these on the PR) ─────────────────────
  diff_compiler_engines      the 3-engine differential (346 fixtures × clang)
$([ "$need_fixpoint" -eq 1 ] || echo "  selfcompile_fixpoint       (not a backend change)")
  the other $(( 82 - $(printf '%s\n' $gates | grep -vc '^$') )) of 82 gates

  This preflight is a FILTER, not an authority. A green run here means the gates
  most likely to notice your change did not break — nothing more. Push a branch and
  open a PR; CI runs the full suite on free hosted runners. DO NOT merge on this.
EOF

exit "$rc"
