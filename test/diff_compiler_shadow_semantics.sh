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
# ⚠️ i1/i3/i4/i5 (IMPORTER shadows) MUST NOT MOVE. Fork 1 confines the
# inversion to DEFINER shadows: an `import` is a SIBLING scope, not an inner
# one. Inverting importers would break the everyday `import map` pattern
# (i4: `isEmpty [1,2]` must still reach `Foldable.isEmpty`). During
# development this gate caught exactly that -- inferDefinerShadowApp also
# serves importer shadows on the mangled emit path, via definerShadowArgHead`s
# `routeLocalSym != ""` arm. If any of them moves, the inversion has leaked.
# STOP.
#
# (This warning used to name d11 alongside them, for a DIFFERENT reason -- it
# was the KNOWN-BAD row and had to stay pinned to the bug. #54 fixed the bug
# and d11 moved, deliberately, to REJECT/REJECT/REJECT; the four importer rows
# did NOT, which is the evidence the definer-only split held.)
#
# d10 is the ledger working as designed. It was added by THIS gate as a
# KNOWN-BAD row pinning the S-1 bug (a CONSTRAINED standalone `Num a =>` shadow
# whose RLocal route carried no dictionary -- check green, run E-PANIC, build
# silently printing a garbage heap pointer). PR #25 then FIXED it, and this
# gate went RED on the very next run -- exactly what a ledger entry is for ("it
# must FAIL when the bug is fixed, so it can't rot"). The row is now re-pinned
# to the FIXED behavior: ACCEPT/ACCEPT/ACCEPT, value 4, run == build.
#
# d11 was that ledger row too, and it drained on 2026-07-17 (#54). It pinned
# S-3: a multi-TYPARAM interface (`interface Ix a i`) bypassed the whole
# definer-shadow machinery, because every entry point gated on
# `singleParamIfaceMethod` -- which, despite its name, counts INTERFACE type
# params, not method params. `check`+`build` agreed on the OLD pre-inversion
# per-receiver answer (4 then 3) while `run`, which has no route stamp to
# follow and resolves the bare name lexically, E-PANICked `unknown op '*'` --
# an S7 path-agreement violation. The fix splits that predicate by shadow KIND
# (`ifaceMethodName` for definers -- the S2 inversion never queries the impl
# universe, so typaram arity is irrelevant to it; `singleTyparamIfaceMethod`
# keeps gating the Fork-1 importer arms, whose per-receiver rule DOES key on the
# receiver standing at the interface's one typaram). d11's row went RED on the
# very next run and is now re-pinned to the fixed behavior -- REJECT/REJECT/
# REJECT, the d7 twin at multi-typaram width. THE LEDGER WORKED TWICE (d10, d11).
#
# ###################################################################
# # d21 -- WHAT DRIVING d11's FIX TO ITS EDGES ACTUALLY FOUND       #
# ###################################################################
# d11 pinned the LOUD half. Crossing its axis (typaram arity) with the one this
# gate's own ⭐ rule above names -- receiver PROVENANCE -- found the SILENT half,
# and nothing in the corpus could express it. d21 is d11 with an S5 dict-bound
# receiver (`useIface : Ix a i => a -> i -> Int`). On eedd1482, pre-#54:
#
#     check -> exit 0, reporting `useIface : a -> b -> Int`
#              (the `Ix a i =>` constraint SILENTLY DROPPED from the scheme)
#     run   -> E-PANIC `unknown op '*'`
#     build -> exit 0; the shipped binary printed  69867028434928  then  3
#              -- a RAW HEAP POINTER rendered as an Int, at exit 0
#
# That is the S-1 / P0-20 garbage-pointer shape, live, reachable through the same
# bypass d11 pinned -- and STRICTLY WORSE than d11's panic, because it is silent.
# #54 closes it: all three engines now give the identical located reject. What d21
# pins is the RESIDUAL -- S5's carve-out ("a dict-bound `=>` receiver DISPATCHES")
# is unreachable at multi-typaram width.
#
# ⚠️ THE CAUSE IS IN THE PARSER, NOT IN THE SHADOW MACHINERY -- issue #604. Ty's
# `TyApp Ty Ty` (compiler/frontend/ast.mdk:31) is BINARY, so `Ix a i` parses as
# `TyApp (TyApp (TyCon "Ix") (TyVar "a")) (TyVar "i")`. extractConstraints
# (compiler/frontend/parser.mdk:1678-1682) matches only `TyApp (TyCon iface _) arg`
# -- the ONE-argument shape -- so the outer TyApp's first field, itself a TyApp, hits
# `_ = []`. EVERY >=2-ARGUMENT CONSTRAINT IS SILENTLY DISCARDED (TyConstrained []).
# S5's antecedent ("a dict-bound `=>` constraint variable") is FALSE by the time
# typecheck runs: there is no constraint left to be bound by. definerReceiverIsDictVar
# and constraintTyVars handle multi-arg constraints correctly -- THEY NEVER RECEIVE ONE.
# The engines are conformant to the program they were GIVEN; the program they were
# given is not the one on disk. Proof, with no shadow anywhere in the file:
#
#     $ cat m2.mdk
#     f : NoSuchIface a b => a -> b -> Int     # this interface does NOT exist
#     f x y = 1
#     $ medaka check m2.mdk ; echo $?
#     f : a -> b -> Int
#     0                                        # accepted, exit 0
#     $ medaka check m1.mdk ; echo $?          # the 1-arg control
#     <unknown location>: Unknown interface: NoSuchIface
#     1
#
# A 3-arg constraint drops identically, so the rule is >=2 args, not "exactly 2".
# So d21 is an S5 GAP, not an S7 violation: the three engines agree exactly. It goes
# RED the day #604 lands, which is the signal to RE-PROBE this cell -- ⚠️ NOT to
# assume it becomes ACCEPT/3/6. Whether S5's carve-out then works, or merely surfaces
# a real design question about multi-arg constraint -> dict-slot mapping, is UNKNOWN.
#
# ⭐ THE LESSON, AGAIN: the corpus was blind to this cell for the SAME reason it was
# blind to row 28 -- an unexercised receiver-provenance axis. Twice now, the axis
# named in this file's own warning is where the silent bug was hiding. When you fix
# a shadow cell, CROSS ITS AXIS WITH PROVENANCE BEFORE YOU CALL IT DONE.
#
# Rows pinned to a KNOWN gap: d18 (BUILD_CRASH, #410 residual) and d21 (S5, #54
# residual). A KNOWN-BAD row is not a skip -- it runs and asserts every turn.
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
#     BUILD_CRASH      -- KNOWN-BAD ledger: build exits 0 but the SHIPPED BINARY
#                         crashes (non-zero exit) while run prints `value`
#                         correctly. Pins BOTH the crash and run's value, so the
#                         row self-drains (goes RED) the day the bug is fixed.
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
d11_definer_multityparam_iface.mdk|D11 definer, multi-TYPARAM interface (`interface Ix a i`) now REJECTs its live-impl receiver like every other definer shadow (S2/S8 INVERSION; S-3 FIXED 2026-07-17 #54 -- was the last KNOWN-BAD row: check+build kept the OLD per-receiver answer 4,3 while run E-PANICked `unknown op '*'`, an S7 violation. The definer entry points gated on a typaram COUNT (singleParamIfaceMethod, now split into ifaceMethodName for definers / singleTyparamIfaceMethod for Fork-1 importers), which excused `Ix a i` from the machinery. `get (Box 3) 1` mistypes against the standalone `get : Int -> Int -> Int`; `get 3 1` -> 3. The d7 twin at multi-TYPARAM width)|REJECT|REJECT|REJECT|NONE|
d12_definer_ungrounded_literal.mdk|D12 definer, UNGROUNDED numeric-literal receiver whose grounded head HAS a live prelude impl (S2+S5; the P0-20 cell, now inverted: the standalone wins, 3 not False)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3\n30
i5_importer_ungrounded_literal/main.mdk|I5 importer, UNGROUNDED numeric-literal receiver (S2+S5; regression for S1-RESIDUAL-B, closed 2026-07-14) + the FORK-1 control in the same fixture (isEmpty [1,2] must still reach Foldable)|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|True\nFalse\nFalse\nTrue
i6_importer_value_pos/main.mdk|I6 importer, value position over no-impl elements (S4, matrix row 21a; #411 -- was check+run ACCEPT [2,3,4] but BUILD died `no impl of method size for type Int`, a loud S7 split on a valid program). The importer twin of d4: expected IDENTICAL to row 9|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[2, 3, 4]
i7_importer_value_pos_liveimpl/main.mdk|I7 importer, value position over LIVE-impl elements (S4, matrix row 21b; #411 -- was the SILENT half: check zero diags and run AND build both printed [1, 2], all three engines agreeing on the forbidden answer). The importer twin of d4b: expected IDENTICAL to row 10|REJECT|REJECT|REJECT|NONE|
i8_importer_nway/main.mdk|I8 importer, N-way multi-impl (S3, matrix row 22): per-receiver, UNCHANGED for importer shadows -- the FORK-1 control at N-way width, which must NOT follow row 6`s definer flip to REJECT. Probed conformant while fixing #411|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3\n30\n4
i9_importer_return_pos/main.mdk|I9 importer, RETURN-POSITION method shadow (S4, matrix row 23): `mk : Int -> a` has no receiver param, so the value-position rule gives the standalone. Probed conformant while fixing #411|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4
d13_definer_return_pos.mdk|D13 definer, RETURN-POSITION method shadow (S4, matrix row 23, definer half): the d-twin of I9. Probed conformant while fixing #411|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|4
d17_definer_value_pos_arity_differ.mdk|D17 definer, value position where METHOD arity (2) DIFFERS from STANDALONE arity (1) (S4; S1-RESIDUAL-A, #410). The emitter lift built a 2-arity closure over a 1-arity body, so map got PAPs back and build printed heap pointers as Ints at exit 0 -- SILENT WRONGNESS. Fixed by methValArity (route-derived, not name-derived). D4/D4b are arity-EQUAL, which is why the corpus was blind to this|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[2, 3, 4]
d19_definer_value_pos_arity_differ_zeroimpls.mdk|D19 definer, arity-differ value position with ZERO impls (S2+S4, #410) -- shadow-hood + arity mismatch + value position suffice; the impl universe is irrelevant|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|[2, 3, 4]
d20_definer_value_pos_arity_differ_opposite.mdk|D20 definer, OPPOSITE arity direction to d17: METHOD arity 1 < STANDALONE arity 2 (S4, #410). Pins the other side of the route-derived arity -- the closure must be arity 2 so `f 1 2` is a saturated direct call|ACCEPT|ACCEPT|ACCEPT|ALL_EXACT|3
d21_definer_multityparam_dictvar_receiver.mdk|D21 definer, S5 CARVE-OUT at MULTI-TYPARAM width: a dict-bound `Ix a i =>` receiver does NOT dispatch. ⚠️ THE CAUSE IS IN THE PARSER, NOT THIS MACHINERY (#604): extractConstraints (compiler/frontend/parser.mdk:1678-1682) matches only the ONE-arg shape `TyApp (TyCon iface _) arg`, and TyApp is binary (ast.mdk:31), so `Ix a i` nests and falls to `_ = []` -- EVERY >=2-arg constraint is silently discarded. S5`s antecedent is false because no constraint survives to bind: definerReceiverIsDictVar never receives one. So the occurrence falls to S2 and useIface monomorphises. An S5 GAP, NOT an S7 violation: all three engines agree, and are conformant to the program they were GIVEN. Pre-#54 this file was SILENT WRONGNESS -- check exit 0, run E-PANIC, build exit 0 printing a RAW HEAP POINTER. Goes RED the day #604 lands (or S5 is honoured here)|REJECT|REJECT|REJECT|NONE|
d18_definer_value_pos_arity_differ_unannot.mdk|D18 KNOWN-BAD: d17 WITHOUT the List Int annotation (#410 headline repro). println`s Display requirement gets a NULL element dict (RNone route) so the shipped binary SEGFAULTs while run is correct. The element TYPE resolves to Int -- this is the requirement ROUTE, stamped in types/typecheck.mdk, NOT an emitter bug|ACCEPT|ACCEPT|ACCEPT|BUILD_CRASH|[2, 3, 4]'

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
    bin_code=$?
  else
    build_v='REJECT'
    : >"$TMP/$base.build.out"
    bin_code=0
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
    BUILD_CRASH)
      # KNOWN-BAD ledger cell, NOT a skip: `build` exits 0 and ships a binary
      # that CRASHES (non-zero exit), while `run` prints the correct `value`.
      # Asserting BOTH halves is what makes this self-draining: the day the
      # underlying bug is fixed the binary stops crashing, this row goes RED,
      # and whoever fixed it MUST come here and re-pin the cell to ALL_EXACT.
      # A `NONE` row would have silently absorbed the fix and taught nobody.
      if [ "$build_v" = 'ACCEPT' ]; then
        printf '%b\n' "$value" > "$TMP/$base.expected"
        if [ "$bin_code" -eq 0 ]; then
          value_v='NO-CRASH-FIXED'   # <-- the drain fired: re-pin this row
          row_ok=0
        elif cmp -s "$TMP/$base.run.out" "$TMP/$base.expected"; then
          value_v="ok(crash:$bin_code)"
        else
          value_v='RUN-DIFF'
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
