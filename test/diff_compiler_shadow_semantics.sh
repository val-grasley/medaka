#!/bin/sh
# SHADOW-SEMANTICS decision-matrix gate (docs/spec/SHADOW-SEMANTICS.md).
#
# test/shadow_fixtures/ is the enforcement corpus for that spec -- one fixture
# per matrix cell -- and until this gate existed NOTHING ran it (audit finding,
# 2026-07-13: 5 orphaned fixture directories tree-wide; this was the worst,
# because it is a SPEC's enforcement, not just a regression corpus). A design
# agent needing to know what a cell actually does had to drive every fixture by
# hand. See test/diff_compiler_run_check_agreement.sh for the general shape
# this gate follows (check/run/build agreement, exit-code AND value).
#
# ⚠️ THIS GATE PINS WHAT THE BINARY ACTUALLY DOES ON CURRENT MAIN, NOT WHAT THE
# SPEC SAYS SHOULD HAPPEN. Per clause S7, `run`/`check`/`build` are specified to
# agree on every cell, so this gate checks all three -- exit-code verdict AND,
# for cells where run+build both accept, that they print the SAME, PINNED
# value (a P0-20-shaped bug -- build exits 0 printing a WRONG number -- is
# invisible to an exit-code-only gate; see that gate's own history).
#
# As of this writing (main past PR #25/#26/#27, binary rebuilt from THAT tree),
# every matrix cell that ships a fixture in test/shadow_fixtures/ is CONFORMANT
# -- check/run/build agree with each other AND with the doc's S1-S9-specified
# outcome -- EXCEPT d11 (below). That includes rows 10/12/13/14 (d4b/d5b/d9/d8),
# whose STATUS column in the doc's section-2 table used to say BUG: that column
# was STALE (P0-19 2026-07-10 + P0-20 2026-07-13 closed all four, as the doc's
# OWN section-5 update notes said a few paragraphs below the stale table). This
# gate's empirical run is what proved it, and the table has now been corrected
# to match -- with this gate cited as the enforcement.
#
# ###################################################################
# # 2026-07-14 -- THE S2 INVERSION. FIVE ROWS FLIPPED ACCEPT->REJECT #
# ###################################################################
# A top-level standalone now WINS over a same-named interface method inside the
# module that DEFINES it (compiler/SHADOW-INVERSION-DESIGN.md; docs/spec/
# SHADOW-SEMANTICS.md S2). The impl universe is no longer consulted for a
# DEFINER shadow. The bug it fixes: a user`s
#
#     eq : List Int -> List Int -> Bool
#     eq a b = True
#     main = println (debug (eq [1] [2]))      -- printed False. SILENTLY.
#
# was ERASED by the prelude`s `impl Eq List` -- on check AND run AND build, so
# by S7 (they all agree) NO differential gate could see it, BY CONSTRUCTION.
# That is exactly why this gate pins VALUES, and it is the only gate that could
# have caught the fix landing wrong.
#
# The five rows re-pinned, each ACCEPT -> located REJECT (`Type mismatch: Int
# vs <receiver>` at the call site, on all three paths):
#   d2 -- live-impl receiver                    (S2)
#   d3 -- N-way: S3 is now VACUOUS for a definer shadow
#   d6 -- live impl at a PARAMETRIC head        (S2)
#   d7 -- two-param method                      (S8)
#   d8 -- iface+impl IMPORTED                   (S6)
# Nothing that REJECTed became an ACCEPT: the change is monotonically MORE
# rejecting for definer shadows, which is what makes it safe to land.
#
# ⚠️ d8 DELIBERATELY REVERTS ebb8ee90 (P0-19 batch 2, row 14), which was two
# days old and made a definer shadow dispatch to a cross-module impl. That fix
# faithfully implemented the OLD S2; the inversion abolishes the rule it
# implemented. This is NOT a regression -- see the row`s label.
#
# ###################################################################
# # THE CORPUS WAS STRUCTURALLY BLIND TO THE UNGROUNDED RECEIVER    #
# ###################################################################
# d12 and i5 (added 2026-07-14) close a hole that let this gate grade 18/0 over a
# REAL BREAK. Every importer fixture -- i1, i3, i4 -- uses a GROUNDED receiver (a
# Box, a Tok, a List). Not one used a bare numeric literal. But a numeric literal
# is `Num a => a`: it is UNGROUNDED at inference time and only unifies to Int
# LATER. So the routing decision is taken on a receiver that HAS NO HEAD TYCON
# YET, and the type is then resolved against a receiver that has SINCE CHANGED.
#
# That shape -- ONE DECISION, DERIVED TWICE, AT TWO DIFFERENT TIMES, OVER A VALUE
# THAT CHANGED IN BETWEEN -- is the recurring root cause of this whole arc (P0-20;
# .claude/workstreams/COMPILER-SOUNDNESS.md). It bit `inferShadowApp` exactly as
# S1-RESIDUAL-B predicted it would, and the symptom was a *higher-kinded* unify
# accident: the prelude's `Foldable.isEmpty : t a -> Bool` swallowed the literal as
# `t := Int, a := Int`, giving the tell-tale `Type mismatch: Int literal vs Int Int`.
#
# ⭐ A GATE THAT CANNOT EXPRESS A CELL CANNOT DEFEND IT. When adding a shadow
# fixture, vary the receiver's PROVENANCE (literal / grounded / dict-bound), not
# just its type -- that axis is where every silent bug in this arc has lived.
#
# ⚠️ i1/i3/i4/i5 (IMPORTER shadows) and d11 MUST NOT MOVE. Fork 1 confines the
# inversion to DEFINER shadows: an `import` is a SIBLING scope, not an inner
# one. Inverting importers would break the everyday `import map` pattern
# (i4: `isEmpty [1,2]` must still reach `Foldable.isEmpty`). During
# development this gate caught exactly that -- inferDefinerShadowApp also
# serves importer shadows on the mangled emit path, via definerShadowArgHead`s
# `routeLocalSym != ""` arm -- and it caught d11 moving when the route stamp
# skipped the singleParamIfaceMethod gate that every typing entry point
# applies. If either moves again, the inversion has leaked. STOP.
#
# d10 is the ledger working as designed. It was added by THIS gate as a
# KNOWN-BAD row pinning the S-1 bug (a CONSTRAINED standalone `Num a =>` shadow
# whose RLocal route carried no dictionary -- check green, run E-PANIC, build
# silently printing a garbage heap pointer). PR #25 then FIXED it, and this
# gate went RED on the very next run -- exactly what a ledger entry is for ("it
# must FAIL when the bug is fixed, so it can't rot"). The row is now re-pinned
# to the FIXED behavior: ACCEPT/ACCEPT/ACCEPT, value 4, run == build.
#
# d11_definer_multityparam_iface.mdk remains the one KNOWN-BAD row: a
# multi-TYPARAM interface (`interface Ix a i`) bypasses the whole
# definer-shadow machinery, because every entry point gates on
# `singleParamIfaceMethod`, which counts INTERFACE type params, not method
# params. `check` and `build` agree (and are in fact per-receiver CORRECT,
# printing 4 then 3) while `run` E-PANICs (`unknown op '*'`) -- an S7
# path-agreement violation. No fix is in flight (doc section 5, residual #2 /
# "S-3"). Its row is pinned to that CURRENT split; it goes red the day `run`
# is taught this shape, which is the signal to correct the row, not silence
# it. A KNOWN-BAD row is not a skip -- it runs and asserts every turn.
#
# Untested-per-the-doc (rows 21-23: importer value-position / importer N-way /
# return-position method shadow) ship NO fixture in test/shadow_fixtures/ and
# are out of scope here -- adding fixtures for them is follow-up work, not a
# silent gap in THIS gate (this gate covers 100% of what test/shadow_fixtures/
# actually contains, checked by the coverage self-audit below, which fails
# loudly the moment a new fixture is dropped into the directory without being
# wired into the TABLE).
#
# Usage:  sh test/diff_compiler_shadow_semantics.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/shadow_fixtures"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }
[ -d "$FIXDIR" ] || { echo "missing fixture dir: $FIXDIR"; exit 2; }

bound() { perl -e 'alarm 60; exec @ARGV' "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; asserts=0

# Table: entry-path (relative to FIXDIR) | label | exp_check | exp_run | exp_build | mode | value
#   exp_* in {ACCEPT, REJECT} -- ACCEPT means exit 0, REJECT means nonzero exit.
#   mode in:
#     NONE             -- no stdout assertion (all three REJECT; nothing ran)
#     ALL_EXACT        -- run and build both ACCEPT: their stdouts, AND the
#                         pinned `value`, must all be byte-identical (S7 value
#                         agreement + ground-truth pin, P0-20 shape)
#     BUILD_EXACT      -- only build's stdout is asserted against `value`
#                         (used when run is expected to REJECT but build is
#                         expected to ACCEPT with a specific, deterministic
#                         value -- a check/build-agree-run-diverges split)
#     BUILD_NOTEQ_INT  -- build's stdout must be a bare integer (digits only)
#                         that is NOT equal to `value` (used for a
#                         non-deterministic garbage-pointer miscompile, where
#                         the wrong value differs run to run but is always
#                         "some integer, not the right one")
#   `value` uses literal backslash-n for embedded newlines (expanded via
#   `printf '%b'`); empty for mode NONE.
TABLE='d1b_definer_noimpl_zeroimpls.mdk|D1b definer, iface has ZERO impls (S2)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4
d1_definer_noimpl.mdk|D1 definer, no-impl receiver, impl exists elsewhere (S2)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4
d2_definer_liveimpl.mdk|D2 definer, live-impl receiver is now a located REJECT (S2 INVERSION: `size (Box 3)` no longer dispatches -- the module`s own `size : Int -> Int` wins, so Box mistypes)|REJECT|REJECT|REJECT|NONE|
d3_definer_nway.mdk|D3 definer, N-way: every live-impl receiver REJECTs (S3 INVERSION: S3 is vacuous for a definer shadow -- no receiver selects an impl; only `size 3` survives)|REJECT|REJECT|REJECT|NONE|
d4_definer_value_pos.mdk|D4 definer, value position over no-impl elements (S4)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[2, 3, 4]
d4b_definer_value_pos_liveimpl.mdk|D4b definer, value position over LIVE-impl elements (S4)|REJECT|REJECT|REJECT|NONE|
d5_definer_poly_receiver.mdk|D5 definer, ungrounded receiver monomorphises to standalone (S5)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4
d5b_definer_poly_liveimpl_call.mdk|D5b definer, poly wrapper CALLED at live-impl type (S5)|REJECT|REJECT|REJECT|NONE|
d6_definer_parametric_receiver.mdk|D6 definer, live impl at a PARAMETRIC head is now a located REJECT (S2 INVERSION: `impl Sizeable (P a)` no longer steals `size (P True)`)|REJECT|REJECT|REJECT|NONE|
d7_definer_multiparam_method.mdk|D7 definer, two-param method shadow now REJECTs its live-impl receiver (S8 INVERSION: `comb (Box 1) (Box 2)` types against the standalone `comb : Int -> Int -> Int`)|REJECT|REJECT|REJECT|NONE|
d9_definer_reject.mdk|D9 definer, no-impl receiver + standalone domain mismatch (S2)|REJECT|REJECT|REJECT|NONE|
d8_definer_imported_impl/main.mdk|D8 definer, IMPORTED iface+impl now REJECTs too (S6 INVERSION -- deliberately REVERTS the P0-19-batch-2 row-14 fix ebb8ee90, which made this dispatch cross-module: S6 is now trivial because the impl universe is never queried for a definer shadow, so WHERE the impl lives cannot change the outcome)|REJECT|REJECT|REJECT|NONE|
i1_importer_local_iface/main.mdk|I1/I2 importer shadow, LOCAL interface (S2/S6)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3\n4
i3_importer_imported_iface/main.mdk|I3 importer shadow, iface+impl in a THIRD module (S6)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3\n4
i4_importer_prelude_iface/main.mdk|I4 importer shadow of a PRELUDE method (S2, stdlib shape)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|True\nFalse\nFalse\nTrue
d10_definer_constrained.mdk|D10 definer, CONSTRAINED standalone dict-passed via RLocal (S9, was the S-1 bug)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4
d11_definer_multityparam_iface.mdk|D11 KNOWN-BAD: multi-typaram interface bypasses shadow machinery (S-3, doc residual)|ACCEPT|REJECT|ACCEPT|BUILD_EXACT|4\n3
d12_definer_ungrounded_literal.mdk|D12 definer, UNGROUNDED numeric-literal receiver whose grounded head HAS a live prelude impl (S2+S5; the P0-20 cell, now inverted: the standalone wins, 3 not False)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3\n30
i5_importer_ungrounded_literal/main.mdk|I5 importer, UNGROUNDED numeric-literal receiver (S2+S5; regression for S1-RESIDUAL-B, closed 2026-07-14) + the FORK-1 control in the same fixture (isEmpty [1,2] must still reach Foldable)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|True\nFalse\nFalse\nTrue'

# --- Coverage self-audit: every top-level fixture unit (a .mdk file, or a
# directory) in FIXDIR must appear in TABLE, or this gate silently re-creates
# the exact orphan-corpus problem it exists to close. ---
listed="$(printf '%s\n' "$TABLE" | awk -F'|' 'NF>1{print $1}' | sed 's#/main\.mdk$##' | sort -u)"
actual="$(cd "$FIXDIR" && for e in *; do
            if [ -d "$e" ] || { [ -f "$e" ] && [ "${e%.mdk}" != "$e" ]; }; then
              echo "$e"
            fi
          done | sort -u)"

uncovered=0
for a in $actual; do
  hit=0
  for l in $listed; do
    [ "$a" = "$l" ] && hit=1 && break
  done
  if [ "$hit" -eq 0 ]; then
    uncovered=$((uncovered+1))
    fail=$((fail+1))
    printf 'FAIL coverage: %s exists in %s but is NOT wired into this gate'"'"'s TABLE\n' "$a" "$FIXDIR"
  fi
done
asserts=$((asserts+1))
if [ "$uncovered" -eq 0 ]; then
  pass=$((pass+1))
  printf 'ok   coverage: every fixture in %s is wired into this gate (%d units)\n' "$FIXDIR" "$(printf '%s\n' "$actual" | grep -c .)"
fi
echo

printf '%-70s %-6s %-6s %-6s %-11s %s\n' 'fixture' 'check' 'run' 'build' 'value' 'result'
printf '%-70s %-6s %-6s %-6s %-11s %s\n' '----------------------------------------------------------------------' '------' '------' '------' '-----------' '------'

printf '%s\n' "$TABLE" | while IFS='|' read -r entry label exp_check exp_run exp_build mode value; do
  [ -z "$entry" ] && continue
  entrypath="$FIXDIR/$entry"
  base="$(printf '%s' "$entry" | sed 's#/main\.mdk$##' | tr '/' '_')"

  if [ ! -f "$entrypath" ]; then
    printf '%-70s %s\n' "$entry" 'FAIL MISSING FIXTURE FILE'
    echo "FAIL" >> "$TMP/verdicts"
    continue
  fi

  bound "$MEDAKA" check "$entrypath" >/dev/null 2>"$TMP/$base.chk.err"
  check_code=$?
  bound "$MEDAKA" run "$entrypath" >"$TMP/$base.run.out" 2>"$TMP/$base.run.err"
  run_code=$?
  bound "$MEDAKA" build "$entrypath" -o "$TMP/$base.bin" >"$TMP/$base.build.err" 2>&1
  build_code=$?

  if [ "$check_code" -eq 0 ]; then check_v='ACCEPT'; else check_v='REJECT'; fi
  if [ "$run_code" -eq 0 ]; then run_v='ACCEPT'; else run_v='REJECT'; fi
  if [ "$build_code" -eq 0 ] && [ -x "$TMP/$base.bin" ]; then
    build_v='ACCEPT'
    bound "$TMP/$base.bin" >"$TMP/$base.build.out" 2>"$TMP/$base.build.runerr"
  else
    build_v='REJECT'
    : >"$TMP/$base.build.out"
  fi

  row_ok=1
  [ "$check_v" = "$exp_check" ] || row_ok=0
  [ "$run_v" = "$exp_run" ] || row_ok=0
  [ "$build_v" = "$exp_build" ] || row_ok=0

  value_v='-'
  case "$mode" in
    NONE) ;;
    ALL_EXACT)
      if [ "$run_v" = 'ACCEPT' ] && [ "$build_v" = 'ACCEPT' ]; then
        printf '%b\n' "$value" > "$TMP/$base.expected"
        if cmp -s "$TMP/$base.run.out" "$TMP/$base.build.out" && cmp -s "$TMP/$base.run.out" "$TMP/$base.expected"; then
          value_v='ok'
        else
          value_v='DIFF'
          row_ok=0
        fi
      else
        value_v='n/a'
      fi
      ;;
    BUILD_EXACT)
      if [ "$build_v" = 'ACCEPT' ]; then
        printf '%b\n' "$value" > "$TMP/$base.expected"
        if cmp -s "$TMP/$base.build.out" "$TMP/$base.expected"; then
          value_v='ok'
        else
          value_v='WRONG'
          row_ok=0
        fi
      else
        value_v='n/a'
      fi
      ;;
    BUILD_NOTEQ_INT)
      if [ "$build_v" = 'ACCEPT' ]; then
        got="$(tr -d '[:space:]' < "$TMP/$base.build.out")"
        case "$got" in
          ''|*[!0-9]*)
            value_v='NOTINT'
            row_ok=0
            ;;
          "$value")
            value_v='EQ-WANT-NE'
            row_ok=0
            ;;
          *)
            value_v='ok(garbage)'
            ;;
        esac
      else
        value_v='n/a'
      fi
      ;;
  esac

  if [ "$row_ok" -eq 1 ]; then
    result='PASS'
    echo "PASS" >> "$TMP/verdicts"
  else
    result='FAIL'
    echo "FAIL" >> "$TMP/verdicts"
  fi
  printf '%-70s %-6s %-6s %-6s %-11s %s\n' "$entry" "$check_v" "$run_v" "$build_v" "$value_v" "$result"
done

# The `printf | while read` above runs in dash/ash as a subshell of the
# pipeline (POSIX allows this; dash actually does fork the last stage of a
# pipe), so pass/fail/asserts mutated INSIDE that loop would NOT survive to
# here. We therefore tally the real per-row verdicts from $TMP/verdicts
# (written from inside the loop, which DOES survive since it's a file, not a
# shell variable) rather than trusting variables mutated in the subshell.
if [ -f "$TMP/verdicts" ]; then
  row_pass="$(grep -c '^PASS$' "$TMP/verdicts")"
  row_fail="$(grep -c '^FAIL$' "$TMP/verdicts")"
else
  row_pass=0
  row_fail=0
fi
pass=$((pass+row_pass))
fail=$((fail+row_fail))
asserts=$((asserts+row_pass+row_fail))

echo
printf '%s: %d passed, %d failed (%d assertions)\n' "$(basename "$0")" "$pass" "$fail" "$asserts"
[ "$fail" -eq 0 ]
