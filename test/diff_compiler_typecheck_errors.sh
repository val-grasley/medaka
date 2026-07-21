#!/bin/sh
# Differential validation for self-hosted TYPE ERROR accumulation.
#
# OCaml-free (REROOT-PLAN §2b): the self-hosted drivers run as native binaries
# and are diffed against a committed golden.  Both sides sorted (order irrelevant
# for the single-error fixtures).
#
# Two drivers tested:
#   A. test/bin/typecheck_main  — bare HM engine, NO prelude
#   B. test/bin/check_main      — full composed front-end WITH prelude
#
# GATE RE-ROOTING (feature #11 — Num-polymorphic literals).  #11 desugars an
# integer literal `1` → `fromInt 1`.  A no-prelude driver (A) cannot resolve
# `fromInt`/`Num`, so for fixtures whose *documented* error depends on the prelude
# (`No impl of Num for …` from a numeric literal at a non-Num type) Driver A
# structurally cannot produce the right answer — it wrongly ACCEPTS and prints
# schemes.  Only the prelude-aware Driver B yields the semantically-correct error
# (verified == the OCaml oracle `main.exe check` / `dev/tc_module_probe.exe`).
#
# Mechanism: PRELUDE_DEP lists, by basename, the prelude-dependent fixtures.  For
# those we run ONLY Driver B and the golden is captured from the prelude-aware
# OCaml probe (dev/tc_module_probe.exe) by test/capture_goldens.sh.  All OTHER
# fixtures keep BOTH drivers + a no-prelude golden, unchanged.  (Capture may use
# OCaml by design; the gate stays OCaml-free at RUN time.)
PRELUDE_DEP="int_vs_string.mdk value_restriction.mdk missing_super_impl.mdk cyclic_superinterface.mdk ambiguous_impl.mdk ambiguous_return_nested.mdk ambiguous_return_noconstraint.mdk do_bind_annot_mismatch.mdk nested_requires_function_key.mdk semigroup_no_impl.mdk negate_no_impl.mdk nonlinear_head_inconsistent.mdk effect_impl_launder_cb.mdk effect_impl_launder_ghost.mdk effect_impl_launder_mixed.mdk effect_impl_launder_retlam.mdk impl_pins_method_tyvar.mdk impl_pins_method_tyvar_num.mdk impl_pins_method_tyvar_tuple.mdk impl_collapses_method_tyvars.mdk impl_effvar_offspine_launder.mdk impl_default_pins_method_tyvar.mdk impl_method_constraint_ok.mdk impl_constraint_via_helper.mdk iface_effvar_arg_uncovered.mdk iface_effvar_arg_only.mdk default_generic_pins_tyvar.mdk"
#
# Usage:  sh test/diff_compiler_typecheck_errors.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC_MAIN="$ROOT/test/bin/typecheck_main"
CHECK="$ROOT/test/bin/check_main"
RT="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/typecheck_error_fixtures"

# Collect ALL missing oracles before failing — naming only the first costs a
# round-trip per oracle in a fresh worktree (#398).
_missing=""
[ -x "$TC_MAIN" ] || _missing="$_missing $TC_MAIN"
[ -x "$CHECK" ] || _missing="$_missing $CHECK"
if [ -n "$_missing" ]; then
  echo "build oracles first — missing:"
  for _m in $_missing; do
    echo "  FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$_m")  (missing $_m)"
  done
  exit 2
fi

# Drop the native value entry's trailing "()" (Unit return; runtime/medaka_rt.c).
strip_unit() { sed '$ s/()$//; ${/^$/d;}'; }

pass=0; fail=0

for f in "$FIXDIR"/*.mdk; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  golden="${f%.mdk}.tc.golden"
  [ -f "$golden" ] || { echo "no golden for $name (run sh test/capture_goldens.sh tc)"; fail=$((fail+2)); continue; }
  ref="$(LC_ALL=C sort < "$golden")"

  # Prelude-dependent fixtures (#11): Driver A structurally can't reject — run
  # ONLY Driver B (prelude-aware).
  case " $PRELUDE_DEP " in
    *" $name "*)
      selfB="$("$CHECK" "$RT" "$CORE" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
      if [ "$selfB" = "$ref" ]; then
        pass=$((pass+1)); printf 'ok   check/%s (prelude-dep)\n' "$name"
      else
        fail=$((fail+1)); printf 'FAIL check/%s\n  self: %s\n   ref: %s\n' "$name" "$selfB" "$ref"
      fi
      continue ;;
  esac

  # Driver A: typecheck_main (bare HM, no prelude)
  selfA="$("$TC_MAIN" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  if [ "$selfA" = "$ref" ]; then
    pass=$((pass+1)); printf 'ok   tc_main/%s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL tc_main/%s\n  self: %s\n   ref: %s\n' "$name" "$selfA" "$ref"
  fi

  # Driver B: check_main (full front-end with prelude)
  selfB="$("$CHECK" "$RT" "$CORE" "$f" 2>/dev/null | strip_unit | LC_ALL=C sort)"
  if [ "$selfB" = "$ref" ]; then
    pass=$((pass+1)); printf 'ok   check/%s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL check/%s\n  self: %s\n   ref: %s\n' "$name" "$selfB" "$ref"
  fi
done

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
