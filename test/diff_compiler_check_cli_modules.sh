#!/bin/sh
# DRIVER-COLLAPSE Phase 4 (OPTION A) capability gate: the real `medaka check` CLI
# now RESOLVES imports (loadProgram → multi-module typecheck), fixing the "native
# check is single-file" limitation.  This gate proves the new capability and that
# `check` AGREES with `build` on the SAME project (both route through the unified
# loader + elaborateModules path → the same hadTypeErrors verdict).
#
# It complements (does NOT duplicate):
#   • diff_compiler_check.sh         — single-file check_main host; no-import
#     byte-identity + UnknownModule for genuinely-missing imports (unchanged).
#   • diff_compiler_check_modules.sh — native multi typecheck vs the OCaml MULTI
#     oracle goldens (the import-aware path check now shares with run/build).
#   • diff_native_cli.sh check/*     — the CLI's no-import goldens (byte-identical).
#
# Drives ./medaka (must be freshly built — make medaka — see the diff_native_cli
# stale-binary footgun: this gate NEVER rebuilds it).
#
# Legs (all on a synthesized 2-file project with a cross-module import):
#   1. resolve:  `check main.mdk` resolves `import helper.{double}` — output names
#                the cross-module-typed binding and emits NO `UnknownModule`.
#   2. exit0:    a well-typed import-bearing project exits 0.
#   3. type-err: a type-error import-bearing project emits a TYPE ERROR and exits 1.
#   4. agree:    on that type-error project, `build` ALSO rejects (exit 1) — check
#                and build agree via the unified path.
#
# Usage:  sh test/diff_compiler_check_cli_modules.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

bound() { perl -e 'alarm 120; exec @ARGV' "$@"; }
strip_unit() { sed '$ s/0$//'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# A small 2-file project: main imports a public helper from a sibling module.
cat > "$TMP/helper.mdk" <<'EOF'
export double : Int -> Int
double x = x + x
EOF
cat > "$TMP/good.mdk" <<'EOF'
import helper.{double}
quad : Int -> Int
quad x = double (double x)
main = println (quad 3)
EOF
cat > "$TMP/bad.mdk" <<'EOF'
import helper.{double}
bad : Int
bad = double "x"
EOF

# 1. resolve: import resolved (quad typed) AND no UnknownModule diagnostic.
good_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/good.mdk" 2>/dev/null | strip_unit)"
good_code=$?
case "$good_out" in
  *UnknownModule*) fail=$((fail+1)); printf 'FAIL resolve/import (still UnknownModule: %s)\n' "$good_out" ;;
  *"quad : Int -> Int"*) pass=$((pass+1)); printf 'ok   resolve/import (cross-module reference typed)\n' ;;
  *) fail=$((fail+1)); printf 'FAIL resolve/import (no quad scheme: [%s])\n' "$good_out" ;;
esac

# 2. exit0: well-typed import-bearing project exits 0.
MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/good.mdk" >/dev/null 2>&1
if [ "$?" -eq 0 ]; then pass=$((pass+1)); printf 'ok   exit0/good\n'
else fail=$((fail+1)); printf 'FAIL exit0/good (exit %d)\n' "$?"; fi

# 3. type-err: import-bearing type error → a LOCATED diagnostic + exit 1.
#    (Imported-module diagnostics fix): the multi-module CLI `check` now renders the
#    accumulated per-module diagnostics LOCATED (`file:L:C: message` + caret), the
#    same surface `--json` mirrors, instead of the old loc-free `TYPE ERROR: …`.  We
#    require the entry error to carry its `bad.mdk:LINE:COL:` location AND the message.
bad_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/bad.mdk" 2>/dev/null)"
bad_code=$?
case "$bad_out" in
  *bad.mdk:*:*:*"Type mismatch"*) if [ "$bad_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   type-err/bad (located file:L:C diagnostic, exit 1)\n'
                  else fail=$((fail+1)); printf 'FAIL type-err/bad (located but exit %d)\n' "$bad_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL type-err/bad (no located diagnostic: [%s])\n' "$bad_out" ;;
esac

# 4. agree: build rejects the SAME type-error project (exit 1) — check==build.
MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/bad.mdk" -o "$TMP/bad.out" >/dev/null 2>&1
build_code=$?
if [ "$build_code" -ne 0 ] && [ ! -x "$TMP/bad.out" ]; then
  pass=$((pass+1)); printf 'ok   agree/build-rejects (check & build both reject)\n'
else
  fail=$((fail+1)); printf 'FAIL agree/build-rejects (build exit %d, binary present=%s)\n' "$build_code" "$([ -x "$TMP/bad.out" ] && echo yes || echo no)"
fi

# 5. numlit-soundness (#11 cross-module hole): a numeric-literal arg to an IMPORTED
#    function, unified through a polymorphic param with a NON-Num type, MUST be
#    rejected (the literal's Num obligation was being silently dropped on the
#    cross-module path → over-accept).  Since Chunk D (Num mis-framing reframe) the
#    rejection reads as the clearer `Type mismatch: Int literal vs List (List Int)`
#    (a literal forced to a ground non-Num type is a structural mismatch), not the
#    older `No impl of Num for …`; either wording proves the obligation is enforced
#    — the gate accepts both and only requires the reject (exit 1).  Legs 1–2 (a
#    legit Int-defaulting cross-module call) still pass, guarding over-strictness.
cat > "$TMP/numlib.mdk" <<'EOF'
export g : Ord a => a -> List a -> Bool
g x ys = True
EOF
cat > "$TMP/numbad.mdk" <<'EOF'
import numlib.{g}
main = println (g [1, 2] 5)
EOF
num_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/numbad.mdk" 2>/dev/null)"
num_code=$?
case "$num_out" in
  *"No impl of Num for List (List Int)"*|*"Int literal vs List (List Int)"*) if [ "$num_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   numlit-soundness (cross-module literal Num obligation enforced)\n'
                  else fail=$((fail+1)); printf 'FAIL numlit-soundness (rejected but exit %d)\n' "$num_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL numlit-soundness (cross-module Num literal hole: [%s])\n' "$num_out" ;;
esac

# 6. cross-module superinterface (WS-1a over-rejection regression guard).  An
#    `impl Monoid Color` in the ENTRY whose required superinterface `impl
#    Semigroup Color` lives in an IMPORTED module must be ACCEPTED — instances are
#    global, so the super impl exists even though it isn't `export`-marked (and
#    even when it is).  Before the allImplDecls accumulator fix, the multi-module
#    superinterface existence query only saw `accData ++ prog` (which drops
#    imported impls) → false `requires a superinterface impl '… Semigroup …',
#    which is missing`.  Legs: (a) imported non-export super → accept; (b) NO
#    super anywhere → still reject (the under-rejection guard for WS-1a itself).
cat > "$TMP/sg.mdk" <<'EOF'
public export data Color = Red | Green

impl Semigroup Color where
  append x y = x
EOF
cat > "$TMP/mono_ok.mdk" <<'EOF'
import sg.{Color(..)}

impl Monoid Color where
  empty = Red

main = println "ok"
EOF
sup_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/mono_ok.mdk" 2>/dev/null)"
sup_code=$?
case "$sup_out" in
  *superinterface*) fail=$((fail+1)); printf 'FAIL super-xmod/accept (false reject: [%s])\n' "$sup_out" ;;
  *) if [ "$sup_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   super-xmod/accept (imported super impl satisfies the requires)\n'
     else fail=$((fail+1)); printf 'FAIL super-xmod/accept (exit %d: [%s])\n' "$sup_code" "$sup_out"; fi ;;
esac

cat > "$TMP/nosup.mdk" <<'EOF'
public export data Color = Red | Green
EOF
cat > "$TMP/mono_bad.mdk" <<'EOF'
import nosup.{Color(..)}

impl Monoid Color where
  empty = Red

main = println "ok"
EOF
nosup_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/mono_bad.mdk" 2>/dev/null)"
nosup_code=$?
case "$nosup_out" in
  *"requires a superinterface 'impl Semigroup Color', which is missing"*)
    if [ "$nosup_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   super-xmod/reject (no super anywhere still rejected)\n'
    else fail=$((fail+1)); printf 'FAIL super-xmod/reject (rejected but exit %d)\n' "$nosup_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL super-xmod/reject (under-rejection regressed: [%s])\n' "$nosup_out" ;;
esac

# 7b. cross-module prelude-Ord obligation (Bug B regression guard).  An import-
#     bearing program whose entry uses an `Ord`-constrained operation on a prelude
#     type (`Int`) records a (Ord, Int) CALL obligation.  checkModuleFullImpl's
#     checkCallObligations matched it against `implDecls ++ prog` only, which OMITS
#     `accData` (the prelude's `impl Ord Int`) → spurious `No impl of Ord for Int`.
#     The fix threads `accData` into the call-obligation impl universe.  This MUST
#     be CLEAN (exit 0), matching run/build.
cat > "$TMP/ordlib.mdk" <<'EOF'
export pick : Ord a => a -> a -> a
pick x y = if x < y then y else x
EOF
cat > "$TMP/orduse.mdk" <<'EOF'
import ordlib.{pick}
main = println (pick 3 7)
EOF
ord_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/orduse.mdk" 2>/dev/null)"
ord_code=$?
case "$ord_out" in
  *"No impl of Ord"*) fail=$((fail+1)); printf 'FAIL ord-xmod (spurious prelude-Ord reject: [%s])\n' "$ord_out" ;;
  *) if [ "$ord_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   ord-xmod (prelude Ord Int obligation satisfied cross-module)\n'
     else fail=$((fail+1)); printf 'FAIL ord-xmod (exit %d: [%s])\n' "$ord_code" "$ord_out"; fi ;;
esac

# 8. global cross-module coherence (D3 / WS-2 part-2).  Two DIFFERENT modules each
#    define `impl C T` for the SAME instance: each module is LOCALLY coherent, but
#    jointly incoherent (silent dispatch ambiguity — cuseM2 would print cuseM1's
#    result).  Per-module coherence accepts this; the global check must REJECT,
#    naming BOTH owning modules.
cat > "$TMP/cohbase.mdk" <<'EOF'
public export data CT = CT1
export interface CIface a where
  csh : a -> Int
EOF
cat > "$TMP/cohm1.mdk" <<'EOF'
import cohbase.{CT(..), CIface(..), csh}
export impl CIface CT where
  csh x = 1
export cuseM1 : Int
cuseM1 = csh CT1
EOF
cat > "$TMP/cohm2.mdk" <<'EOF'
import cohbase.{CT(..), CIface(..), csh}
export impl CIface CT where
  csh x = 2
export cuseM2 : Int
cuseM2 = csh CT1
EOF
cat > "$TMP/cohtop.mdk" <<'EOF'
import cohm1.{cuseM1}
import cohm2.{cuseM2}
main =
  println cuseM1
  println cuseM2
EOF
coh_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/cohtop.mdk" 2>/dev/null)"
coh_code=$?
case "$coh_out" in
  *Conflicting*)
    case "$coh_out" in *cohm1*) m1seen=yes ;; *) m1seen=no ;; esac
    case "$coh_out" in *cohm2*) m2seen=yes ;; *) m2seen=no ;; esac
    if [ "$coh_code" -eq 1 ] && [ "$m1seen" = yes ] && [ "$m2seen" = yes ]; then
      pass=$((pass+1)); printf 'ok   coh-xmod/conflict (rejected, names both modules)\n'
    else
      fail=$((fail+1)); printf 'FAIL coh-xmod/conflict (exit %d m1=%s m2=%s: [%s])\n' "$coh_code" "$m1seen" "$m2seen" "$coh_out"
    fi ;;
  *) fail=$((fail+1)); printf 'FAIL coh-xmod/conflict (not rejected as conflict: [%s])\n' "$coh_out" ;;
esac

# 9. benign DIAMOND: ONE shared impl in `dbase`, imported by m1 and m2 → ACCEPT.
#    Imports do NOT copy impl decls, so the joint set has a single entry — no
#    false overlap.  This is the over-rejection guard for the global check.
cat > "$TMP/dbase.mdk" <<'EOF'
public export data DT = DT1
export interface DIface a where
  dsh : a -> Int
export impl DIface DT where
  dsh x = 9
EOF
cat > "$TMP/dm1.mdk" <<'EOF'
import dbase.{DT(..), DIface(..), dsh}
export duseM1 : Int
duseM1 = dsh DT1
EOF
cat > "$TMP/dm2.mdk" <<'EOF'
import dbase.{DT(..), DIface(..), dsh}
export duseM2 : Int
duseM2 = dsh DT1
EOF
cat > "$TMP/dtop.mdk" <<'EOF'
import dm1.{duseM1}
import dm2.{duseM2}
main =
  println duseM1
  println duseM2
EOF
dia_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/dtop.mdk" 2>/dev/null)"
dia_code=$?
case "$dia_out" in
  *Conflicting*) fail=$((fail+1)); printf 'FAIL coh-xmod/diamond (benign shared impl falsely rejected: [%s])\n' "$dia_out" ;;
  *) if [ "$dia_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   coh-xmod/diamond (single shared impl accepted)\n'
     else fail=$((fail+1)); printf 'FAIL coh-xmod/diamond (exit %d: [%s])\n' "$dia_code" "$dia_out"; fi ;;
esac

# 9. P0-18 importer-shadow on a NO-IMPL receiver.  `size` is IMPORTED from `impprov`
#    and shadows the LOCAL interface method `Sizeable.size`.  `size (Box 3)` must
#    dispatch to the local `impl Sizeable Box` (3); `size 3` (Int, NO impl) must fall
#    back to the imported standalone (4).  Before the fix `check` REJECTED (`No impl of
#    Sizeable for Int`) and `build` PANICKED, while `run` correctly returned the
#    standalone — the imported shadow's bare name was invisible to the emit-path shadow
#    detection (mangled) AND its no-impl obligation was not skipped on the check path.
#    check must ACCEPT and build must AGREE (dispatch 3 then standalone 4).
cat > "$TMP/impprov.mdk" <<'EOF'
export size : Int -> Int
size n = n + 1
EOF
cat > "$TMP/impmain.mdk" <<'EOF'
import impprov.{size}

interface Sizeable a where
  size : a -> Int

data Box = Box Int

impl Sizeable Box where
  size (Box n) = n

main =
  println (size (Box 3))
  println (size 3)
EOF
imp_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/impmain.mdk" 2>/dev/null)"
imp_code=$?
case "$imp_out" in
  *"No impl"*) fail=$((fail+1)); printf 'FAIL importer-shadow/check (spurious no-impl reject: [%s])\n' "$imp_out" ;;
  *) if [ "$imp_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   importer-shadow/check (imported shadow on no-impl receiver accepted)\n'
     else fail=$((fail+1)); printf 'FAIL importer-shadow/check (exit %d: [%s])\n' "$imp_code" "$imp_out"; fi ;;
esac
# build AGREEMENT: the same project must build AND run to `3` then `4`.
if MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/impmain.mdk" -o "$TMP/imp.bin" >/dev/null 2>&1 && [ -x "$TMP/imp.bin" ]; then
  imp_bld="$("$TMP/imp.bin" 2>/dev/null | tr '\n' ',')"
  if [ "$imp_bld" = "3,4," ]; then pass=$((pass+1)); printf 'ok   importer-shadow/build (dispatch 3 + standalone 4)\n'
  else fail=$((fail+1)); printf 'FAIL importer-shadow/build (got [%s], want [3,4,])\n' "$imp_bld"; fi
else fail=$((fail+1)); printf 'FAIL importer-shadow/build (native build failed)\n'; fi

# 10. P0-19 (SHADOW-SEMANTICS row 14 / cell d8) DEFINER shadow with IMPORTED
#     interface+impl.  The CONSUMER defines the standalone `size : Int -> Int` and
#     IMPORTS the interface `Sizeable` + type `Box(..)` + its impl from `dprov`.
#     S6: the impl universe is GLOBAL, so `size (Box 3)` must DISPATCH to the imported
#     `impl Sizeable Box` (3) and `size 3` (Int, no impl) fall back to the standalone
#     (4) — exactly like the all-local cell d2.  Before the fix all three paths
#     REJECTED `Int vs Box` (the definer-shadow app typed against the local standalone
#     before the per-receiver machinery saw the imported impl).  check must ACCEPT and
#     build must AGREE (3 then 4).
cat > "$TMP/dprov.mdk" <<'EOF'
export interface Sizeable a where
  size : a -> Int

public export data Box = Box Int

export impl Sizeable Box where
  size (Box n) = n
EOF
cat > "$TMP/dmain.mdk" <<'EOF'
import dprov.{Sizeable, Box(..)}

size : Int -> Int
size n = n + 1

main =
  println (size (Box 3))
  println (size 3)
EOF
dfn_out="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/dmain.mdk" 2>/dev/null)"
dfn_code=$?
case "$dfn_out" in
  *"Type mismatch"*|*"No impl"*) fail=$((fail+1)); printf 'FAIL definer-shadow-xmod/check (spurious reject: [%s])\n' "$dfn_out" ;;
  *) if [ "$dfn_code" -eq 0 ]; then pass=$((pass+1)); printf 'ok   definer-shadow-xmod/check (imported iface+impl dispatch accepted)\n'
     else fail=$((fail+1)); printf 'FAIL definer-shadow-xmod/check (exit %d: [%s])\n' "$dfn_code" "$dfn_out"; fi ;;
esac
# build AGREEMENT: the same project must build AND run to `3` then `4`.
if MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/dmain.mdk" -o "$TMP/dfn.bin" >/dev/null 2>&1 && [ -x "$TMP/dfn.bin" ]; then
  dfn_bld="$("$TMP/dfn.bin" 2>/dev/null | tr '\n' ',')"
  if [ "$dfn_bld" = "3,4," ]; then pass=$((pass+1)); printf 'ok   definer-shadow-xmod/build (dispatch 3 + standalone 4)\n'
  else fail=$((fail+1)); printf 'FAIL definer-shadow-xmod/build (got [%s], want [3,4,])\n' "$dfn_bld"; fi
else fail=$((fail+1)); printf 'FAIL definer-shadow-xmod/build (native build failed)\n'; fi

# 11. IMPORTED-MODULE diagnostics (the regression this gate's fix targets).  A type
#     error in an IMPORTED module (badhelper.mdk) used to be invisible on the very
#     command the deflection told you to run: `check` reported the entry only (loc-
#     free), `run`/`build` deflected to "type error in main.mdk", yet `--json` DID
#     carry the imported error with a real range.  All THREE human commands must now
#     surface the IMPORTED module's error LOCATED (badhelper.mdk:L:C:), matching JSON.
cat > "$TMP/badhelper.mdk" <<'EOF'
export badFn : Int -> Int
badFn x = x + "notanint"
EOF
cat > "$TMP/impuse.mdk" <<'EOF'
import badhelper.{badFn}
main = println (badFn 3)
EOF
imp_chk="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" check "$TMP/impuse.mdk" 2>&1)"
imp_chk_code=$?
case "$imp_chk" in
  *badhelper.mdk:*:*:*"Type mismatch"*) if [ "$imp_chk_code" -eq 1 ]; then pass=$((pass+1)); printf 'ok   imported-diag/check (imported error located, exit 1)\n'
                  else fail=$((fail+1)); printf 'FAIL imported-diag/check (located but exit %d)\n' "$imp_chk_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL imported-diag/check (imported error not located: [%s])\n' "$imp_chk" ;;
esac
imp_run="$(MEDAKA_ROOT="$ROOT" bound "$MEDAKA" run "$TMP/impuse.mdk" 2>&1)"
imp_run_code=$?
case "$imp_run" in
  *badhelper.mdk:*:*:*"Type mismatch"*) if [ "$imp_run_code" -ne 0 ]; then pass=$((pass+1)); printf 'ok   imported-diag/run (imported error located, nonzero exit)\n'
                  else fail=$((fail+1)); printf 'FAIL imported-diag/run (located but exit 0)\n'; fi ;;
  *) fail=$((fail+1)); printf 'FAIL imported-diag/run (imported error not located: [%s])\n' "$imp_run" ;;
esac
imp_bld="$(MEDAKA_ROOT="$ROOT" MEDAKA="$MEDAKA" bound "$MEDAKA" build "$TMP/impuse.mdk" -o "$TMP/impuse.out" 2>&1)"
imp_bld_code=$?
case "$imp_bld" in
  *badhelper.mdk:*:*:*"Type mismatch"*) if [ "$imp_bld_code" -ne 0 ] && [ ! -x "$TMP/impuse.out" ]; then pass=$((pass+1)); printf 'ok   imported-diag/build (imported error located, no binary)\n'
                  else fail=$((fail+1)); printf 'FAIL imported-diag/build (located but built? exit %d)\n' "$imp_bld_code"; fi ;;
  *) fail=$((fail+1)); printf 'FAIL imported-diag/build (imported error not located: [%s])\n' "$imp_bld" ;;
esac

printf '\n%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
