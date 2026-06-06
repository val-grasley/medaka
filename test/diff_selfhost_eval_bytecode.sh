#!/bin/sh
# Equivalence gate for the bytecode VM (STAGE2-DESIGN §2.2, SLICE 1).
#
# Same shape + same oracle as diff_selfhost_core_ir.sh: there is no bespoke
# reference for the bytecode path — it is validated by EQUIVALENCE against the AST
# tree-walker.  selfhost/eval_bytecode_main.mdk parses → desugars → annotates →
# lowers to Core IR → COMPILES to bytecode → runs the stack VM → prints pp_value
# of `main`; we diff that, byte-for-byte, against dev/eval_probe.exe (the SAME
# oracle eval_main.mdk / core_ir_main.mdk use).  The VM is correct iff running the
# compiled bytecode matches evaluating the AST.
#
# SCOPE — slice 1 only: "arithmetic + variables (slot-indexed) + application",
# plus the trivial non-pattern/non-closure nodes needed to form a runnable whole
# program (literals, primitive binops/unops, tuples, lists, `if`, let-sequencing
# blocks).  Closure values, multi-clause dispatch and pattern-param binding are
# delegated to the reused host runtime (VClosureF + applyValue), exactly as
# core_ir_eval.mdk does — the VM itself only compiles + runs EXPRESSION bodies.
#
# Later slices (compiling these CONSTRUCTS to their own opcodes) are out of scope
# here; a fixture that needs one is listed in DEFERRED below with the slice that
# will cover it.  The compiler panics on the unsupported node, so a deferred
# fixture cannot silently mis-run.
#
# Usage:  sh test/diff_selfhost_eval_bytecode.sh
# Exit:   0 if every slice-1 fixture matches the tree-walker.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/_build/default/dev/eval_probe.exe"
MAIN="$ROOT/_build/default/bin/main.exe"
SELFMAIN="$ROOT/selfhost/eval_bytecode_main.mdk"
FIXDIR="$ROOT/test/eval_fixtures"

[ -x "$PROBE" ] || { echo "build first: dune build --root . (missing $PROBE)"; exit 2; }

# fixtures whose lowered bodies use only slice-1 expression nodes.
SLICE1="adt_nested letrec_mutual list_ops string_kernel"

# the rest of test/eval_fixtures/, with the slice that will cover each.
DEFERRED="\
arrays_ranges:slice3-arrays/ranges/index/slice \
dispatch_basic:slice5-typeclass-dispatch \
dispatch_default:slice5-typeclass-dispatch \
dispatch_multi:slice5-typeclass-dispatch \
guarded_clauses:slice4-where(letgroup)+pattern-bind-guards \
guards_where:slice4-where(letgroup) \
hof_compose:slice4-closures(lambda/sections/compose) \
patterns_misc:slice2-match-expression \
records:slice3-records \
refs_mut:slice3-refs/let-mut/blocks \
shadow_closure:slice4-closures+let-in \
string_ranges_infix:slice2-match+slice3-string-index/slice"

pass=0; fail=0
for name in $SLICE1; do
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

printf '\n%d ok, %d failing (slice 1); %d deferred\n' \
  "$pass" "$fail" "$(printf '%s\n' $DEFERRED | wc -w | tr -d ' ')"
[ "$fail" -eq 0 ]
