#!/bin/sh
# Equivalence gate for the bytecode VM (STAGE2-DESIGN §2.2, SLICES 1–3).
#
# Same shape + same oracle as diff_selfhost_core_ir.sh: there is no bespoke
# reference for the bytecode path — it is validated by EQUIVALENCE against the AST
# tree-walker.  selfhost/eval_bytecode_main.mdk parses → desugars → annotates →
# lowers to Core IR → COMPILES to bytecode → runs the stack VM → prints pp_value
# of `main`; we diff that, byte-for-byte, against dev/eval_probe.exe (the SAME
# oracle eval_main.mdk / core_ir_main.mdk use).  The VM is correct iff running the
# compiled bytecode matches evaluating the AST.
#
# SLICE 1 — arithmetic + variables (slot-indexed) + application, plus the trivial
# non-pattern/non-closure nodes needed to form a runnable whole program (literals,
# primitive binops/unops, tuples, lists, `if`, let-sequencing blocks).  Closure
# values, multi-clause dispatch and pattern-param binding are delegated to the
# reused host runtime (VClosureF + applyValue), exactly as core_ir_eval.mdk does.
#
# SLICE 2 — match via compiled decision trees: IMatchArms (ordered-arm CMatch
# dispatch, for PRng/PRec and other non-tree-able arms) and IMatchDecision
# (decision-tree CDecision dispatch, for constructor/literal/as/tuple arms), plus
# IBindFail for CSLetElse.  Bodies and guards compiled to Chunk at install time;
# guard fall-through for CTGuard leaves (PRng/PRec) preserved exactly.
#
# SLICE 3 — ADTs / records / refs: IMakeArray, IMakeRecord, IField, IFieldValue,
# IRecordUpdate, IRangeList, IRangeArray, IIndex, ISlice, plus CSAssign in blocks.
# Value-level work (evalRecordUpdate / evalField / evalRange / evalIndex / …)
# reused verbatim from eval.mdk — step functions only route opcodes.
#
# DEFERRED — closures (lambda/sections/compose/letrec/where) and typeclass dispatch
# are slices 4–5; a fixture needing one is listed in DEFERRED below with the slice
# that will cover it.  The compiler panics on unsupported nodes so no silent mis-run.
#
# Usage:  sh test/diff_selfhost_eval_bytecode.sh
# Exit:   0 if every active fixture matches the tree-walker.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/_build/default/dev/eval_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
SELFMAIN="$ROOT/selfhost/eval_bytecode_main.mdk"
FIXDIR="$ROOT/test/eval_fixtures"

[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }

# slice 1 — engine primitives (no match / no records / no closures)
SLICE1="adt_nested letrec_mutual list_ops string_kernel"

# slice 2 — match expressions: CMatch (ordered arms) + CDecision (decision trees)
SLICE2="patterns_misc range_pat_tree"

# slice 3 — arrays, records, refs, ranges, index/slice
# (rec_pat_tree and string_ranges_infix also need slice 2 — promoted together)
SLICE3="arrays_ranges records refs_mut"

# slices 2+3 combined — fixtures that require both match and records/arrays/index
SLICE23="string_ranges_infix rec_pat_tree"

ACTIVE="$SLICE1 $SLICE2 $SLICE3 $SLICE23"

# still deferred — closures + letrec/where (slice 4) and typeclass dispatch (slice 5)
DEFERRED="\
dispatch_basic:slice5-typeclass-dispatch \
dispatch_default:slice5-typeclass-dispatch \
dispatch_multi:slice5-typeclass-dispatch \
guarded_clauses:slice4-where(letgroup)+pattern-bind-guards \
guards_where:slice4-where(letgroup) \
hof_compose:slice4-closures(lambda/sections/compose) \
shadow_closure:slice4-closures+let-in"

pass=0; fail=0
for name in $ACTIVE; do
  f="$FIXDIR/$name.mdk"
  [ -f "$f" ] || { printf 'FAIL %s (missing fixture)\n' "$name"; fail=$((fail+1)); continue; }
  ref="$("$PROBE" "$f" 2>/dev/null)"
  self="$("$MAIN" run "$SELFMAIN" "$f" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n-- deferred to later slices --\n'
for entry in $DEFERRED; do
  printf 'defer %s\n' "$entry"
done

printf '\n%d ok, %d failing (slices 1–3); %d deferred\n' \
  "$pass" "$fail" "$(printf '%s\n' $DEFERRED | wc -w | tr -d ' ')"
[ "$fail" -eq 0 ]
