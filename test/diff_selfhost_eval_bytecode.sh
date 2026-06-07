#!/bin/sh
# Equivalence gate for the bytecode VM (STAGE2-DESIGN §2.2, SLICES 1–5).
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
# SLICE 4 — closures / letrec / where-blocks: IMakeClosure (CLam → VClosureF),
# ILetBound (non-rec let-in), ILetRec (recursive let with cell back-patch),
# ILetGroup (where-block / mutual-rec local group — eager nullary, VClosureF for
# parameterised, VMulti for multi-clause, mirroring cevalLetGroup/cGroupValue).
#
# SLICE 5 — typeclass dispatch from elaborated routes: IMethod (CMethod — return-
# position dispatch via RKey/RDict, using narrowMethod/routeTag), IDict (CDict —
# constrained-fn dict application via applyDicts).  bcEvalProgram now installs
# typeclass impls (coalesceImpls → VMulti) before user groups.
#
# SLICE 6 (multi-module per-module frames) remains deferred.
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

# slice 4 — closures, letrec, where-blocks (IMakeClosure/ILetBound/ILetRec/ILetGroup)
# effect_poly: an effect-polymorphic combinator (HOF + Ref) — its <e> row erases
# to nothing, so the VM runs it identically to the tree-walker (STAGE2-DESIGN §2.3).
SLICE4="hof_compose shadow_closure guards_where guarded_clauses effect_poly"

# slice 5 — typeclass dispatch (IMethod/IDict + impl install)
SLICE5="dispatch_basic dispatch_default dispatch_multi"

ACTIVE="$SLICE1 $SLICE2 $SLICE3 $SLICE23 $SLICE4 $SLICE5"

# slice 6 (multi-module per-module frames) still deferred
DEFERRED=""

pass=0; fail=0
for name in $ACTIVE; do
  f="$FIXDIR/$name.mdk"
  [ -f "$f" ] || { printf 'FAIL %s (missing fixture)\n' "$name"; fail=$((fail+1)); continue; }
  ref="$("$PROBE" "$f" 2>/dev/null)"
  self="$("$MAIN" run "$SELFMAIN" "$f" 2>/dev/null)"
  if [ "$ref" = "$self" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n  ref : %s\n  self: %s\n' "$name" "$ref" "$self"; fi
done

printf '\n%d ok, %d failing (slices 1–5); 0 deferred\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
